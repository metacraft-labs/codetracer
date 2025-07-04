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
      debug*: VsCodeDebugApi

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
      command*: cstring
      body*: JsObject 
      
  proc acquireVsCodeApi*(): VsCode {.importc.}

  {.emit: "var vscode = null; try { vscode = require(\"vscode\"); } catch { vscode = acquireVsCodeApi(); }".}

  var vscode* {.importc.}: VsCode # vscode in extension central context; acquireVsCodeApi() in webview;

  const ctExtensionLogging {.strdefine.}: bool = true # TODO: false default for production
  const logging = ctExtensionLogging

  ### WebviewSubscriber:

  type
    WebviewSubscriber* = ref object of Subscriber
      webview*: VsCodeWebview

  method emitRaw*(w: WebviewSubscriber, kind: CtEventKind, value: JsObject, sourceSubscriber: Subscriber) =
    # on receive the other transport should set the actual subscriber: for now always vscode extension context (middleware)
    if logging: console.log cstring"webview subscriber emitRaw: ", $kind, cstring" ", value
    w.webview.postMessage(CtRawEvent(kind: kind, value: value).toJs)
    if logging: echo cstring"  after postMessage"

  proc newWebviewSubscriber*(webview: VsCodeWebview): WebviewSubscriber {.exportc.}=
    WebviewSubscriber(webview: webview)

  ### VsCodeViewTransport:

  type
    VsCodeViewTransport* = ref object of Transport
      vscode: VsCode

  method send*(t: VsCodeViewTransport, data: JsObject, subscriber: Subscriber)  =
    t.vscode.postMessage(data)

  method onVsCodeMessage*(t: VsCodeViewTransport, eventData: CtRawEvent) {.base.}=
    t.internalRawReceive(eventData.toJs, Subscriber(name: cstring"vscode extenson context"))

  proc newVsCodeViewTransport*(vscode: VsCode, vscodeWindow: JsObject): VsCodeViewTransport =
    result = VsCodeViewTransport(vscode: vscode)
    vscodeWindow.addEventListener(cstring"message", proc(event: JsObject) =
      if logging: console.log cstring"vscode view received new message in event listener: ", event.toJs
      let data = event.data
      if not data.kind.isNil and not data.value.isNil:
        # check that it's probably a ct raw event: as maybe we can receive other messages?
        result.onVsCodeMessage(cast[CtRawEvent](data)))
  
  proc newVsCodeViewApi*(name: cstring, vscode: VsCode, vscodeWindow: JsObject): MediatorWithSubscribers {.exportc.} =
    let transport = newVsCodeViewTransport(vscode, vscodeWindow)
    newMediatorWithSubscribers(name, isRemote=true, singleSubscriber=true, transport=transport)

  type
    VsCodeExtensionToViewsTransport* = ref object of Transport

  proc setupVsCodeExtensionViewsApi*(name: cstring): MediatorWithSubscribers {.exportc.} =
    let transport = VsCodeExtensionToViewsTransport() # for now not used for sending;
    # viewsApi.receive called in message handler in `getOrCreatePanel` in initPanels.ts
    newMediatorWithSubscribers(name, isRemote=true, singleSubscriber=false, transport=transport)

