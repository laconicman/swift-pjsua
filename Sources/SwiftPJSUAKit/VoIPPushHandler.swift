import Foundation
import PushKit
import SwiftPJSUA

/// Routes APNs pushes: a **VoIP** push reports an incoming call to CallKit (deduplicated
/// against the SIP INVITE via ``CallIdentity``); a **silent** push triggers a re-REGISTER
/// with updated push parameters (``PJSUA/reRegister(_:updatingPush:)``).
///
/// - Important: **Skeleton.** The payload schema below (`call_uuid` / `sip_call_id` / `from`)
///   is a placeholder to be matched to the real server contract, and the app still owns the
///   `PKPushRegistry` instance and its registration. The dedup + audio wiring it depends on
///   is real; the payload parsing and the silent-push branch are stubs for the next iteration.
public final class VoIPPushHandler: NSObject, PKPushRegistryDelegate {
    private let engine: PJSUA
    private let callKit: CallKitController

    public init(engine: PJSUA, callKit: CallKitController) {
        self.engine = engine
        self.callKit = callKit
        super.init()
    }

    // MARK: PKPushRegistryDelegate

    public func pushRegistry(_ registry: PKPushRegistry,
                             didUpdate pushCredentials: PKPushCredentials,
                             for type: PKPushType) {
        // pushCredentials.token is the APNs token. The app builds a PushConfiguration from it
        // and (re)registers; see PushConfiguration.apns(...) and PJSUA.reRegister(_:updatingPush:).
    }

    public func pushRegistry(_ registry: PKPushRegistry,
                             didReceiveIncomingPushWith payload: PKPushPayload,
                             for type: PKPushType,
                             completion: @escaping () -> Void) {
        // A VoIP push MUST result in a CallKit incoming-call report before this handler
        // returns, or iOS terminates the app. The payload may carry a server call UUID and the
        // SIP Call-ID so the report dedups against the INVITE that follows.
        let payloadDict = payload.dictionaryPayload
        let serverUUID = (payloadDict["call_uuid"] as? String).flatMap(UUID.init(uuidString:))
        let sipCallID = payloadDict["sip_call_id"] as? String
        let handle = (payloadDict["from"] as? String) ?? "Unknown"

        Task {
            await callKit.reportIncomingCall(serverUUID: serverUUID, sipCallID: sipCallID, handle: handle)
            completion()
        }
    }
}
