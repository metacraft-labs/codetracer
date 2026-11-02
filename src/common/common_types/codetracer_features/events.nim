type
  # The kinds of `trace-events.md` §"EventLogKind (u8 enum)", by ordinal: MUST
  # list the same kinds in the same order as `codetracer_trace_types`'s
  # `pub enum EventLogKind`, whose ordinals are what the db-backend sends.
  # `EVENT_KINDS_COUNT` in db-backend/src/task.rs is the number of kinds, and
  # `selectedKinds` (`array[EventLogKind, bool]`) crosses to it by ordinal.
  # Also keep in sync: the `Kind*` constants in
  # src/frontend/tui/app/views/event_log.nim, `EventLogKind` in
  # libs/ct-dap-client/src/types/common.rs, and the kind table in README.md.
  EventLogKind* {.pure.} = enum
    Write,          ## output to stdout, or a write with no more specific kind
    WriteFile,
    WriteOther,     ## a write no other kind describes
    Read,           ## input from stdin, or a read with no more specific kind
    ReadFile,
    ReadOther,      ## a read no other kind describes
    ReadDir,
    OpenDir,
    CloseDir,
    Socket,
    Open,
    Error,
    TraceLogEvent,  ## trace log events
    EvmEvent,       ## Stylus EVM events
    WriteStderr,    ## output to stderr
    Exec,           ## running a program or spawning a process
    ReadEnv,        ## reading an environment variable or testing one is set
    WriteEnv,       ## setting or removing an environment variable
    Stat,           ## existence/metadata query of a filesystem entry, PATH search
    CreateDir,      ## creating a directory, including copying a directory tree
    RemoveDir,
    RemoveFile,
    Rename,         ## renaming or moving a file or directory
    ChangeDir,      ## changing the working directory

  OrdValue* = object ## Order value for a column in a TableArgs object
    column*: int
    dir*: langstring

  SearchValue* = object ## Search Value. Either a string or regex
    value*: langstring
    regex*: bool

  UpdateColumns* = object ## Update Columns object for TableArgs
    data*: langstring
    name*: langstring
    orderable*: bool
    search*: SearchValue
    searchable*: bool

  TableArgs* = object ## TableArgs object
    columns*: seq[UpdateColumns]
    draw*: int
    length*: int
    order*: seq[OrdValue]
    search*: SearchValue
    start*: int

  UpdateTableArgs* = object ## Update TableArgs object
    tableArgs*: TableArgs
    selectedKinds*: array[EventLogKind, bool]
    isTrace*: bool
    ## Index into the db-backend's in-memory event-slot table
    ## (`EventDb::single_tables`): ``0`` is the global event log, slot
    ## ``N + 1`` is the result table for tracepoint ``N``.  M-REC-4
    ## renamed this Rust-side from the historically overloaded
    ## ``trace_id`` to ``event_slot``; M-REC-5 mirrors that rename here
    ## so the Nim → Rust JSON wire-format key flips from ``traceId`` to
    ## ``eventSlot``.  ``trace_id`` is now reserved for OpenTelemetry
    ## W3C TraceContext (parent spec §2's third meaning).
    eventSlot*: int

  TableRow* = object ## TableRow object
    directLocationRRTicks*: int
    rrEventId*: int
    fullPath*: langstring
    lowLevelLocation*: langstring
    kind*: EventLogKind
    semanticKind*: langstring
    content*: langstring
    metadata*: langstring
    base64Encoded*: bool
    stdout*: bool
    sourceGeneration*: int
    sourceDigest*: langstring

  TableData* = object ## TableData object
    draw*: int
    recordsTotal*: int
    recordsFiltered*: int
    data*: seq[TableRow]

  TableUpdate* = object ## TableUpdate object
    data*: TableData
    isTrace*: bool
    ## Mirrors [UpdateTableArgs.eventSlot]; M-REC-5 wire-format rename
    ## from ``traceId`` (now reserved for OTel W3C TraceContext) to
    ## ``eventSlot``.  See the Recording-Identifier-Migration spec.
    eventSlot*: int

  ProgramEvent* = object
    kind*: EventLogKind
    semanticKind*: langstring
    content*: langstring
    rrEventId*: int
    highLevelPath*: langstring
    highLevelLine*: int
    # eventually: might be available in the future
    # lowLevelLocation*: Location
    metadata*: langstring ## metadata for read/write file events:
    bytes*: int
    stdout*: bool
    directLocationRRTicks*: int
    tracepointResultIndex*: int
    eventIndex*: int # index in the overall events sequence
    base64Encoded*: bool
    maxRRTicks*: int
    sourceGeneration*: int
    sourceDigest*: langstring
