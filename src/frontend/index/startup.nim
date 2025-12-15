import
  std/[ async, jsffi, jsconsole, json, os, strformat ],
  results,
  window, traces, files, config, install, electron_vars, debugger,
  ipc_subsystems/socket,
  ../[ config, types, trace_metadata ],
  ../lib/[ jslib, electron_lib ],
  ../../common/[ paths, ct_logging ]

const NO_LIMIT = (-1)
var
  startedFuture: proc: void
  startedReceived = false

nodeProcess.on(cstring"uncaughtException", proc(err: JsObject) =
  # handle the error safely
  console.log cstring"[index]: uncaught exception: ", err)

proc asyncSleep*(ms: int): Future[void] =
  let future = newPromise() do (resolve: (proc: void)):
    discard windowSetTimeout(resolve, ms)
  return future

when not defined(server):
  proc debugSend*(self: js, f: js, id: cstring, data: js) =
    var values = loadValues(data, id)
    if ct_logging.LOG_LEVEL <= CtLogLevel.Debug:
      console.log data
    f.call(self, cast[cstring](id), data)

proc onStarted*(sender: js, response: js) {.async.} =
  if not startedFuture.isNil:
    startedReceived = true
    startedFuture()

    echo "Trying to send acp msg"

    mainWindow.webContents.send("CODETRACER::acp-receive-response", js{
      "test": cstring("hello from index"),
    })

proc started*: Future[void] =
  var future = newPromise() do (resolve: (proc: void)):
    if startedFuture.isNil:
      startedFuture = resolve
    mainWindow.webContents.send "CODETRACER::started", js{}
    discard windowSetTimeout(proc =
      if not startedReceived:
        discard started(), 100)
  return future

proc startShellUi*(main: js, config: Config): Future[void] {.async.} =
  debugPrint "start shell ui"
  main.webContents.send "CODETRACER::start-shell-ui", js{config: config}

proc onLoadCodetracerShell*(sender: js, response: js) {.async.} =
  await wait(1_000)
  await startShellUi(mainWindow, data.config)
  await wait(1_000)
  await started()

proc init*(data: var ServerData, config: Config, layout: js, helpers: Helpers) {.async.} =
  debugPrint "index: init"
  let bypass = true

  data.config = config
  data.config.test = data.config.test
  data.startOptions.isInstalled = isCtInstalled(data.config)
  data.config.skipInstall = data.startOptions.isInstalled

  if data.startOptions.shellUi:
    await wait(1_000)
    await startShellUi(mainWindow, data.config)
    await wait(1_000)
    await started()
    return

  # TODO: leave this to backend/DAP if possible
  if not data.startOptions.edit and not data.startOptions.welcomeScreen:
    if bypass:
      let trace = await electron_vars.app.findTraceWithCodetracer(data.startOptions.traceID)
      if trace.isNil:
        errorPrint "trace is not found for ", data.startOptions.traceID
        quit(1)
      data.trace = trace
      data.pluginClient.trace = trace
      if data.trace.compileCommand.len == 0:
        data.trace.compileCommand = data.config.defaultBuild
      await prepareForLoadingTrace(trace.id, nodeProcess.pid.to(int))

  await started()

  if not data.startOptions.edit and not data.startOptions.welcomeScreen:
    debugPrint "send ", "CODETRACER::init"
    debugPrint data.startOptions

    mainWindow.webContents.send(
      "CODETRACER::init",
      js{
        home: paths.home.cstring,
        config: data.config,
        layout: layout,
        helpers: helpers,
        startOptions: data.startOptions,
        bypass: bypass
    })

    # echo "Trying to send acp msg"
    #
    # mainWindow.webContents.send("CODETRACER::acp-receive-response", js{
    #   "id": cstring("1"),
    #   "content": cstring("hello from index")
    # })
    #
    # mainWindow.webContents.send("CODETRACER::acp-receive-response", js{
    #   "id": cstring("2"),
    #   "content": cstring("hello from index again")
    # })

    # mainWindow.webContents.send("CODETRACER::acp-create-terminal", js{
    #   "id": cstring("2")
    # })

    if bypass:
      if not data.trace.isNil:
        await data.loadTrace(mainWindow, data.trace, data.config, helpers)

    try:
      let instanceClient = await startSocket(CT_DEBUG_INSTANCE_PATH_BASE & cstring($callerProcessPid), expectPossibleFail=true)
      instanceClient.on(cstring"data") do (data: cstring):
        let outputLine = data.trim.parseJsInt
        debugPrint "=> output line ", outputLine
        mainWindow.webContents.send cstring"CODETRACER::output-jump-from-shell-ui", outputLine
    except:
      debugPrint "index: warning: exception when starting instance client:"
      debugPrint "  that's ok, if this was not started from shell-ui!"


  elif data.startOptions.edit:
    let file = ($data.startOptions.name)
    var folder = data.startOptions.folder
    var filenames = await loadFilenames(@[folder], traceFolder=cstring"", selfContained=false)
    var filesystem = await loadFilesystem(@[folder], traceFilesPath=cstring"", selfContained=false)
    var functions: seq[Function] = @[] # TODO load with rg or similar?
    var save = await getSave(@[folder], data.config.test)
    data.save = save

    mainWindow.webContents.send "CODETRACER::no-trace", js{
      path: data.startOptions.name,
      lang: save.project.lang,
      home: paths.home.cstring,
      layout: layout,
      helpers: helpers,
      startOptions: data.startOptions,
      config: data.config,
      filenames: filenames,
      filesystem: filesystem,
      functions: functions,
      save: save
    }
  else:
    let recentTraces = await electron_vars.app.findRecentTracesWithCodetracer(limit=NO_LIMIT)
    var recentTransactions: seq[StylusTransaction] = @[]
    if data.startOptions.stylusExplorer:
      recentTransactions = await electron_vars.app.findRecentTransactions(limit=NO_LIMIT)
    mainWindow.webContents.send "CODETRACER::welcome-screen", js{
      home: paths.home.cstring,
      layout: layout,
      startOptions: data.startOptions,
      config: data.config,
      recentTraces: recentTraces,
      recentTransactions: recentTransactions
    }
