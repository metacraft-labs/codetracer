## SDK-CONSUMER: Omniscience layout, driven with no renderer at all.
##
## test_flow_layout.nim
##
## ## What this suite is for
##
## `codetracer-specs/GUI/Debugging-Features/Omniscience-Flow.md` names five
## computations that decide where an inline value goes — expression columns,
## legend columns, indentation tracking, the loop iteration window, and the
## Before/After value modes. Until `viewmodels/flow_layout.nim` existed all five
## lived in `src/frontend/ui/flow.nim`: 5,161 lines of Karax, Monaco view zones
## and `noUiSlider`, of which only 66 are actually JS interop. The consequence
## was not only that a second renderer would have to reimplement them — it was
## that **none of them had a test**, because testing any of them required an
## Electron renderer with a live Monaco model.
##
## Every case below runs in a process with no DOM, no Monaco and no Karax, on
## both the C and the JS backend (`vm-unit` and `vm-unit-js`).
##
## ## Two kinds of case, deliberately
##
##   1. **Unit cases over synthetic input.** Each extracted decision, with the
##      value it must produce spelled out. These are the ones that say what the
##      layer promises.
##
##   2. **A characterisation case over a REAL recording.**
##      `fixtures/flow/zk_shields_flow_window.json` is a `ct/load-flow` window
##      captured from the `zk_shields` Noir program by
##      `fixtures/flow/capture_zk_shields_flow.nim` — 1315 steps, 80 calls,
##      depth 3, and a `for` loop in which `remaining_shield` takes 29 distinct
##      values from 10000 down under `-=`/`+=`. The whole layout is rendered to
##      text and compared against a golden transcript held in this file.
##
##      That golden is what makes a silent change to inline value placement
##      visible. A refactor that moved a label one column, or reordered two
##      labels on a line, or picked a different iteration, changes the
##      transcript and fails here — which is exactly the failure the desktop
##      would otherwise show only to a human looking at the editor.
##
## ## Why the golden cannot pass with its subject absent
##
## The transcript contains recorded variable names and recorded values from the
## trace. A `computeFlowLayout` that returned an empty layout, or one that
## dropped labels, produces a transcript that is not this string. The fixture is
## `staticRead` at compile time, so a missing or truncated fixture is a compile
## error rather than a green run over nothing — and `test "the fixture is the
## real recording"` asserts the counts the trace is known to have before any
## layout is computed.
##
## Compile and run:
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_flow_layout.nim
##   nim js -d:nodejs -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_flow_layout.nim

import std/[json, strutils, unittest]

# Through the facade, not `viewmodels/flow_layout` directly. That is the point
# of the `SDK-CONSUMER` marker above and of `ci/test/sdk-facade-boundary.sh`:
# if the layout layer is worth extracting, it is worth a consumer being able to
# reach it the way every other consumer reaches the SDK — and this suite is the
# first consumer of it.
import codetracer_embed

# ---------------------------------------------------------------------------
# 1. Before/After value modes  (spec: "Before/After Values")
# ---------------------------------------------------------------------------

suite "Omniscience — before/after value modes":

  test "an unchanged value reads as one value, not an arrow":
    # The spec's `[x=10]`. `testEq` won in `ui/flow.nim:getFlowValueMode` and
    # wins here: an assignment that did not change the variable must not be
    # drawn as a transition.
    check resolveFlowValueMode(hasBefore = true, hasAfter = true,
                               valuesEqual = true) == fvmBefore

  test "a changed value reads as a transition":
    # The spec's `[x: 10→20]`.
    check resolveFlowValueMode(hasBefore = true, hasAfter = true,
                               valuesEqual = false) == fvmBeforeAndAfter

  test "a value recorded only after the step is an after-value":
    # The spec's `[→230]` — a return value has no before.
    check resolveFlowValueMode(hasBefore = false, hasAfter = true,
                               valuesEqual = false) == fvmAfter

  test "a value recorded only before the step is a before-value":
    check resolveFlowValueMode(hasBefore = true, hasAfter = false,
                               valuesEqual = false) == fvmBefore

  test "the text-only overload agrees on identical renderings":
    # A consumer with pre-rendered strings (a review dataset, a JSON wire
    # format) has no structure to compare. Two values that print the same are
    # one value to it, and drawing `10 → 10` would be worse than the equality.
    check resolveFlowValueModeForText("10", "10", true, true) == fvmBefore
    check resolveFlowValueModeForText("10", "20", true, true) ==
      fvmBeforeAndAfter
    check resolveFlowValueModeForText("", "230", false, true) == fvmAfter

# ---------------------------------------------------------------------------
# 2. Expression columns  (spec: "Expression Columns")
# ---------------------------------------------------------------------------

