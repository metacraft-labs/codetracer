## PLAT-28 — `LAW-D1` … `LAW-D5` and `LAW-C7`, executable, over a declared
## population.
##
## Subjects: `viewmodel/editor/{anchor,range_set,decoration,inlay,
## row_projection}.nim`, the seam `wrap.wrapCacheOfMetrics`, and
## `viewmodel/tests/generators/decoration_generator.nim` — the population,
## which is a subject like any other and is armed like one.
##
## =========================================================================
## WHAT THIS FILE IS FOR, IN ONE SENTENCE
## =========================================================================
##
## Editor-ViewModel.md §8.3 calls the reflow *"the design's sharpest claim"*:
## text following an inline widget is positioned AFTER it, and a line whose
## content exceeds the wrap column wraps at the point that content dictates.
## **`LAW-C7` measures a COLUMN, in both arms.** A renderer that draws the
## widget as an overlay cannot move one, and neither can one that draws
## everything at column 0 — which is why the second arm exists (§7b: an
## unfalsified negative control is a self-comparison wearing a negation).
##
## =========================================================================
## THE SIX RULES THAT MAKE THIS EVIDENCE RATHER THAN A GREEN RUN
## =========================================================================
##
## 1. **§30a — A CORRECT RE-DERIVATION MAKES BOTH SIDES AGREE AND THE TEST
##    MEASURE NOTHING, AND NO ASSERTION ABOUT THE ANSWER CAN SEE IT.** Three of
##    the laws here are differentials (`LAW-D1` model-against-oracle, `LAW-D3`
##    skip-against-walk, `LAW-C7` decorated-against-plain). Each is armed with a
##    SOURCE SCAN ON THE BODY of the control, because that is the only
##    instrument that can: "the oracle does not call `mapPos`" is a fact about
##    the oracle's text, not about its answers.
##
## 2. **§34 — THE POPULATIONS, NOT THE PROPERTIES.** The analogue here is a
##    generator producing only decorations whose text is never edited, or only
##    anchors in unwrapped lines. The **deleted-text**, **boundary-side** and
##    **wrapped-line** classes are asserted as EQUALITIES against their
##    per-class draw counts, each witnessed by name, before any law is
##    quantified over them.
##
## 3. **§36a — A CLAMP IS A SILENT REPAIR.** An anchor clamped into range makes
##    a fate look total. Every unreachable-by-construction path in the five new
##    modules RAISES, the raises are EXECUTED rather than only scanned, and the
##    scan asserts the module set contains no `clamp(`.
##
## 4. **§36 — A KILLER THAT CANNOT BE OBSERVED.** Each `LAW-D*` names a
##    mutation in §3.4; every one is performed by
##    `run-plat28-decoration-mutations.py` and the result is reported per law.
##
## 5. **THE FATE MATRIX IS TWO-SIDED.** 2 sides x 3 fates x 5 edit kinds is 30
##    cells and **18 of them are reachable**. The unreachable twelve are
##    asserted UNREACHABLE over the whole population rather than left out, so a
##    model change that makes one reachable is red — and the reachable count is
##    asserted as an equality, so a model change that makes one unreachable is
##    red too. One direction alone is satisfied by a population that never
##    deleted anything.
##
## 6. **THE ORACLE IS NOT THE MAPPING FUNCTION.** `decoration_generator`'s
##    `findMarker` is a byte-by-byte scan of the new document for a literal
##    marker. It is slow on purpose. See that file's header for why each site
##    carries TWO markers rather than one.
##
## ARMING: `run-plat28-decoration-mutations.py`.

import std/[options, strutils, unittest]

import ../../editor/anchor
import ../../editor/change_set
import ../../editor/decoration
import ../../editor/inlay
import ../../editor/range_set
import ../../editor/row_projection
import ../../editor/transaction
import ../../editor/wrap
import ../corpus/unicode_corpus
import ../generators/change_generator
import ../generators/decoration_generator

# ---------------------------------------------------------------------------
# Counted assertions
# ---------------------------------------------------------------------------

var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 1276
  ## **+2 ON 2026-09-19: PLAT-32 ADDED `history.nim` TO `viewmodel/editor/`,
  ## AND THIS SUITE SAID SO BEFORE THAT MILESTONE'S OWN SUITES EXISTED.**
  ## §35's enumeration firing for the sixth time, from a milestone that had
  ## been green for a day. The repair is a list entry and this number.
  ## Asserted by the last case against the runtime tally. Written LAST, from a
  ## run, and updated deliberately in the same commit as the checks that moved
  ## it.
  ##
  ## 1266 -> 1270 -> 1274 on 2026-09-18, and each step is four: the §35
  ## directory check is TWO-SIDED, so every module named there is asserted
  ## twice. PLAT-29 added `document_version.nim` and `reconcile.nim` and
  ## PLAT-30 added `operations.nim` and `editor_state.nim` to the directory
  ## this suite claims to cover; this suite went red by name each time until
  ## they were named, which is the guard working rather than maintenance.

const Seed = 0x28c0de00'u32
  ## Printed. Every population below is derived from it, and the suite is
  ## byte-identical from one seed on both backends.

const Salts = 12
  ## Draws per (document, edit kind). 18 x 5 x 12 = 1,080 transactions, against
  ## the gate's floor of 1,000. The number is asserted at run time rather than
  ## claimed here.

# ---------------------------------------------------------------------------
# The laws, and their killers — §3.4's own column
# ---------------------------------------------------------------------------

type LawId = enum
  lawD1, lawD2, lawD3, lawD4, lawD5

const LawName: array[LawId, string] = [
  "LAW-D1", "LAW-D2", "LAW-D3", "LAW-D4", "LAW-D5"]

const LawKiller: array[LawId, string] = [
  "map anchors with the wrong side",
  "return the collapse point as survived",
  "widen the skip predicate by one chunk, so a chunk the change actually " &
    "touches is skipped and keeps a stale position the unoptimised path moves",
  "widen-vs-narrow: a comparison that returns an empty span always agrees",
  "compare the offset before the enum"]
  ## Transcribed from Editor-Model-Conformance-Suite.md §3.4, and the
  ## transcription is CHECKED: `ci/test/editor-model-case-floor.sh PLAT-28`
  ## parses that table out of the sibling checkout at run time and compares the
  ## ids and the non-empty killer cells against this array in both directions,
  ## with the cardinality asserted (§7.1).

const LawCount = ord(high(LawId)) - ord(low(LawId)) + 1

# **§3.3's SEVENTH ROW IS RUN HERE.** PLAT-27 built §3.3's six coordinate laws
# and DECLARED the seventh deferred — the reflow, which needs widgets.
# `ci/test/editor-model-case-floor.sh PLAT-27` read that deferral, required the
# id to be published AND absent from PLAT-27's suite, and ran the two-way count
# over the remaining six.
#
# This milestone implements it, so the deferral is EXPIRED rather than left
# standing: PLAT-27's entry in that gate now names BOTH suites and compares the
# union of their declared ids against the seven published, with no deferrals at
# all. The array below is spelled with the prefix the gate's reader matches, so
# this declaration is the thing the gate checks rather than a comment claiming
# the law is implemented.
#
# The prose is a `#` block and not a `##` doc comment for a mechanical reason:
# the gate reads `sed -n '/^const LawName/,/]/p'`, and a doc comment mentioning
# the id INSIDE that range would be counted as a second declaration of it.
const LawNameInherited: array[1, string] = [
  "LAW-C7"]

var lawChecks: array[LawId, int]

proc note(law: LawId; n = 1) = lawChecks[law] += n
  ## A plain counter. Verification-Harness-Traps §29: nothing outside a test
  ## body may `check`, because `unittest.check` in a plain `proc` sets a GLOBAL
  ## and the enclosing case still prints `[OK]`.

# ---------------------------------------------------------------------------
# `LAW-C7`'s own tally. It belongs to §3.3's table, not §3.4's, and PLAT-27
# DEFERRED it to this milestone — so it is counted separately and the floor
# gate now requires it to be RUN rather than absent.
# ---------------------------------------------------------------------------

var lawC7Checks = 0

# ===========================================================================
# THE POPULATION
# ===========================================================================

