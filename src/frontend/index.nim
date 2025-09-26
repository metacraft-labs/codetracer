import
  std/jsffi,
  lib/[ jslib, electron_lib ],
  index/[ args, ipc_utils, electron_vars, server_config, config, window ]

data.start = now()
parseArgs()

when not defined(server):
  electron_vars.app.on("window-all-closed") do ():
    stopBackendManager()
    electron_vars.app.quit(0)

  electron_vars.app.on("before-quit") do ():
    stopBackendManager()

  # Ensure signal-driven exits also terminate the backend-manager.
  nodeProcess.on(cstring"SIGINT") do ():
    stopBackendManager()
    electron_vars.app.quit(0)

  nodeProcess.on(cstring"SIGTERM") do ():
    stopBackendManager()
    electron_vars.app.quit(0)

  nodeProcess.on(cstring"SIGHUP") do ():
    stopBackendManager()
    electron_vars.app.quit(0)

  # As a last resort, cleanup on process exit as well.
  nodeProcess.on(cstring"exit") do (code: int):
    stopBackendManager()

  electron_vars.app.on("ready") do ():
    electron_vars.app.js.setName "CodeTracer"
    electron_vars.app.js.setAppUserModelId "com.codetracer.CodeTracer"
    discard ready()
else:
  readyVar = functionAsJs(ready)
  setupServer()
