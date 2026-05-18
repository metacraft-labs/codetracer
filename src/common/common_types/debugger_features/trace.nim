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
    # M-REC-2: ``id`` is now a UUIDv7 recording identifier (lowercase
    # hyphenated 36-char form per RFC 9562).  The field name remains
    # ``id`` for now — M-REC-3 owns the semantic rename to
    # ``recordingId``.  Type-only flip from ``int`` to ``string`` was
    # required because the ``trace_index.db`` schema dropped the
    # integer ``maxTraceID`` counter and switched to
    # ``recording_id TEXT PRIMARY KEY``.  See
    # ``codetracer-specs/Refactoring-Plans/Recording-Identifier-Migration.md``.
    id*: langstring
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
    # M-REC-2/3: recording identifier as a UUIDv7 string.  Field name
    # preserved (M-REC-3 will rename to ``recordingId``); type flipped
    # from ``int`` per the schema cascade.
    traceId*: langstring
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

  RecentFolder* = ref object
    id*: int
    path*: langstring
    name*: langstring
    lastOpened*: langstring
