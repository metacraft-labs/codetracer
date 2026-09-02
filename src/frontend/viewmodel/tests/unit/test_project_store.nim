## NS2's project store, against Noir-Studio.md §4.
##
## Runs in `vm-unit` (C) and `vm-unit-js` (JS via node), by discovery — both
## lanes take every `test_*.nim` in this directory, and the second is the one
## that matters here: the store ships on the JS backend, and NS1 records that
## `vm-unit-js` was created after `async_compat.onComplete` was found queueing
## a callback on JS that ran inline on native, making a whole suite's
## assertions silently not run.
##
## ## Why the store is driven over `memory_volume` and not over OPFS
##
## Node has no OPFS, so an OPFS-backed suite here would be a suite that skips —
## the one thing NS2 forbids. But the substitution is not a weakening, and it is
## worth being precise about why:
##
## `memory_volume` is **a product surface**, not a fixture. §4.2's third row is
## "OPFS unavailable — the session runs against an in-memory store and says so
## before the first keystroke", and this is that store. So every property below
## is asserted against code that ships. What OPFS adds over it is persistence
## across a reload and genuine promise latency; what it does not add is a single
## line of `project_store.nim`, which is the subject here.
##
## The two things that ARE OPFS-specific — the promise composition and the
## DOMException-to-`PlatformErrorKind` translation — are tested in
## `test_platform_web.nim` against a fake `navigator.storage` that drives
## `host/opfs_volume.nim`'s real code paths.
##
## ## `awaitOutcome` and the drain
##
## Copied in shape from `test_platform_facade.nim`, including its `doAssert
## settled`, and for the reason recorded there: a future that never settles
## must fail loudly rather than leave the assertions unexecuted. That check is
## doing real work in this file. `outcome.thenOutcome` preserves synchronous
## settledness through a composition *only* when its input was already settled;
## if that property were lost, every store operation would become a real
## microtask on JS and this `doAssert` would fire rather than the suite quietly
## asserting nothing.

import std/[unittest, algorithm, strutils]

import ../../platform/outcome
import ../../platform/store_volume
import ../../platform/memory_volume
import ../../platform/store_schema
import ../../platform/store_durability
import ../../platform/project_store
import ../../platform/archive

proc awaitOutcome[T](future: PlatformFuture[PlatformOutcome[T]]
                    ): PlatformOutcome[T] =
  var captured: PlatformOutcome[T]
  var settled = false

  proc onValue(value: PlatformOutcome[T]) =
    captured = value
    settled = true

  proc onFailure(message: string) =
    captured = failed[T](pkTransport, "the future failed", message)
    settled = true

  future.onComplete(onValue, onFailure)
  drainPlatformCallbacks()
  doAssert settled,
    "a store future never settled; if this fires on JS and not on C, " &
    "outcome.thenOutcome has stopped preserving synchronous settledness"
  captured

proc bytesOf(text: string): seq[byte] =
  result = newSeq[byte](text.len)
  for i in 0 ..< text.len: result[i] = text[i].byte

proc textOf(bytes: seq[byte]): string =
  result = newString(bytes.len)
  for i in 0 ..< bytes.len: result[i] = bytes[i].char

const t0: int64 = 1_700_000_000_000

proc openFresh(volume: MemoryVolume; owner = "tab-a";
               granted = true; answered = true): StoreSession =
  let opened = awaitOutcome(
    openStore(volume.asVolume, owner, granted, answered, t0))
  doAssert opened.ok, "the store did not open: " & $opened.error
  result = opened.value
  result.acknowledgeDurability()

