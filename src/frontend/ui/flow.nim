import
  ../ui_helpers, ui_imports,
  ../renderer, value, scratchpad

import strutils, os

# thank, God!

proc resizeLineSlider(self: FlowComponent, position: int)
proc shrinkLoopIterations*(self: FlowComponent, loopIndex: int)
proc createLoopViewZones(self: FlowComponent, loopIndex:int)
proc createFlowViewZone(self: FlowComponent, position: int, heightInPx: float, isLoop: bool = false): Node
proc calculateLineIndentations(self: FlowComponent, position: int): int
proc positionRRTicksToStepCount*(self: FlowComponent, position: int, rrTicks: int): int
proc updateIterationStepCount*(self: FlowComponent, line: int, stepCount: int, loopId: int, iteration: int): int
proc reloadFlow*(self:FlowComponent)
proc addStepValues*(self: FlowComponent, step: FlowStep)
proc addComplexLoopStepValues(self: FlowComponent, step: FlowStep)
proc addMultilineLoopStep(self: FlowComponent, step: FlowStep, container: Node)
proc redrawFlow*(self: FlowComponent)
proc resizeFlowSlider*(self: FlowComponent)
proc makeSlider(self: FlowComponent, position: int)
proc updateFlowOnMove*(self: FlowComponent, rrTicks: int, line: int)

const SLIDER_OFFSET = 6 # in px

proc getFlowValueMode(self: FlowComponent, beforeValue: Value, afterValue: Value): ValueMode =
  if testEq(beforeValue, afterValue):
    return BeforeValueMode
  else:
    if afterValue.isNil and not beforeValue.isNil:
      return BeforeValueMode
    elif beforeValue.isNil and not afterValue.isNil:
      return AfterValueMode
    else:
      return BeforeAndAfterValueMode

proc getStepDomOffsetLeft*(self: FlowComponent, step: FlowStep): float =
  let flowLine = self.flowLines[step.position]
  let loopState = self.loopStates[step.loop]
  var valueContainerOffset =
    loopState.containerOffset +
    flowLine.offsetLeft +
    loopState.sumOfPreviousIterations[step.iteration]

  if loopState.viewState != LoopContinuous:
    valueContainerOffset += (step.iteration*self.distanceBetweenValues).float

  return valueContainerOffset

proc stepIterationIsActive(self: FlowComponent, step: FlowStep): bool =
  return step.iteration == self.flowLines[step.position].activeLoopIteration.iteration and
    step.loop == self.flowLines[step.position].activeLoopIteration.loopIndex

proc calculateLoopContainerWidth(self: FlowComponent, loopIndex: int): float =
  var sum: float

  if self.flow.loops[loopIndex].base == -1:
    for value in toSeq(self.loopStates[loopIndex].iterationsWidth.items()):
      sum += value + self.distanceBetweenValues.float
  else:
    let parentLoopState = self.loopStates[self.flow.loops[loopIndex].base]
    let parentIteration = self.flow.loops[loopIndex].baseIteration
    let parentIterationWidth = parentLoopState.iterationsWidth[parentIteration]

    sum = parentIterationWidth + self.distanceBetweenValues.float

  return sum

proc getSourceLineDomIndex(self:FlowComponent, position: int): int =
  var result: int
  let editorId = self.editorUI.id
  let overlayNodes = jq(&"#editorComponent-{editorId} .monaco-editor .view-overlays").children
  let marginOverlayNodes = jq(&"#editorComponent-{editorId} .monaco-editor .margin-view-overlays").children

  for index, overlayNode in marginOverlayNodes:
    let gutter = findNodeInElement(cast[Node](overlayNode),".gutter")
    let dataLine = cast[cstring](gutter.getAttribute("data-line"))
    if cast[int](dataLine) == position:
      result = index
      break

  return result

proc hasAttribute(node: Node, attrName: cstring): bool =
  var result = false

  for attr in node.attributes:
    if attr.nodeName == attrName:
      result = true
      break

  return result

iterator loopPositionsChildren(self: FlowComponent, loopIndex: int): tuple[iteration: int, child: Node] =
  for position in self.flow.loops[loopIndex].first..<self.flow.loops[loopIndex].last:
    let childNodes = self.flowDom[position].childNodes
    var iteration = 0

    for i in 0..<childNodes.len:
      if childNodes[i].hasAttribute("class"):
        let childClass = $(childNodes[i].getAttribute(cstring"class"))

        if childClass.contains("flow-loop-value-single"):
          yield (iteration: iteration, child: childNodes[i])
          iteration += 1

proc makeLoopState(): LoopState = 
  LoopState(
    positions: JsAssoc[int, LoopPosition]{},
    iterationsWidth: JsAssoc[int, float]{},
    sumOfPreviousIterations: JsAssoc[int, float]{},
    containerDoms: JsAssoc[int, Node]{},
    minWidth: 72,
    maxWidth: 270,
    focused: false
  )

proc stepValueIsVisible(self: FlowComponent, step: FlowStep): bool =
  let flowLine = self.flowLines[step.position]
  let loopState = self.loopStates[step.loop]
  var valueContainerOffset =
    loopState.containerOffset +
    flowLine.offsetLeft +
    loopState.sumOfPreviousIterations[step.iteration]

  if loopState.viewState != LoopContinuous:
    valueContainerOffset += (step.iteration*self.distanceBetweenValues).float

  return valueContainerOffset + loopState.iterationsWidth[step.iteration] >
    flowLine.baseOffsetLeft.float or
    valueContainerOffset <
    self.editorUI.monacoEditor.config.layoutInfo.minimapLeft.float -
    self.editorUI.monacoEditor.config.layoutInfo.contentLeft.float

proc getStepMaxValueWidth(self: FlowComponent, step: FlowStep): int =
  var maxValueWidth = 0

  for expression, value in step.beforeValues:
    let valueWidth = value.textRepr(compact=true).len * self.pixelsPerSymbol
    if valueWidth > maxValueWidth:
      maxValueWidth = valueWidth

  return maxValueWidth

proc stepValueIndentation(
  self: FlowComponent,
  step: FlowStep,
  value: Value,
  container: kdom.Node
): float =
  let valueTextWidth = value.textRepr(compact=true).len*self.pixelsPerSymbol
  let monacoLayout = self.editorUI.monacoEditor.config.layoutInfo
  let flowViewStart = self.flowLines[step.position].baseOffsetLeft.float
  let flowViewEnd = monacoLayout.contentWidth.float
  var stepContainerWidth = container.toJs.clientWidth.to(float)
  let stepOffset = container.parentNode.toJs.offsetLeft.to(float) +
    self.getStepDomOffsetLeft(step)
  let stepCenterOffset =
    stepOffset + stepContainerWidth / 2
  let stepEndOffset =
    stepOffset + stepContainerWidth
  let stepValueStartOffset = stepCenterOffset - valueTextWidth.float / 2
  var valueTextIndent: float = 0

  if stepOffset <= flowViewStart and stepEndOffset >= flowViewEnd:
    valueTextIndent = flowViewStart -
      stepOffset + self.flowViewWidth.float / 2 - valueTextWidth.float / 2
  elif stepOffset > flowViewStart and stepValueStartOffset >= flowViewEnd:
    valueTextIndent = (flowViewEnd - stepOffset) / 2 - valueTextWidth.float / 2
  elif stepOffset < flowViewStart and stepEndOffset < flowViewEnd:
    var minIndent = flowViewStart - stepOffset
    valueTextIndent = minIndent + (stepEndOffset - flowViewStart) / 2 - valueTextWidth.float / 2
    if valueTextIndent < minIndent:
      valueTextIndent = minIndent
  else:
    valueTextIndent = 0

  return valueTextIndent


proc loopStepContainerStyle(self: FlowComponent, step: FlowStep): VStyle =
  let loopState = self.loopStates[step.loop]
  let containerWidth = loopState.iterationsWidth[step.iteration]
  var containerLeft = loopState.sumOfPreviousIterations[step.iteration]

  if loopState.viewState != LoopContinuous:
    containerLeft += (step.iteration*self.distanceBetweenValues).float

  style(
    (StyleAttr.width, cstring($(containerWidth) & "px")),
    (StyleAttr.left, cstring($(containerLeft) & "px"))
  )

proc complexValueStyle(self: FlowComponent, step: FlowStep, expression: cstring): VStyle =
  let valueWidth = 
    self.loopStates[step.loop]
      .positions[step.position]
      .positionColumns[step.iteration]
      .valuesExpressions[expression]
      .valuePercent

  style((StyleAttr.width, cstring($valueWidth & "%")))

proc legendValueStyle(self: FlowComponent, step: FlowStep, expression: cstring): VStyle =
  let valueWidth =
    self.loopStates[step.loop]
      .positions[step.position]
      .positionColumns[step.iteration]
      .valuesExpressions[expression]
      .expressionLegendPercent

  style((StyleAttr.width, cstring($valueWidth & "%")))

proc flowLoopPositionStyle(self: FlowComponent, step: FlowStep): VStyle =
  let columnWidth = self.loopStates[step.loop].defaultIterationWidth

  style(StyleAttr.width, cstring($columnWidth & "px"))

proc calculateLoopSliderWidth*(self: FlowComponent, leftValue: int = 0) : int =
  let editor = self.editorUI.monacoEditor
  let editorLayout = editor.config.layoutInfo
  let editorWidth = editorLayout.width
  let contentLeft = editorLayout.contentLeft
  let minimapWidth = editorLayout.minimapWidth

  return editorWidth - minimapWidth - contentLeft - leftValue

proc prepareBackgroundStyleProps(self: FlowComponent, loopIndex: int): FlowLoopBackgroundStyleProps =
  let loop = self.flow.loops[loopIndex]
  let lineHeight = self.editorUI.monacoEditor.config.lineHeight
  let minimapLeft = self.editorUI.monacoEditor.config.layoutInfo.minimapLeft
  let contentLeft = self.editorUI.monacoEditor.config.layoutInfo.contentLeft
  let leftValue = self.maxFlowLineWidth + self.distanceToSource - self.distanceBetweenValues
  let topValue = (-1)*lineHeight
  let widthValue = minimapLeft - contentLeft - leftValue
  let viewZonesCount = toSeq(self.viewZones.keys()).filterIt(it >= loop.first and it <= loop.last).len
  let heightValue = (loop.last.float - loop.first.float + viewZonesCount.float + 1.5)*lineHeight.float

  return FlowLoopBackgroundStyleProps(
    left: leftValue,
    top: topValue,
    width: widthValue,
    height: heightValue
  )

proc flowLoopBackgroundStyle(self: FlowComponent, loopIndex: int): VStyle =
  let propValues = self.prepareBackgroundStyleProps(loopIndex)
  style(
    (StyleAttr.left, cstring($(propValues.left) & "px")),
    (StyleAttr.top, cstring($(propValues.top) & "px")),
    (StyleAttr.width, cstring($(propValues.width) & "px")),
    (StyleAttr.height, cstring($(propValues.height) & "px"))
  )

proc loopSliderStyle(self: FlowComponent, position: int): VStyle =
  var leftValue = cast[Element](self.flowLoops[position].flowDom).clientWidth
  var widthValue = cstring "0px"

  if leftValue != 0:
    widthValue = cstring(fmt"{calculateLoopSliderWidth(self, leftValue)}px")
  else:
    self.shouldRecalcFlow = true

  style(
    (StyleAttr.width, fmt"calc({widthValue} - {SLIDER_OFFSET}ch)".cstring),
    (StyleAttr.fontSize, cstring($data.ui.fontSize)),
    (StyleAttr.fontFamily, cstring"SpaceGrotesk"),
    (StyleAttr.marginLeft, cstring("4ch")),
    (StyleAttr.height, cstring($self.lineHeight & "px")),
    (StyleAttr.lineHeight, cstring($self.lineHeight & "px"))
  )

proc flowLoopLegendStyle(self: FlowComponent, loopIndex: int): VStyle =
  let legendWidth = self.loopStates[loopIndex].legendWidth
  let leftValue = self.maxFlowLineWidth + self.distanceToSource

  style(
    (StyleAttr.left, cstring($leftValue & "px")),
    (StyleAttr.width, cstring($legendWidth & "px"))
  )

proc flowLeftStyle(self: FlowComponent, line: int = 0, isSlider: bool = false): VStyle =
  let tabInfo = self.editorUI.tabInfo
  let column = self.editorUI.monacoEditor.getModel().getLineMaxColumn(line)
  let editorContentLeft = self.editorUI.monacoEditor.config.layoutInfo.contentLeft

  if isSlider:
    let flowDomWidth = self.flowLoops[line].flowDom.toJs.clientWidth

    style(
      (StyleAttr.left, cstring(fmt"calc({flowDomWidth}px - 2ch)")),
      (StyleAttr.fontSize, cstring($data.ui.fontSize & "px"))
    )
  else:
    let textModel = self.editorUI.monacoEditor.getModel()
    let lineContent = textModel.getLineContent(line)

    style(
      (StyleAttr.left, cstring(fmt"calc({lineContent.len()}ch + 1ch)")),
      (StyleAttr.fontSize, cstring($data.ui.fontSize & "px"))
    )

proc calculateMaxFlowLineWidth*(self: FlowComponent): int =
  var length:int = 0

  if self.tab.isNil:
    cwarn "flow: tab is nil"
    return

  var positions: seq[int]

  if self.flow.isNil:
    for position in self.location.functionFirst + 1 .. self.location.functionLast:
      positions.add(position)
  else:
    var i = 0
    for position, stepCounts in self.flow.positionStepCounts:
      if i > 0 or position > self.location.functionFirst:
        positions.add(position)
      i += 1

  let monaco = self.editorUI.monacoEditor

  for position in positions:
    try:
      let positionMaxColumn = monaco.getModel().getLineMaxColumn(position)
      let sourceLength = monaco.getOffsetForColumn(position, positionMaxColumn)

      if length < sourceLength:
        length = sourceLength
    except:
      cerror "flow: calculate max flow line width: " & getCurrentExceptionMsg()

  return length

type
  TokenState* = enum TAny, TExpression, TString

var emptyKeywords = JsAssoc[cstring, bool]{}
let KEYWORDS: array[Lang, JsAssoc[cstring, bool]] = [
  emptyKeywords,
  emptyKeywords,
  emptyKeywords,
  JsAssoc[cstring, bool]{j"func": true, j"proc": true, j"int": true, j"seq": true, j"for": true, j"in": true, j"var": true},
  emptyKeywords,
  emptyKeywords,
  emptyKeywords,
  emptyKeywords,
  emptyKeywords,
  emptyKeywords,
  emptyKeywords,
  emptyKeywords,
  emptyKeywords,
  emptyKeywords,
  emptyKeywords
]

func isSymbol(c: char, lang: Lang): bool =
  if lang == LangNim:
    c.isAlphaAscii or c == '_'
  else:
    false

func isStringSymbol(c: char, lang: Lang): bool =
  if lang == LangNim:
    c == '"'
  else:
    false

func tokenizeExpressions*(source: cstring, lang: Lang): seq[(cstring, int)] =
  result = @[]
  var state: TokenState
  var token = j""

  for i in 0 ..< source.len:
    let c = source[i]
    if c.isSymbol(lang):
      case state:
      of TAny:
        state = TExpression
        token = cstring($c)
        result.add((j"", i))
      of TExpression:
        token = token & cstring($c)
      else:
        discard
    # Faith
    elif c.isStringSymbol(lang):
      case state:
      of TExpression:
        {.noSideEffect.}:
          if not KEYWORDS[lang].hasKey(token):
            result[^1] = (token, result[^1][1])
          else:
            discard result.pop
        token = j""
        state = TString

      of TAny:
        state = TString

      of TString:
        state = TAny
    else:
      case state:
      of TExpression:
        {.noSideEffect.}:
          if not KEYWORDS[lang].hasKey(token):
            result[^1] = (token, result[^1][1])
          else:
            discard result.pop
        token = j""
        state = TAny

      else:
        discard

  case state:
  of TExpression:
    {.noSideEffect.}:
      if not KEYWORDS[lang].hasKey(token):
        result[^1] = (token, result[^1][1])
      else:
        discard result.pop

  else:
    discard

  var res = result
  result = @[]
  for i in countdown(res.len - 1, 0):
    result.add(res[i])

proc removeExpandedFlow(self: FlowComponent, line: int) =
  if self.multilineZones.hasKey(line):
    self.editorUI.monacoEditor.changeViewZones do (view: js):
      view.removeZone(self.multilineZones[line].zoneID)

  if self.multilineFlowLines.hasKey(line):
    discard jsDelete(self.multilineFlowLines[line])

proc openValue*(self: FlowComponent, stepCount: int, name: cstring, before: bool) =
  if not self.flow.isNil and stepCount in self.flow.steps.low .. self.flow.steps.high:
    let step = self.flow.steps[stepCount]
    if not self.scratchpadUI.isNil:
      if before:
        if name == cstring"":
          for valueName, value in step.beforeValues:
            self.scratchpadUI.registerScratchpadValue(valueName, value)
        else:
          if step.beforeValues.hasKey(name):
            self.scratchpadUI.registerScratchpadValue(name, step.beforeValues[name])

        self.data.redraw()

      else:
        if name == cstring"":
          for valueName, value in step.afterValues:
            self.scratchpadUI.registerScratchpadValue(valueName, value)
        else:
          if step.afterValues.hasKey(name):
            self.scratchpadUI.registerScratchpadValue(name, step.afterValues[name])

        self.data.redraw()

