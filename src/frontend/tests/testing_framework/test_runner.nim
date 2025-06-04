import macros, strformat, strutils, typetraits, asyncjs, jsffi

var lastJSError {.importc.}: JsObject


# Mode/Variant?
type
    TestSuiteDefinition*[Mode] = ref object
        name: string
        tests: seq[TestDefinition[Mode]]
        defaultDomainArg*: string # test-specific related: in codetracer's case: program
        defaultModes*: set[Mode]

        before: seq[proc(self: TestSuiteRunner[Mode]): Future[void]]
        after: seq[proc(self: TestSuiteRunner[Mode]): Future[void]]
        beforeEach: seq[proc(self: TestSuiteRunner[Mode], t: TestDefinition[Mode]): Future[void]]
        afterEach: seq[proc(self: TestSuiteRunner[Mode], t: TestDefinition[Mode]): Future[void]]

    TestDefinition*[Mode] = ref object
        name*: string
        domainArg*: string # domain specific argument: in codetracer's case: a program name
        modes*: set[Mode]
        function: proc(runner: TestSuiteRunner[Mode], t: TestDefinition[Mode]): Future[void]

    TestResult* = ref object
        didPass: bool
        logs: seq[string]
        errors: seq[string]
        afterHookErrors: seq[string]
        # duration: int # milliseconds ?

    TestSuiteRunner*[Mode] = ref object
        testSuite*: TestSuiteDefinition[Mode]
        testResults: seq[TestResult]

        mode*: Mode
        verbosity*: int
        testNamePattern*: string

    TestRunner*[Mode] = ref object
        testSuiteRunners: seq[TestSuiteRunner[Mode]]

# proc log*(msg: string) =
  # <somewhere>.logs.add(msg)

var didATestFail = false

proc runTest[Mode](self: TestSuiteRunner[Mode], test: TestDefinition[Mode]): Future[TestResult] {.async.} =
  var res: TestResult
  # echo "run test"
  try:
    # before the test:
    for hook in self.testSuite.beforeEach:
      await hook(self, test)
    res = TestResult(didPass: true, logs: @[], errors: @[], afterHookErrors: @[])
    # actual test case
    await test.function(self, test)
  # we need to catch Defects as well!
  # also we need to catch JavaScript exceptions
  # which seem to require `except:` without args
  except:
    echo cast[string](lastJsError["trace"])
    let msg = getCurrentExceptionMsg()
    res = TestResult(didPass: false, errors: @[$msg])
    didATestFail = true

  # after the test:
  for hook in self.testSuite.afterEach:
    try:
      await hook(self, test)
    except:
      let msg = getCurrentExceptionMsg()
      if res.didPass:
        res.didPass = false
      res.afterHookErrors.add($msg)

  return res

# interface ProgressReporter:
#   beforeTest*(self, test: Test)
#   afterTest*(self, test: Test, res: TestResult)


import jsffi

type
  NodeProcess* = ref object # not full, just some fields
    ## copied from lib.nim
    platform*: cstring
    argv*: seq[cstring]
    env*: JsAssoc[cstring, cstring]
    cwd*: proc: cstring
    stdout*: NodeStdout
    exit*: proc(code: int): void

  NodeStdout* = ref object
    write*: proc(raw: cstring)

var nodeProcess* {.importcpp: "process".}: NodeProcess

type
  TextReporter* = ref object
    useColors*: bool

var stdout = nodeProcess.stdout


# [EVENT]: <info>

proc beforeSuite*[Mode](self: TextReporter, r: TestSuiteRunner[Mode]) =
  echo ""
  echo fmt"[SUITE {r.testSuite.name}] ({r.mode}):" # [SUITE suite-name] (LangC):
  echo ""

proc afterSuite*[Mode](self: TextReporter, r: TestSuiteRunner[Mode]) =
  echo fmt"======================================"
  echo ""

proc beforeTest*[Mode](self: TextReporter, test: TestDefinition[Mode]) =
  # stdout.write alignLeft(fmt"{test.name} ..", 50)
  echo fmt"[{test.name}]:"
  # when not defined(js):
    # flushFile(stdout)


const GREEN_COLOR* = "\x1b[92m"
const RED_COLOR* = "\x1b[91m"
const RESET* = "\x1b[0m"

proc afterTest*[Mode](self: TextReporter, test: TestDefinition[Mode], res: TestResult) =
  # stdout.write "\r" # "\e[1A" # for replacing the line
  # stdout.write "\e[K"
  if res.didPass:
    # TODO: color support
    if self.useColors:
      # copied from stdlib docs/unittest
      echo fmt("{GREEN_COLOR}[PASS]{RESET}")
    else:
      echo "[PASS]" # , test.name
  else:
    let offset = "         "
    var msg = "[ERROR]: " & res.errors.join("\n" & offset) # splitLines()[0] & ".."
    # Franz notes: we need to show this after end as well
    if res.afterHookErrors.len > 0:
      msg.add("\n(after): " & res.afterHookErrors.join("\n" & offset))
    if self.useColors:
      echo fmt("{RED_COLOR}{msg}{RESET}")
    else:
      echo msg  # assuming error is always the last log

