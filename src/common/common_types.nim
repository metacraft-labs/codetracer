# backend agnostic code, part of the types module, should not be imported directly,
# use common/types or frontend/types instead.
import
  strformat, strutils, sequtils, macros, json, times, typetraits, results

import task_and_event

const SHARED* = false
const NO_INDEX*: int = -1
const NO_EVENT*: int = -1
const NO_OFFSET*: int = -1
const NO_LINE*: int = -1
const NO_STEP_COUNT*: int = -1
const NO_POSITION*: int = -1
const NO_KEY*: string = "-1"
const NO_LIMIT*: int = -1
const NO_TICKS*: int = -1
const FLOW_ITERATION_START*: int = 0
const RESTART_EXIT_CODE*: int = 10

const
  CT_SOCKET_PATH* = langstring("/tmp/ct_socket")
  CT_CLIENT_SOCKET_PATH* = langstring("/tmp/ct_client_socket")
  CT_IPC_FILE_PATH* = langstring("/tmp/ct_ipc")
  CT_PLUGIN_SOCKET_PATH* = langstring("/tmp/codetracer_plugin_socket")
  CT_PYTHON_LOG_PATH_BASE* = langstring("/tmp/codetracer/log")

const NO_NAME* = langstring""

proc ct_python_log_path*(callerPid: int): langstring =
  CT_PYTHON_LOG_PATH_BASE & "_" & $callerPid & ".txt"

proc ct_python_json_log_path*(callerPid: int): langstring =
  CT_PYTHON_LOG_PATH_BASE & "_" & $callerPid & ".jsonl"

# this module is used in codetracer and core and in the nim plugin so
# it needs to support both C and JavaScript
# try to use langstring when something is
#  string in c backend and cstring in javascript backend
# TODO unify most type definitions for the backends

# currently a lot of app data is saved in data: Data and it's accessed as a global object in renderer.nim and ui_js.nim

