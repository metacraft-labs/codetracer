## test_cross_renderer_panes.nim — PLAT-21's real-stack integration test.
##
## PLAT-21: *"`test_cross_renderer.nim` extended from generic components to the
## **product's own** views, across all three renderers, on a real recording"*,
## *"the same value renders identically across front-ends at the same budget —
## PLAT-2's purity requirement, now with a third witness"*, and *"keyboard
## contract and state transitions asserted per view, not appearance"*.
##
## ## WHY THE FILE IS HERE AND NOT IN `isonim-gpui/tests/test_cross_renderer.nim`
##
## The milestone names that file, and it is the right ancestor: it already runs
## ONE component across `GpuiRenderer`, `MockRenderer` and isonim's
## `TerminalRenderer`, comparing `textContent` between the instantiations. But
## it lives in **isonim-gpui**, a framework repository that CodeTracer depends
## on. Extending it to *the product's own views* would mean a renderer binding
## importing `codetracer`'s ViewModels — an inverted dependency, and one no
## manifest expresses (`repos/isonim-gpui.toml` knows nothing of this repo).
##
## So the file moved and the SHAPE was extended, which is what the milestone is
## asking for. Three differences from its ancestor, each a strengthening:
##
##   * the components are the **debugger's own panes**, from `pane_views.nim`,
##     built out of the ViewModels a real `replay-server` filled;
##   * the terminal arm is **isonim-tui's widget tree**, not isonim's
##     `terminal_demo` renderer — the same independent oracle PLAT-3's
##     cross-medium suite uses, so what Down does to a list is decided by a
##     library this repository does not own;
##   * the comparison is on **state**, not on `textContent`. Text is appearance
##     and the milestone says not to assert appearance. Value RENDERINGS are
##     compared separately and deliberately, because PLAT-2's purity claim is
##     exactly a claim about bytes.
##
## ## THE THREE ARMS, AND WHICH OF THEM IS INDEPENDENT
##
## Said plainly, because a suite claiming three independent oracles when it has
## one is the weakest thing on this page:
##
##   TERMINAL  INDEPENDENT. `terminal_binding` never calls `applyKey`. It fires
##             a real `keydown` at a real isonim-tui widget and reads the answer
##             out of `ListViewWidget.highlightedIndex`, `TreeWidget.cursor`,
##             `DataTableWidget.selectedRow`.
##   WEB       routes the key through `behaviour.applyKey` after translating it
##             into the DOM's spelling, and reads `data-*` attributes back off
##             the rendered elements.
##   GPUI      routes the key through **the Rust shim's own event dispatcher**
##             — `gpui_dispatch_event` crosses the FFI boundary, the Rust side
##             finds the node's listener, and the callback comes back through
##             `globalDispatcher` — and then calls `applyKey`. The state is read
##             back out of the shim's element store across the same boundary.
##
## So the keyboard claim has ONE independent oracle and two arms that agree with
## the vocabulary's own machine. The GPUI arm's independence is in the
## TRANSPORT and the STORAGE, not in the decision: what it can catch is a key
## that reached the wrong listener, an attribute the renderer mangled, a node
## the renderer dropped — and it caught two of those three (`gpui_gaps`
## `PLAT21-VG2`, and the closure defect `gpui_binding.keyHandler`'s header
## records).
##
## ## §14: THE SHARED CODE PATH, AND THE PROOF THAT THE COMPARISON CAN GO RED
##
## PLAT-20 measured what a shared helper costs an agreement test:
## `distributeExtent` is divided through by both projections, so a change to it
## moved both sides identically and the agreement stayed 8/8 green. This suite
## has the same shape in one place — the web and GPUI arms read their facts
## through `fact_reader.readAttributeFacts` — and the last case in this file is
## the demonstration that the comparison can still fail, over the same reducer.
##
## ## NO MOCKS
##
## A real `.ct` trace recorded by the real Python recorder, opened by a real
## `replay-server` child process, driven through the real `HeadlessDebugSession`
## and the real ViewModels. The two names that read like mocks are the two
## `test_view_vocabulary_cross_medium.nim` already justifies and this file
## inherits verbatim: `isonim.testing.mock_dom.MockRenderer` is one of the four
## renderer backends isonim SHIPS (it satisfies the same compile-time
## `checkRendererBackend` proof `WebRenderer` does, and is the backend the
## product's own non-JS overload of every `isonim_*_view.nim` compiles against;
## `WebRenderer` compiles only under `nim js` against a live DOM and this lane
## compiles C), and `isonim_tui.testing.harness.TerminalTestHarness` is
## isonim-tui's own headless bundle — renderer, driver, compositor, animator,
## focus manager and a virtual clock — which every one of that library's widget
## suites constructs. Neither is a stand-in for the thing it names.
##
## **The BackendService is real too**, and that is this file's other errand:
## PLAT-20 left `syncSessionLayouts` ungraded as residue 7 *"because closing it
## honestly costs a `BackendService`"*, and named a mock or a Tier-2 recording
## as the two ways. This suite already has the second, so the case is here.
##
## ## COUNTED ASSERTIONS (Verification-Harness-Traps §4c)

import std/[algorithm, options, os, sequtils, sets, strutils, tables, unittest]

import isonim/core/[signals, computation]
import isonim/viewmodel
import isonim/testing/mock_dom
import isonim_tui/testing/harness
import isonim_gpui/renderer as gpui_renderer
import isonim_gpui/bindings as gpui_bindings

