import std / [jsffi, jsconsole, strformat, async]
import .. / common / ct_event
import lib
import types
import communication

when not defined(ctInExtension):

  type
    # copied from VsCodeDapMessage
    ExampleDapMessage* = ref object of JsObject
      # type for now can be also accessed as ["type"] because of JsObject
      `type`*: cstring
      event*: cstring
      command*: cstring
      body*: JsObject
     
    ExampleDap* = ref object
      location*: Location
      stackLines*: seq[int]
      handlers*: seq[proc(message: ExampleDapMessage)]

  const START_CALL_LINE = 7

  proc receive(dap: ExampleDap, message: ExampleDapMessage) =
    console.log cstring"example dap: <- ", message
    for handler in dap.handlers:
      try:
        handler(message)
      except:
        console.log cstring"example dap receive error: ", getCurrentExceptionMsg().cstring

  proc receiveOnMove*(dap: ExampleDap, newCall: bool = false) =
    dap.receive(ExampleDapMessage(`type`: "event", event: "stopped", body: DapStoppedEvent(threadId: 1).toJs))
    dap.receive(
      ExampleDapMessage(
        `type`: "event",
        event: "ct/complete-move",
        body: MoveState(
          location: dap.location,
          cLocation: dap.location,
          main: false,
          status: cstring"stopped",
          resetFlow: newCall,
          frameInfo: FrameInfo(
            offset: 0,
            hasSelected: false
          )
        ).toJs
      )
    )

  proc sendRequest*(dap: ExampleDap, command: cstring, value: JsObject) =
    console.log("example dap: -> ", command, value)
    case $command:
    of "step":
      dap.location.key = cstring($(dap.location.key.parseJsInt + 1))
      dap.location.rrTicks += 1
      dap.stackLines.add(dap.location.line)
      dap.location.line = START_CALL_LINE
      dap.location.highLevelLine = dap.location.line
      dap.receiveOnMove()
    of "next":
      dap.location.rrTicks += 1
      dap.location.line += 1
      dap.location.highLevelLine = dap.location.line
      dap.receiveOnMove()
    of "step-out":
      dap.location.key = cstring($(dap.location.key.parseJsInt - 1))
      dap.location.rrTicks += 1
      dap.location.line = dap.stackLines.pop() + 1
      dap.location.highLevelLine = dap.location.line
      dap.receiveOnMove()
    of "continue":
      # finish? TODO?
      discard
    of "ct/load-locals":
      dap.receive(
        ExampleDapMessage(
          `type`: "response",
          command: "ct/load-locals",
          body: CtLoadLocalsResponseBody(
            locals: @[
              Variable(expression: "a", value: Value(kind: Int, i: "0", typ: Type(kind: Int, langType: cstring"int")))
            ]
          ).toJs
        )
      )
    of "ct/update-table":
      dap.receive(ExampleDapMessage(`type`: "event", event: "ct/updated-table", body: CtUpdatedTableResponseBody(
        tableUpdate: TableUpdate(
          data: TableData(
            draw: 0,
            recordsTotal: 0,
            recordsFiltered: 0,
            data: @[
              TableRow(
                directLocationRRTicks: 0,
                rrEventId: 0,
                fullPath: dap.location.path,
                lowLevelLocation: dap.location.lowLevelPath,
                kind: EventLogKind.Write,
                content: "-".cstring,
                metadata: "-".cstring,
                base64Encoded: true,
                stdout: true,
              )
            ]
          ),
          isTrace: false,
          traceId: 0,
        )
      ).toJs))
    of "ct/load-calltrace-section":
      dap.receive(ExampleDapMessage(`type`: "event", event: "ct/updated-calltrace", body: CtUpdatedCalltraceResponseBody(
        callLines: @[
          CallLine(
            content: CallLineContent(
              kind: CallLineContentKind.Call,
              count: 1,
              call: Call(key: dap.location.key, location: dap.location, rawName: dap.location.functionName)
            )
          )
        ]
      ).toJs))
    else:
      discard

  proc on*(dap: ExampleDap, handler: proc(message: ExampleDapMessage)) =
    dap.handlers.add(handler)
    
  type
    DapApi* = ref object
      handlers*: array[CtEventKind, seq[proc(kind: CtEventKind, raw: JsObject)]]
      exampleDap*: ExampleDap    
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

  proc asyncSendCtRequest(dap: DapApi, kind: CtEventKind, rawValue: JsObject) {.async.} =
    dap.exampleDap.sendRequest(toDapCommandOrEvent(kind), rawValue)
    # raise newException(NotImplementedError, "asyncSendCtRequest not implemented")

  proc newExampleDapApi*: DapApi =
    let exampleDap = ExampleDap(
      location: Location(
        path: cstring"/home/alexander92/wazero/test_code/rust_struct_test.rs",
        line: 1,
        key: cstring"0",
        functionName: cstring"<top level>",
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
  
else:
  import .. / .. / libs / karax / karax / kdom
  proc sendCtRequest*(dap: DapApi, kind: CtEventKind, rawValue: JsObject)

  proc asyncSendCtRequest(dap: DapApi, kind: CtEventKind, rawValue: JsObject) {.async.} =
    console.log cstring"-> dap request: ", toDapCommandOrEvent(kind), rawValue
    discard dap.vscode.debug.activeDebugSession.customRequest(toDapCommandOrEvent(kind), rawValue)

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
      ))

  type
    VsCodeEditor* = ref object
      editor*: JsObject
      flow*: FlowComponent

  var vsCodeEditor = VsCodeEditor()

  proc onUpdatedFlow*(editor: JsObject, update: FlowUpdate) =
    discard cast[FlowComponent](vsCodeEditor.flow).onUpdatedFlow(update)

  proc completeMove*(editor: JsObject, response: MoveState, dapApi: DapApi) =
    vsCodeEditor.flow = FlowComponent(
      id: 0,
      flow: nil,
      # tab: self.tabInfo,
      location: response.location,
      multilineZones: JsAssoc[int, MultilineZone]{},
      flowDom: JsAssoc[int, Node]{},
      shouldRecalcFlow: false,
      flowLoops: JsAssoc[int, FlowLoop]{},
      flowLines: JsAssoc[int, FlowLine]{},
      activeStep: FlowStep(rrTicks: -1),
      selectedLine: -1,
      selectedLineInGroup: -1,
      selectedStepCount: -1,
      # multilineFlowLines: multilineFlowLines(),
      multilineValuesDoms: JsAssoc[int, JsAssoc[cstring, Node]]{},
      loopLineSteps: JsAssoc[int, int]{},
      inlineDecorations: JsAssoc[int, InlineDecorations]{},
      # editorUI: self,
      # scratchpadUI: if self.data.ui.componentMapping[Content.Scratchpad].len > 0: self.data.scratchpadComponent(0) else: nil,
      # editor: self.service,
      # service: self.data.services.flow,
      # data: self.data,
      lineGroups: JsAssoc[int, Group]{},
      # status: FlowUpdateState(kind: FlowWaitingForStart),
      statusWidget: nil,
      sliderWidgets: JsAssoc[int, js]{},
      lineWidgets: JsAssoc[int, js]{},
      multilineWidgets: JsAssoc[int, JsAssoc[cstring, js]]{},
      stepNodes: JsAssoc[int, Node]{},
      loopStates: JsAssoc[int, LoopState]{},
      viewZones: JsAssoc[int, int]{},
      loopViewZones: JsAssoc[int, int]{},
      loopColumnMinWidth: 15,
      shrinkedLoopColumnMinWidth: 8,
      pixelsPerSymbol: 8,
      distanceBetweenValues: 10,
      distanceToSource: 50,
      inlineValueWidth: 80,
      bufferMaxOffsetInPx: 300,
      maxWidth: 0,
      modalValueComponent: JsAssoc[cstring, ValueComponent]{},
      valueMode: BeforeValueMode
    )

    dapApi.sendCtRequest(CtLoadFlow, response.location.toJs)

  proc setupEditorApi(dapApi: DapApi, vscode: VsCode, context: VsCodeContext, editor: JsObject) {.exportc.} =
    dapApi.flowFunction = onUpdatedFlow
    dapApi.completeMoveFunction = completeMove
    vsCodeEditor.editor = editor
    context.subscriptions.push(
      vscode.window.toJs.onDidChangeActiveTextEditor(proc(editor: JsObject) =
        if not editor.isNil:
          let uri = editor["document"]["uri"]
          dapApi.editor = editor
      )
    )

proc sendCtRequest*(dap: DapApi, kind: CtEventKind, rawValue: JsObject) =
  discard dap.asyncSendCtRequest(kind, rawValue)
