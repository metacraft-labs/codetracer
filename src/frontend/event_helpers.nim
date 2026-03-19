import
  std / [ jsffi, strformat, algorithm ],
  .. / common / ct_event,
  types,
  communication, dap,
  lib/[ jslib ]

const HISTORY_JUMP_VALUE*: string = "history-jump"
const
  FLOW_DECORATION_MAX_VALUES_PER_LINE* = 10

type
  FlowLineRenderValue* = object
    line*: int
    text*: cstring
  FlowLoopSliderData* = object
    line*: int
    loopId*: int
    firstLine*: int
    lastLine*: int
    baseLoopId*: int
    baseIteration*: int
    iterationCount*: int
    minIteration*: int
    maxIteration*: int
    activeIteration*: int
    locationInside*: bool
    rrTicksForIterations*: seq[int]
  FlowInsetData* = object
    lineValues*: seq[FlowLineRenderValue]
    loopSliders*: seq[FlowLoopSliderData]

proc makeNotification*(kind: NotificationKind, text: cstring, isOperationStatus: bool = false): Notification =
  Notification(
    kind: kind,
    text: text,
    time: Date.now(),
    active: true,
    isOperationStatus: isOperationStatus)

proc ctSourceLineJump*(dap: DapApi, line: int, path: cstring, behaviour: JumpBehaviour) {.exportc.} =
    let target = SourceLineJumpTarget(
    path: path,
    line: line,
    behaviour: behaviour,
    )
    dap.sendCtRequest(CtSourceLineJump, target.toJs)

proc ctAddToScratchpad*(api: MediatorWithSubscribers, expression: cstring) {.exportc.} =
  api.emit(InternalAddToScratchpadFromExpression, expression)

proc historyJump*(api: MediatorWithSubscribers, location: types.Location) =
  api.emit(InternalNewOperation, NewOperation(name: HISTORY_JUMP_VALUE, stableBusy: true))
  api.emit(CtHistoryJump, location)

proc installCt() =
  when not defined(ctInExtension):
    data.ipc.send "CODETRACER::install-ct", js{}

proc showNotification*(api: MediatorWithSubscribers, notification: Notification) =
  api.emit(CtNotification, notification)

proc infoMessage*(api: MediatorWithSubscribers, text: cstring) =
  let notification =
    makeNotification(NotificationKind.NotificationInfo, text)
  api.showNotification(notification)

proc installMessage*(api: MediatorWithSubscribers) =
  let notification = newNotification(
    NotificationKind.NotificationInfo,
    "CodeTracer isn't installed. Do you want to install it?",
    actions = @[newNotificationButtonAction("Install", proc = installCt())]
  )
  api.showNotification(notification)

proc warnMessage*(api: MediatorWithSubscribers, text: cstring) =
  let notification =
    makeNotification(NotificationKind.NotificationWarning, text)
  api.showNotification(notification)

proc errorMessage*(api: MediatorWithSubscribers, text: cstring) =
  let notification =
    makeNotification(NotificationKind.NotificationError, text)
  api.showNotification(notification)

proc successMessage*(api: MediatorWithSubscribers, text: cstring) =
  let notification =
    makeNotification(NotificationKind.NotificationSuccess, text)
  api.showNotification(notification)

proc openValueInScratchpad*(api: MediatorWithSubscribers, arg: ValueWithExpression) =
  api.emit(InternalAddToScratchpad, arg)

proc getStepExpressions*(step: FlowStep): seq[cstring] {.exportc.} =
  ## Resolve expressions in a stable order:
  ## 1) exprOrder from backend, 2) missing before-values keys, 3) missing after-values keys.
  var expressions: seq[cstring] = @[]
  for expression in step.exprOrder:
    if expression.len > 0 and not expressions.contains(expression):
      expressions.add(expression)
  for expression, _ in step.beforeValues:
    if expression.len > 0 and not expressions.contains(expression):
      expressions.add(expression)
  for expression, _ in step.afterValues:
    if expression.len > 0 and not expressions.contains(expression):
      expressions.add(expression)
  result = expressions

proc getStepValuePair*(
  step: FlowStep,
  expression: cstring
): tuple[beforeValue: Value, afterValue: Value] {.exportc.} =
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
  (beforeValue: beforeValue, afterValue: afterValue)

