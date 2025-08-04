type
  ShellEventKind* = enum ShellRaw ## Currently only raw event exists

  ShellEvent* = object
    kind*: ShellEventKind
    id*:   int
    raw*:  langstring

  ShellUpdateKind* = enum
    ShellUpdateRaw,
    ShellEvents

  ShellUpdate* = object ## Either a raw event or a sequence of SessionEvent objects
    id*:   int
    case kind*: ShellUpdateKind:
    of ShellUpdateRaw:
      raw*: langstring
    of ShellEvents:
      events*: seq[SessionEvent]
      progress*: int

  SessionEventKind* = enum
    CustomCompilerFlagCommand,
    LinkingBinary,
    RecordingCommand

  SessionEventStatus* = enum
    WorkingStatus,
    OkStatus,
    ErrorStatus

  SessionEvent* = object ## Session event object. Compiling, linking or recording a trace
    case kind*: SessionEventKind:
    of CustomCompilerFlagCommand:
      program*: langstring
    of LinkingBinary:
      binary*: langstring
    of RecordingCommand:
      traceArchivePath*: langstring
      # for rr-backend: the rr process, not the recorded process itself
      recordPid*: int
      trace*: Trace
    command*: langstring
    sessionId*: int
    status*: SessionEventStatus
    errorMessage*: langstring
    firstLine*: int
    lastLine*: int
    actionId*: int
    time*: langstring

  CITraceEvent* = ref object
    traceArchivePath*: langstring
    recordPid*: int
    langName*: langstring
