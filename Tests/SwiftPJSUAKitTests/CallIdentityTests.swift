import XCTest
@testable import SwiftPJSUAKit

// NOTE: SwiftPJSUAKit links CallKit/PushKit and depends on the iOS-only PJSIP, so this
// target only builds/runs on the iOS Simulator:
//   xcodebuild test -scheme swift-pjsua -destination 'platform=iOS Simulator,name=iPhone 15'
final class CallIdentityTests: XCTestCase {
    // RFC 4122 / RFC 9562 worked example: UUIDv5(DNS namespace, "www.example.com").
    // The authoritative answer is 2ed6657d-e927-568b-95e1-2665a8aea6a2 — verified with
    // Python `uuid.uuid5(uuid.NAMESPACE_DNS, "www.example.com")` and a by-hand SHA-1 of the
    // namespace bytes + name. (An earlier literal ended ...ff66 and an autoreview suggestion
    // ...a1f2; both are wrong — the correct suffix is ...a6a2.)
    func testVersion5MatchesRFC4122KnownAnswer() {
        let dns = UUID(uuidString: "6ba7b810-9dad-11d1-80b4-00c04fd430c8")!
        let derived = UUID(version5: "www.example.com", namespace: dns)
        XCTAssertEqual(derived.uuidString.lowercased(), "2ed6657d-e927-568b-95e1-2665a8aea6a2")
    }

    func testVersion5IsDeterministicAndDistinct() {
        let a1 = UUID(version5: "call-id-A", namespace: CallIdentity.namespace)
        let a2 = UUID(version5: "call-id-A", namespace: CallIdentity.namespace)
        let b = UUID(version5: "call-id-B", namespace: CallIdentity.namespace)
        XCTAssertEqual(a1, a2, "same Call-ID must derive the same UUID on both paths")
        XCTAssertNotEqual(a1, b, "different Call-IDs must derive different UUIDs")
    }

    func testServerProvidedUUIDWins() {
        let server = UUID()
        let resolved = CallIdentity.uuid(serverProvided: server, sipCallID: "abc@host")
        XCTAssertEqual(resolved, server)
    }

    func testFallsBackToCallIDDerivedUUID() {
        let resolved = CallIdentity.uuid(serverProvided: nil, sipCallID: "abc@host")
        XCTAssertEqual(resolved, UUID(version5: "abc@host", namespace: CallIdentity.namespace))
    }

    func testTwoPathsSameCallIDAgree() {
        // Push path (no server UUID) and INVITE path (no server UUID) with the same Call-ID
        // must agree — this is what prevents a double ring.
        let pushSide = CallIdentity.uuid(serverProvided: nil, sipCallID: "shared-call-id@host")
        let inviteSide = CallIdentity.uuid(serverProvided: nil, sipCallID: "shared-call-id@host")
        XCTAssertEqual(pushSide, inviteSide)
    }
}
