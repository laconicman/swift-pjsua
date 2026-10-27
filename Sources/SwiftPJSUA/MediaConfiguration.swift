/// → `pjsua_media_config`: the global media defaults, fixed at ``PJSUA/start(_:)``.
///
/// Hand-written `init(from:)` for the same reason as ``PJSUA/Configuration``: the synthesised
/// one ignores property defaults, so a document omitting a key would fail to decode.
public struct MediaConfiguration: Sendable, Codable, Equatable {
    /// Conference-bridge clock rate in Hz → `pjsua_media_config.clock_rate`. Also the rate the
    /// null sound device runs at. pjsua's default is 16000; `opus/48000/2` is fixed at 48 kHz by
    /// RFC 7587, so with the default every Opus frame is resampled in both directions — a consumer
    /// that prefers Opus sets 48000. Must be non-zero: pjsua does not substitute its default for 0
    /// (``PJSUAUsageError/zeroClockRate``).
    public var clockRate: UInt32 = 16000

    /// Clock rate the *real* sound device is opened at → `pjsua_media_config.snd_clock_rate`.
    /// 0 (pjsua's own convention, and its default) follows ``clockRate``. Irrelevant to the null
    /// sound device.
    public var soundDeviceClockRate: UInt32 = 0

    public init() {}

    private enum CodingKeys: String, CodingKey {
        case clockRate, soundDeviceClockRate
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clockRate = try container.decodeIfPresent(UInt32.self, forKey: .clockRate) ?? 16000
        soundDeviceClockRate = try container.decodeIfPresent(UInt32.self,
                                                             forKey: .soundDeviceClockRate) ?? 0
    }
}
