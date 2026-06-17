import PJSIP

/// Opaque, type-safe handle for a PJSUA account (wraps `pjsua_acc_id`, an `Int32`).
public struct AccountID: Hashable, Sendable, CustomStringConvertible {
    public let raw: pjsua_acc_id
    init(_ raw: pjsua_acc_id) { self.raw = raw }
    public var description: String { "acc#\(raw)" }
}
