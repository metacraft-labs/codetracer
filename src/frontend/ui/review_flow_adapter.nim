## The review-dataset → `FlowUpdate` adapter (RV-5, superseding DR-R6).
##
##   "Flow data from the associated trace is rendered using the **same
##    visualization system** as normal debugging (`flowStyleLines`,
##    `applyEventualStylesLines`). […] **The overlay is driven by the dataset,
##    not by a live recording.** […] It follows that the adapter, not the
##    replay backend, is the thing standing between a dataset and a flow
##    overlay."
##   — `codetracer-specs/DeepReview/DeepReview-GUI.md` §7
##
## A review dataset carries flow **per invocation** (`DeepReviewFunctionFlow` =
## one call of one function, keyed by `functionKey` + `executionIndex`), while
## the editor's flow model is **per view** (`FlowUpdate.viewUpdates[view]`, one
## window for one location). This module is the whole of the difference: it
## picks one invocation and rewrites it into the shape
## `FlowViewUpdate::new()` (`src/db-backend/src/task.rs:801`) would have
## produced for it, so everything downstream — `FlowComponent.onUpdatedFlow`,
## the loop controls, `flowStyleLines` — runs unmodified.
##
## Why it has no imports
## ---------------------
## Both its input (`DeepReviewFileData`) and its output (`FlowUpdate`) are
## declared in *included* modules, so each exists twice with incompatible field
## types: once through `common/types.nim` (`langstring = string`,
## `TableLike = Table`) and once through `frontend/types.nim`
## (`langstring = cstring`, `TableLike = JsAssoc`). A module naming either copy
## would only be usable from one of the two worlds — the constraint
## `viewmodels/state_vm.nim` and `viewmodels/review_entry.nim` both record.
##
## So the adapter is in two halves:
##
##   * `reviewFlowPlan` — generic over the dataset, producing a plain
##     `ReviewFlowPlan` value in which no `common/types` flavour appears. This
##     is where every *decision* is made: which invocation, which lines the
##     function spans, which loop each step belongs to, which lines were
##     executed.
##   * `fillFlowUpdate` — generic over the `FlowUpdate` family, copying that
##     plan into a real `FlowUpdate`. This is where the *shape* obligations are
##     met: the well-formed empty `branchesTaken`, the placeholder `loops[0]`,
##     the synthesised `Location`.
##
## Both are instantiated by the renderer (`ui/editor.nim` and
## `ui/unified_diff.nim`, over the `cstring` flavour) and by the headless suite
## (over the native one), so the same code runs in both.
##
## One obligation this places on a caller: because the module imports nothing,
## `fillFlowUpdate`'s `[]=` on a `TableLike` resolves at the *instantiation*
## site, so whoever calls it must have `std/tables` (native) or `jsffi` (the
## renderer, via `ui_imports`) in scope. A caller that does not gets a
## compile-time "type mismatch" on the assignment, not a silent wrong answer.
##
## The value-fidelity decision (recorded in RV-5)
## ----------------------------------------------
## `FlowStep.beforeValues` / `afterValues` want structured `Value`s;
## `DeepReviewVariableValue.value` is a **pre-rendered string**. Both collectors
## render at collection time — `codetracer-native-backend`'s `.dr` chunks carry
## `value_ref`/`type_ref` offsets into a string table
## (`json_export.rs:convert_flow_chunk`), and the materialized collector calls
## `value.text_repr()` and throws the structure away
## (`db-backend/src/deepreview/collector.rs:293`). Emitting structured values
## therefore means a wire-format change in one repo and a schema change in the
## other, which RV-5 does not undertake.
##
## The interim, chosen deliberately and not silently: `synthesizedValueKind`
## below maps the collector's `kind` string onto a `TypeKind` and the adapter
## fills the matching scalar field, so a value that *is* a recognised scalar
## renders through the normal atom path with the normal per-type class
## (`value-int`, `value-string`, …) and reads back identically to what the
## collector rendered. Anything else becomes `TypeKind.Raw` carrying the
## rendered text verbatim, which `ui/value.nim:1073` prints as-is.
##
## What that costs, in full:
##   1. **No expansion.** A struct, vector or map arrives as one `Raw` string.
##      There are no `members` / `elements` / `items` to expand, so the
##      expansion triangle does nothing on a review's values.
##   2. **Add to Scratchpad carries text, not a value.** The scratchpad
##      operates on `Value` structure; a `Raw` gives it a string.
##   3. **Type-aware formatting only for the scalars named below.** A language
##      type the map does not recognise (`Vec<u8>`, `Option<T>`, a class name)
##      falls back to `Raw` and is styled as raw text.
##   4. **Truncation is terminal.** `truncated: true` means the collector cut
##      the text; there is no structure left to re-render at full width, so the
##      ellipsis is all a reviewer can ever see.
##
## WHAT UD-3 CHANGED, AND WHAT IT DID NOT
## --------------------------------------
## Half of the above is now history and half of it is not, and the difference
## is WHICH COLLECTOR wrote the dataset:
##
##   * The **materialized** collector emits the structure it always had.
##     `db-backend/src/deepreview/json.rs` carries
##     `VariableValueData.structured: Option<Value>` beside the rendering, and
##     `fillFlowUpdate`'s file-taking overload at the foot of this module
##     copies it straight into `FlowStep.beforeValues`. For such a dataset the
##     synthesis below does not run at all: costs 1 and 3 are gone, and the
##     data behind 2 and 4 is present (what those two still need is the chip's
##     *interactions*, which the review's band does not wire — UD-4).
##   * The **native `.dr`** collector still emits none. Its value pool interns
##     one string per value (`json_export.rs::convert_flow_chunk`:
##     `value_ref`, `type_ref`), so there is nothing to serialize without a new
##     chunk kind in the binary format. For such a dataset everything below is
##     exactly as RV-5 left it, all four costs included.
##
## So `synthesizedValueKind` is now the FALLBACK rather than the answer, and it
## must stay: it is the whole native-collector case, not a legacy path.

