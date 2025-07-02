when defined(ctInExtension):
  import std / [async, strformat, jsffi]
  import lib
  import .. / common / ct_event
  import .. / frontend / types
  import communication

  type
    VsCode* = ref object
      postMessage*: proc(raw: JsObject): void
      # valid only in extension-level, not webview context probably
      debug: VsCodeDebugApi

    VsCodeDebugApi* = ref object
      activeDebugSession*: VsCodeDebugSession

    VsCodeDebugSession* = ref object of JsObject
      customRequest*: proc(command: cstring, value: JsObject): Future[JsObject]

    VsCodeWebview* = ref object
      postMessage*: proc(raw: JsObject)

    VsCodeContext* = ref object of JsObject

    VsCodeDapMessage* = ref object of JsObject
      # type for now can be also accessed as ["type"] because of JsObject
      `type`*: cstring
      event*: cstring
      body*: JsObject 
      
  proc acquireVsCodeApi(): VsCode {.importc.}

  {.emit: "const vscode = require(\"vscode\");"}
  
  var vscode* {.importc.}: VsCode # = acquireVsCodeApi()

  ### WebviewSubscriber:

  type
    WebviewSubscriber* = ref object of Subscriber
      webview*: VsCodeWebview

  method emit*[T](w: WebviewSubscriber, kind: CtEventKind, value: T, sourceSubscriber: Subscriber) =
    # on receive the other transport should set the actual subscriber: for now always vscode extension context (middleware)
    w.webview.postMessage(CtRawEvent(kind: kind, value: value.toJs).toJs)

  ### VsCodeViewTransport:

  type
    VsCodeViewTransport* = ref object of Transport
      vscode: VsCode
      onVsCodeMesssage*: proc(t: VsCodeViewTransport, event: JsObject)


  method send*(t: VsCodeViewTransport, eventKind: CtEventKind, value: JsObject, subscriber: Subscriber) =
    t.vscode.postMessage(CtRawEvent(kind: eventKind, value: value).toJs)


  method onVsCodeMessage*(t: VsCodeViewTransport, event: CtRawEvent) =
    t.internalRawReceive(event.toJs, Subscriber(name: "vscode extenson context"))

  proc newVsCodeViewTransport*(vscode: VsCode, vscodeWindow: JsObject): VsCodeViewTransport =
    result = VsCodeViewTransport(vscode: vscode)
    vscodeWindow.addEventListener(cstring"message", proc(event: CtRawEvent) =
      result.onVsCodeMessage(event))

  proc newVsCodeViewApi*(name: string, vscode: VsCode, vscodeWindow: JsObject): MediatorWithSubscribers =
    let transport = newVsCodeViewTransport(vscode, vscodeWindow)
    newMediatorWithSubscribers(name, transport)


  # proc newVsCodeViewModelServer*(vscode: VsCode): ViewModelServer {.exportc.}=
  #    var dap = Dap(vscode: vscode)
  #    let receive = proc(v: ViewModelServer, kind: CtEventKind, rawValue: JsObject, subscriber: Subscriber) =
  #       if kind == CtSubscribe:
  #         v.register(kind, subscriber)
  #       elif true: # TODO: dap check
  #         dap.sendCtRequest(kind, rawValue)
  #    newViewModelServer(receive)

type
  DapApi* = ref object of RootObj
    handlers*: array[CtEventKind, proc(kind: CtEventKind, raw: JsObject)]

  DapRequest* = ref object
    command*: cstring
    value*: JsObject

const CT_EVENT_DAP_TRACKING_RESPONSE_KINDS = {CtLoadLocals}

func toCtDapResponseEventKind(kind: CtEventKind): CtEventKind =
  # TODO: based on $kind? or mapping?
  case kind:
  of CtLoadLocals: CtLoadLocalsResponse
  else: raise newException(ValueError, fmt"no response ct event kind for {kind} defined")


