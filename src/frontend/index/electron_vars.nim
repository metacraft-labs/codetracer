import
  std / [ jsffi, jsconsole ],
  ../lib/[ jslib, electron_lib ]


# We have two main modes: server and desktop.
# By default we compile in desktop.
# In server mode we don't have electron, so we immitate or disable some of the code
# a lot of the logic is in index_config.nim/lib.nim and related
when defined(server):
  let
    electron* = ServerElectron().toJs
    dialog: js = undefined
    app*: ElectronApp = ElectronApp()
  var electronDebug*: js = undefined
else:
  let
    electron* = require("electron")
    dialog = electron.dialog
    app* = cast[ElectronApp](electron.app)
    Menu* = electron.Menu
  var electronDebug*: js = try: require("electron-debug") except: undefined

var
  callerProcessPid*: int = -1
  mainWindow*: JsObject
    ## Where the main process sends what it says and does what it does to
    ## "the window". On the desktop it is `window_routing.windowRouter()`:
    ## the window whose request is being served (else the primary one), with
    ## a `webContents.send` that routes per window (`window_routing`). In
    ## `ct host` it is the server's `FrontendIPC`, routed per client
    ## (`host_clients`). The tests set a stand-in.

console.time(cstring"index: starting backend")
