import std/[ os, osproc, strutils, strformat, sequtils, json ],
  ../../common/[ lang, paths, types, trace_index ],
  ../utilities/[ env, language_detection ],
  ../cli/[ logging, help ],
  ../globals,
  storage_and_import,
  shell

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

# rr patches for ruby/other vm-s: not supported now, instead
# in db backend support only direct traces

proc recordDb(
    lang: Lang, vmExe: string,
    program: string, args: seq[string],
    backend: string, traceFolder: string, traceId: int): Trace =

  createDir(traceFolder)
  let tracePath = traceFolder / "trace.json"
  let traceMetadataPath = traceFolder / "trace_metadata.json"
  if lang == LangNoir and vmExe.len == 0:
    echo fmt"error: CODETRACER_NOIR_EXE_PATH is not set in the env variables"
    quit(1)
  putEnv("CODETRACER_DB_TRACE_PATH", tracePath)
  # echo "record db ", getEnv("CODETRACER_DB_TRACE_PATH")

  let startArgs = case lang:
    of LangRubyDb:
      @[rubyTracerPath, program]
    of LangSmall:
      @[program, "--tracing"]
    of LangNoir:
      let backendArgs = if backend == "plonky2":
          @["--trace-plonky2"]
        elif backend.len > 0:
          echo fmt"error: unsupported backend: {backend}"
          quit(1)
        else:
          @[]

      @["trace", "--trace-dir", traceFolder].concat(backendArgs)
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

  # echo vmExe, " ", startArgs.concat(args), " ", programDir
  # noir: call directly its local exe as a simple workaround for now:
  # (noirExe from src/common/paths.nim)
  #   we should try to not always depend on env var paths though
  echo "codetracer: starting language tracer with:"
  let process = startProcess(
    vmExe,
    args = startArgs.concat(args),
    workingDir = programDir,
    options = {poEchoCmd, poParentStreams})
  let exitCode = waitForExit(process)
  if exitCode != 0:
    echo "error: problem with ruby trace: exit code = ", exitCode
    quit(1)

  importDbTrace(traceMetadataPath, traceId, lang, DB_SELF_CONTAINED_DEFAULT)


# record a program run
proc record(cmd: string, args: seq[string], compileCommand: string,
            langArg: Lang, backend: string, test = false, basic = false,
            traceIDRecord: int = -1, customPath: string = "", outputFolderArg: string = ""): Trace =
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
    executable = expandFilename(executable)
  except OsError:
    let foundExe = findExe(executable)
    if foundExe == "":
      errorMessage fmt"Can't find {executable}"
      quit(1)
    else:
      executable = foundExe

  let lang = detectLang(executable, langArg)
  if lang == LangUnknown:
    errorMessage fmt"error: lang unknown: probably an unsupported type of project/extension, or folder/path doesn't exist?"
    quit(1)
  elif not lang.isDbBased:
    # TODO integrate with rr/gdb backend
    errorMessage fmt"error: {lang} not supported currently!"
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
      return recordDb(LangRubyDb, rubyExe, executable, args, backend, outputFolder, traceId)
    elif lang == LangNoir:
      recordSymbols(executable, outputFolder, lang)
      return recordDb(LangNoir, noirExe, executable, args, backend, outputFolder, traceId)
    elif lang == LangSmall:
      return recordDb(LangSmall, smallExe, executable, args, backend, outputFolder, traceId)
    else:
      echo fmt"ERROR: unsupported lang {lang}"
      quit(1)
  except CatchableError:
    exitCode = -1

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


proc record*(args: seq[string]): Trace =
  # record
  #   [--lang <lang>] [-o/--output-folder <output-folder>]
  #   [--backend <backend>]
  #   [-e/--export <export-zip>] [-c/--cleanup-output-folder]
  #   <program> [<args>]
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
  # for i, arg in args:
  var i = 0
  while i < args.len:
    var arg = args[i]
    if arg == "-o" or arg == "--output-folder":
      if args.len < i + 2:
        displayHelp()
        return
      createDir args[i + 1]
      outputFolder = expandFilename(args[i + 1])
      i += 2
    elif arg == "-e" or arg == "--export":
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
  let isShellExported = getEnv("CODETRACER_SHELL_EXPORT", "0") == "1"
  let shellCleanupOutputFolder = getEnv("CODETRACER_SHELL_CLEANUP_OUTPUT_FOLDER", "0") == "1"
  let shellSocket = getEnv("CODETRACER_SHELL_SOCKET", "")
  let shellAddress = getEnv("CODETRACER_SHELL_ADDRESS", "")

  let actionId = -1 # TODO? newActionId(sessionId, test=false)
  let firstLine = loadLine(sessionId, sessionLogPath)

  if isShellExported:
    isExported = true

  if shellCleanupOutputFolder:
    cleanupOutputFolder = true

  let binaryName = program.extractFilename()

  if isExported:
    if exportZipPath == "":
      outputFolder = binaryName
    else:
      outputFolder = codetracerTmpPath / changeFileExt(exportZipPath, "")

  if recordsOutputFolder != "":
    outputFolder = recordsOutputFolder / fmt"trace-{binaryName}-{traceID}"

  if isShellExported:
    isExported = true
    exportZipPath = outputFolder & ".zip"

  # echo "outputFolder ", outputFolder, " isExported ", isExported, " exportZipPath ", exportZipPath
  # echo "program ", program, " recordArgs ", recordArgs, "lang ", lang

  # echo "recording? ", sessionId, " ", shellSocket, " ", shellAddress
  if sessionId != -1:
    registerRecordingCommand(
      reportFile, shellSocket, shellAddress,
      sessionId, actionId, Trace(id: traceId, outputFolder: outputFolder),
      command, WorkingStatus,
      errorMessage="", firstLine=firstLine, lastLine=firstLine)

  try:
    var trace = record(
      program, recordArgs, "", lang, backend,
      traceIDRecord=traceID, outputFolderArg=outputFolder)
    traceId = trace.id

    var outputPath = trace.outputFolder
    createDir(outputFolder)
    if isExported:
      # TODO: exportRecord
      # exportRecord(program, recordArgs, traceId, exportZipPath, outputFolder, cleanupOutputFolder)
      let exportZipFullPath = expandFilename(exportZipPath)
      outputPath = exportZipFullPath

    if sessionId != -1:
      let lastLine = loadLine(sessionId, sessionLogPath)
      registerRecordingCommand(
        reportFile, shellSocket, shellAddress,
        sessionId, actionId, trace,
        command, OkStatus,
        errorMessage="", firstLine=firstLine, lastLine=lastLine)

    # if reportFile != "":
      # registerRecordInReportFile(reportFile, trace, outputPath)
    putEnv("CODETRACER_RECORDING", "")

    let inUiTest = getEnv("CODETRACER_IN_UI_TEST", "") == "1"
    if inUiTest:
      echo fmt"> codetracer: finished with trace id: {traceId}"
    return trace
  except CatchableError as e:
    if sessionId != -1:
      let lastLine = loadLine(sessionId, sessionLogPath)
      registerRecordingCommand(
        reportFile, shellSocket, shellAddress,
        sessionId, actionId, Trace(id: -1, outputFolder: outputFolder),
        command, ErrorStatus,
        errorMessage=e.msg, firstLine=firstLine, lastLine=lastLine)
    echo "error: ", e.msg
    putEnv("CODETRACER_RECORDING", "")
    quit(1)
