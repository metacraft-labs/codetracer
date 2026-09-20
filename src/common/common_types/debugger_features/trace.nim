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
      ## A SUMMARY of a per-file fact, not an authority.  A language is a
      ## property of a file, and a recording spans as many languages as it
      ## spans files: the Call Trace Pane re-derives the language on every move
      ## from the active location's path (`src/frontend/ui/calltrace.nim`,
      ## `toLangFromFilename(self.location.path)`) and the Event Log does the
      ## same.  This field gives a recording list one label per row and picks
      ## the replay-side defaults (`usesMaterializedTraces`); new code that
      ## needs the language of a FILE asks the path, not this field.
      ## `codetracer-specs/Refactoring-Plans/Language-Recording-Type-Split.md`
      ## §0.0 R1/R2 and §4.1.
    langRetiredName*: langstring
      ## Empty unless the trace index row named a `Lang` member that this build
      ## no longer has.  Then `lang` is `LangUnknown` and this is the name the
      ## recording was made under, kept for display (`trace_index.langLabel`).
      ## See the retired-name policy in `src/common/trace_index.nim`.
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
