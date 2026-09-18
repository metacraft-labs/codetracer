## reconcile.nim — PLAT-29: the asynchronous boundary, from the inside.
##
## Owns: Editor-ViewModel.md §11's three rules —
##
##   1. *"An async producer's result names the version it was computed
##      against."*
##   2. *"Dropping is reported, not silent."*
##   3. *"The model never waits. It has no `Future`, no callback, no clock."*
##
## Rule 3 is the one this file could not state for itself, and it is not
## stated here: it is a property of the **import closure** of the whole
## `editor/` directory, checked by `ci/test/editor-import-closure.sh` with the
## same hardened extractor PLAT-7/PLAT-8's gates use. A sentence in a header
## is not a guard; six separate routes past a text scan were already measured
## and closed in `ci/lib/nim-imports.sh`, and re-deriving a seventh scanner
## here would re-open every one of them.
##
## **WHAT THAT GATE REFUSES, NAMED HERE IN PROSE ON PURPOSE.** Nothing in this
## closure may reach `await`, `waitFor`, `runForever`, `asyncCheck`,
## `callSoon`, `addTimer` or `sleep` — the model does not suspend and owns no
## loop; nor `getTime`, `epochTime`, `cpuTime` or `getMonoTime` — a model that
## reads a clock cannot be replayed, cannot be compared across two hosts, and
## cannot have its edit latency measured without the measurement moving under
## it; nor `readFile`, `writeFile`, `readLines`, `openFileStream`,
## `startProcess`, `execCmd` or `newSocket` — a file load is `pkFileRead`, a
## save is `pkFileWrite`, and both of them happen OUTSIDE and arrive here as a
## `ProducerResult`.
##
## Writing them out is not decoration. The gate's check 4 is a name scan over
## CODE LINES, and *"no denied identifier in the closure"* is satisfied for
## free by a comment stripper that returned nothing — §4, and this campaign's
## most common way of passing. Its control needs a module that names one of
## those identifiers in prose and in prose only, and this paragraph is it.
##
## =========================================================================
## THE SHAPE: ONE FUNCTION, FOUR PRODUCERS, THREE OUTCOMES
## =========================================================================
##
## A producer computes **outside** the model, against a version. When its
## answer arrives, `reconcile` decides one of exactly three things:
##
##   * `roApplied`  — the document did not move. The answer is about the
##     document that is here.
##   * `roMapped`   — it moved, and the answer survives being moved through
##     the intervening change sets.
##   * `roDropped`  — it moved, and the answer does not survive.
##
## The set is CLOSED and it is an enum, so a sweep can assert its cardinality.
## An open outcome vocabulary is one a test cannot enumerate, which is the
## same argument §6.3 makes for annotations and effects.
##
## =========================================================================
## DROP-OR-REBASE IS A PROPERTY OF THE PRODUCER, DECLARED IN A TABLE
## =========================================================================
##
## The interesting question is not *what* happens to a stale result but *who
## decides*. Deciding at the call site means the answer depends on which
## caller wrote which `if`, which is how two highlight paths come to disagree
## about whether an edit invalidates a token. So the decision is a `StaleRule`
## attached to the PRODUCER KIND, in `ProducerRules` below, with the reason in
## the same row. `staleRule` is the only reader, and it is the only predicate:
## the suite, the report and the reconciler all go through it
## (Verification-Harness-Traps §30 — one predicate, one function).
##
## The two rules are genuinely different questions about the same delta, and
## the split is about **what the result is evidence OF**:
##
## | rule | invalidated by | because |
## |---|---|---|
## | `srTextDerived` | any edit INSIDE the evidence region | the answer was computed FROM those bytes. Move the bytes and the answer is a guess, however well its coordinates map |
## | `srAnchorLive` | only a DELETION of the evidence region | the answer is about something other than the text — a program state, a file on disk — and an edit elsewhere only moves where it is shown |
##
## And the four producers, each with the region it declares:
##
## | producer | evidence region | rule | what a drop means |
## |---|---|---|---|
## | `pkTreeSitter` | the span the highlight covers | `srTextDerived` | the token was re-typed while the parse was in flight; re-parse |
## | `pkInlineValues` | the anchored point the badge hangs from | `srAnchorLive` | the line holding the value was deleted; there is nowhere to draw it |
## | `pkFileRead` | the byte range the read would fill | `srTextDerived` | applying it would clobber what the user typed while it was in flight |
## | `pkFileWrite` | the byte range the write persisted | `srAnchorLive` | the buffer that was saved is gone (reloaded, truncated), so the ack describes a document that no longer exists |
##
## **A `pkFileWrite` result is not nothing**, which is worth stating because
## the obvious reading is that a write produces no value to reconcile. It
## produces the *saved boundary*: the range that now matches disk. An editor
## draws "these lines differ from what is saved" from exactly that, and a
## late-arriving ack whose boundary has not been moved through the edits that
## happened while the write was in flight marks the wrong lines clean.
##
## =========================================================================
## EVERY POSITION MOVES THROUGH PLAT-25, AND NOTHING MOVES ANY OTHER WAY
## =========================================================================
##
## Two primitives, both already built and both already tested:
##
##   * `change_set.mapPos` moves a POSITION, with a declared side and a typed
##     fate. `LAW-A10` is that it is total.
##   * `change_set.rebase` moves a CHANGE SET — the shape a file read has,
##     since a read is "replace this range with these bytes". `LAW-A1` is that
##     both arms produce the same document.
##
## There is no third. `test_editor_async_laws.nim` asserts that on this file's
## own BODY, with a forbidden-token scan whose cardinality is asserted, for
## Verification-Harness-Traps §30a's reason: a correct re-derivation agrees
## with the original on every input anybody tests, so no assertion about an
## ANSWER can see one. Only a scan of the source can.

