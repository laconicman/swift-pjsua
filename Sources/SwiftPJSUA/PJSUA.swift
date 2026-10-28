import Foundation
import PJSIP

/// A Swift-only, async front end to PJSIP's pjsua1 C API.
///
/// **Isolation is the bridge.** This actor's executor is a single dedicated,
/// PJLIB-registered POSIX thread (``PJSIPExecutor``). Because the actor runs *there*,
/// each method can call the blocking PJSIP C function directly and return its result —
/// `await phone.makeCall(...)` performs the hop, runs the call on the right thread, and
/// hands back the value. No `withCheckedContinuation`, no GCD, no C++ shim.
///
/// **Events** arrive on PJSUA's own worker threads and are delivered as a `Sendable`
/// ``PJSUAEvent`` stream via ``events``. The callback bridge lives in
/// `PJSUACallbacks.swift` and never touches this actor (see the re-entrancy note there).
///
/// **Singleton.** pjsua is a process-global library; create exactly one `PJSUA`.
public actor PJSUA {

    // Binds the actor to the dedicated PJSIP thread. This single line is what makes
    // "modern concurrency + PJSIP" correct.
    private let executor: PJSIPExecutor
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    /// The complete event record from PJSUA, as a cancellable async sequence. Bounded
    /// newest-first (64): under burst or with no consumer, newest telemetry wins — a
    /// deliberate contract, since everything exclusive to this channel is periodic or
    /// informational. For the events whose loss is unrecoverable, see
    /// ``callEvents`` (TD-3).
    public nonisolated let events: AsyncStream<PJSUAEvent>

    /// Guaranteed-delivery channel for the unrecoverable subset — `.incomingCall`,
    /// `.callState`, `.callMediaState`, `.streamDestroyed`, every `.registrationState`
    /// *transition* (the single ordered, authoritative path for account state — identical
    /// renewal heartbeats stay on ``events`` only), and one-shot media errors — each also
    /// delivered to ``events``. Unbounded by design: only real state changes land here,
    /// so an idle engine produces nothing.
    public nonisolated let callEvents: AsyncStream<PJSUAEvent>

    /// The engine's own registration channel: what the callbacks report about registrations,
    /// read by a task on this actor from ``start(_:)`` on. See `PJSUA+RegistrationLifecycle.swift`.
    nonisolated let registrationSignals: AsyncStream<RegistrationSignal>

    /// The engine's own video-transmission channel: `on_call_media_state` yields a call here
    /// when a rebuilt video stream needs ``CallMediaIntent/transmitsVideo`` re-applied —
    /// applying it means `pjsua_call_set_vid_strm` (opens an `AVCaptureSession`), far too
    /// slow for the callback's dialog-lock context. Read by a task on this actor from
    /// ``start(_:)`` on, like ``registrationSignals``.
    nonisolated let videoTransmissionSignals: AsyncStream<CallID>

    /// Registration bookkeeping, kept from this actor's own calls and from `registrationSignals`.
    var registration = RegistrationLifecycle()

    enum State { case idle, running, stopped }
    private(set) var state: State = .idle

    /// Whether ``start(_:)`` has completed and ``shutdown()`` hasn't run — the only state in
    /// which call/account APIs are valid. Cross-module consumers (SwiftPJSUAKit's router)
    /// gate engine calls on it rather than trusting event ordering at shutdown boundaries.
    public var isRunning: Bool { state == .running }

    /// Parameters of accounts added via ``addAccount(_:credentials:wait:)``, kept so a silent-push
    /// re-REGISTER can re-apply the fields we own on top of pjsua's live config. See
    /// `PJSUA+Accounts.swift`.
    var accountParameters: [AccountID: AccountParameters] = [:]

    /// Monotonic stamp handed to each added account. pjsua recycles freed account ids, so this
    /// is what lets a suspended operation tell "my account" from "a different account that was
    /// given my id while I was awaiting".
    var accountGeneration: UInt64 = 0

    /// Transport ids handed back by `pjsua_transport_create`, keyed by
    /// ``TransportConfiguration/name`` so an account can pin one without persisting a runtime id.
    var transportIDs: [String: pjsua_transport_id] = [:]

    /// Engine configuration. Note `thread_cnt` is intentionally *not* exposed: the design
    /// requires pjsua's worker threads to pump events, so it is pinned inside ``start(_:)``.
    public struct Configuration: Sendable, Codable, Equatable {
        /// Transports to create at ``start(_:)``, in order. Replaces the former single
        /// `port`/`transport` pair, which could not express a per-transport port (TD-18).
        ///
        /// The default makes explicit what `start()` used to do implicitly: a UDP primary plus a
        /// TCP listener, because pjsip's RFC 3261 §18.1.1 size switch can only upgrade an
        /// oversized request to TCP if a TCP transport exists (see `Upstream/` and
        /// pjsip/pjproject#5075).
        public var transports: [TransportConfiguration] = [.init("udp", .udp), .init("tcp", .tcp)]
        public var logLevel: UInt32 = 4
        /// Verbosity ceiling for ``logSink``, independent of ``logLevel`` (which gates
        /// console output). pjsip's own default is 5. Upstream's `level`/`console_level`
        /// cannot express two independent ceilings — `cb` only sees console-eligible lines —
        /// so `start` raises both upstream gates to the max and the per-path ceilings are
        /// enforced inside the callback.
        public var logSinkLevel: UInt32 = 5
        /// Whether pjsip logs whole SIP messages (`logging_config.msg_logging`, on by default
        /// upstream). This is what makes a "live SIP log" possible — leave on for a debug
        /// client, turn off if the traffic itself must not reach the sink.
        public var messageLogging: Bool = true
        /// When set, receives each pjsip log line up to ``logSinkLevel`` — called from
        /// arbitrary pjsip worker threads, so it must be fast and must not block. The console
        /// still logs at ``logLevel`` regardless; this is a tap, not a redirect.
        /// Runtime-only: excluded from `Codable` and `==` — closures are neither.
        public var logSink: (@Sendable (_ level: Int32, _ text: String) -> Void)?
        public var userAgent: String = "swift-pjsua"
        /// Global media defaults (`pjsua_media_config`) — see ``MediaConfiguration``.
        public var media = MediaConfiguration()
        /// Audio codec id prefix → priority, e.g. `["opus": 255, "PCMU": 200, "iLBC": 0]`.
        ///
        /// `pjsua_codec_set_priority` matches each key as a **case-insensitive prefix** of the
        /// codec ids ``audioCodecs()`` reports (`opus/48000/2`, `PCMU/8000/1`, …) — `"opus"`,
        /// `"PCMU"` and `"ilbc"` all match, and `"*"` matches every codec. Every match gets the
        /// priority: 0 disables (listed, never offered), higher offers earlier. pjsua stores a
        /// requested 255 as 254 once sorted and only the most recently assigned 255 wins, so the
        /// keys are applied in **ascending** order — with two keys at 255 the lexicographically
        /// greatest key ends up first; use distinct priorities to express an order. A key that
        /// matches nothing fails ``start(_:)`` with ``PJSUAUsageError/unknownCodec(_:)``.
        public var codecPriorities: [String: UInt8] = [:]
        /// Video twin of ``codecPriorities`` (`pjsua_vid_codec_set_priority`), e.g.
        /// `["H264": 255]`. A separate property because pjsua keeps video codecs in their own
        /// codec manager: `H264` and an audio id do not share a namespace, so one map would
        /// have been a lie about the match. ``videoCodecs()`` lists the ids.
        public var videoCodecPriorities: [String: UInt8] = [:]
        public init() {}

        private enum CodingKeys: String, CodingKey {
            case transports, logLevel, logSinkLevel, messageLogging, userAgent, media
            case codecPriorities, videoCodecPriorities
        }

        /// `logSink` itself has no equality to compare, so `==` counts only set-vs-nil:
        /// a config that taps the log is a different configuration from one that does not.
        public static func == (l: Configuration, r: Configuration) -> Bool {
            l.transports == r.transports && l.logLevel == r.logLevel
                && l.logSinkLevel == r.logSinkLevel
                && l.messageLogging == r.messageLogging
                && l.userAgent == r.userAgent
                && l.media == r.media
                && l.codecPriorities == r.codecPriorities
                && l.videoCodecPriorities == r.videoCodecPriorities
                && (l.logSink == nil) == (r.logSink == nil)
        }

        /// Hand-written for the same reason as ``AccountConfiguration``: the synthesised
        /// `init(from:)` ignores property defaults, so **every** key would be mandatory and a
        /// document omitting any of them would fail to decode. Here that matters most — a
        /// config persisted before `transports` existed should still load.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            transports = try container.decodeIfPresent([TransportConfiguration].self,
                                                       forKey: .transports)
                ?? [.init("udp", .udp), .init("tcp", .tcp)]
            logLevel = try container.decodeIfPresent(UInt32.self, forKey: .logLevel) ?? 4
            logSinkLevel = try container.decodeIfPresent(UInt32.self, forKey: .logSinkLevel) ?? 5
            messageLogging = try container.decodeIfPresent(Bool.self, forKey: .messageLogging)
                ?? true
            userAgent = try container.decodeIfPresent(String.self, forKey: .userAgent)
                ?? "swift-pjsua"
            media = try container.decodeIfPresent(MediaConfiguration.self, forKey: .media)
                ?? MediaConfiguration()
            codecPriorities = try container.decodeIfPresent([String: UInt8].self,
                                                            forKey: .codecPriorities) ?? [:]
            videoCodecPriorities = try container.decodeIfPresent([String: UInt8].self,
                                                                 forKey: .videoCodecPriorities) ?? [:]
        }
    }

    public init() {
        // Install the global event sinks before anything can start delivering callbacks.
        let streams = makePJSUAEventStreams()
        self.events = streams.events
        self.callEvents = streams.callEvents
        self.registrationSignals = streams.registrationSignals
        self.videoTransmissionSignals = streams.videoTransmissionSignals
        self.executor = PJSIPExecutor()
    }

    // MARK: Lifecycle

    /// Create → init → start PJSUA. Runs on the executor thread; `pjsua_create()` makes
    /// that thread PJLIB's registered main thread, so all subsequent calls are safe.
    ///
    /// A start that throws leaves the engine as it found it, so it can be started again once the
    /// cause is gone: a port another app holds, for instance.
    public func start(_ config: Configuration = .init()) throws {
        precondition(state == .idle, "PJSUA.start() succeeds once; only a failed start may be retried")
        // pjsua does not substitute its default for a zero clock rate — it would size the
        // conference bridge's frames at zero samples. Refuse before pjsua_create; nothing to
        // clean up yet.
        guard config.media.clockRate != 0 else { throw PJSUAUsageError.zeroClockRate }

        // 1. create — initializes PJLIB; THIS thread becomes the registered main thread.
        try pjsua_create().throwIfFailed()
        executor.registerThisThread(name: "swift-pjsua.engine") // defensive no-op

        // 1a. Keep the RFC 3261 §18.1.1 UDP→TCP size switch enabled.
        //
        // `sip_util.c:1419` guards the whole §18.1.1 block on `disable_tcp_switch == 0` — size
        // check and TCP-transport lookup alike. With the switch off, an authenticated INVITE —
        // which crosses the 1300-byte threshold once the digest is added — is sent over UDP
        // anyway, fragments, and is dropped: no call over a UDP transport can ever be
        // established. Measured at two independent providers
        // (offhook docs/SIP-Test-Infrastructure.md §6).
        //
        // KEPT DELIBERATELY, though it is now belt-and-braces. `swift-pjsip` 0.1.x compiled the
        // binary with `PJSIP_DONT_SWITCH_TO_TCP 1` — the *opposite* of pjsip's default — and this
        // line was the only thing making UDP calling work at all. 0.2.0 drops that define, so a
        // current binary already has the switch on. The line stays because the package resolves
        // by range: an engine built against an older swift-pjsip would silently lose UDP calling
        // again, and re-asserting the pjsip default costs one store.
        //
        // Set at runtime because the compile-time macro lives in a prebuilt binary. The
        // placement is convention, not a requirement: `pjsua_init()` never reads this field.
        // `pjsip_cfg()->endpt.disable_tcp_switch` (`pjsip/sip_config.h:111`) is read *per send*,
        // in the RFC 3261 §18.1.1 block of `pjsip_endpt_send_request`'s path
        // (`sip_util.c:1419`), so it only has to be settled before the first request leaves.
        // Setting it beside the rest of the endpoint configuration is simply the earliest
        // point at which it is obviously done once.
        pjsip_cfg().pointee.endpt.disable_tcp_switch = 0

        // 2. configure: callbacks + logging + media.
        var cfg = pjsua_config()
        pjsua_config_default(&cfg)

        // G1 (load-bearing invariant): the custom executor only *enters* PJSIP calls; it
        // never calls `pjsua_handle_events`. PJSUA's own worker threads pump events and
        // fire our callbacks. With `thread_cnt == 0` callbacks would silently never fire,
        // so we pin it >= 1 and do not expose it as a knob.
        cfg.thread_cnt = 1
        precondition(cfg.thread_cnt >= 1, "PJSUA requires >= 1 worker thread to deliver callbacks")

        // user_agent must stay alive until pjsua_init copies it — so a strdup'd buffer
        // freed at function exit, NOT a withCString buffer that dies before pjsua_init.
        let cUserAgent = strdup(config.userAgent)
        defer { free(cUserAgent) }
        cfg.user_agent = pj_str(cUserAgent)

        installPJSUACallbacks(into: &cfg)

        var log = pjsua_logging_config()
        pjsua_logging_config_default(&log)
        log.msg_logging = pj_bool_t(config.messageLogging)
        if config.logSink != nil {
            // `console_level` gates which lines reach `cb` at all and `level` gates which
            // reach the writer — so both upstream ceilings get the max of the two requests,
            // and the independent per-path ceilings live inside `pjsuaOnLog` (which also
            // re-forwards console-eligible lines to `pj_log_write`, because `cb` *replaces*
            // console output rather than tapping it).
            let ceiling = max(config.logLevel, config.logSinkLevel)
            log.console_level = ceiling
            log.level = ceiling
            pjsuaLogConsoleLevel = Int32(clamping: config.logLevel)
            pjsuaLogSinkLevel = Int32(clamping: config.logSinkLevel)
            pjsuaLogSink = config.logSink
            log.cb = { level, data, len in pjsuaOnLog(level, data, len) }
        } else {
            log.console_level = config.logLevel
            // `level` gates what reaches the writer at all — leave it at pjsip's 5 and a
            // console level above 5 would silently see nothing. Keep the upstream filter
            // at least as permissive as the most verbose requested output.
            log.level = max(config.logLevel, config.logSinkLevel)
        }

        var media = pjsua_media_config()
        pjsua_media_config_default(&media)
        media.thread_cnt = 1 // media worker thread; keep >= 1 for the same reason as above.
        media.clock_rate = config.media.clockRate
        media.snd_clock_rate = config.media.soundDeviceClockRate

        do {
            try pjsua_init(&cfg, &log, &media).throwIfFailed()

            // Codec priorities are global to the one codec manager and callable once pjsua_init
            // has registered the factories; set here so the first offer already carries them.
            // Audio and video live in separate managers — two maps, two namespaces.
            try applyCodecPriorities(config.codecPriorities, using: pjsua_codec_set_priority)
            try applyCodecPriorities(config.videoCodecPriorities,
                                     using: pjsua_vid_codec_set_priority)

            // 3. transport(s) — one per TransportConfiguration, remembered by name so an
            // account can pin one (`AccountConfiguration.transportName` →
            // `acc_config.transport_id`). Ports live here, never on the account: pjsua has
            // no per-account port.
            for transport in config.transports {
                // Names are the only handle an account has on a transport, so a duplicate
                // would silently make one of them unreachable. Refuse rather than pick.
                guard transportIDs[transport.name] == nil else {
                    throw PJSUAUsageError.duplicateTransportName(transport.name)
                }
                var tcfg = pjsua_transport_config()
                pjsua_transport_config_default(&tcfg)
                tcfg.port = transport.port
                var transportId: pjsua_transport_id = -1 // PJSUA_INVALID_ID
                try pjsua_transport_create(transport.kind.pjType, &tcfg, &transportId)
                    .throwIfFailed()
                transportIDs[transport.name] = transportId
            }

            // Fail-fast is deliberate for a debug engine: if a listener cannot bind,
            // `start()` throws rather than continuing silently — a missing TCP transport
            // disables the §18.1.1 upgrade. A production build may prefer best-effort (log
            // and carry on). See TD-18.

            // 4. go
            try pjsua_start().throwIfFailed()
        } catch {
            // Once `pjsua_create()` has succeeded, pjsua must be destroyed (`pjsua.h`), and its own
            // sample does so when start fails. Left half built, the next start would create it over
            // the remains, and the transport map would still name the dead transports.
            pjsua_destroy()
            transportIDs.removeAll()
            // A failed start must not leave the tap installed: `shutdown()` only clears it
            // on the running path, so a throw here would leak the sink into the next start.
            pjsuaLogSink = nil
            throw error
        }
        state = .running

        // Apply the registration signals in this actor's turns for the engine's whole life; the
        // loop ends when `shutdown` finishes the stream.
        Task { [weak self, registrationSignals] in
            for await signal in registrationSignals {
                await self?.applyRegistrationSignal(signal)
            }
        }

        // Same lifetime for the video-transmission signals: `pjsuaOnCallMediaState` defers the
        // expensive `START_TRANSMIT` here so it runs on the engine thread, off the dialog lock.
        Task { [weak self, videoTransmissionSignals] in
            for await call in videoTransmissionSignals {
                await self?.reapplyVideoTransmission(call)
            }
        }
    }

    /// Re-apply the transmission half of ``CallMediaIntent`` after a video-stream rebuild
    /// (hold/unhold/re-INVITE) — the second half of the signal path that starts in
    /// `pjsuaOnCallMediaState`. The intent is re-read rather than carried on the signal:
    /// it may have changed while the notice was in flight (the user disabled transmission
    /// between the rebuild and this turn), and the current value is the honest one.
    /// `call_set_tx_video` (pjsua_vid.c) sets capture up itself when the rebuild released
    /// it (`cap_win_id == PJSUA_INVALID_ID`) and resumes the stream's encoding leg.
    ///
    /// A failure reaches the app as `.videoTransmissionFailed` on the guaranteed channel —
    /// the capture device unavailable (permission, locked/backgrounded, busy), or encoder start; the app
    /// reacts (e.g. shows "video unavailable", or retries with ``setVideoTransmission(_:_:streamIndex:)``).
    private func reapplyVideoTransmission(_ call: CallID) {
        guard SwiftPJSUA.mediaIntent(for: call.raw).transmitsVideo else { return }
        // The signal may have been queued before a local hold arrived: the audio
        // stream's `.localHold` status is the same proxy the callback uses for
        // pjsua's `!call->local_hold` guard — never restart transmission while held.
        var info = pjsua_call_info()
        if pjsua_call_get_info(call.raw, &info).isSuccess,
           callMediaInfos(from: &info)
               .contains(where: { $0.kind == .audio && $0.status == .localHold }) {
            return
        }
        var param = pjsua_call_vid_strm_op_param()
        pjsua_call_vid_strm_op_param_default(&param)
        let status = pjsua_call_set_vid_strm(call.raw, PJSUA_CALL_VID_STRM_START_TRANSMIT, &param)
        if !status.isSuccess {
            emitCallEvent(.videoTransmissionFailed(call: call, status: Int32(status)))
        }
    }

    /// Destroy PJSUA (on the executor thread) and stop the executor thread.
    public func shutdown() {
        if state == .running {
            pjsua_destroy()
        }
        state = .stopped
        // pjsua_destroy() invalidated every transport id; drop the stale name -> id map so a
        // later start() cannot resolve a transportName to a dead transport.
        transportIDs.removeAll()
        pjsuaLogSink = nil // worker threads are gone — safe to clear the process-global tap
        accountParameters.removeAll()
        stopRegistrationLifecycle() // after the accounts are gone: each waiter finds its own gone
        finishPJSUAEventStreams()
        executor.stop()
    }

    // MARK: Network change

    /// Tell the engine the device's IP/network changed — e.g. an `NWPathMonitor` saw a
    /// Wi-Fi ↔ cellular handoff (`pjsua_handle_ip_change` with all defaults). Restarts
    /// transport listeners, forcefully shuts down TCP/TLS transports, then per account:
    /// re-REGISTERs with the rewritten contact (`allow_contact_rewrite`) and re-INVITEs
    /// in-progress calls (UPDATE where the peer advertises it).
    ///
    /// Progress arrives as ``PJSUAEvent/ipChangeProgress`` ending in `.completed`. During the
    /// sequence pjsua ignores request timeouts (`keep_inv_after_tsx_timeout`), so calls survive
    /// the flap rather than dying on it.
    ///
    /// **A registration operation over every account**: it starts once no other registration
    /// operation runs and no account's registration is busy, and no account operation starts
    /// until pjsua reports the sequence complete. pjsua itself would run a second sequence over
    /// one still in progress ("Previous IP address change handling still in progress",
    /// `pjsua_core.c`). Requests coalesce: one made while an IP change runs is queued, and later
    /// ones join it, so one more sequence follows the running one.
    ///
    /// - Parameter wait: ``RegistrationWait/confirmed(timeout:)``, the default, returns when the
    ///   sequence completes; ``RegistrationWait/dispatched`` once pjsua has started it.
    /// - Throws: ``PJSUAError`` when pjsua refuses to start the sequence;
    ///   ``RegistrationError/ipChangeTimedOut`` when it does not complete in time, after which
    ///   account operations resume.
    public func handleIPChange(wait: RegistrationWait = .confirmed()) async throws {
        precondition(state == .running, "start() must complete before handleIPChange()")
        try await performRegistration(.all, joining: .ipChange, wait: wait) { engine, operation in
            try await engine.ipChangeSteps(operation: operation)
        }
    }

    private func ipChangeSteps(operation: UInt64) async throws {
        let mailbox = openRegistrationMailbox(for: nil)
        defer { closeRegistrationMailbox(mailbox) }
        await awaitQuietRegistrations(mailbox: mailbox)
        guard !registration.stopped else { throw CancellationError() }

        // A `COMPLETED` already applied belongs to an earlier sequence, not to this one.
        discardRegistrationSignals(in: mailbox)
        var param = pjsua_ip_change_param()
        pjsua_ip_change_param_default(&param) // NULL param is a hard assert, not "defaults"
        try pjsua_handle_ip_change(&param).throwIfFailed()
        markRegistrationDispatched(operation)

        let deadline = ContinuousClock.now + Self.registrationBackstop
        while true {
            guard let signal = await nextRegistrationSignal(in: mailbox, before: deadline) else {
                guard !registration.stopped else { throw CancellationError() }
                pjLog(2, "IP change not reported complete after \(Self.registrationBackstop); "
                         + "registration operations resume")
                throw RegistrationError.ipChangeTimedOut
            }
            if case .ipChangeCompleted = signal { return }
        }
    }
}
