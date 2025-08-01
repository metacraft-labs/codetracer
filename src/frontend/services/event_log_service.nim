import service_imports, jsconsole

proc eventJump*(self: EventLogService, event: ProgramEvent) =
  # we use codeID to determine if we need to reset flow
  self.debugger.stableBusy = true
  inc self.debugger.operationCount
  self.debugger.currentOperation = cstring(fmt"event jump {event.rrEventId}")
  echo fmt"event jump {event.rrEventId}"
  self.data.ipc.send "CODETRACER::event-jump", event
  self.data.redraw()
  avgTimePerRRTick(self.debugger, event.directLocationRRTicks)
# TODO escape < and > for raw html as well
# TODO terminal view?

proc loadTerminal*(self: EventLogService) =
  self.data.ipc.send "CODETRACER::load-terminal", js{}

# proc escapeAnsiSequences(content: cstring): cstring =
#   var escapedString = ""
#   var i = 0
#   while i < content.len:
#     var c = content[i]
#     if c == '[':
#       var nextIndex = i + 1
#       while nextIndex < content.len - 1 and (content[nextIndex].isDigit() or content[nextIndex] == ';'):
#         nextIndex += 1
#       if nextIndex < content.len - 1 and content[nextIndex] == 'm':
#         i = nextIndex + 1
#         # ignore \[[digit|;]*m as ansi escape sequence
#       else:
#         for internalIndex in i + 1 .. nextIndex - 1:
#           escapedString.add(content[internalIndex])
#         i = nextIndex
#     elif c == '\\':
#       if i < content.len - 1:
#         if content[i + 1] == 'n':
#           escapedString.add("\n")
#         elif content[i + 1] == 't':
#           escapedString.add("\t")
#         else:
#           escapedString.add("\\")
#           escapedString.add(c)
#         i += 2
#       else:
#         escapedString.add("\\")
#         i += 1
#     else:
#       escapedString.add(c)
#       i += 1
#   let escaped = cstring(escapedString)
#   return escaped

# data.services.eventLog.onUpdatedTrace = proc(self: EventLogService, response: TraceUpdate) {.async.} = 
#   let id = data.ui.activeFocus.id
#   let eventComponent = cast[EventLogComponent](data.ui.componentMapping[Content.EventLog][id])
#   eventComponent.denseTable.context.ajax.reload()

# data.services.eventLog.onUpdatedTable = proc(self: EventLogService, response: TableUpdate) {.async.} =
#   let id = data.ui.activeFocus.id
#   let eventComponent = cast[EventLogComponent](data.ui.componentMapping[Content.EventLog][id])
#   discard eventComponent.onUpdatedTable(response)

data.services.eventLog.onUpdatedEvents = proc(self: EventLogService, response: seq[ProgramEvent]) {.async.} =
  data.maxRRTicks = response[0].maxRRTicks
  if self.ignoreOutput:
    return

  console.time(cstring"new events service")

  for element in response:
    self.events.add(element)
    # TODO: use ansi_up or the escape function?
    # eventually have a flag/shortcut or menu option to
    # toggle between non-escaped and escaped content
    # think again about html/xml in content escaping/pre tags

  console.timeEnd(cstring"new events service")

  self.data.redraw()

data.services.eventLog.onUpdatedEventsContent = proc(self: EventLogService, response: cstring): Future[void] =
  if self.ignoreOutput:
    return

  let lines = response.split(jsNl)
  var lineIndex = 0
  var eventsIndex = 0
  while lineIndex < lines.len and eventsIndex < self.events.len:
    while true:
      if eventsIndex < self.events.len:
        if self.events[eventsIndex].kind in {Write, WriteFile, WriteOther, Read, ReadFile, ReadOther}:
          self.events[eventsIndex].content = lines[lineIndex]
          lineIndex += 1
        eventsIndex += 1
      else:
        echo fmt"warn: no event for line number {lineIndex}"
        break

  self.updatedContent = true
  self.data.redraw()

data.services.eventLog.onCompleteMove = proc(self: EventLogService, response: MoveState) {.async.} =
  if self.started:
    return

  if self.data.config.events:
    self.started = true
    self.data.ipc.send "CODETRACER::event-load", js{}

# TODO init

method restart*(self: EventLogService) =
  self.events = @[]
  self.started = false
