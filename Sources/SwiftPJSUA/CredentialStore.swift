/// Identifies *which* secret the engine needs. Carries no secret itself, so it is safe to log.
public struct CredentialRequest: Sendable, Equatable {
    /// The account's SIP URI (``AccountConfiguration/id``).
    public let accountID: String
    /// Digest username.
    public let username: String
    /// Digest realm, or `"*"` to match any.
    public let realm: String

    public init(accountID: String, username: String, realm: String) {
        self.accountID = accountID
        self.username = username
        self.realm = realm
    }
}

/// Supplies account secrets to the engine **on demand**.
///
/// The engine retains the *store*, never the secret, so ``AccountConfiguration`` stays free of
/// credentials and can be persisted (it is `Codable`) with no risk of writing a password to disk.
/// The store is consulted when an account is added and again whenever its config is rebuilt
/// (``PJSUA/reRegister(_:updatingPush:)``).
///
/// - Important: implementations must **not** block the caller's executor — the engine's executor
///   is a single PJLIB-registered thread that also runs SIP. Keychain reads gated on user presence
///   can take seconds. Under the Swift 5 language mode a `nonisolated async` requirement invoked
///   from the actor already runs on the global executor; if this package later adopts Swift 6.2's
///   `NonisolatedNonsendingByDefault`, this requirement must gain `@concurrent` to keep that
///   property.
///
/// - Note: the engine can only reduce *its own* retention. pjsua deep-copies the credential into
///   its account pool and the shared auth session, where it lives until the account is deleted and
///   is never zeroed. Eliminating that copy needs `on_auth_challenge` (PJSIP 2.17+).
public protocol CredentialStore: Sendable {
    func secret(for request: CredentialRequest) async throws -> String
}

/// A ``CredentialStore`` backed by a closure — for tests, for credentials already in hand, and as
/// the adapter behind the convenience `addAccount(id:…password:…)` overload.
public struct InlineCredentialStore: CredentialStore {
    private let provide: @Sendable (CredentialRequest) async throws -> String

    public init(_ provide: @escaping @Sendable (CredentialRequest) async throws -> String) {
        self.provide = provide
    }

    /// Wraps a password the caller already holds.
    public init(password: String) {
        self.provide = { _ in password }
    }

    public func secret(for request: CredentialRequest) async throws -> String {
        try await provide(request)
    }
}
