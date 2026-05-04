import
  ui_imports,
  ../[ types, renderer, utils, communication, event_helpers],
  ../../common/ct_event

let ATOM_KINDS = {
  Int, Float, String, CString, Char, Bool, Enum, Enum16, Enum32,
  types.Error, TypeKind.Raw, FunctionKind, TypeKind.None
} # temp Function

proc view(
  self: ValueComponent,
  value: Value,
  expression: cstring,
  name: cstring,
  path: seq[SubPath],
  depth: int = 0,
  annotation: cstring = ""
): VNode

proc createContextMenuItems(self: ValueComponent, value: Value, ev: Event): seq[ContextMenuItem]

proc addValues*(self: ChartComponent, expression: cstring, values: seq[Value])

proc loadHistory(self: ValueComponent, expression: cstring) =
  self.api.emit(CtLoadHistory, LoadHistoryArg(expression: expression, location: self.location))

method register*(self: ValueComponent, api: MediatorWithSubscribers) =
  self.api = api
  api.subscribe(CtUpdatedHistory, proc(kind: CtEventKind, response: HistoryUpdate, sub: Subscriber) =
    if self.baseAddress == NO_ADDRESS and response.expression == self.baseExpression or
        self.baseAddress != NO_ADDRESS and response.address == self.baseAddress:
      discard self.onUpdatedHistory(response))

proc registerValueComponent*(component: ValueComponent, api: MediatorWithSubscribers) {.exportc.} =
  component.register(api)

proc intValue*(i: int): Value {.exportc.} =
  Value(
    kind: TypeKind.Int,
    i: cstring($i),
    typ: Type(kind: TypeKind.Int, langType: "Int"),
  )

proc deleteWatch*(self: StateComponent, expression: cstring) =
  var i = self.watchExpressions.find(expression)

  if i != -1:
    delete(self.watchExpressions, i..i)
    self.locals = self.locals.filterIt(it.expression != expression)
    self.redraw()

proc updateWatches*(self: StateComponent, handler: proc(locals: seq[Variable])) {.async.} =
  # TODO: Fix up with new communication
  # data.ipc.send "CODETRACER::update-watches", js{watchExpressions: self.watchExpressions}
  # self.onUpdatedWatches = handler
  discard

proc renameWatch*(self: StateComponent, expression: cstring, newExpression: cstring) =
  self.deleteWatch(expression)

  if ($newExpression).find("\n") != NO_INDEX:
    self.api.errorMessage(cstring"newlines forbidden in watch expressions: not registered")
  else:
    self.watchExpressions.add(newExpression)

    discard self.updateWatches(proc(locals: seq[Variable]) =
      self.locals = locals
      self.redraw()
    )

proc uiExpanded*(self: ValueComponent, value: Value, expression: cstring): bool =
  if not self.expanded.hasKey(expression):
    self.expanded[expression] = false

  return self.expanded[expression]

func findNonExpanded(value: Value): seq[Value] =
  result = @[]

  if value.isNil:
    return @[]

  case value.kind:
  of {Instance, Tuple, Seq, Set, HashSet, OrderedSet, Array, Varargs}:
    for item in value.elements:
      if item.kind == NonExpanded:
        result.add(item)
      else:
        result = result.concat(findNonExpanded(item))

  of Union:
    for name, item in unionChildren(value):
      if item.kind == NonExpanded:
        result.add(item)
      else:
        result = result.concat(findNonExpanded(item))

  of {Ref, Pointer}:
    result = result.concat(findNonExpanded(value.refValue))

  of NonExpanded:
    result.add(value)

  else:
    discard

proc expandValues*(self: ValueComponent, expressions: seq[cstring], depth: int, stateCompleteMoveIndex: int): Future[seq[Value]] {.async.} =
  # TODO: Fix with db-backend
  # let values = await self.data.asyncSend(
  #   "expand-values",
  #   js{
  #     expressions: expressions,
  #     depth: depth,
  #     stateCompleteMoveIndex: stateCompleteMoveIndex
  #   },
  #   $stateCompleteMoveIndex & " " & $expressions,
  #   seq[Value])
  # return values
  discard

proc toggleExpanded*(self: ValueComponent, value: Value, expression: cstring) {.async.} =
  if value.kind in ATOM_KINDS:
    return

  var uiExpanded = not self.uiExpanded(value, expression)

  self.expanded[expression] = uiExpanded

  if self.customRedraw.isNil:
    self.redraw()
  else:
    self.customRedraw(self)

  if uiExpanded and self.stateID != -1: # expanded and in state

    let nonExpandedItems = findNonExpanded(value)
    let nonExpandedItemExpressions = nonExpandedItems.mapIt(it.expression)
    let state = self.data.stateComponent(self.stateID)
    let originalStateIndex = state.completeMoveIndex
    let expandedItems = await self.expandValues(nonExpandedItemExpressions, 1, originalStateIndex)

    if state.completeMoveIndex != originalStateIndex:
      return

    for i, item in nonExpandedItems:
      if i < expandedItems.len:
        let expandedItem = expandedItems[i]
        objectAssign(item.toJs, expandedItem.toJs)
      else:
        cerror &"no expanded item {i}"

    if self.customRedraw.isNil:
      self.redraw()
    else:
      self.customRedraw(self)

proc expandValue(self: ValueComponent, path: seq[SubPath], isLoadMore: bool = false, startIndex: int = 0): Future[Value] {.async.} =
  # We need to emit expand value event and sub to the expand value response
  # and then to resolve the Future[Value]
  # Before we were calling data.services.debugger.expandValue(path)
  # let count = 50
  # var value = await self.data.asyncSend("expand-value", ExpandValueTarget(subPath: subPath, rrTicks: self.location.rrTicks, isLoadMore: isLoadMore, startIndex: startIndex, count: count), $self.location.rrTicks & " " & $subPath, Value)
  # return value
  discard

proc expandNewValues(self: ValueComponent, value: Value, path: seq[SubPath]) {.async.} =
  var expand: bool = value.kind == NonExpanded

  if value.kind == Pointer:
    for child in value.refValue.elements:
      if child.kind == NonExpanded:
        expand = true

        break
  else:
    for child in value.elements:
      if child.kind == NonExpanded:
        expand = true

        break

  # TODO: Rework with the new db-backend and init
  if expand:
    let newValue = await self.expandValue(path)

    if value.kind != Pointer:
      objectAssign(value.toJs, newValue.toJs)
    else:
      objectAssign(value.refValue.toJs, newValue.refValue.toJs)

    if self.customRedraw.isNil:
      self.state.redraw()
    else:
      self.customRedraw(self)

proc redrawAfterValueMutation(self: ValueComponent) =
  if self.customRedraw.isNil:
    self.redraw()
  else:
    self.customRedraw(self)

proc loadMoreValues(self: ValueComponent, value: Value, path: seq[SubPath]) {.async.} =
  var newValue: Value

  if value.kind != TableKind:
    newValue = await self.expandValue(path, isLoadMore = true, startIndex = value.elements.len)

    for element in newValue.elements:
      self.baseValue.elements.add(element)
  else:
    newValue = await self.expandValue(path, isLoadMore = true, startIndex = value.items.len)

    for item in newValue.items:
      self.baseValue.items.add(item)

  self.isOperationRunning = false
  self.baseValue.partiallyExpanded = newValue.partiallyExpanded
  self.redrawAfterValueMutation()