proc displayTooltip(self: FlowComponent, containerId: cstring, content: Node) =
  when not defined(server):
    let tippy = require("tippy.js")
    let followCursor = tippy.followCursor

    if not self.tippyElement.isNil:
      for tippy in self.tippyElement:
        tippy.destroy()
        self.tippyElement = nil

    if self.tippyElement.isNil:
      let obj = tippy(cstring(&"#{containerId}"), JsAssoc[cstring, JsObject]{
        allowHTML: cast[JsObject](true),
        followCursor: cast[JsObject](cstring"horizontal"),
        content: cast[JsObject](content),
        appendTo: cast[JsObject](document.body),
        plugins: cast[JsObject](@[followCursor]),
        interactive: cast[JsObject](true),
        theme: cast[JsObject](cstring"internal_default_light"),
      })

      self.tippyElement = obj
  else:
    cerror "flow: displayTooltip: tippy import not implemented for browser"

proc tooltipValueView(expression: cstring, value: cstring): Node =
  let vNode = buildHtml(
    tdiv(
      id = &"flow-tooltip-value-{expression}",
      class = "flow-tooltip-value"
    )
  ):
    text(&"{expression}: {value}")

  vnodeToDom(vNode, KaraxInstance())

proc tooltipStepInfo(step: FlowStep): Node =
  let vNode = buildHtml(
    tdiv(
      id = &"flow-tooltip-step-info-{step.stepCount}",
      class = &"flow-tooltip-step-info"
    )
  ):
    text(&"Iteration: {step.iteration}")

  vnodeToDom(vNode, KaraxInstance())

proc customRedraw(self: ValueComponent) =
  discard

proc openTooltip*(self: FlowComponent, containerId: cstring, value: Value) =
  let valueDom = vnodeToDom(self.modalValueComponent[containerId].render(), KaraxInstance())

  self.tooltipId = containerId
  self.displayTooltip(containerId, valueDom)

func ensureTokens(self: FlowComponent, line: int) =
  if not self.editorUI.tokens.hasKey(line):
    self.editorUI.tokens[line] = JsAssoc[cstring, int]{}
    let tokens = tokenizeExpressions(self.tab.sourceLines[line - 1], self.data.trace.lang)

    for (token, left) in tokens:
      if not self.editorUI.tokens[line].hasKey(token):
        if line != self.data.services.debugger.location.functionFirst:
          self.editorUI.tokens[line][token] = left
        else:
          self.editorUI.tokens[line][token] = left - 1

const preloadLimit = 3
const LIMIT_WIDTH = 300.0

proc calculateLayout*(self: FlowComponent)

proc directRedraw(self: FlowComponent) =
  self.calculateLayout()

  for line, group in self.lineGroups:
    for loopID, widths in group.loopWidths:
      for i, width in widths:
        var widthStyle = cstring($(width  * group.baseWidth - 10) & "px")
        var element = jq(&"#flow-values-{line}-{loopID}-{i}")

        if not element.isNil:
          element.style.width = widthStyle
          element.toJs.classList.add(j"refresh")

proc focusLoopID(self: FlowComponent, stepCount: int) =
  if stepCount in self.flow.steps.low .. self.flow.steps.high:
    let step = self.flow.steps[stepCount]
    let loopID = step.loop
    let position = step.position
    var group = self.lineGroups[position]

    group.focusedLoopID = loopID
    group.element = nil

    self.makeSlider(position)
    self.directRedraw()

const OUT_LINE_RANGE = -2

proc findStepCount*(self: FlowComponent): int =
  var loop = self.flow.loops[self.selectedGroup.focusedLoopID]

  if self.flow.positionStepCounts.hasKey(loop.first):
    if loop.first in self.flow.steps.low .. self.flow.steps.high and self.selectedIndex in 0 .. self.flow.positionStepCounts[loop.first].high:
      var stepCount = self.flow.positionStepCounts[loop.first][self.selectedIndex]

      while true:
        let step = self.flow.steps[stepCount]

        if step.position == self.selectedLine:
          return stepCount
        elif step.position < loop.first or step.position > loop.last or stepCount >= self.flow.steps.len:
          break

        stepCount += 1

      return NO_STEP_COUNT

    return OUT_LINE_RANGE
  else:
    return OUT_LINE_RANGE

method select*(self: FlowComponent) {.async.} =
  if not self.selected and self.groups.len > 0:
      self.selected = true
      self.data.ui.activeFocus = self
      self.selectedGroup = self.groups[0]

      var loop = self.flow.loops[self.selectedGroup.focusedLoopID]
      var base = self.flow.loops[self.selectedGroup.baseID]

      self.selectedLine = loop.first
      self.selectedLineInGroup = self.selectedLine - base.first + 1
      self.selectedIndex = 0
      self.selectedStepCount = self.findStepCount()
  else:
    self.selected = false
    self.data.ui.activeFocus = self.editorUI
    self.selectedLine = -1
    self.selectedLineInGroup = -1
    self.selectedIndex = 0
    self.selectedStepCount = -1
    self.selectedGroup = nil

proc getOriginLoopIndex*(self: FlowComponent, loopIndex: int): int =
  var parentId = self.flow.loops[loopIndex].base

  if parentId == -1:
    return loopIndex
  else:
    self.getOriginLoopIndex(parentId)

proc calculateFlowLineLeftOffset(self:FlowComponent, flowLine: FlowLine): int =
  case self.data.config.realFlowUI:
  of FlowParallel, FlowInline:
    var flowLineOffset =
      self.maxFlowLineWidth +
      self.distanceToSource +
      self.distanceBetweenValues div 2

    flowLine.baseOffsetLeft = flowLineOffset

  of FlowMultiline:
    let editorContentLeft = self.editorUI.monacoEditor.config
      .layoutInfo.contentLeft

    flowLine.baseOffsetLeft = self.maxFlowLineWidth +
      self.distanceToSource +
      editorContentLeft

  return flowLine.baseOffsetLeft

proc prepareFlowLineContainerProps(self: FlowComponent, position: int): FlowLineContainerStyleProps =
  if self.flowLines[position].loopIds.len == 0:
    raise newException(ValueError, "There is not any loop at the given position.")

  let loopIndex = self.flowLines[position].loopIds[0]
  let monacoConfig = self.editorUI.monacoEditor.getConfiguration()
  let lineHeight = monacoConfig.lineHeight
  let minimapLeft = monacoConfig.layoutInfo.minimapLeft
  let contentLeft = monacoConfig.layoutInfo.contentLeft
  var containerHeight: int
  var containerWidth: int
  var leftValue: int

  case self.data.config.realFlowUI:
  of FlowParallel, FlowInline:
    leftValue = self.maxFlowLineWidth +
      self.distanceToSource +
      self.loopStates[loopIndex].legendWidth +
      self.distanceBetweenValues div 2
    containerHeight = lineHeight
    containerWidth =
      minimapLeft - contentLeft - leftValue - self.distanceBetweenValues

  of FlowMultiline:
    let editorContentLeft = monacoConfig.layoutInfo.contentLeft
    leftValue = self.maxFlowLineWidth +
      self.distanceToSource +
      editorContentLeft
    containerHeight = lineHeight*self.flowLines[position].sortedVariables.len
    containerWidth =
      minimapLeft - leftValue - self.distanceBetweenValues

  return FlowLineContainerStyleProps(
    left: leftValue,
    width: containerWidth,
    height: containerHeight
  )

proc setLoopContainerOffset(self: FlowComponent, loopIndex: int) =
  let baseLoopId = self.flow.loops[loopIndex].base
  let baseIteration = self.flow.loops[loopIndex].baseIteration

  if baseLoopId != -1:
    self.loopStates[loopIndex].containerOffset =
      self.loopStates[baseLoopId].sumOfPreviousIterations[baseIteration] +
      (self.distanceBetweenValues*baseIteration).float
  else:
    self.loopStates[loopIndex].containerOffset = 0

proc makeFlowLoopContainer(
  self: FlowComponent,
  position: int,
  loopIndex: int,
  nested: bool = false
): Node =
  let loop = self.flow.loops[loopIndex]
  var style: VStyle
  var containerId = &"flow-loop-container-{position}"
  var containerClass: cstring

  if nested:
    containerId = containerId & &"-{loopIndex}-{self.flow.loops[loopIndex].baseIteration}"
    let containerWidth = self.loopStates[loopIndex].totalLoopWidth
    containerClass = "flow-nested-loop-container"

    if position == self.flow.loops[loopIndex].first:
      setLoopContainerOffset(self, loopIndex)

    let flowLine = self.flowLines[position]
    let leftValue =
      self.loopStates[loopIndex].containerOffset - (flowLine.baseOffsetLeft.float - flowLine.offsetleft.float)

    style = style(
      (StyleAttr.width, cstring($containerWidth & "px")),
      (StyleAttr.left, cstring($leftValue & "px"))
    )
  else:
    let containerProps = self.prepareFlowLineContainerProps(position)

    style = style(
      (StyleAttr.left, cstring($(containerProps.left) & "px")),
      (StyleAttr.height, cstring($(containerProps.height) & "px")),
      (StyleAttr.width, cstring($(containerProps.width) & "px"))
    )

    containerClass = "flow-loop-container"

  let vNode = buildHtml(
    tdiv(
      id = containerId,
      class = containerClass,
      style = style
    )
  ):
    text ""

  return vnodeToDom(vNode, KaraxInstance())

proc ensureLoopContainer(self: FlowComponent, step: FlowStep, flowDom: Node): Node =
  var positionContainer = cast[Node](findNodeInElement(
    flowDom,
    cstring(&"#flow-loop-container-{step.position}")))

  if positionContainer.isNil:
    positionContainer = self.makeFlowLoopContainer(step.position, step.loop)
    self.flowLines[step.position].mainLoopContainer = positionContainer
    flowDom.appendChild(positionContainer)

  var container = cast[Node](findNodeInElement(
    positionContainer,
    cstring(&"#flow-loop-container-{step.position}-{step.loop}-{self.flow.loops[step.loop].baseIteration}")))

  if container.isNil:
    container = self.makeFlowLoopContainer(step.position, step.loop, nested = true)

  if self.flow.loops[step.loop].base == -1:
    if not self.flowLines[step.position].loopContainers.hasKey(step.loop):
      self.flowLines[step.position].loopContainers[step.loop] = container
  else:
    let parentIteration = self.flow.loops[step.loop].baseIteration

    self.flowLines[step.position].loopContainers[step.loop] = container

  self.loopStates[step.loop].containerDoms[step.position] = container
  positionContainer.appendChild(container)

  return container

proc stepContainerIsInViewRange(self: FlowComponent, step: FlowStep): bool =
  let flowLine = self.flowLines[step.position]
  let loopState = self.loopStates[step.loop]
  let viewRangeStart = self.flowLines[step.position].baseOffsetLeft.float -
    self.bufferMaxOffsetInPx.float
  let viewRangeEnd = self.editorUI.monacoEditor.config.layoutInfo.minimapLeft.float -
    self.editorUI.monacoEditor.config.layoutInfo.contentLeft.float +
    self.bufferMaxOffsetInPx.float
  let stepContainerOffset = self.getStepDomOffsetLeft(step)
  let stepContainerWidth = loopState.iterationsWidth[step.iteration]

  return stepContainerOffset < viewRangeEnd and
    stepContainerOffset + stepContainerWidth > viewRangeStart

proc loopContainerIsInViewRange(self: FlowComponent, loopIndex: int, position: int): bool =
  let flowLine = self.flowLines[position]
  (self.loopStates[loopIndex].containeroffset <
    self.editorUI.monacoEditor.config.layoutInfo.minimapLeft.float +
    self.bufferMaxOffsetInPx.float -
    self.editorUI.monacoEditor.config.layoutInfo.contentLeft.float -
    flowLine.offsetLeft.float -
    self.distanceBetweenValues.float) and (
      self.loopStates[loopIndex].containerOffset.float + self.loopStates[loopIndex].totalLoopWidth.float + flowLine.offsetLeft >
      flowLine.baseOffsetLeft.float - self.bufferMaxOffsetInPx.float
    )

proc clearStepContainer(self: FlowComponent, step: FlowStep) =
  let flowLine = self.flowLines[step.position]
  let loopState = self.loopStates[step.loop]

  flowLine.stepLoopCells[step.loop][step.iteration].toJs.remove()

  discard jsDelete(flowLine.stepLoopCells[step.loop][step.iteration])
  discard jsDelete(self.stepNodes[step.stepCount])

proc clarifyLoopContainerSteps(self: FlowComponent, loopIndex: int, position: int) =
  let flowLine = self.flowLines[position]

  for stepCount in flowLine.loopStepCounts[loopIndex]:
    let step = self.flow.steps[stepCount]
    if flowLine.steploopCells[loopIndex].hasKey(step.iteration):
      if not self.stepContainerIsInViewRange(step):
        self.clearStepContainer(step)
    else:
      if self.stepContainerIsInViewRange(step):
        self.addStepValues(step)

proc clearLoopContainer(self: FlowComponent, loopIndex: int, position: int) =
  let flowLine = self.flowLines[position]
  let loopState = self.loopStates[loopIndex]

  flowLine.loopContainers[loopIndex].toJs.remove()

  discard jsDelete(flowLine.loopContainers[loopIndex])
  discard jsDelete(loopState.containerDoms[position])

  self.clarifyLoopContainerSteps(loopIndex, position)

proc recreateLoopContainerAndSteps(self: FlowComponent, loopIndex: int, position: int) =
  let baseContainer =
    case self.data.config.realFlowUI:
    of FlowParallel, FlowInline:
      self.flowDom[position]

    of FlowMultiline:
      self.multilineZones[position].dom

  let flowLine = self.flowLines[position]
  let loop = self.flow.loops[loopIndex]
  let firstLineLoopStep = self.flow.steps[flowLine.loopStepCounts[loopIndex][0]]
  let parentContainer = self.ensureLoopContainer(firstLineLoopStep, baseContainer)

  for stepCount in flowLine.loopStepCounts[loopIndex]:
    let step = self.flow.steps[stepCount]

    case self.data.config.realFlowUI:
    of FlowParallel, FlowInline:
      self.addComplexLoopStepValues(step)

    of FlowMultiline:
      self.addMultilineLoopStep(step, parentContainer)

proc moveLinkedLoopSteps*(self: FlowComponent, originLoopIndex: int, translation: float) =
  let originLoop = self.flow.loops[originLoopIndex]

  for line, flowLine in self.flowLines:
    if line >= originLoop.first and line <= originLoop.last:
      self.flowLines[line].offsetLeft =
        self.flowLines[line].offsetLeft + translation
      for loopId in flowLine.loopIds:
        let loopState = self.loopStates[loopId]
        if flowLine.loopContainers.hasKey(loopId):
          let container = flowLine.loopContainers[loopId]
          let leftAttr = container.style.left
          var leftPos: float
          if leftAttr != "":
            leftPos = parseJSFloat(leftAttr.slice(0,leftAttr.len() - 2))
          else:
            leftPos = 0

          container.style.left = &"{leftPos + translation}px"

          if not self.loopContainerIsInViewRange(loopId, line):
            self.clearLoopContainer(loopId, line)
          else:
            self.clarifyLoopContainerSteps(loopId, line)
        else:
          if self.loopContainerIsInViewRange(loopId, line):
            self.recreateLoopContainerAndSteps(loopId, line)
            if line == self.flow.loops[loopId].last and flowLine.startBuffer.loopIds.anyIt(it == loopId):
              flowLine.startBuffer.loopIds.delete(flowLine.startBuffer.loopIds.find(loopId))

proc recalculateTranslation*(self: FlowComponent, position: int, translation: float): float =
  var newTranslation = translation
  let newFlowLineStartPosition =
    self.flowLines[position].offsetLeft + translation
  let newFlowLineEndPosition =
    newFlowLineStartPosition + self.flowLines[position].totalLineWidth.float
  let flowViewEnd =
    self.editorUI.monacoEditor.config.layoutInfo.minimapLeft.float -
    self.editorUI.monacoEditor.config.layoutInfo.contentLeft.float -
    self.distanceBetweenValues.float

  if newFlowLineStartPosition > self.flowLines[position].baseOffsetLeft.float:
    newTranslation = translation -
    (newFlowLineStartPosition - self.flowLines[position].baseOffsetLeft.float)
  elif newFlowLineEndPosition < flowViewEnd:
    newTranslation = translation + (flowViewEnd - newFlowLineEndPosition)

  return newTranslation

proc calculateSliderPosition(self: FlowComponent, line: int, baseIteration: int, ratio: float): int =
  var sliderPositionsCount = 0

  for loopId in self.flowLines[line].loopIds:
    let loopBaseIteration = self.flow.loops[loopId].baseIteration

    if loopBaseIteration < baseIteration:
      sliderPositionsCount += self.flow.loops[loopId].iteration
    else:
      if loopBaseIteration == baseIteration:
        let iteration = floor(ratio * self.flow.loops[loopId].iteration.float)

        sliderPositionsCount += iteration
        self.flowLines[line].sliderPosition =
          (loopIndex:loopId, iteration: iteration)

      break

  return sliderPositionsCount

