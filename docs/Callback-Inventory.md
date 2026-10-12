# pjsua callbacks — every member, installed or not

`pjsua_callback` is how pjsua tells an application anything, and for some of its state it is the
only way ([Tech-Debt](./Tech-Debt.md) TD-31). This lists every member, what it conveys, the
context it runs in, and whether the engine installs it, so that wiring one is a decision about a
consumer rather than a new investigation.

- **Binary:** `swift-pjsip` 0.3.0, PJSIP master `bd69054a6`. Its `pjsua.h` is byte-identical to that
  commit's. **60 members**; 2.17.0 (`288de6142`) had 59, without `on_call_siprec_metadata_update`.
- **Call sites** are `file:line` in `pjsip/src/pjsua-lib/` at `bd69054a6`, generated from source.
- **Contexts** assume the engine's configuration:
  - `thread_cnt = 1` with timers on the same thread, so one **worker** polls the SIP ioqueue and the
    timer heap;
  - `media_cfg.has_ioqueue` with one **media** thread for plain RTP (`pjsua_media.c:104-108`);
  - ICE and STUN use the SIP ioqueue and timer heap, so they run on the worker
    (`pjsua_media.c:1179-1181`).

  "Engine" is the actor's executor thread: a callback runs there when pjsua invokes it inside a call
  the engine makes. ✓ marks a context read in source; *DW* one taken from DeepWiki and not re-read.
  The lock analysis is in [Threading-Validation](./Threading-Validation.md).

## Installed (12)

| Member | Event | Context |
|---|---|---|
| `on_call_state` | `.callState` | worker or engine; dialog/tsx locks, no `PJSUA_LOCK` |
| `on_incoming_call` | `.incomingCall` | worker; `PJSUA_LOCK` |
| `on_call_media_state` | `.callMediaState` | worker or engine |
| `on_stream_destroyed` | `.streamDestroyed` | `PJSUA_LOCK` on the disconnect path |
| `on_call_media_event` | `.callMediaEvent` | worker, through a 1 ms timer; no pjsua lock |
| `on_call_transfer_status` | `.callTransferStatus` | worker |
| `on_call_replaced` | `.callReplaced` | worker |
| `on_reg_started2` | engine's `RegistrationSignal` | caller of `pjsua_acc_set_registration`; `PJSUA_LOCK` |
| `on_reg_state2` | `.registrationState`, engine's `RegistrationSignal` | worker, or the sending thread when a send fails after its transaction exists; `PJSUA_LOCK` |
| `on_ip_change_progress` | `.ipChangeProgress`, engine's `RegistrationSignal` | engine or worker; `PJSUA_LOCK` |
| `on_transport_state` | `.transportState` (2026-10-12) | worker, or the sending thread; the locks depend on the path ✓ |
| `on_rejected_incoming_call` | `.incomingCallRejected` (2026-10-12) | worker; `PJSUA_LOCK` ✓ |

## Registration, account and transport

| Member | Fires at | Context | Conveys | Wire when |
|---|---|---|---|---|
| `on_reg_started` | `pjsua_acc.c:3927` | as `on_reg_started2` ✓ | v1 of `on_reg_started2` | never; v2 is installed |
| `on_reg_state` | `:3388` | as `on_reg_state2` ✓ | v1 of `on_reg_state2` | never |
| `on_auth_challenge` | `:98` | worker; for REGISTER the tsx `grp_lock` held, the session's lock released, no `PJSUA_LOCK` ✓ | the 401/407 and the request it challenges, and a hook to answer later | credential-on-demand (TD-11). A deferred REGISTER challenge clears the session's `has_tsx`, so the engine must count it as busy |
| `on_acc_find_for_incoming` | `:4268` | worker; `PJSUA_LOCK` held by the caller ✓ | choose the account for an incoming request | multiple accounts that pjsua's scoring cannot tell apart |
| `on_acc_send_request` | `:2042` | worker *DW* | the answer to `pjsua_acc_send_request` | when the engine sends out-of-dialog requests |
| `on_nat_detect` | `pjsua_core.c:3673` | worker ✓ | the detected NAT type | with STUN (TD-14, offhook OH-4) |
| `on_stun_resolution_complete` | `pjsua_core.c:2067` | worker or caller ✓ | the STUN server resolved | with STUN |

## Calls and signalling

| Member | Fires at | Context | Conveys | Wire when |
|---|---|---|---|---|
| `on_call_tsx_state` | `pjsua_call.c:6008`, `:7444` | worker; dialog and tsx locks *DW* | any in-call transaction's state (INFO, …) | an in-dialog feature |
| `on_call_tsx_terminate_session` | `:7910` | worker; tsx `grp_lock` | override the teardown after an in-dialog failure | a policy against it |
| `on_call_redirected` | `:7875` | worker; dialog lock | a 3xx; without it, pjsua stops and the call ends ✓ | following redirects |
| `on_call_rx_offer` | `:6487` | worker; dialog lock *DW* | a re-offer arriving | media negotiation control |
| `on_call_rx_reinvite` | `:6447`, `:6616` | worker; dialog lock *DW* | first look at a re-INVITE | same |
| `on_call_tx_offer` | `:6867` | worker; dialog lock *DW* | a re-offer about to be sent | same |
| `on_call_sdp_created` | `pjsua_media.c:3478`, `pjsua_vid.c:2210` | engine inside `makeCall`, or worker *DW* | the local SDP before it is sent | SDP edits (TD-14) |
| `on_call_transfer_request` / `2` | `pjsua_call.c:7197`, `:7205` | worker; dialog lock *DW* | an incoming REFER | a transfer-target UI |
| `on_call_replace_request` / `2` | `:2018`, `:2026` | worker; `PJSUA_LOCK` (inside `pjsua_call_on_incoming`) | an INVITE with Replaces | rejecting a replacement |
| `on_call_siprec_metadata_update` | `:2705`, `:6794` | — | SIPREC metadata (master only) | never, unless recording |

