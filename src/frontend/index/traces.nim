import
  std / [ async, jsffi, strutils, sequtils, strformat, os, json ],
  electron_vars, files, config, debugger,
  results,
  ipc_subsystems/[ dap, socket ],
  ../lib/[ jslib, electron_lib ],
  ../[ trace_metadata, config, types ],
  ../../common/[ ct_logging, paths, ],
  # ../../common/common_types/codetracer_features/notifications,
  ./js_helpers,
  ../lang

var
  selectedReplayId = -1
  pendingReplayStart: Future[int] = nil
  replayStartResolver: proc(replayId: int) = nil
  prefetchedTrace*: Trace = nil

proc asyncSleep(ms: int): Future[void] =
  newPromise(proc(resolve: proc(): void) =
    discard windowSetTimeout(resolve, ms)
  )

proc newReplayStartFuture(): Future[int] =
  let future = newPromise(proc (resolve: proc (replayId: int)) =
    replayStartResolver = resolve
  )
  pendingReplayStart = future
  future

proc handleReplayStartResponse(body: JsObject) =
  if replayStartResolver.isNil:
    return

  var replayId = -1
  var success = true
  if jsHasKey(body, cstring"success"):
    success = body["success"].to(bool)
  if success and jsHasKey(body, cstring"body"):
    let bodyNode = body["body"]
    if jsHasKey(bodyNode, cstring"replayId"):
      replayId = bodyNode["replayId"].to(int)

  if replayId >= 0:
    debugPrint("index: backend-manager reported replayId ", $replayId)
  else:
    debugPrint("index: backend-manager failed to start replay: ", body)

  replayStartResolver(replayId)
  replayStartResolver = nil
  pendingReplayStart = nil

registerStartReplayHandler(handleReplayStartResponse)

proc assignTrace(traceId: int): Future[bool] {.async.} =
  var attempts = 0
  var trace: Trace = nil
  while trace.isNil and attempts < 60:
    trace = await electron_vars.app.findTraceWithCodetracer(traceId)
    if trace.isNil:
      await asyncSleep(100)
      inc attempts
  if trace.isNil:
    errorPrint "Unable to locate trace metadata for ", traceId
    return false
  prefetchedTrace = trace
  data.trace = trace
  data.pluginClient.trace = trace
  if data.trace.compileCommand.len == 0:
    data.trace.compileCommand = data.config.defaultBuild
  infoPrint "index: assignTrace resolved trace ", $trace.id, " folder ", $trace.outputFolder
  return true

when defined(ctIndex) or defined(ctTest) or defined(ctInCentralExtensionContext):
  proc startProcess*(
    path: cstring,
    args: seq[cstring],
    options: JsObject = js{"stdio": cstring"ignore"}): Future[Result[NodeSubProcess, JsObject]] =
    # important to ignore stderr, as otherwise too much of it can lead to
    # the spawned process hanging: this is a bugfix for such a situation

    let futureHandler = proc(resolve: proc(res: Result[NodeSubProcess, JsObject])) =
      let process = nodeStartProcess.spawn(path, args, options)
      process.toJs.on("spawn", proc() =
        resolve(Result[NodeSubProcess, JsObject].ok(process)))

      process.toJs.on("error", proc(error: JsObject) =
        resolve(Result[NodeSubProcess, JsObject].err(error)))

    var future = newPromise(futureHandler)
    return future

  proc waitProcessResult*(process: NodeSubProcess): Future[JsObject] =
    let futureHandler = proc(resolve: proc(res: JsObject)) =

      process.toJs.on("exit", proc(code: int, signal: cstring) =
        if code == 0:
          resolve(nil)
        else:
          resolve(cstring(&"Exit with code {code}").toJs))

    var future = newPromise(futureHandler)
    return future

proc loadSymbols(traceFolder: cstring): Future[seq[Symbol]] {.async.} =
  if traceFolder.len > 0:
    let symbolsPath = $traceFolder / "symbols.json"
    let (rawSymbols, err) = await fsReadFileWithErr(cstring(symbolsPath))
    if err.isNil:
      return ($rawSymbols).parseJson.to(seq[Symbol])
    else:
      # leave pathSet empty
      errorPrint "loadSymbols for self contained trace trying to read from ", symbolsPath, ": ", err
      return cast[seq[Symbol]](@[])


proc loadFunctions(path: cstring): Future[seq[Function]] {.async.} =
  let (raw, err) = await fsReadFileWithErr(path)
  if err.isNil:
    return cast[seq[Function]](Json.parse(raw))
  else:
    return cast[seq[Function]](@[])