type
  NotificationKind* = enum ## Notification kinds.
    NotificationInfo,
    NotificationWarning,
    NotificationError,
    NotificationSuccess


  Notification* = ref object ## Notification object.
    kind*: NotificationKind
    time*: int64
    text*: langstring
    active*: bool
    seen*: bool
    timeoutId*: int
    hasTimeout*: bool
    isOperationStatus*: bool
    # Defines side-effect-ful "actions" that will be performed when the
    # notification is sent
    actions*: seq[NotificationAction]

  NotificationActionKind* = enum
    ButtonAction

  NotificationAction* = object
    case kind*: NotificationActionKind:
      of ButtonAction:
        name*: langstring
        handler*: proc: void

  DebuggerErrorKind* = enum ## Debugger Error kinds.
    ErrorLocation,
    ErrorTimeout,
    ErrorGDB,
    ErrorTracepoint,
    ErrorUnexpected,
    ErrorUpdate,
    ErrorConfig,
    ErrorPlugin

  DebuggerErrorObject* = object ## Debugger error object.
    kind*: DebuggerErrorKind
    msg*: langstring
    path*: langstring
    line*: int

  DebuggerError* = ref DebuggerErrorObject ## Ref of DebuggerErrorObject

  WhitespaceCharacter* = enum
    WhitespaceSpaces,
    WhitespaceTabs

  Whitespace* = ref object ## Whitespace object
    character*: WhitespaceCharacter
    width*: int

  TokenKind* = enum ## Token kinds
    EmptySymbol,
    TkSymbol,
    TkRegister,
    TkRegisterOrOffset,
    TkField,
    TkIndex,
    # those are not used in python
    TkComment,
    TkKeyword,
    TkLit,
    TkIntLit,
    TkDirective,
    TkIndent,
    TkWhitespace

  Token* = object ## Token object
    kind*: TokenKind
    tokenName*: cstring
    raw*: langstring
    line*: int
    column*: int

  # support bytecode in general
  AssemblyToken* = ref object ## Assembly token
    offset*:          int
    highLevelLine*:   int
    opcode*:          cstring
    address*:         cstring
    value*:           seq[Token]
    help*:            cstring

  Trace* = ref object ## Trace object
    id*: int
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

  CalltraceMode* {.pure.} = enum NoInstrumentation, CallKeyOnly, RawRecordNoValues, FullRecord

  # possibly unused since RunToCall seems unused
  RunToCallInfo* = object ## Run to call info
    path*:          langstring
    line*:          int
    functionName*:  langstring
    reverse*:       bool

  LayoutMode* = enum ## Layout mode for component and project objects
    DebugMode,
    EditMode,
    QuickEditMode,
    InteractiveEditMode,
    CalltraceLayoutMode

  EditorView* = enum ## Editor views
    ViewSource,
    ViewTargetSource,
    ViewInstructions,
    ViewAst,
    ViewCfg,
    ViewMacroExpansion,
    ViewCalltrace,
    ViewNoSource,
    ViewLowLevelCode,
    ViewEventContent

  DebugOutputKind* = enum ## Debug output kinds.
    DebugLoading,
    DebugResult,
    DebugMove,
    DebugError

  DebugOutput* = object ## Debug output object
    kind*: DebugOutputKind
    output*: langstring

  DebugInteraction* = object ## Debug interaction object kept in the repl history
    input*: langstring
    output*: DebugOutput

  # for now we'll try to reuse those
  TypeKind* = enum ## Types kinds in programming languages
    Seq,
    Set,
    HashSet,
    OrderedSet,
    Array,
    Varargs, ## seq, HashSet, OrderedSet, set and array in Nim, vector and array in C++, list in Python, Array in Ruby
    Instance, ## object in Nim, Python and Ruby. struct, class in C++
    Int,
    Float,
    String,
    CString,
    Char,
    Bool,
    Literal, ## literals in each of them
    Ref, ## ref in Nim, ? C++, not used for Python, Ruby
    Recursion, ## used to signify self-referencing stuff
    Raw, ## fallback for unknown values
    Enum,
    Enum16,
    Enum32, ## enum in Nim and C++, not used for Python, Ruby
    C, ## fallback for c values in Nim, Ruby, Python, not used for C++
    TableKind, ## Table in Nim, std::map in C++, dict in Python, Hash in Ruby
    Union, ## variant objects in Nim, union in C++, not used in Python, Ruby
    Pointer, ## pointer in C/C++: still can have a referenced type, pointer in Nim, not used in Python, Ruby
    # TODO: do we need both `Ref` and `Pointer`?
    Error, ## errors
    FunctionKind, ## a function in Nim, Ruby, Python, a function pointer in C++
    TypeValue,
    Tuple, ## a tuple in Nim, Python
    Variant, ## an enum in Rust
    Html, ## visual value produced debugHTML
    None,
    NonExpanded,
    Any,
    Slice

  GdbValue* = object ## placeholder

  LineFlowKind* = enum ## Line Flow Kinds
    LineFlowHit,
    LineFlowSkip,
    LineFlowUnknown

  CodetracerError* = enum ## Code tracer errors
    ValueErr,
    TimeoutError,
    GdbError,
    ScriptError

  MacroExpansionLevelBase* = enum ## Base for Macro expansion level
    MacroExpansionTopLevel,
    MacroExpansionDeepest

  MacroExpansionLevel* = object ## MacroExpansion level
    base*: MacroExpansionLevelBase
    level*: int ## only for MacroExpansionTopLevel

  MacroExpansionUpdateKind* = enum ## Kinds of macro expansion updates:

    MacroUpdateExpand, ## expand <number>: Expand <times>
    MacroUpdateExpandAll,  ## expand all: ExpandAll
    MacroUpdateCollapse,  ## collapse <number>: Collapse <times>|
    MacroUpdateCollapseAll  ## collapse all: CollapseAll

  MacroExpansionLevelUpdate* = object ## Macro Expansion level update
    kind*: MacroExpansionUpdateKind
    times*: int ## used only in MacroUpdateExpand and MacroUpdateCollapse

  CoreTraceObject* = object ## Core Trace object
    paths*: seq[langstring]
    replay*: bool
    binary*: langstring
    program*: seq[langstring]
    traceId*: int
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

  CoreTrace* = ref CoreTraceObject ## Core Trace object ref

  FlowUI* = enum ## Flow types
    FlowParallel,
    FlowInline,
    FlowMultiline

  LocalStepJump* = object ## Local Step jump object
    path*: langstring
    line*: int
    stepCount*: int
    iteration*: int
    firstLoopLine*: int
    rrTicks*: int
    reverse*: bool

  ShellEventKind* = enum ShellRaw ## Shell Event kind. Currently only raw event exists

  ShellEvent* = object ## Shell event object.
    kind*: ShellEventKind
    id*:   int
    raw*:  langstring

  ShellUpdateKind* = enum ## Shell Update kinds
    ShellUpdateRaw,
    ShellEvents

  ShellUpdate* = object ## Shell update object. Either a raw event or a sequence of SessionEvent objects
    id*:   int
    case kind*: ShellUpdateKind:
    of ShellUpdateRaw:
      raw*: langstring
    of ShellEvents:
      events*: seq[SessionEvent]
      progress*: int

  SessionEventKind* = enum ## Session event kinds
    CustomCompilerFlagCommand,
    LinkingBinary,
    RecordingCommand

  SessionEventStatus* = enum ## State of a Session Event
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
      trace*: Trace
    command*: langstring
    sessionId*: int
    status*: SessionEventStatus
    errorMessage*: langstring
    firstLine*: int
    lastLine*: int
    actionId*: int
    time*: langstring

  SocketAddressInfo* = object ## Socket Adress Info
    host*: langstring
    port*: int
    parameters*: langstring

  StartOptions* = object ## Frontend start options
    loading*: bool
    screen*: bool
    inTest*: bool
    record*: bool
    isInstalled*: bool
    traceID*: int
    edit*: bool
    name*: langstring
    folder*: langstring
    welcomeScreen*: bool
    app*: langstring
    shellUi*: bool
    address*: langstring
    port*: int
    frontendSocket*: SocketAddressInfo
    backendSocket*: SocketAddressInfo
    rawTestStrategy*: langstring

  Type* = ref object ## Representation of a language type
    kind*: TypeKind
    labels*: seq[langstring]
    minVariant*: int
    variants*: seq[seq[int]]
    langType*: langstring
    cType*: langstring
    elementType*: Type
    length*: int
    childrenNames*: seq[seq[langstring]]
    childrenTypes*: seq[seq[Type]]
    kindType*: Type
    kindName*: langstring
    memberNames*: seq[langstring]
    memberTypes*: seq[Type]
    fieldVariants*: TableLike[langstring, langstring]
    caseObjects*: TableLike[langstring, seq[langstring]]
    enumObjects*: TableLike[langstring, int]
    intType*: langstring
    returnType*: Type
    discriminatorName*: langstring
    fieldTypes*: Table[langstring, Type]
    enumNames*: seq[langstring]
    keyType*: Type
    valueType*: Type
    isType*: bool
    withName*: bool

  Value* = ref object ## Representation of a language value
    kind*: TypeKind
    typ*: Type
    elements*: seq[Value]
    text*: langstring
    cText*: langstring
    f*: langstring
    i*: langstring
    enumInt*: BiggestInt
    c*: langstring
    b*: bool
    member*: seq[Value]
    refValue*: Value
    address*: langstring
    strong*: int
    weak*: int
    r*: langstring
    items*: seq[seq[Value]]
    kindValue*: Value
    children*: seq[Value]
    shared*: seq[Value]
    msg*: langstring
    signature*: langstring
    functionLabel*: langstring
    base*: langstring
    dict*: TableLike[langstring, Value]
    members*: seq[Value]
    fields*: TableLike[langstring, Value]
    isWatch*: bool
    isType*: bool
    expression*: langstring
    isLiteral*: bool
    activeVariant*: langstring
    activeVariantValue*: Value
    activeFields*: seq[langstring]
    gdbValue*: ref GdbValue # should be nil always out of python
    partiallyExpanded*: bool


  # XXX: Nim json lib has problems with the table version
  FunctionID* = int64 ## ID of a function

  TracepointMode* = enum ## Tracepoint mode
    TracInlineCode,
    TracExpandable, ## Currently unused
    TracVisual ## Currently Unused

  FlowUpdateStateKind* = enum ## Flow Update State kinds
    FlowNotLoading,
    FlowWaitingForStart,
    FlowLoading,
    FlowFinished

  FlowUpdateState* = object ## Flow Update State. Only FlowLoading kind used
    case kind*: FlowUpdateStateKind:
    of FlowLoading:
      steps*: int
    else:
      discard

  LoopID* = int ## ID of a loop

  CallCountKind* = enum ## CallCount kinds
    Eq,
    GtOrEq,
    LsOrEq,
    Gt,
    Ls

  CallCount* = object ## CallCount object
    i*: int64
    kind*: CallCountKind

  TokenText* = enum ## Token text enum
    InstanceOpen,
    InstanceClose,
    ArrayOpen,
    ArrayClose,
    SeqOpen,
    SeqClose

  Action* = enum ## Debugger action
    StepIn,
    StepOut,
    Next,
    Continue,
    StepC,
    NextC,
    StepI,
    NextI,
    CoStepIn,
    CoNext,
    NonAction

  FrameInfo* = object ## Frame Info object
    offset*: int
    hasSelected*: bool

  BreakpointInfo* = object ## Breakpoint Info
    path*: langstring
    line*: int
    id*: int

  TraceLog* = object ## TraceLog object
    text*: seq[(langstring, Value)]
    error*: bool
    errorMessage*: langstring

  Call* = ref object ## Call object
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

  CallArg* = ref object ## Call Arg object
    name*: langstring
    text*: langstring
    value*: Value

  CallstackJump* = object ##Callstack Jump
    index*: int
    functionName*: langstring

  Helpers* = TableLike[langstring, Helper] ## Table of helpers

  Helper* = ref object ## Helper object
    lang*: Lang
    source*: cstring

  SegfaultRoot* = object ## Seffault root object
    path*: langstring
    line*: int
    description*: langstring

  CalltraceNonExpandedKind* {.pure.} = enum ## Calltrace NonExpanded Kind
    Callstack,
    Children,
    Siblings,
    Calls,
    CallstackInternal,
    CallstackInternalChild

  CallLineContentKind* {.pure.} = enum ## Callline Content Kind
    Call,
    NonExpanded,
    WithHiddenChildren,
    CallstackInternalCount,
    StartCallstackCount,
    EndOfProgramCall,

  CallLineContent* = ref object ## Calline Content object. Either a Call or a NonExpanded count
    kind*: CallLineContentKind
    call*: Call
    nonExpandedKind*: CalltraceNonExpandedKind
    count*: int
    hiddenChildren*: bool
    isError*: bool

  CallLine* = ref object ## Call Line object. Contains a CallLine Content object and a depth
    content*: CallLineContent
    depth*: int

  CallArgsUpdateResults* = object ## CallArgs Update results object
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

  StepIterationInfo* = ref object
    loopId*: int
    iteration*: int

  LineStepValue* = ref object
    expression*: langstring
    value*: Value

  LoadStepLinesArg* = ref object
    location*: Location
    forwardCount*: int
    backwardCount*: int

  LineStepKind* {.pure.} = enum Line, Call, Return

  LineStep* = object
    kind*: LineStepKind
    location*: Location
    delta*: int
    # for now reuse for calls/events/etc description
    sourceLine*: langstring
    # for flow: flow values
    # for call: args (but TODO probably)
    # for return: {"->", ret value} (but TODO probably)
    values*: seq[LineStepValue]

  LoadStepLinesUpdate* = object
    argLocation*: Location
    results*: seq[LineStep]
    finish*: bool

  MacroExpansion* = object ## MacroExpansion object
    path*: langstring
    definition*: langstring
    line*: int
    isDefinition*: bool

  Location* = object ## Location object
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

  CalltraceLoadArgs* = object ## Calltrace Load Arguments
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

  StopType* {.pure.} = enum ## Stop object type
    Trace,
    History,
    State,
    FollowHistory,
    NoEvent

  FlowQuery* = ref object ## Flow Query object
    location*: Location
    taskId*:   TaskId

  FlowEvent* = object
    kind*: EventLogKind
    text*: langstring
    # contains step_id for db-backend
    rrTicks*: int64

  FlowStep* = object ## Flow Step object
    position*: int
    loop*: int
    iteration*: int
    stepCount*: int
    rrTicks*: int
    # TODO: maybe use seq, but for now a bit simpler with Table
    # eventually seq should be ok with labels seq for each visited line in FlowViewUpdate
    # for all langs except maybe very dynamic ones (or macro expansions?)
    beforeValues*: TableLike[langstring, Value]
    afterValues*: TableLike[langstring, Value]
    exprOrder*:    seq[langstring]
    events*: seq[FlowEvent]

  Loop* = object ## Loop object
    base*: int
    baseIteration*: int
    internal*: seq[int]
    first*: int
    last*: int
    registeredLine*: int
    iteration*: int
    stepCounts*: seq[int]
    rrTicksForIterations*: seq[int]

  Project* = object ## Project object
    date*: DateTime
    folders*: seq[langstring]
    name*: langstring
    lang*: Lang
    mode*: LayoutMode
    saveID*: int
    traceID*: int

  Save* = object ## Project save object
    project*: Project
    files*: seq[SaveFile]
    fileMap*: TableLike[langstring, int]
    id*: int

  SaveFile* = object ## Save File object
    path*: langstring
    line*: int

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

  BranchState* = enum ## State of a branch in a debugger, either taken, untaken or unknown
    Unknown,
    Taken,
    NotTaken

  BranchesTaken* = object ## Table of branch states
    table*: TableLike[int, BranchState]

  LoopIterationSteps* = object ## Table of Loop Iteration steps
    table*: TableLike[int, int]

  FlowViewUpdateObject* = object ## FlowViewUpdate obejct
    location*: Location
    positionStepCounts*: TableLike[int, seq[int]]
    steps*: seq[FlowStep]
    loops*: seq[Loop]
    branchesTaken*: seq[seq[BranchesTaken]]
    loopIterationSteps*: seq[seq[LoopIterationSteps]]
    relevantStepCount*: seq[int]

  FlowViewUpdate* = ref FlowViewUpdateObject ## FlowViewUpdate obejct ref

  FlowUpdate* = ref object ## Flow Update object
    viewUpdates*: array[EditorView, FlowViewUpdate]
    location*: Location
    error*: bool
    errorMessage*: langstring
    finished*: bool
    status*: FlowUpdateState

  FlowExpression* = object ## Flow Expression object
    kind*: TokenKind
    base*: langstring
    field*: langstring
    collection*: langstring
    index*: langstring
    expression*: langstring
    startCol*: langstring
    endCol*: langstring

  FlowShape* = ref object ## Flow shape object
    viewUpdates*: array[EditorView, FlowViewShape]

  FlowViewShape* = ref object ## FlowView Shape object
    loops*: seq[LoopShape]
    expressions*: TableLike[int, seq[FlowExpression]]

  LoopShape* = ref object ## Loop shape object
    base*: int
    internal*: seq[LoopID]
    first*: int
    last*: int

  ShortCircuitGroup* = object
    left*:                    Boundary
    right*:                   Boundary

  BoundaryKind* = enum BBefore, BAfter, BAnd, BOr

  Boundary* = object
    # A boundary can be either before/after or n-th operator
    case kind*: BoundaryKind
    of BAnd, BOr:
      index*: int
    else: discard

  Stop* = ref object ## Stop object
    tracepointId*: int ## set to -1 for stops that are not assigned to a tracepoint
    time*: BiggestInt
    line*: int
    path*: langstring
    offset*: int
    address*: langstring
    iteration*: int ## nth time thru this rr event
    resultIndex*: int ## index in tracepoint results
    event*: int ## rr event id
    mode*: TracepointMode ## expandable or visual
    locals*: seq[(langstring, Value)] ## local values
    whenMax*: int
    whenMin*: int
    location*: Location
    errorMessage*: langstring
    eventType*: StopType
    description*: langstring
    rrTicks*: int
    functionName*: langstring
    key*: langstring
    lang*: Lang

  Variable* = ref object
    expression*: langstring
    value*: Value

  # IMPORTANT: must update `pub const EVENT_KINDS_COUNT` in db-backend/src/task.rs
  # on changes here!
  # also must update codetracer-ruby-tracer trace.rb `EVENT_KIND_..` consts
  # and overally this is based on and MUST be in sync with the runtime_tracing lib
  # which defines `pub enum EventLogKind`
  EventLogKind* {.pure.} = enum ## EventLog kinds
    Write,
    WriteFile,
    Read,
    ReadFile,
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
    TraceLogEvent

  ProgramEvent* = object ## Program event object
    kind*: EventLogKind
    content*: langstring
    rrEventId*: int
    highLevelPath*: langstring
    highLevelLine*: int
    # eventually: might be available in the future
    # lowLevelLocation*: Location
    filenameMetadata*: langstring ## metadata for read/write file events:
    bytes*: int
    stdout*: bool
    directLocationRRTicks*: int
    tracepointResultIndex*: int
    eventIndex*: int # index in the overall events sequence
    base64Encoded*: bool
    maxRRTicks*: int

  Tracepoint* = ref object
    ## a single tracepoint: data for one location in a file/instructions
    ## with log code and a language
    ## it also contains a list of result id-s and some helper fields
    tracepointId*: int
    mode*: TracepointMode
    line*: int
    offset*: int
    name*: langstring
    expression*: langstring
    lastRender*: int
    isDisabled*: bool
    isChanged*: bool
    lang*: Lang
    results*: seq[Stop]
    tracepointError*: langstring

  TraceUpdate* = object ## Trace Update Object
    updateID*: int
    firstUpdate*: bool
    sessionID*: int
    tracepointErrors*: TableLike[int, langstring]
    count*: int
    totalCount*: int
    refreshEventLog*: bool

  TracepointResults* = ref object
    sessionId*: int
    tracepointId*: int
    tracepointValues*: seq[(string, Value)]
    events*:      seq[ProgramEvent]
    lastInSession*: bool
    firstUpdate*: bool

  HistoryUpdate* = object ## History Update object
    expression*: string
    results*: seq[HistoryResult]
    finish*: bool

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
    filenameMetadata*: langstring
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

  CallSearchArg* = object ## CallSearch arg object
    value*: langstring

  TraceValues* = object ## TraceValues object
    id*: int
    locals*: seq[seq[(langstring, Value)]]

  TracepointId* = object ## TracepointId object
    id*: int

  TraceResult* = object ## TraceResults object
    i*: int
    resultIndex*: int
    rrTicks*: int64

  TraceSession* = ref object
    ## a trace session contains of all the active tracepoints
    ## and contains all of their results
    tracepoints*: seq[Tracepoint]
    found*: seq[Stop]
    lastCount*: int
    results*: TableLike[int, seq[Stop]]
    id*: int

  HistoryResult* = object ## HistoryResult object
    location*: Location
    value*: Value
    time*: BiggestInt
    description*: langstring

  DebuggerDirection* = enum ## Debugger direction, either forward of backward
    DebForward,
    DebReverse

  ClientAction* = enum ## Client Action enum.
    forwardContinue,
    reverseContinue,
    forwardNext,
    reverseNext,
    forwardStep,
    reverseStep,
    forwardStepOut,
    reverseStepOut,
    stop,
    build,
    switchTabLeft,
    switchTabRight,
    switchTabHistory,
    openFile,
    newTab,
    reopenTab,
    closeTab,
    switchEdit,
    switchDebug,
    commandSearch, # credits to Sublime Text
    fileSearch,
    fixedSearch,
    del,
    selectFlow,
    selectState,
    goUp,
    goDown,
    goRight,
    goLeft,
    pageUp,
    pageDown,
    gotoStart,
    gotoEnd,
    aEnter, # affects only renderer, map manually editor differently
    aEscape,
    zoomIn,
    zoomOut,
    example,
    aExit,
    newFile,
    preferences,
    openFolder,
    openRecent,
    aSave,
    saveAs,
    saveAll,
    closeAllDocuments,
    aCut,
    aCopy,
    aPaste,
    findOrFilter,
    aReplace,
    findInFiles,
    replaceInFiles,
    aToggleComment,
    aIncreaseIndentation,
    aDecreaseIndentation,
    aMakeUppercase,
    aMakeLowercase,
    aCollapseUnderCursor,
    aExpandUnderCursor,
    aExpandAll,
    aCollapseAll,
    aUndo,
    aRedo,
    aProgramCallTrace,
    aProgramStateExplorer,
    aFindResults,
    aBuildLog,
    aFileExplorer,
    aSaveLayout,
    aLoadLayout,
    switchDebugWide,
    switchEditNormal,
    aNewHorizontalTabGroup,
    aNewVerticalTabGroup,
    aNotifications,
    aStartWindow,
    aFullScreen,
    aTheme0,
    aTheme1,
    aTheme2,
    aTheme3,
    aMonacoTheme0,
    aMultiline,
    aSingleLine,
    aNoPreview,
    aLowLevel0,
    aLowLevel1
    aShowMinimap,
    aGotoFile,
    aGotoSymbol,
    aGotoDefinition,
    aFindReferences,
    aGotoLine,
    aGotoPreviousCursorLocation,
    aGotoNextCursorLocation,
    aGotoPrevious,
    aGotoNextEditLocation,
    aGotoPreviousPointInTime,
    aGotoNextPointInTime,
    aGotoNextError,
    aGotoPreviousError,
    aGotoNextSearchResult,
    aGotoPreviousSearchResult,
    aBuild,
    aCompile,
    aRunStatic,
    aTrace,
    aLoadTrace,
    aNewState,
    aNewEventLog,
    aNewFullCalltrace,
    aNewTerminal,
    aPointList,
    aLocalCalltrace,
    aFullCalltrace,
    aState,
    aEventLog,
    aTerminal,
    aStepList,
    aScratchpad,
    aFilesystem,
    aShell,
    aOptions,
    aDebug,
    aBreakpoint,
    aDeleteBreakpoint,
    aDeleteAllBreakpoints,
    aEnableBreakpoint,
    aEnableAllBreakpoint,
    aDisableBreakpoint,
    aDisableAllBreakpoints,
    aTracepoint,
    aDeleteTracepoint,
    aEnableTracepoint,
    aEnableAllTracepoints,
    aDisableTracepoint,
    aDisableAllTracepoints,
    aCollectEnabledTracepointResults,
    aUserManual,
    aReportProblem,
    aSuggestFeature,
    aAbout,
    aMenu,
    zoomFlowLoopIn,
    zoomFlowLoopOut,
    switchFocusedLoopLevelUp,
    switchFocusedLoopLevelDown,
    switchFocusedLoopLevelAtPosition,
    setFlowTypeToMultiline,
    setFlowTypeToParallel,
    setFlowTypeToInline,
    aRestart,
    findSymbol

  Content* {.pure.} = enum ## Content enum
    History = 0,
    Trace = 1,
    EditorView = 2,
    Events = 3,
    State = 4,
    Statistics = 5,
    Calltrace = 6,
    Animate = 7,
    EventLog = 8,
    Filesystem = 9,
    Repl = 10,
    Build = 11,
    Errors = 12,
    FullCalltrace = 13,
    RegionGraph = 14,
    CommandView = 15,
    PointList = 16,
    Scratchpad = 17,
    LowLevelCode = 18,
    Timeline = 19,
    SearchResults = 20,
    BuildErrors = 21,
    TraceLog = 22,
    CalltraceEditor = 23,
    TerminalOutput = 24,
    Shell = 25,
    WelcomeScreen = 26,
    CallExpandedValue = 27,
    Value = 28,
    Debug = 29,
    Menu = 30,
    Status = 31,
    CommandPalette = 32,
    StepList = 33,
    NoInfo = 34

  InputShortcutMap* = TableLike[langstring, langstring] ## Input Shortcut map

  ShortcutMap* = object ## Shortcut map object
    actionShortcuts*: array[ClientAction, seq[Shortcut]]
    shortcutActions*: TableLike[langstring, ClientAction]
    conflictList*: seq[(langstring, seq[ClientAction])]

  Shortcut* = object ## Shortcut object
    renderer*: langstring
    editor*: langstring

  Function* = object ## Function object
    name*: langstring
    signature*: langstring
    path*: langstring
    line*: int
    inSourcemap*: bool

  ValueHistory* = ref object ## ValueHistory object Contains a sequence of historical results and the values location
    location*: Location
    results*: seq[HistoryResult]

  SourceLocation* = object ## Source location object, path and a line number
    path*: langstring
    line*: int

  FunctionLocation* = object
    path*: langstring
    name*: langstring
    key*: langstring
    forceReload*: bool

  Timer* = ref object ## Timer object
    point: float
    # The timer also keeps some metadata that help us detect
    # when the process it measures gets replaced.
    currentOpID*: int

  BreakpointState* = object ## State of the breakpoint at a location, either enabled or disabled
    location*: SourceLocation
    enabled*: bool

  BreakpointSetup* = object ## State of a sequence of breakpoints
    breakpoints*: seq[BreakpointState]

  BugReportData* = object ## Bug Report data object
    title*: langstring
    description*: langstring
    user*: langstring
    hostname*: langstring

  ConfigureArg* = object ## Configure arg object
    lang*: Lang
    trace*: CoreTrace

  StepArg* = object ## Step arg object
    action*: Action
    reverse*: bool
    repeat*: int
    complete*: bool
    skipInternal*: bool
    skipNoSource*: bool

  DebugGdbArg* = object ## Debug Gdb arg object
    expression*: langstring
    process*: langstring

  RunTracepointsArg* = object ## RunTracepoints arg
    session*: TraceSession
    stopAfter*: int

  LoadHistoryArg* = object ## LoadHistory arg
    expression*: langstring
    location*: Location
    isForward*: bool

  LoadCallstackArg* = object ## LocalCallstackArg
    codeID*: int64
    withArgs*: bool

  LoadLocalsArg* = object ## LoadLocals arg
    rrTicks*: int
    countBudget*: int
    minCountLimit*: int

  EvaluateExpressionArg* = object ## Evaluate Expression arg
    rrTicks*: int
    expression*: langstring

  JumpBehaviour* = enum
    SmartJump,
    ForwardJump,
    BackwardJump

  SourceLineJumpTarget* = object ## SourceLineJumpTarget object
    path*: langstring
    line*: int
    behaviour*: JumpBehaviour

  SourceCallJumpTarget* = object ## SourceCallJumpTarget object
    path*: langstring
    line*: int
    token*: langstring
    behaviour*: JumpBehaviour

  SubPathKind* = enum ## Subpath kinds
    Expression,
    Field,
    Index,
    Dereference,
    VariantKind

  SubPath* = object ## Subpath object
    typeKind*: TypeKind
    case kind*: SubPathKind
    of Expression:
      expression*: langstring
    of Field:
      name*: langstring
    of Index:
      index*: int
    of Dereference:
      discard
    of VariantKind:
      kindNumber*: int
      variantName*: langstring

  ExpandValueTarget* = object ## ExpandValueTarget object
    subPath*: seq[SubPath]
    rrTicks*: int
    isLoadMore*: bool
    startIndex*: int
    count*: int

  LoadParsedExprsArg* = object ## LoadParsedExprs arg
    line*: int
    path*: langstring

  ResetOperationArg* = object ## ResetOperation arg
    full*: bool
    resetLastLocation*: bool
    # TODO: eventually?
    # process*: ProcessEnum

  RestartProcessArg* = object ## RestartProcess arg
    breakpoints*: BreakpointSetup
    resetLastLocation*: bool

  BugReportArg* = object ## BugReport arg
    title*: langstring
    description*: langstring
  
  UploadTraceArg* = object
    trace*: Trace
    programName*: langstring

  UploadedTraceData* = object
    downloadKey*: langstring
    controlId*: langstring
    expireTime*: langstring

  DeleteTraceArg* = object
    traceId*: int
    controlId*: langstring

  DbEventKind* {.pure.} = enum Record, Trace, History

  RegisterEventsArg* = object
    kind*: DbEventKind
    events*: seq[ProgramEvent]

  EmptyArg* = object ## Empty arg


