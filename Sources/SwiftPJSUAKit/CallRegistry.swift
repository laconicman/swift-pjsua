import Foundation
import SwiftPJSUA

/// Short-lived dedup map so a VoIP push and the matching SIP INVITE resolve to one CallKit
/// call. Keyed by the CallKit `UUID` (computed identically on both paths via ``CallIdentity``):
/// whichever path arrives first reports the call to CallKit, the second just binds its
/// engine ``CallID`` / SIP `Call-ID` onto the same entry.
public actor CallRegistry {
    public struct Entry: Sendable, Equatable {
        public var uuid: UUID
        public var sipCallID: String?
        public var call: CallID?

        public init(uuid: UUID, sipCallID: String? = nil, call: CallID? = nil) {
            self.uuid = uuid
            self.sipCallID = sipCallID
            self.call = call
        }
    }

    private var entries: [UUID: Entry] = [:]

    public init() {}

    /// Record the call for `uuid`, merging any newly-learned identifiers.
    ///
    /// - Returns: `true` the first time a `uuid` is seen (the caller should report a new
    ///   incoming call to CallKit); `false` on subsequent arrivals (already reported).
    @discardableResult
    public func firstSeen(uuid: UUID, sipCallID: String? = nil, call: CallID? = nil) -> Bool {
        if var existing = entries[uuid] {
            if existing.sipCallID == nil { existing.sipCallID = sipCallID }
            if existing.call == nil { existing.call = call }
            entries[uuid] = existing
            return false
        }
        entries[uuid] = Entry(uuid: uuid, sipCallID: sipCallID, call: call)
        return true
    }

    public func entry(for uuid: UUID) -> Entry? { entries[uuid] }

    /// Bind an engine ``CallID`` to an existing entry (e.g. when the INVITE arrives after the
    /// push has already reported the call).
    public func bind(call: CallID, to uuid: UUID) {
        entries[uuid]?.call = call
    }

    public func remove(uuid: UUID) {
        entries[uuid] = nil
    }
}
