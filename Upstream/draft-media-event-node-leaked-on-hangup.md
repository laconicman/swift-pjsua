# `call_media_on_event()` orphans a recycled event node when the call is hanging up

Upstream note for `pjsip/pjproject`. **Status: FILED 2026-08-19** — issue
[#5204](https://github.com/pjsip/pjproject/issues/5204) → PR
[#5205](https://github.com/pjsip/pjproject/pull/5205). Re-verified against real
`upstream/master` `288de6142` immediately before filing (the local fork's master was 23 commits
behind; the bug is present in both). We now *do* install `on_call_media_event` (TD-27), so this
costs us something.

Small, bounded-per-event, unbounded over process lifetime. Found while auditing which callbacks
survive the `call->hanging_up` guard, for the call-statistics design
(`swift-pjsua/docs/Call-Termination-Paths.md` §3). We do not currently install
`on_call_media_event`, so this costs us nothing today — we are filing it because we are about to
install it, and because it is a two-line fix.

---

## Issue draft

**Title:** `call_media_on_event()` leaks a `pjsua_event_list` node from the recycle list when
`call->hanging_up` is set

### Describe the bug

`call_media_on_event()` recycles `pjsua_event_list` nodes through a free list
(`pjsua_var.event_list`) guarded by `pjsua_var.timer_mutex`. It takes a node from the list — or
allocates a fresh one from `pjsua_var.timer_pool` when the list is empty — and then, only
afterwards, checks whether the call is hanging up and returns early:

```c
    if (pjsua_var.ua_cfg.cb.on_call_media_event) {
        pjsua_event_list *eve = NULL;

        pj_mutex_lock(pjsua_var.timer_mutex);

        if (pj_list_empty(&pjsua_var.event_list)) {
            eve = PJ_POOL_ALLOC_T(pjsua_var.timer_pool, pjsua_event_list);   /* allocate */
        } else {
            eve = pjsua_var.event_list.next;
            pj_list_erase(eve);                                              /* take from list */
        }

        pj_mutex_unlock(pjsua_var.timer_mutex);

        if (call->hanging_up)
            return status;                    /* <-- eve is neither used nor returned */

        eve->call_id = call->index;
        /* ... */
        pjsua_schedule_timer2(&call_med_event_cb, eve, 1);
    }
```
<sub>`pjsip/src/pjsua-lib/pjsua_media.c:1922-1943`</sub>

On that early return the node is not scheduled, so `call_med_event_cb()` — the only place that puts
a node back — never runs for it:

```c
void call_med_event_cb(void *user_data)
{
    pjsua_event_list *eve = (pjsua_event_list *)user_data;

    (*pjsua_var.ua_cfg.cb.on_call_media_event)(eve->call_id, eve->med_idx, &eve->event);

    pj_mutex_lock(pjsua_var.timer_mutex);
    pj_list_push_back(&pjsua_var.event_list, eve);      /* the only return path */
    pj_mutex_unlock(pjsua_var.timer_mutex);
}
```
<sub>`pjsip/src/pjsua-lib/pjsua_media.c:1808-1819`</sub>

The node is orphaned: erased from the free list and never re-linked, or freshly allocated and
immediately dropped.

### Impact

The memory itself lives in `pjsua_var.timer_pool` and is only released when pjsua is destroyed, so
this is not a heap leak and there is no corruption. The effect is that the **recycle list drains**:
every media event that arrives while a call is hanging up permanently removes one node from
circulation, and each subsequent event that finds the list empty allocates a new one from the pool.
`timer_pool` therefore grows monotonically with the number of such events over the process
lifetime.

For a short-lived softphone this is negligible. For a long-running server, gateway, or conference
bridge handling many calls — where "a media event arrives during hangup" is routine, since teardown
is exactly when media transports report errors — the pool grows without bound.

### Suggested fix

Move the `hanging_up` check above the node acquisition, so no node is taken when the event will be
discarded:

```c
    if (pjsua_var.ua_cfg.cb.on_call_media_event && !call->hanging_up) {
        pjsua_event_list *eve = NULL;
        /* ... unchanged ... */
    }
```

That also matches how every other `hanging_up` guard in the tree is written — the check comes first,
e.g. `pjsua_aud.c:553`, `pjsua_call.c:5486`, `pjsua_media.c:1952`. Alternatively, return the node to
the list before the early return; the reorder is simpler and allocates nothing in the common
teardown case.

A caveat for whoever writes the patch: `call->hanging_up` is currently read *outside* the
`timer_mutex` in the early-return position and would still be read outside it after the reorder —
that is unchanged behaviour, not something the fix introduces, but it is worth a glance to confirm
the guard is not expected to be mutex-protected.

---

## Context for us

Found by grep while establishing which callbacks are suppressed during hangup — the same audit that
confirmed `on_stream_destroyed` survives local hangup because `pjsua_call_hangup()` deinits media
*before* setting the flag (`pjsua_call.c:3410-3414`).

Relevant because `swift-pjsua` is about to install `on_call_media_event`: it is the only route to
`PJMEDIA_EVENT_MEDIA_TP_ERR`, which is the sole notification that a call's media transport has
failed — pjsua itself takes no action on that event
(`swift-pjsua/docs/Call-Termination-Paths.md` §3, table row 12).

**Verified 2026-08-19 — this is live, not latent, and the blast radius is larger than first
assumed.** `pjsua2` installs the callback **unconditionally** for every application built on the C++
API (`pjsip/src/pjsua2/endpoint.cpp:2374`,
`ua_cfg.cb.on_call_media_event = &Endpoint::on_call_media_event;`), dispatching to
`Call::onCallMediaEvent()` (`endpoint.cpp:2140`, `pjsua2/call.hpp:2413`) whether or not the
application overrides it — `Endpoint::on_call_media_event` allocates a
`PendingOnMediaEventCallback` and queues it unconditionally. (`:2124` in an earlier draft of this
note was a slipped citation: on `upstream/master` `288de6142`, `:2129` is the *endpoint-level*
`Endpoint::on_media_event`, a different callback, also installed at `:2373` but not implicated
here.) The pjsua CLI sample installs it too
(`pjsip-apps/src/pjsua/pjsua_app.c:1714`).

So **every pjsua2 application leaks a node for every media event that arrives during hangup**, with
no opt-out — and teardown is exactly when media transports report errors. That is worth stating in
the report: it raises this from a latent nit to a small unbounded growth affecting the whole C++
surface.
