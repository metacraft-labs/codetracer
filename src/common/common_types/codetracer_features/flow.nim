type
  LoopID* = int

  LineFlowKind* = enum ## Line Flow Kinds
    LineFlowHit,
    LineFlowSkip,
    LineFlowUnknown

  FlowUI* = enum ## Flow types
    FlowParallel,
    FlowInline,
    FlowMultiline

  BranchState* = enum ## State of a branch in a debugger, either taken, untaken or unknown
    Unknown,
    Taken,
    NotTaken

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

  FlowQuery* = ref object
    location*: Location
    taskId*:   TaskId

  FlowEvent* = object
    kind*: EventLogKind
    text*: langstring
    # contains step_id for db-backend
    rrTicks*: int64
  FlowStep* = object
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
    commentLines*: seq[int]

  FlowViewUpdate* = ref FlowViewUpdateObject ## FlowViewUpdate obejct ref

  FlowUpdate* = ref object
    viewUpdates*: array[EditorView, FlowViewUpdate]
    location*: Location
    error*: bool
    errorMessage*: langstring
    finished*: bool
    status*: FlowUpdateState

  Loop* = object
    base*: int
    baseIteration*: int
    internal*: seq[int]
    first*: int
    last*: int
    registeredLine*: int
    iteration*: int
    stepCounts*: seq[int]
    rrTicksForIterations*: seq[int]

  FlowExpression* = object
    kind*: TokenKind
    base*: langstring
    field*: langstring
    collection*: langstring
    index*: langstring
    expression*: langstring
    startCol*: langstring
    endCol*: langstring

  FlowShape* = ref object
    viewUpdates*: array[EditorView, FlowViewShape]

  LoopShape* = ref object
    base*: int
    internal*: seq[LoopID]
    first*: int
    last*: int

  FlowViewShape* = ref object
    loops*: seq[LoopShape]
    expressions*: TableLike[int, seq[FlowExpression]]


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