proc switchChartKindView*(self: ChartComponent): VNode =
  # based on https://getbootstrap.com/docs/4.3/components/dropdowns/ : good to use
  var kindSelectorClass = cstring"select-view-kind-button"
  var dropdownClass = cstring"kind-dropdown-menu"

  if not self.kindSelectorIsClicked:
    dropdownClass = dropdownClass & cstring" hidden"
  else:
    kindSelectorClass = kindSelectorClass & cstring" active"

  buildHtml(
    tdiv(
      class = "select-view-kind",
      tabindex = "0",
      onmousedown = proc =
        self.kindSelectorIsClicked = not self.kindSelectorIsClicked
        redrawAll(),
      onblur = proc =
        self.kindSelectorIsClicked = false
        redrawAll()
      )
    ):
      tdiv(
        class = cstring(fmt"dropdown-toggle {kindSelectorClass}"),
        id = "dropdownMenuButton"
      ):
        let kind = ($self.viewKind)[4..^1].toLowerAscii().cstring
        text kind
      tdiv(
        class = dropdownClass,
        onmousedown = proc(ev: Event, tg: VNode) = ev.preventDefault()
      ):
        tdiv(
          class = "dropdown-item",
          onmousedown = proc =
            if self.viewKind != ViewTable:
              self.changed = true
              self.viewKind = ViewTable
              self.line = nil
              self.pie = nil
            self.redraw()
        ):
          text "table"
        tdiv(
          class = "dropdown-item",
          onmousedown = proc =
            if self.viewKind != ViewLine:
              self.viewKind = ViewLine
              self.pie = nil
              self.changed = true
            self.redraw()
        ):
          text "line"
        tdiv(
          class = "dropdown-item",
          onmousedown = proc =
            if self.viewKind != ViewPie:
              self.viewKind = ViewPie
              self.line = nil
              self.changed = true
            self.redraw()
        ):
          text "pie"

func getId(c: ChartComponent): int =
  c.chartId

proc ensureLine*(self: ChartComponent) =
  if self.line.isNil and self.viewKind == ViewLine:
    var canvasElement = jq(cstring(fmt"#chart-line-canvas-{self.getId}")).toJs
    try:
      var canvasCtx = canvasElement.getContext(cstring"2d")

      # based on MDN docs : https://developer.mozilla.org/en-US/docs/Web/API/CanvasRenderingContext2D/createLinearGradient#filling_a_rectangle_with_a_linear_gradient
      var gradient = canvasCtx.createLinearGradient(276.0 / 2.0, 0, 276.0 / 2.0, 552.0)

      gradient.addColorStop(0, cstring"grey")
      gradient.addColorStop(0.3, cstring"transparent")
      self.lineConfig =
        js{
          "type": cstring"line",
          "data": js{
            "labels": self.lineLabels,
            "datasets": self.datasets,
            "borderColor": cstring"#F98D71",
            "backgroundColor": gradient
        },
        "options":
          js{
            "responsive": true,
            "maintainAspectRatio": false,
            "aspectRatio": 5,
            "backgroundColor": "red"
          }
      }

      self.line = newChart(canvasCtx, self.lineConfig)
    except:
      cerror "ensureLine: " & getCurrentExceptionMsg()

proc colorLabel*(self: ChartComponent, label: cstring): cstring =
  let r = if label.len > 0: (label[0]).int * 100 mod 256 else: 0
  let g = if label.len >= 2: label[1].int * 100 mod 256 else: 0
  let b = if label.len >= 3: label[2].int * 100 mod 256 else: 0

  cstring(&"rgba({r}, {g}, {b}, 1)")

proc pieLabelsColor*(labels: seq[cstring]): seq[cstring] =
  var colors: seq[cstring]
  var r = 255

  for i in 0..<labels.len:
    colors.add(cstring(&"rgba({r}, 169, 145, 1)"))
    r -= 20

  result = colors

proc ensurePie*(self: ChartComponent) =
  if self.pie.isNil and self.viewKind == ViewPie:
    self.pieConfig =
      js{
        "type": cstring"pie",
        "data":
          js{
            "labels": self.pieLabels,
            "datasets": @[
              js{
                "data": self.pieValues,
                "backgroundColor": self.pieLabels.pieLabelsColor()
              }
            ]
          },
      }
    try:
      var canvas = jq(cstring(fmt"#chart-pie-canvas-{self.getId}")).toJs.getContext(cstring"2d")
      let containerWidth = jq(".trace .editor-traces").toJs.offsetWidth.to(float)

      self.pie = newChart(canvas, self.pieConfig)
      self.trace.traceHeight = containerWidth/2

      jq(".trace .trace-main").style.height = cstring($(self.trace.traceHeight + 30) & "px")

      let additionalHeightInLines = Math.ceil((self.trace.traceHeight + 30 - 210)/20)

      let activeMonacoEditor = data.ui.editors[data.services.editor.active].monacoEditor

      activeMonacoEditor.changeViewZones do (view: js):
        self.trace.toJs.newZoneId = cast[int](
          view.addZone(
            js{
              afterLineNumber: self.trace.line,
              heightInLines: additionalHeightInLines
            }
          )
        )

    except:
      cerror "value: ensurePie: " & getCurrentExceptionMsg()

proc ensureBase(self: ChartComponent) =
  if self.viewKind == ViewLine:
    self.ensureLine()
  else:
    self.ensurePie()

proc ensure*(self: ChartComponent) =
  var label = if self.viewKind == ViewLine:
      "ensureLine"
    elif self.viewKind == ViewTable:
      "<not applicable>"
    else:
      "ensurePie"

  # if self.stateID != -1:
  #   # TODO: think how this would work in extension
  #   kxiMap[cstring("stateComponent-" & $self.stateID)].afterRedraws.add(proc =
  #     discard windowSetTimeout(proc = self.ensureBase(), 500)
  #   )
  # else:
  if not self.trace.isNil:
    self.ensureBase()
  elif self.viewKind != ViewTable:
    # alexander: not sure if this problematic : now code is different..
    cwarn "value: " & label & " cant be called"
    return

proc renderLine*(self: ChartComponent): VNode =
  let hidden =
    if self.viewKind != ViewLine:
      " hidden"
    else:
      ""

  result = buildHtml(
    tdiv(
      class = cstring(fmt"chart-line{hidden}"),
      id = cstring(fmt"chart-line-{self.getId}"),
    )
  ):
    canvas(id = cstring(fmt"chart-line-canvas-{self.getId}"))


proc lineData*(self: ChartComponent, values: seq[Value]): seq[float] =
  result = @[]

  for value in values:
    case value.kind:
    of Int: result.add(parseJsInt(value.i).float)

    of Float: result.add(parseJsFloat(value.f))

    of Char: result.add(value.c[0].int.float)

    of CString, String: result.add(value.text.len.float)

    of Bool: result.add(value.b.int.float)

    of Seq, Set: result.add(value.elements.len.float)

    else: result.add(0.0)


proc ensureLineDataset*(self: ChartComponent, expression: cstring): js =
  if not self.lineDatasetIndices.hasKey(expression):
    let emptyData: seq[float] = @[]
    self.datasets.add(
      js{
        "label": expression,
        "data": emptyData,
        "borderColor": cstring"#F98D71"
      }
    )
    self.lineDatasetIndices[expression] = self.datasets.len - 1

  return self.datasets[self.lineDatasetIndices[expression]]

proc addValues*(self: ChartComponent, expression: cstring, values: seq[Value]) =
  if self.viewKind == ViewLine or self.viewKind == ViewPie:
    self.ensure()

  var lineData = self.lineData(values)
  let dataset = self.ensureLineDataset(expression)

  for i in 0..<lineData.len:
    dataset.data.push(lineData[i])
    if self.lineLabels.len != cast[seq[int]](dataset.data).len:
      self.lineLabels.add(cstring($(self.lineLabels.len)))
      self.pieLabels.add(cstring($(self.pieLabels.len)))

  if not self.line.isNil:
    self.line.toJs.update()

  var values = JsAssoc[cstring, float]{}

  for (label, value) in zip(self.pieLabels, self.pieValues):
    values[label] = value

  for value in lineData:
    let valueText = cstring($value)
    if values.hasKey(valueText):
      values[valueText] = values[valueText] + 1.0
    else:
      values[valueText] = 1.0

  self.pieLabels = @[]
  self.pieValues = @[]

  for label, value in values:
    self.pieLabels.add(label)
    self.pieValues.add(value)

  if not self.pie.isNil:
    self.pieConfig.data.labels = self.pieLabels
    self.pieConfig.data.datasets[0].data = self.pieValues
    self.pie.toJs["update"].call(self.pie, 0)

