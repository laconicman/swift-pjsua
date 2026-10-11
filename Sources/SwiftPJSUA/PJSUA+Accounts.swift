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
    /// across a suspension point — see ``PJSUA/liveParameters(_:generation:)``.
    var generation: UInt64

    /// The push parameters pjsua has now: `config.push` is what the account should have, this is
    /// what was last applied. A difference means the Contact the binding is registered under
    /// changes — the engine's own record, so it need not repeat `pjsua_acc_modify`'s field rules.
    var appliedPush: PushConfiguration?
}

extension PJSUA {
    // MARK: Accounts

    /// Add a SIP account and register it.
    ///
    /// The secret is fetched from `credentials` **before** any engine state is inspected; see the
    /// re-entrancy note on ``addAccount(_:secret:)``.
    ///
    /// **The engine sends the first REGISTER**, not `pjsua_acc_add`: that one ignores whether its
    /// send worked (`pjsua_acc.c`), so it is told not to (`register_on_acc_add`). The REGISTER is
    /// the account's first registration operation, and any other one on the account waits for it.
    ///
    /// - Parameters:
    ///   - config: everything but the secret (see ``AccountConfiguration``).
    ///   - credentials: consulted now, and again on ``reRegister(_:updatingPush:wait:)``.
    ///   - wait: ``RegistrationWait/confirmed(timeout:)``, the default, returns when the registrar
    ///     confirms the binding, as ``reRegister(_:updatingPush:wait:)`` does.
    ///     ``RegistrationWait/dispatched`` returns once the REGISTER is sent.
    /// - Throws: ``PJSUAUsageError`` or ``PJSUAError`` when the account could not be added. An
    ///   added account stays whatever its first REGISTER's fate, and the ``RegistrationError`` that
    ///   reports it names the account.
    @discardableResult
    public func addAccount(_ config: AccountConfiguration,
                           credentials: CredentialStore,
                           wait: RegistrationWait = .confirmed()) async throws -> AccountID {
        // Taken before the critical section, which has no suspension point.
        let secret = try await credentials.secret(for: config.credentialRequest)
        let account = try addAccount(config, secret: secret, credentials: credentials)
        // Created in the same actor turn as the account, so it is the account's first operation.
        try await setRegistration(account, renew: true, wait: wait)
        return account
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
        // (8 as of swift-pjsip 0.2.1, which takes upstream's own default). Reading the
        // imported constant is the right thing to guard on: it is the same value this
        // compilation laid the pjsua struct layouts out with. Those two can come apart —
        // 0.2.0's module map dropped config_site.h's overrides, so Swift compiled 4 against a
        // binary built with 8 — which is why that release was withdrawn and why
        // verify-xcframework.sh now asserts the module and the headers agree.
        // Overflowing the table is **a crash or an error
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
            cfg.register_on_acc_add = false.pjBool   // the engine registers (see the async add)
            try pjsua_acc_add(&cfg, config.isDefault.pjBool, &accId).throwIfFailed()
            return accId
        }
        let account = AccountID(rawId)
        accountGeneration &+= 1
        accountParameters[account] = AccountParameters(config: config,
                                                      credentials: credentials,
                                                      generation: accountGeneration,
                                                      appliedPush: config.push)
        // Tracked from here; nothing is sent yet.
        registration.sessions[account] = .unregistered
        return account
    }

    /// REGISTER (`renew`) or un-REGISTER an account, as it is configured now.
    ///
    /// **A registration operation**: it waits for any REGISTER or un-REGISTER already in flight on
    /// the account to settle, and for any ``handleIPChange(wait:)`` to complete, never fires into
    /// them. An un-REGISTER of an account that is not registered throws as pjsua refuses it, after
    /// pjsua has cancelled any automatic retry of a failed REGISTER.
    ///
    /// - Parameter wait: ``RegistrationWait/confirmed(timeout:)``, the default, returns when the
    ///   registrar answers: for a REGISTER, a confirmed binding, as for
    ///   ``reRegister(_:updatingPush:wait:)``. ``RegistrationWait/dispatched`` returns once the
    ///   request is sent.
    /// - Throws: ``RegistrationError``, or ``PJSUAUsageError/unknownAccount(_:)`` or
    ///   ``PJSUAUsageError/accountReplaced(_:)`` when the account went away meanwhile.
    public func setRegistration(_ account: AccountID,
                                renew: Bool,
                                wait: RegistrationWait = .confirmed()) async throws {
        guard let params = accountParameters[account] else {
            throw PJSUAUsageError.unknownAccount(account)
        }
        let generation = params.generation
        try await performRegistration(.account(account), wait: wait) { engine, operation in
            try await engine.registrationSteps(account, renew: renew,
                                               generation: generation, operation: operation)
        }
    }

    private func registrationSteps(_ account: AccountID,
                                   renew: Bool,
                                   generation: UInt64,
                                   operation: UInt64) async throws {
        let mailbox = openRegistrationMailbox(for: account)
        defer { closeRegistrationMailbox(mailbox) }
        while true {
            try await awaitQuietRegistration(account, generation: generation, mailbox: mailbox)
            // Synchronous from this reading to the send: the push parameters pjsua has applied.
            let push = try liveParameters(account, generation: generation).appliedPush
            guard let answer = try await exchangeRegistration(account, renew: renew,
                                                              generation: generation,
                                                              mailbox: mailbox,
                                                              operation: operation)
            else { continue }
            try confirmRegistration(answer, of: account, push: push)
            return
        }
    }

    /// Remove an account: un-REGISTER its binding and have the registrar answer, then delete it
    /// from pjsua and free its slot in the fixed account table (`pjsua_acc_del` — see
    /// ``addAccount(_:credentials:wait:)``).
    ///
    /// **A registration operation**: it waits for any REGISTER already in flight on the account to
    /// settle, never fires into it. `pjsua_acc_del` alone sends its un-REGISTER and destroys the
    /// session at once. With a REGISTER in flight the un-REGISTER is refused and the REGISTER
    /// orphaned, and pjsip answers a 401 on the orphan with the session's own credentials: the
    /// registrar would keep a binding, push parameters and all, for an account that no longer
    /// exists. Here the un-REGISTER is answered first, so pjsua finds no session left to delete and
    /// sends nothing more.
    ///
    /// The account is removed whatever the registrar answers. A failed un-REGISTER then throws
    /// ``RegistrationError/rejected(_:statusCode:)`` all the same, because the registrar may keep
    /// the binding until it expires. When pjsua reports nothing within the engine's backstop, the
    /// call throws ``RegistrationError/timedOut(_:)`` and the account stays, to be removed again.
    ///
    /// Calls still using the account are unaffected at the SIP-dialog level but can no longer
    /// authenticate re-INVITEs; hang up first.
    ///
    /// - Parameter wait: ``RegistrationWait/dispatched`` returns once the un-REGISTER is sent (or
    ///   at once, for an account with nothing to un-REGISTER); the account is deleted when it is
    ///   answered.
    /// - Important: pjsua **recycles** freed ids — a later `addAccount` may return this same
    ///   ``AccountID``. Consumers keeping per-account state keyed by id must drop it here.
    public func removeAccount(_ account: AccountID, wait: RegistrationWait = .confirmed()) async throws {
        guard let params = accountParameters[account] else {
            throw PJSUAUsageError.unknownAccount(account)
        }
        let generation = params.generation
        try await performRegistration(.account(account), wait: wait) { engine, operation in
            try await engine.removeAccountSteps(account, generation: generation, operation: operation)
        }
    }

    private func removeAccountSteps(_ account: AccountID,
                                    generation: UInt64,
                                    operation: UInt64) async throws {
        let mailbox = openRegistrationMailbox(for: account)
        defer { closeRegistrationMailbox(mailbox) }
        var answer: RegistrationSettlement?
        while true {
            try await awaitQuietRegistration(account, generation: generation, mailbox: mailbox)
            // Synchronous from this reading on: the session is quiet.
            guard case .registered = registration.sessions[account], answer == nil else { break }
            guard let settled = try await exchangeRegistration(account, renew: false,
                                                               generation: generation,
                                                               mailbox: mailbox,
                                                               operation: operation)
            else { continue }
            answer = settled
            // Back to a quiet reading before deleting: pjsua may start a REGISTER of its own after
            // a failed un-REGISTER (its retry block does not exclude them).
        }
        _ = try liveParameters(account, generation: generation)
        try pjsua_acc_del(account.raw).throwIfFailed()
        accountParameters[account] = nil
        registration.sessions[account] = nil
        markRegistrationDispatched(operation)
        if let answer {
            try confirmRegistration(answer, of: account, push: nil)
        }
    }

    /// The stored parameters of `account`, provided it is still the account `generation` was
    /// stamped on: pjsua recycles freed ids, so presence alone proves nothing across a suspension.
    func liveParameters(_ account: AccountID, generation: UInt64) throws -> AccountParameters {
        guard let live = accountParameters[account] else {
            throw PJSUAUsageError.unknownAccount(account)
        }
        guard live.generation == generation else {
            throw PJSUAUsageError.accountReplaced(account)
        }
        return live
    }

    /// Apply the stored parameters to the live account with `pjsua_acc_modify`, telling it not to
    /// register by itself (`disable_reg_on_modify`), and return the push parameters applied. The
    /// config step of ``reRegister(_:updatingPush:wait:)``, run from a quiet session.
    ///
    /// **The caller owns the re-registration.** It un-REGISTERs first when the Contact changes, and
    /// registers straight after this returns, in the same synchronous step: the condition under
    /// which TD-21 allows the flag. pjsua still decides what the change means for the session — a
    /// changed credential or Contact makes it discard the session, so the caller's REGISTER goes
    /// out on a fresh one — so the engine repeats none of `pjsua_acc_modify`'s field rules.
    ///
    /// **Re-validates by generation, not by presence.** The operation suspends before this, and the
    /// actor is re-entrant across a suspension: another call can `removeAccount` and then
    /// `addAccount` in the gap. pjsua recycles freed ids, so the new account can be handed the
    /// *same* ``AccountID`` — a `!= nil` check would pass and we would apply this account's
    /// credential and push parameters to somebody else's account.
    ///
    /// **Read-modify-write, never rebuild.** `pjsua_acc_modify` diffs the struct it is handed
    /// against the *live* config, so passing a freshly-defaulted one silently resets everything
    /// pjsua or the app established after `pjsua_acc_add` — `server_affinity`,
    /// `allow_contact_rewrite`, the negotiated `reg_timeout` and retry intervals,
    /// `rtp_cfg.port` (which also zeroes `next_rtp_port`), and `ice_cfg_use`/`turn_cfg_use`.
    /// We therefore fetch the live config with `pjsua_acc_get_config` into a scratch pool and
    /// overwrite only the fields we own. This is the pattern pjsua's own app and tests use.
    func applyStoredConfiguration(_ account: AccountID,
                                  generation: UInt64,
                                  secret: String) throws -> PushConfiguration? {
        var params = try liveParameters(account, generation: generation)
        guard let pool = pjsua_pool_create("swift-pjsua.accmod", 1024, 1024) else {
            // Not "unknown account" — the check above proved it exists. This is an allocation
            // failure, which is transient and worth retrying.
            throw PJSUAUsageError.poolAllocationFailed
        }
        defer { pj_pool_release(pool) }

        var acc = pjsua_acc_config()
        try pjsua_acc_get_config(account.raw, pool, &acc).throwIfFailed()

        // Only the fields we own; everything else stays as pjsua has it.
        let owners = applyOwnedFields(to: &acc, config: params.config, secret: secret)
        acc.disable_reg_on_modify = true.pjBool
        try withExtendedLifetime(owners) {
            _ = try pjsua_acc_modify(account.raw, &acc).throwIfFailed()
        }
        params.appliedPush = params.config.push
        accountParameters[account] = params
        return params.config.push
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
        // Add path only: reRegister's read-modify-write keeps the live value (D-CONFIG-4).
        if let timeout = config.registrationTimeout {
            acc.reg_timeout = timeout
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
