import XCTest
@testable import SwiftPJSUA

/// Codec enumeration and priorities: decoding defaults, the SDP-order list `audioCodecs()`
/// reports, prefix matching, and the start-time validation (`zeroClockRate`, `unknownCodec`).
final class CodecTests: XCTestCase {

    private var engine: PJSUA?

    override func tearDown() async throws {
        await engine?.shutdown()
        engine = nil
    }

    /// A document without `media` or `codecPriorities` decodes to the defaults, and a set
    /// document round-trips through JSON unchanged.
    func testDocumentWithoutMediaOrCodecPrioritiesDecodesToDefaults() throws {
        let decoded = try JSONDecoder().decode(PJSUA.Configuration.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded.media.clockRate, 16000)
        XCTAssertEqual(decoded.media.soundDeviceClockRate, 0)
        XCTAssertTrue(decoded.codecPriorities.isEmpty)
        XCTAssertTrue(decoded.videoCodecPriorities.isEmpty)

        var configuration = PJSUA.Configuration()
        configuration.media.clockRate = 48000
        configuration.media.soundDeviceClockRate = 48000
        configuration.codecPriorities = ["opus": 255, "PCMU": 0]
        configuration.videoCodecPriorities = ["H264": 1]
        let roundTrip = try JSONDecoder().decode(
            PJSUA.Configuration.self, from: JSONEncoder().encode(configuration))
        XCTAssertEqual(roundTrip, configuration)
    }

    /// `==` covers the new fields: each alone makes two default configs unequal.
    func testEqualityCoversNewFields() {
        XCTAssertEqual(PJSUA.Configuration(), PJSUA.Configuration())

        var clock = PJSUA.Configuration()
        clock.media.clockRate = 48000
        XCTAssertNotEqual(clock, PJSUA.Configuration())

        var priorities = PJSUA.Configuration()
        priorities.codecPriorities = ["opus": 255]
        XCTAssertNotEqual(priorities, PJSUA.Configuration())

        var videoPriorities = PJSUA.Configuration()
        videoPriorities.videoCodecPriorities = ["H264": 255]
        XCTAssertNotEqual(videoPriorities, PJSUA.Configuration())
    }

    /// pjsua does not substitute its default for a zero clock rate — start refuses it, and
    /// because nothing was created the same engine still starts with a clean config.
    func testZeroClockRateIsRefused() async throws {
        let engine = PJSUA()
        self.engine = engine

        var zero = PJSUA.Configuration()
        zero.media.clockRate = 0
        do {
            try await engine.start(zero)
            XCTFail("a start with media.clockRate == 0 succeeded")
        } catch PJSUAUsageError.zeroClockRate {
            // expected
        }
        let runningAfterFailure = await engine.isRunning
        XCTAssertFalse(runningAfterFailure)

        var configuration = PJSUA.Configuration()
        configuration.transports = [.init("udp", .udp, port: 0)]
        try await engine.start(configuration)
        let running = await engine.isRunning
        XCTAssertTrue(running)
    }

    /// An unmatched priority key fails the start after pjsua is initialised — and the failure
    /// is reported as `unknownCodec` naming the key, not as a generic pj_status_t.
    func testUnknownCodecIdFailsStartAndTheStartCanBeRetried() async throws {
        let engine = PJSUA()
        self.engine = engine

        var bad = PJSUA.Configuration()
        bad.transports = [.init("udp", .udp, port: 0)]
        bad.codecPriorities = ["nonesuch": 1]
        do {
            try await engine.start(bad)
            XCTFail("a start with an unmatched codec id succeeded")
        } catch PJSUAUsageError.unknownCodec("nonesuch") {
            // expected
        }

        var configuration = PJSUA.Configuration()
        configuration.transports = [.init("udp", .udp, port: 0)]
        try await engine.start(configuration)
        let running = await engine.isRunning
        XCTAssertTrue(running)
    }

    /// The 0.4.0 binary ships Opus plus the always-built set — enumeration proves what the
    /// factory registration promises, in offer order.
    func testAudioCodecsListOpusOnTheShippedBinary() async throws {
        let engine = PJSUA()
        self.engine = engine
        var configuration = PJSUA.Configuration()
        configuration.transports = [.init("udp", .udp, port: 0)]
        try await engine.start(configuration)

        let codecs = try await engine.audioCodecs()
        print("[codecs] audio, default priorities:")
        for codec in codecs {
            print("[codecs]   \(codec.id) prio=\(codec.priority)")
        }

        XCTAssertTrue(codecs.contains { $0.id.lowercased() == "opus/48000/2" },
                      "opus/48000/2 missing from \(codecs.map(\.id))")
        for prefix in ["pcmu/", "pcma/", "g722/", "ilbc/", "g729/"] {
            XCTAssertTrue(codecs.contains { $0.id.lowercased().hasPrefix(prefix) },
                          "no codec id starts with \(prefix) in \(codecs.map(\.id))")
        }
    }

