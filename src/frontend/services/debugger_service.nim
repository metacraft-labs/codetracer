import
  std / [jsconsole, os],
  ../dap,
  ../lib/[ logging, jslib ],
  ../../common/ct_event,
  service_imports

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
    self.data.ipc.send "CODETRACER::debug-gdb", js{process: cstring"stable", cmd: cmd}

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
  # self.data.dapApi.sendCtRequest(DapSetBreakpoints, ) "CODETRACER::add-break", js{
  #   line: line,
  #   path: path
  # }
  discard

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
    if self.finished and action != cstring"continue":
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

      self.lastAction = cstring(realAction)
    else:
      self.lastDirection = DebReverse

      self.lastAction = cstring(&"reverse-{realAction}")

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

proc stepOverStatement*(self: DebuggerService) =
  ## M2 — Column-Aware Replay Navigation §M2: step forward by one
  ## /statement/ rather than by one source line.  Sends a DAP ``next``
  ## request to the replay-server with ``granularity: "statement"`` on
  ## the wire — the replay-server's ``next_dap`` handler dispatches
  ## to the column-aware [`run_step_over_statement`] runner when the
  ## granularity field is present, and falls back to legacy
  ## line-granularity stepping otherwise.
  ##
  ## Unlike [`DebuggerService.step`] (which is the entry point for the
  ## F10 button + Mousetrap keybind path and routes through
  ## ``CODETRACER::step`` for IPC compatibility with the legacy CT
  ## protocol), this proc speaks DAP directly — the granularity field
  ## is a vanilla DAP extension and does not need a custom CT
  ## protocol bridge.
  ##
  ## See ``codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org``
  ## §M2 for the DAP wire contract.
  if self.stableBusy:
    return
  self.stableBusy = true
  inc self.operationCount
  self.lastDirection = DebForward
  self.lastAction = cstring"next"
  # The DAP arguments carry the standard `threadId` (we currently use
  # the single-thread sentinel `1`) plus the M2 extension field
  # `granularity = "statement"` that activates the column-aware
  # runner on the replay-server.  `DapStepArguments` does not surface
  # the granularity slot on its Nim type — we ship a raw `js{}` literal
  # to avoid widening every step request site with an unused field.
  let args = js{
    threadId: 1,
    granularity: cstring"statement",
  }
  self.data.dapApi.sendCtRequest(DapNext, args)
  self.data.redraw()


proc stepBackStatement*(self: DebuggerService) =
  ## M7 — Column-Aware Replay Navigation §M7: time-travel symmetric
  ## counterpart of [`stepOverStatement`].  Step BACKWARD by one
  ## /statement/ rather than by one source line.  Sends a DAP
  ## ``stepBack`` request to the replay-server with
  ## ``granularity: "statement"`` on the wire — the replay-server's
  ## ``step_back_dap`` handler dispatches to the column-aware reverse
  ## runner when the granularity field is present, and falls back to
  ## the legacy reverse-line-granularity runner otherwise.
  ##
  ## Like [`stepOverStatement`], this proc speaks DAP directly because
  ## the granularity field is a vanilla DAP extension on
  ## ``StepBackArguments`` (DAP spec §StepBackArguments) and does not
  ## need a custom CT protocol bridge.  The legacy reverse-step UX
  ## (the F9 / reverse-debug-controls button surface that ships
  ## ``CODETRACER::step({reverse:true})``) keeps its current behaviour
  ## untouched — M7 is purely additive.
  ##
  ## See ``codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org``
  ## §M7 for the DAP wire contract.
  if self.stableBusy:
    return
  self.stableBusy = true
  inc self.operationCount
  self.lastDirection = DebReverse
  self.lastAction = cstring"reverse-next"
  # DAP arguments mirror the forward `stepOverStatement` payload but
  # ship through the `stepBack` command.  Same single-thread sentinel
  # (`threadId: 1`) and same `granularity: "statement"` opt-in field.
  let args = js{
    threadId: 1,
    granularity: cstring"statement",
  }
  self.data.dapApi.sendCtRequest(DapStepBack, args)
  self.data.redraw()


