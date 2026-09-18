## PLAT-25 — `LAW-A1` … `LAW-A10`, executable, per generator shape class.
##
## Subjects: `viewmodel/editor/change_set.nim` (the algebra and the ONE rebase
## primitive), `viewmodel/editor/transaction.nim`, and
## `viewmodel/tests/generators/change_generator.nim` (the population the laws
## are quantified over — a subject like any other, and armed like one).
##
## =========================================================================
## WHAT THIS FILE IS FOR, IN ONE SENTENCE
## =========================================================================
##
## Editor-ViewModel.md §6.1a states the rebase law, attributes it to
## `codemirror-state/src/change.ts`, says five separate features are
## consequences of it — and until this file nothing ran it. **A quoted law is
## a comment.**
##
## =========================================================================
## THE THREE RULES THAT MAKE THIS EVIDENCE RATHER THAN A GREEN RUN
## =========================================================================
##
## 1. **EACH LAW RUNS PER SHAPE CLASS, NOT ONCE OVER A BLENDED POPULATION.**
##    `LAW-A1` is *trivially true* on disjoint pairs, so a blended population
##    in which 95% of pairs are disjoint is a population on which the law is
##    95% vacuous. Ten laws × ten classes is a hundred cases, and the
##    touching-at-a-point row is visible as its own row.
##
## 2. **THE PAIR GENERATOR IS NOT TWO INDEPENDENT DRAWS** (§4.1). Both sets
##    of every pair are placed against ONE shared position budget —
##    `change_generator.window` — and the realised histogram is asserted, with
##    the *overlapping* and *touching-at-a-point* classes asserted non-empty.
##    That is the one assertion that distinguishes ten thousand interesting
##    pairs from ten thousand easy ones.
##
## 3. **EVERY LAW NAMES THE MUTATION THAT MUST KILL IT.** The killers are
##    §3.1's own column, carried here beside the ids; a case asserts every one
##    of the ten is present and non-empty, because *"an arm with no stated
##    killer is not admitted"*. The killers are then APPLIED by
##    `run-plat25-change-algebra-mutations.py`, and the cross-check against
##    the published table is `ci/test/editor-model-case-floor.sh`, which reads
##    §3.1 out of the sibling `codetracer-specs` checkout at run time and
##    fails by name when it is absent.
##
## =========================================================================
## TWO LAWS ARE NOT TRUE AS §3.1 STATES THEM, AND THE SUITE SAYS SO
## =========================================================================
##
## Both were found by running them, both are properties of the reference's
## algorithm rather than of this port, and both are recorded as measured facts
## with a pinned example each rather than quietly restated:
##
## Every figure below is taken over THIS FILE'S OWN generator — corpus
## windows, shared position budget, seed `0x50A72500` — rather than over the
## synthetic population the laws were first drafted against, because a figure
## about a different population is a figure about a different law.
## Build: Nim 2.2.8, C backend, `--mm:orc`, no `-d:release`, assertions on.
##
## * **`LAW-A2` is associative as a MAPPING and not as a VALUE.** **12
##   divergences in 5,000 generated triples**, all of them at the value level:
##   0 disagreed about the coalesced changed ranges and 0 about the document.
##   Each is a disagreement about whether one changed run is one section or
##   two. CodeMirror's own associativity test (`test-change.ts:279-288`)
##   compares `left.apply(doc)` against `right.apply(doc)` and never the
##   values — the same admission, made quietly. The law here is quantified
##   over `sameMapping`, which is strictly stronger than document equality,
##   and both facts are pinned by cases below.
##
## * **`LAW-A6` is functorial only where no step is SIDE-AMBIGUOUS.** Stated
##   as *"whenever both steps report survived"* it fails **500 times in
##   398,562** position/side pairs over a 5,000-pair draw. With the
##   precondition strengthened to "no step is side-ambiguous at this position"
##   it holds exactly — **0 failures in 389,562 included, 9,000 excluded**.
##
##   **Two of those three numbers are structural and the suite asserts them
##   exactly**, at its own 200-pair scale rather than by transcription: one
##   unrefined failure per TEN pairs and 1.8 exclusions per pair, both
##   invariant across every seed and population size measured (250, 500 and
##   1,000 draws per class x five seeds). So 5,000 pairs give 500 and 9,000,
##   and 200 pairs give 20 and 360 — which is what
##   *"the refinement excludes a real population, not an empty one"* checks,
##   together with 0 failures among the included. The third number, the
##   included total, is a function of which corpus windows were drawn and
##   moves with the seed (393,548 … 401,476 over the same five); it is bounded
##   here, not pinned. A precondition that never fires is a law about
##   everything and one that always fires is a law about nothing, and the
##   count of what the UNREFINED wording gets wrong is the only thing that
##   distinguishes a restatement from a weakening.
##
##   **There are two ways the unrefined wording fails and this population
##   produces only one of them**, which is the clearest thing in this file
##   about why §2 keeps examples beside laws. All 500 failures above are
##   disagreements about the POSITION. The second way — the composite
##   reporting *collapsed* where both steps reported *survived*, at the SAME
##   number, because the composite knows the text is gone — occurs **0 times**
##   here and was found on a synthetic population while the laws were being
##   drafted. It is real, it is reachable, and it is pinned by a hand-written
##   case below rather than left to a generator that does not happen to reach
##   it.
##
## ARMING: `run-plat25-change-algebra-mutations.py`, 28 arms. TWELVE of them
## mutate THIS FILE, the generator or the examples suite rather than the
## product, because the recurring defect in this campaign is a gate that cannot
## fail.

import std/[algorithm, os, strutils, tables, unittest]

import ../../editor/change_set
import ../../editor/text_store
import ../generators/change_generator

# ---------------------------------------------------------------------------
# Counted assertions
# ---------------------------------------------------------------------------

var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 914
  ## 898 -> 906 -> 914 on 2026-09-18: PLAT-29 added `document_version.nim` and
  ## `reconcile.nim` to `viewmodel/editor/` and PLAT-30 added `operations.nim`
  ## and `editor_state.nim`, and the double-mapping scan below runs FOUR
  ## assertions over every module in that directory. The directory enumeration
  ## is what made each of those an edit rather than a silence — and PLAT-30's
  ## made the PRODUCT move too: a paste operation's natural parameter name is
  ## this scan's own needle, `before: bool`, so `operations.nim` calls it
  ## `atRangeStart` rather than the scan being widened to spare it.
  ## Asserted by the last case. Update it deliberately, in the same commit as
  ## the checks that moved it.
  ##
  ## It moved from 858 to 870 when PLAT-26 added `selection.nim` and
  ## `selection_ops.nim` to `viewmodel/editor/`: the compile-time directory
  ## enumeration below put them in the scan's subject set, which is §35's
  ## mechanism doing exactly what it was added for.

# ---------------------------------------------------------------------------
# THE SEED. Printed, so a failure is reproducible without re-running anything.
# ---------------------------------------------------------------------------

const Seed = 0x50a72500'u32
const DrawsPerCell = 8
const GatePairs = 10_000

# ---------------------------------------------------------------------------
# The laws, and their killers — §3.1's own column
# ---------------------------------------------------------------------------

type LawId = enum
  lawA1, lawA2, lawA3, lawA4, lawA5, lawA6, lawA7, lawA8, lawA9, lawA10

