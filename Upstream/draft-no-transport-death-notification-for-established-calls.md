# An established call is never told its transport died — transport-state listeners are per-transaction only

Upstream note for `pjsip/pjproject`. **Status: verified 2026-08-17 against fork `cb0544e0d`
(upstream master of the same day: `7e95d9f70`), and reproduced live 2026-08-18 with a measured
timeline (below) — ready to file, most likely as a documentation issue with an enhancement
question attached.**

This is the sharpest finding of our call-lifecycle pass and probably **by design** rather than a
defect — which is exactly why it deserves to be written down upstream rather than worked around in
silence. Full analysis: `swift-pjsua/docs/Call-Termination-Paths.md` §4.

---

## What we found

In the entire SIP layer there is exactly **one** registration of a transport-state listener:

```
pjsip/src/pjsip/sip_transaction.c:2922
    pjsip_transport_add_state_listener(tp, &tsx_tp_state_callback, tsx, ...)
```

It is attached in `tsx_update_transport()`, i.e. per **transaction**, and only when a transaction
is actually using that transport. `sip_dialog.c` registers no listener at all (verified by grep,
not inferred). `pjsua_acc_on_tp_state_changed()` handles `PJSIP_TP_STATE_DISCONNECTED` at the
account level — clearing `via_tp`, releasing the registration client's transport, driving IP-change
progression — and never reads `pjsua_var.calls[]`.

**Consequence.** When a TCP or TLS connection carrying an established (CONFIRMED) INVITE dialog is
dropped by the network while no transaction is in flight, nothing observes it:

- the invite session stays at `PJSIP_INV_STATE_CONFIRMED`;
- the dialog is not torn down;
- `pjsua_call_get_info()` continues to report a live call;
- no `on_call_state`, and nothing else, is delivered to the application;
- this persists **indefinitely** — until something next tries to use the dialog.

When a transaction *is* in flight the behaviour is good and fast: `tsx_tp_state_callback()` records
`transport_err`, cancels the timeout timer and reschedules it with zero delay under
`TRANSPORT_DISC_TIMER` (`sip_transaction.c:2572-2576`), so the transaction fails on the next timer
tick rather than waiting out Timer B/F. And a transaction created *after* the transport is marked
shut down fails immediately with `PJSIP_SC_TSX_TRANSPORT_ERROR`. The gap is specifically the idle
established dialog.

## Why it matters

On a mobile client this is not an edge case. iOS suspends applications and closes their sockets;
Wi-Fi ↔ cellular handover is routine mid-call. The user-visible result is a call that appears
connected, with a running duration timer, and no audio in either direction — while the stack agrees
that everything is fine.

Nothing else in the stack fills the gap:

- **RTP inactivity detection does not exist in pjmedia.** `PJMEDIA_STREAM_ENABLE_KA`
  (`pjmedia/config.h:1441-1442`, default `0`) *transmits* keep-alives to hold NAT bindings open; it
  does not observe the peer's, and no timer watches inbound RTP.
- **`PJMEDIA_EVENT_MEDIA_TP_ERR` is forwarded but never acted on** — `call_media_on_event()` lets it
  fall through to `default: break` (`pjsua_media.c:1918-1919`) and pjsua changes no state.
- **ICE keep-alive failure** (`pjsua_media.c:1107-1133`) is the only continuous liveness signal, and
  requires ICE.
- **Session timers (RFC 4028)** eventually notice, but `PJSUA_SIP_TIMER_OPTIONAL` is the default and
  only applies if the peer supports it; at the default `Session-Expires` of 1800 s
  (`sip_config.h:1526-1527`) the refresh lands up to ~15 minutes late — measured at **938 s** in the
  reproduction below, with a worst case of ~983 s for the refresher and ~1768 s for the refreshee.
- Over **UDP** there is no transport-death event at all, by nature.

## Reproduced live, 2026-08-18

Not a thought experiment. iOS Simulator (iPhone 16 Pro, iOS 18.5) against `sip.linphone.org`
(Flexisip), TCP transport, iLBC, session timer negotiated end to end
(`Session-Expires: 1800;refresher=uac`, `Require: timer`). The transport was killed with a pf
`block drop` on the server address — a **silent** discard in both directions, no RST and no ICMP,
so the socket dies exactly as it does when a network path disappears.

