# `pjsua_acc_modify()` with `disable_reg_on_modify` still destroys the regc, silently stopping registration refresh

Upstream note for `pjsip/pjproject`. **Status: verified 2026-08-04 against local master
`4896a5e6a` (`2.17-98-g4896a5e6a`), sources read directly — ready to file as a documentation
issue** (arguably a behaviour issue; the draft offers both readings and lets maintainers pick).

Third member of the family that already produced
[`acc-modify-resets-unset-fields`](acc-modify-resets-unset-fields.md) and
[`tls-listener-restart-drops-credentials`](tls-listener-restart-drops-credentials.md): a
modify-style API whose documented contract is narrower than what it actually does.

Found while designing a mobile softphone's precedence rules for "reconfigure the account" vs.
"an inbound call is arriving" (`offhook/docs/Push-vs-Active-Socket.md` §1.2). `disable_reg_on_modify`
is the one knob whose name promises "apply this config without touching my registration", and it is
exactly the knob that quietly ends the registration.

---

## Issue draft

**Title:** Document that `pjsua_acc_modify()` destroys the registration client even when
`disable_reg_on_modify` is set, so the binding stops being refreshed

### Describe the bug

`pjsua_acc_config.disable_reg_on_modify` is documented as:

> *"Specify whether account modification with `pjsua_acc_modify()` should automatically update
> registration if necessary, for example if account credentials change. Disable this when immediate
> registration is not desirable, such as during IP address change. Default: `PJ_FALSE`."*
>
> <sub>`pjsip/include/pjsua-lib/pjsua.h`</sub>

That reads as "suppress the REGISTER traffic; leave my registration alone". What the code does is
suppress the traffic but destroy the registration client regardless:

```c
    /* Unregister first */
    if (unreg_first) {
        if (acc->regc && !cfg->disable_reg_on_modify) {
            status = pjsua_acc_set_registration(acc->index, PJ_FALSE);
            ...
        }
        destroy_regc(acc, PJ_TRUE);          /* <-- not guarded by disable_reg_on_modify */
        ...
    }

    /* Update registration */
    if (update_reg && !cfg->disable_reg_on_modify) {
        if (acc->cfg.reg_uri.slen)
            status = pjsua_acc_set_registration(acc->index, PJ_TRUE);
    }
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
<sub>`pjsip/src/pjsua-lib/pjsua_acc.c`</sub>

`pjsip_regc_destroy2()` in turn cancels the regc's own refresh timer
(`pjsip_endpt_cancel_timer(regc->endpt, &regc->timer)`, `pjsip/src/pjsip-ua/sip_reg.c`).

So after

```c
pjsua_acc_config cfg;
pjsua_acc_get_config(acc_id, pool, &cfg);        /* read-modify-write, as documented */
cfg.disable_reg_on_modify = PJ_TRUE;
cfg.cred_info[0].data = pj_str("new-password");  /* an unreg_first field */
pjsua_acc_modify(acc_id, &cfg);
```

the application is left in a state that no part of the documentation describes:

- the **server still holds the binding** (no un-REGISTER was sent — this part is as documented);
- the client has **no `regc` and no refresh timer**, so it will never renew that binding;
- `acc->contact` is empty, so subsequent dialogs get a Contact synthesised from the transport's
  local address (`pjsua_acc_create_uas_contact()`) rather than the registered one;
- `rfc5626_status` has been reset to `OUTBOUND_UNKNOWN`, discarding the negotiated SIP-outbound
  state and any `Flow-Timer` the registrar supplied.

`pjsua_acc_get_info()` reports the account as no longer registered, but nothing is logged and no
callback fires, so an application that does not poll simply goes dark for inbound calls when the
binding expires.

The behaviour is harmless in the use case the doc names, because pjsua's own IP-change path always
calls `pjsua_acc_set_registration()` afterwards
(`pjsua_acc_update_contact_on_ip_change()` / `pjsua_acc_handle_call_on_ip_change()`). It is only a
problem for the other reading of the flag — "apply configuration quietly" — which the wording
invites.

### Steps to reproduce

1. Add an account with `reg_uri` set and let it register.
2. Read the live config with `pjsua_acc_get_config()`, set `disable_reg_on_modify = PJ_TRUE`, change
   any `unreg_first` field (credentials, `reg_contact_uri_params`, `reg_uri`, `transport_id`, …).
3. Call `pjsua_acc_modify()`. It returns `PJ_SUCCESS`; no SIP is sent, as expected.
4. Observe that `pjsua_acc_get_info()` now reports the account unregistered, and that no REGISTER is
   ever sent again — the binding expires silently on the server.

### PJSIP version

Verified on local master `4896a5e6a` (`2.17-98-g4896a5e6a`) by reading `pjsua_acc_modify()`,
`destroy_regc()` and `pjsip_regc_destroy2()` directly. Not version-specific: the unconditional
`destroy_regc()` call predates the flag.

### Context

iOS softphone on pjsua-lib (pjsua1). The design question was "how do we apply a configuration
change that arrives while a call is in progress, without removing the binding the call depends
on?" — `disable_reg_on_modify` is the natural answer to that question and turns out not to be a
safe one.

### Suggested fix

Either of these would resolve it; the documentation option is the smaller change.

**A — documentation.** On `disable_reg_on_modify`, add:

> **Note:** this flag suppresses the un-REGISTER and re-REGISTER requests, but the account's
> registration client is still destroyed when a modified field requires re-registration. The
> existing binding therefore remains on the server but is **no longer refreshed**, and the
> account's Contact and SIP-outbound state are reset. Applications must call
> `pjsua_acc_set_registration()` themselves once it is appropriate to do so — as
> `pjsua_handle_ip_change()` does internally. There is currently no way to apply a
> registration-affecting configuration change while leaving an existing registration intact.

**B — behaviour.** Guard the `destroy_regc()` call with `!cfg->disable_reg_on_modify` as well. This
would make the flag mean what its name says, but it changes the IP-change path (where destroying
the regc is desirable, because the old transport is gone), so it would need
`pjsua_acc_update_contact_on_ip_change()` to destroy the regc explicitly instead. Maintainers are
better placed to judge whether that is worth the churn.

---

## Context for us (swift-pjsua)

- Tracked locally as **TD-21** (`docs/Tech-Debt.md`).
- Not a live bug: `reRegister` never sets `disable_reg_on_modify`. Filed because the
  push-vs-active-socket design (`offhook/docs/Push-vs-Active-Socket.md` §2) explicitly considered
  and rejected this flag as the "defer the config change" mechanism — the rejection is only obvious
  once you have read `destroy_regc`.
- The engine's own answer to the same problem is a pending-config slot in the *app*, drained when
  the last call ends. No pjsua flag is involved.