method toDapCommandOrEvent(dap: DapApi, kind: CtEventKind): cstring =
  # TODO
  # eventually auto mapping using $kind and tokenization?
  case kind:
  of CtLoadLocals: "ct/load-locals"
  of CtLoadLocalsResponse: "ct/load-locals-response"
  of DapStopped: "stopped"
  else: raise newException(ValueError, fmt"not mapped to request command yet: {kind}")


func commandToCtResponseEventKind(dap: Dap, command: cstring): CtEventKind =
  # based on parseEnum[CtEventKind](command) and toCtDapResponseEventKind?
  # or some common mapping?
  case command:
  of "load-locals": CtLoadLocalsResponse
  else: raise newException(ValueError, fmt"no ct event kind response for command {command} defined")


method sendCtRequest(dap: DapApi, kind: CtEventKind, rawValue: JsObject) =
  discard dap.asyncSendCtRequest(kind, rawValue)


method asyncSendCtRequest(dap: DapVsCodeApi, kind: CtEventKind, rawValue: JsObject) {.async, base.} =
  raise newException(NotImplementedError, "asyncSendCtRequest not implemented")

method on*[T](dap: DapApi, kind: CtEventKind, handler: proc(kind: CtEventKind, value: T)) =
  dap.handlers[kind].add(proc(kind: CtEventKind, rawValue: JsObject) =
    handler(kind, cast[T](rawValue)))

method receive*(dap: DapApi, kind: CtEventKind, rawValue: JsObject) =
  for handler in dap.handlers[kind]:
    try:
      handler(kind, rawValue)
    except:
      echo "dap handler error: ", getCurrentExceptionMsg()
      echo "   kind: ", kind
      console.log cstring"rawValue: ", rawValue

method receiveRequest*(dap: DapApi, command: cstring, rawValue: JsObject) =
  dap.receive(commandToResponseEventKind(command))

method 
when defined(ctInExtension):
  type
    DapVsCodeApi* = ref object of DapApi
      vscode*: VsCode
      context*: VsCodeContext

  method asyncSendCtRequest(dap: DapVsCodeApi, kind: CtEventKind, rawValue: JsObject) {.async.} =
    let response = await dap.vscode.debug.activeDebugSession.customRequest(dap.toDapRequestCommand(kind), rawValue)
    if kind in CT_EVENT_DAP_TRACKING_RESPONSE_KINDS:
      dap.receiveRequest(toCtDapResponseEventKind(kind), response.value)

  proc newDapVsCodeApi*(vscode: VsCode, context: VsCodeContext): DapVsCodeApi {.exportc.} =
    result = DapVsCodeApi(vscode: vscode, context: context)
    proc onDidSendMessage(message: VsCodeDapMessage) =
      if message["type"] == cstring"event":
        result.receiveEvent(message.event, message.body)

    context.subscriptions.add(
      vscode.debug.registerDebugAdapterTrackerFactory(cstring"*"", js{
        createDebugAdapterTracker: proc(session: VsCodeDebugSession): JsObject =
          JsObject{
            onDidSendMessage: onDidSendMessage,
          }
        }
      ))
  


  # backend <-> middleware <-> view (self-contained, can be separate: 0, 1 or more components);

  # type
    # VsCodeBackendTransport* = ref object of Transport
      # vscode*: VsCode
      # dapApi*: VsCodeDapApi

  # proc newVsCodeBackendTransport(dapApi: VsCodeDapApi): VsCodeBackendTransport =
    # VsCodeBackendTransport(vscode: dapApi.vscode, dapApi: dapApi)

