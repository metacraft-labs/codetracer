## decoration_generator.nim — PLAT-28's POPULATION: anchored documents carrying
## SENTINELS, and the five edit kinds the laws are quantified over.
##
## NOT-A-TEST-LANE-FILE: the population's constructor, its classifier and
## `LAW-D1`'s oracle. The assertions are in
## `../unit/test_editor_decoration_laws.nim`.
##
## =========================================================================
## THE ORACLE IS A SENTINEL RE-SCAN AND IT MUST NOT BE THE MAPPING FUNCTION
## =========================================================================
##
## Editor-Model-Conformance-Suite.md §3.4: *"`LAW-D1`'s oracle MUST NOT be the
## mapping function. A sentinel re-scan is deliberately naive and deliberately
## slow; that is what makes it an oracle rather than a second call to the thing
## under test."* Verification-Harness-Traps §30 is the general form and §30a is
## the sharper one: a CORRECT RE-DERIVATION on one side of a differential makes
## both sides agree and the test measure nothing, and no assertion about the
## ANSWER can see it.
##
## So the oracle here is `string.find`. It walks the new document looking for a
## literal marker and reports the byte it is at. It knows nothing about change
## sets, sections, sides or `mapPos`; it could be written by somebody who had
## never read `change_set.nim`. **The suite arms this with a SOURCE SCAN on the
## oracle's own body** (§30a's only available instrument) rather than with an
## assertion about its answer.
##
## =========================================================================
## TWO SENTINELS PER SITE, BECAUSE A SIDE IS NOT OBSERVABLE WITH ONE
## =========================================================================
##
## An anchor declares a side, and the side decides exactly one thing: where the
## anchor lands when text is inserted AT it. With a single marker after the
## anchor, `find(marker)` reports the position after the inserted text — which
## is `sideAfter`'s answer — and `sideBefore`'s answer could only be recovered
## by subtracting the insertion's length, i.e. by reading the change set. That
## would put the change set back into the oracle.
##
## Each site therefore carries TWO markers, `L` and `R`, abutting:
##
##     ... text [[L3]] | [[R3]] text ...
##                     ^ the anchor
##
##   * a `sideBefore` anchor's oracle is `find(L) + len(L)` — it sticks to the
##     text BEFORE it, so an insert at the anchor goes after it;
##   * a `sideAfter` anchor's oracle is `find(R)` — it sticks to the text AFTER
##     it, so an insert at the anchor goes before it.
##
## Neither expression mentions the edit.
##
## =========================================================================
## THE EDIT RULE THAT MAKES THE ORACLE EXACT, STATED AS AN INVARIANT
## =========================================================================
##
## Every drawn edit obeys one of three shapes, and `witnessEditRule` below
## re-checks it on the built change set rather than trusting the constructor:
##
##   1. it acts entirely OUTSIDE every `[[L..]][[R..]]` block; or
##   2. it is a zero-width INSERT exactly at a site's anchor, between `L` and
##      `R` — the one shape where the side decides; or
##   3. it strictly contains a site's anchor AND covers that site's whole
##      block, so BOTH markers are destroyed together.
##
## Under that rule the oracle is total: a marker is either intact and unique
## (survived, and `find` says where) or absent (the anchor's text is gone, and
## the model must report a non-survived fate). **A partially cut marker would
## be a third state the oracle could not read**, and it is excluded by
## construction rather than handled.
##
## =========================================================================
## THE FIVE EDIT KINDS ARE §4.1's OWN NAMES, NOT A NEW TAXONOMY
## =========================================================================
##
## PLAT-28's floor multiplies by "5 edit kinds". They are five of
## `change_generator.ShapeClass`'s ten — pure insert, pure delete, replace,
## multi-section, empty — reached through that enum rather than through a
## parallel one, so a class renamed there does not compile here.
##
## `classifyChange` READS A BUILT CHANGE SET BACK and says what it found.
## Nothing in this file labels its own output (§34's third rule, §30).

import std/options

import ../../editor/anchor
import ../../editor/change_set
import ../../editor/decoration
import ../../editor/transaction
import ../corpus/unicode_corpus
import ./change_generator

export change_generator, decoration, transaction, unicode_corpus

