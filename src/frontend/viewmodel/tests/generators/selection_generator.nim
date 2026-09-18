## selection_generator.nim — PLAT-26's selection generator, §4.3 of
## Editor-Model-Conformance-Suite.md.
##
## NOT-A-TEST-LANE-FILE: a generator, not a suite. It imports no `unittest` and
## asserts nothing; every assertion about what it produced lives in
## `../unit/test_editor_selection_laws.nim`.
##
## =========================================================================
## K > 1 IS THE COMMON CASE, AND THE INPUTS VIOLATE THE INVARIANT ON PURPOSE
## =========================================================================
##
## §4.3, and the milestone states the reason in one sentence: **every selection
## constructed in the tree today has K = 1**, so a generator that mirrored
## today's usage would be a generator that never reaches this milestone's
## subject. Worse, a generator that only produced *already normalised* sets
## would make normalisation trivially true — the selection analogue of §4.1's
## *"two independent draws are overwhelmingly disjoint, and the law is
## trivially true on disjoint pairs"*, and of §34, where the defect a case was
## written to detect was committed inside that very case.
##
## So the eight declared classes below are mostly VIOLATIONS: unsorted,
## touching, overlapping, nested, duplicated, and a caret sitting exactly on
## another range's edge. `selDisjoint` is the easy one and it is one of eight
## rather than the default.
##
## The realised class of each draw is decided by `classifySelection`, which
## **is not the constructor**: the constructor says what it meant to build, the
## classifier reads the ranges back and says what it built, and the suite
## asserts the per-class histogram as an EQUALITY against the per-class draw
## count — §34's rule, because *"non-emptiness is satisfied by a broken
## generator; equality is not"*.
##
## =========================================================================
## THE DOCUMENTS, THE PRNG AND THE WINDOWS ARE PLAT-25's — DELIBERATELY
## =========================================================================
##
## `change_generator` already draws cluster-aligned windows of PLAT-24's
## eighteen corpus documents with a 32-bit xorshift that is exact on the C and
## the JS backend alike. A second copy of any of that would be a second thing
## to keep in step (Verification-Harness-Traps §30), and worse, a second seed
## whose population is not the one the algebra was measured over. This file
## imports them and adds exactly two things: a position budget sized for K
## ranges, and the eight class constructors.
##
## `genAlternatingDoc` is the one new DOCUMENT shape, and it is a synthetic
## document built out of CORPUS clusters rather than ASCII — §4.2's *"synthetic
## documents never replace the corpus for anything width- or cluster-related"*.
## `LAW-S5` is about a tab-expanded DISPLAY column, so a goal column that is
## right on ASCII and wrong on a wide glyph is precisely the defect the type
## was chosen to prevent, and an ASCII ladder of long and short lines would not
## see it.

import std/[algorithm, strutils]

import ../../editor/selection
import ../corpus/unicode_corpus
import ./change_generator

export change_generator, selection

type
  SelClass* = enum
    ## §4.3's declared classes. Six of the eight are inputs that VIOLATE the
    ## invariant `editorSelection` establishes, because normalisation is only
    ## tested by inputs that violate it.
    ## **WHICH OF THESE NORMALISATION ACTUALLY CHANGES MOVED WITH THE MERGE
    ## RULE.** Under the merge-on-touch rule this port briefly had, a chain of
    ## abutting NON-EMPTY ranges collapsed; under the rule now in
    ## `selection.nim`, it does not, so `selTouching` is the class that asserts
    ## the merge does NOT happen and `selCaretOnEdge` is the one that asserts
    ## it does. That is why the §10.1 violation sweep gained `selCaretOnEdge`
    ## as a fifth class: without it the sweep would have pinned the rule in one
    ## direction only.
    selDisjoint      ## sorted, with a gap — nothing to merge
    selUnsorted      ## the same ranges, presented out of order — reorders, never merges
    selTouching      ## `from == prev.to`, both NON-EMPTY — stays as it is
    selOverlapping   ## strict partial overlap — merges
    selNested        ## one range strictly inside another — merges
    selDuplicated    ## the same range more than once — merges
    selCarets        ## every range empty, at distinct boundaries — nothing to merge
    selCaretOnEdge   ## a caret exactly on a non-empty range's boundary — merges,
                     ## and it is the only drawn class in which a TOUCHING pair
                     ## does, which is what `LAW-S1`'s killer needs to see

  SelDraw* = object
    ## The generator's INPUT, which is what the shrinker shrinks.
    docId*, doc*: string
    boundaries*: seq[int]
    ranges*: seq[SelectionRange]   ## UN-NORMALISED, on purpose
    primary*: int
    k*: int
    intended*: SelClass