const VOID_RESULT*: langstring = langstring("{}")

const IN_DEBUG* = true

const
  TOKEN_TEXTS*: array[Lang, array[TokenText, string]] = [
  # InstanceOpen InstanceClose ArrayOpen ArrayClose SeqOpen SeqClose
    ["{", "}", "[", "]", "vector[", "]"],       # LangC
    ["{", "}", "[", "]", "vector[", "]"],       # LangCpp
    ["{", "}", "[", "]", "vec![", "]"],         # LangRust
    ["(", ")", "[", "]", "@[", "]"],            # LangNim
    ["{", "}", "[", "]", "vector[", "]"],       # LangGo
    ["{", "}", "[", "]", "vector[", "]"],       # LangPascal TODO
    ["(", ")", "[", "]", "[", "]"],             # LangPython
    ["(", ")", "[", "]", "[", "]"],             # LangRuby
    ["(", ")", "[", "]", "[", "]"],             # LangRubyDb
    ["{", "}", "[", "]", "[", "]"],             # LangJavascript
    ["{", "}", "[", "]", "[", "]"],             # LangLua
    ["{", "}", "[", "]", "[", "]"],             # LangAsm
    ["{", "}", "[", "]", "[", "]"],             # LangNoir
    ["{", "}", "[", "]", "[", "]"],             # LangSmall
    ["", "", "", "", "", ""]                    # LangUnknown
  ]

  WRITE_STACK*: array[Lang, seq[langstring]] = [
    @["_IO_new_file_write", "new_do_write", "_IO_new_do_write", "_IO_new_file_overflow", "putchar"], # LangC
    @["_IO_new_file_write", "new_do_write", "_IO_new_do_write", "_IO_new_file_overflow", "putchar"], # LangCpp
    @["_IO_new_file_write", "new_do_write", "_IO_new_do_write", "_IO_new_file_overflow", "putchar"], # LangRust TODO
    @["_IO_new_file_write", "_IO_new_file_sync", "new_do_write", "_IO_new_do_write", "_IO_new_file_xsputn", "__GI__IO_fwrite", "__GI__IO_fflush", "echoBinSafe"], # LangNim
    @["_IO_new_file_write", "new_do_write", "_IO_new_do_write", "_IO_new_file_overflow", "putchar"], # LangGo TODO
    @["_IO_new_file_write", "new_do_write", "_IO_new_do_write", "_IO_new_file_overflow", "putchar"], # LangPascal TODO
    @["write"], # LangPython
    @["write"], # LangRuby
    @["write"], # LangRubyDb
    @["write"], # LangJavascript
    @["write"], # LangLua
    @["write"], # LangAsm
    @["write"], # LangNoir
    @["write"], # LangSmall
    @["write"]  # LangUnknown
  ]

  SKIPS*: array[Lang, seq[langstring]] = [
    @["codetracerWriteToTraceFile", "trace_begin", "trace_end", "__cyg_profile_func_enter", "__cyg_profile_func_exit"], # LangC
    @["codetracerWriteToTraceFile", "trace_begin", "trace_end", "__cyg_profile_func_enter", "__cyg_profile_func_exit"], # LangCpp
    @["codetracerWriteToTraceFile", "trace_begin", "trace_end"], # LangRust TODO
    @["codetracerWriteToTraceFile", "codetracerEnterCall", "codetracerExitCall", "codetracerLineProfile", "newFrame", "pushFrame", "setFrame", "popFrame", "nimFrame", "getTicks2", "getTicks", "asgnRefNoCycle", "usrToCell", "nimZeroMem"], # LangNim
    @["codetracer_enter_call", "codetracer_exit_call"], # LangGo TODO: just example function names for now
    @["codetracerWriteToTraceFile", "trace_begin", "trace_end", "__cyg_profile_func_enter", "__cyg_profile_func_exit"], # LangPascal
    @[], # LangPython
    @[], # LangRuby
    @[], # LangRubyDb
    @[], # LangJavascript
    @[], # LangLua
    @[], # LangAsm
    @[], # LangNoir
    @[], # LangSmall
    @[]  # LangUnknown
  ]

  ENTRY_FUNCTIONS*: array[Lang, seq[langstring]] = [
    @["main"], # LangC
    @["main"], # LangCpp
    @["main"], # LangRust
    @[
      "main",
      "NimMain",
      "NimMainModule",
      "NimMainInner"], # LangNim
    @["main.main"], # LangGo TODO: is it <package>.main ? is it always like that?
    @["main"], # LangPascal
    @[], # LangPython,
    @[], # LangRuby
    @[], # LangRuby
    @[], # LangJavascript
    @[], # LangLua
    @[], # LangAsm
    @[], # LangNoir
    @[], # LangSmall
    @[]  # LangUnknown
  ]

