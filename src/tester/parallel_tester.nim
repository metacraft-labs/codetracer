import
  std / [strformat, os, osproc, strutils, terminal, sequtils, streams, strtabs, tables, times, parseopt, re]
import .. / common / [paths, lang]

# API

const SUPPORTED_LANGS = @[LangC, LangRust, LangNim]
let codetracerTmpDir = "/tmp/codetracer/"
let maxProcessLimit = max(countProcessors() - 2, 1) # make sure at least one

type
  TestRunnerState = enum
    trsCreated, trsRunning, trsFinished

  TestScriptState = enum
    tssCreated, tssEnqueued, tssRunning, tssFinished, tssFailed, tssSkipped

  Verbosity = enum
    vQuiet = (0, "quiet") # minimum output
    vErrors = (1, "error") # show errors from logs
    vInfo = (2, "info") # show test cases
    vAll = (3, "full") # echo full logs

  Status = enum
    sSuccess
    sError
    sTimeout
    sSkipped

  Run = enum
    rRun
    rSkip

  # Keeps track of running processes and generates final report
  TestRunner = ref object
    reportPath*: string # path to report file
    state*: TestRunnerState
    processResult*: int
    processLimit*: int
    initialTests*: int
    runningTestScripts*: seq[TestScript]
    testScriptsQueue*: seq[TestScript]
    finishedTestScripts*: seq[TestScript]
    verbosity*: Verbosity
    reportRealtime*: bool
    testSets*: Table[string, TestSet]

  # Represents individual test scripts being run by the runner.
  # Each one runs in separate process and has it's own log
  TestScript = ref object
    name*: string
    lang*: Lang
    testSet*: TestSet
    processExe*: string
    outputFile*: string
    processArgs*: seq[string]
    inputLines*: seq[string] # sequence of strings to be written to the standart input of the test script process
    processStartedAt*: Time
    process*: Process
    state*: TestScriptState
    skip*: bool
    reportRealtime*: bool

  # Represents grouping of similar test scripts
  # Each one describes how each test script in the set should be run
  TestSet = ref object of RootObj
    testPath*: string # Path where the test files are stored
    tests*: Table[string, Table[Lang, Run]]
    processOptions*: set[ProcessOption]
    outputPath*: string
    processWorkingDir*: string
    logTestPattern*: Regex # Regex to extract the test case name from the test script log file
    logErrorPattern*: Regex # Regex to extract the error report from the test script log file
    defaultTimeout*: Duration

method initTestScript(self: TestSet, name: string, lang: Lang, skip: bool, reportRealtime: bool): TestScript {.base.} =
  # Create test script based on values in the TestSet.
  result = TestScript(
    name: name,
    lang: lang,
    testSet: self,
    processExe: bashExe,
    processArgs: newSeq[string](),
    inputLines: newSeq[string](),
    outputFile: self.outputPath / fmt("{splitFile(name)[1]}-{toName(lang)}"),
    state: tssCreated,
    skip: skip,
    reportRealtime: reportRealtime,
  )

iterator testScripts(self: TestSet, pattern: string, langs: seq[Lang], reportRealtime: bool): TestScript =
  for (testScriptName, config) in self.tests.mpairs:
    for (lang, skip) in config.mpairs:
      var path = self.testPath / testScriptName
      case skip:
        of rRun:
          let skipBecauseLang = lang notin langs
          let skipBecausePattern = pattern.len > 0 and pattern notin testScriptName
          # debugecho path, " ", skipBecauseLang, " ", skipBecausePattern, " [", pattern, "]"
          yield self.initTestScript(name=path, lang, skipBecauseLang or skipBecausePattern, reportRealtime)
        of rSkip:
          yield self.initTestScript(name=path, lang, true, reportRealtime)