proc synchronizeLinkedSliders(
  self: FlowComponent,
  loopIndex:int,
  index: int,
  position: int
) =
  let loop = self.flow.loops[loopIndex]
  let originLoopId = self.getOriginLoopIndex(loopIndex)

  if originLoopId != loopIndex:
    let originLoop = self.flow.loops[originLoopId]
    let originLoopIteration = loop.baseIteration
    self.flowLines[originLoop.first].sliderPosition =
      (loopIndex: originLoopId, iteration: originLoopIteration)
    self.flowLines[originLoop.first].sliderDom.toJs.noUiSlider.set(originLoopIteration)
    let iterationRatio = index.float / loop.iteration.float

    for line, slider in self.sliderWidgets:
      if line > originLoop.first and line <= originLoop.last and line != position:
        let sliderPositionsCount =
          self.calculateSliderPosition(line, originLoopIteration, iterationRatio)
        self.flowLines[line].sliderDom.toJs.noUiSlider.set(sliderPositionsCount)
  else:
    for line, slider in self.sliderWidgets:
      if line > loop.first and line <= loop.last and line != position:
        let sliderPositionsCount =
          self.calculateSliderPosition(line, index, 0)
        self.flowLines[line].sliderDom.toJs.noUiSlider.set(sliderPositionsCount)

proc moveFlowDom(
  self: FlowComponent,
  loopIndex: int,
  iteration: int,
  position: int,
  refocus: bool = false,
  resize: bool = false
) =
  let loop = self.flow.loops[loopIndex]
  let flowLine = self.flowLines[position]
  var sliderPosition = self.flowLines[position].sliderPosition

  if sliderPosition.iteration != iteration or sliderPosition.loopIndex != loopIndex or refocus or resize:
    flowLine.sliderPosition = (loopIndex: loopIndex, iteration: iteration)
    # get origin loop ID and origin loop iteration
    self.synchronizeLinkedSliders(loopIndex, iteration, position)

    # calculate translation value and move linked loops
    if self.loopStates.hasKey(loopIndex):
      let loopContainer = self.loopStates[loopIndex].containerDoms[position]
      let activeIterationStep =
        self.flow.steps[flowLine.loopStepCounts[loopIndex][iteration]]
      let iterationPosition =
        self.getStepDomOffsetLeft(activeIterationStep)
      let monacoLayout = self.editorUI.monacoEditor.config.layoutInfo
      let minimapLeft = monacoLayout.minimapLeft.float
      let editorContentLeft = monacoLayout.contentLeft.float
      let flowLineAtPosition = self.flowLines[position]
      var translation = (self.maxFlowLineWidth.float +
        self.distanceToSource.float + editorContentLeft +
        self.flowViewWidth.float / 2) - iterationPosition

      translation = self.recalculateTranslation(position, translation)

      if translation != 0:
        let originLoopId = self.getOriginLoopIndex(loopIndex)
        self.moveLinkedLoopSteps(originLoopId, translation)

proc moveStepValuesInVisibleArea(self: FlowComponent) = # TODO: needs refeactoring
  let flowMode = 
    ($self.data.config.realFlowUI)
      .substr(4, ($self.data.config.realFlowUI).len - 1)
      .toLowerAscii()

  for stepKey, stepNode in self.stepNodes:
    let step = self.flow.steps[stepKey]

    if step.loop != 0 and self.loopStates.hasKey(step.loop) and self.loopStates[step.loop].viewState == LoopValues:
      let sortedExpressions =
        toSeq(self.flowLines[step.position].sortedVariables.keys())

      for i in 0..<sortedExpressions.len:
        let variableExpression = sortedExpressions[i]
        let variableValue = step.beforeValues[variableExpression]

        if self.stepValueIsVisible(step):
          let valueContainer = cast[Node](stepNode.findNodeInElement(
            &"#flow-{flowMode}-value-box-{stepkey}-{variableExpression}"))

          if not valueContainer.isNil:
            let stepValueIndent = self.stepValueIndentation(step, variableValue, valueContainer)
            if stepValueIndent != 0:
              valueContainer.style.textIndent = cstring(&"{stepValueIndent}px")
              valueContainer.style.textAlign = j"left"
            else:
              valueContainer.style.textIndent = j""
              valueContainer.style.textAlign = j""

proc move*(
  self: FlowComponent,
  loopIndex: int,
  iteration: int,
  position: int,
  refocus: bool = false,
  resize: bool = false
) =
  self.moveFlowDom(loopIndex, iteration, position, refocus, resize)

  if not refocus and not resize:
    self.moveStepValuesInVisibleArea()

proc moveRight*(self: FlowComponent) =
  self.selectedIndex += 1
  var stepCount = self.findStepCount()

  if stepCount == OUT_LINE_RANGE:
    self.selectedIndex -= 1
    return

  self.selectedStepCount = stepCount
  self.selectedGroup.visibleStart = self.selectedIndex.float * self.selectedGroup.baseWidth

  self.data.redraw()

proc moveLeft*(self: FlowComponent) =
  if self.selectedIndex > 0:
    self.selectedIndex -= 1
    self.selectedStepCount = self.findStepCount()
    self.selectedGroup.visibleStart = self.selectedIndex.float * self.selectedGroup.baseWidth

    self.data.redraw()


method onRight*(self: FlowComponent) {.async.} =
  if self.selected and not self.selectedGroup.isNil:
    self.moveRight()

method onLeft*(self: FlowComponent) {.async.} =
  if self.selected and not self.selectedGroup.isNil:
    self.moveLeft()

method onCtrlNumber*(self: FlowComponent, arg: int) {.async.} =
  var firstPosition = self.flow.loops[self.selectedGroup.baseID].first
  var position = firstPosition + arg - 1 # from 1

  if self.selectedLineInGroup != arg and self.flow.positionStepCounts.hasKey(position) and
     self.flow.positionStepCounts[position].len > 0:
    self.selectedLine = position
    self.selectedLineInGroup = arg
    self.selectedIndex = 0
    self.focusLoopID(self.selectedStepCount)
    self.selectedStepCount = self.findStepCount()

const DELAY: int64 = 50

proc afterJump(self: FlowComponent, stepCount: int) =
  let step = self.flow.steps[stepCount]
  let location = self.data.services.debugger.location
  let currentStep = self.positionRRTicksToStepCount(location.highLevelLine, location.rrTicks)
  let reverse = if stepCount >= currentStep: false else: true

  let currentTime: int64 = now()
  let lastTimePlusDelay = (self.lastScrollFireTime.toJs + DELAY.toJs).to(int64)

  if lastTimePlusDelay <= currentTime:
    self.redrawFlow()
    self.data.services.debugger.jumpToLocalStep(self.tab.name, step.position, stepCount, step.iteration, step.rrTicks, reverse)


proc jumpToLocalStep*(self: FlowComponent, stepCount: int) =
  let currentTime: int64 = now()

  self.lastScrollFireTime = currentTime

  discard windowSetTimeout(
    proc =
      self.afterJump(stepCount),
      cast[int](DELAY)
  )


proc createContextMenuItems(self: FlowComponent, name: cstring, beforeValue: Value, stepCount: int): seq[ContextMenuItem] =
  var addToScratchpad:  ContextMenuItem
  var addAllValuesToScratchpad:  ContextMenuItem
  var jumpToValue: ContextMenuItem
  var contextMenu:      seq[ContextMenuItem]
  let step = self.flow.steps[stepCount]

  jumpToValue = ContextMenuItem(
    name: "Jump to value",
    hint: "&lt;click on value&gt;",
    handler: proc(e: Event) =
      self.jumpToLocalStep(stepCount)
  )

  contextMenu &= jumpToValue

  addToScratchpad = ContextMenuItem(
    name: "Add value to scratchpad",
    hint: "CTRL+&lt;click on value&gt;",
    handler: proc(e: Event) =
      openValueInScratchpad((name, beforeValue))
      data.redraw()
  )

  contextMenu &= addToScratchpad

  addAllValuesToScratchpad = ContextMenuItem(
    name: "Add all values to scratchpad",
    hint: "",
    handler: proc(e: Event) =
      for key, value in step.beforeValues:
        openValueInScratchpad((key, value))
      data.redraw()
  )

  contextMenu &= addAllValuesToScratchpad

  return contextMenu

proc ensureValueComponent(self: FlowComponent, id: cstring, name: cstring, value: Value) =
  self.modalValueComponent[id] =
    ValueComponent(
      expanded: JsAssoc[cstring, bool]{$name: true},
      charts: JsAssoc[cstring, ChartComponent]{},
      showInLine: JsAssoc[cstring, bool]{},
      baseExpression: name,
      baseValue: value,
      service: data.services.history,
      stateID: -1,
      nameWidth: VALUE_COMPONENT_NAME_WIDTH,
      valueWidth: VALUE_COMPONENT_VALUE_WIDTH,
      data: data,
      isTooltipValue: true,
    )

proc flowEventValue*(self: FlowComponent, event: FlowEvent, stepCount: int, style: VStyle): VNode =
  let flowMode =
    ($self.data.config.realFlowUI)
      .substr(4, ($self.data.config.realFlowUI).len - 1)
      .toLowerAscii()
  var before = &"flow-{flowMode}-value-before-only"

  let (klass, name) = 
    case event.kind:
    of EventLogKind.Error:
      ("flow-error", "error")
    of EventLogKind.Write:
      ("flow-std-default", "stdout")
    of EventLogKind.WriteFile:
      ("flow-std-default", "stdout")
    of EventLogKind.Read:
      ("flow-std-default", "stdin")
    of EventLogKind.ReadFile:
      ("flow-std-default", "stdin")
    else:
      ("", "")
  # let klass = 
  #   case event.kind:
  #   of EventLogKind.Error:
  #     "flow-error"
  #   of EventLogKind.Write:
  #     "flow-std-default"
  #   of EventLogKind.WriteFile:
  #     "flow-std-default"
  #   of EventLogKind.Read:
  #     "flow-std-default"
  #   of EventLogKind.ReadFile:
  #     "flow-std-default"
  #   else:
  #     ""

  result = buildHtml(
    span(
      class = &"flow-{flowMode}-value",
      style=style
    )
  ):
    span(
      class = &"flow-{flowMode}-value-name {klass}-name",
      onmousedown = proc(e: Event, v: VNode) =
        self.jumpToLocalStep(stepCount),
      # oncontextmenu = proc(e: Event, v: VNode) =
      #   case flowValueMode:
      #   of BeforeValueMode:
      #     onContextMenu(e, v, beforeValue)
      #   of AfterValueMode:
      #     onContextMenu(e, v, afterValue)
      #   of BeforeAndAfterValueMode:
      #     discard
    ):
      text &"<{name}>"
    span(
      style = style,
      iteration = $(self.flow.steps[stepCount].iteration),
      class = &"flow-{flowMode}-value-box {klass}-box " & before,
      onmousedown = proc(e: Event, v: VNode) =
        self.jumpToLocalStep(stepCount),
      # oncontextmenu = proc(e: Event, v: VNode) =
      #   onContextMenu(e, v, beforeValue),
      # onmouseover = proc =
      #   if not self.modalValueComponent.hasKey(id):
      #     self.ensureValueComponent(id, name, beforeValue)
      #     self.openTooltip(id, beforeValue)
      #   else:
      #     let valueDom = vnodeToDom(self.modalValueComponent[id].render(), KaraxInstance())
      #     self.displayTooltip(id, valueDom)
    ):
      text event.text


proc flowSimpleValue*(
  self: FlowComponent,
  name: cstring,
  beforeValue: Value,
  afterValue: Value,
  stepCount: int,
  showName: bool,
  style: VStyle,
  i: int = 0,
): VNode =
  let flowMode =
    ($self.data.config.realFlowUI)
      .substr(4, ($self.data.config.realFlowUI).len - 1)
      .toLowerAscii()
  let flowValueMode = self.getFlowValueMode(beforeValue, afterValue)

  proc onMouseDown(e: Event, v: VNode, value: Value) =
    e.stopPropagation()

    if cast[MouseEvent](e).button == 0:
      if cast[bool](e.toJs.ctrlKey):
        openValueInScratchpad((name, value))
        data.redraw()
      else:
        self.jumpToLocalStep(stepCount)

  proc onContextMenu(e: Event, v: VNode, value: Value) =
    e.stopPropagation()

    let step = self.flow.steps[stepCount]
    let contextMenu = createContextMenuItems(self, name, value, stepCount)

    if contextMenu != @[]:
      showContextMenu(contextMenu, cast[int](e.toJs.clientX), cast[int](e.toJs.clientY))

  result = buildHtml(
    span(
      class = &"flow-{flowMode}-value",
      style=style
    )
  ):
    if showName:
      span(
        class = &"flow-{flowMode}-value-name",
        onmousedown = proc(e: Event, v: VNode) =
          self.jumpToLocalStep(stepCount),
        oncontextmenu = proc(e: Event, v: VNode) =
          case flowValueMode:
          of BeforeValueMode:
            onContextMenu(e, v, beforeValue)
          of AfterValueMode:
            onContextMenu(e, v, afterValue)
          of BeforeAndAfterValueMode:
            discard
      ):
        text $name

    if flowValueMode == BeforeValueMode:
      var before = &"flow-{flowMode}-value-before-only"
      let id = &"flow-{flowMode}-value-box-{i}-{stepCount}-{name}"

      span(
        id = id,
        style = style,
        iteration = $(self.flow.steps[stepCount].iteration),
        class = &"flow-{flowMode}-value-box " & before,
        onmousedown = proc(e: Event, v: VNode) =
          onMouseDown(e, v, beforeValue),
        oncontextmenu = proc(e: Event, v: VNode) =
          onContextMenu(e, v, beforeValue),
        onmouseover = proc =
          if not self.modalValueComponent.hasKey(id):
            self.ensureValueComponent(id, name, beforeValue)
            self.openTooltip(id, beforeValue)
          else:
            let valueDom = vnodeToDom(self.modalValueComponent[id].render(), KaraxInstance())
            self.displayTooltip(id, valueDom)
      ):
        text beforeValue.textRepr(compact=true)

    elif flowValueMode == AfterValueMode:
      var after = &"flow-{flowMode}-value-after-only"
      let id = &"flow-{flowMode}-value-box-{i}-{stepCount}-{name}"

      span(
        id = id,
        style = style,
        iteration = $(self.flow.steps[stepCount].iteration),
        class = &"flow-{flowMode}-value-box " & after,
        onmousedown = proc(e: Event, v: VNode) =
          onMouseDown(e, v, afterValue),
        oncontextmenu = proc(e: Event, v: VNode) =
          onContextMenu(e, v, afterValue),
        onmouseover = proc =
          if not self.modalValueComponent.hasKey(id):
            self.ensureValueComponent(id, name, afterValue)
            self.openTooltip(id, afterValue)
          else:
            let valueDom = vnodeToDom(self.modalValueComponent[id].render(), KaraxInstance())
            self.displayTooltip(id, valueDom)
      ):
        text afterValue.textRepr(compact=true)

    else:
      var before = &"flow-{flowMode}-value-dual"
      let idBefore = &"flow-{flowMode}-value-box-{i}-{stepCount}-{name}-before"
      let idAfter = &"flow-{flowMode}-value-box-{i}-{stepCount}-{name}-after"

      span(
        id = idBefore,
        style = style,
        iteration = $(self.flow.steps[stepCount].iteration),
        class = &"flow-{flowMode}-value-box flow-dual-value-before " & before,
        onmousedown = proc(e: Event, v: VNode) =
          onMouseDown(e, v, beforeValue),
        oncontextmenu = proc(e: Event, v: VNode) =
          onContextMenu(e, v, beforeValue),
        onmouseover = proc =
          if not self.modalValueComponent.hasKey(idBefore):
            self.ensureValueComponent(idBefore, name, beforeValue)
            self.openTooltip(idBefore, beforeValue)
          else:
            let valueDom = vnodeToDom(self.modalValueComponent[idBefore].render(), KaraxInstance())
            self.displayTooltip(idBefore, valueDom)
      ):
        text beforeValue.textRepr(compact=true)

      span(
        class = &"flow-{flowMode}-value-name flow-dual-arrow",
      ):
        text "=>"

      span(
        id = idAfter,
        style = style,
        iteration = $(self.flow.steps[stepCount].iteration),
        class = &"flow-{flowMode}-value-box " & before,
        onmousedown = proc(e: Event, v: VNode) =
          onMouseDown(e, v, afterValue),
        oncontextmenu = proc(e: Event, v: VNode) =
          onContextMenu(e, v, afterValue),
        onmouseover = proc =
          if not self.modalValueComponent.hasKey(idAfter):
            self.ensureValueComponent(idAfter, name, afterValue)
            self.openTooltip(idAfter, afterValue)
          else:
            let valueDom = vnodeToDom(self.modalValueComponent[idAfter].render(), KaraxInstance())
            self.displayTooltip(idAfter, valueDom)
      ):
        text afterValue.textRepr(compact=true)

proc clearSliders(self: FlowComponent) =
  var tab = self.data.services.editor.open[self.editorUI.path]
  for widget in self.sliderWidgets:
    tab.monacoEditor.removeContentWidget(widget)
  self.sliderWidgets = JsAssoc[int, js]{}

proc clearInline(self: FlowComponent) =
  for line in self.flowLines:
    # Remove the class 'flow-inline-value' from each node
    for _, node in self.flowLines[line.number].decorationsDoms:
      let nodesToDelete = findAllNodesInElement(node, cstring".flow-inline-value")
      for nodeToDelete in nodesToDelete:
        node.removeChild(nodeToDelete)
    line.decorationsIds = self.editorUI.monacoEditor.deltaDecorations(
      line.decorationsIds,
      @[]
    )
    if not line.contentWidget.isNil:
      self.editorUI.monacoEditor.removeContentWidget(line.contentWidget.toJs)
      line.contentWidget = nil

