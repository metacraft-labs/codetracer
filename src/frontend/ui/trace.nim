import
  ui_imports, value, datatable,
  ../[ types, lang, utils, renderer, communication, dap, event_helpers ],
  ../../common/ct_event

let
  MIN_EDITOR_WIDTH: float = 20 #%
  MAX_EDITOR_WIDTH: float = 70 #%
# LINE_NUMBERS_COLUMN_WIDTH: int = 81 #px
  RUN_TRACE_MESSAGE: cstring = "Press Ctrl+Enter to run the trace."
  NO_RESULTS_MESSAGE: cstring = "No results. Line was not reached (or errors while evaluating logs)."

proc getCurrentMonacoTheme(editor: MonacoEditor): cstring {.importjs:"#._themeService._theme.themeName".}
proc toggleTrace*(editorUI: EditorViewComponent, name: cstring, line: int)
proc closeTrace*(self: TraceComponent)
proc resizeTraceHandler(self: TraceComponent)

when defined(ctInExtension):
  var tracepointComponentMapping* {.exportc.}: JsAssoc[cstring, JsAssoc[int, TraceComponent]] = JsAssoc[cstring, JsAssoc[int, TraceComponent]]{}
  # var tracepointComponentSeq* {.exportc.}: seq[TraceComponent] = @[]
  proc makeTracepointComponentForExtension*(id: cstring, line: int, name: cstring, traceId: int): TraceComponent {.exportc.} =
    # var tracepointComponentForExtension* {.exportc.}: TraceComponent = makeTraceComponent(data, inExtension = true)
    if not tracepointComponentMapping.hasKey(name):
      tracepointComponentMapping[name] = JsAssoc[int, TraceComponent]{}
    if not tracepointComponentMapping[name].hasKey(line):
      tracepointComponentMapping[name][line] = makeTraceComponent(data, inExtension = true, traceId = traceId)
    if tracepointComponentMapping[name][line].kxi.isNil:
      tracepointComponentMapping[name][line].kxi = setRenderer(proc: VNode = tracepointComponentMapping[name][line].render(), id, proc = discard)
      tracepointComponentMapping[name][line].line = line
      tracepointComponentMapping[name][line].name = name
    return tracepointComponentMapping[name][line]
    # if tracepointComponentForExtension.kxi.isNil:
    #   tracepointComponentForExtension.kxi = setRenderer(proc: VNode = tracepointComponentForExtension.render(), id, proc = discard)

proc calcTraceWidth(self: TraceComponent) =
  let editor = self.editorUI.monacoEditor
  let editorLayout = editor.config.layoutInfo
  let editorWidth = editorLayout.width
  let contentLeft = editorLayout.contentLeft
  let minimapWidth = editorLayout.minimapWidth

  self.traceWidth = editorWidth - minimapWidth - contentLeft - 8

# proc traceMainStyle(self: TraceComponent): VStyle =
#   self.editorUI.monacoEditor.config = getConfiguration(self.editorUI.monacoEditor)
#   self.calcTraceWidth()

#   style(
#     (StyleAttr.height, cstring($self.traceHeight & "px")),
#     (StyleAttr.width, cstring(fmt"{self.traceWidth}px"))
#   )

proc showExpandValue*(self: TraceComponent, traceValue: (cstring, Value), line: int) =
  let id = cstring(fmt"modal-content-{line}")
  let traceMain = document.getElementById(id)
  let expandedWindow = document.getElementById(cstring(fmt"trace-modal-window-{line}"))

  traceMain.innerHTML = ""
  traceMain.style.display = "block"
  expandedWindow.style.display = "block"

  let value = ValueComponent(
    expanded: JSAssoc[cstring, bool]{traceValue[0]: true},
    charts: JSAssoc[cstring, ChartComponent]{},
    showInLine: JsAssoc[cstring, bool]{},
    baseExpression: traceValue[0],
    baseValue: traceValue[1],
    stateID: -1,
    nameWidth: VALUE_COMPONENT_NAME_WIDTH,
    valueWidth: VALUE_COMPONENT_VALUE_WIDTH,
    data: data
  )

  self.modalValueComponent = value

  kxiMap[id] = setRenderer(
    (proc: VNode =
      self.modalValueComponent.render()),
    id,
    proc = echo "error when setting up renderer for modal"
  )

  self.data.redraw()

method onUpdatedTable*(self: TraceComponent, response: CtUpdatedTableResponseBody) {.async.} =
  if response.tableUpdate.isTrace and response.tableUpdate.data.draw == self.drawId and response.tableUpdate.traceId == self.id:
    self.tableCallback(response.tableUpdate.data.toJs)
    self.dataTable.rowsCount = response.tableUpdate.data.recordsTotal
    self.dataTable.updateTableRows()
    self.dataTable.updateTableFooter()
    self.redraw()

proc findTracepoint(self: TraceComponent, session: TraceSession, id: int): Tracepoint =
  for trace in session.tracepoints:
    if trace.tracepointId == id:
      return trace

proc shouldUpdate(self: TraceComponent, response: TraceUpdate): bool =
  return not self.isDisabled and response.firstUpdate or
    (not self.dataTable.context.isNil and cast[string](self.dataTable.context.search()) != "") or
    (self.dataTable.rowsCount == 0 or self.isLoading)

const OLD_SESSION_RESULTS_KEY = -1

proc removeTraceLogsFromEventLog() =
  var eventLogService = data.services.eventLog
  var newEvents = eventLogService.events.filterIt(it.kind != TraceLogEvent)
  for i, event in newEvents.mpairs():
    event.eventIndex = i
  data.services.eventLog.events = newEvents
  for i, component in data.ui.componentMapping[Content.EventLog]:
    var eventLogComponent = EventLogComponent(component)
    data.ui.componentMapping[Content.EventLog][i] = eventLogComponent
  data.redraw()

proc getConfiguration*(editor: MonacoEditor): MonacoEditorConfig =
  domwindow.editor = editor
  let layoutInfo = editor.getOption(LAYOUT_INFO)
  let lineHeight = cast[int](editor.getOption(LINE_HEIGHT))

  MonacoEditorConfig(
    lineHeight: lineHeight,
    layoutInfo: MonacoEditorLayoutInfo(
      contentLeft: layoutInfo.contentLeft,
      contentWidth: layoutInfo.contentWidth,
      height: layoutInfo.height,
      width: layoutInfo.width,
      minimapWidth: layoutInfo.minimap.minimapWidth,
      minimapLeft: layoutInfo.minimap.minimapLeft))

