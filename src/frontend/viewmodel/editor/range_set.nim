## range_set.nim — PLAT-28: the ONE range vocabulary, built before the
## decorations that use it.
##
## Owns: Editor-ViewModel.md §8.0. *"Underneath CodeMirror's decorations is a
## single generic structure: a set of ranges carrying values, where each value
## declares which side it binds to at each end, how its position maps when the
## document changes, and whether it is a point or a mark."*
##
## §8.0's own instruction is the reason this file exists at all and is dated
## before `decoration.nim`: **build it before building decorations**, because
## the gutter marks, the execution pointer, the breakpoints, the flow states,
## the inline values and the remote collaborators' carets are all instances of
## it, and building them separately is how a tree ends up with the
## two-copies-of-one-predicate defect
## `common/view_vocabulary/editor_rows.nim` was written to stop.
##
## =========================================================================
## THE TWO OPERATIONS THAT MAKE AN EDITOR CHEAP RATHER THAN MERELY CORRECT
## =========================================================================
##
## §8.0 names exactly two, and both are here with their unoptimised twin beside
## them, because *"the fast path equals the slow path"* is the only form in
## which either claim is checkable:
##
##   * `mapRangeSet` — map a whole set through a change set, **skipping any
##     chunk the change does not touch**, so a keystroke on line 4,000 does not
##     walk the breakpoints on line 1. `mapRangeSetWalked` is the same answer
##     with the skip disabled, and `LAW-D3` is their equality.
##   * `compareOver` — compare two sets over a span, **skipping subtrees that
##     are identical by identity**, which is how a front-end learns the minimal
##     region it must redraw. `differencesWalked` is the elementwise answer and
##     `LAW-D4` is the soundness of the span against it.
##
## =========================================================================
## WHAT "SKIPPING A CHUNK" MEANS, EXACTLY, AND WHY THE PREDICATE IS CLOSED
## =========================================================================
##
## A chunk is skippable when **every** changed range of the change set ends
## strictly before the chunk's first position or begins strictly after its
## last. Then every position in the chunk moves by the SAME constant, which is
## one `mapPos` call for the whole chunk instead of two per value.
##
## The two strict inequalities are load-bearing and are not tidiness. A
## zero-width insertion exactly AT the chunk's first position has
## `fromA == toA == minPos`; it is the one shape where `sideBefore` and
## `sideAfter` give different answers, so the chunk's positions do NOT move
## uniformly and the chunk must be walked. `toA < minPos` excludes it;
## `toA <= minPos` would not, and the value sitting at `minPos` with
## `sideAfter` would keep a stale position the walked path moves. That is
## `LAW-D3`'s published killer — *"widen the skip predicate by one chunk"* —
## at its narrowest.
##
## =========================================================================
## THE DIGEST IS CONTENT, NOT A POINTER, AND THE COMPARISON IS TWO-SIDED
## =========================================================================
##
## CodeMirror skips a subtree when the two sides are `===` — the same object.
## Nim's `seq` is a value, so there is no pointer to compare; a chunk therefore
## carries an FNV-1a digest of its values, computed once at construction, and
## two chunks with equal digests are treated as identical.
##
## **A digest is a hash and a hash can collide**, so `compareOver` is NOT
## trusted on its own: `LAW-D4` asserts the reported span against an
## elementwise walk that never looks at a digest, over a generated population
## in which both the equal and the differing classes are asserted non-empty.
## A comparison that returned an empty span always would agree with itself and
## with nothing else (§4), which is the law's published killer.

import std/options

import ./anchor
import ./change_set

export anchor, options

