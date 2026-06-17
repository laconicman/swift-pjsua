import Foundation

/// Computes the single CallKit `UUID` for a logical call, identically on the VoIP-push path
/// and the SIP-INVITE path, so the two never produce two rings for one call.
public enum CallIdentity {
    /// Fixed namespace for deriving call UUIDs from SIP Call-IDs. Do **not** change it: doing
    /// so would shift every derived UUID and break dedup against already-reported calls.
    public static let namespace = UUID(uuidString: "B2D6F0E2-9B9A-5E7C-8F1A-9C2D3E4F5A6B")!

    /// The CallKit UUID for a call.
    ///
    /// Resolution order:
    /// 1. a server-supplied UUID carried in the push payload (authoritative when present);
    /// 2. otherwise a deterministic UUIDv5 from the SIP `Call-ID` — the INVITE carries the
    ///    same `Call-ID`, so both paths agree;
    /// 3. otherwise a fresh random UUID (no identifier to dedup on — last resort).
    public static func uuid(serverProvided: UUID?, sipCallID: String?) -> UUID {
        if let serverProvided {
            return serverProvided
        }
        if let sipCallID, !sipCallID.isEmpty {
            return UUID(version5: sipCallID, namespace: namespace)
        }
        return UUID()
    }
}