suite "Omniscience — expression columns":

  test "an expression is found at its own column":
    let text = "  let sum = x + y"
    check findExpressionColumn(text, "sum") == 6
    check findExpressionColumn(text, "x") == 12
    check findExpressionColumn(text, "y") == 16

  test "a substring of a longer identifier is not a match":
    # `sum` must not match inside `sums`, or the label lands on the wrong
    # expression — and both names occurring on one line is ordinary code.
    check findExpressionColumn("let sums = 1", "sum") == NoColumn
    check findExpressionColumn("let sums = sum", "sum") == 11
    check findExpressionColumn("if x < 2:", "i") == NoColumn

  test "quoting counts as identifier context":
    # `'` and `"` are identifier characters in `isFlowIdentifierChar`, so a
    # search for `x` skips `"x"` — the string literal is not the variable.
    check isFlowIdentifierChar('\'')
    check isFlowIdentifierChar('"')
    check findExpressionColumn("print(\"x\")", "x") == NoColumn
    check findExpressionColumn("print(\"x\", x)", "x") == 11

  test "an absent expression is parked past the line, in placement order":
    # A return value has no expression text at all. Parking rather than
    # dropping is the decision: a recorded value must be shown somewhere.
    let lineLength = 20
    check fallbackExpressionColumn(lineLength, 0) == 22
    check fallbackExpressionColumn(lineLength, 1) == 24
    check fallbackExpressionColumn(lineLength, 2) == 26

  test "an empty expression matches nothing":
    check findExpressionColumn("anything", "") == NoColumn

  test "placement follows evaluation order, then before, then after":
    # `assignExpressionColumns` is `prepareFlowLineVariables`' three passes.
    # Two of these expressions are not in the source text, so which of them
    # gets the earlier parking slot is decided by that order — which is why
    # the order is asserted rather than assumed.
    let placed = assignExpressionColumns(
      sourceText = "  total = total + i",
      exprOrder = @["total", "i"],
      beforeExpressions = @["total", "i", "hidden"],
      afterExpressions = @["total", "alsoHidden"])
    check placed.len == 4
    check placed[0].expression == "total"
    check placed[0].column == 2
    check placed[0].found
    check placed[1].expression == "i"
    check placed[1].column == 18
    check placed[1].found
    check placed[2].expression == "hidden"
    check not placed[2].found
    check placed[2].column == fallbackExpressionColumn(19, 2)
    check placed[3].expression == "alsoHidden"
    check placed[3].column == fallbackExpressionColumn(19, 3)

  test "an expression is placed once, however many lists name it":
    let placed = assignExpressionColumns(
      "let x = 1", @["x", "x"], @["x"], @["x"])
    check placed.len == 1
    check placed[0].column == 4

  test "labels read left to right by source column":
    # `ui/flow.nim:sortVariablesPositions` with its single call site's
    # argument. The ordering IS the reading order of `[x=10] [y=20] [sum=30]`.
    let placed = assignExpressionColumns(
      "  let sum = x + y", @[], @["sum", "x", "y"], @[])
    var names: seq[string] = @[]
    for entry in orderExpressionsByColumn(placed, ascending = true):
      names.add(entry.expression)
    check names == @["sum", "x", "y"]

    var reversed: seq[string] = @[]
    for entry in orderExpressionsByColumn(placed, ascending = false):
      reversed.add(entry.expression)
    check reversed == @["y", "x", "sum"]

  test "the sort is stable, so co-located labels keep placement order":
    let placed = @[
      FlowExpressionColumn(expression: "a", column: 5, found: false),
      FlowExpressionColumn(expression: "b", column: 5, found: false),
      FlowExpressionColumn(expression: "c", column: 1, found: true)]
    var names: seq[string] = @[]
    for entry in orderExpressionsByColumn(placed, ascending = true):
      names.add(entry.expression)
    check names == @["c", "a", "b"]

  test "the source tokenizer names every identifier on a line, last first":
    # `ui/flow.nim:tokenizeExpressions`. The reversal is not cosmetic: its
    # consumer (`ensureTokens`) reads the result in that order, so a "tidier"
    # ascending result would silently change which token wins a duplicate name.
    let nim = nimFlowTokenLanguage(@["let", "var", "for", "in"])
    var seen: seq[string] = @[]
    var columns: seq[int] = @[]
    for token in tokenizeSourceExpressions("  let sum = x + y", nim):
      seen.add(token.expression)
      columns.add(token.column)
    check seen == @["y", "x", "sum"]
    check columns == @[16, 12, 6]

  test "a keyword is dropped rather than emitted with an empty name":
    let nim = nimFlowTokenLanguage(@["let", "for", "in"])
    var seen: seq[string] = @[]
    for token in tokenizeSourceExpressions("for item in items", nim):
      seen.add(token.expression)
    check seen == @["items", "item"]

  test "text inside a string literal is not an expression":
    let nim = nimFlowTokenLanguage(@["echo"])
    var seen: seq[string] = @[]
    for token in tokenizeSourceExpressions("echo \"hidden\" & shown", nim):
      seen.add(token.expression)
    check seen == @["shown"]

  test "a language with no identifier characters yields nothing":
    # Every language except Nim, on the desktop today: `isSymbol` answered
    # `false` for all of them. Preserved by the extraction rather than widened,
    # and asserted so that widening it later is a visible decision.
    let none = flowTokenLanguage({}, {}, @[])
    check tokenizeSourceExpressions("let sum = x + y", none).len == 0

  test "digits do not continue an identifier":
    # `isSymbol` is `isAlphaAscii or '_'`, so `x1` yields `x`. A quirk, pinned
    # because correcting it would change what the desktop tokenizes.
    let nim = nimFlowTokenLanguage(@[])
    var seen: seq[string] = @[]
    for token in tokenizeSourceExpressions("x1 + y", nim):
      seen.add(token.expression)
    check seen == @["y", "x"]

  test "a label anchors immediately after its expression":
    # `let sum = x + y` — `sum` starts at column 6 (0-based) and is 3 long, so
    # the label goes at 1-based column 10, i.e. the space after `sum`.
    check inlineLabelAnchorColumn(6, 3) == 10
    check inlineLabelAnchorColumn(0, 1) == 2