```
21:58:48  TCP transport tcpc0x105859228 connects — carries the INVITE, the 407 and the 200 OK
21:58:50  200 OK — call CONFIRMED, RTP flowing both ways
21:59:35  pf blackhole applied (verified: port unreachable from the host)
21:59:33  last inbound RTP; rtcp.rx.pkt freezes at 10 and never moves again
22:01:41  tcpc0x105859228: "TCP connection closed"              <-- 126 s: THE STACK KNOWS
          pjsua_acc.c: "Disconnected notification for transport tcpc0x105859228"
          sip_transport.c: "... shutting down" / "... destroyed with reason 120060"
22:02:17  REGISTER refresh fails -> on_reg_state2(408)          <-- the account layer reacts
   …      call remains PJSIP_INV_STATE_CONFIRMED, no callback, for 13½ more minutes …
22:13:50  session-timer UPDATE/cseq=30086 sent (897 s after the 200 OK)
22:13:59  the replacement transport's connect() times out as well
22:14:09  UPDATE retried on another fresh transport
22:14:41  BYE/cseq=30088 (the retry's transaction gave up)
22:15:13  on_call_state -> DISCONNECTED, last_status 408; on_stream_destroyed delivers final stats
```

**938 s — 15 min 38 s — from transport death to the application being told.** Throughout,
`pjsua_call_get_stream_stat()` kept succeeding and `tx.pkt` kept climbing (10 → 217): the sender
never learned there was nothing at the other end.

Three details that bear directly on the questions below:

1. **The stack detected it at 126 s, and delivered that only to the account layer.** This is the
   heart of the report. `tcpc0x105859228` is the connection that carried the INVITE, the 407 and
   the 200 OK — the call's own transport. At **22:01:41** pjsip logged `TCP connection closed` on
   it (`sip_transport_tcp.c:1571`), ran `tcp_init_shutdown()`, destroyed it, and delivered a
   transport-disconnected notification to `pjsua_acc_on_tp_state_changed()`. The CONFIRMED dialog
   riding that exact transport was told **nothing for a further 812 s**.

   What found it is pjsip's own **TCP keep-alive** (`pjsip_cfg()->tcp.keep_alive_interval`,
   default 90 s): the periodic CRLF goes unacknowledged and the resulting socket error surfaces on
   the read path. **So the stack already has a working, continuous, transport-level liveness
   mechanism for exactly this failure — it simply is not wired to calls.** The observed 126 s is
   the keep-alive interval plus the host's TCP retransmission timeout, not a pjsip constant.

   This changes the shape of the enhancement in question 3: a dialog-scoped listener would not be
   building a new detector, it would be subscribing an existing one to a second consumer. On this
   run it would have cut 938 s to ~126 s — **7.4×** — and, unlike the session timer, it needs no
   RFC 4028 negotiation to work at all.
2. **The refresh is only the start of the delay.** From the failed UPDATE to the application
   callback took a further **83 s** (send failure → 10 s retry → BYE → the BYE's own 32 s
   transaction timeout). So the true worst case for the refresher is `Session-Expires/2 + ~83 s` ≈
   **983 s** at the default, not `Session-Expires/2`.
3. **The refreshee is blind for roughly twice as long.** The answering leg of the same call — a
   second UA in the same process, on the same dead transport — received **no callback at all**
   during the 1149 s observation. Its timer is `max(SE−32, SE−SE/3)` = **1768 s** (~29.5 min,
   `sip_timer.c:523-525`). For a mobile client this is the *incoming* call case, which is the one
   where the user is most likely to be sitting there saying "hello?".

Note the 938 s is the *lucky* case: a session timer had been negotiated. Without one, on this
evidence, nothing would ever have ended the call.

## A second run: media death with signalling intact (2026-08-18)

Same apparatus, blocking **UDP only** — RTP dies, the SIP/TCP connection stays healthy. 1000 s,
493 samples, and the point of interest for `PJMEDIA_EVENT_MEDIA_TP_ERR`:

- **`on_call_media_event` fired zero times.** Not once in the whole window.
- The call stayed `CONFIRMED`; `rx.pkt` froze at 9 while `tx.pkt` climbed to 214.
- Registration kept succeeding on the same transport (200 at 5-minute intervals), and the final
  `pjsua_call_hangup()` completed in **0.1 s** — proving the signalling path really was untouched
  and this was a pure media failure.
- **The session timer refreshed the call at 900 s and it succeeded** (`UPDATE` → 407 → 200 OK):
  a call whose media had been dead for 15 minutes was renewed for another 1800 s, without comment.
  Session timers keep *dialogs* alive; they say nothing about media.

**Worth stating precisely, because it is not what we predicted.** We expected the event to be
raised and then dropped by pjsua's `default: break` (`pjsua_media.c:1918-1919`). What actually
happened is that **no event was generated at any layer**.

A third run replaced `block drop` with `block return`, so every RTP packet drew an ICMP
port-unreachable: **still zero events**, still no logged socket error. The code explains it:

