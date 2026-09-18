## async_generator.nim — PLAT-29's POPULATION: documents carrying SENTINEL-
## bracketed evidence regions, the four edit shapes the reconciliation laws are
## quantified over, and the oracle that says what should have happened.
##
## NOT-A-TEST-LANE-FILE: the population's constructor, its classifier and the
## reconciliation oracle. The assertions are in
## `../unit/test_editor_async_laws.nim`.
##
## =========================================================================
## THE ORACLE IS A SENTINEL RE-SCAN AND IT MUST NOT BE THE RECONCILER
## =========================================================================
##
## Verification-Harness-Traps §30a: *"a CORRECT re-derivation on one side of a
## differential test makes both sides agree and the test measure nothing"*, and
## no assertion about the ANSWER can see one — only a scan of the control's own
## body can.
##
## This milestone is the sharpest instance the campaign has had, because the
## thing under test is *"did this stale result get applied"* and the obvious
## oracle is a second copy of the staleness decision. So the oracle here is
## `string.find` and `==` over bytes:
##
##     ... prefix [[L1]]REGION[[R1]] gap [[L2]]REGION[[R2]] ...
##                       ^^^^^^ the evidence region
##
##   * both markers present -> the region still exists, and the bytes between
##     them are the region's current text;
##   * those bytes equal to the issue-time region -> the text under the
##     evidence did NOT change;
##   * a marker missing -> the region was destroyed.
##
## Nothing in `oracleSite` names a change set, a section, a side or `mapPos`.
## It could be written by somebody who had never read `change_set.nim`, and
## `test_editor_async_laws.nim` asserts that on its BODY with a forbidden-token
## list whose cardinality is asserted.
##
## =========================================================================
## THE EDIT RULE THAT MAKES THE ORACLE TOTAL
## =========================================================================
##
## Every edit this generator draws obeys exactly one of three shapes, and
## `witnessShape` re-reads the BUILT change set rather than trusting the
## constructor (§34's third rule: the classifier must not be the constructor):
##
##   1. `esOutside`  — entirely outside every `[[L..]] … [[R..]]` block;
##   2. `esInside`   — strictly inside one site's region, touching neither
##      marker;
##   3. `esDestroy`  — covering one site's whole block, so BOTH markers go
##      together.
##
## A partially cut marker would be a fourth state the oracle could not read,
## and it is excluded by construction rather than handled. `esNone` is the
## fourth member of the enum and is not an edit at all: it is the schedule
## saying *nothing happened between the request and its answer*, which is the
## arm that makes `roApplied` decidable.
##
## =========================================================================
## WHY THE SCHEDULE IS EXPLICIT RATHER THAN DRAWN
## =========================================================================
##
## Verification-Harness-Traps §34 in the form this milestone was warned about:
## *a generator that never produces a stale result, so reconciliation is never
## exercised.* A uniform draw over shapes would produce all three eventually
## and would give the suite no number to assert — "eventually" is the word that
## turns an equality into a non-emptiness test.
##
## So `schedule` is a declared cross product: every `(producer, shape)` pair,
## repeated. The suite asserts the REALISED per-cell counts against the
## SCHEDULED ones as equalities. A reconciler that silently classified
## everything as `roMapped` would fail twelve cells at once, and a generator
## that stopped producing one shape would fail the cells that shape feeds — the
## two failures are distinguishable, which is the whole reason the counts are
## equalities rather than `> 0`.

import std/strutils

import ../../editor/change_set
import ../../editor/reconcile
import ./change_generator
import ../corpus/unicode_corpus

export change_generator
export reconcile

