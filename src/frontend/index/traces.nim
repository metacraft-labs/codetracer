import
  std / [ async, jsffi, strutils, sequtils, strformat, os, json, jsconsole ],
  electron_vars, files, config, debugger,
  results,
  ipc_subsystems/[ dap, socket ],
  ../lib/[ jslib, electron_lib ],
  ../[ trace_metadata, config, types, file_conflicts ],
  ../viewmodel/viewmodels/visual_replay_layout,
  visual_replay_player,
  ../../common/[ ct_logging, paths, trace_source_paths ],
  ../../ct/trace/recorder_output,
  # ../../common/common_types/codetracer_features/notifications,
  ./js_helpers,
  ./launch_config,
  ./settle_once,
  ./tab_answers,
  ../lang

var
  # The currently selected (foreground) replay in the Backend Manager.
  # Multiple replays can run simultaneously; this tracks which one is
  # the BM's "active" selection for DAP event routing.
  selectedReplayId = -1
  replayStartResolvers: seq[proc(replayId: int)] = @[]
    ## One per `ct/start-replay` written and not yet answered, in the order
    ## they were written: the Backend Manager answers them in that order, and
    ## the answer names no request. A single slot let a second start (another
    ## `ct host` client's replay, `host_clients`) take the first's answer.
  prefetchedTrace*: Trace = nil

proc asyncSleep(ms: int): Future[void] =
  newPromise(proc(resolve: proc(): void) =
    discard windowSetTimeout(resolve, ms)
  )

proc handleReplayStartResponse(body: JsObject) =
  if replayStartResolvers.len == 0:
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
    debugPrint("index: session-manager reported replayId ", $replayId)
  else:
    debugPrint("index: session-manager failed to start replay: ", body)

  let resolve = replayStartResolvers[0]
  replayStartResolvers.delete(0)
  resolve(replayId)

registerStartReplayHandler(handleReplayStartResponse)

proc startReplayProcess*(): Future[int] =
  ## Ask the Backend Manager for a new replay process (`ct/start-replay`);
  ## resolves with its replay id, or -1 when it could not start one. The
  ## replay is not selected and has no trace yet: its client's `launch` names
  ## the trace.
  if backendManagerSocket.isNil:
    errorPrint "index: no session-manager connection to start a replay on"
    return newPromise(proc (resolve: proc (replayId: int)) = resolve(-1))
  result = newPromise(proc (resolve: proc (replayId: int)) =
    replayStartResolvers.add resolve)
  backendManagerSocket.write(wrapJsonForSending js{
    "type": cstring"request",
    "command": cstring"ct/start-replay",
    "arguments": @[cstring(dbBackendExe), cstring"dap-server"],
  })

proc pathExists(path: cstring): bool

proc nimSourceCandidate(program: string): cstring =
  if program.len == 0:
    return cstring""
  if program.endsWith(".nim"):
    return cstring(program)

  let adjacentSource = cstring(program & ".nim")
  if pathExists(adjacentSource):
    return adjacentSource

  let buildSourcesPath = cstring(program & ".ct-build-sources.json")
  if pathExists(buildSourcesPath):
    try:
      let sources = cast[seq[cstring]](
        JSON.parse(fs.readFileSync(buildSourcesPath, cstring"utf8")))
      for source in sources:
        if ($source).endsWith(".nim") and pathExists(source):
          return source
    except:
      warnPrint "failed to inspect Nim build sources for ", program, ": ",
        getCurrentExceptionMsg()

  return cstring""

proc normalizeTraceProgramForUi(trace: Trace) =
  if trace.isNil:
    return
  if trace.lang != LangNim and trace.lang != LangUnknown:
    return
  let program = $trace.program
  let sourceCandidate = nimSourceCandidate(program)
  if sourceCandidate.len == 0:
    return
  trace.program = sourceCandidate
  trace.lang = LangNim

proc assignTrace(recordingId: cstring): Future[bool] {.async.} =
  ## M-REC-3: ``recordingId`` is a UUIDv7 recording-id (carried as
  ## ``cstring`` to match the renderer/Electron-IPC layer's JS string
  ## convention).
  var attempts = 0
  var trace: Trace = nil
  while trace.isNil and attempts < 60:
    trace = await electron_vars.app.findTraceWithCodetracer(recordingId)
    if trace.isNil:
      await asyncSleep(100)
      inc attempts
  if trace.isNil:
    errorPrint "Unable to locate trace metadata for ", recordingId
    return false
  normalizeTraceProgramForUi(trace)
  prefetchedTrace = trace
  data.trace = trace
  data.pluginClient.trace = trace
  if data.trace.compileCommand.len == 0:
    data.trace.compileCommand = data.config.defaultBuild
  infoPrint "index: assignTrace resolved trace ", $trace.recordingId, " folder ", $trace.outputFolder
  return true

when defined(ctIndex) or defined(ctTest) or defined(ctInCentralExtensionContext):
  # IMPORTANT: don't use this if you need to read/process the output
  #   use `readProcessOutput` or custom handling for that
  #   we here try to ignore or let the user inherit the stdio on purpose!
  #   to not hang the internal process with unhandled buffers/events
  #   which has happened several times
  proc startProcess*(
    path: cstring,
    args: seq[cstring],
    options: JsObject = js{"stdio": cstring"ignore"}): Future[Result[NodeSubProcess, JsObject]] =
    # important to ignore stderr, as otherwise too much of it can lead to
    # the spawned process hanging: this is a bugfix for such a situation

    var processOptions = options
    if processOptions.stdio.isNil: # nil or undefined
      processOptions.stdio = cstring"ignore"
    # Prevent spawned console apps from creating visible console windows on Windows.
    # Harmless no-op on other platforms.
    processOptions.windowsHide = true
      # make sure we don't let it be the default/not set
      # as this seems to lead to pass it to internal buffer/events
      # and as we might not handle that, this leads to hanging?
      # would be problem for reading, but there is `readProcessOutput` for it
      # and it doesn't use this `startProcess` !
    let futureHandler = proc(resolve: proc(res: Result[NodeSubProcess, JsObject])) =
      # Name what is started, never its options: they carry the child's whole
      # environment (`ready` hands the session-manager a copy of ours), which
      # holds the replay's credentials, such as its storage replay token, and
      # this output reaches the supervisor's log (the ReplayAgent logs every
      # line a replay prints).
      infoPrint "index: starting process ", path
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

proc sendFilenames(main: js, paths: seq[cstring], traceFolder: cstring, selfContained: bool,
                   tab: JsObject) {.async.} =
  let filenames = await loadFilenames(paths, traceFolder, selfContained)
  main.webContents.send "CODETRACER::filenames-loaded",
    withTab(js{filenames: filenames}, tab)

# THE ROOT LOAD ANSWERS ON EVERY EXIT.  The Files pane shows "Loading..."
# until ``filesystem-loaded`` arrives, and nothing else ends that state, so a
# load that rejected without sending left the pane on "Loading..." for good
# (GitHub #785; ``files.onLoadPathContent`` keeps the same rule for sub-folder
# loads, #574).  A failure is sent on the SAME channel, with ``error`` set and
# no ``folders``: the reconnect bootstrap cache (``bootstrap_cache.nim``) keeps
# the latest payload per channel, so one channel replays the latest outcome,
# where two would replay a stale failure after a newer tree.

proc filesystemLoadFailure(paths: seq[cstring]; reason: string): cstring =
  ## The reason the renderer shows, naming the roots it could not load.
  var roots: seq[string] = @[]
  for path in paths:
    roots.add $path
  let what =
    if roots.len == 0: "the file tree"
    else: roots.join(", ")
  cstring(what & ": " &
    (if reason.len > 0: reason else: "the index process gave no reason"))

proc sendFilesystemFailure(main: js, paths: seq[cstring], reason: string,
                           tab: JsObject) =
  let message = filesystemLoadFailure(paths, reason)
  errorPrint "loading the file tree failed: ", $message
  main.webContents.send "CODETRACER::filesystem-loaded",
    withTab(js{ error: message }, tab)

proc sendFilesystem*(main: js, paths: seq[cstring], traceFilesPath: cstring, selfContained: bool,
                     tab: JsObject = jsUndefined) {.async.} =
  ## `tab`: the renderer tab whose load this answers (`tab_answers`).
  var folders: CodetracerFile = nil
  var failure = ""
  try:
    folders = await loadFilesystem(paths, traceFilesPath, selfContained)
  except:
    failure = getCurrentExceptionMsg()
  if folders.isNil:
    sendFilesystemFailure(main, paths, failure, tab)
  else:
    main.webContents.send "CODETRACER::filesystem-loaded",
      withTab(js{ folders: folders }, tab)

proc sendFilesystemWithCategory(main: js, categoryName: cstring, paths: seq[cstring], traceFilesPath: cstring, selfContained: bool,
                                tab: JsObject) {.async.} =
  var folders: CodetracerFile = nil
  var failure = ""
  try:
    folders = await loadFilesystemWithCategory(categoryName, paths, traceFilesPath, selfContained)
  except:
    failure = getCurrentExceptionMsg()
  if folders.isNil:
    let message = filesystemLoadFailure(paths, failure)
    errorPrint "loading the ", $categoryName, " file tree failed: ", $message
    main.webContents.send "CODETRACER::filesystem-category-loaded",
      withTab(js{ category: categoryName, error: message }, tab)
  else:
    main.webContents.send "CODETRACER::filesystem-category-loaded",
      withTab(js{ category: categoryName, folders: folders }, tab)

proc isAbsoluteFilesystemPath(path: string): bool =
  if path.len > 0 and (path[0] == '/' or path[0] == '\\'):
    return true
  path.len >= 3 and path[1] == ':' and (path[2] == '\\' or path[2] == '/')

proc addUniquePath(paths: var seq[cstring]; path: cstring) =
  if path.len == 0:
    return
  for existing in paths:
    if $existing == $path:
      return
  paths.add(path)

proc pathExists(path: cstring): bool =
  if path.len == 0:
    return false
  try:
    return fs.existsSync(path)
  except:
    return false

