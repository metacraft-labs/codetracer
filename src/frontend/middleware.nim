import
  std/[jsffi, jsconsole],
  ../common/[ct_event, ct_logging],
  lib/jslib,
  types,
  communication, dap,
  event_helpers


# backend(dap) <-> middleware <-> view (self-contained, can be separate: 0, 1 or more components);

when not defined(ctInExtension):
  import utils
  import services / debugger_service

  proc dapInitializationHandler() =
    infoPrint "middleware: launching trace id=", $data.trace.id, " folder=", $data.trace.outputFolder

    # it's important that this is in the `dapInitializationHandler` that is
    #   in the not defined(ctInExtension) case!
    # in vscode, we assume the vscode editors handle breakpoints
    # so we do this only for our codetracer non-extension editors
    # important to send this before configurationDone: to
    #   send the existing breakpoints and sync in this way even
    # however, try to do this only after restart of subsystem
    #   as this currently is the same trace where if no source edits have been done
    #   the breakpoints should continue making sense
    #
    # TODO
    # maybe for other trace restarts, like re-record/record-test we need to delete
    #   the breakpoints or move them? not sure for now
    # for just the beginning we might also send this, if we assume this code here happens a bit later
    #   and the user has already managed to setup breakpoints or if we start
    #   having storeable breakpoints between codetracer sessions
    infoPrint "last restart kind ", $data.lastRestartKind
    if data.lastRestartKind == RestartSubsystem:
      data.services.debugger.dapSetBreakpoints()

    data.dapApi.sendCtRequest(DapConfigurationDone, js{})
    # in db-backend/rust: interpret as Some(Location..) in the first case
    #   and None: in the second case
    let restoreLocation = if data.lastRestartKind == RestartSubsystem:
        if data.services.debugger.hasPendingRestartLocation:
          let pending = data.services.debugger.pendingRestartLocation
          data.services.debugger.clearPendingRestartLocation()
          pending.toJs
        else:
          data.services.debugger.location.toJs
      else:
        # in this case, it should just jump to entry
        cast[JsObject](nil) # Location(path: "", line: NO_LINE)
    data.dapApi.sendCtRequest(DapLaunch, js{
      traceFolder: data.trace.outputFolder,
      rawDiffIndex: data.startOptions.rawDiffIndex,
      ctRRWorkerExe: data.config.rrBackend.path,
      restoreLocation: restoreLocation
    })

  proc newOperationHandler*(viewsApi: MediatorWithSubscribers, operation: NewOperation) =
    data.status.currentOperation = operation.name
    data.status.stableBusy = operation.stableBusy
    inc data.status.operationCount
    viewsApi.emit(InternalStatusUpdate, data.status)

  proc addToScratchpadHandler*(viewsApi: MediatorWithSubscribers, value: ValueWithExpression) =
    # opens again or re-focuses scratchpad panel if needed
    let openNew = data.ui.componentMapping[Content.Scratchpad].isNil or
        data.ui.componentMapping[Content.Scratchpad].len == 0 or
        data.ui.componentMapping[Content.Scratchpad].toJs[0].isUndefined or
        data.ui.componentMapping[Content.Scratchpad][0].layoutItem.isNil
    if openNew:
      data.openLayoutTab(Content.Scratchpad)

    if not data.ui.componentMapping[Content.Scratchpad][0].layoutItem.parent.isNil:
      data.ui.componentMapping[Content.Scratchpad][0].
        layoutItem.parent.setActiveContentItem(
          data.ui.componentMapping[Content.Scratchpad][0].layoutItem)
    # if there is no parent, we assume it's a visible panel
    # with only tab scratchpad
    viewsApi.emit(InternalAddToScratchpad, value)