type
  ReviewFlowValue* = object
    ## One captured variable at one step, exactly as the dataset carries it.
    name*: string
    value*: string   ## pre-rendered by the collector — see the header
    kind*: string    ## the collector's language type name ("int", "i32", …)
    truncated*: bool

  ReviewFlowStep* = object
    ## `DeepReviewFlowStep` with the field names `FlowStep` uses.
    ## `line` becomes `position`; `loopId` becomes `loop`; `stepCount`,
    ## `rrTicks` and `iteration` carry over unchanged.
    position*: int
    loop*: int
    iteration*: int
    stepCount*: int
    rrTicks*: int
    values*: seq[ReviewFlowValue]

  ReviewFlowLoop* = object
    ## `DeepReviewLoop` in `Loop`'s shape.
    ##
    ## `stepCounts` and `rrTicksForIterations` are *derived from the steps*
    ## rather than invented: `rrTicksForIterations[i]` must be the trace tick at
    ## which the loop HEADER was passed for the i-th time, because that is what
    ## `flow_loop_math.activeIterationForTicks` reads to decide which iteration
    ## the reader is inside. Anything else makes the loop slider point at the
    ## wrong iteration.
    base*: int
    baseIteration*: int
    internal*: seq[int]
    first*: int
    last*: int
    registeredLine*: int
    iteration*: int
    stepCounts*: seq[int]
    rrTicksForIterations*: seq[int]

  ReviewPositionStepCounts* = object
    ## One entry of `FlowViewUpdate.positionStepCounts`: every step count that
    ## landed on `position`, in visit order.
    position*: int
    stepCounts*: seq[int]

  ReviewInvocation* = object
    ## One selectable invocation — one entry of `DeepReviewFileData.flow`.
    ##
    ## `index` is its position in that seq and is what the selector moves
    ## through; `executionIndex` is what the collector called it. They agree in
    ## practice and are kept apart on purpose, because nothing in the format
    ## promises the seq is ordered by execution index or free of gaps.
    index*: int
    functionKey*: string
    executionIndex*: int
    stepCount*: int
    firstLine*: int
    lastLine*: int

  ReviewFunctionInvocations* = object
    ## Every invocation of one function of one file, plus the fact that makes
    ## RV-4's gap 8 legible: a function the changeset only *calls* is recorded
    ## with a real `callCount` and no flow at all.
    functionKey*: string
    startLine*: int
    endLine*: int
    callCount*: int
    invocations*: seq[ReviewInvocation]

  ReviewFlowPlan* = object
    ## Everything a `FlowUpdate` for one invocation needs, with no
    ## `common/types` flavour in sight.
    ##
    ## `found` is false for "this file has no such invocation" — an empty
    ## changeset, a function with coverage but no flow (gap 8), or an index off
    ## the end. A plan that is not `found` must not be pushed into the editor:
    ## a `FlowUpdate` spanning no lines would repaint the whole overlay away.
    found*: bool
    path*: string
    functionKey*: string
    executionIndex*: int
    invocationIndex*: int
    invocationCount*: int
    functionFirst*: int
    functionLast*: int
    line*: int
      ## Where the flow "is": the first line of the invocation's first step.
      ## `Location.line` on a review has no debugger position to describe, so
      ## it names the entry point of the call being displayed.
    steps*: seq[ReviewFlowStep]
    loops*: seq[ReviewFlowLoop]
    relevantStepCount*: seq[int]
      ## Line numbers the invocation visited. Named after the field it fills,
      ## which the backend also fills with lines rather than step counts
      ## (`flow_preloader.rs:761`).
    commentLines*: seq[int]
    positionStepCounts*: seq[ReviewPositionStepCounts]

  ReviewValueKind* = enum
    ## The subset of `TypeKind` the synthesised values can be. Spelled as its
    ## own enum, not as `TypeKind`, because naming `TypeKind` would import one
    ## of the two type worlds — see the header.
    rvkInt
    rvkFloat
    rvkBool
    rvkString
    rvkChar
    rvkRaw

const
  NoInvocation* = -1
    ## `reviewInvocationIndex`'s answer for "this function has no flow here".

# ---------------------------------------------------------------------------
# Reading the dataset
# ---------------------------------------------------------------------------

proc reviewInvocations*[F](file: F): seq[ReviewInvocation] =
  ## Every invocation the file carries flow for, in dataset order.
  ##
  ## `firstLine` / `lastLine` are the span of the invocation's own steps. They
  ## are the fallback the synthesised `Location` uses when the dataset names no
  ## function covering the key — see `reviewFunctionSpan`.
  result = @[]
  when compiles(file.isNil):
    if file.isNil:
      return
  var index = 0
  for flow in file.flow:
    var first = 0
    var last = 0
    for step in flow.steps:
      if step.line <= 0:
        continue
      if first == 0 or step.line < first:
        first = step.line
      if step.line > last:
        last = step.line
    result.add(ReviewInvocation(
      index: index,
      functionKey: $flow.functionKey,
      executionIndex: flow.executionIndex,
      stepCount: flow.steps.len,
      firstLine: first,
      lastLine: last))
    index += 1

