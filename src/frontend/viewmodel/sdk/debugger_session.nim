## sdk/debugger_session.nim
##
## `DebuggerSession` — the Embed SDK's unit of "a debugger over a trace".
##
## CodeTracer-Embed-SDK.md §3.1 lists "Session lifecycle: create, launch a
## trace, dispose; multi-session in one page" and §6 names the type. This
## module is that type, and it is deliberately **transport-agnostic**: it is
## built over a `BackendService`, which §3.1 defines as the *injectable*
## transport. A session that knew it was talking to a worker — or to a
## spawned `replay-server` — would have collapsed the seam the SDK exists to
## keep open.
##
## What it owns:
##
##   * the ViewModel graph for one trace (`AppViewModel` -> `SessionViewModel`
##     -> `ReplayDataStore` + the panel VMs);
##   * the launch handshake and its typed failures (§6.3);
##   * navigation state that is not per-panel: position, granularity and the
##     history of where the session has been.
##
## What it deliberately does not own: rendering, layout, a chain concept of
## any kind (§3.2). It does not know what a trace *is about*.
##
## Multi-session: nothing here is global. Two `DebuggerSession`s over two
## backends are two independent ViewModel graphs, and `sessionCount` exists so
## a test can prove that disposing one does not disturb the other.
##
## Works on both the C and JS backends.

import std/[json, options, strutils]

import isonim/core/[signals, clock, async_compat]
import isonim/viewmodel

import ../backend/backend_service
import ../app/app_vm
import ../session_vm
import ../store/[replay_data_store, types]
import trace_source

type
  DebuggerSessionErrorKind* = enum
    ## The enumerable error taxonomy of CodeTracer-Embed-SDK.md §6.3.
    ##
    ## The point of the enum is that a consumer can tell "this trace does not
    ## exist" from "the worker died" without matching on message strings. The
    ## string values are the names the spec uses, so a JS facade can surface
    ## them unchanged.
    dseTraceUnavailable = "TraceUnavailable"
      ## The container could not be reached or does not exist.
    dseTraceCorrupt = "TraceCorrupt"
      ## The container was reached but could not be read as a trace.
    dseUnsupportedTraceKind = "UnsupportedTraceKind"
      ## The engine cannot read this container's format or version. §7:
      ## "The trace-format version the SDK can read is declared and checked
      ## at launch".
    dseWorkerFailed = "WorkerFailed"
      ## The transport itself failed — the worker could not be constructed,
      ## or died.
    dseCancelled = "Cancelled"
      ## The operation was abandoned, typically because the session was
      ## disposed while a launch was in flight.
    dseBackendError = "BackendError"
      ## The backend answered, and the answer was a failure that is none of
      ## the above.

  DebuggerSessionError* = object of CatchableError
    ## A typed session failure. Carries the taxonomy value so consumers
    ## branch on `err.kind`, never on `err.msg`.
    kind*: DebuggerSessionErrorKind

  DebuggerSessionPhase* = enum
    ## Lifecycle, as a single enum rather than a set of booleans, so an
    ## illegal combination cannot be represented.
    dspCreated
      ## The shared store exists and nothing has been sent. The panel VMs are
      ## NOT yet constructed: `session_vm.initializePanelViewModels` is
      ## deliberately separate from `createSessionVM` because several panel
      ## VMs own effects that issue backend requests, and a request before a
      ## trace is open is answered by an engine in the wrong state. `launch`
      ## and `attach` are what wake them.
    dspLaunching
      ## A launch is in flight.
    dspReady
      ## A trace is open and navigable.
    dspFailed
      ## The launch failed; `failure` says how.
    dspDisposed
      ## Torn down. Every action is a no-op from here.

  NavigationGranularity* = enum
    ## What one step means. The string values are the DAP `granularity`
    ## argument spellings the replay engine understands.
    ngLine = "line"
    ngStatement = "statement"
    ngInstruction = "instruction"

  NavigationEntry* = object
    ## One position the session has occupied.
    rrTicks*: uint64
    location*: Location
    reason*: string
      ## Why the session moved here ("launch", "step", "goto"). Free text:
      ## it is for a consumer's breadcrumb UI, not for branching on.

  DebuggerSession* = ref object of ViewModel
    ## One debugger over one trace.
    id*: int
      ## Per-process identity, for diagnostics and for proving that two
      ## sessions really are two.
    backend*: BackendService
      ## The injected transport (§3.1). The session never constructs one.
    app*: AppViewModel
      ## The ViewModel graph this session owns.
    trace*: TraceSource
      ## What was launched, or an unset source before `launch`.
    clock*: ClockBase
      ## Injected clock (§3.1). A consumer's deterministic test passes a
      ## `TestClock`; production passes `newRealClock()`.
    phase*: Signal[DebuggerSessionPhase]
    failure*: Signal[Option[DebuggerSessionErrorKind]]
      ## Set alongside `dspFailed`. A signal rather than an exception so a
      ## consumer can render a failed session instead of catching around
      ## every call.
    failureMessage*: Signal[string]
    granularity*: Signal[NavigationGranularity]
    history*: Signal[seq[NavigationEntry]]
    historyLimit*: int
      ## Cap on `history`, so a long session does not grow without bound.

