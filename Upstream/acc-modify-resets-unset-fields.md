# `pjsua_acc_modify()` applies the whole struct, silently resetting fields the caller left at defaults

Upstream note for `pjsip/pjproject`. **Status: verified 2026-07-17 against master `c1ea7648`
(doc text read directly from `pjsua.h`) — ready to file as a documentation issue.**

This one cost us a real bug: our wrapper rebuilt a `pjsua_acc_config` from
`pjsua_acc_config_default()` on every silent-push re-REGISTER, which quietly reset server
affinity, contact-rewrite state and the negotiated registration timers on each call. Nothing in
the API documentation suggests that would happen, and the fix — `pjsua_acc_get_config()` first —
is not mentioned on `pjsua_acc_modify()` at all.

Filed as **documentation**, not behaviour: the whole-struct semantics are reasonable and
changing them would break callers. The gap is that they are undocumented.

---

## Issue draft

**Title:** Document that `pjsua_acc_modify()` applies the entire config, so unset fields are
reset — and that `pjsua_acc_get_config()` is the intended precursor

### Describe the bug

`pjsua_acc_modify()` applies the supplied `pjsua_acc_config` **wholesale**: every field is taken
from the struct, so any field the caller did not explicitly carry over is reset to whatever the
struct holds — typically the value from `pjsua_acc_config_default()`.

The documentation does not say this. The doc comment for `pjsua_acc_modify()`
(`pjsip/include/pjsua-lib/pjsua.h`) describes the parameter only as *"New account
configuration"*, and its two `Note:` bullets cover unregistration/re-registration side effects —
useful, but unrelated to this. There is no statement that unset fields are reset, and no
reference to `pjsua_acc_get_config()`.

The natural reading of "modify" plus a `*_config_default()` initialiser is that one builds a
fresh config, sets the fields to change, and calls modify. That is the one thing a caller must
not do. Fields silently lost this way include:

- `server_affinity`
- `allow_contact_rewrite`, `allow_via_rewrite`
- `reg_timeout`, `reg_delay_before_refresh`, `reg_retry_interval`,
  `reg_retry_random_interval`
- `rtp_cfg.port` (which also resets `next_rtp_port`)
- `ice_cfg_use` / `turn_cfg_use` (per-account ICE/TURN customisation)
- `cred_count` / `cred_info`, `proxy_cnt` / `proxy`

The failure mode is quiet: registration continues to work, so nothing looks wrong until a
setting the application configured once has stopped taking effect — potentially long after, and
with no log line connecting the two.

The correct pattern is used by pjsua's own app and tests, but only appears in sample code:

```c
pj_pool_t *tmp = pjsua_pool_create("tmp", 512, 256);
pjsua_acc_config cfg;
pjsua_acc_get_config(acc_id, tmp, &cfg);   /* read the LIVE config first */
cfg.vid_in_auto_show = PJ_TRUE;            /* touch only what you mean to change */
pjsua_acc_modify(acc_id, &cfg);
pj_pool_release(tmp);
```

### Steps to reproduce

1. Add an account with a non-default setting, e.g. `acc_cfg.reg_timeout = 120;` and
   `acc_cfg.allow_contact_rewrite = PJ_FALSE;`, via `pjsua_acc_add()`.
2. Later, change one unrelated field the way the API appears to invite:
   ```c
   pjsua_acc_config cfg;
   pjsua_acc_config_default(&cfg);
   cfg.id = ...; cfg.reg_uri = ...; cfg.cred_info[0] = ...;  /* only what I am changing */
   pjsua_acc_modify(acc_id, &cfg);
   ```
3. Read the account config back with `pjsua_acc_get_config()`.
4. Observe `reg_timeout` is back to `PJSUA_REG_INTERVAL` and `allow_contact_rewrite` is back to
   `PJ_TRUE`. No warning is logged.

### PJSIP version

Observed on 2.16; doc text and behaviour verified unchanged on current master (`c1ea7648`).

### Context

iOS softphone built on pjsua-lib, calling `pjsua_acc_modify()` from a silent-push handler to
re-REGISTER with updated RFC 8599 push parameters. Every push quietly reset the account's
registration timers and contact-rewrite setting until we switched to read-modify-write.

### Suggested fix (documentation only)

Add to the `pjsua_acc_modify()` doc comment, roughly:

> The entire configuration is applied. Fields not set in `acc_cfg` are **reset** to the values
> the struct carries — including those from `pjsua_acc_config_default()`. To change individual
> settings, retrieve the current configuration with `pjsua_acc_get_config()`, modify the fields
> you need, and pass that struct back. Do **not** build a fresh `pjsua_acc_config` for a partial
> update.

A matching sentence on `pjsua_acc_config_default()` ("intended for `pjsua_acc_add()`; see
`pjsua_acc_get_config()` for modifying an existing account") would close the loop, since that is
where callers start.

---

## Context for us (swift-pjsua)

- Hit in `PJSUA+Accounts.swift`'s `reRegister(_:updatingPush:)`, fixed 2026-07-17 to
  `pjsua_acc_get_config` + read-modify-write (design note D-CONFIG-4,
  `docs/Configuration-Design.md`). The pre-existing comment justifying the rebuild as "avoiding
  the fragile `pjsua_acc_get_config` + pool dance" was simply wrong.
- Found by a config-struct misuse sweep across every pjsua config struct we touch
  ([conversation](https://deepwiki.com/search/misuse-sweep-for-that-same-cla_bb8d7a19-cc1b-44fb-bd24-32dd7d442b8e?mode=deep)),
  which is also where the sibling `pjsua_transport_lis_restart` note came from.
- Field list above cross-checked against `pjsua_acc_config_default()` on master.
