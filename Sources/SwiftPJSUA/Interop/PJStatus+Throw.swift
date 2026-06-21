import PJSIP

// `pj_status_t` is `typedef int`, i.e. `Int32` in Swift. These conveniences are kept
// `internal` so the package does not add surface area to every `Int32` for consumers.
extension pj_status_t {
    /// `true` when the status represents success (`PJ_SUCCESS`, which is `0`).
    var isSuccess: Bool { self == 0 }

    /// `true` when the status represents a failure (any non-zero `pj_status_t`).
    var isError: Bool { !isSuccess }

    /// The human-readable PJLIB error string, or `nil` on success.
    var error: String? { isSuccess ? nil : strError() }

    /// Resolve the PJLIB error string for this status code via `pj_strerror`.
    ///
    /// Uses `PJ_ERR_MSG_SIZE` (80, defined in `pj/errno.h`) as the buffer capacity —
    /// the canonical size used throughout PJSIP. Messages that exceed the buffer are
    /// truncated (harmless for diagnostics).
    func strError() -> String {
        var buffer = [CChar](repeating: 0, count: Int(PJ_ERR_MSG_SIZE))
        let result = pj_strerror(self, &buffer, pj_size_t(buffer.count))
        return result.string ?? "Unknown PJSIP error \(self)"
    }

    /// Throw a ``PJSUAError`` if this status does not represent success.
    ///
    /// Lets call sites read top-to-bottom: `try pjsua_create().throwIfFailed()`.
    @discardableResult
    func throwIfFailed() throws -> pj_status_t {
        guard isSuccess else { throw PJSUAError(status: self) }
        return self
    }
}
