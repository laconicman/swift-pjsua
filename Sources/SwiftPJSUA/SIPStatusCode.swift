import PJSIP

/// Common SIP response-status codes, bridged from PJSIP's `pjsip_status_code` C enum.
///
/// Re-exported as `Int32` so Kit and app layers can reference SIP codes without importing
/// the C module directly. Pass `UInt32(code)` to engine methods like
/// ``PJSUA/hangup(_:statusCode:)`` and ``PJSUA/answer(_:statusCode:)``.
///
/// Only codes the codebase actually matches on are listed. Extend as needed — the full
/// catalogue lives in `pjsip/sip_msg.h` (`pjsip_status_code`).
///
/// - SeeAlso: [RFC 3261 §21](https://www.rfc-editor.org/rfc/rfc3261#section-21) (SIP Response Codes).
public enum SIPStatusCode {
    // 2xx — Success
    public static let ok                      = Int32(PJSIP_SC_OK.rawValue)                      // 200

    // 4xx — Client Failure
    public static let temporarilyUnavailable  = Int32(PJSIP_SC_TEMPORARILY_UNAVAILABLE.rawValue)  // 480
    public static let busyHere                = Int32(PJSIP_SC_BUSY_HERE.rawValue)                // 486
    public static let requestTerminated       = Int32(PJSIP_SC_REQUEST_TERMINATED.rawValue)       // 487

    // 6xx — Global Failure
    public static let busyEverywhere          = Int32(PJSIP_SC_BUSY_EVERYWHERE.rawValue)          // 600
    public static let decline                 = Int32(PJSIP_SC_DECLINE.rawValue)                  // 603
}
