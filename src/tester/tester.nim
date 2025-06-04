import
  std / [strformat, os, osproc, strutils, terminal, sequtils, streams, sets, strtabs, json, tables],
  json_serialization

import .. / common / [intel_fix, paths, lang, summary]

import ../common/types except
  codetracerTestDir, codetracerExe, codetracerInstallDir, codetracerExeDir

import parallel_tester

const RR_GDB_TEST_SUPPORTED_LANGS = @[LangC, LangRust, LangNim]
const CORE_TEST_SUPPORTED_LANGS = @[LangC, LangRust, LangNim]
# TODO: fix nix/ci support for cpython: LangPython?

const BUILD_SUPPORTED_LANGS = @[LangC, LangCpp, LangRust, LangNim, LangGo]

const ENABLED_TEST_PROGRAMS = @["fibonacci", "longer_program", "rr_gdb", "quicksort", "various_calls"]
const GREEN_COLOR = "\x1b[32m"

# not building for now:  "ui_simple" "one_hundred_iterations", "calc"

proc loadTests(path: string, arg: string, endsToken: string): seq[string] =
  echo "loadTests ", path, " ", arg
  for kind, name in walkDir(path):
    # echo name
    if name.endswith(endsToken) and (arg.len == 0 or '.' in arg or arg in name):
      result.add(name)


proc generateExamples(programName: string) =
  # generates or regenerates folder/file structure for example test programs
  # if it exists, tries to overwite only Tupfile-s to make it easy
  # to change all of them in one go
  # =>
  # tests/
  #   programs/
  #     <programName>/
  #       <ext>/ # for each supported lang
  #         program.<ext> # eventually with default content
  #         Tupfile # with default content:
  #
  # Tupfile:
  # ```
  # : program.<ext> | codetracer |> codetracer record_test <programName>.<ext> ../../../binaries/<programName>_<ext> |> ../../../binaries/<programName>_<ext>
  # ```
  echo programName
  assert programName.len > 0
  createDir programDir
  createDir programDir / programName
  for lang in SUPPORTED_LANGS:
    let ext = getExtension(lang)
    createDir programDir / programName / ext
    if not fileExists(programDir / programName / ext / fmt"{programName}.{ext}"):
      writeFile(programDir / programName / ext / fmt"{programName}.{ext}", "")
    # TODO fix codetracer in tup issue
    # let tupfileContent = ""
    # fmt": program.{ext} | ../../../../codetracer |>  " &
    #                     #  fmt"codetracer record_test {programName}.{ext} ../../../binaries/{programName}_{ext} |> " &

    #                      fmt"../../../binaries/{programName}_{ext}"
    # writeFile(programDir / programName / ext / "Tupfile", tupfileContent)

# proc run_core_test(arg: string, args: seq[string], noQuit: bool = false) =
#   let tests = @[codetracerExeDir / "ui_test_simple"] # loadTests(runDir, arg, "_test")
#   var replStatus = 0
#   let argsText = args.join(" ")
#   for test in tests:
#     let status = execShellCmd(fmt("{bashExe} -c \"{test} {argsText}\""))
#     if status == 0:
#       styledWriteLine stderr, fgGreen, "OK", resetStyle
#     else:
#       replStatus = 1
#       styledWriteLine stderr, fgRed, "ERROR", resetStyle
#   if replStatus != 0 or not noQuit:
#     quit(replStatus)

# const SUPPORTED_LANGUAGES_COUNT = 5

proc stopRRGdbAndInternalProcesses =
  # again, hopefully a temporary workaround
  # WARNING: stops/breaks any another parallelly
  # running test/codetracer instances


  let command =
    if getEnv("GITLAB_CI_BUILD", "") != "":
      "pkill -9 rr; pkill -9 gdb; pkill -9 dispatcher; pkill -9 task_process; pkill -9 sleep;"
    else:
      "killall -9 rr gdb dispatcher task_process sleep"
  echo "stopRRGdbAndInternalProcesses: ", command
  discard execShellCmd(command)


