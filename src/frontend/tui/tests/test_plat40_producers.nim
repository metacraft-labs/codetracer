## PLAT-40 — the three panes the vocabulary expresses, fed by production
## producers, drawn on every front-end that draws them, and read back off the
## screens.
##
## Run (the `tui` lane's flags; it links isonim-tui):
##   nim c -r --path:src/frontend/viewmodel <tui lane flags> \
##     src/frontend/tui/tests/test_plat40_producers.nim
##
## ## WHAT IS ASSERTED, AND AGAINST WHAT
##
## 1. **THE PRODUCERS, ON THE SHIPPED PATH, OVER THE RECORDING'S OWN DATA.** A
##    real `replay-server` on the `calc` recording, opened by the function both
##    native front-ends open recordings with (`native_host.openLocalTrace`) and
##    fed by the producers both call (`loadRecordingPanes`, `loadStopPanes`,
##    `HeadlessDebugSession.toggleBreakpoint`). Each pane's census is taken
##    through the product's own `PaneView.report` BEFORE the producers run —
##    it must be a report, which is the census's armed "no" — and after, when
##    it must be data. The rows are then checked against oracles that share no
##    code with the product: the event log against the program's own stdout
##    (`python3 calc/main.py`, run here), the call trace against the `def`s in
##    the program's source, the breakpoint list against the line asked for.
## 2. **ONE DECODER.** `callLineOf` is what a calltrace row IS on every front-end
##    (PLAT-40 found the native and desktop decoders naming rows differently);
##    its rules are asserted, and the response the engine really sent is
##    decoded to the rows the store holds.
## 3. **THE PRODUCER PARTITION.** For each pane, the production procedures that
##    write its rows are EXACTLY a declared set — both set differences empty,
##    the cardinality asserted on both sides — and no procedure defined under a
##    `tests/` directory writes them. A pane fed only by a test helper is the
##    campaign's signature defect.
## 4. **`DIFF-9` — ONE PRODUCER, THE SURFACES THAT DRAW THE PANE.** The shipped
##    terminal's screen is composited in this process (`plainFrame`, the
##    compositor `--headless` prints) under the arrangement
##    `src/tests/visual/plat40-layout.json` describes, and read into PLAT-39's
##    domain types by `terminal_reading`; the native window and the desktop were
##    read off their PIXELS by `vision_producer` into the committed
##    `src/tests/visual/plat40-readings.json`. The three are compared as domain
##    values, never through the ViewModel they would otherwise share.
##
##    **THE SURFACES ARE A MEASURED POPULATION, PER PANE.** The terminal's spec
##    gives the `calltrace` pane kind to its CALL STACK
##    (`app/views/shell.paneTitle`), fed by `stackTrace`, so the terminal draws
##    no call trace: the call trace is compared on two surfaces and the event
##    log and the breakpoint list on three.
##
## No mocks: a real recording, a real `replay-server`, the real session, store,
## ViewModels, views and compositor. The desktop and native-window readings are
## measurements of the shipped binaries, committed as values (the frames are
## gitignored, PLAT-35's reason).

import std/[json, os, osproc, sequtils, sets, strutils, tables, unittest]

import codetracer_embed
import headless_session
import store/types as store_types
import store/replay_data_store
import backend/stdio_backend
import viewmodels/[calltrace_vm, event_log_vm, point_list_vm]
import headless_app/layout_model
import ../../view_vocabulary/pane_views
import ../../../common/value_presentation
import ../app/runtime
import ../app/tui_app
import ../app/theme/capabilities
import ../app/layout/persistence
import ../host/native_host
import ../host/tui_session
import ../host/terminal_driver
import ../../../tests/visual/screen_oracle/[domain_models, pane_grammar,
                                             screen_reading, terminal_reading]
import ./fixtures/fixture_provider

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())

const
  Cols = 200
  Rows = 60
  ProgramSource = "test-programs/calc/main.py"
  ExpectedPanes = [paneCalltrace, paneEventLog, panePointList]
    ## PLAT-40's three: the members of `PaneVocabularyPanes` that had no
    ## production producer.

proc caps(): TerminalCapabilities =
  resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"),
    initCapabilityFlags())

proc scenario(): JsonNode =
  parseJson(readFile(repo / "src/tests/visual/plat40-scenario.json"))

