## Leaner Nim version of the LSP bridge with fewer dedicated JS bindings.
## Compile with: nim js -d:nodejs bridge_reduced.nim

import std/jsffi
import std/asyncjs

proc requireModule(name: cstring): JsObject {.importjs: "__bridgeRequire(#)".}
proc field(target: JsObject; name: cstring): JsObject {.importjs: "#[#]".}
proc setField(target: JsObject; name: cstring; value: JsObject) {.importjs: "#[#] = #".}
proc newObject(): JsObject {.importjs: "({})".}
proc call0(fn: JsObject): JsObject {.importjs: "#()".}
proc call1(fn: JsObject; arg: JsObject): JsObject {.importjs: "#(#)".}
proc construct1(ctor: JsObject; arg: JsObject): JsObject {.importjs: "new #(#)".}
proc toJs(str: cstring): JsObject {.importjs: "#".}
proc spawnDefault(child: JsObject; cmd: cstring): JsObject {.importjs: "#.spawn(#, [], {stdio: ['pipe', 'pipe', 'pipe']})".}
proc spawnDefaultCwd(child: JsObject; cmd, cwd: cstring): JsObject {.importjs: "#.spawn(#, [], {stdio: ['pipe', 'pipe', 'pipe'], cwd: #})".}
proc spawnNoArgs(child: JsObject; cmd: cstring): JsObject {.importjs: "#.spawn(#, [], {stdio: ['pipe', 'pipe', 'pipe']})".}
proc spawnNoArgsCwd(child: JsObject; cmd, cwd: cstring): JsObject {.importjs: "#.spawn(#, [], {stdio: ['pipe', 'pipe', 'pipe'], cwd: #})".}
proc onEvent(target: JsObject; event: cstring; handler: proc (arg: JsObject) {.closure.}) {.importjs: "#.on(#, #)".}
proc onExit(target: JsObject; handler: proc (code, signal: JsObject) {.closure.}) {.importjs: "#.on('exit', #)".}
proc onClose(target: JsObject; handler: proc () {.closure.}) {.importjs: "#.on('close', #)".}
proc terminate(ws: JsObject) {.importjs: "#.terminate()".}
proc kill(child: JsObject) {.importjs: "#.kill()".}
proc isKilled(child: JsObject): bool {.importjs: "#.killed".}
proc toUtf8String(buf: JsObject): JsObject {.importjs: "#.toString('utf8')".}
proc readerListen(reader: JsObject; handler: proc(message: JsObject) {.closure.}) {.importjs: "#.listen(#)".}
proc logError(msg: JsObject) {.importjs: "console.error(#)".}
proc logWarn2(msg: JsObject; detail: JsObject) {.importjs: "console.warn(#, #)".}
proc logInfo(msg: JsObject) {.importjs: "console.log(#)".}
proc listenWithCallback(server: JsObject; port: cint; cb: proc () {.closure.}) {.importjs: "#.listen(#, #)".}
proc listenAsync(server: JsObject; port: cint): Future[void] {.async.} =
  await newPromise(proc (resolve: proc () {.closure.}) {.closure.} =
    listenWithCallback(server, port, resolve)
  )
proc createConnection(server: JsObject; reader, writer: JsObject; disposer: proc () {.closure.}): JsObject {.importjs: "#.createConnection(#, #, #)".}
proc forwardConnections(server: JsObject; a, b: JsObject) {.importjs: "#.forward(#, #)".}
proc unusedOnNotification(connection: JsObject; handler: proc(methodName, params: JsObject) {.closure.}): JsObject {.importjs: "#.onNotification(#)".}

type
  LspNotificationHandler* = proc(methodName, params: JsObject) {.closure.}

var
  notificationHandlers*: seq[LspNotificationHandler] = @[]

proc registerLspNotificationHandler*(handler: LspNotificationHandler) = discard
proc clearLspNotificationHandlers* = discard
proc dispatchNotification(methodName, params: JsObject) = discard

const
  defaultRustAnalyzerCmd = "rust-analyzer"

proc startBridge*(port: cint = 3000; pathName: string = "/lsp"; lsCommand: string = ""; lsCwd: string = ""): Future[JsObject] {.async, exportc.} =
  let http = require("http")
  let wsModule = require("ws")
  let childProcess = require("child_process")
  let rpc = require("vscode-ws-jsonrpc")
  let rpcServer = require("vscode-ws-jsonrpc/server")
  let rpcStreams = require("vscode-jsonrpc/node.js")

  let server = call0(field(http, "createServer"))
  let commandToRun =
    if lsCommand.len == 0: defaultRustAnalyzerCmd else: lsCommand
  let commandCwd = lsCwd
  logInfo(toJs(("Spawning language server: " & commandToRun).cstring))
  let options = newObject()
  setField(options, "server", server)
  setField(options, "path", toJs(pathName.cstring))
  let wss = construct1(field(wsModule, "WebSocketServer"), options)

  onEvent(wss, "connection", proc (wsConn: JsObject) {.closure.} =
    let socket = call1(field(rpc, "toSocket"), wsConn)
    let reader = construct1(field(rpc, "WebSocketMessageReader"), socket)
    let writer = construct1(field(rpc, "WebSocketMessageWriter"), socket)

    let ls =
      if lsCommand.len == 0:
        if commandCwd.len == 0:
          spawnDefault(childProcess, commandToRun.cstring)
        else:
          spawnDefaultCwd(childProcess, commandToRun.cstring, commandCwd.cstring)
      else:
        if commandCwd.len == 0:
          spawnNoArgs(childProcess, commandToRun.cstring)
        else:
          spawnNoArgsCwd(childProcess, commandToRun.cstring, commandCwd.cstring)
    # onEvent(field(ls, "stdout"), "data", proc (chunk: JsObject) {.closure.} =
    #   logInfo(toUtf8String(chunk))
    # )
    # onEvent(field(ls, "stderr"), "data", proc (chunk: JsObject) {.closure.} =
    #   logError(toUtf8String(chunk))
    # )
    # onExit(ls, proc (codeObj: JsObject; signalObj: JsObject) {.closure.} =
    #   logWarn2(toJs("Language server exited with code"), codeObj)
    #   logWarn2(toJs("Language server exit signal"), signalObj)
    # )
    let lsReader = construct1(field(rpcStreams, "StreamMessageReader"), field(ls, "stdout"))
    let lsWriter = construct1(field(rpcStreams, "StreamMessageWriter"), field(ls, "stdin"))

    let clientConnection = createConnection(rpcServer, reader, writer, proc () {.closure.} =
      terminate(wsConn)
    )
    let serverConnection = createConnection(rpcServer, lsReader, lsWriter, proc () {.closure.} =
      if not isKilled(ls):
        kill(ls)
    )

    forwardConnections(rpcServer, clientConnection, serverConnection)

    onClose(wsConn, proc () {.closure.} =
      if not isKilled(ls):
        kill(ls)
    )
  )

  await listenAsync(server, port)
  echo "LSP bridge listening on ws://localhost:" & $port & pathName

  let result = newObject()
  setField(result, "server", server)
  setField(result, "wss", wss)
  return result
