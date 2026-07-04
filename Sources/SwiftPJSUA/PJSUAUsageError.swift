/// Errors for misuse of the engine API that are not PJSIP `pj_status_t` failures.
public enum PJSUAUsageError: Error, Equatable, CustomStringConvertible {
    /// An operation referenced an account that the engine has no record of (it was not
    /// created via ``PJSUA/addAccount(id:registrar:username:password:realm:push:makeDefault:)``,
    /// or it has since been removed).
    case unknownAccount(AccountID)

    /// A mid-call operation needed the call's conference port (e.g. mute), but the call has
    /// no media yet (`pjsua_call_get_conf_port` returned `PJSUA_INVALID_ID`). Retry once the
    /// `.callMediaState` event reports an active audio stream.
    case callHasNoMediaPort(CallID)

    /// ``PJSUA/addAccount(id:registrar:username:password:realm:push:makeDefault:)`` was called
    /// with the pjsua account table already full. The table is a fixed array sized
    /// `PJSUA_MAX_ACC` at *binary* build time (4 in the shipped `PJ_CONFIG_IPHONE` build) and
    /// overflowing it is a hard C assert — the engine guards and throws instead. Free a slot
    /// with ``PJSUA/removeAccount(_:)`` or rebuild `swift-pjsip` with a larger table.
    case accountTableFull(capacity: UInt32)

    public var description: String {
        switch self {
        case .unknownAccount(let account):
            return "PJSUAUsageError.unknownAccount(\(account))"
        case .callHasNoMediaPort(let call):
            return "PJSUAUsageError.callHasNoMediaPort(\(call))"
        case .accountTableFull(let capacity):
            return "PJSUAUsageError.accountTableFull(capacity: \(capacity))"
        }
    }
}
