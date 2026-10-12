import Foundation

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

    /// How long each registration asks to last, in seconds (`pjsua_acc_config.reg_timeout`).
    /// `nil` keeps pjsua's default, `PJSUA_REG_INTERVAL` (300 s). Zero is refused with
    /// ``PJSUAUsageError/zeroRegistrationTimeout``: `Expires: 0` removes the binding.
    ///
    /// Push-woken apps want this long. Once iOS suspends the app nothing refreshes the
    /// registration, so when it expires the server drops the binding, and with it the push
    /// target. The registrar may grant less than asked (Flexisip caps it at `max-expires`).
    ///
    /// Applied when the account is added; ``PJSUA/reRegister(_:updatingPush:wait:)`` keeps the live
    /// value.
    public var registrationTimeout: UInt32?

    /// The account's SIP instance ID (RFC 5626 §4.1): the `+sip.instance` parameter of the REGISTER
    /// `Contact` (`pjsua_acc_config.rfc5626_instance_id`).
    ///
    /// Registrars such as Kamailio and Flexisip treat contacts with the same instance ID as one
    /// device: a new binding from it replaces the old one. So the value must be **unique to the
    /// device and persistent** across launches. Generate it once, store it, and pass the same value
    /// every time. A value that changes leaves stale bindings behind; one shared by two devices
    /// makes them displace each other.
    ///
    /// The engine sends it as `<urn:uuid:…>` in lower case. Registrars compare the value
    /// case-sensitively, and `UUID.uuidString` is upper case.
    ///
    /// `nil` keeps pjsua's own behaviour: an ID derived from the host name, sent only while SIP
    /// outbound is in use (``usesSIPOutbound``, TCP and TLS). On iOS the host name is not the
    /// device's, so every phone would send the same one.
    ///
    /// A configured ID is sent in every REGISTER, with or without SIP outbound. Applied when the
    /// account is added. ``PJSUA/reRegister(_:updatingPush:wait:)`` keeps it: changing it on a
    /// registered binding is a Contact change, which leaves the old binding in place on some
    /// registrars. To change it, remove the account and add it again.
    public var instanceID: UUID?

    /// Whether the account offers SIP outbound (RFC 5626) on TCP and TLS
    /// (`pjsua_acc_config.use_rfc5626`). When it does, the REGISTER carries `reg-id` and the `ob`
    /// Contact parameter, and the request carries `Supported: outbound`. `true` by default, pjsua's
    /// default.
    ///
    /// Turn it off, and set ``instanceID``, for a registrar that does not confirm outbound, as
    /// Flexisip, OpenSIPS and Kamailio in its default configuration do not. With outbound offered
    /// and not confirmed, pjsua sends `reg-id` in the first REGISTER and drops it from later ones.
    /// Kamailio in its default configuration keys bindings on the instance ID and `reg-id`
    /// together, so the un-REGISTER no longer matches and the binding stays until it expires. An
    /// instance ID without outbound keeps the Contact the same from the first REGISTER to the
    /// un-REGISTER. Turning outbound off also means no 439 (First Hop Lacks Outbound Support) can
    /// occur.
    ///
    /// Applied when the account is added. ``PJSUA/reRegister(_:updatingPush:wait:)`` keeps the
    /// live value.
    public var usesSIPOutbound: Bool

    /// Make this the default account for outbound calls.
    public var isDefault: Bool

    public init(id: String,
                registrar: String,
                username: String,
                realm: String = "*",
                transportName: String? = nil,
                push: PushConfiguration? = nil,
                registrationTimeout: UInt32? = nil,
                instanceID: UUID? = nil,
                usesSIPOutbound: Bool = true,
                isDefault: Bool = true) {
        self.id = id
        self.registrar = registrar
        self.username = username
        self.realm = realm
        self.transportName = transportName
        self.push = push
        self.registrationTimeout = registrationTimeout
        self.instanceID = instanceID
        self.usesSIPOutbound = usesSIPOutbound
        self.isDefault = isDefault
    }

    /// The lookup this account's secret is fetched with.
    var credentialRequest: CredentialRequest {
        CredentialRequest(accountID: id, username: username, realm: realm)
    }

    // MARK: Codable
    //
    // Hand-written `init(from:)` because the synthesised one **ignores property defaults**:
    // every key becomes mandatory, so a stored document written by an older build — or by hand —
    // fails to decode outright the moment a field with a default is absent. That would defeat the
    // point of making this type persistable. `decodeIfPresent` + the same defaults as the
    // memberwise initialiser means old documents keep decoding as new optional fields are added.
    // Required keys stay required: an account without `id`, `registrar` or `username` is not a
    // partially-specified account, it is a broken one.

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        registrar = try container.decode(String.self, forKey: .registrar)
        username = try container.decode(String.self, forKey: .username)
        realm = try container.decodeIfPresent(String.self, forKey: .realm) ?? "*"
        transportName = try container.decodeIfPresent(String.self, forKey: .transportName)
        push = try container.decodeIfPresent(PushConfiguration.self, forKey: .push)
        registrationTimeout = try container.decodeIfPresent(UInt32.self, forKey: .registrationTimeout)
        instanceID = try container.decodeIfPresent(UUID.self, forKey: .instanceID)
        usesSIPOutbound = try container.decodeIfPresent(Bool.self, forKey: .usesSIPOutbound) ?? true
        isDefault = try container.decodeIfPresent(Bool.self, forKey: .isDefault) ?? true
    }
}
