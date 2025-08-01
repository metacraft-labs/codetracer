import std / jsconsole
import service_imports

proc restart*(self: DebuggerService) =
  self.locals = @[]
  self.watchExpressions = @[]

proc loadLocals*(self: DebuggerService, rrTicks: int, countBudget: int, minCountLimit: int): Future[seq[Variable]] {.async.} =
  self.locals = await self.data.asyncSend(
    "load-locals",
    LoadLocalsArg(
      rrTicks: rrTicks,
      countBudget: countBudget,
      minCountLimit: minCountLimit),
    $rrTicks,
    seq[Variable])
  return self.locals

proc evaluateExpression*(self: DebuggerService, rrTicks: int, expression: cstring): Future[Value] {.async.} =
  let value = await self.data.asyncSend("evaluate-expression", EvaluateExpressionArg(rrTicks: rrTicks, expression: expression), &"{rrTicks}:{expression}", Value)
  return value

proc loadParsedExprs*(self: DebuggerService, line: int, path: cstring) {.async.} =
  var table = await self.data.asyncSend("load-parsed-exprs", LoadParsedExprsArg(line: line, path: path), &"{path}:{line}", JsAssoc[cstring, seq[FlowExpression]])
  if self.expressionMap.isNil:
    self.expressionMap = JsAssoc[cstring, seq[FlowExpression]]{}
    self.expressionMap = table
  else:
    for key, item in table:
      self.expressionMap[key] = item

proc calltraceSearch*(self: DebuggerService, response: CallSearchArg): Future[seq[Call]] {.async.} =
  let calls = await self.data.asyncSend("calltrace-search", response, &"{response}", seq[Call])
  return calls

proc updateTable*(self: DebuggerService, args: UpdateTableArgs) {.async.} =
  # self.data.ipc.send "CODETRACER::update-table", args
  # var data: seq[TestMe] = @[]
  # for col in args.columns:
  #   data.add(TestMe())
  # return UpdateReturn(draw: args.draw, recordsTotal: 5000, recordsFiltered: 5000, data: @[TestMe(directLocationRRTicks: "661".cstring, rrEventId: "0".cstring, kind: EventLogKind.TraceLogEvent, content: "THIS IS THE CONTENT".cstring)])
  discard await self.data.asyncSend(
    "update-table",
    args,
    "draw" & fmt"-{args.tableArgs.draw}",
    Future[void])

proc tracepointDelete*(self: DebuggerService, tracepointId: TracepointId) {.async.} =
  discard await self.data.asyncSend(
    "tracepoint-delete",
    tracepointId,
    "tracepoint-delete-" & fmt"{tracepointId}",
    Future[void])

proc tracepointToggle*(self: DebuggerService, tracepointId: TracepointId) {.async.} =
  discard await self.data.asyncSend(
    "tracepoint-toggle",
    tracepointId,
    "tracpeoint-toggle-" & fmt"{now()}-{tracepointId}",
    Future[void]
  )

proc debugRepl*(self: DebuggerService, cmd: cstring) {.exportc.} =
  if not self.stableBusy:
    self.stableBusy = true
    inc self.operationCount
    self.data.ipc.send "CODETRACER::debug-gdb", js{process: j"stable", cmd: cmd}

proc internalDeleteBreakpoint*(self: DebuggerService, path: cstring, line: int) =
  self.data.ipc.send "CODETRACER::delete-break", js{
    line: line,
    path: path,
  }

proc internalDeleteBreakpointC*(self: DebuggerService, path: cstring, line: int) =
  self.data.ipc.send "CODETRACER::delete-break-c", js{
    line: line,
    path: path
  }

proc internalAddBreakpoint*(self: DebuggerService, path: cstring, line: int) =
  self.data.ipc.send "CODETRACER::add-break", js{
    line: line,
    path: path
  }

proc internalAddBreakpointC*(self: DebuggerService, path: cstring, line: int) =
  self.data.ipc.send "CODETRACER::add-break-c", js{
    line: line,
    path: path
  }

