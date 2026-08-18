## The review's Omniscience overlay on the unified diff tab (RV-5).
##
##   "The Omniscience visualization is layered on top of the unified diff
##    rather than replaced with a review-specific variant. […] Keep the
##    standard CodeTracer Omniscience appearance, produced by the same code
##    path as normal debugging […] Restrict rendering to lines currently loaded
##    into the diff tab."
##   — `codetracer-specs/DeepReview/DeepReview-GUI.md` §4.4
##
## The diff tab's Monaco model is a *synthetic* document — file headers, `@@`
## dividers, expand controls and the hunks' own lines, in that order
## (`diff_document.buildDiffDocument`) — so its line numbers are not the file's.
## Everything in this module is the translation between the two, and nothing
## else: the classes come from `ui/flow_line_styles`, which is the body of
## `ui/editor.nim`'s `flowStyleLines`, so a diff line and a source line in the
## normal editor are decorated by the same decision with the same class.
##
## The restriction §4.4 asks for is structural rather than checked: a source
## line that is not in the document has no model line to map onto, so it cannot
## be decorated. Removed lines are excluded too — they have no position in the
## new revision, which is the revision the flow was recorded against.
##
## Three things are mapped, and §4.4 asks for all three:
##
##   * the per-line hit/skip classes (`ReviewFlowDecoration`);
##   * the **inline values** (`ReviewValueAnnotation`) — "Preserve existing
##     interaction patterns such as loop sliders and inline values";
##   * the two controls that decide *which* execution those values describe —
##     the invocation selector (`ReviewInvocationZone`, §7) and the loop
##     iteration control (`ReviewLoopZone`).
##
## The loop control is not an optional extra here. The debugger's flow panel
## lays a loop's iterations out side by side in their own column; a review
## annotates the code line itself and so has room for one value strip, which
## means a line inside a loop is undefined until the reader has said which pass
## they are looking at. The control is what makes the values on those lines
## mean anything.
##
## Pure: no Monaco, no DOM, no signals. The host (`ui/unified_diff.nim`) turns
## `ReviewFlowDecoration` and `ReviewValueAnnotation` into Monaco decorations,
## and the two zone types into Monaco view zones.

import ./diff_document
import ../../ui/flow_line_styles
import ../../ui/review_flow_adapter