proc replaceAllValues*(self: ChartComponent, expression: cstring, values: seq[Value]) =
  if self.lineDatasetIndices.hasKey(expression):
    # let lineData = self.lineData(values)
    let dataset = cast[seq[JsObject]](self.datasets)[self.lineDatasetIndices[expression]]
    var datasetData = cast[seq[int]](dataset.data)

    datasetData = @[]
    self.lineLabels = @[]
    self.addValues(expression, values)

proc update*(self: ChartComponent, values: seq[Value], replace: bool) =
  if self.viewKind == ViewLine or self.viewKind == ViewPie:
    self.ensure()

  var lineData = self.lineData(values)

  if not self.line.isNil:
    if not replace:
      self.lineConfig.data.datasets[0].data = self.lineConfig.data.datasets[0].data.toJs.concat(lineData)
    else:
      self.lineConfig.data.datasets[0].data = lineData

    self.line.toJs["update"].call(self.line, 0)

  var values = JsAssoc[cstring, float]{}

  if not replace:
    for (label, value) in zip(self.pieLabels, self.pieValues):
      values[label] = value

  for value in lineData:
    let valueText = cstring($value)
    if values.hasKey(valueText):
      values[valueText] = values[valueText] + 1.0
    else:
      values[valueText] = 1.0

  self.pieLabels = @[]
  self.pieValues = @[]

  for label, value in values:
    self.pieLabels.add(label)
    self.pieValues.add(value)

  if not self.pie.isNil:
    self.pieConfig.data.labels = self.pieLabels
    self.pieConfig.data.datasets[0].data = self.pieValues
    self.pie.toJs["update"].call(self.pie, 0)

  if not replace:
    self.results = self.results.concat(lineData)
  else:
    self.results = lineData

proc renderPie*(self: ChartComponent): VNode =
  let hidden =
    if self.viewKind != ViewPie:
      " hidden"
    else:
      ""

  result = buildHtml(
    tdiv(
      class = cstring(fmt"chart-pie{hidden}"),
      id = cstring(fmt"chart-pie-{self.getId}"),
    )
  ):
    canvas(id = cstring(fmt"chart-pie-canvas-{self.getId}"))

proc renderChart*(self: ChartComponent): VNode =
  ## Render the rich Karax chart sub-tree used by legacy value views.
  ##
  ## This remains a Karax VNode renderer for inline history charts, but it is a
  ## regular proc so ChartComponent no longer participates in generic
  ## Component.render dispatch while the surrounding surfaces are migrated.
  var table = self.tableView()

  result = buildHtml(
    tdiv(class="chart-results-container")
  ):
    table
    renderLine(self)
    renderPie(self)

  result.isThirdParty = true

proc inlineHistoryView*(self: ValueComponent, expression: cstring): VNode =
  let chart = self.charts[expression]
  var chartElement = chart.renderChart()

  chart.ensure()

  # if self.stateID != -1:
  #   kxiMap[&"stateComponent-{self.stateID}"].afterRedraws.add(proc =
  #     let container = document.getElementById(cstring(fmt"history-{expression}"))
  #     if not container.isNil:
  #       container.toJs.scrollTop = chart.historyScrollTop
  #   ) # TODO: Handle multiple state components
  self.state.kxi.afterRedraws.add(proc =
    let container = document.getElementById(cstring(fmt"history-{expression}"))
    if not container.isNil:
      container.toJs.scrollTop = self.historyScrollTop
      self.state.redrawForExtension()
  )

  result = buildHtml(
    tdiv(class = "history-container")
  ):
    tdiv(
      class = "inline-history",
      id = cstring(fmt"history-{expression}"),
    ):
      chartElement

  proc setupExtraScrollHandlers() =
    let el = document.getElementById("history-" & $expression)
    if not el.isNil:
      el.addEventListener(
        "wheel",
        proc (ev: Event) =
          kout el.scrollTop
          self.historyScrollTop = cast[int](el.scrollTop)
      )

  discard setTimeout(proc() = setupExtraScrollHandlers(), 1)

proc createHistoryContextMenu(self: ValueComponent, expression: cstring, value: Value, ev: Event): seq[ContextMenuItem] =
  var addToScratchpad:  ContextMenuItem
  var contextMenu: seq[ContextMenuItem]

  addToScratchpad = ContextMenuItem(
    name: "Add to scratchpad",
    hint: "",
    handler: proc(e: Event) =
      self.state.api.emit(InternalAddToScratchpad, ValueWithExpression(expression: expression, value: value))
  )

  contextMenu &= addToScratchpad

  return contextMenu

proc historyJump(self: ValueComponent, location: types.Location) =
  self.api.historyJump(location)

proc historyClick(self: ValueComponent, location: types.Location) =
  self.historyJump(location)

proc historyContextAction(self: ValueComponent, event: HistoryResult, ev: Event) =
  ev.stopPropagation()
  if self.state.inExtension:
    ev.preventDefault()
  let contextMenu = self.createHistoryContextMenu(self.baseExpression, event.value, ev)
  let e = ev.toJs

  if contextMenu != []:
    showContextMenu(contextMenu, cast[int](e.x), cast[int](e.y), self.state.inExtension)

proc appendText(parent: Node, value: cstring)

proc newElement(tag: cstring, className: cstring = cstring""): Node

proc historyLocationView(self: ValueComponent, event: HistoryResult): VNode =
  buildHtml(
    tdiv(
      class = "history-location",
      # onmousedown = proc(ev: Event, tg: VNode) =
      #   if cast[MouseEvent](ev).button == 0:
      #     self.historyClick(event.location),
      oncontextmenu = proc(ev: Event, tg: VNode) =
        ev.preventDefault()
        self.historyContextAction(event, ev)
    )
  ):
    text $event.location.rrTicks

proc historyValueView(self: ValueComponent, event: HistoryResult): VNode =
  buildHtml(
    tdiv(
      class = "history-value",
      onmousedown = proc(ev: Event, tg: VNode) =
        if cast[MouseEvent](ev).button == 0:
          self.historyClick(event.location),
      oncontextmenu = proc(ev: Event, tg: VNode) =
        ev.preventDefault()
        self.historyContextAction(event, ev)
    )
  ):
    text event.value.textRepr

proc renderChartCanvasDom(self: ChartComponent, kind: cstring, hidden: bool): Node =
  let hiddenClass = if hidden: cstring" hidden" else: cstring""

  result = newElement(cstring"div", cstring(fmt"chart-{kind}{hiddenClass}"))
  result.setAttribute(cstring"id", cstring(fmt"chart-{kind}-{self.getId}"))

  let canvas = document.createElement(cstring"canvas")
  canvas.setAttribute(cstring"id", cstring(fmt"chart-{kind}-canvas-{self.getId}"))
  result.appendChild(canvas)

proc renderHistoryTableDom(self: ValueComponent, expression: cstring, chart: ChartComponent): Node =
  let key =
    if self.baseAddress == NO_ADDRESS:
      expression
    else:
      cstring($self.baseAddress)
  let activeClass =
    if chart.viewKind == ViewTable:
      cstring"view-active"
    else:
      cstring"view-inactive"

  result = newElement(cstring"div", cstring(fmt"history-text {activeClass}"))

  let textElement = newElement(cstring"div", cstring"history-text-element")
  let locationElement = newElement(cstring"div", cstring"history-location-element")
  let valueElement = newElement(cstring"div", cstring"history-value-element")

  if self.state.valueHistory.hasKey(key):
    for event in self.state.valueHistory[key].results:
      let locationNode = newElement(cstring"div", cstring"history-location")
      locationNode.addEventListener(cstring"contextmenu", proc(ev: Event) =
        ev.preventDefault()
        self.historyContextAction(event, ev)
      )
      locationNode.appendText(cstring($event.location.rrTicks))
      locationElement.appendChild(locationNode)

      let valueNode = newElement(cstring"div", cstring"history-value")
      valueNode.addEventListener(cstring"mousedown", proc(ev: Event) =
        if cast[MouseEvent](ev).button == 0:
          self.historyClick(event.location)
      )
      valueNode.addEventListener(cstring"contextmenu", proc(ev: Event) =
        ev.preventDefault()
        self.historyContextAction(event, ev)
      )
      valueNode.appendText(event.value.textRepr)
      valueElement.appendChild(valueNode)

  textElement.appendChild(locationElement)
  textElement.appendChild(valueElement)
  result.appendChild(textElement)