proc clearParallel(self: FlowComponent) =
  var tab = self.data.services.editor.open[self.editorUI.path]

  if not tab.monacoEditor.isNil:
    for viewZone in self.loopViewZones:
      tab.monacoEditor.changeViewZones do (view: js):
        view.removeZone(viewZone)
    # clear flow line content widgets
    for flowLine in self.flowLines:
      if not flowLine.contentWidget.isNil:
        tab.monacoEditor.removeContentWidget(flowLine.contentWidget.toJs)
        flowLine.contentWidget = nil
  self.flowDom = JsAssoc[int, Node]{}
  self.lineWidgets = JsAssoc[int, JsObject]{}
  self.flowLoops = JsAssoc[int, FlowLoop]{}

proc clearWidgets(self: FlowComponent) =
  var tab = self.data.services.editor.open[self.editorUI.path]

  if not self.statusWidget.isNil:
    tab.monacoEditor.removeContentWidget(self.statusWidget)
    self.statusWidget = nil

proc clearMultiline(self: FlowComponent) =
  for line, zone in self.multilineZones:
    self.removeExpandedFlow(line)

  self.multilineZones = JsAssoc[int, MultilineZone]{}
  self.multilineFlowLines = JsAssoc[int, KaraxInstance]{}
  self.multilineValuesDoms = JsAssoc[int, JsAssoc[cstring, kdom.Node]]{}

proc clearFlowLines*(self: FlowComponent) =
  self.flowLines = JsAssoc[int,FlowLine]{}

proc clearLoopStates*(self: FlowComponent) =
  self.loopStates = JsAssoc[int, LoopState]{}

proc clearStepNodes*(self: FlowComponent) =
  self.stepNodes = JsAssoc[int, kdom.Node]{}

proc clearViewZones(self: FlowComponent) =
  self.viewZones = JsAssoc[int, int]{}

proc resetFlow*(self: FlowComponent) =
  self.clearSliders()
  self.clearInline()
  self.clearMultiline()
  self.clearParallel()

  self.clearLoopStates()
  self.clearWidgets()
  self.clearFlowLines()
  self.clearStepNodes()
  self.clearViewZones()

  self.maxWidth = 0

  if not self.flow.isNil:
    self.flow.relevantStepCount = @[]

  # turn off mutation observer
  if not self.mutationObserver.isNil:
    self.mutationObserver.disconnect()
    cdebug "flow: OBSERVER STOPPED"

method clear*(self: FlowComponent) =
  for tip in self.tippyElement:
    tip.destroy()
  self.tippyElement = nil
  if not self.flow.isNil:
    self.resetFlow()

proc switchFlowUI*(self: FlowComponent, flowUI: FlowUI) =
  if self.data.config.realFlowUI == flowUI:
    return

  self.resetFlow()

  let flowUINames: array[FlowUI, cstring] = [j"parallel", j"inline", j"multiline"]

  self.data.config.flowUI = flowUINames[flowUI]
  self.data.config.realFlowUI = flowUI
  self.data.redraw()

proc addContentWidget*(
  self: FlowComponent,
  dom: Node,
  line: int,
  column: int,
  id: cstring,
  isStatusWidget: bool = false,
  isSliderWidget: bool = false
): JsObject =
  dom.class = "flow-content-widget"
  var editor = self.editorUI.monacoEditor

  if self.lineWidgets.isNil:
    cdebug "flow: clear lineWidgets because it's currently nil"
    self.lineWidgets = JsAssoc[int, js]{}

  let widget = js{
    domNode: cast[Node](nil),
    getId: proc: cstring = id,
    getDomNode: (proc: Node =
      if cast[Node](jsthis.domNode).isNil:
        jsthis.domNode = dom
      cast[Node](jsthis.domNode)),
    getPosition: (proc: js =
      js{position: js{lineNumber: parseJSInt(line), column: column}, preference: cast[seq[MonacoContent]](@[EXACT])})
  }

  if isStatusWidget:
    self.statusWidget = widget
  elif isSliderWidget:
    self.sliderWidgets[line] = widget
  else:
    self.flowLines[line].contentWidget = cast[Node](widget)

  editor.addContentWidget(widget)

  return widget

proc makeLegend(self: FlowComponent, step: FlowStep): Node =
  let vNode = buildHtml(
    tdiv(
      class="flow-loop-legend",
      style = flowLoopLegendStyle(self, step.loop)
    )
  ):
    var counter = 0
    let valuesCount = toSeq(step.beforeValues.keys()).len
    for expression, value in step.beforeValues:
      counter += 1
      tdiv(
        class = "flow-loop-legend-expression",
        style = legendValueStyle(self, step, expression)
      ):
        text expression
      if counter < valuesCount:
        var emptySpaceStyle = style()
        let emptySpaceWidth =
          self.loopStates[step.loop].positions[step.position]
            .legendValueGapPercentage
        emptySpaceStyle =
          style((StyleAttr.width, cstring($(emptySpaceWidth) & "%")))
        tdiv(
          class = "flow-loop-empty-space",
          style = emptySpaceStyle
        )

  let legendNode = vnodeToDom(vNode, KaraxInstance())

  self.flowLines[step.position].legendDom = legendNode

  return legendNode

proc makeFlowLineContainer*(self: FlowComponent, step: FlowStep) =
  # create content widget for
  var dom = cast[Node](document.createElement(j"div"))
  let id = j(&"ct-flow-{self.id}-{step.position}")

  self.flowDom[step.position] = dom

  discard self.addContentWidget(dom, step.position, 0, id)

proc shrinkedLoopIterationView(self: FlowComponent, iteration: int) : Node =
  let vNode = buildHtml(
    tdiv(
      class = "flow-loop-shrinked-iteration",
      id = &"flow-loop-shrinked-iteration-{iteration}"
    )
  ):
    text ""
  return vnodeToDom(vNode, KaraxInstance())

proc shrinkLoopIterations*(self: FlowComponent, loopIndex: int) =
  let state = self.loopStates[loopIndex]

  state.viewState = LoopShrinked

  for index, node in loopPositionsChildren(self, loopIndex):
    let nodeChildren = node.childNodes

    for j in 0..<nodeChildren.len:
      nodeChildren[j].style.display = "none"

    node.appendChild(shrinkedLoopIterationView(self, index))
    node.style.width = &"{self.shrinkedLoopColumnMinWidth}px"

    if index > 0:
      let leftValue: string = $(node.style.left.replaceCString("px",""))
      let currentPosition = parseInt(leftValue)
      let deltaWidth = state.defaultIterationWidth - self.shrinkedLoopColumnMinWidth

      node.style.left = cstring($(currentPosition-index*deltaWidth) & "px")

proc resetShrinkedLoopIterations*(self: FlowComponent) =
  let flowMode =
    ($self.data.config.realFlowUI)
      .substr(4, ($self.data.config.realFlowUI).len - 1)
      .toLowerAscii()
  let shrinkedIterations = jqAll(".flow-loop-shrinked-iteration")

  for element in shrinkedIterations:
    element.toJs.remove()

  let flowValues = jqAll(&".contentWidgets .flow-{flowMode}-value")

  for element in flowValues:
    element.style.display = ""

  let emptySpaces = jqAll(".contentWidgets .flow-loop-empty-space")

  for element in emptySpaces:
    element.style.display = ""

  let emptySpacesWithBorder = jqAll(".contentWidgets .flow-loop-empty-space-left-border")

  for element in emptySpacesWithBorder:
    element.style.display = ""

proc resetColumnsWidth*(self:FlowComponent, deltaWidth: int, loopIndex:int, shrinked: bool) =
  let state = self.loopStates[loopIndex]
  var widthStyle = cstring($(state.defaultIterationWidth) & "px")

  for index, position in loopPositionsChildren(self, loopIndex):
    position.style.width = widthStyle
    if index > 0:
      let leftValue: string = $(position.style.left.replaceCString("px",""))
      let currentPosition = parseInt(leftValue)
      if not shrinked:
        position.style.left = cstring($(currentPosition+index*deltaWidth) & "px")
      else:
        position.style.left =
          cstring(
            $(
              currentPosition +
              index *
              deltaWidth *
              (state.defaultIterationWidth - self.shrinkedLoopColumnMinWidth)
            ) & "px"
          )

proc calculatePositionMaxWidth(self: FlowComponent, step: FlowStep) =
  let loop = self.flow.loops[step.loop]
  var loopState = self.loopStates[step.loop]

  if not loopState.positions.hasKey(step.position):
    loopState.positions[step.position] = LoopPosition(
      positionColumns: JsAssoc[int, PositionColumn]{},
      loopIndex: step.loop)

  let loopPosition = loopState.positions[step.position]
  let loopPositionStepCounts =
    self.flow.steps.filterIt(
      it.loop == step.loop and
      it.position == step.position).mapIt(it.stepCount)
  var positionValueMaxChars = 0

  for stepCount in loopPositionStepCounts:
    let step = self.flow.steps[stepCount]

    if not loopPosition.positionColumns.hasKey(step.iteration):
      loopPosition.positionColumns[step.iteration] =
        PositionColumn(
          iteration: step.iteration,
          valuesExpressions: JsAssoc[cstring, ExpressionColumn]{}
        )

    let positionColumn = loopPosition.positionColumns[step.iteration]
    var stepValuesChars = 0
    var stepExpressionsChars = 0

    for expression, value in step.beforeValues:
      var expressionWidth = expression.len
      if expressionWidth < 3: expressionWidth = 3
      var valueWidth = value.textRepr(compact=true).len
      if valueWidth < 3: valueWidth = 3
      if valueWidth > 7: valueWidth = 7
      if not positionColumn.valuesExpressions.hasKey(expression):
        positionColumn.valuesExpressions[expression] =
          ExpressionColumn(
            valueCharsCount: valueWidth,
            expressionCharacters: expressionWidth
          )
      stepExpressionsChars += expressionWidth + 1
      stepValuesChars += valueWidth + 1
    stepExpressionsChars -= 1
    stepValuesChars -= 1

    if loopPosition.expressionsChars == 0:
      loopPosition.expressionsChars = stepExpressionsChars
      loopPosition.legendValueGapPercentage = 100 / stepExpressionsChars
      if loopState.legendWidth < stepExpressionsChars*self.pixelsPerSymbol:
        loopState.legendWidth = stepExpressionsChars*self.pixelsPerSymbol

    if stepValuesChars > positionColumn.positionMaxValuesChars:
      positionColumn.positionMaxValuesChars = stepValuesChars

    if stepValuesChars*self.pixelsPerSymbol > loopState.defaultIterationWidth:
      loopState.defaultIterationWidth = stepValuesChars*self.pixelsPerSymbol
      loopState.maxPositionValuesChars = stepValuesChars

proc realignPositionWidths(self: FlowComponent, loopPosition: LoopPosition) =
  for iteration, positionColumn in loopPosition.positionColumns:
    positionColumn.valueGapPercentage = 100 / positionColumn.positionMaxValuesChars
    for expressionColumn in positionColumn.valuesExpressions:
      expressionColumn.valuePercent =
        expressionColumn.valueCharsCount * 100 / positionColumn.positionMaxValuesChars
      expressionColumn.expressionLegendPercent =
        expressionColumn.expressionCharacters * 100 / loopPosition.expressionsChars

proc flowComplexStep(self: FlowComponent, step: FlowStep): VNode =
  let flowMode =
    ($self.data.config.realFlowUI)
      .substr(4, ($self.data.config.realFlowUI).len - 1)
      .toLowerAscii()
  var vNodeStyle: VStyle
  var parentId: cstring
  var parentClass: cstring

  vNodeStyle = self.flowLeftStyle(step.position)

  parentId = &"flow-{flowMode}-value-{step.position}"
  parentClass = &"flow-{flowMode} flow-{flowMode}-value-single"

  let vNode = buildHtml(
    tdiv(
      id = parentId,
      class = parentClass,
      style = vNodeStyle
    )
  ):
    var counter = 0
    let valuesCount = toSeq(step.beforeValues.keys()).len
    var style = style(
      (StyleAttr.fontSize, cstring($(self.fontSize) & "px")),
      (StyleAttr.lineHeight, cstring($self.lineHeight & "px")),
      (StyleAttr.height, cstring($self.lineHeight & "px"))
    )
    for event in step.events:
      flowEventValue(self, event, step.stepCount, style)

    for i, expression in step.exprOrder:
      let beforeValue = step.beforeValues[expression]
      let afterValue = step.afterValues[expression]
      if beforeValue.isNil and afterValue.isNil:
        continue
      counter += 1
      var showName = true


      flowSimpleValue(
        self,
        expression,
        beforeValue,
        step.afterValues[expression],
        step.stepCount,
        showName,
        style,
        i
      )

      if counter < valuesCount:
        var emptySpaceStyle = style()

        tdiv(
          class = "flow-loop-empty-space",
          style = emptySpaceStyle
        )

  return vNode

proc getEditorFirstLineNumber(self: FlowComponent): int =
  let editorId = self.editorUI.id
  return cast[int](
    jq(&"#editorComponent-{editorId} .monaco-editor .margin-view-overlays .gutter-line")
      .innerText
  )

proc calculateVariablePosition(self: FlowComponent, position: int, expression: cstring): int =
  let pattern = regex("[^a-zA-Z0-9_'\"]" & expression & "[^a-zA-Z0-9_'\"]")
  let text = self.tab.sourceLines[position - 1]
  let match = pattern.exec(text)

  if not match.isNil:
    let variablePosition = match.index.to(int) + 1

    self.flowLines[position].variablesPositions[expression] = variablePosition

    return variablePosition
  else:
    return -1

proc makeflowValue(
  self: FlowComponent,
  position: int,
  expression: cstring,
  topOffset: int,
  leftPos: int,
  beforeValue: Value,
  afterValue: Value,
  stepCount: int
): Node =
  let editor = self.editorUI.monacoEditor
  let positionColumn = editor.getOffsetForColumn(position, leftPos + 1)
  let editorConfiguration = editor.config
  let editorLeftOffset = editorConfiguration.layoutInfo.contentLeft
  let editorLineHeight = editorConfiguration.lineHeight
  let nodeLeft = editorLeftOffset + positionColumn
  let style = style(
    (StyleAttr.fontSize, cstring($(self.fontSize) & "px")),
    (StyleAttr.lineHeight, cstring($(self.lineHeight - 2) & "px")),
    (StyleAttr.height, cstring($(self.lineHeight - 2) & "px"))
  )

  let vNode = buildHtml(
    tdiv(
      id = &"flow-multiline-value-{position}-{expression}",
      class = "flow-multiline-value-container",
      style = style(
        (StyleAttr.top, cstring($(topOffset*editorLineHeight) & "px")),
        (StyleAttr.left, cstring($(nodeLeft) & "px")))
    )
  ):
    if topOffset > 0:
      tdiv(
        class = "flow-multiline-value-pointer",
        style = style(
          (StyleAttr.top, cstring($((-1)*topOffset*editorLineHeight) & "px")),
          (StyleAttr.height, cstring($(topOffset*editorLineHeight) & "px"))))
    flowSimpleValue(self, expression, beforeValue, afterValue, stepCount, false, style)

  return vnodeToDom(vNode, KaraxInstance())

proc sortVariablesPositions(self: FlowComponent, step: FlowStep, ascending: bool = true) =
  var direction: int  = 1;

  if ascending: direction = -1

  var sortedVariablesExpressions =
    toSeq(self.flowLines[step.position].variablesPositions.pairs())
      .sorted((x,y) => direction*x[1]-direction*y[1])
      .mapIt(it[0])

  for expression in sortedVariablesExpressions:
    self.flowLines[step.position].sortedVariables[expression] =
      step.beforeValues[expression]

proc makeMultilineFlowValues(self: FlowComponent, step: FlowStep) =
  var topOffset = 0
  # render variable lines in the viewZone
  for expression, variable in self.flowLines[step.position].sortedVariables:
    let dom = self.makeflowValue(
      step.position,
      expression,
      topOffset,
      self.flowLines[step.position].variablesPositions[expression].int,
      step.beforeValues[expression],
      step.afterValues[expression],
      step.stepCount
    )
    cast[Node](self.multilineZones[step.position].dom).appendChild(dom)

    if not self.multilineValuesDoms.hasKey(step.position):
      self.multilineValuesDoms[step.position] = JsAssoc[cstring, Node]{}

    self.multilineValuesDoms[step.position][expression] = dom
    self.stepNodes[step.stepCount] = dom
    topOffset += 1

proc insertInlineDecorations(self: FlowComponent, step: FlowStep) =
  let monacoEditor = self.editorUI.monacoEditor

  for expression, variable in step.beforeValues:
    let position =
      self.flowLines[step.position].variablesPositions[expression] + 1 +
      expression.len

    if self.flowLines[step.position].variablesPositions.hasKey(expression):
      let decorationRange: MonacoRange = newMonacoRange(
        step.position,
        position,
        step.position,
        position
      )
      let newDecorationId = monacoEditor.deltaDecorations(
        @[],
        @[
          DeltaDecoration(
            `range`: decorationRange,
            options: js{
              afterContentClassName: cstring(&"flow-inline-decoration {expression}")
            }
          )
        ]
      )
      self.flowLines[step.position].decorationsIds.add(newDecorationId[0])


