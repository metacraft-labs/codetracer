type
  CodetracerError* = enum
    ValueErr,
    TimeoutError,
    GdbError,
    ScriptError

  DebuggerErrorKind* = enum
    ErrorLocation,
    ErrorTimeout,
    ErrorGDB,
    ErrorTracepoint,
    ErrorUnexpected,
    ErrorUpdate,
    ErrorConfig,
    ErrorPlugin

  DebuggerErrorObject* = object
    kind*: DebuggerErrorKind
    msg*: langstring
    path*: langstring
    line*: int

  DebuggerError* = ref DebuggerErrorObject

  NotImplementedError* = object of CatchableError
