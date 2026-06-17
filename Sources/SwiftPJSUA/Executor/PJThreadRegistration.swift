import PJSIP

/// Registers a thread with PJLIB and keeps its `pj_thread_desc` alive for the
/// thread's entire lifetime.
///
/// Why this type exists at all: PJLIB stores per-thread bookkeeping *inside* the
/// `pj_thread_desc` buffer you hand to `pj_thread_register`. If that buffer is
/// deallocated while the thread is still calling PJSIP, PJLIB writes into freed
/// memory → heap corruption. The classic iOS bug is registering with a local
/// variable that goes out of scope. So the descriptor must be owned by something
/// that outlives the thread — here, the executor that owns the thread owns this.
///
/// `pj_thread_desc` is `long[PJ_THREAD_DESC_SIZE]` (64 longs). On 64-bit Apple
/// platforms `long == Int`, so we size an `Int` buffer to its byte count.
final class PJThreadRegistration {
    private let desc: UnsafeMutableBufferPointer<Int>
    private var handle: OpaquePointer?   // pj_thread_t *

    init() {
        let count = MemoryLayout<pj_thread_desc>.stride / MemoryLayout<Int>.stride
        desc = UnsafeMutableBufferPointer<Int>.allocate(capacity: count)
        desc.initialize(repeating: 0)
    }

    deinit {
        // Safe to release only once the thread is gone (the executor stops the thread
        // before releasing its registration). PJLIB has no "unregister"; dropping the
        // descriptor after the thread has exited is the correct teardown.
        desc.deallocate()
    }

    /// Register the **current** thread with PJLIB iff it isn't already.
    ///
    /// No-op for threads PJLIB already knows: its own worker threads, and — crucially —
    /// the thread that called `pj_init()` / `pjsua_create()`, which becomes the
    /// registered *main* thread. That is why our single executor thread (which performs
    /// `pjsua_create()`) needs no real registration; this call just makes the design
    /// robust if the thread is ever not the creator.
    ///
    /// - Important: Call only **after** PJLIB is initialized (i.e. after
    ///   `pjsua_create()`). `pj_thread_is_registered()` reads PJLIB TLS that
    ///   `pj_init()` sets up; calling it earlier can crash.
    func registerCurrentThreadIfNeeded(name: String) {
        guard pj_thread_is_registered() == 0 else { return } // pj_bool_t: 0 == false
        name.withCString { cname in
            // `pj_thread_desc` decays to a pointer as a C parameter, so Swift imports it
            // as UnsafeMutablePointer<Int>! — baseAddress matches.
            _ = pj_thread_register(cname, desc.baseAddress, &handle)
        }
    }
}
