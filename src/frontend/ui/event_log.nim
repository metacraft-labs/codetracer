import
  ../types,
  ui_imports, colors, events, trace, typetraits, strutils, jsconsole,
  datatable, strutils, base64

var arg: js

const EVENT_LOG_TAG_NAMES: array[EventTag, string] = [
  "std streams:",
  "read events:",
  "write events:",
  "network:",
  "trace:",
  "file:",
  "errors:"
]

const EVENT_LOG_KIND_NAMES: array[EventLogKind, string] = [
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

  "trace log event"
]

const EVENT_LOG_BUTTON_NAMES: array[EventDropDownBox, string] = [
  "Filter",
  "Trace events",
  "Recorded events",
  "_"
]

let kindTags: array[EventLogKind, seq[EventTag]] = [
  @[EventWrites, EventStd],   #Write
  @[EventWrites, EventFiles], #WriteFile
  @[EventWrites],             #WriteOther
  @[EventReads, EventStd],    #Read
  @[EventReads, EventFiles],  #ReadFile
  @[EventReads],              #ReadOther
  @[],                        #ReadDir
  @[],                        #OpenDir
  @[],                        #CloseDir
  @[EventNetwork],            #Socket
  @[EventFiles],              #Open
  @[EventErrorEvents],        #Error

  @[EventTrace]               #TraceLogEvent
]

var tagKinds: array[EventTag, seq[EventLogKind]]

for kind, tags in kindTags:
  for tag in tags:
    tagKinds[tag].add(kind)

proc denseId*(context: EventLogComponent): cstring =
  j("eventLog-" & $context.id & "-dense-table-" & $context.index)

proc detailedId*(context: EventLogComponent): cstring =
  j("eventLog-" & $context.id & "-detailed-table-" & $context.index)

template local*(expression: untyped): untyped {.dirty.} =
  j(self.type.name[0 .. 0].toLowerAscii() & self.type.name[1..^10] & "-" & expression)

proc recalculateKinds(self: EventLogComponent)

proc resizeEventLogHandler(self: EventLogComponent) =
  self.denseTable.resizeTable()
  self.detailedTable.resizeTable()

proc filterEvents(self: EventLogComponent): seq[ProgramEvent] =
  var events: seq[ProgramEvent] = @[]

  for i in 0..<self.service.events.len():
    let event = self.service.events[i]
    if self.selectedKinds[event.kind]:
      events.add(event)

  return events

proc findElement(self: EventLogComponent): Element =
  var denseTable = self.denseTable
  let context = denseTable.context

  if not context.isNil:
    let rows = context.rows()
    let indexes = rows.indexes()
    let denseTableRows =
      cast[seq[ProgramEvent]](rows.data())

    for i, _ in denseTableRows:
      let index = i + self.hiddenRows
      let datatableRow = context.row(indexes[i])
      let domNode = cast[Element](datatableRow.node())

      if not domNode.isNil:
        domNode.classList.remove("event-selected")

        if index == self.rowSelected:
          result = domNode

proc focusItem*(self: EventLogComponent) =
  let denseTable = self.denseTable
  let rowSelected = self.rowSelected
  let selectedRow = self.findElement()

  if not selectedRow.isNil:
    selectedRow.classList.add("event-selected")

proc findActiveRow(self: EventLogComponent, rrTicks: int, isEventJump: bool = false) =
  var denseTable = self.denseTable
  let context = denseTable.context
  cdebug "eventLog: findActiveRow"

  if not context.isNil:
    let debuggerLocationRRTicks = rrTicks
    let rows = context.rows()
    let indexes = rows.indexes()
    let denseTableRows =
      cast[seq[ProgramEvent]](rows.data())

    for i, row in denseTableRows:
      let index = i  + self.hiddenRows
      let datatableRow = context.row(indexes[i])
      let domNode = cast[Element](datatableRow.node())

      if not domNode.isNil:
        domNode.classList.remove("past")
        domNode.classList.remove("active")
        domNode.classList.remove("future")
        rowTimestamp(domNode, row, rrTicks)

        if not isEventJump:
          if row.directLocationRRTicks == debuggerLocationRRTicks:
            denseTable.activeRowIndex = index
            self.rowSelected = index
        else:
          if index > 0 and
            row.directLocationRRTicks >= debuggerLocationRRTicks and
            denseTableRows[i-1].directLocationRRTicks <= debuggerLocationRRTicks:
              denseTable.activeRowIndex = index
              self.rowSelected = index

    self.focusItem()

    if denseTable.autoScroll and isEventJump:
      scrollTable(denseTable, $(denseTable.activeRowIndex))

