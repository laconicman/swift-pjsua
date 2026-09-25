import Foundation
import XCTest
@testable import SwiftPJSUA

/// `Configuration.logSink` — the app-facing tap on pjsip's own log (`pjsua_logging_config.cb`).
///
/// Two levels of test, because the parts fail differently:
/// * `pjsuaOnLog` itself — the C-shim bridge, where the interesting contract is that `data`
///   is **not** NUL-terminated and `len` is authoritative (a naive `String(cString:)` would
///   read past the buffer).
/// * The plumbing — a real `PJSUA.start()` with a sink installed must produce lines, and the
///   sink's verbosity ceiling is `logging_config.level`, not `console_level`.
final class LogSinkTests: XCTestCase {

    /// Sendable collector for lines arriving on arbitrary pjsip threads.
    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [(level: Int32, text: String)] = []
        func append(_ level: Int32, _ text: String) {
            lock.lock()
            stored.append((level, text))
            lock.unlock()
        }
        var snapshot: [(level: Int32, text: String)] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        var lastText: String? { snapshot.last?.text }
    }

    /// `pjsuaOnLog` must honour `len` — pjsip log buffers are not NUL-terminated strings.
    func testOnLogDecodesExactlyLenBytes() {
        let lines = Lines()
        pjsuaLogSink = { level, text in lines.append(level, text) }
        // -1 keeps the console-forward half silent — this test has no pjsua running, and
        // pj_log_write would otherwise echo the line to stdout.
        pjsuaLogConsoleLevel = -1
        defer { pjsuaLogSink = nil; pjsuaLogConsoleLevel = 4; pjsuaLogSinkLevel = 5 }

        var buffer: [CChar] = Array("partial line".utf8CString) // NUL-terminated storage…
        pjsuaOnLog(3, &buffer, 7)                              // …but only 7 bytes are logged
        XCTAssertEqual(lines.lastText, "partial",
                       "sink must stop at len, not at the NUL")

        pjsuaOnLog(3, nil, 5) // no data pointer — must not call the sink or crash
        XCTAssertEqual(lines.snapshot.count, 1)
    }

    /// The sink's ceiling is applied *inside* the callback — upstream both gates are raised
    /// to the max of the two requests, so a line between `logSinkLevel` and the console
    /// ceiling reaches `cb` and must not reach the sink.
    func testSinkCeilingAppliedInsideCallback() {
        let lines = Lines()
        pjsuaLogSink = { level, text in lines.append(level, text) }
        pjsuaLogConsoleLevel = -1
        pjsuaLogSinkLevel = 3
        defer { pjsuaLogSink = nil; pjsuaLogConsoleLevel = 4; pjsuaLogSinkLevel = 5 }

        var buffer: [CChar] = Array("line".utf8CString)
        pjsuaOnLog(4, &buffer, 4) // above the sink ceiling — dropped
        pjsuaOnLog(3, &buffer, 4) // at it — delivered
        XCTAssertEqual(lines.snapshot.map(\.level), [3])
    }

    /// A real engine start produces log lines through the configured sink — end-to-end proof
    /// that `log.cb` is wired, gated, and fed on pjsip's own threads.
    func testEngineStartFeedsLogSink() async throws {
        let lines = Lines()
        var config = PJSUA.Configuration()
        config.logSink = { level, text in lines.append(level, text) }

        let engine = PJSUA()
        try await engine.start(config)
        // Init and start lines are emitted synchronously inside start(), so the sink has
        // already been fed by the time it returns.
        try await engine.shutdown()

        let captured = lines.snapshot
        XCTAssertFalse(captured.isEmpty, "logSink received nothing from engine start")
        XCTAssertTrue(captured.contains { $0.text.contains("PJSUA") },
                      "expected pjsip's own startup banner among \(captured.count) lines")
        XCTAssertTrue(captured.allSatisfy { (0...6).contains($0.level) },
                      "unexpected log level \(captured.map(\.level))")
    }

    /// `logSink` is runtime-only: it must not participate in Codable round-trips, while the
    /// new scalar fields do.
    func testConfigurationRoundTripExcludesSink() throws {
        var config = PJSUA.Configuration()
        config.logSinkLevel = 3
        config.messageLogging = false
        config.logSink = { _, _ in }

        let decoded = try JSONDecoder().decode(PJSUA.Configuration.self,
                                               from: JSONEncoder().encode(config))
        XCTAssertNil(decoded.logSink)
        XCTAssertEqual(decoded.logSinkLevel, 3)
        XCTAssertFalse(decoded.messageLogging)
        // A configured sink changes behaviour, so `==` counts set-vs-nil as unequal even
        // though the closure itself has no equality to compare.
        XCTAssertNotEqual(decoded, config)
    }
}
