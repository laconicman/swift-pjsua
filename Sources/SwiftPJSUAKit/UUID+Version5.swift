import Foundation
import CryptoKit

extension UUID {
    /// Create a deterministic RFC 4122 / RFC 9562 version-5 (SHA-1) UUID from `name` within
    /// `namespace`.
    ///
    /// Same inputs always produce the same UUID. We use it to derive a stable CallKit UUID
    /// from a SIP `Call-ID`, so a VoIP push and the INVITE that arrives over a persisted
    /// connection compute the *same* UUID and CallKit treats them as one call (no double ring).
    ///
    /// ## Corner case: namespace byte order
    /// RFC 4122 §4.3 requires hashing the namespace in **network byte order** (the 16 bytes
    /// as they appear in the canonical `xxxxxxxx-xxxx-...` string, big-endian fields).
    /// Foundation's `UUID.uuid` tuple already stores the bytes in exactly that order, so
    /// `withUnsafeBytes(of: namespace.uuid)` feeds the correct bytes with **no byte-swap**.
    /// This is the classic interop trap: a Microsoft `Guid` (or `System.Guid.ToByteArray()`)
    /// stores the first three fields little-endian, so naively hashing its raw bytes yields a
    /// *different* UUIDv5 than every RFC-compliant implementation. We are RFC-correct; if we
    /// ever need to match a value produced from a little-endian GUID, swap the first three
    /// fields before hashing.
    ///
    /// ## Why hand-rolled (no third-party dependency)
    /// This is ~15 lines over CryptoKit (a system framework). For a package other code depends
    /// on, that's preferable to taking a dependency: both surveyed UUIDv5 libraries
    /// (`doneservices/UUIDNamespaces`, `baarde/uuid-kit`) are single-contributor and inactive
    /// since 2019/2022, and `UUIDNamespaces` ships with no LICENSE (a redistribution blocker).
    /// Verified against the RFC known-answer (see `CallIdentityTests`).
    public init(version5 name: String, namespace: UUID) {
        var hasher = Insecure.SHA1()
        withUnsafeBytes(of: namespace.uuid) { hasher.update(bufferPointer: $0) }
        hasher.update(data: Data(name.utf8))
        let digest = hasher.finalize()

        var bytes = Array(digest.prefix(16))    // first 16 of the 20 SHA-1 bytes
        bytes[6] = (bytes[6] & 0x0F) | 0x50      // version 5 (0101 in the high nibble)
        bytes[8] = (bytes[8] & 0x3F) | 0x80      // RFC 4122 variant (10 in the high bits)

        self = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}