method onFocus*(self: EventLogComponent) {.async.} =
  self.focusItem()

func filename*(event: ProgramEvent): cstring =
  event.highLevelPath.split("/")[^1]

func reprAndLang(eventElement: ProgramEvent, index: int): (string, Lang) =
  let (name, lang) = 
    case eventElement.kind:
    of WriteFile:
      (
        fmt"event:write to {eventElement.metadata} #{index}",
        toLangFromFilename(eventElement.metadata)
      )

    of ReadFile:
      (
        fmt"event:read from {eventElement.metadata} #{index}",
        toLangFromFilename(eventElement.metadata)
      )

    of WriteOther:
      (
        fmt"event:write: {eventElement.metadata} #{index}",
        LangUnknown
      )

    of ReadOther:
      (
        fmt"event:read: {eventElement.metadata} #{index}",
        LangUnknown
      )

    of Write:
      let into = if eventElement.stdout: "stdout" else: "stderr"
      (fmt"event:write to {into} #{index}", LangUnknown)

    of Read:
      ("event: read from stdin #{index}", LangUnknown)
      
    else:
      (fmt"event: {eventElement.kind} #{index}", LangUnknown)

  (name, lang)

func eventLogDescriptionRepr(eventElement: ProgramEvent, index: int): string =
  case eventElement.kind:
    of Write:
      let into = if eventElement.stdout: "stdout" else: "stderr"
      fmt"{into}: {eventElement.content}"

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

    else:
      fmt"event {eventElement.kind}"

proc programEventJump(self: EventLogComponent, event: ProgramEvent) =
  self.findActiveRow(event.directLocationRRTicks)
  self.activeRowTicks = event.directLocationRRTicks
  self.service.eventJump(event)

proc isDbBased(self: EventLogComponent): bool =
  data.ui.editors.hasKey(self.data.services.debugger.location.path) and
  data.ui.editors[self.data.services.debugger.location.path].lang.isDbBased()

const DELAY: int64 = 200 # milliseconds

proc jump(self: EventLogComponent, table: JsObject, e: JsObject) =
  cdebug "event_log: handler jump"
  var node = e.target

  if node.tagName.to(cstring) == cstring("TBODY"):
    return

  let trNode = node.findTRNode();
  let nodeRow = table.row(trNode)
  let data = nodeRow.data()
  var event: ProgramEvent

  if data.toJs != jsUndefined:
    let location = self.data.services.debugger.location
    event = cast[ProgramEvent](data)
    event.highLevelPath = location.highLevelPath
    event.highLevelLine = location.highLevelLine
    event.metadata = ""
    event.bytes = 0
    event.tracepointResultIndex = 0
    event.eventIndex = 0
    event.stdout = true
    event.maxRRTicks = 0
    cdebug fmt"event_log: ->index from datatable event element(datatable row data): {event.eventIndex}, kind: {event.kind}"
  else:
    cerror "event_log: datatable row data undefined"
    return
  self.programEventJump(event)
  if self.data.ui.activeFocus != self:
    self.data.focusComponent(self)