proc findExpressionColumn*(sourceLine: cstring, expression: cstring): int {.exportc.} =
  ## Find a 1-based column for a whole-word expression match within a source line.
  if sourceLine.len == 0 or expression.len == 0:
    return -1
  let pattern = regex("[^a-zA-Z0-9_'\"]" & expression & "[^a-zA-Z0-9_'\"]")
  let match = pattern.exec(sourceLine)
  if match.isNil:
    return -1
  let lineIndex = match.index.to(int)
  if lineIndex + 1 >= sourceLine.len:
    return -1
  lineIndex + 2

proc formatRenderText(expression: cstring, beforeValue: Value, afterValue: Value): cstring =
  ## Match flowSimpleValue text rules for before/after rendering.
  if beforeValue.isNil and afterValue.isNil:
    return cstring""
  if not beforeValue.isNil and not afterValue.isNil:
    let beforeText = beforeValue.textRepr(compact = true)
    let afterText = afterValue.textRepr(compact = true)
    if beforeText == afterText:
      return cstring(fmt"{expression}: {beforeText}")
    return cstring(fmt"{expression}: {beforeText} => {afterText}")
  if not afterValue.isNil:
    return cstring(fmt"{expression}: {afterValue.textRepr(compact = true)}")
  cstring(fmt"{expression}: {beforeValue.textRepr(compact = true)}")

proc computeRenderValueGroups*(update: FlowUpdate, sourceLines: seq[cstring]): seq[FlowRenderValue] {.exportc.}

proc resolveFlowViewUpdate(update: FlowUpdate): FlowViewUpdate =
  if update.isNil:
    return nil
  result = update.viewUpdates[ViewSource]
  if result.isNil:
    for candidate in update.viewUpdates:
      if not candidate.isNil:
        return candidate

proc findStepCountForPositionAtRRTicks(
  viewUpdate: FlowViewUpdate,
  position: int,
  rrTicks: int
): int =
  ## Equivalent to flow.nim positionRRTicksToStepCount for active step resolution.
  if viewUpdate.isNil:
    return -1
  if not viewUpdate.positionStepCounts.hasKey(position):
    return -1
  let stepCounts = viewUpdate.positionStepCounts[position]
  if stepCounts.len == 0:
    return -1

  let firstStepCount = stepCounts[0]
  let lastStepCount = stepCounts[^1]

  if rrTicks < viewUpdate.steps[firstStepCount].rrTicks:
    return firstStepCount
  if rrTicks > viewUpdate.steps[lastStepCount].rrTicks:
    return lastStepCount

  for i, stepCount in stepCounts:
    let nextStepCount = stepCounts[min(i + 1, stepCounts.len - 1)]
    if rrTicks >= viewUpdate.steps[stepCount].rrTicks and rrTicks <= viewUpdate.steps[nextStepCount].rrTicks:
      return stepCount

  lastStepCount

proc loopDepth(viewUpdate: FlowViewUpdate, loopId: int): int =
  var depth = 0
  var current = loopId
  while current > 0 and current < viewUpdate.loops.len:
    let baseLoop = viewUpdate.loops[current].base
    if baseLoop < 0:
      break
    depth += 1
    current = baseLoop
  depth

proc activeLoopIterationForTicks*(
  rrTicksForIterations: seq[int],
  debuggerLocationRRTicks: int
): int {.exportc.} =
  ## Resolve active loop iteration from rrTicks using nearest-left semantics.
  if rrTicksForIterations.len == 0:
    return 0
  let firstLoopIterationRRTicks = rrTicksForIterations[0]
  let lastLoopIterationRRTicks = rrTicksForIterations[rrTicksForIterations.len - 1]
  if debuggerLocationRRTicks <= firstLoopIterationRRTicks:
    return 0
  if debuggerLocationRRTicks >= lastLoopIterationRRTicks:
    return rrTicksForIterations.len - 1
  for index in countdown(rrTicksForIterations.len - 1, 0):
    if debuggerLocationRRTicks >= rrTicksForIterations[index]:
      return index
  0

