import ui_imports, ../types, ../renderer, ../utils
import ../communication, ../../common/ct_event
import ../event_helpers

let ATOM_KINDS = {
  Int, Float, String, CString, Char, Bool, Enum, Enum16, Enum32,
  types.Error, TypeKind.Raw, FunctionKind, TypeKind.None} # temp Function

proc view(
  self: ValueComponent,
  value: Value,
  expression: cstring,
  name: cstring,
  path: var seq[SubPath],
  depth: int = 0,
  annotation: cstring = ""
): VNode

proc addValues*(self: ChartComponent, expression: cstring, values: seq[Value])

proc loadHistory(self: ValueComponent, expression: cstring) =
  self.api.emit(CtLoadHistory, LoadHistoryArg(expression: expression, location: self.location))

method register*(self: ValueComponent, api: MediatorWithSubscribers) =
  self.api = api
  api.subscribe(CtUpdatedHistory, proc(kind: CtEventKind, response: HistoryUpdate, sub: Subscriber) =
    if cast[cstring](response.expression) == self.baseExpression:
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
          "type": j"line",
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

  j(&"rgba({r}, {g}, {b}, 1)")

proc pieLabelsColor*(labels: seq[cstring]): seq[cstring] =
  var colors: seq[cstring]
  var r = 255

  for i in 0..<labels.len:
    colors.add(j(&"rgba({r}, 169, 145, 1)"))
    r -= 20

  result = colors

proc ensurePie*(self: ChartComponent) =
  if self.pie.isNil and self.viewKind == ViewPie:
    self.pieConfig =
      js{
        "type": j"pie",
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
  var label = if self.viewKind == ViewLine: "ensureLine" else: "ensurePie"

  # if self.stateID != -1:
  #   # TODO: think how this would work in extension
  #   kxiMap[j("stateComponent-" & $self.stateID)].afterRedraws.add(proc =
  #     discard windowSetTimeout(proc = self.ensureBase(), 500)
  #   )
  # else:
  if not self.trace.isNil:
    self.ensureBase()
  else:
    cerror "vaue: " & label & " cant be called"
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

method render*(self: ChartComponent): VNode =
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
  var chartElement = chart.render()

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

proc historyLocationView(self: ValueComponent, event: HistoryResult): VNode =
  buildHtml(
    tdiv(
      class = "history-location",
      onmousedown = proc(ev: Event, tg: VNode) =
        if cast[MouseEvent](ev).button == 0:
          self.historyClick(event.location),
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

proc addChart(self: ValueComponent, expression: cstring): ChartComponent =
  self.charts[expression] = makeChartComponent(self.data)
  let chart = self.charts[expression]

  chart.setId(self.data.ui.idMap["chart"])
  self.data.ui.idMap[j"chart"] = self.data.ui.idMap[j"chart"] + 1
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

    self.data.ui.idMap[j"chart"] = self.data.ui.idMap[j"chart"] + 1
  else:
    if self.charts.hasKey(expression):
      self.charts[expression].tableView = tableView
      self.charts[expression].update(value.elements, replace=true)

proc checkHistoryLocation*(self: ValueComponent, expression: cstring) =
  let currentLocation = self.location

  if currentLocation.path != self.state.valueHistory[expression].location.path or
    currentLocation.functionName != self.state.valueHistory[expression].location.functionName:
      self.state.valueHistory.del(expression)
      self.showInline[expression] = false

method showHistory*(self: ValueComponent, expression: cstring) {.async.} =
  if not self.state.valueHistory.hasKey(expression):
    let location = self.location

    self.state.valueHistory[expression] =
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
            for event in self.state.valueHistory[expression].results:
              historyLocationView(self, event)
          tdiv(class = "history-value-element"):
            for event in self.state.valueHistory[expression].results:
              historyValueView(self, event)

    let chart = self.addChart(expression)

    chart.tableView = tableView
    # chart.ensure()
    # self.ensureValueComponent()
    self.loadHistory(expression)
  else:
    self.showInline[expression] = not self.showInline[expression]

  self.state.redrawForExtension()
  self.state.redraw()

method onUpdatedHistory*(self: ValueComponent, update: HistoryUpdate) {.async.} =
  let expression = cast[cstring](update.expression)
  var valueHistory = self.state.valueHistory

  if valueHistory.hasKey(expression):
    var unsortedHistory = valueHistory[expression].results.concat(update.results.filterIt(it notin valueHistory[expression].results))
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

    valueHistory[expression].results = historyWithoutRepetitions

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
  path: var seq[SubPath],
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

        if element.kind notin ATOM_KINDS and value.kind != Variant:
          try:
            let index = parseInt(($name)[1..^2])
            block: path.add(SubPath{kind: Index, index: index, typeKind: value.kind})
          except:
            block: path.add(SubPath{kind: Field, name: name, typeKind: value.kind})

        if value.kind == Variant and value.activeFields.len != 0:
          block: path.add(
            SubPath{
              kind: VariantKind,
              kindNumber: parseInt($value.activeVariant),
              variantName: name,
              typeKind: value.kind
            }
          )

          if name in value.activeFields:
            view(self, element, cstring(fmt"{expression} {name}"), name, path, depth + 1)
        else:
          view(self, element, cstring(fmt"{expression} {name}"), name, path, depth + 1)

        if depth + 1 < path.len:
          discard path.pop()

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

proc compoundOrPointsToCompound(value: Value): bool =
  return value.kind notin ATOM_KINDS and
    (value.kind != Pointer or
    (not value.refValue.isNil and value.refValue.kind notin ATOM_KINDS))


proc view(
  self: ValueComponent,
  value: Value,
  expression: cstring,
  name: cstring,
  path: var seq[SubPath],
  depth: int = 0,
  annotation: cstring = ""
): VNode =
  proc expandNewValues(self: ValueComponent, value: Value, path: seq[SubPath]) {.async.}

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
        path.add(SubPath{kind: Dereference, typeKind: value.kind})
        self.view(value.refValue, expression, "_", path, depth, value.address & " ->")
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
          children.add((j("[" & $i & "]"), element))

        if children.len == 0:
          atom = "value-expanded-atom-parent"

        self.expandedCompoundView(value, expression, children, path, left, right, depth)
      else:
        self.atomValueView($value.textRepr, expression, "seq", value)

    of Variant:
      if self.uiExpanded(value, expression):
        var children: seq[(cstring, Value)] = @[]

        if not value.activeVariantValue.isNil:
          children.add((value.activeVariantValue.typ.langType, value.activeVariantValue))
        else:
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
        text j"bug in proc view -> value.nim"

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

  #         kxiMap[j"stateComponent-" & j($self.stateID)].afterRedraws.add(proc =
  #           discard windowSetTimeout(proc =
  #             jq(j".value-name-selected").focus(), 50)
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

  #         kxiMap[j"stateComponent-" & j($self.stateID)].afterRedraws.add(proc =
  #           discard windowSetTimeout(proc =
  #             jq(j".value-name-selected").focus(), 50)
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

  var isWatch = if value.isWatch: j"value-watch" else: j""
  var isSelected = if self.selected: j"value-selected" else: j""
  # var nameSelected = if self.selected: j"value-name-selected" else: j""
  var fresh = if self.fresh: j("value-fresh-" & $self.freshIndex) else: j""

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

  #       result = chart.render()
  #       chart.ensure()
  #     else:
  #       result = nil
  #   else:
  #     raise newException(ValueError, "chart not in right context")

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
    self.redraw()

  let cPath = path

  self.isOperationRunning = false

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
              # TODO: Figure out a way to open panel if closed
              # The logic for opening should be in the middleware later on
              # openValueInScratchpad((expression, value))
              self.api.emit(InternalAddToScratchpad, ValueWithExpression(expression: expression, value: value))
              self.redraw()
          ):
            tdiv(class = "custom-tooltip"):
              text "Add to scratchpad"
        span(
          class = "value-expand-button " & fresh,
          onmousedown = proc(ev: Event, v: VNode) =
            self.data.focusComponent(self)
            ev.stopPropagation()
            capture expression, value, cPath:
              discard self.expandNewValues(value, cPath)
              discard self.toggleExpanded(value, expression)
        ):
          if compoundOrPointsToCompound(value):
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
            span(
              class = if self.showInline[expression]: "toggle-value-history active" else: "toggle-value-history",
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
        span(
          class = if self.showInline[expression]: "toggle-value-history active" else: "toggle-value-history",
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

method render*(self: ValueComponent): VNode =
  var path: seq[SubPath] = @[]

  path.add(SubPath{kind: Expression, expression: self.baseExpression, typeKind: self.baseValue.kind})
  result = self.view(self.baseValue, self.baseExpression, self.baseExpression, path, depth=0)

method redraw*(self: ValueComponent) =
  if not self.state.isNil:
    self.state.redraw()
  else:
    procCall Component(self).redraw()