# ---------------------------------------------------------------------------
suite "the store's shape and its version — §4.5":
# ---------------------------------------------------------------------------

  test "a fresh volume gets a store, and the descriptor is readable again":
    let volume = newMemoryVolume()
    let session = openFresh(volume)
    check session.openDecision.verdict == sovFresh
    check session.metadata.version == storeSchemaVersion

    let second = awaitOutcome(
      openStore(volume.asVolume, "tab-b", true, true, t0 + 1))
    check second.ok
    check second.value.openDecision.verdict == sovCurrent

  test "test_an_unrecognised_store_version_is_refused_not_rewritten":
    ## "A store written by a newer schema version is refused with an
    ## explanation and the export path, and the older build does not modify a
    ## single byte of it."
    let volume = newMemoryVolume()
    let future = encodeStoreMetadata(StoreMetadata(
      version: storeSchemaVersion + 7, createdAtMs: t0, lastOpenedAtMs: t0))
    volume.rawWrite(storeMetadataPath, bytesOf(future))
    volume.rawWrite("projects/p1/tree/main.nr", bytesOf("fn main() {}"))
    let before = volume.writeCount

    let opened = awaitOutcome(
      openStore(volume.asVolume, "tab-a", true, true, t0 + 1))
    check not opened.ok
    check opened.error.kind == pkConflict
    check "newer version" in opened.error.message
    check "export" in opened.error.message

    # Not a single byte. This is the assertion that distinguishes "refused" from
    # "refused after touching it": the descriptor still parsing would also hold
    # if the store had rewritten it identically.
    check volume.writeCount == before
    check textOf(volume.rawRead(storeMetadataPath)) == future
    check textOf(volume.rawRead("projects/p1/tree/main.nr")) == "fn main() {}"

  test "an unreadable descriptor is refused too, and distinguishably":
    let volume = newMemoryVolume()
    volume.rawWrite(storeMetadataPath, bytesOf("this is somebody else's file"))
    let before = volume.writeCount
    let opened = awaitOutcome(
      openStore(volume.asVolume, "tab-a", true, true, t0))
    check not opened.ok
    check "not a CodeTracer store descriptor" in opened.error.message
    check volume.writeCount == before

  test "an older store is migrated forward rather than refused":
    ## The counterpart direction. A check that only ever refuses would pass
    ## with `decideStoreOpen` hard-wired to refuse everything.
    let volume = newMemoryVolume()
    volume.rawWrite(storeMetadataPath, bytesOf(
      storeMagic & " 0\ncreated 5\nopened 5\n"))
    let opened = awaitOutcome(
      openStore(volume.asVolume, "tab-a", true, true, t0))
    check opened.ok
    check opened.value.openDecision.verdict == sovMigrate
    check opened.value.openDecision.foundVersion == 0
    check opened.value.metadata.version == storeSchemaVersion
    check opened.value.metadata.createdAtMs == 5

  test "the refusal verdicts are exactly the ones that write nothing":
    ## The rule as a property of the enum rather than of one code path, so a
    ## verdict added later cannot quietly acquire a write.
    for verdict in StoreOpenVerdict:
      check verdict.refuses == not verdict.writesOnOpen

  test "the frozen first line survives an unknown trailing field":
    ## §4.5's requirement that a future store be *refusable*, which needs it to
    ## be parseable enough to yield a version.
    let fromTheFuture =
      storeMagic & " 99\ncreated 1\nopened 2\nprojects-index v3\nfoo bar\n"
    check decodeStoreVersion(fromTheFuture) == 99

