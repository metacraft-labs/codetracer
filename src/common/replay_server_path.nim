## replay_server_path.nim — THE ONE answer to "which `replay-server` runs".
##
## ## Why this module exists
##
## Every front-end and every headless suite in this repository spawns a
## `replay-server`, and until this module each of them carried its own private
## candidate list. Thirty copies of one list is thirty chances to disagree, and
## they did: the copies were consistent with each other and consistently wrong,
## because none of them named the Repro build's output root
## (`src/build-<buildType>-repro/bin`, `repro.nim`'s `buildDebugRoot`). On a
## checkout built through `repro`, the first candidate that existed was a
## leftover cargo build, so the front-end ran a STALE backend — observed as a
## GPUI window that blocked forever in `read(2)` on the DAP pipe, waiting for a
## `stopped` event the old engine never sent (codetracer-pm
## `issues/2026-09-29-replay-server-discovery-misses-the-repro-build-output-root.md`).
## The one copy that had been repaired then had a different order from the
## product's, which is worse: a suite and the front-end it tests found
## different binaries.
##
## So the order lives here, once. `src/common/` is importable from the
## front-ends and from every test tree, and a caller that wants a different
## failure mode (an `IOError`, a `TuiHostError`, a "" for "not built") wraps
## `findReplayServerIn` rather than restating the list. The two places that
## cannot import Nim — the `justfile`'s "is replay-server built?" guard and
## `src/frontend/gpui/tests/run-plat22-mutations.py` — spell the same order
## and say that this module is the authority.
##
## ## The order, and why it is this order
##
## 1. `$REPLAY_SERVER_BIN` — an explicit choice always wins.
## 2. `$CT_BUILD_OUT_ROOT/bin` — the output tree `scripts/build-once.sh`
##    resolved and published. That script owns the config -> variant -> output
##    root derivation precisely so callers stop re-deriving it; when the answer
##    is in hand, using it beats guessing. Relative to the checkout root (the
##    script's contract), absolute accepted.
## 3. `$CODETRACER_BUILD_DIR/bin` — the variable `ci/lib/build-freshness.sh`
##    and the `ci/test` shell lanes use for the same tree (the dev shell
##    exports it as an absolute path). Relative paths are taken against the
##    checkout root, which is where those lanes run.
## 4. `src/build-<buildType>-repro/bin`, then `src/build-<buildType>/bin` — the
##    Repro output root, then tup's variant directory (still real on hosts
##    that drive tup). `<buildType>` is `$CODETRACER_CONFIG`, default `debug`,
##    derived exactly as `scripts/build-once.sh` derives it for both branches.
## 5. `src/db-backend/target/debug`, then `target/release` — cargo's own
##    output, LAST: it is what a developer's ad-hoc `cargo build` leaves
##    behind, and it is the tree most likely to be days older than the build
##    the rest of the checkout came from.
##
## Every candidate is tested for the BINARY, never for its directory:
## `src/build-debug/` is tracked in git holding only `tup.config`, so "the
## directory exists" is true on every checkout and answers the wrong question.

import std/[os, strutils]

const
  ReplayServerBinEnv* = "REPLAY_SERVER_BIN"
    ## Explicit override: the path of the `replay-server` to run.
  BuildOutRootEnv* = "CT_BUILD_OUT_ROOT"
    ## `scripts/build-once.sh`'s published output tree (holds `bin/`).
  BuildDirEnv* = "CODETRACER_BUILD_DIR"
    ## The CI/dev-shell name for the same output tree (holds `bin/`).
  BuildConfigEnv* = "CODETRACER_CONFIG"
    ## `debug` | `release`; selects `src/build-<config>[-repro]`.
  ReplayServerExe* = "replay-server".addFileExt(ExeExt)
    ## The file name, with `.exe` on Windows — cargo and the Repro build both
    ## emit it with the platform suffix, so a bare name never matches there.

proc replayServerBuildType*(): string =
  ## The build configuration whose output trees are searched:
  ## `$CODETRACER_CONFIG`, or `debug` when it is unset or empty — the same
  ## `${CODETRACER_CONFIG:-debug}` both branches of `scripts/build-once.sh`
  ## use, so the tree searched here is the tree that script wrote.
  result = getEnv(BuildConfigEnv, "")
  if result.len == 0:
    result = "debug"

