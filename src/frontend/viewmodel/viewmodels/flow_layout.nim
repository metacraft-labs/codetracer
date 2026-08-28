## viewmodels/flow_layout.nim
##
## **Omniscience layout, without a renderer.**
##
## `codetracer-specs/GUI/Debugging-Features/Omniscience-Flow.md` §"Value
## Positioning" names three computations that decide where an inline value goes:
##
##   1. **Expression Columns** — "Values aligned vertically by expression"
##   2. **Legend Columns** — "Variable names as column headers"
##   3. **Indentation Tracking** — "Proper nesting for control structures"
##
## plus the loop-iteration window ("Loop Visualization", "Loop Slider Control")
## and the Before/After value modes. Until this module existed all five lived in
## `src/frontend/ui/flow.nim`, a 5,161-line Karax/Monaco component — so the
## *only* way to draw omniscience anywhere was to be the Electron desktop app.
## `CodeTracer-Embed-SDK.md` §3.2 excludes Monaco, GoldenLayout and "any
## rendering, any CSS, any component" from the package, which meant it also
## excluded, by accident, the arithmetic that says which label belongs beside
## which expression.
##
## This module is that arithmetic, and nothing else.
##
## ## The boundary, stated
##
## Everything here answers a question about **trace data and source text**:
##
##   * which column of the source line does this expression start at?
##   * which expressions does this line of source even offer, and where?
##   * in what order do this line's labels read left to right?
##   * how many characters wide is this expression's share of the legend row?
##   * which step counts belong to iteration 4 of loop 2?
##   * given the two recorded values, is this a `[x=10]`, a `[→230]` or an
##     `[x: 10→20]`?
##
## Nothing here answers a question about **pixels**: no `px`, no `%` string, no
## CSS class, no DOM node, no font metric, no view zone. A consumer multiplies
## `expressionChars` by whatever a character costs in its own typography, or —
## if it is emitting server-rendered HTML, as BlockTracer does — ignores the
## width entirely and uses the *order* and the *share*, which are unitless.
##
## The line that stays in `ui/flow.nim` is therefore not "the view layer" but
## specifically: Monaco view-zone lifecycle, `noUiSlider`, Karax vdom, Monaco
## decorations, DOM measurement, and the repaint-hazard scheduling its comments
## describe. See that file's header for the split.
##
## ## Units
##
## Two unit systems appear below and neither is a pixel:
##
##   * **columns** — 0-based character offsets into a source line. What
##     `findExpressionColumn` returns, and what a renderer turns into an x
##     coordinate (Monaco: `getOffsetForColumn(line, column + 1)`; a static HTML
##     renderer: a `<span>` boundary at that character index).
##   * **shares** — percentages of a row, as `float`. `legendShare` sums to 100
##     across a position's columns before the inter-column gaps are added; so
##     does `valueShare`. A renderer that lays the row out with CSS `width: %`
##     uses them directly; one that lays it out with a table ignores them.
##
## ## Provenance
##
## Every proc below carries the `ui/flow.nim` proc it was moved out of. The move
## is verbatim where the original was already pure (`findExpressionColumn`,
## `resolveFlowValueMode`, `closestIterationStepCount`) and a transcription
## where the original wrote its answer into a `JsAssoc` graph hanging off
## `FlowComponent` (`computeLoopColumnPlan`, `assignExpressionColumns`).
## `ui/flow.nim` now calls back into here, so there is one implementation of
## each rather than two that can drift.
##
## ## Relationship to the backend
##
## `src/db-backend/src/flow_preloader.rs` already shapes most of the *data*:
## which step touched which line (`positionStepCounts`), the expression
## evaluation order (`exprOrder`), the before/after values themselves, loop
## membership and iteration index, `rrTicksForIterations`, and the
## per-iteration line→step tables. None of that is recomputed here and none of
## it should be. What this module adds is strictly the *placement* decisions
## the backend has no business making, because they depend on source text and
## on what the surface is going to draw.

import std/[algorithm, strutils]

import ../../ui/flow_loop_math
export flow_loop_math

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const
  NoColumn* = -1
    ## `findExpressionColumn` found no standalone occurrence of the expression.

  NoStep* = -1
    ## No step of the current flow window satisfies the query. Mirrors
    ## `ui/flow.nim`'s `NO_STEP_COUNT`, restated rather than imported because
    ## that constant lives in an `include`d module of the desktop types.

  FirstIterationIndex* = 0
    ## Mirrors `FLOW_ITERATION_START`; see `flow_loop_math`'s header for why
    ## the constant is restated rather than imported.

  MinExpressionChars* = 3
    ## A legend heading is never budgeted narrower than this, however short the
    ## variable's name. From `ui/flow.nim:calculatePositionMaxWidth`
    ## (`if expressionWidth < 3: expressionWidth = 3`).

  MinValueChars* = 3
  MaxValueChars* = 7
    ## A value cell's budget is clamped into `[3, 7]` characters regardless of
    ## how long the rendered value is — a loop column shows every iteration side
    ## by side, so one long value must not be allowed to set the width of the
    ## whole band. From the same proc's
    ## `if valueWidth < 3 … if valueWidth > 7 …`.

# ---------------------------------------------------------------------------
# 1. Before/After value modes
#    (spec: "Before/After Values"; from `ui/flow.nim:getFlowValueMode`)
# ---------------------------------------------------------------------------

type
  FlowValueMode* = enum
    ## Which of a step's two recorded values a label shows.
    ##
    ## The spec's table, with the renderings it asks for:
    ##
    ## | Mode                  | Display                     | Example      |
    ## | --------------------- | --------------------------- | ------------ |
    ## | `fvmBefore`           | value before the expression | `[x=10]`     |
    ## | `fvmAfter`            | value after the expression  | `[→230]`     |
    ## | `fvmBeforeAndAfter`   | both                        | `[x: 10→20]` |
    ##
    ## The desktop's `ValueMode` enum (`frontend/types.nim`) has the same three
    ## members and `ui/flow.nim` maps onto it; the names differ only so that
    ## this module names nothing the renderer owns.
    fvmBefore
    fvmAfter
    fvmBeforeAndAfter

