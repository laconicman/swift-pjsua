---
area: transport-udp
kind: bug
status: merged
tracker:
  issue: pjsip/pjproject#5075
  pr: pjsip/pjproject#5076
  docs_pr: pjsip/pjproject_docs#67
---

# Tracked issue draft — silent UDP fallback + docs gap for the §18.1.1 TCP switch

For `pjsip/pjproject`. Pairs with fork PR
[laconicman/pjproject#3](https://github.com/laconicman/pjproject/pull/3) (docs + logging only).
File this first, then reference it from the PR (maintainers prefer a tracked issue even for
docs/logging-only changes).

---

**Title:** Oversized request silently falls back to UDP when the §18.1.1 TCP switch has no TCP
transport to use — undocumented and unlogged

### Summary

When an outgoing request exceeds `PJSIP_UDP_SIZE_THRESHOLD` (1300 B) and `disable_tcp_switch`
is 0, `stateless_send_resolver_callback()` correctly applies the RFC 3261 §18.1.1 switch by
inserting TCP versions of the resolved UDP addresses ahead of the UDP ones. But if the
application only ever created a **UDP** transport, `pjsip_endpt_acquire_transport2()` for the
TCP entry fails; `stateless_send_transport_cb()` then advances `cur_addr` to the next candidate
— the original UDP address — and the oversized request is sent over **UDP**, where it fragments
and is frequently dropped by NATs/SIP proxies.

Two aspects make this hard to diagnose:

1. **No log at the fallback.** The `if (status != PJ_SUCCESS) { sent = -status; continue; }`
   path in `stateless_send_transport_cb()` is silent, so from the application's side the
   request simply never gets through (call/registration times out with no explanation).
2. **The prerequisite isn't documented.** The `PJSIP_UDP_SIZE_THRESHOLD` doc and the
   "Automatic switch to TCP…" guide describe the switch as automatic without stating that a
   TCP (or, for `sips:`, TLS) transport must be registered for it to have any effect.

### Impact

Common: a softphone that opens only a UDP transport and registers against a proxy that
digest-challenges (e.g. Flexisip). The unauthenticated INVITE is under 1300 B and goes out
fine; the authenticated resend (SDP + `Proxy-Authorization`) crosses 1300 B, the switch tries
TCP, finds none, and the resend fragments on UDP — the call silently fails to connect.

### Not a defect in the switch itself

The switch logic is correct: it cannot use a transport that was never created. The fix on the
application side is to create a TCP/TLS transport (or route via one). This issue is purely about
**diagnosability** — a trace log at the fallback and a documentation note.

### Proposed change (see PR)

- `sip_util.c`: a `PJ_LOG(5,…)` at the transport-acquire fallback naming the transport type,
  the message, and the error.
- `sip_config.h`: a note on `PJSIP_UDP_SIZE_THRESHOLD` that the switch requires a registered
  TCP/TLS transport, else an over-MTU request may be sent oversized over UDP.

No behaviour change.

### Reproduction

pjsua/pjsip client with **only** a UDP transport, calling/registering through a proxy that
407/401-challenges, with an offer large enough that the authenticated request exceeds 1300 B
(audio+video or many codecs). Wireshark shows the oversized authenticated request fragmenting
on UDP; enabling the proposed level-5 log shows the "Unable to acquire TCP transport … trying
next address" fallback.
