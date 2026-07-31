import std/[ os, osproc, strutils, strformat, sequtils, json ],
  json_serialization,
  uuid4,
  ../common/[ lang, paths, types, trace_index ],
  utilities/[ env, language_detection, zip ],
  cli/[ logging, help ],
  globals,
  trace/storage_and_import,
  trace/recorder_dispatch,
  trace/shell


proc recordSymbols(sourceDir: string, outputFolder: string, lang: Lang) =
  var ctagsArgs = @[
    "--exclude=.git",
    "-R", # Recurse subdirectories
    "--output-format=json",
    "--fields=NFnK", # Get name, file, line and kind,
    "--kinds-all=*" # Get all possible tags
  ]

  if lang == LangNoir:
    # TODO: for now we will use Rust parser (there isn't one for Noir)
    ctagsArgs.add("--langmap=Rust:.nr")
    ctagsArgs.add("--languages=Rust")

  try:
    var correctSourceDir = sourceDir
    if sourceDir.endsWith(".nr") and fileExists(sourceDir):
      while not fileExists(correctSourceDir / "Nargo.toml"):
        if correctSourceDir == "":
          raise newException(CatchableError, "Can't find \"Nargo.toml\"")

        correctSourceDir = parentDir(correctSourceDir)

    ctagsArgs.add(correctSourceDir)

    let data = execProcess(ctagsExe, workingDir=correctSourceDir, args=ctagsArgs, options={poUsePath})
    var symbols: seq[Symbol] = @[]

    for line in data.split('\n'):
      if line.len != 0:
        symbols.add(line.parseJson.to(Symbol))

    if not dirExists outputFolder:
      createDir outputFolder

    writeFile(outputFolder / "symbols.json", $(%* symbols))

  except:
    echo getCurrentExceptionMsg()
    echo ""
    echo "WARNING: Can't extract symbols. Some functionality may not work correctly!"
    echo ""

proc recordWithCtRrSupport(
    ctRRSupportExe: string,
    program: string, args: seq[string],
    traceFolder: string,
    # M-REC-3: UUIDv7 recording-id string; empty == NO_RECORDING_ID.
    recordingId: string,
    traceKind: string,
    nativeBackend: string = ""): Trace =

  createDir(traceFolder)
  let outputArg =
    if nativeBackend == "mcr":
      traceFolder / "trace"
    else:
      traceFolder
  var recordArgs = @["record"]
  if nativeBackend.len > 0:
    recordArgs = recordArgs.concat(@["--backend", nativeBackend])
  recordArgs = recordArgs.concat(@["-o", outputArg, program]).concat(args)
  let process = startProcess(
    ctRRSupportExe,
    args = recordArgs,
    options = {poEchoCmd, poParentStreams}
  )
  let code = waitForExit(process)
  if code != 0:
    echo fmt"error: ct-native-replay returned exit code ", code
    quit(code)

  # import replay trace metadata written by ct-native-replay.
  result = importTrace(traceFolder, recordingId, NO_PID, LangUnknown, DB_SELF_CONTAINED_DEFAULT, traceKind=traceKind)