func resolveFlowValueMode*(hasBefore, hasAfter, valuesEqual: bool):
    FlowValueMode =
  ## Which mode a label at one expression is in.
  ##
  ## Moved from `ui/flow.nim:getFlowValueMode`, which took two `Value`s and
  ## asked `testEq` / `isNil`. Those three bits are the entire input, so the
  ## decision travels while `Value` — a desktop type that reaches the DOM —
  ## does not.
  ##
  ## `valuesEqual` wins first, and deliberately: an assignment that did not
  ## change the variable reads `[x=10]`, not `[x: 10→10]`. That is also why a
  ## step with neither value recorded (`testEq(nil, nil)` was true in the
  ## original) resolves to `fvmBefore` — the caller then has nothing to print,
  ## which is the same outcome as before but now visible in the answer rather
  ## than in a `nil` dereference.
  if valuesEqual:
    fvmBefore
  elif hasBefore and not hasAfter:
    fvmBefore
  elif hasAfter and not hasBefore:
    fvmAfter
  else:
    fvmBeforeAndAfter

func resolveFlowValueModeForText*(beforeText, afterText: string;
                                  hasBefore, hasAfter: bool): FlowValueMode =
  ## `resolveFlowValueMode` for a consumer that only has the rendered strings.
  ##
  ## A renderer working from a `.dr` review dataset or from a JSON wire format
  ## has no structured `Value` to compare, only what the collector printed. Two
  ## values that print identically are indistinguishable to such a consumer, and
  ## showing `[x: 10→10]` because the structures differed in a field it cannot
  ## see would be worse than the equality this makes.
  resolveFlowValueMode(hasBefore, hasAfter,
    valuesEqual = (hasBefore == hasAfter) and beforeText == afterText)

# ---------------------------------------------------------------------------
# 2. Expression columns
#    (spec: "Expression Columns"; from `ui/flow.nim:isFlowIdentifierChar`,
#     `findFlowExpressionPosition`, `fallbackFlowExpressionPosition`,
#     `calculateVariablePosition`, `prepareFlowLineVariables`)
# ---------------------------------------------------------------------------

type
  FlowExpressionColumn* = object
    ## One expression of one source line, and the column it was placed at.
    expression*: string
    column*: int
      ## 0-based character offset into the source line. Always >= 0 after
      ## `assignExpressionColumns`: an expression the line's text does not
      ## contain is parked past the end of the line by
      ## `fallbackExpressionColumn` rather than dropped, because a value that
      ## was recorded must be shown somewhere.
    found*: bool
      ## `true` when `column` is a real occurrence in the source text, `false`
      ## when it is the fallback. A renderer that draws a connector line from
      ## the label to the expression (the spec's "Multiline Visualization")
      ## needs to know which of the two it has; the desktop's inline mode does
      ## not and ignores this.

func isFlowIdentifierChar*(ch: char): bool =
  ## Moved verbatim from `ui/flow.nim:isFlowIdentifierChar`.
  ##
  ## Quotes count as identifier characters so that a search for `x` does not
  ## match inside `"x"`; that is a deliberate part of the original and is kept.
  ch in {'a'..'z', 'A'..'Z', '0'..'9', '_', '\'', '"'}

func findExpressionColumn*(text, expression: string): int =
  ## First standalone occurrence of `expression` in `text`, or `NoColumn`.
  ##
  ## Moved verbatim from `ui/flow.nim:findFlowExpressionPosition`. "Standalone"
  ## means not adjacent to another identifier character on either side, so
  ## `sum` does not match inside `sums` and `i` does not match inside `if`.
  if expression.len == 0:
    return NoColumn

  var start = 0
  while start < text.len:
    let index = text.find(expression, start)
    if index < 0:
      return NoColumn

    let beforeOk = index == 0 or not isFlowIdentifierChar(text[index - 1])
    let afterIndex = index + expression.len
    let afterOk = afterIndex >= text.len or
      not isFlowIdentifierChar(text[afterIndex])
    if beforeOk and afterOk:
      return index

    start = index + 1

  NoColumn

func fallbackExpressionColumn*(lineLength, alreadyPlaced: int): int =
  ## Where a label goes when its expression is nowhere in the line's text.
  ##
  ## Moved from `ui/flow.nim:fallbackFlowExpressionPosition`, whose two
  ## branches (Monaco's `getLineMaxColumn(position) - 1`, and `text.len` when
  ## the model is unavailable) are the same number — the line's length — reached
  ## two ways. The renderer-specific half was the *measurement*, not the
  ## arithmetic.
  ##
  ## The `+ 2 + alreadyPlaced * 2` trailing run is what keeps several such
  ## labels from stacking on one another: each unplaced expression is parked two
  ## columns past the previous one. It is not a gap size in any unit a renderer
  ## has to honour — it is an ordering.
  ##
  ## This is reached more often than it looks. A return value has no expression
  ## text at all (the spec's `[→230]`), and a compound assignment's target may
  ## be spelled differently in the trace than in the source.
  max(0, lineLength) + 2 + alreadyPlaced * 2

func assignExpressionColumns*(sourceText: string;
                              exprOrder, beforeExpressions,
                              afterExpressions: openArray[string]):
    seq[FlowExpressionColumn] =
  ## Place every expression a step recorded at a column of its source line.
  ##
  ## Transcribed from `ui/flow.nim:prepareFlowLineVariables`, which drove
  ## `calculateVariablePosition` over three lists in this exact order and wrote
  ## the answers into `flowLines[position].variablesPositions`. The order is
  ## load-bearing rather than incidental:
  ##
  ##   1. `exprOrder` — the backend's evaluation order
  ##     (`flow_preloader.rs:log_expressions`), restricted to expressions that
  ##     actually recorded a value;
  ##   2. any remaining `beforeValues` key;
  ##   3. any remaining `afterValues` key.
  ##
  ## It decides which expression gets the *earlier* fallback slot when two of
  ## them are absent from the source text, so changing it moves labels.
  ##
  ## The result is in placement order, not column order — `orderExpressionsByColumn`
  ## is the second step, exactly as `sortVariablesPositions` was.
  result = @[]

  func alreadyHas(placed: seq[FlowExpressionColumn]; expression: string): bool =
    for entry in placed:
      if entry.expression == expression:
        return true
    false

  proc place(placed: var seq[FlowExpressionColumn]; expression: string) =
    if expression.len == 0 or placed.alreadyHas(expression):
      return
    let found = findExpressionColumn(sourceText, expression)
    if found >= 0:
      placed.add(FlowExpressionColumn(
        expression: expression, column: found, found: true))
    else:
      placed.add(FlowExpressionColumn(
        expression: expression,
        column: fallbackExpressionColumn(sourceText.len, placed.len),
        found: false))

  for expression in exprOrder:
    var recorded = false
    for candidate in beforeExpressions:
      if candidate == expression:
        recorded = true
        break
    if not recorded:
      for candidate in afterExpressions:
        if candidate == expression:
          recorded = true
          break
    if recorded:
      result.place(expression)

  for expression in beforeExpressions:
    result.place(expression)

  for expression in afterExpressions:
    result.place(expression)

