import Foundation
import XCTest
@testable import SwiftPJSUA

/// `handleIPChange` — the pjsua_handle_ip_change wrapper. The interesting contract is the
/// *callback chain*: `on_ip_change_progress` must translate the op + info union into
/// `.ipChangeProgress` events on the guaranteed channel, ending in `.completed`. The sync
/// call itself only throws on a pjsua status failure, which a running engine won't produce.
final class IPChangeTests: XCTestCase {

    private var engine: PJSUA?

    override func tearDown() async throws {
        try? await engine?.shutdown()
        engine = nil
    }

    /// On a running engine with no accounts the sequence still runs (shutdown transports →
    /// restart listeners → completed) — asserts the event is emitted *and* terminates.
    func testHandleIPChangeEmitsProgressEndingInCompleted() async throws {
        let engine = PJSUA()
        self.engine = engine
        try await engine.start(PJSUA.Configuration())

        let stream = engine.callEvents
        try await engine.handleIPChange()

        let completed = await withTaskGroup(of: Bool.self) { group -> Bool in
            group.addTask {
                for await event in stream {
                    if case .ipChangeProgress(let op, _, _, _, _) = event, op == .completed {
                        return true
                    }
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        XCTAssertTrue(completed,
                      "handleIPChange never reported .completed on callEvents")
    }
}
