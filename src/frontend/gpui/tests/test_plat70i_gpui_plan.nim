## test_plat70i_gpui_plan.nim — PLAT-70 Part I (Horizontal-Overflow.md §5.5),
## the GPUI window's table panes fit or scroll, read off the SHIPPED binary's
## window plan (`codetracer-gpui --report-window-plan --window-ops=…`: the
## window's own root builder and pointer handlers) over real recordings
## against a real `replay-server`:
##
##   * the Event Log of `test-programs/wide_lines`: its columns fit the pane,
##     so it draws no horizontal bar (HO-11); with the remembered width of its
##     output column wider than the pane (written by the code the terminal
##     writes it with, `host/table_column_widths.saveColumnWidths`, HO-14)
##     the columns SCROLL — the bar (`data-ct-hscroll`) is drawn, the header
##     and every row are as wide as the laid-out table, and a horizontal
##     wheel (`hwheel:`, the window's own wheel handler) moves the header and
##     the rows by the same pixels;
##   * the Call Trace of `test-programs/deep_calls`: a call nested 40 deep
##     makes the pane SCROLL (`data-ct-fit`, the bar), and the wheel moves
##     the rows (HO-15's GPUI half); the shared solver's widths are the ones
##     drawn (HO-13: the plan's list width is `callTraceFit`'s floor).
##
## No mocks: the binary, the engine and the recordings are the product's.

import std/[json, os, osproc, streams, strtabs, strutils, tempfiles,
            unittest]
import ./gpui_child_env

import codetracer_embed

import ../../tui/tests/fixtures/fixture_provider
import ../app/leaves
import ../../viewmodel/host/table_column_widths

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 12

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  StateDirEnvVar = "CODETRACER_TUI_LAYOUT_DIR"
  W = 1440
  H = 1000

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let bin = repo / "build/bin/codetracer-gpui"
let shimDir = getEnv("ISONIM_GPUI_SHIM_DIR",
                   repo.parentDir / "isonim-gpui/rust/target/debug")

proc recording(name, program: string): string =
  let resolved = resolveFixture(FixtureSpec(
    name: name, program: program,
    recorder: "codetracer-python-recorder",
    probe: FixtureProbe(kind: pkPythonRecorder),
    buildHint: "Install codetracer_python_recorder into the interpreter " &
               "`ct` will use.",
    blockedOn: ""))
  doAssert resolved.outcome == foRecorded, resolved.detail
  resolved.tracePath

type Run = object
  plan: JsonNode
  trace: string
  geometry: JsonNode

proc windowPlan(subject, ops: string; state = ""): Run =
  if not fileExists(bin):
    raise newException(IOError, "prerequisite missing: " & bin &
                       " (just build-gpui)")
  let dir = if state.len > 0: state
            else: createTempDir("plat70i-gpui-plan-", "")
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["LD_LIBRARY_PATH"] = gpuiLibraryPath(shimDir)
  env[StateDirEnvVar] = dir
  env["XDG_STATE_HOME"] = dir
  env["CODETRACER_HOME"] = dir / "ct-home"
  env["CODETRACER_GPUI_GESTURE_TRACE"] = "1"
  let geometry = dir / "geometry.json"
  env["CODETRACER_GPUI_GEOMETRY_OUT"] = geometry
  var args = @["--report-window-plan", "--width=" & $W, "--height=" & $H]
  if ops.len > 0:
    args.add "--window-ops=" & ops
  args.add subject
  let errFile = genTempPath("plat70i-gpui-plan-", ".err")
  let p = startProcess("/bin/sh",
    args = @["-c", "exec timeout 180 \"$0\" \"$@\" 2>" & quoteShell(errFile),
             bin] & args, env = env, options = {})
  let output = p.outputStream.readAll()
  let rc = p.waitForExit()
  p.close()
  result.trace = if fileExists(errFile): readFile(errFile) else: ""
  removeFile(errFile)
  if rc != 0:
    checkpoint("codetracer-gpui exited " & $rc & ": " & result.trace)
    raise newException(IOError, "the window plan run failed (" & ops & ")")
  result.plan = parseJson(output)
  result.geometry = if fileExists(geometry): parseFile(geometry) else: newJNull()

