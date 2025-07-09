
import std / [ async, jsffi, strutils, sequtils, sugar, dom, strformat, os, jsconsole, json ]
import results
import lib, types, lang, paths, index_config, config, trace_metadata
import rr_gdb
import program_search
import ../common/ct_logging

# We have two main modes: server and desktop.
# By default we compile in desktop.
# In server mode we don't have electron, so we immitate or disable some of the code
# a lot of the logic is in index_config.nim/lib.nim and related

when defined(server):
  var electronDebug: js = undefined
  let app: ElectronApp = ElectronApp()
  let globalShortcut: js = undefined
else:
  var electronDebug = require("electron-debug")
  let app = cast[ElectronApp](electron.app)
  let globalShortcut = electron.globalShortcut
  let Menu = electron.Menu


data.start = now()

var close = false
var ctStartCoreProcess: NodeSubProcess = nil

proc showOpenDialog(dialog: JsObject, browserWindow: JsObject, options: JsObject): Future[JsObject] {.importjs: "#.showOpenDialog(#,#)".}
proc loadExistingRecord(traceId: int) {.async.}
proc prepareForLoadingTrace(traceId: int, pid: int) {.async.}
proc isCtInstalled(config: Config): bool


proc onClose(e: js) =
  if not data.config.isNil and data.config.test:
    discard
  elif not close:
    # TODO refactor to use just `client.send`
    mainWindow.webContents.send "CODETRACER::close", js{}
    close = true


# proc call(dialog: JsObject, browserWindow: JsObject, options: JsObject): Future[JsObject] {.importjs: "#.showOpenDialog(#,#)".}

# <traceId>
# --port <port>
# --frontend-socket-port <frontend-socket-port>
# --frontend-socket-parameters <frontend-socket-parameters>
# --backend-socket-port <backend-socket-port>
# --caller-pid <callerPid>
# # eventually if needed --backend-socket-host <backend-socket-host>
proc parseArgs =
  # echo "parseArgs"

  data.startOptions.screen = true
  data.startOptions.loading = false
  data.startOptions.record = false
  data.startOptions.stylusExplorer = electronProcess.env[cstring"CODETRACER_LAUNCH_MODE"] == cstring"arb.explorer"

  data.startOptions.folder = electronprocess.cwd()

  if electronProcess.env.hasKey(cstring"CODETRACER_TRACE_ID"):
    data.startOptions.traceID = electronProcess.env[cstring"CODETRACER_TRACE_ID"].parseJSInt
    data.startOptions.inTest = electronProcess.env[cstring"CODETRACER_TEST"] == cstring"1"
    callerProcessPid = electronProcess.env[cstring"CODETRACER_CALLER_PID"].parseJsInt
    return
  else:
    discard



  if electronProcess.env.hasKey(cstring"CODETRACER_TEST_STRATEGY"):
    data.startOptions.rawTestStrategy = electronProcess.env[cstring"CODETRACER_TEST_STRATEGY"]
    infoPrint "RAW TEST STRATEGY:", data.startOptions.rawTestStrategy

  let argsExceptNoSandbox = electronProcess.argv.filterIt(it != cstring"--no-sandbox")

  # TODO electron or just node? server code compatibility
  if argsExceptNoSandbox.len > 2:
    var args = argsExceptNoSandbox[2 .. ^1]
    var i = 0
    while i < args.len:
      let arg = args[i]
      if arg == cstring"--bypass":
        data.startOptions.screen = false
        data.startOptions.loading = true
      elif arg == cstring"--test":
        data.startOptions.screen = false
        data.startOptions.inTest = true
      elif arg == cstring"--no-record":
        data.startOptions.record = false
      elif arg == cstring"edit":
        data.startOptions.edit = true
        data.startOptions.name = argsExceptNoSandbox[i + 3]
        let file = fs.lstatSync(data.startOptions.name)
        var folder = cstring""
        if data.startOptions.name[0] == '/':
          if cast[bool](file.isFile()):
            folder = nodePath.dirname(data.startOptions.name) & cstring"/"
          else:
            folder = data.startOptions.name
            data.startOptions.name = cstring""
          if folder[folder.len - 1] != '/':
            folder = folder & cstring"/"
        else:
          folder = electronprocess.cwd() & cstring"/"
        data.startOptions.folder = folder
        break
      elif arg == cstring"--shell-ui":
        data.startOptions.shellUi = true
        data.startOptions.folder = electronprocess.cwd()
        data.startOptions.traceID = -1
        break
      elif arg == cstring"--port":
        if i + 1 < args.len:
          data.startOptions.port = args[i + 1].parseJsInt
          i += 2
          continue
        else:
          errorPrint "expected --port <port>"
          break
      elif arg == cstring"--frontend-socket-port":
        if i + 1 < args.len:
          data.startOptions.frontendSocket.port = args[i + 1].parseJsInt
          i += 2
          continue
        else:
          errorPrint "expected --frontend-socket-port <frontend-socket-port>"
          break
      elif arg == cstring"--frontend-socket-parameters":
        if i + 1 < args.len:
          data.startOptions.frontendSocket.parameters = args[i + 1]
          i += 2
          continue
        else:
          errorPrint "expected --frontend-socket-parameters <frontend-socket-parameters>"
          break
      elif arg == cstring"--backend-socket-port":
        if i + 1 < args.len:
          data.startOptions.backendSocket.port = args[i + 1].parseJsInt
          i += 2
          continue
        else:
          errorPrint "expected --backend-socket-port <backend-socket-port>"
          break
      # elif arg == cstring"--backend-socket-parameters":
      #   if i + 1 < args.len:
      #     data.startOptions.backendSocket.parameters = args[i + 1]
      #     i += 2
      #     continue
      #   else:
      #     errorPrint "expected --backend-socket-parameters <backend-socket-parameters>"
      #     break
      elif arg == cstring"--caller-pid":
        if i + 1 < args.len:
          callerProcessPid = args[i + 1].parseJsInt
          i += 2
          continue
        else:
          errorPrint "expected --caller-pid <caller-pid>"
          break
      elif not arg.isNaN:
        data.startOptions.screen = false
        data.startOptions.loading = true
        data.startOptions.record = false
        data.startOptions.traceID = arg.parseJSInt
        data.startOptions.folder = electronprocess.cwd()
      else:
        discard
      i += 1
  else:
    data.startOptions.traceID = -1
    data.startOptions.welcomeScreen = true
    data.startOptions.folder = electronprocess.cwd()

  # "traceId=1", "test", "no-sandbox"

proc selectFileOrFolder(options: JsObject): Future[cstring] {.async.} =
  let selection = await electron.dialog.showOpenDialog(mainWindow, options)
  let filePaths = cast[seq[cstring]](selection.filePaths)
  if filePaths.len > 0:
    return filePaths[0]
  else:
    return cstring""

proc selectFiles(dialogTitle: cstring): Future[seq[cstring]] {.async.} =
  let selection = await electron.dialog.showOpenDialog(
    mainWindow,
    js{
      properties: @[j"openFile", j"multiSelections"],
      title: dialogTitle,
      buttonLabel: cstring"Select"})

  if not selection.cancelled.to(bool):
    return cast[seq[cstring]](selection.filePaths)

