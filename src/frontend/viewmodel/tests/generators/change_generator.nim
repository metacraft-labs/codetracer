## change_generator.nim — PLAT-25's change-set generator, §4.1 of
## Editor-Model-Conformance-Suite.md.
##
## NOT-A-TEST-LANE-FILE: a generator, not a suite. It imports no `unittest`
## and asserts nothing; every assertion about what it produced lives in
## `../unit/test_editor_change_algebra.nim`.
##
## =========================================================================
## THE PAIR GENERATOR IS NOT TWO INDEPENDENT DRAWS
## =========================================================================
##
## §4.1, stated twice in the campaign because it is the one thing that
## decides whether ten thousand pairs are evidence: *"Two independent draws
## over a large document are overwhelmingly disjoint, and `LAW-A1` is
## trivially true on disjoint pairs."*
##
## So `genPair` draws a **shared position budget** first — `window`, a run of
## ascending cluster boundaries taken from ONE place in ONE document — and
## then places BOTH change sets of the pair against those same boundaries.
## Every class's constructor takes its positions out of that one `seq`. There
## is no path through this file in which `a` and `b` are drawn independently.
##
## The realised class of each pair is then decided by `classifyPair`, which
## reads the two change sets and **is not the constructor**: the constructor
## says what it meant to build, the classifier says what it built, and the
## suite asserts the histogram of the second. A generator that labelled its
## own output would be a generator agreeing with itself
## (Verification-Harness-Traps §30).
##
## =========================================================================
## THE DOCUMENTS ARE THE UNICODE CORPUS, NOT ASCII
## =========================================================================
##
## §4.2 and §9: *"a fuzzer over ASCII cannot produce the cluster boundary that
## is the interesting input."* Every generated document is a cluster-aligned
## window of one of PLAT-24's eighteen corpus documents, every edit boundary
## is a grapheme-cluster boundary of that window, and every inserted string is
## a whole number of clusters taken from the corpus. The nine classes — ZWJ
## families, combining marks, regional indicators, ambiguous width, CJK, line
## terminators, ill-formed bytes, tabs and ASCII control — all reach the
## algebra through here.
##
## =========================================================================
## THE PRNG IS LOCAL, AND THAT IS NOT NOT-INVENTED-HERE
## =========================================================================
##
## `std/random` is seeded with `int64` and its state is a pair of `uint64`.
## The suite runs on the C backend AND on `nim js`, where 64-bit integers are
## emulated, and the whole value of printing a seed is that the SAME seed
## reproduces the SAME population — on the backend the failure was seen on and
## on the other one. A 32-bit xorshift is exactly representable in both, so
## the two backends draw the same pairs. That is checkable, and the suite
## checks it: a case pins the first draws of a fixed seed, and it runs on both
## lanes.

import std/strutils

import ../../editor/change_set
import ../corpus/unicode_corpus

export change_set

type
  ShapeClass* = enum
    ## §4.1's ten declared classes. The order is the declaration order and the
    ## suite runs every law against every one of them.
    clsPureInsert
    clsPureDelete
    clsReplace
    clsEmpty
    clsWholeDocument
    clsAdjacent
    clsOverlapping
    clsTouchingPoint
    clsMultiSection
    clsCollapsePoint

  Rng* = object
    ## A 32-bit xorshift. Identical on C and JS — see the header.
    state: uint32

  GenDoc* = object
    ## One generated document: a cluster-aligned window of a corpus document,
    ## with every grapheme-cluster boundary precomputed.
    id*: string
    text*: string
    boundaries*: seq[int]

  EditDraw* = object
    ## The generator's INPUT, which is what the shrinker shrinks. Change sets
    ## are derived from this; shrinking a change set directly would have to
    ## preserve invariants the constructor already knows how to preserve.
    docId*: string
    doc*: string
    boundaries*: seq[int]
    aEdits*, bEdits*: seq[Edit]
    intended*: ShapeClass

  ChangePair* = object
    draw*: EditDraw
    a*, b*: ChangeSet

