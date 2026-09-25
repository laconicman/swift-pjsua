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

    enum State { case idle, running, stopped }
    private(set) var state: State = .idle

    /// Whether ``start(_:)`` has completed and ``shutdown()`` hasn't run — the only state in
    /// which call/account APIs are valid. Cross-module consumers (SwiftPJSUAKit's router)
    /// gate engine calls on it rather than trusting event ordering at shutdown boundaries.
    public var isRunning: Bool { state == .running }

    /// Parameters of accounts added via ``addAccount(_:credentials:)``, kept so a silent-push
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
        public init() {}

        private enum CodingKeys: String, CodingKey {
            case transports, logLevel, logSinkLevel, messageLogging, userAgent
        }

        /// `logSink` itself has no equality to compare, so `==` counts only set-vs-nil:
        /// a config that taps the log is a different configuration from one that does not.
        public static func == (l: Configuration, r: Configuration) -> Bool {
            l.transports == r.transports && l.logLevel == r.logLevel
                && l.logSinkLevel == r.logSinkLevel
                && l.messageLogging == r.messageLogging
                && l.userAgent == r.userAgent
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
        }
    }

    public init() {
        // Install the global event sinks before anything can start delivering callbacks.
        let streams = makePJSUAEventStreams()
        self.events = streams.events
        self.callEvents = streams.callEvents
        self.executor = PJSIPExecutor()
    }

    // MARK: Lifecycle

    /// Create → init → start PJSUA. Runs on the executor thread; `pjsua_create()` makes
    /// that thread PJLIB's registered main thread, so all subsequent calls are safe.
    public func start(_ config: Configuration = .init()) throws {
        precondition(state == .idle, "PJSUA.start() must be called exactly once")

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

        do {
            try pjsua_init(&cfg, &log, &media).throwIfFailed()

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
            // A failed start must not leave the tap installed: `shutdown()` only clears it
            // on the running path, so a throw here would leak the sink into the next start.
            pjsuaLogSink = nil
            throw error
        }
        state = .running
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
    /// Progress arrives as ``PJSUAEvent/ipChangeProgress`` ending in `.completed`. Safe to
    /// call repeatedly — pjsua detects a handling sequence already in progress and skips
    /// re-entering it. During the sequence pjsua ignores request timeouts
    /// (`keep_inv_after_tsx_timeout`), so calls survive the flap rather than dying on it.
    public func handleIPChange() throws {
        precondition(state == .running, "start() must complete before handleIPChange()")
        var param = pjsua_ip_change_param()
        pjsua_ip_change_param_default(&param) // NULL param is a hard assert, not "defaults"
        try pjsua_handle_ip_change(&param).throwIfFailed()
    }
}
