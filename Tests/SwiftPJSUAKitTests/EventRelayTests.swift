import XCTest
import CallKit
import PJSIP
@testable import SwiftPJSUA
@testable import SwiftPJSUAKit

/// The router is the sole consumer of the engine's single-consumer streams, so events it
/// doesn't map to CallKit would be invisible to the app without the `eventObserver` tap.
/// These tests drive the (internal) handlers directly — no engine needed — and pin the
/// tap's exactly-once semantics across the two channels.
final class EventRelayTests: XCTestCase {

    private func makeRouter() -> CallSessionRouter {
        // `CXProvider(configuration:)` is a plain initializer — safe to construct in a
        // tool-hosted test; nothing reports to CallKit because no actions are pending.
        CallSessionRouter(engine: PJSUA(),
                          provider: CXProvider(configuration: CXProviderConfiguration()))
    }

    /// Collects events delivered to the tap. `@unchecked Sendable` only so the `@Sendable`
    /// observer closure may capture it — every access is `@MainActor`-confined.
    @MainActor
    private final class Collector: @unchecked Sendable {
        private(set) var events: [PJSUAEvent] = []
        func observe(_ event: PJSUAEvent) { events.append(event) }
    }

    private func streamDestroyedEvent(call: CallID) -> PJSUAEvent {
        let zero = pjmedia_rtcp_stream_stat()
        let stats = CallStreamStatistics(
            kind: .audio,
            codec: .init(name: "PCMU", clockRate: 8000, channels: 1, payloadType: 0),
            transmit: .init(zero),
            receive: .init(zero),
            roundTrip: .init(usec: pj_math_stat())
        )
        return .streamDestroyed(call: call, mediaIndex: 0, statistics: stats)
    }

    /// `.streamDestroyed` is emitted on the guaranteed channel but has no CallKit mapping —
    /// before the tap existed the router consumed and dropped it.
    func testStreamDestroyedReachesEventObserver() async {
        let router = makeRouter()
        let collector = await Collector()
        await router.setEventObserver { event in collector.observe(event) }

        await router.handle(streamDestroyedEvent(call: CallID(0)))

        let observed = await collector.events
        XCTAssertEqual(observed.count, 1)
        guard case .streamDestroyed = observed[0] else {
            return XCTFail("expected streamDestroyed, got \(observed[0])")
        }
    }

    /// `.callMediaEvent` travels on the bounded telemetry stream only — the tap forwards it
    /// from the telemetry loop.
    func testMediaEventReachesEventObserverViaTelemetry() async {
        let router = makeRouter()
        let collector = await Collector()
        await router.setEventObserver { event in collector.observe(event) }

        await router.handleTelemetry(.callMediaEvent(call: CallID(0), mediaIndex: 0,
                                                     event: .other(fourCC: "TEST")))

        let observed = await collector.events
        XCTAssertEqual(observed.count, 1)
        guard case .callMediaEvent = observed[0] else {
            return XCTFail("expected callMediaEvent, got \(observed[0])")
        }
    }

    /// Terminal `.registrationState` reports are dual-emitted (guaranteed + lossy copy), so
    /// both router loops see the same event — the dedup must collapse them to one observation.
    func testTerminalRegistrationRelayedOnceAcrossBothChannels() async {
        let router = makeRouter()
        let collector = await Collector()
        await router.setEventObserver { event in collector.observe(event) }

        let account = AccountID(0)
        let terminal = PJSUAEvent.registrationState(account: account, active: false,
                                                  statusCode: 403, expiration: 0)
        await router.handle(terminal)          // guaranteed-channel copy
        await router.handleTelemetry(terminal) // lossy copy — must not double-deliver

        let observed = await collector.events
        XCTAssertEqual(observed.count, 1,
                       "the same terminal report on both channels must deliver once")
    }

    /// Periodic renewals repeat an identical tuple every expiry interval; only *changes*
    /// are worth relaying.
    func testIdenticalRenewalsRelayedOnceThenChangesRelayed() async {
        let router = makeRouter()
        let collector = await Collector()
        await router.setEventObserver { event in collector.observe(event) }

        let account = AccountID(0)
        await router.handleTelemetry(.registrationState(account: account, active: true,
                                                        statusCode: 200, expiration: 300))
        await router.handleTelemetry(.registrationState(account: account, active: true,
                                                        statusCode: 200, expiration: 300))
        await router.handleTelemetry(.registrationState(account: account, active: true,
                                                        statusCode: 200, expiration: 60))

        let observed = await collector.events
        XCTAssertEqual(observed.count, 2,
                       "identical renewal is a duplicate; a changed expiration is new state")
    }

    /// Call-scoped copies arrive on the telemetry stream too (emitCall writes both) — the
    /// telemetry loop must not re-forward them or the tap double-delivers.
    func testCallScopedTelemetryCopiesAreNotForwarded() async {
        let router = makeRouter()
        let collector = await Collector()
        await router.setEventObserver { event in collector.observe(event) }

        await router.handleTelemetry(.callState(call: CallID(0), state: .confirmed,
                                                sipCallID: "x@y", lastStatus: 200))

        let observed = await collector.events
        XCTAssertTrue(observed.isEmpty,
                      "call-scoped events are forwarded by the callEvents loop only")
    }
}