proc events(self: EventLogComponent) =
  var context = self

  if not self.service.updatedContent:
    return

  proc handler(table: js, e: js) =
    let currentTime: int64 = now()
    self.lastJumpFireTime = currentTime
    if not self.service.debugger.stableBusy:
      self.jump(table, e)

  proc handlerMouseover(table: js, e: js) =
    discard

  proc handlerRightClick(table: js, e: js) =
    e.preventDefault()

    var node = e.target

    if node.tagName.to(cstring) == cstring("TBODY"):
      return

    let trNode = node.findTRNode();
    let nodeRow = table.row(trNode)
    let data = nodeRow.data()
    var index = 0
    var event: ProgramEvent

    if data.toJs != jsUndefined:
      event = cast[ProgramEvent](data)
      cdebug fmt"event_log: ->index from datatable event element(datatable row data): {event.eventIndex}, kind: {event.kind}"
    else:
      cerror "event_log: datatable row data undefined"
      return

    if event.kind != TraceLogEvent:
      let (name, lang) = reprAndLang(event, event.eventIndex)

      # open an editor
      self.data.makeEditorView(
        name,
        event.content.split("\\n").join(jsNl),
        ViewEventContent,
        lang
      )

  domwindow.handler = handler

  if not self.init or self.redrawColumns:
    console.time(cstring"new events: load in datatable: columns init")
    if not self.init:
      self.reInit()
    else:
      try:
        self.denseTable.context.clear().destroy()
        self.detailedTable.context.clear().destroy()
      except:
        cerror "event_log: " & getCurrentExceptionMsg()
        discard

    var ret = false

    try:
      var denseColumns = @[
          js{
            width: cstring"100px",
            className: cstring"direct-location-rr-ticks eventLog-cell",
            data: cstring"directLocationRRTicks",
            orderable: true,
            targets: 0,
            title: cstring"direction location rr ticks",
            render: proc(directLocationRRTicks: int): cstring =
              renderRRTicksLine(directLocationRRTicks, self.data.minRRTicks, self.data.maxRRTicks, "event-rr-ticks-line")
          },
          js{
            className: j"eventLog-index eventLog-cell",
            data: j"rrEventId",
            title: j"rr event id"
          },
          js{
            className: j"eventLog-event eventLog-cell",
            searchable: true,
            data: j"kind",
            title: j"event-image",
            render: proc(event: EventLogKind): cstring =
              cstring""
          },
          js{
            className: j"eventLog-text eventLog-cell",
            searchable: true,
            data: cstring"content",
            title: j"text",
            render: proc(content: cstring, t: js, event: ProgramEvent): cstring =
              let text = case event.kind:
                of Write, WriteFile, WriteOther, Read, ReadFile, ReadOther,
                   OpenDir, ReadDir, CloseDir, Socket, EventLogKind.Open, EventLogKind.Error:
                  cstring(eventLogDescriptionRepr(event, event.eventIndex))

                of TraceLogEvent:
                  event.content

              text
          }
      ]

      var detailedColumns = @[
          js{
            className: j"eventLog-detailed-index eventLog-cell",
            data: j"rrEventId"},
          js{
            className: j"eventLog-detailed-event eventLog-cell",
            searchable: true,
            data: j"kind",
            render: proc(event: EventLogKind): cstring =
              cstring""
          },
       ]

      console.timeEnd(cstring"new events: load in datatable: columns init")
      console.time(cstring"new events: load in datatable: optional columns")

      var renderColumns: array[
          EventOptionalColumn,
          proc(content: cstring, t: js, event: ProgramEvent): cstring
        ] = 
        [
          proc(content: cstring, t: js, event: ProgramEvent): cstring {.closure.} =
            if event.kind != TraceLogEvent:
              cstring"&lt;unknown before jump&gt;"
            else:
              let filename = event.filename
              let line = event.highLevelLine
              cstring(fmt"{filename}:{line}"),
          proc(content: cstring, t: js, event: ProgramEvent): cstring {.closure.} =
            cstring"low level location"
        ]
      if self.isDbBased():
        let lower = j("FullPath".toLowerAscii())

        denseColumns.add(
          js{
            className: j"eventLog-" & lower & " " & local("cell"),
            searchable: true,
            title: lower,
            data: j"fullPath",
          }
        )
        if false:
          let lower = j("LowLevelLocation".toLowerAscii())

          denseColumns.add(
            js{
              className: j"eventLog-" & lower & " " & local("cell"),
              searchable: true,
              title: lower,
              data: j"lowLevelLocation",
            }
          )

      console.timeEnd(cstring"new events: load in datatable: optional columns")
      console.time(cstring"new events: load in datatable: dense datatable preparation and call")

      let denseTableElement = jqFind(j"#" & self.denseId)

      denseTableElement.DataTable.ext.errMode = cstring"throw"
      self.denseTable.context = denseTableElement.DataTable(
        js{
          serverSide:     true,
          deferRender:    true,
          processing:     true,
          ordering:       true,
          searching:      true,
          scrollY:        2000,
          scroller:       true,
          fixedColumns:   true,
          order:          @[[0.toJs, (cstring"asc").toJs]],
          colResize:      js{
            isEnabled: true,
            saveState: true},
          columns:        denseColumns,
          bInfo: false,
          createdRow: rowTimestamp,
          language: js{
            emptyTable: """The current record appears to not have any system events like std read/write,
              network or disc operations.</br>You can add trace point events to your code by selecting any
              line of code and pressing "Enter"""".cstring
          },
          ajax: proc(
            data: TableArgs,
            callback: proc(data: js),
            settings: js
          ) =
            var mutData = data
            self.tableCallback = callback
            self.traceService.drawId += 1
            mutData.draw = self.traceService.drawId
            self.drawId = mutData.draw
            self.hiddenRows = data.start
            discard self.data.services.debugger.updateTable(
              UpdateTableArgs(
                tableArgs: mutData,
                selectedKinds: self.selectedKinds,
                isTrace: false,
                traceId: 0,  
              )
            ),
        }
      )

      console.timeEnd(cstring"new events: load in datatable: dense datatable preparation and call")

    except:
      cerror "event_log: " & getCurrentExceptionMsg()
      console.timeEnd(cstring"new events: load in datatable: columns init")
      console.timeEnd(cstring"new events: load in datatable: optional columns")
      console.timeEnd(cstring"new events: load in datatable: dense datatable preparation and call")

      ret = true

    if ret:
      return

    console.time(cstring"new events: load in datatable: context changes and handlers")

    context.init = true
    context.denseTable.context = jqFind(j"#" & context.denseId).DataTable()
    context.detailedTable.context = jqFind(j"#" & context.detailedId).DataTable()
    context.redrawColumns = false
    context.eventsIndex = self.service.events.len

    cdebug "event_log: setup " & $(cstring"#" & context.denseId & cstring" tbody")
    # cdebug "event_log: setup " & $(cstring"#" & context.detailedId & cstring" tbody")
    jqFind(j"#" & context.denseId & j" tbody").on(j"click", j"tr", proc(e: js) = handler(context.denseTable.context, e))
    jqFind(j"#" & context.detailedId & j" tbody").on(j"click", j"tr", proc(e: js) = handler(context.detailedTable.context, e))
    jqFind(j"#" & context.denseId & j" tbody").on(j"mouseover", j"td", proc(e: js) = handlerMouseover(context.denseTable.context, e))
    jqFind(j"#" & context.denseId & j" tbody").on(j"contextmenu", j"tr", proc(e: js) = handlerRightClick(context.denseTable.context, e))

    console.timeEnd(cstring"new events: load in datatable: context changes and handlers")

  else:

    console.time(cstring"new events: load in datatable: redraw")

    if context.redraw:
      context.redraw = false

    var events = self.service.events

    console.timeEnd(cstring"new events: load in datatable: redraw")
    cdebug "event_log: setup " & $(cstring"#" & context.denseId & cstring" tbody")
    # cdebug "event_log: setup " & $(cstring"#" & context.detailedId & cstring" tbody")
    jqFind(j"#" & context.denseId & j" tbody").on(j"click", j"tr", proc(e: js) = handler(context.denseTable.context, e))
    let denseWrapper = j"#" & self.denseId & j"_wrapper"  
    cast[Node](jq(denseWrapper)).findNodeInElement(".dataTables_scrollBody")
      .addEventListener(j"scroll", proc = self.denseTable.updateTableRows())
    jqFind(j"#" & context.detailedId & j" tbody").on(j"click", j"tr", proc(e: js) = handler(context.detailedTable.context, e))
    jqFind(j"#" & context.denseId & j" tbody").on(j"mouseover", j"td", proc(e: js) = handlerMouseover(context.denseTable.context, e))
    jqFind(j"#" & context.denseId & j" tbody").on(j"contextmenu", j"tr", proc(e: js) = handlerRightClick(context.denseTable.context, e))
    if self.resizeObserver.isNil:
      let componentTab = cast[Node](jq(&"#eventLogComponent-{self.id}"))
      let resizeObserver = createResizeObserver(proc(entries: seq[Element]) =
        for entry in entries:
          let timeout = setTimeout(proc =
            resizeEventLogHandler(self), 100))
      resizeObserver.observe(componentTab)
      self.resizeObserver = resizeObserver


