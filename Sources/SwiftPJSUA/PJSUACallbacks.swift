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
// `nonisolated(unsafe)` invariant: written exactly once via ``makePJSUAEventStream()`` in
// `PJSUA.init`, before `pjsua_start()` can fire any callback; read-only thereafter.
// `AsyncStream.Continuation` is `Sendable` and its `yield` is thread-safe, so yielding
// from PJSUA's worker-thread callbacks is safe. Removal plan: when pjsua gains per-instance
// user-data on these callbacks, replace the global with that.
private nonisolated(unsafe) var pjsuaEventSink: AsyncStream<PJSUAEvent>.Continuation?

/// Create the event stream and install its continuation as the process-global sink.
/// Called once from `PJSUA.init` before anything can start delivering callbacks.
func makePJSUAEventStream() -> AsyncStream<PJSUAEvent> {
    let (stream, continuation) = AsyncStream<PJSUAEvent>.makeStream(
        bufferingPolicy: .bufferingNewest(64)
    )
    pjsuaEventSink = continuation
    return stream
}

/// Finish the event stream (called from `PJSUA.shutdown`).
func finishPJSUAEventStream() {
    pjsuaEventSink?.finish()
}

/// Wire the file-private C callbacks into a `pjsua_config`. The closures are
/// non-capturing (they only reference these file-private free functions), so they
/// convert to `@convention(c)` function pointers automatically.
func installPJSUACallbacks(into cfg: inout pjsua_config) {
    cfg.cb.on_call_state       = { callId, ev    in pjsuaOnCallState(callId, ev) }
    cfg.cb.on_incoming_call    = { acc, callId, rx in pjsuaOnIncomingCall(acc, callId, rx) }
    cfg.cb.on_call_media_state = { callId        in pjsuaOnCallMediaState(callId) }
    cfg.cb.on_reg_state2       = { acc, info     in pjsuaOnRegState2(acc, info) }
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
    pjsuaEventSink?.yield(.callState(
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
    // a VoIP push against the INVITE that follows it over a persisted connection).
    var info = pjsua_call_info()
    let sipCallID = pjsua_call_get_info(callId, &info).isSuccess ? info.call_id.string : nil
    pjsuaEventSink?.yield(.incomingCall(
        account: AccountID(accId),
        call: CallID(callId),
        sipCallID: sipCallID
    ))
}

private func pjsuaOnCallMediaState(_ callId: pjsua_call_id) {
    assertOnRegisteredPJThread()
    var info = pjsua_call_info()
    guard pjsua_call_get_info(callId, &info).isSuccess else { return }

    // When the primary stream is active, bridge the call's conference slot to the sound
    // device (conference slot 0): remote audio → local playback, local capture → remote.
    // Slot 0 is the device port; with iOS's null-sound-device model it is wired to the
    // real hardware only while CallKit has activated the audio session (see SwiftPJSUAKit).
    // MVP handles the single `conf_slot`; multi-stream/video calls iterate `media[]` later.
    if info.media_status == PJSUA_CALL_MEDIA_ACTIVE {
        let slot = info.conf_slot
        pjsua_conf_connect(slot, 0)
        pjsua_conf_connect(0, slot)
    }
    pjsuaEventSink?.yield(.callMediaActive(call: CallID(callId)))
}

private func pjsuaOnRegState2(_ accId: pjsua_acc_id, _ info: UnsafeMutablePointer<pjsua_reg_info>?) {
    assertOnRegisteredPJThread()
    guard let regInfo = info?.pointee else {
        pjsuaEventSink?.yield(.registrationState(
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
    let active = renewing && (200..<300).contains(statusCode) && expiration > 0
    pjsuaEventSink?.yield(.registrationState(
        account: AccountID(accId),
        active: active,
        statusCode: statusCode,
        expiration: expiration
    ))
}