proc ensureDirectory(path: cstring): bool =
  if path.len == 0:
    return false
  try:
    fs.mkdirSync(path, js{recursive: true})
    true
  except:
    errorPrint "failed to create directory ", $path, ": ", getCurrentExceptionMsg()
    false

proc isExecutableFile(path: cstring): bool =
  if path.len == 0 or not pathExists(path):
    return false
  try:
    let stat = fs.lstatSync(path)
    if not cast[bool](stat.isFile()) and not cast[bool](stat.isSymbolicLink()):
      return false
    when defined(windows):
      return true
    else:
      return (stat.mode.to(int) and 0o111) != 0
  except:
    return false

proc isDirectoryPath(path: cstring): bool =
  ## Does `path` name a directory that exists right now?
  ##
  ## `spawn` needs this of `options.cwd` and answers `ENOENT` (or `ENOTDIR` for
  ## a file, which it *throws* rather than emitting) when it does not hold, so
  ## asking first is the difference between naming the missing directory and
  ## reporting five letters that mean three different things.  See issue #747.
  if path.len == 0:
    return false
  try:
    return cast[bool](fs.statSync(path).isDirectory())
  except:
    return false

proc effectiveSearchPath(options: JsObject): cstring =
  ## The `PATH` `spawn` will resolve a bare executable name against.
  ##
  ## **`options.env` wins when it is supplied**, and a re-record can supply one
  ## built from `Trace.env` — a snapshot of the environment the program was
  ## recorded in, possibly on another machine.  So the recorder can be perfectly
  ## installed and still be unfindable, which is the third `ENOENT` cause of
  ## issue #747 and the one nothing in the codebase acknowledged.
  if not options.isNil:
    try:
      let envObject = options.env
      if not envObject.isNil and not envObject.PATH.isNil:
        return envObject.PATH.to(cstring)
    except:
      discard
  try:
    return nodeProcess.toJs.env.PATH.to(cstring)
  except:
    return cstring""

proc resolveRecorderExe(exe: cstring; options: JsObject): cstring =
  ## Where `spawn(exe, …, options)` will actually find `exe`, or `""` when it
  ## will not find it at all.
  ##
  ## `codetracerExe` is an absolute path when the install prefix is known and
  ## the bare name `"ct"` otherwise (`src/common/paths.nim`,
  ## `resolveCodetracerExe`), so both shapes are live and they fail for
  ## different reasons.
  if exe.len == 0:
    return cstring""
  if looksLikeAPath($exe):
    if isExecutableFile(exe):
      return exe
    # Windows names the same binary `ct.exe` while `codetracerExe` spells it
    # `<prefix>/bin/ct` (`paths.nim`'s `when defined(windows)` arm), so the
    # bare spelling missing is not the same as the recorder missing.
    let windowsExe = cstring($exe & ".exe")
    if isExecutableFile(windowsExe):
      return windowsExe
    return cstring""
  let searchPath = $effectiveSearchPath(options)
  if searchPath.len == 0:
    return cstring""
  let delimiter = $cast[JsObject](nodePath).delimiter.to(cstring)
  let separator = if delimiter.len > 0: delimiter else: ":"
  for directory in searchPath.split(separator):
    if directory.len == 0:
      continue
    let candidate = nodePath.join(cstring(directory), exe)
    if isExecutableFile(candidate):
      return candidate
  cstring""

proc materializedTraceRootHasEntries(trace: Trace; root: string): bool =
  let materializedPath = nodePath.join(trace.outputFolder, cstring"files", cstring(root))
  if not pathExists(materializedPath):
    return false
  try:
    let data = fs.lstatSync(materializedPath)
    if cast[bool](data.isFile()) or cast[bool](data.isSymbolicLink()):
      return true
    if cast[bool](data.isDirectory()):
      return fs.readdirSync(materializedPath).len > 0
  except:
    discard
  false

proc fallbackLiveSourceFolders*(trace: Trace): seq[cstring] =
  if trace.program.len > 0:
    if ($trace.program).isAbsoluteFilesystemPath:
      if pathExists(trace.program):
        result.addUniquePath(trace.program)
    elif trace.workdir.len > 0:
      let programPath = nodePath.join(trace.workdir, trace.program)
      if pathExists(programPath):
        result.addUniquePath(programPath)

  if result.len == 0 and trace.workdir.len > 0 and pathExists(trace.workdir):
    result.addUniquePath(trace.workdir)

proc payloadTopLevelNames(trace: Trace): seq[string] =
  ## The names directly under the trace's ``files/`` payload; empty when
  ## the trace has no payload.
  let filesRoot = nodePath.join(trace.outputFolder, cstring"files")
  if not pathExists(filesRoot):
    return @[]
  try:
    for entry in fs.readdirSync(filesRoot):
      result.add $entry
  except:
    warnPrint "failed to list the trace payload ", $filesRoot, ": ",
      getCurrentExceptionMsg()

proc sourceFoldersFromTracePaths*(trace: Trace): Future[seq[cstring]] {.async.} =
  ## The roots of the Files pane for ``trace``.
  ##
  ## A live recording's roots are its recorded source folders.  An
  ## imported (self-contained) trace stores its sources under
  ## ``trace/files`` using relative paths from ``paths.json`` (the
  ## runtime-materialized mirror of the CTFS internal ``paths.json``
  ## file; pre-M-REC-1.5 the sidecar was named ``trace_paths.json``), so
  ## its roots are chosen by the pure rule
  ## ``trace_source_paths.importedTraceTreeRoots``.
  if not trace.imported:
    var sourceFolders: seq[cstring] = trace.sourceFolders
    if sourceFolders.len == 0:
      sourceFolders = fallbackLiveSourceFolders(trace)
    return sourceFolders

  var input = ImportedTraceTreeInputs(
    workdir: if trace.workdir.isNil: "" else: $trace.workdir,
    payloadTopLevel: payloadTopLevelNames(trace))
  for folder in trace.sourceFolders:
    input.recordedSourceFolders.add $folder
  for folder in fallbackLiveSourceFolders(trace):
    input.liveFallback.add $folder

  let (rawTracePaths, err) = await fsReadFileWithErr(
    nodePath.join(trace.outputFolder, cstring"paths.json"))
  if err.isNil:
    input.tracePathsRead = true
    try:
      let tracePaths = cast[seq[cstring]](JSON.parse(rawTracePaths))
      for rawPath in tracePaths: input.tracePaths.add $rawPath
    except:
      warnPrint "failed to derive filesystem folders from paths.json: ",
        getCurrentExceptionMsg()

  let roots = importedTraceTreeRoots(
    input,
    proc(root: string): bool = materializedTraceRootHasEntries(trace, root))
  var folders: seq[cstring] = @[]
  for root in roots:
    folders.addUniquePath(cstring(root))
  return folders

proc sendSymbols(main: js, traceFolder: cstring, tab: JsObject) {.async.} =
  try:
    let symbols = await loadSymbols(traceFolder)
    main.webContents.send "CODETRACER::symbols-loaded",
      withTab(js{symbols: symbols}, tab)
  except:
    errorPrint "loading symbols: ", getCurrentExceptionMsg()

proc findSourcemapPath(outputFolder: cstring): cstring =
  ## Find the ct_sourcemap_* file in the trace's nimcache directory.
  ## Returns the path if found, or an empty cstring if not.
  let nimcacheDir = cstring($outputFolder / "nimcache")
  if not fs.existsSync(nimcacheDir):
    return cstring""
  try:
    let entries = fs.readdirSync(nimcacheDir)
    for entry in entries:
      if ($entry).startsWith("ct_sourcemap_"):
        return cstring($nimcacheDir / $entry)
  except:
    warnPrint "failed to scan nimcache for sourcemap: ", getCurrentExceptionMsg()
  return cstring""

proc findMacroSourcemapPath(outputFolder: cstring): cstring =
  ## Find the macro_sourcemap*.json file in the trace directory (S6).
  ## The macro sourcemap is generated by the Nim compiler with --sourcemap:on
  ## and copied to the trace directory during recording.
  ## Returns the path if found, or an empty cstring if not.
  let traceDir = $outputFolder
  if not fs.existsSync(traceDir.cstring):
    return cstring""
  try:
    let entries = fs.readdirSync(traceDir.cstring)
    for entry in entries:
      let entryStr = $entry
      if entryStr.startsWith("macro_sourcemap") and entryStr.endsWith(".json"):
        return cstring(traceDir / entryStr)
  except:
    warnPrint "failed to scan trace dir for macro_sourcemap: ", getCurrentExceptionMsg()
  return cstring""

proc traceVisualReplayAvailable(trace: Trace): bool =
  if trace.isNil:
    return false
  try:
    detectVisualReplayAvailability(
      $trace.outputFolder,
      proc(path: string): bool = pathExists(cstring(path)),
      proc(path: string): string = $fs.readFileSync(cstring(path), cstring"utf8"),
      proc(path: string): seq[string] =
        let entries = fs.readdirSync(cstring(path))
        for entry in entries:
          result.add($entry))
  except:
    warnPrint "failed to inspect visual replay capability: ", getCurrentExceptionMsg()
    false

proc startVisualReplayForTrace(trace: Trace): Future[VisualReplayPlayerResult] {.async.} =
  if trace.isNil or not traceVisualReplayAvailable(trace):
    return VisualReplayPlayerResult(ok: false, url: "", error: "")

  when defined(js):
    let tracePath = findTraceContainerPath($trace.outputFolder)
    let lifecycle = createVisualReplayPlayerLifecycle(
      tracePath,
      defaultVisualReplayPlayerDeps())
    let result = await lifecycle.start()
    if result.ok and selectedReplayId >= 0:
      registerVisualReplayPlayer(selectedReplayId, lifecycle)
    else:
      lifecycle.shutdown()
    return result
  else:
    return VisualReplayPlayerResult(
      ok: false,
      url: "",
      error: "Visual replay player is only available in the main process.")