func orderExpressionsByColumn*(columns: openArray[FlowExpressionColumn];
                               ascending: bool = true):
    seq[FlowExpressionColumn] =
  ## The order the labels read in.
  ##
  ## Moved from `ui/flow.nim:sortVariablesPositions`, whose `ascending`
  ## parameter is inverted with respect to its name — `ascending = true` there
  ## sets `direction = -1` and sorts *descending*. Its single call site passes
  ## `false`, i.e. left-to-right by source column, which is what `ascending =
  ## true` means here. `ui/flow.nim` now delegates and flips the flag at the
  ## boundary rather than propagating the confusion into the SDK.
  ##
  ## The sort is stable, so two expressions parked at the same fallback column
  ## keep their placement order.
  result = @columns
  if ascending:
    result.sort(proc(a, b: FlowExpressionColumn): int =
      cmp(a.column, b.column))
  else:
    result.sort(proc(a, b: FlowExpressionColumn): int =
      cmp(b.column, a.column))

type
  FlowTokenLanguage* = object
    ## What `tokenizeSourceExpressions` needs to know about a language.
    ##
    ## A profile rather than a `Lang` enum, deliberately. `ui/flow.nim` built its
    ## keyword tables from `common/common_lang.flowKeywords(lang)`, and pulling
    ## that module into the SDK's graph would put `std/os` and forty languages'
    ## worth of tables behind an embeddable package for the sake of two sets of
    ## characters and a word list. It also would not serve the consumer the SDK
    ## exists for: a page rendering someone else's language wants to describe it,
    ## not to be told CodeTracer does not know it.
    identifierStart*: set[char]
      ## Characters that begin and continue an identifier. `ui/flow.nim`'s
      ## `isSymbol` answered `c.isAlphaAscii or c == '_'` for Nim and `false` for
      ## everything else — so DIGITS are not identifier characters and `x1`
      ## tokenizes as `x`. Preserved rather than corrected; see
      ## `nimFlowTokenLanguage`.
    stringDelimiters*: set[char]
      ## Characters that open and close a string literal. Text between them is
      ## not tokenized, which is what keeps a label off the `x` inside `"x"`.
    keywords*: seq[string]
      ## Words that are not expressions. A keyword is dropped from the result
      ## rather than emitted with an empty name.

  FlowSourceToken* = object
    ## One expression found in a source line, and where it starts.
    expression*: string
    column*: int   ## 0-based character offset into the line

func flowTokenLanguage*(identifierStart, stringDelimiters: set[char];
                        keywords: openArray[string]): FlowTokenLanguage =
  FlowTokenLanguage(
    identifierStart: identifierStart,
    stringDelimiters: stringDelimiters,
    keywords: @keywords)

func nimFlowTokenLanguage*(keywords: openArray[string]): FlowTokenLanguage =
  ## The profile `ui/flow.nim` used for Nim, restated.
  ##
  ## `{'a'..'z', 'A'..'Z', '_'}` and `{'"'}` are `isSymbol` and `isStringSymbol`
  ## for `LangNim`; both answered "no" for every other language, so on the
  ## desktop today only Nim yields tokens at all. A consumer that wants Noir or
  ## Rust builds its own profile — which is the point of the profile existing.
  flowTokenLanguage({'a'..'z', 'A'..'Z', '_'}, {'"'}, keywords)

func tokenizeSourceExpressions*(source: string;
                                language: FlowTokenLanguage):
    seq[FlowSourceToken] =
  ## Every expression in one source line, with its column, LAST FIRST.
  ##
  ## Moved from `ui/flow.nim:tokenizeExpressions`. This is the other half of the
  ## spec's "Expression Columns": `findExpressionColumn` locates an expression
  ## the *trace* named, while this enumerates the expressions the *source*
  ## offers — which is what a surface needs when it wants a slot beside every
  ## identifier on a line rather than only beside the ones a step recorded.
  ##
  ## Two behaviours of the original are preserved because callers depend on
  ## them, and both would look like bugs to someone reading only this signature:
  ##
  ##   * **The result is in descending column order.** The original ends with an
  ##     explicit `countdown` reversal, and `ensureTokens` consumes it that way.
  ##   * **A keyword is dropped, not emitted empty.** The tokenizer reserves a
  ##     slot at the first identifier character and fills in the word when the
  ##     identifier ends; a word that turns out to be a keyword pops its slot.
  ##
  ## Digits are not identifier characters (see `FlowTokenLanguage`), so `x1`
  ## yields `x`. That is the original's behaviour and changing it here would
  ## change what the desktop tokenizes.
  var forward: seq[FlowSourceToken] = @[]
  var state = 0   # 0 = between tokens, 1 = inside an identifier, 2 = in a string
  var token = ""

  func isKeyword(language: FlowTokenLanguage; word: string): bool =
    for keyword in language.keywords:
      if keyword == word:
        return true
    false

  func closeIdentifier(forward: var seq[FlowSourceToken];
                       language: FlowTokenLanguage; token: string) =
    if forward.len == 0:
      return
    if language.isKeyword(token):
      discard forward.pop()
    else:
      forward[^1].expression = token

  for i in 0 ..< source.len:
    let c = source[i]
    if c in language.identifierStart:
      case state
      of 0:
        state = 1
        token = $c
        forward.add(FlowSourceToken(expression: "", column: i))
      of 1:
        token.add(c)
      else:
        discard
    elif c in language.stringDelimiters:
      case state
      of 1:
        forward.closeIdentifier(language, token)
        token = ""
        state = 2
      of 0:
        state = 2
      else:
        state = 0
    else:
      if state == 1:
        forward.closeIdentifier(language, token)
        token = ""
        state = 0

  if state == 1:
    forward.closeIdentifier(language, token)

  result = @[]
  for i in countdown(forward.len - 1, 0):
    result.add(forward[i])

func inlineLabelAnchorColumn*(expressionColumn, expressionLength: int): int =
  ## Where an inline label attaches, as a 1-based source column.
  ##
  ## Moved from `ui/flow.nim:insertInlineDecorations`, which computed
  ## `variablesPositions[expression] + 1 + expression.len` and handed it to
  ## `newMonacoRange` as a zero-width range. Monaco columns are 1-based, hence
  ## the `+ 1`; the `+ expressionLength` puts the label immediately *after* the
  ## expression, which is the whole of the spec's `let sum = x + y  # [sum=30]`
  ## placement.
  ##
  ## A renderer with 0-based offsets subtracts one; the point of naming it is
  ## that "immediately after the expression" is a layout decision and belongs
  ## here, while "and Monaco expresses that as a zero-width decoration range"
  ## does not.
  expressionColumn + 1 + expressionLength

