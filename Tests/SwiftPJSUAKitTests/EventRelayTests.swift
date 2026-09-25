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
        private(set) var registrations: [(active: Bool, code: Int32)] = []
        func observe(_ event: PJSUAEvent) { events.append(event) }
        func observeRegistration(active: Bool, code: Int32) {
            registrations.append((active, code))
        }
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
        await router.drainObservers()

        let observed = await collector.events
        XCTAssertEqual(observed.count, 1)
        guard case .streamDestroyed = observed[0] else {
            return XCTFail("expected streamDestroyed, got \(observed[0])")
        }
    }

    /// Informational `.callMediaEvent(.other)` travels on the bounded telemetry stream only —
    /// the tap forwards it from the telemetry loop.
    func testInformationalMediaEventReachesEventObserverViaTelemetry() async {
        let router = makeRouter()
        let collector = await Collector()
        await router.setEventObserver { event in collector.observe(event) }

        await router.handleTelemetry(.callMediaEvent(call: CallID(0), mediaIndex: 0,
                                                     event: .other(fourCC: "TEST")))
        await router.drainObservers()

        let observed = await collector.events
        XCTAssertEqual(observed.count, 1)
        guard case .callMediaEvent = observed[0] else {
            return XCTFail("expected callMediaEvent, got \(observed[0])")
        }
    }

    /// One-shot media errors are emitted on the guaranteed channel; their lossy telemetry
    /// twin must not re-forward, or the tap double-delivers.
    func testMediaErrorForwardsFromGuaranteedChannelOnly() async {
        let router = makeRouter()
        let collector = await Collector()
        await router.setEventObserver { event in collector.observe(event) }

        let error = PJSUAEvent.callMediaEvent(call: CallID(0), mediaIndex: 0,
                                              event: .mediaTransportError(status: 70014,
                                                                          isRTP: true))
        await router.handle(error)          // guaranteed copy — delivers
        await router.handleTelemetry(error) // lossy twin — ignored
        await router.drainObservers()

        let observed = await collector.events
        XCTAssertEqual(observed.count, 1,
                       "a media transport error must reach the tap exactly once")
    }

    /// Every registration report travels the guaranteed channel — the single ordered,
    /// authoritative path — so the telemetry twin is ignored rather than deduplicated.
    /// Order can't be tested by driving both handlers (that would still look ordered);
    /// what can be pinned is that only one channel ever relays.
    func testTerminalRegistrationRelayedOnceAcrossBothChannels() async {
        let router = makeRouter()
        let collector = await Collector()
        await router.setEventObserver { event in collector.observe(event) }

        let account = AccountID(0)
        let terminal = PJSUAEvent.registrationState(account: account, active: false,
                                                  statusCode: 403, expiration: 0)
        await router.handle(terminal)          // authoritative copy — delivers
        await router.handleTelemetry(terminal) // lossy twin — ignored entirely
        await router.drainObservers()

        let observed = await collector.events
        XCTAssertEqual(observed.count, 1,
                       "the same terminal report on both channels must deliver once")
    }

    /// Telemetry-channel registration reports are lossy twins of guaranteed-channel
    /// emissions — the router never relays them (single ordered authoritative path).
    func testTelemetryRegistrationCopiesAreNeverRelayed() async {
        let router = makeRouter()
        let collector = await Collector()
        await router.setRegistrationObserver { _, active, code, _ in
            collector.observeRegistration(active: active, code: code)
        }
        await router.setEventObserver { event in collector.observe(event) }

        await router.handleTelemetry(.registrationState(account: AccountID(0), active: true,
                                                        statusCode: 200, expiration: 300))
        await router.drainObservers()

        let observed = await collector.events
        let regCount = await collector.registrations.count
        XCTAssertTrue(observed.isEmpty)
        XCTAssertEqual(regCount, 0)
    }

    /// Periodic renewals repeat an identical tuple every expiry interval; only *changes*
    /// are worth relaying.
    func testIdenticalRenewalsRelayedOnceThenChangesRelayed() async {
        let router = makeRouter()
        let collector = await Collector()
        await router.setEventObserver { event in collector.observe(event) }

        let account = AccountID(0)
        await router.handle(.registrationState(account: account, active: true,
                                               statusCode: 200, expiration: 300))
        await router.handle(.registrationState(account: account, active: true,
                                               statusCode: 200, expiration: 300))
        await router.handle(.registrationState(account: account, active: true,
                                               statusCode: 200, expiration: 60))
        await router.drainObservers()

        let observed = await collector.events
        XCTAssertEqual(observed.count, 2,
                       "identical renewal is a duplicate; a changed expiration is new state")
    }

    /// PJSUA recycles account IDs on re-add. A terminal report ends the epoch and clears
    /// the dedup snapshot, so a reused ID's first report — even an identical tuple — still
    /// reaches the observers.
    func testReusedAccountIDAfterTerminalStillRelays() async {
        let router = makeRouter()
        let collector = await Collector()
        await router.setRegistrationObserver { _, active, code, _ in
            collector.observeRegistration(active: active, code: code)
        }

        let account = AccountID(0)
        // First account lifecycle ends on a terminal report...
        await router.handle(.registrationState(account: account, active: false,
                                               statusCode: 403, expiration: 0))
        // ...the ID is recycled, and the new account's first report is identical.
        await router.handle(.registrationState(account: account, active: false,
                                               statusCode: 403, expiration: 0))
        await router.drainObservers()

        let relayed = await collector.registrations
        XCTAssertEqual(relayed.count, 2,
                       "a terminal ends the epoch — an identical later report is new state")
    }

    /// Call-scoped copies arrive on the telemetry stream too (emitCall writes both) — the
    /// telemetry loop must not re-forward them or the tap double-delivers.
    func testCallScopedTelemetryCopiesAreNotForwarded() async {
        let router = makeRouter()
        let collector = await Collector()
        await router.setEventObserver { event in collector.observe(event) }

        await router.handleTelemetry(.callState(call: CallID(0), state: .confirmed,
                                                sipCallID: "x@y", lastStatus: 200))
        await router.drainObservers()

        let observed = await collector.events
        XCTAssertTrue(observed.isEmpty,
                      "call-scoped events are forwarded by the callEvents loop only")
    }

    /// `CXCallObserver` is system-wide, so apps filter through `isKnownCall`: true only for
    /// UUIDs the registry has seen (ours), false for anything else (another app's call).
    func testIsKnownCallDistinguishesRegistryEntries() async {
        let router = makeRouter()
        let ours = UUID()
        let foreign = UUID()

        await router.seedRegistryEntry(ours)

        let oursKnown = await router.isKnownCall(ours)
        let foreignKnown = await router.isKnownCall(foreign)
        XCTAssertTrue(oursKnown)
        XCTAssertFalse(foreignKnown)
    }
}