proc loadTrace*(main: js, trace: Trace, config: Config, helpers: Helpers): Future[void] {.async.} =
  ## Send the renderer what it needs to show `trace`, and record its save on
  ## the index process's own state (`config.data`). It used to take a
  ## `var ServerData` and work on a local copy of it, which on the JS backend
  ## is a COPY of the object (see `startup.init`), so `data.save` never
  ## reached the process state.
  # The tab this load answers, taken now: the sends below run after awaits,
  # and every one of them is for this load's tab (`tab_answers`).
  let tab = loadTab
  # set title
  when not defined(server):
    main.setTitle(trace.program)

  let traceFilesPath = cstring($trace.outputFolder / "files")
  discard sendFilenames(main, trace.sourceFolders, trace.outputFolder, trace.imported, tab)
  # Choosing the roots reads the trace folder, so it can fail too; the
  # pane must still get its answer (see `sendFilesystem`).
  var filesystemSourceFolders: seq[cstring] = @[]
  var rootsFailure = ""
  try:
    filesystemSourceFolders = await sourceFoldersFromTracePaths(trace)
  except:
    rootsFailure = getCurrentExceptionMsg()
    if rootsFailure.len == 0:
      rootsFailure = "choosing the source folders failed"

  if rootsFailure.len > 0:
    sendFilesystemFailure(main, trace.sourceFolders, rootsFailure, tab)
  # Check if we have a workspace folder and if trace files are outside it
  elif not data.workspaceFolder.isNil and data.workspaceFolder.len > 0:
    # Check if all trace source folders are inside the workspace
    var allInside = true
    var outsideFolders: seq[cstring] = @[]
    for folder in filesystemSourceFolders:
      if not isPathInside(folder, data.workspaceFolder):
        allInside = false
        outsideFolders.add(folder)

    if not allInside and outsideFolders.len > 0:
      # Send trace files as a separate category
      discard sendFilesystemWithCategory(main, cstring"Trace Files", outsideFolders, traceFilesPath, trace.imported, tab)
    else:
      # All trace files are inside workspace, just update the existing tree
      discard sendFilesystem(main, filesystemSourceFolders, traceFilesPath, trace.imported, tab)
  else:
    # No workspace folder set, use normal loading
    discard sendFilesystem(main, filesystemSourceFolders, traceFilesPath, trace.imported, tab)

  discard sendSymbols(main, trace.outputFolder, tab)

  var functions = await loadFunctions(cstring($trace.outputFolder / "function_index.json"))
  var save = await getSave(trace.sourceFolders, config.test)
  data.save = save

  # `$CODETRACER_HOME/config`, else (as always) `~/.config/codetracer`.
  let dir = ctHomeAreaOr(chaConfig, getHomeDir() / ".config" / "codetracer")
  let configFile = dir / "dont_ask_again.txt"

  let dontAskAgain = fs.existsSync(configFile)
  let startOptions = data.startOptions

  # For Nim traces, locate the sourcemap file so the renderer can load it
  # for ViewTargetSource line synchronization between Nim and C code.
  var sourcemapPath = cstring""
  var macroSourcemapPath = cstring""
  if trace.lang == LangNim:
    sourcemapPath = findSourcemapPath(trace.outputFolder)
    if sourcemapPath.len > 0:
      infoPrint "index: found sourcemap at ", $sourcemapPath
    macroSourcemapPath = findMacroSourcemapPath(trace.outputFolder)
    if macroSourcemapPath.len > 0:
      infoPrint "index: found macro sourcemap at ", $macroSourcemapPath

  let visualReplayAvailable = traceVisualReplayAvailable(trace)
  var visualReplayPlayerUrl = cstring""
  var visualReplayPlayerError = cstring""
  if visualReplayAvailable:
    let visualReplayPlayer = await startVisualReplayForTrace(trace)
    if visualReplayPlayer.ok:
      visualReplayPlayerUrl = cstring(visualReplayPlayer.url)
    elif visualReplayPlayer.error.len > 0:
      visualReplayPlayerError = cstring(visualReplayPlayer.error)
      warnPrint "visual replay player failed: ", visualReplayPlayer.error

  main.webContents.send "CODETRACER::trace-loaded", withTab(js{
    trace: trace,
    functions: functions,
    save: save,
    diff: startOptions.diff,
    withDiff: startOptions.withDiff,
    rawDiffIndex: startOptions.rawDiffIndex,
    dontAskAgain: dontAskAgain,
    sourcemapPath: sourcemapPath,
    macroSourcemapPath: macroSourcemapPath,
    visualReplayAvailable: visualReplayAvailable,
    visualReplayPlayerUrl: visualReplayPlayerUrl,
    visualReplayPlayerError: visualReplayPlayerError,
  }, tab)

proc jsDateNow(): float {.importjs: "Date.now()".}
proc jsRandom(): float {.importjs: "Math.random()".}
proc nodeRandomUUID(): cstring {.importjs: "require('crypto').randomUUID()".}

proc makeLiveRecordingId(): cstring =
  try:
    nodeRandomUUID()
  except:
    cstring(fmt"live-{nodeProcess.pid}-{jsDateNow().int64}-{int(jsRandom() * 1_000_000)}")

proc optionCwd(options: JsObject): cstring =
  if options.isNil:
    return cstring""
  try:
    if not options.cwd.isNil:
      return options.cwd.to(cstring)
  except:
    discard
  cstring""

proc recordTargetOf(recordArgs: seq[cstring]): cstring =
  ## The program inside a `ct record` argument vector.
  ##
  ## Not simply `recordArgs[0]`: `ui/welcome_screen.prepareArgs` (`:341-345`)
  ## prefixes `-o <outputFolder>` when the user chose one, so the program is
  ## the first entry that is not a flag or a flag's value.  Only `-o` takes a
  ## value here, and it is the only flag any sender emits.
  var i = 0
  while i < recordArgs.len:
    let arg = $recordArgs[i]
    if arg == "-o":
      i += 2
      continue
    if arg.len > 0 and arg[0] == '-':
      i += 1
      continue
    return recordArgs[i]
  cstring""

proc recordLaunchFactsFor(exe: cstring; recordTarget: cstring;
                          options: JsObject): RecordLaunchFacts =
  ## Observe everything `classifyRecordLaunch` needs, in the one process that
  ## can observe it.  The decision itself stays pure — see
  ## `src/frontend/file_conflicts.nim`.
  let requestedCwd = optionCwd(options)
  result = RecordLaunchFacts(
    recorder: $exe,
    recorderResolved: $resolveRecorderExe(exe, options),
    recordTarget: $recordTarget,
    requestedCwd: $requestedCwd,
    requestedCwdUsable: isDirectoryPath(requestedCwd))
  if not result.requestedCwdUsable and recordTarget.len > 0:
    # The target is an absolute path or a project root by the time it gets
    # here, so its own directory is a defensible place to run from.
    if isDirectoryPath(recordTarget):
      result.fallbackCwd = $recordTarget
    else:
      let parent = cstring(($recordTarget).parentDir)
      if isDirectoryPath(parent):
        result.fallbackCwd = $parent

proc applyRecordLaunchCwd(options: JsObject; facts: RecordLaunchFacts) =
  ## Replace the requested `options.cwd` with the one that actually exists.
  ##
  ## Clearing the key rather than writing `""` matters.  `undefined` is how you
  ## say "inherit" here — verified against node v20.20.0 / macOS 15 arm64, where
  ## `spawn(exe, args, {cwd: undefined})` runs in the parent's directory and
  ## `{cwd: "/gone"}` is the `ENOENT` of issue #747.  The empty string is NOT an
  ## equivalent spelling: async `spawn` happens to tolerate `{cwd: ""}` and
  ## inherit, but `spawnSync(exe, args, {cwd: ""})` answers `ENOENT` for the
  ## same input, so writing `""` would make the meaning of this field depend on
  ## which node API the caller reaches for.
  ## https://nodejs.org/api/child_process.html#child_processspawncommand-args-options
  if options.isNil:
    return
  let resolved = recordLaunchCwd(facts)
  if resolved.len == 0:
    if facts.requestedCwd.len > 0:
      options["cwd".cstring] = jsUndefined
  else:
    options["cwd".cstring] = cast[JsObject](cstring(resolved))

proc checkRecordLaunch(exe: cstring; recordTarget: cstring;
                       options: JsObject): bool =
  ## Refuse a recorder spawn whose preconditions do not hold, saying which one.
  ##
  ## Issue #747: `spawn` reports `ENOENT` for a missing executable, a missing
  ## `options.cwd` and an unresolvable bare name alike, and names the
  ## executable in `error.path` in all three — so the message the reporter
  ## photographed was compatible with three unrelated causes and pointed at the
  ## wrong one.  Asking first is what turns it back into a diagnosis.
  ##
  ## Returns `true` when the launch may proceed.  A dead working directory is
  ## NOT a refusal: it is replaced, out loud.
  let facts = recordLaunchFactsFor(exe, recordTarget, options)
  let defect = classifyRecordLaunch(facts)
  if defect != rldNone:
    let refusal = recordLaunchRefusal(facts, defect)
    errorPrint "index: record launch refused: ", refusal
    mainWindow.webContents.send "CODETRACER::failed-record",
      forLoadTab(js{errorMessage: cstring(refusal)})
    return false
  applyRecordLaunchCwd(options, facts)
  let warning = recordLaunchCwdWarning(facts)
  if warning.len > 0:
    warnPrint "index: ", warning
    mainWindow.webContents.send "CODETRACER::new-notification",
      newNotification(NotificationWarning, warning)
  true

proc sourceFoldersForLiveProgram(program, cwd: cstring): seq[cstring] =
  if cwd.len > 0 and pathExists(cwd):
    result.addUniquePath(cwd)
  if program.len > 0:
    let parent = cstring(($program).parentDir)
    if parent.len > 0 and pathExists(parent):
      result.addUniquePath(parent)

proc resolveLiveProgramPath(program, cwd: cstring): cstring =
  if program.len == 0:
    return cstring""
  if ($program).isAbsoluteFilesystemPath or cwd.len == 0:
    return program
  nodePath.join(cwd, program)

proc argsFrom(recordArgs: seq[cstring]; start: int): seq[cstring] =
  if start >= recordArgs.len:
    @[]
  else:
    recordArgs[start .. ^1]

