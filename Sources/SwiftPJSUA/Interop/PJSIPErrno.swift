import PJSIP

// Interim, until swift-pjsip exports these from its module. Swift imports `PJSIP_ERRNO_START`
// but stops at the macros built on it: `PJSIP_ERRNO_START_PJSIP` adds one more level of macro
// arithmetic, and the importer drops both it and everything defined from it. So the two the
// engine needs are restated here exactly as `pjsip/sip_errno.h` defines them.

/// `PJSIP_ERRNO_START_PJSIP`: `(PJSIP_ERRNO_START + 1000)` in `pjsip/sip_errno.h`.
let PJSIP_ERRNO_START_PJSIP: pj_status_t = PJSIP_ERRNO_START + 1000

/// `PJSIP_EBUSY`: `(PJSIP_ERRNO_START_PJSIP + 1)` in `pjsip/sip_errno.h`. A registration session
/// returns it when asked to send while a transaction of its own is pending.
let PJSIP_EBUSY: pj_status_t = PJSIP_ERRNO_START_PJSIP + 1
