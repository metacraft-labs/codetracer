import std / jsffi
from std / strutils import splitWhitespace, parseInt
from std / strformat import fmt
from operations import Operation, OperationKind

type
  Strategy* = ref object of RootObj

  # for now left from separate native impl
  # TODO: decide what to do, keep unified strategies
  # or separate
  StepInLimitedStrategy* = ref object of Strategy
    callstackLimit*: int
    stepsInCallLimit*: int
    stepsInCallsMap*: JsAssoc[cstring, int]
    untilStdlib*: bool

  CoStepInLimitedStrategy* = ref object of Strategy
    callstackLimit*: int
    stepsInCallLimit*: int
    stepsInCallsMap*: JsAssoc[cstring, int]
    untilStdlib*: bool

# returns operation and if it's finished
method generateOperation*(strategy: Strategy): (Operation, bool) {.base, locks: "unknown".} =
  if true:
    raise newException(ValueError, "generateOperation method not implemented")

const
  DEFAULT_SIMPLE_COUNT_LIMIT = 100

# ==== concrete strategies => eventually => strategies/<strategy-name.nim> ====

type
  SimpleStrategy* = ref object of Strategy
    count*: int
    countLimit*: int

method generateOperation*(strategy: SimpleStrategy): (Operation, bool) =
  let countMod7 = strategy.count mod 7
  let operation = if countMod7 < 3:
      Operation(kind: OperationKind.OpStepAction, stepAction: "step-in")
    elif countMod7 < 6:
      Operation(kind: OperationKind.OpStepAction, stepAction: "next")
    else:
      let eventIndex = strategy.count div 7
      Operation(kind: OperationKind.OpEventJump, eventIndex: eventIndex)
  strategy.count += 1
  let finished = strategy.count > strategy.countLimit
  (operation, finished)


# =============== end of concrete strategies =======

# TODO: quit(1) is if shared with native
template eventuallyQuit(exitCode: int) =
  when not defined(js):
    quit(1)
  else:
    return nil

proc parseStrategy*(rawStrategy: string): Strategy =
  # e.g.
  # "step-in-limited <limit>"
  # or "simple <limit>"
  var raw = rawStrategy
  if rawStrategy.len >= 2 and rawStrategy[0] == '"' and rawStrategy[-1] == '"':
    raw = rawStrategy[1..^2]
  let tokens = raw.splitWhitespace()
  case tokens[0]:
  of "step-in-limited":
    if tokens.len < 3:
      echo "error: expected <callstack-limit> <steps-in-call-limit> [until-stdlib]"
    #   echo usage
      eventuallyQuit(1)
    let callstackLimit = tokens[1].parseInt
    let stepsInCallLimit = tokens[2].parseInt
    let untilStdlib = tokens.len == 4 and tokens[3] == "until-stdlib"
    result = StepInLimitedStrategy(callstackLimit: callstackLimit, stepsInCallLimit: stepsInCallLimit, untilStdlib: untilStdlib)
  of "co-step-in-limited":
    if tokens.len < 3:
      echo "error: expected <callstack-limit> <steps-in-call-limit> [until-stdlib]"
    #   echo usage
      eventuallyQuit(1)
    let callstackLimit = tokens[1].parseInt
    let stepsInCallLimit = tokens[2].parseInt
    let untilStdlib = tokens.len == 4 and tokens[3] == "until-stdlib"
    result = CoStepInLimitedStrategy(callstackLimit: callstackLimit, stepsInCallLimit: stepsInCallLimit, untilStdlib: untilStdlib)
  of "simple":
    let limit = if tokens.len < 2:
        DEFAULT_SIMPLE_COUNT_LIMIT
      else:
        tokens[1].parseInt
    result = SimpleStrategy(countLimit: limit)
  else:
    echo fmt"error: no strategy with this name: {tokens[0]}"
    # echo usage
    eventuallyQuit(1)