proc liveProgramArgs(filename: cstring; recordArgs: seq[cstring]):
    tuple[program: cstring, args: seq[cstring], outputFolder: cstring] =
  let filenameIsProgram = filename.len > 0 and isExecutableFile(filename)

  if filenameIsProgram:
    result.program = filename
    if recordArgs.len == 0:
      result.args = @[]
    elif recordArgs[0] == filename:
      result.args = recordArgs.argsFrom(1)
    elif recordArgs.len >= 2 and recordArgs[1] == filename:
      result.outputFolder = recordArgs[0]
      result.args = recordArgs.argsFrom(2)
    else:
      result.args = recordArgs
    return

  if recordArgs.len > 0 and isExecutableFile(recordArgs[0]):
    result.program = recordArgs[0]
    result.args = recordArgs.argsFrom(1)
  elif recordArgs.len >= 2 and isExecutableFile(recordArgs[1]):
    result.outputFolder = recordArgs[0]
    result.program = recordArgs[1]
    result.args = recordArgs.argsFrom(2)

proc newLiveTrace(program: cstring;
                  programArgs: seq[cstring];
                  cwd: cstring;
                  outputFolder: cstring): Trace =
  let recordingId = makeLiveRecordingId()
  let traceFolder =
    if outputFolder.len > 0:
      outputFolder
    else:
      cstring(recordingFolder(codetracerTraceDir, $recordingId))
  let workdir =
    if cwd.len > 0:
      cwd
    else:
      cstring(($program).parentDir)
  let sourceFolders = sourceFoldersForLiveProgram(program, workdir)
  Trace(
    recordingId: recordingId,
    program: program,
    args: programArgs,
    env: cstring"",
    workdir: workdir,
    output: cstring"",
    sourceFolders: sourceFolders,
    lowLevelFolder: cstring"",
    compileCommand: data.config.defaultBuild,
    outputFolder: traceFolder,
    date: cstring"",
    duration: cstring"",
    lang: toLangFromFilename(program),
    imported: false,
    calltrace: true,
    events: true,
    test: data.config.test,
    archiveServerID: 0,
    shellID: 0,
    teamID: 0,
    rrPid: 0,
    exitCode: 0,
    calltraceMode: CalltraceMode.FullRecord,
    downloadKey: cstring"",
    controlId: cstring"",
    onlineExpireTime: 0,
  )

proc sendInitAndLoadTrace(trace: Trace) {.async.} =
  data.trace = trace
  data.pluginClient.trace = trace
  if data.trace.compileCommand.len == 0:
    data.trace.compileCommand = data.config.defaultBuild

  mainWindow.webContents.send(
    "CODETRACER::init",
    forLoadTab(js{
      home: paths.home.cstring,
      config: data.config,
      layout: data.layout,
      helpers: data.helpers,
      startOptions: data.startOptions,
      bypass: true}))

  await loadTrace(mainWindow, data.trace, data.config, data.helpers)

proc prepareForLiveTrace*(trace: Trace,
                          program: cstring,
                          programArgs: seq[cstring],
                          cwd: cstring,
                          liveRecordingDir: cstring,
                          pid: int) {.async.} =
  callerProcessPid = pid
  prefetchedTrace = trace
  data.trace = trace
  data.pluginClient.trace = trace

  infoPrint "index: requesting live replay worker for ", $trace.recordingId,
    " folder ", $liveRecordingDir

  let replayId = await startReplayProcess()
  if replayId < 0:
    errorPrint "Unable to start live replay worker"
    return

  selectedReplayId = replayId
  let selectPacket = wrapJsonForSending js{
    "type": cstring"request",
    "command": cstring"ct/select-replay",
    "arguments": replayId
  }
  backendManagerSocket.write(selectPacket)
  noteReplaySelected(replayId)

  mainWindow.webContents.send(
    "CODETRACER::dap-live-session-selected",
    forLoadTab(js{
      trace: trace,
      replayId: replayId,
      program: program,
      args: programArgs,
      cwd: cwd,
      liveRecordingDir: liveRecordingDir,
    }))

  await sendInitAndLoadTrace(trace)

proc loadExistingRecord*(recordingId: cstring) {.async.} =
  ## M-REC-3: UUIDv7 recording-id (cstring in JS/Electron context).
  infoPrint "[info]: load existing record with ID: ", $recordingId
  if prefetchedTrace.isNil or prefetchedTrace.recordingId != recordingId:
    if not await assignTrace(recordingId):
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
    forLoadTab(js{
      home: paths.home.cstring,
      config: data.config,
      layout: data.layout,
      helpers: data.helpers,
      startOptions: data.startOptions,
      bypass: true}))

  if not data.trace.isNil:
    infoPrint "index: loading trace in mainWindow"
    await loadTrace(mainWindow, data.trace, data.config, data.helpers)

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

proc prepareForLoadingTrace*(recordingId: cstring, pid: int) {.async.} =
  ## M-REC-3: UUIDv7 recording-id (cstring in JS/Electron context).
  callerProcessPid = pid
  if prefetchedTrace.isNil or prefetchedTrace.recordingId != recordingId:
    if not await assignTrace(recordingId):
      return
  else:
    infoPrint "index: reuse prefetched trace ", $prefetchedTrace.recordingId, " folder ", $prefetchedTrace.outputFolder
    data.trace = prefetchedTrace
    data.pluginClient.trace = prefetchedTrace
    if data.trace.compileCommand.len == 0:
      data.trace.compileCommand = data.config.defaultBuild

  infoPrint "index: requesting new replay for trace ", $recordingId
  if not data.trace.isNil:
    infoPrint "index: ct/start-replay for trace folder ", $data.trace.outputFolder

  # Do NOT stop the previous replay — multiple sessions need simultaneous
  # DAP connections.  Each session's replay is tracked in sessionReplayIds
  # and stopped only when its session is explicitly closed (see
  # stopReplayForSession).

  let replayId = await startReplayProcess()
  if replayId < 0:
    errorPrint "Unable to start replay for new trace"
    return

  # Track the replay so it can be stopped when its session is closed.
  # Also update the legacy selectedReplayId for backwards compatibility
  # with single-session code paths.  The renderer will tell us which
  # session index to associate this replay with via the
  # "dap-replay-selected" event's response.
  selectedReplayId = replayId
  infoPrint "index: selecting replayId ", $replayId

  let selectPacket = wrapJsonForSending js{
    "type": cstring"request",
    "command": cstring"ct/select-replay",
    "arguments": replayId
  }
  backendManagerSocket.write(selectPacket)
  noteReplaySelected(replayId)
  mainWindow.webContents.send(
    "CODETRACER::dap-replay-selected",
    forLoadTab(js{trace: data.trace, replayId: replayId}))

var
  replayStopAllowed*: proc(replayId: int): bool = nil
    ## Whether the client asking may stop `replayId`. `ct host` allows a
    ## client its own replays only (`host_clients`): its clients are separate
    ## sessions, and one must not end another's. Nil, the desktop, allows
    ## every one: its windows are one user's.
  replayStopped*: proc(replayId: int) = nil
    ## Told after a client's request stopped `replayId`.

proc stopReplayProcess*(replayId: int) =
  ## Stop the replay `replayId` (`ct/stop-replay`) and what serves it.
  if replayId < 0 or backendManagerSocket.isNil:
    return
  infoPrint "index: ct/stop-replay for replayId ", $replayId

  let stopPacket = wrapJsonForSending js{
    "type": cstring"request",
    "command": cstring"ct/stop-replay",
    "arguments": replayId
  }
  backendManagerSocket.write(stopPacket)
  noteReplayStopped(replayId)

  stopVisualReplayPlayer(replayId)

  # Clear the legacy alias if it matches.
  if selectedReplayId == replayId:
    selectedReplayId = -1

proc onCloseReplaySession*(sender: js, response: JsObject) {.async.} =
  ## IPC handler: renderer requests that a session's replay be stopped.
  ## Payload: { replayId: int }
  let replayId = response["replayId"].to(int)
  if replayId < 0:
    return
  if not replayStopAllowed.isNil and not replayStopAllowed(replayId):
    warnPrint "index: refused to stop replay ", $replayId,
      ": it is not the asking client's"
    return
  stopReplayProcess(replayId)
  if not replayStopped.isNil:
    replayStopped(replayId)

proc replayTx(txHash: cstring, pid: int): Future[(cstring, cstring)] {.async.} =
  ## M-REC-3: returns the UUIDv7 recording-id as a cstring; empty
  ## means "no trace recorded" (replacement for the legacy
  ## ``NO_INDEX`` integer sentinel).
  ## M-REC-6: the subprocess wire-format prefix is now ``recordingId:``;
  ## the legacy ``traceId:`` prefix is no longer emitted by the recorder.
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
      let recordingIdLine = $lines[^2]
      # probably because we print `recordingId:<id>\n` : so the last line is ''
      #   and recordingId is in the second last line
      if recordingIdLine.startsWith("recordingId:"):
        let recordingId = cstring(recordingIdLine[("recordingId:").len .. ^1].strip)
        return (output, recordingId)
  else:
    output = JSON.stringify(outputResult.error)
  return (output, cstring"")

proc onLoadRecentTrace*(sender: js, response: jsobject(traceId=cstring)) {.async.} =
  ## IPC field name ``traceId`` preserved (M-REC-5 wire format).  The
  ## payload value is our local recording id.
  # Every message of the load this starts answers the tab that asked.
  startLoadFor(response.toJs)
  await prepareForLoadingTrace(response.traceId, nodeProcess.pid.to(int))
  await loadExistingRecord(response.traceId)

proc onOpenTraceInTab*(sender: js, response: jsobject(traceId=cstring)) {.async.} =
  ## Open a trace as a new tab in the current window, rather than
  ## spawning a new Electron window.  This is the handler for the
  ## "tab" newTracePolicy.  The renderer receives a
  ## "CODETRACER::open-trace-in-tab-ready" message with the trace
  ## metadata so it can create a new session tab and load the trace.
  ## The IPC field name ``traceId`` is preserved here as it is part of
  ## the renderer ↔ main-process wire format owned by M-REC-5.
  # The load is for the tab the renderer creates on
  # `open-trace-in-tab-ready`, which is then the tab on screen; no tab
  # has its id yet, so its messages name none (`tab_answers`).
  loadTab = jsUndefined
  let recordingId = response.traceId
  infoPrint "index: open-trace-in-tab for recording ", $recordingId

  # Tell the renderer to create a new session tab.
  mainWindow.webContents.send(
    "CODETRACER::open-trace-in-tab-ready",
    js{traceId: recordingId})

  # Prepare the replay backend for this trace (starts a DAP session).
  await prepareForLoadingTrace(recordingId, nodeProcess.pid.to(int))
  await loadExistingRecord(recordingId)

