## store/replay_data_store.nim
##
## ReplayDataStore — the central reactive data layer for the ViewModel
## architecture.
##
## Holds IsoNim signals for every piece of state that panels display and
## exposes high-level request procs that talk to the BackendService.
## The store owns the RequestTracker to avoid duplicate in-flight
## requests and updates LoadingState signals so the UI can show
## spinners / errors.
##
## Usage:
##   let store = createReplayDataStore(backend)
##   # read reactive state
##   echo store.debugger.val.status       # dsIdle
##   # issue a command — signals update asynchronously
##   store.requestStep(sdForward)

import std/[json, options, tables]
when defined(js):
  import ../../lib/logging

import isonim/core/[signals, owner, async_compat]
import isonim/viewmodel

import ../backend/backend_service
import types, request_tracker

const
  LiveMcrGetRecordingHeadCommand* = "ct/mcr-get-recording-head"
  LiveMcrRestoreAtCommand* = "ct/mcr-restore-at"
  LiveMcrStepCommand* = "ct/mcr-live-step"
  SeekToGeidCommand* = "ct/seek-to-geid"

# ---------------------------------------------------------------------------
# Store identity tracking — unique ID per store instance for diagnostics
# ---------------------------------------------------------------------------
var storeIdCounter {.global.}: int = 0

# ---------------------------------------------------------------------------
# Cross-platform future callback helper
# ---------------------------------------------------------------------------

proc onComplete(fut: BackendFuture[JsonNode];
                onSuccess: proc(); onError: proc()) =
  ## Convenience wrapper around `async_compat.onComplete` that discards
  ## the result value and error message, matching the fire-and-forget
  ## pattern used by store request procs.
  async_compat.onComplete(fut,
    onSuccess = proc(val: JsonNode) = onSuccess(),
    onError = proc(msg: string) = onError())

proc readRRTicks(response: JsonNode; fallback: uint64): uint64 =
  ## Accept the likely fake/real backend response shapes used while MCR live
  ## support is still behind test seams.
  if response.kind != JObject:
    return fallback

  for key in ["rrTicks", "recordingHead", "head"]:
    if response.hasKey(key):
      let raw = response[key].getBiggestInt
      if raw < 0:
        return 0'u64
      return uint64(raw)

  fallback

# ---------------------------------------------------------------------------
# Sub-store aggregates — group related signals
# ---------------------------------------------------------------------------

type
  CalltraceStore* = object
    ## Reactive state for the calltrace panel.
    lines*: Signal[seq[CallLine]]
    ## Per-call argument values keyed by ``CallLine.callKey``. The old
    ## Karax calltrace rows read the same map (``CalltraceComponent.args``)
    ## to render each row's ``.call-arg`` children. Mirroring it into the
    ## store lets the IsoNim view emit identical DOM driven purely by
    ## reactive data.
    args*: Signal[Table[string, seq[CallArg]]]
    startLineIndex*: Signal[int64]
    totalCallsCount*: Signal[uint64]
    finished*: Signal[bool]
    loadingState*: Signal[LoadingState]

  LocalsStore* = object
    ## Reactive state for the locals / globals panel.
    locals*: Signal[seq[Variable]]
    globals*: Signal[seq[Variable]]
    loadingState*: Signal[LoadingState]
    loadedForRRTicks*: Signal[uint64]
      ## The rrTicks value that the currently loaded data corresponds to.
      ## Lets the UI know whether the data is stale relative to the
      ## debugger position.
    codeStateLine*: Signal[string]
      ## Pre-formatted "<line> | <sourceCode>" string shown above the
      ## variables list (rendered as the `#code-state-line-{id}`
      ## element in the IsoNim state view).  The legacy Karax
      ## ``StateComponent.excerpt`` proc rendered the same text from
      ## ``data.ui.editors[path].sourceLines[line - 1]``; mirroring it
      ## into the store lets the IsoNim view emit the DOM the
      ## Playwright tests look for, regardless of whether the trace is
      ## RR or Materialized.  Empty string means "no source" — the
      ## view falls back to the ``no-code`` class with a blank label.

  ReplayDataStore* = ref object of ViewModel
    ## Central reactive store.  Created via `createReplayDataStore`.
    storeId*: int  ## Unique identity for diagnostics — assigned in createReplayDataStore.
    session*: Signal[SessionState]
    debugger*: Signal[DebuggerState]
    currentGeid*: Signal[Option[uint64]]
    timeline*: Signal[TimelineState]
    calltrace*: CalltraceStore
    locals*: LocalsStore
    backend*: BackendService
    requestTracker*: RequestTracker