proc insertFlowInlineValues(self: FlowComponent, step: FlowStep) =
  let editorId = self.editorUI.id
  let editorLinesDom = jq(&"#editorComponent-{editorId} .monaco-editor .view-lines").children
  let lineIndex = self.getSourceLineDomIndex(step.position)
  let line = cast[Node](editorLinesDom[lineIndex])
  let lineDecorationsDoms = findAllNodesInElement( line,
    cstring".flow-inline-decoration")
  var index = 0
  let style = style(
    (StyleAttr.fontSize, cstring($(self.fontSize) & "px")),
    (StyleAttr.lineHeight, cstring($(self.lineHeight - 2) & "px")),
    (StyleAttr.height, cstring($(self.lineHeight - 2) & "px"))
  )

  if self.flowLines.hasKey(step.position) and not self.flowLines[step.position].sortedVariables.isNil:
    for expression, variable in self.flowLines[step.position].sortedVariables:
      if not self.flowLines[step.position].decorationsDoms.hasKey(expression):
        let widget = self.flowDom[step.position]
        let valueVNode = flowSimpleValue(
          self,
          expression,
          step.beforeValues[expression],
          step.afterValues[expression],
          step.stepCount,
          false,
          style
        )

        lineDecorationsDoms[index].appendChild(vnodeToDom(valueVNode, KaraxInstance()))
        self.flowLines[step.position].decorationsDoms[expression] = lineDecorationsDoms[index]
        index += 1

proc makeInlineFlowLines(self: FlowComponent, step: FlowStep) =
  if self.flowLines[step.position].decorationsIds.len == 0:
    self.insertInlineDecorations(step)

  let id = setTimeout(proc = self.insertFlowInlineValues(step), 50)

proc renderContinuousStep(
  self: FlowComponent,
  stepContainer: Node,
  step: FlowStep,
  name: cstring,
  singleValue: bool,
  style: VStyle
): VNode =
  stepContainer.toJs.classList.toJs.add("continuous")

  let id = &"flow-loop-shrinked-iteration-step-{step.stepCount}"

  buildHtml(
    tdiv(
      id = id,
      class = "flow-loop-continuous-iteration",
      style = style,
      onclick = proc =
        self.jumpToLocalStep(step.stepCount),
      ondblclick = proc =
        self.openValue(step.stepCount, name, before=true),
      onmouseover = proc(ev: Event, tg: VNode) =
        ev.stopPropagation()
    )
  ):
    text ""

proc renderShrinkedStep(
  self: FlowComponent,
  stepContainer: Node,
  step: FlowStep,
  name: cstring,
  singleValue: bool,
  style: VStyle
): VNode =
  stepContainer.toJs.classList.toJs.add("shrinked")

  let id = &"flow-loop-shrinked-iteration-step-{step.stepCount}"

  buildHtml(
    tdiv(
      id = id,
      class = "flow-loop-shrinked-iteration",
      style = style,
      onclick = proc =
        self.jumpToLocalStep(step.stepCount),
      ondblclick = proc =
        self.openValue(step.stepCount, name, before=true),
      onmouseover = proc(ev: Event, tg: VNode) =
        ev.stopPropagation()
    )
  ):
    text ""

proc makeFlowStepContainer(self: FlowComponent, step: FlowStep): Node =
  var containerClass = "flow-loop-step-container"
  var containerStyle = style()

  let vNode = buildHtml(
    tdiv(
      id = &"flow-loop-step-container-{step.loop}-{step.iteration}",
      class = containerClass,
      style = containerStyle
    )
  ):
    text ""

  return vnodeToDom(vNode, KaraxInstance())

proc makeMultilineLoopStepView(self: FlowComponent, step: FlowStep): Node =
  # create flow loop step container
  let stepContainer = self.makeFlowStepContainer(step)

  # fill the container
  var topOffset = 0
  let editor = self.editorUI.monacoEditor
  let editorLineHeight = editor.config.lineHeight
  var stepVNode: VNode

  for expression, variable in self.flowLines[step.position].sortedVariables:
    let style = style(
      (StyleAttr.top, cstring($(topOffset*editorLineHeight) & "px"))
    )

    case self.loopStates[step.loop].viewState:
    of LoopContinuous:
      stepVNode = renderContinuousStep(self, stepContainer, step, expression, singleValue=true, style)

    of LoopShrinked:
      stepVNode = renderShrinkedStep(self, stepContainer, step, expression, singleValue=true, style)

    else:
      stepVNode = flowSimpleValue(
        self,
        expression,
        step.beforeValues[expression],
        step.afterValues[expression],
        step.stepCount,
        false,
        style
      )

    stepContainer.appendChild(vnodeToDom(stepVNode, KaraxInstance()))
    topOffset += 1

  return stepContainer

proc addMultilineLoopStep(self: FlowComponent, step: FlowStep, container: Node) =
  let stepDom = self.makeMultilineLoopStepView(step)

  self.stepNodes[step.stepCount] = stepDom
  container.appendChild(stepDom)

proc makeComplexLoopStepView(self: FlowComponent, step: FlowStep): Node =
  # create step container
  let stepContainer = self.makeFlowStepContainer(step)
  self.stepNodes[step.stepCount] = stepContainer

  # create step vNode
  var stepVNode: VNode
  case self.loopStates[step.loop].viewState:
  of LoopContinuous:
    for expression, value in step.beforeValues:
      stepVNode = renderContinuousStep(self, stepContainer, step, expression, singleValue=false, style())

  of LoopShrinked:
    for expression, value in step.beforeValues:
      stepVNode = renderShrinkedStep(self, stepContainer, step, expression, singleValue=false, style())

  else:
    stepVNode = flowComplexStep(self, step)

  stepContainer.appendChild(vnodeToDom(stepVNode, KaraxInstance()))

  return stepContainer

proc makeLoopStepView(self: FlowComponent, step: FlowStep): Node =
  case self.data.config.realFlowUI:
  of FlowParallel, FlowInline:
    makeComplexLoopStepView(self, step)

  of FlowMultiline:
    makeMultilineLoopStepView(self, step)

proc addLoopStep(self: FlowComponent, step: FlowStep, container: Node) =
  let stepDom = self.makeLoopStepView(step)
  self.stepNodes[step.stepCount] = stepDom

  # check if there is a register for loop step cells
  let stepLoopCells = self.flowLines[step.position].stepLoopCells

  if not stepLoopCells.hasKey(step.loop):
    stepLoopCells[step.loop] = JsAssoc[int, Node]{}

  # add stepDom to flowLines register and append it to container
  stepLoopCells[step.loop][step.iteration] = stepDom
  container.appendChild(stepDom)


proc setFlowLineActiveIteration(self: FlowComponent, position: int) =
  let debuggerLocation = self.data.services.debugger.location.rrTicks
  let line = self.flowLines[position]

  for loopIndex in line.loopIds:
    let loop = self.flow.loops[loopIndex]
    let loopActiveIteration = self.loopStates[loopIndex].activeIteration
    let rrTicksOfLoopActiveIteration =
      self.flow.loops[loopIndex].rrTicksForIterations[loopActiveIteration]

    if debuggerLocation <= rrTicksOfLoopActiveIteration:
      if loop.base == -1:
        line.activeLoopIteration =
          (loopIndex: loopIndex, iteration: loopActiveIteration)
      elif loop.baseIteration == self.loopStates[loop.base].activeIteration:
        line.activeLoopIteration =
          (loopIndex: loopIndex, iteration: loopActiveIteration)
      else:
        line.activeLoopIteration =
          (loopIndex: -1, iteration: -1)

      break

proc makeMultilineLoopFlow(self: FlowComponent, step: FlowStep) =
  # if loop container is out of flow viewport it does not need to be rendered
  if not self.loopContainerIsInViewRange(step.loop, step.position) or
    not self.stepContainerIsInViewRange(step):
    return

  if not self.stepNodes.hasKey(step.stepCount) or step.iteration == 0: # self.loopStates[step.loop].activeIteration:
    # get loop container (create a new one if it does not exist)
    let viewZoneDom = self.multiLineZones[step.position].dom
    let container = self.ensureLoopContainer(step, viewZoneDom)

    # create loop step view
    self.addMultilineLoopStep(step, container)

    # set container calculated width and add it to loopStates register
    container.style.width = &"{self.calculateLoopContainerWidth(step.loop)}px"

proc makeFlowLoopBackgroundDom(self: FlowComponent, loopIndex: int): Node =
  let vNode = buildHtml(
    tdiv(
      id = &"flow-loop-{loopIndex}-background",
      class = "flow-loop-background",
      style = self.flowLoopBackgroundStyle(loopIndex)
    )
  ): text ""

  return vnodeToDom(vNode, KaraxInstance())

proc makeFlowLoopBackground(self: FlowComponent, loopIndex: int) =
  let backgroundDom = self.makeFlowLoopBackgroundDom(loopIndex)
  let loop = self.flow.loops[loopIndex]
  let loopState = self.loopStates[loopIndex]

  if self.flowDom.hasKey(loop.first):
    let widget = self.flowDom[loop.first]

    widget.appendChild(backgroundDom)

    self.loopStates[loopIndex].background = FlowLoopBackground(
      dom: backgroundDom,
      maxWidth:
        case self.data.config.realFlowUI:
        of FlowParallel, FlowInline:
          loopState.legendWidth + loopState.totalLoopWidth + 2*self.distanceBetweenValues

        of FlowMultiline:
          loopState.totalLoopWidth + 2*self.distanceBetweenValues)

proc ensureFlowLineContainer(self: FlowComponent, step: FlowStep) =
  if not self.flowDom.haskey(step.position) and
    self.flowLines[step.position].contentWidget.isNil:
    self.makeFlowLineContainer(step)

  if not self.flowDom.haskey(step.position):
    cwarn fmt"flow: cannot create flow widget at {step.position} line"
    return

proc calculateMaxWidth*(self: FlowComponent, stepNodeWidth: int) =
  let editor = self.editorUI.monacoEditor
  let editorLayout = editor.config.layoutInfo
  let minimapWidth = editorLayout.minimapWidth

  self.maxWidth = max(
    self.maxWidth,
    stepNodeWidth
  )

proc addParallelRegularStepValues(self: FlowComponent, step: FlowStep) =
  # check if there is a widget and container for this step
  # create them if there is not
  self.ensureFlowLineContainer(step)

  # get content widget
  let widget = self.flowDom[step.position]

  # create step container
  let stepContainer = self.makeFlowStepContainer(step)

  # add relevant positions to be drawn in the editor
  self.stepNodes[step.stepCount] = stepContainer

  # get widget as a parent container
  let parentContainer = self.flowDom[step.position]

  # create step vNode
  let stepVNode = flowComplexStep(self, step)

  # create step Node
  let stepNode = vnodeToDom(stepVNode, KaraxInstance())

  # append step Node to stepContainer
  stepContainer.appendChild(stepNode)

  # append stepContainer to parentContainer
  parentContainer.appendChild(stepContainer)

proc addComplexLoopStepValues(self: FlowComponent, step: FlowStep) =
  # if loop container is out of flow viewport it does not need to be rendered
  if not self.loopContainerIsInViewRange(step.loop, step.position) or
    not self.stepContainerIsInViewRange(step):
    return

  # check if there is a widget and container for this step
  # create them if there is not
  self.ensureFlowLineContainer(step)

  # get content widget
  let widget = self.flowDom[step.position]

  # create step container
  let stepContainer = self.makeFlowStepContainer(step)
  self.stepNodes[step.stepCount] = stepContainer

  # create legend if there is not any yet
  if self.flowLines[step.position].legendDom.isNil:
    let legend = self.makeLegend(step)
    widget.appendChild(legend)

  # get loop container or create one if there is not any
  let parentContainer = self.ensureLoopContainer(step, widget)

  # check if there is already a background for loop steps
  # create one if there is not
  if self.loopStates[step.loop].background.isNil and
    self.flow.loops[step.loop].base == -1:
      self.makeFlowLoopBackground(step.loop)

  # make a slider if there is not any yet
  if step.position == self.flow.loops[step.loop].first:
    if not self.viewZones.hasKey(step.position - 1):
      self.createLoopViewZones(step.loop)
    if not self.sliderWidgets.hasKey(step.position):
      self.makeSlider(self.flow.loops[step.loop].first)

  # check if there is a register for loop step cells
  let stepLoopCells = self.flowLines[step.position].stepLoopCells
  if not stepLoopCells.hasKey(step.loop):
    stepLoopCells[step.loop] = JsAssoc[int, Node]{}

  # add step container to flow line step cells register
  steploopCells[step.loop][step.iteration] = stepContainer

  # create step vNode
  var stepVNode: VNode

  case self.loopStates[step.loop].viewState:
  of LoopContinuous:
    stepVNode = renderContinuousStep(self, stepContainer, step, "complex", singleValue=false, style())

  of LoopShrinked:
    stepVNode = renderShrinkedStep(self, stepContainer, step, "complex", singleValue=false, style())

  else:
    stepVNode = flowComplexStep(self, step)

  # create step Node
  let stepNode = vnodeToDom(stepVNode, KaraxInstance())

  # append step Node to stepContainer
  stepContainer.appendChild(stepNode)

  # append stepContainer to parentContainer
  parentContainer.appendChild(stepContainer)

proc addParallelStepValues(self: FlowComponent, step: FlowStep) =
  self.addParallelRegularStepValues(step)

proc addMultilineStepValues(self: FlowComponent, step: FlowStep) =
  # create viewZone for this step if there is not any yet
  if not self.multilineZones.hasKey(step.position) and
      not self.flowDom.haskey(step.position):
    let newZoneDom =
      createFlowViewZone(
        self,
        step.position,
        step.beforeValues.len.float*self.lineHeight.float)

    self.multiLineZones[step.position] =
      MultilineZone(
        dom: newZoneDom,
        zoneId: self.viewZones[step.position],
        variables: JsAssoc[cstring, bool]{})

    cast[Element](newZoneDom).classList.add("flow-content-widget")

    self.flowDom[step.position] = newZoneDom

  self.makeMultilineFlowValues(step)

proc addInlineStepValues(self: FlowComponent, step: FlowStep) =
  self.makeInlineFlowLines(step)

proc recalculateMaxFlowLineWidth*(self: FlowComponent) =
  self.maxFlowLineWidth = 0
  let monaco = self.editorUI.monacoEditor

  for position, stepCounts in self.flow.positionStepCounts:
    let positionMaxColumn = monaco.getModel().getLineMaxColumn(position)
    var sourceLength = monaco.getOffsetForColumn(position, positionMaxColumn)

    if sourceLength > self.maxFlowLineWidth:
      self.maxFlowLineWidth = sourceLength

proc addStepValues*(self: FlowComponent, step: FlowStep) =
  if (step.loop == 0 and step.iteration == 0) or
      (self.flowLoops.hasKey(self.flow.loops[step.loop].registeredLine) and
      self.flowLoops[self.flow.loops[step.loop].registeredLine].loopStep.iteration == step.iteration):
    if step.loop != 0:
      for key, _ in self.flow.loopIterationSteps[step.loop][step.iteration].table:
        self.flow.relevantStepCount.add(key)
    case self.data.config.realFlowUI:
    of FlowParallel:
      addParallelStepValues(self, step)

    of FlowMultiline:
      addMultilineStepValues(self, step)

    else:
      addInlineStepValues(self, step)

proc isFullyLoaded(self: FlowComponent): bool =
  var result = true
  let stepWithValues =
    self.flow.steps.filter(step => step.beforeValues.len > 0)

  for step in stepWithValues:
    if not self.flowDom.hasKey(step.position) or
       not self.stepNodes.hasKey(step.stepCount):
        result = false

        break

  return result

proc setEditorMutationObserver(self: FLowComponent) =
  let editorId = self.editorUI.id
  let editorLinesDom =
    jq(&"#editorComponent-{editorId} .monaco-editor .view-lines")

  self.mutationObserver = createMutationObserver(
    proc(mutationList: seq[MutationRecord], observer: MutationObserver) =
      if mutationList.any(record => $(record.`type`) == cstring"childList"):
        if not self.isFullyLoaded():
          reloadFlow(self))

  self.mutationObserver.observe(
    cast[Element](editorLinesDom),
    js{ childList: true })

  cdebug "flow: OBSERVER STARTED"

proc setLoopTotalWidth(self: FlowComponent, loopIndex: int) =
  let loop = self.flow.loops[loopIndex]
  let loopState = self.loopStates[loopIndex]
  var totalLoopWidth: float = 0

  for i in 0..<loop.iteration:
    totalLoopWidth += loopState.iterationsWidth[i]

  if loopState.viewState == LoopContinuous:
    totalLoopWidth += self.distanceBetweenValues.float
  else:
    totalLoopWidth += (loop.iteration*self.distanceBetweenValues).float

  loopState.totalLoopWidth = Math.round(totalLoopWidth)

proc setLoopIterationsWidth(self: FlowComponent, loopIndex: int, iterationWidth: float) =
  let loop = self.flow.loops[loopIndex]
  let loopState = self.loopStates[loopIndex]
  var sumOfPreviousIterations: float

  for i in 0..<loop.iteration:
    loopState.iterationsWidth[i] = iterationWidth
    loopState.sumOfPreviousIterations[i] = sumOfPreviousIterations
    sumOfPreviousIterations += iterationWidth

