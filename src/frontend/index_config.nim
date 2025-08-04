import jsffi, async, strformat, strutils, sequtils, macros, os, jsconsole, json
import lib, config, path_utils, task_and_event, lang, paths
import ../common/ct_logging
import dap_protocol

import types
# Contains a lot of index process procedures dealing with files and configs


let fsPlus* = require("fs-plus")
let fsAsync* = require("fs").promises
let child_process* = cast[(ChildProcessLib)](require("child_process"))
let util = require("util")
var mmap*: MMap
let helpers* {.exportc: "helpers".} = require("./helpers")

var mainWindow*: JsObject
var installDialogWindow*: JsObject
var callerProcessPid*: int = -1

var indexLogPath*: cstring = cstring""
var logStream*: NodeWriteStream = nil

template debugIndex*(msg: string, taskId: TaskId = NO_TASK_ID): untyped =
  if indexLogPath.len == 0:
    indexLogPath = ensureLogPath(
      "index",
      callerProcessPid,
      "index",
      0,
      "log"
    ).cstring

  if logStream.isNil:
    logStream = fs.createWriteStream(indexLogPath, js{flags: cstring"a"})

  if not logStream.isNil:
    discard logStream.write(withDebugInfo(msg.cstring, taskId, "DEBUG") & jsNl)

type
  ServerData* = object
    tabs*: JsAssoc[cstring, ServerTab]
    config*: Config
    trace*: Trace
    replay*: bool
    exe*: seq[cstring]
    closedTabs*: seq[cstring]
    closedPanels*: seq[cstring]
    save*: Save
    nimcacheDir*: cstring
    startOptions*: StartOptions
    start*: int64
    asmFunctions*: JsAssoc[cstring, Instructions]
    nimCSources*: JsAssoc[cstring, cstring]
    pluginCommands*: JsAssoc[cstring, SearchSource]
    pluginClient*: PluginClient
    ptyProcesses*: JsAssoc[int, PtyProcess]
    debugInstances*: JsAssoc[int, DebugInstance]
    recordProcess*: NodeSubProcess
    layout*: js
    helpers*: Helpers

  DebugInstance* = object
    process*:       NodeSubProcess
    pipe*:          JsObject


  ServerTab* = ref object
    path*:          cstring
    lang*:          Lang
    fileWatched*:   bool
    ignoreNext*:    int # save
    waitsPrompt*:   bool

  DebuggerIPC* = ref object
    functions*: JsAssoc[cstring, js]
    internalSend*: proc(id: cstring, message: cstring, arg: cstring)

  FrontendIPC* = ref object
    webContents*: FrontendIPCSender
    socket*: WebSocket # from socket.io

  FrontendIPCSender* = ref object
    send*: proc(id: cstring, message: js)

  WebSocket* = ref object
    emit*: proc(id: cstring, value: cstring)

  # BrowserIPC* = ref object
  #   functions*: JsAssoc[cstring, js]
  #   send*: js
  #   on*: proc(id: cstring, response: js)

  Pty* = object
    spawn*: proc(shell: cstring, args: seq[cstring], options: JsObject): PtyProcess

  PtyProcess* = ref object
    on*: proc(event: cstring, handler: proc(data: cstring): Future[void])
    write*: proc(raw: cstring)

  ExpressLib* = ref object
    `static`*: proc(path: cstring): JsObject

  ExpressServer* = ref object
    get*: proc(path: cstring, handler: proc(req: Jsobject, response: JsObject))
    listen*: proc(port: int, handler: proc: void)
    use*: proc(prefix: cstring, value: JsObject)



proc call*(lib: ExpressLib): ExpressServer {.importcpp: "#()".}

var data* = ServerData(
  replay: true,
  exe: @[],
  tabs: JsAssoc[cstring, ServerTab]{},
  closedTabs: @[],
  closedPanels: @[],
  nimcacheDir: j"",
  startOptions: StartOptions(
    loading: true,
    screen: true,
    inTest: false,
    record: false,
    edit: false,
    name: j"",
    frontendSocket: SocketAddressInfo(),
    backendSocket: SocketAddressInfo(),
    rawTestStrategy: cstring"",),
  asmFunctions: JsAssoc[cstring, Instructions]{},
  nimCSources: JsAssoc[cstring, cstring]{},
  pluginCommands: JsAssoc[cstring, SearchSource]{},
  debugInstances: JsAssoc[int, DebugInstance]{},
  ptyProcesses: JsAssoc[int, PtyProcess]{})

when not defined(server):
  let electron* = require("electron")
  let dialog* = electron.dialog
else:
  let electron* = ServerElectron().toJs
  let dialog*: js = undefined

var fsReadFile* {.importcpp: "helpers.fsReadFile(#)".}: proc(f: cstring): Future[cstring]
var fsWriteFile* {.importcpp: "helpers.fsWriteFile(#, #)".}: proc(f: cstring, data: cstring): Future[void]
var fsReadFileWithErr* {.importcpp: "helpers.fsReadFileWithErr(#)".}: proc(f: cstring): Future[(cstring, js)]
var fsWriteFileWithErr* {.importcpp: "helpers.fsWriteFileWithErr(#, #)".}: proc(f: cstring, s: cstring): Future[js]
var fsReaddir* {.importcpp: "helpers.fsReaddir(#, #)".}: proc(f: cstring, options: js): Future[seq[cstring]]
var fsCopyFileWithErr* {.importcpp: "helpers.fsCopyFileWithErr(#, #)".}: proc(a: cstring, b: cstring): Future[js]
var fsMkdirWithErr* {.importcpp: "helpers.fsMkdirWithErr(#, #)".}: proc(a: cstring, options: JsObject): Future[JsObject]
var childProcessExec* {.importcpp: "helpers.childProcessExec(#, #)".}: proc(cmd: cstring, options: js = jsUndefined): Future[(cstring, cstring, js)]
var newWebSocket* {.importcpp: "new websocket(#)".}: proc(host: cstring): WebSocket
var newWebSocketServer* {.importcpp: "new websocket.Server({host: '127.0.0.1', port: #})".}: proc(port: int = 3000): WebSocketServer

