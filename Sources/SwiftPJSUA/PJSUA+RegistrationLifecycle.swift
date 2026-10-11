import PJSIP

// MARK: - Registration lifecycle
//
// Account registrations change through one path: operations that run one at a time per account
// (an IP change alone), each to its end, deciding from the sessions pjsua's callbacks report rather
// than from reads of pjsua's state. The callbacks yield ``RegistrationSignal``s and a task on this
// actor applies them in the actor's own turns, so they still hold no actor reference (G2). Design,
// and the windows it cannot close from outside pjsip: `docs/Registration-Lifecycle.md`.

/// pjsua refused a send because the session has a transaction of its own in flight. Recoverable,
/// and caught where it is: the operation waits for that transaction to settle and sends again.
struct RegistrationBusy: Error {}

extension PJSUA {

    /// How long one wait inside an operation lasts before the engine reads pjsua's state once to
    /// recover, and gives up if the session is still busy. pjsip ends a registration transaction
    /// within 33 s (`REGC_TSX_TIMEOUT`, `sip_reg.c`), a challenged one is two, and pjsua reports
    /// the end of each, so this is only a backstop.
    static let registrationBackstop: Duration = .seconds(70)

    /// How long before a session's refresh is due the engine already treats it as busy:
    /// `refreshIn` counts whole seconds, rounded down, so pjsip's timer fires at or after the due
    /// time computed from it, and an operation must not start as it fires.
    static let refreshMargin: Duration = .seconds(2)

    // MARK: Operations

    /// Run `steps` as one registration operation over `scope`, in a task of its own, and keep the
    /// caller as `wait` says. The operation runs to its end however long the caller waits.
    ///
    /// A request with a `key` joins the operation of that kind still waiting for its turn, if there
    /// is one: it has not read its inputs yet, so it answers this request too.
    func performRegistration(_ scope: RegistrationLifecycle.Scope,
                             joining key: RegistrationLifecycle.JoinKey? = nil,
                             wait: RegistrationWait,
                             steps: @escaping @Sendable (PJSUA, UInt64) async throws -> Void) async throws {
        let operation: UInt64
        if let key, let waiting = registration.joinable[key] {
            operation = waiting
        } else {
            operation = registration.makeID()
            registration.operations[operation] = .init()
            if let key { registration.joinable[key] = operation }
            Task { await self.runRegistration(operation, scope: scope, key: key, steps: steps) }
        }

        let result: Result<Void, any Error>?
        switch wait {
        case .dispatched:
            result = await awaitRegistration(operation, untilDispatched: true, deadline: nil)
        case .confirmed(let timeout):
            result = await awaitRegistration(operation, untilDispatched: false,
                                             deadline: .now + timeout)
        }
        guard let result else {
            switch scope {
            case .account(let account): throw RegistrationError.timedOut(account)
            case .all: throw RegistrationError.ipChangeTimedOut
            }
        }
        try result.get()
    }

    private func runRegistration(_ operation: UInt64,
                                 scope: RegistrationLifecycle.Scope,
                                 key: RegistrationLifecycle.JoinKey?,
                                 steps: @Sendable (PJSUA, UInt64) async throws -> Void) async {
        let ticket = await acquireRegistrationTurn(scope)
        // From here the operation reads its inputs, so a later request needs an operation of its own.
        if let key, registration.joinable[key] == operation {
            registration.joinable[key] = nil
        }
        registration.operations[operation]?.phase = .running
        let result: Result<Void, any Error>
        do {
            try await steps(self, operation)
            result = .success(())
        } catch {
            result = .failure(error)
        }
        releaseRegistrationTurn(ticket)
        guard let finished = registration.operations.removeValue(forKey: operation) else { return }
        for waiter in finished.waiters.values {
            waiter.continuation.resume(returning: result)
        }
    }

    /// Tell callers waiting with ``RegistrationWait/dispatched`` that pjsua has the work.
    func markRegistrationDispatched(_ operation: UInt64) {
        guard var record = registration.operations[operation],
              case .running = record.phase else { return }
        record.phase = .dispatched
        for (id, waiter) in record.waiters where waiter.untilDispatched {
            record.waiters[id] = nil
            waiter.continuation.resume(returning: .success(()))
        }
        registration.operations[operation] = record
    }