proc updateViewZoneHeight(self: TraceComponent, newHeight: int) =
  self.editorUI.monacoEditor.changeViewZones do (view: js):
    view.removeZone(self.zoneId)

  self.viewZone.heightInPx = newHeight

  self.editorUI.monacoEditor.changeViewZones do (view: js):
    self.zoneId = cast[int](view.addZone(self.viewZone))
  self.editorUI.monacoEditor.config = getConfiguration(self.editorUI.monacoEditor)
  let traceMain = kdom.document.getElementById(cstring(fmt"trace-{self.id}"))
  let editor = self.editorUI.monacoEditor
  let editorLayout = editor.config.layoutInfo
  let editorWidth = editorLayout.width
  let contentLeft = editorLayout.contentLeft
  let minimapWidth = editorLayout.minimapWidth
  self.traceWidth = editorWidth - minimapWidth - contentLeft - 8
  traceMain.style.width = cstring(fmt"{self.traceWidth}px")
  self.resultsHeight = 210
  jq(cstring(fmt"#trace-{self.id} .editor-traces")).style.height = cstring(fmt"{self.resultsHeight}px")
  discard setTimeout(proc() =
    self.monacoEditor.toJs.getDomNode().querySelector("textarea").focus(),
    1
  )

proc convertTracepointEventToProgramEvent(tracepointEvent: Stop): ProgramEvent =
  var res: cstring
  if tracepointEvent.errorMessage == "":
    for (name, value) in tracepointEvent.locals:
      if value.kind != types.Error:
        if value.isLiteral and value.kind == types.String:
          res.add(value.text & cstring" ")
        else:
          res.add(name & cstring"=" & textRepr(value).cstring & cstring"; ")
      else:
        res.add(name & cstring"=" & cstring"<span class=error-trace>" & value.msg & cstring"</span>")
        res.add(cstring" ")
  else:
    res.add(cstring"<span class=error-trace>" & tracepointEvent.errorMessage & cstring"</span>")

  return ProgramEvent(
    kind: TraceLogEvent,
    content: res,
    rrEventId: tracepointEvent.event,
    highLevelPath: tracepointEvent.path,
    highLevelLine: tracepointEvent.line,
    directLocationRRTicks: tracepointEvent.rrTicks,
    tracepointResultIndex: tracepointEvent.resultIndex,
    eventIndex: tracepointEvent.iteration,
    base64Encoded: false,
    maxRRTicks: data.maxRRTicks,
  )

proc runTracepoints*(data: Data) {.exportc.} =
  tracepointStart = now()
  var tracepoints: seq[Tracepoint] = @[]
  var i = 0
  var unchangedList: seq[ProgramEvent] = data.services.trace.unchanged
  var unchangedTracepointLocations = JsAssoc[cstring, bool]{}

  for component in data.ui.componentMapping[Content.Trace]:
    let trace = TraceComponent(component)
    if not trace.isChanged and not trace.isDisabled and not trace.forceReload:
      unchangedTracepointLocations[&"{trace.tracepoint.name}_{trace.tracepoint.line}"] = true
    else:
      unchangedTracepointLocations[&"{trace.tracepoint.name}_{trace.tracepoint.line}"] = false

  for id, component in data.ui.componentMapping[Content.Trace]:
    let trace = TraceComponent(component)
    let code = trace.monacoEditor.getValue()

    if code != "" and not trace.isDisabled: # and trace.isChanged
      if trace.resultsHeight == 36:
        trace.updateViewZoneHeight(cast[int](trace.viewZone.heightInPx) + 180)
        data.ui.activeFocus = trace

      trace.isRan = true
      trace.isLoading = trace.isChanged
      trace.forceReload = false
      trace.indexInSession = i

      trace.tracepoint.expression = code
      trace.tracepoint.lastRender = 0
      trace.tracepoint.isChanged = trace.isChanged
      trace.tracepoint.results = @[]
      trace.tracepoint.tracepointError = cstring""

      # so we generate json-safe structure, it has problems with assigning null to other branch fields
      # trace.tracepoint.query = cast[QueryNode](js{kind: QNone, label: cstring"", code: js{sons: cast[seq[QueryNode]](@[])}})
      # QueryNode(kind: QNone, label: cstring"", code: QueryCode(sons: @[])) # placeholder
      tracepoints.add(trace.tracepoint)
      trace.loggedSource = code
      trace.isChanged = false
      trace.isUpdating = true
      trace.error = nil
      i += 1
      trace.refreshTrace()

  var oldResults: seq[Stop]
  if data.services.trace.traceSessions.len == 0:
    oldResults = @[]
  else:
    let lastSession = data.services.trace.traceSessions[^1]
    unchangedList = unchangedList.filterIt(unchangedTracepointLocations[&"{it.highLevelPath}_{it.highLevelLine}"])
    for sessionResults in lastSession.results:
      for traceResult in sessionResults:
        if unchangedTracepointLocations[&"{traceResult.path}_{traceResult.line}"]:
          let programEvent = convertTracepointEventToProgramEvent(traceResult)
          unchangedList.add(programEvent)

    data.services.trace.unchanged = unchangedList

  removeTraceLogsFromEventLog()
  let newEvents = data.services.eventLog.events.concat(unchangedList)
  data.services.eventLog.events = newEvents

  if tracepoints.len == 0:
    data.viewsApi.warnMessage("There are no changes in the tracepoints input.")

  let results = JsAssoc[int, seq[Stop]]{}
  results[OLD_SESSION_RESULTS_KEY] = oldResults

  data.services.trace.traceSessions.add(TraceSession(
    tracepoints: tracepoints,
    lastCount: 0,
    results: results,
    id: data.services.trace.traceSessions.len))
  data.pointList.lastTracepoint = 0
  data.pointList.redrawTracepoints = true
  data.dapApi.sendCtRequest(
    CtRunTracepoints,
    RunTracepointsArg(
      session: data.services.trace.traceSessions[^1],
      stopAfter: NO_LIMIT
    ).toJs
  )