proc reviewFunctionInvocations*[F](file: F): seq[ReviewFunctionInvocations] =
  ## The file's functions, each with the invocations the dataset carries for it.
  ##
  ## Every function in `DeepReviewFileData.functions` is listed, **including the
  ## ones with no flow**. That is RV-4's gap 8 made visible rather than hidden:
  ## "a function the diff only CALLS" has a real `callCount` and no flow entry,
  ## because a call is anchored when one of its own steps lands on a changed
  ## line. A reviewer who expects that function's overlay gets an entry with an
  ## empty `invocations` seq — which the selector renders as "no recorded
  ## invocation" — rather than an empty overlay with no explanation, or
  ## somebody else's flow.
  ##
  ## A `functionKey` that matches no declared function still gets an entry, so
  ## flow is never dropped because the coverage half of the dataset is thinner
  ## than the flow half.
  result = @[]
  when compiles(file.isNil):
    if file.isNil:
      return
  let invocations = reviewInvocations(file)
  for fn in file.functions:
    let name = $fn.name
    var mine: seq[ReviewInvocation] = @[]
    for invocation in invocations:
      if invocation.functionKey == name:
        mine.add(invocation)
    result.add(ReviewFunctionInvocations(
      functionKey: name,
      startLine: fn.startLine,
      endLine: fn.endLine,
      callCount: fn.callCount,
      invocations: mine))
  for invocation in invocations:
    var known = false
    for entry in result:
      if entry.functionKey == invocation.functionKey:
        known = true
        break
    if known:
      continue
    result.add(ReviewFunctionInvocations(
      functionKey: invocation.functionKey,
      startLine: invocation.firstLine,
      endLine: invocation.lastLine,
      callCount: 0,
      invocations: @[invocation]))

proc reviewFunctionAt*(functions: openArray[ReviewFunctionInvocations];
                       line: int): int =
  ## Index of the function whose declared span contains `line`, or -1.
  ##
  ## The innermost match wins, so a nested function is preferred over the
  ## enclosing one. This is what anchors the invocation selector: the control
  ## belongs to the function the reader is looking at, exactly as the loop
  ## slider belongs to the loop the reader is looking at (§7).
  result = -1
  var bestSpan = 0
  for i in 0 ..< functions.len:
    let fn = functions[i]
    if fn.startLine <= 0 or fn.endLine < fn.startLine:
      continue
    if line < fn.startLine or line > fn.endLine:
      continue
    let span = fn.endLine - fn.startLine
    if result < 0 or span < bestSpan:
      result = i
      bestSpan = span

proc reviewInvocationIndex*(functions: openArray[ReviewFunctionInvocations];
                            functionKey: string; ordinal: int): int =
  ## The dataset index of the `ordinal`-th invocation of `functionKey`, or
  ## `NoInvocation`.
  ##
  ## `ordinal` is what the in-editor selector counts (0-based, "call 1 of 4"),
  ## and it is clamped rather than wrapped: pressing "next" on the last
  ## invocation stays on the last one, the way the loop iteration slider stops
  ## at the last iteration.
  for fn in functions:
    if fn.functionKey != functionKey:
      continue
    if fn.invocations.len == 0:
      return NoInvocation
    var wanted = ordinal
    if wanted < 0:
      wanted = 0
    if wanted > fn.invocations.high:
      wanted = fn.invocations.high
    return fn.invocations[wanted].index
  NoInvocation

# ---------------------------------------------------------------------------
# The plan
# ---------------------------------------------------------------------------

proc reviewFunctionSpan[F](file: F; functionKey: string;
                           fallbackFirst, fallbackLast: int): (int, int) =
  ## The `functionFirst` / `functionLast` a synthesised `Location` must carry.
  ##
  ## `flowStyleLines` iterates `functionFirst + 1 .. functionLast`, so these two
  ## numbers decide which lines the overlay can touch at all. They come from
  ## `DeepReviewFunctionCoverage.startLine` / `endLine` when the dataset
  ## declares the function, and from the span of the invocation's own steps when
  ## it does not — never from nothing, because a zero span silently disables the
  ## overlay.
  for fn in file.functions:
    if $fn.name == functionKey and fn.startLine > 0 and
       fn.endLine >= fn.startLine:
      return (fn.startLine, fn.endLine)
  (fallbackFirst, fallbackLast)

