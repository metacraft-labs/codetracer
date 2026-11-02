## replay_server_path_test.nim — the `replay-server` search order, and the
## guard that keeps it in one place.
##
## Each case builds a FAKE checkout in a scratch directory — the two marker
## entries plus stub `replay-server` files in exactly the trees the case is
## about — and asks `findReplayServerIn` which one wins. No mocks: the module
## under test reads the real process environment and the real filesystem, and
## the fixtures are real files on it. The environment variables the order
## depends on are saved before every case and restored after it, so a
## developer's dev shell (which exports `CODETRACER_BUILD_DIR`) cannot decide a
## case, and no case leaks into the next.
##
## The first case is the issue's scenario verbatim (codetracer-pm
## `issues/2026-09-29-replay-server-discovery-misses-the-repro-build-output-root.md`):
## a Repro-built engine and a stale cargo one side by side, and a `src/build-debug/`
## holding only `tup.config`.
##
## The last suite is the regression guard: no Nim source under `src/` other
## than this module may build a `replay-server` candidate path of its own,
## because thirty private copies of the list are how the order diverged.

import std/[os, strutils, unittest]

import replay_server_path

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 23

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

proc stub(path: string) =
  ## A file where a `replay-server` would be. Its contents are irrelevant —
  ## discovery tests for the file, it never runs it.
  createDir(path.parentDir)
  writeFile(path, "#!/bin/sh\nexit 0\n")

proc fakeCheckout(name: string): string =
  ## A directory the module would accept as a checkout root.
  result = getTempDir() / ("ct_replay_server_path_" & name & "_" &
                           $getCurrentProcessId())
  removeDir(result)
  createDir(result / "src" / "db-backend")
  writeFile(result / "justfile", "")

proc server(root: varargs[string]): string =
  ## `<root>/<parts...>/replay-server[.exe]`.
  result = root[0]
  for i in 1 ..< root.len:
    result = result / root[i]
  result = result / ReplayServerExe

suite "replay-server discovery order":
  var saved: SavedEnv
  var root: string

  setup:
    saved = saveAndClearEnv()
    root = ""
  teardown:
    restoreEnv(saved)
    if root.len > 0:
      removeDir(root)

  test "the Repro output root beats a stale cargo build (the issue's case)":
    root = fakeCheckout("repro_vs_cargo")
    # Tracked in git exactly like this: the directory exists, its bin/ does
    # not. Testing for the directory would select a path that is not there.
    createDir(root / "src" / "build-debug")
    writeFile(root / "src" / "build-debug" / "tup.config", "CONFIG_DEBUG=1\n")
    let repro = server(root, "src", "build-debug-repro", "bin")
    let cargo = server(root, "src", "db-backend", "target", "debug")
    stub(repro)
    stub(cargo)
    ck findReplayServerIn(root) == repro

  test "an empty tup tree is skipped in favour of cargo":
    root = fakeCheckout("tup_config_only")
    createDir(root / "src" / "build-debug")
    writeFile(root / "src" / "build-debug" / "tup.config", "CONFIG_DEBUG=1\n")
    let cargo = server(root, "src", "db-backend", "target", "debug")
    stub(cargo)
    ck findReplayServerIn(root) == cargo

  test "the tup tree is searched after the Repro one and before cargo":
    root = fakeCheckout("tup_populated")
    let tup = server(root, "src", "build-debug", "bin")
    stub(tup)
    stub(server(root, "src", "db-backend", "target", "debug"))
    ck findReplayServerIn(root) == tup
    let repro = server(root, "src", "build-debug-repro", "bin")
    stub(repro)
    ck findReplayServerIn(root) == repro

  test "cargo debug before cargo release":
    root = fakeCheckout("cargo_profiles")
    let release = server(root, "src", "db-backend", "target", "release")
    stub(release)
    ck findReplayServerIn(root) == release
    let debug = server(root, "src", "db-backend", "target", "debug")
    stub(debug)
    ck findReplayServerIn(root) == debug

  test "CT_BUILD_OUT_ROOT, relative to the checkout, beats the derived trees":
    root = fakeCheckout("out_root_relative")
    stub(server(root, "src", "build-debug-repro", "bin"))
    let published = server(root, "elsewhere", "out", "bin")
    stub(published)
    putEnv(BuildOutRootEnv, "elsewhere" / "out")
    ck findReplayServerIn(root) == published

  test "CT_BUILD_OUT_ROOT may be absolute":
    root = fakeCheckout("out_root_absolute")
    let outside = getTempDir() / ("ct_replay_server_out_" &
                                  $getCurrentProcessId())
    defer: removeDir(outside)
    let published = server(outside, "bin")
    stub(published)
    stub(server(root, "src", "build-debug-repro", "bin"))
    putEnv(BuildOutRootEnv, outside)
    ck findReplayServerIn(root) == published

  test "CODETRACER_BUILD_DIR comes after CT_BUILD_OUT_ROOT and before the trees":
    root = fakeCheckout("build_dir")
    stub(server(root, "src", "build-debug-repro", "bin"))
    let ciTree = server(root, "ci-tree", "bin")
    stub(ciTree)
    putEnv(BuildDirEnv, root / "ci-tree")
    ck findReplayServerIn(root) == ciTree
    let published = server(root, "published", "bin")
    stub(published)
    putEnv(BuildOutRootEnv, "published")
    ck findReplayServerIn(root) == published

  test "an output root with no binary in it falls through":
    root = fakeCheckout("empty_out_root")
    createDir(root / "empty" / "bin")
    putEnv(BuildOutRootEnv, "empty")
    putEnv(BuildDirEnv, root / "empty")
    let repro = server(root, "src", "build-debug-repro", "bin")
    stub(repro)
    ck findReplayServerIn(root) == repro

  test "REPLAY_SERVER_BIN wins when it names a file, and is ignored when not":
    root = fakeCheckout("override")
    let repro = server(root, "src", "build-debug-repro", "bin")
    stub(repro)
    putEnv(ReplayServerBinEnv, root / "no-such-replay-server")
    ck findReplayServerIn(root) == repro
    let chosen = root / "chosen" / ReplayServerExe
    stub(chosen)
    putEnv(ReplayServerBinEnv, chosen)
    putEnv(BuildOutRootEnv, "src" / "build-debug-repro")
    ck findReplayServerIn(root) == chosen

  test "CODETRACER_CONFIG=release selects the release trees":
    root = fakeCheckout("release")
    stub(server(root, "src", "build-debug-repro", "bin"))
    let release = server(root, "src", "build-release-repro", "bin")
    stub(release)
    putEnv(BuildConfigEnv, "release")
    ck findReplayServerIn(root) == release
    ck replayServerCandidates(root).find(
      server(root, "src", "build-debug-repro", "bin")) < 0

  test "nothing built: \"\", and the diagnostic names what was searched":
    root = fakeCheckout("nothing")
    createDir(root / "src" / "build-debug")
    ck findReplayServerIn(root) == ""
    let message = missingReplayServerMessage(root)
    ck message.contains(server(root, "src", "build-debug-repro", "bin"))
    ck message.contains(server(root, "src", "db-backend", "target", "release"))
    ck message.contains(ReplayServerBinEnv)

  test "no checkout: only absolute overrides remain":
    root = ""
    putEnv(BuildOutRootEnv, "relative-out")
    ck replayServerCandidates("").len == 0
    let outside = getTempDir() / "ct_replay_server_abs_only"
    putEnv(BuildDirEnv, outside)
    ck replayServerCandidates("") == @[outside / "bin" / ReplayServerExe]

