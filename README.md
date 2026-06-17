# swift-pjsua

An idiomatic, **Swift-only async** wrapper over PJSIP's high-level **C** API (pjsua1),
built on the prebuilt [`swift-pjsip`](https://github.com/laconicman/swift-pjsip) binary.

The engine is an `actor` whose work runs on a custom `SerialExecutor` backed by **one**
dedicated, PJLIB-registered POSIX thread. So `await phone.makeCall(...)` hops onto the
PJSIP thread and runs the (blocking) C call there — no continuations, no GCD on the hot
path, and no C++ shim.

## Why pjsua1 (C), not PJSUA2 (C++)

PJSUA2 delivers events by having you **subclass** its C++ classes and override virtual
methods. Swift/C++ interop [cannot subclass C++ classes or override their virtuals](https://www.swift.org/documentation/cxx-interop/status/),
so "Swift only" + PJSUA2 would still require a hand-written C++ shim. pjsua1's events are
plain C function pointers (`pjsua_callback`), which bridge to Swift cleanly. That makes
pjsua1 the honest cornerstone for a Swift-only wrapper — **this choice is load-bearing;
don't reverse it casually.**

## Two products, one dependency edge

```
PJSIP (binary)  ←  SwiftPJSUA (pure engine)  ←  SwiftPJSUAKit (CallKit/PushKit/UI)  ←  your app
```

- **`SwiftPJSUA`** — the pure pjsua1 engine. Imports only `PJSIP` + `Foundation`. **No**
  CallKit, PushKit, AVAudioSession, UIKit, or SwiftUI. Exposes call/account primitives plus
  an explicit **audio-device API** that the GUI layer drives.
- **`SwiftPJSUAKit`** — CallKit + PushKit + AVAudioSession orchestration that depends on the
  engine. On iOS, PJSIP is built with `SETUP_AV_AUDIO_SESSION=0`, so **the app/CallKit owns
  the audio session**, not PJSIP — this layer is where that ownership lives.

The boundary is compiler-enforced (the engine can't reach into Kit). Promote `SwiftPJSUAKit`
to its own repository only if its release cadence diverges from the engine's.

## Requirements

- **iOS 17+.** Custom actor executors ([SE-0392](https://github.com/apple/swift-evolution/blob/main/proposals/0392-custom-actor-executors.md))
  need the Swift 5.9 concurrency runtime, which isn't back-deployed below iOS 17.
- Swift tools 5.9+.
- `swift-pjsip` currently ships an **iOS-only** xcframework, so this package does not build
  for macOS yet. (A macOS slice is planned in `swift-pjsip` in a separate effort.)

## Usage sketch

```swift
import SwiftPJSUA

let phone = PJSUA()
try await phone.start(.init(port: 5060, transport: .udp))

let account = try await phone.addAccount(
    id: "sip:alice@example.com",
    registrar: "sip:example.com",
    username: "alice",
    password: "••••",
    // RFC 8599 push (optional). You may also pass a fully custom params string.
    push: .apns(teamID: "ABCDE12345", bundleID: "com.example.offhook", token: deviceToken)
)

// Observe the engine's event stream.
Task {
    for await event in phone.events {
        switch event {
        case let .incomingCall(account, call, sipCallID, from, offeredVideo):
            // In an app, hand sipCallID to SwiftPJSUAKit to dedup against a VoIP push;
            // `from` seeds the CallKit handle and `offeredVideo` its hasVideo flag.
            try? await phone.answer(call)
        case let .callState(call, state, _, lastStatus):
            print("call \(call) → \(state) (\(lastStatus))")
        default:
            break
        }
    }
}

let call = try await phone.makeCall(to: "sip:bob@example.com", from: account)
```

### Audio + CallKit

The engine never opens the mic on its own. CallKit tells it when the audio session is live:

```swift
func provider(_ provider: CXProvider, didActivate session: AVAudioSession) {
    Task { try? await phone.activateAudioDevice() }   // pjsua_set_snd_dev(default, default)
}
func provider(_ provider: CXProvider, didDeactivate session: AVAudioSession) {
    Task { await phone.deactivateAudioDevice() }       // pjsua_set_no_snd_dev()
}
```

`SwiftPJSUAKit` wires this for you (see `CallKitController`).

### Dual-mode (VoIP push + persisted connection), no double ring

One CallKit `UUID` per logical call, computed identically on both paths: prefer a
server-supplied UUID in the push payload; otherwise derive a deterministic **UUIDv5 from the
SIP `Call-ID`** (the INVITE over a persisted connection carries the same `Call-ID`, so both
paths agree). See `CallIdentity` / `CallRegistry` in `SwiftPJSUAKit`.

## Status — what's real vs. skeleton

This package is being built iteratively against a roadmap (M1 → M4).

**Real now (M1 core):**
- Engine lifecycle (`start`/`shutdown`), accounts (`addAccount`/`setRegistration`/
  `reRegister(_:updatingPush:)`), calls (`makeCall`/`answer`/`hangup`), audio-device API.
- pjsua1 callbacks bridged into a single `AsyncStream<PJSUAEvent>`; media-state wiring
  (`pjsua_conf_connect`) so audio actually flows; SIP `Call-ID` + disconnect/SIP status code
  surfaced on events; real `on_reg_state2` parsing.
- `thread_cnt` pinned ≥ 1 (see invariants below); RFC 8599 push params (caller-controlled).
- Deterministic UUIDv5 dedup logic (`CallIdentity`, unit-tested with the RFC 4122 vector).

**Skeleton (filled in next iterations), marked `Skeleton` in source:**
- `SwiftPJSUAKit` CXAction handling (answer/end/hold/mute/DTMF), provider configuration, and
  the VoIP/silent-push payload schema in `VoIPPushHandler`.
- Call features: hold/unhold, transfer, DTMF, multiple calls, video, conferences.
- Network-change / lifecycle handling (`pjsua_handle_ip_change` on `NWPathMonitor`).

## Load-bearing invariants

1. **`thread_cnt` ≥ 1.** The `SerialExecutor` design works *because* pjsua's own worker
   thread(s) pump events (`pjsua_handle_events`); the executor thread does **not**. With
   `thread_cnt == 0`, callbacks silently never fire. The engine owns this config and
   hard-sets it (with a `precondition`); it is deliberately **not** a public knob.
2. **Don't enter PJSIP from GCD/Swift-concurrency threads.** All blocking pjsua calls go
   through the actor → executor → the one registered PJSIP thread. The C callbacks are
   file-private free functions that hold no reference to the actor, so they can't re-enter it.
3. **Threads that call PJSIP must be registered** (`pj_thread_register`) and their
   `pj_thread_desc` must outlive the thread (see `Executor/PJThreadRegistration.swift`).

## Licensing

PJSIP is dual-licensed (GPLv2+ / commercial). `swift-pjsip` is built **with G.729**
(`bcg729`, GPLv3 + patent considerations) because Opus cannot transcode G.729 on the wire.
A production / App Store build therefore needs the appropriate PJSIP commercial license and
G.729 patent terms. This wrapper changes none of that — it only re-exposes the prebuilt
binary's capabilities.