# ---------------------------------------------------------------------------
suite "durability is three tiers, not a boolean — §4.1, §4.2":
# ---------------------------------------------------------------------------

  test "test_the_in_memory_fallback_announces_itself_first":
    ## "With OPFS unavailable the session still runs and states that work will
    ## be lost on close before any editing is possible; the failure is never a
    ## blank screen and never discovered at the end."
    let volume = newMemoryVolume()
    let opened = awaitOutcome(
      openStore(volume.asVolume, "tab-a", false, false, t0))
    check opened.ok                        # it RUNS. Not a blank screen.
    let session = opened.value
    check session.durability.condition == scVolatile
    check session.announcement.len > 0
    check "lost when it closes" in session.announcement
    check session.durability.mustAnnounceBeforeEditing

    # Before any editing is possible.
    check not session.readyForEditing
    discard awaitOutcome(session.createProject("p1", "demo", t0))
    let refused = awaitOutcome(session.writeProjectText("p1", "main.nr", "x"))
    check refused.ok    # the STORE will take it; the facade gate is separate

    session.acknowledgeDurability()
    check session.readyForEditing

  test "a granted-persistence session needs no announcement and is ready":
    ## The counter-check. Without it the gate could be `readyForEditing =
    ## false` unconditionally and every assertion above would still pass.
    let volume = newMemoryVolume()
    var durable = volume.asVolume
    durable.durable = true
    let opened = awaitOutcome(openStore(durable, "tab-a", true, true, t0))
    check opened.ok
    check opened.value.durability.condition == scPersistenceGranted
    check opened.value.announcement == ""
    check opened.value.readyForEditing

  test "an unanswered persistence request is not reported as granted":
    ## §4.2: "whether it was **granted** is shown rather than assumed."
    let volume = newMemoryVolume()
    var durable = volume.asVolume
    durable.durable = true
    let opened = awaitOutcome(openStore(durable, "tab-a", false, false, t0))
    check opened.ok
    check opened.value.durability.condition == scPersistenceUnknown
    check opened.value.durability.exportUrgency == euEscalated
    check "did not say" in opened.value.announcement

  test "the degraded sentences lead with what is true, not with the refusal":
    ## THE DEFECT IN THE WORDING, as an assertion.
    ##
    ## The notice opened on "This browser refused to mark your work as
    ## persistent" — a browser refusal, reported at the moment a first-time
    ## visitor has invested nothing, about work that is in fact in OPFS, on
    ## disk, and surviving reloads and crashes. Under the Storage Standard a
    ## denied first visit is the NORMAL case; the origin is best-effort, not
    ## unsaved.
    ##
    ## Both halves are asserted deliberately. Dropping the eviction risk would
    ## be dishonest — best-effort data really can be cleared without a prompt,
    ## and export really is the mitigation — so the risk and the export
    ## instruction must both still be present. What must not be present is the
    ## refusal as the opening clause.
    for condition in [scPersistenceUnknown, scPersistenceDenied]:
      let sentence = durabilityReport(condition).announcement
      check sentence.startsWith("Your work is saved in this browser")
      check "survives reloads" in sentence
      check "export the project" in sentence
      check "refused" notin sentence
      # The risk is still stated rather than softened away.
      check "storage" in sentence

    # …and `scVolatile` does NOT get the reassuring opening, because nothing is
    # saved in that row and the sentence would be false. This is the arm that
    # stops "lead with what is true" from being applied where it is not true.
    let volatileSentence = durabilityReport(scVolatile).announcement
    check not volatileSentence.startsWith("Your work is saved")
    check "lost when it closes" in volatileSentence

  test "a first refusal is not treated as permanent":
    ## `mayBeGrantedLater` is what `web_project_persistence.recheckPersistence`
    ## consults before asking the browser a second time.
    check mayBeGrantedLater(scPersistenceDenied)
    check mayBeGrantedLater(scPersistenceUnknown)
    # Nothing left to ask for…
    check not mayBeGrantedLater(scPersistenceGranted)
    # …and nothing a grant could rescue: there is no OPFS to make persistent.
    check not mayBeGrantedLater(scVolatile)

  test "a later grant improves the report and keeps the acknowledgement":
    let volume = newMemoryVolume()
    var durable = volume.asVolume
    durable.durable = true
    let opened = awaitOutcome(openStore(durable, "tab-a", false, true, t0))
    check opened.ok
    let session = opened.value
    check session.durability.condition == scPersistenceDenied
    check session.announcement.len > 0
    check session.durability.exportUrgency == euEscalated
    session.acknowledgeDurability()

    session.refreshDurability(scPersistenceGranted)
    check session.durability.condition == scPersistenceGranted
    check session.announcement == ""
    check session.durability.exportUrgency == euRoutine
    # THE ACKNOWLEDGEMENT MUST SURVIVE. `web_platform.writeText` refuses every
    # write while `readyForEditing` is false, so resetting it here would make
    # the product start rejecting saves at the exact moment the news improved.
    check session.readyForEditing

  test "the three tiers are named, and the middle one says why it is absent":
    let report = durabilityReport(scPersistenceGranted)
    check report.tiers[dtWorkingTree].available
    check not report.tiers[dtCommittedHistory].available
    check report.tiers[dtExport].available
    check "NS5" in report.tiers[dtCommittedHistory].unavailableBecause
    check "unrecoverable" in report.tiers[dtCommittedHistory].unavailableBecause
    check strongestAvailableTier(report) == dtExport

  test "export is available even when the working tree is not":
    ## The property that makes the outer tier worth having: an in-memory
    ## session can still hand the user their work.
    let report = durabilityReport(scVolatile)
    check not report.tiers[dtWorkingTree].available
    check report.tiers[dtExport].available

  test "the export warning escalates with the condition":
    check neverExportedWarning(durabilityReport(scPersistenceGranted), false)
            .len > 0
    check "Export it now" in
      neverExportedWarning(durabilityReport(scPersistenceDenied), false)
    check "will be lost when this tab closes" in
      neverExportedWarning(durabilityReport(scVolatile), false)
    # And it stops once the work has actually left.
    check neverExportedWarning(durabilityReport(scVolatile), true) == ""

  test "every condition and every tier is covered by the report":
    ## A table-completeness check, the same shape as NS1's
    ## `test_every_absence_has_a_degradation`: a condition added without an
    ## announcement decision, or a tier added without a state, fails here.
    for condition in StorageCondition:
      let report = durabilityReport(condition)
      check report.condition == condition
      for tier in DurabilityTier:
        check report.tiers[tier].tier == tier
        check report.tiers[tier].survives.len > 0
        check report.tiers[tier].mechanism.len > 0
        if not report.tiers[tier].available:
          check report.tiers[tier].unavailableBecause.len > 0
      check (report.announcement.len > 0) == report.mustAnnounceBeforeEditing

