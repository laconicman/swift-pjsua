import PJSIP

/// A point-in-time RTP/RTCP statistics snapshot for one media stream of a call, mirrored from
/// `pjsua_stream_info` + `pjsua_stream_stat` so callers don't touch the C unions.
///
/// Read it via ``PJSUA/statistics(for:mediaIndex:)`` while the stream is active — e.g. to show
/// in-call quality (codec, packet loss, jitter, RTT) or to assert media actually flowed in
/// integration tests. Counters are cumulative for the stream's lifetime; RTCP-derived fields
/// (``receive`` loss reported by the peer, ``roundTrip``) stay zero until the first RTCP
/// round-trip completes.
///
/// References:
/// - pjsua1 `pjsua_call_get_stream_info` / `pjsua_call_get_stream_stat` (pjsua.h).
/// - `pjmedia_rtcp_stat` / `pjmedia_rtcp_stream_stat` (pjmedia/rtcp.h).
public struct CallStreamStatistics: Sendable, Equatable {

    /// The negotiated codec of the stream (mirrors `pjmedia_codec_info` for audio,
    /// `pjmedia_vid_codec_info` for video).
    public struct Codec: Sendable, Equatable, CustomStringConvertible {
        /// IANA encoding name, e.g. `"PCMU"`, `"G722"`, `"H264"`.
        public var name: String
        /// RTP clock rate in Hz (8000 for G.711; 90000 for video).
        public var clockRate: UInt32
        /// Channel count (audio; reported as 1 for video).
        public var channels: UInt32
        /// RTP payload type (static or dynamic).
        public var payloadType: UInt32
        /// The SDP `a=rtpmap` spelling, e.g. `"PCMU/8000"`.
        public var description: String { "\(name)/\(clockRate)" }
    }

    /// A distribution summary mirrored from `pj_math_stat`. PJSIP keeps these in microseconds;
    /// they are converted to **milliseconds** here.
    public struct Distribution: Sendable, Equatable {
        /// Number of samples aggregated (0 = no data yet).
        public var samples: Int32
        public var minMs: Double
        public var maxMs: Double
        public var lastMs: Double
        public var meanMs: Double

        init(usec stat: pj_math_stat) {
            self.samples = stat.n
            self.minMs = Double(stat.min) / 1000
            self.maxMs = Double(stat.max) / 1000
            self.lastMs = Double(stat.last) / 1000
            self.meanMs = Double(stat.mean) / 1000
        }
    }

    /// One direction's cumulative counters, mirrored from `pjmedia_rtcp_stream_stat`.
    public struct DirectionStats: Sendable, Equatable {
        /// Total RTP packets.
        public var packets: UInt32
        /// Total payload bytes.
        public var bytes: UInt32
        /// Packets discarded (e.g. jitter-buffer overflow).
        public var discarded: UInt32
        /// Packets lost.
        public var lost: UInt32
        /// Out-of-order packets.
        public var reordered: UInt32
        /// Duplicate packets.
        public var duplicated: UInt32
        /// Interarrival-jitter distribution (ms).
        public var jitter: Distribution

        init(_ stat: pjmedia_rtcp_stream_stat) {
            self.packets = stat.pkt
            self.bytes = stat.bytes
            self.discarded = stat.discard
            self.lost = stat.loss
            self.reordered = stat.reorder
            self.duplicated = stat.dup
            self.jitter = Distribution(usec: stat.jitter)
        }
    }

    /// Audio / video (matches the stream's ``CallMediaInfo/kind``).
    public var kind: CallMediaInfo.Kind
    /// The negotiated codec.
    public var codec: Codec
    /// Encoder direction (what we sent).
    public var transmit: DirectionStats
    /// Decoder direction (what we received).
    public var receive: DirectionStats
    /// Round-trip-time distribution (ms) from RTCP; ``Distribution/samples`` is 0 until the
    /// first RTCP report round-trip.
    public var roundTrip: Distribution
}