proc runUITests(args: seq[string], noQuit: bool = false) =
  let tests = loadTests(
    codetracerTestBuildDir,
    if args.len > 0: args[0] else: "",
    ".js")
  let argsText = args.join(" ")
  var userInterfaceTestsStatus = 0

  putEnv("CODETRACER_IN_TEST", "1")

  if tests.len == 0:
    styledWriteLine(
      stderr,
      fgRed,
      "ERROR: expected at least one test (or one test matching pattern)",
      resetStyle)
    quit(1)
  for test in tests:
    stopRRGdbAndInternalProcesses()

    discard execShellCmd(fmt("{bashExe} -c \"rm -rf ~/.config/codetracer\""))

    echo fmt("{bashExe} -c \"{electronExe} {test} {argsText}\"")
    # easier to ignore stderr like that:
    # we want to ignore the electron errors/stderr for
    # starting each suite module and each electron instance in
    # the tests
    # currently outputting the test prints to stdout
    let shellResult = execShellCmd(fmt("{bashExe} -c \"{electronExe} {test} {argsText} 2> /dev/null\""))

    if shellResult == 0:
      styledWriteLine stderr, fgGreen, "OK", resetStyle
    else:
      userInterfaceTestsStatus = 1
      styledWriteLine stderr, fgRed, "ERROR", resetStyle

    stopRRGdbAndInternalProcesses()

  quit(userInterfaceTestsStatus)

  # for setup in UI_TEST_SETUPS:
  #   let status = runUITest(setup, args, isElectron=true) # &"{node} {test} {argsText}")
  #   if status == 0:
  #     styledWriteLine stderr, fgGreen, "OK", resetStyle
  #   else:
  #     userInterfaceTestsStatus = 1
  #     styledWriteLine stderr, fgRed, "ERROR", resetStyle
  # if userInterfaceTestsStatus != 0:
  #   quit(userInterfaceTestsStatus)
  #   # TODO think of a better way to do it
  #   # discard execShellCmd("killall electron rr gdb && sleep 1 && killall electron")


# tester watch
# track tests/programs/<name>/<ext>/files
# on change(for now directly in directories only/not built/start):
#   run build and record
#
# tester prepare
#   build and record again all
#
# until we think of maybe timestamp/db-based prepare/watch
# or just find a fix/workaround for the tup situation

func loadFilterArg(args: seq[string]): string =
  if args.len == 0 or args[0].len == 0:
    ""
  else:
    args[0]

proc extractMarkers() =
  var allMarkers = initTable[string, Table[string, int]]()
  for filename in walkDirRec(programDir):
    let (_, _, ext)= splitFile(filename)
    if ext.len > 0 and toLang(ext[1..^1]) in BUILD_SUPPORTED_LANGS:
      var currentMarkers = initTable[string, int]()
      var linenum = 0
      var found = false
      for line in lines(filename):
        linenum.inc
        if line.contains("marker:"):
          found = true
          var marker = line[line.find("marker:")+8..^1]
          currentMarkers[marker] = linenum
      if found:
        allMarkers[filename] = currentMarkers
  writeFile(codetracerTestDir / "markers.json", pretty(%* allMarkers))

