## viewmodel/headless_session.nim
##
## HeadlessDebugSession — high-level API for automated testing of the
## ViewModel layer with a real replay-server backend.
##
## Provides actions that mirror what a GUI user does (step, continue,
## inspect locals, read calltrace, etc.) but executed programmatically
## with synchronous blocking semantics.
##
## Architecture:
##   HeadlessDebugSession
##     ├── DapStdioBackend  (spawns replay-server, speaks DAP over pipes)
##     ├── SessionViewModel (all 10 VMs + shared ReplayDataStore)
##     └── High-level action methods
##
## Usage:
##   let session = newHeadlessDebugSession("/path/to/trace", replayServerBin)
##   defer: session.close()
##   echo session.getCurrentFile()
##   session.stepForward()
##   echo session.getLocals()
##
## Compile with ``nim c`` (native-only — depends on stdio_backend).

when defined(js):
  {.error: "headless_session.nim is native-only".}

import std/[json, options, strutils, asyncdispatch, osproc, os, streams]

import isonim/core/[signals, computation, async_compat]

import backend/stdio_backend
import store/[replay_data_store, types]
import session_vm
import app/app_vm
import viewmodels/[state_vm, calltrace_vm]

type
  HeadlessDebugSession* = ref object
    ## Owns a replay-server process and the full ViewModel layer.
    ## Provides synchronous action methods for integration testing.
    backend*: DapStdioBackend
      ## The DAP stdio transport to the replay-server child process.
    app*: AppViewModel
      ## The app-level ViewModel graph owned by this headless session.
    session*: SessionViewModel
      ## Convenience alias for app.session (all panel VMs + shared store).
    tracePath*: string
      ## Filesystem path to the trace folder being replayed.
    replayServerBin*: string
      ## Path to the replay-server binary.
    lastCompleteMoveEvent*: JsonNode
      ## Latest raw ``ct/complete-move`` event observed by the session.

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc drain() =
  ## Drain the async event loop so that synchronously-completed futures
  ## fire their callbacks (needed because the store uses asyncdispatch
  ## futures internally).
  try:
    poll(0)
  except ValueError:
    # "No handles or timers registered" — nothing to drain.
    discard
  drainPlatformCallbacks()

proc updatePositionFromCompleteMove(session: HeadlessDebugSession;
                                    completeMoveEvent: JsonNode) =
  ## Extract the debugger position from a ``ct/complete-move`` event
  ## and push it into the store's reactive signals.
  ##
  ## The ``ct/complete-move`` event body is a ``MoveState`` JSON object
  ## with ``location.path``, ``location.line``, ``location.rrTicks``, etc.
  ## See ``src/db-backend/src/task.rs`` for the Rust definition.
  let body = completeMoveEvent.getOrDefault("body")
  session.lastCompleteMoveEvent = completeMoveEvent
  if body.isNil:
    return

  var rrTicks: uint64 = 0
  var file = ""
  var line = 0
  var sourceGeneration = 0
  var sourceDigest = ""
  var geid = none(uint64)

  # The location is nested under body.location (MoveState.location).
  if body.hasKey("location"):
    let loc = body["location"]
    file = loc.getOrDefault("path").getStr("")
    line = loc.getOrDefault("line").getInt(0)
    sourceGeneration = loc.getOrDefault("sourceGeneration").getInt(0)
    sourceDigest = loc.getOrDefault("sourceDigest").getStr("")
    if loc.hasKey("rrTicks"):
      rrTicks = loc["rrTicks"].getBiggestInt().uint64
    if loc.hasKey("geid"):
      geid = some(loc["geid"].getBiggestInt().uint64)
  if body.hasKey("geid"):
    geid = some(body["geid"].getBiggestInt().uint64)
  elif body.hasKey("currentGeid"):
    geid = some(body["currentGeid"].getBiggestInt().uint64)

  session.session.store.updateDebuggerPosition(
    rrTicks, file, line, geid,
    sourceGeneration = sourceGeneration,
    sourceDigest = sourceDigest)

  # Update the debugger status back to idle after the step completes.
  var dbg = session.session.store.debugger.val
  dbg.status = dsIdle
  session.session.store.debugger.val = dbg
  drain()