type Observation = object
  ## One anchor's fate under one transaction. Everything the fate matrix reads
  ## is here, so the matrix cells are filters over a list rather than 30 loops.
  docId: string
  cls: ShapeClass
  side: Side
  surface: AnchorSurface
  fate: AnchorFate
  agreedWithOracle: bool
  oracleSaid: bool          ## whether the oracle found the marker at all
  landing: int
  newLen: int

type PopulationStats = object
  transactions: int
  distinctAnchors: int
  anchorObservations: int
  editKindCounts: array[5, int]
  editKindRealised: array[5, int]
  ruleWitnessed: int
  sideAtBoundary: int       ## §34's boundary-side class: an insert AT an anchor
  deletedText: int          ## §34's deleted-text class: a non-survived fate
  docs: int

var observations: seq[Observation] = @[]
var pop: PopulationStats

proc buildPopulation() =
  ## **ONE PASS, BOUND TO A NAME.** §34's first rule is mechanical: an
  ## expression that mentions a generator twice draws twice. Every draw below
  ## is `let x = ...` before anything reads two of its parts.
  let docs = genDocs(Seed)
  pop.docs = docs.len
  var r = initRng(Seed)
  var anchorIds: seq[string] = @[]
  for d in docs:
    let ad = plantSentinels(d)
    let anchors = anchorsOf(ad)
    for a in anchors:
      let key = d.id & "#" & $a.id
      var seen = false
      for k in anchorIds:
        if k == key: seen = true
      if not seen: anchorIds.add key
    for ki, cls in AnchorEditKinds:
      for salt in 0 ..< Salts:
        let cs = genChange(ad, r, cls)
        let realised = classifyChange(cs)
        inc pop.transactions
        inc pop.editKindCounts[ki]
        if realised == cls: inc pop.editKindRealised[ki]
        if witnessEditRule(ad, cs): inc pop.ruleWitnessed
        # THE TRANSACTION, not the bare change set: `FUZZ-2` is quantified over
        # a transaction stream and the two are different subjects.
        let t = transaction(cs)
        let newDoc = t.apply(ad.text)
        # The boundary-side class: does this change set insert EXACTLY at an
        # anchor, which is the only shape where the side decides?
        for site in ad.sites:
          for ch in cs.changedRanges(individual = true):
            if ch.fromA == ch.toA and ch.fromA == site.anchorPos:
              inc pop.sideAtBoundary
        for a in anchors:
          let m = a.mapAnchor(cs)
          let o = oracleOf(ad, a, newDoc)
          var agreed = false
          if o.isSome:
            agreed = m.fate == mapSurvived and m.landingOf == o.get
          else:
            agreed = m.fate != mapSurvived
            inc pop.deletedText
          inc pop.anchorObservations
          observations.add Observation(
            docId: d.id, cls: cls, side: a.side, surface: a.surface,
            fate: m.fate, agreedWithOracle: agreed, oracleSaid: o.isSome,
            landing: m.landingOf, newLen: newDoc.len)
  pop.distinctAnchors = anchorIds.len

buildPopulation()

# THE REACHABILITY TABLE, DECLARED. `true` means the generator's five edit
# kinds can produce that (side, fate) combination; `false` means they cannot,
# and the cell asserts that it did not. Both directions, and the count of
# `true` cells is asserted, so neither "everything is reachable" nor "nothing
# is" satisfies the matrix.
const Reachable: array[5, array[3, bool]] = [
  # order: [mapSurvived, mapDeleted, mapCollapsed] per AnchorEditKinds index
  [true, false, false],   # clsPureInsert — nothing is removed
  [true, false, true],    # clsPureDelete — a purely deleted range collapses
  [true, true, false],    # clsReplace — replaced text reports `deleted`
  [true, true, true],     # clsMultiSection — all three, in ONE change set
  [true, false, false]]   # clsEmpty — the identity

const ReachableCells = block:
  var n = 0
  for row in Reachable:
    for v in row:
      if v: inc n
  n

const FateOrder: array[3, AnchorFate] = [mapSurvived, mapDeleted, mapCollapsed]
const SideOrder: array[2, Side] = [sideBefore, sideAfter]

func sideName(s: Side): string =
  if s == sideBefore: "sideBefore" else: "sideAfter"

func fateName(f: AnchorFate): string =
  case f
  of mapSurvived: "survived"
  of mapDeleted: "deleted"
  of mapCollapsed: "collapsed"


# ===========================================================================
# `LAW-C7`'s POPULATION — the reflow, per corpus class, derived from the
# documents rather than from constants
# ===========================================================================

func classOfDocId(id: string): int = parseInt($id[1])
  ## The corpus class read off the document id, the same derivation
  ## `unicode_corpus.docsOfClass` uses.

const CorpusClassCount = CorpusDocs.len div 2
  ## **NINE, DERIVED.** §5.1: nine classes, two documents each. Asserted below
  ## against `docsOfClass`, in both directions, because a filter that matched
  ## nothing satisfies every law written over it (§4).

type ReflowCell = object
  ## One class's reflow measurement. Every number here is derived from the
  ## document — `LAW-C7` at a hand-picked column and a hand-picked width would
  ## be a measurement of the constants.
  docId: string
  line: int
  byteAt: int            ## the byte the following text begins at
  widgetText: string
  widgetCells: int       ## W, measured by the model's own width function
  plainColumn: int       ## C, with no widget
  decoColumn: int        ## the same text's column with the widget present
  lineWidth: int
  wrapAt: int            ## the wrap column at which the wrap arm is taken
  plainRows: int
  decoRows: int
  hasWideCluster: bool   ## a cluster of two or more cells after the widget
  wideAtWidePolicy: bool ## the same, with `awWide` — class 4's own question

var reflowCells: array[CorpusClassCount, ReflowCell]
var wrappedWitnesses: array[CorpusClassCount, string]

const ReflowPolicy = ColumnPolicy(tabSize: 4, ambiguous: awNarrow)

proc widestLineOf(doc: string): (int, int) =
  ## `(line index, width)` of the document's widest line, measured with the
  ## model's own metrics. Derived, so the cell moves when the corpus does.
  var best = 0
  var bestW = -1
  for i, line in documentLines(doc):
    let w = lineMetrics(line, ReflowPolicy).width
    if w > bestW:
      bestW = w
      best = i
  (best, bestW)

proc buildReflowCells() =
  for c in 0 ..< CorpusClassCount:
    var chosen = ""
    for d in docsOfClass(c + 1):
      # The LONG document of the pair: the short ones are hand-audited and a
      # few lines each, and a reflow measured on a two-cluster line would be a
      # measurement with nothing after the widget.
      if d.id.endsWith("-long"): chosen = d.id
    let doc = docById(chosen)
    let (line, lineWidth) = widestLineOf(doc)
    let text = documentLines(doc)[line]
    let m = lineMetrics(text, ReflowPolicy)
    # C is a cluster boundary about a third of the way along the line, so
    # there is content on BOTH sides of the widget.
    let ci = max(1, m.clusters.len div 3)
    let byteAt = m.clusters[ci].startByte
    # THE WIDGET IS A REAL INLINE VALUE MADE OF THE DOCUMENT'S OWN TEXT, and
    # its width is measured by `lineMetrics` — the same function that measures
    # the code beside it. A constant here would make `LAW-C7` a statement about
    # the constant.
    let valueText = text[m.clusters[ci].startByte ..< m.clusters[min(
      ci + 2, m.clusters.len - 1)].stopByte]
    let widgetText = inlineTextOf(EditorValue(name: "v", value: valueText))
    let widgetCells = lineMetrics(widgetText, ReflowPolicy).width
    let noWrap = WrapSettings(wrapColumn: 0, policy: ReflowPolicy)
    let ds = decorationSet(@[decoration(
      0, lineStartOffsetsOf(doc)[line] + byteAt,
      lineStartOffsetsOf(doc)[line] + byteAt,
      inlineWidget(widgetCells, widgetText))])
    let plain = initWrapCache(doc, noWrap)
    let deco = inlayWrapCache(doc, noWrap, ds)
    var wide = false
    for k in ci ..< m.clusters.len:
      if m.clusters[k].cells >= 2: wide = true
    # CLASS 4 IS AMBIGUOUS-WIDTH AND AT `awNarrow` ITS CLUSTERS ARE ONE CELL.
    # That is the right answer rather than a gap, and it is asserted as one:
    # the same line at `awWide` DOES carry a wide cluster, which is `LAW-C5`'s
    # two-sidedness arriving inside `LAW-C7`.
    let mWide = lineMetrics(text, ColumnPolicy(tabSize: 4, ambiguous: awWide))
    var wideWide = false
    for k in ci ..< mWide.clusters.len:
      if mWide.clusters[k].cells >= 2: wideWide = true
    # THE WRAP ARM. The wrap column is `lineWidth + W - 1`, derived: the plain
    # line fits in it exactly and the decorated one cannot.
    let wrapAt = lineWidth + widgetCells - 1
    let atEnd = decorationSet(@[decoration(
      0, lineStartOffsetsOf(doc)[line] + text.len,
      lineStartOffsetsOf(doc)[line] + text.len,
      inlineWidget(widgetCells, widgetText))])
    let wrapSet = WrapSettings(wrapColumn: wrapAt, policy: ReflowPolicy)
    reflowCells[c] = ReflowCell(
      docId: chosen, line: line, byteAt: byteAt, widgetText: widgetText,
      widgetCells: widgetCells,
      plainColumn: plain.toDisplay(textPos(line, byteAt)).column,
      decoColumn: deco.toDisplay(textPos(line, byteAt)).column,
      lineWidth: lineWidth, wrapAt: wrapAt,
      plainRows: initWrapCache(doc, wrapSet).rowsInLine(line),
      decoRows: inlayWrapCache(doc, wrapSet, atEnd).rowsInLine(line),
      hasWideCluster: wide, wideAtWidePolicy: wideWide)
    wrappedWitnesses[c] = chosen & " line " & $line & " w=" & $lineWidth &
      " widget=" & $widgetCells & " cells at wrap column " & $wrapAt