proc initTimer*(): Timer =
  Timer(point: 0)

proc startTimer*(self: Timer, operationCount: int) =
  self.point = epochTime()
  self.currentOpID = operationCount

proc stopTimer*(self: Timer) =
  self.point = 0
  self.currentOpID = 0

proc elapsed*(self: Timer): float =
  epochTime() - self.point

# Return elapsed time formatted
proc formatted*(self: Timer): string =
  let elapsed = self.elapsed()
  fmt"{elapsed:.3f}s"

proc compareMetadata*(self: Timer, operationCount: int): bool =
  return self.currentOpID == operationCount

proc asmName*(location: Location): langstring =
  ## Convert location object to string
  langstring(fmt"{location.path}:{location.functionName}")

proc text(value: Value, depth: int): string = #{.exportc: "textValue".}=
  ## Textual representation of a Value object
  var offset = repeat("  ", depth)
  var next = ""
  if value.isNil:
    next = "nil"
    return "$1$2" % [offset, next]
  next = case value.kind:
  of Seq, Set, HashSet, OrderedSet, Array, Varargs:
    "Sequence($1 $2):\n$3" % [
      if not value.typ.isNil: $value.typ.kind else: "",
      if not value.typ.isNil: $value.typ.langType else: "",
      value.elements.mapIt(text(it, depth + 1)).join("\n")
    ]
  of Instance:
    var members = ""
    for i, name  in value.typ.labels:
      members.add("$1: $2\n" % [$name, text(value.members[i], 0)])

    if len(members) > 0:
      members = members[0 ..< ^1]
    "Instance($1):\n$2" % [
      $value.typ.langType,
      members
    ]
  of FunctionKind:
    "function<" & $value.functionLabel & ">"
  of Int:
    $value.i
  of Float:
    $value.f
  of Bool:
    $value.b
  of String:
    "\"$1\"" % $value.text
  of Char:
    "'$1'" % $value.c
  of CString:
    "\"$1\"" % $value.cText
  of Ref:
    "Ref:\n$1" % text(value.refValue, depth + 1)
  of Enum, Enum16, Enum32:
    "Enum($1)" % $value.enumInt
    # TODO
    #"Enum($1 $2)" % [$value.enumInt, $value.typ.enumNames[value.enumInt]]
  of TypeKind.TableKind:
    var items = value.items.mapIt("$1: $2" % [text(it[0], 0), text(it[1], 0)])
    "Table($1):\n$2" % [$value.typ.langType, items.join("\n")]
  of Union:
    "Union($1)" % $value.typ.langType
  of Pointer:
    var res = "Pointer($1)" % $value.address
    if not value.refValue.isNil:
      res.add(":\n$1" % text(value.refValue, depth + 1))
    res
  of Raw:
    "Raw($1)" % $value.r
  of Variant:
    let fieldsText = if value.elements.len == 0: "" else: value.elements.mapIt(text(it, 0)).join(",")
    "$1::$2($3)" % [$value.typ.langType, $value.activeVariant, fieldsText]
  else:
    $value.kind
  result = "$1$2" % [offset, next]

