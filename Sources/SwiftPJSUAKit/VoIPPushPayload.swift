import Foundation

/// What ``VoIPPushHandler`` reads from a VoIP push: the identifiers that match it to the INVITE
/// that follows, and a handle to show.
///
/// The contract is **Flexisip's** VoIP payload (`AppleRequest`, checked in its 2.6.2 source):
///
/// ```json
/// { "aps": { "sound": "", "loc-key": "IC_MSG", "loc-args": ["…"],
///            "call-id": "<SIP Call-ID>", "uuid": "<+sip.instance>", "send-time": "…" },
///   "from-uri": "sip:…", "display-name": "…", "pn_ttl": 90, "customPayload": {} }
/// ```
///
/// `aps.uuid` is the **device's** instance ID, not a call identifier, so it is never used as the
/// CallKit UUID. `from-uri` and `display-name` are empty unless the server sets
/// `module::PushNotification/display-from-uri=true`. The earlier placeholder schema's
/// `sip_call_id` and `from` are read as a fallback. Its `call_uuid` is not read: the INVITE that
/// follows has no server UUID, so it would get the Call-ID's UUID instead and ring a second time
/// (Tech-Debt TD-30).
struct VoIPPushPayload {
    /// The INVITE's `Call-ID`: Flexisip's `aps.call-id`, else `sip_call_id`.
    var sipCallID: String?
    /// Who is calling: `display-name`, else `from-uri`, else `from`, else `"Unknown"`.
    var handle: String

    init(_ payload: [AnyHashable: Any]) {
        let aps = payload["aps"] as? [AnyHashable: Any]
        func text(_ value: Any?) -> String? {
            (value as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        sipCallID = text(aps?["call-id"]) ?? text(payload["sip_call_id"])
        handle = text(payload["display-name"]) ?? text(payload["from-uri"])
            ?? text(payload["from"]) ?? "Unknown"
    }
}
