# thank you, Lord and GOD Jesus!

import
  results,
  std / [
    strutils, strformat, sequtils, sets, streams, json, tables, times, os, osproc,
    asyncdispatch, posix, strtabs, algorithm, rdstdin, nativesockets, re, random
  ],
  json_serialization

import .. / common / [trace_index, types, start_utils, intel_fix, path_utils, paths, lang, install_utils, config]
import version, confutils, codetracerconf

const
  CODETRACER_RECORD_CORE: string = "CODETRACER_RECORD_CORE"
let
  homedir = os.getHomeDir()
  # TODO: This is Linux-specific.
  #       We need to select a more appropriate platform-specific
  #       directory for Mac and Windows
  codetracerShareFolder = getEnv("XDG_DATA_HOME", homedir / ".local" / "share") / "codetracer"
var
  electronPid: int = -1

### forward declarations
proc importDbTrace(traceMetadataPath: string, traceIdArg: int, lang: Lang = LangNoir, selfContained: bool = true): Trace
# proc downloadTrace(traceRegistryId: string): Trace
proc runRecordedTrace(
  trace: Trace,
  test: bool,
  repl: bool = false,
  summary: bool = false,
  summaryOutputPath : string = "",
  recordCore: bool = false): bool


### env-related code
proc envLoadRecordCore: bool =
  let recordCoreRaw = getEnv(CODETRACER_RECORD_CORE, "")
  recordCoreRaw == "true"


proc readRawEnv: string =
  var variables: seq[(string, string)] = @[]
  for name, value in envPairs():
    variables.add((name, value))
  sorted(variables).mapIt($it[0] & "=" & $it[1]).join("\n")


proc displayHelp: void =
  # echo "help: TODO"
  let process = startProcess(codetracerExe, args = @["--help"], options = {poParentStreams})
  let code = waitForExit(process)
  quit(code)


template errorMessage*(message: string) =
  echo message


# run a shell command and trace the passed `cmd`:
#   a wrapped around `execShellCmd`
proc tracedExecShellCmd(cmd: string): int =
  # echo "> ", cmd
  result = execShellCmd(cmd)
  if result != 0:
    echo "error: ", cmd
  #  quit 1


# stop a process by its name: TODO we shouldn't need something like that
# especially if we support several codetracer instances in the same time
proc stopProcess(processName: string, arg: string = "-SIGINT") =
  ensureExists("killall")
  discard execShellCmd(fmt"killall {arg} " & processName)


# prepare record environment and programs running for the record
# and run them
proc prepareRun(
    traceID: int, exeDir, exe: string,
    shellCmd: string, test: bool, basic: bool,
    lang: Lang, calltrace: bool, traceIDRecord: int,
    outputFolder: string) =
  let
    traceDir = outputFolder # codetracerDir / &"trace-{traceID}"
    # calltraceFile = traceDir / "calltrace"

  if traceIDRecord == -1:
    removeDir traceDir
  createDir traceDir / "rr"
  # discard mkfifo(cstring(calltraceFile), 0o644)

  putEnv("CODETRACER_TRACE_FOLDER", traceDir)

  if lang == LangNim:
    # echo "prepare"
    # TODO: remove this once we have embedded debug info
    # try:
    #   copyFile exeDir / &"metadata_{exe}.txt",
    #            traceDir / "metadata.txt"
    # except:
    #   echo "warn: on copy: maybe you need to rebuild? " & getCurrentExceptionMsg()
    #   # quit(1)

    try:
      # TODO: remove this once we have embedded debug info
      # even a bigger problem: ct_sourcemap_{exe} can be left from an older binary
      copyFile exeDir / &"ct_sourcemap_{exe}",
               traceDir / "ct_sourcemap"
    except:
      discard
      # this might be ok
      # echo "warn: probably no sourcemap"

    try:
      # TODO: remove this once we have embedded debug info
      # even a bigger problem: ct_sourcemap_{exe} can be left from an older binary
      copyFile exeDir / &"macro_sourcemap_{exe}.json",
               traceDir / "macro_sourcemap.json"
    except:
      echo "warn: probably no macro sourcemap"

  # shell &"rm -rf {outputFolder}/call_base"
  # translator not used currently stopProcess("translator")

var onInterrupt: proc: void
var rrPid = -1 # global, so it can be updated immediately on starting a process, and then used in `onInterrupt` if needed

proc parseNmFunctionLine(line: string, lang: Lang, addrTable: var Table[string, string], nameTable: var Table[string, seq[string]]) =
  # echo "line ", line, " ", line.len
  let re = re"^(?<addr>[0-9a-fA-F]+) \w (?<name>.+)\n?$"
  var matches: array[2, string]

  if line.match(re, matches):
    let address = matches[0]
    let name = matches[1]

    addrTable[address] = name

    if line.len > 100 or line.len == 0:
      # maybe a complex generic function? for now ignore
      # we had some cases with symbol function names ~80kb ~85k length
      # in chumsky in rust(parser combinators lib)
      # which were leading probably to an explosion here
      return

    if not nameTable.contains(name):
      nameTable[name] = @[]

    nameTable[name].add(name)

    if lang == LangRust:
      let parts = name.split("::")

      for i in 1 ..< parts.len:
        let shortName = parts[i .. ^1].join("::")

        if not nameTable.contains(shortName):
          nameTable[shortName] = @[]

        nameTable[shortName].add(name)


proc recordFunctions(exePath: string, outputFolder: string, lang: Lang) =
  var nameTable: Table[string, seq[string]]
  var addrTable: Table[string, string]

  try:
    let nmProc = startProcess(
      "nm", args=["--demangle", exePath],
      options={poUsePath}
    )

    var data = ""
    while nmProc.running:
      data.add(nmProc.outputstream.readAll)

      for line in data.splitLines(keepEol=true):
        if line.endsWith('\n'):
          parseNmFunctionLine(line, lang, addrTable, nameTable)
        else:
          data = line
          break

    for line in data.splitLines():
      parseNmFunctionLine(line, lang, addrTable, nameTable)

    nmProc.close()

    writeFile(&"{outputFolder}/function_name_map.json", $(%* nameTable))
    writeFile(&"{outputFolder}/function_addr_map.json", $(%* addrTable))

  except:
    echo getCurrentExceptionMsg()
    echo ""
    echo "WARNING: Can't extract function info. Some functionality may not work correctly!"
    echo ""

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

