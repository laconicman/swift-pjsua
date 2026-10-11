import PJSIP

extension PJSUA {

    /// Re-REGISTER an account, optionally replacing its push parameters first.
    ///
    /// For the silent-push "re-REGISTER with updated config" path and for push-token rotation. It
    /// applies the stored ``AccountConfiguration``, with a **freshly fetched** secret, on top of
    /// pjsua's live config, and registers. It touches only this account's config and registration,
    /// so it neither races nor tears down the VoIP-push answer path or an established call.
    ///
    /// **A registration operation**: it waits for any REGISTER or un-REGISTER already in flight on
    /// the account to settle, and for any ``handleIPChange(wait:)`` to complete, never fires into
    /// them. Then, when the push parameters — and with them the Contact the binding is registered
    /// under — change on a registered account, it un-REGISTERs the old binding and has the registrar
    /// answer before it applies the change and registers the new one. `pjsua_acc_modify` alone
    /// would send the two back to back on two sessions, so a late un-REGISTER could delete the new
    /// binding, and would destroy a session whose REGISTER might still be in flight — whose 401
    /// pjsip answers with the old Contact anyway (Tech-Debt TD-23).
    ///
    /// **Requests coalesce, and the latest push parameters win.** A call stores its push
    /// parameters when it is made. A request made while an earlier one still waits for its turn
    /// joins it, and that one re-registration answers both. They stay stored when the
    /// re-registration fails: they are the account's configuration from then on, and the next
    /// re-registration applies them.
    ///
    /// - Parameters:
    ///   - push: new push parameters, or `nil` to keep the current ones.
    ///   - wait: ``RegistrationWait/confirmed(timeout:)``, the default, returns when the registrar
    ///     confirms the binding: a 2xx with an expiry and, when the account has push parameters and
    ///     the registrar lists the bindings it holds, one that carries them.
    ///     ``RegistrationWait/dispatched`` returns once the first request is sent.
    /// - Throws: ``RegistrationError/rejected(_:statusCode:)`` for a final non-2xx;
    ///   ``RegistrationError/bindingNotConfirmed(_:)`` when the 2xx shows the registrar did not keep
    ///   the Contact; ``RegistrationError/failed(_:_:)`` when pjsip could not send or got no
    ///   response; ``RegistrationError/timedOut(_:)``; ``PJSUAError`` when pjsua refused the new
    ///   configuration; and ``PJSUAUsageError/unknownAccount(_:)`` or
    ///   ``PJSUAUsageError/accountReplaced(_:)`` when the account went away meanwhile.
    public func reRegister(_ account: AccountID,
                           updatingPush push: PushConfiguration? = nil,
                           wait: RegistrationWait = .confirmed()) async throws {
        guard var params = accountParameters[account] else {
            throw PJSUAUsageError.unknownAccount(account)
        }
        // Recorded before anything suspends, so whichever re-registration reads the parameters
        // next applies the latest.
        if let push {
            params.config.push = push
            accountParameters[account] = params
        }
        let generation = params.generation
        try await performRegistration(.account(account),
                                      joining: .reRegister(account, generation: generation),
                                      wait: wait) { engine, operation in
            try await engine.reRegisterSteps(account, generation: generation, operation: operation)
        }
    }

    private func reRegisterSteps(_ account: AccountID,
                                 generation: UInt64,
                                 operation: UInt64) async throws {
        let mailbox = openRegistrationMailbox(for: account)
        defer { closeRegistrationMailbox(mailbox) }
        let stored = try liveParameters(account, generation: generation)
        // Fetched once the operation has its turn, so it serves every request that joined it.
        // The store runs off this actor (see CredentialStore).
        let secret = try await stored.credentials.secret(for: stored.config.credentialRequest)
        var unregistered = false

        while true {
            try await awaitQuietRegistration(account, generation: generation, mailbox: mailbox)
            // Synchronous from this reading to the next `await`: the session is quiet.
            let params = try liveParameters(account, generation: generation)

            if params.config.push != params.appliedPush, !unregistered,
               case .registered = registration.sessions[account] {
                guard let answer = try await exchangeRegistration(account, renew: false,
                                                                  generation: generation,
                                                                  mailbox: mailbox,
                                                                  operation: operation)
                else { continue }
                unregistered = true
                if !answer.isSuccess {
                    // The registrar may keep the old binding until it expires; the new one is
                    // registered all the same.
                    pjLog(3, "Acc \(account.raw): un-REGISTER of the old binding failed "
                             + "(status \(answer.status), SIP \(answer.code)); registering the new one")
                }
                continue
            }

            let push = try applyStoredConfiguration(account, generation: generation, secret: secret)
            guard let answer = try await exchangeRegistration(account, renew: true,
                                                              generation: generation,
                                                              mailbox: mailbox,
                                                              operation: operation)
            else { continue }
            try confirmRegistration(answer, of: account, push: push)
            return
        }
    }
}
