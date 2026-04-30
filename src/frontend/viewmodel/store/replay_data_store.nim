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

import std/json

import isonim/core/[signals, owner, async_compat]
import isonim/viewmodel

import ../backend/backend_service
import types, request_tracker

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

# ---------------------------------------------------------------------------
# Sub-store aggregates — group related signals
# ---------------------------------------------------------------------------

type
  CalltraceStore* = object
    ## Reactive state for the calltrace panel.
    lines*: Signal[seq[CallLine]]
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

  ReplayDataStore* = ref object of ViewModel
    ## Central reactive store.  Created via `createReplayDataStore`.
    storeId*: int  ## Unique identity for diagnostics — assigned in createReplayDataStore.
    session*: Signal[SessionState]
    debugger*: Signal[DebuggerState]
    timeline*: Signal[TimelineState]
    calltrace*: CalltraceStore
    locals*: LocalsStore
    backend*: BackendService
    requestTracker*: RequestTracker

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
      {.emit: "console.error('[PIPELINE] createReplayDataStore: creating store id=' + `assignedId`);".}
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
      timeline: createSignal(TimelineState(
        minRRTicks: 0'u64,
        maxRRTicks: 0'u64,
        currentRRTicks: 0'u64,
      )),

      # -- calltrace --
      calltrace: CalltraceStore(
        lines: createSignal(newSeq[CallLine]()),
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
                             line: int = 0) =
  ## Update the store's debugger signal with a new rrTicks position.
  ## Used by legacy UI code to mirror move events into the ViewModel layer.
  # Always construct and assign a new DebuggerState so the signal fires.
  # DB-based traces have rrTicks=0 for every position, so the old
  # `if current.rrTicks != rrTicks` guard prevented the signal from
  # ever triggering. Deduplication of redundant backend requests is
  # handled by RequestTracker, not here.
  let current = store.debugger.val
  let diagOldTicks = current.rrTicks
  let diagStoreId = store.storeId
  when defined(js):
    {.emit: "console.error('[PIPELINE] updateDebuggerPosition: storeId=' + `diagStoreId` + ' setting rrTicks=' + `rrTicks` + ' (was ' + `diagOldTicks` + ') file=' + `file` + ' line=' + `line` + ' observers=' + (`store`.debugger.observers ? `store`.debugger.observers.length : 'N/A'));".}
  # Construct a NEW object — on JS backend, var = signal.val gets a
  # reference, so mutating and writing back the same object doesn't
  # trigger the signal's equality check (it compares to itself).
  store.debugger.val = DebuggerState(
    rrTicks: rrTicks,
    location: Location(file: file, line: line),
    status: current.status,
    threadId: current.threadId,
  )

proc updateLocals*(store: ReplayDataStore;
                   variables: seq[Variable]) =
  ## Replace the store's locals signal with a new variable list.
  ## Used by legacy UI code to mirror locals responses into the
  ## ViewModel layer.
  let diagCount = variables.len
  when defined(js):
    {.emit: "console.error('[PIPELINE] updateLocals: setting ' + `diagCount` + ' variables');".}
  store.locals.locals.val = variables
  store.locals.loadingState.val = lsIdle

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
                             totalCount: uint64) =
  ## Replace the store's calltrace signals with new section data.
  ## Used by legacy UI code to mirror calltrace responses into the
  ## ViewModel layer.
  let diagOldCount = store.calltrace.lines.val.len
  let diagNewCount = lines.len
  let diagStoreId = store.storeId
  when defined(js):
    {.emit: "console.error('[PIPELINE] updateCalltraceSection: storeId=' + `diagStoreId` + ' setting ' + `diagNewCount` + ' lines (was ' + `diagOldCount` + '), startIndex=' + `startIndex` + ' totalCount=' + `totalCount`);".}
  store.calltrace.lines.val = lines
  store.calltrace.startLineIndex.val = startIndex
  store.calltrace.totalCallsCount.val = totalCount
  store.calltrace.loadingState.val = lsIdle

proc makeCallLine*(name: string; depth: int; rrTicks: uint64;
                   file: string = ""; line: int = 0;
                   hasChildren: bool = false; isExpanded: bool = false;
                   callKey: string = ""): CallLine =
  ## Convenience constructor for CallLine — avoids the need for callers
  ## to import store/types.
  CallLine(
    index: 0,
    name: name,
    depth: depth,
    rrTicks: rrTicks,
    location: Location(file: file, line: line),
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
  let args = %*{"direction": dirStr}
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