proc `$`*(value: Value): string =
  ## Textual representation of a Value object
  try:
    return text(value, 0)
  except:
    return "<error>"

proc readableEnum*(value: Value): string =
  ## Textual representation of an enum value
  if value.kind in {Enum, Enum16, Enum32}:
    if value.enumInt <= value.typ.enumNames.high:
      result = $value.typ.enumNames[value.enumInt]
    else:
      result = $value.enumInt
  else:
    result = ""

proc toLangType*(typ: Type, lang: Lang): string =
  ## Original language textual representation of Type object, according to Lang
  if typ.isNil:
    return ""
  if lang == LangNim:
    result = case typ.kind:
      of Literal:
        toLowerAscii($typ.kind)
      of Seq, Set, HashSet, OrderedSet, Array, Varargs:
        var s = ""
        if typ.kind in {Seq, Set, Array, Varargs}:
          s = toLowerAscii($typ.kind)
        else:
          s = $typ.kind
        if typ.kind != Array:
          "$1[$2]" % [s, toLangType(typ.elementType, lang)]
        else:
          "$1[$2 $3]" % [s, $typ.length, toLangType(typ.elementType, lang)]
      of Instance:
        $typ.langType
      of Ref:
        "ref $1" % toLangType(typ.elementType, lang)
      of TableKind:
        $typ.langType
      of Variant:
        $typ.langType
      else:
        $typ.langType
  else:
    result = "!unimplemented"

