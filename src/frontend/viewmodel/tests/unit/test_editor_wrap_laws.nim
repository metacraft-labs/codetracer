## PLAT-27 — `LAW-C1` … `LAW-C6`, executable, over a declared cross product.
##
## Subjects: `viewmodel/editor/wrap.nim` (the projection, the cache, the two
## mappings, the twelve display motions) and
## `viewmodel/tests/generators/wrap_generator.nim` — the population the laws are
## quantified over, which is a subject like any other and is armed like one.
##
## =========================================================================
## WHAT THIS FILE IS FOR, IN ONE SENTENCE
## =========================================================================
##
## Editor-ViewModel.md §9 claims the two mappings are *"a bijection, and that is
## a testable claim rather than a description"*. **The round trip was planned as
## two examples.** A bijection over a population is a different kind of
## statement, and the distance between the two is where every
## tab-at-a-wrap-boundary defect lives.
##
## =========================================================================
## THE FIVE RULES THAT MAKE THIS EVIDENCE RATHER THAN A GREEN RUN
## =========================================================================
##
## 1. **THE POPULATION IS ASSERTED BEFORE ANYTHING IS QUANTIFIED OVER IT.**
##    Verification-Harness-Traps §34: three milestones running, the defect was a
##    generator that stopped producing the interesting class while every law
##    stayed green. Here the analogue is a document narrower than the wrap
##    column, and it was REAL: of §6's 72 declared cells, **35 have no wrapped
##    line at all and six documents never wrap at any declared column**. The
##    repair is a fifth, per-document witness column; the realised classes are
##    asserted as EQUALITIES, not floors; and every document is required to
##    witness the wrapped, exactly-at-boundary and multi-row classes.
##
## 2. **THE NUMBER OF POSITIONS CHECKED IS PRINTED AND ASSERTED**, in BOTH
##    directions and separately. An identity over an empty set holds, and that
##    single assertion is the whole difference between this and the two examples
##    it replaces.
##
## 3. **THE REVERSE DIRECTION IS NOT THE SAME TEST.** Display→logical→display is
##    the identity only at cluster boundaries, so the count of display positions
##    that ARE cluster boundaries is asserted too — and asserted as an EQUALITY
##    against an arithmetic derivation that never calls either mapping, so a
##    model that called every display column a boundary fails rather than
##    passes.
##
## 4. **EVERY LAW NAMES THE MUTATION THAT MUST KILL IT**, §3.3's own column,
##    carried here beside the ids and applied by
##    `run-plat27-coordinate-mutations.py`. `ci/test/editor-model-case-floor.sh
##    PLAT-27` reads §3.3 out of the sibling checkout at run time and checks the
##    ids and killers in both directions with the cardinality asserted.
##
## 5. **THE ORACLES ARE NOT THE CODE UNDER TEST.** Three of them:
##    * `columnCanonical` is derived from the cluster table, so `LAW-C1`'s
##      expected value is not `toLogical(toDisplay(...))`;
##    * PLAT-24's `manifest.tsv` carries each document's display width at both
##      `AmbiguousWidth` settings, written to disk by a different program, and
##      `LAW-C5` is asserted against it;
##    * `DIFF-2`'s other side is **`isonim-tui`'s own `allDisplayRows`**, driven
##      rather than transcribed.
##
## =========================================================================
## `LAW-C1` IS PUBLISHED AS AN IDENTITY "AT EVERY POSITION" AND IT IS NOT ONE
## =========================================================================
##
## Measured before the laws were written, not discovered by a red run: a
## zero-width cluster shares its display column with whatever follows it, and
## two logical positions at one display column cannot both come back from it, so
## on `(row, column)` the identity is false — by **33,465** positions across the
## 90-cell population.
##
## **THE TWO ZERO-WIDTH FIGURES ARE AT TWO POLICIES AND ONLY ONE OF THEM DRIVES
## THE 33,465.** `clusterDisplayWidth` calls **7,352** clusters of the corpus
## zero-width (asserted in `test_editor_wrap_examples.nim`), and that count
## includes the corpus's 659 tabs, which are zero cells to the width function —
## it is the count at `tabSize = 0`. This sweep runs at `tabSize = 4`, where a
## tab expands and absorbs nothing, so the collapsing clusters number **6,693**,
## and `6,693 x 5` wrap columns `=` **33,465** exactly. The larger figure is a
## true statement about the corpus and is NOT the cause of the smaller one.
##
## §36's repair is to the ASSERTION, never to the killer, and it is taken here:
## `LAW-C1` asserts `toLogical(toDisplay(p)) == columnCanonical(p)` at EVERY
## byte position, which is the identity at every position that has a display
## column of its own, and the count of each is printed. The published wording is
## corrected in Editor-Model-Conformance-Suite.md §3.3a with the measurement
## beside it. The alternative — widening a display coordinate so the collapsed
## positions become distinguishable — was rejected for a reason stated in
## `wrap.nim`'s header: a renderer paints cells, and a coordinate no renderer
## can place is not a display coordinate.
##
## ARMING: `run-plat27-coordinate-mutations.py`.

import std/[algorithm, options, os, sequtils, strutils, tables, unittest]

import ../../editor/change_set
import ../../editor/selection
import ../../editor/selection_ops
import ../../editor/text_store
import ../../editor/wrap
import ../generators/change_generator
import ../generators/wrap_generator

# ---------------------------------------------------------------------------
# Counted assertions
# ---------------------------------------------------------------------------

var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 2834
  ## 2774 -> 2804 -> 2834 on 2026-09-18: PLAT-29 added `document_version.nim`
  ## and `reconcile.nim` to `viewmodel/editor/` and PLAT-30 added
  ## `operations.nim` and `editor_state.nim`, and the three renderer-reach
  ## scans below run over every module in that directory — plus the
  ## two-sided §35 directory check, which asserts each name twice, and the
  ## `WrapSettings` split, which now has three projection modules and asserts
  ## the classification of every module in the directory rather than of a
  ## list that predates half of them.
  ## Asserted by the last case against the runtime tally. Update it
  ## deliberately, in the same commit as the checks that moved it.

const Seed = 0x27c0de00'u32
  ## Printed. `FUZZ-6` is the only generated stream here; everything else is a
  ## declared cross product, which is the point of the milestone.

# ---------------------------------------------------------------------------
# The laws, and their killers — §3.3's own column
# ---------------------------------------------------------------------------

type LawId = enum
  lawC1, lawC2, lawC3, lawC4, lawC5, lawC6

const LawName: array[LawId, string] = [
  "LAW-C1", "LAW-C2", "LAW-C3", "LAW-C4", "LAW-C5", "LAW-C6"]

const LawKiller: array[LawId, string] = [
  "round the display column to a cell instead of a cluster",
  "resolve a display column to the end of the cluster containing it rather " &
    "than its start, so the return leg reports the following cluster's column",
  "wrap a line's rows in the wrong order",
  "drop the last row of a wrapped line",
  "ignore the parameter",
  "skip invalidation for a region above the edit"]
  ## Transcribed from Editor-Model-Conformance-Suite.md §3.3, and the
  ## transcription is CHECKED: `ci/test/editor-model-case-floor.sh PLAT-27`
  ## parses that table out of the sibling checkout at run time and compares the
  ## ids and the non-empty killer cells against this array in both directions,
  ## with the cardinality asserted (§7.1).
  ##
  ## **`LAW-C7` IS PUBLISHED AND IS NOT HERE.** §3.3 carries seven rows and says
  ## of the seventh that it *"lands in PLAT-28, which owns widgets, and is named
  ## here because it is a coordinate claim"*. The gate knows that: it takes a
  ## DEFERRED set, requires every deferred id to be published AND absent from
  ## this array, and runs the two-way count over the remaining six. A milestone
  ## silently not implementing a published law is the thing that would otherwise
  ## be indistinguishable from this.

const LawCount = ord(high(LawId)) - ord(low(LawId)) + 1

# ---------------------------------------------------------------------------
# The per-law tally. Accumulated by the sweeps, asserted by the six law cells.
#
# Verification-Harness-Traps §29: nothing below `check`s outside a test block.
# These are plain counters; the assertions are in the cells.
# ---------------------------------------------------------------------------

var lawChecks: array[LawId, int]
var lawFailures: array[LawId, seq[string]]

proc note(law: LawId; ok: bool; what: string) =
  inc lawChecks[law]
  if not ok and lawFailures[law].len < 4: lawFailures[law].add what

# ---------------------------------------------------------------------------
# Helpers that are NOT the implementation
# ---------------------------------------------------------------------------

type CellOutcome = object
  ## What one `(document, wrap column)` cell realised. Every number here is
  ## reported and the ones that decide whether the laws said anything are
  ## asserted.
  forwardPositions: int       ## every byte position of every line
  forwardIdentity: int        ## of those, the ones the round trip fixes exactly
  forwardInsideCluster: int   ## of those, the bytes that are not a boundary
  forwardCollapsed: int       ## of those, the boundaries a zero-width cluster absorbs
  reversePositions: int       ## canonical display positions
  reverseBoundaries: int      ## of those, the ones that are cluster boundaries
  reverseInterior: int        ## of those, interior cells of wide clusters
  canonicalLogical: int       ## the other half of the bijection's cardinality
  interiorDerived: int        ## the same interior count, derived arithmetically
  orderChecks: int
  rows: int

