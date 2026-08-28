## test_worker_backend.nim
##
## Protocol tests for `WorkerBackendService` — the DAP-over-postMessage
## adapter (CodeTracer-Embed-SDK.md §5).
##
## These drive the adapter against an in-process transport double so the
## correlation, routing and teardown logic is checked on *both* backends.
## They are deliberately not a substitute for the real-engine proof: the
## adapter is also run against the actual `db-backend` WASM worker by
## `ci/test/worker-backend-wasm-e2e.sh`, which fails when the WASM is
## absent rather than skipping.
##
##   nim c -r --path:src/frontend/viewmodel src/frontend/viewmodel/tests/unit/test_worker_backend.nim
##   nim js -d:nodejs -r --path:src/frontend/viewmodel src/frontend/viewmodel/tests/unit/test_worker_backend.nim

import std/[json, strutils, unittest]
import isonim/core/async_compat
import backend/[backend_service, worker_backend]

type
  Slot = ref object
    ## A mutable cell a callback can write into. `JsonNode` is itself a
    ## ref, so `new(JsonNode)` would not give us an assignable slot.
    value: JsonNode

  Transport = ref object
    ## Records what crossed the boundary, and lets a test answer.
    sent: seq[JsonNode]
    terminated: int
    throwOnPost: bool

proc newTransport(): Transport =
  Transport(sent: @[], terminated: 0, throwOnPost: false)

proc attach(t: Transport): WorkerBackend =
  newWorkerBackend(
    postProc = proc(messageJson: string) =
      if t.throwOnPost:
        raise newException(ValueError, "worker is gone")
      t.sent.add(parseJson(messageJson)),
    terminateProc = proc() =
      inc t.terminated)

proc lastSent(t: Transport): JsonNode =
  check t.sent.len > 0
  t.sent[^1]

proc drain() =
  ## Flush the reactive layer. On JS `onComplete` never runs inline, so
  ## every assertion that reads a callback's effect must drain first.
  drainPlatformCallbacks()

# ---------------------------------------------------------------------------
# Awaiting a real transport
#
# `drainPlatformCallbacks()` is NOT sufficient to observe a future that this
# adapter resolves. On JS, `async_compat.onComplete` only routes through
# `pendingCallbacks` for futures tagged `__syncResolved` — i.e. those built by
# `newCompletedFuture`. A future created by `newPromise` and resolved later,
# which is what any genuinely asynchronous transport produces, is observed via
# a real `.then` microtask that a synchronous drain cannot pump.
#
# This is a property of the platform, not a defect in the adapter, and it is
# why the tests below yield a turn before asserting.
# ---------------------------------------------------------------------------

when defined(js):
  proc microtask(): Future[void] {.importjs: "Promise.resolve()".}
else:
  proc microtask(): Future[void] =
    result = newFuture[void]("microtask")
    result.complete()

proc settleTurn(): Future[void] {.async.} =
  ## Yield long enough for a resolved promise to deliver, then flush.
  await microtask()
  drain()

proc newSlot(): Slot = Slot(value: nil)

proc capture(fut: BackendFuture[JsonNode]; slot: Slot) =
  onComplete(fut,
    onSuccess = proc(response: JsonNode) = slot.value = response,
    onError = proc(message: string) = slot.value = %*{"transportError": message})

suite "WorkerBackendService — wire format":

  test "send posts a DAP request with an allocated sequence number":
    let t = newTransport()
    let w = t.attach()
    discard w.send("initialize", %*{"clientID": "test"})

    check t.sent.len == 1
    let msg = t.lastSent()
    check msg["type"].getStr == "request"
    check msg["command"].getStr == "initialize"
    check msg["arguments"]["clientID"].getStr == "test"
    check msg["seq"].getInt == 1

  test "sequence numbers are monotonic and distinct":
    let t = newTransport()
    let w = t.attach()
    discard w.send("stepIn", newJObject())
    discard w.send("stepOut", newJObject())
    discard w.send("next", newJObject())

    check t.sent.len == 3
    check t.sent[0]["seq"].getInt == 1
    check t.sent[1]["seq"].getInt == 2
    check t.sent[2]["seq"].getInt == 3

  test "a nil argument payload is sent as an empty object, not null":
    let t = newTransport()
    let w = t.attach()
    discard w.send("configurationDone", nil)
    check t.lastSent()["arguments"].kind == JObject

