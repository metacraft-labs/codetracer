# Preserved-branch triage — 2026-09-02

Six branches were pushed to `origin` purely for preservation during the
browser/cloud campaign and were *believed* to be duplicate landing attempts.
This note records what each one actually contains, established **by content**
— `git cherry` patch-ids plus blob and tree comparison — not by ancestry.

It exists so that a future audit reads a verdict instead of re-doing the
investigation. **Ancestry is not the same as landed:** much of this campaign's
work was rebased or cherry-picked onto a mainline under new SHAs, so a commit
can look unmerged while its content is fully present. Every SHA below was read
from `git rev-parse`.

**None of these branches has been deleted.** The cost of keeping a branch is
zero; the cost of a wrong "safe to delete" is unrecoverable. They are recorded
as *answered*, not as *removed*.

## Superseded — content is on `cloud`, deletion would lose nothing

| Branch | Tip | Verdict |
|---|---|---|
| `land/edit-mode-toolbar` | `365bdcaa57ff417d2f108ba19cdb2633c4c799f7` | superseded |
| `integrate/dev-toolbar` | `9ad0e6116e5aee4c831f188d600ae800ba88d3a5` | superseded |
| `land/step21-required` | `670312f85102e690f9c05667844ea85b5cf464f0` | superseded |
| `fix/asset-cache-immutability` | `60349fe7cbf3e6085dcd16cb5404b6028b3d3250` | superseded |

Evidence, per branch:

- **`land/edit-mode-toolbar`** — `git cherry origin/cloud` reports **both**
  commits (`11d4edef730c1e164e93893279506f8ecdc8663e` and `365bdcaa`) with `-`,
  i.e. already upstream by patch-id; seven of its eleven files are additionally
  byte-identical to `cloud`, and the four that differ are files `cloud` has
  evolved further. The spec half of the same work landed in `codetracer-specs`
  as `8153b9589049c0f160935e804331dc3d3b053277` (branch `latest`).

- **`integrate/dev-toolbar`** — its merge commit `9ad0e611` has an **empty
  combined diff**: the merge introduced nothing that its parents did not
  already carry. It is a landing attempt, not a source of content.

- **`land/step21-required`** — a single `wip:` commit touching only
  `.github/workflows/deploy-web-codetracer.yml`. **All 165 lines it adds are
  present on `cloud`**, checked line by line, including its two distinctive
  markers `EVERY REACHABLE HOST IS REQUIRED` and `OPTIONAL IS A PROPERTY OF
  RESOLUTION, NOT OF IDENTITY`. The file is *not* byte-identical to `cloud`'s
  version — `cloud` has since evolved it further — which is exactly why the
  test is line containment and not blob equality.

- **`fix/asset-cache-immutability`** — `60349fe7`'s patch body is **identical**
  to `8fe3fd631122174523120cc2ffe07522b6e9293c`, which is on `cloud`
  (`fix(ci): verify every host the deployment declares, and prove the set is
  not empty`). Note for accuracy: `60349fe7` is **not** an ancestor of
  `ab4511b496fabbd147e363fdc1dc1f0b92b91d0f` (the content-addressed-assets
  commit landed on 2026-09-02) — the two are independent commits over the same
  files. The content is preserved because `8fe3fd63` landed it, not because
  `ab4511b4` contains it.

## Not duplicates — unique work, now partly landed

| Branch | Tip | Verdict |
|---|---|---|
| `fix/sibling-pin-assert-cloud` | `b515e725eb173fe70e5d3757a67518517f3ac837` | **LANDED on `cloud`** |
| `fix/sibling-pin-assert` | `9f16671142f4cdae1ec4c7b1a5ac9d2f9e13e47e` | **KEEP — `dev` is still unprotected** |

These two were the sole carriers of ~826 lines that existed on no other ref:
`scripts/sibling-pins.sh` and `ci/test/sibling-pins-test.sh`. They are
near-identical twins differing only in workflow wiring; the `-cloud` variant
preserves cloud's isonim pins.

`fix/sibling-pin-assert-cloud` was landed on `cloud` on 2026-09-02. Its
contract suite reports **20 passed, 0 failed**, including eight mutation arms
(a sibling moved off its pin, an absent sibling, a dirty sibling, a non-git
sibling, an emptied sibling list, an unparseable `flake.lock`, a non-SHA
`locked.rev`, a sibling dropped from `flake.nix`).

After that landing, `scripts/sibling-pins.sh` on `cloud` is a strict superset
of the twin's version — a line-level diff shows **0 lines present only in the
twin** — and `ci/test/sibling-pins-test.sh` is byte-identical between them.

