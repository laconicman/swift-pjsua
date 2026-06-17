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

## TD-6 — video & conference surface deferred · deferred-PR-b
PR-a ships the per-stream media **contract** (`CallMediaInfo` carries video window/capture) and
`CXProviderConfiguration.supportsVideo = true`, but the following land in PR-b:
- engine video wrappers (`pjsua_call_set_vid_strm` start/stop transmit, `pjsua_vid_win_*` getters,
  `pjsua_vid_conf_*`) and app-side pixel rendering (lives in the Offhook app);
- conference primitives — cross-connecting conf slots **between legs** for local mixing, and
  `;isfocus` detection for RFC 4579 server-hosted focus;
- CallKit grouping — `CXSetGroupCallAction`, `CXCallUpdate.supportsGrouping/supportsUngrouping`,
  `maximumCallsPerCallGroup > 1`.
- Refs: roadmap §6.3 / §7 M3; RFC 4579 <https://www.rfc-editor.org/rfc/rfc4579>;
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
- Refs: roadmap §6 (G15 resolution).

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

## TD-11 — account credentials live in engine-actor memory · open
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
