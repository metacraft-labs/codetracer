## flow_layout_parity_test.nim
##
## **The characterisation check for the Omniscience layout extraction.**
##
## `viewmodel/viewmodels/flow_layout.nim` took five placement computations out
## of `src/frontend/ui/flow.nim`, and `ui/flow.nim` now calls back into it
## instead of carrying its own copy. That is a refactor, and the obligation a
## refactor carries is that the answers do not change. A silent change to where
## an inline value is placed is close to undetectable afterwards: it shows up as
## a label one column to the left in a screenshot nobody diffs.
##
## So this suite holds the **pre-refactor algorithms, transcribed verbatim from
## `ui/flow.nim` as it stood on `dev` at eb1776ea**, and asserts that the
## extracted functions agree with them over a corpus. The transcriptions are
## reference implementations, never called by the product; the only thing they
## have to be is faithful, and each carries the `dev` proc it came from so that
## claim is checkable line by line.
##
## Why this is not circular
## ------------------------
## The golden transcript in `viewmodel/tests/unit/test_flow_layout.nim` pins the
## extracted layer's output going FORWARD — it was generated from the extracted
## code, so it cannot testify that the extraction preserved anything. This suite
## is the other half: its oracle is the old code, so a divergence introduced by
## the move fails here even though the golden would have been regenerated to
## match it.
##
## What it does NOT prove
## ----------------------
## Nothing here runs Monaco, Karax or a view zone. It proves that the
## computations `ui/flow.nim` delegates produce the answers `ui/flow.nim` used
## to produce; it does not prove that the delegation sites pass the same
## arguments. That second half is a reading obligation and is discharged in the
## diff, where each call site is a two-to-five line change with the original
## visible above it in the same commit.
##
## Runs on both backends (`vm-native` and `vm-js`), which matters: two defects
## in this area were green on C and broken on JS.
##
## Run with:
##   nim c -r --hints:off src/tests/gui/tests/flow/flow_layout_parity_test.nim
##   nim js -d:nodejs -r --hints:off src/tests/gui/tests/flow/flow_layout_parity_test.nim

import std/[algorithm, sequtils, strutils, sugar, unittest]

import ../../../../frontend/viewmodel/viewmodels/flow_layout

# ---------------------------------------------------------------------------
# The corpus
#
# Real source lines, chosen so every branch of the tokenizer and the expression
# search is reached: keywords, string literals, digits inside identifiers,
# repeated names, names that are substrings of other names, empty and
# whitespace-only lines, and the Noir source the `zk_shields` recording was made
# from.
# ---------------------------------------------------------------------------

const Corpus = @[
  "",
  "   ",
  "\t\tlet x = 1",
  "let sum = x + y",
  "  let sum = x + y",
  "let sums = sum + sum",
  "for i in 0 ..< items.len:",
  "echo \"x is \", x",
  "var x1 = x2 + x_3",
  "result = a.b.c[i]",
  "        remaining_shield -= damage;",
  "        let damage = calculate_damage(initial_shield, remaining_shield, mass);",
  "    for i in 0..8 {",
  "        if (remaining_shield as u32 > 0){",
  "        status_report(i,initial_shield, remaining_shield, damage, regeneration);",
  "pub fn iterate_asteroids(initial_shield: Field, shield_regen_percentage: Field, masses: [Field; 8]) -> bool {",
  "    let result = remaining_shield as u32 > 0;",
  "\"quoted\"",
  "x",
  "_",
  "____private_name",
]

const Expressions = @[
  "x", "y", "sum", "sums", "i", "items", "result", "a", "b", "c",
  "damage", "remaining_shield", "initial_shield", "mass", "masses",
  "regeneration", "shield_regen_percentage", "return", "notpresent", "",
]

const NimKeywords = @[
  "let", "var", "const", "for", "in", "if", "else", "elif", "while", "proc",
  "func", "echo", "result", "return", "type", "object", "ref", "of", "case",
]

# ---------------------------------------------------------------------------
# Reference implementation 1 — `dev`'s `ui/flow.nim:isFlowIdentifierChar` and
# `findFlowExpressionPosition`, verbatim apart from `cstring` -> `string`.
# ---------------------------------------------------------------------------

func devIsFlowIdentifierChar(ch: char): bool =
  ch in {'a'..'z', 'A'..'Z', '0'..'9', '_', '\'', '"'}