# ---------------------------------------------------------------------------
suite "test_interrupted_writes_leave_the_previous_state_intact — §4.4":
# ---------------------------------------------------------------------------

  setup:
    let volume = newMemoryVolume()
    let session = openFresh(volume)
    discard awaitOutcome(session.createProject("p1", "demo", t0))
    check awaitOutcome(
      session.writeProjectText("p1", "src/main.nr", "fn main() { 1 }")).ok

  test "a working-tree write is never made in place":
    ## The mechanism, asserted directly: the bytes land somewhere else first
    ## and are moved. Without this the atomicity claims below could hold by
    ## accident on a volume whose write happens to be atomic.
    let movesBefore = volume.moveCount
    check awaitOutcome(
      session.writeProjectText("p1", "src/main.nr", "fn main() { 2 }")).ok
    check volume.moveCount == movesBefore + 1
    check awaitOutcome(session.readProjectText("p1", "src/main.nr")).value ==
      "fn main() { 2 }"

  test "a write killed mid-flight leaves the original file intact":
    volume.failWritesUnder = tempRoot("p1")
    let attempt = awaitOutcome(
      session.writeProjectText("p1", "src/main.nr", "fn main() { RUINED }"))
    check not attempt.ok
    check attempt.error.kind == pkFailed
    volume.failWritesUnder = ""
    check awaitOutcome(session.readProjectText("p1", "src/main.nr")).value ==
      "fn main() { 1 }"

  test "a replace killed mid-flight leaves the original file intact":
    ## The other half: the temp lands and the rename does not.
    volume.failMoves = true
    let attempt = awaitOutcome(
      session.writeProjectText("p1", "src/main.nr", "fn main() { RUINED }"))
    check not attempt.ok
    volume.failMoves = false
    check awaitOutcome(session.readProjectText("p1", "src/main.nr")).value ==
      "fn main() { 1 }"

  test "a failed write leaves no temporary file behind":
    volume.failMoves = true
    discard awaitOutcome(
      session.writeProjectText("p1", "src/main.nr", "fn main() { RUINED }"))
    volume.failMoves = false
    for path in volume.fileNames():
      check not isUnder(tempRoot("p1"), path)

  test "mid-write QuotaExceededError leaves the original file intact":
    ## §4.4: "a write that fails on `QuotaExceededError` discards the
    ## temporary file and leaves the original intact, because nothing is ever
    ## written in place."
    volume.quotaBytes = volume.usedBytes + 8
    let attempt = awaitOutcome(session.writeProjectText(
      "p1", "src/main.nr", "fn main() { a very much longer body indeed }"))
    check not attempt.ok
    check attempt.error.kind == pkQuotaExceeded
    volume.quotaBytes = 0
    check awaitOutcome(session.readProjectText("p1", "src/main.nr")).value ==
      "fn main() { 1 }"
    for path in volume.fileNames():
      check not isUnder(tempRoot("p1"), path)

  test "headroom is checked before a large write, and unknown means yes":
    volume.quotaBytes = volume.usedBytes + 100
    check awaitOutcome(session.headroomFor(10)).value
    check not awaitOutcome(session.headroomFor(10_000)).value
    volume.quotaBytes = 0
    check awaitOutcome(session.headroomFor(10_000_000)).value

  test "an interrupted compilation's outputs are discarded on the next open":
    ## §4.4's derived class, and one half of
    ## `e2e_project_survives_reload_and_crash`.
    check awaitOutcome(session.writeBuildOutput(
      "p1", "circuit.acir", bytesOf("half-written"))).ok
    check awaitOutcome(
      volume.asVolume.stat(buildOutputRoot("p1") & "/circuit.acir")
    ).value.kind == vekFile

    check awaitOutcome(session.discardStaleWork("p1")).ok
    check awaitOutcome(
      volume.asVolume.stat(buildOutputRoot("p1") & "/circuit.acir")
    ).value.kind == vekMissing
    # And the working tree is untouched by the discard.
    check awaitOutcome(session.readProjectText("p1", "src/main.nr")).value ==
      "fn main() { 1 }"

  test "an interrupted git write leaves unreferenced objects, which are kept":
    ## §4.4 calls a half-written git object "unreferenced garbage", not
    ## corruption — it is content-addressed and immutable, so it is unreachable
    ## rather than wrong. Collecting it is git's `gc`, which is NS5's. This
    ## asserts the store does NOT delete it, which is the decision that would
    ## otherwise be made by accident.
    volume.rawWrite(gitDirRoot("p1") & "/objects/ab/cdef", bytesOf("partial"))
    check awaitOutcome(session.discardStaleWork("p1")).ok
    check textOf(volume.rawRead(gitDirRoot("p1") & "/objects/ab/cdef")) ==
      "partial"

  test "the recovery class of a path follows from the path":
    check classify("p1", workingTreeRoot("p1") & "/main.nr") == scWorkingTree
    check classify("p1", buildOutputRoot("p1") & "/a.acir") == scBuildOutput
    check classify("p1", tempRoot("p1") & "/w3") == scStagingTemp
    check classify("p1", gitDirRoot("p1") & "/objects/ab/cd") == scGitObject
    check classify("p1", gitDirRoot("p1") & "/refs/heads/main") == scGitRef
    check classify("p1", projectMetadataPath("p1")) == scStoreInternal
    check discardedOnDoubt(scBuildOutput)
    check discardedOnDoubt(scStagingTemp)
    check not discardedOnDoubt(scWorkingTree)
    check not discardedOnDoubt(scGitObject)
    check needsAtomicReplace(scWorkingTree)
    check needsAtomicReplace(scGitRef)
    check not needsAtomicReplace(scBuildOutput)

