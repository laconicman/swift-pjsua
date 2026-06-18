# SwiftPJSUAKit — Call Lifecycle, Media, Dedup, Video & Conferences (M1 skeleton design)

Status: **SIGNED OFF** — all five decisions approved; **split into PR-a + PR-b** (see §12).
This is the as-designed record committed alongside PR-a; the as-built deltas live in
`docs/Production-Roadmap.md` §6–§7. Plan-first / `/think-hard`.
Target: PJSIP **2.17**, iOS **17+**, Swift 5.9, pjsua1 C API (not PJSUA2 — used as reference only).
Author context: advances PR #1 (merged). Branch `feat/callkit-lifecycle-and-media`, cut off `main`.

> Reading guide. §1–§2 set the one new load-bearing component (the **event router**) that
> everything else hangs off. §3–§9 are the per-feature designs (lifecycle, media, audio,
> video, conferences, registration, dedup). §10 is the full CallKit-action map. §11 lists
> the file changes. **§12 is the sign-off checklist — the decisions that are expensive to
> reverse.** §13 is the commit/test plan; §14 collects citations.

---

## 1. Layering recap & invariants we are NOT touching

```
PJSIP.xcframework (binary, iOS-only)
        ▲   C / C++ modules: PJSIP, PJSUA2 (we use the C `PJSIP` module only)
SwiftPJSUA      — actor on ONE PJLIB-registered thread; pjsua1 wrapper; emits PJSUAEvent
        ▲
SwiftPJSUAKit   — CallKit + PushKit + AVAudioSession glue; owns NO SIP logic
        ▲
Offhook (app)   — SwiftUI, owns CXProvider config, PKPushRegistry, video rendering
```

Untouched cornerstones (decided earlier, *do not reverse casually*):
- **pjsua1, not PJSUA2** — Swift/C++ interop cannot subclass C++ / override virtuals; pjsua1's
  C callbacks bridge cleanly to `@convention(c)`. We *replicate* PJSUA2's upper-level call/media
  lifecycle in Swift, improving where we can. (DeepWiki PJSUA2 lifecycle, §3/§4.)
- **Custom `SerialExecutor` on one PJLIB thread**; the actor only ever *enters* PJSIP calls.
  `thread_cnt`/`media.thread_cnt` pinned ≥1 so pjsua's own worker threads pump events (G1).
- **Callbacks hold no actor reference** — re-entrancy impossible by construction (G2).
- **iOS builds PJSIP with `SETUP_AV_AUDIO_SESSION=0`** — CallKit/app owns `AVAudioSession`; the
  engine only opens/closes the sound device on CallKit's audio cues (§5).
- **G.729 stays** (`PJMEDIA_HAS_BCG729 1`); Opus cannot transcode it.

### 1.1 System frameworks the package links (and why the list drifts)

PJSIP is a **static** library, so the Apple frameworks its objects call into are resolved at
*final-binary* link time (app or test bundle) — not when SwiftPM builds the library module. The
`SwiftPJSUA` source target carries the list in `Package.swift`'s `linkerSettings`, and SwiftPM
propagates it to whatever ultimately links the product. Depending on `SwiftPJSUA` is enough.

Current set:

| Target           | Linked frameworks / libraries |
|------------------|-------------------------------|
| `SwiftPJSUA`     | `AVFoundation`, `AudioToolbox`, `CoreAudio`, `CoreMedia`, `CoreVideo`, `VideoToolbox`, `MetalKit`, `Network`, `Security`, `libc++` |
| `SwiftPJSUAKit`  | + `CallKit`, `PushKit`        |

**This list drifts** along two axes:

1. **PJSIP version** — media backends and transports evolve across releases; a new pjmedia
   capture/codec implementation can pull in a new Apple SDK.
