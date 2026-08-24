## The review's Omniscience overlay on the unified diff tab (RV-5).
##
##   "The Omniscience visualization is layered on top of the unified diff
##    rather than replaced with a review-specific variant. […] Keep the
##    standard CodeTracer Omniscience appearance, produced by the same code
##    path as normal debugging […] Restrict rendering to lines currently loaded
##    into the diff tab."
##   — `codetracer-specs/DeepReview/DeepReview-GUI.md` §4.4
##
## The diff tab's Monaco model still carries chrome the file itself does not —
## file headers, `@@` dividers, expand controls — around the lines it shows
## (`diff_document.buildDiffPair`), so its line numbers are not the file's.
## Everything in this module is the translation between the two, and nothing
## else: the classes come from `ui/flow_line_styles`, which is the body of
## `ui/editor.nim`'s `flowStyleLines`, so a diff line and a source line in the
## normal editor are decorated by the same decision with the same class.
##
## Since UD-1 the tab is a Monaco *diff editor*, and everything here maps onto
## its **modified** model — the new revision, which is the revision the flow
## was recorded against, and the editor the unified view renders into. The old
## revision has its own model and takes no overlay at all.
##
## The restriction §4.4 asks for is structural rather than checked: a source
## line that is not in the document has no model line to map onto, so it cannot
## be decorated. Removed lines are excluded too — they have no position in the
## new revision — and since UD-1 they are excluded twice, because a removal is
## not in the modified model in the first place.
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

  ReviewValueColumn* = object
    ## One `.flow-parallel-values` column of the band drawn beside a line.
    ##
    ## UD-3: the debugger's Omniscience view lays a loop's passes out **side by
    ## side**, one column each, and the slider chooses where the visible run of
    ## columns starts (`ui/flow.renderFlow`: `if index < self.selectedIndex:
    ## continue`). This is that column.
    ##
    ## `values` may be empty, and that is a statement rather than a gap: the
    ## pass this column names never reached the line. The column is still
    ## emitted so the bands of the loop's several lines stay in step — dropping
    ## it would slide the next pass's values leftwards, under the wrong
    ## heading, which is exactly the "stale value from a previous pass" failure
    ## RV-5 was written to prevent, arriving from a different direction.
    iteration*: int      ## the pass this column shows; -1 outside any loop
    stepCount*: int      ## the `FlowStep` it came from, -1 when the pass skipped the line
    selected*: bool      ## the pass the loop control currently names
    values*: seq[ReviewValueChip]

  ReviewValueAnnotation* = object
    ## Every captured variable at one *displayed* line, and where it goes.
    ##
    ## The values are the ones the selected invocation actually recorded at
    ## that line — and, for a line inside a loop, the ones it recorded on the
    ## selected pass. A line the invocation never reached carries no
    ## annotation at all rather than an empty strip, because an empty strip
    ## reads as "ran, and nothing was captured".
    ##
    ## `columns` is UD-3's parallel band and `values` is the selected column of
    ## it. Both are filled, deliberately: the band is what the diff tab draws,
    ## while `values` keeps every reader written against RV-5's single strip —
    ## including the full-file surface of §5.3 — working off one computation
    ## rather than two that can drift apart.
    modelLine*: int
    sourceLine*: int
    stepCount*: int      ## the `FlowStep` these values came from
    loop*: int           ## the plan loop index, 0 for "outside any loop"
    iteration*: int      ## the pass through `loop` these values belong to
    values*: seq[ReviewValueChip]
    columns*: seq[ReviewValueColumn]

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