proc step*(
    self: DebuggerService,
    action: string,
    actionEnum: DebuggerAction,
    reverse: bool = false,
    repeat: int = 1,
    complete: bool = true,
    editorView: EditorView = ViewSource,
    taskId: TaskId = NO_TASK_ID) =

  if not self.stableBusy:
    if self.finished and action != j"continue":
      echo &"program is finished: please add a breakpoint and continue or jump"
      return

    self.stableBusy = true
    inc self.operationCount

    let lang = self.data.trace.lang
    # cdebug "debugger: step: editorView " & $editorView
    let (realAction, realActionEnum) =
      if editorView == ViewInstructions and action in @["next", "step", "step-in"]:
        case action:
        of "next": ("nexti", NextI)
        of "step", "step-in": ("stepi", StepI)
        else: ("stepi", StepI)
      elif lang == LangNim and editorView == ViewTargetSource and action in @["next", "step", "step-in"]:
        case action:
        of "next": ("nextc", NextC)
        of "step", "step-in": ("stepc", StepC)
        else: ("stepc", StepC)
      else:
        (action, actionEnum)

    self.currentOperation = action
    echo "operation ", self.currentOperation

    if not reverse:
      self.lastDirection = DebForward

      self.lastAction = j(realAction)
    else:
      self.lastDirection = DebReverse

      self.lastAction = j(&"reverse-{realAction}")

    cdebug "debugger: send to core step: " & $realActionEnum &
      " reverse: " & $reverse & " repeat: " & $repeat &
      " complete: " & $complete
    # StepArg + taskId
    # TODO: move this to a more general handler
    # that e.g. does both (or optionally both)
    #   a normal dap step operation
    #   and a custom ct ct/step operation
    #   and maybe base it on a custom mediator
    #   so it can be easily called from various components
    #   without depending on a service/shared context
    self.data.ipc.send(
      &"CODETRACER::step", js{
        action: realActionEnum,
        reverse: reverse,
        repeat: repeat,
        complete: complete,
        taskId: taskId,
        skipInternal: self.skipInternal, # TODO: Fix to a toggle switch
        skipNoSource: self.skipNoSource # TODO: Fix to a toggle switch
      }
    )
    self.data.redraw()
  else:
    self.stableBuffer.add((action, reverse))

proc jumpToLocalStep*(self: DebuggerService, path: cstring, line: int, stepCount: int, iteration: int, rrTicks: int = -1, reverse: bool = false) =
  # (line, rr ticks) => all steps that correspond to those rr ticks and line
  # if two steps same lines rr ticks it means jump without changing rr ticks..
  # hard to believe
  let firstLoopLine = if path.len > 0 and self.data.ui.editors.hasKey(path) and not self.data.ui.editors[path].flow.isNil:
      let flow = self.data.ui.editors[path].flow.flow
      let loopId = flow.steps[stepCount].loop
      flow.loops[loopId].first
    else:
      # e.g. step list jump for now
      -1

  self.data.ipc.send "CODETRACER::local-step-jump", LocalStepJump(
    path: path,
    line: line,
    stepCount: stepCount,
    iteration: iteration,
    firstLoopLine: firstLoopLine,
    rrTicks: rrTicks,
    reverse: reverse
  )


func hasBreakpoint*(self: DebuggerService, path: cstring, line: int): bool =
  self.breakpointTable.hasKey(path) and self.breakpointTable[path].hasKey(line)


proc addBreakpoint*(self: DebuggerService, path: cstring, line: int, c: bool = false) =
  if not self.hasBreakpoint(path, line):
    if not self.breakpointTable.hasKey(path):
      self.breakpointTable[path] = JsAssoc[int, UIBreakpoint]{}
    self.breakpointTable[path][line] = UIBreakpoint(line: line, path: path, level: if not c: 0 else: 1, enabled: true)
    data.pointList.breakpoints.add(self.breakpointTable[path][line])

    if not c:
      self.internalAddBreakpoint(path, line)
    else:
      if self.data.trace.lang == LangNim:
        self.internalAddBreakpointC(path, line)

    # TODO self.data.services.editor.open[self.data.services.editor.active].viewLine = line

    self.data.redraw()