type
  ReviewFlowDecoration* = object
    ## One inline flow decoration on the diff document.
    ##
    ## `inlineClassName` rather than a whole-line class because that is what
    ## the editor does: `line-flow-hit` / `-skip` / `-unknown` are applied to
    ## the line's *text range* (`editor.nim`'s `toDeltaDecorations` puts
    ## `MonacoLineStyle.inlineClass` into `inlineClassName`), and
    ## `styles/components/flow.styl` styles them as text weight and opacity.
    ## A whole-line background would not look like the debugger's overlay.
    modelLine*: int
    sourceLine*: int
    inlineClassName*: string

  ReviewInvocationZone* = object
    ## The in-editor invocation selector for one function, and where it goes.
    ##
    ##   "It is an **in-editor control, modelled on the loop iteration
    ##    selector** — the inline slider CodeTracer already renders immediately
    ##    above the relevant lines for a loop. […] Which invocation you are
    ##    looking at is a property *of the code on screen*, exactly as which
    ##    loop iteration you are looking at is."  — §7
    ##
    ## `afterLineNumber` is Monaco's view-zone anchor: the zone is drawn
    ## *between* that line and the next, so anchoring after the line before the
    ## function's first visible line puts the control immediately above it —
    ## the same arithmetic `flow.createLoopViewZones` uses (`loop.first - 1`).
    functionKey*: string
    fileIndex*: int
    afterLineNumber*: int
    firstModelLine*: int
    ordinal*: int        ## which invocation is displayed, 0-based
    total*: int          ## how many invocations the dataset carries
    callCount*: int      ## how many calls the coverage half counted
    invocationIndex*: int
      ## index into `DeepReviewFileData.flow` of the displayed invocation, or
      ## `NoInvocation`

  ReviewValueAnnotation* = object
    ## Every captured variable at one *displayed* line, and where it goes.
    ##
    ## The values are the ones the selected invocation actually recorded at
    ## that line — and, for a line inside a loop, the ones it recorded on the
    ## selected pass. A line the invocation never reached carries no
    ## annotation at all rather than an empty strip, because an empty strip
    ## reads as "ran, and nothing was captured".
    modelLine*: int
    sourceLine*: int
    stepCount*: int      ## the `FlowStep` these values came from
    loop*: int           ## the plan loop index, 0 for "outside any loop"
    iteration*: int      ## the pass through `loop` these values belong to
    values*: seq[ReviewValueChip]

  ReviewLoopZone* = object
    ## The in-editor loop iteration control for one loop, and where it goes.
    ##
    ## §4.4 names loop sliders alongside inline values, and on a review they
    ## are not decoration: a review draws ONE chip strip per line, so a line
    ## inside a loop is only well defined once the reader has said which pass
    ## through the loop they are looking at. The control is therefore what
    ## makes a loop's values meaningful, not an extra affordance on top of
    ## them.
    ##
    ## Anchored exactly as the debugger's is: `ui/flow.createLoopViewZones`
    ## puts a view zone at `loop.first - 1`, so this puts one immediately above
    ## the loop's first *visible* line.
    loopIndex*: int
    functionKey*: string
    fileIndex*: int
    headerLine*: int      ## the loop header's source line
    firstModelLine*: int
    afterLineNumber*: int
    iteration*: int       ## which pass is displayed, 0-based
    total*: int           ## how many passes the invocation recorded

proc reviewFlowDecorations*(doc: DiffDocument; fileIndex: int;
                            styled: openArray[FlowStyledLine]):
    seq[ReviewFlowDecoration] =
  ## Map `styled` (source lines) onto the diff document's model lines.
  ##
  ## A source line that appears more than once in the document — the same line
  ## revealed by expansion above one hunk and carried by the next — is decorated
  ## at each of its positions, because each of them *is* that line on screen.
  result = @[]
  if styled.len == 0:
    return
  for i, line in doc.lines:
    if line.fileIndex != fileIndex:
      continue
    # A removed line's `newNumber` is 0: it has no position in the revision the
    # flow describes, so it is never annotated.
    if line.kind notin {dlkAdded, dlkContext}:
      continue
    if line.newNumber <= 0:
      continue
    for entry in styled:
      if entry.position != line.newNumber:
        continue
      result.add(ReviewFlowDecoration(
        modelLine: i + 1,
        sourceLine: line.newNumber,
        inlineClassName: flowLineStyleClass(entry.kind)))
      break

proc functionSpanInDocument(doc: DiffDocument; fileIndex, startLine,
                            endLine: int): int =
  ## The first model line of `fileIndex` that falls inside the function's
  ## declared source span, or -1 when none of it is on screen.
  ##
  ## This is what keeps the control attached to the code: a function whose lines
  ## the diff does not show gets no selector, because there is nothing for it to
  ## sit above.
  for i, line in doc.lines:
    if line.fileIndex != fileIndex:
      continue
    if line.kind notin {dlkAdded, dlkContext, dlkRemoved}:
      continue
    if line.newNumber <= 0:
      continue
    if line.newNumber >= startLine and line.newNumber <= endLine:
      return i + 1
  -1