proc setupMiddlewareApis*(dapApi: DapApi, viewsApi: MediatorWithSubscribers) {.exportc.}=
    # backendApi.dapApi.onAll(proc(kind: CtEventKind, rawValue: JsObject) =
      # viewsApi.emit(kind, rawValue))

    dapApi.on(DapStopped, proc(value: DapStoppedEvent) = viewsApi.emit(DapStopped, value))
    dapApi.on(CtLoadLocalsResponse, proc(value: CtLoadLocalsResponseBody) = viewsApi.emit(CtLoadLocalsResponse, value))
    
    # backendApi.subscribe(DapStopped, proc(kind: CtEventKind, value: DapStoppedEvent, sub: Subscriber) = viewsApi.emit(kind, value))
    # backendApi.subscribe(CtLoadLocalsResponse, proc(kind: CtEventKind, value: CtLoadLocalsResponseBody, sub: Subscriber) = viewsApi.emit(kind, value))
    # maybe somehow a more proxy-like/macro way

    # setupDapEventHandlers(backendApi)
    viewsApi.subscribe(CtLoadLocals, proc(kind: CtEventKind, value: LoadLocalsArg, sub: Subscriber) = dapApi.requestOrEvent(kind, value))
    # some kind of loop or more raw subscribe, that directly sends for many cases
    # for dap events:
    #   viewsApi.subscribeRaw(CtLoadLocals, proc(kind: CtEventKind, rawValue: JsObject, sub: Subscriber) =
    #     dapApi.requestOrEvent(kind, rawValue))
    # for others(view/frontend communication) maybe different schema


  proc setupVsCodeBackendApi*(name: cstring, dapApi: VsCodeDapApi, viewsApi: MediatorWithSubscribers): MediatorWithSubscribers {.exportc.}=
    var transport = newVsCodeBackendTransport(dapApi)
    result = newMediatorWithSubscribers($name, transport)
    # for event in FirstDapEvent..LastDapEvent:
      # transport.rawSubscribe(event, proc(kind: CtEventKind, rawValue: JsObject) 
    setupMiddlewareApis(result, viewsApi)


  type
    VsCodeExtensionToViewsTransport* = ref object of Transport


  proc setupVsCodeExtensionViewsApi*(name: cstring): MediatorWithSubscribers {.exportc.} =
    let transport = VsCodeExtensionToViewsTransport() # TODO
    newMediatorWithSubscribers($name, transport)

  {.emit: "module.exports.setupVsCodeExtensionViewsApi = setupVsCodeExtensionViewsApi;".}
  {.emit: "module.exports.newDapVsCodeApi = newDapVsCodeApi;".}
  {.emit: "module.exports.setupVsCodeBackendApi = setupVsCodeBackendApi;".}
  {.emit: "module.exports.setupMiddlewareApis = setupMiddlewareApis;".}  

# vscode backend api
# method emit ..:
  # discard v.emitAsync(..)

# method emitAsync ..:
  # let response = await self.dap.sendCtRequest(kind, value.toJs)
  # if response?
    # self.receive(self, self.dap.toCtEventKind(response.command), response.value, self.backendSubscriber)


# method subscribe ..:
  # add to handlers later called by receive

# proc setupDapEventHandlers ..:
  # backendApi.dap().onEvent(proc(rawMessage: DapRawMessage) =
    # backendApi.receive(backendApi, backendApi.dap.toCtEventKind(rawMessage.event), rawMessage.value, backendApi.backendSubscriber))

# method onMessage for vscode and for other dap:

# method onEvent*(dap: VsCodeDap, handler: ..) =
  # dap.context.sub.. 
    # dap.debug.registerDebugAdapterTrackerFactory..
      # createDebugAdapterTracker..
        # return {
          # onDidSendMessage: ..
            # if type == "event":
              # handler(msg)
      # }
        # ..

# method onEvent*(dap: CtDap, handler: ..) =
  # dap.internal.onEvent(..)
  # or directly CtDap being the impl

# 
# TODO: vscode/dap specific wrappers if needed for receiving and emitting:
# dap incoming responses/events calling `emit()` and 
# panel-incoming events calling `receive`

# for normal frontend: dap code also calling `emit()`
# panel-incoming events would already call `receive`

# receive might become the same! at least for javascript-based code
# but with different dap instances: one wrapping vscode and one custom in our electron
# other differences might be in coordinating updates to components/editor: those might be
# overriden as well differently in vscode and in electron


# 

    # self.api.emit(CtLoadLocals, "")

# self.api.subscribe(CtLoadLocalsResponse, self.onLoadLocalsResponse)
