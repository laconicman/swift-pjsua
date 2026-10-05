import Foundation
import XCTest
@testable import SwiftPJSUA

/// ``AccountConfiguration/registrationTimeout``: persisted documents written before the field
/// existed still decode, and the value reaches the wire as the REGISTER's `Expires`.
final class AccountConfigurationTests: XCTestCase {

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func append(_ text: String) {
            lock.lock()
            stored.append(text)
            lock.unlock()
        }
        var snapshot: [String] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    private var engine: PJSUA?

    override func tearDown() async throws {
        try? await engine?.shutdown()
        engine = nil
    }

    func testDocumentWithoutRegistrationTimeoutDecodesToNil() throws {
        let json = #"{"id":"sip:a@example.com","registrar":"sip:example.com","username":"a"}"#
        let decoded = try JSONDecoder().decode(AccountConfiguration.self, from: Data(json.utf8))
        XCTAssertNil(decoded.registrationTimeout)

        var config = decoded
        config.registrationTimeout = 3600
        let roundTripped = try JSONDecoder().decode(AccountConfiguration.self,
                                                    from: JSONEncoder().encode(config))
        XCTAssertEqual(roundTripped.registrationTimeout, 3600)
    }

    func testRegistrationTimeoutSetsRegisterExpires() async throws {
        let expires = try await firstRegisterExpires(registrationTimeout: 3600)
        XCTAssertEqual(expires, "3600")
    }

    func testNilRegistrationTimeoutKeepsPJSUADefault() async throws {
        let expires = try await firstRegisterExpires(registrationTimeout: nil)
        XCTAssertEqual(expires, "300")
    }

    /// Adds an account aimed at a closed local port and reads the `Expires` header of the first
    /// REGISTER pjsip logs as sent. Nothing answers; the send alone is the measurement.
    private func firstRegisterExpires(registrationTimeout: UInt32?) async throws -> String? {
        let lines = Lines()
        var configuration = PJSUA.Configuration()
        configuration.logSink = { _, text in lines.append(text) }
        let engine = PJSUA()
        self.engine = engine
        try await engine.start(configuration)

        try await engine.addAccount(
            AccountConfiguration(id: "sip:alice@127.0.0.1",
                                 registrar: "sip:127.0.0.1:9",
                                 username: "alice",
                                 registrationTimeout: registrationTimeout),
            credentials: InlineCredentialStore(password: "unused"))

        for _ in 0..<50 {
            if let message = lines.snapshot.first(where: { $0.contains("REGISTER sip:127.0.0.1:9") }) {
                return message.split(whereSeparator: \.isNewline)
                    .first { $0.hasPrefix("Expires:") }
                    .map { $0.dropFirst("Expires:".count).trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("no REGISTER was logged")
        return nil
    }
}
