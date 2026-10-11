import Foundation
import Testing
@testable import SwiftPJSUA

extension RegistrationTests {

    /// ``PJSUA/setRegistration(_:renew:wait:)`` on the registration lifecycle.
    @Suite struct SetRegistration {

        /// The case that went wrong. An un-REGISTER asked for while the first REGISTER is still
        /// being challenged was refused with `PJSIP_EBUSY`. The engine must let the exchange end,
        /// then un-REGISTER, and return on the answer.
        @Test func unregisteringWhileTheFirstRegisterIsChallengedWaitsForIt() async throws {
            let registrar = try ScriptedRegistrar { request, index in
                if index == 0 { return (.challenge, after: .milliseconds(400)) }
                return (request.authorized ? .ok : .challenge, after: .zero)
            }
            defer { registrar.stop() }

            try await RegistrationTests.withEngine { engine in
                let account = try await engine.addAccount(RegistrationTests.account(registrar),
                                                          credentials: RegistrationTests.password,
                                                          wait: .dispatched)
                try await engine.setRegistration(account, renew: false)
                #expect(await engine.registration.sessions[account] == .unregistered)

                let requests = registrar.requests
                let unregister = try #require(requests.firstIndex { $0.isUnregister },
                                              "the binding was never un-REGISTERed: \(requests)")
                #expect(requests[..<unregister].contains { !$0.isUnregister && $0.authorized },
                        "the un-REGISTER went out before the challenged REGISTER was answered: \(requests)")
                #expect(!requests[unregister...].contains { !$0.isUnregister },
                        "a REGISTER followed the un-REGISTER: \(requests)")
            }
        }

        /// Off and on again: one un-REGISTER, then one REGISTER, each returning on its answer.
        @Test func unregisterThenRegisterAgain() async throws {
            let registrar = try ScriptedRegistrar { _, _ in (.ok, after: .milliseconds(100)) }
            defer { registrar.stop() }

            try await RegistrationTests.withEngine { engine in
                let account = try await engine.addAccount(RegistrationTests.account(registrar),
                                                          credentials: RegistrationTests.password)

                try await engine.setRegistration(account, renew: false)
                #expect(await engine.registration.sessions[account] == .unregistered)
                try await engine.setRegistration(account, renew: true)
                #expect(await RegistrationTests.isRegistered(account, in: engine))

                let requests = registrar.requests
                #expect(requests.map(\.isUnregister) == [false, true, false], "\(requests)")
            }
        }

        /// A send that pjsip created a transaction for and then failed to send reports a failure
        /// settlement on the engine's thread before the error returns. The report updates the
        /// session, and the account's next operation must not take it for its own answer. pjsip
        /// ends a send that way only on a transport failure loopback cannot stage on demand, so
        /// this drives the actor the way `sendRegistration` does after such a send.
        @Test func aFailedSendsOwnReportAnswersNoOperation() async throws {
            let registrar = try ScriptedRegistrar { _, _ in (.ok, after: .zero) }
            defer { registrar.stop() }

            try await RegistrationTests.withEngine { engine in
                let account = try await engine.addAccount(RegistrationTests.account(registrar),
                                                          credentials: RegistrationTests.password)
                let mailbox = await engine.openRegistrationMailbox(for: account)
                let failure = RegistrationSettlement(account: account, renew: true, status: 0,
                                                     code: 503, expiration: 0, refreshIn: nil,
                                                     bindings: [])

                await engine.expectReportOfFailedSend(on: account)
                await engine.applyRegistrationSignal(.settled(failure))
                #expect(await engine.registration.sessions[account] == .unregistered)
                #expect(await engine.registration.mailboxes[mailbox]?.pending.isEmpty == true,
                        "the failed send's report was delivered as an answer")

                await engine.applyRegistrationSignal(.settled(failure))
                #expect(await engine.registration.mailboxes[mailbox]?.pending.count == 1,
                        "a later report was swallowed")
                await engine.closeRegistrationMailbox(mailbox)
            }
        }
    }
}
