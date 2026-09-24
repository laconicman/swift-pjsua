---
area: ci
kind: bug
status: filed
tracker:
  issue: google/oss-fuzz#15956
---

# CIFuzz builds the wrong code on forks

**Status: investigated 2026-08-05. Fork *support* is declined upstream and not worth re-arguing;
the narrow "don't report green" half is filed as
[google/oss-fuzz#15956](https://github.com/google/oss-fuzz/issues/15956).**

The first draft here was a full bug report. It was retired after the prior-art search below —
this is long known, and re-reporting it would have added nothing. What is *not* settled is the
silent-success behaviour, which the CIFuzz maintainer explicitly left open ("I may consider
failing more loudly"), so that is what #15956 asks for, with the fork-support wish registered as
opinion rather than argued.

Kept because the mechanism is worth having written down — it cost real time on the 439 fix, and
the red Fuzzing checks on `laconicman/pjproject` PRs will keep appearing.

---

## What we hit

On the fork's PR #5 (the 439 fix), the three `Fuzzing (address|memory|undefined)` checks failed
while all 25 other checks passed. The build died compiling `pjmedia/src/pjmedia/cb_port.c` with
`error: redefinition of 'cb_port'`, plus `pjsua2/persistent.hpp: ISO C++17 does not allow
dynamic exception specifications`.

`cb_port.c` exists in **neither** the fork's branch nor current upstream `master`. It exists in
upstream's `refs/pull/5/merge` — a pull request from **September 2018** (`307b5ad70`). CIFuzz
built that 2018 tree with a 2026 clang.

Results tracked whether the PR *number* exists upstream, not the content of our PRs:

| Fork PR | `refs/pull/N/merge` upstream | `Can not check out` logged | Result |
|---|---|---|---|
| #4 | absent | yes | **success** (built upstream default branch) |
| #6 | absent | yes | **success** (built upstream default branch) |
| #5 | **present** (2018 PR) | no | **failure** (built the 2018 PR) |

PRs #4 and #6 were controls (docs-only and comment-only). Both reported green while never
building the branch — so a green CIFuzz check on this fork means nothing at all.

**Two distinct paths, and only one is silent.** Where the ref is absent, `Can not check out` is
logged and the check goes green. Where it collides (#5), the checkout *succeeds* — no error line
at all — and the run fails **loudly but misattributed**: `cb_port.c:215: redefinition of
'cb_port'`, a pjmedia compile error on a branch that touched two files under `pjsip/`, with
nothing anywhere naming forks or refs. Do not read "CIFuzz failed" as "CIFuzz noticed". It never
notices; it either asserts a success it did not earn or a failure that belongs to someone else.

## Mechanism

1. `projects/pjsip/Dockerfile` — `RUN git clone https://github.com/pjsip/pjproject pjsip`. The
   image's clone is **upstream**, and its `origin` is upstream.
2. `infra/cifuzz/platform_config/github.py`, `pr_ref` — the ref is built from the PR **number
   alone**, with no repository qualification:
   ```python
   pr_ref = f'refs/pull/{self._event_data["pull_request"]["number"]}/merge'
   ```
   Its docstring states the assumption outright: *"the repo on the builder image is a clone from
   main/master."*
3. `infra/cifuzz/continuous_integration.py`, `InternalGithub.prepare_for_fuzzer_build()` —
   copies that upstream clone out of the image, then checks the PR ref into it.
4. `infra/repo_manager.py`, `checkout_pr()` — `git fetch origin <pr_ref>`, i.e. against upstream.
5. `continuous_integration.py`, `checkout_specified_commit()` — on failure, logs
   `Can not check out requested state ... Using current repo state` and **continues**, so the
   build proceeds on upstream's default branch and is reported green.

A bare PR number is meaningless without the repository it belongs to. That is the whole bug.

`is_internal` is just `bool(oss_fuzz_project_name)`, so `InternalGithub` is the intended path for
"OSS-Fuzz project on GitHub Actions" — our configuration is not wrong. We configured nothing at
all: `.github/workflows/cifuzz.yml` is **byte-identical to upstream's** and runs
`on: [pull_request]`. Every fork of every CIFuzz-using OSS-Fuzz project inherits this.

## Why we did not file

Already reported, at least three times, all closed:

- [#3731](https://github.com/google/oss-fuzz/issues/3731) — *"[CIFuzz]: CIFuzz seems to be
  incompatible with forks"* (2020-04, closed 2022-12). Same `git fetch origin refs/pull/N/merge`
  failure. In the comments, **ailin-nemui (2021-08)** reports our exact collision case: *"If I
  open PR 1 on my fork, it instead builds PR 1 of the original repo."* **hartwork (2023-06)**
  flags the silent variant: *"Especially when it doesn't fail and just fuzzes the wrong code."*
- [#10472](https://github.com/google/oss-fuzz/issues/10472) — *"CIFuzz action is fuzzing the
  wrong code for topic branch pushes (sibling of #3731)"* (closed 2023-06).
- [#7479](https://github.com/google/oss-fuzz/issues/7479) — *"How do I test different code
  branches using CIFuzz?"* (closed 2022-04), from the libjpeg-turbo maintainer.

The established answer is that CIFuzz builds the project's canonical repo and cannot fuzz
arbitrary forks or branches; **ClusterFuzzLite** is the tool for that. libjpeg-turbo's response
was to [remove CIFuzz entirely](https://github.com/libjpeg-turbo/libjpeg-turbo/commit/5c8cac97c0c130f287e67d9dafc3e4928110f478):
*"there was a misunderstanding regarding how CIFuzz works. It cannot be used to fuzz arbitrary
PRs or code branches."*

One thing did change since #3731 and is arguably a regression: in 2020 the failed checkout
**errored the build** (`Error building fuzzers for project systemd`). Today it logs and reports
**success**. But hartwork already named that in 2023 and it did not move the issue, so it is not
new leverage.

### It is declined, not forgotten

There is a `TODO(metzman)` on the adjacent `git_url` property — *"maybe make OSS-Fuzz GitHub use
this too for: 1. Consistency 2. Maybe it will allow use on forks"* — which reads like an
unfinished intention worth nudging. It is not. Checking who closed what:

- **#3731** is labelled **`bug, wontfix`**, closed by maintainer `oliverchang`. Acknowledged as
  a bug and explicitly declined.
- **#10472** and **#7479** were both closed by **`jonathanmetzman`** — the author of that TODO.

His verdict on #10472 (2023-06-07), answering precisely this ask:

> *"I think CIFuzz supports the important usecases well enough. I'm sorry you don't agree. … I
> may consider failing more loudly when CIFuzz is run against forks, but it's hard enough to get
> this working that the added complexity of fuzzing forks doesn't seem worth it to me."*

`hartwork` then argued at length that an action mishandling forks and push events "is not a
well-behaved GitHub action" and got no further. The only door left ajar is the narrow *fail
loudly on forks* change, which metzman floated himself — but he floated it while declining, and
nothing has moved in three years.

## What this means for us

- **Ignore the three Fuzzing checks on fork PRs.** They are not required checks, and green or
  red, they carry no information about our branch.
- Don't add a `if: github.repository == 'pjsip/pjproject'` guard to the workflow — it would
  diff against upstream and leak into any PR we send them. If the noise becomes annoying,
  disable Actions for the fork in **Settings → Actions**, which leaves no diff.
- If we ever genuinely want fuzzing on our own branches, that is ClusterFuzzLite, not CIFuzz.

## Verification notes

Mechanism confirmed by reading `continuous_integration.py`, `repo_manager.py`,
`config_utils.py` and `platform_config/github.py` directly, and ref existence by
`git ls-remote https://github.com/pjsip/pjproject 'refs/pull/{4,5,6}/*'`. Reproduced on one
project only (pjsip), though the code path is project-independent.

A DeepWiki deep review of `google/oss-fuzz` confirmed the mechanism with citations and correctly
insisted the prior-art search was the outstanding gap — that search is what closed this out. Note
its wiki index was 176 days / 586 commits stale, so its own "found nothing" was worth little.
