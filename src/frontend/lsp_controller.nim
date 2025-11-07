import
  std/[jsffi, strformat, tables, sequtils, strutils],
  lsp_client,
  ../common/ct_logging,
  lib/jslib,
  lsp_js_bindings,
  lsp_paths

type
  ControllerConfig = object
    kind: string
    clientId: string
    clientName: string
    languages: seq[string]
    includeLinkedProjects: bool

  ControllerState = ref object
    activeClient: JsObject
    wsConnection: JsObject
    retryTimer: int

let controllerConfigs = @[
  ControllerConfig(
    kind: defaultLspKind,
    clientId: "codetracer-monaco-lsp",
    clientName: "CodeTracer Language Client",
    languages: @["rust", "json"],
    includeLinkedProjects: true),
  ControllerConfig(
    kind: "ruby",
    clientId: "codetracer-ruby-lsp",
    clientName: "CodeTracer Ruby Language Client",
    languages: @["ruby"],
    includeLinkedProjects: false)
]

var controllerStates = initTable[string, ControllerState]()

proc startClient(kind: string; url: string)

proc getConfig(kind: string): ControllerConfig =
  for cfg in controllerConfigs:
    if cfg.kind == kind:
      return cfg
  controllerConfigs[0]

proc getState(kind: string): ControllerState =
  if controllerStates.hasKey(kind):
    return controllerStates[kind]
  let state = ControllerState(activeClient: nil, wsConnection: nil, retryTimer: 0)
  controllerStates[kind] = state
  state

proc servicesReady(): bool =
  let flag = field(domwindow, "monacoServicesReadyFlag")
  not isUndefined(flag) and cast[bool](flag)

proc stopClient(kind: string) =
  let state = getState(kind)
  if state.retryTimer != 0:
    clearTimeout(state.retryTimer)
    state.retryTimer = 0
  if not state.activeClient.isNil:
    try:
      discard call0(field(state.activeClient, "stop"))
    except CatchableError:
      warnPrint fmt"renderer:lsp ({kind}) stop client failed: {getCurrentExceptionMsg()}"
    state.activeClient = nil
  if not state.wsConnection.isNil:
    try:
      state.wsConnection.closeWebSocket()
    except CatchableError:
      warnPrint fmt"renderer:lsp ({kind}) websocket close failed: {getCurrentExceptionMsg()}"
    state.wsConnection = nil

proc scheduleRetry(kind: string; url: string) =
  let state = getState(kind)
  if state.retryTimer != 0:
    return
  state.retryTimer = setTimeout(proc () =
    state.retryTimer = 0
    startClient(kind, url)
  , 250)

proc addWorkspaceFolder(workspaceFolders: JsObject; workspacePaths: var seq[string]; path: string) =
  let normalized = normalizePathString(path)
  if normalized.len == 0 or workspacePaths.contains(normalized):
    return
  workspacePaths.add(normalized)
  let folderObj = newObject()
  setField(folderObj, "name", toJs(folderDisplayName(normalized).cstring))
  setField(folderObj, "uri", toJs(toFileUri(normalized).cstring))
  push(workspaceFolders, folderObj)

proc addLinkedProject(linkedProjects: JsObject; linkedPaths: var seq[string]; fsModule: JsObject; folderPath: string) =
  let normalized = normalizePathString(folderPath)
  if normalized.len == 0 or linkedPaths.contains(normalized):
    return
  let cargoPath = joinPath(normalized, "Cargo.toml")
  if not cast[bool](call1(field(fsModule, "existsSync"), toJs(cargoPath.cstring))):
    return
  linkedPaths.add(normalized)
  let project = newObject()
  setField(project, "kind", toJs(cstring"cargo"))
  setField(project, "path", toJs(cargoPath.cstring))
  push(linkedProjects, project)

