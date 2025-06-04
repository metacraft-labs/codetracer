type
  TraceLog* = object
    text*: seq[(langstring, Value)]
    error*: bool
    errorMessage*: langstring

  ConfigureArg* = object
    lang*: Lang
    trace*: CoreTrace

  DebugGdbArg* = object
    expression*: langstring
    process*: langstring

  LoadHistoryArg* = object
    expression*: langstring
    location*: Location
    isForward*: bool

  LoadCallstackArg* = object
    codeID*: int64
    withArgs*: bool

  LoadLocalsArg* = object
    rrTicks*: int
    countBudget*: int
    minCountLimit*: int

  EvaluateExpressionArg* = object
    rrTicks*: int
    expression*: langstring

  LoadParsedExprsArg* = object
    line*: int
    path*: langstring

  ResetOperationArg* = object
    full*: bool
    resetLastLocation*: bool
    # TODO: eventually?
    # process*: ProcessEnum

  DbEventKind* {.pure.} = enum Record, Trace, History

  RegisterEventsArg* = object
    kind*: DbEventKind
    events*: seq[ProgramEvent]

  Trace* = ref object
    id*: int
    program*: langstring
    args*: seq[langstring]
    env*: langstring
    workdir*: langstring
    output*: langstring
    sourceFolders*: seq[langstring]
    lowLevelFolder*: langstring
    compileCommand*: langstring
    outputFolder*: langstring
    date*: langstring # TODO: why not DateTime
    duration*: langstring
    lang*: Lang
    imported*: bool
    calltrace*: bool
    events*: bool
    test*: bool
    archiveServerID*: int
    shellID*: int
    teamID*: int
    rrPid*: int
    exitCode*: int
    calltraceMode*: CalltraceMode
    downloadKey*: langstring
    controlId*: langstring
    onlineExpireTime*: int

  CoreTraceObject* = object
    paths*: seq[langstring]
    replay*: bool
    binary*: langstring
    program*: seq[langstring]
    traceId*: int
    calltrace*: bool
    preloadEnabled*: bool
    callArgsEnabled*: bool
    historyEnabled*: bool
    traceEnabled*: bool
    eventsEnabled*: bool
    telemetry*: bool
    imported*: bool
    test*: bool
    debug*: bool
    traceOutputFolder*: langstring

  CoreTrace* = ref CoreTraceObject