proc startTestScript(self: TestScript, env: StringTableRef) =
  # Start the test script process and write the input lines to standard input.
  let processOptions = if not self.reportRealtime:
      self.testSet.processOptions
    else:
      self.testSet.processOptions + {poParentStreams}
  self.process = startProcess(
    command = self.processExe,
    args = self.processArgs,
    workingDir = self.testSet.processWorkingDir,
    env = env,
    options = processOptions)
  self.state = tssRunning
  self.processStartedAt = getTime()
  for line in self.inputLines:
    self.process.inputStream.writeLine(line)
    self.process.inputStream.flush()


proc setProcessLimit(self: TestRunner, val: int) =
  if 0 < val and val <= maxProcessLimit:
    self.processLimit = val
  else:
    styledWriteLine stderr, fgYellow, fmt"""
Warning: The process limit you supplied ({val}) must be between 1 and {maxProcesslimit},
proceeding with default value {self.processLimit}
"""

proc enqueTestScripts(self: TestRunner, testSetName: string, pattern: string, langs: seq[Lang]) =
  var testSets = newSeq[TestSet]()
  # If test set name is not in the test runners registered test sets, enqueue all
  if self.testSets.hasKey(testSetName):
    testSets.add(self.testSets[testSetName])
  else:
    for key, val in self.testSets:
      testSets.add(val)
  for testSet in testSets:
    createDir testSet.outputPath
    for testScript in testSet.testScripts(pattern, langs, self.reportRealtime):
      self.testScriptsQueue.add(testScript)
      testScript.state = tssEnqueued

proc reportTestScript(self: TestScript, done: int, total: int, status: Status, verbosity: Verbosity) =
  # Generate a report for individual test scripts once the process is finished and write it to stderr.
  # color and status args describe the type of message, for example fgRed and "Error" are for failed tests.
  # function also takes into account verbosity setting of the test runner.
  #
  # Don't write full log if reportRealtime passed, as it should've been already printed.

  var color: ForegroundColor
  var message: string

  case status:
    of sSuccess:
      color = fgGreen
      message = " OK"
      self.state = tssFinished
    of sError:
      color = fgRed
      message = " ERROR"
      self.state = tssFailed
    of sTimeout:
      color = fgYellow
      message = " TIMEOUT"
      self.state = tssFailed
    of sSkipped:
      color = fgBlue
      message = " Skipped"
      self.state = tssSkipped

  if verbosity != vQuiet:
    write stderr, fmt("[{done+1}/{total}] Script: {extractFileName(self.name)} Lang: {toName(self.lang)}")
    styledWrite stderr, color, message
    write stderr, "\n"
    if status != sSkipped:
      if verbosity == vAll:
        if not self.reportRealtime:
          write stderr, readFile(self.outputFile)
      else:
        if verbosity == vInfo:
          write stderr, "\n"
          for match in findAll(readFile(self.outputFile), self.testSet.logTestPattern):
            writeLine stderr, fmt"  {match}"

        if verbosity in {vInfo, vErrors}:
          for match in findAll(readFile(self.outputFile), self.testSet.logErrorPattern):
            write stderr, "\n"
            write stderr, match
            write stderr, "\n"

    write stderr, "\n"
  else:
    write stderr, "."

