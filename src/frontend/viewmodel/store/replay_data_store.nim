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

proc requestLocals*(store: ReplayDataStore; rrTicks: uint64) =
  ## Request locals/globals from the backend for the given rrTicks.
  ## Skipped if an identical request is already in flight.
  let key = "load-locals"
  let argsStr = $rrTicks
  if store.requestTracker.isDuplicate(key, argsStr):
    return

  store.requestTracker.markPending(key, argsStr)
  store.locals.loadingState.val = lsLoading

  let args = %*{"rrTicks": rrTicks}
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
