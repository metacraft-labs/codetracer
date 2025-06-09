type
  CallCountKind* = enum
    Equal,
    GreaterOrEqual,
    LessOrEqual,
    Greater,
    Less

  CallCount* = object
    i*: int64
    kind*: CallCountKind

  Call* = ref object
    key*: langstring
    children*: seq[Call]
    hiddenChildren*: bool
    depth*: int
    location*: Location
    parent*: Call
    rawName*: langstring
    args*: seq[CallArg] ## callstack only:
    returnValue*: Value
    # TODO returnName*:  string # e.g. Go? TODO
    withArgsAndReturn*: bool  ## for now true for loaded from callstack calls, false for call successors

  CallArg* = ref object
    name*: langstring
    text*: langstring
    value*: Value

  CallLineContentKind* {.pure.} = enum
    Call,
    NonExpanded,
    WithHiddenChildren,
    CallstackInternalCount,
    StartCallstackCount,
    EndOfProgramCall,

  CallLineContent* = ref object ## Either a Call or a NonExpanded count
    kind*: CallLineContentKind
    call*: Call
    nonExpandedKind*: CalltraceNonExpandedKind
    count*: int
    hiddenChildren*: bool
    isError*: bool

  CallLine* = ref object
    content*: CallLineContent
    depth*: int

  CallArgsUpdateResults* = object
    finished*: bool
    args*: TableLike[langstring, seq[CallArg]] # TODO int64 .. on javascript
    returnValues*: TableLike[langstring, Value]
    startCallLineIndex*: int
    startCall*: Call
    startCallParentKey*: langstring
    callLines*: seq[CallLine]
    totalCallsCount*: int
    scrollPosition*: int
    maxDepth*: int

  CallSearchArg* = langstring

  CalltraceMode* {.pure.} = enum NoInstrumentation, CallKeyOnly, RawRecordNoValues, FullRecord

  CalltraceNonExpandedKind* {.pure.} = enum
    Callstack,
    Children,
    Siblings,
    Calls,
    CallstackInternal,
    CallstackInternalChild

  CalltraceLoadArgs* = object
    location*: Location
    startCallLineIndex*: int
    depth*: int
    height*: int
    rawIgnorePatterns*: langstring
    autoCollapsing*: bool
    optimizeCollapse*: bool
    renderCallLineIndex*: int

  CollapseCallsArgs* = object
    callKey*: langstring
    nonExpandedKind*: CalltraceNonExpandedKind
    count*: int