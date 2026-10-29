## test_plat60_low_level_code.nim — PLAT-60: the Low Level Code listing every
## front-end draws, decided once in `low_level_code_vm`.
##
## What the desktop's view, the terminal's pane and the GPUI window's pane all
## read: the rows (`displayRows`), the execution pointer, the cross-reference
## both ways (`linkedIndices`, `crossRefSource`), the header's words, the row
## menu (`rowMenu` / `runRowMenu`) and stepping at instruction granularity
## (`instructionStepRequest`, from the store's
## `supportsSteppingGranularity`) — and the desktop's view giving each mark a
## class.
##
## ## The one stand-in, and why it is not a mock
##
## A `ReplayDataStore` needs a transport, and the shared model under test is
## pure over the store's signals: the listing is installed the way the stop
## loader installs an engine's answer (`applyAsmAnswer`), from the body the
## engine wrote for the Noir recording (`noir_space_ship`, its `main`:
## `src/main.nr`, relative, as the trace's path table holds it). The
## transport is `MockBackendService` and nothing is asserted of it but the one
## request the desktop's Go to Source Line sends (`ct/source-line-jump`) —
## the real engine's answer to that request is asserted on the terminal
## (`tui/tests/test_plat60_low_level_code.nim`), on the real recording.

import std/[json, strutils, tables, unittest]

import isonim/core/[signals, computation]
import isonim/testing/mock_dom
import isonim/viewmodel

import ../../backend/[backend_service, mock_backend]
import ../../store/replay_data_store
import ../../store/types
import ../../viewmodels/low_level_code_vm
import ../../views/isonim_low_level_code_view

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 83

const
  MainPath = "/work/noir_space_ship/src/main.nr"
  EngineAnswer = """{"address":0,"error":"","instructions":[
    {"args":"","highLevelLine":12,"highLevelPath":"src/main.nr","name":"","offset":1,"other":""},
    {"args":"","highLevelLine":13,"highLevelPath":"src/main.nr","name":"","offset":6,"other":""},
    {"args":"","highLevelLine":14,"highLevelPath":"src/main.nr","name":"","offset":-1,"other":""},
    {"args":"","highLevelLine":15,"highLevelPath":"src/main.nr","name":"","offset":670,"other":""}]}"""