# ---------------------------------------------------------------------------
# 3. Indentation tracking
#    (spec: "Indentation Tracking"; replaces `ui/flow.nim:calculateLineIndentations`)
# ---------------------------------------------------------------------------

func sourceIndentLevel*(text: string; tabSize: int = 4): int =
  ## How many indent levels a source line is nested by.
  ##
  ## The spec asks for "proper nesting for control structures" and
  ## `ui/flow.nim:calculateLineIndentations` answered it by counting Monaco's
  ## rendered `.cigr` indent-guide elements in the line's view overlay — a
  ## measurement of the editor's DOM, available to no other renderer.
  ##
  ## **That proc had no call site.** It was declared at `ui/flow.nim:212`,
  ## defined at 4358, and never invoked from anywhere in the tree; `FlowLine`'s
  ## matching `indentationsCount` field was never read either. So the spec's
  ## third positioning rule was, on the desktop, computed by nothing — which is
  ## also why replacing it here cannot change what the desktop draws.
  ##
  ## The replacement counts leading whitespace instead, expanding tabs to
  ## `tabSize` columns, which is the same number Monaco's guides are drawn from.
  ## A blank or whitespace-only line has no nesting of its own — its indentation
  ## is not a statement about structure — and yields 0.
  if tabSize <= 0:
    return 0
  var width = 0
  for ch in text:
    case ch
    of ' ':
      width += 1
    of '\t':
      # Advance to the next tab stop, which is what an editor does; a tab in
      # column 2 of a 4-wide tab stop is worth 2 columns, not 4.
      width += tabSize - (width mod tabSize)
    else:
      return width div tabSize
  # Reached the end without a non-blank character.
  0

# ---------------------------------------------------------------------------
# 4. The flow window, renderer-neutrally
# ---------------------------------------------------------------------------

type
  FlowValueText* = object
    ## One recorded variable at one step, already rendered to text.
    ##
    ## Text rather than a structured `Value`, on purpose. `Value`
    ## (`frontend/types.nim`) is a desktop type whose renderings reach the DOM,
    ## and `frontend/types.nim` is banned from the SDK's import graph by
    ## `ci/test/sdk-facade-boundary.sh` because `ReplaySession.savedLayoutConfig`
    ## is a GoldenLayout config. Layout needs the *width* and the *identity* of a
    ## value, never its structure — so the caller renders, and this module
    ## places.
    expression*: string
    text*: string

  FlowLayoutStep* = object
    ## One `FlowStep` of the loaded window, with the desktop's `JsAssoc` and
    ## `cstring` replaced by types that compile on both backends.
    ##
    ## Field-for-field the subset of
    ## `common/common_types/codetracer_features/flow.nim:FlowStep` that any
    ## placement decision reads. `events` is absent: a flow event is content, and
    ## whatever renders it decides its own placement.
    stepCount*: int
    line*: int          ## `FlowStep.position` — a source line number
    loopIndex*: int     ## `FlowStep.loop`; 0 means "outside any real loop"
    iteration*: int
    rrTicks*: int
    exprOrder*: seq[string]
    beforeValues*: seq[FlowValueText]
    afterValues*: seq[FlowValueText]

  FlowLayoutLoop* = object
    ## One `Loop` of the loaded window.
    ##
    ## `iterationSteps[i]` is iteration `i`'s line→stepCount table, flattened to
    ## pairs so the type is backend-neutral and its iteration order is defined.
    ## It is the backend's `FlowViewUpdate.loopIterationSteps[loopIndex]`.
    base*: int
    baseIteration*: int
    internal*: seq[int]
    first*: int           ## the loop header's source line
    last*: int            ## the last source line of the body
    registeredLine*: int  ## the line the loop control is attached to
    stepCounts*: seq[int]
    rrTicksForIterations*: seq[int]
    iterationSteps*: seq[seq[tuple[line: int, stepCount: int]]]

  FlowLayoutWindow* = object
    ## Everything a placement decision needs about one loaded flow window.
    ##
    ## `sourceLines` is the file's text, 0-indexed (`sourceLines[n - 1]` is
    ## source line `n`). It is an input rather than something this module fetches
    ## because who owns the source differs per consumer: the desktop reads
    ## Monaco's model, BlockTracer reads the artifact it is rendering, a review
    ## reads the revision under review.
    steps*: seq[FlowLayoutStep]
    loops*: seq[FlowLayoutLoop]
    sourceLines*: seq[string]
    tabSize*: int

func lineText*(window: FlowLayoutWindow; line: int): string =
  ## The source text of `line`, or `""` when the window does not carry it.
  ##
  ## `""` rather than a raise: `ui/flow.nim:flowLineSourceText` returns the empty
  ## string for a line outside the model, and every caller here treats an unknown
  ## line as "no expression can be found in it", which routes the labels through
  ## `fallbackExpressionColumn`. A window loaded before its file is a real state,
  ## not an error.
  if line <= 0 or line > window.sourceLines.len:
    ""
  else:
    window.sourceLines[line - 1]

# ---------------------------------------------------------------------------
# 5. Per-line grouping
#    (from `ui/flow.nim:createFlowLines` / `makeFlowLine` /
#     `sortedFlowLinePositions`, and the backend's `positionStepCounts`)
# ---------------------------------------------------------------------------

type
  FlowLineSteps* = object
    ## Every step of the window that touched one source line.
    line*: int
    stepCounts*: seq[int]
      ## Indices into `FlowLayoutWindow.steps`, in increasing step order — which
      ## is execution order, because the backend's walker only moves forward.

func groupStepsByLine*(window: FlowLayoutWindow): seq[FlowLineSteps] =
  ## Group the window's steps by source line, lines ascending.
  ##
  ## This is `createFlowLines`' walk over `flow.positionStepCounts` with the
  ## `JsAssoc` iteration order — which is insertion order, i.e. whatever the
  ## deserialiser happened to do — replaced by a defined one.
  ## `sortedFlowLinePositions` existed in `ui/flow.nim` precisely because that
  ## order could not be relied on; here the sort is not a repair applied
  ## afterwards, it is the contract.
  ##
  ## Every step is grouped, including steps of lines the consumer will not draw.
  ## Filtering to a viewport is the renderer's decision and depends on how much
  ## of the file it shows — a static page shows all of it.
  result = @[]
  var lines: seq[int] = @[]
  for step in window.steps:
    if step.line <= 0:
      continue
    var seen = false
    for line in lines:
      if line == step.line:
        seen = true
        break
    if not seen:
      lines.add(step.line)
  lines.sort(system.cmp[int])

  for line in lines:
    var entry = FlowLineSteps(line: line, stepCounts: @[])
    for index, step in window.steps:
      if step.line == line:
        entry.stepCounts.add(index)
    result.add(entry)

