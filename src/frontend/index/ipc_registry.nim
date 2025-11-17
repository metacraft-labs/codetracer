import
  std / [ jsffi ],
  ../lib/jslib

type
  IpcHandler* = object
    event*: cstring
    handler*: JsObject

  IpcRegistry* = ref object
    handlers*: seq[IpcHandler]
    socket*: JsObject

proc initIpcRegistry*(): IpcRegistry =
  IpcRegistry(handlers: @[], socket: nil)

proc registerHandler*(registry: IpcRegistry, event: cstring, handler: JsObject) =
  registry.handlers.add(IpcHandler(event: event, handler: handler))
  if not registry.socket.isNil:
    let onFn = registry.socket[cstring"on"]
    if not onFn.isUndefined:
      let onProc = jsAsFunction[proc(id: cstring, handler: JsObject): JsObject](onFn)
      discard onProc(event, handler)

proc unbindAll(registry: IpcRegistry, socket: JsObject) =
  if socket.isNil:
    return
  let offFn = socket[cstring"off"]
  if offFn.isUndefined:
    return
  let offProc = jsAsFunction[proc(id: cstring, handler: JsObject): JsObject](offFn)
  for handler in registry.handlers:
    discard offProc(handler.event, handler.handler)

proc bindAll(registry: IpcRegistry, socket: JsObject) =
  if socket.isNil:
    return
  let onFn = socket[cstring"on"]
  if onFn.isUndefined:
    return
  let onProc = jsAsFunction[proc(id: cstring, handler: JsObject): JsObject](onFn)
  for handler in registry.handlers:
    discard onProc(handler.event, handler.handler)

proc attachSocket*(registry: IpcRegistry, socket: JsObject) =
  if registry.socket == socket:
    return
  if not registry.socket.isNil:
    registry.unbindAll(registry.socket)
  registry.socket = socket
  registry.bindAll(socket)

proc detachSocket*(registry: IpcRegistry) =
  if registry.socket.isNil:
    return
  registry.unbindAll(registry.socket)
  registry.socket = nil
