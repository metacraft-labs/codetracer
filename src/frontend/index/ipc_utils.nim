import
  std / [ async, jsffi, strutils, jsconsole, sugar, json, os, strformat ],
  electron_vars, traces, files, startup, install, menu, online_sharing, window, logging, config, debugger, server_config, base_handlers,
  ipc_subsystems/[ dap, socket ],
  results,
  ../[ lib, types, config, trace_metadata ],
  ../../common/[ ct_logging, paths ]

# handling incoming messages from frontend:
#   calls on<actionToCamelCase>
#   with sender, response
# ipc.on("maximize-window", onMaximizeWindow.toJs)
proc configureIpcMain* =
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


proc loadHelpers(main: js, filename: string): Future[Helpers] {.async.} =
  var file = j(userConfigDir & filename)
  let (raw, err) = await fsReadFileWithErr(file)
  if not err.isNil:
    return JsAssoc[cstring, Helper]{}
  var res = cast[Helpers](yaml.load(raw)[j"helpers"])
  return res

proc ready* {.async.} =
  let backendManager = await startProcess(backendManagerExe.cstring, @[], js{ "stdio": cstring"inherit" })
  if backendManager.isOk:
    backendManagerProcess = backendManager.value

  let backendManagerSocketPath = getTempDir() / "codetracer" / "backend-manager" / $backendManagerProcess.pid & ".sock"

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

  let layout = await mainWindow.loadLayoutConfig(string(fmt"{userLayoutDir / $config.layout}.json"))
  data.layout = layout
  # we load helpers
  let helpers = await mainWindow.loadHelpers("/data" / "data.yaml")
  data.helpers = helpers

  # init the UI
  discard windowSetTimeout(proc = discard data.init(config, layout, helpers), 250)