# tried to return a folder *with* a trailing slash, if it finds one
proc selectDir(dialogTitle: cstring, defaultPath: cstring = cstring""): Future[cstring] {.async.} =
  let selection = await electron.dialog.showOpenDialog(
    mainWindow,
    js{
      properties: @[cstring"openDirectory", cstring"showHiddenFiles"],
      title: dialogTitle,
      buttonLabel: cstring"Select",
      defaultPath: defaultPath
    }
  )

  let filePaths = cast[seq[cstring]](selection.filePaths)
  if filePaths.len > 0:
    var resultDir = filePaths[0]
    if not ($resultDir).endsWith("/"):
      resultDir.add(cstring"/")
    return resultDir
  else:
    return cstring""

proc duration*(name: string) =
  infoPrint fmt"index: TIME for {name}: {now() - data.start}ms"


  # If codetracer has a 'broken' installation, only then do we attempt to install it

proc createMainWindow: js =
  when not defined(server):
    # TODO load from config

    let iconPath = linksPath & "/resources/Icon.iconset/icon_256x256.png"

    let win = jsnew electron.BrowserWindow(
      js{
        "title": j"CodeTracer",
        "icon": iconPath,
        "width": 1900,
        "height": 1400,
        "minWidth": 1050,
        "minHeight": 600,
        "webPreferences": js{
          "nodeIntegration": true,
          "contextIsolation": false,
          "spellcheck": false
        },
        "frame": false,
        "transparent": true,
        })
    win.on("maximize", proc() =
      win.webContents.executeJavaScript("document.body.style.backgroundColor = 'black';"))
    win.on("unmaximize", proc() =
      win.webContents.executeJavaScript("document.body.style.backgroundColor = 'transparent';"))
    win.maximize()
    let url = "file://" & $codetracerExeDir & "/index.html"

    win.loadURL(cstring(url))

    win.on("close", onClose)
    # TODO: eventually add a shortcut and ipc message that lets us
    # open the dev tools directly from the interface, as in browsers
    let inDevEnv = nodeProcess.env[cstring"CODETRACER_OPEN_DEV_TOOLS"] == cstring"1"
    if inDevEnv:
      electronDebug.devTools(win)
    duration("opening the browser window from index")
    return win
  else:
    # we make a test-only placeholder instance of it
    let win = FrontendIPC(webContents: FrontendIPCSender())
    return win.toJs

proc createInstallSubwindow(): js =

    let win = jsnew electron.BrowserWindow(
      js{
        "width": 700,
        "height": 422,
        "resizable": false,
        "parent": mainWindow,
        "modal": true,
        "webPreferences": js{
          "nodeIntegration": true,
          "contextIsolation": false,
          "spellcheck": false
        },
        "frame": false,
        "transparent": false,
        })

    let url = "file://" & $codetracerExeDir & "/subwindow.html"

    debugPrint "Attempting to load: ", url

    win.loadURL(cstring(url))

    let inDevEnv = nodeProcess.env[cstring"CODETRACER_OPEN_DEV_TOOLS"] == cstring"1"

    if inDevEnv:
      electronDebug.devTools(win)

    win.toJs

type
  DebuggerInfo = object of JsObject
    path: cstring
    exe: seq[cstring]
    #lang: Lang

proc onUpdateTable(sender: js, response: UpdateTableArgs) {.async.} =
  discard debugger.updateTable(response)

proc onTracepointDelete(sender: js, response: TracepointId) {.async.} =
  discard debugger.tracepointDelete(response)

proc onTracepointToggle(sender: js, response: TracepointId) {.async.} =
  discard debugger.tracepointToggle(response)

proc onLoadCallstack(sender: js, response: LoadCallstackArg) {.async.} =
  # debug "load ", id=response.codeID
  try:
    var callstack = await debugger.loadCallstack(response)
    var id = j($response.codeID & " " & $response.withArgs)
    # debug "ready ", id=id

    mainWindow.webContents.send "CODETRACER::load-callstack-received", js{argId: id, value: callstack}
  except:
    errorPrint "loadCallstack: ", getCurrentExceptionMsg()
    var id = j($response.codeID & " " & $response.withArgs)
    let callstack: seq[Call] = @[]
    mainWindow.webContents.send "CODETRACER::load-callstack-received", js{argId: id, value: callstack}

# TODO location?
proc onLoadCallArgs(sender: js, response: CalltraceLoadArgs) {.async.} =
  discard debugger.loadCallArgs(response)

proc onCollapseCalls(sender: js, response: CollapseCallsArgs) =
  discard debugger.collapseCalls(response)

proc onExpandCalls(sender: js, response: CollapseCallsArgs) =
  discard debugger.expandCalls(response)

proc updateExpand(path: cstring, line: int, expansionFirstLine: int, update: MacroExpansionLevelUpdate) {.async.} =
  warnPrint "update expansion disabled for now: needs a more stabilized version"

type
  FileFilter = ref object
    name*: cstring
    extensions*: seq[cstring]

when not defined(server):
  proc debugSend*(self: js, f: js, id: cstring, data: js) =
    var values = loadValues(data, id)
    if ct_logging.LOG_LEVEL <= CtLogLevel.Debug:
      console.log data
    f.call(self, cast[cstring](id), data)

# IPC HANDLERS
proc onAsmLoad(sender: js, response: FunctionLocation) {.async.} =
  let res = await data.nativeLoadInstructions(response)
  mainWindow.webContents.send "CODETRACER::asm-load-received", js{argId: cstring(fmt"{response.path}:{response.name}:{response.key}"), value: res.instructions}

proc onTabLoad(sender: js, response: jsobject(location=types.Location, name=cstring, editorView=EditorView, lang=Lang)) {.async.} =
  console.log response
  case response.lang:
  of LangC, LangCpp, LangRust, LangNim, LangGo, LangRubyDb:
    if response.editorView in {ViewSource, ViewTargetSource, ViewCalltrace}:
      discard mainWindow.openTab(response.location, response.lang, response.editorView)
    else:
     discard
  of LangAsm:
    if response.editorView == ViewInstructions:
      let res = await data.nativeLoadInstructions(FunctionLocation(path: response.location.path, name: response.location.functionName, key: response.location.key))
      mainWindow.webContents.send "CODETRACER::tab-load-received", js{argId: response.name, value: res}
  else:
    discard mainWindow.openTab(response.location, response.lang, response.editorView)

proc onLoadLowLevelTab(sender: js, response: jsobject(pathOrName=cstring, lang=Lang, view=EditorView)) {.async.} =
  case response.lang:
  of LangC, LangCpp, LangRust, LangGo:
    case response.view:
    of ViewTargetSource:
      warnPrint fmt"low level view source not supported for {response.lang}"
    of ViewInstructions:
      let res = await data.nativeLoadInstructions(FunctionLocation(name: response.pathOrName))
      mainWindow.webContents.send "CODETRACER::low-level-tab-received", js{argId: response.pathOrName & j" " & j($response.view), value: res}
    else:
      warnPrint fmt"low level view {response.view} not supported for {response.lang}"
  of LangNim:
    case response.view:
    of ViewTargetSource, ViewInstructions:
      let res = await data.nimLoadLowLevel(response.pathOrName, response.view)
      mainWindow.webContents.send "CODETRACER::low-level-tab-received", js{argId: response.pathOrName & j" " & j($response.view), value: res}
    else:
      warnPrint fmt"low level view {response.view} not supported for {response.lang}"
  else:
    warnPrint fmt"low level view not supported for {response.lang}"