proc canonicalTable(m: LineMetrics): seq[int] =
  ## For every cluster index, the byte offset of the first cluster at or after
  ## it that has a column of its own. Precomputed because `LAW-C1` visits every
  ## BYTE and a per-byte walk would make the law a benchmark.
  ##
  ## **This is the law's own derivation and it is deliberately not
  ## `wrap.columnCanonical`** — that routine is a subject and an arm on it would
  ## otherwise disarm the law that uses it (§32a, a second mechanism). Two
  ## derivations; the suite asserts they agree, once, in a case of its own.
  result = newSeq[int](m.clusters.len + 1)
  result[^1] = m.byteLen
  for i in countdown(m.clusters.len - 1, 0):
    result[i] = if m.clusters[i].cells > 0: m.clusters[i].startByte
                else: result[i + 1]

proc sweepCell(c: WrapCache; docId: string; column: int): CellOutcome =
  ## One cell of the population, both directions.
  var o = CellOutcome()

  # -- FORWARD: LAW-C1, at EVERY byte position of every line -----------------
  for line in 0 ..< c.lineCount:
    let m = c.metricsOf(line)
    let canon = canonicalTable(m)
    var ci = 0
    for b in 0 .. m.byteLen:
      while ci < m.clusters.len and m.clusters[ci].stopByte <= b: inc ci
      let expected = canon[ci]
      let d = c.toDisplay(textPos(line, b))
      let back = c.toLogical(d)
      inc o.forwardPositions
      let ok = back.line == line and back.column == expected
      # THE THREE POPULATIONS OF THE FORWARD SWEEP, SEPARATED AND COUNTED.
      # They answer three different questions and lumping them would hide the
      # one that is a fact about the model rather than about UTF-8.
      let isBoundary = ci < m.clusters.len and m.clusters[ci].startByte == b or
                       b == m.byteLen
      if b == expected: inc o.forwardIdentity
      elif not isBoundary: inc o.forwardInsideCluster
      else: inc o.forwardCollapsed
      note(lawC1, ok,
           docId & " w=" & $column & " line " & $line & " byte " & $b &
           ": " & $d & " -> " & $back.column & ", expected " & $expected)

  # -- LAW-C3: logical order and display order agree ------------------------
  for line in 0 ..< c.lineCount:
    let m = c.metricsOf(line)
    var prev = DisplayPos(row: -1, column: -1)
    for cl in m.clusters:
      let d = c.toDisplay(textPos(line, cl.startByte))
      let ok = prev.row < 0 or d.row > prev.row or
               (d.row == prev.row and d.column >= prev.column)
      inc o.orderChecks
      note(lawC3, ok,
           docId & " w=" & $column & " line " & $line & ": " & $prev &
           " then " & $d)
      prev = d
    # And across the line boundary: the line's last row precedes the next
    # line's first.
    if line + 1 < c.lineCount:
      let here = c.toDisplay(textPos(line, m.byteLen))
      let next = c.toDisplay(textPos(line + 1, 0))
      inc o.orderChecks
      note(lawC3, next.row > here.row,
           docId & " w=" & $column & ": line " & $line & " ends at " & $here &
           " and line " & $(line + 1) & " starts at " & $next)

  # -- REVERSE: LAW-C2, at every canonical display position ------------------
  o.rows = c.rowCount
  for line in 0 ..< c.lineCount:
    let m = c.metricsOf(line)
    let base = c.firstRowOf(line)
    let n = c.rowsInLine(line)
    for k in 0 ..< n:
      let r = c.rowAt(base + k)
      let last = k == n - 1
      let hi = if last: r.width else: r.width - 1
      for col in 0 .. hi:
        let d = DisplayPos(row: base + k, column: col)
        inc o.reversePositions
        let p = c.toLogical(d)
        let isBoundary = columnOfByte(m, p.column) == r.startColumn + col
        if isBoundary:
          inc o.reverseBoundaries
          let round = c.toDisplay(p)
          note(lawC2, round == d,
               docId & " w=" & $column & " " & $d & " -> byte " & $p.column &
               " -> " & $round)
        else:
          inc o.reverseInterior
    # The two cardinalities of the bijection, derived arithmetically and
    # WITHOUT calling either mapping.
    var positive = 0
    var interior = 0
    for cl in m.clusters:
      if cl.cells > 0:
        inc positive
        interior += cl.cells - 1
    o.canonicalLogical += positive + 1
    o.interiorDerived += interior

  o

proc partitionText(c: WrapCache; doc: string): string =
  ## Every display row's text, in order, with the wrap points removed and the
  ## logical line terminators put back. `LAW-C4` compares this with the
  ## document.
  var out0 = ""
  var line = -1
  for i in 0 ..< c.rowCount:
    let r = c.rowAt(i)
    if r.line != line:
      if line >= 0: out0.add "\n"
      line = r.line
    out0.add c.rowText(doc, i)
  out0

proc rowsOf(c: WrapCache): seq[wrap.DisplayRow] =
  result = @[]
  for i in 0 ..< c.rowCount: result.add c.rowAt(i)

proc raisesWrap(body: proc ()): bool =
  ## Whether `body` refuses by name. Written as a helper so every refusal is a
  ## COUNTED assertion rather than an `expect` block, which contributes nothing
  ## to the tally and is invisible when it is deleted.
  try:
    body()
    false
  except WrapError:
    true

proc describeRows(a, b: seq[wrap.DisplayRow]): string =
  if a.len != b.len:
    return "row counts " & $a.len & " vs " & $b.len
  for i in 0 ..< a.len:
    if a[i] != b[i]: return "row " & $i & ": " & $a[i] & " vs " & $b[i]
  "identical"

# ---------------------------------------------------------------------------
# The population, materialised once. Every sweep below indexes into it.
# ---------------------------------------------------------------------------

let population = block:
  var xs: seq[WrapCell] = @[]
  for cell in cells(): xs.add cell
  xs

let manifest = manifestRows()

proc manifestOf(id: string): ManifestRow =
  for r in manifest:
    if r.id == id: return r
  raise newException(KeyError, "no manifest row for " & id)

# ===========================================================================
# THE POPULATION IS EVIDENCE — §34, and it fired here
# ===========================================================================

suite "PLAT-27 — the population, before anything is quantified over it":

  test "the declared cross product, its realised classes, and the six documents it left unwrapped":
    echo "SEED: 0x" & toHex(Seed.BiggestInt, 8) &
         "  documents: " & $CorpusDocCount &
         "  declared matrix: " & $WrapMatrix &
         "  cells: " & $population.len
    var hist = initCountTable[WrapClass]()
    var perDoc = initTable[string, set[WrapClass]]()
    var declaredNoWrap = 0
    var declaredCells = 0
    var witnessCells = 0
    var perDocDeclared = initTable[string, set[WrapClass]]()
    for cell in population:
      let c = cell.cellCache()
      let cls = classifyCell(c, cell.column)
      for k in cls: hist.inc k
      perDoc[cell.docId] = perDoc.getOrDefault(cell.docId) + cls
      if cell.isWitness:
        inc witnessCells
      else:
        inc declaredCells
        perDocDeclared[cell.docId] = perDocDeclared.getOrDefault(cell.docId) + cls
        if wcNoWrap in cls: inc declaredNoWrap
    for k in WrapClass:
      echo "  HISTOGRAM " & alignLeft($k, 18) & $hist.getOrDefault(k)
    echo "  DECLARED-MATRIX CELLS WITH NO WRAPPED LINE: " & $declaredNoWrap &
         " of " & $declaredCells
    counted population.len == CorpusDocCount * (WrapMatrixCount + 1)
    counted declaredCells == CorpusDocCount * WrapMatrixCount
    counted witnessCells == CorpusDocCount
    counted WrapClassCount == 4
    # EVERY CLASS NON-EMPTY (§4b), and then the stronger claim: the realised
    # counts as EQUALITIES (§34's second rule). These are not floors. A change
    # to the corpus, to the matrix or to the wrap algorithm moves them, and a
    # reader is then obliged to look at WHICH.
    for k in WrapClass:
      checkpoint("class " & $k & " realised " & $hist.getOrDefault(k))
      counted hist.getOrDefault(k) > 0
    counted hist.getOrDefault(wcNoWrap) == 35
    counted hist.getOrDefault(wcWrapped) == 55
    counted hist.getOrDefault(wcExactBoundary) == 56
    counted hist.getOrDefault(wcMultiRow) == 38
    # THE MEASUREMENT THAT ADDED THE FIFTH COLUMN, kept as an assertion rather
    # than as a sentence: on the DECLARED matrix alone, six documents never
    # wrap, and every coordinate law is trivially true for them.
    counted declaredNoWrap == 35
    var neverWrapDeclared: seq[string] = @[]
    for id, s in perDocDeclared:
      if wcWrapped notin s: neverWrapDeclared.add id
    sort(neverWrapDeclared)
    echo "  DOCUMENTS THAT NEVER WRAP ON THE DECLARED MATRIX: " &
         neverWrapDeclared.join(", ")
    counted neverWrapDeclared.len == 6
    counted neverWrapDeclared == @["c1-zwj-short", "c2-combining-short",
                                   "c3-regional-short", "c4-ambiguous-short",
                                   "c5-cjk-short", "c6-terminators-short"]

  test "every corpus document witnesses the wrapped, boundary and multi-row classes":
    # §4.1's *"a window cut out of a corpus document is not automatically of
    # that document's class"*, one level up: a DOCUMENT crossed with a wrap
    # column is not automatically of the wrap class the cross product implies.
    var perDoc = initTable[string, set[WrapClass]]()
    for cell in population:
      let c = cell.cellCache()
      perDoc[cell.docId] = perDoc.getOrDefault(cell.docId) +
                           classifyCell(c, cell.column)
    counted perDoc.len == CorpusDocCount
    var witnessed = 0
    for id, s in perDoc:
      checkpoint(id & " realises " & $s)
      counted {wcWrapped, wcExactBoundary, wcMultiRow} <= s
      inc witnessed
    counted witnessed == CorpusDocCount

  test "the witness column is DERIVED from the document and is not one of the declared four":
    # §10.4's third rule: a multiplier must be an asserted cardinality rather
    # than a round number, and a constant that silently stopped wrapping would
    # be the same defect in the other direction.
    counted WitnessDivisor == 3
    var checkedDocs = 0
    for i in 0 ..< CorpusDocCount:
      let base = initWrapCache(CorpusDocs[i].text,
                               wrapSettings(WrapMatrix[0], 4, awNarrow))
      let cols = columnsFor(base)
      counted cols.len == WrapMatrixCount + 1
      counted cols[^1] notin WrapMatrix
      counted cols[^1] >= 2
      counted cols[^1] < base.widestLine
      inc checkedDocs
    counted checkedDocs == CorpusDocCount