proc report(self: TestRunner) =
  # Generate final report
  var ran = self.finishedTestScripts.len
  var success = self.finishedTestScripts.filter(proc(s: TestScript): bool = s.state == tssFinished)
  var fail = self.finishedTestScripts.filter(proc(s: TestScript): bool = s.state == tssFailed)
  var skipped = self.finishedTestScripts.filter(proc(s: TestScript): bool = s.state == tssSkipped)
  echo ""
  echo fmt"Ran {ran} tests on {self.processLimit} threads"
  styledWriteLine stderr, fgGreen, fmt"{success.len} OK", resetStyle
  styledWriteLine stderr, fgRed, fmt"{fail.len} ERROR", resetStyle
  if skipped.len != 0:
    styledWriteLine stderr, fgBlue, fmt"{skipped.len} SKIPPED", resetStyle
  echo "\nSee log files for details:"
  for testScript in fail:
    echo fmt("  {testScript.outputFile}")
  if self.reportPath != "":
    echo "Or look at combined report file:"
    echo fmt"  {self.reportPath}"
    removeFile(self.reportPath)
    let f = open(self.reportPath, fmWrite)
    defer: f.close()
    writeline f, fmt"Ran {ran} tests {self.processLimit} threads"
    styledWriteLine f, fgGreen, fmt"{success.len} OK", resetStyle
    styledWriteLine f, fgRed, fmt"{fail.len} ERROR", resetStyle
    writeLine f, "Logs from Failed tests:"
    for testScript in fail:
      write f, fmt("Script: {extractFileName(testScript.name)} Lang: {toName(testScript.lang)}\n\n")
      write f, readFile(testScript.outputFile)
      write f, "\n"
  self.state = trsFinished

proc checkRunningReturnFree(self: TestRunner): int =
  # Check the status of all running processes. If the process has finished generate a report
  # if the process has been running for longer than it's timeout value, terminate it
  # Finally move finished test scripts out of the running seq.
  # Return the number of new processes that can be started
  for testScript in self.runningTestScripts:
    if peekExitCode(testScript.process) != -1: # process finished
      if peekExitCode(testScript.process) == 0:
        testScript.reportTestScript(self.finishedTestScripts.len, self.initialTests, sSuccess, self.verbosity)
      else:
        testScript.reportTestScript(self.finishedTestScripts.len, self.initialTests, sError, self.verbosity)
        self.processResult = peekExitCode(testScript.process)
      self.finishedTestScripts.add(testScript)
    else:
      if (getTime() - testScript.processStartedAt) > testScript.testSet.defaultTimeOut: # process timeouts
        terminate(testScript.process)
        testScript.reportTestScript(self.finishedTestScripts.len, self.initialTests, sTimeout, self.verbosity)
        self.processResult = 1
        self.finishedTestScripts.add(testScript)
  self.runningTestScripts.keepIf(proc (ts: TestScript): bool = ts.state == tssRunning)
  result = self.processLimit - self.runningTestScripts.len

proc runQueue(self: TestRunner): int =
  # Run the test script queue.
  # at each iteration, pull a number of enqueued test scripts
  # out of the queue equal to the number of free slots and run them.
  # once the queue is empty wait for all of the still running processes to finish
  var env = newStringTable(modeStyleInsensitive)
  for name, value in envPairs():
    env[name] = value
  env["CODETRACER_IN_TEST"] = "1"
  env["CODETRACER_LINKS_PATH"] = linksPath

  self.state = trsRunning
  self.initialTests = self.testScriptsQueue.len
  while self.testScriptsQueue.len > 0:
    var free = self.checkRunningReturnFree()
    while free > 0 and self.testScriptsQueue.len > 0:
      var testScript = self.testScriptsQueue.pop()
      if testScript.skip:
        testScript.state = tssSkipped
        testScript.processStartedAt = getTime()
        testscript.reportTestScript(self.finishedTestScripts.len, self.initialTests, sSkipped, self.verbosity)
        self.finishedTestScripts.add(testScript)
      else:
        testScript.startTestScript(env)
        self.runningTestScripts.add(testScript)
        free.dec
    sleep(100)
  while self.runningTestScripts.len > 0:
    discard self.checkRunningReturnFree()
    sleep(100)
  result = self.processResult

# Implementation of specific test set types inheriting from base TestSet type

type
  RRTestSet = ref object of TestSet
  CoreTestSet = ref object of TestSet

