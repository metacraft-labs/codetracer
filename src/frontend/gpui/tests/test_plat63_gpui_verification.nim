## test_plat63_gpui_verification.nim — PLAT-63: **the Verification pane in
## the GPUI window**, read from the window's own render plan and measured
## against the desktop's view of the same run.
##
## Spec: codetracer-pm `spec/Planned-Features/Verification-Payload-
## Contract-v1.md` §5, §7, §9; `milestones/Verno-CodeTracer-Integration.
## milestones.org` VN-M3, VN-M5.
##
## The shipped `codetracer-gpui` (`just build-gpui`) as the Edit window over
## a Noir package, with `--report-window-plan`: `--window-ops` events
## dispatched through the window's own handlers (`verify:*`, aimed where the
## pane was drawn), then the window as a plan.
##
##   * View › Verification (`verify:show`) opens the pane, its Run control
##     naming the package's declared Verno action; `verify:run` presses it
##     and `verify:wait` lets the run settle — the package's own task, run;
##   * THE FINDINGS BY KIND: the heading and each row's kind, title, message
##     and location, equal to the lines the desktop's view draws for the
##     same run (`fixtures/plat63_verno_projects.TypeErrExpectedRows`,
##     asserted equal to the desktop's tree by the terminal's suite);
##   * a PRESS on a finding opens its file at its line and column in the Edit
##     window's editor (K64); a RIGHT PRESS opens the shared menu (K65), whose
##     Go to Source does the same; the keys move the cursor, the pane
##     focused;
##   * THE COUNTEREXAMPLE over the solver run: a press on the offer opens it
##     in the pane — the provenance banner, the steps, the one with no
##     position in words — and a press on the violation opens `src/main.nr`
##     at line 7.
##
## THE ONE STAND-IN (see `tui/tests/fixtures/plat63_verno_projects`): the
## `verno` on the window's PATH replays a recorded real run. The window, its
## host, the runner, the classifier and decoder are the product's.