# ---------------------------------------------------------------------------
# 6. Loop iteration windowing
#    (from `ui/flow.nim:positionRRTicksToStepCount`,
#     `activeLoopIterationStepCounts`, `firstLoopBodyStepForIteration`,
#     `getClosestIterationStepCount`, `maxLoopIteration`)
# ---------------------------------------------------------------------------

func maxIterationIndex*(loop: FlowLayoutLoop): int =
  ## Highest selectable iteration index, or -1 when the loop recorded none.
  ##
  ## Moved from `ui/flow.nim:maxLoopIteration`, including its preference for
  ## `loopIterationSteps` over `rrTicksForIterations`: the two agree in a
  ## well-formed window, and where they do not it is the step tables that decide
  ## what can actually be shown.
  ##
  ## Single definition on purpose — the counter's "of N", the arrows' clamp and
  ## their end-stop state must all agree, and in `ui/flow.nim` they each used to
  ## recompute it inline.
  if loop.iterationSteps.len > 0:
    loop.iterationSteps.len - 1
  else:
    loop.rrTicksForIterations.len - 1

func stepIndexForTicks*(ticks: openArray[int]; rrTicks: int): int =
  ## Which of a line's steps the debugger's `rrTicks` falls on or inside.
  ##
  ## `ticks[i]` is the trace tick of that line's i-th step, in execution order.
  ## Returns an index into `ticks`, or `NoStep` when the line has no steps.
  ##
  ## Moved from `ui/flow.nim:positionRRTicksToStepCount`, whose three cases are
  ## kept exactly: before the line's first step clamps to that first step, after
  ## its last clamps to the last, and otherwise it is the step whose interval
  ## contains the tick.
  ##
  ## Split from the window lookup on purpose. The desktop asks this question on
  ## every debugger move, against `JsAssoc` structures it already holds; giving
  ## it a signature that takes the ticks directly is what lets it delegate the
  ## *arithmetic* without rebuilding a window per call. A line with no steps in
  ## this window is ordinary rather than exceptional — the window covers one
  ## call, and callers ask about lines that are blank, never executed, or
  ## outside it. The original logged that at ERROR level, 79 times in one GUI
  ## run.
  if ticks.len == 0:
    return NoStep
  if rrTicks < ticks[0]:
    return 0
  if rrTicks > ticks[^1]:
    return ticks.len - 1
  for i in 0 ..< ticks.len:
    let next = ticks[min(i + 1, ticks.len - 1)]
    if rrTicks >= ticks[i] and rrTicks <= next:
      return i
  ticks.len - 1

func stepCountForTicks*(window: FlowLayoutWindow; line, rrTicks: int): int =
  ## `stepIndexForTicks`, resolved against a whole window: the index into
  ## `window.steps` of the step at `line` that `rrTicks` falls on or inside, or
  ## `NoStep`.
  var stepIndices: seq[int] = @[]
  var ticks: seq[int] = @[]
  for index, step in window.steps:
    if step.line == line:
      stepIndices.add(index)
      ticks.add(step.rrTicks)
  let chosen = stepIndexForTicks(ticks, rrTicks)
  if chosen == NoStep:
    NoStep
  else:
    stepIndices[chosen]

func orderIterationSteps*(candidates: openArray[
                            tuple[stepCount: int, line: int]]): seq[int] =
  ## Deduplicate an iteration's steps and put them in reading order.
  ##
  ## The tail of `ui/flow.nim:activeLoopIterationStepCounts`: unique by step
  ## count, then sorted by source line with the step count as the tie-break, so
  ## a line executed twice within one pass keeps execution order and the pass as
  ## a whole reads top to bottom. That ordering is what makes the spec's
  ## per-iteration column a column rather than a bag.
  ##
  ## Split out with a primitive signature for the same reason as
  ## `stepIndexForTicks`: `ui/flow.nim` holds the two candidate lists already and
  ## delegates the ordering without building a window.
  var picked: seq[tuple[stepCount: int, line: int]] = @[]
  for candidate in candidates:
    var seen = false
    for existing in picked:
      if existing.stepCount == candidate.stepCount:
        seen = true
        break
    if not seen:
      picked.add(candidate)
  picked.sort(proc(a, b: tuple[stepCount: int, line: int]): int =
    if a.line == b.line:
      cmp(a.stepCount, b.stepCount)
    else:
      cmp(a.line, b.line))
  result = @[]
  for entry in picked:
    result.add(entry.stepCount)

func firstBodyStepIn*(entries: openArray[tuple[line: int, stepCount: int]];
                      first, last, stepCountLimit: int): int =
  ## The lowest-numbered body line's step among `entries`, or `NoStep`.
  ##
  ## The core of `ui/flow.nim:firstLoopBodyStepForIteration`: strictly after the
  ## loop header (`> first`) and not past the body's end (`<= last`), so the
  ## header is excluded and the closing line is not. `stepCountLimit` is the
  ## number of steps in the window — the original's `validFlowStepCount` bound.
  ##
  ## Ties go to the earliest entry, matching the original's `if line <
  ## selectedLine` (strictly less), which keeps the first table entry for a line
  ## rather than the last.
  var selectedLine = int.high
  result = NoStep
  for entry in entries:
    if entry.line > first and entry.line <= last and
       entry.stepCount >= 0 and entry.stepCount < stepCountLimit:
      if entry.line < selectedLine:
        selectedLine = entry.line
        result = entry.stepCount

