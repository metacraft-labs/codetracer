import
  std/[ async, jsffi, jsconsole, json, os, strformat ],
  results,
  window, traces, files, config, install, electron_vars, debugger, launch_config,
  recent_items,
  ipc_subsystems/socket,
  ../[ config, types, trace_metadata ],
  ../lib/[ jslib, electron_lib ],
  ../../common/[ paths, ct_logging ]

## Maximum number of recent traces/folders to show in the welcome screen.
## Using -1 (unlimited) caused 200+ MB of IPC data with thousands of traces,
## blocking the renderer for well over 15 seconds and causing test timeouts.
const RECENT_ITEMS_LIMIT = 50
var
  startedFuture: proc: void
  startedReceived = false

nodeProcess.on(cstring"uncaughtException", proc(err: JsObject) =
  # handle the error safely
  console.log cstring"[index]: uncaught exception: ", err)

nodeProcess.on(cstring"unhandledRejection", proc(reason: JsObject, promise: JsObject) =
  console.log cstring"[index]: unhandled promise rejection: ", reason)

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

proc pushRecentItems(startOptions: StartOptions) {.async.} =
  ## Make sure the renderer holds the recent-traces / recent-folders lists, on
  ## every startup path that can put the welcome surface on screen.
  ##
  ## Issue #568: the lists used to be fetched only in the welcome-screen branch
  ## of ``init`` below, and the renderer only ever assigned them from the
  ## ``CODETRACER::welcome-screen`` message that branch sends.  A process
  ## started with ``ct run <program>`` took a different branch, so pressing the
  ## session tab bar's "+" opened an empty tab whose Recent Traces panel stayed
  ## empty for the whole lifetime of the process — while the same click after a
  ## welcome-screen launch listed them.
  ##
  ## ``recent_items.recentItemsChannel`` owns the decision of which paths need
  ## this push, so it can be (and is) tested headlessly; this proc is the
  ## adapter that performs it.
  ##
  ## Deliberately *eager* rather than a lazy renderer-side request: it reuses
  ## the exact data flow and freshness model the welcome path already has, needs
  ## no request channel and no in-flight state in the renderer, and cannot make
  ## the panel flash empty before filling in.  It is called only after the work
  ## that path's user is actually waiting for has completed, so the two
  ## ``codetracer trace-metadata`` child processes stay off the critical path.
  if not needsRecentItemsPush(startupPath(
      shellUi = startOptions.shellUi,
      withDeepReview = startOptions.withDeepReview,
      edit = startOptions.edit,
      welcomeScreen = startOptions.welcomeScreen)):
    return

  # `quitOnError = false`: these paths are already showing a live session, and
  # failing to list recent traces must never cost the user that session.
  let recentTraces = await electron_vars.app.findRecentTracesWithCodetracer(
    limit = RECENT_ITEMS_LIMIT, quitOnError = false)
  let recentFolders = await electron_vars.app.findRecentFoldersWithCodetracer(
    limit = RECENT_ITEMS_LIMIT, quitOnError = false)
  var recentTransactions: seq[StylusTransaction] = @[]
  if startOptions.stylusExplorer:
    recentTransactions = await electron_vars.app.findRecentTransactions(
      limit = RECENT_ITEMS_LIMIT, quitOnError = false)

  mainWindow.webContents.send RecentItemsMessage, js{
    recentTraces: recentTraces,
    recentFolders: recentFolders,
    recentTransactions: recentTransactions
  }

proc startShellUi*(main: js, config: Config): Future[void] {.async.} =
  debugPrint "start shell ui"
  main.webContents.send "CODETRACER::start-shell-ui", js{config: config}

proc onLoadCodetracerShell*(sender: js, response: js) {.async.} =
  await wait(1_000)
  await startShellUi(mainWindow, data.config)
  await wait(1_000)
  await started()

