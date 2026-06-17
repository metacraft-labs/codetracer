type
  DapStoppedEvent* = ref object
    # TODO
    threadId*: int

  DapInitializeRequestArgs* = ref object
    clientID*: langstring

    clientName*: langstring

    adapterID*: langstring

    locale*: langstring

    linesStartAt1*: bool

    columnsStartAt1*: bool

    # 'path' | 'uri' | langstring
    pathFormat*: langstring

    supportsVariableType*: bool

    supportsVariablePaging*: bool

    supportsRunInTerminalRequest*: bool

    supportsMemoryReferences*: bool

    supportsProgressReporting*: bool

    supportsInvalidatedEvent*: bool

    supportsMemoryEvent*: bool

    supportsArgsCanBeInterpretedByShell*: bool

    supportsStartDebuggingRequest*: bool

    supportsANSIStyling*: bool

  DapStepArguments* = ref object
    threadId*: int

  DapSourceReference* = ref object
    # TODO: Need something for Option[int]
    # that will be serialized properly

  DapSource* = ref object
    name*: langstring
    path*: langstring
    sourceReference*: DapSourceReference

  DapSourceBreakpoint* = ref object
    line*: int
    column*: int
    ## M9 — Column-Aware Conditional Breakpoint: an optional
    ## expression evaluated by the replay engine at the candidate
    ## stop step.  ``""`` (the default for the ref-object's value
    ## type) preserves the unconditional behaviour M1 shipped with;
    ## a non-empty string is forwarded to the replay engine on the
    ## DAP ``setBreakpoints`` request.
    condition*: cstring

  DapSetBreakpointsArguments* = ref object
    source*: DapSource
    breakpoints*: seq[DapSourceBreakpoint]
    lines*: seq[int]
    sourceModified*: bool
