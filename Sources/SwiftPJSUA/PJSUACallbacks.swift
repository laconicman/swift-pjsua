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
// `Sendable` ``PJSUAEvent``. Because they cannot reach the actor, they physically cannot
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
//   held under PJSUA_LOCK  : on_reg_state, on_reg_state2, on_ip_change_progress,
//                            on_incoming_call
//   no PJSUA_LOCK, but the dialog/tsx grp_lock is held upstream:
//                            on_call_state, on_call_tsx_terminate_session, on_mwi_state,
//                            on_auth_challenge
//
// Documented lock order is PJSUA_LOCK > dialog grp_lock > tsx grp_lock, so calling *up* that
// order from inside a callback is an ABBA inversion. `on_call_tsx_terminate_session`'s own
// header says the app MUST NOT call any API acquiring a higher-order lock from within it.
//
// Forward note for the credential work: `on_auth_challenge` (PJSIP 2.17+) is invoked with the
// tsx grp_lock held and must NOT acquire PJSUA_LOCK. If we adopt it to supply secrets on demand
// (see docs/Configuration-Design.md §4), the fetch must use its **async/deferred** path —
// `pjsip_auth_clt_async_send_req` after the secret arrives — never a synchronous Keychain read
// inside the callback.
//
// Full findings: docs/Threading-Validation.md.
//
// `nonisolated(unsafe)` invariant: written exactly once via ``makePJSUAEventStreams()`` in
// `PJSUA.init`, before `pjsua_start()` can fire any callback; read-only thereafter.
// `AsyncStream.Continuation` is `Sendable` and its `yield` is thread-safe, so yielding
// from PJSUA's worker-thread callbacks is safe. Removal plan: when pjsua gains per-instance
// user-data on these callbacks, replace the global with that.
private nonisolated(unsafe) var pjsuaEventSink: AsyncStream<PJSUAEvent>.Continuation?
private nonisolated(unsafe) var pjsuaCallEventSink: AsyncStream<PJSUAEvent>.Continuation?

/// Process-global sink for pjsip's own log lines (`pjsua_logging_config.cb`). Same
/// `nonisolated(unsafe)` invariant as the event sinks, with a narrower window: written once
/// in `PJSUA.start(_:)` before `pjsua_init` can produce a line, cleared in `shutdown` after
/// `pjsua_destroy` has stopped the threads that would call it. Called from arbitrary pjsip
/// threads at console volume — the callback does as little as possible before yielding to
/// the sink.
nonisolated(unsafe) var pjsuaLogSink: (@Sendable (Int32, String) -> Void)?

/// `pjsua_logging_config.cb` — level-gated by `logging_config.level`, fired on whichever
/// pjsip thread emitted the line. `data` is NOT NUL-terminated; `len` is authoritative.
/// The closure above is non-capturing, so it converts to `@convention(c)` automatically.
func pjsuaOnLog(_ level: Int32, _ data: UnsafePointer<CChar>?, _ len: Int32) {
    guard let sink = pjsuaLogSink, let data, len > 0 else { return }
    let text = String(decoding: UnsafeRawBufferPointer(start: UnsafeRawPointer(data),
                                                       count: Int(len)),
                      as: UTF8.self)
    sink(level, text)
}

/// Create the two event streams and install their continuations as the process-global
/// sinks. Called once from `PJSUA.init` before anything can start delivering callbacks.
///
/// Two channels, two contracts (TD-3):
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
func makePJSUAEventStreams() -> (events: AsyncStream<PJSUAEvent>,
                                callEvents: AsyncStream<PJSUAEvent>) {
    let (events, eventsContinuation) = AsyncStream<PJSUAEvent>.makeStream(
        bufferingPolicy: .bufferingNewest(64))
    let (callEvents, callContinuation) = AsyncStream<PJSUAEvent>.makeStream()
    pjsuaEventSink = eventsContinuation
    pjsuaCallEventSink = callContinuation
    return (events, callEvents)
}

/// Finish the event streams (called from `PJSUA.shutdown`). Also resets the registration
/// dedup state — a restarted engine's account slots are fresh, so stale tuples must not
/// suppress the first reports of a new engine lifetime.
func finishPJSUAEventStreams() {
    pjsuaEventSink?.finish()
    pjsuaCallEventSink?.finish()
    regDedupLock.lock()
    lastEmittedRegState.removeAll()
    regDedupLock.unlock()
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
    cfg.cb.on_call_state       = { callId, ev    in pjsuaOnCallState(callId, ev) }
    cfg.cb.on_incoming_call    = { acc, callId, rx in pjsuaOnIncomingCall(acc, callId, rx) }
    cfg.cb.on_call_media_state = { callId        in pjsuaOnCallMediaState(callId) }
    cfg.cb.on_reg_state2       = { acc, info     in pjsuaOnRegState2(acc, info) }
    cfg.cb.on_stream_destroyed = { callId, strm, idx in pjsuaOnStreamDestroyed(callId, strm, idx) }
    cfg.cb.on_call_media_event = { callId, medIdx, ev in pjsuaOnCallMediaEvent(callId, medIdx, ev) }
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
}