proc build(args: seq[string]) =
  # remove test trace db if existing!
  let test = true
  removeFile(DB_PATHS[test.int])

  let filterArg = loadFilterArg(args)
  if filterArg.len == 0: # build all
    assert tryRemoveFile(fmt"{codetracerTestDir}/trace-index.db")


  echo "build:"

  if filterArg.len == 0:
    removeDir recordDir
  createDir recordDir

  var traceId = 0 # just a trace id: important to be unique for a trace

  for (kind, program) in walkDir(programDir, relative=true):
    echo "kind ", kind, " program ", program
    if kind == pcDir and program in ENABLED_TEST_PROGRAMS:
      echo "dir ", programDir / program
      if (filterArg == "" or program in filterArg):
        for (extKind, ext) in walkDir(programDir / program, relative=true):
          # echo "ext ", ext, " extKind ", extKind
          let lang = toLang(ext)
          if extKind == pcDir and lang in BUILD_SUPPORTED_LANGS:
            # TODO: improve this
            if (program == "longer_program" or program == "rr_gdb") and lang notin {LangC, LangRust, LangNim}:
              continue
            let name = fmt"{program}_{ext}"
            echo "==================="
            styledWriteLine stdout, GREEN_COLOR, "building ", program, " for ", ext, resetStyle
            if filterArg.len == 0 or filterArg in name:
              removeDir recordDir / fmt"trace-{traceId}"
              let sourcePath = programDir / program / ext / fmt"{program}.{ext}"
              let binaryPath = testProgramBinariesDir / name
              createDir testProgramBinariesDir
              # TODO detect some db schema problems in codetracer itself: make this hang
              var process = startProcess(
                codetracerExe,
                workingDir=codetracerInstallDir,
                args = @[
                  "record_test",
                  $traceId,
                  binaryPath,
                  sourcePath
                ],
                options={poEchoCmd, poParentStreams, poStdErrToStdOut})
              let code = waitForExit(process)
              if code != 0:
                styledWriteLine stdout, fgRed, "ERROR: ", $code, resetStyle
                quit(1)
              echo "==================="
            traceId += 1
  if filterArg.len == 0 or "rr_gdb" in filterArg:
    let rrGdbLangs =
      if filterArg == "" or filterArg == "rr_gdb" or filterArg == "rr_gdb_":
        RR_GDB_TEST_SUPPORTED_LANGS
      else:
        @[toLang(filterArg["rr_gdb_".len..^1])]

  # # TODO let programs = loadPrograms(arg)
  # let programs = @[
  #   # (1, "sum.nim", "sum", true, LangNim),
  #   # (2, "ui_small.nim", "ui_small", true, LangNim),
  #   # (3, "coroutine.nim", "coroutine", true, LangNim),
  #   # (1, "sum.nim", "sum_no_cg", false, LangNim),
  #   # TODO: more detailed calltrace options?
  #   (1, "ui_simple_c.c", "ui_simple_c", false, LangC),
  #   (2, "ui_simple_cpp.cpp", "ui_simple_cpp", false, LangCpp),
  #   (3, "ui_simple_rs.rs", "ui_simple_rs", false, LangRust),
  #   # (4, "ui_simple_nim.nim", "ui_simple_nim", false, LangNim),
  #   (5, "ui_simple_go.go", "ui_simple_go", false, LangGo)
  #   # (3, "coroutine.nim", "coroutine_no_cg", false, LangNim)]
  #   # (4, "qsort.c", "qsort_c", LangC),
  #   # (5, "find.c", "find_c", LangC),
  #   # (6, "qsort.cpp", "qsort_cpp", LangCpp),
  #   # (7, "find.cpp", "find_cpp", LangCpp)]
  # ]
  # for program in programs:
  #   let input = programDir / &"{program[1]}"
  #   let output = programDir / program[2]
  #   let calltraceEnabled = program[3]
  #   let lang = program[4]
  #   let record = recordDir / &"trace-{program[0]}"
  #   shell &"rm -rf {record}"
  #   var calltrace = ""
  #   if calltraceEnabled:
  #     calltrace = "--calltrace"

  #   shell &"{codetracerExe} record_test {program[0]} {output} {input} {calltrace}"

var scriptsStatusCode = 0

# TODO improve
const DEBUG_GDB_PATH = "/home/al/cpython/result/bin/gdb" # "/nix/store/76sy7nykmc4p3k1rs3rsbkb598xd4k10-gdb-12.1/bin/gdb"

let codetracerTmpDir = "/tmp/codetracer/"