type
  EditShape* = enum
    ## What happened to a site between a request being issued and its answer
    ## arriving. Closed; the suite sweeps every member.
    esNone      ## nothing was applied — the `roApplied` arm
    esOutside   ## an edit that touched no site
    esInside    ## an edit strictly inside one site's region
    esDestroy   ## an edit that removed one site's whole block

  AsyncSite* = object
    ## One evidence region, bracketed by two sentinels.
    index*: int
    leftMarker*, rightMarker*: string
    regionText*: string
      ## The bytes between the markers AT THE MOMENT THE SITE WAS BUILT. The
      ## oracle compares against this and against nothing derived.

  AsyncDoc* = object
    id*: string
    text*: string
    sites*: seq[AsyncSite]

  SiteView* = object
    ## Where a site is in SOME document, found by re-scanning for its markers.
    present*: bool
    regionFrom*, regionTo*: int   ## the half-open evidence region
    blockFrom*, blockTo*: int     ## the whole `[[L..]] … [[R..]]` span
    text*: string                 ## the bytes between the markers

const
  SitesPerDoc* = 3
    ## Three and not one: a law quantified over a single site cannot tell an
    ## edit that missed THE site from an edit that missed EVERY site, and the
    ## `esOutside` arm is exactly the one that distinction is about.

  EditShapeCount* = ord(high(EditShape)) - ord(low(EditShape)) + 1
    ## Derived from the enum (Conformance Suite §10.4 rule 3).

  SiteClusters* = 2
    ## Clusters per region. TWO, because `esInside` needs a cluster boundary
    ## STRICTLY inside the region to edit at, and a one-cluster region has
    ## none — its only interior positions are inside a grapheme cluster, which
    ## is the one edit this campaign's whole storage layer exists to refuse.

  PrefixClusters* = 2
    ## Clusters before the first site. `esOutside` edits here, and a document
    ## whose first site started at byte 0 would leave `esOutside` with nowhere
    ## to go that was not also `esDestroy`.

  GapClusters* = 2
    ## Clusters between two sites, so `esDestroy` on one leaves the next
    ## intact and `esOutside` has somewhere to land between them.

func leftMarkerFor*(k: int): string = "[[L" & $k & "]]"
func rightMarkerFor*(k: int): string = "[[R" & $k & "]]"

func shapeName*(s: EditShape): string =
  ## Spelled once. A case name composed from `$s` would read `esDestroy`,
  ## which is a Nim identifier rather than a description of what happened.
  case s
  of esNone: "no edit"
  of esOutside: "an edit outside every site"
  of esInside: "an edit inside the region"
  of esDestroy: "the region deleted"

# ---------------------------------------------------------------------------
# THE ORACLE — `string.find` and `==`, and nothing else
# ---------------------------------------------------------------------------

proc oracleSite*(text: string; site: AsyncSite): SiteView =
  ## Where `site` is in `text`, by looking for its two markers.
  ##
  ## **THIS IS THE ORACLE.** It knows nothing about change sets, sections,
  ## sides or positions-that-moved; it re-reads the document that is in front
  ## of it and reports what it finds. That is what makes it evidence about the
  ## reconciler rather than a second call to it.
  ##
  ## Deliberately naive and deliberately slow: two whole-document scans per
  ## site per step. A faster version would have to remember where the markers
  ## used to be, and remembering where something used to be is the reconciler's
  ## job.
  let l = text.find(site.leftMarker)
  let r = text.find(site.rightMarker)
  if l < 0 or r < 0 or r < l:
    return SiteView(present: false)
  let regionFrom = l + site.leftMarker.len
  SiteView(present: true, regionFrom: regionFrom, regionTo: r,
           blockFrom: l, blockTo: r + site.rightMarker.len,
           text: text[regionFrom ..< r])

proc oracleShape*(before, after: string; site: AsyncSite): EditShape =
  ## What the ORACLE says happened to `site` between two documents.
  ##
  ## The classifier, and it is not the constructor: it reads two documents and
  ## reports, and `witnessShape` in the suite compares its verdict against the
  ## shape the schedule asked for. A generator that labelled its own output
  ## would make the label true by construction, which is §34's third rule and
  ## the defect `G3` performs in PLAT-28's harness.
  let b = oracleSite(before, site)
  let a = oracleSite(after, site)
  if not a.present: return esDestroy
  if not b.present: return esDestroy   # unreachable under the edit rule; see
                                       # the suite's totality case
  if a.text != b.text: return esInside
  if before == after: return esNone
  esOutside