proc consumeCompleteMoveEvent(session: HeadlessDebugSession) =
  ## Wait for a ``ct/complete-move`` event from the backend and update
  ## the store.  This is the event that carries the actual debugger
  ## position after any navigation command (step, continue, etc.).
  ##
  ## The server may send both ``stopped`` and ``ct/complete-move`` events
  ## after a navigation command.  We consume both, but only use the
  ## ``ct/complete-move`` for position data.
  let completeMove = session.backend.waitForEvent("ct/complete-move")
  session.updatePositionFromCompleteMove(completeMove)

proc consumeNextCompleteMove*(session: HeadlessDebugSession) =
  ## Public wrapper used by collaboration harnesses that route a debugger
  ## command through BackendCommandAuthority. The command has already been sent
  ## to replay-server; this consumes the resulting stop/move events and mirrors
  ## the real backend position into the ViewModel store.
  discard session.backend.waitForEvent("stopped")
  session.consumeCompleteMoveEvent()

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

proc newHeadlessDebugSession*(tracePath: string;
                              replayServerBin: string): HeadlessDebugSession =
  ## Create a headless debug session.
  ##
  ## Steps:
  ## 1. Spawn replay-server as a child process.
  ## 2. Perform the DAP initialization handshake.
  ## 3. Send the ``launch`` command with the trace folder.
  ## 4. Wait for the initial ``stopped`` event.
  ## 5. Create the full SessionViewModel wired to the stdio backend.
  ##
  ## Raises on failure (process spawn, handshake timeout, etc.).

  # 1. Spawn
  let backend = startReplayServer(replayServerBin)

  # 2. DAP initialization handshake
  let initResp = backend.sendDapRequest("initialize", %*{
    "clientID": "headless-test",
    "adapterID": "codetracer",
    "supportsProgressReporting": false,
  })
  if not initResp.getOrDefault("success").getBool(false):
    backend.close()
    raise newException(IOError,
      "DAP initialize failed: " & $initResp)

  # Wait for the "initialized" event that the server sends after
  # processing the initialize request.
  let initializedEvent = backend.waitForEvent("initialized")
  discard initializedEvent  # we just need to consume it

  # 3. Configuration done mirrors the GUI startup order.
  let configResp = backend.sendDapRequest("configurationDone")
  discard configResp

  # 4. Launch with the trace folder
  # The Rust backend deserializes ``traceFolder`` (camelCase) via serde rename.
  let launchResp = backend.sendDapRequest("launch", %*{
    "traceFolder": tracePath,
  })
  if not launchResp.getOrDefault("success").getBool(false):
    backend.close()
    raise newException(IOError,
      "DAP launch failed: " & $launchResp)

  # 5. Wait for the initial stopped event and ct/complete-move.
  # The server sends a standard DAP "stopped" event plus a CT-specific
  # "ct/complete-move" event that carries the actual source location.
  discard backend.waitForEvent("stopped")

  # 6. Create the app ViewModel layer with the stdio backend as the service
  let backendService = backend.toBackendService()
  let app = createAppViewModel(backendService)

  result = HeadlessDebugSession(
    backend: backend,
    app: app,
    session: app.session,
    tracePath: tracePath,
    replayServerBin: replayServerBin,
  )

  # Push initial position into the store from the ct/complete-move event.
  let completeMoveEvent = backend.waitForEvent("ct/complete-move")
  result.updatePositionFromCompleteMove(completeMoveEvent)

# ---------------------------------------------------------------------------
# Stepping actions
# ---------------------------------------------------------------------------

proc stepForward*(s: HeadlessDebugSession) =
  ## Step forward one source line.  Blocks until the backend reports
  ## a new stopped position via ``ct/complete-move``.
  var dbg = s.session.store.debugger.val
  dbg.status = dsStepping
  s.session.store.debugger.val = dbg

  discard s.backend.sendDapRequest("next", %*{"threadId": 1})
  # The server sends "stopped" + "ct/complete-move" after navigation.
  # We consume both; position comes from ct/complete-move.
  discard s.backend.waitForEvent("stopped")
  s.consumeCompleteMoveEvent()

proc stepBackward*(s: HeadlessDebugSession) =
  ## Step backward one source line.
  var dbg = s.session.store.debugger.val
  dbg.status = dsStepping
  s.session.store.debugger.val = dbg

  discard s.backend.sendDapRequest("stepBack", %*{"threadId": 1})
  discard s.backend.waitForEvent("stopped")
  s.consumeCompleteMoveEvent()

