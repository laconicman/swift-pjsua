import PJSIP

/// What the engine keeps per account so a silent-push re-REGISTER can re-apply the fields we own
/// on top of pjsua's live configuration.
///
/// Holds the ``CredentialStore``, **not the secret** — that is fetched on demand each time the
/// config is applied (TD-11: no plaintext password retained on the Swift side).
struct AccountParameters: Sendable {
    var config: AccountConfiguration
    var credentials: CredentialStore

    /// Distinguishes *this* account from a later one that happened to be handed the same
    /// ``AccountID``. pjsua recycles freed ids, so an id alone cannot identify an account
    /// across a suspension point — see ``PJSUA/reRegister(_:updatingPush:)``.
    var generation: UInt64
}

extension PJSUA {
    // MARK: Accounts

    /// Add a SIP account and start registration.
    ///
    /// The secret is fetched from `credentials` **before** any engine state is inspected; see the
    /// re-entrancy note on ``addAccount(_:secret:)``.
    ///
    /// - Parameters:
    ///   - config: everything but the secret (see ``AccountConfiguration``).
    ///   - credentials: consulted now, and again on ``reRegister(_:updatingPush:)``.
    @discardableResult
    public func addAccount(_ config: AccountConfiguration,
                           credentials: CredentialStore) async throws -> AccountID {
        // The one and only suspension point, taken up front.
        let secret = try await credentials.secret(for: config.credentialRequest)
        return try addAccount(config, secret: secret, credentials: credentials)
    }

    /// The critical section: **synchronous by construction**.
    ///
    /// Actors interleave only at suspension points, so a method with none runs to completion
    /// without another call slipping in. Keeping the capacity check and `pjsua_acc_add` in a
    /// non-`async` function makes that structural rather than a convention — a future `await`
    /// here would not compile without changing this signature, so the check-then-add sequence
    /// cannot become a time-of-check/time-of-use race. (Do not inline this back into the `async`
    /// method: there, an `await` between the guard and the add would let two callers both pass
    /// the guard for one free slot — which on PJSIP ≤ 2.17 debug builds is an abort, not an error.)
    private func addAccount(_ config: AccountConfiguration,
                            secret: String,
                            credentials: CredentialStore) throws -> AccountID {
        // The pjsua account table is a fixed array sized PJSUA_MAX_ACC at binary build time
        // (4 in the shipped PJ_CONFIG_IPHONE build). Overflowing it is **a crash or an error
        // return depending on the PJSIP version**: through 2.17 `pjsua_acc_add` guards it with
        // PJ_ASSERT_RETURN, which aborts debug builds; upstream now returns PJ_ETOOMANY in every
        // build (our fix, pjsip/pjproject#5070, `54ebfdbec`). We pre-check regardless — keeps older
        // binaries from aborting, and it surfaces a typed error carrying the capacity instead
        // of a bare status code.
        guard pjsua_acc_get_count() < UInt32(PJSUA_MAX_ACC) else {
            throw PJSUAUsageError.accountTableFull(capacity: UInt32(PJSUA_MAX_ACC))
        }
        let rawId = try withAccConfig(config, secret: secret) { cfg -> pjsua_acc_id in
            var accId: pjsua_acc_id = -1 // PJSUA_INVALID_ID
            try pjsua_acc_add(&cfg, config.isDefault.pjBool, &accId).throwIfFailed()
            return accId
        }
        let account = AccountID(rawId)
        accountGeneration &+= 1
        accountParameters[account] = AccountParameters(config: config,
                                                      credentials: credentials,
                                                      generation: accountGeneration)
        return account
    }

    /// Toggle registration for an account (REGISTER / un-REGISTER).
    public func setRegistration(_ account: AccountID, renew: Bool) throws {
        try pjsua_acc_set_registration(account.raw, renew.pjBool).throwIfFailed()
    }

