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
