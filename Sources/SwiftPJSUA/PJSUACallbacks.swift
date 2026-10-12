import Foundation
import PJSIP

// MARK: - C callback bridge (re-entrancy boundary)
//
// pjsua1 callbacks are C function pointers that carry no user-data context, so they
// can't capture `self`. We bridge them through one file-private sink. pjsua is a
// *process-global* library (there is one instance), so a single sink is the honest
// model, not a hack.
//
// ## Re-entrancy / deadlock discipline (G2)
//
// These functions are the ENTIRE surface that runs on PJSUA's worker threads. They are
// deliberately free functions, `private` to this file, and hold **no reference to the
// `PJSUA` actor**. Their only capability is to read POD out of C structs and `yield` a
// `Sendable` value: a ``PJSUAEvent``, or a ``RegistrationSignal`` on the engine's own channel,
// which the actor reads in its own turns. Because they cannot reach the actor, they physically cannot
// call an engine method or `await` it — so a callback can never re-enter a blocking
// PJSIP call that the actor is already inside. Re-entrancy is prevented *by construction*,
// not by convention. Keep it that way: never give these functions an actor reference, and
// never call a blocking `pjsua_*` request (make_call/answer/hangup/register) from here.
// Reading call info (`pjsua_call_get_info`) and wiring media (`pjsua_conf_connect`) is
// fine — those are non-blocking and must run on this registered worker thread.
//
// ### Why that discipline is load-bearing (validated against pjproject master, 2026-07-17)
//
// A deep source review confirmed G2 is not merely tidy — some of these callbacks run with
// pjsua's own locks **held**, so a synchronous re-entry would deadlock rather than misbehave:
//
//   held under PJSUA_LOCK  : on_reg_state, on_reg_state2, on_reg_started2,
//                            on_ip_change_progress, on_incoming_call,
//                            on_rejected_incoming_call
//   no PJSUA_LOCK, but the dialog/tsx grp_lock is held upstream:
//                            on_call_state, on_call_tsx_terminate_session, on_mwi_state,
//                            on_auth_challenge
//   depends on the path    : on_transport_state — no lock for a socket error, the transport
//                            manager's and the transport's for a shutdown, PJSUA_LOCK too
//                            inside an IP change; on the worker or the sending thread
//
// Documented lock order is PJSUA_LOCK > dialog grp_lock > tsx grp_lock, so calling *up* that
// order from inside a callback is an ABBA inversion. `on_call_tsx_terminate_session`'s own
// header says the app MUST NOT call any API acquiring a higher-order lock from within it.
//
// Forward note for the credential work: `on_auth_challenge` (PJSIP 2.17+) is invoked with the
// tsx grp_lock held and must NOT acquire PJSUA_LOCK. If we adopt it to supply secrets on demand
// (see docs/Configuration-Design.md §4), the fetch must use its **async/deferred** path —
// `pjsip_auth_clt_async_send_req` after the secret arrives — never a synchronous Keychain read
// inside the callback. That path is a use-after-free for REGISTER in the shipped 2.17.0 binary
// (fixed upstream in `5c605b499`, #5251): bump swift-pjsip first.
//
// Full findings: docs/Threading-Validation.md. Every pjsua callback, installed or not, with what it
// conveys and when it is worth wiring: docs/Callback-Inventory.md.
//
// `nonisolated(unsafe)` invariant: written exactly once via ``makePJSUAEventStreams()`` in
// `PJSUA.init`, before `pjsua_start()` can fire any callback; read-only thereafter.
// `AsyncStream.Continuation` is `Sendable` and its `yield` is thread-safe, so yielding
// from PJSUA's worker-thread callbacks is safe. Removal plan: when pjsua gains per-instance
// user-data on these callbacks, replace the global with that.
private nonisolated(unsafe) var pjsuaEventSink: AsyncStream<PJSUAEvent>.Continuation?
private nonisolated(unsafe) var pjsuaCallEventSink: AsyncStream<PJSUAEvent>.Continuation?
/// The engine's own registration channel (``RegistrationSignal``); same invariant as above.
private nonisolated(unsafe) var pjsuaRegistrationSink: AsyncStream<RegistrationSignal>.Continuation?
/// The engine's executor thread, recorded by ``installPJSUACallbacks(into:)``, which
/// `PJSUA.start` runs there. Same invariant: written before `pjsua_init`, read-only thereafter.
private nonisolated(unsafe) var pjsuaEngineThread: pthread_t?
/// Settlements reported on the engine's thread; see ``pjsuaSettlementsOnEngineThread()``. Written
/// and read only on that thread.
private nonisolated(unsafe) var pjsuaEngineThreadSettlements: UInt64 = 0

