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

when defined(js):
  import std/asyncjs
else:
  import std/asyncdispatch

import isonim/core/[signals, owner]
import isonim/viewmodel

import ../backend/backend_service
import types, request_tracker

# ---------------------------------------------------------------------------
# Cross-platform future callback helper
# ---------------------------------------------------------------------------

proc onComplete(fut: BackendFuture[JsonNode];
                onSuccess: proc(); onError: proc()) =
  ## Register callbacks for future completion.
  ## Works on both the native (asyncdispatch) and JS (asyncjs) backends.
  when defined(js):
    proc success(v: JsonNode) = onSuccess()
    proc failure(e: Error) = onError()
    discard fut.then(success, failure)
  else:
    fut.addCallback proc() =
      {.cast(gcsafe).}:
        if fut.failed:
          onError()
        else:
          onSuccess()

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
    let store = ReplayDataStore(
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
                              depth: int) =
  ## Request a window of calltrace lines from the backend.
  ## Skipped if an identical request is already in flight.
  let key = "load-calltrace"
  let argsStr = $startIndex & "|" & $height & "|" & $depth
  if store.requestTracker.isDuplicate(key, argsStr):
    return

  store.requestTracker.markPending(key, argsStr)
  store.calltrace.loadingState.val = lsLoading

  let args = %*{
    "startIndex": startIndex,
    "height": height,
    "depth": depth,
  }
  let fut = store.backend.send("ct/load-calltrace", args)

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
  var dbg = store.debugger.val
  if dbg.rrTicks != rrTicks:
    dbg.rrTicks = rrTicks
    dbg.location = Location(file: file, line: line)
    store.debugger.val = dbg

proc updateLocals*(store: ReplayDataStore;
                   variables: seq[Variable]) =
  ## Replace the store's locals signal with a new variable list.
  ## Used by legacy UI code to mirror locals responses into the
  ## ViewModel layer.
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
  store.calltrace.lines.val = lines
  store.calltrace.startLineIndex.val = startIndex
  store.calltrace.totalCallsCount.val = totalCount
  store.calltrace.loadingState.val = lsIdle

proc makeCallLine*(name: string; depth: int; rrTicks: uint64;
                   file: string = ""; line: int = 0): CallLine =
  ## Convenience constructor for CallLine — avoids the need for callers
  ## to import store/types.
  CallLine(
    index: 0,
    name: name,
    depth: depth,
    rrTicks: rrTicks,
    location: Location(file: file, line: line),
  )

proc requestStep*(store: ReplayDataStore; direction: StepDirection) =
  ## Send a step command to the backend.
  ## Marks the debugger as stepping while the request is in flight.
  let key = "step"
  let dirStr = $direction
  if store.requestTracker.isDuplicate(key, dirStr):
    return

  store.requestTracker.markPending(key, dirStr)

  # Update debugger status to stepping.
  var dbg = store.debugger.val
  dbg.status = dsStepping
  store.debugger.val = dbg

  let args = %*{"direction": dirStr}
  let fut = store.backend.send("ct/step", args)

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