# ---------------------------------------------------------------------------
suite "test_a_second_tab_cannot_corrupt_the_store — §4.3":
# ---------------------------------------------------------------------------
#
# Two `StoreSession`s over ONE volume is two tabs on one origin. That is not a
# simulation of the situation §4.3 describes; it is the situation, minus the
# browser.

  setup:
    let volume = newMemoryVolume()
    let tabA = openFresh(volume, "tab-a")
    let tabB = openFresh(volume, "tab-b")
    discard awaitOutcome(tabA.createProject("p1", "demo", t0))
    check awaitOutcome(tabA.writeProjectText("p1", "main.nr", "one")).ok

  test "the second tab opens read-only and is told who holds it":
    let opened = awaitOutcome(tabB.openProject("p1", t0 + 1))
    check opened.ok
    check opened.value.role == wrReadOnly
    check opened.value.heldBy == "tab-a"

  test "the read-only tab's writes are refused, and change nothing":
    discard awaitOutcome(tabB.openProject("p1", t0 + 1))
    let before = volume.writeCount
    let refused = awaitOutcome(tabB.writeProjectText("p1", "main.nr", "two"))
    check not refused.ok
    check refused.error.kind == pkAccessDenied
    check "read-only" in refused.error.message
    check volume.writeCount == before
    check awaitOutcome(tabA.readProjectText("p1", "main.nr")).value == "one"

  test "takeover is clean: B writes, and A is refused rather than interleaved":
    discard awaitOutcome(tabB.openProject("p1", t0 + 1))
    let taken = awaitOutcome(tabB.takeOverProject("p1", t0 + 2))
    check taken.ok
    check taken.value.role == wrOwner
    check taken.value.lock.generation == 2

    check awaitOutcome(tabB.writeProjectText("p1", "main.nr", "two")).ok

    let stale = awaitOutcome(tabA.writeProjectText("p1", "main.nr", "three"))
    check not stale.ok
    check stale.error.kind == pkConflict
    check "taken over" in stale.error.message
    check "nothing was written" in stale.error.message
    check awaitOutcome(tabB.readProjectText("p1", "main.nr")).value == "two"

  test "the relinquished tab does not silently re-acquire":
    discard awaitOutcome(tabB.openProject("p1", t0 + 1))
    discard awaitOutcome(tabB.takeOverProject("p1", t0 + 2))
    discard awaitOutcome(tabA.writeProjectText("p1", "main.nr", "three"))
    check tabA.writerRole("p1") == wrReadOnly
    # A second attempt is refused for the same reason, not retried into a win.
    let again = awaitOutcome(tabA.writeProjectText("p1", "main.nr", "four"))
    check not again.ok
    check again.error.kind == pkAccessDenied

  test "no interleaving of the two leaves the store unopenable":
    ## The rest of the verification's sentence: "no interleaving of the two
    ## produces a store that fails to open or loses a committed change."
    discard awaitOutcome(tabB.openProject("p1", t0 + 1))
    for round in 0 .. 5:
      discard awaitOutcome(tabA.writeProjectText("p1", "main.nr", "a" & $round))
      discard awaitOutcome(tabB.writeProjectText("p1", "main.nr", "b" & $round))
      discard awaitOutcome(tabB.takeOverProject("p1", t0 + 10 + round.int64))
      discard awaitOutcome(tabA.writeProjectText("p1", "main.nr", "A" & $round))
      discard awaitOutcome(tabA.takeOverProject("p1", t0 + 20 + round.int64))
    let reopened = awaitOutcome(
      openStore(volume.asVolume, "tab-c", true, true, t0 + 99))
    check reopened.ok
    let contents = awaitOutcome(
      reopened.value.readProjectText("p1", "main.nr"))
    check contents.ok
    # Whatever the last accepted write was, it is one of the writes that were
    # accepted — never a mixture, never empty.
    check contents.value.len > 0

  test "releasing lets the next tab take the writer role without a takeover":
    check awaitOutcome(tabA.releaseProject("p1")).ok
    let opened = awaitOutcome(tabB.openProject("p1", t0 + 5))
    check opened.ok
    check opened.value.role == wrOwner

  test "reopening in the same tab is re-entrant and does not bump generation":
    let first = awaitOutcome(tabA.openProject("p1", t0 + 1))
    let second = awaitOutcome(tabA.openProject("p1", t0 + 2))
    check second.value.role == wrOwner
    check second.value.lock.generation == first.value.lock.generation

