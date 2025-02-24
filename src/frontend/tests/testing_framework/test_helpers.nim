import
  strutils, strformat, macros, jsffi, async, unittest, jsconsole, algorithm, os, # os because `/`
  #chronicles,
  ../../lib, ../../types, ../../lang, ../../paths, ../../trace_metadata,
  selenium_web_driver, extended_web_driver

type UnexpectedTestResult* = object of Exception

type InconclusiveTestResult* = object of Exception

type ExpectedTestFailure* = object of Exception

macro asyncsuite*(name: untyped, code: untyped): untyped =
  result = quote:
    proc asuite {.async.} =
      suite `name`:
        `code`
        await closeApp()
        exit(0)

type
  LangState* = object
    traceID*: int
    lang*: Lang
    entryPath*: string
    bLine*: int
    firstLoopLine*: int
    tracePointLine*: int

var codetracerProcess*: JsObject

var process = require(j"child_process")

unittest.abortOnError = false # so we can handle it in `exit`, but stills let `fail` from unittest set correct
# program status/test status impl variable so unittest messages don't show [OK]

proc closeProcess*(process: js) = process.kill()

proc start*(name: cstring, cmd: seq[cstring], options: js): js =
  echo "node: test: start process: ", name, " ", cmd
  result = process.spawn(name, cmd, options)


# echo nodeProcess.argv
let filters = nodeProcess.argv[2 .. ^1]

# default values: filled by <text-filter>-s in command args
var textFilters: seq[string] = @[]

# default values: overriden by .<lang-extension>-s in command args, which enable only those languages
# and disable all others
var enabledLangs*: array[Lang, bool] # false by default
enabledLangs[LangC] = true
enabledLangs[LangCpp] = true
enabledLangs[LangRust] = true
enabledLangs[LangNim] = true
enabledLangs[LangGo] = true

proc processFilters(filters: seq[cstring]) =
  var hadLangFilters = false
  for filter in filters:
    if filter.len > 0:
      if filter[0] != '.':
        textFilters.add($filter)
      else:
        if filter.len > 1:
          if not hadLangFilters:
            hadLangFilters = true
            enabledLangs.fill(false)
          let lang = toLang(filter.slice(1)) # [1..^1])
          if lang != LangUnknown:
            enabledLangs[lang] = true

processFilters(filters)

proc startWebDriver() {.async.} =
  let webDriverProcess = start(
    cstring(chomedriverExe),
    @[],
    js{})
  var stdout = webDriverProcess.stdout
  stdout.setEncoding(cstring"utf8")
  stdout.on(cstring"data", proc(raw: js) = console.log(raw))
  var stderr = webDriverProcess.stderr
  stderr.setEncoding(cstring"utf8")
  stderr.on(cstring"data", proc(raw: js) = console.log(raw))
  webDriverProcess.on(cstring"error", proc(err: js) = console.log(err))

var driver* = ExtendedWebDriver()

proc testModeStartApp*(traceId: int, callerPid: int) {.async.} =
  nodeProcess.env[cstring"CODETRACER_CALLER_PID"] = cstring($callerPid)
  nodeProcess.env[cstring"CODETRACER_TRACE_ID"] = cstring($traceId)
  nodeProcess.env[cstring"CODETRACER_TEST"] = cstring"1"

  #kout nodeProcess.env

  let driverBuilder = jsNew selenium.Builder()
  # opens the chromedriver in path: for now chromedriver-102 from shell.nix
  # usingServer("http://localhost:9515")
  let driver1 = driverBuilder.
    withCapabilities(js{
      "goog:chromeOptions": js{
        # Here is the path to your Electron binary.
        binary: cstring(electronExe),
        args: @[cstring"--app=src/build-debug"], # doesn't seem to pass them the way we want to our electron instance
        #  cstring"1", cstring"--caller-pid", cstring"1", cstring"--test"]
        #  that's why we use env variables for now
        }
    })
  let driver2 = driver1.forBrowser("chrome")
  let driverRaw = driver2.build()

  driver.wrappedDriver = cast[SeleniumWebDriver](driverRaw)

proc startApp*(programName: string, lang: Lang) {.async.} =
  let currentProcessPid = 1 # cast[int](nodeProcess.pid)
  let name = fmt"{programName}_{getExtension(lang)}"
  let path = codetracerTestDir / "binaries" / name
  let app = ElectronApp(quit: proc(code: int) = quit(code))
  let trace = await app.findByProgram(cstring(path), test=true)
  if trace.isNil:
    echo fmt"error: no trace for {programName} and {lang} (for program {path})"
    quit(1)
  let traceId = trace.id
  let process = start(cstring(linksPath / "bin" / "codetracer"),
    @[cstring"start_core", cstring(path), cstring($currentProcessPid), cstring"--test"],
    js{cwd: cstring(codetracerInstallDir)})
  var stdout = process.stdout
  stdout.setEncoding(cstring"utf8")
  # stdout.on(cstring"data", proc(raw: js) = console.log(raw))

  var stderr = process.stderr
  stderr.setEncoding(cstring"utf8")
  # stderr.on(cstring"data", proc(raw: js) = console.log(raw))

  # process.on(cstring"error", proc(err: js) = console.log(err))
  codetracerProcess = process
  # await startWebDriver()
  await testModeStartApp(traceId, currentProcessPid)

proc closeApp*() {.async.} =
  try:
    if not driver.isNil:
      await driver.wrappedDriver.close()
    else:
      echo "driver.isNil: no app to close"
  except:
    echo "TODO: investigate error while running: await driver.wrappedDriver.close()"
    echo getCurrentExceptionMsg()
  try:
    codetracerProcess.closeProcess()
  except:
    echo "ERROR: while running codetracerProcess.closeProcess()"
    echo getCurrentExceptionMsg()


  # (old comment: TODO do we need it again?)
  # (I(alexander) think this had problems in CI:
  # so for now we close only locally, if we're not in CI-like env
  # if nodeProcess.env[cstring"GITLAB_CI_BUILD"].isNil:
  # await driver.closeWindow())

proc compareFiles*(expectedFilePath: cstring, actualFilePath: cstring): Future[bool] {.async.} =
  if not (await pathExists(expectedFilePath)) and not (await pathExists(actualFilePath)):
    return false

  #console.log((await execWithPromise("delta 'src/tests/programs/one_hundred_iterations/c/actual_jump_to_all_events_generated.txt' 'src/tests/programs/one_hundred_iterations/c/expected_jump_to_all_events_generated.txt' || true")).stdout)


  let expected = await fsPromises.readFile(expectedFilePath)
  let actual = await fsPromises.readFile(actualFilePath)

  if expected != actual:
    let delta = await execWithPromise(&"delta '{expectedFilePath}' '{actualFilePath}' || true")
    console.log(delta.stdout)
    return false
  return true

export types