proc eventLogKindView*(self: EventLogComponent, kind: EventLogKind): VNode =
  if self.kindsEnabled.hasKey(kind):
    buildHtml(
      tdiv(
        class = local("button") & " " & local("kind") & " " & local("selected-kind"),
        onclick = proc =
          discard jsdelete self.kindsEnabled[kind]
          self.recalculateKinds()
          self.redraw = true
          self.data.redraw()
      )
    ):
      text $kind
  else:
    buildHtml(
      tdiv(
        class = local("button") & " " & local("kind"),
        onclick = proc =
          self.kindsEnabled[kind] = true
          self.recalculateKinds()
          self.redraw = true
          self.data.redraw()
      )
    ):
      text $kind

proc recalculateKinds(self: EventLogComponent) =
  self.kinds = JsAssoc[types.EventLogKind, bool]{}

  for kind, enabled in self.kindsEnabled:
    if enabled:
      self.kinds[kind] = true

proc showOrHideOptionalColumn(self: EventLogComponent, column: EventOptionalColumn) =
  if self.columns.hasKey(column):
    discard jsdelete self.columns[column]
  else:
    self.columns[column] = true

  self.redrawColumns = true
  self.index += 1

  redrawAll()

proc eventLogColumnView*(self: EventLogComponent, column: EventOptionalColumn): VNode =
  let inputName = ($column).toLowerAscii

  buildHtml(
    li(class = "dropdown-list-item")
  ):
    label(
      `for`= inputName,
      onclick = proc = self.showOrHideOptionalColumn(column)):
      input(name = inputName,
            `type` = "checkbox",
            class = "checkbox",
            checked = toChecked(self.columns.hasKey(column)),
            value = ($column))
      span(class="checkmark")
      text $column