proc setActiveSourceView*(self: DebuggerService, viewPath: cstring) =
  ## M3 — Column-Aware Replay Navigation §M3.  Activate the formatted
  ## srcview at ``viewPath`` so subsequent step-overs advance one
  ## /formatted/ line (or statement) per press rather than one
  ## minified line.  Pass an empty string / ``nil`` to clear the active
  ## view and return the runner to legacy minified-coordinate
  ## behaviour.
  ##
  ## The replay-server's ``ct/set-active-source-view`` handler stores
  ## the path on the per-trace ``Handler`` instance; subsequent ``next``
  ## requests consult it to decide whether to invoke the formatted-view
  ## runner or the legacy line-granularity runner.
  let args = if viewPath.isNil or viewPath.len == 0:
    js{ viewPath: nil }
  else:
    js{ viewPath: viewPath }
  self.data.dapApi.sendCtRequest(CtSetActiveSourceView, args)

proc installSourceViewForTest*(self: DebuggerService;
                               recordedPath, formattedViewPath,
                               sourcemapV3Json: cstring) =
  ## M3 — test-only debug surface: inject a synthetic Source Map V3
  ## record into the replay-server's sourcemap cache.
  ##
  ## Production code path: the recorder writes a ``srcviews.dat``
  ## record that the replay-server discovers at trace-open time via
  ## ``load_source_views``.  This procedure exposes the install hook
  ## directly so headless ViewModel and GUI Playwright tests can
  ## exercise the formatted-view runner without depending on the JS
  ## recorder's autoformat step (which requires ``prettier`` on PATH
  ## and would tie the M3 contract to an external toolchain).
  ##
  ## The injected index is stored under the same in-memory
  ## ``sourcemap_cache`` slot the production ``load_source_views``
  ## path writes to, so both paths exercise the same downstream
  ## runner code.
  let args = js{
    recordedPath: recordedPath,
    formattedViewPath: formattedViewPath,
    sourcemapV3Json: sourcemapV3Json,
  }
  self.data.dapApi.sendCtRequest(CtInstallSourceView, args)


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
    targetIteration: iteration,
    firstLoopLine: firstLoopLine,
    rrTicks: rrTicks,
    reverse: reverse,
    activeIteration: 0
  )


func hasBreakpoint*(self: DebuggerService, path: cstring, line: int): bool =
  self.breakpointTable.hasKey(path) and self.breakpointTable[path].hasKey(line)

const NO_B_COLUMN = 0

proc dapSetBreakpoints*(self: DebuggerService) =
  ## M1 — when a registered breakpoint carries a non-zero column the
  ## DAP request surfaces it; legacy breakpoints (``column == 0``)
  ## fall back to the original line-only payload so older replay
  ## servers (and the existing CI smoke fixtures) keep working.
  ##
  ## M9 — when a registered breakpoint carries a non-empty condition
  ## expression, the DAP request ships it alongside the line/column.
  ## The replay engine evaluates the condition at the candidate stop
  ## step (see `db.condition_satisfied_at`).  Empty-string conditions
  ## are normalised on the replay side to preserve the back-compat
  ## semantic ("no condition").
  ##
  ## M10 — when a registered entry carries a non-empty ``logMessage``
  ## the replay engine treats it as a DAP *tracepoint* (logpoint):
  ## execution passing through the matched ``(line, column)`` emits a
  ## DAP ``output`` event carrying the message and CONTINUES without
  ## stopping.  Empty ``logMessage`` preserves the breakpoint
  ## behaviour M1/M9 shipped with.
  for path, breakpointList in self.breakpointTable:
    var args = DapSetBreakpointsArguments(
      source: DapSource(
        name: extractFilename($path),
        path: path,
        sourceReference: nil
      )
    )
    for line, b in breakpointList:
      if b.enabled:
        args.breakpoints.add(
          DapSourceBreakpoint(
            line: line,
            column: b.column,
            condition: b.condition,
            logMessage: b.logMessage
          )
        )
        args.lines.add(line)
    self.data.dapApi.sendCtRequest(
      DapSetBreakpoints,
      args.toJs
    )