proc afterRun(
    traceID: int, binary: string, program: string,
    test: bool, basic: bool, lang: Lang,
    outputFolder: string, sourceFolders: seq[string]) =

  try:
    if lang != LangNim:
      writeFile(outputFolder / "function_index.json", "[]")
    else:
      discard
      # TODO: think again what to do with those features
      # let (validSourcemap, sourcemap) = loadSourcemap(outputFolder / "ct_sourcemap")
      # let (validMacroSourmap, macroSourcemap) = loadMacroSourcemap(outputFolder / "macro_sourcemap.json")
      # # if validSourcemap and validMacroSourmap:
        # indexFunctions(sourcemap, macroSourcemap, sourceFolders, outputFolder / "function_index.json", traceID)
  except:
    echo "warn: problem with function index " & getCurrentExceptionMsg()
  # echo ""
  # echo "trace id ", traceID
  # echo "record ready"
  echo "> codetracer: finished with trace id: ", traceID


proc scriptSessionLogPath(sessionId: int): string =
  let bashLogFile = getEnv("CODETRACER_SHELL_BASH_LOG_FILE", "")
  if bashLogFile.len == 0:
    codetracerTmpPath / fmt"session-{sessionId}-script.log"
  else:
    bashLogFile


proc stop(process: Process) =
  process.terminate()


proc stopCoreProcess(process: Process, recordCore: bool) =
  if not recordCore:
    discard
    echo "stop core process"
    # send SIGTERM so we can cleanup and stop task processes from core
    process.stop()

    echo "[codetracer PID]: ", getCurrentProcessId()
  else:
    # rr is probably `process`, but we want to stop only
    # the core process, not rr itself
    # so rr can finish the recording
    # of our core process correctly
    #
    # TODO: adapt for rr/gdb backend? here assuming db-backend
    # TODO: stops all db-backend processes
    # so it would break other running codetracer instances
    # stop only our one: getting the pid from process/output/file?
    echo ""
    echo "stopping dispatcher:"
    stopProcess("db-backend", arg="-SIGINT")
    echo ""
    echo "stopping dispatcher: might show an exception.."
    echo "(if it's not from dispatcher, then probably it's a codetracer bug)"
    echo "WAIT FOR \"record ready\" message"
    echo ""


proc launchElectron(args: seq[string] = @[], trace: Trace = nil, recordCore: bool = false, test: bool = false): bool =
  createDir codetracerCache
  let saveDir = codetracerShareFolder / "saves/"
  let workdir = getCurrentDir()
  createDir saveDir

  # sometimes things like "--no-sandbox" are useful e.g. for now for
  # experimenting with appimage
  let optionalElectronArgs = getEnv("CODETRACER_ELECTRON_ARGS", "").splitWhitespace()

  var env = newStringTable(modeStyleInsensitive)
  for name, value in envPairs():
    env[name] = value
  env["ELECTRON_ENABLE_LOGGING"] = "1"

  when defined(builtWithNix):
    env["NODE_PATH"] = nodeModulesPath

  env["NIX_CODETRACER_EXE_DIR"] = codetracerExeDir
  env["LINKS_PATH_DIR"] = linksPath

  # https://www.electronjs.org/docs/latest/api/environment-variables#electron_enable_logging
  env["ELECTRON_LOG_FILE"] = ensureLogPath(
    "frontend",
    getCurrentProcessId(),
    "frontend",
    0,
    "log"
  )

  if args.len > 0:
    if not trace.isNil:
      let process = startCoreProcess(traceId=trace.id, recordCore=recordCore, callerPid=getCurrentProcessId(), test=test)
      ensureExists(electronExe)
      let args = @[
          electronIndexPath].
            concat(args).
            concat(@["--caller-pid", $getCurrentProcessId()].
            concat(optionalElectronArgs))
      var processUI = startProcess(
        electronExe,
        workingDir = workdir,
        args = args,
        env = env,
        options = {poParentStreams})
      electronPid = processUI.processID
      let electronExitCode = waitForExit(processUI)
      stopCoreProcess(process, recordCore)
      sleep(100)

      return electronExitCode == RESTART_EXIT_CODE

  else:
    ensureExists(electronExe)
    let args = @[codetracerExeDir].concat(args).concat(optionalElectronArgs)
    var processUI = startProcess(
      electronExe,
      workingDir = workdir,
      args = args,
      env = env,
      options={poParentStreams})
    electronPid = processUI.processID

    # TODO: seems some processes don't exit
    let electronExitCode = waitForExit(processUI)
    return electronExitCode == RESTART_EXIT_CODE

  return false

# start a simple repl session
proc launchRepl(trace: Trace, test: bool, summary: bool, summaryOutputPath: string, recordCore: bool) =
  createDir codetracerCache
  var args = @[$trace.id, $getCurrentProcessId()]
  if test:
    args.add("--test") # TODO repl support
  if summary:
    args.add("--summary")
    args.add(summaryOutputPath)
  ensureExists(consoleExe)
  let argsShell = args.join(" ")
  if not recordCore:
    echo fmt"{consoleExe} {argsShell}"
    discard execShellCmd(fmt"{consoleExe} {argsShell}")
  else:
    discard execShellCmd(fmt"{codetracerExeDir}/codetracer {consoleExe} {argsShell}")


# detect the lang of the source for a binary
#   based on folder/filename/files and if not possible on symbol patterns
#   in the binary
#   for scripting languages on the extension
#   for folders, we search for now for a special file
#   like `Nargo.toml`
#   just analyzing debug info might be best
#   TODO: a project can have sources in multiple languages
#   so the assumption it has a single one is not always valid
#   but for now are not reforming that yet
proc detectFolderLang(folder: string): Lang =
  if fileExists(folder / "Nargo.toml"):
    LangNoir
  else:
    # TODO: rust/ruby/others?
    LangUnknown


proc detectLang(program: string, lang: Lang): Lang =
  # echo "detectLang ", program
  if lang == LangUnknown:
    if program.endsWith(".rb"):
      LangRubyDb
    elif program.endsWith(".nr"):
      LangNoir
    elif program.endsWith(".small"):
      LangSmall
    elif dirExists(program):
      detectFolderLang(program)
    else:
      LangUnknown
      # TODO: integrate with rr/gdb backend
  else:
    lang


