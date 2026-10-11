import XCTest
@testable import SwiftPJSUA

/// `PJSUA.start()` that fails after `pjsua_create()` destroys pjsua again, so the same engine can
/// be started once the cause is gone.
final class StartTests: XCTestCase {

    private var engine: PJSUA?

    override func tearDown() async throws {
        await engine?.shutdown()
        engine = nil
    }

    /// Two transports with one name fail the start after pjsua is initialised and the first
    /// transport exists. The retry would trip over either if the failed start had left them.
    func testAFailedStartCanBeRetried() async throws {
        let engine = PJSUA()
        self.engine = engine

        var clashing = PJSUA.Configuration()
        clashing.transports = [.init("udp", .udp, port: 0), .init("udp", .udp, port: 0)]
        do {
            try await engine.start(clashing)
            XCTFail("a start with two transports named alike succeeded")
        } catch PJSUAUsageError.duplicateTransportName("udp") {
            // expected
        }

        var configuration = PJSUA.Configuration()
        configuration.transports = [.init("udp", .udp, port: 0)]
        try await engine.start(configuration)
        let running = await engine.isRunning
        XCTAssertTrue(running)
    }
}
