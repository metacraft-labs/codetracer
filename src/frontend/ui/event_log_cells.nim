## What the desktop Event Log's DataTables cells are built from.
##
## Split out of `ui/event_log.nim` so the code that turns a recorded event
## into a cell string can be compiled and driven on its own: `event_log.nim`
## reaches `ui_imports` and, through it, isonim, which the renderer
## HTML-sink suite (`tests/html_sinks_probe.nim`) deliberately does not
## require. This module imports only `types` and is what that suite drives
## through a real DataTables instance.
##
## ## EVERY CELL STRING HERE IS MARKUP
##
## DataTables inserts a column's `render` result — and, for a column without
## a `render`, the row's data — as HTML
## (https://datatables.net/reference/option/columns.render). Everything a
## cell shows from the recording (the program's output, a file name it
## opened, a trace-log message, a source path) is TEXT and must read exactly
## as the program wrote it (Event-Log-Pane.md, "Event Row Display"). So each
## recorded string is HTML-escaped once, here, before DataTables receives it.

import std/[jsffi, strformat, strutils]
import ../types
import ../../common/html_text

const
  EVENT_LOG_KIND_NAMES*: array[EventLogKind, string] = [
    "write",
    "write file",
    "write(other)",
    "read",
    "read file",
    "read(other)",
    "read dir",
    "open dir",
    "close dir",
    "socket",
    "open",
    "error",

    "trace log event",
    "messages",
    "write(stderr)",
    "exec",
    "read env",
    "write env",
    "stat",
    "create dir",
    "remove dir",
    "remove file",
    "rename",
    "change dir",
  ]

func eventLogDescriptionRepr*(eventElement: ProgramEvent, index: int): string =
  ## The one-line description of a recorded event, as TEXT.
  ##
  ## It interpolates recorded strings (`content`, `metadata`, a source path)
  ## verbatim; a caller that hands it to an HTML sink escapes it first, as
  ## `eventLogOutputRender` does.
  if not eventElement.semanticKind.isNil and eventElement.semanticKind.len > 0:
    case $eventElement.semanticKind
    of "debugger-stop":
      if eventElement.metadata.len > 0:
        return $eventElement.metadata
      elif eventElement.highLevelPath.len > 0 and eventElement.highLevelLine > 0:
        return fmt"debugger stop at {eventElement.highLevelPath}:{eventElement.highLevelLine}"
      else:
        return $eventElement.content
    else:
      discard

  case eventElement.kind:
    of Write:
      let into = if eventElement.stdout: "stdout" else: "stderr"
      fmt"{into}: {eventElement.content}"

    of WriteStderr:
      fmt"stderr: {eventElement.content}"

    of Exec, ReadEnv, WriteEnv, Stat, CreateDir, RemoveDir, RemoveFile,
        Rename, ChangeDir:
      let label = EVENT_LOG_KIND_NAMES[eventElement.kind]
      if eventElement.metadata != "":
        fmt"{label} {eventElement.metadata}: {eventElement.content}"
      else:
        fmt"{label}: {eventElement.content}"

    of Read:
      fmt"stdin: {eventElement.content}"

    of WriteFile:
      fmt"write to {eventElement.metadata}: {eventElement.content}"

    of ReadFile:
      fmt"read from {eventElement.metadata}: {eventElement.content}"

    of WriteOther:
      fmt"write: {eventElement.metadata}: {eventElement.content}"

    of ReadOther:
      fmt"read: {eventElement.metadata}: {eventElement.content}"

    of OpenDir, ReadDir, CloseDir:
      "eventually TODO"

    of Socket:
      fmt"socket: {eventElement.content}"

    of EventLogKind.Open:
      fmt"open {eventElement.metadata}"

    of EventLogKind.Error:
      fmt"error: {eventElement.content}"

    of EventLogKind.EvmEvent:
      if eventElement.metadata != "":
        fmt"{eventElement.metadata}: {eventElement.content}"
      else:
        fmt"{eventElement.content}"
    else:
      fmt"event {eventElement.kind}"

proc eventLogOutputText*(event: ProgramEvent): string =
  ## What the output ("Details") cell says, as text: a trace-log event's own
  ## message, every other kind's description.
  case event.kind
  of TraceLogEvent:
    # The old render handed a missing `content` (JS `null`) back unchanged
    # and DataTables drew an empty cell; `$` on a nil `cstring` throws under
    # the JS backend instead, which would abort the whole draw.
    if event.content.isNil: "" else: $event.content
  else: eventLogDescriptionRepr(event, event.eventIndex)

proc eventLogOutputRender*(content: cstring, t: js, event: ProgramEvent): cstring =
  ## The output column's DataTables `render` callback: the description,
  ## escaped as a whole. Every part of it is text — the view's own prefix
  ## (`stdout: `, `write to `) has no markup to keep — so escaping the
  ## assembled string is the same as escaping each recorded piece, and it
  ## cannot miss a field a future branch of `eventLogDescriptionRepr` adds.
  ##
  ## Escaped for every `t` (`display`, `filter`, `sort`, `type`): the dense
  ## table is `serverSide`, so DataTables never filters or sorts on what
  ## this returns — the engine does, on the recorded text.
  cstring(escapeHtmlText(eventLogOutputText(event)))

proc eventLogLocationRender*(fullPath: cstring, t: js, row: js): cstring =
  ## The location column's DataTables `render` callback. The column used to
  ## have none, and DataTables inserts a column's raw data as HTML just the
  ## same, so a source path the recording names reached the parser verbatim.
  if fullPath.isNil: cstring""
  else: cstring(escapeHtmlText($fullPath))

proc dataTableRowOf*(event: ProgramEvent; extras: EventLogRowExtras): JsObject =
  ## One row as DataTables will see it.
  ##
  ## A `ProgramEvent` plus the two path fields the widget's column definitions
  ## name (`data: "fullPath"`) and `ProgramEvent` does not have. The widget used
  ## to be handed raw `TableRow`s instead, which is the mirror image: it had the
  ## paths and lacked `highLevelPath`, `highLevelLine`, `eventIndex` and
  ## `maxRRTicks`, all four of which its own renderers read — so
  ## `eventLogDescriptionRepr(event, event.eventIndex)` was reading `undefined`
  ## off every row it drew. Every field either side of that seam is present now.
  ##
  ## **A COPY, NOT THE ARGUMENT ITSELF** (`PLAT35-PD2`, closed by PLAT-40).
  ## Under the JS backend an object argument is the caller's object, and the
  ## caller passes the variable of a `for` loop — ONE object, overwritten on
  ## every iteration. `event.toJs` handed DataTables that one object once per
  ## row, so every row of the table was the LAST event: `calc`'s six rows all
  ## read `stdout: checksum = 73`. `var row = event` is a fresh object per call.
  var row = event
  result = row.toJs
  # THE LOCATION COLUMN NEVER GOES BLANK FOR A ROW THAT HAS A LOCATION.
  # `fullPath` is the table reply's own text, and a capture of `calc`
  # (PLAT-40's re-take of PLAT-35's `returned-calltrace`) measured a reply
  # whose rows carried none — the column under the `location` header was
  # empty on every row while `highLevelPath`/`highLevelLine`, which the
  # neutral row always carries, said `main.py:111`. The reply's text wins
  # when it has one.
  result.fullPath =
    if extras.fullPath.len > 0: extras.fullPath
    elif event.highLevelPath.len > 0:
      cstring(($event.highLevelPath).split("/")[^1] & ":" & $event.highLevelLine)
    else: extras.fullPath
  result.lowLevelLocation = extras.lowLevelLocation