proc calculateParentsIterationsWidth*(self: FlowComponent, loopIndex: int) =
  let loop = self.flow.loops[loopIndex]

  if loop.base == -1:
    self.loopStates[loopIndex].iterationsWidth[loop.iteration - 1] =
      self.loopStates[loopIndex].defaultIterationWidth.float

    self.setLoopTotalWidth(loopIndex)

    return
  else:
    let nextLoopId = loop.base
    let loopSiblings = toSeq(self.flow.loops.pairs())
      .filterIt(it[1].first >= loop.first and it[1].last <= loop.last)
      .mapIt(it[0])
    for sibling in loopSiblings:
      if self.loopStates.hasKey(loopIndex) and
        self.loopStates.hasKey(loop.base):
        let loop = self.flow.loops[sibling]
        let loopState = self.loopStates[sibling]
        let parentLoop = self.flow.loops[loop.base]
        let parentLoopState = self.loopStates[loop.base]
        let parentIterationWidth =
          loop.iteration *
          (loopState.defaultIterationWidth +
          self.distanceBetweenValues) -
          self.distanceBetweenValues

        parentLoopState.iterationsWidth[loop.baseIteration] =
          parentIterationWidth.float

    self.calculateParentsIterationsWidth(nextLoopId)

proc isWideEnoughForChildToBeShrinked(
  self: FLowComponent,
  parentWidth: float,
  loopIterations: int
): bool =
  return parentWidth >=
    (
      (self.shrinkedLoopColumnMinWidth + self.distanceBetweenValues) *
      loopIterations -
      self.distanceBetweenValues
    ).float

proc setLoopViewState(self: FlowComponent, loopIndex: int, iterationWidth: float) =
  let loopState = self.loopStates[loopIndex]

  if iterationWidth < self.shrinkedLoopColumnMinWidth.float:
    if loopState.viewState != LoopContinuous:
      loopState.viewStateChangesCount += 1

    loopState.viewState = LoopContinuous
  elif iterationWidth < loopState.defaultIterationWidth.float:
    if loopState.viewState != LoopShrinked:
      loopState.viewStateChangesCount += 1

    loopState.viewState = LoopShrinked
  else:
    if loopState.viewState != LoopValues:
      loopState.viewStateChangesCount += 1

    loopState.viewState = LoopValues

proc calculateFocusedLoopsIterationsWidth*(self: FlowComponent) =
  let focusedLoopIds = toSeq(self.loopStates.pairs())
    .filterIt(it[1].focused)
    .mapIt(it[0])

  for loopIndex in focusedLoopIds:
    let loopState = self.loopStates[loopIndex]
    self.setLoopIterationsWidth(loopIndex, loopState.defaultIterationWidth.float)
    self.setLoopTotalWidth(loopIndex)

proc setLoopSumOfPreviousIterationsWidth(self: FlowComponent, loopIndex: int) =
  let loop = self.flow.loops[loopIndex]
  var sum: float = 0
  for i in 0..loop.iteration:
    self.loopStates[loopIndex].sumOfPreviousIterations[i] = sum
    sum += self.loopStates[loopIndex].iterationsWidth[i]

proc calculateActualIterationsWidth*(self: FlowComponent, loopIndex: int) =
  let loop = self.flow.loops[loopIndex]
  let loopState = self.loopStates[loopIndex]

  # for loops witohout parents
  if loop.base == -1:
    self.setLoopViewState(loopIndex, loopState.defaultIterationWidth.float)
    # only for loops without children
    if loop.internal.len == 0:
      self.setLoopIterationsWidth(loopIndex, loopState.defaultIterationWidth.float)
      self.setLoopTotalWidth(loopIndex)
    else:
      self.setLoopSumOfPreviousIterationsWidth(loopIndex)
  # for loops with parents
  else:
    # if loop.base != -1: # and toSeq(loopState.iterationsWidth.keys()).len == 0:
    let parentLoopState = self.loopStates[loop.base]
    let parentIteration = loop.baseIteration

    if not parentLoopState.iterationsWidth.hasKey(parentIteration):
      parentLoopState.iterationsWidth[parentIteration] =
        parentLoopState.defaultIterationWidth.float
    let parentIterationWidth =
      parentLoopState.iterationsWidth[parentIteration]
    var loopIterationWidth: float

    if not self.isWideEnoughForChildToBeShrinked(parentIterationWidth, loop.iteration):
      loopIterationWidth =
        parentIterationWidth / loop.iteration.float

      if loopState.viewState != LoopContinuous:
        loopState.viewStateChangesCount += 1

      loopState.viewState = LoopContinuous
    else:
      loopIterationWidth = (parentIterationWidth -
        ((loop.iteration - 1)*self.distanceBetweenValues).float) /
        loop.iteration.float

      if loopIterationWidth < loopState.defaultIterationWidth.float:
        if loopState.viewState != LoopShrinked:
          loopState.viewStateChangesCount += 1

        loopState.viewState = LoopShrinked
      else:
        if loopState.viewState != LoopValues:
          loopState.viewStateChangesCount += 1

        loopState.viewState = LoopValues

    # set loop iterationsWidth and total Loop width
    self.setLoopIterationsWidth(loopIndex, loopIterationWidth)
    self.setLoopTotalWidth(loopIndex)

proc redrawLoopStepsAtPosition*(
  self: FLowComponent,
  loopIndex: int,
  position: int
) =
  if self.loopStates[loopIndex].containerDoms.hasKey(position):
    let loopContainer = self.loopStates[loopIndex].containerDoms[position]

    # clear loop container
    loopContainer.toJs.innerHTML = ""
    self.flowLines[position].stepLoopCells[loopIndex] = JsAssoc[int, Node]{}

    let loopSteps = self.flow.loops[loopIndex].stepCounts

    for stepCount in loopSteps:
      let loopStep = self.flow.steps[stepCount]
      if loopStep.position == position:
        self.addLoopStep(loopStep, loopContainer)

proc showOrHideSlider(self: FlowComponent, position: int) =
  if self.flowLines[position].totalLineWidth > self.flowViewWidth:
    self.flowLines[position].sliderDom.style.display = "inline-flex"
  else:
    self.flowLines[position].sliderDom.style.display = "none"

proc calculateSliderLeftOffset(self:FlowComponent, loopIndex: int): int =
  case self.data.config.realFlowUI:
  of FlowParallel, FlowInline:
    return self.maxFlowLineWidth +
      self.distanceToSource +
      self.loopStates[loopIndex].legendWidth +
      self.distanceBetweenValues div 2

  of FlowMultiline:
    return self.maxFlowLineWidth +
      self.distanceToSource

proc recalculateFlowViewWidth*(self: FlowComponent) =
  let monacoLayoutInfo =
    self.editorUI.monacoEditor.config.layoutInfo
  let minimapLeft = monacoLayoutInfo.minimapLeft
  let contentLeft = monacoLayoutInfo.contentLeft

  self.flowViewWidth =
    minimapLeft - self.maxFlowLineWidth -
    contentLeft - self.distanceToSource

proc updateLoopBackground(self: FlowComponent, loopIndex: int) =
  let backgroundProps = self.prepareBackgroundStyleProps(loopIndex)
  let backgroundDom = self.loopStates[loopIndex].background.dom
  var backgroundMaxWidth =
    self.loopStates[loopIndex].totalLoopWidth + 2*self.distanceBetweenValues

  if self.data.config.realFlowUI != FlowMultiline:
    backgroundMaxWidth += self.loopStates[loopIndex].legendWidth

  self.loopStates[loopIndex].background.maxWidth = backgroundMaxWidth

  var width = backgroundProps.width

  if backgroundProps.width > backgroundMaxWidth:
    width = backgroundMaxWidth

  backgroundDom.style.left = &"{backgroundProps.left}px"
  backgroundDom.style.top = &"{backgroundProps.top}px"
  backgroundDom.style.width = &"{width}px"
  backgroundDom.style.height = &"{backgroundProps.height}px"

proc resizeFlowLineContainers(self: FlowComponent, line: int) =
  let flowLine = self.flowLines[line]
  let flowLineContainerProps = self.prepareFlowLineContainerProps(line)
  var width = flowLineContainerProps.width

  if width > flowLine.totalLineWidth:
    width = flowLine.totalLineWidth

  flowLine.mainLoopContainer.style.left = &"{flowLineContainerProps.left}px"
  flowLine.mainLoopContainer.style.width = &"{width}px"
  flowLine.mainLoopContainer.style.height = &"{flowLineContainerProps.height}px"

proc updateLoopContainerStyle(self: FLowComponent, loopIndex: int, position: int) =
  let flowLine = self.flowLines[position]
  let loopState = self.loopStates[loopIndex]
  let container = flowLine.loopContainers[loopIndex]
  let containerWidth = loopState.totalLoopWidth
  let leftValue = loopState.containerOffset -
    (flowLine.baseOffsetLeft.float - flowLine.offsetleft.float)

  container.style.width = &"{containerWidth}px"
  container.style.left = &"{leftValue}px"

proc updateFlowDom*(self: FlowComponent) =
  for line, slider in self.sliderWidgets:
    self.showOrHideSlider(line)

  for line, flowLine in self.flowLines:
    if flowLine.loopIds.len > 0:
      let firstLoopId = flowLine.loopIds[0]
      # update flowline legend if there is any
      if not flowLine.legendDom.isNil:
        let legendWidth = self.loopStates[firstLoopId].legendWidth
        flowLine.legendDom.style.width = &"{legendWidth}px"
        flowLine.legendDom.style.left =
          &"{self.maxFlowLineWidth + self.distanceToSource}px"

      # update slider dom element at this line if there is any
      if not flowLine.sliderDom.isNil:
        let sliderLeftOffset =
          self.calculateSliderLeftOffset(firstLoopId)
        flowLine.sliderDom.style.left = &"{sliderLeftOffset}px"
        resizeLineSlider(self, line)

      self.resizeFlowLineContainers(line)

    # update all loops dom nodes
    for loopIndex in flowLine.loopIds:
      if flowLine.loopContainers[loopIndex].isNil:
        continue

      if not self.loopContainerIsInViewRange(loopIndex, line):
          self.clearLoopContainer(loopIndex, line)
          continue

      # if self.loopStates[loopIndex].containerOffset
      let loopState = self.loopStates[loopIndex]
      let loop = self.flow.loops[loopIndex]

      # update flow background if there is any
      if not loopState.background.isNil:
        self.updateLoopBackground(loopIndex)
      # update step nodes width
      for stepCount in loop.stepCounts:
        let step = self.flow.steps[stepCount]

        if self.stepNodes[stepCount].isNil:
          continue

        if not self.stepContainerIsInViewRange(step):
          self.clearStepContainer(step)
          continue

        let stepDom = self.stepNodes[stepCount]
        let stepNodeWidth =
          self.loopStates[step.loop].iterationsWidth[step.iteration]

        # check if view state of the loop has changed more than once
        if loopState.viewStateChangesCount > 1:
          for key, positions in loopState.positions:
            self.redrawLoopStepsAtPosition(loopIndex, key)
          loopState.viewStateChangesCount = 1
        else:
          let containerStyle = self.loopStepContainerStyle(step)
          stepDom.style.width = cstring(containerStyle.getAttr(StyleAttr.width))
          stepDom.style.left = cstring(containerStyle.getAttr(StyleAttr.left))

      self.updateLoopContainerStyle(loopIndex, line)

  self.moveStepValuesInVisibleArea()

proc makeFlowLine(self: FlowComponent, position: int): FlowLine =
  cdebug fmt"makeFlowLine position {position}"
  FlowLine(
    startBuffer: FlowBuffer(
      kind: FlowLineBuffer,
      position: position,
      loopIds: @[]
    ),
    number: position,
    variablesPositions: JsAssoc[cstring, int]{},
    sortedVariables: JsAssoc[cstring, Value]{},
    decorationsIds: @[],
    decorationsDoms: JsAssoc[cstring, Node]{},
    stepLoopCells: JsAssoc[int, JsAssoc[int, Node]]{},
    loopContainers: JsAssoc[int, Node]{},
    iterationContainers: JsAssoc[int, Node]{},
    loopIds: @[],
    sliderPositions: @[],
    activeLoopIteration: (-1,-1),
    loopStepCounts: JsAssoc[int, seq[int]]{}
  )

proc getFocusedLoopsIds*(self: FlowComponent): seq[int] =
  return toSeq(
    self.loopStates.pairs()
  )
    .filterIt(it[1].focused)
    .mapIt(it[0])

proc calculateFlowLoopIterationsWidths*(self: FlowComponent) =
  # get focused loops
  let focusedLoops = self.getFocusedLoopsIds()

  ## calculate all iterations widths of focused loops parents recursively
  if focusedLoops.len > 0:
    self.calculateFocusedLoopsIterationsWidth()
    self.calculateParentsIterationsWidth(focusedLoops[0])

  ## recalculate loop columns width
  for loopIndex, loop in self.loopStates:
    self.calculateActualIterationsWidth(loopIndex)
    self.setLoopContainerOffset(loopIndex)

proc redrawLinkedLoops*(self:FlowComponent) = # TODO: make it work on more than two levels of loops
  # get focused loops
  let focusedLoops = self.getFocusedLoopsIds()

  # find loop origin index and state
  var originLoopIndex = self.getOriginLoopIndex(focusedLoops[0])
  let originLoopState = self.loopStates[originLoopIndex]

  # redraw origin loop steps
  for key, position in originLoopState.positions:
    # diplay or hide slider
    if key == self.flow.loops[originLoopIndex].first and
      not self.flowLines[key].sliderDom.isNil:
        self.showOrHideSlider(key)

    # redraw loop position if they change their view state
    if originLoopState.viewStateChangesCount > 1:
      self.redrawLoopStepsAtPosition(originLoopIndex, key)
      originLoopState.viewStateChangesCount = 1
    else:
      self.clarifyLoopContainerSteps(originLoopIndex, key)


  # redraw all internal loop steps
  for loopIndex in self.flow.loops[originLoopIndex].internal:
    let loopState = self.loopStates[loopIndex]
    for key, positions in loopState.positions:
      if loopState.containerDoms.hasKey(key):
        # diplay or hide slider
        if key == self.flow.loops[loopindex].first and
          not self.flowLines[key].sliderDom.isNil:
            self.showOrHideSlider(key)

        # redraw loop position
        if loopState.viewStateChangesCount > 1:
          self.redrawLoopStepsAtPosition(loopIndex, key)
          originLoopState.viewStateChangesCount = 1
        else:
          self.clarifyLoopContainerSteps(loopIndex, key)
      else:
        if self.loopContainerIsInViewRange(loopIndex, key):
          self.recreateLoopContainerAndSteps(loopIndex, key)

proc setLoopStatesActiveIteration(self: FlowComponent, debuggerLocationRRTicks: int) =
  for index, loopState in self.loopStates:
    let rrTicksForIterations = self.flow.loops[index].rrTicksForIterations
    let firstLoopIterationRRTicks = rrTicksForIterations[0]
    let lastLoopIterationRRTicks = rrTicksForIterations[rrTicksForIterations.len - 1]

    if debuggerLocationRRTicks <= firstLoopIterationRRTicks:
      loopState.activeIteration = 0
    elif debuggerLocationRRTicks >= lastLoopIterationRRTicks:
      loopState.activeIteration = rrTicksForIterations.len - 1
    else:
      for index, iteration in rrTicksForIterations:
        if iteration == debuggerLocationRRTicks:
          loopState.activeIteration = index

proc calclulateFlowLineTotalWidth*(self: FlowComponent, position: int): int =
  var totalWidth = 0
  let flowLine = self.flowLines[position]

  if flowLine.loopIds.len != 0:
    if flowLine.loopIds.len == 1:
      totalWidth += self.loopStates[flowLine.loopIds[0]].totalLoopWidth
    else:
      var parentLoopId = -1
      for loopId in flowLine.loopIds:
        let loop = self.flow.loops[loopId]
        if loop.base != parentLoopId:
          parentLoopId = loop.base
          totalWidth += self.loopStates[parentLoopId].totalLoopWidth

  return totalWidth

proc positionRRTicksToStepCount*(self: FlowComponent, position: int, rrTicks: int): int =
  var flow = self.flow

  try:
    let firstStepCount = flow.positionStepCounts[position][0]
    let lastStepCount = flow.positionStepCounts[position][^1]

    if rrTicks < flow.steps[firstStepCount].rrTicks:
      return firstStepCount
    elif rrTicks > flow.steps[lastStepCount].rrTicks:
      return lastStepCount

    for i, stepCount in flow.positionStepCounts[position]:
      let nextStepCount = flow.positionStepCounts[position][min(i + 1, len(flow.positionStepCounts[position]) - 1)]
      if rrTicks >= flow.steps[stepCount].rrTicks and rrTicks <= flow.steps[nextStepCount].rrTicks:
        return stepCount

    return lastStepCount
  except IndexDefect as e:
    cerror(&"flow: We don't have a position step count or steps for that position {e.msg}")

    return NO_STEP_COUNT

proc createLoopStates(self: FlowComponent) =
  for loopIndex, loop in self.flow.loops:
    if loopIndex > 0:
      if not self.loopStates.hasKey(loopIndex):
        self.loopStates[loopIndex] = makeLoopState()

