## Types and utilities for tasks and events

import strutils, strformat

# TODO document individual task and event kinds
type
  TaskKind* = enum  ## Task kinds
    LoadFlow,
    LoadFlowShape,
    RunTracepoints,
    LoadHistory,
    LoadHistoryWorker,
    CalltraceSearch,
    EventLoad,
    LoadCallArgs,
    CollapseCalls,
    ExpandCalls,
    ResetOperation,
    CalltraceJump,
    EventJump,
    HistoryJump,
    TraceJump,
    Stop,
    Configure,
    RunToEntry,
    Step,
    Start,
    LoadLocals,
    LoadCallstack,
    AddBreak,
    DeleteBreak,
    DebugGdb,
    LocalStepJump,
    SendToShell,
    LoadAsmFunction,
    SourceLineJump,
    SourceCallJump,
    DeleteAllBreakpoints,
    NimLoadCLocations,
    UpdateExpansionLevel,
    AddBreakC,
    Enable,
    Disable,
    UpdateWatches,
    ResetState,
    ExpandValue,
    EvaluateExpression,
    LoadParsedExprs,
    CompleteMoveTask,
    RestartProcess,
    Raw, ## resending the raw/reconstructed raw message to client
    Ready,
    UpdateTable,
    TracepointDelete,
    TracepointToggle,
    SearchProgram,
    LoadStepLines,
    LoadStepLinesWorker,
    RegisterEvents,
    RegisterTracepointLogs,
    LoadCalltrace,
    MissingTaskKind,
    SetupTraceSession,
    LoadTerminal,

  EventKind* = enum ## Event kinds
    CompleteMove,
    DebuggerStarted,
    UpdatedEvents,
    UpdatedEventsContent,
    UpdatedFlow,
    UpdatedCallArgs,
    UpdatedTrace,
    UpdatedShell,
    UpdatedWatches,
    UpdatedHistory,
    UpdatedLoadStepLines,
    UpdatedTable,
    SentFlowShape,
    DebugOutput,
    NewNotification,
    TracepointLocals,
    ProgramSearchResults,
    UpdatedStepLines,
    UpdatedTracepointLogs,
    Error,
    MissingEventKind,
    LoadedTerminal,

func fromCamelCaseToLispCase*(text: string): string =
  ## Change the case of the string from CamelCase to lisp-case
  result = ""
  for i, c in text:
    if c.isUpperAscii:
      if i != 0:
        result.add('-')
      result.add(c.toLowerAscii)
    else:
      result.add(c)

proc toTaskKindText*(taskKind: TaskKind): string =
  ## Convert `TaskKind`_ to a lisp-case string
  fromCamelCaseToLispCase($taskKind)

proc toTaskKind*(raw: string): TaskKind =
  ## Convert raw string to `TaskKind`_ enum
  try:
    var text = raw.capitalizeAscii().replace("-", "")
    result = parseEnum[TaskKind](text)
  except:
    result = MissingTaskKind

proc toEventKind*(raw: string): EventKind =
  ## Convert raw string to `EventKind`_ enum
  try:
    var text = raw.capitalizeAscii().replace("-", "")
    result = parseEnum[EventKind](text)
  except:
    result = MissingEventKind

proc toEventKindText*(eventKind: EventKind): string =
  ## Convert `EventKind`_ to lisp-case string
  fromCamelCaseToLispCase($eventKind)

# task id

when not defined(js):
  type
    langstring = string ## compatibility type between native and javascript backends
else:
  # import jsffi

  type
    langstring = cstring ## compatibility type between native and javascript backends

type
  TaskId* = distinct langstring ## TaskId type. Uniquely identifies a task

proc `$`*(taskId: TaskId): string =
  ## Convert `TaskId`_ to string
  $(taskId.langstring)

proc `==`*(taskId: TaskId, other: TaskId): bool =
  ## Compare two `TaskId`_
  taskId.langstring == other.langstring

const NO_TASK_ID*: TaskId = langstring("<NO_TASK_ID>").TaskId

var taskIdMap: array[TaskKind, int]

when defined(js):
  for t in TaskKind.low .. TaskKind.high:
    taskIdMap[t] = 0

proc genTaskId*(taskKind: TaskKind): TaskId =
  ## Generate a new unique `TaskId`_ based on `TaskKind`_.
  let index = taskIdMap[taskKind]
  taskIdMap[taskKind] += 1
  langstring(fmt"{toTaskKindText(taskKind)}-{index}").TaskId

func genChildTaskId*(parentTaskId: TaskId, taskKind: TaskKind, index: int): TaskId =
  ## Generate a new unique `TaskId`_ based on `TaskKind`_ and a parent `TaskId`_.
  ##
  ## example: reset-operation-0-complete-move-task-0
  TaskId(fmt"{parentTaskId}-{toTaskKindText(taskKind)}-{index}")

# event id

type
  EventId* = distinct langstring ## EventId type. Uniquely identifies an event

const NO_EVENT_ID*: EventId = langstring("<NO_EVENT_ID>").EventId

proc `$`*(eventId: EventId): string =
  ## Convert `EventId`_ to string
  $(eventId.langstring)

proc `==`*(taskId: EventId, other: EventId): bool =
  ## Compare two `EventId`_
  taskId.langstring == other.langstring

var eventIdMap: array[EventKind, int]

when defined(js):
  for m in EventKind.low .. EventKind.high:
    eventIdMap[m] = 0

proc genEventId*(eventKind: EventKind): EventId =
  ## Generate a new unique `EventId`_ based on `EventKind`_
  let index = eventIdMap[eventKind]
  eventIdMap[eventKind] += 1
  langstring(fmt"{toEventKindText(eventKind)}-{index}").EventId