buildReflowCells()

# ---------------------------------------------------------------------------
# `LAW-D3` / `LAW-D4`'s population — decoration sets over the anchored docs
# ---------------------------------------------------------------------------

const DecorationsPerDoc = 40
  ## Five chunks at `range_set.DefaultChunkSize`, so a change touching one
  ## region leaves several untouched and the skip optimisation has something to
  ## skip. Asserted: `skipped > 0` per edit kind.

type SetOutcome = object
  equalSets: int
  comparedPairs: int
  skipped: int
  walked: int
  soundSpans: int
  raised: int
  emptyWhenEqual: int
  differingPairs: int
  identicalPairs: int
  dropped: int
  inBounds: int

var setOutcomes: array[5, SetOutcome]

proc buildSetCell(ki: int; cls: ShapeClass; d: GenDoc; r: var Rng) =
  let ad = plantSentinels(d)
  let before = genDecorations(ad, r, DecorationsPerDoc)
  let cs = genChange(ad, r, cls)
  let newDoc = cs.apply(ad.text)
  var fast: MapStats
  var slow: MapStats
  let mappedFast = mapRangeSet(before.ranges, cs, fast)
  let mappedSlow = mapRangeSetWalked(before.ranges, cs, slow)
  if mappedFast == mappedSlow: inc setOutcomes[ki].equalSets
  setOutcomes[ki].skipped += fast.chunksSkipped
  setOutcomes[ki].walked += slow.chunksWalked
  setOutcomes[ki].dropped += fast.valuesDropped
  var ok = true
  for v in mappedFast.allValues():
    if v.fromAnchor.pos < 0 or v.toAnchor.pos > newDoc.len: ok = false
  if ok: inc setOutcomes[ki].inBounds
  # `LAW-D4`: the reported span contains every actual difference, and it is
  # `none` exactly when there is none.
  var st: CompareStats
  let span = compareOver(before.ranges, mappedFast, 0,
                         max(ad.text.len, newDoc.len), st)
  let diffs = differencesWalked(before.ranges, mappedFast)
  if diffs.len == 0:
    inc setOutcomes[ki].identicalPairs
    if span.isNone: inc setOutcomes[ki].emptyWhenEqual
  else:
    inc setOutcomes[ki].differingPairs
    if span.isSome:
      var sound = true
      for p in diffs:
        if p < span.get[0] or p > span.get[1]: sound = false
      if sound: inc setOutcomes[ki].soundSpans