    /// Remove an account: un-REGISTERs (best effort), deletes it from pjsua, and frees its
    /// slot in the fixed account table (`pjsua_acc_del` — see ``addAccount(_:credentials:)``).
    /// Any calls still using the account are unaffected at the SIP-dialog level but can no
    /// longer authenticate re-INVITEs; hang up first.
    ///
    /// - Important: pjsua **recycles** freed ids — a later `addAccount` may return this same
    ///   ``AccountID``. Consumers keeping per-account state keyed by id must drop it here.
    public func removeAccount(_ account: AccountID) throws {
        try pjsua_acc_del(account.raw).throwIfFailed()
        accountParameters[account] = nil
    }

    /// Re-REGISTER an account, optionally replacing its push parameters first.
    ///
    /// Designed for the silent-push "re-REGISTER with updated config" path: it rebuilds the
    /// account config from the stored ``AccountConfiguration`` and a **freshly fetched** secret,
    /// applies it via `pjsua_acc_modify`, then renews registration. Independent of the VoIP-push
    /// answer path and of lifecycle events — it only mutates this account's config and
    /// registration.
    ///
    /// - Parameter push: new push parameters, or `nil` to keep the current ones.
    public func reRegister(_ account: AccountID, updatingPush push: PushConfiguration? = nil) async throws {
        guard var params = accountParameters[account] else {
            throw PJSUAUsageError.unknownAccount(account)
        }
        if let push { params.config.push = push }
        // Suspension point first, then the synchronous tail (same rule as addAccount).
        let secret = try await params.credentials.secret(for: params.config.credentialRequest)
        try reRegister(account, params: params, secret: secret)
    }

    /// Synchronous tail of ``reRegister(_:updatingPush:)`` — see the note on
    /// ``addAccount(_:secret:credentials:)``.
    ///
    /// **Re-validates by generation, not by presence.** Fetching the secret suspends, and the
    /// actor is re-entrant across that suspension: another call can `removeAccount` and then
    /// `addAccount` in the gap. pjsua recycles freed ids, so the new account can be handed the
    /// *same* ``AccountID`` — a `!= nil` check would pass and we would then apply this call's
    /// credential and push parameters to somebody else's account, and overwrite their stored
    /// parameters with ours. Comparing the generation stamped at add time closes that window.
    ///
    /// **Read-modify-write, never rebuild.** `pjsua_acc_modify` diffs the struct it is handed
    /// against the *live* config, so passing a freshly-defaulted one silently resets everything
    /// pjsua or the app established after `pjsua_acc_add` — `server_affinity`,
    /// `allow_contact_rewrite`, the negotiated `reg_timeout` and retry intervals,
    /// `rtp_cfg.port` (which also zeroes `next_rtp_port`), and `ice_cfg_use`/`turn_cfg_use`.
    /// We therefore fetch the live config with `pjsua_acc_get_config` into a scratch pool and
    /// overwrite only the fields we own. This is the pattern pjsua's own app and tests use.
    private func reRegister(_ account: AccountID,
                            params: AccountParameters,
                            secret: String) throws {
        guard let live = accountParameters[account] else {
            throw PJSUAUsageError.unknownAccount(account)
        }
        guard live.generation == params.generation else {
            throw PJSUAUsageError.accountReplaced(account)
        }
        guard let pool = pjsua_pool_create("swift-pjsua.accmod", 1024, 1024) else {
            // Not "unknown account" — the guard above already proved it exists. This is an
            // allocation failure, which is transient and worth retrying.
            throw PJSUAUsageError.poolAllocationFailed
        }
        defer { pj_pool_release(pool) }

        var acc = pjsua_acc_config()
        try pjsua_acc_get_config(account.raw, pool, &acc).throwIfFailed()

        // Only the fields we own; everything else stays as pjsua has it.
        let owners = applyOwnedFields(to: &acc, config: params.config, secret: secret)

        _ = try withExtendedLifetime(owners) {
            // A changed credential makes pjsua unregister the old binding and re-REGISTER.
            // If that re-registration fails the account stays unregistered and the config is
            // NOT rolled back (documented pjsua_acc_modify behaviour).
            try pjsua_acc_modify(account.raw, &acc).throwIfFailed()
        }
        accountParameters[account] = params   // same generation; only config/push may have changed
        try pjsua_acc_set_registration(account.raw, true.pjBool).throwIfFailed()
    }

    // MARK: Config building

