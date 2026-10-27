## test_sync.nim
##
## Unit tests for the ViewModel state mirroring system (sync layer).
##
## Verifies:
## - Signal serialization round-trips for all domain types (Location,
##   DebuggerState, SessionState, TimelineState, Variable, CallLine)
## - `applySignalUpdate` writes a mirror store, and ignores unknown vm/field
##   values
##
## The publisher, the subscriber, the action relay and whole primary/mirror
## sessions are `test_session_mirroring.nim`'s.
##
## Compile and run:
##   nim c -r src/frontend/viewmodel/tests/unit/test_sync.nim

import std/[json, unittest]
import isonim/core/[signals, computation, owner, batch]
import isonim/viewmodel
import ../../backend/backend_service
import ../../backend/mock_backend
import ../../store/types
import ../../store/replay_data_store
import ../../sync/signal_serializer

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc makeSessionVM(): tuple[session: SessionViewModel,
                            store: ReplayDataStore,
                            mock: MockBackendService] =
  ## Create a minimal SessionViewModel with a mock backend.
  ## Uses the signal_serializer's forward-declared SessionViewModel
  ## which only needs the store field.
  let mock = newMockBackendService(autoRespond = true)
  let store = createReplayDataStore(mock.toBackendService())
  let session = SessionViewModel(store: store)
  (session, store, mock)

# ---------------------------------------------------------------------------
# Serialization round-trip tests
# ---------------------------------------------------------------------------

suite "Signal serialization round-trips":

  test "Location round-trips through JSON":
    let loc = Location(file: "main.py", line: 15, column: 3)
    let j = loc.toJson
    let parsed = parseLocation(j)
    check parsed.file == "main.py"
    check parsed.line == 15
    check parsed.column == 3

  test "DebuggerState round-trips through JSON":
    let state = DebuggerState(
      location: Location(file: "test.nim", line: 42, column: 0),
      rrTicks: 200'u64,
      status: dsStepping,
      threadId: 7'u32,
    )
    let j = state.toJson
    let parsed = parseDebuggerState(j)
    check parsed.location.file == "test.nim"
    check parsed.location.line == 42
    check parsed.rrTicks == 200'u64
    check parsed.status == dsStepping
    check parsed.threadId == 7'u32

  test "SessionState round-trips through JSON":
    let state = SessionState(
      connectionStatus: csConnected,
      debugSessionMode: historicalFromLive,
      lastLiveDebugSessionMode: liveMaterialized,
      recordingHeadRRTicks: 4096'u64,
      recordingHeadLoadingState: lsLoading,
    )
    let j = state.toJson
    let parsed = parseSessionState(j)
    check parsed.connectionStatus == csConnected
    check parsed.debugSessionMode == historicalFromLive
    check parsed.lastLiveDebugSessionMode == liveMaterialized
    check parsed.recordingHeadRRTicks == 4096'u64
    check parsed.recordingHeadLoadingState == lsLoading

  test "TimelineState round-trips through JSON":
    let state = TimelineState(
      minRRTicks: 10'u64,
      maxRRTicks: 5000'u64,
      currentRRTicks: 1234'u64,
    )
    let j = state.toJson
    let parsed = parseTimelineState(j)
    check parsed.minRRTicks == 10'u64
    check parsed.maxRRTicks == 5000'u64
    check parsed.currentRRTicks == 1234'u64

  test "Variable round-trips through JSON (with children)":
    let v = Variable(
      name: "myVar",
      value: "42",
      typeName: "int",
      hasChildren: true,
      children: @[
        Variable(name: "x", value: "1", typeName: "int",
                 hasChildren: false, children: @[]),
        Variable(name: "y", value: "2", typeName: "int",
                 hasChildren: false, children: @[]),
      ],
    )
    let j = v.toJson
    let parsed = parseVariable(j)
    check parsed.name == "myVar"
    check parsed.value == "42"
    check parsed.typeName == "int"
    check parsed.hasChildren == true
    check parsed.children.len == 2
    check parsed.children[0].name == "x"
    check parsed.children[1].value == "2"

  test "CallLine round-trips through JSON":
    let line = CallLine(
      index: 99'i64,
      name: "doStuff",
      depth: 3,
      rrTicks: 500'u64,
      location: Location(file: "lib.nim", line: 10, column: 0),
    )
    let j = line.toJson
    let parsed = parseCallLine(j)
    check parsed.index == 99'i64
    check parsed.name == "doStuff"
    check parsed.depth == 3
    check parsed.rrTicks == 500'u64
    check parsed.location.file == "lib.nim"
    check parsed.location.line == 10

  test "EventLogRow round-trips through JSON":
    let row = EventLogRow(
      eventId: 77'u64,
      eventIndex: 3,
      kindId: 10,
      kind: "debugger-stop",
      file: "src/patchable.c",
      line: 12,
      value: "func()",
      rrTicks: 900'u64,
      maxRRTicks: 1200'u64,
      sourceGeneration: 2,
      sourceDigest: "digest-2",
    )
    let j = row.toJson
    let parsed = parseEventLogRow(j)
    check parsed.eventId == 77'u64
    check parsed.eventIndex == 3
    check parsed.kindId == 10
    check parsed.kind == "debugger-stop"
    check parsed.file == "src/patchable.c"
    check parsed.line == 12
    check parsed.value == "func()"
    check parsed.rrTicks == 900'u64
    check parsed.maxRRTicks == 1200'u64
    check parsed.sourceGeneration == 2
    check parsed.sourceDigest == "digest-2"

  test "Empty Variable seq round-trips":
    let vars: seq[Variable] = @[]
    let j = vars.toJson
    let parsed = parseVariableSeq(j)
    check parsed.len == 0

  test "DebuggerStatus enum values all round-trip":
    for status in DebuggerStatus:
      let j = status.toJson
      let parsed = parseDebuggerStatus(j.getStr)
      check parsed == status

  test "ConnectionStatus enum values all round-trip":
    for status in ConnectionStatus:
      let j = status.toJson
      let parsed = parseConnectionStatus(j.getStr)
      check parsed == status

