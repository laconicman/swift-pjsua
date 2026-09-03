# Tech debt & tracked deferrals

A register of known shortcuts, deferrals, and obligations in `swift-pjsua`. Each item is
intentional and tracked — not an accidental gap. The **roadmap** (`Production-Roadmap.md`) holds the
forward-looking milestone plan; this file is the backward-looking "what we knowingly owe."
Code-level markers use `// TODO:` / `// FIXME:` and reference the IDs below.

Status legend: **open** (owed), **deferred-PR-b** (scheduled for the video/conference PR),
**obligation** (a standing constraint, not codework).

---

## TD-1 — `swift-pjsip` dependency tracks a branch, not a tag · open
`Package.swift` depends on `swift-pjsip` at branch `main`, so a resolve can pull a moving binary and
builds aren't reproducible. Pin to a semantic-version tag once `swift-pjsip` cuts a release
(binary `.xcframework` distribution should be versioned — see the org's *XCFramework distribution*
knowledge). Until then, `Package.resolved` is the only thing pinning the revision.
- Refs: <https://www.swift.org/documentation/package-manager/>; SemVer <https://semver.org/>.

## TD-2 — push payload schemas are placeholders · open
Both push entry points parse a **placeholder** schema that must be matched to the real server
contract before shipping:
- VoIP (`VoIPPushHandler.pushRegistry(_:didReceiveIncomingPushWith:for:)`): `call_uuid`,
  `sip_call_id`, `from`.
- Silent (`VoIPPushHandler.handleSilentPush(_:account:updatingPush:)`): `action == "reregister"`.

The dedup logic that consumes them (`CallIdentity` / `CallRegistry`) is real; only the field names
are provisional. A server UUID in the VoIP payload is preferred over the `Call-ID` UUIDv5 fallback
(see roadmap §6.5), so the payload contract directly affects no-double-ring correctness.
- Refs: RFC 8599 <https://www.rfc-editor.org/rfc/rfc8599>; PushKit
  <https://developer.apple.com/documentation/pushkit/pkpushregistrydelegate>.

## TD-3 — event-stream buffering drops oldest under burst · open
`makePJSUAEventStream()` uses `AsyncStream` `.bufferingNewest(64)`. If the single router consumer
ever falls far behind a callback burst, the **oldest** events are discarded. A dropped
`.callState(.disconnected)` could in principle strand a CallKit call — partially mitigated because
the `CallRegistry` TTL sweep (TD/roadmap §6.5) withdraws stale *pending* reports, but a *bound*
call relies on receiving its terminal event. Revisit the policy (unbounded vs. explicit
back-pressure) during M4 hardening; the consumer is `await`-driven on the engine actor so sustained
overflow is unlikely in practice.
- Refs: <https://developer.apple.com/documentation/swift/asyncstream/continuation/bufferingpolicy>.

## TD-4 — `CXProvider` captured by a `Sendable` actor · open (documented-safe)
`CallSessionRouter` is an `actor` (hence `Sendable`) but holds a `CXProvider`, which is **not**
`Sendable`. We rely on Apple documenting the provider's *report* methods
(`reportNewIncomingCall`, `reportOutgoingCall(with:…)`, `reportCall(with:endedAt:reason:)`) as
callable from any thread, and we only ever touch the provider from the router actor's executor.
If a future Swift-6 strict-concurrency pass flags this, the fix is an explicit `@unchecked Sendable`
wrapper around the provider with a comment pointing here — not loosening the actor.
- Refs: <https://developer.apple.com/documentation/callkit/cxprovider>.

## TD-5 — D2: thread-local re-entrancy guard not implemented · open (substituted)
The roadmap's D2 (`inPJSIPBlockingCall` thread-local flag) is **not** built. It is substituted by
the stronger *structural* guarantee — the C callbacks hold no actor reference, so they cannot
re-enter a blocking `pjsua_*` call — plus a debug `assert(pj_thread_is_registered() != 0)`
(`PJSUACallbacks.swift`). Revisit only if a blocking path ever needs to detect same-thread re-entry.
- Refs: roadmap §6.7.

## TD-6 — video & conference surface · shipped-PR-b, with tail deferrals
PR-a shipped the per-stream media **contract** (`CallMediaInfo` carries video window/capture) and
`CXProviderConfiguration.supportsVideo = true`. **PR-b shipped** the engine + Kit surface:
- engine video wrappers — `PJSUA+Video.swift` (`pjsua_call_set_vid_strm` start/stop transmit,
  add/remove, change-capture-device, send-keyframe; `pjsua_vid_win_*` getters/show via
  `VideoWindowInfo`; `pjsua_call_get_vid_conf_port` + `pjsua_vid_conf_connect/disconnect`);
  `makeCall(to:from:video:)`;
- conference primitives — `PJSUA+Conference.swift` cross-connects conf slots **between legs**
  (`connectAudio(_:and:)` / `disconnectAudio(_:and:)`) and detects `;isfocus`
  (`isConferenceFocus(_:)`) for RFC 4579 server-hosted focus;
- CallKit grouping — `CallSessionRouter.setGroup(_:)` maps `CXSetGroupCallAction` to the bridge with
  a symmetric `groupAdjacency` map (N-way local mixing), `CXCallUpdate.supportsGrouping` /
  `supportsUngrouping`, `maximumCallsPerCallGroup = 5`.

Still **deferred** (tail):
- **app-side pixel rendering** (MetalKit/`UIView`) — lives in the Offhook app, not the SDK;
- **video-conference layout** — multi-source compositing beyond the primitive `connectVideo`
  (`PJMEDIA_VID_CONF_LAYOUT_*`); only the default single-source connect is wired today;
