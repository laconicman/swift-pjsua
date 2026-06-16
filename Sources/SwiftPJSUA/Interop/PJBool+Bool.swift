import PJSIP

// `pj_bool_t` is `typedef int`; PJLIB defines `PJ_TRUE == 1` and `PJ_FALSE == 0`, so we
// convert against the literals directly (robust regardless of how the `pj_constants_`
// enum imports into Swift). Kept `internal` to avoid widening every `Int32`'s API.
extension pj_bool_t {
    /// Bridge a Swift `Bool` to PJLIB's `pj_bool_t` (`1`/`0`).
    init(_ value: Bool) { self = value ? 1 : 0 }

    /// `true` for any non-zero `pj_bool_t`, matching PJLIB's truthiness.
    var bool: Bool { self != 0 }
}

extension Bool {
    /// This `Bool` as a PJLIB `pj_bool_t`.
    var pjBool: pj_bool_t { pj_bool_t(self) }
}
