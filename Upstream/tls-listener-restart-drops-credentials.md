# `pjsua_transport_lis_restart()` on a TLS listener silently drops certificates when passed a defaulted config

Upstream note for `pjsip/pjproject`. **Status: verified 2026-07-17 against master `c1ea7648`
(all three sources read directly) — ready to file as a documentation issue.**

Same class as the sibling `pjsua_acc_modify` note, but with a sharper edge: here the
documentation **actively invites** the mistake, and the consequence is a silent downgrade of
transport security rather than a lost timer.

We have not shipped a TLS transport yet, so this is not a bug we hit — it was found by sweeping
every pjsua config struct for the "fresh default into a modify-style API" hazard after the
`acc_modify` bug. We are filing it because `pjsua_handle_ip_change()` restarts every registered
listener internally, so any TLS deployment that handles network changes is on this path.

---

## Issue draft

**Title:** Document that `pjsua_transport_lis_restart()` takes TLS credentials from the supplied
config, so a defaulted `pjsua_transport_config` silently disables mutual TLS

### Describe the bug

`pjsua_transport_lis_restart()` consumes `tls_setting` from the `pjsua_transport_config` it is
given. Its doc comment (`pjsip/include/pjsua-lib/pjsua.h`) explicitly encourages this:

> *"For TLS transports, TLS settings can be specified in the transport config to update
> certificates, keys, and other TLS parameters during runtime."*
> *"For TCP/TLS: port, public_addr, bound_addr, and `tls_setting` are used."*

What it does not say is that the idiomatic way to produce that struct **erases** those
credentials. `pjsua_transport_config_default()` is:

```c
PJ_DEF(void) pjsua_transport_config_default(pjsua_transport_config *cfg)
{
    pj_bzero(cfg, sizeof(*cfg));
    pjsip_tls_setting_default(&cfg->tls_setting);
}
```
<sub>`pjsip/src/pjsua-lib/pjsua_core.c`</sub>

and `pjsip_tls_setting_default()` begins with `pj_memset(tls_opt, 0, sizeof(*tls_opt))`
(`pjsip/include/pjsip/sip_transport_tls.h`), restoring only `reuse_addr`, `qos_type`,
`qos_ignore_error`, `sockopt_ignore_error`, `proto`, `enable_renegotiation` and
`initial_timeout`. Every credential field — `cert_file`, `privkey_file`, `password`,
`ca_list_file`, `ciphers`, and the `verify_*` flags — is left zeroed.

The credentials are not merely *left unset* — they are actively destroyed.
`pjsua_transport_lis_restart()` forwards `&cfg->tls_setting` unconditionally (no emptiness
guard, unlike the neighbouring `public_addr` handling), and `pjsip_tls_transport_restart2()`
then does, for a non-`NULL` `opt`:

```c
if (opt) {
    pjsip_tls_setting_wipe_keys(&listener->tls_setting);            /* wipe live settings   */
    pjsip_tls_setting_copy(listener->factory.pool,
                           &listener->tls_setting, opt);            /* copy the zeroed one  */
    if (listener->cert) {
        pj_ssl_cert_wipe_keys(listener->cert);
        listener->cert = NULL;                                      /* free the live cert   */
    }
    if (listener->tls_setting.cert_file.slen ||                     /* all empty for a      */
        listener->tls_setting.ca_list_file.slen ||                  /* defaulted config, so */
        listener->tls_setting.ca_list_path.slen ||                  /* nothing is reloaded  */
        listener->tls_setting.privkey_file.slen)
    { /* load certificate … */ }
}
```
<sub>`pjsip/src/pjsip/sip_transport_tls.c`</sub>

So the listener ends up with `cert == NULL` and a zeroed `tls_setting`. The wipe is deliberate
and correct *when the caller supplies new credentials* — the comment even reads "Wipe old
certificate keys for security". The problem is purely that nothing warns the caller that
supplying a **defaulted** struct means supplying *no* credentials.

So the obvious sequence for "restart my TLS listener on a new port":