proc startClient(kind: string; url: string) =
  if not servicesReady():
    scheduleRetry(kind, url)
    return
  stopClient(kind)
  let normalized = url.strip(chars = Whitespace)
  if normalized.len == 0:
    infoPrint fmt"renderer:lsp bridge stopped ({kind})"
    return
  if not (normalized.startsWith("ws://") or normalized.startsWith("wss://")):
    warnPrint fmt"renderer:lsp ignoring non-websocket url ({kind}): {normalized}"
    return
  let monacoLanguageClientCtor = field(domwindow, "MonacoLanguageClient")
  if isUndefined(monacoLanguageClientCtor):
    warnPrint fmt"renderer:lsp MonacoLanguageClient unavailable ({kind})"
    return
  let rpcHelpers = field(domwindow, "VscodeWsJsonrpc")
  if isUndefined(rpcHelpers):
    warnPrint fmt"renderer:lsp vscode-ws-jsonrpc unavailable ({kind})"
    return
  let cfg = getConfig(kind)
  let state = getState(kind)
  let fsModule = requireModule("fs")
  try:
    state.wsConnection = newWebSocket(normalized.cstring)
    let openHandler = proc () {.closure.} =
      try:
        let transport = call1(field(rpcHelpers, "toSocket"), state.wsConnection)
        let reader = construct1(field(rpcHelpers, "WebSocketMessageReader"), transport)
        let writer = construct1(field(rpcHelpers, "WebSocketMessageWriter"), transport)

        let docSelector = newArray()
        for lang in cfg.languages:
          let entry = newObject()
          setField(entry, "language", toJs(lang.cstring))
          push(docSelector, entry)

        let clientOptions = newObject()
        setField(clientOptions, "documentSelector", docSelector)

        let workspaceFolders = newArray()
        var workspacePaths: seq[string] = @[]
        let dataObj = field(domwindow, "data")
        if not isUndefined(dataObj):
          let traceObj = field(dataObj, "trace")
          if not isUndefined(traceObj) and not traceObj.isNil:
            let workdirVal = field(traceObj, "workdir")
            if not workdirVal.isNil:
              let workdir = $toCString(workdirVal)
              addWorkspaceFolder(workspaceFolders, workspacePaths, workdir)
            let sourceFolders = field(traceObj, "sourceFolders")
            if not isUndefined(sourceFolders) and not sourceFolders.isNil:
              let count = arrayLen(sourceFolders)
              var idx = 0
              while idx < count:
                let folderVal = arrayAt(sourceFolders, idx)
                if not folderVal.isNil:
                  addWorkspaceFolder(workspaceFolders, workspacePaths, $toCString(folderVal))
                inc idx

        if arrayLen(workspaceFolders) > 0:
          setField(clientOptions, "workspaceFolders", workspaceFolders)
          setField(clientOptions, "workspaceFolder", arrayAt(workspaceFolders, 0))

        if cfg.includeLinkedProjects:
          let linkedProjects = newArray()
          var linkedPaths: seq[string] = @[]
          for path in workspacePaths:
            addLinkedProject(linkedProjects, linkedPaths, fsModule, path)
          if arrayLen(linkedProjects) > 0:
            let initOptions = newObject()
            setField(initOptions, "linkedProjects", linkedProjects)
            setField(clientOptions, "initializationOptions", initOptions)

        let transports = newObject()
        setField(transports, "reader", reader)
        setField(transports, "writer", writer)

        let clientConfig = newObject()
        setField(clientConfig, "id", toJs(cfg.clientId.cstring))
        setField(clientConfig, "name", toJs(cfg.clientName.cstring))
        setField(clientConfig, "clientOptions", clientOptions)
        setField(clientConfig, "messageTransports", transports)

        state.activeClient = construct1(monacoLanguageClientCtor, clientConfig)
        discard call0(field(state.activeClient, "start"))
        infoPrint fmt"renderer:lsp client ({kind}) started @ {normalized}"
      except CatchableError:
        warnPrint fmt"renderer:lsp start failed ({kind}) @ {normalized}: {getCurrentExceptionMsg()}"
        scheduleRetry(kind, url)
    setField(state.wsConnection, "onopen", toJs(openHandler))
  except CatchableError:
    warnPrint fmt"renderer:lsp websocket setup failed ({kind}): {getCurrentExceptionMsg()}"
    state.wsConnection = nil
    scheduleRetry(kind, url)

proc onUrlChange(kind: string; url: string) =
  startClient(kind, url)

proc requestInitialStatus(kind: string) =
  let currentUrl = lsp_client.getLspUrl(kind)
  if currentUrl.len > 0:
    startClient(kind, currentUrl)
  else:
    lsp_client.requestLspUrl(kind)

proc initLspController* =
  for cfg in controllerConfigs:
    let kind = cfg.kind
    onLspUrlChange(proc(url: string) {.closure.} = onUrlChange(kind, url), kind = kind)
    requestInitialStatus(kind)