const
  ReviewValueBandGapPx* = 50.0
    ## The gap the debugger leaves between the longest source line and the
    ## first value column — `FlowComponent.distanceToSource`, set at
    ## `ui/editor.nim` alongside `distanceBetweenValues` and read by
    ## `flowLoopBackgroundStyle` / `makeLegend` as
    ## `maxFlowLineWidth + distanceToSource`. Restated as a constant rather
    ## than read off a `FlowComponent`, because a review has none (RV-5
    ## judgement call 3) and the placement must still be the same one.
  ReviewValueChipChromeChars* = 7
    ## The padding and margin one chip adds beside its own text, in characters.
    ##
    ## Measured, not guessed: in the design corpus a `<index>0` chip — eight
    ## characters of text — renders 123px wide against a character advance of
    ## 8.4px, so 56px of the box is chrome, which is 6.7 characters. The
    ## previous estimate of 4 was low enough that a four-chip column was
    ## computed to fit a pane it then overflowed by six pixels, and a reviewer
    ## read the result as a chip "truncated by the pane boundary with no
    ## ellipsis".
    ##
    ## The chrome comes from `.ct-omni-value`'s `padding: 0.25em 0.5em` and
    ## `margin-right: 0.5em` plus `.flow-parallel-value-name`'s 10px either
    ## side — the debugger's own, which is why it is a constant here rather
    ## than something this module could compute.
  ReviewValueBandLinePrefixChars* = 6.0
    ## What the source-line number at the head of a row-below band occupies:
    ## `min-width: 3ch` plus a `1em` margin, rounded up. Subtracted from the
    ## room the columns have, because it is drawn inside the band and the
    ## columns start after it.
  ReviewValueMorePassesChars* = 4
    ## The room the "more passes than fit" marker needs at the end of a band,
    ## in characters — `…+N` plus the padding `flow.styl` gives it.
    ##
    ## Taken out of the room the columns leave over rather than out of a column;
    ## see `reviewMorePassesMarkerFits`.
  ReviewValueBandMinGapPx* = 12.0
    ## The narrowest the gap between the longest annotated line and the first
    ## value column is allowed to become.
    ##
    ## `ReviewValueBandGapPx` is the debugger's number and the one asked for
    ## whenever the pane can pay it. What this says is what gives when it
    ## cannot: the WHITESPACE, before either the placement or a recorded value.
    ## About one character of separation is what keeps the band reading as an
    ## annotation beside the code rather than as a continuation of it.

func reviewValueBandLeftPx*(maxLineWidthPx: float): float =
  ## Where the value band starts, in pixels from the editor's content left,
  ## when the pane is not the constraint.
  ##
  ## Past the LONGEST annotated line rather than past each line's own end. That
  ## single decision is what makes the band a set of columns instead of RV-5's
  ## ragged trailing strip: every annotated line's values begin at the same x,
  ## so a reader can read one variable down the file. It is also the debugger's
  ## own arithmetic — `FlowComponent.maxFlowLineWidth + distanceToSource`,
  ## where the maximum runs over the lines that carry flow and not over the
  ## whole file — which is what §4.4 asks for.
  maxLineWidthPx + ReviewValueBandGapPx

func reviewValueBandLeftPx*(maxLineWidthPx, contentWidthPx,
                            columnWidthPx: float): float =
  ## Where the value band starts once the pane has been measured.
  ##
  ## The debugger's gap where the pane can pay for it, and a NARROWER gap where
  ## it cannot — never a position before the longest annotated line, and never
  ## one that puts the widest column past the pane's right edge.
  ##
  ## Why the gap is what gives, rather than the placement. UD-3's remedy for a
  ## column that does not fit beside the code was to move every band to its own
  ## row under its line, and that is still the answer when nothing else will
  ## do. But it is expensive in a way that was not measured at the time: a
  ## row-below band is a Monaco VIEW ZONE, so it adds its own height to the
  ## document. Measured on `sample-review.json` at 1920x1080, moving all nine
  ## bands there added about 315px to a pane roughly 500px tall — the file's
  ## line 23 left the viewport, and four expansion cases that read the gutter
  ## (Tests 15, 16c, 16d and 16e) went red because the lines they had just
  ## revealed were no longer rendered.
  ##
  ## The gap costs nothing to give up. It is empty space: shrinking it moves no
  ## code, hides no line, drops no chip and keeps the single left rail, because
  ## the offset is still one number for every band. So the order of surrender
  ## is whitespace first, then the placement — and the placement is surrendered
  ## only when even `ReviewValueBandMinGapPx` of separation cannot fit the
  ## widest column, which is a genuinely narrow pane rather than a merely
  ## tight one.
  result = maxLineWidthPx + ReviewValueBandGapPx
  let latestThatFits = contentWidthPx - columnWidthPx
  if latestThatFits < result:
    result = latestThatFits
  let earliestAllowed = maxLineWidthPx + ReviewValueBandMinGapPx
  if result < earliestAllowed:
    # Past the longest line by at least the minimum separation. The caller asks
    # `reviewValueBandFitsBeside` about THIS number, so a pane that cannot hold
    # the column even here takes the row-below placement instead.
    result = earliestAllowed