private func isOnEngineThread() -> Bool {
    pjsuaEngineThread.map { pthread_equal($0, pthread_self()) != 0 } ?? false
}

/// How many settlements have been reported on the engine's thread so far; read it on that thread.
/// A send that pjsip ends in place — the transaction created, then its send failed — reports its
/// settlement there, synchronously, before the send returns its error (`sip_util_statefull.c`,
/// `pjsip_endpt_send_request`), so the count before and after a send tells whether it reported one.
func pjsuaSettlementsOnEngineThread() -> UInt64 { pjsuaEngineThreadSettlements }

/// Process-global sink for pjsip's own log lines (`pjsua_logging_config.cb`). Same
/// `nonisolated(unsafe)` invariant as the event sinks, with a narrower window: written once
/// in `PJSUA.start(_:)` before `pjsua_init` can produce a line, cleared in `shutdown` after
/// `pjsua_destroy` has stopped the threads that would call it. Called from arbitrary pjsip
/// threads at console volume — the callback does as little as possible before yielding to
/// the sink.
nonisolated(unsafe) var pjsuaLogSink: (@Sendable (Int32, String) -> Void)?

/// The two per-path ceilings the app asked for, retained for `pjsuaOnLog` — see below.
nonisolated(unsafe) var pjsuaLogConsoleLevel: Int32 = 4
nonisolated(unsafe) var pjsuaLogSinkLevel: Int32 = 5

/// `pjsua_logging_config.cb` — fired on whichever pjsip thread emitted the line.
///
/// Two behaviours upstream hides in `log_writer` (pjsua_core.c):
/// * **`cb` replaces console output, it does not tap it** — the writer calls `cb` *instead
///   of* `pj_log_write` for every console-eligible line. So this callback re-forwards lines
///   at or below the app's requested console level to `pj_log_write` (never `pj_log`, which
///   would recurse back through this callback).
/// * **`console_level` gates what reaches `cb` at all, and `level` gates what reaches the
///   writer.** `PJSUA.start` therefore sets both upstream ceilings to the maximum of the
///   app's two requested levels, and the independent per-path ceilings live here.
///
/// `data` is NOT NUL-terminated; `len` is authoritative.
func pjsuaOnLog(_ level: Int32, _ data: UnsafePointer<CChar>?, _ len: Int32) {
    guard let data, len > 0 else { return }
    if level <= pjsuaLogConsoleLevel {
        pj_log_write(level, data, len)
    }
    if let sink = pjsuaLogSink, level <= pjsuaLogSinkLevel {
        let text = String(decoding: UnsafeRawBufferPointer(start: UnsafeRawPointer(data),
                                                           count: Int(len)),
                          as: UTF8.self)
        sink(level, text)
    }
}

/// Create the event streams and install their continuations as the process-global sinks.
/// Called once from `PJSUA.init` before anything can start delivering callbacks.
///
/// Two public channels, two contracts (TD-3):
/// - `events` is the complete record, bounded newest-first: every event lands here and
///   telemetry may drop under pressure — it carries only periodic (`.registrationState`,
///   re-delivered each renewal) or informational (`.callMediaEvent`) payloads besides
///   the lossy copies of the call channel, so a drop converges instead of stranding.
/// - `callEvents` is the guaranteed channel for the call-scoped events whose loss is
///   unrecoverable — `.incomingCall` (call never rings), `.callState` (a dropped
///   `.disconnected` strands a CallKit call), `.callMediaState` (a pending hold never
///   fulfills), `.streamDestroyed` (the only copy of the final statistics). It is
///   unbounded, which is affordable precisely here: these events are per-call, so an
///   unconsumed buffer grows only with real call activity — an idle engine produces
///   none, unlike the periodic renewals a single unbounded stream would have retained.
///
/// The third, `registrationSignals`, is the engine's own and never reaches the app. It is
/// unbounded because nothing may drop from it: the engine sequences account registrations on
/// these signals. A task on the engine actor reads it for the engine's whole life, so it does
/// not accumulate.
func makePJSUAEventStreams() -> (events: AsyncStream<PJSUAEvent>,
                                callEvents: AsyncStream<PJSUAEvent>,
                                registrationSignals: AsyncStream<RegistrationSignal>) {
    let (events, eventsContinuation) = AsyncStream<PJSUAEvent>.makeStream(
        bufferingPolicy: .bufferingNewest(64))
    let (callEvents, callContinuation) = AsyncStream<PJSUAEvent>.makeStream()
    let (registrationSignals, registrationContinuation) =
        AsyncStream<RegistrationSignal>.makeStream()
    pjsuaEventSink = eventsContinuation
    pjsuaCallEventSink = callContinuation
    pjsuaRegistrationSink = registrationContinuation
    return (events, callEvents, registrationSignals)
}