**`fix/sibling-pin-assert` must still be kept.** `origin/dev` and `origin/main`
do **not** carry either file, so the branch-tip-instead-of-commit defect
remains open on `dev`. Delete it only once an equivalent guard is on `dev`.

## Why this mattered

Every incident this guard addresses is a build sibling resolved by *tip*
instead of by *commit*:

- a build script silently resolved the Embed SDK from a sibling checkout when
  an env var was unset, so three builds of identical source came out at
  1,434,511 / 1,350,330 / 1,377,289 bytes, and journey verdicts were not
  reproducible between agents;
- pinning one source was not enough — two builds sharing an SDK revision and a
  byte-identical `src/frontend` still differed by 55,850 bytes, because two
  further siblings were on the Nim path;
- an unpinned replay engine produced a phantom origin-classification
  regression that consumed three agents and two confidently wrong diagnoses
  before the engine was suspected.

## First drift verdict, 2026-09-02: the PINS drifted, not the checkouts

The moment the guard was landed it went red on this workstation, for all
three siblings. "Stale pin" and "drifted checkout" are **opposite fixes**, so
this was established from ancestry rather than assumed:

| Sibling | Pin | Relation to the pin | Verdict |
|---|---|---|---|
| `codetracer-native-recorder` | `7e0400b3` (2026-07-06) | pin is an **ancestor** of local HEAD; pin is **1151 commits** behind the sibling's `origin/dev`; both are on `dev` | **pin stale** |
| `codetracer-trace-format` | `392c5559` | pin is **not on `origin/dev` at all** — reachable only from `origin/ci/ref-rot-gate` and `origin/fix/ci-action-refs`, two unmerged feature branches | **pin off-branch** |
| `codetracer-trace-format-nim` | `d7eca441` | pin on `origin/dev`, 7 commits behind | **pin stale** |

`flake.nix` declares all three as `.../dev`. For `codetracer-trace-format`
the lock therefore **contradicts its own declared branch** — that one is a
correctness defect, not staleness.

**Aligning the checkouts to the pins would have been the inverted fix.** It
would have moved the recorder back 1151 commits to July code and parked
`trace-format` on an unmerged feature branch — the exact "pin a workspace to
superseded code" error.

**CI was not red on this.** The deploy lane clones the siblings *at* the pins
and then verifies *at* the pins, so it is self-consistent and passes. The red
is a statement about this workstation's checkouts — i.e. that local builds do
not match CI — which is the reproducibility gap, not an outage.

The bump is prepared on branch **`fix/sibling-pins-bump-2026-09-02`** and is
deliberately **not** on a mainline: it moves the recorder by 1,459 files and
+364,380/−22,976 lines, and nothing was built, because this workspace cannot
build codetracer. The flake re-locks and evaluates and the contract suite is
20/0, but evaluation is not a build. It needs a build window and someone who
can run one. The `trace-format` correction has an independent argument and
does not have to wait for the recorder bump.

Also observed and **not** touched: the local `codetracer-trace-format` checkout
is parked on `feat/managed-upload-derivation` with 3 uncommitted files. That is
someone's live work; a shared checkout is not a thing to reset underneath them.

## Known gap: the toolchain is not pinned

`scripts/sibling-pins.sh` pins three **repositories**. It does not pin the
compilers that read them, and it now says so on every pass. There is a live,
unclosed hypothesis that the Nim compiler is a fourth unpinned input: two
builds that both claimed all three sources at their pins differed by 60,920
bytes, and the two environments were observed running different Nim versions
(`Nim 2.2.4` from `~/.nix-profile/bin/nim` against `nim-unwrapped-2.2.10`).
Pinning the toolchain is separate, unstarted work.

## Relationship to `client/hydrate/build.sh` (blocktracer)

The two mechanisms **compose; they do not duplicate.** They live in different
repositories and pin disjoint sets from different sources:

| | repo | pins | source of truth |
|---|---|---|---|
| `client/hydrate/build.sh` | blocktracer | `CODETRACER_REF`, `ISONIM_REF`, `NIM_EVERYWHERE_REF` | `ci/embed-sdk-pin.env` |
| `scripts/sibling-pins.sh` | codetracer | `codetracer-native-recorder`, `codetracer-trace-format`, `codetracer-trace-format-nim` | `flake.lock` |

blocktracer pins *codetracer* at a commit; codetracer's own guard then makes
that commit determine its three build siblings. Together the chain is fully
determined at the repository level. There is no overlap in the pinned sets, so
neither check makes the other redundant, and removing either reopens one link.