type
  SentinelSite* = object
    ## One anchored point of a generated document.
    index*: int
    left*, right*: string
    blockStart*, anchorPos*, blockEnd*: int
      ## In the document AS BUILT. After an edit these are stale by design —
      ## re-finding them is the oracle's job, not a field's.

  AnchorDoc* = object
    ## A corpus window with sentinel sites planted in it.
    docId*: string
    text*: string
    sites*: seq[SentinelSite]
    safeOffsets*: seq[int]
      ## Composed-document offsets at which an edit may begin or end: every
      ## cluster boundary of the ORIGINAL window, shifted past the blocks
      ## inserted before it. Never inside a block.

  AnchorDraw* = object
    ## The generator's INPUT, which is what the shrinker shrinks.
    docIndex*: int
    cls*: ShapeClass
    sites*: int
    salt*: uint32

  DecoClass* = enum
    ## The declared shape classes of a generated DECORATION set. A set that
    ## only ever held marks would leave three of `decoration`'s four arms
    ## unexercised by every law quantified over it (§4b).
    dcMark
    dcInlineWidget
    dcBlockWidget
    dcLine

  GeneratorError* = object of ValueError

const
  AnchorEditKinds*: array[5, ShapeClass] = [
    clsPureInsert, clsPureDelete, clsReplace, clsMultiSection, clsEmpty]
    ## **THE FIVE, BY NAME FROM §4.1's ENUM.** The floor's "5 edit kinds"
    ## multiplier is `AnchorEditKinds.len`, which §10.4's third rule asks for:
    ## an asserted cardinality rather than a round number.

  AnchorEditKindCount* = AnchorEditKinds.len
  DecoClassCount* = ord(high(DecoClass)) - ord(low(DecoClass)) + 1

  SitesPerDoc* = 3
    ## Three sites per document and TWO anchors per site — one of each side —
    ## so eighteen documents supply 108 anchors against the gate's floor of 50.
    ## Three and not one because `clsMultiSection` needs a site it deletes
    ## purely, a site it replaces and a site it leaves alone, IN ONE CHANGE
    ## SET: with fewer, that class could not realise all three fates at once
    ## and the multi-section row of the fate matrix would be empty for a reason
    ## about the generator.

  MarkerPrefix* = "[["
    ## The sentinels are ASCII and begin with a sequence no corpus document
    ## contains. `plantSentinels` ASSERTS that, per document, rather than
    ## assuming it — Verification-Harness-Traps §5: a sentinel that collides
    ## with the text turns a found marker into a false position.

func leftMarker*(k: int): string = MarkerPrefix & "L" & $k & "]]"
func rightMarker*(k: int): string = MarkerPrefix & "R" & $k & "]]"

func occurrences*(hay, needle: string): int =
  ## **THE ORACLE'S COUNTER, AND IT IS DELIBERATELY NAIVE.** A linear scan with
  ## no index, no cache and no knowledge of the edit. See the header.
  if needle.len == 0: return 0
  var i = 0
  while i + needle.len <= hay.len:
    if hay[i ..< i + needle.len] == needle:
      inc result
      i += needle.len
    else:
      inc i

func findMarker*(hay, needle: string): int =
  ## **THE ORACLE.** `-1` when the marker is not there. Also deliberately
  ## naive; `strutils.find` would be faster and would still be an oracle, and
  ## this is spelled out so the source scan that grades the oracle has a body
  ## to read rather than a call to somebody else's.
  result = -1
  if needle.len == 0: return
  var i = 0
  while i + needle.len <= hay.len:
    if hay[i ..< i + needle.len] == needle: return i
    inc i