method initTestScript(self: RRTestSet, name: string, lang: Lang, skip: bool, reportRealtime: bool): TestScript =
  result = system.procCall initTestScript(TestSet(self), name, lang, skip, reportRealtime) # call base method
  # redirect only if not reporting in realtime
  let redirectToFile = if not reportRealtime: fmt" > {result.outputFile}" else: ""
  result.processArgs =  @["-c", fmt("rr replay {recordDir}/rr_gdb_{getExtension(lang)}{redirectToFile}")]
  result.inputLines = @[fmt"source {name}", fmt"pi run_test_suite(True, '{toName(lang)}')"]

method initTestScript(self: CoreTestSet, name: string, lang: Lang, skip: bool, reportRealtime: bool): TestScript =
  result = system.procCall initTestScript(TestSet(self), name, lang, skip, reportRealtime) # call base method
  # redirect only if not reporting in realtime
  let redirectToFile = if not reportRealtime: fmt" > {result.outputFile}" else: ""
  result.processArgs = @[
    "-c",
    fmt"{name} .{getExtension(lang)}{redirectToFile}"
  ]

var runner = TestRunner(
  reportPath: "",
  state: trsCreated,
  verbosity: vErrors,
  processLimit: maxProcessLimit,
  runningTestScripts: newSeq[TestScript](),
  testScriptsQueue: newSeq[TestScript](),
  finishedTestScripts: newSeq[TestScript](),
  testSets: initTable[string, TestSet]()
)

# we can skip tests here
runner.testSets["rr"] = RRTestSet(
  testPath: codetracerInstallDir / "src" / "gdb" / "tests",
  tests: {
    "tracepoint_test.py": {LangRust: rSkip, LangNim: rRun, LangC: rRun}.toTable,
    # TODO: adapt after integration with call lines
    "calltrace_test.py": {LangRust: rSkip, LangNim: rSkip, LangC: rSkip}.toTable,
    "values_test.py": {LangRust: rRun, LangNim: rRun, LangC: rRun}.toTable
    }.toTable(),
  processOptions: {},
  processWorkingDir: codetracerInstallDir,
  outputPath: codetracerTmpDir / "rr_tests",
  logTestPattern: re"(?m)Test case:.*$",
  logErrorPattern: re"(?m)^FAIL: .*\n[\S\s]*\+[\S\s]*-{70}$",
  defaultTimeout: initDuration(minutes=5)
)

runner.testSets["core"] = CoreTestSet(
  testPath: codetracerTestBuildDir,
  tests: {
    # "core_cancel_test": {LangRust: rRun, LangNim: rRun, LangC: rRun}.toTable,
    "core_loading_values_test": {LangRust: rRun, LangNim: rRun, LangC: rRun}.toTable,
    "core_flow_condition_test": {LangRust: rRun, LangNim: rRun, LangC: rRun}.toTable,
    # "core_stepping_test": {LangRust: rRun, LangNim: rRun, LangC: rRun}.toTable,
    "core_single_simple_tracepoint_test": {LangRust: rRun, LangNim: rRun, LangC: rRun}.toTable,
    "core_simple_source_call_jumps_test": {LangRust: rRun}.toTable,
    "core_ambiguous_source_call_jumps_test": {LangRust: rRun}.toTable,
    "core_errors_source_call_jumps_test": {LangRust: rRun}.toTable,
    "core_source_line_jump_test": {LangRust: rRun, LangNim: rRun, LangC: rRun}.toTable,
    "core_multi_simple_tracepoints_test": {LangRust: rRun, LangNim: rRun, LangC: rRun}.toTable,
    "core_same_tracepoint_ticks_test": {LangRust: rRun, LangNim: rSkip, LangC: rRun}.toTable,
    "core_events_test": {LangRust: rRun, LangNim: rSkip, LangC: rRun}.toTable,

    # StepIn can sometimes behave like Continue in C. So the tests are skipped for now
    # https://github.com/rr-debugger/rr/issues/3618
    #
    # All paths are `{...}/codetracer-desktop/src/build-debug/native/trace.c` for Nim, so skip no source is broken.,
    "core_load_step_lines_test": {LangRust: rRun, LangNim: rSkip, LangC: rSkip}.toTable,
    }.toTable(),
  processOptions: {},
  processWorkingDir: codetracerInstallDir,
  outputPath: codetracerTmpDir / "core_tests",
  logTestPattern: re"(?m)^\[.*\]:.*$",
  logErrorPattern: re"(?m)^FAIL: .*\n[\S\s]*actual.*",
  defaultTimeout: initDuration(minutes=5)
)

