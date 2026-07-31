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
      pendingResponses*: JsAssoc[cstring, proc(body: JsObject)]
        ## M49 — in-flight `asyncSendCtRequest` continuations, keyed by
        ## the request's wire `seq`.
        ##
        ## Electron's DAP transport is one-way at the IPC layer: the
        ## renderer writes a request frame and the Backend Manager
        ## broadcasts the response back on a *separate* channel
        ## (`CODETRACER::dap-receive-response`, see
        ## `index/ipc_subsystems/dap.nim::handleFrame`). Before M49 the
        ## future `asyncSendCtRequest` returned was therefore resolved
        ## with an empty `js{}` the instant the frame was written — it
        ## announced a response it had never seen. Every ViewModel that
        ## read a resolved body got `{}`, which is why the Event Log's
        ## correlation-marker rows never rendered in the product even
        ## though `ct/event-load` answers with a populated `markers`
        ## array (pinned by `m25b_event_log_test.rs`): the VM's
        ## `applyMarkerRowsResponse` saw no `markers` key and returned.
        ##
        ## The Backend Manager already tags every response with the
        ## originating `request_seq`, so the correlation needs no new
        ## wire field — only a place to park the continuation until it
        ## arrives.

  proc newDapApi(ipc: JsObject) : DapApi =
    result = DapApi(
      seq: 0,
      sessionId: 0,
      pendingResponses: JsAssoc[cstring, proc(body: JsObject)]{}
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
  # Multi-process sessions (M29 §5.2 / M42 §14.8). The same command
  # string names both the request the frontend may issue and the
  # session-load event the backend dispatches unsolicited, so a single
  # mapping entry serves `asyncSendCtRequest` and `receiveEvent`.
  CtListProcesses: "ct/listProcesses",
  CtListProcessesResponse: "",
  # M25b §5.3 — Event Log boundary-chip counterpart lookup.
  CtPairIndexLookup: "ct/pairIndexLookup",
  CtPairIndexLookupResponse: "",
  CtGotoTicks: "ct/goto-ticks",
]

# ---------------------------------------------------------------------------
# Multi-process request routing (M42 §14.8).
#
# `db-backend/src/dap_server.rs::handle_request_via_session` selects
# which recording of a multi-trace session serves a request purely from
# the request's `threadId` argument (composed as `slot << 24 | inner`,
# see `session_handler.rs::compose_thread_id`); a request without one
# falls back to slot 0, the first `[[trace]]` in `session.toml`.
#
# The renderer therefore has exactly one lever for "which process am I
# debugging": the `threadId` it stamps on outgoing requests. Rather
# than thread an id through every call site (the legacy step path in
# `renderer.nim` hardcodes `DapStepArguments(threadId: 1)`), we stamp it
# once here, at the single choke point every DAP request passes
# through.
#
# `0` means "not a multi-process session" and leaves every request
# byte-identical to the pre-M42 wire, so single-recording sessions —
# i.e. every existing test — are unaffected. The process tree installs
# a real id via `setActiveSessionThreadId` only once a session with
# more than one recording reports its process list.
# ---------------------------------------------------------------------------

var activeSessionThreadId: int = 0

proc isMissingArgs(value: JsObject): bool {.
  importjs: "((function(v) { return v === undefined || v === null; })(#))".}
  ## `null`/`undefined` probe for a request's `arguments` slot. Nim's
  ## `isNil` covers `null` but not `undefined`, and both reach here from
  ## call sites that pass a bare `js{}` or omit the argument entirely.

proc setActiveSessionThreadId*(threadId: int) =
  ## Route subsequent DAP requests to the recording owning `threadId`.
  ## Pass `0` to restore the default (slot 0) routing.
  activeSessionThreadId = threadId