/// Finish the event streams (called from `PJSUA.shutdown`). Also resets the registration
/// dedup state — a restarted engine's account slots are fresh, so stale tuples must not
/// suppress the first reports of a new engine lifetime.
func finishPJSUAEventStreams() {
    pjsuaEventSink?.finish()
    pjsuaCallEventSink?.finish()
    pjsuaRegistrationSink?.finish()
    regDedupLock.lock()
    lastEmittedRegState.removeAll()
    regDedupLock.unlock()
    registrationTransportLock.lock()
    registrationTransports.removeAll()
    registrationTransportLock.unlock()
}

/// Telemetry yield: the bounded `events` stream only.
private func emit(_ event: PJSUAEvent) {
    pjsuaEventSink?.yield(event)
}

/// Call-scoped yield: the guaranteed `callEvents` channel plus the `events` copy, so
/// the complete record stays complete for consumers that want it.
private func emitCall(_ event: PJSUAEvent) {
    pjsuaCallEventSink?.yield(event)
    pjsuaEventSink?.yield(event)
}

/// Wire the file-private C callbacks into a `pjsua_config`. The closures are
/// non-capturing (they only reference these file-private free functions), so they
/// convert to `@convention(c)` function pointers automatically.
func installPJSUACallbacks(into cfg: inout pjsua_config) {
    pjsuaEngineThread = pthread_self()
    cfg.cb.on_call_state       = { callId, ev    in pjsuaOnCallState(callId, ev) }
    cfg.cb.on_incoming_call    = { acc, callId, rx in pjsuaOnIncomingCall(acc, callId, rx) }
    cfg.cb.on_call_media_state = { callId        in pjsuaOnCallMediaState(callId) }
    cfg.cb.on_reg_state2       = { acc, info     in pjsuaOnRegState2(acc, info) }
    cfg.cb.on_reg_started2     = { acc, info     in pjsuaOnRegStarted2(acc, info) }
    cfg.cb.on_stream_destroyed = { callId, strm, idx in pjsuaOnStreamDestroyed(callId, strm, idx) }
    cfg.cb.on_call_media_event = { callId, medIdx, ev in pjsuaOnCallMediaEvent(callId, medIdx, ev) }
    cfg.cb.on_call_transfer_status = { callId, code, text, final, pCont in
        pjsuaOnCallTransferStatus(callId, code, text, final, pCont)
    }
    cfg.cb.on_call_replaced = { oldId, newId in pjsuaOnCallReplaced(oldId, newId) }
    cfg.cb.on_ip_change_progress = { op, status, info in
        pjsuaOnIPChangeProgress(op, status, info)
    }
    cfg.cb.on_transport_state = { tp, state, info in pjsuaOnTransportState(tp, state, info) }
    cfg.cb.on_rejected_incoming_call = { param in pjsuaOnRejectedIncomingCall(param) }
}

/// Debug sanity check: every callback must arrive on a thread PJLIB has registered.
/// Compiles out in release builds. It is *not* the re-entrancy guard — the structural
/// "callbacks hold no actor reference" rule above is. This just catches a future change
/// that drives the callbacks from an unregistered thread.
@inline(__always)
private func assertOnRegisteredPJThread(_ function: StaticString = #function) {
    assert(
        pj_thread_is_registered() != 0,
        "PJSUA callback (\(function)) fired on a thread PJLIB doesn't know"
    )
}

// MARK: - Callbacks (worker-thread context)

private func pjsuaOnCallState(_ callId: pjsua_call_id, _ event: UnsafeMutablePointer<pjsip_event>?) {
    assertOnRegisteredPJThread()
    var info = pjsua_call_info()
    guard pjsua_call_get_info(callId, &info).isSuccess else { return }
    emitCall(.callState(
        call: CallID(callId),
        state: CallState(info.state),
        sipCallID: info.call_id.string,
        lastStatus: Int32(info.last_status.rawValue)
    ))
}

