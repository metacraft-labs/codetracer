## test_plat70b_gpui_plan.nim — PLAT-70 Part B (Horizontal-Overflow.md §5),
## the GPUI window's table panes, read off the SHIPPED binary's window plan
## (`codetracer-gpui --report-window-plan --window-ops=…`: the window's own
## root builder, its own pointer and key handlers) over a real recording of
## `test-programs/wide_lines` against a real `replay-server`:
##
##   * HO-8 — in the Variables, Event Log and Call Trace panes a cell carries
##     `data-ct-cut` exactly when its text ends in `…`, both directions; an
##     Event Log cell and a Call Trace row are the shared `fitCell` of their
##     whole text at the characters their column holds; the state pane draws
##     no sideways scrollbar (Variable-State-Pane Decision 3);
##   * §5.3 hover — the pointer resting on a cut cell shows its whole text
##     once 500 ms have passed (the window's own hover clock, advanced by the
##     scripted `wait:`), not before; on a cell that fits, none;
##   * §5.3 detail — a press on a cut cell's `…` opens its row's whole text
##     under the row (`data-ct-detail`), at most `DetailMaxLines` lines, and
##     moves neither the debugger nor its tick; `Ctrl+K Ctrl+I`
##     (`list.show-detail`) opens the focused variable's; `Ctrl+C` copies its
##     WHOLE value;
##   * §5.2 / HO-9 — the remembered document's width (written in the
##     terminal's own form by the code the terminal writes it with,
##     `host/table_column_widths.saveColumnWidths`) is the width the window
##     draws, and a drag on a header separator writes the window's back.
##
## No mocks: the binary, the engine and the recording are the product's.

import std/[json, math, os, osproc, streams, strtabs, strutils, tempfiles,
            unicode, unittest]
import ./gpui_child_env

import codetracer_embed

import ../../tui/tests/fixtures/fixture_provider
import ../app/leaves
import ../../viewmodel/host/table_column_widths

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 40

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  StateDirEnvVar = "CODETRACER_TUI_LAYOUT_DIR"
  W = 1440
  H = 1000
  Program = "test-programs/wide_lines/main.py"
  Steps = "key:f10,key:f10,key:f10"
    ## Past the module's first statements: its names are the state's rows.

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let bin = repo / "build/bin/codetracer-gpui"
let shimDir = getEnv("ISONIM_GPUI_SHIM_DIR",
                   repo.parentDir / "isonim-gpui/rust/target/debug")

proc recording(): string =
  let resolved = resolveFixture(FixtureSpec(
    name: "wide_lines", program: Program,
    recorder: "codetracer-python-recorder",
    probe: FixtureProbe(kind: pkPythonRecorder),
    buildHint: "Install codetracer_python_recorder into the interpreter " &
               "`ct` will use.",
    blockedOn: ""))
  doAssert resolved.outcome == foRecorded, resolved.detail
  resolved.tracePath

let subject = recording()

type Run = object
  plan: JsonNode
  trace: string
  geometry: JsonNode
  state: string

proc windowPlan(ops: string; state = ""): Run =
  if not fileExists(bin):
    raise newException(IOError, "prerequisite missing: " & bin &
                       " (just build-gpui)")
  result.state = if state.len > 0: state
                 else: createTempDir("plat70b-gpui-plan-", "")
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["LD_LIBRARY_PATH"] = gpuiLibraryPath(shimDir)
  env[StateDirEnvVar] = result.state
  env["XDG_STATE_HOME"] = result.state
  env["CODETRACER_HOME"] = result.state / "ct-home"
  env["CODETRACER_GPUI_GESTURE_TRACE"] = "1"
  let geometry = result.state / "geometry.json"
  env["CODETRACER_GPUI_GEOMETRY_OUT"] = geometry
  var args = @["--report-window-plan", "--width=" & $W, "--height=" & $H]
  if ops.len > 0:
    args.add "--window-ops=" & ops
  args.add subject
  let errFile = genTempPath("plat70b-gpui-plan-", ".err")
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

proc text(n: JsonNode): string =
  if n{"kind"}.getStr == "TextNode": return n{"text"}.getStr
  for c in n{"children"}.getElems: result.add text(c)

proc bodyOf(g: JsonNode; pane: string): tuple[x, y, w, h: int] =
  for n in g["nodes"].getElems:
    if n{"kind"}.getStr == "tabs":
      for p in n["panes"].getElems:
        if p.getStr == pane:
          let b = n["body"].getElems
          return (b[0].getInt, b[1].getInt, b[2].getInt, b[3].getInt)
  (0, 0, 0, 0)

proc tickOf(trace: string): string =
  ## The last tick the window reported (`control … tick=N`).
  for line in trace.splitLines:
    let at = line.find("tick=")
    if at >= 0:
      result = line[at + 5 .. ^1].split(' ')[0]