const
  ShapeClassCount* = ord(high(ShapeClass)) - ord(low(ShapeClass)) + 1
    ## Derived from the enum. §10.4 rule 3: a sweep's multiplier must be an
    ## asserted cardinality, not a round number — and the floor's second
    ## multiplier is this one.

  WindowPositions* = 7
    ## How many positions a class constructor may take from one shared budget.
    ## `clsMultiSection` uses all seven; nothing uses more.

  GenDocClusters* = 24
    ## The size of the window cut out of each corpus document. Big enough that
    ## a budget of `WindowPositions` fits with gaps, small enough that a law
    ## quantified over EVERY BYTE POSITION of the document stays affordable on
    ## the JS backend as well as the C one.

  GenDocMinBoundaries* = 2 * WindowPositions + 1
    ## Every generated document must offer at least this many cluster
    ## boundaries: the window's stride is 1 or 2, so seven positions consume at
    ## most fourteen boundaries. Asserted by the suite PER DOCUMENT — a
    ## document too small to hold the shapes would make its class's draws
    ## silently degenerate, which is §4b's partial sweep wearing the right
    ## label.

# ---------------------------------------------------------------------------
# The PRNG
# ---------------------------------------------------------------------------

func initRng*(seed: uint32): Rng =
  Rng(state: if seed == 0'u32: 0x9E3779B9'u32 else: seed)

func nextU32*(r: var Rng): uint32 =
  var x = r.state
  x = x xor (x shl 13)
  x = x xor (x shr 17)
  x = x xor (x shl 5)
  r.state = x
  x

func rand*(r: var Rng; hi: int): int =
  ## `0 .. hi`, inclusive. A modulo draw: the bias at these ranges is far
  ## below anything the histogram assertions can see, and the alternative
  ## (rejection sampling) would make the two backends' sequences diverge the
  ## moment one of them rejected a different number of draws.
  if hi <= 0: 0 else: int(r.nextU32() mod uint32(hi + 1))

func pick*[T](r: var Rng; xs: openArray[T]): T =
  xs[r.rand(xs.len - 1)]

# ---------------------------------------------------------------------------
# Documents, from the corpus
# ---------------------------------------------------------------------------

proc clusterBoundaries*(s: string): seq[int] =
  ## Every grapheme-cluster boundary of `s`, ascending, including 0 and
  ## `s.len`. The segmenter is `isonim-tui`'s, the same one PLAT-24's corpus
  ## manifest is measured with — so "a cluster boundary" means one thing in
  ## this campaign.
  result = @[0]
  for c in graphemeClusters(s):
    if c.stop > result[^1]: result.add c.stop
  if result.len == 0 or result[^1] != s.len: result.add s.len

proc windowOf(text: string; bs: seq[int]; startIdx, wantClusters: int):
    (string, seq[int]) =
  ## `wantClusters` clusters of `text` starting at boundary `startIdx`, with
  ## the window's own boundaries rebased to zero. Cluster-aligned by
  ## construction: a window cut at a byte offset would be the generator
  ## producing the defect the corpus exists to catch.
  let a = bs[min(startIdx, bs.len - 1)]
  let bIdx = min(startIdx + wantClusters, bs.len - 1)
  let b = bs[bIdx]
  var sub: seq[int] = @[]
  for v in bs:
    if v >= a and v <= b: sub.add v - a
  (text[a ..< b], sub)

let CorpusBoundaries* = block:
  ## Every corpus document's cluster boundaries, segmented ONCE.
  ##
  ## Not a micro-optimisation. `corpusClusters` is called two or three times
  ## per generated pair and the gate draws ten thousand of them; segmenting a
  ## 17,000-byte document on each call put the JS lane at **5 m 55 s** for one
  ## suite. With the tables hoisted it is a fraction of that, and the figures
  ## are in PLAT-25's status with the build they were taken under (§28b).
  var t: seq[seq[int]] = @[]
  for d in CorpusDocs: t.add clusterBoundaries(d.text)
  t