proc recordNim(
    program: string, args: seq[string],
    traceFolder: string,
    # M-REC-3: UUIDv7 recording-id string; empty == NO_RECORDING_ID.
    recordingId: string): Trace =
  ## Record a Nim program.
  ##
  ## Two flows, dispatched on the source extension:
  ##
  ## * ``.nims`` — evaluated with ``nim e --trace:<traceFolder>/trace.ct
  ##   <program>``.  The M-nim tracer (codetracer-nim,
  ##   ``feature/M-nim-column-aware``) emits a CTFS-format ``.ct`` container
  ##   straight into the trace folder, which importTrace then ingests.
  ##
  ## * ``.nim`` (default) — first compiled to a native binary with
  ##   ``nim c -o:<binary> <program>`` into the trace folder, then recorded
  ##   with the MCR ``ct-mcr record`` tool.  MCR writes a ``trace.ct``
  ##   container next to the binary, again consumable by importTrace.
  ##
  ## The temp compile step is the simplest plausible bridge — it intentionally
  ## does not handle multi-file Nim projects with ``.nimble`` manifests or
  ## custom ``config.nims``.  Those should land as follow-ups once the basic
  ## ``ct record example.nim`` flow is wired through.
  createDir(traceFolder)
  let ext = program.splitFile.ext.toLowerAscii

  if nimCompilerExe.len == 0:
    echo "error: Nim compiler not found. Set CODETRACER_NIM_EXE_PATH or ensure `nim` is on PATH."
    quit(1)

  if ext == ".nims":
    # ``nim e`` invokes the script VM (the same path the M-nim tracer
    # instruments).  ``--trace:<path>`` is gated by the optTraceVM global
    # option in the codetracer-nim fork; the resulting ``.ct`` container
    # ends up at ``<traceFolder>/trace.ct``.
    let traceOut = traceFolder / "trace.ct"
    var nimArgs = @[
      "e",
      "--trace:" & traceOut,
      program
    ]
    nimArgs = nimArgs.concat(args)
    let process = startProcess(
      nimCompilerExe,
      args = nimArgs,
      options = {poParentStreams})
    let recordPid = process.processId
    let exitCode = waitForExit(process)
    if exitCode != 0:
      echo fmt"error: nim e tracer exited with {exitCode} for {program}"
      quit(1)
    return importTrace(traceFolder, recordingId, recordPid, LangNim,
        DB_SELF_CONTAINED_DEFAULT, traceKind="db")

  # Default (``.nim`` and any other Nim-recognised extension we may add
  # later): compile to a native binary then hand off to MCR.
  if mcrRecorderExe.len == 0:
    echo "error: MCR (ct-mcr) not found. Set CODETRACER_CT_MCR_PATH or build " &
        "codetracer-native-recorder/ct_cli/ct_cli and add it to PATH."
    quit(1)

  let compiledName = program.splitFile.name
  let binaryPath = traceFolder / compiledName
  let compileArgs = @[
    "c",
    "--hints:off",
    "-d:release",
    "-o:" & binaryPath,
    program
  ]
  let compileProcess = startProcess(
    nimCompilerExe,
    args = compileArgs,
    options = {poEchoCmd, poParentStreams})
  let compileExit = waitForExit(compileProcess)
  if compileExit != 0:
    echo fmt"error: nim c exited with {compileExit} for {program}"
    quit(1)

  # MCR ``record -o <out.ct>`` produces a single CTFS container.  We point it
  # at ``<traceFolder>/trace.ct`` so importTrace's findCtFileInFolder picks
  # it up by the canonical name.
  let traceOut = traceFolder / "trace.ct"
  var recordArgs = @[
    "record",
    "-o", traceOut,
    "--",
    binaryPath
  ]
  recordArgs = recordArgs.concat(args)
  let process = startProcess(
    mcrRecorderExe,
    args = recordArgs,
    options = {poEchoCmd, poParentStreams})
  let recordPid = process.processId
  let exitCode = waitForExit(process)
  if exitCode != 0:
    echo fmt"error: ct-mcr record exited with {exitCode} for {binaryPath}"
    quit(1)
  result = importTrace(traceFolder, recordingId, recordPid, LangNim,
      DB_SELF_CONTAINED_DEFAULT, traceKind="db")


# rr patches for ruby/other vm-s: not supported now, instead
# in db backend support only direct traces

