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
export stdio_backend.DapReadBound, stdio_backend.DapStalledError,
       stdio_backend.DapInterruptedError
import store/[replay_data_store, types]
# PLAT-2's value-presentation pipeline. `json_adapter` is qualified at its call
# sites because `toPValue` also exists on the `Value` side of the bridge, and a
# reader of `headless_session` has to be able to tell which one is meant — this
# module is precisely the one that cannot see the other.
import ../../common/value_presentation
import ../../common/value_presentation/json_adapter
import session_vm
import app/app_vm
import sdk/[debugger_session, trace_source]
import viewmodels/[state_vm, calltrace_vm]

type
  HeadlessDebugSession* = ref object
    ## Owns a replay-server process and the full ViewModel layer.
    ## Provides synchronous action methods for integration testing.
    ##
    ## Since the Embed SDK facade landed, the ViewModel graph and the session
    ## lifecycle are NOT built here: they come from `sdk.DebuggerSession`, and
    ## this type is the native, process-spawning *host* around it. What stays
    ## here is what the SDK cannot own — spawning `replay-server`, and the
    ## blocking `waitForEvent` pump that `BackendService` deliberately does
    ## not expose.
    backend*: DapStdioBackend
      ## The DAP stdio transport to the replay-server child process.
    sdk*: DebuggerSession
      ## The Embed SDK session this harness hosts. Owns the ViewModel graph,
      ## the lifecycle phase and the navigation history.
    app*: AppViewModel
      ## The app-level ViewModel graph. Alias for `sdk.app`, kept as a field
      ## so the 25 suites that read it are untouched.
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
  # Tell the SDK session where the move landed. The SDK cannot observe this
  # itself on the stdio transport — the position arrives on an event this
  # harness pumps — so the host reports it rather than the session guessing.
  if not session.sdk.isNil:
    session.sdk.recordPosition("move")
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

proc newHeadlessDebugSession*(
    tracePath: string;
    replayServerBin: string;
    handshake: DapReadBound = DapReadBound(interruptFd: -1)
  ): HeadlessDebugSession =
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
  ##
  ## ``handshake`` is CTUI-14's ``DapReadBound``, and it applies to steps 2-5
  ## and then STAYS ON the backend for the rest of the session.  The default is
  ## the zero value — unbounded, exactly what every caller had before — and
  ## `src/frontend/tui/host/native_host.openLocalTrace` is the caller that
  ## passes one, because it is the caller holding a terminal it would otherwise
  ## never give back.  ``stdio_backend.nim``'s header has the reproduction.

  # 1. Spawn
  let backend = startReplayServer(replayServerBin, bound = handshake)

  # THE CHILD IS REAPED ON EVERY FAILING PATH, not only on the two the code
  # below already named. CTUI-14 made that matter: with a `DapReadBound`
  # installed a stalled handshake now RAISES where it used to hang, and the
  # raise used to leave `replay-server` running with nobody holding it — one
  # orphan per refused trace, which is exactly what
  # `tests/real_terminal/test_real_no_orphans.nim` counts. The two explicit
  # `backend.close()` calls inside stay where they are: they close a session
  # that answered and REFUSED, which is a different fact from one that broke.
  try:
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
    # The Rust backend deserializes ``traceFolder`` (camelCase) via serde
    # rename.
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

    # 6. Create the ViewModel layer through the Embed SDK session, with the
    #    stdio backend injected as the BackendService (spec §3.1 — the
    #    transport is injectable, so the same lifecycle code serves the mock,
    #    a worker and this spawned process).
    #
    #    `attach` rather than `launch`: steps 2-5 above already performed the
    #    DAP handshake on the raw channel, because they need the blocking
    #    `waitForEvent` that `BackendService.onEvent` does not provide.
    let backendService = backend.toBackendService()
    let sdkSession = newDebuggerSession(backendService)
    sdkSession.attach(localFolderTrace(tracePath))

    result = HeadlessDebugSession(
      backend: backend,
      sdk: sdkSession,
      app: sdkSession.app,
      session: sdkSession.session,
      tracePath: tracePath,
      replayServerBin: replayServerBin,
    )

    # Push initial position into the store from the ct/complete-move event.
    let completeMoveEvent = backend.waitForEvent("ct/complete-move")
    result.updatePositionFromCompleteMove(completeMoveEvent)
  except CatchableError:
    try:
      backend.close()
    except CatchableError:
      # A child that cannot be closed is not a reason to lose the diagnosis of
      # why the handshake failed, which is what re-raising from here would do.
      discard
    raise

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