proc switchEventKindSelection(self: EventLogComponent, kind: EventLogKind) =
  self.selectedKinds[kind] = not self.selectedKinds[kind]
  self.redraw = true
  self.data.redraw()

proc changeAllEventKinds(self: EventLogComponent, value: bool) =
  for tag, _ in self.tags:
    for kind in tagKinds[tag]:
      self.selectedKinds[kind] = value

  self.redraw = true
  self.data.redraw()

proc isTagSelected(self: EventLogComponent, tag: EventTag): bool =
  var isChecked = true

  for kind in tagKinds[tag]:
    isChecked = self.selectedKinds[kind]
    if self.selectedKinds[kind]:
      break

  return isChecked

proc switchEventTagSelection(self: EventLogComponent, tag: EventTag, value: bool = false) =
  let isChecked = if not value: not self.isTagSelected(tag) else: true

  for kind in tagKinds[tag]:
    self.selectedKinds[kind] = isChecked

  self.redraw = true
  self.data.redraw()

proc checkIndeterminateCheckbox(self: EventLogComponent, tag: EventTag): (bool, string) =
  var isChecked = true
  var count = 0

  for kind in tagKinds[tag]:
    if self.selectedKinds[kind]:
      count += 1

  if count > 0 and count == tagKinds[tag].len:
    return (true, "checkmark")
  elif count != 0:
    return (true, "indeterminate-checkmark")
  else:
    return (false, "checkmark")

proc enableOrDisable(self: EventLogComponent): bool =
  var b: bool

  for tag, _ in self.tags:
    for kind in tagKinds[tag]:
      b = not self.selectedKinds[kind]
      if b:
        return b

  return b

proc isOnlyTraceSelected(self: EventLogComponent): bool =
  for tag, _ in self.tags:
    for kind in tagKinds[tag]:
      if self.selectedKinds[kind] and tag != EventTrace:
        return false
      elif not self.selectedKinds[kind] and tag == EventTrace:
        return false

  return true

proc isOnlyRecordedEventSelected(self: EventLogComponent): bool =
  for tag, _ in self.tags:
    for kind in tagKinds[tag]:
      if tag != EventTrace and not self.selectedKinds[kind]:
        return false
      if self.selectedKinds[kind] and tag == EventTrace:
        return false

  return true

proc onlyTrace(self: EventLogComponent) =
  let traceTags = [EventTrace]

  self.changeAllEventKinds(false)

  for tag in traceTags:
    self.switchEventTagSelection(tag, true)

proc onlyRecordedEvent(self: EventLogComponent) =
  let eventTags = [EventReads, EventFiles, EventNetwork, EventWrites, EventErrorEvents]

  self.changeAllEventKinds(false)

  for tag in eventTags:
    self.switchEventTagSelection(tag, true)

