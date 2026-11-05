## test_plat70e_gpui_plan.nim — PLAT-70 Part E (Variable-State-Pane.md
## § Value origin from the keyboard; Value-Origin-Tracking.md §13.0): **the
## value origin from the keyboard in the GPUI window**, read from the
## window's own render plan and gesture trace.
##
## The shipped `codetracer-gpui` on the `calc` recording, with
## `--report-window-plan` and `--window-ops` dispatched through the window's
## own key handler — keyboard only after the setup press that reaches the
## position (PLAT-50's: the third event's jump). There, with the Variables pane
## focused from the View menu (`Alt+W`, `V`, `Enter`) and `value`
## selected by `Down`:
##
##   * `Ctrl+Shift+O` opens its chain under the row (one
##     `data-ct-origin-hop` node per hop, each with its seek tick); `Down`
##     moves the cursor onto the first hop (`data-state-selected` on the hop,
##     not on the variable); `Escape` closes the chain and returns to the
##     variable; `Enter` on a hop moves the recording to the hop's tick (the
##     footer's position);
##   * the application key (`menu`) opens the row's menu with "Show value
##     origin", and choosing it toggles the chain;
##   * `o` walks to the origin (the tick moves, the trace names the hop) and
##     `Shift+O` walks back to the question's tick.
##
## No mocks: the real binary, a real recording of the `calc` program, a real
## `replay-server`.

import replay_prerequisite
import std/[json, os, osproc, streams, strtabs, strutils, tempfiles, unittest]
import ./gpui_child_env

import ../../tui/tests/fixtures/fixture_provider

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  ExpectedAssertions = 16
  StateDirEnvVar = "CODETRACER_TUI_LAYOUT_DIR"
  W = 1600
  H = 1000

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let bin = repo / "build/bin/codetracer-gpui"
let shimDir = getEnv("ISONIM_GPUI_SHIM_DIR",
                   repo.parentDir / "isonim-gpui/rust/target/debug")

proc calcTrace(): string =
  let resolved = resolveFixture("calc")
  doAssert resolved.outcome == foRecorded, resolved.detail
  resolved.tracePath

let trace = calcTrace()

proc windowPlan(ops: string): tuple[plan: JsonNode, trace: string] =
  ## The window's root after `ops`, and its gesture trace.
  if not fileExists(bin):
    raise newException(IOError, "prerequisite missing: " & bin &
                       " (just build-gpui)")
  let state = createTempDir("plat70e-gpui-plan-", "")
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["LD_LIBRARY_PATH"] = gpuiLibraryPath(shimDir)
  env[StateDirEnvVar] = state
  env["XDG_STATE_HOME"] = state
  env["CODETRACER_HOME"] = state / "ct-home"
  env["CODETRACER_GPUI_GESTURE_TRACE"] = "1"
  let errFile = genTempPath("plat70e-gpui-plan-", ".err")
  let args = @["--report-window-plan", "--width=" & $W, "--height=" & $H,
               "--window-ops=" & ops, trace]
  let p = startProcess("/bin/sh",
    args = @["-c", "exec \"$0\" \"$@\" 2>" & quoteShell(errFile), bin] & args,
    env = env, options = {})
  let output = p.outputStream.readAll()
  let rc = p.waitForExit()
  p.close()
  result.trace = if fileExists(errFile): readFile(errFile) else: ""
  removeFile(errFile)
  removeDir(state)
  if rc != 0:
    checkpoint("codetracer-gpui exited " & $rc & ": " & result.trace)
    raise newException(IOError, "the window plan run failed (" & ops & ")")
  result.plan = parseJson(output)

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

proc textOf(n: JsonNode): string =
  if n{"kind"}.getStr == "TextNode": return n{"text"}.getStr
  for c in n{"children"}.getElems: result.add textOf(c)

proc tickOf(plan: JsonNode): string =
  ## The footer's location's ticks (`data-ct-footer-position`,
  ## `<path>:<line>#<ticks>`).
  let loc = plan.nodesWith("data-ct-footer-position")
  if loc.len != 1: return ""
  let t = loc[0].attr("data-ct-footer-position")
  let at = t.rfind('#')
  if at < 0 or at == t.high: return ""
  t[at + 1 .. ^1]