proc computeFlowLineValuesFromRenderValues*(
  renderValues: seq[FlowRenderValue],
  maxValuesPerLine: int = FLOW_DECORATION_MAX_VALUES_PER_LINE
): seq[FlowLineRenderValue] {.exportc.} =
  var lineToValues = JsAssoc[int, seq[FlowRenderValue]]{}
  var lines: seq[int] = @[]

  for value in renderValues:
    if value.line <= 0 or value.text.len == 0:
      continue
    if not lineToValues.hasKey(value.line):
      lineToValues[value.line] = @[]
      lines.add(value.line)
    var lineValues = lineToValues[value.line]
    lineValues.add(value)
    lineToValues[value.line] = lineValues

  lines.sort(proc(a, b: int): int = a - b)

  for line in lines:
    var lineValues = lineToValues[line]
    lineValues.sort(proc(a, b: FlowRenderValue): int =
      if a.column != b.column:
        return a.column - b.column
      cmp(a.text, b.text)
    )
    var texts: seq[cstring] = @[]
    for i, lineValue in lineValues:
      if i >= maxValuesPerLine:
        break
      texts.add(lineValue.text)
    if texts.len > 0:
      var lineText = cstring""
      for i, text in texts:
        if i > 0:
          lineText.add(cstring", ")
        lineText.add(text)
      result.add(FlowLineRenderValue(line: line, text: lineText))

proc computeFlowLineValues*(
  update: FlowUpdate,
  sourceLines: seq[cstring],
  maxValuesPerLine: int = FLOW_DECORATION_MAX_VALUES_PER_LINE
): seq[FlowLineRenderValue] {.exportc.} =
  let renderValues = computeRenderValueGroups(update, sourceLines)
  result = computeFlowLineValuesFromRenderValues(renderValues, maxValuesPerLine)

proc computeActiveRenderValues*(
  update: FlowUpdate,
  sourceLines: seq[cstring]
): seq[FlowRenderValue] {.exportc.} =
  ## Build render values from active iteration steps at the current debugger rrTicks.
  let viewUpdate = resolveFlowViewUpdate(update)
  if viewUpdate.isNil:
    return @[]

  let currentRRTicks = update.location.rrTicks
  var stepCountByLine = JsAssoc[int, int]{}

  # Baseline active step per line at current rrTicks.
  for position, _ in viewUpdate.positionStepCounts:
    let stepCount = findStepCountForPositionAtRRTicks(viewUpdate, position, currentRRTicks)
    if stepCount >= 0 and stepCount < viewUpdate.steps.len:
      stepCountByLine[position] = stepCount

  # Override by active iteration of each loop so all lines in active iterations are rendered.
  var loopIds: seq[int] = @[]
  for loopId, loop in viewUpdate.loops:
    if loopId <= 0:
      continue
    if loop.iteration <= 0:
      continue
    loopIds.add(loopId)
  loopIds.sort(proc(a, b: int): int =
    let depthA = loopDepth(viewUpdate, a)
    let depthB = loopDepth(viewUpdate, b)
    if depthA != depthB:
      return depthA - depthB
    a - b
  )

  for loopId in loopIds:
    let loop = viewUpdate.loops[loopId]
    let activeIteration =
      activeLoopIterationForTicks(loop.rrTicksForIterations, currentRRTicks)
    if loopId >= viewUpdate.loopIterationSteps.len:
      continue
    if activeIteration < 0 or activeIteration >= viewUpdate.loopIterationSteps[loopId].len:
      continue
    let iterationTable = viewUpdate.loopIterationSteps[loopId][activeIteration].table
    for line, stepCount in iterationTable:
      if stepCount >= 0 and stepCount < viewUpdate.steps.len:
        stepCountByLine[line] = stepCount

  var valuesByKey = JsAssoc[cstring, FlowRenderValue]{}
  for position, stepCount in stepCountByLine:
    let step = viewUpdate.steps[stepCount]
    let lineIndex = step.position - 1
    if lineIndex < 0 or lineIndex >= sourceLines.len:
      continue

    for expression in getStepExpressions(step):
      let (beforeValue, afterValue) = getStepValuePair(step, expression)
      if beforeValue.isNil and afterValue.isNil:
        continue
      let column = findExpressionColumn(sourceLines[lineIndex], expression)
      if column < 0:
        continue
      let text = formatRenderText(expression, beforeValue, afterValue)
      if text.len == 0:
        continue
      let key = cstring(&"{step.position}:{expression}")
      valuesByKey[key] = FlowRenderValue(
        line: step.position,
        column: column,
        loopId: step.loop,
        iteration: step.iteration,
        rrTicks: step.rrTicks,
        text: text
      )

  for _, value in valuesByKey:
    result.add(value)

  result.sort(proc(a, b: FlowRenderValue): int =
    if a.line != b.line:
      return a.line - b.line
    if a.column != b.column:
      return a.column - b.column
    cmp(a.text, b.text)
  )

