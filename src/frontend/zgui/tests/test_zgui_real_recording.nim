## test_zgui_real_recording.nim — `codetracer-zgui` on a real recording.
##
## The shipped binary is run headless on the `calc` recording: it opens the
## recording through a real `replay-server`, draws the window, steps through
## it — eight step-ins from `--replay-ops` and a step over from the key F10, which
## goes through zgui's dispatch and the keymap router as a reader's key does
## — and reports what its window shows, read back out of zgui's document
## (`--facts-out`), with the frames drawn by the real wgpu renderer
## (`--capture-dir`).
##
## The suite drives a second session over the same recording to the same
## stop through the host's own producers, and compares:
##
##   * the editor: the execution row is the session's execution line, its
##     inline values (the flow's annotations) are the row model's, and the
##     drawn frame carries the execution band on that row;
##   * the state, call trace and event log panes: the state each one shows,
##     read out of zgui, equals the web binding's rendering of the same
##     ViewModel's pane view — the cross-renderer comparison, on a real stop;
##   * the step's work: a step writes a few elements, not the window.
##
## ## NO MOCKS
##
## A real Python recording, a real `replay-server` child of the binary and
## of this suite, the real ViewModels and zgui's real runtime. `MockRenderer`
## is the web binding's non-JS backend (see `test_zgui_vocabulary_binding`).

import std/[json, os, osproc, strutils, tables, unittest]

import isonim/core/[signals, computation]
import isonim/testing/mock_dom
import isonim/viewmodel

import headless_session
import viewmodels/[state_vm, calltrace_vm, event_log_vm]
import ../../tui/host/[native_host, session_driver]
import ../../gpui/host/gpui_host
import ../../view_vocabulary/[pane_views, editor_surface]
import ../../view_vocabulary/web_binding as wbind
import ../../../common/view_vocabulary
import ../../../common/value_presentation
import ../../styles/generated/design_tokens
import ../../tui/tests/fixtures/fixture_provider
import ../app/zgui_leaves
import headless_app/layout_model

var countedAssertions = 0
const ExpectedAssertions = 57

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const StepIns = 8
  ## From `--replay-ops`: into the module's body, where the flow has values
  ## for the lines it ran. Then one step over, from the key.

proc zguiBinary(): string =
  result = getEnv("CODETRACER_ZGUI_BIN")
  if result.len == 0:
    result = currentSourcePath().parentDir() / "../../../../build/bin/codetracer-zgui"
  doAssert fileExists(result), "codetracer-zgui is not built at " & result &
    " (just build-zgui, or set CODETRACER_ZGUI_BIN)"

let trace = requireFixture(fixtureSpec("calc"))
let work = getTempDir() / "codetracer-zgui-test-" & $getCurrentProcessId()
createDir(work)
let facts = work / "facts.json"
let frames = work / "frames.json"
let shots = work / "shots"

let run = execCmdEx(quoteShellCommand([zguiBinary(), "--headless",
  "--capture-dir=" & shots, "--replay-ops=stepIn=" & $StepIns, "--keys=F10,Alt+e,ArrowDown",
  "--width=1600", "--height=1000",
  "--facts-out=" & facts, "--frame-report=" & frames, trace]))

# A second run: the Debug menu opened and an item run by pointer clicks on
# the top bar, then a control; and a third that only opens the menu, to read
# the popover while it is shown.
let menuFacts = work / "menu.json"
let clicked = execCmdEx(quoteShellCommand([zguiBinary(), "--headless",
  "--clicks=menu:Debug", "--facts-out=" & menuFacts, trace]))
let clickFrames = work / "clicks.json"
let clickFacts = work / "clicks-facts.json"
let ran = execCmdEx(quoteShellCommand([zguiBinary(), "--headless",
  "--clicks=menu:Debug,action:forwardStep,control:next",
  "--facts-out=" & clickFacts, "--frame-report=" & clickFrames, trace]))

