import XCTest
@testable import SwiftPJSUAKit

final class VoIPPushPayloadTests: XCTestCase {
    /// The shape Flexisip 2.6.2 sends (`AppleRequest`, PushType::VoIP), as JSON-decoded by iOS.
    func testFlexisipPayload() throws {
        let json = #"""
        { "aps": { "sound": "", "loc-key": "IC_MSG", "loc-args": ["Alice"],
                   "call-id": "1-97362@192.168.64.1",
                   "uuid": "<urn:uuid:fd3b6f76-b04d-44a8-9e15-788bf09fc0f8>",
                   "send-time": "2026-10-05 13:17:23" },
          "from-uri": "sip:alice@example.com", "display-name": "Alice", "pn_ttl": 90,
          "customPayload": {} }
        """#
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [AnyHashable: Any])
        let push = VoIPPushPayload(payload)
        XCTAssertEqual(push.sipCallID, "1-97362@192.168.64.1")
        XCTAssertNil(push.serverUUID, "aps.uuid is the device's instance ID, never the call's UUID")
        XCTAssertEqual(push.handle, "Alice")
    }

    /// With `display-from-uri=false` (Flexisip's default) both caller fields arrive empty.
    func testFlexisipPayloadWithoutCallerFallsBackToUnknown() {
        let push = VoIPPushPayload(["aps": ["call-id": "c1"], "from-uri": "", "display-name": ""])
        XCTAssertEqual(push.sipCallID, "c1")
        XCTAssertEqual(push.handle, "Unknown")
    }

    func testFlexisipPayloadWithURIOnly() {
        let push = VoIPPushPayload(["aps": ["call-id": "c1"], "from-uri": "sip:bob@example.com",
                                    "display-name": ""])
        XCTAssertEqual(push.handle, "sip:bob@example.com")
    }

    func testPlaceholderKeysStillRead() {
        let uuid = UUID()
        let push = VoIPPushPayload(["call_uuid": uuid.uuidString, "sip_call_id": "c2",
                                    "from": "sip:carol@example.com"])
        XCTAssertEqual(push.serverUUID, uuid)
        XCTAssertEqual(push.sipCallID, "c2")
        XCTAssertEqual(push.handle, "sip:carol@example.com")
    }
}
