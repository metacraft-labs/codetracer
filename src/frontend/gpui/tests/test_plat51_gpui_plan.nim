## test_plat51_gpui_plan.nim — PLAT-51 in the GPUI window, read off the
## SHIPPED binary's window plan (`codetracer-gpui --report-window-plan
## --window-ops=…`: the window's own root builder and its own pointer and key
## handlers) over real recordings and a real `replay-server`:
##
##   * deliverable 1 — NO TIMELINE: no pane, no tab, no View-menu entry; a
##     saved v5 layout that placed it as the ACTIVE tab of the event stack
##     opens without it, on the tab that slid into its place;
##   * deliverable 2 — the Event Log's and the Call Trace's scrollbars are
##     SCRUBBERS over the WHOLE population (`noir_space_ship`'s 70 events,
##     `call_pages`' 603 calls — more than either pane holds): the track's
##     total is the engine's, a press at its end shows the LAST rows, a held
##     thumb dragged to the end does too with at most one window fetch per
##     motion, the current position is marked, and none of it moves the
##     debugger (a press on the track is not a press on the call row under
##     it);
##   * deliverable 4 — a changed value carries the desktop's changed-value
##     accent (`data-ct-changed`, the value text in
##     `StateChangedColour`), and nothing does at the program's entry;
##   * deliverable 5 — the value history opens under its row, its entries
##     navigation rows;
##   * deliverable 6 — a click in the code places the read-only editor's
##     caret, distinct from the execution pointer;
##   * deliverable 7 — Shift + right-click opens the SAME menu as a plain
##     right-click, with no "terminal / browser menu" hint row (GPUI has no
##     native menu to fall back to);
##   * deliverable 12 — the omnibox on the editor's ground and foreground in
##     every state;
##   * deliverable 13 — the execution pointer is the desktop's
##     `highlight_line_arrow.svg`, never the `▶` glyph.
##
## No mocks: the binary, the engine and the recordings are the product's.