# ===========================================================================
# THE BIJECTION — `LAW-C1` … `LAW-C4`, over the 90-cell population
# ===========================================================================

var totalForward = 0
var totalForwardIdentity = 0
var totalForwardInsideCluster = 0
var totalForwardCollapsed = 0
var totalReverse = 0
var totalReverseBoundaries = 0
var totalCanonicalLogical = 0
var totalRows = 0
var cellsSwept = 0

suite "PLAT-27 — the bijection, over the declared cross product":

  for cellIdx in 0 ..< population.len:
    let cell = population[cellIdx]
    test "bijection: " & cell.docId & " x w=" & $cell.column:
      let c = cell.cellCache()
      let o = sweepCell(c, cell.docId, cell.column)
      inc cellsSwept
      totalForward += o.forwardPositions
      totalForwardIdentity += o.forwardIdentity
      totalForwardInsideCluster += o.forwardInsideCluster
      totalForwardCollapsed += o.forwardCollapsed
      totalReverse += o.reversePositions
      totalReverseBoundaries += o.reverseBoundaries
      totalCanonicalLogical += o.canonicalLogical
      totalRows += o.rows
      # NON-VACUITY FIRST, per cell (§4): a cell that checked nothing satisfies
      # every law written over it.
      counted o.forwardPositions > 0
      counted o.reversePositions > 0
      counted o.orderChecks > 0
      # **THE BIJECTION, AS A BIJECTION.** The two sets' cardinalities, one
      # counted by walking the display space and one derived from the cluster
      # table without calling either mapping.
      counted o.reverseBoundaries == o.canonicalLogical
      # And the rest of the display space is accounted for exactly, so "every
      # column is a boundary" is excluded by arithmetic rather than by hope.
      counted o.reverseBoundaries + o.reverseInterior == o.reversePositions
      counted o.reverseInterior == o.interiorDerived
      # `LAW-C4`: the rows PARTITION the document.
      let doc = CorpusDocs[cell.docIndex].text
      let rebuilt = partitionText(c, doc)
      note(lawC4, rebuilt == doc,
           cell.docId & " w=" & $cell.column & ": partition differs at byte " &
           $(block:
               var i = 0
               while i < min(rebuilt.len, doc.len) and rebuilt[i] == doc[i]: inc i
               i))
      counted rebuilt.len == doc.len
      counted rebuilt == doc
      # A document of N lines has at least N rows, and exactly N when nothing
      # wrapped — the partition holding at its degenerate end.
      counted c.rowCount >= c.lineCount

  test "LAW-C1":
    # logical→display→logical, at EVERY byte position of every line of every
    # cell. The identity where the position has a display column of its own,
    # and `columnCanonical` where a zero-width cluster absorbed it — see the
    # header, and §3.3a.
    echo "  LAW-C1 POSITIONS: " & $lawChecks[lawC1] &
         "  identity: " & $totalForwardIdentity &
         "  inside a cluster: " & $totalForwardInsideCluster &
         "  boundaries absorbed by a zero-width cluster: " &
         $totalForwardCollapsed
    for f in lawFailures[lawC1]: checkpoint(f)
    counted lawFailures[lawC1].len == 0
    counted cellsSwept == population.len
    counted lawChecks[lawC1] == totalForward
    # **THE COUNT IS ASSERTED NON-TRIVIAL, AND AS AN EQUALITY.** An identity
    # over an empty set holds; an identity over a tenth of the corpus holds
    # just as loudly.
    counted totalForward == 1_726_670
    counted totalForwardIdentity == 794_565
    counted totalForwardInsideCluster == 898_640
    # **THE 33,465 THAT MAKE THE PUBLISHED WORDING FALSE.** These are cluster
    # BOUNDARIES — genuine logical positions — that share a display column with
    # a following cluster and therefore cannot come back from it. See §3.3a.
    counted totalForwardCollapsed == 33_465
    counted totalForwardIdentity + totalForwardInsideCluster +
            totalForwardCollapsed == totalForward
    # The identity set is exactly the bijection's logical half.
    counted totalForwardIdentity == totalReverseBoundaries

  test "LAW-C2":
    # display→logical→display, at every canonical display position that is a
    # cluster boundary — and the count of those is itself asserted, because a
    # model reporting every display column as a boundary would pass the round
    # trip and be wrong about the thing it exists to check.
    echo "  LAW-C2 DISPLAY POSITIONS: " & $totalReverse &
         "  of which cluster boundaries: " & $totalReverseBoundaries &
         "  round trips checked: " & $lawChecks[lawC2]
    for f in lawFailures[lawC2]: checkpoint(f)
    counted lawFailures[lawC2].len == 0
    counted lawChecks[lawC2] == totalReverseBoundaries
    counted totalReverse == 941_510
    counted totalReverseBoundaries == 794_565
    counted totalReverseBoundaries < totalReverse
    counted totalCanonicalLogical == totalReverseBoundaries
    # The reverse direction is a SMALLER set than the forward one, and by how
    # much is a fact about the corpus rather than about the model: bytes are
    # not cells.
    counted totalReverse < totalForward

  test "LAW-C3":
    echo "  LAW-C3 ORDER COMPARISONS: " & $lawChecks[lawC3]
    for f in lawFailures[lawC3]: checkpoint(f)
    counted lawFailures[lawC3].len == 0
    counted lawChecks[lawC3] == 827_940
    counted totalRows > 0

  test "LAW-C4":
    echo "  LAW-C4 PARTITIONS: " & $lawChecks[lawC4] & "  rows: " & $totalRows
    for f in lawFailures[lawC4]: checkpoint(f)
    counted lawFailures[lawC4].len == 0
    counted lawChecks[lawC4] == population.len
    counted totalRows == 32_128

# ===========================================================================
# `LAW-C5` — THE WIDTH POLICY IS TWO-SIDED
# ===========================================================================

suite "PLAT-27 — LAW-C5, the width policy, two-sided":

  for docIdx in 0 ..< CorpusDocCount:
    for policy in [awNarrow, awWide]:
      let id = CorpusDocs[docIdx].id
      test "LAW-C5 x " & id & " / " & $policy:
        let text = CorpusDocs[docIdx].text
        # `TabsAsClusters` because the manifest's widths are a sum of
        # `clusterDisplayWidth` over clusters with no tab expansion — the
        # oracle and the measurement have to mean the same thing by "width".
        let c = initWrapCache(text, wrapSettings(0, TabsAsClusters, policy))
        var total = 0
        for line in 0 ..< c.lineCount: total += c.metricsOf(line).width
        let row = manifestOf(id)
        let expected = if policy == awNarrow: row.widthNarrow else: row.widthWide
        # **THE ORACLE IS A FILE WRITTEN BY ANOTHER PROGRAM**, not a second call
        # to this one.
        note(lawC5, total == expected,
             id & " / " & $policy & ": " & $total & " vs manifest " & $expected)
        counted total == expected
        # THE TWO-SIDED HALF. Class 4 must CHANGE under the other policy and
        # class 9 must NOT — and the manifest decides which, so the claim is
        # not this suite grading its own homework.
        let other = if policy == awNarrow: awWide else: awNarrow
        let c2 = initWrapCache(text, wrapSettings(0, TabsAsClusters, other))
        var total2 = 0
        for line in 0 ..< c2.lineCount: total2 += c2.metricsOf(line).width
        let manifestSaysDiffer = row.widthNarrow != row.widthWide
        note(lawC5, (total != total2) == manifestSaysDiffer,
             id & ": widths " & $total & "/" & $total2 &
             " but the manifest says differ=" & $manifestSaysDiffer)
        counted (total != total2) == manifestSaysDiffer
        if corpusClassOf(id) == 4:
          counted total != total2
        if corpusClassOf(id) == 9:
          counted total == total2
        # And at a real wrap column the ROWS follow the widths: switching the
        # policy must move a row boundary for a document whose width moved,
        # and must move nothing for one whose width did not.
        let w = max(2, c.widestLine div WitnessDivisor)
        let ra = rowsOf(initWrapCache(text, wrapSettings(w, TabsAsClusters, policy)))
        let rb = rowsOf(initWrapCache(text, wrapSettings(w, TabsAsClusters, other)))
        counted (ra != rb) == manifestSaysDiffer

  test "LAW-C5":
    echo "  LAW-C5 CHECKS: " & $lawChecks[lawC5]
    for f in lawFailures[lawC5]: checkpoint(f)
    counted lawFailures[lawC5].len == 0
    counted lawChecks[lawC5] == 2 * 2 * CorpusDocCount
    # THE NEGATIVE HALF IS NOT PADDING (§7b). The population of documents whose
    # width DOES move, and of those whose width does not, are both asserted
    # non-empty — an arm with only one of them is a self-comparison wearing a
    # negation.
    var moved = 0
    var invariant = 0
    for r in manifest:
      if r.widthNarrow != r.widthWide: inc moved else: inc invariant
    echo "  DOCUMENTS WHOSE WIDTH MOVES UNDER THE POLICY: " & $moved &
         ", INVARIANT: " & $invariant
    counted moved == 5
    counted invariant == 13
    counted moved + invariant == CorpusDocCount