proc plantSentinels*(d: GenDoc; sites = SitesPerDoc): AnchorDoc =
  ## A generated window with `sites` sentinel blocks planted at cluster
  ## boundaries, well separated and with margins at both ends.
  ##
  ## The margins are not cosmetic: a delete that must strictly contain an
  ## anchor needs a safe offset on each side of the block, so a site at the
  ## first or last boundary would have a fate the generator could never reach
  ## and the matrix would carry an empty cell for a reason about the layout.
  let bs = d.boundaries
  if bs.len < 2 * sites + 4:
    raise newException(GeneratorError,
      "plantSentinels: " & d.id & " offers " & $bs.len & " cluster " &
      "boundaries, fewer than the " & $(2 * sites + 4) & " that " & $sites &
      " sites with margins need. Refused rather than narrowed: a narrowed " &
      "layout produces fates the matrix then reports as unreachable.")
  if occurrences(d.text, MarkerPrefix) != 0:
    raise newException(GeneratorError,
      "plantSentinels: " & d.id & " already contains '" & MarkerPrefix &
      "'. A sentinel that collides with the text turns a found marker into a " &
      "false position (Verification-Harness-Traps §5).")

  # The site boundaries: evenly spread across the interior, never adjacent.
  var at: seq[int] = @[]
  let usable = bs.len - 4
  for k in 0 ..< sites:
    at.add bs[2 + (usable * k) div sites]
  for k in 1 ..< at.len:
    if at[k] <= at[k - 1]:
      raise newException(GeneratorError,
        "plantSentinels: " & d.id & " produced non-ascending site offsets")

  result.docId = d.id
  result.sites = @[]
  var text = ""
  var prev = 0
  var shift = 0
  for k in 0 ..< sites:
    let l = leftMarker(k)
    let r = rightMarker(k)
    text.add d.text[prev ..< at[k]]
    let blockStart = at[k] + shift
    text.add l
    text.add r
    result.sites.add SentinelSite(index: k, left: l, right: r,
                                  blockStart: blockStart,
                                  anchorPos: blockStart + l.len,
                                  blockEnd: blockStart + l.len + r.len)
    shift += l.len + r.len
    prev = at[k]
  text.add d.text[prev .. ^1]
  result.text = text

  # The safe offsets: every original boundary, shifted past the blocks planted
  # at or before it. Derived from the same `at` list rather than re-found in
  # the composed text, because a search for "a boundary" in text that now
  # contains ASCII markers would be a second segmentation.
  result.safeOffsets = @[]
  for v in bs:
    var s = 0
    for k in 0 ..< sites:
      if at[k] <= v: s += leftMarker(k).len + rightMarker(k).len
    result.safeOffsets.add v + s

  for site in result.sites:
    if occurrences(result.text, site.left) != 1 or
       occurrences(result.text, site.right) != 1:
      raise newException(GeneratorError,
        "plantSentinels: marker " & site.left & "/" & site.right &
        " is not unique in " & d.id)

func anchorsOf*(ad: AnchorDoc): seq[Anchor] =
  ## **TWO ANCHORS PER SITE, ONE OF EACH SIDE, AT THE SAME POSITION.** That is
  ## what makes the side dimension a comparison rather than two runs: both
  ## anchors see the same edit and the only thing that can differ is the side.
  ##
  ## The surface rotates through `AnchorSurface`'s four members so `LAW-D2`'s
  ## "4 surfaces" multiplier is realised by the population rather than by a
  ## second loop over a constant.
  result = @[]
  for s in ad.sites:
    for si, side in [sideBefore, sideAfter]:
      let surface = AnchorSurface((2 * s.index + si) mod AnchorSurfaceCount)
      result.add anchorAt(s.anchorPos, side, surface,
                          id = 2 * s.index + si)

func siteOfAnchor*(a: Anchor): int = a.id div 2
func sideIndexOfAnchor*(a: Anchor): int = a.id mod 2

func oracleOf*(ad: AnchorDoc; a: Anchor; newDoc: string): Option[int] =
  ## **`LAW-D1`'s ORACLE.** `none` means *"the text this anchor sat in is
  ## gone"*; a value is the byte the anchor's own marker now begins (or ends)
  ## at.
  ##
  ## Two `find`s and one addition. No change set, no section, no side
  ## arithmetic — the SIDE picks which marker to look for and nothing else.
  let s = ad.sites[siteOfAnchor(a)]
  if a.side == sideBefore:
    let i = findMarker(newDoc, s.left)
    if i < 0: none(int) else: some(i + s.left.len)
  else:
    let i = findMarker(newDoc, s.right)
    if i < 0: none(int) else: some(i)

# ---------------------------------------------------------------------------
# The five edit kinds
# ---------------------------------------------------------------------------

func safeBelow(ad: AnchorDoc; pos: int): int =
  ## The largest safe offset strictly below `pos`.
  result = -1
  for v in ad.safeOffsets:
    if v < pos and v > result: result = v

func safeAbove(ad: AnchorDoc; pos: int): int =
  result = high(int)
  for v in ad.safeOffsets:
    if v > pos and v < result: result = v
  if result == high(int): result = -1