proc getActiveSessionThreadId*(): int =
  ## Current session-wide routing thread id; `0` when unset.
  activeSessionThreadId

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
  # Multi-process sessions (M42 §14.8)
  of CtListProcesses: CtListProcessesResponse
  of CtPairIndexLookup: CtPairIndexLookupResponse
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
  # Multi-process sessions (M42 §14.8)
  of "ct/listProcesses": CtListProcessesResponse
  of "ct/pairIndexLookup": CtPairIndexLookupResponse
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

  proc setResponseTimeout(cb: proc(); delayMs: int) {.importjs: "setTimeout(#, #)".}

  func jsHasOwn(obj: JsObject; key: cstring): bool {.
    importjs: "Object.prototype.hasOwnProperty.call(# || {}, #)", noSideEffect.}
    ## Presence probe that tolerates `null`/`undefined` receivers — a
    ## response frame can reach us without a `body`, and calling
    ## `.hasOwnProperty` on `undefined` throws.

  proc jsDeleteKey[A, B](a: JsAssoc[A, B]; key: A) {.importjs: "delete #[#]".}

  proc ensurePendingResponses(dap: DapApi) =
    ## Lazily create the pending-response table.
    ##
    ## `newDapApi` is not the only way a `DapApi` comes into existence:
    ## `types.nim` and `ui/session_switch.nim` build one from an object
    ## literal per replay session, so a field initialised only in the
    ## constructor is nil on every session the user opens after the
    ## first. Initialising on first use keeps the invariant with the
    ## code that depends on it instead of spread across every
    ## construction site.
    if dap.pendingResponses.isNil:
      dap.pendingResponses = JsAssoc[cstring, proc(body: JsObject)]{}

  const DAP_RESPONSE_TIMEOUT_MS* = 30_000
    ## M49 — how long a request waits for its response before its
    ## continuation is released with an empty body.
    ##
    ## The timeout is a liveness guard, not a policy: a handler that
    ## answers with events only (or a request the backend drops on the
    ## floor) must not leave a ViewModel's loading state pinned
    ## forever. Releasing with `js{}` reproduces exactly the value
    ## every caller received before M49, so the worst case after this
    ## change is the pre-M49 behaviour arriving late rather than a new
    ## failure mode.

  proc resolvePendingDapResponse*(dap: DapApi, raw: JsObject) =
    ## M49 — hand a DAP response frame to the `asyncSendCtRequest`
    ## continuation that is waiting for it, if any.
    ##
    ## Keyed on the DAP wire field `request_seq`, which
    ## `index/ipc_subsystems/dap.nim` forwards untouched from the
    ## Backend Manager. A response with no `request_seq`, or one whose
    ## sender has already timed out, is simply not claimed — the
    ## legacy `receiveResponse` fan-out still delivers it to every
    ## `dap.on(...)` subscriber either way, so this is purely
    ## additive.
    if dap.isNil or dap.pendingResponses.isNil or raw.isNil:
      return
    if not jsHasOwn(raw, cstring"request_seq"):
      return
    let key = cstring($(raw["request_seq"].to(int)))
    if not dap.pendingResponses.hasKey(key):
      return
    let pending = dap.pendingResponses[key]
    dap.pendingResponses.jsDeleteKey(key)
    let body = if jsHasOwn(raw, cstring"body"): raw["body"] else: js{}
    pending(body)

  proc asyncSendCtRequest*(dap: DapApi,
                         kind: CtEventKind,
                         rawValue: JsObject): Future[JsObject] =

    # M42 §14.8 — stamp the active recording's composed thread id so the
    # session router in `dap_server.rs` dispatches to the process the
    # user selected in the process tree. No-op (and no allocation) for
    # single-recording sessions, where `activeSessionThreadId` is 0.
    var args = rawValue
    if activeSessionThreadId != 0:
      if isMissingArgs(args):
        args = JsObject{}
      args["threadId"] = activeSessionThreadId

    let requestSeq = dap.seq
    let packet = JsObject{
      seq:        requestSeq,
      `type`:     cstring"request",
      command:    toDapCommandOrEvent(kind),
      arguments:  args
    }

    dap.seq += 1

    # M8: Attach the session id so the main process can route
    # the request to the correct backend session in the future.
    packet["sessionId"] = dap.sessionId

    # M49 — park the continuation under this request's `seq` *before*
    # writing the frame. The IPC round-trip cannot complete inside this
    # synchronous block, but registering first keeps the ordering
    # obviously correct rather than merely true in practice.
    let key = cstring($requestSeq)
    let api = dap
    api.ensurePendingResponses()
    result = newPromise proc(resolve: proc(response: JsObject)) =
      var settled = false
      api.pendingResponses[key] = proc(body: JsObject) =
        if settled:
          return
        settled = true
        resolve(body)
      setResponseTimeout(proc() =
        if settled:
          return
        settled = true
        api.pendingResponses.jsDeleteKey(key)
        resolve(js{}), DAP_RESPONSE_TIMEOUT_MS)
      api.ipc.send("CODETRACER::dap-raw-message", packet)


else:
  proc sendCtRequest*(dap: DapApi, kind: CtEventKind, rawValue: JsObject)

  proc asyncSendCtRequest*(dap: DapApi, kind: CtEventKind, rawValue: JsObject): Future[JsObject] {.async.} =
    console.log cstring"-> dap request: ", toDapCommandOrEvent(kind), rawValue
    return await dap.vscode.debug.activeDebugSession.customRequest(toDapCommandOrEvent(kind), rawValue)

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
