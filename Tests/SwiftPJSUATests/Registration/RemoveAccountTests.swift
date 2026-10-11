import Foundation
import Testing
@testable import SwiftPJSUA

extension RegistrationTests {

    /// ``PJSUA/removeAccount(_:wait:)``: un-REGISTER, answered, then delete — never into a
    /// REGISTER in flight.
    @Suite struct RemoveAccount {

        /// The case that went wrong. `pjsua_acc_del` with the first REGISTER still challenged
        /// refused its own un-REGISTER and orphaned the REGISTER, whose 401 pjsip then answered:
        /// the registrar kept a binding for the deleted account and was never told otherwise. The
        /// engine must let the exchange end, then un-REGISTER, and only then delete.
        @Test func removalWhileTheFirstRegisterIsChallengedWaitsForIt() async throws {
            let registrar = try ScriptedRegistrar { request, index in
                if index == 0 { return (.challenge, after: .milliseconds(400)) }
                return (request.authorized ? .ok : .challenge, after: .zero)
            }
            defer { registrar.stop() }

            try await RegistrationTests.withEngine { engine in
                let account = try await engine.addAccount(RegistrationTests.account(registrar),
                                                          credentials: RegistrationTests.password)
                try await engine.removeAccount(account)
                #expect(await engine.accountParameters[account] == nil)

                try await Task.sleep(for: .seconds(1))   // room for a straggler from an orphan
                let requests = registrar.requests
                let unregister = try #require(requests.firstIndex { $0.isUnregister },
                                              "the binding was never un-REGISTERed: \(requests)")
                #expect(requests[..<unregister].contains { !$0.isUnregister && $0.authorized },
                        "the un-REGISTER went out before the challenged REGISTER was answered: \(requests)")
                #expect(!requests[unregister...].contains { !$0.isUnregister },
                        "a REGISTER followed the un-REGISTER: \(requests)")
            }
        }

        /// A registered account: one un-REGISTER, answered, and the account is gone.
        @Test func removingARegisteredAccountUnregistersItFirst() async throws {
            let registrar = try ScriptedRegistrar { _, _ in (.ok, after: .milliseconds(100)) }
            defer { registrar.stop() }

            try await RegistrationTests.withEngine { engine in
                let account = try await engine.addAccount(RegistrationTests.account(registrar),
                                                          credentials: RegistrationTests.password)
                try await RegistrationTests.eventually {
                    await RegistrationTests.isRegistered(account, in: engine)
                }

                try await engine.removeAccount(account)

                #expect(await engine.accountParameters[account] == nil)
                #expect(await engine.registration.sessions[account] == nil)
                let requests = registrar.requests
                #expect(requests.count == 2 && requests.last?.isUnregister == true, "\(requests)")
            }
        }

        /// The registrar refuses the un-REGISTER: the account is removed all the same, the call
        /// says the binding may remain, and pjsua's own retry after the failure sends nothing for
        /// the deleted account.
        @Test func aRefusedUnregisterStillRemovesTheAccount() async throws {
            let registrar = try ScriptedRegistrar { request, _ in
                (request.isUnregister ? .reject(500) : .ok, after: .zero)
            }
            defer { registrar.stop() }

            try await RegistrationTests.withEngine { engine in
                let account = try await engine.addAccount(RegistrationTests.account(registrar),
                                                          credentials: RegistrationTests.password)
                await #expect(throws: RegistrationError.rejected(account, statusCode: 500)) {
                    try await engine.removeAccount(account)
                }
                #expect(await engine.accountParameters[account] == nil)

                try await Task.sleep(for: .seconds(1))
                let requests = registrar.requests
                let unregister = try #require(requests.lastIndex { $0.isUnregister })
                #expect(unregister == requests.count - 1, "something followed the un-REGISTER: \(requests)")
            }
        }
    }
}
