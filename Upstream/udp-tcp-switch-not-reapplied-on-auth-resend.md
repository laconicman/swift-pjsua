# UDP→TCP size switch is not re-applied on the 401/407 authenticated resend

Upstream note for `pjsip/pjproject`. **Status: 2026-07-13 — RESOLVED: NOT A CODE BUG; shipped a
docs+logging PR instead.** The size switch is reachable and correct on the auth resend (verified
on the 2.16 tag + 2.17/master by two independent source reads + DeepWiki deep; the 2.17 CLI
repro was harness-limited and the source analysis is decisive). Our UDP-only symptom was simply
the switch having **no TCP transport to switch to** → fallback to the UDP entry → oversized UDP.
pjsip is behaving reasonably for a UDP-only app; our app-side fix (TCP listener + `;transport=tcp`)
is correct. The one real gap was **diagnosability** (silent, undocumented fallback), addressed by
fork PR [laconicman/pjproject#3](https://github.com/laconicman/pjproject/pull/3) (`PJ_LOG(5)` at
the fallback + a `PJSIP_UDP_SIZE_THRESHOLD` doc note; DeepWiki-reviewed, compiled vs 2.17).
Tracked-issue draft for that PR: `Upstream/warn-oversized-udp-fallback-issue.md`.

<details><summary>Superseded root-cause analysis (falsified — kept for the record)</summary>