proc recordNativeServer(
    program: string, args: seq[string], traceFolder: string,
    recordingId: string): Trace =
  ## ``ct record --server`` for the native family.
  ##
  ## A native server has no middleware seam — nginx does not know what a
  ## CodeTracer request span is — so codetracer-native-recorder ships a
  ## separate supervisor, ``ct_server_record`` (installed as
  ## ``codetracer-native-recorder``), which drives ``ct-mcr`` for the
  ## long-running process, time-slices the result and then DISCOVERS the
  ## request spans from the recording's own syscall payloads.  That is the
  ## flow `just demo-request-panel native` runs by hand; this is the same
  ## flow behind the flag.
  if nativeServerRecorderExe.len == 0:
    errorMessage "error: the native server recorder `codetracer-native-recorder` " &
      "was not found, so `ct record --server` cannot record this program."
    errorMessage "help: set CODETRACER_NATIVE_SERVER_RECORDER_PATH=/path/to/it, or"
    errorMessage "help:   build it with `cd ../codetracer-native-recorder && just build`;"
    errorMessage "help:   it produces ct_server_record/codetracer-native-recorder."
    quit(1)

  createDir(traceFolder)
  for line in serverGuidance(LangC, traceFolder):
    echo "codetracer: " & line
  flushFile(stdout)

  let process = startProcess(
    nativeServerRecorderExe,
    args = @["--out-dir", traceFolder, "--", program].concat(args),
    workingDir = getCurrentDir(),
    options = {poParentStreams})
  let recordPid = process.processId
  let exitCode = waitForExit(process)
  # 130/143 are the shell conventions for SIGINT / SIGTERM, which is how a
  # server recording is normally stopped.
  if exitCode notin [0, 130, 143]:
    echo fmt"error: the native server recorder exited with {exitCode}"
    quit(1)

  importTrace(traceFolder, recordingId, recordPid, LangUnknown,
              DB_SELF_CONTAINED_DEFAULT, traceKind = "rr")

proc requireRecorder(lang: Lang) =
  ## Fail with a precise, actionable message when a language's recording
  ## toolchain is not installed — never fall through to a different backend
  ## and never spawn the empty string.
  ##
  ## Before this check the recorder path was resolved out of ``paths.nim``
  ## and passed straight to ``startProcess``.  When the lookup failed the exe
  ## was ``""``, ``startProcess`` raised, ``record``'s ``except
  ## CatchableError`` swallowed it, and ``ct`` registered a trace for a
  ## recording that never ran.  The Python arm in ``src/ct/trace/record.nim``
  ## already modelled the right behaviour (``checkPythonRecorder`` → "install
  ## it with …"); this brings every other language up to that bar, using the
  ## per-language remedy table in ``trace/recorder_dispatch.nim``.
  let missing = missingArtifacts(lang)
  let tool = recorderToolFor(lang)
  if tool.supported and missing.len == 0:
    return
  for line in missingRecorderMessage(lang, missing):
    errorMessage line
  quit(1)

proc recordDb(
    lang: Lang,
    program: string, args: seq[string],
    backend: string, traceFolder: string, stylusTrace: string,
    # M-REC-3: UUIDv7 recording-id string; empty == NO_RECORDING_ID.
    recordingId: string, pythonActivationPath: string = "",
    pythonTestFramework: string = "", pythonTestArgs: seq[string] = @[],
    server: bool = false): Trace =

  requireRecorder(lang)
  if lang == LangNoir and backend.len > 0 and backend != "plonky2":
    echo fmt"error: unsupported backend: {backend}"
    quit(1)

  createDir(traceFolder)
  # Materialized traces are CTFS-only; the recorders write a single
  # `<program>.ct` container into ``traceFolder`` directly, so we no longer
  # need to set CODETRACER_DB_TRACE_PATH (which used to point recorders at
  # the legacy ``trace.json`` sidecar).

  # The whole per-language argv/env table lives in trace/recorder_dispatch.nim
  # so it can be asserted by a test without recording anything.  See that
  # module's header for why it is not inlined here any more.
  let invocation = recorderInvocation(
    lang, program, traceFolder,
    RecorderOptions(
      backend: backend,
      stylusTrace: stylusTrace,
      pythonActivationPath: pythonActivationPath,
      pythonTestFramework: pythonTestFramework,
      pythonTestArgs: pythonTestArgs,
      server: server))

  if invocation.exe.len == 0:
    # Unreachable via ``requireRecorder`` above; kept as a hard stop so a
    # future language added to the Lang enum but not to the dispatch table
    # fails loudly instead of spawning "".
    errorMessage fmt"error: no recorder invocation is defined for {lang.toName}."
    errorMessage "help: add it to src/ct/trace/recorder_dispatch.nim."
    quit(1)

  if server:
    for line in serverGuidance(lang, traceFolder):
      echo "codetracer: " & line
    flushFile(stdout)

  for (name, value) in invocation.env:
    putEnv(name, value)

  let workdir = if invocation.workdir.len > 0: invocation.workdir
                else: getCurrentDir()

  let process = startProcess(
    invocation.exe,
    args = invocation.args.concat(args),
    workingDir = workdir,
    options = {poParentStreams}) # add poEchoCmd if you want to debug and see how the cmd might look
  let recordPid = process.processId
  let exitCode = waitForExit(process)
  if exitCode != 0:
    # A recorded SERVER is normally stopped with Ctrl-C or SIGTERM, so the
    # shell-convention exit codes for those (128 + SIGINT / 128 + SIGTERM)
    # are how a successful `ct record --server` ends.  Treating them as
    # failures would make the flag unusable.
    const SignalStopCodes = [130, 143]
    if not (server and exitCode in SignalStopCodes):
      echo fmt"error: recorder exited with {exitCode} for {lang}"
      quit(1)

  result = importTrace(traceFolder, recordingId, recordPid, lang, DB_SELF_CONTAINED_DEFAULT, traceKind="db")


