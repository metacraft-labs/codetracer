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
    metadata*: langstring

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

  FlowMode* {.pure.} = enum
    ## The engine's flow *query* mode — NOT a view granularity.
    ##
    ## The mirror of this enum is `FlowMode` in
    ## `src/db-backend/src/task.rs`; `FlowModeWireNames` below is the shared
    ## vocabulary, and `src/db-backend/tests/flow_mode_wire_test.rs` reads
    ## this file so the two cannot drift apart without a test failing.
    ##
    ## Do not confuse this with `viewmodels/flow_vm.FlowMode`, which has
    ## three members (`fmCall | fmLine | fmFunction`) and describes how the
    ## *panel* renders. That confusion is exactly what the old ordinal wire
    ## form let through unnoticed: `fmLine` would have arrived here as
    ## `Diff`, a completely different query, with no error anywhere.
    Call,
    Diff,

  CtLoadFlowArguments* = ref object
    flowMode*: FlowMode
    location*: Location # empty/ignored for FlowMode.Diff

# The vocabulary itself lives in `common/flow_mode_wire.nim`, which the
# db-backend's `flow_mode_wire_test.rs` reads. This assertion is what ties
# *this* enum to it: adding a third variant here without giving it a wire
# spelling is a compile error, not a runtime surprise.
static:
  doAssert FlowModeWireNames.len == ord(FlowMode.high) + 1,
    "every FlowMode variant needs a wire spelling in common/flow_mode_wire.nim"

proc toWireName*(mode: FlowMode): string =
  ## The wire spelling the replay engine parses.
  flowModeWireName(ord(mode))

proc parseFlowModeWireName*(name: string): FlowMode =
  ## Inverse of `toWireName`. Raises on an unknown spelling rather than
  ## defaulting: a silently-wrong flow mode is the defect this replaced.
  let ordinal = flowModeWireOrdinal(name)
  if ordinal < 0:
    raise newException(ValueError,
      "unknown ct/load-flow flowMode `" & name & "`")
  FlowMode(ordinal)



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