# ---------------------------------------------------------------------------
# Signal update envelope tests
# ---------------------------------------------------------------------------

suite "Signal update envelope":

  test "serializeSignalUpdate creates correct structure":
    let update = serializeSignalUpdate("debugger", "state", %*{"rrTicks": 42})
    check update["vm"].getStr == "debugger"
    check update["field"].getStr == "state"
    check update["value"]["rrTicks"].getInt == 42

# ---------------------------------------------------------------------------
# applySignalUpdate tests
# ---------------------------------------------------------------------------

suite "applySignalUpdate":

  test "applies debugger state to mirror store":
    createRoot proc(dispose: proc()) =
      let (session, store, _) = makeSessionVM()
      let dbgState = DebuggerState(
        location: Location(file: "main.py", line: 15, column: 0),
        rrTicks: 200'u64,
        status: dsIdle,
        threadId: 1'u32,
      )
      let update = serializeSignalUpdate("debugger", "state", dbgState.toJson)
      applySignalUpdate(session, update)

      check store.debugger.val.rrTicks == 200'u64
      check store.debugger.val.location.file == "main.py"
      check store.debugger.val.location.line == 15
      dispose()

  test "applies session state to mirror store":
    createRoot proc(dispose: proc()) =
      let (session, store, _) = makeSessionVM()
      let update = serializeSignalUpdate("session", "state",
        SessionState(
          connectionStatus: csConnected,
          debugSessionMode: liveMcr,
          lastLiveDebugSessionMode: liveMcr,
          recordingHeadRRTicks: 512'u64,
          recordingHeadLoadingState: lsIdle,
        ).toJson)
      applySignalUpdate(session, update)

      check store.session.val.connectionStatus == csConnected
      check store.session.val.debugSessionMode == liveMcr
      check store.session.val.lastLiveDebugSessionMode == liveMcr
      check store.session.val.recordingHeadRRTicks == 512'u64
      check store.session.val.recordingHeadLoadingState == lsIdle
      dispose()

  test "applies timeline state to mirror store":
    createRoot proc(dispose: proc()) =
      let (session, store, _) = makeSessionVM()
      let state = TimelineState(
        minRRTicks: 0'u64,
        maxRRTicks: 9999'u64,
        currentRRTicks: 500'u64,
      )
      let update = serializeSignalUpdate("timeline", "state", state.toJson)
      applySignalUpdate(session, update)

      check store.timeline.val.maxRRTicks == 9999'u64
      check store.timeline.val.currentRRTicks == 500'u64
      dispose()

  test "applies calltrace lines to mirror store":
    createRoot proc(dispose: proc()) =
      let (session, store, _) = makeSessionVM()
      let lines = @[
        CallLine(index: 0, name: "main", depth: 0, rrTicks: 100'u64,
                 location: Location(file: "a.nim", line: 1, column: 0)),
        CallLine(index: 1, name: "foo", depth: 1, rrTicks: 200'u64,
                 location: Location(file: "b.nim", line: 5, column: 0)),
      ]
      let update = serializeSignalUpdate("calltrace", "lines", lines.toJson)
      applySignalUpdate(session, update)

      check store.calltrace.lines.val.len == 2
      check store.calltrace.lines.val[0].name == "main"
      check store.calltrace.lines.val[1].name == "foo"
      dispose()

  test "applies locals to mirror store":
    createRoot proc(dispose: proc()) =
      let (session, store, _) = makeSessionVM()
      let vars = @[
        Variable(name: "x", value: "10", typeName: "int",
                 hasChildren: false, children: @[]),
      ]
      let update = serializeSignalUpdate("locals", "locals", vars.toJson)
      applySignalUpdate(session, update)

      check store.locals.locals.val.len == 1
      check store.locals.locals.val[0].name == "x"
      check store.locals.locals.val[0].value == "10"
      dispose()

  test "unknown vm name is silently ignored":
    createRoot proc(dispose: proc()) =
      let (session, store, _) = makeSessionVM()
      let update = serializeSignalUpdate("nonexistent", "field", %"value")
      # Should not raise.
      applySignalUpdate(session, update)
      # Store state unchanged.
      check store.debugger.val.rrTicks == 0'u64
      dispose()

  test "unknown field name is silently ignored":
    createRoot proc(dispose: proc()) =
      let (session, store, _) = makeSessionVM()
      let update = serializeSignalUpdate("debugger", "nonexistent", %"value")
      applySignalUpdate(session, update)
      check store.debugger.val.rrTicks == 0'u64
      dispose()

# ---------------------------------------------------------------------------
# SyncPublisher tests
# ---------------------------------------------------------------------------
