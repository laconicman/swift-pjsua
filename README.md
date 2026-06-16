# swift-pjsua (skeleton)

A Swift-only, async front end to **PJSIP's pjsua1 C API**, built on
[`swift-pjsip`](https://github.com/laconicman/swift-pjsip)'s `PJSIP` module. This is a
**skeleton** — it compiles in principle against `swift-pjsip` and shows the architecture
end to end, but the account/media wiring is intentionally minimal and marked `// TODO`.
It has **not** been linked or run here; treat it as a starting point to adapt, not a
finished SDK.

## The one idea

> An actor runs its code on *its* executor — not on "the" Swift executor. Give the
> engine a custom `SerialExecutor` backed by **one dedicated, PJLIB-registered POSIX
> thread**, and `await phone.makeCall(...)` runs the (blocking) PJSIP C call on the
> correct thread, then hops back. No `withCheckedContinuation`, no GCD, no C++ shim.

This directly contradicts the common claim (including in the DeepWiki dialog) that you
*can't* use actors/async-await with PJSIP "because actors use GCD." That's only true of
the **default** executor. The custom executor is the whole point — and it's *cleaner*
than the timer-callback or hand-rolled-worker-thread bridges, because:

- **Stable thread identity.** It's the same OS thread for the engine's life, registered
  with PJLIB exactly once. The GCD-thread-reuse hazard (a recycled thread losing its
  registration, corrupting the `pj_thread_desc`) cannot happen.
- **Blocking is allowed here — by design.** PJSIP calls may block; that's fine on a
  thread dedicated to PJSIP. It would be a *bug* on the cooperative pool, which forbids
  blocking (it breaks Swift's forward-progress guarantee). So this executor is precisely
  where PJSIP blocking belongs.
- **Registration is nearly free.** The thread that calls `pjsua_create()` (→ `pj_init()`)
  *becomes* PJLIB's registered main thread. Since `PJSUA.start()` runs on the executor
  thread and does the `create`, that thread is registered automatically; we still call
  `registerThisThread(...)` defensively (a no-op in the common case).

## Why pjsua1 (C), not PJSUA2 (C++)

PJSUA2 delivers events by you **subclassing** its C++ classes (`Call`, `Account`, …) and
overriding virtual methods. Swift/C++ interop **cannot** subclass C++ classes or override
their virtuals ([status](https://www.swift.org/documentation/cxx-interop/status/)), so a
"Swift-only" PJSUA2 wrapper would still need a C++ shim — relocating the C++ layer, not
removing it. pjsua1's C function-pointer callbacks bridge to Swift directly, so for the
Swift-only + modern-concurrency goal, pjsua1 is the honest cornerstone. (The conveniences
PJSUA2 would hand you — typed Call/Account objects — are exactly what
[`swift-pjsip-gen`](https://github.com/laconicman/swift-pjsip-gen) can generate on top of
the flat C API.)

## Files

| File | Role |
|---|---|
| `PJSIPExecutor.swift` | The custom `SerialExecutor` + its dedicated thread. The core. |
| `PJThreadRegistration.swift` | Owns the `pj_thread_desc` for the thread's lifetime; guarded `pj_thread_register`. |
| `PJSUA.swift` | The `actor`: lifecycle, account/call methods, and the C-callback → `AsyncStream` bridge. |
| `PJSUAEvent.swift` | `CallID`/`AccountID`/`Transport`/`CallState`/`PJSUAEvent` value types. |
| `PJSUAError.swift` | `pj_status_t` → `Error` (`pj_strerror`), and the `check(_:)` helper. |
| `PJ+ScheduleTimer.swift` | Optional `#fileID`/`#line` debug wrapper for `pjsua_schedule_timer2`. |

## Usage sketch

```swift
import SwiftPJSUA

let phone = PJSUA()                            // create exactly one (pjsua is global)

// Observe lifecycle as a cancellable async sequence.
let watcher = Task {
    for await event in phone.events {
        switch event {
        case .incomingCall(_, let call):  print("ringing: \(call)")
        case .callState(let call, let s): print("\(call) → \(s)")
        default: break
        }
    }
}

try await phone.start()                        // hops onto the PJSIP thread
let acc = try await phone.addAccount(
    id: "sip:alice@example.com",
    registrar: "sip:example.com",
    username: "alice",
    password: "••••"
)
let call = try await phone.makeCall(to: "sip:bob@example.com", from: acc)
// ... later ...
try await phone.hangup(call)
await phone.shutdown()
watcher.cancel()
```

Every `await` above is the hop onto the dedicated PJSIP thread; the method bodies call
the C API synchronously and return/throw. That's the executor doing its job.

## What you must fill in

1. **Media / audio.** `pjsuaOnCallMediaState` only yields an event. Connect the call's
   conference slot to the sound device there (`pjsua_conf_connect`), matching your
   PJSIP version's `pjsua_call_info` layout (single `conf_slot` vs `media[]`/`media_cnt`).
2. **AVAudioSession + CallKit.** Activating the audio session is the **app's** job and
   must be driven by CallKit's `provider(_:didActivate:)`, not by `makeCall` returning.
   PushKit's "report to CallKit synchronously or be terminated" contract still applies.
3. **Registration result.** `pjsuaOnRegState2` is stubbed; read
   `info.pointee.cbparam.pointee.code`/`.expiration` for real status.
4. **Cancellation.** If you want a Swift `Task` cancellation to map onto a PJSIP hangup,
   wrap the relevant call in `withTaskCancellationHandler`.

## Availability and the pre-iOS-17 fallback

Custom actor executors (SE-0392) require the **Swift 5.9 concurrency runtime**, which is
**not back-deployed below iOS 17 / macOS 14**. Hence `platforms: [.iOS(.v17), .macOS(.v14)]`.

If you must support **iOS 15–16**, keep `PJSIPExecutor`'s *thread* (and
`PJThreadRegistration`) but **drop the `SerialExecutor` conformance**, and bridge with a
continuation instead — enqueue work onto the same dedicated thread and resume from there:

```swift
// Conceptual fallback — same thread, no custom executor:
func makeCall(to uri: String, from acc: AccountID) async throws -> CallID {
    try await withCheckedThrowingContinuation { cont in
        pjThread.enqueue {                       // runs on the registered PJSIP thread
            var id: pjsua_call_id = -1
            let status = /* ... pjsua_call_make_call ... */ 0
            status == 0 ? cont.resume(returning: CallID(id))
                        : cont.resume(throwing: PJSUAError(status: status))
        }
    }
}
```

Guard every early-exit path so the continuation resumes **exactly once** (e.g. if the
enqueue/schedule itself fails). The custom-executor version above avoids this bookkeeping
entirely for the common path, which is why it's the preferred design on iOS 17+.

## License

Match your intent; the PJSIP binary it links is GPL/commercial (see `swift-pjsip`).