let InsertableDocs* = block:
  ## The indices `corpusClusters` may draw from — see its own doc comment for
  ## why class 7 is not among them.
  var t: seq[int] = @[]
  for i in 0 ..< CorpusDocs.len:
    if not CorpusDocs[i].id.startsWith("c7-"): t.add i
  t

proc classWitness*(id, text: string; boundaries: seq[int]): bool =
  ## **Does this window still belong to the class its name claims?**
  ##
  ## A window cut at a random offset out of a 17,000-byte corpus document can
  ## easily contain none of what put that document in its class — and a
  ## `c7-illformed` window with no ill-formed byte in it is §4b's partial
  ## sweep wearing the right label: every law quantified over "class 7" runs,
  ## passes, and says nothing about ill-formed input.
  ##
  ## Measured, which is why this exists: on the first seed tried, the
  ## `c7-illformed-long` window came out **entirely ASCII** and `FUZZ-1`'s
  ## store-refusal arm consequently fired zero times across all ten classes.
  ##
  ## One predicate, used twice (§30): `genDocs` searches for a window that
  ## satisfies it, and `test_editor_change_algebra.nim` asserts every window
  ## does.
  if id.len < 2: return false
  proc hasByte(t: string; lo, hi: uint8): bool =
    for ch in t:
      let b = uint8(ch)
      if b >= lo and b <= hi: return true
    false
  case id[1]
  of '1': text.contains("\xE2\x80\x8D")          # ZERO WIDTH JOINER
  of '2', '4', '5': hasByte(text, 0x80'u8, 0xFF'u8)  # combining / ambiguous / CJK
  of '3': text.contains("\xF0\x9F\x87")           # a regional indicator lead
  of '6': text.contains("\r") or text.contains("\n")
  of '7':
    # The witness class 7 exists for: a cluster boundary that is NOT a UTF-8
    # code-point boundary, which is the input PLAT-24's store refuses.
    var found = false
    for b in boundaries:
      if b > 0 and b < text.len and (uint8(text[b]) and 0xC0'u8) == 0x80'u8:
        found = true
    found
  of '8': text.contains("\t")
  of '9':
    var found = false
    for ch in text:
      let b = uint8(ch)
      if (b < 0x20'u8 and ch notin {'\n', '\r', '\t'}) or b == 0x7F'u8:
        found = true
    found
  else: false

proc genDocs*(seed: uint32): seq[GenDoc] =
  ## One window per corpus document, eighteen in all. The window's position
  ## depends on the seed, so a second seed is a second set of real documents
  ## rather than the same eighteen again — but every window is searched
  ## forward from the drawn start until it WITNESSES ITS CLASS, and a document
  ## with no such window anywhere raises by name rather than yielding a window
  ## that is class-7 in the filename only.
  result = @[]
  var r = initRng(seed xor 0x5bf03635'u32)
  for di in 0 ..< CorpusDocs.len:
    let d = CorpusDocs[di]
    let bs = CorpusBoundaries[di]
    let want = GenDocClusters
    let maxStart = max(0, bs.len - want - 1)
    let drawn = if maxStart <= 0: 0 else: r.rand(maxStart)
    var chosen = -1
    var text = ""
    var sub: seq[int] = @[]
    for step in 0 .. maxStart:
      let start = (drawn + step) mod (maxStart + 1)
      let (t, sb) = windowOf(d.text, bs, start, want)
      if sb.len >= GenDocMinBoundaries and classWitness(d.id, t, sb):
        chosen = start
        text = t
        sub = sb
        break
    if chosen < 0:
      raise newException(ValueError,
        "change generator: no " & $want & "-cluster window of " & d.id &
        " witnesses its class — the corpus document and the class list have " &
        "parted company")
    result.add GenDoc(id: d.id, text: text, boundaries: sub)

proc corpusClusters*(r: var Rng; n: int): string =
  ## `n` whole clusters taken from a random place in a random corpus
  ## document. This is what gets INSERTED, so inserted text is real text with
  ## real cluster structure rather than `"x"`.
  ##
  ## **CLASS 7 — ill-formed input — IS EXCLUDED FROM INSERTED TEXT, AND THAT
  ## IS A DECISION RATHER THAN AN OVERSIGHT.** A cluster boundary in
  ## ill-formed bytes is not a UTF-8 code-point boundary, so inserting one
  ## would seed bare continuation bytes into every OTHER class's documents and
  ## PLAT-24's store would then refuse edits in a `c5-cjk` window for a reason
  ## that has nothing to do with CJK. Class 7 still reaches the algebra as a
  ## DOCUMENT — two of the eighteen generated windows are c7 — where its
  ## refusals are confined to it and can be asserted two-sidedly (`FUZZ-1`),
  ## and the case that inserts ill-formed text deliberately is
  ## `test_editor_change_algebra.nim`, "ill-formed text is refused by the
  ## store and not by the algebra".
  let k = InsertableDocs[r.rand(InsertableDocs.len - 1)]
  let bs = CorpusBoundaries[k]
  if bs.len < 2: return ""
  let i = r.rand(bs.len - 2)
  let j = min(i + n, bs.len - 1)
  CorpusDocs[k].text[bs[i] ..< bs[j]]

# ---------------------------------------------------------------------------
# The shared position budget
# ---------------------------------------------------------------------------

proc window*(d: GenDoc; r: var Rng; want: int): seq[int] =
  ## **THE SHARED POSITION BUDGET.** `want` ascending, DISTINCT cluster
  ## boundaries taken from one contiguous stretch of `d`, with a gap of at
  ## least one cluster between neighbours so a class that needs two positions
  ## apart can have them.
  ##
  ## Both change sets of a pair are placed against the result. This procedure
  ## is the reason the pair generator is not two independent draws, and it is
  ## the only source of positions in this file.
  let bs = d.boundaries
  # The stride below is 1 or 2, so `want` positions consume at most `2 * want`
  # boundaries. A document that cannot supply them is REFUSED rather than
  # silently narrowed: a narrowed window produces pairs of a class nobody
  # asked for, and a class that quietly became a different class is §4b's
  # partial sweep wearing the right label.
  let maxStart = bs.len - 1 - 2 * want
  if maxStart < 0:
    raise newException(ValueError,
      "change generator: document " & d.id & " offers " & $bs.len &
      " cluster boundaries, fewer than the " & $(2 * want + 1) &
      " a window of " & $want & " positions needs")
  var at = r.rand(maxStart)
  result = @[]
  for k in 0 ..< want:
    # Strictly ascending by construction — no de-duplication step, because a
    # duplicate would make two "different" positions the same one and move
    # the pair into the touching class without anything saying so.
    result.add bs[at]
    at += 1 + r.rand(1)

# ---------------------------------------------------------------------------
# The ten class constructors
# ---------------------------------------------------------------------------

proc genDraw*(d: GenDoc; r: var Rng; cls: ShapeClass): EditDraw =
  ## One pair, of the intended class, placed against ONE shared budget.
  result.docId = d.id
  result.doc = d.text
  result.boundaries = d.boundaries
  result.intended = cls
  let w = window(d, r, 7)
  template ins(n: int): string = corpusClusters(r, n)
  case cls
  of clsPureInsert:
    result.aEdits = @[Edit(fromPos: w[0], toPos: w[0], insert: ins(1 + r.rand(2)))]
    result.bEdits = @[Edit(fromPos: w[3], toPos: w[3], insert: ins(1 + r.rand(2)))]
  of clsPureDelete:
    result.aEdits = @[Edit(fromPos: w[0], toPos: w[1], insert: "")]
    result.bEdits = @[Edit(fromPos: w[3], toPos: w[4], insert: "")]
  of clsReplace:
    result.aEdits = @[Edit(fromPos: w[0], toPos: w[1], insert: ins(1 + r.rand(2)))]
    result.bEdits = @[Edit(fromPos: w[3], toPos: w[4], insert: ins(1 + r.rand(2)))]
  of clsEmpty:
    # The identity, and `LAW-A3`'s arm. Which SIDE is empty alternates, so a
    # law that only handled `id ∘ A` is not satisfied by half the class.
    if r.rand(1) == 0:
      result.aEdits = @[]
      result.bEdits = @[Edit(fromPos: w[2], toPos: w[3], insert: ins(1))]
    else:
      result.aEdits = @[Edit(fromPos: w[2], toPos: w[3], insert: ins(1))]
      result.bEdits = @[]
  of clsWholeDocument:
    result.aEdits = @[Edit(fromPos: 0, toPos: d.text.len, insert: ins(2 + r.rand(3)))]
    result.bEdits = @[Edit(fromPos: w[2], toPos: w[2], insert: ins(1))]
  of clsAdjacent:
    # Two changed sections of `a` with NO keep between them: the coalescing
    # boundary §6 makes a parameter. `b` is placed clear of both.
    result.aEdits = @[Edit(fromPos: w[0], toPos: w[1], insert: ""),
                      Edit(fromPos: w[1], toPos: w[1], insert: ins(1 + r.rand(2)))]
    result.bEdits = @[Edit(fromPos: w[4], toPos: w[4], insert: ins(1))]
  of clsOverlapping:
    # THE ONLY CLASS `LAW-A1` IS INTERESTING ON. Strict interior overlap:
    # w0 < w1 < w2 < w3 and the two replacements are [w0,w2) and [w1,w3).
    result.aEdits = @[Edit(fromPos: w[0], toPos: w[2], insert: ins(1 + r.rand(2)))]
    result.bEdits = @[Edit(fromPos: w[1], toPos: w[3], insert: ins(1 + r.rand(2)))]
  of clsTouchingPoint:
    # WHERE `before` DECIDES. Two sub-shapes, both drawn: two insertions at
    # exactly the same point (the case the flag alone resolves), and an
    # insertion exactly at the start of a deletion.
    if r.rand(1) == 0:
      result.aEdits = @[Edit(fromPos: w[2], toPos: w[2], insert: ins(1 + r.rand(1)))]
      result.bEdits = @[Edit(fromPos: w[2], toPos: w[2], insert: ins(1 + r.rand(1)))]
    else:
      result.aEdits = @[Edit(fromPos: w[2], toPos: w[2], insert: ins(1 + r.rand(1)))]
      result.bEdits = @[Edit(fromPos: w[2], toPos: w[4], insert: "")]
  of clsMultiSection:
    # More than one changed run, SEPARATED by a keep, so composition has to
    # merge rather than coalesce.
    result.aEdits = @[Edit(fromPos: w[0], toPos: w[1], insert: ins(1)),
                      Edit(fromPos: w[3], toPos: w[4], insert: ins(1))]
    result.bEdits = @[Edit(fromPos: w[6], toPos: w[6], insert: ins(1))]
  of clsCollapsePoint:
    # `LAW-A10`'s *collapsed* arm has no other source: `a` deletes a range
    # outright and `b` inserts at a point strictly INSIDE it, so `b`'s
    # position has to be mapped onto `a`'s collapse point.
    result.aEdits = @[Edit(fromPos: w[0], toPos: w[3], insert: "")]
    result.bEdits = @[Edit(fromPos: w[1], toPos: w[1], insert: ins(1 + r.rand(2)))]

proc build*(draw: EditDraw): ChangePair =
  ChangePair(draw: draw,
             a: changeSet(draw.doc.len, draw.aEdits),
             b: changeSet(draw.doc.len, draw.bEdits))

proc genPair*(d: GenDoc; r: var Rng; cls: ShapeClass): ChangePair =
  build(genDraw(d, r, cls))

proc genSimple*(text: string; r: var Rng; maxEdits = 2): ChangeSet =
  ## A change set of no declared class: one to `maxEdits` disjoint,
  ## cluster-aligned edits over arbitrary text.
  ##
  ## Two places need this and neither of them is a shape class. `LAW-A2` needs
  ## a THIRD operand over the document the first two produced, and that
  ## document has whatever cluster structure the first two left it with;
  ## `FUZZ-1` needs a stream of edits over a document that changes under it.
  ## Forcing either through a class constructor would mean asserting a shape
  ## over a document the shape was not drawn against — a label that had
  ## stopped being true.
  let bs = clusterBoundaries(text)
  if bs.len < 2: return identityChangeSet(text.len)
  var edits: seq[Edit] = @[]
  var at = 0
  for k in 0 .. r.rand(maxEdits - 1):
    if at >= bs.len - 1: break
    let f = at + r.rand(max(0, bs.len - 1 - at))
    if f >= bs.len - 1: break
    let t = f + r.rand(min(2, bs.len - 1 - f))
    let ins = if r.rand(2) == 0: "" else: corpusClusters(r, 1 + r.rand(1))
    if t == f and ins.len == 0: continue
    edits.add Edit(fromPos: bs[f], toPos: bs[t], insert: ins)
    at = t + 1
  changeSet(text.len, edits)

# ---------------------------------------------------------------------------
# The classifier — NOT the constructor
# ---------------------------------------------------------------------------

proc rangesOf(cs: ChangeSet): seq[ChangedRange] =
  cs.changedRangeSeq(individual = true)

proc hasAdjacentChanges(cs: ChangeSet): bool =
  ## Two changed sections with no keep between them — which is exactly the
  ## difference between the two `changedRanges` modes.
  cs.changedRangeSeq(individual = true).len >
    cs.changedRangeSeq(individual = false).len

proc classifyPair*(a, b: ChangeSet): ShapeClass =
  ## **Exactly one class, by a stated precedence.** A classifier that could
  ## answer two things would make the histogram an opinion.
  ##
  ## The order, and why each step is where it is:
  ##
  ##   1. `clsEmpty` and 2. `clsWholeDocument` are properties of ONE set, and
  ##      they subsume every relation — the identity relates to nothing, and a
  ##      whole-document replace overlaps everything. Deciding them first is
  ##      what stops those two classes being absorbed into `clsOverlapping`.
  ##   3. `clsCollapsePoint` before `clsOverlapping`, because a zero-width
  ##      change strictly inside a deleted range is NOT a strict overlap (its
  ##      two endpoints coincide) and would otherwise fall through to a class
  ##      that does not describe it.
  ##   4. `clsOverlapping` before 5. `clsTouchingPoint`: a pair that both
  ##      overlaps and shares an endpoint is the harder of the two.
  ##   6. `clsAdjacent` and 7. `clsMultiSection` are intra-set shapes, reached
  ##      only when the two sets do not interact.
  ##   8-10. the single-section shapes, by what their sections are.
  let ar = rangesOf(a)
  let br = rangesOf(b)
  if ar.len == 0 or br.len == 0: return clsEmpty
  if (ar.len == 1 and ar[0].fromA == 0 and ar[0].toA == a.length and a.length > 0) or
     (br.len == 1 and br[0].fromA == 0 and br[0].toA == b.length and b.length > 0):
    return clsWholeDocument
  for x in ar:
    for y in br:
      if x.fromA == x.toA and y.fromA < x.fromA and x.fromA < y.toA:
        return clsCollapsePoint
      if y.fromA == y.toA and x.fromA < y.fromA and y.fromA < x.toA:
        return clsCollapsePoint
  for x in ar:
    for y in br:
      if max(x.fromA, y.fromA) < min(x.toA, y.toA):
        return clsOverlapping
  for x in ar:
    for y in br:
      if x.fromA == y.fromA or x.fromA == y.toA or
         x.toA == y.fromA or x.toA == y.toA:
        return clsTouchingPoint
  if hasAdjacentChanges(a) or hasAdjacentChanges(b): return clsAdjacent
  if ar.len > 1 or br.len > 1: return clsMultiSection
  var allInsert = true
  var allDelete = true
  for x in ar & br:
    if x.toA > x.fromA: allInsert = false
    if x.inserted.len > 0: allDelete = false
  if allInsert: return clsPureInsert
  if allDelete: return clsPureDelete
  clsReplace

# ---------------------------------------------------------------------------
# Shrinking — §4.5
# ---------------------------------------------------------------------------

proc isValidDraw*(draw: EditDraw): bool =
  ## Exported because the shrinker's own test asserts LOCAL MINIMALITY by
  ## exhausting `shrinkCandidates` itself: a case that trusted the loop inside
  ## `shrink` would be the loop agreeing with itself (§30).
  try:
    discard changeSet(draw.doc.len, draw.aEdits)
    discard changeSet(draw.doc.len, draw.bEdits)
    true
  except ChangeSetError:
    false

proc clusterPrefix(s: string; clusters: int): string =
  ## The first `clusters` whole clusters of `s`. Shrinking an inserted string
  ## by BYTES would produce an inserted string that is half a cluster, and the
  ## shrunk counterexample would then be about a defect the shrinker created.
  let bs = clusterBoundaries(s)
  s[0 ..< bs[min(clusters, bs.len - 1)]]

proc shrinkCandidates*(draw: EditDraw): seq[EditDraw] =
  ## Smaller draws to try, roughly largest reduction first.
  result = @[]
  for side in 0 .. 1:
    let edits = if side == 0: draw.aEdits else: draw.bEdits
    # Drop an edit outright.
    for i in 0 ..< edits.len:
      var d = draw
      var e = edits
      e.delete(i)
      if side == 0: d.aEdits = e else: d.bEdits = e
      result.add d
    # Shorten an inserted string, by whole clusters.
    for i in 0 ..< edits.len:
      let cs = clusterBoundaries(edits[i].insert).len - 1
      if cs > 0:
        for target in [cs div 2, cs - 1]:
          if target >= 0 and target < cs:
            var d = draw
            var e = edits
            e[i].insert = clusterPrefix(e[i].insert, target)
            if side == 0: d.aEdits = e else: d.bEdits = e
            result.add d
    # Narrow a deleted range, to a cluster boundary.
    for i in 0 ..< edits.len:
      if edits[i].toPos > edits[i].fromPos:
        for bnd in draw.boundaries:
          if bnd > edits[i].fromPos and bnd < edits[i].toPos:
            var d = draw
            var e = edits
            e[i].toPos = bnd
            if side == 0: d.aEdits = e else: d.bEdits = e
            result.add d
            break

proc shrink*(draw: EditDraw; fails: proc (d: EditDraw): bool): EditDraw =
  ## A locally minimal failing draw: greedily accept the first smaller
  ## candidate that STILL fails, until nothing smaller does.
  ##
  ## §4.5: *"A failing property that reports a 400-transaction counterexample
  ## has found a defect nobody will fix."* The shrinker is itself tested, by a
  ## planted always-failing property whose minimal counterexample is known —
  ## `test_editor_change_algebra.nim`, "the shrinker reaches a known minimum".
  result = draw
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

proc describe*(draw: EditDraw): string =
  ## The counterexample, printed. Both the original and the shrunk one are
  ## printed by the harness, per §4.5.
  result = draw.docId & "[" & $draw.doc.len & "B] intended=" & $draw.intended
  result.add " a="
  for e in draw.aEdits:
    result.add "(" & $e.fromPos & "," & $e.toPos & ",+" & $e.insert.len & ")"
  result.add " b="
  for e in draw.bEdits:
    result.add "(" & $e.fromPos & "," & $e.toPos & ",+" & $e.insert.len & ")"