import headless_session
import backend/stdio_backend
import store/types as store_types
import viewmodels/state_vm
import viewmodels/calltrace_vm
import viewmodels/event_log_vm
import viewmodels/point_list_vm
import viewmodels/point_collection_source
import headless_app/layout_model
import gpui/app/shell as gpui_shell

import ../../../common/view_vocabulary
import ../../../common/value_presentation
import ../../../common/project_definitions
import ../../view_vocabulary/pane_views
import ../../view_vocabulary/terminal_binding as tbind
import ../../view_vocabulary/web_binding as wbind
import ../../view_vocabulary/gpui_binding as gbind
import ./fixtures/fixture_provider

var asserted = 0
var countedAssertions = 0

template ck(condition: untyped) =
  inc asserted
  inc countedAssertions
  check condition

template expectCount(expected: int) =
  if asserted != expected:
    checkpoint("assertion count is " & $asserted & ", expected " & $expected)
  check asserted == expected

template resetCount() =
  asserted = 0

const
  FixtureName = "calc"
    ## The smallest fixture that fills all four panes. Measured on 2026-09-15:
    ## twelve locals, twenty-eight call lines and six recorded events, six
    ## steps in.
  StepsIn = 6
    ## Far enough that `main`'s frame has locals. The number is here rather
    ## than inline because the three panes below all depend on the SAME stop,
    ## and a stop that moved would move all three.
  AnchorText = "def add("
    ## A line the recorded program really contains, used as a tracepoint
    ## anchor. Asserted to be present in the recorded source BEFORE it is used,
    ## so an edit to the program reddens the case instead of silently changing
    ## what "a resolved point" means.
  MissingAnchorText = "def this_function_does_not_exist("
    ## And one it does not, so the tracepoint list carries an UNRESOLVED row —
    ## which `pane_views` renders as a disabled option, which is what the
    ## keyboard case below asserts motion skips.

# ---------------------------------------------------------------------------
# One real session, shared by every case. Opening a recording costs a process
# and a DAP handshake; doing it per case would be three minutes of replay
# server for no additional evidence.
# ---------------------------------------------------------------------------

type
  Live = object
    session: HeadlessDebugSession
    sourcePath: string
    sourceLines: seq[string]

var live: Live
var liveResolved = false
var liveSkip = ""

proc openLive() =
  if liveResolved or liveSkip.len > 0: return
  let res = resolveFixture(FixtureName)
  if res.outcome == foMissingPrereq:
    # LOUD AND COUNTED, per the fixture corpus's own rule. `replay-server` is
    # never a skip — `findReplayServer` raises — so reaching here means the
    # RECORDER is missing, which is a partial environment rather than a broken
    # one.
    liveSkip = missingPrereqMessage(res.spec, res.detail)
    echo liveSkip
    return
  let s = newHeadlessDebugSession(res.tracePath, findReplayServer())
  for _ in 0 ..< StepsIn:
    s.stepForward()
    discard s.drainEvents()
  s.requestAndLoadLocals()
  s.requestAndLoadCalltrace()
  # THE EVENT LOG GOES IN THROUGH ITS OWN PRODUCER NOW, and this line is the
  # whole of it. `requestAndLoadEventLog` sends `ct/event-load` and feeds the
  # answer to `ReplayDataStore.applyEventLogResponse`, which is
  # `EventLogVM.eventRows` — exactly as `requestAndLoadLocals` above feeds
  # `applyLocalsResponse` and fills `StateVM.currentVariables`.
  #
  # **THIS USED TO BE A LOOP**, and the loop was the evidence that the plumbing
  # did not exist: it took the sequence this call returns and pushed each row
  # into the ViewModel by hand through `appendLiveDebuggerStop` — a door meant
  # for the LIVE debugger head, not for persisted events — because nothing in
  # the repository connected the backend's answer to the signal. The data was
  # always the recording's; what was missing was the wire between them. The
  # loop's disappearance, with the count below unchanged at six, is what says
  # the wire is there.
  discard s.requestAndLoadEventLog(0, 50)
  live.session = s
  live.sourcePath = s.getCurrentFile()
  live.sourceLines =
    if fileExists(live.sourcePath): readFile(live.sourcePath).splitLines()
    else: @[]
  liveResolved = true

proc publishTracepoints() =
  ## Fill `PointListVM` through PLAT-11's REAL producer.
  ##
  ## **The sentence here used to read "`point_list_vm.setPoints` has two call
  ## sites and neither is a backend response". It was stale on both halves and
  ## is corrected, 2026-09-17.** There are three call sites (PLAT-22's
  ## verification found the third), and one of them IS a backend response since
  ## `points` became `ReplayDataStore.pointList.rows`:
  ## `applyTracepointResults` writes a row per spec of a `ct/run-tracepoints`
  ## sweep, which `tui/tests/test_event_log_jump.nim` asserts on a real
  ## recording.
  ##
  ## The project-definitions producer is still the right one for THIS file: a
  ## sweep reports where a tracepoint fired, and what these cases need is a
  ## list that deliberately contains a point which could NOT be located — which
  ## only an anchor resolved against source text can produce. `resolveCollection`
  ## anchors each point against the RECORDING'S OWN SOURCE LINES, read off disk
  ## at the path the backend reported, so a resolved point is resolved against
  ## the program that was recorded rather than against a fixture.
  let linesRef = live.sourceLines
  let path = live.sourcePath
  proc sources(p: string): SourceFile {.noSideEffect, gcsafe, raises: [].} =
    if p == path: SourceFile(present: true, lines: linesRef)
    else: SourceFile(present: false, lines: @[])
  let collection = PointCollection(
    name: "plat21",
    enabledByDefault: true,
    scope: "",
    file: ".codetracer/points.toml",
    points: @[
      PointDefinition(kind: pkTracepoint, path: path,
                      anchor: PointAnchor(text: AnchorText, occurrence: 1,
                                          offset: 0, line: 0),
                      label: "on add"),
      PointDefinition(kind: pkTracepoint, path: path,
                      anchor: PointAnchor(text: MissingAnchorText,
                                          occurrence: 1, offset: 0, line: 0),
                      label: "on a line that is not there"),
      PointDefinition(kind: pkBreakpoint, path: path,
                      anchor: PointAnchor(text: AnchorText, occurrence: 1,
                                          offset: 1, line: 0),
                      label: "inside add")])
  live.session.session.pointListVM.applyCollections(
    @[resolveCollection(collection, sources)],
    defaultEnabled(@[collection]))