proc onLoadRecentTransaction*(sender: js, response: jsobject(txHash=cstring)) {.async.} =
  # Every message of the load this starts answers the tab that asked.
  startLoadFor(response.toJs)
  let (rawOutputOrError, recordingId) = await replayTx(response.txHash, nodeProcess.pid.to(int))
  if recordingId.len > 0:
    await prepareForLoadingTrace(recordingId, nodeProcess.pid.to(int))
    await loadExistingRecord(recordingId)
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
  # A recorder process asked, not a tab: the tab on screen (`tab_answers`).
  loadTab = jsUndefined
  let trace = await electron_vars.app.findTraceByRecordProcessId(pid)
  infoPrint "index: trace by record process id has recording id ", trace.recordingId
  prefetchedTrace = trace
  data.trace = trace
  data.pluginClient.trace = trace
  await prepareForLoadingTrace(trace.recordingId, pid)
  await loadExistingRecord(trace.recordingId)

proc onStopRecordingProcess*(sender: js, response: js) {.async.} =
  if not data.recordProcess.isNil:
    if data.recordProcess.kill():
      data.recordProcess = nil
      # Clearing the slot here means the killed process no longer owns it and
      # will report nothing on exit, so the stop has to be reported instead —
      # the renderer's re-record gate stays shut until a recording it launched
      # is accounted for.
      mainWindow.webContents.send "CODETRACER::failed-record",
        forLoadTab(js{errorMessage: cstring"Recording stopped."})
    else:
      warnPrint "Unable to stop recording process"
  else:
    warnPrint "There is not any recording process"

proc onOpenLocalTrace*(sender: js, response: js) {.async.} =
  # Every message of the load this starts answers the tab that asked.
  startLoadFor(response.toJs)
  let selection = await selectDir(cstring"Select Trace Output Folder", codetracerTraceDir)
  if selection.len == 0:
    errorPrint "no folder selected"
  else:
    # selectDir tries to return a folder with a trailing slash
    let trace = await electron_vars.app.findByPath(selection)
    if not trace.isNil:
      mainWindow.webContents.send "CODETRACER::loading-trace",
        forLoadTab(js{trace: trace})
      prefetchedTrace = trace
      data.trace = trace
      data.pluginClient.trace = trace
      await prepareForLoadingTrace(trace.recordingId, nodeProcess.pid.to(int))
      await loadExistingRecord(trace.recordingId)
    else:
      errorPrint "There is no record at given path."

proc onLoadTraceFile*(sender: js, response: jsobject(tracePath=cstring)) {.async.} =
  ## Load a .ct trace file by path.  Used by the "Trace Macro Execution"
  ## action (M11) to open a trace produced by the Nim langserver's
  ## ``nim/traceExpandMacro`` command.
  ##
  ## The handler looks up the trace in the CodeTracer metadata store by
  ## its output path.  If the trace is not yet registered (e.g. a freshly
  ## generated macro trace), it registers it first, then loads it into
  ## the current session.
  # Every message of the load this starts answers the tab that asked.
  startLoadFor(response.toJs)
  let tracePath = response.tracePath
  if tracePath.len == 0:
    errorPrint "onLoadTraceFile: empty trace path"
    return

  infoPrint "index: loading trace file at ", tracePath

  # Two shapes reach this handler, and both must resolve:
  #
  #   * a **.ct file** path, from nimsuggest's macro trace — the metadata
  #     lookup wants the containing output folder, so it needs `dirname`;
  #   * a **trace folder** path, from AA-2's `ct test` drill-down — every
  #     `ct test` provider reports `TraceMetadata.path` as the output
  #     *directory* (`native_m11_common`, `js_common`, `ruby_common` and
  #     `smart_contract_common` all do), and taking its `dirname` would look
  #     up the parent directory and miss.
  #
  # So the path is tried as-is first, and only then as a file whose dirname to
  # take.  The .ct-file caller is unaffected: `findByPath` does not match a
  # file path, so it falls through to exactly the lookup it did before.
  let pathModule = require("path")
  let traceDir = cast[cstring](pathModule.dirname(tracePath))

  var trace = await electron_vars.app.findByPath(tracePath)
  if trace.isNil:
    trace = await electron_vars.app.findByPath(traceDir)
  if not trace.isNil:
    mainWindow.webContents.send "CODETRACER::loading-trace",
      forLoadTab(js{trace: trace})
    prefetchedTrace = trace
    data.trace = trace
    data.pluginClient.trace = trace
    await prepareForLoadingTrace(trace.recordingId, nodeProcess.pid.to(int))
    await loadExistingRecord(trace.recordingId)
  else:
    # Name the path the caller actually asked for, not the dirname.  While
    # `dirname` was the only lookup this handler did, naming it was the same
    # thing; now that the path is tried as-is first, reporting the dirname
    # tells the reader about a directory nobody named — the `ct test`
    # drill-down asked for `<...>/trace` and was told `<...>` was missing.
    errorPrint "onLoadTraceFile: no trace found at path: ", tracePath,
      " (nor at ", traceDir, ")"
    mainWindow.webContents.send "CODETRACER::trace-load-error",
      forLoadTab(js{error: cstring("No trace found at " & $tracePath &
         ". The .ct file may need to be imported first.")})

proc initEditModeForFolder(sender: js; folder: cstring) {.async.}

proc selectedOpenFolderForTest(): cstring =
  let folder = nodeProcess.env[cstring"CODETRACER_TEST_OPEN_FOLDER_DIALOG_PATH"]
  if folder.isNil:
    return cstring""
  folder

proc rememberRecentFolder(folder: cstring) {.async.} =
  let result = await readProcessOutput(
    codetracerExe.cstring,
    @[cstring"trace-metadata", cstring"--add-recent-folder", cstring($folder)])
  if result.isErr:
    warnPrint "could not update recent folder metadata: ", result.error

proc onOpenFolderDialog*(sender: js, response: js) {.async.} =
  # Every message of the load this starts answers the tab that asked.
  startLoadFor(response.toJs)
  var selection = selectedOpenFolderForTest()
  if selection.len == 0:
    selection = await selectDir(cstring"Select Folder to Open")
  if selection.len == 0:
    debugPrint "no folder selected"
  else:
    await initEditModeForFolder(sender, selection)
    discard rememberRecentFolder(selection)

proc onLoadRecentFolder*(sender: js, response: jsobject(folderPath=cstring)) {.async.} =
  # Every message of the load this starts answers the tab that asked.
  startLoadFor(response.toJs)
  await initEditModeForFolder(sender, response.folderPath)
  discard rememberRecentFolder(response.folderPath)

proc onOpenTraceDialog*(sender: js, response: js) {.async.} =
  ## Show file dialog to select a trace folder/file
  # Every message of the load this starts answers the tab that asked.
  startLoadFor(response.toJs)
  let selection = await selectDir(cstring"Select Trace Folder")
  if selection.len == 0:
    debugPrint "no trace folder selected"
  else:
    debugPrint "selected trace folder: ", selection
    # Check if it's a valid trace folder (contains trace.db or similar)
    # For now, just try to load it
    var traceResponse = js{tracePath: selection}
    await onOpenLocalTrace(sender, traceResponse)

proc onRecordFromLaunch*(sender: js, response: js) {.async.} =
  ## Parse launch.json and send configurations to frontend for menu display
  # Every message of the load this starts answers the tab that asked.
  startLoadFor(response.toJs)
  debugPrint "onRecordFromLaunch called"

  if data.workspaceFolder.isNil or data.workspaceFolder.len == 0:
    mainWindow.webContents.send "CODETRACER::new-notification",
      newNotification(NotificationWarning, "No workspace folder opened")
    return

  let launchConfigs = getLaunchConfigsForWorkspace(data.workspaceFolder)

  if launchConfigs.len == 0:
    mainWindow.webContents.send "CODETRACER::new-notification",
      newNotification(NotificationWarning, "No launch configurations found in .vscode/launch.json")
    return

  # Convert to JS-friendly format for sending to renderer
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

  mainWindow.webContents.send "CODETRACER::launch-configs-loaded", forLoadTab(js{configs: configsJs})

