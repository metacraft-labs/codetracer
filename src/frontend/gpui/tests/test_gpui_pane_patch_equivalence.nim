## The panes patched in place draw what a full rebuild draws.
##
## A replay window no longer rebuilds every pane's tree on every step: a
## pane's new tree is compared with the one on screen, and only the nodes
## that differ are replaced (`patchPane` in main.nim). That is an
## optimisation, so it must not be visible: the same steps, reported with
## `CODETRACER_GPUI_FULL_REDRAW=1` (every pane rebuilt, the behaviour before
## it) and without, give the same window render plan, node for node.
##
## The control: the steps change the plan at all. Two plans that are equal
## because nothing moved would prove nothing about the patch.
##
## Run: `nim c -r src/frontend/gpui/tests/test_gpui_pane_patch_equivalence.nim`
## from the repo root, `build/bin/codetracer-gpui` built (`just build-gpui`).

import ../../tui/tests/fixtures/fixture_provider
import std/[algorithm, exitprocs, json, os, osproc, streams, strtabs, strutils,
            tempfiles, unittest]
import ./gpui_child_env

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  ExpectedAssertions = 6
  StateDirEnvVar = "CODETRACER_TUI_LAYOUT_DIR"
  W = 1600
  H = 1000
  # Steps forward and back, into a call and out of it, and a pane scrolled
  # between them: every pane the stepping run re-renders gets a new view
  # model at least once.
  Steps = "key:n,key:n,key:f11,key:f11,wheel:eventLog:2,wheel:editor:3,key:n,key:p," &
          "click:tab:calltrace,key:n,key:p,key:n,key:n"

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let bin = repo / "build/bin/codetracer-gpui"
let shimDir = getEnv("ISONIM_GPUI_SHIM_DIR",
                   repo.parentDir / "isonim-gpui/rust/target/debug")
let calc = requireFixture(fixtureSpec("calc"))
let ctHome = createTempDir("gpui-patch-equivalence-home-", "")
  ## One CodeTracer home for every run: the plan names files under it (the
  ## tab icons' cache), so a home of its own per run would differ in nothing
  ## but its path.
addExitProc(proc() = removeDir(ctHome))

proc canonical(n: JsonNode) =
  ## An element's listened events are a set, printed in hash order, which
  ## differs from run to run of the same binary: sorted, so two plans compare
  ## by what they hold. (Objects compare regardless of key order.)
  if n.kind == JObject:
    if n.hasKey("event_names") and n["event_names"].kind == JArray:
      var names: seq[string]
      for e in n["event_names"]: names.add e.getStr
      names.sort()
      n["event_names"] = %names
    for _, v in n: canonical(v)
  elif n.kind == JArray:
    for v in n: canonical(v)

proc windowPlan(ops: string; fullRedraw: bool): JsonNode =
  ## The window's render plan after `ops`, as the shipped binary prints it.
  if not fileExists(bin):
    raise newException(IOError, "prerequisite missing: " & bin &
                       " (just build-gpui)")
  let root = createTempDir("gpui-patch-equivalence-", "")
  defer: removeDir(root)
  var env = newStringTable()
  for k, v in envPairs():
    if k != "CODETRACER_GPUI_FULL_REDRAW":
      env[k] = v
  if fullRedraw:
    env["CODETRACER_GPUI_FULL_REDRAW"] = "1"
  env["LD_LIBRARY_PATH"] = gpuiLibraryPath(shimDir)
  env[StateDirEnvVar] = root
  env["XDG_STATE_HOME"] = root / "xdg"
  env["CODETRACER_HOME"] = ctHome
  var args = @["--report-window-plan", "--width=" & $W, "--height=" & $H]
  if ops.len > 0:
    args.add "--window-ops=" & ops
  args.add calc
  let errFile = root / "stderr"
  let p = startProcess("/bin/sh",
    args = @["-c", gpuiRunScript("2>" & quoteShell(errFile)), bin] & args,
    env = env, options = {})
  let output = p.outputStream.readAll()
  let rc = p.waitForExit()
  p.close()
  if rc != 0:
    let err = if fileExists(errFile): readFile(errFile) else: ""
    checkpoint("codetracer-gpui " & gpuiExitText(rc) & ": " & err)
    raise newException(IOError, "the window plan run failed (" & ops & ")")
  result = parseJson(output)
  canonical(result)

suite "GPUI: panes patched in place":

  test "the steps give the same plan as a full rebuild of every pane":
    let patched = windowPlan(Steps, fullRedraw = false)
    let rebuilt = windowPlan(Steps, fullRedraw = true)
    ck patched.len > 0
    ck patched == rebuilt
    if patched != rebuilt:
      # Where they part, for the reader.
      let a = patched.pretty
      let b = rebuilt.pretty
      var i = 0
      while i < min(a.len, b.len) and a[i] == b[i]:
        inc i
      checkpoint("first difference at " & $i & ": patched …" &
                 a[max(0, i - 300) ..< min(a.len, i + 200)] &
                 "… rebuilt …" & b[max(0, i - 300) ..< min(b.len, i + 200)] & "…")

  test "control: the steps change the plan":
    let opened = windowPlan("", fullRedraw = false)
    let stepped = windowPlan(Steps, fullRedraw = false)
    ck opened.len > 0
    ck stepped != opened
    # And the switch reaches the binary: the opened window is the same
    # either way (nothing has been patched yet).
    ck windowPlan("", fullRedraw = true) == opened

  test "every assertion ran":
    ck CHECKS == ExpectedAssertions
