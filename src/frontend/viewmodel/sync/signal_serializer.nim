## sync/signal_serializer.nim
##
## Serialize and deserialize ViewModel signal values to/from JSON for
## transmission between primary and mirror processes.
##
## The serialization covers all ViewModel domain types defined in
## store/types.nim: Location, DebuggerState, SessionState, TimelineState,
## CallLine, Variable, and EventLogRow.
##
## This module is the single source of truth for the JSON wire format
## used by SyncPublisher and SyncSubscriber. Both JS and native backends
## are supported (uses std/json only).
##
## Usage:
##   let msg = serializeSignalUpdate("debugger", "state", debuggerState)
##   applySignalUpdate(session, msg)

import std/json

import isonim/core/signals

import ../store/types
import ../store/replay_data_store

# Forward-declare SessionViewModel to avoid circular imports.
# The actual type is imported by sync_publisher/sync_subscriber which
# use this module's procs.
type
  SessionViewModel* = ref object
    ## Minimal forward declaration for the apply proc.
    ## The real SessionViewModel is in session_vm.nim; we only need
    ## the store field here.
    store*: ReplayDataStore

# ---------------------------------------------------------------------------
# Type -> JSON serialization
# ---------------------------------------------------------------------------

proc toJson*(loc: Location): JsonNode =
  ## Serialize a Location to JSON.
  %*{"file": loc.file, "line": loc.line, "column": loc.column}

proc toJson*(status: DebuggerStatus): JsonNode =
  ## Serialize a DebuggerStatus enum to its string representation.
  %($status)

proc toJson*(status: ConnectionStatus): JsonNode =
  ## Serialize a ConnectionStatus enum to its string representation.
  %($status)

proc toJson*(state: DebuggerState): JsonNode =
  ## Serialize a full DebuggerState to JSON.
  %*{
    "location": state.location.toJson,
    "rrTicks": % state.rrTicks,
    "status": state.status.toJson,
    "threadId": % state.threadId,
  }

proc toJson*(state: SessionState): JsonNode =
  ## Serialize a SessionState to JSON.
  %*{"connectionStatus": state.connectionStatus.toJson}

proc toJson*(state: TimelineState): JsonNode =
  ## Serialize a TimelineState to JSON.
  %*{
    "minRRTicks": % state.minRRTicks,
    "maxRRTicks": % state.maxRRTicks,
    "currentRRTicks": % state.currentRRTicks,
  }

proc toJson*(v: Variable): JsonNode =
  ## Serialize a Variable (recursively including children) to JSON.
  var childrenJson = newJArray()
  for child in v.children:
    childrenJson.add(child.toJson)
  %*{
    "name": v.name,
    "value": v.value,
    "typeName": v.typeName,
    "hasChildren": v.hasChildren,
    "children": childrenJson,
  }

proc toJson*(line: CallLine): JsonNode =
  ## Serialize a CallLine to JSON.
  %*{
    "index": line.index,
    "name": line.name,
    "depth": line.depth,
    "rrTicks": % line.rrTicks,
    "location": line.location.toJson,
  }

proc toJson*(row: EventLogRow): JsonNode =
  ## Serialize an EventLogRow to JSON.
  %*{
    "eventId": % row.eventId,
    "kind": row.kind,
    "line": row.line,
    "value": row.value,
  }

proc toJson*[T](items: seq[T]): JsonNode =
  ## Serialize a sequence of serializable items to a JSON array.
  var arr = newJArray()
  for item in items:
    arr.add(item.toJson)
  arr

# ---------------------------------------------------------------------------
# JSON -> Type deserialization
# ---------------------------------------------------------------------------

proc parseLocation*(j: JsonNode): Location =
  ## Parse a Location from JSON.
  Location(
    file: j["file"].getStr,
    line: j["line"].getInt,
    column: j["column"].getInt,
  )

proc parseDebuggerStatus*(s: string): DebuggerStatus =
  ## Parse a DebuggerStatus from its string representation.
  case s
  of "dsIdle": dsIdle
  of "dsStepping": dsStepping
  of "dsRunning": dsRunning
  of "dsFinished": dsFinished
  of "dsError": dsError
  else: dsIdle

proc parseConnectionStatus*(s: string): ConnectionStatus =
  ## Parse a ConnectionStatus from its string representation.
  case s
  of "csDisconnected": csDisconnected
  of "csConnecting": csConnecting
  of "csConnected": csConnected
  of "csError": csError
  else: csDisconnected

