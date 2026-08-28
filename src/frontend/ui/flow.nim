import
  strutils, os,
  ui_imports,
  value, scratchpad,
  ../[ renderer, communication, dap, event_helpers],
  ../lib/isonim_styles,
  ../../common/ct_event,
  origin_chain_runtime,
  # Pure loop-iteration arithmetic, factored out so it is testable on the C
  # backend — this module is JS-only. See flow_loop_math.nim.
  flow_loop_math,
  # noUiSlider's construction, its zero-width refusal and its idempotency
  # marker, shared with the review's loop control (UD-3). See
  # flow_loop_slider.nim.
  flow_loop_slider,
  # The Omniscience value chip and the parallel column band, factored out so
  # the review's diff tab draws the same elements rather than a look-alike
  # (UD-3, DeepReview-GUI.md §4.4). See flow_value_dom.nim.
  flow_value_dom

from trace import getConfiguration

# ---------------------------------------------------------------------------
# ViewModel layer — wired in parallel with the legacy event-bus code.
# The FlowVM receives the same data but does not affect rendering yet.
# ---------------------------------------------------------------------------
import std/json
from ../viewmodel/backend/backend_service import BackendService, BackendFuture
import ../viewmodel/store/replay_data_store
from ../viewmodel/viewmodels/flow_vm import
  FlowVM, createFlowVM
# The renderer-neutral half of Omniscience's layout — expression columns,
# legend columns, indentation, per-line grouping, loop iteration windowing and
# the before/after value modes. It was extracted OUT of this file so that a
# renderer which is not Monaco can drive the feature from `FlowVM` alone
# (CodeTracer-Embed-SDK.md §3.2 excludes Monaco and "any rendering"); what is
# left here is view-zone lifecycle, noUiSlider, Karax and Monaco decorations.
# This file now CALLS that module rather than carrying a second copy, which is
# what keeps the desktop and any other surface from drifting apart.
from ../viewmodel/viewmodels/flow_layout import
  FlowValueMode, fvmBefore, fvmAfter, fvmBeforeAndAfter, resolveFlowValueMode,
  FlowExpressionColumn, findExpressionColumn, fallbackExpressionColumn,
  orderExpressionsByColumn, inlineLabelAnchorColumn,
  FlowTokenLanguage, flowTokenLanguage, nimFlowTokenLanguage,
  FlowSourceToken, tokenizeSourceExpressions,
  stepIndexForTicks, orderIterationSteps, firstBodyStepIn,
  closestIterationStepCount, FlowLayoutLoop
from isonim/web/dom_api import nil
from ../viewmodel/views/isonim_flow_view import
  mountIsoNimFlow

proc removeMonacoViewZone(editor: MonacoEditor, zoneId: int) {.importjs: """
  #.changeViewZones(function(accessor) {
    accessor.removeZone(#);
  })
""".}

proc addMonacoViewZone(editor: MonacoEditor, zone: js): int {.importjs: """
  (function() {
    let zoneId = 0;
    #.changeViewZones(function(accessor) {
      zoneId = accessor.addZone(#);
    });
    return zoneId;
  })()
""".}

proc layoutMonacoViewZone(editor: MonacoEditor, zoneId: int) {.importjs: """
  #.changeViewZones(function(accessor) {
    accessor.layoutZone(#);
  })
""".}

proc appendToDocumentBody(node: dom_api.Node) {.importjs: "document.body.appendChild(#)".}

# Module-level FlowVM instance. Created once and fed data whenever
# the legacy event-bus handlers fire. Rendering still reads from legacy
# data so behaviour is unchanged.
var flowVMInstance: FlowVM
var flowVMStore: ReplayDataStore
var isoNimFlowMounted*: bool = false

when defined(js):
  proc setTimeoutWithArg[T](cb: proc(x: T) {.cdecl.}, delay: int, arg: T) {.importjs: "setTimeout(#, #, #)".}

proc tryMountIsoNimFlowPanel()

proc flowIsLive*(self: FlowComponent): bool =
  ## Whether this component is still the editor's current flow.
  ##
  ## `EditorViewComponent.loadFlow` builds a NEW `FlowComponent` for every move
  ## and flags the outgoing one as `superseded`. Anything that repaints — the
  ## deferred redraw and the loop-iteration value render passes, both of which
  ## run on `setTimeout` and therefore outlive the assignment that replaced the
  ## component — must check this first. A retired component that keeps
  ## repainting re-creates Monaco view zones the live component does not know
  ## about and paints the previous debugger position's iteration over the
  ## current one; see the comment on `superseded` in `types.nim` and #593/#595.
  ##
  ## Reading (rather than painting) on a retired component is fine, and is what
  ## keeps the loop arrows usable in the gap before the replacement renders.
  not self.superseded

proc validFlowStepCount*(self: FlowComponent, stepCount: int): bool =
  ## Whether `stepCount` addresses a step of the CURRENT flow window.
  ##
  ## Step counts are window-relative indices into `flow.steps`, and the window
  ## is replaced on every debugger move, so any step count that was stored
  ## earlier (in `flowLines[..].loopStepCounts`, in a `FlowLoop.loopStep`, in a
  ## DOM closure) has to be revalidated before it is used as an index.
  not self.flow.isNil and stepCount >= 0 and stepCount < self.flow.steps.len

# ---------------------------------------------------------------------------
# ViewModel bridge procs — sync legacy event data into the parallel store.
# ---------------------------------------------------------------------------

proc initFlowVMWithStore*(store: ReplayDataStore) =
  ## Initialise the parallel FlowVM using an externally-provided
  ## ReplayDataStore (typically the shared store from SessionViewModel).
  ##
  ## If a stub-backed instance already exists (created by initFlowVM
  ## before the real backend was available), it is replaced so that the
  ## panel uses the real DapApi instead of the no-op stub.
  if flowVMInstance != nil:
    clog "FlowVM: replacing existing instance with shared-store version"
    isoNimFlowMounted = false
  flowVMStore = store
  flowVMInstance = createFlowVM(store)
  clog "FlowVM: parallel ViewModel instance created (shared store)"
  tryMountIsoNimFlowPanel()

proc initFlowVM() =
  ## Lazily create the parallel FlowVM backed by a stub
  ## BackendService.  Fallback when no shared store has been provided
  ## via `initFlowVMWithStore`.
  if flowVMInstance != nil:
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

  flowVMStore = createReplayDataStore(stubBackend)
  flowVMInstance = createFlowVM(flowVMStore)
  clog "FlowVM: parallel ViewModel instance created (stub backend)"
  tryMountIsoNimFlowPanel()

proc syncFlowDebuggerPosition(rrTicks: int, path: cstring, line: int;
                              sourceGeneration: int = 0;
                              sourceDigest: cstring = cstring"") =
  ## Mirror the legacy debugger position into the ViewModel store so
  ## the FlowVM's auto-load effect fires with the updated rrTicks.
  if flowVMStore.isNil:
    return
  let ticks = cast[uint64](rrTicks)
  flowVMStore.updateDebuggerPosition(
    ticks, $path, line,
    sourceGeneration = sourceGeneration,
    sourceDigest = $sourceDigest)
  clog fmt"FlowVM: synced debugger rrTicks={ticks}"

proc jsQuerySelector(selector: cstring): dom_api.Element
  {.importcpp: "document.querySelector(#)".}
  ## Thin wrapper around `document.querySelector` for cases where
  ## the isonim dom_api does not expose this method.

type
  FlowMountData = ref object
    retryCount: int

proc doMountFlowPanel(data: FlowMountData) {.cdecl.} =
  if isoNimFlowMounted:
    return
  data.retryCount += 1
  let container = jsQuerySelector(cstring".flow-component-container")
  if dom_api.isNodeNil(dom_api.Node(container)):
    if data.retryCount > 100:
      clog "IsoNim flow panel: container not found after 100 retries, giving up"
      return
    setTimeoutWithArg(doMountFlowPanel, 0, data)
    return

  let containerNode = dom_api.Node(container)
  while not dom_api.isNodeNil(containerNode.firstChild):
    discard dom_api.removeChild(containerNode, containerNode.firstChild)

  isoNimFlowMounted = true
  mountIsoNimFlow(dom_api.Element(containerNode), flowVMInstance)
  clog "IsoNim flow panel: mounted as primary renderer in .flow-component-container"

proc tryMountIsoNimFlowPanel() =
  ## Mount the IsoNim flow panel view into the first
  ## `.flow-component-container` element in the DOM. The IsoNim view
  ## replaces existing Karax content and becomes the primary renderer,
  ## creating the container structure that the Monaco view zone
  ## integration code and noUiSlider attach to.
  ##
  ## After mounting:
  ## - `isoNimFlowMounted` is set to true
  ## - The Karax render() returns a minimal stub
  ## - The existing DOM manipulation code (createFlowViewZone,
  ##   makeSlider, addStepValues, etc.) continues to work on
  ##   the IsoNim-created containers
  ##
  ## Safe to call multiple times — mounts only once.
  if isoNimFlowMounted or flowVMInstance.isNil:
    return

  let mountData = FlowMountData(retryCount: 0)
  doMountFlowPanel(mountData)

# thank, God!
proc resizeLineSlider(self: FlowComponent, position: int)
proc shrinkLoopIterations*(self: FlowComponent, loopIndex: int)
proc createLoopViewZones(self: FlowComponent, loopIndex:int)
proc createFlowViewZone(self: FlowComponent, position: int, heightInPx: float, isLoop: bool = false): Node
proc positionRRTicksToStepCount*(self: FlowComponent, position: int, rrTicks: int): int
proc updateIterationStepCount*(self: FlowComponent, line: int, stepCount: int, loopId: int, iteration: int): int
proc reloadFlow*(self:FlowComponent)
proc addStepValues*(self: FlowComponent, step: FlowStep)
proc addComplexLoopStepValues(self: FlowComponent, step: FlowStep)
proc addMultilineLoopStep(self: FlowComponent, step: FlowStep, container: Node)
proc prepareFlowLineVariables(self: FlowComponent, step: FlowStep)
proc renderActiveLoopIterationValues(self: FlowComponent)
proc scheduleActiveLoopIterationValueRender*(self: FlowComponent)
proc redrawFlow*(self: FlowComponent)
proc resizeFlowSlider*(self: FlowComponent)
proc makeSlider(self: FlowComponent, position: int)
proc updateFlowOnMove*(self: FlowComponent, rrTicks: int, line: int)
proc makeLoopLine(self: FlowComponent, step: FlowStep, allIterations: int): Node

const
  SLIDER_OFFSET = 6 # in px
  FLOW_VALUE_LIMIT = 30
  FLOW_VALUE_MAX_WIDTH = fmt"{FLOW_VALUE_LIMIT}ch"

proc calculateMaxWidth*(self: FlowComponent, stepNodeWidth: int) =
  let editor = self.editorUI.monacoEditor
  let editorLayout = editor.config.layoutInfo
  let minimapWidth = editorLayout.minimapWidth

  self.maxWidth = max(
    self.maxWidth,
    stepNodeWidth
  )

proc adjustEditorWidth*(self: EditorViewComponent) =
  let path = self.tabInfo.name
  let options = cast[MonacoEditorOptions](self.monacoEditor.getOptions())

  for _, flowDom in self.flow.flowDom:
    if not flowDom.firstChild.isNil and not flowDom.firstChild.toJs.firstElementChild.isNil:
      self.flow.calculateMaxWidth(cast[Element](flowDom.firstChild.toJs.firstElementChild).clientWidth)

  let charWidth = data.ui.fontSize.float * 0.55
  let scrollBeyondLastColumn =
    self.flow.maxWidth

  options.scrollBeyondLastColumn = floor(scrollBeyondLastColumn.float / charWidth)
  self.monacoEditor.updateOptions(options)

proc getFlowValueMode(self: FlowComponent, beforeValue: Value, afterValue: Value): ValueMode =
  ## Which of the step's two values this label shows.
  ##
  ## The decision itself now lives in `viewmodel/viewmodels/flow_layout`, which
  ## has no `Value` and no DOM; what stays here is the three bits it needs and
  ## the mapping back onto the desktop's `ValueMode`. The branch order and the
  ## precedence of `testEq` over the nil checks are unchanged.
  case resolveFlowValueMode(
      hasBefore = not beforeValue.isNil,
      hasAfter = not afterValue.isNil,
      valuesEqual = testEq(beforeValue, afterValue))
  of fvmBefore: BeforeValueMode
  of fvmAfter: AfterValueMode
  of fvmBeforeAndAfter: BeforeAndAfterValueMode

when defined(ctInExtension):
  var flowComponentForExtension* {.exportc.}: FlowComponent = makeFlowComponent(data, 13, inExtension = true)

  proc bindFlowExtensionHost(component: FlowComponent) =
    if component.extensionRendererId.len == 0:
      return

    let host = document.getElementById(component.extensionRendererId)
    if host.isNil:
      return

    # The extension flow surface has no panel markup of its own; keep the
    # exported component usable without retaining an empty Karax renderer.
    host.innerHTML = cstring""

  proc makeFlowComponentForExtension*(id: cstring): FlowComponent {.exportc.} =
    if flowComponentForExtension.extensionRendererId.len == 0:
      flowComponentForExtension.extensionRendererId = id
      flowComponentForExtension.bindFlowExtensionHost()
    result = flowComponentForExtension

  method redrawForExtension*(self: FlowComponent) =
    self.bindFlowExtensionHost()

method register*(self: FlowComponent, api: MediatorWithSubscribers) =
  self.api = api
  api.subscribe(CtCompleteMove, proc(kind: CtEventKind, response: MoveState, sub: Subscriber) =
    # Feed the same position into the parallel ViewModel store.
    initFlowVM()
    syncFlowDebuggerPosition(
      response.location.rrTicks,
      response.location.path,
      response.location.line,
      response.location.sourceGeneration,
      response.location.sourceDigest)

    self.location = response.location
    # The legacy CtLoadFlow emit has been removed.  The
    # syncFlowDebuggerPosition call above updates the store's debugger
    # signal which triggers the FlowVM's auto-load effect.  That effect
    # sends the ct/load-flow command through the real backend, and the
    # response arrives via the existing CtUpdatedFlow subscription.
    self.redraw()
  )
  api.subscribe(CtUpdatedFlow, proc(kind: CtEventKind, response: FlowUpdate, sub: Subscriber) =
    # `onUpdatedFlow` decides internally whether a full `redrawFlow()` is
    # needed (key changed) or only an in-place value update (key unchanged).
    discard self.onUpdatedFlow(response)
  )

# FlowComponent.render() removed: IsoNim is the primary renderer.
# Generic callers are expected to use direct IsoNim mount paths. All
# real rendering is handled by tryMountIsoNimFlowPanel().


proc registerFlowComponent*(component: FlowComponent, api: MediatorWithSubscribers) {.exportc.} =
  component.register(api)

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

let FLOW_TOKEN_LANGUAGES: array[Lang, FlowTokenLanguage] = block:
  ## One `FlowTokenLanguage` profile per language, built at module init from
  ## `flowKeywords` in `common_lang.nim` — which remains the exhaustive `case`
  ## holding the data.
  ##
  ## The tokenizer itself moved to `viewmodel/viewmodels/flow_layout`
  ## (`tokenizeSourceExpressions`): source text in, `(expression, column)` out,
  ## which is a fact about a line of code and not about an editor. What stays
  ## here is the mapping from CodeTracer's `Lang` enum onto that profile, and
  ## `common_lang` stays out of the SDK's import graph as a result.
  ##
  ## `isSymbol` / `isStringSymbol` answered for `LangNim` only and `false` for
  ## every other language, so every other language gets EMPTY character sets and
  ## therefore an empty token list — exactly as before. That is a real
  ## limitation of the tokenizer and it is preserved rather than quietly widened
  ## by this refactor.
  var table: array[Lang, FlowTokenLanguage]
  for lang in Lang:
    if lang == LangNim:
      table[lang] = nimFlowTokenLanguage(flowKeywords(lang))
    else:
      table[lang] = flowTokenLanguage({}, {}, flowKeywords(lang))
  table

