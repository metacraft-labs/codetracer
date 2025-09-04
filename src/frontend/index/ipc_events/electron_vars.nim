import
  std / [ jsffi, json ],
  ../../[ index_config, lib ]


# We have two main modes: server and desktop.
# By default we compile in desktop.
# In server mode we don't have electron, so we immitate or disable some of the code
# a lot of the logic is in index_config.nim/lib.nim and related
when defined(server):
  var electronDebug*: js = undefined
  let app*: ElectronApp = ElectronApp()
else:
  var electronDebug* = require("electron-debug")
  let app* = cast[ElectronApp](electron.app)
  let Menu* = electron.Menu