proc init*(dataArg: var ServerData, config: Config, layout: js, helpers: Helpers) {.async.} =
  # Copy into a local var to work around Nim 2.2's capture check for
  # var parameters in async procs.  On the JS backend, ServerData is a
  # reference type (JS object), so mutations to 'data' propagate back
  # to the caller.
  var data = dataArg
  debugPrint "index: init"
  let bypass = true

  data.config = config
  data.config.test = data.startOptions.inTest
  data.startOptions.isInstalled = isCtInstalled(data.config)
  data.config.skipInstall = data.startOptions.isInstalled

  if data.startOptions.shellUi:
    await wait(1_000)
    await startShellUi(mainWindow, data.config)
    await wait(1_000)
    await started()
    # A no-op for the shell UI (it hides the welcome surface entirely), but
    # every exit of `init` routes through the same decision so a new startup
    # path cannot silently skip it — see `index/recent_items.nim`.
    await pushRecentItems(data.startOptions)
    return

  if data.startOptions.withDeepReview:
    # DeepReview mode: skip trace loading and send the startup message
    # directly to the frontend renderer so it can initialise the
    # DeepReview component layout.
    debugPrint "start deepreview mode"
    await started()
    # Load and forward the EDITOR layout, not the debugging one this proc was
    # handed (RV-2; DeepReview-GUI.md §1.1).  `ct review <PATH>` never loads a
    # recording, so the debugging layout's EVENT LOG, CALLTRACE, TIMELINE and
    # TERMINAL OUTPUT panels came up present but empty — which reads as
    # missing data.  The editor layout omits exactly those, and
    # `loadReviewLayoutConfig` keeps the Agent Activity panel an editing
    # session would also hide, because it is the review's third pillar.
    #
    # This is still the same user layout file an editing session opens; the
    # renderer then *adds* nothing and removes nothing (issue #610), it only
    # brings the review's panels to the front of the stacks that host them.
    #
    # Only the dataset launch reaches this branch.  A review over a
    # diff-associated trace, and an agentic handoff, enter from the renderer
    # with a recording loaded, and keep the debugging layout.
    let reviewLayout = await mainWindow.loadReviewLayoutConfig(
      string(userLayoutDir / "default_edit_layout.json"))
    mainWindow.webContents.send "CODETRACER::start-deepreview", js{
      config: data.config,
      layout: reviewLayout,
      startOptions: data.startOptions
    }
    # DeepReview is a normal window with a session tab bar, so its "+" opens a
    # welcome tab too (issue #568).
    await pushRecentItems(data.startOptions)
    return

  # TODO: leave this to backend/DAP if possible
  if not data.startOptions.edit and not data.startOptions.welcomeScreen:
    if bypass:
      let trace = await electron_vars.app.findTraceWithCodetracer(data.startOptions.recordingID)
      if trace.isNil:
        errorPrint "trace is not found for ", data.startOptions.recordingID
        quit(1)
      data.trace = trace
      data.pluginClient.trace = trace
      if data.trace.compileCommand.len == 0:
        data.trace.compileCommand = data.config.defaultBuild
      await prepareForLoadingTrace(trace.recordingId, nodeProcess.pid.to(int))

  await started()
  let configSnapshot = data.config
  let startOptionsSnapshot = data.startOptions

  if not startOptionsSnapshot.edit and not startOptionsSnapshot.welcomeScreen:
    debugPrint "send ", "CODETRACER::init"
    debugPrint startOptionsSnapshot

    mainWindow.webContents.send(
      "CODETRACER::init",
      js{
        home: paths.home.cstring,
        config: configSnapshot,
        layout: layout,
        helpers: helpers,
        startOptions: startOptionsSnapshot,
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


  elif startOptionsSnapshot.edit:
    let file = ($startOptionsSnapshot.name)
    var folder = startOptionsSnapshot.folder
    # Store workspace folder for later use when switching modes
    data.workspaceFolder = folder
    var filenames = await loadFilenames(@[folder], traceFolder=cstring"", selfContained=false)
    var filesystem = await loadFilesystem(@[folder], traceFilesPath=cstring"", selfContained=false)
    var functions: seq[Function] = @[] # TODO load with rg or similar?
    var save = await getSave(@[folder], data.config.test)
    data.save = save
    let editLayout = await mainWindow.loadEditLayoutConfig(
      string(userLayoutDir / "default_edit_layout.json"))

    mainWindow.webContents.send "CODETRACER::no-trace", js{
      path: startOptionsSnapshot.name,
      lang: save.project.lang,
      home: paths.home.cstring,
      layout: editLayout,
      helpers: helpers,
      startOptions: startOptionsSnapshot,
      config: configSnapshot,
      filenames: filenames,
      filesystem: filesystem,
      functions: functions,
      save: save
    }

    # Load and send launch configs for the workspace
    let launchConfigs = getLaunchConfigsForWorkspace(folder)
    if launchConfigs.len > 0:
      var configsJs: seq[JsObject] = @[]
      for i, config in launchConfigs:
        var envJs: seq[JsObject] = @[]
        for j in 0 ..< config.env.len:
          let envPair = config.env[j]
          envJs.add(js{key: envPair.key, value: envPair.value})
        configsJs.add(js{
          index: i,
          name: config.name,
          program: config.program,
          args: config.args,
          cwd: config.cwd,
          configType: config.configType,
          env: envJs
        })
      mainWindow.webContents.send "CODETRACER::launch-configs-loaded", js{configs: configsJs}

  else:
    let recentTraces = await electron_vars.app.findRecentTracesWithCodetracer(limit=RECENT_ITEMS_LIMIT)
    let recentFolders = await electron_vars.app.findRecentFoldersWithCodetracer(limit=RECENT_ITEMS_LIMIT)
    var recentTransactions: seq[StylusTransaction] = @[]
    if data.startOptions.stylusExplorer:
      recentTransactions = await electron_vars.app.findRecentTransactions(limit=RECENT_ITEMS_LIMIT)
    mainWindow.webContents.send WelcomeScreenMessage, js{
      home: paths.home.cstring,
      layout: layout,
      startOptions: startOptionsSnapshot,
      config: configSnapshot,
      recentTraces: recentTraces,
      recentFolders: recentFolders,
      recentTransactions: recentTransactions
    }

  # Issue #568: the welcome branch above carries the recent lists inline; every
  # other startup path needs them pushed separately, or the welcome surface the
  # session tab bar's "+" opens has nothing to list.  `pushRecentItems` is a
  # no-op for the paths whose message already carried them.
  await pushRecentItems(startOptionsSnapshot)
