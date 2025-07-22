import std / [jsffi, jsconsole, strformat, async]
import .. / common / ct_event
import lib
import types
import communication

when not defined(ctInExtension):

  type
    DapApi* = ref object
      handlers*: array[CtEventKind, seq[proc(kind: CtEventKind, raw: JsObject)]]

  proc newDapApi() : DapApi =
    result = DapApi()

  type
    # copied from VsCodeDapMessage
    ExampleDapMessage* = ref object of JsObject
      # type for now can be also accessed as ["type"] because of JsObject
      `type`*: cstring
      event*: cstring
      command*: cstring
      body*: JsObject
     
    ExampleDap* = ref object
      # location*: Location
      stackLines*: seq[int]
      handlers*: seq[proc(message: ExampleDapMessage)]

  # Don't accept a raw JsObject, define adequate types
  proc onDapRawResponseOrEvent*(sender: JsObject, raw: JsObject) = 
    # TODO: Implement
    discard

else:
  import vscode
  # import ui / flow

  type
    DapApi* = ref object
      handlers*: array[CtEventKind, seq[proc(kind: CtEventKind, raw: JsObject)]]
      vscode*: VsCode
      context*: VsCodeContext
      editor*: JsObject
      flowFunction*: proc(editor: JsObject, value: FlowUpdate)
      completeMoveFunction*: proc(editor: JsObject, response: MoveState, dapApi: DapApi)

type
  DapRequest* = ref object
    command*: cstring
    value*: JsObject

# From CtEventKind to DAP request commands and dap events
# empty strings represent two kind of situations:
# 1. Response CtEventKinds
# 2. Non backend related events
const EVENT_KIND_TO_DAP_MAPPING: array[CtEventKind, cstring] = [
  CtUpdateTable: "ct/update-table",
  CtUpdatedTable: "ct/updated-table",
  CtUpdateTableResponse: "",
  CtSubscribe: "",
  CtLoadLocals: "ct/load-locals",
  CtLoadLocalsResponse: "",
  CtUpdatedCalltrace: "ct/updated-calltrace",
  CtLoadCalltraceSection: "ct/load-calltrace-section",
  CtCompleteMove: "ct/complete-move",
  DapStopped: "stopped",
  DapInitialized: "initialized",
  DapOutput: "output",
  CtEventLoad: "ct/event-load",
  CtUpdatedEvents: "ct/updated-events",
  CtUpdatedEventsContent: "ct/updated-events-content",
  CtLoadTerminal: "ct/load-terminal",
  CtLoadedTerminal: "ct/loaded-terminal",
  CtCollapseCalls: "ct/collapse-calls",
  CtExpandCalls: "ct/expand-calls",
  CtCalltraceJump: "ct/calltrace-jump",
  CtEventJump: "ct/event-jump",
  CtLoadHistory: "ct/load-history",
  CtUpdatedHistory: "ct/updated-history",
  CtHistoryJump: "ct/history-jump",
  CtSearchCalltrace: "ct/search-calltrace",
  CtCalltraceSearchResponse: "ct/calltrace-search-res",
  CtSourceLineJump: "ct/source-line-jump",
  CtSourceCallJump: "ct/source-call-jump",
  CtLocalStepJump: "ct/local-step-jump",
  CtTracepointToggle: "ct/tracepoint-toggle",
  CtTracepointDelete: "ct/tracepoint-delete",
  CtTraceJump: "ct/trace-jump",
  CtUpdatedTrace: "ct/updated-trace",
  CtLoadFlow: "ct/load-flow",
  CtUpdatedFlow: "ct/updated-flow",
  CtRunToEntry: "ct/run-to-entry",
  InternalLastCompleteMove: "internal/last-complete-move",
]

var DAP_TO_EVENT_KIND_MAPPING = JsAssoc[cstring, CtEventKind]{}

for kind, command in EVENT_KIND_TO_DAP_MAPPING:
  if command != "":
    DAP_TO_EVENT_KIND_MAPPING[command] = kind

func toCtDapResponseEventKind*(kind: CtEventKind): CtEventKind =
  # TODO: based on $kind? or mapping?
  case kind:
  of CtLoadLocals: CtLoadLocalsResponse
  else: raise newException(ValueError, fmt"no response ct event kind for {kind} defined")


func toDapCommandOrEvent(kind: CtEventKind): cstring =
  if EVENT_KIND_TO_DAP_MAPPING[kind] != "":
    EVENT_KIND_TO_DAP_MAPPING[kind]
  else:
    raise newException(ValueError, fmt"not mapped to request command yet: {kind}")


