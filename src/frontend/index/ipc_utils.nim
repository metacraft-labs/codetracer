import
  std / [ async, jsffi, strutils, sequtils, jsconsole, sugar, json, os, strformat ],
  electron_vars, traces, files, startup, install, menu, online_sharing, window, logging, config, debugger, server_config, base_handlers, bootstrap_cache, lsp_bridge,
  ipc_subsystems/[ dap, socket, acp_ipc ],
  results,
  ../lib/[ jslib, misc_lib, electron_lib ],
  ../[ types, config, trace_metadata ],
  ../../common/[ ct_logging, paths ]

var Object {.importc, nodecl.}: JsObject

proc fsExistsSync(path: cstring): bool {.importjs: "require('fs').existsSync(#)".}

proc jsEmptyArray: JsObject {.importjs: "([])".}
  ## Return a fresh empty JS array.  Used to satisfy ``nimCopy``'s
  ## ``.length`` read when the renderer deserializes ``seq[SearchResult]``
  ## — without this, the ``customFields`` field arrives as ``undefined``
  ## and the copy crashes with "Cannot read properties of undefined
  ## (reading 'length')``.

proc onSearchProgram*(sender: js, response: cstring) {.async.} =
  ## Handle ``CODETRACER::search-program`` from the renderer.
  ##
  ## Uses ripgrep (``rg``) to search the trace's resolved source folders for
  ## the given query string, then streams batches of 50 results back to the
  ## renderer as ``CODETRACER::search-results-updated`` messages so the Find
  ## in Files panel starts populating immediately.
  ##
  ## Falls back to the ``outputFolder/files/`` subtree for self-contained /
  ## imported traces that have no live source folders recorded.
  let query = $response
  if query.len == 0:
    return

  # Resolve the search roots from the trace metadata.
  let sourceFolders = await sourceFoldersFromTracePaths(data.trace)
  var searchRoots: seq[string] = @[]
  for f in sourceFolders:
    let s = $f
    if s.len > 0:
      searchRoots.add(s)

  # Filter searchRoots to the trace workdir subtree only.
  # Some recorders (e.g. Ruby) include gem/stdlib paths in sourceFolders,
  # which would make rg search /nix/store/, /usr/lib/ruby/, ~/.gem/ etc.
  # We only want to search files the user actually wrote, so we restrict to
  # paths under the trace's working directory when one is available.
  if not data.trace.isNil:
    let workdir = $data.trace.workdir
    if workdir.len > 0:
      let filtered = searchRoots.filterIt(it.startsWith(workdir))
      if filtered.len > 0:
        searchRoots = filtered
      elif searchRoots.len > 0:
        # None of the recorded source folders are under workdir — use workdir
        # itself as the search root so at least the project files are searched.
        searchRoots = @[workdir]

  # Fallback for self-contained traces: search the materialized files tree.
  if searchRoots.len == 0 and not data.trace.isNil:
    let filesRoot = $nodePath.join(data.trace.outputFolder, cstring"files")
    if fsExistsSync(cstring(filesRoot)):
      searchRoots.add(filesRoot)
    elif ($data.trace.outputFolder).len > 0:
      searchRoots.add($data.trace.outputFolder)

  if searchRoots.len == 0:
    infoPrint "onSearchProgram: no source folders for query: ", query
    return

  # Escape the query and build the ripgrep invocation.
  #   -n   include line numbers
  #   -F   treat query as a literal string, not a regex
  #   -i   case-insensitive
  #   -H   always print the filename (even when searching a single file)
  #   --no-heading  one line per match: path:line:text
  let escapedQuery = query.replace("'", "'\\''")
  let rootsArg = searchRoots.mapIt("'" & it.replace("'", "'\\''") & "'").join(" ")
  let rgCmd = cstring(&"rg -n -F -i -H --no-heading -- '{escapedQuery}' {rootsArg}")

  infoPrint "onSearchProgram: rg query=", query, " roots=", rootsArg

  # rg exits with code 1 for no matches — that is not an error.
  let (stdoutData, _, _) = await childProcessExec(rgCmd)

  let lines = ($stdoutData).splitLines()
  var batch: seq[JsObject] = @[]
  for rawLine in lines:
    if rawLine.len == 0:
      continue
    # rg -H --no-heading output:  path:linenum:text
    # Paths on Linux do not contain colons, so the first two colons delimit.
    let colonIdx1 = rawLine.find(':')
    if colonIdx1 < 0:
      continue
    let colonIdx2 = rawLine.find(':', colonIdx1 + 1)
    if colonIdx2 < 0:
      continue
    let filePath = rawLine[0 ..< colonIdx1]
    let lineStr  = rawLine[colonIdx1 + 1 ..< colonIdx2]
    let lineText = rawLine[colonIdx2 + 1 .. ^1]
    var lineNum = 0
    try:
      lineNum = parseInt(lineStr)
    except:
      continue
    batch.add(js{text: cstring(lineText), path: cstring(filePath), line: lineNum, customFields: jsEmptyArray()})
    if batch.len >= 50:
      mainWindow.webContents.send "CODETRACER::search-results-updated", batch.toJs
      batch = @[]

  # Always send the final batch, even when empty, so the renderer can
  # clear the loading shimmer when ripgrep finds no matches.
  mainWindow.webContents.send "CODETRACER::search-results-updated", batch.toJs

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
    "save-file"
    "save-untitled"
    "no-reload-file"
    "run-test"
    "restart-subsystem"

    # welcome screen options
    "load-codetracer-shell"
    "load-recent-trace"
    "open-local-trace"
    "open-folder-dialog"
    "load-recent-folder"
    "load-recent-transaction"
    "open-trace-dialog"
    "load-trace-file"
    "record-from-launch"
    "record-with-launch-config"
    "init-edit-mode"

    "tab-load"
    "load-low-level-tab"

    # Dap
    "dap-raw-message"

    # LSP
    "start-lsp"

    # Acp
    "acp-prompt"
    "acp-session-init"
    "acp-stop"
    "acp-cancel-prompt"

    "save-config"
    # Auto-hide (pinned panel) state.  It is persisted separately from the
    # GoldenLayout config because pinning a panel REMOVES it from the
    # GoldenLayout tree — see `onSaveAutoHideState` in `index/window.nim`.
    # `request-auto-hide-state` answers an `ipcRenderer.sendSync` from
    # `ui/layout.nim`'s `initLayout`.
    "save-auto-hide-state"
    "request-auto-hide-state"
    "exit-error"
    "started"
    "open-tab"
    "close-app"
    "show-in-debug-instance"
    "send-bug-report-and-logs"

    # Multi-window (M17)
    "open-new-window"

    # Open trace as a new tab in the current window (tab-vs-window policy)
    "open-trace-in-tab"

    # Cross-window panel transfer (M21)
    "panel-detach"
    "list-windows"

    # Session lifecycle
    "close-replay-session"

    # Upload/Download
    "upload-trace-file"
    "download-trace-file"
    "delete-online-trace-file"
    "lsp-get-url"


  when defined(ctmacos):
    indexIpcHandlers("CODETRACER::"):
      "register-menu"

  indexIpcHandlers("CODETRACER::"):
    "restart"
    # update filesystem component
    "load-path-content"
    "open-devtools"
    "search-program"


