type
  BreakpointKind* = enum ## BreakpointKind enum, either a path line or a function
    BreakpointPathLine,
    BreakpointFunction

  RRGDBStopSignal* = enum ## stop signal for RRGDB process
    NoStopSignal,
    SigsegvStopSignal,
    SigkillStopSignal,
    SighupStopSignal,
    SigintStopSignal,
    OtherStopSignal

  RRGDBError* = enum ## RRGDB error enum
    RRGDBErrorBreakpoint,
    RRGDBErrorWatchpoint,
    RRGDBErrorAmbiguousName,
    RRGDBErrorOther

  RRGDBStatus* = enum ## RRGDB Status enum
    SignalReceived,
    BreakpointHit,
    ExitedNormally,
    WatchpointTrigger,
    EndSteppingRange,
    FunctionFinished,
    InvalidStep