const
  SelClassCount* = ord(high(SelClass)) - ord(low(SelClass)) + 1
    ## Derived from the enum — §10.4 rule 3. It is a multiplier of the
    ## histogram case and of nothing else; the floor's multipliers are the law
    ## count, the K count and the operation count.

  KValues* = [1, 2, 3, 7]
    ## §4.3: *"Each law runs at K in {1, 2, 3, 7}. K = 1 is kept deliberately
    ## as the arm that must NOT discriminate: a single-range implementation
    ## passes it, which is what makes the K > 1 rows evidence rather than
    ## decoration."*
    ##
    ## 7 rather than 5 because the shapes that only appear at larger K — a
    ## nested range with several siblings, a touching CHAIN rather than a
    ## touching pair — are the ones a merge loop written for two ranges gets
    ## wrong.

  KCount* = KValues.len

# ---------------------------------------------------------------------------
# The position budget
# ---------------------------------------------------------------------------

proc selWindow*(d: GenDoc; r: var Rng; want: int): seq[int] =
  ## `want` STRICTLY ASCENDING, DISTINCT cluster boundaries of `d`, contiguous
  ## from a drawn start.
  ##
  ## Contiguous rather than gapped — which is the opposite of
  ## `change_generator.window` and is deliberate. That budget needs gaps
  ## because its classes place two change sets *apart*; this one needs
  ## DENSITY, because the interesting selections are the ones whose ranges
  ## meet. A document that cannot supply `want` boundaries is refused by name
  ## rather than silently narrowed: a narrowed budget produces duplicate
  ## endpoints, and a draw that quietly became `selDuplicated` when
  ## `selOverlapping` was asked for is §4b's partial sweep wearing the right
  ## label.
  let bs = d.boundaries
  if bs.len < want:
    raise newException(ValueError,
      "selection generator: document " & d.id & " offers " & $bs.len &
      " cluster boundaries, fewer than the " & $want & " a K-range budget needs")
  let at = r.rand(bs.len - want)
  result = newSeqOfCap[int](want)
  for i in 0 ..< want: result.add bs[at + i]

func budgetFor*(k: int): int =
  ## How many boundaries a draw of `k` ranges needs. `selNested` spans the
  ## whole budget and puts `k - 1` disjoint ranges inside it, which is the
  ## widest of the eight.
  2 * k + 1

# ---------------------------------------------------------------------------
# The eight class constructors
# ---------------------------------------------------------------------------

proc genSelDraw*(d: GenDoc; r: var Rng; cls: SelClass; k: int): SelDraw =
  ## One un-normalised range set of the intended class, placed against ONE
  ## budget.
  ##
  ## **K = 1 DEGENERATES AND SAYS SO.** Six of the eight classes are relations
  ## between two ranges and have no K = 1 form; the draw then yields the single
  ## range the class is built out of, and `classifySelection` will report
  ## `selDisjoint` or `selCarets` for it. That is not a defect to paper over —
  ## it is why the histogram is asserted at K > 1 and the laws are run at every
  ## K including 1.
  result.docId = d.id
  result.doc = d.text
  result.boundaries = d.boundaries
  result.intended = cls
  result.k = k
  let p = selWindow(d, r, budgetFor(k))
  var rs: seq[SelectionRange] = @[]
  case cls
  of selDisjoint:
    for i in 0 ..< k: rs.add spanRange(p[2 * i], p[2 * i + 1])
  of selUnsorted:
    for i in 0 ..< k: rs.add spanRange(p[2 * i], p[2 * i + 1])
    reverse(rs)
  of selTouching:
    # A CHAIN, not a pair: range i ends exactly where range i + 1 begins.
    for i in 0 ..< k: rs.add spanRange(p[i], p[i + 1])
  of selOverlapping:
    for i in 0 ..< k: rs.add spanRange(p[i], p[i + 2])
  of selNested:
    rs.add spanRange(p[0], p[2 * k])
    for i in 1 ..< k: rs.add spanRange(p[2 * i - 1], p[2 * i])
  of selDuplicated:
    let distinct1 = max(1, (k + 1) div 2)
    for i in 0 ..< k:
      let j = i mod distinct1
      rs.add spanRange(p[2 * j], p[2 * j + 1])
  of selCarets:
    for i in 0 ..< k: rs.add caret(p[2 * i],
                                   (if r.rand(1) == 0: assocBefore else: assocAfter))
  of selCaretOnEdge:
    rs.add spanRange(p[0], p[1])
    if k > 1: rs.add caret(p[1], assocBefore)
    if k > 2: rs.add caret(p[0], assocAfter)
    for i in 3 ..< k: rs.add caret(p[2 * i - 2])
  result.ranges = rs
  result.primary = r.rand(rs.len - 1)

