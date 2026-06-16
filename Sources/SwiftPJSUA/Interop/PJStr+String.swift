import Foundation
import PJSIP

extension pj_str_t {
    /// A Swift `String` copied out of this `pj_str_t`.
    ///
    /// `pj_str_t` is a pointer + explicit length and is *not* NUL-terminated, so we copy
    /// exactly `slen` bytes. Safe to call on a `pj_str_t` whose backing buffer is only
    /// valid for the duration of a C callback, because the bytes are copied immediately.
    var string: String? {
        guard let ptr = ptr else { return nil }
        if slen <= 0 { return "" }
        let data = Data(bytes: ptr, count: Int(slen))
        return String(data: data, encoding: .utf8)
    }
}
