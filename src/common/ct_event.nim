type
  CtEventKind* = enum
    CtUpdateTable,
    CtUpdatedTable,
    CtUpdateTableResponse
    CtSubscribe,
    CtLoadLocals,
    CtLoadLocalsResponse,
    CtUpdatedCalltrace,
    CtLoadCalltraceSection,
    CtCompleteMove,
    DapStopped,
    DapInitialized,
    DapInitialize,
    DapInitializeResponse,
    DapConfigurationDone,
    DapConfigurationDoneResponse,
    DapLaunch,
    DapLaunchResponse,
    DapOutput,
    DapStepIn,
    DapStepInResponse,
    DapStepOut,
    DapStepOutResponse,
    DapNext,
    DapNextResponse,
    DapContinue,
    DapContinueResponse,
    DapStepBack,
    DapStepBackResponse,
    DapReverseContinue,
    DapReverseContinueResponse,
    DapSetBreakpoints,
    CtReverseStepIn,
    CtReverseStepInResponse,
    CtReverseStepOut,
    CtReverseStepOutResponse,
    CtEventLoad,
    CtUpdatedEvents,
    CtUpdatedEventsContent,
    CtLoadTerminal,
    CtLoadedTerminal,
    CtCollapseCalls,
    CtExpandCalls,
    CtCalltraceJump,
    CtEventJump,
    CtLoadHistory,
    CtUpdatedHistory,
    CtHistoryJump,
    CtSearchCalltrace,
    CtCalltraceSearchResponse,
    CtSourceLineJump,
    CtSourceCallJump,
    CtLocalStepJump,
    CtTracepointToggle,
    CtTracepointDelete,
    CtTraceJump,
    CtUpdatedTrace,
    CtLoadFlow,
    CtUpdatedFlow,
    CtRunToEntry,
    CtRunTracepoints,
    CtRunTraceSession,
    CtSetupTraceSession,
    CtLoadAsmFunction,
    CtLoadAsmFunctionResponse,
    CtUpdateExpansion,
    CtUpdateExpansionResponse,
    InternalLastCompleteMove,
    InternalAddToScratchpad,
    InternalAddToScratchpadFromExpression,
    InternalStatusUpdate,
    InternalNewOperation,
    InternalTraceMapUpdate,
    CtNotification,
    TracepointLocals,
    CtTracepointResults,
    CtFlowJump,
    CtTimelineSeek,
    CtShellEval,
    CtMcrGetRecordingHead,
    CtMcrRestoreAt,
    CtLiveRestoreAt,
    CtMcrLiveStep,
    CtSeekToGeid,
    # Value Origin Tracking (M2). See
    # codetracer-specs/GUI/Debugging-Features/Value-Origin-Tracking.md §5.2.
    CtUpdatedOriginChain,
    # Value Origin Tracking (M4) — frontend-initiated requests
    # (spec §5.3 / §5.3.2). Listed here so the Karax / IsoNim event
    # router can dispatch them through the same DapApi pipeline as
    # every other ct/* command.
    CtOriginChain,
    CtOriginChainResponse,
    CtOriginSummary,
    CtOriginSummaryResponse,
    # Column-Aware Replay Navigation (M3) — frontend-initiated requests
    # that toggle the formatted-view step-over runner.  See
    # codetracer-specs/Planned-Features/Column-Aware-Navigation.status.org §M3.
    CtSetActiveSourceView,
    CtSetActiveSourceViewResponse,
    CtInstallSourceView,
    CtInstallSourceViewResponse,
    # Multi-process sessions (M29 §5.2 / M42 §14.8). `ct/listProcesses`
    # is unusual in that the backend speaks it in BOTH directions: as a
    # request the frontend may issue, and as an unsolicited event
    # dispatched once per session load
    # (`db-backend/src/dap_server.rs::dispatch_session_load_event`).
    # Both carry the same body shape, so both route to this kind and
    # `SessionViewModel.applyListProcessesResponse` decodes either.
    CtListProcesses,
    CtListProcessesResponse,
    # M25b §5.3 / M49 — Event Log correlation-marker counterpart lookup.
    # The boundary chip's jump resolves a marker's counterpart through
    # this request; without a kind here `dapCommandToEventKind` raises
    # and the request is never written to the wire, so the click
    # resolved nothing and rotated nothing.
    CtPairIndexLookup,
    CtPairIndexLookupResponse,
    # M25b §5.3 / M49 — seek the active recording's timeline to a
    # marker firing's step. `EventLogVM.jumpToCounterpart` has always
    # named this command; it had no kind, so the send raised and the
    # jump landed wherever the process switch happened to leave the
    # cursor instead of on the correlated step.
    CtGotoTicks,

when defined(js):
  import std / jsffi

  type
    CtRawEvent* = ref object
      kind*: CtEventKind
      value*: JsObject

type
  CtEvent*[T] = ref object
    kind*: CtEventKind
    value: T
