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
else:
  var electronDebug = require("electron-debug")
  let app = cast[ElectronApp](electron.app)
  let Menu = electron.Menu

data.start = now()

var
  close = false
  backendManagerProcess: NodeSubProcess = nil
  backendManagerCleanedUp = false

proc stopBackendManager() =
  # Ensure we only attempt cleanup once and guard against nil.
  if backendManagerCleanedUp:
    return
  backendManagerCleanedUp = true
  if not backendManagerProcess.isNil:
    backendManagerProcess.stopProcess()
    backendManagerProcess = nil

proc showOpenDialog(dialog: JsObject, browserWindow: JsObject, options: JsObject): Future[JsObject] {.importjs: "#.showOpenDialog(#,#)".}
proc loadExistingRecord(traceId: int) {.async.}
proc prepareForLoadingTrace(traceId: int, pid: int) {.async.}
proc isCtInstalled(config: Config): bool

proc asyncSleep(ms: int): Future[void] =
  let future = newPromise() do (resolve: (proc: void)):
    discard windowSetTimeout(resolve, ms)
  return future

proc onClose(e: js) =
  if not data.config.isNil and data.config.test:
    discard
  elif not close:
    # TODO refactor to use just `client.send`
    mainWindow.webContents.send "CODETRACER::close", js{}
    close = true

# <traceId>
# --port <port>
# --frontend-socket-port <frontend-socket-port>
# --frontend-socket-parameters <frontend-socket-parameters>
# --backend-socket-port <backend-socket-port>
# --caller-pid <callerPid>
# # eventually if needed --backend-socket-host <backend-socket-host>
proc parseArgs =
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

proc selectFileOrFolder(options: JsObject): Future[cstring] {.async.} =
  let selection = await electron.dialog.showOpenDialog(mainWindow, options)
  let filePaths = cast[seq[cstring]](selection.filePaths)

  if filePaths.len > 0:
    return filePaths[0]
  else:
    return cstring""

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
    let inDevEnv = nodeProcess.env[cstring"CODETRACER_DEV_TOOLS"] == cstring"1"
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

    let inDevEnv = nodeProcess.env[cstring"CODETRACER_DEV_TOOLS"] == cstring"1"
    if inDevEnv:
      electronDebug.devTools(win)

    win.toJs

type
  DebuggerInfo = object of JsObject
    path: cstring
    exe: seq[cstring]

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
        if not cast[bool](child.menuOs and ord(MenuNodeOSNonMacOS)) and not cast[bool](child.menuOs and ord(MenuNodeOSHost)):
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

proc onSaveConfig(sender: js, response: jsobject(name=cstring, layout=cstring)) {.async.} =
  warnprint "FOR NOW: persisting config disabled"

proc onExitError(sender: js, response: cstring) {.async.} =
  # we call this on fatal errors
  errorPrint fmt"exit: {response}"
  if true: # workaround for unreachable statement and async
    quit(1)

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

proc onCloseApp(sender: js, response: js) {.async.} =
  # TODO: maybe send shutdown message
  stopBackendManager()
  mainWindow.close()

proc onRestart(sender: js, response: js) {.async.} =
  quit(RESTART_EXIT_CODE)

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

let CT_DEBUG_INSTANCE_PATH_BASE*: cstring = cstring(codetracerTmpPath) & cstring"/ct_instance_"

