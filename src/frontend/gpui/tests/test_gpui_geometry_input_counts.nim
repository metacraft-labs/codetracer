## test_gpui_geometry_input_counts.nim — the window's geometry report counts
## key events apart from pointer events (`input.keys` beside `input.handled`).
##
## A capture that sends a key waits until the window has handled it. Counted
## together with pointer events, a lost key was indistinguishable from a
## pointer event the compositor delivered late: under load the plat47 capture
## read a lost Esc as handled, never sent it again, and the drag it should have
## ended stayed active (`ci/test/plat47_gpui_window.py`, `key_handled`).
## `input.keys` moves for a key and only for a key.
##
## Read off the SHIPPED binary's window plan (`codetracer-gpui
## --report-window-plan --window-ops=…`: the window's own pointer and key
## handlers) over the `calc` recording, and the geometry file it writes.
##
## Run (needs `just build-gpui`, the Python recorder, which records the `calc`
## fixture on first use, `REPLAY_SERVER_BIN`, isonim-gpui's shim):
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/gpui/tests/test_gpui_geometry_input_counts.nim
##
## No mocks: the shipped binary, the real shim, the real `replay-server`, a
## real recording. A missing prerequisite fails by name.

import replay_prerequisite
import ../../tui/tests/fixtures/fixture_provider
import std/[json, os, osproc, streams, strtabs, tempfiles, unittest]
import ./gpui_child_env

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  StateDirEnvVar = "CODETRACER_TUI_LAYOUT_DIR"
  W = 1920
  H = 1080

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let bin = repo / "build/bin/codetracer-gpui"
let shimDir = getEnv("ISONIM_GPUI_SHIM_DIR",
                   repo.parentDir / "isonim-gpui/rust/target/debug")
let calc = requireFixture(fixtureSpec("calc"))

proc inputAfter(ops: string): JsonNode =
  ## The geometry report's `input` object after `ops`, as the shipped binary
  ## writes it.
  if not fileExists(bin):
    raise newException(IOError, "prerequisite missing: " & bin &
                       " (just build-gpui)")
  let state = createTempDir("gpui-input-counts-", "")
  defer: removeDir(state)
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["LD_LIBRARY_PATH"] = gpuiLibraryPath(shimDir)
  env[StateDirEnvVar] = state
  env["XDG_STATE_HOME"] = state
  env["CODETRACER_HOME"] = state / "ct-home"
  let geomFile = state / "geometry.json"
  env["CODETRACER_GPUI_GEOMETRY_OUT"] = geomFile
  let args = @["--report-window-plan", "--width=" & $W, "--height=" & $H,
               "--window-ops=" & ops, calc]
  let errFile = genTempPath("gpui-input-counts-", ".err")
  let p = startProcess("/bin/sh",
    args = @["-c", gpuiRunScript("2>" & quoteShell(errFile)), bin] & args,
    env = env, options = {})
  discard p.outputStream.readAll()
  let rc = p.waitForExit()
  p.close()
  let err = if fileExists(errFile): readFile(errFile) else: ""
  removeFile(errFile)
  if rc != 0:
    checkpoint("codetracer-gpui " & gpuiExitText(rc) & ": " & err)
    raise newException(IOError, "the window plan run failed (" & ops & ")")
  if not fileExists(geomFile):
    raise newException(IOError, "the window wrote no geometry report (" &
                       ops & ")")
  parseFile(geomFile){"input"}

proc count(input: JsonNode; name: string): int =
  if input.isNil or input.kind != JObject or not input.hasKey(name): -1
  else: input[name].getInt(-1)

suite "the geometry report counts keys apart from pointer events":

  test "a pointer event moves input.handled and not input.keys":
    let input = inputAfter("move:600:400")
    checkpoint($input)
    ck input.count("handled") == 1
    ck input.count("keys") == 0

  test "a key event moves both":
    let input = inputAfter("key:escape")
    checkpoint($input)
    ck input.count("handled") == 1
    ck input.count("keys") == 1

  test "pointer events around a key leave input.keys at the keys sent":
    let input = inputAfter("move:600:400,key:escape,move:610:400,move:620:400")
    checkpoint($input)
    ck input.count("handled") == 4
    ck input.count("keys") == 1

  test "CHECKS":
    echo "CHECKS: ", CHECKS
    check CHECKS == 6