method onUpdatedTrace*(traceComponent: TraceComponent, response: TraceUpdate) {.async.} =
  # let timeInMs = now()
  # var traceSession = data.services.trace.traceSessions[response.sessionID]

  # for tracepoint in traceSession.tracepoints:
  if not response.refreshEventLog: # response.updateId <= traceSession.tracepoints[^1].tracepointId and
    let tracepoint = traceComponent.tracepoint # self.findTracepoint(traceSession, response.updateId)
    # let traceComponent =
    #   data.ui.editors[tracepoint.name].traces[tracepoint.line]

    if traceComponent.shouldUpdate(response):
      traceComponent.isLoading = false
      traceComponent.isReached = true
      if response.tracepointErrors.hasKey(tracepoint.tracepointId):
        let tracepointError = response.tracepointErrors[tracepoint.tracepointId]
        traceComponent.tracepoint.tracepointError = tracepointError
      traceComponent.refreshTrace()
      traceComponent.dataTable.context.ajax.reload(nil, false)
    else:
      traceComponent.dataTable.rowsCount = response.count
      traceComponent.dataTable.updateTableFooter()

      if cast[int](traceComponent.dataTable.context.scroller.page()["end"]) == traceComponent.dataTable.endRow - 1 and
          traceComponent.dataTable.endRow != traceComponent.dataTable.rowsCount:
        traceComponent.dataTable.context.ajax.reload(nil, false)

    # let duration = timeInMs - tracepointStart

proc createContextMenuItems(self: TraceComponent, ev: js): seq[ContextMenuItem] =
  var addToScratchpad:     ContextMenuItem
  # var expandTraceValue:    ContextMenuItem
  var contextMenu:         seq[ContextMenuItem]

  let localValues = self.locals[max(cast[int](ev.currentTarget.rowIndex) - 1, 0)]
  let name = if localValues.len() > 1: "values" else: "value"
  addToScratchpad = ContextMenuItem(
    name: cstring(fmt"Add {name} to scratchpad"),
    hint: "",
    handler: proc(e: Event) =
      for local in localValues:
        self.api.emit(InternalAddToScratchpad, ValueWithExpression(expression: local[0], value: local[1]))
  )

  contextMenu &= addToScratchpad

  # TODO: For now remove this feature until stable
  # expandTraceValue = ContextMenuItem(
  #   name: &"Expand {localValues[0]} value",
  #   hint: "",
  #   handler: proc(e: Event) =
  #     self.showExpandValue(localValues, self.line)
  #     self.data.redraw()
  # )

  # contextMenu &= expandTraceValue

  return contextMenu

proc renderTableResults(
  self: TraceComponent,
  traceSession: TraceSession = nil
) =
  # check if there is dataTable context
  if self.dataTable.context.isNil:
    # there is not dataTabl context defined
    # we create a new one and load all the session results in it
    let element = jqFind(cstring(fmt"#trace-table-{self.id}"))

    if not element.isNil:
      # traceSession.tracepoints[self.indexInSession].lastRender += results.len
      var columns = @[
        js{
          className: cstring"direct-location-rr-ticks",
          data: cstring"directLocationRRTicks",
        },
        js{
          className: cstring"trace-values",
          data: cstring"content",
        }
      ]

      self.dataTable.context = element.DataTable(
        js{
          serverSide: true,
          deferRender: true,
          scrollY: 150,
          processing: true,
          fixedColumns: true,
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
          scroller: true,
          scrollerCollapse: true,
          bInfo: false,
          ajax: proc(data: TableArgs, callback: proc(data: js), settings: js) =
            var mutData = data
            self.tableCallback = callback
            self.service.drawId += 1
            mutData.draw = self.service.drawId
            self.drawId = mutData.draw
            let updateTableArgs =
              UpdateTableArgs(
                tableArgs: mutData,
                isTrace: true,
                traceId: self.id,
              )
            self.api.emit(CtUpdateTable, updateTableArgs),
          columns: columns,
        }
      )

      # add event handler for search input
      self.dataTable.context.on(cstring("search.dt"), proc(e: js, settings: js) =
        self.dataTable.updateTableRows()
        self.dataTable.updateTableFooter()
      )

      # add handler for table redraw event
      self.dataTable.context.on(cstring("draw.dt"), proc(e, show, row: js) =
        discard windowSetTimeout(proc = self.dataTable.updateTableRows(), 100)
      )

      # resize data table to fit container
      self.dataTable.resizeTable()

      # add event listener for scrolling to update table footer
      let scrollBodyDom = jq(cstring(fmt"#chart-table-{self.id} .dt-scroll-body"))

      # add wheel event handler for nested scrollable element (table content)
      scrollBodyDom.toJs.addEventListener(cstring"wheel", proc(ev: Event, tg: VNode) =
        ev.stopPropagation()
        self.dataTable.inputFieldChange = false
        discard setTimeout(proc() =
          self.dataTable.updateTableRows()
          self.redraw(),
          100
        )
        discard setTimeout(proc() =
          self.dataTable.updateTableFooter()
          self.redraw(),
          100
        )
      )

      proc toProgramEvent(self: TraceComponent, datatableRow: js): ProgramEvent =
        ProgramEvent(
          kind: TraceLogEvent,
          highLevelPath: self.name,
          highLevelLine: self.line,
          rrEventId: cast[int](datatableRow.rrEventId),
          directLocationRRTicks: cast[int](datatableRow.directLocationRRTicks),
          content: cstring"",
          metadata: cstring"",
          maxRRTicks: data.maxRRTicks,
        )

      jqFind(cstring(fmt"#trace-table-{self.id} tbody")).on(cstring"click", cstring"tr") do (event: js):
        let target = event.target
        let parentNode = target.parentNode
        let datatable = self.dataTable.context
        let datatableRow = datatable.row(parentNode)
        let traceValue = self.toProgramEvent(datatableRow.data())

        if cast[bool](event.originalEvent.ctrlKey):
          self.data.redraw()
        else:
          self.api.emit(CtTraceJump, traceValue)
          self.api.emit(InternalNewOperation, NewOperation(name: "trace jump", stableBusy: true))

      jqFind(cstring(fmt"#trace-table-{self.id} tbody")).on(cstring"contextmenu", cstring"tr") do (event: js):
        # let target = event.target
        # let parentNode = target.parentNode
        # let datatable = self.dataTable.context
        # let datatableRow = datatable.row(parentNode)
        # let traceValue = self.toProgramEvent(datatableRow.data())
        let contextMenu = createContextMenuItems(self, event)

        if contextMenu != @[]:
          showContextMenu(contextMenu, cast[int](event.clientX), cast[int](event.clientY))
    else:
      return

    let denseWrapper = cstring(fmt"#trace-table-{self.id}_wrapper")

    cast[Node](jq(denseWrapper)).findNodeInElement(".dt-scroll-body")
        .addEventListener(cstring"wheel", proc(ev: Event) =
          ev.stopPropagation()
          self.dataTable.updateTableRows()
          self.dataTable.updateTableFooter())

