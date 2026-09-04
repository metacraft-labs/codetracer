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

  BranchExtent* = object
    ## The lines an arm of a conditional occupies, ITS HEADER EXCLUDED.
    ##
    ## Mirrors `task.rs`'s `BranchExtent`, which crosses as
    ## `{ "firstLine": n, "lastLine": m }` — the wire is an unchecked
    ## `JsObject.to(T)` cast (`frontend/dap.nim`), so the field names here are
    ## the contract and there is no parser to catch a disagreement.
    ##
    ## `Omniscience-Flow.md` § *Dimming means "the run did not take this
    ## branch"*: "What is dimmed is the arm's interior, not its header. The
    ## line carrying the condition is evidence — for an `else if`, it is the
    ## line whose test was evaluated and came out false, so it demonstrably
    ## *did* run."
    firstLine*: int
    lastLine*: int

  BranchesTaken* = object ## Table of branch states
    table*: TableLike[int, BranchState]
    extents*: TableLike[int, BranchExtent]
      ## `header_line` -> the interior of the arm that header introduces, for
      ## the headers the backend could locate a body for.
      ##
      ## KEYED THE SAME WAY AS `table` ON PURPOSE: a renderer asking "is this
      ## line inside an arm that was not taken" joins the two by header line
      ## and needs no third index.
      ##
      ## Absent for a header whose body node the language's grammar
      ## configuration did not name, and absent entirely on a window that did
      ## not come from the backend at all (the review-dataset adapter builds
      ## one by hand). Both are the same case for the reader: the state is
      ## known and the extent is not, so nothing is claimed about the arm's
      ## lines and none of them is dimmed.

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



## `toLineFlowKind` WAS HERE, AND IS DELETED RATHER THAN CORRECTED.
##
## It was the second statement of the per-line flow rule —
##
##     if position in flow.relevantStepCount: LineFlowHit
##     elif finished:                         LineFlowSkip
##     else:                                  LineFlowUnknown
##
## — and `ui/flow_line_styles.nim`'s header named it as the proc that module
## deliberately duplicated, because an *included* module cannot be called from
## one that must compile against both copies of `FlowViewUpdate`.
##
## That rule is the defect reported as *"I jump into a function and all of its
## lines before the current line get dimmed"*, and
## `GUI/Debugging-Features/Omniscience-Flow.md` § *Dimming means "the run did
## not take this branch"* now forbids it: a line is dimmed when, and only when,
## it belongs to an arm of a conditional the run did not enter. Not having
## executed is not, by itself, a reason to dim a line.
##
## Deleted and not fixed because it had NO production caller — only the
## `flow_line_styles`-era duplicate did the work — and a dead proc stating a
## rule the spec forbids is worse than no proc at all: it is a correct-looking
## thing for the next reader to reach for. `flowStyledLines` in
## `ui/flow_line_styles.nim` is the one implementation, and `LineFlowKind`
## itself is left in place because it is a wire-adjacent enum rather than a
## decision.
