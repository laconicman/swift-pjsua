import PJSIP

extension String {
    /// Run `body` with a `pj_str_t` that borrows this string's UTF-8 bytes.
    ///
    /// The `pj_str_t` (and the bytes it points at) are valid **only** for the duration of
    /// `body`. Use this for transient, read-only arguments to C calls — e.g. a SIP URI
    /// passed to `pjsua_call_make_call`. Do not let the `pj_str_t` escape the closure; for
    /// values PJSIP must retain, copy into an owned buffer (see ``PJString``).
    func withPJStr<T>(_ body: (inout pj_str_t) throws -> T) rethrows -> T {
        try withCString { cString in
            var pjStr = pj_str_t(
                ptr: UnsafeMutablePointer(mutating: cString),
                slen: pj_ssize_t(strlen(cString))
            )
            return try body(&pjStr)
        }
    }
}
