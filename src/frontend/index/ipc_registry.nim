import
  std / [ jsffi ]

type
  IpcHandler* = object
    event*: cstring
    handler*: JsObject

  IpcRegistry* = ref object
    handlers*: seq[IpcHandler]
    socket*: JsObject

proc callOn(fn: JsObject, self: JsObject, event: cstring, handler: JsObject): JsObject {.importcpp: "((#)).call(#, #, #)".}
proc callOff(fn: JsObject, self: JsObject, event: cstring, handler: JsObject): JsObject {.importcpp: "((#)).call(#, #, #)".}

proc initIpcRegistry*(): IpcRegistry =
  IpcRegistry(handlers: @[], socket: nil)

proc registerHandler*(registry: IpcRegistry, event: cstring, handler: JsObject) =
  registry.handlers.add(IpcHandler(event: event, handler: handler))
  if not registry.socket.isNil:
    let onFn = registry.socket[cstring"on"]
    if not onFn.isUndefined:
      discard callOn(onFn, registry.socket, event, handler)

proc unbindAll(registry: IpcRegistry, socket: JsObject) =
  if socket.isNil:
    return
  let offFn = socket[cstring"off"]
  if offFn.isUndefined:
    return
  for handler in registry.handlers:
    discard callOff(offFn, socket, handler.event, handler.handler)

proc bindAll(registry: IpcRegistry, socket: JsObject) =
  if socket.isNil:
    return
  let onFn = socket[cstring"on"]
  if onFn.isUndefined:
    return
  for handler in registry.handlers:
    discard callOn(onFn, socket, handler.event, handler.handler)

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