proc genChange*(ad: AnchorDoc; r: var Rng; cls: ShapeClass): ChangeSet =
  ## One change set of the intended kind, obeying the edit rule in the header.
  ##
  ## **The class is an ARGUMENT and the histogram is the CLASSIFIER's**, so
  ## this routine never gets to say what it built.
  # **THE ROLE EACH SITE PLAYS ROTATES, AND THAT IS NOT COSMETIC.** A site's
  # SURFACE is a property of the anchor (`anchorsOf` cycles through
  # `AnchorSurface`'s four members) and its FATE is decided by which site this
  # change set deletes. With the roles pinned to sites 0 and 1, the two are
  # perfectly correlated: `asBreakpoint` would only ever be `collapsed` and
  # `asDecorationRange` only ever `deleted` — measured on the first run, where
  # four of `LAW-D2`'s twelve cells came back EMPTY for a reason about the
  # generator rather than about the model. The rotation is drawn per change
  # set, so over `Salts` draws every site plays every role.
  let rot = r.rand(ad.sites.len - 1)
  let delSite = ad.sites[rot]
  let repSite = ad.sites[(rot + 1) mod ad.sites.len]
  let keepSite = ad.sites[(rot + 2) mod ad.sites.len]
  let delFrom = safeBelow(ad, delSite.blockStart)
  let delTo = safeAbove(ad, delSite.blockEnd)
  let repFrom = safeBelow(ad, repSite.blockStart)
  let repTo = safeAbove(ad, repSite.blockEnd)
  if delFrom < 0 or delTo < 0 or repFrom < 0 or repTo < 0:
    raise newException(GeneratorError,
      "genChange: " & ad.docId & " has a site with no safe offset on one " &
      "side of it; `plantSentinels`' margins were not honoured")
  # A safe position well away from every block, for the "survives" arm.
  let far = ad.safeOffsets[^2]
  var edits: seq[Edit] = @[]
  case cls
  of clsPureInsert:
    # An insert exactly AT a site's anchor — the one shape where the side
    # decides — and one in free text.
    edits.add Edit(fromPos: delSite.anchorPos, toPos: delSite.anchorPos,
                   insert: corpusClusters(r, 1 + r.rand(2)))
    if far > delSite.blockEnd:
      edits.add Edit(fromPos: far, toPos: far,
                     insert: corpusClusters(r, 1 + r.rand(1)))
  of clsPureDelete:
    # Across one whole block: purely deleted, so the fate is `collapsed`.
    edits.add Edit(fromPos: delFrom, toPos: delTo, insert: "")
  of clsReplace:
    # Across one whole block, with new text: the fate is `deleted`.
    edits.add Edit(fromPos: repFrom, toPos: repTo,
                   insert: corpusClusters(r, 1 + r.rand(2)))
  of clsMultiSection:
    # ALL THREE FATES IN ONE CHANGE SET, which is why `SitesPerDoc` is 3: one
    # site purely deleted, one replaced, one left alone with a zero-width
    # insert exactly at its anchor.
    edits.add Edit(fromPos: delFrom, toPos: delTo, insert: "")
    edits.add Edit(fromPos: repFrom, toPos: repTo,
                   insert: corpusClusters(r, 1 + r.rand(2)))
    edits.add Edit(fromPos: keepSite.anchorPos, toPos: keepSite.anchorPos,
                   insert: corpusClusters(r, 1))
  of clsEmpty:
    discard
  of clsWholeDocument, clsAdjacent, clsOverlapping, clsTouchingPoint,
     clsCollapsePoint:
    raise newException(GeneratorError,
      "genChange: " & $cls & " is one of §4.1's ten classes and is NOT one of " &
      "PLAT-28's five edit kinds. It is refused rather than approximated: a " &
      "class silently mapped onto another is a histogram row that means two " &
      "things.")
  # ASCENDING, because `changeSet` refuses an unordered edit list and the
  # rotation above produces them in role order rather than in position order.
  # Sorted here rather than by `changeSetOrdered`, which is a DIFFERENT
  # routine with a different contract (it composes rather than rejects).
  for i in 1 ..< edits.len:
    var j = i
    while j > 0 and edits[j - 1].fromPos > edits[j].fromPos:
      swap(edits[j - 1], edits[j])
      dec j
  changeSet(ad.text.len, edits)

func sectionShapes(cs: ChangeSet): seq[int] =
  ## `0` pure delete, `1` pure insert, `2` replacement — per changed section.
  result = @[]
  for s in cs.sections:
    if s.kind == skKeep: continue
    if s.insert.len == 0: result.add 0
    elif s.delete == 0: result.add 1
    else: result.add 2

func classifyChange*(cs: ChangeSet): ShapeClass =
  ## **THE CLASSIFIER.** It reads a built change set back and says what it
  ## found; nothing tells it what the change set was supposed to be (§34).
  let shapes = sectionShapes(cs)
  if shapes.len == 0: return clsEmpty
  var distinct3 = 0
  for k in 0 .. 2:
    for s in shapes:
      if s == k:
        inc distinct3
        break
  if distinct3 > 1: return clsMultiSection
  case shapes[0]
  of 0: clsPureDelete
  of 1: clsPureInsert
  else: clsReplace