const
  DefaultHistoryLimit* = 512

var sessionIdCounter {.global.}: int = 0

# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------

proc newDebuggerSessionError*(kind: DebuggerSessionErrorKind;
                              msg: string): ref DebuggerSessionError =
  ## Build a typed session error. `msg` is for humans; `kind` is for code.
  result = newException(DebuggerSessionError, $kind & ": " & msg)
  result.kind = kind

proc classifyBackendFailure*(response: JsonNode): DebuggerSessionErrorKind =
  ## Map a failed DAP response onto the §6.3 taxonomy.
  ##
  ## The engine does not (yet) send a machine-readable failure class, so
  ## this reads the message. That is exactly the string matching §6.3 says
  ## consumers must not have to do — which is the point: it happens **once,
  ## here**, and every consumer downstream branches on the enum. When the
  ## engine grows a typed code, only this proc changes.
  if response.isNil or response.kind != JObject:
    return dseBackendError
  var message = ""
  if response.hasKey("message"):
    message = response["message"].getStr("")
  if message.len == 0 and response.hasKey("body"):
    let body = response["body"]
    if body.kind == JObject and body.hasKey("error"):
      message = $body["error"]
  let lowered = message.toLowerAscii()
  if lowered.len == 0:
    return dseBackendError
  # Ordered most-specific first: "unsupported trace format" must not be read
  # as "not found" merely because both mention the trace.
  if lowered.contains("unsupported") or lowered.contains("version"):
    dseUnsupportedTraceKind
  elif lowered.contains("corrupt") or lowered.contains("malformed") or
       lowered.contains("parse"):
    dseTraceCorrupt
  elif lowered.contains("not found") or lowered.contains("no such") or
       lowered.contains("does not exist") or lowered.contains("unavailable"):
    dseTraceUnavailable
  else:
    dseBackendError

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

proc unsetTraceSource(): TraceSource =
  ## The `trace` value of a session that has not launched. An empty
  ## local-folder rather than an `Option[TraceSource]` so that reading
  ## `session.trace.kind` never has to unwrap; `isValid` is false for it,
  ## which is the honest answer.
  TraceSource(kind: tskLocalFolder, folder: "")

proc newDebuggerSession*(backend: BackendService;
                         clock: ClockBase = nil;
                         historyLimit: int = DefaultHistoryLimit): DebuggerSession =
  ## Create a session over `backend`: the shared `ReplayDataStore` exists,
  ## no trace is open, and the panel ViewModels are not yet constructed.
  ##
  ## Construction is passive: it sends nothing. That mirrors
  ## `createSessionVM`'s contract — the panel VMs own effects that issue
  ## backend requests, so they are woken by `launch`/`attach`, not here. It is
  ## what makes it safe for a consumer to build the graph before it knows
  ## which trace it wants: the "create" half of §3.1's "create, launch a
  ## trace, dispose".
  doAssert not backend.isNil, "DebuggerSession requires a BackendService"
  withViewModel proc(dispose: proc()): DebuggerSession =
    inc sessionIdCounter
    DebuggerSession(
      id: sessionIdCounter,
      backend: backend,
      app: createAppViewModel(backend, initializePanels = false),
      trace: unsetTraceSource(),
      clock: (if clock.isNil: ClockBase(newRealClock()) else: clock),
      phase: createSignal(dspCreated),
      failure: createSignal(none(DebuggerSessionErrorKind)),
      failureMessage: createSignal(""),
      granularity: createSignal(ngLine),
      history: createSignal(newSeq[NavigationEntry]()),
      historyLimit: (if historyLimit > 0: historyLimit else: DefaultHistoryLimit),
      disposeProc: dispose,
    )