suite "PLAT-70 Part B: the GPUI window's table panes":

  test "HO-8: the cut cells off the plan, and the shared fit":
    let run = windowPlan(Steps)
    let cells = run.plan.all(proc(n: JsonNode): bool =
      n.attr(StateColumnAttribute) == StateValueColumn or
      n.hasAttr(CallRowAttribute) or
      (n.hasAttr("data-column-index") and n{"children"}.len > 0 and
       n{"children"}[0]{"kind"}.getStr == "TextNode"))
    var both, cutSeen = 0
    for c in cells:
      let drawn = c.text
      let marked = c.hasAttr(TableCutAttribute)
      if drawn.endsWith(Ellipsis) == marked: inc both
      if marked: inc cutSeen
    checkpoint("cells " & $cells.len & ", cut " & $cutSeen)
    ck both == cells.len
    ck cutSeen >= 3
    ck cutSeen < cells.len
    # The event's output: the fit of its whole text at its column's
    # characters, from the window's own geometry and column layout.
    let ev = run.geometry.bodyOf($paneEventLog)
    ck ev.w > 0
    var outX, outW = 0
    for (col, x, w) in defaultEventLogColumns().eventColumnsPx(ev.w):
      if col == elcOutput:
        outX = x
        outW = w
    let full = "stdout: <<LEFT-EDGE>> the quick brown fox jumps over the lazy " &
               "dog, 0123456789 the quick brown fox jumps over the lazy dog, " &
               "0123456789 the quick brown fox jumps over the lazy dog, " &
               "0123456789 the quick brown fox jumps over the lazy dog, " &
               "0123456789 <<RIGHT-EDGE>>"
    let fitted = fitCell(full, cellsInPx(outW - 14))
    var outputCell: JsonNode
    for c in cells:
      if c.text.startsWith("stdout: <<LEFT-EDGE>>"): outputCell = c
    ck not outputCell.isNil
    ck outputCell.text == fitted.text
    ck outputCell.attr(TableCutAttribute) == $elcOutput
    # Decision 3: no sideways scrollbar in the state pane.
    ck run.plan.all(proc(n: JsonNode): bool =
      n.attr("data-ct-state-scrollbar") == "horizontal").len == 0

  test "§5.3: hover after 500 ms on a cut cell, none on one that fits":
    let ev = windowPlan(Steps).geometry.bodyOf($paneEventLog)
    let y = ev.y + EventRowsTopPx + 12
    let cutX = ev.x + ev.w div 2
    proc tooltips(r: Run): seq[JsonNode] =
      r.plan.all(proc(n: JsonNode): bool = n.hasAttr("data-ct-cell-tooltip"))
    let early = windowPlan(Steps & ",move:" & $cutX & ":" & $y & ",wait:300")
    ck early.tooltips.len == 0
    let late = windowPlan(Steps & ",move:" & $cutX & ":" & $y & ",wait:600")
    let tips = late.tooltips
    ck tips.len == 1
    ck tips[0].text.contains("<<LEFT-EDGE>> the quick")
    ck "cell tooltip" in late.trace
    # The `#` cell of the same row fits: no tooltip.
    let fitsX = ev.x + ev.w div 10 + 20
    let quiet = windowPlan(Steps & ",move:" & $fitsX & ":" & $y & ",wait:600")
    ck quiet.tooltips.len == 0

  test "§5.3: the `…` press opens the detail; the tick stays; again closes":
    let base = windowPlan(Steps)
    let ev = base.geometry.bodyOf($paneEventLog)
    var outX, outW = 0
    for (col, x, w) in defaultEventLogColumns().eventColumnsPx(ev.w):
      if col == elcOutput:
        outX = x
        outW = w
    let shown = cellsInPx(outW - 14)
    let dotX = ev.x + outX + 14 + pxOfText(shown - 1) + 3
    let y = ev.y + EventRowsTopPx + 12
    # As a real press reaches the window: the row under it first (its
    # listeners — a row press jumps the debugger), then the window root.
    let press = "click:event:0@" & $dotX & "x" & $y
    let opened = windowPlan(Steps & "," & press)
    let lines = opened.plan.all(proc(n: JsonNode): bool =
      n.hasAttr(TableDetailAttribute))
    checkpoint("detail lines " & $lines.len)
    ck lines.len >= 2
    ck lines.len <= DetailLineCap
    var joined = ""
    for l in lines: joined.add l.text & " "
    ck joined.contains("<<RIGHT-EDGE>>")
    ck "detail open eventLog" in opened.trace
    ck "pane click event left to the table gesture" in opened.trace
    ck opened.trace.tickOf == base.trace.tickOf
    let closed = windowPlan(Steps & "," & press & "," & press)
    ck closed.plan.all(proc(n: JsonNode): bool =
      n.hasAttr(TableDetailAttribute)).len == 0

  test "§5.3: Ctrl+K Ctrl+I on the focused variable; Ctrl+C its whole value":
    let st = windowPlan(Steps).geometry.bodyOf($paneState)
    let focus = "press:" & $(st.x + 40) & ":" & $(st.y + StateRowsTopPx + 6) &
                ",release:" & $(st.x + 40) & ":" & $(st.y + StateRowsTopPx + 6)
    let select = "click:var:__builtins__"
    let opened = windowPlan(Steps & "," & focus & "," & select &
                            ",key:k:control,key:i:control")
    let lines = opened.plan.all(proc(n: JsonNode): bool =
      n.attr(TableDetailAttribute) == "__builtins__")
    ck lines.len >= 2
    ck lines.len <= detailMaxLines((st.h - StateRowsTopPx) div StateValueRowPx)
    let copied = windowPlan(Steps & "," & focus & "," & select &
                            ",key:c:control")
    # The whole value is the copied text; a multi-line value (a docstring's
    # newlines) continues on the trace's next lines, up to the next gesture.
    var copyLine = ""
    var inCopy = false
    for line in copied.trace.splitLines:
      if "copied the value of __builtins__" in line:
        copyLine = line
        inCopy = true
      elif inCopy and not line.startsWith("gesture "):
        copyLine.add "\n" & line
      else:
        inCopy = false
    checkpoint("copy: " & copyLine.runeSubStr(0, min(120, copyLine.runeLen)))
    ck copyLine.len > 0
    let value = copyLine[copyLine.find(": ", copyLine.find("__builtins__")) + 2 .. ^1]
    ck value.startsWith("@[(\"__name__\", \"builtins\")")
    ck value.runeLen > 1000
    # The WHOLE value (the presenter at `tableFullBudget`), not the row's
    # own rendering, which the row budget cuts after `float` with `…]`:
    # `zip` is among the last of the builtins.
    ck value.contains("(\"zip\", ")
    ck not value.endsWith("…]")

  test "§5.2 / HO-9: the remembered width is drawn; a drag writes it back":
    let state = createTempDir("plat70b-gpui-widths-", "")
    putEnv(StateDirEnvVar, state)
    # A width the defaults never draw (the `#` column's default is 12).
    # The terminal's own write: the code `codetracer-tui` saves a drag with.
    ck saveColumnWidths("event-log",
                        @[(table: "event-log", column: "#", cells: 20)]) == ""
    delEnv(StateDirEnvVar)
    ck readFile(state / TableColumnsFileName) == "event-log.#=20\n"
    let run = windowPlan(Steps, state)
    let header = run.plan.all(proc(n: JsonNode): bool =
      n.hasAttr(EventLogHeaderAttribute))
    ck header.len == 1
    var hashWidth = ""
    for c in header[0]{"children"}.getElems:
      if c.text.startsWith("#"): hashWidth = c{"styles"}{"w"}.getStr
    ck hashWidth == $pxOfCells(20) & "px"
    # A drag on the `#` column's separator grip, 40 px right.
    let ev = run.geometry.bodyOf($paneEventLog)
    var cols = defaultEventLogColumns()
    discard cols.setColumnWidth(elcIndex, 20)
    var edge = 0
    for (col, x, w) in cols.eventColumnsPx(ev.w):
      if col == elcIndex: edge = x + w
    let gx = ev.x + edge - 2
    let gy = ev.y + EventHeaderTopPx + 10
    # A press on the grip and its release in place, as a real press reaches
    # the window — the header cell under it first: the log is not ordered by
    # it, and the width is what it was.
    let onGrip = windowPlan(Steps & ",click:header:#@" & $gx & "x" & $gy, state)
    ck "pane click header left to the table gesture" in onGrip.trace
    ck "event log order" notin onGrip.trace
    ck readFile(state / TableColumnsFileName) == "event-log.#=20\n"
    # The same in place on a column at its DEFAULT width (49 px, not a whole
    # number of cells): still no width is set, and nothing is remembered.
    block:
      let fresh = createTempDir("plat70b-gpui-inplace-", "")
      var edge0 = 0
      for (col, x, w) in defaultEventLogColumns().eventColumnsPx(ev.w):
        if col == elcIndex: edge0 = x + w
      let g0 = ev.x + edge0 - 2
      discard windowPlan(Steps & ",press:" & $g0 & ":" & $gy & ",release:" &
                         $g0 & ":" & $gy, fresh)
      ck not fileExists(fresh / TableColumnsFileName)
    let dragged = windowPlan(Steps & ",press:" & $gx & ":" & $gy &
                             ",move:" & $(gx + 20) & ":" & $gy &
                             ",move:" & $(gx + 40) & ":" & $gy &
                             ",release:" & $(gx + 40) & ":" & $gy, state)
    ck "column separator #" in dragged.trace
    let doc = readFile(state / TableColumnsFileName)
    checkpoint("document: " & doc)
    ck doc.contains("event-log.#=")
    let after = decodeColumnWidths(doc)
    ck after.ok
    var cells = 0
    for e in after.entries:
      if e.column == "#": cells = e.cells
    ck cells > 20
    # The minimum: the separator, now further right, dragged far left.
    discard cols.setColumnWidth(elcIndex, cells)
    var edge2 = 0
    for (col, x, w) in cols.eventColumnsPx(ev.w):
      if col == elcIndex: edge2 = x + w
    let g2 = ev.x + edge2 - 2
    discard windowPlan(Steps & ",press:" & $g2 & ":" & $gy &
                       ",move:" & $(ev.x) & ":" & $gy &
                       ",release:" & $(ev.x) & ":" & $gy, state)
    ck readFile(state / TableColumnsFileName).contains("event-log.#=3\n")

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
