## PLAT-29 — the COUNTED STALENESS REPORT, the drop count in both directions,
## and the edit-latency figure taken under a mid-flight producer.
##
## Subjects: `viewmodel/editor/{document_version,reconcile}.nim`.
##
## =========================================================================
## WHY THE DROP COUNT IS THE MILESTONE'S CENTRAL NUMBER
## =========================================================================
##
## Editor-ViewModel.md §11: *"Dropping is reported, not silent. A highlight
## result discarded for staleness is a normal event; a stream of them is a
## defect, and the only way to tell the two apart is to count them."*
##
## The verification gate states the consequence for the suite itself: **a suite
## where the drop count is zero is a suite that never reached the code it
## grades.** So the count is asserted in BOTH directions here — greater than
## zero under an edit storm, and exactly zero when nothing moves — because
## either half alone is satisfied by a reconciler that has one answer.
##
## Every one of the five drop reasons is realised by a case of its own, by
## name. A reason that no stream ever produces is a row in an enum that looks
## like coverage (Verification-Harness-Traps §32a), and two of them —
## `drVersionForgotten` and `drCarriedDeleted` — are NOT realised by the laws
## suite's schedule. That is a measured fact rather than an assumption: the
## schedule's own printed `REASONS:` line shows both at zero, which is exactly
## why they are here.
##
## =========================================================================
## THE LATENCY FIGURE IS REPORTED WITH ITS LOAD, NEVER ASSERTED AGAINST A
## CONSTANT — §28a
## =========================================================================
##
## Verification-Harness-Traps §28: *"an inequality between two independently
## noisy measurements, asserted against an exact constant, is a coin flip."*
## The six latency cases below assert **that a figure was taken and recorded**,
## with the load it was taken under, and they assert nothing about its
## magnitude.
##
## The property they exist for is asserted STRUCTURALLY in the same cases and
## does not depend on a clock at all: with a producer in flight, the number of
## transactions the model applies is exactly the number requested, every
## version is published, and the producer's answer is reconciled only when it
## is handed back. An edit that waited would show up as a missing version, not
## as a slow one — and a missing version is an equality.
##
## **THE LOAD IS SYNTHETIC AND SELF-INFLICTED, and that is deliberate.**
## `/proc/loadavg` does not exist on two of this suite's three backends, so a
## figure labelled with the host's load would be a figure labelled differently
## depending on where it ran. The three loads here are declared amounts of
## work this process does between edits, which is reproducible, portable, and
## is the thing the claim is actually about: a producer occupying the machine.
##
## §29: every assertion goes through `counted`, which is a template.
##
## Compile and run (from the repository root):
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_editor_async_examples.nim

import std/[strutils, times, unittest]

import ../../editor/change_set
import ../../editor/document_version
import ../../editor/reconcile
import ../generators/async_generator

var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 143
  ## Asserted by the last case against the runtime tally.

const Seed = 0x29e0a11e'u32

const StormEdits = 64
  ## Edits in the storm. Enough that a request issued at its start is stale by
  ## the time it lands, which is the whole point of a storm.

const LoadLevels = [0, 2000, 8000]
  ## The three declared loads, as units of synthetic work between edits. Named
  ## rather than drawn so the reported figure carries a load a reader can
  ## reproduce.

const LatencyTakes = 2
  ## §28a: two takes, reported. One measurement is a sample of size one and
  ## nothing here compares it to anything.

let ClassDocs = docsOneNumberPerClass(Seed)

# ---------------------------------------------------------------------------
# Helpers. None of these asserts, so none of them is a template (§29).
# ---------------------------------------------------------------------------

proc issueAt(vd: VersionedDocument; site: AsyncSite;
             producer: ProducerKind): ProducerResult =
  let view = oracleSite(vd.text, site)
  producerResult(producer, vd.version, vd.text.len,
                 view.regionFrom, view.regionTo,
                 carried = @[view.regionFrom, view.regionTo],
                 payload = site.leftMarker)

proc burn(units: int): int =
  ## Synthetic work. The result is RETURNED and asserted on by the caller so
  ## the optimiser cannot delete the loop — a load that was compiled away is a
  ## load whose figure is about a different program.
  result = 1
  for i in 1 .. units:
    result = (result * 31 + i) and 0xFFFF

