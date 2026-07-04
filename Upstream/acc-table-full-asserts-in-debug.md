# `pjsua_acc_add` aborts debug builds when the account table is full

Upstream note for `pjsip/pjproject`. **Status: verified 2026-07-04 — ready to file as a
discussion / documentation issue** (behaviour is "by PJLIB convention", as suspected).
Confirmed on master via DeepWiki deep-mode
([conversation](https://deepwiki.com/search/what-is-pjsuamaxacc-can-i-be-o_31d0692b-982d-44fd-986c-a171ce2f052d?mode=deep)):
guard is `PJ_ASSERT_RETURN(pjsua_var.acc_cnt < PJ_ARRAY_SIZE(pjsua_var.acc), PJ_ETOOMANY)` at
`pjsua_acc.c:463-464`; `PJSUA_MAX_ACC` defaults to **8** (`pjsua.h:3622-3627`), is `#ifndef`
compile-time only (no runtime override); slots ARE recycled (first-fit scan for
`valid == PJ_FALSE`, `pjsua_acc.c:482-485`; `pjsua_acc_del` bzeroes the slot, `:731-734`; the
slot pool is reset, not re-created, `:494-498`). Master `pjsua_acc.c` gained two commits after
our fork base (2026-06-17, 2026-06-24 — registration/reconnect logic); the guard is untouched.

---

## Issue draft

**Title:** `pjsua_acc_add` uses `PJ_ASSERT_RETURN` for the account-table-full condition —
debug builds abort on a user-input-driven state

### Summary

`pjsua_acc_add()` guards the fixed account table with
`PJ_ASSERT_RETURN(pjsua_var.acc_cnt < PJ_ARRAY_SIZE(pjsua_var.acc), PJ_ETOOMANY)`
(pjsua_acc.c). In release builds this correctly returns `PJ_ETOOMANY`; in debug builds
`pj_assert` **aborts the process**.

Whether the table is full is not a programming error — it is driven by how many accounts the
*user* configures at runtime (multi-account softphones hit this organically, especially with
`PJ_CONFIG_IPHONE`'s sample `PJSUA_MAX_ACC = 4`, where transports/probes/user accounts sum up
quickly). Per common assert doctrine, asserts are for invariants the programmer controls;
capacity exhaustion from user input should be an error return in all build configurations.

### Suggested improvement

Convert the capacity check to a plain `if (…) return PJ_ETOOMANY;` — this is already the
codebase's own pattern for the **analogous calls-capacity condition**: at the
`PJSUA_MAX_CALLS` limit, `pjsua_call_make_call` returns `PJ_ETOOMANY` via a plain `if`
(`pjsua_call.c:879-883`) and an incoming INVITE gets a stateless `486 Busy Here`
(`pjsua_call.c:1616-1623`) — neither asserts in any build type. `pjsua_acc_add` is the
outlier. Alternatively, document prominently on `pjsua_acc_add()` that debug builds abort
and that applications must pre-check `pjsua_acc_get_count()` against `PJSUA_MAX_ACC`.

### Repro

Debug build, `PJ_CONFIG_IPHONE` (`PJSUA_MAX_ACC = 4`): add 5 accounts →
`Assertion failed: (pjsua_var.acc_cnt < (sizeof(pjsua_var.acc)/sizeof(pjsua_var.acc[0]))),
function pjsua_acc_add, file pjsua_acc.c` → abort. Release: `PJ_ETOOMANY`.

---

## Context for us (swift-pjsua)

- Hit live 2026-07-04 (Offhook suite test03 crashed the test runner: 4 user accounts + 1
  throwaway auth-probe account).
- Local mitigation (kept regardless of upstream outcome): `addAccount` pre-checks
  `pjsua_acc_get_count() < PJSUA_MAX_ACC` and throws `PJSUAUsageError.accountTableFull`;
  `removeAccount(_:)` frees slots.
- Related footgun to mention in the same discussion: `config_site_sample.h`'s iPhone config
  pins `PJSUA_MAX_ACC = 4` / `PJSUA_MAX_CALLS = 4` — easy to inherit unknowingly via
  `PJ_CONFIG_IPHONE` (we did).