proc flowLoopValue*(
  self: FlowComponent,
  step: FlowStep,
  allIterations: int,
  style: VStyle
): VNode =
  let flowMode =
    ($self.data.config.realFlowUI)
      .substr(4, ($self.data.config.realFlowUI).len - 1)
      .toLowerAscii()
  var iteration = step.iteration
  var width = len(intToStr(allIterations))

  proc onEnter(self: FlowComponent) =
    let newStep = self.flow.steps[self.flow.loopIterationSteps[step.loop][iteration].table[step.position]]
    self.activeStep = newStep
    self.jumpToLocalStep(self.activeStep.stepCount + 1)

  result = buildHtml(
    span(
      class = &"flow-loop-value",
      style=style
    )
  ):
    span(class = &"flow-loop-value-name", style=style):
      span(class = &"flow-parallel-loop-iteration-start"): text "iteration "
      textarea(class = &"flow-loop-textarea",
        placeholder = fmt"{iteration}",
        maxlength = $width,
        oninput = proc(ev: Event, v: VNode) =
          let value = parseInt($ev.target.value)
          if value >= 0 and value <= allIterations:
            iteration = value,
        onkeydown = proc(ev: KeyboardEvent, v: VNode) =
          if ev.keyCode == ENTER_KEY_CODE:
            self.onEnter()
            self.redrawFlow(),
        style = style(
          (StyleAttr.width, cstring($(width+1) & "ch")),
          (StyleAttr.textAlign, cstring("right"))),
      )
      span(class = &"flow-{flowMode}-loop-iteration-end"): text fmt"from {allIterations}"

proc backLoopControlButton(self: FlowComponent, step: FlowStep, style: VStyle): VNode =
  let iteration = step.iteration
  let currentStep = self.flow.steps[step.stepCount]
  let previousIterationStepCount = self.flow.steps[self.flow.loopIterationSteps[currentStep.loop][max(iteration-1, 0)].table[step.position]]

  result = buildHtml(
    button(
      class = "flow-loop-button backward",
      style = style,
      disabled = toDisabled(iteration-1 < 0),
      onclick = proc =
        self.activeStep = previousIterationStepCount
        self.jumpToLocalStep(self.activeStep.stepCount + 1)
        self.redrawFlow()
        self.data.redraw()
    )
  )

proc nextLoopControlButton(self: FlowComponent, step: FlowStep, style: VStyle): VNode =
  let iteration = step.iteration
  let currentStep = self.flow.steps[step.stepCount]
  let maxIterations = self.flow.loopIterationSteps[currentStep.loop].len - 1
  let nextIterationStepCount = self.flow.steps[self.flow.loopIterationSteps[currentStep.loop][min(iteration+1, maxIterations)].table[step.position]]

  result = buildHtml(
    button(
      class = "flow-loop-button forward",
      style = style,
      disabled = toDisabled(maxIterations == iteration),
      onclick = proc =
        self.activeStep = nextIterationStepCount
        self.jumpToLocalStep(self.activeStep.stepCount + 1)
        self.redrawFlow()
        self.data.redraw()
    )
  )

proc makeLoopLine(
  self: FlowComponent,
  step: FlowStep,
  allIterations: int
): Node =
  let editor = self.editorUI.monacoEditor
  let positionColumn = editor.getOffsetForColumn(step.position, 0)
  let editorConfiguration = editor.config
  let editorLeftOffset = editorConfiguration.layoutInfo.contentLeft
  let style = style(
    (StyleAttr.fontSize, cstring($(self.fontSize) & "px")),
    (StyleAttr.lineHeight, cstring($self.lineHeight & "px")),
    (StyleAttr.height, cstring($self.lineHeight & "px"))
  )

  let vNode = buildHtml(
    tdiv(
      id = &"flow-multiline-value-{step.position}-{step.stepCount}",
      class = "flow-multiline-value-container"
    )
  ):
    backLoopControlButton(self, step, style)
    flowLoopValue(self, step, allIterations, style)
    nextLoopControlButton(self, step, style)

  self.data.redraw()

  return vnodeToDom(vNode, KaraxInstance())

proc makeFlowLoops(self: FlowComponent, step: FlowStep) =
  let expression = &"for-{step.position}"
  # render variable lines in the viewZone
  let allIterations = self.flow.loops[step.loop].rrTicksForIterations.len - 1
  let dom = self.makeLoopLine(
    step,
    allIterations)
  cast[Node](self.flowLoops[step.position].flowZones.dom).appendChild(dom)

  self.flowLoops[step.position].flowDom = dom
  self.makeSlider(step.position)

proc addLoopInfo(self: FlowComponent, step: FlowStep) =
  # create viewZone for this step if there is not any yet
  if not self.flowLoops.hasKey(step.position):
    self.flowLoops[step.position] = FlowLoop(loopStep: step)
    let lineHeight =
      self.editorUI.monacoEditor.config.lineHeight
    let position = self.flow.loops[step.loop].first
    let newZoneDom =
      createFlowViewZone(
        self,
        position - 1,
        self.lineHeight.float,
        true)

    self.flowLoops[step.position].flowZones =
      MultilineZone(
        dom: newZoneDom,
        zoneId: self.loopViewZones[step.position],
        variables: JsAssoc[cstring, bool]{})

    cast[Element](newZoneDom).classList.add("flow-content-widget")

    self.makeFlowLoops(step)

proc getClosestIterationStepCount*(self: FlowComponent, loop: Loop, stepCount: int): int =
  var steps = self.flow.steps
  let firstStepCount = loop.stepCounts[0]
  let lastStepCount = loop.stepCounts[^1]

  if firstStepCount < stepCount and stepCount < lastStepCount:
    return stepCount
  elif stepCount <= firstStepCount:
    return firstStepCount
  elif lastStepCount <= stepCount:
    return lastStepCount

proc updateIterationStepCount*(self: FlowComponent, line: int, stepCount: int, loopId: int, iteration: int): int =
  var table = self.flow.loopIterationSteps[loopId][iteration].table

  if table.hasKey(line):
    return table[line]
  else:
    return stepCount

proc getCurrentStepCount*(self: FlowComponent, line: int): int =
  var stepCount: int
  stepCount = self.positionRRTicksToStepCount(line, self.data.services.debugger.location.rrTicks)
  let step = self.flow.steps[stepCount]

  if self.flowLoops.hasKey(self.flow.loops[step.loop].first):
    let loopStep = self.flowLoops[self.flow.loops[step.loop].first].loopStep
    stepCount = self.updateIterationStepCount(line, stepCount, loopStep.loop, loopStep.iteration)
  elif self.activeStep.rrTicks == NO_TICKS:
    stepCount = self.positionRRTicksToStepCount(line, self.data.services.debugger.location.rrTicks)
  else:
    stepCount = self.positionRRTicksToStepCount(line, self.activeStep.rrTicks)
    let activeStep = self.flow.steps[stepCount]
    let loop = self.flow.loops[activeStep.loop]
    if self.flow.steps[stepCount].loop == self.activeStep.loop:
      stepCount = self.updateIterationStepCount(line, stepCount, self.activeStep.loop, self.activeStep.iteration)
    elif self.flow.loops[self.activeStep.loop].internal != []:
      var activeLoop = self.flow.loops[self.activeStep.loop]
      var loopId = activeLoop.internal[min(self.activeStep.iteration, len(activeLoop.internal) - 1)]
      var iteration =
        if activeLoop.internal.len == self.activeStep.iteration:
          len(self.flow.loopIterationSteps[loopId]) - 1
        else:
          FLOW_ITERATION_START

      stepCount = self.updateIterationStepCount(line, stepCount, loopId, iteration)

  return stepCount

proc renderFlowLines*(self: FlowComponent) =
  # cdebug "flow: renderFlowLines"
  let editorContentLeft =
    self.editorUI.monacoEditor.config.layoutInfo.contentLeft.float

  self.createLoopStates()

  for line, flowLine in self.flowLines:
    let stepCount = self.getCurrentStepCount(line)
    let step = self.flow.steps[stepCount]
    let loopId = step.loop
    let loopIteration = step.iteration

    # calculate variables position on the line
    if toSeq(self.flowLines[step.position].variablesPositions.keys()).len == 0:
      for expression, values in step.beforeValues:
        discard calculateVariablePosition(self, step.position, expression)
      self.sortVariablesPositions(step, false)

    # add step values
    let monacoEditorRange = self.editorUI.monacoEditor.getVisibleRanges()[0]
    let flowViewStartLine = monacoEditorRange.startLineNumber.to(int)
    let flowViewEndLine = monacoEditorRange.endLineNumber.to(int)

    if not self.stepNodes.hasKey(step.stepCount):
      if step.position == self.flow.loops[loopId].registeredLine:
        self.addLoopInfo(step)
      if step.beforeValues.len > 0 or step.afterValues.len > 0 or step.events.len > 0:
        self.addStepValues(step)

proc reloadFlow*(self:FlowComponent) =
  self.renderFlowLines()

proc createFlowLines(self: FlowComponent) =
  let editorContentLeft =
    self.editorUI.monacoEditor.config.layoutInfo.contentLeft.float

  for line, stepCounts in self.flow.positionStepCounts:
    if line < self.tab.sourceLines.len:
      for stepCount in stepCounts:
        let step = self.flow.steps[stepCount]
        if step.loop == 0 and step.iteration == 0:
          self.flow.relevantStepCount.add(step.position)

      if not self.flowLines.hasKey(line):
        self.flowLines[line] = self.makeFlowLine(line)
        self.flowLines[line].offsetLeft =
          self.calculateFlowLineLeftOffset(self.flowLines[line]).float
    else:
      cwarn "ignoring because is too big for this file(wrong file?)"

proc maxLegendWidthInLoopFamily(self: FlowComponent, loopIndex: int): int =
  var maxChildLegendWidth = 0
  let loop = self.flow.loops[loopIndex]
  let loopState = self.loopStates[loopIndex]

  if loop.internal.len == 0:
    return loopState.legendWidth
  else:
    for loopId in loop.internal:
      let maxWidth = self.maxLegendWidthInLoopFamily(loopId)
      if maxWidth > maxChildLegendWidth:
        maxChildLegendWidth = self.loopStates[loopId].legendWidth

  if maxChildLegendWidth > loopState.legendWidth:
    return maxChildLegendWidth
  else:
    return loopState.legendWidth

proc setLoopFamilyLegendWidth(self: FlowComponent, loopIndex: int, legendWidth: int) =
  let loop = self.flow.loops[loopIndex]
  let loopState = self.loopStates[loopIndex]

  loopState.legendWidth = legendWidth

  if loop.internal.len == 0:
    return
  else:
    for loopId in loop.internal:
      self.setLoopFamilyLegendWidth(loopId, legendWidth)

proc calculateLineHeight(self: FlowComponent) =
  let option = self.editorUI.monacoEditor.getOption(50)

  self.lineHeight = option.lineHeight - 4
  self.fontSize = option.fontSize - 2

proc recalculateAndRedrawFlow*(self: FlowComponent) =
  self.createFlowLines()
  self.calculateLineHeight()
  self.renderFlowLines()

  if self.mutationObserver.isNil:
    setEditorMutationObserver(self)

proc adjustFlow(self: FlowComponent) =
  self.recalculateMaxFlowLineWidth()
  self.recalculateFlowViewWidth()

  for line, flowLine in self.flowLines:
    flowLine.offsetLeft = self.calculateFlowLineLeftOffset(flowLine).float
    if not flowLine.mainLoopContainer.isNil:
      flowLine.mainLoopContainer.style.left = &"{flowLine.offsetLeft}px"

method onUpdatedFlow*(self: FlowComponent, update: FlowUpdate) {.async.} =
  try:
    if update.isNil:
      cdebug "flow: update is nil: stopping"
      return
    if update.location.toJs.isNil:
      cdebug "flow: update location is nil: stopping"
      return
    let updateLocationName = if self.editorUI.editorView != ViewInstructions:
        update.location.highLevelPath
      else:
        # should be always path:name
        update.location.highLevelPath & cstring":" & update.location.functionName

    if self.editorUI.name != updateLocationName:
      cdebug "flow: editor name not equal to update location name: stopping"
      return

    self.status = update.status

    if update.location.key != self.key:
      self.resetFlow()
      self.key = update.location.key

      if self.flow.isNil:
        self.flow = update.view_updates[self.editorUI.editorView]
    else:
      self.flow = update.view_updates[self.editorUI.editorView]

    self.editorUI.flowUpdate = update

    self.recalculateAndRedrawFlow()

    self.redrawFlow()

    self.recalculate = true
    self.data.redraw()
  except:
    console.error lastJSError
    console.error lastJSError.stack
    cerror "flow: " & getCurrentExceptionMsg()


proc varStyle(self: FlowComponent, fields: seq[cstring]): VStyle =
  let width = 70 / fields.len.float
  style((StyleAttr.cssFloat, j"left"))

proc makeSliderDom(self: FlowComponent, position: int): Node =
  var dom = cast[Node](jq(&"#flow-loop-slider-container-{position}"))

  if dom.isNil:
    let vNode = buildHtml(tdiv(class = "flow-loop-slider-container",
      id = &"flow-loop-slider-container-{position}",
      style = flowLeftStyle(self, position, true))):
        tdiv(class = "flow-loop-slider",
             id = &"flow-loop-slider-{position}",
             style = loopSliderStyle(self, position))

    dom = vnodeToDom(vNode, KaraxInstance())
  else:
    let childVNode = buildHtml(tdiv(class = "flow-loop-slider",
      id = &"flow-loop-slider-{position}",
      style = loopSliderStyle(self, position))): text ""
    let childDom = vnodeToDom(childVNode, KaraxInstance())

    dom.appendChild(childDom)

  self.flowLoops[position].sliderDom = dom.childNodes[0]

  return dom

proc addSliderWidget(self: FlowComponent, position:int) =
  let id = &"flow-slider-widget-{position}"
  let dom = makeSliderDom(self, position)

  self.flowLoops[position].flowDom.appendChild(dom)

proc resizeEditorHandler(self:FlowComponent, position: int) =
  # get new monaco editor config
  self.editorUI.monacoEditor.config = getConfiguration(self.editorUI.monacoEditor)
  self.resizeFlowSlider()

proc setEditorResizeObserver(self: FLowComponent, position: int) =
  let activeEditor = "\"" & self.data.services.editor.active & "\""
  let editorDom = jq(fmt"[data-label={activeEditor}]")
  let resizeObserver = createResizeObserver(proc(entries: seq[Element]) =
    for entry in entries:
      let timeout = setTimeout(proc = resizeEditorHandler(self, position),100))

  resizeObserver.observe(cast[Node](editorDom))

proc calculateLineIndentations(self: FlowComponent, position: int) : int =
  let previousLineOverlaysDom =
    jq(&"#editorComponent-{self.editorUI.id} .monaco-editor .view-overlays")
      .children[self.getSourceLineDomIndex(position)]
  var indents = 0

  for child in previousLineOverlaysDom.children:
    if getAttribute(cast[Node](child), cstring"class") == cstring"cigr":
      indents += 1

  return indents

proc createFlowViewZone(self: FlowComponent, position: int, heightInPx: float, isLoop: bool = false): Node =
  #create viewZone
  let editorLineNumbersWidth =
    self.editorUI.monacoEditor.config.layoutInfo.contentLeft
  var zoneDom = document.createElement("div")

  zoneDom.id = fmt"flow-view-zone-{position}"
  zoneDom.class = "flow-view-zone"
  zoneDom.style.display = "flex"

  let viewZone = js{
        afterLineNumber: position,
        heightInPx: heightInPx + 3,
        domNode: zoneDom
      }

  if isLoop:
    self.editorUI.monacoEditor.changeViewZones do (view: js):
      var zoneId = cast[int](view.addZone(viewZone))
      self.loopViewZones[position] = zoneId
  else:
    self.editorUI.monacoEditor.changeViewZones do (view: js):
      var zoneId = cast[int](view.addZone(viewZone))
      self.viewZones[position] = zoneId

  # calculate previous position indentations count
  let lineNumberDom = document.createElement("div")

  lineNumberDom.class = "line-numbers"
  lineNumberDom.style.height = "100%"
  lineNumberDom.style.width = jq(".line-numbers").style.width
  lineNumberDom.style.position = "absolute"
  lineNumberDom.style.left = "0px"
  zoneDom.appendChild(lineNumberDom)

  return zoneDom

proc createLoopViewZones(self: FlowComponent, loopIndex: int) =
  # get loop positions
  let loop = self.flow.loops[loopIndex]
  let lineHeight =
    self.editorUI.monacoEditor.config.lineHeight.float

  discard self.createFlowViewZone(loop.first - 1, lineHeight)

  if loop.base == -1:
    discard self.createFlowViewZone(loop.last - 1, lineHeight)

proc makeSlider(self: FlowComponent, position: int) =
  # create slider widget
  self.addSliderWidget(position)

  # slider setup
  var element = self.flowLoops[position].sliderDom
  let step = self.flowLoops[position].loopStep
  let loop = self.flow.loops[step.loop]
  var maxLength = self.editorUI.monacoEditor.config.layoutInfo.contentWidth

  # tooltip function
  proc sliderEncoder(value: float): int =
    return Math.floor(value)

  if element.isNil:
    return

  if not element.toJs.noUiSlider.isNil:
   element.toJs.noUiSlider.destroy()
  else:
    noUiSlider.create(element, js{
      "start": step.iteration,
      "range": js{
        "min": FLOW_ITERATION_START,
        "max": loop.iteration
      },
      "behaviour": cstring"drag-tap",
      "connect": [true, false],
      "step": 1,
    })

    var onUpdate = proc(values: seq[cstring], handle: int, unencoded: seq[float], tap: bool, positions: seq[float]) =
      let newTimeInMs = now()
      let loopIteration = Math.floor(unencoded[0])
      let newStepCount = self.flow.loopIterationSteps[step.loop][loopIteration].table[step.position]
      let activeStep = self.flow.steps[newStepCount]

      if self.data.ui.activeFocus != self:
        self.data.ui.activeFocus = self

      self.flowLoops[position].loopStep = activeStep
      self.activeStep = activeStep
      # self.updateFlowOnMove(newStepCount + 1, activeStep.position)
      self.redrawFlow()
      # TODO?
      # if self.lastSliderUpdateTimeInMs <= 0 or newTimeInMs - self.lastSliderUpdateTimeInMs >= 100:
      self.lastSliderUpdateTimeInMs = newTimeInMs
      self.jumpToLocalStep(newStepCount + 1)
      # Affect the complete move to have a delay on the update
      # Maybe later on add to all of the EventLog components?
      cast[EventLogComponent](data.ui.componentMapping[Content.EventLog][0]).isFlowUpdate = true

    let elementSlider = cast[JsObject](element).noUiSlider
    elementSlider.on(cstring"slide", onUpdate)
    setEditorResizeObserver(self, position)