proc onRecordWithLaunchConfig*(sender: js,
    response: jsobject(configIndex=int, recordBackend=cstring)) {.async.} =
  ## Execute recording with a specific launch configuration
  # Every message of the load this starts answers the tab that asked.
  startLoadFor(response.toJs)
  infoPrint "onRecordWithLaunchConfig called with index: ", $response.configIndex
  infoPrint "workspaceFolder: ", $data.workspaceFolder

  if data.workspaceFolder.isNil or data.workspaceFolder.len == 0:
    mainWindow.webContents.send "CODETRACER::new-notification",
      newNotification(NotificationError, "No workspace folder opened")
    return

  let launchConfigs = getLaunchConfigsForWorkspace(data.workspaceFolder)

  if response.configIndex < 0 or response.configIndex >= launchConfigs.len:
    mainWindow.webContents.send "CODETRACER::new-notification",
      newNotification(NotificationError, "Invalid launch configuration index")
    return

  let config = launchConfigs[response.configIndex]

  infoPrint fmt"Recording with launch config: {config.name}"
  infoPrint fmt"  Program: {config.program}"
  infoPrint fmt"  Args: {config.args}"
  infoPrint fmt"  CWD: {config.cwd}"
  infoPrint fmt"  codetracerExe: {codetracerExe}"

  if response.recordBackend == cstring"mcr":
    let resolvedProgram = resolveLiveProgramPath(config.program, config.cwd)
    if isExecutableFile(resolvedProgram):
      let liveTrace = newLiveTrace(
        resolvedProgram,
        config.args,
        config.cwd,
        cstring"")
      if not ensureDirectory(liveTrace.outputFolder):
        mainWindow.webContents.send "CODETRACER::failed-record",
          forLoadTab(js{errorMessage: cstring"failed to create live recording directory"})
        return
      mainWindow.webContents.send "CODETRACER::new-notification",
        newNotification(NotificationInfo, fmt"Starting live session: {config.name}")
      await prepareForLiveTrace(
        liveTrace,
        resolvedProgram,
        config.args,
        liveTrace.workdir,
        liveTrace.outputFolder,
        nodeProcess.pid.to(int))
      return

  # Build record arguments
  var recordArgs = @[config.program]
  if not response.recordBackend.isNil and response.recordBackend.len > 0:
    recordArgs = @[cstring"--backend", response.recordBackend].concat(recordArgs)
  for arg in config.args:
    recordArgs.add(arg)

  # Build process options with environment variables
  var processOptions = js{
    "cwd": config.cwd,
    "stdio": cstring"inherit"
  }

  # Set up environment if we have env vars
  if config.env.len > 0:
    let processEnv = js{}
    # First copy existing env
    let nodeEnv = nodeProcess.toJs.env
    let envKeys = Object.keys(nodeEnv)
    for i in 0..<cast[int](envKeys.length):
      let key = envKeys[i].to(cstring)
      processEnv[key] = nodeEnv[key]
    # Add launch config env vars (they override)
    for j in 0 ..< config.env.len:
      let envPair = config.env[j]
      processEnv[envPair.key] = envPair.value.toJs
    processOptions["env"] = processEnv

  mainWindow.webContents.send "CODETRACER::new-notification",
    newNotification(NotificationInfo, fmt"Recording: {config.name}")

  # The same precondition gate as `onNewRecord` (issue #747).  This path is if
  # anything more exposed: `config.cwd` comes straight out of a checked-in
  # `launch.json`, which routinely names a directory that exists on the author's
  # machine and not on this one.
  if not checkRecordLaunch(codetracerExe, config.program, processOptions):
    return

  let processResult = await startProcess(
    codetracerExe,
    @[cstring"record"].concat(recordArgs),
    processOptions)

  if processResult.isOk:
    infoPrint "index: record process started with pid " & $processResult.value.pid
    data.recordProcess = processResult.value
    let error = await waitProcessResult(processResult.value)

    # Same ownership rule as `onNewRecord`: release the slot on exit, and only
    # report for the process that still holds it.  Leaving it set here would
    # make every later re-record look like "a recording is already running".
    let ownsSlot = not data.recordProcess.isNil and
      data.recordProcess.pid == processResult.value.pid
    if ownsSlot:
      data.recordProcess = nil

    if error.isNil:
      infoPrint "index: recorded successfully from launch config, now loading trace..."
      mainWindow.webContents.send "CODETRACER::successful-record", forLoadTab(js{})
      infoPrint "index: calling onLoadTraceByRecordProcessId with pid " & $processResult.value.pid
      await onLoadTraceByRecordProcessId(nil, processResult.value.pid)
      infoPrint "index: onLoadTraceByRecordProcessId completed"
    else:
      errorPrint "record error: ", error
      errorPrint "record error message: ", cast[cstring](error)
      if ownsSlot:
        mainWindow.webContents.send "CODETRACER::failed-record",
          forLoadTab(js{errorMessage: cstring"codetracer record command failed"})
  else:
    errorPrint "record start process error: ", processResult.error
    let errorSpecificText = if not processResult.error.isNil: cast[cstring](processResult.error.code) else: cstring""
    let errorText = cstring"record start process error: " & errorSpecificText
    mainWindow.webContents.send "CODETRACER::failed-record",
      forLoadTab(js{errorMessage: errorText})

proc sendNotification*(kind: NotificationKind, message: string) =
  # The renderer subscribes to the namespaced channel (`ui_js.configureIPC`),
  # so an unprefixed send is simply dropped.  Every progress message routed
  # through this helper — "ct record process started", "starting live native
  # session" — was therefore invisible; see issue #603.
  let notification = newNotification(kind, message)
  mainWindow.webContents.send "CODETRACER::new-notification", notification

proc initEditMode(sender: js; folders: seq[cstring]) {.async.} =
  ## Enter edit mode over zero or one folders, and hand the renderer the
  ## `CODETRACER::no-trace` message that puts it there.
  ##
  ## ISSUE #735 generalised this from one folder to a SEQUENCE, so that "New
  ## file" — which opens edit mode with no project at all — takes the same path
  ## rather than a parallel one. The empty case is not a special case anywhere
  ## below: `loadFilesystem(@[])` returns the artificial "source folders" root
  ## with no children, `loadFilenames(@[])` returns an empty list,
  ## `getLaunchConfigsForWorkspace("")` finds nothing, and `getSave` ignores its
  ## folders entirely. The one thing that does differ is `startOptions.folder`,
  ## which stays empty — and `ui_js.onNoTrace` reads exactly that to decide the
  ## session gets an untitled buffer.
  let folder = if folders.len > 0: folders[0] else: cstring""
  # Set the startup options to edit mode
  data.startOptions.edit = true
  data.startOptions.welcomeScreen = false  # No longer in welcome screen mode
  data.startOptions.folder = folder
  data.startOptions.name = cstring""
  data.workspaceFolder = folder

  # Load filesystem and filenames for the folder
  let filesystem = await loadFilesystem(folders, traceFilesPath=cstring"", selfContained=false)
  let filenames = await loadFilenames(folders, traceFolder=cstring"", selfContained=false)
  var functions: seq[Function] = @[]
  let save = await getSave(folders, data.config.test)
  data.save = save

  # Open folders in the edit layout, not the debugger replay layout.  The
  # loader validates and resets stale/corrupt user layout files before
  # returning, so a broken default_edit_layout.json cannot blank the handoff.
  let layout = await mainWindow.loadEditLayoutConfig(
    string(userLayoutDir / "default_edit_layout.json"))

  # Send no-trace message to switch to edit mode
  mainWindow.webContents.send "CODETRACER::no-trace", forLoadTab(js{
    path: folder,
    lang: save.project.lang,
    home: paths.home.cstring,
    layout: layout,
    helpers: data.helpers,
    startOptions: data.startOptions,
    config: data.config,
    filenames: filenames,
    filesystem: filesystem,
    functions: functions,
    save: save
  })

  # Also load and send launch configs for the workspace.
  #
  # Only when there IS one. `getLaunchConfigsForWorkspace("")` joins to the
  # relative `.vscode/launch.json`, which resolves against the Electron main
  # process's own working directory — so a projectless edit session (issue
  # #735's "New file") would silently adopt whatever launch configurations
  # happened to sit beside wherever CodeTracer was started from.
  let launchConfigs =
    if folder.len > 0: getLaunchConfigsForWorkspace(folder)
    else: newSeq[LaunchConfig]()
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
    mainWindow.webContents.send "CODETRACER::launch-configs-loaded", forLoadTab(js{configs: configsJs})

proc initEditModeForFolder(sender: js; folder: cstring) {.async.} =
  await initEditMode(sender, @[folder])

proc onInitEditMode*(sender: js, response: jsobject(folder=cstring)) {.async.} =
  # Every message of the load this starts answers the tab that asked.
  startLoadFor(response.toJs)
  await initEditModeForFolder(sender, response.folder)

proc onNewFile*(sender: js, response: js) {.async.} =
  ## ISSUE #735 — the welcome screen's "New file" start option.
  ##
  ## Edit mode with NO project: no folder to walk, no filenames, no save file.
  ## `ui_js.onNoTrace` recognises that state by `startOptions.folder` being
  ## empty — nothing else in the product reaches edit mode without a folder;
  ## see that branch's comment for what guarantees it — and opens one untitled
  ## buffer.
  ##
  ## The main process's own state is updated by `initEditMode` exactly as an
  ## "Open folder" would update it, which is why this goes through the main
  ## process at all rather than opening a tab in the renderer directly: after
  ## this returns, `data.startOptions` and `data.workspaceFolder` describe an
  ## edit session with no workspace, and everything downstream that asks —
  ## `onRecordFromLaunch`, `hcr_launch`, a later mode switch — gets a truthful
  ## answer instead of a stale "the welcome screen is up".
  # Every message of the load this starts answers the tab that asked.
  startLoadFor(response.toJs)
  await initEditMode(sender, @[])