proc expectedOutcome*(shape: EditShape; rule: StaleRule): ReconcileOutcome =
  ## What the reconciliation of a result issued before `shape` happened MUST
  ## be, given the producer's declared rule.
  ##
  ## This is the schedule's intent, derived from the DECLARED table and the
  ## oracle's shape — never from the reconciler. The two `srTextDerived` /
  ## `srAnchorLive` rows are the entire content of *"which one is a property of
  ## the producer"*, and they are the rows a reviewer disputes one at a time.
  case shape
  of esNone: roApplied
  of esOutside: roMapped
  of esInside:
    # The bytes under the evidence changed. A text-derived answer was computed
    # FROM those bytes and is now a guess; an anchored answer is about
    # something else and only needed somewhere to live.
    if rule == srTextDerived: roDropped else: roMapped
  of esDestroy: roDropped

# ---------------------------------------------------------------------------
# THE POPULATION
# ---------------------------------------------------------------------------

proc buildAsyncDoc*(d: GenDoc): AsyncDoc =
  ## One corpus window, with `SitesPerDoc` sentinel-bracketed regions spliced
  ## into it at cluster boundaries.
  ##
  ## Deterministic in `d` and nothing else: the window `d` already carries was
  ## drawn from the seed, and a second draw here would make two runs with the
  ## same seed disagree about which document they were.
  ##
  ## REFUSES rather than narrows. A window too small for the layout raises by
  ## name; silently packing the sites closer together would produce documents
  ## in which `esOutside` has nowhere to land and the arm would go on being
  ## counted while measuring nothing (§4b's partial sweep wearing the right
  ## label).
  let bs = d.boundaries
  let need = PrefixClusters + SitesPerDoc * (SiteClusters + GapClusters) + 1
  if bs.len < need:
    raise newException(ValueError,
      "async generator: document " & d.id & " offers " & $bs.len &
      " cluster boundaries, fewer than the " & $need &
      " a layout of " & $SitesPerDoc & " sites needs")

  var text = ""
  var sites: seq[AsyncSite] = @[]
  var at = 0          # boundary index into `bs`
  text.add d.text[bs[at] ..< bs[at + PrefixClusters]]
  at += PrefixClusters
  for k in 0 ..< SitesPerDoc:
    let regionText = d.text[bs[at] ..< bs[at + SiteClusters]]
    at += SiteClusters
    let site = AsyncSite(index: k,
                         leftMarker: leftMarkerFor(k),
                         rightMarker: rightMarkerFor(k),
                         regionText: regionText)
    text.add site.leftMarker
    text.add regionText
    text.add site.rightMarker
    sites.add site
    text.add d.text[bs[at] ..< bs[at + GapClusters]]
    at += GapClusters

  # UNIQUENESS IS ASSERTED, NOT ASSUMED. `find` reports the FIRST occurrence,
  # so a marker that also occurs in the corpus text would make the oracle
  # answer about the wrong bytes — and it would answer confidently.
  for s in sites:
    if text.count(s.leftMarker) != 1 or text.count(s.rightMarker) != 1:
      raise newException(ValueError,
        "async generator: marker " & s.leftMarker & "/" & s.rightMarker &
        " is not unique in document " & d.id &
        ". The oracle is `find`, and `find` answers about the first one.")
  AsyncDoc(id: d.id, text: text, sites: sites)

proc interiorBoundary*(doc: AsyncDoc; text: string; site: AsyncSite): int =
  ## A cluster boundary strictly inside `site`'s region in `text`, or -1.
  ##
  ## Re-segments the CURRENT region rather than remembering the issue-time
  ## offsets: after an `esOutside` edit the region has moved, and an offset
  ## remembered from before it is an offset into a document that is gone.
  let view = oracleSite(text, site)
  if not view.present: return -1
  let inner = text[view.regionFrom ..< view.regionTo]
  let bs = clusterBoundaries(inner)
  for b in bs:
    if b > 0 and b < inner.len:
      return view.regionFrom + b
  -1

