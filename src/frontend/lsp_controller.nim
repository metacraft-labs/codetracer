import
  std/[jsffi, strutils, strformat],
  lsp_client,
  ../common/ct_logging,
  lib/jslib

when defined(js):
  proc newWebSocket(url: cstring): JsObject {.importjs: "new WebSocket(#)".}
  proc closeWebSocket(ws: JsObject) {.importjs: "#.close()".}
  proc setTimeout(callback: proc() {.closure.}; delay: int): int {.importjs: "setTimeout(#, #)".}
  proc clearTimeout(timerId: int) {.importjs: "clearTimeout(#)".}
  proc field(target: JsObject; name: cstring): JsObject {.importjs: "#[#]".}
  proc isUndefined(value: JsObject): bool {.importjs: "(# === undefined)".}
  proc construct1(ctor: JsObject; arg: JsObject): JsObject {.importjs: "new #(#)".}
  proc call0(fn: JsObject): JsObject {.importjs: "#()".}
  proc call1(fn: JsObject; arg: JsObject): JsObject {.importjs: "#(#)".}
  proc newObject(): JsObject {.importjs: "({})".}
  proc newArray(): JsObject {.importjs: "([])".}
  proc setField(target: JsObject; name: cstring; value: JsObject) {.importjs: "#[#] = #".}
  proc push(target: JsObject; value: JsObject) {.importjs: "#.push(#)".}
  proc toJs(str: cstring): JsObject {.importjs: "#".}

var
  activeClient*: JsObject = nil
  wsConnection: JsObject = nil
  retryTimer = 0

proc startClient(url: string)

proc stopClient() =
  if retryTimer != 0:
    clearTimeout(retryTimer)
    retryTimer = 0
  if not activeClient.isNil:
    try:
      discard call0(field(activeClient, "stop"))
    except CatchableError:
      warnPrint "renderer:lsp stop client failed: ", getCurrentExceptionMsg()
    activeClient = nil
  if not wsConnection.isNil:
    try:
      wsConnection.closeWebSocket()
    except CatchableError:
      warnPrint "renderer:lsp websocket close failed: ", getCurrentExceptionMsg()
    wsConnection = nil

proc servicesReady(): bool =
  let flag = field(domwindow, "monacoServicesReadyFlag")
  result = not isUndefined(flag) and cast[bool](flag)

proc scheduleRetry(url: string) =
  if retryTimer != 0:
    return
  retryTimer = setTimeout(proc () =
    retryTimer = 0
    startClient(url)
  , 250)

proc startClient(url: string) =
  if not servicesReady():
    scheduleRetry(url)
    return
  stopClient()
  let normalized = url.strip(chars = Whitespace)
  if normalized.len == 0:
    infoPrint "renderer:lsp bridge stopped"
    return
  if not (normalized.startsWith("ws://") or normalized.startsWith("wss://")):
    warnPrint "renderer:lsp ignoring non-websocket url: " & normalized
    return
  let monacoLanguageClientCtor = field(domwindow, "MonacoLanguageClient")
  if isUndefined(monacoLanguageClientCtor):
    warnPrint "renderer:lsp MonacoLanguageClient unavailable"
    return
  let rpcHelpers = field(domwindow, "VscodeWsJsonrpc")
  if isUndefined(rpcHelpers):
    warnPrint "renderer:lsp vscode-ws-jsonrpc unavailable"
    return
  try:
    wsConnection = newWebSocket(normalized.cstring)
    let openHandler = proc () {.closure.} =
      try:
        let transport = call1(field(rpcHelpers, "toSocket"), wsConnection)
        let reader = construct1(field(rpcHelpers, "WebSocketMessageReader"), transport)
        let writer = construct1(field(rpcHelpers, "WebSocketMessageWriter"), transport)

        let docSelector = newArray()
        let rustSelector = newObject()
        setField(rustSelector, "language", toJs(cstring"rust"))
        push(docSelector, rustSelector)
        let jsonSelector = newObject()
        setField(jsonSelector, "language", toJs(cstring"json"))
        push(docSelector, jsonSelector)

        let clientOptions = newObject()
        setField(clientOptions, "documentSelector", docSelector)

        let transports = newObject()
        setField(transports, "reader", reader)
        setField(transports, "writer", writer)

        let clientConfig = newObject()
        setField(clientConfig, "id", toJs(cstring"codetracer-monaco-lsp"))
        setField(clientConfig, "name", toJs(cstring"CodeTracer Language Client"))
        setField(clientConfig, "clientOptions", clientOptions)
        setField(clientConfig, "messageTransports", transports)

        activeClient = construct1(monacoLanguageClientCtor, clientConfig)
        discard call0(field(activeClient, "start"))
        infoPrint fmt"renderer:lsp client started @ {normalized}"
      except CatchableError:
        warnPrint "renderer:lsp start failed @ " & normalized & ": " & getCurrentExceptionMsg()
        scheduleRetry(url)
    setField(wsConnection, "onopen", toJs(openHandler))
  except CatchableError:
    warnPrint "renderer:lsp websocket setup failed: ", getCurrentExceptionMsg()
    scheduleRetry(url)

proc onUrlChange(url: string) =
  startClient(url)

proc requestInitialStatus() =
  if lsp_client.lspUrl.len > 0:
    startClient(lsp_client.lspUrl)
  else:
    lsp_client.requestLspUrl()

proc initLspController* =
  onLspUrlChange(onUrlChange)
  requestInitialStatus()
