## test_sync.nim
##
## Unit tests for the ViewModel state mirroring system (sync layer).
##
## Verifies:
## - Signal serialization round-trips for all domain types (Location,
##   DebuggerState, SessionState, TimelineState, Variable, CallLine)
## - SyncPublisher observes signal changes and publishes JSON messages
## - SyncSubscriber applies messages to a mirror store
## - Full round-trip: primary signal change -> publish -> subscribe -> mirror
## - Batch updates are applied atomically
## - Action serialization and dispatch
## - Unknown vm/field/action values are silently ignored
##
## Compile and run:
##   nim c -r src/frontend/viewmodel/tests/unit/test_sync.nim

import std/[json, unittest, asyncdispatch]
import isonim/core/[signals, computation, owner, batch]
import isonim/viewmodel
import ../../backend/backend_service
import ../../backend/mock_backend
import ../../store/types
import ../../store/replay_data_store
import ../../sync/signal_serializer
import ../../sync/sync_publisher
import ../../sync/sync_subscriber
import ../../sync/action_relay
import ../../viewmodels/[
  calltrace_vm,
  state_vm,
  debug_controls_vm,
  event_log_vm,
  search_vm,
]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc drain() =
  ## Drain the async event loop so that all synchronously-completed
  ## futures fire their callbacks.
  try:
    poll(0)
  except ValueError:
    discard

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

suite "SyncPublisher":

  test "publishes initial signal values on creation":
    createRoot proc(dispose: proc()) =
      let (session, store, _) = makeSessionVM()
      var messages: seq[JsonNode] = @[]
      let publisher = createSyncPublisher(session, proc(msg: JsonNode) =
        messages.add(msg))

      # Effects run immediately on creation, so we should have initial
      # messages for all watched signals.
      check messages.len > 0

      # Verify at least the debugger state was published.
      var foundDebugger = false
      for msg in messages:
        if msg["vm"].getStr == "debugger" and msg["field"].getStr == "state":
          foundDebugger = true
          check msg["value"]["rrTicks"].getBiggestInt == 0
      check foundDebugger
      dispose()

  test "publishes when debugger signal changes":
    createRoot proc(dispose: proc()) =
      let (session, store, _) = makeSessionVM()
      var messages: seq[JsonNode] = @[]
      let publisher = createSyncPublisher(session, proc(msg: JsonNode) =
        messages.add(msg))

      # Clear initial messages.
      messages.setLen(0)

      # Change debugger state.
      store.debugger.val = DebuggerState(
        location: Location(file: "changed.nim", line: 99, column: 0),
        rrTicks: 555'u64,
        status: dsIdle,
        threadId: 0'u32,
      )

      # The effect should have fired and published a message.
      var found = false
      for msg in messages:
        if msg["vm"].getStr == "debugger":
          found = true
          check msg["value"]["rrTicks"].getBiggestInt == 555
          check msg["value"]["location"]["file"].getStr == "changed.nim"
      check found
      dispose()

  test "publishes calltrace line changes":
    createRoot proc(dispose: proc()) =
      let (session, store, _) = makeSessionVM()
      var messages: seq[JsonNode] = @[]
      let publisher = createSyncPublisher(session, proc(msg: JsonNode) =
        messages.add(msg))

      messages.setLen(0)

      store.calltrace.lines.val = @[
        CallLine(index: 0, name: "entry", depth: 0, rrTicks: 1'u64,
                 location: Location(file: "a.nim", line: 1, column: 0)),
      ]

      var found = false
      for msg in messages:
        if msg["vm"].getStr == "calltrace" and msg["field"].getStr == "lines":
          found = true
          check msg["value"].len == 1
          check msg["value"][0]["name"].getStr == "entry"
      check found
      dispose()

  test "publishes locals changes":
    createRoot proc(dispose: proc()) =
      let (session, store, _) = makeSessionVM()
      var messages: seq[JsonNode] = @[]
      let publisher = createSyncPublisher(session, proc(msg: JsonNode) =
        messages.add(msg))

      messages.setLen(0)

      store.locals.locals.val = @[
        Variable(name: "z", value: "99", typeName: "int",
                 hasChildren: false, children: @[]),
      ]

      var found = false
      for msg in messages:
        if msg["vm"].getStr == "locals" and msg["field"].getStr == "locals":
          found = true
          check msg["value"].len == 1
          check msg["value"][0]["name"].getStr == "z"
      check found
      dispose()

# ---------------------------------------------------------------------------
# SyncSubscriber tests
# ---------------------------------------------------------------------------