proc renderChartDom(self: ValueComponent, expression: cstring): Node =
  let chart = self.charts[expression]

  result = newElement(cstring"div", cstring"chart-results-container")
  result.appendChild(self.renderHistoryTableDom(expression, chart))
  result.appendChild(chart.renderChartCanvasDom(cstring"line", chart.viewKind != ViewLine))
  result.appendChild(chart.renderChartCanvasDom(cstring"pie", chart.viewKind != ViewPie))

proc renderInlineHistoryDom(self: ValueComponent, expression: cstring): Node =
  let chart = self.charts[expression]
  let chartElement = self.renderChartDom(expression)

  chart.ensure()

  self.state.kxi.afterRedraws.add(proc =
    let container = document.getElementById(cstring(fmt"history-{expression}"))
    if not container.isNil:
      container.toJs.scrollTop = self.historyScrollTop
      self.state.redrawForExtension()
  )

  result = newElement(cstring"div", cstring"history-container")

  let inlineHistory = newElement(cstring"div", cstring"inline-history")
  inlineHistory.setAttribute(cstring"id", cstring(fmt"history-{expression}"))
  inlineHistory.appendChild(chartElement)
  result.appendChild(inlineHistory)

  proc setupExtraScrollHandlers() =
    let el = document.getElementById(cstring("history-" & $expression))
    if not el.isNil:
      el.addEventListener(
        cstring"wheel",
        proc (ev: Event) =
          kout el.scrollTop
          self.historyScrollTop = cast[int](el.scrollTop)
      )

  discard setTimeout(proc() = setupExtraScrollHandlers(), 1)

proc addChart(self: ValueComponent, expression: cstring): ChartComponent =
  self.charts[expression] = makeChartComponent(self.data)
  let chart = self.charts[expression]

  chart.setId(self.data.ui.idMap["chart"])
  self.data.ui.idMap[cstring"chart"] = self.data.ui.idMap[cstring"chart"] + 1
  chart.stateID = self.stateID
  chart.expression = expression

  return self.charts[expression]

method ensureCollectionElementsChart*(
  self: ValueComponent,
  value: Value,
  expression: cstring,
  valueView: proc(value: Value): VNode
) {.base.} =
  let tableView = proc: VNode =
    let kl = if self.charts[expression].viewKind == ViewTable: cstring"view-active" else: cstring"view-inactive"
    buildHtml(tdiv(class=kl)):
      valueView(value)
  if not self.charts.hasKey(expression):
    let chart = self.addChart(expression)

    chart.tableView = tableView
    chart.ensure()
    chart.addValues(expression, value.elements)

    self.data.ui.idMap[cstring"chart"] = self.data.ui.idMap[cstring"chart"] + 1
  else:
    if self.charts.hasKey(expression):
      self.charts[expression].tableView = tableView
      self.charts[expression].update(value.elements, replace=true)

proc checkHistoryLocation*(self: ValueComponent, expression: cstring) =
  # for now this applicable for db traces only
  let currentLocation = self.location

  if currentLocation.path != self.state.valueHistory[expression].location.path or
    currentLocation.functionName != self.state.valueHistory[expression].location.functionName:
      self.state.valueHistory.del(expression)
      self.showInline[expression] = false

method showHistory*(self: ValueComponent, expression: cstring, redraw: bool = true) {.async.} =
  let key = if self.baseAddress == NO_ADDRESS:
      expression
    else:
      cstring($self.baseAddress)
  clog cstring(fmt"showHistory {key}")
  console.log self.state.valueHistory

  let hasValueHistory = self.state.valueHistory.hasKey(key)

  if not hasValueHistory or self.charts.len() == 0:
    let location = self.location

    if not hasValueHistory:
      self.state.valueHistory[key] =
        ValueHistory(
          location: location,
          results: @[]
        )

    self.showInline[expression] = true

    var tableView = proc: VNode =
      let kl =
        if self.charts[expression].viewKind == ViewTable:
          "view-active"
        else:
          "view-inactive"

      buildHtml(tdiv(class = cstring(fmt"history-text {kl}"))):
        tdiv(class = "history-text-element"):
          tdiv(class = "history-location-element"):
            for event in self.state.valueHistory[key].results:
              historyLocationView(self, event)
          tdiv(class = "history-value-element"):
            for event in self.state.valueHistory[key].results:
              historyValueView(self, event)

    let chart = self.addChart(expression)

    chart.tableView = tableView
    # chart.ensure()
    # self.ensureValueComponent()
    if not hasValueHistory:
      echo "loadHistory for ", expression
      self.loadHistory(expression)
  else:
    # TODO?
    # self.showInline[expression] = not self.showInline[expression]
    discard

  if redraw:
    self.state.redrawForExtension()
    self.state.redraw()

method onUpdatedHistory*(self: ValueComponent, update: HistoryUpdate) {.async.} =
  # TODO: detect if db-based or rr-based
  # for now assume if NO_ADDRESS: db-based
  let key = if update.address == NO_ADDRESS: update.expression else: cstring($update.address)
  if update.address != NO_ADDRESS:
    # assuming rr
    #
    # adding an artifficial watch variable for this address
    # should be loaded on next load-locals update
    #   if we jump to a call/frame, where no local variable matches the address of this history
    #   we can show it at least for this artifficial watch variable:
    # TODO: eventually adding `(typeName*)` ?
    # toHex(update.address) seem to produce a smaller value? maybe because of JavaScript number
    #   something like ~2^53 limitation for nim ints? not sure
    #   that's why we use baseAddress, assuming the history is for this value
    let expression = if self.baseValue.typ.kind == Pointer:
        # here for `int* a` and its address we would track `(int*)a`
        cstring(fmt"({self.baseValue.typ.langType})0x{toHex(self.baseAddress)}")
      else:
        # here, for `int a` and its address we would track `(int*)a_address`
        cstring(fmt"({self.baseValue.typ.langType}*)0x{toHex(self.baseAddress)}")
    if expression notin self.state.watchExpressions:
      self.state.watchExpressions.add(expression)

  var valueHistory = self.state.valueHistory
  echo "update history for ", key
  if valueHistory.hasKey(key):
    var unsortedHistory = valueHistory[key].results.concat(update.results.filterIt(it notin valueHistory[key].results))
    var sortedHistory = sorted(
      unsortedHistory,
      proc (a: HistoryResult, b: HistoryResult): int =
        cmp(a.location.rrTicks, b.location.rrTicks)
    )
    var historyWithoutRepetitions: seq[HistoryResult] = @[]
    var previousStoredValue: Value = nil

    for i, res in sortedHistory:
      if i > 0:
        if previousStoredValue.testEq(res.value):
          # ignore and don't store: assume it's a repetition,
          # and store only the first occurence we have
          continue
        else:
          # store
          historyWithoutRepetitions.add(res)
          previousStoredValue = res.value

      else:
        # always store the first result
        historyWithoutRepetitions.add(res)
        previousStoredValue = res.value

    valueHistory[key].results = historyWithoutRepetitions

    self.redraw()