    /// `"opus"`, `"PCMU"`, `"ilbc"` all match regardless of case; applied in ascending key
    /// order, `"opus"` — the greatest key — lands at the top, stored as 254, with PCMU's
    /// earlier 255 demoted to 254 right behind it. iLBC at 0 sits in the disabled tail.
    func testPrefixMatchIsCaseInsensitiveAndKeysApplyInAscendingOrder() async throws {
        let engine = PJSUA()
        self.engine = engine
        var configuration = PJSUA.Configuration()
        configuration.transports = [.init("udp", .udp, port: 0)]
        configuration.codecPriorities = ["opus": 255, "PCMU": 255, "ilbc": 0]
        try await engine.start(configuration)

        let codecs = try await engine.audioCodecs()
        print("[codecs] audio, opus>PCMU, ilbc disabled:")
        for codec in codecs {
            print("[codecs]   \(codec.id) prio=\(codec.priority)")
        }

        XCTAssertTrue(codecs[0].id.lowercased().hasPrefix("opus/"),
                      "expected opus first, got \(codecs.map(\.id))")
        XCTAssertEqual(codecs[0].priority, 254)
        XCTAssertTrue(codecs[1].id.lowercased().hasPrefix("pcmu/"),
                      "expected PCMU second, got \(codecs.map(\.id))")
        XCTAssertEqual(codecs[1].priority, 254)

        guard let ilbc = codecs.firstIndex(where: { $0.id.lowercased().hasPrefix("ilbc/") }) else {
            return XCTFail("iLBC missing from \(codecs.map(\.id))")
        }
        XCTAssertEqual(codecs[ilbc].priority, 0)
        let lastEnabled = codecs.lastIndex { $0.priority > 0 }
        XCTAssertGreaterThan(ilbc, lastEnabled ?? -1,
                             "a disabled codec outranks an enabled one")
    }

    /// Priorities are not start-time-only: pjsua reads the codec manager at every negotiation,
    /// so a running engine takes a new order for the next offer or answer.
    func testPrioritiesCanBeChangedAtRuntime() async throws {
        let engine = PJSUA()
        self.engine = engine
        var configuration = PJSUA.Configuration()
        configuration.transports = [.init("udp", .udp, port: 0)]
        try await engine.start(configuration)

        try await engine.setCodecPriorities(["PCMU": 255])
        var codecs = try await engine.audioCodecs()
        XCTAssertTrue(codecs[0].id.lowercased().hasPrefix("pcmu/"),
                      "expected PCMU first, got \(codecs.map(\.id))")

        try await engine.setCodecPriorities(["opus": 255, "PCMU": 0])
        codecs = try await engine.audioCodecs()
        XCTAssertTrue(codecs[0].id.lowercased().hasPrefix("opus/"),
                      "expected opus first, got \(codecs.map(\.id))")
        let pcmu = codecs.first { $0.id.lowercased().hasPrefix("pcmu/") }
        XCTAssertEqual(pcmu?.priority, 0)

        let before = codecs
        do {
            try await engine.setCodecPriorities(["nonesuch": 1])
            XCTFail("an unmatched codec id succeeded")
        } catch PJSUAUsageError.unknownCodec("nonesuch") {
            // expected
        }
        codecs = try await engine.audioCodecs()
        XCTAssertEqual(codecs, before)
    }

    /// `videoCodecs()` must at least enumerate without error — the list can legitimately be
    /// empty if the binary registers no video codecs — and an unmatched key against the video
    /// namespace fails the start the same way an audio one does.
    func testVideoCodecsEnumerateAndUnknownVideoIdFailsStart() async throws {
        let engine = PJSUA()
        self.engine = engine
        var configuration = PJSUA.Configuration()
        configuration.transports = [.init("udp", .udp, port: 0)]
        try await engine.start(configuration)

        let codecs = try await engine.videoCodecs()
        print("[codecs] video, default priorities:")
        for codec in codecs {
            print("[codecs]   \(codec.id) prio=\(codec.priority) \"\(codec.description)\"")
        }
        await engine.shutdown()
        self.engine = nil

        let second = PJSUA()
        self.engine = second
        var bad = PJSUA.Configuration()
        bad.transports = [.init("udp", .udp, port: 0)]
        bad.videoCodecPriorities = ["nonesuch": 1]
        do {
            try await second.start(bad)
            XCTFail("a start with an unmatched video codec id succeeded")
        } catch PJSUAUsageError.unknownCodec("nonesuch") {
            // expected
        }
    }
}
