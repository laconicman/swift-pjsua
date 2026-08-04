# Configuration & credentials — design draft

**Status: draft, 2026-07-17.** Pre-implementation DeepWiki consult on the pjsua config surface is
in flight; §5 lists what may still move. Post-implementation review is planned per the standing
deep-consult rule.

Consolidates the config-shaped debt — **TD-16** (no outbound-proxy surface), **TD-18** (transport
port model), **TD-14** (STUN/ICE/DNS unexposed), codec priority, and the credential half of
**TD-11** — into one vocabulary, so those features become *field additions* rather than repeated
signature churn.

## 1. The problem

`addAccount(id:registrar:username:password:realm:push:makeDefault:)` already carries seven
parameters and `Configuration` holds a single `port`/`transport`. Every pending feature wants to
add more. Growing the parameter list per feature is the smell; pjproject's own conventions say it
too ("prefer param structs over many positional arguments for extensibility"). The public API
shape is the expensive-to-reverse decision, so it gets the up-front design (BDUF proportional to
cost of change).

## 2. Three layers

| Layer | Owner | Contents |
|---|---|---|
| **A — vocabulary** | `SwiftPJSUA` | `Configuration`, `AccountConfiguration`, `TransportConfiguration` — `Sendable` + `Codable`, **no secrets** |
| **B — secret seam** | `SwiftPJSUA` (protocol only) | `CredentialStore` — engine retains the *store*, never the secret |
| **C — persistence** | app (Offhook) | Keychain for secrets; JSON/file for the Codable config |

The A/B split is the load-bearing one: **secrets are absent from the `Codable` types by
construction**, so no amount of app-side persistence can accidentally serialise a password to
disk. That property is why config and credentials are separate types rather than one struct with
a `password` field.

## 3. Layer A — the types

Shapes below are the **target** vocabulary, informed by the consult (§5). Fields marked ⏳ are
*placed* here but land **with their feature**, not in step 1 — a config field the engine silently
ignores is a bug factory.

```swift
public struct TransportConfiguration: Sendable, Codable, Equatable {
    /// Stable, app-chosen label. Accounts reference a transport **by name**; the engine resolves
    /// it to the runtime `pjsua_transport_id` at creation. Raw ids are runtime values and must
    /// never leak into persisted config.
    public var name: String
    public var kind: Transport          // .udp | .tcp | .tls
    public var port: UInt32             // 0 = ephemeral. IANA 5060 UDP/TCP, 5061 TLS (RFC 3261 §19.1.2)

    public init(_ name: String, _ kind: Transport, port: UInt32? = nil)  // port defaults per kind
}

/// → `pjsua_media_config`: the **global media defaults** accounts inherit.
public struct MediaConfiguration: Sendable, Codable, Equatable {
    public var isICEEnabled: Bool = false          // ⏳ TD-14
    public var turnServer: String?                 // ⏳ TD-14
}

extension PJSUA {
    public struct Configuration: Sendable, Codable, Equatable {
        /// Replaces the single `port`/`transport` pair — closes TD-18. The default makes today's
        /// implicit "UDP primary + TCP listener" explicit.
        public var transports: [TransportConfiguration] = [.init("udp", .udp), .init("tcp", .tcp)]
        public var userAgent: String = "swift-pjsua"
        public var logLevel: UInt32 = 4
        public var stunServers: [String] = []      // ⏳ → pjsua_config.stun_srv[]
        public var nameservers: [String] = []      // ⏳ → pjsua_config.nameserver[]
        public var media = MediaConfiguration()    // → pjsua_media_config
        /// Codec id → priority (0 disables … 255 highest), e.g. ["PCMU/8000": 128].
        /// **Global in pjsua1**, applied after `pjsua_init` — never per-account. ⏳
        public var codecPriorities: [String: UInt8] = [:]
    }
}

public struct AccountConfiguration: Sendable, Codable, Equatable {
    public var id: String                 // "sip:alice@example.com"
    public var registrar: String          // "sip:example.com" (Request-URI of REGISTER; independent of proxies)
    public var username: String
    public var realm: String = "*"

    /// Pins the account to a `TransportConfiguration.name` → `acc_config.transport_id`.
    /// `nil` = let the stack choose (URI scheme / `;transport=`). ⏳ TD-18
    public var transportName: String?

    /// Outbound proxies as full SIP URIs — **`;lr` strongly recommended**: without it pjsip
    /// treats the proxy as a *strict* router (RFC 3261 §16.1), which breaks most deployments.
    /// Inserted as `Route` on **every** request for the account. Capped at
    /// `PJSUA_ACC_MAX_PROXIES`. ⏳ TD-16
    public var proxies: [String] = []
    /// REGISTER-only control over which proxies appear in the REGISTER route set
    /// (`reg_use_proxy` bitmask; pjsua default = both). ⏳ TD-16
    public var registrationProxyUse: RegistrationProxyUse = .both

    public var push: PushConfiguration?
    public var isDefault: Bool = true
    // Deliberately NO password — see Layer B.
    // ⏳ TD-14: per-account `ice`/`turn` overrides (nil = inherit `Configuration.media`)
    //           map to acc_config.ice_cfg / turn_cfg.
}
```