proc newSocketIoServer*(serverClass: JsObject, httpServer: JsObject, options: JsObject): JsObject {.importcpp: "new #(#, #)" .}

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


when not defined(server):
  var chalk* = cast[Chalk](require(j"chalk"))
  type DebugMainIPC = ref object
    electron*: js


  proc on*(ipc: DebugMainIPC, id: cstring, handler: JsObject) =
    ipc.electron[j"on2"] = ipc.electron[j"on"]
    ipc.electron.on2(id) do (sender: js, data: js):
      var values = loadValues(data, id)
      let kind = cast[cstring](id)
      if kind != cstring"CODETRACER::save-config":
        debugPrint cstring($(chalk.blue(cstring(fmt"frontend =======> index: {kind}"))))
        # TODO: think more: flag for enabling/disabling printing those?
        # values
      else:
        debugPrint cstring($(chalk.blue(cstring(fmt"frontend =======> index: {kind}"))))
      let rawTaskId = if not data.isNil: data.taskId else: NO_TASK_ID.toJs
      let taskId = if not rawTaskId.isUndefined:
          cast[TaskId](rawTaskId)
        else:
          NO_TASK_ID
      debugIndex fmt"frontend =======> index: {kind}", taskId
      let handlerFunction = jsAsFunction[proc(sender: js, response: js): Future[void]](handler)
      discard handlerFunction(sender, data)

  var ipc* = DebugMainIPC(electron: electron.ipcMain)
else:
  var ipc* = FrontendIPC()


