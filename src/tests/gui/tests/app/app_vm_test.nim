## Headless tests for CodeTracerAppVM.
##
## These are the intended counterparts for app-level GUI operations: no
## Electron, no GoldenLayout, no IPC. Tests drive the same ViewModel
## composition that production adapters should call.

import std/[options, tables, unittest]

import vm_test_helpers
import isonim/core/computation
import isonim/core/signals
import app_vm
import app_vm_bridge
import backend/mock_backend
import session_vm
import store/types

type
  MockList = ref object
    items: seq[MockBackendService]

  TestHarness = object
    app: CodeTracerAppVM
    mocks: MockList

proc newHarness(indexedFiles: seq[string] = @[]): TestHarness =
  let mocks = MockList(items: @[])

  proc makeSession(): SessionViewModel =
    let mock = newMockBackendService(autoRespond = true)
    mocks.items.add(mock)
    createSessionVM(mock.toBackendService())

  proc indexFolder(folderPath: string): seq[string] =
    indexedFiles

  result.app = createCodeTracerAppVM(makeSession, indexFolder)
  result.mocks = mocks

suite "CodeTracerAppVM":

  test "starts with a composed welcome session":
    var h = newHarness()
    check h.app.sessionCount == 1
    check h.app.activeSessionIndex.val == 0
    check h.app.activeSession.kind.val == askWelcome
    check h.app.activeSession.session.editorVM != nil
    check h.app.activeSession.session.debugControlsVM != nil
    check h.app.activeSession.welcomeVM != nil

  test "createWelcomeTab and switchSession are headless app operations":
    var h = newHarness()
    let second = h.app.createWelcomeTab()
    check second == 1
    check h.app.sessionCount == 2
    check h.app.activeSessionIndex.val == 1
    check h.app.activeSession.kind.val == askWelcome

    check h.app.switchSession(0)
    check h.app.activeSessionIndex.val == 0
    check not h.app.switchSession(99)
    check h.app.activeSessionIndex.val == 0

  test "openFolder enters edit mode, indexes files and opens first file":
    let files = @["/workspace/project/src/main.nim", "/workspace/project/README.md"]
    var h = newHarness(files)

    check h.app.openFolder("/workspace/project")
    let active = h.app.activeSession
    check active.kind.val == askEdit
    check active.editFolderPath.val == "/workspace/project"
    check active.indexedFiles.val == files
    check active.openFiles.val == @[files[0]]
    check active.welcomeVM.editMode.val == true
    check active.welcomeVM.launchConfig.val.editFolderPath == "/workspace/project"
    check active.session.editorVM.activeFileName.val == files[0]

  test "openFile selects existing file without duplicating tabs":
    let files = @["/workspace/project/src/main.nim", "/workspace/project/src/lib.nim"]
    var h = newHarness(files)
    check h.app.openFolder("/workspace/project")
    check h.app.openFile(files[1])
    check h.app.openFile(files[1])

    let active = h.app.activeSession
    check active.openFiles.val == files
    check active.session.editorVM.activeFileName.val == files[1]
    check active.session.editorVM.activeTabIndex.val == 1

  test "toolbar and keyboard debug actions route to active session only":
    var h = newHarness()
    discard h.app.createWelcomeTab()

    check h.app.switchSession(0)
    check h.app.invokeDebugAction("next")
    drain()
    check h.mocks.items[0].findCommand("next").isSome
    check h.mocks.items[1].findCommand("next").isNone

    h.mocks.items[0].clearReceivedCommands()
    check h.app.switchSession(1)
    check h.app.dispatchShortcut("F10")
    drain()
    check h.mocks.items[0].findCommand("next").isNone
    check h.mocks.items[1].findCommand("next").isSome

  test "runtime bridge exposes app operations to legacy adapters":
    resetAppVMBridgeForTests()
    let mock = newMockBackendService(autoRespond = true)
    let session = createSessionVM(mock.toBackendService())
    initAppVMBridge(session)

    check activeAppVM.sessionCount == 1
    let files = @["/workspace/project/src/main.nim"]
    check noteFolderOpened("/workspace/project", files)
    check activeAppVM.activeSession.kind.val == askEdit
    check activeAppVM.activeSession.openFiles.val == files

    check noteWelcomeTabCreated() == 1
    check activeAppVM.activeSessionIndex.val == 1
    check noteSessionSwitched(0)
    check activeAppVM.activeSessionIndex.val == 0

    check dispatchDebugAction("next")
    drain()
    check mock.findCommand("next").isSome

  test "runtime bridge initialization preserves populated session store":
    resetAppVMBridgeForTests()
    let mock = newMockBackendService(autoRespond = true)
    let session = createSessionVM(mock.toBackendService())
    let store = session.store

    store.calltrace.lines.val = @[
      CallLine(
        index: 1,
        name: "SudokuSolver#solve",
        depth: 0,
        rrTicks: 42'u64,
        location: Location(file: "sudoku_solver.rb", line: 17, column: 0),
        hasChildren: false,
        isExpanded: false,
        callKey: "call-1",
      )
    ]
    var args = initTable[string, seq[CallArg]]()
    args["call-1"] = @[CallArg(name: "board", text: "[[1, 2], [3, 4]]")]
    store.calltrace.args.val = args
    store.locals.locals.val = @[
      Variable(name: "board", value: "[[1, 2], [3, 4]]",
        typeName: "Array", hasChildren: false, children: @[])
    ]
    store.locals.codeStateLine.val = "17 | def solve"
    store.session.val = SessionState(connectionStatus: csConnected)
    store.timeline.val = TimelineState(
      minRRTicks: 0'u64,
      maxRRTicks: 100'u64,
      currentRRTicks: 42'u64,
    )
    store.debugger.val = DebuggerState(
      location: Location(file: "sudoku_solver.rb", line: 17, column: 0),
      rrTicks: 42'u64,
      status: dsIdle,
      threadId: 1'u32,
    )

    initAppVMBridge(session)

    check activeAppVM.sessionCount == 1
    check activeAppVM.activeSession.session.store == store
    check store.calltrace.lines.val.len == 1
    check store.calltrace.lines.val[0].name == "SudokuSolver#solve"
    check store.calltrace.args.val["call-1"][0].name == "board"
    check store.locals.locals.val[0].name == "board"
    check store.locals.codeStateLine.val == "17 | def solve"
    check store.session.val.connectionStatus == csConnected
    check store.timeline.val.currentRRTicks == 42'u64
    check store.debugger.val.location.file == "sudoku_solver.rb"