func reviewValueBandFitsBeside*(contentWidthPx, bandLeftPx,
                                columnWidthPx: float): bool =
  ## Whether the pane has room to draw the band beside the code at all.
  ##
  ## Asked ONCE for the whole tab, before any band is placed, and this is the
  ## point of it. Deciding per line produces a tab where some values sit beside
  ## their line and others do not, and deciding after the fact — clamping a
  ## band that does not fit back to the edge — produces the sheared column
  ## every UD-1 and UD-2 reviewer reported.
  ##
  ## `columnWidthPx` is the width the WIDEST annotated line's column actually
  ## needs, not a floor. That is the correction UD-3 shipped without: this used
  ## to ask only for `ReviewValueBandMinColumnChars` (12) characters of room,
  ## which is a question no band's real content is measured against, so the
  ## beside branch accepted panes it then overflowed. Measured in the running
  ## product on `sample-review.json` at 1920x1080: content 519px, band at
  ## 309px, so 210px of room — and the widest annotated line's column needs
  ## 240px. The old test said yes, the column was drawn at its full 230px from
  ## x=618 and ran to x=848 against a pane ending at 829, and the chips that
  ## did not fit the 21-character budget were replaced by an ellipsis, so
  ## `<y> 20` left the screen. Asking for the width that is actually needed is
  ## what makes "only whole columns are drawn" true rather than intended.
  ##
  ## Anything wider falls to the row-below placement, which has the full pane
  ## and no line text to clear. The diff tab is one pane of a layout, not a
  ## window, so that is a real branch rather than a defensive one.
  if contentWidthPx <= 0.0:
    return false
  if columnWidthPx <= 0.0:
    # Nothing to place. Answering "yes" would commit every band of the tab to a
    # placement chosen against a width that was never measured.
    return false
  contentWidthPx - bandLeftPx >= columnWidthPx

func reviewDrawnColumnChars*(naturalChars: int;
                             availableWidthPx, charWidthPx: float): int =
  ## How wide a column is DRAWN, in characters: what it needs, capped at the
  ## room the band actually has.
  ##
  ## The companion to `reviewVisibleColumnCount`'s "at least one column
  ## always". That floor is right — a band with no columns reads as "this line
  ## never executed", which is a different and false statement — but on its own
  ## it is how a column too wide for the pane got drawn anyway, at its full
  ## natural width, past the edge. The floor keeps the column; this decides how
  ## wide the kept column may be, so the pair together can never put anything
  ## outside the band.
  ##
  ## Capping is not squeezing: the box is narrower, and `reviewChipsThatFit`
  ## then drops whole chips out of it. No chip is ever drawn at less than its
  ## own width, which is the property three reviewers rated the squeeze 3/10
  ## for losing.
  result = max(naturalChars, 1)
  if charWidthPx <= 0.0 or availableWidthPx <= 0.0:
    # Unmeasured. The natural width is the honest answer; the caller has
    # nothing to clamp against yet and will repaint once it does.
    return
  let room = int(availableWidthPx / charWidthPx)
  if room < result:
    # `max(room, 1)`: a band with less than one character of room is degenerate
    # — there is no width that is both honest and non-zero — and a zero-width
    # column is the one outcome that must not happen, because Monaco reuses the
    # node and a zero box never recovers.
    result = max(room, 1)

