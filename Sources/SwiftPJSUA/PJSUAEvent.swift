import PJSIP

/// Opaque, type-safe handle for a PJSUA call (wraps `pjsua_call_id`, an `Int32`).
public struct CallID: Hashable, Sendable, CustomStringConvertible {
    public let raw: pjsua_call_id
    init(_ raw: pjsua_call_id) { self.raw = raw }
    public var description: String { "call#\(raw)" }
}

/// Opaque, type-safe handle for a PJSUA account (wraps `pjsua_acc_id`, an `Int32`).
public struct AccountID: Hashable, Sendable, CustomStringConvertible {
    public let raw: pjsua_acc_id
    init(_ raw: pjsua_acc_id) { self.raw = raw }
    public var description: String { "acc#\(raw)" }
}

/// SIP transport to create. Maps to PJSIP's `pjsip_transport_type_e`.
public enum Transport: Sendable {
    case udp, tcp, tls
    var pjType: pjsip_transport_type_e {
        switch self {
        case .udp: return PJSIP_TRANSPORT_UDP
        case .tcp: return PJSIP_TRANSPORT_TCP
        case .tls: return PJSIP_TRANSPORT_TLS
        }
    }
}

/// The INVITE-session lifecycle, mirrored from `pjsip_inv_state` so callers don't
/// import the C enum. The raw value of `pjsip_call_make_call` tells you the INVITE was
/// *sent*; the real lifecycle arrives as these states via `PJSUA.events`.
public enum CallState: Sendable {
    case null, calling, incoming, early, connecting, confirmed, disconnected, unknown(Int32)

    init(_ s: pjsip_inv_state) {
        switch s {
        case PJSIP_INV_STATE_NULL:       self = .null
        case PJSIP_INV_STATE_CALLING:    self = .calling
        case PJSIP_INV_STATE_INCOMING:   self = .incoming
        case PJSIP_INV_STATE_EARLY:      self = .early
        case PJSIP_INV_STATE_CONNECTING: self = .connecting
        case PJSIP_INV_STATE_CONFIRMED:  self = .confirmed
        case PJSIP_INV_STATE_DISCONNECTED: self = .disconnected
        default: self = .unknown(s.rawValue)
        }
    }
}

/// Events surfaced from PJSUA's internal worker-thread callbacks, delivered to the
/// app via `PJSUA.events` (an `AsyncStream`). This is the clean boundary: the C
/// callbacks translate to POD `Sendable` values and never touch app/UI state directly.
public enum PJSUAEvent: Sendable {
    case registrationState(AccountID, active: Bool, statusCode: Int32)
    case incomingCall(AccountID, CallID)
    case callState(CallID, CallState)
    case callMediaActive(CallID)
}
