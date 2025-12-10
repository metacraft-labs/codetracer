import
  std/[asyncjs, jsffi, strformat, strutils, tables],
  ../../lsp/bridge_reduced,
  ../lib/electron_lib,
  ../../common/ct_logging,
  electron_vars

const
  rustLspKind* = "rust"
  rubyLspKind* = "ruby"
  notificationHistoryLimit = 50

type
  BridgeConfig = object
    kind: string
    defaultPort: int
    defaultPath: string
    defaultCommand: string
    envPort: string
    envPath: string
    envUrl: string
    envCommand: string
    envCwd: string

  BridgeState = ref object
    handle: JsObject
    port: int
    path: string
    starting: bool
    lastBridgeError: string

let configuredBridges = [
  BridgeConfig(
    kind: rustLspKind,
    defaultPort: 3100,
    defaultPath: "/lsp",
    defaultCommand: "rust-analyzer",
    envPort: "CODETRACER_LSP_PORT",
    envPath: "CODETRACER_LSP_PATH",
    envUrl: "CODETRACER_LSP_URL",
    envCommand: "CODETRACER_LS_COMMAND",
    envCwd: "CODETRACER_LS_CWD"),
  BridgeConfig(
    kind: rubyLspKind,
    defaultPort: 3110,
    defaultPath: "/ruby-lsp",
    defaultCommand: "ruby-lsp",
    envPort: "CODETRACER_RUBY_LSP_PORT",
    envPath: "CODETRACER_RUBY_LSP_PATH",
    envUrl: "CODETRACER_RUBY_LSP_URL",
    envCommand: "CODETRACER_RUBY_LS_COMMAND",
    envCwd: "CODETRACER_RUBY_LS_CWD")
]

var
  bridgeConfigs = initTable[string, BridgeConfig]()
  bridgeStates = initTable[string, BridgeState]()
  lspNotificationHandler: LspNotificationHandler = nil
  lspNotifications*: seq[string] = @[]

for cfg in configuredBridges:
  bridgeConfigs[cfg.kind] = cfg

proc newObject(): JsObject {.importjs: "({})".}
proc setField(target: JsObject; name: cstring; value: JsObject) {.importjs: "#[#] = #".}
proc newArray(): JsObject {.importjs: "([])".}
proc push(array: JsObject; value: JsObject) {.importjs: "#.push(#)".}
proc boolToJs(flag: bool): JsObject {.importjs: "(# ? true : false)".}

proc toDisplayString(value: JsObject): cstring {.importjs: "(function(value){ try { if (value === undefined) return 'undefined'; if (typeof value === 'string') return value; return JSON.stringify(value); } catch (err) { return String(value); } })(#)".}
proc toCStringValue(value: JsObject): cstring {.importjs: "String(#)".}
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

proc getBridgeConfig(kind: string): BridgeConfig =
  if bridgeConfigs.hasKey(kind):
    bridgeConfigs[kind]
  else:
    bridgeConfigs[rustLspKind]

proc getBridgeState(kind: string): BridgeState =
  if bridgeStates.hasKey(kind):
    return bridgeStates[kind]
  let cfg = getBridgeConfig(kind)
  let state = BridgeState(
    handle: nil,
    port: cfg.defaultPort,
    path: cfg.defaultPath,
    starting: false,
    lastBridgeError: "")
  bridgeStates[kind] = state
  state

proc lspBridgeUrl(kind: string): string =
  let state = getBridgeState(kind)
  "ws://127.0.0.1:" & $state.port & state.path

proc buildStatusPayload(kind: string; running: bool): JsObject =
  let state = getBridgeState(kind)
  result = newObject()
  let urlText = if running: lspBridgeUrl(kind) else: ""
  setField(result, "url", toJs(urlText.cstring))
  setField(result, "running", boolToJs(running))
  setField(result, "kind", toJs(kind.cstring))
  if state.lastBridgeError.len > 0:
    setField(result, "error", toJs(state.lastBridgeError.cstring))
  if lspNotifications.len > 0:
    let notifArray = newArray()
    for note in lspNotifications:
      push(notifArray, toJs(note.cstring))
    setField(result, "notifications", notifArray)

proc sendLspStatusToRenderer*(kind: string = "") =
  when defined(server):
    # for now not supported on server
    return
  if kind.len == 0:
    for cfg in configuredBridges:
      sendLspStatusToRenderer(cfg.kind)
    return
  let windowRef = electron_vars.mainWindow
  if windowRef.isNil or windowIsDestroyed(windowRef):
    return
  let contents = windowWebContents(windowRef)
  if contents.isNil or webContentsIsDestroyed(contents):
    return
  let state = getBridgeState(kind)
  let payload = buildStatusPayload(kind, not state.handle.isNil)
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
  # Bridge stays transport-only; renderer handles notifications directly.
  registerLspNotificationHandler(nil)

proc resetNotificationHandler() =
  lspNotificationHandler = nil
  lspNotifications.setLen(0)

proc envValue(name: string): string =
  let raw = nodeProcess.env[name.cstring]
  if raw.isNil:
    return ""
  $raw

proc setEnv(name, value: string) =
  nodeProcess.env[name.cstring] = value.cstring

proc normalizePath(path: string; defaultValue: string): string =
  if path.len == 0:
    return defaultValue
  if path[0] == '/':
    return path
  '/' & path

