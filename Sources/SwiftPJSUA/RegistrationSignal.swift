import PJSIP

/// What the callback bridge tells the engine itself about registrations, on a channel only the
/// engine reads (see `PJSUA+RegistrationLifecycle.swift`). The app hears about registrations
/// through `.registrationState`; these carry what the engine needs to keep its own state and to
/// sequence its work.
enum RegistrationSignal: Sendable {
    /// A REGISTER (`renew`) or un-REGISTER that pjsua started by itself through
    /// `pjsua_acc_set_registration` (`on_reg_started2`): an automatic retry, a Contact rewrite,
    /// an IP-change step. The engine's own sends are not reported; it records them as it makes
    /// them. `pending` is whether the transaction was still open when pjsua reported the start;
    /// it is not when the response had already been processed, and then the settlement has been
    /// reported already.
    case started(account: AccountID, renew: Bool, pending: Bool)

    /// A REGISTER or un-REGISTER on an account's current registration session ended
    /// (`on_reg_state2`).
    case settled(RegistrationSettlement)

    /// The `pjsua_handle_ip_change` sequence finished (`on_ip_change_progress`, `COMPLETED`).
    case ipChangeCompleted

    /// Whether an operation on `account` should look again: an IP change concerns them all.
    func concerns(_ account: AccountID) -> Bool {
        switch self {
        case .started(let started, _, _): started == account
        case .settled(let settlement): settlement.account == account
        case .ipChangeCompleted: true
        }
    }
}

/// The final outcome of one REGISTER or un-REGISTER, as `on_reg_state2` reports it.
struct RegistrationSettlement: Sendable {
    let account: AccountID

    /// `false` for an un-REGISTER.
    let renew: Bool

    /// pjsip's status for the transaction; not success when it ended without a usable SIP
    /// response, a transport failure for instance.
    let status: pj_status_t

    /// The SIP status code. pjsip reports 408 itself when nothing answered.
    let code: Int32

    /// The expiry the registrar granted, in seconds; 0 after an un-REGISTER.
    let expiration: UInt32

    /// After a 2xx that keeps a binding: seconds until the session's refresh timer sends the next
    /// REGISTER, as pjsip scheduled it (`next_reg`). That REGISTER starts without a callback, so
    /// this is the only notice of it.
    let refreshIn: UInt32?

    /// The Contact URIs a response listed: in a 2xx, the registrar's own account of the bindings
    /// it now holds for the address of record.
    let bindings: [String]

    /// A 2xx that pjsip accepted.
    var isSuccess: Bool { status.isSuccess && (200..<300).contains(code) }

    /// A 2xx to a REGISTER that left the account with a binding.
    var isRegistered: Bool { renew && isSuccess && expiration > 0 }
}
