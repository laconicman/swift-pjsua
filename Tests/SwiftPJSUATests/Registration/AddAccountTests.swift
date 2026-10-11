import Foundation
import Testing
@testable import SwiftPJSUA

extension RegistrationTests {

    /// ``PJSUA/addAccount(_:credentials:wait:)``: the engine sends the first REGISTER itself and
    /// returns on its answer.
    @Suite struct AddAccount {

        /// The default wait returns on the registrar's answer, with one REGISTER sent: the
        /// engine's, none from `pjsua_acc_add`.
        @Test func addingReturnsOnceTheRegistrarConfirms() async throws {
            let registrar = try ScriptedRegistrar { _, _ in (.ok, after: .milliseconds(300)) }
            defer { registrar.stop() }

            try await RegistrationTests.withEngine { engine in
                let started = ContinuousClock.now
                let account = try await engine.addAccount(RegistrationTests.account(registrar),
                                                          credentials: RegistrationTests.password)
                #expect(ContinuousClock.now - started >= .milliseconds(300))
                #expect(await RegistrationTests.isRegistered(account, in: engine))

                try await Task.sleep(for: .milliseconds(500))   // room for a second REGISTER
                #expect(registrar.requests.count == 1, "\(registrar.requests)")
            }
        }

        /// A refused first REGISTER throws, and the error names the account, which stays: the
        /// caller can register it again, or remove it.
        @Test func aRejectedFirstRegisterThrowsAndKeepsTheAccount() async throws {
            let registrar = try ScriptedRegistrar { _, index in
                (index == 0 ? .reject(403) : .ok, after: .zero)
            }
            defer { registrar.stop() }

            try await RegistrationTests.withEngine { engine in
                var refused: AccountID?
                do {
                    try await engine.addAccount(RegistrationTests.account(registrar),
                                                credentials: RegistrationTests.password)
                } catch RegistrationError.rejected(let account, statusCode: 403) {
                    refused = account
                }
                let account = try #require(refused, "the refusal was not reported")
                #expect(await engine.accountParameters[account] != nil)

                try await engine.setRegistration(account, renew: true)
                #expect(await RegistrationTests.isRegistered(account, in: engine))
            }
        }

        /// ``RegistrationWait/dispatched`` returns once the REGISTER is sent; the registration
        /// goes on to the registrar's answer.
        @Test func dispatchedReturnsOnceTheRegisterIsSent() async throws {
            let registrar = try ScriptedRegistrar { _, _ in (.ok, after: .milliseconds(500)) }
            defer { registrar.stop() }

            try await RegistrationTests.withEngine { engine in
                let started = ContinuousClock.now
                let account = try await engine.addAccount(RegistrationTests.account(registrar),
                                                          credentials: RegistrationTests.password,
                                                          wait: .dispatched)
                #expect(ContinuousClock.now - started < .milliseconds(400))
                #expect(await engine.registration.sessions[account] == .pending)

                try await RegistrationTests.eventually {
                    await RegistrationTests.isRegistered(account, in: engine)
                }
            }
        }
    }
}
