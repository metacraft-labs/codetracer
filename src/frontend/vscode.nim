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
  DapRequest = ref object
    command: cstring
    value: JsObject

type
  CtEventKind* = enum
    CtExample

  CtRawEvent* = ref object
    kind*: CtEventKind
    value*: JsObject


type
  VsCodeTransport* = ref object
    vscode: VsCode
    messageHandlers*: array[CtEventKind, seq[proc(raw: JsObject): void]]
    onVsCodeMesssage*: proc(t: VsCodeTransport, event: JsObject)

method emit*[T](t: Transport, event: T) =
  t.vscode.postMessage(event.toJs)

method subscribe*[T](t: Transport, eventKind: CtEventKind, callback: proc(value: T): Future[void]) {.base.} =
  # t.messageHandlers used in onVsCodeMessage : on window.addEventListener('message', (event) => t.onVsCodeMessage(event))
  # if not t.messageHandlers.hasKey(eventKind):
    # t.messageHandlers[eventKind] = @[]
  t.messageHandlers[eventKind].add(proc(raw: JsObject) = discard callback(cast[T](raw)))

method onVsCodeMessage*(t: VsCodeTransport, event: CtRawEvent) =
  for handler in t.messageHandlers[event.kind]:
    try:
      handler(event.value)
    except:
      cerror fmt"handler for {event.kind} error: {getCurrentExceptionMsg()}"

proc newVsCodeTransport(vscode: VsCode, vscodeWindow: JsObject): VsCodeTransport =
  result = VsCodeTransport(vscode: vscode)
  vscodeWindow.addEventListener(cstring"message", proc(event: CtRawEvent) =
    result.onVsCodeMessage(event))