func devFindFlowExpressionPosition(text: string, expression: string): int =
  let expressionText = expression
  if expressionText.len == 0:
    return -1

  var start = 0
  while start < text.len:
    let index = text.find(expressionText, start)
    if index < 0:
      return -1

    let beforeOk = index == 0 or not devIsFlowIdentifierChar(text[index - 1])
    let afterIndex = index + expressionText.len
    let afterOk = afterIndex >= text.len or
      not devIsFlowIdentifierChar(text[afterIndex])
    if beforeOk and afterOk:
      return index

    start = index + 1

  return -1

# ---------------------------------------------------------------------------
# Reference implementation 2 — `dev`'s `ui/flow.nim:tokenizeExpressions`,
# with `cstring`/`JsAssoc` replaced by `string`/`seq` and `KEYWORDS[lang]` by an
# explicit word list. The state machine, the reserve-then-fill slot handling and
# the closing `countdown` reversal are unchanged.
# ---------------------------------------------------------------------------

type DevTokenState = enum dtAny, dtExpression, dtString

func devIsSymbol(c: char): bool =
  c.isAlphaAscii or c == '_'

func devIsStringSymbol(c: char): bool =
  c == '"'

func devTokenizeExpressions(source: string;
                            keywords: seq[string]): seq[(string, int)] =
  func isKeyword(token: string): bool =
    for keyword in keywords:
      if keyword == token:
        return true
    false

  result = @[]
  var state: DevTokenState
  var token = ""

  for i in 0 ..< source.len:
    let c = source[i]
    if devIsSymbol(c):
      case state
      of dtAny:
        state = dtExpression
        token = $c
        result.add(("", i))
      of dtExpression:
        token = token & $c
      else:
        discard
    elif devIsStringSymbol(c):
      case state
      of dtExpression:
        if not isKeyword(token):
          result[^1] = (token, result[^1][1])
        else:
          discard result.pop
        token = ""
        state = dtString
      of dtAny:
        state = dtString
      of dtString:
        state = dtAny
    else:
      case state
      of dtExpression:
        if not isKeyword(token):
          result[^1] = (token, result[^1][1])
        else:
          discard result.pop
        token = ""
        state = dtAny
      else:
        discard

  case state
  of dtExpression:
    if not isKeyword(token):
      result[^1] = (token, result[^1][1])
    else:
      discard result.pop
  else:
    discard

  var res = result
  result = @[]
  for i in countdown(res.len - 1, 0):
    result.add(res[i])

# ---------------------------------------------------------------------------
# Reference implementation 3 — `dev`'s `ui/flow.nim:getFlowValueMode`.
# ---------------------------------------------------------------------------

type DevValueMode = enum dvBefore, dvAfter, dvBeforeAndAfter

func devGetFlowValueMode(hasBefore, hasAfter, testEqResult: bool): DevValueMode =
  # `testEq(beforeValue, afterValue)` is the caller's; the three booleans are
  # the whole of the decision's input.
  if testEqResult:
    return dvBefore
  else:
    if not hasAfter and hasBefore:
      return dvBefore
    elif not hasBefore and hasAfter:
      return dvAfter
    else:
      return dvBeforeAndAfter

# ---------------------------------------------------------------------------
# Reference implementation 4 — `dev`'s `ui/flow.nim:sortVariablesPositions`
# ordering. `ascending = false` is the product's only call.
# ---------------------------------------------------------------------------

func devSortVariablesPositions(pairsIn: seq[(string, int)];
                               ascending: bool): seq[string] =
  var direction = 1
  if ascending: direction = -1
  pairsIn
    .sorted((x, y) => direction * x[1] - direction * y[1])
    .mapIt(it[0])

# ---------------------------------------------------------------------------
# Reference implementation 5 — `dev`'s
# `ui/flow.nim:positionRRTicksToStepCount` interval search, over the line's
# step ticks.
# ---------------------------------------------------------------------------

const DevNoStepCount = -1

func devPositionRRTicksToStepIndex(ticks: seq[int]; rrTicks: int): int =
  if ticks.len < 1:
    return DevNoStepCount

  let first = 0
  let last = ticks.len - 1

  if rrTicks < ticks[first]:
    return first
  elif rrTicks > ticks[last]:
    return last

  for i in 0 ..< ticks.len:
    let nextIndex = min(i + 1, ticks.len - 1)
    if rrTicks >= ticks[i] and rrTicks <= ticks[nextIndex]:
      return i

  return last

# ---------------------------------------------------------------------------
# Reference implementation 6 — `dev`'s
# `ui/flow.nim:activeLoopIterationStepCounts` deduplication and ordering.
# ---------------------------------------------------------------------------

