type
  TracepointMode* = enum ## Tracepoint mode
      TracInlineCode,
      TracExpandable, ## Currently unused
      TracVisual ## Currently Unused

  Tracepoint* = ref object
    ## a single tracepoint: data for one location in a file/instructions
    ## with log code and a language
    ## it also contains a list of result id-s and some helper fields
    tracepointId*: int
    mode*: TracepointMode
    line*: int
    offset*: int
    name*: langstring
    expression*: langstring
    lastRender*: int
    isDisabled*: bool
    isChanged*: bool
    lang*: Lang
    results*: seq[Stop]
    tracepointError*: langstring

  TraceUpdate* = object
    updateID*: int
    firstUpdate*: bool
    sessionID*: int
    tracepointErrors*: TableLike[int, langstring]
    count*: int
    totalCount*: int
    refreshEventLog*: bool

  TracepointResults* = ref object
    sessionId*: int
    tracepointId*: int
    tracepointValues*: seq[(string, Value)]
    events*:      seq[ProgramEvent]
    lastInSession*: bool
    firstUpdate*: bool

  TraceValues* = object
    id*: int
    locals*: seq[seq[(langstring, Value)]]

  TracepointId* = object
    id*: int

  TraceResult* = object
    i*: int
    resultIndex*: int
    rrTicks*: int64

  TraceSession* = ref object
    ## a trace session contains of all the active tracepoints
    ## and contains all of their results
    tracepoints*: seq[Tracepoint]
    found*: seq[Stop]
    lastCount*: int
    results*: TableLike[int, seq[Stop]]
    id*: int

  RunTracepointsArg* = object
    session*: TraceSession
    stopAfter*: int

  StopType* {.pure.} = enum
    Trace,
    History,
    State,
    FollowHistory,
    NoEvent

  # An object that represents a tracepoint stop location
  Stop* = ref object
    tracepointId*: int ## set to -1 for stops that are not assigned to a tracepoint
    time*: BiggestInt
    line*: int
    path*: langstring
    offset*: int
    address*: langstring
    iteration*: int ## nth time thru this rr event
    resultIndex*: int ## index in tracepoint results
    event*: int ## rr event id
    mode*: TracepointMode ## expandable or visual
    locals*: seq[(langstring, Value)] ## local values
    whenMax*: int
    whenMin*: int
    location*: Location
    errorMessage*: langstring
    eventType*: StopType
    description*: langstring
    rrTicks*: int
    functionName*: langstring
    key*: langstring
    lang*: Lang

  Helpers* = TableLike[langstring, Helper]

  Helper* = ref object
    lang*: Lang
    source*: cstring
