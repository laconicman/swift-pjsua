import PJSIP

/// Events surfaced from PJSUA's internal worker-thread callbacks, delivered to the app via
/// ``PJSUA/events`` (an `AsyncStream`). This is the clean boundary: the C callbacks
/// translate to plain `Sendable` values and never touch app/UI state directly.
///
/// Several cases carry the SIP `Call-ID` (`sipCallID`). The GUI layer needs it to compute
/// a stable CallKit UUID so a VoIP push and the matching INVITE over a persisted
/// connection resolve to the *same* call (no double ring). See `SwiftPJSUAKit`.
public enum PJSUAEvent: Sendable {
    /// Registration state changed. `statusCode` is the SIP response code (e.g.
    /// `PJSIP_SC_OK` / 200, 401, 403),
    /// `expiration` the next re-registration interval in seconds (0 when unregistered).
    case registrationState(account: AccountID, active: Bool, statusCode: Int32, expiration: UInt32)

    /// A new inbound INVITE arrived. `sipCallID` is the SIP `Call-ID` header value, `from`
    /// the remote party's display info/URI (for the CallKit handle on the socket path), and
    /// `offeredVideo` is `true` when the offer contains a video stream (drives
    /// `CXCallUpdate.hasVideo`).
    case incomingCall(account: AccountID, call: CallID, sipCallID: String?,
                      from: String?, offeredVideo: Bool)

    /// The INVITE-session state changed. `lastStatus` is the SIP status of the last event
    /// on the call (e.g. `PJSIP_SC_REQUEST_TERMINATED` / 487 when the caller CANCELs before
    /// answer, `PJSIP_SC_OK` / 200 on success);
    /// `sipCallID` is the SIP `Call-ID` header value.
    case callState(call: CallID, state: CallState, sipCallID: String?, lastStatus: Int32)

    /// The call's media changed. Carries the full **per-stream** vector (`media[i]`), emitted
    /// on every `on_call_media_state` transition (initial SDP and every re-INVITE — hold,
    /// unhold, add-video). The engine surfaces all streams and the app/router decides what
    /// matters — mirroring how PJSUA2's `onCallMediaState` hands the app `CallInfo.media[]`
    /// and lets it react per stream (audio → conference slot, video → window). The engine
    /// still performs the low-level audio conference-bridge wiring itself; see
    /// `pjsuaOnCallMediaState`.
    case callMediaState(call: CallID, media: [CallMediaInfo])
}
