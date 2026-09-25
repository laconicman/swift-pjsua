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

    /// `reset()` drops *resolved* entries — bound calls and accepted reports — so a
    /// CallKit-dropped call stops answering `isKnownCall` and its later INVITE can
    /// re-report. Reports still in flight survive: CallKit may accept them post-reset.
    func testRemoveResolvedClearsBoundAndReportedKeepsInFlight() async {
        let registry = CallRegistry()
        let inFlight = UUID()
        let reported = UUID()
        let bound = UUID()
        _ = await registry.firstSeen(uuid: inFlight)
        _ = await registry.firstSeen(uuid: reported)
        _ = await registry.firstSeen(uuid: bound)
        await registry.markReported(uuid: reported)
        await registry.bind(call: CallID(0), to: bound)

        await registry.removeResolved()

        let inFlightEntry = await registry.entry(for: inFlight)
        let reportedEntry = await registry.entry(for: reported)
        let boundEntry = await registry.entry(for: bound)
        XCTAssertNotNil(inFlightEntry)
        XCTAssertNil(reportedEntry)
        XCTAssertNil(boundEntry)
    }
}