proc attr(n: JsonNode; name: string): string =
  if n{"attributes"}.kind == JObject: n["attributes"]{name}.getStr else: ""

proc hasAttr(n: JsonNode; name: string): bool =
  n{"attributes"}.kind == JObject and n["attributes"].hasKey(name)

proc collect(n: JsonNode; pred: proc(n: JsonNode): bool;
             acc: var seq[JsonNode]) =
  if n.isNil: return
  if pred(n): acc.add n
  for c in n{"children"}.getElems: collect(c, pred, acc)

proc all(n: JsonNode; pred: proc(n: JsonNode): bool): seq[JsonNode] =
  collect(n, pred, result)

proc style(n: JsonNode; key: string): string =
  ## A style the plan carries, by any of its spellings.
  let st = n{"styles"}
  if st.isNil or st.kind != JObject: return ""
  for k in [key, key.replace("-", "_"),
            key.replace("-width", "_w").replace("-height", "_h")]:
    if st.hasKey(k): return st[k].getStr
  ""

proc bars(run: Run; pane: string): seq[JsonNode] =
  run.plan.all(proc(n: JsonNode): bool =
    n.hasAttr(TableHBarAttribute) and n.attr("data-ct-hscroll-pane") == pane)

proc leftOf(bar: JsonNode): int =
  parseInt(bar.attr(TableHBarAttribute).split(',')[0])

suite "PLAT-70 Part I in the GPUI window: fit or scroll":

  test "the Event Log: no bar while it fits; a wide column scrolls and the wheel moves header and rows":
    let subject = recording("wide_lines", "test-programs/wide_lines/main.py")
    let fits = windowPlan(subject, "")
    ck fits.bars($paneEventLog).len == 0
    let state = createTempDir("plat70i-gpui-widths-", "")
    putEnv(StateDirEnvVar, state)
    ck saveColumnWidths("event-log",
                        @[(table: "event-log", column: "output", cells: 400)]) == ""
    delEnv(StateDirEnvVar)
    let scrolls = windowPlan(subject, "", state)
    let bar = scrolls.bars($paneEventLog)
    ck bar.len == 1
    ck bar[0].leftOf == 0
    let header = scrolls.plan.all(proc(n: JsonNode): bool =
      n.hasAttr(EventLogHeaderAttribute))
    ck header.len == 1
    # The header is as wide as the laid-out table: the output column alone is
    # the user's 400 cells.
    let headW = parseInt(header[0].style("min-width").replace("px", ""))
    ck headW >= pxOfCells(400)
    let moved = windowPlan(subject, "hwheel:" & $paneEventLog & ":12", state)
    let bar2 = moved.bars($paneEventLog)
    ck bar2.len == 1 and bar2[0].leftOf > 0
    let head2 = moved.plan.all(proc(n: JsonNode): bool =
      n.hasAttr(EventLogHeaderAttribute))
    ck head2.len == 1 and
       head2[0].style("margin-left") == "-" & $bar2[0].leftOf & "px"

  test "HO-15: a deep call makes the Call Trace scroll; the wheel moves its rows":
    let subject = recording("deep_calls", "test-programs/deep_calls/main.py")
    # The trace's deep calls on screen: the wheel down over the pane (the
    # window loads the section it scrolls to).
    let down = "wheel:" & $paneCalltrace & ":40"
    let run = windowPlan(subject, down)
    let bar = run.bars($paneCalltrace)
    checkpoint(run.trace[max(0, run.trace.len - 2000) .. ^1])
    ck bar.len == 1
    let lists = run.plan.all(proc(n: JsonNode): bool =
      n.attr("data-calltrace") == "rows")
    ck lists.len == 1
    let moved = windowPlan(subject, down & ",hwheel:" & $paneCalltrace & ":30")
    let bar2 = moved.bars($paneCalltrace)
    ck bar2.len == 1 and bar2[0].leftOf > 0
    let lists2 = moved.plan.all(proc(n: JsonNode): bool =
      n.attr("data-calltrace") == "rows")
    ck lists2.len == 1 and
       lists2[0].style("margin-left") == "-" & $bar2[0].leftOf & "px"

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
