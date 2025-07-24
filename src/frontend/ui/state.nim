import
  ../ui_helpers,
  ui_imports,
  show_code,
  value,
  .. / communication, 
  .. / .. / common / ct_event

from std / dom import nil # imports dom, without directly its items: you need to use `dom.Node`

# let MIN_NAME_WIDTH: float = 15 #%
# let MAX_NAME_WIDTH: float = 85 #%
# let TOTAL_VALUE_COMPONENT_WIDTH: float = 95 #%

proc calculateValueWidth(self: StateComponent):float = self.totalValueWidth - self.nameWidth
# proc watchView(self: StateComponent): VNode
# proc headerView(self: StateComponent): VNode
proc excerpt(self: StateComponent): VNode
proc redraw*(self: StateComponent)


method restart*(self: StateComponent) =
  discard

var stateComponentForExtension* {.exportc.}: StateComponent = makeStateComponent(data, 0, inExtension = true)

proc makeStateComponentForExtension*(id: cstring): StateComponent {.exportc.} =
  if stateComponentForExtension.kxi.isNil:
    stateComponentForExtension.kxi = setRenderer(proc: VNode = stateComponentForExtension.render(), id, proc = discard)
  result = stateComponentForExtension

proc registerLocals*(self: StateComponent, response: CtLoadLocalsResponseBody) {.exportc.} =
  clog fmt"registerLocals"
  self.locals = response.locals
  for localVariable in response.locals:
    let expression = localVariable.expression

    if self.values.hasKey(expression):
      let value = self.values[expression]

      for chart in value.charts:
        chart.replaceAllValues(expression, localVariable.value.elements)
  self.completeMoveIndex += 1
  self.redraw()



proc redrawDynamically*(self: StateComponent) =
  let vdom = self.render()
  let newDom = vnodeToDom(vdom, KaraxInstance())

  # console.log "new vdom, dom ", vdom, newDom

  let idSelector = cstring(fmt"#stateComponent-{self.id}")
  var node = cast[Node](kdom.document.querySelector(idSelector)).parentNode # value-components-container"))
  if node.childNodes.len > 0:
    node.removeChild(node.childNodes[0])
  # console.log("old ", node)
  node.appendChild(newDom)
  # console.log("new ", node)

proc redraw*(self: StateComponent) =
  if self.inExtension:
    self.redrawForExtension()
  else:
    self.redrawDynamically()
  # should be working.. but for now workaround with redrawDynamically
  # if not self.kxi.isNil:
    # self.kxi.redraw()


method onMove(self: StateComponent) {.async.} =
  # TODO: fixing rr ticks
  # self.rrTicks = response.location.rrTicks
  let countBudget = 3000
  let minCountLimit = 50
  let arguments = CtLoadLocalsArguments(
    rrTicks: self.rrTicks,
    countBudget: countBudget,
    minCountLimit: minCountLimit,
  )
  self.api.emit(CtLoadLocals, arguments)
  self.redraw()

  
method register*(self: StateComponent, api: MediatorWithSubscribers) =
  self.api = api
  # api.subscribe(DapStopped, proc(kind: CtEventKind, response: DapStoppedEvent, sub: Subscriber) =
    # discard self.onMove())
  api.subscribe(CtCompleteMove, proc(kind: CtEventKind, response: MoveState, sub: Subscriber) =
    discard self.onCompleteMove(response)
  )
  api.subscribe(CtLoadLocalsResponse, proc(kind: CtEventKind, response: CtLoadLocalsResponseBody, sub: Subscriber) =
    self.registerLocals(response)
  )

# think if it's possible to directly exportc in this way the method
proc registerStateComponent*(component: StateComponent, api: MediatorWithSubscribers) {.exportc.} =
  component.register(api)