proc resizeLineSlider(self: FlowComponent, position: int) =
  let editor = self.editorUI.monacoEditor
  let editorLayout = editor.config.layoutInfo
  let minimapLeft = editorLayout.minimapLeft
  let minimapWidth = editorLayout.minimapWidth
  let slider = jq(fmt"#flow-loop-slider-{position}")
  if not slider.isNil:
    let leftValue = slider.style.left
    slider.style.width = fmt"calc({minimapLeft - minimapWidth}px - {leftValue})"

const MAX_CELL_WIDTH = 100

proc moveButtonsView(self: FlowComponent, visibleWidth: float): VNode =
  result = buildHtml(
    tdiv(class="move-buttons")
  ):
    let leftStyle = style((StyleAttr.left, cstring($(self.maxFlowLineWidth - 4) & cstring"ex")))
    let rightStyle = style((StyleAttr.marginLeft, cstring($(visibleWidth + MAX_CELL_WIDTH.float)) & cstring"px"))

    tdiv(class="flow-left-button", style=leftStyle, onclick = proc =
      if not self.selected:
        discard self.select()
      discard self.onLeft()):
      fa "caret-left"
    tdiv(class="flow-right-button", style=rightStyle, onclick = proc =
      if not self.selected:
        discard self.select()
      discard self.onRight()):
      fa "caret-right"

proc iterationVarView(self: FlowComponent, line: int, field: cstring, style: VStyle): VNode =
  var limitedLabel = if ($field).len > 5: ($field)[0 .. ^4] & ".." else: $field

  buildHtml(tdiv(style=style)):
    text limitedLabel

proc iterationInfoView(self: FlowComponent, line: int, fields: seq[cstring]): VNode =
  buildHtml(tdiv(class="flow-iteration-info")):
    let style = self.varStyle(fields)
    for variable in fields:
      iterationVarView(self, line, variable, style)

func calculateInternal(self: FlowComponent, group: Group, loop: Loop, width: float)

proc calculateLayout*(self: FlowComponent) =
  # calculate layout before redraw
  for group in self.groups:
    if self.recalculate or group.lastCalculationID == -1 or group.lastCalculationID != group.focusedLoopID:
      group.loopWidths = JsAssoc[int, seq[float]]{}
      group.loopFinal = JsAssoc[int, float]{}
      group.baseWidth = 2.0

      if self.valueMode != BeforeAndAfterValueMode:
        group.baseWidth = 1.0

      var width = 1.float
      var focused = self.flow.loops[group.focusedLoopID]
      var base: Loop
      var baseID = -1
      var idList = @[group.focusedLoopID]
      var maxWidth = 1.0

      if focused.base != -1:
        base = self.flow.loops[focused.base]
        baseID = focused.base
        idList = idList.concat(base.internal)

      for id in idList:
        var loop = self.flow.loops[id]
        for line in loop.first .. loop.last:
          var loopList: seq[float] = @[]
          var final = 0.0
          for i in 0 ..< loop.iteration:
            loopList.add(width)
            final += width

            if id == group.focusedLoopID:
              let stepCount = loop.stepCounts[i]

              if stepCount in self.flow.steps.low .. self.flow.steps.high:
                let step = self.flow.steps[stepCount]
                var valueWidth = 0.0

                if self.data.config.realFlowUI != FlowMultiline:
                  for label, value in step.beforeValues:
                    let before = value
                    let after = step.afterValues[label]
                    var valueCharactersLength = 0

                    case self.valueMode:
                    of BeforeValueMode:
                      valueCharactersLength += before.textRepr(compact=true).len

                    of AfterValueMode:
                      valueCharactersLength += after.textRepr(compact=true).len

                    of BeforeAndAfterValueMode:
                       valueCharactersLength += before.textRepr(compact=true).len + after.textRepr(compact=true).len

                    valueWidth += (valueCharactersLength + 1).float * 4.0
                else:
                  self.ensureTokens(line)

                  for label, left in self.editorUI.tokens[line]:
                    if step.beforeValues.hasKey(label):
                      let before = step.beforeValues[label]
                      let after = step.afterValues[label]
                      var valueCharactersLength = 0

                      case self.valueMode:
                      of BeforeValueMode:
                        valueCharactersLength += before.textRepr(compact=true).len

                      of AfterValueMode:
                        valueCharactersLength += after.textRepr(compact=true).len

                      of BeforeAndAfterValueMode:
                        valueCharactersLength += before.textRepr(compact=true).len + after.textRepr(compact=true).len

                      if valueWidth < width:
                        valueWidth = width

                if maxWidth < valueWidth and valueWidth <= LIMIT_WIDTH:
                  maxWidth = valueWidth

          group.loopWidths[id] = loopList
          group.loopFinal[id] = final

        if id == group.focusedLoopID:
          group.baseWidth = maxWidth

      self.calculateInternal(group, focused, width)

      self.recalculate = false
      group.lastCalculationID = group.focusedLoopID

      while baseID != -1:
        var baseIteration = -1
        var baseWidth = 0.0
        var final = 0.0

        for i in base.internal:
          let element = self.flow.loops[i]

          if element.baseIteration != baseIteration:
            if not group.loopWidths.hasKey(baseID):
              group.loopWidths[baseID] = @[]

            var loopList = group.loopWidths[baseID]

            baseWidth = group.loopFinal[i]
            loopList.setLen(element.baseIteration + 1)
            loopList[element.baseIteration] = baseWidth
            final += baseWidth
            baseIteration = element.baseIteration
            baseWidth = 0.0

        group.loopFinal[baseID] = final
        baseID = base.base

        if baseID != -1:
          base = self.flow.loops[baseID]

func calculateInternal(self: FlowComponent, group: Group, loop: Loop, width: float) =
  # calculate layout for internal loops
  for internalID in loop.internal:
    var internalLoop = self.flow.loops[internalID]

    if internalLoop.iteration > 0:
      var internalWidth = width / internalLoop.iteration.float
      var loopList: seq[float] = @[]
      var final = 0.0

      for i in 0 ..< internalLoop.iteration:
        loopList.add(internalWidth)
        final += internalWidth

      group.loopWidths[internalID] = loopList
      group.loopFinal[internalID] = final

      self.calculateInternal(group, internalLoop, internalWidth)

func startWidth*(self: FlowComponent, group: Group, loopID: int, i: int): float =
  var width = 0.0
  var loop = self.flow.loops[loopID]

  for id, otherLoop in self.flow.loops:
    if otherLoop.base == loop.base and id < loopID:
      for a in 0 ..< otherLoop.iteration:
        if a < group.loopWidths[id].len:
          width += group.loopWidths[id][a] * group.baseWidth # error

  for a in 0 ..< i:
    if a < group.loopWidths[loopID].len:
      width += group.loopWidths[loopID][a] * group.baseWidth

  return width

func startWidth*(self: FlowComponent, loopID: int): float =
  var group = self.lineGroups[self.flow.loops[loopID].first]
  return self.startWidth(group, loopID, 0)

proc renderFlow*(self: FlowComponent, position: int, stepCount: int): VNode =
  if stepCount notin self.flow.steps.low .. self.flow.steps.high:
    return
  var step = self.flow.steps[stepCount]

  if step.loop == -1:
    result = buildHtml(
      tdiv(
        class = fmt"flow-parallel flow-parallel-value-single",
        style=self.flowLeftStyle()
      )
    ):
      var style = style()
      var i = 0

      for name in step.exprOrder:
        flowSimpleValue(self, name, step.beforeValues[name], step.afterValues[name], stepCount, true, style, i)
        i += 1

    return

  let firstLoopID = step.loop
  let firstHeader = self.flow.loops[firstLoopID].first == position
  let firstLoop = self.flow.loops[firstLoopID]

  self.calculateLayout()

  var loops: seq[(int, Loop)]
  if firstLoop.base == -1:
    loops.add((firstLoopID, firstLoop))
  else:
    var firstBase = firstLoop.base
    var baseLoop = self.flow.loops[firstBase]
    for internal in baseLoop.internal:
      var internalLoop = self.flow.loops[internal]
      loops.add((internal, internalLoop))

  var group = self.lineGroups[position]
  var values: seq[cstring] = @[]
  var valueLines: seq[seq[cstring]] = @[]
  var loopClass = ""

  if self.data.config.realFlowUI != FlowMultiline:
    for name, value in step.beforeValues:
      values.add(name)

    valueLines = @[values]
    loopClass = "flow-loop-line"
  else:
    self.ensureTokens(position)

    for label, left in self.editorUI.tokens[position]:
      values = @[label]
      valueLines.add(values)

    loopClass = "flow-loop-multiline"

  let domElement = self.editorUI.monacoEditor.domElement
  let monacoEditorWidth = cast[kdom.Element](domElement).clientWidth
  let visibleWidth = monacoEditorWidth.float - (self.maxFlowLineWidth + 11).float * 13.0 - 70 # iteration info is 70

  result = buildHtml(tdiv(class=loopClass))

  for values in valueLines:
    if self.data.config.realFlowUI == FlowMultiline and not self.multilineZones[position].variables[values[0]]:
      continue

    var lineClass = ""

    if not group.isNil and self.flow.loops[group.focusedLoopID].first == position:
      lineClass = "flow-loop-first-line"

    var res = buildHtml(
      tdiv(
        class = &"flow-parallel flow-parallel-loop {lineClass}",
        style=flowLeftStyle(self)
      )
    ):
      if not group.isNil and self.flow.loops[group.focusedLoopID].first == position:
        moveButtonsView(self, visibleWidth)

      if self.data.config.realFlowUI != FlowMultiline:
        iterationInfoView(self, position, values)

    for (loopID, loop) in loops:
      var index = 0
      
      if not self.flow.positionStepCounts.hasKey(position):
        index += 1

        continue

      for step in self.flow.positionStepCounts[position]:
        if step == stepCount.int:
          break

        index += 1

      var hasLoop = false
      var html = buildHtml(
        tdiv(
          class = &"flow-parallel-loop-values loop-{loopID.int}",
          onscroll = proc(ev: Event, node: VNode) =
            discard
        )
      ):
        tdiv(class="flow-parallel-group"):
          for i in 0 ..< loop.iteration:
            if group.isNil:
              break
            if index < self.selectedIndex:
              index += 1
              continue

            hasLoop = true
            let width = 
              if self.valueMode == BeforeAndAfterValueMode:
                group.loopWidths[loopID][i] * group.baseWidth * 2 + 21
              else:
                (group.loopWidths[loopID][i] * group.baseWidth)
            let columnStyle = style(
              (StyleAttr.width, j($width & "px")))

            # change class on width change to make sure it's re-rendered
            let flowWidthClass = fmt"flow-parallel-values-width-{width}"

            tdiv(
              id = &"flow-values-{position}-{loopID.int}-{index}",
              class = &"flow-parallel-values {flowWidthClass}",
              style=columnStyle
            ):
              if not self.flow.positionStepCounts.hasKey(position):
                continue

              if index >= self.flow.positionStepCounts[position].len:
                break

              let currentStepCount = self.flow.positionStepCounts[position][index]

              if currentStepCount notin self.flow.steps.low .. self.flow.steps.high:
                break

              let currentStep = self.flow.steps[currentStepCount]

              index += 1

              var style = style()

              for name in values:
                if not currentStep.beforeValues.hasKey(name) or not currentStep.afterValues.hasKey(name):
                  span(class = &"flow-parallel-value", style=style):
                    text "no value"
                else:
                  flowSimpleValue(
                    self,
                    name,
                    currentStep.beforeValues[name],
                    currentStep.afterValues[name],
                    currentStepCount,
                    false,
                    style
                  )
      if hasLoop:
        res.add(html)

    result.add(res)

proc resizeFlowSlider*(self: FlowComponent) =
  self.shouldRecalcFlow = false

  for position, loop in self.flowLoops:
    loop.sliderDom.applyStyle(self.loopSliderStyle(position))

proc redrawFlow*(self: FlowComponent) =
  self.clear()
  self.recalculateAndRedrawFlow()

  for zone in self.flowLoops:
    if not zone.flowZones.isNil:
      zone.flowZones.dom.style.toJs.left = self.leftPos

proc updateFlowOnMove*(self: FlowComponent, rrTicks: int, line: int) =
  let debuggerLocationRRTicks = rrTicks
  let debuggerLocationLine = line

  self.setLoopStatesActiveIteration(debuggerLocationRRTicks)

  for position, line in self.flowLines:
    self.setFlowLineActiveIteration(position)

  let activeLoopStepDoms = cast[seq[Element]](jqAll(".active-flow-step"))

  for element in activeLoopStepDoms:
    element.classList.toJs.remove("active-flow-step")

  for line, flowLine in self.flowLines:
    let activeLoop = flowLine.activeLoopIteration.loopIndex
    let activeIteration = flowLine.activeLoopIteration.iteration

    # add "active" class to step containers of the steps of the active loop iteration
    if self.loopStates.hasKey(activeLoop) and not flowLine.stepLoopCells.isUndefined:
      let loopContainer = self.loopStates[activeLoop].containerDoms[line]
      let activeIterationStep = self.flow.steps[flowLine.loopStepCounts[activeLoop][activeIteration]]
      let activeIterationStepDom = flowLine.stepLoopCells[activeLoop][activeIteration]

      if not activeIterationStepDom.isNil:
        activeIterationStepDom.toJs.classList.toJs.add("active-flow-step")
        flowLine.activeIterationPosition =
          self.getStepDomOffsetLeft(activeIterationStep)
        if flowLine.activeIterationPosition > self.maxLoopActiveIterationOffset:
          self.maxLoopActiveIterationOffset = flowLine.activeIterationPosition

    case self.data.config.realFlowUI:
    of FlowMultiline:
      # change multiline flow values
      if self.multilineValuesDoms.hasKey(line):
        for expression, node in self.multilineValuesDoms[line]:
          let steps = self.flow.steps.filterIt(
            it.position == line and
            it.loop == activeLoop and
            it.iteration == activeIteration)
          if steps.len > 0:
            let step = steps[0]
            discard jsDelete(node.findNodeInElement(".flow-multiline-value"))
            let valueVNode = flowSimpleValue(
              self,
              expression,
              step.beforeValues[expression],
              step.afterValues[expression],
              step.stepCount,
              false,
              style())
            node.appendChild(vnodeToDom(valueVNode, KaraxInstance()))

    of FlowInline:
      # change inline flow values
      if flowLine.decorationsIds.len > 0:
        for expression, node in flowLine.decorationsDoms:
          let steps = self.flow.steps.filterIt(
            it.position == line and
            it.loop == activeLoop and
            it.iteration == activeIteration)
          if steps.len > 0:
            let step = steps[0]
            node.innerHTML = ""
            let valueVNode = flowSimpleValue(
              self,
              expression,
              step.beforeValues[expression],
              step.afterValues[expression],
              step.stepCount,
              false,
              style())
            node.appendChild(vnodeToDom(valueVNode, KaraxInstance()))

    else:
      discard

  if self.flowLines.hasKey(debuggerLocationLine):
    let flowLineAtLocation = self.flowLines[debuggerLocationLine]
    let activeLoopAtLocation =
      flowLineAtLocation.activeLoopIteration.loopIndex
    let activeIterationAtLocation =
      flowLineAtLocation.activeLoopIteration.iteration
    let activeLoopFirstLine = self.flow.loops[activeLoopAtLocation].first

    self.move(activeLoopAtLocation,
              activeIterationAtLocation,
              activeLoopFirstLine)

    let activeLoopBaseIteration = self.flow.loops[activeLoopAtLocation].baseIteration
    var sliderPositionsCount = 0

    if activeLoopBaseIteration == -1:
      sliderPositionsCount = activeIterationAtLocation
    else:
      let iterationRatio =
        activeIterationAtLocation.float / self.flow.loops[activeLoopAtLocation].iteration.float
      sliderPositionsCount =
        self.calculateSliderPosition(activeLoopFirstLine, activeLoopBaseIteration, iterationRatio)

    self.flowLines[activeLoopFirstLine].sliderDom.toJs.noUiSlider.set(sliderPositionsCount)


method onCompleteMove*(self: FlowComponent, response: MoveState) {.async.} =
  # self.updateFlowOnMove(response.location.rrTicks, response.location.line)
  self.redrawFlow()

method onLoadedFlowShape*(self: Component, update: FlowShape) {.async.} =
  discard

proc switchFlowType*(self: FlowComponent, flowType: FlowUI) =
  if self.data.config.realFlowUI != flowType:
    self.resetFlow()
    self.data.config.realFlowUI = flowType
    self.recalculateAndRedrawFlow()
    self.updateFlowDom()