# ===========================================================================
# `LAW-C6` — THE WRAP CACHE IS COHERENT
# ===========================================================================

proc applyEdits(doc: string; cs: ChangeSet): string = cs.apply(doc)

suite "PLAT-27 — LAW-C6, the wrap cache":

  for docIdx in 0 ..< CorpusDocCount:
    let id = CorpusDocs[docIdx].id
    test "LAW-C6 x " & id:
      # The window rather than the whole document: `LAW-C6` is about the
      # SPLICE, and a stream of edits over 67 KB at every step is a benchmark
      # rather than a law. The window is PLAT-25's — real corpus text with real
      # cluster structure, and it witnesses its class.
      var r = initRng(Seed xor uint32(docIdx * 7919))
      let docs = genDocs(Seed)
      var doc = docs[docIdx].text
      let settings = wrapSettings(8, 4, awNarrow)
      var c = initWrapCache(doc, settings)
      var applied = 0
      for step in 0 ..< 12:
        let cs = genSimple(doc, r, 2)
        if cs.isIdentity: continue
        let newDoc = applyEdits(doc, cs)
        let updated = c.updateWrapCache(doc, cs, newDoc)
        let fresh = initWrapCache(newDoc, settings)
        let a = rowsOf(updated)
        let b = rowsOf(fresh)
        note(lawC6, a == b,
             id & " step " & $step & ": " & describeRows(a, b))
        counted a == b
        inc applied
        doc = newDoc
        c = updated
      # **THE STREAM REALLY EDITED SOMETHING.** A cache that was never asked to
      # move is a cache whose invalidation was never exercised — §4, in the
      # shape this law is most vulnerable to.
      counted applied >= 6
      counted c.rowCount > 0
      counted rowsOf(c) == rowsOf(initWrapCache(doc, settings))

  test "LAW-C6":
    echo "  LAW-C6 SPLICES: " & $lawChecks[lawC6]
    for f in lawFailures[lawC6]: checkpoint(f)
    counted lawFailures[lawC6].len == 0
    counted lawChecks[lawC6] >= 6 * CorpusDocCount

# ===========================================================================
# `DIFF-2` — THE MODEL AND A REAL TERMINAL RENDER
# ===========================================================================

proc modelRowSpans(c: WrapCache): seq[(int, int, int)] =
  ## The model's rows in the terminal's unit — clusters, not bytes — so the two
  ## producers are compared on the same question.
  result = @[]
  for i in 0 ..< c.rowCount:
    let r = c.rowAt(i)
    let m = c.metricsOf(r.line)
    result.add (r.line, clusterIndexOfByte(m, r.startByte),
                clusterIndexOfByte(m, r.endByte))

suite "PLAT-27 — DIFF-2, the model against isonim-tui":

  for docIdx in 0 ..< CorpusDocCount:
    let id = CorpusDocs[docIdx].id
    let text = CorpusDocs[docIdx].text
    let witness = block:
      let base = initWrapCache(text, wrapSettings(20, TabsAsClusters, awNarrow))
      max(2, base.widestLine div WitnessDivisor)
    for w in [20, witness]:
      test "DIFF-2 x " & id & " x w=" & $w:
        # The widget reads the THREADVAR policy; the model never does. Setting
        # it here is what makes the two comparable, and the asymmetry is the
        # milestone's own deliverable 1.
        setAmbiguousWidth(awNarrow)
        let c = initWrapCache(text, wrapSettings(w, TabsAsClusters, awNarrow))
        let mine = modelRowSpans(c)
        let theirs = terminalRowSpans(text, w)
        counted mine.len > 0
        counted theirs.len > 0
        if mine.len != theirs.len:
          checkpoint(id & " w=" & $w & ": " & $mine.len & " model rows vs " &
                     $theirs.len & " terminal rows")
        counted mine.len == theirs.len
        var firstDiff = -1
        for i in 0 ..< min(mine.len, theirs.len):
          if mine[i] != theirs[i]:
            firstDiff = i
            break
        if firstDiff >= 0:
          checkpoint(id & " w=" & $w & " row " & $firstDiff & ": model " &
                     $mine[firstDiff] & " vs terminal " & $theirs[firstDiff])
        counted firstDiff == -1
        # **THE CONTENT OF EACH ROW, NOT ONLY ITS SPAN.** The spans above
        # DETERMINE the content given one document, so this is a consequence
        # rather than an independent fact — and the verification gate asks for
        # the content to be *asserted*, which a consequence is not. The two
        # sides are built by two derivations: the model slices by BYTE through
        # its own line index, the terminal side re-segments the line and slices
        # by CLUSTER index, which is the unit the widget answers in.
        var lineTexts: seq[string] = @[]
        for line in text.split('\n'): lineTexts.add line
        var contentDiff = -1
        for i in 0 ..< min(mine.len, theirs.len):
          let (ln, a, b) = theirs[i]
          var bs = @[0]
          for cl in graphemeClusters(lineTexts[ln]):
            if cl.stop > bs[^1]: bs.add cl.stop
          if bs[^1] != lineTexts[ln].len: bs.add lineTexts[ln].len
          let theirText = lineTexts[ln][bs[min(a, bs.high)] ..<
                                        bs[min(b, bs.high)]]
          if c.rowText(text, i) != theirText:
            contentDiff = i
            break
        if contentDiff >= 0:
          checkpoint(id & " w=" & $w & " row " & $contentDiff &
                     " CONTENT: model " & c.rowText(text, contentDiff).escape())
        counted contentDiff == -1

  test "DIFF-2 runs at tabSize 0 because the two producers DISAGREE about tabs — the negative half":
    # §7b. A differential that passed because both sides ignored the thing it
    # was comparing would be a self-comparison wearing a negation. At
    # `tabSize = 4` the model expands tabs and the terminal does not, so the two
    # must DISAGREE on exactly the tab-bearing documents and agree on the rest.
    setAmbiguousWidth(awNarrow)
    var disagreed: seq[string] = @[]
    var agreed = 0
    for docIdx in 0 ..< CorpusDocCount:
      let text = CorpusDocs[docIdx].text
      let c = initWrapCache(text, wrapSettings(20, 4, awNarrow))
      if modelRowSpans(c) != terminalRowSpans(text, 20):
        disagreed.add CorpusDocs[docIdx].id
      else:
        inc agreed
    sort(disagreed)
    echo "  AT tabSize=4 THE MODEL AND THE TERMINAL DISAGREE ON: " &
         disagreed.join(", ")
    counted disagreed.len > 0
    counted agreed > 0
    counted disagreed.len + agreed == CorpusDocCount
    # The documents that carry a tab, measured independently of the comparison.
    var withTabs: seq[string] = @[]
    for d in CorpusDocs:
      if '\t' in d.text: withTabs.add d.id
    sort(withTabs)
    counted withTabs == @["c6-terminators-short", "c8-tabs-long",
                          "c8-tabs-short", "c9-ascii-control-short"]
    for id in disagreed:
      checkpoint("disagreed: " & id)
      counted id in withTabs

# ===========================================================================
# DISPLAY-LINE MOTIONS — §9's reason the model owns wrapping
# ===========================================================================

const MotionColumns = [8, 20, 40]
  ## Three wrap columns, and `8` is there so a corpus SHORT document wraps: the
  ## same §34 defect that added the population's fifth column would otherwise
  ## make `gj` a no-op on half the documents the motions run over.

proc motionDoc(): string =
  ## One document with wrapped lines, real clusters and at least one tab. Built
  ## from the corpus rather than from ASCII: a motion suite over `"abc"` cannot
  ## produce the landing-inside-a-cluster defect it exists to catch.
  docById("c8-tabs-short") & "\n" & docById("c5-cjk-short")