proc loadHelpers(main: js, filename: string): Future[Helpers] {.async.} =
  var file = cstring(userConfigDir & filename)
  let (raw, err) = await fsReadFileWithErr(file)
  if not err.isNil:
    return JsAssoc[cstring, Helper]{}
  var res = cast[Helpers](yaml.load(raw)[cstring"helpers"])
  return res

let runtimePlatform {.importjs: "process.platform", nodecl.}: cstring

proc ready*(): Future[void] {.async.} =
  infoPrint "index: ready start"
  infoPrint "index: backendManagerExe = ", backendManagerExe
  let spawnOptions = when defined(windows):
    js{ "windowsHide": true }
  else:
    js{ "stdio": cstring"inherit" }
  let processEnv = js{}
  let nodeEnv = nodeProcess.toJs.env
  let envKeys = Object.keys(nodeEnv)
  for i in 0..<cast[int](envKeys.length):
    let key = envKeys[i].to(cstring)
    processEnv[key] = nodeEnv[key]
  processEnv[cstring"CODETRACER_TMP_PATH"] = cstring(codetracerTmpPath)
  spawnOptions["env"] = processEnv
  let backendManager = await startProcess(backendManagerExe.cstring, @[], spawnOptions)
  if backendManager.isOk:
    backendManagerProcess = backendManager.value
    infoPrint "index: session-manager started, pid = ", $backendManagerProcess.pid
  else:
    errorPrint "index: session-manager FAILED to start: ", backendManager.error
    errorPrint "index: backendManagerExe was: ", backendManagerExe

  if runtimePlatform == cstring"win32":
    # On Windows, the session-manager uses TCP on localhost.
    # It writes the port number to a .port file.
    let portFilePath = codetracerTmpPath / "session-manager" / $backendManagerProcess.pid & ".port"
    infoPrint "index: waiting for TCP port file at ", portFilePath

    await asyncSleep(100)

    var socketAttempt = 0
    while true:
      let portStr = await readPortFile(portFilePath)
      if portStr.len > 0:
        let port = parseInt(portStr)
        if port > 0:
          backendManagerSocket = await startTcpSocket(cstring"127.0.0.1", port)
          if not backendManagerSocket.isNil:
            break
      socketAttempt += 1
      if socketAttempt mod 5 == 0:
        infoPrint "index: still waiting for session-manager TCP port (attempt ", $socketAttempt, ")"
      await asyncSleep(1000)
  else:
    let backendManagerSocketPath =
      codetracerTmpPath / "session-manager" / $backendManagerProcess.pid & ".sock"
    infoPrint "index: waiting for socket at ", backendManagerSocketPath

    await asyncSleep(100)

    var socketAttempt = 0
    while true:
      backendManagerSocket = await startSocket(backendManagerSocketPath)
      if not backendManagerSocket.isNil:
        break
      socketAttempt += 1
      if socketAttempt mod 5 == 0:
        infoPrint "index: still waiting for session-manager socket (attempt ", $socketAttempt, ")"
      await asyncSleep(1000)

  setupProxyForDap(backendManagerSocket)
  infoPrint "index: session manager socket configured"

  configureIpcMain()

  # we load the config file
  var config = await mainWindow.loadConfig(data.startOptions, home=paths.home.cstring, send=true)
  infoPrint "index: config loaded"
  when defined(server):
    # replay bootstrap state on reconnect (server builds only)
    ipc.replayBootstrap = proc() =
      if data.bootstrapMessages.len == 0:
        debugPrint "ipc replay bootstrap: nothing cached"
      else:
        debugPrint cstring(fmt"ipc replay bootstrap: {data.bootstrapMessages.len} messages")
        replayBootstrap(data.bootstrapMessages, proc(id: cstring, payload: cstring) =
          ipc.emit(id, payload))

  when not defined(server):
    # Skip the install dialog entirely when running in test mode
    # (CODETRACER_TEST=1). Without this, the dialog blocks creation of
    # the main window and Playwright tests see only subwindow.html.
    if not data.startOptions.inTest:
      config.skipInstall = isCtInstalled(config)
      if not config.skipInstall:
        installDialogWindow = createInstallSubwindow()
        discard await waitForResponseFromInstall()

  debugPrint "index: creating window"
  mainWindow = createMainWindow()
  registerMainWindow()
  infoPrint "index: main window created"
  sendLspStatusToRenderer()

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

    proc recordBootstrap(id, key, serialized: cstring) =
      ## Cache a payload for replay on socket reconnect.
      ##
      ## ``key`` differentiates multiple payloads on the same channel
      ## (used by ``dap-receive-event`` so distinct DAP events do not
      ## clobber each other in the cache).  For the legacy single-
      ## payload channels listed in ``bootstrapEvents`` the key is empty.
      if id in bootstrapEvents:
        let payload = BootstrapPayload(id: id, key: cstring"", payload: serialized)
        upsertBootstrap(data.bootstrapMessages, payload)
      elif id == cstring"CODETRACER::dap-receive-event" and key.len > 0:
        let payload = BootstrapPayload(id: id, key: key, payload: serialized)
        upsertBootstrap(data.bootstrapMessages, payload)

    proc dapReceiveEventKey(response: js): cstring =
      ## Extract the inner DAP event name from a ``dap-receive-event``
      ## payload, returning an empty string when the event is not one
      ## of the bootstrap-critical kinds we want to cache.
      if response.isNil:
        return cstring""
      let raw = response[cstring"event"]
      if raw.isUndefined or raw.isNull:
        return cstring""
      let eventName = cast[cstring](raw)
      bootstrapDapEventKey(eventName)

    mainWindow.webContents.send = proc(id: cstring, response: js) =
      debugPrint cstring"frontend ... <=== index: ", id, response
      let serialized = JSON.stringify(response, replacer, 2.toJs)
      debugIndex fmt"frontend ... <=== index: {id}"  # TODO? too big: {serialized}"
      let dapKey =
        if id == cstring"CODETRACER::dap-receive-event":
          dapReceiveEventKey(response)
        else:
          cstring""
      recordBootstrap(id, dapKey, serialized)
      ipc.emit(id, serialized)

  # bootstrap payloads that may need replay after reconnect
  let layout = await mainWindow.loadLayoutConfig(string(fmt"{userLayoutDir / $config.layout}.json"))
  data.layout = layout
  let helpers = await mainWindow.loadHelpers("/data" / "data.yaml")
  data.helpers = helpers
  data.config = config
  infoPrint "index: layout/helpers loaded, calling data.init"

  # init the UI directly; delayed timer scheduling can be skipped in server mode
  discard data.init(config, layout, helpers)
  infoPrint "index: data.init dispatched"
