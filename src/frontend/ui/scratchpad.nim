import
  ui_imports,
  ../[ types, communication ],
  ../../common/ct_event

when defined(ctInExtension):
  var scratchpadComponentForExtension* {.exportc.}: ScratchpadComponent = makeScratchpadComponent(data, 0, inExtension = true)

  proc makeScratchpadComponentForExtension*(id: cstring): ScratchpadComponent {.exportc.} =
    if scratchpadComponentForExtension.kxi.isNil:
      scratchpadComponentForExtension.kxi = setRenderer(proc: VNode = scratchpadComponentForExtension.render(), id, proc = discard)
    result = scratchpadComponentForExtension

proc removeValue*(self: ScratchpadComponent, i: int) =
  self.programValues.delete(i, i)
  self.values.delete(i, i)
  self.redraw()

proc registerLocals*(self: ScratchpadComponent, response: CtLoadLocalsResponseBody) =
  self.locals = response.locals

proc registerValue(self: ScratchpadComponent, variable: ValueWithExpression) =
  let value = variable.value
  let expression = variable.expression
  self.programValues.add((expression, value))
  self.values.add(
    ValueComponent(
      expanded: JsAssoc[cstring, bool]{},
      charts: JsAssoc[cstring, ChartComponent]{},
      showInline: JsAssoc[cstring, bool]{},
      baseExpression: expression,
      baseValue: value,
      nameWidth: VALUE_COMPONENT_NAME_WIDTH,
      valueWidth: VALUE_COMPONENT_VALUE_WIDTH,
      stateID: -1
    )
  )
  self.redraw()

method register*(self: ScratchpadComponent, api: MediatorWithSubscribers) =
  self.api = api
  api.subscribe(InternalAddToScratchpad, proc(kind: CtEventKind, response: ValueWithExpression, sub: Subscriber) =
    self.registerValue(response)
  )
  api.subscribe(InternalAddToScratchpadFromExpression, proc(kind: CtEventKind, response: cstring, sub: Subscriber) =
    var found: Variable
    var foundIt = false

    for v in self.locals:
      if v.expression == response:
        found = v
        foundIt = true
        break

    if foundIt:
      self.registerValue(ValueWithExpression(expression: found.expression, value: found.value))
    else:
      echo "Variable not found."
  )
  api.subscribe(CtLoadLocalsResponse, proc(kind: CtEventKind, response: CtLoadLocalsResponseBody, sub: Subscriber) =
    self.registerLocals(response)
  )

proc scratchpadValueView(self: ScratchpadComponent, i: int, value: ValueComponent): VNode =
  value.isScratchpadValue = true
  proc renderFunction(value: ValueComponent): VNode =
    result = buildHtml(tdiv(class = "scratchpad-value-view")):
      button(
        class = "scratchpad-value-close",
        onclick = proc =
          self.removeValue(i)
      )
      render(value)

  renderFunction(value)

method render*(self: ScratchpadComponent): VNode =

  buildHtml(
    tdiv(id = "values", class = componentContainerClass("active-state"))):
      tdiv(class = "value-components-container"):
        if self.values.len() > 0:
          for i, value in self.values:
            scratchpadValueView(self, i, value)
        else:
          tdiv(class = "empty-overlay"):
            text "You can add values from other components by right clicking on them and then click on 'Add value to scratchpad'."
