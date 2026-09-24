# Upstream notes

Root-cause fixes and enhancements for [`pjsip/pjproject`](https://github.com/pjsip/pjproject) —
retiring swift-pjsua's local workarounds where there is one, and improving the shared stack where
there isn't. Convention borrowed from GitLabKit: each note carries a **pasteable issue/PR draft**
(GitHub-flavoured markdown for the pjproject tracker) and enough **repro/context** to elaborate
later. File only after re-verifying against current `master` (our observations are from the pjsip
**2.16** binary shipped in `swift-pjsip`; DeepWiki deep-mode on `pjsip/pjproject` is the designated
verification tool).

## File naming

**A note's filename is its permanent identity. Nothing that can change ever appears in it.**

```
<area>-<what-is-wrong>.md          # kebab-case. No status, no tracker number, no outcome.
```

Everything mutable — status, tracker ref, outcome, the commit the claims were checked against —
lives in **YAML front-matter inside the note**, and is mirrored in the tables below.

**Why this replaces the old `draft-` → `<tracker>-<number>-` rename.** The previous rule already had
the right principle: *"whether something is merged … flips over time and every flip would break
every inbound link across four repos."* It then made one exception for filing — and that exception
was the expensive one, because a note acquires most of its inbound links **while it is a draft**
(the doc that spawned it links to it immediately), and the rename fires at exactly the moment the
note becomes worth citing. Encoding `draft` vs `filed` in a filename is a status flip like any
other. This rule just applies the existing principle to the one case it exempted.

Second benefit, free: the directory now sorts by **subsystem** instead of by status, so the two
`rtcp-xr-*` notes sit together instead of being scattered across `draft-` and `pjproject-5xxx-`.

### Front-matter — the source of truth

```yaml
---
area: rtcp-xr                  # the subsystem you would grep for
kind: bug                      # bug | enhancement | question | docs | reference
status: ready                  # see vocabulary below
verified: cb0544e0d            # commit the claims were checked against
tracker:                       # omit until filed; PR where one exists, else issue
  issue: pjsip/pjproject#5204
  pr: pjsip/pjproject#5205
blocked_by:                    # required when status is `hold` — say what unblocks it
---
```

**Status vocabulary.** `draft` (being written, claims not all verified) · `ready` (verified, could
be filed today) · `hold` (verified but deliberately gated — `blocked_by` says why) · `filed`
(issue/PR open) · `merged` (landed upstream) · `closed` (dropped without filing, or rejected). Notes with `kind: reference` are not on that lifecycle and use `current` or `superseded` instead.

`hold` is new and load-bearing. A note can be fully source-verified and still be wrong to file —
`call-transport-death-not-notified` is verified against the source but has never been observed on a
running stack, so filing it before the live experiment would put a confident claim in front of
maintainers we have a good record with. The old scheme had no way to say that except prose buried in
a table cell.

### Multi-artefact notes

When a note spans more than one file (issue body, problem statement), they share the slug and take a
**dotted role suffix**: `439-first-hop-lacks-outbound.md` +
`439-first-hop-lacks-outbound.issue-body.md`. The role is part of what the file *is*, not a status,
so it is stable.

### Discoverable without this index

```sh
ls Upstream/                                                  # by subsystem — the slug is the topic
grep -rl --exclude=README.md 'status: ready'    Upstream/     # what could be filed today
grep -rl --exclude=README.md 'status: hold'     Upstream/     # what is gated (-A1 for why)
grep -rn  --exclude=README.md '5205'            Upstream/     # by tracker ref
grep -rl --exclude=README.md 'verified: cb0544' Upstream/     # stale after a pjproject bump
```

`--exclude=README.md` matters: this file quotes the field names, so it matches every query
otherwise. Front-matter is always the first block of a note, so a stricter `awk 'NR<12'` variant
works too if you prefer.

That last one is the reason `verified:` is a field rather than prose: a pjproject bump turns
"which notes were checked against the old tree?" from a reading exercise into one command.

### Migration — done

**Applied 2026-08-20.** All 15 notes renamed off their status prefixes, and the 18 inbound links
that referenced them repaired across `swift-pjsua/docs`, `offhook/docs`, `swift-pjsip/docs`,
`Upstream/test-servers/`, `PROJECT-MEMORY.md` and the root `TASK-*` files. That count is the
measured cost of the old scheme: every one of those links would have broken the next time a draft
was filed, and six notes currently sit at `ready` or `hold` — six breakages that were queued.

**From here a note is never renamed again for the rest of its life.** If you are adding one, the
name is the topic and nothing else; status goes in front-matter.

Two slugs are worth improving by hand afterwards, and deliberately left alone by the script so the
migration stays purely mechanical: `no-transport-death-notification-for-established-calls` (long,
and does not lead with its area — `call-transport-death-not-notified` would) and
`warn-oversized-udp-fallback` (leads with the fix, not the subsystem).

## Working with the fork

Contributions go through [`laconicman/pjproject`](https://github.com/laconicman/pjproject) first: a
branch, then a PR **against the fork's own master** for Devin review, and only then the upstream PR.
Two consequences worth remembering: the fork PR number and the upstream PR number are different (the
notes here carry the *upstream* one), and fork PRs run CIFuzz against upstream's tree, so their
Fuzzing check is meaningless — see [ossfuzz-15956](cifuzz-fork-pr-ref.md).

## Filed upstream

| Note | Problem | Outcome |
|---|---|---|
| [pjproject-5070](acc-table-full-asserts-in-debug.md) | `pjsua_acc_add` used `PJ_ASSERT_RETURN` for a user-input-driven capacity condition → debug builds **abort** where release returns `PJ_ETOOMANY` | issue [#5069](https://github.com/pjsip/pjproject/issues/5069) → PR [#5070](https://github.com/pjsip/pjproject/pull/5070) **merged** (`54ebfdbec`). Local `addAccount` guard kept: older pinned binaries still assert, and it yields a typed error carrying the capacity |
| [pjproject-5076](warn-oversized-udp-fallback.md) | Oversized request silently falls back to UDP when the §18.1.1 TCP upgrade has no TCP transport to acquire — no log line, docs promise the opposite | issue [#5075](https://github.com/pjsip/pjproject/issues/5075) → PR [#5076](https://github.com/pjsip/pjproject/pull/5076) **merged** (`PJ_PERROR` at the fallback + doc note) |
| [pjproject-5076](warn-oversized-udp-fallback.md) — *docs follow-up* | The guide page that made the false promise was left unchanged by #5076: it still asserted the 401/407 retry "will be sent with TCP" with no prerequisite, and framed the missing-transport case as an error you *will* see (not emitted on the address-fallback path) | [pjproject_docs#66](https://github.com/pjsip/pjproject_docs/issues/66) → PR [pjproject_docs#67](https://github.com/pjsip/pjproject_docs/pull/67) — **MERGED 2026-08-05** |
| [pjproject-5154](439-first-hop-lacks-outbound.md) | `use_rfc5626` defaults on, so pjsua sent `;reg-id` + `Supported: outbound` — the exact RFC 5626 §6 439 trigger — and then handled 439 nowhere: absent from `regc_cb()`'s retry set, no outbound fallback, `use_rfc5626` never downgraded → account **permanently unregistered** | PR [#5154](https://github.com/pjsip/pjproject/pull/5154) **merged** (`77ad3feec`) → follow-up PR [#5168](https://github.com/pjsip/pjproject/pull/5168) **merged** (`716ef557d`), adding `first_hop_changed` + `reset_outbound_rejection()` in `pjsua_acc_modify()` so a first-hop change clears the sticky rejection. **Retires TD-22.** Remaining half still on the fork: [laconicman#7](https://github.com/laconicman/pjproject/pull/7) |
| [pjproject-5178](coreaudio-vpio-other-audio-ducking.md) | **Enhancement, not a defect.** The coreaudio backend never configures VPIO's other-audio ducking, so the OS holds a *fixed* duck for the whole call — music a user was listening to stays flattened from answer to hangup. macOS 14 / iOS 17 added `kAUVoiceIOProperty_OtherAudioDuckingConfiguration`, whose advanced mode follows voice activity instead | issue [#5177](https://github.com/pjsip/pjproject/issues/5177) → PR [#5178](https://github.com/pjsip/pjproject/pull/5178) — **merged 2026-08-17** (`65a7e0cba`), verbatim, no maintainer edits (filed 2026-08-11). Two `#ifndef` `config.h` macros. **Review round 1 (sauwming, 2026-08-12) applied:** default flipped to `0` at his request, enabled for iOS via `config_site_sample.h` under `PJ_CONFIG_IPHONE`, and `!TARGET_OS_TV && !TARGET_OS_WATCH` added to the guard (load-bearing — tvOS failed to compile without it). Full CI green on macOS/Linux/Windows. macOS deliberately left on the old behaviour upstream (sauwming: "I suppose we can leave MacOS as it is right now") — `swift-pjsip` sets the macro itself. Written from `AudioUnitProperties.h` + WWDC23 10235 only — **never** from SashaSIP's GPL patch, since pjproject is dual-licensed. Listening test **not** done |
| [media-event-node-leaked-on-hangup](media-event-node-leaked-on-hangup.md) | `call_media_on_event()` takes a `pjsua_event_list` node from the recycle list, *then* returns early if `call->hanging_up` — orphaning it (`pjsua_media.c:1922-1943`). Not a heap leak (pool-backed), but the free list drains and `timer_pool` grows monotonically over process lifetime | issue [#5204](https://github.com/pjsip/pjproject/issues/5204) → PR [#5205](https://github.com/pjsip/pjproject/pull/5205) — **filed 2026-08-19**, awaiting review. **Impact escalated in a follow-up comment**: pjsua2's `libInit()` installs the callback unconditionally (`pjsua2/endpoint.cpp:2374`), so every C++ application is affected with no opt-out — live, not latent. Two-line fix: hoist the `hanging_up` guard into the enclosing condition so the node is never acquired when it will not be used. Re-verified on `upstream/master` `288de6142` before filing |

## Ready to file

| Note | Problem | Local mitigation today | Status |
|---|---|---|---|
| [acc-modify-resets-unset-fields](acc-modify-resets-unset-fields.md) | `pjsua_acc_modify()` takes most settings from the supplied struct, so fields left at `pjsua_acc_config_default()` values are silently reset (`rtp_cfg`, ICE/TURN cfg, creds, proxies, reg timers, `ka_interval`, assorted switches). Docs never say so, nor point at `pjsua_acc_get_config()` | `reRegister` does read-modify-write (D-CONFIG-4) | **verified 2026-07-17 vs master `c1ea7648`**, field list corrected by reading `pjsua_acc_modify()` itself (it is field-by-field, and `server_affinity` is *not* reset) — documentation issue. **This one cost us a real bug** |
| [tls-listener-restart-drops-credentials](tls-listener-restart-drops-credentials.md) | `pjsua_transport_lis_restart()` takes `tls_setting` from the supplied config, but `pjsua_transport_config_default()` zeroes every cert/key/CA/verify field → restarting a TLS listener from a defaulted struct **silently disables mutual TLS**. The doc actively invites passing a config to update certs | none needed yet — we only `create` transports and ship no TLS | **verified 2026-07-17 vs master `c1ea7648`** (all three sources read) — documentation issue; TD-19. Reached via `pjsua_handle_ip_change`, so it lands on the M2 milestone |
| [acc-modify-disable-reg-still-destroys-regc](acc-modify-disable-reg-still-destroys-regc.md) | `pjsua_acc_modify()` calls `destroy_regc(acc, PJ_TRUE)` on the `unreg_first` path regardless of `disable_reg_on_modify`, killing the regc, its refresh timer, `acc->contact` and the SIP-outbound state → the server keeps a binding the client will never refresh. **The behaviour is deliberate ([#4509](https://github.com/pjsip/pjproject/pull/4509)); the doc comment still describes the pre-#4509 semantics from [#3910](https://github.com/pjsip/pjproject/pull/3910)** | none needed — we never set the flag, and now must not (TD-21) | **revised 2026-08-17 vs `upstream/master` `27d28485f`**, history read. **Documentation-only** — the 08-04 draft's alternative "guard `destroy_regc()`" fix would have reverted a maintainer's own `type: bug` change and has been removed. Handoff: `TASK-code-pjsip-disable-reg-on-modify-docs.md` |
| [no-transport-death-notification-for-established-calls](no-transport-death-notification-for-established-calls.md) | An established INVITE dialog is never told its TCP/TLS transport died: the only transport-state listener in the SIP layer is per-**transaction** (`sip_transaction.c:2922`), `sip_dialog.c` registers none, and `pjsua_acc_on_tp_state_changed()` never touches `pjsua_var.calls[]`. An idle CONFIRMED call stays CONFIRMED indefinitely — app shows "connected", user hears nothing | app-side liveness polling of `pjsua_call_get_stream_stat().rx.pkt` (offhook OH-10) | ⛔ **HOLD — do not file next.** Source-verified vs fork `cb0544e0d` (grep-confirmed, not inferred; pre-filing re-check 2026-08-19 confirms no dialog-level listener exists in `sip_dialog.[ch]`/`sip_inv.c`), but **never observed on a running stack**. Gated on `TASK-code-call-lifecycle-verification.md` §2 — if something *does* fire when an idle call's transport is killed, the premise is wrong and filing would be a public mistake. File *with* the observation once it exists, as a documentation issue + enhancement *question*, not a bug. Analysis: `docs/Call-Termination-Paths.md` §4 |
| [rtcp-xr-no-structured-pjsua1-accessor](rtcp-xr-no-structured-pjsua1-accessor.md) | With RTCP XR compiled in, a pjsua1 app can only reach the VoIP-metrics data by re-parsing `pjsua_call_dump()` text — `pjsua_stream_stat` has no XR member (`pjsua.h:672-680`) and pjsua exposes no `pjmedia_stream *` getter | none needed — we read the stream pointer from `on_stream_destroyed` instead | **verified 2026-08-17 vs fork `cb0544e0d`**. **Enhancement**, low priority: the gap is only for *mid-call* reads |
| [rtcp-xr-r-factor-has-no-writer](rtcp-xr-r-factor-has-no-writer.md) | `PJMEDIA_RTCP_XR_INFO_R_FACTOR` writes `ext_r_factor` (`rtcp_xr.c:821-823`); `rx.voip_mtc.r_factor` has no writer besides the `127` init yet is transmitted at `:382` — so pjproject always advertises R factor "unavailable" and no app can populate it. RFC 3611 §4.7 distinguishes in-session vs out-of-session R | none — we compute no R factor at all | **mechanically verified 2026-08-17 vs fork `cb0544e0d`**; *intent* unverified → file as a **question**. MOS/`mos_lq`/`mos_cq` setters are unaffected |

## Closed without filing

| Note | Outcome |
|---|---|
| [ossfuzz-15956](cifuzz-fork-pr-ref.md) | For `google/oss-fuzz`, not pjproject. CIFuzz resolves `refs/pull/<N>/merge` against the **upstream** repo, not the fork — so on our fork it either silently fuzzes upstream's default branch and reports **green**, or (on a number collision) builds an unrelated upstream PR. Our PR #5 built a **2018** pjproject PR. Fork *support* is declined upstream ([#3731](https://github.com/google/oss-fuzz/issues/3731) `bug`+`wontfix`, [#10472](https://github.com/google/oss-fuzz/issues/10472), [#7479](https://github.com/google/oss-fuzz/issues/7479)) — not re-argued. The separable "don't report green" half, which the maintainer left open, is filed as [#15956](https://github.com/google/oss-fuzz/issues/15956). **Practical upshot: ignore the Fuzzing checks on fork PRs entirely — green means nothing either.** |
| [closed-udp-tcp-switch-not-reapplied](udp-tcp-switch-not-reapplied-on-auth-resend.md) | **Root cause disproven — deliberately not filed.** The stateless reuse branch *does* call `stateless_send_resolver_callback` in both 2.16 and master, so the §18.1.1 switch re-runs; both fixes we drafted were unsound. The observed fragmentation was the *no TCP transport to switch to* case, which became #5075 above. Kept with the analysis struck through: the symptom was real, and a future investigation should start from a live transport-level trace |

Not an issue draft: [post-2.16-fixes-impact.md](post-2.16-fixes-impact.md) — the reverse scan of
upstream fixes since 2.16 and the bump checklist.
