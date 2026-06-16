import Foundation
import PJSIP

/// An error originating from a PJSIP / pjsua1 C call.
///
/// Wraps the `pj_status_t` returned by the C API together with the human-readable
/// message PJLIB resolves for it via `pj_strerror`.
public struct PJSUAError: Error, Equatable, CustomStringConvertible {
    /// The raw `pj_status_t` status code returned by the failing C call.
    public let status: pj_status_t
    /// The message PJLIB associates with `status`.
    public let message: String

    public init(status: pj_status_t) {
        self.status = status
        self.message = PJSUAError.describe(status)
    }

    public var description: String { "PJSUAError(\(status): \(message))" }

    /// Resolve the PJLIB error string for a status code.
    private static func describe(_ status: pj_status_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        let result = pj_strerror(status, &buffer, buffer.count)
        // `pj_strerror` returns a pj_str_t pointing into `buffer`; copy it out before
        // the buffer goes out of scope.
        guard result.ptr != nil, result.slen > 0 else {
            return "Unknown PJSIP error \(status)"
        }
        return String(cString: buffer)
    }
}