suite "PLAT-27 — display-line motions":

  for op in displayOps():
    for w in MotionColumns:
      test "display motion: " & $op & " x w=" & $w:
        let doc = motionDoc()
        let ctx = initDisplayCtx(doc, wrapSettings(w, 4, awNarrow))
        counted ctx.cache.rowCount > ctx.cache.lineCount
        var landings = 0
        var moved = 0
        var boundaryOk = 0
        for row in 0 ..< ctx.cache.rowCount:
          let rr = ctx.cache.rowAt(row)
          for col in [0, rr.width div 2, rr.width]:
            if col > rr.width: continue
            let start = ctx.cache.toLogical(DisplayPos(row: row, column: col))
            let off = ctx.store.offsetOf(start)
            let r = caret(off)
            let outR = ctx.applyDisplayOp(op, r)
            inc landings
            # EVERY LANDING IS INSIDE THE DOCUMENT AND ON A CLUSTER BOUNDARY.
            # A motion that lands mid-cluster is the half-deleted-emoji defect
            # the corpus exists to catch, in its navigation form.
            if outR.head >= 0 and outR.head <= doc.len and
               outR.head in ctx.boundaries: inc boundaryOk
            if outR.head != off: inc moved
        counted landings > 0
        counted boundaryOk == landings
        # THE OPERATION'S OWN PROPERTY, so the sweep is not twelve copies of
        # one claim.
        case op.motion
        of dispRowStart, dispRowEnd:
          # A screen-line motion stays on ITS display row.
          var sameRow = 0
          for row in 0 ..< ctx.cache.rowCount:
            let start = ctx.cache.toLogical(DisplayPos(row: row, column: 0))
            let r = caret(ctx.store.offsetOf(start))
            let landed = ctx.applyDisplayOp(op, r)
            let d = ctx.cache.toDisplay(ctx.store.posOf(landed.head))
            if d.row == row: inc sameRow
          counted sameRow == ctx.cache.rowCount
          # And it CLEARS the goal column, which is the reference's rule and
          # the only one under which a goal is a statement about VERTICAL
          # motion rather than about motion in general.
          let probe = ctx.applyDisplayOp(
            op, caret(0, assocBefore, none(BidiLevel), some(7)))
          counted probe.goalColumn.isNone
        of dispRowUp, dispRowDown:
          # A display-row motion moves by exactly ONE display row, except at
          # the document's first and last row where clamping is the specified
          # behaviour.
          var stepped = 0
          var clamped = 0
          for row in 0 ..< ctx.cache.rowCount:
            let start = ctx.cache.toLogical(DisplayPos(row: row, column: 0))
            let r = caret(ctx.store.offsetOf(start))
            let landed = ctx.applyDisplayOp(op, r)
            let d = ctx.cache.toDisplay(ctx.store.posOf(landed.head))
            let want = if op.motion == dispRowUp: row - 1 else: row + 1
            if want < 0 or want >= ctx.cache.rowCount:
              if d.row == row: inc clamped
            elif d.row == want:
              inc stepped
          counted stepped == ctx.cache.rowCount - 1
          counted clamped == 1
          # AND IT PRESERVES THE GOAL COLUMN.
          let probe = ctx.applyDisplayOp(
            op, caret(0, assocBefore, none(BidiLevel), some(3)))
          counted probe.goalColumn == some(3)
        # THE FORM'S OWN PROPERTY.
        let anchored = spanRange(ctx.boundaries[1], ctx.boundaries[3])
        let res = ctx.applyDisplayOp(op, anchored)
        case op.form
        of formMove:
          counted res.isEmpty
        of formExtend:
          counted res.anchor == anchored.anchor
        of formSpan:
          counted res.rangeFrom == min(anchored.head, res.head)

  test "THE DISPLAY VOCABULARY'S CARDINALITY, asserted, and the sweep taken against it":
    counted DisplayMotionCount == 4
    counted DisplayFormCount == 3
    counted DisplayOpCount == 12
    counted displayOps().len == DisplayOpCount
    var seen: seq[string] = @[]
    for op in displayOps(): seen.add $op
    counted seen.len == 12
    counted deduplicate(seen).len == 12
    counted MotionColumns.len == 3

  test "at wrapColumn 0 a display motion IS its PLAT-26 logical counterpart":
    # **THE GOAL COLUMN'S UNIT, ASSERTED RATHER THAN DESCRIBED.** `wrap.nim`'s
    # header says the goal is *"the tab-expanded column within the row the
    # motion steps between"*, and that a logical row IS a logical line when
    # nothing wraps. This is that sentence, executable: with soft wrap off,
    # `gj` and `opMoveLineDown` must land in the same place for every caret in
    # the document.
    let doc = motionDoc()
    let ctx = initDisplayCtx(doc, wrapSettings(0, 4, awNarrow))
    let lctx = initOpCtx(doc, ColumnPolicy(tabSize: 4, ambiguous: awNarrow))
    counted ctx.cache.rowCount == ctx.cache.lineCount
    var agreed = 0
    var compared = 0
    for b in ctx.boundaries:
      for pair in [(dispRowDown, opMoveLineDown), (dispRowUp, opMoveLineUp)]:
        let r = caret(b)
        let mine = ctx.applyDisplayOp(
          DisplayOp(motion: pair[0], form: formMove), r)
        let theirs = applyRangeOp(lctx, pair[1], r)
        inc compared
        if mine.head == theirs.range.head: inc agreed
        else:
          if agreed + 4 > compared:
            checkpoint("at " & $b & " " & $pair[0] & " landed " & $mine.head &
                       " and " & $pair[1] & " landed " & $theirs.range.head)
    counted compared > 200
    counted agreed == compared

  test "THE GOAL COLUMN IS A COLUMN AND NOT A CLUSTER INDEX, over a wrapped ladder":
    # `LAW-S5`'s claim, re-asked in display space. A ladder of alternating wide
    # and narrow rows: stepping down through a narrow row and back up must
    # return to the column the caret started at. A goal recomputed from the
    # landed column collapses on the first narrow row and never comes back; a
    # goal counting CLUSTERS lands in the middle of a CJK ideograph.
    let wide = docById("c5-cjk-short").splitLines()[0]
    let narrow = "ab"
    var doc = ""
    for i in 0 ..< 6:
      doc.add (if i mod 2 == 0: wide else: narrow)
      doc.add "\n"
    let ctx = initDisplayCtx(doc, wrapSettings(0, 4, awNarrow))
    let startOff = ctx.store.offsetOf(textPos(0, offsetAtColumn(
      wide, 8, ColumnPolicy(tabSize: 4, ambiguous: awNarrow))))
    var r = caret(startOff, assocBefore, none(BidiLevel), none(int))
    let startCol = ctx.cache.toDisplay(ctx.store.posOf(r.head)).column
    counted startCol >= 4
    for i in 0 ..< 4:
      r = ctx.applyDisplayOp(DisplayOp(motion: dispRowDown, form: formMove), r)
    # THE GOAL DID NOT COLLAPSE ONTO THE NARROW ROW. A goal recomputed from the
    # landed column would read 2 here, which is `narrow`'s whole width.
    counted r.goalColumn == some(startCol)
    counted startCol > 2
    for i in 0 ..< 4:
      r = ctx.applyDisplayOp(DisplayOp(motion: dispRowUp, form: formMove), r)
    counted ctx.cache.toDisplay(ctx.store.posOf(r.head)).column == startCol
    counted r.head == startOff
    counted r.head in ctx.boundaries

  test "a display motion is a function of ONE range, so multi-cursor needs no special case":
    let doc = motionDoc()
    let ctx = initDisplayCtx(doc, wrapSettings(20, 4, awNarrow))
    for k in [1, 2, 3, 7]:
      var rs: seq[SelectionRange] = @[]
      var i = 1
      while rs.len < k and i < ctx.boundaries.len:
        rs.add caret(ctx.boundaries[i])
        i += max(1, ctx.boundaries.len div (k + 2))
      let sel = editorSelection(rs, 0)
      for op in displayOps():
        let moved = ctx.runDisplayOp(op, sel)
        counted moved.rangeCount <= sel.rangeCount
        counted moved.invariantViolation.len == 0

# ===========================================================================
# THE TAB MATRIX — class 8, at three tab sizes and four wrap columns
# ===========================================================================

