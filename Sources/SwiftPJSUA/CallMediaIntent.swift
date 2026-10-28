/// What the user wants from a call's media, independent of what SDP currently says.
///
/// The engine keeps this because pjsua's media state alone cannot express it: every
/// direction change — local hold, local unhold, remote hold, remote resume, codec
/// re-INVITE, IP-change re-INVITE — makes `is_media_changed()` (pjsua_media.c) return
/// true, which tears down and rebuilds the audio *and* video streams. The audio conf
/// slot is destroyed and reallocated; the video capture window is released; and
/// `pjsua_vid_channel_update()` (pjsua_vid.c) starts the rebuilt video stream paused in
/// the encoding direction, setting capture up only `if (!call->local_hold &&
/// acc->cfg.vid_out_auto_transmit)` — a flag the engine deliberately keeps `PJ_FALSE`
/// (the pjsua default) and does not expose. So after *every* rebuild the camera is off
/// until something issues `PJSUA_CALL_VID_STRM_START_TRANSMIT`, and after every rebuild
/// the mic bridge would default to connected. The user's choice must live somewhere the
/// rebuild cannot reset: here.
///
/// It lives in the engine, not in a Kit, because mute and hold are *system* actions —
/// CallKit's `CXSetMutedCallAction`/`CXSetHeldCallAction` and LiveCommunicationKit's
/// `MuteConversationAction` both reach the engine while the app may not be running its
/// own in-call UI — and neither kit carries a per-call "send camera" flag, so the
/// camera half of the intent is Kit-agnostic state only the engine can hold.
///
/// One more reason it cannot be derived from pjsua status: a sendonly video stream is
/// reported as `PJSUA_CALL_MEDIA_LOCAL_HOLD` (pjsua_media.c), so "camera on" ≠
/// "media active" — the intent has to be tracked separately.
///
/// Stored per call (keyed by `pjsua_call_id`) in `PJSUACallbacks.swift`, guarded by
/// `mediaIntentLock`: the worker-thread callbacks read it while applying the media
/// state synchronously (fail-closed), and the actor writes it from its own methods.
/// The entry is cleared on `.disconnected` — pjsua recycles call ids, and a recycled
/// id must start with the default intent.
public struct CallMediaIntent: Sendable, Equatable {
    /// `setMute` — the capture→call conference link (slot 0 → the call's port) stays
    /// disconnected while `true`, including across hold/resume. Applied synchronously
    /// in `on_call_media_state` so a muted call never comes up with a live mic.
    public var microphoneMuted = false

    /// `setCameraEnabled` — the user wants local video transmitted on this call.
    /// Re-applied as `PJSUA_CALL_VID_STRM_START_TRANSMIT` after every media rebuild
    /// (hold/unhold/re-INVITE) by the engine itself; the app does not re-issue it.
    /// While the call is on local hold it is applied nowhere — the audio stream's
    /// `.localHold` status is the engine's proxy for pjsua's own `!call->local_hold`
    /// guard (`pjsua_vid_channel_update`, pjsua_vid.c), which `pjsua_call_info` does
    /// not expose.
    public var cameraEnabled = false

    /// Policy for the *remote's* video offers: the initial `answer` and every incoming
    /// re-INVITE/UPDATE offer (`on_call_rx_offer`). `false` answers the video m-line
    /// with port 0 (`opt.vid_cnt = 0`) while audio stays — a decline, not a 488.
    /// Offering video ourselves (`makeCall(video:)`, `addVideoStream`,
    /// `setVideoDirection` ≠ `.none`) sets it `true`: refusing the answer-side
    /// re-offers of a line we put up would be incoherent.
    public var acceptsVideo = true

    public init(microphoneMuted: Bool = false,
                cameraEnabled: Bool = false,
                acceptsVideo: Bool = true) {
        self.microphoneMuted = microphoneMuted
        self.cameraEnabled = cameraEnabled
        self.acceptsVideo = acceptsVideo
    }
}