proc vmFor(pane: PaneKind): ViewModel =
  let s = live.session.session
  case pane
  of paneState: ViewModel(s.stateVM)
  of paneCalltrace: ViewModel(s.calltraceVM)
  of paneEventLog: ViewModel(s.eventLogVM)
  of panePointList: ViewModel(s.pointListVM)
  else: nil

# ---------------------------------------------------------------------------
# Three renderers over one pane view
# ---------------------------------------------------------------------------

type
  ThreeWay = object
    ## ONE `ViewNode` tree, rendered by three bindings.
    ##
    ## THREE SEPARATE MODELS, deliberately, exactly as PLAT-3's cross-medium
    ## suite keeps two: `applyKey` mutates the `ViewNode` it is given, so a
    ## shared tree would let the web arm move the object the terminal arm was
    ## built from and the comparison would be reading one state three times.
    terminal: TerminalBinding
    web: WebBinding[MockRenderer, MockNode]
    gpui: GpuiBinding

proc buildThreeWay(pane: PaneKind; budget: Budget): ThreeWay =
  gpui_reset_tree()
  resetCallbacks()
  let h = newTerminalTestHarness(220, 80)
  var mr = MockRenderer()
  result.terminal = tbind.bindView(h, paneView(pane, vmFor(pane), budget,
                                               "terminal").root)
  result.web = wbind.renderWeb[MockRenderer, MockNode](
    mr, paneView(pane, vmFor(pane), budget, "web").root)
  result.gpui = gbind.renderGpui(GpuiRenderer(),
    paneView(pane, vmFor(pane), budget, "gpui").root)

proc childTextOf(b: WebBinding[MockRenderer, MockNode]; id: string): string =
  ## **The node's OWN text**, out of the mock DOM. The web column's copy of the
  ## bytes PLAT-2's purity requirement is about.
  ##
  ## `web_binding.renderNode` puts a `Tree` row's label in a leading `span`, so
  ## the first child is the label and the trailing children are the view's own
  ## children. `mock_dom.textContent` on the whole element would concatenate
  ## the subtree, which is why this reads the first child rather than the node.
  ##
  ## It lives here rather than in `web_binding.nim` because it is specific to
  ## `MockRenderer`'s node type, and the binding is generic over the backend.
  if id notin b.nodes: return ""
  let first = b.renderer.firstChild(b.nodes[id])
  if first.isNil: return ""
  mock_dom.textContent(first)

proc factsOf(fs: seq[StateFact]): Table[string, string] =
  for f in fs:
    result[f.id & "." & f.field] = f.value

proc terminalFacts(t: ThreeWay): Table[string, string] =
  factsOf(tbind.readTerminalFacts(t.terminal))

proc webFacts(t: ThreeWay): Table[string, string] =
  factsOf(wbind.readWebFacts(t.web))

proc gpuiFacts(t: ThreeWay): Table[string, string] =
  factsOf(t.gpui.readGpuiFacts())

proc divergences(t: ThreeWay): seq[string] =
  ## Every key on which the three arms do not all say the same thing.
  let tf = terminalFacts(t)
  let wf = webFacts(t)
  let gf = gpuiFacts(t)
  var keys: seq[string] = @[]
  for k in tf.keys: keys.add k
  for k in wf.keys:
    if k notin tf: keys.add k
  for k in gf.keys:
    if k notin tf and k notin wf: keys.add k
  keys.sort()
  for k in keys:
    let a = tf.getOrDefault(k, "<absent on terminal>")
    let b = wf.getOrDefault(k, "<absent on web>")
    let c = gf.getOrDefault(k, "<absent on gpui>")
    if a != b or b != c:
      result.add k & ": terminal=" & a & " web=" & b & " gpui=" & c

# THESE ARE TEMPLATES AND NOT PROCS. `unittest.check` assigns
# `testStatusIMPL`, which the `test` template injects as a LOCAL and which
# `unittest` ALSO declares as a module-level fallback — so a `check` inside an
# ordinary `proc` compiles, sets the global, and the test reports `[OK]` with
# the failed comparison printed directly above it
# (Verification-Harness-Traps §13). PLAT-3's suite walked into it on its first
# run and this file inherits the remedy.