type
  RangeMapMode* = enum
    ## §8.0's *"how its position maps when the document changes"*. Two modes,
    ## named for what they DO rather than for a truth value: `rmDropWhenTouched`
    ## as a `bool` field called `inclusive` is the shape where a reader has to
    ## remember which way round it goes.
    rmTrack
      ## Both endpoints map; the value survives whatever became of its text,
      ## with the fate reported. A breakpoint, a remote caret.
    rmDropWhenTouched
      ## The value is REMOVED when the change touches the text it spans. An
      ## atomic range, a syntax-derived mark — something whose meaning does not
      ## survive its text being edited.

  RangePointness* = enum
    ## §8.0's *"whether it is a point (meaningful on its own, and atomic when
    ## non-empty) or a mark (styling applied to a span)"*.
    rpMark
    rpPoint

  RangeValue* = object
    ## One member of the set. **The side is declared at EACH END**, which is
    ## what makes an insert exactly at a range's boundary a decision rather
    ## than an accident: a mark that should grow when you type at its start
    ## and one that should not are the same shape with two different
    ## `fromAnchor.side` values.
    id*: int
    fromAnchor*, toAnchor*: Anchor
    mode*: RangeMapMode
    pointness*: RangePointness

  RangeChunk* = object
    ## A run of values, ordered, with the bounds and the digest the two
    ## optimisations read. The bounds are DERIVED from the values rather than
    ## maintained beside them — §36a's third rule, bookkeeping with no
    ## arithmetic to get wrong.
    values*: seq[RangeValue]
    minPos*, maxPos*: int
    digest*: uint64

  RangeSet* = object
    chunks*: seq[RangeChunk]
    chunkSize*: int

  MapStats* = object
    ## What the optimisation actually did. Reported so a law can assert the
    ## fast path was TAKEN: a skip count of zero makes `LAW-D3` an equality
    ## between the walked path and itself (§4).
    chunksSkipped*, chunksWalked*, valuesWalked*, valuesDropped*: int

  CompareStats* = object
    chunksSkipped*, chunksCompared*: int

  RangeSetError* = object of ValueError

const
  DefaultChunkSize* = 8
    ## Small deliberately. The optimisation is only observable when a document
    ## holds more chunks than a change touches, and a chunk size large enough
    ## to swallow a whole generated document would make every law here a law
    ## about one chunk — §4b's partial population, in a constant.