func tokenizeExpressions*(source: cstring, lang: Lang): seq[(cstring, int)] =
  ## Every expression in one source line, with its column, last first.
  ##
  ## The tokenizer is `flow_layout.tokenizeSourceExpressions`; this is the
  ## `cstring`/tuple shape `ensureTokens` reads.
  ##
  ## `{.noSideEffect.}` around the table read for the same reason the previous
  ## `KEYWORDS[lang]` reads carried it: `FLOW_TOKEN_LANGUAGES` is a module-level
  ## `let`, which Nim treats as a side effect to touch, and `ensureTokens` — the
  ## only caller — is itself a `func`.
  ##
  ## ONE representational difference from the version that lived here, bounded
  ## and checked rather than assumed away. The old loop walked the `cstring`
  ## directly, which on the JS backend indexes UTF-16 code units; `$source` is
  ## `cstrToNimstr`, so this one indexes UTF-8 bytes. The TOKENS are identical
  ## either way — every identifier and string-delimiter character in every
  ## profile is ASCII — but the COLUMN of a token that follows a non-ASCII
  ## character on the same line differs by that character's encoding delta.
  ##
  ## It is unobservable, and that is checkable rather than hopeful:
  ## `ensureTokens` stores the column as the VALUE of `editorUI.tokens[line]`,
  ## and both readers (`calculateLayout` and `renderFlow`, below) iterate that
  ## map for the label and discard the value. Nothing outside this file reads
  ## `editorUI.tokens` at all.
  result = @[]
  {.noSideEffect.}:
    for token in tokenizeSourceExpressions($source, FLOW_TOKEN_LANGUAGES[lang]):
      result.add((cstring(token.expression), token.column))

proc removeExpandedFlow(self: FlowComponent, line: int) =
  if self.multilineZones.hasKey(line):
    removeMonacoViewZone(self.editorUI.monacoEditor, self.multilineZones[line].zoneID)

proc registerScratchpadValue(self: ScratchpadComponent, expression: cstring, value: Value) =
  self.programValues.add((expression, value))
  self.values.add(ValueComponent(
    expanded: JsAssoc[cstring, bool]{},
    charts: JsAssoc[cstring, ChartComponent]{},
    showInline: JsAssoc[cstring, bool]{},
    baseExpression: expression,
    baseValue: value,
    nameWidth: VALUE_COMPONENT_NAME_WIDTH,
    valueWidth: VALUE_COMPONENT_VALUE_WIDTH,
    stateID: -1,
    data: self.data))

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

        self.redraw()

      else:
        if name == cstring"":
          for valueName, value in step.afterValues:
            self.scratchpadUI.registerScratchpadValue(valueName, value)
        else:
          if step.afterValues.hasKey(name):
            self.scratchpadUI.registerScratchpadValue(name, step.afterValues[name])

        self.redraw()

