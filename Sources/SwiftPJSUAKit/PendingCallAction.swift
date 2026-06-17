import CallKit

/// A `CXAction` whose SIP outcome resolves *asynchronously*, stashed by ``CallSessionRouter``
/// (keyed by the call's CallKit `UUID`) until the matching engine event arrives — at which point
/// the router calls `.fulfill()` / `.fail()`.
///
/// Apple mandates this deferral for the connection-establishing actions: *"if the user answers an
/// incoming call before the app is able to establish the connection, don't fulfill the
/// `CXAnswerCallAction` … wait until the connection is established"*
/// (Responding to VoIP Notifications from PushKit). Hold/unhold are likewise confirmed only when
/// the media direction actually changes (see design §2 / §10).
enum PendingCallAction {
    /// `CXAnswerCallAction` (incoming) or `CXStartCallAction` (outgoing) — fulfilled on
    /// `.callState(.confirmed)` once the INVITE session is up.
    case connect(CXAction)

    /// `CXSetHeldCallAction` — fulfilled on the `.callMediaState` whose audio stream reflects the
    /// requested `onHold` state (local-hold when holding, active when resuming).
    case setHeld(CXSetHeldCallAction, onHold: Bool)

    /// The underlying action, for `.fulfill()` / `.fail()` regardless of case.
    var action: CXAction {
        switch self {
        case .connect(let action):        return action
        case .setHeld(let action, _):     return action
        }
    }
}
