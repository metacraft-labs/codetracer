## test_gpui_keyed_redraw.nim — a step writes the elements it moved, and the
## window it leaves is the window a full rebuild draws.
##
## The window draws every pane again after the debugger moves. The panes keep
## the elements whose content did not move (`element_reuse`): an editor row,
## an event row, a call, a value, drawn last time from the same inputs, is
## appended where its rebuilt twin would have gone. That is an optimisation,
## so two things must hold, and this suite holds both against the shipped
## binary over the `calc` recording:
##
## * **It is not visible.** The same scripted steps — forward and back, into
##   a call and out of it, a pane scrolled, a tab pressed, an event row
##   pressed after the log scrolled — give the same window render plan with
##   the pools on and with `CODETRACER_GPUI_FULL_REDRAW=1` (every element
##   built anew, the behaviour before). The control: the steps change the
##   plan at all, and the switch reaches the binary.
## * **It is real.** Each step's churn report
##   (`CODETRACER_GPUI_CHURN_REPORT`, the elements each op built, per pane,
##   read off the shim's node ids) shows a step replacing at most
##   `MaxEditorReplaced` of the editor's own children and building at most a
##   quarter of what the full rebuild builds for the same step. The control:
##   under the full rebuild the same steps replace every editor row, so the
##   bound is not met by a step that moved nothing.
##
## Everything is read from the binary's output after it exits: nothing here
## waits on a clock, so the suite is the same on a loaded host.
##
## No mocks: the shipped `build/bin/codetracer-gpui`, the real isonim-gpui
## shim, a real replay-server and a real recording.
##
## Run: `nim c -r --path:src/frontend/viewmodel src/frontend/gpui/tests/test_gpui_keyed_redraw.nim`
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
  ExpectedAssertions = 15
  StateDirEnvVar = "CODETRACER_TUI_LAYOUT_DIR"
  W = 1600
  H = 1000
  # Steps forward and back, into a call and out of it, panes scrolled, a tab
  # pressed, an event row pressed after the log scrolled (its row is a kept
  # element whose index moved), and the editor wheeled to the file's end and
  # back (its first row pulled up above the editor's top, then not): every
  # pane the stepping run redraws gets a new ViewModel at least once.
  Steps = "key:n,key:n,key:f11,key:f11,wheel:eventLog:2,wheel:editor:3,key:n," &
          "key:p,click:tab:calltrace,key:n,key:p,wheel:eventLog:1," &
          "click:event:1,key:n,key:n,wheel:editor:200,key:n,wheel:editor:-200," &
          "key:n,key:n"
  # The editor wheeled to the file's end, where its last line rests on the
  # bottom edge and the first drawn row starts above the editor's top.
  EndOps = "key:n,wheel:editor:200"
  # The stepping run the bounds are read from: a step over, thirty times
  # less twenty, at the recording's start.
  StepOps = "key:n,key:n,key:n,key:n,key:n,key:n,key:n,key:n,key:n,key:n"
  MaxEditorReplaced = 5
    ## The editor's own children the median step may build: the rows the
    ## execution line left and reached, the overview ruler's mark, and the
    ## scrubber's.
  MaxShareOfFull = 0.25
    ## The elements the median step builds, as a share of the full
    ## rebuild's.

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let bin = repo / "build/bin/codetracer-gpui"
let shimDir = getEnv("ISONIM_GPUI_SHIM_DIR",
                   repo.parentDir / "isonim-gpui/rust/target/debug")
let calc = requireFixture(fixtureSpec("calc"))
let ctHome = createTempDir("gpui-keyed-redraw-home-", "")
  ## One CodeTracer home for every run: the plan names files under it (the
  ## tab icons' cache), so a home of its own per run would differ in nothing
  ## but its path.
addExitProc(proc() = removeDir(ctHome))

proc canonical(n: JsonNode) =
  ## An element's listened events are a set, printed in hash order, which
  ## differs from run to run of the same binary: sorted, so two plans compare
  ## by what they hold. Node ids are the shim's creation order, and a kept
  ## element keeps its id while a rebuilt one takes a new one: dropped, so
  ## the plans compare by what they draw. (Objects compare regardless of key
  ## order.)
  if n.kind == JObject:
    if n.hasKey("event_names") and n["event_names"].kind == JArray:
      var names: seq[string]
      for e in n["event_names"]: names.add e.getStr
      names.sort()
      n["event_names"] = %names
    for key in ["node_id", "id"]:
      if n.hasKey(key) and n[key].kind == JInt:
        n.delete(key)
    for _, v in n: canonical(v)
  elif n.kind == JArray:
    for v in n: canonical(v)

type Run = object
  plan: JsonNode
  churn: JsonNode