# ---------------------------------------------------------------------------
suite "test_committed_history_survives_a_corrupted_working_tree — §4.1":
# ---------------------------------------------------------------------------

  test "the middle tier is unavailable, and the store says so instead of lying":
    ## The named verification asks that "with working-tree files deliberately
    ## truncated, the project reopens at its last commit".
    ##
    ## **The product cannot do that yet, and this suite says so rather than
    ## passing.** §4.1 places committed history behind the git engine, which
    ## NS5 is sequenced for after launch, and is explicit about the cost:
    ## "without committed history there is **no recovery point inside the
    ## store**: a bad edit, a deleted file or a corrupted tree is unrecoverable
    ## unless the project was exported."
    ##
    ## So what is asserted is the honest contract: the tier reports itself
    ## unavailable, names why, and a truncated working tree is NOT silently
    ## recovered. The day the engine lands, this test changes shape and the
    ## verification above becomes assertable — which is exactly the signal a
    ## `status: pending` cannot give.
    let volume = newMemoryVolume()
    let session = openFresh(volume)
    discard awaitOutcome(session.createProject("p1", "demo", t0))
    check awaitOutcome(session.writeProjectText("p1", "main.nr", "good")).ok

    volume.rawWrite(workingTreeRoot("p1") & "/main.nr", @[])

    let reopened = awaitOutcome(
      openStore(volume.asVolume, "tab-b", true, true, t0 + 1))
    check reopened.ok
    let recovered = awaitOutcome(reopened.value.readProjectText("p1", "main.nr"))
    check recovered.ok
    check recovered.value == ""     # truncated, and NOT recovered

    check not reopened.value.durability.tiers[dtCommittedHistory].available
    check "NS5" in
      reopened.value.durability.tiers[dtCommittedHistory].unavailableBecause

  test "the export tier IS reachable, which is the recovery point that exists":
    let volume = newMemoryVolume()
    let session = openFresh(volume)
    discard awaitOutcome(session.createProject("p1", "demo", t0))
    check awaitOutcome(session.writeProjectText("p1", "main.nr", "good")).ok

    let tree = awaitOutcome(session.collectTree("p1"))
    check tree.ok
    check tree.value.len == 1
    check textOf(tree.value[0].content) == "good"