proc getGitTopLevel(dir: string): string =
  try:
    let gitExe = findExe("git")
    let cmd = startProcess(
      gitExe,
      args = @["rev-parse", "--show-toplevel"],
      workingDir = dir,
      options = {poStdErrToStdOut}
    )
    let output = cmd.outputStream.readAll().strip()
    let exitCode = waitForExit(cmd)
    if exitCode == 0 and output.len > 0:
      return output
  except:
    return ""

proc processSourceFoldersList(folderSet: HashSet[string], programDir: string = ""): seq[string] =
  var folders: seq[string] = @[]
  let gitRoot = getGitTopLevel(programDir)
  var i = 0

  for potentialChild in folderSet:
    var ok = true
    # e.g. generated_not_to_break_here/ or relative/
    if potentialChild.len == 0 or potentialChild[0] != '/':
      ok = false
    else:
      var k = 0
      for potentialParent in folderSet:
        if i != k and potentialChild.startsWith(potentialParent):
          ok = false
          break
        k += 1
    if ok and not potentialChild.startsWith(gitRoot):
      folders.add(potentialChild)
    i += 1

  # Add Git repository roots to the final result
  if gitRoot != "":
    folders.add(gitRoot)

  if folders.len == 0:
    folders.add(getAppFilename().parentDir)
  # based on https://stackoverflow.com/a/24867480/438099
  # credit to @DrCopyPaste https://stackoverflow.com/users/2186023/drcopypaste
  var sortedFolders = sorted(folders)

  result = sortedFolders


# for now hardcode: files are usually useful and
# probably much less perf/size compared to actual traces
# it's still good to have an option/opt-out, so we leave that
# as a flag in the internals, but not exposed to user yet
# that's why for now it's hardcoded for db
const DB_SELF_CONTAINED_DEFAULT = true

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
      error &"Can't find {executable}"
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


# run a recorded trace based on args, a saving project for it in the process
proc runRecordedTrace(
  trace: Trace,
  test: bool,
  repl: bool = false,
  summary: bool = false,
  summaryOutputPath: string = "",
  recordCore: bool = false
): bool =
  let args = if test: @[$trace.id, "--test"] else: @[$trace.id]
  if not repl:
    if summary:
      echo "error: repl must be true for summary"
      quit(1)
    return launchElectron(args, trace, recordCore, test)
  else:
    launchRepl trace, test, summary, summaryOutputPath, recordCore
    return false


when defined(testing):
  proc runTest(traceID: int, recordCore: bool = false) =
    let trace = trace_index.find(traceID, test=true)
    if not trace.isNil:
      let recordCore = envLoadRecordCore()
      discard runRecordedTrace(trace, true, recordCore=recordCore)

proc generateSecurePassword(length: int): string =
  let chars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  randomize(getTime().toUnix)
  result = newString(length)
  for i in 0..<length:
    result[i] = chars[rand(chars.len - 1)]
  return result

proc zipFileWithPassword(inputFile: string, outputZip: string, password: string) =
  let basePath = lastPathPart(inputFile)
  let cmd = &"cd {parentDir(inputFile)} && zip -r -P " & password & " " & outputZip & " " & basePath
  discard execShellCmd(cmd)

proc uploadEncyptedZip(file: string): int =
  # TODO: Plug in http client instead of curl
  let config = loadConfig(folder=getCurrentDir(), inTest=false)
  let cmd = &"curl -X POST -F \"file=@{file}\" {config.webApiRoot}/upload"
  let exitCode = execCmd(cmd)
  exitCode

proc uploadTrace(trace: Trace) =
  let outputZip = trace.outputFolder / "archived.zip"
  let password = generateSecurePassword(20)
  echo password

  zipFileWithPassword(trace.outputFolder, outputZip, password)
  let exitCode = uploadEncyptedZip(outputZip)

  quit(exitCode)

proc fillSourceFiles(folder: string, sourcePaths: seq[string]) =
  for path in sourcePaths:
    try:
      let targetPath = folder / path
      let targetDir = targetPath.parentDir
      if targetDir != folder:
        createDir targetDir
      copyFile path, folder / path
    except OsError:
      discard # assume path like start.S/unaccessible: don't add to source


proc fillTraceMetadataFile(path: string, traceId: int) =
  let trace = trace_index.find(traceId, test=false)
  if trace.isNil:
    echo "error: trace with id ", traceId, " not found for filling trace metadata json file: stopping"
    quit (1)
  writeFile(path, JSON.encode(trace, pretty=true))



proc loadSessionId: int =
  let sessionIdRaw = getEnv("CODETRACER_SESSION_ID", "-1")
  var sessionId = -1
  try:
    sessionId = sessionIdRaw.parseInt
  except ValueError:
    sessionId = -1
  sessionId


proc loadLine(sessionId: int, sessionLogPath: string): int =
  if sessionId == -1:
    NO_LINE
  else:
    let useScript = getEnv("CODETRACER_SHELL_USE_SCRIPT", "0") == "1"
    let raw = readFile(sessionLogPath)
    if not useScript:
      raw.parseInt
    else:
      raw.splitLines.len - 1


proc record(args: seq[string]): Trace =
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


const
  TRACE_CMD_COLUMN_WIDTH = 70
  TRACE_WORKDIR_COLUMN_WIDTH = 40


func limitColumnLeft(text: string, width: int): string =
  if text.len > width:
    ".." & text[text.len - (width - 2) .. ^1]
  else:
    text


func limitColumnRight(text: string, width: int): string =
  if text.len > width:
    text[0 .. (width - 2) - 1] & ".."
  else:
    text


func traceInText(trace: Trace): string =
  let displayCmd = limitColumnRight(trace.program & " " & trace.args.join(" "), TRACE_CMD_COLUMN_WIDTH)
  let displayWorkdir = limitColumnLeft("ran in " & trace.workdir, TRACE_WORKDIR_COLUMN_WIDTH)
  let idColumn = fmt"{trace.id}."
  alignLeft(idColumn, 5) & " | " & alignLeft(displayCmd, TRACE_CMD_COLUMN_WIDTH) & " | " &
  alignLeft(displayWorkdir, TRACE_WORKDIR_COLUMN_WIDTH) & " | " &
  alignLeft(toName(trace.lang), 15) & " | " & alignLeft(trace.date, 15)