proc stepIn*(s: HeadlessDebugSession) =
  ## Step into a function call.
  var dbg = s.session.store.debugger.val
  dbg.status = dsStepping
  s.session.store.debugger.val = dbg

  discard s.backend.sendDapRequest("stepIn", %*{"threadId": 1})
  discard s.backend.waitForEvent("stopped")
  s.consumeCompleteMoveEvent()

proc stepOut*(s: HeadlessDebugSession) =
  ## Step out of the current function.
  var dbg = s.session.store.debugger.val
  dbg.status = dsStepping
  s.session.store.debugger.val = dbg

  discard s.backend.sendDapRequest("stepOut", %*{"threadId": 1})
  discard s.backend.waitForEvent("stopped")
  s.consumeCompleteMoveEvent()

proc continueForward*(s: HeadlessDebugSession) =
  ## Continue execution forward until a breakpoint or end.
  var dbg = s.session.store.debugger.val
  dbg.status = dsRunning
  s.session.store.debugger.val = dbg

  discard s.backend.sendDapRequest("continue", %*{"threadId": 1})
  discard s.backend.waitForEvent("stopped")
  s.consumeCompleteMoveEvent()

proc continueBackward*(s: HeadlessDebugSession) =
  ## Continue execution backward until a breakpoint or start.
  var dbg = s.session.store.debugger.val
  dbg.status = dsRunning
  s.session.store.debugger.val = dbg

  discard s.backend.sendDapRequest("reverseContinue", %*{"threadId": 1})
  discard s.backend.waitForEvent("stopped")
  s.consumeCompleteMoveEvent()

# ---------------------------------------------------------------------------
# Inspection
# ---------------------------------------------------------------------------

proc getLocals*(s: HeadlessDebugSession): seq[Variable] =
  ## Get the current local variables from the StateVM.
  ## This reads the reactive signal — the auto-load effect in StateVM
  ## should have requested locals when the debugger position changed.
  s.session.stateVM.currentVariables.val

proc getCalltraceLines*(s: HeadlessDebugSession): seq[CallLine] =
  ## Get the calltrace lines from the store.
  ##
  ## Reads directly from the store's ``calltrace.lines`` signal rather
  ## than the CalltraceVM's ``visibleLines`` memo.  The VM memo filters
  ## by viewport height (which defaults to 0 in headless mode), so
  ## reading from the store ensures we see all loaded data.
  ##
  ## Use ``getVisibleCalltraceLines`` to test the VM's viewport logic.
  s.session.store.calltrace.lines.val

proc getVisibleCalltraceLines*(s: HeadlessDebugSession): seq[CallLine] =
  ## Get the visible calltrace lines from the CalltraceVM's viewport memo.
  ## Requires that ``calltraceVM.viewportHeight`` is set to a value > 0
  ## (e.g. via ``calltraceVM.setViewportHeight(50)``).
  s.session.calltraceVM.visibleLines.val

proc getCurrentFile*(s: HeadlessDebugSession): string =
  ## Get the current source file path from the debugger state.
  s.session.store.debugger.val.location.file

proc getCurrentLine*(s: HeadlessDebugSession): int =
  ## Get the current source line number from the debugger state.
  s.session.store.debugger.val.location.line

proc getCurrentRRTicks*(s: HeadlessDebugSession): uint64 =
  ## Get the current rrTicks position from the debugger state.
  s.session.store.debugger.val.rrTicks

proc getCurrentGeid*(s: HeadlessDebugSession): Option[uint64] =
  ## Get the current visual replay GEID, if the backend reported one.
  s.session.store.currentGeid.val

proc getDebuggerStatus*(s: HeadlessDebugSession): DebuggerStatus =
  ## Get the current debugger status (idle, stepping, running, etc.).
  s.session.store.debugger.val.status

# ---------------------------------------------------------------------------
# DAP response parsing helpers
# ---------------------------------------------------------------------------

