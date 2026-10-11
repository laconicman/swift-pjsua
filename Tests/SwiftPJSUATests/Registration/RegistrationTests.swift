import Foundation
import Testing
@testable import SwiftPJSUA

/// The engine's registration operations against a ``ScriptedRegistrar`` on loopback, which decides
/// when each request is answered, and how. That timing is the subject: operations must run on the
/// registration's lifecycle, never into a transaction in flight (`docs/Registration-Lifecycle.md`).
///
/// One serialized suite with a nested suite per operation, each in its own file: pjsua is a
/// process-global library, so at most one engine may run at a time, across all of them.
@Suite(.serialized)
struct RegistrationTests {

    static let push = PushConfiguration(params: ";pn-provider=apns;pn-param=TEAM.app.voip;pn-prid=c0ffee")
    static let otherPush = PushConfiguration(params: ";pn-provider=apns;pn-param=TEAM.app.voip;pn-prid=beef")
    static let password = InlineCredentialStore(password: "secret")

    static func account(_ registrar: ScriptedRegistrar) -> AccountConfiguration {
        AccountConfiguration(id: "sip:alice@127.0.0.1",
                             registrar: "sip:127.0.0.1:\(registrar.port)",
                             username: "alice")
    }

    /// Run `body` against a started engine on an ephemeral UDP port, and shut it down after.
    static func withEngine(_ body: (PJSUA) async throws -> Void) async throws {
        var configuration = PJSUA.Configuration()
        configuration.transports = [.init("udp", .udp, port: 0)]
        let engine = PJSUA()
        try await engine.start(configuration)
        do {
            try await body(engine)
        } catch {
            await engine.shutdown()
            throw error
        }
        await engine.shutdown()
    }

    /// Wait until `condition` holds, looking every 20 ms; record an issue if it never does.
    static func eventually(within limit: Duration = .seconds(5),
                           sourceLocation: SourceLocation = #_sourceLocation,
                           _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + limit
        while await !condition() {
            guard ContinuousClock.now < deadline else {
                Issue.record("condition not met within \(limit)", sourceLocation: sourceLocation)
                return
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Whether the engine's state shows `account` registered.
    static func isRegistered(_ account: AccountID, in engine: PJSUA) async -> Bool {
        if case .registered = await engine.registration.sessions[account] { return true }
        return false
    }
}
