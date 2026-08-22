---
area: rtcp-xr
kind: question
status: ready
verified: cb0544e0d
---

# RTCP XR: the local R-factor field has no writer, so pjproject always reports it unavailable

Upstream note for `pjsip/pjproject`. **Status: mechanically verified 2026-08-17 against fork
`cb0544e0d` (upstream master of the same day: `7e95d9f70`); the *reading of intent* is not verified
— file as a question, not as a bug report.**

Sibling of [rtcp-xr-no-structured-pjsua1-accessor](rtcp-xr-no-structured-pjsua1-accessor.md).
Both came out of the same call-quality design pass; they are separate notes because they would be
separate issues.

---

## Issue draft

**Title:** `PJMEDIA_RTCP_XR_INFO_R_FACTOR` writes `ext_r_factor`, leaving `r_factor` permanently 127
— intended?

### Describe the bug

`pjmedia_rtcp_xr_stream_stat.voip_mtc.r_factor` is written in exactly one place in
`pjmedia/src/pjmedia/`: the "unavailable" initialisation.

```c
/* pjmedia/src/pjmedia/rtcp_xr.c:88-91 */
session->stat.rx.voip_mtc.r_factor     = 127;
session->stat.rx.voip_mtc.ext_r_factor = 127;
session->stat.rx.voip_mtc.mos_lq       = 127;
session->stat.rx.voip_mtc.mos_cq       = 127;
```

It is nonetheless transmitted on every outgoing report:

```c
/* rtcp_xr.c:382-383 */
r->r_factor     = sess->stat.rx.voip_mtc.r_factor;      /* always 127 */
r->ext_r_factor = sess->stat.rx.voip_mtc.ext_r_factor;
```

The application-facing setter maps `PJMEDIA_RTCP_XR_INFO_R_FACTOR` to **`ext_r_factor`**, not
`r_factor`:

```c
/* rtcp_xr.c:821-823 */
case PJMEDIA_RTCP_XR_INFO_R_FACTOR:
    sess->stat.rx.voip_mtc.ext_r_factor = (pj_uint8_t) v;
    break;
```

whereas the neighbouring MOS cases write their matching fields (`:825-830`), so the asymmetry looks
specific to `r_factor` rather than a convention applied across the group.

`grep -rn 'rx\.voip_mtc\.r_factor' pjmedia/src/pjmedia/` returns only lines 88 and 382.

### Consequence

pjproject always advertises R factor = 127 ("unavailable" per RFC 3611 §4.7), and an application has
no way to populate it — only the extended field. `pjsua_dump.c:515-519` correspondingly prints
`"(na)"`.

### Why the field choice may be wrong

RFC 3611 §4.7 distinguishes the two:

> **R factor:** "a voice quality metric describing the segment of the call that is carried over
> **this** RTP session"
>
> **Extended R factor:** a metric for a segment carried **outside** this RTP session (e.g. a
> wireless or other non-IP leg).

An application computing an R value from its own reception statistics for *this* stream is producing
the former, not the latter.

### Suggested resolution

Either:

- point `PJMEDIA_RTCP_XR_INFO_R_FACTOR` at `r_factor` and add a separate
  `PJMEDIA_RTCP_XR_INFO_EXT_R_FACTOR` for the genuinely out-of-session case (behaviour change; would
  alter what existing callers put on the wire, so worth a note in the release notes); **or**
- if the current mapping is deliberate, say so in the `pjmedia_rtcp_xr_info` doc comment
  (`pjmedia/include/pjmedia/rtcp_xr.h:62-70`), since the enum name currently implies otherwise, and
  document that `r_factor` is not settable.

We have no strong preference and would defer to whichever matches the original intent — hence
filing as a question.

---

## Context for us

Found while establishing whether enabling RTCP XR would give us a MOS for an on-device call-quality
feature. It would not, and this is part of why: **pjmedia never computes R-factor or MOS at all.**
It initialises all four quality fields to 127, relays whatever a peer sends
(`rtcp_xr.c:627-630` decodes a received block into the `tx` side), and otherwise expects the
*application* to supply values via `pjmedia_rtcp_xr_update_info()` (`:801-830`). What pjmedia does
compute locally is loss rate, discard rate, and burst/gap density and duration via the RFC 3611
Appendix A.4 Markov model, with `Gmin` defaulting to the RFC's recommended 16 (`rtcp_xr.c:52`).

That division of labour is entirely reasonable — quality scoring is a policy decision, and
`pjmedia_rtcp_xr_update_info()` is the hook for it. It just means the hook has one field it cannot
reach.

(Our own conclusion was to compute no scalar at all: ITU-T G.107 §1 states its estimates are "only
made for transmission planning purposes and not for actual customer opinion prediction". See
`offhook/docs/Call-Quality-Statistics.md` §5 — not upstream's problem, noted only to explain why we
are not proposing that pjmedia compute an R factor itself.)
