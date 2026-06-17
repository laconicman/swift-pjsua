import PJSIP

extension PJSUA {
    // MARK: Video stream operations
    //
    // Thin wrappers over `pjsua_call_set_vid_strm`, the single pjsua1 entry point for
    // per-call video stream control. Each op is initialised from
    // `pjsua_call_vid_strm_op_param_default` (which sets `med_idx = -1` = first/default video
    // stream, `dir = ENCODING_DECODING`, `cap_dev = PJMEDIA_VID_DEFAULT_CAPTURE_DEV`) and then
    // tweaked. ADD/REMOVE/CHANGE_DIR re-INVITE the peer; START/STOP_TRANSMIT,
    // CHANGE_CAP_DEV and SEND_KEYFRAME are local-only (no signalling).
    //
    // The engine shapes the full video *surface* (D-VIDEO sign-off); actual pixel rendering
    // (MetalKit / `UIView`) is the Offhook app's job. The package already links CoreVideo /
    // VideoToolbox / MetalKit for that consumer.
    //
    // References:
    // - pjsua1 `pjsua_call_set_vid_strm` / `pjsua_call_vid_strm_op` / `..._op_param` (pjsua.h).
    // - pjsua1 video window + video conference bridge APIs (pjsua.h).
    // - PJSUA2 video call handling — <https://docs.pjsip.org/en/latest/>.

    /// Add a new video stream (a new `m=video` line) to the call, re-INVITE-ing the peer. Used
    /// to upgrade an audio call to video. `captureDevice` is a `pjmedia_vid_dev_index`; `-1`
    /// (the default) is `PJMEDIA_VID_DEFAULT_CAPTURE_DEV` — the account's configured camera.
    public func addVideoStream(to call: CallID, captureDevice: Int32 = -1) throws {
        try setVideoStream(call, PJSUA_CALL_VID_STRM_ADD) { $0.cap_dev = captureDevice }
    }

    /// Remove / disable an existing video stream, re-INVITE-ing the peer (downgrade to audio).
    /// `streamIndex` selects the `m=video` line; `-1` is the default/first video stream.
    public func removeVideoStream(from call: CallID, streamIndex: Int32 = -1) throws {
        try setVideoStream(call, PJSUA_CALL_VID_STRM_REMOVE) { $0.med_idx = streamIndex }
    }

    /// Resume transmitting local video on an existing stream (local-only; no re-INVITE).
    public func startVideoTransmission(_ call: CallID, streamIndex: Int32 = -1) throws {
        try setVideoStream(call, PJSUA_CALL_VID_STRM_START_TRANSMIT) { $0.med_idx = streamIndex }
    }

    /// Pause transmitting local video on an existing stream — stops sending packets while
    /// keeping the stream negotiated (local-only; no re-INVITE).
    public func stopVideoTransmission(_ call: CallID, streamIndex: Int32 = -1) throws {
        try setVideoStream(call, PJSUA_CALL_VID_STRM_STOP_TRANSMIT) { $0.med_idx = streamIndex }
    }

    /// Switch the capture device (camera) feeding a video stream — e.g. front ↔ back camera
    /// (local-only; no re-INVITE). `device` is a `pjmedia_vid_dev_index`.
    public func changeVideoCaptureDevice(_ call: CallID, to device: Int32, streamIndex: Int32 = -1) throws {
        try setVideoStream(call, PJSUA_CALL_VID_STRM_CHANGE_CAP_DEV) {
            $0.med_idx = streamIndex
            $0.cap_dev = device
        }
    }

    /// Force the stream to emit a video keyframe as soon as possible (local-only). Useful when
    /// a new viewer joins or after packet loss.
    public func sendVideoKeyframe(_ call: CallID, streamIndex: Int32 = -1) throws {
        try setVideoStream(call, PJSUA_CALL_VID_STRM_SEND_KEYFRAME) { $0.med_idx = streamIndex }
    }

    /// Shared body: default-init the op param, let the caller tweak it, then apply the op.
    private func setVideoStream(_ call: CallID,
                                _ op: pjsua_call_vid_strm_op,
                                configure: (inout pjsua_call_vid_strm_op_param) -> Void) throws {
        var param = pjsua_call_vid_strm_op_param()
        pjsua_call_vid_strm_op_param_default(&param)
        configure(&param)
        try pjsua_call_set_vid_strm(call.raw, op, &param).throwIfFailed()
    }

    // MARK: Video windows
    //
    // Each decoded (incoming) video stream renders into a window (`pjsua_vid_win_id`), surfaced
    // on ``CallMediaInfo/videoWindow``. The app reads ``videoWindowInfo(_:)`` to lay out and
    // attaches its own view for rendering; the engine only toggles visibility.

    /// Show or hide a video window. Invalid for native windows
    /// (``VideoWindowInfo/isNative`` — use the platform's native windowing API for those).
    public func showVideoWindow(_ window: UInt32, _ show: Bool) throws {
        try pjsua_vid_win_set_show(pjsua_vid_win_id(window), pj_bool_t(show)).throwIfFailed()
    }

    /// A snapshot of a video window (geometry, show state, renderer slot), or `nil` if the id is
    /// unknown. See ``VideoWindowInfo``.
    public func videoWindowInfo(_ window: UInt32) -> VideoWindowInfo? {
        var info = pjsua_vid_win_info()
        guard pjsua_vid_win_get_info(pjsua_vid_win_id(window), &info).isSuccess else { return nil }
        return VideoWindowInfo(info)
    }

    // MARK: Video conference bridge
    //
    // Video has its own conference bridge, parallel to the audio bridge. A call's encode
    // (capture→net) and decode (net→render) ports are addressable as conference slots; the app
    // composes layouts by connecting sources to sinks. These primitives mirror the audio ones
    // in `PJSUA+Conference.swift`; topology/layout choices belong to the GUI layer.

    /// A call's slot in the **video** conference bridge for the given direction
    /// (`pjsua_call_get_vid_conf_port`), or `nil` when the video media is not established/active.
    /// `sending == true` queries the encode (capture→network) port; `false` the decode
    /// (network→render) port. Only these two directions are valid.
    public func videoConferenceSlot(of call: CallID, sending: Bool) -> Int32? {
        let dir = sending ? PJMEDIA_DIR_ENCODING : PJMEDIA_DIR_DECODING
        let slot = pjsua_call_get_vid_conf_port(call.raw, dir)
        return slot >= 0 ? slot : nil // PJSUA_INVALID_ID == -1
    }

    /// Connect a video source slot to a sink slot in the video conference bridge, directionally
    /// (`pjsua_vid_conf_connect`).
    public func connectVideo(from source: Int32, to sink: Int32) throws {
        try pjsua_vid_conf_connect(source, sink, nil).throwIfFailed()
    }

    /// Disconnect a directional video conference link made with ``connectVideo(from:to:)``.
    public func disconnectVideo(from source: Int32, to sink: Int32) throws {
        try pjsua_vid_conf_disconnect(source, sink).throwIfFailed()
    }
}
