# Threading invariants — validated against pjproject master

The G1/G2 invariants are the load-bearing claims of this package: they are why pjsua1 (C) was
chosen over PJSUA2 (C++), and everything else is built on them. Until 2026-07-17 they rested on
our own reasoning plus a green live test suite. This is the record of checking them against
upstream source.

**Source:** DeepWiki deep review of `pjsip/pjproject` @ master, 2026-07-17
([conversation](https://deepwiki.com/search/validate-this-threading-model_0660c605-1423-43a6-82b0-741e14997b91?mode=deep),
24 citations; archived in `VoIP/deepwiki-store/`).

**Verdict: both invariants hold.** No change required. Three constraints and one upstream bug are
worth carrying forward.

## G1 — one dedicated PJLIB-registered thread for all `pjsua_*` calls ✅

- `pjsua_create()` → `pj_init()` → `pj_thread_init()` → `pj_thread_register()` registers **the
  calling thread** as PJLIB's main thread. There is no privileged main thread beyond that
  registration, so making our executor thread the caller is exactly right.
- Nothing in pjsua1 requires the API caller to be one of pjsua's worker threads. Public entry
  points take `PJSUA_LOCK` and/or `acquire_call()`, whose try-lock retry loop is safe from any
  registered thread.
- Upstream's own iOS sample **recommends** a dedicated thread for pjsua calls in non-trivial
  apps — our model is the documented approach, not a deviation.

**Caveat carried forward:** `pjsua_call_hangup_all()` deliberately does *not* take `PJSUA_LOCK`
("may deadlock", upstream #1305). We call it from `hangupAll()` and the Kit's `reset()`. Serialised
on our single executor thread this is fine; do not assume it is internally synchronised.

## G2 — callbacks hold no actor reference ✅ (and it is stronger than "tidy")

The review's most valuable finding: several callbacks run **with pjsua's locks held**, so a
synchronous re-entry would deadlock, not merely race.

| Callback | Lock state when invoked |
|---|---|
| `on_reg_state`, `on_reg_state2`, `on_ip_change_progress`, `on_incoming_call` | **`PJSUA_LOCK` held** |
| `on_call_state`, `on_call_tsx_terminate_session`, `on_mwi_state`, `on_auth_challenge` | no `PJSUA_LOCK`, but dialog/tsx `grp_lock` held upstream |

Documented order is **`PJSUA_LOCK` > dialog `grp_lock` > tsx `grp_lock`**; calling *up* that order
from inside a callback is an ABBA inversion. `on_call_tsx_terminate_session`'s header states the
application MUST NOT call any API acquiring a higher-order lock from within it.

Because our callbacks only read POD and `yield` a `Sendable` event, none of this can bite —
which is the point of preventing re-entrancy by construction rather than by convention.

## Constraints for work not yet written

1. **`on_auth_challenge` (PJSIP 2.17+)** is invoked with the tsx `grp_lock` held and must not
   acquire `PJSUA_LOCK`. The planned credential-on-demand design
   (`Configuration-Design.md` §4) must therefore use its **async/deferred** path — resolve the
   secret, then `pjsip_auth_clt_async_send_req` — never a synchronous Keychain read inside the
   callback. A biometric prompt there would block a SIP worker thread under a lock.
2. **Never add a synchronous `pjsua_*` request** (make_call/answer/hangup/register) to a
   callback. Under `on_reg_state2` or `on_incoming_call` that call would contend for a
   `PJSUA_LOCK` the worker already holds.
3. **`pjsua_acc_modify` / `pjsua_acc_del` carry a pre-existing upstream lock inversion:** both
   hold `PJSUA_LOCK` recursively while reaching tsx `grp_lock` via
   `pjsua_acc_set_registration()`. Upstream cannot be relied on to make these concurrency-safe
   against each other. *Our G1 serialisation already prevents the dangerous interleaving* — every
   engine call runs on one thread, so `reRegister` can never overlap `removeAccount`. Worth
   knowing before anyone proposes "parallelising" engine calls for throughput: that would
   reintroduce a bug we currently get for free.

## Related

`Configuration-Design.md` (D-CONFIG-2 uses the same prevent-by-construction approach for actor
re-entrancy); `Tech-Debt.md` TD-19; `PJSUACallbacks.swift` carries the callback table inline.
