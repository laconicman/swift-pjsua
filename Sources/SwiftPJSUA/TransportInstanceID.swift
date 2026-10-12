import PJSIP

/// The identity of one live `pjsip_transport`; for TCP and TLS, one connection. Equal across the
/// ``TransportStateChange`` events of that transport. pjsip may hand the same memory to a later
/// transport once this one is ``TransportState/destroyed``, so do not keep it past that event.
public struct TransportInstanceID: Hashable, Sendable, CustomStringConvertible {
    let raw: UInt
    init(_ transport: UnsafeMutablePointer<pjsip_transport>) { raw = UInt(bitPattern: transport) }
    init(raw: UInt) { self.raw = raw }
    public var description: String { "tp#\(String(raw, radix: 16))" }
}
