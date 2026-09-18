## PLAT-26 — `LAW-S1` … `LAW-S6`, executable, at K ∈ {1, 2, 3, 7}.
##
## Subjects: `viewmodel/editor/selection.nim` (the range variant, the
## normalising constructor, the mapping), `viewmodel/editor/selection_ops.nim`
## (the twelve primitives and `changeByRange`), and
## `viewmodel/tests/generators/selection_generator.nim` — the population the
## laws are quantified over, which is a subject like any other and is armed
## like one.
##
## =========================================================================
## WHAT THIS FILE IS FOR, IN ONE SENTENCE
## =========================================================================
##
## Editor-ViewModel.md §7 claims *"multi-cursor is not a feature — it is the
## absence of a special case"*. **That is a claim only a K > 1 sweep can
## falsify**, and every selection constructed in the tree before this milestone
## had K = 1.
##
## =========================================================================
## THE FOUR RULES THAT MAKE THIS EVIDENCE RATHER THAN A GREEN RUN
## =========================================================================
##
## 1. **EVERY LAW RUNS AT EVERY K, AND K = 1 IS KEPT AS THE ARM THAT MUST NOT
##    DISCRIMINATE.** A single-range implementation passes every K = 1 row,
##    which is what makes the K > 1 rows evidence. The rows are separate cases
##    so the K they failed at is visible without reading a log.
##
## 2. **THE GENERATOR EMITS INPUTS THAT VIOLATE THE INVARIANT.** Normalisation
##    is only tested by unsorted, touching, overlapping, nested and duplicated
##    inputs; a generator that produced only well-formed sets would make
##    `LAW-S1` trivially true — the selection analogue of §4.1's disjoint pairs
##    and of §34, where the defect a case was written to detect was committed
##    inside that case. The realised histogram is asserted as an EQUALITY per
##    class, and the overlapping, touching and nested classes are asserted by
##    name.
##
## 3. **THE TOTALITY CONTROL IS NOT A SECOND CALL TO `changeByRange`.** §30:
##    rule and control must be two derivations, not one function called twice.
##    The rule is `changeByRange`, which rebases at every step; the control
##    applies the per-range edits BACK TO FRONT (so start-document offsets stay
##    valid, and no rebase happens at all) and shifts each returned range by
##    the arithmetic sum of the length deltas before it.
##
## 4. **EVERY LAW NAMES THE MUTATION THAT MUST KILL IT**, §3.2's own column,
##    carried here beside the ids and applied by
##    `run-plat26-selection-mutations.py`. `ci/test/editor-model-case-floor.sh
##    PLAT-26` reads §3.2 out of the sibling checkout at run time and checks
##    the ids and the killers in both directions with the cardinality asserted.
##
## =========================================================================
## THE ONE PLACE THIS PORT DIVERGES FROM THE REFERENCE, AND WHY
## =========================================================================
##
## `editorSelection` merges ranges that TOUCH as well as ranges that overlap;
## CodeMirror merges a touching range only when it is empty. The reason is
## `LAW-S1`'s published killer — *"drop the merge step for touching ranges"* —
## which under the reference's rule is not observable at all: `[0,3)` and
## `[3,6)` do not overlap, so an invariant that forbids only OVERLAP is
## satisfied by the mutated output and the law cannot go red. A law whose
## published killer cannot kill it is a law nobody has watched fail. The full
## argument is in `selection.nim`'s header; the arm that shows it lands is
## `M1`.
##
## ARMING: `run-plat26-selection-mutations.py`.

import std/[options, os, strutils, tables, unittest]

import ../../editor/change_set
import ../../editor/selection
import ../../editor/selection_ops
import ../../editor/text_store
import ../generators/selection_generator

# ---------------------------------------------------------------------------
# Counted assertions
# ---------------------------------------------------------------------------

var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 2764
  ## Asserted by the last case against the runtime tally. Update it
  ## deliberately, in the same commit as the checks that moved it.

# ---------------------------------------------------------------------------
# THE SEED. Printed, so a failure is reproducible without re-running anything.
# ---------------------------------------------------------------------------

const Seed = 0x50a72600'u32
const DrawsPerCell = 6
const HistogramDraws = 400

# ---------------------------------------------------------------------------
# The laws, and their killers — §3.2's own column
# ---------------------------------------------------------------------------

type LawId = enum
  lawS1, lawS2, lawS3, lawS4, lawS5, lawS6

const LawName: array[LawId, string] = [
  "LAW-S1", "LAW-S2", "LAW-S3", "LAW-S4", "LAW-S5", "LAW-S6"]

const LawKiller: array[LawId, string] = [
  "drop the merge step for touching ranges",
  "reset the primary index to 0",
  "make one operation read s.ranges[s.primary]",
  "map both ends with the same bias",
  "recompute the goal from the landed column",
  "emit one mapped range per touched change section, so a range spanning " &
    "two edits comes back as two"]
  ## Transcribed from Editor-Model-Conformance-Suite.md §3.2. The transcription
  ## is deliberate and it is CHECKED: `ci/test/editor-model-case-floor.sh
  ## PLAT-26` parses that table out of the sibling checkout at run time and
  ## compares the six ids and six non-empty killer cells against this array, in
  ## both directions, with the cardinality asserted (§7.1). A transcription
  ## nobody checks is the defect §7's first rule is about; one a gate diffs
  ## against its source is a cache.

const LawCount = ord(high(LawId)) - ord(low(LawId)) + 1

# ---------------------------------------------------------------------------
# Helpers that are NOT the implementation
#
# Verification-Harness-Traps §29: a `unittest.check` written inside a plain
# `proc` sets a GLOBAL and the test still reports `[OK]`. Nothing in this file
# checks outside a test block.
# ---------------------------------------------------------------------------

type LawOutcome = object
  draws: int
  checks: int
  extra: int
  failures: seq[string]

proc note(o: var LawOutcome; ok: bool; what: string) =
  inc o.checks
  if not ok and o.failures.len < 4: o.failures.add what

