import PJSIP

extension PJSUA {
    // MARK: Audio device

    // On iOS, swift-pjsip is built with `SETUP_AV_AUDIO_SESSION=0`: PJSIP does **not** own
    // `AVAudioSession`. CallKit/the app owns it, and the engine only opens/closes the sound
    // device in response to CallKit's audio-session lifecycle. The GUI layer
    // (`SwiftPJSUAKit`) drives these from `CXProviderDelegate`:
    //   - `provider(_:didActivate:)`   → ``activateAudioDevice()``
    //   - `provider(_:didDeactivate:)` → ``deactivateAudioDevice()``
    // The actual mic↔remote conference wiring happens in the media-state callback
    // (`pjsua_conf_connect`, see `PJSUACallbacks.swift`).

    /// Open the default capture + playback devices. Call **after** CallKit activates the
    /// audio session (`provider(_:didActivate:)`), never before — opening the device while
    /// the session is inactive fails or yields no audio.
    public func activateAudioDevice() throws {
        let capture = Int32(PJMEDIA_AUD_DEFAULT_CAPTURE_DEV)   // -1
        let playback = Int32(PJMEDIA_AUD_DEFAULT_PLAYBACK_DEV) // -2
        try pjsua_set_snd_dev(capture, playback).throwIfFailed()
    }

    /// Release the sound hardware by disconnecting the conference bridge from any device.
    /// Call when CallKit deactivates the audio session (`provider(_:didDeactivate:)`) so
    /// PJSIP never holds the mic in the background.
    ///
    /// Wraps `pjsua_set_no_snd_dev()`, which returns the bridge's master port (for apps
    /// that drive their own master port); we don't use it and it reports no error code.
    public func deactivateAudioDevice() {
        _ = pjsua_set_no_snd_dev()
    }
}