import ./change_set
import ./document_version

export document_version

type
  ProducerKind* = enum
    ## The four asynchronous producers §11 names. Closed, and its cardinality
    ## is the multiplier in PLAT-29's floor, so it cannot drift from the
    ## reconciliation table without a gate noticing.
    pkTreeSitter      ## re-parse and re-highlight
    pkInlineValues    ## the DAP data that feeds inline values and provenance
    pkFileRead        ## a file load
    pkFileWrite       ## a file save's acknowledgement

  StaleRule* = enum
    ## What makes a moved result WRONG, as opposed to merely misplaced.
    srTextDerived     ## the answer was computed from the bytes in its region
    srAnchorLive      ## the answer is about something else and only needs a
                      ## place to live

  ReconcileOutcome* = enum
    ## §11's closed set. Every arm is realised by every producer, and the
    ## suite asserts that as twelve EQUALITIES rather than twelve
    ## non-emptiness tests (Verification-Harness-Traps §34).
    roApplied
    roMapped
    roDropped

  DropReason* = enum
    ## Why a drop happened. `roDropped` alone is a number; a stream of drops
    ## is a defect, and the only way to tell WHICH defect is this.
    drNotDropped        ## the result was not dropped — the arm that keeps
                        ## `reasons` two-sided
    drVersionForgotten  ## the timeline no longer holds the intervening changes
    drEvidenceEdited    ## `srTextDerived`, and the delta edited the region
    drEvidenceDeleted   ## the evidence region itself is gone
    drCarriedDeleted    ## a position the result carries is gone

  ProducerResult* = object
    ## What an async producer hands back. It names the version it was computed
    ## against — §11's first rule — and it is the ONLY way into `reconcile`.
    producer*: ProducerKind
    computedAgainst*: DocumentVersion
    evidenceFrom*, evidenceTo*: int
      ## The region of the document AT `computedAgainst` this result is about.
      ## Half-open. A point region (`from == to`) is legal and is what an
      ## inline value uses.
    carried*: seq[int]
      ## Positions in the document AT `computedAgainst` that the result holds
      ## and that must move with the text — a highlight's token boundaries, a
      ## badge's anchor.
    change*: ChangeSet
      ## The document change this result would INSTALL, expressed against the
      ## document at `computedAgainst`. `identityChangeSet` for a producer
      ## that installs none, which keeps one code path rather than two
      ## (§30) — `rebase` of an identity is an identity, and it costs the
      ## length check that catches a result about a different document.
    payload*: string
      ## Opaque to the model. It is here so a test can assert that the value
      ## survived reconciliation unchanged, which is the half a test about
      ## positions alone does not cover.

  Reconciled* = object
    ## The verdict. A variant rather than a tuple with a nullable field: there
    ## is no reading of a dropped result's positions, and a type that offers
    ## them is a type that invites one.
    producer*: ProducerKind
    case outcome*: ReconcileOutcome
    of roApplied, roMapped:
      value*: ProducerResult
        ## Re-expressed against the CURRENT document. For `roApplied` this is
        ## the input unchanged, and that is a fact rather than an accident:
        ## the delta is the identity, so mapping it would be the identity too.
    of roDropped:
      reason*: DropReason

  StalenessReport* = object
    ## §11's second rule, as a value. *"A highlight result discarded for
    ## staleness is a normal event; a stream of them is a defect, and the only
    ## way to tell the two apart is to count them."*
    cells: array[ProducerKind, array[ReconcileOutcome, int]]
    reasons: array[DropReason, int]

  ReconcileError* = object of ValueError
    ## Raised for a result that cannot be about this document at all — one
    ## whose change set has the wrong length, or whose region is out of
    ## bounds. **Never clamped**: §36a, and a clamped region silently reports
    ## a result about bytes that were never examined.