# ---------------------------------------------------------------------------
# The classifier — NOT the constructor
# ---------------------------------------------------------------------------

proc classifySelection*(rs: seq[SelectionRange]): SelClass =
  ## **Exactly one class, by a stated precedence.** A classifier that could
  ## answer two things would make the histogram an opinion.
  ##
  ## The order, and why each step is where it is:
  ##
  ##   1. `selDuplicated` first, because a duplicate is also nested, also
  ##      overlapping and also touching — every later test would claim it.
  ##   2. `selNested` before `selOverlapping`: containment is the harder shape
  ##      and a contained pair also satisfies the partial-overlap predicate.
  ##   3. `selCaretOnEdge` before `selTouching`, because a caret on an edge
  ##      satisfies the touching predicate too and is a different input: a
  ##      merge rule written for two extents and not for a point is what it
  ##      exists to catch.
  ##   4. `selCarets` before `selUnsorted` and `selDisjoint`, which are the
  ##      two shapes with no relation between any pair.
  for i in 0 ..< rs.len:
    for j in i + 1 ..< rs.len:
      if rs[i].rangeFrom == rs[j].rangeFrom and rs[i].rangeTo == rs[j].rangeTo:
        return selDuplicated
  for i in 0 ..< rs.len:
    for j in 0 ..< rs.len:
      if i == j: continue
      if not rs[j].isEmpty and
         rs[i].rangeFrom <= rs[j].rangeFrom and rs[j].rangeTo <= rs[i].rangeTo:
        return selNested
  for i in 0 ..< rs.len:
    for j in i + 1 ..< rs.len:
      if max(rs[i].rangeFrom, rs[j].rangeFrom) <
         min(rs[i].rangeTo, rs[j].rangeTo):
        return selOverlapping
  for i in 0 ..< rs.len:
    for j in 0 ..< rs.len:
      if i == j: continue
      if rs[i].isEmpty and not rs[j].isEmpty and
         (rs[i].pos == rs[j].rangeFrom or rs[i].pos == rs[j].rangeTo):
        return selCaretOnEdge
  for i in 0 ..< rs.len:
    for j in i + 1 ..< rs.len:
      if not rs[i].isEmpty and not rs[j].isEmpty and
         (rs[i].rangeTo == rs[j].rangeFrom or rs[j].rangeTo == rs[i].rangeFrom):
        return selTouching
  var allEmpty = true
  for x in rs:
    if not x.isEmpty: allEmpty = false
  if allEmpty: return selCarets
  for i in 1 ..< rs.len:
    if rs[i].rangeFrom < rs[i - 1].rangeFrom: return selUnsorted
  selDisjoint

# ---------------------------------------------------------------------------
# Documents of alternating line length — `LAW-S5`'s population
# ---------------------------------------------------------------------------

