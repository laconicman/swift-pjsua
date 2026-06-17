/// Errors for misuse of the engine API that are not PJSIP `pj_status_t` failures.
public enum PJSUAUsageError: Error, Equatable, CustomStringConvertible {
    /// An operation referenced an account that the engine has no record of (it was not
    /// created via ``PJSUA/addAccount(id:registrar:username:password:realm:push:makeDefault:)``,
    /// or it has since been removed).
    case unknownAccount(AccountID)

    public var description: String {
        switch self {
        case .unknownAccount(let account):
            return "PJSUAUsageError.unknownAccount(\(account))"
        }
    }
}