# record a program run
proc record(
    cmd: string, args: seq[string], compileCommand: string,
    langArg: Lang, backend: string, stylusTrace: string,
    test = false, basic = false,
    # M-REC-2: ``traceIDRecord`` is now a UUIDv7 recording-id string;
    # empty (``""`` == NO_RECORDING_ID) means "mint a fresh one".
    traceIDRecord: string = NO_RECORDING_ID, customPath: string = "", outputFolderArg: string = "",
    traceKind: string = "db", rrSupportPath: string = "",
    pythonInterpreter: string = "", pythonActivationPath: string = "", pythonWithDiff: bool = false,
    pythonTestFramework: string = "", pythonTestArgs: seq[string] = @[],
    server: bool = false): Trace =
  var traceID: string
  if traceIDRecord == NO_RECORDING_ID:
    traceID = trace_index.newID(test)
  else:
    traceID = traceIDRecord

  # if we are using the ct_wrapper.nim as in the tup dev build,
  # we need to use its pid as a record pid(which it puts in this env var),
  # because that's what index.nim sees
  # as the pid of the called process
  # otherwise this should be the directly called process, so we use `getCurrentProcessId`
  let recordPid = getEnv("CODETRACER_WRAPPER_PID", $(getCurrentProcessId())).parseInt
  trace_index.registerRecordingForPid(recordPid, traceID, test)

  let codetracerDir = if not test: codetracerShareFolder
                      elif customPath.len > 0: customPath
                      else: &"{codetracerTestDir}/records/"
  # M-REC-7: folder name is the bare ``recording_id`` (UUIDv7) — see paths.recordingFolder.
  let outputFolder = if outputFolderArg.len == 0: recordingFolder(codetracerDir, traceID) else: outputFolderArg
  let env = readRawEnv()
  let argsShell = args.join " "
  var shellCmd = cmd & " " & argsShell
  let shellArgs = @[cmd].concat(args)

  # For pytest/unittest mode, cmd might be empty since args are passed via pythonTestArgs
  var executable: string
  if pythonTestFramework.len > 0 and cmd.len == 0:
    # Test framework mode - use pytest/unittest as the "executable" for metadata
    executable = pythonTestFramework
  else:
    executable = cmd.split(" ", 1)[0]
    try:
      executable = expandFilename(expandTilde(executable))
    except OsError:
      let foundExe = findExe(executable)
      if foundExe == "":
        errorMessage fmt"Can't find {executable}"
        quit(1)
      else:
        executable = foundExe

  # For test framework mode, use the explicitly set langArg
  let lang = if pythonTestFramework.len > 0: langArg else: detectLang(executable, langArg)
  # echo "in db ", lang, " ", executable
  if lang == LangUnknown:
    if traceKind == "db":
      errorMessage fmt"error: lang unknown: probably an unsupported type of project/extension, or folder/path doesn't exist?"
      quit(1)
  elif not lang.usesMaterializedTraces:
    # TODO integrate with rr/gdb backend
    if traceKind == "db":
      errorMessage fmt"error: {lang} not supported currently with db: maybe you need a rr trace for it?"
      quit(1)

  # Every arm below either returns a Trace or quits: the recorders themselves
  # register the recording (``importTrace``), so there is no longer a
  # fall-through ``trace_index.recordTrace`` tail here.  That tail used to be
  # reached only when the ``except`` swallowed a recorder failure, which is
  # exactly the silent-success bug this dispatch rework removes; with the
  # except now fatal, the locals it consumed (exitCode / calltrace /
  # sourceFolders / shellID / calltraceMode / traceDir / env) are dead too.

  if server and serverSupport(lang) == ssUnsupported:
    for line in serverUnsupportedMessage(lang):
      errorMessage line
    quit(1)

  try:
    if lang in {LangNoir, LangRustWasm, LangCppWasm}:
      if lang == LangNoir:
        # TODO: base the first arg: source folder for record symbols on
        #   debuginfo or the CTFS meta.dat paths block
        # for noir for now "executable" is the noir folder
        recordSymbols(executable, outputFolder, lang)
      return recordDb(lang, executable, args, backend, outputFolder,
                      stylusTrace, traceId, server = server)
    elif lang == LangNim:
      # ``.nim`` / ``.nims`` files dispatch into recordNim, which decides
      # between the MCR native-binary flow and the M-nim VM tracer based on
      # the source extension.  See src/ct/db_backend_record.nim:recordNim.
      requireRecorder(LangNim)
      return recordNim(executable, args, outputFolder, traceId)
    elif lang == LangPythonDb:
      var activationPathResolved = pythonActivationPath
      if activationPathResolved.len > 0:
        try:
          activationPathResolved = expandFilename(expandTilde(activationPathResolved))
        except OsError:
          discard

      return recordDb(
        LangPythonDb,
        executable,
        args,
        backend,
        outputFolder,
        stylusTrace,
        traceId,
        pythonActivationPath = activationPathResolved,
        pythonTestFramework = pythonTestFramework,
        pythonTestArgs = pythonTestArgs,
        server = server)
    elif recorderToolFor(lang).supported:
      # Every remaining materialized-trace language goes through the one
      # dispatch table in trace/recorder_dispatch.nim: Ruby, JavaScript, PHP,
      # Elixir, Erlang, bash, zsh and the twelve blockchain / VM recorders.
      # PHP, Elixir and Erlang had no arm here at all before this change even
      # though language detection produced them and they are marked
      # ``usesMaterializedTraces``, so `ct record app.php` fell through to
      # "ERROR: unsupported trace kind db" and exited 0.
      return recordDb(lang, executable, args, backend, outputFolder,
                      stylusTrace, traceId, server = server)
    elif traceKind == "rr" or traceKind == "ttd":
      if server:
        return recordNativeServer(executable, args, outputFolder, traceId)
      return recordWithCtRrSupport(
        rrSupportPath,
        executable,
        args,
        outputFolder,
        traceId,
        traceKind,
        backend)
    else:
      # ``lang`` is a language CodeTracer knows about but has no recorder
      # for (or an explicitly-requested retired backend such as
      # ``--lang ruby``).  Say which one and what to do instead, rather than
      # blaming the trace kind — "ERROR: unsupported trace kind db" was the
      # message `ct record app.php` used to print, and it named neither the
      # language nor a remedy.
      for line in missingRecorderMessage(lang, missingArtifacts(lang)):
        errorMessage line
      quit(1)
  except CatchableError as recordError:
    # Never fall through to ``recordTrace`` on an exception: that registered a
    # trace for a recording that never happened, and `ct record` then printed
    # a recordingId and exited 0.  Surface the failure instead.
    errorMessage fmt"error: recording {lang.toName} program '{executable}' failed: {recordError.msg}"
    quit(1)