# ---------------------------------------------------------------------------
# 3. Indentation tracking  (spec: "Indentation Tracking")
# ---------------------------------------------------------------------------

suite "Omniscience — indentation tracking":

  test "nesting is counted in indent levels, not characters":
    check sourceIndentLevel("fn main() {", 4) == 0
    check sourceIndentLevel("    let x = 1;", 4) == 1
    check sourceIndentLevel("        let y = 2;", 4) == 2

  test "a tab advances to the next tab stop":
    # Not "a tab is worth tabSize": a tab in the middle of a partial indent
    # closes that indent, which is what an editor's guides show.
    check sourceIndentLevel("\tlet x = 1;", 4) == 1
    check sourceIndentLevel("  \tlet x = 1;", 4) == 1
    check sourceIndentLevel("\t\tlet x = 1;", 4) == 2
    check sourceIndentLevel("  let x = 1;", 2) == 1

  test "a blank line has no nesting of its own":
    # Whitespace with nothing after it is not a statement about structure, and
    # a blank line between two nested statements must not read as deeper than
    # either of them.
    check sourceIndentLevel("", 4) == 0
    check sourceIndentLevel("        ", 4) == 0

  test "a nonsense tab size is refused rather than dividing by zero":
    check sourceIndentLevel("    x", 0) == 0

# ---------------------------------------------------------------------------
# 4. Loop iteration windowing  (spec: "Loop Visualization", "Loop Slider")
# ---------------------------------------------------------------------------

proc sampleLoop(): FlowLayoutLoop =
  ## A three-iteration loop over lines 7..9, with a header at 7.
  FlowLayoutLoop(
    base: -1, baseIteration: 0, internal: @[],
    first: 7, last: 9, registeredLine: 7,
    stepCounts: @[1, 2, 3, 4, 5, 6],
    rrTicksForIterations: @[100, 200, 300],
    iterationSteps: @[
      @[(line: 7, stepCount: 1), (line: 8, stepCount: 2), (line: 9, stepCount: 3)],
      @[(line: 7, stepCount: 4), (line: 8, stepCount: 5), (line: 9, stepCount: 6)],
      @[(line: 7, stepCount: 7)]])

