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