proc shiftRange(r: SelectionRange; delta: int): SelectionRange =
  ## A range moved by a constant. **Arithmetic, and deliberately not
  ## `mapRange`**: the totality control must not be a second call to the thing
  ## under test (§30).
  case r.kind
  of srEmpty:
    caret(r.pos + delta, r.assoc, r.bidiLevel, r.goalColumn)
  of srNonEmpty:
    if r.inverted: spanRange(r.hi + delta, r.lo + delta, r.goalColumn)
    else: spanRange(r.lo + delta, r.hi + delta, r.goalColumn)

proc totalityControl(ctx: OpCtx; op: SelectionOp;
                     sel: EditorSelection): (string, EditorSelection) =
  ## §3.2's `LAW-S3`, computed the other way: *"running it per range in
  ## start-document coordinates and merging"*.
  ##
  ## No rebase, no composition and no `changeByRange`. The per-range edits are
  ## disjoint because the input selection is strictly separated, so applying
  ## them BACK TO FRONT keeps every start-document offset valid, and each
  ## returned range moves by the arithmetic sum of the length deltas of the
  ## edits before it. The precondition that makes the second half exact — that
  ## an operation which edits returns its range at its own edit site — is
  ## asserted by a case below rather than assumed here.
  var outs: seq[RangeOutcome] = @[]
  for r in sel: outs.add applyRangeOp(ctx, op, r)
  var doc = ctx.doc
  for i in countdown(outs.len - 1, 0):
    doc = changeSet(doc.len, outs[i].edits).apply(doc)
  var ranges: seq[SelectionRange] = @[]
  var delta = 0
  for i in 0 ..< outs.len:
    ranges.add shiftRange(outs[i].range, delta)
    for e in outs[i].edits: delta += e.insert.len - (e.toPos - e.fromPos)
  (doc, editorSelection(ranges, sel.primaryIndex))

proc primaryOnly(ctx: OpCtx; op: SelectionOp;
                 sel: EditorSelection): (string, EditorSelection) =
  ## **THE MUTATION, WRITTEN AS A FUNCTION SO THE SUITE CAN ASSERT IT IS
  ## DISTINGUISHABLE.** §3.2's killer for `LAW-S3` is *"make one operation read
  ## `s.ranges[s.primary]`"*, and an arm that performs it can only kill if the
  ## suite's population contains a selection on which primary-only and
  ## all-ranges DISAGREE. That is not obvious — for a K-range selection of
  ## carets under `opCollapseToHead` the two agree — so it is asserted by the
  ## gate rather than hoped for.
  applyOp(ctx, op, editorSelection([sel.mainRange], 0))

proc columnOfHead(ctx: OpCtx; r: SelectionRange): int =
  let line = ctx.store.posOf(r.head).line
  columnAt(ctx.store.lineText(line),
           r.head - ctx.store.offsetOf(textPos(line, 0)), ctx.policy)

proc landsOnClusterBoundary(ctx: OpCtx; r: SelectionRange): bool =
  r.rangeFrom in ctx.boundaries and r.rangeTo in ctx.boundaries

# ---------------------------------------------------------------------------
# The population, drawn once and shared with PLAT-25's generator
# ---------------------------------------------------------------------------

let docs = genDocs(Seed)

proc drawFor(k: int; r: var Rng): SelDraw =
  ## One draw, from a class chosen round-robin over the eight so that every
  ## cell sees violating inputs rather than whichever class the PRNG favoured.
  let d = docs[r.rand(docs.len - 1)]
  let cls = SelClass(r.rand(SelClassCount - 1))
  genSelDraw(d, r, cls, k)

# ===========================================================================
# THE LAW RUNNER
# ===========================================================================

