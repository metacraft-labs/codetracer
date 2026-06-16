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

  # An abstaract location in the code
  Location* = object
    path*: langstring
    line*: int
    ## M1 — Column-Aware Replay Navigation §M1: 1-indexed column the
    ## step landed on for column-aware recordings (JS / Python via the
    ## column-extended recorders), or 0 when the trace carries no
    ## column data (legacy line-only traces).  Mirrors the
    ## ``Option<i64>``-shaped field on the Rust ``Location`` struct
    ## (``src/db-backend/src/task.rs``) — ``None`` is wired across the
    ## DAP JSON wire as a missing key, which Nim's JSON-to-object
    ## ``nimCopy`` materialises as the zero default so callers can
    ## treat 0 as "no column recorded" without an optional check.
    ##
    ## Adding this field is what lets ``DebuggerService.onCompleteMove``
    ## propagate the column out of the ``ct/complete-move`` payload —
    ## without the field declared here, Nim's JS backend's nimCopy
    ## against the static type descriptor would silently drop the
    ## column field even though the wire JSON carries it.  See the
    ## status file's Follow-up notes for the diagnosis.
    column*: int
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
    sourceGeneration*: int
    sourceDigest*: langstring
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