proc reviewInvocationZones*(doc: DiffDocument; fileIndex: int;
                            functions: openArray[ReviewFunctionInvocations];
                            ordinals: openArray[(string, int)] = []):
    seq[ReviewInvocationZone] =
  ## One selector per function of `fileIndex` that the document actually shows.
  ##
  ## `ordinals` is the reader's current choice per function key; a function that
  ## is not named there shows its first invocation. Out-of-range choices are
  ## clamped by `reviewInvocationIndex`, so a stale ordinal left over from a
  ## previous dataset cannot select nothing.
  ##
  ## A function with **no** invocations still gets a zone. That is RV-4's gap 8
  ## answered rather than hidden: `format_output` is called twice and recorded
  ## once, and a reviewer looking at the second call needs to be told the
  ## dataset has no flow for it — an unannotated function with no explanation
  ## reads as "this code never ran".
  result = @[]
  for fn in functions:
    if fn.startLine <= 0 or fn.endLine < fn.startLine:
      continue
    let firstModelLine = functionSpanInDocument(
      doc, fileIndex, fn.startLine, fn.endLine)
    if firstModelLine < 0:
      continue
    var ordinal = 0
    for entry in ordinals:
      if entry[0] == fn.functionKey:
        ordinal = entry[1]
        break
    if ordinal < 0:
      ordinal = 0
    if fn.invocations.len > 0 and ordinal > fn.invocations.high:
      ordinal = fn.invocations.high
    result.add(ReviewInvocationZone(
      functionKey: fn.functionKey,
      fileIndex: fileIndex,
      # Monaco draws a view zone after the given line, so anchoring after the
      # line before puts it above — `createLoopViewZones` does `loop.first - 1`
      # for the same reason. Anchoring after line 0 is legal and puts the zone
      # at the very top of the document.
      afterLineNumber: firstModelLine - 1,
      firstModelLine: firstModelLine,
      ordinal: if fn.invocations.len == 0: 0 else: ordinal,
      total: fn.invocations.len,
      callCount: fn.callCount,
      invocationIndex:
        if fn.invocations.len == 0: NoInvocation
        else: fn.invocations[ordinal].index))

proc invocationSelectorLabel*(zone: ReviewInvocationZone): string =
  ## The text the control shows, in the loop counter's register.
  ##
  ## The loop control reads "iteration N / M"; this reads "call N / M" for the
  ## same reason and in the same place. When the dataset recorded fewer calls
  ## than the coverage half counted (RV-4 gap 8) the difference is stated, so a
  ## missing overlay is explained rather than merely absent.
  if zone.total == 0:
    if zone.callCount > 0:
      return zone.functionKey & ": called " & $zone.callCount &
        (if zone.callCount == 1: " time, no flow recorded"
         else: " times, no flow recorded")
    return zone.functionKey & ": no flow recorded"
  var label = zone.functionKey & ": call " & $(zone.ordinal + 1) & " / " &
    $zone.total
  if zone.callCount > zone.total:
    label.add(" (" & $zone.callCount & " called, " & $zone.total & " recorded)")
  label

proc canStepBack*(zone: ReviewInvocationZone): bool =
  zone.total > 1 and zone.ordinal > 0

proc canStepForward*(zone: ReviewInvocationZone): bool =
  zone.total > 1 and zone.ordinal < zone.total - 1

proc nextOrdinal*(zone: ReviewInvocationZone; delta: int): int =
  ## The ordinal a click on the control moves to — clamped, never wrapped, so
  ## the ends of the range are stable the way the loop slider's are.
  if zone.total <= 0:
    return 0
  result = zone.ordinal + delta
  if result < 0:
    result = 0
  if result > zone.total - 1:
    result = zone.total - 1

# ---------------------------------------------------------------------------
# Loops: which pass through the loop the reader is looking at
# ---------------------------------------------------------------------------

