import
  std / [ async, jsffi, macros ],
  ../lib/[ jslib ],
  ../[ types ],
  ./ipc_registry,
  ../../common/[ ct_logging ]


type
  DebuggerIPC* = ref object
    functions*: JsAssoc[cstring, js]
    internalSend*: proc(id: cstring, message: cstring, arg: cstring)

  FrontendIPCSender* = ref object
    send*: proc(id: cstring, message: js)

  WebSocket* = ref object
    off*: proc(id: cstring, handler: JsObject)
    emit*: proc(id: cstring, value: cstring)

  FrontendIPC* = ref object
    webContents*: FrontendIPCSender
    socket*: WebSocket # from socket.io
    registry*: IpcRegistry

proc on*(socket: WebSocket, name: cstring, handler: proc) {.importcpp: "#.on(#, #)".}

# TODO: error on unhandled: is it easy with electron
macro indexIpcHandlers*(namespace: static[string], messages: untyped): untyped =
  let ipc = ident("ipc")
  let data = ident("data")
  result = nnkStmtList.newTree()
  for message in messages:
    var fullMessage: NimNode
    var handler: NimNode
    var messageCode: NimNode
    if message.kind == nnkStrLit:
      fullMessage = (namespace & $message).newLit
      handler = (("on-" & $message).toCamelCase).ident
      messageCode = quote:
        `ipc`.on(`fullMessage`, `handler`.toJs)
      result.add(messageCode)
    else:
      error "unexpected message ", message


proc on*(debugger: DebuggerIPC, taskId: TaskId, code: proc) =
  debugger.functions[taskId.cstring] = functionAsJS(code)

proc on*(debugger: DebuggerIPC, eventId: EventId, code: proc) =
  debugger.functions[eventId.cstring] = functionAsJS(code)

proc send*(debugger: DebuggerIPC, message: cstring, taskId: cstring, arg: cstring) =
  if not debugger.internalSend.isNil:
    debugger.internalSend(message, taskId, arg)
  else:
    errorPrint "index: no internalSend"

proc initFrontendIPC*(): FrontendIPC =
  FrontendIPC(
    webContents: FrontendIPCSender(),
    socket: nil,
    registry: initIpcRegistry())

proc attachSocket*(frontend: FrontendIPC, socket: WebSocket) =
  # detach old bindings and rebind to the new socket
  frontend.registry.attachSocket(socket.toJs)
  frontend.socket = socket

proc detachSocket*(frontend: FrontendIPC) =
  frontend.registry.detachSocket()
  frontend.socket = nil

proc emit*(frontend: FrontendIPC, id: cstring, payload: cstring) =
  if frontend.socket.isNil:
    debugPrint "ipc emit dropped: no socket attached"
    return
  frontend.socket.emit(id, payload)

proc on*(frontend: FrontendIPC, id: cstring, handler: JsObject) =
  let handlerFunction = jsAsFunction[proc(sender: JsObject, response: JsObject): Future[void]](handler)
  let wrappedHandler = functionAsJs(proc(value: JsObject) =
    discard handlerFunction(undefined, value)
  )
  frontend.registry.registerHandler(id, wrappedHandler)