proc stepOverStatement*(s: HeadlessDebugSession) =
  ## M2 — Column-Aware Replay Navigation §M2: step forward by one
  ## /statement/ rather than by one source line.  Sends the DAP
  ## ``next`` request with ``granularity = "statement"`` on the wire
  ## so the replay-server dispatches to the column-aware runner.
  ##
  ## Back-compat: ``stepForward`` (above) keeps sending ``next``
  ## without ``granularity`` and therefore continues to behave as
  ## line-granularity step-over.  Tests that need to verify the
  ## legacy path stays intact use ``stepForward``; tests that need
  ## the new behaviour use ``stepOverStatement``.
  var dbg = s.session.store.debugger.val
  dbg.status = dsStepping
  s.session.store.debugger.val = dbg

  discard s.backend.sendDapRequest(
    "next",
    %*{"threadId": 1, "granularity": "statement"})
  discard s.backend.waitForEvent("stopped")
  s.consumeCompleteMoveEvent()

proc setActiveSourceView*(s: HeadlessDebugSession; viewPath: string) =
  ## M3 — Column-Aware Replay Navigation §M3: activate the formatted
  ## srcview at ``viewPath``.  When non-empty, subsequent ``stepForward``
  ## / ``stepOverStatement`` calls advance one /formatted/ line (or
  ## statement) per invocation rather than one minified line — the
  ## replay-server's ``next_dap`` runner consults the active view's
  ## sourcemap to project each candidate step.
  ##
  ## Pass an empty string to clear the active view and return the
  ## runner to legacy minified-coordinate behaviour.
  ##
  ## See ``codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org``
  ## §M3 for the DAP wire contract.
  let args = if viewPath.len == 0:
    %*{ "viewPath": newJNull() }
  else:
    %*{ "viewPath": viewPath }
  let resp = s.backend.sendDapRequest("ct/set-active-source-view", args)
  if not resp.getOrDefault("success").getBool(false):
    raise newException(IOError,
      "ct/set-active-source-view failed: " & $resp)

proc installSourceViewForTest*(s: HeadlessDebugSession;
                               recordedPath, formattedViewPath,
                               sourcemapV3Json: string) =
  ## M3 — test-only debug request: install a synthetic Source Map V3
  ## record under ``recordedPath`` so the formatted-view runner has a
  ## real projection to consult.
  ##
  ## Production code path: the recorder writes a srcviews.dat record
  ## that the replay-server discovers at trace-open time via
  ## ``load_source_views``.  The test path uses this hook to inject the
  ## same parsed SourcemapIndex into the cache at runtime — bypassing
  ## the recorder's autoformat step (which requires ``prettier`` on
  ## PATH and would tie the M3 contract to an external toolchain).
  let args = %*{
    "recordedPath": recordedPath,
    "formattedViewPath": formattedViewPath,
    "sourcemapV3Json": sourcemapV3Json,
  }
  let resp = s.backend.sendDapRequest("ct/install-source-view", args)
  if not resp.getOrDefault("success").getBool(false):
    raise newException(IOError,
      "ct/install-source-view failed: " & $resp)

proc stepBackward*(s: HeadlessDebugSession) =
  ## Step backward one source line.
  var dbg = s.session.store.debugger.val
  dbg.status = dsStepping
  s.session.store.debugger.val = dbg

  discard s.backend.sendDapRequest("stepBack", %*{"threadId": 1})
  discard s.backend.waitForEvent("stopped")
  s.consumeCompleteMoveEvent()

