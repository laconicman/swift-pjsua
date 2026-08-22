# Call termination paths — what ends a call, and what the app is told

Companion to [Threading-Validation](./Threading-Validation.md): that file records *where* callbacks
run, this one records *whether they run at all*. Written because the call-statistics design
(`offhook/docs/Call-Quality-Statistics.md`) captures one record per stream at `on_stream_destroyed`
and needed to know which terminations that misses — and the answer turned out to matter far beyond
statistics.

**Source:** local `pjproject` fork at **`cb0544e0d`** (upstream master of the same day:
`7e95d9f70`, `3ca540207`), read directly, plus one DeepWiki deep consult
([conversation](https://deepwiki.com/search/is-pjsuamediachanneldeinit-gua_bac31a61-237c-41ee-9890-644b3dc2614b?mode=deep),
2026-08-17; every claim below re-verified against the fork — see §6). Line numbers are that commit.

---

## 0. Verdict

**Signalled termination is fully covered. Unsignalled death is invisible, indefinitely.**

Every path that runs pjsua's teardown delivers `on_stream_destroyed`, and the `hanging_up` guard
that looks like it would drop local hangups does not (§2) — so end-of-call statistics capture is
sound on *every* path that ends a call through pjsua, including `pjsua_call_hangup_all()`,
`pjsua_destroy()`, ICE failure, and IP-change hangups.

The gap is elsewhere, and it is worse than a missing statistic. **An established call whose
transport dies without a BYE produces no event at all, for as long as the call is idle.**
**Reproduced live 2026-08-18: 938 s — 15 min 38 s — of a CONFIRMED call over a blackholed TCP
transport with zero callbacks, ended only by the session timer** (§4.1). And pjsip *knew*: it
declared the call's own transport dead after **126 s**, delivered that to the account handler, and
never told the dialog. Registration reacted at 162 s; the answering leg had still not noticed when
the run ended at 1149 s. In the
whole SIP layer there is exactly one registration of a transport-state listener, and it is
per-*transaction* (`sip_transaction.c:2922`); `sip_dialog.c` registers none, and pjsua's own
transport handler never touches `pjsua_var.calls[]`. So a confirmed call over a dead TCP/TLS socket
stays `PJSIP_INV_STATE_CONFIRMED` — the app still shows "connected", the user hears nothing —
until something next tries to use that dialog. Over UDP there is no transport-death concept at all.
And there is **no RTP inactivity detector anywhere in pjmedia**: `PJMEDIA_STREAM_ENABLE_KA` only
*transmits* keep-alives, it does not notice their absence.

The one continuous media-liveness signal in the entire stack is **ICE keep-alive failure**
(`pjsua_media.c:1107-1133`) — and Offhook does not enable ICE ([OH-4](../../offhook/docs/Tech-Debt.md)).

---

## 1. Taxonomy

`✅` = fires · `—` = does not fire · **Stats** = does `on_stream_destroyed` deliver a final
statistics record.

| # | How the call ends | What pjsua does | `on_call_state` | Stats | Notes |
|---|---|---|---|---|---|
| 1 | **Local hangup** (`pjsua_call_hangup`) | deinit media, then set `hanging_up` | ✅ (user event) | ✅ | `pjsua_call.c:3410-3414` — order is load-bearing, see §2 |
| 2 | **Remote BYE / any DISCONNECTED** | `PJSUA_LOCK` → deinit → release lock → callback | ✅ | ✅ | `pjsua_call.c:5458-5464`, `:5486-5487` |
| 3 | **`pjsua_call_hangup_all()`** | loops path 1 per call | ✅ | ✅ | `pjsua_call.c:4318-4337`; takes **no** `PJSUA_LOCK` by design (upstream #1305) |
| 4 | **`pjsua_destroy()`** | `pjsua_call_hangup_all()` → path 1 | ✅ | ✅ | `pjsua_core.c:2000` |
| 5 | **`pjsua_destroy2(PJSUA_DESTROY_NO_TX_MSG)`** | direct `pjsua_media_channel_deinit(i)`, no hangup | — | ✅ | `pjsua_core.c:2003-2008`. `hanging_up` stays false → stats still captured, but no SIP goodbye |
| 6 | **Transaction timeout** (Timer B/F, 64×T1 ≈ 32 s) | tsx fails → inv → DISCONNECTED → path 2 | ✅ | ✅ | Tunable via `pjsip_cfg()->tsx.td`, unexposed — [TD-17](./Tech-Debt.md) |
| 7 | **IP change, `hangup_calls` set** | `pjsua_call_hangup(i, PJSIP_SC_GONE)` → path 1 | ✅ | ✅ | `pjsua_acc.c:5762-5778` |
| 8 | **IP change, `reinvite_flags` set** | re-INVITE; call survives or fails into path 6 | ✅ (on failure) | ✅ | `pjsua_acc.c:5732-5733` |
| 9 | **ICE negotiation failure** | media → `PJSUA_CALL_MEDIA_ERROR`, **call NOT ended** | — | — | `pjsua_media.c:1082-1092` → `on_call_media_state`. See §3 |
| 10 | **SRTP negotiation failure** | same as 9 | — | — | `pjsua_media.c:1985-1995` |
| 11 | **Media update failure** (re-INVITE SDP) | stop stream, close transport, `MEDIA_ERROR`, **call NOT ended** | — | ⚠️ | `pjsua_media.c:4785-4798` — `stop_media_stream()` runs, so the callback *does* fire here; the call continues without media |
| 12 | **Media transport error** (`PJMEDIA_EVENT_MEDIA_TP_ERR`) | **nothing** — forwarded to app, no state change | — | — | §3. **Observed**: for a blackholed path the event is never even raised |
| 13 | **ICE keep-alive failure** | `on_call_media_transport_state` + `on_ice_transport_error` | — | — | `pjsua_media.c:1107-1133`. Only continuous liveness signal in the stack |
| 14 | **TCP/TLS transport death, call idle** | **nothing, indefinitely** | — | — | §4. The gap. **Observed: 938 s of silence** (§4.1) |
| 15 | **TCP/TLS transport death, transaction in flight** | tsx force-failed on next timer tick | ✅ | ✅ | `sip_transaction.c:2572-2576` — zero-delay `TRANSPORT_DISC_TIMER`, not the full Timer B/F wait |
| 16 | **UDP "transport death"** | does not exist as an event | — | — | Connectionless; only paths 6/9-13 or a session timer can notice. **Unobservable from this stack** — see §6.5 |
| 17 | **Session timer (RFC 4028) expiry** | refresh (an **UPDATE**) fails → retry → BYE → path 6 | ✅ | ✅ | Default `PJSUA_SIP_TIMER_OPTIONAL` (`pjsua.h:2688-2690`), `Session-Expires` 1800 s (`sip_config.h:1526-1527`). **Observed**: refresh at SE/2, then **+83 s** to reach the app — see §4.1 |

**Reading of the table:** every row that ends a call captures statistics. Rows 9, 10, 12, 13, 14
and 16 do not end the call — they are the "connected but no audio" family, and they are exactly
where a quality record would be most valuable and is not produced, because the stream is still
alive and will only be torn down whenever the call eventually ends by some other route.

### 1.1 Re-INVITE and hold — "smart media update" decides whether a record is produced

Resolved from source 2026-08-17 (this was listed as unverified in the first cut of §6; it is not a
live-test question).

`pjsua_media_channel_update()` does **not** blanket-stop the media session on a re-INVITE — the call
to do so is commented out (`pjsua_media.c:4605`, "Destroy existing media session, if any"). Instead
each stream goes through `apply_med_update()` (`:4218`), which asks whether anything actually
changed:

```c
/* pjsua_media.c:4398-4408 */
if (pjsua_var.media_cfg.no_smart_media_update || is_media_changed(call, mi, &stream_info)) {
    media_changed = PJ_TRUE;
    stop_media_stream(call, mi);        /* -> on_stream_destroyed fires, record captured */
} else {
    PJ_LOG(4,(THIS_FILE, "Call %d: stream #%d (%s) unchanged.", ...));   /* stream survives */
}
```

`is_media_changed()` (`:3969`) compares media type, **direction** (`:3993-3995`), remote RTP address,
`rtcp_mux`, codec info and codec params against the live stream's own
`pjmedia_stream_get_info()`. Three consequences:

- **Hold and resume each produce a record.** Hold changes direction (`sendrecv` → `sendonly`/
  `inactive`), which `is_media_changed()` catches, so the stream is destroyed and rebuilt. A single
  call with one hold/resume cycle therefore yields **three** stream records, not one — confirming
  the per-stream (not per-call) record model in
  `../../offhook/docs/Call-Quality-Statistics.md` §2.1, and confirming that the record needs its
  `sequence` field to order them.
- **Re-INVITEs that change nothing produce no record, and that is correct.** A session-timer refresh,
  or an IP-change re-INVITE whose SDP ends up identical, leaves the stream and its counters intact.
  Records mark real media transitions, not signalling events.
- **`pjsua_media_config.no_smart_media_update`** (`pjsua.h:8389-8401`, default `PJ_FALSE`, upstream
  ticket #1568) forces teardown on **every** successful negotiation. Setting it would produce a
  record per re-INVITE and reset every counter with it. We leave it at the default; noted because it
  silently changes the shape of the statistics store.

**Caveat:** the counters in each record are per-*stream*, so a held call's "receive packets = 0"
record is expected, not a fault. Anything aggregating a call's quality must join its streams and
weight by duration — see `Call-Quality-Statistics.md` §2.3.

**Confirmed live, 2026-08-18** (`offhook` `CallLifecycleObservationTests.test20`, Flexisip
loopback, iLBC). One call with one hold/resume cycle produced **exactly three**
`on_stream_destroyed` records on the caller leg — at hold, at resume, at hangup — matching the
prediction above.

Two things the run corrected, both about *measuring* this rather than about the behaviour:

- **Counting the log line over-counts.** `Media stream call%02d:%d is destroyed` is emitted by
  `stop_media_stream()` **unconditionally** (`pjsua_media.c:3483`), while the callback lives
  inside `pjsua_aud_stop_stream()`'s `if (strm)` guard (`pjsua_aud.c:511`). The first media
  update of a call therefore logs a teardown with no stream to tear down: **4 log lines, 3
  records.** Count callbacks, not log lines.
- **Text streams produce no record at all.** Our INVITE offers a second m-line (`m=text`, T.140),
  which is torn down on the same transitions and logs the same line, but `on_stream_destroyed` is
  an audio callback — so the log shows 8 lines across the two media indices for what is 3 records.

---

## 2. The `hanging_up` guard is benign — but only by ordering

`on_stream_destroyed` is guarded (`pjsua_aud.c:553`):

```c
if (!call_med->call->hanging_up && pjsua_var.ua_cfg.cb.on_stream_destroyed)
    pjsua_var.ua_cfg.cb.on_stream_destroyed(call_med->call->index, strm, call_med->idx);
```

This reads like it drops every locally-terminated call. It does not, because **`hanging_up` has
exactly two writers in the entire tree, both inside `pjsua_call_hangup()`** — and the live one runs
*after* the teardown:

```c
/* pjsua_call.c:3410-3414 */
} else {
    /* Destroy media session. */
    pjsua_media_channel_deinit(call_id);   /* fires on_stream_destroyed — flag still FALSE */
    call->hanging_up = PJ_TRUE;            /* set only now */
    pjsua_check_snd_dev_idle();
}
```

The other writer (`:3409`) is the `delay_hangup` branch, taken when media transport creation has
not completed (`inv->state == PJSIP_INV_STATE_NULL`) — there is no stream to report on.

**This is undocumented ordering we depend on.** `hanging_up` is declared with the bare comment
"Is call in the process of hangup?" (`pjsua_internal.h:215`); nothing promises the deinit precedes
it. A refactor upstream that hoisted the flag three lines would silently delete every local-hangup
statistics record with no compile error and no test failure. Assert it — see
[TD-27](./Tech-Debt.md).

**Confirmed live, 2026-08-18.** With `on_stream_destroyed` installed, `pjsua_call_hangup()` on the
caller leg delivered a record carrying non-zero counters, so the ordering holds in the shipped
binary. It is now pinned by `offhook` `test07_localHangupProducesStatisticsRecord`, which filters
to the *caller* leg deliberately: the callee leg is torn down by the BYE (row 2) and would keep
passing even if the local path broke.

The same run settles what DeepWiki could not (it ran out of tool budget on the question,
[conversation](https://deepwiki.com/search/on-current-master-how-does-a-p_c80688f4-93fd-4689-bd1e-9b69f823c375?mode=deep)):
**the stream is fully constructed when the callback fires.** `pjsua_aud.c` calls
`pjmedia_stream_get_stat()` itself a few lines earlier and invokes `pjmedia_stream_destroy()` only
afterwards, and the records we captured carry real codec info and non-zero counters. Reading stats
inside the callback is sound.

Two further notes on the guard:

- `pjsua_media.c:238` — a `pjsua_media_channel_deinit()` loop that looks like a second shutdown
  path — is **dead code inside `#if 0`**, moved out to `pjsua_destroy()` per upstream #1717.
- The same `!hanging_up` pattern guards ~20 other callbacks (`on_call_state`, `on_call_media_state`,
  `on_dtmf_event`, `on_stream_created`…). The design intent is clear: once the app has asked for a
  hangup, stop telling it things. Fine for notifications; a trap for anything carrying data the app
  cannot reconstruct.

---

## 3. Media failures that do *not* end the call

`call_media_on_event()` (`pjsua_media.c:1822-1946`) is subscribed to every stream's event stream
(`pjsua_aud.c:827`). Its `switch` handles exactly three things — video keyframe requests, video
format changes, and logging a video device error — and everything else, **including
`PJMEDIA_EVENT_MEDIA_TP_ERR`, falls through to `default: break`** (`:1918-1919`). The event is then
forwarded verbatim to `on_call_media_event` and pjsua takes no action whatsoever.

So: **a media transport error does not disturb the call.** No state change, no SIP signalling, no
teardown. The call stays confirmed with dead media, and the only party that can do anything about
it is the application — which must have installed `on_call_media_event` to even hear about it.

**Observed live 2026-08-18, and the result is worse than the analysis** (`offhook`
`CallLifecycleObservationTests.test22`, RTP blackholed for 1000 s with SIP/TCP left up):

- **`on_call_media_event` fired zero times** in 493 samples. The call stayed `.confirmed`, `rx.pkt`
  froze at 9, `tx.pkt` climbed to 214.
- Signalling was demonstrably healthy throughout — registration refreshed 200/OK three times, and
  the closing `hangup()` completed in **0.1 s**.
- **The session timer refreshed the call at 900 s and succeeded.** A call whose media had been dead
  for a quarter of an hour was renewed for another 1800 s. Session timers keep *dialogs* alive;
  they are not liveness checks.

**The prediction was right for the wrong reason, and the difference matters.** We expected
`PJMEDIA_EVENT_MEDIA_TP_ERR` to be raised and then dropped at `default: break`. In fact **no event
was generated at any layer**: a silently blackholed UDP path produces no socket error at all,
`sendto()` keeps succeeding, and pjmedia has nothing to report. For the most common real-world
media failure — a path that quietly stops forwarding — `MEDIA_TP_ERR` is not merely ignored by
pjsua, it never exists. Installing `on_call_media_event` (TD-27 item 2) therefore buys **less**
than this section implied: it covers local socket errors and audio-device failures, not a dead
network path.

**The follow-up run settled it, and `default: break` turns out to be a red herring.** Repeating
with `pf`'s `block return` instead of `block drop` — so every RTP packet drew an ICMP
port-unreachable — produced **zero media events again** and no logged socket error. The source
says why, and the conclusion is stronger than "pjsua discards it":

- **Both publish sites are on the receive path, behind one specific status.**
  `publish_tp_event(PJMEDIA_EVENT_MEDIA_TP_ERR, …)` appears exactly twice
  (`stream_imp_common.c:378`, `:437`), both under `Unable to receive RTP/RTCP packet`, both guarded
  by `if (status == PJ_ESOCKETSTOP)`. **Nothing publishes it on the send path at all.**
- **`PJ_ESOCKETSTOP` does not mean "the network broke".** For UDP it is raised in one place
  (`ioqueue_common_abs.c:1344`): a *send* returning `EPIPE` on a datagram socket where the
  automatic `replace_udp_sock()` retry has already failed — "this socket is dead and could not be
  replaced" (upstream #1107).
- **The RTP socket is unconnected.** `transport_udp.c` uses `pj_ioqueue_sendto()` and never calls
  `pj_sock_connect()`, and BSD/macOS do not deliver ICMP errors to unconnected UDP sockets — so the
  returned ICMP could not reach it even in principle.

So neither a dropping path nor a rejecting one can raise this event: the first produces no error,
the second one the socket cannot receive, and the send path has no publisher regardless.

**This reframes what `on_call_media_event` is for.** It is not a media-liveness signal — it is the
**socket-invalidation signal**, which is what `PJ_ESOCKETSTOP` actually encodes: the OS killing a
socket on suspend or network change, with replacement attempted and failed. That is real and it
matters to us — it is [TD-24](./Tech-Debt.md) / `../../offhook/docs/Push-vs-Active-Socket.md`
territory — but it is a different problem from this section's, and should be valued as such.

Three delivery details that matter to a Swift wrapper:

1. **It is deferred through a timer, not delivered inline.** `pjsua_schedule_timer2(&call_med_event_cb,
   eve, 1)` (`:1942`) — a 1 ms timer, so `on_call_media_event` runs on the **timer thread**, not the
   media thread that published the event. Different threading context from the other callbacks in
   [Threading-Validation](./Threading-Validation.md).
2. **Events are recycled through a free list** guarded by `pjsua_var.timer_mutex` (`:1925-1934`),
   returned in `call_med_event_cb` (`:1816-1818`).
3. **That free list leaks a node per event dropped during hangup.** `:1936-1937` returns early when
   `call->hanging_up`, *after* the node has been erased from the free list at `:1931` and without
   pushing it back. Filed as
   [media-event-node-leaked-on-hangup](../Upstream/media-event-node-leaked-on-hangup.md).

**What pjsua *does* act on**, and therefore what the app can react to today:

| Signal | Callback | Reaches Swift today? |
|---|---|---|
| ICE / SRTP negotiation failure → `PJSUA_CALL_MEDIA_ERROR` | `on_call_media_state` | ✅ — mapped to `CallMediaStatus.error` |
| Media transport state changes, incl. ICE keep-alive failure | `on_call_media_transport_state` | ❌ not installed |
| ICE keep-alive failure (dedicated) | `on_ice_transport_error` | ❌ not installed |
| Any `pjmedia_event`, incl. `MEDIA_TP_ERR`, `AUD_DEV_ERROR` | `on_call_media_event` | ✅ — ``CallMediaEvent`` (2026-08-18) |
| Stream teardown + final statistics | `on_stream_destroyed` | ✅ — `.streamDestroyed` (2026-08-18) |
| SIP transport up/down | `on_transport_state` | ❌ not installed |

`SwiftPJSUA` installs six callbacks (`PJSUACallbacks.swift`): `on_call_state`,
`on_incoming_call`, `on_call_media_state`, `on_reg_state2`, and — added 2026-08-18 as the minimum
needed to *observe* rows 9–13 — `on_stream_destroyed` and `on_call_media_event`. The remaining
three are still unwired; [TD-27](./Tech-Debt.md) tracks the rest.

---

## 4. The silent-death gap

The finding that most changes how the app should be built.

**In the entire SIP layer there is one registration of a transport-state listener:**

```
sip_transaction.c:2922   pjsip_transport_add_state_listener(tp, &tsx_tp_state_callback, tsx, ...)
```

`sip_dialog.c` registers none — verified by grep, not inference. The listener is attached in
`tsx_update_transport()`, which runs only when a **transaction** is actually using the transport.
pjsua's own global handler, `pjsua_acc_on_tp_state_changed()` (`pjsua_acc.c`, 105 lines), does
account-level bookkeeping — clearing `via_tp`, releasing the registration client's transport,
driving IP-change progression — and **never reads `pjsua_var.calls[]`**.

Therefore:

- **Call idle when the socket dies → nothing happens.** No listener exists to notify. The invite
  session stays `CONFIRMED`, the dialog is not torn down, `pjsua_call_get_info()` keeps reporting a
  live call, and the app keeps showing "connected". Indefinitely.
- **Transaction in flight when the socket dies → fast failure.** `tsx_tp_state_callback` records
  `transport_err`, cancels the timeout timer and reschedules it with **zero delay** under
  `TRANSPORT_DISC_TIMER` (`sip_transaction.c:2572-2576`, id defined `:141`), so the transaction
  fails on the next timer tick rather than waiting out Timer B/F. That propagates through
  `inv_set_state(… PJSIP_INV_STATE_DISCONNECTED …)` to `on_call_state`.
- **A new transaction started after the transport is already shut down** is failed immediately with
  `PJSIP_SC_TSX_TRANSPORT_ERROR` — this is what makes a *later* hangup or session-timer refresh
  discover the truth.

**What eventually notices, and how slowly:**

| Mechanism | Enabled in our build? | Time to notice |
|---|---|---|
| Session timer (RFC 4028) refresh — **refresher** (the UAC) | `PJSUA_SIP_TIMER_OPTIONAL` — negotiated with Flexisip, see §6.3 | ~½ × `Session-Expires` **+ ~83 s** = up to **~983 s (16.4 min)** at the 1800 s default. **Measured: 938 s** |
| Session timer — **refreshee** (the UAS) | same | `max(SE−32, SE−SE/3)` = **1768 s (~29.5 min)** (`sip_timer.c:523-525`). Not reached in a 1149 s run — the answering leg never noticed |
| ICE keep-alive | ❌ ICE not enabled ([OH-4](../../offhook/docs/Tech-Debt.md)) | seconds — if it were on |
| RTP inactivity detection | **does not exist in pjmedia** | never |
| The user pressing hang up | always | immediately, and badly |

`PJMEDIA_STREAM_ENABLE_KA` (`pjmedia/config.h:1441-1442`, default `0`, and `swift-pjsip` does not
set it) is a **transmitter**: it sends keep-alive packets so NAT bindings survive silence. It does
not observe the peer's. Nothing in pjmedia times inbound RTP.

**Why this is acute for us specifically.** iOS suspends apps and kills their sockets; network
changes between Wi-Fi and cellular are routine; `Push-vs-Active-Socket.md` already documents the
registration-side version of this problem, and
[TD-24](./Tech-Debt.md) records that a socket the OS killed during suspension is discovered late.

**This is the in-call analogue of TD-24, and the asymmetry is sharper than it first looks.** A
lapsed *registration* has a recovery path that does not depend on us noticing anything: under
RFC 8599 §5.2 the proxy buckets the incoming request, pushes, and forwards it once our
binding-refresh REGISTER arrives — ~2 s, and **the binding need not be live when the call arrives**
(`../../offhook/docs/Provisioning-Models.md`, corrected 2026-08-19). So against a proxy that
implements the bucket, a silently-lapsed registration costs nothing.

A silently-dead *call* has no such mechanism. There is no bucket for a dialog already in progress,
nothing retries, and nothing re-establishes it — the user sits watching a running call timer saying
"hello? hello?" while the app agrees everything is fine. Neither the engine nor pjsip will tell us.
**The app has to notice, because it is the only party that can.**

**The cheap detector we already have.** `pjsua_call_get_stream_stat()` is a non-blocking read of
counters pjmedia maintains continuously. Polling `rx.pkt` on the active call — the sampling that
`Call-Quality-Statistics.md` §3 scopes to the debug view — doubles as a liveness check: RX packet
count flat for N seconds while the call is confirmed and not on hold *is* the media-death signal
pjmedia declines to provide.

The counter is the right one, verified in source: `sess->stat.rx.pkt++` sits in
`pjmedia_rtcp_rx_rtp2()` (`rtcp.c:316+`) **before** its bad-packet `return`, and the call site is
at `on_return:` in `stream_imp_common.c:599` — reached even by the `goto`s for bad-sequence and
zero-payload packets. So it counts every RTP packet that arrives, including keep-alives and
discards; RTCP alone never advances it; and a locally-held call keeps counting inbound RTP
(`channel->paused` also lands on `on_return`).

**But N has a floor, and it is larger than it looks.** Measured live 2026-08-18: pjmedia suspends
VAD for `PJMEDIA_STREAM_VAD_SUSPEND_MSEC` = 600 ms and then suppresses silence, emitting one
packet per `PJMEDIA_CODEC_MAX_SILENCE_PERIOD` = 5000 ms. A healthy but silent stream therefore
advances the counter at **0.2 pkt/s** against ~33 pkt/s while speech flows — so any N ≤ 5 s fires
on ordinary quiet, and a peer compiled with that constant at `-1` sends nothing at all. The
detector stands; it is a coarse one, and it cannot be tuned tight. Thresholds:
[OH-10](../../offhook/docs/Tech-Debt.md).

### 4.1 Reproduced live — 2026-08-18

Everything above was read from source. This is the run that tested it.

**Setup.** iOS Simulator (iPhone 16 Pro, iOS 18.5), `swift-pjsua` over the `swift-pjsip` binary
(**PJ_VERSION 2.16.0** — predated our five merged upstream PRs; every number below was taken on
that build, and **re-baselined unchanged on 2.17.0 / swift-pjsip 0.2.0, 2026-08-20**: three
`on_stream_destroyed` records against four log lines, iLBC, `Session-Expires: 1800`, and transmit
freezing at 21–22 packets),
loopback call through `sip.linphone.org` (Flexisip) on **TCP**, iLBC, session timer negotiated
(`Session-Expires: 1800;refresher=uac`).

> **Re-baselined on PJ_VERSION 2.17.0 — 2026-08-19.** `swift-pjsip` 0.2.0 (pjproject master
> `288de6142`, which carries all five PRs) with a changed `config_site.h`:
> `PJSIP_DONT_SWITCH_TO_TCP` dropped, `PJSUA_MAX_ACC`/`MAX_CALLS` 4→8, `PJSUA_MAX_CONF_PORTS`
> 12→254. Same simulator, same endpoint. The cheap pair (`offhook` test07 + test20) was re-run;
> **nothing in this section moved**:
>
> | Claim | 2.16.0 | 2.17.0 |
> |---|---|---|
> | Session timer negotiated, `Session-Expires` / `Min-SE` | 1800 / 90, `refresher=uac` | **identical** |
> | Stream teardowns on the caller leg, one hold/resume cycle | 4 log lines, **3** records | **identical** |
> | `on_stream_destroyed` after a local hangup, non-zero counters | yes | yes (iLBC, tx 22 pkt) |
> | Round-trip on the loopback pair | — | 173–184 ms |
>
> The **20-minute blackhole experiments were not re-run** — §5 of the rebuild task says to re-run
> them only if the cheap pair looks different, and it does not. The 126 s transport-death figure
> and the 900 s + 83 s session-timer arithmetic below therefore remain **2.16.0 measurements**,
> carried forward on the strength of an unchanged session-timer negotiation and unchanged
> teardown behaviour — not re-measured. Note `PJSIP_TCP_KEEP_ALIVE_INTERVAL`, the mechanism
> behind the 126 s figure, was deliberately left untouched by the rebuild for exactly this
> reason. The transport was killed with a pf `block drop` on the
server address — a **silent** discard in both directions, no RST and no ICMP, so the socket dies
the way a vanishing network path kills it. Apparatus:
`../../offhook/docs/SIP-Test-Infrastructure.md` §7. Trace:
`offhook/Tests/CallLifecycleObservationTests.test21`.

```
21:58:48  TCP transport tcpc0x105859228 connects — this is the call's transport
21:58:50  200 OK — CONFIRMED, RTP both ways
21:59:35  transport blackholed (pf-verified unreachable)
21:59:33  last inbound RTP — rx.pkt freezes at 10 and never moves again
22:01:41  tcpc0x105859228: "TCP connection closed"                  ← 126 s: PJSIP KNOWS
          pjsua_acc.c: "Disconnected notification for transport tcpc0x105859228"
          transport destroyed, reason 120060
22:02:17  REGISTER refresh fails → on_reg_state2(408)               ← the ACCOUNT layer reacts
   …      call stays CONFIRMED, zero callbacks, for 13½ more minutes …
22:13:50  session-timer UPDATE sent (897 s after the 200 OK)
22:13:59  the *replacement* transport's connect() times out too
22:14:09  UPDATE retried on another fresh transport
22:14:41  BYE (the retry gave up)
22:15:13  on_call_state → DISCONNECTED, last_status 408; on_stream_destroyed delivers final stats
```

**The prediction held on every point**, and three things are now known that the source read could
not settle:

| | Predicted | Observed |
|---|---|---|
| `on_call_state` while idle | nothing | **nothing, for 938 s** |
| `pjsua_call_get_stream_stat()` | still reports a live call | **succeeded every 2 s for the whole window** — positive evidence pjsua considered the call live, not merely absent events |
| `rx.packets` | flat from the moment of death | **flat within 2 s**, at 10, for 938 s |
| `tx.packets` | (not predicted) | **kept climbing, 10 → 217** — the sender never learns |
| RTT | (not predicted) | **frozen** at 327 ms; RTCP dies with the same transport, so it is not an independent liveness signal |

1. **pjsip knew at 126 s, and told the wrong subsystem — this is the finding.** `tcpc0x105859228`
   is the transport that carried the INVITE, the 407 and the 200 OK: the call's own connection. At
   **22:01:41**, 126 s after the network died, pjsip logged `TCP connection closed` on it, ran
   `tcp_init_shutdown()`, and delivered a transport-disconnected notification — **to
   `pjsua_acc_on_tp_state_changed()`**. The CONFIRMED dialog riding that exact transport was told
   nothing for a further **812 s**.

   What discovered it is pjsip's own **TCP keep-alive** (`pjsip_cfg()->tcp.keep_alive_interval`,
   default 90 s, `sip_config.h:815`): the periodic CRLF write goes unacknowledged, the kernel
   eventually gives up, and the error surfaces on the read path
   (`sip_transport_tcp.c:1571`). So the stack *does* have a continuous transport-liveness
   mechanism, it works, and it is simply not wired to calls. The 126 s is keep-alive interval plus
   the host TCP retransmission timeout, so treat it as "~2 minutes on this OS", not a constant.

   **This is the number that matters for a fix.** A dialog-scoped listener would have cut the
   observed 938 s to ~126 s — 7.4× — without needing a session timer to be negotiated at all.
2. **"~15 min" was optimistic.** The refresh is only the trigger: failure → 10 s retry → BYE → the
   BYE's own 32 s transaction timeout adds **83 s** before the app hears anything.
3. **The answering leg is blind for roughly twice as long.** The callee — same process, same dead
   transport — got **no callback at all** in 1149 s. As refreshee its timer is 1768 s (~29.5 min).
   For Offhook that is the *incoming* call case.

**The contrast is the finding.** One dead socket, and three subsystems on top of it: pjmedia's RTP
counter had the answer in **2 s**, pjsip's transport layer in **126 s**, the account layer reacted
at **162 s** — and the call, which is what the user is actually looking at, at **938 s**. Nothing
was missing from the stack except a wire between the parts that knew and the part that cared. It costs one actor hop per interval and needs no engine change beyond
what is already asked for. That reframes in-call polling from "a debug nicety" to "the only
mechanism we have", which is why [OH-10](../../offhook/docs/Tech-Debt.md) exists.

---

## 5. What this asks of `SwiftPJSUA`

Tracked as [TD-27](./Tech-Debt.md). Ordered by value.

1. **`on_stream_destroyed`** — end-of-call statistics (the original ask), plus a reliable
   "media really stopped" edge. Must read the `pjmedia_stream *` inside the callback; the pointer
   dies 17 lines later (`pjsua_aud.c:573`). Fires with **`PJSUA_LOCK` held**.
2. **`on_call_media_event`** — the only way to hear `PJMEDIA_EVENT_MEDIA_TP_ERR` and
   `PJMEDIA_EVENT_AUD_DEV_ERROR`. Delivered on the **timer thread** (§3). **Revised 2026-08-19:
   worth much less than its position here suggests.** Two live runs showed it cannot fire for a
   dead network path at all — it is gated on `PJ_ESOCKETSTOP`, i.e. an OS-invalidated socket. Keep
   it for the iOS socket-death case (TD-24); do not expect media liveness from it.
3. **`on_transport_state`** — SIP transport up/down. Does not tell you which call died (nothing
   does), but it is the earliest signal that anything is wrong, and it is what a reconnect policy
   keys off.
4. **`on_call_media_transport_state` / `on_ice_transport_error`** — ICE keep-alive failure. Only
   useful once ICE is enabled, but cheap to wire while the others are being added.
5. **A regression test for the `hanging_up` ordering** (§2).

All five are notification-only and hold no actor reference, so G2 is unaffected.

---

## 6. Unverified

1. ~~**Whether `on_stream_destroyed` fires on re-INVITE stream replacement.**~~ **Resolved from
   source 2026-08-17 — see §1.1.** It fires when, and only when, `is_media_changed()` finds a real
   change; direction is compared, so hold/resume does produce records. No live test was needed; this
   entry was a misjudgement in the first cut.
2. **The exact SIP status the app sees on path 15.** DeepWiki traced the transaction-level
   mechanism but ran out of budget before confirming what `pjsua_call_get_info()` reports —
   `PJSIP_SC_TSX_TRANSPORT_ERROR` propagated, versus a synthesised 408. Matters only for how the
   app *labels* the failure, not for whether it detects it.
3. ~~**Whether a session timer is actually negotiated with our test endpoints.**~~ **Resolved
   live 2026-08-18 — negotiated.** Through `sip.linphone.org` (Flexisip): offer carries
   `Supported: … timer` / `Session-Expires: 1800` / `Min-SE: 90`, answer comes back
   `Require: timer` / `Session-Expires: 1800;refresher=uac`. The refresher is the **UAC**, and it
   refreshes at `sess_expires / 2` (`sip_timer.c:517`), so the first thing to touch an idle
   dialog is a re-INVITE at **900 s**. The §4 row is real for this endpoint, and its number is 15
   minutes, not "never".
   **But the loopback pair is pjsua on both ends**, so what this proves is that Flexisip passes
   RFC 4028 through untouched — not that an arbitrary peer accepts one. Against a peer that
   declines, the row still becomes "never", and nothing else in the stack would notice.
   Per-endpoint detail: `../../offhook/docs/SIP-Test-Infrastructure.md` §8.1.
4. ~~**Rows 9/10/12/13/14 have not been observed live.**~~ **Row 14 resolved live 2026-08-18 —
   the prediction held; see §4.1.** 938 s of a CONFIRMED call over a blackholed TCP transport with
   no callback of any kind, `rx.pkt` flat from the moment of death, ended only by the session
   timer. Two corrections came out of it: the delay is `SE/2 + ~83 s`, not `SE/2`, and the
   *refreshee* leg is blind for 1768 s rather than 900 s.

   **Row 12 resolved live 2026-08-18 — see §3.** RTP blackholed for 1000 s with signalling up
   produced **zero** `on_call_media_event` callbacks, and the reason turned out to be that no event
   is generated at all for a silently dropped path, not that pjsua discards it.

   **Rows 9/10/13 remain unobserved**, and all three need a different setup than a blackhole: 9 and
   10 are *negotiation* failures (ICE / SRTP), 13 needs ICE enabled ([OH-4](../../offhook/docs/Tech-Debt.md)).
   The one cheap follow-up still open is `pf`'s `block return` instead of `block drop`, to deliver
   ICMP port-unreachable and find out whether `MEDIA_TP_ERR` is reachable at all in practice.

---

### 6.5 Row 16 (UDP) cannot currently be observed at all

Attempted 2026-08-19 and blocked before the experiment could start: **this stack cannot place an
authenticated call over UDP to any provider.** The initial INVITE fits under pjsip's 1300-byte
UDP threshold and draws a `407`; the authenticated resend does not fit, is sent over UDP anyway,
fragments and is dropped. Verified at two independent providers — `sip.linphone.org` (1322 → 1634 B)
and `sip.antisip.com` (1289 → 1578 B) — so it is a property of our stack, not a server quirk.

The gap this leaves is worth naming, because it is the *worse* case: over UDP there is no
connection, so the 126 s transport-level detection measured in §4.1 does not exist. An idle call
over a dead UDP path has **only** the session timer between it and forever — and if the peer
declines RFC 4028, nothing at all. That is an inference from architecture, not an observation.

The cause was **our own build configuration**, not pjsip: `swift-pjsip/scripts/config_site.h` sets
`PJSIP_DONT_SWITCH_TO_TCP 1`, which disables the RFC 3261 §18.1.1 UDP→TCP size switch outright
(`sip_util.c:1419` guards the whole block on it). `PJSUA.start()` now clears it at runtime
(`pjsip_cfg()->endpt.disable_tcp_switch = 0`), verified working 2026-08-19.

**That fixes calling, and closes this row rather than opening it.** With the switch working as
specified, an authenticated INVITE — ours crosses 1300 bytes once the digest is added — is moved
to TCP *every time*. So the stack does not carry an authenticated dialog over UDP at all, by
design. Row 16 is therefore not merely untested but largely **unreachable in practice**, which
also caps how much it matters: the scenario needs an unauthenticated peer or an unusually small
INVITE. The architectural point stands and is unchanged — over UDP there is no connection, so the
126 s transport-level detection of §4.1 does not exist, leaving only the session timer.
Details: `../../offhook/docs/SIP-Test-Infrastructure.md` §6.

## See Also

- [Threading-Validation](./Threading-Validation.md) — where these callbacks run and under which locks
- [Tech-Debt](./Tech-Debt.md) — TD-26 (discarded jitter-buffer stats), TD-27 (missing callbacks), TD-17, TD-24
- [Production-Roadmap](./Production-Roadmap.md) — the G1/G2 invariants these callbacks must respect
- `../Upstream/` — upstream notes arising from this pass
- `../../offhook/docs/Call-Quality-Statistics.md` — what the app does with the records
- `../../offhook/docs/Push-vs-Active-Socket.md` — the registration-side version of §4