# TODO: when fixing the nim c level support
# proc onLoadLowLevelLocations(sender: js, response: jsobject(path=cstring, line=int, lang=Lang, view=EditorView)) {.async.} =
#   case response.lang:
#   of LangNim:
#     let res = await data.nimLoadLowLevelLocations(response.path, response.line, response.view)
#     mainWindow.webContents.send "CODETRACER::load-low-level-locations-received", js{argId: response.path & j" " & j($response.line) & j" " & j($response.view), value: res}
#   else:
#     discard

when defined(ctmacos):
  let modMap* : JsAssoc[cstring, cstring] = JsAssoc[cstring, cstring]{
    $"ctrl":    $"cmdorctrl",
    $"meta":    $"cmd",
    $"super":   $"cmd",
    $"shift":   $"shift",
    $"alt":     $"option",
  }

  proc lookup(map: JsAssoc[cstring,cstring], tok: string): string =
    let v = map[tok.cstring]
    if v.isNil: tok else: $v

  proc toAccelerator* (raw: cstring): string =
    let s = $raw
    result = s
      .split({'+'})
      .mapIt(lookup(modMap, it.toLowerAscii))
      .join("+")

  proc menuNodeToItem(node: MenuNode): js =
    if node.kind == MenuFolder:
      var items: seq[js] = @[]
      for child in node.elements:
        if child.menuOs != ord(MenuNodeOSNonMacOS):
          items.add(menuNodeToItem(child))
          if child.isBeforeNextSubGroup:
            items.add(js{type: cstring"separator"})
      js{ label: node.name, enabled: node.enabled, submenu: cast[js](items), role: node.role }
    else:
      let binding = data.config.shortcutMap.actionShortcuts[node.action]
      let resultBinding = if binding.len == 0: "" else: toAccelerator($binding[0].renderer)
      if node.role != "":
        js{ role: node.role }
      else:
        js{
          label: node.name,
          enabled: node.enabled,
          accelerator: cstring(resultBinding),
          click: proc(menuItem: js, win: js) =
            mainWindow.webContents.send("CODETRACER::menu-action", js{action: node.action})
        }

  proc onRegisterMenu(sender: js, response: jsobject(menu=MenuNode)) =
    var elements: seq[js] = @[]
    for child in response.menu.elements:
      if child.menuOs != ord(MenuNodeOSNonMacOS):
        elements.add(menuNodeToItem(child))
        if child.isBeforeNextSubGroup:
          elements.add(js{type: cstring"separator"})
    let menu = Menu.buildFromTemplate(cast[js](elements))
    Menu.setApplicationMenu(menu)


else:
  proc onRegisterMenu(sender: js, response: jsobject(menu=MenuNode)) = discard

proc onUpdateExpansion(sender: js, response: jsobject(path=cstring, line=int, update=MacroExpansionLevelUpdate)) {.async.} =
  await updateExpand(response.path, response.line, -1, response.update) # TODO expansionFirstLine ?


proc onLoadTokens(sender: js, response: jsobject(path=cstring, lang=Lang)) {.async.} =
  errorPrint "onLoadTokens not working anymore"


proc onSaveConfig(sender: js, response: jsobject(name=cstring, layout=cstring)) {.async.} =
  # await persistConfig(mainWindow, response.name, response.layout)
  warnprint "FOR NOW: persisting config disabled"


proc onEventJump(sender: js, response: ProgramEvent) {.async.} =
  await debugger.eventJump(response)


proc onLoadTerminal(sender: js, response: js) {.async.} =
  discard debugger.loadTerminal(EmptyArg())

# proc onCallstackJump(sender: js, response: CallstackJump) {.async.} =
  # calls the n-th function in the callstack, 0 is current
  # await debugger.callstackJump(response)


proc onCalltraceJump(sender: js, response: types.Location) {.async.} =
  await debugger.calltraceJump(response)


proc onTraceJump(sender: js, response: ProgramEvent) {.async.} =
  await debugger.traceJump(response)


proc onHistoryJump(sender: js, response: types.Location) {.async.} =
  await debugger.historyJump(response)


# proc onDebugCT(sender: js, response: cstring) {.async.} =
#   let output = await debugger.debugCT(response)
#   mainWindow.webContents.send "CODETRACER::debug-output", output


# not supported in db-backend for now
# proc onDebugGdb(sender: js, response: DebugGdbArg) {.async.} =
  # there is a debug-output event, we ignore this one here for now
  # let output = await debugger.debugGdb(response)
  # discard output


# TODO also function name/id-based

proc onAddBreak(sender: js, response: SourceLocation) {.async.} =
  let id = await debugger.addBreak(response)
  mainWindow.webContents.send "CODETRACER::add-break-response",
    BreakpointInfo(path: response.path, line: response.line, id: id)


proc onDeleteBreak(sender: js, response: SourceLocation) {.async.} =
  discard debugger.deleteBreak(response)


# proc onAddBreakC(sender: js, response: jsobject(path=cstring, line=int)) {.async.} =
#   let id = await debugger.addBreakC(response.path, response.line)
#   mainWindow.webContents.send "CODETRACER::add-break-c-response",
#     BreakpointInfo(path: response.path, line: response.line, id: id)

proc onDeleteBreakC(sender: js, response: SourceLocation) {.async.} =
  discard debugger.deleteBreak(response)

proc onEnable(sender: js, response: SourceLocation) {.async.} =
  discard debugger.enable(response)

proc onDisable(sender: js, response: SourceLocation) {.async.} =
  discard debugger.disable(response)

# proc onLoadCallstackDirectChildrenBefore(sender: js, response: jsobject(codeID=int64, before=int64)) {.async.} =
  # var calls = await debugger.loadCallstackDirectChildrenBefore(response.codeID, response.before)
  # mainWindow.webContents.send "CODETRACER::load-callstack-direct-children-before-received", js{argId: j($response.codeID & " " & $response.before), value: calls}

proc onSearchCalltrace(sender: js, response: cstring) {.async.} =
  var calls = await debugger.calltraceSearch(response)
  mainWindow.webContents.send "CODETRACER::search-calltrace-received", js{argId: response, value: calls}

# TODO
# proc onUpdatedCalltraceArgs(sender: js, response: js) {.async.} =
#   for element in response.args:
#     let codeID = cast[int64](element.codeID)
#     let args = cast[CalltraceArgs](element.args)
#     graphEngine.args[codeID] = args
#   mainWindow.webContents.send "CODETRACER::updated-calltrace-args", response

proc onResetOperation(sender: js, response: jsobject(full=bool, taskId=TaskId, resetLastLocation=bool)) {.async.} =
  await debugger.resetOperation(ResetOperationArg(full: response.full, resetLastLocation: response.resetLastLocation), response.taskId)


proc onExitError(sender: js, response: cstring) {.async.} =
  # we call this on fatal errors
  errorPrint fmt"exit: {response}"
  if true: # workaround for unreachable statement and async
    quit(1)

# proc onInlineCallJump(sender: js, response: types.Location) {.async.} =
  # discard debugger.inlineCallJump(response)

# proc onUpdateTelemetryLog(sender: js, response: jsobject(logs=seq[TelemetryEvent])) {.async.} =
#   # we save the log in the file
#   if TELEMETRY_ENABLED:
#     var text = j""
#     for log in response.logs:
#       text = text & toYaml(log)
#     index_config.fs.appendFile(j"telemetry.log", text, proc = discard)
#   else:
#     await fsWriteFile(j"telemetry.log", j"")

proc onUpdateWatches(sender: js, response: jsobject(watchExpressions=seq[cstring])) {.async, exportc.} =
  discard debugger.updateWatches(response.watchExpressions)

proc onRunTracepoints(sender: js, response: RunTracepointsArg) {.async.} =
  await debugger.runTracepoints(response)