**Status: 2026-07-11 — ON HOLD, DO NOT FILE. Root cause below is DISPROVEN.** A DeepWiki deep design review
([thread](https://deepwiki.com/search/three-questions-about-pjprojec_6945a3bf-383d-4b6c-9a1c-6baa706623e8?mode=deep))
plus direct source read of the working tree (`c1ea7648`) and the **`2.16` tag** show the
"Code path" section is wrong: `pjsip_endpt_send_request_stateless`'s reuse branch
(`dest_info.addr.count != 0`) **does call** `stateless_send_resolver_callback`
(`sip_util.c:1571`, and identically in 2.16), and that callback runs the §18.1.1 size switch
unconditionally on the existing `dest_info.addr` — so the switch *should* re-run on the resend
in both versions. The two proposed fixes are also unsound: **(A)** clearing `dest_info` forces
re-resolution and can route the authenticated resend to a *different* SRV/pool member than the
one that issued the nonce → auth loop (this reuse is deliberate); **(B)** is a no-op (the switch
already runs on that path). The **observed symptom is real** (1297→407→1596 B UDP resend
fragmenting, `testrun4/5.log`), so a genuine defect likely exists — but in the **stateful
INVITE transaction** path (`tsx_send_msg` reuses `tsx->transport` via `pjsip_transport_send`,
`sip_transaction.c:2580-2588`, bypassing resolution+switch) or a config factor, **not** where
this note claims. **Next step: re-establish the mechanism from a live PJSIP transport-level
trace (log level 5+) of the resend, not source archaeology, then rewrite or discard.** Fix 1
(acc-table assert) is unaffected and proceeds.

<!-- Superseded root-cause analysis retained below for the re-investigation; treat as a
     hypothesis that was falsified on the stateless path. -->

### Re-investigation leads (2026-07-13, DeepWiki deep + independent source read — CONVERGED)

Both the tsx-reuse hypothesis and the stateless-skip hypothesis are **refuted**: the auth
resend always creates a **new** UAC tsx (`pjsip_inv_send_msg`→`pjsip_dlg_send_request`→
`pjsip_tsx_create_uac`, `tsx->transport==NULL` from `PJ_POOL_ZALLOC_T`), so it falls through
`tsx_send_msg`'s cached-transport fast path into `pjsip_endpt_send_request_stateless` → reuse
branch → `stateless_send_resolver_callback` → the §18.1.1 switch *does* run. So the switch is
reachable. The real trigger for the observed UDP fragmentation is one of two transport-layer
interactions, **to be decided empirically** (2.17 repro, Config A vs B below):

1. **No usable TCP path to switch to.** The switch inserts TCP entries at `entry[0]`, but
   `stateless_send_transport_cb` (`sip_util.c:~1187`) does `cur_addr++` on a transport-acquire
   failure and tries the next address — the original UDP entry — sending oversized on UDP. With
   a UDP-only engine (our failing config; the TCP listener was our later fix) there is nothing
   to acquire for the TCP entry.
2. **Pinned UDP `tp_sel` overrides the switch** (DeepWiki's lead): if `tdata->tp_sel` is a
   `PJSIP_TPSELECTOR_TRANSPORT` bound to the UDP transport, the transport manager uses it
   regardless of the TCP entries the switch inserted into `dest_info.addr`. Orthogonal to (1).

Also ruled in as a check: `disable_tcp_switch` gating (should be 0 by default). **If either (1)
or (2) is the mechanism, this is arguably correct pjsip behaviour** (you cannot switch to a
transport you never created / you explicitly pinned UDP) → the upstream contribution, if any,
shrinks to a **warning log** ("wanted TCP for over-MTU request but no TCP transport available;
sending oversized on UDP") and/or a **docs clarification** that the auto-switch needs a TCP
transport. Only mechanism (2) *might* be a real defect (a pin silently defeating the switch).
Decide after the 2.17 reproduction; do not file until then.

---

Upstream note for `pjsip/pjproject`. ~~**Status: re-verified 2026-07-11 … ready to file.**~~
`sip_auth_client.c` unchanged in the relevant paths (`tdata = old_request;` :1733,
`invalidate_msg` :1851, still **zero** `dest_info` refs; post-2.16 it gained only `db3cfdee`
async-auth — a wrapper that *falls back to the unchanged* `reinit_req` — plus `5c997b5e`/
`c82123ea` unrelated fixes). In `sip_util.c` the resolve gate drifted :1484 → **:1535**; new
adjacent code at :1488-1529 is the **server-affinity destination pinning** (`1be002ac`,
2026-07-10, #4964 family) — its own comment limits pinning to *reliable* transports ("datagram
(UDP) selectors don't, so they still resolve normally"), so it does **not** cover this resend
case: our stale-UDP `dest_info.addr` short-circuits at :1535 exactly as before. Deep-scan
nuance (DeepWiki [conversation](https://deepwiki.com/search/three-questions-about-pjprojec_6945a3bf-383d-4b6c-9a1c-6baa706623e8?mode=deep)):
TCP/TLS-affinity accounts dodge fragmentation *incidentally* (transport already reliable);
**UDP affinity** (`f587ef14`) pins via a hidden `Route` and sets no `tp_sel`, so the bug
remains there — and conversely a large first-send can still size-switch to TCP *escaping* the
UDP pin, a latent inconsistency worth one line in the filing. Upstream is actively working in
this precise region — cite #4964/`1be002ac` as adjacent-but-not-fixing.
Observed live against pjsip **2.16** (swift-pjsip binary) + Flexisip (`sip.linphone.org`);
code path confirmed by source read of the fork @ `868a376b` (2026-05-19), whose relevant files
equal `master` (`sip_util.c` last changed 2025-10-14, `sip_auth_client.c` 2026-04-13 — both
predate the fork base). Bonus: the behaviour **contradicts pjproject's own documentation**
([Using SIP TCP Transport](https://docs.pjsip.org/en/latest/specific-guides/network_nat/sip_tcp.html#automatic-switch-to-tcp-if-request-is-larger-than-1300-bytes)),
which promises: *"once the request is challenged with 401 or 407, the size grows larger than
1300 bytes … In this case, the request retry will be sent with TCP."* It won't be — see the
code path below. (DeepWiki fast-mode initially claimed the switch *is* re-evaluated — its own
citations disprove it; kept here as a caution:
[conversation](https://deepwiki.com/search/when-pjsip-resends-a-request-w_79d24b3a-9753-4d2a-aa46-01c79b0c94b8).)

---

## Issue draft

**Title:** Authenticated request resend after 401/407 skips the RFC 3261 §18.1.1 UDP→TCP size
switch — over-MTU INVITE fragments and fails silently

### Summary

With only a UDP transport in use and `disable_tcp_switch == 0` (default:
`PJSIP_DONT_SWITCH_TO_TCP = 0`), pjsip correctly switches an outgoing request to TCP when it
exceeds `PJSIP_UDP_SIZE_THRESHOLD` (1300 bytes), per RFC 3261 §18.1.1. However, when a request
is **resent with credentials after a 401/407 challenge**, the switch is not re-evaluated —
even though the resend is precisely the moment the message grows past the threshold (digest
`Authorization`/`Proxy-Authorization` adds 300+ bytes).

This contradicts the project's own documentation, [Using SIP TCP Transport →
"Automatic Switch to TCP…"](https://docs.pjsip.org/en/latest/specific-guides/network_nat/sip_tcp.html#automatic-switch-to-tcp-if-request-is-larger-than-1300-bytes)
(feature originally ticket #831), which states: *"It could be the case that the initial INVITE
is sent with UDP, and once the request is challenged with 401 or 407, the size grows larger
than 1300 bytes due to the addition of Authorization or Proxy-Authorization header. In this
case, the request retry will be sent with TCP."*

### Code path (current master)

The §18.1.1 size check lives **only** inside the resolver callback, and resolution is skipped
when the tdata already carries a resolved destination:

1. `pjsip_auth_clt_reinit_req()` **reuses the original tdata** — `tdata = old_request;`
   (`sip_auth_client.c:1733`). It re-adds auth headers and calls
   `pjsip_tx_data_invalidate_msg(tdata)` (`sip_auth_client.c:1851`), which only resets
   `buf.cur`/`info` (`sip_transport.c:594-598`) — **`tdata->dest_info` is never cleared**
   (zero references to `dest_info` in `sip_auth_client.c`).
2. The dialog resends it (`sip_dialog.c:2314` → `pjsip_dlg_send_request`), the new transaction
   transmits via `pjsip_endpt_send_request_stateless` (`sip_transaction.c:2678`).
3. `pjsip_endpt_send_request_stateless` (`sip_util.c:1455`) resolves the destination **only
   `if (tdata->dest_info.addr.count == 0)`** (`sip_util.c:1484`). The original send populated
   `dest_info.addr` (resolver callback copies the server addresses into the tdata,
   `sip_util.c:1371-1380`), so the resend takes the already-resolved branch.
4. The `disable_tcp_switch` / `PJSIP_UDP_SIZE_THRESHOLD` re-evaluation sits in
   `stateless_send_resolver_callback` (`sip_util.c:1354`, check at `1388-1429`) — which never
   runs for the resend. The oversized retry goes out on the cached UDP address.

### Observed sequence (pjsip 2.16, UDP + TCP transports both created, target URI without transport param)

1. `pjsua_call_make_call` → INVITE, **1297 bytes** → sent over UDP (below threshold — correct).
2. `407 Proxy Authentication Required` ← proxy (Flexisip). ACK sent.
3. Library resends INVITE with `Proxy-Authorization`, CSeq+1 — now **1596 bytes** (> 1300) —
   but still over **UDP**, apparently reusing the already-resolved destination of the original
   request (same `tdata` pointer in the log; no new resolution, no switch, no
   "sending to TCP" log line).
4. The 1.6 kB UDP datagram fragments; the proxy never responds (fragment-dropping is common on
   NATs/SIP proxies); the INVITE retransmits on the UDP timer set and the call dies at
   Timer B with no error distinguishable from a dead server.

### Why it matters

- The failure is **silent** and environment-dependent — exactly the class RFC 3261 §18.1.1's
  "within 200 bytes of MTU → use congestion-controlled transport" rule exists to prevent.
- Proxy-authenticated INVITE is the **normal** case on registrar-challenged services
  (Flexisip/Linphone). Every non-trivial SDP (audio+video, multiple codecs) crosses 1300 bytes
  once the digest header is added.
- The workaround (explicit `;transport=tcp` in request URIs, or an outbound proxy with a TCP
  route set) requires the application to know about MTU internals.

### Suggested fix

Clear `tdata->dest_info` (at least `addr.count = 0`) in `pjsip_auth_clt_reinit_req()` next to
the existing `pjsip_tx_data_invalidate_msg()` call, so the resend re-resolves and the §18.1.1
check in `stateless_send_resolver_callback` runs again — alternatively, re-run the
size-vs-threshold check on the already-resolved address list before reusing it. Either
restores the behaviour the documentation already promises.

### Repro

Any pjsua-based client, UDP+TCP transports, account on a 407-challenging proxy, call target
whose authenticated INVITE exceeds 1300 bytes (audio+video SDP suffices). Wireshark shows the
fragmented resend; the proxy answers the small unauthenticated INVITE but never the large
authenticated one.

### Test infrastructure (reproducing without private setup)

- **Public, free:** a [Flexisip](https://subscribe.linphone.org) account on `sip.linphone.org`
  (which 407-challenges) reproduces it directly — register and place a call over **UDP** with
  an audio+video (or multi-codec) offer so the authenticated resend clears 1300 bytes. A
  second free account on the same server gives a callable target (loopback), so no external
  callee is needed.
- **Self-hosted:** any digest-auth proxy over UDP — Kamailio, OpenSIPS, or Asterisk — with a
  large-SDP INVITE.
- **In-tree, deterministic:** a SIPp UAS scenario under `tests/pjsua/scripts-sipp/` that
  replies `407` and then asserts the authenticated resend's transport — the neighbouring
  `uas-keep-call-on-tsx-fail.*` and the auth scenarios are a template. This would also serve as
  the regression test for the fix.

### Port / transport-selection nuance

Default SIP ports are **5060 for UDP and TCP, 5061 for TLS** (RFC 3261 §18.1 / §19.1.2; IANA).
The existing size switch (`sip_util.c`) upgrades by inserting a "TCP version of the resolved
UDP addresses" that **copies the UDP entry and only flips `type` to `PJSIP_TRANSPORT_TCP`** —
i.e. it reuses the **same port number**. That is correct for the common dual-listener case
(5060/UDP + 5060/TCP), but note it does not consult any per-transport port a proxy might mandate
(e.g. a provider offering TCP on a non-5060 port); whichever fix is chosen should preserve this
existing copy-and-flip semantics rather than re-deriving the port, to avoid regressing that case.

---

## Context for us (swift-pjsua)

- Hit in the Offhook live suite (`offhook/Tests`), test04, 2026-07-04; full SIP trace in that
  session's logs (VoIP workspace, `testrun4.log`/`testrun5.log` scratchpad captures — sizes
  1297 → 407 → 1596-byte resend → silence).
- Local mitigation: engine opens a TCP listener beside UDP (`PJSUA.start()`), and callers use
  `;transport=tcp`; **TD-16** tracks the outbound-proxy surface that makes this transparent.
- **Verified 2026-07-04 (Cowork/DeepWiki connector task):** resend path does NOT re-resolve —
  `dest_info` reuse confirmed by source read (fork `868a376b` ≡ master in the relevant files;
  only `pjsua_acc.c` moved after the fork base: 2026-06-17 + 2026-06-24, registration logic,
  unrelated). No prior report found (tracker keyword search
  [tcp switch 401/407/fragment](https://github.com/pjsip/pjproject/issues?q=is%3Aissue+tcp+switch+401+OR+407+OR+fragment):
  0 open matches; closest is #2342, a different TCP/ACK corruption). Possibly-related
  archaeology if upstream asks: `sip_util.c` #4192 "Fixed SIP transport selection used to
  reach destination" (2024-12-03) touched this selection logic.

</details>