proc stepBackStatement*(s: HeadlessDebugSession) =
  ## M7 — Column-Aware Replay Navigation §M7: time-travel symmetric
  ## counterpart of ``stepOverStatement``.  Step BACKWARD by one
  ## /statement/ rather than by one source line.  Sends the DAP
  ## ``stepBack`` request with ``granularity = "statement"`` on the
  ## wire so the replay-server dispatches to the column-aware reverse
  ## runner.
  ##
  ## Back-compat: ``stepBackward`` (above) keeps sending ``stepBack``
  ## without ``granularity`` and therefore continues to behave as
  ## reverse-line-granularity step-back.  Tests that need to verify
  ## the legacy path stays intact use ``stepBackward``; tests that
  ## need the new behaviour use ``stepBackStatement``.
  var dbg = s.session.store.debugger.val
  dbg.status = dsStepping
  s.session.store.debugger.val = dbg

  discard s.backend.sendDapRequest(
    "stepBack",
    %*{"threadId": 1, "granularity": "statement"})
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

proc getCurrentColumn*(s: HeadlessDebugSession): Option[int] =
  ## M1 — return the 1-indexed column the current step landed on, as
  ## reported by the backend's most recent ``ct/complete-move`` event.
  ##
  ## The DAP-reported column is `Option<i64>` on the wire: ``None`` for
  ## legacy line-only recordings, ``Some(c)`` for column-aware traces
  ## (Python + JavaScript recorders).  We surface the same shape so
  ## tests can distinguish "the trace has no column data" from "the
  ## column is at position 0/1/..".  The store currently keeps only
  ## the line; the column is read straight off the cached complete-move
  ## event to avoid widening every downstream consumer mid-migration.
  if s.lastCompleteMoveEvent.isNil:
    return none(int)
  let body = s.lastCompleteMoveEvent.getOrDefault("body")
  if body.isNil:
    return none(int)
  if not body.hasKey("location"):
    return none(int)
  let loc = body["location"]
  if not loc.hasKey("column") or loc["column"].kind == JNull:
    return none(int)
  some(loc["column"].getInt(0))

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

# ---------------------------------------------------------------------------
# `ct/load-locals` value decoding — PLAT-2
#
# THIS MODULE NO LONGER RENDERS VALUES. It decodes the wire into `PValue` and
# hands it to the ONE presenter, at a budget it declares by name.
#
# What used to be here was `extractValueText`: a 130-line, kind-directed
# renderer that reproduced `common_types/utils/text_representation.textRepr`'s
# conventions over `JsonNode` because it could not import them (`common_types`
# is `include`d twice under incompatible `langstring` bindings). It was the
# FOURTH of seven independent implementations of "value -> string" in this
# repository, and the divergences were not stylistic: it wrote a struct `{…}`
# where the desktop wrote `Type(…)`, it had no member cap at all, and it was
# not language-aware, so a Rust `Vec` read `[…]` in the terminal and `vec![…]`
# in the desktop.
#
# `../../common/value_presentation/json_adapter.toPValue` is the decode half of
# that function with the renderer removed. The wire ordinals it needs moved
# with it — `src/common/value_presentation_bridge_test.nim` asserts the
# transcription still matches `TypeKind` (suite "PLAT-2: the wire ordinals in
# json_adapter ARE TypeKind's", which walks every member of the enum and
# asserts the COUNT is 34). That is the check that was missing when the
# PREVIOUS set of ordinals was wrong on six kinds; the sixty lines of
# measurement that used to stand here are preserved in that file's header,
# where the assertion that would catch a recurrence now lives beside them.
# ---------------------------------------------------------------------------

proc valueTypeName*(valueNode: JsonNode): string =
  ## `Value.typ.langType`, or "" when the response carries no type.
  json_adapter.typeNameOf(valueNode)

proc valuePresentation*(valueNode: JsonNode; budget: Budget): Presentation =
  ## One wire value, presented at `budget`. THE decoding entry point.
  present(json_adapter.toPValue(valueNode), budget)

proc presentedValueText*(valueNode: JsonNode;
                         budget: Budget = tuiValueBudget()): string =
  ## The single-line rendering a `store/types.Variable` carries.
  valuePresentation(valueNode, budget).root.text


