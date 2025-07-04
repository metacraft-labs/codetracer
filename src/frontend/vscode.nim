when defined(ctInExtension):
  import std / [async, strformat, jsffi, jsconsole]
  import lib
  import .. / common / ct_event
  import .. / frontend / types
  import communication

  type
    VsCode* = ref object
      postMessage*: proc(raw: JsObject): void
      # valid only in extension-level, not webview context
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
      command: cstring
      body*: JsObject 
      
  # proc acquireVsCodeApi(): VsCode {.importc.}

  {.emit: "var vscode = null; try { vscode = require(\"vscode\"); } catch { vscode = acquireVsCodeApi(); }".}

  var vscode* {.importc.}: VsCode # vscode in extension central context; acquireVsCodeApi() in webview;

  ### WebviewSubscriber:

  type
    WebviewSubscriber* = ref object of Subscriber
      webview*: VsCodeWebview

  method emitRaw*(w: WebviewSubscriber, kind: CtEventKind, value: JsObject, sourceSubscriber: Subscriber) =
    # on receive the other transport should set the actual subscriber: for now always vscode extension context (middleware)
    console.log cstring"webview subscriber emitRaw: ", $kind, cstring" ", value
    w.webview.postMessage(CtRawEvent(kind: kind, value: value).toJs)
    echo cstring"  after postMessage"

  proc newWebviewSubscriber*(webview: VsCodeWebview): WebviewSubscriber {.exportc.}=
    WebviewSubscriber(webview: webview)

  ### VsCodeViewTransport:

  type
    VsCodeViewTransport* = ref object of Transport
      vscode: VsCode
      # onVsCodeMesssage*: proc(t: VsCodeViewTransport, event: JsObject)

  method send*(t: VsCodeViewTransport, data: JsObject, subscriber: Subscriber)  =
    t.vscode.postMessage(data)

  method onVsCodeMessage*(t: VsCodeViewTransport, eventData: CtRawEvent) {.base.}=
    t.internalRawReceive(eventData.toJs, Subscriber(name: cstring"vscode extenson context"))

  proc newVsCodeViewTransport*(vscode: VsCode, vscodeWindow: JsObject): VsCodeViewTransport =
    result = VsCodeViewTransport(vscode: vscode) # , onVsCodeMessage: onVsCodeMessage)
    vscodeWindow.addEventListener(cstring"message", proc(event: JsObject) = # TODO? vscode event
      console.log cstring"vscode view received new message in event listener: ", event.toJs
      let data = event.data
      if not data.kind.isNil and not data.value.isNil:
        # probably a ct raw event: as maybe we can receive other ones?
        result.onVsCodeMessage(cast[CtRawEvent](data)))
  
  proc newVsCodeViewApi*(name: cstring, vscode: VsCode, vscodeWindow: JsObject): MediatorWithSubscribers {.exportc.} =
    let transport = newVsCodeViewTransport(vscode, vscodeWindow)
    newMediatorWithSubscribers(name, isRemote=true, singleSubscriber=true, transport=transport)

when not defined(ctInExtension):
  type
    DapApi* = ref object
      handlers*: array[CtEventKind, seq[proc(kind: CtEventKind, raw: JsObject)]]    
else:
  type
    DapApi* = ref object
      handlers*: array[CtEventKind, seq[proc(kind: CtEventKind, raw: JsObject)]]
      vscode*: VsCode
      context*: VsCodeContext

type
  DapRequest* = ref object
    command*: cstring
    value*: JsObject

const CT_EVENT_DAP_TRACKING_RESPONSE_KINDS = {CtLoadLocals}

func toCtDapResponseEventKind*(kind: CtEventKind): CtEventKind =
  # TODO: based on $kind? or mapping?
  case kind:
  of CtLoadLocals: CtLoadLocalsResponse
  else: raise newException(ValueError, fmt"no response ct event kind for {kind} defined")


func toDapCommandOrEvent(kind: CtEventKind): cstring =
  # TODO
  # eventually auto mapping using $kind and tokenization?
  case kind:
  of CtLoadLocals: "ct/load-locals"
  of CtLoadLocalsResponse: "ct/load-locals-response"
  of DapStopped: "stopped"
  else: raise newException(ValueError, fmt"not mapped to request command yet: {kind}")


func commandToCtResponseEventKind(command: cstring): CtEventKind =
  # based on parseEnum[CtEventKind](command) and toCtDapResponseEventKind?
  # or some common mapping?
  case $command:
  of "ct/load-locals": CtLoadLocalsResponse
  else: raise newException(
    ValueError, 
    "no ct event kind response for command: \"" & $command & "\" defined")

func dapEventToCtEventKind(event: cstring): CtEventKind =
  case $event:
  of "stopped": DapStopped
  of "initialized": DapInitialized
  of "output": DapOutput
  else: raise newException(
    ValueError,
    "no ct event kind for this string: \"" & $event & "\" defined")

proc on*[T](dap: DapApi, kind: CtEventKind, handler: proc(kind: CtEventKind, value: T)) =
  dap.handlers[kind].add(proc(kind: CtEventKind, rawValue: JsObject) =
    handler(kind, cast[T](rawValue)))

proc receive*(dap: DapApi, kind: CtEventKind, rawValue: JsObject) =
  for handler in dap.handlers[kind]:
    try:
      handler(kind, rawValue)
    except:
      echo "dap handler error: ", getCurrentExceptionMsg()
      echo "   kind: ", kind
      console.log cstring"rawValue: ", rawValue