proc hops(plan: JsonNode): seq[JsonNode] = plan.nodesWith("data-ct-origin-hop")

proc selectedRows(plan: JsonNode): seq[JsonNode] =
  for n in plan.nodesWith("data-state-selected"):
    if n.attr("data-state-selected") == "true": result.add n

proc variableRow(plan: JsonNode; name: string): JsonNode =
  for n in plan.nodesWith("data-state-row"):
    if textOf(n).startsWith(name & ":"): return n
  nil

const
  AtExpressions = "click:event:3:left,wait:2000"
    ## The position of the third event (tick 118, `main.py:111`) — the third
    ## event's jump (setup; everything after it is keys).
  FocusVariables = "key:w:alt,type:V,key:enter"
    ## The View menu's Variables (`Alt+W`, `V`, `Enter`) — the keyboard's way
    ## to the pane, which focuses it as the desktop's View menu does.
  ToExpressions = AtExpressions & "," & FocusVariables &
                  repeat(",key:down", 19)
    ## `Down` 19 times: `value`, the 19th row (the rows are in name order;
    ## its origin is the call at tick 90, not the stop's 118).

suite "PLAT-70 Part E: value origin from the keyboard in the GPUI window":

  test "Ctrl+Shift+O, Down onto a hop, Escape, Enter seeks":
    let ops = ToExpressions
    let (plan, gestures) = windowPlan(ops)
    checkpoint(gestures)
    let sel = plan.selectedRows
    ck sel.len == 1 and textOf(sel[0]).startsWith("value:")
    let t0 = tickOf(plan)
    # Ctrl+Shift+O: the chain under the row.
    let (opened, og) = windowPlan(ops & ",key:o:control+shift")
    checkpoint(og)
    let hs = opened.hops
    ck hs.len >= 1
    ck opened.selectedRows.len == 1 and
       textOf(opened.selectedRows[0]).startsWith("value:")
    # Down: onto the first hop.
    let (onHop, _) = windowPlan(ops & ",key:o:control+shift,key:down")
    let s1 = onHop.selectedRows
    ck s1.len == 1 and s1[0].attr("data-ct-origin-hop") == "0"
    # Escape: the chain closes, the variable is the cursor's again.
    let (closed, _) = windowPlan(ops & ",key:o:control+shift,key:down,key:escape")
    ck closed.hops.len == 0
    ck closed.selectedRows.len == 1 and
       textOf(closed.selectedRows[0]).startsWith("value:")
    # Enter on the first hop: the recording moves to the hop's tick.
    let target = hs[0].attr("data-ct-origin-tick")
    ck target.len > 0 and target != t0
    let (seeked, sg) = windowPlan(ops & ",key:o:control+shift,key:down,key:enter,wait:3000")
    checkpoint(sg)
    ck sg.contains("origin hop at tick " & target)
    ck tickOf(seeked) == target
    # The cursor stays on the hop across the stop the seek made (the chain
    # read again at the new tick).
    let s2 = seeked.selectedRows
    ck s2.len == 1 and s2[0].attr("data-ct-origin-hop") == "0"

  test "the Menu key opens the row menu; Show value origin toggles the chain":
    let ops = ToExpressions
    let (menu, mg) = windowPlan(ops & ",key:menu")
    checkpoint(mg)
    ck mg.contains("context menu") and mg.contains("Show value origin")
    let (toggled, _) = windowPlan(ops & ",key:menu,ctx:Show value origin")
    ck toggled.hops.len >= 1
    discard menu

  test "o walks to the origin and Shift+O walks back":
    let ops = ToExpressions
    let (at, _) = windowPlan(ops)
    let t0 = tickOf(at)
    ck at.selectedRows.len == 1 and
       textOf(at.selectedRows[0]).startsWith("value:")
    let (walked, wg) = windowPlan(ops & ",key:o,wait:3000")
    checkpoint(wg)
    ck wg.contains("value ")
    ck tickOf(walked).len > 0 and tickOf(walked) != t0
    let (back, bg) = windowPlan(ops & ",key:o,wait:3000,key:o:shift,wait:3000")
    checkpoint(bg)
    ck tickOf(back) == t0

  test "assertion count":
    check CHECKS == ExpectedAssertions
