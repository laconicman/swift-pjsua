# `pjsua_transport_lis_restart()` on a TLS listener silently drops certificates when passed a defaulted config

Upstream note for `pjsip/pjproject`. **Status: verified 2026-07-17 against master `c1ea7648`
(all three sources read directly); reproduced at runtime 2026-09-01 on the iOS Simulator against
PJSIP 2.17.0 `288de6142` — ready to file as a documentation issue.**

Same class as the sibling `pjsua_acc_modify` note, but with a sharper edge: here the
documentation **actively invites** the mistake, and the consequence is a silent downgrade of
transport security rather than a lost timer.

We have not shipped a TLS transport yet, so this is not a bug we hit — it was found by sweeping
every pjsua config struct for the "fresh default into a modify-style API" hazard after the
`acc_modify` bug, and then reproduced deliberately.

> **Correction, 2026-09-01.** An earlier revision of this note motivated the report with
> `pjsua_handle_ip_change()`, on the grounds that it restarts every registered listener. That was
> wrong and is withdrawn: `restart_listener()` in `pjsua_core.c` calls the three-argument
> `pjsip_tls_transport_restart()`, i.e. `restart2(factory, NULL, …)`, and a `NULL` `opt` skips the
> wipe-and-copy entirely. **The IP-change path preserves credentials.** What reaches the hazard is
> the application's own `pjsua_transport_lis_restart()` call — which, since
> [#5216](https://github.com/pjsip/pjproject/pull/5216) made a listener fail fast on an unloadable
> certificate, is precisely the recovery an application is now expected to perform.

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

### Two things that widen this beyond the listener

**It also disarms outbound mutual TLS.** `lis_create_transport()` applies the same
`listener->cert` to every client transport the factory spawns
(`pj_ssl_sock_set_certificate(ssock, pool, listener->cert)`). So the visible symptom of a
credential-less restart on a client-side UA is not "we stopped accepting inbound TLS" — it is the
registrar refusing to authenticate us, one restart later, with nothing logged in between.

**`restart2` cannot restore a `cert_direct` listener at all.** Listener start
(`pjsip_tls_transport_start2()`) has four independent credential branches — files, buffer, store,
and `cert_direct` via `pj_ssl_cert_load_direct()`. `restart2`'s reload block has three, chained
`else if`, and no `cert_direct`. A listener configured with `cert_direct` therefore loses its
certificate on any restart even when the caller re-supplies the identical `pjsip_tls_setting`.

### Context

iOS softphone on pjsua-lib. Not yet using TLS; found by inspection, then reproduced on the iOS
Simulator (Xcode 26.6, iOS 26.5, PJSIP 2.17.0 `288de6142`, Apple/Network.framework backend). The
three observations were: create with a valid `.p12` succeeds; restart with a defaulted config
returns `PJ_SUCCESS` and re-binds the listener on a new port; restart with an unloadable
certificate fails. The last is what establishes that the supplied `tls_setting` is what the
listener ends up with, and therefore that the middle one is a real credential drop rather than a
preserved setting.

### Suggested fix (documentation only)

On `pjsua_transport_lis_restart()`, state that the supplied config is used as-is and add the
warning, roughly:

> **Note:** `tls_setting` is taken from `cfg` in full. Because
> `pjsua_transport_config_default()` zeroes all TLS credential fields, passing a freshly
> defaulted config will restart the listener **without** its certificate, private key, CA list
> and verification settings. Keep a copy of the `pjsua_transport_config` used to create the
> transport and re-supply it (adjusting only what you intend to change) rather than building a
> new one.

A cross-reference from `pjsua_handle_ip_change()` would help too — in the other direction: that
path restarts listeners on the application's behalf via the preserving three-argument form, and a
reader who has just read the warning above will reasonably assume otherwise.

---

## Context for us (swift-pjsua)

- Tracked locally as **TD-19** (`docs/Tech-Debt.md`), confirmed by
  `Tests/SwiftPJSUATests/TLSTransportTests.swift`. Not a live bug *yet*: `PJSUA.start()` only calls
  `pjsua_transport_create` (create-style, where a fresh default is correct), and we ship no TLS
  transport.
- **Not** on the M2 IP-change path — see the correction above. It becomes ours the moment we ship
  a TLS transport, because TD-22's fail-fast recovery is `pjsua_transport_lis_restart()`.
- Found by the same config-struct misuse sweep as the `acc_modify` note
  ([conversation](https://deepwiki.com/search/misuse-sweep-for-that-same-cla_bb8d7a19-cc1b-44fb-bd24-32dd7d442b8e?mode=deep));
  the restart/recovery semantics were pinned in a follow-up deep consult
  ([conversation](https://deepwiki.com/search/design-question-about-tls-list_c88a6faf-8491-407d-a80a-4f4a03d46d05?mode=deep)).
- **The two defects that surfaced with it are filed**, as §5 and §7 of
  [pjproject#5232](https://github.com/pjsip/pjproject/issues/5232) (with the missing `cert_direct`
  branch as §6): `restart2`'s `if (!listener->ssock)` branch returns `PJ_SUCCESS` without
  re-opening the listener or reloading the certificate, so once a restart has failed no later
  restart can recover it (TD-22); and `ssl_sock_apple.m` labels every import failure
  `"Apple SSL error SecItemImport"` even on iOS, which takes the `SecPKCS12Import()` branch.
  **This note itself is still unfiled** — it is a documentation request against
  `pjsua_transport_lis_restart()`, which #5232 deliberately does not cover.