suite "Omniscience — loop iteration windowing":

  test "the iteration count is the loop's selectable range":
    check maxIterationIndex(sampleLoop()) == 2
    check maxIterationIndex(FlowLayoutLoop()) == -1

  test "a body tick maps onto the iteration that contains it":
    # #593: a header tick is the debugger's position on exactly one step of
    # each pass, so an equality test essentially never matches and the counter
    # freezes at 0. The search is for the containing interval.
    let loop = sampleLoop()
    check activeIteration(loop, 100) == 0
    check activeIteration(loop, 150) == 0   # inside iteration 0's body
    check activeIteration(loop, 200) == 1
    check activeIteration(loop, 250) == 1
    check activeIteration(loop, 999) == 2   # past the last header
    check activeIteration(loop, 1) == 0     # before the first

  test "a tick is mapped onto the line's step by containing interval":
    check stepIndexForTicks(@[10, 20, 30], 5) == 0    # before the first
    check stepIndexForTicks(@[10, 20, 30], 10) == 0
    check stepIndexForTicks(@[10, 20, 30], 15) == 0
    check stepIndexForTicks(@[10, 20, 30], 25) == 1
    check stepIndexForTicks(@[10, 20, 30], 99) == 2   # past the last

  test "an interval is closed at BOTH ends, so a shared tick takes the earlier step":
    # A quirk of `ui/flow.nim:positionRRTicksToStepCount` and therefore of this
    # function: the containment test is `>= ticks[i] and <= ticks[i+1]`, so a
    # tick that lands exactly on the NEXT step's tick still matches the current
    # interval and resolves to the earlier step. Pinned rather than corrected —
    # the extraction is a refactor, and "fixing" it here would move a label on
    # the desktop for a reason no reader of this suite asked for.
    check stepIndexForTicks(@[10, 20, 30], 20) == 0
    check stepIndexForTicks(@[10, 20, 30], 30) == 1

  test "a line with no steps in this window is not an error":
    # It is the ordinary case: the window covers one call, and callers ask
    # about lines that are blank, never executed, or outside it.
    check stepIndexForTicks(@[], 5) == NoStep

  test "an iteration's steps read top to bottom, deduplicated":
    # The two sources overlap by construction, so dropping the dedup would
    # double every step; dropping the sort would emit them in table order,
    # which is the deserialiser's habit rather than the reader's.
    check orderIterationSteps(@[
      (stepCount: 9, line: 12),
      (stepCount: 4, line: 10),
      (stepCount: 9, line: 12),
      (stepCount: 7, line: 10)]) == @[4, 7, 9]

  test "two visits to one line within a pass keep execution order":
    check orderIterationSteps(@[
      (stepCount: 8, line: 10),
      (stepCount: 3, line: 10)]) == @[3, 8]

  test "selecting an iteration lands on its first body line, not the header":
    # `NoirSpaceShip.SimpleLoopIterationJump` — "Enter iteration number, verify
    # cursor". The header is where the loop condition is, not where the pass's
    # code is.
    let loop = sampleLoop()
    check firstBodyStepIn(loop.iterationSteps[0], loop.first, loop.last,
                          stepCountLimit = 100) == 2
    check firstBodyStepIn(loop.iterationSteps[1], loop.first, loop.last,
                          stepCountLimit = 100) == 5

  test "a pass with no body statement falls back to nothing here":
    # Iteration 2 of the sample recorded only its header, so the body search
    # finds none; `firstBodyStepForIteration` is where the header fallback
    # lives, and the window-level case below covers it.
    let loop = sampleLoop()
    check firstBodyStepIn(loop.iterationSteps[2], loop.first, loop.last,
                          stepCountLimit = 100) == NoStep

  test "a step index past the window is refused":
    # Step counts are window-relative and the window is replaced on every
    # move, so a stale index must not be dereferenced.
    let loop = sampleLoop()
    check firstBodyStepIn(loop.iterationSteps[0], loop.first, loop.last,
                          stepCountLimit = 2) == NoStep

  test "a step count is clamped into the loop's recorded span":
    let loop = sampleLoop()
    check closestIterationStepCount(loop, 3) == 3
    check closestIterationStepCount(loop, 0) == 1
    check closestIterationStepCount(loop, 99) == 6

  test "a loop with no recorded steps answers rather than raising":
    check closestIterationStepCount(FlowLayoutLoop(), 3) == NoStep

# ---------------------------------------------------------------------------
# 5. Legend columns  (spec: "Legend Columns", "Parallel Columns Overlay")
# ---------------------------------------------------------------------------

proc columnWindow(): FlowLayoutWindow =
  ## One loop, one body line, two passes, two variables.
  FlowLayoutWindow(
    tabSize: 4,
    sourceLines: @[
      "fn main() {",
      "    for i in 0..2 {",
      "        total = total + i;",
      "    }",
      "}"],
    loops: @[
      FlowLayoutLoop(),                       # the backend's placeholder
      FlowLayoutLoop(first: 2, last: 3, registeredLine: 2,
                     stepCounts: @[0, 1],
                     rrTicksForIterations: @[10, 20],
                     iterationSteps: @[
                       @[(line: 3, stepCount: 0)],
                       @[(line: 3, stepCount: 1)]])],
    steps: @[
      FlowLayoutStep(stepCount: 0, line: 3, loopIndex: 1, iteration: 0,
                     rrTicks: 11, exprOrder: @["total", "i"],
                     beforeValues: @[
                       FlowValueText(expression: "total", text: "0"),
                       FlowValueText(expression: "i", text: "0")],
                     afterValues: @[
                       FlowValueText(expression: "total", text: "0")]),
      FlowLayoutStep(stepCount: 1, line: 3, loopIndex: 1, iteration: 1,
                     rrTicks: 21, exprOrder: @["total", "i"],
                     beforeValues: @[
                       FlowValueText(expression: "total", text: "0"),
                       FlowValueText(expression: "i", text: "1")],
                     afterValues: @[
                       FlowValueText(expression: "total", text: "1")])])