# ===========================================================================
suite "PLAT-29 — the drop count, in both directions":
# ===========================================================================

  test "THE DROP COUNT IS NON-ZERO UNDER AN EDIT STORM":
    # The gate's own wording: *"under the edit storm above, the number of
    # results discarded for staleness is greater than zero — proving the path
    # is exercised."*
    var rep = initStalenessReport()
    var reconciled = 0
    for d in ClassDocs:
      let doc = buildAsyncDoc(d)
      var vd = initVersionedDocument(doc.text)
      var r = initRng(Seed xor uint32(reconciled + 1))
      var inflight: seq[ProducerResult] = @[]
      for p in ProducerKind:
        inflight.add issueAt(vd, doc.sites[ord(p) mod SitesPerDoc], p)
      # THE STORM. Edits keep arriving while the four results are in flight,
      # and every one of them applies synchronously.
      var live = @[0, 1, 2]
      for k in 0 ..< StormEdits:
        if live.len == 0: break
        let si = live[k mod live.len]
        let shape = if k mod 8 == 7: esDestroy
                    elif k mod 3 == 0: esInside
                    else: esOutside
        let cs = editFor(doc, vd.text, doc.sites[si], shape, r)
        discard vd.applyChanges(cs)
        if shape == esDestroy:
          var next: seq[int] = @[]
          for x in live:
            if x != si: next.add x
          live = next
      for res in inflight:
        discard reconcile(vd, res, rep)
        inc reconciled
    for line in rep.reportLines(): echo line
    counted reconciled == ClassDocs.len * ProducerKindCount
    counted rep.total() == reconciled
    counted rep.total(roDropped) > 0
    # AND THE FRESH ARM DID NOT FIRE, which is the half that says the storm
    # really was a storm: nothing survived to `roApplied` because the document
    # moved under every single request.
    counted rep.total(roApplied) == 0
    for p in ProducerKind:
      checkpoint($p & ": " & $rep.count(p, roDropped) & " dropped of " &
                 $rep.total(p) & " (" & $rep.dropPermille(p) & "/1000)")
      counted rep.count(p, roDropped) > 0

  test "AND IT IS EXACTLY ZERO WHEN THE DOCUMENT DOES NOT MOVE":
    # The other direction. Without it, "greater than zero" is satisfied by a
    # reconciler that drops everything — which would also be a defect, and a
    # louder one.
    var rep = initStalenessReport()
    for d in ClassDocs:
      let doc = buildAsyncDoc(d)
      var vd = initVersionedDocument(doc.text)
      for p in ProducerKind:
        let res = issueAt(vd, doc.sites[ord(p) mod SitesPerDoc], p)
        let verdict = reconcile(vd, res, rep)
        counted verdict.outcome == roApplied
    counted rep.total(roDropped) == 0
    counted rep.total(roMapped) == 0
    counted rep.total(roApplied) == ClassDocs.len * ProducerKindCount
    for p in ProducerKind:
      counted rep.dropPermille(p) == 0

  test "drVersionForgotten is realised, by name":
    # NOT realised by the laws suite's schedule — its printed `REASONS:` line
    # shows it at zero — so it gets a case of its own. A reason nothing ever
    # produces is a row that looks like coverage (§32a).
    var rep = initStalenessReport()
    let doc = buildAsyncDoc(ClassDocs[0])
    var vd = initVersionedDocument(doc.text)
    var r = initRng(Seed xor 0xf0f0f0f0'u32)
    let res = issueAt(vd, doc.sites[0], pkInlineValues)
    discard vd.applyChanges(editFor(doc, vd.text, doc.sites[1], esOutside, r))
    discard vd.applyChanges(editFor(doc, vd.text, doc.sites[1], esOutside, r))
    counted vd.knows(res.computedAgainst)
    vd.forget(vd.version)
    counted not vd.knows(res.computedAgainst)
    let verdict = reconcile(vd, res, rep)
    counted verdict.outcome == roDropped
    counted verdict.reason == drVersionForgotten
    counted rep.reasonCount(drVersionForgotten) == 1
    # THE TWIN: the same request against a timeline that has NOT forgotten is
    # mapped, so the drop above is attributable to the forgetting and to
    # nothing else.
    var vd2 = initVersionedDocument(doc.text)
    var r2 = initRng(Seed xor 0xf0f0f0f0'u32)
    let res2 = issueAt(vd2, doc.sites[0], pkInlineValues)
    discard vd2.applyChanges(editFor(doc, vd2.text, doc.sites[1], esOutside, r2))
    discard vd2.applyChanges(editFor(doc, vd2.text, doc.sites[1], esOutside, r2))
    counted reconcile(vd2, res2, rep).outcome == roMapped

  test "drEvidenceEdited is realised, by name":
    var rep = initStalenessReport()
    let doc = buildAsyncDoc(ClassDocs[0])
    var vd = initVersionedDocument(doc.text)
    var r = initRng(Seed xor 0x0e0e0e0e'u32)
    let res = issueAt(vd, doc.sites[0], pkTreeSitter)
    counted staleRule(pkTreeSitter) == srTextDerived
    discard vd.applyChanges(editFor(doc, vd.text, doc.sites[0], esInside, r))
    let verdict = reconcile(vd, res, rep)
    counted verdict.outcome == roDropped
    counted verdict.reason == drEvidenceEdited
    # The markers are STILL THERE — the region was not deleted, it was edited,
    # and the distinction is the entire content of the reason.
    counted oracleSite(vd.text, doc.sites[0]).present

  test "drEvidenceDeleted is realised, by name":
    var rep = initStalenessReport()
    let doc = buildAsyncDoc(ClassDocs[0])
    var vd = initVersionedDocument(doc.text)
    var r = initRng(Seed xor 0x0d0d0d0d'u32)
    let res = issueAt(vd, doc.sites[0], pkInlineValues)
    counted staleRule(pkInlineValues) == srAnchorLive
    discard vd.applyChanges(editFor(doc, vd.text, doc.sites[0], esDestroy, r))
    let verdict = reconcile(vd, res, rep)
    counted verdict.outcome == roDropped
    counted verdict.reason == drEvidenceDeleted
    counted not oracleSite(vd.text, doc.sites[0]).present

  test "drCarriedDeleted is realised, by name":
    # The reason the laws suite's schedule never reaches: a result whose
    # evidence region SURVIVES while a position it carries does not. It needs a
    # carried position OUTSIDE the region, which is a shape the schedule's
    # results do not have — and a reason nothing reaches is a reason nothing
    # tests.
    var rep = initStalenessReport()
    let doc = buildAsyncDoc(ClassDocs[0])
    var vd = initVersionedDocument(doc.text)
    let view = oracleSite(vd.text, doc.sites[1])
    # The prefix — everything before the FIRST site's block — is the one
    # stretch of this document that no evidence region covers, so deleting it
    # leaves site 1's region alive and takes a carried position with it.
    let prefixEnd = oracleSite(vd.text, doc.sites[0]).blockFrom
    counted prefixEnd >= 2
    let res = producerResult(pkFileWrite, vd.version, vd.text.len,
                             view.regionFrom, view.regionTo,
                             carried = @[1], payload = "prefix anchor")
    discard vd.applyChanges(changeSet(vd.text.len, 0, prefixEnd, ""))
    let verdict = reconcile(vd, res, rep)
    counted verdict.outcome == roDropped
    counted verdict.reason == drCarriedDeleted
    # THE TWIN: the same result with the same edit and NO carried position is
    # mapped, so the drop is attributable to the carried position alone.
    var vd2 = initVersionedDocument(doc.text)
    let res2 = producerResult(pkFileWrite, vd2.version, vd2.text.len,
                              view.regionFrom, view.regionTo,
                              payload = "prefix anchor")
    discard vd2.applyChanges(changeSet(vd2.text.len, 0, prefixEnd, ""))
    counted reconcile(vd2, res2, rep).outcome == roMapped

# ===========================================================================
suite "PLAT-29 — the counted staleness report":
# ===========================================================================

  test "the report's cells sum to the number of reconciliations, per producer and overall":
    var rep = initStalenessReport()
    var n = 0
    for p in ProducerKind:
      for o in ReconcileOutcome:
        let reason = if o == roDropped: drEvidenceEdited else: drNotDropped
        for k in 0 .. ord(p):
          rep.record(p, o, reason)
          inc n
    counted rep.total() == n
    var perProducer = 0
    for p in ProducerKind:
      counted rep.total(p) == ReconcileOutcomeCount * (ord(p) + 1)
      perProducer += rep.total(p)
    counted perProducer == n
    var perOutcome = 0
    for o in ReconcileOutcome:
      perOutcome += rep.total(o)
    counted perOutcome == n
    counted rep.reasonCount(drNotDropped) + rep.reasonCount(drEvidenceEdited) == n

  test "dropPermille is a ratio of the counts it is derived from, and zero denominators do not divide":
    var rep = initStalenessReport()
    # An untouched producer: no reconciliations at all.
    counted rep.total(pkFileRead) == 0
    counted rep.dropPermille(pkFileRead) == 0
    # One in four.
    rep.record(pkTreeSitter, roDropped, drEvidenceEdited)
    for k in 0 .. 2: rep.record(pkTreeSitter, roMapped, drNotDropped)
    counted rep.total(pkTreeSitter) == 4
    counted rep.dropPermille(pkTreeSitter) == 250
    # All of them.
    rep.record(pkFileWrite, roDropped, drEvidenceDeleted)
    counted rep.dropPermille(pkFileWrite) == 1000
    # None of them.
    rep.record(pkInlineValues, roApplied, drNotDropped)
    counted rep.dropPermille(pkInlineValues) == 0

  test "reportLines renders every producer, every outcome and every reason":
    # A report nobody can read is a counter with no consumer. The rendering is
    # asserted for CONTENT rather than for shape, in both directions: every
    # enum member appears, and the line count is the cardinality plus the two
    # summary rows.
    var rep = initStalenessReport()
    rep.record(pkTreeSitter, roDropped, drEvidenceEdited)
    rep.record(pkFileRead, roMapped, drNotDropped)
    let lines = rep.reportLines()
    counted lines.len == ProducerKindCount + 2
    let joined = lines.join("\n")
    for p in ProducerKind:
      counted joined.contains($p)
    for o in ReconcileOutcome:
      counted joined.contains($o)
    for reason in DropReason:
      counted joined.contains($reason)
    counted joined.contains("drop/1000=")
    counted ($rep).startsWith("StalenessReport")

  test "a drop reason that disagrees with its outcome is refused, not reconciled":
    # Both directions of the same refusal, executed. A counter that accepted
    # either would report a drop total and a reason total that do not add up,
    # and nothing downstream could tell which of the two was wrong.
    var rep = initStalenessReport()
    var refused = 0
    try:
      rep.record(pkTreeSitter, roApplied, drEvidenceEdited)
    except ReconcileError:
      inc refused
    try:
      rep.record(pkTreeSitter, roDropped, drNotDropped)
    except ReconcileError:
      inc refused
    counted refused == 2
    counted rep.total() == 0
    # AND THE AGREEING PAIRS ARE ACCEPTED, so the refusals above are not
    # satisfied by a counter that refuses everything.
    rep.record(pkTreeSitter, roApplied, drNotDropped)
    rep.record(pkTreeSitter, roDropped, drEvidenceEdited)
    counted rep.total() == 2

# ===========================================================================
suite "PLAT-29 — edit latency under a mid-flight producer":
# ===========================================================================

  for loadIdx in 0 ..< LoadLevels.len:
    for take in 1 .. LatencyTakes:
      test "EDIT LATENCY AT LOAD " & $LoadLevels[loadIdx] & ", TAKE " & $take:
        # §28a: the figure is REPORTED WITH ITS LOAD and asserted against
        # nothing. What IS asserted is the structural property the whole
        # boundary exists for, and it needs no clock: with a producer in
        # flight, every requested edit applied and every version was published.
        let doc = buildAsyncDoc(ClassDocs[loadIdx mod ClassDocs.len])
        var vd = initVersionedDocument(doc.text)
        var r = initRng(Seed xor uint32(loadIdx * 16 + take))
        var rep = initStalenessReport()
        # THE PRODUCER GOES IN FLIGHT FIRST and is not touched again until
        # after every edit has landed.
        let res = issueAt(vd, doc.sites[0], pkTreeSitter)
        let startVersion = vd.version
        var sink = 0
        let t0 = epochTime()
        for k in 0 ..< StormEdits:
          sink += burn(LoadLevels[loadIdx])
          discard vd.applyChanges(
            editFor(doc, vd.text, doc.sites[2], esOutside, r))
        let elapsed = epochTime() - t0
        # THE LOAD REALLY RAN. A load the optimiser deleted is a figure about a
        # different program.
        if LoadLevels[loadIdx] == 0:
          counted sink == StormEdits
        else:
          counted sink > StormEdits
        # THE STRUCTURAL PROPERTY, as equalities.
        counted distanceBetween(startVersion, vd.version) == StormEdits
        counted vd.historyLen == StormEdits
        counted rep.total() == 0      # nothing was reconciled while editing
        # AND THE PRODUCER'S ANSWER IS STILL RECONCILABLE AFTERWARDS.
        let verdict = reconcile(vd, res, rep)
        counted rep.total() == 1
        counted verdict.outcome in {roMapped, roDropped}
        # THE FIGURE, REPORTED. Never compared to a constant.
        echo "LATENCY: load=" & $LoadLevels[loadIdx] & " take=" & $take &
             " edits=" & $StormEdits &
             " wall_ms=" & formatFloat(elapsed * 1000.0, ffDecimal, 3) &
             " per_edit_us=" &
             formatFloat(elapsed * 1_000_000.0 / float(StormEdits),
                         ffDecimal, 2)
        counted elapsed >= 0.0

# ===========================================================================
suite "PLAT-29 — the tally":
# ===========================================================================
  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
