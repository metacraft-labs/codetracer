## backend/worker_backend.nim
##
## WorkerBackendService — a `BackendService` that speaks DAP over
## `postMessage` to a WebWorker hosting the `db-backend` WASM replay
## engine (CodeTracer-Embed-SDK.md §5, the "DAP over postMessage" edge of
## the architecture diagram).
##
## The transport is **injected**, not imported.  This module owns the
## protocol — sequence allocation, response correlation, event routing,
## teardown — and knows nothing about how bytes reach the worker.  The
## same reasons apply as for `real_backend.nim`: it keeps the module free
## of a JS-only dependency so the protocol logic is testable on the C
## backend, and it keeps `std/jsffi` out of the SDK import graph except
## where a real `Worker` is actually constructed.
##
## Wire format, as implemented by `src/db-backend/wasm-testing/worker.js`
## and `src/db-backend/src/dap.rs:setup_onmessage_callback`:
##
## * **main → worker** is a structured-clone *object*:
##   `{seq, type: "request", command, arguments}`.  The Rust side does
##   `JSON.stringify(event.data)` on it (`dap.rs:545`).
## * **worker → main** is a JSON *string* for DAP traffic — `dap.rs:570`
##   posts `JsValue::from_str(&json)` — but a plain *object* for the
##   worker's own bootstrap messages (`wasm-loaded`, `vfs-ack`,
##   `trace-loaded`, `worker-error`), and the bare string `"ready"` from
##   `wasm_start()` (`lib.rs:299`).
##
## That asymmetry is the transport's to absorb: `deliver` takes the raw
## payload already rendered as text, and classifies it here.
##
## **Before wiring a ViewModel to this adapter, read `dap_dialect.md` in this
## directory.** The transport is sound — `ci/test/worker-backend-wasm-e2e.sh`
## proves 19 checks against the real engine — but the ViewModel layer and the
## engine disagree about the protocol in eight places, four of which trap the
## WASM worker outright. In particular the handshake order
## `sdk/debugger_session.nim` sends is the one the browser engine cannot
## accept: it answers all three requests `success: true` and then silently
## drops every request after them.
##
## Compiles on both backends (`nim js` and `nim c`).

import std/[json, tables, strutils]
import isonim/core/async_compat
import backend_service

type
  WorkerPostProc* = proc(messageJson: string)
    ## Hand one outbound message, rendered as JSON text, to the worker.
    ## The transport is responsible for parsing it back into an object
    ## before `postMessage` — the worker expects a structured-clone
    ## object, not a string.

  WorkerTerminateProc* = proc()
    ## Tear the underlying worker down.  Called once, by `disconnect`.

  WorkerBackendFailure* = enum
    ## The §6.3 error taxonomy, restricted to what this transport can
    ## actually distinguish.
    wbfNone
    wbfWorkerFailed      ## the worker errored or was torn down
    wbfDisconnected      ## `disconnect` was called by the consumer

  WorkerBackend* = ref object
    ## DAP-over-postMessage protocol driver.
    postProc: WorkerPostProc
    terminateProc: WorkerTerminateProc
    seqCounter: int
    pending: Table[int, proc(response: JsonNode)]
    pendingOrder: seq[int]
      ## Insertion order, so a teardown settles futures in the order the
      ## requests were made rather than in `Table` hash order.
    eventHandlers: seq[EventHandler]
    controlHandlers: seq[EventHandler]
    disconnected*: bool
    failure*: WorkerBackendFailure
    failureMessage*: string
    lastError*: string

const
  WorkerFailedMessagePrefix* = "worker backend failed: "
  DisconnectedMessage* = "worker backend disconnected"

# ---------------------------------------------------------------------------
# Construction
# ---------------------------------------------------------------------------

