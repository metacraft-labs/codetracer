import
  std / [unittest, tables],
  ../index/ipc_registry,
  ../lib/jslib,
  std/jsffi

type
  FakeSocket = ref object
    registered: Table[string, JsObject]
    removed: seq[string]
    obj: JsObject

proc newFakeSocket(): FakeSocket =
  var sock = FakeSocket(registered: initTable[string, JsObject](), removed: @[])
  let jsSock = newJsObject()
  jsSock["on"] = proc(event: cstring, handler: JsObject) =
    sock.registered[$event] = handler
  jsSock["off"] = proc(event: cstring, handler: JsObject) =
    sock.removed.add($event)
    if sock.registered.hasKey($event):
      sock.registered.del($event)
  sock.obj = jsSock
  sock

proc trigger(sock: FakeSocket, event: string, payload: JsObject = nil) =
  if sock.registered.hasKey(event):
    let handler = sock.registered[event]
    let handlerProc = jsAsFunction[proc(data: JsObject)](handler)
    handlerProc(payload)

suite "ipc registry":
  test "rebinds handlers to new socket and detaches old" :
    var registry = initIpcRegistry()
    let handler = newJsObject()

    registry.registerHandler("CODETRACER::open-tab", handler)

    let first = newFakeSocket()
    registry.attachSocket(first.obj)
    check first.registered["CODETRACER::open-tab"] == handler

    let second = newFakeSocket()
    registry.attachSocket(second.obj)

    check second.registered["CODETRACER::open-tab"] == handler
    check "CODETRACER::open-tab" in first.removed

  test "handlers still invoked after reconnect" :
    var registry = initIpcRegistry()
    var firstHit = false
    var secondHit = false
    let handler = functionAsJs(proc(_: JsObject) =
      # mark hit depending on which socket invokes us
      if not firstHit and not secondHit:
        firstHit = true
      else:
        secondHit = true
    )

    registry.registerHandler("CODETRACER::open-tab", handler)

    let first = newFakeSocket()
    registry.attachSocket(first.obj)
    first.trigger("CODETRACER::open-tab")
    check firstHit

    let second = newFakeSocket()
    registry.attachSocket(second.obj)
    second.trigger("CODETRACER::open-tab")

    check secondHit
    # ensure old socket no longer has the handler registered
    check not first.registered.hasKey("CODETRACER::open-tab")

suite "ipc registry, several sockets (ct host's clients)":
  test "a socket added beside another gets every handler, and keeps it when the other goes":
    var registry = initIpcRegistry()
    var hits: seq[string] = @[]
    registry.registerHandler("CODETRACER::open-tab",
      functionAsJs(proc(_: JsObject) = hits.add "open-tab"))

    let first = newFakeSocket()
    let second = newFakeSocket()
    registry.addSocket(first.obj)
    registry.addSocket(second.obj)
    first.trigger("CODETRACER::open-tab")
    second.trigger("CODETRACER::open-tab")
    check hits.len == 2

    registry.removeSocket(first.obj)
    check not first.registered.hasKey("CODETRACER::open-tab")
    second.trigger("CODETRACER::open-tab")
    check hits.len == 3

  test "a handler registered later reaches every socket already added":
    var registry = initIpcRegistry()
    let first = newFakeSocket()
    let second = newFakeSocket()
    registry.addSocket(first.obj)
    registry.addSocket(second.obj)
    let handler = newJsObject()
    registry.registerHandler("CODETRACER::started", handler)
    check first.registered["CODETRACER::started"] == handler
    check second.registered["CODETRACER::started"] == handler

  test "each socket's handlers run through that socket's wrap":
    var registry = initIpcRegistry()
    var ran: seq[string] = @[]
    registry.registerHandler("CODETRACER::open-tab",
      functionAsJs(proc(_: JsObject) = ran.add "handler"))
    proc wrapFor(label: string): HandlerWrap =
      result = proc(handler: JsObject): JsObject =
        let inner = jsAsFunction[proc(data: JsObject)](handler)
        functionAsJs(proc(data: JsObject) =
          ran.add label
          inner(data))
    let first = newFakeSocket()
    let second = newFakeSocket()
    registry.addSocket(first.obj, wrapFor("first"))
    registry.addSocket(second.obj, wrapFor("second"))
    second.trigger("CODETRACER::open-tab")
    check ran == @["second", "handler"]
    first.trigger("CODETRACER::open-tab")
    check ran == @["second", "handler", "first", "handler"]
    # `off` is handed the wrapped function the socket was given.
    registry.removeSocket(second.obj)
    check not second.registered.hasKey("CODETRACER::open-tab")
    check first.registered.hasKey("CODETRACER::open-tab")

  test "attachSocket keeps one socket: every other is unbound":
    var registry = initIpcRegistry()
    registry.registerHandler("CODETRACER::open-tab", newJsObject())
    let first = newFakeSocket()
    let second = newFakeSocket()
    let third = newFakeSocket()
    registry.addSocket(first.obj)
    registry.addSocket(second.obj)
    registry.attachSocket(third.obj)
    check not first.registered.hasKey("CODETRACER::open-tab")
    check not second.registered.hasKey("CODETRACER::open-tab")
    check third.registered.hasKey("CODETRACER::open-tab")