proc isIntShape*(shape: Value): bool =
  ## Is value int shaped
  not shape.isNil and shape.kind == Int

proc isStringShape*(shape: Value): bool =
  ## Is value string shaped
  not shape.isNil and shape.kind == String

proc isNumberShape*(shape: Value): bool =
  ## Is value number shaped
  not shape.isNil and shape.kind in {Int, Float}

proc isFloatShape*(shape: Value): bool =
  ## Is value float shaped
  not shape.isNil and shape.kind == Float

func textReprDefault(value: Value, depth: int = 10): string

func textReprRust(value: Value, depth: int = 10, compact: bool = false): string

proc textRepr*(value: Value, depth: int = 10, lang: Lang = LangUnknown, compact: bool = false): string #{.exportc.}

proc testEq*(a: Value, b: Value, langType: bool = true): bool =
  ## Compare two values for equality
  if a.isNil or b.isNil:
    return a.isNil and b.isNil
  if a.kind != b.kind:
    # echo "no kind"
    return false
  # echo "eq ", a, " ", b
  case a.kind:
  of Seq, Set, HashSet, OrderedSet, Array, Varargs:
    if a.kind != b.kind or len(a.elements) != len(b.elements):
      # echo "not kind Seq"
      return false
    else:
      for j in 0..<len(a.elements):
        if not a.elements[j].testEq(b.elements[j]):
          return false
    return true
  of Instance:
    if a.elements.len != b.elements.len:
      return false
    if a.typ.langType != b.typ.langType:
      return false
    for i, element in a.elements:
      var bElement = b.elements[i]
      if not element.testEq(bElement):
        return false
    return true
  of Int:
    return a.i == b.i
  of Float:
    return a.f == b.f
  of String:
    return a.text == b.text
  of CString:
    return a.cText == b.cText
  of Char:
    return a.c == b.c
  of Bool:
    return a.b == b.b
  of Ref:
    return a.refValue.testEq(b.refValue, false)
  of Enum, Enum16, Enum32:
    return a.i == b.i
  of TableKind:
    if len(a.items) != len(b.items):
      return false
    else:
      for z in 0..<len(a.items):
        if not a.items[z][0].testEq(b.items[z][0]) or
           not a.items[z][1].testEq(b.items[z][1]):
          return false
    return true
  of Union:
    if a.kindValue.enumInt != b.kindValue.enumInt:
      return false
    # var c = a.kindValue
    return false
  of Pointer:
    return false #a.address == b.address
  of Raw:
    return a.r == b.r
  of Error:
    return a.msg == b.msg
  of FunctionKind:
    return a.functionLabel == b.functionLabel and a.signature == b.signature
  of TypeValue:
    if a.base != b.base:
      return false
    for label, member in a.dict:
      var bMember = b.dict[label]
      if bMember.isNil:
        return false
      if not member.testEq(bMember):
        return false
    return true
  of Tuple:
    if len(a.elements) != len(b.elements):
      return false
    return zip(a.elements, b.elements).allIt(it[0].testEq(it[1]))
  of Variant:
    if a.activeVariant != b.activeVariant:
      return false
    return zip(a.elements, b.elements).allIt(it[0].testEq(it[1]))
  of None:
    return true
  else:
    return false