- `PJMEDIA_EVENT_MEDIA_TP_ERR` is published in exactly two places
  (`stream_imp_common.c:378`, `:437`), **both on the receive path** (`Unable to receive RTP/RTCP
  packet`), both guarded by `if (status == PJ_ESOCKETSTOP)`. There is no publisher on the send path.
- For UDP, `PJ_ESOCKETSTOP` is raised only at `ioqueue_common_abs.c:1344`: a *send* returning
  `EPIPE` on a datagram socket where `replace_udp_sock()` has already failed — "this socket is dead
  and unreplaceable", the mobile socket-invalidation case (upstream #1107).
- The RTP socket is **unconnected** (`transport_udp.c` uses `pj_ioqueue_sendto()`, never
  `pj_sock_connect()`), so BSD/macOS will not deliver ICMP errors to it regardless.

**So a media path that stops forwarding — dropping or rejecting — cannot raise this event.** That
may well be intended. The point for the documentation half of this report is that
`PJMEDIA_EVENT_MEDIA_TP_ERR` reads like a media-transport-failure notification and is in practice
an *invalidated-socket* notification. An application that installs `on_call_media_event` expecting
to learn "my media path died" will wait forever. If our reading is right, saying so beside the
event's declaration would be worth more than any code change.

## Questions for the maintainers

Deliberately phrased as questions — we may well be missing an intended mechanism, and would rather
be told so than patch around it.

1. **Is this the intended contract?** That is, is an application expected to detect dead media for
   an established call by itself (polling `pjsua_call_get_stream_stat()`, running its own RTP
   inactivity timer, enabling ICE, or mandating session timers), rather than being notified?
2. **If so, could that be stated in the docs?** The pjsua "Making and receiving calls" guidance
   describes the call state machine as the way an application learns a call ended, without noting
   that transport death does not enter that state machine while the dialog is idle. A short note —
   plus a pointer to whichever of the mechanisms above is recommended — would save the next
   implementer this investigation.
3. **Would a dialog-scoped transport-state listener be welcome?** `pjsip_dlg_*` could register on
   the dialog's transport and surface `PJSIP_TP_STATE_DISCONNECTED` to the invite-session layer,
   letting pjsua deliver `on_call_state(DISCONNECTED)` with `PJSIP_SC_TSX_TRANSPORT_ERROR`
   immediately instead of never. We recognise this is a non-trivial change with real design
   questions we do not presume to answer — in particular whether a transport drop *should* end the
   call at all, since the dialog may legitimately survive on a replacement connection, which is
   precisely what `PJSIP_TSX_UAS_CONTINUE_ON_TP_ERROR` (`sip_transaction.c:1356-1364`) exists to
   allow for incoming INVITEs. If the answer is "no, by design", question 2 stands on its own.
4. **Is there an existing knob we have missed** — a media-inactivity timeout, or a transport
   keep-alive whose failure ends associated dialogs — that would give a client this signal without
   application-level polling?

---

## Context for us

We are not blocked: the detector is cheap on our side, and the reproduction above confirms it works
— `rx.pkt` went flat **938 s before** the stack reached the same conclusion.
`pjsua_call_get_stream_stat()` is a non-blocking read of counters pjmedia already maintains
continuously, so polling `rx.pkt` on the active call — flat for N seconds while confirmed and not
on hold — is a serviceable media-death signal, and we were already scoping in-call sampling for a
quality indicator
(`offhook/docs/Call-Quality-Statistics.md` §3). This finding promotes that polling from a debug
convenience to the app's only liveness mechanism, tracked as `offhook` OH-10.

We are filing anyway because the *documentation* half is real: nothing in the pjsua call-lifecycle
material warns that the state machine has this hole, and every mobile client hits it eventually.

**Pre-filing check done 2026-08-19:** no `pjsip_dlg_add_transport_state_listener` or equivalent
exists anywhere in `sip_dialog.h`, `sip_dialog.c` or `sip_inv.c` on `cb0544e0d`, so questions 1–3
are not moot. Re-run that grep against master immediately before filing anyway — it is one command.

**HOLD — do not file until the live experiment has run.** Every claim here is read from source and
**has not been observed on a running stack**. `TASK-code-call-lifecycle-verification.md` §2 is the
experiment: establish a call over TCP/TLS, leave it idle, kill the transport, watch for 10 minutes.
If something *does* fire, the central premise of this note is wrong and filing it would be a public
mistake. If nothing fires, this note gains the one thing it currently lacks — an observation — and
should be filed with it included. **The cost of waiting is a few days; the cost of not waiting is
filing a confident issue against a maintainer team we have a good record with.**
