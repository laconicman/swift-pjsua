import XCTest
@testable import SwiftPJSUA
@testable import SwiftPJSUAKit

final class CallRegistryTests: XCTestCase {
    func testFirstSeenIsTrueOnceThenFalse() async {
        let registry = CallRegistry()
        let uuid = UUID()
        let first = await registry.firstSeen(uuid: uuid, sipCallID: "a@host")
        let second = await registry.firstSeen(uuid: uuid, sipCallID: "a@host")
        XCTAssertTrue(first, "first arrival should report a new call")
        XCTAssertFalse(second, "second arrival for the same UUID should not")
    }

    func testSecondArrivalLearnsMissingSipCallID() async {
        let registry = CallRegistry()
        let uuid = UUID()
        // A server-UUID push can arrive without the SIP Call-ID...
        _ = await registry.firstSeen(uuid: uuid, sipCallID: nil)
        // ...then the INVITE supplies it; the entry should learn it without resetting.
        _ = await registry.firstSeen(uuid: uuid, sipCallID: "a@host")
        let entry = await registry.entry(for: uuid)
        XCTAssertEqual(entry?.sipCallID, "a@host")
    }

    func testRemoveClearsEntry() async {
        let registry = CallRegistry()
        let uuid = UUID()
        _ = await registry.firstSeen(uuid: uuid)
        await registry.remove(uuid: uuid)
        let entry = await registry.entry(for: uuid)
        XCTAssertNil(entry)
    }

    /// `reset()` drops *bound* entries — including ones `sweepExpired` skips — so a
    /// CallKit-dropped call stops answering `isKnownCall` even though its `disconnected`
    /// event can no longer find a UUID binding to evict it. Pending entries survive: their
    /// CallKit report may still be in flight and be accepted after the reset.
    func testRemoveBoundClearsBoundKeepsPending() async {
        let registry = CallRegistry()
        let pending = UUID()
        let bound = UUID()
        _ = await registry.firstSeen(uuid: pending)
        _ = await registry.firstSeen(uuid: bound)
        await registry.bind(call: CallID(0), to: bound)

        await registry.removeBound()

        let pendingEntry = await registry.entry(for: pending)
        let boundEntry = await registry.entry(for: bound)
        XCTAssertNotNil(pendingEntry)
        XCTAssertNil(boundEntry)
    }
}