func tracesInText(traces: seq[Trace]): string =
  traces.reversed.mapIt(traceInText(it)).join("\n")


func tracesInJson(traces: seq[Trace]): string =
  Json.encode(traces)


proc interactiveReplayMenu(command: StartupCommand, repl: bool) =
  let recordCore = envLoadRecordCore()
  # ordered by id
  # returns the newest(biggest id) first
  let traces = trace_index.all(test=false)
  let limitedTraces = if traces.len > 10:
      traces[0 ..< 10]
    else:
      traces

  echo "Select a trace to replay, entering its id:"
  echo ""

  for trace in limitedTraces:
    echo traceInText(trace)

  if traces.len > 10:
    echo "..(older traces not shown)"

  echo ""

  while true:
    let raw = readLineFromStdin("replay: ")
    try:
      let traceId = raw.parseInt
      let trace = trace_index.find(traceId, test=false)
      if not trace.isNil:
        if command != StartupCommand.upload:
          discard runRecordedTrace(trace, test=false, repl=repl, recordCore=recordCore)
        else:
          uploadTrace(trace)
        break
      else:
        echo fmt"trace with id {traceId} not found in local codetracer db, please try again"
    except:
      echo "error: ", getCurrentExceptionMsg()
      echo "please try again"


proc findTraceForArgs(
    patternArg: Option[string],
    traceIdArg: Option[int],
    traceFolderArg: Option[string]): Trace =
  # if no trace found, direct error on screen and quit
  if traceIdArg.isSome:
    let traceId = traceIdArg.get
    let trace = trace_index.find(traceId, test=false)
    if not trace.isNil:
      return trace
    else:
      errorMessage fmt"error: trace with id {traceId} not found in local codetracer db"
      quit(1)
  elif traceFolderArg.isSome:
    let folder = traceFolderArg.get
    var trace = trace_index.findByPath(expandFilename(folder), test=false)
    if trace.isNil:
      trace = trace_index.findByPath(expandFilename(folder) & "/", test=false)
    if not trace.isNil:
      return trace
    else:
      errorMessage fmt"error: trace with output folder {folder} not found in local codetracer db"
      quit(1)
  else:
    assert patternArg.isSome
    let programPattern = patternArg.get
    #var traceID = -1
    # for now:
    #   no program args match
    #   i think i haven't used it lately
    #   but this can be re-added
    #   either by configuration  update
    #   or maybe a custom flag/restArgs
    # var runArgs: seq[string]
    # for i in 1 ..< args.len:
    #   runArgs.add(args[i])
    # if runArgs.len > 0:
    #   runTrace(
    #     program,
    #     runArgs,
    #     "",
    #     LangUnknown,
    #     test=false,
    #     repl=repl,
    #     traceID=traceID,
    #     recordCore=recordCore)
    # else:
    # if true:
    let trace = if '#' in programPattern:
        let localTrace = trace_index.findByProgramPattern(programPattern, test=false)
        if localTrace.isNil:
          echo "trace not found locally: do you want to download it from registry and replay? y/n"
          echo "  WARNING: might include sensitive data/foreign code"
          let userInput = readLine(stdin)
          if userInput.toLowerAscii() != "y":
            echo "no download and replay!"
            quit(1)
          else:
            # downloadTrace(programPattern)
            echo "error: unsupported currently!"
            quit(1)
        else:
          localTrace
      else:
        trace_index.findByProgramPattern(programPattern, test=false)
    if not trace.isNil:
      return trace
    else:
      errorMessage fmt"error: trace matching program with {programPattern} not found in local codetracer db"
      quit(1)


proc internalReplayOrUpload(
  patternArg: Option[string],
  traceIdArg: Option[int],
  traceFolderArg: Option[string],
  interactive: bool,
  command: StartupCommand
): bool =
  # replay/console/upload
  #   interactive menu:
  #     limited list of last traces and ability
  #     to replay some of them with <id>
  # replay [<last-trace-matching-pattern>] (including cmd similar to run)
  # e.g.
  #   replay `program-name` # works
  #   # but also as in run
  #   replay `program-name original-args`
  # replay --id <id>
  # replay --trace-folder/-t <trace-output-folder>
  # TODO: other flags?
  let inConsole = command == StartupCommand.console
  if interactive:
    interactiveReplayMenu(command, repl=inConsole)
    return false
  else:
    let trace = findTraceForArgs(patternArg, traceIdArg, traceFolderArg)
    # if no trace found, findTraceForArgs directly errors on screen and quits
    if command != StartupCommand.upload:
      let recordCore = envLoadRecordCore()
      return runRecordedTrace(trace, test=false, repl=inConsole, recordCore=recordCore)
    else:
      uploadTrace(trace)
      return false


proc replay(
  patternArg: Option[string],
  traceIdArg: Option[int],
  traceFolderArg: Option[string],
  interactive: bool
): bool =
  internalReplayOrUpload(patternArg, traceIdArg, traceFolderArg, interactive, command=StartupCommand.replay)


proc uploadCommand(
  patternArg: Option[string],
  traceIdArg: Option[int],
  traceFolderArg: Option[string],
  interactive: bool
) =
  discard internalReplayOrUpload(patternArg, traceIdArg, traceFolderArg, interactive, command=StartupCommand.upload)


proc console(
  patternArg: Option[string],
  traceIdArg: Option[int],
  traceFolderArg: Option[string],
  interactive: bool
) =
  discard internalReplayOrUpload(patternArg, traceIdArg, traceFolderArg, interactive, command=StartupCommand.console)