func iterationStepCounts*(window: FlowLayoutWindow;
                          loopIndex, iteration: int): seq[int] =
  ## Every step of `loopIndex`'s `iteration`, in source-line order.
  ##
  ## Moved from `ui/flow.nim:activeLoopIterationStepCounts`, both of its
  ## sources and its ordering intact:
  ##
  ##   * the iteration's own line→step table, which is what the backend built
  ##     for exactly this question, and
  ##   * a scan of the loop's `stepCounts` for steps tagged with this
  ##     iteration, which catches steps the table does not name.
  ##
  ## Deduplicated, then sorted by source line with the step index as the
  ## tie-break — so a line executed twice in one iteration keeps execution
  ## order, and the iteration as a whole reads top to bottom. That is what makes
  ## the spec's per-iteration column a column rather than a bag.
  result = @[]
  if loopIndex < 0 or loopIndex >= window.loops.len:
    return

  let loop = window.loops[loopIndex]
  var candidates: seq[tuple[stepCount: int, line: int]] = @[]

  if iteration >= 0 and iteration < loop.iterationSteps.len:
    for entry in loop.iterationSteps[iteration]:
      if entry.stepCount >= 0 and entry.stepCount < window.steps.len:
        candidates.add((stepCount: entry.stepCount,
                        line: window.steps[entry.stepCount].line))

  for stepCount in loop.stepCounts:
    if stepCount < 0 or stepCount >= window.steps.len:
      continue
    let step = window.steps[stepCount]
    if step.loopIndex == loopIndex and step.iteration == iteration:
      candidates.add((stepCount: stepCount, line: step.line))

  result = orderIterationSteps(candidates)

func iterationStepAt*(window: FlowLayoutWindow;
                      loopIndex, iteration, line: int): int =
  ## The step of `loopIndex`'s `iteration` that sits on `line`, or `NoStep`.
  ##
  ## Moved from `ui/flow.nim:loopIterationStepAt`. Used with `loop.first` it is
  ## "the loop header on this pass", which is what the loop control jumps to
  ## when the pass recorded no body statement.
  if loopIndex < 0 or loopIndex >= window.loops.len:
    return NoStep
  let loop = window.loops[loopIndex]
  if iteration < 0 or iteration >= loop.iterationSteps.len:
    return NoStep
  for entry in loop.iterationSteps[iteration]:
    if entry.line == line:
      if entry.stepCount >= 0 and entry.stepCount < window.steps.len:
        return entry.stepCount
      return NoStep
  NoStep

func firstBodyStepForIteration*(window: FlowLayoutWindow;
                                loopIndex, iteration: int): int =
  ## The first statement *inside* the loop body on this pass, or `NoStep`.
  ##
  ## Moved from `ui/flow.nim:firstLoopBodyStepForIteration`. Selecting an
  ## iteration is a navigation, and what the reader must end up looking at is
  ## the iteration's code rather than the `for` header they were already on —
  ## `Omniscience-Flow.md` lists `NoirSpaceShip.SimpleLoopIterationJump`
  ## ("Enter iteration number, verify cursor") among its implemented tests.
  ##
  ## Strictly `> loop.first` and `<= loop.last`, so the header is excluded and
  ## the closing line is not. Falls back to the header when the pass recorded no
  ## body statement at all — an empty body, or a recorder that only emits the
  ## header, is the one case where the header *is* where the iteration exists.
  if loopIndex < 0 or loopIndex >= window.loops.len:
    return NoStep
  let loop = window.loops[loopIndex]
  if iteration < 0 or iteration >= loop.iterationSteps.len:
    return NoStep

  let selected = firstBodyStepIn(
    loop.iterationSteps[iteration], loop.first, loop.last, window.steps.len)
  if selected == NoStep:
    return iterationStepAt(window, loopIndex, iteration, loop.first)
  selected

func closestIterationStepCount*(loop: FlowLayoutLoop; stepCount: int): int =
  ## `stepCount` clamped into the loop's recorded span.
  ##
  ## Moved verbatim from `ui/flow.nim:getClosestIterationStepCount` (called from
  ## `ui/editor.nim`). Returns `NoStep` for a loop with no steps, where the
  ## original indexed `stepCounts[0]` and raised.
  if loop.stepCounts.len == 0:
    return NoStep
  let first = loop.stepCounts[0]
  let last = loop.stepCounts[^1]
  if first < stepCount and stepCount < last:
    stepCount
  elif stepCount <= first:
    first
  else:
    last

func activeIteration*(loop: FlowLayoutLoop; locationTicks: int): int =
  ## Which pass through `loop` the debugger is currently inside.
  ##
  ## The containing-interval search of `flow_loop_math.activeIterationForTicks`,
  ## named against a loop so a consumer never has to know that
  ## `rrTicksForIterations` holds interval *starts* rather than positions the
  ## debugger stops on. That misunderstanding was issue #593.
  activeIterationForTicks(loop.rrTicksForIterations, locationTicks)

# ---------------------------------------------------------------------------
# 7. Legend columns and expression columns
#    (spec: "Legend Columns", "Parallel Columns Overlay";
#     from `ui/flow.nim:calculatePositionMaxWidth` + `realignPositionWidths`)
# ---------------------------------------------------------------------------

type
  FlowColumnShare* = object
    ## One variable's share of one line's value row inside a loop.
    expression*: string
    expressionChars*: int
      ## The heading's character budget — `max(len(expression), 3)`.
    valueChars*: int
      ## The cell's character budget — `len(rendered value)` clamped to `[3, 7]`.
    legendShare*: float
      ## Percent of the legend row this heading occupies.
    valueShare*: float
      ## Percent of the value row this cell occupies.

  FlowIterationColumns* = object
    ## One iteration's cell of the parallel band at one source line.
    ##
    ## The spec's "Advanced Loop Visualization": *"a single line in the code may
    ## be traversed multiple times during a single execution, so we need to group
    ## the labels into columns (each column representing one repeating of the
    ## loop)"*. This is one such column.
    iteration*: int
    maxValueChars*: int
      ## The widest this iteration's value row got across the steps that landed
      ## on this line. `valueShare` is a percentage of it.
    valueGapShare*: float
      ## Percent of the value row one inter-cell gap occupies — `100 /
      ## maxValueChars`, i.e. one character.
    columns*: seq[FlowColumnShare]

  FlowPositionColumns* = object
    ## Every iteration's column for one source line inside one loop.
    line*: int
    loopIndex*: int
    expressionChars*: int
      ## The legend row's total character budget, which every `legendShare` is a
      ## percentage of. Taken from the FIRST step seen at this line, matching
      ## `calculatePositionMaxWidth`'s `if loopPosition.expressionsChars == 0`:
      ## the heading row is written once and the iterations align to it, so a
      ## later step that captured more variables must not silently re-flow the
      ## headings the reader has already read.
    legendGapShare*: float
      ## Percent of the legend row one inter-heading gap occupies.
    maxPositionValueChars*: int
      ## The widest value row over all of this line's iterations. What a
      ## renderer multiplies by its character advance to get a default column
      ## width — `ui/flow.nim` called that `defaultIterationWidth` and did the
      ## multiplication by `pixelsPerSymbol` in the same proc, which is exactly
      ## the pixel that does not belong here.
    iterations*: seq[FlowIterationColumns]

  FlowLoopColumnPlan* = object
    ## The parallel band of one loop: its legend, and its lines' columns.
    loopIndex*: int
    legendChars*: int
      ## The legend's character budget for the whole loop — the widest
      ## `expressionChars` over its lines. `ui/flow.nim` kept this as
      ## `LoopState.legendWidth`, already multiplied into pixels.
    legend*: seq[string]
      ## The column headings, in the order they are drawn. The spec's "Legend
      ## Columns — variable names as column headers"; taken from the same first
      ## step `expressionChars` is.
    positions*: seq[FlowPositionColumns]