proc enableIcon(self: TraceComponent) =
  let iconDom =
    cast[Element](jq(cstring(&"#trace-{self.id} .trace-disable")))

  if not iconDom.isNil:
    iconDom.innerHtml = "Disable"
    self.redrawForExtension()
    self.data.redraw()

proc disableIcon(self: TraceComponent) =
  let iconDom =
    cast[Element](jq(cstring(&"#trace-{self.id} .trace-disable")))

  if not iconDom.isNil:
    iconDom.innerHtml = "Enable"
    self.redrawForExtension()
    self.data.redraw()

proc showSelectedChart(self: TraceComponent) =
  hideDomElement(self.chartTableDom)
  hideDomElement(self.chartLineDom)
  hideDomElement(self.chartPieDom)

  case self.chart.viewKind:
  of ViewTable:
    showDomElement(self.chartTableDom)

  of ViewLine:
    showDomElement(self.chartLineDom)

  of ViewPie:
    showDomElement(self.chartPieDom)

proc showEmptyResults(self: TraceComponent) =
  self.resultsOverlayDom.children[0].innerHTML = NO_RESULTS_MESSAGE
  showDomElement(self.resultsOverlayDom)

proc showErrorMessage(self: TraceComponent, tracepointError: cstring) =
  self.resultsOverlayDom.children[0].innerHTML = cstring""
  let traceErrorVdom = buildHtml(span(class="trace-error")):
      text tracepointError
  let traceErrorDom = vnodeToDom(traceErrorVdom, KaraxInstance())
  self.resultsOverlayDom.children[0].appendChild(traceErrorDom)
  hideDomElement(self.searchInput)
  hideDomElement(self.traceViewDom)
  showDomElement(self.resultsOverlayDom)

method onTracepointLocals*(self: TraceComponent, response: TraceValues) {.async.} =
  if self.tracepoint.tracepointId == response.id:
    self.locals = response.locals

method refreshTrace*(self: TraceComponent) =
  if self.isDisabled:
    showDomElement(self.overlayDom)
    self.disableIcon()

    return
  else:
    hideDomElement(self.overlayDom)
    self.enableIcon()

  if self.tracepoint.tracepointError == cstring"":
    showDomElement(self.searchInput)
    showDomElement(self.traceViewDom)

  if self.isChanged: # self.editorUI.tabInfo.changed or
    # self.resultsOverlayDom.children[0].innerHTML = RUN_TRACE_MESSAGE
    showDomElement(self.resultsOverlayDom)

    return
  else:
    hideDomElement(self.resultsOverlayDom)

  if self.isLoading:
    self.resultsOverlayDom.children[0].innerHTML = "Loading..."
    showDomElement(self.resultsOverlayDom)

    return
  else:
    hideDomElement(self.resultsOverlayDom)

  if self.chart.changed:
    # show selected chart kind
    self.showSelectedChart()

    # reset result render counter if table chart is changed
    self.tracepoint.lastRender = 0
    self.chart.changed = false

  # add results
  if self.chart.viewKind == ViewTable:
    if self.chartTableDom.isHidden():
      showDomElement(self.chartTableDom)

    self.renderTableResults()
  else:
    self.chart.ensure()

  if self.tracepoint.tracepointError != cstring"":
    self.showErrorMessage(self.tracepoint.tracepointError)
  elif not self.isReached and self.isRan:
    self.showEmptyResults()

  # change button text if chart kind is changed
  # if self.chart.changed:
  #   self.kindSwitchButton.innerHTML =
  #     ($self.chart.viewKind)[4..^1].toLowerAscii().cstring

proc saveSource*(self: TraceComponent) =
  self.source = self.monacoEditor.getValue()

  if self.source != self.loggedSource:
    self.isChanged = true
    self.isRan = false
  else:
    self.isChanged = false

  self.refreshTrace()

proc ensureEdit*(self: TraceComponent) =
  if self.selectorId.len == 0:
    self.selectorId = cstring(&"edit-trace-{self.editorUI.id}-{self.line}")
    self.isChanged = true

proc ensureChart(self: TraceComponent) =
  if self.chart.tableView.isNil:
    var tableView = proc: VNode =

      buildHtml(
        tdiv(
          id = cstring(fmt"chart-table-{self.id}"),
          class = "chart-table hidden"
        )
      ):
        tdiv(class = "data-table"):
          table(
            id = cstring(fmt"trace-table-{self.id}"),
            class = "trace-table",
            onmouseover = proc =
              self.mouseIsOverTable = true,
            onmouseleave = proc =
              self.mouseIsOverTable = false
          )
        tableFooter(self.dataTable)

    self.chart.tableView = tableView
    # self.chart.id = self.data.ui.idMap[j"chart"]
    self.chart.stateID = -1
    self.chart.trace = self
    self.chart.expression = cstring"trace"

proc refreshLine(self: TraceComponent) =
  self.monacoEditor.changeViewZones do (view: js):
    self.viewZone.heightInLines = self.viewZone.heightInLines
    view.layoutZone(self.zoneId)

proc editorLineNumber*(self: EditorViewComponent, path: cstring, line: int, isDeleteChunk: bool = false, lineNumber: int = NO_LINE): cstring =
  let realLine =
    if isDeleteChunk:
      -1
    elif not self.isExpansion:
      line
    else:
      line + self.tabInfo.location.expansionFirstLine - 1

  var tracepointHtml = cstring"<div class='gutter-no-trace' onmousedown='event.stopPropagation()'></div>"
  var breakpointHtml = cstring"<div class='gutter-no-breakpoint' onmousedown='event.stopPropagation()'></div>"
  var highlightHtml = cstring"<div class='gutter-no-highlight' onmousedown='event.stopPropagation()'></div>"

  if self.traces.hasKey(realLine):
    var editor = self.traces[realLine]

    if not editor.isDisabled:
      tracepointHtml = cstring"<div class='gutter-trace' onmousedown='event.stopPropagation()'></div>"
    else:
      tracepointHtml = cstring"<div class='gutter-disabled-trace' onmousedown='event.stopPropagation()'></div>"

  if line == self.location.line and
      path == self.location.path and
      not isDeleteChunk:
    highlightHtml = cstring"<div class='gutter-highlight-active' onmousedown='event.stopPropagation()'></div>"

  if self.data.services.debugger.hasBreakpoint(path, realLine):
    let breakpoint = self.data.services.debugger.breakpointTable[path][realLine]

    if breakpoint.enabled:
      if not breakpoint.error:
        breakpointHtml = cstring"<div class='gutter-breakpoint-enabled' onmousedown='event.stopPropagation()'></div>"
      else:
        breakpointHtml = cstring"<div class='gutter-breakpoint-error' onmousedown='event.stopPropagation()'></div>"

    else:
      breakpointHtml = cstring"<div class='gutter-breakpoint-disabled' onmousedown='event.stopPropagation()'></div>"

  let trueLineNumber = if not isDeleteChunk: toCString(realLine) else: toCString(line + lineNumber - 1)
  let lineHtml = cstring"<div class='gutter-line' onmousedown='event.stopPropagation()'>" & trueLineNumber & cstring"</div>"
  let diffHtml = cstring"<div class='diff-line' onmousedown='event.stopPropagation()'>" & cstring"</div>"
  let klass = if isDeleteChunk: cstring"diff-deleted-gutter" elif line in self.diffAddedLines: cstring"diff-added-gutter" else: cstring""

  result = cstring"<div class='gutter " & klass & "' data-line=" & trueLineNumber & cstring" onmousedown='event.stopPropagation()'>" & highlightHtml & lineHtml & diffHtml & tracepointHtml & breakpointHtml & cstring"</div>"