## Media

| Member | Fires at | Context | Conveys | Wire when |
|---|---|---|---|---|
| `on_call_media_transport_state` | `pjsua_media.c:1125`, `:1971` | lifecycle: the media operation's thread; ICE: worker, no pjsua lock ✓ | the media transport's lifecycle; with ICE, a TURN-refresh failure and a STUN-detected change of the mapped address | ICE with TURN (OH-4). **Not** a peer-liveness signal (TD-27) |
| `on_ice_transport_error` | `:1132` | worker; no pjsua lock ✓ | **a TURN refresh failure only**. Its first argument is the call ID, not the "transport index" the header names | same |
| `on_media_event` | `:1813` | the publishing thread (sound device, media); no pjsua lock *DW* | a `pjmedia_event` outside any call, such as a sound-device error | the audio session's own failure handling |
| `on_stream_precreate` | `pjsua_aud.c:750`, `pjsua_vid.c:1275` | the media operation's thread *DW* | stream parameters before creation (jitter buffer, keep-alive) | jitter-buffer tuning (TD-26) |
| `on_stream_created` / `2` | `pjsua_aud.c:835`, `:828` | same *DW* | the live `pjmedia_stream*` | never; statistics come from getters and `on_stream_destroyed` |
| `on_create_media_transport` | `pjsua_media.c:2345` | same *DW* | a hook to substitute the media transport | a custom transport |
| `on_create_media_transport_srtp` | `:2097` | same; deprecated *DW* | SRTP options | never |
| `on_snd_dev_operation` | `pjsua_aud.c:1170` and six more | the caller, mostly under `PJSUA_LOCK` *DW* | the sound device is about to open or close | if CallKit's audio session needs that edge |
| `on_conf_op_completed` | `pjsua_aud.c:380` (`pjmedia_conf_set_op_cb`) | conference or media thread (header) | an asynchronous conference-bridge operation finished | conference work that must wait for it |
| `on_vid_conf_op_completed` | `pjsua_vid.c:147` | same | the video variant | same, for video |
| `on_dtmf_digit`, `on_dtmf_digit2`, `on_dtmf_event` | `pjsua_aud.c:645-681`, `pjsua_call.c:7742-7745` | media thread (RFC 2833) or worker (SIP INFO) *DW* | a received DTMF digit | a DTMF feature |
| `on_call_rx_text` | `pjsua_txt.c:110`, `:251` | media *DW* | received real-time text | never |

## Presence, IM and MWI

None is wanted: the engine has no presence, IM or MWI feature.

| Members | Fires at | Context |
|---|---|---|
| `on_incoming_subscribe`, `on_srv_subscribe_state` | `pjsua_pres.c:1166`, `:962` | worker; `PJSUA_LOCK` ✓ |
| `on_buddy_state`, `on_buddy_dlg_event_state`, `on_buddy_evsub_state`, `on_buddy_evsub_dlg_event_state` | `pjsua_pres.c:1873-1886` | worker; the buddy dialog's lock, no `PJSUA_LOCK` ✓ |
| `on_pager`, `on_pager2`, `on_pager_status`, `on_pager_status2`, `on_typing`, `on_typing2` | `pjsua_im.c:228-576`, `pjsua_call.c:7516-7533` | worker *DW* |
| `on_mwi_state`, `on_mwi_info` | `pjsua_pres.c:2321`, `:2363`, `:2630` | worker; the subscription's dialog lock ✓ |

## What is not here

What each piece of callback-only state is, and what would justify keeping it, is in TD-31. Why
G2 makes every one of these safe to install is in Threading-Validation. Upstream issues found while
building this:
- [pjsip/pjproject#5330](https://github.com/pjsip/pjproject/issues/5330): `contact_rewritten` is
  written after `PJSUA_UNLOCK()`;
- [#5333](https://github.com/pjsip/pjproject/issues/5333): an un-REGISTER whose start is reported
  and whose answer is not;
- [#5334](https://github.com/pjsip/pjproject/issues/5334): a STUN keep-alive failure after ICE init
  is never reported.

## Sources

DeepWiki deep consults on `pjsip/pjproject`, every claim they flagged re-read in source:
[account state](https://deepwiki.com/search/which-pjsua-account-internal-s_542c5437-86cc-491c-8bc6-4bb66c8a6ce8?mode=deep),
[`on_transport_state`](https://deepwiki.com/search/pjsuacallbackontransportstate_b59d52be-5480-4e5c-a610-5245329cf58b?mode=deep),
[media and ICE health](https://deepwiki.com/search/media-and-ice-health-in-pjsua1_c5c01052-e1c8-4142-92b1-37d9a50e90f1?mode=deep),
[auth challenge and the remaining contexts](https://deepwiki.com/search/two-parts-from-source-with-fil_0716fb09-6188-4306-949b-22a3bba764f1?mode=deep),
[review of the two issues](https://deepwiki.com/search/two-claims-to-check-against-cu_f2e17ca9-d5d8-45a8-af0f-d07d4c75438f?mode=deep).