proc session*(s: DebuggerSession): SessionViewModel =
  ## The panel ViewModels and the shared store for this session.
  s.app.session

proc store*(s: DebuggerSession): ReplayDataStore =
  ## The reactive trace data layer (§3.1, `ReplayDataStore`).
  s.app.session.store

proc sessionCount*(): int =
  ## How many sessions this process has created since it started. A
  ## monotonic diagnostic counter, not a live count of open sessions — it
  ## does not go down on `dispose`.
  sessionIdCounter

# ---------------------------------------------------------------------------
# Navigation state
# ---------------------------------------------------------------------------

proc position*(s: DebuggerSession): Location =
  ## Where the session currently is.
  s.store.debugger.val.location

proc rrTicks*(s: DebuggerSession): uint64 =
  ## The current time coordinate.
  s.store.debugger.val.rrTicks

proc setGranularity*(s: DebuggerSession; g: NavigationGranularity) =
  ## Choose what one step means for subsequent navigation.
  if s.phase.val == dspDisposed:
    return
  s.granularity.val = g

proc recordPosition*(s: DebuggerSession; reason: string) =
  ## Append the store's current position to the navigation history.
  ##
  ## Public because the *host* owns event delivery: with the native stdio
  ## transport the position arrives on a `ct/complete-move` event that the
  ## harness consumes directly, so the session cannot observe the move by
  ## itself. Rather than have the session guess, whoever applied the move
  ## says so.
  if s.phase.val == dspDisposed:
    return
  let dbg = s.store.debugger.val
  var entries = s.history.val
  if entries.len > 0 and entries[^1].rrTicks == dbg.rrTicks and
     entries[^1].location == dbg.location:
    return  # No movement: do not grow the history with duplicates.
  entries.add(NavigationEntry(
    rrTicks: dbg.rrTicks, location: dbg.location, reason: reason))
  if entries.len > s.historyLimit:
    # Drop the oldest entries. `seq` has no slice-delete, so re-slice.
    entries = entries[(entries.len - s.historyLimit) .. ^1]
  s.history.val = entries

# ---------------------------------------------------------------------------
# Lifecycle
# ---------------------------------------------------------------------------

proc failWith(s: DebuggerSession; kind: DebuggerSessionErrorKind;
              msg: string) =
  s.failure.val = some(kind)
  s.failureMessage.val = msg
  s.phase.val = dspFailed

proc markReady(s: DebuggerSession; trace: TraceSource) =
  s.trace = trace
  s.failure.val = none(DebuggerSessionErrorKind)
  s.failureMessage.val = ""
  s.phase.val = dspReady
  # Only now do the panels start asking the backend for data. Before a trace
  # is open there is nothing to ask about, and a request sent then is answered
  # by an engine in the wrong state.
  s.app.session.initializePanelViewModels()
  s.recordPosition("launch")

proc attach*(s: DebuggerSession; trace: TraceSource) =
  ## Adopt a trace that some other code already launched on this transport.
  ##
  ## The native headless harness performs its own DAP handshake, because it
  ## needs blocking `waitForEvent` semantics that `BackendService` does not
  ## expose (its `onEvent` is a registration, not a pump). `attach` is how
  ## that harness still gets its lifecycle, its phase and its history from
  ## the SDK instead of keeping a second copy — the seam bends rather than
  ## forking.
  if s.phase.val == dspDisposed:
    return
  s.markReady(trace)