proc reviewFlowPlan*[F](file: F; invocationIndex: int): ReviewFlowPlan =
  ## The adapter's decision half: one invocation of one file, in `FlowUpdate`'s
  ## vocabulary.
  ##
  ## An out-of-range index, a nil file or a file with no flow yields
  ## `found: false` and nothing else — see `ReviewFlowPlan.found`.
  result = ReviewFlowPlan(
    found: false, invocationIndex: invocationIndex, steps: @[], loops: @[],
    relevantStepCount: @[], commentLines: @[], positionStepCounts: @[])
  when compiles(file.isNil):
    if file.isNil:
      return
  let invocations = reviewInvocations(file)
  result.invocationCount = invocations.len
  result.path = $file.path
  if invocationIndex < 0 or invocationIndex >= invocations.len:
    return

  let selected = invocations[invocationIndex]
  result.found = true
  result.functionKey = selected.functionKey
  result.executionIndex = selected.executionIndex
  let (first, last) = reviewFunctionSpan(
    file, selected.functionKey, selected.firstLine, selected.lastLine)
  result.functionFirst = first
  result.functionLast = last

  let flow = file.flow[invocationIndex]

  # `loops[0]` is the placeholder `Loop::default()` the backend always emits,
  # and `FlowStep.loop` indexes this seq — RV-4 records that a review's
  # `loopId` is already "the loop's index within its function's flow view", so
  # the indices carry over rather than being renumbered. A step outside any
  # loop carries `loopId: -1` in the dataset and must land on the placeholder.
  #
  # The array is sized by the loops **this invocation actually entered**, not by
  # every loop the file declares: `DeepReviewFileData.loops` is per file, so a
  # function that contains no loop would otherwise be handed its neighbour's,
  # and `branchesTaken` would grow a row for a loop that never ran. The backend
  # does the same — `process_loops` pushes a `Loop` when the walker first
  # crosses its header, never before.
  var maxLoopId = 0
  for step in flow.steps:
    if step.loopId > maxLoopId:
      maxLoopId = step.loopId
  result.loops = newSeq[ReviewFlowLoop](maxLoopId + 1)
  for index in 0 .. maxLoopId:
    # `base` is the *parent* loop's index and -1 means "not nested"
    # (`ui/flow.nim:339`, `:1058`). A review dataset carries no nesting, so
    # every loop it describes is top-level; claiming a parent would send
    # `calculateLoopContainerWidth` looking up a `loopStates` entry that does
    # not exist.
    result.loops[index] = ReviewFlowLoop(
      base: -1, internal: @[], stepCounts: @[], rrTicksForIterations: @[])
  for lp in file.loops:
    if lp.loopId <= 0 or lp.loopId > maxLoopId:
      continue
    result.loops[lp.loopId].first = lp.startLine
    result.loops[lp.loopId].last = lp.endLine
    result.loops[lp.loopId].registeredLine =
      if lp.headerLine > 0: lp.headerLine else: lp.startLine

  var stepCount = 0
  for step in flow.steps:
    let loopIndex =
      if step.loopId > 0 and step.loopId < result.loops.len: step.loopId else: 0
    var values: seq[ReviewFlowValue] = @[]
    for v in step.values:
      values.add(ReviewFlowValue(
        name: $v.name, value: $v.value, kind: $v.kind, truncated: v.truncated))
    # `stepCount` is re-derived from the step's position in the invocation
    # rather than trusted from the dataset. `FlowComponent` keys its per-step
    # DOM by it (`stepNodes[step.stepCount]`), so two steps sharing a number
    # would make the second overwrite the first's node, and a step no number
    # reaches would render nowhere. Both collectors number them this way
    # already; re-deriving makes the property belong to the adapter rather than
    # to whichever collector happened to produce this file.
    result.steps.add(ReviewFlowStep(
      position: step.line,
      loop: loopIndex,
      iteration: max(step.iteration, 0),
      stepCount: stepCount,
      rrTicks: step.rrTicks,
      values: values))

    if step.line > 0:
      if step.line notin result.relevantStepCount:
        result.relevantStepCount.add(step.line)
      var recorded = false
      for i in 0 ..< result.positionStepCounts.len:
        if result.positionStepCounts[i].position == step.line:
          result.positionStepCounts[i].stepCounts.add(stepCount)
          recorded = true
          break
      if not recorded:
        result.positionStepCounts.add(ReviewPositionStepCounts(
          position: step.line, stepCounts: @[stepCount]))

    # The loop's per-iteration ticks are the ticks at which its header was
    # passed, so only a step ON the header line opens an iteration.
    if loopIndex > 0 and step.line == result.loops[loopIndex].registeredLine:
      result.loops[loopIndex].rrTicksForIterations.add(step.rrTicks)
      result.loops[loopIndex].stepCounts.add(stepCount)
      result.loops[loopIndex].iteration =
        max(result.loops[loopIndex].rrTicksForIterations.high, 0)

    stepCount += 1

  if result.steps.len > 0:
    result.line = result.steps[0].position

# ---------------------------------------------------------------------------
# The synthesised values
# ---------------------------------------------------------------------------

func lowerAsciiCopy(s: string): string =
  result = newString(s.len)
  for i in 0 ..< s.len:
    let c = s[i]
    result[i] = if c >= 'A' and c <= 'Z': chr(ord(c) + 32) else: c

func unquoted(s: string): string =
  ## The collector renders a string value *with* its quotes (`"hello"`), while
  ## `Value`'s own `$` adds them again for `TypeKind.String`. Stripping one pair
  ## here is what makes a synthesised value read back as exactly what the
  ## collector rendered rather than as `""hello""`.
  if s.len >= 2 and ((s[0] == '"' and s[^1] == '"') or
                     (s[0] == '\'' and s[^1] == '\'')):
    s[1 ..< s.high]
  else:
    s