proc setup(ticks = 5'u64): (LowLevelCodeVM, MockBackendService) =
  let mock = newMockBackendService(autoRespond = true)
  let store = createReplayDataStore(mock.toBackendService())
  var d = store.debugger.val
  d.rrTicks = ticks
  d.location.file = MainPath
  d.location.line = 13
  store.debugger.val = d
  let vm = createLowLevelCodeVM(store)
  vm.applyAsmAnswer(parseJson(EngineAnswer), AsmFunctionLocation(
    path: MainPath, name: "main", key: "1", line: 13))
  (vm, mock)

proc instructionRows(vm: LowLevelCodeVM): seq[LowLevelRowView] =
  for r in vm.displayRows():
    if r.kind == lrkInstruction: result.add r

proc hasClass(node: MockNode; className: string): bool =
  for part in node.attributes.getOrDefault("class", "").split(' '):
    if part == className: return true

proc findAll(node: MockNode; className: string): seq[MockNode] =
  if node.isNil: return
  if node.kind == mnkElement and node.hasClass(className):
    result.add node
  for c in node.children:
    result.add findAll(c, className)

suite "PLAT-60: one listing — rows, the pointer, the debugger's line":

  test "the engine's answer as rows: each instruction after its line":
    let (vm, _) = setup()
    defer: vm.dispose()
    let rows = vm.displayRows()
    ck rows.len == 8
    var lines: seq[int] = @[]
    for r in rows:
      if r.kind == lrkSource: lines.add r.line
    ck lines == @[12, 13, 14, 15]
    let instrs = vm.instructionRows
    ck instrs.len == 4
    ck instrs[0].offsetText == "StepId(1)"
    ck instrs[2].offsetText == "<no step id>"
    ck instrs[1].name == "<no instructions>"
    ck instrs[1].crossRef == "src/main.nr:13"

  test "the debugger's line marks its rows, though the move spells the path in full":
    # The engine writes `src/main.nr`; the move reports the full path. Until
    # PLAT-60 the two were compared verbatim and no Noir row was ever marked.
    ck sameSourcePath("src/main.nr", MainPath)
    ck sameSourcePath(MainPath, "src/main.nr")
    ck not sameSourcePath("main.nr", "/work/src/xmain.nr")
    ck not sameSourcePath("/a/src/main.nr", "/b/src/main.nr")
    let (vm, _) = setup()
    defer: vm.dispose()
    var active: seq[int] = @[]
    for r in vm.displayRows():
      if r.active: active.add r.line
    ck active.len == 2     # line 13's source row and its instruction
    let instrs = vm.instructionRows
    ck instrs[1].active
    ck not instrs[0].active

  test "the execution pointer: the step the debugger is at, else its line":
    # At tick 5 no instruction was reached AT step 5; the pointer falls on
    # the first instruction of the line the debugger is at (13).
    let (vm, _) = setup(ticks = 5)
    defer: vm.dispose()
    ck vm.executionIndex == 1
    let marked = vm.instructionRows
    ck marked[1].executing
    ck not marked[0].executing
    # At tick 670 it is that step's own instruction (line 15), whatever line.
    let (vm2, _) = setup(ticks = 670)
    defer: vm2.dispose()
    ck vm2.executionIndex == 3
    ck executionIndexIn(@[], 0, true, 0, "", -1) == -1

suite "PLAT-60: the cross-reference, both ways":

  test "source → instructions: the editor's line marks what came from it":
    let (vm, _) = setup()
    defer: vm.dispose()
    vm.setSourceCursor(MainPath, 15)
    ck vm.linkedIndices == @[3]
    let instrs = vm.instructionRows
    ck instrs[3].linked
    ck not instrs[1].linked
    vm.setSourceCursor(MainPath, 99)
    ck vm.linkedIndices.len == 0
    # Source syncing off: nothing is cross-referenced.
    vm.setSourceCursor(MainPath, 15)
    vm.setSyncEnabled(false)
    ck vm.linkedIndices.len == 0
    ck vm.mappingNotice == "source syncing is off"

  test "instruction → source: the listing's cursor names its line":
    let (vm, _) = setup()
    defer: vm.dispose()
    ck vm.crossRefSource.line == 0
    ck vm.moveSelection("list.focus-next") == 1   # starts at the pointer
    ck vm.moveSelection("list.focus-next") == 2
    ck vm.crossRefSource == SourceLineRef(path: "src/main.nr", line: 14)
    var linkedSource: seq[int] = @[]
    for r in vm.displayRows():
      if r.kind == lrkSource and r.linked: linkedSource.add r.line
    ck linkedSource == @[14]
    ck vm.moveSelection("list.focus-last") == 3
    ck vm.moveSelection("list.focus-first") == 0
    ck vm.moveSelection("list.focus-page-down", 10) == 3
    vm.selectInstruction(NoSelectedInstruction)
    ck vm.crossRefSource.line == 0
    # A new listing forgets the cursor.
    vm.selectInstruction(2)
    vm.clearInstructions()
    ck vm.selected.val == NoSelectedInstruction

suite "PLAT-60: the header and the row menu":

  test "the header's words":
    let (vm, _) = setup()
    defer: vm.dispose()
    ck vm.steppingText == SteppingByLineText
    ck vm.mappingNotice == ""     # the recording's own code is kept in step
    ck vm.emptyText == ""
    vm.clearInstructions()
    ck vm.emptyText == LowLevelEmptyText
    vm.setErrorMessage("refused")
    ck vm.emptyText == ""
    ck addressText(255).startsWith("Originating address: 0x")
    ck addressText(255).endsWith("FF")

  test "the menu: its entries, a disabled one's reason, and what each does":
    let (vm, mock) = setup()
    defer: vm.dispose()
    var labels: seq[string] = @[]
    for e in vm.rowMenu(1):
      labels.add e.label
      ck e.enabled
    ck labels == @["Go to Source Line", "Show Source Line",
                   "Copy Instruction", "Copy Source Location"]
    let copied = vm.runRowMenu(1, llmCopyInstruction)
    ck copied.copied == "StepId(6)  <no instructions>"
    let location = vm.runRowMenu(3, llmCopySourceLocation)
    ck location.copied == "src/main.nr:15"
    let show = vm.runRowMenu(2, llmShowSourceLine)
    ck vm.selected.val == 2
    ck show.note.contains("src/main.nr:14")
    # A host that drives its engine itself is told where to go.
    let native = vm.runRowMenu(3, llmGoToSourceLine, send = false)
    ck native.jumpTo == SourceLineRef(path: "src/main.nr", line: 15)
    ck not native.moved
    # The desktop's path sends the engine the move, the path verbatim.
    let before = mock.receivedCommands.len
    let desk = vm.runRowMenu(3, llmGoToSourceLine)
    ck desk.moved
    ck mock.receivedCommands.len == before + 1
    ck mock.receivedCommands[^1].command == "ct/source-line-jump"
    ck mock.receivedCommands[^1].args["path"].getStr == "src/main.nr"
    ck mock.receivedCommands[^1].args["line"].getInt == 15
    # An instruction with no source line: disabled, with the reason.
    vm.clearInstructions()
    vm.setInstructions(@[LowLevelInstruction(name: "nop", offset: 0)])
    let entries = vm.rowMenu(0)
    ck not entries[0].enabled
    ck entries[0].reason == NoSourceLineReason
    ck entries[2].enabled
    ck vm.runRowMenu(0, llmGoToSourceLine).note == NoSourceLineReason

suite "PLAT-60: stepping at instruction granularity, where offered":

  test "no engine offers it: the step goes by line, and the words say so":
    let (vm, _) = setup()
    defer: vm.dispose()
    let r = vm.instructionStepRequest("debugger.step-over")
    ck not r.offered
    ck r.note == InstructionSteppingRefusal
    ck not vm.instructionStepRequest("debugger.step-out").offered

  test "an engine that offers it: DAP's own request, by instruction":
    let (vm, _) = setup()
    defer: vm.dispose()
    vm.store.applyDapCapabilities(%*{"supportsStepBack": true,
                                     "supportsSteppingGranularity": true})
    ck vm.instructionStepOffered
    ck vm.steppingText == SteppingByInstructionText
    let r = vm.instructionStepRequest("debugger.step-over")
    ck r.offered
    ck r.command == "next"
    ck r.args["granularity"].getStr == "instruction"
    ck vm.instructionStepRequest("debugger.reverse-step-over").command ==
       "stepBack"
    ck vm.instructionStepRequest("debugger.step-into").command == "stepIn"

suite "PLAT-60: the desktop's view gives each mark a class":

  test "pointer, cross-reference, cursor, stepping, empty":
    let (vm, _) = setup()
    defer: vm.dispose()
    vm.setSourceCursor(MainPath, 15)
    vm.selectInstruction(2)
    let r = MockRenderer()
    let panel = renderLowLevelCodePanel[MockRenderer, MockNode](r, vm)
    let rows = findAll(panel, "low-level-code-instruction")
    ck rows.len == 4
    ck rows[1].hasClass("execution-pointer")
    ck rows[1].hasClass("active-instruction")
    ck rows[2].hasClass("selected-instruction")
    ck rows[3].hasClass("cross-referenced")
    let sources = findAll(panel, "low-level-code-source-line")
    ck sources[2].hasClass("cross-referenced")
    let stepping = findAll(panel, "low-level-code-stepping")
    ck stepping.len == 1
    ck stepping[0].textContent == SteppingByLineText
    ck findAll(panel, "low-level-code-empty").len == 0
    vm.clearInstructions()
    let empty = findAll(panel, "low-level-code-empty")
    ck empty.len == 1
    ck empty[0].textContent == LowLevelEmptyText

suite "PLAT-60 suite self-check":
  test "plat60_assertion_count_is_measured":
    checkpoint("assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
