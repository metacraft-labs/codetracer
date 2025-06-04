type
  DebuggerDirection* = enum
    DebForward,
    DebReverse

  StepIterationInfo* = ref object
    loopId*: int
    iteration*: int

  LineStepValue* = ref object
    expression*: langstring
    value*: Value

  LoadStepLinesArg* = ref object
    location*: Location
    forwardCount*: int
    backwardCount*: int

  LineStepKind* {.pure.} = enum Line, Call, Return

  LineStep* = object
    kind*: LineStepKind
    location*: Location
    delta*: int
    # for now reuse for calls/events/etc description
    sourceLine*: langstring
    # for flow: flow values
    # for call: args (but TODO probably)
    # for return: {"->", ret value} (but TODO probably)
    values*: seq[LineStepValue]

  LoadStepLinesUpdate* = object
    argLocation*: Location
    results*: seq[LineStep]
    finish*: bool

  StepArg* = object
    action*: DebuggerAction
    reverse*: bool
    repeat*: int
    complete*: bool
    skipInternal*: bool
    skipNoSource*: bool