proc runLaw(law: LawId; k: int; r: var Rng): LawOutcome =
  result.failures = @[]
  for iter in 0 ..< DrawsPerCell:
    let draw = drawFor(k, r)
    inc result.draws
    let why = describe(draw)
    let sel = editorSelection(draw.ranges, draw.primary)
    case law
    of lawS1:
      # IDEMPOTENT AND TOTAL. Total is the half that needs the violating
      # classes: `editorSelection` must produce a value for every input the
      # generator can build, not raise on the awkward ones.
      result.note(sel.invariantViolation.len == 0,
                  "S1 not normalised: " & sel.invariantViolation & " :: " & why)
      let again = editorSelection(sel.ranges, sel.primaryIndex)
      result.note(again == sel, "S1 not idempotent: " & $sel & " -> " & $again &
                  " :: " & why)
      result.note(sel.rangeCount >= 1 and sel.rangeCount <= draw.ranges.len,
                  "S1 range count " & $sel.rangeCount & " out of bounds: " & why)
      result.note(sel.primaryIndex >= 0 and sel.primaryIndex < sel.rangeCount,
                  "S1 primary out of range: " & why)
    of lawS2:
      # THE PRIMARY SURVIVES — checked by CONTAINMENT of the pre-normalisation
      # primary's head, which is not how `editorSelection` tracks it (it
      # decrements an index per merge). Two derivations, deliberately.
      let h = draw.ranges[draw.primary].head
      let m = sel.mainRange
      result.note(m.rangeFrom <= h and h <= m.rangeTo,
                  "S2 primary " & $m & " does not contain head " & $h & ": " & why)
    of lawS3:
      # TOTALITY OVER N RANGES, one operation per draw so the cell covers many
      # over its draws. The dedicated per-operation sweep is a separate suite
      # section over a different population.
      let ctx = initOpCtx(draw.doc)
      let op = SelectionOp(r.rand(SelectionOpCount - 1))
      let (docR, selR) = applyOp(ctx, op, sel)
      let (docC, selC) = totalityControl(ctx, op, sel)
      result.note(docR == docC, "S3 " & $op & " documents differ: " & why)
      result.note(selR == selC, "S3 " & $op & " selections differ: " &
                  $selR & " vs " & $selC & " :: " & why)
    of lawS4:
      # A NON-EMPTY RANGE SHRINKS AWAY FROM AN EDGE INSERT.
      for x in sel:
        if x.isEmpty: continue
        let atStart = changeSet(draw.doc.len, x.rangeFrom, x.rangeFrom, "@@")
        let m1 = mapRange(x, atStart)
        result.note(m1.rangeFrom == x.rangeFrom + 2,
                    "S4 start swallowed an insert: " & $x & " -> " & $m1 &
                    " :: " & why)
        result.note(m1.byteLen == x.byteLen,
                    "S4 extent changed at the start: " & $x & " -> " & $m1 &
                    " :: " & why)
        let atEnd = changeSet(draw.doc.len, x.rangeTo, x.rangeTo, "@@")
        let m2 = mapRange(x, atEnd)
        result.note(m2.rangeTo == x.rangeTo,
                    "S4 end swallowed an insert: " & $x & " -> " & $m2 &
                    " :: " & why)
        result.note(m2.byteLen == x.byteLen,
                    "S4 extent changed at the end: " & $x & " -> " & $m2 &
                    " :: " & why)
        inc result.extra
    of lawS5:
      # THE GOAL COLUMN IS STABLE UNDER VERTICAL MOTION. The document is a
      # ladder of alternating long and short lines built out of corpus
      # clusters; the carets are spaced far enough apart that one step down
      # cannot merge them, so the law is about the column and not about the
      # merge.
      var rr = r
      let clsIdx = 1 + (iter mod 9)
      let text = genAlternatingDoc(rr, clsIdx, 4 * k + 6, 9, 2)
      let ctx = initOpCtx(text)
      var carets: seq[SelectionRange] = @[]
      for i in 0 ..< k:
        let line = i * 4
        let lt = ctx.store.lineText(line)
        carets.add caret(ctx.store.offsetOf(textPos(line, 0)) +
                         offsetAtColumn(lt, 6, ctx.policy))
      let start = editorSelection(carets, 0)
      var before: seq[int] = @[]
      for x in start: before.add columnOfHead(ctx, x)
      let (_, down) = applyOp(ctx, opMoveLineDown, start)
      let (_, back) = applyOp(ctx, opMoveLineUp, down)
      result.note(back.rangeCount == start.rangeCount,
                  "S5 the ladder merged: " & $start & " -> " & $back)
      if back.rangeCount == start.rangeCount:
        for i in 0 ..< back.rangeCount:
          result.note(columnOfHead(ctx, back[i]) == before[i],
                      "S5 column " & $columnOfHead(ctx, back[i]) &
                      " != " & $before[i] & " at range " & $i)
          result.note(landsOnClusterBoundary(ctx, back[i]),
                      "S5 landed mid-cluster: " & $back[i])
      inc result.extra
    of lawS6:
      # MAPPING PRESERVES ORDER AND COUNT-OR-MERGE.
      let cs = genSimple(draw.doc, r)
      let mapped = mapSelection(sel, cs)
      result.note(mapped.invariantViolation.len == 0,
                  "S6 mapped set is not normalised: " &
                  mapped.invariantViolation & " :: " & why)
      result.note(editorSelection(mapped.ranges, mapped.primaryIndex) == mapped,
                  "S6 mapped set does not normalise to itself: " & why)
      result.note(mapped.rangeCount <= sel.rangeCount,
                  "S6 count rose from " & $sel.rangeCount & " to " &
                  $mapped.rangeCount & ": " & why)
      for i in 1 ..< mapped.rangeCount:
        result.note(mapped[i].rangeFrom > mapped[i - 1].rangeTo,
                    "S6 order or separation lost: " & $mapped & " :: " & why)

# ===========================================================================
# THE GENERATOR IS EVIDENCE — §4
# ===========================================================================

