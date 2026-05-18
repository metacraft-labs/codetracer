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
    # M-REC-3: ``recordingId`` is a UUIDv7 recording identifier (lowercase
    # hyphenated 36-char form per RFC 9562).  Pre-M-REC-2 this was an
    # integer ``id`` allocated from the ``trace_values.maxTraceID``
    # counter in ``trace_index.db``; the schema rewrite (M-REC-2) flipped
    # the type to ``string`` and M-REC-3 renamed the field from ``id``
    # so the codebase speaks "recording" rather than the overloaded
    # "trace".  See
    # ``codetracer-specs/Refactoring-Plans/Recording-Identifier-Migration.md``.
    recordingId*: langstring
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
    # M-REC-3: recording identifier as a UUIDv7 string.  The pre-M-REC-2
    # name was ``traceId``; M-REC-3 renamed it to ``recordingId`` so the
    # field clearly speaks "recording" rather than the overloaded
    # "trace_id".  See the Recording-Identifier-Migration spec.
    recordingId*: langstring
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
