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
    CtSetupTraceSession,
    CtLoadAsmFunction,
    CtLoadAsmFunctionResponse,
    InternalLastCompleteMove,
    InternalAddToScratchpad,
    InternalAddToScratchpadFromExpression,
    InternalStatusUpdate,
    InternalNewOperation,
    CtNotification,
    
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