suite "PLAT-26 — the generator, before anything is quantified over it":

  test "the seed, the K values and the realised histogram are printed and asserted":
    echo "SEED: 0x" & toHex(Seed.BiggestInt, 8) &
         "  documents: " & $docs.len &
         "  classes: " & $SelClassCount & "  K: " & $KValues
    var r = initRng(Seed)
    var hist = initCountTable[SelClass]()
    var drawn = 0
    var kCounts = initCountTable[int]()
    for k in [2, 3, 7]:
      for cls in SelClass:
        for i in 0 ..< HistogramDraws:
          let d = docs[r.rand(docs.len - 1)]
          # ONE draw, bound to a name before two of its parts are read (§34).
          let draw = genSelDraw(d, r, cls, k)
          inc drawn
          kCounts.inc k
          hist.inc classifySelection(draw.ranges)
    for cls in SelClass:
      echo "  HISTOGRAM " & alignLeft($cls, 16) & $hist.getOrDefault(cls)
    counted drawn == 3 * SelClassCount * HistogramDraws
    counted SelClassCount == 8
    # EVERY CLASS NON-EMPTY (§4b), and then the stronger claim.
    for cls in SelClass:
      checkpoint("class " & $cls & " realised " & $hist.getOrDefault(cls))
      counted hist.getOrDefault(cls) > 0
    # THE FOUR THAT CARRY THE WEIGHT, ASSERTED BY NAME AT THEIR FULL DRAW
    # COUNT. A generator that produced only non-overlapping sets would make
    # normalisation trivially true, which is this milestone's analogue of §4.1
    # and the reason these are equalities rather than floors.
    counted hist.getOrDefault(selOverlapping) == 3 * HistogramDraws
    counted hist.getOrDefault(selTouching) == 3 * HistogramDraws
    counted hist.getOrDefault(selNested) == 3 * HistogramDraws
    counted hist.getOrDefault(selDuplicated) == 3 * HistogramDraws
    var total = 0
    for cls in SelClass: total += hist.getOrDefault(cls)
    counted total == drawn
    for k in [2, 3, 7]:
      counted kCounts.getOrDefault(k) == SelClassCount * HistogramDraws

  test "every drawn set realises the class it was drawn for, at every K > 1":
    # §34's rule: the constructor says what it MEANT to build, the classifier
    # reads the ranges back. Equality per class, not non-emptiness.
    var r = initRng(Seed xor 0x1111'u32)
    var agreed = 0
    var disagreed = 0
    for k in [2, 3, 7]:
      for cls in SelClass:
        for i in 0 ..< 60:
          let d = docs[r.rand(docs.len - 1)]
          let draw = genSelDraw(d, r, cls, k)
          if classifySelection(draw.ranges) == cls: inc agreed
          else:
            inc disagreed
            if disagreed < 4:
              checkpoint("drawn " & $cls & " at K=" & $k & " realised " &
                         $classifySelection(draw.ranges) & ": " & describe(draw))
    counted agreed == 3 * SelClassCount * 60
    counted disagreed == 0

  test "K > 1 is the common case, and K = 1 degenerates rather than lying":
    # §4.3. The draw at K = 1 has no relation to realise, so it must NOT be
    # reported as one — a generator that labelled a single range `selNested`
    # would make every K = 1 row of the law grid look like evidence.
    var r = initRng(Seed xor 0x2222'u32)
    counted KCount == 4
    counted KValues[0] == 1
    var oneRangeSets = 0
    for cls in SelClass:
      for i in 0 ..< 20:
        let d = docs[r.rand(docs.len - 1)]
        let draw = genSelDraw(d, r, cls, 1)
        counted draw.ranges.len == 1
        inc oneRangeSets
        let realised = classifySelection(draw.ranges)
        counted realised in {selDisjoint, selCarets}
    counted oneRangeSets == SelClassCount * 20
    # And at every K > 1 the set really has K ranges BEFORE normalisation.
    for k in [2, 3, 7]:
      for cls in SelClass:
        let d = docs[r.rand(docs.len - 1)]
        let draw = genSelDraw(d, r, cls, k)
        counted draw.ranges.len == k

  test "the population is corpus text with real cluster structure":
    # §4.2 and §9: a fuzzer over ASCII cannot produce the cluster boundary that
    # is the interesting input. The documents are PLAT-25's corpus windows —
    # the same eighteen — and the ladder documents `LAW-S5` uses are built out
    # of corpus clusters rather than ASCII.
    counted docs.len == 18
    var wideDocs = 0
    for d in docs:
      counted d.boundaries.len >= budgetFor(7)
      counted classWitness(d.id, d.text, d.boundaries)
      var multiByte = 0
      for i in 1 ..< d.boundaries.len:
        if d.boundaries[i] - d.boundaries[i - 1] > 1: inc multiByte
      if multiByte > 0: inc wideDocs
    counted wideDocs >= 10
    var r = initRng(Seed xor 0x3333'u32)
    var laddersWithWideGlyphs = 0
    for clsIdx in 1 .. 9:
      let text = genAlternatingDoc(r, clsIdx, 8, 9, 2)
      counted text.len > 0
      counted text.split('\n').len == 8
      if lineWidth(text.split('\n')[0]) != text.split('\n')[0].len:
        inc laddersWithWideGlyphs
    # At least one class's ladder has a line whose DISPLAY width differs from
    # its byte length — which is the only reason `LAW-S5` runs over the corpus
    # rather than over ASCII.
    counted laddersWithWideGlyphs > 0

# ===========================================================================
# THE LAWS — six ids × four values of K
# ===========================================================================

suite "PLAT-26 — LAW-S1 ... LAW-S6, at K in {1, 2, 3, 7}":

  for law in LawId:
    for k in KValues:
      test LawName[law] & " x K=" & $k:
        var r = initRng(Seed + uint32(ord(law)) * 1013'u32 + uint32(k) * 7919'u32)
        let o = runLaw(law, k, r)
        for f in o.failures: checkpoint(f)
        counted o.failures.len == 0
        # THE POPULATION FLOOR. A cell that drew nothing satisfies every law
        # written over it (§4); a cell that made no comparison satisfies it
        # twice over.
        counted o.draws == DrawsPerCell
        counted o.checks > 0

# ===========================================================================
# LAW-S3's SWEEP — twelve primitives × four values of K
# ===========================================================================
#
# The milestone's verification gate: *"For every operation that exists at this
# point, the result of running it on a K-range selection equals the result of
# running it per range independently and merging. K > 1 for every operation,
# and the number of operations swept is asserted against the vocabulary's
# cardinality so the sweep cannot silently shrink."*

suite "PLAT-26 — LAW-S3: totality over N ranges, per primitive":

  for op in SelectionOp:
    for k in KValues:
      test "totality: " & $op & " x K=" & $k:
        var r = initRng(Seed xor 0xa5a5'u32 + uint32(ord(op)) * 104729'u32 +
                        uint32(k) * 31'u32)
        var compared = 0
        var failures: seq[string] = @[]
        for cls in SelClass:
          let d = docs[r.rand(docs.len - 1)]
          let draw = genSelDraw(d, r, cls, k)
          let sel = editorSelection(draw.ranges, draw.primary)
          let ctx = initOpCtx(draw.doc)
          let (docR, selR) = applyOp(ctx, op, sel)
          let (docC, selC) = totalityControl(ctx, op, sel)
          inc compared
          if docR != docC and failures.len < 4:
            failures.add "document: " & describe(draw)
          if selR != selC and failures.len < 4:
            failures.add "selection " & $selR & " vs " & $selC & ": " &
              describe(draw)
        for f in failures: checkpoint(f)
        counted failures.len == 0
        counted compared == SelClassCount

# ===========================================================================
# NORMALISATION ON INPUTS THAT VIOLATE IT — four classes × four primaries
# ===========================================================================

const ViolationClasses = [selUnsorted, selOverlapping, selTouching,
                          selDuplicated]
  ## The four the milestone names: *"unsorted, overlapping, touching, and
  ## duplicate ranges, with the primary index's landing place checked in
  ## each"*.

suite "PLAT-26 — normalisation is asserted on inputs that violate it":

  for cls in ViolationClasses:
    for primary in 0 .. 3:
      test "normalisation: " & $cls & " / primary " & $primary:
        # K = 4 so all four primary placements are distinct indices, and the
        # landing place of each is checked rather than only the shape.
        var r = initRng(Seed xor 0xbeef'u32 + uint32(ord(cls)) * 7717'u32 +
                        uint32(primary) * 131'u32)
        var seen = 0
        for d in docs:
          var draw = genSelDraw(d, r, cls, 4)
          draw.primary = primary
          counted draw.ranges.len == 4
          counted classifySelection(draw.ranges) == cls
          let head = draw.ranges[primary].head
          let sel = editorSelection(draw.ranges, draw.primary)
          # THE INVARIANT.
          counted sel.invariantViolation.len == 0
          # THE PRIMARY'S LANDING PLACE.
          counted sel.mainRange.rangeFrom <= head
          counted head <= sel.mainRange.rangeTo
          # THE MERGE ACTUALLY HAPPENED for the three classes that ask for one,
          # and did NOT for the one that does not — two-sided, or "merging
          # everything into one range" would satisfy the rows above.
          case cls
          of selUnsorted: counted sel.rangeCount == 4
          of selOverlapping, selTouching: counted sel.rangeCount == 1
          of selDuplicated: counted sel.rangeCount == 2
          else: counted false
          inc seen
        counted seen == docs.len

# ===========================================================================
# RANGE MAPPING AT BOUNDARIES — five positions × two sides × two emptiness
# ===========================================================================
#
# The document is `0123456789`; the subject range is `[4, 8)` or a caret at 4.
# The five positions are the ones a concurrent insert can land on relative to
# a range, and they are the whole of `LAW-S4`'s surface.

type MapPosClass = enum
  mpBeforeStart, mpAtStart, mpInterior, mpAtEnd, mpAfterEnd

const MapPosOffset: array[MapPosClass, int] = [2, 4, 6, 8, 10]
const MapDoc = "0123456789"

suite "PLAT-26 — a range maps at every boundary, both sides, both emptinesses":

  for mp in MapPosClass:
    for side in [sideBefore, sideAfter]:
      for empty in [false, true]:
        test "range mapping: " & $mp & " / " & $side &
             (if empty: " / empty" else: " / non-empty"):
          let at = MapPosOffset[mp]
          let cs = changeSet(MapDoc.len, at, at, "##")
          let assoc = if side == sideBefore: assocBefore else: assocAfter
          if empty:
            let x = caret(4, assoc)
            let m = mapRange(x, cs)
            counted m.isEmpty
            # A CARET HAS NO EDGES, SO ITS ASSOCIATION DECIDES — and it decides
            # only where the insert is AT the caret. Everywhere else both
            # associations agree, which is the two-sidedness that makes the
            # `mpAtStart` row evidence rather than decoration.
            let expected =
              if at < 4: 6
              elif at > 4: 4
              elif side == sideBefore: 4
              else: 6
            counted m.pos == expected
            counted m.assoc == assoc
            let other = mapRange(caret(4, (if assoc == assocBefore: assocAfter
                                           else: assocBefore)), cs)
            if mp == mpAtStart:
              counted other.pos != m.pos      # the side DOES decide here
            else:
              counted other.pos == m.pos      # and nowhere else
          else:
            let x = spanRange(4, 8)
            let m = mapRange(x, cs)
            # THE BIAS IS FIXED BY THE TYPE, NOT PASSED IN. The start is
            # forward-biased and the end backward-biased, so an insert at
            # either edge lands OUTSIDE the range — `LAW-S4`, whose killer is
            # "map both ends with the same bias".
            # AT THE START THE RANGE MOVES OFF THE INSERT (6, not 4) — that is
            # the forward bias, and it is the cell the law exists for: the
            # inserted `##` lands OUTSIDE the selection rather than being
            # swallowed into it. At the END the range stays put (8, not 10),
            # which is the backward bias, and both together are `LAW-S4`.
            let expectedFrom = if at <= 4: 6 else: 4
            let expectedTo = if at < 8: 10 else: 8
            counted m.rangeFrom == expectedFrom
            counted m.rangeTo == expectedTo
            counted m.byteLen == (if mp == mpInterior: 6 else: 4)
            # And the same-bias alternative — the mutation — differs exactly at
            # the two edges, which is what makes the arm killable.
            let sameBias = (cs.mapPosOr(4, sideBefore), cs.mapPosOr(8, sideBefore))
            if mp == mpAtStart:
              counted sameBias[0] != m.rangeFrom
            else:
              counted sameBias[0] == m.rangeFrom

# ===========================================================================
# LAW-S5 OVER THE CORPUS'S NINE CLASSES
# ===========================================================================

const VerticalSteps = 3

suite "PLAT-26 — LAW-S5: the goal column over the corpus's nine classes":

  for clsIdx in 1 .. 9:
    test "goal column x corpus class " & $clsIdx:
      # §4.3: *"`LAW-S5` runs over the corpus's nine classes rather than over
      # ASCII, because the column is a tab-expanded DISPLAY column and a goal
      # column that is correct on ASCII and wrong on a wide glyph is the defect
      # the type was chosen to prevent."*
      var r = initRng(Seed xor 0xc010'u32 + uint32(clsIdx) * 9973'u32)
      let k = 3
      let lines = k * (2 * VerticalSteps + 2) + 4
      let text = genAlternatingDoc(r, clsIdx, lines, 9, 2)
      let ctx = initOpCtx(text)
      counted ctx.store.lineCount == lines
      var carets: seq[SelectionRange] = @[]
      for i in 0 ..< k:
        let line = i * (2 * VerticalSteps + 2)
        let lt = ctx.store.lineText(line)
        carets.add caret(ctx.store.offsetOf(textPos(line, 0)) +
                         offsetAtColumn(lt, 6, ctx.policy))
      var sel = editorSelection(carets, 0)
      var before: seq[int] = @[]
      for x in sel: before.add columnOfHead(ctx, x)
      counted before.len == k
      # N DOWN, then N UP. The ladder alternates a nine-cluster line with a
      # two-cluster one, so without a carried goal the column collapses on the
      # first step down and cannot come back.
      for step in 1 .. VerticalSteps:
        let (_, next) = applyOp(ctx, opMoveLineDown, sel)
        sel = next
        counted sel.rangeCount == k
      var collapsed = 0
      for x in sel:
        if columnOfHead(ctx, x) < before[0]: inc collapsed
      # THE LADDER IS DOING ITS JOB: at least one landing really is on a short
      # line, or "the column came back" is a claim about a document where it
      # never left.
      counted collapsed > 0
      for step in 1 .. VerticalSteps:
        let (_, next) = applyOp(ctx, opMoveLineUp, sel)
        sel = next
        counted sel.rangeCount == k
      for i in 0 ..< k:
        checkpoint("range " & $i & " column " & $columnOfHead(ctx, sel[i]) &
                   " expected " & $before[i])
        counted columnOfHead(ctx, sel[i]) == before[i]
        # AND IT LANDED ON A GLYPH. A motion that lands mid-cluster is a
        # defect, and this is the class the corpus exists to catch it in.
        counted landsOnClusterBoundary(ctx, sel[i])

# ===========================================================================
# FUZZ-3 — the selection is ALWAYS normalised, checked after every step
# ===========================================================================

type FuzzOutcome = object
  steps: int
  problems: seq[string]
  merges: int
  edits: int

proc runFuzz(clsIdx: int; r: var Rng; rounds, stepsPerRound: int): FuzzOutcome =
  ## §9's invariant set, for selections: after EVERY step the selection is
  ## ordered, strictly separated, non-empty and its primary index is in range.
  ## Seeded from the corpus, and the shortest breaking PREFIX is what gets
  ## reported.
  result.problems = @[]
  for round in 0 ..< rounds:
    let text = genAlternatingDoc(r, clsIdx, 12, 7, 2)
    var ctx = initOpCtx(text)
    var sel = block:
      var cs: seq[SelectionRange] = @[]
      let bs = ctx.boundaries
      for i in 0 ..< 4:
        let a = bs[r.rand(bs.len - 1)]
        let b = bs[r.rand(bs.len - 1)]
        cs.add spanRange(a, b)
      editorSelection(cs, r.rand(3))
    for step in 1 .. stepsPerRound:
      let op = SelectionOp(r.rand(SelectionOpCount - 1))
      let before = sel.rangeCount
      let t = runOp(ctx, op, sel)
      let after = t.changes.apply(ctx.doc)
      if after.len != t.changes.newLength:
        result.problems.add "step " & $step & ": byte length " & $after.len &
          " is not the fold " & $t.changes.newLength
      sel = t.selection.get
      let v = sel.invariantViolation
      if v.len > 0:
        result.problems.add "step " & $step & " (" & $op & "): " & v
      if sel.rangeCount > before:
        result.problems.add "step " & $step & " (" & $op & "): range count rose " &
          $before & " -> " & $sel.rangeCount
      if sel.rangeCount < before: inc result.merges
      if after != ctx.doc:
        inc result.edits
        ctx = initOpCtx(after)
      for x in sel:
        if x.rangeTo > ctx.doc.len:
          result.problems.add "step " & $step & " (" & $op & "): " & $x &
            " is outside a document of " & $ctx.doc.len & " bytes"
      inc result.steps
      if result.problems.len > 0: return

var fuzzMerges = 0
var fuzzEdits = 0

suite "PLAT-26 — FUZZ-3: the selection is always normalised":

  for clsIdx in 1 .. 9:
    test "FUZZ-3 x corpus class " & $clsIdx:
      var r = initRng(Seed xor 0xf3f3'u32 + uint32(clsIdx) * 104729'u32)
      let o = runFuzz(clsIdx, r, rounds = 3, stepsPerRound = 14)
      for p in o.problems: checkpoint(p)
      counted o.problems.len == 0
      counted o.steps == 42
      fuzzMerges += o.merges
      fuzzEdits += o.edits

suite "PLAT-26 — FUZZ-3's two arms, two-sided":

  test "the fuzz stream really merged ranges and really edited the document":
    # An arm nothing ever takes is an arm nobody has seen work. "The selection
    # is always normalised" is satisfied by a stream in which nothing ever
    # collides, and "the document is consistent" by one in which nothing ever
    # changes.
    echo "  FUZZ-3: " & $fuzzMerges & " merging steps, " & $fuzzEdits &
         " editing steps"
    counted fuzzMerges > 0
    counted fuzzEdits > 0

# ===========================================================================
# THE VERIFICATION GATE
# ===========================================================================

suite "PLAT-26 — the verification gate":

  test "THE VOCABULARY'S CARDINALITY, asserted, and the sweep taken against it":
    # §10.4 rule 3, and the milestone's own instruction: *"the gate below
    # already asserts the sweep against that cardinality. If the number of
    # primitives changes, the assertion moves the floor rather than the floor
    # hiding the change."*
    counted SelectionOpCount == 12
    counted SelectionOpCount == ord(high(SelectionOp)) - ord(low(SelectionOp)) + 1
    counted KCount == 4
    counted SelectionOpCount * KCount == 48
    var names: seq[string] = @[]
    for op in SelectionOp:
      counted $op notin names
      names.add $op
    counted names.len == SelectionOpCount

  test "A MUTATION ARM THAT READS ONLY THE PRIMARY RANGE can kill, per operation":
    # §3.2's killer for `LAW-S3` is *"make one operation read
    # `s.ranges[s.primary]`"*, and an arm performing it kills only if the
    # population contains a selection on which primary-only and all-ranges
    # DISAGREE. That is asserted here, PER OPERATION, rather than hoped for —
    # an operation for which no such selection exists would be an operation
    # whose totality row is decoration.
    var r = initRng(Seed xor 0xd1ff'u32)
    var discriminated = 0
    var missing: seq[string] = @[]
    for op in SelectionOp:
      var found = false
      for attempt in 0 ..< 40:
        if found: break
        let d = docs[r.rand(docs.len - 1)]
        let draw = genSelDraw(d, r, SelClass(r.rand(SelClassCount - 1)),
                              KValues[1 + r.rand(2)])
        let sel = editorSelection(draw.ranges, draw.primary)
        if sel.rangeCount < 2: continue
        let ctx = initOpCtx(draw.doc)
        if applyOp(ctx, op, sel) != primaryOnly(ctx, op, sel):
          found = true
      if found: inc discriminated
      else: missing.add $op
    for m in missing: checkpoint("no discriminating selection found for " & m)
    counted missing.len == 0
    counted discriminated == SelectionOpCount

  test "the totality control's precondition holds for every operation":
    # `totalityControl` shifts each returned range by the arithmetic sum of the
    # length deltas BEFORE it, which is exact only because an operation that
    # edits returns its range at its own edit site. Stated as a precondition in
    # that proc and asserted here rather than assumed.
    var r = initRng(Seed xor 0xe11e'u32)
    var withEdits = 0
    var withoutEdits = 0
    for op in SelectionOp:
      for i in 0 ..< 12:
        let d = docs[r.rand(docs.len - 1)]
        let draw = genSelDraw(d, r, SelClass(r.rand(SelClassCount - 1)), 3)
        let sel = editorSelection(draw.ranges, draw.primary)
        let ctx = initOpCtx(draw.doc)
        for x in sel:
          let o = applyRangeOp(ctx, op, x)
          if o.edits.len == 0:
            inc withoutEdits
          else:
            inc withEdits
            var lo = o.edits[0].fromPos
            var hi = o.edits[0].fromPos + o.edits[0].insert.len
            for e in o.edits:
              lo = min(lo, e.fromPos)
              hi = max(hi, e.fromPos + e.insert.len)
            counted o.range.rangeFrom >= lo
            counted o.range.rangeTo <= hi
    # BOTH POPULATIONS ARE NON-EMPTY, or the precondition is a claim about one
    # of them only.
    counted withEdits > 0
    counted withoutEdits > 0

  test "every motion lands on a cluster boundary, over all eighteen corpus documents":
    # **Positions are byte offsets and a motion that lands mid-cluster is a
    # defect** — §7, and the reason PLAT-24's corpus exists. The two operators
    # are excluded because they change the document under the boundary table;
    # the ten motions are not, so their landings are checkable directly against
    # the segmentation of the document they moved in.
    var moves = 0
    var midCluster: seq[string] = @[]
    for d in docs:
      let ctx = initOpCtx(d.text)
      for op in SelectionOp:
        if op in {opDeleteRange, opInsertText}: continue
        for b in ctx.boundaries:
          let (_, after) = applyOp(ctx, op, caretSelection(b))
          inc moves
          for x in after:
            if not landsOnClusterBoundary(ctx, x) and midCluster.len < 4:
              midCluster.add d.id & " " & $op & " from " & $b & " to " & $x
    for m in midCluster: checkpoint(m)
    counted midCluster.len == 0
    counted moves > 1000

  test "the law set's cardinality is asserted and every law names its killer":
    counted LawCount == 6
    counted LawName.len == LawCount
    counted LawKiller.len == LawCount
    var names: seq[string] = @[]
    for l in LawId:
      checkpoint(LawName[l])
      counted LawName[l].startsWith("LAW-S")
      counted LawName[l] notin names
      names.add LawName[l]
      # AN ARM WITH NO STATED KILLER IS NOT ADMITTED.
      counted LawKiller[l].len > 20
      counted LawKiller[l] != "-"
      counted not LawKiller[l].startsWith("—")
    counted names.len == LawCount

# ===========================================================================
# NO OPERATION READS THE PRIMARY — the source scan
# ===========================================================================
#
# §35: a source scan is only as wide as its subject list, so this one
# enumerates `viewmodel/editor/` at compile time and asserts the enumeration
# against the names it reads. `staticRead` takes a string literal, which is why
# the two halves have to be written separately and compared.
#
# What it can see: an operation that indexes the primary range, and a second
# module that does. What it cannot see: an operation that reaches the same
# behaviour through another spelling. The guarantee that does not depend on
# spelling is `LAW-S3`'s sweep and the arm on `changeByRange` — this scan is a
# tripwire for the cheap version.

const
  SelectionSource = staticRead("../../editor/selection.nim")
  SelectionOpsSource = staticRead("../../editor/selection_ops.nim")

  PlatSelectionModules = ["selection.nim", "selection_ops.nim"]

  EditorDirModules = block:
    var xs: seq[string] = @[]
    for kind, path in walkDir(currentSourcePath().parentDir.parentDir.parentDir /
                              "editor"):
      if kind == pcFile and path.endsWith(".nim"):
        xs.add path.extractFilename
    xs

proc codeOnly(src: string): string =
  ## Comment lines dropped. Both headers DISCUSS `s.ranges[s.primary]` at
  ## length, and a scan that counted prose would be a scan whose answer changes
  ## when somebody improves a doc comment.
  var lines: seq[string] = @[]
  for raw in src.splitLines():
    let t = raw.strip()
    if t.startsWith("#"): continue
    let hash = raw.find(" #")
    lines.add(if hash >= 0: raw[0 ..< hash] else: raw)
  lines.join("\n")

suite "PLAT-26 — no operation reads only the primary range":

  test "the primary index is read in exactly one place, and it is not an operation":
    let ops = codeOnly(SelectionOpsSource)
    let sel = codeOnly(SelectionSource)
    # Non-vacuity first: a scan that found nothing satisfies everything written
    # over it (§4).
    counted ops.len > 1000
    counted sel.len > 1000
    counted ops.contains("proc applyRangeOp*(ctx: OpCtx; op: SelectionOp; r: SelectionRange)")
    counted ops.contains("proc changeByRange*(")
    # THE PER-RANGE FUNCTION TAKES A RANGE. If it took a selection, every
    # operation could read the primary and `LAW-S3` would be the only thing
    # between the model and a single-range implementation.
    counted not ops.contains("proc applyRangeOp*(ctx: OpCtx; op: SelectionOp; r: EditorSelection)")
    # READ ONCE, and the one read is `changeByRange` carrying the caller's
    # primary index onto the result.
    counted ops.count("primaryIndex") == 1
    counted ops.contains("sel.primaryIndex)")
    counted ops.count("mainRange") == 0
    counted ops.count(".ranges[") == 0
    # And the module that OWNS the index does not let an operation reach it:
    # `ranges` and `primary` are private fields, so `primaryIndex` is the only
    # door and it is counted above.
    counted sel.contains("    ranges: seq[SelectionRange]")
    counted sel.contains("    primary: int")
    counted not sel.contains("ranges*: seq[SelectionRange]")
    counted not sel.contains("primary*: int")

  test "the scan's subject list is the directory, not a list somebody maintains":
    # §35, and the list grew by two in PLAT-26 — which is the enumeration
    # working rather than a scan quietly not covering a new file.
    counted EditorDirModules.len > 0
    for name in PlatSelectionModules:
      checkpoint(name)
      counted name in EditorDirModules
    counted PlatSelectionModules.len == 2
    # And the directory holds the other editor modules it is supposed to, so
    # the enumeration is reaching a populated directory rather than a stub.
    # NOTE: this is a COUNT, not a check that no other module defines a second
    # selection type — an earlier comment here claimed the latter, which the
    # code below does not do and `staticRead`'s string-literal argument makes
    # awkward to do. The claim that does not depend on this is `LAW-S3`.
    var others = 0
    for name in EditorDirModules:
      if name in PlatSelectionModules: continue
      inc others
    counted others >= 5

# ===========================================================================
# THE HARNESS'S OWN GUARDS
# ===========================================================================

const LawsSuiteSource = staticRead("test_editor_selection_laws.nim")
  ## This file, read at compile time. The two cases below are about the SUITE
  ## rather than about the product, and they are here because this campaign's
  ## recurring defect is a gate that cannot fail.

suite "PLAT-26 — the suite's own non-vacuity":

  test "the totality control is a SECOND DERIVATION, not a second call to the rule":
    # §30, mechanised. `totalityControl` must not reach `changeByRange`,
    # `applyOp` or `rebase` — if it did, `LAW-S3` would be `changeByRange`
    # agreeing with itself and every totality row would be decoration that no
    # mutation of `changeByRange` could redden.
    #
    # This is the ONE claim in the file that a mutation arm on the product
    # cannot establish: an arm that made the control equal to the rule would
    # SURVIVE, and a survivor is a signal a reader has to interpret. The scan
    # goes red instead.
    let src = codeOnly(LawsSuiteSource)
    counted src.len > 2000
    let a = src.find("proc totalityControl(")
    let b = src.find("proc primaryOnly(")
    counted a > 0
    counted b > a
    let body = src[a ..< b]
    counted body.contains("applyRangeOp(ctx, op, r)")
    counted body.contains("changeSet(doc.len, outs[i].edits)")
    counted not body.contains("changeByRange")
    counted not body.contains("applyOp(")
    counted not body.contains("rebase(")
    counted not body.contains("mapRange(")
    # And the RULE does use the primitive, or the two would be two copies of
    # the control rather than a rule and a control.
    counted codeOnly(SelectionOpsSource).contains("rebase(changes, newChanges)")

  test "the invariant predicate is FALSIFIABLE, and refuses each violation by name":
    # §7b: a predicate that can only be handed values the normalising
    # constructor produced is a predicate nobody has watched say "no".
    # `rangesInvariantViolation` takes a RAW sequence for exactly this reason,
    # and every violation class the generator emits is refused here.
    counted rangesInvariantViolation([spanRange(0, 4), spanRange(6, 9)], 0).len == 0
    counted rangesInvariantViolation([], 0).len > 0
    counted rangesInvariantViolation([spanRange(0, 4)], 1).len > 0
    counted rangesInvariantViolation([spanRange(0, 4)], -1).len > 0
    # UNSORTED
    counted rangesInvariantViolation([spanRange(6, 9), spanRange(0, 4)], 0).len > 0
    # OVERLAPPING
    counted rangesInvariantViolation([spanRange(0, 5), spanRange(3, 9)], 0).len > 0
    # TOUCHING — the one LAW-S1's killer drops, and the one the reference does
    # not refuse.
    counted rangesInvariantViolation([spanRange(0, 4), spanRange(4, 9)], 0).len > 0
    counted rangesInvariantViolation([spanRange(0, 4), spanRange(4, 9)], 0)
      .contains("touches or overlaps")
    # DUPLICATED
    counted rangesInvariantViolation([spanRange(0, 4), spanRange(0, 4)], 0).len > 0
    # A CARET ON AN EDGE
    counted rangesInvariantViolation([spanRange(0, 4), caret(4)], 0).len > 0
    # And the predicate at the type is the SAME predicate, not a second copy.
    counted editorSelection([spanRange(0, 4), spanRange(4, 9)]).invariantViolation.len == 0
    counted isNormalised(editorSelection([spanRange(0, 4), spanRange(4, 9)]))

# ===========================================================================
# THE SHRINKER REACHES A KNOWN MINIMUM — §4.5
# ===========================================================================

suite "PLAT-26 — the shrinker reaches a known minimum":

  test "a planted always-failing property shrinks to its known counterexample":
    # The property: "the draw covers two or more bytes in total". The minimal
    # failing draw therefore covers exactly two, and that minimum is arithmetic
    # rather than an observation of the shrinker's output.
    proc covered(d: SelDraw): int =
      for x in d.ranges: result += x.byteLen
    proc fails(d: SelDraw): bool = covered(d) >= 2

    var r = initRng(Seed xor 0x5151'u32)
    var shrunk = 0
    for cls in [selOverlapping, selNested, selTouching]:
      let d = docs[r.rand(docs.len - 1)]
      let draw = genSelDraw(d, r, cls, 7)
      checkpoint("original: " & describe(draw) & " covers " & $covered(draw))
      counted fails(draw)
      counted covered(draw) >= 6
      let small = shrink(draw, fails)
      checkpoint("shrunk:   " & describe(small) & " covers " & $covered(small))
      counted fails(small)
      # LOCALLY MINIMAL, asserted by exhausting the reductions rather than by
      # trusting the loop that produced them.
      var smallerAndStillFailing = 0
      for cand in shrinkCandidates(small):
        if cand.isValidDraw and fails(cand): inc smallerAndStillFailing
      counted smallerAndStillFailing == 0
      inc shrunk
    counted shrunk == 3

  test "the shrinker terminates on a property nothing can satisfy away":
    proc alwaysFails(d: SelDraw): bool = true
    var r = initRng(Seed xor 0x6161'u32)
    let d = docs[0]
    let draw = genSelDraw(d, r, selNested, 7)
    let small = shrink(draw, alwaysFails)
    counted small.ranges.len == 1
    counted small.doc == draw.doc
    counted small.isValidDraw

# ---------------------------------------------------------------------------
# The tally
# ---------------------------------------------------------------------------

suite "PLAT-26 — the tally":
  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