method render*(self: StateComponent): VNode =
  # render using value components
  # most of the stuff is separated into  watches and normal local values
  # the watch functionality has a search form and editable names
  let klass = "active-state"

  for localVariable in self.locals:
    let name = localVariable.expression

    if not self.values.hasKey(name):
      self.values[name] = ValueComponent(
        expanded: JsAssoc[cstring, bool]{},
        charts: JsAssoc[cstring, ChartComponent]{},
        state: self,
        # history: JsAssoc[cstring, seq[HistoryResult]]{},
        showInline: JsAssoc[cstring, bool]{},
        baseExpression: name,
        service: self.data.services.history,
        stateID: self.id,
        id: self.values.len,
        data: self.data,
        nameWidth: self.nameWidth,
        valueWidth: self.calculateValueWidth(),
        location: self.location,
        api: self.api
      )
      registerValueComponent(self.values[name], self.api)
    elif self.valueHistory.hasKey(name):
      checkHistoryLocation(self.values[name], name)

  try:
    proc renderFunction(value: ValueComponent): VNode =
      value.nameWidth = self.nameWidth
      value.valueWidth = self.calculateValueWidth()
      value.render()

    var initialPosition: float

    proc resizeColumns(ev: Event, tg:VNode) =
      let mouseEvent = cast[MouseEvent](ev) 
      let containerWidth = jq(".active-state #chevron-container").offsetWidth.toJs.to(float)
      let currentPosition = mouseEvent.screenX.toJs.to(float) 
      let movementX = (currentPosition-initialPosition) * 100 / containerWidth
      let newPosition = self.nameWidth + movementX

      if newPosition >= self.minNameWidth and newPosition < self.maxNameWidth:
        self.nameWidth = max(newPosition, self.minNameWidth)
        self.data.redraw()
        initialPosition = currentPosition

    result = buildHtml(
      tdiv(id = cstring(fmt"stateComponent-{self.id}"),
        class = componentContainerClass(klass) & cstring" " & cstring"state-component",
        onclick = proc(ev: Event, tg: VNode) =
          self.chevronClicked = false
          ev.preventDefault(),
        # onmousemove = proc(ev: Event, tg:VNode) =
        #   if self.chevronClicked:
        #     resizeColumns(ev,tg),
        # onmousedown = proc(ev: Event, tg:VNode) =
        #   if self.chevronClicked:
        #     initialPosition = cast[MouseEvent](ev).screenX.toJs.to(float), 
        onmouseup = proc =
          self.chevronClicked = false,
        onmouseleave = proc = self.chevronClicked = false
      )
    ):
      excerpt(self)
      # watchView(self) # TODO: Add later on

      tdiv(class = "value-components-container"):
        if (not self.service.stableBusy or delta(now(), self.data.ui.lastRedraw) < 1_000) or self.inExtension:
          self.i = 0
          let localsList = if self.inExtension: self.locals else: self.service.locals
          for variable in localsList:
            let name = variable.expression
            let value = variable.value
            if value.isNil:
              continue
            # var realValue = readValue(cast[uint](value))
            if self.values[name].baseValue.isNil or self.values[name].baseValue.kind != value.kind:
              self.values[name].fresh = true
              self.values[name].freshIndex = self.values[name].freshIndex + 1
            else:
              self.values[name].fresh = false
            self.values[name].baseValue = value
            self.values[name].i = self.i
            renderFunction(self.values[name])
  except:
    echo getCurrentExceptionMsg()

# Show the current active debugger line on top of the search bar in the state component
proc excerpt(self: StateComponent): VNode =
  let path = data.services.debugger.location.path
  let id = cstring(fmt"code-state-line-{self.id}")

  if data.ui.editors.hasKey(path):
    let editor = data.ui.editors[path]
    let codeLine = data.services.debugger.location.line
    let sourceCode = editor.tabInfo.sourceLines[codeLine - 1]

    result = buildHtml(
      tdiv(
        id = id,
        class = "code-state-line"
      )
    ):
      span(): text cstring(fmt"{codeLine} | {sourceCode}")
      showCode(id, path, codeLine-3, codeLine+5, codeLine)
  else:
    result = buildHtml(
      tdiv(
        id = id,
        class = "code-state-line no-code"
      )
    ):
      span(): text ""

# proc headerView(self: StateComponent): VNode =
#   result = buildHtml(
#     tdiv(
#       id = "chevron-container"
#     )
#   ):
#     span(
#       class = cstring(fmt"chevron chevron-width-{(self.nameWidth * 100).floor.int}"),
#       style = style(StyleAttr.left, cstring(fmt"{self.nameWidth}%")),
#       onmousedown = proc(ev:Event, tg:VNode) =
#       self.chevronClicked = true,
#       onmouseup = proc =
#       self.chevronClicked = false
#     )

# proc watchView(self: StateComponent): VNode =
#   result = buildHtml(
#     tdiv(id = "gdb-evaluate")
#   ):
#     form(
#       onsubmit = proc(ev: Event, v: VNode) =
#       ev.stopPropagation()
#       ev.preventDefault()

#       if not self.service.stableBusy:
#         var e = jq("#watch").toJs.value.to(cstring)

#         if ($e).find("\n") != NO_INDEX:
#           errorMessage(cstring"newlines forbidden in watch expressions: not registered")
#         else:
#           self.watchExpressions.add(e)
#           self.data.services.debugger.watchExpressions.add(e)
#           discard self.data.services.debugger.updateWatches(proc(service: DebuggerService, locals: seq[Variable]) =
#             self.locals = locals
#             service.locals = locals
#             self.data.redraw())
#           jq("#watch").toJs.value = j"",
#       onmousemove = proc(ev: Event, tg:VNode) = ev.stopPropagation(),
#       onclick = proc(ev: Event, tg:VNode) = ev.stopPropagation()
#     ):
#       input(`type`="text", placeholder="Enter a watch expression", id="watch")

  
method onCompleteMove*(self: StateComponent, response: MoveState) {.async.} =
  self.location = response.location
  for value in self.values:
    value.location = response.location
  await self.onMove()