proc updateLineNumbersOnly*(self: EditorViewComponent) =
  let editorInstance = self.monacoEditor
  if not editorInstance.isNil:
    var currentOptions = editorInstance.getOptions()

    currentOptions["lineNumbers"] = proc(line: int): cstring = self.editorLineNumber(self.path, line)
    editorInstance.updateOptions(cast[MonacoEditorOptions](currentOptions))

proc toggleTraceState*(self: TraceComponent) =
  self.api.emit(CtTracepointToggle, TracepointId(id: self.id))

  self.isDisabled = not self.isDisabled
  self.forceReload = true
  self.tracepoint.isDisabled = not self.tracepoint.isDisabled
  self.error = nil

  self.refreshLine()
  self.refreshTrace()
  self.editorUI.updateLineNumbersOnly()

proc closeHamburger(self: TraceComponent) =
  deactivateDomElement(self.hamburgerButton)
  hideDomElement(self.hamburgerDropdownList)
  self.hamburgerButton.blur()

proc openHamburger(self: TraceComponent) =
  activateDomElement(self.hamburgerButton)
  showDomElement(self.hamburgerDropdownList)

proc toggleHamburger(self: TraceComponent) =
  if self.hamburgerButton.isActive():
    self.closeHamburger()
  else:
    self.openHamburger()

proc getTracepointInfo(trace: TraceComponent): Tracepoint =
  let code = trace.monacoEditor.getValue()

  if code != "":
    trace.isRan = true
    trace.isLoading = trace.isChanged
    trace.forceReload = false
    # trace.indexInSession = i

    trace.tracepoint.expression = code
    trace.tracepoint.lastRender = 0
    trace.tracepoint.isChanged = trace.isChanged
    trace.tracepoint.results = @[]
    trace.tracepoint.tracepointError = cstring""

    trace.tracepoint.name = trace.name
    trace.tracepoint.line = trace.line

    result = trace.tracepoint

    trace.loggedSource = code
    trace.isChanged = false
    trace.isUpdating = true
    trace.error = nil

  return result

proc traceMenuView(self: TraceComponent): VNode =
  var search = proc(ev: Event, tg: VNode) =
    let value = cast[cstring](ev.target.value)
    if not self.dataTable.context.isNil:
      self.dataTable.context.search(value).draw()

  buildHtml(
    tdiv(class = "trace-menu")
  ):
    tdiv(class = "trace-search"):
      input(
        `type` = "text",
        id = cstring(fmt"trace-input-{self.id}"),
        onchange = search,
        oninput = search,
        placeholder = "Search"
      )

    tdiv(class = "trace-buttons-container"):
      tdiv(
        class = "run-trace-button",
        onclick = proc() =
          self.api.emit(InternalTraceMapUpdate, self.getTracepointInfo())
          self.refreshTrace()
          self.api.emit(CtRunTraceSession, EmptyArg())
          # runTracepoints(self.data)
      ):
        tdiv(class = "trace-run-button-svg")
        tdiv(class="custom-tooltip"):
          text "Run tracepoints (Ctrl+Enter)"

      switchChartKindView(self.chart)

      tdiv(class = "hamburger-dropdown-container"):
        tdiv(
          class = "hamburger-dropdown",
          tabindex = "0",
          onclick = proc (e: Event, et: VNode) =
            self.toggleHamburger(),
          onblur = proc (e: Event, et: VNode) =
            self.closeHamburger()
        ):
          tdiv(class="trace-hamburger-svg")
        tdiv(
          class = "dropdown-list hidden",
          onmousedown = proc (ev: Event, et: VNode) = ev.preventDefault()
        ):
          tdiv(class = "trace-dropdown-list-container"):
            tdiv(
              class = "trace-disable dropdown-list-item",
              onclick = proc =
                self.toggleTraceState()
                self.data.redraw()
            ):
              text "Disable"
            tdiv(
              class = "trace-minimize dropdown-list-item",
              onclick = proc = self.editorUI.toggleTrace(self.name, self.line)
            ):
              text "Hide"
            tdiv(
              class="trace-close dropdown-list-item",
              onclick = proc = self.closeTrace()
            ):
              text "Delete"

# proc doNotDoAnything(monacoEditor: MonacoEditor, editor: EditorViewComponent) =
#   discard

# proc insertNewLine(monacoEditor: MonacoEditor, editor: EditorViewComponent) =
#   monacoEditor.insertTextAtCurrentPosition("\n")

proc renderEdit(self: TraceComponent): VNode =
  result = buildHtml(
    tdiv(
      id = self.selectorId,
      class = "edit")
    ):
      text(if self.source.isNil: cstring"                 " else: self.source)

  result.isThirdParty = true

func traceLine(line: int): cstring =
  cstring($line)

# const RESULT_HEIGHT = 10

