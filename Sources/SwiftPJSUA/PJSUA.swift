import Foundation
import PJSIP

// MARK: - C callback bridge
//
// pjsua1 callbacks are C function pointers that carry no user-data context, so they
// can't capture `self`. We bridge them through one file-private sink. pjsua is a
// *process-global* library (there is one instance), so a single sink is the honest
// model, not a hack.
//
// `nonisolated(unsafe)` invariant: written exactly once in `PJSUA.init`, before
// `pjsua_start()` can fire any callback; read-only thereafter. `AsyncStream.Continuation`
// is `Sendable` and its `yield` is thread-safe, so yielding from PJSUA's worker-thread
// callbacks is safe. Removal plan: when pjsua gains per-instance user-data on these
// callbacks, replace the global with that.
private nonisolated(unsafe) var pjsuaEventSink: AsyncStream<PJSUAEvent>.Continuation?

// These run on PJSUA's internal worker threads, which PJLIB has already registered —
// so calling PJSIP from inside them is allowed. We only ever read POD and yield a
// `Sendable` event; we never touch actor or UI state directly (that would be a race).

private func pjsuaOnCallState(_ callId: pjsua_call_id, _ event: UnsafeMutablePointer<pjsip_event>?) {
    var info = pjsua_call_info()
    guard pjsua_call_get_info(callId, &info) == 0 else { return }
    pjsuaEventSink?.yield(.callState(CallID(callId), CallState(info.state)))
}

private func pjsuaOnIncomingCall(_ accId: pjsua_acc_id,
                                 _ callId: pjsua_call_id,
                                 _ rdata: UnsafeMutablePointer<pjsip_rx_data>?) {
    pjsuaEventSink?.yield(.incomingCall(AccountID(accId), CallID(callId)))
}

private func pjsuaOnCallMediaState(_ callId: pjsua_call_id) {
    // Safe to call PJSIP here (registered worker thread).
    // TODO: when the call's media is PJSUA_CALL_MEDIA_ACTIVE, bridge it to the sound
    // device's conference slot, e.g.:
    //     var info = pjsua_call_info(); pjsua_call_get_info(callId, &info)
    //     pjsua_conf_connect(info.conf_slot, 0)   // remote audio → speaker
    //     pjsua_conf_connect(0, info.conf_slot)   // mic          → remote
    // (Newer PJSIP exposes per-media info via info.media[]/media_cnt instead of
    //  a single info.conf_slot — match your build.) The AVAudioSession activation
    // itself belongs in the app and must be coordinated with CallKit's
    // provider(_:didActivate:), not done here.
    pjsuaEventSink?.yield(.callMediaActive(CallID(callId)))
}

private func pjsuaOnRegState2(_ accId: pjsua_acc_id, _ info: UnsafeMutablePointer<pjsua_reg_info>?) {
    // TODO: read the real result, e.g. `info?.pointee.cbparam?.pointee.code` for the
    // SIP status and `.expiration` to distinguish register vs unregister. Left minimal
    // here because the exact enum/struct import varies across PJSIP versions.
    pjsuaEventSink?.yield(.registrationState(AccountID(accId), active: true, statusCode: 0))
}

// MARK: - PJSUA engine