proc divergencesAfter(t: ThreeWay; after: string): seq[string] =
  ## `divergences`, with the step's LABEL carried into the call.
  ##
  ## The parameter is not read, and that is deliberate.
  ## Verification-Harness-Traps §17a: a mutation arm's `because` is a quotation
  ## of the failure text, `unittest` prints an assertion's AST **as substituted
  ## at the call site**, and a template-local `let` is gensym'd — so
  ## `ck d.len == 0` printed ``d`gensym229.len == 0``, whose NUMBER IS NOT
  ## STABLE ACROSS COMPILATIONS. That is §17a's second trap, and it was found
  ## by deriving a `because` and reading it.
  ##
  ## Passing the label makes the substituted text stable AND unique per call
  ## site, which is §17a's own closing rule and its bonus: no two `allThreeAgree`
  ## calls can derive the same `because`, so an arm cannot be attributed to a
  ## step it did not break. It also makes the transcript name the step.
  divergences(t)

template allThreeAgree(t: ThreeWay; after: string) =
  block:
    let d = divergencesAfter(t, after)
    if d.len > 0:
      checkpoint after & ":\n  " & d.join("\n  ")
  # THE POSITIVE CONTROL FIRST (§4): three bindings that rendered nothing
  # produce three empty projections, and three empty projections agree about
  # everything.
  #
  # Both assertions call through rather than reading a local, for the §17a
  # reason `divergencesAfter`'s own comment gives.
  ck terminalFacts(t).len > 0
  ck divergencesAfter(t, after).len == 0

template allThreeSay(t: ThreeWay; key, value: string) =
  block:
    let tf = terminalFacts(t).getOrDefault(key, "<absent>")
    let wf = webFacts(t).getOrDefault(key, "<absent>")
    let gf = gpuiFacts(t).getOrDefault(key, "<absent>")
    if tf != value or wf != value or gf != value:
      checkpoint key & ": terminal=" & tf & " web=" & wf & " gpui=" & gf &
        " expected=" & value
  # AND THE ASSERTIONS CALL THROUGH, so the substituted text carries this call
  # site's own `key` and `value` instead of a gensym'd local. See
  # `divergencesAfter`.
  ck terminalFacts(t).getOrDefault(key, "<absent>") == value
  ck webFacts(t).getOrDefault(key, "<absent>") == value
  ck gpuiFacts(t).getOrDefault(key, "<absent>") == value

template sendAll(t: ThreeWay; id: string; k: Key; ch = ' ') =
  ## The SAME vocabulary key, spelled each medium's own way by its own binding
  ## and delivered through each medium's own transport. That translation is the
  ## only thing that differs, which is the claim under test.
  ck tbind.sendKey(t.terminal, id, k, ch)
  discard wbind.sendKey[MockRenderer, MockNode](
    t.web, id, k, (if k == kChar: $ch else: ""))
  discard t.gpui.sendKey(id, k, (if k == kChar: $ch else: ""))

template liveTest(name: string; body: untyped) =
  ## A case that needs the recording.
  ##
  ## The fixture corpus's rule (`fixture_provider.nim`'s header, and
  ## `Silent-Self-Pass-Audit-2026-08-23.md`): `replay-server` is never a skip —
  ## `findReplayServer` RAISES — and a missing RECORDER is a skip that must be
  ## LOUD and COUNTED. So a skipped case here prints the one greppable
  ## `MISSING-PREREQ SKIP:` line, asserts that the line is NAMED rather than
  ## asserting nothing, and contributes exactly one assertion — which makes the
  ## file's own tally at the bottom able to tell a skipped run from a verified
  ## one instead of both reporting the same number.
  ##
  ## A `template` wrapping the whole body, rather than an early `return` from a
  ## guard: `unittest`'s `test` is itself a template and `return` is not legal
  ## inside it.
  test name:
    resetCount()
    openLive()
    if liveSkip.len > 0:
      checkpoint liveSkip
      ck liveSkip.startsWith(MissingPrereqSkipPrefix)
      expectCount(1)
    else:
      body

# ---------------------------------------------------------------------------