private func pjsuaOnIncomingCall(_ accId: pjsua_acc_id,
                                 _ callId: pjsua_call_id,
                                 _ rdata: UnsafeMutablePointer<pjsip_rx_data>?) {
    assertOnRegisteredPJThread()
    // Surface the SIP Call-ID so the GUI layer can compute a stable CallKit UUID (dedup
    // a VoIP push against the INVITE that follows it over a persisted connection), the
    // remote display info for the CallKit handle, and whether the offer carried video.
    var info = pjsua_call_info()
    let haveInfo = pjsua_call_get_info(callId, &info).isSuccess
    let sipCallID = haveInfo ? info.call_id.string : nil
    let from = haveInfo ? info.remote_info.string : nil
    // rem_vid_cnt > 0 when the remote offered ≥1 video stream → drives CXCallUpdate.hasVideo.
    let offeredVideo = haveInfo && info.rem_vid_cnt > 0
    emitCall(.incomingCall(
        account: AccountID(accId),
        call: CallID(callId),
        sipCallID: sipCallID,
        from: from,
        offeredVideo: offeredVideo
    ))
}

private func pjsuaOnCallMediaState(_ callId: pjsua_call_id) {
    assertOnRegisteredPJThread()
    var info = pjsua_call_info()
    guard pjsua_call_get_info(callId, &info).isSuccess else { return }

    // Per-stream handling, mirroring PJSUA2 iterating `CallInfo.media[]`. For each active
    // audio stream, bridge its conference slot to the sound device (slot 0) both ways:
    // remote audio → local playback, local capture → remote. Slot 0 is the device port;
    // under iOS's null-sound-device model it reaches real hardware only while CallKit has
    // activated the audio session (see SwiftPJSUAKit). We wire ACTIVE **and** REMOTE_HOLD,
    // matching upstream `pjsua_app.c`: on remote hold the slot stays bridged so resume needs
    // no re-wiring (and any remote on-hold media still plays). Video-stream wiring
    // (`pjsua_vid_conf_*`) lands in a later iteration; here we only surface the video info.
    // This low-level wiring is the engine's job; the higher-level reaction is the app's
    // (see `PJSUAEvent.callMediaState`).
    let media = callMediaInfos(from: &info)
    for stream in media where stream.kind == .audio {
        guard let slot = stream.audioConfSlot else { continue }
        switch stream.status {
        case .active, .remoteHold:
            pjsua_conf_connect(slot, 0)
            pjsua_conf_connect(0, slot)
        default:
            break
        }
    }
    // Surface the full per-stream vector; the engine does not filter — the app/router
    // decides which streams/states matter (see `PJSUAEvent.callMediaState`).
    emitCall(.callMediaState(call: CallID(callId), media: media))
}

/// Build the per-stream media vector from a call's `media[]` C array (a fixed-size tuple in
/// Swift), bounded by `media_cnt`. POD reads only — safe on the worker thread. Rebinding the
/// tuple's storage to its element type is valid because a C array is contiguous.
private func callMediaInfos(from info: inout pjsua_call_info) -> [CallMediaInfo] {
    let count = Int(info.media_cnt)
    guard count > 0 else { return [] }
    return withUnsafePointer(to: &info.media) { tuplePtr in
        tuplePtr.withMemoryRebound(to: pjsua_call_media_info.self, capacity: count) { base in
            (0..<count).map { CallMediaInfo(base[$0]) }
        }
    }
}

/// The stream is about to be destroyed — this is the **only** point at which its final counters
/// are readable, so they are read here rather than surfaced as a pointer the app could not
/// safely use. `pjsua_aud_stop_stream()` invokes this while the stream is still fully
/// constructed (`pjmedia_stream_destroy` runs afterwards) and with **`PJSUA_LOCK` held**, so the
/// G2 rule matters more here than anywhere else: read POD, yield, return.
///
/// Not called for locally-hung-up calls whose teardown has already set `call->hanging_up`. That
/// it *is* called for `pjsua_call_hangup()` depends on undocumented ordering in `pjsua_call.c` —
/// the media deinit precedes the flag by three lines. `offhook` pins that with a regression test;
/// see `docs/Call-Termination-Paths.md` §2.
private func pjsuaOnStreamDestroyed(_ callId: pjsua_call_id,
                                    _ stream: OpaquePointer?,
                                    _ streamIndex: UInt32) {
    assertOnRegisteredPJThread()
    guard let stream else { return }
    var stat = pjmedia_rtcp_stat()
    guard pjmedia_stream_get_stat(stream, &stat).isSuccess else { return }

    // Codec info is a separate read and a nice-to-have: a stream with no readable info still has
    // counters worth keeping, so a failure here degrades to an unnamed codec rather than dropping
    // the record.
    var info = pjmedia_stream_info()
    let codec: CallStreamStatistics.Codec
    if pjmedia_stream_get_info(stream, &info).isSuccess {
        codec = .init(name: info.fmt.encoding_name.string ?? "?",
                      clockRate: info.fmt.clock_rate,
                      channels: info.fmt.channel_cnt,
                      payloadType: info.fmt.pt)
    } else {
        codec = .init(name: "?", clockRate: 0, channels: 0, payloadType: 0)
    }

    emitCall(.streamDestroyed(
        call: CallID(callId),
        mediaIndex: Int(streamIndex),
        statistics: CallStreamStatistics(kind: .audio,
                                         codec: codec,
                                         transmit: .init(stat.tx),
                                         receive: .init(stat.rx),
                                         roundTrip: .init(usec: stat.rtt))
    ))
}

