import PJSIP

extension PJSUA {
    // MARK: Conference primitives — audio (local / client-side mixing)
    //
    // PJSIP supports two conference models (design §7). This file provides the engine
    // primitives for **local / client-side mixing** via the PJMEDIA conference bridge plus the
    // detection primitive for the **server-hosted / focus** model (RFC 4579). The higher-level
    // topology choice (which legs to bridge, when) belongs to the GUI layer's
    // `CallSessionRouter`; the engine only exposes the slot wiring and the focus flag — no
    // standalone `Conference` abstraction (D-CONF sign-off).
    //
    // The conference bridge mixes locally: every call leg has a conference *slot*
    // (`pjsua_call_get_conf_port`). Connecting two slots is **directional**, so audio that
    // flows both ways needs two `pjsua_conf_connect` calls. The engine already bridges each
    // active leg to the sound device (slot 0) in `pjsuaOnCallMediaState`; to let participants
    // hear *each other* in a local N-way call, the legs' slots must additionally be
    // cross-connected — that is what these primitives do.
    //
    // References:
    // - pjsua1 `pjsua_call_get_conf_port` / `pjsua_conf_connect` / `pjsua_conf_disconnect` (pjsua.h).
    // - PJSUA2 local conference bridge & RFC 4579 focus models — <https://docs.pjsip.org/en/latest/>.
    // - RFC 4579 (SIP Call Control — Conferencing), `;isfocus` Contact parameter.

    /// The PJMEDIA conference-bridge slot for a call's audio (`pjsua_call_get_conf_port`), or
    /// `nil` when the call has no active audio media yet (`PJSUA_INVALID_ID`). Slot `0` is the
    /// sound device; every other slot is a call leg.
    public func audioConferenceSlot(of call: CallID) -> Int32? {
        let slot = pjsua_call_get_conf_port(call.raw)
        return slot >= 0 ? slot : nil // PJSUA_INVALID_ID == -1
    }

    /// Connect one conference slot to another, directionally (`source` audio is mixed into
    /// `sink`). For two-way audio call this twice with the slots swapped, or use
    /// ``connectAudio(_:and:)``.
    public func connectAudioSlot(from source: Int32, to sink: Int32) throws {
        try pjsua_conf_connect(source, sink).throwIfFailed()
    }

    /// Disconnect a directional conference-slot link previously made with
    /// ``connectAudioSlot(from:to:)``.
    public func disconnectAudioSlot(from source: Int32, to sink: Int32) throws {
        try pjsua_conf_disconnect(source, sink).throwIfFailed()
    }

    /// Bidirectionally bridge two call legs' audio so the parties hear each other (local
    /// mixing). Both legs must already have active audio media; otherwise this throws
    /// ``PJSUAUsageError/callHasNoMediaPort(_:)`` and wires nothing. The legs remain bridged to
    /// the sound device independently (done in `pjsuaOnCallMediaState`); this only adds the
    /// leg↔leg cross-connection.
    public func connectAudio(_ a: CallID, and b: CallID) throws {
        guard let portA = audioConferenceSlot(of: a) else { throw PJSUAUsageError.callHasNoMediaPort(a) }
        guard let portB = audioConferenceSlot(of: b) else { throw PJSUAUsageError.callHasNoMediaPort(b) }
        try connectAudioSlot(from: portA, to: portB)
        try connectAudioSlot(from: portB, to: portA)
    }

    /// Undo ``connectAudio(_:and:)``: drop the leg↔leg cross-connection in both directions,
    /// leaving each leg's sound-device bridge intact. A leg with no media port is skipped
    /// (nothing to disconnect).
    public func disconnectAudio(_ a: CallID, and b: CallID) throws {
        guard let portA = audioConferenceSlot(of: a), let portB = audioConferenceSlot(of: b) else { return }
        try disconnectAudioSlot(from: portA, to: portB)
        try disconnectAudioSlot(from: portB, to: portA)
    }

    // MARK: Conference detection — server-hosted / focus (RFC 4579)

    /// Whether the remote party is a **conference focus** (RFC 4579): its `Contact` header
    /// carries the `;isfocus` feature parameter. When `true`, the server mixes all
    /// participants and the app should *not* use the local bridge to mix legs — it connects its
    /// single call's audio to the device and shows one mixed stream. Returns `false` when the
    /// call is unknown or its `Contact` has not been learned yet (before the dialog is
    /// established). Parsed from `pjsua_call_info.remote_contact`, as pjsua1 exposes no
    /// dedicated focus flag.
    public func isConferenceFocus(_ call: CallID) -> Bool {
        var info = pjsua_call_info()
        guard pjsua_call_get_info(call.raw, &info).isSuccess else { return false }
        guard let contact = info.remote_contact.string else { return false }
        // RFC 4579: the parameter is `;isfocus` (token, case-insensitive, value-less).
        return contact.lowercased().contains("isfocus")
    }
}