import std/[json, os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import ../../tui/tests/fixtures/plat63_verno_projects
import ./gpui_child_env

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 29

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  StateDirEnvVar = "CODETRACER_TUI_LAYOUT_DIR"
  W = 1600
  H = 1000
  Run = "verify:show,verify:control:run,verify:wait"

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let bin = repo / "build/bin/codetracer-gpui"
let shimDir = getEnv("ISONIM_GPUI_SHIM_DIR",
                   repo.parentDir / "isonim-gpui/rust/target/debug")

proc windowPlan(run: VernoRun; ops: string;
                trace: var string): JsonNode =
  ## The Edit window over `run.root` after `ops`: its root, and its gesture
  ## trace — the binary run in the package, its own scratch homes, the
  ## replaying `verno` first on its PATH.
  if not fileExists(bin):
    raise newException(IOError, "prerequisite missing: " & bin &
                       " (just build-gpui)")
  let state = createTempDir("plat63-gpui-", "")
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["PATH"] = run.bin & ":" & getEnv("PATH")
  env["LD_LIBRARY_PATH"] = gpuiLibraryPath(shimDir)
  env[StateDirEnvVar] = state
  env["XDG_STATE_HOME"] = state
  env["XDG_DATA_HOME"] = state / "data"
  env["XDG_CONFIG_HOME"] = state / "config"
  env["CODETRACER_HOME"] = state / "ct-home"
  env["CODETRACER_GPUI_GESTURE_TRACE"] = "1"
  createDir(state / "ct-home")
  writeFile(state / "ct-home" / ".codetracer-test-home", "")
  let errFile = genTempPath("plat63-gpui-", ".err")
  let args = @["--report-window-plan", "--width=" & $W, "--height=" & $H,
               "--window-ops=" & ops, "--edit", run.root]
  let p = startProcess("/bin/sh",
    args = @["-c", "exec \"$0\" \"$@\" 2>" & quoteShell(errFile), bin] & args,
    workingDir = run.root, env = env, options = {})
  let output = p.outputStream.readAll()
  let rc = p.waitForExit()
  p.close()
  trace = if fileExists(errFile): readFile(errFile) else: ""
  removeFile(errFile)
  removeDir(state)
  if rc != 0:
    checkpoint("codetracer-gpui exited " & $rc & ": " & trace)
    raise newException(IOError, "the window plan run failed (" & ops & ")")
  parseJson(output)

proc attr(n: JsonNode; name: string): string =
  if n{"attributes"}.kind == JObject: n["attributes"]{name}.getStr else: ""

proc has(n: JsonNode; name: string): bool =
  n{"attributes"}.kind == JObject and n["attributes"].hasKey(name)

proc nodesWith(plan: JsonNode; attribute: string): seq[JsonNode] =
  proc walk(n: JsonNode; acc: var seq[JsonNode]) =
    if n.kind != JObject: return
    if n.has(attribute): acc.add n
    for c in n{"children"}.getElems: walk(c, acc)
  walk(plan, result)

proc child(n: JsonNode; attribute: string): string =
  let hits = n.nodesWith(attribute)
  if hits.len > 0: hits[0].attr(attribute) else: ""

proc linesOf(plan: JsonNode): seq[string] =
  ## The pane's lines in the terminal suite's words: `group <heading>` and
  ## `row <key> <kind> | <title> | <message> @ <location>`.
  for n in plan.nodesWith("data-ct-verification-line"):
    case n.attr("data-ct-verification-line-kind")
    of "vlGroup":
      result.add "group " & n.child("data-ct-verification-text")
    of "vlFinding":
      result.add "row " & n.attr("data-ct-verification-key") & " " &
        n.child("data-ct-verification-kind-label") & " | " &
        n.child("data-ct-verification-title") & " | " &
        n.child("data-ct-verification-message") & " @ " &
        n.attr("data-ct-verification-location")
    else: discard

proc kindsOf(plan: JsonNode): seq[string] =
  for n in plan.nodesWith("data-ct-verification-line"):
    result.add n.attr("data-ct-verification-line-kind")

proc selectedKeys(plan: JsonNode): seq[string] =
  for n in plan.nodesWith("data-ct-verification-line"):
    if n.attr("data-ct-selected") == "true":
      result.add n.attr("data-ct-verification-key")

suite "PLAT-63: the Verification pane in the GPUI window":

  test "a real run: Run, the findings by kind, a press, the menu, the keys":
    let run = writeTypeErrRun()
    defer: run.removeRun()
    var tr = ""
    # Before the run: the Run control names the declared action.
    let before = windowPlan(run, "verify:show", tr)
    let controls = before.nodesWith("data-ct-verification-control")
    ck controls.len == 1
    ck controls.len == 1 and
       controls[0].attr("data-ct-verification-control") == "run"
    let after = windowPlan(run, Run, tr)
    ck tr.contains("verification: verifying: " & VernoCommandLine)
    ck after.nodesWith("data-ct-verification-control").len == 1
    ck tr.contains("verification: failed before reaching the prover")
    let pane = after.nodesWith("data-ct-verification-pane")
    ck pane.len == 1
    ck pane.len == 1 and pane[0].attr("data-ct-verification-pane").startsWith(
         "failed before reaching the prover")
    ck after.nodesWith("data-ct-verification-command").len == 1
    var want = @["group pipeline error (2)"]
    for i, r in TypeErrExpectedRows:
      want.add "row finding:" & $i & " " & r[0] & " | " & r[1] & " | " &
               r[2] & " @ " & r[3]
    ck after.linesOf() == want
    ck after.kindsOf() == @["vlNote", "vlGroup", "vlFinding", "vlFinding"]
    # K64: a press on the second finding opens `src/main.nr` at 1:24.
    let pressed = windowPlan(run, Run & ",verify:line:3", tr)
    ck tr.contains("verification: press finding:1")
    ck tr.contains("verification: opened typeerr/src/main.nr:1:24")
    ck tr.contains("caret 1:24")
    ck pressed.selectedKeys() == @["finding:1"]
    # K65: the right press's menu, the shared entries in order, and Go to
    # Source from it.
    discard windowPlan(run, Run & ",verify:menu:2", tr)
    ck tr.contains("context menu verification-row Go to Source|Copy Message|" &
                   "Copy Location")
    discard windowPlan(run, Run & ",verify:menu:2,verify:choose:Go to Source",
                       tr)
    ck tr.contains("caret 2:20")
    # The keys, the pane focused: End, then Enter opens the last finding.
    let keyed = windowPlan(run, Run & ",verify:key:list.focus-last," &
                           "verify:key:list.activate", tr)
    ck tr.contains("caret 1:24")
    ck keyed.selectedKeys() == @["finding:1"]

  test "the counterexample: the offer opens it; the violation opens its line":
    let run = writeCounterexampleRun()
    defer: run.removeRun()
    var tr = ""
    let listed = windowPlan(run, Run, tr)
    ck listed.kindsOf() == @["vlOffer", "vlOffer", "vlGroup", "vlFinding"]
    let offers = listed.nodesWith("data-ct-verification-line")
    ck offers[1].attr("data-ct-verification-key") == "offer:f1"
    ck offers[1].child("data-ct-verification-location") == "src/main.nr:7:12"
    let opened = windowPlan(run, Run & ",verify:line:1", tr)
    ck tr.contains("verification: press offer:f1")
    ck opened.kindsOf() == @["vlOffer", "vlOffer", "vlGroup", "vlFinding",
                             "vlCounterexample", "vlNote", "vlNote", "vlStep",
                             "vlStep"]
    var notes: seq[string] = @[]
    for n in opened.nodesWith("data-ct-verification-line"):
      if n.attr("data-ct-verification-line-kind") == "vlNote":
        notes.add n.child("data-ct-verification-text")
    ck notes == @["These values come from the prover, not from a run. " &
                  "Nothing executed this program to produce them.",
                  "1 of 2 steps have no source position"]
    let steps = opened.nodesWith("data-ct-current")
    ck steps.len == 1 and steps[0].attr("data-ct-verification-key") == "step:0"
    var unknown = false
    for n in opened.nodesWith("data-ct-verification-location"):
      if n.attr("data-ct-verification-location") == "position not recorded":
        unknown = true
    ck unknown
    # The step with no position says so; the violation opens line 7.
    discard windowPlan(run, Run & ",verify:line:1,verify:line:7", tr)
    ck tr.contains("verification: step 1: position not recorded")
    discard windowPlan(run, Run & ",verify:line:1,verify:line:8", tr)
    ck tr.contains("caret 7:12")
    # A finding whose file the package does not have says so.
    discard windowPlan(run, Run & ",verify:line:3", tr)
    ck tr.contains("noir_verification_failing/src/main.nr is not in")

  test "the assertion count":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