    /// Suspend until `operation` is dispatched (or done, when not `untilDispatched`); `nil` when
    /// `deadline` passes first. Called in the same actor turn that created or joined the operation,
    /// so the operation has not finished yet.
    private func awaitRegistration(_ operation: UInt64,
                                   untilDispatched: Bool,
                                   deadline: ContinuousClock.Instant?) async -> Result<Void, any Error>? {
        guard let record = registration.operations[operation] else {
            preconditionFailure("a registration operation finished before its caller waited for it")
        }
        if untilDispatched, case .dispatched = record.phase { return .success(()) }
        let waiter = registration.makeID()
        let timer = deadline.map { deadline in
            Task { [weak self] in
                do {
                    try await Task.sleep(until: deadline, clock: .continuous)
                } catch {
                    return   // the wait ended another way
                }
                await self?.dropRegistrationWaiter(waiter, of: operation)
            }
        }
        defer { timer?.cancel() }
        return await withCheckedContinuation { continuation in
            registration.operations[operation]?.waiters[waiter] =
                .init(untilDispatched: untilDispatched, continuation: continuation)
        }
    }

    private func dropRegistrationWaiter(_ waiter: UInt64, of operation: UInt64) {
        registration.operations[operation]?.waiters.removeValue(forKey: waiter)?
            .continuation.resume(returning: nil)
    }

    // MARK: Turns

    /// Wait until no conflicting operation runs, or waits ahead of this one. Returns at once after
    /// shutdown; the operation then finds its account gone.
    private func acquireRegistrationTurn(_ scope: RegistrationLifecycle.Scope) async -> UInt64 {
        let ticket = registration.makeID()
        registration.waitingTurns.append((ticket, scope))
        while !registration.stopped, !registration.mayStart(ticket) {
            await withCheckedContinuation { continuation in
                registration.turnWakers[ticket] = continuation
            }
        }
        registration.waitingTurns.removeAll { $0.ticket == ticket }
        registration.runningTurns[ticket] = scope
        return ticket
    }

    private func releaseRegistrationTurn(_ ticket: UInt64) {
        registration.runningTurns[ticket] = nil
        wakeRegistrationTurns()
    }

    /// Every waiting operation looks again; `mayStart` keeps them in order.
    private func wakeRegistrationTurns() {
        let wakers = registration.turnWakers
        registration.turnWakers = [:]
        for waker in wakers.values { waker.resume() }
    }

    // MARK: Signals

    /// Apply one signal from the callback bridge, in this actor's turn, then hand it to the
    /// mailboxes of the operations it concerns.
    func applyRegistrationSignal(_ signal: RegistrationSignal) {
        switch signal {
        case .started(let account, _, let pending):
            // A start whose transaction is no longer pending was already settled, and that
            // settlement is in the stream ahead of it or applied: it changes nothing.
            if pending, registration.sessions[account] != nil {
                registration.sessions[account] = .pending
            }
        case .settled(let settlement):
            if registration.sessions[settlement.account] != nil {
                registration.sessions[settlement.account] = settlement.isRegistered
                    ? .registered(refreshDue: settlement.refreshIn.map { .now + .seconds($0) })
                    : .unregistered
            }
        case .ipChangeCompleted:
            registration.ipChangeRunning = false
        }
        for (id, mailbox) in registration.mailboxes
        where mailbox.account.map(signal.concerns) ?? true {
            if mailbox.waiting != nil {
                resumeRegistrationMailbox(id, with: signal)
            } else {
                registration.mailboxes[id]?.pending.append(signal)
            }
        }
    }

    /// Shutdown: wake everything that waits, for good. Each operation then finds its account gone.
    func stopRegistrationLifecycle() {
        registration.stopped = true
        registration.sessions.removeAll()
        registration.ipChangeRunning = false
        for id in registration.mailboxes.keys {
            resumeRegistrationMailbox(id, with: nil)
        }
        wakeRegistrationTurns()
    }