proc anchored(root, path: string): string =
  ## `path` as an absolute candidate: itself when absolute, joined to `root`
  ## when relative, and "" when relative with no checkout to anchor it — a
  ## relative output root resolved against the process's cwd would name a
  ## tree nobody built.
  if path.isAbsolute:
    path
  elif root.len > 0:
    root / path
  else:
    ""

proc replayServerCandidates*(root: string): seq[string] =
  ## Every place `replay-server` may be, in the order it is preferred, for the
  ## checkout at `root` and the current process environment. Pure apart from
  ## the environment reads: nothing here touches the filesystem, so a test can
  ## assert the ORDER without building anything, and a diagnostic can list
  ## exactly what was searched.
  ##
  ## `root` may be "" (a binary running away from the checkout it was built
  ## in); then only the absolute environment-supplied candidates remain.
  ## Duplicates are dropped, keeping the earlier position — e.g.
  ## `CT_BUILD_OUT_ROOT=src/build-debug-repro` names the tree step 4 would
  ## search anyway.
  proc addOnce(acc: var seq[string]; path: string) =
    if path.len > 0 and path notin acc:
      acc.add(path)

  # Taken as given, not anchored: an override is a path the user typed, and
  # it has always been resolved against the cwd it was typed in.
  result.addOnce(getEnv(ReplayServerBinEnv, ""))
  for envName in [BuildOutRootEnv, BuildDirEnv]:
    let tree = getEnv(envName, "")
    if tree.len > 0:
      let anchoredTree = anchored(root, tree)
      if anchoredTree.len > 0:
        result.addOnce(anchoredTree / "bin" / ReplayServerExe)
  if root.len > 0:
    let buildType = replayServerBuildType()
    result.addOnce(root / "src" / ("build-" & buildType & "-repro") / "bin" /
               ReplayServerExe)
    result.addOnce(root / "src" / ("build-" & buildType) / "bin" / ReplayServerExe)
    for profile in ["debug", "release"]:
      result.addOnce(root / "src" / "db-backend" / "target" / profile /
                 ReplayServerExe)

proc findReplayServerIn*(root: string): string =
  ## The first of `replayServerCandidates(root)` that exists as a file, or ""
  ## when none does. "" rather than an exception so each caller keeps its own
  ## failure contract: the TUI host reports a remedy, a fixture provider
  ## counts a prerequisite, a headless suite raises with
  ## `missingReplayServerMessage`.
  for candidate in replayServerCandidates(root):
    if fileExists(candidate):
      return candidate
  ""

proc codetracerCheckoutRoot*(): string =
  ## The checkout this module was compiled from, found by walking up from its
  ## source file to the first directory holding both `src/db-backend` and a
  ## `justfile` (the markers every `repoRoot` in the test trees uses), or ""
  ## when there is none — a binary copied away from its checkout.
  ##
  ## `currentSourcePath` rather than `getAppDir`: test binaries live in a
  ## nimcache directory nowhere near the checkout, so resolving relative to
  ## the executable would find nothing.
  var dir = currentSourcePath().parentDir
  while true:
    if dirExists(dir / "src" / "db-backend") and fileExists(dir / "justfile"):
      return dir
    let parent = dir.parentDir
    if parent == dir or parent.len == 0:
      return ""
    dir = parent

proc locateReplayServer*(): string =
  ## `findReplayServerIn` for this checkout: the call every front-end and
  ## suite makes. "" when `replay-server` has not been built.
  findReplayServerIn(codetracerCheckoutRoot())

proc missingReplayServerMessage*(root = codetracerCheckoutRoot()): string =
  ## The standard diagnostic for a `replay-server` that could not be found,
  ## naming every path searched so the reader can see which tree is missing
  ## rather than guess from a remedy.
  let searched = replayServerCandidates(root)
  "missing replay-server; set " & ReplayServerBinEnv & ", or build it " &
    "(`just build-once`, or `cd src/db-backend && cargo build`). Searched: " &
    (if searched.len == 0: "(nothing: no checkout and no override)"
     else: searched.join(", "))
