import
  std/[jsffi, jsconsole, strutils],
  lib/[ jslib, electron_lib ],
  index/[ args, ipc_utils, electron_vars, server_config, config, window ]

data.start = now()
parseArgs()

when not defined(server):
  # --------------------------------------------------------------------------
  # Single-instance lock for the "tab" newTracePolicy.
  #
  # When the policy is "tab" (the default), a second `ct run` / `ct replay`
  # invocation should open the trace as a new tab in the existing window
  # rather than spawning a new Electron window.
  #
  # We use Electron's requestSingleInstanceLock() to detect whether another
  # instance is already running.  If the lock fails, the second instance
  # sends its trace ID via the command-line argv and quits.  The first
  # instance receives a "second-instance" event and loads the trace in a
  # new tab.
  # --------------------------------------------------------------------------
  let effectivePolicy =
    if electronProcess.env.hasKey(cstring"CODETRACER_NEW_TRACE_POLICY"):
      $electronProcess.env[cstring"CODETRACER_NEW_TRACE_POLICY"]
    else:
      "tab"

  if effectivePolicy == "tab":
    let gotLock = electron_vars.app.js.requestSingleInstanceLock().to(bool)

    if not gotLock:
      # Another CodeTracer instance already owns the lock.
      # It will receive our argv via the "second-instance" event.
      # Quit immediately — the first instance will open our trace.
      console.log cstring"index: single-instance lock not acquired — delegating to existing instance"
      electron_vars.app.quit(0)
      nodeProcess.exit(0)
    else:
      # We are the first instance.  Listen for second-instance events.
      electron_vars.app.on("second-instance") do (event: js, argv: js, workingDirectory: js):
        # The second instance passes the trace ID as the first positional arg
        # to Electron (argv[2+] after electron binary and entry point).
        # Parse it out and tell the renderer to open the trace in a new tab.
        console.log cstring"index: second-instance event received"

        # Bring the main window to front.
        if not mainWindow.isNil:
          if mainWindow.isMinimized().to(bool):
            mainWindow.restore()
          mainWindow.focus()

        # Extract the command from the second instance's argv.
        # Supported formats:
        #   ct <traceId> [--test] [--diff ...]
        #   ct edit <path>
        # Electron can prepend runtime flags to argv, so scan for the first
        # CodeTracer command instead of assuming a fixed argv[2] position.
        let argvLen = argv.length.to(int)
        var handledSecondInstance = false
        for i in 2 ..< argvLen:
          if handledSecondInstance:
            break

          let argText = $argv[i].to(cstring)
          if argText == "edit" and i + 1 < argvLen and not mainWindow.isNil:
            let rawEditPath = argv[i + 1].to(cstring)
            let editPathText = $rawEditPath
            let isAbsolute = editPathText.len > 0 and
              (editPathText[0] == '/' or
               (editPathText.len >= 3 and editPathText[1] == ':' and
                (editPathText[2] == '\\' or editPathText[2] == '/')))
            let editPath =
              if isAbsolute:
                rawEditPath
              else:
                nodePath.join(workingDirectory.to(cstring), rawEditPath)
            console.log cstring"index: opening edit folder ", editPath, cstring" in new tab (second-instance)"
            mainWindow.webContents.send(
              "CODETRACER::open-edit-folder-in-tab-ready",
              js{folderPath: editPath})
            handledSecondInstance = true
          elif argText.len > 0 and argText[0] != '-':
            try:
              let traceId = parseInt(argText)
              if traceId > 0 and not mainWindow.isNil:
                console.log cstring"index: opening trace ", cstring($traceId), cstring" in new tab (second-instance)"
                # Signal the renderer to create a new session tab and prepare
                # the trace.  The renderer handles this by creating a new
                # session, and the onOpenTraceInTab IPC handler starts the
                # backend replay and sends the trace data.
                mainWindow.webContents.send(
                  "CODETRACER::open-trace-in-tab-ready",
                  js{traceId: traceId})
                handledSecondInstance = true
            except ValueError:
              discard

        if not handledSecondInstance:
          console.log cstring"index: second-instance argv did not contain an edit command or trace ID"

  electron_vars.app.on("window-all-closed") do ():
    stopBackendManager()
    electron_vars.app.quit(0)

  electron_vars.app.on("before-quit") do ():
    stopBackendManager()

  # Ensure signal-driven exits also terminate the session-manager.
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
