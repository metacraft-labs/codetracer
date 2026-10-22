import
  std / [jsconsole, os, options],
  ../dap,
  ../lib/[ logging, jslib ],
  ../../common/ct_event,
  service_imports

from ../viewmodel/store/replay_data_store import ReplayDataStore
import ../viewmodel/sdk/breakpoints

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

# NOT `{.exportc.}`.  `exportc` fixes the emitted JS name, and
# `renderer.nim` already exports a devtools-console helper called
# `debugRepl`.  Two `exportc` procs with one name land as two top-level
# `function debugRepl` declarations in `ui.js`, where the LAST one wins —
# so this method was silently replaced by the renderer's one-argument
# version, which would have taken `self` as its `expression` and dropped
# `cmd`.  A method taking a `DebuggerService` was never callable from a
# console anyway, so the fixed name bought nothing.
# `ci/test/js-bundle-name-uniqueness.sh` now fails on the collision.
proc debugRepl*(self: DebuggerService, cmd: cstring) =
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
  ## F10 button + key-router path and routes through
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


# ---------------------------------------------------------------------------
# Breakpoints — the session store's, through the shared producer
# ---------------------------------------------------------------------------
#
# THE STORE HOLDS THE ONLY BREAKPOINT STATE (Shared-DOM-Front-Ends D7.4). This
# service kept its own `breakpointTable` and sent it with `dapSetBreakpoints`,
# and the store learned only the lines the engine verified — so a disabled
# breakpoint, a column and a condition existed on this side and nowhere a
# ViewModel could read them, and the editor drew its gutter from the table
# while every other front-end drew from the store. Each operation below is now
# a plan over the store's rows (`sdk/breakpoints`, the planners the terminal and
# GPUI use) sent through the session's backend, and the rows are replaced by
# what the engine answered. The procs keep their names for their callers (the
# program menu, the editor's menus, the renderer's `onAddBreakpoint`).

proc store(self: DebuggerService): ReplayDataStore =
  ## The session store this service's breakpoints live in, or nil before the
  ## renderer has built the session (`ui_js` sets `pointStore`).
  if self.isNil or self.pointStore.isNil: nil
  else: cast[ReplayDataStore](self.pointStore)

proc breakpointOf*(self: DebuggerService, path: cstring,
                   line: int): Option[BreakpointSpec] =
  ## The breakpoint on `path:line`, armed or not.
  let st = self.store
  if st.isNil: none(BreakpointSpec)
  else: breakpointAt(st, $path, line)

proc hasBreakpoint*(self: DebuggerService, path: cstring, line: int): bool =
  self.breakpointOf(path, line).isSome

proc breakpointsIn*(self: DebuggerService, path: cstring): seq[BreakpointSpec] =
  ## `path`'s breakpoints, armed and disabled.
  let st = self.store
  if not st.isNil:
    result = heldBreakpoints(st, $path)

proc dapSetBreakpoints*(self: DebuggerService) =
  ## Send every file's breakpoints again — the engine restarted and holds none
  ## of them (`middleware`'s subsystem restart).
  let st = self.store
  if not st.isNil:
    resendBreakpoints(st)

proc addBreakpoint*(self: DebuggerService, path: cstring, line: int, c: bool = false) =
  ## A whole-line breakpoint on `path:line`, unless the line has one.
  let st = self.store
  if st.isNil or self.hasBreakpoint(path, line):
    return
  toggleBreakpoint(st, $path, line)

proc addColumnTracepoint*(self: DebuggerService, path: cstring, line: int, column: int,
                          logMessage: cstring) =
  ## M10 — Column-Aware Tracepoint / Logpoint: a DAP *logpoint* anchored at
  ## `(path, line, column)` carrying `logMessage`. When execution passes
  ## through the matched step the replay engine emits a DAP `output` event
  ## carrying the message and CONTINUES without stopping. It replaces the
  ## line's breakpoint, as a column breakpoint does. See
  ## `codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org`
  ## §M10.
  let st = self.store
  if not st.isNil:
    setAnchoredBreakpoint(st, $path, line, column, logMessage = $logMessage)

proc addColumnBreakpoint*(self: DebuggerService, path: cstring, line: int, column: int,
                          condition: cstring = cstring"") =
  ## M1 — Column-Aware Replay Navigation: a breakpoint anchored at
  ## `(path, line, column)`, replacing the line's breakpoint; the replay
  ## server matches the exact recorded `DbStep.column` at continue-time. M9:
  ## a non-empty `condition` is evaluated by the engine at the candidate stop
  ## step, and the breakpoint fires only when it holds.
  let st = self.store
  if not st.isNil:
    setAnchoredBreakpoint(st, $path, line, column, condition = $condition)

