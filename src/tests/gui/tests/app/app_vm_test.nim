## Headless tests for CodeTracerAppVM.
##
## These are the intended counterparts for app-level GUI operations: no
## Electron, no GoldenLayout, no IPC. Tests drive the same ViewModel
## composition that production adapters should call.

import std/[options, unittest]

import vm_test_helpers
import isonim/core/computation
import isonim/core/signals
import app_vm
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