proc computeActiveFlowLineValues*(
  update: FlowUpdate,
  sourceLines: seq[cstring],
  maxValuesPerLine: int = FLOW_DECORATION_MAX_VALUES_PER_LINE
): seq[FlowLineRenderValue] {.exportc.} =
  let renderValues = computeActiveRenderValues(update, sourceLines)
  result = computeFlowLineValuesFromRenderValues(renderValues, maxValuesPerLine)

proc computeFlowLoopSliders*(update: FlowUpdate): seq[FlowLoopSliderData] {.exportc.} =
  if update.isNil:
    return @[]
  let viewUpdate = resolveFlowViewUpdate(update)
  if viewUpdate.isNil:
    return @[]

  let currentLine = update.location.line
  let currentRRTicks = update.location.rrTicks
  for loopId, loop in viewUpdate.loops:
    if loop.iteration <= 0:
      continue
    let rrTicksForIterations = loop.rrTicksForIterations
    let activeIteration = activeLoopIterationForTicks(rrTicksForIterations, currentRRTicks)
    result.add(FlowLoopSliderData(
      line: loop.first,
      loopId: loopId,
      firstLine: loop.first,
      lastLine: loop.last,
      baseLoopId: loop.base,
      baseIteration: loop.baseIteration,
      iterationCount: loop.iteration,
      minIteration: 0,
      maxIteration: loop.iteration,
      activeIteration: activeIteration,
      locationInside: currentLine >= loop.first and currentLine <= loop.last,
      rrTicksForIterations: rrTicksForIterations
    ))

  result.sort(proc(a, b: FlowLoopSliderData): int =
    if a.locationInside != b.locationInside:
      return (if a.locationInside: -1 else: 1)
    if a.firstLine != b.firstLine:
      return a.firstLine - b.firstLine
    a.loopId - b.loopId
  )

proc computeFlowInsetData*(
  update: FlowUpdate,
  sourceLines: seq[cstring],
  maxValuesPerLine: int = FLOW_DECORATION_MAX_VALUES_PER_LINE
): FlowInsetData {.exportc.} =
  result = FlowInsetData(
    lineValues: computeActiveFlowLineValues(update, sourceLines, maxValuesPerLine),
    loopSliders: computeFlowLoopSliders(update)
  )

proc computeRenderValueGroups*(update: FlowUpdate, sourceLines: seq[cstring]): seq[FlowRenderValue] {.exportc.} =
  ## Build render values from ViewSource steps only (exprOrder + before/after values).
  let viewUpdate = resolveFlowViewUpdate(update)
  if viewUpdate.isNil:
    return @[]

  var valuesByKey = JsAssoc[cstring, FlowRenderValue]{}
  for step in viewUpdate.steps:
    let expressions = getStepExpressions(step)

    for expression in expressions:
      let (beforeValue, afterValue) = getStepValuePair(step, expression)
      if beforeValue.isNil and afterValue.isNil:
        continue
      let text = formatRenderText(expression, beforeValue, afterValue)
      if text.len == 0:
        continue
      let lineIndex = step.position - 1
      if lineIndex < 0 or lineIndex >= sourceLines.len:
        continue
      let column = findExpressionColumn(sourceLines[lineIndex], expression)
      if column < 0:
        continue
      let renderValue = FlowRenderValue(
        line: step.position,
        column: column,
        loopId: 0,
        iteration: step.iteration,
        rrTicks: step.rrTicks,
        text: text
      )
      let key = cstring(&"{step.position}:{expression}")
      valuesByKey[key] = renderValue

  var values: seq[FlowRenderValue] = @[]
  for _, value in valuesByKey:
    values.add(value)

  values.sort(proc(a, b: FlowRenderValue): int =
    if a.line != b.line:
      return a.line - b.line
    if a.column != b.column:
      return a.column - b.column
    return cmp(a.text, b.text)
  )

  result = values