/// A `pjmedia_event` pjsua chose not to act on. Delivered on the **timer thread** — pjsua defers
/// it through a 1 ms `pjsua_schedule_timer2` rather than delivering it on the media thread that
/// published it — so this is the one callback in this file that does not share the others'
/// threading context. See `docs/Threading-Validation.md`.
private func pjsuaOnCallMediaEvent(_ callId: pjsua_call_id,
                                   _ mediaIndex: UInt32,
                                   _ event: UnsafeMutablePointer<pjmedia_event>?) {
    assertOnRegisteredPJThread()
    guard let event else { return }
    let mediaEvent = CallMediaEvent(event.pointee)
    let wrapped = PJSUAEvent.callMediaEvent(call: CallID(callId),
                                          mediaIndex: Int(mediaIndex),
                                          event: mediaEvent)
    switch mediaEvent {
    case .mediaTransportError, .audioDeviceError:
        // One-shot failures pjsua itself never reacts to — dropped from the bounded stream,
        // the app would never learn media died while the call stays confirmed.
        emitCall(wrapped)
    case .other:
        // Periodic/informational (RTCP, format changes, keyframe requests…) — a dropped
        // copy is made whole by the next event, so these stay on the bounded stream.
        emit(wrapped)
    }
}

/// Last registration tuple emitted per account slot. Renewals repeat an identical report
/// every expiry interval; only *transitions* go on the unbounded `callEvents` channel, so
/// an idle-but-registered engine buffers nothing there (the raw heartbeat still reaches the
/// bounded `events` stream for the record). Cleared on a terminal report: the epoch ended,
/// and a recycled `pjsua_acc_id` must not inherit the previous account's dedup state.
/// Guarded by `regDedupLock` — reg callbacks may arrive on different PJSUA worker threads.
private let regDedupLock = NSLock()
private var lastEmittedRegState: [pjsua_acc_id: (active: Bool, code: Int32,
                                               expiration: UInt32)] = [:]

private func pjsuaOnRegState2(_ accId: pjsua_acc_id, _ info: UnsafeMutablePointer<pjsua_reg_info>?) {
    assertOnRegisteredPJThread()
    guard let regInfo = info?.pointee else {
        // No reg_info at all is a terminal report — guaranteed channel (see below).
        // It also ends the epoch: clear the dedup entry or a later recovery whose tuple
        // happens to equal the cached active one would emit only to the lossy stream.
        regDedupLock.lock()
        lastEmittedRegState[accId] = nil
        regDedupLock.unlock()
        recordRegistrationTransport(nil, for: accId)
        emitCall(.registrationState(
            account: AccountID(accId), active: false, statusCode: 0, expiration: 0
        ))
        return
    }

    let renewing = regInfo.renew.bool
    var statusCode: Int32 = 0
    var expiration: UInt32 = 0
    if let cb = regInfo.cbparam?.pointee {
        statusCode = Int32(cb.code)            // SIP status code received (int)
        expiration = UInt32(cb.expiration)     // next expiration interval, seconds
    }
    // "Active" = a renewing registration that the server accepted (2xx) with a live
    // expiration. A successful un-REGISTER (renewing == false, expiration == 0) is inactive.
    let active = renewing && (Int32(PJSIP_SC_OK.rawValue) ..< 300).contains(statusCode) && expiration > 0
    recordRegistrationTransport(active ? sessionTransport(regInfo.regc) : nil, for: accId)
    // Every registration *transition* goes on the guaranteed channel — the single ordered,
    // authoritative path for account state. Identical renewal heartbeats emit only to the
    // bounded `events` record: they are periodic, self-replacing, and would otherwise grow
    // the unbounded `callEvents` buffer forever when nobody consumes it.
    let event = PJSUAEvent.registrationState(
        account: AccountID(accId),
        active: active,
        statusCode: statusCode,
        expiration: expiration
    )
    regDedupLock.lock()
    let tuple = (active: active, code: statusCode, expiration: expiration)
    let duplicate = lastEmittedRegState[accId].map { $0 == tuple } ?? false
    lastEmittedRegState[accId] = active ? tuple : nil
    regDedupLock.unlock()
    if duplicate {
        emit(event) // heartbeat — record only, not lifecycle
    } else {
        emitCall(event)
    }

    // The engine's own record, heartbeats included: it keeps each account's session from these,
    // and sequences its registration work on them.
    if let param = regInfo.cbparam?.pointee {
        let settlement = RegistrationSettlement(
            account: AccountID(accId),
            renew: renewing,
            status: param.status,
            code: statusCode,
            expiration: expiration,
            refreshIn: active ? refreshDelay(of: regInfo.regc) : nil,
            bindings: registrarBindings(param)
        )
        if isOnEngineThread() { pjsuaEngineThreadSettlements &+= 1 }
        pjsuaRegistrationSink?.yield(.settled(settlement))
    }
}