proc extractValueText(valueNode: JsonNode): string =
  ## Extract a human-readable text representation from a ct/load-locals
  ## ``Value`` JSON object.
  ##
  ## The backend's ``Value`` struct (see ``src/db-backend/src/value.rs``)
  ## uses a tagged-flat layout: ``kind`` is a numeric ``TypeKind`` ordinal,
  ## and the actual data lives in ``i`` (int), ``f`` (float), ``text``
  ## (string), ``b`` (bool), ``c`` (char), ``r`` (raw), ``msg`` (error),
  ## or ``elements`` (compound).
  ##
  ## TypeKind ordinals (from codetracer-trace-format):
  ##   7 = Int, 8 = Float, 3 = String, 4 = CString, 5 = Bool,
  ##   6 = Struct, 9 = Seq, 10 = Char, 11 = Tuple, 30 = None, etc.
  if valueNode.isNil or valueNode.kind != JObject:
    return ""
  let kind = valueNode.getOrDefault("kind").getInt(-1)
  case kind
  of 7:  # Int
    result = valueNode.getOrDefault("i").getStr("")
  of 8:  # Float
    result = valueNode.getOrDefault("f").getStr("")
  of 3:  # String
    result = "\"" & valueNode.getOrDefault("text").getStr("") & "\""
  of 4:  # CString
    result = "\"" & valueNode.getOrDefault("cText").getStr("") & "\""
  of 5:  # Bool
    result = if valueNode.getOrDefault("b").getBool(false): "true" else: "false"
  of 10: # Char
    result = "'" & valueNode.getOrDefault("c").getStr("") & "'"
  of 6, 9, 11: # Struct, Seq, Tuple
    # For compound types, produce a comma-separated list of child representations.
    let elements = valueNode.getOrDefault("elements")
    if not elements.isNil and elements.kind == JArray:
      var parts: seq[string]
      # For structs, try to include field labels from typ.labels.
      let typ = valueNode.getOrDefault("typ")
      var labels: seq[string]
      if not typ.isNil and typ.kind == JObject:
        let labelsNode = typ.getOrDefault("labels")
        if not labelsNode.isNil and labelsNode.kind == JArray:
          for lbl in labelsNode:
            labels.add(lbl.getStr(""))
      for idx in 0 ..< elements.len:
        let elem = elements[idx]
        let childRepr = extractValueText(elem)
        if idx < labels.len and labels[idx].len > 0:
          parts.add(labels[idx] & ": " & childRepr)
        else:
          parts.add(childRepr)
      let open = if kind == 9: "[" elif kind == 11: "(" else: "{"
      let close = if kind == 9: "]" elif kind == 11: ")" else: "}"
      result = open & parts.join(", ") & close
    else:
      result = "()"
  of 30: # None
    result = "nil"
  of 14: # Raw
    result = valueNode.getOrDefault("r").getStr("")
  of 15: # Error
    result = "<error: " & valueNode.getOrDefault("msg").getStr("") & ">"
  else:
    # Unknown kind — fall back to ``i`` or ``text`` if present, otherwise empty.
    let i = valueNode.getOrDefault("i").getStr("")
    if i.len > 0: return i
    let text = valueNode.getOrDefault("text").getStr("")
    if text.len > 0: return text
    result = ""

proc parseVariable(localNode: JsonNode): Variable =
  ## Parse a single variable entry from the ct/load-locals response.
  let expression = localNode.getOrDefault("expression").getStr("")
  let valueNode = localNode.getOrDefault("value")
  let valueText = extractValueText(valueNode)
  var typeName = ""
  if not valueNode.isNil and valueNode.kind == JObject:
    let typ = valueNode.getOrDefault("typ")
    if not typ.isNil and typ.kind == JObject:
      typeName = typ.getOrDefault("langType").getStr("")

  # Check for compound children (structs, seqs, tuples).
  var children: seq[Variable]
  var hasChildren = false
  if not valueNode.isNil and valueNode.kind == JObject:
    let elements = valueNode.getOrDefault("elements")
    if not elements.isNil and elements.kind == JArray and elements.len > 0:
      hasChildren = true
      let typ = valueNode.getOrDefault("typ")
      var labels: seq[string]
      if not typ.isNil and typ.kind == JObject:
        let labelsNode = typ.getOrDefault("labels")
        if not labelsNode.isNil and labelsNode.kind == JArray:
          for lbl in labelsNode:
            labels.add(lbl.getStr(""))
      for idx in 0 ..< elements.len:
        let elem = elements[idx]
        let childName = if idx < labels.len and labels[idx].len > 0: labels[idx]
                        else: "[" & $idx & "]"
        let childValue = extractValueText(elem)
        var childTypeName = ""
        let childTyp = elem.getOrDefault("typ")
        if not childTyp.isNil and childTyp.kind == JObject:
          childTypeName = childTyp.getOrDefault("langType").getStr("")
        children.add(Variable(
          name: childName,
          value: childValue,
          typeName: childTypeName,
        ))

  Variable(
    name: expression,
    value: valueText,
    typeName: typeName,
    hasChildren: hasChildren,
    children: children,
  )