suite "Omniscience — legend and value column shares":

  test "a heading is never budgeted below the floor":
    check expressionBudgetChars("i") == MinExpressionChars
    check expressionBudgetChars("total") == 5

  test "a value cell's budget is clamped at both ends":
    # The upper clamp is what stops one long value on one pass from setting
    # the width of a whole side-by-side band.
    check valueBudgetChars("1") == MinValueChars
    check valueBudgetChars("10000") == 5
    check valueBudgetChars("a very long rendering") == MaxValueChars

  test "a loop's legend names its columns in order":
    let plan = computeLoopColumnPlan(columnWindow(), 1)
    check plan.loopIndex == 1
    check plan.legend == @["total", "i"]
    check legendColumns(plan, 3) == @["total", "i"]
    check legendColumns(plan, 99).len == 0

  test "the legend row's shares are of the row, not of a pixel width":
    # `total` is 5 characters and `i` is budgeted at the 3-character floor, so
    # the row is 5 + 1 + 3 = 9 characters wide and the two headings take
    # 5/9 and 3/9 of it. Nothing here is a pixel or a font metric.
    let plan = computeLoopColumnPlan(columnWindow(), 1)
    check plan.positions.len == 1
    let position = plan.positions[0]
    check position.line == 3
    check position.expressionChars == 9
    check abs(position.legendGapShare - 100.0 / 9.0) < 1e-9
    check position.iterations.len == 2
    let columns = position.iterations[0].columns
    check columns.len == 2
    check columns[0].expression == "total"
    check columns[0].expressionChars == 5
    check abs(columns[0].legendShare - 500.0 / 9.0) < 1e-9
    check columns[1].expression == "i"
    check columns[1].expressionChars == 3
    check abs(columns[1].legendShare - 300.0 / 9.0) < 1e-9

  test "value shares are of that iteration's own widest row":
    # Both values are one character and so take the 3-character floor: the
    # row is 3 + 1 + 3 = 7 wide and each cell is 3/7 of it.
    let plan = computeLoopColumnPlan(columnWindow(), 1)
    let iteration = plan.positions[0].iterations[0]
    check iteration.maxValueChars == 7
    check abs(iteration.valueGapShare - 100.0 / 7.0) < 1e-9
    for column in iteration.columns:
      check column.valueChars == 3
      check abs(column.valueShare - 300.0 / 7.0) < 1e-9

  test "each pass of the loop gets its own column":
    let plan = computeLoopColumnPlan(columnWindow(), 1)
    check plan.positions[0].iterations[0].iteration == 0
    check plan.positions[0].iterations[1].iteration == 1

  test "a loop index outside the window yields an empty plan":
    check computeLoopColumnPlan(columnWindow(), 99).positions.len == 0
    check computeLoopColumnPlan(columnWindow(), -1).legend.len == 0

# ---------------------------------------------------------------------------
# 6. Per-line grouping and the composed layout
# ---------------------------------------------------------------------------

suite "Omniscience — per-line grouping and the composed layout":

  test "steps are grouped by source line, lines ascending":
    let groups = groupStepsByLine(columnWindow())
    check groups.len == 1
    check groups[0].line == 3
    check groups[0].stepCounts == @[0, 1]

  test "a line inside a loop shows the selected pass only":
    # The desktop's inline behaviour and the spec's: "only one iteration shown
    # at a time". Showing both passes' labels on one line is the "stale value
    # from a previous pass" reading the loop control exists to prevent.
    let window = columnWindow()
    let first = computeFlowLayout(window, locationTicks = 11)
    check first.lines.len == 1
    check first.lines[0].line == 3
    check first.lines[0].iteration == 0
    var firstTexts: seq[string] = @[]
    for label in first.lines[0].labels:
      firstTexts.add(label.expression & "=" & label.beforeText)
    check firstTexts == @["total=0", "i=0"]

    let second = computeFlowLayout(window, locationTicks = 21)
    check second.lines[0].iteration == 1
    var secondTexts: seq[string] = @[]
    for label in second.lines[0].labels:
      secondTexts.add(label.expression & "=" & label.beforeText)
    check secondTexts == @["total=0", "i=1"]

  test "the slider's choice overrides the debugger's position":
    let window = columnWindow()
    let layout = computeFlowLayout(
      window, locationTicks = 11,
      selectedIterations = @[(loopIndex: 1, iteration: 1)])
    check layout.lines[0].iteration == 1
    check layout.activeIterations == @[(loopIndex: 1, iteration: 1)]

  test "an out-of-range selection is clamped, never wrapped":
    let window = columnWindow()
    check computeFlowLayout(window, 11, @[(loopIndex: 1, iteration: 99)])
      .activeIterations == @[(loopIndex: 1, iteration: 1)]
    check computeFlowLayout(window, 11, @[(loopIndex: 1, iteration: -5)])
      .activeIterations == @[(loopIndex: 1, iteration: 0)]

  test "labels carry both a column and an ordinal slot":
    # A renderer with source-column geometry uses `sourceColumn`; one that
    # draws a table or a list uses `slot` and ignores the geometry. Both must
    # be present or one of the two consumers has to recompute the other.
    let layout = computeFlowLayout(columnWindow(), locationTicks = 11)
    let labels = layout.lines[0].labels
    check labels.len == 2
    check labels[0].expression == "total"
    check labels[0].slot == 0
    check labels[0].sourceColumn == 8
    check labels[0].anchorColumn == inlineLabelAnchorColumn(8, 5)
    check labels[1].expression == "i"
    check labels[1].slot == 1
    check labels[1].sourceColumn == 24

  test "the layout carries the line's indentation":
    let layout = computeFlowLayout(columnWindow(), locationTicks = 11)
    check layout.lines[0].indentLevel == 2

  test "a value that changed across the step is a transition":
    # `total` is `0` before and `1` after on the second pass — the spec's
    # `[x: 10→20]`. On the first pass it did not change, and is `[x=10]`.
    let window = columnWindow()
    check computeFlowLayout(window, 21).lines[0].labels[0].mode ==
      fvmBeforeAndAfter
    check computeFlowLayout(window, 11).lines[0].labels[0].mode == fvmBefore

  test "the window answers for a line it does not carry":
    let window = columnWindow()
    check window.lineText(3) == "        total = total + i;"
    check window.lineText(0) == ""
    check window.lineText(999) == ""

  test "the window-level loop lookups agree with the primitives":
    let window = columnWindow()
    check window.stepCountForTicks(3, 11) == 0
    check window.stepCountForTicks(3, 15) == 0
    check window.stepCountForTicks(3, 22) == 1
    check window.stepCountForTicks(99, 11) == NoStep
    check window.iterationStepCounts(1, 0) == @[0]
    check window.iterationStepCounts(1, 1) == @[1]
    check window.iterationStepAt(1, 0, 3) == 0
    check window.iterationStepAt(1, 0, 99) == NoStep
    # Line 3 is the only body line and is > first (2) and <= last (3).
    check window.firstBodyStepForIteration(1, 0) == 0