suite "PLAT-21: the product's panes, in the vocabulary, on a real recording":

  liveTest "the recording opened and the four panes have real content":
    # THE NON-VACUITY FLOOR for every case below it. Each of these is a number
    # the RECORDING produced, so a session that opened and answered nothing
    # fails here by name rather than making twelve comparisons of empty sets.
    ck live.session != nil
    ck live.sourcePath.endsWith("main.py")
    ck live.sourceLines.len > 10
    ck AnchorText in readFile(live.sourcePath)
    ck MissingAnchorText notin readFile(live.sourcePath)
    ck live.session.session.stateVM.currentVariables.val.len == 12
    ck live.session.session.calltraceVM.visibleLines.val.len == 28
    ck live.session.session.eventLogVM.eventRows.val.len == 6
    publishTracepoints()
    ck live.session.session.pointListVM.points.val.len == 3
    expectCount(9)

  liveTest "the event rows are the recording's own output, not a well-formed absence":
    # **THE COUNT ABOVE CANNOT TELL A RENDERING FROM AN APOLOGY**, and that is
    # not a general worry about counts — it is this pane's specific one.
    # `eventLogPaneView` answers *"no events have been loaded"* for an empty
    # row set, which for every shipped front-end WAS the correct output until
    # the producer this file now exercises existed. So `len == 6` is asserted
    # above as a floor and the CONTENT is asserted here, against the program
    # the recorder ran.
    let rows = live.session.session.eventLogVM.eventRows.val
    ck rows.len == 6
    # THE STORE AND THE VIEWMODEL ARE THE SAME ROWS. Not "both have six":
    # `EventLogVM.eventRows` IS `store.eventLog.rows`, so a ViewModel that had
    # gone back to holding its own copy would show as a difference in the
    # FIRST ROW'S BYTES rather than in a length.
    let stored = live.session.session.store.eventLog.rows.val
    ck stored.len == rows.len
    ck stored.len > 0 and stored[0].value == rows[0].value
    # `test-programs/calc/main.py` prints `"%s = %d" % (expression, value)` once
    # per expression and then `"checksum = %d"`. Both halves are asserted, so a
    # decoder that answered six rows of empty strings, or six copies of one
    # row, fails here rather than passing a shape check.
    var withEquals = 0
    var distinctValues: seq[string] = @[]
    for row in rows:
      if "=" in row.value: inc withEquals
      if row.value notin distinctValues: distinctValues.add row.value
    ck withEquals == 6
    ck distinctValues.len == 6
    ck rows[^1].value.contains("checksum = ")
    ck rows[0].value.contains(" = ")
    # EVERY FIELD THE DECODER FILLS, asserted on the recording rather than on a
    # zero value. `eventIndex` is the row's position in the WHOLE log, the tick
    # is where selecting the row seeks, and `file` is the path the backend
    # reported — the same one the source pane opened.
    var wrongIndex = 0
    var wrongFile = 0
    var nonAscending = 0
    for i, row in rows:
      if row.eventIndex != i: inc wrongIndex
      if row.file != live.sourcePath: inc wrongFile
      if i > 0 and row.rrTicks <= rows[i - 1].rrTicks: inc nonAscending
    ck wrongIndex == 0
    ck wrongFile == 0
    ck nonAscending == 0
    ck rows[0].rrTicks > 0'u64
    # …and the line is the `print` call's own, which the recorded source really
    # contains at that line. Read off disk rather than written down here, so an
    # edit to the program moves both sides together.
    ck rows[0].line >= 1 and rows[0].line <= live.sourceLines.len
    ck live.sourceLines[rows[0].line - 1].contains("print(")
    expectCount(13)

  liveTest "four panes are expressible in the vocabulary and the source pane is not":
    for pane in PaneVocabularyPanes:
      let pv = paneView(pane, vmFor(pane), GpuiPanelBudget, "gpui")
      let report = checkPortable(pv.root)
      if report.violations.len > 0:
        checkpoint $pane & ": " & describeReport(report)
      ck report.violations.len == 0
      ck report.nodesVisited > 0
      ck pv.native.len == 0
    # …AND THE SOURCE PANE IS REFUSED, which is the half that makes the four
    # above mean something. PLAT-3's admission test rejected `Editor`; PLAT-22
    # owns the decision. A milestone that had quietly rendered source as a
    # `List` of lines would pass the four assertions above and be claiming the
    # vocabulary covers an editor.
    let src = sourcePaneView("gpui")
    let srcReport = checkPortable(src.root)
    ck srcReport.violations.len == 1
    ck src.native == "gpui"
    ck src.root.nativeView == "editor"
    ck paneEditor in PaneNativePanes
    ck paneEditor notin PaneVocabularyPanes
    # The panes PLAT-21 does not cover REPORT rather than render blank.
    let flow = paneView(paneFlow, nil, GpuiPanelBudget, "gpui")
    ck flow.report.len > 0
    ck flow.entries == {pkText}
    expectCount(19)

  liveTest "the entries each pane uses are the ones the module declares":
    publishTracepoints()
    ck paneView(paneState, vmFor(paneState), GpuiPanelBudget, "gpui").entries ==
       {pkTree, pkTabs, pkCollapsible}
    ck paneView(paneCalltrace, vmFor(paneCalltrace), GpuiPanelBudget,
                "gpui").entries == {pkList}
    ck paneView(paneEventLog, vmFor(paneEventLog), GpuiPanelBudget,
                "gpui").entries == {pkTable}
    ck paneView(panePointList, vmFor(panePointList), GpuiPanelBudget,
                "gpui").entries == {pkList}
    expectCount(4)

suite "PLAT-21: three renderers, one pane view, the same state":

  liveTest "the state pane renders the same state on all three media":
    var t = buildThreeWay(paneState, GpuiPanelBudget)
    allThreeAgree(t, "the state pane as opened")
    allThreeSay(t, "state.tabs.selected", "0")
    allThreeSay(t, "state.root.cursor", "0")
    allThreeSay(t, "state.expanded", "true")
    # Twelve variables plus the tree root, and the number comes from the
    # RECORDING rather than from this file: a pane that rendered three rows
    # would agree with itself on all three media.
    let tf = terminalFacts(t)
    var treeRows = 0
    for k in tf.keys:
      if k.endsWith(".expanded"): inc treeRows
    ck treeRows == 14      # 12 variables + the tree root + the Collapsible
    expectCount(12)

  liveTest "the call trace pane renders the same state on all three media":
    var t = buildThreeWay(paneCalltrace, GpuiPanelBudget)
    allThreeAgree(t, "the call trace as loaded")
    allThreeSay(t, "calltrace.highlight", "0")
    expectCount(5)

  liveTest "the event log pane renders the same state on all three media":
    var t = buildThreeWay(paneEventLog, GpuiPanelBudget)
    allThreeAgree(t, "the event log as loaded")
    allThreeSay(t, "eventLog.row", "0")
    allThreeSay(t, "eventLog.column", "0")
    expectCount(8)

  liveTest "the tracepoint pane renders the same state on all three media":
    publishTracepoints()
    var t = buildThreeWay(panePointList, GpuiPanelBudget)
    allThreeAgree(t, "the tracepoint list as published")
    allThreeSay(t, "pointList.highlight", "0")
    expectCount(5)

