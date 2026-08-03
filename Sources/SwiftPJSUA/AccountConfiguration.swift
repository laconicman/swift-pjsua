/// Everything the engine needs to add a SIP account **except its secret**.
///
/// Secrets are absent by construction, which is what makes this type safe to make `Codable`: an
/// app can persist it (JSON, `UserDefaults`, SwiftData) with no way to accidentally serialise a
/// password. The matching secret is supplied separately by a ``CredentialStore``.
///
/// Fields land here as their engine support lands; see `docs/Configuration-Design.md` for the
/// target shape (outbound proxies and `reg_use_proxy` — TD-16; per-account ICE/TURN overrides —
/// TD-14). A config field the engine silently ignored would be worse than one that does not exist.
public struct AccountConfiguration: Sendable, Codable, Equatable {

    /// The account's SIP URI, e.g. `"sip:alice@example.com"`.
    public var id: String

    /// Registrar URI, e.g. `"sip:example.com"` — the Request-URI of REGISTER. Independent of any
    /// outbound proxy (which is a `Route` header, not the target).
    public var registrar: String

    /// Digest username.
    public var username: String

    /// Digest realm; `"*"` matches any realm the server challenges with.
    public var realm: String

    /// Pins this account to a ``TransportConfiguration/name`` declared in
    /// ``PJSUA/Configuration/transports``, mapping to `pjsua_acc_config.transport_id`.
    ///
    /// `nil` — the default and the recommended setting — lets the stack choose from the URI
    /// scheme and any `;transport=` parameter.
    ///
    /// - Warning: pinning is stricter than it looks, in two ways.
    ///   1. **A mismatch is a hard error, not a fallback.** If the pin says UDP and a target URI
    ///      says `;transport=tcp`, `pjsip_process_route_set` fails the request with
    ///      `PJSIP_ETPNOTSUITABLE` ("Unsuitable transport selected to reach destination").
    ///      Keep the pin consistent with `registrar` and any proxy URIs.
    ///   2. **Pinning a UDP transport disables the RFC 3261 §18.1.1 size upgrade** — the very
    ///      thing that keeps an oversized authenticated INVITE off UDP. The upgrade inserts TCP
    ///      candidates, but the UDP pin makes acquiring them fail, so the stack falls back to
    ///      UDP and the request fragments (pjsip/pjproject#5075). Pinning a *TCP* transport is
    ///      safe: it selects a listener, so everything goes over TCP and the upgrade is moot.
    public var transportName: String?

    /// Optional RFC 8599 push parameters (see ``PushConfiguration``).
    public var push: PushConfiguration?

    /// Make this the default account for outbound calls.
    public var isDefault: Bool

    public init(id: String,
                registrar: String,
                username: String,
                realm: String = "*",
                transportName: String? = nil,
                push: PushConfiguration? = nil,
                isDefault: Bool = true) {
        self.id = id
        self.registrar = registrar
        self.username = username
        self.realm = realm
        self.transportName = transportName
        self.push = push
        self.isDefault = isDefault
    }

    /// The lookup this account's secret is fetched with.
    var credentialRequest: CredentialRequest {
        CredentialRequest(accountID: id, username: username, realm: realm)
    }
}