# test <x>:
#   clicked ..
#   searching Y:
#     entering Z
#   clicked

var reporter = TextReporter(useColors: true)

# ===== end of reporter
proc run*[Mode](self: TestSuiteRunner[Mode]) {.async.} =
  reporter.beforeSuite(self)
  #TODO: add capability log error messages from before/after
  for beforeProcedure in self.testSuite.before:
    await beforeProcedure(self)

  for test in self.testSuite.tests:
    if test.modes.len == 0 or # {} => assume no explicit modes arg, all modes are ok
       self.mode in test.modes: # mode explicitly enabled for test
      reporter.beforeTest(test)
      let res = await self.runTest(test)
      reporter.afterTest(test, res)
    else:
      # modes.len != 0 and self.mode notin test.modes
      # mode explicitly not enabled for tests
      # reporter.skipTest(test)
      discard

  for afterProcedure in self.testSuite.after:
    await afterProcedure(self)

  reporter.afterSuite(self)

proc exit*(code: int) =
  nodeProcess.exit(code)

proc run*[Mode](runner: TestRunner[Mode]) {.async.} =
  for suiteRunner in runner.testSuiteRunners:
    try:
      await suiteRunner.run()
    except:
      echo "run fail: ", getCurrentExceptionMsg() # huh, maybe don't stop before other langs?
      # exit(1) # TODO: pass a flag, or a handler, and do exit
    # exit(didATestFail.int)
    # code based on errors
  exit(didATestFail.int)

proc runnerForModes*[Mode](suite: TestSuiteDefinition, modes: set[Mode], verbosity: int = 1, testNamePattern: string = ""): TestRunner[Mode] =
  result = TestRunner[Mode](testSuiteRunners: @[])
  # echo "modes ", modes
  for mode in modes:
    var runner = TestSuiteRunner[Mode](testSuite: suite, mode: mode, verbosity: verbosity, testNamePattern: testNamePattern)
    result.testSuiteRunners.add(runner)



# codetracerSuite("a", "example_program", {C, Cpp}):
#   test "example", [
#             (a, b, c),
#             (0, 1, 2),
#             (3, 4, 5)]:

#   test "example", [
#       (lang, a, b, c)
#       (C, 0, 1, 2),
#       (Cpp, 0, 1, 3, 4)
#   ], [
#       (a2, b2, c2),
#       (0, 1, 2),
#       (3, 4, 5)
#   ]: # (lang: C, a: 0, b: 1, c: 2, a2: 0, b2: 1, c2: 2)
#   # if clash: on compile time say, field shouldn't clash
#   # generate a named tuple probably
#   # and iterate for all combinations filtered optionally by mode
#   # or index
#     assertAreEqual(args.a, args.c - 2)


# globalParams[C] = (a: 10, b: 20)
# globalParams[Cpp] = (a: 10, b: 22)
# globalParams[Rust] = (a: .., b: ..)

# codetracerSuite("a", "example_program", {C, Cpp}):
#   test "example":
#     # generating params = globalParams[test.mode]
#     # or just using such a template?
#     params.a ..