const
  ProducerKindCount* = ord(high(ProducerKind)) - ord(low(ProducerKind)) + 1
  ReconcileOutcomeCount* = ord(high(ReconcileOutcome)) - ord(low(ReconcileOutcome)) + 1
  StaleRuleCount* = ord(high(StaleRule)) - ord(low(StaleRule)) + 1
  DropReasonCount* = ord(high(DropReason)) - ord(low(DropReason)) + 1
    ## Derived from the enums rather than written (Conformance Suite §10.4,
    ## rule 3). PLAT-29's floor multiplies by the first two.

  ProducerRules*: array[ProducerKind, tuple[rule: StaleRule, why: string]] = [
    ## **THE TABLE THE WHOLE BOUNDARY TURNS ON.** Rule and reason in one row,
    ## so a rule cannot be changed without its justification going with it,
    ## and read by exactly one function.
    (srTextDerived,
     "a highlight span's CLASS is computed from the bytes it covers, so an " &
     "edit inside it makes the class a guess however exactly its coordinates " &
     "map. Outside it, the mapping is exact and the span is still true"),
    (srAnchorLive,
     "an inline value is about the PROGRAM's state at a point, not about the " &
     "text at that point. Editing elsewhere on the line moves where the badge " &
     "is drawn and changes nothing about what it says; deleting the anchor " &
     "leaves nowhere to draw it"),
    (srTextDerived,
     "a read's bytes are the file as it was. Installing them over a range the " &
     "user has since typed into would clobber the typing — the one outcome a " &
     "load must never have — while a read landing in untouched territory is " &
     "exactly what `rebase` re-expresses"),
    (srAnchorLive,
     "a write's ack names the range that now matches disk, which is what the " &
     "'differs from saved' decoration is drawn from. An edit elsewhere only " &
     "moves that boundary; a deletion of the range means the buffer that was " &
     "saved is gone and the ack describes a document that no longer exists"),
  ]

func staleRule*(p: ProducerKind): StaleRule =
  ## ONE PREDICATE, ONE FUNCTION (Verification-Harness-Traps §30). The
  ## reconciler, the report and the suite's two-sided table all ask through
  ## here; a second reader spelled as a `case` would agree with itself while
  ## the table said something else.
  ProducerRules[p].rule

func ruleReason*(p: ProducerKind): string =
  ProducerRules[p].why

# ---------------------------------------------------------------------------
# The one predicate about a delta this module owns
# ---------------------------------------------------------------------------

func touchesRegion*(cs: ChangeSet; fromPos, toPos: int): bool =
  ## True when `cs` edits any byte of the half-open old-document region
  ## `[fromPos, toPos)`.
  ##
  ## **THIS IS A PREDICATE, NOT A MAPPING.** It answers *did the text under
  ## this region change*, and it answers it by reading `changedRanges` — the
  ## reporting interface `change_set.nim` already publishes — rather than by
  ## walking sections. Nothing in it produces a position, which is the
  ## property the source scan in `test_editor_async_laws.nim` asserts.
  ##
  ## An edit that ABUTS the region does not touch it, and that is the right
  ## answer for both rules: a token is not re-classified by text typed after
  ## its last byte, and a read is not clobbered by an edit that starts where
  ## it ends. A zero-width insertion falls out of the same comparison — it
  ## touches only when it is strictly inside — with no special case to get
  ## wrong.
  for r in cs.changedRanges(individual = true):
    if r.fromA < toPos and r.toA > fromPos:
      return true
  false

# ---------------------------------------------------------------------------
# Constructors
# ---------------------------------------------------------------------------