func synthesizedValueKind*(kind: string): ReviewValueKind =
  ## Map a collector's language type name onto the `TypeKind` a synthesised
  ## `Value` should carry.
  ##
  ## The recognised set is deliberately the scalars — anything compound is
  ## `rvkRaw`, because a review carries no structure to expand (see the
  ## header's cost 1). The names cover what the two collectors emit today: the
  ## native one writes the generic spellings ("int", "string", "bool"), the
  ## materialized one writes the language's own type name, so Rust's `i32` /
  ## `f64` / `&str` and Python's `int` / `str` are matched too.
  let k = lowerAsciiCopy(kind)
  case k
  of "int", "integer", "i8", "i16", "i32", "i64", "i128", "isize",
     "u8", "u16", "u32", "u64", "u128", "usize", "long", "short", "byte",
     "bigint":
    rvkInt
  of "float", "double", "f32", "f64", "real":
    rvkFloat
  of "bool", "boolean":
    rvkBool
  of "string", "str", "&str", "cstring", "text":
    rvkString
  of "char", "character", "rune":
    rvkChar
  else:
    rvkRaw

# ---------------------------------------------------------------------------
# The values, as the overlay draws them
# ---------------------------------------------------------------------------
#
#   "Preserve existing interaction patterns such as loop sliders and **inline
#    values**."  — DeepReview-GUI.md §4.4
#
# A review draws ONE value strip per line, where the debugger's flow panel has a
# whole column per loop iteration. Everything below is the consequence: a line
# recorded several times in one invocation has to name which recording it is
# showing, and that is the loop iteration control's job. These procs are here
# rather than in `viewmodel/viewmodels/review_flow_overlay.nim` because they are
# about the *plan* and nothing else — both hosts need them, and the full-file
# editor (§5.3) has no diff document to map through.

type
  ReviewValueChip* = object
    ## One captured variable, in the shape the standard Omniscience value chip
    ## renders it.
    ##
    ## `name` is drawn in the name chip and `text` in the value box, which is
    ## the pair the debugger's own `ui/flow.flowSimpleValue` builds
    ## (`ct-omni-name` plus `flow-parallel-value-box
    ## flow-parallel-value-before-only`) and the pair the deleted standalone
    ## review panel drew straight from the dataset. `text` already carries the
    ## collector's truncation marker, so a host never has to know about
    ## `truncated` to render correctly — the flag is kept so a host that wants
    ## to *style* a cut value can.
    name*: string
    text*: string
    truncated*: bool

const
  ReviewValueNameClass* =
    "ct-omni-name flow-parallel-value-name review-flow-value review-flow-value-name"
    ## The class the *name* half of an inline value chip carries.
    ##
    ## §5.3: "Use the standard Omniscience appearance / Do not create a separate
    ## DeepReview-specific inline style." So the two classes that do the drawing
    ## are the debugger's own — `ct-omni-name` is what `ui/flow.flowSimpleValue`
    ## puts on a value's name, and `flow-parallel-value-name` is what
    ## `styles/components/flow.styl` styles as the name chip. The last two are
    ## markers carrying only the box model an *injected* span needs and a flex
    ## child of the flow panel's value column does not.
  ReviewValueBoxClass* =
    "flow-parallel-value-box flow-parallel-value-before-only review-flow-value review-flow-value-box"
    ## The class the *value* half carries — the exact pair
    ## `ui/flow.flowSimpleValue` applies to a before-only value box, which is
    ## the mode a review is always in (the dataset carries one rendered value
    ## per name per step).
  ReviewInlineValueNameClass* =
    ReviewValueNameClass & " review-inline-value"
  ReviewInlineValueBoxClass* =
    ReviewValueBoxClass & " review-inline-value"
    ## The same chip, drawn as Monaco **injected text** instead of as an
    ## element of the debugger's band (UD-3).
    ##
    ## The extra marker exists because the two surfaces need opposite things
    ## from CSS. The diff tab's band is built out of the debugger's own
    ## elements — a `.ct-omni-value` flex container holding the name and the
    ## box — and therefore needs NO styling of its own; §5.3's full-file
    ## surface annotates the code line itself, where an injected span cannot
    ## have that container and must restate the box model it would have
    ## provided. Putting the restatement on `review-flow-value` made it apply
    ## to both and stripped the band's chips of the debugger's own padding, so
    ## the marker that *locates* a chip and the marker that *styles* an
    ## injected one are now two different things.

func reviewValueChipName*(chip: ReviewValueChip): string =
  ## The text of the name chip.
  ##
  ## Angle-bracketed, which is how the deleted standalone panel drew a review's
  ## values, and what makes a strip parseable when it is injected into the code
  ## line rather than laid out in the flow panel's own column: without a
  ## delimiter, `x 10 y 20` is ambiguous about where one pair ends.
  "<" & chip.name & ">"

func reviewValueChips*(step: ReviewFlowStep): seq[ReviewValueChip] =
  ## One step's captured variables, in dataset order.
  ##
  ## Dataset order rather than sorted, because it is the collector's order and
  ## the collector emits them in the order the recorder saw them — which is the
  ## order `FlowStep.exprOrder` gives the debugger's own chips.
  result = @[]
  for value in step.values:
    result.add(ReviewValueChip(
      name: value.name,
      # The collector's own truncation marker, appended here rather than in
      # either renderer so both hosts cut a long value the same way and the
      # headless suite can assert it.
      text: value.value & (if value.truncated: "..." else: ""),
      truncated: value.truncated))

