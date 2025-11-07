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
  proc requireModule(name: cstring): JsObject {.importjs: "require(#)".}
  proc arrayLen(arr: JsObject): int {.importjs: "#.length".}
  proc arrayAt(arr: JsObject; idx: int): JsObject {.importjs: "#[#]".}
  proc toCString(value: JsObject): cstring {.importjs: "String(#)".}

var
  activeClient*: JsObject = nil
  wsConnection: JsObject = nil
  retryTimer = 0

proc normalizePathString(path: string): string =
  var normalized = path.strip(chars = Whitespace)
  if normalized.len == 0:
    return normalized
  for i in 0 ..< normalized.len:
    if normalized[i] == '\\':
      normalized[i] = '/'
  let hasDrive = normalized.len >= 2 and normalized[1] == ':'
  while normalized.len > 1 and normalized[^1] == '/':
    if hasDrive and normalized.len == 3:
      break
    normalized.setLen(normalized.len - 1)
  normalized

proc folderDisplayName(path: string): string =
  let normalized = normalizePathString(path)
  if normalized.len == 0:
    return ""
  var endIdx = normalized.len - 1
  while endIdx > 0 and normalized[endIdx] == '/':
    dec endIdx
  var idx = endIdx
  while idx >= 0:
    if normalized[idx] == '/':
      if idx == endIdx:
        return normalized
      return normalized[idx + 1 .. endIdx]
    dec idx
  normalized[0 .. endIdx]

proc joinPath(base: string; child: string): string =
  if base.len == 0:
    return child
  if base[^1] == '/':
    base & child
  else:
    base & "/" & child

proc toFileUri(path: string): string =
  var normalized = normalizePathString(path)
  if normalized.len == 0:
    return ""
  if normalized.startsWith("file://"):
    return normalized
  if normalized[0] == '/':
    return "file://" & normalized
  "file:///" & normalized

proc containsPath(list: seq[string]; value: string): bool =
  for entry in list:
    if entry == value:
      return true
  false

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
  let fsModule = requireModule("fs")
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

        let workspaceFolders = newArray()
        let linkedProjects = newArray()
        var workspacePaths: seq[string] = @[]
        var linkedProjectPaths: seq[string] = @[]
        let existsFn = field(fsModule, "existsSync")

        proc addWorkspaceFolder(path: string) =
          let normalized = normalizePathString(path)
          if normalized.len == 0 or containsPath(workspacePaths, normalized):
            return
          workspacePaths.add(normalized)
          let folderObj = newObject()
          let display = folderDisplayName(normalized)
          setField(folderObj, "name", toJs(display.cstring))
          setField(folderObj, "uri", toJs(toFileUri(normalized).cstring))
          push(workspaceFolders, folderObj)

        proc addLinkedProject(folderPath: string) =
          let normalized = normalizePathString(folderPath)
          if normalized.len == 0:
            return
          let cargoPath = joinPath(normalized, "Cargo.toml")
          if containsPath(linkedProjectPaths, cargoPath):
            return
          if not cast[bool](call1(existsFn, toJs(cargoPath.cstring))):
            return
          linkedProjectPaths.add(cargoPath)
          let project = newObject()
          setField(project, "kind", toJs(cstring"cargo"))
          setField(project, "path", toJs(cargoPath.cstring))
          push(linkedProjects, project)

        proc registerFolder(path: string) =
          if path.len == 0:
            return
          addWorkspaceFolder(path)
          addLinkedProject(path)

        let dataObj = field(domwindow, "data")
        if not isUndefined(dataObj):
          let traceObj = field(dataObj, "trace")
          if not isUndefined(traceObj) and not traceObj.isNil:
            let workdirVal = field(traceObj, "workdir")
            if not isUndefined(workdirVal) and not workdirVal.isNil:
              let workdir = $toCString(workdirVal)
              registerFolder(workdir)
            let sourceFolders = field(traceObj, "sourceFolders")
            if not isUndefined(sourceFolders) and not sourceFolders.isNil:
              let count = arrayLen(sourceFolders)
              var idx = 0
              while idx < count:
                let folderVal = arrayAt(sourceFolders, idx)
                if not folderVal.isNil:
                  let folderPath = $toCString(folderVal)
                  registerFolder(folderPath)
                inc idx

        if arrayLen(workspaceFolders) > 0:
          setField(clientOptions, "workspaceFolders", workspaceFolders)
          setField(clientOptions, "workspaceFolder", arrayAt(workspaceFolders, 0))
        if arrayLen(linkedProjects) > 0:
          let initOptions = newObject()
          setField(initOptions, "linkedProjects", linkedProjects)
          setField(clientOptions, "initializationOptions", initOptions)

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