proc windowRun(ops: string; fullRedraw: bool): Run =
  ## The window's render plan after `ops`, as the shipped binary prints it,
  ## and its churn report.
  if not fileExists(bin):
    raise newException(IOError, "prerequisite missing: " & bin &
                       " (just build-gpui)")
  let root = createTempDir("gpui-keyed-redraw-", "")
  defer: removeDir(root)
  var env = newStringTable()
  for k, v in envPairs():
    if k notin ["CODETRACER_GPUI_FULL_REDRAW", "CODETRACER_GPUI_CHURN_REPORT"]:
      env[k] = v
  if fullRedraw:
    env["CODETRACER_GPUI_FULL_REDRAW"] = "1"
  env["CODETRACER_GPUI_CHURN_REPORT"] = root / "churn.json"
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
  result.plan = parseJson(output)
  canonical(result.plan)
  result.churn = if ops.len > 0: parseJson(readFile(root / "churn.json"))
                 else: newJArray()

proc firstDifference(a, b: JsonNode): string =
  let x = a.pretty
  let y = b.pretty
  var i = 0
  while i < min(x.len, y.len) and x[i] == y[i]:
    inc i
  "first difference at " & $i & ": with the pools …" &
    x[max(0, i - 300) ..< min(x.len, i + 200)] & "… rebuilt …" &
    y[max(0, i - 300) ..< min(y.len, i + 200)] & "…"

func median(xs: seq[float]): float =
  ## The middle value (the mean of the two middle ones for an even count).
  if xs.len == 0: return 0.0
  let s = xs.sorted()
  if s.len mod 2 == 1: s[s.len div 2]
  else: (s[s.len div 2 - 1] + s[s.len div 2]) / 2

proc editorReplaced(step: JsonNode): int =
  step["panes"]{"editor"}{"replaced"}.getInt(-1)

suite "GPUI: a step writes what it moved":

  test "the steps give the same plan as a full rebuild of every pane":
    let kept = windowRun(Steps, fullRedraw = false)
    let rebuilt = windowRun(Steps, fullRedraw = true)
    ck kept.plan.len > 0
    ck kept.plan == rebuilt.plan
    if kept.plan != rebuilt.plan:
      checkpoint(firstDifference(kept.plan, rebuilt.plan))
    # And the pools were on in one run and off in the other.
    var reused, reusedFull = 0
    for s in kept.churn: reused += s["reused"].getInt
    for s in rebuilt.churn: reusedFull += s["reused"].getInt
    ck reused > 0
    ck reusedFull == 0

  test "control: the steps change the plan, and the switch reaches the binary":
    let opened = windowRun("", fullRedraw = false)
    let stepped = windowRun(Steps, fullRedraw = false)
    ck opened.plan.len > 0
    ck stepped.plan != opened.plan
    ck windowRun("", fullRedraw = true).plan == opened.plan

  test "a step builds a quarter of the full rebuild, and few editor rows":
    let kept = windowRun(StepOps, fullRedraw = false)
    let rebuilt = windowRun(StepOps, fullRedraw = true)
    ck kept.churn.len == rebuilt.churn.len
    # The stepping run draws the same window either way, too: its last step
    # moved the execution line within kept rows.
    ck kept.plan == rebuilt.plan
    # The first step is the window's first redraw after it opened: every
    # pane's pool is empty until a draw has filled it. A step into another
    # file draws that file's rows for the first time, so the bounds are on
    # the MEDIAN step, as the milestone states them.
    var editor, shares: seq[float]
    for i in 1 ..< min(kept.churn.len, rebuilt.churn.len):
      editor.add float(editorReplaced(kept.churn[i]))
      shares.add kept.churn[i]["fresh"].getInt /
                 max(1, rebuilt.churn[i]["fresh"].getInt)
    checkpoint("editor children each step built: " & $editor &
               "; each step's share of the full rebuild: " & $shares)
    ck median(editor) <= float(MaxEditorReplaced)
    ck median(shares) <= MaxShareOfFull
    # The control: the full rebuild replaces every editor row on a step, so
    # the bound above is not met by steps that drew nothing.
    var full: seq[float]
    for i in 1 ..< rebuilt.churn.len:
      full.add float(editorReplaced(rebuilt.churn[i]))
    checkpoint("editor children the full rebuild built: " & $full)
    ck median(full) > float(4 * MaxEditorReplaced)

  test "at the file's end the first row is pulled above the editor's top":
    # The first editor row (`data-ct-row`) of the window wheeled to the end
    # carries a negative `margin-top`, with the pools on and off alike, and
    # the full rebuild agrees with the kept rows about which row it is.
    proc firstRowMargin(n: JsonNode): string =
      if n.kind != JObject: return ""
      if n{"attributes"}{"data-ct-row"}.getStr.len > 0:
        return n{"styles"}{"margin_top"}.getStr
      for c in n{"children"}.getElems:
        let m = firstRowMargin(c)
        if m.len > 0: return m
      ""
    let kept = windowRun(EndOps, fullRedraw = false)
    let margin = firstRowMargin(kept.plan)
    checkpoint("the first row's margin-top: '" & margin & "'")
    ck margin.startsWith("-")
    ck margin == firstRowMargin(windowRun(EndOps, fullRedraw = true).plan)

  test "every assertion ran":
    ck CHECKS == ExpectedAssertions
