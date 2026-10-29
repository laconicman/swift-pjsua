import PJSIP
import XCTest
@testable import SwiftPJSUA

/// `CallMediaIntent` bookkeeping — testable without a SIP peer because the intent is
/// engine-side state the call APIs record whether or not media exists yet. (`CallID(0)`
/// rather than a huge id — pjsua asserts on out-of-range ids, and the in-range-but-empty
/// slot is exactly the "call with no media" case.) The *application* of the intent —
/// fail-closed mic wiring, video-transmission re-arm after a rebuild, `on_call_rx_offer` — is the
/// Offhook live suite's job (test06c), not this one's.
final class MediaIntentTests: XCTestCase {

    private var engine: PJSUA?

    override func tearDown() async throws {
        await engine?.shutdown()
        engine = nil
    }

    /// A mute issued before any media exists must be *recorded*, not thrown away with
    /// `callHasNoMediaPort` — the media-state callback applies it when the stream comes
    /// up. (That callback path is what makes muting-before-media meaningful at all.)
    func testMuteBeforeMediaRecordsIntentAndDoesNotThrow() async throws {
        let engine = PJSUA()
        self.engine = engine
        try await engine.start(PJSUA.Configuration())

        try await engine.setMute(CallID(0), muted: true)
        var intent = await engine.mediaIntent(for: CallID(0))
        XCTAssertTrue(intent.microphoneMuted)

        try await engine.setMute(CallID(0), muted: false)
        intent = await engine.mediaIntent(for: CallID(0))
        XCTAssertFalse(intent.microphoneMuted)
    }

    /// `setVideoTransmission` on a call with no video stream records the intent and does not
    /// throw — it is applied when a stream next becomes active (`on_call_media_state` →
    /// the actor's START_TRANSMIT), not rejected because none exists yet.
    func testTransmitsVideoRecordsIntentWithoutVideoStream() async throws {
        let engine = PJSUA()
        self.engine = engine
        try await engine.start(PJSUA.Configuration())

        try await engine.setVideoTransmission(CallID(0), enabled: true)
        var intent = await engine.mediaIntent(for: CallID(0))
        XCTAssertTrue(intent.transmitsVideo)

        try await engine.setVideoTransmission(CallID(0), enabled: false)
        intent = await engine.mediaIntent(for: CallID(0))
        XCTAssertFalse(intent.transmitsVideo)
    }

    /// `acceptsVideo` defaults to `true` and round-trips through `setAcceptsVideo` —
    /// the policy `on_call_rx_offer` consults on the remote's next re-INVITE.
    func testAcceptsVideoRoundTrips() async throws {
        let engine = PJSUA()
        self.engine = engine
        try await engine.start(PJSUA.Configuration())

        var intent = await engine.mediaIntent(for: CallID(0))
        XCTAssertTrue(intent.acceptsVideo)

        await engine.setAcceptsVideo(CallID(0), false)
        intent = await engine.mediaIntent(for: CallID(0))
        XCTAssertFalse(intent.acceptsVideo)

        await engine.setAcceptsVideo(CallID(0), true)
        intent = await engine.mediaIntent(for: CallID(0))
        XCTAssertTrue(intent.acceptsVideo)
    }

    /// Clearing an entry returns the call to defaults. `on_call_state` runs this on
    /// `.disconnected` precisely because pjsua recycles call ids — a recycled id must
    /// not inherit the previous call's mute/transmission/policy. (A real disconnect needs a
    /// peer; the clear path itself is what is under test here.)
    func testClearedIntentReturnsToDefaults() async throws {
        let engine = PJSUA()
        self.engine = engine
        try await engine.start(PJSUA.Configuration())

        try await engine.setMute(CallID(0), muted: true)
        try await engine.setVideoTransmission(CallID(0), enabled: true)
        await engine.setAcceptsVideo(CallID(0), false)
        clearMediaIntent(for: 0)

        let intent = await engine.mediaIntent(for: CallID(0))
        XCTAssertEqual(intent, CallMediaIntent())
    }
}
