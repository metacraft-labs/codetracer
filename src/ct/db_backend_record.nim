import std/[ os, osproc, strutils, strformat, sequtils, json ],
  json_serialization,
  uuid4,
  ../common/[ lang, paths, types, trace_index ],
  utilities/[ env, language_detection, zip ],
  cli/[ logging, help ],
  globals,
  trace/storage_and_import,
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

proc recordWithRR(
    ctRRSupportExe: string,
    program: string, args: seq[string],
    traceFolder: string,
    traceId: int): Trace =
  
  createDir(traceFolder)
  let traceMetadataPath = traceFolder / "trace_metadata.json"
  let traceDbMetadataPath = traceFolder / "trace_db_metadata.json"
  let process = startProcess(
    ctRRSupportExe,
    args = @[
      "record", "-o", traceFolder, program
    ].concat(args),
    options = {poEchoCmd, poParentStreams}
  )
  let code = waitForExit(process)
  if code != 0:
    echo fmt"error: ct-rr-support returned exit code ", code
    quit(code)
  
  var trace = Json.decode(readFile(traceDbMetadataPath), Trace)
  trace.id = traceId

  result = importDbTrace(traceMetadataPath, traceId, recordPid, lang, DB_SELF_CONTAINED_DEFAULT)


# rr patches for ruby/other vm-s: not supported now, instead
# in db backend support only direct traces

proc recordDb(
    lang: Lang, vmExe: string,
    program: string, args: seq[string],
    backend: string, traceFolder: string, stylusTrace: string,
    traceId: int, pythonActivationPath: string = ""): Trace =

  createDir(traceFolder)
  let tracePath = traceFolder / "trace.json"
  let traceMetadataPath = traceFolder / "trace_metadata.json"
  if lang == LangNoir and vmExe.len == 0:
    echo fmt"error: CODETRACER_NOIR_EXE_PATH is not set in the env variables"
    quit(1)
  putEnv("CODETRACER_DB_TRACE_PATH", tracePath)
  # echo "record db ", getEnv("CODETRACER_DB_TRACE_PATH")

  var startArgs: seq[string]
  case lang:
    of LangRubyDb:
      startArgs = @[rubyRecorderPath, "--out-dir", fmt"{traceFolder}", program]
    of LangSmall:
      startArgs = @[program, "--tracing"]
    of LangRustWasm, LangCppWasm:
      var vmArgs = @["run"]
      if stylusTrace.len > 0:
        vmArgs.add("-stylus")
        vmArgs.add(stylusTrace)
      vmArgs = vmArgs.concat(@["--trace-dir", traceFolder, program])
      startArgs = vmArgs
    of LangNoir:
      let backendArgs = if backend == "plonky2":
          @["--trace-plonky2"]
        elif backend.len > 0:
          echo fmt"error: unsupported backend: {backend}"
          quit(1)
        else:
          @[]

      startArgs = @["trace", "--trace-dir", traceFolder].concat(backendArgs)
    of LangPythonDb:
      if vmExe.len == 0:
        echo "error: python interpreter not provided while trying to start recorder"
        quit(1)
      var recorderArgs = @["-m", "codetracer_python_recorder", "--trace-dir", traceFolder, "--format", "json"]
      if pythonActivationPath.len > 0:
        recorderArgs.add("--activation-path")
        recorderArgs.add(pythonActivationPath)
      recorderArgs.add(program)
      startArgs = recorderArgs
    else:
      echo fmt"error: lang {lang} not supported for recordDb"
      quit(1)

  var programDir = program.parentDir
  if lang == LangNoir:
    if dirExists(program):
      # for noir, we run nargo inside `programDir`,
      # so it's sufficient to just pass a folder
      # that is inside the noir traced program
      # crate/package directory, i think
      #
      # here we just make sure it's the folder itself
      # if passed directly to `ct record`, for files
      # we take their folder as in the default case
      # with `parentDir`
      programDir = program

  if lang == LangNoir:
    if vmExe.len == 0:
      echo "error: expected a path in `CODETRACER_NOIR_EXE_PATH`: please fill this env var"
      quit(1)

  if lang in {LangRustWasm, LangCppWasm}:
    if vmExe.len == 0:
      echo "error: expected a path in `CODETRACER_WASM_VM_PATH`: please fill this env var"

  # echo vmExe, " ", startArgs.concat(args), " ", programDir
  # noir: call directly its local exe as a simple workaround for now:
  # (noirExe from src/common/paths.nim)
  #   we should try to not always depend on env var paths though
  # echo "codetracer: starting language tracer with:"
  let workdir = if lang == LangNoir:
        # for noir, we must start in the noir project directory
        # for the trace command to work
        programDir
      else:
        # for other languages, we must start in the real inherited
        # work dir
        getCurrentDir()

  let process = startProcess(
    vmExe,
    args = startArgs.concat(args),
    workingDir = workdir,
    options = {poParentStreams}) # add poEchoCmd if you want to debug and see how the cmd might look
  let recordPid = process.processId
  let exitCode = waitForExit(process)
  if exitCode != 0:
    echo fmt"error: recorder exited with {exitCode} for {lang}"
    quit(1)

  result = importDbTrace(traceMetadataPath, traceId, recordPid, lang, DB_SELF_CONTAINED_DEFAULT)