proc deleteBreakpoint*(self: DebuggerService, path: cstring, line: int, c: bool = false) =
  if self.hasBreakpoint(path, line):
    # TODO move point list
    for i, b in data.pointList.breakpoints:
      if b == self.breakpointTable[path][line]:
        delete(data.pointList.breakpoints, i..i)
        data.pointList.redrawBreakpoints = true
      break
    self.breakpointTable[path].del(line)

    if not c:
      self.internalDeleteBreakpoint(path, line)

    else:
      if self.data.trace.lang == LangNim:
        self.internalDeleteBreakpointC(path, line)

    self.data.redraw()


proc toggleBreakpoint*(self: DebuggerService, path: cstring, line: int, c: bool = false) =
  if not self.hasBreakpoint(path, line):
    self.addBreakpoint(path, line, c)
  else:
    self.deleteBreakpoint(path, line, c)


proc isEnabled*(self: DebuggerService, path: cstring, line: int): bool =
  if self.breakpointTable.hasKey(path) and self.breakpointTable[path].hasKey(line):
    return self.breakpointTable[path][line].enabled
  else:
    return false

proc enable*(self: DebuggerService, path: cstring, line: int) =
  if self.breakpointTable.hasKey(path) and self.breakpointTable[path].hasKey(line):
    # TODO move point list
    #for i, b in data.pointList.breakpoints:
    #  if b == self.breakpointTable[path][line]:
        # TODO set disabled?
        # data.pointList.breakpoints.delete(i, i)
        # data.pointList.redrawBreakpoints = true
    #    break

    # TODO better way
    var breakpoint = self.breakpointTable[path][line]
    breakpoint.enabled = true
    self.breakpointTable[path][line] = breakpoint

    self.data.ipc.send "CODETRACER::enable", js{path: path, line: line}

proc disable*(self: DebuggerService, path: cstring, line: int) =
  if self.breakpointTable.hasKey(path) and self.breakpointTable[path].hasKey(line):
    # TODO move point list
    #for i, b in data.pointList.breakpoints:
    #  if b == self.breakpointTable[path][line]:
        # TODO set disabled?
        # data.pointList.breakpoints.delete(i, i)
        # data.pointList.redrawBreakpoints = true
    #    break

    # TODO better way
    var breakpoint = self.breakpointTable[path][line]
    breakpoint.enabled = false
    self.breakpointTable[path][line] = breakpoint
    self.data.ipc.send "CODETRACER::disable", js{path: path, line: line}

proc toggleAssemblyBreakpoint*(self: DebuggerService, address: cstring) =
  discard

proc onAddBreakResponse*(self: DebuggerService, response: BreakpointInfo, c: bool) =
  if self.breakpointTable.hasKey(response.path):
    if self.breakpointTable[response.path].hasKey(response.line):
      if response.id != NO_INDEX:
        var b = self.breakpointTable[response.path][response.line]
        b.id = response.id
      else:
        var b = self.breakpointTable[response.path][response.line]
        b.id = NO_INDEX
        b.error = true
      # error: ignore? we should already have this editor component
      refreshEditorLine(self.data.ui.editors[response.path], response.line)

proc deleteAllBreakpoints*(self: DebuggerService, editor: EditorViewComponent) =
  let breakpointsCopy = data.pointList.breakpoints
  for i, b in breakpointsCopy:
    delete(data.pointList.breakpoints, i..i)
    data.services.debugger.breakpointTable[b.path].del(b.line)
    editor.refreshEditorLine(b.line)
  data.pointList.redrawBreakpoints = true
  self.data.ipc.send "CODETRACER::delete-all-breakpoints", js{}