func loopIterationCount*(plan: ReviewFlowPlan; loopIndex: int): int =
  ## How many passes through `loopIndex` the displayed invocation recorded.
  ##
  ## Counted from `rrTicksForIterations`, which `reviewFlowPlan` fills with one
  ## entry per crossing of the loop HEADER — so it is the number of passes this
  ## call actually made, not the number the file's static loop record claims
  ## (`DeepReviewLoop.totalIterations` is a whole-program figure and can be far
  ## larger than any single invocation's).
  if loopIndex <= 0 or loopIndex >= plan.loops.len:
    return 0
  plan.loops[loopIndex].rrTicksForIterations.len

func selectedLoopIteration*(plan: ReviewFlowPlan; loopIndex: int;
                            iterations: openArray[(int, int)]): int =
  ## The reader's chosen pass through `loopIndex`, clamped into range.
  ##
  ## Clamped rather than wrapped, and clamped *here* rather than at the call
  ## sites, so a stale choice left over from another invocation — call 1 of a
  ## function may loop six times and call 2 only twice — can never select a pass
  ## that was not recorded.
  for entry in iterations:
    if entry[0] == loopIndex:
      result = entry[1]
      break
  if result < 0:
    result = 0
  let total = plan.loopIterationCount(loopIndex)
  if total > 0 and result > total - 1:
    result = total - 1

func stepAtLine*(plan: ReviewFlowPlan; sourceLine: int;
                 iterations: openArray[(int, int)] = []): int =
  ## Index into `plan.steps` of the step whose values `sourceLine` should show,
  ## or -1.
  ##
  ## A line can be recorded many times in one invocation — every pass through a
  ## loop records its body again — and there is room for one strip. The rule is
  ## therefore: a step inside a loop only qualifies when its `iteration` is the
  ## one the loop's control currently names, and among the qualifying steps the
  ## first wins. A body line the selected pass did not execute (a `continue`
  ## skipped it, or the pass is the loop's last, partial one) has no qualifying
  ## step and shows nothing, which is the honest answer rather than the previous
  ## pass's values relabelled.
  result = -1
  for i in 0 ..< plan.steps.len:
    let step = plan.steps[i]
    if step.position != sourceLine:
      continue
    if step.loop > 0 and step.loop < plan.loops.len:
      if step.iteration != plan.selectedLoopIteration(step.loop, iterations):
        continue
    return i

func stepAtLineIteration*(plan: ReviewFlowPlan; sourceLine, iteration: int): int =
  ## Index into `plan.steps` of the step `sourceLine` recorded on pass
  ## `iteration`, or -1.
  ##
  ## The per-column counterpart of `stepAtLine`: where that proc answers "what
  ## does this line show, given the reader's choice", this one answers "what did
  ## this line do on pass N" for every N the band draws a column for. `-1` for
  ## the iteration selects a step outside any loop, which is the shape a
  ## non-loop line's single column asks for.
  ##
  ## A -1 answer is load-bearing rather than an error: it is how a pass that
  ## never reached the line gets an EMPTY column instead of a neighbouring
  ## pass's values under its heading. See `renderFlow`'s "no value" span, which
  ## occupies the same slot in the debugger's own band.
  result = -1
  for i in 0 ..< plan.steps.len:
    let step = plan.steps[i]
    if step.position != sourceLine:
      continue
    if iteration < 0:
      if step.loop > 0 and step.loop < plan.loops.len:
        continue
      return i
    if step.loop <= 0 or step.loop >= plan.loops.len:
      continue
    if step.iteration != iteration:
      continue
    return i

func loopAtLine*(plan: ReviewFlowPlan; sourceLine: int): int =
  ## The plan loop index whose body contains `sourceLine`, or 0 for "none".
  ##
  ## Read off the steps rather than off `Loop.first`/`last`, because a step
  ## knows which loop it was recorded inside and a line span does not
  ## distinguish a body line from a line that merely sits between the header
  ## and the closing brace without ever being recorded.
  result = 0
  for step in plan.steps:
    if step.position != sourceLine:
      continue
    if step.loop > 0 and step.loop < plan.loops.len:
      return step.loop

# ---------------------------------------------------------------------------
# Writing the FlowUpdate
# ---------------------------------------------------------------------------

proc asLangString[T](s: string): T =
  ## `langstring` is `string` natively and `cstring` in the renderer; only one
  ## of these branches is ever compiled.
  when T is string:
    s
  else:
    cstring(s)

proc emptyTableLike[T](): T =
  ## An empty `TableLike`, whichever flavour `T` is.
  ##
  ## `TableLike` is `Table` natively — a value type whose default *is* the empty
  ## table — and `JsAssoc` in the renderer, a ref whose default is nil, and a
  ## nil `JsAssoc` makes `hasKey` throw rather than answer false. The JS object
  ## literal is emitted rather than built with `jsffi`'s `JsAssoc[K, V]{}`
  ## because importing `jsffi` would drag the JS-only surface into this module
  ## and cost it the native compilation the headless tests need.
  ##
  ## The condition tests `T` rather than the backend on purpose: the ViewModel
  ## suite compiles this module *with the JS backend* over the `common/types`
  ## flavour (`test-vm-js`), where `T` is still `Table`, so `defined(js)` alone
  ## would emit a JS object literal into a Nim `Table` and corrupt it.
  when defined(js) and compiles(result.isNil):
    {.emit: [result, " = {};"].}

