# Upstream notes

Drafts for fixing root causes in [`pjsip/pjproject`](https://github.com/pjsip/pjproject) so
swift-pjsua's local workarounds can be retired. Convention borrowed from GitLabKit: each note
carries a **pasteable issue draft** (GitHub-flavoured markdown for the pjproject tracker) and
enough **repro/context** to elaborate later. File only after re-verifying against current
`master` (our observations are from the pjsip **2.16** binary shipped in `swift-pjsip`;
DeepWiki deep-mode on `pjsip/pjproject` is the designated verification tool).

## Shipped upstream ✅

| Note | Problem | Outcome |
|---|---|---|
| [acc-table-full-asserts-in-debug](acc-table-full-asserts-in-debug.md) | `pjsua_acc_add` used `PJ_ASSERT_RETURN` for a user-input-driven capacity condition → debug builds **abort** where release returns `PJ_ETOOMANY` | issue [#5069](https://github.com/pjsip/pjproject/issues/5069) → PR [#5070](https://github.com/pjsip/pjproject/pull/5070) **merged** (`54ebfdbec`). Local `addAccount` guard kept: older pinned binaries still assert, and it yields a typed error carrying the capacity |
| [warn-oversized-udp-fallback-issue](warn-oversized-udp-fallback-issue.md) | Oversized request silently falls back to UDP when the §18.1.1 TCP upgrade has no TCP transport to acquire — no log line, docs promise the opposite | issue [#5075](https://github.com/pjsip/pjproject/issues/5075) → PR [#5076](https://github.com/pjsip/pjproject/pull/5076) **merged** (`PJ_PERROR` at the fallback + doc note) |

## Ready to file

| Note | Problem | Local mitigation today | Status |
|---|---|---|---|
| [acc-modify-resets-unset-fields](acc-modify-resets-unset-fields.md) | `pjsua_acc_modify()` applies the **whole** struct, so fields left at `pjsua_acc_config_default()` values are silently reset (server affinity, contact/via rewrite, reg timers, `rtp_cfg.port`, ICE/TURN use, creds, proxies). Docs never say so, nor point at `pjsua_acc_get_config()` | `reRegister` does read-modify-write (D-CONFIG-4) | **verified 2026-07-17 vs master `c1ea7648`** (doc text read directly) — documentation issue. **This one cost us a real bug** |
| [tls-listener-restart-drops-credentials](tls-listener-restart-drops-credentials.md) | `pjsua_transport_lis_restart()` takes `tls_setting` from the supplied config, but `pjsua_transport_config_default()` zeroes every cert/key/CA/verify field → restarting a TLS listener from a defaulted struct **silently disables mutual TLS**. The doc actively invites passing a config to update certs | none needed yet — we only `create` transports and ship no TLS | **verified 2026-07-17 vs master `c1ea7648`** (all three sources read) — documentation issue; TD-19. Reached via `pjsua_handle_ip_change`, so it lands on the M2 milestone |

## Closed without filing

| Note | Outcome |
|---|---|
| [udp-tcp-switch-not-reapplied-on-auth-resend](udp-tcp-switch-not-reapplied-on-auth-resend.md) | **Root cause disproven — deliberately not filed.** The stateless reuse branch *does* call `stateless_send_resolver_callback` in both 2.16 and master, so the §18.1.1 switch re-runs; both fixes we drafted were unsound. The observed fragmentation was the *no TCP transport to switch to* case, which became #5075 above. Kept with the analysis struck through: the symptom was real, and a future investigation should start from a live transport-level trace |

Not an issue draft: [post-2.16-fixes-impact.md](post-2.16-fixes-impact.md) — the reverse scan of
upstream fixes since 2.16 and the bump checklist.
