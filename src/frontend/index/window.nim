import
  std / [ async, jsffi, json, strutils, strformat ],
  electron_vars, server_config, base_handlers, config,
  ../lib/[ jslib, electron_lib ],
  ../[ types ],
  ../../common/[ paths, ct_logging ]

var
  close = false
  backendManagerProcess*: NodeSubProcess = nil
  backendManagerCleanedUp = false

proc stopProcess(process: NodeSubProcess) =
  process.toJs.kill()

proc stopBackendManager* =
  # Ensure we only attempt cleanup once and guard against nil.
  if backendManagerCleanedUp:
    return
  backendManagerCleanedUp = true
  if not backendManagerProcess.isNil:
    backendManagerProcess.stopProcess()
    backendManagerProcess = nil

proc duration*(name: string) =
  infoPrint fmt"index: TIME for {name}: {now() - data.start}ms"

proc onOpenDevTools* =
  electronDebug.devTools(mainWindow)

proc onClose*(e: js) =
  if not data.config.isNil and data.config.test:
    discard
  elif not close:
    # TODO refactor to use just `client.send`
    mainWindow.webContents.send "CODETRACER::close", js{}
    close = true

proc createMainWindow*: js =
  when not defined(server):
    # TODO load from config

    let iconPath = linksPath & "/resources/Icon.iconset/icon_256x256.png"

    let win = jsnew electron.BrowserWindow(
      js{
        "title": cstring"CodeTracer",
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


proc onCloseApp*(sender: js, response: js) {.async.} =
  stopBackendManager()
  mainWindow.close()

proc onRestart*(sender: js, response: js) {.async.} =
  quit(RESTART_EXIT_CODE)

proc onMinimizeWindow*(sender: js, response: JsObject) {.async.} =
  mainWindow.minimize()

proc onRestoreWindow*(sender: js, response: JsObject) {.async.} =
  mainWindow.restore()

proc onMaximizeWindow*(sender: js, response: JsObject) {.async.} =
  mainWindow.maximize()

proc onCloseWindow*(sender: js, response: JsObject) {.async.} =
  mainWindow.close()

proc onSaveConfig*(sender: js, response: jsobject(name=cstring, layout=cstring)) {.async.} =
  warnprint "FOR NOW: persisting config disabled"

proc onExitError*(sender: js, response: cstring) {.async.} =
  # we call this on fatal errors
  errorPrint fmt"exit: {response}"
  if true: # workaround for unreachable statement and async
    quit(1)