proc fillFlowValue*[V](target: V; source: ReviewFlowValue) =
  ## Populate one already-allocated `Value` from a review's rendered value.
  ##
  ## Split out of `fillFlowUpdate` so the value-fidelity decision has a name and
  ## a test of its own. `target.kind` is set by ordinal lookup on the enum the
  ## `Value` copy in this world declares, so the module never has to name
  ## `TypeKind`.
  type KindT = typeof(target.kind)
  let synthesized = synthesizedValueKind(source.kind)
  # `TypeKind`'s spelling is `Int` / `Float` / `Bool` / `String` / `Char` /
  # `Raw`; resolving by name keeps this honest if the enum is ever reordered.
  var resolved = low(KindT)
  var matched = false
  let wanted =
    case synthesized
    of rvkInt: "Int"
    of rvkFloat: "Float"
    of rvkBool: "Bool"
    of rvkString: "String"
    of rvkChar: "Char"
    of rvkRaw: "Raw"
  for candidate in low(KindT) .. high(KindT):
    if $candidate == wanted:
      resolved = candidate
      matched = true
      break
  target.kind = resolved
  # The raw text is always carried, whichever kind was resolved: `ui/value.nim`
  # renders `TypeKind.Raw` straight out of `r`, and a reader inspecting a
  # synthesised scalar can still see exactly what the collector wrote.
  target.r = asLangString[typeof(target.r)](source.value)
  if not matched:
    return
  case synthesized
  of rvkInt:
    target.i = asLangString[typeof(target.i)](source.value)
  of rvkFloat:
    target.f = asLangString[typeof(target.f)](source.value)
  of rvkBool:
    target.b = lowerAsciiCopy(source.value) == "true"
  of rvkString:
    target.text = asLangString[typeof(target.text)](unquoted(source.value))
  of rvkChar:
    target.c = asLangString[typeof(target.c)](unquoted(source.value))
  of rvkRaw:
    discard

proc fillFlowUpdate*[U, V](plan: ReviewFlowPlan; update: U; view: V) =
  ## Copy `plan` into an already-allocated `FlowUpdate`, for the given
  ## `EditorView`.
  ##
  ## The three shape obligations DR-R6 catalogued are met here:
  ##
  ##   1. **A synthesised `Location`.** Review flow carries only a
  ##      `functionKey` and an `executionIndex`; `flowStyleLines` iterates
  ##      `functionFirst + 1 .. functionLast` and `FlowComponent.onUpdatedFlow`
  ##      matches the editor's name against `highLevelPath`, so both the path
  ##      and the span are filled.
  ##   2. **A well-formed empty `branchesTaken`.** One outer and one inner
  ##      element with an empty table, matching `FlowViewUpdate::new()`, plus
  ##      one inner element per iteration of each loop, matching
  ##      `process_loops`. `flow_line_styles.hasBranchStateAt` guards the read
  ##      as a second line of defence; this is the first.
  ##   3. **Derived step counts.** `positionStepCounts` and
  ##      `relevantStepCount` are computed by `reviewFlowPlan` from the steps,
  ##      not left empty — an empty `relevantStepCount` would make
  ##      `toLineFlowKind` answer `LineFlowSkip` for every line of an
  ##      invocation that plainly ran.
  ##
  ## `update.finished` is set: a dataset is complete by construction, and a
  ## window that never reports finished leaves every unexecuted line
  ## `LineFlowUnknown` instead of skipped.
  type ViewUpdateT = typeof(update.viewUpdates[view])
  var viewUpdate: ViewUpdateT
  new(viewUpdate)

  viewUpdate.location.path = asLangString[typeof(viewUpdate.location.path)](plan.path)
  viewUpdate.location.highLevelPath =
    asLangString[typeof(viewUpdate.location.highLevelPath)](plan.path)
  viewUpdate.location.functionName =
    asLangString[typeof(viewUpdate.location.functionName)](plan.functionKey)
  viewUpdate.location.highLevelFunctionName =
    asLangString[typeof(viewUpdate.location.highLevelFunctionName)](plan.functionKey)
  viewUpdate.location.line = plan.line
  viewUpdate.location.highLevelLine = plan.line
  viewUpdate.location.functionFirst = plan.functionFirst
  viewUpdate.location.functionLast = plan.functionLast
  viewUpdate.location.highLevelFunctionFirst = plan.functionFirst
  viewUpdate.location.highLevelFunctionLast = plan.functionLast

  # A plan that found nothing still gets the placeholder loop, so a caller that
  # pushes it anyway cannot leave `FlowComponent` with a `loops` seq it indexes
  # out of bounds.
  var planLoops = plan.loops
  if planLoops.len == 0:
    planLoops = @[ReviewFlowLoop(
      base: -1, internal: @[], stepCounts: @[], rrTicksForIterations: @[])]

  type LoopT = typeof(viewUpdate.loops[0])
  viewUpdate.loops = @[]
  for lp in planLoops:
    var loopValue: LoopT
    loopValue.base = lp.base
    loopValue.baseIteration = lp.baseIteration
    loopValue.internal = lp.internal
    loopValue.first = lp.first
    loopValue.last = lp.last
    loopValue.registeredLine = lp.registeredLine
    loopValue.iteration = lp.iteration
    loopValue.stepCounts = lp.stepCounts
    loopValue.rrTicksForIterations = lp.rrTicksForIterations
    viewUpdate.loops.add(loopValue)

  type BranchesT = typeof(viewUpdate.branchesTaken[0][0])
  type IterationStepsT = typeof(viewUpdate.loopIterationSteps[0][0])
  viewUpdate.branchesTaken = @[]
  viewUpdate.loopIterationSteps = @[]
  for loopIndex in 0 ..< planLoops.len:
    let iterations =
      if loopIndex == 0: 1
      else: max(planLoops[loopIndex].rrTicksForIterations.len, 1)
    var branchRow: seq[BranchesT] = @[]
    var stepRow: seq[IterationStepsT] = @[]
    for _ in 0 ..< iterations:
      var branches: BranchesT
      var steps: IterationStepsT
      branches.table = emptyTableLike[typeof(branches.table)]()
      steps.table = emptyTableLike[typeof(steps.table)]()
      branchRow.add(branches)
      stepRow.add(steps)
    viewUpdate.branchesTaken.add(branchRow)
    viewUpdate.loopIterationSteps.add(stepRow)

  viewUpdate.relevantStepCount = plan.relevantStepCount
  viewUpdate.commentLines = plan.commentLines
  viewUpdate.positionStepCounts =
    emptyTableLike[typeof(viewUpdate.positionStepCounts)]()
  for entry in plan.positionStepCounts:
    viewUpdate.positionStepCounts[entry.position] = entry.stepCounts

  type StepT = typeof(viewUpdate.steps[0])
  let sampleKey = asLangString[typeof(viewUpdate.location.path)]("")
  type ValueT = typeof(viewUpdate.steps[0].beforeValues[sampleKey])
  viewUpdate.steps = @[]
  for step in plan.steps:
    var flowStep: StepT
    flowStep.position = step.position
    flowStep.loop = step.loop
    flowStep.iteration = step.iteration
    flowStep.stepCount = step.stepCount
    flowStep.rrTicks = step.rrTicks
    flowStep.beforeValues = emptyTableLike[typeof(flowStep.beforeValues)]()
    flowStep.afterValues = emptyTableLike[typeof(flowStep.afterValues)]()
    flowStep.exprOrder = @[]
    flowStep.events = @[]
    for source in step.values:
      let key = asLangString[typeof(viewUpdate.location.path)](source.name)
      var value: ValueT
      new(value)
      fillFlowValue(value, source)
      # The dataset carries ONE rendered value per name per step, and the
      # collector documents it as the after-value with the before-value as the
      # fallback (`collector.rs:289`). Both slots are filled with it because
      # `FlowComponent` reads whichever the reader's value mode selects, and a
      # half-filled step renders blank in the other mode.
      flowStep.beforeValues[key] = value
      flowStep.afterValues[key] = value
      flowStep.exprOrder.add(key)
    viewUpdate.steps.add(flowStep)

  update.viewUpdates[view] = viewUpdate
  update.location = viewUpdate.location
  update.error = false
  update.finished = true


