## Procedures for reading and writing tasks and events through files
## identified through PIDs and Task/Event ids.

import json_serialization
import task_and_event, path_utils

const
  NO_PID* = -1

var callerProcessPid* = NO_PID ## PID of the caller, used to identify which file to read/write

proc readRawArg*(taskId: TaskId): string =
  ## Using the callerProcessPid_ and the `TaskId <task_and_event.html#TaskId>`_, determine the argument file
  ## and read it as a string.
  readFile(ensureArgPathFor(callerProcessPid, taskId))

proc readArg*[MessageArg](taskId: TaskId): MessageArg =
  ## Using the `callerProcessPid`_ and the `TaskId <task_and_event.html#TaskId>`_, determine the argument file
  ## and read it as a json containing an object of `MessageArg` type
  Json.decode(readRawArg(taskId), MessageArg)

proc readRawResult*(taskId: TaskId): string =
  ## Using the `callerProcessPid`_ and the `TaskId <task_and_event.html#TaskId>`_, determine the result file
  ## and read it as a string.
  readFile(ensureResultPathFor(callerProcessPid, taskId))

proc readResult*[ReturnType](taskId: TaskId): ReturnType =
  ## Using the `callerProcessPid`_ and the `TaskId <task_and_event.html#TaskId>`_, determine the result file
  ## and read it as a json containing an object of `ReturnType` type
  Json.decode(readRawResult(taskId), ReturnType)

proc readRawEvent*(eventId: EventId): string =
  ## Using the `callerProcessPid`_ and the `EventId <task_and_event.html#EventId>`_, determine the event file
  ## and read it as a string.
  readFile(ensureEventPathFor(callerProcessPid, eventId))

proc readEvent*[EventContent](eventId: EventId): EventContent =
  ## Using the `callerProcessPid`_ and the `EventId <task_and_event.html#EventId>`_, determine the event file
  ## and read it as a json containing an object of `EventContent` type
  Json.decode(readRawEvent(eventId), EventContent)

proc writeRawResult*(taskId: TaskId, raw: string) =
  ## Using the `callerProcessPid`_ and the `TaskId <task_and_event.html#TaskId>`_, determine the result file
  ## and write the content of `raw` to it as a string
  writeFile(ensureResultPathFor(callerProcessPid, taskId), raw)

proc writeResult*[ReturnType](taskId: TaskId, res: ReturnType) =
  ## Using the `callerProcessPid`_ and the `TaskId <task_and_event.html#TaskId>`_, determine the result file
  ## and write the content of `res` to it as json
  writeRawResult(taskId, Json.encode(res))

proc writeRawEvent*(eventId: EventId, raw: string) =
  ## Using the `callerProcessPid`_ and the `EventId <task_and_event.html#EventId>`_, determine the event file
  ## and write the content of `raw` to it as a string
  writeFile(ensureEventPathFor(callerProcessPid, eventId), raw)

proc writeEvent*[EventContent](eventId: EventId, content: EventContent) =
  ## Using the `callerProcessPid`_ and the `EventId <task_and_event.html#EventId>`_, determine the event file
  ## and write the content of `content` to it as a json
  writeRawEvent(eventId, Json.encode(content))

proc writeRawArg*(taskId: TaskId, raw: string) =
  ## Using the `callerProcessPid`_ and the `TaskId <task_and_event.html#TaskId>`_, determine the argument file
  ## and write the content of `raw` to it as a string
  writeFile(ensureArgPathFor(callerProcessPid, taskId), raw)

proc writeArg*[Arg](taskId: TaskId, content: Arg) =
  ## Using the `callerProcessPid`_ and the `TaskId <task_and_event.html#TaskId>`_, determine the argument file
  ## and write the content of `content` to it as json
  writeRawArg(taskId, Json.encode(content))