proc parseCallLine(callLineNode: JsonNode; globalIndex: int64): CallLine =
  ## Parse a single calltrace line from the ct/load-calltrace-section response.
  ## The response JSON uses ``callLines[].content.call`` for the call data
  ## and ``callLines[].depth`` for the indentation level.
  let content = callLineNode.getOrDefault("content")
  let depth = callLineNode.getOrDefault("depth").getInt(0)
  var name = ""
  var file = ""
  var line = 0
  var rrTicks: uint64 = 0

  if not content.isNil and content.kind == JObject:
    let call = content.getOrDefault("call")
    if not call.isNil and call.kind == JObject:
      name = call.getOrDefault("rawName").getStr("")
      let loc = call.getOrDefault("location")
      if not loc.isNil and loc.kind == JObject:
        file = loc.getOrDefault("path").getStr("")
        line = loc.getOrDefault("line").getInt(0)
        rrTicks = loc.getOrDefault("rrTicks").getBiggestInt(0).uint64

  CallLine(
    index: globalIndex,
    name: name,
    depth: depth,
    rrTicks: rrTicks,
    location: Location(file: file, line: line),
  )

# ---------------------------------------------------------------------------
# Data loading — send DAP requests and feed responses into the store
# ---------------------------------------------------------------------------

proc requestAndLoadLocals*(s: HeadlessDebugSession) =
  ## Send ``ct/load-locals`` to the backend, parse the response, and
  ## feed the resulting Variable sequence into the store.
  ##
  ## This closes the data-flow loop that the GUI achieves via event-bus
  ## wiring: request -> response -> store update -> reactive signal change.
  let args = %*{
    "rrTicks": s.getCurrentRRTicks().int64,
    "countBudget": 3000,
    "minCountLimit": 50,
    "depthLimit": 7,
    "watchExpressions": [],
    "lang": 0,  # auto-detect
  }
  let resp = s.backend.sendDapRequest("ct/load-locals", args)
  if resp.getOrDefault("success").getBool(false):
    let body = resp.getOrDefault("body")
    if not body.isNil and body.kind == JObject:
      let localsNode = body.getOrDefault("locals")
      if not localsNode.isNil and localsNode.kind == JArray:
        var variables: seq[Variable]
        for localNode in localsNode:
          variables.add(parseVariable(localNode))
        s.session.store.updateLocals(variables)
        s.session.store.locals.loadedForRRTicks.val = s.getCurrentRRTicks()
        drain()

proc requestAndLoadCalltrace*(s: HeadlessDebugSession;
                              startIndex: int64 = 0;
                              height: int = 50;
                              depth: int = 20) =
  ## Send ``ct/load-calltrace-section`` to the backend, parse the
  ## response, and feed the resulting CallLine sequence into the store.
  let dbg = s.session.store.debugger.val
  let args = %*{
    "location": {
      "rrTicks": dbg.rrTicks.int64,
      "path": dbg.location.file,
      "line": dbg.location.line,
    },
    "startCallLineIndex": startIndex,
    "height": height,
    "depth": depth,
    "rawIgnorePatterns": "",
    "optimizeCollapse": true,
    "autoCollapsing": false,
    "renderCallLineIndex": 0,
  }
  let resp = s.backend.sendDapRequest("ct/load-calltrace-section", args)
  # The calltrace response also emits an event before the response —
  # drain any interleaved events from the queue.
  discard s.backend.drainEvents()
  if resp.getOrDefault("success").getBool(false):
    let body = resp.getOrDefault("body")
    if not body.isNil and body.kind == JObject:
      let callLinesNode = body.getOrDefault("callLines")
      let startCallLineIdx = body.getOrDefault("startCallLineIndex").getBiggestInt(0).int64
      let totalCount = body.getOrDefault("totalCallsCount").getBiggestInt(0).uint64
      if not callLinesNode.isNil and callLinesNode.kind == JArray:
        var lines: seq[CallLine]
        for idx in 0 ..< callLinesNode.len:
          lines.add(parseCallLine(callLinesNode[idx], startCallLineIdx + idx.int64))
        s.session.store.updateCalltraceSection(lines, startCallLineIdx, totalCount)
        drain()

# ---------------------------------------------------------------------------
# Navigation — calltrace and event jumps
# ---------------------------------------------------------------------------

