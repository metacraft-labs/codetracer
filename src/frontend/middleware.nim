import std / [jsffi, jsconsole]
import .. / common / ct_event
import types
import communication, dap

# backend(dap) <-> middleware <-> view (self-contained, can be separate: 0, 1 or more components);

proc setupMiddlewareApis*(dapApi: DapApi, viewsApi: MediatorWithSubscribers) {.exportc.}=
  # backendApi.dapApi.onAll(proc(kind: CtEventKind, rawValue: JsObject) =
    # viewsApi.emit(kind, rawValue))

  dapApi.on(DapStopped, proc(kind: CtEventKind, value: DapStoppedEvent) = viewsApi.emit(DapStopped, value))
  dapApi.on(CtLoadLocalsResponse, proc(kind: CtEventKind, value: CtLoadLocalsResponseBody) = viewsApi.emit(CtLoadLocalsResponse, value))
  dapApi.on(CtUpdatedTable, proc(kind: CtEventKind, value: CtUpdatedTableResponseBody) = viewsApi.emit(CtUpdatedTable, value))
  dapApi.on(CtUpdatedCalltrace, proc(kind: CtEventKind, value: CtUpdatedCalltraceResponseBody) = viewsApi.emit(CtUpdatedCalltrace, value))
  dapApi.on(CtUpdatedEvents, proc(kind: CtEventKind, value: seq[ProgramEvent]) = viewsApi.emit(CtUpdatedEvents, value))
  dapApi.on(CtUpdatedEventsContent, proc(kind: CtEventKind, value: cstring) = viewsApi.emit(CtUpdatedEventsContent, value))
  dapApi.on(CtCompleteMove, proc(kind: CtEventKind, value: MoveState) = viewsApi.emit(CtCompleteMove, value))
  dapApi.on(CtLoadedTerminal, proc(kind: CtEventKind, value: seq[ProgramEvent]) = viewsApi.emit(CtLoadedTerminal, value))
  dapApi.on(CtUpdatedHistory, proc(kind: CtEventKind, value: HistoryUpdate) = viewsApi.emit(CtUpdatedHistory, value))
  dapApi.on(CtCalltraceSearchResponse, proc(kind: CtEventKind, value: seq[Call]) = viewsApi.emit(CtCalltraceSearchResponse, value))
  dapApi.on(CtUpdatedTrace, proc(kind: CtEventKind, value: TraceUpdate) = viewsApi.emit(CtUpdatedTrace, value))
  dapApi.on(CtUpdatedFlow, proc(kind: CtEventKind, value: FlowUpdate) = viewsApi.emit(CtUpdatedFlow, value))

  viewsApi.subscribe(CtLoadLocals, proc(kind: CtEventKind, value: LoadLocalsArg, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
  viewsApi.subscribe(CtUpdateTable, proc(kind: CtEventKind, value: UpdateTableArgs, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
  viewsApi.subscribe(CtLoadCalltraceSection, proc(kind: CtEventKind, value: CalltraceLoadArgs, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
  viewsApi.subscribe(CtEventLoad, proc(kind: CtEventKind, value: EmptyArg, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
  viewsApi.subscribe(CtLoadTerminal, proc(kind: CtEventkind, value: EmptyArg, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
  viewsApi.subscribe(CtCollapseCalls, proc(kind: CtEventkind, value: CollapseCallsArgs, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
  viewsApi.subscribe(CtExpandCalls, proc(kind: CtEventkind, value: CollapseCallsArgs, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
  viewsApi.subscribe(CtCalltraceJump, proc(kind: CtEventKind, value: Location, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
  viewsApi.subscribe(CtEventJump, proc(kind: CtEventKind, value: ProgramEvent, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
  viewsApi.subscribe(CtLoadHistory, proc(kind: CtEventKind, value: LoadHistoryArg, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
  viewsApi.subscribe(CtHistoryJump, proc(kind: CtEventKind, value: Location, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
  viewsApi.subscribe(CtSearchCalltrace, proc(kind: CtEventKind, value: CallSearchArg, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
  viewsApi.subscribe(CtSourceLineJump, proc(kind: CtEventKind, value: SourceLineJumpTarget, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
  viewsApi.subscribe(CtSourceCallJump, proc(kind: CtEventKind, value: SourceCallJumpTarget, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
  viewsApi.subscribe(CtLocalStepJump, proc(kind: CtEventKind, value: LocalStepJump, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
  viewsApi.subscribe(CtTracepointToggle, proc(kind: CtEventKind, value: TracepointId, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
  viewsApi.subscribe(CtTracepointDelete, proc(kind: CtEventKind, value: TracepointId, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
  viewsApi.subscribe(CtTraceJump, proc(kind: CtEventKind, value: ProgramEvent, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
  viewsApi.subscribe(CtLoadFlow, proc(kind: CtEventKind, value: Location, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))

# maybe somehow a more proxy-like/macro way
# some kind of loop or more raw subscribe, that directly sends for many cases
# for dap events:
#   viewsApi.subscribeRaw(CtLoadLocals, proc(kind: CtEventKind, rawValue: JsObject, sub: Subscriber) =
#     dapApi.requestOrEvent(kind, rawValue))
# for others(view/frontend communication) maybe different schema
      
when defined(ctInExtension):
  when defined(ctInCentralExtensionContext):
    # we don't want this in webview
    {.emit: "module.exports.setupVsCodeExtensionViewsApi = setupVsCodeExtensionViewsApi;".}
    {.emit: "module.exports.newDapVsCodeApi = newDapVsCodeApi;".}
    {.emit: "module.exports.setupMiddlewareApis = setupMiddlewareApis;".}  
    {.emit: "module.exports.receive = receive;".}
    {.emit: "module.exports.newWebviewSubscriber = newWebviewSubscriber;".}

