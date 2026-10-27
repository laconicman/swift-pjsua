/// One codec the engine's binary offers, as pjsua reports it. See ``PJSUA/audioCodecs()``.
public struct CodecInfo: Sendable, Equatable, Hashable {
    /// pjsua's codec id — `encoding/clockRate/channels`, e.g. `opus/48000/2`, `PCMU/8000/1`.
    /// This is the string ``PJSUA/Configuration/codecPriorities`` keys are prefix-matched against.
    public let id: String
    /// 0 = disabled (listed, never offered) … 255. pjsua stores a requested 255 as 254 once sorted.
    public let priority: UInt8
    /// pjsua's description. Empty for audio codecs (pjsua does not fill it); set for video codecs.
    public let description: String

    public init(id: String, priority: UInt8, description: String) {
        self.id = id
        self.priority = priority
        self.description = description
    }
}