proc atomValueView(self: ValueComponent, valueText: string, expression: cstring, klass: string, value: Value): VNode =
  let klassNumber =
    if self.i mod 2 == 0:
      "atom-even"
    else:
      "atom-odd"

  self.i += 1

  let htmlText = valueText
  let defaultClass =
    if not self.charts.hasKey(expression):
      "value-expanded-default"
    else:
      ""

  result = buildHtml(
    tdiv(class = cstring(fmt"value-expanded-atom atom-{klass} {klassNumber} {defaultClass}"))
  ):
    if not self.uiExpanded(value, expression) or not self.charts.hasKey(expression):
      span(class = "value-expanded-text"):
        text htmlText
      span(class = "value-type"):
        text(value.typ.langType)
    else:
      switchChartKindView(self.charts[expression])

proc atomValueTextAndClass(value: Value): (string, string) =
  case value.kind:
  of Int, Float, String, CString, Char, Bool:
    ($value, toLowerAscii($value.kind))

  of Enum, Enum16, Enum32:
    (value.readableEnum(), "enum")

  of FunctionKind:
    (value.textRepr, "function")

  of types.None:
    ("nil", "nil")

  else:
    ("", "empty")

proc collapsedValueTextAndClass(value: Value): (string, string) =
  case value.kind:
  of Pointer:
    ($value.textRepr, "pointer")

  of Seq, Set, HashSet, OrderedSet, Array, Varargs:
    ($value.textRepr, "seq")

  of Variant:
    ($value.textRepr, "variant")

  of TableKind:
    ($value.textRepr, "table")

  of Instance, Union, Tuple:
    ($value.textRepr, "instance")

  else:
    atomValueTextAndClass(value)

proc inlineHistoryVisible(self: ValueComponent, expression: cstring): bool =
  self.charts.hasKey(expression) and
    self.showInline.hasKey(expression) and
    self.showInline[expression]

proc appendText(parent: Node, value: cstring) =
  parent.appendChild(document.createTextNode(value))

proc newElement(tag: cstring, className: cstring): Node =
  result = document.createElement(tag)
  if className.len > 0:
    result.setAttribute(cstring"class", className)

proc compoundOrPointsToCompound(value: Value): bool =
  return value.kind notin ATOM_KINDS and
    (value.kind != Pointer or
    (not value.refValue.isNil and value.refValue.kind notin ATOM_KINDS))

proc valueLanguage(self: ValueComponent): Lang =
  try:
    self.data.trace.lang
  except:
    LangNoir

proc renderValueHistoryButtonDom(self: ValueComponent, expression: cstring, active: string): Node =
  result = newElement(cstring"button")
  result.setAttribute(cstring"class", cstring(&"{active} ct-button-image-sm-secondary ct-custom-button-size ct-ml-2"))
  result.setAttribute(cstring"id", cstring"value-history")
  result.addEventListener(cstring"mousedown", proc(ev: Event) =
    if cast[MouseEvent](ev).button == 0:
      discard self.showHistory(expression)
  )

  let tooltip = newElement(cstring"div", cstring"custom-tooltip")
  tooltip.appendText(cstring"Toggle history value")
  result.appendChild(tooltip)

proc renderDirectAtomValueDom(
  self: ValueComponent,
  valueText: string,
  expression: cstring,
  klass: string,
  value: Value
): Node =
  let klassNumber =
    if self.i mod 2 == 0:
      "atom-even"
    else:
      "atom-odd"

  self.i += 1

  let defaultClass =
    if not self.charts.hasKey(expression):
      "value-expanded-default"
    else:
      ""

  result = newElement(
    cstring"div",
    cstring(fmt"value-expanded-atom atom-{klass} {klassNumber} {defaultClass}")
  )

  let textSpan = newElement(cstring"span", cstring"value-expanded-text")
  textSpan.appendText(cstring(valueText))
  result.appendChild(textSpan)

  let typeSpan = newElement(cstring"span", cstring"value-type")
  typeSpan.appendText(value.typ.langType)
  result.appendChild(typeSpan)

proc renderExpandButtonDom(
  self: ValueComponent,
  value: Value,
  expression: cstring,
  path: seq[SubPath],
  fresh: cstring
): Node =
  result = newElement(cstring"span", cstring("value-expand-button " & fresh))
  result.addEventListener(cstring"mousedown", proc(ev: Event) =
    self.data.focusComponent(self)
    ev.stopPropagation()
    capture expression, value, path:
      discard self.expandNewValues(value, path)
      discard self.toggleExpanded(value, expression)
  )

  let caretClass =
    if self.uiExpanded(value, expression):
      cstring"caret-expand"
    else:
      cstring"caret-collapse"

  result.appendChild(newElement(cstring"div", caretClass))

proc renderExpandMarkerDom(self: ValueComponent, value: Value, left: string, right: string, empty: bool): Node =
  var list = if empty: "" else: ".."

  if value.kind == NonExpanded:
    list = ".."

  let klass = if self.i mod 2 == 0: "atom-even" else: "atom-odd"

  self.i += 1

  result = newElement(cstring"span", cstring(fmt"value-expand {klass}"))
  result.appendText(cstring(&"{left}{list}{right}"))

proc renderLoadMoreButtonDom(self: ValueComponent, value: Value, path: seq[SubPath]): Node =
  let cPath = path

  result = newElement(cstring"button", cstring"value-load-more-button")
  result.addEventListener(cstring"mousedown", proc(ev: Event) =
    capture value, cPath:
      if not self.isOperationRunning:
        self.isOperationRunning = true
        discard self.loadMoreValues(value, cPath)
  )
  result.appendText(cstring"Load More")

proc childPathForExpandedValue(parent: Value, childName: cstring, element: Value, path: seq[SubPath]): seq[SubPath] =
  result = path

  if element.kind notin ATOM_KINDS and parent.kind != Variant:
    try:
      let index = parseInt(($childName)[1..^2])
      result.add(SubPath{kind: Index, index: index, typeKind: parent.kind})
    except:
      result.add(SubPath{kind: Field, name: childName, typeKind: parent.kind})

proc expandedChildrenAndDelimiters(
  self: ValueComponent,
  value: Value,
  lang: Lang
): (seq[(cstring, Value)], string, string) =
  var children: seq[(cstring, Value)] = @[]
  var left = ""
  var right = ""

  case value.kind:
  of Seq, Set, HashSet, OrderedSet, Array, Varargs:
    left =
      if value.kind in {Array, Varargs}:
        TOKEN_TEXTS[lang][ArrayOpen]
      else:
        TOKEN_TEXTS[lang][SeqOpen]
    right =
      if value.kind in {Array, Varargs}:
        TOKEN_TEXTS[lang][ArrayClose]
      else:
        TOKEN_TEXTS[lang][SeqClose]

    for i, element in value.elements:
      children.add((cstring("[" & $i & "]"), element))

  of Variant:
    if not value.activeVariantValue.isNil:
      for label, fieldValue in unionChildren(value):
        children.add((label, fieldValue))

    left = $value.typ.langType & TOKEN_TEXTS[lang][InstanceOpen]
    right = TOKEN_TEXTS[lang][InstanceClose]

  of TableKind:
    for items in value.items:
      children.add((($items[0]).cstring, items[1]))

    left = $value.typ.langType & TOKEN_TEXTS[lang][InstanceOpen]
    right = TOKEN_TEXTS[lang][InstanceClose]

  of Instance, Union, Tuple:
    if value.kind == Union:
      for label, fieldValue in unionChildren(value):
        children.add((label, fieldValue))
    else:
      for i, label in value.typ.labels:
        let fieldValue = value.elements[i]
        children.add((label, fieldValue))

    left = $value.typ.langType & TOKEN_TEXTS[lang][InstanceOpen]
    right = TOKEN_TEXTS[lang][InstanceClose]

  else:
    discard

  (children, left, right)

proc renderValueRowDom(
  self: ValueComponent,
  value: Value,
  expression: cstring,
  name: cstring,
  path: seq[SubPath],
  depth: int = 0,
  annotation: cstring = ""
): Node

