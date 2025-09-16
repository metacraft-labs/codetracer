import
  std / [ async, jsffi, macros ],
  ../[ types, lib ],
  ../../common/[ ct_logging ]


type
  DebuggerIPC* = ref object
    functions*: JsAssoc[cstring, js]
    internalSend*: proc(id: cstring, message: cstring, arg: cstring)

  FrontendIPCSender* = ref object
    send*: proc(id: cstring, message: js)

  WebSocket* = ref object
    emit*: proc(id: cstring, value: cstring)

  FrontendIPC* = ref object
    webContents*: FrontendIPCSender
    socket*: WebSocket # from socket.io

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

proc on*(frontend: FrontendIPC, id: cstring, handler: JsObject) =
  let handlerFunction = jsAsFunction[proc(sender: JsObject, response: JsObject): Future[void]](handler)
  frontend.socket.on(id, proc(value: JsObject) = discard handlerFunction(undefined, value))