/// `on_reg_started2` — a REGISTER or un-REGISTER left through `pjsua_acc_set_registration`.
/// Runs with `PJSUA_LOCK` held, after pjsua dropped its own reference on the session.
///
/// Reported only when pjsua started it on a thread of its own: an automatic retry, a Contact
/// rewrite, an IP-change step. A start on the engine's thread comes from a call the engine made,
/// and the engine records those at the call (a send as pending, an IP change as running). This
/// callback could not report them reliably: when the worker has just processed a fast response, it
/// may have reported the settlement and released `PJSUA_LOCK` but still hold its reference on the
/// session, so `is_busy` reads open (`sip_reg.c`, `regc_tsx_callback`) and the session would be
/// left pending with no settlement to follow.
///
/// On pjsua's own thread the read holds: the one worker the engine pins (`thread_cnt`, timers
/// polled on it too) processes this transaction's response only after this callback returns, so
/// `pending` is whether a settlement is still to come.
private func pjsuaOnRegStarted2(_ accId: pjsua_acc_id, _ info: UnsafeMutablePointer<pjsua_reg_info>?) {
    assertOnRegisteredPJThread()
    if isOnEngineThread() { return }
    guard let regInfo = info?.pointee else { return }
    var pending = false
    if let regc = regInfo.regc {
        var state = pjsip_regc_info()
        if pjsip_regc_get_info(regc, &state).isSuccess { pending = state.is_busy.bool }
    }
    pjsuaRegistrationSink?.yield(.started(account: AccountID(accId),
                                          renew: regInfo.renew.bool,
                                          pending: pending))
}

/// Seconds until `regc`'s refresh timer sends the next REGISTER: `next_reg`, read in
/// `on_reg_state2`, after pjsip scheduled the timer for the 2xx being reported
/// (`schedule_registration` runs before the callback, `sip_reg.c`). That REGISTER leaves with no
/// callback, so this is the engine's only notice of it.
private func refreshDelay(of regc: OpaquePointer?) -> UInt32? {
    guard let regc else { return nil }
    var state = pjsip_regc_info()
    guard pjsip_regc_get_info(regc, &state).isSuccess, state.auto_reg.bool else { return nil }
    return state.next_reg
}

/// The connection each account's registration went over at its last 2xx, as an address, keyed by
/// pjsua account id. `on_transport_state` reads it to name the accounts a connection carried: it
/// runs before pjsua's own handler, which then releases the connection from those sessions, after
/// which nothing can tell. The session holds a reference on the transport until that release, so
/// the address cannot be reused while an entry names it. Entries go on that connection's
/// disconnection or destruction, and on any settlement that leaves the account unregistered.
/// Guarded by `registrationTransportLock`: `on_transport_state` runs on the worker and on sending
/// threads. A leaf lock: nothing is called while it is held.
private let registrationTransportLock = NSLock()
private var registrationTransports: [pjsua_acc_id: UInt] = [:]

private func recordRegistrationTransport(_ transport: UInt?, for account: pjsua_acc_id) {
    registrationTransportLock.lock()
    registrationTransports[account] = transport
    registrationTransportLock.unlock()
}