func reviewVisibleColumnCount*(availableWidthPx, columnWidthPx: float;
                               total: int): int =
  ## How many parallel columns the band draws, given the room it has.
  ##
  ## Only WHOLE columns: the pane's right edge cut the chips in half in every
  ## UD-1 and UD-2 review, and a band that stops one column early is the fix
  ## that does not depend on a CSS ellipsis landing in the right place. The
  ## passes that do not fit are still reachable — the loop control scrolls the
  ## run of columns, exactly as `renderFlow`'s `selectedIndex` does.
  ##
  ## At least one column always, even at zero width: drawing none would read as
  ## "this line never executed", which is a different and false statement, and
  ## it is the reading the bare-line rule reserves for lines that really did
  ## not run. Callers pass a width from `reviewDrawnColumnChars`, which is
  ## capped at the room available — so the column this floor keeps is one that
  ## fits, rather than one drawn past the pane's edge.
  if total <= 0:
    return 1
  if columnWidthPx <= 0.0 or availableWidthPx <= 0.0:
    return 1
  result = int(availableWidthPx / columnWidthPx)
  if result < 1:
    result = 1
  if result > total:
    result = total

func reviewMorePassesMarkerFits*(availableWidthPx, columnWidthPx: float;
                                 visible: int; markerWidthPx: float): bool =
  ## Whether the "more passes than fit" marker fits in the room the drawn
  ## columns leave over.
  ##
  ## The marker is never bought with a pass. It would be easy to charge its
  ## width to `availableWidthPx` before the columns are counted, and on the
  ## measured fixture that costs a whole recorded pass — two 230px columns tile
  ## a 461px band with 0.6px to spare, so ANY reservation drops one of them.
  ## Spending recorded data to say that recorded data was not shown is the
  ## trade this milestone refused everywhere else ("a whole chip is legible or
  ## absent"), and the loop control directly above the band already names the
  ## total ("iteration 1 / 3"), so the fact is on screen either way.
  ##
  ## The rule also lands where the complaint was. A band is tight exactly when
  ## its columns tile it, and it has slack exactly when its columns are WIDE —
  ## which is the case a reviewer read as a defect: `let contribution = …`
  ## showing one group under a header showing four, "reads as missing 3 of 4
  ## passes' data". Those bands have room for the marker; the tiled ones lose
  ## nothing.
  if markerWidthPx <= 0.0:
    return false
  if visible < 1 or columnWidthPx <= 0.0:
    return false
  availableWidthPx - float(visible) * columnWidthPx >= markerWidthPx

func reviewChipWidthChars*(chip: ReviewValueChip): int =
  ## How wide one chip draws, in characters — its text plus its chrome.
  reviewValueChipName(chip).len + chip.text.len + ReviewValueChipChromeChars

func reviewChipsThatFit*(chips: openArray[ReviewValueChip];
                         availableChars: int): int =
  ## How many of a column's chips are drawn, given the room the column has.
  ##
  ## When a column is wider than the pane there is nothing to scroll it and
  ## nowhere to move it, and something has to give. What gives is the NUMBER of
  ## chips, never their size:
  ##
  ##   * squeezing them was tried and measured. Three fresh reviewers rated the
  ##     result 3/10 and all three named the same cause — a squeezed chip clips
  ##     its own value, so `<contribution> 0` renders as `<contribution>` with
  ##     an empty box, which is the brief's own disqualifying "chips showing a
  ##     name but no value";
  ##   * letting them overflow was the state before, and every UD-1 and UD-2
  ##     reviewer reported it as chips "cut mid-token at the pane edge".
  ##
  ## A whole chip is legible or absent. At least one is always drawn: a column
  ## with nothing in it reads as "this pass recorded nothing", which is a
  ## different and false statement.
  if chips.len == 0:
    return 0
  if availableChars <= 0:
    return 1
  var used = 0
  result = 0
  for chip in chips:
    let width = reviewChipWidthChars(chip)
    if result > 0 and used + width > availableChars:
      return
    used += width
    result += 1

