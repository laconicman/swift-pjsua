import Foundation
import Testing
@testable import SwiftPJSUA

extension RegistrationTests {

    /// ``PJSUA/reRegister(_:updatingPush:wait:)`` on the registration lifecycle (Tech-Debt TD-23).
    @Suite struct ReRegister {

        /// The case that used to go wrong. The token arrives while the first REGISTER is still
        /// being challenged. Modifying then would orphan that REGISTER, pjsip would answer its 401
        /// with the old, push-less Contact after the new REGISTER, and the trailing registration
        /// call would fail with `PJSIP_EBUSY`. The engine must let the exchange end, un-REGISTER the
        /// old binding and have that answered, and only then register the new one.
        @Test func pushChangeWhileTheFirstRegisterIsChallengedWaitsForIt() async throws {
            let registrar = try ScriptedRegistrar { request, index in
                if index == 0 { return (.challenge, after: .milliseconds(400)) }
                return (request.authorized ? .ok : .challenge, after: .zero)
            }
            defer { registrar.stop() }

            try await RegistrationTests.withEngine { engine in
                let account = try await engine.addAccount(RegistrationTests.account(registrar),
                                                          credentials: RegistrationTests.password,
                                                          wait: .dispatched)
                try await engine.reRegister(account, updatingPush: RegistrationTests.push)

                try await Task.sleep(for: .seconds(1))   // room for a straggler from an orphan
                let requests = registrar.requests
                let push = RegistrationTests.push.params
                let firstPush = try #require(requests.firstIndex { $0.carries(push) })
                #expect(requests[..<firstPush].contains { $0.isUnregister },
                        "the old binding was not un-REGISTERed first: \(requests)")
                #expect(!requests[firstPush...].contains { $0.isUnregister },
                        "the new REGISTER went out before the un-REGISTER was answered: \(requests)")
                #expect(requests[firstPush...].allSatisfy { $0.carries(push) },
                        "a REGISTER without the push parameters followed the first one with them: \(requests)")
            }
        }

        /// A push change on a quiet account: one un-REGISTER, answered before the one REGISTER that
        /// follows, and nothing else. Answers are slow enough that sending both at once, as
        /// `pjsua_acc_modify` would, shows up as the REGISTER arriving before the un-REGISTER's
        /// answer.
        @Test func pushChangeOnAQuietAccountUnregistersThenRegistersOnce() async throws {
            let registrar = try ScriptedRegistrar { _, _ in (.ok, after: .milliseconds(200)) }
            defer { registrar.stop() }

            try await RegistrationTests.withEngine { engine in
                let account = try await engine.addAccount(RegistrationTests.account(registrar),
                                                          credentials: RegistrationTests.password)
                try await engine.reRegister(account)   // returns once the binding is confirmed
                let before = registrar.requests.count

                try await engine.reRegister(account, updatingPush: RegistrationTests.push)

                try await Task.sleep(for: .seconds(1))   // room for an extra REGISTER, if any
                let afterChange = Array(registrar.requests.dropFirst(before))
                #expect(afterChange.count == 2, "\(afterChange)")
                #expect(afterChange.first?.isUnregister == true, "\(afterChange)")
                #expect(afterChange.last.map {
                    !$0.isUnregister && $0.carries(RegistrationTests.push.params)
                } == true, "\(afterChange)")
            }
        }

        /// Nothing changed, so the engine refreshes the binding on the existing session: one
        /// REGISTER, no un-REGISTER, same Call-ID.
        @Test func unchangedParametersSendOneRegisterOnTheSameSession() async throws {
            let registrar = try ScriptedRegistrar { _, _ in (.ok, after: .zero) }
            defer { registrar.stop() }

            try await RegistrationTests.withEngine { engine in
                var config = RegistrationTests.account(registrar)
                config.push = RegistrationTests.push
                let account = try await engine.addAccount(config, credentials: RegistrationTests.password)

                try await engine.reRegister(account)

                try await Task.sleep(for: .milliseconds(500))
                let requests = registrar.requests
                #expect(requests.count == 2, "\(requests)")
                #expect(requests.allSatisfy {
                    !$0.isUnregister && $0.carries(RegistrationTests.push.params)
                }, "\(requests)")
                #expect(Set(requests.map(\.callID)).count == 1, "\(requests)")
            }
        }

        /// A registrar that answers at once, so pjsua may report a settlement before the start that
        /// led to it. Every re-registration must still end on its own answer, quickly, with no
        /// wait into the backstop.
        @Test func anInstantRegistrarNeverStallsAnOperation() async throws {
            let registrar = try ScriptedRegistrar { _, _ in (.ok, after: .zero) }
            defer { registrar.stop() }

            try await RegistrationTests.withEngine { engine in
                let account = try await engine.addAccount(RegistrationTests.account(registrar),
                                                          credentials: RegistrationTests.password)
                for _ in 0..<5 {
                    let started = ContinuousClock.now
                    try await engine.reRegister(account)
                    #expect(ContinuousClock.now - started < .seconds(2))
                }
                #expect(registrar.requests.count == 6, "\(registrar.requests)")
            }
        }

        /// A rotated password changes only how the REGISTER authenticates, not the binding: no
        /// un-REGISTER, and a REGISTER on a fresh session (a new Call-ID) that authenticates anew.
        @Test func credentialChangeRegistersOnAFreshSessionWithoutUnregistering() async throws {
            let registrar = try ScriptedRegistrar { request, _ in
                (request.authorized ? .ok : .challenge, after: .zero)
            }
            defer { registrar.stop() }
            let password = Password("first")

            try await RegistrationTests.withEngine { engine in
                let account = try await engine.addAccount(
                    RegistrationTests.account(registrar),
                    credentials: InlineCredentialStore { _ in password.value })
                try await engine.reRegister(account)   // returns once the binding is confirmed
                let before = registrar.requests
                password.value = "rotated"

                try await engine.reRegister(account)

                let afterRotation = Array(registrar.requests.dropFirst(before.count))
                #expect(!afterRotation.isEmpty)
                #expect(!afterRotation.contains { $0.isUnregister }, "\(afterRotation)")
                #expect(afterRotation.allSatisfy { !before.map(\.callID).contains($0.callID) },
                        "the REGISTER reused the old session: \(afterRotation)")
                #expect(afterRotation.contains { $0.authorized }, "\(afterRotation)")
            }
        }

        /// The registrar refuses the new binding: the call throws its status code.
        @Test func aRejectedRegisterThrowsItsStatusCode() async throws {
            let registrar = try ScriptedRegistrar { request, _ in
                (request.carries(RegistrationTests.push.params) && !request.isUnregister
                    ? .reject(403) : .ok, after: .zero)
            }
            defer { registrar.stop() }

            try await RegistrationTests.withEngine { engine in
                let account = try await engine.addAccount(RegistrationTests.account(registrar),
                                                          credentials: RegistrationTests.password)
                await #expect(throws: RegistrationError.rejected(account, statusCode: 403)) {
                    try await engine.reRegister(account, updatingPush: RegistrationTests.push)
                }
            }
        }

        /// A 2xx whose bindings lack the push parameters is not a confirmation: the registrar did
        /// not keep the Contact it was sent.
        @Test func aBindingWithoutThePushParametersIsNotConfirmed() async throws {
            let registrar = try ScriptedRegistrar { request, _ in
                (request.carries(RegistrationTests.push.params) && !request.isUnregister
                    ? .okListing("sip:alice@127.0.0.1:1") : .ok, after: .zero)
            }
            defer { registrar.stop() }

            try await RegistrationTests.withEngine { engine in
                let account = try await engine.addAccount(RegistrationTests.account(registrar),
                                                          credentials: RegistrationTests.password)
                await #expect(throws: RegistrationError.bindingNotConfirmed(account)) {
                    try await engine.reRegister(account, updatingPush: RegistrationTests.push)
                }
            }
        }

        /// Two requests while the first REGISTER is in flight: the later push parameters win, both
        /// callers succeed, and the earlier parameters never reach the wire.
        @Test func concurrentRequestsCoalesceAndTheLatestPushWins() async throws {
            let registrar = try ScriptedRegistrar { _, index in
                (.ok, after: index == 0 ? .milliseconds(600) : .zero)
            }
            defer { registrar.stop() }

            try await RegistrationTests.withEngine { engine in
                let account = try await engine.addAccount(RegistrationTests.account(registrar),
                                                          credentials: RegistrationTests.password,
                                                          wait: .dispatched)
                let first = Task {
                    try await engine.reRegister(account, updatingPush: RegistrationTests.otherPush)
                }
                // Start the second only once the first is recorded, so "latest" is well defined.
                try await RegistrationTests.eventually {
                    await engine.accountParameters[account]?.config.push == RegistrationTests.otherPush
                }
                let second = Task {
                    try await engine.reRegister(account, updatingPush: RegistrationTests.push)
                }

                try await first.value
                try await second.value
                let requests = registrar.requests
                #expect(!requests.contains { $0.carries(RegistrationTests.otherPush.params) },
                        "superseded push parameters were sent: \(requests)")
                #expect(requests.filter(\.isUnregister).count == 1, "\(requests)")
                #expect(requests.contains { $0.carries(RegistrationTests.push.params) }, "\(requests)")
            }
        }

        /// ``RegistrationWait/dispatched`` returns once the request is out, and the operation goes
        /// on to the registrar's answer.
        @Test func dispatchedReturnsBeforeTheAnswer() async throws {
            let registrar = try ScriptedRegistrar { _, _ in (.ok, after: .milliseconds(500)) }
            defer { registrar.stop() }

            try await RegistrationTests.withEngine { engine in
                let account = try await engine.addAccount(RegistrationTests.account(registrar),
                                                          credentials: RegistrationTests.password)
                try await engine.reRegister(account)   // the first binding, confirmed

                let started = ContinuousClock.now
                try await engine.reRegister(account, wait: .dispatched)
                #expect(ContinuousClock.now - started < .milliseconds(400))
                #expect(await engine.registration.sessions[account] == .pending)

                try await RegistrationTests.eventually {
                    await RegistrationTests.isRegistered(account, in: engine)
                }
            }
        }

        /// A REGISTER that never settles: the caller's wait runs out with
        /// ``RegistrationError/timedOut(_:)``, and nothing more is sent meanwhile.
        @Test func aRegisterThatNeverSettlesTimesOut() async throws {
            let registrar = try ScriptedRegistrar { _, _ in (.silence, after: .zero) }
            defer { registrar.stop() }

            try await RegistrationTests.withEngine { engine in
                let account = try await engine.addAccount(RegistrationTests.account(registrar),
                                                          credentials: RegistrationTests.password,
                                                          wait: .dispatched)
                try await RegistrationTests.eventually { registrar.requests.count == 1 }

                let started = ContinuousClock.now
                await #expect(throws: RegistrationError.timedOut(account)) {
                    try await engine.reRegister(account, updatingPush: RegistrationTests.push,
                                                wait: .confirmed(timeout: .milliseconds(500)))
                }
                let waited = ContinuousClock.now - started
                #expect(waited >= .milliseconds(500), "gave up before the timeout: \(waited)")
                #expect(registrar.requests.count == 1, "\(registrar.requests)")
            }
        }

        /// The confirmation check reads push parameters out of a binding without regard to case,
        /// order or other parameters, and fails when one is missing.
        @Test func pushParametersAreFoundInABinding() {
            let push = PushConfiguration(params: ";pn-provider=apns;pn-param=T.app.voip;pn-prid=AB12")
            #expect(push.isCarried(by: "sip:alice@10.0.0.1:5060;ob;PN-PRID=ab12;pn-param=T.app.voip;pn-provider=apns"))
            #expect(push.isCarried(by: "<sip:alice@10.0.0.1;pn-provider=apns;pn-param=T.app.voip;pn-prid=ab12>"))
            #expect(!push.isCarried(by: "sip:alice@10.0.0.1:5060;pn-provider=apns;pn-param=T.app.voip"))
            #expect(!push.isCarried(by: "sip:alice@10.0.0.1:5060?pn-provider=apns"))
        }

        /// A refresh that settles while the operation waits for its secret is applied before the
        /// REGISTER goes out, and must not be taken for that REGISTER's answer. pjsip refreshes a
        /// 10 s registration 5 s in; the secret takes 6 s; the registrar answers the REGISTER 1 s
        /// late.
        @Test func aRefreshDuringTheSecretFetchDoesNotAnswerTheRegister() async throws {
            let registrar = try ScriptedRegistrar { _, index in
                (.ok, after: index == 2 ? .seconds(1) : .zero)
            }
            defer { registrar.stop() }
            let secrets = SlowSecondSecret()

            try await RegistrationTests.withEngine { engine in
                var config = RegistrationTests.account(registrar)
                config.registrationTimeout = 10
                let account = try await engine.addAccount(
                    config, credentials: InlineCredentialStore { _ in try await secrets.next() })

                try await engine.reRegister(account)

                let answered = ContinuousClock.now
                let fetched = try #require(await secrets.lastReturn)
                let requests = registrar.requests
                #expect(requests.count == 3, "add, refresh, re-register: \(requests)")
                #expect(answered - fetched >= .milliseconds(800),
                        "returned on the refresh's answer, not the REGISTER's")
            }
        }

        /// Secrets for the test above: the second one, the re-registration's, takes 6 s.
        private actor SlowSecondSecret {
            private var fetches = 0
            private(set) var lastReturn: ContinuousClock.Instant?

            func next() async throws -> String {
                fetches += 1
                if fetches == 2 { try await Task.sleep(for: .seconds(6)) }
                lastReturn = .now
                return "secret"
            }
        }

        /// A password the test can change while the engine holds the store.
        private final class Password: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: String
            init(_ value: String) { stored = value }
            var value: String {
                get { lock.withLock { stored } }
                set { lock.withLock { stored = newValue } }
            }
        }
    }
}