suite "WorkerBackendService — response correlation":




  test "a response for an unknown request_seq does not disturb pending work":
    let t = newTransport()
    let w = t.attach()
    let got = newSlot()
    capture(w.send("threads", newJObject()), got)

    w.deliver("""{"type":"response","request_seq":99,"command":"threads",
                  "success":true,"body":{}}""")
    drain()

    check got.value.isNil
    check w.pendingCount == 1

suite "WorkerBackendService — event routing":

  test "DAP events reach onEvent handlers and settle no futures":
    let t = newTransport()
    let w = t.attach()
    var events: seq[JsonNode] = @[]
    w.onEvent(proc(e: JsonNode) = events.add(e))

    let got = newSlot()
    capture(w.send("next", newJObject()), got)

    w.deliver("""{"type":"event","event":"stopped","body":{"reason":"step"}}""")
    drain()

    check events.len == 1
    check events[0]["event"].getStr == "stopped"
    check got.value.isNil
    check w.pendingCount == 1

  test "worker bootstrap messages are control traffic, not DAP events":
    # `vfs-ack` must never reach `dapCommandToEventKind`.
    let t = newTransport()
    let w = t.attach()
    var events: seq[JsonNode] = @[]
    var control: seq[JsonNode] = @[]
    w.onEvent(proc(e: JsonNode) = events.add(e))
    w.onControl(proc(e: JsonNode) = control.add(e))

    w.deliver("""{"type":"wasm-loaded"}""")
    w.deliver("""{"type":"vfs-ack","path":"trace/trace.ct","ok":true}""")
    w.deliver("""{"type":"trace-loaded","files":[]}""")

    check events.len == 0
    check control.len == 3
    check control[1]["path"].getStr == "trace/trace.ct"

  test "the bare `ready` token is surfaced as worker status":
    # `wasm_start()` posts the string "ready", not JSON (lib.rs:299).
    let t = newTransport()
    let w = t.attach()
    var control: seq[JsonNode] = @[]
    w.onControl(proc(e: JsonNode) = control.add(e))

    w.deliver("ready")

    check control.len == 1
    check control[0]["type"].getStr == "worker-status"
    check control[0]["status"].getStr == "ready"

  test "multiple event handlers all fire":
    let t = newTransport()
    let w = t.attach()
    var a = 0
    var b = 0
    w.onEvent(proc(e: JsonNode) = inc a)
    w.onEvent(proc(e: JsonNode) = inc b)
    w.deliver("""{"type":"event","event":"ct/complete-move","body":{}}""")
    check a == 1
    check b == 1

suite "WorkerBackendService — failure and teardown":


  test "disconnect posts a DAP disconnect and terminates the worker":
    let t = newTransport()
    let w = t.attach()
    w.disconnect()

    check t.sent.len == 1
    check t.lastSent()["command"].getStr == "disconnect"
    check t.terminated == 1
    check w.disconnected

  test "disconnect is idempotent":
    let t = newTransport()
    let w = t.attach()
    w.disconnect()
    w.disconnect()
    w.disconnect()
    check t.terminated == 1


  test "a send after disconnect resolves with a failure instead of hanging":
    let t = newTransport()
    let w = t.attach()
    w.disconnect()

    let got = newSlot()
    capture(w.send("stepIn", newJObject()), got)
    drain()

    check not got.value.isNil
    check not got.value["success"].getBool
    check got.value["message"].getStr == DisconnectedMessage

  test "teardown survives a transport that throws on a dead worker":
    let t = newTransport()
    let w = t.attach()
    t.throwOnPost = true
    w.disconnect()
    check t.terminated == 1
    check w.disconnected

  test "constructing without a postProc is refused at the call site":
    expect ValueError:
      discard newWorkerBackend(nil)

suite "WorkerBackendService — BackendService conformance":

  test "the adapted service satisfies the three-proc contract":
    let t = newTransport()
    let w = t.attach()
    let service = w.toBackendService()

    check not service.sendProc.isNil
    check not service.onEventProc.isNil
    check not service.disconnectProc.isNil

  test "events registered through the service surface reach handlers":
    let t = newTransport()
    let w = t.attach()
    let service = w.toBackendService()
    var seen = 0
    service.onEvent(proc(e: JsonNode) = inc seen)
    w.deliver("""{"type":"event","event":"stopped","body":{}}""")
    check seen == 1


  test "disconnect through the service tears the worker down":
    let t = newTransport()
    let w = t.attach()
    let service = w.toBackendService()
    service.disconnect()
    check t.terminated == 1

