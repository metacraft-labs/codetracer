## test_low_level_code_loading.nim
##
## HSF-D3 (Shared-DOM-Front-Ends D7.2): the Low Level Code pane is loaded by
## the session's stop loader, per stop, while a front-end shows it; the answer
## lands in `LowLevelCodeVM`; the one generic view groups the listing under
## its source lines and sets the source as text.
##
## Driven through a real `SessionViewModel` and `StopLoader` over a
## `MockBackendService` — the stand-in for the replay engine's transport, the
## one boundary these tests cannot run for real without a recording; what is
## asserted is the requests the loader sends, the VM state the answers leave,
## and the DOM the view renders under `MockRenderer`. The source text comes
## from a stub `SourceProvider`, the injected seam the VM fetches through, so
## the markup case controls exactly what the "recorded source" says.

import std/[json, options, strutils, tables, unittest]

import isonim/core/[signals, owner, async_compat]
import isonim/testing/mock_dom

import backend/[backend_service, mock_backend]
import session_vm
import store/[replay_data_store, types]
import viewmodels/[low_level_code_vm, source_vm]
import sdk/[stop_loader, source_provider]
import views/isonim_low_level_code_view

proc sent(mock: MockBackendService; command: string): int =
  for c in mock.receivedCommands:
    if c.command == command:
      inc result

proc lastArgs(mock: MockBackendService; command: string): JsonNode =
  for i in countdown(mock.receivedCommands.high, 0):
    if mock.receivedCommands[i].command == command:
      return mock.receivedCommands[i].args

proc newSession(mock: MockBackendService): (SessionViewModel, StopLoader) =
  let session = createSessionVM(mock.toBackendService())
  session.store.claimLocalsLoading()
  session.initializePanelViewModels()
  # No source text unless a case installs some: the DAP default would send
  # `source` requests these cases do not answer.
  session.lowLevelCodeVM.setSourceProvider(SourceProvider(
    kind: spkDapSource, name: "none",
    supportsProc: proc(): bool = false,
    fetchProc: proc(request: SourceLineRequest;
                    onResult: proc(fetch: SourceFetch)) =
      onResult(SourceFetch(status: sfsProviderUnavailable, request: request))))
  let loader = createStopLoader(session)
  loader.follow()
  (session, loader)

proc move(store: ReplayDataStore; ticks: int; path, fn, key: string;
          line: int; cPath = ""; cFn = ""; cKey = ""; cLine = 0) =
  ## A `ct/complete-move` as the engine reports it.
  var body = %*{"location": {"path": path, "line": line, "rrTicks": ticks,
                             "functionName": fn, "key": key}}
  if cPath.len > 0:
    body["cLocation"] = %*{"path": cPath, "line": cLine, "functionName": cFn,
                           "key": cKey}
  store.applyCompleteMove(body)

proc instr(name: string; offset: int; path: string; line: int): JsonNode =
  %*{"name": name, "args": "", "other": "", "offset": offset,
     "highLevelPath": path, "highLevelLine": line}

proc asmAnswer(rows: varargs[JsonNode]): JsonNode =
  ## A whole `ct/load-asm-function` response (`Instructions`).
  var list = newJArray()
  for r in rows: list.add r
  %*{"success": true, "body": {"address": 0, "instructions": list,
                               "error": ""}}

proc withAddress(answer: JsonNode; address: int): JsonNode =
  answer["body"]["address"] = %address
  answer

proc elementChildren(n: MockNode): int =
  for c in n.children:
    if c.kind == mnkElement: inc result

proc byClass(n: MockNode; cls: string; found: var seq[MockNode]) =
  if n.isNil: return
  if n.kind == mnkElement and
     cls in n.attributes.getOrDefault("class", "").split(' '):
    found.add n
  for c in n.children: byClass(c, cls, found)

proc allByClass(n: MockNode; cls: string): seq[MockNode] =
  byClass(n, cls, result)