proc eventLogCategoryButtonView(self: EventLogComponent, event: EventDropDownBox): VNode =
  proc showDropdown(e: Event, et: VNode)
  let category = event
  let categoryName = ($event).toLowerAscii()
  let dropDownId = local("category-" & categoryName & fmt"-{self.id}")
  var dropDownClass = if event == Filter: local("category-dropdown-button") else: local("medium-control-button")
  let dropDownListId = dropDownId & "-list"
  var dropDownListClass = "dropdown-list"
  var dropDownContainerClass = "dropdown-container"
  var dropDownContainerId = "dropdown-container-id"
  var text = EVENT_LOG_BUTTON_NAMES[event]

  proc eventLogKindButtonCheckboxView(
    self: EventLogComponent,
    tag: EventTag,
    kind: EventLogKind
  ) : VNode =
    let checkBoxName = local($tag & "-" & $kind & "-checkbox")

    buildHtml(
      li(class = "dropdown-list-item")
    ):
      label(
        `for` = checkBoxName,
        onclick = proc (e: Event, et: VNode)=
          self.switchEventKindSelection(kind)
          self.denseTable.context.ajax.reload(nil, false)
          self.autoScrollUpdate = true
          showDropdown(e, et)
      ):
        input(
          name = checkBoxName,
          `type` = "checkbox",
          class = "checkbox",
          checked = toChecked(self.selectedKinds[kind]),
          value = ($kind)
        )
        span(class = "checkmark")
        text(EVENT_LOG_KIND_NAMES[kind])

  proc eventLogTagButtonCheckboxView(
    self: EventLogComponent,
    tag: EventTag
  ): VNode =
    let checkBoxName = local($tag & "-checkbox")
    let checkBoxState = self.checkIndeterminateCheckbox(tag)
    let isChecked = checkBoxState[0]
    let checkmarkClass = checkBoxState[1]

    if not isChecked and isChecked != self.isTagSelected(tag):
      self.switchEventTagSelection(tag)

    buildHtml(
      li(class = "dropdown-list-item")
    ):
      label(
        `for` = checkBoxName,
        onclick = proc (ev: Event, et: VNode) =
          self.switchEventTagSelection(tag)
          self.denseTable.context.ajax.reload(nil, false)
          self.autoScrollUpdate = true
          showDropdown(ev, et)
      ):
        input(
          name = checkBoxName,
          `type` = "checkbox",
          class = "checkbox",
          checked = toChecked(isChecked),
          value = ($tag)
        )
        span(class = checkmarkClass)
        text(EVENT_LOG_TAG_NAMES[tag])

  proc dropdownVNode(): VNode =
    var activeTraceClass = if self.isOnlyTraceSelected(): "active" else: ""
    var activeEventsClass = if self.isOnlyRecordedEventSelected(): "active" else: ""

    buildHtml(
      tdiv(class = dropDownContainerClass, id = dropDownContainerId)
    ):
      ul(
        id = dropDownListId,
        class = dropDownListClass,
        onmousedown = proc (ev: Event, et: VNode) =
          ev.preventDefault(),
        onclick = proc (ev: Event, et: VNode) =
          ev.stopPropagation()
      ):
        tdiv(class = "dropdown-list-tag"):
          for tag, _ in self.tags:
            eventLogTagButtonCheckboxView(self, tag)
        tdiv(class = "dropdown-kind-container"):
          for tag, _ in self.tags:
            tdiv(class = "dropdown-list-kind"):
              for kind in tagKinds[tag]:
                eventLogKindButtonCheckboxView(self, tag, kind)
      tdiv(class = "toggle-buttons"):
        tdiv(
          id = local("category-onlytrace"),
          class = local("medium-control-button") & fmt" {activeTraceClass}",
          tabIndex = "0",
          onmousedown = proc (e: Event, et: VNode) =
            e.preventDefault(),
          onclick = proc (e: Event, et: VNode) =
            e.stopPropagation()
            self.onlyTrace()
            self.denseTable.context.ajax.reload(nil, false)
            self.autoScrollUpdate = true
            showDropdown(e, et),
        ):
          text(EVENT_LOG_BUTTON_NAMES[EventDropDownBox.OnlyTrace])
          tdiv(
            id = "eventLog-tooltip-trace",
            class = "custom-tooltip",
          ): text("Display only trace logs: events that happened as part of the debugging")
        tdiv(
          id=local("category-only-recorded-event"),
          class = local("medium-control-button") & fmt" {activeEventsClass}",
          tabIndex = "0",
          onmousedown = proc (e: Event, et: VNode) =
            e.preventDefault(),
          onclick = proc (e: Event, et: VNode) =
            e.stopPropagation()
            self.onlyRecordedEvent()
            self.denseTable.context.ajax.reload(nil, false)
            self.autoScrollUpdate = true
            showDropdown(e, et)
        ):
          text(EVENT_LOG_BUTTON_NAMES[EventDropDownBox.OnlyRecordedEvent])
          tdiv(
            id = "eventLog-tooltip-event",
            class = "custom-tooltip",
          ): text("Display only recorded events: events from the original record")
        tdiv(
          id = local("category-enabledisable"),
          class = local("medium-control-button"),
          tabIndex = "0",
          onmousedown = proc (e: Event, et: VNode) =
            e.preventDefault(),
          onclick = proc (e: Event, et: VNode) =
            e.stopPropagation()
            self.changeAllEventKinds(self.enableOrDisable())
            self.denseTable.context.ajax.reload(nil, false)
            self.autoScrollUpdate = true
            showDropdown(e, et)
        ):
          text(if self.enableOrDisable(): "Enable All" else: "Disable All")

  proc showDropdown(e: Event, et: VNode) =
    var dropdownElem = document.getElementById(dropDownContainerId)
    
    if dropdownElem == nil:
      document.body.appendChild(vnodeToDom(dropdownVNode(), KaraxInstance()))
      dropdownElem = document.getElementById(dropDownContainerId)
    else:
      dropdownElem.innerHTML = ""
      dropdownElem.appendChild(vnodeToDom(dropdownVNode(), KaraxInstance()))

    let filterButton = document.getElementById(dropDownId)
    let rect = filterButton.getBoundingClientRect()
    let fullWidth = document.body.getBoundingClientRect().width

    dropdownElem.style.position = "absolute"
    dropdownElem.style.top = $(rect.bottom) & "px"
    dropdownElem.style.right = $(fullWidth - rect.right) & "px"
    dropdownElem.style.zIndex = 1000
    dropdownElem.style.display = "block"
    filterButton.focus()

  proc hideDropdown(e: Event, et: VNode) =
    let dropdownElem = document.getElementById(dropDownContainerId)
    if dropdownElem != nil:
      dropdownElem.style.display = "none"

  buildHtml(
    tdiv(
      id=dropDownId,
      class = dropDownClass,
      tabindex = "0",
      onclick = proc (e: Event, et: VNode) =
        for categoryType, value in self.dropDowns:
          if categoryType == category:
            self.dropDowns[categoryType] = not self.dropDowns[category]
        if not self.dropDowns[category] and self.focusedDropDowns[category]:
          cast[Element](e.target).blur(),
      onfocus = proc (e: Event, et: VNode) =
        self.focusedDropDowns[category] = true
        showDropdown(e, et),
      onblur = proc (e: Event, et: VNode) =
        if self.dropDowns[category] or self.focusedDropDowns[category]:
          self.focusedDropDowns[category] = false
          self.dropDowns[category] = false
          hideDropdown(e, et),
    )
  ):
    text(text)

