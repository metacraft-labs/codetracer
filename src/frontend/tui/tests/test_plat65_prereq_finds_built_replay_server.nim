## test_plat65_prereq_finds_built_replay_server.nim — PLAT-65's prerequisite
## check finds the `replay-server` the build produced, the way the product
## does, instead of demanding `$REPLAY_SERVER_BIN`.
##
## `fixtures/plat65_nim_project.missingPrereq` decides whether the PLAT-65
## suites (the terminal one in `real_terminal/` and its GPUI twin) run or
## report `MISSING-PREREQ SKIP:`. It used to accept a `replay-server` ONLY
## through `$REPLAY_SERVER_BIN`, so in the `tui-tests` CI job — which builds
## the engine with `just build-once` into `src/build-debug/bin/` and sets no
## such variable — the terminal suite skipped every case and the lane, which
## fails an all-skipped file, went red (codetracer-pm
## `issues/2026-11-09-tui-job-runs-plat60-and-plat65-without-their-prerequisites.md`).
## The spawned terminal never needed the variable: it resolves its engine
## through `host/native_host.findReplayServer`, i.e. through
## `src/common/replay_server_path`. The prerequisite check has to ask the same
## question, or it skips a suite whose product would have run.
##
## The build's published output root (`CT_BUILD_OUT_ROOT`) is pointed at a
## scratch tree outside the checkout holding a stub engine, so the first case
## fails on the old check for the issue's own reason — no `$REPLAY_SERVER_BIN`,
## an engine where the build put it, and "replay-server (REPLAY_SERVER_BIN)"
## reported missing — and does not depend on what this checkout has built.
## The second case pins that the explicit override still satisfies the check.
##
## No mocks: the stub is a real file, the environment is the real process
## environment (saved and restored around every case), and the function under
## test is the fixture's own `missingPrereq`. The stub is never executed, which
## is why `CODETRACER_REQUIRE_REPLAY_REVISION` (the opt-in revision handshake
## `locateReplayServer` would run against it) is cleared for the cases.
##
## Lane: `tui` (Tier 1). It imports the PLAT-65 fixture only, never
## `fixtures/native_recording`, so it needs no rr and stays out of the
## `tui-native` lane.

import std/[os, strutils, unittest]

import ./fixtures/plat65_nim_project
import ../../../common/replay_server_path

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 3

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  RevisionEnv = "CODETRACER_REQUIRE_REPLAY_REVISION"
    ## `locateReplayServer`'s opt-in handshake; a stub cannot answer it.
  SearchEnv = [ReplayServerBinEnv, BuildOutRootEnv, BuildDirEnv,
               BuildConfigEnv, RevisionEnv]
    ## Every variable that changes which engine the search finds.

type SavedEnv = seq[(string, bool, string)]

proc saveAndClearEnv(): SavedEnv =
  for name in SearchEnv:
    result.add((name, existsEnv(name), getEnv(name)))
    delEnv(name)

proc restoreEnv(saved: SavedEnv) =
  for (name, present, value) in saved:
    if present: putEnv(name, value) else: delEnv(name)

proc scratchOutRoot(tag: string): string =
  ## An output tree outside the checkout — ABSOLUTE, so the search takes it as
  ## given rather than anchoring it to the checkout — with a stub engine in
  ## its `bin/`, where `scripts/build-once.sh` puts the real one.
  result = getTempDir() / ("ct_plat65_prereq_" & tag & "_" &
                           $getCurrentProcessId())
  removeDir(result)
  createDir(result / "bin")
  writeFile(result / "bin" / ReplayServerExe, "#!/bin/sh\nexit 0\n")

proc reportsReplayServer(missing: string): bool =
  ## Whether `missingPrereq`'s answer names the engine as missing. Matched on
  ## the binary's name, which every spelling of that diagnostic carries.
  missing.toLowerAscii.contains("replay-server")

suite "plat65_nim_project.missingPrereq finds replay-server as the product does":
  var saved: SavedEnv
  setup:
    saved = saveAndClearEnv()
  teardown:
    restoreEnv(saved)

  test "an engine in the build's output root satisfies it with REPLAY_SERVER_BIN unset":
    let outRoot = scratchOutRoot("out_root")
    defer: removeDir(outRoot)
    putEnv(BuildOutRootEnv, outRoot)
    # Precondition, so a pass below means the check agreed with the search
    # and not that the search found nothing to agree with.
    ck locateReplayServer() == outRoot / "bin" / ReplayServerExe
    let missing = missingPrereq()
    checkpoint "missingPrereq() = " & missing
    ck not reportsReplayServer(missing)

  test "an explicit REPLAY_SERVER_BIN still satisfies it":
    let outRoot = scratchOutRoot("explicit")
    defer: removeDir(outRoot)
    putEnv(ReplayServerBinEnv, outRoot / "bin" / ReplayServerExe)
    let missing = missingPrereq()
    checkpoint "missingPrereq() = " & missing
    ck not reportsReplayServer(missing)

suite "assertion tally":
  test "every assertion ran":
    check countedAssertions == ExpectedAssertions