suite "HSF-D3: the stop loader loads the low-level code while it is shown":

  test "a hidden pane asks nothing; a shown one asks once per move":
    let mock = newMockBackendService(autoRespond = true)
    let (session, _) = newSession(mock)
    let vm = session.lowLevelCodeVM
    session.store.move(10, "/src/main.py", "main", "4", 3)
    drainPlatformCallbacks()
    check mock.sent("ct/load-asm-function") == 0   # not shown
    vm.setShown(true)
    drainPlatformCallbacks()
    check mock.sent("ct/load-asm-function") == 1
    let args = mock.lastArgs("ct/load-asm-function")
    check args["path"].getStr == "/src/main.py"
    check args["name"].getStr == "main"
    check args["key"].getStr == "4"
    check args["forceReload"].getBool == false
    # The same stop asks nothing more; a move asks again.
    session.store.move(10, "/src/main.py", "main", "4", 3)
    drainPlatformCallbacks()
    check mock.sent("ct/load-asm-function") == 1
    session.store.move(20, "/src/main.py", "helper", "7", 9)
    drainPlatformCallbacks()
    check mock.sent("ct/load-asm-function") == 2
    check mock.lastArgs("ct/load-asm-function")["key"].getStr == "7"
    # Hidden again: further moves ask nothing.
    vm.setShown(false)
    session.store.move(30, "/src/main.py", "main", "4", 5)
    drainPlatformCallbacks()
    check mock.sent("ct/load-asm-function") == 2

  test "the answer lands in the VM, and the debugger's line marks its rows":
    let mock = newMockBackendService()
    let (session, loader) = newSession(mock)
    let vm = session.lowLevelCodeVM
    mock.expect("ct/load-asm-function", asmAnswer(
      instr("push", 1, "/src/main.py", 3),
      instr("mov", 1, "/src/main.py", 3),
      instr("call", 2, "/src/main.py", 4)).withAddress(0x400))
    vm.setShown(true)
    session.store.move(10, "/src/main.py", "main", "4", 4)
    drainPlatformCallbacks()
    check loader.status[spLowLevelCode].val == plsApplied
    check vm.instructions.val.len == 3
    check vm.address.val == 0x400
    check vm.activeLine.val == 4
    let rows = vm.instructions.val
    check not isActiveInstruction(rows[0], vm.activeLine.val,
                                  vm.activePath.val, vm.activeOffset.val)
    check isActiveInstruction(rows[2], vm.activeLine.val, vm.activePath.val,
                              vm.activeOffset.val)

  test "a Nim recording asks for the C-level function and marks the C line":
    let mock = newMockBackendService()
    let (session, _) = newSession(mock)
    let vm = session.lowLevelCodeVM
    mock.expect("ct/load-asm-function", asmAnswer(
      instr("mov", 5, "/build/@mmain.nim.c", 120),
      instr("ret", 6, "/build/@mmain.nim.c", 121)))
    vm.setShown(true)
    session.store.move(10, "/src/main.nim", "main", "3", 7,
                       cPath = "/build/@mmain.nim.c", cFn = "main__main_u1",
                       cKey = "9", cLine = 121)
    drainPlatformCallbacks()
    let args = mock.lastArgs("ct/load-asm-function")
    check args["path"].getStr == "/build/@mmain.nim.c"
    check args["name"].getStr == "main__main_u1"
    check args["key"].getStr == "9"
    check vm.activeLine.val == 121
    check vm.activePath.val == "/build/@mmain.nim.c"
    let rows = vm.instructions.val
    check not isActiveInstruction(rows[0], vm.activeLine.val,
                                  vm.activePath.val, vm.activeOffset.val)
    check isActiveInstruction(rows[1], vm.activeLine.val, vm.activePath.val,
                              vm.activeOffset.val)

  test "a Noir recording asks again on every move and shows step ids":
    let mock = newMockBackendService()
    let (session, _) = newSession(mock)
    let vm = session.lowLevelCodeVM
    mock.expect("ct/load-asm-function", asmAnswer(
      instr("BRILLIG CALL", 12, "/src/main.nr", 5)))
    vm.setShown(true)
    session.store.move(10, "/src/main.nr", "main", "2", 5)
    drainPlatformCallbacks()
    check mock.lastArgs("ct/load-asm-function")["forceReload"].getBool
    check vm.noirProject.val
    createRoot proc(dispose: proc()) =
      let panel = renderLowLevelCodePanel[MockRenderer, MockNode](
        MockRenderer(), vm)
      let offsets = panel.allByClass("low-level-code-instruction-offset")
      check offsets.len == 1
      check offsets.len == 1 and offsets[0].textContent == "StepId(12)"
      dispose()

  test "a refusal is shown in the pane, not as an empty listing":
    let mock = newMockBackendService()
    let (session, loader) = newSession(mock)
    let vm = session.lowLevelCodeVM
    mock.expect("ct/load-asm-function",
      %*{"success": false, "message": "no instructions recorded"})
    vm.setShown(true)
    session.store.move(10, "/src/main.py", "main", "4", 3)
    drainPlatformCallbacks()
    check loader.status[spLowLevelCode].val == plsFailed
    check vm.errorMessage.val.contains("no instructions recorded")
    createRoot proc(dispose: proc()) =
      let panel = renderLowLevelCodePanel[MockRenderer, MockNode](
        MockRenderer(), vm)
      let errors = panel.allByClass("low-level-code-error")
      check errors.len == 1
      check errors.len == 1 and
            errors[0].textContent.contains("no instructions recorded")
      dispose()

  test "a generated listing painted at this stop is not replaced":
    let mock = newMockBackendService(autoRespond = true)
    let (session, _) = newSession(mock)
    let vm = session.lowLevelCodeVM
    session.store.move(10, "/src/main.nr", "main", "2", 5)
    vm.showGeneratedListing(@[LowLevelInstruction(name: "acir op", offset: 0)],
                            @[], ArtefactSupport(), "/src/main.nr", 5,
                            "build output")
    vm.setShown(true)                    # opening the pane for the listing
    drainPlatformCallbacks()
    check mock.sent("ct/load-asm-function") == 0
    check vm.instructions.val.len == 1 and
          vm.instructions.val[0].name == "acir op"
    # The next move shows the recording's code again.
    session.store.move(20, "/src/main.nr", "main", "2", 6)
    drainPlatformCallbacks()
    check mock.sent("ct/load-asm-function") == 1