proc variableFromPValue*(name: string; pv: PValue): Variable =
  ## One `Variable` and, RECURSIVELY, its members.
  ##
  ## THE RECURSION IS THE POINT, and its absence was a real limitation rather
  ## than a simplification: an earlier implementation built children with
  ## neither `hasChildren` nor `children` set, so a compound member — every
  ## entry of `wide_state`'s `wide_mapping`, which is a `(key, value)` tuple —
  ## arrived at a tree view as a leaf that could not be opened. The engine's
  ## own answer already carries the whole subtree (bounded by the request's
  ## `depthLimit`), so nothing extra is fetched; it was being discarded.
  ##
  ## PLAT-2: THE ROW CARRIES THE VALUE, NOT ONLY ITS RENDERING. `presented` is
  ## the normalised value, so a pane that knows its own width can ask the
  ## presenter for a rendering that fits IT rather than clipping a string
  ## rendered for somebody else. `value` remains, and is the presenter's answer
  ## at `tui-value` — it is pipeline output, not a second formatter.
  result = Variable(name: name,
                    value: present(pv, tuiValueBudget()).root.text,
                    typeName: (if pv.isNil: "" else: pv.typeName),
                    presented: pv)
  if pv.isNil:
    return
  if pv.kind == pvkMap:
    if pv.entries.len == 0:
      return
    result.hasChildren = true
    for idx, entry in pv.entries:
      # A map's child is named by its KEY's own rendering, at the same budget
      # the row uses. Before PLAT-2 a map had no children at all here: the
      # decoder looked for `elements`, and a `TableKind` carries `items`.
      result.children.add variableFromPValue(
        present(entry.key, tuiValueBudget()).root.text, entry.val)
    return
  if not isContainer(pv.kind) or pv.members.len == 0:
    return
  result.hasChildren = true
  for idx, m in pv.members:
    let childName = if m.label.len > 0: m.label else: "[" & $idx & "]"
    result.children.add variableFromPValue(childName, m.value)

proc variableFromValue*(name: string; valueNode: JsonNode): Variable =
  ## One wire variable, decoded and presented.
  variableFromPValue(name, json_adapter.toPValue(valueNode))

proc parseVariable(localNode: JsonNode): Variable =
  ## Parse a single variable entry from the ct/load-locals response.
  variableFromValue(localNode.getOrDefault("expression").getStr(""),
                    localNode.getOrDefault("value"))

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
  # THE SESSION'S OWN WATCH LIST, not a literal `[]`.
  #
  # This surface exposes `addWatch` / `removeWatch` (below) which write
  # `stateVM.watchExpressions`, and then asked the backend for no watches
  # at all — so a headless or SDK caller could add a watch and never
  # receive an answer to it. Same crossed wiring the GUI had, on a
  # different surface.
  var watches: seq[string] = @[]
  if not s.session.isNil and not s.session.stateVM.isNil:
    watches = s.session.stateVM.watchExpressions.val
  let args = %*{
    "rrTicks": s.getCurrentRRTicks().int64,
    "countBudget": 3000,
    "minCountLimit": 50,
    "depthLimit": 7,
    "watchExpressions": watches,
    "lang": 0,  # auto-detect
  }
  let resp = s.backend.sendDapRequest("ct/load-locals", args)
  if resp.getOrDefault("success").getBool(false):
    let body = resp.getOrDefault("body")
    if not body.isNil and body.kind == JObject:
      let localsNode = body.getOrDefault("locals")
      if not localsNode.isNil and localsNode.kind == JArray:
        # Watch answers ride the same list, marked `value.isWatch`. The
        # split itself is `applyLocalsResponse`'s — the one place every
        # host does it.
        var rows: seq[Variable]
        for localNode in localsNode:
          var parsed = parseVariable(localNode)
          parsed.isWatch =
            localNode.getOrDefault("value").getOrDefault("isWatch").getBool(false)
          rows.add(parsed)
        s.session.store.applyLocalsResponse(rows)
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
  ## The handler does send a DAP response (see ``Handler::calltrace_jump``),
  ## but this helper synchronises on the events rather than on the reply, so
  ## it uses ``sendDapRequestNoResponse`` and lets ``waitForEvent`` drop the
  ## response.  The note that previously stood here -- that the handler sends
  ## no response at all -- described a defect that has since been fixed.
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