proc newWorkerBackend*(postProc: WorkerPostProc;
                       terminateProc: WorkerTerminateProc = nil): WorkerBackend =
  ## Create a protocol driver over an already-constructed worker.
  ##
  ## `postProc` must not be nil: a backend that cannot send is a
  ## programming error, and failing here names the mistake at the
  ## consumer's call site rather than at the first navigation
  ## (CodeTracer-Embed-SDK.md §5.1, "Failure must be legible").
  if postProc.isNil:
    raise newException(ValueError,
      "WorkerBackend requires a postProc; without one no request can reach the worker")
  WorkerBackend(
    postProc: postProc,
    terminateProc: terminateProc,
    seqCounter: 0,
    pending: initTable[int, proc(response: JsonNode)](),
    pendingOrder: @[],
    eventHandlers: @[],
    controlHandlers: @[],
    disconnected: false,
    failure: wbfNone,
    failureMessage: "",
    lastError: "")

proc pendingCount*(w: WorkerBackend): int =
  ## Number of requests awaiting a response.  Exposed for tests and for
  ## consumers that want to know whether a teardown would strand work.
  w.pendingOrder.len

# ---------------------------------------------------------------------------
# Outbound
# ---------------------------------------------------------------------------

proc settle(w: WorkerBackend; requestSeq: int; response: JsonNode): bool =
  ## Complete the future waiting on `requestSeq`, if any.
  if not w.pending.hasKey(requestSeq):
    return false
  let resolver = w.pending[requestSeq]
  w.pending.del(requestSeq)
  let idx = w.pendingOrder.find(requestSeq)
  if idx >= 0:
    w.pendingOrder.delete(idx)
  if not resolver.isNil:
    resolver(response)
  true

proc failedResponse(command: string; message: string): JsonNode =
  ## The shape `DebuggerSession.launch` and the ViewModels already check:
  ## a DAP response object carrying `success: false`.  Synthesising one
  ## rather than rejecting the promise means a stranded request is
  ## reported through the same path as a backend-refused one, instead of
  ## surfacing as an unhandled rejection the consumer never wrote.
  %*{
    "type": "response",
    "command": command,
    "success": false,
    "message": message,
    "body": newJObject(),
  }

proc send*(w: WorkerBackend; command: string; args: JsonNode): BackendFuture[JsonNode] =
  ## Send a DAP request and return a future for its response.
  ##
  ## A request made after `disconnect` resolves immediately with a
  ## `success: false` response rather than hanging forever — the failure
  ## mode this adapter exists to avoid.
  if w.disconnected or w.failure != wbfNone:
    let message =
      if w.failure == wbfWorkerFailed: WorkerFailedMessagePrefix & w.failureMessage
      else: DisconnectedMessage
    return newCompletedFuture[JsonNode](failedResponse(command, message))

  inc w.seqCounter
  let requestSeq = w.seqCounter
  let payload = %*{
    "seq": requestSeq,
    "type": "request",
    "command": command,
    "arguments": (if args.isNil: newJObject() else: args),
  }

  when defined(js):
    result = newPromise(proc(resolve: proc(response: JsonNode)) =
      w.pending[requestSeq] = resolve
      w.pendingOrder.add(requestSeq))
  else:
    let future = newFuture[JsonNode]("WorkerBackend.send")
    w.pending[requestSeq] = proc(response: JsonNode) =
      if not future.finished:
        future.complete(response)
    w.pendingOrder.add(requestSeq)
    result = future

  # Posting happens after the pending slot exists, so a transport that
  # delivers synchronously (every in-process test double, and a worker
  # shim that resolves from the same tick) cannot answer a request whose
  # future has not been registered yet.
  w.postProc($payload)

# ---------------------------------------------------------------------------
# Inbound
# ---------------------------------------------------------------------------

proc emitEvent(w: WorkerBackend; event: JsonNode) =
  for handler in w.eventHandlers:
    if not handler.isNil:
      handler(event)

proc emitControl(w: WorkerBackend; message: JsonNode) =
  for handler in w.controlHandlers:
    if not handler.isNil:
      handler(message)

proc failAllPending(w: WorkerBackend; message: string) =
  ## Settle every in-flight request with a failure response.  Called on
  ## worker death and on disconnect; without it each stranded future is a
  ## promise that never settles, which is exactly how a dropped DAP
  ## request presents to a ViewModel (a pane that spins forever).
  let stranded = w.pendingOrder
  w.pendingOrder = @[]
  for requestSeq in stranded:
    if w.pending.hasKey(requestSeq):
      let resolver = w.pending[requestSeq]
      w.pending.del(requestSeq)
      if not resolver.isNil:
        resolver(failedResponse("", message))

