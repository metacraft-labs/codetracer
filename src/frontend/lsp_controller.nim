import
  std/[jsffi, strformat, tables, sequtils, strutils],
  lsp_client,
  ../common/ct_logging,
  lib/jslib,
  lsp_js_bindings,
  lsp_paths,
  lsp_router

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
var pathModuleCache: JsObject
var pendingStartUrls = initTable[string, string]()

proc startClient(kind: string; url: string; allowDefer: bool = true)

proc ensurePathModule(): JsObject =
  if pathModuleCache.isNil:
    pathModuleCache = requireModule("path")
  pathModuleCache

proc normalizeKind(kind: string): string =
  if kind.len == 0:
    ""
  else:
    kind.toLowerAscii()

proc logClientConfig(label: cstring; payload: JsObject) {.importjs: "console.log(#, JSON.stringify(#, null, 2))".}

proc fileExists(fsModule: JsObject; path: string): bool =
  if path.len == 0:
    return false
  try:
    cast[bool](call1(field(fsModule, "existsSync"), toJs(path.cstring)))
  except CatchableError:
    false

proc dirname(pathModule: JsObject; target: string): string =
  if target.len == 0:
    return ""
  try:
    let dirValue = call1(field(pathModule, "dirname"), toJs(target.cstring))
    normalizePathString($toCString(dirValue))
  except CatchableError:
    ""

proc findCargoRoot(fsModule, pathModule: JsObject; filePath: string): string =
  var current = normalizePathString(filePath)
  if current.len == 0:
    return ""
  var currentDir = dirname(pathModule, current)
  var guard = 0
  while currentDir.len > 0 and guard < 256:
    let cargoPath = joinPath(currentDir, "Cargo.toml")
    infoPrint fmt"renderer:lsp cargo search ({filePath}) checking {cargoPath}"
    if fileExists(fsModule, cargoPath):
      infoPrint fmt"renderer:lsp cargo root detected: {currentDir}"
      return currentDir
    let parentDir = dirname(pathModule, currentDir)
    if parentDir.len == 0 or parentDir == currentDir:
      break
    currentDir = parentDir
    inc guard
  infoPrint fmt"renderer:lsp cargo search failed for {filePath}"
  ""

proc attachDidOpenLogger(client: JsObject; kind: cstring) {.importjs: "(function(c,label){ var origStart = c.start.bind(c); c.start = function(){ if (!c.__diagnosticHook){ var origNotify = c.sendNotification.bind(c); c.sendNotification = function(method, params){ if (method && method.method === 'textDocument/didOpen'){ console.log('[LSP didOpen ' + label + ']', params && params.textDocument ? params.textDocument.uri : params); } return origNotify(method, params); }; c.__diagnosticHook = true; } return origStart(); }; })(#, #)".}

proc attachWiretap(client: JsObject; kind: cstring) {.importjs: "(function(c,label){ if (c && !c.__wiretap){ var origSendNotification = c.sendNotification ? c.sendNotification.bind(c) : null; var origSendRequest = c.sendRequest ? c.sendRequest.bind(c) : null; if (origSendNotification){ c.sendNotification = function(method, params){ console.log('[LSP -> ' + label + ' notify]', method, JSON.stringify(params, null, 2)); return origSendNotification(method, params); }; } if (origSendRequest){ c.sendRequest = function(method, params){ console.log('[LSP -> ' + label + ' request]', method, JSON.stringify(params, null, 2)); return origSendRequest(method, params); }; } c.__wiretap = true; } })(#, #)".}

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
      detachLspDiagnostics(kind)
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
  push(linkedProjects, toJs(cargoPath.cstring))

proc addEditorWorkspaceFolders(kind: string; fsModule: JsObject; workspaceFolders: JsObject; workspacePaths: var seq[string]; hasExistingWorkspace: var bool) =
  let editorPaths = getRegisteredDocumentPaths(kind)
  if editorPaths.len == 0:
    return
  let pathModule = ensurePathModule()
  let normalizedKind = normalizeKind(kind)
  for filePath in editorPaths:
    var targetFolder = ""
    if normalizedKind == "rust":
      targetFolder = findCargoRoot(fsModule, pathModule, filePath)
    else:
      targetFolder = dirname(pathModule, normalizePathString(filePath))
    if targetFolder.len == 0:
      continue
    if workspacePaths.contains(targetFolder):
      continue
    addWorkspaceFolder(workspaceFolders, workspacePaths, targetFolder)
    if not hasExistingWorkspace and fileExists(fsModule, targetFolder):
      hasExistingWorkspace = true