    // MARK: Mailboxes

    /// Start collecting the signals that concern `account` (`nil`: every signal).
    func openRegistrationMailbox(for account: AccountID?) -> UInt64 {
        let id = registration.makeID()
        registration.mailboxes[id] = .init(account: account)
        return id
    }

    func closeRegistrationMailbox(_ mailbox: UInt64) {
        resumeRegistrationMailbox(mailbox, with: nil)
        registration.mailboxes[mailbox] = nil
    }

    /// The next signal in `mailbox`, or `nil` once `deadline` passes or the engine stops.
    func nextRegistrationSignal(in mailbox: UInt64,
                                before deadline: ContinuousClock.Instant) async -> RegistrationSignal? {
        if let signal = registration.mailboxes[mailbox]?.pending.first {
            registration.mailboxes[mailbox]?.pending.removeFirst()
            return signal
        }
        guard !registration.stopped, registration.mailboxes[mailbox] != nil else { return nil }
        let token = registration.makeID()
        let timer = Task { [weak self] in
            do {
                try await Task.sleep(until: deadline, clock: .continuous)
            } catch {
                return   // the wait ended another way
            }
            await self?.resumeRegistrationMailbox(mailbox, token: token, with: nil)
        }
        defer { timer.cancel() }
        return await withCheckedContinuation { continuation in
            registration.mailboxes[mailbox]?.waiting = (token, continuation)
        }
    }

    /// Resume `mailbox`'s suspended wait with `signal`, if one is suspended — and, given a
    /// `token`, only if it is that wait, so a deadline cannot end a later wait.
    private func resumeRegistrationMailbox(_ mailbox: UInt64,
                                           token: UInt64? = nil,
                                           with signal: RegistrationSignal?) {
        guard let waiting = registration.mailboxes[mailbox]?.waiting,
              token.map({ $0 == waiting.token }) ?? true else { return }
        registration.mailboxes[mailbox]?.waiting = nil
        waiting.continuation.resume(returning: signal)
    }

    // MARK: Quiet, and waiting for it

    /// Whether the engine may touch `account`'s registration now: no transaction in flight, no
    /// refresh about to leave, no IP change running.
    func isQuietRegistration(_ account: AccountID) -> Bool {
        guard !registration.ipChangeRunning else { return false }
        switch registration.sessions[account] ?? .unregistered {
        case .unregistered: return true
        case .pending: return false
        case .registered(let refreshDue):
            return refreshDue.map { ContinuousClock.now < $0 - Self.refreshMargin } ?? true
        }
    }

    /// Suspend until `account`'s registration is quiet. It looks again only when a signal for the
    /// account arrives, never on a timer, and returns straight after the reading that found it
    /// quiet, so the caller's next synchronous step acts on that state. Re-validates the account
    /// each time: it may have been removed or replaced meanwhile.
    func awaitQuietRegistration(_ account: AccountID,
                                generation: UInt64,
                                mailbox: UInt64) async throws {
        let deadline = ContinuousClock.now + Self.registrationBackstop
        while true {
            _ = try liveParameters(account, generation: generation)
            if isQuietRegistration(account) { return }
            if await nextRegistrationSignal(in: mailbox, before: deadline) == nil {
                _ = try liveParameters(account, generation: generation)
                resyncRegistration(account)
                if isQuietRegistration(account) { return }
                throw RegistrationError.timedOut(account)
            }
        }
    }

    /// Suspend until `account`'s session reports the outcome of the (un-)REGISTER the caller has
    /// just sent: the next settlement of that kind (`renew`). The caller sent only from a quiet
    /// session, whose every earlier report had been applied, so the next one is its own.
    func awaitSettlement(of account: AccountID,
                         generation: UInt64,
                         mailbox: UInt64,
                         renew: Bool) async throws -> RegistrationSettlement {
        let deadline = ContinuousClock.now + Self.registrationBackstop
        while true {
            guard let signal = await nextRegistrationSignal(in: mailbox, before: deadline) else {
                _ = try liveParameters(account, generation: generation)
                resyncRegistration(account)
                throw RegistrationError.timedOut(account)
            }
            if case .settled(let settlement) = signal, settlement.renew == renew {
                return settlement
            }
        }
    }

