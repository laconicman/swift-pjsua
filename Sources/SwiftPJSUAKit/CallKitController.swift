import AVFoundation
import CallKit
import Foundation
import SwiftPJSUA

/// The `CXProviderDelegate` that bridges CallKit to the ``PJSUA`` engine.
///
/// This type is intentionally **thin**: it owns the `CXProvider`, starts the
/// ``CallSessionRouter``, and forwards every `CXAction` and audio-session callback into it.
/// All correlation logic (which engine event fulfills which action, dedup, registry ownership)
/// lives in the router — the single consumer of ``PJSUA/events`` (design **D-ROUTER**).
/// ``VoIPPushHandler`` reports incoming pushes through ``reportIncomingCall(serverUUID:sipCallID:handle:hasVideo:)``.
///
/// - SeeAlso: `CXProviderDelegate`
///   (<https://developer.apple.com/documentation/callkit/cxproviderdelegate>),
///   Making and receiving VoIP calls
///   (<https://developer.apple.com/documentation/callkit/making-and-receiving-voip-calls>).
public final class CallKitController: NSObject, CXProviderDelegate {
    private let provider: CXProvider
    private let engine: PJSUA

    /// The single engine-event consumer and CallKit/SIP correlation hub. Exposed so the app can
    /// set the outgoing account (``CallSessionRouter/setOutgoingAccount(_:)``) and so
    /// ``VoIPPushHandler`` can reach it.
    public let router: CallSessionRouter

    public init(engine: PJSUA,
                registry: CallRegistry = CallRegistry(),
                configuration: CXProviderConfiguration = CallKitController.defaultConfiguration()) {
        self.engine = engine
        let provider = CXProvider(configuration: configuration)
        self.provider = provider
        // CXProvider is not Sendable, but Apple documents its report methods as thread-safe, so the
        // actor may issue reports on it. It is created here and handed to the router once.
        self.router = CallSessionRouter(engine: engine, provider: provider, registry: registry)
        super.init()
        provider.setDelegate(self, queue: nil)
        Task { await router.start() }
    }

    public static func defaultConfiguration() -> CXProviderConfiguration {
        let configuration = CXProviderConfiguration()
        // Shape the full video surface from the start (design D-VIDEO); pixel rendering lands in the
        // Offhook app.
        configuration.supportsVideo = true
        // Allow local conferences: CallKit shows merge/split UI and routes CXSetGroupCallAction,
        // mapped to the engine conference bridge (design §7.1). The ceiling is the local-mix
        // participant cap; apps may tune it.
        configuration.maximumCallsPerCallGroup = 5
        configuration.supportedHandleTypes = [.generic]
        return configuration
    }

    /// Report a new incoming call to CallKit, deduplicated via ``CallIdentity`` / ``CallRegistry``
    /// inside the router. If the call (same server UUID or same SIP `Call-ID`) was already reported
    /// — e.g. the VoIP push and the socket INVITE both arrive — this is a no-op and returns the
    /// existing UUID, so the user sees a single ring (design §9).
    ///
    /// - Returns: the CallKit UUID used for this call (stable across push and INVITE).
    /// - Throws: when CallKit refuses to surface the call (blocked caller, DND, etc.). The
    ///   PushKit contract — calling `reportNewIncomingCall` before the push handler returns — is
    ///   satisfied regardless of the outcome, so callers on the push path may safely swallow.
    @discardableResult
    public func reportIncomingCall(serverUUID: UUID?,
                                   sipCallID: String?,
                                   handle: String,
                                   hasVideo: Bool = false) async throws -> UUID {
        try await router.reportIncomingCall(serverUUID: serverUUID,
                                            sipCallID: sipCallID,
                                            handle: handle,
                                            hasVideo: hasVideo)
    }

    // MARK: CXProviderDelegate — actions forwarded to the router

    public func providerDidReset(_ provider: CXProvider) {
        // CallKit dropped all calls (e.g. a crash recovery); tear down engine calls to match.
        Task { await router.reset() }
    }

    public func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Task { await router.startCall(action) }
    }

    public func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { await router.answerCall(action) }
    }

    public func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { await router.endCall(action) }
    }

    public func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        Task { await router.setHeld(action) }
    }

    public func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        Task { await router.setMuted(action) }
    }

    public func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        Task { await router.playDTMF(action) }
    }

    public func provider(_ provider: CXProvider, perform action: CXSetGroupCallAction) {
        Task { await router.setGroup(action) }
    }

    // MARK: CXProviderDelegate — audio session lifecycle

    public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        // CallKit activated the audio session — only now may PJSIP open the sound device.
        Task { try? await engine.activateAudioDevice() }
    }

    public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        // Session is going away; release the device so PJSIP never holds the mic in background.
        Task { await engine.deactivateAudioDevice() }
    }
}