suite "PLAT-27 — tabs at wrap boundaries":

  for id in ["c8-tabs-short", "c8-tabs-long"]:
    for tab in TabSizes:
      for w in WrapMatrix:
        test "tab matrix: " & id & " x tab=" & $tab & " x w=" & $w:
          let text = docById(id)
          let c = initWrapCache(text, wrapSettings(w, tab, awNarrow))
          let policy = ColumnPolicy(tabSize: tab, ambiguous: awNarrow)
          # **THE COLUMN ORACLE.** PLAT-26's `columnAt` expands tabs by a
          # DIFFERENT derivation — a prefix walk of the line — and this module
          # expands them into a per-cluster table. The two must agree at every
          # cluster boundary of every line, and neither was written from the
          # other.
          #
          # The sweep is AGGREGATED into three counts and the counts are what
          # is asserted. §10.1: the assertion tally exists to stop a case being
          # hollow, and twenty-four cells x 24,738 clusters would make it a
          # measure of the corpus's size instead. The failure is reported with
          # the first divergence, so a red run still names a position.
          var compared = 0
          var agreed = 0
          var widthsAgreed = 0
          var firstBad = ""
          var lineStart = 0
          for line in 0 ..< c.lineCount:
            let m = c.metricsOf(line)
            let lineText = text[lineStart ..< lineStart + m.byteLen]
            for cl in m.clusters:
              inc compared
              let oracle = columnAt(lineText, cl.startByte, policy)
              if cl.column == oracle: inc agreed
              elif firstBad.len == 0:
                firstBad = "line " & $line & " byte " & $cl.startByte &
                           ": column " & $cl.column & " vs columnAt " & $oracle
            if m.width == lineWidth(lineText, policy): inc widthsAgreed
            lineStart += m.byteLen + 1
          if firstBad.len > 0: checkpoint(id & " tab=" & $tab & " " & firstBad)
          counted compared > 0
          counted agreed == compared
          counted widthsAgreed == c.lineCount
          # NO CLUSTER IS SPLIT, at any tab size or column: every row boundary
          # is a cluster boundary of its line.
          var splits = 0
          for i in 0 ..< c.rowCount:
            let r = c.rowAt(i)
            let m = c.metricsOf(r.line)
            var startIsBoundary = r.startByte == 0 or r.startByte == m.byteLen
            var endIsBoundary = r.endByte == 0 or r.endByte == m.byteLen
            for cl in m.clusters:
              if cl.startByte == r.startByte: startIsBoundary = true
              if cl.startByte == r.endByte: endIsBoundary = true
            if not (startIsBoundary and endIsBoundary): inc splits
          counted splits == 0
          # A ROW NEVER EXCEEDS THE WRAP COLUMN unless a single cluster does —
          # the one case where the alternative is to split it.
          var overflow = 0
          for i in 0 ..< c.rowCount:
            let r = c.rowAt(i)
            if r.width > w:
              let m = c.metricsOf(r.line)
              var clusters = 0
              for cl in m.clusters:
                if cl.startByte >= r.startByte and cl.startByte < r.endByte:
                  inc clusters
              if clusters != 1: inc overflow
          counted overflow == 0

  test "a tab's expansion DEPENDS on the tab size, and the rows move with it":
    # The negative control's positive half: a tab matrix in which the tab size
    # changed nothing would be twenty-four cases of the same case.
    let text = docById("c8-tabs-short")
    var widths: seq[int] = @[]
    for tab in TabSizes:
      let c = initWrapCache(text, wrapSettings(20, tab, awNarrow))
      var total = 0
      for line in 0 ..< c.lineCount: total += c.metricsOf(line).width
      widths.add total
    echo "  TOTAL DISPLAY WIDTH OF c8-tabs-short AT TAB SIZES " & $TabSizes &
         ": " & $widths
    counted widths.len == TabSizeCount
    counted deduplicate(widths).len == TabSizeCount
    counted widths[0] < widths[1]
    counted widths[1] < widths[2]
    # And a document with NO tab does not move — the other side of the same
    # claim, so "the tab size changes the answer" is not satisfied by a model
    # that reacts to the setting everywhere.
    let noTabs = docById("c5-cjk-short")
    var invariantWidths: seq[int] = @[]
    for tab in TabSizes:
      let c = initWrapCache(noTabs, wrapSettings(20, tab, awNarrow))
      var total = 0
      for line in 0 ..< c.lineCount: total += c.metricsOf(line).width
      invariantWidths.add total
    counted deduplicate(invariantWidths).len == 1

# ===========================================================================
# `FUZZ-6` — AFTER EVERY TRANSACTION, THE CACHE EQUALS A FULL RECOMPUTE
# ===========================================================================