proc newDebugInstancePipe(pid: int): Future[JsObject] {.async.} =
  var future = newPromise() do (resolve: proc(response: JsObject)):
    var connections: seq[JsObject] = @[nil.toJs]
    let path = CT_DEBUG_INSTANCE_PATH_BASE & cstring($pid)
    connections[0] = net.createServer(proc(server: JsObject) =
      infoPrint "index: connected instance server for ", path
      resolve(server))

    connections[0].on(cstring"error") do (error: js):
      errorPrint "index: socket instance server error: ", error
      resolve(nil.toJs)

    connections[0].listen(path)
  return await future

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
    # Make sure the backend-manager process is killed on window close.
    stopBackendManager()
    app.quit(0)

  # Proactively stop the backend-manager on any app quit lifecycle event.
  app.on("before-quit") do ():
    stopBackendManager()

  # Ensure signal-driven exits also terminate the backend-manager.
  nodeProcess.on(cstring"SIGINT") do ():
    stopBackendManager()
    app.quit(0)

  nodeProcess.on(cstring"SIGTERM") do ():
    stopBackendManager()
    app.quit(0)

  nodeProcess.on(cstring"SIGHUP") do ():
    stopBackendManager()
    app.quit(0)

  # As a last resort, cleanup on process exit as well.
  nodeProcess.on(cstring"exit") do (code: int):
    stopBackendManager()

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
  # TODO: use type/function for this
  let packet = wrapJsonForSending js{
    "type": cstring"request",
    "command": cstring"ct/start-replay",
    "arguments": [dbBackendExe.cstring]
  }
  backendManagerSocket.write(packet)

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

proc onOpenDevTools =
  electronDebug.devTools(mainWindow)

# handling incoming messages from frontend:
#   calls on<actionToCamelCase>
#   with sender, response
# ipc.on("maximize-window", onMaximizeWindow.toJs)
proc configureIpcMain =
  indexIpcHandlers("CODETRACER::"):
    # main window controls
    "minimize-window"
    "restore-window"
    "maximize-window"
    "close-window"

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
    "load-low-level-tab"

    "dap-raw-message"

    "save-config"
    "exit-error"
    "started"
    "open-tab"
    "close-app"
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
    # update filesystem component
    "load-path-content"

    "open-devtools"

const NO_LIMIT = (-1)

proc init(data: var ServerData, config: Config, layout: js, helpers: Helpers) {.async.} =
  debugPrint "index: init"
  let bypass = true

  data.config = config
  data.config.test = data.config.test
  data.startOptions.isInstalled = isCtInstalled(data.config)
  data.config.skipInstall = data.startOptions.isInstalled

  if data.startOptions.shellUi:
    await wait(1_000)
    await startShellUi(mainWindow, data.config)
    await wait(1_000)
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
      await prepareForLoadingTrace(trace.id, nodeProcess.pid.to(int))

  # if not data.startOptions.welcomeScreen:
    # debugPrint "index: start and setup core ipc"
    # await startAndSetupCoreIPC()

  await started()

  if not data.trace.isNil:
    discard initDebugger(mainWindow, data.trace, data.config, Helpers())

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
    var folder = data.startOptions.folder
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
  when defined(server):
    return true
  else:
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
  let backendManager = await startProcess(backendManagerExe.cstring, @[], js{ "stdio": cstring"inherit" })
  if backendManager.isOk:
    backendManagerProcess = backendManager.value

  let backendManagerSocketPath = codetracerTmpPath / "backend-manager" / $backendManagerProcess.pid & ".sock"

  await asyncSleep(100)
  while true:
    backendManagerSocket = await startSocket(backendManagerSocketPath)
    if not backendManagerSocket.isNil:
      break
    await asyncSleep(1000)

  setupProxyForDap(backendManagerSocket)

  # we configure the listeners
  configureIpcMain()

  # we load the config file
  var config = await mainWindow.loadConfig(data.startOptions, home=paths.home.cstring, send=true)

  when not defined(server):
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

  let layout = await mainWindow.loadLayoutConfig(&"{userLayoutDir / $config.layout}.json")
  data.layout = layout
  # we load helpers
  let helpers = await mainWindow.loadHelpers("/data" / "data.yaml")
  data.helpers = helpers

  # init the UI
  discard windowSetTimeout(proc = discard data.init(config, layout, helpers), 250)

# start
parseArgs()

when not defined(server):
  app.on("ready") do ():
    app.js.setName "CodeTracer"
    app.js.setAppUserModelId "com.codetracer.CodeTracer"
    discard ready()
else:
  readyVar = functionAsJs(ready)
  setupServer()