# ---------------------------------------------------------------------------
# 7. Characterisation over a real recording
# ---------------------------------------------------------------------------

const ZkShieldsWindowJson = staticRead(
  "../fixtures/flow/zk_shields_flow_window.json")
  ## `staticRead` rather than `readFile`: this suite runs on the JS backend
  ## too, where `std/os` is unavailable, and a fixture that has gone missing
  ## must fail the BUILD rather than let the golden case pass over nothing.

proc jsonStr(node: JsonNode; key: string; fallback = ""): string =
  if node.isNil or node.kind != JObject: return fallback
  let child = node.getOrDefault(key)
  if child.isNil or child.kind != JString: return fallback
  child.getStr

proc jsonNum(node: JsonNode; key: string; fallback = 0): int =
  if node.isNil or node.kind != JObject: return fallback
  let child = node.getOrDefault(key)
  if child.isNil: return fallback
  case child.kind
  of JInt: int(child.getBiggestInt)
  of JFloat: int(child.getFloat)
  of JString:
    try: parseInt(child.getStr) except ValueError: fallback
  else: fallback

proc renderValue(node: JsonNode): string =
  ## The value's text as a renderer would print it, compactly.
  ##
  ## This is the CONSUMER's job, not the layer's — `flow_layout` takes
  ## `FlowValueText` and never formats anything, which is exactly why `Value`
  ## (a desktop type that reaches the DOM) is not in its import graph. The
  ## adapter here is deliberately minimal and deliberately honest: the backend's
  ## `Value` (`db-backend/src/value.rs`) carries a scalar's rendering in `i`,
  ## `f`, `text`, `msg` or `cText`, and a composite's in `elements`. Anything it
  ## does not recognise renders empty rather than guessing — reading the `b`
  ## field of a non-boolean, which an earlier draft of this did, printed
  ## `masses=false` for an eight-element array.
  if node.isNil: return ""
  if node.kind != JObject:
    return $node

  let elements = node.getOrDefault("elements")
  if not elements.isNil and elements.kind == JArray and elements.len > 0:
    var parts: seq[string] = @[]
    for element in elements:
      parts.add(renderValue(element))
    return "[" & parts.join(", ") & "]"

  for key in ["i", "f", "text", "msg", "cText"]:
    let child = node.getOrDefault(key)
    if child.isNil: continue
    case child.kind
    of JString:
      if child.getStr.len > 0: return child.getStr
    of JInt: return $child.getBiggestInt
    of JFloat: return $child.getFloat
    else: discard
  ""

proc valuesOf(node: JsonNode): seq[FlowValueText] =
  result = @[]
  if node.isNil or node.kind != JObject:
    return
  for expression, value in node:
    result.add(FlowValueText(expression: expression, text: renderValue(value)))

