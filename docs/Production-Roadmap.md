# swift-pjsua — Session Handoff & Production Roadmap

**Purpose.** This document hands off the design work behind the `swift-pjsua` skeleton to
an engineer who will take it to a production-ready solution. It records *what was decided,
why, and what remains*. It is intentionally thorough; read it once before touching the
code. It assumes no prior exposure to the conversation that produced the skeleton.

**What you are receiving (the season's artifacts):**

1. **`swift-pjsua/`** — the package (this is the thing to make production-ready). As of this
   iteration it is a **two-target** package (see §3.5, §6.1):
   - `Sources/SwiftPJSUA/` — the pure engine (imports only `PJSIP` + `Foundation`): the actor
     (`PJSUA.swift` + `PJSUA+Accounts/Calls/Audio.swift`), the executor
     (`Executor/PJSIPExecutor.swift`, `Executor/PJThreadRegistration.swift`), the callback bridge
     (`PJSUACallbacks.swift`), the event/value types (`PJSUAEvent.swift`, `CallState.swift`,
     `Transport.swift`, `CallID.swift`, `AccountID.swift`, `PushConfiguration.swift`,
     `PJSUAUsageError.swift`), and the C-interop leaf helpers (`Interop/`).
   - `Sources/SwiftPJSUAKit/` — the GUI layer (CallKit/PushKit/AVAudioSession/CryptoKit):
     `CallKitController.swift`, `VoIPPushHandler.swift`, and the dual-mode dedup
     (`CallIdentity.swift`, `CallRegistry.swift`, `UUID+Version5.swift`).
   - `Tests/` — pure-logic unit tests (CallState/Transport mapping, UUIDv5 known-answer, registry
     dedup). `Package.swift`, `README.md`, and this document under `docs/`.
2. **`Open-Source-SIP-VoIP-on-Apple-Platforms-A-Field-Survey-2026.md`** — a survey of the
   open-source SIP/VoIP landscape on Apple platforms (engines, wrappers, apps), with
   quality grades and the canonical iOS integration constraints. Background reading;
   especially its CallKit/PushKit section, which production work depends on.
3. **This document** and its companion, *SPM & Skills — Discovered Improvements*.

**The two repositories this builds on (same author):**
[`swift-pjsip`](https://github.com/laconicman/swift-pjsip) (the prebuilt PJSIP XCFramework
as an SPM binary package) and [`swift-pjsip-gen`](https://github.com/laconicman/swift-pjsip-gen)
(SwiftPM plugins that generate Swift conveniences from the headers `swift-pjsip` ships).

---

## 1. Goal and scope

Build an **idiomatic, Swift-only, async** front end to PJSIP for iOS, leveraging modern
Swift concurrency (`async/await`, actors), distributed as a Swift package. "Swift-only"
means *the wrapper is written in Swift against a C API* — no hand-written C++/Objective-C++
bridge to maintain.

The skeleton realizes the architecture and the hard parts (threading, the executor, the
callback bridge); it deliberately stubs the breadth (media, CallKit, full account/call
surface). Turning breadth-stubs into a shipping VoIP client is the work described in §7.

---

## 2. Engine choice: pjsua1 (C), not PJSUA2 (C++)

PJSIP exposes two high-level APIs: **pjsua** ("pjsua1", C) and **PJSUA2** (C++). Both are
vended by `swift-pjsip` (modules `PJSIP` and `PJSUA2`). We chose **pjsua1**, and this is
the cornerstone decision — do not casually reverse it.

**Why.** PJSUA2 delivers events by having you **subclass** its C++ classes (`Call`,
`Account`, `Buddy`, …) and override their **virtual methods**, which PJSUA2's runtime
calls polymorphically. Swift/C++ interop, as of today, **cannot inherit from a C++ class
or override its virtual methods** — see the official status page:
<https://www.swift.org/documentation/cxx-interop/status/>. Therefore a "Swift-only"
PJSUA2 wrapper still requires a C++ shim (a C++ subclass forwarding each virtual to a
C-callable callback). That *relocates* the C++ layer rather than removing it, defeating
the goal.

pjsua1's callbacks are **C function pointers** on a `pjsua_callback` struct; these bridge
to Swift with non-capturing closures (`@convention(c)`) and no C++ at all. pjsua1 is fully
supported and is in fact the substrate PJSUA2 is built upon, so this is not a "legacy"
choice — it is the stable, lower layer.

**The trade-off you are accepting.** pjsua1 automates *less* than PJSUA2 (you track
`pjsua_call_id` / `pjsua_acc_id` integers and own more state). The remedy is
[`swift-pjsip-gen`](https://github.com/laconicman/swift-pjsip-gen): generate the typed,
Swifty conveniences (and `CustomStringConvertible` for the C structs) that PJSUA2 would
otherwise hand you. That is a cleaner, lower-coupling architecture than inheriting a C++
object graph through a shim.

If a future requirement genuinely needs PJSUA2's built-in object model and the team
accepts owning a C++ shim, the honest package name would be `swift-pjsua2`, and `swift-pjsip`
already proves the C++ build/packaging is feasible.

---

## 3. The central design: a custom `SerialExecutor` on one dedicated thread

### 3.1 The one idea

> An actor runs its code on **its** executor, not on "the" Swift executor. Give the engine
> a custom `SerialExecutor` (SE-0392) backed by **one dedicated, PJLIB-registered POSIX
> thread**, make the engine an `actor` whose `unownedExecutor` is that executor, and then
> `await phone.makeCall(...)` performs the hop onto the PJSIP thread, runs the (blocking) C
> call there, and returns the value. No `withCheckedContinuation`, no GCD, no C++ shim.

This is implemented in `PJSIPExecutor.swift` (the executor + thread) and `PJSUA.swift` (the
actor). SE-0392: <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0392-custom-actor-executors.md>.

### 3.2 Why this is correct where GCD / the cooperative pool are wrong

A common claim (it appears in the DeepWiki dialog that informed this work) is that you
*cannot* use actors or `async/await` with PJSIP "because actors use GCD / the Swift
executor." **That is only true of the default executor.** The custom executor is precisely
the mechanism that makes modern concurrency correct here, for three reasons:

- **Stable thread identity.** It is the *same* OS thread for the engine's entire life,
  registered with PJLIB exactly once. The notorious GCD hazard — a recycled pool thread
  losing its registration and corrupting its `pj_thread_desc` — cannot occur.
- **Blocking is allowed here, by design.** PJSIP calls can block. That is fine on a thread
  dedicated to PJSIP; it is a *bug* on Swift's cooperative thread pool, which forbids
  blocking (it breaks the runtime's forward-progress guarantee). The custom executor is the
  correct home for blocking PJSIP work.
- **Registration is nearly free.** The thread that calls `pjsua_create()` (→ `pj_init()`)
  *becomes* PJLIB's registered main thread. Because `PJSUA.start()` runs on the executor
  thread and performs `pjsua_create()`, that thread is registered automatically. We still
  call `registerThisThread(...)` defensively (a no-op in the common case).

### 3.3 Thread registration mechanics (the trap to respect)

Any thread that calls a PJSIP function must be registered with PJLIB (`pj_thread_register`),
*except* threads PJSIP created itself (its workers) and the `pj_init` caller. PJLIB stores
per-thread bookkeeping **inside** the `pj_thread_desc` buffer you pass; that buffer is
`long[PJ_THREAD_DESC_SIZE]` (64 longs) and **must outlive the thread**. The classic iOS bug
is registering with a local that goes out of scope → PJLIB writes into freed memory → heap
corruption. `PJThreadRegistration.swift` owns the descriptor for the executor thread's
lifetime and guards registration with `pj_thread_is_registered()`. `pj_thread_is_registered`
must only be called **after** PJLIB is initialized (it reads TLS that `pj_init` sets up).

### 3.4 The callback bridge

pjsua1 callbacks carry no user-data pointer, so they cannot capture `self`. The skeleton
bridges them through **one file-private sink** (`pjsuaEventSink`, an
`AsyncStream<PJSUAEvent>.Continuation`). This is honest, not a hack: **pjsua is a
process-global library — there is exactly one instance — so a single sink is the correct
model.** `AsyncStream.Continuation` is `Sendable` and its `yield` is thread-safe, so
yielding from PJSUA's worker-thread callbacks is safe. The `nonisolated(unsafe)` global is
documented with its invariant (set once in `init` before `pjsua_start`; read-only after)
and a removal plan (replace if pjsua gains per-callback user-data). Callbacks translate to
plain `Sendable` events and **never touch actor or UI state directly** — that boundary
(`PJSUAEvent` as an `AsyncStream`) is the clean separation of concerns; preserve it.

### 3.5 `SwiftPJSUA` as the "support target"

A `.binaryTarget` cannot carry `linkerSettings`, so `swift-pjsip` documents PJSIP's required
system frameworks for the app to link by hand. The `SwiftPJSUA` source target carries those
`linkerSettings` itself, and SwiftPM propagates a linked target's settings to whatever links
the product — so depending on `SwiftPJSUA` auto-links the frameworks for the consuming app.
This is the "wrapper/support-target" pattern; it is purely additive (the linker dedups
duplicate `-framework` flags and dead-strips unused PJSIP objects). See `Package.swift`.

---

## 4. Threading rules (reference)

From the PJSIP iOS samples and PJLIB semantics; keep this table next to you while extending.

| Operation | Where it must run |
|---|---|
| Blocking PJSUA/PJSIP API calls (`make_call`, `hangup`, `answer`, `acc_set_registration`, `set_snd_dev`, `conf_connect`, `handle_ip_change`, …) | A **registered POSIX thread** (here: the executor thread). **Never** GCD or the main thread. |
| PJSUA callbacks (`on_call_state`, `on_incoming_call`, `on_call_media_state`, `on_reg_state2`) | Delivered on PJSUA's **own worker threads** (already PJLIB-registered). Safe to call PJSIP from inside them; **not** safe to touch actor/UI state. |
| UIKit / SwiftUI state updates | **Main thread** (`@MainActor`). Reaching MainActor *from* a PJSIP thread is fine — you are leaving PJSIP, not entering it. |
| `pjsua_schedule_timer2` (dispatch a one-off onto PJSUA's timer thread) | Any thread (it just locks a mutex and enqueues). See `PJ+ScheduleTimer.swift`. |

**The enter-vs-leave rule** resolves the apparent "no GCD" contradiction: GCD / Swift
concurrency must never be the thread that *enters* a PJSIP call; it is perfectly fine as the
destination you hop to when *leaving* one (e.g. updating `@MainActor` UI state from a
callback). Internalize this — it prevents most PJSIP-on-iOS threading bugs.

Canonical (minimal) Apple reference for the Swift + PJSUA threading pattern:
[`pjproject/.../ios-swift`](https://github.com/pjsip/pjproject/tree/master/pjsip-apps/src/pjsua/ios-swift).

---

## 5. Constraints & caveats (read before you build)

- **Not yet compiled or run.** The skeleton was written against `swift-pjsip`'s API but was
  never linked (no PJSIP module or iOS SDK in the authoring environment). Expect to fix
  small things on first build. Symbol spellings that vary by PJSIP version (e.g. `PJ_SUCCESS`
  vs the literal `0`, `PJSUA_INVALID_ID` vs `-1`, the `pjsua_call_info` media layout) are
  centralized or commented; verify them against the exact `swift-pjsip` build you consume.
- **iOS 17 minimum, iOS-only.** Custom actor executors (SE-0392) require the Swift 5.9
  concurrency runtime, which is **not back-deployed** below iOS 17. The package targets
  `.iOS(.v17)` and declares **no** macOS platform — `swift-pjsip` ships no macOS slice, so a
  `.macOS` target would not link (was gap G15; see §6.1). A macOS slice is a separate future
  session. If you must support iOS 15–16, keep `PJSIPExecutor`'s *thread* and
  `PJThreadRegistration`, drop the `SerialExecutor` conformance, and bridge with
  `withCheckedThrowingContinuation` enqueued onto the same dedicated thread (sketch in the
  package README). Guard every early exit so the continuation resumes **exactly once**.
- **`enqueue(_:UnownedJob)`** draws a deprecation warning under Swift 6 in favor of the
  owned `consuming ExecutorJob` form. Both compile; switch when convenient (commented in
  `PJSIPExecutor.swift`).
- **Single instance.** pjsua is process-global; create exactly one `PJSUA`. The single
  event sink depends on this.
- **Licensing.** `swift-pjsip` links a **GPL/commercial** PJSIP build (and GPLv3 bcg729 for
  G.729). A closed-source App Store app needs the commercial licenses. **G.729 is retained by
  decision** (Opus cannot transcode it — see §6.8). PJSIP licensing:
  <https://docs.pjsip.org/en/latest/overview/license_pjsip.html>. Settle this before shipping.

---

## 6. Decisions & invariants locked in this iteration

This iteration turned the single-target skeleton into the two-target package described in §3.5
and froze a set of decisions. They are recorded here so a future engineer does not re-litigate
them; the items tagged **M1 invariant** must be preserved as the call MVP (§7) is built out.

### 6.1 Package shape & naming
- **Two library targets in one package**, one-way dependency:
  `PJSIP (binary, from swift-pjsip) ← SwiftPJSUA (engine) ← SwiftPJSUAKit (CallKit/PushKit/UI) ← app`.
  `SwiftPJSUA` is pure: it imports only `PJSIP` + `Foundation`, with **no** CallKit, PushKit,
  AVAudioSession, UIKit or SwiftUI. `SwiftPJSUAKit` owns all of those. The boundary is
  compiler-enforced. Promote `SwiftPJSUAKit` to its own repository only if/when its release
  cadence diverges.
- **Naming** (SwiftPM-idiomatic, matches `swift-nio` / `swift-pjsip`): package & repo are
  lowercase-hyphen `swift-pjsua`; products & modules are UpperCamelCase `SwiftPJSUA` /
  `SwiftPJSUAKit`. The companion app is a separate repo, working name **Offhook** (`offhook`).
- **No "just in case" protocol abstraction.** The engine is concrete. The only inversion of
  control is the explicit audio-device API (§6.3), which exists because CallKit — not the engine —
  owns the audio-session lifecycle.
- **iOS-only; macOS dropped for now** (was gap G15). See §5.

### 6.2 `thread_cnt >= 1` — **M1 invariant** (was gap G1)
The custom `SerialExecutor` (§3) works *only* because PJSUA's own worker threads pump events and
fire the callbacks; the executor thread never calls `pjsua_handle_events`. If `thread_cnt` were
`0`, callbacks would silently never fire and every `await` would hang. The engine therefore does
**not** expose `thread_cnt` as a knob: `PJSUA.start()` hard-sets `cfg.thread_cnt = 1` and
`media_cfg.thread_cnt = 1` and guards with `precondition(cfg.thread_cnt >= 1)` + comment. Keep it
pinned; if tuning is ever added, clamp to `>= 1`.

### 6.3 Audio-device API + media wiring — **M1 invariant** (was gaps G3/G4)
Because `swift-pjsip` is built with `SETUP_AV_AUDIO_SESSION=0`, PJSIP does **not** own
`AVAudioSession`; CallKit/the app does. The contract that makes audio actually flow:
- The engine exposes `activateAudioDevice()` (→ `pjsua_set_snd_dev(default, default)`) and
  `deactivateAudioDevice()` (→ `pjsua_set_no_snd_dev()`), and **nothing else** touches the sound
  device. `SwiftPJSUAKit`'s `CXProviderDelegate` drives them from `didActivate` / `didDeactivate`,
  never from `makeCall`.
- The media-state callback connects the bridge: `pjsua_conf_connect(conf_slot, 0)` +
  `pjsua_conf_connect(0, conf_slot)` for `PJSUA_CALL_MEDIA_ACTIVE` **and**
  `PJSUA_CALL_MEDIA_REMOTE_HOLD` — matching upstream `pjsua_app.c`, so a remote hold keeps the
  slot bridged (resume needs no re-wiring, and any remote on-hold media still plays). This
  iteration wires the **single-`conf_slot`** case; iterating `media[]`/`media_cnt` for
  multi-stream calls is deferred (D1).
- **The engine does not filter media transitions.** `pjsuaOnCallMediaState` emits
  `PJSUAEvent.callMediaState(call:status:)` on **every** transition, carrying a
  `CallMediaStatus` (mirroring `pjsua_call_media_status`: `none`/`active`/`localHold`/
  `remoteHold`/`error`/`unknown`). Which transitions matter — UI for remote hold, stopping a
  ringback on active, etc. — is the **app's** decision, exactly as PJSUA2's `onCallMediaState`
  hands the app the full `CallMediaInfo` vector and lets it react. (Earlier this fired a
  status-less `.callMediaActive` only on active; that swallowed hold/resume and put policy in
  the core. Confirmed idiomatic via DeepWiki against PJSIP 2.17.)

#### The "two conference types"
The product must support **both** kinds of conference call PJSIP enables, which are an
*application-level* distinction, not two different bridges:
1. **Local mix** — the device hosts the conference: each remote leg is its own `pjsua_call`
   with its own `conf_slot`, and the app cross-connects the slots through the single
   `pjmedia_conf` bridge (`pjsua_conf_connect` between call slots, not just to slot 0).
2. **Server-hosted focus** — a conference-focus URI (RFC 4579) mixes centrally; the device
   holds **one** call leg to the focus and uses `pjsua_call_send_request` / the event package
   for roster/control. Media-wise it's an ordinary single-leg call.

Per DeepWiki, PJSIP exposes effectively **one** `pjmedia_conf` bridge, so media-state handling
is the same for both; the difference is how many legs exist and how their slots are wired.
Emitting the full media status per leg (above) is what lets the Kit/app implement either model
without engine changes. Multi-leg slot cross-connection is the `media[]` work deferred in D1.

### 6.4 SIP push / RFC 8599 — **M1 invariant** (was gap G6)
Push is the only viable wake path on iOS (a suspended app cannot keep REGISTER alive). The engine
attaches caller-controlled contact-URI parameters **before** `pjsua_acc_add`:
- `PushConfiguration` carries a **raw parameter string** plus a `scope` (`registerOnly` →
  `reg_contact_uri_params`, `allRequests` → `contact_uri_params`).
- `PushConfiguration.apns(teamID:bundleID:token:pushType:scope:)` builds the standard
  `;pn-provider=apns;pn-param={teamID}.{bundleID}.voip;pn-prid={token}` form — **but** because the
  string is free-form, the **deviated scenario** the product needs is supported directly: a silent
  push that overrides `pn-param` (e.g. drops `.voip`) and carries a *regular* APNs token is just a
  different string passed to `init(params:scope:)`.
- `reRegister(_:updatingPush:)` is the seam for a silent-push-triggered re-REGISTER with updated
  params; it rebuilds the account config from stored Swift state and calls `pjsua_acc_modify` +
  `pjsua_acc_set_registration`, so it doesn't race or tear down the VoIP-push answer path.

### 6.5 Dual-mode dedup (no double ring)
The app must answer both via VoIP push **and** as an always-on client over a persisted connection,
without two rings for one call. Both paths compute the **same** CallKit `UUID`:
1. a server-supplied UUID in the push payload wins when present; else
2. a deterministic **UUIDv5 of the SIP `Call-ID`** (the INVITE over the persisted connection
   carries the same `Call-ID`, so both paths agree); else
3. a random UUID (last resort, nothing to dedup on).
This lives in `SwiftPJSUAKit` (`CallIdentity` + the `CallRegistry` actor). The engine's only
obligation is to **surface the SIP `Call-ID`** on `incomingCall` / `callState` events — which it
now does.

**UUIDv5 corner case (byte order).** The fallback is RFC 4122 / RFC 9562 version-5 over the SIP
`Call-ID`, implemented in ~15 lines on CryptoKit (`UUID(version5:namespace:)`) rather than a
third-party library — both surveyed options (`doneservices/UUIDNamespaces`, `baarde/uuid-kit`)
are single-contributor and inactive, and `UUIDNamespaces` ships no LICENSE. The trap: the
namespace must be hashed in **network byte order**. Foundation's `UUID.uuid` tuple is already in
that order, so no byte-swap is needed — but a Microsoft `Guid` stores its first three fields
little-endian, so interop with a value derived from a .NET GUID would need a swap first. The
known-answer test pins `UUIDv5(DNS, "www.example.com") = 2ed6657d-e927-568b-95e1-2665a8aea6a2`
(verified via Python `uuid5` + a hand SHA-1; both an earlier `...ff66` literal and an
auto-review's `...a1f2` suggestion were wrong).

**`CallRegistry` lifetime (deferred, tracked — was review finding #4).** The dedup map has no
TTL/eviction yet; entries are dropped only on explicit `remove(uuid:)`. A push whose INVITE never
arrives leaks an entry. M1 hardening: evict on terminal call state, bound the map, and/or stamp
entries with a creation time and sweep past a short TTL (longer than the push→INVITE window).
Marked with `// TODO:` at the `entries` declaration.

### 6.6 Cancelled / disconnected calls (was gap G4)
A caller CANCEL before answer surfaces as `on_call_state` → `PJSIP_INV_STATE_DISCONNECTED` with a
SIP status (e.g. 487). The `callState` event now carries `lastStatus`, so the Kit can withdraw the
CallKit call and dismiss the system call screen instead of leaving a stuck ring.

### 6.7 Re-entrancy / deadlock discipline (was gap G2)
Three layers, strongest first:
1. **Structural / compile-time.** The C callbacks are file-private free functions whose only
   capability is `pjsuaEventSink.yield(...)`. They hold no reference to the actor, so they cannot
   call engine methods or `await` it — re-entrancy is impossible by construction.
2. **Debug runtime.** `assertOnRegisteredPJThread()` (`assert(pj_thread_is_registered() != 0)`)
   catches a future maintainer who runs a callback off a non-PJLIB thread.
3. **Docs / lint.** A file-header invariant note on `PJSUACallbacks.swift`; a SwiftLint custom rule
   flagging `await` / `Task {` in that file is possible but low-ROI given (1).
See deferral D2 for the thread-local guard this substitutes for.

### 6.8 Licensing: G.729 retained — **M1 invariant** (was gap G13)
`swift-pjsip` bundles **bcg729 (G.729, GPLv3 + patents)**. The product needs G.729 on the wire
(Opus cannot transcode it), so `PJMEDIA_HAS_BCG729 1` **stays**. This is a deliberate decision: a
shipping closed-source app must carry the PJSIP commercial license **and** G.729 terms. No code
change; the obligation note stands.

### 6.9 Deferrals (intentional, tracked)
- **D1 — `media[]`/`conf_slot` iteration.** MVP wires a single `conf_slot`; multi-stream
  (`tupleToArray` over the imported `media` tuple) lands with video / multi-call in §7 M3.
- **D2 — thread-local `inPJSIPBlockingCall` re-entrancy flag.** Substituted for now by the
  structural boundary + `assert(pj_thread_is_registered() != 0)` (§6.7). Revisit if a blocking
  path ever needs to detect re-entry from the same thread.

---

## 7. Production roadmap (the actual remaining work)

The skeleton's `// TODO`s are, collectively, "make it a real VoIP client." Suggested
milestone order — each builds on the last.

### Milestone 1 — Call MVP with CallKit, PushKit, and audio
This is the largest and most important chunk. Without it you do not have an iOS VoIP app.

**Scaffolded in this iteration** (see §6): the engine audio-device API + `conf_connect`-on-media
(§6.3); `Call-ID`/`lastStatus` on events (§6.5/§6.6); the RFC 8599 push config + `reRegister` seam
(§6.4); and `SwiftPJSUAKit` skeletons — `CallKitController` (audio-session lifecycle + deduplicated
`reportNewIncomingCall`) and `VoIPPushHandler` — plus the dual-mode dedup (`CallIdentity` /
`CallRegistry`). What remains for M1 is the breadth below: AVAudioSession category config, the full
`CXAction` mapping, and the real push payload contract.

- **AVAudioSession + audio path.** `conf_connect` on media-active in `pjsuaOnCallMediaState` is
  done for the single-`conf_slot` case (extend to `media[]`/`media_cnt` per D1). Still to do:
  configure `AVAudioSession` (`.playAndRecord`, `.voiceChat`) in the app/Kit.
- **CallKit.** `CallKitController` wires the audio lifecycle (`didActivate`/`didDeactivate` →
  engine `activate/deactivateAudioDevice()`) and a deduplicated incoming-call report. Still to do:
  map `CXAnswerCallAction`/`CXEndCallAction`/`CXSetMutedCallAction`/`CXSetHeldCallAction` onto
  `PJSUA.answer`/`hangup`/mute/hold, and full provider configuration. Audio is started/stopped in
  `didActivate`/`didDeactivate`, **not** when `makeCall` returns. Docs:
  <https://developer.apple.com/documentation/callkit/cxprovider>.
- **PushKit (the contract that terminates your app if you get it wrong).** `VoIPPushHandler` is a
  skeleton (payload schema is a placeholder). Register a
  `PKPushRegistry` for `.voIP`; declare the VoIP background mode in `Info.plist`. The handler
  adopts the **`async` variant** `pushRegistry(_:didReceiveIncomingPushWith:for:) async`
  (iOS 11+, modern API at our iOS 17 floor) instead of the completion-handler form; it
  `guard`s `type == .voIP` and `await`s `CallKitController.reportIncomingCall(...)`. You
  **must** call `CXProvider.reportNewIncomingCall(...)` before the method returns (i.e. before
  the async task completes), or iOS terminates the app; repeated failures revoke the VoIP
  token. Do SIP/network work *after* reporting. Put caller identity in the push payload so the
  call UI can ring without a network round-trip. Docs:
  <https://developer.apple.com/documentation/pushkit/pkpushregistrydelegate>; WWDC19
  "Advances in App Background Execution" <https://developer.apple.com/videos/play/wwdc2019/707/>.
  - *Future (iOS 26.4+):* migrate to
    `pushRegistry(_:didReceiveIncomingVoIPPushWith:metadata:withCompletionHandler:)` and honour
    `PKVoIPPushMetadata.mustReport` (`false` when foreground / a call is already active / the
    push is late) to skip a redundant CallKit report — directly useful for the dual-mode
    no-double-ring path. Too new for the current floor; tracked as a `// TODO` in
    `VoIPPushHandler`.
  - Edge cases (mainland China bans CallKit; the private `unrestricted-voip` entitlement;
    `CXProvider.isSupported` is false on Catalyst) are detailed in the field-survey artifact.
- **Reference to study:** [VialerSIPLib](https://github.com/VoIPGRID/VialerSIPLib)'s
  `CallKitProviderDelegate` + `VSLCallManager` (archived, but the best open iOS CallKit-on-PJSIP
  wiring to read).

### Milestone 2 — Registration robustness & network changes
- Parse `on_reg_state2` properly (`info.pointee.cbparam.pointee.code`/`.expiration`);
  surface real registration state; handle 401/403, retry/backoff, multiple accounts.
- **IP/network change handling.** Drive `pjsua_handle_ip_change` (and STUN refresh) from
  `NWPathMonitor`. Mind the **SRV-vs-A-record** gotcha: some providers (e.g. 1&1) don't
  publish SRV records, so an SRV-only resolver fails to register — fall back to plain
  address resolution. (Documented in [libphone](https://github.com/oliverepper/libphone)'s
  provider notes.)
- TLS (the `swift-pjsip` build uses native Darwin SSL) and SRTP policy.

### Milestone 3 — Call features
- DTMF (RFC 2833 and/or SIP INFO), hold/unhold, mute, speaker routing, multiple/concurrent
  calls, call transfer, early media. Expand the `PJSUA` actor surface accordingly.

### Milestone 4 — Hardening, testing, docs
- **Concurrency:** migrate `enqueue` to `ExecutorJob`; add `withTaskCancellationHandler` so
  a cancelled `Task` maps onto a PJSIP hangup; consider an explicit actor-isolated state
  machine; choose an `AsyncStream` buffering policy deliberately.
- **Testing:** unit-test the executor (jobs run on the dedicated thread; serialization
  order; `stop()` drains cleanly), and lifetimes (thread + `pj_thread_desc`; the continuation
  finishes). PJSIP itself is hard to unit-test without a server — stand up a local SIP server
  (Asterisk/Kamailio, or a loopback PJSIP account) for integration tests.
- **Ergonomics via codegen:** use [`swift-pjsip-gen`](https://github.com/laconicman/swift-pjsip-gen)
  to generate typed facades and `CustomStringConvertible` for the pjsua structs — this is the
  pjsua1 answer to "PJSUA2 automates more."
- **Logging:** route PJSIP logs to OSLog (a log callback or generated helper); the
  `#fileID`/`#line` timer wrapper is in `PJ+ScheduleTimer.swift`.
- **Privacy manifest:** PJSIP touches a required-reason API (system boot time for its
  timers); declare it in the **app's** `PrivacyInfo.xcprivacy` (the binary can't carry one).
  See `swift-pjsip`'s README.
- **DocC** for the public API.

---

## 8. References

**This project's repos**
- `swift-pjsip` — <https://github.com/laconicman/swift-pjsip>
- `swift-pjsip-gen` — <https://github.com/laconicman/swift-pjsip-gen>
- `buildPJwVideoPatch` (origin of the build scripts) — <https://github.com/laconicman/buildPJwVideoPatch>

**PJSIP**
- Docs — <https://docs.pjsip.org> · iOS build — <https://docs.pjsip.org/en/latest/get-started/ios/build_instructions.html> · PJSUA2 building — <https://docs.pjsip.org/en/latest/pjsua2/building.html> · License — <https://docs.pjsip.org/en/latest/overview/license_pjsip.html>
- Apple Swift + PJSUA sample — <https://github.com/pjsip/pjproject/tree/master/pjsip-apps/src/pjsua/ios-swift>

**Swift concurrency & interop**
- SE-0392 Custom Actor Executors — <https://github.com/swiftlang/swift-evolution/blob/main/proposals/0392-custom-actor-executors.md>
- Swift/C++ interoperability status — <https://www.swift.org/documentation/cxx-interop/status/>

**Apple iOS VoIP integration**
- PushKit `PKPushRegistryDelegate` — <https://developer.apple.com/documentation/pushkit/pkpushregistrydelegate>
- CallKit `CXProvider` — <https://developer.apple.com/documentation/callkit/cxprovider>
- WWDC19 707, Advances in App Background Execution — <https://developer.apple.com/videos/play/wwdc2019/707/>

**Open-source references worth studying**
- Telephone (Clean Architecture, macOS PJSIP softphone) — <https://github.com/64characters/Telephone>
- VialerSIPLib (iOS CallKit-on-PJSIP wiring; archived) — <https://github.com/VoIPGRID/VialerSIPLib>
- Oliver Epper — libphone <https://github.com/oliverepper/libphone>, SwiftSIP <https://github.com/oliverepper/SwiftSIP>, "Managing binary dependencies for Swift" <https://oliver-epper.de/posts/managing-binary-dependencies-for-swift/>
- Linphone SDK (the major non-PJSIP alternative) — <https://github.com/BelledonneCommunications/linphone-sdk>

**Companion artifacts (this season)**
- *Open-Source SIP/VoIP on Apple Platforms — A Field Survey (2026)* — landscape & canonical iOS constraints.
- *SPM & Skills — Discovered Improvements* — the companion to this document.