# The same stop, through the host's own producers.
let session = openGpuiTrace(trace)
# The flow overlay on, as the window has it, so the flow loads its values.
session.session.editorVM.showFlowOverlay.val = FlowOverlayShownByDefault
discard session.loadRecordingPanes(raiseOnStall = true)
discard session.loadStopPanes()
for _ in 0 ..< StepIns:
  doAssert session.runDebugControl("step-in")
  session.afterMove()
doAssert session.runDebugControl("next")
session.afterMove()
# The call trace holds a section the size of a pane, as the window's does, and
# the current call is selected in it.
discard session.pageCalltrace(30, 0, 600, 16)
session.selectCurrentCall()
let source = newGpuiSourceService(session, trace, 40)
source.visibleRows = 40
source.serveWindow()
let surface = editorSurfaceFor(
  source = source.vm, editor = session.session.editorVM,
  state = session.session.stateVM, flow = session.session.flowVM,
  availability = source.availability(), budget = gpuiRowBudget(),
  medium = ZguiMedium)

proc webFactsOf(kind: PaneKind): Table[string, string] =
  let vm = case kind
    of paneState: ViewModel(session.session.stateVM)
    of paneCalltrace: ViewModel(session.session.calltraceVM)
    else: ViewModel(session.session.eventLogVM)
  let pv = paneView(kind, vm, GpuiPanelBudget, ZguiMedium)
  let b = renderWeb[MockRenderer, MockNode](MockRenderer(), pv.root)
  for f in b.readWebFacts(): result[f.id & "." & f.field] = f.value

proc zguiFactsOf(doc: JsonNode; kind: PaneKind): Table[string, string] =
  for f in doc{"panes", $kind, "facts"}.getElems:
    result[f["id"].getStr & "." & f["field"].getStr] = f["value"].getStr