# ---------------------------------------------------------------------------
# The structured values (UD-3, superseding RV-9's materialized half)
# ---------------------------------------------------------------------------

proc fillFlowUpdate*[F, U, V](file: F; plan: ReviewFlowPlan; update: U; view: V) =
  ## `fillFlowUpdate`, and then the **structured** values where the dataset
  ## carries them.
  ##
  ## Why the file rather than the plan: `ReviewFlowPlan` is a plain,
  ## non-generic value and it must stay one, because it is what lets every
  ## decision in this module be made once for two incompatible copies of the
  ## type world (see the header). A `Value` cannot travel in it — naming
  ## `Value` would pick one of the two copies — so the structure is fetched
  ## from the dataset at the point where a real `Value` field is being
  ## written, and `file` is what it is fetched from.
  ##
  ## The lookup is positional and that is safe by construction, not by luck:
  ## `reviewFlowPlan` appends exactly one `ReviewFlowStep` per
  ## `DeepReviewFunctionFlow.steps` entry and one `ReviewFlowValue` per
  ## `DeepReviewFlowStep.values` entry, in order, with no filtering. The bounds
  ## are still checked, because a plan and a file that did not come from the
  ## same call would otherwise fail silently rather than loudly.
  ##
  ## A value with no structure keeps the synthesis `fillFlowValue` performed —
  ## which is the whole native-collector case, and is why this is additive
  ## rather than a replacement.
  fillFlowUpdate(plan, update, view)
  if not plan.found:
    return
  when compiles(file.isNil):
    if file.isNil:
      return
  if plan.invocationIndex < 0 or plan.invocationIndex >= file.flow.len:
    return
  let flow = file.flow[plan.invocationIndex]
  let viewUpdate = update.viewUpdates[view]
  if viewUpdate.isNil:
    return
  for stepIndex in 0 ..< viewUpdate.steps.len:
    if stepIndex >= flow.steps.len:
      break
    let sourceStep = flow.steps[stepIndex]
    for valueIndex in 0 ..< sourceStep.values.len:
      let sourceValue = sourceStep.values[valueIndex]
      if sourceValue.structured.isNil:
        continue
      if valueIndex >= viewUpdate.steps[stepIndex].exprOrder.len:
        break
      let key = viewUpdate.steps[stepIndex].exprOrder[valueIndex]
      # The same object in both slots, as `fillFlowUpdate` does: the dataset
      # carries ONE value per name per step and `FlowComponent` reads whichever
      # the reader's value mode selects.
      viewUpdate.steps[stepIndex].beforeValues[key] = sourceValue.structured
      viewUpdate.steps[stepIndex].afterValues[key] = sourceValue.structured
