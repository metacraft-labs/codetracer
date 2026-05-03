## browser_replay_vm_test.nim
##
## Headless companions for:
##   - browser-materialized-replay.spec.ts
##   - browser-mcr-replay.spec.ts
##
## These tests model the browser replay flow at the ViewModel layer: replay
## mode metadata, editor source, event log rows and calltrace navigation. They
## intentionally do not launch `ct host`; WebSocket/VFS transport remains a
## lower-layer integration concern.

import std/[json, os, strutils, unittest]

import vm_test_helpers
import isonim/core/[signals, computation, owner]
import backend/mock_backend
import session_vm
import store/types
import viewmodels/calltrace_vm
import viewmodels/replay_lifecycle_vm

type
  BrowserReplayConfig = object
    name: string
    traceKind: ReplayTraceKind
    sourcePath: string
    entryFunction: string
    outputText: string
    variableName: string

proc makeCallLine(index: int64; name, file: string; line: int;
                  rrTicks: uint64): CallLine =
  CallLine(
    index: index,
    name: name,
    depth: 0,
    rrTicks: rrTicks,
    location: Location(file: file, line: line, column: 0),
    hasChildren: false,
    isExpanded: false,
    callKey: name & ":" & $index,
  )

proc makeEventRow(eventId: uint64; line: int; value: string): EventLogRow =
  EventLogRow(eventId: eventId, kind: "stdout", line: line, value: value)

proc makeVariable(name, value: string): Variable =
  Variable(
    name: name,
    value: value,
    typeName: "object",
    hasChildren: false,
    children: @[],
  )

proc seedBrowserReplay(config: BrowserReplayConfig) =
  createRoot proc(dispose: proc()) =
    let mock = newMockBackendService(autoRespond = true)
    let session = createSessionVM(mock.toBackendService())
    let lifecycle = createReplayLifecycleVM(session.store)

    lifecycle.configureReplay(
      rdmWeb,
      config.traceKind,
      config.sourcePath,
      config.entryFunction,
    )
    lifecycle.beginLoading()
    lifecycle.markBackendReady()

    var dbg = session.store.debugger.val
    dbg.location = Location(file: config.sourcePath, line: 1, column: 0)
    dbg.rrTicks = 1'u64
    dbg.status = dsIdle
    session.store.debugger.val = dbg

    session.store.calltrace.lines.val = @[
      makeCallLine(0'i64, config.entryFunction, config.sourcePath, 1, 1'u64),
    ]
    session.store.calltrace.startLineIndex.val = 0'i64
    session.store.calltrace.totalCallsCount.val = 1'u64
    session.store.calltrace.finished.val = true
    session.calltraceVM.setViewportHeight(20)

    session.eventLogVM.eventRows.val = @[
      makeEventRow(1'u64, 1, config.outputText),
    ]
    session.eventLogVM.totalEventCount.val = 1
    if config.variableName.len > 0:
      session.store.locals.locals.val = @[
        makeVariable(config.variableName, "[[5, 3], [6, 7]]"),
      ]
    drain()

    check lifecycle.isBrowserReplay.val == true
    check lifecycle.isReady.val == true
    check lifecycle.sourcePath.val == config.sourcePath
    check session.editorVM.activeFileName.val.endsWith(config.sourcePath.extractFilename())
    check session.eventLogVM.eventRows.val.len == 1
    check session.calltraceVM.visibleLines.val.len == 1
    check session.calltraceVM.visibleLines.val[0].name == config.entryFunction
    if config.variableName.len > 0:
      check session.stateVM.currentVariables.val.len == 1
      check session.stateVM.currentVariables.val[0].name == config.variableName

    let beforeJump = mock.receivedCommands.len
    session.calltraceVM.doubleClickEntry(0)
    drain()
    check mock.receivedCommands.len == beforeJump + 1
    check mock.receivedCommands[^1].command == "ct/calltrace-jump"
    check mock.receivedCommands[^1].args["path"].getStr == config.sourcePath
    dispose()

suite "BrowserReplayVM - materialized DB trace":

  test "browser materialized replay exposes Python editor, event log and solve_sudoku calltrace":
    ## Paired to browser-materialized-replay.spec.ts:
    ## editor loads main.py, event log populates, calltrace navigates
    ## to solve_sudoku in web deployment mode.
    seedBrowserReplay(BrowserReplayConfig(
      name: "browser-materialized-replay",
      traceKind: rtkMaterialized,
      sourcePath: "py_sudoku_solver/main.py",
      entryFunction: "solve_sudoku",
      outputText: "Solved Python sudoku",
      variableName: "",
    ))

  test "materialized browser mode flag is distinct from MCR":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())
      let lifecycle = createReplayLifecycleVM(session.store)
      lifecycle.configureReplay(rdmWeb, rtkMaterialized,
                                "py_sudoku_solver/main.py", "solve_sudoku")
      check lifecycle.isBrowserReplay.val == true
      check lifecycle.isMaterializedBrowserReplay.val == true
      check lifecycle.isMcrBrowserReplay.val == false
      dispose()

suite "BrowserReplayVM - MCR trace":

  test "browser MCR replay exposes C editor, event log, main calltrace and output":
    ## Paired to browser-mcr-replay.spec.ts:
    ## editor loads main.c, event log populates/contains Solved, and
    ## calltrace navigation targets main in web deployment mode.
    seedBrowserReplay(BrowserReplayConfig(
      name: "browser-mcr-replay",
      traceKind: rtkMcr,
      sourcePath: "c_sudoku_solver/main.c",
      entryFunction: "main",
      outputText: "Solved",
      variableName: "test_boards",
    ))

  test "MCR browser mode flag is distinct from materialized":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let session = createSessionVM(mock.toBackendService())
      let lifecycle = createReplayLifecycleVM(session.store)
      lifecycle.configureReplay(rdmWeb, rtkMcr,
                                "c_sudoku_solver/main.c", "main")
      check lifecycle.isBrowserReplay.val == true
      check lifecycle.isMcrBrowserReplay.val == true
      check lifecycle.isMaterializedBrowserReplay.val == false
      dispose()
