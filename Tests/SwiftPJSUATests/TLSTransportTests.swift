import Foundation
import PJSIP
import XCTest
@testable import SwiftPJSUA

/// What a TLS transport actually does on iOS, observed against the C API rather than
/// inferred from the headers.
///
/// Three things about our TLS surface had only ever been established by reading source,
/// and each of them decides whether we can ship TLS at all:
///
/// * **Eager validation.** The Apple/Network.framework backend loads the server identity
///   once, at listener start — `network_start_accept()` → `network_create_params()` →
///   `create_identity_from_cert()`, before `nw_listener_create()` — so an unloadable
///   certificate fails `pjsua_transport_create()` itself rather than every later
///   handshake. pjproject#5216 made that the house rule for all backends. If a PJSIP bump
///   ever reverts it, ``testMissingCertificateFailsAtTransportCreate`` goes red here
///   instead of in the field.
/// * **The 8 KB truncation.** `create_data_from_file()` reads a single 8192-byte chunk and
///   treats it as the whole file, so a larger bundle is silently truncated and then fails
///   as unparsable. pjproject#5222 fixes that and is *not* in our pinned binary, so
///   ``testOversizedPKCS12StillFailsToLoad`` is a detector: when it starts failing, the
///   fix has arrived.
/// * **TD-19 / TD-22.** Whether a listener restart keeps the credentials the listener was
///   created with. That decides whether the recovery path upstream's design assumes —
///   "a certificate that becomes loadable late needs an explicit restart" — is usable at
///   all. The last two tests are the point of this file.
///
/// **iOS only, by construction.** iOS imports the private key from the `.p12` itself
/// (`SecPKCS12Import()`); macOS resolves it through the keychain (`SecItemImport()` +
/// `SecIdentityCreateWithCertificate()`) and the very same file fails there with
/// `errSecItemNotFound`. See `swift-pjsip/docs/Apple-TLS-Backends.md`.
final class TLSTransportTests: XCTestCase {

    // MARK: - Positive control

    /// A small, valid PKCS#12 with the right password creates a TLS listener.
    ///
    /// Everything else in this file is only meaningful if this passes, so the other tests
    /// skip rather than fail when it does not.
    func testValidPKCS12CreatesTLSTransport() throws {
        let certificate = try TLSFixture.path("good")
        try withPJSUA {
            let created = createTLSTransport(certFile: certificate)
            XCTAssertTrue(created.status.isSuccess,
                          "pjsua_transport_create(TLS) with a valid .p12 failed: "
                          + created.status.strError())
            XCTAssertNotEqual(boundPort(created.id), 0,
                              "listener reported ready but is not bound to a port")
        }
    }

    // MARK: - Eager failure (pjproject#5216)

    /// A certificate path that does not exist fails at `pjsua_transport_create()`.
    ///
    /// `pj_ssl_cert_load_from_files2()` does no I/O — it is `pj_strdup` of the paths — so
    /// this failure comes from the backend's eager import at listener start, which is
    /// exactly the behaviour #5216 settled on. A regression would show up as this test
    /// passing a bad certificate through to a listener that reports ready.
    func testMissingCertificateFailsAtTransportCreate() throws {
        try withPJSUA {
            let created = createTLSTransport(certFile: TLSFixture.missing)
            XCTAssertTrue(created.status.isError,
                          "a nonexistent certificate must fail transport creation, not the "
                          + "first connection — pjproject#5216")
        }
    }

    /// A file that is not a PKCS#12 at all fails the same way.
    func testUnparsableCertificateFailsAtTransportCreate() throws {
        let certificate = try TLSFixture.path("garbage")
        try withPJSUA {
            let created = createTLSTransport(certFile: certificate)
            XCTAssertTrue(created.status.isError,
                          "an unparsable certificate must fail transport creation")
        }
    }

    // MARK: - The 8 KB ceiling (pjproject#5222)

    /// A valid but oversized (> 8 KB) PKCS#12 fails **today**, because
    /// `create_data_from_file()` truncates it.
    ///
    /// This is a detector, not a wish: when a `swift-pjsip` rebuild picks up
    /// pjproject#5222 this test starts failing, and the right response is to flip the
    /// expectation and delete this comment. Until then, chains must stay under 8 KB.
    func testOversizedPKCS12StillFailsToLoad() throws {
        let certificate = try TLSFixture.path("oversized")
        try withPJSUA {
            let created = createTLSTransport(certFile: certificate)
            XCTAssertTrue(created.status.isError,
                          "an oversized .p12 loaded — pjproject#5222 has landed in our "
                          + "binary. Flip this expectation and lift the 8 KB ceiling from "
                          + "swift-pjsip/docs/Apple-TLS-Backends.md.")
        }
    }

