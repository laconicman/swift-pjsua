# PR draft — configurable other-audio ducking for the CoreAudio VPIO unit

For `pjsip/pjproject`. **Enhancement**, not a bug fix — no local workaround in swift-pjsua is
being retired; this is a behaviour improvement every VoIP app on the backend inherits.

**Status: MERGED ✅** — issue [#5177](https://github.com/pjsip/pjproject/issues/5177) → PR
[#5178](https://github.com/pjsip/pjproject/pull/5178), filed 2026-08-11, merged **2026-08-17** as
`65a7e0cba` on `pjsip/pjproject` master. Merged verbatim: our commit `0c2439368` went in unchanged,
91 insertions across three files, no maintainer edits. Full CI green (macOS, Linux, Windows,
CodeQL, CIFuzz); the one non-green check was a Bitrise `DEN (timeout)` infra abort, unrelated.

Third contribution from this fork to land upstream, after
[#5070](pjproject-5070-acc-table-full-asserts-in-debug.md) and
[#5076](pjproject-5076-warn-oversized-udp-fallback.md) — and the first that is an **enhancement**
rather than a defect report.

### Review round 1 — sauwming, 2026-08-12 · *applied*

Maintainer's verdict: "the PR is welcome", with two asks, both taken
([comment](https://github.com/pjsip/pjproject/pull/5178#issuecomment-5266061679) →
[reply](https://github.com/pjsip/pjproject/pull/5178#issuecomment-5313437235)).

1. **Default → `0`.** He prefers existing behaviour unchanged, and offered instead to enable it
   in `config_site_sample.h` under `PJ_CONFIG_IPHONE`. Done both ways.
   **Consequence for us:** `PJ_CONFIG_IPHONE` is iOS-only, so **macOS gets nothing** — macOS
   enables the backend through `aconfigure`'s `*darwin*` branch, not through
   `config_site_sample.h`, so there is no equivalent hook. We asked whether that was intended;
   sauwming's answer (2026-08-17): *"I suppose we can leave MacOS as it is right now."* So it is a
   **deliberate upstream decision**, not an oversight — macOS keeps the fixed whole-call duck by
   default forever, and `swift-pjsip` must set
   `PJMEDIA_AUDIO_DEV_COREAUDIO_ADVANCED_DUCKING 1` in its own `scripts/config_site.h` for any
   macOS slice. (We do that for every slice anyway rather than inheriting upstream defaults —
   `swift-pjsip/docs/ARCHITECTURE.md` §11.)
2. **`&& !TARGET_OS_TV && !TARGET_OS_WATCH` on the guard.** Done — and it turned out to be
   load-bearing, not defensive: a tvOS build of the previous commit fails with
   `'kAUVoiceIOProperty_OtherAudioDuckingConfiguration' is unavailable: not available on tvOS`.
   watchOS is moot (no `AudioUnit/AudioUnit.h` at all) but kept for symmetry.

**Open thread, carried:** the reply argued that flipping the default later is API- and ABI-neutral
(compile-time macro; no struct layout, enum member, or symbol change) and proposed revisiting it
at a **major** release, where semver already signals behavioural change. Recorded as "right for
the upcoming minor, not settled forever" — deliberately not conceded indefinitely. sauwming did
not push back on it and merged as-is, so the position stands on the record without being agreed.
**Revisit when pjproject next plans a major.**

Written from Apple's own sources only — `AudioToolbox/AudioUnitProperties.h` (Xcode 26.5 macOS
and iOS SDKs) and WWDC23 session 10235 *What's new in voice processing*. Deliberately **not**
derived from SashaSIP's GPL patch: pjproject is dual-licensed (GPLv2-or-later + Teluu
commercial), so contributed code must be ours to relicense.

---

## Issue — **filed 2026-08-11** as [#5177](https://github.com/pjsip/pjproject/issues/5177)

Awaiting maintainer/Copilot response before the PR is opened. Body as filed:

**Title:** coreaudio: VPIO ducks other audio for the whole call, with no way to configure it

### Summary

The coreaudio backend opens the VoiceProcessingIO (VPIO) audio unit whenever echo cancellation
is enabled. VPIO ducks "other audio" — every audio stream on the system that is not the voice
chat — to improve the intelligibility of the call. pjproject never configures that ducking, so
it gets the system default: a **fixed duck, held for the entire call**.

The user-visible effect: someone listening to music who accepts a call has that music
attenuated from answer to hangup, including the long stretches when nobody is talking. There is
currently no way for an application on this backend to change that, short of turning off echo
cancellation.

### What macOS 14 / iOS 17 added

`kAUVoiceIOProperty_OtherAudioDuckingConfiguration` makes the behaviour configurable through two
independent controls (per WWDC23 session 10235, *What's new in voice processing*):

- `mEnableAdvancedDucking` — the *style* of ducking. When enabled the duck follows the voice
  activity of the local and remote participants: more ducking while someone is talking, less
  when nobody is. Apple compares it to FaceTime SharePlay, where media volume returns between
  utterances. Disabled by default, which is what pjproject gets today.
- `mDuckingLevel` — the *amount* of ducking: `Default`, `Min`, `Mid`, `Max`. `Default` is the
  value Apple tuned for a typical voice chat, and is what pjproject gets today.

`AudioUnitProperties.h` states: "If not set, the default ducking configuration is to disable
advanced ducking, with a ducking level set to `kAUVoiceIOOtherAudioDuckingLevelDefault`."

### Suggested fix

Set the property in `create_audio_unit()` when EC is enabled, driven by two `#ifndef`-guarded
`config.h` macros so downstream projects can override them from `config_site.h` — advanced
ducking on by default (it addresses the actual complaint and is better for any VoIP app), and
the ducking depth left at Apple's default (a far more opinionated axis where deployments
genuinely differ, so the library should not pick a side).

Gating would follow the macOS 14 / iOS 17 pattern already used in
`pjmedia/src/pjmedia-videodev/darwin_dev.m` — an SDK check plus a runtime `@available` — with
the property probed via `AudioUnitGetPropertyInfo` and any failure logged as a warning rather
than treated as an error, so it can never break audio.

I have a patch ready and will open a PR against this issue; happy to make the new behaviour
opt-in instead if you would rather ship it as strictly additive.

---

## PR body (pasteable)

**Title:** pjmedia: make VoiceProcessingIO other-audio ducking configurable on Apple platforms

### Motivation

The coreaudio backend opens the VoiceProcessingIO (VPIO) audio unit whenever echo cancellation
is enabled. VPIO ducks "other audio" — every audio stream on the system that is not the voice
chat — to improve the intelligibility of the call.

With the system defaults that duck is **fixed and held for the entire call**. A user listening
to music who accepts a call has that music attenuated from answer to hangup, even during the
long stretches when nobody is talking.

macOS 14 / iOS 17 added `kAUVoiceIOProperty_OtherAudioDuckingConfiguration`, which exposes two
independent controls over that behaviour:

- `mEnableAdvancedDucking` — the *style* of ducking. When enabled, the duck follows the voice
  activity of the local and remote chat participants: more ducking while someone is talking,
  less when nobody is. Apple compares it to FaceTime SharePlay, where media volume comes back
  up between utterances.
- `mDuckingLevel` — the *amount* of ducking: `Default`, `Min`, `Mid`, `Max`.

pjproject currently sets neither, so it gets Apple's implicit default: advanced ducking off,
level `Default`.

### Change

`create_audio_unit()` sets the property right after the audio unit is instantiated, only when
EC is enabled (i.e. only when the unit actually is VPIO). Gating follows the existing in-tree
style for macOS 14 / iOS 17 API in `pjmedia/src/pjmedia-videodev/darwin_dev.m`: an SDK check
(`__IPHONE_17_0` / `__MAC_14_0`) plus a runtime `if (@available(macOS 14.0, iOS 17.0, *))`.

The property is queried with `AudioUnitGetPropertyInfo` first and skipped unless it is present
and writable. Every failure path logs a `PJ_LOG(4, …)` warning and returns — configuring the
duck must never be able to break audio.

Two `config.h` macros, `#ifndef`-guarded so they can be overridden from `config_site.h`:

| Macro | Default | Effect |
|---|---|---|
| `PJMEDIA_AUDIO_DEV_COREAUDIO_ADVANCED_DUCKING` | `1` | Enable voice-activity-driven ducking |
| `PJMEDIA_AUDIO_DEV_COREAUDIO_DUCKING_LEVEL` | `0` (`kAUVoiceIOOtherAudioDuckingLevelDefault`) | Ducking depth |

No new `pjmedia_aud_dev_cap`: this has no independent runtime axis — it is a refinement of
existing EC/VPIO behaviour, not something an application would toggle per call through
`pjmedia_aud_stream_set_cap()` — and adding one would push `PJMEDIA_AUD_DEV_CAP_MAX` past its
current `16384`.

### Why these defaults

**Advanced ducking on.** The complaint this addresses is precisely "other audio is attenuated
for the whole call". Following voice activity fixes exactly that, and it is the part of the
change that is unambiguously better for any VoIP application.

**Depth left at Apple's default.** Ducking depth is a much more opinionated axis, and real
deployments differ: a dispatch or contact-centre application may want a deep duck for
intelligibility, a consumer softphone a light one. Apple describes `Default` as the tuned value
for a typical voice chat, and it is the level pjproject already gets today. A library should
not pick a side there, so it is exposed as its own macro and left where it is. Keeping the
depth unchanged also holds the behavioural delta to one clearly-motivated axis.

### Three things worth flagging

**1. This changes existing behaviour.** Anyone building against a macOS 14+ / iOS 17+ SDK with
EC enabled gets voice-activity-driven ducking instead of a constant duck. Setting
`PJMEDIA_AUDIO_DEV_COREAUDIO_ADVANCED_DUCKING` to `0` restores the previous behaviour exactly:
with both macros at `0` the property is set to `{advanced off, level Default}`, which
`AudioUnitProperties.h` documents as identical to never setting the property at all — "If not
set, the default ducking configuration is to disable advanced ducking, with a ducking level set
to `kAUVoiceIOOtherAudioDuckingLevelDefault`." Happy to flip the default to opt-in (`0`) if you
would rather ship this as strictly additive.

**2. `mDuckingLevel` is meaningful whether or not advanced ducking is on.** I checked rather
than assumed. WWDC23 session 10235 states the struct "provides controls of two independent
aspects of ducking — the style of ducking, that is `mEnableAdvancedDucking`, and the amount of
ducking, that is `mDuckingLevel`", and that "the two controls can be used independently".
That is why they are two macros and not one enum.

**3. Platform scope.** `kAUVoiceIOProperty_OtherAudioDuckingConfiguration` is declared
`API_AVAILABLE(ios(17.0), macos(14.0)) API_UNAVAILABLE(watchos, tvos)`. That covers every
platform this backend targets — macOS, iOS, and Mac Catalyst, which inherits the iOS
availability — and I verified Catalyst compiles. It does **not** cover tvOS or watchOS, where
the symbol is declared but unavailable and would fail to compile. The guard I used matches the
file's convention that `TARGET_OS_IPHONE` means iOS, which is true for pjproject today (there
is no tvOS or watchOS build support anywhere in the tree). If you would rather harden it
against a future port, `&& !TARGET_OS_TV && !TARGET_OS_WATCH` on the `TARGET_OS_IPHONE` arm is
the one-line change — say the word and I will add it.

### Validation

- `make` in `pjmedia/build` on `aarch64-apple-darwin` — clean, zero warnings, and the new code
  is confirmed present in the built `coreaudio_dev.o`.
- `coreaudio_dev.m` compiles clean (`-Wall -Wextra`, no output) for: macOS at the host
  deployment target and at `-mmacosx-version-min=10.15`; iOS `arm64` at deployment targets 15.0
  and 12.0 — i.e. both the compiled-in and the runtime-`@available`-false paths; Mac Catalyst
  `arm64`; with `PJMEDIA_AUDIO_DEV_COREAUDIO_ADVANCED_DUCKING=0`; with
  `PJMEDIA_AUDIO_DEV_COREAUDIO_DUCKING_LEVEL=kAUVoiceIOOtherAudioDuckingLevelMin` (confirming
  the macro accepts the Apple constants by name from `config_site.h`); and with
  `PJMEDIA_AUDIO_DEV_HAS_COREAUDIO=0`.
- Non-Apple platforms are unaffected: the two new macros are referenced only in
  `coreaudio_dev.m`, and `config.h` gains only integer literals, so it still compiles with no
  Apple headers in scope (verified by compiling `audiodev.c` against it).
- **Not verified: the listening test.** I have not played music, placed a call with EC enabled,
  and confirmed by ear that the music is no longer flattened for the call's duration and that
  echo cancellation still works. That check is human-only and has not been done.

---

## Local notes (not for the PR)

### Where it landed

- `pjmedia/include/pjmedia-audiodev/config.h` — two `#ifndef`-guarded macros after the
  `PJMEDIA_AUDIO_DEV_HAS_COREAUDIO` block, doc comments with an explicit `Default:` line to
  match `PJMEDIA_OBOE_USE_LOWLATENCY` and `PJMEDIA_AUDIO_DEV_SYMB_APS_DETECTS_CODEC`.
- `pjmedia/src/pjmedia-audiodev/coreaudio_dev.m` — a `static` helper guarded by the SDK check
  and annotated `API_AVAILABLE(macos(14.0), ios(17.0))`, plus a five-line call site in
  `create_audio_unit()` after `AudioComponentInstanceNew()`. The helper keeps
  `create_audio_unit()` (already ~340 lines) flat and lets the failure paths early-return; it
  mirrors the `#if COREAUDIO_MAC` / `static create_audio_resample()` shape directly above it.

### Verified against master, not assumed

- No `kAUVoiceIO*` property use, no ducking code, no prior issue anywhere in the tree.
- `strm->param.ec_enabled` is settled before `create_audio_unit()` runs (set via
  `ca_stream_set_cap(PJMEDIA_AUD_DEV_CAP_EC)` in `ca_factory_create_stream()`), and
  `cf->io_comp` is the VPIO component exactly when it is true — so it is the correct condition.
- `AUVoiceIOOtherAudioDuckingLevel` does have a `Mid` member: `Default = 0`, `Min = 10`,
  `Mid = 20`, `Max = 30`.

### Open question before filing

Both prior merged PRs from this fork (#5070, #5076) were preceded by a tracked issue, because
maintainers prefer one even for docs/logging-only changes. This is an enhancement rather than a
defect, so there may be nothing to file an issue *about* — worth deciding before opening the PR.