proc renderExpandedCompoundDom(
  self: ValueComponent,
  value: Value,
  expression: cstring,
  children: seq[(cstring, Value)],
  path: seq[SubPath],
  left: string,
  right: string,
  depth: int = 0
): Node =
  result = newElement(cstring"div", cstring(fmt"value-expanded-compound depth-{depth}"))
  result.applyStyle(style(StyleAttr.marginLeft, cstring"17px"))

  if children.len == 0:
    result.appendChild(self.renderExpandMarkerDom(value, left, right, children.len == 0))
  else:
    for child in children:
      let (childName, element) = child
      let childPath = childPathForExpandedValue(value, childName, element, path)

      echo "view expandCompoundView ", expression, " ", childName
      result.appendChild(self.renderValueRowDom(
        element,
        cstring(fmt"{expression} {childName}"),
        childName,
        childPath,
        depth + 1
      ))

proc renderValueContentDom(
  self: ValueComponent,
  value: Value,
  expression: cstring,
  path: seq[SubPath],
  depth: int,
  annotation: cstring,
  atomClass: var cstring
): Node =
  let lang = self.valueLanguage()

  case value.kind:
  of Pointer:
    if self.uiExpanded(value, expression):
      var nextPath = path
      nextPath.add(SubPath{kind: Dereference, typeKind: value.kind})
      result = self.renderValueRowDom(value.refValue, expression, cstring"_", nextPath, depth, value.address & " ->")
    else:
      let (valueText, klass) = collapsedValueTextAndClass(value)
      result = self.renderDirectAtomValueDom(valueText, expression, klass, value)

  of Seq, Set, HashSet, OrderedSet, Array, Varargs,
      Variant, TableKind, Instance, Union, Tuple:
    if self.uiExpanded(value, expression):
      let (children, left, right) = self.expandedChildrenAndDelimiters(value, lang)

      if children.len == 0:
        atomClass = cstring"value-expanded-atom-parent"

      result = self.renderExpandedCompoundDom(value, expression, children, path, left, right, depth)
    else:
      let (valueText, klass) = collapsedValueTextAndClass(value)
      result = self.renderDirectAtomValueDom(valueText, expression, klass, value)

  of Int, Float, String, CString, Char, Bool,
      Enum, Enum16, Enum32, FunctionKind, types.None:
    let (valueText, klass) = atomValueTextAndClass(value)
    result = self.renderDirectAtomValueDom(valueText, expression, klass, value)

  of TypeKind.Raw:
    result = newElement(cstring"div", cstring"value-raw value-expanded-text")
    result.appendText(value.r)

  of NonExpanded:
    result = newElement(cstring"div", cstring"value-non-expanded value-expanded-text")
    result.appendText(cstring"<non expanded>")

  of types.Error:
    result = newElement(cstring"div", cstring"value-error value-expanded-text")
    result.appendText(value.msg)

  of Ref:
    result = newElement(cstring"div", cstring"value-bug")
    result.appendText(cstring"bug in proc view -> value.nim")

  else:
    result = newElement(cstring"div", cstring"value-empty value-expanded-text")
    result.appendText(cstring"")

proc renderValueRowDom(
  self: ValueComponent,
  value: Value,
  expression: cstring,
  name: cstring,
  path: seq[SubPath],
  depth: int = 0,
  annotation: cstring = ""
): Node =
  if value.kind == Ref and not value.refValue.toJs.isNil:
    return self.renderValueRowDom(value.refValue, expression, name, path, depth)

  if self.uiExpanded(value, expression):
    discard self.expandNewValues(value, path)

  var isWatch = if value.isWatch: cstring"value-watch" else: cstring""
  var isSelected = if self.selected: cstring"value-selected" else: cstring""
  var fresh = if self.fresh: cstring("value-fresh-" & $self.freshIndex) else: cstring""
  self.isOperationRunning = false
  let active =
    if self.showInline.hasKey(expression) and self.showInline[expression]:
      "active"
    else:
      ""

  var atomClass =
    if value.kind in ATOM_KINDS or not self.uiExpanded(value, expression):
      cstring"value-expanded-atom-parent"
    else:
      cstring"value-expanded-compound-parent"

  result = newElement(
    cstring"div",
    cstring(fmt"value-expanded {isWatch} {isSelected} border-value-{depth} value-expanded-name")
  )

  let atomParent = newElement(cstring"div", atomClass)
  atomParent.addEventListener(cstring"contextmenu", proc(ev: Event) =
    let contextMenu = self.createContextMenuItems(value, ev)
    let e = ev.toJs
    let inExtension = not self.state.isNil and self.state.inExtension
    if inExtension:
      ev.preventDefault()
    if contextMenu != []:
      showContextMenu(contextMenu, cast[int](e.x), cast[int](e.y), inExtension)
  )

  let nameContainer = newElement(cstring"div", cstring"value-name-container")
  if self.isTooltipValue and expression == self.baseExpression:
    let scratchpadButton = newElement(cstring"div", cstring"add-to-scratchpad-button")
    scratchpadButton.addEventListener(cstring"mousedown", proc(ev: Event) =
      self.api.openValueInScratchpad(ValueWithExpression(expression: expression, value: value))
      self.redraw()
    )
    let tooltip = newElement(cstring"div", cstring"custom-tooltip")
    tooltip.appendText(cstring"Add to scratchpad")
    scratchpadButton.appendChild(tooltip)
    nameContainer.appendChild(scratchpadButton)

  if compoundOrPointsToCompound(value):
    nameContainer.appendChild(self.renderExpandButtonDom(value, expression, path, fresh))

  let nameSpan = newElement(cstring"span", cstring"value-name")
  nameSpan.appendText(name & cstring": ")
  nameContainer.appendChild(nameSpan)

  if self.uiExpanded(value, expression) and value.kind notin ATOM_KINDS:
    let typeSpan = newElement(cstring"span", cstring"value-type")
    typeSpan.appendText(value.typ.langType)
    nameContainer.appendChild(typeSpan)

    let annotationSpan = newElement(cstring"span", cstring"value-annotation")
    annotationSpan.appendText(annotation)
    nameContainer.appendChild(annotationSpan)

    if expression == self.baseExpression:
      nameContainer.appendChild(self.renderValueHistoryButtonDom(expression, active))

  atomParent.appendChild(nameContainer)

  let valueContainer = newElement(cstring"div")
  let valueView = newElement(cstring"span", cstring"value-view")

  let valueViewStyle =
    if value.kind == types.Error:
      style(StyleAttr.marginLeft, cstring"10px")
    else:
      style(StyleAttr.marginLeft, cstring"0px")
  valueView.applyStyle(valueViewStyle)

  try:
    valueView.appendChild(self.renderValueContentDom(value, expression, path, depth, annotation, atomClass))
  except:
    let errorValue = newElement(cstring"div", cstring"value-error")
    echo "VALUE ERROR: ", getCurrentExceptionMsg()
    errorValue.appendText(cstring(fmt"^ error: Can't show value: {getCurrentExceptionMsg()}"))
    valueView.appendChild(errorValue)
  valueContainer.appendChild(valueView)
  atomParent.appendChild(valueContainer)
  atomParent.setAttribute(cstring"class", atomClass)

  if expression == self.baseExpression and not self.uiExpanded(value, expression):
    atomParent.appendChild(self.renderValueHistoryButtonDom(expression, active))

  if value.partiallyExpanded and self.uiExpanded(value, expression):
    atomParent.appendChild(self.renderLoadMoreButtonDom(value, path))

  result.appendChild(atomParent)

  if expression == self.baseExpression and self.inlineHistoryVisible(expression):
    result.appendChild(self.renderInlineHistoryDom(expression))

proc expandValueView(self: ValueComponent, value: Value, expression: cstring, left: string, right: string, empty: bool): VNode =
  var list = if empty: "" else: ".."

  if value.kind == NonExpanded:
    list = ".."

  let klass = if self.i mod 2 == 0: "atom-even" else: "atom-odd"

  self.i += 1

  result = buildHtml(
    span(class = cstring(fmt"value-expand {klass}"))
  ):
    text(&"{left}{list}{right}")

