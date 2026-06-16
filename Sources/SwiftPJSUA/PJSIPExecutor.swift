import Foundation
import PJSIP

/// A `SerialExecutor` whose every job runs on a single, dedicated, PJLIB-registered
/// POSIX thread. This is the heart of the package and the rebuttal to the common
/// claim that "you can't use actors with PJSIP because actors use the Swift executor."
///
/// Actors don't use *the* executor — they use *their* executor. Give an actor this one
/// and `await actor.method()` hops onto this thread, runs the (blocking) PJSIP C call
/// there, and hops back. No `withCheckedContinuation`, no GCD, no thread juggling.
///
/// Two properties make this correct where GCD/the cooperative pool are wrong:
///   1. **Stable identity.** It is the *same* OS thread for the engine's whole life,
///      registered with PJLIB exactly once. The GCD-thread-reuse hazard (a recycled
///      thread losing its registration) cannot occur.
///   2. **Blocking is allowed — by design.** PJSIP calls may block; that is fine here
///      because this thread is dedicated to PJSIP. It would be a bug on the cooperative
///      pool, which forbids blocking (it breaks Swift's forward-progress guarantee).
///
/// Availability: custom executors (SE-0392) need the Swift 5.9 runtime → iOS 17+.
final class PJSIPExecutor: SerialExecutor, @unchecked Sendable {
    // @unchecked Sendable invariant: the only mutable state is `queue`/`stopping`, both
    // guarded by `lock` (an NSCondition, i.e. a pthread mutex + condition variable —
    // POSIX primitives, appropriate for executor plumbing and PJSIP-compatible).

    private let lock = NSCondition()
    private var queue: [UnownedJob] = []
    private var stopping = false
    private let registration = PJThreadRegistration()
    private var thread: Thread?

    init(name: String = "swift-pjsua.engine") {
        let t = Thread { [weak self] in self?.threadMain() }
        t.name = name
        t.stackSize = 1 << 20                // 1 MiB; PJSIP call stacks run deep
        t.qualityOfService = .userInitiated
        thread = t
        t.start()
    }

    // MARK: SerialExecutor

    // Swift 6 spells this `enqueue(_ job: consuming ExecutorJob)`. The `UnownedJob`
    // overload remains available and keeps us aligned with the iOS 17 runtime.
    func enqueue(_ job: UnownedJob) {
        lock.lock()
        queue.append(job)
        lock.signal()
        lock.unlock()
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    // MARK: Thread lifecycle

    /// The dedicated PJSIP thread's run loop. It does NOT register with PJLIB here:
    /// the first job to run is `PJSUA.start()`, which calls `pjsua_create()` → `pj_init()`
    /// and thereby makes *this* thread PJLIB's main thread. `PJSUA.start()` then calls
    /// `registerThisThread(...)` defensively (a no-op once we are the main thread).
    private func threadMain() {
        while true {
            lock.lock()
            while queue.isEmpty && !stopping { lock.wait() }
            if stopping && queue.isEmpty {
                lock.unlock()
                return
            }
            let job = queue.removeFirst()
            lock.unlock()
            // Runs the actor's code on THIS thread.
            job.runSynchronously(on: asUnownedSerialExecutor())
        }
    }

    /// Defensive PJLIB registration for this executor thread. Call from `PJSUA.start()`
    /// *after* `pjsua_create()`. No-op when this thread is already the registered main
    /// thread (the common case), active if you ever drive the executor differently.
    func registerThisThread(name: String) {
        registration.registerCurrentThreadIfNeeded(name: name)
    }

    /// Signals the run loop to exit after draining. Call after `pjsua_destroy()`.
    func stop() {
        lock.lock()
        stopping = true
        lock.signal()
        lock.unlock()
    }
}
