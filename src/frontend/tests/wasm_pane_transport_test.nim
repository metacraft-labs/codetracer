## wasm_pane_transport_test.nim — the WebAssembly core's transport over the
## renderer's own `DapApi` (`web_core/renderer_transport.nim`).
##
## The wasm panes share the page's connection to the engine: their core's
## `WorkerBackendService` sends DAP text, the transport turns each request
## into a `DapApi.asyncSendCtRequest` and each answer and event back into DAP
## text. This suite drives the real `WorkerBackend` (the core's backend,
## compiled here with `nim js`), the real transport and the real `DapApi`
## send and delivery paths, and reads what reached the wire and what reached
## the core — including a `DebuggerSession` attached over it, whose position
## a move event must change.
##
## THE ONE STAND-IN: the `ipc` object's `send`, which records the request
## frame instead of writing it to the Backend Manager; the answers are written
## in the Backend Manager's shape and handed to `deliverDapResponse`, exactly
## as `ui_js.onDapReceiveResponse` does (the same stand-in, for the same
## reason, as `locals_answer_identity_test.nim`). Nothing in the code under
## test is replaced.
##
## Lane: `renderer-dom` (`nim js -d:ctRenderer`, run under jsdom). Without
## `-d:nodejs` `std/unittest` cannot set the exit status, so this suite does.

import std/[jsffi, asyncjs, json]

import ../types
import ../dap
import ../../common/ct_event
import ../web_core/renderer_transport
import ../viewmodel/backend/[backend_service, worker_backend]
import ../viewmodel/sdk/[debugger_session, trace_source]
import isonim/core/async_compat

var checks = 0
var failedChecks = 0
template ck(cond: untyped) =
  ## A plain check: the cases await the event loop, which `std/unittest`'s
  ## `test` bodies cannot.
  inc checks
  if not (cond):
    inc failedChecks
    echo "  [FAILED] ", astToStr(cond)

var sentPackets: seq[JsObject] = @[]
proc recordingIpc(): JsObject =
  let ipc = JsObject{}
  ipc.send = proc(channel: cstring, packet: JsObject) =
    sentPackets.add(packet)
  ipc

proc settle(): Future[void] =
  newPromise proc(resolve: proc()) =
    {.emit: "setTimeout(`resolve`, 0);".}

proc callSend(t: JsObject; text: cstring) {.importjs: "#.send(#)".}
proc callOnMessage(t: JsObject; cb: proc(text: cstring)) {.importjs: "#.onMessage(#)".}

proc main() {.async.} =
  let dapApi = DapApi(ipc: recordingIpc(), seq: 0, sessionId: 7)
  let transport = newWasmPaneTransport(dapApi)
  let worker = newWorkerBackend(proc(messageJson: string) =
    transport.callSend(cstring(messageJson)))
  transport.callOnMessage(proc(text: cstring) = worker.deliver($text))
  let backend = worker.toBackendService()

  echo "[Suite] a request from the core"
  echo "  case: reaches the renderer's DapApi with its command and arguments"
  sentPackets.setLen(0)
  var answered: JsonNode = nil
  onComplete(backend.send("ct/load-locals", %*{"rrTicks": 42, "countBudget": 3000}),
    onSuccess = proc(r: JsonNode) = answered = r,
    onError = proc(m: string) = discard)
  ck sentPackets.len == 1
  let packet = sentPackets[0]
  ck packet["command"].to(cstring) == cstring"ct/load-locals"
  ck packet["arguments"]["rrTicks"].to(int) == 42
  ck packet["sessionId"].to(int) == 7

  echo "[Suite] the answer"
  echo "  case: comes back to the core's own request, with its body"
  sentPackets.setLen(0)
  var reply: JsonNode = nil
  onComplete(backend.send("ct/load-locals", %*{"rrTicks": 5}),
    onSuccess = proc(r: JsonNode) = reply = r,
    onError = proc(m: string) = discard)
  let seqOnWire = sentPackets[0]["seq"].to(int)
  let body = JsObject{}
  body["marker"] = 1234
  let frame = JsObject{}
  frame["type"] = cstring"response"
  frame["request_seq"] = seqOnWire
  frame["success"] = true
  frame["command"] = cstring"ct/load-locals"
  frame["body"] = body
  deliverDapResponse(dapApi, dapApi, frame)
  await settle()
  drainPlatformCallbacks()
  ck not reply.isNil
  ck responseBody(reply){"marker"}.getInt(0) == 1234

  echo "[Suite] an event"
  echo "  case: reaches the core under its DAP name, and moves an attached session"
  let session = newDebuggerSession(backend)
  session.followBackendMoves()
  session.attach(localFolderTrace("/recordings/example"))
  ck session.isReady
  let loc = JsObject{}
  loc["path"] = cstring"/src/main.py"
  loc["line"] = 17
  let move = JsObject{}
  move["location"] = loc
  dapApi.receiveEvent(cstring"ct/complete-move", move)
  await settle()
  drainPlatformCallbacks()
  ck session.position.line == 17
  ck session.position.file == "/src/main.py"

  if failedChecks > 0:
    {.emit: "process.exitCode = 1;".}
  echo "wasm_pane_transport_test: ", checks, " checks, ", failedChecks, " failed"

discard main()