# proc downloadTrace(traceRegistryId: string): Trace =
#   # ! ONLY db-backend for now
#   #
#   # very similar to importTraceInPreparedFolder
#   # but with newer logic for now for db-backend
#   # some of it in api.downloadTrace
#   let newTraceId = trace_index.newID(test=false)
#   let downloadFolder = codetracerTmpPath / fmt"trace-{newTraceId}"
#   let traceLocalFolder = codetracerTraceDir / fmt"trace-{newTraceId}"
#   # make sure we delete it, if there was something before
#   removeDir(downloadFolder)
#   var api = newApi()
#   let ok = api.downloadTrace(traceRegistryId, downloadFolder)
#   if ok:
#     let rawTraceDbRecord = readFile(downloadFolder / "trace_index_db_record.json")
#     var importedTrace = Json.decode(rawTraceDbRecord, Trace)
#     importedTrace.id = newTraceId
#     importedTrace.outputFolder = traceLocalFolder
#     importedTrace.imported = true
#     importedTrace.program = traceRegistryId
#
#     moveDir(downloadFolder, traceLocalFolder)
#     trace_index.recordTrace(importedTrace, test=false)
#   else:
#     nil
#
#   # TODO
#   # store with both program from trace_metadata.json and longer name
#   # if called from replay, return the trace so it can be replayed easily


# proc downloadCommand(traceRegistryId: string) =
#   let trace = downloadTrace(traceRegistryId)
#   if not trace.isNil:
#     echo "downloaded trace locally"
#     echo fmt"you can replay it with `ct replay {traceRegistryId}`"
#   else:
#     echo "assuming some problem with trace download"
#     quit(1)

proc runWithRestart(
  test: bool,
  repl: bool = false,
  summary: bool = false,
  summaryOutputPath: string = "",
  recordCore: bool = false,
  lang: Lang = LangUnknown,
  recordArgs: seq[string] = @[]
) =
  var afterRestart = false

  while true:
    var recordedTrace: Trace = nil

    if lang == LangUnknown:
      errorMessage fmt"error: lang unknown: probably an unsupported type of project/extension, or folder/path doesn't exist?"
      quit(1)
    elif not lang.isDbBased:
      errorMessage fmt"error: {lang} not supported currently!"
      quit(1)
    else:
      recordedTrace = record(recordArgs)
    if not recordedTrace.isNil:
      let shouldRestart =
        if not afterRestart:
          runRecordedTrace(recordedTrace, test, repl, recordCore)
        else:
          let process = startProcess(codetracerExe, args = @["replay", fmt"--id={recordedTrace.id}"], options = {poParentStreams})
          waitForExit(process) == RESTART_EXIT_CODE

      if not shouldRestart:
        break
      else:
        afterRestart = true

    else:
      break

proc run(programArg: string, args: seq[string]) =
  # run <program> <args>
  # optionally if env variable CODETRACER_RECORD_CORE=true
  # try to record core (dispatcher run) with codetracer
  let recordCore = envLoadRecordCore()
  var traceID = -1
  var program = programArg
  var dbBasedSupport = false

  let lang = detectLang(program, LangUnknown)
  let recordArgs = @[programArg].concat(args)

  runWithRestart(
    test=false,
    repl=false,
    recordCore=recordCore,
    lang=lang,
    recordArgs=recordArgs
  )


type
  ListFormat = enum FormatText, FormatJson

  ListTarget {.pure.} = enum Local, Remote


proc parseListFormat(arg: string): ListFormat =
  if arg == "text":
    FormatText
  elif arg == "json":
    FormatJson
  else:
    errorMessage "error: expected --format text/json"
    quit(1)


proc parseListTarget(arg: string): ListTarget =
  if arg == "local":
    ListTarget.Local
  elif arg == "remote":
    ListTarget.Remote
  else:
    errorMessage "error: expected local or remote"
    quit(1)


proc listLocalTraces(format: ListFormat) =
  let traces = trace_index.all(test=false)
  case format:
  of FormatText:
    echo tracesInText(traces)
  of FormatJson:
    echo tracesInJson(traces)


const TRACE_USER_COLUMN_WIDTH = 16
const TRACE_HOSTNAME_COLUMN_WIDTH = 32


# func traceMetadataText*(metadata: WebApiTraceMetadata): string =
#   # <compositeKey> <title> <time>
#   # calc.rb:4 | alexander92 | al-1 | time
#   let traceRegistryId = metadata.compositeKey
#   if traceRegistryId.len > 32:
#     "too big trace registry id for our list command: printing only it for now: " & traceRegistryId
#   else:
#     alignLeft(traceRegistryId, 32) & " | " & alignLeft(metadata.user, TRACE_USER_COLUMN_WIDTH) & " | " &
#       alignLeft(metadata.hostname, TRACE_HOSTNAME_COLUMN_WIDTH) & " | "


# proc listRemoteTraces(format: ListFormat) =
#   var api = newApi()
#   case format:
#   of FormatText:
#     let tracesMetadata = api.listTraces()
#     echo tracesMetadata.mapIt(traceMetadataText(it)).join("\n")
#   of FormatJson:
#     let tracesJson = api.listRawJsonTraces()
#     echo tracesJson


proc listCommand(rawTarget: string, rawFormat: string) =
  # list [local/remote (default local)] [--format text/json (default text)]
  let target = parseListTarget(rawTarget)
  let format = parseListFormat(rawFormat)
  case target:
  of ListTarget.Local:
    listLocalTraces(format)
  of ListTarget.Remote:
    echo "error: unsupported currently!"
    # listRemoteTraces(format)


const DEFAULT_SOCKET_PORT: int = 5_000