    // MARK: - TD-19: does a restart keep the credentials?

    /// `pjsua_transport_lis_restart()` **replaces** the listener's TLS credentials with
    /// whatever the supplied config carries — and a freshly-defaulted config carries none.
    ///
    /// The proof is the pair of statuses, not either one alone:
    ///
    /// * restarting with a credential-less config **succeeds**, quietly;
    /// * restarting with a config that names an unloadable certificate **fails**.
    ///
    /// The second is what makes the first mean something. If `cfg->tls_setting` were
    /// ignored and the listener kept its own credentials, the unloadable certificate would
    /// be ignored too and that restart would succeed as well. It does not — so the config
    /// is what the listener ends up with, and a default one leaves it with nothing.
    func testListenerRestartReplacesCredentialsRatherThanPreservingThem() throws {
        let certificate = try TLSFixture.path("good")
        try withPJSUA {
            let created = createTLSTransport(certFile: certificate)
            try XCTSkipIf(created.status.isError,
                          "positive control failed (\(created.status.strError())); nothing "
                          + "below would be meaningful")
            let portOnCreate = boundPort(created.id)

            // What every "just restart the listener" call site produces:
            // pjsua_transport_config_default() bzeroes the struct and then
            // pjsip_tls_setting_default() leaves every credential field empty.
            let withoutCredentials = restartTLSListener(created.id, certFile: nil)
            let portAfterRestart = boundPort(created.id)

            let withUnloadableCredentials = restartTLSListener(created.id,
                                                              certFile: TLSFixture.missing)

            XCTAssertTrue(withUnloadableCredentials.isError,
                          "restarting with an unloadable certificate succeeded, which would "
                          + "mean cfg->tls_setting is ignored — read the assertion below "
                          + "as proving nothing if you ever see this")
            XCTAssertTrue(withoutCredentials.isSuccess,
                          "restarting with a credential-less config reported "
                          + "\(withoutCredentials.strError()); TD-19 predicts it succeeds, "
                          + "which is precisely what makes the credential loss silent")
            XCTAssertNotEqual(portAfterRestart, 0,
                              "the credential-less restart reported success but left no "
                              + "listener bound (was \(portOnCreate))")
        }
    }

    /// Once a credential-carrying restart **fails**, `pjsua_transport_lis_restart()` can
    /// no longer bring the listener back — and it reports success while not doing so.
    ///
    /// This matters because "call restart, reschedule on failure" is the recovery recipe
    /// pjsua itself models in `restart_listener()` (`pjsua_core.c`) and the one TD-22 says
    /// upstream's fail-fast design assumes. A failed restart leaves `listener->ssock`
    /// NULL, and every later restart then takes `pjsip_tls_transport_restart2()`'s
    /// "no listener created, update the published address only" branch: it copies the new
    /// settings, does **not** reload the certificate, does **not** re-open the socket, and
    /// returns `PJ_SUCCESS`.
    ///
    /// The listening port is the evidence. A failed restart leaves the factory's recorded
    /// address at what was *asked* for — port 0, via `update_bound_addr()` — so a restart
    /// that really re-binds reports a real port afterwards, and one that does nothing
    /// still reports 0.
    func testRestartAfterAFailedRestartReportsSuccessWithoutRecovering() throws {
        let certificate = try TLSFixture.path("good")
        try withPJSUA {
            let created = createTLSTransport(certFile: certificate)
            try XCTSkipIf(created.status.isError,
                          "positive control failed (\(created.status.strError())); nothing "
                          + "below would be meaningful")

            let broken = restartTLSListener(created.id, certFile: TLSFixture.missing)
            try XCTSkipIf(broken.isSuccess,
                          "the restart meant to break the listener succeeded; this test has "
                          + "nothing to observe")
            XCTAssertEqual(boundPort(created.id), 0,
                           "expected the failed restart to have closed the listener and "
                           + "left the recorded bind address at port 0")

            // The prescribed recovery: the certificate is loadable again, so restart.
            let recovery = restartTLSListener(created.id, certFile: certificate)
            let portAfterRecovery = boundPort(created.id)

            XCTAssertTrue(recovery.isSuccess,
                          "expected the no-op branch to report success; it returned "
                          + "\(recovery.strError())")
            XCTAssertEqual(portAfterRecovery, 0,
                           "the listener re-bound on port \(portAfterRecovery), so a restart "
                           + "does recover from a failed one after all — this trap is gone "
                           + "and the test can go with it")
        }
    }
}

// MARK: - Harness

extension TLSTransportTests {

