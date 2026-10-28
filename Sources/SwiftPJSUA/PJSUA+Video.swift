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
    // **A negotiated video stream starts paused.** `pjsua_vid_channel_update()`
    // (pjsua_vid.c) starts the rebuilt stream then pauses it in the encoding direction;
    // capture is set up only `if (!call->local_hold && acc->cfg.vid_out_auto_transmit)`.
    // The engine keeps `vid_out_auto_transmit` at its `PJ_FALSE` default and does not
    // expose it — pjsua's flag answers "when should video transmit" once, at
    // negotiate time, while ``CallMediaIntent/transmitsVideo`` answers it as a standing
    // user choice the engine re-applies after every rebuild (every direction change
    // makes `is_media_changed()` in pjsua_media.c tear down and rebuild the stream:
    // hold, unhold, remote hold, codec or IP-change re-INVITE). So the transmission API here
    // is intent-based (`setVideoTransmission`), not one-shot.
    //
    // The engine shapes the full video *surface* (D-VIDEO sign-off); actual pixel rendering
    // (MetalKit / `UIView`) is the Offhook app's job. The package already links CoreVideo /
    // VideoToolbox / MetalKit for that consumer.
    //
    // **Threading:** `darwin_stream_stop` (pjmedia-videodev/darwin_dev.m) does
    // `performSelectorOnMainThread:… waitUntilDone:YES` for `stopRunning`/`finish_render`;
    // it is reached by STOP_TRANSMIT, hangup and every hold/re-INVITE stream rebuild. The
    // engine's architecture is the structural fix — every pjsua call runs on the pinned
    // engine thread and `await` on the actor suspends without blocking the main run loop.
    // The one way to recreate the deadlock (upstream pjproject issue #4928, closed as
    // "don't block main") is a *blocking* wait on the main thread for the engine:
    // `DispatchSemaphore`, `Thread.sleep`, `DispatchQueue.main.sync` from a callback —
    // apps must never do that; the Kit never does (CallKit delegate → `Task { await … }`).
    //
    // References:
    // - pjsua1 `pjsua_call_set_vid_strm` / `pjsua_call_vid_strm_op` / `..._op_param` (pjsua.h).
    // - pjsua1 video window + video conference bridge APIs (pjsua.h).
    // - PJSUA2 video call handling — <https://docs.pjsip.org/en/latest/>.

    /// Add video to the call, re-INVITE-ing the peer. Used to upgrade an audio call to
    /// video. `captureDevice` is a `pjmedia_vid_dev_index`; `-1` (the default) is
    /// `PJMEDIA_VID_DEFAULT_CAPTURE_DEV` — the account's configured camera.
    ///
    /// When the call already carries a *disabled* video line (`status == .none` — a
    /// video offer it declined or a line `removeVideoStream` took down) this re-enables
    /// that line with `PJSUA_CALL_VID_STRM_CHANGE_DIR` (ENCODING_DECODING) on its index
    /// instead: `call_add_video` (pjsua_vid.c) always *appends* a new m-line, while
    /// `call_modify_video` is the path that turns a port-0 line back on ("Create new SDP
    /// media line if the stream is disabled"). A second appended line is not what an
    /// upgrade means.
    ///
    /// Also records ``CallMediaIntent/acceptsVideo`` `= true`: we are offering video, so
    /// refusing the peer's answer-side re-offers of that line would be incoherent.
    public func addVideoStream(to call: CallID, captureDevice: Int32 = -1) throws {
        var info = pjsua_call_info()
        if pjsua_call_get_info(call.raw, &info).isSuccess,
           let disabled = callMediaInfos(from: &info)
               .first(where: { $0.kind == .video && $0.status == .none }) {
            try setVideoStream(call, PJSUA_CALL_VID_STRM_CHANGE_DIR) {
                $0.med_idx = Int32(disabled.index)
                $0.dir = PJMEDIA_DIR_ENCODING_DECODING
            }
            // CHANGE_DIR takes no device (`call_modify_video` has no cap_dev), so the
            // requested device is applied separately on the explicit index — safe while
            // the re-INVITE is in flight because `call_change_cap_dev` only stores
            // `strm.v.cap_dev` when no capture window is up yet (`cap_win_id ==
            // PJSUA_INVALID_ID`); it takes effect when capture is set up. A pjsua error
            // here is thrown as-is — the direction change already went out.
            // We are offering video — recorded as soon as the offer is out, BEFORE the
            // device switch below: a CHANGE_CAP_DEV failure must throw but must not
            // leave the intent unset for an offer that already went out.
            updateMediaIntent(for: call.raw) { $0.acceptsVideo = true }
            if captureDevice != -1 {
                try setVideoStream(call, PJSUA_CALL_VID_STRM_CHANGE_CAP_DEV) {
                    $0.med_idx = Int32(disabled.index)
                    $0.cap_dev = captureDevice
                }
            }
        } else {
            try setVideoStream(call, PJSUA_CALL_VID_STRM_ADD) { $0.cap_dev = captureDevice }
            updateMediaIntent(for: call.raw) { $0.acceptsVideo = true }
        }
    }

    /// Remove / disable an existing video stream, re-INVITE-ing the peer (downgrade to audio).
    /// `streamIndex` selects the `m=video` line; `-1` is the default/first video stream.
    public func removeVideoStream(from call: CallID, streamIndex: Int32 = -1) throws {
        try setVideoStream(call, PJSUA_CALL_VID_STRM_REMOVE) { $0.med_idx = streamIndex }
    }

    /// Turn local video transmission on or off for this call — the "send my video" switch
    /// (local-only; no re-INVITE). Recorded as ``CallMediaIntent/transmitsVideo`` first,
    /// then applied as `PJSUA_CALL_VID_STRM_START/STOP_TRANSMIT` (`call_set_tx_video`,
    /// pjsua_vid.c — it sets capture up itself when the stream has none) when the call
    /// currently has a video stream with an encoding direction; otherwise only recorded.
    ///
    /// The engine re-applies the recorded intent after every media rebuild — a video
    /// stream comes back from hold/unhold/re-INVITE with capture released and the
    /// encoder paused (`pjsua_vid_channel_update`; the account flag
    /// `vid_out_auto_transmit` that would resume it is deliberately kept `PJ_FALSE` and
    /// not exposed — see ``CallMediaIntent``). Enabling transmission once survives the
    /// whole call; failure to resume is reported as `.videoTransmissionFailed`.
    ///
    /// Call-wide: applied to EVERY negotiated video stream with an encoding direction.
    /// Per-stream control is not a use case the engine models — one video line per call
    /// today (``addVideoStream(to:captureDevice:)`` re-enables a disabled line rather
    /// than appending).
    public func setVideoTransmission(_ call: CallID, enabled: Bool) throws {
        updateMediaIntent(for: call.raw) { $0.transmitsVideo = enabled }
        var info = pjsua_call_info()
        guard pjsua_call_get_info(call.raw, &info).isSuccess else { return }
        let media = callMediaInfos(from: &info)
        // An audio stream on local hold proxies the call-level local hold pjsua guards
        // with `!call->local_hold` (`pjsua_vid_channel_update`, not exposed on
        // `pjsua_call_info`): while held this records only — the resume rebuild re-applies.
        if media.contains(where: { $0.kind == .audio && $0.status == .localHold }) { return }
        for stream in media
        where stream.kind == .video
            && (stream.direction == .encoding || stream.direction == .encodingDecoding) {
            try setVideoStream(call,
                               enabled ? PJSUA_CALL_VID_STRM_START_TRANSMIT
                                       : PJSUA_CALL_VID_STRM_STOP_TRANSMIT) {
                $0.med_idx = Int32(stream.index)
            }
        }
    }

    /// Change a video stream's negotiated direction — a re-INVITE (`call_modify_video`,
    /// pjsua_vid.c). Maps onto SDP as `sendrecv` / `sendonly` / `recvonly` / `inactive`
    /// for `.encodingDecoding` / `.encoding` / `.decoding` / `.none`.
    ///
    /// There is no SIP/RTP way to make the peer transmit video: `.decoding`
    /// (recvonly) is merely a request in the offer — the peer may still answer the line
    /// inactive or port 0. Going the other way *is* enforceable: an `.encoding`
    /// (sendonly) offer obliges a compliant peer to stop sending (RFC 3264 §5.1).
    /// Note a sendonly stream reports `.localHold` status (pjsua_media.c) — "transmitting"
    /// is not the same as "media active", which is why ``CallMediaIntent`` tracks the
    /// want separately. Setting anything but `.none` also records
    /// ``CallMediaIntent/acceptsVideo`` `= true` (we are offering video).
    public func setVideoDirection(_ call: CallID, _ direction: CallMediaInfo.Direction,
                                  streamIndex: Int32 = -1) throws {
        let dir: pjmedia_dir
        switch direction {
        case .none:              dir = PJMEDIA_DIR_NONE
        case .encoding:          dir = PJMEDIA_DIR_ENCODING
        case .decoding:          dir = PJMEDIA_DIR_DECODING
        case .encodingDecoding:  dir = PJMEDIA_DIR_ENCODING_DECODING
        case .unknown(let raw):
            preconditionFailure("setVideoDirection: cannot signal an unknown direction (\(raw))")
        }
        try setVideoStream(call, PJSUA_CALL_VID_STRM_CHANGE_DIR) {
            $0.med_idx = streamIndex
            $0.dir = dir
        }
        // Offering video — recorded only once the offer was signalled.
        if direction != .none {
            updateMediaIntent(for: call.raw) { $0.acceptsVideo = true }
        }
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