extension EventRelayTests {

    /// `.callReplaced` migrates the replaced leg's CallKit identity onto the new call —
    /// the INVITE-with-Replaces never passes `.incomingCall`, so without the migration the
    /// replacement leg has no UUID and the old leg's disconnect would end the visible call.
    func testCallReplacedMigratesCallKitIdentity() async {
        let router = makeRouter()
        let collector = await Collector()
        await router.setEventObserver { event in collector.observe(event) }
        let uuid = UUID()
        let oldCall = CallID(3), newCall = CallID(4)
        await router.setUUID(uuid, for: oldCall)

        await router.handle(.callReplaced(call: oldCall, newCall: newCall))
        await router.drainObservers()

        let newUUID = await router.uuid(for: newCall)
        let oldUUID = await router.uuid(for: oldCall)
        XCTAssertEqual(newUUID, uuid, "new call inherits the replaced leg's UUID")
        XCTAssertNil(oldUUID, "old leg unbound — its disconnect is a no-op")

        // And the disconnect that follows leaves the identity alone.
        await router.handle(.callState(call: oldCall, state: .disconnected,
                                       sipCallID: nil, lastStatus: 200))
        let stillBound = await router.uuid(for: newCall)
        XCTAssertEqual(stillBound, uuid,
                       "old leg's disconnect must not end the migrated call")

        let observed = await collector.events
        XCTAssertTrue(observed.contains { if case .callReplaced = $0 { true } else { false } },
                      "the tap still sees the event")
    }

    /// `.callTransferStatus` reaches the tap; on an unstarted engine the final-2xx hangup
    /// is gated by `isRunning`, so driving it here is safe and verifies the no-op path.
    func testCallTransferStatusReachesObserverWithoutEngine() async {
        let router = makeRouter()
        let collector = await Collector()
        await router.setEventObserver { event in collector.observe(event) }

        await router.handle(.callTransferStatus(call: CallID(0), statusCode: 200,
                                                statusText: "OK", isFinal: true))
        await router.drainObservers()

        let observed = await collector.events
        guard case .callTransferStatus(_, let code, _, let isFinal) = observed.first else {
            return XCTFail("expected callTransferStatus, got \(String(describing: observed.first))")
        }
        XCTAssertEqual(code, 200)
        XCTAssertTrue(isFinal)
    }
}