proc processArgs(args: seq[string], testScript: string, defaultLangs: seq[Lang]): (bool, bool, seq[Lang]) =
  var runTest = true
  var langs = defaultLangs
  if args.len == 0:
    runTest = true
  else:
    var allLangs = true
    var langSet = initHashSet[Lang]()
    for arg in args:
      if arg.len == 0 or arg[0] != '.':
        let filterArg = arg
        let filterMatch = filterArg.len == 0 or (filterArg.len > 0 and filterArg in testScript)
        runTest = runTest and filterMatch
      else:
        let langExtArg = arg
        let lang = toLang(langExtArg[1..^1])
        if lang != LangUnknown:
          allLangs = false
          langSet.incl(lang)

    langs = if allLangs:
        defaultLangs
      else:
        toSeq(langSet)

  let recordInGdb = args.len > 1 and args[1] == "--record-in-gdb"
  echo (runTest, recordInGdb, langs)
  (runTest, recordInGdb, langs)


proc runCoreTest(
    lang: Lang,
    testProgramRecordPath: string,
    testProgramSourcePath: string,
    testBinaryPath: string) =

  putEnv("CODETRACER_IN_TEST", "1")

  let process = startProcess(
    testBinaryPath,
    args = @[fmt".{getExtension(lang)}"],
    workingDir = codetracerInstallDir,
    options = {poEchoCmd, poParentStreams})
  let code = waitForExit(process)
  if code == 0:
    styledWriteLine stderr, fgGreen, "OK", resetStyle
  else:
    styledWriteLine stderr, fgRed, "ERROR", resetStyle


proc runCoreTests*(args: seq[string]) =
  # echo "run core tests"
  for kind, testProgram in walkDir(codetracerTestDir / "example-based"):
    if kind == pcFile:
      let programName = testProgram.lastPathPart
      if programName.startsWith("core_") and programName.endsWith("_test.nim"):
        let (runTest, recordInGdb, langs) = processArgs(args, programName, CORE_TEST_SUPPORTED_LANGS)
        discard recordInGdb
        if runTest:
          for lang in langs:
            let name = fmt"core_test_program_{getExtension(lang)}"
            let testBinaryName = programName.splitFile.name
            echo fmt"run core test {testBinaryName}"
            runCoreTest(lang, recordDir / name, programDir / name, codetracerTestBuildDir / testBinaryName)


proc runPropertyTest(args: seq[string]) =
  putEnv("CODETRACER_IN_TEST", "1")
  let process = startProcess(
    codetracerExeDir / "tests" / "property_test",
    workingDir = codetracerInstallDir,
    args = args,
    options = {poParentStreams})
  let code = waitForExit(process)
  quit(code)

proc runUiPropertyTest(args: seq[string]) =
  let process = startProcess(
    codetracerExeDir / "tests" / "ui_property_test",
    workingDir = codetracerInstallDir,
    args = args,
    options = {poParentStreams})
  let code = waitForExit(process)
  quit(code)

let shell_test = codetracerExeDir / "shell_test"
let shellProgramsDir = codetracerTestDir / "shell-programs"

let EXPECTED_SUMMARIES = @[
  Json.encode(replaySummaryForEntry(shellProgramsDir / "example.c", 3)),
  # TODO eventually others
]

# echo EXPECTED_SUMMARIES

proc cleanupCodetracerFiles =
  removeFile DB_PATHS[0]
  echo execShellCmd(fmt"rm -rf {reportFilesDir}/*")

proc setupLdLibraryPath =
  # we set it here explicitly, so calling codetracer(from ct) can work:
  # explanation
  # (copied from original commit that comments it out from the devshell):
  #
  # fix: don't set LD_LIBRARY_PATH in shell, but only for needed ops
  #
  # in https://discourse.nixos.org/t/what-package-provides-libstdc-so-6/18707/5
  # and from our xp this seems true even if i didn't think
  # it's important: setting things like this can break other software
  # e.g. nix wasn't working because of clash between itc GLIBC version
  # and some from those LD_LIBRARY_PATH
  # 
  # so we pass it in tester explicitly where needed
  # and this already happens in `ct`: however this breaks for now
  # `codetracer`, but not sure what to do there: maybe pass it as well?
  # (however it itself needs the sqlite path)
  putEnv("LD_LIBRARY_PATH", getEnv("CT_LD_LIBRARY_PATH", ""))