func valueBudgetChars*(valueText: string): int =
  ## A value cell's character budget.
  ##
  ## From `ui/flow.nim:calculatePositionMaxWidth`. The upper clamp is the
  ## interesting half: a loop draws every pass side by side, so one long value
  ## on one pass must not set the width of the entire band. A renderer truncates
  ## or ellipsises past this; the number is not a claim that the text fits.
  result = valueText.len
  if result < MinValueChars:
    result = MinValueChars
  if result > MaxValueChars:
    result = MaxValueChars

func expressionBudgetChars*(expression: string): int =
  ## A legend heading's character budget. From the same proc.
  max(expression.len, MinExpressionChars)

func computeLoopColumnPlan*(window: FlowLayoutWindow; loopIndex: int):
    FlowLoopColumnPlan =
  ## The parallel-column plan for one loop of the window.
  ##
  ## Transcribed from `ui/flow.nim:calculatePositionMaxWidth` (accumulation) and
  ## `realignPositionWidths` (the percentages), which between them are the whole
  ## of the spec's "Expression Columns" and "Legend Columns". Everything those
  ## two procs did in characters and percentages is here; the two places they
  ## multiplied by `pixelsPerSymbol` are not, and are the renderer's.
  ##
  ## **Neither original proc had a call site.** `calculatePositionMaxWidth` was
  ## defined at `ui/flow.nim:2150` and `realignPositionWidths` at 2210, and
  ## nothing in the tree called either. They were also the only writers of
  ## `LoopState.positions`, so `makeLegend` — which *is* called — indexes an
  ## empty map and dereferences the `undefined` it gets back. The desktop's loop
  ## legend does not render at all; it is not merely laid out at `0%`. That
  ## defect is deliberately NOT fixed by this extraction — a refactor must not
  ## change what the desktop draws — and is recorded in
  ## `Omniscience-Flow.md` and in `ui/flow.nim` where the procs used to be.
  ##
  ## The practical consequence for this extraction is that these percentages are
  ## reaching a renderer for the first time, and the first renderer to draw them
  ## will be BlockTracer's rather than the desktop's.
  result = FlowLoopColumnPlan(
    loopIndex: loopIndex, legendChars: 0, legend: @[], positions: @[])
  if loopIndex < 0 or loopIndex >= window.loops.len:
    return

  # The lines this loop touched, ascending — `calculatePositionMaxWidth` was
  # called per step and keyed `loopState.positions` by `step.position`.
  var lines: seq[int] = @[]
  for step in window.steps:
    if step.loopIndex != loopIndex or step.line <= 0:
      continue
    var seen = false
    for line in lines:
      if line == step.line:
        seen = true
        break
    if not seen:
      lines.add(step.line)
  lines.sort(system.cmp[int])

  for line in lines:
    var position = FlowPositionColumns(
      line: line, loopIndex: loopIndex, expressionChars: 0,
      legendGapShare: 0.0, maxPositionValueChars: 0, iterations: @[])
    var legendForLine: seq[string] = @[]

    for step in window.steps:
      if step.loopIndex != loopIndex or step.line != line:
        continue

      var iterIndex = -1
      for i, entry in position.iterations:
        if entry.iteration == step.iteration:
          iterIndex = i
          break
      if iterIndex < 0:
        position.iterations.add(FlowIterationColumns(
          iteration: step.iteration, maxValueChars: 0,
          valueGapShare: 0.0, columns: @[]))
        iterIndex = position.iterations.high

      var stepValueChars = 0
      var stepExpressionChars = 0
      for value in step.beforeValues:
        let expressionChars = expressionBudgetChars(value.expression)
        let valueChars = valueBudgetChars(value.text)
        var known = false
        for column in position.iterations[iterIndex].columns:
          if column.expression == value.expression:
            known = true
            break
        if not known:
          position.iterations[iterIndex].columns.add(FlowColumnShare(
            expression: value.expression,
            expressionChars: expressionChars,
            valueChars: valueChars,
            legendShare: 0.0,
            valueShare: 0.0))
        stepExpressionChars += expressionChars + 1
        stepValueChars += valueChars + 1
      # One trailing separator too many was added inside the loop.
      stepExpressionChars -= 1
      stepValueChars -= 1

      if position.expressionChars == 0 and stepExpressionChars > 0:
        position.expressionChars = stepExpressionChars
        position.legendGapShare = 100.0 / float(stepExpressionChars)
        for value in step.beforeValues:
          legendForLine.add(value.expression)

      if stepValueChars > position.iterations[iterIndex].maxValueChars:
        position.iterations[iterIndex].maxValueChars = stepValueChars
      if stepValueChars > position.maxPositionValueChars:
        position.maxPositionValueChars = stepValueChars

    # `realignPositionWidths`, per iteration.
    for i in 0 ..< position.iterations.len:
      let maxValueChars = position.iterations[i].maxValueChars
      if maxValueChars > 0:
        position.iterations[i].valueGapShare = 100.0 / float(maxValueChars)
      for j in 0 ..< position.iterations[i].columns.len:
        if maxValueChars > 0:
          position.iterations[i].columns[j].valueShare =
            float(position.iterations[i].columns[j].valueChars) * 100.0 /
              float(maxValueChars)
        if position.expressionChars > 0:
          position.iterations[i].columns[j].legendShare =
            float(position.iterations[i].columns[j].expressionChars) * 100.0 /
              float(position.expressionChars)

    position.iterations.sort(proc(a, b: FlowIterationColumns): int =
      cmp(a.iteration, b.iteration))

    if position.expressionChars > result.legendChars:
      result.legendChars = position.expressionChars
      result.legend = legendForLine
    result.positions.add(position)

func legendColumns*(plan: FlowLoopColumnPlan; line: int): seq[string] =
  ## The column headings drawn above `line`'s band, in order.
  ##
  ## Empty when the line carries no loop columns, which is the honest answer:
  ## the reader is looking at a line the loop never reached on any pass.
  for position in plan.positions:
    if position.line == line and position.iterations.len > 0:
      for column in position.iterations[0].columns:
        result.add(column.expression)
      return
  @[]

