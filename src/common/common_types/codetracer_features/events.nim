type
  # IMPORTANT: must update `pub const EVENT_KINDS_COUNT` in db-backend/src/task.rs
  # on changes here!
  # also must update codetracer-ruby-tracer trace.rb `EVENT_KIND_..` consts
  # and overally this is based on and MUST be in sync with the runtime_tracing lib
  # which defines `pub enum EventLogKind`
  EventLogKind* {.pure.} = enum
    Write,
    WriteFile,
    WriteOther,
    Read,
    ReadFile,
    ReadOther,
    # not really used for now
    # we might remove them or implement them
    # in the future
    ReadDir,
    OpenDir,
    CloseDir,
    Socket,
    Open,
    Error,

    # used for trace log events
    TraceLogEvent,

    # used for stylus evm events
    EvmEvent,

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
    traceId*: int

  TableRow* = object ## TableRow object
    directLocationRRTicks*: int
    rrEventId*: int
    fullPath*: langstring
    lowLevelLocation*: langstring
    kind*: EventLogKind
    content*: langstring
    metadata*: langstring
    base64Encoded*: bool
    stdout*: bool

  TableData* = object ## TableData object
    draw*: int
    recordsTotal*: int
    recordsFiltered*: int
    data*: seq[TableRow]

  TableUpdate* = object ## TableUpdate object
    data*: TableData
    isTrace*: bool
    traceId*: int

  ProgramEvent* = object
    kind*: EventLogKind
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
    opId*: int
