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
}