func fnv1aStep(acc: uint64; v: int): uint64 =
  ## The corpus's fingerprint function, one integer at a time. Spelled here
  ## rather than imported from the corpus loader because that module is a TEST
  ## fixture and this is the model; what matters for §30 is that neither side
  ## of `LAW-D4` computes a digest, and the elementwise oracle does not.
  ##
  ## **EVERY INPUT IS NON-NEGATIVE BY CONSTRUCTION** — positions come through
  ## `anchorAt`, which refuses a negative, `ord` of an enum is non-negative,
  ## and `rangeValue` refuses a negative id. So the `uint64` conversion is
  ## total here without a repair, and the JS backend's emulated 64-bit
  ## arithmetic sees the same bytes the C backend does.
  var h = acc
  var x = uint64(v)
  for _ in 0 ..< 8:
    h = h xor (x and 0xFF'u64)
    h = h * 0x100000001b3'u64
    x = x shr 8
  h

func digestOf*(values: openArray[RangeValue]): uint64 =
  result = 0xcbf29ce484222325'u64
  for v in values:
    result = fnv1aStep(result, v.id)
    result = fnv1aStep(result, v.fromAnchor.pos)
    result = fnv1aStep(result, v.toAnchor.pos)
    result = fnv1aStep(result, ord(v.fromAnchor.side))
    result = fnv1aStep(result, ord(v.toAnchor.side))
    result = fnv1aStep(result, ord(v.mode))
    result = fnv1aStep(result, ord(v.pointness))

func rangeValue*(id, fromPos, toPos: int; fromSide = sideBefore;
                 toSide = sideAfter; mode = rmTrack;
                 pointness = rpMark;
                 surface = asDecorationRange): RangeValue =
  ## The only constructor, and it REFUSES an inverted range rather than
  ## swapping the ends (§36a). A range whose end precedes its start is a defect
  ## in whatever computed it, and silently reversing it makes every later
  ## answer plausible.
  if toPos < fromPos:
    raise newException(RangeSetError,
      "rangeValue: [" & $fromPos & ", " & $toPos & ") is inverted. The ends " &
      "are not swapped for you: a reversed range is a defect in the caller, " &
      "and repairing it here would hide it for as long as it stayed wrong.")
  if id < 0:
    raise newException(RangeSetError,
      "rangeValue: a negative id (" & $id & "). Ids index nothing and are " &
      "hashed into the chunk digest, which is defined over non-negative " &
      "inputs; refused rather than normalised.")
  RangeValue(id: id,
             fromAnchor: anchorAt(fromPos, fromSide, surface, id),
             toAnchor: anchorAt(toPos, toSide, surface, id),
             mode: mode, pointness: pointness)

func isEmptyRange*(v: RangeValue): bool = v.fromAnchor.pos == v.toAnchor.pos

func isAtomic*(v: RangeValue): bool =
  ## §8.0's *"a point … is atomic when non-empty"*. A property of the value
  ## rather than a separate flag, so the two cannot disagree.
  v.pointness == rpPoint and not v.isEmptyRange

func `==`*(a, b: RangeValue): bool =
  a.id == b.id and a.fromAnchor == b.fromAnchor and
    a.toAnchor == b.toAnchor and a.mode == b.mode and
    a.pointness == b.pointness

func `$`*(v: RangeValue): string =
  "range#" & $v.id & "[" & $v.fromAnchor.pos & "," & $v.toAnchor.pos & ")" &
    (if v.pointness == rpPoint: "point" else: "mark")

func sortedByPosition(values: seq[RangeValue]): seq[RangeValue] =
  ## Insertion sort on `(fromPos, toPos, id)`. Written out rather than taken
  ## from `std/algorithm` so the module has no import that a JS lane has to
  ## think about, and because the sets here are small by construction — the
  ## chunking is what makes the operations cheap, not the sort.
  result = @[]
  for v in values:
    var i = result.len
    while i > 0 and (result[i - 1].fromAnchor.pos > v.fromAnchor.pos or
                     (result[i - 1].fromAnchor.pos == v.fromAnchor.pos and
                      (result[i - 1].toAnchor.pos > v.toAnchor.pos or
                       (result[i - 1].toAnchor.pos == v.toAnchor.pos and
                        result[i - 1].id > v.id)))):
      dec i
    result.insert(v, i)

func chunkOf(values: seq[RangeValue]): RangeChunk =
  result.values = values
  result.minPos = high(int)
  result.maxPos = low(int)
  for v in values:
    if v.fromAnchor.pos < result.minPos: result.minPos = v.fromAnchor.pos
    if v.toAnchor.pos > result.maxPos: result.maxPos = v.toAnchor.pos
  result.digest = digestOf(values)

func rangeSet*(values: openArray[RangeValue];
               chunkSize = DefaultChunkSize): RangeSet =
  ## Sorted, then cut into chunks of at most `chunkSize`. The order is part of
  ## the value: two sets built from the same values in two orders are the same
  ## set, which is what makes `compareOver`'s digest comparison mean
  ## *"the same ranges"* rather than *"built by the same caller"*.
  if chunkSize <= 0:
    raise newException(RangeSetError,
      "rangeSet: a chunk size of " & $chunkSize & " would put every value in " &
      "one chunk or in none. It is not repaired to a default: the skip " &
      "optimisation is measured against this number and a silent substitution " &
      "would make the measurement about a different set.")
  result.chunkSize = chunkSize
  result.chunks = @[]
  let ordered = sortedByPosition(@values)
  var i = 0
  while i < ordered.len:
    let stop = min(i + chunkSize, ordered.len)
    result.chunks.add chunkOf(ordered[i ..< stop])
    i = stop

func allValues*(rs: RangeSet): seq[RangeValue] =
  result = @[]
  for c in rs.chunks:
    for v in c.values: result.add v

func len*(rs: RangeSet): int =
  for c in rs.chunks: result += c.values.len

func `==`*(a, b: RangeSet): bool =
  ## Equality as VALUES, over the flattened order. The chunking is an internal
  ## arrangement and two sets that hold the same ranges are equal even when one
  ## was built at a different chunk size — otherwise `LAW-D3` would be
  ## comparing the optimisation's bookkeeping instead of its answer.
  let av = a.allValues()
  let bv = b.allValues()
  if av.len != bv.len: return false
  for i in 0 ..< av.len:
    if av[i] != bv[i]: return false
  true

# ===========================================================================
# MAPPING — §8.0's first operation
# ===========================================================================

func touchesChunk(ranges: seq[ChangedRange]; minPos, maxPos: int): bool =
  ## **THE SKIP PREDICATE, AND IT IS THE WHOLE OF `LAW-D3`'s SUBJECT.** See the
  ## header for why both inequalities are strict.
  for r in ranges:
    if not (r.toA < minPos or r.fromA > maxPos): return true
  false

proc mapValue(v: RangeValue; cs: ChangeSet): Option[RangeValue] =
  ## One value, both ends, through `change_set.mapPos`. `rmDropWhenTouched` is
  ## the only place a value can leave the set, and it leaves when EITHER end
  ## failed to survive — not when the mapped range happens to be empty, which
  ## is a different and much commoner thing.
  let a = v.fromAnchor.mapAnchor(cs)
  let b = v.toAnchor.mapAnchor(cs)
  if v.mode == rmDropWhenTouched and
     (a.fate != mapSurvived or b.fate != mapSurvived):
    return none(RangeValue)
  let lo = a.landingOf
  let hi = b.landingOf
  var moved = v
  moved.fromAnchor.pos = min(lo, hi)
  moved.toAnchor.pos = max(lo, hi)
  some(moved)

proc mapChunkWalked(c: RangeChunk; cs: ChangeSet;
                    st: var MapStats): seq[RangeValue] =
  result = @[]
  for v in c.values:
    inc st.valuesWalked
    let m = mapValue(v, cs)
    if m.isSome: result.add m.get
    else: inc st.valuesDropped

proc mapRangeSet*(rs: RangeSet; cs: ChangeSet;
                  st: var MapStats): RangeSet =
  ## **THE CHUNK-SKIPPING MAPPING.** `LAW-D3` is this against
  ## `mapRangeSetWalked` below, and `st.chunksSkipped` is what makes that law a
  ## statement rather than a tautology: a population in which nothing is ever
  ## skipped compares the walked path with itself.
  let touched = cs.changedRangeSeq()
  var mapped: seq[RangeValue] = @[]
  # INDEXED, and not `for c in rs.chunks`, so `LAW-D3`'s published killer —
  # *"widen the skip predicate by ONE CHUNK"* — has a spelling. A mutation
  # that can only be written as a different predicate on the same chunk is a
  # narrower mutation than the one the law names.
  for ci in 0 ..< rs.chunks.len:
    let c = rs.chunks[ci]
    if c.values.len == 0: continue
    if not touchesChunk(touched, c.minPos, c.maxPos):
      # ONE `mapPos` FOR THE WHOLE CHUNK. Every position in it moves by the
      # same constant, which is exactly what the predicate above established.
      inc st.chunksSkipped
      # THE ONE `mapPos` CALL, AND ITS ARM IS CHECKED RATHER THAN ASSUMED.
      # The predicate above established that no changed range reaches
      # `minPos`, so it sits in a kept run and the answer is `mapSurvived`.
      # `-d:nimOldCaseObjects` is on in this repo (`config.nims`), so reading
      # the wrong arm of a variant is NOT checked by the compiler — it would
      # read whatever the object happened to hold. A `raise` here is the
      # difference between an invariant and a comment (§36a).
      let m = cs.mapPos(c.minPos, sideBefore)
      if m.kind != mapSurvived:
        raise newException(RangeSetError,
          "mapRangeSet: chunk at " & $c.minPos & " was judged untouched and " &
          "its first position did not survive (" & $m & "). The skip " &
          "predicate and `mapPos` disagree; this is unreachable by " &
          "construction and is raised rather than repaired.")
      let delta = m.pos - c.minPos
      for v in c.values:
        var moved = v
        moved.fromAnchor.pos = v.fromAnchor.pos + delta
        moved.toAnchor.pos = v.toAnchor.pos + delta
        mapped.add moved
    else:
      inc st.chunksWalked
      for v in mapChunkWalked(c, cs, st): mapped.add v
  rangeSet(mapped, rs.chunkSize)

proc mapRangeSetWalked*(rs: RangeSet; cs: ChangeSet;
                        st: var MapStats): RangeSet =
  ## The same answer with the optimisation off: every value's two ends mapped.
  ## `LAW-D3`'s control, and it is a SECOND ROUTE to the answer rather than the
  ## same routine with a flag — a flag would be one function agreeing with
  ## itself under two arguments (§30).
  var mapped: seq[RangeValue] = @[]
  for c in rs.chunks:
    inc st.chunksWalked
    for v in mapChunkWalked(c, cs, st): mapped.add v
  rangeSet(mapped, rs.chunkSize)

# ===========================================================================
# COMPARISON — §8.0's second operation
# ===========================================================================

func addPos(xs: var seq[int]; p: int) =
  for q in xs:
    if q == p: return
  xs.add p

func differencesWalked*(a, b: RangeSet): seq[int] =
  ## **THE ELEMENTWISE ORACLE.** Every position at which the two sets differ,
  ## computed without looking at a single digest and without any notion of a
  ## chunk. `LAW-D4` asserts the reported span against this.
  ##
  ## A value present on one side only contributes both of its endpoints; a
  ## value present on both with different endpoints contributes all four.
  result = @[]
  let av = a.allValues()
  let bv = b.allValues()
  var i = 0
  var j = 0
  while i < av.len or j < bv.len:
    if i >= av.len:
      result.addPos bv[j].fromAnchor.pos
      result.addPos bv[j].toAnchor.pos
      inc j
    elif j >= bv.len:
      result.addPos av[i].fromAnchor.pos
      result.addPos av[i].toAnchor.pos
      inc i
    elif av[i] == bv[j]:
      inc i
      inc j
    elif av[i].id == bv[j].id:
      result.addPos av[i].fromAnchor.pos
      result.addPos av[i].toAnchor.pos
      result.addPos bv[j].fromAnchor.pos
      result.addPos bv[j].toAnchor.pos
      inc i
      inc j
    elif av[i].fromAnchor.pos <= bv[j].fromAnchor.pos:
      result.addPos av[i].fromAnchor.pos
      result.addPos av[i].toAnchor.pos
      inc i
    else:
      result.addPos bv[j].fromAnchor.pos
      result.addPos bv[j].toAnchor.pos
      inc j

proc compareOver*(a, b: RangeSet; fromPos, toPos: int;
                  st: var CompareStats): Option[(int, int)] =
  ## **THE MINIMAL REGION A FRONT-END MUST REDRAW**, restricted to
  ## `[fromPos, toPos]`, with identical chunks skipped by digest.
  ##
  ## `none` means *"nothing in this span changed"* and it is a claim, not a
  ## default: `LAW-D4` is two-sided, so a comparison that answered `none`
  ## whenever it was unsure would fail on every differing pair rather than
  ## agreeing with everything (§4's widen-vs-narrow).
  if toPos < fromPos:
    raise newException(RangeSetError,
      "compareOver: the span [" & $fromPos & ", " & $toPos & "] is inverted.")
  var lo = high(int)
  var hi = low(int)
  let n = max(a.chunks.len, b.chunks.len)
  for k in 0 ..< n:
    let ac = if k < a.chunks.len: a.chunks[k] else: RangeChunk(digest: 0)
    let bc = if k < b.chunks.len: b.chunks[k] else: RangeChunk(digest: 0)
    if k < a.chunks.len and k < b.chunks.len and ac.digest == bc.digest:
      inc st.chunksSkipped
      continue
    inc st.chunksCompared
    for v in ac.values:
      if v.toAnchor.pos < fromPos or v.fromAnchor.pos > toPos: continue
      lo = min(lo, max(v.fromAnchor.pos, fromPos))
      hi = max(hi, min(v.toAnchor.pos, toPos))
    for v in bc.values:
      if v.toAnchor.pos < fromPos or v.fromAnchor.pos > toPos: continue
      lo = min(lo, max(v.fromAnchor.pos, fromPos))
      hi = max(hi, min(v.toAnchor.pos, toPos))
  if lo > hi: none((int, int)) else: some((lo, hi))
