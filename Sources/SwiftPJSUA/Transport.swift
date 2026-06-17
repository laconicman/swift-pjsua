import PJSIP

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