proc shouldDeferStart(kind: string): bool =
  not hasRegisteredDocuments(kind)

proc tryStartPendingClient(kind: string)

proc startClient(kind: string; url: string; allowDefer: bool = true) =
  if not servicesReady():
    scheduleRetry(kind, url)
    return
  if allowDefer and shouldDeferStart(kind):
    infoPrint fmt"renderer:lsp deferring start ({kind}) until workspace is available"
    pendingStartUrls[kind] = url
    return
  stopClient(kind)
  var effectiveUrl = url
  let cachedUrl = lsp_client.getLspUrl(kind)
  if kind != defaultLspKind and cachedUrl.len > 0 and cachedUrl != url:
    infoPrint fmt"renderer:lsp overriding url ({kind}): requested={url}, cached={cachedUrl}"
    effectiveUrl = cachedUrl
  infoPrint fmt"renderer:lsp startClient requested ({kind}) => {effectiveUrl}"
  let normalized = effectiveUrl.strip(chars = Whitespace)
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
        var hasExistingWorkspace = false
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
            for candidate in workspacePaths:
              if cast[bool](call1(field(fsModule, "existsSync"), toJs(candidate.cstring))):
                hasExistingWorkspace = true
                break
            if not hasExistingWorkspace:
              let outputFolderVal = field(traceObj, "outputFolder")
              if not outputFolderVal.isNil:
                let filesPath = joinPath(normalizePathString($toCString(outputFolderVal)), "files")
                addWorkspaceFolder(workspaceFolders, workspacePaths, filesPath)
                if cast[bool](call1(field(fsModule, "existsSync"), toJs(filesPath.cstring))):
                  hasExistingWorkspace = true

        addEditorWorkspaceFolders(kind, fsModule, workspaceFolders, workspacePaths, hasExistingWorkspace)
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
        let logLabel = cstring(fmt"[LSP clientConfig {kind}]")
        logClientConfig(logLabel, clientConfig)

        state.activeClient = construct1(monacoLanguageClientCtor, clientConfig)
        if not state.activeClient.isNil:
          attachDidOpenLogger(state.activeClient, cfg.kind.cstring)
          attachWiretap(state.activeClient, cfg.kind.cstring)
        discard call0(field(state.activeClient, "start"))
        attachLspDiagnostics(kind, state.activeClient)
        markClientReady(kind)
        infoPrint fmt"renderer:lsp client ({kind}) started @ {normalized}"
      except CatchableError:
        warnPrint fmt"renderer:lsp start failed ({kind}) @ {normalized}: {getCurrentExceptionMsg()}"
        scheduleRetry(kind, url)
    setField(state.wsConnection, "onopen", toJs(openHandler))
  except CatchableError:
    warnPrint fmt"renderer:lsp websocket setup failed ({kind}): {getCurrentExceptionMsg()}"
    state.wsConnection = nil
    scheduleRetry(kind, url)

proc tryStartPendingClient(kind: string) =
  if not pendingStartUrls.hasKey(kind):
    return
  let url = pendingStartUrls[kind]
  pendingStartUrls.del(kind)
  infoPrint fmt"renderer:lsp resuming deferred start ({kind}) => {url}"
  startClient(kind, url, false)

proc onUrlChange(kind: string; url: string) =
  startClient(kind, url)

proc requestInitialStatus(kind: string) =
  let currentUrl = lsp_client.getLspUrl(kind)
  infoPrint fmt"renderer:lsp requestInitialStatus {kind}, cachedUrl='{currentUrl}'"
  if currentUrl.len > 0:
    startClient(kind, currentUrl)
  else:
    lsp_client.requestLspUrl(kind)

proc registerKindController(cfg: ControllerConfig) =
  let capturedKind = cfg.kind
  registerDocumentObserver(capturedKind, proc () {.closure.} =
    tryStartPendingClient(capturedKind)
  )
  onLspUrlChange(proc(url: string) {.closure.} = onUrlChange(capturedKind, url), kind = capturedKind)
  requestInitialStatus(capturedKind)

proc initLspController* =
  for cfg in controllerConfigs:
    registerKindController(cfg)