method delete*(self: ValueComponent) {.async.} =
  if self.selected:
    var state = self.data.stateComponent(self.stateID)
    state.deleteWatch(self.baseExpression)

proc expandedCompoundView*(
  self: ValueComponent,
  value: Value,
  expression: cstring,
  children: seq[(cstring, Value)],
  path: seq[SubPath],
  left: string,
  right: string,
  depth: int = 0
): VNode =
  result = buildHtml(
    tdiv(
      class = cstring(fmt"value-expanded-compound depth-{depth}"),
      style = style(StyleAttr.marginLeft, cstring"17px")
    )
  ):
    if children.len == 0:
      expandValueView(self, value, expression, left, right, children.len == 0)
    else:
      for child in children:
        let (name, element) = child
        var childPath = path

        if element.kind notin ATOM_KINDS and value.kind != Variant:
          try:
            let index = parseInt(($name)[1..^2])
            block: childPath.add(SubPath{kind: Index, index: index, typeKind: value.kind})
          except:
            block: childPath.add(SubPath{kind: Field, name: name, typeKind: value.kind})

        # TODO: when fixing expansion of values/fields:
        #   rework with activeVariantValue fields or elements
        #   no `activeFields` anymore!
        #
        # if value.kind == Variant and value.activeFields.len != 0:
        #   block: path.add(
        #     SubPath{
        #       kind: VariantKind,
        #       kindNumber: parseInt($value.activeVariant),
        #       variantName: name,
        #       typeKind: value.kind
        #     }
        #   )

        #   if name in value.activeFields:
        #     view(self, element, cstring(fmt"{expression} {name}"), name, path, depth + 1)
        # else:

        echo "view expandCompoundView ", expression, " ", name
        view(self, element, cstring(fmt"{expression} {name}"), name, childPath, depth + 1)

proc createContextMenuItems(self: ValueComponent, value: Value, ev: Event): seq[ContextMenuItem] =
  var showHistory:  ContextMenuItem
  var contextMenu:  seq[ContextMenuItem]

  if not self.isScratchpadValue:
    showHistory = ContextMenuItem(
      name: "Toggle value history",
      hint: "",
      handler: proc(e: Event) =
        discard self.showHistory(self.baseExpression)
    )

    contextMenu &= showHistory

  return contextMenu

# proc historyButtonView(self: ValueComponent, expression: cstring): VNode =
#   buildHtml(
#     tdiv(
#       class = "value-history-button",
#       onclick = proc =
#         discard self.showHistory(expression)
#     )
#   ):
#     fa "search"