/// The connection `account`'s registration went over at its last 2xx, while it lives; see
/// ``PJSUA/registrationTransport(of:)``.
func pjsuaRegistrationTransport(of account: pjsua_acc_id) -> UInt? {
    registrationTransportLock.lock()
    defer { registrationTransportLock.unlock() }
    return registrationTransports[account]
}

/// The connection `regc` last sent over (`pjsip_regc_info.transport`), as an address: compared,
/// never dereferenced, outside the callback that read it.
private func sessionTransport(_ regc: OpaquePointer?) -> UInt? {
    guard let regc else { return nil }
    var state = pjsip_regc_info()
    guard pjsip_regc_get_info(regc, &state).isSuccess, let transport = state.transport else {
        return nil
    }
    return UInt(bitPattern: transport)
}

/// The Contact URIs a REGISTER response listed, printed as pjsip prints them. Reads the parsed
/// response only: plain fields and formatting, nothing that takes a lock or enters pjsua.
private func registrarBindings(_ param: pjsip_regc_cbparam) -> [String] {
    var param = param
    let count = Int(min(max(param.contact_cnt, 0), Int32(PJSIP_REGC_MAX_CONTACT)))
    guard count > 0 else { return [] }
    return withUnsafePointer(to: &param.contact) { tuple in
        tuple.withMemoryRebound(to: UnsafeMutablePointer<pjsip_contact_hdr>?.self,
                                capacity: count) { headers in
            (0..<count).compactMap { index in
                // A "Contact: *" header has no URI.
                guard let uri = headers[index]?.pointee.uri else { return nil }
                var buffer = [CChar](repeating: 0, count: Int(PJSIP_MAX_URL_SIZE))
                let length = pjsip_uri_print(PJSIP_URI_IN_CONTACT_HDR, uri, &buffer, buffer.count)
                guard length > 0 else { return nil }
                return String(decoding: buffer[..<Int(length)].map { UInt8(bitPattern: $0) },
                              as: UTF8.self)
            }
        }
    }
}

/// `on_call_transfer_status` — REFER progress on the *transferor* leg. `pCont` stays
/// `PJ_TRUE` so the NOTIFY subscription reports through `final`; the app decides what to
/// do with the stream (it can't reach back into this callback anyway).
private func pjsuaOnCallTransferStatus(_ callId: pjsua_call_id,
                                       _ stCode: Int32,
                                       _ stText: UnsafePointer<pj_str_t>?,
                                       _ final: pj_bool_t,
                                       _ pCont: UnsafeMutablePointer<pj_bool_t>?) {
    assertOnRegisteredPJThread()
    pCont?.pointee = true.pjBool
    emitCall(.callTransferStatus(
        call: CallID(callId),
        statusCode: stCode,
        statusText: stText?.pointee.string ?? "",
        isFinal: final != 0
    ))
}

/// `on_call_replaced` — the *transferee* side: an incoming INVITE-with-Replaces took over
/// `old_call_id`; `new_call_id` is the call that replaced it (pjsua answers it itself).
private func pjsuaOnCallReplaced(_ oldCallId: pjsua_call_id, _ newCallId: pjsua_call_id) {
    assertOnRegisteredPJThread()
    emitCall(.callReplaced(call: CallID(oldCallId), newCall: CallID(newCallId)))
}

/// `on_ip_change_progress` — per-step progress of a `handleIPChange()` sequence. The
/// `info` union member is read only for the op that fills it; everything lands on the
/// guaranteed channel (the sequence is rare and lifecycle-relevant — diagnostics want it).
private func pjsuaOnIPChangeProgress(_ op: pjsua_ip_change_op,
                                     _ status: pj_status_t,
                                     _ info: UnsafePointer<pjsua_ip_change_op_info>?) {
    assertOnRegisteredPJThread()
    var operation: IPChangeOperation
    var account: AccountID?
    var call: CallID?
    var transportID: Int32?
    switch op {
    case PJSUA_IP_CHANGE_OP_SHUTDOWN_TP:
        operation = .shutdownTransport
    case PJSUA_IP_CHANGE_OP_RESTART_LIS:
        operation = .restartListener
        transportID = info.map { Int32($0.pointee.lis_restart.transport_id) }
    case PJSUA_IP_CHANGE_OP_ACC_SHUTDOWN_TP:
        operation = .accountShutdownTransport
        account = info.map { AccountID($0.pointee.acc_shutdown_tp.acc_id) }
    case PJSUA_IP_CHANGE_OP_ACC_UPDATE_CONTACT:
        operation = .accountUpdateContact
        account = info.map { AccountID($0.pointee.acc_update_contact.acc_id) }
    case PJSUA_IP_CHANGE_OP_ACC_HANGUP_CALLS:
        operation = .accountHangupCalls
        account = info.map { AccountID($0.pointee.acc_hangup_calls.acc_id) }
        call = info.map { CallID($0.pointee.acc_hangup_calls.call_id) }
    case PJSUA_IP_CHANGE_OP_ACC_REINVITE_CALLS:
        operation = .accountReinviteCalls
        account = info.map { AccountID($0.pointee.acc_reinvite_calls.acc_id) }
        call = info.map { CallID($0.pointee.acc_reinvite_calls.call_id) }
    case PJSUA_IP_CHANGE_OP_COMPLETED:
        operation = .completed
        // Ends the engine's IP-change operation, which holds every account's registration still.
        pjsuaRegistrationSink?.yield(.ipChangeCompleted)
    default:
        operation = .unknown
    }
    emitCall(.ipChangeProgress(operation: operation, status: Int32(status),
                               account: account, call: call, transportID: transportID))
}

