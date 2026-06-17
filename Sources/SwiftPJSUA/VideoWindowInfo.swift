import PJSIP

/// A snapshot of a PJSUA video window, mirrored from `pjsua_vid_win_info`.
///
/// PJSUA renders each incoming (decoded) video stream into a *window* identified by a
/// `pjsua_vid_win_id`. The engine surfaces that id on ``CallMediaInfo/videoWindow`` and lets the
/// app drive rendering (pixel work belongs to the Offhook app — D-VIDEO sign-off). This value
/// type exposes the window's geometry/show state so the app can lay out its view; the opaque
/// native handle (`hwnd`) is intentionally **not** surfaced — the app attaches its own view via
/// the engine's window API rather than reaching the raw handle (which is not `Sendable`).
///
/// Reference: pjsua1 `pjsua_vid_win_info` (pjsua.h).
public struct VideoWindowInfo: Sendable, Equatable {
    /// `true` for a native window (e.g. a built-in capture preview). When native, only the
    /// underlying handle is meaningful and geometry/show operations are invalid — see
    /// ``PJSUA/showVideoWindow(_:_:)``.
    public var isNative: Bool
    /// The renderer device id backing this window.
    public var renderDevice: Int32
    /// This window's renderer slot in the **video** conference bridge (the sink you connect a
    /// decoded video source into; see ``PJSUA/connectVideo(from:to:)``).
    public var conferenceSlot: Int32
    /// Whether the window is currently shown (hidden if `false`).
    public var isShown: Bool
    /// Window x position.
    public var x: Int32
    /// Window y position.
    public var y: Int32
    /// Window width in pixels.
    public var width: UInt32
    /// Window height in pixels.
    public var height: UInt32

    public init(isNative: Bool,
                renderDevice: Int32,
                conferenceSlot: Int32,
                isShown: Bool,
                x: Int32,
                y: Int32,
                width: UInt32,
                height: UInt32) {
        self.isNative = isNative
        self.renderDevice = renderDevice
        self.conferenceSlot = conferenceSlot
        self.isShown = isShown
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Map one C `pjsua_vid_win_info` into the Swift value type. Reads POD only.
    init(_ info: pjsua_vid_win_info) {
        self.isNative = info.is_native.bool
        self.renderDevice = info.rdr_dev
        self.conferenceSlot = info.slot_id
        self.isShown = info.show.bool
        self.x = info.pos.x
        self.y = info.pos.y
        self.width = info.size.w
        self.height = info.size.h
    }
}