proc displayTooltip(self: FlowComponent, containerId: cstring, content: Node) =
  when not defined(server) and not defined(ctInCentralExtensionContext):
    let tippy = require("tippy.js")
    let followCursor = tippy.followCursor

    if not self.tippyElement.isNil:
      for tippy in self.tippyElement:
        tippy.destroy()
        self.tippyElement = nil

    if self.tippyElement.isNil:
      let obj = ui_imports.misc_lib.tippy(cstring(&"#{containerId}"), JsAssoc[cstring, JsObject]{
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
  result = document.createElement("div")
  result.setAttribute(cstring"id", cstring(&"flow-tooltip-value-{expression}"))
  result.setAttribute(cstring"class", cstring"flow-tooltip-value")
  result.appendChild(document.createTextNode(cstring(&"{expression}: {value}")))

proc tooltipStepInfo(step: FlowStep): Node =
  result = document.createElement("div")
  result.setAttribute(cstring"id", cstring(&"flow-tooltip-step-info-{step.stepCount}"))
  result.setAttribute(cstring"class", cstring"flow-tooltip-step-info")
  result.appendChild(document.createTextNode(cstring(&"Iteration: {step.iteration}")))

proc customRedraw(self: ValueComponent) =
  discard

proc renderModalValueDom(self: FlowComponent, containerId: cstring): Node =
  self.modalValueComponent[containerId].renderValueDom()

proc openTooltip*(self: FlowComponent, containerId: cstring, value: Value) =
  let valueDom = self.renderModalValueDom(containerId)

  self.tooltipId = containerId
  self.displayTooltip(containerId, valueDom)

func ensureTokens(self: FlowComponent, line: int) =
  if self.tab.isNil or self.tab.sourceLines.len == 0:
    return
  if line - 1 < 0 or line - 1 >= self.tab.sourceLines.len:
    return
  if not self.editorUI.tokens.hasKey(line):
    self.editorUI.tokens[line] = JsAssoc[cstring, int]{}
    let tokens = tokenizeExpressions(self.tab.sourceLines[line - 1], self.data.trace.lang)

    for (token, left) in tokens:
      if not self.editorUI.tokens[line].hasKey(token):
        if line != self.location.functionFirst:
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
          element.toJs.classList.add(cstring"refresh")

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
  if self.inExtension: return 0
  case self.data.config.flow.realFlowUI:
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

  case self.data.config.flow.realFlowUI:
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
  var containerId = &"flow-loop-container-{position}"
  var containerClass: cstring

  result = document.createElement(cstring"div")

  if nested:
    containerId = containerId & &"-{loopIndex}-{self.flow.loops[loopIndex].baseIteration}"
    let containerWidth = self.loopStates[loopIndex].totalLoopWidth
    containerClass = "flow-nested-loop-container"

    if position == self.flow.loops[loopIndex].first:
      setLoopContainerOffset(self, loopIndex)

    let flowLine = self.flowLines[position]
    let leftValue =
      self.loopStates[loopIndex].containerOffset - (flowLine.baseOffsetLeft.float - flowLine.offsetleft.float)

    result.style.width = cstring($containerWidth & "px")
    result.style.left = cstring($leftValue & "px")
  else:
    let containerProps = self.prepareFlowLineContainerProps(position)

    result.style.left = cstring($(containerProps.left) & "px")
    result.style.height = cstring($(containerProps.height) & "px")
    result.style.width = cstring($(containerProps.width) & "px")

    containerClass = "flow-loop-container"

  result.setAttribute(cstring"id", cstring(containerId))
  result.setAttribute(cstring"class", containerClass)
  result.appendChild(document.createTextNode(cstring""))

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
    case self.data.config.flow.realFlowUI:
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

    case self.data.config.flow.realFlowUI:
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
  ## Keep the slider of an inner loop's ORIGIN (outermost) loop in step with the
  ## iteration just selected on the inner one.
  ##
  ## Historical note: this proc also contained two loops over
  ## `self.sliderWidgets`, meant to move the sliders of the *sibling* lines
  ## inside the same loop. `sliderWidgets` is only ever written by
  ## `addContentWidget(..., isSliderWidget = true)`, which has no call site
  ## anywhere in the codebase, so that map was permanently empty and both loops
  ## were unconditional no-ops. They have been removed along with the map rather
  ## than left in place looking functional. Reviving sibling-slider
  ## synchronisation is a separate change: `flowLines` cannot simply be
  ## substituted as the iteration source, because it also contains lines with no
  ## slider at all and the sibling updates would need their own coverage.
  let loop = self.flow.loops[loopIndex]
  let originLoopId = self.getOriginLoopIndex(loopIndex)

  if originLoopId != loopIndex:
    let originLoop = self.flow.loops[originLoopId]
    let originLoopIteration = loop.baseIteration
    self.flowLines[originLoop.first].sliderPosition =
      (loopIndex: originLoopId, iteration: originLoopIteration)
    if not self.flowLines[originLoop.first].sliderDom.isNil and not self.flowLines[originLoop.first].sliderDom.toJs.noUiSlider.isNil:
      self.flowLines[originLoop.first].sliderDom.toJs.noUiSlider.set(originLoopIteration)

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
    #
    # `loopStepCounts` is filled while rendering, and both its per-loop entry
    # and the step count it yields are indices into the flow window that was
    # current at that time. A move replaces the window, so neither index can be
    # assumed to be in range here — an out-of-range one used to raise an
    # `IndexDefect` that escaped `updateFlowOnMove` and abandoned the rest of
    # the render pass (leaving the editor's cursor and decorations at the
    # previous position, #593).
    if self.loopStates.hasKey(loopIndex) and
       flowLine.loopStepCounts.hasKey(loopIndex) and
       iteration >= 0 and iteration < flowLine.loopStepCounts[loopIndex].len and
       self.validFlowStepCount(flowLine.loopStepCounts[loopIndex][iteration]):
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
    ($self.data.config.flow.realFlowUI)
      .substr(4, ($self.data.config.flow.realFlowUI).len - 1)
      .toLowerAscii()

  for stepKey, stepNode in self.stepNodes:
    # `stepNodes` is keyed by step count, i.e. by an index into the flow window
    # that was current when the node was created (see `validFlowStepCount`).
    if not self.validFlowStepCount(stepKey):
      continue
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
              valueContainer.style.textAlign = cstring"left"
            else:
              valueContainer.style.textIndent = cstring""
              valueContainer.style.textAlign = cstring""

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

  self.redraw()

proc moveLeft*(self: FlowComponent) =
  if self.selectedIndex > 0:
    self.selectedIndex -= 1
    self.selectedStepCount = self.findStepCount()
    self.selectedGroup.visibleStart = self.selectedIndex.float * self.selectedGroup.baseWidth

    self.redraw()


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

proc jumpToLocalStep*(self: FlowComponent, path: cstring, line: int, stepCount: int, iteration: int, rrTicks: int = -1, reverse: bool = false) =
  # (line, rr ticks) => all steps that correspond to those rr ticks and line
  # if two steps same lines rr ticks it means jump without changing rr ticks..
  # hard to believe
  let firstLoopLine = if path.len > 0 and not self.editorUI.isNil and not self.editorUI.flow.isNil:
      let flow = self.flow
      let loopId = flow.steps[stepCount].loop
      flow.loops[loopId].first
    else:
      # e.g. step list jump for now
      -1

  let activeIteration = if self.loopStates.hasKey(line):
      self.loopStates[line].activeIteration
    else:
      0

  self.api.emit(
    CtLocalStepJump,
    LocalStepJump(
      path: path,
      line: line,
      stepCount: stepCount,
      targetIteration: iteration,
      firstLoopLine: firstLoopLine,
      rrTicks: rrTicks,
      reverse: reverse,
      activeIteration: activeIteration
    )
  )
  self.api.emit(InternalNewOperation, NewOperation(name: "local step jump", stableBusy: true))

proc afterJump(self: FlowComponent, stepCount: int) =
  let step = self.flow.steps[stepCount]
  let location = self.location
  let currentStep = self.positionRRTicksToStepCount(location.highLevelLine, location.rrTicks)
  let reverse = if stepCount >= currentStep: false else: true

  let currentTime: int64 = now()
  let lastTimePlusDelay = (self.lastScrollFireTime.toJs + DELAY.toJs).to(int64)

  if lastTimePlusDelay <= currentTime:
    self.redrawFlow()
    self.jumpToLocalStep(self.location.path, step.position, stepCount, step.iteration, step.rrTicks, reverse)


proc jumpToLocalStep*(self: FlowComponent, stepCount: int) =
  let currentTime: int64 = now()

  self.lastScrollFireTime = currentTime

  discard windowSetTimeout(
    proc =
      self.afterJump(stepCount),
      cast[int](DELAY)
  )

proc invalidFlowStep(): FlowStep =
  FlowStep(position: NO_LINE, loop: NO_STEP_COUNT, stepCount: NO_STEP_COUNT, rrTicks: NO_TICKS)

proc loopIterationStepAt(
  self: FlowComponent,
  loopIndex: int,
  iteration: int,
  position: int
): FlowStep =
  if loopIndex < 0 or loopIndex >= self.flow.loopIterationSteps.len:
    return invalidFlowStep()
  if iteration < 0 or iteration >= self.flow.loopIterationSteps[loopIndex].len:
    return invalidFlowStep()

  let table = self.flow.loopIterationSteps[loopIndex][iteration].table
  if not table.hasKey(position):
    return invalidFlowStep()

  let stepCount = table[position]
  if not self.validFlowStepCount(stepCount):
    return invalidFlowStep()

  self.flow.steps[stepCount]

proc firstLoopBodyStepForIteration(
  self: FlowComponent,
  loopIndex: int,
  iteration: int
): FlowStep =
  if loopIndex < 0 or loopIndex >= self.flow.loops.len:
    return invalidFlowStep()
  if loopIndex >= self.flow.loopIterationSteps.len:
    return invalidFlowStep()
  if iteration < 0 or iteration >= self.flow.loopIterationSteps[loopIndex].len:
    return invalidFlowStep()

  let loop = self.flow.loops[loopIndex]
  let table = self.flow.loopIterationSteps[loopIndex][iteration].table
  # The "lowest body line of this pass" search is
  # `flow_layout.firstBodyStepIn`; flattening the `JsAssoc` table is this
  # file's, because the table type differs between the two worlds.
  var entries: seq[tuple[line: int, stepCount: int]] = @[]
  for line, stepCount in table:
    entries.add((line: line, stepCount: stepCount))

  let selectedStepCount =
    firstBodyStepIn(entries, loop.first, loop.last, self.flow.steps.len)

  if selectedStepCount == NO_STEP_COUNT:
    return self.loopIterationStepAt(loopIndex, iteration, loop.first)

  self.flow.steps[selectedStepCount]

proc jumpToFlowStep(self: FlowComponent, targetStep: FlowStep) =
  if targetStep.stepCount == NO_STEP_COUNT or targetStep.rrTicks == NO_TICKS:
    return

  let currentStepCount =
    self.positionRRTicksToStepCount(self.location.highLevelLine, self.location.rrTicks)
  let reverse =
    currentStepCount != NO_STEP_COUNT and targetStep.stepCount < currentStepCount

  self.activeStep = targetStep
  self.jumpToLocalStep(
    self.location.path,
    targetStep.position,
    targetStep.stepCount,
    targetStep.iteration,
    targetStep.rrTicks,
    reverse)

proc selectLoopIteration(
  self: FlowComponent,
  loopIndex: int,
  iteration: int,
  registeredLine: int
) =
  # Take ownership of the active iteration immediately.
  #
  # `loopStates[..].activeIteration` is the single source of truth the loop
  # counter, the arrows and the slider all read. Until the debugger reports the
  # completed move, `setLoopStatesActiveIteration` has not run yet; without this
  # write there is a window in which the user has clicked but every reader still
  # sees the old iteration, so a second click computes its target from a stale
  # value and appears to skip (#595). The subsequent move recomputes it from the
  # debugger's ticks and will agree.
  if self.loopStates.hasKey(loopIndex):
    self.loopStates[loopIndex].activeIteration = iteration

  let loopStep = self.loopIterationStepAt(loopIndex, iteration, registeredLine)
  if loopStep.stepCount != NO_STEP_COUNT:
    if self.flowLoops.hasKey(registeredLine):
      self.flowLoops[registeredLine].loopStep = loopStep
    self.activeStep = loopStep
    self.renderActiveLoopIterationValues()
    # Do not call scheduleActiveLoopIterationValueRender here: the slider's
    # onUpdate handler already calls it after this returns, and a second
    # schedule would queue redundant timers on every slider tick.

  # Jump to the FIRST STATEMENT of the selected iteration, not to the `for` /
  # `while` header line.
  #
  # `codetracer-specs/GUI/Debugging-Features/Omniscience-Flow.md` lists
  # `NoirSpaceShip.SimpleLoopIterationJump` — "Enter iteration number, verify
  # cursor" — among its implemented tests: selecting an iteration is a
  # navigation, and what the user must end up looking at is the iteration's
  # code, not the loop condition they were already on.
  #
  # This is safe for the iteration arithmetic even though the backend counts an
  # iteration only when the flow walker passes the loop header: `FlowMode.Call`
  # returns the window of the whole enclosing call, so the header of every
  # iteration — including the ones behind the cursor — is inside it, and
  # `rrTicksForIterations` is identical no matter where in the call the cursor
  # sits. `activeIterationForTicks` then maps a body tick onto the containing
  # header interval, which is exactly the iteration we selected.
  # `src/db-backend/tests/flow_loop_iteration_window_test.rs` pins that window
  # invariance.
  let bodyStep = self.firstLoopBodyStepForIteration(loopIndex, iteration)
  if bodyStep.stepCount != NO_STEP_COUNT:
    self.jumpToFlowStep(bodyStep)
  elif loopStep.stepCount != NO_STEP_COUNT:
    # No body statement recorded for this iteration (an empty body, or a
    # recorder that only emits the header) — the header is then the only place
    # the iteration exists.
    self.jumpToFlowStep(loopStep)


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
      self.api.openValueInScratchpad(ValueWithExpression(expression: name, value: beforeValue))
      data.redraw()
  )

  contextMenu &= addToScratchpad

  addAllValuesToScratchpad = ContextMenuItem(
    name: "Add all values to scratchpad",
    hint: "",
    handler: proc(e: Event) =
      for key, value in step.beforeValues:
        self.api.openValueInScratchpad(ValueWithExpression(expression: key, value: value))
      data.redraw()
  )

  contextMenu &= addAllValuesToScratchpad

  return contextMenu

proc ensureValueComponent(self: FlowComponent, id: cstring, name: cstring, value: Value) =
  self.modalValueComponent[id] =
    ValueComponent(
      api: self.api,
      expanded: JsAssoc[cstring, bool]{$name: true},
      charts: JsAssoc[cstring, ChartComponent]{},
      showInLine: JsAssoc[cstring, bool]{},
      baseExpression: name,
      baseValue: value,
      stateID: -1,
      nameWidth: VALUE_COMPONENT_NAME_WIDTH,
      valueWidth: VALUE_COMPONENT_VALUE_WIDTH,
      data: data,
      isTooltipValue: true,
    )

proc flowEventValue*(self: FlowComponent, event: FlowEvent, stepCount: int, style: VStyle, i: int): Node =
  let flowMode =
    ($self.data.config.flow.realFlowUI)
      .substr(4, ($self.data.config.flow.realFlowUI).len - 1)
      .toLowerAscii()
  let before = &"flow-{flowMode}-value-before-only"

  let (nameClassSuffix, valueClass, name) =
    case event.kind:
    of EventLogKind.Error:
      ("-error", "flow-error-box", "error")
    of EventLogKind.Write:
      ("-std", "flow-std-default-box", "stdout")
    of EventLogKind.WriteFile:
      ("-std", "flow-std-default-box", "stdout")
    of EventLogKind.Read:
      ("-std", "flow-std-default-box", "stdin")
    of EventLogKind.ReadFile:
      ("-std", "flow-std-default-box", "stdin")
    of EventLogKind.EvmEvent:
      ("-std", "flow-std-default-box", $event.metadata)
    else:
      ("", "", "")

  result = document.createElement(cstring"span")
  result.setAttribute(cstring"class", cstring"ct-omni-value")
  result.applyStyle(style)

  if event.text.len() > FLOW_VALUE_LIMIT:
    let viewMore = document.createElement(cstring"span")
    viewMore.setAttribute(cstring"class", cstring(&"ct-omni-name{nameClassSuffix} flow-view-more-button flow-hide-content"))
    viewMore.applyStyle(style)
    viewMore.addEventListener(cstring"mousedown", proc(e: Event) =
      let targetId = &"flow-{flowMode}-value-box-{stepCount}-{i}"
      let target = document.getElementById(targetId)
      if not target.isNil:
        if target.style.maxWidth != "none":
          target.style.maxWidth = "none"
          e.target.toJs.classList.remove("flow-hide-content")
          e.target.toJs.classList.add("flow-show-content")
        else:
          e.target.toJs.classList.remove("flow-show-content")
          e.target.toJs.classList.add("flow-hide-content")
          target.style.maxWidth = FLOW_VALUE_MAX_WIDTH
        self.maxWidth = 0
        self.editorUI.adjustEditorWidth()
    )
    result.appendChild(viewMore)

  let nameSpan = document.createElement(cstring"span")
  nameSpan.setAttribute(cstring"class", cstring(&"ct-omni-name{nameClassSuffix}"))
  nameSpan.addEventListener(cstring"mousedown", proc(e: Event) =
    self.jumpToLocalStep(stepCount)
  )
  nameSpan.appendChild(document.createTextNode(cstring(&"<{name}>")))
  result.appendChild(nameSpan)

  let valueSpan = document.createElement(cstring"span")
  valueSpan.setAttribute(cstring"id", cstring(&"flow-{flowMode}-value-box-{stepCount}-{i}"))
  valueSpan.applyStyle(style)
  if event.text.len() > FLOW_VALUE_LIMIT:
    valueSpan.style.maxWidth = FLOW_VALUE_MAX_WIDTH
  valueSpan.setAttribute(cstring"iteration", cstring($(self.flow.steps[stepCount].iteration)))
  valueSpan.setAttribute(cstring"class", cstring(&"flow-{flowMode}-value-box {valueClass} " & before))
  valueSpan.addEventListener(cstring"mousedown", proc(e: Event) =
    self.jumpToLocalStep(stepCount)
  )
  # flowEventValue intentionally has no tooltip/modal behavior. Normal
  # flow values centralize modal materialization in renderModalValueDom.
  valueSpan.appendChild(document.createTextNode(event.text))
  result.appendChild(valueSpan)


proc flowSimpleValue*(
  self: FlowComponent,
  name: cstring,
  beforeValue: Value,
  afterValue: Value,
  stepCount: int,
  showName: bool,
  style: VStyle,
  i: int = 0,
): Node =
  let flowMode =
    ($self.data.config.flow.realFlowUI)
      .substr(4, ($self.data.config.flow.realFlowUI).len - 1)
      .toLowerAscii()
  let flowValueMode = self.getFlowValueMode(beforeValue, afterValue)

  proc renderViewOption(): Node =
    result = document.createElement(cstring"span")
    result.setAttribute(cstring"class", cstring(&"flow-{flowMode}-value-name flow-view-more-button flow-hide-content"))
    result.applyStyle(style)
    result.addEventListener(cstring"mousedown", proc(e: Event) =
      let targetId = &"flow-{flowMode}-value-box-{i}-{stepCount}-{name}"
      let target = document.getElementById(targetId)
      if not target.isNil:
        if target.style.maxWidth != "none":
          target.style.maxWidth = "none"
          e.target.toJs.classList.remove("flow-hide-content")
          e.target.toJs.classList.add("flow-show-content")
        else:
          e.target.toJs.classList.remove("flow-show-content")
          e.target.toJs.classList.add("flow-hide-content")
          target.style.maxWidth = FLOW_VALUE_MAX_WIDTH
      self.maxWidth = 0
      self.editorUI.adjustEditorWidth()
    )

  proc onMouseDown(e: Event, value: Value) =
    e.stopPropagation()

    if cast[MouseEvent](e).button == 0:
      if cast[bool](e.toJs.ctrlKey):
        self.api.openValueInScratchpad(ValueWithExpression(expression: name, value: value))
        data.redraw()
      else:
        self.jumpToLocalStep(stepCount)

  proc onContextMenu(e: Event, value: Value) =
    e.stopPropagation()

    let step = self.flow.steps[stepCount]
    let contextMenu = createContextMenuItems(self, name, value, stepCount)

    if contextMenu != @[]:
      showContextMenu(contextMenu, cast[int](e.toJs.clientX), cast[int](e.toJs.clientY))

  proc appendValueSpan(parent: Node, id: cstring, className: string, value: Value) =
    # The element itself comes from `ui/flow_value_dom.nim`, which the review's
    # diff tab also builds from (UD-3) — so "the standard Omniscience
    # appearance" is one implementation rather than two that agree today.
    # Everything below it here is behaviour this host has and the review does
    # not: the jump, the context menu and the tooltip.
    let valueSpan = flowValueBoxDom(
      id = id,
      className = cstring(className),
      text = value.textRepr(compact = true),
      iteration = self.flow.steps[stepCount].iteration,
      style = style,
      maxWidth =
        if value.textRepr(compact = true).len() > FLOW_VALUE_LIMIT:
          cstring(FLOW_VALUE_MAX_WIDTH)
        else:
          cstring"")
    valueSpan.addEventListener(cstring"mousedown", proc(e: Event) =
      onMouseDown(e, value)
    )
    valueSpan.addEventListener(cstring"contextmenu", proc(e: Event) =
      onContextMenu(e, value)
    )
    # Tooltip/modal value rendering is centralized through ValueComponent's
    # DOM entrypoint so flow no longer owns a local Karax materialization bridge.
    valueSpan.addEventListener(cstring"mouseover", proc(e: Event) =
      if not self.modalValueComponent.hasKey(id):
        self.ensureValueComponent(id, name, value)
        self.openTooltip(id, value)
      else:
        let valueDom = self.renderModalValueDom(id)
        self.displayTooltip(id, valueDom)
    )
    parent.appendChild(valueSpan)

  result = flowValueContainerDom(style)

  case flowValueMode:
  of BeforeValueMode:
    if beforeValue.textRepr(compact=true).len() > FLOW_VALUE_LIMIT:
      result.appendChild(renderViewOption())
  of AfterValueMode:
    if afterValue.textRepr(compact=true).len() > FLOW_VALUE_LIMIT:
      result.appendChild(renderViewOption())
  of BeforeAndAfterValueMode:
    if beforeValue.textRepr(compact=true).len() + afterValue.textRepr(compact=true).len() > FLOW_VALUE_LIMIT:
      result.appendChild(renderViewOption())

  if showName:
    let nameSpan = flowValueNameDom(name)
    nameSpan.addEventListener(cstring"mousedown", proc(e: Event) =
      self.jumpToLocalStep(stepCount)
    )
    nameSpan.addEventListener(cstring"contextmenu", proc(e: Event) =
      case flowValueMode:
      of BeforeValueMode:
        onContextMenu(e, beforeValue)
      of AfterValueMode:
        onContextMenu(e, afterValue)
      of BeforeAndAfterValueMode:
        discard
    )
    result.appendChild(nameSpan)

  if flowValueMode == BeforeValueMode:
    let before = &"flow-{flowMode}-value-before-only"
    let id = &"flow-{flowMode}-value-box-{i}-{stepCount}-{name}"
    # The `flow-parallel-value-box` token is part of the DOM contract:
    # the GUI smoke-test helper `assertFlowValueVisible` (and any
    # consumer checking [class*="flow-parallel-value-box"]) needs it
    # present even on single-assignment / before-only spans. The
    # AfterValueMode and dual cases below already include it; emit it
    # here too so the contract is uniform across all flow value
    # branches.
    appendValueSpan(result, cstring(id), &"flow-{flowMode}-value-box " & before, beforeValue)
  elif flowValueMode == AfterValueMode:
    let after = &"flow-{flowMode}-value-after-only"
    let id = &"flow-{flowMode}-value-box-{i}-{stepCount}-{name}"
    appendValueSpan(result, cstring(id), &"flow-{flowMode}-value-box " & after, afterValue)
  else:
    let before = &"flow-{flowMode}-value-dual"
    let idBefore = &"flow-{flowMode}-value-box-{i}-{stepCount}-{name}-before flow-{flowMode}-value-box-{i}-{stepCount}-{name}"
    let idAfter = &"flow-{flowMode}-value-box-{i}-{stepCount}-{name}-after flow-{flowMode}-value-box-{i}-{stepCount}-{name}"

    appendValueSpan(result, cstring(idBefore), &"flow-{flowMode}-value-box flow-dual-value-before " & before, beforeValue)

    let arrowSpan = document.createElement(cstring"span")
    arrowSpan.setAttribute(cstring"class", cstring(&"flow-{flowMode}-value-name flow-dual-arrow"))
    arrowSpan.appendChild(document.createTextNode(cstring"=>"))
    result.appendChild(arrowSpan)

    appendValueSpan(result, cstring(idAfter), &"flow-{flowMode}-value-box " & before, afterValue)

  # Value Origin Tracking (M4 deliverable §3.2.3 + Gap 2) — attach the
  # icon-only origin badge per annotated value.  The per-value summary
  # lives in ``FlowStep.origin_summaries`` (Rust wire shape — see
  # ``task::FlowStep``) keyed by variable name; the Nim ``FlowStep``
  # object does not yet carry a typed field so we recover it via
  # ``extractOriginSummaryMap`` on the raw JsObject.  Placeholder
  # badges (the §3.2.3 default for the omniscience-flow row) auto-
  # enqueue via the lazy-fill observer.
  if stepCount >= 0 and stepCount < self.flow.steps.len:
    let step = self.flow.steps[stepCount]
    let summaryEntries =
      extractOriginSummaryMap(step.toJs[cstring("originSummaries")])
    let nameKey = $name
    var match: Option[OriginSummary]
    for (key, summary) in summaryEntries:
      if key == nameKey:
        match = some(summary)
        break
    if match.isSome:
      let summary = match.get
      let originVM = originChainVM()
      let prefs =
        if originVM.isNil: defaultOriginPreferences()
        else: originVM.preferences.val
      let badge = renderBadgeDom(
        parent = result,
        summary = summary,
        prefs = prefs,
        atSidePanel = false,
        iconOnly = true,
        onClick = proc(token: string) =
          if summary.isPlaceholder and token.len > 0:
            enqueueOriginPlaceholderToken(token)
            flushPlaceholdersNow()
          elif not originVM.isNil:
            let chainValue =
              if afterValue.isNil: beforeValue else: afterValue
            self.api.emit(
              CtOriginChain,
              ValueWithExpression(expression: name, value: chainValue))
      )
      if summary.isPlaceholder:
        observePlaceholderBadge(badge)

proc clearInline(self: FlowComponent) =
  for _, line in self.flowLines:
    # Remove the class 'flow-inline-value' from each node
    for _, node in line.decorationsDoms:
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
  if not self.inExtension:
    var tab = self.data.services.editor.open[self.editorUI.path]

    if not tab.monacoEditor.isNil:
      for _, viewZone in self.loopViewZones:
        removeMonacoViewZone(tab.monacoEditor, viewZone)
      # clear flow line content widgets
      for _, flowLine in self.flowLines:
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
  self.multilineValuesDoms = JsAssoc[int, JsAssoc[cstring, kdom.Node]]{}

proc clearFlowLines*(self: FlowComponent) =
  self.flowLines = JsAssoc[int,FlowLine]{}

proc clearLoopStates*(self: FlowComponent) =
  self.loopStates = JsAssoc[int, LoopState]{}

proc clearStepNodes*(self: FlowComponent) =
  self.stepNodes = JsAssoc[int, kdom.Node]{}

proc removeViewZones(self: FlowComponent, zones: JsAssoc[int, int]) =
  if self.inExtension or self.editorUI.isNil or self.editorUI.monacoEditor.isNil:
    return

  for _, zoneId in zones:
    try:
      removeMonacoViewZone(self.editorUI.monacoEditor, zoneId)
    except:
      discard

proc clearViewZones(self: FlowComponent) =
  self.removeViewZones(self.viewZones)
  self.viewZones = JsAssoc[int, int]{}

proc clearLoopViewZones(self: FlowComponent) =
  self.removeViewZones(self.loopViewZones)
  self.loopViewZones = JsAssoc[int, int]{}

proc resetFlow*(self: FlowComponent) =
  # NOTE: `clearSliders` used to be called here. It removed Monaco content
  # widgets from `sliderWidgets`, a map nothing ever wrote to (see
  # `synchronizeLinkedSliders`), so it removed nothing. The loop sliders that do
  # exist live inside the loop view zones and are torn down by
  # `clearLoopViewZones` / `clearParallel` below.
  # Inline flow uses Monaco decorations that must be removed before any redraw,
  # otherwise unrelated UI redraws stack duplicate inline values in the editor.
  self.clearInline()
  self.clearMultiline()
  self.clearLoopViewZones()
  self.clearParallel()

  self.clearLoopStates()
  if not self.inExtension:
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
  if self.data.config.flow.realFlowUI == flowUI:
    return

  self.resetFlow()

  let flowUINames: array[FlowUI, cstring] = [cstring"parallel", cstring"inline", cstring"multiline"]

  self.data.config.flow.ui = flowUINames[flowUI]
  self.data.config.flow.realFlowUI = flowUI
  self.redraw()

proc addContentWidget*(
  self: FlowComponent,
  dom: Node,
  line: int,
  column: int,
  id: cstring,
  isStatusWidget: bool = false
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
  else:
    self.flowLines[line].contentWidget = cast[Node](widget)

  editor.addContentWidget(widget)

  return widget

proc makeLegend(self: FlowComponent, step: FlowStep): Node =
  let legendNode = document.createElement(cstring"div")
  legendNode.setAttribute(cstring"class", cstring"flow-loop-legend")
  legendNode.style.left = cstring($(self.maxFlowLineWidth + self.distanceToSource) & "px")
  legendNode.style.width = cstring($(self.loopStates[step.loop].legendWidth) & "px")

  var counter = 0
  let valuesCount = toSeq(step.beforeValues.keys()).len
  for expression, value in step.beforeValues:
    counter += 1
    let valueNode = document.createElement(cstring"div")
    valueNode.setAttribute(cstring"class", cstring"flow-loop-legend-expression")
    let valueWidth =
      self.loopStates[step.loop]
        .positions[step.position]
        .positionColumns[step.iteration]
        .valuesExpressions[expression]
        .expressionLegendPercent
    valueNode.style.width = cstring($valueWidth & "%")
    valueNode.appendChild(document.createTextNode(expression))
    legendNode.appendChild(valueNode)

    if counter < valuesCount:
      let emptySpaceNode = document.createElement(cstring"div")
      emptySpaceNode.setAttribute(cstring"class", cstring"flow-loop-empty-space")
      let emptySpaceWidth =
        self.loopStates[step.loop].positions[step.position]
          .legendValueGapPercentage
      emptySpaceNode.style.width = cstring($(emptySpaceWidth) & "%")
      legendNode.appendChild(emptySpaceNode)

  self.flowLines[step.position].legendDom = legendNode

  return legendNode

proc makeFlowLineContainer*(self: FlowComponent, step: FlowStep) =
  # create content widget for
  var dom = cast[Node](document.createElement(cstring"div"))
  let id = cstring(&"ct-flow-{self.id}-{step.position}")

  self.flowDom[step.position] = dom

  discard self.addContentWidget(dom, step.position, 0, id)

proc shrinkedLoopIterationView(self: FlowComponent, iteration: int) : Node =
  result = document.createElement(cstring"div")
  result.setAttribute(cstring"class", cstring"flow-loop-shrinked-iteration")
  result.setAttribute(cstring"id", cstring(&"flow-loop-shrinked-iteration-{iteration}"))
  result.appendChild(document.createTextNode(cstring""))

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
    ($self.data.config.flow.realFlowUI)
      .substr(4, ($self.data.config.flow.realFlowUI).len - 1)
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

# `calculatePositionMaxWidth` and `realignPositionWidths` used to be here.
# Between them they were the spec's "Expression Columns" and "Legend Columns":
# each variable's character budget at a line inside a loop, each iteration's
# widest value row, and the percentages a heading and a value cell occupy of
# their rows.
#
# NEITHER HAD A CALL SITE. Nothing in the tree invoked either — verified by
# `git grep` against `dev`: forward declaration, definition, and comments in
# `review_flow_overlay.nim` describing the algorithm, nothing more.
#
# THE CONSEQUENCE IS A LIVE DEFECT, and it is worse than a wrong number.
# `calculatePositionMaxWidth` was the only writer of `LoopState.positions`,
# which is otherwise initialised empty (`makeLoopState`) and never filled. Three
# procs read through it. Two of them — `complexValueStyle` and
# `legendValueStyle` — have no call site either. The third, `makeLegend`, IS
# called (`addComplexLoopStepValues` <- `recreateLoopContainerAndSteps`, for
# both `FlowParallel` and `FlowInline`), and it reads
#
#     loopStates[loop].positions[position].positionColumns[iteration]
#       .valuesExpressions[expression].expressionLegendPercent
#
# which the JS backend emits as exactly that chain, unguarded. `positions[...]`
# is `undefined`, so the next `.positionColumns` raises a TypeError — the
# heading is not laid out at `0%`, the legend is not built at all. The same
# dead writer is why `LoopState.defaultIterationWidth` starts at 0 and is
# thereafter only ever moved by the two keyboard zoom commands in `ui_js.nim`.
#
# It is deliberately NOT fixed here: this change is a refactor, and wiring the
# computation up would change what the desktop draws. It is recorded in
# `codetracer-specs/GUI/Debugging-Features/Omniscience-Flow.md` so that it does
# not survive only as a comment in the file it was found in.
#
# The computation itself now lives as `flow_layout.computeLoopColumnPlan`, in
# characters and percentages with the two `pixelsPerSymbol` multiplications left
# behind for a renderer to apply. It is exercised headlessly for the first time
# by `viewmodel/tests/unit/test_flow_layout.nim`.

proc flowComplexStep(self: FlowComponent, step: FlowStep): Node =
  let flowMode =
    ($self.data.config.flow.realFlowUI)
      .substr(4, ($self.data.config.flow.realFlowUI).len - 1)
      .toLowerAscii()

  let nodeStyle = self.flowLeftStyle(step.position)
  let parentId = cstring(&"flow-{flowMode}-value-{step.position}")
  let parentClass = cstring(&"flow-{flowMode} flow-{flowMode}-value-single")

  result = document.createElement(cstring"div")
  result.setAttribute(cstring"id", parentId)
  result.setAttribute(cstring"class", parentClass)
  result.applyStyle(nodeStyle)

  var counter = 0
  let valuesCount = toSeq(step.beforeValues.keys()).len
  var style = style(
    (StyleAttr.fontSize, cstring($(self.fontSize) & "px")),
    (StyleAttr.lineHeight, cstring($self.lineHeight & "px")),
    (StyleAttr.height, cstring($self.lineHeight & "px")),
    (StyleAttr.backgroundSize, cstring($(self.fontSize + 2) & "px"))
  )
  for i, event in step.events:
    result.appendChild(flowEventValue(self, event, step.stepCount, style, i))

  for i, expression in step.exprOrder:
    let beforeValue = step.beforeValues[expression]
    let afterValue = step.afterValues[expression]
    if beforeValue.isNil and afterValue.isNil:
      continue
    counter += 1
    var showName = true

    let valueNode = flowSimpleValue(
      self,
      expression,
      beforeValue,
      step.afterValues[expression],
      step.stepCount,
      showName,
      style,
      i
    )
    result.appendChild(valueNode)

    if counter < valuesCount:
      let emptySpace = document.createElement(cstring"div")
      emptySpace.setAttribute(cstring"class", cstring"flow-loop-empty-space")
      emptySpace.applyStyle(style())
      result.appendChild(emptySpace)

proc getEditorFirstLineNumber(self: FlowComponent): int =
  let editorId = self.editorUI.id
  return cast[int](
    jq(&"#editorComponent-{editorId} .monaco-editor .margin-view-overlays .gutter-line")
      .innerText
  )

proc flowLineSourceText(self: FlowComponent, position: int): string =
  if position <= 0:
    return ""

  try:
    let model = self.editorUI.monacoEditor.getModel()
    if position <= model.getLineCount():
      let text = $cast[cstring](model.getLineContent(position))
      if text.len > 0:
        return text
  except:
    discard

  if not self.tab.isNil and position - 1 >= 0 and position - 1 < self.tab.sourceLines.len:
    return $self.tab.sourceLines[position - 1]

  return ""

proc fallbackFlowExpressionPosition(self: FlowComponent, position: int): int =
  ## Where a label goes when its expression is nowhere in the line's text.
  ##
  ## The MEASUREMENT is Monaco's and stays here; the arithmetic over it is
  ## `flow_layout.fallbackExpressionColumn`. `getLineMaxColumn` is 1-based, so
  ## `- 1` is the line's length, which is exactly what the `except` branch
  ## reaches for when there is no model.
  let placed = self.flowLines[position].variablesPositions.len
  try:
    let model = self.editorUI.monacoEditor.getModel()
    return fallbackExpressionColumn(model.getLineMaxColumn(position) - 1, placed)
  except:
    return fallbackExpressionColumn(self.flowLineSourceText(position).len, placed)

proc calculateVariablePosition(self: FlowComponent, position: int, expression: cstring): int =
  ## The source column this expression's label attaches at.
  ##
  ## `findExpressionColumn` (`flow_layout`) is the standalone-occurrence search
  ## that used to be `findFlowExpressionPosition` here.
  let text = self.flowLineSourceText(position)
  var variablePosition = findExpressionColumn(text, $expression)

  if variablePosition < 0:
    variablePosition = self.fallbackFlowExpressionPosition(position)

  self.flowLines[position].variablesPositions[expression] = variablePosition
  return variablePosition

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

  result = document.createElement(cstring"div")
  result.setAttribute(cstring"id", cstring(&"flow-multiline-value-{position}-{expression}"))
  result.setAttribute(cstring"class", cstring"flow-multiline-value-container")
  result.style.top = cstring($(topOffset*editorLineHeight) & "px")
  result.style.left = cstring($(nodeLeft) & "px")

  if topOffset > 0:
    let pointer = document.createElement(cstring"div")
    pointer.setAttribute(cstring"class", cstring"flow-multiline-value-pointer")
    pointer.style.top = cstring($((-1)*topOffset*editorLineHeight) & "px")
    pointer.style.height = cstring($(topOffset*editorLineHeight) & "px")
    result.appendChild(pointer)

  let valueNode = flowSimpleValue(
    self,
    expression,
    beforeValue,
    afterValue,
    stepCount,
    false,
    style
  )
  result.appendChild(valueNode)

proc sortVariablesPositions(self: FlowComponent, step: FlowStep, ascending: bool = true) =
  ## Order this line's labels and copy the matching values into
  ## `flowLines[..].sortedVariables`.
  ##
  ## The ordering is `flow_layout.orderExpressionsByColumn`. Note the flag flip:
  ## this proc's `ascending` is inverted with respect to its name — it set
  ## `direction = -1` for `ascending = true` and so sorted DESCENDING — and its
  ## only call site passes `false`, i.e. left to right by source column. The SDK
  ## function is named for what it does, so the inversion is confined to this
  ## line instead of travelling.
  var placed: seq[FlowExpressionColumn] = @[]
  for expression, column in self.flowLines[step.position].variablesPositions:
    placed.add(FlowExpressionColumn(
      expression: $expression, column: column, found: true))

  var sortedVariablesExpressions: seq[cstring] = @[]
  for entry in orderExpressionsByColumn(placed, ascending = not ascending):
    sortedVariablesExpressions.add(cstring(entry.expression))

  for expression in sortedVariablesExpressions:
    if step.beforeValues.hasKey(expression):
      self.flowLines[step.position].sortedVariables[expression] =
        step.beforeValues[expression]
    elif step.afterValues.hasKey(expression):
      self.flowLines[step.position].sortedVariables[expression] =
        step.afterValues[expression]

proc makeMultilineFlowValues(self: FlowComponent, step: FlowStep) =
  var topOffset = 0
  # render variable lines in the viewZone
  for expression, variable in self.flowLines[step.position].sortedVariables:
    let beforeValue =
      if step.beforeValues.hasKey(expression):
        step.beforeValues[expression]
      else:
        nil
    let afterValue =
      if step.afterValues.hasKey(expression):
        step.afterValues[expression]
      else:
        nil
    let dom = self.makeflowValue(
      step.position,
      expression,
      topOffset,
      self.flowLines[step.position].variablesPositions[expression].int,
      beforeValue,
      afterValue,
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
    # "Immediately after the expression" is the layout decision and lives in
    # `flow_layout.inlineLabelAnchorColumn`; "and Monaco expresses that as a
    # zero-width decoration range" is this file's and stays.
    let position = inlineLabelAnchorColumn(
      self.flowLines[step.position].variablesPositions[expression],
      expression.len)

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
        let valueNode = flowSimpleValue(
          self,
          expression,
          step.beforeValues[expression],
          step.afterValues[expression],
          step.stepCount,
          false,
          style
        )

        lineDecorationsDoms[index].appendChild(valueNode)
        self.flowLines[step.position].decorationsDoms[expression] = lineDecorationsDoms[index]
        index += 1

type
  InlineFlowValuesData = ref object
    self: FlowComponent
    step: FlowStep

proc triggerInsertFlowInlineValues(data: InlineFlowValuesData) {.cdecl.} =
  if not data.self.isNil:
    data.self.insertFlowInlineValues(data.step)

proc makeInlineFlowLines(self: FlowComponent, step: FlowStep) =
  if self.flowLines[step.position].decorationsIds.len == 0:
    self.insertInlineDecorations(step)

  let valData = InlineFlowValuesData(self: self, step: step)
  setTimeoutWithArg(triggerInsertFlowInlineValues, 50, valData)

proc renderContinuousStep(
  self: FlowComponent,
  stepContainer: Node,
  step: FlowStep,
  name: cstring,
  singleValue: bool,
  style: VStyle
): Node =
  stepContainer.toJs.classList.toJs.add("continuous")

  let id = &"flow-loop-shrinked-iteration-step-{step.stepCount}"

  result = document.createElement(cstring"div")
  result.setAttribute(cstring"id", cstring(id))
  result.setAttribute(cstring"class", cstring"flow-loop-continuous-iteration")
  result.applyStyle(style)
  result.addEventListener(cstring"click", proc(ev: Event) =
    self.jumpToLocalStep(step.stepCount)
  )
  result.addEventListener(cstring"dblclick", proc(ev: Event) =
    self.openValue(step.stepCount, name, before=true)
  )
  result.addEventListener(cstring"mouseover", proc(ev: Event) =
    ev.stopPropagation()
  )
  result.appendChild(document.createTextNode(cstring""))

proc renderShrinkedStep(
  self: FlowComponent,
  stepContainer: Node,
  step: FlowStep,
  name: cstring,
  singleValue: bool,
  style: VStyle
): Node =
  stepContainer.toJs.classList.toJs.add("shrinked")

  let id = &"flow-loop-shrinked-iteration-step-{step.stepCount}"

  result = document.createElement(cstring"div")
  result.setAttribute(cstring"id", cstring(id))
  result.setAttribute(cstring"class", cstring"flow-loop-shrinked-iteration")
  result.applyStyle(style)
  result.addEventListener(cstring"click", proc(ev: Event) =
    self.jumpToLocalStep(step.stepCount)
  )
  result.addEventListener(cstring"dblclick", proc(ev: Event) =
    self.openValue(step.stepCount, name, before=true)
  )
  result.addEventListener(cstring"mouseover", proc(ev: Event) =
    ev.stopPropagation()
  )
  result.appendChild(document.createTextNode(cstring""))

proc makeFlowStepContainer(self: FlowComponent, step: FlowStep): Node =
  result = document.createElement(cstring"div")
  result.setAttribute(cstring"id", cstring(&"flow-loop-step-container-{step.loop}-{step.iteration}"))
  result.setAttribute(cstring"class", cstring"flow-loop-step-container")
  result.appendChild(document.createTextNode(cstring""))

proc makeMultilineLoopStepView(self: FlowComponent, step: FlowStep): Node =
  # create flow loop step container
  let stepContainer = self.makeFlowStepContainer(step)

  # fill the container
  var topOffset = 0
  let editor = self.editorUI.monacoEditor
  let editorLineHeight = editor.config.lineHeight

  for expression, variable in self.flowLines[step.position].sortedVariables:
    let beforeValue =
      if step.beforeValues.hasKey(expression):
        step.beforeValues[expression]
      else:
        nil
    let afterValue =
      if step.afterValues.hasKey(expression):
        step.afterValues[expression]
      else:
        nil
    let style = style(
      (StyleAttr.top, cstring($(topOffset*editorLineHeight) & "px"))
    )

    case self.loopStates[step.loop].viewState:
    of LoopContinuous:
      let stepNode = renderContinuousStep(self, stepContainer, step, expression, singleValue=true, style)
      stepContainer.appendChild(stepNode)

    of LoopShrinked:
      let stepNode = renderShrinkedStep(self, stepContainer, step, expression, singleValue=true, style)
      stepContainer.appendChild(stepNode)

    else:
      let stepNode = flowSimpleValue(
        self,
        expression,
        beforeValue,
        afterValue,
        step.stepCount,
        false,
        style
      )
      stepContainer.appendChild(stepNode)
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

  # create step node
  var stepNode: Node
  case self.loopStates[step.loop].viewState:
  of LoopContinuous:
    for expression, value in step.beforeValues:
      stepNode = renderContinuousStep(self, stepContainer, step, expression, singleValue=false, style())

  of LoopShrinked:
    for expression, value in step.beforeValues:
      stepNode = renderShrinkedStep(self, stepContainer, step, expression, singleValue=false, style())

  else:
    stepNode = flowComplexStep(self, step)

  stepContainer.appendChild(stepNode)

  return stepContainer

proc makeLoopStepView(self: FlowComponent, step: FlowStep): Node =
  case self.data.config.flow.realFlowUI:
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
  ## DORMANT: `FlowLine.loopIds` is initialised to `@[]` (`makeFlowLine` here and
  ## the twin literal in `ui/editor.nim`) and **nothing anywhere appends to it**,
  ## so this loop body never executes and `line.activeLoopIteration` keeps its
  ## `(-1, -1)` initial value for the whole session. Everything in
  ## `updateFlowOnMove` that keys off `activeLoopIteration` — the
  ## `.active-flow-step` marker and the per-iteration value refresh — is
  ## therefore dead too.
  ##
  ## It is left dormant rather than switched on here: populating `loopIds` also
  ## activates several width/offset readers (`calclulateFlowLineTotalWidth`,
  ## `prepareFlowLineContainerProps`, `resizeFlowLineContainers`) whose effect on
  ## the rendered layout cannot be judged without running the editor. The loop
  ## COUNTER and the slider handle do not depend on it: both read
  ## `loopStates[..].activeIteration` directly, via `activeLoopIterationFor`
  ## (`flowLoopValue`, `updateLoopControlDom`) and `ensureLoopSlider`.
  let debuggerLocation = self.location.rrTicks
  let line = self.flowLines[position]

  for loopIndex in line.loopIds:
    if loopIndex < 0 or loopIndex >= self.flow.loops.len or
       not self.loopStates.hasKey(loopIndex):
      continue
    let loop = self.flow.loops[loopIndex]
    let loopActiveIteration = self.loopStates[loopIndex].activeIteration
    if loopActiveIteration < 0 or
       loopActiveIteration >= loop.rrTicksForIterations.len:
      # `updateFlowOnMove` is not wrapped in a `try`, so an IndexDefect raised
      # here would abandon the rest of the move handling, loop control refresh
      # included.
      continue
    let rrTicksOfLoopActiveIteration =
      loop.rrTicksForIterations[loopActiveIteration]

    if debuggerLocation <= rrTicksOfLoopActiveIteration:
      if loop.base == -1:
        line.activeLoopIteration =
          (loopIndex: loopIndex, iteration: loopActiveIteration)
      elif self.loopStates.hasKey(loop.base) and
           loop.baseIteration == self.loopStates[loop.base].activeIteration:
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
  let props = self.prepareBackgroundStyleProps(loopIndex)

  result = document.createElement(cstring"div")
  result.setAttribute(cstring"id", cstring(&"flow-loop-{loopIndex}-background"))
  result.setAttribute(cstring"class", cstring"flow-loop-background")
  result.style.left = cstring($(props.left) & "px")
  result.style.top = cstring($(props.top) & "px")
  result.style.width = cstring($(props.width) & "px")
  result.style.height = cstring($(props.height) & "px")
  result.appendChild(document.createTextNode(cstring""))

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
        case self.data.config.flow.realFlowUI:
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

  # create step Node
  let stepNode = flowComplexStep(self, step)

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
    # This used to be guarded by `not self.sliderWidgets.hasKey(step.position)`,
    # a condition that was always true because nothing ever wrote to that map.
    # `makeSlider` / `ensureLoopSlider` are idempotent — an existing slider with
    # the right range is only re-positioned — so the call needs no guard.
    self.makeSlider(self.flow.loops[step.loop].first)

  # check if there is a register for loop step cells
  let stepLoopCells = self.flowLines[step.position].stepLoopCells
  if not stepLoopCells.hasKey(step.loop):
    stepLoopCells[step.loop] = JsAssoc[int, Node]{}

  # add step container to flow line step cells register
  steploopCells[step.loop][step.iteration] = stepContainer

  # create step node
  var stepNode: Node

  case self.loopStates[step.loop].viewState:
  of LoopContinuous:
    stepNode = renderContinuousStep(self, stepContainer, step, "complex", singleValue=false, style())

  of LoopShrinked:
    stepNode = renderShrinkedStep(self, stepContainer, step, "complex", singleValue=false, style())

  else:
    stepNode = flowComplexStep(self, step)

  # append step Node to stepContainer
  stepContainer.appendChild(stepNode)

  # append stepContainer to parentContainer
  parentContainer.appendChild(stepContainer)

proc addParallelStepValues(self: FlowComponent, step: FlowStep) =
  self.addParallelRegularStepValues(step)

proc addMultilineStepValues(self: FlowComponent, step: FlowStep) =
  # create viewZone for this step if there is not any yet
  if not self.multilineZones.hasKey(step.position):
    let valueRows = max(
      1,
      max(
        self.flowLines[step.position].sortedVariables.len,
        max(step.beforeValues.len, step.afterValues.len)))
    let newZoneDom =
      createFlowViewZone(
        self,
        step.position,
        valueRows.float*self.lineHeight.float)

    self.multiLineZones[step.position] =
      MultilineZone(
        dom: newZoneDom,
        zoneId: self.viewZones[step.position],
        variables: JsAssoc[cstring, bool]{})

    cast[Element](newZoneDom).classList.add("flow-content-widget")

    if not self.flowDom.hasKey(step.position):
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
    case self.data.config.flow.realFlowUI:
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

  if not editorLinesDom.isNil:
    self.mutationObserver = createMutationObserver(
      proc(mutationList: seq[MutationRecord], observer: MutationObserver) =
        if mutationList.any(record => $(record.`type`) == cstring"childList"):
          if not self.isFullyLoaded():
            reloadFlow(self))

    self.mutationObserver.observe(
      cast[Element](editorLinesDom),
      js{ childList: true })

    cdebug "flow: OBSERVER STARTED"
  else:
    cdebug "flow: OBSERVER NOT STARTED — editor DOM lines not found yet"

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
  # A line can legitimately have no slider: single-iteration loops never get
  # one (`makeSlider`), and `removeSliderWidget` clears it again when a loop
  # collapses to one iteration in a new flow window.
  if not self.flowLines.hasKey(position) or self.flowLines[position].sliderDom.isNil:
    return
  if self.flowLines[position].totalLineWidth > self.flowViewWidth:
    self.flowLines[position].sliderDom.style.display = "inline-flex"
  else:
    self.flowLines[position].sliderDom.style.display = "none"

proc calculateSliderLeftOffset(self:FlowComponent, loopIndex: int): int =
  case self.data.config.flow.realFlowUI:
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

  if self.data.config.flow.realFlowUI != FlowMultiline:
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
  # NOTE: this used to begin with `for line, slider in self.sliderWidgets:
  # self.showOrHideSlider(line)`. `sliderWidgets` was never populated, so the
  # loop never ran. It is not revived against `flowLines` here on purpose:
  # `showOrHideSlider` hides any slider whose line is narrower than the flow
  # view, which for the loop-control slider is the normal case — reviving it
  # naively would hide exactly the slider #562 is about.

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
  ## Recompute, for every loop in the current flow window, which iteration the
  ## debugger is now inside.
  ##
  ## This is the ONLY writer of `activeIteration` that follows the debugger, so
  ## the loop counter and the slider are only ever as correct as this call.
  ## `activeIterationForTicks` does a containing-interval search rather than the
  ## exact-equality match this used to do; see `flow_loop_math.nim` for why that
  ## match could essentially never succeed (#593).
  for index, loopState in self.loopStates:
    if index < 0 or index >= self.flow.loops.len:
      continue
    loopState.activeIteration =
      activeIterationForTicks(
        self.flow.loops[index].rrTicksForIterations,
        debuggerLocationRRTicks)

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
    # A line with no steps in the current window is ordinary, not an error: the
    # flow window covers one call, and callers ask about lines that may be
    # outside it, never executed, or blank. This used to log at ERROR level —
    # 79 entries in a single GUI run — and dereferenced the missing key with
    # `console.log` on the line before the check, which printed `undefined`.
    if not flow.positionStepCounts.hasKey(position) or
       flow.positionStepCounts[position].len < 1:
      cdebug cstring(fmt"flow: no step recorded at line {position} in this flow window")
      return NO_STEP_COUNT

    # The interval search is `flow_layout.stepIndexForTicks`; the lookup of the
    # line's step counts stays here because it reads the desktop's `JsAssoc`
    # window directly and this runs on every debugger move.
    let stepCounts = flow.positionStepCounts[position]
    var ticks: seq[int] = @[]
    for stepCount in stepCounts:
      ticks.add(flow.steps[stepCount].rrTicks)

    let chosen = stepIndexForTicks(ticks, rrTicks)
    if chosen < 0:
      return NO_STEP_COUNT
    return stepCounts[chosen]
  except IndexDefect as e:
    cerror(&"flow: We don't have a position step count or steps for that position {e.msg}")

    return NO_STEP_COUNT

proc debuggerRRTicks(self: FlowComponent): int =
  ## The trace tick the debugger is currently stopped at, as this component
  ## understands it. `NO_TICKS` when the component has no location yet.
  if self.location.toJs.isNil:
    NO_TICKS
  else:
    self.location.rrTicks

proc createLoopStates(self: FlowComponent) =
  ## Make sure every loop in the freshly loaded flow window has a `LoopState`.
  ##
  ## A NEW state is seeded with the iteration the debugger is actually inside,
  ## never with 0 (#593/#595).
  ##
  ## Why this matters more than it looks: `EditorViewComponent.loadFlow`
  ## (`ui/editor.nim`) constructs a **brand-new `FlowComponent`** — with an
  ## empty `loopStates` — for every move whose `rrTicks` differ, which is every
  ## move. So the states this proc creates are not "the states from before the
  ## jump with one field stale"; they are the only states there are, and they
  ## are created here, during `renderFlowLines`, i.e. *before* the loop control
  ## DOM is built from them by `addLoopInfo` -> `makeFlowLoops` ->
  ## `flowLoopValue`.
  ##
  ## `setLoopStatesActiveIteration` does run for the same window, but only
  ## afterwards (`onUpdatedFlow` calls `redrawFlow()` and *then*
  ## `updateFlowOnMove`), so before this seeding the control was always painted
  ## from the default 0 and then never repainted: the counter read "iteration 0"
  ## no matter where the debugger was, and the next arrow click computed its
  ## target from that 0 and jumped back to iteration 1.
  ##
  ## An EXISTING state is deliberately left alone, so that a `createLoopStates`
  ## that runs without an intervening teardown cannot undo the optimistic
  ## iteration `selectLoopIteration` just wrote (at that moment `self.location`
  ## still names the PRE-jump position, so re-deriving would step the user
  ## backwards). Note that `redrawFlow` -> `clear` -> `resetFlow` ->
  ## `clearLoopStates` wipes the table, so on that path every state is a new
  ## one and is seeded from the location — which is why the arrow handlers and
  ## the iteration textarea update the control through `updateLoopControlDom`
  ## rather than through `redrawFlow`.
  let locationTicks = self.debuggerRRTicks()
  for loopIndex, loop in self.flow.loops:
    if loopIndex > 0:
      if not self.loopStates.hasKey(loopIndex):
        let loopState = makeLoopState()
        if locationTicks != NO_TICKS:
          loopState.activeIteration =
            activeIterationForTicks(loop.rrTicksForIterations, locationTicks)
        self.loopStates[loopIndex] = loopState

proc maxLoopIteration*(self: FlowComponent, loopIndex: int): int =
  ## Highest selectable iteration index for `loopIndex` in the CURRENT flow
  ## window, or -1 when the loop has no recorded iterations.
  ##
  ## Single definition on purpose: the loop counter's "from N" label, the
  ## forward arrow's clamp and its `disabled` state must all agree, and they
  ## previously each recomputed this inline.
  if loopIndex >= 0 and loopIndex < self.flow.loopIterationSteps.len:
    self.flow.loopIterationSteps[loopIndex].len - 1
  elif loopIndex >= 0 and loopIndex < self.flow.loops.len:
    self.flow.loops[loopIndex].rrTicksForIterations.len - 1
  else:
    -1

proc activeLoopIterationFor*(self: FlowComponent, step: FlowStep): int =
  ## The iteration the loop controls should currently display for `step`.
  ##
  ## `loopStates[..].activeIteration` is the live value maintained by
  ## `setLoopStatesActiveIteration` / `selectLoopIteration`; `step.iteration` is
  ## only the fallback for a loop whose state has not been created yet.
  if self.loopStates.hasKey(step.loop):
    self.loopStates[step.loop].activeIteration
  else:
    step.iteration

proc updateLoopControlDom*(self: FlowComponent, position: int) =
  ## Refresh the already-rendered loop control at `position` in place.
  ##
  ## The loop control's textarea and arrow `disabled` flags are written once, at
  ## DOM-construction time (`flowLoopValue` / `backLoopControlButton` /
  ## `nextLoopControlButton`). Before this proc existed the only way to make a
  ## new `activeIteration` visible was `redrawFlow()`, which tears down and
  ## rebuilds every Monaco view zone in the editor — that full rebuild on each
  ## arrow click is what the #562 reporter saw as blinking. The arrow handlers
  ## had been changed to call `self.redraw()` instead, but `Component.redraw`
  ## dispatches to `redrawForSinglePage`, whose base implementation is
  ## `discard` and which `FlowComponent` does not override, so the click
  ## produced no visible change at all.
  ##
  ## This writes exactly the two things that can change — the displayed
  ## iteration number and whether each arrow is at its end stop — and touches
  ## nothing else.
  if not self.flowLoops.hasKey(position):
    return

  let flowLoop = self.flowLoops[position]
  if flowLoop.isNil or flowLoop.flowDom.isNil:
    return

  let step = flowLoop.loopStep
  let iteration = self.activeLoopIterationFor(step)
  let maxIteration = self.maxLoopIteration(step.loop)
  let root = flowLoop.flowDom

  let textarea = root.querySelector(cstring".flow-loop-textarea")
  if not textarea.isNil:
    # Both the attribute and the live `value` property: the attribute is what
    # a freshly parsed DOM shows, the property is what the browser renders for
    # a textarea the user may already have focused.
    textarea.setAttribute(cstring"value", cstring($iteration))
    textarea.toJs.value = cstring($iteration)

  proc setDisabled(node: Node, disabled: bool) =
    if node.isNil:
      return
    if disabled:
      node.setAttribute(cstring"disabled", cstring"disabled")
    else:
      node.removeAttribute(cstring"disabled")

  setDisabled(root.querySelector(cstring".flow-loop-button.backward"), iteration <= FLOW_ITERATION_START)
  setDisabled(root.querySelector(cstring".flow-loop-button.forward"), maxIteration <= iteration)

proc flowLoopValue*(
  self: FlowComponent,
  step: FlowStep,
  allIterations: int,
  style: VStyle
): Node =
  var iteration = self.activeLoopIterationFor(step)
  var width = len(intToStr(allIterations))

  proc onEnter(self: FlowComponent) =
    self.selectLoopIteration(step.loop, iteration, step.position)

  result = document.createElement(cstring"span")
  result.setAttribute(cstring"class", cstring"flow-loop-value")
  result.applyStyle(style)

  let loopSpan = document.createElement(cstring"span")
  loopSpan.setAttribute(cstring"class", cstring"ct-omniscience-loop")
  loopSpan.applyStyle(style)

  let iterationStart = document.createElement(cstring"span")
  iterationStart.setAttribute(cstring"class", cstring"flow-parallel-loop-iteration-start")
  iterationStart.appendChild(document.createTextNode(cstring"iteration "))
  loopSpan.appendChild(iterationStart)

  let textarea = document.createElement(cstring"textarea")
  textarea.setAttribute(cstring"class", cstring"flow-loop-textarea")
  textarea.setAttribute(cstring"value", cstring($(iteration)))
  textarea.toJs.value = cstring($(iteration))
  textarea.setAttribute(cstring"maxlength", cstring($width))
  textarea.addEventListener(cstring"blur", proc(e: Event) =
    self.onEnter()
    # `redrawFlow()` used to be called here. It is `clear()` +
    # `recalculateAndRedrawFlow()`, and `clear()` drops `loopStates` — so it
    # discarded the iteration `onEnter` had just selected and re-derived it
    # from `self.location`, which still holds the PRE-jump position until the
    # move completes. The control therefore snapped back to the old iteration
    # for the duration of the jump. `updateLoopControlDom` writes the two
    # things that changed and leaves the view zones standing (see #562's
    # "blinking").
    self.updateLoopControlDom(step.position)
    self.scheduleActiveLoopIterationValueRender()
  )
  textarea.addEventListener(cstring"input", proc(ev: Event) =
    let rawValue = $cast[cstring](ev.target.toJs.value)
    if rawValue.len > 0:
      try:
        let value = parseInt(rawValue)
        if value >= 0 and value <= allIterations:
          iteration = value
      except ValueError:
        discard
  )
  textarea.addEventListener(cstring"keydown", proc(ev: Event) =
    let key = $cast[cstring](ev.toJs.key)
    if key == "Enter" or cast[int](ev.toJs.keyCode) == ENTER_KEY_CODE:
      ev.preventDefault()
      self.onEnter()
      # Same reasoning as the `blur` handler above.
      self.updateLoopControlDom(step.position)
  )
  textarea.applyStyle(style(
    (StyleAttr.width, cstring($(width+1) & "ch")),
    (StyleAttr.textAlign, cstring("right"))))
  loopSpan.appendChild(textarea)

  # TODO: FOR NOW HARDCODE THE PARALLEL
  let iterationEnd = document.createElement(cstring"span")
  iterationEnd.setAttribute(cstring"class", cstring"flow-parallel-loop-iteration-end")
  iterationEnd.appendChild(document.createTextNode(cstring(fmt"from {allIterations}")))
  loopSpan.appendChild(iterationEnd)

  result.appendChild(loopSpan)

proc liveLoopIteration(self: FlowComponent, step: FlowStep): int =
  ## The active iteration as of RIGHT NOW, read through `flowLoops` so a handler
  ## installed on an earlier rebuild still sees the current value.
  if self.flowLoops.hasKey(step.position):
    let loopStep = self.flowLoops[step.position].loopStep
    if loopStep.loop == step.loop:
      return self.activeLoopIterationFor(loopStep)
  self.activeLoopIterationFor(step)

proc backLoopControlButton(self: FlowComponent, step: FlowStep, style: VStyle): Node =
  let iteration = self.activeLoopIterationFor(step)

  result = document.createElement(cstring"button")
  result.setAttribute(cstring"class", cstring"ct-button-image-sm-secondary ct-button-no-border flow-loop-button backward")
  result.setAttribute(cstring"id", cstring"backward-loop")
  result.applyStyle(style)
  if iteration <= FLOW_ITERATION_START:
    result.setAttribute(cstring"disabled", cstring"disabled")
  result.addEventListener(cstring"click", proc(e: Event) =
    # Resolve the target from the LIVE active iteration rather than from the
    # value captured when this button was built: rebuilds can leave a stale
    # control transiently clickable, and a captured index would then move the
    # user by more than one iteration (#595).
    let target = previousIteration(self.liveLoopIteration(step), self.maxLoopIteration(step.loop))
    self.selectLoopIteration(step.loop, target, step.position)
    # Targeted DOM update instead of `redrawFlow()`: see `updateLoopControlDom`.
    self.updateLoopControlDom(step.position)
  )

proc nextLoopControlButton(self: FlowComponent, step: FlowStep, style: VStyle): Node =
  let iteration = self.activeLoopIterationFor(step)
  let maxIterations = self.maxLoopIteration(step.loop)

  result = document.createElement(cstring"button")
  result.setAttribute(cstring"class", cstring"ct-button-image-sm-secondary ct-button-no-border flow-loop-button forward")
  result.setAttribute(cstring"id", cstring"forward-loop")
  result.applyStyle(style)
  if maxIterations <= iteration:
    result.setAttribute(cstring"disabled", cstring"disabled")
  result.addEventListener(cstring"click", proc(e: Event) =
    let target = nextIteration(self.liveLoopIteration(step), self.maxLoopIteration(step.loop))
    self.selectLoopIteration(step.loop, target, step.position)
    self.updateLoopControlDom(step.position)
  )

proc makeLoopLine(
  self: FlowComponent,
  step: FlowStep,
  allIterations: int
): Node =
  let fontSize = if self.fontSize != 0: cstring($(self.fontSize) & "px") else: cstring("inherit")
  let style = style(
    (StyleAttr.fontSize, fontSize),
    (StyleAttr.lineHeight, cstring($self.lineHeight & "px")),
    (StyleAttr.height, cstring($self.lineHeight & "px")),
    (StyleAttr.width, cstring("fit-content"))
  )

  let bStyle = style()

  # NOTE: keep the `flow-multiline-value-container` class on the outer
  # element.  It is part of the public DOM contract of the flow loop
  # control and used as a stable selector by Playwright suites
  # (e.g. tests/noir-space-ship/noir-space-ship.spec.ts:
  # "loop iteration slider tracks remaining shield" /
  # "simple loop iteration jump").  The 0ac4fdda
  # (feat: Omniscience design redo) commit dropped this class in favour
  # of the new `ct-flex ct-p-0` design-system utilities — that is how
  # the noir-space-ship loop tests started to fail to find the loop
  # control.  Both class names are preserved together: the design
  # utilities for layout, the legacy class for tests + styling
  # consistency with the (post-fix-1.12) flow-parallel-value-box DOM
  # contract.
  result = document.createElement(cstring"div")
  result.setAttribute(cstring"id", cstring(&"flow-multiline-value-{step.position}-{step.stepCount}"))
  result.setAttribute(cstring"class", cstring"flow-multiline-value-container ct-flex ct-p-0")

  if step.rrTicks != -1:
    result.appendChild(backLoopControlButton(self, step, bStyle))
    result.appendChild(flowLoopValue(self, step, allIterations, style))
    result.appendChild(nextLoopControlButton(self, step, bStyle))

  # self.redraw()

proc makeFlowLoops(self: FlowComponent, step: FlowStep) =
  let expression = &"for-{step.position}"
  # render variable lines in the viewZone
  let allIterations =
    if step.loop >= 0 and step.loop < self.flow.loopIterationSteps.len:
      self.flow.loopIterationSteps[step.loop].len - 1
    else:
      self.flow.loops[step.loop].rrTicksForIterations.len - 1
  let dom = self.makeLoopLine(step, allIterations)
  cast[Node](self.flowLoops[step.position].flowZones.dom).appendChild(dom)

  self.flowLoops[step.position].flowDom = dom
  self.makeSlider(step.position)

proc activeLoopIterationStepCounts(self: FlowComponent, loopIndex: int, iteration: int): seq[int] =
  ## Every step of one pass through one loop, in reading order.
  ##
  ## The two sources (the iteration's own line→step table, and a scan of the
  ## loop's steps for ones tagged with this iteration) are read here because
  ## they are the desktop's `JsAssoc` window; the deduplication and the
  ## (line, stepCount) ordering are `flow_layout.orderIterationSteps`.
  if loopIndex < 0 or loopIndex >= self.flow.loops.len:
    return

  var candidates: seq[tuple[stepCount: int, line: int]] = @[]

  if loopIndex < self.flow.loopIterationSteps.len and
     iteration >= 0 and iteration < self.flow.loopIterationSteps[loopIndex].len:
    for _, stepCount in self.flow.loopIterationSteps[loopIndex][iteration].table:
      if stepCount >= 0 and stepCount < self.flow.steps.len:
        candidates.add(
          (stepCount: stepCount, line: self.flow.steps[stepCount].position))

  for stepCount in self.flow.loops[loopIndex].stepCounts:
    if stepCount < 0 or stepCount >= self.flow.steps.len:
      continue
    let step = self.flow.steps[stepCount]
    if step.loop == loopIndex and step.iteration == iteration:
      candidates.add((stepCount: stepCount, line: step.position))

  result = orderIterationSteps(candidates)

proc ensureFlowLineForStep(self: FlowComponent, step: FlowStep) =
  if not self.flowLines.hasKey(step.position):
    self.flowLines[step.position] = self.makeFlowLine(step.position)
    self.flowLines[step.position].offsetLeft =
      self.calculateFlowLineLeftOffset(self.flowLines[step.position]).float

proc renderLoopIterationStepValue(self: FlowComponent, loopIndex: int, step: FlowStep) =
  if step.position == self.flow.loops[loopIndex].registeredLine:
    return

  self.ensureFlowLineForStep(step)
  self.prepareFlowLineVariables(step)

  if self.stepNodes.hasKey(step.stepCount):
    if self.data.config.flow.realFlowUI != FlowMultiline or
       self.multilineValuesDoms.hasKey(step.position):
      return

  if toSeq(self.flowLines[step.position].sortedVariables.keys()).len == 0 and
     step.events.len == 0:
    return

  case self.data.config.flow.realFlowUI:
  of FlowMultiline:
    self.addMultilineStepValues(step)
  else:
    self.addStepValues(step)

proc addLoopInfo(self: FlowComponent, step: FlowStep) =
  # create viewZone for this step if there is not any yet
  if not self.flowLoops.hasKey(step.position):
    self.flowLoops[step.position] = FlowLoop(loopStep: step)
    # The zone is registered ABOVE the loop header line, so `createFlowViewZone`
    # records its id under `zonePosition`, not under `step.position`.
    # Reading it back under `step.position` (as this used to) always yielded
    # `undefined`, leaving every loop zone with no usable `zoneId`.
    let zonePosition = self.flow.loops[step.loop].first - 1
    let newZoneDom =
      createFlowViewZone(
        self,
        zonePosition,
        self.lineHeight.float,
        true)

    self.flowLoops[step.position].flowZones =
      MultilineZone(
        dom: newZoneDom,
        zoneId: self.loopViewZones[zonePosition],
        variables: JsAssoc[cstring, bool]{})

    cast[Element](newZoneDom).classList.add("flow-content-widget")

    self.makeFlowLoops(step)
    self.scheduleActiveLoopIterationValueRender()

    for stepCount in self.activeLoopIterationStepCounts(step.loop, step.iteration):
      self.renderLoopIterationStepValue(step.loop, self.flow.steps[stepCount])

proc getClosestIterationStepCount*(self: FlowComponent, loop: Loop, stepCount: int): int =
  ## `stepCount` clamped into the loop's recorded span.
  ##
  ## Delegates to `flow_layout.closestIterationStepCount`, which is the same
  ## clamp verbatim. One difference, in an error path: the version here indexed
  ## `loop.stepCounts[0]` unguarded, so a loop with no recorded steps raised an
  ## `IndexDefect` through `ui/editor.nim`'s caller; the SDK version answers
  ## `NO_STEP_COUNT` instead. No working case changes.
  closestIterationStepCount(
    FlowLayoutLoop(stepCounts: loop.stepCounts), stepCount)

proc updateIterationStepCount*(self: FlowComponent, line: int, stepCount: int, loopId: int, iteration: int): int =
  var table = self.flow.loopIterationSteps[loopId][iteration].table

  if table.hasKey(line):
    return table[line]
  else:
    return stepCount

proc getCurrentStepCount*(self: FlowComponent, line: int): int =
  try:
    var stepCount: int
    stepCount = self.positionRRTicksToStepCount(line, self.location.rrTicks)
    if stepCount < 0 or stepCount >= self.flow.steps.len:
      return NO_STEP_COUNT
    let step = self.flow.steps[stepCount]

    if step.loop >= 0 and step.loop < self.flow.loops.len and
       self.flowLoops.hasKey(self.flow.loops[step.loop].registeredLine):
      let loopStep = self.flowLoops[self.flow.loops[step.loop].registeredLine].loopStep
      stepCount = self.updateIterationStepCount(line, stepCount, loopStep.loop, loopStep.iteration)
    elif self.activeStep.rrTicks == NO_TICKS:
      stepCount = self.positionRRTicksToStepCount(line, self.location.rrTicks)
    else:
      stepCount = self.positionRRTicksToStepCount(line, self.activeStep.rrTicks)
      if stepCount < 0 or stepCount >= self.flow.steps.len:
        return NO_STEP_COUNT
      let activeStep = self.flow.steps[stepCount]
      if activeStep.loop >= 0 and activeStep.loop < self.flow.loops.len:
        let loop = self.flow.loops[activeStep.loop]
        if self.flow.steps[stepCount].loop == self.activeStep.loop:
          stepCount = self.updateIterationStepCount(line, stepCount, self.activeStep.loop, self.activeStep.iteration)
        elif self.activeStep.loop >= 0 and self.activeStep.loop < self.flow.loops.len and
             self.flow.loops[self.activeStep.loop].internal != []:
          var activeLoop = self.flow.loops[self.activeStep.loop]
          var loopId = activeLoop.internal[min(self.activeStep.iteration, len(activeLoop.internal) - 1)]
          var iteration =
            if activeLoop.internal.len == self.activeStep.iteration:
              len(self.flow.loopIterationSteps[loopId]) - 1
            else:
              FLOW_ITERATION_START

          stepCount = self.updateIterationStepCount(line, stepCount, loopId, iteration)

    return stepCount
  except IndexDefect:
    cerror cstring(fmt"flow: getCurrentStepCount IndexDefect for line {line}")
    return NO_STEP_COUNT

proc sortedFlowLinePositions(self: FlowComponent): seq[int] =
  result = toSeq(self.flowLines.keys())
  result.sort(system.cmp[int])

proc prepareFlowLineVariables(self: FlowComponent, step: FlowStep) =
  let flowLine = self.flowLines[step.position]
  if toSeq(flowLine.sortedVariables.keys()).len != 0:
    return

  if toSeq(flowLine.variablesPositions.keys()).len == 0:
    for expression in step.exprOrder:
      if step.beforeValues.hasKey(expression) or step.afterValues.hasKey(expression):
        discard calculateVariablePosition(self, step.position, expression)

    for expression, value in step.beforeValues:
      if not flowLine.variablesPositions.hasKey(expression):
        discard calculateVariablePosition(self, step.position, expression)

    for expression, value in step.afterValues:
      if not flowLine.variablesPositions.hasKey(expression):
        discard calculateVariablePosition(self, step.position, expression)

  self.sortVariablesPositions(step, false)

proc renderActiveLoopIterationValues(self: FlowComponent) =
  ## Repaint the values of whichever pass each on-screen loop is showing.
  ##
  ## The selection is this file's (it reads the live `flowLoops` DOM registry);
  ## the deduplication and reading order are `flow_layout.orderIterationSteps`,
  ## the same ordering `activeLoopIterationStepCounts` uses — which is the point
  ## of sharing it, since the two used to carry identical copies.
  var candidates: seq[tuple[stepCount: int, line: int]] = @[]

  for stepCount in 0 ..< self.flow.steps.len:
    let step = self.flow.steps[stepCount]
    if step.loop < 0 or step.loop >= self.flow.loops.len:
      continue

    let registeredLine = self.flow.loops[step.loop].registeredLine
    if not self.flowLoops.hasKey(registeredLine):
      continue

    let loopStep = self.flowLoops[registeredLine].loopStep
    if loopStep.loop == step.loop and loopStep.iteration == step.iteration:
      candidates.add((stepCount: stepCount, line: step.position))

  let stepCounts = orderIterationSteps(candidates)

  for stepCount in stepCounts:
    let step = self.flow.steps[stepCount]
    self.renderLoopIterationStepValue(step.loop, step)

type
  LoopIterationRenderData = ref object
    self: FlowComponent

proc doRenderActiveLoopIterationValues(data: LoopIterationRenderData) {.cdecl.} =
  if data.self.isNil or data.self.flow.isNil or not data.self.flowIsLive:
    return
  data.self.renderActiveLoopIterationValues()
  if not data.self.inExtension and not data.self.editorUI.isNil:
    data.self.editorUI.adjustEditorWidth()
    data.self.resizeFlowSlider()

proc scheduleActiveLoopIterationValueRender*(self: FlowComponent) =
  # Cancel any render that was queued by an earlier call so that rapid slider
  # moves don't pile up cascading re-renders.  We keep exactly two renders:
  #   • an immediate deferred render (next event-loop tick, 0 ms) for
  #     responsiveness,
  #   • a 300 ms fallback that catches Monaco view-zone settle after the fast
  #     sequence of slider events ends.
  if self.pendingRenderTimerId != -1:
    windowClearTimeout(self.pendingRenderTimerId)
    self.pendingRenderTimerId = -1
  let renderData = LoopIterationRenderData(self: self)
  # Immediate deferred render.
  self.pendingRenderTimerId = windowSetTimeout(proc() =
    doRenderActiveLoopIterationValues(renderData)
    # Single fallback render after Monaco has finished adjusting view zones.
    renderData.self.pendingRenderTimerId = windowSetTimeout(proc() =
      doRenderActiveLoopIterationValues(renderData)
      renderData.self.pendingRenderTimerId = -1
    , 300)
  , 0)

proc renderFlowLines*(self: FlowComponent) =
  # cdebug "flow: renderFlowLines"
  let editorContentLeft =
    if self.inExtension:
      0.0
    else:
      self.editorUI.monacoEditor.config.layoutInfo.contentLeft.float

  self.createLoopStates()

  let positions = self.sortedFlowLinePositions()

  # Render loop controls before loop-local values.  `flowLines` is backed by a
  # JS object, so relying on its iteration order can visit body lines before
  # the registered loop line and permanently skip their values.
  for line in positions:
    try:
      let stepCount = self.getCurrentStepCount(line)
      if stepCount < 0 or stepCount >= self.flow.steps.len:
        continue
      let step = self.flow.steps[stepCount]
      let loopId = step.loop

      # TODO: We need to calculate the position beforehand
      # it will be used both in the extension and standalone
      self.prepareFlowLineVariables(step)

      if not self.stepNodes.hasKey(step.stepCount) and
         loopId >= 0 and loopId < self.flow.loops.len and
         step.position == self.flow.loops[loopId].registeredLine:
        self.addLoopInfo(step)
    except IndexDefect:
      cerror cstring(fmt"flow: renderFlowLines IndexDefect for line {line}")
      continue

  self.renderActiveLoopIterationValues()

  if toSeq(self.flowLoops.keys()).len > 0:
    self.scheduleActiveLoopIterationValueRender()

  for line in positions:
    try:
      let stepCount = self.getCurrentStepCount(line)
      if stepCount < 0 or stepCount >= self.flow.steps.len:
        continue
      let step = self.flow.steps[stepCount]

      self.prepareFlowLineVariables(step)

      # add step values
      if not self.stepNodes.hasKey(step.stepCount):
        if step.loop >= 0 and step.loop < self.flow.loops.len and
           step.position == self.flow.loops[step.loop].registeredLine and
           self.flowLoops.hasKey(step.position):
          continue
        if step.beforeValues.len > 0 or step.afterValues.len > 0 or step.events.len > 0:
          self.addStepValues(step)
    except IndexDefect:
      cerror cstring(fmt"flow: renderFlowLines IndexDefect for line {line}")
      continue

proc reloadFlow*(self:FlowComponent) =
  self.renderFlowLines()

type
  FlowRedrawData = ref object
    self: FlowComponent

proc doFlowRedraw(data: FlowRedrawData) {.cdecl.} =
  if data.self.isNil or data.self.flow.isNil or not data.self.flowIsLive:
    return
  data.self.redrawFlow()
  data.self.redraw()
  data.self.scheduleActiveLoopIterationValueRender()

proc scheduleFlowRedraw(self: FlowComponent, delay: int) =
  let redrawData = FlowRedrawData(self: self)
  setTimeoutWithArg(doFlowRedraw, delay, redrawData)

proc createFlowLines(self: FlowComponent) =
  let editorContentLeft =
    if self.inExtension:
      0.0
    else:
      self.editorUI.monacoEditor.config.layoutInfo.contentLeft.float

  for line, stepCounts in self.flow.positionStepCounts:
    if self.inExtension or line < self.tab.sourceLines.len:
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
  let option = self.editorUI.monacoEditor.getOption(FONT_INFO)

  self.lineHeight = option.lineHeight - 4
  self.fontSize = option.fontSize - 2

proc recalculateAndRedrawFlow*(self: FlowComponent) =
  # A retired component must not build view zones (see `redrawFlow`).
  if not self.flowIsLive:
    return
  if not self.flow.isNil:
    self.createFlowLines()
    if not self.inExtension:
      self.calculateLineHeight()
    self.renderFlowLines()

    if self.mutationObserver.isNil and not self.inExtension:
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
    # A component the editor has already replaced must not adopt a flow window
    # and rebuild itself — the replacement owns the view now. See `flowIsLive`.
    if not self.flowIsLive:
      cdebug "flow: update delivered to a superseded component: stopping"
      return
    if update.isNil:
      cdebug "flow: update is nil: stopping"
      return
    if update.location.toJs.isNil:
      cdebug "flow: update location is nil: stopping"
      return
    let updateLocationName = if self.inExtension or self.editorUI.editorView != ViewInstructions:
        update.location.highLevelPath
      else:
        # should be always path:name
        update.location.highLevelPath & cstring":" & update.location.functionName

    # Accept the update if EITHER:
    #
    #   * the editor name matches the update's resolved location
    #     (the historic equality check), OR
    #   * the FlowComponent was created for a location whose
    #     ``highLevelPath`` matches the editor name (i.e. this is the
    #     response for a request the editor itself originated).
    #
    # The second branch is required for Noir traces (and any backend
    # that rewrites ``location.high_level_path`` via
    # ``find_function_location``) where a call into ``iterate_asteroids``
    # in ``shield.nr`` is resolved by the backend to the enclosing
    # function in ``main.nr``.  Without this relaxation the
    # ``ct/updated-flow`` event for a shield.nr load is dropped here
    # and ``.flow-multiline-value-container`` never renders.
    # See /tmp/isonim-migration.txt §1.64 (noir-space-ship §5.8).
    let locationMatchesRequest =
      not self.location.toJs.isNil and
      $self.location.highLevelPath == $self.editorUI.name
    if not self.inExtension and
        self.editorUI.name != updateLocationName and
        not locationMatchesRequest:
      cdebug "flow: editor name not equal to update location name: stopping"
      return

    self.status = update.status

    let editorView = if self.inExtension: EditorView.ViewSource else: self.editorUI.editorView
    if ord(editorView) < 0 or ord(editorView) >= update.view_updates.len:
      cerror "flow: editorView index out of bounds: " & $ord(editorView) & " updates len: " & $update.view_updates.len
      return

    if not self.inExtension:
      self.editorUI.flowUpdate = update

    if update.location.key != self.key or self.flow.isNil:
      # Full rebuild required when:
      #   * the location key changed (different file/function/loop structure), OR
      #   * this component has never received flow data yet (self.flow is nil).
      #
      # The `self.flow.isNil` guard is critical for components freshly created
      # by `loadFlow()`: they start with key="" and flow=nil. If the server
      # also sends key="" the string comparison alone would be false, landing
      # in the in-place branch where no DOM is built and handoffFlow is never
      # cleared — causing old zones to accumulate with each navigation.
      self.resetFlow()
      self.key = update.location.key
      if self.flow.isNil:
        self.flow = update.view_updates[editorView]
      self.redrawFlow()
      # Now that the new DOM is built, remove the entire chain of superseded
      # components' Monaco view zones. Walking the chain (not just one level)
      # is necessary for rapid navigations where multiple loadFlow() calls
      # queued before any CtUpdatedFlow arrived: each intermediate component
      # carries its own handoffFlow pointer, and without the loop their zones
      # would accumulate as view-zone duplicates.
      var prev = self.handoffFlow
      while not prev.isNil:
        let next = prev.handoffFlow
        prev.resetFlow()
        prev.handoffFlow = nil
        prev = next
      self.handoffFlow = nil
      self.updateFlowOnMove(self.location.rrTicks, self.location.line)
      self.recalculate = true
      # NOTE: a no-op in the app (`FlowComponent` overrides only
      # `redrawForExtension`); kept because it rebinds the extension host.
      self.redraw()
      # One deferred rebuild to capture offsets Monaco has not yet laid out.
      self.scheduleFlowRedraw(100)
      self.scheduleActiveLoopIterationValueRender()
    else:
      # Same location key and component already has DOM: the flow structure
      # (loops, lines) is unchanged. Only step data and active iteration
      # changed — update existing DOM nodes in-place without teardown.
      # This is the hot path during noUiSlider drags and arrow-button clicks.
      # handoffFlow should be nil here (new components always hit the branch
      # above due to self.flow.isNil), but clear it defensively.
      if not self.handoffFlow.isNil:
        self.handoffFlow.resetFlow()
        self.handoffFlow = nil
      # NOTE: do NOT replace self.flow here. flowLines.loopStepCounts still holds
      # indices into the existing self.flow.steps array. Replacing self.flow with
      # new step data that may have a different step count would invalidate those
      # indices and cause an IndexDefect in updateFlowOnMove. The canReuseFlow
      # path in EditorViewComponent.onCompleteMove no longer emits CtLoadFlow for
      # same-function navigation, so in-place updates are driven entirely by
      # FlowComponent.onCompleteMove (which does NOT replace self.flow).
      self.updateFlowOnMove(self.location.rrTicks, self.location.line)
      self.scheduleActiveLoopIterationValueRender()
  except:
    cerror "flow: " & getCurrentExceptionMsg()


proc varStyle(self: FlowComponent, fields: seq[cstring]): VStyle =
  let width = 70 / fields.len.float
  style((StyleAttr.cssFloat, cstring"left"))

proc makeLoopSliderChildDom(self: FlowComponent, position: int, includeEmptyText: bool = false): Node =
  result = document.createElement(cstring"div")
  result.setAttribute(cstring"class", cstring"flow-loop-slider")
  result.setAttribute(cstring"id", cstring(&"flow-loop-slider-{position}"))

  if not self.inExtension:
    var leftValue = cast[Element](self.flowLoops[position].flowDom).clientWidth
    var widthValue = cstring"0px"

    if leftValue != 0:
      widthValue = cstring(fmt"{calculateLoopSliderWidth(self, leftValue)}px")
    else:
      self.shouldRecalcFlow = true

    result.style.width = fmt"calc({widthValue} - {SLIDER_OFFSET}ch)".cstring
    result.style.fontSize = cstring($data.ui.fontSize)
    result.style.fontFamily = cstring"SpaceGrotesk"
    result.style.marginLeft = cstring"4ch"
    result.style.height = cstring($self.lineHeight & "px")
    result.style.lineHeight = cstring($self.lineHeight & "px")

  if includeEmptyText:
    result.appendChild(document.createTextNode(cstring""))

proc makeLoopSliderContainerDom(self: FlowComponent, position: int): Node =
  result = document.createElement(cstring"div")
  result.setAttribute(cstring"class", cstring"flow-loop-slider-container")
  result.setAttribute(cstring"id", cstring(&"flow-loop-slider-container-{position}"))

  if not self.inExtension:
    let flowDomWidth = self.flowLoops[position].flowDom.toJs.clientWidth
    result.style.left = cstring(fmt"calc({flowDomWidth}px - 2ch)")
    result.style.fontSize = cstring($data.ui.fontSize & "px")

  result.appendChild(self.makeLoopSliderChildDom(position))

proc makeSliderDom(self: FlowComponent, position: int): Node =
  var dom = cast[Node](jq(&"#flow-loop-slider-container-{position}"))
  if dom.isNil:
    # `makeLoopSliderContainerDom` already appends the inner `.flow-loop-slider`
    # element; a fresh container therefore needs nothing more.
    dom = self.makeLoopSliderContainerDom(position)

  # Look for the inner slider element INSIDE the container we are returning,
  # not with a document-wide id query.
  #
  # This used to be `jq(&"flow-loop-slider-{position}")` — a tag selector,
  # missing the leading `#`, that could never match anything. The result was an
  # extra `.flow-loop-slider` div (with a duplicate id) appended to the reused
  # container on every rebuild, while `sliderDom` kept pointing at the first
  # one, leaving a stack of dead empty divs behind (#562).
  var sliderDom = cast[Node](dom.querySelector(cstring".flow-loop-slider"))
  if sliderDom.isNil:
    sliderDom = self.makeLoopSliderChildDom(position, includeEmptyText = true)
    dom.appendChild(sliderDom)

  self.flowLoops[position].sliderDom = sliderDom
  if self.flowLines.hasKey(position):
    self.flowLines[position].sliderDom = sliderDom

  return dom

proc addSliderWidget(self: FlowComponent, position:int) =
  let dom = makeSliderDom(self, position)

  self.flowLoops[position].flowDom.appendChild(dom)

proc removeSliderWidget(self: FlowComponent, position: int) =
  ## Drop the slider container for `position`, if one is present.
  ##
  ## Needed for loops that have only a single iteration in the current flow
  ## window: noUiSlider cannot be created over a zero-width range, and the bare
  ## container renders as an empty artefact next to the iteration counter — the
  ## "a container with nothing in it" half of #562.
  if self.flowLoops.hasKey(position):
    self.flowLoops[position].sliderDom = nil
  if self.flowLines.hasKey(position):
    self.flowLines[position].sliderDom = nil

  let container = cast[Node](jq(&"#flow-loop-slider-container-{position}"))
  if not container.isNil and not container.parentNode.isNil:
    container.parentNode.removeChild(container)

proc resizeEditorHandler(self:FlowComponent, position: int) =
  # get new monaco editor config
  self.editorUI.monacoEditor.config = getConfiguration(self.editorUI.monacoEditor)
  self.resizeFlowSlider()

type
  ResizeEditorData = ref object
    self: FlowComponent
    position: int

proc triggerResizeEditorHandler(data: ResizeEditorData) {.cdecl.} =
  if not data.self.isNil:
    resizeEditorHandler(data.self, data.position)

proc setEditorResizeObserver(self: FLowComponent, position: int) =
  let activeEditor = "\"" & self.data.services.editor.active & "\""
  let editorDom = jq(fmt"[data-label={activeEditor}]")
  let resizeData = ResizeEditorData(self: self, position: position)
  let resizeObserver = createResizeObserver(proc(entries: seq[Element]) =
    for entry in entries:
      setTimeoutWithArg(triggerResizeEditorHandler, 100, resizeData))

  resizeObserver.observe(cast[Node](editorDom))

# `calculateLineIndentations` used to be here: the spec's "Indentation
# Tracking" positioning rule, answered by counting Monaco's rendered `.cigr`
# indent-guide elements in a line's view overlay. It had NO CALL SITE — it was
# forward-declared, defined, and invoked from nowhere in the tree, and
# `FlowLine.indentationsCount` was never read — so the rule was, on the desktop,
# computed by nothing. It now lives as `flow_layout.sourceIndentLevel`, which
# counts leading whitespace instead of rendered guides and is therefore
# available to a renderer that has no Monaco. Removing the DOM version cannot
# change what the desktop draws, because nothing drew from it.

proc createFlowViewZone(self: FlowComponent, position: int, heightInPx: float, isLoop: bool = false): Node =
  #create viewZone
  var zoneDom = document.createElement("div")

  zoneDom.id = fmt"flow-view-zone-{position}"
  zoneDom.class = "flow-view-zone"
  zoneDom.style.display = "flex"

  if not self.inExtension:
    let viewZone = js{
          afterLineNumber: position,
          heightInPx: heightInPx + 3,
          domNode: zoneDom
        }

    if isLoop:
      var zoneId = addMonacoViewZone(self.editorUI.monacoEditor, viewZone)
      self.loopViewZones[position] = zoneId
    else:
      var zoneId = addMonacoViewZone(self.editorUI.monacoEditor, viewZone)
      self.viewZones[position] = zoneId

  # calculate previous position indentations count
  let lineNumberDom = document.createElement("div")

  lineNumberDom.class = "line-numbers"
  lineNumberDom.style.height = "100%"
  if not self.inExtension:
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

proc loopControlWidth(self: FlowComponent, position: int): int =
  ## Rendered width in px of the loop control the slider is laid out against.
  ##
  ## 0 means "not measurable yet": Monaco attaches and lays out a freshly
  ## registered view zone on a later frame, so the control's DOM node has no
  ## box during the tick in which we build it.
  if self.flowLoops.hasKey(position) and not self.flowLoops[position].flowDom.isNil:
    cast[Element](self.flowLoops[position].flowDom).clientWidth
  else:
    0

proc ensureLoopSlider*(self: FlowComponent, position: int) =
  ## Create — or, if it already exists with the right range, just re-position —
  ## the noUiSlider for the loop control at `position`.
  ##
  ## #562, primary cause: this used to run unconditionally and synchronously
  ## from `makeFlowLoops`, in the same tick in which `addLoopInfo` registered a
  ## brand-new Monaco view zone. At that moment `flowDom.clientWidth` is 0, so
  ## the slider was created with `width: calc(0px - 6ch)` inside a container at
  ## `left: calc(0px - 2ch)`: present in the DOM, 0 x 2 px, parked to the left of
  ## the control, invisible on screen and reported as not visible by Playwright.
  ## Whether it ever became visible depended entirely on a later
  ## `resizeFlowSlider` from the 0/100/500/1000/2000 ms timer fan-out.
  ##
  ## The fix is to make creation conditional on being measurable rather than to
  ## add more timers (the fan-out is itself part of the flicker in #562's second
  ## half). `resizeFlowSlider` — already driven by that render pass and by the
  ## editor resize observer — calls back in and creates the slider the first
  ## time the zone has a real width.
  if not self.flowLoops.hasKey(position):
    return

  let flowLoop = self.flowLoops[position]
  let element = flowLoop.sliderDom
  if element.isNil:
    return

  let step = flowLoop.loopStep
  let maxIteration = self.maxLoopIteration(step.loop)

  # Defer until the hosting view zone has been laid out. `shouldRecalcFlow`
  # records that a recalculation is still owed.
  #
  # ONLY outside the extension, and that has always been the rule: the
  # extension has no `resizeFlowSlider` path to come back on
  # (`doRenderActiveLoopIterationValues` schedules it behind
  # `if not data.self.inExtension`, and `resizeEditorHandler` needs an
  # `editorUI.monacoEditor` the extension does not have), so deferring there
  # means never building the slider at all.  `requireMeasurable` below carries
  # the same condition into `ensureFlowLoopSlider`, which would otherwise apply
  # lesson 1 unconditionally and reintroduce exactly that.
  let canDeferForWidth = not self.inExtension
  if canDeferForWidth and maxIteration > FLOW_ITERATION_START and
     self.loopControlWidth(position) == 0:
    self.shouldRecalcFlow = true
    return

  let iteration = self.activeLoopIterationFor(step)

  # The construction, the idempotency marker and the `slide` wiring all live in
  # `flow_loop_slider.nim` now, shared with the review's own loop control
  # (RV-10 / UD-3): a review can measure a slider after all, so the reason the
  # two were different has gone and one implementation is what keeps them the
  # same control.  Everything the DEBUGGER does with a new iteration — the
  # active step, the jump, the counter DOM — stays here, because a review has
  # no debugger position to move.
  let slid = ensureFlowLoopSlider(element, maxIteration, iteration,
    proc(loopIteration: int) =
      let newTimeInMs = now()
      let activeStep = self.loopIterationStepAt(step.loop, loopIteration, step.position)

      if activeStep.stepCount != NO_STEP_COUNT:
        self.flowLoops[position].loopStep = activeStep
        self.activeStep = activeStep
      self.lastSliderUpdateTimeInMs = newTimeInMs
      self.selectLoopIteration(step.loop, loopIteration, step.position)
      self.updateLoopControlDom(step.position)
      # Affect the complete move to have a delay on the update
      # Maybe later on add to all of the EventLog components?
      cast[EventLogComponent](data.ui.componentMapping[Content.EventLog][0]).isFlowUpdate = true
    ,
    requireMeasurable = canDeferForWidth
  )
  # The width gate above measures the CONTAINER; `ensureFlowLoopSlider`
  # measures the slider element itself, and the two can disagree — the slider's
  # own `width: calc(...)` is applied by `resizeFlowSlider`, so on the
  # `makeSlider` path the container can have a box in the tick the slider
  # inside it does not.
  #
  # That second refusal is kept, because "never construct at zero width" is
  # #562's actual lesson and the container's width is not evidence for it. What
  # is NOT kept is its silence: a refusal for width must always leave a
  # recalculation owed, or the slider is lost until some unrelated resize
  # happens to run. Benign today — `resizeFlowSlider` applies `loopSliderStyle`
  # before calling back in — but "benign today" is how #562 was introduced, and
  # this is one assignment.
  if not slid and canDeferForWidth and maxIteration > FLOW_ITERATION_START and
     not flowLoopSliderIsMeasurable(element):
    self.shouldRecalcFlow = true
  if not slid and maxIteration <= FLOW_ITERATION_START:
    # The zero-range refusal used to remove the container here as well as
    # destroy the widget; `ensureFlowLoopSlider` destroys, and the container is
    # this host's to drop.
    self.removeSliderWidget(position)

proc makeSlider(self: FlowComponent, position: int) =
  if not self.flowLoops.hasKey(position):
    return

  # Suppress the container entirely for loops with a single iteration — see
  # `ensureLoopSlider`. Doing this BEFORE `addSliderWidget` is what keeps an
  # empty `.flow-loop-slider-container` from being inserted at all.
  if self.maxLoopIteration(self.flowLoops[position].loopStep.loop) <= FLOW_ITERATION_START:
    self.removeSliderWidget(position)
    return

  self.addSliderWidget(position)
  self.ensureLoopSlider(position)

  if not self.inExtension:
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

proc flowFontAwesomeIcon(typ: string, kl: string = ""): Node =
  result = document.createElement(cstring"i")
  result.setAttribute(cstring"class", cstring(fmt"fa fa-{typ} {kl}"))

proc moveButtonsView(self: FlowComponent, visibleWidth: float): Node =
  result = document.createElement(cstring"div")
  result.setAttribute(cstring"class", cstring"move-buttons")

  let leftStyle = style((StyleAttr.left, cstring($(self.maxFlowLineWidth - 4) & cstring"ex")))
  let rightStyle = style((StyleAttr.marginLeft, cstring($(visibleWidth + MAX_CELL_WIDTH.float)) & cstring"px"))

  let leftButton = document.createElement(cstring"div")
  leftButton.setAttribute(cstring"class", cstring"flow-left-button")
  leftButton.applyStyle(leftStyle)
  leftButton.addEventListener(cstring"click", proc(e: Event) =
    if not self.selected:
      discard self.select()
    discard self.onLeft()
  )
  leftButton.appendChild(flowFontAwesomeIcon("caret-left"))
  result.appendChild(leftButton)

  let rightButton = document.createElement(cstring"div")
  rightButton.setAttribute(cstring"class", cstring"flow-right-button")
  rightButton.applyStyle(rightStyle)
  rightButton.addEventListener(cstring"click", proc(e: Event) =
    if not self.selected:
      discard self.select()
    discard self.onRight()
  )
  rightButton.appendChild(flowFontAwesomeIcon("caret-right"))
  result.appendChild(rightButton)

proc iterationVarView(self: FlowComponent, line: int, field: cstring, style: VStyle): Node =
  var limitedLabel = if ($field).len > 5: ($field)[0 .. ^4] & ".." else: $field

  result = document.createElement(cstring"div")
  result.applyStyle(style)
  result.appendChild(document.createTextNode(cstring(limitedLabel)))

proc iterationInfoView(self: FlowComponent, line: int, fields: seq[cstring]): Node =
  result = document.createElement(cstring"div")
  result.setAttribute(cstring"class", cstring"flow-iteration-info")

  let style = self.varStyle(fields)
  for variable in fields:
    result.appendChild(iterationVarView(self, line, variable, style))

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

                if self.data.config.flow.realFlowUI != FlowMultiline:
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

proc renderFlow*(self: FlowComponent, position: int, stepCount: int): Node =
  if stepCount notin self.flow.steps.low .. self.flow.steps.high:
    return
  var step = self.flow.steps[stepCount]

  if step.loop == -1:
    # Built through `flow_value_dom`, shared with the review's diff tab (UD-3).
    # `flowLeftStyle`'s own `left` is applied on top, because this host's offset
    # is a `calc()` in `ch` rather than a pixel count.
    result = flowValueBandDom(0.0, isLoop = false)
    result.applyStyle(self.flowLeftStyle())

    var style = style()
    var i = 0
    for name in step.exprOrder:
      result.appendChild(flowSimpleValue(self, name, step.beforeValues[name], step.afterValues[name], stepCount, true, style, i))
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

  if self.data.config.flow.realFlowUI != FlowMultiline:
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

  result = document.createElement(cstring"div")
  result.setAttribute(cstring"class", cstring(loopClass))

  for values in valueLines:
    if self.data.config.flow.realFlowUI == FlowMultiline and not self.multilineZones[position].variables[values[0]]:
      continue

    var lineClass = ""

    if not group.isNil and self.flow.loops[group.focusedLoopID].first == position:
      lineClass = "flow-loop-first-line"

    var res = flowValueBandDom(0.0, isLoop = true, extraClass = lineClass)
    res.applyStyle(flowLeftStyle(self))

    if not group.isNil and self.flow.loops[group.focusedLoopID].first == position:
      res.appendChild(moveButtonsView(self, visibleWidth))

    if self.data.config.flow.realFlowUI != FlowMultiline:
      res.appendChild(iterationInfoView(self, position, values))

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
      # The band's elements come from `flow_value_dom`, shared with the
      # review's diff tab (UD-3) so both draw one implementation's columns.
      var html = flowValueLoopValuesDom(loopID.int)
      html.addEventListener(cstring"scroll", proc(ev: Event) =
        discard
      )

      let parallelGroup = flowValueGroupDom()
      html.appendChild(parallelGroup)

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
            group.loopWidths[loopID][i] * group.baseWidth
        # `flowValueColumnDom` carries the "change the class on a width change
        # so Monaco cannot skip the re-render" rule with it.
        let valuesColumn = flowValueColumnDom(
          cstring(&"flow-values-{position}-{loopID.int}-{index}"), width)
        parallelGroup.appendChild(valuesColumn)

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
            valuesColumn.appendChild(flowValueEmptyDom(style))
          else:
            valuesColumn.appendChild(flowSimpleValue(
              self,
              name,
              currentStep.beforeValues[name],
              currentStep.afterValues[name],
              currentStepCount,
              false,
              style
            ))
      if hasLoop:
        res.appendChild(html)

    result.appendChild(res)

proc resizeFlowSlider*(self: FlowComponent) =
  self.shouldRecalcFlow = false

  for position, loop in self.flowLoops:
    if not loop.sliderDom.isNil:
      loop.sliderDom.applyStyle(self.loopSliderStyle(position))
      let container = jq(fmt"#flow-loop-slider-container-{position}")
      if not container.isNil and not loop.flowDom.isNil:
        let leftValue = cast[Element](loop.flowDom).clientWidth
        if leftValue != 0:
          container.style.left = cstring(fmt"calc({leftValue}px - 2ch)")

    # This is also the deferred-creation path for sliders whose Monaco view
    # zone had not been laid out yet when the loop control was built — see
    # `ensureLoopSlider`. It is a no-op once the slider exists at the right
    # range, so it is safe to run on every resize/render pass.
    self.ensureLoopSlider(position)

proc redrawFlow*(self: FlowComponent) =
  # Single choke point for "tear the flow view down and build it again".
  #
  # Several callers reach here from a `setTimeout` (`doFlowRedraw`,
  # `afterJump`) and therefore can run after the editor has already replaced
  # this component. Rebuilding then registers Monaco view zones that only the
  # retired component knows about — the live one cannot clear them — and paints
  # the previous debugger position's loop iteration over the current one
  # (#593/#595). See `flowIsLive`.
  if not self.flowIsLive:
    return

  self.clear()
  self.recalculateAndRedrawFlow()

  for _, zone in self.flowLoops:
    if not zone.flowZones.isNil:
      zone.flowZones.dom.style.toJs.left = self.leftPos

proc updateFlowOnMove*(self: FlowComponent, rrTicks: int, line: int) =
  let debuggerLocationRRTicks = rrTicks
  let debuggerLocationLine = line

  # `EditorViewComponent.onCompleteMove` creates the replacement FlowComponent
  # and then forwards the move to it, so this runs once with no flow data yet:
  # every reader below dereferences `self.flow`. The real render happens when
  # `ct/updated-flow` arrives.
  if self.flow.isNil:
    return

  self.setLoopStatesActiveIteration(debuggerLocationRRTicks)

  # Push the recomputed iteration into the loop controls that are already on
  # screen. `setLoopStatesActiveIteration` only touches model state; the
  # counter's textarea and the arrows' `disabled` flags are written at
  # DOM-construction time, so without this the number the user reads keeps
  # whatever value it was built with (#593). This also covers the path in
  # `EditorViewComponent.onCompleteMove` that reuses the existing flow and only
  # calls `redrawFlow()`.
  for position, _ in self.flowLoops:
    self.updateLoopControlDom(position)

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
      if flowLine.loopStepCounts.hasKey(activeLoop) and
         activeIteration >= 0 and
         activeIteration < flowLine.loopStepCounts[activeLoop].len and
         # The recorded step count is an index into the flow window that was
         # current when this line was rendered; the window may since have been
         # replaced by a shorter one (see `validFlowStepCount`).
         self.validFlowStepCount(flowLine.loopStepCounts[activeLoop][activeIteration]) and
         flowLine.stepLoopCells.hasKey(activeLoop) and
         flowLine.stepLoopCells[activeLoop].hasKey(activeIteration):
        let activeIterationStep = self.flow.steps[flowLine.loopStepCounts[activeLoop][activeIteration]]
        let activeIterationStepDom = flowLine.stepLoopCells[activeLoop][activeIteration]

        if not activeIterationStepDom.isNil:
          activeIterationStepDom.toJs.classList.toJs.add("active-flow-step")
          flowLine.activeIterationPosition =
            self.getStepDomOffsetLeft(activeIterationStep)
          if flowLine.activeIterationPosition > self.maxLoopActiveIterationOffset:
            self.maxLoopActiveIterationOffset = flowLine.activeIterationPosition

    case self.data.config.flow.realFlowUI:
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
            let valueNode = flowSimpleValue(
              self,
              expression,
              step.beforeValues[expression],
              step.afterValues[expression],
              step.stepCount,
              false,
              style())
            node.appendChild(valueNode)

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
            let valueNode = flowSimpleValue(
              self,
              expression,
              step.beforeValues[expression],
              step.afterValues[expression],
              step.stepCount,
              false,
              style())
            # Replace the existing child in a single DOM mutation to avoid the
            # two-repaint flash that innerHTML="" + appendChild produces.
            if node.firstChild.isNil:
              node.appendChild(valueNode)
            else:
              replaceChild(node, valueNode, node.firstChild)

    else:
      discard

  if self.flowLines.hasKey(debuggerLocationLine):
    let flowLineAtLocation = self.flowLines[debuggerLocationLine]
    let activeLoopAtLocation =
      flowLineAtLocation.activeLoopIteration.loopIndex
    let activeIterationAtLocation =
      flowLineAtLocation.activeLoopIteration.iteration
    if activeLoopAtLocation >= 0 and activeLoopAtLocation < self.flow.loops.len:
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

      if not self.flowLines[activeLoopFirstLine].sliderDom.isNil and not self.flowLines[activeLoopFirstLine].sliderDom.toJs.noUiSlider.isNil:
        self.flowLines[activeLoopFirstLine].sliderDom.toJs.noUiSlider.set(sliderPositionsCount)


method onCompleteMove*(self: FlowComponent, response: MoveState) {.async.} =
  self.location = response.location
  self.updateFlowOnMove(self.location.rrTicks, self.location.line)
  self.scheduleActiveLoopIterationValueRender()

method onLoadedFlowShape*(self: Component, update: FlowShape) {.async.} =
  discard

proc switchFlowType*(self: FlowComponent, flowType: FlowUI) =
  if self.data.config.flow.realFlowUI != flowType:
    self.resetFlow()
    self.data.config.flow.realFlowUI = flowType
    self.recalculateAndRedrawFlow()
    self.updateFlowDom()

when defined(ctInExtension):
  proc vsUpdatedFlow*(editor: JsObject, update: FlowUpdate) {.exportc.} =
    discard
    # discard cast[FlowComponent](vsCodeEditor.flow).onUpdatedFlow(update)

  proc completeMove*(editor: JsObject, response: MoveState, dapApi: DapApi) {.exportc.} =
    discard
    # vsCodeEditor.flow = FlowComponent(
    #   id: 0,
    #   flow: nil,
    #   # tab: self.tabInfo,
    #   location: response.location,
    #   multilineZones: JsAssoc[int, MultilineZone]{},
    #   flowDom: JsAssoc[int, Node]{},
    #   shouldRecalcFlow: false,
    #   flowLoops: JsAssoc[int, FlowLoop]{},
    #   flowLines: JsAssoc[int, FlowLine]{},
    #   activeStep: FlowStep(rrTicks: -1),
    #   selectedLine: -1,
    #   selectedLineInGroup: -1,
    #   selectedStepCount: -1,
    #   multilineValuesDoms: JsAssoc[int, JsAssoc[cstring, Node]]{},
    #   loopLineSteps: JsAssoc[int, int]{},
    #   inlineDecorations: JsAssoc[int, InlineDecorations]{},
    #   # editorUI: self,
    #   # scratchpadUI: if self.data.ui.componentMapping[Content.Scratchpad].len > 0: self.data.scratchpadComponent(0) else: nil,
    #   # editor: self.service,
    #   # service: self.data.services.flow,
    #   # data: self.data,
    #   lineGroups: JsAssoc[int, Group]{},
    #   # status: FlowUpdateState(kind: FlowWaitingForStart),
    #   statusWidget: nil,
    #   sliderWidgets: JsAssoc[int, js]{},
    #   lineWidgets: JsAssoc[int, js]{},
    #   multilineWidgets: JsAssoc[int, JsAssoc[cstring, js]]{},
    #   stepNodes: JsAssoc[int, Node]{},
    #   loopStates: JsAssoc[int, LoopState]{},
    #   viewZones: JsAssoc[int, int]{},
    #   loopViewZones: JsAssoc[int, int]{},
    #   loopColumnMinWidth: 15,
    #   shrinkedLoopColumnMinWidth: 8,
    #   pixelsPerSymbol: 8,
    #   distanceBetweenValues: 10,
    #   distanceToSource: 50,
    #   inlineValueWidth: 80,
    #   bufferMaxOffsetInPx: 300,
    #   maxWidth: 0,
    #   modalValueComponent: JsAssoc[cstring, ValueComponent]{},
    #   valueMode: BeforeValueMode
    # )

    # dapApi.sendCtRequest(CtLoadFlow, response.location.toJs)

when defined(ctInExtension):
  when defined(ctInCentralExtensionContext):
    {.emit: "module.exports.vsUpdatedFlow = vsUpdatedFlow".}
    {.emit: "module.exports.completeMove = completeMove".}