proc eventLogHeaderView*(self: EventLogComponent): VNode =
  var search = proc =
    let value = jqFind("#eventLog-" & $self.id & "-search input")[0].value.to(cstring)
    if not self.isDetailed:
      self.denseTable.context.search(value).draw()
    else:
      self.detailedTable.context.search(value).draw()

  var buttonClass = "hamburger-dropdown"
  var dropDownListClass = "dropdown-list"

  if not self.isOptionalColumnsMenuOpen:
    dropDownListClass = dropDownListClass & " hidden"

  buildHtml(
    tdiv(class = local("header"))
  ):
    tdiv(id = "eventLog-" & $self.id & "-search", class = local("search")):
      input(
        class = "eventLog-search-field",
        `type` = "text",
        placeholder = "Find event",
        onchange = search,
        oninput = search
      )

    tdiv(class = local("switch") & " " & local("button") & " " & local("normal-color-button")):
      if not self.isDetailed:
        span(id = "detailed", onclick = proc =
          self.isDetailed = true
          redrawAll()):
          text "detailed"
      else:
        span(id = "dense", onclick = proc =
          self.isDetailed = false
          redrawAll()):
          text "dense"

    tdiv(class = local("categories")):
      eventLogCategoryButtonView(self, EventDropDownBox.Filter)

method onUpdatedTable*(self: EventLogComponent, response: TableUpdate) {.async.} =
  if not response.isTrace and self.drawId == response.data.draw:
    let dt = self.denseTable

    dt.rowsCount = response.data.recordsTotal
    self.service.loadEvents(response.data)

    var mutData = response.data

    for i, row in response.data.data:
      if row.base64Encoded:
        mutData.data[i].content = cstring(decode($response.data.data[i].content))

    self.tableCallback(mutData.toJs)
    self.data.redraw()

    if self.autoScrollUpdate:
      self.findActiveRow(self.activeRowTicks, true)
      self.autoScrollUpdate = false
    else:
      self.findActiveRow(self.activeRowTicks)

method onUpdatedTrace*(self: EventLogComponent, response: TraceUpdate) {.async.} =
  if response.firstUpdate or response.refreshEventLog or
      (not self.denseTable.context.isNil and cast[string](self.denseTable.context.search()) != ""):
    self.denseTable.context.ajax.reload(nil, false)
    self.findActiveRow(self.activeRowTicks, true)
  else:
    let dt = self.denseTable

    dt.rowsCount = response.totalCount
    self.data.redraw()