suite "PLAT-21: the keyboard contract, per view, on all three media":

  liveTest "Tree: the state pane's cursor and expansion agree across three media":
    var t = buildThreeWay(paneState, GpuiPanelBudget)
    allThreeSay(t, "state.root.cursor", "0")
    sendAll(t, "state.root", kDown)
    allThreeSay(t, "state.root.cursor", "1")
    sendAll(t, "state.root", kDown)
    allThreeSay(t, "state.root.cursor", "2")
    allThreeAgree(t, "moving the variables cursor")
    # EXPANDING A REAL RECORDED STRUCTURE. `__builtins__` is a Dict the Python
    # recorder really produced; expanding it adds rows to the rendered set on
    # every medium, which is a change to the SET and not to an attribute.
    let beforeRows = terminalFacts(t).len
    sendAll(t, "state.root", kHome)
    sendAll(t, "state.root", kDown)
    sendAll(t, "state.root", kRight)
    let afterRows = terminalFacts(t).len
    ck afterRows > beforeRows
    allThreeAgree(t, "expanding a recorded structure")
    sendAll(t, "state.root", kLeft)
    ck terminalFacts(t).len == beforeRows
    allThreeAgree(t, "collapsing it again")
    expectCount(23)

  liveTest "List: the call trace moves and clamps identically on three media":
    var t = buildThreeWay(paneCalltrace, GpuiPanelBudget)
    allThreeSay(t, "calltrace.highlight", "0")
    sendAll(t, "calltrace", kDown)
    allThreeSay(t, "calltrace.highlight", "1")
    sendAll(t, "calltrace", kEnd)
    allThreeSay(t, "calltrace.highlight", "27")
    sendAll(t, "calltrace", kDown)
    # NO WRAP, agreed by all three — and the terminal arm is the independent
    # one, so this is isonim-tui's `ListViewWidget` and the vocabulary
    # agreeing rather than one function agreeing with itself.
    allThreeSay(t, "calltrace.highlight", "27")
    sendAll(t, "calltrace", kHome)
    allThreeSay(t, "calltrace.highlight", "0")
    # A key OUTSIDE the contract changes nothing anywhere.
    sendAll(t, "calltrace", kRight)
    allThreeSay(t, "calltrace.highlight", "0")
    allThreeAgree(t, "the whole call-trace script")
    expectCount(25)

  liveTest "Table: the event log's two dimensions agree across three media":
    var t = buildThreeWay(paneEventLog, GpuiPanelBudget)
    allThreeSay(t, "eventLog.row", "0")
    sendAll(t, "eventLog", kDown)
    allThreeSay(t, "eventLog.row", "1")
    sendAll(t, "eventLog", kRight)
    allThreeSay(t, "eventLog.column", "1")
    sendAll(t, "eventLog", kEnd)
    allThreeSay(t, "eventLog.row", "5")   # six recorded events
    sendAll(t, "eventLog", kDown)
    allThreeSay(t, "eventLog.row", "5")
    allThreeAgree(t, "the whole event-log script")
    expectCount(21)

  liveTest "List: motion skips the tracepoint that could not be located":
    publishTracepoints()
    # The middle point's anchor is not in the recorded source, so `resolve`
    # answers line 0, so `pane_views` marks the option DISABLED, so
    # `behaviour.nextEnabled` skips it — on three media, none of which was
    # told why.
    let points = live.session.session.pointListVM.points.val
    ck points.len == 3
    ck points[0].line > 0
    ck points[1].line == 0
    ck points[2].line > 0
    var t = buildThreeWay(panePointList, GpuiPanelBudget)
    allThreeSay(t, "pointList.highlight", "0")
    sendAll(t, "pointList", kDown)
    allThreeSay(t, "pointList.highlight", "2")
    sendAll(t, "pointList", kUp)
    allThreeSay(t, "pointList.highlight", "0")
    allThreeAgree(t, "skipping an unresolved point")
    expectCount(17)