func showable(value: Value): bool =
  ## Is value showabse. Currently always true
  true

proc simple*(value: Value): bool =
  ## Is value simple? not-Nil and one of {Int, Float, String, CString, Char, Bool,
  ##  Seq, Set, HashSet, OrderedSet, Array, Enum, Enum16, Enum32}
  not value.isNil and
  value.kind in {Int, Float, String, CString, Char, Bool,
    Seq, Set, HashSet, OrderedSet, Array, Enum, Enum16, Enum32}

proc simple*(typ: Type): bool =
  ## Is type simple? not-Nil and one of {Int, Float, String, CString, Char, Bool,
  ##  Seq, Set, HashSet, OrderedSet, Array, Enum, Enum16, Enum32}
  not typ.isNil and
  typ.kind in {Int, Float, String, CString, Char, Bool,
    Seq, Set, HashSet, OrderedSet, Array, Enum, Enum16, Enum32}

func `$`*(location: Location): string =
  ## Textual representation of location
  &"Location {location.path}:{location.line}"

iterator unionChildren*(value: Value): (defaultstring, Value) =
  ## Yield name and value for each value field
  for name, field in value.fields:
    yield (name, field)

func textReprDefault(value: Value, depth: int = 10): string =
  # a repr of a language value, we probably have to do this for each lang:
  # TODO language-specific display?
  # for now we mostly use the same repr
  if value.isNil:
    return "nil"
  if depth <= 0:
    return "#"
  result = case value.kind:
  of Int:
    $value.i
  of String:
    "\"$1\"" % $value.text
  of Bool:
    $value.b
  of Float:
    $value.f
  of Char:
    "'$1'" % $value.c
  of CString:
    "\"$1\"" % $value.cText
  of Enum:
    if value.enumInt < value.typ.enumNames.len:
      $value.typ.enumNames[value.enumInt]
    else:
      &"{value.typ.langType}({value.enumInt})"
  of Seq, Set, HashSet, OrderedSet, Array, Varargs:
    let elements = value.elements
    var l = ""
    let e = elements.mapIt(textReprDefault(it, depth - 1)).join(", ")
    let openText: array[6, string] = ["@[", "{", "HashSet{", "OrderedSet{", "[", "varargs["]
    let closeText: array[6, string] = ["]", "}", "}", "}", "]", "]"]
    let more = if value.partiallyExpanded: ".." else: ""
    l = openText[value.kind.int - Seq.int] & e
    l = l & more & closeText[value.kind.int - Seq.int]
    l
  of Instance:
    var record = ""
    for i, field in value.elements:
      if showable(field):
        record.add(&"{value.typ.labels[i]}:{textReprDefault(field, depth - 1)}")
        record.add(",")
      else:
        record.add(&"{value.typ.labels[i]}:..")
    if record.len > 0:
      record.setLen(record.len - 1)
    record = &"{value.typ.langType}({record})"
    record
  of Union:
    var record = ""
    for name, field in unionChildren(value):
      # echo "textRepr ", name
      # if showable(field):
      record.add(&"{name}:{textReprDefault(field, depth - 1)}")
      record.add(", ")
      # else:
        # record.add(&"{name}:..")
    if record.len > 0:
      record.setLen(record.len - 1)
    record = &"#{value.kindValue.textReprDefault}({record})"
    record
  of Ref:
    textReprDefault(value.refValue, depth)
  of Pointer:
    if not value.refValue.isNil: &"{value.address} -> ({textReprDefault(value.refValue)})" else: "NULL"
  of Recursion:
    "this"
  of Raw:
    "raw:" & $value.r
  of C:
    "c"
  of TableKind:
    let items = value.items
    var l = ""
    let more = if value.partiallyExpanded: ".." else: ""
    for item in items:
      l &= item.mapIt(textReprDefault(it, depth - 1)).join(": ") & " "
    l & more
    # $value.typ.langType & SUMMARY_EXPAND
  of Error:
    $value.msg
  of FunctionKind:
    &"function<{value.functionLabel}>" # $value.signature
  of TypeValue:
    $value.base
  of Tuple:
    var l = ""
    let elements = value.elements.mapIt(textReprDefault(it, depth - 1)).join(", ")
    l = "(" & elements & ")"
    l
  of Variant:
    var res: seq[string]
    if not value.activeVariantValue.isNil:
      fmt"""{value.typ.langType}::{textReprDefault(value.activeVariantValue)}"""
    elif value.activeFields.len != 0:
      var elements = value.elements[1..^1]
      var fieldsText: seq[string]
      fieldsText = elements.mapIt(textReprDefault(it, depth - 1))
      for i, v in fieldsText:
        res.add(fmt"{value.activeFields[i+1]}: {v}")
      fmt"""{value.typ.langType}::{textReprDefault(value.elements[0])}({res.join(", ")})"""
    else:
      var elements = value.elements
      res = value.elements.mapIt(textReprDefault(it, depth - 1))
      fmt"""{value.typ.langType}::{value.activeVariant}({res.join(", ")})"""
  of Html:
    "html"
  of TypeKind.None:
    "nil"
  of NonExpanded:
    ".."
  else:
    ""

