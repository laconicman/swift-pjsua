import CallKit
import Foundation
import os
import PJSIP
import SwiftPJSUA

/// The single consumer of ``PJSUA/callEvents`` and ``PJSUA/events``, and the correlation hub
/// between CallKit and the SIP engine (design §2, **D-ROUTER**). Long-lived `Task`s iterate
/// the guaranteed lifecycle channel and the bounded telemetry stream respectively, and:
///
/// - maps each engine event onto a CallKit provider report (incoming/outgoing/ended — §3);
/// - owns the **pending-action table**, stashing `CXAction`s whose SIP outcome is asynchronous
///   (answer/start fulfilled on `.confirmed`, hold/unhold on the media-state change — §10);
/// - owns the ``CallRegistry`` (UUID ↔ SIP `Call-ID` ↔ engine ``CallID``) and is its only writer
///   after the initial incoming report, so push and socket INVITE never double-ring (§9).
///
/// `AsyncStream` is single-consumer, so centralising here (rather than many `for await` sites)
/// also gives one place to enforce ordering and correlate actions ↔ events. ``CallKitController``
/// is a thin `CXProviderDelegate` that forwards actions in; ``VoIPPushHandler`` forwards pushes in.
///
/// - SeeAlso: Responding to VoIP Notifications from PushKit, Making and receiving VoIP calls
///   (https://developer.apple.com/documentation/callkit).
public actor CallSessionRouter {
    private let engine: PJSUA
    private let provider: CXProvider
    private let registry: CallRegistry
    private let callEvents: AsyncStream<PJSUAEvent>
    private let events: AsyncStream<PJSUAEvent>

    /// Account used for outgoing calls (`CXStartCallAction`). The app sets this (via
    /// ``setOutgoingAccount(_:)``) after it has added an account through ``PJSUA/addAccount(_:)``;
    /// a `CXStartCallAction` arriving while it is `nil` fails (nowhere to place the call from).
    private var outgoingAccount: AccountID?

    /// App-facing relay of `.registrationState` transitions. The router consumes the engine streams
    /// **exclusively** (they are single-consumer), and registration has no CallKit mapping (§3) —
    /// so the app's account UI observes it here instead of reading `engine.events` itself.
    ///
    /// `@MainActor` by type, so the closure body runs on the main actor: the app updates UI
    /// directly, with no risk of an off-main mutation and no manual hop to remember. The router
    /// `await`s the main-actor hop when it fires (see `handle`).
    public typealias RegistrationObserver = @MainActor @Sendable (AccountID, _ active: Bool,
                                                                  _ statusCode: Int32,
                                                                  _ expiration: UInt32) -> Void
    private var registrationObserver: RegistrationObserver?

    /// App-facing relay of **every** event the router processes — the multicast tap that makes
    /// the single-consumer streams observable (diagnostics views, media-error policy, the
    /// FieldKit harness). Without it, events the router handles but doesn't map to CallKit
    /// (`.streamDestroyed`, `.callMediaEvent`, `.registrationState`) are invisible to
    /// the app: an `AsyncStream` cannot broadcast a consumed event to a second subscriber.
    ///
    /// Delivery semantics mirror the engine's channels exactly: call-scoped events
    /// (`.incomingCall`, `.callState`, `.callMediaState`, `.streamDestroyed`), **every**
    /// `.registrationState` transitions, and one-shot media errors (`.mediaTransportError`,
    /// `.audioDeviceError`) arrive on the guaranteed channel — unbounded, ordered, never
    /// dropped; periodic `.callMediaEvent(.other)` arrives on the bounded telemetry channel
    /// and may drop under burst. Each event is delivered **once**: lossy `events` copies of
    /// guaranteed-channel events are consumed but not re-forwarded, and identical
    /// `.registrationState` renewals collapse to one observation per transition
    /// (``relayRegistration``).
    ///
    /// `@MainActor` by type, like ``RegistrationObserver`` — update UI directly.
    public typealias EventObserver = @MainActor @Sendable (PJSUAEvent) -> Void
    private var eventObserver: EventObserver?

    /// Last registration tuple relayed to the observers, per account. Renewals repeat an
    /// identical tuple every expiry interval — relay only on change. Cleared when an
    /// inactive report relays (the epoch ended), so a recycled `AccountID` cannot inherit
    /// the previous account's deduplication state.
    private struct RegistrationSnapshot: Equatable {
        let active: Bool
        let statusCode: Int32
        let expiration: UInt32
    }
    private var lastRegistrationRelay: [AccountID: RegistrationSnapshot] = [:]

    /// Serial delivery chain for observer callbacks. Both observer types are `@MainActor`,
    /// and `handle` must never block CallKit work on app code (a slow observer awaiting a
    /// main-actor hop could delay an incoming-call report). Each delivery chains behind the
    /// previous one, so observers still see the router's order — they just can't stall it.
    /// The observer is captured at enqueue time: a later `set…Observer` doesn't redirect
    /// already-queued deliveries.
    private var observerTail: Task<Void, Never>?
    /// Queued-but-undelivered observer callbacks — bounds the task chain: a wedged
    /// `@MainActor` observer otherwise turns periodic telemetry into unbounded task growth.
    private var pendingObserverDeliveries = 0
    /// Backlog depth at which droppable deliveries are skipped. Sized with the telemetry
    /// stream in mind — deeper than this means the observer is wedged, not busy.
    /// Guaranteed-channel events deliberately bypass the cap: they are activity-bounded
    /// (O(calls × states), not per-frame), and dropping them would silently corrupt the
    /// tap's every-transition contract — a permanently wedged observer is an app bug the
    /// tap cannot heal either way.
    private static let maxPendingObserverDeliveries = 32

    /// Enqueue a `@MainActor` observer delivery without awaiting it. `droppingIfBusy`
    /// marks the delivery as best-effort telemetry: when the backlog is deep, periodic
    /// events are skipped rather than piled onto the chain — the same loss trade the
    /// bounded `events` stream already makes for them.
    private func deliverToObserver(droppingIfBusy: Bool = false,
                                   _ delivery: @escaping @MainActor @Sendable () -> Void) {
        if droppingIfBusy && pendingObserverDeliveries >= Self.maxPendingObserverDeliveries {
            return
        }
        pendingObserverDeliveries += 1
        let previous = observerTail
        observerTail = Task {
            await previous?.value
            await delivery()
            pendingObserverDeliveries -= 1
        }
    }

    /// Suspend until every queued observer delivery has run. Internal for `@testable` —
    /// production callers must not await observer work (that would re-couple the paths
    /// ``deliverToObserver`` decouples).
    func drainObservers() async {
        await observerTail?.value
    }

    /// Connection-establishing / hold actions awaiting the engine event that resolves them.
    /// Keyed by CallKit `UUID`; at most one outstanding per call in this skeleton (answer→hold are
    /// temporally exclusive). See ``PendingCallAction``.
    private var pending: [UUID: PendingCallAction] = [:]

    /// Reverse index so `.callState` / `.callMediaState` events (which carry the engine
    /// ``CallID``) can be mapped back to the CallKit `UUID`. Kept in lockstep with the registry.
    private var uuidByCall: [CallID: UUID] = [:]

    /// Calls we hung up locally (via `CXEndCallAction`): the engine still emits a terminal
    /// `.callState(.disconnected)` we must NOT re-report to CallKit (it would be a duplicate).
    private var locallyEnded: Set<UUID> = []

    /// Local-conference membership (design §7.1): for each grouped call, the set of *other*
    /// calls its audio is bridged to. Symmetric (if A↔B then B∈adjacency[A] and A∈adjacency[B]).
    /// Drives N-way local mixing — a new member is cross-connected to every existing member of
    /// the group it joins (`CXSetGroupCallAction`). Empty for un-grouped calls.
    private var groupAdjacency: [UUID: Set<UUID>] = [:]

    private var consumer: Task<Void, Never>?
    private var telemetryConsumer: Task<Void, Never>?

    /// Periodic TTL sweep of orphaned *pending* registry entries — a VoIP push reported a call
    /// whose INVITE never arrived. Withdraws the stale ringing CallKit report (see
    /// ``CallRegistry/sweepExpired(olderThan:)``). Runs for the process lifetime alongside
    /// `consumer`.
    private var sweeper: Task<Void, Never>?

    /// Cadence of the pending-entry sweep. Several of these fit inside `defaultPendingTTL` so an
    /// orphaned push is withdrawn within roughly one TTL of arriving.
    private static let sweepInterval: Duration = .seconds(15)

    private static let logger = Logger(subsystem: "SwiftPJSUAKit", category: "CallSessionRouter")

    public init(engine: PJSUA, provider: CXProvider, registry: CallRegistry = CallRegistry()) {
        self.engine = engine
        self.provider = provider
        self.registry = registry
        self.callEvents = engine.callEvents
        self.events = engine.events
    }

    /// Start consuming engine events. Idempotent; safe to call once at app start.
    public func start() {
        guard consumer == nil else { return }
        // Captured by value (AsyncStream is Sendable); iterated off-actor.
        let callEvents = callEvents
        let events = events
        // Lifecycle arrives on the guaranteed channel, where ordering is preserved — an
        // `.incomingCall` is always handled before that call's `.callState`s.
        consumer = Task { [weak self] in
            for await event in callEvents {
                await self?.handle(event)
            }
        }
        telemetryConsumer = Task { [weak self] in
            for await event in events {
                await self?.handleTelemetry(event)
            }
        }
        sweeper = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: CallSessionRouter.sweepInterval)
                await self?.sweepExpiredPending()
            }
        }
    }

    /// Set the account outgoing `CXStartCallAction`s originate from. Call once after adding an
    /// account; `nil` disables outgoing calls.
    public func setOutgoingAccount(_ account: AccountID?) {
        outgoingAccount = account
    }

    /// Set (or clear) the app's registration observer. The closure is `@MainActor`, so it runs
    /// on the main actor — update UI directly; no manual thread hop needed.
    public func setRegistrationObserver(_ observer: RegistrationObserver?) {
        registrationObserver = observer
    }

    /// Set (or clear) the app's event observer — the multicast tap for events the router
    /// processes. See ``EventObserver`` for the delivery semantics.
    public func setEventObserver(_ observer: EventObserver?) {
        eventObserver = observer
    }

    // MARK: Incoming report (push or socket)

    /// Report a new incoming call to CallKit, deduplicated via ``CallIdentity`` / ``CallRegistry``.
    /// Whichever path (VoIP push or socket INVITE) arrives first reports; the second only binds its
    /// freshly-learned identifiers onto the same entry (no second ring — §9).
    ///
    /// - Returns: the CallKit `UUID` for this logical call (stable across push and INVITE).
    /// - Throws: the error from `CXProvider.reportNewIncomingCall(with:update:)` if the system
    ///   refused to surface the call (blocked caller, Do Not Disturb, etc.). On refusal the
    ///   registry entry and reverse index are evicted so caller and engine state stay consistent.
    @discardableResult
    func reportIncomingCall(serverUUID: UUID?,
                            sipCallID: String?,
                            handle: String,
                            hasVideo: Bool,
                            call: CallID? = nil) async throws -> UUID {
        let uuid = CallIdentity.uuid(serverProvided: serverUUID, sipCallID: sipCallID)
        if let call { uuidByCall[call] = uuid }

        let isNew = await registry.firstSeen(uuid: uuid, sipCallID: sipCallID, call: call)
        guard isNew else { return uuid }

        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: handle)
        update.hasVideo = hasVideo
        update.supportsHolding = true
        update.supportsDTMF = true
        // Advertise local conferencing so CallKit offers merge/split, mapped to the conference
        // bridge in setGroup(_:) (§7.1 / §10).
        update.supportsGrouping = true
        update.supportsUngrouping = true
        do {
            try await provider.reportNewIncomingCall(with: uuid, update: update)
        } catch {
            Self.logger.error("reportNewIncomingCall refused for \(uuid, privacy: .public): \(error, privacy: .public)")
            await evict(uuid: uuid)
            throw error
        }
        return uuid
    }

    // MARK: CXProviderDelegate forwarding (called by CallKitController)

    func startCall(_ action: CXStartCallAction) async {
        guard let account = outgoingAccount else {
            // Nowhere to originate from; the app must set `outgoingAccount` first.
            action.fail()
            return
        }
        do {
            let call = try await engine.makeCall(to: action.handle.value, from: account, video: action.isVideo)
            await bind(call: call, to: action.callUUID)
            pending[action.callUUID] = .connect(action)
            // Outbound dialing has begun; connecting/connected are reported on .early/.confirmed.
        } catch {
            action.fail()
        }
    }

    func answerCall(_ action: CXAnswerCallAction) async {
        guard let call = await registry.entry(for: action.callUUID)?.call else {
            action.fail()
            return
        }
        do {
            try await engine.answer(call)
            // Apple: do NOT fulfill yet — wait for the connection (.confirmed).
            pending[action.callUUID] = .connect(action)
        } catch {
            action.fail()
        }
    }

    func endCall(_ action: CXEndCallAction) async {
        locallyEnded.insert(action.callUUID)
        if let call = await registry.entry(for: action.callUUID)?.call {
            try? await engine.hangup(call)
        }
        await evict(uuid: action.callUUID)
        action.fulfill()
    }

    func setHeld(_ action: CXSetHeldCallAction) async {
        guard let call = await registry.entry(for: action.callUUID)?.call else {
            action.fail()
            return
        }
        do {
            if action.isOnHold {
                try await engine.setHold(call)
            } else {
                try await engine.resume(call)
            }
            // Fulfilled when .callMediaState reflects the new direction (§10).
            pending[action.callUUID] = .setHeld(action, onHold: action.isOnHold)
        } catch {
            action.fail()
        }
    }

    func setMuted(_ action: CXSetMutedCallAction) async {
        guard let call = await registry.entry(for: action.callUUID)?.call else {
            action.fail()
            return
        }
        do {
            try await engine.setMute(call, muted: action.isMuted)
            action.fulfill() // local conference re-wire; no signalling, so resolve immediately.
        } catch {
            action.fail()
        }
    }

    func playDTMF(_ action: CXPlayDTMFCallAction) async {
        guard let call = await registry.entry(for: action.callUUID)?.call else {
            action.fail()
            return
        }
        do {
            try await engine.sendDTMF(call, digits: action.digits)
            action.fulfill()
        } catch {
            action.fail()
        }
    }

    /// Group (merge) or ungroup (split) a call in a local conference, mapped to the engine's
    /// audio conference bridge (§7.1, **D-CONF**). When `callUUIDToGroupWith` is set, the call
    /// joins that call's group and is bidirectionally bridged to every existing member; when it
    /// is `nil`, the call leaves its group and is unbridged from each remaining member. Each leg
    /// independently keeps its sound-device bridge (wired in the engine media callback), so
    /// ungrouping a call leaves it a working 1:1 call. Fulfilled once the bridge is wired.
    func setGroup(_ action: CXSetGroupCallAction) async {
        guard let call = await registry.entry(for: action.callUUID)?.call else {
            action.fail()
            return
        }
        do {
            if let other = action.callUUIDToGroupWith {
                try await joinGroup(uuid: action.callUUID, call: call, groupingWith: other)
            } else {
                await leaveGroup(uuid: action.callUUID, call: call)
            }
            action.fulfill()
        } catch {
            action.fail()
        }
    }

    /// CallKit dropped all calls (e.g. crash recovery). Tear down engine calls and clear state.
    func reset() async {
        await engine.hangupAll()
        for action in pending.values { action.action.fail() }
        pending.removeAll()
        uuidByCall.removeAll()
        locallyEnded.removeAll()
        groupAdjacency.removeAll()
    }

    // MARK: Engine event → CallKit

    /// Internal (not `private`) so tests can drive the handlers directly via `@testable` —
    /// the streams themselves can't be injected without a running engine.
    func handle(_ event: PJSUAEvent) async {
        // Observe before acting: the tap sees the event regardless of what CallKit does
        // with it. `.registrationState` is excluded here — it reaches the tap through the
        // transition-deduplicated ``relayRegistration`` path instead.
        if case .registrationState = event { } else {
            deliverToObserver { [eventObserver] in eventObserver?(event) }
        }
        switch event {
        case let .incomingCall(_, call, sipCallID, from, offeredVideo):
            do {
                try await reportIncomingCall(serverUUID: nil,
                                             sipCallID: sipCallID,
                                             handle: from ?? "Unknown",
                                             hasVideo: offeredVideo,
                                             call: call)
            } catch {
                // CallKit refused to ring (blocked / DND); reject the SIP leg with
                // PJSIP_SC_TEMPORARILY_UNAVAILABLE (480) so the peer hears a clean reject instead
                // of ringing into the void. 480 is preferred over PJSIP_SC_DECLINE (603): DND is
                // transient, and we cannot distinguish DND from a blocked caller at this layer
                // (see CXErrorCodeIncomingCallError.Code).
                try? await engine.hangup(call, statusCode: PJSIP_SC_TEMPORARILY_UNAVAILABLE.rawValue)
            }

        case let .callState(call, state, _, lastStatus):
            await handleCallState(call: call, state: state, lastStatus: lastStatus)

        case let .callMediaState(call, media):
            handleMediaState(call: call, media: media)

        case let .registrationState(account, active, statusCode, expiration):
            // No CallKit mapping (§3) — deduplicated relay to the app's observers.
            await relayRegistration(account: account, active: active,
                                    statusCode: statusCode, expiration: expiration)

        case .streamDestroyed, .callMediaEvent:
            // No CallKit mapping either, and deliberately not invented: neither event ends a
            // call, and CallKit has no vocabulary for "still connected, but the media is dead".
            // Already forwarded to the eventObserver above — end-of-stream statistics and
            // media-failure policy are the app's (offhook OH-10).
            break
        }
    }

    /// The bounded `events` stream is either lossy twins or heartbeat: every case that
    /// lands on `callEvents` (call-scoped events, registration *transitions*, one-shot
    /// media errors) has its authoritative delivery there, and identical renewal
    /// heartbeats are telemetry-exclusive but deliberately unrelayed — observers track
    /// transitions, not pulse. The one payload forwarded from here is
    /// `.callMediaEvent(.other)` — periodic, informational, and droppable under backlog.
    /// Internal (not `private`) for the same @testable reason as ``handle(_:)``.
    func handleTelemetry(_ event: PJSUAEvent) async {
        if case .callMediaEvent(_, _, .other) = event {
            deliverToObserver(droppingIfBusy: true) { [eventObserver] in
                eventObserver?(event)
            }
        }
    }

    /// Relay one registration report to ``registrationObserver`` and ``eventObserver``,
    /// but only when it carries a *changed* tuple — renewals repeat an identical report
    /// every expiry interval and only transitions are worth observing. An inactive report
    /// additionally **clears** the snapshot: it ends the registration epoch, so a reused
    /// `AccountID` cannot inherit the previous account's deduplication state.
    private func relayRegistration(account: AccountID, active: Bool,
                                   statusCode: Int32, expiration: UInt32) async {
        let snapshot = RegistrationSnapshot(active: active, statusCode: statusCode,
                                            expiration: expiration)
        guard lastRegistrationRelay[account] != snapshot else { return }
        lastRegistrationRelay[account] = active ? snapshot : nil
        deliverToObserver { [registrationObserver, eventObserver] in
            registrationObserver?(account, active, statusCode, expiration)
            eventObserver?(.registrationState(account: account, active: active,
                                              statusCode: statusCode, expiration: expiration))
        }
    }

    private func handleCallState(call: CallID, state: CallState, lastStatus: Int32) async {
        guard let uuid = uuidByCall[call] else { return }
        switch state {
        case .early:
            // Outgoing only: remote is ringing. (Incoming early needs no CallKit report.)
            if case .connect(let action) = pending[uuid], action is CXStartCallAction {
                provider.reportOutgoingCall(with: uuid, startedConnectingAt: nil)
            }

        case .confirmed:
            // Connection established: fulfill a stashed answer/start (Apple-mandated timing).
            if case .connect(let action) = pending[uuid] {
                if action is CXStartCallAction {
                    provider.reportOutgoingCall(with: uuid, connectedAt: nil)
                }
                action.fulfill()
                pending[uuid] = nil
            }

        case .disconnected:
            if let action = pending[uuid] {
                action.action.fail() // connection failed before it could be fulfilled.
                pending[uuid] = nil
            }
            if !locallyEnded.contains(uuid) {
                provider.reportCall(with: uuid, endedAt: nil, reason: Self.endedReason(lastStatus))
            }
            await evict(uuid: uuid)

        case .null, .calling, .incoming, .connecting, .unknown:
            break
        }
    }

    private func handleMediaState(call: CallID, media: [CallMediaInfo]) {
        guard let uuid = uuidByCall[call] else { return }
        guard case .setHeld(let action, let onHold) = pending[uuid] else { return }
        let reflected = media.contains { stream in
            guard stream.kind == .audio else { return false }
            return onHold ? (stream.status == .localHold || stream.status == .none)
                          : (stream.status == .active)
        }
        if reflected {
            action.fulfill()
            pending[uuid] = nil
        }
    }

    // MARK: Local conference membership

    /// Cross-connect `uuid` to every existing member of the group containing `other` (and to
    /// `other` itself), then record the symmetric adjacency. Members whose engine call is gone
    /// are skipped. If a bridge connect fails partway, every connection already made is rolled
    /// back (so a failed `CXSetGroupCallAction` leaves no dangling bridges) before rethrowing.
    private func joinGroup(uuid: UUID, call: CallID, groupingWith other: UUID) async throws {
        var targets = groupAdjacency[other] ?? []
        targets.insert(other)
        targets.remove(uuid) // never bridge a call to itself.
        var connected: [(uuid: UUID, call: CallID)] = []
        do {
            for member in targets {
                guard let memberCall = await registry.entry(for: member)?.call else { continue }
                try await engine.connectAudio(call, and: memberCall)
                connected.append((member, memberCall))
                groupAdjacency[uuid, default: []].insert(member)
                groupAdjacency[member, default: []].insert(uuid)
            }
        } catch {
            // Unwind the partial bridge so the audio state matches the failed CallKit action.
            for wired in connected {
                try? await engine.disconnectAudio(call, and: wired.call)
                groupAdjacency[uuid]?.remove(wired.uuid)
                groupAdjacency[wired.uuid]?.remove(uuid)
                if groupAdjacency[wired.uuid]?.isEmpty == true { groupAdjacency[wired.uuid] = nil }
            }
            if groupAdjacency[uuid]?.isEmpty == true { groupAdjacency[uuid] = nil }
            throw error
        }
    }

    /// Unbridge `uuid` from each call it is grouped with and drop it from the adjacency map.
    private func leaveGroup(uuid: UUID, call: CallID) async {
        guard let members = groupAdjacency[uuid] else { return }
        for member in members {
            if let memberCall = await registry.entry(for: member)?.call {
                try? await engine.disconnectAudio(call, and: memberCall)
            }
            groupAdjacency[member]?.remove(uuid)
            if groupAdjacency[member]?.isEmpty == true { groupAdjacency[member] = nil }
        }
        groupAdjacency[uuid] = nil
    }

    // MARK: Helpers

    /// Bind an engine ``CallID`` to a CallKit `UUID` in both the reverse index and the registry.
    /// `firstSeen` creates the registry entry when missing (outgoing calls, which are never
    /// "reported" as incoming) and merges the `CallID` onto an existing entry otherwise.
    private func bind(call: CallID, to uuid: UUID) async {
        uuidByCall[call] = uuid
        await registry.firstSeen(uuid: uuid, call: call)
    }

    /// Reap pending registry entries whose INVITE never arrived and withdraw their still-ringing
    /// CallKit reports. Bound (live) calls are untouched — they end via `.disconnected` /
    /// `CXEndCallAction`.
    private func sweepExpiredPending() async {
        let expired = await registry.sweepExpired()
        for uuid in expired {
            // The reported push never produced an INVITE; dismiss the system call UI.
            provider.reportCall(with: uuid, endedAt: nil, reason: .unanswered)
            pending[uuid] = nil
            locallyEnded.remove(uuid)
        }
    }

    private func evict(uuid: UUID) async {
        if let call = await registry.entry(for: uuid)?.call { uuidByCall[call] = nil }
        await registry.remove(uuid: uuid)
        pending[uuid] = nil
        locallyEnded.remove(uuid)
        // Drop the call from any local conference. The engine tears the leg's conference slot
        // down on hangup, so its bridge links vanish automatically; only the bookkeeping needs
        // clearing here (no engine disconnect on a dead leg).
        for member in groupAdjacency[uuid] ?? [] {
            groupAdjacency[member]?.remove(uuid)
            if groupAdjacency[member]?.isEmpty == true { groupAdjacency[member] = nil }
        }
        groupAdjacency[uuid] = nil
    }

    /// Map the last SIP status on a disconnected call to a CallKit end reason.
    /// `PJSIP_SC_REQUEST_TERMINATED` (487, caller CANCEL before answer) surfaces as a
    /// missed/unanswered call; >= 300 failures as failed; otherwise the remote simply hung up (BYE).
    private static func endedReason(_ lastStatus: Int32) -> CXCallEndedReason {
        switch UInt32(bitPattern: lastStatus) {
        case PJSIP_SC_REQUEST_TERMINATED.rawValue:                                     // 487
            .unanswered
        case PJSIP_SC_BUSY_HERE.rawValue,                                              // 486
             PJSIP_SC_BUSY_EVERYWHERE.rawValue,                                        // 600
             PJSIP_SC_DECLINE.rawValue:                                                // 603
            .remoteEnded
        case 300...:
            .failed
        default:
            .remoteEnded
        }
    }
}