/// `on_transport_state` — a SIP transport changed state. It runs before pjsua's own handler, in
/// several contexts (`docs/Threading-Validation.md`, addendum 2026-10-11 (b)): on the worker for a
/// socket error, a failed keep-alive or a connect; on the sending thread, the engine's included,
/// when an immediate send fails; and, for the shutdown that follows a disconnection or comes with
/// an IP change, with the transport manager's and the transport's locks held. So it reads the
/// transport's fixed fields, takes only its own leaf lock, and yields.
private func pjsuaOnTransportState(_ transport: UnsafeMutablePointer<pjsip_transport>?,
                                   _ state: pjsip_transport_state,
                                   _ info: UnsafePointer<pjsip_transport_state_info>?) {
    assertOnRegisteredPJThread()
    guard let transport else { return }
    let newState = TransportState(state)
    let address = UInt(bitPattern: transport)
    registrationTransportLock.lock()
    let accounts = registrationTransports.filter { $0.value == address }.map(\.key).sorted()
    if newState == .disconnected || newState == .destroyed {
        for account in accounts { registrationTransports[account] = nil }
    }
    registrationTransportLock.unlock()

    let remote = transport.pointee.remote_name
    emitCall(.transportState(TransportStateChange(
        transport: TransportInstanceID(transport),
        state: newState,
        status: info?.pointee.status ?? 0,
        type: transport.pointee.type_name.map { String(cString: $0) } ?? "?",
        remote: "\(remote.host.string ?? ""):\(remote.port)",
        registeredAccounts: accounts.map(AccountID.init),
        tlsVerifyStatus: tlsVerifyStatus(transport, info)
    )))
}

/// The peer certificate's verify status on a TLS transport. pjsip sets `ext_info` to a
/// `pjsip_tls_state_info` for TLS connects and disconnections, when the socket can still be read
/// (`sip_transport_tls.c`, `tls_init_shutdown`); never for other transports.
private func tlsVerifyStatus(_ transport: UnsafeMutablePointer<pjsip_transport>,
                             _ info: UnsafePointer<pjsip_transport_state_info>?) -> UInt32? {
    let type = pjsip_transport_type_e(rawValue: UInt32(truncatingIfNeeded: transport.pointee.key.type))
    guard type == PJSIP_TRANSPORT_TLS || type == PJSIP_TRANSPORT_TLS6,
          let tls = info?.pointee.ext_info?.assumingMemoryBound(to: pjsip_tls_state_info.self)
    else { return nil }
    return tls.pointee.ssl_sock_info?.pointee.verify_status
}

/// `on_rejected_incoming_call` — pjsua refused an incoming INVITE itself, so `on_incoming_call`
/// never fires for it. Worker thread, `PJSUA_LOCK` held. `rdata` is valid only here, so the
/// Call-ID is read now: a VoIP push reported the call under it (`SwiftPJSUAKit`).
private func pjsuaOnRejectedIncomingCall(
    _ param: UnsafePointer<pjsua_on_rejected_incoming_call_param>?
) {
    assertOnRegisteredPJThread()
    guard let param else { return }
    emitCall(.incomingCallRejected(
        call: param.pointee.call_id >= 0 ? CallID(param.pointee.call_id) : nil,
        sipCallID: param.pointee.rdata?.pointee.msg_info.cid?.pointee.id.string,
        from: param.pointee.remote_info.string,
        statusCode: param.pointee.st_code,
        statusText: param.pointee.st_text.string ?? ""
    ))
}