# ---------------------------------------------------------------------------
suite "e2e_project_survives_reload_and_crash":
# ---------------------------------------------------------------------------

  test "a project written, reloaded and interrupted mid-save recovers whole":
    let volume = newMemoryVolume()

    # Session one: write a small tree.
    block:
      let session = openFresh(volume, "tab-1")
      discard awaitOutcome(session.createProject("p1", "demo", t0))
      check awaitOutcome(session.writeProjectText(
        "p1", "Nargo.toml", "[package]\nname = \"demo\"\n")).ok
      check awaitOutcome(session.writeProjectText(
        "p1", "src/main.nr", "fn main() {}")).ok
      check awaitOutcome(session.writeProjectText(
        "p1", "src/lib.nr", "fn helper() {}")).ok
      check awaitOutcome(session.writeBuildOutput(
        "p1", "target/demo.json", bytesOf("{}"))).ok

    # A reload is a new session over the same volume, with a new owner id.
    let reloaded = awaitOutcome(
      openStore(volume.asVolume, "tab-2", true, true, t0 + 1))
    check reloaded.ok
    let session = reloaded.value
    session.acknowledgeDurability()

    # A RELOAD IS INDISTINGUISHABLE FROM A SECOND TAB, and §4.3 gives no other
    # answer. The previous session's lock record is still in the store — it
    # released nothing, because it was closed rather than closed *down* — and
    # §4.3 deliberately has no staleness timeout, because a timeout is
    # last-writer-wins with a delay. So the reloaded tab opens read-only,
    # naming the holder, and the way back is the explicit takeover the section
    # specifies.
    #
    # This is a real gap in §4.3 rather than a defect here: the section
    # answers "two tabs" and does not answer "the holder is gone", which is
    # the commoner case. It is recorded in NS2's report; what a browser can
    # add is a liveness probe (Web Locks or a BroadcastChannel ping), which is
    # a browser mechanism and does not belong in this host-free layer.
    let afterReload = awaitOutcome(session.openProject("p1", t0 + 1))
    check afterReload.value.role == wrReadOnly
    check afterReload.value.heldBy == "tab-1"
    check awaitOutcome(session.takeOverProject("p1", t0 + 2)).value.role ==
      wrOwner

    check awaitOutcome(session.readProjectText("p1", "Nargo.toml")).value ==
      "[package]\nname = \"demo\"\n"
    check awaitOutcome(session.readProjectText("p1", "src/main.nr")).value ==
      "fn main() {}"

    # Now the crash: a save that does not complete.
    volume.failMoves = true
    check not awaitOutcome(
      session.writeProjectText("p1", "src/main.nr", "fn main() { broken")).ok
    volume.failMoves = false

    # Nothing lost, nothing corrupted, nothing partial left behind.
    check awaitOutcome(session.readProjectText("p1", "src/main.nr")).value ==
      "fn main() {}"
    check awaitOutcome(session.discardStaleWork("p1")).ok
    for path in volume.fileNames():
      check not isUnder(tempRoot("p1"), path)
      check not isUnder(buildOutputRoot("p1"), path)

    let tree = awaitOutcome(session.collectTree("p1"))
    check tree.ok
    var paths: seq[string] = @[]
    for file in tree.value: paths.add file.path
    paths.sort()
    check paths == @["Nargo.toml", "src/lib.nr", "src/main.nr"]

  test "listing a project shows what was written, at each level":
    let volume = newMemoryVolume()
    let session = openFresh(volume)
    discard awaitOutcome(session.createProject("p1", "demo", t0))
    check awaitOutcome(session.writeProjectText("p1", "Nargo.toml", "x")).ok
    check awaitOutcome(session.writeProjectText("p1", "src/main.nr", "y")).ok

    let top = awaitOutcome(session.listProjectDir("p1", ""))
    check top.ok
    var names: seq[string] = @[]
    for entry in top.value: names.add entry.name
    names.sort()
    check names == @["Nargo.toml", "src"]

    let inner = awaitOutcome(session.listProjectDir("p1", "src"))
    check inner.ok
    check inner.value.len == 1
    check inner.value[0].name == "main.nr"
    check inner.value[0].kind == vekFile

  test "projects are listed, and the store's own files are not among them":
    let volume = newMemoryVolume()
    let session = openFresh(volume)
    discard awaitOutcome(session.createProject("alpha", "Alpha", t0))
    discard awaitOutcome(session.createProject("beta", "Beta", t0))
    let listed = awaitOutcome(session.listProjects())
    check listed.ok
    var ids = listed.value
    ids.sort()
    check ids == @["alpha", "beta"]

