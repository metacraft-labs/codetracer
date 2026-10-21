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

import std/[monotimes, os, osproc, streams, strutils, times]
when defined(windows):
  import std/winlean
else:
  import std/posix

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

proc gitOutput(root: string; args: seq[string]): tuple[output: string, code: int] =
  let p = startProcess("git", workingDir = root, args = args,
    options = {poUsePath, poStdErrToStdOut})
  defer: p.close()
  result.output = p.outputStream.readAll()
  result.code = p.waitForExit()

proc isGitHash(value: string): bool =
  if value.len notin [40, 64]: return false
  for ch in value:
    if ch notin {'0'..'9', 'a'..'f'}: return false
  true

proc replaySourceFingerprint*(root: string): string =
  ## Match build.rs's ordered hashes of actual backend/library input bytes.
  ## Hashing contents rather than HEAD accepts a commit with unchanged inputs,
  ## and rejects a stale binary even when both builds name the same dirty HEAD.
  try:
    let listing = gitOutput(root,
      @["ls-files", "-z", "--", "src/db-backend", "src/libs", "libs"])
    if listing.code != 0: return ""
    let files = listing.output.split('\0')
    var args = @["hash-object", "--"]
    for file in files:
      if file.len > 0 and fileExists(root / file): args.add(file)
    if args.len == 2: return ""
    var hashes: seq[string]
    var first = 2
    while first < args.len:
      let last = min(first + 63, args.high)
      let hashed = gitOutput(root, @["hash-object", "--"] & args[first .. last])
      if hashed.code != 0: return ""
      hashes.add(hashed.output.strip().splitLines())
      first = last + 1
    if hashes.len != args.len - 2: return ""
    for hash in hashes:
      if not isGitHash(hash): return ""
    var input = ""
    for i in 2 ..< args.len:
      input.add(args[i] & '\0' & hashes[i - 2] & '\n')
    let p = startProcess("git", workingDir = root,
      args = ["hash-object", "--stdin"], options = {poUsePath})
    defer: p.close()
    p.inputStream.write(input)
    p.inputStream.close()
    result = p.outputStream.readAll().strip()
    if p.waitForExit() != 0 or not isGitHash(result): result = ""
  except OSError, IOError:
    result = ""

proc replayServerRevisionProblem*(bin, root: string; timeoutMs = 3000): string =
  ## Bounded, side-effect-free handshake before a real-stack test starts DAP.
  ## Never fall through to another engine after rejecting an explicit choice.
  try:
    let p = startProcess(bin, args = ["--build-revision"], options = {poStdErrToStdOut})
    defer: p.close()
    # Read the raw pipe without a userspace buffer, with a deadline and size
    # limit. readAll after waitForExit is not bounded: a descendant may still
    # hold stdout open after its parent exited successfully.
    let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
    var answer = ""
    var timedOut = false
    when not defined(windows):
      let fd = cint(p.outputHandle)
      let flags = fcntl(fd, F_GETFL)
      if flags < 0 or fcntl(fd, F_SETFL, flags or O_NONBLOCK) < 0:
        p.kill()
        discard p.waitForExit()
        return "cannot configure revision handshake pipe: " & bin
    while true:
      var buffer: array[512, char]
      var count = 0
      when defined(windows):
        var available, received: int32
        if peekNamedPipe(Handle(p.outputHandle), nil, 0, nil, addr available, nil) and available > 0:
          discard winlean.readFile(Handle(p.outputHandle), addr buffer[0],
            min(available, 512'i32), addr received, nil)
          count = int(received)
      else:
        count = int(posix.read(fd, addr buffer[0], buffer.len))
      if count > 0:
        for i in 0 ..< count: answer.add(buffer[i])
        if answer.len > 512: break
      elif not p.running:
        break
      if getMonoTime() >= deadline:
        timedOut = true
        break
      sleep(5)
    if p.running:
      p.kill()
    let code = p.waitForExit()
    if timedOut:
      return "revision handshake timed out: " & bin
    if answer.len > 512:
      return "revision handshake response too large: " & bin
    answer = answer.strip()
    let fields = answer.splitWhitespace()
    if code != 0 or fields.len != 3 or fields[0] != "codetracer-replay-build-v1" or
        not isGitHash(fields[1]):
      return "revision handshake unsupported: " & bin & " (" & answer & ")"
    let expected = replaySourceFingerprint(root)
    if expected.len == 0 or fields[1] == "unknown" or fields[2] != expected:
      return "stale replay-server: " & bin & " built at " & fields[1] &
        " (source " & fields[2] & "; checkout source " & expected & ")"
  except OSError, IOError:
    return "cannot probe replay-server " & bin & ": " & getCurrentExceptionMsg()

proc locateReplayServer*(): string =
  ## `findReplayServerIn` for this checkout: the call every front-end and
  ## suite makes. "" when `replay-server` has not been built.
  result = findReplayServerIn(codetracerCheckoutRoot())
  if result.len > 0 and getEnv("CODETRACER_REQUIRE_REPLAY_REVISION") == "1":
    let problem = replayServerRevisionProblem(result, codetracerCheckoutRoot())
    if problem.len > 0:
      stderr.writeLine("prerequisite missing: " & problem &
        "; rebuild with `just build-once` or `cd src/db-backend && cargo build`")
      result = ""

proc missingReplayServerMessage*(root = codetracerCheckoutRoot()): string =
  ## The standard diagnostic for a `replay-server` that could not be found,
  ## naming every path searched so the reader can see which tree is missing
  ## rather than guess from a remedy.
  let searched = replayServerCandidates(root)
  "missing replay-server; set " & ReplayServerBinEnv & ", or build it " &
    "(`just build-once`, or `cd src/db-backend && cargo build`). Searched: " &
    (if searched.len == 0: "(nothing: no checkout and no override)"
     else: searched.join(", "))