proc reviewValueAnnotations*(doc: DiffDocument; fileIndex: int;
                             plan: ReviewFlowPlan;
                             iterations: openArray[(int, int)] = []):
    seq[ReviewValueAnnotation] =
  ## The inline values §4.4 requires, mapped onto the diff document's lines.
  ##
  ## Mapped by exactly the rule `reviewFlowDecorations` uses, and for the same
  ## reasons: only added and context lines can carry an annotation, because a
  ## removed line has no position in the revision the flow was recorded
  ## against; a source line the document shows twice is annotated at both
  ## positions, because each of them *is* that line on screen; and a source line
  ## the document does not show cannot be annotated at all, which is §4.4's
  ## "restrict rendering to lines currently loaded into the diff tab" met
  ## structurally rather than by a check that could be forgotten.
  result = @[]
  if not plan.found:
    return
  for i, line in doc.lines:
    if line.fileIndex != fileIndex:
      continue
    if line.kind notin {dlkAdded, dlkContext}:
      continue
    if line.newNumber <= 0:
      continue
    let stepIndex = plan.stepAtLine(line.newNumber, iterations)
    if stepIndex < 0:
      continue
    let step = plan.steps[stepIndex]
    if step.values.len == 0:
      continue
    let chips = reviewValueChips(step)
    result.add(ReviewValueAnnotation(
      modelLine: i + 1,
      sourceLine: line.newNumber,
      stepCount: step.stepCount,
      loop: step.loop,
      iteration: step.iteration,
      values: chips))

proc reviewLoopZones*(doc: DiffDocument; fileIndex: int; plan: ReviewFlowPlan;
                      iterations: openArray[(int, int)] = []):
    seq[ReviewLoopZone] =
  ## One iteration control per loop of the displayed invocation that the
  ## document actually shows.
  ##
  ## Index 0 is skipped: it is the placeholder `Loop::default()` the backend
  ## always emits and `reviewFlowPlan` reproduces, and it describes no loop. A
  ## loop the invocation entered exactly once is skipped too — there is nothing
  ## to choose between, and the debugger removes its slider for the same reason
  ## (`ui/flow.removeSliderWidget`, "loops that have only a single iteration").
  result = @[]
  if not plan.found:
    return
  for loopIndex in 1 ..< plan.loops.len:
    let total = plan.loopIterationCount(loopIndex)
    if total <= 1:
      continue
    let loop = plan.loops[loopIndex]
    if loop.first <= 0 or loop.last < loop.first:
      continue
    let firstModelLine = functionSpanInDocument(
      doc, fileIndex, loop.first, loop.last)
    if firstModelLine < 0:
      continue
    result.add(ReviewLoopZone(
      loopIndex: loopIndex,
      functionKey: plan.functionKey,
      fileIndex: fileIndex,
      headerLine: loop.registeredLine,
      firstModelLine: firstModelLine,
      # `createLoopViewZones` anchors the debugger's control at `loop.first - 1`
      # so it is drawn immediately above the loop; the same arithmetic, against
      # the loop's first line *on screen*.
      afterLineNumber: firstModelLine - 1,
      iteration: plan.selectedLoopIteration(loopIndex, iterations),
      total: total))

proc loopSelectorLabel*(zone: ReviewLoopZone): string =
  ## The text the loop control shows.
  ##
  ## "iteration N / M" rather than the debugger's 0-based "iteration N from M":
  ## it sits directly under the review's own "call N / M" and the two must
  ## count the same way or the pair reads as a bug.
  if zone.total <= 0:
    return "iteration - / 0"
  "iteration " & $(zone.iteration + 1) & " / " & $zone.total

proc canStepBack*(zone: ReviewLoopZone): bool =
  zone.total > 1 and zone.iteration > 0

proc canStepForward*(zone: ReviewLoopZone): bool =
  zone.total > 1 and zone.iteration < zone.total - 1

proc nextIteration*(zone: ReviewLoopZone; delta: int): int =
  ## The iteration a click on the control moves to — clamped, never wrapped,
  ## exactly as `nextOrdinal` clamps the invocation.
  if zone.total <= 0:
    return 0
  result = zone.iteration + delta
  if result < 0:
    result = 0
  if result > zone.total - 1:
    result = zone.total - 1
