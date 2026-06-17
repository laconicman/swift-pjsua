import PJSIP

/// One media stream of a call, mirrored from `pjsua_call_media_info`.
///
/// A SIP call can negotiate several media streams (audio + video, multiple of each), and
/// each stream has an independent status/direction. The engine therefore surfaces the full
/// per-stream vector on every `on_call_media_state` rather than a single aggregate status —
/// mirroring PJSUA2, which hands the app `CallInfo.media[]` and lets it react per stream
/// (audio → conference slot, video → window id). This is the engine↔Kit contract; reshaping
/// it later would be expensive, so it carries audio *and* video fields from the start even
/// though video wiring/rendering lands in a later iteration.
///
/// References:
/// - pjsua1 `pjsua_call_media_info` / `pjsua_call_info.media[]` (pjsua.h).
/// - PJSUA2 `onCallMediaState` iterating `CallInfo.media` — <https://docs.pjsip.org/en/latest/>.
public struct CallMediaInfo: Sendable, Equatable {

    /// The kind of media this stream carries (mirrors `pjmedia_type`).
    public enum Kind: Sendable, Equatable {
        case audio
        case video
        case application
        /// A media type newer than this enum knows about; carries the raw C value.
        case unknown(Int32)

        init(_ type: pjmedia_type) {
            switch type {
            case PJMEDIA_TYPE_AUDIO:       self = .audio
            case PJMEDIA_TYPE_VIDEO:       self = .video
            case PJMEDIA_TYPE_APPLICATION: self = .application
            default:                       self = .unknown(Int32(type.rawValue))
            }
        }
    }

    /// Stream direction relative to the network (mirrors `pjmedia_dir`): `encoding` is
    /// outgoing/capture, `decoding` is incoming/playback.
    public enum Direction: Sendable, Equatable {
        case none
        case encoding
        case decoding
        case encodingDecoding
        /// A direction newer than this enum knows about; carries the raw C value.
        case unknown(Int32)

        init(_ dir: pjmedia_dir) {
            switch dir {
            case PJMEDIA_DIR_NONE:              self = .none
            case PJMEDIA_DIR_ENCODING:          self = .encoding
            case PJMEDIA_DIR_DECODING:          self = .decoding
            case PJMEDIA_DIR_ENCODING_DECODING: self = .encodingDecoding
            default:                            self = .unknown(Int32(dir.rawValue))
            }
        }
    }

    /// Index of this media line in the negotiated SDP.
    public var index: Int
    /// Audio / video / application.
    public var kind: Kind
    /// Active / hold / error for this stream (see ``CallMediaStatus``).
    public var status: CallMediaStatus
    /// Encoding / decoding / both for this stream.
    public var direction: Direction
    /// For audio streams: the PJMEDIA conference-bridge slot, or `nil` when the stream has
    /// no port yet. The engine bridges this slot to the sound device (slot 0); the app uses
    /// it for local mixing / conferences.
    public var audioConfSlot: Int32?
    /// For video streams: the incoming-video window id (`pjsua_vid_win_id`), or `nil` when
    /// there is no decoded video window. Pixel rendering belongs to the app.
    public var videoWindow: UInt32?
    /// For video streams: whether a capture device is bound for outgoing video.
    public var videoCapture: Bool

    public init(index: Int,
                kind: Kind,
                status: CallMediaStatus,
                direction: Direction,
                audioConfSlot: Int32? = nil,
                videoWindow: UInt32? = nil,
                videoCapture: Bool = false) {
        self.index = index
        self.kind = kind
        self.status = status
        self.direction = direction
        self.audioConfSlot = audioConfSlot
        self.videoWindow = videoWindow
        self.videoCapture = videoCapture
    }

    /// Map one C `pjsua_call_media_info` into the Swift value type. Reads POD only; safe to
    /// call from the worker-thread callback.
    init(_ media: pjsua_call_media_info) {
        self.index = Int(media.index)
        self.kind = Kind(media.type)
        self.status = CallMediaStatus(media.status)
        self.direction = Direction(media.dir)
        switch media.type {
        case PJMEDIA_TYPE_AUDIO:
            // Valid conference ports are >= 0; PJSUA_INVALID_ID == -1 means "no slot".
            let slot = media.stream.aud.conf_slot
            self.audioConfSlot = slot >= 0 ? slot : nil
            self.videoWindow = nil
            self.videoCapture = false
        case PJMEDIA_TYPE_VIDEO:
            self.audioConfSlot = nil
            // win_in is PJSUA_INVALID_ID (-1) when there is no incoming video window.
            let win = media.stream.vid.win_in
            self.videoWindow = win >= 0 ? UInt32(win) : nil
            // cap_dev == PJMEDIA_VID_INVALID_DEV (-3) means no capture device is bound;
            // the default-device sentinels (-1, -2) still count as "has capture".
            self.videoCapture = media.stream.vid.cap_dev != -3
        default:
            self.audioConfSlot = nil
            self.videoWindow = nil
            self.videoCapture = false
        }
    }
}