proc parseDebuggerState*(j: JsonNode): DebuggerState =
  ## Parse a DebuggerState from JSON.
  DebuggerState(
    location: parseLocation(j["location"]),
    rrTicks: j["rrTicks"].getBiggestInt.uint64,
    status: parseDebuggerStatus(j["status"].getStr),
    threadId: j["threadId"].getBiggestInt.uint32,
  )

proc parseSessionState*(j: JsonNode): SessionState =
  ## Parse a SessionState from JSON.
  SessionState(
    connectionStatus: parseConnectionStatus(j["connectionStatus"].getStr),
  )

proc parseTimelineState*(j: JsonNode): TimelineState =
  ## Parse a TimelineState from JSON.
  TimelineState(
    minRRTicks: j["minRRTicks"].getBiggestInt.uint64,
    maxRRTicks: j["maxRRTicks"].getBiggestInt.uint64,
    currentRRTicks: j["currentRRTicks"].getBiggestInt.uint64,
  )

proc parseVariable*(j: JsonNode): Variable =
  ## Parse a Variable from JSON (recursively including children).
  var children = newSeq[Variable]()
  if j.hasKey("children"):
    for child in j["children"]:
      children.add(parseVariable(child))
  Variable(
    name: j["name"].getStr,
    value: j["value"].getStr,
    typeName: j["typeName"].getStr,
    hasChildren: j["hasChildren"].getBool,
    children: children,
  )

proc parseCallLine*(j: JsonNode): CallLine =
  ## Parse a CallLine from JSON.
  CallLine(
    index: j["index"].getBiggestInt.int64,
    name: j["name"].getStr,
    depth: j["depth"].getInt,
    rrTicks: j["rrTicks"].getBiggestInt.uint64,
    location: parseLocation(j["location"]),
  )

proc parseEventLogRow*(j: JsonNode): EventLogRow =
  ## Parse an EventLogRow from JSON.
  EventLogRow(
    eventId: j["eventId"].getBiggestInt.uint64,
    kind: j["kind"].getStr,
    line: j["line"].getInt,
    value: j["value"].getStr,
  )

proc parseVariableSeq*(j: JsonNode): seq[Variable] =
  ## Parse a JSON array into a seq of Variables.
  result = newSeq[Variable]()
  for item in j:
    result.add(parseVariable(item))

proc parseCallLineSeq*(j: JsonNode): seq[CallLine] =
  ## Parse a JSON array into a seq of CallLines.
  result = newSeq[CallLine]()
  for item in j:
    result.add(parseCallLine(item))

# ---------------------------------------------------------------------------
# Signal update envelope
# ---------------------------------------------------------------------------

proc serializeSignalUpdate*(vm: string, field: string,
                            value: JsonNode): JsonNode =
  ## Create a signal update envelope with pre-serialized value.
  ## This is the wire format consumed by SyncSubscriber.
  %*{"vm": vm, "field": field, "value": value}

# ---------------------------------------------------------------------------
# Apply a signal update to a mirror session's store
# ---------------------------------------------------------------------------

proc applySignalUpdate*(session: SessionViewModel, update: JsonNode) =
  ## Apply a received signal update to a mirror SessionViewModel's store.
  ## Dispatches on the "vm" and "field" keys to write to the correct
  ## signal in the store.
  ##
  ## Unknown vm/field combinations are silently ignored so that older
  ## subscribers can receive updates from newer publishers without
  ## crashing.
  let vmName = update["vm"].getStr
  let field = update["field"].getStr
  let value = update["value"]

  case vmName
  of "session":
    case field
    of "state":
      session.store.session.val = parseSessionState(value)
    else: discard

  of "debugger":
    case field
    of "state":
      session.store.debugger.val = parseDebuggerState(value)
    else: discard

  of "timeline":
    case field
    of "state":
      session.store.timeline.val = parseTimelineState(value)
    else: discard

  of "calltrace":
    case field
    of "lines":
      session.store.calltrace.lines.val = parseCallLineSeq(value)
    of "startLineIndex":
      session.store.calltrace.startLineIndex.val = value.getBiggestInt.int64
    of "totalCallsCount":
      session.store.calltrace.totalCallsCount.val = value.getBiggestInt.uint64
    of "finished":
      session.store.calltrace.finished.val = value.getBool
    else: discard

  of "locals":
    case field
    of "locals":
      session.store.locals.locals.val = parseVariableSeq(value)
    of "globals":
      session.store.locals.globals.val = parseVariableSeq(value)
    else: discard

  else: discard