    /// The engine's one read of pjsua's registration state, after a wait ran into the backstop.
    /// pjsua can end a transaction and report nothing: when its NAT Contact rewrite re-registers
    /// and that send fails, the 2xx before it was never reported either (`pjsua_acc.c`,
    /// `regc_cb` and `acc_check_nat_addr`). This re-seeds the session from
    /// `pjsua_acc_get_info().expires`: 0 while a transaction is pending, the seconds to the next
    /// refresh, or `PJSIP_EXPIRES_NOT_SPECIFIED` (a cast macro Swift does not import) without one.
    private func resyncRegistration(_ account: AccountID) {
        var info = pjsua_acc_info()
        guard pjsua_acc_get_info(account.raw, &info).isSuccess else { return }
        registration.sessions[account] = switch info.expires {
        case 0: .pending
        case UInt32.max: .unregistered
        default: .registered(refreshDue: .now + .seconds(info.expires))
        }
    }

    // MARK: Sending and confirming

    /// Send a REGISTER (`renew`) or un-REGISTER from a quiet reading, tell `operation`'s callers it
    /// is dispatched, and await the registrar's answer. `nil` when pjsua refused because a
    /// transaction of its own is in flight: the caller waits for quiet again and sends again.
    func exchangeRegistration(_ account: AccountID,
                              renew: Bool,
                              generation: UInt64,
                              mailbox: UInt64,
                              operation: UInt64) async throws -> RegistrationSettlement? {
        do {
            try sendRegistration(account, renew: renew)
        } catch is RegistrationBusy {
            return nil
        }
        markRegistrationDispatched(operation)
        return try await awaitSettlement(of: account, generation: generation,
                                         mailbox: mailbox, renew: renew)
    }

    /// Send a REGISTER (`renew`) or un-REGISTER on `account`'s session, from a quiet reading.
    ///
    /// - Throws: ``RegistrationBusy`` when pjsua refuses because a transaction of its own started
    ///   after the quiet reading (its start not yet applied); the session is then marked pending, so
    ///   the caller's next wait for quiet waits for that transaction. Any other refusal throws
    ///   ``RegistrationError/failed(_:_:)``.
    private func sendRegistration(_ account: AccountID, renew: Bool) throws {
        let status = pjsua_acc_set_registration(account.raw, renew.pjBool)
        if status.isSuccess || status == PJSIP_EBUSY {
            // In flight: ours, or the one that refused ours.
            registration.sessions[account] = .pending
        }
        if status == PJSIP_EBUSY {
            // pjsua has just logged the refusal as an error; say what happens instead.
            pjLog(3, "Acc \(account.raw): another registration transaction is in flight; the "
                     + "\(renew ? "REGISTER" : "un-REGISTER") waits for it to settle")
            throw RegistrationBusy()
        }
        guard status.isSuccess else {
            throw RegistrationError.failed(account, PJSUAError(status: status))
        }
    }

    /// Whether the registrar took what the engine sent: a 2xx; for a REGISTER also an expiry and,
    /// when `push` is set and the registrar listed bindings, one binding that carries it. RFC 3261
    /// §10.3 says a 2xx SHOULD list the bindings; one that lists none is taken at its word.
    func confirmRegistration(_ settlement: RegistrationSettlement,
                             of account: AccountID,
                             push: PushConfiguration?) throws {
        guard settlement.status.isSuccess else {
            throw RegistrationError.failed(account, PJSUAError(status: settlement.status))
        }
        guard (200..<300).contains(settlement.code) else {
            throw RegistrationError.rejected(account, statusCode: settlement.code)
        }
        guard settlement.renew else { return }
        guard settlement.expiration > 0 else { throw RegistrationError.bindingNotConfirmed(account) }
        if let push, !settlement.bindings.isEmpty,
           !settlement.bindings.contains(where: push.isCarried(by:)) {
            throw RegistrationError.bindingNotConfirmed(account)
        }
    }
}