proc programStdout(): seq[string] =
  ## THE ORACLE THAT SHARES NO CODE WITH THE PRODUCT: the program, run.
  let py = findExe("python3")
  doAssert py.len > 0, "PLAT-40 needs python3 to run the calc program"
  let (output, rc) = execCmdEx(py & " " & quoteShell(repo / ProgramSource))
  doAssert rc == 0, "calc exited " & $rc & ": " & output
  for line in output.splitLines():
    if line.len > 0: result.add line

proc programDefs(): HashSet[string] =
  ## Every function the program defines — what a call-trace row may name.
  for line in lines(repo / ProgramSource):
    let s = line.strip()
    if s.startsWith("def "):
      result.incl s[4 ..< s.find('(')]

proc paneOf(kind: PaneKind; s: HeadlessDebugSession): PaneView =
  let vm: ViewModel =
    case kind
    of paneCalltrace: ViewModel(s.session.calltraceVM)
    of paneEventLog: ViewModel(s.session.eventLogVM)
    of panePointList: ViewModel(s.session.pointListVM)
    else: nil
  paneView(kind, vm, GpuiPanelBudget, "tui")

# ===========================================================================
suite "PLAT-40 1 — the producers, on the shipped path, over the recording's own data":
# ===========================================================================

  let resolution = resolveFixture("calc")
  doAssert resolution.outcome != foMissingPrereq,
    missingPrereqMessage(resolution.spec, resolution.detail)
  let s = openLocalTrace(resolution.tracePath)
  var before: Table[PaneKind, string]
  for k in ExpectedPanes: before[k] = paneOf(k, s).report
  let loaded = s.loadRecordingPanes()
  let stop = s.loadStopPanes()

  test "the census is ARMED: over a store no producer has written, each pane is a report":
    # The census's "no". Fresh ViewModels over a FRESH store on the live
    # backend: nothing has decoded anything into it, so each pane must answer
    # with its report — a census that answered DATA here could not tell a fed
    # pane from an unfed one.
    let fresh = createReplayDataStore(s.backend.toBackendService())
    let vms: array[3, ViewModel] = [ViewModel(createCalltraceVM(fresh)),
                                    ViewModel(createEventLogVM(fresh)),
                                    ViewModel(createPointListVM(fresh))]
    for i, k in ExpectedPanes:
      let report = paneView(k, vms[i], GpuiPanelBudget, "tui").report
      checkpoint($k & ": " & report)
      ck report.len > 0

  test "before the shared producers run, the call trace and the breakpoints are reports and the event log is not":
    # MEASURED, and recorded as the fact it is: the event log is fed AT OPEN,
    # by `EventLogVM`'s own `ct/event-load` effect — the desktop's producer —
    # before either native producer is called. The other two panes are
    # reports until theirs run.
    checkpoint($before)
    ck before[paneCalltrace].len > 0
    ck before[panePointList].len > 0
    ck before[paneEventLog].len == 0

  test "a producer that runs and loads nothing fails BY NAME":
    # `PLAT35-PD3`'s lesson: "ran" is a claim about raising, and the gate is
    # on what ARRIVED. Each flag is the store's row count, not a return code.
    ck loaded.events
    ck loaded.calltrace
    ck stop.locals

  test "each pane's census moves from REPORT to DATA — the call trace":
    let pv = paneOf(paneCalltrace, s)
    checkpoint(pv.report)
    ck pv.report.len == 0
    ck pv.root.options.len > 0

  test "each pane's census moves from REPORT to DATA — the event log":
    let pv = paneOf(paneEventLog, s)
    checkpoint(pv.report)
    ck pv.report.len == 0
    ck pv.root.rows.len > 0

  test "the event log's rows ARE the program's output, in order and distinct":
    # `PLAT35-PD2`: the desktop's table drew ONE ROW SIX TIMES. The rows are
    # checked against what the program printed, not counted.
    let want = programStdout()
    let rows = s.session.store.eventLog.rows.val
    var got: seq[string] = @[]
    for r in rows: got.add r.value.strip(chars = {'\n', '\r'})
    checkpoint("program: " & $want & " | log: " & $got)
    ck want.len == 6
    ck got == want
    ck got.toHashSet.len == got.len

  test "every call-trace row names a function the program defines":
    let defs = programDefs()
    var named, markers = 0
    var calls = initHashSet[string]()
    for line in s.session.store.calltrace.lines.val:
      if line.name.startsWith("<") and line.name.endsWith(">"):
        inc markers   # `<__main__>`, `<end of program>`: the module's frame
      else:
        checkpoint("row: " & line.name)
        ck line.name in defs
        calls.incl line.name
        inc named
    ck named > 0
    ck markers >= 1
    # AND THE DEFINED FUNCTIONS THE PROGRAM CALLS ARE ALL THERE — a trace that
    # dropped a frame kind would still satisfy the line above.
    for f in ["main", "evaluate", "apply_op", "add", "sub", "mul", "div"]:
      checkpoint("expected a call to " & f)
      ck f in calls

  let bpFile = s.getCurrentFile()
  let bpLine = scenario()["breakpointLine"].getInt

  test "each pane's census moves from REPORT to DATA — the breakpoint list":
    ck s.toggleBreakpoint(bpFile, bpLine)
    let pv = paneOf(panePointList, s)
    checkpoint(pv.report)
    ck pv.report.len == 0
    ck pv.root.options.len == 1
    ck pv.root.options[0].label.startsWith("breakpoint ")

  test "a breakpoint is the row the ENGINE verified; toggled again, the row is gone":
    let rows = s.session.store.pointList.rows.val.filterIt(
      it.kind == PointKindBreakpoint)
    ck rows.len == 1
    ck rows[0].line == bpLine
    ck rows[0].path == bpFile
    ck rows[0].resolution == "verified"
    # The negative half: a pane that only ever appends would keep the row.
    let file = bpFile
    let line = bpLine
    ck s.toggleBreakpoint(file, line)
    ck s.session.store.pointList.rows.val.filterIt(
      it.kind == PointKindBreakpoint).len == 0
    ck paneOf(panePointList, s).report.len > 0

  s.close()

