import PJSIP

/// SIP transport to create. Maps to PJSIP's `pjsip_transport_type_e`.
public enum Transport: Sendable, Codable, Equatable, CaseIterable {
    case udp, tcp, tls

    /// IANA default listening port: 5060 for UDP/TCP, 5061 for TLS (RFC 3261 §19.1.2).
    public var defaultPort: UInt32 { self == .tls ? 5061 : 5060 }

    var pjType: pjsip_transport_type_e {
        switch self {
        case .udp: return PJSIP_TRANSPORT_UDP
        case .tcp: return PJSIP_TRANSPORT_TCP
        case .tls: return PJSIP_TRANSPORT_TLS
        }
    }
}