suite "SyncSubscriber":

  test "applies single signal-update message":
    createRoot proc(dispose: proc()) =
      let (session, store, _) = makeSessionVM()
      let subscriber = createSyncSubscriber(session)

      let msg = %*{
        "type": "signal-update",
        "vm": "debugger",
        "field": "state",
        "value": DebuggerState(
          location: Location(file: "sub.nim", line: 7, column: 0),
          rrTicks: 333'u64,
          status: dsRunning,
          threadId: 2'u32,
        ).toJson,
      }
      subscriber.onMessage(msg)

      check store.debugger.val.rrTicks == 333'u64
      check store.debugger.val.status == dsRunning
      check store.debugger.val.location.file == "sub.nim"
      dispose()

  test "applies signal-batch message atomically":
    createRoot proc(dispose: proc()) =
      let (session, store, _) = makeSessionVM()
      let subscriber = createSyncSubscriber(session)

      # Track how many times the debugger effect fires.
      var effectCount = 0
      createEffect proc() =
        discard store.debugger.val
        discard store.calltrace.lines.val
        inc effectCount

      # Initial effect execution.
      let initialCount = effectCount

      let msg = %*{
        "type": "signal-batch",
        "batch": [
          serializeSignalUpdate("debugger", "state", DebuggerState(
            location: Location(file: "batch.nim", line: 1, column: 0),
            rrTicks: 777'u64,
            status: dsIdle,
            threadId: 0'u32,
          ).toJson),
          serializeSignalUpdate("calltrace", "lines", @[
            CallLine(index: 0, name: "batchEntry", depth: 0, rrTicks: 777'u64,
                     location: Location(file: "batch.nim", line: 1, column: 0)),
          ].toJson),
        ],
      }
      subscriber.onMessage(msg)

      # Both signals should be updated.
      check store.debugger.val.rrTicks == 777'u64
      check store.calltrace.lines.val.len == 1
      check store.calltrace.lines.val[0].name == "batchEntry"

      # The effect should have fired only once for the batch (not twice),
      # since batch() defers reactive updates. The initial run counted
      # as 1, and the batch should add exactly 1 more.
      check effectCount == initialCount + 1
      dispose()

  test "ignores unknown message type":
    createRoot proc(dispose: proc()) =
      let (session, store, _) = makeSessionVM()
      let subscriber = createSyncSubscriber(session)

      let msg = %*{"type": "unknown-type", "data": "hello"}
      # Should not raise.
      subscriber.onMessage(msg)
      # Store unchanged.
      check store.debugger.val.rrTicks == 0'u64
      dispose()

# ---------------------------------------------------------------------------
# Full round-trip: primary -> publisher -> subscriber -> mirror
# ---------------------------------------------------------------------------

