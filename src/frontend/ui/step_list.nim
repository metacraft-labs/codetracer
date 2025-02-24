import ui_imports, value, ../utils

const STEP_LINE_HEIGHT_PX = 26

proc panelHeight*(self: StepListComponent): int =
  cast[int](jq("#stepListComponent").offsetHeight) div STEP_LINE_HEIGHT_PX

method onUpdatedLoadStepLines*(self: StepListComponent, stepLinesUpdate: LoadStepLinesUpdate) {.async.} =
  self.lineSteps = self.lineSteps.concat(stepLinesUpdate.results)
  sort(self.lineSteps, func (x, y: LineStep): int = cmp(x.delta, y.delta))

  redraw(kxiMap[cstring(fmt"step-list-{self.id}")])


proc loadStepLinesFor*(self: StepListComponent, location: types.Location) =
  self.lineSteps = @[]
  let count = self.panelHeight()

  self.service.loadStepLines(location, count)

method onCompleteMove*(self: StepListComponent, response: MoveState) {.async.} =
  self.loadStepLinesFor(response.location)

proc lineStepLineView(self: StepListComponent, lineStep: LineStep): VNode =
  let isCurrentStepLine = self.data.services.debugger.location.rrTicks == lineStep.location.rrTicks and
    self.data.services.debugger.location.path == lineStep.location.path and
    self.data.services.debugger.location.line == lineStep.location.line
  let activeClass = if isCurrentStepLine:
      "active-step-line"
    else:
      ""
  let preClasses = if isCurrentStepLine:
      "active-step-line-pre step-line-pre"
    else:
      "inactive-step-line-pre step-line-pre"

  buildHtml(
    tdiv(
      class = fmt"step-line {activeClass}",
      onclick = proc =
        let onOriginalLocation = self.data.services.debugger.location.rrTicks == lineStep.location.rrTicks and
            self.data.services.debugger.location.path == lineStep.location.path and
            self.data.services.debugger.location.line == lineStep.location.line
        if true:
          self.data.services.debugger.lineStepJump(lineStep)
        else:
          cwarn "moved to a different location: not jumping, we want to jump only from the original one"
    )
  ):
    span(class = "step-line-column step-line-delta"):
      text $lineStep.delta
    span(class = "step-line-column step-line-location"):
      let filename = ($lineStep.location.path).extractFilename
      text fmt"{filename}:{lineStep.location.line}[{lineStep.location.functionName}]"
    span(class = "step-line-column step-line-source-code"):
      pre(class = preClasses):
        code:
          text lineStep.sourceLine
    span(class = "step-line-column step-line-flow-values"):
      for stepFlowValue in lineStep.values:
        span(class = "step-line-flow-value"):
          span(class = "step-line-flow-value-expression"):
            text stepFlowValue.expression
          span(class = "step-line-flow-value-repr"):
            text stepFlowValue.value.textRepr

proc lineStepCallView(self: StepListComponent, lineStep: LineStep): VNode =
  buildHtml(
    tdiv(class = "step-line step-line-call")
  ):
    span(class = "step-line-description step-line-call-description"):
      text lineStep.sourceLine
    span(class = "step-line-args"):
      for arg in lineStep.values:
        span(class = "step-line-value"):
          span(class = "step-line-value-expression"):
            text arg.expression
          span(class = "step-line-value-repr"):
            text arg.value.textRepr

proc lineStepReturnView(self: StepListComponent, lineStep: LineStep): VNode =
  buildHtml(
    tdiv(class = "step-line step-line-return")
  ):
    span(class = "step-line-description step-line-return-description"):
      text lineStep.sourceLine
    if lineStep.values.len > 0:
      span(class = "step-line-return-value"):
        span(class = "step-line-return-value-expression"):
          text lineStep.values[0].expression
        span(class = "step-line-return-value-repr"):
          text lineStep.values[0].value.textRepr

proc lineStepView(self: StepListComponent, lineStep: LineStep): VNode =
  case lineStep.kind:
  of LineStepKind.Line:
    self.lineStepLineView(lineStep)

  of LineStepKind.Call:
    self.lineStepCallView(lineStep)

  of LineStepKind.Return:
    self.lineStepReturnView(lineStep)

method render*(self: StepListComponent): VNode =
  buildHtml(
    tdiv(class = "step-list")
  ):
    tdiv(class = "step-list-lines-box"):
      tdiv(class = "step-lines"):
        for lineStep in self.lineSteps:
          lineStepView(self, lineStep)