proc sendFilenames(main: js, paths: seq[cstring], traceFolder: cstring, selfContained: bool) {.async.} =
  let filenames = await loadFilenames(paths, traceFolder, selfContained)
  main.webContents.send "CODETRACER::filenames-loaded", js{filenames: filenames}

proc sendFilesystem(main: js, paths: seq[cstring], traceFilesPath: cstring, selfContained: bool) {.async.} =
  let folders = await loadFilesystem(paths, traceFilesPath, selfContained)
  main.webContents.send "CODETRACER::filesystem-loaded", js{ folders: folders }

proc sendSymbols(main: js, traceFolder: cstring) {.async.} =
  try:
    let symbols = await loadSymbols(traceFolder)
    main.webContents.send "CODETRACER::symbols-loaded", js{symbols: symbols}
  except:
    errorPrint "loading symbols: ", getCurrentExceptionMsg()

proc loadTrace*(data: var ServerData, main: js, trace: Trace, config: Config, helpers: Helpers): Future[void] {.async.} =
  # set title
  when not defined(server):
    main.setTitle(trace.program)

  let traceFilesPath = cstring($trace.outputFolder / "files")
  discard sendFilenames(main, trace.sourceFolders, trace.outputFolder, trace.imported)
  discard sendFilesystem(main, trace.sourceFolders, traceFilesPath, trace.imported)
  discard sendSymbols(main, trace.outputFolder)

  var functions = await loadFunctions(cstring($trace.outputFolder / "function_index.json"))
  var save = await getSave(trace.sourceFolders, config.test)
  data.save = save

  let dir = getHomeDir() / ".config" / "codetracer"
  let configFile = dir / "dont_ask_again.txt"

  let dontAskAgain = fs.existsSync(configFile)

  main.webContents.send "CODETRACER::trace-loaded", js{
    trace: trace,
    functions: functions,
    save: save,
    diff: data.startOptions.diff,
    withDiff: data.startOptions.withDiff,
    rawDiffIndex: data.startOptions.rawDiffIndex,
    dontAskAgain: dontAskAgain,
  }

proc loadExistingRecord*(traceId: int) {.async.} =
  debugPrint "[info]: load existing record with ID: ", $traceId
  if prefetchedTrace.isNil or prefetchedTrace.id != traceId:
    if not await assignTrace(traceId):
      warnPrint "couldn't assign trace"
      return
  let trace = prefetchedTrace
  prefetchedTrace = nil
  data.trace = trace
  data.pluginClient.trace = trace
  if data.trace.compileCommand.len == 0:
    data.trace.compileCommand = data.config.defaultBuild

  infoPrint "index: init frontend"
  mainWindow.webContents.send(
    "CODETRACER::init",
    js{
      home: paths.home.cstring,
      config: data.config,
      layout: data.layout,
      helpers: data.helpers,
      startOptions: data.startOptions,
      bypass: true})

  if not data.trace.isNil:
    infoPrint "index: loading trace in mainWindow"
    await data.loadTrace(mainWindow, data.trace, data.config, data.helpers)

  # (alexander: i think this is not really used anymore: as it's expected to really work only
  #    for ct shell, but that's not currently maintained a lot)
  # try:
  #   let instanceClient = await startSocket(CT_DEBUG_INSTANCE_PATH_BASE & cstring($callerProcessPid))
  #   instanceClient.on(cstring"data") do (data: cstring):
  #     let outputLine = data.trim.parseJsInt
  #     debugPrint "index: ===> output line ", outputLine
  #     mainWindow.webContents.send cstring"CODETRACER::output-jump-from-shell-ui", outputLine
  # except:
  #   debugPrint "warning: exception when starting instance client:"
  #   debugPrint "  that's ok, if this was not started from shell-ui!"

proc prepareForLoadingTrace*(traceId: int, pid: int) {.async.} =
  callerProcessPid = pid
  if prefetchedTrace.isNil or prefetchedTrace.id != traceId:
    if not await assignTrace(traceId):
      return
  else:
    infoPrint "index: reuse prefetched trace ", $prefetchedTrace.id, " folder ", $prefetchedTrace.outputFolder
    data.trace = prefetchedTrace
    data.pluginClient.trace = prefetchedTrace
    if data.trace.compileCommand.len == 0:
      data.trace.compileCommand = data.config.defaultBuild

  let replayStartFuture = newReplayStartFuture()
  infoPrint "index: requesting new replay for trace ", $traceId
  if not data.trace.isNil:
    infoPrint "index: ct/start-replay for trace folder ", $data.trace.outputFolder

  if selectedReplayId >= 0:
    let stopPacket = wrapJsonForSending js{
      "type": cstring"request",
      "command": cstring"ct/stop-replay",
      "arguments": [selectedReplayId]
    }
    backendManagerSocket.write(stopPacket)

  let packet = wrapJsonForSending js{
    "type": cstring"request",
    "command": cstring"ct/start-replay",
    "arguments": [cstring(dbBackendExe), cstring"dap-server"],
  }
  backendManagerSocket.write(packet)

  let replayId = await replayStartFuture
  if replayId < 0:
    errorPrint "Unable to start replay for new trace"
    return

  selectedReplayId = replayId
  infoPrint "index: selecting replayId ", $replayId

  let selectPacket = wrapJsonForSending js{
    "type": cstring"request",
    "command": cstring"ct/select-replay",
    "arguments": [replayId]
  }
  backendManagerSocket.write(selectPacket)
  mainWindow.webContents.send(
    "CODETRACER::dap-replay-selected",
    js{trace: data.trace})

