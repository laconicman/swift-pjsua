/// How long one of the engine's registration operations keeps its caller.
///
/// Either way the engine runs an account's registration operations one at a time, and each one to
/// its end: the wait decides only when the caller gets control back, not when the next operation
/// may start.
public enum RegistrationWait: Sendable, Equatable {
    /// Return once pjsua has the work: the (un-)REGISTER sent, or the IP-change sequence started.
    case dispatched

    /// Return when the work is done: the registrar answered, or the IP-change sequence completed.
    /// A final failure throws ``RegistrationError``, and so does `timeout` running out; the
    /// operation itself still runs to its end.
    case confirmed(timeout: Duration = .seconds(70))
}