suite "codetracer-zgui opens a real recording and steps through it":

  test "the binary opened the recording, stepped and drew every frame":
    checkpoint(run.output)
    ck run.exitCode == 0
    ck fileExists(facts) and fileExists(frames)
    var pngs = 0
    for f in walkFiles(shots / "*.png"): inc pngs
    # The open, the replayed steps and the three keys.
    ck pngs == StepIns + 4

  test "the editor's execution row is the session's, with its inline values":
    let doc = parseFile(facts)
    var exec: JsonNode = nil
    for row in doc["editorRows"].getElems:
      if row["pointer"].getStr == $eptExecution: exec = row
    ck not exec.isNil
    ck surface.executionLine > 0
    if not exec.isNil:
      ck parseInt(exec["line"].getStr) == surface.executionLine
      let modelRow = surface.rowAt(surface.executionLine)
      ck exec["values"].getStr == structuredValues(modelRow.values)
      ck exec["text"].getStr.contains(modelRow.text.strip())
    # Every row the model has, the window has, line for line.
    var lines: seq[int]
    for row in doc["editorRows"].getElems: lines.add parseInt(row["line"].getStr)
    var modelLines: seq[int]
    for r in surface.rows: modelLines.add r.line
    checkpoint($lines & " vs " & $modelLines)
    ck surface.executionLine in lines
    # The flow's annotations, row by row: every drawn row says what the row
    # model says about its values and its flow state, and some rows have
    # values to say.
    var annotated = 0
    var differ: seq[string]
    for row in doc["editorRows"].getElems:
      let line = parseInt(row["line"].getStr)
      let model = surface.rowAt(line)
      # The two windows need not hold the same lines (they are as tall as the
      # pane each was given); a line both hold is compared.
      if model.line != line: continue
      if row["values"].getStr != structuredValues(model.values) or
         row["flow"].getStr != $model.flow:
        differ.add $line
      if model.values.len > 0: inc annotated
    checkpoint("rows that differ: " & $differ)
    ck differ.len == 0
    ck annotated >= 3

  test "the drawn frame carries the execution band on that row":
    let doc = parseFile(facts)
    ck doc{"executionRowLine"}.getStr == $surface.executionLine
    ck doc{"executionRowPixel"}.getStr ==
       DesignTokenHex[dtEditorThemeExecutionLine][dmDark]

  test "the state, call trace and event log show what the web binding shows":
    let doc = parseFile(facts)
    for kind in [paneState, paneCalltrace, paneEventLog]:
      let z = zguiFactsOf(doc, kind)
      let w = webFactsOf(kind)
      checkpoint($kind & " zgui " & $z & "\n  web " & $w)
      ck doc{"panes", $kind, "state"}.getStr == "live"
      ck z.len > 0
      if kind == paneEventLog:
        # The binary's last key moved the event log's row (the case below);
        # the column, and every other fact, agree.
        var moved = z
        moved["eventLog.row"] = w.getOrDefault("eventLog.row")
        ck moved == w
      else:
        ck z == w
    # And the values, not only their shape: every local the state pane holds
    # at this stop is named in what zgui drew.
    let drawn = doc{"panes", $paneState, "text"}.getStr
    let locals = session.session.stateVM.currentVariables.val
    ck locals.len > 0
    for v in locals:
      ck drawn.contains(v.name)

  test "a step writes the rows that changed, not the window":
    let rec = parseFile(frames)
    let drawnRows = parseFile(facts)["editorRows"].len
    var steps = 0
    var quiet = 0
    var names: seq[string]
    for op in rec["operations"].getElems:
      let name = op["name"].getStr
      names.add name
      if name.startsWith("stepIn") or name.contains("debugger.step-over"):
        inc steps
        checkpoint($op)
        # A step rewrites the editor rows whose pointer, values or flow
        # changed — all of them only when the window scrolled to another
        # place — and writes the panes' changed elements; it never rebuilds
        # the window.
        if op["rowsWritten"].getInt > drawnRows or
           op["paneElementsReplaced"].getInt > 4:
          checkpoint("too much work: " & name)
          inc steps, 100
        if op["rowsWritten"].getInt <= 4: inc quiet
    ck steps == StepIns + 1
    # A step within one function moves the pointer: two rows.
    ck quiet >= 3
    checkpoint($names)
    ck names[^3].startsWith("key:F10 -> debugger.step-over")

  test "a one-row change in the event log writes that row":
    # Alt+E gives the event log the keyboard (the CUA keymap's chord) and
    # Down moves its row: the view's own key, through zgui's dispatch.
    let rec = parseFile(frames)
    let ops = rec["operations"].getElems
    ck ops[^2]["name"].getStr == "key:Alt+e -> focus:" & $paneEventLog
    let row = ops[^1]
    checkpoint($row)
    ck row["name"].getStr == "key:ArrowDown -> view-key:" & $paneEventLog
    ck row["paneElementsReplaced"].getInt == 0
    ck row["paneElementsWritten"].getInt in 1 .. 4
    ck row["nodesRelaidOut"].getInt == 0
    let doc = parseFile(facts)
    ck zguiFactsOf(doc, paneEventLog)["eventLog.row"] == "1"

suite "the top bar and its menus":

  test "a menu opens in zgui's popover overlay, with the product's items":
    checkpoint(clicked.output)
    ck clicked.exitCode == 0
    let doc = parseFile(menuFacts)
    ck doc{"openMenu"}.getStr == "Debug"
    ck doc{"openMenuInOverlay"}.getBool
    for label in ["Step Over", "Step In", "Step Out", "Continue",
                  "Reverse Step Over"]:
      ck doc{"openMenuText"}.getStr.contains(label)

  test "a menu item and a control run their operations, and the menu closes":
    checkpoint(ran.output)
    ck ran.exitCode == 0
    var names: seq[string]
    for op in parseFile(clickFrames)["operations"].getElems:
      names.add op["name"].getStr
    ck names == @["open", "click:menu:Debug",
                  "click:action:forwardStep -> forwardStep",
                  "click:control:next -> next"]
    let doc = parseFile(clickFacts)
    ck not doc.hasKey("openMenu")
    var exec = 0
    for row in doc["editorRows"].getElems:
      if row["pointer"].getStr == $eptExecution: exec = parseInt(row["line"].getStr)
    # A step in and a step over from the first stop: the pointer moved.
    ck exec > 0 and exec != 1

suite "cleanup":
  test "the session is closed and the scratch removed":
    session.close()
    removeDir(work)
    ck not dirExists(work)

suite "assertion count":
  test "every case in this file ran":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