# record a program run
proc record(
    cmd: string, args: seq[string], compileCommand: string,
    langArg: Lang, backend: string, stylusTrace: string,
    test = false, basic = false,
    traceIDRecord: int = -1, customPath: string = "", outputFolderArg: string = "",
    traceKind: string = "db", rrSupportPath: string = "",
    pythonInterpreter: string = "", pythonActivationPath: string = "", pythonWithDiff: bool = false): Trace =
  var traceID: int
  if traceIDRecord == -1:
    traceID = trace_index.newID(test)
  else:
    traceID = traceIDRecord

  # if we are using the ct_wrapper.nim as in the tup dev build,
  # we need to use its pid as a record pid(which it puts in this env var),
  # because that's what index.nim sees
  # as the pid of the called process
  # otherwise this should be the directly called process, so we use `getCurrentProcessId`
  let recordPid = getEnv("CODETRACER_WRAPPER_PID", $(getCurrentProcessId())).parseInt
  trace_index.registerRecordTraceId(recordPid, traceID, test)

  let codetracerDir = if not test: codetracerShareFolder
                      elif customPath.len > 0: customPath
                      else: &"{codetracerTestDir}/records/"
  let outputFolder = if outputFolderArg.len == 0: fmt"{codetracerDir}/trace-{traceID}/" else: outputFolderArg
  let env = readRawEnv()
  let argsShell = args.join " "
  var shellCmd = cmd & " " & argsShell
  let shellArgs = @[cmd].concat(args)
  var executable = cmd.split(" ", 1)[0]
  try:
    executable = expandFilename(expandTilde(executable))
  except OsError:
    let foundExe = findExe(executable)
    if foundExe == "":
      errorMessage fmt"Can't find {executable}"
      quit(1)
    else:
      executable = foundExe

  let lang = detectLang(executable, langArg)
  # echo "in db ", lang, " ", executable
  if lang == LangUnknown:
    if traceKind == "db":
      errorMessage fmt"error: lang unknown: probably an unsupported type of project/extension, or folder/path doesn't exist?"
      quit(1)
  elif not lang.isDbBased:
    # TODO integrate with rr/gdb backend
    if traceKind == "db":
      errorMessage fmt"error: {lang} not supported currently with db: maybe you need a rr trace for it?"
      quit(1)

  let (executableDir, executableFile, executableExt) = executable.splitFile
  discard executableDir
  discard executableExt

  let traceDir = outputFolder

  var exitCode = 0

  var calltrace = false

  var sourceFolders: seq[string] = @[]
  var sourceFoldersText = ""
  let shellID = if basic: getEnv("CODETRACER_SHELL_ID", "-1").parseInt else: -1

  let defaultRawCalltraceMode = if not lang.isDbBased:
    "RawRecordNoValues"
  else:
    "FullRecord"

  # here we have different default for rr/gdb backend from loadCalltraceMode:
  #   RawRecordNoValues: for new traces
  #   `loadCalltraceMode` can be used for older traces which don't originally have this column
  #   so there the default for rr/gdb is NoInstrumentation to be more conservative
  let calltraceMode = loadCalltraceMode(getEnv("CODETRACER_CALLTRACE_MODE", defaultRawCalltraceMode), lang)

  try:
    if lang == LangRubyDb:
      return recordDb(LangRubyDb, rubyExe, executable, args, backend, outputFolder, "", traceId)
    elif lang in {LangNoir, LangRustWasm, LangCppWasm}:
      if lang == LangNoir:
        # TODO: base the first arg: source folder for record symbols on
        #   debuginfo or trace_paths.json
        # for noir for now "executable" is the noir folder
        recordSymbols(executable, outputFolder, lang)
      var vmPath = ""
      if lang in {LangRustWasm, LangCppWasm}:
        vmPath = wazeroExe
      else:
        vmPath = noirExe
      return recordDb(lang, vmPath, executable, args, backend, outputFolder, stylusTrace, traceId)
    elif lang == LangSmall:
      return recordDb(LangSmall, smallExe, executable, args, backend, outputFolder, stylusTrace, traceId)
    elif lang == LangPythonDb:
      var interpreterPath = pythonInterpreter
      if interpreterPath.len == 0:
        errorMessage "error: expected a python interpreter path but received an empty value"
        quit(1)
      if fileExists(interpreterPath):
        if not interpreterPath.isAbsolute():
          interpreterPath = absolutePath(interpreterPath)
      else:
        let foundInterpreter = findExe(interpreterPath, followSymlinks=false)
        if foundInterpreter.len == 0:
          errorMessage fmt"error: can't locate python interpreter at '{pythonInterpreter}'"
          quit(1)
        interpreterPath = foundInterpreter

      var activationPathResolved = pythonActivationPath
      if activationPathResolved.len > 0:
        try:
          activationPathResolved = expandFilename(expandTilde(activationPathResolved))
        except OsError:
          discard

      return recordDb(
        LangPythonDb,
        interpreterPath,
        executable,
        args,
        backend,
        outputFolder,
        stylusTrace,
        traceId,
        pythonActivationPath = activationPathResolved)
    elif traceKind == "rr":
      echo "TODO rr"
      echo rrSupportPath
      quit(1)
    else:
      echo fmt"ERROR: unsupported lang {lang}"
      quit(1)
  except CatchableError:
    exitCode = -1
  # echo "record trace from db_backend_record with pid ", rrPid
  result = trace_index.recordTrace(
    traceID,
    program = executable,
    args = args,
    compileCommand = compileCommand,
    env = env,
    workdir = getCurrentDir(),
    lang = lang,
    sourceFolders = sourceFoldersText,
    lowLevelFolder = "",
    outputFolder = outputFolder,
    test = test,
    imported = false,
    shellID = shellID,
    rrPid = rrPid,
    exitCode = exitCode,
    calltrace = calltrace,
    calltraceMode = calltraceMode)


