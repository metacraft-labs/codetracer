type
  CtEventKind* = enum
    CtExample,
    CtSubscribe,
    CtLoadLocals,
    CtLoadLocalsResponse,
    DapStopped,
    DapInitialized,
    DapOutput,
    
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

    


