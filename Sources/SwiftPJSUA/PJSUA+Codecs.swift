import PJSIP

extension PJSUA {
    // MARK: Codec enumeration and priorities

    /// The audio codecs the binary offers, in the order the engine will list them in an SDP offer
    /// (priority-sorted; disabled ones, priority 0, at the tail and never offered). Valid once
    /// ``start(_:)`` has completed. Wraps `pjsua_enum_codecs`.
    public func audioCodecs() throws -> [CodecInfo] {
        precondition(state == .running, "start() must complete before audioCodecs()")
        return try enumCodecs(using: pjsua_enum_codecs)
    }

    /// Video twin of ``audioCodecs()`` — the video codecs the binary offers, in SDP offer order.
    /// pjsua keeps video codecs in their own codec manager, a separate namespace from the audio
    /// ids (`H264` and `opus/48000/2` never collide). Valid once ``start(_:)`` has completed.
    /// Wraps `pjsua_vid_enum_codecs`.
    public func videoCodecs() throws -> [CodecInfo] {
        precondition(state == .running, "start() must complete before videoCodecs()")
        return try enumCodecs(using: pjsua_vid_enum_codecs)
    }

    /// Re-prioritise audio codecs on a running engine — the keys and semantics of
    /// ``Configuration/codecPriorities`` (prefix match, 0 disables, ascending key order,
    /// ``PJSUAUsageError/unknownCodec(_:)`` for a key that matches nothing). Takes effect from the
    /// next offer or answer on; calls in progress keep their codec until they renegotiate. pjsua
    /// keeps one codec manager, so this is global, never per account or per call. On a failure,
    /// keys before the failing one stay applied.
    public func setCodecPriorities(_ priorities: [String: UInt8]) throws {
        precondition(state == .running, "start() must complete before setCodecPriorities()")
        try applyCodecPriorities(priorities, using: pjsua_codec_set_priority)
    }

    /// Video twin of ``setCodecPriorities(_:)`` — `pjsua_vid_codec_set_priority`.
    public func setVideoCodecPriorities(_ priorities: [String: UInt8]) throws {
        precondition(state == .running, "start() must complete before setVideoCodecPriorities()")
        try applyCodecPriorities(priorities, using: pjsua_vid_codec_set_priority)
    }

    /// Runs one of pjsua's codec enumerators over a fixed array and copies the strings out.
    ///
    /// pjsua caps the enumeration at 32 entries, and each returned `pjsua_codec_info`'s
    /// `codec_id`/`desc` point into that element's own `buf_` — so the `String`s are made while
    /// the array's buffer is alive, never from a copied element.
    private func enumCodecs(
        using enumerate: (UnsafeMutablePointer<pjsua_codec_info>,
                          UnsafeMutablePointer<UInt32>) -> pj_status_t
    ) throws -> [CodecInfo] {
        var infos = [pjsua_codec_info](repeating: .init(), count: 32)
        var count = UInt32(infos.count)
        return try infos.withUnsafeMutableBufferPointer { buffer in
            try enumerate(buffer.baseAddress!, &count).throwIfFailed()
            return (0..<Int(count)).map {
                CodecInfo(id: buffer[$0].codec_id.string ?? "",
                          priority: buffer[$0].priority,
                          description: buffer[$0].desc.string ?? "")
            }
        }
    }

    /// Applies `priorities` in ascending key order through `set`; an id that matches nothing throws
    /// ``PJSUAUsageError/unknownCodec(_:)``.
    ///
    /// The sort makes application order deterministic — two configurations differing only in
    /// dictionary order produce the same offer. pjsua keeps only the most recently assigned
    /// top priority, so with several keys at 255 the lexicographically greatest key wins.
    func applyCodecPriorities(_ priorities: [String: UInt8],
                              using set: (UnsafePointer<pj_str_t>, UInt8) -> pj_status_t) throws {
        for id in priorities.keys.sorted() {
            let status = id.withPJStr { set(&$0, priorities[id]!) }
            if status == PJ_ENOTFOUND {
                throw PJSUAUsageError.unknownCodec(id)
            }
            try status.throwIfFailed()
        }
    }
}
