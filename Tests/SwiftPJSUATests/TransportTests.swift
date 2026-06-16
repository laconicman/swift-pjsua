import PJSIP
import XCTest
@testable import SwiftPJSUA

final class TransportTests: XCTestCase {
    func testTransportMapsToPJSIPType() {
        XCTAssertEqual(Transport.udp.pjType, PJSIP_TRANSPORT_UDP)
        XCTAssertEqual(Transport.tcp.pjType, PJSIP_TRANSPORT_TCP)
        XCTAssertEqual(Transport.tls.pjType, PJSIP_TRANSPORT_TLS)
    }
}