suite "HSF-D3: the view groups the listing under its source lines":

  test "each run of instructions follows its source line, as text":
    let mock = newMockBackendService()
    let (session, _) = newSession(mock)
    let vm = session.lowLevelCodeVM
    # The recorded source of line 3 is markup.
    vm.setSourceProvider(SourceProvider(
      kind: spkDapSource, name: "stub",
      supportsProc: proc(): bool = true,
      fetchProc: proc(request: SourceLineRequest;
                      onResult: proc(fetch: SourceFetch)) =
        var lines: seq[string] = @[]
        for l in request.firstLine .. request.lastLine:
          lines.add(if l == 3: "<img src=x onerror=alert(1)>"
                    else: "line " & $l)
        onResult(SourceFetch(status: sfsAvailable, request: request,
                             firstLine: request.firstLine, lines: lines))))
    mock.expect("ct/load-asm-function", asmAnswer(
      instr("push", 1, "/src/page.html", 3),
      instr("mov", 1, "/src/page.html", 3),
      instr("call", 2, "/src/page.html", 4)))
    vm.setShown(true)
    session.store.move(10, "/src/page.html", "render", "4", 4)
    drainPlatformCallbacks()
    createRoot proc(dispose: proc()) =
      let panel = renderLowLevelCodePanel[MockRenderer, MockNode](
        MockRenderer(), vm)
      let list = panel.allByClass("low-level-code-instructions")[0]
      # source 3, push, mov, source 4, call — in that order.
      var kinds: seq[string] = @[]
      for c in list.children:
        let cls = c.attributes.getOrDefault("class", "")
        kinds.add(if "low-level-code-source-line" in cls: "src" else: "op")
      check kinds == @["src", "op", "op", "src", "op"]
      let texts = panel.allByClass("low-level-code-source-line-text")
      check texts.len == 2
      # THE MARKUP IS TEXT: one text child, no element parsed out of it.
      check texts.len == 2 and texts[0].textContent ==
        "<img src=x onerror=alert(1)>"
      check texts.len == 2 and texts[0].elementChildren == 0
      # The debugger's line (4) marks its source row and its instruction.
      let sources = panel.allByClass("low-level-code-source-line")
      check sources.len == 2 and
            "active-source-line" notin sources[0].attributes["class"]
      check sources.len == 2 and
            "active-source-line" in sources[1].attributes["class"]
      let active = panel.allByClass("active-instruction")
      check active.len == 1
      dispose()

  test "rows that share an offset each get their own keyed row":
    let mock = newMockBackendService()
    let (session, _) = newSession(mock)
    let vm = session.lowLevelCodeVM
    createRoot proc(dispose: proc()) =
      let panel = renderLowLevelCodePanel[MockRenderer, MockNode](
        MockRenderer(), vm)
      vm.setInstructions(@[
        LowLevelInstruction(name: "a", offset: 1),
        LowLevelInstruction(name: "b", offset: 1),
        LowLevelInstruction(name: "c", offset: 1)])
      let names = panel.allByClass("low-level-code-instruction-name")
      check names.len == 3
      var got: seq[string] = @[]
      for n in names: got.add n.textContent
      check got == @["a", "b", "c"]
      # Clicking a row asks to go to ITS source line.
      vm.setInstructions(@[
        LowLevelInstruction(name: "x", offset: 1, highLevelPath: "/a.py",
                            highLevelLine: 3),
        LowLevelInstruction(name: "y", offset: 1, highLevelPath: "/a.py",
                            highLevelLine: 8)])
      mock.clearReceivedCommands()
      let rows = panel.allByClass("low-level-code-instruction")
      check rows.len == 2
      if rows.len == 2:
        rows[1].fireEvent("click")
        let jump = mock.lastArgs("ct/source-line-jump")
        check not jump.isNil and jump["line"].getInt == 8
      dispose()
