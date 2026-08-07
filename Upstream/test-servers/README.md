# SIP test servers

Minimal Swift registrars that reproduce SIP behaviour the public test harnesses
cannot. Written to verify the upstream 439 fix
(`439-first-hop-lacks-outbound-not-handled.md`, pjsip/pjproject#5146), kept
because the scenarios recur and each one caught a real defect.

They are plain `swift`-runnable scripts, deliberately **not** a SwiftPM target:
`swift-pjsua` is iOS-only, and a macOS socket executable has no business in its
build graph.

## Why not `tests/pjsua`

pjproject's SIPp harness hardcodes UDP (`mod_sipp.py`), while SIP outbound only
applies to TCP/TLS — so it cannot exercise this at all. SIPp's `-m 1` also ends
the scenario after one call, but a pjsua retry arrives on a **new** TCP
connection with a new Call-ID, i.e. a second call. Both are why these exist.

## Scenarios

| Script | Serves | Expected |
|---|---|---|
| `run-439-test.sh` | TCP; 439 to any REGISTER advertising outbound, 200 otherwise | 2 REGISTERs — the retry drops `;ob`, `;reg-id`, `;+sip.instance` and the `Supported: outbound, path` header, and is accepted |
| `run-439-udp-test.sh` | UDP; 439 to everything | 1 REGISTER — a UDP account never advertises outbound, so a 439 is non-conformant and must be ignored |
| `run-regparams-test.sh` | TCP; 200 **without** `Require: outbound`, account configured with REGISTER-only push params | Refresh drops `reg-id`/`+sip.instance` but keeps `pn-provider` (URI param) and `pn-prid` (header param) — needs pjsua built with `--reg-contact-params` / `--reg-contact-uri-params` |
| `run-failover-test.sh` | TCP; 200 **without** `Require: outbound`, then 439 to the refresh | 3 REGISTERs — the refresh still carries `reg-id` even though `rfc5626_status` has gone `OUTBOUND_NA`, so the 439 must still trigger the fallback |

`run-failover-test.sh` is the subtle one. `update_rfc5626_status()` drops the status on a 200
lacking `Require: outbound` and rewrites `acc->reg_contact`, but never calls
`pjsip_regc_update_contact()` — so the regc keeps sending the original reg-id
Contact. A fix gated on `rfc5626_status` looks right and silently leaves the
account unregistered here. That is the steady state for any account registered
to a registrar without outbound support.

## Running

Needs a built `pjsua` from the `pjproject` checkout next to this repo. Override
with `PJSUA=/path/to/pjsua` if it lives elsewhere.

```bash
./run-439-test.sh && grep -E "REGISTER #|TOTAL" registrar.log
```

Each run takes 1.5–3 minutes: the first retry waits out
`reg_first_retry_interval` (~55 s, not exposed on the pjsua CLI), and the
failover run additionally waits for a refresh at `--reg-timeout 40`.

Each script writes `registrar*.log` (wire view) and `pjsua-*.log` (stack view);
the pairing is what makes a failure diagnosable.

## Gotchas that cost time

- **Relink staleness.** `make pjsua` will not relink when only `libpjsua.a`
  changed. `rm` the binary first, or you will test the previous build. This bit
  three separate verification runs.
- **Header changes need `make clean`.** pjproject does not track header
  dependencies, so editing `pjsua_internal.h` and rebuilding incrementally
  leaves objects compiled against two different `struct pjsua_acc` layouts —
  which corrupts memory shortly after account setup rather than failing loudly.
- **Switching branches does not rebuild the libraries.** `make pjsua` relinks
  against whatever `libpjsua.a` happens to be on disk, so checking out a branch
  and rebuilding only the app silently tests the *previous* branch's library.
  Rebuild `pjsip/build` after every checkout, and check the timestamps if a
  result looks impossible — a "baseline" run that already shows the fix is the
  giveaway.
- Registrar stdout is line-buffered (`setvbuf`) so output survives the script
  killing the process at the end of a run.

## `run-regparams-test.sh` needs a patched pjsua

The REGISTER-only Contact parameters (`reg_contact_params`,
`reg_contact_uri_params` — where RFC 8599 push parameters live) exist in
`pjsua_acc_config` but the stock sample app exposes no way to set them. That is
why a change dropping them from re-registrations was reviewable only by
argument, not by test. The two options were added upstream-side; until that
lands, this script needs a pjsua built from that branch.