const LawName: array[LawId, string] = [
  "LAW-A1", "LAW-A2", "LAW-A3", "LAW-A4", "LAW-A5",
  "LAW-A6", "LAW-A7", "LAW-A8", "LAW-A9", "LAW-A10"]

const LawKiller: array[LawId, string] = [
  "flip `before` in one of the primitive's two arms",
  "reorder the section merge in compose",
  "drop the empty-run coalescing so A . id gains a zero-length section",
  "record the inserted text's length instead of the deleted text",
  "any off-by-one in the composed section lengths",
  "apply B to the pre-A offset",
  "a side comparison that reads the wrong end of a replacement",
  "let a section's two lengths disagree",
  "drop a field from the encoder",
  "return survived for a position inside deleted text"]
  ## Transcribed from Editor-Model-Conformance-Suite.md §3.1. The transcription
  ## is deliberate and it is checked: `ci/test/editor-model-case-floor.sh`
  ## parses that table out of the sibling checkout at run time and compares the
  ## ten ids and ten non-empty killer cells against this array, in both
  ## directions, with the cardinality asserted (§7.1). A transcription nobody
  ## checks is the defect §7's first rule is about; a transcription a gate
  ## diffs against its source is a cache.

const LawCount = ord(high(LawId)) - ord(low(LawId)) + 1

# ---------------------------------------------------------------------------
# The law runner. Returns a value; the TEST BLOCK does the `check`.
#
# Verification-Harness-Traps §29: a `unittest.check` written inside a plain
# `proc` sets a GLOBAL, and the test then reports `[OK]` with the failed
# comparison printed directly above it. Nothing in this file checks outside a
# test block, and that is why.
# ---------------------------------------------------------------------------

type LawOutcome = object
  draws: int
  checks: int
  extra: int            ## a law-specific secondary population count
  failures: seq[string]

proc note(o: var LawOutcome; ok: bool; what: string) =
  inc o.checks
  if not ok and o.failures.len < 4: o.failures.add what

proc isStable(cs: ChangeSet; p: int): bool =
  ## No insertion happens exactly at `p`, so the side does not decide
  ## anything there. This is `LAW-A6`'s refined precondition, spelled ONCE —
  ## the law's population filter and the case that asserts the filter is doing
  ## work both call this (§30: one predicate, one function).
  let a = cs.mapPos(p, sideBefore)
  let b = cs.mapPos(p, sideAfter)
  a.kind == mapSurvived and b.kind == mapSurvived and a.pos == b.pos

proc isNormalised(cs: ChangeSet): bool =
  ## The builder's coalescing contract, read back off the value: no
  ## zero-extent section, no two adjacent keeps, no two adjacent pure
  ## deletions, no two adjacent pure insertions.
  ##
  ## **THIS IS WHAT `LAW-A3`'s "as VALUES, not merely as documents" ACTUALLY
  ## ASKS FOR, and it had to be added after the first mutation run.** The law
  ## as written — `A ∘ id == A` — is structurally hard to break in this
  ## encoding: the identity is a single keep spanning the document, so
  ## composing with it walks `A`'s sections one for one and reproduces them
  ## whatever the builder does about adjacency. Dropping the adjacent-keep
  ## merge (§3.1's own stated killer for `LAW-A3`) left that equality intact
  ## and was caught two suites away, by a ported composition example — a
  ## MISDIRECTED verdict, which says the run told you nothing about the case
  ## that was supposed to notice.
  ##
  ## The coalescing is observable where change sets are actually BUILT piece
  ## by piece: `rebase` emits a keep per overlapping run of the two sets, so
  ## two misaligned keep runs produce adjacent keeps on almost every pair.
  ## Asserting the contract on every change set the law sees is what makes the
  ## killer land on the law that names it.
  let ss = cs.sections
  for i, sec in ss:
    case sec.kind
    of skKeep:
      if sec.keep <= 0: return false
      if i > 0 and ss[i - 1].kind == skKeep: return false
    of skReplace:
      if sec.delete <= 0 and sec.insert.len == 0: return false
      if i > 0 and ss[i - 1].kind == skReplace:
        if sec.insert.len == 0 and ss[i - 1].insert.len == 0: return false
        if sec.delete == 0 and ss[i - 1].delete == 0: return false
  true

proc expectedArm(cs: ChangeSet; p: int): MappedKind =
  ## THE ORACLE FOR `LAW-A10`, derived from `changedRanges` rather than from
  ## `mapPos`. Two copies of one predicate would let the control agree with
  ## itself (§30); these are two independent walks of the same value.
  for r in cs.changedRanges(individual = true):
    if r.fromA < p and p < r.toA:
      return if r.inserted.len == 0: mapCollapsed else: mapDeleted
  mapSurvived

proc runLaw(law: LawId; cls: ShapeClass; docs: seq[GenDoc];
            r: var Rng): LawOutcome =
  result.failures = @[]
  for k in 0 ..< DrawsPerCell:
    let d = docs[r.rand(docs.len - 1)]
    let pair = genPair(d, r, cls)
    inc result.draws
    let a = pair.a
    let b = pair.b
    let doc = d.text
    let why = describe(pair.draw)
    # THE PRIMITIVE, CALLED ONCE PER DRAW. Every law that needs a second
    # change set expressed against the first's output takes it from here
    # rather than deriving one, so no law is quietly testing its own copy.
    let rb = rebase(a, b)
    case law
    of lawA1:
      let aFirst = compose(a, rb.bOverA)
      let bFirst = compose(b, rb.aOverB)
      result.note(aFirst.apply(doc) == bFirst.apply(doc),
                  "A1 documents differ: " & why)
      result.note(aFirst.newLength == bFirst.newLength,
                  "A1 lengths differ: " & why)
    of lawA2:
      let x = a
      let y = rb.bOverA
      let mid = compose(x, y)
      let z = genSimple(mid.apply(doc), r)
      let left = compose(compose(x, y), z)
      let right = compose(x, compose(y, z))
      result.note(sameMapping(left, right), "A2 mappings differ: " & why)
      result.note(left.apply(doc) == right.apply(doc),
                  "A2 documents differ: " & why)
      if left != right: inc result.extra    # the value-level divergence
    of lawA3:
      for s in [a, b]:
        result.note(compose(s, identityChangeSet(s.newLength)) == s,
                    "A3 s . id differs as a value: " & why)
        result.note(compose(identityChangeSet(s.length), s) == s,
                    "A3 id . s differs as a value: " & why)
      # The other half of "as values": every change set any operation produces
      # is in the builder's canonical form. Without this the law is satisfied
      # by an encoding that keeps a zero-length run or two adjacent keeps —
      # see `isNormalised`.
      for s in [a, b, rb.aOverB, rb.bOverA,
                compose(a, rb.bOverA), invert(a, doc),
                identityChangeSet(doc.len)]:
        result.note(isNormalised(s), "A3 not in canonical form: " & why)
    of lawA4:
      for s in [a, b]:
        result.note(invert(s, doc).apply(s.apply(doc)) == doc,
                    "A4 round trip: " & why)
    of lawA5:
      result.note(compose(a, rb.bOverA).apply(doc) ==
                    rb.bOverA.apply(a.apply(doc)), "A5 a-first: " & why)
      result.note(compose(b, rb.aOverB).apply(doc) ==
                    rb.aOverB.apply(b.apply(doc)), "A5 b-first: " & why)
    of lawA6:
      let x = a
      let y = rb.bOverA
      let xy = compose(x, y)
      for p in 0 .. doc.len:
        for side in [sideBefore, sideAfter]:
          let m1 = x.mapPos(p, side)
          if m1.kind != mapSurvived: continue
          let m2 = y.mapPos(m1.pos, side)
          if m2.kind != mapSurvived: continue
          if not (isStable(x, p) and isStable(y, m1.pos) and isStable(xy, p)):
            inc result.extra
            continue
          result.note(xy.mapPos(p, side) == m2,
                      "A6 at " & $p & " " & $side & ": " & why)
    of lawA7:
      for s in [a, b]:
        for side in [sideBefore, sideAfter]:
          var prev = -1
          for p in 0 .. doc.len:
            let m = s.mapPos(p, side)
            if m.kind == mapSurvived:
              result.note(m.pos >= prev, "A7 not monotone at " & $p & ": " & why)
              prev = m.pos
    of lawA8:
      for s in [a, b]:
        result.note(s.length == doc.len, "A8 length: " & why)
        result.note(s.newLength == s.apply(doc).len, "A8 newLength: " & why)
    of lawA9:
      for s in [a, b, rb.aOverB, rb.bOverA]:
        let wire = encodeChangeSet(s)
        result.note(decodeChangeSet(wire) == s, "A9 round trip: " & why)
        result.note(encodeChangeSet(s) == wire, "A9 not deterministic: " & why)
    of lawA10:
      for s in [a, b]:
        for p in 0 .. doc.len:
          for side in [sideBefore, sideAfter]:
            let m = s.mapPos(p, side)
            result.note(m.kind == expectedArm(s, p),
                        "A10 arm at " & $p & " " & $side & ": " & why)

