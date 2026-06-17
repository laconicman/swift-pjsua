import Foundation
import PushKit
import SwiftPJSUA

/// Routes APNs pushes to the engine and CallKit:
///
/// - a **VoIP** push (PushKit, ``pushRegistry(_:didReceiveIncomingPushWith:for:)``) reports an
///   incoming call to CallKit, deduplicated against the SIP INVITE via ``CallIdentity``;
/// - a **silent** background push — which is delivered through the app delegate's
///   `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`, **not** PushKit —
///   is forwarded to ``handleSilentPush(_:account:updatingPush:)`` to re-REGISTER with updated
///   push parameters (``PJSUA/reRegister(_:updatingPush:)``).
///
/// - Important: **Skeleton.** The payload schemas (`call_uuid` / `sip_call_id` / `from` for VoIP;
///   `action == "reregister"` for silent) are placeholders to be matched to the real server
///   contract, and the app still owns the `PKPushRegistry` instance and its registration.
///
/// - SeeAlso: Responding to VoIP Notifications from PushKit
///   (<https://developer.apple.com/documentation/PushKit/responding-to-voip-notifications-from-pushkit>);
///   Pushing background updates to your App
///   (<https://developer.apple.com/documentation/usernotifications/pushing-background-updates-to-your-app>).
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

    // Modern async variant of `pushRegistry(_:didReceiveIncomingPushWith:for:)` (iOS 11+,
    // available at our iOS 17 floor). A VoIP push MUST result in a CallKit incoming-call
    // report before this method **returns** — i.e. before the `async` task completes — or iOS
    // terminates the app and repeated failures revoke the VoIP token. Reporting via `await`
    // here and returning afterwards satisfies that contract without the old completion-handler
    // dance. The payload may carry a server call UUID and the SIP Call-ID so the report dedups
    // against the INVITE that follows (see ``CallIdentity``).
    //
    // TODO: When the deployment target reaches iOS 26.4+, adopt
    // `pushRegistry(_:didReceiveIncomingVoIPPushWith:metadata:withCompletionHandler:)` and
    // honour `PKVoIPPushMetadata.mustReport` — it is `false` when the app is foreground / a
    // call is already active / the push arrived late, which lets us skip a redundant
    // CallKit report and is directly useful for the dual-mode no-double-ring path.
    public func pushRegistry(_ registry: PKPushRegistry,
                             didReceiveIncomingPushWith payload: PKPushPayload,
                             for type: PKPushType) async {
        guard type == .voIP else { return }

        let payloadDict = payload.dictionaryPayload
        let serverUUID = (payloadDict["call_uuid"] as? String).flatMap(UUID.init(uuidString:))
        let sipCallID = payloadDict["sip_call_id"] as? String
        let handle = (payloadDict["from"] as? String) ?? "Unknown"

        await callKit.reportIncomingCall(serverUUID: serverUUID, sipCallID: sipCallID, handle: handle)
    }

    // MARK: Silent push → re-REGISTER

    /// Handle a **silent** background push by re-REGISTERing `account`, optionally swapping in new
    /// push parameters. Call this from the app delegate's
    /// `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)` — silent pushes do
    /// **not** flow through PushKit.
    ///
    /// This path is deliberately independent of the VoIP-push answer path and of app-lifecycle
    /// events: ``PJSUA/reRegister(_:updatingPush:)`` only mutates this account's config and
    /// registration, so a silent re-REGISTER cannot race or tear down an in-flight incoming call.
    /// To carry a *regular* APNs token instead of the VoIP `pn-param` (a deviated scenario), build
    /// the override with ``PushConfiguration/init(params:scope:)`` or
    /// ``PushConfiguration/apns(teamID:bundleID:token:pushType:scope:)`` (e.g. `pushType: ""`).
    ///
    /// - Parameters:
    ///   - payload: the silent push's `dictionaryPayload` (or `userInfo`).
    ///   - account: the account to refresh; the app holds this from ``PJSUA/addAccount(id:registrar:username:password:realm:push:makeDefault:)``.
    ///   - push: replacement push parameters, or `nil` to keep the account's current ones.
    public func handleSilentPush(_ payload: [AnyHashable: Any],
                                 account: AccountID,
                                 updatingPush push: PushConfiguration? = nil) async {
        // Skeleton contract: a silent push carrying `"action": "reregister"` asks the client to
        // refresh its registration (e.g. the server rotated push routing). Unrelated silent pushes
        // are ignored. Match this to the real server payload schema.
        guard (payload["action"] as? String) == "reregister" else { return }
        do {
            try await engine.reRegister(account, updatingPush: push)
        } catch {
            // Best-effort: the account's periodic REGISTER refresh recovers if this fails.
        }
    }
}