/// A Swift-only, async front end to PJSIP's pjsua1 C API.
///
/// **Isolation is the bridge.** This actor's executor is a single dedicated,
/// PJLIB-registered POSIX thread (`PJSIPExecutor`). Because the actor runs *there*,
/// each method below can call the blocking PJSIP C function directly and return its
/// result — `await phone.makeCall(...)` performs the hop, runs the call on the right
/// thread, and hands back the value. No `withCheckedContinuation`, no GCD, no C++ shim.
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

    private enum State { case idle, running, stopped }
    private var state: State = .idle

    public struct Configuration: Sendable {
        public var port: UInt32 = 5060
        public var transport: Transport = .udp
        public var logLevel: UInt32 = 4
        public var userAgent: String = "swift-pjsua"
        public init() {}
    }

    public init() {
        let (stream, continuation) = AsyncStream<PJSUAEvent>.makeStream(
            bufferingPolicy: .bufferingNewest(64)
        )
        self.events = stream
        self.executor = PJSIPExecutor()
        // Safe: set before start() (the only thing that begins delivering callbacks).
        pjsuaEventSink = continuation
    }

    // MARK: Lifecycle

    /// Create → init → start PJSUA. Runs on the executor thread; `pjsua_create()` makes
    /// that thread PJLIB's registered main thread, so all subsequent calls are safe.
    public func start(_ config: Configuration = .init()) throws {
        precondition(state == .idle, "PJSUA.start() must be called exactly once")

        // 1. create — initializes PJLIB; THIS thread becomes the registered main thread.
        try check(pjsua_create())
        executor.registerThisThread(name: "swift-pjsua.engine") // defensive no-op

        // 2. configure: callbacks + logging + media. Closures are non-capturing, so they
        //    convert to @convention(c) function pointers automatically.
        var cfg = pjsua_config()
        pjsua_config_default(&cfg)
        // user_agent must stay alive until pjsua_init copies it — so a strdup'd buffer
        // freed at function exit, NOT a withCString buffer that dies before pjsua_init.
        let cUserAgent = strdup(config.userAgent)
        defer { free(cUserAgent) }
        cfg.user_agent = pj_str(cUserAgent)
        cfg.cb.on_call_state       = { callId, ev   in pjsuaOnCallState(callId, ev) }
        cfg.cb.on_incoming_call    = { acc, callId, rx in pjsuaOnIncomingCall(acc, callId, rx) }
        cfg.cb.on_call_media_state = { callId       in pjsuaOnCallMediaState(callId) }
        cfg.cb.on_reg_state2       = { acc, info    in pjsuaOnRegState2(acc, info) }

        var log = pjsua_logging_config()
        pjsua_logging_config_default(&log)
        log.console_level = config.logLevel

        var media = pjsua_media_config()
        pjsua_media_config_default(&media)

        try check(pjsua_init(&cfg, &log, &media))

        // 3. transport
        var tcfg = pjsua_transport_config()
        pjsua_transport_config_default(&tcfg)
        tcfg.port = config.port
        var transportId: pjsua_transport_id = -1
        try check(pjsua_transport_create(config.transport.pjType, &tcfg, &transportId))

        // 4. go
        try check(pjsua_start())
        state = .running
    }

    /// Destroy PJSUA (on the executor thread) and stop the executor thread.
    public func shutdown() {
        if state == .running {
            pjsua_destroy()
        }
        state = .stopped
        pjsuaEventSink?.finish()
        executor.stop()
    }

    // MARK: Accounts

    /// Add a SIP account and start registration. pjsua copies the config strings into
    /// its own pool, so the `strdup`'d buffers only need to live across this call.
    @discardableResult
    public func addAccount(id: String,
                           registrar: String,
                           username: String,
                           password: String,
                           realm: String = "*") throws -> AccountID {
        var acc = pjsua_acc_config()
        pjsua_acc_config_default(&acc)

        let cId = strdup(id), cReg = strdup(registrar)
        let cRealm = strdup(realm), cScheme = strdup("digest")
        let cUser = strdup(username), cPass = strdup(password)
        defer { [cId, cReg, cRealm, cScheme, cUser, cPass].forEach { free($0) } }

        acc.id = pj_str(cId)
        acc.reg_uri = pj_str(cReg)
        acc.cred_count = 1
        acc.cred_info.0.realm = pj_str(cRealm)
        acc.cred_info.0.scheme = pj_str(cScheme)
        acc.cred_info.0.username = pj_str(cUser)
        acc.cred_info.0.data_type = 0 // PJSIP_CRED_DATA_PLAIN_PASSWD
        acc.cred_info.0.data = pj_str(cPass)

        var accId: pjsua_acc_id = -1 // PJSUA_INVALID_ID
        try check(pjsua_acc_add(&acc, 1 /* PJ_TRUE: make default */, &accId))
        return AccountID(accId)
    }

    /// Toggle registration for an account (REGISTER / un-REGISTER).
    public func setRegistration(_ account: AccountID, renew: Bool) throws {
        try check(pjsua_acc_set_registration(account.raw, renew ? 1 : 0))
    }

    // MARK: Calls

    /// Place an outbound call. The returned `CallID` means the INVITE was *sent*; the
    /// answered/failed outcome arrives via `events` as `.callState`.
    @discardableResult
    public func makeCall(to uri: String, from account: AccountID) throws -> CallID {
        precondition(state == .running, "start() must complete before makeCall()")
        var opt = pjsua_call_setting()
        pjsua_call_setting_default(&opt)

        var callId: pjsua_call_id = -1 // PJSUA_INVALID_ID
        let status = uri.withCString { cstr -> pj_status_t in
            // pjsua_call_make_call parses/copies the URI during the call, so a pointer
            // valid for the duration of withCString is sufficient.
            var dst = pj_str(UnsafeMutablePointer(mutating: cstr))
            return pjsua_call_make_call(account.raw, &dst, &opt, nil, nil, &callId)
        }
        try check(status)
        return CallID(callId)
    }

    /// Answer an incoming call (default 200 OK).
    public func answer(_ call: CallID, statusCode: UInt32 = 200) throws {
        try check(pjsua_call_answer(call.raw, statusCode, nil, nil))
    }

    /// Hang up a call (default 603 Decline; use 486 Busy, 487 Cancelled, etc.).
    public func hangup(_ call: CallID, statusCode: UInt32 = 603) throws {
        try check(pjsua_call_hangup(call.raw, statusCode, nil, nil))
    }

    /// Hang up every active call.
    public func hangupAll() {
        pjsua_call_hangup_all()
    }
}