proc producerResult*(producer: ProducerKind;
                     computedAgainst: DocumentVersion;
                     docLen: int;
                     evidenceFrom, evidenceTo: int;
                     carried: seq[int] = @[];
                     payload = ""): ProducerResult =
  ## A result that installs no document change — a highlight, a badge, a write
  ## acknowledgement. `docLen` is the document's length at `computedAgainst`,
  ## and it is a PARAMETER rather than something this constructor guesses: the
  ## producer ran outside, against a document it was handed, and a constructor
  ## that filled this in from the current document would make every result
  ## agree with the present by construction.
  ProducerResult(producer: producer, computedAgainst: computedAgainst,
                 evidenceFrom: evidenceFrom, evidenceTo: evidenceTo,
                 carried: carried, change: identityChangeSet(docLen),
                 payload: payload)

proc producerChange*(producer: ProducerKind;
                     computedAgainst: DocumentVersion;
                     change: ChangeSet;
                     evidenceFrom, evidenceTo: int;
                     carried: seq[int] = @[];
                     payload = ""): ProducerResult =
  ## A result that installs a document change — a file read is the case that
  ## exists today. The change's own `length` is the document length at
  ## `computedAgainst`, so there is nothing for a caller to state twice.
  ProducerResult(producer: producer, computedAgainst: computedAgainst,
                 evidenceFrom: evidenceFrom, evidenceTo: evidenceTo,
                 carried: carried, change: change, payload: payload)

# ---------------------------------------------------------------------------
# The report
# ---------------------------------------------------------------------------

func initStalenessReport*(): StalenessReport = StalenessReport()

func count*(rep: StalenessReport; p: ProducerKind;
            o: ReconcileOutcome): int =
  rep.cells[p][o]

func total*(rep: StalenessReport; o: ReconcileOutcome): int =
  for p in ProducerKind:
    result += rep.cells[p][o]

func total*(rep: StalenessReport; p: ProducerKind): int =
  for o in ReconcileOutcome:
    result += rep.cells[p][o]

func total*(rep: StalenessReport): int =
  for p in ProducerKind:
    for o in ReconcileOutcome:
      result += rep.cells[p][o]

func reasonCount*(rep: StalenessReport; r: DropReason): int =
  rep.reasons[r]

func dropPermille*(rep: StalenessReport; p: ProducerKind): int =
  ## Drops per thousand reconciliations for one producer, as an INTEGER.
  ##
  ## Per mille and not a float, and that is a portability decision rather than
  ## a stylistic one: this suite runs on three backends and a float formatted
  ## by `nim js` is not always the string `nim c` prints. A ratio nobody can
  ## compare across the three backends is a ratio that cannot be asserted.
  ##
  ## Zero reconciliations gives zero, which is the honest answer — no drops
  ## were observed — and it is why callers assert the DENOMINATOR separately.
  let n = rep.total(p)
  if n == 0: 0 else: (rep.cells[p][roDropped] * 1000) div n

proc record*(rep: var StalenessReport; producer: ProducerKind;
             outcome: ReconcileOutcome; reason: DropReason) =
  ## The single mutation point. `reconcile` is its only in-tree caller; it is
  ## exported so a harness can build a report for a control without going
  ## through a document.
  if (outcome == roDropped) != (reason != drNotDropped):
    raise newException(ReconcileError,
      "record: outcome " & $outcome & " does not agree with reason " &
      $reason & ". A drop without a reason is a number nobody can act on, " &
      "and a reason without a drop is a count of something that did not " &
      "happen. Neither is clamped into agreement.")
  inc rep.cells[producer][outcome]
  inc rep.reasons[reason]

proc reportLines*(rep: StalenessReport): seq[string] =
  ## The counted staleness report, one line per producer plus the totals and
  ## the reason breakdown. Printed by the suites so the numbers are in the
  ## log rather than only in an assertion.
  result = @[]
  for p in ProducerKind:
    var line = "  " & $p & ":"
    for o in ReconcileOutcome:
      line.add " " & $o & "=" & $rep.cells[p][o]
    line.add "  drop/1000=" & $rep.dropPermille(p)
    result.add line
  var totals = "  TOTAL:"
  for o in ReconcileOutcome:
    totals.add " " & $o & "=" & $rep.total(o)
  result.add totals
  var reasons = "  REASONS:"
  for r in DropReason:
    reasons.add " " & $r & "=" & $rep.reasons[r]
  result.add reasons

proc `$`*(rep: StalenessReport): string =
  result = "StalenessReport\n"
  for line in rep.reportLines():
    result.add line & "\n"

# ---------------------------------------------------------------------------
# THE RECONCILER
# ---------------------------------------------------------------------------