proc host(
    port: int,
    backendSocketPort: Option[int],
    frontendSocketPort: Option[int],
    frontendSocketParameters: string,
    traceArg: string) =
  # codetracer host --port <port>
  #        [--backend-socket-port <port>]
  #        [--frontend-socket <port>]
  #        [--frontend-socket-parameters <parameters>]
  #        <trace-id>/<trace-folder>

  # var backendSocketHost = "localhost"

  var env = newStringTable(modeStyleInsensitive)

  for name, value in envPairs():
    env[name] = value


  when defined(builtWithNix):
    env["NODE_PATH"] = nodeModulesPath

  let isSetBackendSocketPort = backendSocketPort.isSome
  let isSetFrontendSocketPort = frontendSocketPort.isSome
  let backendSocketPort = if backendSocketPort.isSome:
      backendSocketPort.get
    else:
      DEFAULT_SOCKET_PORT
  let frontendSocketPort = if frontendSocketPort.isSome:
      frontendSocketPort.get
    else:
      DEFAULT_SOCKET_PORT
  var traceId = -1

  if port < 0:
    errorMessage fmt"codetracer host: error: no valid port specified: {port}"
    quit(1)

  if isSetBackendSocketPort and not isSetFrontendSocketPort or
      not isSetBackendSocketPort and isSetFrontendSocketPort:
    errorMessage "codetracer host: error: pass either both backend and frontend port or neither"
    quit(1)

  try:
    traceId = traceArg.parseInt
  except CatchableError:
    # probably traceId is a folder
    # TODO don't depend on db?
    let traceFolder = traceArg
    var traceFolderFullPath = ""
    try:
      traceFolderFullPath = expandFilename(traceFolder)
    except OsError as e:
      echo "codetracer host error: folder os error: ", e.msg
      quit(1)
    var trace = trace_index.findByPath(traceFolderFullPath, test=false)
    if trace.isNil:
      trace = trace_index.findByPath(traceFolderFullPath & "/", test=false)
      if trace.isNil:
        echo "codetracer host error: trace not found: maybe you should import it first"
        quit(1)
    traceId = trace.id

  let callerPid = getCurrentProcessId()
  let recordCore = envLoadRecordCore()
  let coreProcess = startCoreProcess(traceId=traceId, recordCore=recordCore, callerPid=callerPid)
  # echo "server index ", codetracerExeDir
  var process = startProcess(
    electronExe,
    workingDir = codetracerInstallDir,
    args = @[
          codetracerExeDir / "server_index.js",
          $traceId,
          "--port",
          $port,
          "--frontend-socket-port",
          $frontendSocketPort,
          "--frontend-socket-parameters",
          frontendSocketParameters,
          # "--backend-socket-host",
          # backendSocketHost,
          "--backend-socket-port",
          $backendSocketPort,
          "--caller-pid",
          $callerPid
        ],
    env = env,
    options={poParentStreams})
  electronPid = process.processID
  echo "server_index exit code:", waitForExit(process)
  let code = waitForExit(coreProcess)
  echo "core exit code: ", code
  stopCoreProcess(coreProcess, recordCore)


proc startCore(traceArg: string, callerPid: int, test: bool) =
  # start_core <trace-program-pattern> <caller-pid> [--test]

  let recordCore = envLoadRecordCore()
  var trace: Trace = nil
  try:
    let traceId = traceArg.parseInt
    trace = trace_index.find(traceId, test=test)
  except ValueError:
    trace = trace_index.findByProgramPattern(traceArg, test=test)
  except CatchableError as e:
    errorMessage fmt"start core loading trace error: {e.msg}"
    quit(1)

  if trace.isNil:
    echo "error: start core: trace not found for ", traceArg
    quit(1)
  # echo trace.repr
  let process = startCoreProcess(traceId = trace.id, recordCore=recordCore, callerPid=callerPid, test=test)
  let code = waitForExit(process)
  discard code
  stopCoreProcess(process, recordCore)


proc importTraceInPreparedFolder(traceZipPath: string, outputFolderFullPath: string) =
  let res = execProcess(linksPath / "bin" / "unzip", args = @[traceZipPath, "-d", outputFolderFullPath], options={})
  echo res
  let traceMetadata = Json.decode(readFile(outputFolderFullPath / "trace_metadata.json"), Trace)
  let newTraceId = trace_index.newID(test=false)
  var importedTrace = traceMetadata
  importedTrace.id = newTraceId
  importedTrace.outputFolder = outputFolderFullPath
  importedTrace.imported = true
  let t = trace_index.recordTrace(importedTrace, test=false)
  discard t
  echo "recorded with id ", newTraceId


proc importCommand(traceZipPath: string, importedTraceFolder: string) =
  # codetracer import <trace-zip-path> [<imported-trace-folder>]
  let outputFolder = if importedTraceFolder.len > 0: importedTraceFolder else: changeFileExt(traceZipPath, "")

  # TODO: OVERWRITES the `outputFolder`, or an already imported trace there or other files!!!
  # think if we want to check and show an error if the folder exists?
  removeDir(outputFolder)

  createDir(outputFolder)
  let outputFolderFullPath = expandFilename(outputFolder)
  importTraceInPreparedFolder(traceZipPath, outputFolderFullPath)


proc storeTraceFiles(paths: seq[string], traceFolder: string, lang: Lang) =
  let filesFolder = traceFolder / "files"
  createDir(filesFolder)

  var sourcePaths = paths

  if lang == LangNoir:
    var baseFolder = ""
    for path in paths:
      if path.len > 0 and path.startsWith('/'):
        let originalFolder = path.parentDir
        if baseFolder.len == 0 or baseFolder.len > originalFolder.len and
            baseFolder.startsWith(originalFolder):
          baseFolder = originalFolder
    # assuming or at least trying for something like `<noir-project>/src/`
    if baseFolder.lastPathPart == "src":
      baseFolder = baseFolder.parentDir
    # adding baseFolder : if the top level of the noir project, hoping
    # that we copy Prover.toml, Nargo.toml, readme etc
    for pathData in walkDir(baseFolder):
      if pathData.kind == pcFile:
        sourcePaths.add(pathData.path)

    # echo baseFolder, " ", sourcePaths

  for path in sourcePaths:
    if path.len > 0:
      # echo "store path ", path
      let traceFilePath = filesFolder / path
      let traceFileFolder = traceFilePath.parentDir
      try:
        # echo "create ", traceFileFolder
        createDir(traceFileFolder)
        # echo "copy to ", traceFilePath
        copyFile(path, traceFilePath)
      except CatchableError as e:
        echo fmt"WARNING: trying to copy trace file {path} error: ", e.msg
        echo "  skipping copying that file"