proc help(subcommand: string) =
  if subcommand.len == 0:
    echo """
      tester build [<program-name-pattern>]
      tester ui [args]
      tester rr-gdb-scripts [<test-file-name-pattern>] [.<lang-extension>] [--record-in-gdb]
      tester shell [<test-name-pattern>]
      tester property [<program-name-pattern>] [<property-test-args>]; use `tester help property`
      tester ui-property [<program-name-pattern>] [--strategy:<strategy-and-args>]; use `tester help ui-property`
      tester help
      tester parallel [<test set>] [<options>]

      [args]: [.<lang-ext>] [<test-name-pattern>]

      e.g.

      tester ui .c
      tester ui events
      tester ui .c events
      tester rr-gdb-scripts val
      tester rr-gdb-scripts val --record-in-gdb
      tester property loop_c
      tester build rr_gdb_c

      ----
      tester parallel:
    """
    parallelHelp()

  elif subcommand == "property":
    echo """
    tester property <program-name> [<program-args>] [--strategy:<strategy>] [--callstack] [--flow] [--locals]

    <strategy>:
      "step-in-limited <callstack-limit> <steps-in-call-limit> [until-stdlib]":
        runs step-in under <callstack-limit> calls deep or <steps-in-call-limit> count of steps,
        on <callstack-limit> depth steps out once; -1 means no limit
        on <steps-in-call-limit> steps out once; -1 means no limit
        if until-stdlib passed: steps out if path seems to be in stdlib
      "co-step-in-limited <callstack-limit> <steps-in-call-limit> [until-stdlib]":
        runs co-step-in under <callstack-limit> calls deep or <steps-in-call-limit> count of steps,
        on <callstack-limit> depth steps out once with step-out; -1 means no limit
        on <steps-in-call-limit> steps out once with step-out; -1 means no limit
        if until-stdlib passed: steps out if path seems to be in stdlib
      default: "step-in-limited -1 -1"

    e.g.

    tester property loop_c
    """
  elif subcommand == "ui-property":
    echo """
    tester ui-property <program-name> [<program-args>] [--strategy:<strategy>]

    <strategy>: "<strategy-name> [<arg> <arg2> ..]"

    e.g.

    tester ui-property loop_c --strategy:simple
    """
  else:
    echo """
      no specific help for this subcommand
    """

  # TODO tester repl [args]
  # tester run-all [args] (args can contain flags and max one path:arg)
proc run(command: string, args: seq[string] = @[]) =
  case command:
  of "build":
    setupLdLibraryPath()
    build(args)
    extractMarkers()
  of "core":
    setupLdLibraryPath()
    runCoreTests(args)
  of "ui":
    setupLdLibraryPath()
    runUITests(args)
  # of "run-all":
  #   echo "build"
  #   build(arg)
  #   # echo "test repl"
  #   # repl(arg, args, noQuit=true)
  #   echo "test ui"
  #   ui(arg, args, noQuit=true)
  of "examples":
    if args.len > 0:
      generateExamples(args[0])
    else:
      echo "error: expected a program name for examples"
      quit(1)
  of "property":
    setupLdLibraryPath()
    runPropertyTest(args)
  of "ui-property":
    setupLdLibraryPath()
    runUiPropertyTest(args)
  of "parallel":
    setupLdLibraryPath()
    quit(runTestSets(args))
  else:
    let possibleSubcommand = if args.len > 0:
        args[0]
      else:
        ""
    help(possibleSubcommand)


proc ctrlCHandler() {.noconv.} =
  echo "Stopped because ctrlCHandler was triggered by pressing c ctrl+c in the command line"
  quit 1

setControlCHook(ctrlCHandler)



# TODO: This shouldn't be necessary here
#       Why is this module calling RR directly?
#       It should be testing the CodeTracer executable file instead.
workaroundIntelECoreProblem()

# tester build
# tester core "calltrace"
if paramCount() == 1:
  run(paramStr(1), @[])
elif paramCount() > 1:
  var args = newSeq[string]()
  for i in 2 .. paramCount():
    args.add(paramStr(i))
  run(paramStr(1), args)
else:
  help("")