suite "PLAT-21: PLAT-2's purity requirement, with a third witness":

  liveTest "one recorded value renders to the SAME BYTES on all three media":
    # The milestone: *"the same value renders identically across front-ends at
    # the same budget"*. Read back through THREE DIFFERENT READERS — the
    # isonim-tui `TreeNodeRef`'s own label, the mock DOM's text content, and
    # the Rust shim's text content across the FFI boundary — so an arm that
    # stopped rendering the value would differ from the other two rather than
    # from a string this file wrote down.
    var t = buildThreeWay(paneState, GpuiPanelBudget)
    let vars = live.session.session.stateVM.currentVariables.val
    ck vars.len == 12
    var compared = 0
    for v in vars:
      let terminalLabel = tbind.treeLabelOf(t.terminal, "state.root", v.name)
      let webLabel = childTextOf(t.web, v.name)
      let gpuiLabel = t.gpui.ownTextOf(v.name)
      if terminalLabel != webLabel or webLabel != gpuiLabel:
        checkpoint v.name & ": terminal='" & terminalLabel & "' web='" &
          webLabel & "' gpui='" & gpuiLabel & "'"
      ck terminalLabel.len > 0        # the §4 floor, per row
      ck terminalLabel == webLabel
      ck webLabel == gpuiLabel
      # AND IT IS THE PRESENTER'S ANSWER, not a string the pane assembled: the
      # same `PValue` put through `present` at the same budget must produce the
      # same bytes. Without this the three could agree on a rendering all three
      # had truncated.
      let expected = v.name & " = " &
        (if v.presented.isNil: v.value
         else: presentText(v.presented, GpuiPanelBudget))
      ck terminalLabel == expected
      inc compared
    ck compared == 12
    expectCount(50)

  liveTest "…and on a row that HAS children rendered under it":
    # **ADDED AFTER ARM U1 SURVIVED**, and the arm was right about the case
    # rather than about the reader. `ownTextOf` reads the node's FIRST CHILD
    # because `textContent` on a GPUI element CONCATENATES its descendants —
    # and the case above compares only rows whose children are NOT rendered,
    # so the two readings are the same string and a reader that had started
    # concatenating was indistinguishable from one that had not.
    #
    # Verification-Harness-Traps §4a's emptied subject: twelve rows were
    # compared, the count never moved, and what was missing was the VARIETY
    # inside the set. The repair is here, in the suite.
    #
    # Expanding a variable is done through `StateVM.expandedPaths` — the
    # signal the terminal's variables binding and the desktop's state view both
    # read — and the signal is restored afterwards so no later case inherits it.
    let vm = live.session.session.stateVM
    let before = vm.expandedPaths.val
    var parent = ""
    for v in vm.currentVariables.val:
      if v.children.len > 0:
        parent = v.name
        break
    # THE §4 FLOOR: a recording whose every local is a leaf would make this
    # case vacuous, and it would look exactly like a pass.
    ck parent.len > 0
    var expanded = before
    expanded.incl parent
    vm.expandedPaths.val = expanded
    var t = buildThreeWay(paneState, GpuiPanelBudget)
    # The parent's children really are rendered now — on the GPUI side, read
    # out of the shim.
    ck childCount(t.gpui.nodes[parent]) > 1
    let terminalLabel = tbind.treeLabelOf(t.terminal, "state.root", parent)
    let webLabel = childTextOf(t.web, parent)
    let gpuiLabel = t.gpui.ownTextOf(parent)
    if terminalLabel != webLabel or webLabel != gpuiLabel:
      checkpoint parent & ": terminal='" & terminalLabel & "' web='" &
        webLabel & "' gpui='" & gpuiLabel & "'"
    ck terminalLabel.len > 0
    ck terminalLabel == webLabel
    ck webLabel == gpuiLabel
    # …and it is still the presenter's answer, not the row plus its subtree.
    ck gpuiLabel.endsWith(presentText(
      vm.currentVariables.val[0].presented, GpuiPanelBudget)) or
       gpuiLabel.startsWith(parent & " = ")
    vm.expandedPaths.val = before
    expectCount(6)

  liveTest "the state pane's cursor comes from StateVM.selectedPath":
    # **ADDED AFTER ARM U3 SURVIVED.** `statePaneView` derives the tree cursor
    # from `StateVM.selectedPath` — the signal the terminal's
    # `variables_binding.publishSelection` writes and the desktop's state view
    # reads — and every case above starts from a session whose `selectedPath`
    # is EMPTY, so replacing the derivation with a constant 0 left all of them
    # green. Verification-Harness-Traps §7a: a deliberate choice argued in a
    # doc comment with nothing that can tell it from its opposite.
    let vm = live.session.session.stateVM
    let before = vm.selectedPath.val
    let vars = vm.currentVariables.val
    ck vars.len >= 3
    # The THIRD variable, so a cursor that answered 0 or 1 for any reason is
    # still wrong. `visibleRows` puts the tree root at 0 and the variables
    # after it, so the third variable is row 3.
    vm.selectedPath.val = vars[2].name
    var t = buildThreeWay(paneState, GpuiPanelBudget)
    allThreeSay(t, "state.root.cursor", "3")
    allThreeAgree(t, "a cursor published by StateVM")
    vm.selectedPath.val = before
    expectCount(6)

  liveTest "each front-end declares its OWN budget, and they are not the same":
    # PLAT-21 deliverable 2. The three budgets differ, and the SAME value put
    # through them differs too — which is what makes "declares its own budget"
    # a fact about the rendering rather than about a constant nobody reads.
    ck GpuiPanelBudget.name == "gpui-panel"
    ck StatePanelBudget.name == "state-panel"
    ck TuiTreeBudget.name == "tui-tree"
    ck GpuiPanelBudget != TuiTreeBudget
    let vars = live.session.session.stateVM.currentVariables.val
    var differing = 0
    for v in vars:
      if v.presented.isNil: continue
      let wide = presentText(v.presented, GpuiPanelBudget)
      let narrow = presentText(v.presented, FlowBudget)  # 30 cells
      if wide != narrow: inc differing
    # At least one recorded value is long enough for a 30-cell budget to
    # answer differently. Asserted rather than assumed: if every recorded value
    # fitted in 30 cells this case would be comparing a budget with itself.
    ck differing > 0
    expectCount(5)