when defined(server):
  let express* = cast[ExpressLib](require("express"))
  let ejs = require("ejs")
  var readyVar*: js

  proc setupServer* =
    # we create a server
    # and we receive socket messages instead of using ipc
    # Nikola hides all of this behind some kind of proxy

    var httpServer = require("http").createServer()
    var server = express.call()

    server.toJs.set(cstring"view engine", cstring"ejs")
    server.get(cstring"/", proc(request: JsObject, response: JsObject) =
      # response.send(cstring"mercy")
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
    socketIOServer.on(cstring"connection") do (client: WebSocket):
      debugPrint "connection"
      ipc.socket = client

      if not readyVar.isNil:
        debugPrint "call ready"
        discard jsAsFunction[proc: Future[void]](readyVar)()
        readyVar = undefined
    infoPrint fmt"socket.io listening on localhost:{backendSocketPort}"
    httpServer.listen(backendSocketPort)



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

proc findNimcacheDir(data: var ServerData): Future[cstring] =
  # we are trying to find the nimcache dir based on dump: I think we should review it
  if data.nimcacheDir != j"":
    return cast[Future[cstring]](data.nimcacheDir)
  var promise = newPromise() do (resolve: proc(response: cstring)):
    var s = child_process.spawn(j"libs/nim/bin/nim", concat(@[j"dump"], @[data.trace.program]))
    s.stdout.setEncoding(j"utf8")
    s.stderr.setEncoding(j"utf8")
    var finished = false
    s.stdout.on(j"data") do (raw: cstring):
      if not finished:
        data.nimcacheDir = raw.split(jsNl)[0].trim() & j"/"
        finished = true
        resolve(data.nimcacheDir)
  return promise


proc toAsm(data: ServerData, name: string): Future[seq[cstring]] {.async.}=
  # find the asm code for a function
  let (output, _, _) = await childProcessExec(j(&"gdb -batch -ex 'file {data.trace.program}' -ex 'disassemble {name}'"))
  var res: seq[cstring] = output.split(jsNl)[1 .. ^3]
  return res

proc initDebugger*(main: js, trace: Trace, config: Config, helpers: Helpers) {.async.}
proc loadAsm*(data: ServerData, functionLocation: FunctionLocation): Future[Instructions] {.async.}


proc mapAssemblyFunctions(data: ServerData, functions: seq[tuple[name: string, line: int]], functionName: cstring, savedFunctions: JsAssoc[cstring, seq[AssemblyToken]]): Future[JsAssoc[cstring, seq[AssemblyToken]]] {.async.} =
  var res = savedFunctions
  let raw = await data.toAsm($functionName)
  let tokens: seq[AssemblyToken] = @[] #raw.mapIt(assemblyTokenize(it))
  res[functionName] = tokens
  return res

proc basename(filename: cstring): cstring =
  var t = ($filename).rsplit("/", 1)[1]
  return j(t)

# TaskId/EventId cstring => function
var debuggerIPC* = DebuggerIPC(functions: JsAssoc[cstring, js]{})
console.time(cstring"index: starting backend")

var onDebugger = JsAssoc[cstring, js]{}

let net* = require("net")

proc writeArgFile*(message: cstring, taskIdRaw: cstring, arg: cstring) =
  let argFilePath = ensureArgPathFor(callerProcessPid, taskIdRaw.TaskId)
  fs.writeFileSync(argFilePath, arg)

proc readRawResult*(taskId: TaskId): cstring =
  fs.readFileSync(ensureResultPathFor(callerProcessPid, taskId), cstring"utf8")

proc readResult*[ReturnType](taskId: TaskId): ReturnType =
  cast[ReturnType](JSON.parse(readRawResult(taskId)))

proc readRawEvent*(eventId: EventId): cstring =
  fs.readFileSync(ensureEventPathFor(callerProcessPid, eventId), cstring"utf8")

proc readEvent*[EventContent](eventId: EventId): EventContent =
  cast[EventContent](JSON.parse(readRawResult(eventId)))

var unixClient: js
var unixSender: js

proc setupCoreIPC(debugger: DebuggerIPC) =
  var message = cstring""
  var argText = cstring""
  var received = cstring""
  var inReceive = false
  var receiveMessage = cstring""
  var receiveOutput = cstring""

  unixClient.on(cstring"data") do (data: cstring):
    # receiving one of:
    #
    # return <message> <task-id>
    # event <event> <event-id>
    #

    debugPrint "data: ", data
    let lines = data.split(jsNl)
    for i, line in lines:
      if line.len == 0: # empty line: ignore
        continue
      debugPrint "<= ", line
      # debug "line", line=line
      let tokens = line.split(cstring" ")
      if tokens.len != 3:
        let message = fmt"error: invalid line, not 3 tokens: {line}"
        debugPrint message
        debugIndex(fmt"error: invalid line, not 3 tokens: {line}")
      else:
        let kind = tokens[0]
        if kind == "return":
          let rawMessage = tokens[1]
          let taskId = tokens[2].TaskId
          let res = JSON.parse(readRawResult(taskId))
          var handler = debugger.functions[taskId.cstring]
          if not handler.isNil:
            handler.call(handler, res)
        elif kind == "event" or kind == "raw-event":
          let rawEvent = tokens[1]
          let eventId = tokens[2].EventId
          let res = if kind == "event":
              JSON.parse(readRawEvent(eventId))
            else:
              readRawEvent(eventId).toJs
          # directly delegate to frontend
          mainWindow.webContents.send fmt"CODETRACER::{rawEvent}", res


  debugger.internalSend = proc(message: cstring, taskIdRaw: cstring, arg: cstring) =
    let taskId = cast[TaskId](taskIdRaw)
    debugPrint fmt"index ===> ... dispatcher {message} {taskId} {arg}"
    debugIndex fmt"index ===> ... dispatcher {message} {arg}", taskId
    writeArgFile(message, taskIdRaw, arg)
    unixSender.write(
        message & cstring" " & taskIdRaw & jsNl)
        # args.mapIt(JSON.stringify(it) & jsNl).join(cstring"") &
        # cstring"#END" & jsNl)

proc startSocket*(path: cstring, expectPossibleFail: bool = false): Future[JsObject] =
  var future = newPromise() do (resolve: proc(response: JsObject)):
    var connections: seq[JsObject] = @[nil.toJs]
    connections[0] = net.createConnection(js{path: path, encoding: cstring"utf8"}, proc =
      debugPrint "index: connected succesfully socket for ", path #  for receiving from core and task processes"
      resolve(connections[0]))

    connections[0].on(cstring"error") do (error: js):
      # in some cases, we expect a socket might not be connected
      # e.g. for "instance client": this is not expected to work
      # if not started from the `shell-ui` feature, which is not really working now
      # (at least in thsi version)
      # we only log an error for the other cases,
      # and just a debug print for the expected possible fails
      if not expectPossibleFail:
        errorPrint "socket ipc error: ", error
      else:
        debugPrint "socket ipc error(but expected possible fail): ", error
      resolve(nil.toJs)
  return future

type
  RawDapMessage* = ref object
    raw*: cstring

  DapRequest* = ref object
    command*: cstring
    value*: JsObject

var dapSocket*: JsObject

proc utf8ByteLen(s: cstring): int
  {.importjs: "(typeof Buffer==='function' ? Buffer.byteLength(#,'utf8') : (new TextEncoder()).encode(#).length)".}

proc stringify*(o: JsObject): cstring {.importjs: "JSON.stringify(#)".}

proc onDapRawMessage*(sender: js, response: DapRequest) {.async.} =
  if not dapSocket.isNil:
    console.log "RECEIVED THE FOLLOWING DAP MESSAGE IN INDEX FROM UI: ", response.command, " with val: ", response.value

    let cmd = $response.command

    let req = Request(
      seq: 1,
      `type`: "request",
      command: cmd,
      arguments: response.value
    )
    console.log "SENDING AFTER PROCESSING: ", req

    dapSocket.write req.toCString()
  else:
    # TODO: put in a queue, or directly make an error, as it might be made hard to happen,
    # if sending from frontend only after dap socket setup here
    errorPrint "dap socket is nil, couldn't send ", response.toJs

# TODO: This function need to differentiate between a response and an event
proc setupProxyForDap* =
  dapSocket.on(cstring"data", proc(data: cstring) =
    echo "received: ", splitLines($data)
    let body: JsonNode = parseJson(splitLines($data)[2])
    echo "body: ", body

    if body["type"].getStr == "request":
      mainWindow.webContents.send "CODETRACER::dap-receive-response", data
    elif body["type"].getStr == "event":
      mainWindow.webContents.send "CODETRACER::dap-receive-event", data
  )

proc dapSocketPathForCallerPid(callerPid: int): cstring =
  CT_DAP_SOCKET_PATH_BASE & cstring"_" & cstring($callerPid)

proc startAndSetupCoreIPC*() {.async.} =
  while dapSocket.isNil:
    let socketPath = dapSocketPathForCallerPid(callerProcessPid)
    dapSocket = await startSocket(socketPath)
  setupProxyForDap()

  # while unixClient.isNil or unixSender.isNil:
  #   if unixClient.isNil:
  #     unixClient = await startSocket(debugger, CT_CLIENT_SOCKET_PATH & cstring"_" & cstring($callerProcessPid))
  #   if unixSender.isNil:
  #     unixSender = await startSocket(debugger, CT_SOCKET_PATH & cstring"_" & cstring($callerProcessPid))
  #   await wait(500)
  # setupCoreIPC(debugger)


var debugger* = debuggerIPC


macro defineAPI*(functions: untyped): untyped =
  let debugger = ident("debugger")
  let DebuggerIPC = ident("DebuggerIPC")

  result = nnkStmtList.newTree()

  for fun in functions:
    let name = fun[1]
    var a = fun[2][0]
    var r = a[0]
    let nameText = newLit(name.repr)
    let messageLit = ident(name.repr.capitalizeAscii())
    var messageArg: NimNode
    if a.len > 1:
      messageArg = a[1][0]
    else:
      messageArg = newLit("")

    let oldA = a
    a = nnkFormalParams.newTree(
      r,
      nnkIdentDefs.newTree(debugger, DebuggerIPC, newEmptyNode()))

    for i, arg in oldA:
      if i == 0:
        continue
      a.add(arg)

    let taskIdIdent = ident("taskId")
    let default = quote do: genTaskId(TaskKind.`messageLit`)
    a.add(
      nnkIdentDefs.newTree(
        taskIdIdent,
        ident("TaskId"),
        default))
        # ident("NO_TASK_ID")))
    # args[1].add(quote do: `taskIdIdent`.toJs)

    let ipc = ident("debuggerIPC")
    var code: NimNode
    if r.repr == "Future[void]":
      code = quote:
        var promise = newPromise() do (resolve: (proc: void)):
          # debug "debugger", topics="index", _="CODETRACER::" & `nameText`
          `debugger`.send(
            `nameText`,
            `taskIdIdent`.cstring,
            Json.stringify(`messageArg`.toJs))

          # debug "wait", msg="CODETRACER::" & `nameText` & "-received"
          `ipc`.on(`taskIdIdent`) do (res: JsObject):
            resolve()
        return promise
    else:
      let typ = r[1]
      code = quote:
        var promise = newPromise() do (resolve: (proc(response: `typ`))):
          # debug "debugger", topics="index", _="CODETRACER::" & `nameText`
          `debugger`.send(
            `nameText`.cstring,
            `taskIdIdent`.cstring,
             Json.stringify(`messageArg`.toJs))

          # debug "wait", msg="CODETRACER::" & `nameText` & "-received"
          `ipc`.on(`taskIdIdent`) do (res: JsObject):
            let response = cast[`typ`](res)
            resolve(response)
        return promise

    result.add(
      nnkProcDef.newTree(
        nnkPostfix.newTree(ident("*"), name),
        newEmptyNode(),
        newEmptyNode(),
        a,
        newEmptyNode(),
        newEmptyNode(),
        nnkStmtList.newTree(code)))

type DOutput = DebugOutput # hack? maybe a bug in macro

defineAPI:
  configure         is proc(arg: ConfigureArg): Future[void]
  start             is proc(arg: EmptyArg): Future[void]
  runToEntry        is proc(arg: EmptyArg): Future[void]
  step              is proc(arg: StepArg): Future[void]
  loadLocals        is proc(arg: LoadLocalsArg): Future[seq[Variable]]
  updateWatches     is proc(watchExpressions: seq[cstring]): Future[void]
  eventLoad         is proc(arg: EmptyArg): Future[void]
  resetOperation    is proc(arg: ResetOperationArg): Future[void]
  loadAsmFunction   is proc(functionLocation: FunctionLocation): Future[Instructions]
  runTracepoints    is proc(arg: RunTracepointsArg): Future[void]
  addBreak          is proc(location: SourceLocation): Future[int]
  deleteBreak       is proc(location: SourceLocation): Future[bool]
  enable            is proc(location: SourceLocation): Future[void]
  disable           is proc(location: SourceLocation): Future[void]
  deleteAllBreakpoints is proc(arg: EmptyArg): Future[void]
  loadFlow          is proc(location: Location): Future[void]
  loadCallstack     is proc(arg: LoadCallstackArg): Future[seq[Call]]
  loadCallArgs      is proc(calltraceLoadArgs: CalltraceLoadArgs): Future[void]
  loadTerminal      is proc(arg: EmptyArg): Future[void]
  collapseCalls     is proc(collapseCallsArgs: CollapseCallsArgs): Future[void]
  expandCalls       is proc(collapseCallsArgs: CollapseCallsArgs): Future[void]
  updateTable       is proc(args: UpdateTableArgs): Future[void]
  tracepointDelete  is proc(tracepointId: TracepointId): Future[void]
  tracepointToggle  is proc(tracepointId: TracepointId): Future[void]
  loadHistory       is proc(arg: LoadHistoryArg): Future[void]
  searchProgram     is proc(query: cstring): Future[void]
  loadStepLines     is proc(arg: LoadStepLinesArg): Future[void]
  resetState        is proc(arg: EmptyArg): Future[void]

  calltraceJump     is proc(location: Location): Future[void]
  calltraceSearch   is proc(arg: CallSearchArg): Future[seq[Call]]
  eventJump         is proc(event: ProgramEvent): Future[void]
  traceJump         is proc(event: ProgramEvent): Future[void]
  historyJump       is proc(res: Location): Future[void]
  sourceLineJump    is proc(target: SourceLineJumpTarget): Future[void]
  sourceCallJump    is proc(target: SourceCallJumpTarget): Future[void]
  localStepJump     is proc(jumpInfo: types.LocalStepJump): Future[void]

  expandValue       is proc(target: ExpandValueTarget): Future[Value]
  loadParsedExprs   is proc(target: LoadParsedExprsArg): Future[JsAssoc[cstring, seq[FlowExpression]]]

  evaluateExpression is proc(target: EvaluateExpressionArg): Future[Value]

  # CRITICAL: CAREFUL: don't expose that out of development
  # debugGdb          is proc(arg: DebugGdbArg): Future[DOutput]

when false:
  ## TODO: fix/test expand values
  #
  # expandValue       is proc(expression: cstring): Future[Value]
  # expandValues      is proc(expressions: seq[cstring], depth: int): Future[seq[Value]]
  # --
      # TODO: flow shape separation/improvements, not clear when would this happen
  # maybe in the longer term?
  # loadFlowShape     is proc(location: Location): Future[void]

  ## c low level related: not sure if going in internal release:
  #
  # addBreakC         is proc(location: SourceLocation): Future[int]
  # nimLoadCLocations is proc(path: cstring, line: int): Future[LowLevelLocations]
  # --

  ## do we still need it, or is calltraceJump always enough?
  #
  # callstackJump     is proc(location: CallstackJump): Future[void]
  # --

  ## older experiment with trace nim template-like helpers
  ## like Zahary wanted: think if and how and when would we need
  ## something like this now
  #
  # saveHelpers       is proc(): Future[void]
  # registerHelper    is proc(name: cstring, helper: Helper, node: QueryNode): Future[void]
  # --


  ## older calltrace/global calltrace ideas: not supported currently,
  ##   but maybe we can fix them?
  #
  # updateCalltrace       is proc(parent: int64, depth: int, length: int, start: int, sectionLength: int): Future[UpdatedCalltrace]
  # calltraceScrollUp   is proc: Future[void]
  # calltraceScrollDown is proc: Future[void]
  # fullCalltraceScrollUp   is proc: Future[FullSection]
  # fullCalltraceScrollDown is proc: Future[FullSection]
  # calltraceSearch   is proc(expression: cstring): Future[seq[Call]]
  # loadCallstackDirectChildrenBefore is proc(codeID: int64, before: int64): Future[seq[Call]]
  # --

  ## experiment for just walking around the codebase
  ## automatically, for e.g. testing
  #
  # walk              is proc(waitDuration: int): Future[void] # miliseconds
  # --

  ## macro expansion: maybe not part of internal release?
  #
  # loadCodeLocations is proc(pattern: cstring, limit: int): Future[void]
  # updateExpansionLevel is proc(path: cstring, line: int, update: MacroExpansionLevelUpdate): Future[Location]
  # --

proc onError*(error: DebuggerError) =
  errorPrint error.kind, " ", error.msg
  mainWindow.webContents.send "CODETRACER::error", error

proc sendNotification*(kind: NotificationKind, message: cstring) =
  let notification = newNotification(kind, $message)
  mainWindow.webContents.send "CODETRACER::new-notification", notification

proc openTab*(main: js, location: types.Location, lang: Lang, editorView: EditorView, line: int = -1): Future[void] {.async.}


proc open*(data: ServerData, main: js, location: types.Location, editorView: EditorView, messagePath: string, replay: bool, exe: seq[cstring], lang: Lang, line: int): Future[void] {.async.} =
  var source = j""
  var tokens: seq[seq[Token]] = @[]
  var symbols = JsAssoc[cstring, seq[js]]{}
  if location.highLevelPath == j"unknown":
    return
  let filename = location.highLevelPath
  # TODO path for low level?
  # if data.tabs.hasKey(filename):
  #   return

  # TODO: explicitly ask for trace source of direct file
  # e.g. source location/debugger always => trace source
  # ctrlp/filesystem: maybe based on where the file comes from:
  #   trace paths/trace sourcefolder or direct filesystem/other
  # ctrl+o/similar => direct
  var readPath = if data.trace.imported:
      let traceFilesFolder = $data.trace.outputFolder / "files"
      cstring(traceFilesFolder / $filename)
    else:
      filename

  var err: js
  (source, err) = await fsReadFileWithErr(readPath)
  if not err.isNil:
    # source = j"<file missing>!"
    # filename = j"<file missing: " & filename & j">"
    # missing = true
    console.log "error reading file directly ", filename, " ", err
    if data.trace.imported:
      # try original filename if
      # it was first tried with a trace copy path
      (source, err) = await fsReadFileWithErr(filename)

      if not err.isNil:
        console.log "error reading file from trace ", filename, " ", err
        return
    else:
      # we tried the original filename if not imported:
      # directly stop
      console.log "error: trace not imported, but file couldn't be read ", filename
      return
    # bug "file missing " & $filename

  if err.isNil:
    if not data.tabs.hasKey(filename):
      # TODO: enable again, but
      # try to not send event for our own saves/changes

      # fs.watch(filename) do (e: cstring, filenameArg: cstring):
      #   if e == j"change":
      #     # debugPrint "change?", filename
      #     # TODO: try to not send event for our own saves/changes
      #     if not data.tabs.hasKey(filename):
      #       data.tabs[filename] = ServerTab(path: filename, lang: LangUnknown, fileWatched: true)
      #     if data.tabs[filename].fileWatched and data.tabs[filename].ignoreNext == 0 and not data.tabs[filename].waitsPrompt:
      #       data.tabs[filename].waitsPrompt = true
      #       mainWindow.webContents.send "CODETRACER::change-file", js{path: filename}
      #     elif data.tabs[filename].ignoreNext > 0:
      #       data.tabs[filename].ignoreNext = data.tabs[filename].ignoreNext - 1

      data.tabs[filename] = ServerTab(path: filename, lang: lang, fileWatched: true)

  echo "index_config open: file read succesfully"
  var sourceLines = source.split(jsNl)

  var name = cstring""
  var argId = cstring""

  if location.isExpanded:
    sourceLines = sourceLines.slice(location.expansionFirstLine - 1, location.expansionLastLine)
    source = sourceLines.join(jsNl) & jsNl
    name = location.functionName
    argId = name
  else:
    name = basename(filename)
    # TODO maybe remove if we don't hit that for some time
    if name == cstring"expanded.nim":
      errorPrint "expanded.nim with isExpanded == false ", filename
      return
    argId = filename

  if editorView == ViewCalltrace:
    name = location.path & cstring":" & location.functionName & cstring"-" & location.key
    argId = name
    sourceLines = sourceLines.slice(location.functionFirst - 1, location.functionLast)
    source = sourceLines.join(jsNl) & jsNl

  main.webContents.send "CODETRACER::" & messagePath, js{
    "argId": argId,
    "value": TabInfo(
      overlayExpanded: -1,
      highlightLine: -1,
      location: location,
      source: source,
      sourceLines: sourceLines,
      received: true,

      name: name,
      path: filename,
      lang: lang
    )
  }

proc save*(filename: cstring, obj: js) =
  let y = yaml.dump(obj, 4)
  fs.writeFile(filename, y, proc(err: js) =
    errorPrint "index: save file error ", err)

proc editorOpen*(main: js, location: types.Location, replay: bool, exe: seq[cstring], lang: Lang, line: int = -1): Future[void] {.async.} =
  await data.open(main, location, ViewSource, "file-loaded", replay, exe, lang, line)

proc openTab*(main: js, location: types.Location, lang: Lang, editorView: EditorView, line: int = -1): Future[void] {.async.} =
  await data.open(main, location, editorView, "tab-load-received", data.replay, data.exe, lang, line)

proc persistConfig*(main: js, name: cstring, layout: cstring): Future[void] {.async.} =
  if not data.config.test:
    let layoutErr = await fsWriteFileWithErr(j(&"{userLayoutDir / $name}.json"), layout)
    if layoutErr.isNone and not main.isNil:
      main.webContents.send "CODETRACER::saved-config"

proc loadFilenames*(paths: seq[cstring], traceFolder: cstring, selfContained: bool): Future[seq[string]] {.async.} =
  # debug "filenames", paths=paths
  var res: seq[string] = @[]
  var repoPathSet: JsAssoc[cstring, bool] = JsAssoc[cstring, bool]{}

  if not selfContained:
    for path in paths:
      try:
        let (stdoutRev, stderrRev, errRev) = await childProcessExec(j(&"git rev-parse --show-toplevel"), js{cwd: path})
        repoPathSet[stdoutRev.trim] = true
      except Exception as e:
        errorPrint "git rev-parse error for ", path, ": ", e.repr
    for path, _ in repoPathSet:
      let (stdout, stderr, err) = await childProcessExec(j(&"git ls-tree HEAD -r --name-only"), js{cwd: path})
      if err.isNil:
        res = res.concat(($stdout).splitLines().mapIt($path & "/" & it))
      else:
        discard
        #res = cast[seq[string]](@[])
        # if not a git repo: just load some files? empty for now
        # for now for self-contained load files from trace
        # TODO discuss
  else:
    # for now assume db-backend, otherwise empty
    if traceFolder.len > 0:
      var pathSet = JsAssoc[cstring, bool]{}
      let tracePathsPath = $traceFolder / "trace_paths.json"
      let (rawTracePaths, err) = await fsReadFileWithErr(cstring(tracePathsPath))
      if err.isNil:
        let tracePaths = cast[seq[cstring]](JSON.parse(rawTracePaths))
        for path in tracePaths:
          pathSet[path] = true
      else:
        # leave pathSet empty
        warnPrint "loadFilenames for self contained trace trying to read ", tracePathsPath, ":", err

      for path, _ in pathSet:
        res.add($path)
    else:
      # leave res empty
      discard
  return res

proc loadSymbols(traceFolder: cstring): Future[seq[Symbol]] {.async.} =
  if traceFolder.len > 0:
    let symbolsPath = $traceFolder / "symbols.json"
    let (rawSymbols, err) = await fsReadFileWithErr(cstring(symbolsPath))
    if err.isNil:
      return ($rawSymbols).parseJson.to(seq[Symbol])
    else:
      # leave pathSet empty
      errorPrint "loadSymbols for self contained trace trying to read from ", symbolsPath, ": ", err
      return cast[seq[Symbol]](@[])


proc sendFilenames*(main: js, paths: seq[cstring], traceFolder: cstring, selfContained: bool) {.async.} =
  let filenames = await loadFilenames(paths, traceFolder, selfContained)

  main.webContents.send "CODETRACER::filenames-loaded", js{filenames: filenames}

proc sendSymbols*(main: js, traceFolder: cstring) {.async.} =
  try:
    let symbols = await loadSymbols(traceFolder)

    main.webContents.send "CODETRACER::symbols-loaded", js{symbols: symbols}
  except:
    errorPrint "loading symbols: ", getCurrentExceptionMsg()

proc initDebugger*(main: js, trace: Trace, config: Config, helpers: Helpers) {.async.} =
  let binary = if "/" in $trace.program: j(($trace.program).rsplit("/", 1)[1]) else: trace.program
  await debugger.configure(
    ConfigureArg(
      lang: trace.lang,
      trace: CoreTrace(
        replay: true,
        binary: binary,
        program: @[trace.program].concat(trace.args),
        paths: trace.sourceFolders,
        traceID: trace.id,
        calltrace: config.calltrace and trace.calltrace,
        preloadEnabled: config.flow.enabled and trace.lang != LangPython,
        callArgsEnabled: config.callArgs,
        traceEnabled: config.trace,
        historyEnabled: config.history,
        eventsEnabled: config.events,
        telemetry: config.telemetry,
        imported: trace.imported,
        test: config.test,
        debug: config.debug,
        traceOutputFolder: trace.outputFolder)))
  debugPrint "index: debugger start"
  await debugger.start(EmptyArg())
  console.timeLog(cstring"index: starting backend")
  debugPrint ""
  debugPrint "========================"
  debugPrint ""
  main.webContents.send "CODETRACER::debugger-started", js{}

let fileIcons = require("@exuanbo/file-icons-js")

proc getClass(icons: js, name: cstring, options: js): Future[cstring] {.importjs: "#.getClass(#,#)".}

proc stripLastChar*(text: cstring, c: cstring): cstring =
  if cstring($(text[text.len - 1])) == c:
    return cstring(($(text)).substr(0, text.len - 2))
  else:
    return text

proc loadFile(
    path: cstring,
    depth: int,
    index: int,
    parentIndices: seq[int],
    traceFilesPath: cstring,
    selfContained: bool): Future[CodetracerFile] {.async.} =
  var data: js
  var res: CodetracerFile

  if path.len == 0:
    return res

  let realPath = if not selfContained:
      path
    else:
      # https://stackoverflow.com/a/39836259/438099
      # see here ^:
      # join combines two absolute paths /a and /b into /a/b
      # resolve returns just /b
      # here we want the first behavior!
      nodePath.join(traceFilesPath, path)

  # debugPrint "loadFile ", path, " ", traceFilesPath, " ", selfContained
  # debugPrint "  real path ", realPath
  try:
    data = await cast[Future[js]](fsAsync.lstat(realPath))
  except:
    errorPrint "lstat error: ", getCurrentExceptionMsg()
    return res

  if path.len == 0:
    return res

  let strippedPath = path.stripLastChar(cstring"/")
  let subParts = strippedPath.split(cstring"/")
  let name = subParts[^1]

  # TODO configure?

  # name == j".git" or name == j".tup" or name == j".keep" or
  # name == j".venv"
  # j".bin"

  # Viktor: This filter need to be disabled for the component to be tested.
  # Activate filter when fix issue: https://gitlab.com/metacraft-labs/code-tracer/CodeTracer/-/issues/565
  # if name.len > 0 and (name == j"public" or name == j"build-debug" or name[0] == '.' or name.slice(-2) == j".o" or
  #    name == j"test" or name == j"libs" or name == j"csources" or name == j"dist" or name == j"tests"):
  #   return res

  if cast[bool](data.isDirectory()):
    try:
      # returning just the filenames, not full paths!
      let files = await cast[Future[seq[cstring]]](fsAsync.readdir(realPath))
      let depthLimit = subParts.len() - 2
      res = CodetracerFile(
        text: name,
        children: @[],
        state: js{opened: depth < depthLimit},
        index: index,
        parentIndices: parentIndices,
        original: CodetracerFileData(text: name, path: path))

      if depth >= depthLimit:
        res.state.opened = false
        if files.len > 0:
          res.children.add(CodetracerFile(text: "Loading..."))
        return res

      if files.len > 0:
        var newParentIndices = parentIndices
        newParentIndices.add(index)
        for fileIndex, file in files:
          var child = await loadFile(
            nodePath.join(path, file),
            depth + 1,
            fileIndex,
            newParentIndices,
            traceFilesPath,
            selfContained)
          if not child.isNil:
            res.children.add(child)
    except:
      errorPrint "probably directory error ", getCurrentExceptionMsg()
      res = CodetracerFile(
        text: name,
        children: @[],
        state: js{opened: true},
        original: CodetracerFileData(text: name, path: path))

  elif cast[bool](data.isFile()) or cast[bool](data.isSymbolicLink()):
    let icon = await fileIcons.getClass(name, js{})
    res = CodetracerFile(
      text: name,
      children: @[],
      icon: $icon,
      index: index,
      parentIndices: parentIndices,
      original: CodetracerFileData(text: name, path: path))

  else:
    res = CodetracerFile(
      text: name,
      children: @[],
      state: js{opened: true},
      original: CodetracerFileData(text: name, path: path))

  res.toJs.path = path

  return res


proc loadFunctions*(path: cstring): Future[seq[Function]] {.async.} =
  let (raw, err) = await fsReadFileWithErr(path)
  if err.isNil:
    return cast[seq[Function]](Json.parse(raw))
  else:
    return cast[seq[Function]](@[])

proc loadPathContentPartially*(path: cstring, index: int, parentIndices: seq[int], traceFilesPath: cstring, selfContained: bool): Future[CodetracerFile] {.async.} =
  let depth = 0

  return await loadFile(path, depth, index, parentIndices, traceFilesPath, selfContained)

proc loadFilesystem*(paths: seq[cstring], traceFilesPath: cstring, selfContained: bool): Future[CodetracerFile] {.async.}=
  # not a real file, but artificial(root):
  #   a group of the source folders,
  #   which might not be siblings
  var folderGroup = CodetracerFile(
    text: cstring"source folders",
    children: @[],
    state: js{opened: true},
    index: 0,
    parentIndices: @[],
    original: CodetracerFileData(
      text: cstring"source folders",
      path: cstring""))

  # debugPrint "loadFilesystem ", paths, " ", traceFilesPath, " ", selfContained

  var parentIndices: seq[int] = @[]
  for index, path in paths:
    let file = await loadPathContentPartially(path, index, parentIndices, traceFilesPath, selfContained)
    if not file.isNil:
      folderGroup.children.add(file)

  return folderGroup

proc sendFilesystem*(main: js, paths: seq[cstring], traceFilesPath: cstring, selfContained: bool) {.async.} =
  let folders = await loadFilesystem(paths, traceFilesPath, selfContained)

  main.webContents.send "CODETRACER::filesystem-loaded", js{ folders: folders }

proc getSave*(folders: seq[cstring], test: bool): Future[Save] {.async.} =
  # if test:
  # TODO: think about save functionality/projects
  var save = Save(project: Project(), files: @[], id: -1)
  return save
proc saveSave*(data: ServerData) {.async.} =
  let path = j(&"{app}/saves/save-{data.save.id}.json")
  await fsWriteFile(path, JSON.stringify(data.save.toJs))


proc nativeLoadInstructions*(data: var ServerData, functionLocation: FunctionLocation): Future[TabInfo] {.async.} =
  let instructions = await data.loadAsm(functionLocation)
  return TabInfo(
    name: functionLocation.name,
    offset: 0,
    # loading: false,
    error: cstring"",
    # view: ViewInstructions,
    instructions: instructions,
    received: true,
    lang: LangAsm)


proc loadAsm*(data: ServerData, functionLocation: FunctionLocation): Future[Instructions] {.async.} =
  var res: Instructions
  let name = fmt"{functionLocation.path}:{functionLocation.name}:{functionLocation.key}"
  # we use gdb, as we already use the commands, we can pass to disassemble
  # still, keep in mind licensing
  # if we use objdump, we can use `-drwC and load the `.o` object for the path of the function
  # for faster loading (objdump for the whole binary takes more time)
  # thanks to Bastien Léonard and Peter Cordes https://stackoverflow.com/a/1289907/438099
  # await data.loadObjdumpAsm(data.trace.binary)
  if not data.asmFunctions.hasKey(name) or functionLocation.forceReload:
    res = await debugger.loadAsmFunction(functionLocation)
    data.asmFunctions[name] = res
  else:
    res = data.asmFunctions[name]
  return res

# I planned to load directly all assembly for a file
# but there is a problem with that:
#   it's slow with gdb because I have to call it a lot: once for each function
#   it can be fast with objdump and also it can add some C line
#   but for big binaries it's very slow with objdump and there doesn't seem to be
#   a good way to filter it except grepping, or knowing address range
#   even reading DWARF would be probably slow for big binaries
#   just load with gdb the current function TODO: C lines
proc nimLoadLowLevel*(data: var ServerData, name: cstring, view: EditorView): Future[TabInfo] {.async.} =
  var res: TabInfo
  var error = cstring""
  case view:
  of ViewTargetSource:
    var rawSource = cstring""
    var path = name
    if data.nimCSources.hasKey(path):
      rawSource = data.nimCSources[path]
    else:
      var err: js
      (rawSource, err) = await fsReadFileWithErr(path)
      if not err.isNone:
        error = cstring"cant find " & path
      else:
        data.nimCSources[path] = rawSource

    let sourceLines = rawSource.split(jsNl)
    res = TabInfo(
      source: rawSource,
      sourceLines: sourceLines,
      lang: LangC,
      name: name,
      error: error)
  of ViewInstructions:
    var instructions: Instructions
    instructions = await data.loadAsm(FunctionLocation(name: name))
    res = TabInfo(
      name: name,
      instructions: instructions,
      error: instructions.error,
      lang: LangAsm)
  else:
    discard
  return res


proc loadTrace*(data: var ServerData, main: js, trace: Trace, config: Config, helpers: Helpers): Future[void] {.async.} =
  # set title
  when not defined(server):
    main.setTitle(trace.program)

  let traceFilesPath = cstring($trace.outputFolder / "files")
  discard sendFilenames(main, trace.sourceFolders, trace.outputFolder, trace.imported)
  discard sendFilesystem(main, trace.sourceFolders, traceFilesPath, trace.imported)
  discard sendSymbols(main, trace.outputFolder)

  var functions = await loadFunctions(cstring($trace.outputFolder / "function_index.json"))
  var save = await getSave(trace.sourceFolders, config.test)
  data.save = save

  let dir = getHomeDir() / ".config" / "codetracer"
  let configFile = dir / "dont_ask_again.txt"

  let dontAskAgain = fs.existsSync(configFile)

  main.webContents.send "CODETRACER::trace-loaded", js{
    trace: trace,
    # tags: tags,
    functions: functions,
    save: save,
    dontAskAgain: dontAskAgain
  }


proc startShellUi*(main: js, config: Config): Future[void] {.async.} =
  debugPrint "start shell ui"
  main.webContents.send "CODETRACER::start-shell-ui", js{config: config}

proc findConfig*(folder: cstring, configPath: cstring): cstring =
  var current = folder
  var config = false
  while true:
    let path = nodePath.join(current, configPath)
    if fs.existsSync(path):
      return path
    else:
      if config:
        return j""
      current = nodePath.dirname(current)
      if current == j"/":
        current = userConfigDir
        config = true

proc loadConfig*(main: js, startOptions: StartOptions, home: cstring = j"", send: bool = false): Future[Config] {.async.} =
  # loads config
  var file = findConfig(startOptions.folder, configPath)
  if file.len == 0:
    file = userConfigDir / configPath

    let errMkdir = await fsMkdirWithErr(cstring(userConfigDir), js{recursive: true})
    if not errMkdir.isNil:
      errorPrint "mkdir for config folder error: exiting: ", errMkdir
      quit(1)
    # thanks to Peter for the good advice to use copyFile instead of `cp`
    # works around an issue i had with wrong libc version and nix
    # and more clean
    let errCopy = await fsCopyFileWithErr(
      cstring(fmt"{configDir / defaultConfigPath}"),
      cstring(fmt"{userConfigDir / configPath}"));
     # cstring(&"cp {configDir}{defaultLayoutPath} {filename}"))
    if not errCopy.isNil:
      errorPrint "can't copy .config.yaml to user config dir:"
      errorPrint "  tried to copy from: ", cstring(fmt"{configDir / defaultConfigPath}")
      errorPrint "  to: ", fmt"{userConfigDir / configPath}"
      quit(1)

  # TODO: maybe remove config test logic?
  # if startOptions.inTest:
    # file = nodePath.join(j(codetracerTestDir), j(testConfigPath))
  infoPrint "index: load config ", file
  let (s, err) = await fsreadFileWithErr(file)
  if not err.isNil:
    errorPrint "read config file error: ", err
    quit(1)
  try:
    let config = cast[Config](yaml.load(s))
    config.shortcutMap = initShortcutMap(config.bindings)
    return config
  except:
    errorPrint "load config or init shortcut map error: ", getCurrentExceptionMsg()
    quit(1)

proc asyncShowOpenDialog(dialog: js, main: js, options: js): Future[seq[cstring]] =
  var promise = newPromise() do (resolve: proc(response: seq[cstring])):
    dialog.showOpenDialog(main, options, resolve)
  return promise

proc loadLayoutConfig*(main: js, filename: string): Future[js] {.async.} =
  # debug "layout", filename=filename
  # await fsWriteFile(cstring"index_log", cstring(filename))
  let (data, err) = await fsreadFileWithErr(j(filename))
  if err.isNil:
    let config = JSON.parse(data)
    return config
  else:
    let directory = filename.parentDir
    let errMkdir = await fsMkdirWithErr(cstring(directory), js{recursive: true})
    if not errMkdir.isNil:
      errorPrint "mkdir for layout config folder error: exiting: ", errMkdir
      quit(1)
    # thanks to Peter for the good advice to use copyFile instead of `cp`
    # works around an issue i had with wrong libc version and nix
    # and more clean
    let errCopy = await fsCopyFileWithErr(
      cstring(fmt"{configDir / defaultLayoutPath}"),
      cstring(filename));
     # cstring(&"cp {configDir}{defaultLayoutPath} {filename}"))
    if errCopy.isNil:
      return await loadLayoutConfig(main, filename)
    else:
      errorPrint "index: load layout config error: ", errCopy
      quit(1)

proc loadHelpers*(main: js, filename: string): Future[Helpers] {.async.} =
  var file = j(userConfigDir & filename)
  let (raw, err) = await fsReadFileWithErr(file)
  if not err.isNil:
    return JsAssoc[cstring, Helper]{}
  var res = cast[Helpers](yaml.load(raw)[j"helpers"])
  return res
