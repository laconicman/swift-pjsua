# Registration lifecycle — how the engine changes a live registration

**Status: implemented 2026-10-11.** Discharges Tech-Debt TD-23. Every pjsua and pjsip claim below
was read in the source of the binary we ship — PJSIP 2.17.0, `288de6142`, via `swift-pjsip` 0.2.1
— and the same code is unchanged on upstream master `98f3145e5` (2026-10-08). Line numbers are
`288de6142`'s. Consulted in a DeepWiki deep thread
([conversation](https://deepwiki.com/search/an-ios-softphone-on-pjsua1-c-a_68487496-de63-4676-b721-6a55752dee54?mode=deep));
where its answers disagreed with the source, the source is what is recorded here.

## 0. Verdict

The engine's registration calls used to return before the pjsua work they started had finished,
and fired into whatever the account's registration session was doing:

- `reRegister` called `pjsua_acc_modify` and then `pjsua_acc_set_registration(PJ_TRUE)`. Modify
  re-registers by itself when the Contact or the credential changes, so the trailing call failed
  with `PJSIP_EBUSY` and the method threw although it had worked (TD-23). With a REGISTER still in
  flight, modify orphaned it, and pjsip answers a 401 on an orphan with the old request: the
  push-less Contact could reach the registrar after the new one.
- `removeAccount` let `pjsua_acc_del` send its un-REGISTER and destroy the session at once. With a
  REGISTER in flight the un-REGISTER was refused and the REGISTER orphaned; its 401 was answered,
  and the registrar kept a binding, push parameters and all, for an account that no longer existed.
- `addAccount` let `pjsua_acc_add` send the first REGISTER, which ignores whether the send worked.
- `setRegistration` was refused with `PJSIP_EBUSY` during any transaction.
- `handleIPChange` returned at kickoff, and a second call ran a second sequence over the first.

Every registration-affecting call is now a **registration operation**. Operations run one at a
time per account, an IP change alone across all of them, and each runs to its end: it acts only
while the account's session is quiet, waits for pjsua's report of every transaction it sends,
owns the un-REGISTER → REGISTER order itself, and is done when the registrar's 2xx says so. The
engine keeps the session state from pjsua's callbacks; the callbacks still hold no actor
reference. Nothing polls, and `PJSIP_EBUSY` is never read as success: it is thrown at the send and
caught where it is recoverable.

## 1. What pjsua and pjsip do

| Fact | Where |
|---|---|
| A changed `reg_contact_uri_params`, `contact_uri_params` or credential sets `update_reg` and `unreg_first`; modify then sends an un-REGISTER, swallows its failure, `destroy_regc(acc, PJ_TRUE)`, and registers on a fresh session | `pjsua_acc.c:1550-1574`, `:1666-1724`, `:1928-1959` |
| With `disable_reg_on_modify`, modify sends neither, and still destroys the session on `unreg_first`. The flag is read from the struct passed in, never stored | `pjsua_acc.c:1930`, `:1940`, `:1949` |
| `pjsua_acc_add` sends the first REGISTER only when `register_on_acc_add` is set, and ignores the result | `pjsua_acc.c:906-908` |
| A send on a session with a transaction pending fails `PJSIP_EBUSY`; nothing is sent | `sip_reg.c:1586-1594` |
| Destroying a session with a transaction pending only sets `_delete_flag` and drops the callback | `sip_reg.c:198-206` |
| A 401/407 on such an orphan is still answered, from `tsx->last_tx`: the old Contact | `sip_reg.c:1269-1399` |
| `pjsua_acc_del` un-REGISTERs and destroys the session without waiting for the answer | `pjsua_acc.c:1097-1106` |
| `pjsua_acc_set_registration` cancels the automatic-retry timer on entry, refuses an un-REGISTER without a session ("Currently not registered"), releases `PJSUA_LOCK` around the send, and calls `on_reg_started2` after taking it back | `pjsua_acc.c:3790-3794`, `:3843-3846`, `:3879-3913` |
| `on_reg_started2` fires only from `pjsua_acc_set_registration`; the session's own refresh timer and the 401/423 resends start transactions silently | `pjsua_acc.c:3904-3914`; `sip_reg.c:854-883`, `:1366-1382` |
| `pjsip_regc_get_info().is_busy` is the session's reference count or its open transaction. The worker holds a reference across the whole response handling, callback included, and drops it last | `sip_reg.c:239`, `:1206`, `:1561-1573` |
| `regc_cb` ignores any session but the account's current one; it also returns early, without `on_reg_state2`, on a `PJSIP_EBUSY` status and when `acc_check_nat_addr` rewrites the Contact (which sends its own replacement REGISTER) | `pjsua_acc.c:3068-3071`, `:3101-3105`, `:3179-3189` |
| That rewrite re-registers with `pjsua_acc_set_registration` and ignores the result; with the un-REGISTER method the session is already gone | `pjsua_acc.c:2636-2668` |
| An un-REGISTER's 2xx always reports expiry 0, so `regc_cb` destroys the session; every failure destroys it too | `sip_reg.c:1141-1144`; `pjsua_acc.c:3112-3170` |
| A failed un-REGISTER (408, 5xx, 480, 6xx) schedules an automatic re-REGISTER — the retry block has no `is_unreg` check | `pjsua_acc.c:3349-3360`, `:5506-5520` |
| After a 2xx, pjsip schedules the refresh before it calls back, so `next_reg` read in `on_reg_state2` is the delay to the next REGISTER | `sip_reg.c:1542`, `:1562` |
| `pjsua_acc_get_info().expires` is the session's `next_reg`, read under `PJSUA_LOCK`: 0 while a transaction is pending, `PJSIP_EXPIRES_NOT_SPECIFIED` with no session | `pjsua_acc.c:3988-3994`; `sip_reg.c:245-246` |
| `pjsua_handle_ip_change` during a sequence logs "Previous IP address change handling still in progress" and runs another over the same accounts | `pjsua_core.c:4172-4186` |
| An IP change re-registers each account itself; a session it finds busy is destroyed and rebuilt | `pjsua_acc.c:5646-5720` |
| `COMPLETED` is reported once every account's step has ended | `pjsua_acc.c:5899-5929` |

There is no public pjsua1 path to swap a Contact in **one** REGISTER — the old Contact with
`expires=0` beside the new one, which RFC 3261 §10.3 makes atomic. `pjsip_regc` can carry it
(`pjsip_regc_update_contact` and its removed-contact list), but pjsua uses that only for its own
Contact rewrites (`pjsua_acc.c:5427-5430`), and the session is not reachable through `pjsua.h`.

## 2. The design

### Signals

`on_reg_state2`, `on_reg_started2` and `on_ip_change_progress(COMPLETED)` yield
`RegistrationSignal`s onto a third stream, separate from `events` and `callEvents`, which a task on
the engine actor reads for the engine's life and applies in the actor's own turns. The callbacks
read POD and yield; G2 holds.

- **`settled`** — one REGISTER or un-REGISTER ended: `renew`, status, SIP code, granted expiry,
  the Contact URIs the response listed, and, after a 2xx that keeps a binding, `refreshIn`: the
  session's `next_reg`, the seconds until its refresh timer sends the next REGISTER with no callback.
- **`started`** — a transaction pjsua started **by itself**: an automatic retry, a Contact rewrite,
  an IP-change step; with `pending`, `is_busy` read in the callback. Starts reported on the engine's
  own thread are dropped. They come from calls the engine made, which it records at the call, and
  the reading cannot be trusted there: `pjsua_acc_set_registration` releases `PJSUA_LOCK` around
  the send, so a fast response can be reported on the worker before the engine thread takes the lock
  back, while the worker still holds its reference on the session. `is_busy` then reads open after
  the settlement went out, and the session would stay pending with nothing to follow. On pjsua's
  own thread the reading holds: the one worker processes the response only after the callback
  returns.
- **`ipChangeCompleted`**.

### Sessions and quiet

Per account the engine keeps `unregistered`, `registered(refreshDue:)` or `pending`. Only signals
and the engine's own sends write it. An account is **quiet** when its session is not pending and
its refresh is not due within 2 s (`refreshIn` counts whole seconds, rounded down).

### Operations

`addAccount`, `setRegistration`, `reRegister`, `removeAccount` and `handleIPChange` are
operations. Each takes a turn over its scope — one account, or every account for an IP change —
first come, first served among conflicting scopes, and runs in a task of its own, so cancelling a
caller never leaves an account between its un-REGISTER and its REGISTER. A request that finds an
operation of its kind still waiting for its turn joins it: `reRegister` per account and generation,
the latest push parameters winning; `handleIPChange` globally, so requests made during a sequence
coalesce into one more.

`RegistrationWait` decides only when the caller gets control back: `.dispatched` once the request
is sent (or the sequence started), `.confirmed(timeout:)`, the default, when the operation is done.
The operation runs on to its end either way.

Inside an operation every step follows a quiet reading with no suspension between: send, mark
dispatched, await the answer. A send pjsua refuses with `PJSIP_EBUSY` sent nothing; the engine marks
the session pending, waits for quiet again, and sends again. Each operation opens a mailbox when it
starts, so no signal is lost between a synchronous step and the wait that follows. Waits are woken
by signals, never by timers.

| Operation | Steps |
|---|---|
| `addAccount` | `pjsua_acc_add` with `register_on_acc_add` off, in the same actor turn as the operation's creation, so it is the account's first; then REGISTER → await |
| `setRegistration` | REGISTER or un-REGISTER → await |
| `reRegister`, push parameters changed on a registered account | un-REGISTER → await → modify with `disable_reg_on_modify` → REGISTER → await |
| `reRegister`, anything else | modify with `disable_reg_on_modify` → REGISTER → await. pjsua decides the session: a changed credential gets a fresh one, nothing changed keeps it. No un-REGISTER: the binding keeps its Contact, so the registrar replaces it |
| `removeAccount` | if registered: un-REGISTER → await; then `pjsua_acc_del`, which finds no session left and sends nothing |
| `handleIPChange` | wait until no account is busy → `pjsua_handle_ip_change` → await `COMPLETED` |

The engine decides the un-REGISTER from its own record — `appliedPush` against the stored push
parameters — and leaves every other field rule to `pjsua_acc_modify`. The flag is set only where
TD-21 allows it: the engine registers itself in the same synchronous step.

### Correlation

The answer to the engine's (un-)REGISTER is the next settlement of that kind after the send. The
send came from a quiet session, whose reports were all applied, so the next one is its own —
including when a fast registrar's 2xx is reported before pjsua returns from the send. When a NAT
Contact rewrite swallows the 2xx and re-registers, the rewrite's settlement answers instead, which
is the binding the registrar now holds.

### Done

A 2xx with an expiry and, when the account has push parameters and the registrar lists bindings,
one binding carrying them (names and values compared without case). RFC 3261 §10.3 makes the list a
SHOULD, so a 2xx without one is taken at its word. Otherwise `RegistrationError`, which names the
account in every account-level case, so a caller whose `addAccount` threw still has it:

| Case | When |
|---|---|
| `.rejected(account, statusCode:)` | a final non-2xx; pjsip reports 408 when nothing answered |
| `.failed(account, PJSUAError)` | pjsip could not send, or the transaction ended without a SIP response it could report |
| `.bindingNotConfirmed(account)` | a 2xx without an expiry, or whose listed bindings lack the push parameters |
| `.timedOut(account)` | the caller's timeout ran out, or a wait hit the backstop |
| `.ipChangeTimedOut` | no `COMPLETED` in time |

### The backstop and the one read

Every wait inside an operation has a 70 s backstop: pjsip ends a registration transaction within
33 s (`REGC_TSX_TIMEOUT`), and a challenged one is two. pjsua can end a transaction and report
nothing — the rewrite above, when its own send fails — so at the backstop the engine reads
`pjsua_acc_get_info().expires` once to re-seed the session, and reports `.timedOut` if it is still
busy. That is the engine's only read of pjsua's registration state. An IP change that hits the
backstop while waiting for quiet goes ahead regardless; one that never reports `COMPLETED` throws
`.ipChangeTimedOut`, and account operations resume.

## 3. What cannot be closed from outside pjsip

1. **A transaction pjsua starts and ends while its reports wait to be applied.** An automatic retry
   on an unregistered account can start and settle on the worker while the actor runs other work.
   If an operation reads quiet in that gap, it sends, and its next settlement is the retry's. It
   needs a retry timer firing within a whole round trip of the operation's reading. pjsua offers no
   transaction identity to correlate by: `on_reg_started2` carries no request.
2. **A refresh pjsip fires outside the 2 s margin** — a late timer — can be in flight when modify
   runs. On the credential path modify then orphans a REGISTER carrying the same Contact, which is
   harmless to the binding. On the Contact path the session is already gone.
3. **A `COMPLETED` that arrives after its IP change gave up** on the backstop can end the next
   sequence's wait early.
4. **A transaction pjsua ends without calling back** leaves only the backstop and the one read.

Trade-off, deliberate: an IP change waits for busy sessions to settle, and a transaction stalled on
the old network path can hold it until pjsip's 32 s transaction timeout (Tech-Debt TD-32).

## 4. Rejected

- **Polling `pjsua_acc_get_info` on a timer**, or reading pjsua's state before each decision. The
  actor and the callback bridge exist so the engine can be told, not keep asking; each read under
  pjsua's threading is one more chance to see a state mid-change.
- **Reading `PJSIP_EBUSY` as success.** It names neither the transaction in flight nor its outcome.
  Even `PJ_SUCCESS` from `pjsua_acc_set_registration` means only "handed to the transaction layer";
  only the registrar's answer says what it holds.
- **Letting `pjsua_acc_modify` register.** It sends the un-REGISTER and the new REGISTER back to
  back on two sessions with different Call-IDs; in our traces the two authenticated resends left
  1 ms apart. A registrar that matches bindings by `+sip.instance`, or by RFC 3261 URI comparison
  (which ignores a parameter present in only one URI), deletes the new binding if the un-REGISTER
  lands second.
- **Repeating modify's field rules in the engine** to predict what it will send. The engine diffs
  only what it owns, the push parameters; pjsua keeps the rest.
- **Letting `pjsua_acc_add` register.** It drops the send's result.
- **Trusting `pending` for the engine's own starts** (§2, Signals).
- **One REGISTER that removes and adds** (§1). It is unreachable through pjsua1. Under RFC 5626 both
  Contacts would also share `+sip.instance` and `reg-id`, which the RFC does not cover.
- **Merging triggers by priority in a debounce window** — one "reason" per window, the highest
  winning, with polling to wait for the stack. A network change and a token change in one window
  become one reconfigure without the transport restart. The engine is reason-free: it takes intents
  as state, merges same-account work as a union, and finishes on events. Which trigger means what —
  a VoIP push, a silent push, a token rotation, a path change, holding during a call — is the app's
  and the Kit's policy.

## 5. Tests

`Tests/SwiftPJSUATests/Registration/` (Swift Testing; one serialized suite `RegistrationTests`
with a nested suite per operation, since pjsua is process-global) drives the engine against
`ScriptedRegistrar`, a UDP registrar on loopback inside the test process that answers by script:
200 (optionally listing a different binding), a 401 challenge, a failure code, or nothing, after a
chosen delay.

| Suite | Test | Pins |
|---|---|---|
| `AddAccount` | `addingReturnsOnceTheRegistrarConfirms` | one REGISTER, the engine's; returns on the answer |
| | `aRejectedFirstRegisterThrowsAndKeepsTheAccount` | the error names the account, which stays |
| | `dispatchedReturnsOnceTheRegisterIsSent` | `.dispatched` |
| `SetRegistration` | `unregisteringWhileTheFirstRegisterIsChallengedWaitsForIt` | no `PJSIP_EBUSY`; the un-REGISTER after the challenged REGISTER's answer |
| | `unregisterThenRegisterAgain` | one request each, each returning on its answer |
| `ReRegister` | `pushChangeWhileTheFirstRegisterIsChallengedWaitsForIt` | the TD-23 case: un-REGISTER answered before the new REGISTER, nothing push-less after it |
| | `pushChangeOnAQuietAccountUnregistersThenRegistersOnce` | the Contact path |
| | `unchangedParametersSendOneRegisterOnTheSameSession` | same Call-ID |
| | `anInstantRegistrarNeverStallsAnOperation` | a settlement reported before the send returns |
| | `credentialChangeRegistersOnAFreshSessionWithoutUnregistering` | the credential path |
| | `aRejectedRegisterThrowsItsStatusCode` | `.rejected(403)` |
| | `aBindingWithoutThePushParametersIsNotConfirmed` | `.bindingNotConfirmed` |
| | `concurrentRequestsCoalesceAndTheLatestPushWins` | coalescing; superseded parameters never sent |
| | `dispatchedReturnsBeforeTheAnswer` | `.dispatched` |
| | `aRegisterThatNeverSettlesTimesOut` | `.timedOut`, nothing sent meanwhile |
| | `pushParametersAreFoundInABinding` | the binding match |
| `RemoveAccount` | `removalWhileTheFirstRegisterIsChallengedWaitsForIt` | the orphan case: un-REGISTER after the answer, nothing after it |
| | `removingARegisteredAccountUnregistersItFirst` | one un-REGISTER, answered |
| | `aRefusedUnregisterStillRemovesTheAccount` | `.rejected(500)`, account gone, pjsua's retry sends nothing |
| `HandleIPChange` | `returnsOnceTheSequenceCompletes` | returns on `COMPLETED` |
| | `aReRegisterDuringTheSequenceWaitsForIt` | no `PJSIP_EBUSY`, nothing sent into the sequence |
| | `requestsDuringASequenceCoalesceIntoOneMore` | two requests, one more sequence |

Five of these scenarios, written against the engine before this change with the same assertions,
all fail there. `reRegister` during the challenged first REGISTER, `setRegistration(false)` during
it, and `reRegister` during an IP change throw `PJSUAError(171001: Object is busy (PJSIP_EBUSY))`.
Removal during the challenge sends no un-REGISTER at all: the orphan's authenticated REGISTER goes
out after the delete, and the registrar keeps the binding. Three `handleIPChange` calls run three
sequences, each rebuilding the session under a new Call-ID.
