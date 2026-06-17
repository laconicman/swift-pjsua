import PJSIP

extension PJSUA {
    // MARK: Calls

    /// Place an outbound call. The returned ``CallID`` means the INVITE was *sent*; the
    /// answered/failed outcome arrives via ``events`` as `.callState`.
    @discardableResult
    public func makeCall(to uri: String, from account: AccountID) throws -> CallID {
        precondition(state == .running, "start() must complete before makeCall()")
        var opt = pjsua_call_setting()
        pjsua_call_setting_default(&opt)

        var callId: pjsua_call_id = -1 // PJSUA_INVALID_ID
        let status = uri.withPJStr { dst -> pj_status_t in
            // pjsua_call_make_call parses/copies the URI during the call, so a pointer
            // valid for the duration of withPJStr is sufficient.
            pjsua_call_make_call(account.raw, &dst, &opt, nil, nil, &callId)
        }
        try status.throwIfFailed()
        return CallID(callId)
    }

    /// Answer an incoming call (default 200 OK).
    public func answer(_ call: CallID, statusCode: UInt32 = 200) throws {
        try pjsua_call_answer(call.raw, statusCode, nil, nil).throwIfFailed()
    }

    /// Hang up a call (default 603 Decline; use 486 Busy, 487 Cancelled, etc.).
    public func hangup(_ call: CallID, statusCode: UInt32 = 603) throws {
        try pjsua_call_hangup(call.raw, statusCode, nil, nil).throwIfFailed()
    }

    /// Hang up every active call.
    public func hangupAll() {
        pjsua_call_hangup_all()
    }

    // MARK: Mid-call control

    /// Put a call on hold. Sends a re-INVITE with `sendonly`/`inactive` SDP
    /// (`pjsua_call_set_hold`). The resulting media transition arrives via ``events`` as
    /// `.callMediaState`; the GUI layer fulfils a `CXSetHeldCallAction` only once it observes
    /// that change (the action models intent, the media event confirms the outcome).
    public func setHold(_ call: CallID) throws {
        try pjsua_call_set_hold(call.raw, nil).throwIfFailed()
    }

    /// Release a hold. Sends a re-INVITE with the `PJSUA_CALL_UNHOLD` flag, restoring
    /// `sendrecv` (`pjsua_call_reinvite`). Like ``setHold(_:)`` the change is confirmed via a
    /// subsequent `.callMediaState` event rather than synchronously.
    public func resume(_ call: CallID) throws {
        // PJSUA_CALL_UNHOLD == 1 — the header pins this flag to 1 for backward compatibility
        // (pjsua.h, pjsua_call_flag). Integer literal + symbol comment per codebase
        // convention (C-enum .rawValue interop is avoided so the package builds on Linux too).
        try pjsua_call_reinvite(call.raw, 1, nil).throwIfFailed()
    }

    /// Mute or unmute the local microphone for a call by (dis)connecting the capture device
    /// (conference slot 0) and the call's conference port (`pjsua_call_get_conf_port`). This
    /// is a purely local conference re-wiring — no SIP signalling — so it is instantaneous
    /// and a `CXSetMutedCallAction` can be fulfilled immediately. Remote audio keeps playing
    /// while muted (we only drop the capture -> call direction).
    public func setMute(_ call: CallID, muted: Bool) throws {
        let port = pjsua_call_get_conf_port(call.raw)
        guard port >= 0 else { throw PJSUAUsageError.callHasNoMediaPort(call) } // PJSUA_INVALID_ID == -1
        let status = muted ? pjsua_conf_disconnect(0, port) : pjsua_conf_connect(0, port)
        try status.throwIfFailed()
    }

    /// Send DTMF `digits` for the call. Uses `pjsua_call_dial_dtmf2`, i.e. in-band RFC 2833
    /// telephone-event signalling. `duration` is per-digit in milliseconds; 0 uses PJSIP's
    /// default duration.
    public func sendDTMF(_ call: CallID, digits: String, duration: UInt32 = 0) throws {
        let status = digits.withPJStr { d -> pj_status_t in
            pjsua_call_dial_dtmf2(call.raw, &d, duration)
        }
        try status.throwIfFailed()
    }
}