proc corpusLine*(r: var Rng; clsIdx, clusters: int): string =
  ## `clusters` whole grapheme clusters taken from one of the two corpus
  ## documents of class `clsIdx`, with line terminators removed so the caller
  ## decides where the lines are.
  ##
  ## Terminators are stripped rather than avoided: class 6 IS the line
  ## terminator class, and a "line" that contained a `\n` would be two lines
  ## and would make every claim about "the line below" a claim about a
  ## different line.
  var docs: seq[string] = @[]
  for d in docsOfClass(clsIdx): docs.add d.text
  if docs.len == 0: return ""
  let text = docs[r.rand(docs.len - 1)]
  let bs = clusterBoundaries(text)
  if bs.len < 2: return ""
  let i = r.rand(bs.len - 2)
  let j = min(i + clusters, bs.len - 1)
  result = text[bs[i] ..< bs[j]]
  result = result.replace("\n", "").replace("\r", "")

proc genAlternatingDoc*(r: var Rng; clsIdx, lines, longClusters,
                        shortClusters: int): string =
  ## A document of `lines` lines whose lengths ALTERNATE long, short, long,
  ## short — **the shape the goal column exists for**. Vertical motion through
  ## it is the property `LAW-S5` states: without a carried goal, the column
  ## collapses to the short line's width on the first step down and never comes
  ## back.
  ##
  ## Built out of corpus clusters of the named class, never ASCII.
  var ls: seq[string] = @[]
  for i in 0 ..< lines:
    let want = if i mod 2 == 0: longClusters else: shortClusters
    var line = corpusLine(r, clsIdx, want)
    if line.len == 0: line = "."
    ls.add line
  ls.join("\n")

# ---------------------------------------------------------------------------
# Shrinking — §4.5
# ---------------------------------------------------------------------------

proc isValidDraw*(d: SelDraw): bool =
  ## Exported because the shrinker's own test asserts LOCAL MINIMALITY by
  ## exhausting `shrinkCandidates` itself.
  if d.ranges.len == 0: return false
  if d.primary < 0 or d.primary >= d.ranges.len: return false
  for x in d.ranges:
    if x.rangeFrom < 0 or x.rangeTo > d.doc.len: return false
  true

proc shrinkCandidates*(d: SelDraw): seq[SelDraw] =
  ## Smaller draws to try, roughly largest reduction first.
  result = @[]
  for i in 0 ..< d.ranges.len:
    if d.ranges.len > 1:
      var c = d
      c.ranges.delete(i)
      # **A CLAMP, AND A DELIBERATELY BENIGN ONE — named because §36a's rule is
      # that a silent index repair must either RAISE or be a behaviour with a
      # name.** Deleting a range can leave `primary` past the end. It is put
      # back on the last range rather than followed to the range it was, and
      # that is correct HERE and would not be in `editorSelection`: a shrink
      # candidate's whole contract is `isValidDraw` — non-empty, primary in
      # range, ranges inside the document — and WHICH range is primary is not
      # part of it. The shrinker proposes; `shrink` keeps only candidates that
      # still fail the property. There is no right answer being masked, which
      # is the exact thing that was not true of the clamp §36a is about.
      if c.primary >= c.ranges.len: c.primary = c.ranges.len - 1
      c.k = c.ranges.len
      result.add c
  for i in 0 ..< d.ranges.len:
    let x = d.ranges[i]
    if not x.isEmpty:
      # Narrow a range to a cluster boundary strictly inside it, so a shrunk
      # counterexample is still cluster-aligned. Shrinking by BYTES would make
      # the shrunk input carry a defect the shrinker created.
      for bnd in d.boundaries:
        if bnd > x.rangeFrom and bnd < x.rangeTo:
          var c = d
          c.ranges[i] = spanRange(x.rangeFrom, bnd)
          result.add c
          break
      var c = d
      c.ranges[i] = caret(x.rangeFrom)
      result.add c

proc shrink*(d: SelDraw; fails: proc (x: SelDraw): bool): SelDraw =
  ## A locally minimal failing draw. §4.5: *"A failing property that reports a
  ## 400-transaction counterexample has found a defect nobody will fix."*
  result = d
  var progress = true
  var guard = 0
  while progress and guard < 500:
    inc guard
    progress = false
    for cand in shrinkCandidates(result):
      if cand.isValidDraw and fails(cand):
        result = cand
        progress = true
        break

proc describe*(d: SelDraw): string =
  result = d.docId & "[" & $d.doc.len & "B] intended=" & $d.intended &
    " K=" & $d.k & " primary=" & $d.primary & " "
  for x in d.ranges: result.add $x & " "
