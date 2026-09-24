---
area: rtcp-xr
kind: enhancement
status: ready
verified: cb0544e0d
---

# RTCP XR statistics are unreachable from pjsua1 except by parsing a text dump

Upstream note for `pjsip/pjproject`. **Status: verified 2026-08-17 against fork `cb0544e0d`
(upstream master of the same day: `7e95d9f70`) — ready to file as an enhancement.**

**Enhancement, not a defect.** Low priority for us: our own capture point does not need it (see
"Context" below). Filed for symmetry and for anyone wanting XR mid-call.

Supersedes the root-level `upstream-pjproject-rtcp-xr-notes.md` from the same pass, which was
written before this `Upstream/` convention was applied to it.

---

## Issue draft

**Title:** Add a structured pjsua1 accessor for RTCP XR statistics
(`pjsua_call_get_stream_stat_xr()`)

### Is your feature request related to a problem?

With `PJMEDIA_HAS_RTCP_XR` and `PJMEDIA_STREAM_ENABLE_XR` compiled in and
`pjsua_acc_config.enable_rtcp_xr` set, pjmedia collects a full RFC 3611 VoIP Metrics picture —
including the burst/gap density that plain `pjmedia_rtcp_stat` cannot express, computed by the
Markov model in `pjmedia_rtcp_build_rtcp_xr()` (`pjmedia/src/pjmedia/rtcp_xr.c:294-329`). A pjsua1
application has no structured way to read any of it.

- `pjsua_stream_stat` carries `pjmedia_rtcp_stat rtcp` and `pjmedia_jb_state jbuf` only — there is
  no XR member (`pjsip/include/pjsua-lib/pjsua.h:672-680`), so `pjsua_call_get_stream_stat()`
  cannot return it.
- `pjmedia_stream_get_stat_xr()` exists but takes a `pjmedia_stream *`
  (`pjmedia/include/pjmedia/stream.h:291-301`), and pjsua1 exposes no getter for that pointer —
  `call_med->strm.a.stream` is internal.
- The only place pjsua-lib reaches it is `dump_media_session()`
  (`pjsip/src/pjsua-lib/pjsua_dump.c:504-544`), which formats the values into a human-readable
  string for `pjsua_call_dump()`. An application wanting the numbers must re-parse that text.

The sample `pjsip-apps/src/samples/streamutil.c` uses the pjmedia API directly, on a stream object
it owns — which is not available to a pjsua1 app.

### Describe the solution you'd like

A structured accessor beside the existing one:

```c
PJ_DECL(pj_status_t) pjsua_call_get_stream_stat_xr(pjsua_call_id call_id,
                                                   unsigned med_idx,
                                                   pjmedia_rtcp_xr_stat *stat);
```

resolving `call->media[med_idx].strm.a.stream` and delegating to `pjmedia_stream_get_stat_xr()`,
exactly as `pjsua_dump.c` already does internally — guarded by
`#if defined(PJMEDIA_HAS_RTCP_XR) && PJMEDIA_HAS_RTCP_XR != 0`, matching the guard on the pjmedia
declaration. Additive: no change to existing structs, so no ABI break. Optionally mirrored in
pjsua2's `Call` class.

### Describe alternatives you've considered

An application that only needs **end-of-call** statistics can already obtain the `pjmedia_stream *`
from the `on_stream_destroyed` callback (`pjsua.h:1580-1582`) and call the pjmedia API on it
directly — the stream is still fully constructed at that point (pjsua itself calls
`pjmedia_stream_get_stat()` on the same pointer at `pjsua_aud.c:540`, 13 lines before invoking the
callback at `:553-557`, and destroys it at `:573`).

So the gap is specifically **mid-call** reads. That is why this is filed as a convenience/symmetry
enhancement rather than a blocker.

---

## Context for us

We take the `on_stream_destroyed` route, so we do not need this API. We are also **not enabling XR**
for now: three independent gates all default to off —

| Gate | Default | Where |
|---|---|---|
| `PJMEDIA_HAS_RTCP_XR` | `0` | `pjmedia/include/pjmedia/config.h:644-645` |
| `PJMEDIA_STREAM_ENABLE_XR` | `0` | `config.h:656-657` |
| `pjsua_acc_config.enable_rtcp_xr` | `0` (derived) | `pjsua.h:5188`; from the product of the two above at `pjsua_core.c:408` |

— the third also adds `a=rtcp-xr` to the SDP (`pjsua_media.c:3352-3360`), i.e. enabling it is a
signalling change visible to every registrar and SBC, in exchange for a debug statistic. And it
would not yield a MOS in any case (see the sibling note,
[rtcp-xr-r-factor-has-no-writer](rtcp-xr-r-factor-has-no-writer.md) — pjmedia never
computes the quality scores). Reasoning: `offhook/docs/Call-Quality-Statistics.md` §6.

**The defaults are deliberate**, documented in the macro comments (footprint, plus per-stream
runtime opt-in) — recorded here only so the next person does not mistake them for an oversight.
