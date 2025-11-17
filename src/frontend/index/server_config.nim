import
  std / [ async, jsffi, macros, jsconsole, strformat ],
  electron_vars, base_handlers, config, idle_timeout,
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
  proc nowMs(): int {.importjs: "Date.now()".}
  proc setInterval*(cb: proc(): void, delay: int): JsObject {.importjs: "setInterval(#, #)".}

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
    var lastConnectionMs = nowMs()
    var lastActivityMs = lastConnectionMs
    var socketAttached = false
    var idleTimer: JsObject
    var activeSocket: base_handlers.WebSocket

    proc resetActivity() =
      lastActivityMs = nowMs()

    proc resetConnection() =
      lastConnectionMs = nowMs()
      resetActivity()

    proc emitConnectionDisconnection(target: base_handlers.WebSocket, reason: cstring, message: cstring) =
      if target.isNil:
        return
      let payload = block:
        let reasonPart = cstring("""{"reason":""" & "\"" & $reason & "\"")
        if message.len > 0:
          reasonPart & cstring(""","message":""" & "\"" & $message & "\"" & "}")
        else:
          reasonPart & cstring("}")
      target.emit(cstring"CODETRACER::connection-disconnected", payload)

    proc startIdleTimer(timeoutMs: int) =
      let interval = idleCheckInterval(timeoutMs)
      if interval < 0:
        return
      idleTimer = setInterval(proc =
        let now = nowMs()
        if shouldExitIdle(socketAttached, lastConnectionMs, lastActivityMs, now, timeoutMs):
          let reason = if socketAttached: "no activity" else: "no connection"
          infoPrint fmt"ct host idle timeout reached ({reason}); exiting."
          if socketAttached and not activeSocket.isNil:
            emitConnectionDisconnection(activeSocket, cstring"idle-timeout", cstring"Host timed out after inactivity.")
          nodeProcess.exit(0)
      , interval)

    startIdleTimer(data.startOptions.idleTimeoutMs)

    socketIOServer.on(cstring"connection") do (client: base_handlers.WebSocket):
      debugPrint "connection"
      if not activeSocket.isNil and activeSocket != client:
        emitConnectionDisconnection(activeSocket, cstring"superseded", cstring"Another browser tab took over the connection.")
      activeSocket = client
      socketAttached = true
      resetConnection()

      client.onAny(proc() =
        resetActivity()
      )

      # Fallback activity hook until full heartbeats land: listen for generic activity ping.
      client.on(cstring"__activity__") do ():
        resetActivity()
      ipc.attachSocket(client)

      client.on(cstring"disconnect") do ():
        debugPrint "socket disconnect"
        ipc.detachSocket()
        socketAttached = false
        if client == activeSocket:
          activeSocket = nil
        lastConnectionMs = nowMs()
        lastActivityMs = lastConnectionMs

      if not readyVar.isNil:
        debugPrint "call ready"
        discard jsAsFunction[proc: Future[void]](readyVar)()
        readyVar = undefined

    infoPrint fmt"socket.io listening on localhost:{backendSocketPort}"
    httpServer.listen(backendSocketPort)