import std/[json, os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import gpui/app/leaves
import gpui/list_scrubber

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 104

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  StateDirEnvVar = "CODETRACER_TUI_LAYOUT_DIR"
  W = 1440
  H = 1400

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let bin = repo / "build/bin/codetracer-gpui"
let shimDir = getEnv("ISONIM_GPUI_SHIM_DIR",
                   repo.parentDir / "isonim-gpui/rust/target/debug")

proc fixture(prefix: string): string =
  for kind, path in walkDir(repo / "test-logs/tui-fixtures"):
    if kind == pcDir and path.extractFilename.startsWith(prefix & "-"):
      return path
  ""

proc windowPlan(ops: string; subject: string; pre: seq[string] = @[];
                trace: var string): JsonNode =
  if not fileExists(bin):
    raise newException(IOError, "prerequisite missing: " & bin &
                       " (just build-gpui)")
  if subject.len == 0:
    raise newException(IOError, "prerequisite missing: a tui-fixtures " &
      "recording (the tui lane records them on its first run)")
  let state = createTempDir("plat51-gpui-plan-", "")
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["LD_LIBRARY_PATH"] = shimDir &
    (if existsEnv("LD_LIBRARY_PATH"): ":" & getEnv("LD_LIBRARY_PATH") else: "")
  env[StateDirEnvVar] = state
  env["XDG_STATE_HOME"] = state
  # Every other per-user location (trace index, config, caches) of the
  # spawned binary: its own, under this case's directory (common/ct_home).
  env["CODETRACER_HOME"] = state / "ct-home"
  env["CODETRACER_GPUI_GESTURE_TRACE"] = "1"
  var args = pre & @["--report-window-plan", "--width=" & $W,
                     "--height=" & $H]
  if ops.len > 0:
    args.add "--window-ops=" & ops
  args.add subject
  let errFile = genTempPath("plat51-gpui-plan-", ".err")
  let p = startProcess("/bin/sh",
    args = @["-c", "exec timeout 120 \"$0\" \"$@\" 2>" & quoteShell(errFile),
             bin] & args, env = env, options = {})
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

proc windowPlan(ops: string; subject: string;
                pre: seq[string] = @[]): JsonNode =
  var t: string
  windowPlan(ops, subject, pre, t)

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

proc scrubber(plan: JsonNode; pane: string): JsonNode =
  for n in plan.nodesWith(ListTrackAttribute):
    if n.attr(ListTrackAttribute) == pane: return n
  newJNull()

proc scrubInt(plan: JsonNode; pane, field: string): int =
  let s = plan.scrubber(pane)
  if s.kind == JNull: -1 else: parseInt(s.attr("data-ct-scrub-" & field))

proc executionLine(plan: JsonNode): int =
  for n in plan.nodesWith(EditorExecutionAttribute):
    return parseInt(n.attr(EditorExecutionAttribute))
  -1

proc menuEntries(plan: JsonNode): seq[string] =
  for n in plan.nodesWith("data-ct-context-entry"):
    result.add n.attr("data-ct-context-entry")

proc countLines(trace, needle: string): int =
  for line in trace.splitLines:
    if needle in line: inc result

proc colourOfText(n: JsonNode): seq[string] =
  ## The text colours under `n` (its own and its descendants').
  let c = n{"styles"}{"text_color"}.getStr
  if c.len > 0: result.add c
  for ch in n{"children"}.getElems: result.add colourOfText(ch)

let calc = fixture("calc")
let noir = fixture("noir_space_ship")
let calls = fixture("call_pages")

suite "PLAT-51 GPUI: the Timeline panel is removed":

  test "no Timeline pane, tab or View-menu entry":
    let plan = windowPlan("menu:View", calc)
    var panes: seq[string] = @[]
    for n in plan.nodesWith(PaneRoleAttribute): panes.add n.attr(PaneRoleAttribute)
    checkpoint("panes: " & $panes)
    ck panes.len > 0
    ck "timeline" notin panes
    var tabs: seq[string] = @[]
    for n in plan.nodesWith("data-ct-tab-pane"): tabs.add n.attr("data-ct-tab-pane")
    ck "timeline" notin tabs
    ck "eventLog" in tabs
    var items: seq[string] = @[]
    for n in plan.nodesWith("data-ct-menu-item"): items.add n.attr("data-ct-menu-item")
    checkpoint("View menu: " & $items)
    ck "Event Log" in items          # the View menu IS open
    ck "Terminal Output" in items
    for it in items:
      ck not it.startsWith("Timeline")

  test "a saved v5 layout with the Timeline as the active tab opens without it":
    let dir = createTempDir("plat51-v5-layout-", "")
    let file = dir / "layout.json"
    writeFile(file, $(%*{"version": 5, "docked": [],
      "layout": {"kind": "row", "weight": 1.0, "children": [
        {"kind": "pane", "pane": "editor", "weight": 2.0},
        {"kind": "stack", "weight": 1.0, "activeIndex": 1, "children": [
          {"kind": "pane", "pane": "eventLog", "weight": 1.0},
          {"kind": "pane", "pane": "timeline", "weight": 1.0},
          {"kind": "pane", "pane": "terminalOutput", "weight": 1.0}]}]}}))
    let plan = windowPlan("", calc, pre = @["--layout=" & file])
    removeDir(dir)
    var panes, tabs: seq[string] = @[]
    for n in plan.nodesWith(PaneRoleAttribute): panes.add n.attr(PaneRoleAttribute)
    for n in plan.nodesWith("data-ct-tab-pane"): tabs.add n.attr("data-ct-tab-pane")
    checkpoint("panes " & $panes & " tabs " & $tabs)
    # The stack kept its other two tabs; the tab that slid into the
    # Timeline's place is the one shown.
    ck tabs == @["editor", "eventLog", "terminalOutput"]
    ck panes == @["editor", "terminalOutput"]

suite "PLAT-51 GPUI: list-pane scrollbars are scrubbers over the whole list":

  test "the Event Log's track spans all 70 events; its end shows the last":
    var trace = ""
    let before = windowPlan("", noir)
    ck before.scrubInt("eventLog", "total") == 70
    ck before.scrubInt("eventLog", "first") == 0
    ck before.scrubber("eventLog").attr("data-ct-scrub-known") == "true"
    let after = windowPlan("scrub:eventLog:track:1000", noir, trace = trace)
    let rows = after.nodesWith("data-row-index").len
    checkpoint("rows shown " & $rows & ", first " &
               $after.scrubInt("eventLog", "first"))
    ck rows > 0
    ck rows < 70                      # the pane holds a window, not the log
    # THE LAST ROWS OF THE WHOLE LOG: first + shown == total.
    ck after.scrubInt("eventLog", "first") + rows == 70
    # …and the press moved the VIEW, not the debugger.
    ck after.executionLine == before.executionLine
    ck trace.countLines("eventlog top=") == 1
    # The track's start brings the first row back.
    let back = windowPlan("scrub:eventLog:track:1000,scrub:eventLog:track:0",
                          noir)
    ck back.scrubInt("eventLog", "first") == 0

  test "the Call Trace's track spans all 603 calls; the press is not a jump":
    var trace = ""
    let before = windowPlan("", calls)
    ck before.scrubInt("calltrace", "total") == 603
    let after = windowPlan("scrub:calltrace:track:1000", calls, trace = trace)
    checkpoint(trace)
    var indices: seq[int] = @[]
    for n in after.nodesWith(CallRowAttribute):
      indices.add parseInt(n.attr(CallRowAttribute))
    ck indices.len > 0
    ck max(indices) == 602              # the LAST call of the whole trace
    ck after.scrubInt("calltrace", "first") > 500
    # Not the call row under the track: no jump, the debugger stays.
    ck trace.countLines("calltrace jump") == 0
    ck after.executionLine == before.executionLine
    # The current call is marked on the track — the module's, at the entry
    # — and the press did not move it (it moved the view, not the debugger).
    let marksBefore = before.nodesWith(ListMarkAttribute)
    let marks = after.nodesWith(ListMarkAttribute)
    ck marksBefore.len == 1
    ck marks.len == 1
    ck marks[0].attr(ListMarkAttribute) == marksBefore[0].attr(ListMarkAttribute)
    ck parseInt(marks[0].attr(ListMarkAttribute)) < 3

  test "a held thumb dragged to the end follows, one fetch per motion at most":
    var trace = ""
    let plan = windowPlan("scrub:calltrace:drag:0:1000", calls, trace = trace)
    # The view followed every pointer event of the drag (11 motions and the
    # release), and the engine was asked for a window at most once per
    # event — fewer, since a window already held is not asked for again.
    let followed = trace.countLines("calltrace top=")
    var loads = 0
    for line in trace.splitLines:
      let at = line.find("loads=")
      if "calltrace top=" in line and at >= 0:
        loads = parseInt(line[at + 6 .. ^1].split(' ')[0])
    checkpoint("pointer events followed " & $followed & ", window reads " &
               $loads)
    ck followed >= 12
    ck loads >= 1
    ck loads <= followed
    var indices: seq[int] = @[]
    for n in plan.nodesWith(CallRowAttribute):
      indices.add parseInt(n.attr(CallRowAttribute))
    ck max(indices) == 602
    ck trace.countLines("calltrace jump") == 0

suite "PLAT-51 GPUI: values, the caret, menus, the omnibox, the pointer":

  test "a changed value takes the desktop's accent; nothing at the entry":
    let entry = windowPlan("", calc)
    ck entry.nodesWith(StateChangedAttribute).len == 0
    let stepped = windowPlan("", calc, pre = @["--replay-ops=next=3"])
    let changed = stepped.nodesWith(StateChangedAttribute)
    checkpoint("changed rows: " & $changed.len)
    ck changed.len > 0
    var lit = 0
    for row in changed:
      if StateChangedColour in row.colourOfText: inc lit
    ck lit == changed.len
    # No badge text anywhere.
    ck not stepped.textOf.contains("[MOD]")
    # An unchanged row's text has no accent: the entry's rows.
    var plain = 0
    for row in entry.nodesWith(StateRowAttribute):
      if StateChangedColour notin row.colourOfText: inc plain
    ck plain == entry.nodesWith(StateRowAttribute).len

  test "the value history opens under its row; its entries are navigation rows":
    var trace = ""
    let plan = windowPlan("click:statecontrol:history:__name__", calc,
                          pre = @["--replay-ops=next=3"], trace = trace)
    let entries = plan.nodesWith(StateHistoryEntryAttribute)
    checkpoint(trace)
    ck entries.len > 0
    ck trace.contains("history __name__")
    # Each entry names a recording position (its ticks).
    for e in entries:
      ck e.attr(StateHistoryEntryAttribute).len > 0
    let lit = plan.nodesWith(StateControlAttribute)
    ck lit.len > 0

  test "a click in the code places the caret, apart from the pointer":
    let plan = windowPlan("click:code:31@5:left", calc)
    let carets = plan.nodesWith(EditorCaretAttribute)
    ck carets.len == 1
    ck carets[0].attr(EditorCaretAttribute) == "31:5"
    # The execution pointer did not move to it.
    ck plan.executionLine == 1

  test "Shift + right-click opens the same menu, with no hint row":
    let plain = windowPlan("click:code:31:right", calc)
    let shifted = windowPlan("click:code:31:right:shift", calc)
    let a = plain.menuEntries
    let b = shifted.menuEntries
    checkpoint($b)
    ck a.len > 0
    ck b == a
    ck "Add tracepoint" in b
    for e in b:
      ck not e.contains("Shift + right-click")

  test "the omnibox is on the editor's ground and foreground in every state":
    for ops in ["", "key:p:control", "key:p:control,key:a"]:
      let plan = windowPlan(ops, calc)
      let field = plan.nodesWith("data-ct-omnibar")
      ck field.len == 1
      ck field[0]{"styles"}{"bg"}.getStr == EditorGround
    let typed = windowPlan("key:p:control,key:a", calc)
    ck typed.nodesWith("data-ct-omnibar")[0]{"styles"}{"text_color"}.getStr ==
       EditorTextColour
    let results = typed.nodesWith("data-ct-omnibar-results")
    ck results.len == 1
    ck results[0]{"styles"}{"bg"}.getStr == EditorGround

  test "the execution pointer is the desktop's arrow, never ▶":
    let plan = windowPlan("", calc)
    let marks = plan.nodesWith(PointerMarkAttribute)
    ck marks.len == 1
    ck marks[0].attr(PointerMarkAttribute) == "highlight_line_arrow.svg"
    ck not plan.textOf.contains("▶")

suite "PLAT-51 GPUI plan: assertion count":
  test "every assertion ran":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
