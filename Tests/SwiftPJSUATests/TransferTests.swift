import Foundation
import PJSIP
import XCTest
@testable import SwiftPJSUA

/// Transfer API surface — the sync error paths are testable without a SIP peer:
/// `pjsua_call_xfer` / `pjsua_call_xfer_replaces` validate the call id via `acquire_call`
/// and return a failure status for a slot with no call on it. (`CallID(0)` rather than a
/// huge id — pjsua *asserts* on out-of-range ids, so only the in-range-but-empty slot
/// exercises the status path.) The success path needs a live REFER recipient — that's the
/// Offhook integration suite's job.
final class TransferTests: XCTestCase {

    private var engine: PJSUA?

    override func tearDown() async throws {
        try? await engine?.shutdown()
        engine = nil
    }

    func testTransferOnEmptyCallSlotThrows() async throws {
        let engine = PJSUA()
        self.engine = engine
        try await engine.start(PJSUA.Configuration())

        do {
            try await engine.transfer(CallID(0), to: "sip:nobody@example.org")
            XCTFail("transfer on a slot with no call must throw")
        } catch { }
        do {
            try await engine.attendedTransfer(CallID(0), replacing: CallID(1))
            XCTFail("attendedTransfer on empty slots must throw")
        } catch { }
        do {
            try await engine.attendedTransfer(CallID(0), replacing: CallID(1), requireReplaces: false)
            XCTFail("attendedTransfer (no Require) on empty slots must throw")
        } catch { }
    }
}