var files: seq[(cstring, cstring)] = @[]

proc saveAsFile(name: cstring, raw: cstring) {.async.} =
  electron.dialog.showSaveDialog(js{
    title: j"save as", defaultPath: name, buttonLabel: j"save"
    }, proc (file: cstring) {.async.} =
      if file.len > 0:
        discard fsWriteFile(file, raw)
        var files = JsAssoc[cstring, cstring]{}
        files[name] = file
        mainWindow.webContents.send "CODETRACER::saved-as", files)


proc onSaveFile(sender: js, response: jsobject(name=cstring, raw=cstring, saveAs=bool)) {.async.} =
  # debug "file register", name=response.name
  # files.add((response.name, response.raw, response.saveFile))
  # debugPrint response.name, " ", response.saveAs
  if response.saveAs:
    await saveAsFile(response.name, response.raw)
  else:
    await fsWriteFile(response.name, response.raw)


proc onSaveUntitled(sender: js, response: jsobject(name=cstring, raw=cstring, saveAs=bool)) {.async.} =
  await saveAsFile(response.name, response.raw)


proc onUpdate(sender: js, response: jsobject(build=bool, currentPath=cstring)) {.async.} =
  for file in files:
    # debug "save file", name=file[0]
    if not data.tabs.hasKey(file[0]):
      data.tabs[file[0]] = ServerTab(path: file[0], lang: LangNim, fileWatched: true)
    data.tabs[file[0]].ignoreNext = 2
    await fsWriteFile(file[0], file[1])
  files = @[]

  # not supported yet
  # if response.build:
  #   await initUpdate(data.trace, response.currentPath)

# @FileError, JsonError, ElectronError

# simple examples

# {.pragma: asyncError, raises: [IOError].}

# proc onUpdatedReader(sender: js, response: cstring) {.async.} =
#   data.reader = Json.parse(await fsReadFile(response)).to(SimpleReader)
#   mainWindow.webContents.send j"CODETRACER::updated-reader", data.reader

proc onSaveNew(sender: js, response: SaveFile) {.async, raises: [].} =
  data.save.files.add(response)
  await cast[Future[void]](0)
  # await data.saveSave()


proc onSaveClose(sender: js, index: int) {.async.} =
  if not data.config.test:
    data.save.files.delete(index)
    await data.saveSave()


proc onLoadHistory(sender: js, response: LoadHistoryArg) {.async.} =
  # TODO: fix in core/use new dsl
  await debugger.loadHistory(response)


proc onLoadFlow(sender: js, response: FlowQuery) {.async.} =
  await debugger.loadFlow(response.location, response.taskId)

proc onSetupTraceSession(sender: js, response: RunTracepointsArg) {.async.} =
  discard

proc onLoadFlowShape(sender: js, response: types.Location) {.async.} =
  # await debugger.loadFlowShape(response)
  warnPrint "TODO: fix in core/use new dsl: loadFlowShape not working now, also not sure about flow shape reform"

var startedFuture: proc: void
var startedReceived = false

proc onStarted(sender: js, response: js) {.async.} =
  if not startedFuture.isNil:
    startedReceived = true
    startedFuture()

proc onOpenTab(sender: js, response: js) {.async.} =

  let options = js{
    properties: @[j"openFile"],
    title: cstring"Select File",
    buttonLabel: cstring"Select"}

  let file = await selectFileOrFolder(options)

  if file != "":
    if file.slice(-4) == j".nim":
      mainWindow.webContents.send "CODETRACER::opened-tab", js{path: file, lang: LangNim}
    else:
      mainWindow.webContents.send "CODETRACER::opened-tab", js{path: file, lang: LangUnknown}


proc onReloadFile(sender: js, response: jsobject(path=cstring)) {.async.} =
  let lang = if response.path.slice(-4) == j".nim": LangNim else: LangUnknown
  data.tabs[response.path].waitsPrompt = false
  discard data.open(mainWindow, types.Location(highLevelPath: response.path, isExpanded: false), ViewSource, "tab-reloaded", false, data.exe, lang, -1)

proc onNoReloadFile(sender: js, response: jsobject(path=cstring)) {.async.} =
  data.tabs[response.path].waitsPrompt = false

proc onCloseApp(sender: js, response: js) {.async.} =
  for (name, file) in files:
    await fsWriteFile(name, file)

  if not ctStartCoreProcess.isNil:
    ctStartCoreProcess.stopProcess()

  mainWindow.close()

proc onRunToEntry(sender: js, response: js) {.async.} =
  discard debugger.runToEntry(EmptyArg())

proc onRestart(sender: js, response: js) {.async.} =
  quit(RESTART_EXIT_CODE)

proc onSearch(sender: js, response: SearchQuery) {.async.} = discard
#   # debugPrint "search ", response
#   if data.pluginCommands.hasKey(response.value):
#     if data.pluginClient.isNil:
#       # debugPrint cstring"plugin client is nil"
#       return
#     if data.pluginClient.running:
#       await data.pluginClient.cancelOrWait()
#     data.pluginClient.running = true
#     data.pluginClient.cancelled = false
#     # debugPrint response.command
#     await (data.pluginCommands[response.value]).search(response, data.pluginClient)
#     data.pluginClient.running = false
#     if not data.pluginClient.cancelOrWaitFunction.isNil:
#       data.pluginClient.cancelOrWaitFunction()
#   else:
#     errorPrint "not found ", response.value

# proc onRunTo(sender: js, response: jsobject(path=cstring, line=int, reverse=bool)) {.async.} =
  # discard debugger.runTo(response.path, response.line, response.reverse)

# proc onRunToCall(sender: js, re)
# TODO pass argId?

proc onSearchProgram(sender: js, query: cstring) {.async.} =
  debugPrint "search program ", query
  when not defined(server):
    discard doProgramSearch($query, debugSend, mainWindow)
  # discard debugger.searchProgram(query)

proc onLoadStepLines(sender: js, response: LoadStepLinesArg) {.async.} =
  discard debugger.loadStepLines(response)

proc onUploadTraceFile(sender: JsObject, response: UploadTraceArg) =
  runUploadWithStreaming(
    codetracerExe.cstring,
    @[
      j"upload",
      j"--trace-folder=" & response.trace.outputFolder
    ],
    onData = proc(data: string) =
      let jsonLine = parseJson(data.split("\n")[^2].strip())
      if jsonLine.hasKey("progress"):
        mainWindow.webContents.send("CODETRACER::upload-trace-progress",
        UploadProgress(
          id: response.trace.id,
          progress: jsonLine["progress"].getInt(),
          msg: jsonLine["message"].getStr("")
        )),
    onDone = proc(success: bool, result: string) =
      if success:
        let lines = result.splitLines()
        let lastLine = lines[^2]
        let parsed = parseJson(lastLine)
        let uploadData = UploadedTraceData(
          downloadKey: $parsed["downloadKey"].getStr(""),
          controlId: $parsed["controlId"].getStr(""),
          expireTime: $parsed["storedUntilEpochSeconds"].getInt()
        )
        mainWindow.webContents.send("CODETRACER::upload-trace-file-received", js{
          "argId": j(response.trace.program & ":" & $response.trace.id),
          "value": uploadData
        })
      else:
        mainWindow.webContents.send("CODETRACER::uploaded-trace-file-received", js{
          "argId": j(response.trace.program & ":" & $response.trace.id),
          "value": UploadedTraceData(downloadKey: "Errored")
        })
  )