proc replayTx(txHash: cstring, pid: int): Future[(cstring, int)] {.async.} =
  callerProcessPid = pid
  let outputResult = await readProcessOutput(
    codetracerExe.cstring,
    @[cstring"arb", cstring"replay", txHash]
  )
  var output = cstring""
  if outputResult.isOk:
    output = outputResult.value
    let lines = output.split(jsNl)
    if lines.len > 1:
      let traceIdLine = $lines[^2]
      # probably because we print `traceId:<traceId>\n` : so the last line is ''
      #   and traceId is in the second last line
      if traceIdLine.startsWith("traceId:"):
        let traceId = traceIdLine[("traceId:").len .. ^1].parseInt
        return (output, traceId)
  else:
    output = JSON.stringify(outputResult.error)
  return (output, NO_INDEX)

proc onLoadRecentTrace*(sender: js, response: jsobject(traceId=int)) {.async.} =
  await prepareForLoadingTrace(response.traceId, nodeProcess.pid.to(int))
  await loadExistingRecord(response.traceId)

proc onLoadRecentTransaction*(sender: js, response: jsobject(txHash=cstring)) {.async.} =
  let (rawOutputOrError, traceId) = await replayTx(response.txHash, nodeProcess.pid.to(int))
  if traceId != NO_INDEX:
    await prepareForLoadingTrace(traceId, nodeProcess.pid.to(int))
    await loadExistingRecord(traceId)
  else:
    # TODO: process notifications in welcome screen, or a different kind of error handler for this case
    # currently not working in frontend, because no status component for now in welcome screen
    # sendNotification(NotificationKind.NotificationError, "couldn't record trace for the transaction")
    echo ""
    echo ""
    echo "ERROR: couldn't record trace for transaction:"
    echo "==========="
    echo "(raw output or error):"
    echo rawOutputOrError
    echo "(end of raw output or error)"
    echo "==========="
    quit(1)

proc onLoadTraceByRecordProcessId*(sender: js, pid: int) {.async.} =
  let trace = await electron_vars.app.findTraceByRecordProcessId(pid)
  infoPrint "index: trace by record process id has trace id ", trace.id
  prefetchedTrace = trace
  data.trace = trace
  data.pluginClient.trace = trace
  await prepareForLoadingTrace(trace.id, pid)
  await loadExistingRecord(trace.id)

proc onStopRecordingProcess*(sender: js, response: js) {.async.} =
  if not data.recordProcess.isNil:
    if data.recordProcess.kill():
      data.recordProcess = nil
    else:
      warnPrint "Unable to stop recording process"
  else:
    warnPrint "There is not any recording process"

proc onOpenLocalTrace*(sender: js, response: js) {.async.} =
  let selection = await selectDir(cstring"Select Trace Output Folder", codetracerTraceDir)
  if selection.len == 0:
    errorPrint "no folder selected"
  else:
    # selectDir tries to return a folder with a trailing slash
    let trace = await electron_vars.app.findByPath(selection)
    if not trace.isNil:
      mainWindow.webContents.send "CODETRACER::loading-trace",
        js{trace: trace}
      prefetchedTrace = trace
      data.trace = trace
      data.pluginClient.trace = trace
      await prepareForLoadingTrace(trace.id, nodeProcess.pid.to(int))
      await loadExistingRecord(trace.id)
    else:
      errorPrint "There is no record at given path."

proc sendNewNotification*(kind: NotificationKind, message: string) =
  let notification = newNotification(kind, message)
  mainWindow.webContents.send "new-notification", notification

