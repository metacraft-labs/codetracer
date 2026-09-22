type
  TraceLog* = object
    text*: seq[(langstring, Value)]
    error*: bool
    errorMessage*: langstring

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
      ## Empty unless no live `Lang` summarises the whole `recordings.lang`
      ## cell: a four-axis token whose ISA or approach no member has (a wasm
      ## recording, since LRS-5 deleted `LangRustWasm`), or the name of a
      ## member a later build removed.  Then this is what the cell said, kept
      ## for display (`trace_index.langLabel`), and `lang` is the cell's
      ## LANGUAGE axis alone.  See the retired-name policy and
      ## `langForStorageAxes` in `src/common/trace_index.nim`.
    approach*: RecordingApproach
      ## **How this recording was made** — the per-recording fact `lang`
      ## cannot carry, decoded from the four-axis `recordings.lang` cell
      ## (`trace_index.loadTrace`).
      ##
      ## Added by LRS-5's second deletion round, which is precondition (b) of
      ## deleting `LangRustWasm` / `LangCppWasm`: for Rust and C++ the language
      ## has two recording routes — native (`raMcr`, replayed by
      ## `ct-native-replay`) and wasm (`raVmEmulation`, a materialized CTFS
      ## trace) — and while the summary was the only per-recording fact the
      ## frontend had, two `Lang` members were the only way to tell them apart.
      ## The four sites that branch on it read
      ## `usesMaterializedTraces(trace)`, which is
      ## `materializedReplayFor(sourceLanguageOf(lang), approach)`: the REPL
      ## (`ui/repl.nim` -> `repl_vm.setMaterialized`),
      ## `DebuggerService.lineStepJump`, the re-record path
      ## (`index/traces.nim`) and `trace_index.loadCalltraceMode`'s default.
      ##
      ## It crosses the `ct trace-metadata` -> Electron hop as a NAME, not an
      ## ordinal (`serializesAsTextInJson(RecordingApproach)` in
      ## `src/common/trace_index.nim`; decoded by
      ## `src/frontend/trace_metadata.nim`).
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

func usesMaterializedTraces*(trace: Trace): bool =
  ## **The per-recording form, and the one the replay side uses.**  Does this
  ## recording open as a self-contained, materialized (CTFS) trace rather than
  ## as a native replay recording?
  ##
  ## LRS-5's second deletion round, precondition (b).  Until it, the four sites
  ## that branch on this asked `usesMaterializedTraces(trace.lang)` — a
  ## question about a LANGUAGE — and it could only be answered for Rust and C++
  ## because two `Lang` members, `LangRustWasm` and `LangCppWasm`, existed to
  ## say "wasm".  It now reads `Trace.approach`, which the `recordings.lang`
  ## cell carries per recording since trace_index schema version 2, with the
  ## language axis supplying the two stated exceptions
  ## (`MaterializedSummaryExceptions`: a Nim MCR container IS materialized, a
  ## Lua one cannot exist).
  ##
  ## A `nil` trace is `false`: no recording is open, so nothing is materialized.
  if trace.isNil: false
  else: materializedReplayFor(sourceLanguageOf(trace.lang), trace.approach)
