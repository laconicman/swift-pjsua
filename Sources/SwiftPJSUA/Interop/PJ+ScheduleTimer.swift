import PJSIP

// Optional convenience, not used by the actor — kept as a documented escape hatch for
// the rare case of scheduling one-off work onto PJSUA's timer thread from a non-actor C
// context. The actor's `SerialExecutor` is the production mechanism for getting onto the
// PJSIP thread; this is deliberately low-level (no ordering / cancellation guarantees).
//
// When PJ_TIMER_DEBUG=1 (PJSIP's default), the C macro `pjsua_schedule_timer2` expands
// to `pjsua_schedule_timer2_dbg(..., __FILE__, __LINE__)`. C macros don't import into
// Swift, so only the `_dbg` symbol is callable — and a C wrapper would bake in the
// wrapper's own file/line, which is useless. Instead, recreate the convenient name in
// Swift with `#fileID`/`#line` as **default arguments**, which capture the *call site*
// exactly like the C macros do. Call sites stay clean: `pjsua_schedule_timer2(cb, ud, 0)`
// and PJLIB's timer debug log shows `MyFile.swift:42`.
@discardableResult
public func pjsua_schedule_timer2(
    _ callback: @escaping @convention(c) (UnsafeMutableRawPointer?) -> Void,
    _ userData: UnsafeMutableRawPointer?,
    _ msecDelay: UInt32,
    file: StaticString = #fileID,
    line: Int32 = #line
) -> pj_status_t {
    "\(file)".withCString { filePtr in
        pjsua_schedule_timer2_dbg(callback, userData, msecDelay, filePtr, line)
    }
}