proc onNewRecord*(sender: js, response: jsobject(filename=cstring, args=seq[cstring], options=JsObject, projectOnly=bool)) {.async.}=
  infoPrint "index: new record for", response.filename, " originally ", response.args, " projectOnly?: ", response.projectOnly
  # TODO fix replay
  var recordArgs = response.args
  if not data.trace.lang.isDbBased:
    var buildArg = if response.filename.len > 0:
        response.filename
      else:
        let (rawTracePaths, err) = await fsReadFileWithErr(nodePath.join(data.trace.outputFolder, cstring"trace_paths.json"))
        if not err.isNil:
          cstring""
        else:
          let tracePaths = cast[seq[cstring]](JSON.parse(rawTracePaths))
          if tracePaths.len > 0:
            # TODO: add either entry/special source file, or current file as argument
            # and do that in trace_db_metadata/sqlite OR in trace_paths being more special(first?)
            # for now just assuming trace paths first file is useful for this goal
            tracePaths[0]
          else:
            cstring""

    if buildArg.len == 0:
      errorPrint "index: build: can't find a filename or project to build: stopping"
      # should be working, but there was a problem: TODO maybe debug more
      # but ther other `failed-record` also works here for errors indeed, i noticed it later 
      # sendNewNotification(NotificationKind.NotificationError, "index: build: can't find a filename to build: stopping")
      mainWindow.webContents.send "CODETRACER::failed-record", js{errorMessage: cstring"index: build: can't find a filename or project to build: stopping"}
      return

    if response.projectOnly:
      buildArg = cstring(($buildArg).parentDir)
      # for now `ct build` => `ct-rr-support build` tries just use project logic when passed a folder and 
      #   simpler file-based compile logic when passed a file
      #   e.g. project logic is look up for a folder with Cargo.toml for rust
      # we do this for now instead of having an explicit `--project` argument

    let buildArgs = @[buildArg]
    infoPrint "index: build: ", buildArgs
    let buildProcessResult = await readProcessOutput(
      codetracerExe,
      @[cstring"build"].concat(buildArgs)
    )

    
    if buildProcessResult.isOk:
      let output = buildProcessResult.value
      infoPrint "index: build ok: ", output
      let lines = ($output).splitLines()
      if lines[^1].startsWith("binary: "):
        let tokens = lines[^1].split(": ", 1)
        let binary = cstring(tokens[1].strip)
        if recordArgs[0] != binary:
          recordArgs = @[binary] # assume other args from original trace might be unrelated
    else:
      errorPrint "index: build error: ", buildProcessResult.error
      # sendNewNotification(NotificationKind.NotificationError, "index: build error: " & $JSON.stringify(buildProcessResult.error))
      mainWindow.webContents.send "CODETRACER::failed-record", js{errorMessage: cstring("index: build error: " & $JSON.stringify(buildProcessResult.error))}
      return

  infoPrint "index: record with args: ", recordArgs
  let processResult = await startProcess(
    codetracerExe,
    @[cstring"record"].concat(recordArgs),
    response.options)

  if processResult.isOk:
    infoPrint "index: record process started with pid " & $processResult.value.pid
    data.recordProcess = processResult.value
    let error = await waitProcessResult(processResult.value)

    if error.isNil:
      infoPrint "index: recorded successfully"
      mainWindow.webContents.send "CODETRACER::successful-record"
      await onLoadTraceByRecordProcessId(nil, processResult.value.pid)
    else:
      errorPrint "record error: ", error
      if not data.recordProcess.isNil:
        mainWindow.webContents.send "CODETRACER::failed-record",
          js{errorMessage: cstring"codetracer record command failed"}

  else:
    errorPrint "record start process error: ", processResult.error
    let errorSpecificText = if not processResult.error.isNil: cast[cstring](processResult.error.code) else: cstring""
    let errorText = cstring"record start process error: " & errorSpecificText
    mainWindow.webContents.send "CODETRACER::failed-record",
      js{errorMessage: errorText}

proc onRunTest*(sender: JsObject, response: RunTestOptions) {.async.} =
  infoPrint "index: run test: ", response[]
  let processResult = await readProcessOutput(
    codetracerExe,
    @[cstring"record-test"].concat(@[response.testName, response.path, cstring($response.line), cstring($response.column)])
  )
  if processResult.isOk: # true
    let output = processResult.value
    let lines = ($output).splitLines()
    let traceId = parseInt(lines[^1]) #  1063 
    await prepareForLoadingTrace(traceId, nodeProcess.pid.to(int))
    await loadExistingRecord(traceId)
  else:
    errorPrint "index: ct record-test error: ", JSON.stringify(processResult.error)
    mainWindow.webContents.send "CODETRACER::failed-record", js{errorMessage: cstring"ct record-test error: " & JSON.stringify(processResult.error)}