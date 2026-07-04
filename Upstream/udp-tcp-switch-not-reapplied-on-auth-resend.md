# UDP→TCP size switch is not re-applied on the 401/407 authenticated resend

Upstream note for `pjsip/pjproject`. **Status: verified 2026-07-04 — ready to file.**
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