- **event-surfacing of `isFocus`** — exposed as the engine accessor `isConferenceFocus(_:)` rather
  than on `PJSUAEvent`, to keep the event/`CallMediaInfo` contracts stable (see TD-13). Promote to an
  event field only if the app proves it needs push-style focus notification.
- Refs: roadmap §7 M3; RFC 4579 <https://www.rfc-editor.org/rfc/rfc4579>;
  <https://developer.apple.com/documentation/callkit/cxsetgroupcallaction>.

## TD-7 — G.729 licensing · obligation
`swift-pjsip` bundles **bcg729 (G.729, GPLv3 + patents)** with `PJMEDIA_HAS_BCG729 1`. The product
needs G.729 on the wire (Opus cannot transcode it), so it stays. A shipping closed-source app must
carry the **PJSIP commercial license** *and* **G.729 patent terms**. No codework — a standing
obligation on the release.
- Refs: roadmap §6.8; <https://github.com/BelledonneCommunications/bcg729>.

## TD-8 — iOS-only; no macOS slice · open
`Package.swift` declares `.iOS(.v17)` only, matching the iOS-only `swift-pjsip` binary. This means
the executor and pure-logic types **cannot be unit-tested headlessly on a Mac/Linux CI** — every
target transitively imports the iOS-only framework, so tests run only on the iOS Simulator. A macOS
slice (in `swift-pjsip` first, then here) would unlock headless executor tests; deferred to a
dedicated session.

**What the macOS slice inherits from pjmedia's CoreAudio backend.** Read before designing any Mac
audio UI — `coreaudio_dev.m` behaves materially differently on macOS than on iOS once EC is on,
because EC *is* the VoiceProcessingIO (VPIO) unit. Verified against pjproject master `b8b988b02`
on 2026-08-11:

- **Device selection is ignored whenever VPIO is active.** `create_audio_unit()` sets
  `kAudioOutputUnitProperty_CurrentDevice` only in the `!ec_enabled` branch (setting it under VPIO
  makes the later buffer-size query fail with `kAudioUnitErr_InvalidProperty`). So on macOS you get
  EC **or** a working device picker, not both — the call runs on the system default in/out. This is
  a product decision for a Mac softphone, where users expect to choose a mic, not a bug to work
  around.
- **The warning under-reports it.** The `"audio device id settings are ignored when using VPIO"`
  log fires only when `rec_id` **and** `play_id` are *both* non-default. Set just one — a specific
  mic, default speaker — and the choice is silently dropped with no log line at all.
- **Stereo silently turns EC off.** `ca_factory_create_stream()` forces `ec_enabled = PJ_FALSE`
  when `channel_count > 1` on Mac ("temporarily disabled … due to recording sound artefacts"). Any
  Mac path that asks for stereo capture gets no VPIO — and therefore none of the VPIO-conditional
  behaviour above or below.