suite "the search order is spelled once":
  test "no Nim source outside this module builds a replay-server candidate":
    # Every way a private copy of the list could spell a candidate: a path
    # joined onto the file name (`dir /` the quoted name, also with `.exe` or
    # `.addFileExt`, which is how every one of the thirty copies ended), a
    # string literal that ends in the file name (`"src/build-debug/bin/
    # replay-server"`), and a join onto this module's own `ReplayServerExe`.
    # Built by concatenation so this file does not match itself.
    let q = "\""
    let tails = ["/ " & q & "replay-server",
                 "/replay-" & "server" & q,
                 "/replay-" & "server.exe" & q,
                 "/ " & "ReplayServerExe"]
    # `paths.nim`'s `dbBackendExe` is the INSTALLED layout under the product
    # prefix, not a checkout candidate, so it is the one other legitimate
    # spelling.
    let exempt = ["src" / "common" / "replay_server_path.nim",
                  "src" / "common" / "paths.nim"]
    # The two suites that pin the order build stub engines at the paths the
    # order names, by joining onto `ReplayServerExe`; that is a fixture, not a
    # search, so they are exempt from that one tail only.
    let fixtureJoinExempt = [
      "src" / "common" / "replay_server_path_test.nim",
      "src" / "frontend" / "tui" / "tests" /
        "test_native_host_replay_server.nim"]
    let checkout = codetracerCheckoutRoot()
    var offenders: seq[string]
    var scanned = 0
    var stack = @[checkout / "src"]
    while stack.len > 0:
      let dir = stack.pop()
      for kind, path in walkDir(dir):
        let name = path.extractFilename
        case kind
        of pcDir:
          # Build outputs and vendored trees: large, and not our sources.
          if name in ["target", "node_modules", "nimcache", ".git"] or
              name.startsWith("build-"):
            continue
          stack.add(path)
        of pcFile:
          if not name.endsWith(".nim"):
            continue
          let rel = path.relativePath(checkout)
          if rel in exempt:
            continue
          inc scanned
          let text = readFile(path)
          for i, tail in tails:
            if i == tails.high and rel in fixtureJoinExempt:
              continue
            if tail in text:
              offenders.add(rel)
              break
        else:
          discard
    checkpoint("re-spelled replay-server search: " & offenders.join(", "))
    ck scanned > 100
    ck offenders.len == 0

suite "assertion tally":
  test "every assertion ran":
    check countedAssertions == ExpectedAssertions