proc expandWithEnter*(self: TraceComponent, newHeight: int) =
  self.editorUI.monacoEditor.changeViewZones do (view: js):
    view.removeZone(self.zoneId)
  self.viewZone.heightInPx = newHeight + self.resultsHeight + 16

  self.editorUI.monacoEditor.changeViewZones do (view: js):
    self.zoneId = cast[int](view.addZone(self.viewZone))

  discard setTimeout(proc() =
    self.monacoEditor.toJs.getDomNode().querySelector("textarea").focus(),
    1
  )
  self.editorUI.monacoEditor.config = getConfiguration(self.editorUI.monacoEditor)
  let traceMain = kdom.document.getElementById(cstring(fmt"trace-{self.id}"))
  let editor = self.editorUI.monacoEditor
  let editorLayout = editor.config.layoutInfo
  let editorWidth = editorLayout.width
  let contentLeft = editorLayout.contentLeft
  let minimapWidth = editorLayout.minimapWidth
  self.traceWidth = editorWidth - minimapWidth - contentLeft - 8
  traceMain.style.width = cstring(fmt"{self.traceWidth}px")
  jq(cstring(fmt"#trace-{self.id} .editor-textarea")).style.height = cstring(fmt"{self.lineCount * (data.ui.fontSize + 5)}px")

# proc traceErrorView(self: TraceComponent): VNode =
#   buildHtml(
#     tdiv(class = "trace-error")
#   ):
#     text self.error.msg

proc ensureMonacoEditor(self: TraceComponent) =
  # check if trace has a monaco editor
  if self.monacoEditor.isNil:
    # get main editor monaco editor and it's theme

    # TODO: Finf a way to store the monaco current theme?
    # let activeMonacoEditor =
    #   data.ui.editors[data.services.editor.active].monacoEditor
    # let activeMonacoTheme = activeMonacoEditor.getCurrentMonacoTheme()

    let documentTmp = domWindow.document
    let overflowHost = documentTmp.createElement("div")
    overflowHost.className = cstring("monaco-editor")
    documentTmp.body.appendChild(overflowHost)

    # create trace monaco editor
    self.monacoEditor = monaco.editor.create(
      jq(cstring(fmt".trace #{self.selectorId}")),
      MonacoEditorOptions(
        value: self.source,
        # language: toJsLang(self.editorUI.lang),
        theme: if self.inExtension: "vs-dark" else: data.ui.editors[data.services.editor.active].monacoEditor.getCurrentMonacoTheme(),
        readOnly: false,
        automaticLayout: true,
        lineNumbers: traceLine,
        folding: false,
        glyphMargin: false,
        fontSize: j"14px",
        minimap: js{ enabled: false },
        scrollbar: js{
          vertical: j"visible",
          horizontalScrollbarSize: 4,
          horizontalSliderSize: 4,
          verticalScrollbarSize: 4,
          verticalSliderSize: 4
        },
        overflowWidgetsDomNode: overflowHost,
        fixedOverflowWidgets: true
      )
    )

    # focus trace monaco editor text area after delay
    discard setTimeout(proc() =
      self.monacoEditor.toJs.getDomNode().querySelector("textarea").focus(),
      1
    )

    # add trace monaco editor to the register
    # TODO: Find a better way when using extension
    if not self.inExtension:
      self.data.ui.traceMonacoEditors.add(self.monacoEditor)
      self.monacoEditor.onMouseWheel(proc(e: js) =
        e.preventDefault()
      )
    # subscribe to trace monaco editor change event
    self.monacoEditor.onDidChangeModelContent(proc (event: JsObject) =
      self.error = nil
      self.saveSource()

      let code = self.monacoEditor.getValue()
      let lineCount = code.split("\n").len() + 1

      if self.lineCount != lineCount:
        self.lineCount = lineCount
        if not self.inExtension:
          self.expandWithEnter(lineCount*(data.ui.fontSize + 5))
    )

proc resizeEditorHandler(self: TraceComponent) =
  # get new monaco editor config
  self.editorUI.monacoEditor.config = getConfiguration(self.editorUI.monacoEditor)
  self.resizeTraceHandler()

proc setEditorResizeObserver(self: TraceComponent) =
  let activeEditor = "\"" & self.data.services.editor.active & "\""
  let editorDom = jq(cstring(fmt"[data-label={activeEditor}]"))
  let resizeObserver = createResizeObserver(proc(entries: seq[Element]) =
    for entry in entries:
      # let timeout =
      discard setTimeout(proc = resizeEditorHandler(self), 100)
  )

  resizeObserver.observe(cast[Node](editorDom))

  self.resizeObserver = resizeObserver

proc traceBase(self: TraceComponent): VNode =
  buildHtml(tdiv(id = cstring(fmt"trace-{self.id}"), class="trace")):
    tdiv(id = cstring(fmt"trace-editor-{self.id}"))

method render*(self: TraceComponent): VNode =
  self.ensureEdit()
  self.ensureChart()

  # var tabInfo = self.editorUI.tabInfo

  # check if main editor source has changed
  # if tabInfo.changed:
  #   self.api.warnMessage(cstring("can't create a tracepoint: you have to rebuild first, file changed"))
  #   return

  # var initialPosition: float

  # proc resizeEditor(ev: Event, tg:VNode) =
  #   let mouseEvent = cast[MouseEvent](ev)
  #   let containerWidth = jq(".trace-main").offsetHeight.toJs.to(float)
  #   let currentPosition = mouseEvent.screenY.toJs.to(float)
  #   let movementX = (currentPosition-initialPosition) * 100 / containerWidth
  #   let newPosition = self.editorWidth + movementX

  #   if newPosition >= MIN_EDITOR_WIDTH and newPosition < MAX_EDITOR_WIDTH:
  #     self.editorWidth = max(newPosition, MIN_EDITOR_WIDTH)

  #     jq(cstring(fmt"#trace-{self.id} .editor-textarea")).style.height = "100px"
  #     jq(cstring(fmt"#trace-{self.id} .editor-traces")).style.height = "60px"

  #     initialPosition = currentPosition

  var mainView = self.chart.render()

  result = buildHtml(tdiv):
    tdiv(
      class = "trace-main",
      onclick = proc(ev: Event, v:VNode) =
        ev.stopPropagation()
        if self.data.ui.activeFocus != self:
          self.data.ui.activeFocus = self,
      onmousemove = proc(ev: Event, tg:VNode) =
        if self.splitterClicked:
          resizeEditor(ev,tg),
      onmousedown = proc(ev: Event, tg: VNode) =
        if self.splitterClicked:
          initialPosition = cast[MouseEvent](ev).screenY.toJs.to(float),
      onmouseup = proc(ev: Event, tg: VNode) =
        if self.splitterClicked:
          self.splitterClicked = false
          ev.stopPropagation(),
      onmouseleave = proc = self.splitterClicked = false
    ):
      tdiv(class = "trace-chevron"):
        tdiv(class = "trace-chevron-arrow")
      tdiv(class = "editor-info"):
        tdiv(
          class = cstring(fmt"editor-textarea editor-textarea-width-{$self.editorWidth}"),
          style = style(StyleAttr.height, cstring(fmt"{self.lineCount * (data.ui.fontSize + 5) + 20}px"))
        ):
          tdiv(class = "trace-disabled-overlay tracepoint-overlay hidden"):
            tdiv(class = "trace-overlay"):
              text "Tracepoint is disabled"
          tdiv(class = "editor-textarea-empty-header")
          renderEdit(self)
        tdiv(class = "editor-traces"):
          traceMenuView(self)
          tdiv(class = "trace-view"):
            mainView
          tdiv(class = "trace-results-overlay tracepoint-overlay"):
            tdiv(class = "trace-overlay"):
              text "Press Ctrl+Enter to run the trace."
      tdiv(class = "trace-modal", id = cstring(fmt"trace-modal-window-{self.line}")):
        button(
          class = "modal-close-button",
          onclick = proc =
            document.getElementById(cstring(fmt"modal-content-{self.line}")).style.display = "none"
            document.getElementById(cstring(fmt"trace-modal-window-{self.line}")).style.display = "none"
        )
        tdiv(id = cstring(fmt"modal-content-{self.line}"))

