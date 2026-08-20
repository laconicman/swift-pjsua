import PJSIP

/// A `pjmedia_event` forwarded to the application through pjsua's `on_call_media_event`.
///
/// **pjsua takes no action on these.** `call_media_on_event()` handles exactly three event types
/// (video keyframe requests, video format changes, and logging a video device error) and lets
/// everything else — `PJMEDIA_EVENT_MEDIA_TP_ERR` included — fall through `default: break` before
/// forwarding the event verbatim. The call is not disturbed: no state change, no SIP signalling,
/// no teardown. The application is the only party that can react. See
/// `docs/Call-Termination-Paths.md` §3.
///
/// Only the two members an application can act on today are named; everything else is carried as
/// its raw FOURCC so the surface makes no claims about events we have not studied.
public enum CallMediaEvent: Sendable, Equatable {

    /// `PJMEDIA_EVENT_MEDIA_TP_ERR` — the media transport failed. `status` is the `pj_status_t`
    /// it failed with, `isRTP` distinguishes the RTP socket from the RTCP one.
    ///
    /// The call stays confirmed with dead media, which is the single most dangerous entry in the
    /// termination taxonomy: nothing else will ever mention it.
    case mediaTransportError(status: Int32, isRTP: Bool)

    /// `PJMEDIA_EVENT_AUD_DEV_ERROR` — the audio device failed mid-call.
    case audioDeviceError(status: Int32)

    /// Any other `pjmedia_event_type`, rendered as its FOURCC (`"FMCH"`, `"IFRM"`, `"RTFB"`…).
    case other(fourCC: String)
}

extension CallMediaEvent {
    /// Reads the union arm that `event.type` selects. POD reads only — safe on the timer thread
    /// that delivers these (`pjsua_schedule_timer2(&call_med_event_cb, eve, 1)`).
    init(_ event: pjmedia_event) {
        switch event.type {
        case PJMEDIA_EVENT_MEDIA_TP_ERR:
            self = .mediaTransportError(status: event.data.med_tp_err.status,
                                        isRTP: event.data.med_tp_err.is_rtp.bool)
        case PJMEDIA_EVENT_AUD_DEV_ERROR:
            self = .audioDeviceError(status: event.data.aud_dev_err.status)
        default:
            self = .other(fourCC: Self.fourCC(event.type.rawValue))
        }
    }

    /// `PJMEDIA_FOURCC(C1,C2,C3,C4)` packs the characters little-endian
    /// (`C4<<24 | C3<<16 | C2<<8 | C1`, `pjmedia/types.h:299`), so C1 is the low byte.
    private static func fourCC(_ raw: UInt32) -> String {
        let bytes = (0..<4).map { UInt8((raw >> ($0 * 8)) & 0xFF) }
        guard bytes.allSatisfy({ (0x20...0x7E).contains($0) }) else { return "0x\(String(raw, radix: 16))" }
        return String(decoding: bytes, as: UTF8.self)
    }
}