suite "PLAT-27 — FUZZ-6, the cache under a random stream":

  for cls in 1 .. 9:
    test "FUZZ-6 x corpus class " & $cls:
      var r = initRng(Seed xor uint32(cls * 104729))
      let docs = genDocs(Seed xor 0x6666'u32)
      var members: seq[GenDoc] = @[]
      for d in docs:
        if parseInt($d.id[1]) == cls: members.add d
      # Two documents per class — asserted, because a filter that matched
      # nothing satisfies every law written over it (§4).
      counted members.len == 2
      var steps = 0
      var edits = 0
      for d in members:
        var doc = d.text
        let settings = wrapSettings(6, 4, awNarrow)
        var c = initWrapCache(doc, settings)
        for step in 0 ..< 20:
          let cs = genSimple(doc, r, 2)
          if cs.isIdentity: continue
          let newDoc = cs.apply(doc)
          c = c.updateWrapCache(doc, cs, newDoc)
          doc = newDoc
          inc steps
          edits += cs.changedRangeSeq().len
          counted rowsOf(c) == rowsOf(initWrapCache(doc, settings))
      # THE STREAM REALLY RAN AND REALLY EDITED.
      counted steps >= 12
      counted edits >= steps

  test "the fuzz stream really moved rows, and the cache was really spliced":
    # §4 again, one level up: a stream in which the row count never changed
    # would exercise the splice's easy path only.
    var r = initRng(Seed xor 0x7777'u32)
    let docs = genDocs(Seed xor 0x6666'u32)
    var rowCountChanges = 0
    var lineCountChanges = 0
    var steps = 0
    for d in docs:
      var doc = d.text
      let settings = wrapSettings(6, 4, awNarrow)
      var c = initWrapCache(doc, settings)
      for step in 0 ..< 20:
        let cs = genSimple(doc, r, 2)
        if cs.isIdentity: continue
        let newDoc = cs.apply(doc)
        let before = (c.rowCount, c.lineCount)
        c = c.updateWrapCache(doc, cs, newDoc)
        doc = newDoc
        inc steps
        if c.rowCount != before[0]: inc rowCountChanges
        if c.lineCount != before[1]: inc lineCountChanges
    echo "  FUZZ-6 STEPS: " & $steps & "  row-count changes: " &
         $rowCountChanges & "  line-count changes: " & $lineCountChanges
    counted steps >= 100
    counted rowCountChanges > 0
    counted lineCountChanges > 0

# ===========================================================================
# THE SUITE'S OWN NON-VACUITY — scans, the law table, and the clamp sweep
# ===========================================================================

const
  WrapSource = staticRead("../../editor/wrap.nim")
  SelectionSource = staticRead("../../editor/selection.nim")
  SelectionOpsSource = staticRead("../../editor/selection_ops.nim")
  ChangeSetSource = staticRead("../../editor/change_set.nim")
  TransactionSource = staticRead("../../editor/transaction.nim")
  TextStoreSource = staticRead("../../editor/text_store.nim")
  WrapGeneratorSource = staticRead("../generators/wrap_generator.nim")
    ## The POPULATION's module, read at compile time. It is a subject of the
    ## mutation harness and of the case that checks `DIFF-2`'s second producer
    ## is the widget rather than a second call to the model.
  LawsSuiteSource = staticRead("test_editor_wrap_laws.nim")
    ## This file, read at compile time. The case below is about the SUITE
    ## rather than the product: the model must NOT touch the threadvar and the
    ## suite MUST, and an asymmetry asserted on one side only is half a claim.
  RopeSource = staticRead("../../editor/rope.nim")
  SeqLineStoreSource = staticRead("../../editor/seq_line_store.nim")
  AnchorSource = staticRead("../../editor/anchor.nim")
  RangeSetSource = staticRead("../../editor/range_set.nim")
  DecorationSource = staticRead("../../editor/decoration.nim")
  InlaySource = staticRead("../../editor/inlay.nim")
  RowProjectionSource = staticRead("../../editor/row_projection.nim")
  DocumentVersionSource = staticRead("../../editor/document_version.nim")
  ReconcileSource = staticRead("../../editor/reconcile.nim")
  EditorStateSource = staticRead("../../editor/editor_state.nim")
  OperationsSource = staticRead("../../editor/operations.nim")
    ## **PLAT-28's FIVE, AND THE FOURTH TIME §35's ENUMERATION HAS PAID.** This
    ## case went red by name when `viewmodel/editor/` grew from eight modules to
    ## thirteen, before PLAT-28's own suites existed. `inlay.nim` is the one
    ## worth reading in this context: it computes an inline widget's columns and
    ## calls `wrap.wrapCacheOfMetrics`, and it is asserted below NOT to spell
    ## the wrap algorithm itself — which is the claim "the model computes soft
    ## wrap in exactly one module" surviving a milestone that moves the wrap
    ## point.

const ScannedModules = ["anchor.nim", "change_set.nim", "decoration.nim",
                        "document_version.nim", "editor_state.nim",
                        "inlay.nim", "operations.nim", "range_set.nim",
                        "reconcile.nim", "rope.nim", "row_projection.nim",
                        "selection.nim", "selection_ops.nim",
                        "seq_line_store.nim", "text_store.nim",
                        "transaction.nim", "wrap.nim"]
  ## GREW BY TWO ON 2026-09-18, and the growth is §35's guard doing its job
  ## rather than maintenance: PLAT-29 added `document_version.nim` and
  ## `reconcile.nim` to the directory this list claims to cover, and THIS SUITE
  ## went red by name — from a milestone that had been green for a day — until
  ## they were named here and read below.
  ##
  ## **AND BY TWO MORE, LATER THE SAME DAY.** PLAT-30's `operations.nim` and
  ## `editor_state.nim` did it again, and here the claim being defended is the
  ## sharp one: *"the model computes soft wrap in exactly one module"*. The
  ## vocabulary has twenty-four display-dependent operations and every one of
  ## them reaches wrapping through `wrap.nim` — it spells no `wrapColumn`, no
  ## `DisplayRow` and no `wrapLine` of its own, which is what the scan below
  ## now says about it rather than what this comment claims.

const EditorDirModules = block:
  ## **§35: THE SUBJECT LIST IS THE DIRECTORY, NOT A LIST SOMEBODY MAINTAINS.**
  ## `staticRead` takes a string literal, so the eight constants above are
  ## frozen at the moment they were written and a NINTH module in the same
  ## directory would be unscanned, uncounted and unmissed. A compile-time
  ## `walkDir` runs in the VM and therefore works on every backend this suite
  ## compiles to, including the ones with no filesystem at run time.
  var xs: seq[string] = @[]
  for kind, path in walkDir(currentSourcePath().parentDir.parentDir.parentDir /
                            "editor"):
    if kind == pcFile and path.endsWith(".nim"):
      xs.add path.extractFilename
  sort(xs)
  xs

const OtherModules = block:
  var xs: seq[(string, string)] = @[]
  xs.add ("change_set.nim", ChangeSetSource)
  xs.add ("rope.nim", RopeSource)
  xs.add ("selection.nim", SelectionSource)
  xs.add ("selection_ops.nim", SelectionOpsSource)
  xs.add ("seq_line_store.nim", SeqLineStoreSource)
  xs.add ("text_store.nim", TextStoreSource)
  xs.add ("transaction.nim", TransactionSource)
  xs.add ("anchor.nim", AnchorSource)
  xs.add ("range_set.nim", RangeSetSource)
  xs.add ("decoration.nim", DecorationSource)
  xs.add ("inlay.nim", InlaySource)
  xs.add ("row_projection.nim", RowProjectionSource)
  xs.add ("document_version.nim", DocumentVersionSource)
  xs.add ("reconcile.nim", ReconcileSource)
  xs.add ("editor_state.nim", EditorStateSource)
  xs.add ("operations.nim", OperationsSource)
  xs

proc codeOnly(src: string): string =
  ## Comment lines dropped. `wrap.nim`'s header DISCUSSES the threadvar
  ## overload, renderers and clamps at length, and a scan that counted prose
  ## would be a scan whose answer changes when somebody improves a doc comment
  ## (§4d).
  var lines: seq[string] = @[]
  for raw in src.splitLines():
    let t = raw.strip()
    if t.startsWith("#"): continue
    let hash = raw.find(" #")
    lines.add(if hash >= 0: raw[0 ..< hash] else: raw)
  lines.join("\n")

const ProjectionModules = ["wrap.nim", "inlay.nim", "operations.nim"]
  ## **THREE SINCE 2026-09-18, AND THE THIRD IS THE DECISION BEING CONFIRMED
  ## RATHER THAN MAINTENANCE.** PLAT-30's `operations.nim` names `WrapSettings`
  ## because twenty-four of its 224 operations TAKE it as a parameter — which
  ## is exactly what §5-vs-§9 settled — and this case went red by name until it
  ## was classified. Its sibling `editor_state.nim` is a STATE module and stays
  ## out: it holds the document, the selection, the mode, the registers and the
  ## marks, and names the settings nowhere in its code. That is the negative
  ## half of this scan gaining a member that could have gone the other way,
  ## which is the only kind of negative control worth having.
  ## The modules that may name `WrapSettings`, because a projection is what it
  ## is a parameter TO. Every other module in `viewmodel/editor/` is document
  ## state and may not — §16's decision, with both halves asserted.

const RendererSpellings = ["isonim_tui/widgets", "isonim_tui/renderer",
                           "isonim_tui/css", "isonim_tui/terminal",
                           "isonim_gpui", "karax", "std/dom"]
  ## Spelled as IMPORT PATHS rather than as words. "dom" on its own matches
  ## "random" and would make the scan pass for a reason that has nothing to do
  ## with a renderer — §5's sentinel-collision, in a scan.

suite "PLAT-27 — the suite's own non-vacuity":

  test "the law set's cardinality is asserted and every law names its killer":
    counted LawCount == 6
    var ids: seq[string] = @[]
    for l in LawId:
      counted LawName[l].len > 0
      counted LawName[l].startsWith("LAW-C")
      # §3's *"an arm with no stated killer is not admitted"*, at the suite's
      # own end. The gate checks the other end.
      counted LawKiller[l].len >= 15
      ids.add LawName[l]
    counted deduplicate(ids).len == LawCount
    counted "LAW-C7" notin ids
    # EVERY LAW RAN. A law declared and never exercised is the shape that makes
    # a six-row table mean four.
    for l in LawId:
      checkpoint(LawName[l] & " ran " & $lawChecks[l] & " check(s)")
      counted lawChecks[l] > 0

  test "the model computes soft wrap in exactly one module":
    let code = codeOnly(WrapSource)
    # NON-VACUITY FIRST (§4): if these markers are absent the scan is asleep.
    counted code.len > 2000
    counted code.contains("func wrapLine*(")
    counted code.count("func wrapLine*(") == 1
    counted code.contains("proc lineMetrics*(")
    counted code.contains("func cellsOf*(")
    # A TAB'S EXPANSION IS SPELLED ONCE IN THIS MODULE.
    counted code.count("policy.tabSize") == 3
    # AND NO OTHER MODULE IN THE DIRECTORY WRAPS ANYTHING.
    for (name, src) in OtherModules:
      checkpoint(name)
      let other = codeOnly(src)
      counted not other.contains("wrapColumn")
      counted not other.contains("DisplayRow")
      counted not other.contains("wrapLine")

  test "the scan's subject list is the directory, not a list somebody maintains":
    # §35, and the arm is one character in the extension it filters on.
    counted EditorDirModules.len > 0
    counted EditorDirModules.len == ScannedModules.len
    for name in ScannedModules:
      checkpoint(name)
      counted name in EditorDirModules
    for name in EditorDirModules:
      checkpoint(name)
      counted name in ScannedModules
    counted ScannedModules.len == 17
    counted OtherModules.len == ScannedModules.len - 1

  test "NO MODULE OF THE CORE REACHES A RENDERER — the dependency does not invert":
    # PLAT-27's named risk is *"the model answers display questions by asking
    # the renderer, and the dependency inverts without anyone noticing"*, with
    # PLAT-29's import-closure check as the mitigation. PLAT-29 has not landed,
    # so the claim is made here by a source scan over the enumerated directory
    # rather than left as a risk with no gate at all.
    #
    # The residual is stated where the scan is (§35's third rule): this catches
    # an IMPORT. It cannot catch a renderer reached through a callback somebody
    # passes in, and what makes that expensive is that no type here has room
    # for one.
    # NON-VACUITY FIRST, and it is the assertion this case most needed: a
    # scan whose SPELLING LIST is empty iterates nothing and satisfies every
    # "must not import" written over it (§4). The arm is deleting the list.
    counted RendererSpellings.len == 7
    var scanned = 0
    for (name, src) in OtherModules & @[("wrap.nim", WrapSource)]:
      let code = codeOnly(src)
      counted code.len > 200
      for spelling in RendererSpellings:
        checkpoint(name & " must not import " & spelling)
        counted not code.contains(spelling)
      inc scanned
    counted scanned == ScannedModules.len
    # AND THE ONE isonim-tui IMPORT THE CORE DOES HAVE IS THE TEXT MODULE,
    # which is a width table and a segmenter, not a renderer.
    counted codeOnly(WrapSource).contains("import isonim_tui/text/width")
    counted codeOnly(SelectionSource).contains("import isonim_tui/text/width")
    # PLAT-28's `row_projection.nim` reaches NEITHER, and that is load-bearing
    # rather than tidy: it is callable from
    # `frontend/view_vocabulary/editor_surface.nim`, which the `gpui-shell`
    # lane compiles WITHOUT isonim_tui flags. An import there would put the
    # terminal's width table into the GPUI front-end's compile.
    # **CHECKED ON THE IMPORT LINES, NOT ON THE FILE.** `decoration.nim` NAMES
    # `isonim_tui/text/width` inside a string literal — the measurement of its
    # own filed gap `PLAT28-DG4` — and a substring scan over the module cannot
    # tell a dependency from a sentence about one. Whether a module IMPORTS
    # something is a question about its import lines.
    for (name, src) in [("row_projection.nim", RowProjectionSource),
                        ("decoration.nim", DecorationSource)]:
      checkpoint(name)
      var importLines = 0
      for raw in codeOnly(src).splitLines():
        let t = raw.strip()
        if not t.startsWith("import "): continue
        inc importLines
        counted not t.contains("isonim_tui")
      counted importLines > 0

  test "the model calls the PURE width func, never the threadvar overload":
    # Deliverable 1: *"`clusterDisplayWidth(cluster, ambiguous)` is already a
    # pure `func`; the `proc` overload that reads a `threadvar` is not used
    # here"*. Executable rather than asserted in prose.
    let code = codeOnly(WrapSource)
    counted code.contains("clusterDisplayWidth(cluster, policy.ambiguous)")
    counted code.count("clusterDisplayWidth(") == 1
    counted not code.contains("setAmbiguousWidth")
    counted not code.contains("getAmbiguousWidth")
    for (name, src) in OtherModules:
      checkpoint(name)
      counted not codeOnly(src).contains("setAmbiguousWidth")
    # The SUITE does set it — for `DIFF-2`, because the widget reads it — and
    # that asymmetry is the point rather than an inconsistency.
    counted LawsSuiteSource.contains("setAmbiguousWidth(awNarrow)")

  test "NO CLAMP REPAIRS A COORDINATE — the out-of-range paths RAISE":
    # §36a: *"a guard that repairs a value silently must be a guard that RAISES,
    # unless the repair is itself a specified behaviour with a name"*. The sweep
    # is both halves.
    let code = codeOnly(WrapSource)
    # The ONE clamp in the module is the specified one, and it is in the
    # vertical motion where "stop at the last row" is the behaviour.
    counted code.count("clamp(") == 1
    counted code.contains("clamp(here.row + delta, 0, ctx.cache.rowCount - 1)")
    # Every OTHER out-of-range path raises by name. These are executed, not
    # only scanned — a `raise` nobody has seen fire is a branch nobody has run.
    let c = initWrapCache("abc\ndef", wrapSettings(2, 4, awNarrow))
    counted c.rowCount == 4
    # Each of the nine is COUNTED, so a path that stopped raising is a failed
    # assertion rather than a silently absent `expect` block.
    counted raisesWrap(proc () = discard c.rowAt(-1))
    counted raisesWrap(proc () = discard c.rowAt(c.rowCount))
    counted raisesWrap(proc () = discard c.toDisplay(textPos(-1, 0)))
    counted raisesWrap(proc () = discard c.toDisplay(textPos(9, 0)))
    counted raisesWrap(proc () = discard c.toDisplay(textPos(0, 99)))
    counted raisesWrap(proc () = discard c.toLogical(DisplayPos(row: 0, column: 99)))
    counted raisesWrap(proc () = discard c.toLogical(DisplayPos(row: 0, column: -1)))
    counted raisesWrap(proc () = c.refuseStaleCache("abc\ndefgh"))
    counted raisesWrap(proc () = discard c.rowText("abc\ndefgh", 0))
    # And the guard is FALSIFIABLE: a legal coordinate does NOT raise, or the
    # nine above would be satisfied by a routine that raised unconditionally
    # (§7b).
    counted not raisesWrap(proc () = discard c.rowAt(0))
    counted not raisesWrap(proc () = discard c.toDisplay(textPos(0, 3)))
    counted not raisesWrap(proc () = c.refuseStaleCache("abc\ndef"))
    # AND THE RAISE IS REACHABLE FROM THE SPLICE, which is where §36a's own
    # instance sat: bookkeeping that produced an index nobody could see.
    counted code.contains("the splice produced")
    counted code.contains("raise newException(WrapError")

  test "DIFF-2's OTHER SIDE IS THE WIDGET, not a second call to the model":
    # §30, mechanised — and it is here because the arm that matters cannot be
    # killed by any assertion about the answer. `G6` replaces
    # `terminalRowSpans` with the model's own rows at the widget's tab policy,
    # which is a CORRECT re-derivation of what the widget does: all thirty-six
    # `DIFF-2` cells stay green, and so does the negative half, because a model
    # at `tabSize = 0` disagrees with a model at `tabSize = 4` about tabs
    # exactly as the widget does. **It was run and it SURVIVED**, which is how
    # this case came to exist rather than as a precaution.
    #
    # So the claim that has to be checked is not about the answer, it is about
    # the PRODUCER: `terminalRowSpans` must reach `isonim-tui` and must not
    # reach this milestone's own projection. The scan goes red instead of an
    # arm surviving, which is PLAT-26's `G14` in a second shape.
    let src = codeOnly(WrapGeneratorSource)
    counted src.len > 2000
    let a = src.find("proc terminalRowSpans*(")
    counted a > 0
    # `terminalRowSpans` is the LAST routine in the file, so "the next `proc`"
    # is absent and the body runs to the end. The fallback is spelled out
    # rather than assumed, because a slice that silently became empty would
    # satisfy every `not contains` written over it (§4) — which is why the
    # body's LENGTH is asserted below rather than only its content.
    let b = src.find("\nproc ", a + 1)
    let body = src[a ..< (if b > a: b else: src.len)]
    counted body.len > 300
    # IT DRIVES THE REAL WIDGET.
    counted body.contains("tui.allDisplayRows(t)")
    counted body.contains("tui.TextAreaWidget(")
    # AND IT REACHES NOTHING OF THIS MILESTONE'S OWN.
    counted not body.contains("initWrapCache")
    counted not body.contains("wrapSettings")
    counted not body.contains("rowAt")
    counted not body.contains("wrapLine")
    # And the import is the widget module, not a transcription of it.
    counted src.contains("import isonim_tui/widgets/textarea as tui")

  test "`columnCanonical` and the law's own derivation agree, over the corpus":
    # §30: the law does not call the routine it is about. The two derivations
    # are compared ONCE, here, so that the law's oracle is a second derivation
    # and this case is the place a divergence would be reported.
    var compared = 0
    var agreed = 0
    for d in CorpusDocs:
      let c = initWrapCache(d.text, wrapSettings(20, 4, awNarrow))
      for line in 0 ..< c.lineCount:
        let m = c.metricsOf(line)
        let canon = canonicalTable(m)
        var ci = 0
        for b in 0 .. m.byteLen:
          while ci < m.clusters.len and m.clusters[ci].stopByte <= b: inc ci
          inc compared
          if canon[ci] == columnCanonical(m, b): inc agreed
    echo "  CANONICALISATION COMPARED AT " & $compared & " POSITIONS"
    counted compared > 300_000
    counted agreed == compared

  test "the gutter facts are FACTS and the model takes no view":
    let doc = motionDoc()
    let c = initWrapCache(doc, wrapSettings(8, 4, awNarrow))
    var firstRows = 0
    var continuations = 0
    for i in 0 ..< c.rowCount:
      let g = c.gutterFacts(i)
      counted g.rowsInLine >= 1
      counted g.rowInLine < g.rowsInLine
      counted g.isContinuation == (g.rowInLine > 0)
      if g.isContinuation: inc continuations else: inc firstRows
    counted firstRows == c.lineCount
    counted continuations == c.rowCount - c.lineCount
    counted continuations > 0
    # The model supplies no `showsLineNumber`: that is the rendering policy §9
    # says it must not decide.
    counted not codeOnly(WrapSource).contains("showsLineNumber")
    counted not codeOnly(WrapSource).contains("gutterWidth")

  test "TWO PROJECTIONS OF ONE DOCUMENT AT TWO WIDTHS COEXIST — the §5-vs-§9 decision, executable":
    # The decision is that wrap configuration is a PARAMETER, not a field of
    # the shared state. This is PLAT-34's shape in one case: one document, two
    # renderers, two widths, both answering at the same time, neither a global.
    let doc = motionDoc()
    let terminal = initWrapCache(doc, wrapSettings(80, 4, awNarrow))
    let window = initWrapCache(doc, wrapSettings(24, 4, awNarrow))
    counted terminal.rowCount != window.rowCount
    counted terminal.lineCount == window.lineCount
    # Both answer about the SAME logical position, and disagree about the
    # display row, and both are right.
    # A position taken FROM the document rather than written as a number: the
    # first line of `motionDoc()` is shorter than any constant worth choosing,
    # and `toDisplay` refuses an out-of-range column by name rather than
    # clamping it into range (§36a), which is how this was found.
    var probeLine = 0
    for i in 0 ..< terminal.lineCount:
      if terminal.metricsOf(i).byteLen > terminal.metricsOf(probeLine).byteLen:
        probeLine = i
    let p = textPos(probeLine, terminal.metricsOf(probeLine).byteLen div 2)
    let a = terminal.toDisplay(p)
    let b = window.toDisplay(p)
    counted terminal.toLogical(a).line == window.toLogical(b).line
    counted a != b
    # And `rewrap` reuses the cluster metrics, which is the operation the
    # decision makes cheap.
    let rewrapped = terminal.rewrap(24)
    counted rowsOf(rewrapped) == rowsOf(window)
    # NOTHING IN THE STATE CARRIES A WRAP COLUMN: the scan is the mechanical
    # half of the decision.
    #
    # **THE SCAN IS TWO-SIDED NOW, AND PLAT-28 IS WHY.** It used to read "no
    # module other than `wrap.nim` mentions `WrapSettings`", which was true
    # while `wrap.nim` was the only projection in the directory and became
    # false when `inlay.nim` arrived — a module that takes the settings as a
    # PARAMETER, which is precisely what the decision says is right. A scan
    # that forbids the spelling everywhere cannot tell a parameter from a
    # field, so the modules are split by what they ARE: a projection module may
    # name the settings, a STATE module may not, and both halves are asserted
    # or "nothing carries a wrap column" is satisfied by a list nobody keeps.
    counted ProjectionModules.len == 3
    for (name, src) in OtherModules & @[("wrap.nim", WrapSource)]:
      checkpoint(name)
      let mentions = codeOnly(src).contains("WrapSettings")
      counted mentions == (name in ProjectionModules)

# ---------------------------------------------------------------------------
# The tally
# ---------------------------------------------------------------------------

suite "PLAT-27 — the tally":
  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