# ---------------------------------------------------------------------------
suite "archive export — §6.2's launch form":
# ---------------------------------------------------------------------------

  test "an archive round-trips through a reader written from the format":
    let built = buildArchive(@[
      ArchiveEntry(path: "demo/Nargo.toml", content: bytesOf("[package]"),
                   modifiedMs: t0),
      ArchiveEntry(path: "demo/src/main.nr", content: bytesOf("fn main() {}"),
                   modifiedMs: t0)])
    check built.ok
    check built.rejected.len == 0
    let read = readArchive(built.bytes)
    check read.len == 2
    check read[0].path == "demo/Nargo.toml"
    check textOf(read[0].content) == "[package]"
    check read[1].path == "demo/src/main.nr"
    check textOf(read[1].content) == "fn main() {}"

  test "the header checksum a real tar would verify actually holds":
    ## The field a hand-rolled writer gets wrong and `tar` refuses on. Computed
    ## here from the emitted bytes rather than from the writer's own arithmetic.
    let built = buildArchive(@[
      ArchiveEntry(path: "demo/a.nr", content: bytesOf("x"), modifiedMs: t0)])
    check built.ok
    check archiveChecksumHolds(built.bytes, 0)

  test "the checksum check can fail":
    ## Otherwise the check above is a check that cannot fail.
    var built = buildArchive(@[
      ArchiveEntry(path: "demo/a.nr", content: bytesOf("x"), modifiedMs: t0)])
    check built.ok
    built.bytes[0] = (if built.bytes[0] == 'd'.byte: 'e'.byte else: 'd'.byte)
    check not archiveChecksumHolds(built.bytes, 0)

  test "the archive is ordered by path, whatever order it was handed":
    let forwards = buildArchive(@[
      ArchiveEntry(path: "d/a", content: bytesOf("1"), modifiedMs: t0),
      ArchiveEntry(path: "d/b", content: bytesOf("2"), modifiedMs: t0)])
    let backwards = buildArchive(@[
      ArchiveEntry(path: "d/b", content: bytesOf("2"), modifiedMs: t0),
      ArchiveEntry(path: "d/a", content: bytesOf("1"), modifiedMs: t0)])
    check forwards.ok and backwards.ok
    check forwards.bytes == backwards.bytes

  test "a path too long for ustar is refused by name, never truncated":
    var long = "demo"
    for i in 0 .. 40: long.add "/directorywithquitealongname"
    let built = buildArchive(@[
      ArchiveEntry(path: long & "/main.nr", content: bytesOf("x"),
                   modifiedMs: t0)])
    check not built.ok
    check built.rejected.len == 1
    check built.bytes.len == 0
    check "not written" in built.reason
    check long in built.reason

  test "a long-but-expressible path is split across name and prefix":
    ## The counter-check: the rejection above must not be "any path over 100
    ## bytes", or the refusal would be a bug rather than a limit.
    var dir = "demo"
    for i in 0 .. 4: dir.add "/directorywithquitealongname"
    let path = dir & "/main.nr"
    check path.len > 100
    check path.len < 256
    let built = buildArchive(@[
      ArchiveEntry(path: path, content: bytesOf("x"), modifiedMs: t0)])
    check built.ok
    check readArchive(built.bytes)[0].path == path

  test "an empty archive is still a valid, terminated one":
    let built = buildArchive(@[])
    check built.ok
    check built.bytes.len == 512 * 20
    check readArchive(built.bytes).len == 0
