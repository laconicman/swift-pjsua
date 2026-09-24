---
area: rfc5626-outbound
kind: bug
status: merged
verified: 77ad3feec
tracker:
  pr: pjsip/pjproject#5154
---

### Describe the bug

A 439 (`PJSIP_SC_FIRST_HOP_LACKS_OUTBOUND_SUPPORT`) response to REGISTER is never handled, and the account is left permanently unregistered.

`pjsua_acc_config.use_rfc5626` defaults to `PJ_TRUE`, so for a TCP/TLS account pjsua emits exactly the combination RFC 5626 §6 names as the 439 (`PJSIP_SC_FIRST_HOP_LACKS_OUTBOUND_SUPPORT`) trigger — a `reg-id` Contact parameter (`update_regc_contact()`) plus the `outbound` option tag in `Supported` (`pjsua_regc_init()`). A registrar whose first hop does not add `Path: <…;ob>` **MUST** answer 439. An outbound-aware registrar behind an edge proxy that is not outbound-aware is an ordinary deployment.

`PJSIP_SC_FIRST_HOP_LACKS_OUTBOUND_SUPPORT` is defined in `sip_msg.h` and given a status phrase in `sip_msg.c`. Grepping the tree for that symbol, or for "First Hop", returns **only those two definitions** — nothing consumes it:

- `sip_reg.c`'s automatic response handling special-cases only 423 (`PJSIP_SC_INTERVAL_TOO_BRIEF`); everything else falls through to the failure callback.
- `regc_cb()`'s auto-retry list (`PJSIP_SC_REQUEST_TIMEOUT`, `PJSIP_SC_INTERNAL_SERVER_ERROR`, `PJSIP_SC_BAD_GATEWAY`, `PJSIP_SC_SERVICE_UNAVAILABLE`, `PJSIP_SC_SERVER_TIMEOUT`, `PJSIP_SC_TEMPORARILY_UNAVAILABLE`, 6xx) does not include 439 (`PJSIP_SC_FIRST_HOP_LACKS_OUTBOUND_SUPPORT`), so no re-registration is scheduled.
- `update_rfc5626_status()` only downgrades to `OUTBOUND_NA` from the `Require` header of a **2xx**; a 439 never reaches it.

So the account cannot register at all: the failure is reported through `on_reg_state`, nothing is retried, and every subsequent attempt — including a manual `pjsua_acc_set_registration()` — reproduces the same 439. A NAT-traversal feature that is **on by default** therefore makes standards-compliant deployments unusable, and the symptom ("registration fails forever with a status code nobody recognises") is expensive to diagnose in the field.

RFC 5626 §4.2.1 describes the intended client behaviour:

> *"If the registering UA receives a 439 (First Hop Lacks Outbound Support) response to a REGISTER request, it MAY re-attempt registration without using the outbound mechanism (subject to local policy at the client)."*

Given outbound is enabled by default, "MAY re-attempt without outbound" is close to mandatory in practice.

### Steps to reproduce

1. Configure an account over TCP or TLS with defaults, so `use_rfc5626 == PJ_TRUE`, registering through a first hop that does not add `Path: <…;ob>`, to a registrar implementing RFC 5626 §6.
2. The registrar responds 439 (`PJSIP_SC_FIRST_HOP_LACKS_OUTBOUND_SUPPORT`).
3. `on_reg_state` reports failure. No re-registration is scheduled, and every subsequent registration attempt receives 439 as well.

### PJSIP version

Reproduced by inspection on current `master` (`770a8e113`). Not version-specific — no 439 (`PJSIP_SC_FIRST_HOP_LACKS_OUTBOUND_SUPPORT`) handling has ever existed.

### Context

iOS softphone built on pjsua-lib. Found while aligning an RFC 8599 push design with RFC 5626; not yet hit in production, since we have no TCP/TLS deployment — reported because it is a latent, default-on hazard.

### Log, call stack, etc

```shell
Not captured against a live 439-returning registrar — we have no outbound-unaware
edge proxy available, and would rather say so than imply a test we did not run.
The report is based on reading the code paths named above on current master.
```

---

### Note on the fix: `rfc5626_status` cannot carry the fallback

We attempted two fixes and both failed review. Recording why, since the obvious approach does not work and the reason is not visible from the call site.

**Attempt 1** — in `regc_cb()`, set `acc->rfc5626_status = OUTBOUND_NA` and `schedule_reregistration()`. No effect: nothing regenerates the request. The Contact carrying `;reg-id` / `;+sip.instance` is cached in `acc->reg_contact`; `auto_rereg_timer_cb()` only rebuilds it inside `if (pj_strcmp(&tmp_contact, &acc->contact))`, which does not fire because the *plain* Contact is unchanged; and `pjsua_acc_set_registration()` reuses the existing regc, so the `Supported: outbound, path` header survives too. The retry is byte-identical and draws another 439.

**Attempt 2** — additionally call `destroy_regc()` before setting the status. Also defeated: `pjsua_regc_init()` itself calls `destroy_regc()` on the retry, and `destroy_regc()` resets `rfc5626_status` to `OUTBOUND_UNKNOWN`. `update_regc_contact()` then recomputes `need_outbound` purely from the transport in `acc->contact`, so a TCP/TLS account lands back on `OUTBOUND_WANTED` and the `reg-id` returns. The marker is erased before it is ever consulted.

**The conclusion is about the state, not the patch:** `rfc5626_status` is regc-scoped derived state, reset by every teardown and recomputed from scratch on every contact rebuild — so no fallback built on it can survive the path it needs to survive. A working fix needs a *persistent* per-account signal that outlives `destroy_regc()` and is consulted in `update_regc_contact()` alongside `!use_rfc5626`.

Note for whoever writes it: `use_rfc5626` gates outbound emission in **three** places, not one — the `reg-id` / `+sip.instance` Contact params in `update_regc_contact()`, and the `;ob` Contact URI parameter in both `pjsua_acc_create_uac_contact()` and the contact rebuild inside `acc_check_nat_addr()`. A fallback that misses the latter two still emits `;ob` after disabling outbound. The `Supported: outbound, path` header in `pjsua_regc_init()` needs no separate gate: it keys off `rfc5626_status`, which `update_regc_contact()` has already driven to `OUTBOUND_NA` by the time it is read.

There is precedent for that shape: the account-scoped server affinity added in #4964 keeps `sa_enabled` / `sa_pin_explicit` on `pjsua_acc` precisely to remember something about the path across registrations. We found no existing "capability rejected by this path" flag to reuse, and no other outbound-failure or downgrade path anywhere in the tree (Flow-Timer is parsed for the keep-alive interval only).

We are implementing that persistent-flag version now and will link a PR here once it is green on CI. Maintainers who would rather design this themselves — it is a change to the outbound state machine, not just a bug fix — should say so and we will stand down; the report above stands on its own either way. The two failed attempts, with review comments explaining each failure, are on a branch here: <https://github.com/laconicman/pjproject/pull/4> (deliberately kept as a draft — it does **not** work).

### Minor: a dead store in `update_regc_contact()`

The `done:` block opens with `acc->rfc5626_status = OUTBOUND_WANTED;`, but every path out of that block assigns the field again — `OUTBOUND_WANTED` when `need_outbound`, `OUTBOUND_NA` otherwise, and `OUTBOUND_NA` in the `else` branch where the Contact is reused unchanged. The initial assignment is therefore dead. Harmless, but it reads as if it were load-bearing and is what misled us into attempt 2; worth deleting.
