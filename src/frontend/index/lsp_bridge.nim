import
  std/[asyncjs, jsffi, strformat, strutils],
  ../../lsp/bridge_reduced,
  ../lib/electron_lib,
  ../../common/ct_logging,
  electron_vars

const
  defaultLspPort = 3100
  defaultLspPath = "/lsp"
  notificationHistoryLimit = 50

var
  lspBridgeHandle: JsObject = nil
  lspBridgePort* = defaultLspPort
  lspBridgePath* = defaultLspPath
  lspBridgeStarting = false
  lspNotificationHandler: LspNotificationHandler = nil
  lspNotifications*: seq[string] = @[]
  lastBridgeError* = ""

proc newObject(): JsObject {.importjs: "({})".}
proc setField(target: JsObject; name: cstring; value: JsObject) {.importjs: "#[#] = #".}
proc newArray(): JsObject {.importjs: "([])".}
proc push(array: JsObject; value: JsObject) {.importjs: "#.push(#)".}
proc boolToJs(flag: bool): JsObject {.importjs: "(# ? true : false)".}

proc toDisplayString(value: JsObject): cstring {.importjs: "(function(value){ try { if (value === undefined) return 'undefined'; if (typeof value === 'string') return value; return JSON.stringify(value); } catch (err) { return String(value); } })(#)".}
proc windowIsDestroyed(win: JsObject): bool {.importjs: "((w)=> (w && typeof w.isDestroyed === 'function') ? w.isDestroyed() : false)(#)".}
proc windowWebContents(win: JsObject): JsObject {.importjs: "((w)=> (w ? w.webContents : undefined))(#)".}
proc webContentsIsDestroyed(contents: JsObject): bool {.importjs: "((c)=> (c && typeof c.isDestroyed === 'function') ? c.isDestroyed() : false)(#)".}

when not defined(ctRenderer):
  proc createWs(url: cstring): JsObject {.importjs: "new (require('ws'))(#, 'jsonrpc')".}
  proc wsOnOpen(ws: JsObject; handler: proc () {.closure.}) {.importjs: "#.on('open', #)".}
  proc wsOnMessage(ws: JsObject; handler: proc (data: JsObject) {.closure.}) {.importjs: "#.on('message', #)".}
  proc wsOnError(ws: JsObject; handler: proc (err: JsObject) {.closure.}) {.importjs: "#.on('error', #)".}
  proc wsSendJson(ws: JsObject; payload: JsObject) {.importjs: "#.send(JSON.stringify(#))".}
  proc wsClose(ws: JsObject) {.importjs: "#.close()".}
  proc jsValueToString(value: JsObject): cstring {.importjs: "String(#)".}

proc lspBridgeUrl*(): string =
  "ws://127.0.0.1:" & $lspBridgePort & lspBridgePath

proc buildStatusPayload(running: bool): JsObject =
  result = newObject()
  let urlText = if running: lspBridgeUrl() else: ""
  setField(result, "url", toJs(urlText.cstring))
  setField(result, "running", boolToJs(running))
  if lastBridgeError.len > 0:
    setField(result, "error", toJs(lastBridgeError.cstring))
  if lspNotifications.len > 0:
    let notifArray = newArray()
    for note in lspNotifications:
      push(notifArray, toJs(note.cstring))
    setField(result, "notifications", notifArray)

proc sendLspStatusToRenderer* =
  let windowRef = electron_vars.mainWindow
  if windowRef.isNil or windowIsDestroyed(windowRef):
    return
  let contents = windowWebContents(windowRef)
  if contents.isNil or webContentsIsDestroyed(contents):
    return
  let payload = buildStatusPayload(not lspBridgeHandle.isNil)
  try:
    contents.send(cstring"CODETRACER::lsp-url", payload)
  except CatchableError:
    warnPrint "index:lsp failed to send status to renderer: ", getCurrentExceptionMsg()


proc trimNotificationBuffer() =
  if lspNotifications.len > notificationHistoryLimit:
    let startIndex = lspNotifications.len - notificationHistoryLimit
    lspNotifications = lspNotifications[startIndex ..< lspNotifications.len]

proc ensureNotificationHandler() =
  if not lspNotificationHandler.isNil:
    return
  lspNotificationHandler = proc(methodName, params: JsObject) {.closure.} =
    let methodText = toDisplayString(methodName)
    let payloadText = toDisplayString(params)
    debugPrint fmt"index:lsp notification received: {methodText}"
    lspNotifications.add(fmt"{methodText}: {payloadText}")
    trimNotificationBuffer()
    sendLspStatusToRenderer()
  registerLspNotificationHandler(lspNotificationHandler)

proc resetNotificationHandler() =
  if lspNotificationHandler.isNil:
    return
  clearLspNotificationHandlers()
  lspNotificationHandler = nil
  lspNotifications.setLen(0)
  sendLspStatusToRenderer()