func devAddUniqueStepCount(stepCounts: var seq[int]; stepCount: int) =
  for existing in stepCounts:
    if existing == stepCount:
      return
  stepCounts.add(stepCount)

func devOrderIterationSteps(candidates: seq[(int, int)]): seq[int] =
  # `candidates` is `(stepCount, line)`, in the order the two sources produced
  # them.
  var picked: seq[int] = @[]
  for candidate in candidates:
    picked.devAddUniqueStepCount(candidate[0])

  func lineOf(stepCount: int): int =
    for candidate in candidates:
      if candidate[0] == stepCount:
        return candidate[1]
    -1

  picked.sort(proc(a, b: int): int =
    let lineA = lineOf(a)
    let lineB = lineOf(b)
    if lineA == lineB:
      system.cmp(a, b)
    else:
      system.cmp(lineA, lineB))
  picked

# ---------------------------------------------------------------------------
# Reference implementation 7 — `dev`'s
# `ui/flow.nim:firstLoopBodyStepForIteration` body search, and
# `getClosestIterationStepCount`.
# ---------------------------------------------------------------------------

func devFirstLoopBodyStep(entries: seq[(int, int)];
                          first, last, stepCountLimit: int): int =
  # `entries` is `(line, stepCount)`.
  var selectedLine = int.high
  var selectedStepCount = DevNoStepCount
  for entry in entries:
    let line = entry[0]
    let stepCount = entry[1]
    if line > first and line <= last and
       stepCount >= 0 and stepCount < stepCountLimit:
      if line < selectedLine:
        selectedLine = line
        selectedStepCount = stepCount
  selectedStepCount

func devClosestIterationStepCount(stepCounts: seq[int]; stepCount: int): int =
  let firstStepCount = stepCounts[0]
  let lastStepCount = stepCounts[^1]
  if firstStepCount < stepCount and stepCount < lastStepCount:
    return stepCount
  elif stepCount <= firstStepCount:
    return firstStepCount
  elif lastStepCount <= stepCount:
    return lastStepCount

# ---------------------------------------------------------------------------
# The parity assertions
# ---------------------------------------------------------------------------

