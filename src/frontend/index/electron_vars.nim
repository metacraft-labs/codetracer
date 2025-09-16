import
  std / [ jsffi, jsconsole ],
  ../lib


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
  var electronDebug* = require("electron-debug")

var
  callerProcessPid*: int = -1
  mainWindow*: JsObject

console.time(cstring"index: starting backend")