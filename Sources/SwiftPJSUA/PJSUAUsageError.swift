/// Errors for misuse of the engine API that are not PJSIP `pj_status_t` failures.
public enum PJSUAUsageError: Error, Equatable, CustomStringConvertible {
    /// An operation referenced an account that the engine has no record of (it was not
    /// created via ``PJSUA/addAccount(_:credentials:wait:)``,
    /// or it has since been removed).
    case unknownAccount(AccountID)

    /// A mid-call operation needed the call's conference port (e.g. mute), but the call has
    /// no media yet (`pjsua_call_get_conf_port` returned `PJSUA_INVALID_ID`). Retry once the
    /// `.callMediaState` event reports an active audio stream.
    case callHasNoMediaPort(CallID)

    /// ``PJSUA/addAccount(_:credentials:wait:)`` was called
    /// with the pjsua account table already full. The table is a fixed array sized
    /// `PJSUA_MAX_ACC` at *binary* build time (4 in the shipped `PJ_CONFIG_IPHONE` build) and
    /// overflowing it is a hard C assert — the engine guards and throws instead. Free a slot
    /// with ``PJSUA/removeAccount(_:wait:)`` or rebuild `swift-pjsip` with a larger table.
    case accountTableFull(capacity: UInt32)

    /// A media-index argument was negative. pjsua's `med_idx` is `unsigned`, so a negative
    /// `Int` can't be expressed — and converting it would trap. Valid indices come from
    /// ``CallMediaInfo/index`` (always `>= 0`). An index that is non-negative but past the
    /// call's media count is *not* this error: pjsua returns a clean `PJ_EINVAL` for it, which
    /// surfaces as a thrown `PJSUAError`.
    case invalidMediaIndex(Int)

    /// The ``AccountID`` still exists, but it now belongs to a *different* account: the original
    /// was removed and a new one was added while an operation was suspended, and pjsua recycled
    /// the id. The operation was abandoned rather than applied to the wrong account. Re-read the
    /// current account list and retry against the right id.
    case accountReplaced(AccountID)

    /// Two ``TransportConfiguration`` entries shared a name, so an account could not
    /// unambiguously pin one of them.
    case duplicateTransportName(String)

    /// A scratch `pj_pool_t` could not be allocated (`pjsua_pool_create` returned `nil`),
    /// so an operation needing one — such as reading an account's live config back before
    /// modifying it — could not proceed. Distinct from ``unknownAccount``: the account is
    /// fine, the engine is out of memory or not initialised. Typically transient; retry.
    case poolAllocationFailed

    /// An ``AccountConfiguration/transportName`` referenced a transport that
    /// ``PJSUA/Configuration/transports`` never declared, so there is no
    /// `pjsua_transport_id` to pin the account to.
    case unknownTransport(String)

    /// ``AccountConfiguration/registrationTimeout`` was zero. A REGISTER asking for `Expires: 0`
    /// removes the binding instead of keeping it; leave the field `nil` for pjsua's default.
    case zeroRegistrationTimeout

    /// A ``PJSUA/Configuration/codecPriorities`` / `videoCodecPriorities` key matched no codec id
    /// in the binary (`pjsua_codec_set_priority` → `PJ_ENOTFOUND`). The match is a case-insensitive
    /// prefix on ids such as `opus/48000/2`; ``PJSUA/audioCodecs()`` lists what the binary offers.
    /// Thrown from ``PJSUA/start(_:)``, which fails rather than silently offering the wrong codecs.
    case unknownCodec(String)

    /// ``MediaConfiguration/clockRate`` was zero. pjsua does not substitute its default for 0; it
    /// would size the conference bridge's frames at zero samples.
    case zeroClockRate

    public var description: String {
        switch self {
        case .unknownAccount(let account):
            "PJSUAUsageError.unknownAccount(\(account))"
        case .callHasNoMediaPort(let call):
            "PJSUAUsageError.callHasNoMediaPort(\(call))"
        case .accountTableFull(let capacity):
            "PJSUAUsageError.accountTableFull(capacity: \(capacity))"
        case .invalidMediaIndex(let index):
            "PJSUAUsageError.invalidMediaIndex(\(index))"
        case .accountReplaced(let account):
            "PJSUAUsageError.accountReplaced(\(account))"
        case .duplicateTransportName(let name):
            "PJSUAUsageError.duplicateTransportName(\(name))"
        case .poolAllocationFailed:
            "PJSUAUsageError.poolAllocationFailed"
        case .unknownTransport(let name):
            "PJSUAUsageError.unknownTransport(\(name))"
        case .zeroRegistrationTimeout:
            "PJSUAUsageError.zeroRegistrationTimeout"
        case .unknownCodec(let id):
            "PJSUAUsageError.unknownCodec(\(id))"
        case .zeroClockRate:
            "PJSUAUsageError.zeroClockRate"
        }
    }
}