proc markWorkerFailed*(w: WorkerBackend; message: string) =
  ## Record that the worker died and strand nothing.
  if w.failure == wbfNone:
    w.failure = wbfWorkerFailed
  w.failureMessage = message
  w.lastError = message
  w.failAllPending(WorkerFailedMessagePrefix & message)

proc deliver*(w: WorkerBackend; raw: string) =
  ## Feed one inbound payload from the worker, rendered as text.
  ##
  ## Handles all three shapes the worker actually produces: a DAP JSON
  ## string, a bootstrap control object, and the bare `ready` token.
  let trimmed = raw.strip()
  if trimmed.len == 0:
    return

  if not (trimmed.startsWith("{") or trimmed.startsWith("[")):
    # `wasm_start()` posts the bare string "ready" (lib.rs:299).
    w.emitControl(%*{"type": "worker-status", "status": trimmed})
    return

  var message: JsonNode
  try:
    message = parseJson(trimmed)
  except CatchableError:
    w.emitControl(%*{"type": "worker-status", "status": trimmed})
    return

  if message.isNil or message.kind != JObject:
    return

  let messageType = message{"type"}.getStr("")

  case messageType
  of "response":
    let requestSeq = message{"request_seq"}.getInt(-1)
    if not w.settle(requestSeq, message):
      # A response for a request we never made, or one already settled by
      # a teardown.  Surfacing it as control traffic keeps it visible
      # instead of vanishing.
      w.emitControl(message)
  of "event":
    w.emitEvent(message)
  of "worker-error":
    let detail = message{"error"}.getStr("unknown worker error")
    w.emitControl(message)
    w.markWorkerFailed(detail)
  else:
    # Bootstrap traffic: wasm-loaded, vfs-ack, vfs-exists-result,
    # trace-loaded, trace-load-error.  Not DAP, so not an `onEvent`
    # event — the session lifecycle consumes these.
    w.emitControl(message)

# ---------------------------------------------------------------------------
# BackendService surface
# ---------------------------------------------------------------------------

proc onEvent*(w: WorkerBackend; handler: EventHandler) =
  if not handler.isNil:
    w.eventHandlers.add(handler)

proc onControl*(w: WorkerBackend; handler: EventHandler) =
  ## Register a handler for the worker's non-DAP bootstrap messages.
  ## Separate from `onEvent` because a `vfs-ack` is not a DAP event and
  ## must not reach `dapCommandToEventKind`.
  if not handler.isNil:
    w.controlHandlers.add(handler)

proc disconnect*(w: WorkerBackend) =
  ## Send DAP `disconnect`, strand nothing, then terminate the worker.
  ##
  ## Idempotent: a second call is a no-op, so a consumer that disposes a
  ## session twice does not double-terminate.
  if w.disconnected:
    return
  w.disconnected = true
  if w.failure == wbfNone:
    w.failure = wbfDisconnected
    # Best-effort: the worker may already be gone, and a transport that
    # throws on a dead worker must not prevent teardown.
    try:
      inc w.seqCounter
      w.postProc($(%*{
        "seq": w.seqCounter,
        "type": "request",
        "command": "disconnect",
        "arguments": newJObject(),
      }))
    except CatchableError:
      discard
  w.failAllPending(DisconnectedMessage)
  if not w.terminateProc.isNil:
    try:
      w.terminateProc()
    except CatchableError:
      discard

proc toBackendService*(w: WorkerBackend): BackendService =
  ## Adapt to the injectable `BackendService` the ViewModels consume.
  BackendService(
    sendProc: proc(command: string, args: JsonNode): BackendFuture[JsonNode] =
      w.send(command, args),
    onEventProc: proc(handler: EventHandler) =
      w.onEvent(handler),
    disconnectProc: proc() =
      w.disconnect())

proc newWorkerBackendService*(postProc: WorkerPostProc;
                              terminateProc: WorkerTerminateProc = nil): BackendService =
  ## Convenience: build the driver and adapt it in one step, for
  ## consumers that do not need the `WorkerBackend` handle.
  newWorkerBackend(postProc, terminateProc).toBackendService()