proc parallelHelp*() =
  echo """
  Parallel testing. Execute rr and/or core tests in parallel:

  tester parallel [<test-sets>] [<options>]
  options:
  -h/--help
    Print this message and exit
  -r/--report-path=<file>
    Generate detailed report and store it in file
  -p/--process-count
    Set the number of processes to use. Default is cpucount-2, but always 1 or more.
  -v/--verbosity=<0..3|quiet|error|info|full>
    Set verbosity level. Does not affect output to report-path. Option is either a number or an enum:
      0, quiet - minimum output
      1, error - show errors from process logs
      2, info - show the names of testcases from processes
      3, full - echo the full process logs
  --realtime
    Set to directly print out test output in realtime. Overrides `verbosity`
      (output is possibly as verbose as `verbosity`: `full`/3, sometimes more)
    Makes sense mostly when we want to iterate on a single or longer running test,
    but still use the `tester parallel` API.
  <test-sets>
  Specify which test sets to run and how. If not supplied, run all test sets. Specification is as follows:
    [rr|core],[<pattern>,.<lang-extention>]
    examples:
      rr,values_test,.rs - run all rr values tests for Rust
      core - runs all core tests for all langs
      .rs - runs all tests for Rust
"""
  quit(0)

proc parseTestSetSpec(testSetNames: seq[string], args: string): (string, string, seq[Lang])=
  # a test set spec is a comma delimited list of 0 to 3 items
  # if the item starts with a ., it is a lang spec, and is converted to Lang
  # if the item is one of testSetNames, it is the name of a test set
  # otherwise the item denotes a search pattern for test scripts.
  var args = rsplit(args, ",")
  var pattern = ""
  var langs = SUPPORTED_LANGS
  var testSet = ""
  for i, arg in args:
    if "." in arg:
      langs =  @[toLang(arg[1..^1])]
    elif arg in testSetNames:
      testSet = arg
    else:
      # (alexander): sorry, very hacky, not sure
      # how to cleanly do it
      # ignore parallel from `tester parallel` only
      # for pattern
      if i > 0 or arg != "parallel":
        pattern = arg
  result = (testSet, pattern, langs)

proc runTestSets*(args: seq[string]): int =
  var parsed_options = initOptParser(args)
  var
    testSet: string = ""
    pattern: string = ""
    langs: seq[Lang] = @[]
    hasTestSpec = false

  for kind, key, val in getopt(parsed_options):
    case kind:
      of cmdEnd:
        discard
      of cmdArgument:
        (testSet, pattern, langs) = parseTestSetSpec(toSeq(keys(runner.testSets)), key)
        hasTestSpec = true
      of cmdLongOption, cmdShortOption:
        case key:
          of "h", "help":
            parallelHelp() # exit
          of "r", "report-path":
            runner.reportPath = val
          of "p", "process-count":
            runner.setProcessLimit(parseInt(val))
          of "v", "verbosity":
            if len(val) == 1 and isDigit(val[0]):
              runner.verbosity = Verbosity(parseInt(val))
            else:
              runner.verbosity = parseEnum[Verbosity](val)
          of "realtime":
            runner.reportRealtime = true


  if hasTestSpec:
    # we want to have the other runner fields ready before enqueTestScripts
    runner.enqueTestScripts(testSet, pattern, langs)

  if runner.testScriptsQueue.len == 0: # if no test sets are specified by the user, run all
    runner.enqueTestScripts("", "", SUPPORTED_LANGS)
  result = runner.runQueue()
  runner.report()
