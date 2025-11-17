import
  std / [unittest, tables],
  ../index/ipc_registry,
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
  sock.obj = jsSock
  sock

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
