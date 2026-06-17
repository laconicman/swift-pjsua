import CallKit
import Foundation
import SwiftPJSUA

/// The single consumer of ``PJSUA/events`` and the correlation hub between CallKit and the SIP
/// engine (design §2, **D-ROUTER**). One long-lived `Task` iterates the engine event stream and:
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
    private let events: AsyncStream<PJSUAEvent>

    /// Account used for outgoing calls (`CXStartCallAction`). The app sets this (via
    /// ``setOutgoingAccount(_:)``) after it has added an account through ``PJSUA/addAccount(_:)``;
    /// a `CXStartCallAction` arriving while it is `nil` fails (nowhere to place the call from).
    private var outgoingAccount: AccountID?

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

    /// Periodic TTL sweep of orphaned *pending* registry entries — a VoIP push reported a call
    /// whose INVITE never arrived. Withdraws the stale ringing CallKit report (see
    /// ``CallRegistry/sweepExpired(olderThan:)``). Runs for the process lifetime alongside
    /// `consumer`.
    private var sweeper: Task<Void, Never>?

    /// Cadence of the pending-entry sweep. Several of these fit inside `defaultPendingTTL` so an
    /// orphaned push is withdrawn within roughly one TTL of arriving.
    private static let sweepInterval: Duration = .seconds(15)

    public init(engine: PJSUA, provider: CXProvider, registry: CallRegistry = CallRegistry()) {
        self.engine = engine
        self.provider = provider
        self.registry = registry
        self.events = engine.events
    }

    /// Start consuming engine events. Idempotent; safe to call once at app start.
    public func start() {
        guard consumer == nil else { return }
        let stream = events // captured by value (AsyncStream is Sendable); iterated off-actor.
        consumer = Task { [weak self] in
            for await event in stream {
                await self?.handle(event)
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

    // MARK: Incoming report (push or socket)

    /// Report a new incoming call to CallKit, deduplicated via ``CallIdentity`` / ``CallRegistry``.
    /// Whichever path (VoIP push or socket INVITE) arrives first reports; the second only binds its
    /// freshly-learned identifiers onto the same entry (no second ring — §9).
    ///
    /// - Returns: the CallKit `UUID` for this logical call (stable across push and INVITE).
    @discardableResult
    func reportIncomingCall(serverUUID: UUID?,
                            sipCallID: String?,
                            handle: String,
                            hasVideo: Bool,
                            call: CallID? = nil) async -> UUID {
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
        provider.reportNewIncomingCall(with: uuid, update: update) { _ in }
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

    private func handle(_ event: PJSUAEvent) async {
        switch event {
        case let .incomingCall(_, call, sipCallID, from, offeredVideo):
            await reportIncomingCall(serverUUID: nil,
                                     sipCallID: sipCallID,
                                     handle: from ?? "Unknown",
                                     hasVideo: offeredVideo,
                                     call: call)

        case let .callState(call, state, _, lastStatus):
            await handleCallState(call: call, state: state, lastStatus: lastStatus)

        case let .callMediaState(call, media):
            handleMediaState(call: call, media: media)

        case .registrationState:
            // Registration is surfaced for the app's account UI; no CallKit mapping here.
            break
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
    /// are skipped. Throws (wiring nothing further) if a bridge connect fails.
    private func joinGroup(uuid: UUID, call: CallID, groupingWith other: UUID) async throws {
        var targets = groupAdjacency[other] ?? []
        targets.insert(other)
        targets.remove(uuid) // never bridge a call to itself.
        for member in targets {
            guard let memberCall = await registry.entry(for: member)?.call else { continue }
            try await engine.connectAudio(call, and: memberCall)
            groupAdjacency[uuid, default: []].insert(member)
            groupAdjacency[member, default: []].insert(uuid)
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

    /// Map the last SIP status on a disconnected call to a CallKit end reason. 487 (caller CANCEL
    /// before answer) surfaces as a missed/unanswered call; >= 300 failures as failed; otherwise
    /// the remote simply hung up (BYE).
    private static func endedReason(_ lastStatus: Int32) -> CXCallEndedReason {
        switch lastStatus {
        case 487:          return .unanswered          // Request Terminated (caller canceled).
        case 486, 600, 603: return .remoteEnded        // Busy / Decline — peer rejected.
        case 300...:       return .failed              // other 3xx–6xx error.
        default:           return .remoteEnded          // normal BYE / success path.
        }
    }
}