## this is the DSL we use to generate the test data structure
## it's copied and adapted from the the stdlib `unittest` module
## it's implemented with a macro for now
macro asyncTestSuite*(
    name: untyped,
    beforeEach: untyped,
    before: untyped,
    after: untyped,
    afterEach: untyped,
    defaultDomainArg: untyped,
    defaultModes: untyped,
    code: untyped): untyped =
  # we should generate something like this
  #
  # let testSuiteDefinition = TestSuiteDefinition(
  #   name: "Smoke tests",
  #   tests: @[],
  #   before: before,
  #   after: after,
  #   beforeEach: beforeEach,
  #   afterEach: afterEach)
  # testSuiteDefinition.tests.add(TestDefinition(
  #       name: "example",
  #       function: proc {.async.} =
  #         echo "step 1"))

  # var testRunner = TestRunner(testSuites: TestSuiteRunner(testSuite: testDefinition, testResults: @[]))
  # testRunner.run()

  # TODO

  # test("example"):
  #   echo "step1"
  #
  # has this AST =>
  #
  # StmtList
  #   Call
  #     Ident "test"
  #     StrLit "example"
  #     StmtList
  #       Command
  #         Ident "echo"
  #         StrLit "step1"
  # Node(
  #    kind: nnkCall,
  #    sons: @[
    #     Node(kind: nnkIdent, ident: <"test">),
    #     Node(kind: nnkStrLit, s: "example"),
    #     Node(kind: nnkStmtList,
    #       sons: @[
      #       Node(kind: nnkCommand,
      #         sons: @[
        #         Node(kind: nnkIdent, ident: <"echo">),
        #         Node(kind: nnkStrLit, s: "step1")])])])

  # echo code.treeRepr() # draws the tree of code

  let testSuiteDefinitionName = genSym(nskVar, "testSuiteDefinition") #generate hygenic name


  let initCode = quote:
    var `testSuiteDefinitionName` = TestSuiteDefinition[`defaultModes`.elementType](
      name: `name`,
      tests: @[],
      defaultDomainArg: `defaultDomainArg`,
      defaultModes: `defaultModes`,
      before: `before`,
      after: `after`,
      beforeEach: `beforeEach`,
      afterEach: `afterEach`
    )

  var testAddCode = nnkStmtList.newTree() # empty block of code

  # for each test <name>: <code>
  for testNode in code:
    # echo testNode.kind
    let testName = testNode[1]
    let (testModes, testCode) = if testNode.len > 3:
        if testNode[2].kind != nnkCurly:
          error("test macro error: expected a set literal like {<mode1>, ..} for test second arg(modes), got: " & testNode[2].repr)
        elif testNode[2].len == 0:
          error("test macro error: expected at least one mode like {<mode1>, ..} in test second arg(modes), but it's empty: " & testNode[2].repr)
        (testNode[2], testNode[3])
      else:
        ((quote do: {}), testNode[2])


    # check this is actually called `test`
    if testNode[0].repr != "test":
      error("asyncTestSuite macro error: expected `test`, but got: " & testNode[0].repr)

    # testSuiteDefinition.tests.add(TestDefinition(
    #       name: "example",
    #       function: proc {.async.} =
    #         echo "step 1"))


    let testAddCodeSingle = quote:
      `testSuiteDefinitionName`.tests.add(TestDefinition[`defaultModes`.elementType](
        name: `testName`,
        modes: `testModes`,
        domainArg: `defaultDomainArg`,
        function: proc(
          runner {.inject.}: TestSuiteRunner[`defaultModes`.elementType],
          t {.inject.}: TestDefinition[`defaultModes`.elementType]) {.async.} =
            `testCode`))

    testAddCode.add(testAddCodeSingle)

  # let runnerCode = quote:
  #   var testRunner = TestRunner(testSuiteRunners: @[TestSuiteRunner(testSuite: `testSuiteDefinitionName`, testResults: @[])])
  #   await testRunner.run()

  result = quote:
    # proc asuite {.async.} =
    block:
      `initCode`
      `testAddCode`
      `testSuiteDefinitionName`
      # `runnerCode`

  # echo "\n===== generate\n"
  # echo result.repr
  # echo "===== end generated code\n"

## end of macro

# it is a defect, so people don't catch it by accident
type TestRunnerAssertionError* = object of Defect

template assertAreEqual*(actual: untyped, expected: untyped): untyped =
  let actualValue = actual
  let expectedValue = expected
  if actualValue != expectedValue:
    # echo "error in:"
    # echo instantiationInfo()
    # echo "expected value: ", expectedValue
    # echo "actual value: ", actualValue
    raise newException(
      TestRunnerAssertionError,
      "test error: expected " & $expectedValue & " " & " got " & $actualValue)
    # exit(code=1)
  # echo "."

type
  ExampleMode = enum ExampleMode1, ExampleMode2

## before/after
let beforeExample = proc(self: TestSuiteRunner[ExampleMode]) {.async.} =
  # echo "(before all hook)"
  discard
var before: seq[proc(self: TestSuiteRunner[ExampleMode]): Future[void]] = @[]
before.add(beforeExample)

let beforeEachExample = proc(self: TestSuiteRunner[ExampleMode], t: TestDefinition[ExampleMode]) {.async.} =
  # echo "(before test hook)"
  discard
var beforeEach: seq[proc(self: TestSuiteRunner[ExampleMode], t: TestDefinition[ExampleMode]): Future[void]] = @[]
beforeEach.add(beforeEachExample)

let afterExample = proc(self: TestSuiteRunner[ExampleMode]) {.async.} =
  # echo "(after all hook)"
  discard
var after: seq[proc(self: TestSuiteRunner[ExampleMode]): Future[void]] = @[]
after.add(afterExample)

let afterEachExample = proc(self: TestSuiteRunner[ExampleMode], t: TestDefinition[ExampleMode]) {.async.} =
  # echo "(after test hook)"
  discard
  # raise newException(ValueError, "after each error")
var afterEach: seq[proc(self: TestSuiteRunner[ExampleMode], t: TestDefinition[ExampleMode]): Future[void]] = @[]
afterEach.add(afterEachExample)



var defaultModes = {ExampleMode1, ExampleMode2}
when isMainModule:
  var suite = asyncTestSuite("test runner example", beforeEach, before, after, afterEach, defaultDomainArg="", defaultModes=defaultModes):
    test("example"):
      # sleep(1_000)
      let a = 10
      assertAreEqual(a, 5)

    test("example2", {ExampleMode1}):
      assertAreEqual(10, 10)


  var runner = runnerForModes(suite, defaultModes, verbosity=1, testNamePattern="") # TestSuiteRunner[ExampleMode](testSuite: suite, testResults: @[])
  discard runner.run()

# if a test has more specific mode that doesn't match the current mode, skip it
# TODO cli-based mode filtering

# when not defined(js):
  # export terminal
export typetraits
