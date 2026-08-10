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

  # Multi-window management (M15):
  # windowTable maps BrowserWindow.id to the BrowserWindow JS object.
  # sessionWindows maps a session ID to the list of window IDs showing that session.
  # These coexist with mainWindow for backwards compatibility — existing code
  # that references mainWindow continues to work unchanged.
  windowTable*: JsAssoc[int, JsObject]   = JsAssoc[int, JsObject]{}
  sessionWindows*: JsAssoc[int, seq[int]] = JsAssoc[int, seq[int]]{}

proc broadcastToSession*(sessionId: int, channel: cstring, payload: JsObject) =
  ## Send an IPC message to all windows belonging to the given session.
  ## Falls back to the legacy mainWindow when no session entry exists.
  if sessionWindows.hasKey(sessionId):
    for windowId in sessionWindows[sessionId]:
      if windowTable.hasKey(windowId):
        windowTable[windowId].webContents.send(channel, payload)
  elif not mainWindow.isNil:
    mainWindow.webContents.send(channel, payload)

console.time(cstring"index: starting backend")
