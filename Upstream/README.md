# Upstream notes

Drafts for fixing root causes in [`pjsip/pjproject`](https://github.com/pjsip/pjproject) so
swift-pjsua's local workarounds can be retired. Convention borrowed from GitLabKit: each note
carries a **pasteable issue draft** (GitHub-flavoured markdown for the pjproject tracker) and
enough **repro/context** to elaborate later. File only after re-verifying against current
`master` (our observations are from the pjsip **2.16** binary shipped in `swift-pjsip`;
DeepWiki deep-mode on `pjsip/pjproject` is the designated verification tool).

| Note | Problem | Local mitigation today | Status |
|---|---|---|---|
| [udp-tcp-switch-not-reapplied-on-auth-resend](udp-tcp-switch-not-reapplied-on-auth-resend.md) | Authenticated resend after 401/407 skips the RFC 3261 §18.1.1 UDP→TCP size switch → over-MTU INVITE fragments and dies **silently** — and pjproject's own [TCP-transport doc](https://docs.pjsip.org/en/latest/specific-guides/network_nat/sip_tcp.html#automatic-switch-to-tcp-if-request-is-larger-than-1300-bytes) promises the opposite | engine always opens a TCP listener; callers dial with `;transport=tcp` (TD-16 tracks proxy surface) | **verified 2026-07-04 — ready to file** (code path = master; see note header) |
| [acc-table-full-asserts-in-debug](acc-table-full-asserts-in-debug.md) | `pjsua_acc_add` uses `PJ_ASSERT_RETURN` for a user-input-driven condition → debug builds **abort** where release returns `PJ_ETOOMANY` | engine guards `addAccount` (`pjsua_acc_get_count() < PJSUA_MAX_ACC`, throws) | **verified 2026-07-04 — ready to file** as discussion/doc issue (by PJLIB convention, confirmed on master; see note header) |
