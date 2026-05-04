import
  ../[ types, communication ],
  ../../common/ct_event,
  ui_imports, colors, trace, typetraits, strutils, jsconsole,
  datatable, strutils, base64

# ---------------------------------------------------------------------------
# ViewModel layer — wired in parallel with the legacy event-bus code.
# The EventLogVM receives the same data but does not affect rendering yet.
# ---------------------------------------------------------------------------
import std/json
from ../viewmodel/backend/backend_service import BackendService, BackendFuture
import ../viewmodel/store/replay_data_store
from ../viewmodel/viewmodels/event_log_vm import
  EventLogVM, createEventLogVM
from isonim/web/dom_api import nil
from ../viewmodel/views/isonim_event_log_view import
  mountIsoNimEventLog, mountIsoNimEventLogWithDataTables

# Module-level EventLogVM instance. Created once and fed data whenever
# the legacy event-bus handlers fire. Rendering still reads from legacy
# data so behaviour is unchanged.
var eventLogVMInstance: EventLogVM
var eventLogVMStore: ReplayDataStore
var isoNimEventLogMounted*: bool = false

# Reference to the EventLogComponent instance so that the IsoNim mount
# callback can trigger DataTables initialisation via events().
var eventLogComponentRef: EventLogComponent

proc tryMountIsoNimEventLogPanel()
proc eventLogAfterRedraws(self: EventLogComponent)

# ---------------------------------------------------------------------------
# ViewModel bridge procs — sync legacy event data into the parallel store.
# ---------------------------------------------------------------------------

proc initEventLogVMWithStore*(store: ReplayDataStore) =
  ## Initialise the parallel EventLogVM using an externally-provided
  ## ReplayDataStore (typically the shared store from SessionViewModel).
  ##
  ## If a stub-backed instance already exists (created by initEventLogVM
  ## before the real backend was available), it is replaced so that the
  ## panel uses the real DapApi instead of the no-op stub.
  if eventLogVMInstance != nil:
    clog "EventLogVM: replacing existing instance with shared-store version"
    isoNimEventLogMounted = false
  eventLogVMStore = store
  eventLogVMInstance = createEventLogVM(store)
  clog "EventLogVM: parallel ViewModel instance created (shared store)"
  tryMountIsoNimEventLogPanel()

proc initEventLogVM() =
  ## Lazily create the parallel EventLogVM backed by a stub
  ## BackendService.  Fallback when no shared store has been provided
  ## via `initEventLogVMWithStore`.
  if eventLogVMInstance != nil:
    return

  let stubSend = proc(command: string, args: JsonNode): BackendFuture[JsonNode] =
    when defined(js):
      result = newPromise proc(resolve: proc(resp: JsonNode)) =
        resolve(%*{})
    else:
      var fut = newFuture[JsonNode]("stub-backend")
      fut.complete(%*{})
      result = fut

  let stubBackend = BackendService(
    sendProc: stubSend,
    onEventProc: proc(handler: proc(event: JsonNode)) = discard,
    disconnectProc: proc() = discard,
  )

  eventLogVMStore = createReplayDataStore(stubBackend)
  eventLogVMInstance = createEventLogVM(eventLogVMStore)
  clog "EventLogVM: parallel ViewModel instance created (stub backend)"
  tryMountIsoNimEventLogPanel()

proc syncEventLogDebuggerPosition(rrTicks: int, path: cstring, line: int) =
  ## Mirror the legacy debugger position into the ViewModel store so
  ## the EventLogVM's auto-load effect fires with the updated rrTicks.
  if eventLogVMStore.isNil:
    return
  let ticks = cast[uint64](rrTicks)
  eventLogVMStore.updateDebuggerPosition(ticks, $path, line)
  clog fmt"EventLogVM: synced debugger rrTicks={ticks}"