2. **The concrete `swift-pjsip` binary** — the committed xcframework is compiled against a
   specific [`config_site.h`](https://github.com/laconicman/swift-pjsip/blob/main/scripts/config_site.h)
   (video on, VideoToolbox H.264, BCG729, Apple SSL). Flipping any of those options at rebuild
   time changes which SDKs `libpjproject.a` actually references.

So treat `Package.swift` as the source of truth and re-verify on every `swift-pjsip` upgrade
or `config_site.h` flip. A missing framework surfaces as an `Undefined symbol` at link time,
not at runtime — typically caught first by the **test bundle's** link step, since library
targets only emit Swift modules and skip the full link. Example: `_CMSampleBufferCreate` →
`CoreMedia`.

---

## 2. The missing piece: a Kit-side **event router** (NEW — central decision)

Today `SwiftPJSUA` emits `PJSUAEvent`s on an `AsyncStream`, and `CallKitController` only knows
how to *report a new incoming call* and drive the audio device. Nothing consumes the engine
event stream to (a) update CallKit as the SIP call progresses, or (b) resolve CallKit actions
once the engine reaches the right state. That consumer is the heart of this milestone.

**Proposal: `CallSessionRouter` (actor in SwiftPJSUAKit).**
- Owns a single `Task` that iterates `engine.events` for the process lifetime.
- Maps each engine event onto CallKit provider reports (see tables in §3) — e.g.
  `.callState(.disconnected, lastStatus: 487)` → `provider.reportCall(with:endedAt:reason:.remoteEnded/.unanswered)`.
- Holds the **pending-action table**: when CallKit asks us to perform an action that completes
  asynchronously in SIP (answer, hold, unhold), we *stash the `CXAction`* keyed by call UUID and
  `fulfill()`/`fail()` it later when the matching engine event arrives. This is mandated by
  Apple: *"if the user answers … before the app is able to establish the connection, don't
  fulfill the `CXAnswerCallAction` … wait until the connection is established"*
  ([Responding to VoIP Notifications from PushKit][push]).
- Keeps the `CallRegistry` (UUID ↔ SIP `Call-ID` ↔ `CallID`) authoritative and is the only
  writer to it after the initial report.

Why an actor + one consumer task (not many `for await` sites): `AsyncStream` is single-consumer;
multiple readers would steal events. Centralizing also gives us one place to enforce ordering and
to correlate actions ↔ events. (swift-concurrency skill: prefer one structured consumer; keep
mutable correlation state behind an actor.)

```
                         engine.events (AsyncStream<PJSUAEvent>)
                                   │  (one consumer Task)
        ┌──────────────────────────▼───────────────────────────┐
        │                 CallSessionRouter (actor)             │
        │  • event → CallKit report   • pending CXAction table   │
        │  • owns CallRegistry        • conference topology      │
        └───▲───────────────▲──────────────────────▲────────────┘
   CXProviderDelegate   VoIPPushHandler         engine (PJSUA actor)
   (actions in)         (push in)               (commands out)
```

**D-ROUTER (sign-off):** introduce `CallSessionRouter` as the single engine-event consumer and
action-correlation owner. `CallKitController` becomes a thin `CXProviderDelegate` that forwards
actions to the router; `VoIPPushHandler` forwards pushes to it.

---

## 3. Call lifecycle — incoming & outgoing

State sequences confirmed via DeepWiki (PJSUA2 = `pjsua_app`/`pjsua2` over the same pjsip core we
call directly):

**Incoming, answered:** `on_incoming_call` → `INCOMING` → (`EARLY` if we send 180) → `CONNECTING`
(on 200 sent) → `on_call_media_state` (SDP negotiated) → `CONFIRMED` (ACK).
**Outgoing, answered:** `CALLING` → (`EARLY` on 1xx) → `on_call_media_state` (if SDP in 1xx/2xx) →
`CONNECTING` (2xx) → `CONFIRMED` (ACK sent).
**Caller cancels before answer:** `DISCONNECTED`, `last_status` = **487**.
**Remote BYE while confirmed:** `DISCONNECTED`. PJSUA2 auto-frees media on DISCONNECTED.

### 3.1 Engine event → CallKit (incoming)

| Engine event | Router action (CallKit) |
|---|---|
| `.incomingCall(sipCallID, offeredVideo, from)` | dedup (§9); if new → `reportNewIncomingCall(with:uuid, update:)` (`update.hasVideo = offeredVideo`) |
| `.callState(.early)` | optional: ringing UI; no CallKit call needed |
| `.callState(.confirmed)` | **fulfill** the stashed `CXAnswerCallAction` (connection now up) |
| `.callMediaState(...)` | per-stream wiring (§4); reflect remote-hold/active |
| `.callState(.disconnected, last=487)` | `reportCall(with:endedAt:reason:.unanswered/.remoteEnded)`, evict registry |
| `.callState(.disconnected, last≥300)` | `reportCall(... reason:.failed)`, evict |

### 3.2 Engine event → CallKit (outgoing)

| Engine event | Router action (CallKit) |
|---|---|
| user taps call → `CXStartCallAction` | `engine.makeCall`, stash action; `reportOutgoingCall(with:startedConnectingAt:)` on `.early` |
| `.callState(.confirmed)` | `provider.reportOutgoingCall(with:connectedAt:)`; fulfill `CXStartCallAction` |
| `.callState(.disconnected)` | fail action if not yet connected, else `reportCall(endedAt:)` |

Apple outgoing reference: `provider(_:perform: CXStartCallAction)` → `configureAudioSession()`
(configure only; do not start audio), report connecting/connected, `action.fulfill()`/`.fail()`
([Making and receiving VoIP calls][mkvoip]).

---

## 4. Media model redesign — per-stream `media[]` (KEY DECISION)

**Problem.** Today `pjsuaOnCallMediaState` reads the single aggregate `info.media_status` and the
event carries one `CallMediaStatus`. That cannot represent a call with **audio + video**, or a
**conference** with several streams, each having its own type / status / direction. DeepWiki
confirms PJSUA2's `onCallMediaState` iterates `CallInfo.media[]`, and for each entry inspects
`media[i].type` (AUDIO/VIDEO), `media[i].status` (NONE/ACTIVE/LOCAL_HOLD/REMOTE_HOLD/ERROR),
`media[i].dir` (ENCODING/DECODING/ENCODING_DECODING); audio entries expose a conference slot,
video entries a window/stream index. `on_call_media_state` fires whenever SDP negotiation
completes — **initial offer/answer AND every re-INVITE** (hold, unhold, add video). So it is the
one place to react to media-direction changes.

**Proposal.** Introduce a per-stream value type and make the event carry a vector:

```swift
public struct CallMediaInfo: Sendable, Equatable {
    public enum Kind: Sendable, Equatable { case audio, video, application, unknown(Int32) }
    public enum Direction: Sendable, Equatable { case none, encoding, decoding, encodingDecoding }
    public var index: Int                 // index within the call's media[]
    public var kind: Kind
    public var status: CallMediaStatus    // existing enum (none/active/localHold/remoteHold/error)
    public var direction: Direction
    public var audioConfSlot: Int32?      // pjsua conf-bridge slot, when kind == .audio
    public var videoWindow: UInt32?       // pjsua_vid_win_id, when kind == .video (incoming)
    public var videoCapture: Bool         // this video stream is transmitting our camera
}

// PJSUAEvent change:
case callMediaState(call: CallID, media: [CallMediaInfo])   // was: status: CallMediaStatus
```

The engine still performs the *low-level* wiring on its worker thread (audio: `pjsua_conf_connect`
both directions for each ACTIVE/REMOTE_HOLD audio slot; video: connect to the video conf bridge,
surface the window id), then yields the full `[CallMediaInfo]`. The **app/Kit** decides the
higher-level reaction (show remote video window, reflect hold in UI, stop ringback on active),
mirroring PJSUA2 — exactly the "don't filter in core" stance you set on PR #1 finding #2.

**D-MEDIA (sign-off):** replace aggregate `media_status` with per-stream `[CallMediaInfo]` now,
while the skeleton is cheap to reshape. This is the single most expensive-to-defer decision
because the event type is the contract between engine and Kit/app.

---

## 5. Audio session ownership (unchanged direction, formalized)

CallKit owns `AVAudioSession`; the engine opens the sound device only when the system activates the
session. Flow:
- `provider(_:perform: CXAnswerCallAction)` / `CXStartCallAction` → **configure** the category
  (`.playAndRecord`, mode `.voiceChat`/`.videoChat`) but **do not start audio** — Apple: *"audio
  should not be started until the audio session is activated by the system, after having its
  priority elevated"* ([Making and receiving VoIP calls][mkvoip]).
- `provider(_:didActivate:)` → `engine.activateAudioDevice()` (`pjsua_set_snd_dev`). *(already wired)*
- `provider(_:didDeactivate:)` → `engine.deactivateAudioDevice()` (`pjsua_set_no_snd_dev`). *(already wired)*

The category configuration (mode, video vs audio) lives in Kit; the device open/close lives in the
engine. ([CXProviderDelegate audio-session methods][cxdel]; [AVAudioSession][avas].)

---

## 6. Video as first-class

Decisions baked in now even though pixel rendering is the app's job:
- CallKit: `CXProviderConfiguration.supportsVideo = true`; incoming `CXCallUpdate.hasVideo` set from
  the **offered** SDP; outgoing `CXStartCallAction.isVideo`. ([CXCallUpdate.hasVideo][cxcu].)
- Engine surfaces `offeredVideo` on `.incomingCall` (parse the INVITE's media — a video `m=` line)
  so the very first CallKit report is correct (an upgrade later is possible via a new `CXCallUpdate`,
  but getting it right at report time avoids a flash).
- `CallMediaInfo.video` carries the `pjsua_vid_win_id` (remote) and a capture flag (local). Engine
  adds thin wrappers: start/stop transmitting local video (`pjsua_call_set_vid_strm` with
  `PJSUA_CALL_VID_STRM_START/STOP_TRANSMIT`), and getters for the window so the app can attach a
  view. Actual rendering (MetalKit/`UIView`) is the app's. The video-side Apple frameworks
  are linked by the package (`CoreMedia`, `CoreVideo`, `VideoToolbox`, `MetalKit`); see §1.1
  for the full framework list and the drift caveats.
- **Video while screen locked:** works because CallKit's `didActivate` fires regardless of lock
  state and the device/video bridge are driven from there, not from UI. Local camera capture may be
  restricted while locked — the app reflects that; the signaling path is unaffected.

**D-VIDEO (sign-off):** shape the full video type/event/API surface now; implement engine-side
window-id surfacing + video-conf connect; defer app-side rendering (it lives in Offhook).

**As-built (PR-b).** `PJSUA+Video.swift`: `addVideoStream` / `removeVideoStream` /
`startVideoTransmission` / `stopVideoTransmission` / `changeVideoCaptureDevice` / `sendVideoKeyframe`
(all via `pjsua_call_set_vid_strm`, each initialised with `pjsua_call_vid_strm_op_param_default`);
`showVideoWindow(_:_:)` (`pjsua_vid_win_set_show`) + `videoWindowInfo(_:)` (`pjsua_vid_win_get_info`)
returning the new `VideoWindowInfo` value type; `videoConferenceSlot(of:sending:)`
(`pjsua_call_get_vid_conf_port`) + `connectVideo` / `disconnectVideo`. `makeCall(to:from:video:)`
offers one video stream (`opt.vid_cnt = 1`). Pixel rendering stays in Offhook.

---

## 7. Conferences — both PJSIP models, first-class

DeepWiki confirmed two distinct models; we represent both.

### 7.1 Local / client-side mixing (PJMEDIA conference bridge)
The built-in bridge mixes locally: connect each call's conf slot to slot 0 (the device) **and** to
every other participant's slot. `pjsua_conf_connect(src, sink)` is directional; bidirectional needs
two calls. `pjsua_call_get_conf_port(callId)` returns a call's slot. Multiple sources into one sink
are mixed. Video has its own bridge: `pjsua_vid_conf_add_port` / `pjsua_vid_conf_connect` /
`pjsua_call_get_vid_conf_port`; layouts `PJMEDIA_VID_CONF_LAYOUT_DEFAULT` (others planned upstream).

CallKit tie-in: the system models multi-party via **`CXSetGroupCallAction`** (group/ungroup calls)
and `CXCallUpdate.supportsGrouping`. The router maps grouping → local-mix topology (connect the
grouped calls' slots together). ([CXProviderDelegate set-group action][cxdel].)

### 7.2 Server-hosted / focus (RFC 4579 conference-as-focus)
One call to a focus URI; the remote `Contact` carries `;isfocus`. The app connects its single
call's audio to slot 0 both ways; the server mixes everyone. Local bridge is NOT used to mix
participants. Video is a single mixed stream shown in one window.

Engine surfaces `isFocus` (parsed from the answering `Contact`) on the call so the app/router knows
which model applies. We provide engine primitives for both; the Kit `CallSessionRouter` chooses the
topology. We do **not** add a heavy `Conference` abstraction now (you've "suffered from just-in-case
abstraction") — primitives + a thin router mapping from CallKit grouping.

**D-CONF (sign-off):** engine exposes conference primitives (audio slot connect/disconnect, video
conf add/connect, `isFocus` detection) + per-stream media; Kit maps CallKit grouping → local-mix and
detects focus for server-side. No standalone Conference type yet.

**As-built (PR-b).** `PJSUA+Conference.swift`: `audioConferenceSlot(of:)`
(`pjsua_call_get_conf_port`), `connectAudioSlot` / `disconnectAudioSlot` (directional
`pjsua_conf_connect` / `pjsua_conf_disconnect`), the bidirectional leg convenience
`connectAudio(_:and:)` / `disconnectAudio(_:and:)`, and `isConferenceFocus(_:)` (parses
`pjsua_call_info.remote_contact` for `;isfocus`, since pjsua1 has no focus field). Router
`setGroup(_:)` maps `CXSetGroupCallAction` to bidirectional slot cross-connects, tracking N-way
membership in a symmetric `groupAdjacency` map; `supportsGrouping` / `supportsUngrouping` advertised
on the incoming update and `maximumCallsPerCallGroup = 5`. Video-conference *layout* (compositing
multiple sources beyond the primitive `connectVideo`) is deferred — see Tech-Debt TD-6.

---

## 8. Registration, RFC 8599 push, silent re-REGISTER

- `on_reg_state2` parsing already distinguishes active/failure/de-reg via `code`/`expiration`/`renew`
  (`PJSUA+/PJSUACallbacks`). Keep; add `reason` phrase passthrough for diagnostics.
- RFC 8599: `reg_contact_uri_params = ";pn-provider=apns;pn-param={team}.{bundle}.voip;pn-prid={tok}"`
  set before `pjsua_acc_add`. Already implemented as free-form `PushConfiguration` + `apns(...)`
  builder + `reRegister(_:updatingPush:)`.
- **Silent push → re-REGISTER with updated params must NOT collide with the VoIP-push answer path.**
  These are independent: silent push → `engine.reRegister(account, updatingPush:)` (rebuilds acc
  config from stored `AccountParameters`, `pjsua_acc_modify`, `pjsua_acc_set_registration(renew)`).
  VoIP push → CallKit report + await INVITE. The router serializes both onto the engine actor, so
  there is no shared-state race; the only ordering rule is "a re-REGISTER never tears down an
  in-flight call," which holds because `acc_modify` doesn't drop calls. (DeepWiki RFC 8599 +
  user-stated deviated scenario: a silent-push topic may carry a regular token — already supported
  by the free-form param string.)

No new sign-off here; this is wiring `VoIPPushHandler`'s silent branch to `reRegister`.

---

## 9. Dual-INVITE dedup (VoIP push + persisted socket) — no double ring

Already scaffolded (`CallIdentity` + `CallRegistry`); this milestone makes it load-bearing:
- One CallKit UUID per logical call. Resolution: server-supplied UUID in push → else **UUIDv5 from
  SIP `Call-ID`** (CryptoKit) → else random. The INVITE over the socket carries the same `Call-ID`,
  so both paths compute the same UUID. PJSIP does **not** correlate push↔INVITE — the app must
  (confirmed by the official ipjsua `call_map` pattern).
- `CallRegistry.firstSeen(uuid:)` returns `true` once; the second arrival just binds its `CallID` /
  `Call-ID`. Whichever of push/INVITE lands first reports; the other no-ops.
- **TTL/eviction (PR #1 finding #4):** the router now evicts on terminal `.callState(.disconnected)`
  and on `CXEndCallAction`; additionally stamp entries and sweep > ~45s (push→INVITE window) so a
  push whose INVITE never arrives can't leak. This closes the documented `CallRegistry` gap.

No new sign-off; this is finishing the scaffolded design.

---

## 10. CallKit action → engine command map (full)

| `CXProviderDelegate` method | Engine command | Fulfillment rule |
|---|---|---|
| `perform: CXStartCallAction` | `makeCall(to:from:video:)` (maps `isVideo`) | configure audio; fulfill on `.confirmed` (stash) |
| `perform: CXAnswerCallAction` | `answer(call, 200)` | **fulfill on `.confirmed`** not immediately ([push][push]) |
| `perform: CXEndCallAction` | `hangup(call)` + `registry.remove` | fulfill immediately |
| `perform: CXSetHeldCallAction` | hold: re-INVITE sendonly; unhold: `PJSUA_CALL_UNHOLD` reinvite | fulfill on `.callMediaState` reflecting the change |
| `perform: CXSetMutedCallAction` | mute: disconnect capture→call slot / `pjsua_call set mute`; unmute: reconnect | fulfill immediately |
| `perform: CXPlayDTMFCallAction` | `pjsua_call_dial_dtmf2` (RFC 2833) | fulfill immediately |
| `perform: CXSetGroupCallAction` | local-mix: connect grouped calls' slots | fulfill after wiring |
| `didActivate:` / `didDeactivate:` | `activate/deactivateAudioDevice()` | n/a |
| `providerDidReset` | `hangupAll()` | n/a |

New engine methods needed: `setHold(_:)`, `resume(_:)`, `setMute(_:muted:)`, `sendDTMF(_:digits:)`,
video stream start/stop. All are simple pjsua1 calls run on the engine actor.

---

## 11. New / changed files (package layout)

`Sources/SwiftPJSUA/` (engine):
- **CallMediaInfo.swift** (new) — per-stream value type (§4).
- **PJSUAEvent.swift** — `.callMediaState` carries `[CallMediaInfo]`; `.incomingCall` gains
  `offeredVideo`/`from`; add `isFocus` where available.
- **PJSUACallbacks.swift** — `pjsuaOnCallMediaState` iterates `info.media[]`; build `[CallMediaInfo]`.
- **PJSUA+Calls.swift** — add `setHold`, `resume`, `setMute`, `sendDTMF`.
- **PJSUA+Video.swift** (new) — start/stop transmit, window getters, video-conf wrappers.
- **VideoWindowInfo.swift** (new) — value type mirroring `pjsua_vid_win_info` (geometry/show/slot).
- **PJSUA+Conference.swift** (new) — audio slot connect/disconnect; `isFocus` helper.

`Sources/SwiftPJSUAKit/`:
- **CallSessionRouter.swift** (new) — the event consumer + pending-action table + registry owner (§2).
- **CallKitController.swift** — full `CXProviderDelegate`; `supportsVideo = true`; forwards actions.
- **PendingCallAction.swift** (new) — small value type for the stash table.
- **CallRegistry.swift** — add timestamp + TTL sweep (§9).
- **VoIPPushHandler.swift** — wire the silent-push branch to `reRegister`.

(One primary entity per file, `+`-extension naming — per the Swift file-org convention.)

---

## 12. Sign-off checklist (the expensive-to-reverse calls)

1. **D-ROUTER** — add `CallSessionRouter` as the single `engine.events` consumer + CXAction
   correlation owner. *(Recommend: yes.)*
2. **D-MEDIA** — change `PJSUAEvent.callMediaState` from one `CallMediaStatus` to per-stream
   `[CallMediaInfo]` (audio+video, status, direction, conf slot / video window). *(Recommend: yes —
   this is the contract; cheapest to change now.)*
3. **D-VIDEO** — shape the full video surface now (CallKit `supportsVideo`/`hasVideo`/`isVideo`,
   engine window-id + video-conf connect); defer pixel rendering to the app. *(Recommend: yes.)*
4. **D-CONF** — primitives + thin router mapping (CallKit grouping → local mix; `isFocus` →
   server-side); **no** standalone `Conference` type yet. *(Recommend: yes.)*
5. **D-FULFILL** — answer/start fulfilled on `.confirmed` (not immediately); hold/unhold on the
   media-state change. Requires the pending-action table. *(Recommend: yes — Apple-mandated.)*

**Decision (signed off):** all five approved; **split** into **PR-a** (D-ROUTER + D-MEDIA +
audio/lifecycle/dedup + registry TTL + silent-push→reRegister — testable end-to-end on a 1:1 call)
and **PR-b** (D-VIDEO rendering surface + D-CONF conference primitives + CallKit grouping/focus
mapping, layered on the stable contract).

---

## 13. Implementation plan & test plan

Commits (Conventional, UPPERCASE TYPE; one logical unit each).

**PR-a** (`feat/callkit-lifecycle-and-media`, merged as #2):
1. `FEAT: per-stream CallMediaInfo media model` (engine types + callback iteration).
2. `FEAT: CallSessionRouter — consume engine events, drive CallKit, correlate actions`.
3. `FEAT: full CXProviderDelegate actions (answer/end/hold/mute/DTMF/start)` + engine commands.
4. `FEAT: registry TTL + terminal-state eviction (closes #4 gap)`.
5. `FEAT: silent-push re-REGISTER branch` + `DOCS: design doc + tech-debt`.

**PR-b** (`feat/video-and-conferences`):
1. `FEAT: engine audio conference primitives and focus detection` (`PJSUA+Conference.swift`).
2. `FEAT: engine video stream, window and video-conference wrappers` (`PJSUA+Video.swift`,
   `VideoWindowInfo.swift`, `makeCall(video:)`).
3. `FEAT: map CallKit grouping and video to engine conference/video primitives` (router `setGroup`
   + `groupAdjacency`, `supportsGrouping`/`supportsUngrouping`, `isVideo` → `makeCall(video:)`,
   controller `CXSetGroupCallAction` + `maximumCallsPerCallGroup = 5`).
4. `DOCS: roadmap + design + tech-debt as-built notes`.

Test plan (you run on Mac / iOS Simulator — this Linux box can't link iOS-only PJSIP):
- Engine unit tests: `CallMediaInfo` mapping from synthetic `pjsua_call_info`; `CallState`/status
  mappings; registry TTL sweep; UUIDv5 known-answer (already green).
- Kit unit tests: router fulfills a stashed answer only after `.confirmed`; dedup no-double-ring
  (push then INVITE, and INVITE then push); disconnect → `reportCall` reason mapping.
- Manual / integration (future, public SIP infra): 1:1 audio, hold/unhold, video, local 3-way,
  focus conference, locked-screen video.

Verification on this box is limited to symbol/enum spelling vs the shipped `pjsua.h`, citation
checks, and UUID known-answers. CI: none configured (Devin Review only). Documentation: brief
citations in code comments, verbose in `docs/Production-Roadmap.md` + a new `docs/Tech-Debt.md`.

---

## 14. Citations

CallKit / PushKit / audio (Apple, via sosumi.ai → developer.apple.com):
- [Making and receiving VoIP calls][mkvoip]
- [Responding to VoIP Notifications from PushKit][push]
- [CXProviderDelegate][cxdel] · [CXCallUpdate][cxcu] · [CXProviderConfiguration][cxcfg]
- [VoIP calling with CallKit (Speakerbox sample)][speakerbox] · [AVAudioSession][avas]

PJSIP / SIP (DeepWiki `pjsip/pjproject` + RFCs + your earlier Q&A sessions):
- PJSUA2 call/media lifecycle, hold/unhold, per-media iteration — DeepWiki Q&A (this session).
- Two conference models (local bridge vs RFC 4579 focus); video conf bridge — DeepWiki (this session).
- `on_reg_state2` fields; RFC 8599 push params; silent re-REGISTER — DeepWiki (this session).
- Dual-INVITE Call-ID dedup; ipjsua `call_map` — DeepWiki (this session).
- [PJSIP docs][pjsip] · RFC 8599 (SIP push) · RFC 4579 (conference as focus) · RFC 2833 (DTMF).

[mkvoip]: https://developer.apple.com/documentation/callkit/making-and-receiving-voip-calls
[push]: https://developer.apple.com/documentation/PushKit/responding-to-voip-notifications-from-pushkit
[cxdel]: https://developer.apple.com/documentation/callkit/cxproviderdelegate
[cxcu]: https://developer.apple.com/documentation/callkit/cxcallupdate
[cxcfg]: https://developer.apple.com/documentation/callkit/cxproviderconfiguration
[speakerbox]: https://developer.apple.com/documentation/callkit/voip-calling-with-callkit
[avas]: https://developer.apple.com/documentation/avfaudio/avaudiosession
[pjsip]: https://docs.pjsip.org/en/latest/