proc onNewRecord*(sender: js,
    response: jsobject(filename=cstring, args=seq[cstring], options=JsObject,
                       projectOnly=bool, recordBackend=cstring)) {.async.}=
  # Every message of the load this starts answers the tab that asked.
  startLoadFor(response.toJs)
  infoPrint "index: new record for", response.filename, " originally ", response.args, " projectOnly?: ", response.projectOnly
  # One recorder at a time.  `data.recordProcess` is a single slot and
  # `ct build` writes into the target project's own build directory, so a
  # second `ct record` started while the first is running clobbers the build
  # and then reports its failure against the other one's slot — the stack of
  # identical "ct record process started" / "codetracer record command failed"
  # notifications in issue #603.  The renderer refuses the second request
  # first; this is the backstop for every other sender.
  if not data.recordProcess.isNil:
    warnPrint "index: a record process is already running; refusing a second one"
    mainWindow.webContents.send "CODETRACER::failed-record",
      forLoadTab(js{errorMessage: cstring"A recording is already running; " &
                       cstring"wait for it to finish before starting another."})
    return
  # TODO fix replay
  var recordArgs = response.args
  let recordBackendArgs =
    if not response.recordBackend.isNil and response.recordBackend.len > 0:
      @[cstring"--backend", response.recordBackend]
    else:
      newSeq[cstring]()
  let selectedRecordTarget =
    if not response.filename.isNil and response.filename.len > 0:
      response.filename
    elif recordArgs.len > 0:
      recordArgs[0]
    else:
      cstring""
  # LRS-5 (b), one of the four sites.  Two different questions share this
  # branch and they are now asked of two different things:
  #
  # * with a recording open, "does THIS recording replay from a materialized
  #   container?" — `Trace.approach`, the per-recording fact;
  # * with none, "would a recording of this TARGET be materialized?" — the
  #   target's filename, which is all there is, and the `Lang` summary is the
  #   right tool for it.
  #
  # Before this milestone both went through `usesMaterializedTraces(Lang)`,
  # and the first one was answerable for Rust and C++ only because
  # `LangRustWasm` / `LangCppWasm` existed.
  let selectedUsesMaterialized =
    if not data.trace.isNil:
      data.trace.usesMaterializedTraces
    else:
      toLangFromFilename(selectedRecordTarget).usesMaterializedTraces
  if not selectedUsesMaterialized and
      not isExecutableFile(selectedRecordTarget):
    var buildArg = if selectedRecordTarget.len > 0:
        selectedRecordTarget
      elif data.trace.isNil:
        cstring""
      else:
        let (rawTracePaths, err) = await fsReadFileWithErr(nodePath.join(data.trace.outputFolder, cstring"paths.json"))
        if not err.isNil:
          cstring""
        else:
          let tracePaths = cast[seq[cstring]](JSON.parse(rawTracePaths))
          if tracePaths.len > 0:
            # TODO: add either entry/special source file, or current file as argument
            # and do that via the CTFS meta.dat / sqlite trace index, or by
            # giving the first entry in `paths` (the runtime-materialized
            # mirror of CTFS `paths.json`) a special status.
            # For now just assume the first path is useful for this goal.
            tracePaths[0]
          else:
            cstring""

    if buildArg.len == 0:
      errorPrint "index: build: can't find a filename or project to build: stopping"
      # should be working, but there was a problem: TODO maybe debug more
      # but ther other `failed-record` also works here for errors indeed, i noticed it later
      # sendNewNotification(NotificationKind.NotificationError, "index: build: can't find a filename to build: stopping")
      mainWindow.webContents.send "CODETRACER::failed-record", forLoadTab(js{errorMessage: cstring"index: build: can't find a filename or project to build: stopping"})
      return

    if response.projectOnly:
      buildArg = cstring(($buildArg).parentDir)
      # for now `ct build` => `ct-native-replay build` tries just use project logic when passed a folder and
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
        if recordArgs.len == 0 or recordArgs[0] != binary:
          recordArgs = @[binary] # assume other args from original trace might be unrelated
    else:
      errorPrint "index: build error: ", buildProcessResult.error
      # sendNewNotification(NotificationKind.NotificationError, "index: build error: " & $JSON.stringify(buildProcessResult.error))
      mainWindow.webContents.send "CODETRACER::failed-record", forLoadTab(js{errorMessage: cstring("index: build error: " & $JSON.stringify(buildProcessResult.error))})
      return
  elif recordArgs.len == 0 and selectedRecordTarget.len > 0:
    recordArgs = @[selectedRecordTarget]

  if response.recordBackend == cstring"mcr":
    let liveLaunch = liveProgramArgs(response.filename, recordArgs)
    let liveCwd = optionCwd(response.options)
    let resolvedProgram = resolveLiveProgramPath(liveLaunch.program, liveCwd)
    if resolvedProgram.len > 0 and isExecutableFile(resolvedProgram):
      let liveTrace = newLiveTrace(
        resolvedProgram,
        liveLaunch.args,
        liveCwd,
        liveLaunch.outputFolder)
      if not ensureDirectory(liveTrace.outputFolder):
        mainWindow.webContents.send "CODETRACER::failed-record",
          forLoadTab(js{errorMessage: cstring"failed to create live recording directory"})
        return
      sendNotification(NotificationKind.NotificationInfo, "starting live native session")
      await prepareForLiveTrace(
        liveTrace,
        resolvedProgram,
        liveLaunch.args,
        liveTrace.workdir,
        liveTrace.outputFolder,
        nodeProcess.pid.to(int))
      return

  let finalRecordArgs = recordBackendArgs.concat(recordArgs)
  infoPrint "index: record with args: ", finalRecordArgs
  # Issue #747.  Everything `spawn` can answer `ENOENT` for is asked about here,
  # by name, while there is still something to say about it.
  if not checkRecordLaunch(
      codetracerExe, recordTargetOf(recordArgs), response.options):
    return
  let processResult = await startProcess(
    codetracerExe,
    @[cstring"record"].concat(finalRecordArgs),
    response.options)

  if processResult.isOk:
    infoPrint "index: record process started with pid " & $processResult.value.pid
    sendNotification(NotificationKind.NotificationInfo, "ct record process started")
    data.recordProcess = processResult.value
    let error = await waitProcessResult(processResult.value)

    # Only the process that still owns the slot may report on it, and it
    # releases the slot as it does.  The old guard was `not
    # data.recordProcess.isNil`, which is true for *any* live recording — so a
    # process that had already been superseded reported its own failure
    # against its successor, and nothing ever cleared the slot (issue #603).
    let ownsSlot = not data.recordProcess.isNil and
      data.recordProcess.pid == processResult.value.pid
    if ownsSlot:
      data.recordProcess = nil

    if error.isNil:
      infoPrint "index: recorded successfully"
      mainWindow.webContents.send "CODETRACER::successful-record", forLoadTab(js{})
      await onLoadTraceByRecordProcessId(nil, processResult.value.pid)
    else:
      errorPrint "record error: ", error
      if ownsSlot:
        mainWindow.webContents.send "CODETRACER::failed-record",
          forLoadTab(js{errorMessage: cstring"codetracer record command failed"})

  else:
    errorPrint "record start process error: ", processResult.error
    let errorSpecificText = if not processResult.error.isNil: cast[cstring](processResult.error.code) else: cstring""
    let errorText = cstring"record start process error: " & errorSpecificText
    mainWindow.webContents.send "CODETRACER::failed-record",
      forLoadTab(js{errorMessage: errorText})

proc restartDbBackend {.async.} =
  # copied and adapted from Petar's code for re-recording + re-replaying up in this file
  #   or at least based on it/reusing its helpers completely
  #   it's almost the same, but we're not re-recording,
  #   just re-replaying the same trace and restarting
  #   db-backend with it
  #   and in the frontend we don't delete/reinit the layout in this case
  #   based on `data.lastRestartKind`, so the update is more invisible
  #   as it might happend automatically e.g. on problem/hanging in the future
  #
  #   we assume that run to entry complete move would lead to reloading the local panels:
  #     editor/state/flow
  #   and the global ones are ok staying the same as its the same trace:
  #     calltrace/event log/tracpoints

  await prepareForLoadingTrace(data.trace.recordingId, nodeProcess.pid.to(int))
  await loadExistingRecord(data.trace.recordingId)

proc onRestartSubsystem*(sender: JsObject, name: cstring) {.async.} =
  if name == "replay-server" or name == "db-backend":
    # sends notice to frontend client, when available
    #   and it sends back ct/restore, with the last location and breakpoints?
    await restartDbBackend()

proc jsLocalTimeText(): cstring {.importjs: "new Date().toLocaleTimeString()".}
  ## When the recording was made, in the reader's own clock. Stamped here
  ## rather than in the renderer because this is the process that watched
  ## `ct record-test` finish.

proc sendTestRunSettled(recordingId: cstring; errorMessage: cstring;
                        tab: JsObject) =
  ## TELL THE RENDERER THE RUN IS OVER, however it ended.
  ##
  ## `GUI/Core-Panes/Test-Results-Pane.md` §5. `onRunTest` has five exits and
  ## before this every one of them was silent as far as the Test Results pane
  ## and the editor's Run-test button were concerned: the button spun until its
  ## own two-minute deadline and the pane never moved (issue #748). The failure
  ## exits are the ones that matter most, because they are the ones a user
  ## meets — a run that succeeds at least replaces the window with the
  ## recording.
  ##
  ## NOT `CODETRACER::failed-record`, which carries no success arm at all and
  ## which every recording and build failure in this file also sends —
  ## `checkRecordLaunch`, `onStopRecordingProcess`, `onRecordWithLaunchConfig`
  ## and `onNewRecord` between them. A settle keyed on it would fire for
  ## re-records that have nothing to do with a test, and would still leave
  ## every successful run unsettled.
  # `tab`: the Test Results pane of the tab that started the run
  # (`tab_answers`).
  mainWindow.webContents.send "CODETRACER::test-run-settled", withTab(js{
    recordingId: recordingId,
    recordedAt: (if recordingId.len > 0: jsLocalTimeText() else: cstring""),
    errorMessage: errorMessage
  }, tab)

