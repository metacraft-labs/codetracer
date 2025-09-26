from std / strformat import fmt
from std / dom import click
import ../lib/[ jslib, logging ]
from loaders import nil

type
  OperationKind* {.pure.} = enum OpStepAction, OpEventJump

  Operation* = object
    case kind*: OperationKind:
    of OpStepAction:
      stepAction*: string
    of OpEventJump:
      eventIndex*: int

proc clickDebugButton(action: string) =
  uiTestLog fmt"info: click debug button {action}!"
  let debugButtonElement = loaders.debugButton(action)
  if not debugButtonElement.isNil:
    debugButtonElement.click()
  
proc clickEvent(eventIndex: int) =
  uiTestLog fmt"info: click event {eventIndex}"
  let eventRowElement = loaders.eventRow(eventIndex)
  if not eventRowElement.isNil:
    eventRowElement.click()


method runOperation*(operation: Operation) =
  case operation.kind:
  of OpStepAction:
    clickDebugButton(operation.stepAction)
  of OpEventJump:
    clickEvent(operation.eventIndex)

proc `$`*(operation: Operation): string =
  case operation.kind:
  of OpStepAction:
    fmt"step {operation.stepAction}"
  of OpEventJump:
    fmt"event-jump to event with index {operation.eventIndex}"
