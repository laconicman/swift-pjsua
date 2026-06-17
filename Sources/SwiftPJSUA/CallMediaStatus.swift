import PJSIP

/// The media status of a call's primary stream, mirrored from `pjsua_call_media_status` so
/// callers don't have to import the C enum.
///
/// The engine surfaces **every** transition (`PJSUAEvent.callMediaState`) rather than
/// filtering to "active only": which transitions matter is the app's decision, exactly as
/// PJSUA2 exposes the full `CallMediaInfo` vector from `onCallMediaState` and lets the app
/// react. The engine still owns the low-level conference-bridge wiring (see
/// `pjsuaOnCallMediaState`); this enum is the higher-level signal the app reasons about
/// (e.g. reflect remote hold in the UI, stop a ringback on active).
public enum CallMediaStatus: Sendable, Equatable {
    /// No media yet, or media not used.
    case none
    /// Media is flowing.
    case active
    /// Put on hold by the local endpoint.
    case localHold
    /// Put on hold by the remote endpoint.
    case remoteHold
    /// Media reported an error (e.g. ICE negotiation failed).
    case error
    /// A status value newer than this enum knows about; carries the raw C value.
    case unknown(Int32)

    init(_ status: pjsua_call_media_status) {
        switch status {
        case PJSUA_CALL_MEDIA_NONE:        self = .none
        case PJSUA_CALL_MEDIA_ACTIVE:      self = .active
        case PJSUA_CALL_MEDIA_LOCAL_HOLD:  self = .localHold
        case PJSUA_CALL_MEDIA_REMOTE_HOLD: self = .remoteHold
        case PJSUA_CALL_MEDIA_ERROR:       self = .error
        default:                           self = .unknown(Int32(status.rawValue))
        }
    }
}