proc setupMiddlewareApis*(dapApi: DapApi, viewsApi: MediatorWithSubscribers) {.exportc.}=
  var lastCompleteMove: MoveState = nil
  proc nextJumpOpId(): int =
    data.services.debugger.currentJump += 1
    data.services.debugger.currentJump

  proc noteEventJumpLocation(event: ProgramEvent) =
    if event.highLevelPath.len == 0:
      return
    data.services.debugger.setPendingRestartLocation(
      Location(
        path: event.highLevelPath,
        line: event.highLevelLine,
        rrTicks: event.directLocationRRTicks,
      )
    )

  # for event in ..
  # dapApi.onRaw(DapStopped, proc(kind: CtEventKind, value: JsObject) = viewsApi.emit(DapStopped, value))

  # for event in DapFirst..DapLast
  # viewsApi.subscribeRaw(DapStepIn, proc(kind: CtEventKind, value: JsObject, sub: Subscriber) = dapApi.sendCtRequest(kind, value))
  # for event in InternalFirst..InternalLast
  # or maybe custom for each case!
  # viewsApi.subscribeRaw(InternalAddToScratchpad, proc(kind: CtEventKind, value: JsObject, sub: Subscriber) = 
    # viewsApi.emit(kind, value))
  # for other custom cases, manual overrides! maybe typed
  # problem: almost nowhere actual enforcing of types
  # maybe if we combine in big variant type, then ok, but then one big type (maybe that's still better? if one field with subcase?)
  # and a function that makes it possible to set/get as raw JsObject
  # case kind: CtEventKind:
  # of DapStopped: dapStoppedData*: DapStoppedEvent
  # ..
  # so one can either take a CtEvent
  # or a payload/kind+payload
  # or directly kind+raw 


  dapApi.on(DapStopped, proc(kind: CtEventKind, value: DapStoppedEvent) = viewsApi.emit(DapStopped, value))
  dapApi.on(CtLoadLocalsResponse, proc(kind: CtEventKind, value: CtLoadLocalsResponseBody) = viewsApi.emit(CtLoadLocalsResponse, value))
  dapApi.on(CtUpdatedTable, proc(kind: CtEventKind, value: CtUpdatedTableResponseBody) = viewsApi.emit(CtUpdatedTable, value))
  dapApi.on(CtUpdatedCalltrace, proc(kind: CtEventKind, value: CtUpdatedCalltraceResponseBody) = viewsApi.emit(CtUpdatedCalltrace, value))
  dapApi.on(CtUpdatedEvents, proc(kind: CtEventKind, value: seq[ProgramEvent]) = viewsApi.emit(CtUpdatedEvents, value))
  dapApi.on(CtUpdatedEventsContent, proc(kind: CtEventKind, value: cstring) = viewsApi.emit(CtUpdatedEventsContent, value))
  dapApi.on(CtCompleteMove, proc(kind: CtEventKind, value: MoveState) =
    viewsApi.emit(CtCompleteMove, value)
    lastCompleteMove = value
    
    when not defined(ctInExtension):
      data.status.stableBusy = false
      data.status.hasStarted = true
  )

  dapApi.on(CtLoadedTerminal, proc(kind: CtEventKind, value: seq[ProgramEvent]) = viewsApi.emit(CtLoadedTerminal, value))
  dapApi.on(CtUpdatedHistory, proc(kind: CtEventKind, value: HistoryUpdate) = viewsApi.emit(CtUpdatedHistory, value))
  dapApi.on(CtCalltraceSearchResponse, proc(kind: CtEventKind, value: seq[Call]) = viewsApi.emit(CtCalltraceSearchResponse, value))
  dapApi.on(CtUpdatedTrace, proc(kind: CtEventKind, value: TraceUpdate) = viewsApi.emit(CtUpdatedTrace, value))
  dapApi.on(CtUpdatedFlow, proc(kind: CtEventKind, value: FlowUpdate) = viewsApi.emit(CtUpdatedFlow, value))
  dapApi.on(CtNotification, proc(kind: CtEventKind, value: Notification) = viewsApi.emit(CtNotification, value))
  dapApi.on(CtLoadAsmFunctionResponse, proc(kind: CtEventKind, value: Instructions) = viewsApi.emit(CtLoadAsmFunctionResponse, value.toJs))

    #when defined(ctInExtension):
    # TODO: For now not using in the extension
    # dapApi.on(CtUpdatedFlow, proc(kind: CtEventKind, value: FlowUpdate) =
    #   if not dapApi.flowFunction.isNil:
    #     dapApi.flowFunction(dapApi.editor, value)
    # )
    # dapApi.on(CtCompleteMove, proc(kind: CtEventKind, value: MoveState) =
    #   if not dapApi.completeMoveFunction.isNil:
    #     dapApi.completeMoveFunction(dapApi.editor, value, dapApi)
    # )
  viewsApi.subscribe(InternalAddToScratchpadFromExpression, proc(kind: CtEventKind, value: cstring, sub: Subscriber) = viewsApi.emit(InternalAddToScratchpadFromExpression, value))

  when not defined(ctInExtension):
    dapApi.on(DapInitialized, proc(kind: CtEventKind, value: JsObject) = dapInitializationHandler())
    viewsApi.subscribe(InternalNewOperation, proc(kind: CtEventKind, value: NewOperation, sub: Subscriber) =
      newOperationHandler(viewsApi, value)
    )

    viewsApi.subscribe(InternalAddToScratchpad, proc(kind: CtEventKind, value: ValueWithExpression, sub: Subscriber) =
      addToScratchpadHandler(viewsApi, value))
  else:
    # TODO: also in extension: opening again/focusing scratchpad and 
    # sending to it, maybe using a handler that we pass to setupMiddlewareApis ?
    # or a global function?
    viewsApi.subscribe(InternalAddToScratchpad, proc(kind: CtEventKind, value: ValueWithExpression, sub: Subscriber) = viewsApi.emit(InternalAddToScratchpad, value))


  viewsApi.subscribe(CtNotification, proc(kind: CtEventKind, value: Notification, sub: Subscriber) = viewsApi.emit(CtNotification, value))
  viewsApi.subscribe(DapStepIn, proc(kind: CtEventKind, value: DapStepArguments, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
  viewsApi.subscribe(DapStepOut, proc(kind: CtEventKind, value: DapStepArguments, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
  viewsApi.subscribe(DapNext, proc(kind: CtEventKind, value: DapStepArguments, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
  viewsApi.subscribe(DapContinue, proc(kind: CtEventKind, value: DapStepArguments, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
  viewsApi.subscribe(DapStepBack, proc(kind: CtEventKind, value: DapStepArguments, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
  viewsApi.subscribe(DapReverseContinue, proc(kind: CtEventKind, value: DapStepArguments, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
  viewsApi.subscribe(DapSetBreakpoints, proc(kind: CtEventKind, value: DapSetBreakpointsArguments, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
  viewsApi.subscribe(CtReverseStepIn, proc(kind: CtEventKind, value: DapStepArguments, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
  viewsApi.subscribe(CtReverseStepOut, proc(kind: CtEventKind, value: DapStepArguments, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
  
  viewsApi.subscribe(CtLoadLocals, proc(kind: CtEventKind, value: LoadLocalsArg, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
  viewsApi.subscribe(CtUpdateTable, proc(kind: CtEventKind, value: UpdateTableArgs, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
  viewsApi.subscribe(CtLoadCalltraceSection, proc(kind: CtEventKind, value: CalltraceLoadArgs, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
  viewsApi.subscribe(CtEventLoad, proc(kind: CtEventKind, value: EmptyArg, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
  viewsApi.subscribe(CtLoadTerminal, proc(kind: CtEventkind, value: EmptyArg, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
  viewsApi.subscribe(CtCollapseCalls, proc(kind: CtEventkind, value: CollapseCallsArgs, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
  viewsApi.subscribe(CtExpandCalls, proc(kind: CtEventkind, value: CollapseCallsArgs, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
  viewsApi.subscribe(CtCalltraceJump, proc(kind: CtEventKind, value: Location, sub: Subscriber) =
    var payload = value
    payload.opId = nextJumpOpId()
    data.services.debugger.setPendingRestartLocation(payload)
    dapApi.sendCtRequest(kind, payload.toJs)
  )
  viewsApi.subscribe(CtEventJump, proc(kind: CtEventKind, value: ProgramEvent, sub: Subscriber) =
    var payload = value
    payload.opId = nextJumpOpId()
    noteEventJumpLocation(payload)
    dapApi.sendCtRequest(kind, payload.toJs)
  )
  viewsApi.subscribe(CtLoadHistory, proc(kind: CtEventKind, value: LoadHistoryArg, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
  viewsApi.subscribe(CtHistoryJump, proc(kind: CtEventKind, value: Location, sub: Subscriber) =
    var payload = value
    payload.opId = nextJumpOpId()
    data.services.debugger.setPendingRestartLocation(payload)
    dapApi.sendCtRequest(kind, payload.toJs)
  )
  viewsApi.subscribe(CtSearchCalltrace, proc(kind: CtEventKind, value: CallSearchArg, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
  viewsApi.subscribe(CtSourceLineJump, proc(kind: CtEventKind, value: SourceLineJumpTarget, sub: Subscriber) =
    var payload = value
    payload.opId = nextJumpOpId()
    dapApi.sendCtRequest(kind, payload.toJs)
  )
  viewsApi.subscribe(CtSourceCallJump, proc(kind: CtEventKind, value: SourceCallJumpTarget, sub: Subscriber) =
    var payload = value
    payload.opId = nextJumpOpId()
    dapApi.sendCtRequest(kind, payload.toJs)
  )
  viewsApi.subscribe(CtLocalStepJump, proc(kind: CtEventKind, value: LocalStepJump, sub: Subscriber) =
    var payload = value
    payload.opId = nextJumpOpId()
    if data.services.debugger.location.path.len > 0:
      data.services.debugger.setPendingRestartLocation(
        Location(
          path: data.services.debugger.location.path,
          line: data.services.debugger.location.line,
          rrTicks: payload.rrTicks,
        )
      )
    dapApi.sendCtRequest(kind, payload.toJs)
  )
  viewsApi.subscribe(CtTracepointToggle, proc(kind: CtEventKind, value: TracepointId, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
  viewsApi.subscribe(CtTracepointDelete, proc(kind: CtEventKind, value: TracepointId, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
  viewsApi.subscribe(CtTraceJump, proc(kind: CtEventKind, value: ProgramEvent, sub: Subscriber) =
    var payload = value
    payload.opId = nextJumpOpId()
    noteEventJumpLocation(payload)
    dapApi.sendCtRequest(kind, payload.toJs)
  )
  viewsApi.subscribe(CtLoadFlow, proc(kind: CtEventKind, value: CtLoadFlowArguments, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
  viewsApi.subscribe(CtRunToEntry, proc(kind: CtEventKind, value: EmptyArg, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
  viewsApi.subscribe(CtRunTracepoints, proc(kind: CtEventKind, value: RunTracepointsArg, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
  viewsApi.subscribe(CtSetupTraceSession, proc(kind: CtEventKind, value: RunTracepointsArg, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
  viewsApi.subscribe(CtLoadAsmFunction, proc(kind: CtEventKind, value: FunctionLocation, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
  viewsApi.subscribe(InternalLastCompleteMove, proc(kind: CtEventKind, value: EmptyArg, sub: Subscriber) =
    if not lastCompleteMove.isNil:
      viewsApi.emit(CtCompleteMove, lastCompleteMove.toJs)
  )

when defined(ctInExtension):
  when defined(ctInCentralExtensionContext):
    # we don't want this in webview
    {.emit: "module.exports.setupVsCodeExtensionViewsApi = setupVsCodeExtensionViewsApi;".}
    {.emit: "module.exports.newDapVsCodeApi = newDapVsCodeApi;".}
    {.emit: "module.exports.setupEditorApi = setupEditorApi;".}
    {.emit: "module.exports.setupMiddlewareApis = setupMiddlewareApis;".}
    {.emit: "module.exports.receive = receive;".}
    {.emit: "module.exports.newWebviewSubscriber = newWebviewSubscriber;".}
    {.emit: "module.exports.ctSourceLineJump = ctSourceLineJump".}
    {.emit: "module.exports.ctAddToScratchpad = ctAddToScratchpad".}
    {.emit: "module.exports.getRecentTraces = getRecentTraces".}
    {.emit: "module.exports.getRecentTransactions = getRecentTransactions".}
    {.emit: "module.exports.getTransactionTrace = getTransactionTrace".}
    {.emit: "module.exports.getCurrentTrace = getCurrentTrace".}