proc onDownloadTraceFile(sender: js, response: jsobject(downloadKey = seq[cstring])) {.async.} =
  let res = await readProcessOutput(
    codetracerExe.cstring,
    @[j"download"].concat(response.downloadKey)
  )

  if res.isOk:
    let traceId = parseInt($res.v.trim())
    await prepareForLoadingTrace(traceId, nodeProcess.pid.to(int))
    await loadExistingRecord(traceId)
    mainWindow.webContents.send "CODETRACER::successful-download"
  else:
    mainWindow.webContents.send "CODETRACER::failed-download",
      js{errorMessage: cstring"codetracer server down or wrong download key"}

proc onDeleteOnlineTraceFile(sender: js, response: DeleteTraceArg) {.async.} =
  let res = await readProcessOutput(
    codetracerExe.cstring,
    @[
      j"cmdDelete",
      j"--trace-id=" & $response.traceId,
      j"--control-id=" & response.controlId
    ]
  )

  mainWindow.webContents.send(
    "CODETRACER::delete-online-trace-file-received",
    js{
      "argId": j($response.traceId & ":" & response.controlId),
      "value": res.isOk
    }
  )

proc onSendBugReportAndLogs(sender: js, response: BugReportArg) {.async.} =
  let process = await runProcess(
    codetracerExe.cstring,
    @[j"report-bug",
      j"--title=" & response.title,
      j"--description=" & response.description,
      j($callerProcessPid),
      j"--confirm-send=0"]
  )
  # debugPrint process

proc onStep(sender: js, response: JsObject) {.async.} =
  await debugger.step(cast[StepArg](response), cast[TaskId](response.taskId))

proc onDeleteAllBreakpoints(sender: js, response: js) {.async.} =
  await debugger.deleteAllBreakpoints(EmptyArg())

proc onSourceLineJump(sender: js, response: SourceLineJumpTarget) {.async.} =
  await debugger.sourceLineJump(response)

proc onSourceCallJump(sender: js, response: SourceCallJumpTarget) {.async.} =
  await debugger.sourceCallJump(response)

proc onLocalStepJump(sender: js, response: LocalStepJump) {.async.} =
  await debugger.localStepJump(response)

# TODO: somehow share with codetracer_shell.nim ?
proc scriptSessionLogPath(sessionId: int): cstring =
  cstring(codetracerTmpPath / fmt"session-{sessionId}-script.log")

let pty: JsObject = jsundefined # = cast[Pty](jsundefined) # TODO or remove completely require(cstring"node-pty"))
var afterId = 0
var sessionId = -1
var shellXtermProgress = -1


let CT_DEBUG_INSTANCE_PATH_BASE*: cstring = cstring(codetracerTmpPath) & cstring"/ct_instance_"

proc newDebugInstancePipe(pid: int): Future[JsObject] {.async.} =
  var future = newPromise() do (resolve: proc(response: JsObject)):
    var connections: seq[JsObject] = @[nil.toJs]
    let path = CT_DEBUG_INSTANCE_PATH_BASE & cstring($pid)
    connections[0] = net.createServer(proc(server: JsObject) =
      infoPrint "index: connected instance server for ", path
      # connections[0].pipe(connections[0])
       # js{path: path, encoding: cstring"utf8"},
      resolve(server))

    connections[0].on(cstring"error") do (error: js):
      errorPrint "index: socket instance server error: ", error
      resolve(nil.toJs)

    connections[0].listen(path)
  return await future
  # startSocket(debugger, CT_DEBUG_INSTANCE_PATH_BASE & cstring($pid)) # & cstring"_" & cstring($callerProcessPid))

proc sendOutputJumpIPC(instance: DebugInstance, outputLine: int) {.async.} =
  debugPrint "send output jump ipc ", cast[int](instance.process.pid), " ", outputLine
  instance.pipe.write(cstring($outputLine & "\n"))

proc onShowInDebugInstance(sender: js, response: jsobject(traceId=int, outputLine=int)) {.async.} =
  if not data.debugInstances.hasKey(response.traceId):
    var process = child_process.spawn(
      codetracerExe,
      @[cstring"run", cstring($response.traceId)])
    var pipe = await newDebugInstancePipe(process.pid)
    data.debugInstances[response.traceId] = DebugInstance(process: process, pipe: pipe)
    await wait(5_000)

  if response.outputLine != -1:
    await sendOutputJumpIPC(data.debugInstances[response.traceId], response.outputLine)


proc onOpenTrace(sender: js, traceId: int) {.async.} =
  # codetracer run <traceId>
  var process = child_process.spawn(
    codetracerExe,
    @[cstring"run", cstring($traceId)])

# proc onUpdatedEventsContent(sender: js, response: cstring) {.async.} =
#   try:
#     mainWindow.webContents.send "CODETRACER::updated-events-content", response
#   except:
#     errorPrint "error for `onUpdatedEventsContent` ", getCurrentExceptionMsg()

proc onLoadParsedExprs(sender: js, response: LoadParsedExprsArg) {.async.} =
  let value = await debugger.loadParsedExprs(response)
  mainWindow.webContents.send "CODETRACER::load-parsed-exprs-received", js{"argId": j($response.path & ":" & $response.line), "value": value}

proc onLoadLocals(sender: js, response: LoadLocalsArg) {.async.} =
  # debug "load locals"
  var locals = await debugger.loadLocals(response)
  mainWindow.webContents.send "CODETRACER::load-locals-received", js{"argId": j($response.rrTicks), "value": locals}

proc onEvaluateExpression(sender: js, response: EvaluateExpressionArg) {.async.} =
  var value = await debugger.evaluateExpression(response)
  mainWindow.webContents.send "CODETRACER::evaluate-expression-received", js{"argId": j($response.rrTicks & ":" & $response.expression), "value": value}

proc onEventLoad(sender: js, response: js) {.async.} =
  discard debugger.eventLoad(EmptyArg())

proc onExpandValue(sender: js, response: ExpandValueTarget) {.async.} =
  var value = await debugger.expandValue(response)
  mainWindow.webContents.send "CODETRACER::expand-value-received", js{"argId": j($response.rrTicks & " " & $response.subPath), "value": value}

# proc onExpandValues(sender: js, response: jsobject(expressions=seq[cstring], depth=int, stateCompleteMoveIndex=int)) {.async.} =
#   var values = await debugger.expandValues(response.expressions, response.depth)
#   mainWindow.webContents.send(
#     "CODETRACER::expand-values-received",
#     js{
#       "argId": j($response.stateCompleteMoveIndex & " " & $response.expressions),
#       "value": values})

proc onMinimizeWindow(sender: js, response: JsObject) {.async.} =
  mainWindow.minimize()

proc onRestoreWindow(sender: js, response: JsObject) {.async.} =
  mainWindow.restore()

proc onMaximizeWindow(sender: js, response: JsObject) {.async.} =
  mainWindow.maximize()

proc onCloseWindow(sender: js, response: JsObject) {.async.} =
  mainWindow.close()

when not defined(server):
  app.on("window-all-closed") do ():
    app.quit(0)

proc started*: Future[void] =
  var future = newPromise() do (resolve: (proc: void)):
    if startedFuture.isNil:
      startedFuture = resolve
    mainWindow.webContents.send "CODETRACER::started", js{}
    discard windowSetTimeout(proc =
      if not startedReceived:
        discard started(), 100)
  return future