proc tryMountIsoNimEventLogPanel() =
  ## Mount the IsoNim event log view into the GoldenLayout-managed
  ## event log component container. The container is created by
  ## GoldenLayout with the id `eventLogComponent-0`. The IsoNim view
  ## replaces the previous component content and becomes the primary renderer,
  ## creating the DOM structure that DataTables attaches to.
  ##
  ## After mounting:
  ## - `isoNimEventLogMounted` is set to true
  ## - Generic component rendering stays on the direct mount path
  ## - The kxiMap entry is removed so redrawAll() skips this component
  ## - The EventLogComponent's events() runs to init DataTables on the
  ##   IsoNim-created `<table>` elements
  ## - Event handlers (onUpdatedTable, onUpdatedEvents, etc.) still feed
  ##   data through the DataTables API; IsoNim effects can also react
  ##
  ## Safe to call multiple times — mounts only once.
  cerror "tryMountIsoNimEventLogPanel: called, isoNimEventLogMounted=" & $isoNimEventLogMounted & " vmIsNil=" & $eventLogVMInstance.isNil & " compRefIsNil=" & $eventLogComponentRef.isNil
  if isoNimEventLogMounted or eventLogVMInstance.isNil:
    cerror "tryMountIsoNimEventLogPanel: skipping (already mounted or VM nil)"
    return
  if eventLogComponentRef.isNil:
    cerror "tryMountIsoNimEventLogPanel: skipping (eventLogComponentRef is nil)"
    return

  # Wait for the DOM container to exist. GoldenLayout creates it when
  # the component is registered. IsoNim mounts directly into it —
  # no Karax renderer is involved.
  let key = cstring"eventLogComponent-0"
  var eventLogRetryCount = 0
  proc doMount() =
    if isoNimEventLogMounted:
      return
    eventLogRetryCount += 1
    let container = dom_api.getElementById(dom_api.document, key)
    if dom_api.isNodeNil(dom_api.Node(container)):
      if eventLogRetryCount > 200:
        cerror "tryMountIsoNimEventLogPanel: not ready after 200 retries, giving up"
        return
      discard setTimeout(proc() = doMount(), 10)
      return

    let containerNode = dom_api.Node(container)
    while not dom_api.isNodeNil(containerNode.firstChild):
      discard dom_api.removeChild(containerNode, containerNode.firstChild)

    isoNimEventLogMounted = true

    let comp = eventLogComponentRef
    let denseId = "eventLog-" & $comp.id & "-dense-table-" & $comp.index
    let detailedId = "eventLog-" & $comp.id & "-detailed-table-" & $comp.index
    let searchId = "eventLog-" & $comp.id & "-search"

    try:
      mountIsoNimEventLogWithDataTables(
        container,
        eventLogVMInstance,
        comp.id,
        denseId,
        detailedId,
        searchId,
        proc() =
          comp.init = false
          comp.redrawColumns = true
          comp.eventLogAfterRedraws()
      )
      cerror "tryMountIsoNimEventLogPanel: mount COMPLETE in #eventLogComponent-0"

    except:
      cerror "tryMountIsoNimEventLogPanel: mount EXCEPTION: " & getCurrentExceptionMsg()

  doMount()

var arg: js

const
  CLICK_DELAY_TIMER = 5

when defined(ctInExtension):
  var eventLogComponentForExtension* {.exportc.}: EventLogComponent = makeEventLogComponent(data, 0, inExtension = true)

  proc bindEventLogExtensionHost(component: EventLogComponent) =
    if component.extensionRendererId.len == 0:
      return

    let host = document.getElementById(component.extensionRendererId)
    if host.isNil:
      return

    # The extension event-log surface has no panel markup of its own; keep the
    # exported component alive without retaining an empty Karax renderer.
    host.innerHTML = cstring""

  proc makeEventLogComponentForExtension*(id: cstring): EventLogComponent {.exportc.} =
    if eventLogComponentForExtension.extensionRendererId.len == 0:
      eventLogComponentForExtension.extensionRendererId = id
      eventLogComponentForExtension.bindEventLogExtensionHost()
    result = eventLogComponentForExtension

