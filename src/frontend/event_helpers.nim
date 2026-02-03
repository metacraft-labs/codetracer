import
  std / [ jsffi, strformat, algorithm ],
  .. / common / ct_event,
  types,
  communication, dap,
  lib/[ jslib ]

const HISTORY_JUMP_VALUE*: string = "history-jump"

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

proc findExpressionColumn(sourceLine: cstring, expression: cstring): int =
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

proc computeRenderValueGroups*(update: FlowUpdate, sourceLines: seq[cstring]): seq[FlowRenderValue] {.exportc.} =
  ## Build render values from ViewSource steps only (exprOrder + before/after values).
  if update.isNil:
    return @[]
  var viewUpdate = update.viewUpdates[ViewSource]
  if viewUpdate.isNil:
    for candidate in update.viewUpdates:
      if not candidate.isNil:
        viewUpdate = candidate
        break
  if viewUpdate.isNil:
    return @[]

  var valuesByKey = JsAssoc[cstring, FlowRenderValue]{}
  for step in viewUpdate.steps:
    var expressions = step.exprOrder
    if expressions.len == 0:
      for key, _ in step.beforeValues:
        expressions.add(key)
      for key, _ in step.afterValues:
        if not expressions.contains(key):
          expressions.add(key)

    for expression in expressions:
      let beforeValue = if step.beforeValues.hasKey(expression): step.beforeValues[expression] else: nil
      let afterValue = if step.afterValues.hasKey(expression): step.afterValues[expression] else: nil
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