func reviewColumnWidthChars*(annotation: ReviewValueAnnotation): int =
  ## How wide one column of this line's band is, in characters.
  ##
  ## Sized from the line's own widest pass, and the SAME for every column of
  ## that line: a band whose columns changed width from pass to pass could not
  ## be read across.
  ##
  ## Per LINE, and that is a deliberate departure from the debugger, which
  ## sizes per loop: `calculatePositionMaxWidth` raises
  ## `loopState.defaultIterationWidth` over every position of the loop, so
  ## every line of it draws its passes at one width and pass 2 starts at the
  ## same x all the way down. Per-loop was implemented and MEASURED here, and
  ## it does not survive the transplant. The debugger pairs it with a focus
  ## mechanism this surface does not have — `shrinkedLoopColumnMinWidth` /
  ## `setLoopIterationsWidth` draw the neighbours of the selected iteration
  ## narrowed — and with a panel that owns a whole editor. Dropped into a 461px
  ## review band, one uniform width is the WIDEST line's, so every line of the
  ## loop fits exactly one pass and the parallel columns stop appearing at all.
  ## A fresh reviewer of that build rated it 2/10 on precisely that: /"the frame
  ## never shows a chip row with two-or-more value-groups packed side by side
  ## … the one property that's supposed to distinguish this view never appears
  ## anywhere in the frame."/ Per-line keeps the narrow lines showing their
  ## passes, and what the wide lines are hiding is said by the `+N` marker
  ## rather than by an alignment they have no room for.
  ##
  ## The characters counted are what a chip actually draws — the bracketed name
  ## and the value text — plus `ReviewValueChipChromePx`'s worth of padding and
  ## margin around them. A floor keeps a line whose only value is `0` from
  ## producing a column too narrow to read a heading in.
  result = 0
  for column in annotation.columns:
    var chars = 0
    for chip in column.values:
      chars += reviewValueChipName(chip).len + chip.text.len +
        ReviewValueChipChromeChars
    if chars > result:
      result = chars
  if result < 10:
    result = 10

func reviewWidestColumnChars*(annotations: openArray[ReviewValueAnnotation]):
    int =
  ## The width one column needs on the widest-annotated line of a tab, in
  ## characters — the number `reviewValueBandFitsBeside` is asked against.
  ##
  ## Over the whole tab and not per line, because the placement is one decision
  ## for the tab: a tab where some lines' values sit beside the code and others
  ## sit under it has no left rail to read down, which three reviewers named as
  ## the most damaging thing about the surface.
  result = 0
  for annotation in annotations:
    if annotation.columns.len == 0:
      continue
    let chars = reviewColumnWidthChars(annotation)
    if chars > result:
      result = chars

proc reviewValueColumns*(plan: ReviewFlowPlan; sourceLine: int;
                         iterations: openArray[(int, int)] = [];
                         maxColumns: int = 1): seq[ReviewValueColumn] =
  ## The parallel band for one source line.
  ##
  ## Outside a loop there is one column and no choice to make. Inside one there
  ## is a column per recorded pass, and the run drawn starts at the pass the
  ## loop control names — so stepping the control scrolls the band rather than
  ## replacing its single strip, which is what the debugger's slider does.
  result = @[]
  let loopIndex = plan.loopAtLine(sourceLine)
  if loopIndex <= 0:
    let stepIndex = plan.stepAtLineIteration(sourceLine, -1)
    if stepIndex < 0:
      return
    result.add(ReviewValueColumn(
      iteration: -1,
      stepCount: plan.steps[stepIndex].stepCount,
      selected: true,
      values: reviewValueChips(plan.steps[stepIndex])))
    return
  let total = plan.loopIterationCount(loopIndex)
  if total <= 0:
    return
  let selected = plan.selectedLoopIteration(loopIndex, iterations)
  var wanted = maxColumns
  if wanted < 1:
    wanted = 1
  var iteration = selected
  while iteration < total and result.len < wanted:
    let stepIndex = plan.stepAtLineIteration(sourceLine, iteration)
    if stepIndex < 0:
      result.add(ReviewValueColumn(
        iteration: iteration, stepCount: -1,
        selected: iteration == selected, values: @[]))
    else:
      result.add(ReviewValueColumn(
        iteration: iteration,
        stepCount: plan.steps[stepIndex].stepCount,
        selected: iteration == selected,
        values: reviewValueChips(plan.steps[stepIndex])))
    iteration += 1

proc reviewValueAnnotations*(doc: DiffDocument; fileIndex: int;
                             plan: ReviewFlowPlan;
                             iterations: openArray[(int, int)] = [];
                             maxColumns: int = 1):
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
      values: chips,
      columns: reviewValueColumns(
        plan, line.newNumber, iterations, maxColumns)))

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
