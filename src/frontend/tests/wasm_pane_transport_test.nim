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
    echo "    check failed: ", astToStr(cond)

# Each case reports itself in the lane runner's tally: `[OK] <case>` or
# `[FAILED] <case>` once it ends (the shape `locals_answer_identity_test.nim`
# uses, for the same reason). Without them the runner sees no result line
# and scores the file DID NOT RUN however its checks came out.
var caseName = ""
var caseFailuresBefore = 0
var caseOpen = false
proc endCase() =
  if caseOpen:
    caseOpen = false
    echo (if failedChecks == caseFailuresBefore: "  [OK] " else: "  [FAILED] ") &
         caseName
proc beginCase(name: string) =
  endCase()
  caseName = name
  caseFailuresBefore = failedChecks
  caseOpen = true

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
  beginCase("reaches the renderer's DapApi with its command and arguments")
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
  beginCase("comes back to the core's own request, with its body")
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
  ck responseSucceeded(reply)
  ck responseBody(reply){"marker"}.getInt(0) == 1234

  echo "[Suite] a refusal"
  beginCase("reaches the core as a failed response, with the engine's message")
  sentPackets.setLen(0)
  var refused: JsonNode = nil
  onComplete(backend.send("ct/load-locals", %*{"rrTicks": 9}),
    onSuccess = proc(r: JsonNode) = refused = r,
    onError = proc(m: string) = discard)
  let refusedSeq = sentPackets[0]["seq"].to(int)
  let refusal = JsObject{}
  refusal["type"] = cstring"response"
  refusal["request_seq"] = refusedSeq
  refusal["success"] = false
  refusal["command"] = cstring"ct/load-locals"
  refusal["message"] = cstring"no replay for this tab"
  refusal["body"] = JsObject{}
  deliverDapResponse(dapApi, dapApi, refusal)
  await settle()
  drainPlatformCallbacks()
  ck not refused.isNil
  ck not responseSucceeded(refused)
  ck refused{"message"}.getStr == "no replay for this tab"

  echo "[Suite] an event"
  beginCase("reaches the core under its DAP name, and moves an attached session")
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

  echo "[Suite] two tabs"
  beginCase("each tab's panes are its own core's, over its own connection")
  # The panes' host (`web_core_panels.js`) as the renderer loads it, over a
  # stand-in core and core host that record which transport each core was
  # booted with and which presses reached it — the wasm module itself is
  # `web-core-browser.sh`'s subject, not this suite's.
  let dapA = DapApi(ipc: recordingIpc(), seq: 0, sessionId: 1)
  let dapB = DapApi(ipc: recordingIpc(), seq: 0, sessionId: 2)
  let tabA = JsObject{}
  let tabB = JsObject{}
  installWasmPaneTransport(dapA, tabA)
  installWasmPaneTransport(dapB, tabB)
  installWasmPaneTransport(dapA, tabA)   # a tab whose ViewModels are replaced
  var sameTransport, distinctTransports, firstIsDefault: bool
  {.emit: [sameTransport, " = ", tabA, ".ctwTransport === ", dapA, ".ctwTransport;",
           distinctTransports, " = ", tabA, ".ctwTransport !== ", tabB, ".ctwTransport;",
           firstIsDefault, " = globalThis.ctwRendererTransport === ", tabA, ".ctwTransport;"].}
  ck sameTransport
  ck distinctTransports
  ck firstIsDefault
  {.emit: """
  globalThis.__ctwBoots = [];
  globalThis.ctwModule = async () => ({});
  globalThis.CtWebCoreHost = { startWebCore(opts) {
    const panes = {};
    const h = { transport: opts.transport, presses: [],
      attach() {}, mountPane(n) {},
      paneElement(n) {
        if (!panes[n]) { panes[n] = document.createElement('div');
          panes[n].className = 'ct-web-core-pane'; opts.mount.appendChild(panes[n]); }
        return panes[n]; },
      press(op, el) { h.presses.push(op); return true; } };
    globalThis.__ctwBoots.push(h);
    return h; } };
  require(globalThis.ctRepoRoot + '/src/frontend/web_core/web_core_panels.js');
  """.}
  var hostA1, hostA2, hostB: JsObject
  {.emit: """
  `hostA1` = document.createElement('div'); `hostA2` = document.createElement('div');
  `hostB` = document.createElement('div');
  document.body.append(`hostA1`, `hostA2`, `hostB`);
  globalThis.ctwPanels.mount('state', `hostA1`, `tabA`);
  globalThis.ctwPanels.mount('calltrace', `hostA2`, `tabA`);
  globalThis.ctwPanels.mount('state', `hostB`, `tabB`);
  """.}
  await settle()
  await settle()
  var boots, aBootedOnA, bBootedOnB, placed, routed: bool
  {.emit: """
  const b = globalThis.__ctwBoots;
  `boots` = b.length === 2;
  `aBootedOnA` = b.length === 2 && b[0].transport === `tabA`.ctwTransport;
  `bBootedOnB` = b.length === 2 && b[1].transport === `tabB`.ctwTransport;
  `placed` = !!`hostA1`.firstChild && !!`hostA2`.firstChild && !!`hostB`.firstChild &&
             `hostA1`.firstChild !== `hostB`.firstChild;
  const pb = `hostB`.firstChild;
  `routed` = globalThis.ctwPanels.owns(pb) && globalThis.ctwPanels.press('expand', pb) &&
             b.length === 2 && b[1].presses.length === 1 && b[0].presses.length === 0;
  """.}
  ck boots
  ck aBootedOnA
  ck bBootedOnB
  ck placed
  ck routed

  endCase()
  echo "CHECKS: ", checks
  if failedChecks > 0:
    {.emit: "process.exitCode = 1;".}
  echo "wasm_pane_transport_test: ", checks, " checks, ", failedChecks, " failed"

discard main()
