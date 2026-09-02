# Build bring-up & first-run verification

This doc was written when the package had been **authored against `swift-pjsip`'s API but
never linked** — no PJSIP module or iOS SDK in the authoring environment — as the checklist
to take it from "reads correctly" to "builds and rings," and the order to expect friction in.

**That gate is passed.** The package compiles and links for the iOS Simulator, its own test
suites run there, and the `offhook` live suite registers, places loopback calls and carries
RTP through it. What has *not* been proven is a run on a **device**, and there is still no CI
(`Tech-Debt.md` TD-12) — so nothing here re-checks itself. The friction table below is kept as
the triage order for the next environment that meets the compiler for the first time (a device,
a macOS slice, a PJSIP bump), not as a list of open items.

## Why `swift test` is not the gate

Every target transitively imports the **iOS-only** `PJSIP` xcframework, so `swift test` on
macOS will not link. Bring-up happens in an Xcode app target built for the iOS Simulator (or
device):

```
xcodebuild build -scheme <App> -destination 'platform=iOS Simulator,name=iPhone 15'
```

The app target depends on `SwiftPJSUA` (+ `SwiftPJSUAKit`); the framework link flags ride in
on `SwiftPJSUA`'s `linkerSettings` automatically (the support-target pattern, roadmap §3.5).

An app target is needed for the *runtime smoke* below, but **not** for the test suites: the
package's own generated scheme builds and runs them against the Simulator directly, which is how
`SwiftPJSUATests` is run today.

```
xcodebuild test -scheme swift-pjsua-Package \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Add `-only-testing:SwiftPJSUATests/TLSTransportTests` to run one suite. Confirmed working on
Xcode 26.6 with an iOS 26.5 simulator — 8 tests, no build warnings. This is a smaller gate than
TD-12 asks for, but it is a real one and it needs no app.

**Simulator only, and not by choice.** Apple does not allow tool-hosted testing on device
destinations, and a SwiftPM package test target cannot declare a host application — the setting
does not exist in the manifest API — so these tests are tool-hosted by construction. Running any
XCTest of this stack on a device needs a project with a host app, which is blocked on TD-26.
The device route today is `offhook`'s app-side auto-smoke:
[`offhook/docs/Testing-Playbook.md`](../../offhook/docs/Testing-Playbook.md).

## Predicted first-compile friction (triage in this order)

| # | Site | What to verify against the real headers |
|---|---|---|
| 1 | `Interop/PJString.swift`, `String+PJStr.swift` | `pj_str_t(ptr:slen:)` member-wise init names and `pj_ssize_t` type. |
| 2 | `PJSUACallbacks.swift` `callMediaInfos(from:)` | `pjsua_call_info.media` imports as a fixed homogeneous tuple; `withMemoryRebound(to: pjsua_call_media_info.self, capacity:)` over it is valid only if the import is contiguous as assumed. |
| 3 | `CallMediaInfo.swift` | union access `media.stream.aud.conf_slot`, `media.stream.vid.win_in`, `.vid.cap_dev` — confirm the imported Swift names for the C `stream` union members. |
| 4 | enum `.rawValue` interop | `PJSIP_SC_*`, `pjsip_inv_state`, `pjsua_call_media_status`, `last_status.rawValue` are read via `.rawValue`. Confirm how these C enums import (and reconcile with `resume()`, which deliberately *avoids* `.rawValue` for `pjsua_call_flag` "to build on Linux too" — keep the convention consistent). |
| 5 | sentinels written as literals | `PJSUA_INVALID_ID == -1`, `PJMEDIA_AUD_DEFAULT_CAPTURE_DEV == -1` / `PLAYBACK == -2`, `PJMEDIA_VID_INVALID_DEV == -3`, `PJSUA_CALL_UNHOLD == 1` — verify each against `pjsua.h`/`pjmedia` for the consumed build. |
| 6 | `PJThreadRegistration.swift` | `MemoryLayout<pj_thread_desc>.stride` — confirm `pj_thread_desc` imports as a tuple of `Int` (long[64]) so the `Int`-buffer sizing matches. |
| 7 | `PJSIPExecutor.swift` `enqueue(_:UnownedJob)` | compiles with an `UnownedJob` deprecation warning under Swift 6; migrate to `consuming ExecutorJob` when convenient. |

None of these are design problems; they are the expected cost of a binding that has never
met the compiler. Centralised interop helpers (`Interop/`) keep the fixes in few places.

## Runtime smoke (debug build, assertions on)

The structural re-entrancy guard plus `assertOnRegisteredPJThread()` (`PJSUACallbacks.swift`)
are active in debug — a green run is meaningful.

1. `try await phone.start()` — engine + executor thread come up; `pjsua_create()` registers
   the executor thread as PJLIB's main thread.
2. `addAccount(…)` against a test registrar → observe `.registrationState(active: true)`.
3. `makeCall(to:)` an echo-test URI → observe `.callState(.confirmed)` then
   `.callMediaState` with an `.active` audio stream.
4. Confirm audio flows **after** CallKit's `didActivate` drives `activateAudioDevice()` —
   not on `makeCall` return (roadmap §6.3). Hear the echo.
5. Verify `assertOnRegisteredPJThread` never trips (it would mean a callback fired off a
   non-PJLIB thread).

App-target prerequisites: mic (and camera, for video) usage strings; the `voip` background
mode; and the **app's** `PrivacyInfo.xcprivacy` declaring the system-boot-time required-reason
API PJSIP uses (the binary can't carry one — see `swift-pjsip` README).

## CI gate (closes TD-12)

Add a macOS-runner job:
`xcodebuild test -destination 'platform=iOS Simulator,name=iPhone 15'`. Until the pure-logic
module is extracted (TD-15) this is the only way to run even the mapping/dedup tests.
