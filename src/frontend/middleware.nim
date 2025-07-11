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

    viewsApi.subscribe(CtLoadLocals, proc(kind: CtEventKind, value: LoadLocalsArg, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
    viewsApi.subscribe(CtUpdateTable, proc(kind: CtEventKind, value: UpdateTableArgs, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
    viewsApi.subscribe(CtLoadCalltraceSection, proc(kind: CtEventKind, value: CalltraceLoadArgs, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
    viewsApi.subscribe(CtEventLoad, proc(kind: CtEventKind, value: EmptyArg, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
    viewsApi.subscribe(CtLoadTerminal, proc(kind: CtEventkind, value: EmptyArg, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
    viewsApi.subscribe(CtCollapseCalls, proc(kind: CtEventkind, value: CollapseCallsArgs, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))
    viewsApi.subscribe(CtExpandCalls, proc(kind: CtEventkind, value: CollapseCallsArgs, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))

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

