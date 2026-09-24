---
area: rfc5626-outbound
kind: bug
status: merged
verified: 77ad3feec
tracker:
  pr: pjsip/pjproject#5154
  followup_pr: pjsip/pjproject#5168
---

# A 439 (First Hop Lacks Outbound Support) leaves a pjsua account permanently unregistered

Upstream note for `pjsip/pjproject`. **Status: MERGED.** PR
[#5154](https://github.com/pjsip/pjproject/pull/5154) (`77ad3feec`) — *"pjsua: retry registration
without SIP outbound on 439"* — plus follow-up
[#5168](https://github.com/pjsip/pjproject/pull/5168) (`716ef557d`) — *"pjsua: complete the SIP
outbound rejection reset lifecycle"*, which added the `first_hop_changed` / `reset_outbound_rejection()`
handling in `pjsua_acc_modify()` so a first-hop change clears the sticky rejection instead of
retrying into another 439.

Originally verified 2026-08-04 against local master `4896a5e6a`; issue body kept in
[`439-first-hop-lacks-outbound.issue-body.md`](439-first-hop-lacks-outbound.issue-body.md). The problem statement below
describes the **pre-fix** state and is retained as the record of why the change was made.

**Still open from this line of work:** fork PR
[laconicman/pjproject#7](https://github.com/laconicman/pjproject/pull/7) — *"push the Contact to the
regc when outbound turns out unsupported"* — the remaining half, not yet sent upstream.

Unlike the other notes in this folder this is not a "fresh default into a modify-style API"
documentation trap: pjsua emits exactly the request that provokes a 439, has SIP outbound **on by
default**, defines the 439 status code, and then does nothing with it. The account stays
unregistered with no retry and no fallback.

Found while researching RFC 5626 / RFC 8599 alignment for a mobile softphone
(`offhook/docs/Push-vs-Active-Socket.md` §6, §7.4).

---

## Issue draft

**Title:** 439 (First Hop Lacks Outbound Support) is never handled: the account is left
unregistered with no retry and no non-outbound fallback

### Describe the bug

`pjsua_acc_config.use_rfc5626` defaults to `PJ_TRUE`:

> *"Control the use of SIP outbound feature. … This feature is highly useful in NAT-ed
> deployments, hence it is enabled by default. … Default: PJ_TRUE"*
>
> <sub>`pjsip/include/pjsua-lib/pjsua.h`</sub>

For a TCP or TLS account, pjsua therefore sends exactly the combination RFC 5626 §6 names as the
439 trigger — a `reg-id` Contact parameter plus the `outbound` option tag in `Supported`:

```c
/* pjsua_regc_init(), pjsip/src/pjsua-lib/pjsua_acc.c */
if (acc->rfc5626_status == OUTBOUND_WANTED ||
    acc->rfc5626_status == OUTBOUND_ACTIVE)
{
    ...
    hsup->count = 2;
    hsup->values[0] = pj_str("outbound");
    hsup->values[1] = pj_str("path");
    status = pjsip_regc_add_headers(acc->regc, &hdr_list);
}
```

```c
/* update_regc_contact(), same file */
if (need_outbound) {
    acc->rfc5626_status = OUTBOUND_WANTED;
    pj_strcat(&reg_contact, &acc->rfc5626_regprm);    /* ;reg-id=1        */
    pj_strcat(&reg_contact, &acc->rfc5626_instprm);   /* ;+sip.instance=… */
}
```

RFC 5626 §6 (Registrar Procedures) makes the registrar's side mandatory:

> *"if the REGISTER request contains the reg-id and the outbound option tag in a Supported header
> field, then the registrar MUST respond to the REGISTER request with a 439 (First Hop Lacks
> Outbound Support) response"*

— which happens whenever the first hop is a proxy that does not add a `Path` header with an `ob`
parameter. That is an ordinary deployment: an outbound-aware registrar behind an edge proxy that
is not outbound-aware.

pjsip defines the code:

```c
PJSIP_SC_FIRST_HOP_LACKS_OUTBOUND_SUPPORT = 439,   /* pjsip/include/pjsip/sip_msg.h */
pj_strset2( &status_phrase[439], "First Hop Lacks Outbound Support");  /* sip_msg.c */
```

but nothing consumes it. Grepping the tree for `439`, `FIRST_HOP_LACKS_OUTBOUND_SUPPORT` or
"First Hop" outside those two definitions returns nothing. Concretely:

- `sip_reg.c`'s automatic handling special-cases only 423 (Interval Too Brief); everything else
  falls through to the generic failure callback.
- pjsua's `regc_cb()` auto-retry list does not include 439:

  ```c
  if (acc->cfg.reg_retry_interval &&
      acc->ip_change_op != PJSUA_IP_CHANGE_OP_ACC_UPDATE_CONTACT &&
      (param->code == PJSIP_SC_REQUEST_TIMEOUT ||
       param->code == PJSIP_SC_INTERNAL_SERVER_ERROR ||
       param->code == PJSIP_SC_BAD_GATEWAY ||
       param->code == PJSIP_SC_SERVICE_UNAVAILABLE ||
       param->code == PJSIP_SC_SERVER_TIMEOUT ||
       param->code == PJSIP_SC_TEMPORARILY_UNAVAILABLE ||
       PJSIP_IS_STATUS_IN_CLASS(param->code, 600)))
  {
      schedule_reregistration(acc);
  }
  ```
  <sub>`pjsip/src/pjsua-lib/pjsua_acc.c`, `regc_cb()`</sub>

- `update_rfc5626_status()` only downgrades to `OUTBOUND_NA` based on the `Require` header of a
  **2xx**; a 439 never reaches it.

So the outcome is: `destroy_regc()`, `on_reg_state` reporting failure, **no retry, no fallback, and
`use_rfc5626` still `PJ_TRUE`** — so even a manual `pjsua_acc_set_registration()` reproduces the
same 439 forever. The account cannot register at all until the application notices the specific
status code and flips `use_rfc5626` itself.

RFC 5626 §4.2.1 describes the intended client behaviour:

> *"If the registering UA receives a 439 (First Hop Lacks Outbound Support) response to a REGISTER
> request, it MAY re-attempt registration without using the outbound mechanism (subject to local
> policy at the client). If the client has one or more alternate outbound proxies available, it MAY
> re-attempt registration through such outbound proxies."*

Given that pjsua enables outbound by default, "MAY re-attempt without outbound" is close to
mandatory in practice — the alternative is that enabling a NAT-traversal feature by default makes
some standards-compliant deployments unusable.

### Steps to reproduce

1. Configure an account over TCP or TLS with defaults (so `use_rfc5626 == PJ_TRUE`), registering
   through a first hop that does not add `Path: <…;ob>`, to a registrar that implements RFC 5626
   §5.3.
2. The registrar responds 439.
3. `on_reg_state` reports failure. No re-registration is scheduled. Every subsequent manual
   registration attempt receives 439 as well.

### PJSIP version

Verified on local master `4896a5e6a` (`2.17-98-g4896a5e6a`) by reading `pjsua_regc_init()`,
`update_regc_contact()`, `update_rfc5626_status()` and `regc_cb()` in `pjsua_acc.c`, the automatic
response handling in `sip_reg.c`, and the 439 definitions in `sip_msg.h` / `sip_msg.c`. Not
version-specific — no 439 handling has ever existed.

### Suggested fix

In `regc_cb()`, treat 439 as "outbound is not available on this path" rather than as a generic
failure:

```c
if (param->code == PJSIP_SC_FIRST_HOP_LACKS_OUTBOUND_SUPPORT &&
    acc->cfg.use_rfc5626)
{
    PJ_LOG(3,(THIS_FILE, "Acc %d: first hop lacks outbound support, "
                         "retrying registration without SIP outbound",
                         acc->index));
    acc->rfc5626_status = OUTBOUND_NA;      /* suppresses reg-id / +sip.instance
                                             * and the Supported: outbound header */
    schedule_reregistration(acc);
}
```

Setting `rfc5626_status = OUTBOUND_NA` is enough on its own: `update_regc_contact()` already
short-circuits on it, and `pjsua_regc_init()` only adds `Supported: outbound, path` for
`OUTBOUND_WANTED`/`OUTBOUND_ACTIVE`. It also keeps `cfg.use_rfc5626` untouched, so the account's
configured intent is preserved and outbound is retried after any event that resets the status
(`destroy_regc()` sets `OUTBOUND_UNKNOWN`).

If maintainers prefer the behaviour to be opt-in, a `pjsua_acc_config` flag (e.g.
`fallback_on_439`, default `PJ_TRUE` to match the default-on `use_rfc5626`) would work equally
well. Either way, adding 439 to the documented list of registration failure codes an application
must expect would help.

---

## Context for us (swift-pjsua)

- Tracked locally as **TD-22** (`docs/Tech-Debt.md`).
- We have not hit it: no TCP/TLS deployment yet, and Phase 0 has not run against real
  infrastructure. Filed because it is a *latent* default-on hazard — the moment we register over
  TLS through someone else's edge proxy we are on this path, and the symptom ("registration just
  fails, forever, with a status code nobody recognises") is expensive to diagnose in the field.
- App-side mitigation until fixed: on `on_reg_state` with code 439, re-apply the account config
  with `use_rfc5626 = false`. Note this goes through `pjsua_acc_modify()` and `use_rfc5626` is an
  `unreg_first` field, so it must not be done while a call is in progress
  (`offhook/docs/Push-vs-Active-Socket.md` §2).
