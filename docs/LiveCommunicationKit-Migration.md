# LiveCommunicationKit — migration notes for SwiftPJSUAKit

> Working notes for the day the Kit moves from CallKit's `CXProvider` to LiveCommunicationKit
> (LCK). Not a plan to do it now. Gathered 2026-10-28 while designing the per-call media intent
> model (swift-pjsua #38); sources are Apple's LCK reference (iOS 17.4+ API set) and WWDC26
> session 226 "Create live communication experiences", where Apple says apps on `CXProvider`
> should "move over to LiveCommunicationKit". Facts marked *verify* were not checked on a device.

## 1. When it becomes possible

- **The gate is iOS 17.4, not a major version.** Every LCK type used below is available on
  iOS 17.4+ / iPadOS 17.4+ / visionOS 1.1+ / watchOS 10.4+. The package floor is iOS 17, so the
  only deployment change is `.iOS(.v17)` → `.iOS("17.4")`. Nothing waits for "dropping iOS 15".
- **iOS 26-only parts** (June 2025 additions): `SetTranslatingAction` / `supportsAudioTranslation`
  (system live translation — not applicable to a SIP media path), and the default-dialer surface
  (`TelephonyConversationManager`, `StartCellularConversationAction`, `telephony://` fallback).
  None of those block a migration of the call path.
- **PushKit stays.** LCK does not replace PushKit; the VoIP push still wakes the app and the
  conversation must be reported before the push delegate returns, or the app is terminated —
  the same contract the Kit honours today (``VoIPPushHandler``).

## 2. Vocabulary map (CallKit → LCK)

| Kit today (CallKit) | LCK | Notes |
|---|---|---|
| `CXProvider` + `CXProviderConfiguration` | `ConversationManager` + `ConversationManager.Configuration` | Config is mutable at runtime. Fields: `ringtoneName`, `iconTemplateImageData`, `maximumConversationGroups`, `maximumConversationsPerConversationGroup`, `includesConversationInRecents`, `supportsVideo`, `supportedHandleTypes`. |
| `CXProviderDelegate` | `ConversationManagerDelegate` | One `perform(_: ConversationAction)` callback plus `timedOutPerforming`, `didActivate`/`didDeactivate` (audio session), `conversationManagerDidBegin/DidReset`, `conversationChanged`. |
| `CXCall` / `CXCallObserver` | `Conversation` (`@Observable`, `Sendable`); `manager.conversations` | In-app observation no longer needs a system-wide observer or `isKnownCall` filtering: the manager lists only this app's conversations. |
| `CXCallUpdate` | `Conversation.Update(localMember:members:activeRemoteMembers:capabilities:)` | `remoteHandle` → `members`; `hasVideo` → `.video` in `capabilities`; `supportsHolding` → `.pausing`; `supportsDTMF` → `.playingTones`; `supportsGrouping`/`supportsUngrouping` → `.merging`/`.unmerging`. Capabilities may change mid-conversation and the UI follows immediately. |
| `reportNewIncomingCall(with:update:)` | `reportNewIncomingConversation(uuid:update:)` (async throws) | Same dedup role for ``CallIdentity``/``CallRegistry``. A class-level `reportNewIncomingVoIPPushPayload(_:)` exists for reporting from a notification service extension (*verify* the launch/entitlement rules before relying on it). |
| `reportOutgoingCall(startedConnectingAt:)` / `(connectedAt:)` / `reportCall(endedAt:reason:)` | `reportConversationEvent(.conversationStartedConnecting(Date) / .conversationConnected(Date) / .conversationEnded(Date, EndedReason) / .conversationUpdated(Update), for:)` | One event API for both directions. `EndedReason`: `declinedElsewhere`, `failed`, `joinedElsewhere`, `remoteEnded`, `unanswered` — the same set as `CXCallEndedReason` (`joinedElsewhere` ≙ `answeredElsewhere`), so `endedReason(_:)` ports 1:1. |
| `CXStartCallAction` | `StartConversationAction(conversationUUID:handles:isVideo:)` | `isVideo` survives — the one system control that expresses "send video". |
| `CXAnswerCallAction` | `JoinConversationAction`; fulfilled with `fulfill(dateConnected:)` | No video flag on join (same as CallKit) — video transmission on an incoming call remains the app's decision (``CallMediaIntent``). |
| `CXEndCallAction` | `EndConversationAction` | |
| `CXSetHeldCallAction` | `PauseConversationAction(isPaused:)` | "Stops or restarts all audio and video streams"; the system offers it only when `.pausing` is declared (long-press on Mute). Maps to ``PJSUA/setHold(_:)`` / ``PJSUA/resume(_:)`` and is still fulfilled on the `.callMediaState` transition. |
| `CXSetMutedCallAction` | `MuteConversationAction(isMuted:)` | Maps to ``PJSUA/setMute(_:muted:)``; the engine keeps the mute across pause/resume. |
| `CXPlayDTMFCallAction` | `PlayToneAction` (needs `.playingTones`) | → ``PJSUA/sendDTMF(_:digits:duration:)``. |
| `CXSetGroupCallAction` | `MergeConversationAction` / `UnmergeConversationAction` (two UUIDs) | → router `setGroup` / `groupAdjacency` unchanged in substance. |
| `providerDidReset` | `conversationManagerDidReset` | → `router.reset()`. |
| `provider(_:didActivate:)` / `didDeactivate` | identical pair on the delegate | Engine audio gating (`activateAudioDevice` on activation only) is unchanged. |
| `CXProviderConfiguration.includesCallsInRecents` (write-only) | `includesConversationInRecents` + `ConversationHistoryManager` (`recentConversations(matching:)`, mark-as-read) — the app can now *read* its recents | Redial from Recents / Siri arrives as the start-call intent → `NSUserActivity`; Apple asks apps to donate their own intent after each conversation. |

## 3. Lifecycle differences that touch the router

- **State machine is explicit:** `idle → joining → joined → paused ↔ joined → leaving → left`.
  The app drives transitions through events; Apple's rule is "no audio or video capture before
  `joined`". That is the rule the Kit already follows for audio (device opens on `didActivate`),
  and the one ``CallMediaIntent`` follows for video (transmission only on explicit intent, re-applied
  after each media rebuild) — the engine side needs no change.
- **Actions carry a `timeoutDate` and a `state`,** and the delegate is told when one
  `timedOutPerforming`. Today's `pending` table (answer/start fulfilled on `.confirmed`, hold on
  the media transition) stays, but gains a required path: on timeout, fail the action *and* clear
  the pending entry; the manager also exposes `pendingActions` /
  `pendingConversationActions(of:for:)`, which can replace the Kit's own bookkeeping of what is
  outstanding per call.