proc loadFixtureWindow(): tuple[window: FlowLayoutWindow; ticks: int] =
  ## Turn the captured `ct/load-flow` view update into a `FlowLayoutWindow`.
  ##
  ## This is the adapter a consumer writes once — the SDK deliberately does not
  ## own the wire format, and writing it here is also what proves the input type
  ## is reachable from raw DAP JSON with no desktop type in the way.
  let doc = parseJson(ZkShieldsWindowJson)
  let view = doc["viewUpdate"]

  var window = FlowLayoutWindow(tabSize: 4)
  for line in doc["sourceLines"]:
    window.sourceLines.add(line.getStr)

  for step in view["steps"]:
    var entry = FlowLayoutStep(
      stepCount: jsonNum(step, "stepCount"),
      line: jsonNum(step, "position"),
      loopIndex: jsonNum(step, "loop"),
      iteration: jsonNum(step, "iteration"),
      rrTicks: jsonNum(step, "rrTicks"),
      beforeValues: valuesOf(step.getOrDefault("beforeValues")),
      afterValues: valuesOf(step.getOrDefault("afterValues")))
    let order = step.getOrDefault("exprOrder")
    if not order.isNil and order.kind == JArray:
      for expression in order:
        entry.exprOrder.add(expression.getStr)
    window.steps.add(entry)

  let iterationSteps = view.getOrDefault("loopIterationSteps")
  for loopIndex in 0 ..< view["loops"].len:
    let loop = view["loops"][loopIndex]
    var entry = FlowLayoutLoop(
      base: jsonNum(loop, "base", -1),
      baseIteration: jsonNum(loop, "baseIteration"),
      first: jsonNum(loop, "first", -1),
      last: jsonNum(loop, "last", -1),
      registeredLine: jsonNum(loop, "registeredLine", -1))
    let internal = loop.getOrDefault("internal")
    if not internal.isNil and internal.kind == JArray:
      for child in internal:
        entry.internal.add(int(child.getBiggestInt))
    let stepCounts = loop.getOrDefault("stepCounts")
    if not stepCounts.isNil and stepCounts.kind == JArray:
      for child in stepCounts:
        entry.stepCounts.add(int(child.getBiggestInt))
    let ticksForIterations = loop.getOrDefault("rrTicksForIterations")
    if not ticksForIterations.isNil and ticksForIterations.kind == JArray:
      for child in ticksForIterations:
        entry.rrTicksForIterations.add(int(child.getBiggestInt))
    if not iterationSteps.isNil and iterationSteps.kind == JArray and
       loopIndex < iterationSteps.len:
      for iteration in iterationSteps[loopIndex]:
        var pairsForIteration: seq[tuple[line: int, stepCount: int]] = @[]
        let table = iteration.getOrDefault("table")
        if not table.isNil and table.kind == JObject:
          for line, stepCount in table:
            var lineNumber = 0
            try: lineNumber = parseInt(line) except ValueError: continue
            pairsForIteration.add(
              (line: lineNumber, stepCount: int(stepCount.getBiggestInt)))
        entry.iterationSteps.add(pairsForIteration)
    window.loops.add(entry)

  (window: window, ticks: jsonNum(doc["position"], "rrTicks"))

proc transcribe(layout: FlowLayout): string =
  ## The layout as text: "these labels, at these line/column slots, in this
  ## order". Everything the golden pins and nothing that is not a placement.
  var rows: seq[string] = @[]
  for entry in layout.activeIterations:
    rows.add("loop " & $entry.loopIndex & " showing iteration " &
      $entry.iteration)
  for plan in layout.loopPlans:
    rows.add("legend loop " & $plan.loopIndex & " chars=" & $plan.legendChars &
      " [" & plan.legend.join(", ") & "]")
    for position in plan.positions:
      var shares: seq[string] = @[]
      for column in position.iterations[0].columns:
        shares.add(column.expression & ":" & $column.expressionChars & "/" &
          $column.valueChars)
      rows.add("  line " & $position.line & " exprChars=" &
        $position.expressionChars & " maxValueChars=" &
        $position.maxPositionValueChars & " passes=" &
        $position.iterations.len & " [" & shares.join(" ") & "]")
  for line in layout.lines:
    var labels: seq[string] = @[]
    for label in line.labels:
      let rendering =
        case label.mode
        of fvmBefore: label.expression & "=" & label.beforeText
        of fvmAfter: "->" & label.afterText
        of fvmBeforeAndAfter:
          label.expression & ": " & label.beforeText & "->" & label.afterText
      labels.add("@" & $label.sourceColumn & "#" & $label.slot & " " & rendering)
    # No trailing space on a line that contributed no label. The separator is
    # written without one and the labels bring their own, because the golden
    # below is a string constant in a repository whose `trim-trailing-whitespace`
    # pre-commit hook would otherwise silently edit the expectation out from
    # under this test.
    let head = "line " & $line.line & " indent=" & $line.indentLevel &
      " loop=" & $line.loopIndex & " iter=" & $line.iteration & " |"
    rows.add(if labels.len == 0: head else: head & " " & labels.join("  "))
  rows.join("\n")

