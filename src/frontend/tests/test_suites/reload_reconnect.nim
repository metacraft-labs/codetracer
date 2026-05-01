import
  std / [async, jsffi, sequtils, strutils],
  ../../index/[base_handlers, bootstrap_cache],
  ../../lib/jslib

# Headless harness: simulate two socket.io clients connecting in sequence and
# ensure IPC handlers rebind after reconnect. Keeps dependencies minimal so
# `nim js` can produce a test for `tester ui`.

type
  FakeClient = ref object
    socket: JsObject
    received: seq[string]

proc newFakeClient(): FakeClient =
  var c = FakeClient(received: @[])
  let sock = newJsObject()
  sock["on"] = proc(event: cstring, handler: JsObject) =
    sock[("h_" & $event).cstring] = handler
  sock["off"] = proc(event: cstring, handler: JsObject) =
    if not sock[("h_" & $event).cstring].isUndefined:
      sock[("h_" & $event).cstring] = undefined
  sock["emit"] = proc(event: cstring, value: cstring) =
    c.received.add($event & ":" & $value)
  c.socket = sock
  c

proc trigger(client: FakeClient, event: string, payload: JsObject = nil) =
  let key = ("h_" & event).cstring
  if not client.socket[key].isUndefined:
    let handler = client.socket[key]
    let handlerProc = jsAsFunction[proc(data: JsObject)](handler)
    handlerProc(payload)

proc assertOnlyNewSocketReceivesStarted() =
  var ipc = initFrontendIPC()
  var logs: seq[string] = @[]

  ipc.logRecorder = proc(msg: cstring) =
    logs.add($msg)

  let handler = functionAsJs(proc(sender: JsObject, data: JsObject): Future[void] {.async.} =
    return
  )
  ipc.on("CODETRACER::open-tab", handler)

  let first = newFakeClient()
  ipc.attachSocket(cast[WebSocket](first.socket))
  first.trigger("CODETRACER::open-tab", js{ "path": cstring"/foo" })
  ipc.emit("CODETRACER::started", "{\"ok\":true}")

  let second = newFakeClient()
  ipc.attachSocket(cast[WebSocket](second.socket))
  second.trigger("CODETRACER::open-tab", js{ "path": cstring"/bar" })
  ipc.emit("CODETRACER::started", "{\"ok\":true}")

  if second.received.len == 0:
    raiseAssert "second client did not receive emits after reconnect"
  if first.received.len > 1:
    raiseAssert "first client still receiving after detach"
  let firstStarted = first.received.countIt(it.startsWith("CODETRACER::started"))
  let secondStarted = second.received.countIt(it.startsWith("CODETRACER::started"))
  if firstStarted != 1 or secondStarted != 1:
    raiseAssert "started events not routed exclusively to latest socket"
  if logs.countIt(it == "ipc attach socket") != 2:
    raiseAssert "attach events were not logged twice"
  if logs.countIt(it == "ipc detach socket") < 1:
    raiseAssert "detach events were not logged at rebind time"

proc assertMidRequestDisconnectRecovers() =
  var ipc = initFrontendIPC()
  var handled: seq[string] = @[]

  let handler = functionAsJs(proc(_: JsObject, data: JsObject): Future[void] {.async.} =
    handled.add("request")
    if handled.len == 1:
      # simulate a disconnect while the handler is still running
      ipc.detachSocket()
      # emit should be safely dropped without a panic
      ipc.emit("CODETRACER::started", "{\"dropped\":true}")
  )
  ipc.on("CODETRACER::open-tab", handler)

  let first = newFakeClient()
  ipc.attachSocket(cast[WebSocket](first.socket))
  first.trigger("CODETRACER::open-tab", js{ "path": cstring"/first" })

  let second = newFakeClient()
  ipc.attachSocket(cast[WebSocket](second.socket))
  second.trigger("CODETRACER::open-tab", js{ "path": cstring"/second" })
  ipc.emit("CODETRACER::started", "{\"ok\":true}")

  if handled.len != 2:
    raiseAssert "handler was not invoked once per request across reconnect"
  let firstStarted = first.received.countIt(it.startsWith("CODETRACER::started"))
  let secondStarted = second.received.countIt(it.startsWith("CODETRACER::started"))
  if firstStarted != 0:
    raiseAssert "first socket received started after being detached"
  if secondStarted != 1:
    raiseAssert "second socket did not receive started after reconnect"

