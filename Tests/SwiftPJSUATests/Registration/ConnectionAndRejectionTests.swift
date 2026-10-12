import Foundation
import PJSIP
import Testing
@testable import SwiftPJSUA

extension RegistrationTests {

    /// ``PJSUAEvent/transportState(_:)`` (`on_transport_state`): the connection a registration goes
    /// over is reported when it comes up and when it dies, its death names the account, and
    /// ``PJSUA/registrationTransport(of:)`` names it in between. pjsua itself reports neither: its
    /// handler releases the connection and arms a retry silently (`docs/Tech-Debt.md` TD-31).
    @Suite struct Connections {

        @Test func aDeadRegistrationConnectionNamesItsAccount() async throws {
            // The second REGISTER, the unchanged re-registration's, is answered late.
            let registrar = try ScriptedRegistrar(over: .tcp) { _, index in
                (.ok, after: index == 1 ? .milliseconds(1500) : .zero)
            }
            var configuration = PJSUA.Configuration()
            configuration.transports = [.init("tcp", .tcp, port: 0)]
            let engine = PJSUA()
            try await engine.start(configuration)
            let events = Collected<PJSUAEvent>()
            let collector = Task { for await event in engine.callEvents { events.append(event) } }
            defer { collector.cancel() }
            do {
                var account = RegistrationTests.account(registrar)
                account.registrar = "sip:127.0.0.1:\(registrar.port);transport=tcp"
                let id = try await engine.addAccount(account, credentials: RegistrationTests.password)
                try await RegistrationTests.eventually {
                    events.transportChanges.contains { $0.state == .connected && $0.type == "TCP" }
                }
                let connected = events.transportChanges.first { $0.state == .connected }?.transport
                #expect(await engine.registrationTransport(of: id) == connected)

                // An unchanged re-registration keeps the session, so the connection stays named
                // while its REGISTER waits for the answer.
                try await engine.reRegister(id, wait: .dispatched)
                #expect(await engine.registrationTransport(of: id) == connected)
                try await RegistrationTests.eventually(within: .seconds(5)) {
                    guard registrar.requests.count == 2 else { return false }
                    return await RegistrationTests.isRegistered(id, in: engine)
                }
                #expect(await engine.registrationTransport(of: id) == connected)

                registrar.stop()   // closes the connection
                try await RegistrationTests.eventually {
                    events.transportChanges.contains {
                        $0.state == .disconnected && $0.registeredAccounts == [id]
                            && $0.transport == connected
                    }
                }
                #expect(await engine.registrationTransport(of: id) == nil)
            } catch {
                registrar.stop()
                await engine.shutdown()
                throw error
            }
            await engine.shutdown()
        }
    }

    /// ``PJSUAEvent/incomingCallRejected(call:sipCallID:from:statusCode:statusText:)``
    /// (`on_rejected_incoming_call`): an INVITE pjsua refuses itself never reaches
    /// ``PJSUAEvent/incomingCall(account:call:sipCallID:from:offeredVideo:)``, so this is its only
    /// report. With no account to take it, pjsua answers 480 (`pjsua_call_on_incoming`).
    @Suite struct RejectedCalls {

        @Test func anInviteNoAccountTakesIsReportedWithItsCallID() async throws {
            try await RegistrationTests.withEngine { engine in
                let events = Collected<PJSUAEvent>()
                let collector = Task { for await event in engine.callEvents { events.append(event) } }
                defer { collector.cancel() }
                let port = await engine.boundPort(of: "udp")
                try #require(port != 0)

                let callID = "rejected-\(UUID().uuidString)@127.0.0.1"
                try sendInvite(callID: callID, to: port)
                try await RegistrationTests.eventually {
                    events.rejections.contains { $0.sipCallID == callID && $0.statusCode >= 300 }
                }
                #expect(events.rejections.first { $0.sipCallID == callID }?.from
                        == "sip:carol@127.0.0.1")
                #expect(!events.all.contains {
                    if case .incomingCall = $0 { true } else { false }
                })
            }
        }

        /// Sends a body-less INVITE to the engine's UDP port from a throwaway socket. The 480 goes
        /// back to that socket unread.
        private func sendInvite(callID: String, to port: UInt16) throws {
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            defer { close(fd) }
            let message = [
                "INVITE sip:bob@127.0.0.1:\(port) SIP/2.0",
                "Via: SIP/2.0/UDP 127.0.0.1:9;rport;branch=z9hG4bK\(UUID().uuidString.prefix(8))",
                "Max-Forwards: 70",
                "From: <sip:carol@127.0.0.1>;tag=carol",
                "To: <sip:bob@127.0.0.1>",
                "Call-ID: \(callID)",
                "CSeq: 1 INVITE",
                "Contact: <sip:carol@127.0.0.1:9>",
                "Content-Length: 0",
                "", "",
            ].joined(separator: "\r\n")
            var address = sockaddr_in()
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr.s_addr = inet_addr("127.0.0.1")
            address.sin_port = port.bigEndian
            let bytes = Array(message.utf8)
            let sent = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard sent == bytes.count else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        }
    }
}

extension PJSUA {
    /// The port the transport named `name` is bound to, or `0` if pjsua cannot say. An actor
    /// method, so the pjsua call runs on the engine's thread.
    func boundPort(of name: String) -> UInt16 {
        guard let id = transportIDs[name] else { return 0 }
        var info = pjsua_transport_info()
        guard pjsua_transport_get_info(id, &info).isSuccess else { return 0 }
        return withUnsafePointer(to: &info.local_addr) { pj_sockaddr_get_port($0) }
    }
}

/// Events as they arrive, readable from the test while the collecting task appends.
private final class Collected<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Element] = []
    func append(_ item: Element) { lock.withLock { items.append(item) } }
    var all: [Element] { lock.withLock { items } }
}

private extension Collected where Element == PJSUAEvent {
    var transportChanges: [TransportStateChange] {
        all.compactMap { if case .transportState(let change) = $0 { change } else { nil } }
    }

    var rejections: [(sipCallID: String?, from: String?, statusCode: Int32)] {
        all.compactMap {
            if case .incomingCallRejected(_, let sipCallID, let from, let statusCode, _) = $0 {
                (sipCallID, from, statusCode)
            } else {
                nil
            }
        }
    }
}
