import PJSIP
import XCTest
@testable import SwiftPJSUA

// NOTE: swift-pjsip ships an iOS-only xcframework, so this target only builds/runs on the
// iOS Simulator, e.g.:
//   xcodebuild test -scheme swift-pjsua -destination 'platform=iOS Simulator,name=iPhone 15'
// `swift test` on macOS will not link PJSIP.
final class CallStateTests: XCTestCase {
    func testKnownInviteStatesMapToCases() {
        XCTAssertEqual(CallState(PJSIP_INV_STATE_NULL), .null)
        XCTAssertEqual(CallState(PJSIP_INV_STATE_CALLING), .calling)
        XCTAssertEqual(CallState(PJSIP_INV_STATE_INCOMING), .incoming)
        XCTAssertEqual(CallState(PJSIP_INV_STATE_EARLY), .early)
        XCTAssertEqual(CallState(PJSIP_INV_STATE_CONNECTING), .connecting)
        XCTAssertEqual(CallState(PJSIP_INV_STATE_CONFIRMED), .confirmed)
        XCTAssertEqual(CallState(PJSIP_INV_STATE_DISCONNECTED), .disconnected)
    }
}
