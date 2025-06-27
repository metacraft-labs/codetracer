import std / [strformat, jsffi]
import lib

type
  VsCode* = ref object
    postMessage*: proc(js: JsObject): void
    # valid only in extension-level, not webview context probably
    debug: VsCodeDebugApi

  VsCodeDebugApi* = ref object
    activeDebugSession*: VsCodeDebugSession

  VsCodeDebugSession* = ref object
    customRequest*: proc(command: cstring, value: JsObject): Future[JsObject]

var vscode*: VsCode

type
  CtRawEvent* = ref object
    kind*: CtEventKind
    value*: JsObject

type
  VsCodeTransport* = ref object
    vscode: VsCode
    messageHandlers*: array[CtEventKind, seq[proc(raw: JsObject): void]]
    onVsCodeMesssage*: proc(t: VsCodeTransport, event: JsObject)

method emit*[T](t: Transport, eventKind: CtEventKind, value: T) =
  t.vscode.postMessage(CtRawEvent(kind: eventKind, value: value.toJs))

method subscribe*[T](t: Transport, eventKind: CtEventKind, callback: proc(value: T): Future[void]) {.base.} =
  # t.messageHandlers used in onVsCodeMessage : on window.addEventListener('message', (event) => t.onVsCodeMessage(event))
  # if not t.messageHandlers.hasKey(eventKind):
    # t.messageHandlers[eventKind] = @[]
  t.messageHandlers[eventKind].add(proc(raw: JsObject) = discard callback(cast[T](raw)))
  t.vscode.postMessage(CtRawEvent())

method onVsCodeMessage*(t: VsCodeTransport, event: CtRawEvent) =
  for handler in t.messageHandlers[event.kind]:
    try:
      handler(event.value)
    except:
      cerror fmt"handler for {event.kind} error: {getCurrentExceptionMsg()}"

proc newVsCodeTransport*(vscode: VsCode, vscodeWindow: JsObject): VsCodeTransport =
  result = VsCodeTransport(vscode: vscode)
  vscodeWindow.addEventListener(cstring"message", proc(event: CtRawEvent) =
    result.onVsCodeMessage(event))

proc newVsCodeViewModelClient*(vscode: VsCode, vscodeWindow: JsObject): ViewModelClient =
  let transport = newVsCodeTransport(vscode, vscodeWindow)
  newViewModelClient(transport)



proc newVsCodeViewModelServer*(vscode: VsCode): ViewModelServer {.exportc.}=
   var dap = Dap(vscode: vscode)
   let receive = proc(v: ViewModelServer, kind: CtEventKind, rawValue: JsObject, subscriber: Subscriber) =
      if kind == CtSubscribe:
        v.register(kind, subscriber)
      elif true: # TODO: dap check
        dap.sendCtRequest(kind, rawValue)
   newViewModelServer(receive)

type
  Dap* = ref object
    vscode: VsCode

  DapRequest* = ref object
    command*: cstring
    value*: JsObject


method toDapRequestCommand(dap: Dap, kind: CtEventKind): cstring =
  let request = DapRequest(command: $kind, value: rawValue)
  # TODO
  # CtLoadLocals => "ct/load-locals"
  # Step => "step" etc
  cstring($kind)

method sendCtRequest(dap: Dap, kind: CtEventKind, rawValue: JsObject) =
  # TODO: await and handle response? emit for it?
  discard dap.vscode.activeDebugSession.customRequest(dap.toDapRequestCommand(kind), rawValue)

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