func commandToCtResponseEventKind(command: cstring): CtEventKind =
  # based on parseEnum[CtEventKind](command) and toCtDapResponseEventKind?
  # or some common mapping?
  case $command:
  of "ct/load-locals": CtLoadLocalsResponse
  else: raise newException(
    ValueError, 
    "no ct event kind response for command: \"" & $command & "\" defined")


proc dapEventToCtEventKind(event: cstring): CtEventKind =
  if DAP_TO_EVENT_KIND_MAPPING.hasKey(event):
    DAP_TO_EVENT_KIND_MAPPING[event]
  else:
    raise newException(
      ValueError,
      "no ct event kind for this string: \"" & $event & "\" defined"
    )

### DapApi procedures:

proc on*[T](dap: DapApi, kind: CtEventKind, handler: proc(kind: CtEventKind, value: T)) =
  dap.handlers[kind].add(proc(kind: CtEventKind, rawValue: JsObject) =
    handler(kind, rawValue.to(T)))

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
  import errors

  # TODO: Send this to the index process using IPC
  proc asyncSendCtRequest(dap: DapApi, kind: CtEventKind, rawValue: JsObject) {.async.} =
    discard
    #dap.exampleDap.sendRequest(toDapCommandOrEvent(kind), rawValue)
    # raise newException(NotImplementedError, "asyncSendCtRequest not implemented")
<<<<<<< HEAD

  proc newExampleDapApi*: DapApi =
    let exampleDap = ExampleDap(
      location: Location(
        path: cstring"/tmp/rust_struct_test.rs",
        line: 1,
        key: cstring"0",
        functionName: cstring"<top level>",
        highLevelFunctionName: cstring"<top level>",
      ),
      stackLines: @[],
      handlers: @[]
    )
    exampleDap.location.highLevelPath = exampleDap.location.path

    result = DapApi(exampleDap: exampleDap) 
    result.exampleDap.on(proc(message: ExampleDapMessage) =
      if message.`type` == cstring"response":
        result.receiveResponse(message.command, message.body)
      elif message.`type` == cstring"event":
        result.receiveEvent(message.event, message.body))
=======
>>>>>>> cabf6a8 (feat(dap): start integrating dap client into index and ui)
  
else:
  import .. / .. / libs / karax / karax / kdom
  proc sendCtRequest*(dap: DapApi, kind: CtEventKind, rawValue: JsObject)

  proc asyncSendCtRequest(dap: DapApi, kind: CtEventKind, rawValue: JsObject) {.async.} =
    console.log cstring"-> dap request: ", toDapCommandOrEvent(kind), rawValue
    discard dap.vscode.debug.activeDebugSession.customRequest(toDapCommandOrEvent(kind), rawValue)

  proc ctSourceLineJump*(dap: DapApi, line: int, path: cstring, behaviour: JumpBehaviour) {.exportc.} =
    let target = SourceLineJumpTarget(
      path: path,
      line: line,
      behaviour: behaviour,
    )
    dap.sendCtRequest(CtSourceLineJump, target.toJs)

  proc newDapVsCodeApi*(vscode: VsCode, context: VsCodeContext): DapApi {.exportc.} =
    result = DapApi(vscode: vscode, context: context)
    proc onDidSendMessage(message: VsCodeDapMessage) =
      console.log cstring"<- dap message:", message.`type`, message.command, message.event, message
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
      )
    )

  type
    VsCodeEditor* = ref object
      editor*: JsObject
      flow*: FlowComponent

  var vsCodeEditor* = VsCodeEditor()

  proc setupEditorApi*(dapApi: DapApi, vscode: VsCode, context: VsCodeContext, editor: JsObject) {.exportc.} =
    dapApi.editor = editor
    vsCodeEditor.editor = editor
    context.subscriptions.push(
      vscode.window.toJs.onDidChangeActiveTextEditor(proc(editor: JsObject) =
        if not editor.isNil:
          let uri = editor["document"]["uri"]
          dapApi.editor = editor
          vsCodeEditor.editor = editor
      )
    )

proc sendCtRequest*(dap: DapApi, kind: CtEventKind, rawValue: JsObject) =
  discard dap.asyncSendCtRequest(kind, rawValue)
<<<<<<< HEAD
=======


>>>>>>> cabf6a8 (feat(dap): start integrating dap client into index and ui)