proc loadExistingRecord(traceId: int) {.async.} =
  debugPrint "[info]: load existing record with ID: ", $traceId
  let trace = await app.findTraceWithCodetracer(traceId)
  data.trace = trace
  data.pluginClient.trace = trace
  if data.trace.compileCommand.len == 0:
    data.trace.compileCommand = data.config.defaultBuild

  debugPrint "index: start ct start_core " & $traceId & " " & $callerProcessPid
  # var process = child_process.spawn(
    # codetracerExe.cstring,
    # TODO: don't hardcode those, use Victor's fields and parseArgs first
    # @[cstring"start_core", cstring($traceId), cstring($callerProcessPid)])

  debugPrint "index: start and setup core ipc"
  await startAndSetupCoreIPC(debugger)

  if not data.trace.isNil:
    debugPrint "index: init debugger"
    discard initDebugger(mainWindow, data.trace, data.config, Helpers())

  debugPrint "index: init frontend"
  mainWindow.webContents.send(
    "CODETRACER::init",
    js{
      home: paths.home.cstring,
      config: data.config,
      layout: data.layout,
      helpers: data.helpers,
      startOptions: data.startOptions,
      bypass: true})

  if not data.trace.isNil:
    debugPrint "index: loading trace in mainWindow"
    await data.loadTrace(mainWindow, data.trace, data.config, data.helpers)

  try:
    let instanceClient = await startSocket(CT_DEBUG_INSTANCE_PATH_BASE & cstring($callerProcessPid))
    instanceClient.on(cstring"data") do (data: cstring):
      let outputLine = data.trim.parseJsInt
      debugPrint "index: ===> output line ", outputLine
      mainWindow.webContents.send cstring"CODETRACER::output-jump-from-shell-ui", outputLine
  except:
    debugPrint "warning: exception when starting instance client:"
    debugPrint "  that's ok, if this was not started from shell-ui!"

proc prepareForLoadingTrace(traceId: int, pid: int) {.async.} =
  callerProcessPid = pid
  let process = await startProcess(
    codetracerExe.cstring,
    @[cstring"start_core", cstring($traceId), cstring($pid)])
  if process.isOk:
    ctStartCoreProcess = process.value
  # keep a reference for later: on close, stop the ct process, which should stop
  #   the backend process as well

proc replayTx(txHash: cstring, pid: int): Future[(cstring, int)] {.async.} =
  callerProcessPid = pid
  let outputResult = await readProcessOutput(
    codetracerExe.cstring,
    @[cstring"arb", cstring"replay", txHash]
  )
  var output = cstring""
  if outputResult.isOk:
    output = outputResult.value
    let lines = output.split(jsNl)
    if lines.len > 1:
      let traceIdLine = $lines[^2]
      # probably because we print `traceId:<traceId>\n` : so the last line is ''
      #   and traceId is in the second last line
      if traceIdLine.startsWith("traceId:"):
        let traceId = traceIdLine[("traceId:").len .. ^1].parseInt
        return (output, traceId)
  else:
    output = JSON.stringify(outputResult.error)
  return (output, NO_INDEX)

proc onLoadRecentTrace*(sender: js, response: jsobject(traceId=int)) {.async.} =
  await prepareForLoadingTrace(response.traceId, nodeProcess.pid.to(int))
  await loadExistingRecord(response.traceId)

proc onLoadRecentTransaction*(sender: js, response: jsobject(txHash=cstring)) {.async.} =
  let (rawOutputOrError, traceId) = await replayTx(response.txHash, nodeProcess.pid.to(int))
  if traceId != NO_INDEX:
    await prepareForLoadingTrace(traceId, nodeProcess.pid.to(int))
    await loadExistingRecord(traceId)
  else:
    # TODO: process notifications in welcome screen, or a different kind of error handler for this case
    # currently not working in frontend, because no status component for now in welcome screen
    # sendNotification(NotificationKind.NotificationError, "couldn't record trace for the transaction")
    echo ""
    echo ""
    echo "ERROR: couldn't record trace for transaction:"
    echo "==========="
    echo "(raw output or error):"
    echo rawOutputOrError
    echo "(end of raw output or error)"
    echo "==========="
    quit(1)
    
proc onLoadTraceByRecordProcessId*(sender: js, pid: int) {.async.} =
  let trace = await app.findTraceByRecordProcessId(pid)
  await prepareForLoadingTrace(trace.id, pid)
  await loadExistingRecord(trace.id)

proc onPathValidation(
  sender: js,
  response: jsobject(
    path=cstring,
    fieldName=cstring,
    required=bool)) {.async.} =

  var message: cstring = ""
  var isValid = true

  if response.path == "" or response.path.isNil:
    if response.required:
      isValid = false
      message = "This field is required."
  else:
    if not await pathExists(response.path):
      isValid = false
      message = cstring("Path does not exist.")

  mainWindow.webContents.send "CODETRACER::path-validated",
    js{
      execPath: response.path,
      isValid: isValid,
      fieldName: response.fieldName,
      message: message
    }

proc onLoadPathForRecord(sender: js, response: jsobject(fieldName=cstring)) {.async.} =
  let options = js{
    # cstring"openFile",
    # for now defaulting on directories for the noir usecase
    properties: @[cstring"openDirectory"],
    title: cstring"Select project or executable to record",
    buttonLabel: cstring"Select",
    # filters: @[FileFilter(
      # This option does not provide a proper way to filter files that are able to be selected to be only binaries.
      # May be we should implement form field validation with a warning message if the user selects a file that is not a binary.
      # name: "binaries",
      # extensions: @[j"bin", j"exe"]
    # )]
  }

  let selection = await selectFileOrFolder(options)

  mainWindow.webContents.send "CODETRACER::record-path",
    js{ execPath: selection, fieldName: response.fieldName }

proc onChooseDir(sender: js, response: jsobject(fieldName=cstring)) {.async.} =
  let selection = await selectDir(cstring(&"Select {capitalize(response.fieldName)}"))
  if selection != "":
    let dirExists = await pathExists(selection)
    mainWindow.webContents.send "CODETRACER::record-path",
      js{execPath: selection, fieldName: response.fieldName}

proc onNewRecord(sender: js, response: jsobject(args=seq[cstring], options=JsObject)) {.async.}=
  let processResult = await startProcess(
    codetracerExe,
    @[j"record"].concat(response.args),
    response.options)

  if processResult.isOk:
    data.recordProcess = processResult.value
    let error = await waitProcessResult(processResult.value)

    if error.isNil:
      debugPrint "recorded successfully"
      mainWindow.webContents.send "CODETRACER::successful-record"
      await onLoadTraceByRecordProcessId(nil, processResult.value.pid)
    else:
      errorPrint "record error: ", error
      if not data.recordProcess.isNil:
        mainWindow.webContents.send "CODETRACER::failed-record",
          js{errorMessage: cstring"codetracer record command failed"}

  else:
    errorPrint "record start process error: ", processResult.error
    let errorSpecificText = if not processResult.error.isNil: cast[cstring](processResult.error.code) else: cstring""
    let errorText = cstring"record start process error: " & errorSpecificText
    mainWindow.webContents.send "CODETRACER::failed-record",
      js{errorMessage: errorText}

proc onInstallCt(sender: js, response: js) {.async.} =
  installDialogWindow = createInstallSubwindow()

type
  InstallResponseKind* {.pure.} = enum Ok, Problem, Dismissed

  InstallResponse = object
    case kind*: InstallResponseKind
    of Ok, Dismissed:
      discard
    of Problem:
      message*: string

var installResponseResolve: proc(response: InstallResponse)

