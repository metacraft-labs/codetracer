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

import std/[json, asyncdispatch]

import isonim/core/[signals, computation]

import backend/stdio_backend
import store/[replay_data_store, types]
import session_vm
import viewmodels/[state_vm, calltrace_vm]

type
  HeadlessDebugSession* = ref object
    ## Owns a replay-server process and the full ViewModel layer.
    ## Provides synchronous action methods for integration testing.
    backend*: DapStdioBackend
      ## The DAP stdio transport to the replay-server child process.
    session*: SessionViewModel
      ## The full ViewModel layer (all VMs + shared store).
    tracePath*: string
      ## Filesystem path to the trace folder being replayed.
    replayServerBin*: string
      ## Path to the replay-server binary.

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

proc updatePositionFromCompleteMove(session: HeadlessDebugSession;
                                    completeMoveEvent: JsonNode) =
  ## Extract the debugger position from a ``ct/complete-move`` event
  ## and push it into the store's reactive signals.
  ##
  ## The ``ct/complete-move`` event body is a ``MoveState`` JSON object
  ## with ``location.path``, ``location.line``, ``location.rrTicks``, etc.
  ## See ``src/db-backend/src/task.rs`` for the Rust definition.
  let body = completeMoveEvent.getOrDefault("body")
  if body.isNil:
    return

  var rrTicks: uint64 = 0
  var file = ""
  var line = 0

  # The location is nested under body.location (MoveState.location).
  if body.hasKey("location"):
    let loc = body["location"]
    file = loc.getOrDefault("path").getStr("")
    line = loc.getOrDefault("line").getInt(0)
    if loc.hasKey("rrTicks"):
      rrTicks = loc["rrTicks"].getBiggestInt().uint64

  session.session.store.updateDebuggerPosition(rrTicks, file, line)

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

  # 3. Configuration done (required by DAP before launch)
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

  # 6. Create the ViewModel layer with the stdio backend as the service
  let backendService = backend.toBackendService()
  let session = createSessionVM(backendService)

  result = HeadlessDebugSession(
    backend: backend,
    session: session,
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
  ## Get the visible calltrace lines from the CalltraceVM.
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

proc getDebuggerStatus*(s: HeadlessDebugSession): DebuggerStatus =
  ## Get the current debugger status (idle, stepping, running, etc.).
  s.session.store.debugger.val.status

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
  s.session.dispose()
  s.backend.close()