# ---------------------------------------------------------------------------
# 8. The composed layout — what a renderer consumes
# ---------------------------------------------------------------------------

type
  FlowLabel* = object
    ## One inline label: a variable, at a place, in a mode.
    ##
    ## Everything the spec's three renderings need and nothing more. The label
    ## text itself is the renderer's — `[x=10]`, `x: 10 → 20` and a two-cell
    ## table row are the same label in three surfaces, and picking the brackets
    ## here would be picking one of them.
    expression*: string
    beforeText*: string
    afterText*: string
    mode*: FlowValueMode
    sourceColumn*: int
      ## 0-based column of the expression in its source line.
    anchorColumn*: int
      ## 1-based column the label attaches at — `inlineLabelAnchorColumn`.
    slot*: int
      ## The label's ordinal in its line's left-to-right run. A renderer with no
      ## column geometry at all (a `<table>`, a list) uses this and ignores the
      ## two columns above.
    stepCount*: int
    loopIndex*: int
    iteration*: int

  FlowLineLayout* = object
    ## One source line's labels, and how the line sits.
    line*: int
    indentLevel*: int
    loopIndex*: int
      ## The loop the labels belong to; 0 for a line outside any real loop,
      ## matching the backend's placeholder `loops[0]`.
    iteration*: int
    labels*: seq[FlowLabel]

  FlowLayout* = object
    ## "These labels, at these line/column slots, in this order."
    ##
    ## The whole output of this module, and the whole input a renderer needs to
    ## draw omniscience. No pixel, no unit, no class, no node.
    lines*: seq[FlowLineLayout]
    loopPlans*: seq[FlowLoopColumnPlan]
    activeIterations*: seq[tuple[loopIndex: int, iteration: int]]
      ## Which pass each real loop is showing. Derived from the debugger's tick,
      ## so a consumer that only wants "what is on screen now" reads this rather
      ## than re-deriving it and disagreeing with the loop control (#593).

func labelsForStep*(window: FlowLayoutWindow; stepIndex: int): seq[FlowLabel] =
  ## Every label one step contributes, left to right.
  ##
  ## The composition `ui/flow.nim` performs across `prepareFlowLineVariables`
  ## (place), `sortVariablesPositions` (order) and `flowSimpleValue` (mode), with
  ## the DOM construction removed.
  result = @[]
  if stepIndex < 0 or stepIndex >= window.steps.len:
    return
  let step = window.steps[stepIndex]

  var beforeNames: seq[string] = @[]
  for value in step.beforeValues:
    beforeNames.add(value.expression)
  var afterNames: seq[string] = @[]
  for value in step.afterValues:
    afterNames.add(value.expression)

  let placed = assignExpressionColumns(
    window.lineText(step.line), step.exprOrder, beforeNames, afterNames)
  let ordered = orderExpressionsByColumn(placed, ascending = true)

  for slot, entry in ordered:
    var beforeText = ""
    var hasBefore = false
    for value in step.beforeValues:
      if value.expression == entry.expression:
        beforeText = value.text
        hasBefore = true
        break
    var afterText = ""
    var hasAfter = false
    for value in step.afterValues:
      if value.expression == entry.expression:
        afterText = value.text
        hasAfter = true
        break

    result.add(FlowLabel(
      expression: entry.expression,
      beforeText: beforeText,
      afterText: afterText,
      mode: resolveFlowValueModeForText(
        beforeText, afterText, hasBefore, hasAfter),
      sourceColumn: entry.column,
      anchorColumn: inlineLabelAnchorColumn(
        entry.column, entry.expression.len),
      slot: slot,
      stepCount: step.stepCount,
      loopIndex: step.loopIndex,
      iteration: step.iteration))

func computeFlowLayout*(window: FlowLayoutWindow;
                        locationTicks: int = 0;
                        selectedIterations: openArray[
                          tuple[loopIndex: int, iteration: int]] = []):
    FlowLayout =
  ## The whole placement of one flow window, for one debugger position.
  ##
  ## `selectedIterations` overrides the pass a given loop shows — the loop
  ## slider's state. A loop not named there shows the pass the debugger is
  ## inside, derived from `locationTicks`; that default is the thing #593 got
  ## wrong by defaulting to iteration 0 instead.
  ##
  ## A line inside a loop contributes the labels of its **selected pass only**.
  ## That is the desktop's inline behaviour and the spec's ("Slider allows
  ## iteration navigation; only one iteration shown at a time"). A consumer that
  ## wants every pass at once — the spec's proposed enhancement — reads
  ## `loopPlans` and `iterationStepCounts` instead, which is why both are
  ## exposed rather than folded in here.
  result = FlowLayout(lines: @[], loopPlans: @[], activeIterations: @[])

  # Which pass each real loop is on. Index 0 is the backend's placeholder
  # `Loop::default()` and is never a real loop — `pickFocusedLoop` and
  # `createLoopStates` skip it for the same reason.
  var chosen: seq[tuple[loopIndex: int, iteration: int]] = @[]
  for loopIndex in 1 ..< window.loops.len:
    var iteration = activeIteration(window.loops[loopIndex], locationTicks)
    for entry in selectedIterations:
      if entry.loopIndex == loopIndex:
        iteration = entry.iteration
        break
    let maxIteration = maxIterationIndex(window.loops[loopIndex])
    if maxIteration < 0:
      iteration = FirstIterationIndex
    elif iteration < FirstIterationIndex:
      iteration = FirstIterationIndex
    elif iteration > maxIteration:
      iteration = maxIteration
    chosen.add((loopIndex: loopIndex, iteration: iteration))
    result.loopPlans.add(computeLoopColumnPlan(window, loopIndex))
  result.activeIterations = chosen

  func selectedFor(loopIndex: int): int =
    for entry in chosen:
      if entry.loopIndex == loopIndex:
        return entry.iteration
    FirstIterationIndex

  for group in groupStepsByLine(window):
    var layout = FlowLineLayout(
      line: group.line,
      indentLevel: sourceIndentLevel(
        window.lineText(group.line),
        if window.tabSize > 0: window.tabSize else: 4),
      loopIndex: 0,
      iteration: FirstIterationIndex,
      labels: @[])

    for stepIndex in group.stepCounts:
      let step = window.steps[stepIndex]
      if step.loopIndex > 0 and step.loopIndex < window.loops.len:
        if step.iteration != selectedFor(step.loopIndex):
          continue
      layout.loopIndex = step.loopIndex
      layout.iteration = step.iteration
      for label in labelsForStep(window, stepIndex):
        layout.labels.add(label)

    result.lines.add(layout)
