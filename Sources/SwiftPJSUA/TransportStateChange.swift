/// A SIP transport changed state (pjsua's `on_transport_state`): for TCP and TLS, a connection
/// came up, went down, is shutting down, or was destroyed.
///
/// pjsip reports this per `pjsip_transport` and **before pjsua's own handler runs**
/// (`pjsua_core.c`, `on_tp_state_callback`). On ``TransportState/disconnected`` that handler then
/// releases the connection from every registration that used it, downgrades SIP outbound and arms
/// an automatic retry, and reports none of it (`docs/Tech-Debt.md` TD-31). An established call
/// over the connection is not told either: its dialog has no transport listener
/// (`docs/Call-Termination-Paths.md` §4).
///
/// A connection the OS closed while the app was suspended is reported only when pjsip next reads
/// or sends on it, a REGISTER or the 90 s keep-alive, not on resume (TD-24).
public struct TransportStateChange: Sendable, Equatable {
    /// The connection. An identity across its events until ``TransportState/destroyed``.
    public let transport: TransportInstanceID
    public let state: TransportState
    /// The `pj_status_t` pjsip reported: the socket error for a disconnection, `PJ_ECANCELLED`
    /// for a shutdown.
    public let status: Int32
    /// pjsip's type name for the transport: `"UDP"`, `"TCP"` or `"TLS"`.
    public let type: String
    /// The peer, as `host:port`.
    public let remote: String
    /// The accounts whose registration went over this connection at its last 2xx. This is the
    /// only report of which accounts a ``TransportState/disconnected`` takes down: pjsua's handler,
    /// which runs right after, releases the connection from their sessions. Empty on
    /// ``TransportState/connected``, because a connection is matched to an account at the
    /// registrar's answer, which comes later.
    public let registeredAccounts: [AccountID]
    /// For TLS, the peer certificate's `pj_ssl_sock_info.verify_status`: 0 when it verified,
    /// `pj_ssl_cert_verify_flag_t` bits otherwise. `nil` for other transports, and for TLS when
    /// pjsip had no socket left to read it from.
    public let tlsVerifyStatus: UInt32?
}