- **Deployment floor decides which OS-version guards bite.** pjmedia gates macOS 14 / iOS 17 API
  behind an SDK check plus a runtime `@available`. Target macOS 14+ and the runtime check is always
  true; target 12/13 and the feature silently no-ops. First live instance: the configurable VPIO
  other-audio ducking we contributed upstream ([#5178](https://github.com/pjsip/pjproject/pull/5178),
  filed 2026-08-11) — with a macOS 14+ floor a Mac slice can have voice-activity-driven ducking;
  below it, calls keep the old whole-call duck. See
  [`Upstream/pjproject-5178-coreaudio-vpio-other-audio-ducking.md`](../Upstream/pjproject-5178-coreaudio-vpio-other-audio-ducking.md).
- **Nothing Apple-specific arrives by default — we must ask for it.** At the maintainer's request
  #5178 (merged 2026-08-17) ships with `PJMEDIA_AUDIO_DEV_COREAUDIO_ADVANCED_DUCKING` defaulting
  to `0`, switched on upstream only inside `config_site_sample.h`'s `PJ_CONFIG_IPHONE` block —
  which is **iOS-only**, and confirmed deliberate ("I suppose we can leave MacOS as it is").
  That is not a one-off: macOS configures the CoreAudio backend through `aconfigure`'s `*darwin*`
  branch while iOS configures it through `config_site.h`, so anything upstream enables "for Apple"
  by way of `PJ_CONFIG_IPHONE` misses a Mac slice entirely. The fix is structural, and it lives in
  `swift-pjsip`: set feature macros explicitly per slice in its `scripts/config_site.h` rather than
  inheriting upstream defaults. See `swift-pjsip/docs/ARCHITECTURE.md` §11.

- Refs: roadmap §6 (G15 resolution), §6.3 (audio-device API);
  `TASK-code-swift-pjsip-macos-slice.md` §5; `swift-pjsip/docs/ARCHITECTURE.md` §11.

## TD-9 — `on_reg_state2` diagnostics are minimal · open
The registration callback surfaces `active` / `statusCode` / `expiration` but **not** the SIP reason
phrase, nor 401/403 auth-failure differentiation or retry/backoff. Sufficient for M1; M2 adds
robust registration handling.
- Refs: roadmap §7 M2; <https://docs.pjsip.org/en/latest/>.

## TD-10 — newer PushKit metadata API (iOS 26.4+) · open
When the deployment floor allows, migrate to
`pushRegistry(_:didReceiveIncomingVoIPPushWith:metadata:withCompletionHandler:)` and honour
`PKVoIPPushMetadata.mustReport` (`false` when foreground / a call is already active / the push is
late) to skip a redundant CallKit report — directly useful for the dual-mode no-double-ring path.
Tracked as a `// TODO` in `VoIPPushHandler`; too new for the iOS 17 floor.
- Refs: <https://developer.apple.com/documentation/pushkit/pkpushregistrydelegate>.

## TD-11 — account credentials live in engine-actor memory · **partly discharged 2026-07-17**
The Swift-side copy is gone: `AccountParameters` now retains a ``CredentialStore`` and the secret
is fetched on demand at `addAccount`/`reRegister` (see `docs/Configuration-Design.md` §4, §6).
**Still open:** pjsua itself deep-copies the credential into the account pool *and* the shared
auth session, alive until `pjsua_acc_del` and never zeroed (`pj_pool_t` is a bump allocator with
no scrub API). Removing that needs `cred_count = 0` plus the `on_auth_challenge` hook, which is
**PJSIP 2.17+** (`db3cfdee`) — gated on the version bump. Original entry follows.


`reRegister(_:updatingPush:)` rebuilds the account config from `AccountParameters` retained in the
`PJSUA` actor — which includes the SIP **password** in plaintext in process memory. Acceptable for a
skeleton, but a production app should hold credentials in the Keychain and supply them to the engine
on demand rather than retaining them. Flag for the Offhook app's credential design.
- Refs: <https://developer.apple.com/documentation/security/keychain-services>.

## TD-12 — no CI build gate · open
The repo has **no GitHub Actions**; compilation and unit tests are verified on the maintainer's Mac
(iOS Simulator), and Devin Review is the only automated check on a PR. Consider an Xcode-Cloud /
macOS-runner `xcodebuild -destination 'platform=iOS Simulator,...'` job once the build is stable so
regressions are caught pre-merge.
- Refs: <https://developer.apple.com/documentation/xcode/building-and-running-an-app>.

## TD-13 — `isFocus` / conference state kept off the event contract · open (deliberate)
PR-b deliberately did **not** widen `PJSUAEvent` or `CallMediaInfo` to carry conference state.
`;isfocus` is read on demand via the engine accessor `isConferenceFocus(_:)`, and local-conference
membership lives in the Kit router's `groupAdjacency` map — not in an engine event. Rationale: the
engine↔Kit event/media contracts are the most expensive thing to reshape, and nothing in the current
design needs focus *pushed* (the router queries it when mapping `CXSetGroupCallAction`). Revisit only
if the app needs unsolicited focus-change notification (e.g. a server promoting a 1:1 to a focus
mid-call); the fix is a new `PJSUAEvent` case, additively. Avoids the "just-in-case abstraction" the
maintainer has been burned by.
- Refs: design doc §6/§7 "As-built (PR-b)"; RFC 4579 <https://www.rfc-editor.org/rfc/rfc4579>.

## TD-14 — STUN/ICE/TURN and DNS are in the binary but unexposed by the engine · open (M2)
`swift-pjsip`'s `config_site.h` disables neither `pjnath` (ICE/STUN/TURN) nor `pjlib-util`
DNS, so the prebuilt binary already supports both — but the `PJSUA` actor surfaces no way to
configure them. The user-facing connectivity goals are therefore pure engine-surface work, not
a rebuild:
- **STUN:** `pjsua_config.stun_srv_cnt` / `stun_srv[]`; ICE via `pjsua_media_config.enable_ice`
  and per-account `pjsua_acc_config.ice_cfg`; TURN via `turn_cfg`.
- **DNS:** async SRV resolution via `pjsua_config.nameserver_cnt` / `nameserver[]`; a *custom*
  resolver via `pjsip_endpt_set_resolver` over a `pj_dns_resolver`.
- Mind the **SRV-vs-A fallback** (roadmap §7 M2): some providers publish no SRV records, so an
  SRV-only path fails to register — fall back to plain A/AAAA resolution.
- Refs: roadmap §7 M2; pjsua.h; DeepWiki *NAT Traversal (ICE, STUN, TURN)*.

## TD-15 — pure-logic types are not headlessly testable · open (relates TD-8, TD-12)
Because every target transitively imports the iOS-only `PJSIP`, even PJSIP-independent logic
runs only on the iOS Simulator. The genuinely pure pieces — `UUID(version5:)` and
`CallIdentity` (Foundation/CryptoKit only) — could move to a leaf module with **no**
`import PJSIP`, so the UUIDv5 known-answer and identity-resolution tests run on macOS/Linux CI.
The PJSIP-typed logic (`CallRegistry` via `CallID`, the `CallState`/`Transport`/`CallMediaInfo`
mappings) still needs the macOS slice (TD-8) to test headlessly. Splitting the leaf module is
cheap, low-coupling, and unblocks a fast CI signal independent of the simulator.
- Refs: TD-8; TD-12; <https://www.swift.org/documentation/server/guides/testing.html>.

## TD-16 — no outbound-proxy surface; big INVITEs can fragment on UDP · open (found live 2026-07-04)
Integration testing against Flexisip (`sip.linphone.org`) surfaced a transport trap: the proxy
challenges INVITE (407), and the authenticated resend (~1.6 kB of SDP + digest) exceeds
`PJSIP_UDP_SIZE_THRESHOLD` (1300). pjsip's RFC 3261 §18.1.1 UDP→TCP auto-switch does **not**
apply to that resend (the reused `tdata` keeps its already-resolved UDP destination), so the
request fragments on UDP and is dropped silently — the call just never confirms. Mitigations
shipped in the engine: `start()` now opens a TCP listener alongside a UDP primary (enables the
size switch where it does apply, and `;transport=tcp` registrars); the reliable per-call fix is
an explicit `;transport=` param in the dial URI. The *proper* account-level fix is exposing
`pjsua_acc_config.proxy[]` (outbound proxy / route set) so every request for an account follows
the proxy's transport — standard softphone practice (Linphone, Telephone). Engine surface only;
no rebuild needed.
- Refs: RFC 3261 §18.1.1; `sip_config.h` `PJSIP_UDP_SIZE_THRESHOLD`/`PJSIP_DONT_SWITCH_TO_TCP`;
  pjsua.h `pjsua_acc_config.proxy`.

## TD-17 — SIP transaction timers unexposed; the "32 seconds" is magic to consumers · open
A silent registrar surfaces as a 408 only after **PJSIP_TD_TIMEOUT = 32 000 ms** — RFC 3261's
Timer B/F (64 × T1, T1 = 500 ms). pjsip exposes all of it at **runtime** — `pjsip_cfg()->tsx`
(`t1`, `t2`, `t4`, `td`, settable before init) — but the engine surfaces none of it, so
consumers either hard-code waits that outlast 32 s (the Offhook test harness uses 40 s) or
can't tighten failure detection on flaky networks (a mobile app may want td ≈ 8–10 s + its own
retry). Discharge: a `Configuration.transactionTimeout` (or a narrow `timers` sub-struct)
applied via `pjsip_cfg()` inside `start()` before `pjsua_init`; document the RFC default.
- Verified vs master 2026-07-04: **no** per-account/per-call/per-regc knob exists
  (`REGC_TSX_TIMEOUT` is a fixed 33 000 ms, `sip_reg.c:50`). Two refinements: (1) **writing
  `pjsip_cfg()->tsx.*` after init is a no-op** — values are cached in statics
  (`sip_transaction.c:125-133`); post-init changes require `pjsip_tsx_set_timers()` (#2781),
  and already-scheduled timers keep their old values either way. Our "before `pjsua_init`"
  placement is load-bearing — keep it. (2) master has per-INVITE-transaction
  `pjsip_tsx_set_timeout()` (`sip_transaction.c:2035`) — a finer-grained option if we ever
  want per-call timeouts instead of a global.
- Refs: RFC 3261 §17.1.1.2 (Timer B) / §17.1.2.2 (Timer F); `sip_config.h` `pjsip_cfg_t.tsx`,
  `PJSIP_T1_TIMEOUT`/`PJSIP_TD_TIMEOUT`.

## TD-28 — `linkerSettings` is short three frameworks, which blocks app-hosted tests · open (found 2026-09-03)
> Numbered 28, not 26: `feat/call-lifecycle-observation` (PR #11) already defines a different
> TD-26 (discarded `jbuf` statistics) and a TD-27. The file has carried duplicate IDs before —
> there were two TD-22s — so check the open branches before claiming the next number.
`SwiftPJSUA` carries the `-framework` flags on behalf of everything that links the binary (the
support-target pattern, roadmap §3.5) — and the list is incomplete. `libpjproject.a` contains
`ios_opengl_dev.o`, whose `GLView` needs **OpenGLES** and **UIKit**, and raw **Metal** classes
(`MTLRenderPipelineDescriptor`, `MTLTextureDescriptor`) that `MetalKit` alone does not bring.

- **Why nobody has hit it:** a SwiftUI *app* links UIKit and Metal anyway, so the app target
  resolves them by accident. The gap only shows where the binary is linked without an app
  around it.
- **What it blocks:** app-hosting `offhook`'s test bundle, which is the only route to running
  XCTest on a **device** (Apple forbids tool-hosted testing on device destinations, and a
  SwiftPM package test target cannot declare a host app at all). Verified 2026-09-03: adding
  the host app generates correctly and then fails to link on those symbols.
- **Fix:** add `OpenGLES`, `UIKit` and `Metal` to `linkerSettings`, or stop compiling the
  OpenGL video device into the artifact — it is dead weight next to the VideoToolbox/Metal
  path we actually use, and `swift-pjsip`'s `config_site.h` is where that is decided.
- **Not sufficient on its own.** Hosting also puts the tests inside a process whose app already
  constructs a `PJSUA` and installs the global event sink, and pjsua is process-global. See the
  playbook.
- Refs: [`offhook/docs/Testing-Playbook.md`](../../offhook/docs/Testing-Playbook.md) §2.

## TD-25 — `pjsip_regc` is mostly mutable in place; our mental model of `acc_modify` was too coarse · open (informational)
From a DeepWiki deep consult 2026-08-17, verified against `sip_regc.h` / `sip_reg.c`. Only **five**
pieces of `pjsip_regc` state have no public setter and therefore genuinely force a rebuild:
**registrar/target URI, From, To, Call-ID, CSeq** (plus header *removal*, since
`pjsip_regc_add_headers()` is additive-only — the `pj_list_init` reset is commented out at
`sip_reg.c:544-545`). Contact list, expiry, route set, credentials, auth session/prefs, transport
selector and Via sent-by all have setters (`pjsip_regc_update_contact`, `_update_expires`,
`_set_route_set`, `_set_credentials`, `_set_auth_sess`, `_set_prefs`, `_set_transport`,
`_set_via_sent_by`).

Cross-referenced against the `unreg_first` table in `offhook/docs/Push-vs-Active-Socket.md` §1.1,
this means pjsua tears the regc down for many changes that would not require it — including a bare
credential rotation and a push-parameter change, our two most likely Model-B updates.
- **Not actionable in the engine today** — we do not drive `pjsip_regc` directly, and doing so
  would mean bypassing pjsua-lib, which invariant #1 rules out.
- Recorded because it is the basis of the optional "Deliverable B" in
  `VoIP/TASK-code-pjsip-disable-reg-on-modify.md`, and because it sharpens §1.1: the cost of an
  `unreg_first` field is a *pjsua* policy, not a SIP or regc necessity.
- Caveat: whether `pjsua_regc_init()` is reached only when `acc->regc == NULL` is **unverified**.

## TD-24 — a socket the OS killed during suspension is discovered late, not on resume · open (iOS)
Raised by Pavel 2026-08-04, and the sharp edge under `Push-vs-Active-Socket.md` §5. When iOS
suspends the app it reclaims the TCP/TLS connection, but **pjsip has no resume hook**: it learns
the socket is dead only *reactively* — when a send fails, or when the transport keep-alive timer
(`PJSIP_TCP_KEEP_ALIVE_INTERVAL` / TLS equivalent, **90 s**) next fires, and timers do not run
while suspended so that check is itself late.
`pjsua_acc_on_tp_state_changed` handles `PJSIP_TP_STATE_DISCONNECTED` *after the fact*.

The window between resume and discovery is the hazard: pjsip believes it has a transport,
`rfc5626_status` may still read `OUTBOUND_ACTIVE`, and the account looks registered — so the app
reports itself reachable, and an outgoing REGISTER or INVITE goes into a black hole until the
stack notices. On a push wake this is exactly the wrong moment to be optimistic.

**Design rule this implies (not yet implemented):** on foreground/resume the engine must treat any
connection-oriented transport as **presumed stale** and re-validate proactively rather than trust
its own state — shut the transport down and re-register, rather than waiting for a failure. pjsua's
sanctioned hammer for "everything may have changed" is `pjsua_handle_ip_change()` (with
`shutdown_transport`), which is the M2 milestone; a lighter targeted operation may be preferable
for the plain suspend/resume case, since nothing about the IP necessarily changed.

- **Verified:** the reactive-only nature of the transport-state callback and the keep-alive
  intervals (read in the fork at `4896a5e6a`; see `Push-vs-Active-Socket.md` §5).
- **Not verified — wants a device test:** how long detection actually takes after resume, whether
  a queued send fails fast or hangs to transaction timeout, and whether UDP's NAT binding shows the
  same class of false confidence (no connection state, so probably a different failure shape).
- Relates: TD-19 (a TLS listener restart drops its credentials — the M2 path that would do this
  re-validation), TD-22 (439), `Push-vs-Active-Socket.md` §5.

## TD-23 — `reRegister` throws `PJSIP_EBUSY` on a *successful* credential rotation · open
Found 2026-08-04 while researching `offhook/docs/Push-vs-Active-Socket.md` (§1.5). `reRegister`
ends with

```swift
try pjsua_acc_modify(account.raw, &acc).throwIfFailed()
accountParameters[account] = params
try pjsua_acc_set_registration(account.raw, true.pjBool).throwIfFailed()
```

but a changed credential makes `pjsua_acc_modify` set `unreg_first` and **call
`pjsua_acc_set_registration(PJ_TRUE)` itself** (`pjsua_acc.c`, `pjsua_acc_modify()` tail). Our
trailing call therefore arrives while the regc still has a transaction in flight, and
`pjsip_regc_send` refuses:

```c
if (regc->has_tsx) { ... return PJSIP_EBUSY; }   /* pjsip/src/pjsip-ua/sip_reg.c */
```

So the happy path — rotate the secret, pjsua re-registers — surfaces to the caller as a thrown
error, while the re-registration proceeds and succeeds behind it. Fix: only issue the trailing
`set_registration` when `acc_modify` did *not* signal (i.e. when nothing in the §1.1 field table
changed), or tolerate `PJSIP_EBUSY` there. **Needs a runtime test to confirm the ordering** — the
analysis is static; `pjsua_acc_modify` returns only after `pjsip_regc_send`, but whether `has_tsx`
is still set by the time we call depends on transport speed.

## TD-22 — a 439 (First Hop Lacks Outbound Support) left us permanently unregistered · **discharged upstream 2026-08 (pending a PJSIP bump)**
Verified 2026-08-04 against local master `4896a5e6a`. `use_rfc5626` defaults to `PJ_TRUE`, so on
TCP/TLS pjsua sends `;reg-id` + `Supported: outbound` — exactly the combination RFC 5626 §6
requires a registrar to answer with **439** when the first hop does not add `Path: <…;ob>`. pjsip
defined the status code (`sip_msg.h`) and handled it nowhere: absent from `regc_cb()`'s auto-retry
set, `update_rfc5626_status()` only read the `Require` header of a 2xx, and `use_rfc5626` was never
downgraded — so every subsequent attempt got 439 too.

**Fixed upstream by our own PRs:** [#5154](https://github.com/pjsip/pjproject/pull/5154)
(`77ad3feec`) retries registration without SIP outbound on 439, and
[#5168](https://github.com/pjsip/pjproject/pull/5168) (`716ef557d`) completes the lifecycle —
`first_hop_changed` + `reset_outbound_rejection()` in `pjsua_acc_modify()`, so changing the first
hop clears the sticky rejection instead of retrying into another 439.
- **The app-side mitigation this entry used to prescribe is now unnecessary** — do not add it.
- **Remains open until `swift-pjsip` ships a binary containing both commits** (TD-1 pins a branch,
  not a tag; the shipped binary is still 2.16-era). Until then a 439 in the field still bricks
  registration. Bump checklist: `Upstream/reference-post-2.16-fixes-impact.md`.
- Note: [`pjproject-5154`](../Upstream/pjproject-5154-439-first-hop-lacks-outbound.md). The
  remaining half — pushing the Contact to the regc when outbound turns out unsupported — is still
  on the fork as [laconicman#7](https://github.com/laconicman/pjproject/pull/7).

## TD-22 — TLS now fails fast at start, and our only recovery path is TD-19 · open (blocks TLS) · **measured 2026-09-01**
Found while fixing the Apple TLS backends upstream, Aug 2026; the runtime behaviour below was
observed on the Simulator on 2026-09-01 (`Tests/SwiftPJSUATests/TLSTransportTests.swift`).

pjproject [#5216](https://github.com/pjsip/pjproject/pull/5216) (merged) makes a TLS listener
**validate its server certificate when the listener starts** rather than on the first inbound
connection. The Apple/Network.framework backend we ship always behaved that way; the change
brought the Darwin backend into line and settled the question upstream.

- **What it buys us:** an unloadable certificate now fails `pjsua_transport_create()` directly,
  instead of producing a listener that reports ready and then rejects every handshake. The error
  arrives where it can be acted on.
- **What it costs us:** there is no longer any implicit recovery. A certificate that only becomes
  loadable *after* startup — a keychain unlocked late, a provisioning write, a rotated file —
  requires an explicit `pjsip_tls_transport_restart()` / `pjsua_transport_lis_restart()`. That is
  the contract we argued for upstream, on the grounds that it is the house convention
  (`restart_listener()` in `pjsua_core.c` already reschedules itself on failure).
- **Why that is a problem here:** **that call is TD-19.** `pjsua_transport_lis_restart()` is
  modify-style and consumes a `pjsua_transport_config` whose defaults zero every TLS credential
  field. So the one recovery path the upstream design assumes is the one we have already recorded
  as silently dropping our credentials.
- **Consequence:** TD-19 stops being latent the moment we ship TLS. Whoever adds a TLS transport
  must carry the live `tls_setting` across a restart *before* relying on restart as recovery,
  otherwise a transient certificate problem becomes a permanent one — the listener fails at start,
  the retry restarts it without credentials, and mutual TLS is quietly off.
- The same restart is also the only way to pick up a **rotated** certificate: the Apple backend
  captures the identity in the listener's `nw_parameters` at start and never reloads it.

Three further constraints from the same investigation, all recorded in
[`swift-pjsip/docs/Apple-TLS-Backends.md`](../../swift-pjsip/docs/Apple-TLS-Backends.md):

- `PJ_SSL_SOCK_IMP_APPLE` **requires the select ioqueue**. Every async event arrives via
  `ssl_network_event_poll()`, whose only caller is `ioqueue_select.c`; with kqueue the build links
  and no connection ever completes. Do not override `PJ_IOQUEUE_IMP`.
- A `.p12` that loads on iOS **fails on macOS** — iOS imports the identity from the file, macOS
  resolves the key through the keychain. This shapes how TLS can be tested at all.
- `get_cert_info()` parses the **peer's** certificate on every handshake and has four unguarded
  paths, one reached by SAN-only leaves that modern issuers emit routinely. Fixes are in review
  upstream; until they land, peer certificates are input the library does not fully validate.

- Refs: TD-19; pjproject #5216, #5222, #5224; `swift-pjsip/docs/Apple-TLS-Backends.md`.

### What was actually measured

Xcode 26.6 (17F113), iPhone 17 Pro simulator, **iOS 26.5**, PJSIP 2.17.0 (`288de6142`) via
`swift-pjsip` 0.2.1. Device not tested — every claim here is Simulator-only. (The earlier session
saw behaviour differ between iPhoneOS 26.2 and 26.5, so treat the SDK stamp as load-bearing.)

| what | observed |
|---|---|
| valid `.p12` + correct password | listener ready, ephemeral port — the positive control works, and only on iOS |
| certificate path that does not exist | `pjsua_transport_create()` fails, `PJ_EINVAL`; log `Failed opening file` / `Failed reading cert file` |
| file that is not a PKCS#12 | `pjsua_transport_create()` fails, status 496275; log `Apple SSL error SecItemImport [-26275]: Unable to decode the provided data` |
| valid `.p12` of 12 205 bytes | **fails, same `-26275`** — the 8 KB truncation is still in our binary, so pjproject#5222 has not arrived |
| restart with a defaulted config | `PJ_SUCCESS`, listener re-binds on a new port, credentials gone (TD-19) |
| restart with an unloadable certificate | fails — which is what proves the row above is a real drop and not a preserved setting |

So #5216's eager behaviour is exactly as advertised on the backend we ship: a bad certificate is a
`pjsua_transport_create()` error, not a mystery at first connection. **What is not as advertised is
the recovery.**

### The recovery path does not recover

"Call restart, reschedule on failure" is the recipe — `restart_listener()` in `pjsua_core.c` is the
model, and it is what we argued for upstream. Measured, it does not work through
`pjsua_transport_lis_restart()`:

1. a credential-carrying restart that fails has already run `pj_ssl_sock_close()` and set
   `listener->ssock = NULL`, and has already freed `listener->cert`;
2. every later restart therefore takes `pjsip_tls_transport_restart2()`'s
   `if (!listener->ssock)` branch — *"TLS restart requested while no listener created, update the
   published address only"* — which copies the new settings, **does not reload the certificate,
   does not re-open the socket, and returns `PJ_SUCCESS`**;
3. so the scheduled retry reports success forever while the listener stays down. Observed:
   the port stays at 0 after the "successful" retry
   (`testRestartAfterAFailedRestartReportsSuccessWithoutRecovering`).

The only route back appears to be destroying the transport and creating a new one. That has to be
settled before we ship TLS, because the whole fail-fast design is premised on restart being a
usable recovery.

**Upstream: filed, not fixed.** All three went into
[pjproject#5232](https://github.com/pjsip/pjproject/issues/5232) — a register rather than a
request, since none is blocking and the PR series was already carrying review load:
- **§5** — `restart2`'s no-listener branch should re-open the listener, or at minimum not report
  success. This is the one with teeth: it makes an unrecoverable listener indistinguishable from
  a working one, on the path #5216 made the documented recovery.
- **§6** — `restart2` handles three credential branches (files, buffer, store) as `else if`;
  listener start handles **four** independent `if`s including `cert_direct`. A `cert_direct`
  listener cannot be restored by any restart. See TD-19.
- **§7** — `ssl_sock_apple.m` reports every import failure as `"Apple SSL error SecItemImport"`,
  but iOS takes the `SecPKCS12Import()` branch. Cosmetic, one string, and it sends anyone
  debugging a `.p12` to the wrong API's documentation.

**None of this is fixed for us either way.** The eight-PR Apple-TLS series merged upstream on
2026-09-02 — including #5222, the 8 KB fix — but our binary is pinned at 2.17.0 (`288de6142`),
which predates all of it. The measurements above stand until a `swift-pjsip` rebuild, and the
oversized-`.p12` test is what will tell us the rebuild happened.

## TD-21 — `disable_reg_on_modify` is not a safe "apply config quietly" switch · obligation
Verified 2026-08-04, **history established 2026-08-17**. The flag suppresses the un-REGISTER and
re-REGISTER, but `pjsua_acc_modify()` calls `destroy_regc(acc, PJ_TRUE)` on the `unreg_first` path
regardless — which NULLs the regc (cancelling its refresh timer), clears `acc->contact` and
`reg_mapped_addr`, and resets `rfc5626_status`/`rfc5626_flowtmr`. The server keeps a binding we
will never refresh, and new dialogs get a Contact synthesised by `pjsua_acc_create_uas_contact()`
without our `contact_uri_params`.

**This is deliberate upstream behaviour, not a bug.** [#3910](https://github.com/pjsip/pjproject/pull/3910)
guarded the whole block; [#4509](https://github.com/pjsip/pjproject/pull/4509) (`ce81bb698`,
labelled `type: bug`) moved the guard inward on purpose — *"destroying old regc may still be
needed so we can use the updated registration related settings"*. Only the doc comment is stale,
in both `pjsua.h` and `pjsua2/account.hpp`.
- **The obligation stands: the engine must never set `disable_reg_on_modify`** as a way to apply
  configuration without signalling. The only fields that are genuinely signalling-free are the
  silent column of `offhook/docs/Push-vs-Active-Socket.md` §1.1.
- **Reassurance for our design:** #4509's rationale is the same shape as our pending-config slot
  drained on last-call-end — apply the settings, let the next registration pick them up. We simply
  have to own the re-registration.
- Upstream note: [`draft-acc-modify-disable-reg-still-destroys-regc`](../Upstream/draft-acc-modify-disable-reg-still-destroys-regc.md);
  handoff: `VoIP/TASK-code-pjsip-disable-reg-on-modify.md`.

## TD-20 — RFC 8599 is app-side string work; pjsip implements none of it · open
Verified 2026-07-26 against local master `4896a5e6a` (grep) and a DeepWiki deep consult
([conversation](https://deepwiki.com/search/rfc-8599-support-in-pjsippjsua_dbc6e482-8331-4443-b78f-3c5c9a2045ab?mode=deep)):
**pjsip contains no RFC 8599 code whatsoever.** `pnsreg`, `pnspurr` and `pn-purr` have zero
occurrences in the tree, and even `pn-provider` appears only in the iOS *sample app*, which
hand-builds the Contact string. Everything rides on `pjsua_acc_config.reg_contact_uri_params`
being appended verbatim — which is exactly where our ``PushConfiguration`` writes, so we can
express all of it, but nothing is parsed *for* us. Three consequences:

1. **`sip.pnsreg` media feature tag (RFC 8599 §8.5)** — presence means "this UA **can** refresh
   its binding without a push wake-up". A mobile UA that cannot signals by **omitting** it; there
   is no negative flag. We omit it, which is correct — but by accident, not by decision. Make it
   explicit in `PushConfiguration` so nobody "helpfully" adds it later.
2. **The proxy's `sip.pnsreg` feature-capability indicator (§8.4) is never parsed.** Its value is
   the *minimum seconds before expiry* at which the proxy expects a binding-refresh REGISTER.
   pjsua schedules refresh purely from the granted `Expires` plus `reg_timeout` /
   `reg_delay_before_refresh` — neither of which the engine currently exposes. So a push-aware
   proxy demanding more lead time than our margin will simply not be honoured, silently. Exposing
   those two account fields is the minimum fix; reading the indicator would need app-side parsing
   of the 2xx.
3. **`pn-purr` / `sip.pnspurr` (§6.2.1) — mid-dialog push to a *suspended* UA — is unsupported.**
   This is the standardised answer to reaching a UA whose dialog is live but whose app is
   suspended, i.e. one shape of the push-vs-active-socket race
   (`offhook/docs/Provisioning-Models.md` §B.1). Adopting it is entirely app-side work.

Also confirmed: 423 (Interval Too Brief) handling is generic `Min-Expires` retry with no
push-awareness — nothing accepts a longer expiry just because the UA is push-capable.

**Followed up 2026-08-04** by `offhook/docs/Push-vs-Active-Socket.md` §7, which reads the RFC text
directly and turns the three consequences above into recommendations: omit `sip.pnsreg`
deliberately (§7.1); parse the `sip.pnsreg` indicator — noting that its *absence* also matters,
since RFC 8599 §4.1.4 says a UA "SHOULD only send a binding-refresh REGISTER when it receives a
push notification" in that case, the opposite of what pjsua's timer does (§7.2); and adopt
`pn-purr` (§7.3) — which needs a **per-call** contact URI parameter surface, since
`contact_uri_params` is per-account and per-dialog is what RFC 8599 §6.1.1 requires. Note also that
RFC 5626 *is* implemented and on by default (§7.4) — see TD-22 for the gap that creates.

## TD-19 — a TLS listener restart silently drops its credentials · **confirmed by runtime test 2026-09-01** · open (blocks TLS)
Found by the 2026-07-17 config-struct misuse sweep
([conversation](https://deepwiki.com/search/misuse-sweep-for-that-same-cla_bb8d7a19-cc1b-44fb-bd24-32dd7d442b8e?mode=deep)),
the same bug class as D-CONFIG-4. `pjsua_transport_lis_restart()` is a **modify-style** API that
consumes `pjsua_transport_config` including `tls_setting` — and
`pjsua_transport_config_default()` zeroes every TLS credential field (`cert_file`,
`privkey_file`, `password`, `ciphers`). Restarting a TLS listener with a freshly-defaulted struct
therefore **silently disables mutual TLS**.

**No longer latent, and no longer analysis.** `Tests/SwiftPJSUATests/TLSTransportTests.swift`
(`testListenerRestartReplacesCredentialsRatherThanPreservingThem`) reproduces it on the
Simulator. Measured on Xcode 26.6 (17F113) / iPhone 17 Pro / **iOS 26.5**, PJSIP 2.17.0
(`288de6142`) via `swift-pjsip` 0.2.1:

- create with a valid `.p12` → listener ready on an ephemeral port (`tlstp:63153`);
- restart with a **freshly-defaulted** config → `PJ_SUCCESS`, and the listener really re-binds
  (`tlstp:63154`, a new port) — no error, no warning, nothing in the log to say the security
  posture changed;
- restart with a config naming an **unloadable** certificate → fails (`PJ_EINVAL`).

The third line is what makes the second mean something: had `cfg->tls_setting` been ignored in
favour of the listener's own, the unloadable certificate would have been ignored too and that
restart would have succeeded as well. It does not, so the config is what the listener ends up
with — and a defaulted one leaves it with nothing.

- **Correction to this entry's original reasoning.** It said the M2 IP-change milestone walks
  into this because `pjsua_handle_ip_change()` restarts every listener. **That part is wrong and
  is withdrawn.** `restart_listener()` (`pjsua_core.c`) calls the *three-argument*
  `pjsip_tls_transport_restart()`, which is `restart2(factory, NULL, …)`, and a `NULL` `opt`
  skips the wipe-and-copy block entirely — credentials preserved by construction.
  **`pjsua_handle_ip_change()` cannot drop TLS credentials.** The hazard is only ever *our own*
  call to `pjsua_transport_lis_restart()`, which is exactly the recovery path TD-22 needs.
- **Blast radius is wider than the listener.** `lis_create_transport()` takes the *client*
  certificate for outbound connections from the same `listener->cert`
  (`pj_ssl_sock_set_certificate(ssock, pool, listener->cert)`), so losing it also stops the UA
  presenting a client certificate to a provider. For a softphone that is the case that matters:
  the visible symptom is not "we stopped accepting inbound TLS", it is "the registrar stopped
  authenticating us", one restart later.
- **There is no preserving path through the pjsua API.** `pjsua_transport_lis_restart()` always
  passes `&cfg->tls_setting`, never `NULL`. `pjsua_transport_lis_start()` does leave
  `tls_setting`/`cert` untouched, but returns `PJ_SUCCESS` immediately when the socket is already
  up, so it is not a substitute. **Whoever adds TLS must keep our own copy of the live
  `pjsua_transport_config` and re-supply it on every restart** — there is nothing to read it back
  from.
- **Do not build the credential surface on `cert_direct`.** Listener start has four credential
  branches (files, buffer, store, `cert_direct`); `restart2` has three and **no `cert_direct`**
  (confirmed at `288de6142`). A listener configured that way cannot have its certificate restored
  by a restart even when the settings are re-supplied faithfully. Use `cert_file` (or `cert_buf`).
- **Discharge condition:** either upstream gives `pjsua_transport_lis_restart()` a way to say
  "keep what you have", or our TLS transport surface carries the live config across restarts and
  a test proves it. Not before.
- Refs: TD-22 (why this stops being avoidable); `Upstream/draft-tls-listener-restart-drops-credentials.md`;
  `docs/Configuration-Design.md` D-CONFIG-4 for the general rule; DeepWiki deep consult
  ([conversation](https://deepwiki.com/search/design-question-about-tls-list_c88a6faf-8491-407d-a80a-4f4a03d46d05?mode=deep),
  `query_id` `design-question-about-tls-list_c88a6faf-8491-407d-a80a-4f4a03d46d05`).

## TD-18 — transport port model · **discharged 2026-07-17** (fail-fast note still stands)
`Configuration.transports: [TransportConfiguration]` gives each transport its own kind and port
(IANA default per kind), and `AccountConfiguration.transportName` pins an account to one via
`acc_config.transport_id` — so the "single shared port" simplification is gone. Two caveats now
live on the API rather than here: a pin/URI mismatch is a hard `PJSIP_ETPNOTSUITABLE` error, and
pinning **UDP** disables the §18.1.1 upgrade (re-creating #5075) — pin TCP or leave it `nil`.
**Still deliberate:** fail-fast if a listener cannot bind (a production build may prefer
best-effort). Original entry follows.


`start()` opens the primary transport on `config.port` and, for a UDP primary, a **TCP listener
on the same port** (TD-16 mitigation). Two simplifications are deliberate for now and should be
lifted before Phase 2's per-account transport policy:
- **Single shared port.** Same-port UDP+TCP is safe (separate protocol families; IANA default
  is 5060 for both), but it is *not* a general rule: **TLS defaults to 5061**, and providers may
  mandate a specific non-default port per transport. One `config.port` cannot express a
  per-transport port map. Discharge: a transport list (`[(transport, port)]`) or per-transport
  port config, aligned with the per-account transport/TLS policy planned for Phase 2.
- **Fail-fast on the TCP bind.** If the TCP `pjsua_transport_create` fails, all of `start()`
  throws (tearing down UDP). Correct for a debug engine — a silent missing-TCP disables the
  §18.1.1 size switch — but a production build may prefer best-effort (log + continue on UDP,
  surface "TCP unavailable" as state). Decide when the transport surface is generalised.
- Refs: PR #7 Devin review (#2); RFC 3261 §18 (transports); IANA SIP ports (5060 UDP/TCP, 5061
  TLS); ties to Phase 2 per-account transport policy and TD-16.