proc deleteBreakpoint*(self: DebuggerService, path: cstring, line: int, c: bool = false) =
  let st = self.store
  if not st.isNil:
    discard deleteBreakpoint(st, $path, line)

proc toggleBreakpoint*(self: DebuggerService, path: cstring, line: int, c: bool = false) =
  let st = self.store
  if not st.isNil:
    toggleBreakpoint(st, $path, line)

proc isEnabled*(self: DebuggerService, path: cstring, line: int): bool =
  let b = self.breakpointOf(path, line)
  b.isSome and b.get.enabled

proc enable*(self: DebuggerService, path: cstring, line: int) =
  ## Arm the breakpoint on `path:line`; nothing when the line has none.
  let st = self.store
  if not st.isNil:
    discard setBreakpointEnabled(st, $path, line, true)

proc disable*(self: DebuggerService, path: cstring, line: int) =
  ## Disarm the breakpoint on `path:line`: it stays on the point list and in
  ## the gutter, dimmed, and is not sent to the engine.
  let st = self.store
  if not st.isNil:
    discard setBreakpointEnabled(st, $path, line, false)

proc setAllEnabled*(self: DebuggerService, path: cstring, enabled: bool) =
  ## Arm or disarm every breakpoint of `path` ("" for every file).
  let st = self.store
  if not st.isNil:
    setAllBreakpointsEnabled(st, enabled, $path)

proc deleteAllBreakpoints*(self: DebuggerService, path: cstring = cstring"") =
  ## Delete every breakpoint of `path`, or of every file when `path` is "".
  let st = self.store
  if not st.isNil:
    clearBreakpoints(st, $path)

proc newJsArray(): JsObject {.importjs: "(new Array())".}

proc breakpointRowsForTests(): JsObject {.exportc: "ctBreakpointRows".} =
  ## The active session's breakpoints as plain objects — `{path, line,
  ## column, enabled, condition, logMessage}` — for the GUI tests, which read
  ## breakpoint state from the page. The rows are the session store's
  ## (`sdk/breakpoints`); there is no other breakpoint state to read.
  result = newJsArray()
  if data.isNil or data.services.isNil or data.services.debugger.isNil:
    return
  let st = data.services.debugger.store
  if st.isNil:
    return
  for file in breakpointFiles(st):
    let path = cstring(file)
    let held = heldBreakpoints(st, file)
    for i in 0 ..< held.len:
      let line = held[i].line
      let column = held[i].column
      let enabled = held[i].enabled
      let condition = cstring(held[i].condition)
      let logMessage = cstring(held[i].logMessage)
      discard result.push(js{
        path: path, line: line, column: column, enabled: enabled,
        condition: condition, logMessage: logMessage})

proc deleteBreakpointForTests(path: cstring; line: int): bool {.exportc: "ctDeleteBreakpoint".} =
  ## Delete the active session's breakpoint on `path:line` — for the GUI
  ## tests, which cannot call the name-mangled service procs. False when the
  ## line has none.
  if data.isNil or data.services.isNil or data.services.debugger.isNil:
    return false
  let st = data.services.debugger.store
  if st.isNil:
    return false
  deleteBreakpoint(st, $path, line)

proc toggleAssemblyBreakpoint*(self: DebuggerService, address: cstring) =
  discard

proc onAddBreakResponse*(self: DebuggerService, response: BreakpointInfo, c: bool) =
  ## The legacy add-break answer: the line is redrawn; the breakpoint's state
  ## is the store's.
  if self.data.ui.editors.hasKey(response.path):
    refreshEditorLine(self.data.ui.editors[response.path], response.line)

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

# `runTo` USED TO BE HERE, and it was a closed loop: it sent
# `CODETRACER::run-to`, which no main-process handler ever listened for, and its
# only caller was `renderer.onRunTo` — the RECEIVER for that same channel, which
# called straight back into it. Nothing ever sent the message, so neither proc
# ever ran; nothing had a keybinding, menu item, palette entry or button.
#
# It is deleted rather than wired up because *Run to Cursor*, the command it was
# named for, is a BEHAVIOUR OF THE LINE JUMP and not a second command beside it
# (`codetracer-specs` `GUI/Debugging-Features/Debugger-Controls.md` § "Running to
# a line"). The forward direction of `ct/source-line-jump` is that command; see
# `sourceLineJump` above and `ui/editor.nim`'s `CTRL+F10`. Leaving a dead
# `runTo` beside it is how a reader concludes the product has two of something
# it has one of.

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
  # LRS-5 (b), one of the four sites: a jump to a step id is what a
  # MATERIALIZED container supports and repeated `step-in` is what a native
  # replay recording needs, so the question is about the recording and is
  # asked of `Trace.approach`.
  if not self.data.trace.usesMaterializedTraces:
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