proc traceBase(self: TraceComponent): VNode =
  buildHtml(tdiv(id = cstring(fmt"trace-{self.id}"), class="trace")):
    tdiv(id = cstring(fmt"trace-editor-{self.id}"))

const TOGGLE_REPEAT_TIME_LIMIT = 100i64

var lastToggleTime = 0i64

proc closeKindSwitchMenu(self: TraceComponent) =
  deactivateDomElement(self.kindSwitchButton)
  hideDomElement(self.kindSwitchDropDownList)

proc toggleChartKindMenu(self: TraceComponent) =
  if not self.kindSwitchButton.isActive():
    activateDomElement(self.kindSwitchButton)
    showDomElement(self.kindSwitchDropDownList)
  else:
    self.closeKindSwitchMenu()

proc resizeTraceHandler(self: TraceComponent) =
  let traceMain = document.getElementById(cstring(fmt"trace-{self.id}"))

  self.calcTraceWidth()
  traceMain.style.width = cstring(fmt"{self.traceWidth}px")

  if not self.dataTable.context.isNil:
    self.dataTable.resizeTable()
    self.dataTable.updateTableFooter()

proc togglePoint*(trace: TraceComponent) =
  if trace.viewZone.isNil:
    # create trace base dom Node
    let traceNode = vnodeToDom(traceBase(trace), kxi)

    # config new view zone in monaco editor
    trace.viewZone = js{
      afterLineNumber: line,
      heightInPx: 90,
      domNode: traceNode
    }

    # add configured zone
    # tabInfo.monacoEditor.changeViewZones do (view: js):
    #   trace.zoneId = cast[int](view.addZone(trace.viewZone))

    # # add tracepoint to points register
    # data.pointList.tracepoints[trace.tracepoint.tracepointId] = trace.tracepoint

    # render current trace component
    # trace.viewZone.domNode.appendChild(vnodeToDom(trace.render(), KaraxInstance()))

    # sаve references to component dom elements

    trace.searchInput =
      cast[Element](jq(
        cstring(&"#trace-{trace.id} .trace-search")
      ))
    trace.traceViewDom =
      cast[Element](jq(
        cstring(&"#trace-{trace.id} .trace-view")
      ))
    trace.hamburgerButton =
      cast[Element](jq(
        cstring(&"#trace-{trace.id} .hamburger-dropdown")
      ))
    trace.hamburgerDropdownList =
      cast[Element](jq(
        cstring(&"#trace-{trace.id} .hamburger-dropdown-container .dropdown-list")
      ))
    trace.overlayDom =
      cast[Element](jq(
        cstring(&"#trace-{trace.id} .trace-disabled-overlay")
      ))
    trace.resultsOverlayDom =
      cast[Element](jq(
        cstring(&"#trace-{trace.id} .trace-results-overlay")
      ))
    trace.kindSwitchButton =
      cast[Element](jq(
        cstring(&"#trace-{trace.id} .select-view-kind-button")
      ))
    trace.kindSwitchDropDownList =
      cast[Element](jq(
        cstring(&"#trace-{trace.id} .kind-dropdown-menu")
      ))
    trace.chartTableDom =
      cast[Element](jq(
        cstring(&"#trace-{trace.id} .chart-table")
      ))

    # add reference to trace table footer dom
    trace.dataTable.footerDom =
      cast[Element](trace.chartTableDom.findNodeInElement(".data-tables-footer"))

    trace.chartLineDom =
      cast[Element](jq(
        cstring(&"#trace-{trace.id} .chart-line")
      ))

    trace.chartPieDom =
      cast[Element](jq(
        cstring(&"#trace-{trace.id} .chart-pie")
      ))

    trace.runTraceButtonDom =
      cast[Element](jq(
        cstring(&"#trace-{trace.id} .run-trace-button")
      ))

    trace.kindSwitchButton.toJs.parentNode.addEventListener(cstring("click"), proc =
      trace.toggleChartKindMenu()
      trace.refreshTrace()
    )

    trace.kindSwitchButton.toJs.parentNode.addEventListener(cstring("blur"), proc =
      trace.closeKindSwitchMenu()
    )

    # create resize observer
    if trace.resizeObserver.isNil:
      trace.setEditorResizeObserver()

    # create monaco editor if there is not any yet
    trace.ensureMonacoEditor()

    # set trace to expanded
    trace.expanded = true