proc onDismissCtFrontend(sender: js, dontAskAgain: bool) {.async.} =
  # very important, otherwise we might try to send a message to it
  # and we get a object is destroyed error or something similar
  installDialogWindow = nil

  if dontAskAgain:
    infoPrint "remembering to not ask again for installation"
    let dir = getHomeDir() / ".config" / "codetracer"
    let configFile = dir / "dont_ask_again.txt"
    fs.writeFile(configFile.cstring, "dont_ask_again=true".cstring, proc(err: js) = discard)
  if not installResponseResolve.isNil:
    installResponseResolve(InstallResponse(kind: InstallResponseKind.Dismissed))

proc onInstallCtFrontend(sender: js, response: js) {.async.} =
  var args = @[cstring"install"]

  if response["desktop"].to(bool):
    args.add(cstring"--desktop")

  if response["path"].to(bool):
    args.add(cstring"--path")

  let res = await readProcessOutput(
    codetracerExe.cstring,
    args)

  let isOk = res.isOk
  let status = if isOk:
      (cstring"ok", cstring"Succesfully installated")
    else:
      # TODO: propagate a more precise message
      (cstring"problem", cstring"there was a problem during installation")

  # leaving this code in, if we decide to re-enable showing
  # status in notifications as well:
  #
  # if not mainWindow.isNil:
  #  mainWindow.webContents.send "CODETRACER::ct-install-status", status

  if not installDialogWindow.isNil:
    installDialogWindow.webContents.send "CODETRACER::ct-install-status", status
  else:
    echo status[1]

proc onStopRecordingProcess(sender: js, response: js) {.async.} =
  if not data.recordProcess.isNil:
    if data.recordProcess.kill():
      data.recordProcess = nil
    else:
      warnPrint "Unable to stop recording process"
  else:
    warnPrint "There is not any recording process"

proc onOpenLocalTrace(sender: js, response: js) {.async.} =
  let selection = await selectDir(j"Select Trace Output Folder", codetracerTraceDir)
  if selection.len == 0:
    errorPrint "no folder selected"
  else:
    # selectDir tries to return a folder with a trailing slash
    let trace = await app.findByPath(selection)
    if not trace.isNil:
      mainWindow.webContents.send "CODETRACER::loading-trace",
        js{trace: trace}
      await prepareForLoadingTrace(trace.id, nodeProcess.pid.to(int))
      await loadExistingRecord(trace.id)
    else:
      errorPrint "There is no record at given path."

proc onLoadCodetracerShell(sender: js, response: js) {.async.} =
  await wait(1_000)
  await startShellUi(mainWindow, data.config)
  await wait(1_000)
  await started()

proc onLoadPathContent(
  sender: js,
  response: jsobject(
    path=cstring,
    nodeId=cstring,
    nodeIndex=int,
    nodeParentIndices=seq[int])) {.async.} =
  # this won't work if we have multiple traces in one index_js instance!
  let traceFilesPath = nodePath.join(data.trace.outputFolder, cstring"files")
  let content = await loadPathContentPartially(
    response.path,
    response.nodeIndex,
    response.nodeParentIndices,
    traceFilesPath,
    selfContained=data.trace.imported)

  if not content.isNil:
    mainWindow.webContents.send "CODETRACER::update-path-content", js{
      content: content,
      nodeId: response.nodeId,
      nodeIndex: response.nodeIndex,
      nodeParentIndices: response.nodeParentIndices}

proc configureIpcMain =

  # handling incoming messages from frontend:
  #   calls on<actionToCamelCase>
  #   with sender, response
  # ipc.on("maximize-window", onMaximizeWindow.toJs)

  indexIpcHandlers("CODETRACER::"):
    # main window controls
    "minimize-window"
    "restore-window"
    "maximize-window"
    "close-window"

    # new-record-screen
    "load-path-for-record"
    "choose-dir"
    "new-record"
    "install-ct"
    "install-ct-frontend"
    "dismiss-ct-frontend"
    "stop-recording-process"
    "load-trace-by-record-process-id"
    "path-validation"

    # welcome screen options
    "load-codetracer-shell"
    "load-recent-trace"
    "open-local-trace"
    "load-recent-transaction"

    "tab-load"
    # "asm-load"
    "load-low-level-tab"

    "dap-raw-message"

    # "update-expansion"
    # "load-tokens"
    # "load-locals"
    # "evaluate-expression"
    # "load-parsed-exprs"
    # "expand-value"
    # "expand-values"
    "save-config"
    # "run-tracepoints"
    # "event-jump"
    # "event-load"
    # "load-terminal"
    # "callstack-jump"
    # "calltrace-jump"
    # "trace-jump"
    # "history-jump"
    # "add-break"
    # "delete-break"
    # "add-break-c"
    # "delete-break-c"
    # "delete-all-breakpoints"
    # "source-line-jump"
    # "source-call-jump"
    # "enable"
    # "disable"
    # "search-calltrace"
    # "update-table"
    # "tracepoint-delete"
    # "tracepoint-toggle"
    # "load-callstack"
    # "load-call-args"
    # "collapse-calls"
    # "expand-calls"
    # "updated-calltrace-args"
    # "reset-operation"
    "exit-error"
    # "update-watches"
    # "save-file"
    # "save-untitled"
    # "update"
    # "save-new"
    # "save-close"
    # "load-history"
    # "load-flow"
    # "load-flow-shape"
    # "setup-trace-session"
    "started"
    "open-tab"
    # "reload-file"
    # "no-reload-file"
    "close-app"
    # "run-to-entry"
    # "search"
    # "search-program"
    # "load-step-lines"
    # "step"
    # "local-step-jump"
    # "open-trace"
    "show-in-debug-instance"
    "send-bug-report-and-logs"

    # Upload/Download
    "upload-trace-file"
    "download-trace-file"
    "delete-online-trace-file"

  when defined(ctmacos):
    indexIpcHandlers("CODETRACER::"):
      "register-menu"

  indexIpcHandlers("CODETRACER::"):
    "restart"

    # "debug-gdb"

    # update filesystem component
    "load-path-content"

const NO_LIMIT = (-1)


