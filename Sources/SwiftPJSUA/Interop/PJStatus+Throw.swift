import PJSIP

// `pj_status_t` is `typedef int`, i.e. `Int32` in Swift. These conveniences are kept
// `internal` so the package does not add surface area to every `Int32` for consumers.
extension pj_status_t {
    /// `true` when the status represents success (`PJ_SUCCESS`, which is `0`).
    var isSuccess: Bool { self == 0 }

    /// Throw a ``PJSUAError`` if this status does not represent success.
    ///
    /// Lets call sites read top-to-bottom: `try pjsua_create().throwIfFailed()`.
    @discardableResult
    func throwIfFailed() throws -> pj_status_t {
        guard isSuccess else { throw PJSUAError(status: self) }
        return self
    }
}