# ---------------------------------------------------------------------------
# Future resolution, against a transport that answers asynchronously.
#
# These cannot live in a `unittest` `test` block: the block body is
# synchronous, and on JS the response arrives on a microtask. They report in
# the same `[OK]` / `[FAILED]` shape the lane runner counts, and force a
# non-zero exit on failure.
# ---------------------------------------------------------------------------

var asyncOk = 0
var asyncFailed = 0

proc report(name: string; ok: bool; detail = "") =
  if ok:
    inc asyncOk
    echo "  [OK] " & name
  else:
    inc asyncFailed
    echo "  [FAILED] " & name & (if detail.len > 0: " — " & detail else: "")

proc asyncSuite() {.async.} =
  echo ""
  echo "[Suite] WorkerBackendService — future resolution over an async transport"

  block:
    const name = "a response resolves the future for its own request_seq"
    let w = newTransport().attach()
    let got = newSlot()
    capture(w.send("stackTrace", newJObject()), got)
    let hadPending = w.pendingCount == 1
    w.deliver("""{"type":"response","request_seq":1,"command":"stackTrace",
                  "success":true,"body":{"totalFrames":1}}""")
    await settleTurn()
    report(name,
      hadPending and w.pendingCount == 0 and (not got.value.isNil) and
      got.value{"success"}.getBool and
      got.value{"body"}{"totalFrames"}.getInt == 1,
      "pending=" & $w.pendingCount & " value=" & (if got.value.isNil: "nil" else: $got.value))

  block:
    const name = "out-of-order responses reach the right futures"
    let w = newTransport().attach()
    let first = newSlot()
    let second = newSlot()
    capture(w.send("ct/load-locals", newJObject()), first)
    capture(w.send("ct/load-flow", newJObject()), second)
    # Answer the second request first — the engine is free to do this.
    w.deliver("""{"type":"response","request_seq":2,"command":"ct/load-flow",
                  "success":true,"body":{"which":"flow"}}""")
    await settleTurn()
    let secondOnly = (not second.value.isNil) and first.value.isNil and
                     second.value{"body"}{"which"}.getStr == "flow" and
                     w.pendingCount == 1
    w.deliver("""{"type":"response","request_seq":1,"command":"ct/load-locals",
                  "success":true,"body":{"which":"locals"}}""")
    await settleTurn()
    report(name,
      secondOnly and (not first.value.isNil) and
      first.value{"body"}{"which"}.getStr == "locals" and w.pendingCount == 0)

  block:
    # `DebuggerSession.launch` inspects `success` on the resolved value;
    # rejecting instead would route a refused launch through the
    # transport-error path and mislabel it.
    const name = "a success:false response resolves rather than rejects"
    let w = newTransport().attach()
    let got = newSlot()
    capture(w.send("launch", newJObject()), got)
    w.deliver("""{"type":"response","request_seq":1,"command":"launch",
                  "success":false,"message":"no such trace","body":{}}""")
    await settleTurn()
    report(name,
      (not got.value.isNil) and (not got.value{"success"}.getBool) and
      got.value{"message"}.getStr == "no such trace")

  block:
    const name = "a worker error strands no pending request"
    let w = newTransport().attach()
    let got = newSlot()
    capture(w.send("ct/load-locals", newJObject()), got)
    w.deliver("""{"type":"worker-error","error":"RuntimeError: unreachable"}""")
    await settleTurn()
    report(name,
      w.pendingCount == 0 and (not got.value.isNil) and
      (not got.value{"success"}.getBool) and
      got.value{"message"}.getStr.contains("unreachable") and
      w.failure == wbfWorkerFailed)

  block:
    const name = "disconnect settles in-flight requests instead of stranding them"
    let w = newTransport().attach()
    let got = newSlot()
    capture(w.send("ct/load-calltrace-section", newJObject()), got)
    let hadPending = w.pendingCount == 1
    w.disconnect()
    await settleTurn()
    report(name,
      hadPending and w.pendingCount == 0 and (not got.value.isNil) and
      (not got.value{"success"}.getBool))

  block:
    const name = "send through the BackendService surface correlates like the driver"
    let w = newTransport().attach()
    let service = w.toBackendService()
    let got = newSlot()
    capture(service.send("threads", newJObject()), got)
    w.deliver("""{"type":"response","request_seq":1,"command":"threads",
                  "success":true,"body":{"threads":[]}}""")
    await settleTurn()
    report(name, (not got.value.isNil) and got.value{"success"}.getBool)

  echo ""
  echo "async checks: " & $asyncOk & " passed, " & $asyncFailed & " failed"
  if asyncFailed > 0:
    quit(1)

when defined(js):
  discard asyncSuite()
else:
  waitFor asyncSuite()
