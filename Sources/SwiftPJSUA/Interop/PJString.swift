import PJSIP

/// An ARC-owned backing store for a `pj_str_t`.
///
/// `pj_str_t` is a non-owning pointer + length. When PJSIP must keep a string alive
/// across a call (e.g. fields of `pjsua_acc_config`), the bytes have to outlive the C
/// call. `PJString` owns a heap buffer and exposes a ``value`` pointing into it; keep the
/// `PJString` instance alive (e.g. via `withExtendedLifetime`) for as long as PJSIP may
/// read `value`.
final class PJString {
    private let buffer: UnsafeMutableBufferPointer<CChar>

    /// A `pj_str_t` pointing into this instance's owned buffer.
    let value: pj_str_t

    init(_ string: String) {
        // `utf8CString` includes the trailing NUL; PJSIP wants the length without it.
        let utf8 = Array(string.utf8CString)
        let buffer = UnsafeMutableBufferPointer<CChar>.allocate(capacity: utf8.count)
        _ = buffer.initialize(from: utf8)
        self.buffer = buffer
        self.value = pj_str_t(
            ptr: buffer.baseAddress,
            slen: pj_ssize_t(utf8.count - 1)
        )
    }

    deinit { buffer.deallocate() }
}
