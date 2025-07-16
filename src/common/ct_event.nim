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
    DapOutput,
    DapStepIn,
    DapStepOut,
    DapNext,
    DapContinue,
    DapStepBack,
    DapReverseContinue,
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

    


