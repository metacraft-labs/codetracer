import std / [async, strformat, jsffi]
import lib
import .. / common / ct_event
import .. / frontend / types
# import .. / common / types
import communication

type
  VsCode* = ref object
    postMessage*: proc(raw: JsObject): void
    # valid only in extension-level, not webview context probably
    debug: VsCodeDebugApi

  VsCodeDebugApi* = ref object
    activeDebugSession*: VsCodeDebugSession

  VsCodeDebugSession* = ref object
    customRequest*: proc(command: cstring, value: JsObject): Future[JsObject]

  VsCodeWebview* = ref object
    postMessage*: proc(raw: JsObject)

  VsCodeContext* = ref object

type
  DapApi* = ref object of RootObj

  VsCodeDapApi* = ref object of DapApi
    context*: VsCodeContext
    vscode*: VsCode

var vscode*: VsCode

### VsCodeDapApi:

proc newVsCodeDap*(context: VsCodeContext): VsCodeDapApi {.exportc.} =
  VsCodeDapApi(vscode: vscode, context: context)


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
  Dap* = ref object
    vscode: VsCode

  DapRequest* = ref object
    command*: cstring
    value*: JsObject


method toDapRequestCommand(dap: Dap, kind: CtEventKind): cstring =
  # TODO
  # CtLoadLocals => "ct/load-locals"
  # Step => "step" etc
  cstring($kind)

method sendCtRequest(dap: Dap, kind: CtEventKind, rawValue: JsObject) =
  # TODO: await and handle response? emit for it?
  discard dap.vscode.debug.activeDebugSession.customRequest(dap.toDapRequestCommand(kind), rawValue)


# backend <-> middleware <-> view (self-contained, can be separate: 0, 1 or more components);

# backend
# views

type
  VsCodeBackendTransport* = ref object of Transport
    vscode*: VsCode
    dapApi*: VsCodeDapApi

proc newVsCodeBackendTransport(dapApi: VsCodeDapApi): VsCodeBackendTransport =
  VsCodeBackendTransport(vscode: vscode, dapApi: dapApi)

proc setupMiddlewareToBackendApi*(backendApi: Mediator, viewsApi: Mediator) =
  backendApi.subscribe(DapStopped, proc(kind: CtEventKind, value: DapStoppedEvent, sub: Subscriber) = viewsApi.emit(kind, value))
  backendApi.subscribe(CtLoadLocalsResponse, proc(kind: CtEventKind, value: CtLoadLocalsResponseBody, sub: Subscriber) = viewsApi.emit(kind, value))
    # maybe somehow a more proxy-like/macro way

  # setupDapEventHandlers(backendApi)
  viewsApi.subscribe(CtLoadLocals, proc(kind: CtEventKind, value: LoadLocalsArg, sub: Subscriber) = backendApi.emit(kind, value))


proc setupVsCodeBackendApi*(name: cstring, dapApi: VsCodeDapApi, viewsApi: Mediator): MediatorWithSubscribers {.exportc.}=
  var transport = newVsCodeBackendTransport(dapApi)
  result = newMediatorWithSubscribers($name, transport)
  # for event in FirstDapEvent..LastDapEvent:
    # transport.rawSubscribe(event, proc(kind: CtEventKind, rawValue: JsObject) 
  setupMiddlewareToBackendApi(result, viewsApi)


type
  VsCodeExtensionToViewsTransport* = ref object of Transport


proc setupVsCodeExtensionViewsApi*(name: cstring): MediatorWithSubscribers {.exportc.} =
  let transport = VsCodeExtensionToViewsTransport() # TODO
  newMediatorWithSubscribers($name, transport)

  
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

# vscode:
# newVsCodeViewModelServer(vscode)

# electron:
# newViewModelServer(receive: .. receive)
# 
# newViewModelClient(newLocalTransport(server))

    # self.api.emit(CtLoadLocals, "")

# self.api.subscribe(CtLoadLocalsResponse, self.onLoadLocalsResponse)