method restart*(self: EventLogComponent) =
  if not self.denseTable.isNil:
    try:
      self.denseTable.context.rows().remove()
      self.denseTable.context.rows().draw()
    except:
      cerror "event_log: remove: " & getCurrentExceptionMsg()

  if not self.detailedTable.isNil:
    try:
      self.detailedTable.context.rows().remove()
      self.detailedTable.context.rows().draw()
    except:
      cerror "event_log: remove: " & getCurrentExceptionMsg()

  self.eventsIndex = 0

method render*(self: EventLogComponent): VNode =
  kxiMap[j("eventLogComponent-" & $self.id)].afterRedraws.add(proc =
    self.events()
    let denseWrapper = j"#" & self.denseId & j"_wrapper"
    let detailedWrapper = j"#" & self.detailedId & j"_wrapper"
    let eventId = j"eventLogComponent-" & $self.id

    if not self.isDetailed:
      jq(denseWrapper).show()
      jq(detailedWrapper).hide()
    else:
      jq(denseWrapper).hide()
      jq(detailedWrapper).show()

    self.denseTable.updateTableRows(redraw = true)
    self.detailedTable.updateTableRows(redraw = true)

    if self.resizeObserver.isNil:
      let componentTab = cast[Node](jq(&"#eventLogComponent-{self.id}"))
      let resizeObserver = createResizeObserver(proc(entries: seq[Element]) =
        for entry in entries:
          let timeout = setTimeout(proc =
            resizeEventLogHandler(self), 100))
      resizeObserver.observe(componentTab)
      self.resizeObserver = resizeObserver
  )

  result = buildHtml(
    tdiv(
      class = componentContainerClass("eventLog"),
      tabIndex = "2",
      onclick = proc(ev: Event, v:VNode) = 
        ev.stopPropagation()
        if self.data.ui.activeFocus != self:
          self.data.ui.activeFocus = self
    )
  ):
    eventLogHeaderView(self)
    tdiv(class = local("dense-table") & " data-table"):
      table(id = self.denseId)
    if not self.denseTable.isNil:
      tableFooter(self.denseTable)
    tdiv(class = local("detailed-table") & " data-table"):
      table(id = self.detailedId)

proc scrollOnMove*(self: EventLogComponent, rowSelected: int) =
  if rowSelected > self.denseTable.endRow - 1 or rowSelected < self.denseTable.startRow:
    scrollTable(self.denseTable, $(rowSelected))
    self.denseTable.updateTableRows()

const MOVE_DELAY: int64 = 300

proc afterMove(self: EventLogComponent) =
  let currentTime: int64 = now()
  let lastTimePlusDelay = (self.lastJumpFireTime.toJs + MOVE_DELAY.toJs).to(int64)

  if lastTimePlusDelay <= currentTime:
    self.findActiveRow(self.activeRowTicks, true)
    self.isFlowUpdate = false

method onCompleteMove*(self: EventLogComponent, response: MoveState) {.async.} =
  if self.data.ui.activeFocus != self:
    let currentTime: int64 = now()

    self.activeRowTicks = response.location.rrTicks
    self.lastJumpFireTime = currentTime
    if self.isFlowUpdate:
      self.findActiveRow(self.activeRowTicks, false)

      discard windowSetTimeout(
        proc =
          self.afterMove(),
          cast[int](MOVE_DELAY)
      )
    else:
      self.findActiveRow(self.activeRowTicks, true)

method onUp*(self: EventLogComponent) {.async.} =
  if self.rowSelected != 0:
    self.rowSelected -= 1
    self.focusItem()
    self.scrollOnMove(self.rowSelected)

method onDown*(self: EventLogComponent) {.async.} =
  if self.rowSelected < self.denseTable.rowsCount - 1:
    self.rowSelected += 1
    self.focusItem()
    self.scrollOnMove(self.rowSelected)

method onGotoStart*(self: EventLogComponent) {.async.} =
  self.rowSelected = 0
  self.focusItem()
  self.scrollOnMove(self.rowSelected)

method onGotoEnd*(self: EventLogComponent) {.async.} =
  self.rowSelected = self.denseTable.rowsCount - 1
  self.focusItem()
  self.scrollOnMove(self.rowSelected)

method onFindOrFilter*(self: EventLogComponent) {.async.} =
  var divElement = document.getElementsByClass("eventLog-search-field")[self.id]
  divElement.focus()

method onEnter*(self: EventLogComponent) {.async.} =
  let event = cast[ProgramEvent](self.service.events[self.rowSelected - self.hiddenRows])
  self.programEventJump(event)