proc calltraceJump*(s: HeadlessDebugSession; file: string; line: int;
                    rrTicks: uint64) =
  ## Jump to a specific calltrace entry by its location.
  ## This mirrors the GUI's double-click-on-calltrace-entry action.
  ## Sends ``ct/calltrace-jump`` and waits for the ``stopped`` +
  ## ``ct/complete-move`` events that carry the new debugger position.
  ##
  ## The ``ct/calltrace-jump`` handler does NOT send a DAP response --
  ## it only emits events (``stopped`` + ``ct/complete-move``) via the
  ## channel.  We use ``sendDapRequestNoResponse`` to avoid blocking
  ## forever waiting for a response that never arrives.
  let args = %*{
    "file": file,
    "line": line,
    "rrTicks": rrTicks,
  }
  s.backend.sendDapRequestNoResponse("ct/calltrace-jump", args)
  discard s.backend.waitForEvent("stopped")
  s.consumeCompleteMoveEvent()

proc calltraceJumpByLine*(s: HeadlessDebugSession; callLine: CallLine) =
  ## Convenience: jump to a calltrace entry using a CallLine object.
  s.calltraceJump(callLine.location.file, callLine.location.line,
                  callLine.rrTicks)

# ---------------------------------------------------------------------------
# Breakpoints
# ---------------------------------------------------------------------------

proc setBreakpoint*(s: HeadlessDebugSession; file: string; line: int) =
  ## Send a ``setBreakpoints`` DAP request for a single breakpoint at the
  ## given file and line.  The standard DAP ``setBreakpoints`` command
  ## replaces all breakpoints for the specified source, so calling this
  ## multiple times for the same file will overwrite previous breakpoints
  ## in that file.
  let args = %*{
    "source": {
      "path": file,
    },
    "breakpoints": [
      {"line": line},
    ],
  }
  let resp = s.backend.sendDapRequest("setBreakpoints", args)
  if not resp.getOrDefault("success").getBool(false):
    raise newException(IOError,
      "setBreakpoints failed: " & $resp)

# ---------------------------------------------------------------------------
# Event log
# ---------------------------------------------------------------------------

type
  EventLogEntry* = object
    ## A single entry from the ``ct/event-load`` response.
    content*: string
    rrTicks*: uint64
    line*: int
    file*: string
    sourceGeneration*: int
    sourceDigest*: string

proc requestAndLoadEventLog*(s: HeadlessDebugSession;
                             start: int = 0;
                             count: int = 0): seq[EventLogEntry] =
  ## Send ``ct/event-load`` to the backend and return the parsed event log
  ## entries.  When ``count`` is 0 (default) the backend returns the first
  ## 20 events (legacy behaviour); pass an explicit ``count`` for pagination.
  let args = %*{
    "start": start,
    "count": count,
  }
  let resp = s.backend.sendDapRequest("ct/event-load", args)
  # Drain interleaved events (the server may push events before the response).
  discard s.backend.drainEvents()
  if resp.getOrDefault("success").getBool(false):
    let body = resp.getOrDefault("body")
    if not body.isNil and body.kind == JObject:
      let eventsNode = body.getOrDefault("events")
      if not eventsNode.isNil and eventsNode.kind == JArray:
        for ev in eventsNode:
          var entry = EventLogEntry()
          entry.content = ev.getOrDefault("content").getStr("")
          # ProgramEvent fields use camelCase serde names:
          #   high_level_path -> highLevelPath (or high_level_path)
          #   high_level_line -> highLevelLine (or high_level_line)
          #   directLocationRRTicks -> directLocationRRTicks
          entry.file = ev.getOrDefault("high_level_path").getStr(
            ev.getOrDefault("highLevelPath").getStr(""))
          entry.line = ev.getOrDefault("high_level_line").getInt(
            ev.getOrDefault("highLevelLine").getInt(0))
          entry.rrTicks = ev.getOrDefault("directLocationRRTicks").getBiggestInt(0).uint64
          entry.sourceGeneration = ev.getOrDefault("source_generation").getInt(
            ev.getOrDefault("sourceGeneration").getInt(0))
          entry.sourceDigest = ev.getOrDefault("source_digest").getStr(
            ev.getOrDefault("sourceDigest").getStr(""))
          result.add(entry)

