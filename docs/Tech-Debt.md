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
  filed 2026-08-11) — with a macOS 14+ floor a Mac slice picks up voice-activity-driven ducking for
  free; below it, calls keep the old whole-call duck. See
  [`Upstream/coreaudio-vpio-other-audio-ducking.md`](../Upstream/coreaudio-vpio-other-audio-ducking.md).

- Refs: roadmap §6 (G15 resolution), §6.3 (audio-device API);
  `TASK-code-swift-pjsip-macos-slice.md` §5.

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

## TD-22 — a 439 (First Hop Lacks Outbound Support) would leave us permanently unregistered · open (latent)
Verified 2026-08-04 against local master `4896a5e6a`. `use_rfc5626` defaults to `PJ_TRUE`, so on
TCP/TLS pjsua sends `;reg-id` + `Supported: outbound` — exactly the combination RFC 5626 §6
requires a registrar to answer with **439** when the first hop does not add `Path: <…;ob>`. pjsip
defines the status code (`sip_msg.h`) and handles it nowhere: it is absent from `regc_cb()`'s
auto-retry set, `update_rfc5626_status()` only reads the `Require` header of a 2xx, and
`use_rfc5626` is never downgraded — so every subsequent attempt gets 439 too.
- Not live: no TLS/TCP deployment yet. Latent the moment we register through someone else's edge
  proxy.
- App-side mitigation: on `on_reg_state` code 439, re-apply the config with `use_rfc5626 = false`.
  Note `use_rfc5626` is an `unreg_first` field, so never mid-call.
- Upstream note: [`439-first-hop-lacks-outbound-not-handled`](../Upstream/439-first-hop-lacks-outbound-not-handled.md).

## TD-21 — `disable_reg_on_modify` is not a safe "apply config quietly" switch · obligation
Verified 2026-08-04. The flag suppresses the un-REGISTER and re-REGISTER, but `pjsua_acc_modify()`
calls `destroy_regc(acc, PJ_TRUE)` **unconditionally** on the `unreg_first` path — which NULLs the
regc (cancelling its refresh timer), clears `acc->contact` and `reg_mapped_addr`, and resets
`rfc5626_status`/`rfc5626_flowtmr`. The result: the server keeps a binding we will never refresh,
and new dialogs get a Contact synthesised by `pjsua_acc_create_uas_contact()` without our
`contact_uri_params`.
- **The obligation: the engine must never set `disable_reg_on_modify`** as a way to apply
  configuration without signalling. The only fields that are genuinely signalling-free are the
  silent column of `offhook/docs/Push-vs-Active-Socket.md` §1.1.
- Upstream note: [`acc-modify-disable-reg-still-destroys-regc`](../Upstream/acc-modify-disable-reg-still-destroys-regc.md).

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

## TD-19 — a TLS listener restart would silently drop its credentials · open (latent; M2)
Found by the 2026-07-17 config-struct misuse sweep
([conversation](https://deepwiki.com/search/misuse-sweep-for-that-same-cla_bb8d7a19-cc1b-44fb-bd24-32dd7d442b8e?mode=deep)),
the same bug class as D-CONFIG-4. `pjsua_transport_lis_restart()` is a **modify-style** API that
consumes `pjsua_transport_config` including `tls_setting` — and
`pjsua_transport_config_default()` zeroes every TLS credential field (`cert_file`,
`privkey_file`, `password`, `ciphers`). Restarting a TLS listener with a freshly-defaulted struct
therefore **silently disables mutual TLS**.
- **Not a bug today:** `start()` only ever calls `pjsua_transport_create` (create-style, where a
  fresh default is correct), and we ship no TLS transport yet.
- **Why it is queued rather than ignored:** the M2 IP-change milestone calls
  `pjsua_handle_ip_change()`, which internally restarts every registered listener — including
  `pjsip_tls_transport_restart`. Whoever adds TLS + IP-change must carry the live `tls_setting`
  across the restart (save our own copy or read it back), not rebuild it.
- Refs: capability map "IP/network-change" (M2); `pjsua_transport_lis_restart` docs;
  `docs/Configuration-Design.md` D-CONFIG-4 for the general rule.

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
