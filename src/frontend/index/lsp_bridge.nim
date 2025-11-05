import
  std/[asyncjs, jsffi, strformat, strutils],
  ../../lsp/bridge_reduced,
  ../lib/electron_lib,
  ../../common/ct_logging

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

proc toDisplayString(value: JsObject): cstring {.importjs: "(function(value){ try { if (value === undefined) return 'undefined'; if (typeof value === 'string') return value; return JSON.stringify(value); } catch (err) { return String(value); } })(#)".}

proc trimNotificationBuffer() =
  if lspNotifications.len > notificationHistoryLimit:
    let excess = lspNotifications.len - notificationHistoryLimit
    lspNotifications = lspNotifications[0 ..< excess - 1]

proc ensureNotificationHandler() =
  if not lspNotificationHandler.isNil:
    return
  lspNotificationHandler = proc(methodName, params: JsObject) {.closure.} =
    let methodText = toDisplayString(methodName)
    let payloadText = toDisplayString(params)
    debugPrint fmt"index:lsp notification received: {methodText}"
    lspNotifications.add(fmt"{methodText}: {payloadText}")
    trimNotificationBuffer()
  registerLspNotificationHandler(lspNotificationHandler)

proc resetNotificationHandler() =
  if lspNotificationHandler.isNil:
    return
  clearLspNotificationHandlers()
  lspNotificationHandler = nil
  lspNotifications.setLen(0)

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

proc lspBridgeUrl*(): string =
  "ws://127.0.0.1:" & $lspBridgePort & lspBridgePath

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
    setEnv("CODETRACER_LSP_PORT", $port)
    setEnv("CODETRACER_LSP_PATH", path)
    setEnv("CODETRACER_LSP_URL", lspBridgeUrl())
    infoPrint fmt"index:lsp bridge listening on {lspBridgeUrl()}"
  except CatchableError:
    lspBridgeHandle = nil
    errorPrint "index:lsp bridge failed to start: ", getCurrentExceptionMsg()
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
  lspBridgePort = defaultLspPort
  lspBridgePath = defaultLspPath
  setEnv("CODETRACER_LSP_URL", "")
  setEnv("CODETRACER_LSP_PORT", "")
  setEnv("CODETRACER_LSP_PATH", "")
  infoPrint "index:lsp bridge stopped"
  resetNotificationHandler()