`Codable` on these is a deliberate affordance: the app persists the engine's own vocabulary
instead of maintaining a mirrored DTO (DRY). It is safe *because* secrets live elsewhere.

## 4. Layer B — the credential seam

```swift
/// Identifies which secret the engine needs. Carries no secret itself.
public struct CredentialRequest: Sendable, Equatable {
    public let accountID: String   // AccountConfiguration.id
    public let username: String
    public let realm: String
}

public protocol CredentialStore: Sendable {
    /// Called on demand when the engine must (re)build an account's credentials —
    /// at `addAccount` and again on `reRegister`.
    ///
    /// - Important: implementations must not block the caller's executor; do I/O off-actor.
    func secret(for request: CredentialRequest) async throws -> String
}

/// Closure adapter — tests (env vars) and simple apps.
public struct InlineCredentialStore: CredentialStore { /* wraps @Sendable (CredentialRequest) async throws -> String */ }

extension PJSUA {
    public func addAccount(_ config: AccountConfiguration,
                           credentials: CredentialStore) async throws -> AccountID
}
```

The engine retains the **store**, not the secret, so `reRegister` can re-fetch. That removes the
Swift-side plaintext copy in `AccountParameters` — the half of TD-11 we can actually close today.

**Honest ceiling (verified):** pjsua still deep-copies the credential into `acc->pool` *and* the
shared auth session's pool, alive until `pjsua_acc_del`, never zeroed (`pj_pool_t` is a bump
allocator with no scrub API). The stronger posture — `cred_count = 0` plus the
`on_auth_challenge` hook — needs **PJSIP 2.17+** (`db3cfdee`; absent from our pinned 2.16), so it
is deliberately out of scope for this iteration and additive later.

### Concurrency (Swift 5 mode, tools 5.9, no strict-concurrency flags)

1. **Re-entrancy is newly relevant.** `addAccount` is synchronous today, so it runs to completion
   on the actor's executor. Adding `await` makes it re-entrant: another `addAccount` /
   `removeAccount` can interleave at the suspension. The account-table capacity check therefore
   becomes **TOCTOU** — two callers can both pass the guard for one free slot. On 2.16 that is a
   debug **abort**, not an error. → **Re-check capacity after the last `await`, immediately
   before the C call.** (This corrects my earlier claim that the single pinned executor made the
   check inherently atomic — true only while the method has no suspension point.)
2. **Never suspend inside `withAccConfig`.** That closure hands C a `pjsua_acc_config` whose
   `pj_str_t` fields point into Swift buffers held alive by `withExtendedLifetime`. Resolve the
   secret *before* entering it.
3. **Executor placement.** In Swift 5 mode a `nonisolated async` requirement invoked from the
   actor runs on the global concurrent executor, so Keychain I/O will not occupy the pinned PJLIB
   thread. ⚠️ Adopting Swift 6.2's `NonisolatedNonsendingByDefault` flips this (nonisolated async
   inherits caller isolation) and would put Keychain I/O — including biometric prompts — on the
   PJLIB thread. Revisit this note at any language-mode bump.