proc launch*(s: DebuggerSession; trace: TraceSource;
             clientId: string = "codetracer-embed") =
  ## Open `trace` on this session's backend and, on success, move to
  ## `dspReady`.
  ##
  ## The handshake is the DAP one the replay engine expects: `initialize`,
  ## `configurationDone`, `launch`. It is driven through `BackendService`,
  ## so a mock, a worker and a spawned process are all launched by the same
  ## code path — which is what makes `MockBackendService` a real test of the
  ## lifecycle rather than a test of a parallel implementation.
  ##
  ## Failure never escapes as an untyped exception: it lands in `failure`
  ## and `phase`. A caller that prefers an exception calls `raiseIfFailed`.
  if s.phase.val == dspDisposed:
    raise newDebuggerSessionError(dseCancelled,
      "launch on a disposed session")
  trace.validate()
  s.phase.val = dspLaunching
  s.failure.val = none(DebuggerSessionErrorKind)
  s.failureMessage.val = ""

  # Each step is fire-and-inspect: with every transport in this repo the
  # future is already completed by the time `send` returns (the stdio one
  # blocks; the mock is synchronous). A genuinely async transport resolves
  # the same callbacks later, and the phase signal is what the consumer
  # watches.
  #
  # WHAT "ALREADY COMPLETED" DOES *NOT* IMPLY, and it cost this proc its
  # correctness on one backend: that `onComplete` runs the callback inline.
  # It does on the C backend. On the **JS** backend it does not —
  # `nim_everywhere/async_compat.onComplete` pushes even a
  # synchronously-resolved future's callback onto `pendingCallbacks`, to be
  # run by `drainPlatformCallbacks`. So `handshakeFailed` was still false
  # when the check below ran, and a launch the backend had answered
  # `success: false` was reported as `dspReady` with `failure` empty. The
  # whole §6.3 error taxonomy was inert on the backend BlockTracer ships,
  # and no suite could see it: `test_sdk_facade.nim` imported `std/osproc`
  # and therefore could not compile under `nim js` at all
  # (BlockTracer.milestones.org M2b, "Tier 1 runs on the C backend only").
  #
  # The drain below is what makes the two backends agree. It is the same
  # primitive `headless_session.drain` already uses, and on native it is a
  # `poll(0)` that costs nothing when there is nothing queued.
  var handshakeFailed = false

  proc step(command: string; args: JsonNode) =
    if handshakeFailed:
      return
    onComplete(s.backend.send(command, args),
      onSuccess = proc(response: JsonNode) =
        # A DAP response with `success: false` is a failure even though the
        # future succeeded. Missing `success` is treated as success: the
        # stdio transport's `configurationDone` answers with a bare object.
        if not response.isNil and response.kind == JObject and
           response.hasKey("success") and
           not response["success"].getBool(false):
          handshakeFailed = true
          s.failWith(classifyBackendFailure(response),
            command & " failed: " & $response),
      onError = proc(msg: string) =
        handshakeFailed = true
        s.failWith(dseWorkerFailed, command & " transport error: " & msg))
    # Drained per step, not once at the end, so the short-circuit above
    # behaves the same on both backends: a queued-callback backend would
    # otherwise send all three commands to a backend that had already
    # refused the first, and `failWith` would report the LAST failure rather
    # than the one that actually stopped the handshake.
    drainPlatformCallbacks()

  step("initialize", %*{
    "clientID": clientId,
    "adapterID": "codetracer",
    "supportsProgressReporting": false,
  })
  step("configurationDone", %*{})
  step("launch", trace.toLaunchArgs())

  if not handshakeFailed and s.phase.val == dspLaunching:
    s.markReady(trace)

proc raiseIfFailed*(s: DebuggerSession) =
  ## Raise the typed error for a failed session. For consumers that want
  ## exceptions; the signals are the primary surface.
  let f = s.failure.val
  if f.isSome:
    raise newDebuggerSessionError(f.get, s.failureMessage.val)

proc isReady*(s: DebuggerSession): bool =
  s.phase.val == dspReady

proc isDisposed*(s: DebuggerSession): bool =
  s.phase.val == dspDisposed

proc dispose*(s: DebuggerSession; disconnectBackend: bool = true) =
  ## Tear the session down: dispose the ViewModel graph, disconnect the
  ## transport, release the reactive root.
  ##
  ## Idempotent, because a consumer's component teardown may run twice and
  ## the second run must not fault. Disposing one session must not touch
  ## another: nothing here is global except the id counter.
  ##
  ## `disconnectBackend = false` is for a host that owns the transport's
  ## lifetime itself — the native headless harness kills its `replay-server`
  ## child directly, and a second teardown through `BackendService.disconnect`
  ## would close the same process handle twice.
  if s.isNil or s.phase.val == dspDisposed:
    return
  s.phase.val = dspDisposed
  if not s.app.isNil:
    # The flag has to be forwarded, not merely honoured on the line below:
    # `AppViewModel.dispose` reaches `SessionViewModel.dispose`, which used
    # to disconnect unconditionally. That made this proc's `false` case a
    # no-op in practice and gave `HeadlessDebugSession.close` the exact
    # double `DapStdioBackend.close` its own comment says it is avoiding.
    s.app.dispose(disconnectBackend = disconnectBackend)
  if disconnectBackend and not s.backend.isNil:
    s.backend.disconnect()
  ViewModel(s).dispose()
