# `disable_reg_on_modify` destroys the registration client — the docs still describe the pre-#4509 behaviour

Upstream note for `pjsip/pjproject`. **Status: verified 2026-08-17 against `upstream/master`
`27d28485f`, with the full history read — ready to file as a documentation issue.**

> **Revised 2026-08-17.** The 2026-08-04 draft framed this as an internal inconsistency and offered
> "guard `destroy_regc()` with the flag" as an alternative fix. **That alternative is wrong and has
> been removed:** it would revert [#4509](https://github.com/pjsip/pjproject/pull/4509), a
> deliberate, reviewed, `type: bug`-labelled change by the maintainer. What is actually wrong is
> only the documentation, which was not updated when the behaviour changed. Filing the earlier
> version would have proposed undoing a maintainer's own fix — worth recording as a caution: read
> `git log -S` on the flag *before* writing the issue, not after.

Found while designing a mobile softphone's precedence rules for "reconfigure the account" vs.
"an inbound call is arriving" (`offhook/docs/Push-vs-Active-Socket.md` §1.2). `disable_reg_on_modify`
is the knob whose name promises "apply this config without touching my registration", and its real
contract is materially different.

---

## The history, which is the whole story

| PR | Date | What it did to the `unreg_first` block |
|---|---|---|
| [#3910](https://github.com/pjsip/pjproject/pull/3910) `e7e7f28f1` | 2024-04-03 | Introduced the flag. Guard on the **whole block**: `if (unreg_first && !cfg->disable_reg_on_modify)` — so setting it skipped the un-REGISTER, the re-REGISTER **and** `destroy_regc()`. |
| [#4509](https://github.com/pjsip/pjproject/pull/4509) `ce81bb698` | 2025-07-24 | Moved the guard **inward**: `if (unreg_first) { if (acc->regc && !cfg->disable_reg_on_modify) {…} destroy_regc(acc, PJ_TRUE); …}`. Rationale in the PR body: *"destroying old regc may still be needed so we can use the updated registration related settings."* Approved by nanangizz, labelled `component: pjsua-lib` / `type: bug`, milestone release-2.16. |

The behaviour change is intentional and, for its purpose, correct. **The doc comment has read the
same words since #3910 and describes the #3910 semantics.**

---

## Issue draft

**Title:** Document that `disable_reg_on_modify` still destroys the registration client, so the
application must re-register

### Describe the bug

This is a documentation gap, not a code defect — the code does what
[#4509](https://github.com/pjsip/pjproject/pull/4509) intended.

`pjsua_acc_config.disable_reg_on_modify` is documented as:

> *"Specify whether account modification with `pjsua_acc_modify()` should automatically update
> registration if necessary, for example if account credentials change. Disable this when immediate
> registration is not desirable, such as during IP address change. Default: `PJ_FALSE`."*
>
> <sub>`pjsip/include/pjsua-lib/pjsua.h`; `pjsip/include/pjsua2/account.hpp` carries the same text
> for `AccountRegConfig::disableRegOnModify`</sub>

That text is accurate for the behaviour #3910 shipped, where the flag guarded the entire
`unreg_first` block. Since #4509 it guards only the requests:

```c
    /* Unregister first */
    if (unreg_first) {
        if (acc->regc && !cfg->disable_reg_on_modify) {
            status = pjsua_acc_set_registration(acc->index, PJ_FALSE);
            ...
        }
        destroy_regc(acc, PJ_TRUE);          /* runs regardless of the flag */
        ...
    }

    /* Update registration */
    if (update_reg && !cfg->disable_reg_on_modify) { ... }
```
<sub>`pjsip/src/pjsua-lib/pjsua_acc.c`, `pjsua_acc_modify()`</sub>

and `destroy_regc()` does considerably more than free an object:

```c
static pj_status_t destroy_regc(pjsua_acc *acc, pj_bool_t force)
{
    if (acc->regc) {
        pj_status_t status = pjsip_regc_destroy2(acc->regc, force);
        ...
    }
    acc->regc = NULL;
    acc->contact.slen = 0;
    acc->reg_mapped_addr.slen = 0;
    acc->rfc5626_status = OUTBOUND_UNKNOWN;
    acc->rfc5626_flowtmr = 0;
    ...
}
```
<sub>same file</sub>

With the flag set there is no un-REGISTER, so `regc->has_tsx` is false and
`pjsip_regc_destroy2()` takes its immediate-teardown branch — the one that runs
`pjsip_endpt_cancel_timer(regc->endpt, &regc->timer)`. **The refresh timer is gone the moment
`pjsua_acc_modify()` returns.**

So after

```c
pjsua_acc_config cfg;
pjsua_acc_get_config(acc_id, pool, &cfg);        /* read-modify-write, as required */
cfg.disable_reg_on_modify = PJ_TRUE;
cfg.cred_info[0].data = pj_str("new-password");  /* an unreg_first field */
pjsua_acc_modify(acc_id, &cfg);
```

the application is in a state the documentation does not describe:

- the **server still holds the binding** — no un-REGISTER was sent (this part *is* documented);
- the client has **no `regc` and no refresh timer**, so it will never renew that binding;
- `acc->contact` is empty, so dialogs created before the next successful REGISTER get a Contact
  synthesised from the receiving transport's local address (`pjsua_acc_create_uas_contact()`)
  rather than the registered one — without `contact_params` / `contact_uri_params`;
- `rfc5626_status` is back to `OUTBOUND_UNKNOWN`, discarding negotiated SIP-outbound state and any
  `Flow-Timer` the registrar supplied.

Nothing is logged and no callback fires. An application that reads the doc comment, sets the flag
to "apply configuration without registration traffic", and does not separately call
`pjsua_acc_set_registration()` goes dark for inbound calls when the binding expires — anywhere from
a few minutes to an hour later, with no diagnostic pointing at `pjsua_acc_modify()`.

The gap is easy to fall into precisely because the flag's stated use case ("during IP address
change") is one where the application *is* expected to re-register afterwards, so the omission
never shows up there.

### Steps to reproduce

1. Add an account with `reg_uri` set and let it register.
2. `pjsua_acc_get_config()`, set `disable_reg_on_modify = PJ_TRUE`, change any field that sets
   `unreg_first` (credentials, `reg_contact_uri_params`, `reg_uri`, `transport_id`, …).
3. Call `pjsua_acc_modify()`. It returns `PJ_SUCCESS` and sends no SIP, as documented.
4. `pjsua_acc_get_info()` now reports the account unregistered, and no REGISTER is ever sent again.
   The binding expires silently on the server.

### PJSIP version

Verified on `master` `27d28485f`. Behaviour dates from `ce81bb698` (#4509, 2.16); documentation
text dates from `e7e7f28f1` (#3910) and has not changed since.

### Context

iOS softphone on pjsua-lib (pjsua1). The design question was "how do we apply a configuration
change that arrives while a call is in progress, without removing the binding the call depends on?"
`disable_reg_on_modify` looks like the answer to that question and is not one — which is fine, but
only discoverable by reading `pjsua_acc_modify()` and `destroy_regc()`.

### Suggested fix (documentation)

On `pjsua_acc_config::disable_reg_on_modify` in `pjsua.h`, and on
`AccountRegConfig::disableRegOnModify` in `pjsua2/account.hpp`:

> **Note:** this flag suppresses the un-REGISTER and re-REGISTER requests, but the account's
> registration client is still destroyed when a modified field requires re-registration, so that
> the next registration picks up the updated settings (see #4509). Consequently the existing
> binding remains on the server but is **no longer refreshed**, and the account's Contact and
> SIP-outbound state are reset. The application is responsible for calling
> `pjsua_acc_set_registration()` (pjsua2: `Account::setRegistration()`) once registration is
> appropriate again — as `pjsua_handle_ip_change()` does internally. This flag is therefore not a
> way to apply a registration-affecting configuration change while keeping an existing
> registration alive; no such mechanism currently exists.

A `PJ_LOG(4, …)` at the `destroy_regc()` call noting that the registration client was destroyed and
that the caller must re-register would make the state visible in a trace, where today it is
invisible. Offered as a separate, optional half — happy to drop it if you would rather keep the
change documentation-only.

---

## Context for us (swift-pjsua)

- Tracked locally as **TD-21** (`docs/Tech-Debt.md`).
- Not a live bug: `reRegister` never sets `disable_reg_on_modify`, and per TD-21 it must not.
- Filed because the push-vs-active-socket design
  (`offhook/docs/Push-vs-Active-Socket.md` §2) evaluated and rejected this flag as the
  "defer the config change" mechanism. The rejection is only obvious once you have read
  `destroy_regc()` — which is the point of the issue.
- **Our design and #4509's rationale agree**, which is reassuring: the maintainer's "destroy the
  regc so the next registration uses the new settings" is the same shape as our pending-config slot
  drained when the last call ends. We simply have to own the re-registration.
