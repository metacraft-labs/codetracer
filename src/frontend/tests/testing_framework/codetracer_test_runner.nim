import parseopt, sequtils, strutils, strformat, async, jsffi
import test_runner, ../../lang
import test_helpers, ../../lib

# # keep similar as in types.nim !
# # but we have Multi
# # for now we probably don't import types, to make the build faster
# # and the dependencies on codetracer smaller
# # TODO: should we move this to a more general functionality of the runner
# type
#TestLang* = enum C, Cpp, Rust, Nim, Go, Multi # LangPascal, LangPython, LangRuby, LangJavascript, LangLua, LangAsm, LangUnknown

# TODO: simplify Lang, add Multi
type
  TestLang* = Lang

let DEFAULT_LANGS*: set[Lang] = {LangC, LangCpp, LangRust, LangGo, LangNim}

type
  CodetracerTestOptions* = object
    help*: bool
    error*: bool
    langs*: set[TestLang]
    verbosity*: int
    testNamePattern*: string

proc parseTestOptions*(params: string): CodetracerTestOptions =
  # echo "parseTestOptions"
  var p = initOptParser(params)
  result.langs = DEFAULT_LANGS
  var hadLangArgument = false
  while true:
    p.next()
    case p.kind:
    of cmdEnd:
      break
    of cmdShortOption, cmdLongOption:
      if p.key == "v" or p.key == "verbosity":
        echo p.val
        result.verbosity = p.val.parseInt
    of cmdArgument:
      # echo "argument ", p.key
      if p.key.len > 0 and p.key[0] == '.': # extension
        # echo "language"
        if not hadLangArgument:
          result.langs = {}
          hadLangArgument = true
        result.langs.incl(toLang(p.key[1..^1]))
      else:
        result.testNamePattern = p.key

let app = fmt"node {nodeProcess.argv[1]}"

let TEST_USAGE = fmt"""
  {app} [<test-name-pattern>] [.<ext>] [-v/--verbosity <verbosity>]
  example:
     {app} "my-test" .c -v 1
"""

proc codetracerTestEntrypoint*(suite: TestSuiteDefinition[TestLang]) {.async.} =
  let params = lib.nodeProcess.argv.mapIt($it).join(" ")
  let options = parseTestOptions(params)
  if options.error or options.help:
    echo TEST_USAGE
    quit(1)
  # quit(0)
  var langs = suite.defaultModes * options.langs
  var runner = runnerForModes[TestLang](suite, langs, verbosity=options.verbosity, testNamePattern=options.testNamePattern)
  await runner.run()

# example

proc stopRRGdbAndInternalProcesses =
  # again, hopefully a temporary workaround
  # WARNING: stops/breaks any another parallelly
  # running test/codetracer instances

  # killall seems to sometimes hang on CI?
  # pkill seems available on CI  but not sure how to
  # add with nix
  # try maybe temporary or only in CI?
  let inGitlabCI = not nodeProcess.env[cstring"GITLAB_CI_BUILD"].isNil

  let command =
    if inGitlabCI:
      "pkill -9 rr; pkill -9 gdb; pkill -9 dispatcher; pkill -9 task_process; pkill -9 sleep;"
    else:
      "killall -9 rr gdb dispatcher task_process sleep"

  echo "stopRRGdbAndInternalProcesses: ", command
  discard execWithPromise(cstring(command))

let ctStartBeforeAll* = proc(self: TestSuiteRunner[TestLang]) {.async.} =
  # echo "ct: before: "
  echo "ctStartBeforeAll ", self.testSuite.defaultDomainArg, " ", self.mode
  stopRRGdbAndInternalProcesses()
  await startApp(self.testSuite.defaultDomainArg, self.mode) # TODO Multi

var ctBefore*: seq[proc(self: TestSuiteRunner[TestLang]): Future[void]] = @[]
ctBefore.add(ctStartBeforeAll)
# ct before

let ctStartBefore* = proc(self: TestSuiteRunner[TestLang], t: TestDefinition[TestLang]) {.async.} =
  # echo "ct: before: "
  if t.domainArg.len > 0:
    echo "ctStartBefore ", t.domainArg, " ", self.mode
    await startApp(t.domainArg, self.mode) # TODO Multi


var ctBeforeEach*: seq[proc(self: TestSuiteRunner[TestLang], t: TestDefinition[TestLang]): Future[void]] = @[]
#ctBeforeEach.add(ctStartBefore)
## end ct before

let ctAfterAll* = proc(self: TestSuiteRunner[TestLang]) {.async.} =
  # echo "ct: before: "
  await closeApp()

var ctAfter*: seq[proc(self: TestSuiteRunner[TestLang]): Future[void]] = @[]
ctAfter.add(ctAfterAll)
## ct after
let ctStopAfter = proc(self: TestSuiteRunner[TestLang], t: TestDefinition[TestLang]) {.async.} =
  # echo "ct: after: "
  if t.domainArg.len > 0:
    await closeApp()

  # TODO stop app
var ctAfterEach*: seq[proc(self: TestSuiteRunner[TestLang], t: TestDefinition[TestLang]): Future[void]] = @[]
#ctAfterEach.add(ctStopAfter)
## end ct after

# if a test has more specific mode that doesn't match the current mode, skip it
# TODO cli-based mode filtering

# cli args, lang support/cases/flags
when isMainModule:
  var codetracerSuite = asyncTestSuite("Smoke tests", ctBeforeEach, ctBefore, ctAfter, ctAfterEach, defaultDomainArg="", defaultModes=DEFAULT_LANGS):
    test("example"):
      # sleep(1_000)
      let a = 10
      assertAreEqual(2, 5)

    test("example2"): #, program="other_program", langs={LangRs}):
      # sleep(1_000)
      echo "test2"

    test("example3"):
      # sleep(1_000)
      discard

    test("example4"):
      # sleep(1_000)
      discard

    test("example5"):
      # sleep(1_000)
      discard

      # raise newException(ValueError, "problem")
      # {.emit: "throw \"a\"".}
      # var a = @[2, 5]
      # echo a[2]
        # log "step1"
        # log "step2"
        #assert...
      # test("event jump c"):
      #   log "step1"
      #   log "step2"

  # echo suite.repr


  discard codetracerTestEntrypoint(codetracerSuite)

export test_runner
export lang

# TODO: fix run and cli
# TODO: fix colors for node mode
# TODO: filtering/beforeEach/tup etc