proc addBreakpoint*(self: DebuggerService, path: cstring, line: int, c: bool = false) =
  if not self.hasBreakpoint(path, line):
    if not self.breakpointTable.hasKey(path):
      self.breakpointTable[path] = JsAssoc[int, UIBreakpoint]{}
    self.breakpointTable[path][line] = UIBreakpoint(
      line: line,
      column: NO_B_COLUMN,
      condition: cstring"",
      path: path,
      level: if not c: 0 else: 1,
      enabled: true)
    data.pointList.breakpoints.add(self.breakpointTable[path][line])

    # if not c:
    #   self.internalAddBreakpoint(path, line)
    # else:
    #   if self.data.trace.lang == LangNim:
    #     self.internalAddBreakpointC(path, line)

    # TODO self.data.services.editor.open[self.data.services.editor.active].viewLine = line
  self.dapSetBreakpoints()
  self.data.redraw()


proc addColumnTracepoint*(self: DebuggerService, path: cstring, line: int, column: int,
                          logMessage: cstring) =
  ## M10 — Column-Aware Tracepoint / Logpoint: register a DAP
  ## *logpoint* anchored at ``(path, line, column)`` carrying
  ## ``logMessage``.  When execution passes through the matched step
  ## the replay engine emits a DAP ``output`` event carrying the
  ## message and CONTINUES without stopping — the defining
  ## difference between a tracepoint (logpoint) and a breakpoint.
  ##
  ## Stored in the same ``breakpointTable[path][line]`` slot as a
  ## column-aware breakpoint; the ``logMessage`` field distinguishes
  ## the two surfaces.  Mirrors ``addColumnBreakpoint`` (M1) for the
  ## tracepoint half of the column-aware navigation surface, the
  ## final piece of the Column-Aware Replay Navigation campaign.
  ##
  ## See ``codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org``
  ## §M10 for the contract.
  if not self.breakpointTable.hasKey(path):
    self.breakpointTable[path] = JsAssoc[int, UIBreakpoint]{}
  self.breakpointTable[path][line] = UIBreakpoint(
    line: line,
    column: column,
    condition: cstring"",
    logMessage: logMessage,
    path: path,
    level: 0,
    enabled: true)
  data.pointList.breakpoints.add(self.breakpointTable[path][line])
  self.dapSetBreakpoints()
  self.data.redraw()


proc addColumnBreakpoint*(self: DebuggerService, path: cstring, line: int, column: int,
                          condition: cstring = cstring"") =
  ## M1 — Column-Aware Replay Navigation: register a breakpoint
  ## anchored at ``(path, line, column)``.  Stored in the same
  ## ``breakpointTable[path][line]`` slot as a line-only breakpoint
  ## (one column-anchored breakpoint per line in the UI for now);
  ## the recorded column is round-tripped through DAP so the
  ## replay-server matches the exact recorded ``DbStep.column`` at
  ## continue-time.
  ##
  ## Used by tests (and a future GUI affordance) to set
  ## column-precision breakpoints; the existing
  ## ``addBreakpoint``/``toggleBreakpoint`` path remains line-only
  ## so the gutter-click default behaviour is unchanged.
  ##
  ## M9 — Column-Aware Conditional Breakpoint: the optional
  ## ``condition`` parameter is forwarded to the replay engine on
  ## the DAP ``setBreakpoints`` request.  When non-empty the engine
  ## evaluates it against the locals recorded at the matched step
  ## and only fires the breakpoint when the expression holds.
  ## Composes orthogonally with ``column`` — both filters apply.
  ## ``condition = ""`` preserves the M1 unconditional behaviour.
  if not self.breakpointTable.hasKey(path):
    self.breakpointTable[path] = JsAssoc[int, UIBreakpoint]{}
  self.breakpointTable[path][line] = UIBreakpoint(
    line: line,
    column: column,
    condition: condition,
    path: path,
    level: 0,
    enabled: true)
  data.pointList.breakpoints.add(self.breakpointTable[path][line])
  self.dapSetBreakpoints()
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

    # if not c:
    #   self.internalDeleteBreakpoint(path, line)

    # else:
    #   if self.data.trace.lang == LangNim:
    #     self.internalDeleteBreakpointC(path, line)

  self.dapSetBreakpoints()
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

    self.dapSetBreakpoints()

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
    self.dapSetBreakpoints()

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
  self.dapSetBreakpoints()

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
  if not self.data.trace.lang.usesMaterializedTraces:
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
