import Foundation
import SwiftPJSUA

/// Short-lived dedup map so a VoIP push and the matching SIP INVITE resolve to one CallKit
/// call. Keyed by the CallKit `UUID` (computed identically on both paths via ``CallIdentity``):
/// whichever path arrives first reports the call to CallKit, the second just binds its
/// engine ``CallID`` / SIP `Call-ID` onto the same entry.
///
/// Entries are reclaimed two ways:
/// - **Terminal call state** — once an engine ``CallID`` is bound, the call is live and the
///   entry survives until ``CallSessionRouter`` calls ``remove(uuid:)`` on `.disconnected` /
///   `CXEndCallAction`.
/// - **TTL sweep** — a *pending* entry (reported to CallKit but with no `CallID` yet, i.e. a VoIP
///   push whose INVITE never arrived) would otherwise leak forever. ``sweepExpired(olderThan:)``
///   reaps those after a short TTL so the router can withdraw the stale ringing call.
public actor CallRegistry {
    public struct Entry: Sendable, Equatable {
        public var uuid: UUID
        public var sipCallID: String?
        public var call: CallID?
        /// When the entry was first created. Used only to evict orphaned *pending* entries; not
        /// refreshed when later identifiers are merged.
        public var createdAt: Date

        public init(uuid: UUID, sipCallID: String? = nil, call: CallID? = nil,
                    createdAt: Date = Date()) {
            self.uuid = uuid
            self.sipCallID = sipCallID
            self.call = call
            self.createdAt = createdAt
        }
    }

    /// How long a *pending* entry (no engine ``CallID`` bound yet) may live before being swept.
    /// Comfortably longer than the push→INVITE window — Apple expects the app to report the call
    /// within seconds of a PushKit VoIP notification, and the matching INVITE follows over the
    /// signalling connection — yet short enough that a lost INVITE doesn't leave a phantom entry.
    public static let defaultPendingTTL: TimeInterval = 45

    private var entries: [UUID: Entry] = [:]

    /// Clock used for `createdAt` stamping and TTL comparison; injectable so tests can drive time
    /// deterministically rather than sleeping.
    private let now: @Sendable () -> Date

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

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
        entries[uuid] = Entry(uuid: uuid, sipCallID: sipCallID, call: call, createdAt: now())
        return true
    }

    public func entry(for uuid: UUID) -> Entry? { entries[uuid] }

    /// Bind an engine ``CallID`` to an existing entry (e.g. when the INVITE arrives after the
    /// push has already reported the call). Once bound, the entry is no longer swept by TTL.
    public func bind(call: CallID, to uuid: UUID) {
        entries[uuid]?.call = call
    }

    public func remove(uuid: UUID) {
        entries[uuid] = nil
    }

    /// Evict *pending* entries — those still without an engine ``CallID`` — older than `ttl`.
    /// Bound (live) calls are never swept here; they are removed on terminal call state via
    /// ``remove(uuid:)``. Called periodically by ``CallSessionRouter``.
    ///
    /// - Returns: the UUIDs evicted, so the router can withdraw any still-ringing CallKit report
    ///   (the push's INVITE never arrived).
    @discardableResult
    public func sweepExpired(olderThan ttl: TimeInterval = CallRegistry.defaultPendingTTL) -> [UUID] {
        let cutoff = now()
        let expired = entries.compactMap { uuid, entry -> UUID? in
            guard entry.call == nil, cutoff.timeIntervalSince(entry.createdAt) > ttl else { return nil }
            return uuid
        }
        for uuid in expired { entries[uuid] = nil }
        return expired
    }
}