proc receiveResponse*(dap: DapApi, command: cstring, rawValue: JsObject) =
  dap.receive(commandToCtResponseEventKind(command), rawValue)

proc receiveEvent*(dap: DapApi, event: cstring, rawValue: JsObject) =
  dap.receive(dapEventToCtEventKind(event), rawValue)
 
when not defined(ctInExtension):
  proc asyncSendCtRequest(dap: DapApi, kind: CtEventKind, rawValue: JsObject) {.async.} =
    raise newException(NotImplementedError, "asyncSendCtRequest not implemented")
else:
  proc asyncSendCtRequest(dap: DapApi, kind: CtEventKind, rawValue: JsObject) {.async.} =
    console.log cstring"-> dap request: ", toDapCommandOrEvent(kind), rawValue
    # let response = 
    discard dap.vscode.debug.activeDebugSession.customRequest(toDapCommandOrEvent(kind), rawValue)
    # console.log cstring"<- dap response(or undefined if timeout): ", response
    # if kind in CT_EVENT_DAP_TRACKING_RESPONSE_KINDS and not response.isNil:
    #   dap.receiveResponse(cast[cstring](response.command), response.value)

  proc newDapVsCodeApi*(vscode: VsCode, context: VsCodeContext): DapApi {.exportc.} =
    result = DapApi(vscode: vscode, context: context)
    proc onDidSendMessage(message: VsCodeDapMessage) =
      console.log cstring"<- dap message:", message
      if message.`type` == cstring"event":
        result.receiveEvent(message.event, message.body)
      elif message.`type` == cstring"response":
        try:
          result.receiveResponse(message.command, message.body)
        except ValueError as e:
          console.warn cstring"  receive response error: ", cstring(e.msg)

    context.subscriptions.push(
      vscode.debug.toJs.registerDebugAdapterTrackerFactory(cstring"*", js{
        createDebugAdapterTracker: proc(session: VsCodeDebugSession): JsObject =
          JsObject{
            onDidSendMessage: onDidSendMessage,
          }
        }
      ))

proc sendCtRequest(dap: DapApi, kind: CtEventKind, rawValue: JsObject) =
  discard dap.asyncSendCtRequest(kind, rawValue)


# backend(dap) <-> middleware <-> view (self-contained, can be separate: 0, 1 or more components);

proc setupMiddlewareApis*(dapApi: DapApi, viewsApi: MediatorWithSubscribers) {.exportc.}=
    # backendApi.dapApi.onAll(proc(kind: CtEventKind, rawValue: JsObject) =
      # viewsApi.emit(kind, rawValue))

    dapApi.on(DapStopped, proc(kind: CtEventKind, value: DapStoppedEvent) = viewsApi.emit(DapStopped, value))
    dapApi.on(CtLoadLocalsResponse, proc(kind: CtEventKind, value: CtLoadLocalsResponseBody) = viewsApi.emit(CtLoadLocalsResponse, value))

    # backendApi.subscribe(DapStopped, proc(kind: CtEventKind, value: DapStoppedEvent, sub: Subscriber) = viewsApi.emit(kind, value))
    # backendApi.subscribe(CtLoadLocalsResponse, proc(kind: CtEventKind, value: CtLoadLocalsResponseBody, sub: Subscriber) = viewsApi.emit(kind, value))
    # maybe somehow a more proxy-like/macro way

    viewsApi.subscribe(CtLoadLocals, proc(kind: CtEventKind, value: LoadLocalsArg, sub: Subscriber) = dapApi.sendCtRequest(kind, value.toJs))

    # some kind of loop or more raw subscribe, that directly sends for many cases
    # for dap events:
    #   viewsApi.subscribeRaw(CtLoadLocals, proc(kind: CtEventKind, rawValue: JsObject, sub: Subscriber) =
    #     dapApi.requestOrEvent(kind, rawValue))
    # for others(view/frontend communication) maybe different schema
      
when defined(ctInExtension):
  type
    VsCodeExtensionToViewsTransport* = ref object of Transport


  proc setupVsCodeExtensionViewsApi*(name: cstring): MediatorWithSubscribers {.exportc.} =
    let transport = VsCodeExtensionToViewsTransport() # for now not used for sending;
    # viewsApi.receive called in message handler in `getOrCreatePanel` in initPanels.ts
    newMediatorWithSubscribers(name, isRemote=true, singleSubscriber=false, transport=transport)

  when defined(ctInCentralExtensionContext):
    # we don't want this in webview
    {.emit: "module.exports.setupVsCodeExtensionViewsApi = setupVsCodeExtensionViewsApi;".}
    {.emit: "module.exports.newDapVsCodeApi = newDapVsCodeApi;".}
    {.emit: "module.exports.setupMiddlewareApis = setupMiddlewareApis;".}  
    {.emit: "module.exports.receive = receive;".}
    {.emit: "module.exports.newWebviewSubscriber = newWebviewSubscriber;".}

# receive might become the same! at least for javascript-based code
# but with different dap instances: one wrapping vscode and one custom in our electron
# other differences might be in coordinating updates to components/editor: those might be
# overriden as well differently in vscode and in electron


# 

    # self.api.emit(CtLoadLocals, "")

# self.api.subscribe(CtLoadLocalsResponse, self.onLoadLocalsResponse)
