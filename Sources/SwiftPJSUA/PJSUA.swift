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

    /// Lifecycle events from PJSUA, as a cancellable async sequence.
    public nonisolated let events: AsyncStream<PJSUAEvent>

    enum State { case idle, running, stopped }
    private(set) var state: State = .idle

    /// Parameters of accounts added via ``addAccount(_:)``, kept so a silent-push
    /// re-REGISTER can rebuild the full account config with updated push parameters
    /// without the fragile `pjsua_acc_get_config` + pool dance. See `PJSUA+Accounts.swift`.
    var accountParameters: [AccountID: AccountParameters] = [:]

    /// Engine configuration. Note `thread_cnt` is intentionally *not* exposed: the design
    /// requires pjsua's worker threads to pump events, so it is pinned inside ``start(_:)``.
    public struct Configuration: Sendable {
        public var port: UInt32 = 5060
        public var transport: Transport = .udp
        public var logLevel: UInt32 = 4
        public var userAgent: String = "swift-pjsua"
        public init() {}
    }

    public init() {
        // Install the global event sink before anything can start delivering callbacks.
        self.events = makePJSUAEventStream()
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
        log.console_level = config.logLevel

        var media = pjsua_media_config()
        pjsua_media_config_default(&media)
        media.thread_cnt = 1 // media worker thread; keep >= 1 for the same reason as above.

        try pjsua_init(&cfg, &log, &media).throwIfFailed()

        // 3. transport
        var tcfg = pjsua_transport_config()
        pjsua_transport_config_default(&tcfg)
        tcfg.port = config.port
        var transportId: pjsua_transport_id = -1 // PJSUA_INVALID_ID
        try pjsua_transport_create(config.transport.pjType, &tcfg, &transportId).throwIfFailed()

        // 4. go
        try pjsua_start().throwIfFailed()
        state = .running
    }

    /// Destroy PJSUA (on the executor thread) and stop the executor thread.
    public func shutdown() {
        if state == .running {
            pjsua_destroy()
        }
        state = .stopped
        finishPJSUAEventStream()
        executor.stop()
    }
}
