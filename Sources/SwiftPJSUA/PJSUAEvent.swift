import PJSIP

/// Events surfaced from PJSUA's internal worker-thread callbacks, delivered to the app via
/// ``PJSUA/events`` (an `AsyncStream`). This is the clean boundary: the C callbacks
/// translate to plain `Sendable` values and never touch app/UI state directly.
///
/// Several cases carry the SIP `Call-ID` (`sipCallID`). The GUI layer needs it to compute
/// a stable CallKit UUID so a VoIP push and the matching INVITE over a persisted
/// connection resolve to the *same* call (no double ring). See `SwiftPJSUAKit`.
public enum PJSUAEvent: Sendable {
    /// Registration state changed. `statusCode` is the SIP status (e.g. 200, 401, 403),
    /// `expiration` the next re-registration interval in seconds (0 when unregistered).
    case registrationState(account: AccountID, active: Bool, statusCode: Int32, expiration: UInt32)

    /// A new inbound INVITE arrived. `sipCallID` is the SIP `Call-ID` header value.
    case incomingCall(account: AccountID, call: CallID, sipCallID: String?)

    /// The INVITE-session state changed. `lastStatus` is the SIP status of the last event
    /// on the call (e.g. 487 when the caller CANCELs before answer, 200 on success);
    /// `sipCallID` is the SIP `Call-ID` header value.
    case callState(call: CallID, state: CallState, sipCallID: String?, lastStatus: Int32)

    /// The call's media status changed. Emitted on **every** transition (not filtered to
    /// "active"): the engine surfaces the full status and the app decides what matters —
    /// mirroring how PJSUA2's `onCallMediaState` hands the app the complete media info and
    /// lets it react (e.g. reflect `remoteHold` in the UI, stop a ringback on `active`).
    /// The engine still performs the low-level conference-bridge wiring itself; see
    /// `pjsuaOnCallMediaState`.
    case callMediaState(call: CallID, status: CallMediaStatus)
}
