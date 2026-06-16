import PJSIP

/// A PJSIP failure: the numeric `pj_status_t` plus its human-readable message.
///
/// Note on `PJ_SUCCESS`: depending on how the PJSIP headers import into Swift, the
/// success constant may surface as `PJ_SUCCESS` (a struct with `.rawValue`) or be
/// awkward to name. `PJ_SUCCESS` is *always* 0, so we compare against the literal `0`
/// and centralize that here, rather than scatter version-fragile spellings.
public struct PJSUAError: Error, CustomStringConvertible {
    public let status: pj_status_t
    public let message: String

    public init(status: pj_status_t) {
        self.status = status
        var buffer = [CChar](repeating: 0, count: 256)
        // pj_strerror writes the message into `buffer` and returns a pj_str_t into it.
        _ = pj_strerror(status, &buffer, pj_size_t(buffer.count))
        self.message = String(cString: buffer)
    }

    public var description: String { "PJSIP error \(status): \(message)" }
}

/// Throw `PJSUAError` unless `status` is success (0). Call sites read as:
/// `try check(pjsua_create())`.
@inline(__always)
func check(_ status: pj_status_t) throws {
    if status != 0 { // 0 == PJ_SUCCESS
        throw PJSUAError(status: status)
    }
}