proc witnessEditRule*(ad: AnchorDoc; cs: ChangeSet): bool =
  ## **THE EDIT RULE, RE-CHECKED ON THE BUILT CHANGE SET.** The constructor
  ## above obeys it by construction; this reads the result back, because a
  ## constructor that graded itself is the shape §34's third rule is about, and
  ## because the oracle is only total while this holds.
  ##
  ## The three admissible shapes are a DISJUNCTION and the routine is a
  ## conjunction over sites: a change that is admissible for every site is
  ## admissible. Anything else — a cut that lands inside a block, a delete that
  ## covers one marker and not the other — is a shape the oracle cannot read,
  ## and it is reported rather than classified into the nearest neighbour.
  for ch in cs.changedRanges(individual = true):
    for s in ad.sites:
      let atAnchor = ch.fromA == ch.toA and ch.fromA == s.anchorPos
      let covers = ch.fromA < s.blockStart and ch.toA > s.blockEnd
      let outside = ch.toA <= s.blockStart or ch.fromA >= s.blockEnd
      if not (atAnchor or covers or outside): return false
  true

proc streamOf*(ad: AnchorDoc; r: var Rng; cls: ShapeClass): Transaction =
  ## One transaction, because `FUZZ-2` is quantified over a TRANSACTION stream
  ## and a bare change set would be a different subject with a similar shape.
  transaction(genChange(ad, r, cls))

# ---------------------------------------------------------------------------
# Decorations
# ---------------------------------------------------------------------------

proc genDecorations*(ad: AnchorDoc; r: var Rng; n: int): DecorationSet =
  ## `n` decorations at safe offsets, cycling through the four arms so no law
  ## quantified over a generated set is a law about marks only.
  ##
  ## The ids are `0 ..< n` and the positions ascend, which makes the chunking
  ## in `range_set` meaningful: a set whose values all sat at one offset would
  ## be one chunk and the skip optimisation would never be exercised.
  var ds: seq[Decoration] = @[]
  let offs = ad.safeOffsets
  for i in 0 ..< n:
    let a = offs[(i * 2) mod offs.len]
    let b = offs[min(((i * 2) mod offs.len) + 1, offs.len - 1)]
    let cls = DecoClass(i mod DecoClassCount)
    let payload = case cls
      of dcMark: markPayload("gen-mark-" & $i)
      of dcInlineWidget: inlineWidget(1 + (i mod 4), "v" & $i)
      of dcBlockWidget: blockWidget(1 + (i mod 2),
                                    BlockPlacement(i mod BlockPlacementCount),
                                    "b" & $i)
      of dcLine: linePayload("gen-line-" & $i)
    let mode = if r.rand(3) == 0: rmDropWhenTouched else: rmTrack
    ds.add decoration(i, min(a, b), max(a, b), payload,
                      fromSide = if (i and 1) == 0: sideBefore else: sideAfter,
                      toSide = if (i and 2) == 0: sideBefore else: sideAfter,
                      mode = mode)
  decorationSet(ds)

func classifyDecoration*(d: Decoration): DecoClass =
  ## The classifier for the decoration population, reading the ARM back.
  case d.payload.kind
  of dkMark: dcMark
  of dkInlineWidget: dcInlineWidget
  of dkBlockWidget: dcBlockWidget
  of dkLine: dcLine

# ---------------------------------------------------------------------------
# Shrinking — §4.5, and it is tested by a planted always-failing property
# ---------------------------------------------------------------------------

func isValidDraw*(d: AnchorDraw): bool =
  d.sites >= 1 and d.sites <= SitesPerDoc and d.docIndex >= 0 and
    d.docIndex < CorpusDocs.len

func shrinkCandidates*(d: AnchorDraw): seq[AnchorDraw] =
  ## Strictly smaller draws, in the order a human would try them: fewer sites
  ## first, then an earlier document, then the simplest edit kind.
  result = @[]
  if d.sites > 1:
    var c = d
    c.sites = d.sites - 1
    result.add c
  if d.docIndex > 0:
    var c = d
    c.docIndex = 0
    result.add c
  if d.cls != clsEmpty:
    var c = d
    c.cls = clsEmpty
    result.add c

proc shrink*(d: AnchorDraw; fails: proc (x: AnchorDraw): bool): AnchorDraw =
  ## A locally minimal failing draw. Greedy, and it stops when no candidate
  ## still fails — which is what "locally minimal" means and all a shrinker of
  ## this shape can promise.
  result = d
  var moved = true
  while moved:
    moved = false
    for c in shrinkCandidates(result):
      if isValidDraw(c) and fails(c):
        result = c
        moved = true
        break

func describe*(d: AnchorDraw): string =
  "draw(doc=" & $d.docIndex & ", cls=" & $d.cls & ", sites=" & $d.sites &
    ", salt=" & $d.salt & ")"