proc eventJump*(s: HeadlessDebugSession; event: EventLogEntry) =
  ## Jump to the location of an event log entry.
  ## Sends ``ct/event-jump`` and waits for the position update.
  ##
  ## The ProgramEvent struct uses ``serde(rename_all = "camelCase")`` with
  ## explicit ``#[serde(rename)]`` overrides for some fields.  The JSON
  ## keys must match what the Rust deserializer expects.
  ## EventLogKind is repr(u8) with Serialize_repr/Deserialize_repr:
  ##   0 = Write, 1 = WriteFile, 2 = WriteOther, 3 = Read, etc.
  let args = %*{
    "kind": 0,
    "content": event.content,
    "rrEventId": 0,
    "highLevelPath": event.file,
    "highLevelLine": event.line,
    "metadata": "",
    "bytes": 0,
    "stdout": true,
    "directLocationRRTicks": event.rrTicks.int64,
    "tracepointResultIndex": -1,
    "eventIndex": 0,
    "base64Encoded": false,
    "maxRRTicks": 0,
  }
  s.backend.sendDapRequestNoResponse("ct/event-jump", args)
  discard s.backend.waitForEvent("stopped")
  s.consumeCompleteMoveEvent()

# ---------------------------------------------------------------------------
# Trace recording
# ---------------------------------------------------------------------------

proc findCtBinary*(): string =
  ## Locate the ``ct`` binary for recording traces.
  ## Falls back to the CT_BIN environment variable.
  let envBin = getEnv("CT_BIN", "")
  if envBin.len > 0 and fileExists(envBin):
    return envBin
  # headless_session.nim is at src/frontend/viewmodel/headless_session.nim
  # so 4 parentDir calls reach the repo root.
  let thisFile = currentSourcePath()
  let repoRoot = thisFile.parentDir.parentDir.parentDir.parentDir
  let candidate = repoRoot / "src" / "build-debug" / "bin" / "ct"
  if fileExists(candidate):
    return candidate
  raise newException(IOError,
    "Could not find ct binary. Set CT_BIN or build it. Tried: " & candidate)

proc recordTrace*(programPath: string; outputDir: string = "";
                  lang: string = ""): string =
  ## Record a trace for the given program and return the trace folder path.
  ##
  ## If ``outputDir`` is empty, a temporary directory is created.
  ## The returned path is the directory containing the trace files.
  ##
  ## This shells out to ``ct record -o <dir> <program>`` which invokes
  ## the appropriate recorder for the language.
  let ctBin = findCtBinary()
  let traceDir = if outputDir.len > 0: outputDir
                 else: getTempDir() / "ct-headless-test-traces" /
                       programPath.extractFilename().changeFileExt("")
  createDir(traceDir)

  var args = @["record", "-o", traceDir]
  if lang.len > 0:
    args.add("--lang")
    args.add(lang)
  args.add(programPath)

  let process = startProcess(ctBin, args = args,
                             options = {poStdErrToStdOut, poUsePath})
  let exitCode = process.waitForExit()
  let output = process.outputStream.readAll()
  process.close()
  if exitCode != 0:
    raise newException(IOError,
      "ct record failed (exit " & $exitCode & "): " & output)
  return traceDir

# ---------------------------------------------------------------------------
# Watch expressions
# ---------------------------------------------------------------------------

proc addWatch*(s: HeadlessDebugSession; expression: string) =
  ## Add a watch expression to the StateVM.
  state_vm.addWatch(s.session.stateVM, expression)

proc removeWatch*(s: HeadlessDebugSession; expression: string) =
  ## Remove a watch expression from the StateVM.
  state_vm.removeWatch(s.session.stateVM, expression)

# ---------------------------------------------------------------------------
# Raw DAP access
# ---------------------------------------------------------------------------

proc sendRawDapRequest*(s: HeadlessDebugSession; command: string;
                        args: JsonNode = newJObject()): JsonNode =
  ## Send an arbitrary DAP request and return the response.
  ## Useful for testing custom ct/* commands.
  s.backend.sendDapRequest(command, args)

proc drainEvents*(s: HeadlessDebugSession): seq[JsonNode] =
  ## Return and clear all buffered DAP events.
  s.backend.drainEvents()

# ---------------------------------------------------------------------------
# Teardown
# ---------------------------------------------------------------------------

proc close*(s: HeadlessDebugSession) =
  ## Shut down the session: dispose VMs, disconnect backend, kill process.
  s.app.dispose()
  s.backend.close()
