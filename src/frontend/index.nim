import
  std/jsffi,
  lib,
  index/[ args, ipc_utils, electron_vars, server_config, config ]

data.start = now()
parseArgs()

when not defined(server):
  electron_vars.app.on("window-all-closed") do ():
    electron_vars.app.quit(0)

  electron_vars.app.on("ready") do ():
    electron_vars.app.js.setName "CodeTracer"
    electron_vars.app.js.setAppUserModelId "com.codetracer.CodeTracer"
    discard ready()
else:
  readyVar = functionAsJs(ready)
  setupServer()