proc view(
  self: ValueComponent,
  value: Value,
  expression: cstring,
  name: cstring,
  path: seq[SubPath],
  depth: int = 0,
  annotation: cstring = ""
): VNode =
  if value.kind == Ref and not value.refValue.toJs.isNil:
    result = self.view(value.refValue, expression, name, path, depth)
    return

  if self.uiExpanded(value, expression):
    discard self.expandNewValues(value, path)

  # var isExpandedCompoundParent = value.kind notin ATOM_KINDS and self.uiExpanded(value, expression)
  var atom = if value.kind in ATOM_KINDS or not self.uiExpanded(value, expression): "value-expanded-atom-parent" else: "value-expanded-compound-parent"
  var lang = LangUnknown
  try:
    lang = self.data.trace.lang
  except:
    lang = LangNoir
  var valueView = proc(value: Value): VNode =
    case value.kind:
    of Int, Float, String, CString, Char, Bool:
      self.atomValueView($value, expression, toLowerAscii($value.kind), value)

    of Enum, Enum16, Enum32:
      self.atomValueView(value.readableEnum(), expression, "enum", value)

    of FunctionKind:
      self.atomValueView(value.textRepr, expression, "function", value)

    of Pointer:
      if self.uiExpanded(value, expression):
        var nextPath = path
        nextPath.add(SubPath{kind: Dereference, typeKind: value.kind})
        self.view(value.refValue, expression, "_", nextPath, depth, value.address & " ->")
      else:
        self.atomValueView($value.textRepr, expression, "pointer", value)

    of Seq, Set, HashSet, OrderedSet, Array, Varargs:
      let left =
        if value.kind in {Array, Varargs}:
          TOKEN_TEXTS[lang][ArrayOpen]
        else:
          TOKEN_TEXTS[lang][SeqOpen]
      let right =
        if value.kind in {Array, Varargs}:
          TOKEN_TEXTS[lang][ArrayClose]
        else:
         TOKEN_TEXTS[lang][SeqClose]

      if self.uiExpanded(value, expression):
        var children: seq[(cstring, Value)]

        for i, element in value.elements:
          children.add((cstring("[" & $i & "]"), element))

        if children.len == 0:
          atom = "value-expanded-atom-parent"

        self.expandedCompoundView(value, expression, children, path, left, right, depth)
      else:
        self.atomValueView($value.textRepr, expression, "seq", value)

    of Variant:
      if self.uiExpanded(value, expression):
        var children: seq[(cstring, Value)] = @[]

        if not value.activeVariantValue.isNil:
          for label, fieldValue in unionChildren(value):
            children.add((label, fieldValue))

        let left = $value.typ.langType & TOKEN_TEXTS[lang][InstanceOpen]
        let right = TOKEN_TEXTS[lang][InstanceClose]

        self.expandedCompoundView(value, expression, children, path, left, right, depth)
      else:
        self.atomValueView($value.textRepr, expression, "variant", value)

    of TableKind:
      if self.uiExpanded(value, expression):
        var children: seq[(cstring, Value)] = @[]

        for items in value.items:
          children.add((($items[0]).cstring, items[1]))

        let left = $value.typ.langType & TOKEN_TEXTS[lang][InstanceOpen]
        let right = TOKEN_TEXTS[lang][InstanceClose]

        self.expandedCompoundView(value, expression, children, path, left, right, depth)
      else:
        self.atomValueView($value.textRepr, expression, "table", value)

    of Instance, Union, Tuple:
      if self.uiExpanded(value, expression):
        var children: seq[(cstring, Value)] = @[]

        if value.kind == Union:
          for label, fieldValue in unionChildren(value):
            children.add((label, fieldValue))
        else:
          for i, label in value.typ.labels:
            let fieldValue = value.elements[i]

            children.add((label, fieldValue))

        if children.len == 0:
          atom = "value-expanded-atom-parent"

        let left = $value.typ.langType & TOKEN_TEXTS[lang][InstanceOpen]
        let right = TOKEN_TEXTS[lang][InstanceClose]

        self.expandedCompoundView(value, expression, children, path, left, right, depth)
      else:
        self.atomValueView($value.textRepr, expression, "instance", value)

    of Ref:
      buildHtml(
        tdiv(class = "value-bug")
      ):
        text cstring"bug in proc view -> value.nim"

    of TypeKind.Raw:
      buildHtml(
        tdiv(class = "value-raw value-expanded-text")
      ):
        text(value.r)

    of types.None:
      self.atomValueView("nil", expression, "nil", value)

    of NonExpanded:
      buildHtml(
        tdiv(class = "value-non-expanded value-expanded-text")
      ):
        text "<non expanded>"

    of types.Error:
      buildHtml(
        tdiv(class = "value-error value-expanded-text")
      ):
        text value.msg

    else:
      buildHtml(
        tdiv(class = "value-empty value-expanded-text")
      ):
        text("")

  # var selectRow = proc =
  #   if value.isWatch:
  #     if self.selected:
  #       self.selected = false
  #     else:
  #       let state = self.data.stateComponent(self.stateID)

  #       for name, valueComponent in state.values:
  #         valueComponent.selected = false
  #         self.selected = true
  #         self.data.focusComponent(self)

  #         kxiMap[cstring"stateComponent-" & cstring($self.stateID)].afterRedraws.add(proc =
  #           discard windowSetTimeout(proc =
  #             jq(cstring".value-name-selected").focus(), 50)
  #         )

  #     self.data.redraw()

  # var nameEdit = proc =
  #   if value.isWatch:
  #     if not self.selected:
  #       let state = self.data.stateComponent(self.stateID)

  #       for name, valueComponent in state.values:
  #         valueComponent.selected = false
  #         self.selected = true
  #         self.data.focusComponent(self)

  #         kxiMap[cstring"stateComponent-" & cstring($self.stateID)].afterRedraws.add(proc =
  #           discard windowSetTimeout(proc =
  #             jq(cstring".value-name-selected").focus(), 50)
  #         )

  #       self.data.redraw()

  # var renameWatch = proc(e: Event, v: VNode) =
  #   var element = e.target
  #   let state = self.data.stateComponent(self.stateID)
  #   var text = cast[cstring](cast[js](element).innerText)

  #   if text.len > 0:
  #     state.renameWatch(expression, text)
  #   else:
  #     state.deleteWatch(expression)

  #   self.data.redraw()

  var isWatch = if value.isWatch: cstring"value-watch" else: cstring""
  var isSelected = if self.selected: cstring"value-selected" else: cstring""
  # var nameSelected = if self.selected: cstring"value-name-selected" else: cstring""
  var fresh = if self.fresh: cstring("value-fresh-" & $self.freshIndex) else: cstring""

  # let ensureCollectionElementsChart = proc: VNode =
  #   if isExpandedCompoundParent:
  #     self.ensureCollectionElementsChart(
  #       value,
  #       expression,
  #       proc(value: Value): VNode =
  #         buildHtml(tdiv()):
  #           valueView(value)
  #     )
  #   else:
  #     raise newException(ValueError, "chart not in right context")

  # let renderSelectedView = proc: VNode =
  #   if isExpandedCompoundParent:
  #     if self.charts.hasKey(expression):
  #       let chart = self.charts[expression]

  #       result = chart.renderChart()
  #       chart.ensure()
  #     else:
  #       result = nil
  #   else:
  #     raise newException(ValueError, "chart not in right context")

  let cPath = path

  self.isOperationRunning = false
  let active = if self.showInline[expression]: "active" else: ""

  result = buildHtml(
    tdiv(class = cstring(fmt"value-expanded {isWatch} {isSelected} border-value-{depth} value-expanded-name"))
  ):
    tdiv(
      class = cstring(fmt"{atom}"),
      onContextMenu = proc(ev: Event, v: VNode) =
        let contextMenu = self.createContextMenuItems(value, ev)
        let e = ev.toJs
        if not self.state.isNil and self.state.inExtension:
          ev.preventDefault()
        if contextMenu != []:
          showContextMenu(contextMenu, cast[int](e.x), cast[int](e.y), not self.state.isNil and self.state.inExtension)
    ):
      tdiv(class = "value-name-container"):
        if self.isTooltipValue and expression == self.baseExpression:
          tdiv(
            class = "add-to-scratchpad-button",
            onmousedown = proc(ev: Event, v: VNode) =
              self.api.openValueInScratchpad(ValueWithExpression(expression: expression, value: value))
              self.redraw()
          ):
            tdiv(class = "custom-tooltip"):
              text "Add to scratchpad"
        if compoundOrPointsToCompound(value):
          span(
            class = "value-expand-button " & fresh,
            onmousedown = proc(ev: Event, v: VNode) =
              self.data.focusComponent(self)
              ev.stopPropagation()
              capture expression, value, cPath:
                discard self.expandNewValues(value, cPath)
                discard self.toggleExpanded(value, expression)
          ):
            if self.uiExpanded(value, expression):
              tdiv(class = "caret-expand")
            else:
              tdiv(class = "caret-collapse")
        span(class = "value-name"):
          text(name & ": ")
        if self.uiExpanded(value, expression) and value.kind notin ATOM_KINDS:
          span(class = "value-type"):
            text(value.typ.langType)
          span(class = "value-annotation"):
            text(annotation)
          if expression == self.baseExpression:
            button(
              class = &"{active} ct-button-image-sm-secondary ct-custom-button-size ct-ml-2",
              id = "value-history",
              onmousedown = proc(ev: Event, tg: VNode) =
                if cast[MouseEvent](ev).button == 0:
                  discard self.showHistory(expression)
            ):
              tdiv(class = "custom-tooltip"):
                text "Toggle history value"
      tdiv():
        var s: VStyle

        if value.kind == types.Error:
          s = style(StyleAttr.marginLeft, cstring"10px")
        else:
          s = style(StyleAttr.marginLeft, cstring"0px")

        span(
          class = "value-view",
          style = s
        ):
          try:
            valueView(value)
          except:
            tdiv(class = "value-error"):
              echo "VALUE ERROR: ", getCurrentExceptionMsg()
              text fmt"^ error: Can't show value: {getCurrentExceptionMsg()}"
      if expression == self.baseExpression and not self.uiExpanded(value, expression):
        button(
          class = &"{active} ct-button-image-sm-secondary ct-custom-button-size ct-ml-2",
          id = "value-history",
          onmousedown = proc(ev: Event, tg: VNode) =
            if cast[MouseEvent](ev).button == 0:
              discard self.showHistory(expression)
        ):
          tdiv(class = "custom-tooltip"):
            text "Toggle history value"
      if value.partiallyExpanded and self.uiExpanded(value, expression):
        button(
          class = "value-load-more-button",
          onmousedown = proc(ev: Event, v: VNode)=
            capture value, cPath:
              if not self.isOperationRunning:
                self.isOperationRunning = true
                discard self.loadMoreValues(value, cPath)
        ):
          text("Load More")
    if expression == self.baseExpression and
      self.charts.hasKey(expression) and
      self.showInline.hasKey(expression) and
      self.showInline[expression]:
        inlineHistoryView(self, expression)
  result.alwaysChange = true

proc renderValue*(self: ValueComponent): VNode =
  ## Render the rich Karax value sub-tree used by legacy/IsoNim-adjacent views.
  ##
  ## The expandable value tree still feeds editor, flow, trace and calltrace
  ## embeddings, but this regular proc avoids a residual generic render-method
  ## override while preserving the exact VNode tree.
  var path: seq[SubPath] = @[]

  path.add(SubPath{kind: Expression, expression: self.baseExpression, typeKind: self.baseValue.kind})
  result = self.view(self.baseValue, self.baseExpression, self.baseExpression, path, depth=0)

proc directValueDomSubject(self: ValueComponent): Value =
  if not self.baseValue.isNil and
      self.baseValue.kind == Ref and
      not self.baseValue.refValue.isNil:
    self.baseValue.refValue
  else:
    self.baseValue

proc rootValuePath(self: ValueComponent): seq[SubPath] =
  @[SubPath{kind: Expression, expression: self.baseExpression, typeKind: self.baseValue.kind}]

proc renderValueDom*(self: ValueComponent): Node =
  ## Shared DOM entrypoint for the rich value tree.
  ##
  ## Collapsed rows, expanded compound shells, child lists, active inline
  ## history/chart surfaces, expanded load-more rows, and the legacy fallback
  ## TypeKind branches now render directly here.
  let value = self.directValueDomSubject()
  if value.isNil:
    result = newElement(cstring"div", cstring"value-empty value-expanded-text")
    result.appendText(cstring"")
    return

  result = self.renderValueRowDom(
    value,
    self.baseExpression,
    self.baseExpression,
    self.rootValuePath(),
    depth=0
  )

proc renderValueDomWithLeft*(self: ValueComponent, left: cstring): Node =
  ## Render a value DOM node with the legacy root ``left`` style applied.
  ##
  ## Monaco inline value view zones historically patched this style onto the
  ## root value VNode immediately before materialization.  Keep that contract
  ## centralized with the value DOM entrypoint.
  result = self.renderValueDom()
  result.toJs.style.left = left

method redraw*(self: ValueComponent) =
  if not self.state.isNil:
    self.state.redraw()
  else:
    procCall Component(self).redraw()