    /// Build a `pjsua_acc_config` from `config` + `secret` and run `body` with it.
    ///
    /// `pjsua_acc_config` is a struct of non-owning `pj_str_t` fields. pjsua copies them
    /// into its own pool *during* `pjsua_acc_add`/`pjsua_acc_modify`, so the backing bytes
    /// only need to outlive `body`. We own them with ``PJString`` and hold every owner
    /// alive across `body` via `withExtendedLifetime` — no manual `free`, no dangling
    /// pointers if `body` throws.
    ///
    /// - Important: this must stay non-`async`. Suspending here would hold C pointers into
    ///   Swift-owned buffers across a suspension point.
    private func withAccConfig<T>(_ config: AccountConfiguration,
                                  secret: String,
                                  _ body: (inout pjsua_acc_config) throws -> T) throws -> T {
        var acc = pjsua_acc_config()
        pjsua_acc_config_default(&acc)

        let idOwner = PJString(config.id)
        let regOwner = PJString(config.registrar)

        acc.id = idOwner.value
        acc.reg_uri = regOwner.value

        // Pin the account to a named transport, if it asked for one (TD-18). Precedence in
        // pjsip: transport_id > URI ";transport=" param > stack auto-selection.
        if let name = config.transportName {
            guard let transportID = transportIDs[name] else {
                throw PJSUAUsageError.unknownTransport(name)
            }
            acc.transport_id = transportID
        }

        var owners: [PJString] = [idOwner, regOwner]
        owners += applyOwnedFields(to: &acc, config: config, secret: secret)

        return try withExtendedLifetime(owners) {
            try body(&acc)
        }
    }

    /// Write the fields this wrapper owns — the digest credential and the RFC 8599 push
    /// parameters — onto `acc`, returning the ``PJString`` owners whose bytes must outlive the
    /// following `pjsua_acc_add`/`pjsua_acc_modify` call.
    ///
    /// Shared by the **add** path (fresh config) and the **modify** path (live config read back
    /// via `pjsua_acc_get_config`) deliberately: the two must not drift. In particular the
    /// push-scope rule below is only correct if it runs on *both* paths.
    ///
    /// - Note: **both** contact-parameter slots are always written, even when only one carries a
    ///   value. On the modify path the struct starts from the *live* config, so leaving the
    ///   unused slot untouched would keep the previous scope's push string attached — after a
    ///   `.registerOnly` → `.allRequests` change the account would advertise a stale push token
    ///   alongside the new one. Clearing works because `pjsua_acc_modify` diffs each field with
    ///   `pj_strcmp` and then `pj_strdup_with_null`s whatever it was handed, so an empty
    ///   `pj_str_t` genuinely erases the stored value rather than meaning "no change"
    ///   (`pjsua_acc.c`, the `reg_contact_uri_params` / `contact_params` blocks).
    private func applyOwnedFields(to acc: inout pjsua_acc_config,
                                  config: AccountConfiguration,
                                  secret: String) -> [PJString] {
        let realmOwner = PJString(config.realm)
        let schemeOwner = PJString("digest")
        let userOwner = PJString(config.username)
        let passOwner = PJString(secret)

        acc.cred_count = 1
        acc.cred_info.0.realm = realmOwner.value
        acc.cred_info.0.scheme = schemeOwner.value
        acc.cred_info.0.username = userOwner.value
        acc.cred_info.0.data_type = 0 // PJSIP_CRED_DATA_PLAIN_PASSWD
        acc.cred_info.0.data = passOwner.value

        var owners = [realmOwner, schemeOwner, userOwner, passOwner]

        // Drive both slots so a scope change (or dropping push entirely) cannot leave the
        // previous value behind — see the note above.
        acc.reg_contact_uri_params = pj_str_t()
        acc.contact_uri_params = pj_str_t()
        if let push = config.push {
            let pushOwner = PJString(push.params)
            owners.append(pushOwner)
            switch push.scope {
            case .registerOnly: acc.reg_contact_uri_params = pushOwner.value
            case .allRequests:  acc.contact_uri_params = pushOwner.value
            }
        }
        return owners
    }
}