proc parsePort(value: string; defaultValue: int): int =
  if value.len == 0:
    return defaultValue
  try:
    let parsed = value.parseInt()
    if parsed <= 0 or parsed >= 65536:
      warnPrint "index:lsp invalid port provided: ", value
      return defaultValue
    parsed
  except CatchableError:
    warnPrint "index:lsp failed to parse port value: ", value
    defaultValue


proc getField(target: JsObject; name: cstring): JsObject {.importjs: "#[#]".}
proc serverClose(server: JsObject) {.importjs: "#.close()".}
proc wssClose(wss: JsObject) {.importjs: "#.close()".}

proc lspBridgeUrl*(): string =
  lspBridgeUrl(rustLspKind)

proc startLspBridge*(kind: string = rustLspKind; lsCommand: string = ""; lsCwd: string = ""): Future[void] {.async.} =
  let cfg = getBridgeConfig(kind)
  let state = getBridgeState(kind)
  if not state.handle.isNil or state.starting:
    return
  state.starting = true
  var port = parsePort(envValue(cfg.envPort), cfg.defaultPort)
  var path = normalizePath(envValue(cfg.envPath), cfg.defaultPath)
  var command = if lsCommand.len > 0: lsCommand else: cfg.defaultCommand
  let commandOverride = envValue(cfg.envCommand)
  if commandOverride.len > 0:
    command = commandOverride
  var commandDir = lsCwd
  let cwdOverride = envValue(cfg.envCwd)
  if cwdOverride.len > 0:
    commandDir = cwdOverride
  if path.len == 0:
    path = cfg.defaultPath
  ensureNotificationHandler()
  try:
    let handle = await startBridge(cint(port), path, command, commandDir)
    state.handle = handle
    state.port = port
    state.path = path
    state.lastBridgeError = ""
    setEnv(cfg.envPort, $port)
    setEnv(cfg.envPath, path)
    setEnv(cfg.envUrl, lspBridgeUrl(kind))
    infoPrint fmt"index:lsp bridge ({kind}) listening on {lspBridgeUrl(kind)}"
    sendLspStatusToRenderer(kind)
  except CatchableError:
    state.handle = nil
    state.lastBridgeError = getCurrentExceptionMsg()
    errorPrint fmt"index:lsp bridge ({kind}) failed to start: {state.lastBridgeError}"
    sendLspStatusToRenderer(kind)
    raise
  finally:
    state.starting = false

proc stopLspBridge*(kind: string = rustLspKind) =
  let cfg = getBridgeConfig(kind)
  let state = getBridgeState(kind)
  if state.handle.isNil:
    return
  let server = getField(state.handle, "server")
  let wss = getField(state.handle, "wss")
  state.handle = nil
  try:
    if not wss.isNil:
      wssClose(wss)
  except CatchableError:
    warnPrint fmt"index:lsp bridge websocket close error ({kind}): {getCurrentExceptionMsg()}"
  try:
    if not server.isNil:
      serverClose(server)
  except CatchableError:
    warnPrint fmt"index:lsp bridge server close error ({kind}): {getCurrentExceptionMsg()}"
  state.lastBridgeError = ""
  state.port = cfg.defaultPort
  state.path = cfg.defaultPath
  setEnv(cfg.envUrl, "")
  setEnv(cfg.envPort, "")
  setEnv(cfg.envPath, "")
  infoPrint fmt"index:lsp bridge ({kind}) stopped"
  sendLspStatusToRenderer(kind)

proc stopAllLspBridges* =
  for cfg in configuredBridges:
    stopLspBridge(cfg.kind)
  resetNotificationHandler()

proc sendLspProbe*(payload: JsObject; kind: string = rustLspKind) =
  when defined(ctRenderer):
    discard
  else:
    let state = getBridgeState(kind)
    if state.handle.isNil:
      warnPrint fmt"index:lsp probe skipped ({kind}) because bridge is not running"
      return
    let url = lspBridgeUrl(kind)
    var completed = false
    let ws = createWs(url.cstring)
    wsOnOpen(ws, proc () {.closure.} =
      infoPrint fmt"index:lsp probe sending payload to {url} ({kind})"
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
  var kind = rustLspKind
  let kindField = response["kind"]
  if not kindField.isNil:
    let rawKind = $toCStringValue(kindField)
    if rawKind.len > 0:
      kind = rawKind
  if kind.len == 0:
    sendLspStatusToRenderer()
  elif bridgeConfigs.hasKey(kind):
    sendLspStatusToRenderer(kind)
  else:
    sendLspStatusToRenderer(rustLspKind)

proc onStartLsp*(sender: JsObject, response: JsObject) {.async.} =
  # we call it in a `onStartLsp` handler, because if we directly
  # start it from `ready` it can raise an unhandled error
  #   which breaks ready and new window record replay(or even maybe normal replay?) 
  #   find a way to catch `.listen` callback error?
  when not defined(server):
    # for now not supported on server
    for kind in [rustLspKind, rubyLspKind]:
      try:
        await startLspBridge(kind)
      except: # CatchableError:
        warnPrint fmt"index:lsp unable to start {kind} bridge" # : {getCurrentExceptionMsg()}"
  else:
    discard
