/// One SIP listening transport the engine should create at ``PJSUA/start(_:)``.
///
/// Ports belong to *transports*, not to accounts: pjsua creates each transport independently and
/// hands back a `pjsua_transport_id`, which an account may then pin
/// (``AccountConfiguration/transportName``). That is why this type carries a **stable name** —
/// transport ids are runtime values and must never leak into persisted configuration.
///
/// Replaces the earlier single `port` + `transport` pair, which could not express a per-transport
/// port (Tech-Debt TD-18).
public struct TransportConfiguration: Sendable, Codable, Equatable, Identifiable {

    /// Stable, app-chosen label used to reference this transport from an account.
    public var name: String

    /// UDP / TCP / TLS.
    public var kind: Transport

    /// Listening port. `0` binds an ephemeral port. Defaults to the IANA port for `kind`
    /// — 5060 for UDP and TCP, 5061 for TLS (RFC 3261 §19.1.2).
    public var port: UInt32

    public var id: String { name }

    /// - Parameter port: omit to use `kind`'s IANA default.
    public init(_ name: String, _ kind: Transport, port: UInt32? = nil) {
        self.name = name
        self.kind = kind
        self.port = port ?? kind.defaultPort
    }
}