const ZkShieldsGolden = """loop 1 showing iteration 1
legend loop 1 chars=68 [initial_shield, regeneration, remaining_shield, shield_regen_percentage]
  line 4 exprChars=0 maxValueChars=0 passes=9 []
  line 5 exprChars=10 maxValueChars=11 passes=8 [i:3/3 masses:6/7]
  line 6 exprChars=36 maxValueChars=16 passes=8 [initial_shield:14/5 mass:4/3 remaining_shield:16/5]
  line 7 exprChars=23 maxValueChars=10 passes=8 [damage:6/3 remaining_shield:16/5]
  line 9 exprChars=0 maxValueChars=0 passes=8 []
  line 10 exprChars=16 maxValueChars=4 passes=8 [remaining_shield:16/4]
  line 11 exprChars=68 maxValueChars=18 passes=8 [initial_shield:14/5 regeneration:12/3 remaining_shield:16/4 shield_regen_percentage:23/3]
  line 12 exprChars=29 maxValueChars=9 passes=8 [regeneration:12/3 remaining_shield:16/4]
  line 14 exprChars=55 maxValueChars=24 passes=8 [damage:6/3 i:3/3 initial_shield:14/5 regeneration:12/3 remaining_shield:16/5]
line 1 indent=0 loop=0 iter=0 | @25#0 ->10000  @113#1 return=
line 2 indent=1 loop=0 iter=0 | @31#0 initial_shield=10000
line 4 indent=1 loop=1 iter=1 | @8#0 ->1
line 5 indent=2 loop=1 iter=1 | @12#0 ->2000  @19#1 masses=[100, 2000, 200, 100, 100, 50, 50, 14]  @26#2 i=1
line 6 indent=2 loop=1 iter=1 | @12#0 ->2000  @38#1 initial_shield=10000  @54#2 remaining_shield=10000  @72#3 mass=2000
line 7 indent=2 loop=1 iter=1 | @8#0 remaining_shield=10000  @28#1 damage=2000
line 9 indent=2 loop=1 iter=1 |
line 10 indent=2 loop=1 iter=1 | @12#0 remaining_shield=8000
line 11 indent=2 loop=1 iter=1 | @8#0 regeneration: 0->1000  @53#1 initial_shield=10000  @69#2 remaining_shield=8000  @87#3 shield_regen_percentage=10
line 12 indent=2 loop=1 iter=1 | @8#0 remaining_shield: 8000->9000  @28#1 regeneration=1000
line 14 indent=2 loop=1 iter=1 | @22#0 i=1  @24#1 initial_shield=10000  @40#2 remaining_shield=9000  @58#3 damage=2000  @66#4 regeneration=1000
line 18 indent=1 loop=0 iter=0 | @17#0 remaining_shield=1018  @49#1 return="""

suite "Omniscience — characterisation over the zk_shields recording":

  test "the fixture is the real recording, not a stub":
    # Asserted before any layout is computed, so a fixture that had been
    # emptied or replaced by a placeholder fails HERE rather than silently
    # making the golden case trivial.
    let loaded = loadFixtureWindow()
    check loaded.window.steps.len > 0
    check loaded.window.sourceLines.len > 0
    check loaded.ticks > 0
    var realLoops = 0
    var maxIterations = 0
    for index in 1 ..< loaded.window.loops.len:
      if loaded.window.loops[index].rrTicksForIterations.len > 0:
        realLoops += 1
        if loaded.window.loops[index].rrTicksForIterations.len > maxIterations:
          maxIterations = loaded.window.loops[index].rrTicksForIterations.len
    check realLoops >= 1
    check maxIterations > 1
    var recordedValues = 0
    for step in loaded.window.steps:
      recordedValues += step.beforeValues.len + step.afterValues.len
    check recordedValues > 0

  test "the layout of the real window matches the golden transcript":
    # THE characterisation check. A change that moves a label one column,
    # reorders two labels on a line, or picks a different pass changes this
    # string. Regenerate deliberately, never to make a red go away.
    let loaded = loadFixtureWindow()
    let transcript = transcribe(
      computeFlowLayout(loaded.window, locationTicks = loaded.ticks))
    if transcript != ZkShieldsGolden:
      echo "--- actual transcript ---"
      echo transcript
      echo "--- end ---"
    check transcript == ZkShieldsGolden

  test "every label of the real window is placed somewhere":
    # A label parked past the end of the line is a placement; a label with a
    # negative column is a dropped one, and would be invisible in a renderer
    # that clips.
    let loaded = loadFixtureWindow()
    let layout = computeFlowLayout(loaded.window, loaded.ticks)
    var total = 0
    for line in layout.lines:
      for label in line.labels:
        check label.sourceColumn >= 0
        check label.anchorColumn > label.sourceColumn
        check label.slot >= 0
        total += 1
    check total > 0

  test "the pass shown is the pass the debugger is inside":
    # #593 in one assertion, over real ticks: the layout must not default to
    # iteration 0 for a debugger that is deep into the loop.
    let loaded = loadFixtureWindow()
    let layout = computeFlowLayout(loaded.window, loaded.ticks)
    for entry in layout.activeIterations:
      let loop = loaded.window.loops[entry.loopIndex]
      if loop.rrTicksForIterations.len == 0:
        continue
      check entry.iteration ==
        activeIterationForTicks(loop.rrTicksForIterations, loaded.ticks)
      check entry.iteration >= 0
      check entry.iteration <= maxIterationIndex(loop)
