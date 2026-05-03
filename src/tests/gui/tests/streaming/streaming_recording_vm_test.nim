## streaming_recording_vm_test.nim
##
## Headless companion for streaming-recording.spec.ts.
##
## The GUI spec verifies that a Python streaming recording exposes three
## burst_activity phases, compute_fibonacci calls, editor navigation and
## variables. This file drives the same intent with MockBackendService and
## ViewModel signals; recorder process lifecycle remains a lower layer.

import std/[json, sequtils, unittest]

import vm_test_helpers
import isonim/core/[signals, computation, owner]
import backend/mock_backend
import session_vm
import store/types
import viewmodels/calltrace_vm
import viewmodels/replay_lifecycle_vm

proc makeCallLine(index: int64; name: string; line: int;
                  depth: int; rrTicks: uint64): CallLine =
  CallLine(
    index: index,
    name: name,
    depth: depth,
    rrTicks: rrTicks,
    location: Location(file: "py_streaming_test/main.py", line: line, column: 0),
    hasChildren: false,
    isExpanded: false,
    callKey: name & ":" & $index,
  )

proc makeVariable(name, value: string): Variable =
  Variable(
    name: name,
    value: value,
    typeName: "int",
    hasChildren: false,
    children: @[],
  )

proc seedStreamingSession(): tuple[session: SessionViewModel,
                                   lifecycle: ReplayLifecycleVM,
                                   mock: MockBackendService] =
  let mock = newMockBackendService(autoRespond = true)
  let session = createSessionVM(mock.toBackendService())
  let lifecycle = createReplayLifecycleVM(session.store)

  lifecycle.configureReplay(rdmDesktop, rtkMaterialized,
                            "py_streaming_test/main.py",
                            "burst_activity")
  lifecycle.beginStreaming(expectedPhases = 3)

  var dbg = session.store.debugger.val
  dbg.location = Location(file: "py_streaming_test/main.py", line: 19, column: 0)
  dbg.rrTicks = 10'u64
  dbg.status = dsIdle
  session.store.debugger.val = dbg

  session.store.calltrace.lines.val = @[
    makeCallLine(0'i64, "burst_activity", 19, 0, 10'u64),
    makeCallLine(1'i64, "compute_fibonacci", 11, 1, 11'u64),
    makeCallLine(2'i64, "burst_activity", 31, 0, 20'u64),
    makeCallLine(3'i64, "compute_fibonacci", 11, 1, 21'u64),
    makeCallLine(4'i64, "burst_activity", 36, 0, 30'u64),
    makeCallLine(5'i64, "compute_fibonacci", 11, 1, 31'u64),
  ]
  session.store.calltrace.startLineIndex.val = 0'i64
  session.store.calltrace.totalCallsCount.val = 6'u64
  session.store.calltrace.finished.val = true
  session.calltraceVM.setViewportHeight(20)

  session.store.locals.locals.val = @[
    makeVariable("n", "8"),
    makeVariable("a", "0"),
    makeVariable("b", "1"),
  ]
  drain()

  (session, lifecycle, mock)

suite "StreamingRecordingVM":

  test "captures all three burst_activity phases":
    createRoot proc(dispose: proc()) =
      let (session, lifecycle, _) = seedStreamingSession()
      for i in 0 ..< 3:
        lifecycle.recordStreamingPhase()
      check lifecycle.completedStreamingPhases.val == 3
      check lifecycle.hasAllStreamingPhases.val == true
      check lifecycle.stage.val == rlsComplete

      var burstCount = 0
      for line in session.calltraceVM.visibleLines.val:
        if line.name == "burst_activity":
          inc burstCount
      check burstCount == 3
      dispose()

  test "calltrace shows burst_activity and compute_fibonacci":
    createRoot proc(dispose: proc()) =
      let (session, _, _) = seedStreamingSession()
      let visible = session.calltraceVM.visibleLines.val
      check visible.anyIt(it.name == "burst_activity")
      check visible.anyIt(it.name == "compute_fibonacci")
      session.calltraceVM.setSearchQuery("compute_fibonacci")
      check session.calltraceVM.highlightedMatches.val.len == 3
      dispose()

  test "calltrace activation dispatches navigation to main.py":
    createRoot proc(dispose: proc()) =
      let (session, _, mock) = seedStreamingSession()
      let beforeJump = mock.receivedCommands.len
      session.calltraceVM.doubleClickEntry(0)
      drain()
      check mock.receivedCommands.len == beforeJump + 1
      check mock.receivedCommands[^1].command == "ct/calltrace-jump"
      check mock.receivedCommands[^1].args["path"].getStr ==
        "py_streaming_test/main.py"
      check session.editorVM.activeFileName.val == "py_streaming_test/main.py"
      dispose()

  test "compute_fibonacci variables are available through StateVM":
    createRoot proc(dispose: proc()) =
      let (session, _, _) = seedStreamingSession()
      let vars = session.stateVM.currentVariables.val
      check vars.anyIt(it.name == "n")
      check vars.anyIt(it.name == "a")
      check vars.anyIt(it.name == "b")
      dispose()

  test "streaming failure records a lifecycle error":
    createRoot proc(dispose: proc()) =
      let (_, lifecycle, _) = seedStreamingSession()
      lifecycle.failReplay("stream disconnected")
      check lifecycle.stage.val == rlsError
      check lifecycle.errorMessage.val == "stream disconnected"
      check lifecycle.isReady.val == false
      dispose()