proc importDbTrace(
    traceMetadataPath: string,
    traceIdArg: int,
    lang: Lang = LangNoir,
    selfContained: bool = true): Trace =
  let rawTraceMetadata = readFile(traceMetadataPath)
  let untypedJson = parseJson(rawTraceMetadata)
  let program = untypedJson{"program"}.getStr()
  let args = untypedJson{"args"}.getStr().splitLines()
  let workdir = untypedJson{"workdir"}.getStr()

  let traceID = if traceIdArg != NO_TRACE_ID:
      traceIdArg
    else:
      trace_index.newId(test=false)

  let traceFolder = traceMetadataPath.parentDir
  let tracePathsPath = traceFolder / "trace_paths.json"
  let tracePath = traceFolder / "trace.json"

  let outputFolder = fmt"{codetracerTraceDir}/trace-{traceID}/"
  if traceIdArg == NO_TRACE_ID:
    createDir(outputFolder)
    copyFile(traceMetadataPath, outputFolder / "trace_metadata.json")
    try:
      copyFile(tracePathsPath, outputFolder / "trace_paths.json")
    except CatchableError as e:
      echo "WARNING: probably no trace_paths.json: no self-contained support in this case:"
      echo "  ", e.msg
      echo "  skipping trace_paths file"
    copyFile(tracePath, outputFolder / "trace.json")

  var rawPaths: string
  try:
    rawPaths = readFile(tracePathsPath)
  except CatchableError as e:
    echo "warn: probably no trace_paths.json: no self-contained support for now:"
    echo "  ", e.msg
    echo "  skipping trace_paths file"

  var paths: seq[string] = @[]
  if rawPaths.len > 0:
    paths = Json.decode(rawPaths, seq[string])

  if selfContained:
    # for now assuming it happens on the original machine
    # when the source files are still available and unchanged
    if paths.len > 0:
      storeTraceFiles(paths, outputFolder, lang)

  var sourceFoldersInitialSet = initHashSet[string]()
  for path in paths:
    if path.len > 0 and path.startsWith('/'):
      sourceFoldersInitialSet.incl(path.parentDir)

  let sourceFolders = processSourceFoldersList(sourceFoldersInitialSet, workdir)
  # echo sourceFolders
  let sourceFoldersText = sourceFolders.join(" ")

  trace_index.recordTrace(
    traceID,
    program = program,
    args = args,
    compileCommand = "",
    env = "",
    workdir = workdir,
    lang = lang,
    sourceFolders = sourceFoldersText,
    lowLevelFolder = "",
    outputFolder = outputFolder,
    test = false,
    imported = selfContained,
    shellID = -1,
    rrPid = -1,
    exitCode = -1,
    calltrace = true,
    # for now always use FullRecord for db-backend
    # and ignore possible env var override
    calltraceMode = CalltraceMode.FullRecord)


proc replaySummary(traceId: int, summaryOutputPath: string) =
  let recordCore = envLoadRecordCore()
  var trace = trace_index.find(traceId, test=false)
  if not trace.isNil:
    discard runRecordedTrace(trace, test=false, repl=true, summary=true, summaryOutputPath=summaryOutputPath, recordCore=recordCore)
  else:
    echo "error: codetracer summary: trace not found for ", traceId


proc summary(traceId: int, summaryOutputPath: string) =
  # codetracer summary <trace-id> <summary-output-path>
  replaySummary(traceId, summaryOutputPath)


# proc sendBugReportAndLogsCommand(title: string, description: string, instance: string, confirmSend: bool) =
#   var api = newApi()
#   let (response, exitCode) = api.uploadBugReport(
#     title, description, "bug-reports",
#     instance, confirmSend)
#   echo response
#   quit(exitCode)


proc traceMetadata(
    idArg: Option[int], pathArg: Option[string],
    programArg: Option[string], recordPidArg: Option[int],
    recent: bool, recentLimit: int, test: bool) =
  if idArg.isSome:
    let trace = trace_index.find(idArg.get, test)
    echo Json.encode(trace)
  elif pathArg.isSome:
    var path = pathArg.get
    if path.len > 2 and path.startsWith('"') and path.endsWith('"'):
      path = path[1..^2]
    let trace = trace_index.findByPath(path, test)
    echo Json.encode(trace)
  elif programArg.isSome:
    let trace = trace_index.findByProgramPattern(programArg.get, test)
    echo Json.encode(trace)
  elif recordPidArg.isSome:
    let trace = trace_index.findByRecordProcessId(recordPidArg.get, test)
    echo Json.encode(trace)
  elif recent:
    let traces = trace_index.findRecentTraces(limit=recentLimit, test)
    echo Json.encode(traces)
  else:
    echo "null"


# let callerPid = getCurrentProcessId()


proc cleanup*: void {.noconv.} =
  echo "codetracer: cleanup!"
  if not onInterrupt.isNil:
    onInterrupt()
  # important: signal handlers should be
  # signal-safe https://man7.org/linux/man-pages/man7/signal-safety.7.html

  # Franz found an issue
  # https://gitlab.com/metacraft-labs/code-tracer/CodeTracer/-/merge_requests/116#note_1360620095
  # which shows maybe we need to stop the electron process if not stopped too
  if electronPid != -1:
    discard kill(electronPid.Pid, SIGKILL)


onSignal(SIGINT):
  cleanup()
  quit(1)


# onSignal(SIGKILL):
#   cleanup()
#   quit(0)


onSignal(SIGTERM):
  cleanup()
  quit(0)


# proc runCommandWithCurrentBackend(conf: CodetracerConf) =
proc notSupportedCommand(commandName: string) =
  echo fmt"{commandName} not supported with this backend"


# workaround because i can't change conf interactive fields here
# as it's an object(maybe i can just pass it as var?)
# still a bit easier to be directly boolean, not an option
# after validation
var replayInteractive = false

proc getGitRootDir(): string =

  try:

    let gitExe = findExe("git")

    let process = startProcess(
      gitExe,
      args = @["rev-parse", "--show-toplevel"],
      options = {poStdErrToStdOut}
    )

    let output = process.outputStream.readAll().strip()

    let exitCode = waitForExit(process)

    if exitCode == 0:
      return output
    else:
      raise newException(ValueError, "Getting the git project's root level failed")

  except:
    raise newException(OSError, "Something went wrong with getting the git project's root level")