proc setBreakpoint*(s: HeadlessDebugSession; file: string; line: int;
                    column: int = 0; condition: string = "") =
  ## Send a ``setBreakpoints`` DAP request for a single breakpoint at the
  ## given file and line.  The standard DAP ``setBreakpoints`` command
  ## replaces all breakpoints for the specified source, so calling this
  ## multiple times for the same file will overwrite previous breakpoints
  ## in that file.
  ##
  ## M1 — Column-Aware Replay Navigation: when ``column`` is non-zero the
  ## breakpoint is anchored at ``(line, column)`` and the next ``continue``
  ## stops only at recorded steps whose ``(line, column)`` match exactly.
  ## When ``column`` is ``0`` (the default) the legacy line-only semantics
  ## apply: the next ``continue`` stops at the first recorded step on
  ## ``line``, regardless of column.
  ##
  ## M9 — Column-Aware Conditional Breakpoint: when ``condition`` is
  ## non-empty the replay engine evaluates the expression against the
  ## locals recorded at the candidate stop step and only fires the
  ## breakpoint when the expression yields a truthy value.  Composes
  ## orthogonally with ``column``: both filters apply when both are
  ## set.  ``condition = ""`` (the default) preserves the M1
  ## unconditional behaviour.
  ##
  ## See ``codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org``
  ## §M1 and §M9 for the DAP wire contract.
  var bp = %*{"line": line}
  if column > 0:
    bp["column"] = %column
  if condition.len > 0:
    bp["condition"] = %condition
  let args = %*{
    "source": {
      "path": file,
    },
    "breakpoints": [bp],
  }
  let resp = s.backend.sendDapRequest("setBreakpoints", args)
  if not resp.getOrDefault("success").getBool(false):
    raise newException(IOError,
      "setBreakpoints failed: " & $resp)

proc addColumnTracepoint*(s: HeadlessDebugSession; file: string; line: int;
                           column: int; logMessage: string) =
  ## M10 — register a column-aware DAP *tracepoint* (logpoint) by
  ## sending a ``setBreakpoints`` DAP request whose
  ## ``SourceBreakpoint`` carries a non-empty ``logMessage``.  The
  ## replay engine routes the request to its tracepoint registry
  ## instead of the breakpoint registry: when the next ``continue``
  ## traverses the matched ``(file, line, column)`` step the engine
  ## emits a DAP ``output`` event carrying ``logMessage`` and
  ## continues WITHOUT stopping.
  ##
  ## ``column`` may be ``0`` for the legacy line-only logpoint
  ## behaviour (fires on every step on the line).  ``logMessage``
  ## must be non-empty — a tracepoint with no message is a
  ## breakpoint, so callers should use ``setBreakpoint`` instead.
  ##
  ## See ``codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org``
  ## §M10 for the DAP wire contract.
  doAssert logMessage.len > 0,
    "addColumnTracepoint: logMessage must be non-empty (a logpoint without " &
    "a message is a breakpoint — use setBreakpoint instead)"
  var bp = %*{"line": line, "logMessage": logMessage}
  if column > 0:
    bp["column"] = %column
  let args = %*{
    "source": {
      "path": file,
    },
    "breakpoints": [bp],
  }
  let resp = s.backend.sendDapRequest("setBreakpoints", args)
  if not resp.getOrDefault("success").getBool(false):
    raise newException(IOError,
      "setBreakpoints (logpoint) failed: " & $resp)

proc lastSetTracepointResponse*(s: HeadlessDebugSession;
                                file: string; line: int;
                                column: int;
                                logMessage: string): JsonNode =
  ## M10 — same wire shape as ``addColumnTracepoint`` but returns the
  ## raw DAP response so tests can assert on the bound column the
  ## backend echoes back (mirrors ``lastSetBreakpointsResponse``).
  doAssert logMessage.len > 0
  var bp = %*{"line": line, "logMessage": logMessage}
  if column > 0:
    bp["column"] = %column
  let args = %*{
    "source": {
      "path": file,
    },
    "breakpoints": [bp],
  }
  result = s.backend.sendDapRequest("setBreakpoints", args)