proc events(self: EventLogComponent)
proc resizeEventLogHandler*(self: EventLogComponent)

proc denseId*(context: EventLogComponent): cstring =
  cstring("eventLog-" & $context.id & "-dense-table-" & $context.index)

proc detailedId*(context: EventLogComponent): cstring =
  cstring("eventLog-" & $context.id & "-detailed-table-" & $context.index)

template local*(expression: untyped): untyped {.dirty.} =
  cstring(self.type.name[0 .. 0].toLowerAscii() & self.type.name[1..^10] & "-" & expression)

proc resizeEventLogHandler*(self: EventLogComponent) =
  if self.denseTable.isNil or self.denseTable.context.isNil:
    return

  self.denseTable.resizeTable()
  if not self.denseTable.footerDom.isNil:
    self.denseTable.updateTableFooter()
  # self.detailedTable.resizeTable()

proc filterEvents(self: EventLogComponent): seq[ProgramEvent] =
  var events: seq[ProgramEvent] = @[]

  for i in 0..<self.programEvents.len():
    let event = self.programEvents[i]
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

    of EventLogKind.EvmEvent:
      if eventElement.metadata != "":
        fmt"{eventElement.metadata}: {eventElement.content}"
      else:
        fmt"{eventElement.content}"
    else:
      fmt"event {eventElement.kind}"

proc eventJump(self: EventLogComponent, event: ProgramEvent) =
  self.api.emit(CtEventJump, event)
  self.api.emit(InternalNewOperation, NewOperation(name: fmt"Event jump #{event.rrEventId}", stableBusy: true))

proc programEventJump(self: EventLogComponent, event: ProgramEvent) =
  self.findActiveRow(event.directLocationRRTicks)
  self.activeRowTicks = event.directLocationRRTicks
  self.eventJump(event)

const DELAY: int64 = 200 # milliseconds

proc findTRNode*(node: js): js =
  return if node.tagName.to(cstring) == cstring("TR"):
    node else: findTRNode(node.parentNode)

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
    let location = self.location
    event = cast[ProgramEvent](data)
    event.highLevelPath = location.highLevelPath
    event.highLevelLine = location.highLevelLine
    event.metadata = ""
    event.bytes = 0
    event.tracepointResultIndex = 0
    event.eventIndex = 0
    event.stdout = true
    event.maxRRTicks = 0
  else:
    # DataTables emits placeholder rows while the table is empty; they are not real events.
    return
  self.programEventJump(event)
  # if self.data.ui.activeFocus != self:
  #   self.data.focusComponent(self)

