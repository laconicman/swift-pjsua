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
        self.message = status.strError()
    }

    public var description: String { "PJSUAError(\(status): \(message))" }
}