proc assertBootstrapReplayKeepsLatestState() =
  var payloads: seq[BootstrapPayload] = @[]
  upsertBootstrap(payloads, BootstrapPayload(
    id: cstring"CODETRACER::trace-loaded",
    payload: cstring"""{"trace":1}"""))
  upsertBootstrap(payloads, BootstrapPayload(
    id: cstring"CODETRACER::started",
    payload: cstring"{}"))
  upsertBootstrap(payloads, BootstrapPayload(
    id: cstring"CODETRACER::init",
    payload: cstring"""{"layout":1}"""))
  # simulate a later trace-load replacing the cached payload
  upsertBootstrap(payloads, BootstrapPayload(
    id: cstring"CODETRACER::trace-loaded",
    payload: cstring"""{"trace":2}"""))

  var ipc = initFrontendIPC()
  let client = newFakeClient()
  ipc.attachSocket(cast[WebSocket](client.socket))
  replayBootstrap(payloads, proc(id: cstring, payload: cstring) =
    ipc.emit(id, payload))

  if client.received.len != 3:
    raiseAssert "bootstrap replay did not emit all cached messages"
  if client.received[0] != "CODETRACER::started:{}":
    raiseAssert "started should lead the bootstrap replay"
  if client.received[1] != "CODETRACER::init:{\"layout\":1}":
    raiseAssert "init payload not replayed or ordered correctly"
  let traceMessages = client.received.filterIt(it.startsWith("CODETRACER::trace-loaded"))
  if traceMessages.len != 1 or traceMessages[0] != "CODETRACER::trace-loaded:{\"trace\":2}":
    raiseAssert "bootstrap replay did not keep the latest trace payload"

proc assertDapReceiveEventKeyedUpsert() =
  ## A reload-reconnect regression: distinct DAP events delivered over
  ## the same ``CODETRACER::dap-receive-event`` channel must not clobber
  ## one another in the bootstrap cache.  Without the ``key`` field the
  ## second payload would replace the first (both share the same id),
  ## so the reloaded client would only receive one of them.
  ##
  ## We also assert that re-recording the same DAP event upserts in
  ## place (latest payload wins) instead of accumulating duplicates.
  var payloads: seq[BootstrapPayload] = @[]
  upsertBootstrap(payloads, BootstrapPayload(
    id: cstring"CODETRACER::dap-receive-event",
    key: cstring"ct/complete-move",
    payload: cstring"""{"event":"ct/complete-move","body":{"loc":1}}"""))
  upsertBootstrap(payloads, BootstrapPayload(
    id: cstring"CODETRACER::dap-receive-event",
    key: cstring"ct/updated-events",
    payload: cstring"""{"event":"ct/updated-events","body":[]}"""))
  # A new ct/complete-move arrives with an updated location: it must
  # replace the previous payload, not append.
  upsertBootstrap(payloads, BootstrapPayload(
    id: cstring"CODETRACER::dap-receive-event",
    key: cstring"ct/complete-move",
    payload: cstring"""{"event":"ct/complete-move","body":{"loc":2}}"""))

  if payloads.len != 2:
    raiseAssert "keyed upsert should keep one payload per (id, key) tuple"

  var ipc = initFrontendIPC()
  let client = newFakeClient()
  ipc.attachSocket(cast[WebSocket](client.socket))
  replayBootstrap(payloads, proc(id: cstring, payload: cstring) =
    ipc.emit(id, payload))

  if client.received.len != 2:
    raiseAssert "both keyed dap-receive-event payloads should replay"
  let dapMessages = client.received.filterIt(it.startsWith("CODETRACER::dap-receive-event"))
  if dapMessages.len != 2:
    raiseAssert "expected both dap-receive-event payloads to be emitted"
  let completeMoveMessages = dapMessages.filterIt(it.contains("ct/complete-move"))
  if completeMoveMessages.len != 1:
    raiseAssert "ct/complete-move replay should be deduplicated to the latest payload"
  if not completeMoveMessages[0].contains("\"loc\":2"):
    raiseAssert "ct/complete-move replay should carry the latest payload, not the stale one"

proc run*() =
  assertOnlyNewSocketReceivesStarted()
  assertMidRequestDisconnectRecovers()
  assertBootstrapReplayKeepsLatestState()
  assertDapReceiveEventKeyedUpsert()

run()