proc events(self: EventLogComponent) =
  var context = self

  proc reinit(self: EventLogComponent) =
    self.kinds = JsAssoc[EventLogKind, bool]{}
    self.kindsEnabled = JsAssoc[EventLogKind, bool]{}
    self.tags = JsAssoc[EventTag, bool]{}
    for kind in EventLogKind.low .. EventLogKind.high:
      self.kinds[kind] = true
      self.kindsEnabled[kind] = true
    for tag in EventTag.low .. EventTag.high:
      self.tags[tag] = true

  proc handler(table: js, e: js) =
    let currentTime: int64 = now()
    if currentTime - self.lastJumpFireTime > CLICK_DELAY_TIMER:
      self.lastJumpFireTime = currentTime
      let isAction = cast[bool](e.target.classList[0] == "row-expander".toJs)
      if isAction:
        let textElement = e.currentTarget.childNodes[3]
        if textElement.classList[0] == "eventLog-text".toJs:
          if textElement.style.toJs.maxHeight == "24px".toJs:
            textElement.style.overflow = "auto"
            textElement.style.maxHeight = "20ch".toJs
            e.target.classList.remove("flow-hide-content")
            e.target.classList.add("flow-show-content")
          else:
            textElement.style.overflow = ""
            textElement.style.maxHeight = "24px".toJs
            e.target.classList.remove("flow-show-content")
            e.target.classList.add("flow-hide-content")
      else:
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
    else:
      # Empty-table placeholder rows should not open an event view.
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
            # width: cstring"100px",
            className: cstring"direct-location-rr-ticks eventLog-cell",
            data: cstring"directLocationRRTicks",
            orderable: true,
            targets: 0,
            title: cstring"direction location rr ticks",
            render: proc(directLocationRRTicks: int): cstring =
              renderRRTicksLine(directLocationRRTicks, self.data.minRRTicks, self.data.maxRRTicks, "event-rr-ticks-line")
          },
          js{
            className: cstring"eventLog-index eventLog-cell",
            data: cstring"rrEventId",
            title: cstring"rr event id"
          },
      ]
      if self.usesMaterializedTracesTrace:
        let lower = cstring("FullPath".toLowerAscii())

        denseColumns.add(
          js{
            className: cstring"eventLog-" & lower & " " & local("cell"),
            searchable: true,
            title: lower,
            data: cstring"fullPath",
          }
        )
      denseColumns.add(
        @[
          js{
            className: cstring"eventLog-event eventLog-cell",
            searchable: true,
            data: cstring"kind",
            title: cstring"event-image",
            render: proc(kind: EventLogKind, t: js, event: ProgramEvent): cstring =
              if event.content.split("\n").len() == 2 and event.content.split("\n")[^1] == "":
                cstring""
              elif event.content.split("\n").len() > 1:
                cstring"""<span class="row-expander flow-hide-content flow-view-more-button"/>"""
              else:
                cstring""
          },
          js{
            className: cstring"eventLog-text eventLog-cell",
            searchable: true,
            data: cstring"content",
            title: cstring"text",
            render: proc(content: cstring, t: js, event: ProgramEvent): cstring =
              let text = case event.kind:
                of Write, WriteFile, WriteOther, Read, ReadFile, ReadOther,
                  OpenDir, ReadDir, CloseDir, Socket, EventLogKind.Open, EventLogKind.Error, EventLogKind.EvmEvent:
                  cstring(eventLogDescriptionRepr(event, event.eventIndex))

                of TraceLogEvent:
                  event.content

              text
          }
        ]
      )

      var detailedColumns = @[
          js{
            className: cstring"eventLog-detailed-index eventLog-cell",
            data: cstring"rrEventId"},
          js{
            className: cstring"eventLog-detailed-event eventLog-cell",
            searchable: true,
            data: cstring"kind",
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

      # if self.usesMaterializedTracesTrace:
      #   let lower = cstring("FullPath".toLowerAscii())

      #   denseColumns.add(
      #     js{
      #       className: cstring"eventLog-" & lower & " " & local("cell"),
      #       searchable: true,
      #       title: lower,
      #       data: cstring"fullPath",
      #     }
      #   )
      #   if false:
      #     let lower = cstring("LowLevelLocation".toLowerAscii())

      #     denseColumns.add(
      #       js{
      #         className: cstring"eventLog-" & lower & " " & local("cell"),
      #         searchable: true,
      #         title: lower,
      #         data: cstring"lowLevelLocation",
      #       }
      #     )

      console.timeEnd(cstring"new events: load in datatable: optional columns")
      console.time(cstring"new events: load in datatable: dense datatable preparation and call")

      let denseTableElement = jqFind(cstring"#" & self.denseId)

      denseTableElement.DataTable.ext.errMode = cstring"throw"
      self.denseTable.context = denseTableElement.DataTable(
        js{
          serverSide:     true,
          deferRender:    true,
          processing:     true,
          ordering:       true,
          searching:      true,
          scrollY:        2000,
          scrollCollapse: true,
          scroller:       true,
          scrollerCollapse: true,
          fixedColumns:   true,
          info: false,
          lengthChange: false,
          search: false,
          label: false,
          layout: js{
            top:        nil,
            topStart:   nil,
            topEnd:     nil,
            bottom:     nil,
            bottomStart:nil,
            bottomEnd:  nil
          },
          pageLength: -1,
          order:          @[[0.toJs, (cstring"asc").toJs]],
          colResize:      js{
            isEnabled: true,
            saveState: true},
          columns:        denseColumns,
          bInfo: false,
          createdRow: rowTimestamp,
          language: js{
            emptyTable: proc: cstring =
              # TODO if self.receivedUpdates:
              """The current record appears to not have any system events like std read/write,
              network or disc operations.</br>You can add trace point events to your code by selecting any
              line of code and pressing "Enter"""".cstring
              # else:
              #   "Loading record events...".cstring
          },
          ajax: proc(
            data: TableArgs,
            callback: proc(data: js),
            settings: js
          ) =
            var mutData = data
            self.tableCallback = callback
            self.drawId += 1
            mutData.draw = self.drawId
            self.drawId = mutData.draw
            self.hiddenRows = data.start
            let updateTableArgs =
              UpdateTableArgs(
                tableArgs: mutData,
                selectedKinds: self.selectedKinds,
                isTrace: false,
                traceId: 0,
              )
            self.api.emit(CtUpdateTable, updateTableArgs),
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
    context.denseTable.context = jqFind(cstring"#" & context.denseId).DataTable()
    context.detailedTable.context = jqFind(cstring"#" & context.detailedId).DataTable()
    context.redrawColumns = context.tableCallback.isNil
    context.eventsIndex = self.programEvents.len

    cdebug "event_log: setup " & $(cstring"#" & context.denseId & cstring" tbody")
    # cdebug "event_log: setup " & $(cstring"#" & context.detailedId & cstring" tbody")
    jqFind(cstring"#" & context.denseId & cstring" tbody").on(cstring"click", cstring"tr", proc(e: js) = handler(context.denseTable.context, e))
    jqFind(cstring"#" & context.detailedId & cstring" tbody").on(cstring"click", cstring"tr", proc(e: js) = handler(context.detailedTable.context, e))
    jqFind(cstring"#" & context.denseId & cstring" tbody").on(cstring"mouseover", cstring"td", proc(e: js) = handlerMouseover(context.denseTable.context, e))
    jqFind(cstring"#" & context.denseId & cstring" tbody").on(cstring"contextmenu", cstring"tr", proc(e: js) = handlerRightClick(context.denseTable.context, e))

    console.timeEnd(cstring"new events: load in datatable: context changes and handlers")

  else:

    console.time(cstring"new events: load in datatable: redraw")

    var events = self.programEvents

    console.timeEnd(cstring"new events: load in datatable: redraw")
    cdebug "event_log: setup " & $(cstring"#" & context.denseId & cstring" tbody")
    # cdebug "event_log: setup " & $(cstring"#" & context.detailedId & cstring" tbody")
    jqFind(cstring"#" & context.denseId & cstring" tbody").on(cstring"click", cstring"tr", proc(e: js) = handler(context.denseTable.context, e))
    let denseWrapper = cstring"#" & self.denseId & cstring"_wrapper"
    cast[Node](jq(denseWrapper)).findNodeInElement(".dt-scroll-body")
      .addEventListener(
        cstring"scroll",
        proc () =
          self.denseTable.updateTableRows(redraw = true)
          self.redraw()
      )
    jqFind(cstring"#" & context.detailedId & cstring" tbody").on(cstring"click", cstring"tr", proc(e: js) = handler(context.detailedTable.context, e))
    jqFind(cstring"#" & context.denseId & cstring" tbody").on(cstring"mouseover", cstring"td", proc(e: js) = handlerMouseover(context.denseTable.context, e))
    jqFind(cstring"#" & context.denseId & cstring" tbody").on(cstring"contextmenu", cstring"tr", proc(e: js) = handlerRightClick(context.denseTable.context, e))

    if self.resizeObserver.isNil:
      let componentTab = cast[Node](jq(&"#eventLogComponent-{self.id}"))
      let resizeObserver = createResizeObserver(proc(entries: seq[Element]) =
        for entry in entries:
          let timeout = setTimeout(proc =
            resizeEventLogHandler(self), 100))
      resizeObserver.observe(componentTab)
      self.resizeObserver = resizeObserver


proc loadEvents*(self: EventLogComponent, update: TableData) =
  console.log(cstring(fmt"event_log: loadEvents records={update.data.len} draw={update.draw}"))
  self.programEvents = @[]
  if update.data.len() > 0:
    self.receivedUpdates = true
  for i, row in update.data:
    self.programEvents.add(
      ProgramEvent(
        kind: row.kind,
        content: row.content,
        rrEventId: row.rrEventId,
        metadata: row.metadata,
        highLevelPath: row.fullPath,
        directLocationRRTicks: row.directLocationRRTicks,
        eventIndex: i,
        tracepointResultIndex: 0,
        base64Encoded: row.base64Encoded,
        maxRRTicks: data.maxRRTicks,
        stdout: row.stdout
      )
    )


method onUpdatedTable*(self: EventLogComponent, res: CtUpdatedTableResponseBody) {.async.} =
  let response = res.tableUpdate

  if not response.isTrace and self.drawId == response.data.draw:
    let dt = self.denseTable

    dt.rowsCount = response.data.recordsTotal
    self.loadEvents(response.data)

    var mutData = response.data

    for i, row in response.data.data:
      if row.base64Encoded:
        mutData.data[i].content = cstring(decode($response.data.data[i].content))

    self.tableCallback(mutData.toJs)
    self.redraw()

    # The IsoNim event-log shell renders the footer once with a static
    # class string (`data-tables-footer 0to0`) and child counters fixed
    # at "0".  The current shell is mounted once and table redraws do not
    # rebuild that wrapper, so its class string and inner texts must be
    # updated explicitly after each ajax callback.  `updateTableRows` recomputes
    # `startRow`/`endRow` from the Scroller's current page and the new
    # `rowsCount`; `updateTableFooter` then writes those values into
    # the visible counters and parent class.  Page-object tests parse
    # the parent `.data-tables-footer` class with `(\d*)to`, so keeping
    # it in sync is part of the test contract.
    if not dt.isNil and not dt.context.isNil:
      dt.updateTableRows(redraw = false)
      if not dt.footerDom.isNil:
        dt.updateTableFooter()

    if self.autoScrollUpdate:
      self.findActiveRow(self.activeRowTicks, true)
      self.autoScrollUpdate = false
    else:
      self.findActiveRow(self.activeRowTicks)

    # When the backend returns 0 records but the debugger has already
    # positioned (self.started), the event data may not have been loaded
    # yet (ct/event-load still in flight).  Schedule retries with
    # exponential back-off so DataTables eventually populates once the
    # backend is ready.  Stop retrying after events arrive or after a
    # maximum number of attempts to avoid infinite spinning.
    if response.data.recordsTotal == 0 and self.started and
       not self.receivedUpdates and self.pendingReloadRetries < 8:
      self.pendingReloadRetries += 1
      let delay = 250 * self.pendingReloadRetries  # 250, 500, 750, ... ms
      cerror "[PIPELINE] event_log: onUpdatedTable got 0 records, scheduling reload retry " &
             $self.pendingReloadRetries & " in " & $delay & "ms"
      discard setTimeout(proc() =
        if not self.receivedUpdates and
           not self.denseTable.isNil and not self.denseTable.context.isNil:
          self.denseTable.context.ajax.reload(nil, false)
      , delay)

method onUpdatedTrace*(self: EventLogComponent, response: TraceUpdate) {.async.} =
  if response.firstUpdate or response.refreshEventLog or
      (not self.denseTable.context.isNil and cast[string](self.denseTable.context.search()) != ""):
    self.denseTable.context.ajax.reload(nil, false)
    self.findActiveRow(self.activeRowTicks, true)
  else:
    let dt = self.denseTable

    dt.rowsCount = response.totalCount
    self.redraw()

    # Keep the IsoNim-rendered footer in sync with the new totalCount
    # (see comment in `onUpdatedTable` for the full rationale — the
    # static IsoNim shell does not re-render on `redraw()`).
    if not dt.isNil and not dt.context.isNil:
      dt.updateTableRows(redraw = false)
      if not dt.footerDom.isNil:
        dt.updateTableFooter()

method onUpdatedEvents*(self: EventLogComponent, response: seq[ProgramEvent]) {.async.} =
  self.receivedUpdates = true
  if response.len > 0:
    self.data.maxRRTicks = response[0].maxRRTicks
  if self.ignoreOutput:
    return

  for element in response:
    self.programEvents.add(element)

  if not self.denseTable.isNil and not self.denseTable.context.isNil:
    self.denseTable.context.ajax.reload()
  self.redraw()


method clear*(self: EventLogComponent) =
  if not self.denseTable.isNil and not self.denseTable.context.isNil:
    try:
      self.denseTable.context.clear().draw()
    except:
      cerror "event_log: clear dense: " & getCurrentExceptionMsg()

  if not self.detailedTable.isNil and not self.detailedTable.context.isNil:
    try:
      self.detailedTable.context.clear().draw()
    except:
      cerror "event_log: clear detailed: " & getCurrentExceptionMsg()

  self.programEvents = @[]
  self.eventsIndex = 0
  self.rowSelected = 0
  self.activeRowTicks = 0
  self.hiddenRows = 0

method restart*(self: EventLogComponent) =
  self.clear()
  if not self.denseTable.isNil and not self.denseTable.context.isNil:
    try:
      self.denseTable.context.rows().remove()
      self.denseTable.context.rows().draw()
    except:
      cerror "event_log: remove: " & getCurrentExceptionMsg()
    self.denseTable.context = nil

  if not self.detailedTable.isNil and not self.detailedTable.context.isNil:
    try:
      self.detailedTable.context.rows().remove()
      self.detailedTable.context.rows().draw()
    except:
      cerror "event_log: remove: " & getCurrentExceptionMsg()
    self.detailedTable.context = nil

  self.drawId = 0
  self.tableCallback = nil
  self.autoScrollUpdate = false
  self.started = false
  self.isFlowUpdate = false
  self.init = false
  self.redrawColumns = true
  self.redraw()

proc eventLogAfterRedraws(self: EventLogComponent) =
  self.events()
  let denseWrapper = cstring"#" & self.denseId & cstring"_wrapper"
  let detailedWrapper = cstring"#" & self.detailedId & cstring"_wrapper"
  let componentTab = cast[Node](jq(&"#eventLogComponent-{self.id}"))

  self.denseTable.footerDom =
    cast[Element](componentTab.findNodeInElement(".data-tables-footer"))

  if not self.inExtension:
    if not self.isDetailed:
      jq(denseWrapper).show()
      jq(detailedWrapper).hide()
    else:
      jq(denseWrapper).hide()
      jq(detailedWrapper).show()

  self.denseTable.updateTableRows(redraw = true)
  self.detailedTable.updateTableRows(redraw = true)
  # if self.denseTable.scrollAreaHeight == 0:
  resizeEventLogHandler(self)

# EventLogComponent.render() removed: IsoNim is the primary renderer.
# Generic callers are expected to use direct IsoNim mount paths. All
# real rendering is handled by tryMountIsoNimEventLogPanel().

when defined(ctInExtension):
  method redrawForExtension*(self: EventLogComponent) =
    self.bindEventLogExtensionHost()

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
  # Feed the same position into the parallel ViewModel store.
  initEventLogVM()
  syncEventLogDebuggerPosition(
    response.location.rrTicks,
    response.location.path,
    response.location.line)

  self.location = response.location
  let lang = toLangFromFilename(self.location.path)
  # if self.data.ui.activeFocus != self:
  if not self.usesMaterializedTracesTraceSet:
    self.usesMaterializedTracesTrace = lang != LangUnknown and lang.usesMaterializedTraces
    self.usesMaterializedTracesTraceSet = true
    try:
      self.denseTable.context.column(2).visible(false)
    except:
      cwarn "Complete move came before initializing the event log component"

  let currentTime: int64 = now()
  self.location = response.location

  self.activeRowTicks = response.location.rrTicks
  self.lastJumpFireTime = currentTime
  if self.isFlowUpdate:
    self.findActiveRow(self.activeRowTicks, false)

    discard windowSetTimeout(
      proc =
        self.afterMove(),
        cast[int](MOVE_DELAY)
    )
    # else:
    #   self.findActiveRow(self.activeRowTicks, true)

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
  let event = cast[ProgramEvent](self.programEvents[self.rowSelected - self.hiddenRows])
  self.programEventJump(event)

method register*(self: EventLogComponent, api: MediatorWithSubscribers) =
  self.api = api

  # Store a module-level reference so the IsoNim mount callback can
  # trigger DataTables initialisation via eventLogAfterRedraws().
  if eventLogComponentRef.isNil:
    eventLogComponentRef = self
    # If the VM was already created before the component registered,
    # try mounting now.
    tryMountIsoNimEventLogPanel()

  api.subscribe(CtCompleteMove, proc(kind: CtEventKind, response: MoveState, sub: Subscriber) =
    discard self.onCompleteMove(response)
    # On the first CtCompleteMove, DataTables has already been initialised
    # and its initial ajax request returned 0 records (the backend had not
    # finished loading events from the ct/event-load request yet).
    # Trigger a DataTables ajax reload so it re-requests data now that the
    # backend has had time to load events.  A short delay gives the backend
    # a margin to finish processing ct/event-load before the reload fires.
    if not self.started:
      self.started = true
      # Emit CtEventLoad to ensure the backend loads events.
      # The IsoNim EventLogVM auto-load effect may not fire reliably
      # yet, so the legacy CtEventLoad path is the primary trigger.
      self.api.emit(CtEventLoad, EmptyArg())
      # Schedule a single delayed DataTables ajax reload.  The
      # onUpdatedTable retry mechanism handles further retries if
      # the backend hasn't finished loading events yet.
      if not self.denseTable.isNil and not self.denseTable.context.isNil:
        discard setTimeout(proc() =
          if not self.denseTable.isNil and not self.denseTable.context.isNil:
            cerror "[PIPELINE] event_log: first CtCompleteMove, reloading DataTables ajax"
            self.denseTable.context.ajax.reload(nil, false)
        , 500)
  )

  api.subscribe(CtUpdatedEvents, proc(kind: CtEventKind, response: seq[ProgramEvent], sub: Subscriber) =
    discard self.onUpdatedEvents(response)
  )

  api.subscribe(CtUpdatedEventsContent, proc(kind: CtEventKind, response: cstring, sub: Subscriber) =
    if self.ignoreOutput:
      return

    let lines = response.split(jsNl)
    var lineIndex = 0
    var eventsIndex = 0
    while lineIndex < lines.len and eventsIndex < self.programEvents.len:
      while true:
        if eventsIndex < self.programEvents.len:
          if self.programEvents[eventsIndex].kind in {Write, WriteFile, WriteOther, Read, ReadFile, ReadOther}:
            self.programEvents[eventsIndex].content = lines[lineIndex]
            lineIndex += 1
          eventsIndex += 1
        else:
          echo fmt"warn: no event for line number {lineIndex}"
          break

    self.redraw()
  )
  api.subscribe(CtUpdatedTable, proc(kind: CtEventKind, response: CtUpdatedTableResponseBody, sub: Subscriber) =
    discard self.onUpdatedTable(response)
  )
  api.subscribe(CtUpdatedTrace, proc(kind: CtEventKind, response: TraceUpdate, sub: Subscriber) =
    discard self.onUpdatedTrace(response)
  )

  api.emit(InternalLastCompleteMove, EmptyArg())

proc registerEventLogComponent*(component: EventLogComponent, api: MediatorWithSubscribers) {.exportc.} =
  component.register(api)
