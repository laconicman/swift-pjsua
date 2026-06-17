import PJSIP

/// The INVITE-session lifecycle, mirrored from `pjsip_inv_state` so callers don't have to
/// import the C enum. The `pj_status_t` returned by `pjsua_call_make_call` only tells you
/// the INVITE was *sent*; the real lifecycle arrives as these states via `PJSUA.events`.
public enum CallState: Sendable, Equatable {
    case null, calling, incoming, early, connecting, confirmed, disconnected
    case unknown(Int32)

    init(_ state: pjsip_inv_state) {
        switch state {
        case PJSIP_INV_STATE_NULL:         self = .null
        case PJSIP_INV_STATE_CALLING:      self = .calling
        case PJSIP_INV_STATE_INCOMING:     self = .incoming
        case PJSIP_INV_STATE_EARLY:        self = .early
        case PJSIP_INV_STATE_CONNECTING:   self = .connecting
        case PJSIP_INV_STATE_CONFIRMED:    self = .confirmed
        case PJSIP_INV_STATE_DISCONNECTED: self = .disconnected
        default:                           self = .unknown(Int32(state.rawValue))
        }
    }
}
