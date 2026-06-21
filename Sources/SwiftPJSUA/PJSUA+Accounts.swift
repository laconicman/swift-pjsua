import PJSIP

/// The parameters needed to (re)build a `pjsua_acc_config`. Stored per account so a
/// silent-push re-REGISTER can rebuild the full config with updated push parameters,
/// avoiding the fragile `pjsua_acc_get_config` + pool path.
struct AccountParameters: Sendable, Equatable {
    var id: String
    var registrar: String
    var username: String
    var password: String
    var realm: String
    var push: PushConfiguration?
}

extension PJSUA {
    // MARK: Accounts

    /// Add a SIP account and start registration.
    ///
    /// - Parameters:
    ///   - id: the account's SIP URI (e.g. `"sip:alice@example.com"`).
    ///   - registrar: the registrar URI (e.g. `"sip:example.com"`).
    ///   - username/password/realm: digest credentials (`realm` `"*"` matches any).
    ///   - push: optional RFC 8599 push parameters (see ``PushConfiguration``).
    ///   - makeDefault: make this the default account for outbound calls.
    @discardableResult
    public func addAccount(id: String,
                           registrar: String,
                           username: String,
                           password: String,
                           realm: String = "*",
                           push: PushConfiguration? = nil,
                           makeDefault: Bool = true) throws -> AccountID {
        let params = AccountParameters(
            id: id, registrar: registrar, username: username,
            password: password, realm: realm, push: push
        )
        let rawId = try withAccConfig(params) { cfg -> pjsua_acc_id in
            var accId: pjsua_acc_id = -1 // PJSUA_INVALID_ID
            try pjsua_acc_add(&cfg, makeDefault.pjBool, &accId).throwIfFailed()
            return accId
        }
        let account = AccountID(rawId)
        accountParameters[account] = params
        return account
    }

    /// Toggle registration for an account (REGISTER / un-REGISTER).
    public func setRegistration(_ account: AccountID, renew: Bool) throws {
        try pjsua_acc_set_registration(account.raw, renew.pjBool).throwIfFailed()
    }

    /// Re-REGISTER an account, optionally replacing its push parameters first.
    ///
    /// Designed for the silent-push "re-REGISTER with updated config" path: it rebuilds
    /// the account config from stored ``AccountParameters`` (so it never races a
    /// `get_config`/pool round-trip), applies it via `pjsua_acc_modify`, then renews
    /// registration. This is independent of the VoIP-push answer path and of lifecycle
    /// events — it only mutates this account's config and registration.
    ///
    /// - Parameter push: new push parameters, or `nil` to keep the current ones.
    public func reRegister(_ account: AccountID, updatingPush push: PushConfiguration? = nil) throws {
        guard var params = accountParameters[account] else {
            throw PJSUAUsageError.unknownAccount(account)
        }
        if let push { params.push = push }
        try withAccConfig(params) { cfg -> Void in
            try pjsua_acc_modify(account.raw, &cfg).throwIfFailed()
        }
        accountParameters[account] = params
        try pjsua_acc_set_registration(account.raw, true.pjBool).throwIfFailed()
    }

    // MARK: Config building

    /// Build a `pjsua_acc_config` from `params` and run `body` with it.
    ///
    /// `pjsua_acc_config` is a struct of non-owning `pj_str_t` fields. pjsua copies them
    /// into its own pool *during* `pjsua_acc_add`/`pjsua_acc_modify`, so the backing bytes
    /// only need to outlive `body`. We own them with ``PJString`` and hold every owner
    /// alive across `body` via `withExtendedLifetime` — no manual `free`, no dangling
    /// pointers if `body` throws.
    private func withAccConfig<T>(_ params: AccountParameters,
                                  _ body: (inout pjsua_acc_config) throws -> T) rethrows -> T {
        var acc = pjsua_acc_config()
        pjsua_acc_config_default(&acc)

        let idOwner = PJString(params.id)
        let regOwner = PJString(params.registrar)
        let realmOwner = PJString(params.realm)
        let schemeOwner = PJString("digest")
        let userOwner = PJString(params.username)
        let passOwner = PJString(params.password)

        acc.id = idOwner.value
        acc.reg_uri = regOwner.value
        acc.cred_count = 1
        acc.cred_info.0.realm = realmOwner.value
        acc.cred_info.0.scheme = schemeOwner.value
        acc.cred_info.0.username = userOwner.value
        acc.cred_info.0.data_type = 0 // PJSIP_CRED_DATA_PLAIN_PASSWD
        acc.cred_info.0.data = passOwner.value

        var owners: [PJString] = [idOwner, regOwner, realmOwner, schemeOwner, userOwner, passOwner]

        if let push = params.push {
            let pushOwner = PJString(push.params)
            owners.append(pushOwner)
            switch push.scope {
            case .registerOnly: acc.reg_contact_uri_params = pushOwner.value
            case .allRequests:  acc.contact_uri_params = pushOwner.value
            }
        }

        return try withExtendedLifetime(owners) {
            try body(&acc)
        }
    }
}
