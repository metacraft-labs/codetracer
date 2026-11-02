## index/ipc_registry.nim — the index IPC handlers, and the sockets they are
## bound to.
##
## Handlers are registered once (`registerHandler`) and bound to every socket
## the registry holds, including sockets added later, so a handler registered
## before any client connected still answers it.
##
## A registry holds any number of sockets: `ct host` serves several clients at
## once, each on its own socket (`host_clients`). `addSocket` can wrap each
## handler for one socket, which is how a handler learns which client it is
## running for. `attachSocket` keeps the single-socket form — the given
## socket replaces every other one — for an embedding that serves one client.

import
  std / [ jsffi ]

type
  IpcHandler* = object
    event*: cstring
    handler*: JsObject

  HandlerWrap* = proc(handler: JsObject): JsObject
    ## What a socket is given in place of `handler`: a function that runs it in
    ## that socket's context. Nil binds the handler itself.

  BoundSocket = object
    socket: JsObject
    wrap: HandlerWrap
    bound: seq[JsObject]
      ## What was passed to the socket's `on`, one per `handlers` entry, so
      ## `off` removes exactly that function.

  IpcRegistry* = ref object
    handlers*: seq[IpcHandler]
    sockets: seq[BoundSocket]

proc callOn(fn: JsObject, self: JsObject, event: cstring, handler: JsObject): JsObject {.importcpp: "((#)).call(#, #, #)".}
proc callOff(fn: JsObject, self: JsObject, event: cstring, handler: JsObject): JsObject {.importcpp: "((#)).call(#, #, #)".}

proc initIpcRegistry*(): IpcRegistry =
  IpcRegistry(handlers: @[], sockets: @[])

proc bindOne(entry: var BoundSocket; handler: IpcHandler) =
  let fn = if entry.wrap.isNil: handler.handler else: entry.wrap(handler.handler)
  entry.bound.add fn
  # Called with the socket as `this`: socket.io's emitter reads its own
  # `_events` through it.
  let onFn = entry.socket[cstring"on"]
  if not onFn.isUndefined:
    discard callOn(onFn, entry.socket, handler.event, fn)

proc unbindAll(registry: IpcRegistry; entry: BoundSocket) =
  let offFn = entry.socket[cstring"off"]
  if offFn.isUndefined:
    return
  for i, handler in registry.handlers:
    if i < entry.bound.len:
      discard callOff(offFn, entry.socket, handler.event, entry.bound[i])

proc registerHandler*(registry: IpcRegistry, event: cstring, handler: JsObject) =
  let entry = IpcHandler(event: event, handler: handler)
  registry.handlers.add(entry)
  for socket in registry.sockets.mitems:
    socket.bindOne(entry)

proc indexOf(registry: IpcRegistry; socket: JsObject): int =
  for i, entry in registry.sockets:
    if entry.socket == socket:
      return i
  -1

proc addSocket*(registry: IpcRegistry; socket: JsObject;
                wrap: HandlerWrap = nil) =
  ## Bind every handler to `socket` as well, each through `wrap` when given.
  ## A socket already held is left as it is.
  if socket.isNil or registry.indexOf(socket) >= 0:
    return
  var entry = BoundSocket(socket: socket, wrap: wrap)
  for handler in registry.handlers:
    entry.bindOne(handler)
  registry.sockets.add entry

proc removeSocket*(registry: IpcRegistry; socket: JsObject) =
  ## Unbind every handler from `socket`; the other sockets keep theirs.
  let i = registry.indexOf(socket)
  if i < 0:
    return
  registry.unbindAll(registry.sockets[i])
  registry.sockets.delete(i)

proc detachSocket*(registry: IpcRegistry) =
  ## Unbind every handler from every socket.
  for i in countdown(registry.sockets.high, 0):
    registry.unbindAll(registry.sockets[i])
  registry.sockets.setLen(0)

proc attachSocket*(registry: IpcRegistry, socket: JsObject) =
  ## Bind the handlers to `socket` ALONE: every other socket is unbound.
  if registry.sockets.len == 1 and registry.sockets[0].socket == socket:
    return
  registry.detachSocket()
  registry.addSocket(socket)