- **Single action path.** In-app buttons create the same action objects
  (`manager.perform([action])`) that the system UI creates, so the app never calls the router
  directly for mute/hold/end — the pattern the Kit already uses through `CXCallController`.
- **Membership is a first-class update.** `members` (invited) vs `activeRemoteMembers` (media
  flowing) must be kept current; for the local-mix conference (D-CONF) that means reporting the
  merged member set after every `setGroup`, not just a group id. The focus model (RFC 4579) maps
  to a single remote member unless the focus publishes participants (conference-info) — unchanged.
- **Video is a capability, not a one-shot flag.** A remote mid-call upgrade that the engine
  accepts (``CallMediaIntent/acceptsVideo``) should be reported as
  `.conversationUpdated` adding `.video`; a downgrade removes it. CallKit needed
  `reportCall(with:updated:)` for the same.

## 4. Things to verify on a device before switching

1. Does a conversation whose capabilities include `.video` force an unlock before join, the way
   `CXCallUpdate.hasVideo = true` does for CallKit? The Kit's video-transmission story relies on the app being
   foreground when the user decides to send video.
2. Is a `MuteConversationAction` re-delivered after pause/resume, or is the app expected to
   restore mute itself (the engine already does, so either answer is safe — but the UI state must
   agree).
3. `reportNewIncomingVoIPPushPayload(_:)` from a notification service extension: entitlement,
   whether the main app is launched, and how the UUID reaches the router's registry.
4. Whether `supportsVideo = true` plus the `.video` capability shows a camera control the system
   expects the app to honour (the WWDC session says the video button is enabled by configuration;
   what the button does is the app's).

## 5. What does not change

The engine (`SwiftPJSUA`) and the media intent model. Both frameworks make mute and hold system
actions and leave video transmission to the app; neither carries a video flag on answer/join. That is why
``CallMediaIntent`` lives in the engine and not in the Kit: a `ConversationController` replacing
``CallKitController`` is a mapping exercise over the table in §2, with ``CallSessionRouter``'s
correlation logic (registry, pending actions, dedup of push vs INVITE) kept intact.