proc sourceLineJump*(self: DebuggerService, path: cstring, line: int, behaviour: JumpBehaviour) =
  self.data.ipc.send "CODETRACER::source-line-jump", SourceLineJumpTarget(
    path: path,
    line: line,
    behaviour: behaviour
  )
  self.currentOperation = "source jump"

proc sourceCallJump*(self: DebuggerService, path: cstring, line: int, targetToken: cstring, behaviour: JumpBehaviour) =
  self.data.ipc.send "CODETRACER::source-call-jump", SourceCallJumpTarget(
    path: path,
    line: line,
    token: targetToken,
    behaviour: behaviour
  )

proc runTo*(self: DebuggerService, path: cstring, line: int, reverse: bool = false) =
  self.data.ipc.send "CODETRACER::run-to", js{path: path, line: line, reverse: reverse}

proc runToEntry*(self: DebuggerService) =
  self.data.ipc.send "CODETRACER::run-to-entry", js{}
  self.currentOperation = "run to entry"

proc resetOperation*(self: DebuggerService, full: bool, resetLastLocation: bool = false, taskId: TaskId) =
  # TODO?
  # think about multiprocess
  self.stableBusy = true
  inc self.operationCount
  self.currentOperation = if not full: "canceling: interrupt" else: "canceling: replacing with new process"
  cdebug fmt"sending reset-operation to index full {full}", taskId
  self.data.ipc.send "CODETRACER::reset-operation", js{full: full, taskId: taskId, resetLastLocation: resetLastLocation}

proc lineStepJump*(self: DebuggerService, lineStep: LineStep) =
  if not self.data.trace.lang.isDbBased:
    self.step(
      "step-in",
      StepIn,
      reverse = lineStep.delta < 0,
      repeat = lineStep.delta,
      complete = true,
      taskId = genTaskId(Step))
  else:
    # a bit hacky, using only for db-backend, where it just jumps to `step_id` == <the location rr ticks>
    # so the other args shouldn't concern us for here
    self.jumpToLocalStep(cstring"", -1, -1, -1, rrTicks=lineStep.location.rrTicks)


data.services.debugger.onDebuggerStarted = proc(self: DebuggerService, response: int) {.async.} =
  # echo "started"
  self.hasStarted = true
  self.data.redraw()
  self.runToEntry()


data.services.debugger.onCompleteMove = proc(self: DebuggerService, response: MoveState) {.async.} =
  self.location = response.location
  self.cLocation = response.cLocation
  self.frameInfo = response.frameInfo
  self.stopSignal = response.stopSignal
  # self.lowLevel = 0 # TODO
  self.finished = false
  self.stableBusy = false
  cdebug fmt"ui test runner isNil?: debugger service: {self.data.testRunner.isNil}"
  if not self.data.testRunner.isNil:
    cdebug fmt"onCompleteMoveResolve isNil?: {self.data.testRunner.onCompleteMoveResolve.isNil}"
    if not self.data.testRunner.isNil and not self.data.testRunner.onCompleteMoveResolve.isNil:
      self.data.testRunner.onCompleteMoveResolve()
  self.data.redraw()


# HACK: `response` argument probably doesnt exist, i think the dsl needs one in the signature
data.services.debugger.onFinished = proc(self: DebuggerService, response: JsObject) {.async.} =
  self.location = Location(path: cstring"")

  self.finished = true
  self.stableBusy = false

  self.data.redraw()

data.services.debugger.onError = proc(self: DebuggerService, response: DebuggerError) {.async.} =
  self.error = response

  # TODO errorUI $response.msg

  # finished: again?
  # finished error

data.services.debugger.onDebugOutput = proc(self: DebuggerService, response: DebugOutput) {.async.} =
  self.stableBusy = false

data.services.debugger.onAddBreakResponse = proc(self: DebuggerService, response: BreakpointInfo) {.async.} =
  onAddBreakResponse(self, response, c=false)

data.services.debugger.onAddBreakCResponse = proc(self: DebuggerService, response: BreakpointInfo) {.async.} =
  onAddBreakResponse(self, response, c=true)