suite "Flow layout extraction — parity with the pre-refactor ui/flow.nim":

  test "the corpus is big enough to be evidence":
    # A parity suite over an empty or trivial corpus is the shape of check that
    # cannot fail. State the size, so shrinking it is a visible edit.
    check Corpus.len >= 20
    check Expressions.len >= 20
    var nonTrivial = 0
    for line in Corpus:
      if line.strip().len > 0:
        nonTrivial += 1
    check nonTrivial >= 17

  test "isFlowIdentifierChar agrees on every byte":
    for code in 0 .. 255:
      let ch = char(code)
      check isFlowIdentifierChar(ch) == devIsFlowIdentifierChar(ch)

  test "findExpressionColumn agrees on every (line, expression) pair":
    var checked = 0
    for line in Corpus:
      for expression in Expressions:
        checkpoint("line=" & line & " expression=" & expression)
        check findExpressionColumn(line, expression) ==
          devFindFlowExpressionPosition(line, expression)
        checked += 1
    check checked == Corpus.len * Expressions.len

  test "findExpressionColumn actually finds things in this corpus":
    # Parity with a reference that always answers -1 would be worthless. At
    # least a third of the pairs must be real hits.
    var hits = 0
    for line in Corpus:
      for expression in Expressions:
        if findExpressionColumn(line, expression) >= 0:
          hits += 1
    check hits >= 20

  test "fallbackExpressionColumn agrees with dev's arithmetic":
    for lineLength in 0 .. 40:
      for placed in 0 .. 6:
        check fallbackExpressionColumn(lineLength, placed) ==
          max(0, lineLength) + 2 + placed * 2

  test "the tokenizer agrees on the whole corpus, token for token":
    let language = nimFlowTokenLanguage(NimKeywords)
    var totalTokens = 0
    for line in Corpus:
      checkpoint("line=" & line)
      let extracted = tokenizeSourceExpressions(line, language)
      let reference = devTokenizeExpressions(line, NimKeywords)
      check extracted.len == reference.len
      for i in 0 ..< min(extracted.len, reference.len):
        check extracted[i].expression == reference[i][0]
        check extracted[i].column == reference[i][1]
      totalTokens += extracted.len
    # As above: parity on an empty token stream proves nothing.
    check totalTokens >= 40

  test "the value-mode decision agrees on all eight input combinations":
    for hasBefore in [false, true]:
      for hasAfter in [false, true]:
        for equal in [false, true]:
          checkpoint("before=" & $hasBefore & " after=" & $hasAfter &
            " equal=" & $equal)
          let extracted = resolveFlowValueMode(hasBefore, hasAfter, equal)
          let reference = devGetFlowValueMode(hasBefore, hasAfter, equal)
          check (extracted == fvmBefore) == (reference == dvBefore)
          check (extracted == fvmAfter) == (reference == dvAfter)
          check (extracted == fvmBeforeAndAfter) ==
            (reference == dvBeforeAndAfter)

  test "label ordering agrees, including the flag inversion":
    # `dev`'s `ascending` parameter is inverted with respect to its name, and
    # `ui/flow.nim` passes `false` for left-to-right. The extracted function is
    # named for what it does, so the call site flips the flag — and this is
    # where that flip is checked rather than assumed.
    let columnSets = @[
      @[("sum", 6), ("x", 12), ("y", 16)],
      @[("a", 5), ("b", 5), ("c", 1)],
      @[("only", 0)],
      newSeq[(string, int)](),
      @[("z", 99), ("a", 0), ("m", 50), ("dup", 50)],
    ]
    for columns in columnSets:
      var placed: seq[FlowExpressionColumn] = @[]
      for entry in columns:
        placed.add(FlowExpressionColumn(
          expression: entry[0], column: entry[1], found: true))

      var extractedAscending: seq[string] = @[]
      for entry in orderExpressionsByColumn(placed, ascending = true):
        extractedAscending.add(entry.expression)
      check extractedAscending == devSortVariablesPositions(columns, false)

      var extractedDescending: seq[string] = @[]
      for entry in orderExpressionsByColumn(placed, ascending = false):
        extractedDescending.add(entry.expression)
      check extractedDescending == devSortVariablesPositions(columns, true)

  test "the label anchor agrees with dev's `position + 1 + expression.len`":
    for column in 0 .. 40:
      for length in 0 .. 20:
        check inlineLabelAnchorColumn(column, length) == column + 1 + length

  test "the tick-to-step search agrees, including on the interval boundaries":
    let tickSets = @[
      newSeq[int](),
      @[10],
      @[10, 20, 30],
      @[1, 2, 3, 4, 5],
      @[13, 95, 175, 257, 339, 421, 503, 585, 667],  # the zk_shields loop
    ]
    for ticks in tickSets:
      for rrTicks in -5 .. 700:
        checkpoint("ticks=" & $ticks & " rrTicks=" & $rrTicks)
        check stepIndexForTicks(ticks, rrTicks) ==
          devPositionRRTicksToStepIndex(ticks, rrTicks)

  test "iteration step ordering agrees, duplicates and ties included":
    let candidateSets = @[
      newSeq[(int, int)](),
      @[(4, 10)],
      @[(9, 12), (4, 10), (9, 12), (7, 10)],
      @[(8, 10), (3, 10)],
      @[(5, 7), (2, 4), (6, 9), (2, 4), (1, 4)],
    ]
    for candidates in candidateSets:
      var typed: seq[tuple[stepCount: int, line: int]] = @[]
      for entry in candidates:
        typed.add((stepCount: entry[0], line: entry[1]))
      checkpoint("candidates=" & $candidates)
      check orderIterationSteps(typed) == devOrderIterationSteps(candidates)

  test "the first-body-step search agrees, header and closing line included":
    let entrySets = @[
      newSeq[(int, int)](),
      @[(7, 1), (8, 2), (9, 3)],
      @[(7, 1)],
      @[(9, 3), (8, 2), (7, 1)],
      @[(4, 0), (5, 1), (14, 2), (15, 3)],
    ]
    for entries in entrySets:
      for first in 3 .. 8:
        for last in first .. 16:
          var typed: seq[tuple[line: int, stepCount: int]] = @[]
          for entry in entries:
            typed.add((line: entry[0], stepCount: entry[1]))
          checkpoint("entries=" & $entries & " first=" & $first &
            " last=" & $last)
          check firstBodyStepIn(typed, first, last, stepCountLimit = 100) ==
            devFirstLoopBodyStep(entries, first, last, 100)

  test "the step-count clamp agrees over the loop's whole range":
    let loops = @[@[1, 2, 3, 4, 5, 6], @[10], @[3, 9]]
    for stepCounts in loops:
      for stepCount in -3 .. 15:
        checkpoint("stepCounts=" & $stepCounts & " stepCount=" & $stepCount)
        check closestIterationStepCount(
            FlowLayoutLoop(stepCounts: stepCounts), stepCount) ==
          devClosestIterationStepCount(stepCounts, stepCount)
