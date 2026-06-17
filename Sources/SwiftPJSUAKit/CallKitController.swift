import AVFoundation
import CallKit
import Foundation
import SwiftPJSUA

/// Bridges CallKit to the ``PJSUA`` engine.
///
/// - Important: **Skeleton.** This iteration wires the one piece needed for audio to flow —
///   the CallKit audio-session lifecycle drives the engine's sound-device API — plus a
///   deduplicated incoming-call report. CXAction handling (answer/end/hold/mute/DTMF) and
///   full provider configuration are intentionally deferred to the next iteration.
public final class CallKitController: NSObject, CXProviderDelegate {
    private let provider: CXProvider
    private let engine: PJSUA
    private let registry: CallRegistry

    public init(engine: PJSUA,
                registry: CallRegistry = CallRegistry(),
                configuration: CXProviderConfiguration = CallKitController.defaultConfiguration()) {
        self.engine = engine
        self.registry = registry
        self.provider = CXProvider(configuration: configuration)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    public static func defaultConfiguration() -> CXProviderConfiguration {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]
        return configuration
    }

    /// Report a new incoming call to CallKit, deduplicated via ``CallIdentity``. If the call
    /// (same server UUID or same SIP `Call-ID`) was already reported, this is a no-op and
    /// returns the existing UUID.
    ///
    /// - Returns: the CallKit UUID used for this call (stable across push and INVITE).
    @discardableResult
    public func reportIncomingCall(serverUUID: UUID?,
                                   sipCallID: String?,
                                   handle: String,
                                   hasVideo: Bool = false) async -> UUID {
        let uuid = CallIdentity.uuid(serverProvided: serverUUID, sipCallID: sipCallID)
        let isNew = await registry.firstSeen(uuid: uuid, sipCallID: sipCallID)
        guard isNew else { return uuid }

        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: handle)
        update.hasVideo = hasVideo
        provider.reportNewIncomingCall(with: uuid, update: update) { _ in }
        return uuid
    }

    // MARK: CXProviderDelegate

    public func providerDidReset(_ provider: CXProvider) {
        // CallKit dropped all calls (e.g. a crash recovery); tear down engine calls to match.
        Task { await engine.hangupAll() }
    }

    public func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        // CallKit activated the audio session — only now may PJSIP open the sound device.
        Task { try? await engine.activateAudioDevice() }
    }

    public func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        // Session is going away; release the device so PJSIP never holds the mic in background.
        Task { await engine.deactivateAudioDevice() }
    }
}
