## test_native_host_replay_server.nim — the TUI/GPUI host finds the
## `replay-server` the build produced, through the shared search order.
##
## `host/native_host.findReplayServer` is the product entry point both native
## front-ends call before spawning an engine. It used to carry a private list —
## `REPLAY_SERVER_BIN`, `src/build-debug/bin`, cargo's two trees — that did not
## know the Repro build's output root, so on a checkout built through `repro`
## it picked a stale cargo engine and the window hung on a DAP read forever
## (codetracer-pm
## `issues/2026-09-29-replay-server-discovery-misses-the-repro-build-output-root.md`).
## `src/common/replay_server_path_test.nim` pins the ORDER on fake checkouts;
## this suite pins that the product really uses it.
##
## The build's published output root (`CT_BUILD_OUT_ROOT`) is pointed at a
## scratch directory holding a stub engine, so the case does not depend on what
## this checkout happens to have built, and it fails on the old list for the
## issue's own reason: that list never consulted where the build said its
## output went. No mocks; the stub is a real file and the environment is the
## real process environment, saved and restored around every case.

import std/[os, unittest]

import ../host/native_host
import ../../../common/replay_server_path

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 3

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const OrderEnv = [ReplayServerBinEnv, BuildOutRootEnv, BuildDirEnv,
                  BuildConfigEnv]

type SavedEnv = seq[(string, bool, string)]

proc saveAndClearEnv(): SavedEnv =
  for name in OrderEnv:
    result.add((name, existsEnv(name), getEnv(name)))
    delEnv(name)

proc restoreEnv(saved: SavedEnv) =
  for (name, present, value) in saved:
    if present: putEnv(name, value) else: delEnv(name)

proc scratchOutRoot(tag: string): string =
  ## An output tree outside the checkout with a stub engine in its `bin/`.
  result = getTempDir() / ("ct_native_host_rs_" & tag & "_" &
                           $getCurrentProcessId())
  removeDir(result)
  createDir(result / "bin")
  writeFile(result / "bin" / ReplayServerExe, "#!/bin/sh\nexit 0\n")

suite "native_host.findReplayServer uses the build's output root":
  var saved: SavedEnv
  setup:
    saved = saveAndClearEnv()
  teardown:
    restoreEnv(saved)

  test "CT_BUILD_OUT_ROOT's engine is the one the host spawns":
    let outRoot = scratchOutRoot("out_root")
    defer: removeDir(outRoot)
    putEnv(BuildOutRootEnv, outRoot)
    ck findReplayServer() == outRoot / "bin" / ReplayServerExe

  test "CODETRACER_BUILD_DIR's engine is found too":
    let buildDir = scratchOutRoot("build_dir")
    defer: removeDir(buildDir)
    putEnv(BuildDirEnv, buildDir)
    ck findReplayServer() == buildDir / "bin" / ReplayServerExe

  test "the host and the suites agree on this checkout":
    # Whatever this checkout has built — possibly nothing, then both are "" —
    # the product and the shared helper must name the same binary.
    ck findReplayServer() == locateReplayServer()

suite "assertion tally":
  test "every assertion ran":
    check countedAssertions == ExpectedAssertions