    /// Bring pjsua up far enough to create transports, run `body`, then tear it down.
    ///
    /// Inline on the caller's thread on purpose: `pjsua_create()` registers the *calling*
    /// thread with PJLIB and every later `pjsua_*` call must come from that same thread.
    /// Keeping a whole scenario inside one test method is what guarantees that — XCTest
    /// makes no promise that `setUp` runs on the test method's thread.
    ///
    /// Each test gets its own pjsua instance rather than sharing one, because a TLS
    /// listener that has been deliberately broken stays broken (see
    /// ``testRestartAfterAFailedRestartReportsSuccessWithoutRecovering``).
    private func withPJSUA(_ body: () throws -> Void) throws {
        try pjsua_create().throwIfFailed()
        defer { pjsua_destroy() }

        var cfg = pjsua_config()
        pjsua_config_default(&cfg)
        // Same as the engine's G1 invariant: PJSUA's worker pumps the ioqueue, which is
        // also what drains the Apple backend's Network.framework events
        // (`ssl_network_event_poll()`, called only from `ioqueue_select.c`).
        cfg.thread_cnt = 1

        var log = pjsua_logging_config()
        pjsua_logging_config_default(&log)
        // Loud on purpose: when a case here fails, the reason is in PJSIP's own log line
        // ("Failed creating identity from cert", "It has to be in DER format", …) and not
        // in the status code, which is a generic PJ_EINVAL more often than not.
        log.console_level = 4

        var media = pjsua_media_config()
        pjsua_media_config_default(&media)

        try pjsua_init(&cfg, &log, &media).throwIfFailed()
        // Deliberately no pjsua_start(): transports are created between init and start,
        // and not starting keeps the audio subsystem out of a transport test.

        try body()
    }

    /// Run `body` with a transport config carrying `certFile`, or — for `nil` — carrying
    /// no TLS credentials at all, exactly as `pjsua_transport_config_default()` leaves it.
    ///
    /// The `pj_str_t`s in `tls_setting` are non-owning views. pjsip copies them into the
    /// listener's own pool during the call, so they only have to outlive `body`.
    private func withTransportConfig(
        certFile: String?,
        password: String = TLSFixture.password,
        _ body: (inout pjsua_transport_config) -> Void
    ) {
        var cfg = pjsua_transport_config()
        pjsua_transport_config_default(&cfg)
        // Ephemeral, so these tests never fight each other or the machine over 5061 —
        // and so that "did the listener really re-bind?" becomes observable, since a
        // successful restart takes a fresh port that pjsua_transport_get_info() reports.
        cfg.port = 0

        guard let certFile else {
            body(&cfg)
            return
        }
        certFile.withPJStr { cert in
            password.withPJStr { secret in
                cfg.tls_setting.cert_file = cert
                cfg.tls_setting.password = secret
                body(&cfg)
            }
        }
    }

    private func createTLSTransport(
        certFile: String?,
        password: String = TLSFixture.password
    ) -> (status: pj_status_t, id: pjsua_transport_id) {
        var id: pjsua_transport_id = -1 // PJSUA_INVALID_ID
        var status: pj_status_t = -1
        withTransportConfig(certFile: certFile, password: password) { cfg in
            status = pjsua_transport_create(PJSIP_TRANSPORT_TLS, &cfg, &id)
        }
        return (status, id)
    }

    private func restartTLSListener(
        _ id: pjsua_transport_id,
        certFile: String?,
        password: String = TLSFixture.password
    ) -> pj_status_t {
        var status: pj_status_t = -1
        withTransportConfig(certFile: certFile, password: password) { cfg in
            status = pjsua_transport_lis_restart(id, &cfg)
        }
        return status
    }

    /// The port pjsua reports the listener bound to, or `0` if it cannot say.
    ///
    /// Note this reads the *factory's* recorded address, which is only rewritten by a
    /// successful listener start — so it answers "did a restart re-bind?" and not "is the
    /// listener up right now?".
    private func boundPort(_ id: pjsua_transport_id) -> UInt16 {
        var info = pjsua_transport_info()
        guard pjsua_transport_get_info(id, &info).isSuccess else { return 0 }
        return withUnsafePointer(to: &info.local_addr) { pj_sockaddr_get_port($0) }
    }
}

/// The committed certificate fixtures. `Fixtures/make-certificates.sh` regenerates them
/// and documents what each one is for.
private enum TLSFixture {
    static let password = "secret"

    /// A path that certainly holds no certificate.
    static let missing = "/nonexistent/swift-pjsua/absent.p12"

    static func path(_ name: String) throws -> String {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "p12", subdirectory: "Fixtures"),
            "\(name).p12 is missing from the test bundle — check the target's resources"
        )
        return url.path
    }
}