proc envValue(name: cstring): string =
  let raw = nodeProcess.env[name]
  if raw.isNil:
    return ""
  $raw

proc setEnv(name, value: string) =
  nodeProcess.env[name.cstring] = value.cstring

proc normalizePath(path: string): string =
  if path.len == 0:
    return defaultLspPath
  if path[0] == '/':
    return path
  '/' & path

proc parsePort(value: string): int =
  if value.len == 0:
    return defaultLspPort
  try:
    let parsed = value.parseInt()
    if parsed <= 0 or parsed >= 65536:
      warnPrint "index:lsp invalid port provided: ", value
      return defaultLspPort
    parsed
  except CatchableError:
    warnPrint "index:lsp failed to parse port value: ", value
    defaultLspPort


proc getField(target: JsObject; name: cstring): JsObject {.importjs: "#[#]".}
proc serverClose(server: JsObject) {.importjs: "#.close()".}
proc wssClose(wss: JsObject) {.importjs: "#.close()".}

proc startLspBridge*(lsCommand: string = ""; lsCwd: string = ""): Future[void] {.async.} =
  if not lspBridgeHandle.isNil:
    return
  if lspBridgeStarting:
    return
  lspBridgeStarting = true
  var port = parsePort(envValue(cstring"CODETRACER_LSP_PORT"))
  var path = normalizePath(envValue(cstring"CODETRACER_LSP_PATH"))
  var command = lsCommand
  let commandOverride = envValue(cstring"CODETRACER_LS_COMMAND")
  if commandOverride.len > 0:
    command = commandOverride
  var commandDir = lsCwd
  let cwdOverride = envValue(cstring"CODETRACER_LS_CWD")
  if cwdOverride.len > 0:
    commandDir = cwdOverride
  if path.len == 0:
    path = defaultLspPath
  ensureNotificationHandler()
  try:
    let handle = await startBridge(cint(port), path, command, commandDir)
    lspBridgeHandle = handle
    lspBridgePort = port
    lspBridgePath = path
    lastBridgeError = ""
    setEnv("CODETRACER_LSP_PORT", $port)
    setEnv("CODETRACER_LSP_PATH", path)
    setEnv("CODETRACER_LSP_URL", lspBridgeUrl())
    infoPrint fmt"index:lsp bridge listening on {lspBridgeUrl()}"
    sendLspStatusToRenderer()
  except CatchableError:
    lspBridgeHandle = nil
    lastBridgeError = getCurrentExceptionMsg()
    errorPrint "index:lsp bridge failed to start: ", lastBridgeError
    sendLspStatusToRenderer()
    raise
  finally:
    lspBridgeStarting = false

proc stopLspBridge* =
  if lspBridgeHandle.isNil:
    return
  let server = getField(lspBridgeHandle, "server")
  let wss = getField(lspBridgeHandle, "wss")
  lspBridgeHandle = nil
  try:
    if not wss.isNil:
      wssClose(wss)
  except CatchableError:
    warnPrint "index:lsp bridge websocket close error: ", getCurrentExceptionMsg()
  try:
    if not server.isNil:
      serverClose(server)
  except CatchableError:
    warnPrint "index:lsp bridge server close error: ", getCurrentExceptionMsg()
  lastBridgeError = ""
  lspBridgePort = defaultLspPort
  lspBridgePath = defaultLspPath
  setEnv("CODETRACER_LSP_URL", "")
  setEnv("CODETRACER_LSP_PORT", "")
  setEnv("CODETRACER_LSP_PATH", "")
  infoPrint "index:lsp bridge stopped"
  resetNotificationHandler()
  sendLspStatusToRenderer()

proc sendLspProbe*(payload: JsObject) =
  when defined(ctRenderer):
    discard
  else:
    if lspBridgeHandle.isNil:
      warnPrint "index:lsp probe skipped because bridge is not running"
      return
    let url = lspBridgeUrl()
    var completed = false
    let ws = createWs(url.cstring)
    wsOnOpen(ws, proc () {.closure.} =
      infoPrint fmt"index:lsp probe sending payload to {url}"
      wsSendJson(ws, payload)
    )
    wsOnMessage(ws, proc (data: JsObject) {.closure.} =
      if completed:
        return
      completed = true
      infoPrint fmt"index:lsp probe response: {jsValueToString(data)}"
      wsClose(ws)
    )
    wsOnError(ws, proc (err: JsObject) {.closure.} =
      if completed:
        return
      completed = true
      warnPrint "index:lsp probe error: ", jsValueToString(err)
      wsClose(ws)
    )

proc onLspGetUrl*(sender: JsObject, response: JsObject) {.async.} =
  sendLspStatusToRenderer()