proc lastSetBreakpointsResponse*(s: HeadlessDebugSession;
                                 file: string; line: int;
                                 column: int = 0;
                                 condition: string = ""): JsonNode =
  ## Send a ``setBreakpoints`` request and return the raw DAP response
  ## body.  Mirrors ``setBreakpoint`` but exposes the response so tests
  ## can assert on the bound ``column`` the backend echoes back.
  ##
  ## M9 — Column-Aware Conditional Breakpoint: the optional
  ## ``condition`` parameter is forwarded to the replay engine
  ## alongside the column.  The DAP response doesn't echo the
  ## condition back (DAP doesn't define that round-trip slot), but
  ## the ``verified`` flag and the bound ``column`` confirm the
  ## request was accepted.
  var bp = %*{"line": line}
  if column > 0:
    bp["column"] = %column
  if condition.len > 0:
    bp["condition"] = %condition
  let args = %*{
    "source": {
      "path": file,
    },
    "breakpoints": [bp],
  }
  result = s.backend.sendDapRequest("setBreakpoints", args)

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
    # CTUI-8 added the four fields below. They were already on the wire — every
    # one is a field of ``ProgramEvent``
    # (``libs/ct-dap-client/src/types/common.rs``) that this decoder discarded —
    # and a timeline pane needs all four: ``kind`` and ``stdout`` are what
    # decide whether a recorded write is a print or a storage mutation,
    # ``eventIndex`` is the row's position in the WHOLE log rather than in the
    # page, and ``maxRRTicks`` is the recording's last step id, which is the
    # only surface in this workspace that reports a completed replay's extent.
    kind*: int
      ## ``EventLogKind`` ordinal: 0 = Write, 1 = WriteFile, … 11 = Error.
    stdout*: bool
    eventIndex*: int
    maxRRTicks*: uint64

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
          entry.kind = ev.getOrDefault("kind").getInt(0)
          entry.stdout = ev.getOrDefault("stdout").getBool(false)
          entry.eventIndex = ev.getOrDefault("event_index").getInt(
            ev.getOrDefault("eventIndex").getInt(0))
          entry.maxRRTicks =
            ev.getOrDefault("maxRRTicks").getBiggestInt(0).uint64
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
# Absolute tick seeking (CTUI-8)
# ---------------------------------------------------------------------------

proc settleAfterSeek*(s: HeadlessDebugSession) =
  ## Consume the ``stopped`` + ``ct/complete-move`` pair a seek produces and
  ## mirror the landed position into the store.
  ##
  ## EXPOSED SEPARATELY BECAUSE THE SEEK ITSELF BELONGS TO THE PRODUCT.  CTUI-8's
  ## contract is that selecting an event issues ONE atomic ``goto`` through
  ## ``TimelineVM.seek`` — a ViewModel action, on the store's own
  ## ``BackendService`` — and a harness that also sent the request would be
  ## testing its own path instead of the product's.  So a caller drives
  ## ``TimelineVM.seek`` and then calls this to pump the events; nothing else in
  ## this module can do the pumping for it, because ``consumeCompleteMoveEvent``
  ## is private and the position mirroring is what makes every pane agree.
  discard s.backend.waitForEvent("stopped")
  s.consumeCompleteMoveEvent()

proc gotoTick*(s: HeadlessDebugSession; tick: uint64) =
  ## Seek to an absolute recorded tick with ``ct/goto-ticks`` and block until
  ## the backend reports the new position.
  ##
  ## ``ct/goto-ticks`` and ``ct/timeline-seek`` reach the SAME handler —
  ## ``dap_server.rs`` routes both into ``Handler::goto_ticks`` — so this is the
  ## raw twin of the product path above, for callers that need a position
  ## without a ViewModel in the picture.
  s.backend.sendDapRequestNoResponse("ct/goto-ticks", %*{"ticks": tick.int64})
  s.settleAfterSeek()

# ---------------------------------------------------------------------------
# Post-hoc tracepoints (CTUI-8)
# ---------------------------------------------------------------------------

