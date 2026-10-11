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
    }
}