```c
pjsua_transport_config cfg;
pjsua_transport_config_default(&cfg);
cfg.port = new_port;
pjsua_transport_lis_restart(tp_id, &cfg);
```

brings the listener back **without its certificate, private key or CA list, and with
verification flags cleared** — mutual TLS silently disabled. The listener restarts successfully
and nothing is logged to indicate the security posture changed; the failure surfaces later as
peers being unable to authenticate, or as unauthenticated peers being accepted.

This is more likely than the equivalent `pjsua_acc_modify` trap, because the documentation
presents runtime certificate update as a *feature* of this call — so callers reach for a config
struct specifically expecting `tls_setting` to be meaningful, and the default initialiser is the
only documented way to construct one.

### Steps to reproduce

1. Create a TLS transport with real credentials:
   ```c
   pjsua_transport_config cfg;
   pjsua_transport_config_default(&cfg);
   cfg.port = 5061;
   cfg.tls_setting.cert_file = pj_str("cert.pem");
   cfg.tls_setting.privkey_file = pj_str("key.pem");
   cfg.tls_setting.verify_client = PJ_TRUE;
   pjsua_transport_create(PJSIP_TRANSPORT_TLS, &cfg, &tp_id);
   ```
2. Restart the listener the way the docs invite, changing only the port:
   ```c
   pjsua_transport_config cfg2;
   pjsua_transport_config_default(&cfg2);
   cfg2.port = 5062;
   pjsua_transport_lis_restart(tp_id, &cfg2);
   ```
3. The restart succeeds. The listener now has `cert == NULL`, a zeroed `tls_setting`, and
   `verify_client == PJ_FALSE`. No warning is emitted.

### PJSIP version

Verified on current master (`c1ea7648`) by reading the full chain: `pjsua.h` (doc),
`pjsua_core.c` (`pjsua_transport_config_default`, `pjsua_transport_lis_restart`),
`sip_transport_tls.h` (`pjsip_tls_setting_default`) and `sip_transport_tls.c`
(`pjsip_tls_transport_restart2`). Not version-specific — the defaulting behaviour is
long-standing; `restart2` is the newer path (`5daf06ca`, 2025-10-16).

### Context

iOS softphone on pjsua-lib. Not yet using TLS, so this was found by inspection rather than in
production. Raising it because `pjsua_handle_ip_change()` calls `restart_listener()` for every
registered transport (including `pjsip_tls_transport_restart`), so any TLS application that
handles Wi-Fi/cellular changes reaches this path — a mobile app is exactly where both TLS and
frequent IP changes are normal.

### Suggested fix (documentation only)

On `pjsua_transport_lis_restart()`, state that the supplied config is used as-is and add the
warning, roughly:

> **Note:** `tls_setting` is taken from `cfg` in full. Because
> `pjsua_transport_config_default()` zeroes all TLS credential fields, passing a freshly
> defaulted config will restart the listener **without** its certificate, private key, CA list
> and verification settings. Keep a copy of the `pjsua_transport_config` used to create the
> transport and re-supply it (adjusting only what you intend to change) rather than building a
> new one.

A cross-reference from `pjsua_handle_ip_change()` would help too, since that path restarts
listeners on the application's behalf and readers there will want to know how their TLS settings
are preserved.

---

## Context for us (swift-pjsua)

- Tracked locally as **TD-19** (`docs/Tech-Debt.md`). Not a live bug: `PJSUA.start()` only calls
  `pjsua_transport_create` (create-style, where a fresh default is correct), and we ship no TLS
  transport yet.
- Queued because the M2 IP-change milestone (`pjsua_handle_ip_change` driven by
  `NWPathMonitor`) walks straight into it — whoever adds TLS must carry the live `tls_setting`
  across the restart.
- Found by the same config-struct misuse sweep as the `acc_modify` note
  ([conversation](https://deepwiki.com/search/misuse-sweep-for-that-same-cla_bb8d7a19-cc1b-44fb-bd24-32dd7d442b8e?mode=deep)).