type
  TracepointSweepSpec* = object
    ## One tracepoint to run over the whole recording.
    tracepointId*: int
    path*: string
    line*: int
    expression*: string
    lang*: int
      ## ``Lang`` ordinal (``libs/ct-lang/src/lib.rs``).  Measured on ``calc``
      ## with both 12 (``Python``) and 21 (``PythonDb``): the engine answered
      ## identically and echoed ``lang: 0`` on every ``Stop``, so it does not
      ## select the evaluator on a CTFS trace.  The field is still sent because
      ## ``Tracepoint`` requires it.

  TracepointSweepHit* = object
    ## One ``Stop`` from a ``ct/tracepoint-results`` answer.
    tracepointId*: int
    rrTicks*: uint64
    path*: string
    line*: int
    values*: seq[(string, string)]
      ## The locals the expression named, as ``(name, rendered)``.
    errorMessage*: string

proc runTracepoints*(s: HeadlessDebugSession;
                     specs: seq[TracepointSweepSpec];
                     maxMessages = 40): seq[TracepointSweepHit] =
  ## Run post-hoc tracepoints over the WHOLE recording and return every hit.
  ##
  ## ``ct/run-tracepoints`` ANSWERS WITH NO DAP RESPONSE, and that is not a
  ## guess: ``Handler::run_tracepoints`` (``src/db-backend/src/dap_handler.rs``)
  ## sends ``ct/updated-trace`` and ``ct/tracepoint-results`` and never calls
  ## ``respond_dap``.  A caller that used ``sendDapRequest`` here would block for
  ## ever — measured, as a hang, on ``calc`` on 2026-09-06 before the handler was
  ## read.  This is exactly the shape
  ## ``codetracer-specs/Testing/Verification-Harness-Traps.md`` §3 describes: the
  ## symptom is a timeout and the cause is a boundary that speaks a different
  ## shape.  So the request is sent WITHOUT expecting a reply and the
  ## synchronisation is on the ``ct/tracepoint-results`` event.
  ##
  ## Raises ``ValueError`` (from ``waitForEvent``) when the event does not
  ## arrive within the message budget, rather than returning an empty sequence:
  ## "the sweep found nothing" and "the sweep never answered" are different
  ## facts and only one of them is a result.
  var tracepoints = newJArray()
  for spec in specs:
    tracepoints.add %*{
      "tracepointId": spec.tracepointId,
      "mode": 0,
      "line": spec.line,
      "offset": 0,
      "name": spec.path,
      "expression": spec.expression,
      "lastRender": 0,
      "isDisabled": false,
      "isChanged": true,
      "lang": spec.lang,
      "results": newJArray(),
      "tracepointError": "",
    }
  s.backend.sendDapRequestNoResponse("ct/run-tracepoints", %*{
    "session": {
      "tracepoints": tracepoints,
      "found": newJArray(),
      "lastCount": 0,
      "results": newJObject(),
      "id": 0,
    },
    "stopAfter": -1,
  })
  let event = s.backend.waitForEvent("ct/tracepoint-results",
                                     maxMessages = maxMessages)
  let body = event.getOrDefault("body")
  if body.isNil or body.kind != JObject:
    return
  let results = body.getOrDefault("results")
  if results.isNil or results.kind != JArray:
    return
  for stop in results:
    var hit = TracepointSweepHit(
      tracepointId: stop.getOrDefault("tracepointId").getInt(0),
      rrTicks: stop.getOrDefault("rrTicks").getBiggestInt(0).uint64,
      path: stop.getOrDefault("path").getStr(""),
      line: stop.getOrDefault("line").getBiggestInt(0).int,
      values: @[],
      errorMessage: stop.getOrDefault("errorMessage").getStr(""))
    let locals = stop.getOrDefault("locals")
    if not locals.isNil and locals.kind == JArray:
      for pair in locals:
        # `StringAndValueTuple` serialises as `{"Field0": name, "Field1": value}`
        # — a tuple struct, so the names are positional and not descriptive.
        let name = pair.getOrDefault("Field0").getStr("")
        let value = pair.getOrDefault("Field1")
        hit.values.add (name, presentedValueText(value, TracepointBudget))
    result.add hit

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
  ##
  ## `disconnectBackend = false` because this harness owns the child process
  ## and closes it on the next line; letting the SDK also route a disconnect
  ## through `toBackendService`'s `disconnectProc` would call
  ## `DapStdioBackend.close` twice on the same handle.
  s.sdk.dispose(disconnectBackend = false)
  s.backend.close()