# ===========================================================================
suite "PLAT-40 2 — one decoder: what a call-trace row IS":
# ===========================================================================

  let decoderSession = openLocalTrace(resolveFixture("calc").tracePath)

  test "named by the high-level name, located at the high-level location":
    let l = callLineOf(CallLineWire(rawName: "raw", highLevelFunctionName: "hl",
      path: "low.c", line: 3, highLevelPath: "src.py", highLevelLine: 9,
      depth: 2, count: 0), 7)
    ck l.name == "hl"
    ck l.location.file == "src.py"
    ck l.location.line == 9
    ck l.depth == 2
    ck l.index == 7

  test "falls back to the raw name and the low-level location when they are all it has":
    let l = callLineOf(CallLineWire(rawName: "raw", path: "low.c", line: 3), 0)
    ck l.name == "raw"
    ck l.location.file == "low.c"
    ck l.location.line == 3

  test "children and expansion follow the legacy call-line rules":
    let leaf = callLineOf(CallLineWire(rawName: "f"), 0)
    ck not leaf.hasChildren
    ck not leaf.isExpanded
    let hidden = callLineOf(CallLineWire(rawName: "f", count: 3,
                                         hiddenChildren: true), 0)
    ck hidden.hasChildren
    ck not hidden.isExpanded
    let shown = callLineOf(CallLineWire(rawName: "f", count: 3), 0)
    ck shown.isExpanded
    let loaded = callLineOf(CallLineWire(rawName: "f", hiddenChildren: true,
                                         loadedChildren: 2), 0)
    ck loaded.hasChildren
    ck loaded.isExpanded

  test "a response is decoded whole, an entry with no call is skipped, a non-section leaves the store alone":
    # A store over the LIVE backend (the decoder never sends; the store's
    # constructor subscribes to the transport, which must exist).
    let store = createReplayDataStore(decoderSession.backend.toBackendService())
    let body = %*{"startCallLineIndex": 10, "totalCallsCount": 3,
      "callLines": [
        {"depth": 0, "content": {"count": 1, "hiddenChildren": false,
          "call": {"rawName": "main", "key": "k0", "children": [],
                   "location": {"path": "m.py", "line": 1,
                                "highLevelPath": "m.py", "highLevelLine": 1,
                                "highLevelFunctionName": "main",
                                "rrTicks": 5}}}},
        {"depth": 1, "content": {"count": 0}},
        {"depth": 1, "content": {"count": 0, "hiddenChildren": false,
          "call": {"rawName": "f", "key": "k2", "children": [],
                   "location": {"path": "m.py", "line": 4,
                                "highLevelPath": "", "highLevelLine": 0,
                                "highLevelFunctionName": "", "rrTicks": 6}}}}]}
    ck store.applyCalltraceResponse(body) == 2
    let lines = store.calltrace.lines.val
    ck lines.mapIt(it.name) == @["main", "f"]
    ck lines.mapIt(it.index) == @[10'i64, 12]
    ck lines[0].callKey == "k0"
    ck lines[0].hasChildren
    ck store.calltrace.totalCallsCount.val == 3
    ck store.applyCalltraceResponse(%*{"other": 1}) == -1
    ck store.calltrace.lines.val.len == 2

  test "the desktop's path and the native path both end in `callLineOf`":
    # §30b: one predicate, one function, every consumer calling it. The
    # desktop decodes a TYPED response and the native front-ends a JSON one,
    # so the two cannot share the parse — they share the decision.
    let desktop = readFile(repo / "src/frontend/ui/calltrace.nim")
    let native = readFile(repo / "src/frontend/viewmodel/headless_session.nim")
    let store = readFile(repo / "src/frontend/viewmodel/store/replay_data_store.nim")
    ck "callLineOf(CallLineWire(" in desktop
    ck "makeCallLine(" notin desktop
    ck "applyCalltraceResponse(" in native
    ck "parseCallLine" notin native
    let apply = store[store.find("proc applyCalltraceResponse*(") .. ^1]
    ck "callLineOf(" in apply[0 ..< apply.find("\nproc ")]

  decoderSession.close()

# ===========================================================================
suite "PLAT-40 3 — the producer partition":
# ===========================================================================

  type Writer = tuple[file, name: string]

  proc isTestPath(f: string): bool =
    "/tests/" in f or f.extractFilename.startsWith("test_")

  proc writersOf(sinkCalls: openArray[string]; sinkName: string): seq[Writer] =
    ## Every procedure under `src/frontend` whose body writes a pane's rows —
    ## calls the store's sink, or assigns the signal — attributed to the
    ## INNERMOST ENCLOSING declaration by indentation, so a nested helper does
    ## not take its parent's call and a `test` block is attributed to nothing.
    for f in walkDirRec(repo / "src/frontend"):
      if not f.endsWith(".nim"): continue
      var stack: seq[(int, string)] = @[]
      for raw in lines(f):
        let code = raw.split('#')[0]
        if code.strip().len == 0: continue
        let indent = code.len - code.strip(trailing = false).len
        while stack.len > 0 and stack[^1][0] >= indent: discard stack.pop()
        let t = code.strip()
        var declared = ""
        for kw in ["proc ", "func ", "method ", "template ", "iterator "]:
          if t.startsWith(kw):
            var n = t[kw.len .. ^1].strip(chars = {'`', ' '})
            var e = 0
            while e < n.len and n[e] in IdentChars: inc e
            declared = n[0 ..< e]
        if declared.len > 0:
          stack.add (indent, declared)
          continue
        if stack.len == 0: continue
        if stack[^1][1] == sinkName: continue   # the sink's own body
        for c in sinkCalls:
          if c in t:
            result.add (f.relativePath(repo), stack[^1][1])
            break

  const Declared = {
    "calltrace": @[
      ("src/frontend/ui/calltrace.nim", "syncCalltraceData"),
      ("src/frontend/viewmodel/collab/backend_snapshots.nim",
       "projectBackendSnapshotToStore"),
      ("src/frontend/viewmodel/store/replay_data_store.nim",
       "applyCalltraceResponse"),
      ("src/frontend/viewmodel/sync/signal_serializer.nim", "applySignalUpdate")],
    "eventLog": @[
      ("src/frontend/ui/event_log.nim", "loadEvents"),
      ("src/frontend/ui/event_log.nim", "onUpdatedEvents"),
      ("src/frontend/viewmodel/store/replay_data_store.nim", "appendLiveEventRow"),
      ("src/frontend/viewmodel/store/replay_data_store.nim", "applyEventLogResponse"),
      ("src/frontend/viewmodel/store/replay_data_store.nim", "clearEventLog")],
    "pointList": @[
      ("src/frontend/viewmodel/store/replay_data_store.nim", "applyTracepointResults"),
      ("src/frontend/viewmodel/store/replay_data_store.nim",
       "applyVerifiedBreakpoints"),
      ("src/frontend/viewmodel/viewmodels/point_list_vm.nim", "setPoints")]}.toTable
  const Sinks = {
    "calltrace": ("updateCalltraceSection", @["updateCalltraceSection(",
                                              "calltrace.lines.val ="]),
    "eventLog": ("applyEventLogRows", @["applyEventLogRows(",
                                        "eventLog.rows.val ="]),
    "pointList": ("applyPointRows", @["applyPointRows(",
                                      "pointList.rows.val ="])}.toTable
  const Fixture = "src/frontend/storybook_components.nim"
    ## The storybook builds demonstration stores and is neither shipped nor a
    ## test; its writers are REPORTED, never counted as producers.

  for pane in ["calltrace", "eventLog", "pointList"]:
    test "the writers of the " & pane & " rows are exactly the declared producers":
      let (sink, calls) = Sinks[pane]
      let all = writersOf(calls, sink)
      var production = initHashSet[Writer]()
      var testDefined: seq[Writer] = @[]
      for w in all:
        if w.file == Fixture: continue
        if isTestPath(w.file): testDefined.add w
        else: production.incl w
      let declared = Declared[pane].toHashSet
      checkpoint("production writers: " & $production)
      checkpoint("undeclared: " & $(production - declared) &
                 " | declared, not found: " & $(declared - production))
      ck (production - declared).len == 0
      ck (declared - production).len == 0
      ck production.len == Declared[pane].len
      ck declared.len == Declared[pane].len
      # NO TEST-ONLY DEFINITION MASQUERADES AS A PRODUCER.
      checkpoint("defined under tests/: " & $testDefined)
      ck testDefined.len == 0

# ===========================================================================
suite "PLAT-40 4 — DIFF-9: the surfaces that draw each pane, compared as domain values":
# ===========================================================================

  let rec = parseJson(readFile(repo / "src/tests/visual/plat40-readings.json"))
  let sc = scenario()

  proc names(r: JsonNode): seq[string] =
    for n in r["value"]: result.add n.getStr

  proc points(r: JsonNode): seq[PointRowModel] =
    for p in r["value"]:
      result.add PointRowModel(kind: p["kind"].getStr,
        fileName: p["fileName"].getStr, lineNumber: p["lineNumber"].getInt)

  proc texts(r: JsonNode): seq[string] =
    for t in r["value"]: result.add compactText(t.getStr)

  # THE TERMINAL'S SCREEN, composited here exactly as `--headless` prints it.
  let resolution = resolveFixture("calc")
  let rt = newTuiRuntime(newTuiApp(), caps(), Cols, Rows)
  let ts = openTuiSession(resolution.tracePath, viewportHeight = Rows - 6)
  ts.setViewportHeight(rt.sourcePaneRows())
  ts.learnExtent()
  for _ in 0 ..< sc["nextSteps"].getInt:
    ts.session.stepForward()
    discard ts.session.drainEvents()
  discard ts.toggleBreakpoint(ts.session.getCurrentFile(),
                              sc["breakpointLine"].getInt)
  ts.refresh(rt)
  let binding = rt.app.enableLayoutBinding(Cols, Rows)
  let restored = binding.adoptLayoutDocument(
    "plat40-layout.json", readFile(repo / "src/tests/visual/plat40-layout.json"))
  let frame = plainFrame(caps(), rt.shellScreenOf().styledRows, Cols, Rows).splitLines()
  let termLog = readTerminalEventLog(frame)
  let termPoints = readTerminalPointList(frame)
  ts.close()

  test "the terminal took the arrangement, and its screen carries the panes":
    checkpoint(restored.message)
    ck restored.status == lrsRestored
    checkpoint(frame.join("\n"))
    ck termLog.isRead
    ck termPoints.isRead

  test "the record is present and provenanced, and both lanes drove one stop":
    ck rec["takenAt"].getStr.len > 0
    ck rec["host"].getStr.len > 0
    ck rec["scenario"] == sc
    ck rec["electronDom"]["scenario"]["breakpointLine"].getInt ==
       sc["breakpointLine"].getInt
    for run in rec["gpuiRuns"]:
      if run["id"].getStr in ["panes", "default"]:
        ck run["settled"].getBool
        ck run["ops"].getStr == sc["gpuiOps"].getStr

  for pane in ["calltrace", "eventLog", "pointList"]:
    test "PLAT-39's reader returns READ, never EMPTY, off both screens — " & pane:
      for surface in [rec["gpui"]["panes"], rec["electron"]["panes"]]:
        checkpoint(pane & ": " & $surface[pane])
        ck surface[pane]["kind"].getStr == "read"
        ck surface[pane]["value"].len > 0

  test "the controls say no: no breakpoint list under the default layout, nothing on a blank screen":
    ck rec["gpui"]["default"]["pointList"]["kind"].getStr == "unreadable"
    ck rec["gpui"]["default"]["pointList"]["reason"].getStr == "region-not-located"
    for pane in ["calltrace", "eventLog", "pointList"]:
      ck rec["gpui"]["blank"][pane]["kind"].getStr == "unreadable"

  # THE SURFACES, PER PANE — a measured population (see the header): the
  # call trace on the two that draw one, the event log and the breakpoint list
  # on all three. The DESKTOP'S DOM reading and the program's own output are
  # the exact references; a PIXEL reading is compared row for row within
  # OCR's one edit (`withinOneEdit`), with names compared by `callNameKey`.

  proc domCalls(): seq[string] =
    for c in rec["electronDom"]["calltrace"]["calls"]: result.add c["name"].getStr

  proc callTraceAgrees(reading: seq[string]): bool =
    ## A pixel reading of the call trace is a PREFIX of the desktop's DOM
    ## reading — each pane shows as many rows as its height holds — row for
    ## row within one edit, and holds a real share of the trace.
    let dom = domCalls()
    result = reading.len >= 10 and reading.len <= dom.len
    for i, n in reading:
      if i >= dom.len: return false
      if not withinOneEdit(compactText(callNameKey(n)),
                           compactText(callNameKey(dom[i]))):
        checkpoint("row " & $i & ": '" & n & "' vs '" & dom[i] & "'")
        result = false

  test "DIFF-9 — the call trace, on the native window":
    ck callTraceAgrees(names(rec["gpui"]["panes"]["calltrace"]))

  test "DIFF-9 — the call trace, on the desktop":
    ck callTraceAgrees(names(rec["electron"]["panes"]["calltrace"]))
    # And the desktop's DOM draws the whole trace the native producer loaded.
    ck domCalls().len == 28

  let wantEvents = programStdout().mapIt(compactText(it))

  proc eventsAgree(reading: seq[string]; exact: bool): bool =
    checkpoint("want " & $wantEvents & "\ngot  " & $reading)
    if reading.len != wantEvents.len: return false
    for i in 0 ..< reading.len:
      if exact:
        if reading[i] != wantEvents[i]: return false
      elif not withinOneEdit(reading[i], wantEvents[i]): return false
    true

  test "DIFF-9 — the event log, on the terminal":
    var term: seq[string] = @[]
    for e in termLog.value.events: term.add compactText(eventText(e.consoleOutput))
    ck eventsAgree(term, exact = true)

  test "DIFF-9 — the event log, on the native window":
    ck eventsAgree(texts(rec["gpui"]["panes"]["eventLog"]), exact = false)

  test "DIFF-9 — the event log, on the desktop":
    var dom: seq[string] = @[]
    for e in rec["electronDom"]["eventLog"]["events"]:
      dom.add compactText(eventText(e["consoleOutput"].getStr))
    ck eventsAgree(dom, exact = true)
    ck eventsAgree(texts(rec["electron"]["panes"]["eventLog"]), exact = false)

  let wantPoints = @[PointRowModel(kind: "breakpoint",
    fileName: sc["breakpointFile"].getStr,
    lineNumber: sc["breakpointLine"].getInt)]

  test "DIFF-9 — the breakpoint list, on the terminal":
    checkpoint($termPoints.value)
    ck termPoints.value.points == wantPoints

  test "DIFF-9 — the breakpoint list, on the native window":
    ck points(rec["gpui"]["panes"]["pointList"]) == wantPoints

  test "DIFF-9 — the breakpoint list, on the desktop":
    var dom: seq[PointRowModel] = @[]
    for p in rec["electronDom"]["pointList"]["points"]:
      dom.add PointRowModel(kind: p["kind"].getStr,
        fileName: p["fileName"].getStr, lineNumber: p["lineNumber"].getInt)
    ck dom == wantPoints
    ck points(rec["electron"]["panes"]["pointList"]) == wantPoints

  test "Content.PointList's arm is LIVE, and the View menu reaches it":
    # The arm was a COMMENTED line until PLAT-40, and the menu entry was
    # commented too; `ci/test/renderer-pane-parity.sh` drops comment lines, so
    # it counted the pane as not dispatched. Asserted on uncommented code.
    proc live(path, needle: string): bool =
      for raw in lines(repo / path):
        let code = raw.split('#')[0]
        if needle in code: return true
    ck live("src/frontend/utils.nim", "of Content.PointList:")
    ck live("src/frontend/utils.nim", "makePointListComponent(")
    ck live("src/frontend/ui_js.nim", "element \"Breakpoints & Tracepoints\", aPointList")

suite "PLAT-40 — assertion tally":
  test "CHECKS":
    echo "CHECKS: ", CHECKS
    check CHECKS > 0
