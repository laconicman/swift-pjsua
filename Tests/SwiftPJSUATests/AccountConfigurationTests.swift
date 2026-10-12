import Foundation
import XCTest
@testable import SwiftPJSUA

/// The fields ``AccountConfiguration`` applies when an account is added: persisted documents
/// written before a field existed still decode, and each value reaches the wire in the first
/// REGISTER — ``AccountConfiguration/registrationTimeout`` as its `Expires`,
/// ``AccountConfiguration/instanceID`` and ``AccountConfiguration/usesSIPOutbound`` in its
/// `Contact` and `Supported` headers, and the Contact again in the un-REGISTER.
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

    /// `Expires: 0` would un-REGISTER the binding it means to create, so the add refuses it.
    func testZeroRegistrationTimeoutIsRefused() async throws {
        let engine = PJSUA()
        self.engine = engine
        try await engine.start(PJSUA.Configuration())

        do {
            try await engine.addAccount(
                AccountConfiguration(id: "sip:alice@127.0.0.1", registrar: "sip:127.0.0.1:9",
                                     username: "alice", registrationTimeout: 0),
                credentials: InlineCredentialStore(password: "unused"))
            XCTFail("an account with a zero registration timeout was added")
        } catch PJSUAUsageError.zeroRegistrationTimeout {
            // expected
        }
        let accounts = await engine.accountParameters
        XCTAssertTrue(accounts.isEmpty)
    }

    func testRegistrationTimeoutSetsRegisterExpires() async throws {
        let register = try await firstRegister(account(registrationTimeout: 3600))
        XCTAssertEqual(header("Expires", in: register), "3600")
    }

    func testNilRegistrationTimeoutKeepsPJSUADefault() async throws {
        let register = try await firstRegister(account())
        XCTAssertEqual(header("Expires", in: register), "300")
    }

    // MARK: Instance ID and SIP outbound

    private static let instanceID = UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!
    private static let instanceParameter =
        #"+sip.instance="<urn:uuid:e621e1f8-c36c-495a-93fc-0c247a3e6e5f>""#

    func testDocumentWithoutInstanceIDOrOutboundDecodesToDefaults() throws {
        let json = #"{"id":"sip:a@example.com","registrar":"sip:example.com","username":"a"}"#
        let decoded = try JSONDecoder().decode(AccountConfiguration.self, from: Data(json.utf8))
        XCTAssertNil(decoded.instanceID)
        XCTAssertTrue(decoded.usesSIPOutbound)

        var config = decoded
        config.instanceID = Self.instanceID
        config.usesSIPOutbound = false
        let roundTripped = try JSONDecoder().decode(AccountConfiguration.self,
                                                    from: JSONEncoder().encode(config))
        XCTAssertEqual(roundTripped.instanceID, Self.instanceID)
        XCTAssertFalse(roundTripped.usesSIPOutbound)
    }

    /// Over UDP there is no SIP outbound, so before pjproject#5313 not even a configured instance
    /// ID was sent. Since swift-pjsip 0.3.0 it is, as a lower-case UUID URN although the `UUID`
    /// prints upper case.
    func testInstanceIDIsSentOverUDPInLowerCase() async throws {
        let register = try await firstRegister(account(instanceID: Self.instanceID))
        let contact = try XCTUnwrap(header("Contact", in: register))
        XCTAssertTrue(contact.contains(Self.instanceParameter), contact)
        XCTAssertFalse(contact.contains("reg-id"), contact)
    }

    /// The stable shape on a registrar that does not confirm outbound: the instance ID, and nothing
    /// that pjsua would drop from a later REGISTER — no `reg-id`, no `ob`, no outbound option tag.
    func testInstanceIDWithoutOutboundOverTCP() async throws {
        let listener = try SilentTCPListener()
        let register = try await firstRegister(account(registrar: listener.registrar,
                                                       instanceID: Self.instanceID,
                                                       usesSIPOutbound: false))
        let contact = try XCTUnwrap(header("Contact", in: register))
        XCTAssertTrue(contact.contains(Self.instanceParameter), contact)
        XCTAssertFalse(contact.contains("reg-id"), contact)
        XCTAssertFalse(contact.contains(";ob"), contact)
        XCTAssertFalse(header("Supported", in: register)?.contains("outbound") ?? false)
    }

    /// pjsua's default, unchanged: over TCP it offers outbound with the instance ID and `reg-id`.
    func testOutboundStaysOnByDefaultOverTCP() async throws {
        let listener = try SilentTCPListener()
        let register = try await firstRegister(account(registrar: listener.registrar,
                                                       instanceID: Self.instanceID))
        let contact = try XCTUnwrap(header("Contact", in: register))
        XCTAssertTrue(contact.contains(Self.instanceParameter), contact)
        XCTAssertTrue(contact.contains("reg-id=1"), contact)
        XCTAssertTrue(header("Supported", in: register)?.contains("outbound") ?? false)
    }

    // MARK: Contact lifecycle

    /// What `usesSIPOutbound` is for. With a configured instance ID and outbound off, the
    /// un-REGISTER carries the first REGISTER's Contact unchanged, so a registrar that keys on the
    /// instance, on `reg-id` or on the URI matches it either way. The scripted registrar answers over
    /// TCP without `Require: outbound`: the answer after which pjsua changes the Contact when
    /// outbound is on.
    func testContactIsUnchangedFromRegisterToUnregisterWithoutOutbound() async throws {
        let (first, unregister) = try await registerThenUnregister(usesSIPOutbound: false)
        XCTAssertEqual(first, unregister)
        XCTAssertTrue(first.contains(Self.instanceParameter), first)
    }

    /// The contrast. With outbound on, the first REGISTER offers `reg-id`, and the un-REGISTER that
    /// follows an unconfirming 200 drops it while keeping the configured instance ID. On a registrar
    /// keying bindings on (instance, `reg-id`) that un-REGISTER matches nothing.
    func testOutboundOnDropsRegIDAfterAnUnconfirmingAnswer() async throws {
        let (first, unregister) = try await registerThenUnregister(usesSIPOutbound: true)
        XCTAssertTrue(first.contains("reg-id=1"), first)
        XCTAssertFalse(unregister.contains("reg-id"), unregister)
        XCTAssertTrue(unregister.contains(Self.instanceParameter), unregister)
    }

    /// Adds an account with the instance ID against a scripted TCP registrar, waits for its 200,
    /// removes it, and returns the Contact of the first REGISTER and of the un-REGISTER as the
    /// registrar received them.
    private func registerThenUnregister(usesSIPOutbound: Bool) async throws -> (String, String) {
        let registrar = try ScriptedRegistrar(over: .tcp) { _, _ in (.ok, after: .zero) }
        defer { registrar.stop() }
        let engine = PJSUA()
        self.engine = engine
        try await engine.start(PJSUA.Configuration())

        let id = try await engine.addAccount(
            account(registrar: "sip:127.0.0.1:\(registrar.port);transport=tcp",
                    instanceID: Self.instanceID,
                    usesSIPOutbound: usesSIPOutbound),
            credentials: InlineCredentialStore(password: "unused"))
        try await engine.removeAccount(id)

        let requests = registrar.requests
        let first = try XCTUnwrap(requests.first { !$0.isUnregister }?.contact, "\(requests)")
        let unregister = try XCTUnwrap(requests.last { $0.isUnregister }?.contact, "\(requests)")
        return (first, unregister)
    }

    // MARK: Harness

    private func account(registrar: String = "sip:127.0.0.1:9",
                         registrationTimeout: UInt32? = nil,
                         instanceID: UUID? = nil,
                         usesSIPOutbound: Bool = true) -> AccountConfiguration {
        AccountConfiguration(id: "sip:alice@127.0.0.1",
                             registrar: registrar,
                             username: "alice",
                             registrationTimeout: registrationTimeout,
                             instanceID: instanceID,
                             usesSIPOutbound: usesSIPOutbound)
    }

    /// Adds `account` and returns the lines of the first REGISTER pjsip logs as sent. Nothing
    /// answers; the send alone is the measurement.
    private func firstRegister(_ account: AccountConfiguration) async throws -> [Substring] {
        let lines = Lines()
        var configuration = PJSUA.Configuration()
        configuration.logSink = { _, text in lines.append(text) }
        let engine = PJSUA()
        self.engine = engine
        try await engine.start(configuration)

        try await engine.addAccount(account,
                                    credentials: InlineCredentialStore(password: "unused"),
                                    wait: .dispatched)

        let requestLine = "REGISTER \(account.registrar) SIP/2.0"
        for _ in 0..<50 {
            if let message = lines.snapshot.first(where: { $0.contains(requestLine) }) {
                return message.split(whereSeparator: \.isNewline)
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("no REGISTER was logged")
        return []
    }

    private func header(_ name: String, in lines: [Substring]) -> String? {
        lines.first { $0.hasPrefix("\(name):") }
            .map { $0.dropFirst(name.count + 1).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// A loopback TCP port that is listened on and never read. The kernel completes the handshake
    /// for a listening socket, which is all pjsip needs to send the REGISTER over TCP.
    private final class SilentTCPListener {
        let registrar: String
        private let socket: Int32

        init() throws {
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }

            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            address.sin_port = 0
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let listening = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, length) == 0 && listen(fd, 4) == 0
                        && getsockname(fd, $0, &length) == 0
                }
            }
            guard listening else {
                close(fd)
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            socket = fd
            registrar = "sip:127.0.0.1:\(UInt16(bigEndian: address.sin_port));transport=tcp"
        }

        deinit { close(socket) }
    }
}