proc exportRecord(
    program: string,
    recordArgs: seq[string],
    # M-REC-3: UUIDv7 recording-id string.
    recordingId: string,
    exportZipPath: string,
    outputFolder: string,
    cleanupOutputFolder: bool) =
  # M-REC-1.5: the legacy trace_db_metadata.json sidecar that used to be
  # bundled into the export zip is gone — the CTFS container's meta.dat
  # is the single source of trace metadata.  Online sharing protocol
  # adjustments (M-REC-8) consume the metadata from the container.
  #
  # outputFolder/
  #   < original files >
  #   trace.ct  (carries meta.dat with recording_id + program + args + workdir)
  #
  # -> zip -> <exportZipPath>
  discard recordingId

  # (alexander):
  #   trying to find full path
  #   a hack: writing first there, otherwise i think expandFilename fails in some cases, when no such file yets
  writeFile(exportZipPath, "")
  let exportZipFullPath = expandFilename(expandTilde(exportZipPath))
  # otherwise zip seems to try to add to it and because it's not a valid archive, it leads to an error
  removeFile(exportZipPath)

  # zip -r <exportZipPath> . # in <outputFolder>
  # changing directory, so we have relative paths
  try:
    zip.zipFolder(outputFolder, exportZipFullPath)
    # echo "OK"
  # let process = startProcess(zipExe, workingDir=outputFolder, args = @["-r", exportZipFullPath, "."], options={poParentStreams})
  # let code = waitForExit(process)
  except Exception as e:
    echo "error: ", e.msg, " while trying to zip: maybe archive is not created"
    quit(1)
  finally:
    if cleanupOutputFolder:
      # in both cases: success or error
      # echo "cleanup output folder: ", outputFolder
      removeDir outputFolder