proc fillTraceDbMetadataFile(path: string, traceId: int) =
  let trace = trace_index.find(traceId, test=false)
  if trace.isNil:
    echo "error: trace with id ", traceId, " not found for filling trace metadata json file: stopping"
    quit (1)
  writeFile(path, JSON.encode(trace, pretty=true))


proc exportRecord(
    program: string,
    recordArgs: seq[string],
    traceId: int,
    exportZipPath: string,
    outputFolder: string,
    cleanupOutputFolder: bool) =
  # let folder = codetracerTmpPath / changeFileEx(exportZipPath, "")

  # outputFolder/
  #   < original files >
  #   trace_db_metadata.json
  #
  # -> zip -> <exportZipPath>

  fillTraceDbMetadataFile(outputFolder / "trace_db_metadata.json", traceId)

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
  #   [--trace-kind db/rr] [--rr-support-path <rr-support-path>]
  #   <program> [<args>]
  let args = os.commandLineParams()
  if args.len == 0:
    displayHelp()
    return
  var program = ""
  var recordArgs: seq[string]
  var outputFolder = ""
  #var recordArgsIndex = -1
  var traceID = -1
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

  if recordsOutputFolder != "":
    outputFolder = recordsOutputFolder / fmt"trace-{binaryName}-{traceID}"
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
      pythonInterpreter=pythonInterpreter)
    traceId = trace.id
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
      echo fmt"> codetracer: finished with trace id: {traceId}"
    # Marker for caller
    echo fmt"traceId:{traceId}"
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
