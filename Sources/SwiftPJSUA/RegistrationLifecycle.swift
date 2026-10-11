/// The engine actor's registration bookkeeping, kept from pjsua's callbacks and the engine's own
/// calls; the mechanics are in `PJSUA+RegistrationLifecycle.swift`, the design in
/// `docs/Registration-Lifecycle.md`.
///
/// - **Sessions**: what each account's registration session is doing, as the callbacks report it.
///   pjsua has no getter for most of it.
/// - **Turns**: registration operations run one at a time per account; an IP change runs alone.
/// - **Operations**: what callers wait on — dispatch or the end.
/// - **Mailboxes**: the signals each running operation has yet to read.
struct RegistrationLifecycle {

    // MARK: Sessions

    /// An account's registration session, as the callbacks have reported it so far.
    enum Session: Equatable {
        /// No registration: never registered, un-REGISTERed, or failed — pjsua destroys the session
        /// on every failure and after an un-REGISTER.
        case unregistered
        /// Registered. The session's own refresh timer sends the next REGISTER at `refreshDue`,
        /// with no callback to say so.
        case registered(refreshDue: ContinuousClock.Instant?)
        /// A REGISTER or un-REGISTER is in flight.
        case pending
    }

    /// Sessions of the accounts the engine added; signals for others are ignored.
    var sessions: [AccountID: Session] = [:]

    /// Set by ``PJSUA/shutdown()``: no signal comes any more, so nothing may wait for one.
    var stopped = false

    /// One counter for every id below.
    private var lastID: UInt64 = 0

    mutating func makeID() -> UInt64 {
        lastID += 1
        return lastID
    }

    // MARK: Turns

    /// What an operation needs to itself.
    enum Scope: Equatable {
        case account(AccountID)
        /// Every account: an IP change, which holds its turn until pjsua reports the sequence
        /// `COMPLETED`, so no account operation runs while pjsua re-registers the accounts.
        case all

        func conflicts(with other: Scope) -> Bool {
            self == .all || other == .all || self == other
        }
    }

    /// Turns asked for and not yet granted, in the order asked.
    var waitingTurns: [(ticket: UInt64, scope: Scope)] = []
    var runningTurns: [UInt64: Scope] = [:]
    var turnWakers: [UInt64: CheckedContinuation<Void, Never>] = [:]

    /// Whether `ticket` may run now: nothing running conflicts with it, and nothing asked earlier
    /// that conflicts with it is still waiting. First come, first served among conflicting
    /// operations; operations on different accounts do not wait for each other.
    func mayStart(_ ticket: UInt64) -> Bool {
        guard let index = waitingTurns.firstIndex(where: { $0.ticket == ticket }) else { return false }
        let scope = waitingTurns[index].scope
        return !runningTurns.values.contains { $0.conflicts(with: scope) }
            && !waitingTurns[..<index].contains { $0.scope.conflicts(with: scope) }
    }

    // MARK: Operations

    /// A request that may join an operation of the same kind still waiting for its turn. The
    /// generation keeps a request from joining an operation for an account whose id was recycled.
    enum JoinKey: Hashable {
        case reRegister(AccountID, generation: UInt64)
        case ipChange
    }

    struct Operation {
        enum Phase {
            case waiting, running, dispatched
            case finished(Result<Void, any Error>)
        }

        struct Waiter {
            /// `true`: the caller is done once the work is dispatched.
            let untilDispatched: Bool
            /// Resumed with the result, or `nil` when the caller's deadline passed first.
            let continuation: CheckedContinuation<Result<Void, any Error>?, Never>
        }

        var phase: Phase = .waiting
        var waiters: [UInt64: Waiter] = [:]
    }

    var operations: [UInt64: Operation] = [:]
    var joinable: [JoinKey: UInt64] = [:]

    // MARK: Mailboxes

    /// Where an operation's signals wait for it: every signal that concerns its account (`nil`:
    /// every signal), from the moment the operation opens it, so none is lost between its
    /// synchronous steps and its waits.
    struct Mailbox {
        let account: AccountID?
        var pending: [RegistrationSignal] = []
        var waiting: (token: UInt64, continuation: CheckedContinuation<RegistrationSignal?, Never>)?
    }

    var mailboxes: [UInt64: Mailbox] = [:]
}