suite "Full round-trip":

  test "debugger state round-trips from primary to mirror":
    createRoot proc(dispose: proc()) =
      let (primary, primaryStore, _) = makeSessionVM()
      let (mirror, mirrorStore, _) = makeSessionVM()

      # Capture published messages.
      var messages: seq[JsonNode] = @[]
      let publisher = createSyncPublisher(primary, proc(msg: JsonNode) =
        messages.add(msg))
      let subscriber = createSyncSubscriber(mirror)

      # Clear initial messages.
      messages.setLen(0)

      # Change primary state.
      primaryStore.updateDebuggerPosition(200'u64, "main.py", 15)

      # Wrap each message as a signal-update and apply to mirror.
      for msg in messages:
        let wrapped = %*{
          "type": "signal-update",
          "vm": msg["vm"].getStr,
          "field": msg["field"].getStr,
          "value": msg["value"],
        }
        subscriber.onMessage(wrapped)

      # Verify mirror matches primary.
      check mirrorStore.debugger.val.rrTicks == 200'u64
      check mirrorStore.debugger.val.location.file == "main.py"
      check mirrorStore.debugger.val.location.line == 15
      dispose()

  test "calltrace lines round-trip from primary to mirror":
    createRoot proc(dispose: proc()) =
      let (primary, primaryStore, _) = makeSessionVM()
      let (mirror, mirrorStore, _) = makeSessionVM()

      var messages: seq[JsonNode] = @[]
      let publisher = createSyncPublisher(primary, proc(msg: JsonNode) =
        messages.add(msg))
      let subscriber = createSyncSubscriber(mirror)

      messages.setLen(0)

      # Update primary calltrace.
      let lines = @[
        CallLine(index: 0, name: "main", depth: 0, rrTicks: 100'u64,
                 location: Location(file: "a.nim", line: 1, column: 0)),
        CallLine(index: 1, name: "helper", depth: 1, rrTicks: 150'u64,
                 location: Location(file: "b.nim", line: 20, column: 0)),
      ]
      primaryStore.calltrace.lines.val = lines

      for msg in messages:
        let wrapped = %*{
          "type": "signal-update",
          "vm": msg["vm"].getStr,
          "field": msg["field"].getStr,
          "value": msg["value"],
        }
        subscriber.onMessage(wrapped)

      check mirrorStore.calltrace.lines.val.len == 2
      check mirrorStore.calltrace.lines.val[0].name == "main"
      check mirrorStore.calltrace.lines.val[1].name == "helper"
      check mirrorStore.calltrace.lines.val[1].rrTicks == 150'u64
      dispose()

  test "locals round-trip from primary to mirror":
    createRoot proc(dispose: proc()) =
      let (primary, primaryStore, _) = makeSessionVM()
      let (mirror, mirrorStore, _) = makeSessionVM()

      var messages: seq[JsonNode] = @[]
      let publisher = createSyncPublisher(primary, proc(msg: JsonNode) =
        messages.add(msg))
      let subscriber = createSyncSubscriber(mirror)

      messages.setLen(0)

      primaryStore.locals.locals.val = @[
        Variable(name: "count", value: "42", typeName: "int",
                 hasChildren: false, children: @[]),
        Variable(name: "items", value: "[1,2,3]", typeName: "seq[int]",
                 hasChildren: true, children: @[
                   Variable(name: "0", value: "1", typeName: "int",
                            hasChildren: false, children: @[]),
                 ]),
      ]

      for msg in messages:
        let wrapped = %*{
          "type": "signal-update",
          "vm": msg["vm"].getStr,
          "field": msg["field"].getStr,
          "value": msg["value"],
        }
        subscriber.onMessage(wrapped)

      check mirrorStore.locals.locals.val.len == 2
      check mirrorStore.locals.locals.val[0].name == "count"
      check mirrorStore.locals.locals.val[1].children.len == 1
      dispose()

# ---------------------------------------------------------------------------
# Action relay tests
# ---------------------------------------------------------------------------

suite "Action serialization":

  test "serializeAction creates correct structure":
    let msg = serializeAction("debugControls", "stepForward")
    check msg["type"].getStr == "action"
    check msg["vm"].getStr == "debugControls"
    check msg["action"].getStr == "stepForward"

  test "serializeAction includes args":
    let msg = serializeAction("calltrace", "scroll",
                              %*{"position": 100})
    check msg["args"]["position"].getInt == 100

suite "Action dispatch":

  test "stepForward action dispatches to debug controls":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())

      let session = FullSessionViewModel(
        store: store,
        debugControlsVM: createDebugControlsVM(store),
        calltraceVM: createCalltraceVM(store),
        stateVM: createStateVM(store),
        eventLogVM: createEventLogVM(store),
        searchVM: createSearchVM(store),
      )

      let msg = serializeAction("debugControls", "stepForward")
      applyAction(session, msg)
      drain()

      # The debug controls VM should have sent a step command.
      check mock.receivedCommands.len >= 1
      var foundStep = false
      for cmd in mock.receivedCommands:
        if cmd.command == "next":
          foundStep = true
      check foundStep
      dispose()

  test "reverse step actions dispatch through debug controls":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      var dbg = store.debugger.val
      dbg.rrTicks = 10'u64
      dbg.status = dsIdle
      store.debugger.val = dbg

      let session = FullSessionViewModel(
        store: store,
        debugControlsVM: createDebugControlsVM(store),
        calltraceVM: createCalltraceVM(store),
        stateVM: createStateVM(store),
        eventLogVM: createEventLogVM(store),
        searchVM: createSearchVM(store),
      )

      applyAction(session, serializeAction("debugControls", "reverseStepIn"))
      drain()

      check mock.receivedCommands.len >= 1
      check mock.receivedCommands[^1].command == "ct/reverseStepIn"
      check mock.receivedCommands[^1].args["threadId"].getInt == 1
      dispose()

  test "calltrace scroll action updates scroll position":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())

      let session = FullSessionViewModel(
        store: store,
        debugControlsVM: createDebugControlsVM(store),
        calltraceVM: createCalltraceVM(store),
        stateVM: createStateVM(store),
        eventLogVM: createEventLogVM(store),
        searchVM: createSearchVM(store),
      )

      let msg = serializeAction("calltrace", "scroll",
                                %*{"position": 50})
      applyAction(session, msg)

      check session.calltraceVM.scrollPosition.val == 50'i64
      dispose()

  test "state addWatch action adds a watch expression":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())

      let session = FullSessionViewModel(
        store: store,
        debugControlsVM: createDebugControlsVM(store),
        calltraceVM: createCalltraceVM(store),
        stateVM: createStateVM(store),
        eventLogVM: createEventLogVM(store),
        searchVM: createSearchVM(store),
      )

      let msg = serializeAction("state", "addWatch",
                                %*{"expression": "myVar + 1"})
      applyAction(session, msg)

      check session.stateVM.watchExpressions.val.len == 1
      check session.stateVM.watchExpressions.val[0] == "myVar + 1"
      dispose()

  test "unknown vm in action is silently ignored":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())

      let session = FullSessionViewModel(
        store: store,
        debugControlsVM: createDebugControlsVM(store),
        calltraceVM: createCalltraceVM(store),
        stateVM: createStateVM(store),
        eventLogVM: createEventLogVM(store),
        searchVM: createSearchVM(store),
      )

      let msg = serializeAction("nonexistent", "doSomething")
      # Should not raise.
      applyAction(session, msg)
      dispose()