proc editFor*(doc: AsyncDoc; text: string; site: AsyncSite;
              shape: EditShape; r: var Rng): ChangeSet =
  ## A change set over `text` realising `shape` against `site`.
  ##
  ## `esNone` is the identity, which is a change set like any other and NOT a
  ## special case in the caller: a schedule that branched on "is there an edit"
  ## would have one arm the reconciler never sees.
  case shape
  of esNone:
    identityChangeSet(text.len)
  of esOutside:
    # In the prefix, which is outside every block by construction. An INSERT
    # and not a delete, because a delete in the prefix would also be the only
    # thing that can produce `drCarriedDeleted`, and mixing the two would make
    # the `esOutside` cells depend on a draw.
    changeSet(text.len, 0, 0, corpusClusters(r, 1))
  of esInside:
    let at = interiorBoundary(doc, text, site)
    if at < 0:
      raise newException(ValueError,
        "async generator: site " & $site.index & " of " & doc.id &
        " has no interior cluster boundary; `esInside` cannot be drawn " &
        "against it")
    changeSet(text.len, at, at, corpusClusters(r, 1))
  of esDestroy:
    let view = oracleSite(text, site)
    if not view.present:
      raise newException(ValueError,
        "async generator: site " & $site.index & " of " & doc.id &
        " is already gone; `esDestroy` cannot be drawn against it")
    changeSet(text.len, view.blockFrom, view.blockTo, "")

proc witnessShape*(before: string; cs: ChangeSet; site: AsyncSite): EditShape =
  ## The shape READ BACK off the built change set and the document it applies
  ## to — the second, independent classifier.
  ##
  ## `oracleShape` compares two DOCUMENTS; this one looks at the CHANGE SET's
  ## own changed ranges against the site's block. Two classifiers over two
  ## different inputs agreeing is evidence; one classifier consulted twice is
  ## not.
  let view = oracleSite(before, site)
  var touchedBlock = false
  var coversBlock = false
  var any = false
  for rng in cs.changedRanges(individual = true):
    any = true
    if not view.present: continue
    if rng.fromA <= view.blockFrom and rng.toA >= view.blockTo:
      coversBlock = true
    elif rng.fromA < view.blockTo and rng.toA > view.blockFrom:
      touchedBlock = true
  if not any: return esNone
  if coversBlock: return esDestroy
  if touchedBlock: return esInside
  esOutside

# ---------------------------------------------------------------------------
# THE SCHEDULE
# ---------------------------------------------------------------------------

type ScheduleStep* = object
  producer*: ProducerKind
  shape*: EditShape
  site*: int

proc schedule*(repeats = 1): seq[ScheduleStep] =
  ## Every `(producer, shape)` pair, `repeats` times, cycling the site.
  ##
  ## The cross product is WRITTEN OUT rather than drawn, so the per-cell
  ## expected count is `repeats` and the suite's histogram assertion is an
  ## EQUALITY. `esDestroy` cycles through the sites so no single run destroys
  ## the same site twice, which would raise from `editFor` rather than
  ## silently skipping.
  result = @[]
  var k = 0
  for rep in 0 ..< repeats:
    for p in ProducerKind:
      for s in EditShape:
        result.add ScheduleStep(producer: p, shape: s, site: k mod SitesPerDoc)
        inc k

func corpusClassIds*(): seq[string] =
  ## The distinct corpus classes, derived from `CorpusDocs`' own ids rather
  ## than written as `9`. §10.4 rule 3: a sweep's multiplier is an asserted
  ## cardinality.
  result = @[]
  for d in CorpusDocs:
    let cls = d.id.split('-')[0]
    if cls notin result: result.add cls

proc docsOneNumberPerClass*(seed: uint32): seq[GenDoc] =
  ## One generated document per corpus class, in class order.
  ##
  ## `genDocs` yields one window per corpus DOCUMENT (eighteen: a short and a
  ## long member of each class). The laws below are quantified over CLASSES,
  ## so taking the first window of each class is the population — and taking
  ## it by class id rather than by index means a corpus that grows a tenth
  ## class arrives here rather than being silently cut off at nine.
  let all = genDocs(seed)
  result = @[]
  for cls in corpusClassIds():
    for d in all:
      if d.id.split('-')[0] == cls:
        result.add d
        break
