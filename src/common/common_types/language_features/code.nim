type
  FunctionID* = int64 ## ID of a function

  Function* = object ## Function object
    name*: langstring
    signature*: langstring
    path*: langstring
    line*: int
    inSourcemap*: bool

  FunctionLocation* = object
    path*: langstring
    name*: langstring
    key*: langstring
    forceReload*: bool

  Instruction* = object ## Instruction object. Represents asm/bytecode instruction
    name*: langstring
    args*: langstring
    other*: langstring
    offset*: int
    highLevelPath*: langstring
    highLevelLine*: int

  Instructions* = object ## Instruction objects. Represents a sequence of instructions
    address*: int
    instructions*: seq[Instruction]
    error*: langstring

  SourceLocation* = object
    path*: langstring
    line*: int

  Location* = object
    path*: langstring
    line*: int
    status*: langstring
    functionName*: langstring
    event*: int
    expression*: langstring
    highLevelPath*: langstring
    highLevelLine*: int
    highLevelFunctionName*: langstring
    lowLevelPath*: langstring
    lowLevelLine*: int
    rrTicks*: int
    functionFirst*: int
    functionLast*: int
    highLevelFunctionFirst*: int
    highLevelFunctionLast*: int
    offset*: int
    error*: bool
    callstackDepth*: int
    originatingInstructionAddress*: int
    key*: langstring
    globalCallKey*: langstring
    # expansion location
    expansionParents*: seq[(langstring, int, int)]
    expansionDepth*: int
    expansionId*: int
    expansionFirstLine*: int
    expansionLastLine*: int
    isExpanded*: bool

    missingPath*: bool

  Symbol* = object
    name*: string
    path*: string
    line*: int
    kind*: string

  FrameInfo* = object
    offset*: int
    hasSelected*: bool