suite "PLAT-21: PLAT-20 residue 7 — syncSessionLayouts, with a REAL backend":

  liveTest "a layout command in a GPUI window reaches the session slot":
    # PLAT-20 recorded this as *"argued and ungraded"*: `syncSessionLayouts`
    # reduced to a no-op left every suite green, and closing it *"needs a
    # `BackendService`, which needs a mock or a Tier-2 recording"*. This suite
    # has the Tier-2 recording, so no mock was needed and none is used: the
    # `BackendService` below is the real DAP stdio transport to the real
    # `replay-server` child process this file already opened.
    let shell = newGpuiShell()
    let sessionId = shell.app.openSession(
      live.session.backend.toBackendService(), title = "plat21")
    ck sessionId != nil
    let opened = shell.openWindowForSession(WindowId(1), sessionId.id)
    ck opened.kind == wsApplied
    # BEFORE: the slot's tree does not carry the pane the command adds.
    let slot = shell.app.slot(sessionId.id)
    ck slot != nil
    ck paneSearch notin slot.layout.allPanes()
    let applied = shell.applyIn(WindowId(1),
      cmdSplit(paneState, paneSearch, saColumn))
    ck applied.kind == wsApplied
    # AFTER: it does — and the ONLY thing that could have put it there is
    # `syncSessionLayouts`, because `applyIn` writes `shell.windows` and the
    # session slot is a different object.
    ck paneSearch in slot.layout.allPanes()
    # THE DIRECTION, asserted as well as the effect. Running it the other way
    # would make an activation in one window move a pane in another, which is
    # what `syncSessionLayouts`'s own doc comment argues against and what
    # nothing could previously falsify: mutate the SLOT and the window must not
    # follow.
    # `layout_model.apply` NEVER MUTATES its argument — it answers a new
    # layout — so the slot's tree is reassigned from the outcome. The first
    # version of this line `discard`ed the outcome and the pane was still
    # there, which is the module's own purity working rather than a defect.
    let removal = slot.layout.apply(cmdRemovePane(paneSearch))
    ck removal.kind == loApplied
    slot.layout = removal.layout.tree
    ck paneSearch notin slot.layout.allPanes()
    let idx = shell.windows.indexOf(WindowId(1))
    ck idx >= 0
    ck paneSearch in shell.windows.windows[idx].layout.tree.allPanes()
    # And `restoreWindowLayout` syncs too, which is the second caller.
    let doc = shell.saveWindowLayout(WindowId(1))
    let restored = shell.restoreWindowLayout(WindowId(1), doc)
    ck restored.kind == wsApplied
    ck paneSearch in shell.app.slot(sessionId.id).layout.allPanes()
    # The session is closed WITHOUT disconnecting the backend: the DAP pipe is
    # this file's, and closing it here would take `replay-server` down while
    # later cases still need it.
    discard shell.app.closeSession(sessionId.id, disconnectBackend = false)
    expectCount(12)

suite "PLAT-21: the three-way comparison CAN go red":

  liveTest "a reducer that reads one arm's state for another makes it fail":
    # Verification-Harness-Traps §14, answered rather than argued. The web and
    # GPUI arms read their facts through ONE shared function
    # (`fact_reader.readAttributeFacts`), and PLAT-20 measured what that costs:
    # an agreement test whose arms divide through one helper cannot see a
    # change to the helper.
    #
    # So this case demonstrates the comparison's teeth from the other side: it
    # replaces the GPUI arm's projection with the TERMINAL arm's — the exact
    # shape a binding that had stopped reading its own medium would produce —
    # and requires `divergences` to report it. Without this, "0 divergences"
    # and "the reducer stopped discriminating" are the same transcript.
    var t = buildThreeWay(paneCalltrace, GpuiPanelBudget)
    ck divergences(t).len == 0
    # Move ONE arm and nothing else. The terminal binding is the independent
    # oracle, so moving it is the sharpest version of this.
    ck tbind.sendKey(t.terminal, "calltrace", kDown, ' ')
    let d = divergences(t)
    if d.len == 0:
      checkpoint "the three-way comparison did not see a moved terminal arm"
    ck d.len == 1
    ck d[0].contains("calltrace.highlight")
    ck d[0].contains("terminal=1")
    ck d[0].contains("web=0")
    ck d[0].contains("gpui=0")
    expectCount(7)

  liveTest "and the shared reader is load-bearing for two of the three arms":
    # Said as a measurement rather than as a caveat: the web and GPUI arms
    # BOTH come through `readAttributeFacts`, so a defect in it moves both
    # identically and the pair agrees. The terminal arm is what keeps the
    # three-way comparison from being blind to it, and this case pins that the
    # terminal arm's projection really is a different code path — it reads
    # isonim-tui's widget objects, which have no `data-*` attribute anywhere.
    var t = buildThreeWay(paneCalltrace, GpuiPanelBudget)
    ck t.terminal.bound.len > 0
    ck t.terminal.bound[0].kind == pkList
    # The widget's own field, read directly, is what the terminal projection
    # reports — so the two projections cannot be one function.
    ck t.terminal.bound[0].listW.highlightedIndex == 0
    ck terminalFacts(t).getOrDefault("calltrace.highlight", "") == "0"
    t.terminal.bound[0].listW.highlightedIndex = 3
    ck terminalFacts(t).getOrDefault("calltrace.highlight", "") == "3"
    ck webFacts(t).getOrDefault("calltrace.highlight", "") == "0"
    expectCount(6)

suite "PLAT-21: the session is closed":
  test "the replay-server child is released":
    if liveSkip.len > 0:
      echo liveSkip
      check true
    else:
      live.session.close()
      check true

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count.
const ExpectedAssertions = 253

suite "PLAT-21: the assertion count":
  test "every case in this file ran":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
