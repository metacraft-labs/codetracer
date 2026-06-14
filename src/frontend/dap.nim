import
  std/[ jsffi, jsconsole, strformat, asyncjs ],
  ../common/ct_event,
  lib/jslib,
  types,
  communication

when not defined(ctInExtension):

  type
    DapApi* = ref object
      handlers*: array[CtEventKind, seq[proc(kind: CtEventKind, raw: JsObject)]]
      ipc*: Jsobject
      seq*: int
      sessionId*: int  ## M8: id of the owning ReplaySession, attached to outgoing DAP requests.

  proc newDapApi(ipc: JsObject) : DapApi =
    result = DapApi(
      seq: 0,
      sessionId: 0
    )

else:
  import vscode
  # import ui / flow

  type
    DapApi* = ref object
      handlers*: array[CtEventKind, seq[proc(kind: CtEventKind, raw: JsObject)]]
      vscode*: VsCode
      context*: VsCodeContext
      editor*: JsObject
      sessionId*: int  ## M8: id of the owning ReplaySession (unused in extension mode for now).
      # flowFunction*: proc(editor: JsObject)
      # completeMoveFunction*: proc(editor: JsObject, response: MoveState, dapApi: DapApi)

type
  DapRequest* = ref object
    command*: cstring
    value*: JsObject

# From CtEventKind to DAP request commands and dap events
# empty strings represent two kind of situations:
# 1. Response CtEventKinds
# 2. Non backend related events
const EVENT_KIND_TO_DAP_MAPPING*: array[CtEventKind, cstring] = [
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
  DapInitialize: "initialize",
  DapInitializeResponse: "",
  DapConfigurationDone: "configurationDone",
  DapConfigurationDoneResponse: "",
  DapLaunch: "launch",
  DapLaunchResponse: "",
  DapOutput: "output",
  DapStepIn: "stepIn",
  DapStepInResponse: "",
  DapStepOut: "stepOut",
  DapStepOutResponse: "",
  DapNext: "next",
  DapNextResponse: "",
  DapContinue: "continue",
  DapContinueResponse: "",
  DapStepBack: "stepBack",
  DapStepBackResponse: "",
  DapReverseContinue: "reverseContinue",
  DapReverseContinueResponse: "",
  DapSetBreakpoints: "setBreakpoints",
  CtReverseStepIn: "ct/reverseStepIn",
  CtReverseStepInResponse: "",
  CtReverseStepOut: "ct/reverseStepOut",
  CtReverseStepOutResponse: "",
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
  CtRunTracepoints: "ct/run-tracepoints",
  CtRunTraceSession: "ct/run-trace-session",
  CtSetupTraceSession: "ct/setup-trace-session",
  CtLoadAsmFunction: "ct/load-asm-function",
  CtLoadAsmFunctionResponse: "",
  CtUpdateExpansion: "ct/update-expansion",
  CtUpdateExpansionResponse: "",
  InternalLastCompleteMove: "internal/last-complete-move",
  InternalAddToScratchpad: "",
  InternalAddToScratchpadFromExpression: "",
  InternalStatusUpdate: "",
  InternalNewOperation: "",
  InternalTraceMapUpdate: "",
  CtNotification: "ct/notification",
  TracepointLocals: "tracepoint-locals",
  CtTracepointResults: "ct/tracepoint-results",
  CtFlowJump: "ct/flow-jump",
  CtTimelineSeek: "ct/timeline-seek",
  CtShellEval: "ct/shell-eval",
  CtMcrGetRecordingHead: "ct/mcr-get-recording-head",
  CtMcrRestoreAt: "ct/mcr-restore-at",
  CtLiveRestoreAt: "ct/live-restore-at",
  CtMcrLiveStep: "ct/mcr-live-step",
  CtSeekToGeid: "ct/seek-to-geid",
  # Value Origin Tracking (M2) — the backend emits an event alongside the
  # `ct/originChain` response so frontends can react to lazy continuations
  # without re-issuing the request (spec §5.2).
  CtUpdatedOriginChain: "ct/updated-origin-chain",
  # Value Origin Tracking (M4) — frontend-initiated requests
  # (spec §5.3 + §5.3.2). The response CtEventKinds use empty strings
  # because the dispatch table only maps the request side; responses
  # are routed via `toCtDapResponseEventKind` below.
  CtOriginChain: "ct/originChain",
  CtOriginChainResponse: "",
  CtOriginSummary: "ct/originSummary",
  CtOriginSummaryResponse: "",
  # Column-Aware Replay Navigation (M3) — frontend-initiated requests.
  CtSetActiveSourceView: "ct/set-active-source-view",
  CtSetActiveSourceViewResponse: "",
  CtInstallSourceView: "ct/install-source-view",
  CtInstallSourceViewResponse: "",
]

var DAP_TO_EVENT_KIND_MAPPING = JsAssoc[cstring, CtEventKind]{}

for kind, command in EVENT_KIND_TO_DAP_MAPPING:
  if command != "":
    DAP_TO_EVENT_KIND_MAPPING[command] = kind

proc dapCommandToEventKind*(command: cstring): CtEventKind =
  ## Convert a DAP command string (e.g. "ct/load-locals") to its
  ## corresponding CtEventKind.  Used by the RealBackendService adapter
  ## to translate BackendService string commands into DapApi calls.
  ## Raises ValueError if the command is not in the mapping.
  if DAP_TO_EVENT_KIND_MAPPING.hasKey(command):
    DAP_TO_EVENT_KIND_MAPPING[command]
  else:
    raise newException(
      ValueError,
      "no ct event kind for command: \"" & $command & "\" defined"
    )

