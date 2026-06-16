import Foundation
import CryptoKit

extension UUID {
    /// Create a deterministic RFC 4122 version-5 (SHA-1) UUID from `name` within `namespace`.
    ///
    /// Same inputs always produce the same UUID. We use it to derive a stable CallKit UUID
    /// from a SIP `Call-ID`, so a VoIP push and the INVITE that arrives over a persisted
    /// connection compute the *same* UUID and CallKit treats them as one call (no double ring).
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