proc buildSetPopulation() =
  let docs = genDocs(Seed)
  var r = initRng(Seed xor 0xD3D4'u32)
  for ki, cls in AnchorEditKinds:
    for d in docs:
      inc setOutcomes[ki].comparedPairs
      # **A RAISE IN A MODULE-SCOPE POPULATION KILLS EVERY CASE IN THE FILE**,
      # and a run that prints nothing looks exactly like a run in which every
      # case passed if the only signal read is an exit status. `mapRangeSet`
      # RAISES when the skip predicate and `mapPos` disagree (§36a) — which is
      # precisely what `LAW-D3`'s published killer makes happen — so the
      # exception is CAUGHT and counted here and the law's own cell asserts the
      # count is zero. Measured rather than anticipated: without this, the arm
      # that widens the skip predicate reported HARNESS-FAILURE instead of a
      # kill, because the process died before `unittest` printed a line.
      try:
        buildSetCell(ki, cls, d, r)
      except CatchableError:
        inc setOutcomes[ki].raised

buildSetPopulation()

# ---------------------------------------------------------------------------
# `FUZZ-2` / `FUZZ-7` — a multi-step transaction stream, per corpus class
# ---------------------------------------------------------------------------

const FuzzSteps = 20

type FuzzOutcome = object
  steps: int
  anchorChecks: int
  outOfRange: int
  typedFates: int
  decoChecks: int
  unordered: int
  outOfBounds: int
  movedRows: int
  raised: int

var fuzzOutcomes: array[CorpusClassCount, FuzzOutcome]

proc buildFuzzDoc(c: int; d: GenDoc; r: var Rng) =
      let ad = plantSentinels(d)
      var doc = ad.text
      var live = anchorsOf(ad)
      var dead = 0
      var ds = genDecorations(ad, r, DecorationsPerDoc)
      for step in 0 ..< FuzzSteps:
        # **BOTH ARMS OF THE INVARIANT HAVE TO BE REACHED** (§4b). A stream of
        # `genSimple` draws over a 24-cluster window is overwhelmingly inserts
        # and deletes that MISS the six anchors — measured: six of the nine
        # classes realised ZERO typed fates on the first run, so the
        # "or reports a typed deleted fate" half of `FUZZ-2` fired nowhere and
        # passed everywhere. Every fourth step is therefore a pure deletion of
        # the cluster span STRADDLING a live anchor, which is the only shape
        # that can produce a non-survived fate, and the realised count is
        # asserted non-zero per class.
        var cs = genSimple(doc, r, 2)
        if step mod 4 == 3 and live.len > 0:
          let bs = clusterBoundaries(doc)
          let at = live[step mod live.len].pos
          var lo = -1
          var hi = -1
          for v in bs:
            if v < at and v > lo: lo = v
            if v > at and (hi < 0 or v < hi): hi = v
          if lo >= 0 and hi >= 0 and hi <= doc.len:
            cs = changeSet(doc.len, [Edit(fromPos: lo, toPos: hi, insert: "")])
        let t = transaction(cs)
        let nextDoc = t.apply(doc)
        inc fuzzOutcomes[c].steps
        var stillLive: seq[Anchor] = @[]
        for a in live:
          let m = a.mapAnchor(cs)
          inc fuzzOutcomes[c].anchorChecks
          # FUZZ-2: inside [0, len] OR a typed non-survived fate. Both arms
          # counted, so "every anchor survived" and "every anchor died" are
          # both visible in the report.
          if m.fate == mapSurvived:
            if m.position < 0 or m.position > nextDoc.len:
              inc fuzzOutcomes[c].outOfRange
            stillLive.add Anchor(pos: m.position, side: a.side,
                                 surface: a.surface, id: a.id)
          else:
            inc fuzzOutcomes[c].typedFates
            inc dead
        live = stillLive
        var st: MapStats
        ds = mapDecorationSet(ds, cs, st)
        for v in ds.ranges.allValues():
          inc fuzzOutcomes[c].decoChecks
          if v.fromAnchor.pos < 0 or v.toAnchor.pos > nextDoc.len:
            inc fuzzOutcomes[c].outOfBounds
          if v.toAnchor.pos < v.fromAnchor.pos: inc fuzzOutcomes[c].unordered
        let vs = ds.ranges.allValues()
        for i in 1 ..< vs.len:
          if vs[i].fromAnchor.pos < vs[i - 1].fromAnchor.pos:
            inc fuzzOutcomes[c].unordered
        if nextDoc.len != doc.len: inc fuzzOutcomes[c].movedRows
        doc = nextDoc

proc buildFuzz() =
  let docs = genDocs(Seed)
  for c in 0 ..< CorpusClassCount:
    var r = initRng(Seed xor uint32(0xF2F7 + c))
    for d in docs:
      if classOfDocId(d.id) != c + 1: continue
      # CAUGHT AND COUNTED, for the same reason `buildSetPopulation` catches
      # (see there): `mapRangeSet`'s §36a guard raises when the skip predicate
      # and `mapPos` disagree, and an exception at module scope makes every
      # case in the file disappear — which is indistinguishable from a run in
      # which they all passed if the only signal read is an exit status.
      try:
        buildFuzzDoc(c, d, r)
      except CatchableError:
        inc fuzzOutcomes[c].raised

buildFuzz()

# ===========================================================================
# THE SUITES
# ===========================================================================

suite "PLAT-28 — the population, before anything is quantified over it":

  test "the seed, the realised edit kinds and the anchor count are printed and asserted":
    echo "  seed: 0x" & toHex(int64(Seed), 8)
    echo "  documents: " & $pop.docs & "  transactions: " & $pop.transactions
    echo "  distinct anchors: " & $pop.distinctAnchors &
         "  anchor observations: " & $pop.anchorObservations
    counted pop.docs == CorpusDocs.len
    # THE GATE'S TWO FLOORS, ASSERTED OF THE REALISED STREAM rather than
    # claimed of the generator.
    counted pop.transactions >= 1000
    counted pop.distinctAnchors >= 50
    counted pop.transactions == pop.docs * AnchorEditKindCount * Salts
    counted pop.distinctAnchors == pop.docs * SitesPerDoc * SideCount
    # AND THE OBSERVATION COUNT, WHICH WAS PRINTED ABOVE AND NOT ASSERTED. Every
    # transaction is observed at every anchored site, on both sides, so the
    # figure is fully determined by the two counts already asserted — which is
    # exactly why leaving it printed-only was a number nobody could be wrong
    # about out loud. An observation stream that quietly stopped visiting one
    # site per document would still print a large, plausible total.
    counted pop.anchorObservations == pop.transactions * SitesPerDoc * SideCount
    # EVERY DRAW REALISED THE CLASS IT WAS DRAWN FOR — an EQUALITY, per class,
    # against that class's draw count (§34's second rule). Non-emptiness is
    # satisfied by a broken generator; this is not.
    for ki, cls in AnchorEditKinds:
      checkpoint($cls & ": " & $pop.editKindRealised[ki] & " of " &
                 $pop.editKindCounts[ki])
      counted pop.editKindCounts[ki] == pop.docs * Salts
      counted pop.editKindRealised[ki] == pop.editKindCounts[ki]
    # AND EVERY CHANGE SET OBEYS THE EDIT RULE THE ORACLE RESTS ON.
    counted pop.ruleWitnessed == pop.transactions

  test "the deleted-text, boundary-side and wrapped-line classes are EQUALITIES, each witnessed":
    # §34, four milestones running. The analogue here is a generator producing
    # only decorations whose text is never edited, or only anchors in unwrapped
    # lines — and each of the three is asserted as an equality against a count
    # derived from the population's own shape, not as a floor.
    #
    # DELETED TEXT. `clsPureDelete` removes site 0, `clsReplace` removes site
    # 1, and `clsMultiSection` removes both. Two anchors per site, so per draw:
    # 2 + 2 + 4 = 8 non-survived observations.
    let perDoc = Salts * (2 + 2 + 4)
    checkpoint("deleted-text observations: " & $pop.deletedText)
    counted pop.deletedText == pop.docs * perDoc
    counted pop.deletedText > 0
    # BOUNDARY SIDE. `clsPureInsert` inserts exactly at site 0's anchor and
    # nothing else does, so the count is one per `clsPureInsert` draw.
    checkpoint("boundary-side inserts: " & $pop.sideAtBoundary)
    # `clsPureInsert` and `clsMultiSection` each insert exactly at one anchor.
    counted pop.sideAtBoundary == 2 * pop.docs * Salts
    counted pop.sideAtBoundary > 0
    # WRAPPED LINES. `LAW-C7`'s wrap arm is taken on a line that WRAPS with the
    # widget and does not without it, and the witness is recorded per class so
    # a class whose chosen line stopped wrapping fails by name.
    # THE REALISED COUNT, not the array's length. `wrappedWitnesses` is an
    # `array[CorpusClassCount, string]`, so `.len` is a COMPILE-TIME CONSTANT
    # equal to `CorpusClassCount` — the equality that stood here could not fail,
    # in a case whose title says its assertions are EQUALITIES. What can fail is
    # the number of classes that actually witnessed a wrap.
    var wrapWitnessed = 0
    for c in 0 ..< CorpusClassCount:
      if wrappedWitnesses[c].len > 0 and
         reflowCells[c].decoRows > reflowCells[c].plainRows: inc wrapWitnessed
    counted wrapWitnessed == CorpusClassCount
    for c in 0 ..< CorpusClassCount:
      checkpoint("class " & $(c + 1) & " wrapped witness: " &
                 wrappedWitnesses[c])
      counted wrappedWitnesses[c].len > 0
      # `== 2`, NOT `>= 2`, AND THE EXACT VALUE IS PROVABLE. The wrap column is
      # `lineWidth + W - 1`, so the decorated line is `lineWidth + W` cells wide
      # — exactly ONE cell past the column — and one cell past a wrap column
      # produces two rows and cannot produce three. A floor here would be
      # satisfied by a projection that wrapped the line four times.
      counted reflowCells[c].decoRows == 2
      counted reflowCells[c].plainRows == 1

  test "the reachability table is two-sided and its cardinality is asserted":
    # NINE `(edit kind, fate)` cells are reachable; the matrix's cells are
    # `(side, fate, edit kind)`, so the reachable count is nine times the two
    # sides — EIGHTEEN of thirty, which is the number the fate matrix reports.
    counted ReachableCells == 9
    counted ReachableCells * SideCount == 18
    counted Reachable.len == AnchorEditKindCount
    counted Reachable[0].len == AnchorFateCount
    # THE OTHER DIRECTION: every `true` cell was realised by the population and
    # every `false` cell was not. A table nobody compared against a run is a
    # comment with square brackets.
    var realised = 0
    for ki in 0 ..< AnchorEditKindCount:
      for fi in 0 ..< AnchorFateCount:
        var n = 0
        for o in observations:
          if o.cls == AnchorEditKinds[ki] and o.fate == FateOrder[fi]: inc n
        if n > 0: inc realised
        checkpoint($AnchorEditKinds[ki] & " x " & fateName(FateOrder[fi]) &
                   ": " & $n)
        counted (n > 0) == Reachable[ki][fi]
    counted realised == ReachableCells

  test "the DECORATION population realises all four arms, as EQUALITIES":
    # §4b one level down. A generated set that only ever held marks would leave
    # three of `decoration`'s four arms unexercised by `LAW-D3`, `LAW-D4` and
    # `FUZZ-7` alike, and every one of them would stay green.
    let docs = genDocs(Seed)
    var r = initRng(Seed xor 0xDEC0'u32)
    var hist: array[DecoClassCount, int]
    var sets = 0
    for d in docs:
      let ad = plantSentinels(d)
      let ds = genDecorations(ad, r, DecorationsPerDoc)
      inc sets
      counted ds.len == DecorationsPerDoc
      for dec in ds.payloads:
        inc hist[ord(classifyDecoration(dec))]
    counted sets == CorpusDocs.len
    for k in 0 ..< DecoClassCount:
      checkpoint($DecoClass(k) & ": " & $hist[k])
      # AN EQUALITY, not a floor: the arms cycle, so each is exactly a quarter
      # of every set.
      counted hist[k] == sets * (DecorationsPerDoc div DecoClassCount)
      counted hist[k] > 0
    counted DecoClassCount == DecorationKindCount

  test "the corpus filter matched TWO documents in every class, in both directions":
    var total = 0
    for c in 1 .. CorpusClassCount:
      var n = 0
      for d in docsOfClass(c): inc n
      checkpoint("class " & $c & ": " & $n & " documents")
      counted n == 2
      total += n
    counted total == CorpusDocs.len
    counted CorpusClassCount == 9

# ---------------------------------------------------------------------------
# LAW-D1 — 2 sides x 3 fates x 5 edit kinds, the declared cross product
# ---------------------------------------------------------------------------

suite "PLAT-28 — LAW-D1, anchors track their text against an independent oracle":

  for si, side in SideOrder:
    for fi, fate in FateOrder:
      for ki, cls in AnchorEditKinds:
        let cellName = "LAW-D1 anchor: " & sideName(side) & " x " &
                       fateName(fate) & " x " & $cls
        test cellName:
          var seen = 0
          var agreed = 0
          var disagreements: seq[string] = @[]
          for o in observations:
            if o.side != side or o.fate != fate or o.cls != cls: continue
            inc seen
            if o.agreedWithOracle: inc agreed
            elif disagreements.len < 4:
              disagreements.add o.docId & " " & fateName(o.fate) & " landing " &
                $o.landing
          for d in disagreements: checkpoint(d)
          checkpoint("observations: " & $seen & ", agreed: " & $agreed)
          if Reachable[ki][fi]:
            # REACHABLE: the cell was realised AND every observation in it
            # agreed with the sentinel re-scan.
            counted seen > 0
            counted agreed == seen
          else:
            # UNREACHABLE BY CONSTRUCTION, asserted rather than omitted. A
            # model change that makes this combination happen is red here and
            # nowhere else.
            counted seen == 0
          note(lawD1, 2)

# ---------------------------------------------------------------------------
# LAW-D2 — the fate is TYPED and REPORTED, per surface
# ---------------------------------------------------------------------------

suite "PLAT-28 — LAW-D2, a deleted anchor has a typed fate":

  for surface in AnchorSurface:
    for fate in FateOrder:
      test "LAW-D2 fate: " & $surface & " x " & fateName(fate):
        var seen = 0
        var reported = 0
        var refusedPosition = 0
        for o in observations:
          if o.surface != surface or o.fate != fate: continue
          inc seen
          # THE FATE IS REPORTED RATHER THAN A PLAUSIBLE NEIGHBOURING POSITION.
          # The oracle said whether the text is gone; the model said a fate;
          # the two must agree, and that is the whole of the law.
          if (o.fate == mapSurvived) == o.oracleSaid: inc reported
          if o.fate != mapSurvived: inc refusedPosition
        checkpoint($surface & " x " & fateName(fate) & ": " & $seen &
                   " observations")
        counted seen > 0
        counted reported == seen
        if fate != mapSurvived: counted refusedPosition == seen
        else: counted refusedPosition == 0
        note(lawD2, 3)

  test "LAW-D2's refusal is EXECUTED: `position` raises on a non-survived fate":
    # §36a, and it is the assertion that makes the "typed" in "typed fate" mean
    # something: a model that returned the collapse point as a POSITION would
    # be indistinguishable from one that survived, and `landingOf` is the
    # caller's explicit decision to accept a neighbour.
    let cs = changeSet(10, 3, 7, "")
    let a = anchorAt(5, sideBefore, asBreakpoint, 1)
    let m = a.mapAnchor(cs)
    counted m.fate == mapCollapsed
    counted m.landingOf == 3
    var raised = false
    try:
      discard m.position
    except AnchorError:
      raised = true
    counted raised
    # AND IT IS FALSIFIABLE: a survivor answers.
    let s = anchorAt(9, sideBefore, asBreakpoint, 2).mapAnchor(cs)
    counted s.fate == mapSurvived
    counted s.position == 5
    note(lawD2, 5)

# ---------------------------------------------------------------------------
# LAW-D3 / LAW-D4 — the two operations §8.0 names, per edit kind
# ---------------------------------------------------------------------------

suite "PLAT-28 — LAW-D3, chunk-skipping mapping equals walking":

  for ki, cls in AnchorEditKinds:
    test "LAW-D3 x " & $cls:
      let o = setOutcomes[ki]
      checkpoint($cls & ": " & $o.equalSets & " of " & $o.comparedPairs &
                 " equal, " & $o.skipped & " chunks skipped, " & $o.walked &
                 " walked, " & $o.dropped & " values dropped")
      counted o.comparedPairs == CorpusDocs.len
      # NO CELL RAISED. `mapRangeSet`'s own §36a guard fires when the skip
      # predicate and `mapPos` disagree, which is `LAW-D3`'s published killer
      # arriving as an exception rather than as a wrong answer — so the law
      # asserts BOTH: nothing raised, and what did not raise agreed.
      counted o.raised == 0
      counted o.equalSets == o.comparedPairs
      # THE FAST PATH WAS TAKEN. Without this the law compares the walked path
      # with itself, which is §4 in one number.
      counted o.skipped > 0
      counted o.walked > 0
      counted o.inBounds == o.comparedPairs
      note(lawD3, 5)

suite "PLAT-28 — LAW-D4, set comparison over a span is sound":

  for ki, cls in AnchorEditKinds:
    test "LAW-D4 x " & $cls:
      let o = setOutcomes[ki]
      checkpoint($cls & ": " & $o.differingPairs & " differing, " &
                 $o.identicalPairs & " identical, " & $o.soundSpans &
                 " sound spans, " & $o.emptyWhenEqual & " empty-when-equal")
      counted o.differingPairs + o.identicalPairs == o.comparedPairs
      # SOUNDNESS: every reported span contains every actual difference.
      counted o.soundSpans == o.differingPairs
      # AND THE OTHER SIDE, which is the published killer's whole subject: a
      # comparison that always returned an empty span would satisfy soundness
      # and fail here.
      counted o.emptyWhenEqual == o.identicalPairs
      if cls == clsEmpty:
        # The identity moves nothing, so EVERY pair is identical — the arm that
        # proves the `none` answer is reachable.
        counted o.identicalPairs == o.comparedPairs
      else:
        counted o.differingPairs > 0
      note(lawD4, 5)

# ---------------------------------------------------------------------------
# LAW-D5 — the order is total, and it is the DECLARED order
# ---------------------------------------------------------------------------

type OrderAxiom = enum
  oaTotal, oaAntisymmetric, oaTransitive, oaStable

const OrderAxiomCount = ord(high(OrderAxiom)) - ord(low(OrderAxiom)) + 1

proc ordersFor(kind: DecorationKind): seq[DecoOrder] =
  ## The orders one decoration kind can legally take, with offsets that RUN
  ## AGAINST the class order — a smaller class with a larger offset, and the
  ## reverse — because a population whose offsets agree with its classes cannot
  ## see the published killer at all.
  result = @[]
  case kind
  of dkMark: result.add decoOrder(ocInlineBefore, 7)
  of dkInlineWidget:
    result.add decoOrder(ocInlineBefore, -3)
    result.add decoOrder(ocInlineAfter, -DecoOffsetBound)
  of dkBlockWidget:
    for p in BlockPlacement: result.add decoOrder(orderClassOf(p), DecoOffsetBound)
  of dkLine: result.add decoOrder(ocLine, 0)
  # Every kind is compared against the WHOLE band, so a kind whose own arm
  # yields one class still exercises the class comparison.
  result.add decoOrder(ocBlockBefore, DecoOffsetBound)
  result.add decoOrder(ocBlockAfter, -DecoOffsetBound)
  result.add decoOrder(ocLine, DecoOffsetBound)
  result.add decoOrder(ocInlineBefore, -DecoOffsetBound)
  # **A DELIBERATE DUPLICATE, FOR EVERY KIND.** Stability is only observable on
  # a pair with EQUAL orders, and on the first run only `dkBlockWidget`
  # happened to produce one — so the arm that makes the sort unstable was
  # MISDIRECTED, killing one cell of four for a reason about the draw rather
  # than about the kind (§36's fourth rule: an arm whose kill depends on a draw
  # is an arm that is sometimes a survivor).
  result.add result[0]

suite "PLAT-28 — LAW-D5, decoration order at one position is a TOTAL order":

  for kind in DecorationKind:
    for axiom in OrderAxiom:
      test "LAW-D5 " & $axiom & " x " & $kind:
        let xs = ordersFor(kind)
        counted xs.len >= 5
        case axiom
        of oaTotal:
          for a in xs:
            for b in xs:
              let lt = a < b
              let gt = b < a
              let eq = a == b
              # Trichotomy: exactly one.
              counted (ord(lt) + ord(gt) + ord(eq)) == 1
        of oaAntisymmetric:
          for a in xs:
            for b in xs:
              if a < b: counted not (b < a)
        of oaTransitive:
          for a in xs:
            for b in xs:
              for c in xs:
                if a < b and b < c: counted a < c
        of oaStable:
          # SORTING IS STABLE AND THE RESULT IS THE DECLARED BAND ORDER.
          # `sortedAtPosition` is the routine under test; the expected sequence
          # is built by band, never by calling it.
          var ds: seq[Decoration] = @[]
          for i, o in xs:
            ds.add decoration(i, 0, 0, markPayload("m" & $i),
                              order = o, useDefaultOrder = false)
          let s = decorationSet(ds)
          let got = s.sortedAtPosition(0)
          counted got.len == xs.len
          for i in 1 ..< got.len:
            counted not (got[i].order < got[i - 1].order)
            # STABILITY: equal orders keep their declaration order.
            if got[i].order == got[i - 1].order:
              counted got[i].value.id > got[i - 1].value.id
        # §36 — THE PUBLISHED KILLER IS NOT OBSERVABLE BY THE THREE ORDER
        # AXIOMS ALONE, AND THIS IS THE REPAIR TO THE ASSERTION.
        # `(offset, class)` compared lexicographically is ALSO a total order:
        # antisymmetric, transitive, trichotomous. What it is not is the
        # DECLARED band order. So every cell also asserts that the class
        # dominates, over pairs whose offsets run the other way.
        for a in xs:
          for b in xs:
            if ord(a.cls) < ord(b.cls): counted a < b
        note(lawD5, 4)

# ---------------------------------------------------------------------------
# LAW-C7 — the reflow, over the corpus's nine classes, in BOTH arms
# ---------------------------------------------------------------------------

suite "PLAT-28 — LAW-C7, an inline widget occupies columns":

  for c in 0 ..< CorpusClassCount:
    test "LAW-C7 x class " & $(c + 1) & " x with the widget":
      let cell = reflowCells[c]
      checkpoint(cell.docId & " line " & $cell.line & ": text at byte " &
                 $cell.byteAt & " sits at column " & $cell.decoColumn &
                 " with a widget of " & $cell.widgetCells &
                 " cells, and at " & $cell.plainColumn & " without it")
      # NON-VACUITY FIRST: a widget of zero cells makes both arms equal and the
      # law says nothing (§4).
      counted cell.widgetCells > 0
      counted cell.plainColumn > 0
      # **THE MEASUREMENT.** C + W.
      counted cell.decoColumn == cell.plainColumn + cell.widgetCells
      inc lawC7Checks

    test "LAW-C7 x class " & $(c + 1) & " x without the widget":
      let cell = reflowCells[c]
      # §7b: THE NEGATIVE CONTROL, AND IT IS FALSIFIABLE. "The text is after
      # the widget" is also true of a renderer that draws everything at column
      # 0, so the arm without the widget has to put the text somewhere ELSE —
      # at C, which is the column the undecorated projection reports.
      let doc = docById(cell.docId)
      let noWrap = WrapSettings(wrapColumn: 0, policy: ReflowPolicy)
      let plain = initWrapCache(doc, noWrap)
      counted plain.toDisplay(textPos(cell.line, cell.byteAt)).column ==
        cell.plainColumn
      counted cell.plainColumn != cell.decoColumn
      # AND THE ARM THAT DISTINGUISHES "after it" FROM "after it IN CELLS":
      # class 5 is CJK and class 4 is ambiguous-width, so at least one cluster
      # after the widget occupies two cells there.
      # CLASS 5 IS CJK: a wide cluster follows the widget at EVERY policy.
      if c + 1 == 5: counted cell.hasWideCluster
      # CLASS 4 IS AMBIGUOUS-WIDTH: narrow at `awNarrow`, wide at `awWide`, and
      # both halves are asserted so "the policy is read" cannot be satisfied by
      # ignoring it.
      if c + 1 == 4:
        counted not cell.hasWideCluster
        counted cell.wideAtWidePolicy
      inc lawC7Checks

  for c in 0 ..< CorpusClassCount:
    test "LAW-C7 wrap arm x class " & $(c + 1):
      let cell = reflowCells[c]
      checkpoint(wrappedWitnesses[c] & ": " & $cell.plainRows &
                 " row(s) plain, " & $cell.decoRows & " with the widget")
      # **THE CLAIM A HOST-DRAWN OVERLAY CANNOT MAKE.** The wrap column is
      # derived from the line's own width, so the two arms differ in the widget
      # and in nothing else.
      counted cell.wrapAt == cell.lineWidth + cell.widgetCells - 1
      counted cell.plainRows == 1
      # EXACTLY TWO, DERIVED FROM THE LINE ABOVE. `wrapAt` is one cell short of
      # the decorated width, so the line passes the column by one cell: two rows,
      # never three. `>= 2` is a floor where an equality is provable, and a floor
      # cannot tell a correct wrap from a projection that wraps every cluster.
      counted cell.decoRows == 2
      inc lawC7Checks

# ---------------------------------------------------------------------------
# FUZZ-2 and FUZZ-7, over the corpus's nine classes
# ---------------------------------------------------------------------------

suite "PLAT-28 — FUZZ-2, every anchor resolves or reports a typed fate":

  for c in 0 ..< CorpusClassCount:
    test "FUZZ-2 x class " & $(c + 1):
      let o = fuzzOutcomes[c]
      checkpoint("class " & $(c + 1) & ": " & $o.steps & " steps, " &
                 $o.anchorChecks & " anchor checks, " & $o.typedFates &
                 " typed fates, " & $o.outOfRange & " out of range")
      counted o.steps == 2 * FuzzSteps      # two documents per class
      counted o.anchorChecks > 0
      counted o.outOfRange == 0
      counted o.raised == 0
      # BOTH ARMS REACHED: a stream in which nothing was ever deleted would
      # make the typed-fate half of the invariant vacuous.
      counted o.typedFates > 0

suite "PLAT-28 — FUZZ-7, every decoration range stays in bounds and ordered":

  for c in 0 ..< CorpusClassCount:
    test "FUZZ-7 x class " & $(c + 1):
      let o = fuzzOutcomes[c]
      checkpoint("class " & $(c + 1) & ": " & $o.decoChecks &
                 " decoration checks, " & $o.outOfBounds & " out of bounds, " &
                 $o.unordered & " unordered")
      counted o.decoChecks > 0
      counted o.outOfBounds == 0
      counted o.unordered == 0
      counted o.movedRows > 0
      # NOTHING RAISED. The decoration set is mapped through `mapRangeSet`,
      # whose skip predicate carries its own §36a guard; an exception there is
      # a `LAW-D3` defect arriving in the fuzz stream and is counted rather
      # than allowed to take the file down with it.
      counted o.raised == 0

# ===========================================================================
# THE SUITE'S OWN NON-VACUITY — the subjects, the scans, and the raises
# ===========================================================================

import std/[algorithm, os, sequtils]

const
  AnchorSource = staticRead("../../editor/anchor.nim")
  RangeSetSource = staticRead("../../editor/range_set.nim")
  DecorationSource = staticRead("../../editor/decoration.nim")
  InlaySource = staticRead("../../editor/inlay.nim")
  RowProjectionSource = staticRead("../../editor/row_projection.nim")
  WrapSource = staticRead("../../editor/wrap.nim")
  GeneratorSource = staticRead("../generators/decoration_generator.nim")

const ScannedModules = ["anchor.nim", "change_set.nim", "decoration.nim",
                        "document_version.nim", "editor_state.nim",
                        "history.nim",
                        "inlay.nim", "operations.nim", "range_set.nim",
                        "reconcile.nim", "rope.nim", "row_projection.nim",
                        "selection.nim", "selection_ops.nim",
                        "seq_line_store.nim", "text_store.nim",
                        "transaction.nim", "wrap.nim"]
  ## GREW BY TWO ON 2026-09-18, and the growth is §35's guard doing its job
  ## rather than maintenance: PLAT-29 added `document_version.nim` and
  ## `reconcile.nim` to the directory this list claims to cover, and THIS
  ## SUITE WENT RED until they were named here. A hardcoded subject list that
  ## cannot see a new file in its own directory is the trap; a hardcoded list
  ## compared against a directory walk in both directions is the remedy.

const EditorDirModules = block:
  ## **§35: THE SUBJECT LIST IS THE DIRECTORY, NOT A LIST SOMEBODY MAINTAINS.**
  ## `staticRead` takes a string literal, so the constants above are frozen at
  ## the moment they were written and a FOURTEENTH module in the same directory
  ## would be unscanned, uncounted and unmissed. A compile-time `walkDir` runs
  ## in the VM and therefore works on every backend this suite compiles to.
  var xs: seq[string] = @[]
  for kind, path in walkDir(currentSourcePath().parentDir.parentDir.parentDir /
                            "editor"):
    if kind == pcFile and path.endsWith(".nim"):
      xs.add path.extractFilename
  sort(xs)
  xs

const NewModules = block:
  var xs: seq[(string, string)] = @[]
  xs.add ("anchor.nim", AnchorSource)
  xs.add ("range_set.nim", RangeSetSource)
  xs.add ("decoration.nim", DecorationSource)
  xs.add ("inlay.nim", InlaySource)
  xs.add ("row_projection.nim", RowProjectionSource)
  xs

proc codeOnly(src: string): string =
  ## Comment lines dropped. Every header here DISCUSSES clamps, overlays and
  ## `mapPos` at length, and a scan that counted prose would be a scan whose
  ## answer changes when somebody improves a doc comment.
  var lines: seq[string] = @[]
  for raw in src.splitLines():
    let t = raw.strip()
    if t.startsWith("#"): continue
    let hash = raw.find(" #")
    lines.add(if hash >= 0: raw[0 ..< hash] else: raw)
  lines.join("\n")

const OracleForbidden = ["mapPos", "mapAnchor", "changeSet", "ChangeSet",
                         "sections", "compose(", "rebase(", "mapPosOr"]
  ## The spellings the oracle may not contain. A NAMED CONST rather than a
  ## literal in the loop, so the population the scan runs over has a
  ## cardinality a case can assert — a list that became empty would iterate
  ## nothing and satisfy every "must not contain" written over it (§4), and
  ## that is the arm.

const OracleRegionStart = "func occurrences*(hay, needle: string): int ="
const OracleRegionEnd = "# The five edit kinds"

proc oracleRegion(): string =
  let a = GeneratorSource.find(OracleRegionStart)
  let b = GeneratorSource.find(OracleRegionEnd)
  if a < 0 or b < 0 or b <= a: return ""
  codeOnly(GeneratorSource[a ..< b])

const AllowedCoreImports = ["import std/options", "import std/strutils",
                            "import ./anchor", "import ./change_set",
                            "import ./decoration", "import ./range_set",
                            "import ../../../common/view_vocabulary/editor_rows"]
  ## **THE WHOLE IMPORT SET THE FOUR STATE MODULES MAY HAVE.** Everything on it
  ## is `std` or a sibling in this directory or the shared row vocabulary; none
  ## of it reaches a renderer, a terminal text module, an event loop or a
  ## filesystem. The list's cardinality is asserted, so an entry added to make a
  ## scan pass is an edit somebody makes on purpose.

proc importLinesOf(src: string): seq[string] =
  ## Every `import` line of a module, comments stripped. `export` lines are not
  ## collected: an export names a module already imported, so checking both
  ## would double-count without widening the claim.
  result = @[]
  for raw in codeOnly(src).splitLines():
    let t = raw.strip()
    if t.startsWith("import "): result.add t

proc raises(body: proc ()): bool =
  try:
    body()
    false
  except CatchableError:
    true

suite "PLAT-28 — the suite's own non-vacuity":

  test "the law set's cardinality is asserted and every law names its killer":
    counted LawCount == 5
    var ids: seq[string] = @[]
    for l in LawId:
      counted LawName[l].len > 0
      counted LawName[l].startsWith("LAW-D")
      # §3: *"an arm with no stated killer is not admitted"*, at the suite's own
      # end. The floor gate checks the other end.
      counted LawKiller[l].len >= 15
      ids.add LawName[l]
    counted deduplicate(ids).len == LawCount
    # EVERY LAW RAN. A law declared and never exercised is the shape that makes
    # a five-row table mean three.
    for l in LawId:
      checkpoint(LawName[l] & " ran " & $lawChecks[l] & " check(s)")
      counted lawChecks[l] > 0
    # AND `LAW-C7`, WHICH IS §3.3's AND WAS DEFERRED TO THIS MILESTONE BY
    # PLAT-27. It is counted separately because the floor gate's two-way count
    # is over §3.4's five, and the deferral is expired by REMOVING `LAW-C7`
    # from that gate's `LAW_DEFERRED` for PLAT-27 — which fails unless this
    # suite runs it.
    checkpoint("LAW-C7 ran " & $lawC7Checks & " check(s)")
    counted lawC7Checks == 3 * CorpusClassCount

  test "THE ORACLE IS NOT THE MAPPING FUNCTION — §30a, on the BODY":
    # §30a: a CORRECT re-derivation on one side of a differential makes both
    # sides agree and the test measure nothing, and **no assertion about the
    # answer can see it**. The only instrument that can is a scan of the
    # control's own text, and this is it.
    let region = oracleRegion()
    # NON-VACUITY FIRST: a region that came back empty satisfies every "must
    # not contain" written over it (§4).
    counted region.len > 400
    counted region.contains("func findMarker*")
    counted region.contains("func oracleOf*")
    counted region.contains("proc plantSentinels*")
    counted OracleForbidden.len == 8
    for forbidden in OracleForbidden:
      checkpoint("the oracle must not spell " & forbidden)
      counted not region.contains(forbidden)
    # AND THE THING IT MUST SPELL, so the scan is two-sided: the oracle's whole
    # content is a literal search of the NEW DOCUMENT.
    counted region.contains("hay[i ..< i + needle.len] == needle")

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
    # THIRTEEN, THEN FIFTEEN, AND SEVENTEEN SINCE PLAT-30 PUT
    # `operations.nim` AND `editor_state.nim` IN THE SAME DIRECTORY — all three
    # moves on 2026-09-18. The literal is deliberate and is NOT redundant with
    # the two-sided comparison above: without it, a directory walk that matched
    # nothing and a list that had been emptied would agree with each other
    # perfectly (§4). Forcing this edit is the whole job it does.
    counted ScannedModules.len == 18
    counted NewModules.len == 5

  test "NO CLAMP REPAIRS AN ANCHOR — every unreachable path RAISES":
    # §36a: *"an anchor clamped into range makes a fate look total"*. The five
    # new modules contain no clamp at all, and the raises are EXECUTED rather
    # than only scanned — a `raise` nobody has seen fire is a branch nobody has
    # run.
    for (name, src) in NewModules:
      checkpoint(name)
      let code = codeOnly(src)
      counted code.len > 500
      counted not code.contains("clamp(")
      counted code.contains("raise newException")
    # THE ANCHOR'S OWN REFUSALS.
    counted raises(proc () = discard anchorAt(-1, sideBefore))
    # `position` REFUSES a non-survived fate rather than answering the landing:
    # a caller that wants a plausible neighbour asks `landingOf` by name.
    counted raises(proc () =
      discard anchorAt(5, sideBefore).mapAnchor(
        changeSet(10, 3, 7, "")).position)
    # `mapPos` refuses a position outside the document rather than clamping it.
    counted raises(proc () =
      discard anchorAt(99, sideBefore).mapAnchor(identityChangeSet(4)))
    # THE RANGE SET'S.
    counted raises(proc () = discard rangeValue(0, 5, 2))
    counted raises(proc () = discard rangeValue(-1, 0, 2))
    counted raises(proc () = discard rangeSet([], 0))
    counted raises(proc () =
      var st: CompareStats
      discard compareOver(rangeSet([]), rangeSet([]), 5, 2, st))
    # THE DECORATION'S — and this is the one the reference CLAMPS.
    counted raises(proc () = discard decoOrder(ocLine, DecoOffsetBound + 1))
    counted raises(proc () = discard decoOrder(ocLine, -DecoOffsetBound - 1))
    counted raises(proc () = discard inlineWidget(-1))
    counted raises(proc () = discard blockWidget(-1))
    counted raises(proc () = discard decorationSet(@[]).decorationById(7))
    # THE INLAY'S.
    counted raises(proc () = discard inlayPlacement(-1, 2, 0))
    counted raises(proc () =
      discard inlayLineMetrics("abc", ReflowPolicy,
        [inlayPlacement(2, 1, 0), inlayPlacement(1, 1, 1)]))
    counted raises(proc () =
      discard inlayLineMetrics("abc", ReflowPolicy, [inlayPlacement(9, 1, 0)]))
    # THE PROJECTION'S CODEC.
    counted raises(proc () = discard markOfClass("ct-mark-typo"))
    counted raises(proc () = discard pointerOfClass(""))
    counted raises(proc () = discard flowOfClass("ct-flow"))
    counted raises(proc () = discard editorValueOf("no separator here"))
    counted raises(proc () =
      discard inlineTextOf(EditorValue(name: "a = b", value: "c")))
    # AND THE GUARDS ARE FALSIFIABLE: the legal call does NOT raise.
    counted not raises(proc () = discard anchorAt(0, sideBefore))
    counted not raises(proc () = discard decoOrder(ocLine, DecoOffsetBound))
    counted not raises(proc () = discard markOfClass(MarkClassBreakpoint))

  test "A DECORATED CACHE REFUSES THE SPLICE rather than dropping its widgets":
    # §36a again, and this one is a DROP rather than a clamp: `updateWrapCache`
    # recomputes a touched line's metrics from its TEXT, and a widget is not in
    # the text — so splicing a decorated projection would quietly un-decorate
    # exactly the lines being edited.
    let doc = "alpha beta\ngamma\n"
    let settings = WrapSettings(wrapColumn: 0, policy: ReflowPolicy)
    let ds = decorationSet(@[decoration(0, 3, 3, inlineWidget(4, "v = 1"))])
    let deco = inlayWrapCache(doc, settings, ds)
    let cs = changeSet(doc.len, 0, 0, "x")
    counted raises(proc () =
      discard updateWrapCache(deco, doc, cs, cs.apply(doc)))
    # AND THE UNDECORATED CACHE STILL SPLICES, which is what makes the refusal
    # a property of the widgets rather than of the routine.
    let plain = initWrapCache(doc, settings)
    counted not raises(proc () =
      discard updateWrapCache(plain, doc, cs, cs.apply(doc)))
    # THE ROUTINE THAT DOES IT PROPERLY.
    var st: MapStats
    let (moved, movedDeco) = updateInlayCache(doc, cs, cs.apply(doc), settings,
                                              ds, st)
    counted moved.rowCount == deco.rowCount
    counted movedDeco.len == ds.len
    counted movedDeco.payloads[0].value.fromAnchor.pos == 4

  test "THE TWO ARMS OF THE REFLOW ARE ONE CODE PATH — §30a on the control":
    # The negative control is *"the same line without the widget and nothing
    # else changed"*. If `initWrapCache` were a second loop rather than the
    # undecorated arm of `wrapCacheOfMetrics`, the two arms would differ in the
    # constructor as well as in the widget, and a defect in either loop would
    # make them agree for the wrong reason.
    let code = codeOnly(WrapSource)
    counted code.contains("proc wrapCacheOfMetrics*(")
    counted code.count("proc wrapCacheOfMetrics*(") == 1
    counted code.contains("wrapCacheOfMetrics(doc, settings, ms)")
    # `wrapLine` is still declared once and still only in this module.
    counted code.count("func wrapLine*(") == 1
    for (name, src) in NewModules:
      checkpoint(name)
      counted not codeOnly(src).contains("func wrapLine*(")

  test "`projectionLines` and `wrap.documentLines` agree over every corpus document":
    # §30's remedy when a second copy genuinely cannot be avoided (see
    # `row_projection.nim`'s header — importing `wrap` would put
    # `isonim_tui/text/width` into the GPUI front-end's compile): grade the two
    # copies against each other rather than trusting the comment.
    var linesCompared = 0
    for d in CorpusDocs:
      let a = wrap.documentLines(d.text)
      let b = projectionLines(d.text)
      counted a.len == b.len
      for i in 0 ..< a.len:
        if a[i] != b[i]: checkpoint(d.id & " line " & $i)
        inc linesCompared
      counted wrap.lineStartOffsetsOf(d.text) == projectionLineStarts(d.text)
    counted linesCompared > 1000
    checkpoint("lines compared: " & $linesCompared)

  test "THE PROJECTION DOES NOT REACH A RENDERER OR THE TERMINAL'S TEXT MODULE":
    # PLAT-28's own version of PLAT-27's dependency-inversion scan, and it has
    # a second job here: `row_projection.nim` is callable from
    # `frontend/view_vocabulary/editor_surface.nim`, which the `gpui-shell`
    # lane compiles WITHOUT isonim_tui flags. An import added here would be a
    # terminal dependency in the GPUI front-end.
    #
    # **THE SCAN IS OVER THE IMPORT LINES, NOT OVER THE FILE**, and the repair
    # is worth the sentence because the first spelling went red on a STRING
    # LITERAL: `decoration.nim`'s filed gap `PLAT28-DG4` names
    # `isonim_tui/text/width` in its own measurement text, and a
    # forbidden-substring scan over the whole module cannot tell a dependency
    # from a sentence about one (§4d, in the other direction — prose moving a
    # scan's answer). Extracting the imports and comparing them against an
    # ALLOW-LIST is also strictly stronger: it fails on a renderer import that
    # nobody thought to forbid.
    counted AllowedCoreImports.len == 7
    var importsChecked = 0
    for name in ["anchor.nim", "range_set.nim", "decoration.nim",
                 "row_projection.nim"]:
      var src = ""
      for (n, s) in NewModules:
        if n == name: src = s
      checkpoint(name)
      counted src.len > 500
      let imports = importLinesOf(src)
      # NON-VACUITY: every one of these modules imports SOMETHING, so a
      # extractor that returned nothing would satisfy the allow-list.
      counted imports.len > 0
      for line in imports:
        checkpoint(name & ": " & line)
        counted line in AllowedCoreImports
        inc importsChecked
    counted importsChecked >= 8
    # AND THE ASYMMETRY IS THE POINT: `inlay.nim` DOES reach the width module,
    # through `wrap`, because a cell is what it measures.
    counted codeOnly(InlaySource).contains("import ./wrap")
    counted codeOnly(WrapSource).contains("import isonim_tui/text/width")

  test "THE SHRINKER EXISTS AND IS TESTED BY A PLANTED ALWAYS-FAILING PROPERTY":
    # §4.5: *"a failing property that reports a 400-transaction counterexample
    # has found a defect nobody will fix … The shrinker is itself tested, by a
    # planted always-failing property whose minimal counterexample is known."*
    let big = AnchorDraw(docIndex: 13, cls: clsMultiSection,
                         sites: SitesPerDoc, salt: 7'u32)
    counted isValidDraw(big)
    counted shrinkCandidates(big).len == 3
    # THE PLANTED PROPERTY: every draw fails. The minimal counterexample is
    # therefore the smallest VALID draw — one site, document 0, the empty edit
    # kind — and it is known in advance, which is what makes this a test of the
    # shrinker rather than a run of it.
    let minimal = shrink(big, proc (x: AnchorDraw): bool = true)
    counted minimal.sites == 1
    counted minimal.docIndex == 0
    counted minimal.cls == clsEmpty
    checkpoint("shrunk: " & describe(big) & " -> " & describe(minimal))
    # AND A PROPERTY THAT ONLY FAILS ON THE MULTI-SECTION KIND SHRINKS TO A
    # DIFFERENT MINIMUM, so the shrinker is not simply returning the smallest
    # draw whatever it is handed.
    let other = shrink(big, proc (x: AnchorDraw): bool =
      x.cls == clsMultiSection)
    counted other.cls == clsMultiSection
    counted other.sites == 1
    counted other.docIndex == 0

suite "PLAT-28 — the tally":
  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