proc onRunTest*(sender: JsObject, response: RunTestOptions) {.async.} =
  infoPrint "index: run test: ", response[]
  # The run, and the recording it loads, answer the tab that asked.
  let tab = askingTab(response.toJs)
  startLoadFor(response.toJs)

  # SETTLED EXACTLY ONCE, ON EVERY PATH — including the ones that are not a
  # return value. `GUI/Core-Panes/Test-Results-Pane.md` §5 named the residual:
  # a rejected `await` before the hoisted settle below (`findTraceWithCodetracer`
  # was the one) escaped this `async` proc, rejected its future, reached no
  # handler and settled nothing — the renderer's raising-dispatch defect, on
  # this side of the IPC. The rule is `settle_once.settleGuarded`, which a
  # JS-backend test asserts (`src/frontend/tests/settle_once_test.nim`): the
  # handler below runs under it, a rejection or raise before anything was
  # sent is answered with a sentence, and the recording load AFTER the hoisted
  # send can fail without a second message contradicting the first.
  let once = newSettleOnce()
  proc settle(recordingId: cstring; errorMessage: cstring) =
    if once.claim():
      sendTestRunSettled(recordingId, errorMessage, tab)

  proc handle(once: SettleOnce): Future[void] {.async.} =
    let pid = nodeProcess.pid.to(int)
    # `readProcessOutcome`, not `readProcessOutput`: the latter turns a
    # non-zero exit into "Exit with code <n>" and DISCARDS what the recorder
    # printed, which is where `ct record-test` states its reason (for a
    # language it has no test route for: "currently `ct record-test` not
    # supported for this db-based language"; for a Noir test nargo cannot
    # find: "`<name>` does not match with any test function"). Never rejects,
    # so its outcome is one value to branch on.
    let outcome = await readProcessOutcome(
      codetracerExe,
      @[cstring"record-test"].concat(
          @[
            response.testName,
            response.path,
            cstring($response.line),
            cstring($response.column),
            # TODO: maybe diff passed by frontend or constructed here?
            cstring(fmt"--with-diff=HEAD"),
            # TODO: maybe session id or other
            cstring(fmt"--store-trace-folder-for-pid={pid}")
            ])
    )
    if outcome.spawnError.len == 0 and outcome.signal.len == 0 and
       outcome.exitCode == 0:
      let output = outcome.stdout
      echo output
      # `recordingIdFromOutput` scans for the last `recordingId:` line rather
      # than reading a fixed index: `ct record-test` echoes the recorder's
      # output, whose marker can be followed by the traced program's own
      # output, and the old `lines[^3]` read both missed that and, behind a
      # short guard, raised an `IndexDefect` out of this `async` proc.
      let traceId = cstring(recordingIdFromOutput($output))
      if traceId.len > 0:
        infoPrint "index: traceId for test: ", traceId
        let trace = await electron_vars.app.findTraceWithCodetracer(traceId)
        if trace.isNil:
          errorPrint "index: run-test: can't find trace"
          settle(cstring"", cstring(
            "ct record-test reported recording " & $traceId &
            ", but CodeTracer cannot find it. Nothing about the test has " &
            "been established."))
          return
        infoPrint "trace is in ", trace.outputFolder

        # SETTLED BEFORE THE TRACE IS LOADED, and the order is deliberate. The
        # run is over the moment the recorder answered; loading the recording
        # is the next operation, it can take seconds, and on the
        # `newWindow` arm it happens in a different process entirely.
        # Settling afterwards would leave the button spinning across the
        # load, and would never settle at all if the load failed.
        settle(traceId, cstring"")

        if response.keepWindow:
          # THE ROW'S `⟳`: record and STAY. The recording now exists and the
          # renderer has its id (the settle above); entering it is what the
          # row's `⏵` does later, through `CODETRACER::load-recent-trace`,
          # without running anything. Loading it here would replace the very
          # pane the user asked to stay in.
          infoPrint "index: run-test: recorded, keeping the window"
        elif response.newWindow:
          infoPrint "new window"
          discard startProcess(codetracerExe,
            @[cstring"replay", cstring(fmt"--id={traceId}")],
            options=JsObject{stdio: cstring"inherit"}
          )
        else:
          infoPrint "existing window"
          await prepareForLoadingTrace(traceId, nodeProcess.pid.to(int))

          await loadExistingRecord(traceId)

        return
      warnPrint "index: run-test: traced ok, but couldn't extract traceId"
      # EXIT 0 AND NO `recordingId:` LINE. `ct record-test` prints the marker
      # on every route that produced a recording, so this is a recorder that
      # answered in a shape this build does not understand — which is a
      # fault, and a fault the pane has to state rather than absorb.
      settle(cstring"", cstring(
        "ct record-test finished without reporting a recording id, so there " &
        "is nothing to replay. Its output is in the CodeTracer log."))
    else:
      # THE RECORDER'S OWN WORDS, under the same `ct record-test error:` stem
      # (`recorder_output.recordTestFailureSentence`, pure and unit-tested).
      let errorText = cstring(recordTestFailureSentence(
        outcome.exitCode, $outcome.signal, $outcome.stdout, $outcome.stderr,
        $outcome.spawnError))
      errorPrint "index: ", errorText
      if outcome.stdout.len > 0:
        echo outcome.stdout
      # BOTH MESSAGES, and they are not redundant. `failed-record` is the
      # re-record latch's release and the new-record form's error line;
      # `test-run-settled` is what ends the RUN — the pane's `endRun` and the
      # editor's spinner. Before this the failure arm sent only the first,
      # which the Test Results pane does not subscribe to, so a failed run
      # left the button turning for two minutes under a message saying it had
      # started. That is the reported defect in its most-travelled form.
      mainWindow.webContents.send "CODETRACER::failed-record", forLoadTab(js{errorMessage: errorText})
      settle(cstring"", errorText)

  let settleFailure = proc(detail: string) =
    errorPrint "index: run-test: ", detail
    sendTestRunSettled(cstring"", cstring(
      "CodeTracer could not finish handling ct record-test's answer: " & detail),
      tab)
  let loadFailedAfterSettle = proc(detail: string) =
    # The run had already been settled — this is the recording LOAD that
    # follows it failing. The renderer has been told how the run ended; the
    # load failure is logged rather than reported as a second, contradictory
    # end of the same run.
    errorPrint "index: run-test: loading the recording failed: ", detail
  await settleGuarded(once, handle, settleFailure, loadFailedAfterSettle)

# ---------------------------------------------------------------------------
# THE WHOLE-SUITE RUN — the desktop Test Results pane's header ▶
#
# `GUI/Core-Panes/Test-Results-Pane.md` §4.3. The renderer's desktop host
# (`viewmodel/viewmodels/desktop_test_host.nim`) sends
# `CODETRACER::run-test-suite` with the project folder; this runs `ct test run
# --workspace <folder> --events <file>` — which `ct` hands to the ORC-built
# `ct-test` installed beside it (`src/ct_test/ct_test_delegate.nim`) — and
# answers with `CODETRACER::test-suite-settled` on EVERY exit.
#
# Deliberately thin. Every decision about what the answer MEANS — which exit
# code is a failed run, which stream is unreadable, what the pane says — is
# the host's `settleDesktopSuiteRun`, which a headless suite asserts
# (`test_desktop_suite_run_gives_verdicts.nim`). This side only runs the
# process and reports what it saw.
# ---------------------------------------------------------------------------

var testSuiteRunCounter = 0
  ## Names each run's events file, together with this process's pid, so two
  ## windows (or two quick runs) can never read each other's file.

proc nowMs(): float {.importjs: "Date.now()".}

proc removeFileQuietly(path: cstring) {.importjs:
  "(function(p){ try { require('fs').unlinkSync(p); } catch (e) {} })(#)".}
  ## The events file is this process's own scratch, read once; a file that is
  ## already gone is not an error worth reporting.

proc makeDirRecursive(path: cstring) {.importjs:
  "require('fs').mkdirSync(#, {recursive: true})".}

proc sendTestSuiteSettled(events: cstring; exitCode: int;
                          stderrText: cstring; errorMessage: cstring;
                          tab: JsObject) =
  ## TELL THE RENDERER THE SUITE RUN IS OVER, however it ended.
  ##
  ## `events` is what `ct-test --events` wrote (JSON Lines; "" when there is
  ## none), `exitCode` its exit status (-1 when it never reached one), `stderr`
  ## its stderr — where `ct-test` states its verdict and the reason for it —
  ## and `errorMessage` this process's sentence when the run could not be
  ## started or its answer could not be collected. A message of its own, not
  ## `test-run-settled`: see `DesktopRunKind` for why a settle of one runner
  ## must not end a run of the other.
  # `tab`: the tab whose Test Results pane started the run (`tab_answers`).
  mainWindow.webContents.send "CODETRACER::test-suite-settled", withTab(js{
    events: events,
    exitCode: exitCode,
    stderr: stderrText,
    errorMessage: errorMessage
  }, tab)

proc onRunTestSuite*(sender: JsObject,
                     response: jsobject(workspaceRoot=cstring)) {.async.} =
  # SETTLED EXACTLY ONCE, ON EVERY PATH — `onRunTest`'s rule, and for its
  # reason: an exception escaping this `async` proc would settle nothing and
  # leave the pane on "running…" for ever. Asserted through
  # `settle_once.settleGuarded` (`src/frontend/tests/settle_once_test.nim`).
  let once = newSettleOnce()
  let tab = askingTab(response.toJs)
  proc settle(events: cstring; exitCode: int; stderrText: cstring;
              errorMessage: cstring) =
    if once.claim():
      sendTestSuiteSettled(events, exitCode, stderrText, errorMessage, tab)

  var eventsPath = cstring""
  proc handle(once: SettleOnce): Future[void] {.async.} =
    let root = if response.workspaceRoot.isNil: "" else: $response.workspaceRoot
    if root.len == 0:
      # The renderer refuses before sending this (`DesktopNoProjectText`);
      # answered anyway, because a message that settles nothing is the defect.
      settle(cstring"", -1, cstring"",
             cstring"ct test run was asked to run with no project folder.")
      return

    # UNDER THE CODETRACER TMP DIR, which `CODETRACER_HOME` relocates, so a
    # test harness's scratch home keeps these files out of the user's own.
    let dir = codetracerTmpPath / "test-suite-runs"
    makeDirRecursive(cstring(dir))
    inc testSuiteRunCounter
    eventsPath = cstring(dir / ($nodeProcess.pid.to(int) & "-" &
                                $testSuiteRunCounter & "-" &
                                $int64(nowMs()) & ".jsonl"))
    infoPrint "index: run-test-suite: ct test run --workspace ", root,
              " --events ", $eventsPath

    let outcome = await readProcessOutcome(
      codetracerExe,
      @[cstring"test", cstring"run", cstring"--workspace", cstring(root),
        cstring"--events", eventsPath])

    if outcome.spawnError.len > 0:
      settle(cstring"", -1, outcome.stderr,
             cstring"ct test run could not be started: " & outcome.spawnError)
      return

    # The events file is read whatever the exit status: a failing suite (exit
    # 1) is exactly when the per-test answer matters. Absent means the runner
    # wrote none — an argument error, or a `ct` that found no `ct-test` — and
    # the host says so from the exit status and stderr.
    var events = cstring""
    if fs.existsSync(eventsPath):
      events = fs.readFileSync(eventsPath, cstring"utf8")
    let signalSentence =
      if outcome.signal.len > 0:
        cstring"ct test run was ended by signal " & outcome.signal
      else:
        cstring""
    infoPrint "index: run-test-suite: exit ", $outcome.exitCode,
              " events bytes ", $events.len
    settle(events, outcome.exitCode, outcome.stderr, signalSentence)

  let settleFailure = proc(detail: string) =
    errorPrint "index: run-test-suite: ", detail
    sendTestSuiteSettled(cstring"", -1, cstring"", cstring(
      "CodeTracer could not run ct test run: " & detail), tab)
  try:
    await settleGuarded(once, handle, settleFailure)
  finally:
    if eventsPath.len > 0:
      removeFileQuietly(eventsPath)