# ---------------------------------------------------------------------------
# The population, drawn once and shared
# ---------------------------------------------------------------------------

let docs = genDocs(Seed)

# ===========================================================================
# THE GENERATOR IS EVIDENCE — §4
# ===========================================================================

suite "PLAT-25 — the generator, before anything is quantified over it":

  test "the seed, the case count and the realised histogram are printed and asserted":
    echo "SEED: 0x" & toHex(Seed.BiggestInt, 8) &
         "  documents: " & $docs.len &
         "  pairs: " & $(ShapeClassCount * 1000)
    var r = initRng(Seed)
    var hist = initCountTable[ShapeClass]()
    var drawn = 0
    for cls in ShapeClass:
      for i in 0 ..< 1000:
        let d = docs[r.rand(docs.len - 1)]
        inc drawn
        # ONE draw, both halves of it. Writing this as
        # `classifyPair(genPair(...).a, genPair(...).b)` draws TWO pairs and
        # takes one half of each — which is the two-independent-draws defect
        # §4.1 exists to forbid, committed inside the case that asserts it is
        # not committed. It smeared the histogram across every class and the
        # class floors are what caught it.
        let p = genPair(d, r, cls)
        hist.inc classifyPair(p.a, p.b)
    for cls in ShapeClass:
      echo "  HISTOGRAM " & alignLeft($cls, 18) & $hist.getOrDefault(cls)
    # 1. the number of cases actually produced, against a declared minimum.
    counted drawn == ShapeClassCount * 1000
    counted ShapeClassCount == 10
    # 2. EVERY class non-empty. §4b: a partial set is worse than an empty one,
    #    because "at least one case ran" is satisfied by the easy shape.
    for cls in ShapeClass:
      checkpoint("class " & $cls & " realised " & $hist.getOrDefault(cls))
      counted hist.getOrDefault(cls) > 0
    # 3. THE TWO THAT CARRY THE WEIGHT, asserted by name and by a floor that
    #    a disjoint-heavy generator could not meet. §4.1: without this,
    #    10,000 pairs can be 10,000 easy pairs.
    counted hist.getOrDefault(clsOverlapping) == 1000
    counted hist.getOrDefault(clsTouchingPoint) == 1000
    counted hist.getOrDefault(clsCollapsePoint) == 1000
    # 4. and the total is accounted for, so a class cannot be double counted.
    var total = 0
    for cls in ShapeClass: total += hist.getOrDefault(cls)
    counted total == drawn

  test "every drawn pair realises the class it was drawn for":
    # The constructor says what it MEANT to build; `classifyPair` says what it
    # built. A generator that labelled its own output would be agreeing with
    # itself (§30), so the two are compared rather than one of them trusted.
    var r = initRng(Seed xor 0x1111'u32)
    var agreed = 0
    var disagreed = 0
    for cls in ShapeClass:
      for i in 0 ..< 200:
        let d = docs[r.rand(docs.len - 1)]
        let p = genPair(d, r, cls)
        if classifyPair(p.a, p.b) == cls: inc agreed
        else:
          inc disagreed
          if disagreed < 4:
            checkpoint("drawn " & $cls & " realised " &
                       $classifyPair(p.a, p.b) & ": " & describe(p.draw))
    counted agreed == ShapeClassCount * 200
    counted disagreed == 0

  test "every corpus window offers the boundaries a shared budget needs":
    # A document too small to hold the shapes makes its class's draws
    # degenerate silently. Asserted per document rather than in aggregate.
    counted docs.len == 18
    var r = initRng(Seed)
    for d in docs:
      checkpoint(d.id & ": " & $d.boundaries.len & " boundaries, " &
                 $d.text.len & " bytes")
      counted d.boundaries.len >= GenDocMinBoundaries
      counted d.text.len > 0
      counted d.boundaries[0] == 0
      counted d.boundaries[^1] == d.text.len
      # AND IT IS STILL A WINDOW OF ITS CLASS. A random cut out of a
      # 17,000-byte document can contain none of what put that document in its
      # class, and a `c7-illformed` window with no ill-formed byte in it makes
      # every law quantified over class 7 a law about ordinary ASCII. Measured
      # on the first seed tried: `c7-illformed-long`'s window came out
      # entirely ASCII and FUZZ-1's refusal arm fired zero times.
      counted classWitness(d.id, d.text, d.boundaries)
      # The budget itself: seven strictly ascending positions, every one of
      # them a cluster boundary of THIS document.
      let w = window(d, r, WindowPositions)
      counted w.len == WindowPositions
      for i in 1 ..< w.len: counted w[i] > w[i - 1]
      for p in w: counted p in d.boundaries

  test "the population is real Unicode, not ASCII wearing a corpus's name":
    # §4.2 and §9. The generator's whole claim is that it draws from the
    # corpus; a corpus window that had come out all-ASCII would satisfy every
    # law in this file and demonstrate nothing about clusters.
    var multiByteDocs = 0
    var multiRuneClusters = 0
    for d in docs:
      var nonAscii = 0
      for ch in d.text:
        if uint8(ch) >= 0x80'u8: inc nonAscii
      if nonAscii > 0: inc multiByteDocs
      for i in 1 ..< d.boundaries.len:
        if d.boundaries[i] - d.boundaries[i - 1] > 1: inc multiRuneClusters
    checkpoint($multiByteDocs & " of " & $docs.len &
               " windows carry non-ASCII bytes; " & $multiRuneClusters &
               " clusters are wider than one byte")
    # Measured on this seed: 11 of the 18 windows carry non-ASCII bytes and
    # 110 of their clusters are wider than one byte. The seven that do not are
    # the windows cut from classes 6, 8 and 9 (line terminators, tabs, ASCII
    # control) plus `c7-illformed-long`, and those classes ARE ASCII — a floor
    # of 18 here would be a floor the corpus cannot meet by construction.
    counted multiByteDocs >= 10
    counted multiRuneClusters >= 100
    # THE WITNESS PREDICATE IS FALSIFIABLE, which is the half that is usually
    # missing (§7b): plain ASCII must fail it for every class that is not an
    # ASCII class, and a c7 window must fail it when its ill-formed byte is
    # replaced by an ordinary one.
    counted not classWitness("c1-zwj-short", "plain ascii", @[0, 11])
    counted not classWitness("c3-regional-short", "plain ascii", @[0, 11])
    counted not classWitness("c5-cjk-short", "plain ascii", @[0, 11])
    counted not classWitness("c7-illformed-short", "plain ascii", @[0, 11])
    counted not classWitness("c8-tabs-short", "plain ascii", @[0, 11])
    counted not classWitness("c9-ascii-control-short", "plain ascii", @[0, 11])
    counted classWitness("c9-ascii-control-short", "plain\x07ascii", @[0, 11])

  test "one seed, one population — the same on the C backend and on node":
    # The seed is printed so a failure is reproducible. That is worth nothing
    # if the two backends draw different pairs from it, which is exactly what
    # `std/random` would give: its state is two `uint64` and `nim js`
    # emulates those. The 32-bit xorshift is exact on both, and this case is
    # the pin — it runs in the `vm-unit` lane AND in `vm-unit-js`, so a
    # divergence reddens one of the two.
    var r = initRng(0x12345678'u32)
    counted r.nextU32() == 0x87985AA5'u32
    counted r.nextU32() == 0x155B24A3'u32
    counted r.nextU32() == 0x4820F4C4'u32
    var r2 = initRng(1'u32)
    var acc = 0
    for i in 0 ..< 64: acc += r2.rand(9)
    counted acc == 295

# ===========================================================================
# THE LAWS — ten ids × ten shape classes
# ===========================================================================

suite "PLAT-25 — LAW-A1 ... LAW-A10, per generator shape class":

  for law in LawId:
    for cls in ShapeClass:
      test LawName[law] & " x " & $cls:
        var r = initRng(Seed + uint32(ord(law)) * 1013'u32 +
                        uint32(ord(cls)) * 7919'u32)
        let o = runLaw(law, cls, docs, r)
        for f in o.failures: checkpoint(f)
        counted o.failures.len == 0
        # THE POPULATION FLOOR. A cell that drew nothing satisfies every law
        # written over it (§4); a cell that made no comparison satisfies it
        # twice over.
        counted o.draws == DrawsPerCell
        counted o.checks > 0

# ===========================================================================
# THE TWO REFINEMENTS, PINNED
# ===========================================================================

suite "PLAT-25 — where §3.1's wording is stronger than the algebra":

  test "LAW-A2: associativity holds as a mapping and NOT as a value":
    # The minimal counterexample, found by search and pinned here so the fact
    # is asserted rather than described. Over "b": `x` inserts two bytes at the
    # end, `y` inserts one more at the end of that, `z` deletes the first
    # three. `(x.y).z` comes back as ONE section — a three-byte replacement —
    # and `x.(y.z)` as TWO, a deletion followed by an insertion. Both produce
    # "Y".
    let d = "b"
    let x = changeSet(1, 1, 1, "XY")
    let y = changeSet(3, 3, 3, "Y")
    let z = changeSet(4, 0, 3, "")
    let left = compose(compose(x, y), z)
    let right = compose(x, compose(y, z))
    counted left.apply(d) == right.apply(d)      # documents agree
    counted sameMapping(left, right)             # mappings agree
    counted left != right                        # VALUES do not
    counted left.sections.len == 1
    counted right.sections.len == 2
    # And `sameMapping` is strictly stronger than document equality, or the
    # law above would have been weakened rather than restated: these two
    # produce the same document from "ab" and are not the same mapping.
    let p = changeSet(2, 0, 1, "a")
    let q = changeSet(2, 1, 2, "b")
    counted p.apply("ab") == q.apply("ab")
    counted not sameMapping(p, q)

  test "LAW-A6: the two ways the unrefined wording fails, one example each":
    # (i) THE ANSWER DIFFERS. `x` deletes the only byte; `y` inserts two after
    # it. Stepwise with `sideAfter` lands after the insertion; the composite
    # merges the two into one changed run and lands at its start. The position
    # is side-ambiguous for `y`, which is what the refinement excludes.
    let x = changeSet(1, 0, 1, "")
    let y = changeSet(0, 0, 0, "XY")
    let xy = compose(x, y)
    let step = y.mapPos(x.mapPos(0, sideAfter).pos, sideAfter)
    counted step == Mapped(kind: mapSurvived, pos: 2)
    counted xy.mapPos(0, sideAfter) == Mapped(kind: mapSurvived, pos: 0)
    counted not isStable(y, 0)
    # (ii) THE ARM DIFFERS AND THE POSITION DOES NOT. **This is the one the
    # committed generator does not reach** — 0 occurrences in 398,562
    # position/side pairs — so it is here as a hand-written example rather
    # than as a row in a histogram. Two deletions that meet:
    # each step reports the position survived at its own edge, and the
    # composite — which knows the byte is gone — reports it collapsed. Same
    # number, more information.
    let doc = "cbccaba"
    let u = changeSet(7, 0, 5, "")
    let v = changeSet(2, 0, 1, "")
    let uv = compose(u, v)
    let s1 = u.mapPos(5, sideBefore)
    counted s1.kind == mapSurvived
    let s2 = v.mapPos(s1.pos, sideBefore)
    counted s2 == Mapped(kind: mapSurvived, pos: 0)
    counted uv.mapPos(5, sideBefore).kind == mapCollapsed
    counted uv.mapPosOr(5, sideBefore) == s2.pos
    counted uv.apply(doc) == "a"

  test "the refinement excludes a real population, not an empty one":
    # A precondition that never fires is a law stated over everything, and a
    # precondition that fires always is a law stated over nothing. Both ends
    # are asserted, over the same draws the cells use.
    #
    # AND SO IS THE THING THE REFINEMENT EXISTS FOR: the number of failures
    # the UNREFINED wording produces on this very population, which is what
    # makes "LAW-A6 is false as §3.1 stated it" a measurement here rather than
    # a sentence somewhere else. Two of the three counts are structural rather
    # than statistical — one failure per ten pairs and 1.8 exclusions per pair,
    # invariant across every seed and population size tried — so they are
    # asserted EXACTLY. The third, `included`, is a function of the documents
    # drawn and is bounded rather than pinned.
    const PopulationPairs = 200
    var r = initRng(Seed xor 0x2222'u32)
    var included = 0
    var excluded = 0
    var unrefinedFailures = 0
    var refinedFailures = 0
    var pairs = 0
    for cls in ShapeClass:
      for k in 0 ..< PopulationPairs div ShapeClassCount:
        let d = docs[r.rand(docs.len - 1)]
        let pair = genPair(d, r, cls)
        let x = pair.a
        let y = rebase(x, pair.b).bOverA
        let xy = compose(x, y)
        inc pairs
        for p in 0 .. d.text.len:
          for side in [sideBefore, sideAfter]:
            let m1 = x.mapPos(p, side)
            if m1.kind != mapSurvived: continue
            # `stepped`, not `m2`: the law's own check spells this line with
            # `m2` and a mutation arm's needle quotes it, so a second copy of
            # that exact text here would make the arm AMBIGUOUS and unkillable
            # (§32). The needle scan caught this when it was written.
            let stepped = y.mapPos(m1.pos, side)
            if stepped.kind != mapSurvived: continue
            let stepwiseDiffers = xy.mapPos(p, side) != stepped
            if stepwiseDiffers: inc unrefinedFailures
            if isStable(x, p) and isStable(y, m1.pos) and isStable(xy, p):
              inc included
              if stepwiseDiffers: inc refinedFailures
            else:
              inc excluded
    echo "  LAW-A6 population: " & $pairs & " pairs, " & $included &
         " included, " & $excluded & " excluded by the stability " &
         "precondition; " & $unrefinedFailures &
         " failures as §3.1 states the law, " & $refinedFailures & " with it"
    counted pairs == PopulationPairs
    counted included > 1000
    counted excluded > 0
    counted excluded < included    # the filter is a refinement, not a gate
    # THE LAW IS FALSE AS §3.1 WROTE IT, on this population, by this many.
    counted unrefinedFailures == PopulationPairs div 10
    counted excluded == (PopulationPairs * 9) div 5
    # AND TRUE WITH THE PRECONDITION. A restatement that did not also show the
    # unrefined wording failing would be a law weakened to fit an
    # implementation, which is the thing §3.1a is not allowed to be.
    counted refinedFailures == 0

# ===========================================================================
# THE VERIFICATION GATE
# ===========================================================================

suite "PLAT-25 — the verification gate":

  test "THE IDENTITY, over 10,000 generated pairs from a stated distribution":
    # PLAT-25's first gate line, and the one the milestone exists for.
    #
    # ONE FUNCTION, ONE TEST, RULE AND CONTROL BOTH CALLING IT (§30). The two
    # sides below are `compose(a, r.bOverA)` and `compose(b, r.aOverB)` with
    # `r` from ONE `rebase` call. Nothing here re-derives either arm; a second
    # copy of the primitive inside the test is the defect this campaign has
    # met at least twice.
    var r = initRng(Seed xor 0xa1a1a1a1'u32)
    var hist = initCountTable[ShapeClass]()
    var pairs = 0
    var agreed = 0
    var firstFailure = ""
    let perClass = GatePairs div ShapeClassCount
    for cls in ShapeClass:
      for k in 0 ..< perClass:
        let d = docs[r.rand(docs.len - 1)]
        let pair = genPair(d, r, cls)
        inc pairs
        hist.inc classifyPair(pair.a, pair.b)
        let rb = rebase(pair.a, pair.b)
        if compose(pair.a, rb.bOverA).apply(d.text) ==
           compose(pair.b, rb.aOverB).apply(d.text):
          inc agreed
        elif firstFailure.len == 0:
          firstFailure = describe(pair.draw)
          # §4.5: the shrunk counterexample, and the original beside it.
          let small = shrink(pair.draw, proc (dr: EditDraw): bool =
            let p = build(dr)
            let rr = rebase(p.a, p.b)
            compose(p.a, rr.bOverA).apply(dr.doc) !=
              compose(p.b, rr.aOverB).apply(dr.doc))
          checkpoint("original:  " & firstFailure)
          checkpoint("shrunk to: " & describe(small))
    echo "  GATE: " & $pairs & " pairs, " & $agreed & " agreed"
    counted pairs == GatePairs
    counted agreed == GatePairs
    # THE COUNT IS ASSERTED, so a generator that silently produced nothing
    # cannot pass — and the distribution is asserted too, because a generator
    # that produced only the easy class satisfies "at least one case ran".
    counted hist.getOrDefault(clsOverlapping) == perClass
    counted hist.getOrDefault(clsTouchingPoint) == perClass
    counted hist.len == ShapeClassCount

  test "invert round-trips over the same population":
    var r = initRng(Seed xor 0xa1a1a1a1'u32)     # the SAME population
    var checked = 0
    var ok = 0
    let perClass = GatePairs div ShapeClassCount
    for cls in ShapeClass:
      for k in 0 ..< perClass:
        let d = docs[r.rand(docs.len - 1)]
        let pair = genPair(d, r, cls)
        for s in [pair.a, pair.b]:
          inc checked
          if invert(s, d.text).apply(s.apply(d.text)) == d.text: inc ok
    counted checked == GatePairs * 2
    counted ok == checked

  test "the law set's cardinality is asserted and every law names its killer":
    # §3's opening rule, applied to this file rather than only stated in it.
    counted LawCount == 10
    counted LawName.len == LawCount
    counted LawKiller.len == LawCount
    var names: seq[string] = @[]
    for l in LawId:
      checkpoint(LawName[l])
      counted LawName[l].startsWith("LAW-A")
      counted LawName[l] notin names
      names.add LawName[l]
      # AN ARM WITH NO STATED KILLER IS NOT ADMITTED. An em dash in §3.1's
      # column means the law is not admitted, and seven laws in that document
      # held one until 2026-09-18 — so the check is for a real sentence, not
      # for a non-empty cell.
      counted LawKiller[l].len > 20
      counted LawKiller[l] != "-"
      counted not LawKiller[l].startsWith("—")
    counted names.len == LawCount

  test "every law ran against every shape class, and the product is the floor's first term":
    # The two multipliers that carry PLAT-25's floor — 10 laws and 10 shape
    # classes — are both enumerated lists a check can count (§10.4 rule 3).
    counted LawCount * ShapeClassCount == 100
    counted LawCount == ord(high(LawId)) - ord(low(LawId)) + 1
    counted ShapeClassCount == ord(high(ShapeClass)) - ord(low(ShapeClass)) + 1

# ===========================================================================
# ONE FUNCTION, ONE NAME — the source scan
# ===========================================================================
#
# The deliverable is "ONE rebase function, with one name", and the risk the
# milestone names is that it gets inlined at its call sites "for clarity" and
# the campaign acquires five copies of a four-line function, one with the flag
# wrong. A mutation arm on the primitive catches an inlined copy by SURVIVING,
# which is a signal a reader has to interpret. This scan catches it by going
# red.
#
# `staticRead`, never a runtime `readFile`: `std/os` has no `readFile` on the
# JS backend, this directory is compiled by three lanes, and a scan that read
# nothing would satisfy every "must be exactly these" written over it.
#
# WHAT THIS SCAN CAN AND CANNOT SEE, STATED BEFORE IT IS TRUSTED
# ==============================================================
# `staticRead` takes a STRING LITERAL, so the sources below are a hardcoded
# list — and a hardcoded list is blind to a SIXTH module dropped into the same
# directory. That is not hypothetical: planting
# `viewmodel/editor/rebase_copy.nim`, exporting `mapOver(setA, setB:
# ChangeSet; before: bool)` in the exact spelling the checks below forbid, and
# importing it from `transaction.nim`, leaves this suite at 130 of 130 green.
# `EditorModules` closes that: the directory is ENUMERATED at compile time
# (which works on the C and the JS backend alike, because it happens in the
# VM) and its `.nim` set is required to be exactly the set that is read, so a
# new module fails by name until somebody adds it here.
#
# What the scan still cannot see is a RE-IMPLEMENTATION under another name:
# `sections*` is an exported accessor, so another module can walk two change
# sets itself and call its flag something else. The checks below are a
# tripwire for the cheap copy — the four lines lifted out of `rebase` — and
# nothing stronger. The guarantee that does not depend on spelling is the
# compiler's: `mapOver` is unexported, so a copy has to be written from
# scratch rather than pasted.

const
  ChangeSetSource = staticRead("../../editor/change_set.nim")
  TransactionSource = staticRead("../../editor/transaction.nim")
  RopeSource = staticRead("../../editor/rope.nim")
  TextStoreSource = staticRead("../../editor/text_store.nim")
  SeqLineStoreSource = staticRead("../../editor/seq_line_store.nim")
  SelectionSource = staticRead("../../editor/selection.nim")
  SelectionOpsSource = staticRead("../../editor/selection_ops.nim")
  WrapSource = staticRead("../../editor/wrap.nim")
  AnchorSource = staticRead("../../editor/anchor.nim")
  RangeSetSource = staticRead("../../editor/range_set.nim")
  DecorationSource = staticRead("../../editor/decoration.nim")
  InlaySource = staticRead("../../editor/inlay.nim")
  RowProjectionSource = staticRead("../../editor/row_projection.nim")
  DocumentVersionSource = staticRead("../../editor/document_version.nim")
  ReconcileSource = staticRead("../../editor/reconcile.nim")
  EditorStateSource = staticRead("../../editor/editor_state.nim")
  OperationsSource = staticRead("../../editor/operations.nim")

  ScannedModules = ["anchor.nim", "change_set.nim", "decoration.nim",
                    "document_version.nim", "editor_state.nim", "inlay.nim",
                    "operations.nim", "range_set.nim",
                    "reconcile.nim", "rope.nim", "row_projection.nim",
                    "selection.nim", "selection_ops.nim",
                    "seq_line_store.nim", "text_store.nim",
                    "transaction.nim", "wrap.nim"]
    ## The thirteen names above, as data. It moves in the same edit as the
    ## `staticRead` list and the case below is what refuses the two to drift.
    ##
    ## **It grew by two when PLAT-26 landed and by one more when PLAT-27 did,
    ## and that is the enumeration working.** §35 is the trap that a hardcoded
    ## subject list cannot see a new file in the directory it claims to cover;
    ## `EditorModules` below enumerates the directory at compile time, so
    ## `selection.nim` and `selection_ops.nim` failed this case BY NAME on the
    ## first build of PLAT-26, and `wrap.nim` failed it BY NAME on the first
    ## run of PLAT-27's floor gate — before that milestone's own suite existed
    ## to say anything, and from a milestone that had been green for a day.
    ## That is the mechanism paying for itself twice — and a THIRD time on
    ## 2026-09-18, when PLAT-28 added `anchor.nim`, `range_set.nim`,
    ## `decoration.nim`, `inlay.nim` and `row_projection.nim` and this case
    ## went red by name on the first build of that milestone's floor gate.
    ## `anchor.nim` is the one that matters: §8.2 says an anchor is mapped
    ## through every change set that passes *"including remote ones"*, which is
    ## exactly where a sixth hand-written double mapping would land.
    ##
    ## **AND A FOURTH TIME ON THE SAME DAY**: PLAT-29 added
    ## `document_version.nim` and `reconcile.nim`, and this case went red by
    ## name before that milestone's own suites existed. `reconcile.nim` is the
    ## one that matters this time, for `anchor.nim`'s reason one layer up: it
    ## moves an async producer's change set over the edits that landed while it
    ## was in flight, which is the fifth of §6.1a's five reference call sites
    ## and is exactly where a sixth hand-written double mapping would land. It
    ## calls `rebase` and takes `bOverA`; it spells no flag, because there is
    ## no flag to spell.
    ##
    ## **AND A FIFTH TIME, LATER THE SAME DAY**: PLAT-30 added
    ## `operations.nim` and `editor_state.nim`, and this case went red by name
    ## on the first run of the whole lane — from a suite that had been green
    ## since the day before. `operations.nim` is the one that matters: it is
    ## the 224-operation vocabulary, every editing operation in the model goes
    ## through it, and it reaches the algebra through `changeByRange` alone. It
    ## spells no flag either — and the scan made it RENAME one: a paste
    ## operation's natural parameter name is `before: bool`, which is exactly
    ## this scan's needle, so the module calls it `atRangeStart` and says why
    ## (§5's sentinel collision, resolved in favour of keeping the tripwire
    ## sharp).

  EditorModules = block:
    ## Every `.nim` file actually in `viewmodel/editor/`, sorted, read out of
    ## the filesystem at COMPILE TIME rather than transcribed.
    var xs: seq[string] = @[]
    for kind, path in walkDir(currentSourcePath().parentDir.parentDir.parentDir /
                              "editor"):
      if kind == pcFile and path.endsWith(".nim"):
        xs.add path.extractFilename
    sort(xs)
    xs

proc codeOnly(src: string): string =
  ## Comment lines dropped. The headers of these files DISCUSS `mapOver` and
  ## `before` at length, and a scan that counted prose would be a scan whose
  ## answer changes when somebody improves a doc comment.
  var lines: seq[string] = @[]
  for raw in src.splitLines():
    let t = raw.strip()
    if t.startsWith("#"): continue
    let hash = raw.find(" #")
    lines.add(if hash >= 0: raw[0 ..< hash] else: raw)
  lines.join("\n")

suite "PLAT-25 — one function, one name":

  test "the flag-taking routine is private, declared once, and called twice":
    let code = codeOnly(ChangeSetSource)
    # Non-vacuity first: a scan that found nothing satisfies everything
    # written over it (§4). If these markers are absent the scan is asleep.
    counted code.len > 1000
    counted code.contains("proc rebase*(a, b: ChangeSet): Rebased")
    counted code.contains("proc mapOver(")
    # PRIVATE: no export marker.
    counted not code.contains("proc mapOver*(")
    counted not code.contains("func mapOver*(")
    # DECLARED ONCE.
    counted code.count("proc mapOver(") == 1
    # CALLED EXACTLY TWICE, AND BOTH CALLS ARE INSIDE `rebase`.
    counted code.count("mapOver(") == 3        # one declaration, two calls
    let atRebase = code.find("proc rebase*(a, b: ChangeSet): Rebased")
    counted atRebase > 0
    counted code[atRebase .. ^1].count("mapOver(") == 2
    counted code[0 ..< atRebase].count("mapOver(") == 1
    # THE FLAG IS SPELLED IN ONE SIGNATURE AND SET IN EXACTLY TWO PLACES,
    # both of them that function's two arms.
    counted code.count("before: bool") == 1
    counted code.count("before = true") == 1
    counted code.count("before = false") == 1
    counted code[atRebase .. ^1].count("before = true") == 1
    counted code[atRebase .. ^1].count("before = false") == 1

  test "no other module in the editor tree can spell the double mapping":
    # The four remaining reference call sites belong to PLAT-26, PLAT-32 and
    # PLAT-33. What stops them hand-writing their own copy is not a comment:
    # it is that the routine is unreachable from outside `change_set.nim`, and
    # this is the check that says so.
    # THE SUBJECT SET IS ITSELF ASSERTED, and this is the half a source scan
    # usually omits: the checks below are exactly as good as the list of files
    # they run over, and that list cannot be derived from `staticRead`. A
    # sixth module in this directory is caught HERE and nowhere else.
    counted EditorModules.len > 0            # the enumeration is not asleep
    counted EditorModules == @ScannedModules
    let others = {"transaction.nim": TransactionSource,
                  "rope.nim": RopeSource,
                  "text_store.nim": TextStoreSource,
                  "seq_line_store.nim": SeqLineStoreSource,
                  "selection.nim": SelectionSource,
                  "selection_ops.nim": SelectionOpsSource,
                  "wrap.nim": WrapSource,
                  "anchor.nim": AnchorSource,
                  "range_set.nim": RangeSetSource,
                  "decoration.nim": DecorationSource,
                  "inlay.nim": InlaySource,
                  "row_projection.nim": RowProjectionSource,
                  "document_version.nim": DocumentVersionSource,
                  "reconcile.nim": ReconcileSource,
                  "editor_state.nim": EditorStateSource,
                  "operations.nim": OperationsSource}.toTable
    counted others.len == 16
    counted others.len + 1 == ScannedModules.len
    for name, src in others:
      checkpoint(name)
      counted src.len > 500                  # the file was actually read
      let code = codeOnly(src)
      counted not code.contains("mapOver")
      counted not code.contains("before: bool")
      counted not code.contains("before = true")

  test "the call sites that DO exist all call the primitive by name":
    counted codeOnly(TransactionSource).contains("rebase(a.changes, b.changes)")
    counted codeOnly(ChangeSetSource).contains("rebase(total, part).bOverA")
    # THREE in-tree call sites now: `mergeTransactions` (the reference's
    # `mergeTransaction`), `changeSetOrdered` (the reference's `ChangeSet.of`)
    # and — since PLAT-26 — `changeByRange` (the reference's `state.ts:161`,
    # the second of its five hand-written double mappings). The remaining
    # three reference sites are `mapEvent` (PLAT-32), `receiveUpdates` and
    # `rebaseUpdates` (PLAT-33), features that do not exist yet, and the
    # milestone's status says so rather than this comment claiming they are
    # covered.
    counted codeOnly(SelectionOpsSource).contains("rebase(changes, newChanges)")
    counted codeOnly(TransactionSource).count("rebase(") == 1
    counted codeOnly(ChangeSetSource).count("rebase(") == 1
    counted codeOnly(SelectionOpsSource).count("rebase(") == 1
    # AND THE NEW MODULES CANNOT SPELL THE FLAG EITHER. `changeByRange` is the
    # site PLAT-25 named as the risk — *"what keeps them from hand-writing
    # their own copy when they arrive"* — so the check that it did not is here
    # rather than in PLAT-26's own suite, beside the four it was written for.
    counted not codeOnly(SelectionOpsSource).contains("before = true")
    counted not codeOnly(SelectionOpsSource).contains("before: bool")
    # A FOURTH IN-TREE CALL SITE, ADDED BY PLAT-28: an anchor mapped through a
    # REMOTE change set. §8.2 names that case explicitly, and it is the one
    # place in this campaign where the reference's `receiveUpdates` shape
    # arrives early — so the assertion is here, beside the other three, rather
    # than in PLAT-28's own suite.
    counted codeOnly(AnchorSource).contains("rebase(remote, local)")
    counted codeOnly(AnchorSource).count("rebase(") == 1
    counted not codeOnly(AnchorSource).contains("before = true")
    counted not codeOnly(AnchorSource).contains("before: bool")

# ===========================================================================
# FUZZ-1 — the document is never corrupt, checked after EVERY step
# ===========================================================================

type FuzzOutcome = object
  steps: int
  problems: seq[string]
  clusterChecks: int
  refusals: int
  refusalDocs: seq[string]

proc isContinuationByte(s: string; at: int): bool =
  ## A byte that can only occur INSIDE a UTF-8 code point. PLAT-24's store
  ## refuses an edit boundary that lands on one, and this is the independent
  ## predicate that says when it must — computed from the document's bytes
  ## here, never from the store's answer (§30).
  at >= 0 and at < s.len and (uint8(s[at]) and 0xC0'u8) == 0x80'u8

proc runFuzz(cls: ShapeClass; docs: seq[GenDoc]; r: var Rng;
             rounds, stepsPerRound: int): FuzzOutcome =
  ## A random transaction stream, with every invariant checked after EVERY
  ## step, so the reported counterexample is the shortest breaking PREFIX
  ## rather than the whole sequence.
  ##
  ## **The differential half is the point, and it is two-sided.** The same
  ## stream is applied to a plain `string` through `apply` and to PLAT-24's
  ## `TextStore` through `replaceRange`. The store RAISES on an offset inside a
  ## UTF-8 code point — which is exactly what a cluster boundary IS inside
  ## class 7's ill-formed bytes — so the invariant is not "the store agrees".
  ## It is:
  ##
  ##   * the store refuses **iff** a boundary of this edit is a continuation
  ##     byte of the document as it stands, and
  ##   * where it does not refuse, it agrees with the string byte for byte.
  ##
  ## A one-sided version of that is satisfied by a store that never refuses
  ## anything, and by one that refuses everything.
  result.problems = @[]
  result.refusalDocs = @[]
  for round in 0 ..< rounds:
    let d0 = docs[r.rand(docs.len - 1)]
    var text = d0.text
    var store = toTextStore(text)
    for step in 1 .. stepsPerRound:
      # Every second step carries the shape class under test; the others keep
      # the stream moving over whatever document the class left behind.
      let cs =
        if step mod 2 == 1 and clusterBoundaries(text).len >= GenDocMinBoundaries:
          let gd = GenDoc(id: d0.id, text: text,
                          boundaries: clusterBoundaries(text))
          genPair(gd, r, cls).a
        else:
          genSimple(text, r)
      let ranges = cs.changedRangeSeq(individual = true)
      # THE BOUNDARY INVARIANT, re-derived from a FRESH segmentation of the
      # document as it stands — not from the boundaries the generator used. A
      # position mapping that drifted by one byte would put a later edit off a
      # cluster boundary, and this is what notices.
      let bs = clusterBoundaries(text)
      var expectRefusal = false
      for rng2 in ranges:
        inc result.clusterChecks
        if rng2.fromA notin bs or rng2.toA notin bs:
          result.problems.add "step " & $step & ": edit [" & $rng2.fromA &
            ", " & $rng2.toA & ") is not cluster-aligned in " & d0.id
        if text.isContinuationByte(rng2.fromA) or
           (rng2.toA != rng2.fromA and text.isContinuationByte(rng2.toA)):
          expectRefusal = true
      let after = cs.apply(text)
      # The same edits, through PLAT-24's store, applied back to front so the
      # old-document offsets stay valid, onto a COPY so a refusal leaves the
      # committed store untouched.
      var trial = store
      var refused = ""
      try:
        for i in countdown(ranges.len - 1, 0):
          trial.replaceRange(trial.posOf(ranges[i].fromA),
                             trial.posOf(ranges[i].toA), ranges[i].inserted)
      except ValueError as e:
        refused = e.msg
      if (refused.len > 0) != expectRefusal:
        result.problems.add "step " & $step & ": store refusal=" &
          $(refused.len > 0) & " expected=" & $expectRefusal & " in " & d0.id &
          (if refused.len > 0: " (" & refused & ")" else: "")
      if refused.len > 0:
        inc result.refusals
        if d0.id notin result.refusalDocs: result.refusalDocs.add d0.id
        store = toTextStore(after)          # resync and keep fuzzing
      else:
        store = trial
        if store.text != after:
          result.problems.add "step " & $step &
            ": store and string disagree in " & d0.id
      # THE FOLD. Byte length equals the fold of every applied change set's
      # `newLength`, which is the invariant that catches a section whose two
      # lengths have drifted apart.
      if after.len != cs.newLength:
        result.problems.add "step " & $step & ": byte length " & $after.len &
          " is not the fold " & $cs.newLength
      var terminators = 0
      for ch in after:
        if ch == '\n': inc terminators
      if terminators != store.lineCount - 1:
        result.problems.add "step " & $step & ": " & $terminators &
          " terminators against " & $store.lineCount & " lines"
      text = after
      inc result.steps
      if result.problems.len > 0: return   # the shortest breaking prefix

var fuzzRefusals = 0
var fuzzRefusalDocs: seq[string] = @[]

suite "PLAT-25 — FUZZ-1: the document is never corrupt":

  for cls in ShapeClass:
    test "FUZZ-1 x " & $cls:
      var r = initRng(Seed xor 0xf0f0'u32 + uint32(ord(cls)) * 104729'u32)
      let o = runFuzz(cls, docs, r, rounds = 3, stepsPerRound = 12)
      for p in o.problems: checkpoint(p)
      counted o.problems.len == 0
      counted o.steps == 36
      counted o.clusterChecks > 0
      fuzzRefusals += o.refusals
      for id in o.refusalDocs:
        if id notin fuzzRefusalDocs: fuzzRefusalDocs.add id

suite "PLAT-25 — FUZZ-1's refusal arm, two-sided":

  test "the store's refusals happened, and only where the bytes are ill-formed":
    # An arm nothing ever takes is an arm nobody has seen work. `FUZZ-1`'s
    # refusal half is asserted per step above; this is the other half of §7b —
    # the refusal population is non-empty, and it is confined to the class the
    # corpus put ill-formed bytes in.
    echo "  FUZZ-1: " & $fuzzRefusals & " typed refusals, in " &
         $fuzzRefusalDocs.len & " document(s): " & fuzzRefusalDocs.join(", ")
    counted fuzzRefusals > 0
    counted fuzzRefusalDocs.len > 0
    for id in fuzzRefusalDocs:
      checkpoint("refusals in " & id)
      counted id.startsWith("c7-")

  test "ill-formed text is refused by the store and not by the algebra":
    # The complement of the exclusion `change_generator.corpusClusters`
    # documents: ill-formed bytes are kept out of INSERTED text so that a
    # refusal in a CJK window is impossible. Here they are inserted on
    # purpose, so the behaviour is pinned rather than merely avoided.
    let illFormed = "\xC3\x28\x80"
    let doc = "abcdef"
    let cs = changeSet(doc.len, 3, 3, illFormed)
    # The algebra is byte-transparent: it neither validates nor normalises.
    counted cs.apply(doc) == "abc" & illFormed & "def"
    counted decodeChangeSet(encodeChangeSet(cs)) == cs
    # The store refuses an edit whose boundary lands inside a code point, by
    # name, rather than silently moving it.
    var store = toTextStore("ab\x80cd")
    expect ValueError:
      store.replaceRange(store.posOf(2), store.posOf(2), "X")
    counted store.text == "ab\x80cd"
    # And it accepts the same edit one byte later, where the boundary is a
    # code-point boundary — so the refusal is about the bytes and not about
    # the store having given up on the document.
    store.replaceRange(store.posOf(3), store.posOf(3), "X")
    counted store.text == "ab\x80Xcd"

suite "PLAT-25 — the shrinker reaches a known minimum":

  test "a planted always-failing property shrinks to its known counterexample":
    # §4.5: *"The shrinker is itself tested, by a planted always-failing
    # property whose minimal counterexample is known."*
    #
    # The property: "the draw inserts fewer than two clusters in total." It
    # fails for any draw that inserts two or more, and the minimal failing
    # draw is therefore ONE edit inserting exactly TWO clusters and deleting
    # nothing. That minimum is arithmetic, not an observation of the
    # shrinker's output.
    proc insertedClusters(dr: EditDraw): int =
      for e in dr.aEdits & dr.bEdits:
        result += clusterBoundaries(e.insert).len - 1
    proc fails(dr: EditDraw): bool = insertedClusters(dr) >= 2

    var r = initRng(Seed xor 0x5151'u32)
    var shrunkOnce = 0
    for cls in [clsMultiSection, clsOverlapping, clsReplace]:
      let d = docs[r.rand(docs.len - 1)]
      var draw = genDraw(d, r, cls)
      # Make the planted property genuinely fail on a LARGE input first, or
      # the shrinker has nothing to do and the case is vacuous.
      draw.aEdits.add Edit(fromPos: d.boundaries[^1], toPos: d.boundaries[^1],
                           insert: corpusClusters(r, 6))
      checkpoint("original: " & describe(draw) & " inserts " &
                 $insertedClusters(draw) & " clusters")
      counted fails(draw)
      counted insertedClusters(draw) >= 6
      let small = shrink(draw, fails)
      checkpoint("shrunk:   " & describe(small) & " inserts " &
                 $insertedClusters(small) & " clusters")
      counted fails(small)
      # THE KNOWN MINIMUM, and it is a number rather than a shape. The
      # property's threshold is two clusters, so no failing draw can insert
      # fewer and a shrinker that reached the minimum inserts exactly two.
      # The SHAPE is not unique — two edits of one cluster each is as minimal
      # as one edit of two — so asserting a shape would be asserting one of
      # several correct answers, which is a test that fails on a better
      # shrinker.
      counted insertedClusters(small) == 2
      counted small.aEdits.len + small.bEdits.len <= 2
      # LOCALLY MINIMAL, asserted by exhausting the reductions rather than by
      # trusting the loop that produced it: every smaller candidate either is
      # invalid or stops failing.
      var smallerAndStillFailing = 0
      for cand in shrinkCandidates(small):
        if cand.isValidDraw and fails(cand): inc smallerAndStillFailing
      counted smallerAndStillFailing == 0
      inc shrunkOnce
    counted shrunkOnce == 3

  test "the shrinker terminates on a property nothing can satisfy away":
    # A property that fails for EVERY draw, including the empty one. The
    # shrinker must reach the empty draw and stop rather than loop.
    proc alwaysFails(dr: EditDraw): bool = true
    var r = initRng(Seed xor 0x6161'u32)
    let d = docs[0]
    let draw = genDraw(d, r, clsMultiSection)
    let small = shrink(draw, alwaysFails)
    counted small.aEdits.len == 0
    counted small.bEdits.len == 0
    counted small.doc == draw.doc

# ---------------------------------------------------------------------------
# The tally
# ---------------------------------------------------------------------------

suite "PLAT-25 — the tally":
  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
