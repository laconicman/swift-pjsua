import PJSIP

/// Opaque, type-safe handle for a PJSUA call (wraps `pjsua_call_id`, an `Int32`).
public struct CallID: Hashable, Sendable, CustomStringConvertible {
    public let raw: pjsua_call_id
    init(_ raw: pjsua_call_id) { self.raw = raw }
    public var description: String { "call#\(raw)" }
}