### Deliberately rejected (YAGNI)

- A `Secret` enum with a `digestHA1` case. The consult showed HA1 is bound to one *realm* and one
  *algorithm* (a plain password covers all algorithms automatically), so it trades one plaintext
  for a realm×algorithm matrix. Additive later if a deployment demands it.
- Persisting anything inside the engine.

## 5. Consult findings that shaped the above

Deep consult, 2026-07-17
([conversation](https://deepwiki.com/search/five-questions-about-the-pjsua_b5a757a3-8914-41e8-b69c-417c26a029bf?mode=deep)):

- **There is no per-account port.** Ports belong to *transports*, created independently
  (`pjsua_transport_create` → `pjsua_transport_id`); an account pins one via
  `acc_config.transport_id`. Precedence: `transport_id` → URI `;transport=` / `sips:` → stack
  auto-select. This is why our `;transport=tcp` dial-URI workaround worked (level 2) and it
  dictates the **name-based reference** above, since raw ids can't be persisted.
- **`proxy[]` vs `reg_use_proxy` are different scopes.** `proxy[]` becomes a `Route` on *every*
  request; `reg_use_proxy` is a REGISTER-only bitmask (outbound-proxy bit | account-proxy bit,
  default both) — so REGISTER can skip proxies that still apply to calls. `;lr` matters:
  omitting it selects strict routing.
- **STUN/DNS are global (`pjsua_config`); ICE/TURN are global *defaults* (`pjsua_media_config`)
  with per-account overrides (`acc_config.ice_cfg` / `turn_cfg`, seeded by
  `pjsua_ice_config_from_media_config()`).** Hence the nested `media` struct plus optional
  per-account overrides, rather than one flat ICE flag.
- **Codec priority is strictly global** (`pjsua_codec_set_priority`, one codec manager), callable
  after `pjsua_init` — so it is engine-level config applied during `start()`, never an account
  field.
- **`pjsua_acc_modify` accepts every field** — nothing needs delete-and-re-add. An
  `update(_ account:to:)` API is therefore viable, and `AccountConfiguration` can be treated as
  live-editable state on the app side.

## 6. As-built (2026-07-17) — decisions and the review that changed them

Layers A and B are implemented; both the engine and Offhook build clean. New files:
`TransportConfiguration.swift`, `AccountConfiguration.swift`, `CredentialStore.swift`;
`Configuration` and `PJSUA+Accounts.swift` reworked.

**D-CONFIG-0 — one door, and the secret's provenance is visible at every call site.**
The transitional `addAccount(id:registrar:username:password:…)` overload was **removed**
(2026-07-17), not deprecated: with no external consumers and three call sites, a second entry
point accepting a raw `password:` would have made D-CONFIG-1 advisory rather than structural.
Callers that legitimately hold a password still pass one — but they must name
`InlineCredentialStore(password:)`, which is explicit, greppable, and reads as a choice instead
of the default path. Migrated: `PhoneModel.register()` and two integration tests.

**D-CONFIG-1 — secrets are absent from the config type, not merely discouraged.**
`AccountConfiguration` is `Codable` *because* it cannot hold a secret; the two are one decision.
Secrets arrive through ``CredentialStore``, which the engine retains **per account** so
`reRegister` can re-fetch. `AccountParameters` no longer stores a password — the Swift half of
**TD-11** is closed. (The pjsua-side copies remain: see §4's ceiling note.)

**D-CONFIG-2 — the check-then-add race is prevented structurally, not by re-checking.**
Introducing `await` into `addAccount` would make it actor-re-entrant, so a capacity check before
the suspension could be invalidated by an interleaved call — and on PJSIP ≤ 2.17 debug builds the
loser *aborts*. The public method takes its one suspension (the credential fetch) up front and
then calls a **private non-`async`** function holding the guard and `pjsua_acc_add`. Actors do
not interleave without a suspension point, and a future `await` there would not compile. Same
shape for `reRegister`, whose synchronous tail also re-validates the account.

**D-CONFIG-3 — transports own ports; accounts reference a transport by name.** pjsua has no
per-account port. `start()` creates one transport per `TransportConfiguration` and records
`name → pjsua_transport_id`; `AccountConfiguration.transportName` resolves through that map to
`acc_config.transport_id`. Names exist because transport ids are runtime values that must never
enter persisted config. Closes the port half of **TD-18**.

**D-CONFIG-4 — `pjsua_acc_modify` is read-modify-write.** *Changed by the post-implementation
review.* The first cut rebuilt a whole `pjsua_acc_config` from defaults; `pjsua_acc_modify` diffs
against the **live** config, so that silently reset `server_affinity`, `allow_contact_rewrite`,
the negotiated `reg_timeout` and retry intervals, `rtp_cfg.port` (zeroing `next_rtp_port`), and
`ice_cfg_use`/`turn_cfg_use`. `reRegister` now does `pjsua_acc_get_config` into a scratch pool,
overwrites only the credential and push params, then modifies — the pattern pjsua's own app and
tests use. The pre-existing comment claiming `get_config` was "fragile" was wrong and is gone.
`addAccount` still builds fresh, which is correct there: no live config exists yet.

**Hazards documented on the API** (also from the review):
- Pinning is **strict**: a pin/URI mismatch fails the request with `PJSIP_ETPNOTSUITABLE`, it does
  not fall back.
- **Pinning a UDP transport disables the RFC 3261 §18.1.1 size upgrade** and thereby re-creates
  pjsip/pjproject#5075 — the upgrade inserts TCP candidates the UDP pin cannot acquire, so the
  oversized request fragments. Pinning TCP is safe (listener selector); `nil` stays the default.
- Rotating the secret on `modify` triggers unregister + re-REGISTER; a failed re-registration
  leaves the account unregistered with **no config rollback**.

**Misuse sweep (2026-07-17) — the rest of the config surface is clean.** Having found D-CONFIG-4,
we swept every pjsua config struct the wrapper touches for the same "fresh default into a
modify-style API" hazard
([conversation](https://deepwiki.com/search/misuse-sweep-for-that-same-cla_bb8d7a19-cc1b-44fb-bd24-32dd7d442b8e?mode=deep)):

| Struct | Modify-style consumer | Must read-modify-write? | Our usage |
|---|---|---|---|
| `pjsua_config`, `pjsua_media_config` | none (`pjsua_init` only) | n/a | fresh default — **correct** |
| `pjsua_transport_config` | `pjsua_transport_lis_restart` | **yes, for TLS** (`tls_setting` is zeroed) | we only `create` — correct today; **TD-19** for M2 |
| `pjsua_acc_config` | `pjsua_acc_modify` | **yes, always** | fixed — D-CONFIG-4 |
| `pjsua_call_setting` | per-operation, no live state | no | fresh default — correct (and we already pin `vid_cnt` explicitly) |
| `pjsua_call_vid_strm_op_param` | per-operation | no | fresh default — correct; `med_idx`/`cap_dev` sentinels are resolved by pjsua |

The sweep also named two `acc_config` fields our own audit missed — `allow_via_rewrite`, and
`proxy_cnt`/`proxy` — which a rebuild would have wiped once TD-16 adds outbound proxies. Another
reason D-CONFIG-4 had to be fixed before, not after, that feature.

Reviews archived in `VoIP/deepwiki-store/` (pre-implementation `…_b5a757a3`, post-implementation
follow-up on the same thread, misuse sweep `…_bb8d7a19`).

## 7. Sequencing

1. Layer A + `addAccount(_:credentials:)` — version-independent, lands now (break the old
   signature freely; repo policy permits).
2. Fold in consult findings; add TD-16/TD-18/TD-14 fields.
3. App: Keychain behind its own `CredentialStore` conformance.
4. After the PJSIP bump: `on_auth_challenge` for the stronger secrecy posture.
