---
area: pjproject-bump
kind: reference
status: current
---

# Post-2.16 pjproject fixes — impact scan for swift-pjsip/swift-pjsua

Reverse-scan of upstream fixes landed **after the 2.16 tag** (~2025-11-26), assessed against
our dependency footprint. Compiled 2026-07-11 from: the 2026-07-05 ip-change deep consult's
commit enumeration, a dedicated DeepWiki deep run
([conversation](https://deepwiki.com/search/three-questions-about-pjprojec_6945a3bf-383d-4b6c-9a1c-6baa706623e8?mode=deep),
33 live-master tool calls), and raw-source reads of master `c1ea7648` (2026-07-10).
Context: our shipped binary is **2.16-era**; **2.17 was tagged 2026-04-22** (`5a457451`);
the build fork's base `868a376b` (2026-05-19) already contains 2.17 + some later commits.

> The sections after this one are the 2026-07 scan, kept as history: everything in them is in the
> binary since swift-pjsip 0.2.1 (`288de6142`), which took master rather than the 2.17 tag.

## swift-pjsip 0.3.0 — `288de6142` → `bd69054a6` (2026-10-11)

105 upstream commits, read from `git log 288de6142..bd69054a6` and the merged PRs; claims about
behaviour were checked against source at `bd69054a6`. Only what touches our footprint is listed.

### Changes the engine or its tests must react to

| Commit | Change | What it means here |
|---|---|---|
| `70ee4eb2a` (#5313) | A *configured* `rfc5626_instance_id` is sent in every REGISTER, with or without SIP outbound | Prerequisite for an account-level instance ID; the generated one stays outbound-only |
| `87d1f8a74` (#5281), `98f3145e5` (#5311) | The regc Contact is updated when the registrar does not confirm outbound | The remaining half of TD-22. It also means later REGISTERs drop `reg-id` (and a generated instance). Measured elsewhere: that Contact change is what leaves dead bindings on some registrars, which is why a configured ID with outbound off is the stable shape |
| `df97472e1` (#5222) | Apple TLS backends read the whole certificate file | The 8 KB ceiling is gone; `TLSTransportTests` flips its detector |
| `9b3ff706b` (#5233) | A TCP/TLS listener restart after a failed one really restarts; one credential loader for start and restart | Changes what TD-19 / TD-29's restart tests observe; re-measured on this binary |
| `947b0e08e` (#5297), `69576e03e` (#5266) | Parallel conference bridge (`conf_thread.c`) is the default backend | iOS runs it without workers; queued connect/disconnect/remove apply one frame later. swift-pjsip `config_site-ios.h` has the reasoning |
| `5c605b499` (#5251) | Use-after-free when an async auth challenge is deferred | Was the blocker on TD-31's deferred-REGISTER path ("bump swift-pjsip first") |

### Fixes we get for free (no engine change)

| Impact | Commit | Fix | Our exposure |
|---|---|---|---|
| ⬤ | GHSA-3659-543c-qm3g | NULL dereference in the registration client on a wildcard `Contact` from the registrar | Every account we register; a misbehaving registrar crashed the client |
| ◐ | GHSA-wm98-82v7-vjw2 | Peer certificate CN taken from an unrelated Subject field, and consulted although a SAN is present | TLS peer verification, once TLS ships |
| ◐ | GHSA-vcvv-w84c-pfqq | SIPS dialog target refresh accepted a non-SIPS Contact | TLS calls, once TLS ships |
| ◐ | `f7eb21ffc` (#5056) | `mod_mutex` self-deadlock on iOS/macOS | Our platform |
| ◐ | `3c8a577b2` (#5287) | Crash on IP change when the registration has no transport | `handleIPChange()` |
| ◐ | `4e367266d` (#5273) | Crash in `pjsua_check_snd_dev_idle()` if pjsua is destroyed before it started | A failed `start()` that is torn down and retried |
| ◐ | `d84c2e325` (#5242), `5ae74b7b6` (#5243) | Media clock: destroy-lock pool lifetime; stop/destroy wakes the clock thread | The null sound device runs on a media clock (headless tests) |
| ◐ | `9228b0301` (#5125) | A call's conference slot and state survive SDP renegotiation | Per-stream media events should no longer report a new slot after a re-INVITE; not yet observed |
| ◐ | `3bc680a18` (#5325) | Ephemeral TLS and IPv6 ports are preserved | Our transports are ephemeral (port 0) |
| ◐ | `16e09941a` (#5254) | Two keep-alive pongs from the server answered with a wrong pong | TCP/TLS keep-alive |
| ○ | `8a5c8d7f9` (#5240) | Use-after-free in `inv_session_destroy()` when the last reference to an INVITE session is dropped outside a dialog lock | Not reachable as far as checked. pjsip drops the last reference itself only inside `pjsip_dlg_on_tsx_state()`, under the dialog lock; the crash needs a caller holding its own reference (`pjsip_inv_add_ref()`) and dropping it elsewhere. At `288de6142` no pjsua source takes one (every add/dec site is in `sip_inv.c`), and the engine calls no `pjsip_inv_*` API. That every `sip_inv.c` drop runs under the lock is upstream's statement, not audited here. Fixed in this binary regardless |
| ○ | `068cf96ae` (#5205), `fcf0834e4` (#5203), `a7fa90f45` (#5269) | Media-event node leak on hangup; SRTP pool growth per SDES renegotiation; SRTP ROC retry after transport reinit | Calls with media events; SDES-SRTP |
| ○ | `9fd0920c2` (#5211), `f4b8fea78` (#5225), `256f22d8d` (#5219) | 513 for an oversized request; Via `sent-by` fallback without `received`; missing Call-ID guard | Robustness against odd peers |

### Compiled in, off by default

Server failover (`PJSIP_SERVER_FAILOVER`, #5293/#5298) and the system-resolver fallback
(`PJ_DNS_RESOLVER_SYS_FALLBACK`, #5303). Nameservers updatable after init (#5290). All belong to
the DNS work in TD-14; nothing changes until the engine turns them on.

## Our two pending issue drafts — both still unfixed upstream

| Draft | Master status (c1ea7648) |
|---|---|
| UDP→TCP switch skipped on 401/407 resend | **root cause DISPROVEN 2026-07-11 — ON HOLD.** The stateless reuse branch *does* re-run the size switch (2.16 & master); the real defect (symptom is real) is likely the stateful INVITE-tsx transport reuse path or config — re-investigate via live trace, do not file yet |
| `pjsua_acc_add` debug-abort on full table | **present** — `PJ_ASSERT_RETURN` at `pjsua_acc.c:788`; **fix designed + DeepWiki-approved**, PR in progress |

**File the acc-table issue; hold the UDP→TCP issue** pending a live-trace mechanism.
Either way, keep the app-side workarounds (TCP listener + `;transport=tcp`; `addAccount` guard).

## Fixes that affect us (⬤ high / ◐ medium / ○ low), by where they land

### In **2.17** (tag 2026-04-22) — picked up by any bump
| Impact | Commit | Fix | Our exposure |
|---|---|---|---|
| ◐ | `f40e39f1` | acc-del **use-after-free** with active calls; adds `pjsua_acc_del2(force)` (plain `acc_del` stays force=TRUE) | `removeAccount(_:)` — behaviour-stable, gains the UAF fix; post-bump prefer `acc_del2(force=false)` |
| ◐ | `46af8185` | registration refresh **integer underflow** when server grants tiny `Expires` (e.g. 1 s) → re-REGISTER scheduled far-future = silent registration loss | live-registrar dependent (iptel granted 60 s; a 1–2 s grant would bite). Commit dated tag day — **verify tag containment on bump** |
| ○ | `c82123ea` | stack overflow in `pjsip_auth_create_digest2` (SHA-256/512-256 digest) | we've only seen MD5 challenges; security-relevant anyway |
| ○ | `5c997b5e` | uninitialised value in `auth_clt_init_req` | sanitizer noise |
| ○ | `1b259c1a`, `4ca49720` | IPv6 parse/send asserts | debug-abort class; matters when IPv6 paths appear (cellular!) |
| ⬤ | `db3cfdee` | async client auth (feature) — **reclassified 2026-07-17 from ○** | introduces `pjsua_callback::on_auth_challenge` (absent in 2.16, present 2.17+), the on-demand credential hook our Keychain design depends on. **Prerequisite for the credential architecture**, not just a dispatch change |

### Master-only (post-2.17) — need a fork rebase + xcframework rebuild
| Impact | Commit | Fix | Our exposure |
|---|---|---|---|
| ⬤ | `70f8332b` (06-24) | registration timeout over **TCP/TLS did not reconnect** — dead connection until manual action | **direct hit**: we register over TCP (Flexisip) by design; a silently-dropped connection = unreachable until noticed |
| ⬤ | `acc03b57` (06-17) | **OOB write** in `update_service_route()` on multi-header `Service-Route` | memory-safety against any registrar that sends Service-Route (we saw the code path log on iptel) |
| ◐ | `6156adce` (05-28) | **use-after-free**: media ops (hold/re-INVITE/video) accepted after hangup started | our router can race `CXSetHeldCallAction` vs hangup; exactly our call-control shape |
| ◐ | `f86b8137` (05-28) | assert race on **call-slot reuse** (`med_prov_cnt`) | our suite reuses slots rapidly; debug-abort class |
| ◐ | `93410b16` + `a71d26dd` (07-10) | conference-bridge **races** on parallel port add/remove | conference milestone (D-CONF `setGroup`) |
| ◐ | `db33371d` (05-05) | conf **port leak** on alloc failure; `vid_conf` returns success on OOM | conference + video milestones |
| ◐ | `6b27565e` (07-10) | Via/Contact resolved toward account URI instead of next hop on **multihomed** hosts | iPhone Wi-Fi+cellular is multihomed; ties to the M2 IP-change milestone |
| ○ | `555cc462`/`f587ef14`/`1be002ac` | server affinity (feature) | future option; UDP flavour has a latent pin-vs-size-switch inconsistency (see udp-tcp note) |
| ○ | `092001d8`, `0e8589b5`, `2d2aebac`, `d862568c` | contact-rewrite/re-reg on transport drop | TCP registration hygiene, pairs with `70f8332b` |

Not affected: `c111a304` (needs `contact_use_src_port`, we don't set it), `9ab23a95` (siprec),
`36d06288` (norefersub), `9bec9e6c` (eCall 408/481 callback — feature, possibly interesting
for TD-17-adjacent control). `stream.c`/`pjsua_media.c`: no post-2.16 fixes found (index gap
possible — recheck at bump time).

## At bump time — checklist for the engine

- **Keep** the `addAccount` capacity pre-check. Our upstream fix (#5070, `54ebfdbec`) removes the
  debug abort, but the guard still earns its place: older/pinned binaries still assert, and it
  yields a typed `accountTableFull(capacity:)` instead of a bare `PJ_ETOOMANY`. Its comment is
  already version-neutral ("a crash or an error return depending on the PJSIP version") — no edit
  needed at bump.
- **Prefer `pjsua_acc_del2(force: false)`** over `pjsua_acc_del` in `removeAccount(_:)` and
  surface `PJ_EBUSY`, so "hang up first" is enforced rather than documented (`f40e39f1`).
- **Re-check** `stream.c` / `pjsua_media.c` for fixes the scan couldn't confirm (possible index gap).
- **Regression gate:** the Offhook live suite, plus a UDP-only run to confirm the new
  `PJ_PERROR(5)` fallback line (our #5075 fix) now appears when the TCP upgrade can't be honoured.

## Recommendation

**Rebase the pjproject fork onto current master (≥ `c1ea7648`) and rebuild the swift-pjsip
xcframework** — a 2.17-only bump misses the two highest-impact items for our *current* live
setup (`70f8332b` TCP-registration reconnect, `acc03b57` Service-Route OOB) plus the
call/conference race fixes our roadmap walks straight into. The fork base (2026-05-19) is
already past 2.17, so the rebase distance is ~7 weeks of upstream. Keep both workarounds
(they're unfixed); re-run the Offhook live suite as the regression gate after the rebuild.
File both issue drafts now — independent of the bump.