proc toggleTrace*(editorUI: EditorViewComponent, name: cstring, line: int) =
  let newTime = now()

  if lastToggleTime > 0 and newTime - lastToggleTime <= TOGGLE_REPEAT_TIME_LIMIT:
    editorUI.api.warnMessage(cstring(&"no toggleTrace on line {line}: happens before limit"))
    return

  lastToggleTime = newTime

  if line == -1:
    return

  # create trace component if there is not any
  if not editorUI.traces.hasKey(line):
    discard makeTraceComponent(editorUI.data, editorUI, name, line)

  # get the trace ui component
  var trace = editorUI.traces[line]

  # get the position of monaco's cursor
  let tracePosition = editorUI.monacoEditor.getPosition()

  # set the chevron position at the location that user opens the trace
  trace.chevronPosition =
    editorUI.monacoEditor.getOffsetForColumn(
      tracePosition.lineNumber,
      tracePosition.column
    )

  var tabInfo = editorUI.tabInfo

  if tabInfo.isNil:
    return

  if trace.viewZone.isNil:
    # create trace base dom Node
    let traceNode = vnodeToDom(traceBase(trace), kxi)

    # config new view zone in monaco editor
    trace.viewZone = js{
      afterLineNumber: line,
      heightInPx: 90,
      domNode: traceNode
    }

    # add configured zone
    tabInfo.monacoEditor.changeViewZones do (view: js):
      trace.zoneId = cast[int](view.addZone(trace.viewZone))

    # add tracepoint to points register
    data.pointList.tracepoints[trace.tracepoint.tracepointId] = trace.tracepoint

    # render current trace component
    trace.viewZone.domNode.appendChild(vnodeToDom(trace.render(), KaraxInstance()))

    # sаve references to component dom elements

    trace.searchInput =
      cast[Element](jq(
        cstring(&"#trace-{trace.id} .trace-search")
      ))
    trace.traceViewDom =
      cast[Element](jq(
        cstring(&"#trace-{trace.id} .trace-view")
      ))
    trace.hamburgerButton =
      cast[Element](jq(
        cstring(&"#trace-{trace.id} .hamburger-dropdown")
      ))
    trace.hamburgerDropdownList =
      cast[Element](jq(
        cstring(&"#trace-{trace.id} .hamburger-dropdown-container .dropdown-list")
      ))
    trace.overlayDom =
      cast[Element](jq(
        cstring(&"#trace-{trace.id} .trace-disabled-overlay")
      ))
    trace.resultsOverlayDom =
      cast[Element](jq(
        cstring(&"#trace-{trace.id} .trace-results-overlay")
      ))
    trace.kindSwitchButton =
      cast[Element](jq(
        cstring(&"#trace-{trace.id} .select-view-kind-button")
      ))
    trace.kindSwitchDropDownList =
      cast[Element](jq(
        cstring(&"#trace-{trace.id} .kind-dropdown-menu")
      ))
    trace.chartTableDom =
      cast[Element](jq(
        cstring(&"#trace-{trace.id} .chart-table")
      ))

    # add reference to trace table footer dom
    trace.dataTable.footerDom =
      cast[Element](trace.chartTableDom.findNodeInElement(".data-tables-footer"))

    trace.chartLineDom =
      cast[Element](jq(
        cstring(&"#trace-{trace.id} .chart-line")
      ))

    trace.chartPieDom =
      cast[Element](jq(
        cstring(&"#trace-{trace.id} .chart-pie")
      ))

    trace.runTraceButtonDom =
      cast[Element](jq(
        cstring(&"#trace-{trace.id} .run-trace-button")
      ))

    trace.kindSwitchButton.toJs.parentNode.addEventListener(cstring("click"), proc =
      trace.toggleChartKindMenu()
      trace.refreshTrace()
    )

    trace.kindSwitchButton.toJs.parentNode.addEventListener(cstring("blur"), proc =
      trace.closeKindSwitchMenu()
    )

    # create resize observer
    if trace.resizeObserver.isNil:
      trace.setEditorResizeObserver()

    # create monaco editor if there is not any yet
    trace.ensureMonacoEditor()

    # set trace to expanded
    trace.expanded = true

    return

  # check if trace is expanded
  if not trace.expanded:
    # expand the trace
    trace.expanded = true

    tabInfo.monacoEditor.changeViewZones do (view: js):
      trace.zoneId = cast[int](view.addZone(trace.viewZone))

    discard setTimeout(proc = resizeEditorHandler(editorUI.traces[line]),100)
  else:
    # shrink the trace and sace its source
    trace.expanded = false
    # trace.hamburgerIsClicked = false
    trace.saveSource()

    # remove trace view zone from monaco editor
    tabInfo.monacoEditor.changeViewZones do (view: js):
      view.removeZone(trace.zoneId)

  editorUI.data.redraw()
  data.ui.activeFocus = trace

method onCompleteMove*(self: TraceComponent, response: MoveState) {.async.} =
  self.location = response.location
  # TODO: For now find a better way when in extension
  # self.editorUI.updateLineNumbersOnly()

method onError*(self: TraceComponent, error: DebuggerError) {.async.} =
  if error.kind == ErrorTracepoint:
    if self.name == error.path and self.line == error.line:
      self.error = error
      self.data.redraw()

method register*(self: TraceComponent, api: MediatorWithSubscribers) =
  self.api = api
  api.subscribe(CtCompleteMove, proc(kind: CtEventKind, response: MoveState, sub: Subscriber) =
    self.ensureMonacoEditor()
    self.togglePoint()
    discard self.onCompleteMove(response)
  )
  api.subscribe(CtUpdatedTable, proc(kind: CtEventKind, response: CtUpdatedTableResponseBody, sub: Subscriber) =
    discard self.onUpdatedTable(response)
  )
  api.subscribe(CtUpdatedTrace, proc(kind: CtEventKind, response: TraceUpdate, sub: Subscriber) =
    discard self.onUpdatedTrace(response)
  )
  api.emit(InternalLastCompleteMove, EmptyArg())

proc closeTrace*(self: TraceComponent) =
  if self.isRan:
    self.api.emit(CtTracepointDelete, TracepointId(id: self.id))

  if self.editorUI.tabInfo.isNil:
    return

  # remove editor view zone
  self.editorUI.tabInfo.monacoEditor.changeViewZones do (view: js):
    view.removeZone(self.zoneId)

  # remove tracepoint from pointList
  if self.data.pointList.tracepoints.hasKey(self.tracepoint.tracepointId):
    discard jsdelete(self.data.pointList.tracepoints[self.tracepoint.tracepointId])
    self.data.pointList.redrawTracepoints = true

  # remove trace component from the editor register
  discard jsDelete(self.editorUI.traces[self.line])

  # remove monaco editor
  for i, me in self.data.ui.traceMonacoEditors:
    if me == self.monacoEditor:
      delete(data.ui.traceMonacoEditors, i..i)
      break

  #remove trace component from componentMapping register
  if self.data.ui.componentMapping[Content.Trace].hasKey(self.id):
    discard jsDelete(
      self.data.ui.componentMapping[Content.Trace][self.id]
    )

  self.data.redraw()

proc registerTracepointComponent*(component: TraceComponent, api: MediatorWithSubscribers) {.exportc.} =
  component.register(api)
