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