func toCtDapResponseEventKind*(kind: CtEventKind): CtEventKind =
  # TODO: based on $kind? or mapping?
  case kind:
  of CtLoadLocals: CtLoadLocalsResponse
  of DapInitialize: DapInitializeResponse
  of DapLaunch: DapLaunchResponse
  of DapStepIn: DapStepInResponse
  of DapStepOut: DapStepOutResponse
  of DapNext: DapNextResponse
  of DapContinue: DapContinueResponse
  of DapStepBack: DapStepBackResponse
  of DapReverseContinue: DapReverseContinueResponse
  of CtReverseStepIn: CtReverseStepInResponse
  of CtReverseStepOut: CtReverseStepOutResponse
  of CtMcrGetRecordingHead: CtMcrGetRecordingHead
  of CtMcrRestoreAt: CtMcrRestoreAt
  of CtLiveRestoreAt: CtLiveRestoreAt
  of CtMcrLiveStep: CtMcrLiveStep
  of CtSeekToGeid: CtSeekToGeid
  # Value Origin Tracking (M4)
  of CtOriginChain: CtOriginChainResponse
  of CtOriginSummary: CtOriginSummaryResponse
  # Column-Aware Replay Navigation (M3)
  of CtSetActiveSourceView: CtSetActiveSourceViewResponse
  of CtInstallSourceView: CtInstallSourceViewResponse
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
  of "initialize": DapInitializeResponse
  of "launch": DapLaunchResponse
  of "configurationDone": DapConfigurationDoneResponse
  of "stepIn": DapStepInResponse
  of "stepOut": DapStepOutResponse
  of "next": DapNextResponse
  of "continue": DapContinueResponse
  of "stepBack": DapStepBackResponse
  of "reverseContinue": DapReverseContinueResponse
  of "ct/reverseStepIn": CtReverseStepInResponse
  of "ct/reverseStepOut": CtReverseStepOutResponse
  of "ct/load-asm-function": CtLoadAsmFunctionResponse
  of "ct/update-expansion": CtUpdateExpansionResponse
  of "ct/mcr-get-recording-head": CtMcrGetRecordingHead
  of "ct/mcr-restore-at": CtMcrRestoreAt
  of "ct/live-restore-at": CtLiveRestoreAt
  of "ct/mcr-live-step": CtMcrLiveStep
  of "ct/seek-to-geid": CtSeekToGeid
  # Value Origin Tracking (M4)
  of "ct/originChain": CtOriginChainResponse
  of "ct/originSummary": CtOriginSummaryResponse
  # Column-Aware Replay Navigation (M3)
  of "ct/set-active-source-view": CtSetActiveSourceViewResponse
  of "ct/install-source-view": CtInstallSourceViewResponse
  else: raise newException(
    ValueError,
    "no ct event kind response for command: \"" & $command & "\" defined")


proc dapEventToCtEventKind*(event: cstring): CtEventKind =
  console.log cstring"CONVERTING EVENT: ", event
  if DAP_TO_EVENT_KIND_MAPPING.hasKey(event):
    DAP_TO_EVENT_KIND_MAPPING[event]
  else:
    raise newException(
      ValueError,
      "no ct event kind for this string: \"" & $event & "\" defined"
    )

### DapApi procedures:

# Read/bump accessors for the `seq` field. The field is named after
# the DAP wire-format key (`seq`), which collides with Nim's `seq[T]`
# typedesc inside the `js{}` literal macro's field-access probe — see
# the call site in `renderer.nim`. dap.nim's own import set does not
# trip the lookup ambiguity, so we expose the access through a typed
# accessor here and call it from the noisy module. Only the
# non-extension `DapApi` carries this field; in `-d:ctInExtension`
# builds DAP dispatch goes through the VSCode runtime.
when not defined(ctInExtension):
  proc readSeq*(dap: DapApi): int {.inline.} = dap.seq
  proc bumpSeq*(dap: DapApi) {.inline.} = dap.seq += 1

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

  proc stringify(o: JsObject): cstring {.importjs: "JSON.stringify(#)".}

  proc asyncSendCtRequest(dap: DapApi,
                        kind: CtEventKind,
                        rawValue: JsObject) {.async.} =

    let packet = JsObject{
      seq:        dap.seq,
      `type`:     cstring"request",
      command:    toDapCommandOrEvent(kind),
      arguments:  rawValue
    }

    dap.seq += 1

    # M8: Attach the session id so the main process can route
    # the request to the correct backend session in the future.
    packet["sessionId"] = dap.sessionId

    dap.ipc.send("CODETRACER::dap-raw-message", packet)


else:
  proc sendCtRequest*(dap: DapApi, kind: CtEventKind, rawValue: JsObject)

  proc asyncSendCtRequest(dap: DapApi, kind: CtEventKind, rawValue: JsObject) {.async.} =
    console.log cstring"-> dap request: ", toDapCommandOrEvent(kind), rawValue
    discard dap.vscode.debug.activeDebugSession.customRequest(toDapCommandOrEvent(kind), rawValue)

  proc newDapVsCodeApi*(vscode: VsCode, context: VsCodeContext): DapApi {.exportc.} =
    let dap = DapApi(vscode: vscode, context: context)
    proc onDidSendMessage(message: VsCodeDapMessage) =
      console.log cstring"<- dap message:", message.`type`, message.command, message.event, message
      if message.`type` == cstring"event":
        dap.receiveEvent(message.event, message.body)
      elif message.`type` == cstring"response":
        try:
          dap.receiveResponse(message.command, message.body)
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
    dap

  type
    VsCodeEditor* = ref object
      editor*: JsObject
      # flow*: FlowComponent

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
  console.log "Sending ct request: ", kind, " with val ", rawValue
  discard dap.asyncSendCtRequest(kind, rawValue)