proc init(data: var ServerData, config: Config, layout: js, helpers: Helpers) {.async.} =
  debugPrint "index: init"
  let bypass = true

  data.config = config
  # config <- file config combined with cli args and other setup
  # improve this code

  data.config.test = data.config.test #  or data.startOptions.inTest
  # TELEMETRY_ENABLED = false
  # data.layout = layout
  # data.helpers = helpers

  data.startOptions.isInstalled = isCtInstalled(data.config)
  data.config.skipInstall = data.startOptions.isInstalled

  if data.startOptions.shellUi:
    await wait(1_000)
    await startShellUi(mainWindow, data.config)
    await wait(1_000)
    # await startAndSetupCoreIPC(debugger)
    await started()
    return

  # TODO: leave this to backend/DAP if possible
  if not data.startOptions.edit and not data.startOptions.welcomeScreen:
    if bypass:
      let trace = await app.findTraceWithCodetracer(data.startOptions.traceID)
      if trace.isNil:
        errorPrint "trace is not found for ", data.startOptions.traceID
        quit(1)
      data.trace = trace
      data.pluginClient.trace = trace
      if data.trace.compileCommand.len == 0:
        data.trace.compileCommand = data.config.defaultBuild

  if not data.startOptions.welcomeScreen:
    debugPrint "index: start and setup core ipc"
    await startAndSetupCoreIPC(debugger)

  await started()

  if not data.trace.isNil:
    discard initDebugger(mainWindow, data.trace, data.config, Helpers())

  # discard startIPCFileRead(debugger)
  if not data.startOptions.edit and not data.startOptions.welcomeScreen:
    debugPrint "send ", "CODETRACER::init"
    debugPrint data.startOptions

    mainWindow.webContents.send(
      "CODETRACER::init",
      js{
        home: paths.home.cstring,
        config: data.config,
        layout: layout,
        helpers: helpers,
        startOptions: data.startOptions,
        bypass: bypass})

    if bypass:
      if not data.trace.isNil:
        await data.loadTrace(mainWindow, data.trace, data.config, helpers)

    try:
      let instanceClient = await startSocket(CT_DEBUG_INSTANCE_PATH_BASE & cstring($callerProcessPid), expectPossibleFail=true)
      instanceClient.on(cstring"data") do (data: cstring):
        let outputLine = data.trim.parseJsInt
        debugPrint "=> output line ", outputLine
        mainWindow.webContents.send cstring"CODETRACER::output-jump-from-shell-ui", outputLine
    except:
      debugPrint "index: warning: exception when starting instance client:"
      debugPrint "  that's ok, if this was not started from shell-ui!"


  elif data.startOptions.edit:
    let file = ($data.startOptions.name)
    # let fs = await cast[Future[js]](fsAsync.lstat(file))
    var folder = data.startOptions.folder
    # if cast[bool](fs.isFile()):
    #   folder = ($data.startOptions.name).rsplit("/", 1)[0]
    # else:
    #   folder = file
    #   data.startOptions.name = j""
    # if not folder.endsWith("/"):
    #   folder = folder & "/"
    var filenames = await loadFilenames(@[folder], traceFolder=cstring"", selfContained=false)
    var filesystem = await loadFilesystem(@[folder], traceFilesPath=cstring"", selfContained=false)
    var functions: seq[Function] = @[] # TODO load with rg or similar?
    var save = await getSave(@[folder], data.config.test)
    data.save = save

    # debug "folder", folder
    mainWindow.webContents.send "CODETRACER::no-trace", js{
      path: data.startOptions.name,
      lang: save.project.lang,
      home: paths.home.cstring,
      layout: layout,
      helpers: helpers,
      startOptions: data.startOptions,
      config: data.config,
      filenames: filenames,
      filesystem: filesystem,
      functions: functions,
      save: save
    }
  else:
    let recentTraces = await app.findRecentTracesWithCodetracer(limit=NO_LIMIT)
    var recentTransactions: seq[StylusTransaction] = @[]
    if data.startOptions.stylusExplorer:
      recentTransactions = await app.findRecentTransactions(limit=NO_LIMIT)
    mainWindow.webContents.send "CODETRACER::welcome-screen", js{
      home: paths.home.cstring,
      layout: layout,
      startOptions: data.startOptions,
      config: data.config,
      recentTraces: recentTraces,
      recentTransactions: recentTransactions
    }

when not defined(ctRepl) and not defined(server):
  var requireDirect {.importcpp: "remote.rendererRequireDirect(require.resolve('./debugger'))".}: proc (): Future[js]

var process {.importc.}: js

proc isCtInstalled(config: Config): bool =
  if not config.skipInstall:
    if process.platform == "darwin".toJs:
      let ctLaunchersPath = cstring($paths.home / ".local" / "share" / "codetracer" / "shell-launchers" / "ct")
      return fs.existsSync(ctLaunchersPath)
    else:
      let dataHome = getEnv("XDG_DATA_HOME", getEnv("HOME") / ".local/share")
      let dataDirs = getEnv("XDG_DATA_DIRS", "/usr/local/share:/usr/share").split(':')

      # if we find the desktop file then it's installed by the package manager automatically
      for d in @[dataHome] & dataDirs:
        if fs.existsSync(d / "applications/codetracer.desktop"):
          return true
      return false
  else:
    return true

proc waitForResponseFromInstall: Future[InstallResponse] {.async.} =
  return newPromise() do (resolve: proc(response: InstallResponse)):
    installResponseResolve = resolve


proc ready {.async.} =
  # we configure the listeners
  configureIpcMain()

  # we load the config file
  var config = await mainWindow.loadConfig(data.startOptions, home=paths.home.cstring, send=true)

  config.skipInstall = isCtInstalled(config)
  if not config.skipInstall:
    installDialogWindow = createInstallSubwindow()
    discard await waitForResponseFromInstall()

  debugPrint "index: creating window"
  mainWindow = createMainWindow()

  when not defined(server):
    mainWindow.setMenuBarVisibility(false)
    mainWindow.setMenu(jsNull)
  # TODO cleanup code
  data.pluginClient = PluginClient(
    cancelled: false,
    running: false,
    cancelOrWaitFunction: nil,
    window: mainWindow,
    trace: nil,
    startOptions: data.startOptions)

  when not defined(server):
    # we hook output code in send for debug
    var internalSend = mainWindow.webContents.send
    mainWindow.webContents.send = proc(id: cstring, data: js) =
      # debug "send", _ = $id
      # too much content sometimes here, just log we did it
      if id == "filenames-loaded":
        debugPrint cstring"frontend ... <=== index: ", id, "[..not shown to optimize send time..]"
      else:
        debugPrint cstring"frontend ... <=== index: ", id
      debugIndex fmt"frontend ... <=== index: {id}"  # TODO? too big: {Json.stringify(data, nil, 2.toJs)}"
      debugSend(mainWindow.webContents, internalSend, id, data)
  else:
    proc replacer(key: cstring, value: js): js =
      if key == cstring"m_type":
        undefined
      else:
        value

    mainWindow.webContents.send = proc(id: cstring, response: js) =
      debugPrint cstring"frontend ... <=== index: ", id, response
      let serialized = JSON.stringify(response, replacer, 2.toJs)
      debugIndex fmt"frontend ... <=== index: {id}"  # TODO? too big: {serialized}"
      ipc.socket.emit(id, serialized)

  # we load the layout
  # let layout = if data.startOptions.inTest:
  #   await mainWindow.loadLayoutConfig(&"{codetracerTestDir}/layouts/{config.layout}.json")
  # else:
  #   await mainWindow.loadLayoutConfig(&"{userLayoutDir}{config.layout}.json")

  let layout = await mainWindow.loadLayoutConfig(&"{userLayoutDir / $config.layout}.json")
  data.layout = layout
  # we load helpers
  let helpers = await mainWindow.loadHelpers("/data" / "data.yaml")
  data.helpers = helpers

  # init the UI
  discard windowSetTimeout(proc = discard data.init(config, layout, helpers), 250)

# start
parseArgs()

proc matchRegex(text: string, pattern: string): JsObject {.importjs: "#.match(new RegExp(#, 'm'))".}

# proc extractExecCommandJs(desktopFile: string): string =
#   let content = readFileJs(cstring(desktopFile))
#
#   console.log("CONTENT")
#   echo content
#
#   let matches = matchRegex(content, "^Exec=(.*)$")
#
#   console.log(matches)
#
#   if matches != nil and matches[1] != nil:
#     return matches[1].to(string)
#
#   echo "NO MATCH FOUND"
#
#   return ""  # Return empty if no match found


when not defined(server):
  app.on("ready") do ():
    app.js.setName "CodeTracer"
    app.js.setAppUserModelId "com.codetracer.CodeTracer"
    discard ready()
else:
  readyVar = functionAsJs(ready)
  setupServer()
  # discard ready()