proc reconcile*(vd: VersionedDocument; r: ProducerResult;
                rep: var StalenessReport): Reconciled =
  ## Decide what happens to `r`, count it, and return the verdict.
  ##
  ## Synchronous and total. Every path either returns a `Reconciled` or raises
  ## for an input that cannot describe this document at all — and the raising
  ## paths are the ones a clamp would have hidden (§36a).
  if r.computedAgainst > vd.version:
    raise newException(VersionError,
      "reconcile: a result names " & $r.computedAgainst &
      " and this document is at " & $vd.version &
      ". Versions are minted by `apply` and by nothing else, so this result " &
      "was computed against a document that does not exist. It is NOT " &
      "clamped to the current version: that would report it as fresh, which " &
      "is the exact defect this boundary exists to prevent " &
      "(Verification-Harness-Traps §36a).")

  if not vd.knows(r.computedAgainst):
    rep.record(r.producer, roDropped, drVersionForgotten)
    return Reconciled(producer: r.producer, outcome: roDropped,
                      reason: drVersionForgotten)

  let delta = vd.delta(r.computedAgainst)

  if r.change.length != delta.length:
    raise newException(ReconcileError,
      "reconcile: this result's change set is over " & $r.change.length &
      " bytes and the document at " & $r.computedAgainst & " was " &
      $delta.length & ". The result is about a different document.")
  if r.evidenceFrom < 0 or r.evidenceTo < r.evidenceFrom or
     r.evidenceTo > delta.length:
    raise newException(ReconcileError,
      "reconcile: the evidence region [" & $r.evidenceFrom & ", " &
      $r.evidenceTo & ") is not inside a document of " & $delta.length &
      " bytes. It is not clamped into range: a clamped region reports a " &
      "result about bytes nothing examined (§36a).")
  for p in r.carried:
    if p < 0 or p > delta.length:
      raise newException(ReconcileError,
        "reconcile: a carried position " & $p &
        " is outside a document of " & $delta.length & " bytes.")

  # ARM ONE — the document did not move.
  if delta.isIdentity:
    rep.record(r.producer, roApplied, drNotDropped)
    return Reconciled(producer: r.producer, outcome: roApplied, value: r)

  # ARM THREE, first half — the producer's own rule says the answer is wrong
  # rather than merely misplaced.
  if staleRule(r.producer) == srTextDerived and
     delta.touchesRegion(r.evidenceFrom, r.evidenceTo):
    rep.record(r.producer, roDropped, drEvidenceEdited)
    return Reconciled(producer: r.producer, outcome: roDropped,
                      reason: drEvidenceEdited)

  # ARM THREE, second half — the place the answer lives is gone.
  #
  # The SIDES are `LAW-S4`'s rule, applied to a region rather than to a
  # selection: the start is forward-biased and the end backward-biased, so
  # text inserted at either edge is not swallowed into the region. A highlight
  # that grew to cover text the parser never saw is exactly the failure a
  # single side would produce at one of the two ends.
  let movedFrom = delta.mapPos(r.evidenceFrom, sideAfter)
  let movedTo = delta.mapPos(r.evidenceTo, sideBefore)
  if movedFrom.kind != mapSurvived or movedTo.kind != mapSurvived:
    rep.record(r.producer, roDropped, drEvidenceDeleted)
    return Reconciled(producer: r.producer, outcome: roDropped,
                      reason: drEvidenceDeleted)

  var moved = newSeqOfCap[int](r.carried.len)
  for p in r.carried:
    let m = delta.mapPos(p, sideBefore)
    if m.kind != mapSurvived:
      rep.record(r.producer, roDropped, drCarriedDeleted)
      return Reconciled(producer: r.producer, outcome: roDropped,
                        reason: drCarriedDeleted)
    moved.add m.pos

  # ARM TWO — it moved and the answer survives. The change set moves through
  # THE rebase primitive: `delta` is the one that came first, so the result's
  # own change re-expressed to apply after it is `bOverA`.
  let rebased = rebase(delta, r.change)
  rep.record(r.producer, roMapped, drNotDropped)
  Reconciled(
    producer: r.producer,
    outcome: roMapped,
    value: ProducerResult(
      producer: r.producer,
      computedAgainst: vd.version,
      evidenceFrom: movedFrom.pos,
      evidenceTo: movedTo.pos,
      carried: moved,
      change: rebased.bOverA,
      payload: r.payload))
