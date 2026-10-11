/// Why a registration operation did not end the way it was asked to.
///
/// Every account-level case names the account, so a caller that never got an ``AccountID`` back
/// — an add whose first REGISTER was refused — still has one.
public enum RegistrationError: Error, Equatable, CustomStringConvertible {
    /// The (un-)REGISTER got a final non-2xx response. pjsip reports 408 itself when nothing
    /// answered.
    case rejected(AccountID, statusCode: Int32)

    /// pjsip could not send the (un-)REGISTER, or its transaction ended without a SIP response it
    /// could report; the status says why.
    case failed(AccountID, PJSUAError)

    /// The registrar answered 2xx, but either granted no expiry or listed bindings none of which
    /// carries the account's push parameters: it did not keep the Contact the engine sent.
    case bindingNotConfirmed(AccountID)

    /// The caller's ``RegistrationWait/confirmed(timeout:)`` ran out, or a transaction on the
    /// account did not settle within the engine's backstop. The operation runs on to its end; the
    /// next `.registrationState` event for the account tells how it ended.
    case timedOut(AccountID)

    /// An IP-change sequence did not report completion in time.
    case ipChangeTimedOut

    public var description: String {
        switch self {
        case .rejected(let account, let statusCode):
            "RegistrationError.rejected(\(account), statusCode: \(statusCode))"
        case .failed(let account, let error):
            "RegistrationError.failed(\(account), \(error))"
        case .bindingNotConfirmed(let account):
            "RegistrationError.bindingNotConfirmed(\(account))"
        case .timedOut(let account):
            "RegistrationError.timedOut(\(account))"
        case .ipChangeTimedOut:
            "RegistrationError.ipChangeTimedOut"
        }
    }
}