proc main*(): Trace =
  # record
  #   [--lang <lang>] [-o/--output-folder <output-folder>]
  #   [--backend <backend>]
  #   [-e/--export <export-zip>] [-c/--cleanup-output-folder]
  #   [-t/--stylus-trace <trace-path>]
  #   [-a/--address <address>] [--socket <socket-path>]
  #   [--trace-kind db/rr/ttd] [--rr-support-path <rr-support-path>]
  #   <program> [<args>]
  let args = os.commandLineParams()
  if args.len == 0:
    displayHelp()
    return
  var program = ""
  var recordArgs: seq[string]
  var outputFolder = ""
  #var recordArgsIndex = -1
  # M-REC-2: ``traceID`` is now a UUIDv7 recording-id string.
  # Empty means "to be assigned" (newID() is called below).
  var traceID: string = ""
  var lang: Lang = LangUnknown

  var isExported = false
  var cleanupOutputFolder = false
  var exportZipPath = ""
  var backend = ""
  var stylusTrace = ""
  var address = ""
  var socketPath = ""
  var isExportedWithArg = false
  var pythonInterpreter = ""
  var traceKind = "db" # by default
  var rrSupportPath = ""
  var server = false
  var pythonTestFramework = ""
  var pythonTestArgs: seq[string] = @[]

  echo args

  # for i, arg in args:
  var i = 0
  while i < args.len:
    var arg = args[i]
    if arg == "-o" or arg == "--output-folder":
      if args.len < i + 2:
        displayHelp()
        return
      createDir args[i + 1]
      outputFolder = expandFilename(expandTilde(args[i + 1]))
      i += 2
    elif arg == "-e" or arg == "--export":
      isExportedWithArg = true
      isExported = true
      if args.len < i + 2:
        displayHelp()
        return
      exportZipPath = args[i + 1]
      i += 2
    elif arg == "-c" or arg == "--cleanup-output-folder":
      cleanupOutputFolder = true
      i += 1
    elif arg == "--server":
      # `ct record --server`: the recorded program is a long-lived server.
      # See trace/recorder_dispatch.nim's ServerSupport for what this changes
      # per language.
      server = true
      i += 1
    elif arg == "--lang":
      if args.len < i + 2:
        displayHelp()
        return
      lang = toLang(args[i + 1])
      i += 2
    elif arg == "--backend":
      if args.len() < i + 2:
        displayHelp()
        return
      backend = args[i + 1]
      i += 2
    elif arg == "--stylus-trace" or arg == "-t":
      if args.len() < i + 2:
        displayHelp()
        return
      stylusTrace = args[i + 1]
      i += 2
    elif arg == "--python-interpreter":
      if args.len() < i + 2:
        displayHelp()
        return
      pythonInterpreter = args[i + 1]
      i += 2
    elif arg == "--address" or arg == "-a":
      if args.len() < i + 2:
        displayHelp()
        return
      address = args[i + 1]
      i += 2
    elif arg == "--socket":
      if args.len() < i + 2:
        displayHelp()
        return
      socketPath = args[i + 1]
      i += 2
    elif arg == "--trace-kind":
      if args.len() < i + 2:
        displayHelp()
        return
      traceKind = args[i + 1]
      i += 2
    elif arg == "--rr-support-path":
      if args.len() < i + 2:
        displayHelp()
        return
      rrSupportPath = args[i + 1]
      i += 2
    elif arg == "--pytest":
      # Collect all remaining args as pytest arguments
      pythonTestFramework = "pytest"
      lang = LangPythonDb
      i += 1
      while i < args.len:
        pythonTestArgs.add(args[i])
        i += 1
    elif arg == "--unittest":
      # Collect all remaining args as unittest arguments
      pythonTestFramework = "unittest"
      lang = LangPythonDb
      i += 1
      while i < args.len:
        pythonTestArgs.add(args[i])
        i += 1
    else:
      if program == "":
        program = arg
      else:
        recordArgs.add(arg)
        # recordArgsIndex = 1
      i += 1
      # outputFolder = ""

  # for i in recordArgsIndex ..< args.len:
    # recordArgs.add(args[i])

  traceID = trace_index.newID(test=false)

  # if '.' in program:
  #   var programBinary = ""
  #   if program[0] != '.':
  #     programBinary = rsplit(program, ".", 1)[0]
  #   else:
  #     if '.' in program[1..^1]:
  #       programBinary = "." & rsplit(program[1..^1], ".", 1)[0]
  #   if programBinary.len > 0:
  #     discard runCompiler(
  #       args[0], programBinary, calltrace=true,
  #       traceID=traceID, test=false)


  let command = args.join(" ")
  putEnv("CODETRACER_RECORDING", "1")
  let sessionId = loadSessionId()
  let sessionLogPath = scriptSessionLogPath(sessionId)
  let reportFile = getEnv("CODETRACER_SHELL_REPORT_FILE", "")
  let recordsOutputFolder = getEnv("CODETRACER_SHELL_RECORDS_OUTPUT", "")
  let exportFolder = getEnv("CODETRACER_SHELL_EXPORT", "")
  let shellCleanupOutputFolder = getEnv("CODETRACER_SHELL_CLEANUP_OUTPUT_FOLDER", "0") == "1"
  let shellSocket = getEnv("CODETRACER_SHELL_SOCKET", "")
  let shellAddress = getEnv("CODETRACER_SHELL_ADDRESS", "")

  let actionId = -1 # TODO? newActionId(sessionId, test=false)
  let firstLine = loadLine(sessionId, sessionLogPath)

  if shellCleanupOutputFolder:
    cleanupOutputFolder = true

  let binaryName = program.extractFilename()
  discard binaryName  # M-REC-7: binary name is no longer encoded in the
                      # folder name; it lives in the trace_index DB row's
                      # ``program`` column.  Kept extracted in case future
                      # ``ct shell`` logging wants to print it.

  if recordsOutputFolder != "":
    # M-REC-7: folder name is the bare ``recording_id`` (UUIDv7) — the
    # pre-M-REC-7 ``trace-<binaryName>-<id>`` composite duplicated
    # information already stored in the DB row.  See paths.recordingFolder.
    outputFolder = recordingFolder(recordsOutputFolder, traceID)
  else:
    # if empty, it would be constructed in `record` if it receives an empty outputFolder: get from there after `record(..)`
    # otherwise: it's already ready
    discard

  if exportFolder.len > 0:
    isExported = true

  # echo "outputFolder ", outputFolder, " isExported ", isExported, " exportZipPath ", exportZipPath
  # echo "program ", program, " recordArgs ", recordArgs, "lang ", lang

  # echo "recording? ", sessionId, " ", shellSocket, " ", shellAddress

  if socketPath.len == 0: # arg has precedence over env: only if empty, use env
    socketPath = shellSocket
  if address.len == 0:
    address = shellAddress

  let shouldSendEvents = sessionId != -1 or socketPath.len > 0 and address.len > 0

  # echo "socketPath ", socketPath
  # echo "address ", address
  # echo "shouldSendEvents ", shouldSendEvents

  # enable, if we need before-record events
  let sendAdditionalEvents = false
  var traceZipFullPath = ""

  if shouldSendEvents:
    if sendAdditionalEvents:
      registerRecordingCommand(
        reportFile, socketPath, address,
        sessionId, actionId, NO_PID, "",
        command, WorkingStatus,
        errorMessage="", firstLine=firstLine, lastLine=firstLine)

  try:
    var trace = record(
      program, recordArgs, "", lang, backend, stylusTrace,
      traceIDRecord=traceID, outputFolderArg=outputFolder,
      traceKind=traceKind, rrSupportPath=rrSupportPath,
      pythonInterpreter=pythonInterpreter,
      pythonTestFramework=pythonTestFramework,
      pythonTestArgs=pythonTestArgs,
      server=server)
    traceId = trace.recordingId
    outputFolder = trace.outputFolder

    createDir(outputFolder)
    if isExported:
      # args override env vars, which exportFolder comes from
      if not isExportedWithArg and exportFolder.len > 0:
        let uuid = $uuid4()
        exportZipPath = exportFolder / fmt"trace-{uuid}.zip"
        createDir(exportFolder)
      exportRecord(program, recordArgs, traceId, exportZipPath, outputFolder, cleanupOutputFolder)

      traceZipFullPath = expandFilename(expandTilde(exportZipPath))

    if shouldSendEvents:
      let lastLine = loadLine(sessionId, sessionLogPath)
      registerRecordingCommandForCI(
        socketPath, address,
        trace.rrPid, traceZipFullPath, toCLang(trace.lang))
      # in the past it was `registerRecordingCommand().. with more args
      #   for `ct shell` mode; if needed, this can be restored

    putEnv("CODETRACER_RECORDING", "")

    let inUiTest = getEnv("CODETRACER_IN_UI_TEST", "") == "1"
    if inUiTest:
      echo fmt"> codetracer: finished with recording id: {traceId}"
    # Marker for caller — M-REC-6 renamed the prefix from ``traceId:`` to
    # ``recordingId:`` to remove the "trace_id" overload across our
    # subprocess plumbing.  The payload is still a UUIDv7 string.
    echo fmt"recordingId:{traceId}"
    # The recorder runs the traced program as a child with
    # ``poParentStreams``, so the child writes directly to our inherited
    # stdout while our own ``echo`` output goes through Nim's buffered
    # ``stdout`` File.  On Windows, when the parent process exits while
    # this buffer still holds the marker lines, the pipe can be torn down
    # before the C runtime's atexit flush completes — the caller then
    # sees truncated output ending at the traced program's last line and
    # never receives the ``recordingId:`` marker.  Flush explicitly so
    # the marker is durably on the pipe before we return/exit.
    flushFile(stdout)
    return trace
  except CatchableError as e:
    if shouldSendEvents and sendAdditionalEvents:
      let lastLine = loadLine(sessionId, sessionLogPath)
      registerRecordingCommand(
        reportFile, socketPath, address,
        sessionId, actionId, NO_PID, "",
        command, ErrorStatus,
        errorMessage=e.msg, firstLine=firstLine, lastLine=lastLine)
    echo "error: ", e.msg
    putEnv("CODETRACER_RECORDING", "")
    quit(1)

discard main()