func textReprRust(value: Value, depth: int = 10, compact: bool = false): string =
  let langType = if compact:
                   strutils.join(value.typ.langType.split("::")[1..^1], "::")
                 else:
                   $value.typ.langType
  if value.isNil:
    return "nil"
  if depth <= 0:
    return "#"
  result = case value.kind:
  of Int:
    if compact:
      fmt"{value.i}"
    else:
      fmt"{value.i}{value.typ.cType}"
  of String:
    "\"$1\"" % $value.text
  of Float:
    if compact:
      fmt"{value.f}"
    else:
      fmt"{value.f}{value.typ.cType}"
  of Seq, Array:
    let elements = value.elements
    var l = ""
    let e = elements.mapIt(textReprRust(it, depth - 1, compact)).join(", ")
    let more = if value.partiallyExpanded: ".." else: ""
    if (value.kind == Seq):
      l = "vec![" & e & more & "]"
    else:
      l = "[" & e & more & "]"
    l
  of Instance:
    var record = "{"
    for i, field in value.elements:
      if showable(field):
        record.add(&"{value.typ.labels[i]}:{textReprRust(field, depth - 1, compact)}")
        record.add(",")
      else:
        record.add(&"{value.typ.labels[i]}:..")
    if record.len > 0:
      record.setLen(record.len - 1)
    record.add("}")
    record = &"{langType}{record}"
    record
  of Ref:
     &"ref {langType}: {textReprRust(value.refValue, depth, compact)}"
  of Pointer:
    if not value.refValue.isNil: &"{value.address} -> *{langType}({textReprRust(value.refValue, depth, compact)})" else: "NULL"
  of FunctionKind:
    &"fn {value.functionLabel}: {value.signature}" # $value.signature
  of Tuple:
    let elements = value.elements.mapIt(textReprRust(it, depth - 1, compact)).join(", ")
    "(" & elements & ")"
  of Variant:
    if value.activeVariantValue.kind == Instance:
      var record = "{"
      for i, field in value.activeVariantValue.elements:
        if showable(field):
          record.add(&"{value.activeVariantValue.typ.labels[i]}:{textReprRust(field, depth - 1, compact)}")
          record.add(",")
        else:
          record.add(&"{value.activeVariantValue.typ.labels[i]}:..")
      if record.len > 0:
        record.setLen(record.len - 1)
        record.add("}")
      fmt"""{value.activeVariant}{record}"""
    elif value.activeVariantValue.kind == Variant and value.activeVariantValue.activeVariantValue.kind == Instance:
      fmt"""{textReprRust(value.activeVariantValue, depth, compact)}"""
    elif value.activeVariantValue.kind == None:
      fmt"""{langType}::{value.activeVariant}"""
    else:
      fmt"""{value.activeVariant}({textReprRust(value.activeVariantValue, depth, compact)})"""
  else:
    textReprDefault(value, depth)

proc textRepr*(value: Value, depth: int = 10, lang: Lang = LangUnknown, compact: bool = false): string = #{.exportc.} =
  ## Text representation of Value, depending on lang
  case lang:
    of LangUnknown:
      if CURRENT_LANG != LangUnknown:
        textRepr(value, depth, CURRENT_LANG, compact)
      else:
        textReprDefault(value, depth)
    of LangRust:
      textReprRust(value, depth, compact)
    else:
      textReprDefault(value, depth)

template bug*(message: string) =
  echo "BUG [" & instantiationInfo().filename & ":" & $instantiationInfo().line & "]:"
  echo message
  quit(1)

template error*(message: string) =
  echo "ERROR [" & instantiationInfo().filename & ":" & $instantiationInfo().line & "]:"
  echo message
  quit(1)

proc toLineFlowKind*(flow: FlowViewUpdate, position: int, finished: bool): LineFlowKind =
  ## Return the LineFlowKind for  FlowViewUpdate at position and if finished or not
  if flow.isNil:
    LineFlowUnknown
  elif position in flow.relevantStepCount:
    LineFlowHit
  elif finished:
    LineFlowSkip
  else:
    LineFlowUnknown

proc newNotification*(kind: NotificationKind, text: string, isOperationStatus: bool = false, actions: seq[NotificationAction] = @[]): Notification =
  ## Init new notification
  Notification(
    kind: kind,
    text: text,
    time: getTime().toUnix,
    active: true,
    isOperationStatus: isOperationStatus,
    actions: actions
    )

proc newNotificationButtonAction*(name: langstring, handler: proc: void): NotificationAction =
  NotificationAction(
    name: name,
    handler: handler,
    kind: NotificationActionKind.ButtonAction
  )

const
  GREEN_COLOR* = "\x1b[92m"
  YELLOW_COLOR* = "\x1b[93m"
  RED_COLOR* = "\x1b[91m"
  BLUE_COLOR* = "\x1b[94m"
  RESET* = "\x1b[0m"

export task_and_event

type Symbol* = object
  name*: string
  path*: string
  line*: int
  kind*: string
