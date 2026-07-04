import PJSIP

extension PJSUA {
    // MARK: Call statistics

    /// A statistics snapshot for one media stream of `call` — codec plus cumulative RTP/RTCP
    /// counters (packets, loss, jitter, RTT). See ``CallStreamStatistics``.
    ///
    /// `mediaIndex` is the media-line index as carried on ``CallMediaInfo/index`` (default 0 —
    /// the audio line of a plain call; pass the video stream's index for video stats). Throws
    /// when the stream at that index has no active session (e.g. before media is up, or after
    /// disconnect) — wraps `pjsua_call_get_stream_info` + `pjsua_call_get_stream_stat`.
    public func statistics(for call: CallID, mediaIndex: Int = 0) throws -> CallStreamStatistics {
        var info = pjsua_stream_info()
        try pjsua_call_get_stream_info(call.raw, UInt32(mediaIndex), &info).throwIfFailed()
        var stat = pjsua_stream_stat()
        try pjsua_call_get_stream_stat(call.raw, UInt32(mediaIndex), &stat).throwIfFailed()

        // `info.info` is the aud/vid/txt union — read only the arm `info.type` selects.
        let codec: CallStreamStatistics.Codec
        switch info.type {
        case PJMEDIA_TYPE_AUDIO:
            let fmt = info.info.aud.fmt
            codec = .init(name: fmt.encoding_name.string ?? "?",
                          clockRate: fmt.clock_rate,
                          channels: fmt.channel_cnt,
                          payloadType: fmt.pt)
        case PJMEDIA_TYPE_VIDEO:
            let vid = info.info.vid.codec_info
            codec = .init(name: vid.encoding_name.string ?? "?",
                          clockRate: vid.clock_rate,
                          channels: 1,
                          payloadType: vid.pt)
        default:
            codec = .init(name: "?", clockRate: 0, channels: 0, payloadType: 0)
        }

        return CallStreamStatistics(kind: .init(info.type),
                                    codec: codec,
                                    transmit: .init(stat.rtcp.tx),
                                    receive: .init(stat.rtcp.rx),
                                    roundTrip: .init(usec: stat.rtcp.rtt))
    }
}
