import Foundation
import Testing
@testable import SwiftPJSUA

extension RegistrationTests {

    /// ``PJSUA/handleIPChange(wait:)``: one sequence at a time, holding every account's
    /// registration still until pjsua reports it complete.
    @Suite struct HandleIPChange {

        /// The default wait returns once the sequence completes, after pjsua re-registered the
        /// account.
        @Test func returnsOnceTheSequenceCompletes() async throws {
            let registrar = try ScriptedRegistrar { _, index in
                (.ok, after: index == 1 ? .milliseconds(300) : .zero)
            }
            defer { registrar.stop() }

            try await RegistrationTests.withEngine { engine in
                let account = try await engine.addAccount(RegistrationTests.account(registrar),
                                                          credentials: RegistrationTests.password)
                let started = ContinuousClock.now
                try await engine.handleIPChange()
                #expect(ContinuousClock.now - started >= .milliseconds(300),
                        "returned before the re-REGISTER was answered")
                #expect(registrar.requests.count == 2, "\(registrar.requests)")
                #expect(await RegistrationTests.isRegistered(account, in: engine))
            }
        }

        /// The case that went wrong: a re-registration asked for while the IP change re-registers
        /// the account was refused with `PJSIP_EBUSY`. It must wait for the sequence instead, and
        /// send nothing into it.
        @Test func aReRegisterDuringTheSequenceWaitsForIt() async throws {
            let registrar = try ScriptedRegistrar { _, index in
                (.ok, after: index == 1 ? .milliseconds(500) : .zero)
            }
            defer { registrar.stop() }

            try await RegistrationTests.withEngine { engine in
                let account = try await engine.addAccount(RegistrationTests.account(registrar),
                                                          credentials: RegistrationTests.password)
                try await engine.handleIPChange(wait: .dispatched)
                let started = ContinuousClock.now

                try await engine.reRegister(account)

                #expect(ContinuousClock.now - started >= .milliseconds(400),
                        "did not wait for the IP change's re-REGISTER")
                try await Task.sleep(for: .milliseconds(300))   // room for a stray REGISTER
                #expect(registrar.requests.count == 3, "\(registrar.requests)")
            }
        }

        /// Requests made while a sequence runs coalesce into one more sequence after it.
        @Test func requestsDuringASequenceCoalesceIntoOneMore() async throws {
            let registrar = try ScriptedRegistrar { _, index in
                (.ok, after: index == 1 ? .milliseconds(500) : .zero)
            }
            defer { registrar.stop() }

            try await RegistrationTests.withEngine { engine in
                try await engine.addAccount(RegistrationTests.account(registrar),
                                            credentials: RegistrationTests.password)
                try await engine.handleIPChange(wait: .dispatched)

                async let second: Void = engine.handleIPChange()
                async let third: Void = engine.handleIPChange()
                _ = try await (second, third)

                try await Task.sleep(for: .milliseconds(300))   // room for a third sequence
                // The add's REGISTER, then one re-REGISTER per sequence.
                #expect(registrar.requests.count == 3, "\(registrar.requests)")
            }
        }
    }
}
