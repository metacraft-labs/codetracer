import
  std / [ async, jsffi, macros, jsconsole, strformat ],
  electron_vars, base_handlers, config,
  ../lib/[ jslib, electron_lib, misc_lib ],
  ../[ types ],
  ../../common/[ paths, ct_logging ]

when defined(server):
  type
    ExpressLib* = ref object
      `static`*: proc(path: cstring): JsObject

    ExpressServer* = ref object
      get*: proc(path: cstring, handler: proc(req: Jsobject, response: JsObject))
      listen*: proc(port: int, handler: proc: void)
      use*: proc(prefix: cstring, value: JsObject)


when not defined(server):
  var chalk* = cast[Chalk](require(cstring"chalk"))
  type DebugMainIPC = ref object
    electron*: js

  proc on*(ipc: DebugMainIPC, id: cstring, handler: JsObject) =
    ipc.electron[cstring"on2"] = ipc.electron[cstring"on"]
    ipc.electron.on2(id) do (sender: js, data: js):
      var values = loadValues(data, id)
      let kind = cast[cstring](id)
      if kind != cstring"CODETRACER::save-config":
        debugPrint cstring($(chalk.blue(cstring(fmt"frontend =======> index: {kind}"))))
        # TODO: think more: flag for enabling/disabling printing those values?
      else:
        debugPrint cstring($(chalk.blue(cstring(fmt"frontend =======> index: {kind}"))))
      let rawTaskId = if not data.isNil: data.taskId else: NO_TASK_ID.toJs
      let taskId = if not rawTaskId.isUndefined:
          cast[TaskId](rawTaskId)
        else:
          NO_TASK_ID
      # TODO: QA NOTE FIX THE CIRCULAR DEPENDENCY
      #debugIndex fmt"frontend =======> index: {kind}", taskId
      let handlerFunction = jsAsFunction[proc(sender: js, response: js): Future[void]](handler)
      discard handlerFunction(sender, data)

  var ipc* = DebugMainIPC(electron: electron.ipcMain)
else:
  var ipc* = initFrontendIPC()


when defined(server):
  proc call*(lib: ExpressLib): ExpressServer {.importcpp: "#()".}
  proc newSocketIoServer*(serverClass: JsObject, httpServer: JsObject, options: JsObject): JsObject {.importcpp: "new #(#, #)" .}

  let express* = cast[ExpressLib](require("express"))
  var readyVar*: js

  proc setupServer* =
    # we create a server
    # and we receive socket messages instead of using ipc
    # Nikola hides all of this behind some kind of proxy

    var httpServer = require("http").createServer()
    var server = express.call()

    server.toJs.set(cstring"view engine", cstring"ejs")
    server.get(cstring"/", proc(request: JsObject, response: JsObject) =
      response.render(cstring"server_index", js{
        frontendSocketPort: data.startOptions.frontendSocket.port,
        frontendSocketParameters: data.startOptions.frontendSocket.parameters
      }))

    debugPrint codetracerExeDir & cstring"/frontend/styles/"
    server.use(cstring"/golden-layout", express.`static`(codetracerInstallDir & cstring"/libs/golden-layout"))
    server.use(cstring"/public/", express.`static`(codetracerExeDir & cstring"/public/"))
    server.use(cstring"/styles/", express.`static`(codetracerExeDir & cstring"/frontend/styles/"))
    server.use(cstring"/frontend/styles/", express.`static`(codetracerExeDir & cstring"/frontend/styles/"))
    server.use(cstring"/node_modules", express.`static`(codetracerInstallDir & cstring"/node_modules"))
    server.use(cstring"/ui.js", express.`static`(userInterfacePath))
    server.listen(data.startOptions.port, proc = infoPrint fmt"listening on localhost:{data.startOptions.port}")

    debugPrint "in server"
    debugPrint data.startOptions

    let port = data.startOptions.port
    let backendSocketPort = data.startOptions.backendSocket.port

    var socketIoServerClass = (require("socket.io"))[cstring"Server"]
    var socketIoServer = newSocketIoServer(socketIoServerClass, httpServer, js{
      cors: js{
        origin: cstring("*"),
        credentials: false
      }
    })
    socketIOServer.on(cstring"connection") do (client: base_handlers.WebSocket):
      debugPrint "connection"
      ipc.attachSocket(client)

      client.on(cstring"disconnect") do ():
        debugPrint "socket disconnect"
        ipc.detachSocket()

      if not readyVar.isNil:
        debugPrint "call ready"
        discard jsAsFunction[proc: Future[void]](readyVar)()
        readyVar = undefined
    infoPrint fmt"socket.io listening on localhost:{backendSocketPort}"
    httpServer.listen(backendSocketPort)