proc runInitial(conf: CodetracerConf) =
  # TODO should this be here?
  workaroundIntelECoreProblem()

  case conf.cmd:
    of StartupCommand.install:
      let rootDir = when defined(withTup): getGitRootDir() & "/" else: linksPath & "/"

      when defined(macosx):
        let
          appDir = getAppDir()
          parentDir = appDir.parentDir
          inBundle = appDir.endsWith("/bin") and parentDir.endsWith("/MacOS")
          appLocation = if inBundle:
            # Skip over the Contents directory
            parentDir.parentDir.parentDir
          else:
            getAppFilename()
          appLocationFile = appInstallFsLocationPath()

        try:
          createDir appLocationFile.parentDir
        except CatchableError as err:
          echo "Failed to create directory for app location file: " & err.msg
          quit 1

        try:
          writeFile appLocationFile, appLocation
        except CatchableError as err:
          echo "Failed to create the app location file: " & err.msg
          quit 1

      if conf.installCtOnPath:
        echo "About to install on PATH"
        let status = installCodetracerOnPath(codetracerExe)
        if status.isErr:
          echo "Failed to install CodeTracer: " & status.error
          quit 1

      when defined(linux):
        if conf.installCtDesktopFile:
          installCodetracerDesktopFile(linksPath, rootDir, codetracerExe)

      quit(0)

    of StartupCommand.replay:
      let shouldRestart = replay(
        conf.lastTraceMatchingPattern,
        conf.replayTraceId,
        conf.replayTraceFolder,
        replayInteractive
      )
      if shouldRestart:
        quit(RESTART_EXIT_CODE)
    of StartupCommand.noCommand:
      let workdir = codetracerInstallDir

      # sometimes things like "--no-sandbox" are useful e.g. for now for
      # experimenting with appimage
      # let optionalElectronArgs = getEnv("CODETRACER_ELECTRON_ARGS", "").splitWhitespace()
      discard launchElectron()
      # var processUI = startProcess(
      #   electronExe,
      #   workingDir = workdir,
      #   args = @[electronIndexPath].concat(optionalElectronArgs),
      #   options={poParentStreams})
      # electronPid = processUI.processID
      # echo "status code:", waitForExit(processUI)
    # of StartupCommand.ruby:
    #   runCompilerProcess(
    #     "ruby",
    #     conf.rubyArgs)
    # of StartupCommand.python:
    #   notSupportedCommand(conf.cmd)
    # of StartupCommand.lua:
    #   notSupportedCommand(conf.cmd)
    # of StartupCommand.nim:
    #   notSupportedCommand(conf.cmd)
    of StartupCommand.list:
      listCommand(conf.listTarget, conf.listFormat)
    of StartupCommand.help:
      displayHelp()
    of StartupCommand.version:
      echo "CodeTracer ", when defined(debug): "debug " else: "", CodeTracerVersionStr
    of StartupCommand.console:
      # similar to replay
      notSupportedCommand($conf.cmd)
    of StartupCommand.upload:
      # similar to replay/console
      # eventually enable?
      uploadCommand(
        conf.uploadLastTraceMatchingPattern,
        conf.uploadTraceId,
        conf.uploadTraceFolder,
        replayInteractive)
    of StartupCommand.download:
      notSupportedCommand($conf.cmd)
      # eventually enable?
      # downloadCommand(conf.traceRegistryId)
    # of StartupCommand.build:
    #   notSupportedCommand($conf.cmd)
      # eventually enable if needed?
      # build(conf.buildProgramPath, conf.buildOutputPath)
    of StartupCommand.record:
      # TODO: maybe with more confutils
      # enforcement of order
      # record(conf.recordOutputFolder, conf.recordExportFile, conf.recordLang, conf.recordProgram, conf.recordProgramArgs)
      discard record(conf.recordArgs)
    of StartupCommand.run:
      run(conf.runTracePathOrId, conf.runArgs)
    of StartupCommand.start_core:
      startCore(conf.coreTraceArg, conf.coreCallerPid, conf.coreInTest)
    # of StartupCommand.host:
    #   host(
    #     conf.hostPort,
    #     conf.hostBackendSocketPort, conf.hostFrontendSocketPort,
    #     conf.hostFrontendSocketParameters, conf.hostTraceArg)
    # of StartupCommand.`import`:
    #   importCommand(conf.importTraceZipPath, conf.importOutputPath)
    # of StartupCommand.`import-db-trace`:
    #   discard importDbTrace(conf.importDbTracePath, NO_TRACE_ID)
    # of StartupCommand.summary:
    #   summary(conf.summaryTraceId, conf.summaryOutputFolder)
    # of StartupCommand.`report-bug`:
    #   sendBugReportAndLogsCommand(conf.title, conf.description, conf.pid, conf.confirmSend)
    of StartupCommand.`trace-metadata`:
      traceMetadata(
        conf.traceMetadataIdArg, conf.traceMetadataPathArg,
        conf.traceMetadataProgramArg, conf.traceMetadataRecordPidArg,
        conf.traceMetadataRecent,
        conf.traceMetadataRecentLimit,
        conf.traceMetadataTest)


proc customValidate(conf: CodetracerConf) =
  case conf.cmd:
    of StartupCommand.replay, StartupCommand.console, StartupCommand.upload:
      let r = conf.cmd == StartupCommand.replay
      discard r
      let lastTraceMatchingPattern = case conf.cmd:
        of StartupCommand.replay:
          conf.lastTraceMatchingPattern
        of StartupCommand.console:
          conf.consoleLastTraceMatchingPattern
        else: # possible only StartupCommand.upload:
          conf.uploadLastTraceMatchingPattern


      let (traceId, traceFolder, interactive) =
        case conf.cmd:
        of StartupCommand.replay:
          (conf.replayTraceId,
           conf.replayTraceFolder,
           conf.replayInteractive)
        of StartupCommand.console:
          (conf.consoleTraceId,
           conf.consoleTraceFolder,
           conf.consoleInteractive)
        else: # possible only StartupCommand.upload:
          (conf.uploadTraceId,
           conf.uploadTraceFolder,
           conf.uploadInteractive)

      let isSetPattern = lastTraceMatchingPattern.isSome
      let isSetTraceId = traceId.isSome
      let isSetTraceFolder = traceFolder.isSome
      let isSetInteractive = interactive.isSome
      let setArgsCount = isSetPattern.int + isSetTraceId.int +
        isSetTraceFolder.int + isSetInteractive.int
      if setArgsCount > 1:
        errorMessage "configuration error: expected no more than one arg to command to be passed"
        echo "Try `codetracer --help` for more information"
        quit(1)
      if not isSetPattern and not isSetTraceId and not isSetTraceFolder:
        replayInteractive = true
      elif isSetInteractive:
        replayInteractive = interactive.get
      else:
        replayInteractive = false
    else:
      discard


try:
  let conf = CodetracerConf.load()
  customValidate(conf)
  runInitial(conf)
except Exception as ex:
  echo "Unhandled exception"
  echo getStackTrace(ex)
  error "error: unhandled " & ex.msg
