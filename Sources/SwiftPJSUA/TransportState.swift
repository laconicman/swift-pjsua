import PJSIP

/// The state a ``TransportStateChange`` reports (`pjsip_transport_state`).
public enum TransportState: Sendable, Equatable {
    /// Connected: TCP, or TLS after its handshake.
    case connected
    /// The connection failed or closed. pjsua shuts the transport down next.
    case disconnected
    /// Shutting down: no new request goes over it, and it is destroyed once its last user lets
    /// go. An IP change shuts every TCP/TLS transport down.
    case shutdown
    /// Destroyed. Its ``TransportInstanceID`` may be reused after this.
    case destroyed
    /// A `pjsip_transport_state` this build does not know.
    case unknown

    init(_ state: pjsip_transport_state) {
        switch state {
        case PJSIP_TP_STATE_CONNECTED:    self = .connected
        case PJSIP_TP_STATE_DISCONNECTED: self = .disconnected
        case PJSIP_TP_STATE_SHUTDOWN:     self = .shutdown
        case PJSIP_TP_STATE_DESTROY:      self = .destroyed
        default:                          self = .unknown
        }
    }
}