proc setDebuggerSnapshot(store: ReplayDataStore; rrTicks: uint64;
                         status: DebuggerStatus) =
  let current = store.debugger.val
  store.debugger.val = DebuggerState(
    rrTicks: rrTicks,
    location: current.location,
    status: status,
    threadId: current.threadId,
  )

proc setSessionMode*(store: ReplayDataStore; mode: DebugSessionMode) =
  ## Update only the debug-session mode, preserving connection/head state.
  var session = store.session.val
  session.debugSessionMode = mode
  store.session.val = session

proc updateRecordingHead*(store: ReplayDataStore; rrTicks: uint64) =
  ## Mirror a backend recording-head update into session and timeline state.
  var session = store.session.val
  session.recordingHeadRRTicks = rrTicks
  session.recordingHeadLoadingState = lsIdle
  store.session.val = session

  var timeline = store.timeline.val
  if rrTicks > timeline.maxRRTicks:
    timeline.maxRRTicks = rrTicks
  store.timeline.val = timeline

# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

proc createReplayDataStore*(backend: BackendService): ReplayDataStore =
  ## Create the store inside a reactive root.  The root's dispose proc
  ## is stored on the ViewModel base so the caller can tear everything
  ## down with `store.dispose()`.
  withViewModel proc(dispose: proc()): ReplayDataStore =
    inc storeIdCounter
    let assignedId = storeIdCounter
    when defined(js):
      cerror "[PIPELINE] createReplayDataStore: creating store id=" & $assignedId
    let store = ReplayDataStore(
      storeId: assignedId,
      # -- top-level state --
      session: createSignal(SessionState(
        connectionStatus: csDisconnected,
      )),
      debugger: createSignal(DebuggerState(
        location: Location(file: "", line: 0, column: 0),
        rrTicks: 0'u64,
        status: dsIdle,
        threadId: 0'u32,
      )),
      currentGeid: createSignal(none(uint64)),
      timeline: createSignal(TimelineState(
        minRRTicks: 0'u64,
        maxRRTicks: 0'u64,
        currentRRTicks: 0'u64,
      )),

      # -- calltrace --
      calltrace: CalltraceStore(
        lines: createSignal(newSeq[CallLine]()),
        args: createSignal(initTable[string, seq[CallArg]]()),
        startLineIndex: createSignal(0'i64),
        totalCallsCount: createSignal(0'u64),
        finished: createSignal(false),
        loadingState: createSignal(lsIdle),
      ),

      # -- locals --
      locals: LocalsStore(
        locals: createSignal(newSeq[Variable]()),
        globals: createSignal(newSeq[Variable]()),
        loadingState: createSignal(lsIdle),
        loadedForRRTicks: createSignal(0'u64),
        codeStateLine: createSignal(""),
      ),

      # -- services --
      backend: backend,
      requestTracker: newRequestTracker(),
      disposeProc: dispose,
    )
    store

# ---------------------------------------------------------------------------
# Request procs
# ---------------------------------------------------------------------------

proc requestLocals*(store: ReplayDataStore; rrTicks: uint64;
                    countBudget: int = 3000;
                    minCountLimit: int = 50;
                    depthLimit: int = 7;
                    watchExpressions: seq[string] = @[];
                    lang: int = 0) =
  ## Request locals/globals from the backend for the given rrTicks.
  ## Skipped if an identical request is already in flight.
  ##
  ## The backend expects the full ``CtLoadLocalsArguments`` set
  ## (rrTicks, countBudget, minCountLimit, depthLimit,
  ## watchExpressions, lang).  Default values match the legacy
  ## ``loadLocals`` in state.nim so callers that only know the
  ## tick position still produce a valid request.
  ##
  ## ``lang`` is the ordinal of the ``Lang`` enum (matching the Rust
  ## backend's ``#[repr(u8)]`` Lang which uses ``serde_repr``).
  ## 0 = C (the Rust-side default).
  let key = "load-locals"
  # Include watch expressions in the dedup key so that adding a new
  # watch at the same rrTicks position still triggers a fresh request.
  let argsStr = $rrTicks & "|" & $watchExpressions.len
  if store.requestTracker.isDuplicate(key, argsStr):
    return

  store.requestTracker.markPending(key, argsStr)
  store.locals.loadingState.val = lsLoading

  let args = %*{
    "rrTicks": rrTicks,
    "countBudget": countBudget,
    "minCountLimit": minCountLimit,
    "depthLimit": depthLimit,
    "watchExpressions": watchExpressions,
    "lang": lang,
  }
  let fut = store.backend.send("ct/load-locals", args)

  # In the native (C) backend the future resolves synchronously in
  # tests.  The actual JSON→Variable parsing will be added when the
  # locals panel is converted; for now we just update loading state.
  # The callback mutates reactive signals which are thread-local
  # (not gcsafe), but we are single-threaded so the cast is safe.
  let s = store
  let ticks = rrTicks
  fut.onComplete(
    onSuccess = proc() =
      s.requestTracker.markComplete(key)
      s.locals.loadingState.val = lsIdle
      s.locals.loadedForRRTicks.val = ticks,
    onError = proc() =
      s.requestTracker.markComplete(key)
      s.locals.loadingState.val = lsError,
  )

proc requestCalltraceSection*(store: ReplayDataStore;
                              startIndex: int64;
                              height: int;
                              depth: int;
                              rrTicks: uint64 = 0;
                              file: string = "";
                              line: int = 0;
                              rawIgnorePatterns: string = "";
                              optimizeCollapse: bool = true;
                              autoCollapsing: bool = false;
                              renderCallLineIndex: int = 0) =
  ## Request a window of calltrace lines from the backend.
  ## Skipped if an identical request is already in flight.
  ##
  ## The command name matches the legacy CtLoadCalltraceSection event
  ## ("ct/load-calltrace-section") so that the RealBackendService can
  ## translate it to the correct CtEventKind via dapCommandToEventKind.
  ## The backend responds with CtUpdatedCalltrace which is handled by
  ## the existing event-bus subscription in calltrace.nim.
  let key = "load-calltrace"
  let argsStr = $startIndex & "|" & $height & "|" & $depth & "|" & $rrTicks
  if store.requestTracker.isDuplicate(key, argsStr):
    return

  store.requestTracker.markPending(key, argsStr)
  store.calltrace.loadingState.val = lsLoading

  # Build a location sub-object matching the legacy CalltraceLoadArgs format.
  let args = %*{
    "location": {
      "rrTicks": rrTicks,
      "path": file,
      "line": line,
    },
    "startCallLineIndex": startIndex,
    "height": height,
    "depth": depth,
    "rawIgnorePatterns": rawIgnorePatterns,
    "optimizeCollapse": optimizeCollapse,
    "autoCollapsing": autoCollapsing,
    "renderCallLineIndex": renderCallLineIndex,
  }
  let fut = store.backend.send("ct/load-calltrace-section", args)

  let s = store
  fut.onComplete(
    onSuccess = proc() =
      s.requestTracker.markComplete(key)
      s.calltrace.loadingState.val = lsIdle,
    onError = proc() =
      s.requestTracker.markComplete(key)
      s.calltrace.loadingState.val = lsError,
  )

# ---------------------------------------------------------------------------
# Bridge procs — used by the legacy UI layer to feed data into the store
# without importing store/types (which would cause name conflicts with
# the legacy types).
# ---------------------------------------------------------------------------

proc updateDebuggerPosition*(store: ReplayDataStore;
                             rrTicks: uint64;
                             file: string = "";
                             line: int = 0;
                             geid: Option[uint64] = none(uint64)) =
  ## Update the store's debugger signal with a new rrTicks position.
  ## Used by legacy UI code to mirror move events into the ViewModel layer.
  # Always construct and assign a new DebuggerState so the signal fires.
  # DB-based traces have rrTicks=0 for every position, so the old
  # `if current.rrTicks != rrTicks` guard prevented the signal from
  # ever triggering. Deduplication of redundant backend requests is
  # handled by RequestTracker, not here.
  let current = store.debugger.val
  when defined(js):
    cerror "[PIPELINE] updateDebuggerPosition: storeId=" &
      $store.storeId & " setting rrTicks=" & $rrTicks & " (was " &
      $current.rrTicks & ") file=" & file & " line=" & $line
  # Construct a NEW object — on JS backend, var = signal.val gets a
  # reference, so mutating and writing back the same object doesn't
  # trigger the signal's equality check (it compares to itself).
  store.debugger.val = DebuggerState(
    rrTicks: rrTicks,
    location: Location(file: file, line: line),
    status: current.status,
    threadId: current.threadId,
  )
  if geid.isSome:
    store.currentGeid.val = geid

proc updateCurrentGeid*(store: ReplayDataStore; geid: Option[uint64]) =
  ## Update the current visual replay GEID independently of rrTicks. MCR
  ## backends can report a graphics event id for the debugger stop even when
  ## the source-level rrTicks position is unchanged or unavailable.
  store.currentGeid.val = geid

proc updateLocals*(store: ReplayDataStore;
                   variables: seq[Variable]) =
  ## Replace the store's locals signal with a new variable list.
  ## Used by legacy UI code to mirror locals responses into the
  ## ViewModel layer.
  when defined(js):
    cerror "[PIPELINE] updateLocals: setting " & $variables.len & " variables"
  store.locals.locals.val = variables
  store.locals.loadingState.val = lsIdle

proc updateCodeStateLine*(store: ReplayDataStore;
                          line: int;
                          sourceCode: string) =
  ## Update the formatted "<line> | <sourceCode>" string displayed above
  ## the variables list. Empty ``sourceCode`` means "no source available
  ## yet" — callers pass it that way when the editor for the current
  ## file has not loaded its source lines yet, or when the trace's
  ## position is on a synthetic location with no source mapping.
  ## The IsoNim state view reads this signal to decide between the
  ## populated ``code-state-line`` markup and the ``no-code`` fallback.
  let formatted =
    if sourceCode.len == 0: ""
    else: $line & " | " & sourceCode
  when defined(js):
    cerror "[PIPELINE] updateCodeStateLine: storeId=" &
      $store.storeId & " line=" & $line & " has_source=" &
      $(sourceCode.len > 0)
  store.locals.codeStateLine.val = formatted

proc makeVariable*(name, value, typeName: string;
                   hasChildren: bool = false;
                   children: seq[Variable] = @[]): Variable =
  ## Convenience constructor for Variable — avoids the need for callers
  ## to import store/types.
  Variable(name: name, value: value, typeName: typeName,
           hasChildren: hasChildren, children: children)

proc newVariableSeq*(): seq[Variable] =
  ## Create an empty seq of store Variables. Useful for callers that
  ## cannot name the Variable type due to import conflicts.
  newSeq[Variable]()

proc updateCalltraceSection*(store: ReplayDataStore;
                             lines: seq[CallLine];
                             startIndex: int64;
                             totalCount: uint64;
                             args: Table[string, seq[CallArg]] =
                                 initTable[string, seq[CallArg]]()) =
  ## Replace the store's calltrace signals with new section data.
  ## Used by legacy UI code to mirror calltrace responses into the
  ## ViewModel layer.
  ##
  ## ``args`` holds per-call argument values keyed by ``CallLine.callKey``.
  ## When omitted, the args signal is left untouched so callers that only
  ## know about lines (the legacy headless tests) still work; callers that
  ## carry args (notably ``syncCalltraceData`` in
  ## ``frontend/ui/calltrace.nim``) pass the parsed map alongside lines.
  when defined(js):
    cerror "[PIPELINE] updateCalltraceSection: storeId=" &
      $store.storeId & " setting " & $lines.len & " lines (was " &
      $store.calltrace.lines.val.len & "), startIndex=" & $startIndex &
      " totalCount=" & $totalCount
  store.calltrace.lines.val = lines
  # Replace args atomically with the new section's args.  If the caller
  # didn't supply any (the VM tests that only know about lines), the
  # existing args are cleared so stale entries from a prior section
  # don't bleed into the freshly loaded rows.
  store.calltrace.args.val = args
  store.calltrace.startLineIndex.val = startIndex
  store.calltrace.totalCallsCount.val = totalCount
  store.calltrace.loadingState.val = lsIdle

proc updateCalltraceArgs*(store: ReplayDataStore;
                          args: Table[string, seq[CallArg]]) =
  ## Replace the store's per-call argument map. Separate from
  ## ``updateCalltraceSection`` for callers that already have lines but
  ## want to feed args separately (e.g. when args arrive on a follow-up
  ## response). The signal is set unconditionally so empty maps overwrite
  ## stale data on a fresh navigation.
  store.calltrace.args.val = args

proc makeCallArg*(name, text: string): CallArg =
  ## Convenience constructor for the ViewModel ``CallArg``. Mirrors the
  ## ``makeCallLine`` helper above so callers in ``frontend/ui`` don't
  ## have to import ``store/types`` directly (which would clash with the
  ## legacy ``CallArg`` ref-object name).
  CallArg(name: name, text: text)

proc makeCallLine*(name: string; depth: int; rrTicks: uint64;
                   file: string = ""; line: int = 0;
                   callstackDepth: int = 0;
                   hasChildren: bool = false; isExpanded: bool = false;
                   callKey: string = ""): CallLine =
  ## Convenience constructor for CallLine — avoids the need for callers
  ## to import store/types.
  CallLine(
    index: 0,
    name: name,
    depth: depth,
    rrTicks: rrTicks,
    location: Location(file: file, line: line, callstackDepth: callstackDepth),
    hasChildren: hasChildren,
    isExpanded: isExpanded,
    callKey: callKey,
  )

proc stepDirectionToDapCommand*(direction: StepDirection): string =
  ## Map a StepDirection to the correct DAP command string.
  ## Each direction corresponds to a standard DAP command or a
  ## CodeTracer extension command, all of which are registered
  ## in the EVENT_KIND_TO_DAP_MAPPING table in dap.nim.
  case direction
  of sdForward:          "next"
  of sdBackward:         "stepBack"
  of sdStepIn:           "stepIn"
  of sdStepOut:          "stepOut"
  of sdContinue:         "continue"
  of sdReverseContinue:  "reverseContinue"
  of sdReverseStepIn:    "ct/reverseStepIn"
  of sdReverseStepOut:   "ct/reverseStepOut"

proc requestStep*(store: ReplayDataStore; direction: StepDirection) =
  ## Send a step command to the backend.
  ## Marks the debugger as stepping while the request is in flight.
  ##
  ## The direction is mapped to the correct DAP command string
  ## (e.g. sdForward → "next", sdStepIn → "stepIn") so that
  ## ``dapCommandToEventKind`` in dap.nim can resolve it without
  ## raising ``ValueError``.
  let key = "step"
  let dirStr = $direction
  if store.requestTracker.isDuplicate(key, dirStr):
    return

  store.requestTracker.markPending(key, dirStr)

  # Update debugger status to stepping.
  # Construct a NEW object to avoid JS reference semantics bug.
  let current = store.debugger.val
  store.debugger.val = DebuggerState(
    rrTicks: current.rrTicks,
    location: current.location,
    status: dsStepping,
    threadId: current.threadId,
  )

  let command = stepDirectionToDapCommand(direction)
  let threadId =
    if current.threadId == 0'u32:
      1
    else:
      current.threadId.int
  let args = %*{"direction": dirStr, "threadId": threadId}
  let fut = store.backend.send(command, args)

  let s = store
  fut.onComplete(
    onSuccess = proc() =
      s.requestTracker.markComplete(key),
    onError = proc() =
      s.requestTracker.markComplete(key)
      var dbg = s.debugger.val
      dbg.status = dsError
      s.debugger.val = dbg,
  )

proc requestRecordingHead*(store: ReplayDataStore) =
  ## Query the live MCR backend for the current recording head and mirror it
  ## into the session/timeline signals.
  let key = "mcr-recording-head"
  if store.requestTracker.isDuplicate(key, ""):
    return

  store.requestTracker.markPending(key, "")
  var session = store.session.val
  session.recordingHeadLoadingState = lsLoading
  store.session.val = session

  let fut = store.backend.send(LiveMcrGetRecordingHeadCommand, %*{})
  let s = store
  async_compat.onComplete(fut,
    onSuccess = proc(response: JsonNode) =
      s.requestTracker.markComplete(key)
      let head = response.readRRTicks(s.session.val.recordingHeadRRTicks)
      s.updateRecordingHead(head),
    onError = proc(msg: string) =
      s.requestTracker.markComplete(key)
      var failedSession = s.session.val
      failedSession.recordingHeadLoadingState = lsError
      s.session.val = failedSession,
  )

proc requestLiveToolbarAction*(store: ReplayDataStore; actionId: string) =
  ## Route a toolbar action to the fake/real live MCR command path instead of
  ## the completed-replay DAP step commands.
  let key = "mcr-live-step"
  if store.requestTracker.isDuplicate(key, actionId):
    return

  store.requestTracker.markPending(key, actionId)
  let current = store.debugger.val
  let runningStatus =
    if actionId == "continue": dsRunning
    else: dsStepping
  store.setDebuggerSnapshot(current.rrTicks, runningStatus)

  let threadId =
    if current.threadId == 0'u32:
      1
    else:
      current.threadId.int
  let args = %*{"action": actionId, "threadId": threadId}
  let fut = store.backend.send(LiveMcrStepCommand, args)

  let s = store
  fut.onComplete(
    onSuccess = proc() =
      s.requestTracker.markComplete(key)
      s.setDebuggerSnapshot(s.debugger.val.rrTicks, dsIdle),
    onError = proc() =
      s.requestTracker.markComplete(key)
      var dbg = s.debugger.val
      dbg.status = dsError
      s.debugger.val = dbg,
  )

proc requestSeekToGeid*(store: ReplayDataStore; geid: uint64) =
  ## Ask the backend to move the source/debugger position to a graphics event.
  ## The follow-up complete-move event is expected to refresh debugger state.
  discard store.backend.send(SeekToGeidCommand, %*{"geid": geid})

proc requestRestoreAt*(store: ReplayDataStore; rrTicks: uint64;
                       jumpToLive: bool = false) =
  ## Restore execution at a recorded MCR position. A regular restore puts the
  ## toolbar into historical replay mode; jump-to-live restores to the tracked
  ## head and switches controls back to live mode.
  let key = if jumpToLive: "mcr-jump-to-live" else: "mcr-restore-at"
  let argsStr = $rrTicks
  if store.requestTracker.isDuplicate(key, argsStr):
    return

  store.requestTracker.markPending(key, argsStr)
  store.setDebuggerSnapshot(store.debugger.val.rrTicks, dsStepping)

  let args = %*{"rrTicks": rrTicks, "jumpToLive": jumpToLive}
  let fut = store.backend.send(LiveMcrRestoreAtCommand, args)
  let s = store
  fut.onComplete(
    onSuccess = proc() =
      s.requestTracker.markComplete(key)

      var session = s.session.val
      session.debugSessionMode =
        if jumpToLive: liveMcr else: historicalFromLive
      if jumpToLive and session.recordingHeadRRTicks < rrTicks:
        session.recordingHeadRRTicks = rrTicks
      s.session.val = session

      var timeline = s.timeline.val
      timeline.currentRRTicks = rrTicks
      if rrTicks > timeline.maxRRTicks:
        timeline.maxRRTicks = rrTicks
      s.timeline.val = timeline
      s.setDebuggerSnapshot(rrTicks, dsIdle),
    onError = proc() =
      s.requestTracker.markComplete(key)
      var dbg = s.debugger.val
      dbg.status = dsError
      s.debugger.val = dbg,
  )

proc jumpToLive*(store: ReplayDataStore) =
  ## Restore to the last known live recording head.
  store.requestRestoreAt(store.session.val.recordingHeadRRTicks,
                         jumpToLive = true)
