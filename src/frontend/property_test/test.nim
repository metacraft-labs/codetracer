import std / [jsffi, async]
from std / jsconsole import console, log
from std / strformat import fmt
import ../lib/[ jslib, logging ]
from operations import Operation, runOperation, `$`
from strategies import Strategy, parseStrategy, generateOperation

type
  Status = enum Running, Succeeded, Failed

  FrontendTestRunner* = ref object
    strategy: Strategy
    operationHistory: seq[Operation]
    # onCompleteMove*: Future[void]
    onCompleteMoveResolve*: proc: void
    status: Status


const MAX_OPERATION_TIMEOUT* = 5_000 # ms: 5 seconds


method failAfterTimeout(runner: FrontendTestRunner) =
  let info = if runner.operationHistory.len == 0:
      "before any operations"
    else:
      let lastOperationText = $runner.operationHistory[^1]
      fmt"for {lastOperationText}"
  uiTestLog fmt"error: timeout while waiting for complete move {info}"
  runner.status = Failed


method onCompleteMove(runner: FrontendTestRunner): Future[void] =
  let future = newPromise[void](proc(resolve: proc: void) =
    let timeout = windowSetTimeout(proc = runner.failAfterTimeout(), MAX_OPERATION_TIMEOUT)

    runner.onCompleteMoveResolve = proc: void =
      windowClearTimeout(timeout)
      uiTestLog "complete move"
      runner.onCompleteMoveResolve = nil
      resolve())
  future


method runOperation(runner: FrontendTestRunner, operation: Operation) {.async.}=
  let index = runner.operationHistory.len
  uiTestLog fmt"test operation #{index}: {$operation}:"
  operations.runOperation(operation)
  runner.operationHistory.add(operation)
  await runner.onCompleteMove()


method run(runner: FrontendTestRunner) {.async.} =
  await wait(5_000)
  uiTestLog "start run"
  while true:
    try:
      let (operation, finished) = runner.strategy.generateOperation()
      if finished:
        runner.status = Succeeded
      else:
        await runner.runOperation(operation)

      if runner.status != Running:
        break
    except:
      uiTestLog "warn:" & getCurrentExceptionMsg()
      break
  if runner.status == Succeeded:
    uiTestLog "success: finished"

proc runUiTest*(rawStrategy: cstring): FrontendTestRunner =
  uiTestLog fmt"strategy: {rawStrategy}"
  let strategy = parseStrategy($rawStrategy)
  if not strategy.isNil:
    console.log strategy

  var frontendTestRunner = FrontendTestRunner(
    strategy: strategy,
    operationHistory: @[],
    onCompleteMoveResolve: nil,
    status: Running)
  discard frontendTestRunner.run()
  frontendTestRunner
