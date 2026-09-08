## test_layout_persistence_matrix.nim — PLAT-6, Tier 1: **the persistence
## decision, enumerated.**
##
## ## The defect CLASS this closes, rather than the three instances
##
## `test_layout_persistence.nim` is the behavioural suite: it asserts the key,
## the round trip, the four decoder failures, the `EACCES` arm and the flag-off
## arm. It is not exhaustive, and three separate verification passes each found
## a different **unmeasured combination** in the same decision — each one of
## which destroys a user's file:
##
##   1. neuter `runtime.markLayoutDocumentUnreadable` and a transient `EACCES`
##      DELETES the document (arm `M45`, control `S18`);
##   2. delete `rt.rebuildFocus()` from the mouse path and the ring offers a
##      docked-away pane (arm `M37`, control `S10`);
##   3. weaken `layoutPersistPlan`'s first branch to
##      `quarantined and (b.isNil or not b.userModified)` and a session that
##      **rearranged a pane over a `version: 99` document** replaces it on disk
##      with a `version: 2` one — permanent loss, not a session's.
##
## Every one of the three was found by hand-picking one more arm, which is not
## a repeatable process. **This suite is the repeatable one:** it enumerates the
## decision's whole input space as DATA and asserts every cell, so the next
## combination is covered before anybody thinks to pick it.
##
## ## THE INPUT SPACE, DERIVED FROM THE CODE
##
## `host/layout_store.restoreLayoutForSession` and
## `app/layout/persistence.layoutPersistPlan` (through
## `runtime.layoutPersistPlanOf`) branch on exactly these facts, and this list
## is read off the branches rather than off anybody's summary:
##
##   * `rt.layoutBindingEnabled()` — `restoreLayoutForSession`'s first guard and
##     the first half of `layoutPersistenceEnabled`;
##   * `rt.layoutDocument.len > 0` — the SECOND half of `layoutPersistenceEnabled`,
##     and it is **an independent input**, not a consequence of the first: a host
##     may enable the binding and never name a document, which is the
##     "rearrangeable session that forgets" `runtime.layoutPersistenceEnabled`
##     documents. It is the dimension a summary of this decision is most likely
##     to drop, because no `main.nim` path produces it today;
##   * what is at the document's path — `fileExists`, then whether `readFile`
##     succeeds, then what `adoptLayoutDocument` makes of the bytes;
##   * `b.userModified` — which is **derived, not free**: it is set by a
##     restore (`binding.restoreDocument`), set by any applied layout command,
##     and cleared by `:reset-layout`. It cannot be chosen independently of the
##     document and the gesture, which is why the table's third dimension is the
##     GESTURE and `userModified` is an output;
##   * `quarantined` — likewise derived: `bindLayoutDocument` clears it,
##     `adoptLayoutDocument` sets it from the restore status, and
##     `markLayoutDocumentUnreadable` sets it on the one path the decoder never
##     sees;
##   * `b.isNil` — `layoutPersistPlan`'s own defensive guard, which no session
##     can present to it (see `PlanTable` below).
##
## So the SESSION table's three dimensions are the three free inputs — how the
## session is wired, what is on disk, and what the user did — and everything
## else is an asserted output.
##
## ## THE FOUR TABLES
##
## | table | cells | reachable | unreachable |
## | --- | --- | --- | --- |
## | `SessionMatrix` — session x document x gesture | 96 | 96 | 0 |
## | `PlanTable` — `layoutPersistPlan`'s own two inputs | 6 | 4 | 2 |
## | `KindTable` — every `LayoutRestoreReport.kind` this build can produce | 13 | 11 | 2 |
## | `FailureTable` — the two arms that answer `lpoFailed` | 2 | 2 | 0 |
##
## **`FailureTable` IS A TABLE AND NOT A DIMENSION**, and the reason is worth
## one paragraph because the previous version of this file got it wrong in the
## other direction — it declared `lpoFailed` UNREACHABLE, with a rationale
## ("both arms need a filesystem that refuses a write to a directory this
## process has just created, which a temporary directory does not provide")
## that is simply false. Both arms are reached below on an ordinary
## `createTempDir()`, and the remove arm uses the very `setFilePermissions`
## technique the `EACCES` lane already runs on this host — so the file
## contradicted itself. A false claim about the POPULATION, inside the
## instrument whose whole value is its claim to be exhaustive, is worse than
## the gap it papers over.
##
## What is true is the smaller statement: **no SESSION cell reaches it**. A
## failure arm is reached by obstructing the filesystem, which is a fourth
## thing to do to the WORLD rather than a fourth thing to do in a session; as a
## value of a session dimension it would have meant 96 cells carrying an
## obstruction 94 of them ignore. So the cross asserts `lpoFailed` is absent
## from it, and the table below reaches both arms with real obstructions.
##
## The counts are written here and asserted below; `SessionMatrix` is declared
## as an `array[96, MatrixRow]`, so a row added or lost is a COMPILE error
## rather than a smaller question quietly answered. The completeness check is
## separate and is the one that matters: every one of the 3 x 8 x 4 triples is
## required to appear EXACTLY ONCE, so a dimension that grows a value reddens
## this suite instead of silently leaving a corner unmeasured.
##
## ## EVERY CELL ASSERTS THE FILE
##
## All three findings above shared one shape: **the report was unchanged while
## the file moved.** `M45`'s measurement is the clearest — the user is still
## told `UnreadableFile` and the file is gone. So no cell here is graded on its
## report alone: every row carries a `FileAfter` and the assertion reads the
## directory and the bytes.
##
## ## AND THE WRITE IS ASSERTED TO BE A RENAME, POSITIVELY
##
## `host/layout_store.nim`'s header promises that the document is staged at
## `<path>.new` and moved onto `<path>`, so a process killed mid-write leaves
## the previous arrangement intact. **Nothing asserted that.** Collapsing the
## two lines to a single `writeFile(path, plan.text)` left all four of PLAT-6's
## suites at 0 failed, and no arm of the 83-arm harness touched `moveFile`. The
## only mentions of `.new` in either suite were NEGATIVE — *"a stray `.new`
## would mean the rename did not happen"* — which is trap §4a exactly: a lone
## negative assertion with no positive twin has nothing to fail.
##
## The twin is the *"DURABILITY"* case below, and it is the same probe that
## reaches the write half of `FailureTable`: obstruct `<path>.new` and the
## write cannot happen at all, which is what says the bytes go THROUGH the
## staging path. With the collapse planted that probe reports `lpoWritten` and
## goes red. One case, both jobs.
##
## ## No mocks
##
## None, and none is justified. Real temporary directories under `getTempDir()`,
## the product's own `host/layout_store.nim` doing the I/O, the product's own
## `handleToken` receiving the gestures, and a REAL permission removal for the
## `EACCES` row rather than an injected failure.
##
## ## Templates, not procs, for anything that calls `check`
##
## Verification-Harness-Traps §13: `unittest.check` inside a plain `proc`
## resolves to a module-level global and the test still reports `[OK]` with its
## failed comparison printed above it. Every helper here that calls `check` is a
## `template`; the `proc`s return values and call `check` nowhere.

import std/[algorithm, json, options, os, strutils, tempfiles, unittest]

import headless_app/layout_model

import ../app/runtime
import ../app/theme/capabilities
import ../host/layout_store

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 1083

const EaccesLaneAssertions = 41
  ## What the `EACCES` lane contributes to the count above.
  ##
  ## Subtracted from the total — and only from it — on a host where the row
  ## cannot be measured at all, so the count stays EXACT in both worlds rather
  ## than being relaxed into a range. See `EaccesPreconditionBanner`.
  ##
  ## **MEASURED FROM A RUN, NEVER COMPUTED.** Every number in this block is:
  ## the lane is forced to skip and the two `CHECKS:` lines are differenced. A
  ## hand-computed constant that happens to match is how a counter stops being
  ## evidence (§4c: *write the number last, from a run*).

const EaccesLaneCells = 4
  ## …and the cells, on the same rule. The cell tally is the table's own §4b
  ## count control, so it must move by exactly the number of cells that did not
  ## run rather than being widened into an inequality.

const EaccesPreconditionBanner =
  "PRECONDITION NOT MET: removing every permission from a file this process " &
  "OWNS did not deny reading it — this run is privileged (root), or the " &
  "state directory is on a filesystem that does not enforce permissions. " &
  "THE 4 CELLS OF THE `unopenable` ROW WERE NOT MEASURED by this run. Re-run " &
  "the suite as an unprivileged user on a permission-enforcing filesystem."
  ## The loud half of a loud skip (Silent-Self-Pass-Audit's rule: a missing
  ## prerequisite is made LOUD and the assertion is never weakened). The case
  ## calls `unittest.skip()`, so it reports `[SKIPPED]` rather than `[OK]` and
  ## the lane's own SKIPPED tally moves.

const RemoveFailureLaneAssertions = 12
  ## What the `FailureTable`'s REMOVE arm contributes, on the same rule as
  ## `EaccesLaneAssertions` and for the same reason: its obstruction — a state
  ## directory with no write permission — is refused by nobody on a privileged
  ## host, so the case can be unmeasurable while every other case is fine.
  ##
  ## The WRITE arm has no such constant because it has no precondition: a
  ## directory where a file must be opened defeats `writeFile` for root as
  ## surely as for anybody else.

const RemoveFailurePreconditionBanner =
  "PRECONDITION NOT MET: removing the write permission from a directory this " &
  "process OWNS did not refuse it a `removeFile` — this run is privileged " &
  "(root), or the state directory is on a filesystem that does not enforce " &
  "permissions. THE `remove` ARM OF `FailureTable` WAS NOT MEASURED by this " &
  "run. Re-run the suite as an unprivileged user on a permission-enforcing " &
  "filesystem."

var countedAssertions = 0
var countedCells = 0
var eaccesLaneRan = true
var removeFailureLaneRan = true

template ck(condition: untyped) =
  inc countedAssertions
  check condition

# ---------------------------------------------------------------------------
# THE DIMENSIONS. Three free inputs; everything else in a row is an output.
# ---------------------------------------------------------------------------

type
  SessionKind* = enum
    ## How the session is wired — the two halves of `layoutPersistenceEnabled`,
    ## as the three states a host can actually produce.
    sNoBinding = "no-binding"
      ## No `--layout-binding`. `layoutBindingEnabled()` is false.
    sUnnamed = "binding-but-no-document"
      ## A binding, and `restoreLayoutForSession` was never called, so
      ## `rt.layoutDocument` is still `""`.
      ##
      ## **THE DIMENSION A SUMMARY DROPS, and the reason it does is the reason
      ## it belongs here:** no `main.nim` path produces it today. It is not
      ## hypothetical either — `runtime.layoutPersistenceEnabled`'s own header
      ## describes it as a supported state ("a rearrangeable session that
      ## forgets"), it is one of the two halves that predicate tests, and a
      ## second host embedding this runtime reaches it by doing nothing. A
      ## state that is reachable, supported and produced by nobody is exactly
      ## the state no hand-written case gets written for.
    sBound = "bound"
      ## A binding, and the session was bound to this recording's document.

  DocumentKind* = enum
    ## What is at the document's path when the session starts.
    ##
    ## Eight values rather than the fourteen `KindTable` enumerates: these are
    ## the states the PERSIST DECISION distinguishes, plus one representative of
    ## each *reason* a document can be unreadable — bytes, emptiness, schema,
    ## vocabulary and the open itself. `KindTable` owns the rest, and the
    ## equivalence is asserted rather than assumed (see the `PRECEDENCE` cases:
    ## every unreadable reason produces the same intent, outcome and file).
    dAbsent = "absent"
    dCurrent = "current-version"
    dOlder = "older-version"
      ## A `version: 1` document. It MIGRATES FORWARD and restores, and the
      ## session then rewrites it as `version: 2` — a document REPLACED on disk
      ## with no user gesture at all. Intended (§6 has no backward migration),
      ## and named here because a replacement nobody wrote down is how the next
      ## finding starts.
    dFuture = "future-version"
      ## `version: 99`. The expensive case the schema chain exists for.
    dNotJson = "not-json"
    dEmpty = "empty"
    dUnknownPane = "unknown-pane"
    dUnopenable = "unopenable"
      ## A perfectly good document whose permissions are gone. The one arm
      ## whose quarantine comes from `markLayoutDocumentUnreadable` rather than
      ## from `adoptLayoutDocument`.

  GestureKind* = enum
    ## What the user did in the session. `userModified` is a FUNCTION of this
    ## and of the restore, which is why this is the dimension and that is not.
    gNone = "nothing"
    gReset = "reset-layout"
    gRearrange = "dock-bottom"
    gRearrangeThenReset = "dock-bottom-then-reset"

  FileAfter* = enum
    ## What the exit did to the bytes on disk. THE COLUMN THE THREE FINDINGS
    ## WOULD HAVE MOVED; the report columns beside it would not have.
    faAbsent = "no file"
    faUnchanged = "unchanged, byte for byte"
    faWritten = "written by this build"

  MatrixLane* = enum
    ## Which named case asserts a row. Carried as DATA rather than derived from
    ## the key, so the partition is auditable and its histogram is asserted —
    ## and so a mutation arm can name ONE case that must redden.
    lOff = "off"
    lUnnamed = "unnamed"
    lAbsent = "absent"
    lReadable = "readable"
    lPrecedenceModified = "precedence-modified"
    lPrecedenceUnmodified = "precedence-unmodified"
    lEacces = "eacces"

  MatrixRow* = tuple
    lane: MatrixLane
    session: SessionKind
    document: DocumentKind
    gesture: GestureKind
    status: LayoutRestoreStatus
    kind: string
    quarantined: bool
    intent: LayoutPersistIntent
    outcome: LayoutPersistOutcome
    file: FileAfter

const
  ExpectedCells = 96
    ## THE CARDINALITY, STATED RATHER THAN COMPUTED FROM THE SUBJECT. Asserted
    ## three ways below: against the literal array's length, against the product
    ## of the three dimensions' sizes, and against a per-triple occupancy walk.
  ExpectedLaneCounts: array[MatrixLane, int] =
    [32, 32, 4, 8, 4, 12, 4]

# ---------------------------------------------------------------------------
# THE SESSION MATRIX. 3 sessions x 8 documents x 4 gestures.
#
# READ IT AS: "wired like this, with that on disk, after the user did this — the
# restore says X, the plan is Y, the exit does Z, and the file ends up W."
#
# The two `sNoBinding` / `sUnnamed` blocks are 64 of the 96 rows and every one
# of them says the same thing: NOTHING MOVED. That is not padding — "the flag is
# off" and "no document was named" are the two ways this feature is invisible,
# and a table that asserted them once would be asserting them for one document
# state out of eight.
# ---------------------------------------------------------------------------

const SessionMatrix: array[ExpectedCells, MatrixRow] = [
  # -- lOff: no binding. Nothing is read, no path is computed, nothing moves. --
  (lOff, sNoBinding, dAbsent, gNone, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faAbsent),
  (lOff, sNoBinding, dAbsent, gReset, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faAbsent),
  (lOff, sNoBinding, dAbsent, gRearrange, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faAbsent),
  (lOff, sNoBinding, dAbsent, gRearrangeThenReset, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faAbsent),
  (lOff, sNoBinding, dCurrent, gNone, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lOff, sNoBinding, dCurrent, gReset, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lOff, sNoBinding, dCurrent, gRearrange, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lOff, sNoBinding, dCurrent, gRearrangeThenReset, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lOff, sNoBinding, dOlder, gNone, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lOff, sNoBinding, dOlder, gReset, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lOff, sNoBinding, dOlder, gRearrange, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lOff, sNoBinding, dOlder, gRearrangeThenReset, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lOff, sNoBinding, dFuture, gNone, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lOff, sNoBinding, dFuture, gReset, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lOff, sNoBinding, dFuture, gRearrange, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lOff, sNoBinding, dFuture, gRearrangeThenReset, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lOff, sNoBinding, dNotJson, gNone, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lOff, sNoBinding, dNotJson, gReset, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lOff, sNoBinding, dNotJson, gRearrange, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lOff, sNoBinding, dNotJson, gRearrangeThenReset, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lOff, sNoBinding, dEmpty, gNone, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lOff, sNoBinding, dEmpty, gReset, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lOff, sNoBinding, dEmpty, gRearrange, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lOff, sNoBinding, dEmpty, gRearrangeThenReset, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lOff, sNoBinding, dUnknownPane, gNone, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lOff, sNoBinding, dUnknownPane, gReset, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lOff, sNoBinding, dUnknownPane, gRearrange, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lOff, sNoBinding, dUnknownPane, gRearrangeThenReset, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lOff, sNoBinding, dUnopenable, gNone, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lOff, sNoBinding, dUnopenable, gReset, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lOff, sNoBinding, dUnopenable, gRearrange, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lOff, sNoBinding, dUnopenable, gRearrangeThenReset, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),

  # -- lUnnamed: a binding, and no document was ever named. --------------------
  #
  # `restoreLayoutForSession` is NOT called for these rows, which is what makes
  # them the dimension they are: the gestures apply (there IS a binding, so
  # `:dock bottom` really docks a pane and `userModified` really is set), and
  # the exit still writes nowhere because `layoutPersistenceEnabled` needs both
  # halves. `status`/`kind` are `lrsNoDocument`/`""` by convention here — no
  # restore was performed at all — and the lane separately asserts
  # `rt.layoutDocument.len == 0`, which is what distinguishes these rows from
  # `lOff`'s.
  (lUnnamed, sUnnamed, dAbsent, gNone, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faAbsent),
  (lUnnamed, sUnnamed, dAbsent, gReset, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faAbsent),
  (lUnnamed, sUnnamed, dAbsent, gRearrange, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faAbsent),
  (lUnnamed, sUnnamed, dAbsent, gRearrangeThenReset, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faAbsent),
  (lUnnamed, sUnnamed, dCurrent, gNone, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lUnnamed, sUnnamed, dCurrent, gReset, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lUnnamed, sUnnamed, dCurrent, gRearrange, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lUnnamed, sUnnamed, dCurrent, gRearrangeThenReset, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lUnnamed, sUnnamed, dOlder, gNone, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lUnnamed, sUnnamed, dOlder, gReset, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lUnnamed, sUnnamed, dOlder, gRearrange, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lUnnamed, sUnnamed, dOlder, gRearrangeThenReset, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lUnnamed, sUnnamed, dFuture, gNone, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lUnnamed, sUnnamed, dFuture, gReset, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lUnnamed, sUnnamed, dFuture, gRearrange, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lUnnamed, sUnnamed, dFuture, gRearrangeThenReset, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lUnnamed, sUnnamed, dNotJson, gNone, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lUnnamed, sUnnamed, dNotJson, gReset, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lUnnamed, sUnnamed, dNotJson, gRearrange, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lUnnamed, sUnnamed, dNotJson, gRearrangeThenReset, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lUnnamed, sUnnamed, dEmpty, gNone, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lUnnamed, sUnnamed, dEmpty, gReset, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lUnnamed, sUnnamed, dEmpty, gRearrange, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lUnnamed, sUnnamed, dEmpty, gRearrangeThenReset, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lUnnamed, sUnnamed, dUnknownPane, gNone, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lUnnamed, sUnnamed, dUnknownPane, gReset, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lUnnamed, sUnnamed, dUnknownPane, gRearrange, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lUnnamed, sUnnamed, dUnknownPane, gRearrangeThenReset, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lUnnamed, sUnnamed, dUnopenable, gNone, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lUnnamed, sUnnamed, dUnopenable, gReset, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lUnnamed, sUnnamed, dUnopenable, gRearrange, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),
  (lUnnamed, sUnnamed, dUnopenable, gRearrangeThenReset, lrsNoDocument, "", false, lpiQuarantine, lpoDisabled, faUnchanged),

  # -- lAbsent: bound, nothing saved. The ordinary first run. ------------------
  (lAbsent, sBound, dAbsent, gNone, lrsNoDocument, "", false, lpiRemove, lpoRemoved, faAbsent),
  (lAbsent, sBound, dAbsent, gReset, lrsNoDocument, "", false, lpiRemove, lpoRemoved, faAbsent),
  (lAbsent, sBound, dAbsent, gRearrange, lrsNoDocument, "", false, lpiWrite, lpoWritten, faWritten),
  (lAbsent, sBound, dAbsent, gRearrangeThenReset, lrsNoDocument, "", false, lpiRemove, lpoRemoved, faAbsent),

  # -- lReadable: bound, and this build understands the document. --------------
  #
  # **THE ROWS WHERE A DOCUMENT IS REPLACED OR DELETED ON PURPOSE.** A restore
  # sets `userModified` (`binding.restoreDocument`'s own decision), so `gNone`
  # REWRITES rather than leaves alone — and for `dOlder` that rewrite is the
  # v1 -> v2 migration reaching the disk. `:reset-layout` clears the flag, so a
  # reset DELETES the document: that is the round trip PLAT-6 designed and it
  # is destructive by design, which is exactly why it is enumerated here beside
  # the destructive cells that are NOT by design.
  (lReadable, sBound, dCurrent, gNone, lrsRestored, "", false, lpiWrite, lpoWritten, faWritten),
  (lReadable, sBound, dCurrent, gReset, lrsRestored, "", false, lpiRemove, lpoRemoved, faAbsent),
  (lReadable, sBound, dCurrent, gRearrange, lrsRestored, "", false, lpiWrite, lpoWritten, faWritten),
  (lReadable, sBound, dCurrent, gRearrangeThenReset, lrsRestored, "", false, lpiRemove, lpoRemoved, faAbsent),
  (lReadable, sBound, dOlder, gNone, lrsRestored, "", false, lpiWrite, lpoWritten, faWritten),
  (lReadable, sBound, dOlder, gReset, lrsRestored, "", false, lpiRemove, lpoRemoved, faAbsent),
  (lReadable, sBound, dOlder, gRearrange, lrsRestored, "", false, lpiWrite, lpoWritten, faWritten),
  (lReadable, sBound, dOlder, gRearrangeThenReset, lrsRestored, "", false, lpiRemove, lpoRemoved, faAbsent),

  # -- lPrecedenceModified: quarantined AND userModified. ----------------------
  #
  # **THE CELL THE THIRD FINDING LIVES IN.** The session could not read the
  # document AND then rearranged a pane, so `quarantined` and `userModified` are
  # BOTH true and the two branches of `layoutPersistPlan` disagree. Quarantine
  # must win: weaken the first branch to
  # `quarantined and (b.isNil or not b.userModified)` and every one of these
  # four rows writes a `version: 2` document over the user's file.
  (lPrecedenceModified, sBound, dFuture, gRearrange, lrsUnreadable, "UnknownVersion", true, lpiQuarantine, lpoQuarantined, faUnchanged),
  (lPrecedenceModified, sBound, dNotJson, gRearrange, lrsUnreadable, "NotJson", true, lpiQuarantine, lpoQuarantined, faUnchanged),
  (lPrecedenceModified, sBound, dEmpty, gRearrange, lrsUnreadable, "EmptyDocument", true, lpiQuarantine, lpoQuarantined, faUnchanged),
  (lPrecedenceModified, sBound, dUnknownPane, gRearrange, lrsUnreadable, "UnknownPane", true, lpiQuarantine, lpoQuarantined, faUnchanged),

  # -- lPrecedenceUnmodified: quarantined and NOT userModified. ----------------
  #
  # THE OTHER DIRECTION, and it is the one a reordering breaks: test
  # `b.isNil or not b.userModified` first and every one of these twelve rows
  # answers `lpiRemove` and DELETES a document this build merely failed to
  # understand. Both directions are needed, or "quarantine is tested first" is
  # a fact about one half of the disagreement.
  (lPrecedenceUnmodified, sBound, dFuture, gNone, lrsUnreadable, "UnknownVersion", true, lpiQuarantine, lpoQuarantined, faUnchanged),
  (lPrecedenceUnmodified, sBound, dFuture, gReset, lrsUnreadable, "UnknownVersion", true, lpiQuarantine, lpoQuarantined, faUnchanged),
  (lPrecedenceUnmodified, sBound, dFuture, gRearrangeThenReset, lrsUnreadable, "UnknownVersion", true, lpiQuarantine, lpoQuarantined, faUnchanged),
  (lPrecedenceUnmodified, sBound, dNotJson, gNone, lrsUnreadable, "NotJson", true, lpiQuarantine, lpoQuarantined, faUnchanged),
  (lPrecedenceUnmodified, sBound, dNotJson, gReset, lrsUnreadable, "NotJson", true, lpiQuarantine, lpoQuarantined, faUnchanged),
  (lPrecedenceUnmodified, sBound, dNotJson, gRearrangeThenReset, lrsUnreadable, "NotJson", true, lpiQuarantine, lpoQuarantined, faUnchanged),
  (lPrecedenceUnmodified, sBound, dEmpty, gNone, lrsUnreadable, "EmptyDocument", true, lpiQuarantine, lpoQuarantined, faUnchanged),
  (lPrecedenceUnmodified, sBound, dEmpty, gReset, lrsUnreadable, "EmptyDocument", true, lpiQuarantine, lpoQuarantined, faUnchanged),
  (lPrecedenceUnmodified, sBound, dEmpty, gRearrangeThenReset, lrsUnreadable, "EmptyDocument", true, lpiQuarantine, lpoQuarantined, faUnchanged),
  (lPrecedenceUnmodified, sBound, dUnknownPane, gNone, lrsUnreadable, "UnknownPane", true, lpiQuarantine, lpoQuarantined, faUnchanged),
  (lPrecedenceUnmodified, sBound, dUnknownPane, gReset, lrsUnreadable, "UnknownPane", true, lpiQuarantine, lpoQuarantined, faUnchanged),
  (lPrecedenceUnmodified, sBound, dUnknownPane, gRearrangeThenReset, lrsUnreadable, "UnknownPane", true, lpiQuarantine, lpoQuarantined, faUnchanged),

  # -- lEacces: the row whose quarantine comes from a different call. ----------
  #
  # Its own lane because its PRECONDITION can fail — `chmod 000` denies root
  # nothing — and a lane that cannot be measured must skip loudly as a unit
  # rather than weaken four cells inside another case.
  (lEacces, sBound, dUnopenable, gNone, lrsUnreadable, "UnreadableFile", true, lpiQuarantine, lpoQuarantined, faUnchanged),
  (lEacces, sBound, dUnopenable, gReset, lrsUnreadable, "UnreadableFile", true, lpiQuarantine, lpoQuarantined, faUnchanged),
  (lEacces, sBound, dUnopenable, gRearrange, lrsUnreadable, "UnreadableFile", true, lpiQuarantine, lpoQuarantined, faUnchanged),
  (lEacces, sBound, dUnopenable, gRearrangeThenReset, lrsUnreadable, "UnreadableFile", true, lpiQuarantine, lpoQuarantined, faUnchanged),
]

# ---------------------------------------------------------------------------
# THE PLAN TABLE. `layoutPersistPlan`'s own two inputs, exhaustively.
#
# Six cells, and two of them are UNREACHABLE THROUGH THE PRODUCT — which is a
# claim that has to be asserted rather than asserted-about. See the case below:
# the assertion is that `layoutPersistPlanOf` never hands a nil binding to this
# routine, and it is written so that REMOVING the guard reddens it.
# ---------------------------------------------------------------------------

type
  PlanBindingKind* = enum
    pbNil = "nil-binding"
    pbUnmodified = "untouched-binding"
    pbModified = "modified-binding"

  PlanRow* = tuple
    binding: PlanBindingKind
    quarantined: bool
    intent: LayoutPersistIntent
    writesText: bool
    reachable: bool
    reason: string
      ## Empty for a reachable cell; why not, for an unreachable one.

const
  ExpectedPlanCells = 6
  ExpectedPlanReachable = 4

const PlanTable: array[ExpectedPlanCells, PlanRow] = [
  (pbNil, false, lpiRemove, false, false,
   "`layoutPersistPlanOf` returns before calling this routine whenever " &
   "`layoutPersistenceEnabled()` is false, and that predicate implies " &
   "`layoutBindingEnabled()`, which implies the binding is not nil. The arm " &
   "is defensive, not reachable."),
  (pbNil, true, lpiQuarantine, false, false,
   "Same guard. Note this cell answers what the guard itself answers, so it " &
   "is invisible from outside the module — which is why the reachability " &
   "claim is asserted against the GUARD rather than against this answer."),
  (pbUnmodified, false, lpiRemove, false, true, ""),
  (pbUnmodified, true, lpiQuarantine, false, true, ""),
  (pbModified, false, lpiWrite, true, true, ""),
  (pbModified, true, lpiQuarantine, false, true, ""),
]

# ---------------------------------------------------------------------------
# THE KIND TABLE. Every value `LayoutRestoreReport.kind` can take in this build.
#
# Three are `app/layout/persistence.nim`'s own, one is its fallback literal, and
# eight are `layout_model.LayoutDecodeErrorKind`'s — plus `""` for a success.
# Two are UNREACHABLE and say why; the rest name a document that produces them.
# ---------------------------------------------------------------------------

type
  KindRow* = tuple
    kind: string
    reachable: bool
    text: string
      ## The document that produces it, for a reachable kind.
    reason: string
      ## Why it cannot be produced, for an unreachable one.

const
  ExpectedKindCells = 13
  ExpectedKindReachable = 11

const KindTable: array[ExpectedKindCells, KindRow] = [
  ("", true, """{"version": 2, "layout": {"kind": "pane", "pane": "calltrace"}, "docked": []}""", ""),
  ("NotJson", true, "{not json at all", ""),
  ("EmptyDocument", true, "   \n  ", ""),
  ("UnreadableFile", true, "", ""),
    # Two producers, and only one of them is a document: the host's `readFile`
    # failure (asserted in the EACCES lane) and `adoptLayoutDocument`'s
    # nil-binding arm (asserted in this case, by direct call). The second is
    # unreachable from `restoreLayoutForSession` for the same reason `pbNil` is.
  ("NotAnObject", true, "[1, 2, 3]", ""),
  ("UnknownVersion", true, """{"version": 99, "layout": {"kind": "pane", "pane": "editor"}, "docked": []}""", ""),
  ("UnknownPane", true, """{"version": 2, "layout": {"kind": "pane", "pane": "holodeck"}, "docked": []}""", ""),
  ("UnknownNodeKind", true, """{"version": 2, "layout": {"kind": "hypercube"}, "docked": []}""", ""),
  ("MissingField", true, """{"version": 2, "docked": []}""", ""),
  ("WrongFieldType", true, """{"version": "2", "layout": {"kind": "pane", "pane": "calltrace"}, "docked": []}""", ""),
  ("UnknownEdge", true, """{"version": 2, "layout": {"kind": "pane", "pane": "calltrace"}, "docked": [{"pane": "editor", "edge": "leGalactic", "order": 0}]}""", ""),
  ("Refused", false, "",
   "`persistence.adoptLayoutDocument` composes this literal when " &
   "`restoreDocument` refuses WITHOUT reporting a kind. " &
   "`binding.restoreDocument` has exactly one non-applied return and it sets " &
   "`problem = some(e.kind)` on it, so the literal has no producer. Asserted " &
   "over the whole corpus below: every refusal carries a kind."),
  ("DockedPanesUnsupported", false, "",
   "`layout_model` raises it only from `restoreLayout`, the BARE-NODE entry " &
   "point, which cannot represent a docked pane. `adoptLayoutDocument` calls " &
   "`restoreDocument` -> `restoreLayoutDocument`, which decodes docked panes " &
   "rather than refusing them. Asserted both ways below: the same document " &
   "restores here and raises there."),
]

# ---------------------------------------------------------------------------
# THE FAILURE TABLE. The two arms of `persistLayoutForSession` that answer
# `lpoFailed`, and the obstruction that reaches each.
#
# THERE ARE EXACTLY TWO, and that is asserted rather than counted off the array:
# `LayoutPersistIntent` has three values and only two of them touch the
# filesystem — `lpiQuarantine` performs no I/O at all, so it has no `except`
# arm and cannot fail. The completeness claim below is over the INTENTS, so an
# intent that grew an I/O path would redden this suite.
#
# BOTH OBSTRUCTIONS ARE REAL, on a real `createTempDir()`, and neither is an
# injected failure — the same rule the `EACCES` lane follows, for the same
# reason: an injected failure grades the report and not the module.
# ---------------------------------------------------------------------------

type
  FailingArm* = enum
    faWriteArm = "write"
    faRemoveArm = "remove"

  FailureRow* = tuple
    arm: FailingArm
    intent: LayoutPersistIntent
    obstruction: string
      ## What is done to the filesystem to reach the arm.
    messageStem: string
      ## The sentence `persistLayoutForSession` composes for this arm. Asserted
      ## as a PREFIX rather than matched whole, because the tail is the errno's
      ## own message and belongs to the host.
    needsEnforcedPermissions: bool
      ## Whether the obstruction can be defeated by a privileged run. Only the
      ## remove arm's can, which is why only it has a precondition and a skip.

const ExpectedFailureCells = 2

const FailureTable: array[ExpectedFailureCells, FailureRow] = [
  (faWriteArm, lpiWrite,
   "a DIRECTORY at `<path>.new`, so the staging write cannot open its file " &
   "while `<path>` itself stays free and the state directory stays writable",
   "the layout could not be saved: ", false),
  (faRemoveArm, lpiRemove,
   "the state directory stripped of its write permission, so the unlink is " &
   "refused while the document itself stays perfectly readable",
   "the saved layout could not be removed: ", true),
]

proc failureRow(arm: FailingArm): FailureRow =
  ## The row for one arm. A `proc`, and it calls `check` nowhere — §13.
  for row in FailureTable:
    if row.arm == arm:
      return row
  FailureTable[0]

# ---------------------------------------------------------------------------
# Fixtures. Values only; nothing here calls `check`.
# ---------------------------------------------------------------------------

proc caps(): TerminalCapabilities =
  resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"),
    initCapabilityFlags())

proc newRuntime(cols, rows: int): TuiRuntime =
  newTuiRuntime(newTuiApp(), caps(), cols, rows)

proc newBoundRuntime(cols, rows: int): TuiRuntime =
  result = newRuntime(cols, rows)
  discard result.enableLayoutBinding()

proc typeLine(rt: TuiRuntime; line: string): RuntimeOutcome =
  result = rt.handleToken(":", 0'i64)
  for ch in line:
    result = rt.handleToken($ch, 0'i64)
  result = rt.handleToken("\r", 0'i64)

proc filesUnder(root: string): seq[string] =
  ## Every file below `root`, relative and sorted. THE WHOLE STATE ROOT, so a
  ## stray `.new` from a failed rename is visible as well as the document.
  result = @[]
  if not dirExists(root):
    return
  for path in walkDirRec(root):
    result.add path.relativePath(root)
  result.sort()

proc documentText(d: DocumentKind): string =
  ## The bytes planted for one document state. `dAbsent` plants nothing.
  case d
  of dAbsent: ""
  of dCurrent:
    """{"version": 2,
  "layout": {"kind": "pane", "pane": "calltrace"},
  "docked": []}
"""
  of dOlder:
    # No `docked` key at all — that is what makes it a v1 document, and
    # `migrateV1toV2` is what makes it restorable.
    """{"version": 1,
  "layout": {"kind": "pane", "pane": "calltrace"}}
"""
  of dFuture:
    """{"version": 99,
  "layout": {"kind": "pane", "pane": "editor"},
  "docked": []}
"""
  of dNotJson: "{not json at all"
  of dEmpty: "   \n  "
  of dUnknownPane:
    """{"version": 2,
  "layout": {"kind": "pane", "pane": "holodeck"},
  "docked": []}
"""
  of dUnopenable:
    # A document THIS BUILD CAN READ. The permission is the only thing wrong
    # with it, which is what makes the failure transient and the deletion
    # expensive.
    """{"version": 2,
  "layout": {"kind": "pane", "pane": "calltrace"},
  "docked": []}
"""

type
  Sandbox = object
    root: string
    trace: string
    document: string

proc newSandbox(tag: string): Sandbox =
  let base = createTempDir("plat6-matrix-" & tag & "-", "")
  result = Sandbox(root: base / "state", trace: base / "recording.ct")
  createDir(result.trace)
  putEnv(LayoutDirEnvVar, result.root)
  result.document = layoutDocumentPathFor(result.trace)

proc restorePermissions(path: string) =
  ## Put a document's ordinary permissions back.
  ##
  ## It does nothing when the file is gone, and that is the point: a defect
  ## under grading DELETES that file, and a bare `setFilePermissions` would
  ## raise an `OSError` on the mutated tree and take the rest of the case's
  ## assertions — and the suite's count — down with it.
  if fileExists(path):
    setFilePermissions(path, {fpUserRead, fpUserWrite})

proc restoreDirectoryPermissions(path: string) =
  ## Put a state DIRECTORY's ordinary permissions back.
  ##
  ## The remove arm of `FailureTable` takes the write permission off the
  ## document's directory, and a directory left like that defeats `removeDir`
  ## below — so the teardown would raise and take the rest of the case's
  ## assertions, and the suite's count, down with it. Unconditional and
  ## idempotent: every sandbox pays one `dirExists`.
  if dirExists(path):
    setFilePermissions(path, {fpUserRead, fpUserWrite, fpUserExec})

proc dispose(box: Sandbox) =
  restoreDirectoryPermissions(box.document.parentDir)
  restorePermissions(box.document)
  delEnv(LayoutDirEnvVar)
  removeDir(box.root.parentDir)

type
  CellResult = object
    ## What one cell of the session matrix actually produced. Values only —
    ## the assertions are in the `template` below.
    status: LayoutRestoreStatus
    kind: string
    quarantined: bool
    boundPath: string
    intent: LayoutPersistIntent
    outcome: LayoutPersistOutcome
    planted: string
    plantedExisted: bool
    after: string
    afterExists: bool
    files: seq[string]
    documentName: string
    documentPath: string
    deniedRead: bool
      ## For `dUnopenable` only: whether the permission removal really denied
      ## this process a read. Measured, never assumed.

proc runCell(row: MatrixRow): CellResult =
  ## Drive one cell end to end through the product's own entry points.
  let box = newSandbox($row.session & "-" & $row.document & "-" & $row.gesture)
  try:
    result.documentName = box.document.extractFilename
    result.documentPath = box.document
    result.planted = documentText(row.document)
    result.plantedExisted = row.document != dAbsent
    result.deniedRead = true
    if result.plantedExisted:
      createDir(box.document.parentDir)
      writeFile(box.document, result.planted)
      if row.document == dUnopenable:
        setFilePermissions(box.document, {})
        # THE PRECONDITION, MEASURED RATHER THAN ASSUMED.
        result.deniedRead = false
        try:
          discard readFile(box.document)
        except CatchableError:
          result.deniedRead = true

    let rt =
      if row.session == sNoBinding: newRuntime(80, 24)
      else: newBoundRuntime(80, 24)
    if row.session != sUnnamed:
      let report = restoreLayoutForSession(rt, box.trace)
      result.status = report.status
      result.kind = report.kind
    result.quarantined = rt.layoutDocumentQuarantined
    result.boundPath = rt.layoutDocument

    case row.gesture
    of gNone: discard
    of gReset: discard rt.typeLine("reset-layout")
    of gRearrange: discard rt.typeLine("dock bottom")
    of gRearrangeThenReset:
      discard rt.typeLine("dock bottom")
      discard rt.typeLine("reset-layout")

    result.intent = rt.layoutPersistPlanOf().intent
    let persisted = persistLayoutForSession(rt)
    result.outcome = persisted.outcome

    result.files = filesUnder(box.root)
    restorePermissions(box.document)
    result.afterExists = fileExists(box.document)
    result.after = if result.afterExists: readFile(box.document) else: ""
  finally:
    box.dispose()

# ---------------------------------------------------------------------------
# The assertion helpers. TEMPLATES, every one of them — §13.
# ---------------------------------------------------------------------------

template assertCell(row: MatrixRow) =
  ## One cell of the session matrix, asserted through to the FILE.
  ##
  ## Six or eight assertions: the report, the path the session bound, and the
  ## file. The file half is the one the three findings would have moved.
  ##
  ## **`status` AND `kind` ARE NOT ASSERTED FOR THE `sUnnamed` ROWS, and that
  ## is the fix for an assertion that could not fail.** `restoreLayoutForSession`
  ## is never called for that lane — it is what makes the lane the lane — so
  ## `CellResult.status` and `.kind` are still default-initialised, and the
  ## table declares `lrsNoDocument` / `""`, which are the SAME default. Those
  ## 64 comparisons were true by construction: no edit to the product could
  ## have moved either side. The file's own comment disclosed it and disclosure
  ## is not a defence — an assertion that cannot fail is a count that is not
  ## evidence (traps §10, §4c). They are DROPPED rather than repaired, because
  ## there is nothing to repair: the lane's real facts are that no document was
  ## named and nothing on disk moved, and both are asserted. The table's own
  ## columns for those rows are pinned as a convention in the input-space case,
  ## so they are not free-floating data nobody reads.
  block:
    inc countedCells
    let got = runCell(row)
    checkpoint($row.session & " | " & $row.document & " | " & $row.gesture &
               " -> " & $got.status & " [" & got.kind & "] q=" &
               $got.quarantined & " intent=" & $got.intent & " outcome=" &
               $got.outcome & " path='" & got.boundPath & "' files=" &
               $got.files)
    if row.session != sUnnamed:
      ck got.status == row.status
      ck got.kind == row.kind
    # THE PATH THE SESSION BOUND, per cell rather than once. For `sUnnamed` it
    # is the fact that DEFINES the lane and it replaces the two comparisons
    # above; for `sNoBinding` it is the stronger form of "nothing was read" —
    # no path was even computed; for `sBound` it is the key, and a store that
    # keyed the document by something else would move it.
    if row.session == sBound:
      ck got.boundPath == got.documentPath
    else:
      ck got.boundPath.len == 0
    ck got.quarantined == row.quarantined
    ck got.intent == row.intent
    ck got.outcome == row.outcome
    # ---- THE FILE, not the report ----
    case row.file
    of faAbsent:
      ck not got.afterExists
      ck got.files.len == 0
    of faUnchanged:
      ck got.afterExists
      # BYTE FOR BYTE. `==` on the whole text rather than a size or a hash,
      # because "the file is still there" is satisfied by a file this build
      # rewrote to the same length.
      ck got.after == got.planted
      ck got.files == @[LayoutDocumentDirName / got.documentName]
    of faWritten:
      ck got.afterExists
      # EXACTLY ONE FILE: a `.new` left behind means the rename did not happen
      # and the next launch reads a half-written document.
      ck got.files == @[LayoutDocumentDirName / got.documentName]
      # PRODUCED BY THIS BUILD, and different from whatever was there.
      ck (not got.plantedExisted) or got.after != got.planted

template runLane(wanted: MatrixLane) =
  ## Every row of one lane, and the COUNT — §4b: a loop whose membership is
  ## knowable must assert the count, not its non-emptiness.
  ##
  ## The parameter is `wanted` rather than `lane` for a reason worth one line:
  ## a template substitutes its parameter name everywhere, so a parameter called
  ## `lane` rewrites `row.lane` into `row.<the argument>` and the suite does not
  ## compile. The failure is loud; the near miss — a parameter name that IS a
  ## field name and still resolves — would not be.
  block:
    var ran = 0
    for row in SessionMatrix:
      if row.lane == wanted:
        inc ran
        assertCell(row)
    checkpoint($wanted & " lane cells: " & $ran)
    ck ran == ExpectedLaneCounts[wanted]

# ---------------------------------------------------------------------------

suite "PLAT-6: the persistence decision, enumerated":

  test "the input space: three dimensions, 96 cells, every triple exactly once":
    # THE TABLE'S OWN INTEGRITY, asserted before anything is graded against it.
    # A table that had lost a row, gained a dimension value, or covered one
    # triple twice and another never would still produce a green run of every
    # case below — every assertion it still made would be true (§4b).
    ck SessionMatrix.len == ExpectedCells
    # THE PRODUCT OF THE DIMENSIONS. This is what fails when a dimension
    # appears or disappears: add a ninth `DocumentKind` and 3*9*4 = 108 is no
    # longer 96, whatever the array happens to contain.
    let dims = (SessionKind.high.ord - SessionKind.low.ord + 1) *
               (DocumentKind.high.ord - DocumentKind.low.ord + 1) *
               (GestureKind.high.ord - GestureKind.low.ord + 1)
    checkpoint("dimensions: " &
      $(SessionKind.high.ord - SessionKind.low.ord + 1) & " sessions x " &
      $(DocumentKind.high.ord - DocumentKind.low.ord + 1) & " documents x " &
      $(GestureKind.high.ord - GestureKind.low.ord + 1) & " gestures = " & $dims)
    ck dims == ExpectedCells

    # EVERY TRIPLE EXACTLY ONCE. The completeness proof: 96 assertions, one per
    # corner of the cross, so a corner that is merely absent fails by name.
    var seen: array[SessionKind, array[DocumentKind, array[GestureKind, int]]]
    for row in SessionMatrix:
      inc seen[row.session][row.document][row.gesture]
    for s in SessionKind:
      for d in DocumentKind:
        for g in GestureKind:
          if seen[s][d][g] != 1:
            checkpoint("triple " & $s & "/" & $d & "/" & $g & " appears " &
                       $seen[s][d][g] & " times")
          ck seen[s][d][g] == 1

    # THE LANE PARTITION, as a histogram. The lanes are how the mutation arms
    # name ONE case each, so a row that drifted into the wrong lane would move
    # a kill into a case that does not name it.
    var perLane: array[MatrixLane, int]
    for row in SessionMatrix:
      inc perLane[row.lane]
    var laneTotal = 0
    for lane in MatrixLane:
      checkpoint($lane & ": " & $perLane[lane])
      ck perLane[lane] == ExpectedLaneCounts[lane]
      laneTotal += perLane[lane]
    ck laneTotal == ExpectedCells

    # AND THE OUTPUT SPACE IS COVERED. A table of 96 cells that only ever
    # expected one intent would satisfy every assertion in this file; these
    # four say the cross reaches every answer the decision can give.
    var intents: array[LayoutPersistIntent, int]
    var outcomes: array[LayoutPersistOutcome, int]
    var files: array[FileAfter, int]
    for row in SessionMatrix:
      inc intents[row.intent]
      inc outcomes[row.outcome]
      inc files[row.file]
    for i in LayoutPersistIntent:
      checkpoint("intent " & $i & ": " & $intents[i])
      ck intents[i] > 0
    for f in FileAfter:
      checkpoint("file-after " & $f & ": " & $files[f])
      ck files[f] > 0
    # AND THE EXACT SPLIT, not just non-emptiness (§4b: when the membership is
    # knowable, assert the COUNT). This is the column the three findings would
    # have moved, so the number of cells watching each of its three values is
    # the number worth pinning: 76 cells require the planted bytes to be there
    # afterwards, 5 require a document this build produced, and 15 require no
    # file at all.
    ck files[faUnchanged] == 76
    ck files[faWritten] == 5
    ck files[faAbsent] == 15
    # `lpoFailed` is the one outcome no cell of THIS CROSS reaches, and the
    # reason is a property of the cross rather than of the filesystem: a
    # failure arm is reached by OBSTRUCTING the filesystem, and no session
    # obstructs anything. `FailureTable` and its two cases own both arms, on an
    # ordinary `createTempDir()`; the equivalence is asserted just below, so
    # this zero is a partition rather than a gap.
    ck outcomes[lpoFailed] == 0
    ck outcomes[lpoDisabled] == 64
    ck outcomes[lpoQuarantined] == 20
    ck outcomes[lpoWritten] == 5
    ck outcomes[lpoRemoved] == 7

    # **THE `sUnnamed` ROWS' REPORT COLUMNS, PINNED AS A CONVENTION.**
    # `assertCell` does not compare them against the product, because
    # `restoreLayoutForSession` is never called for that lane and both sides of
    # the comparison would be the same default-initialised value. So they are
    # pinned here as data instead — a §4b COUNT rather than 64 comparisons that
    # cannot fail — which is what keeps them from being columns nobody reads.
    var unnamedConvention = 0
    for row in SessionMatrix:
      if row.session == sUnnamed and row.status == lrsNoDocument and
         row.kind.len == 0:
        inc unnamedConvention
    checkpoint("`sUnnamed` rows declaring the no-restore convention: " &
               $unnamedConvention)
    ck unnamedConvention == ExpectedLaneCounts[lUnnamed]

    # **AND THE OUTCOME SPACE IS COVERED ACROSS BOTH TABLES.** The zero above
    # is only honest if something else reaches `lpoFailed`, so the partition is
    # asserted rather than described: every `LayoutPersistIntent` that performs
    # I/O has an arm in `FailureTable`, and `lpiQuarantine`, which performs
    # none, has none.
    ck FailureTable.len == ExpectedFailureCells
    var armsSeen: array[FailingArm, int]
    var intentsWithAnArm: array[LayoutPersistIntent, int]
    for row in FailureTable:
      inc armsSeen[row.arm]
      inc intentsWithAnArm[row.intent]
      # AN OBSTRUCTION WITHOUT A DESCRIPTION IS AN ARM NOBODY CAN REPRODUCE.
      ck row.obstruction.len > 40
      ck row.messageStem.len > 20
    for arm in FailingArm:
      ck armsSeen[arm] == 1
    ck intentsWithAnArm[lpiWrite] == 1
    ck intentsWithAnArm[lpiRemove] == 1
    # `lpiQuarantine` returns a value and touches no file, so it has no `except`
    # arm to reach. This is the line that reddens if it ever grows one.
    ck intentsWithAnArm[lpiQuarantine] == 0
    ck failureRow(faWriteArm).arm == faWriteArm
    ck failureRow(faRemoveArm).arm == faRemoveArm

  test "OFF: with no layout binding, all 32 cells are inert and no file moves":
    # THE FLAG-OFF HALF OF THE CROSS. Not one document state, but all eight —
    # including the two that would make a bound session quarantine and the one
    # that would make it write. With no binding the answer is the same for all
    # of them, and the state directory is not touched even by a `stat`.
    # THE STRONGER STATEMENT — no path is computed at all — used to be made
    # once here, by a thirty-third `runCell`. `assertCell` now makes it for
    # every cell of every lane, so the extra run said nothing the lane did not.
    runLane(lOff)

  test "BOUND BUT UNNAMED: a rearrangeable session with no document writes nowhere":
    # THE DIMENSION A SUMMARY OF THIS DECISION DROPS. Both halves of
    # `layoutPersistenceEnabled` are required, and this lane is the one where
    # the first holds and the second does not: the gestures apply, the
    # arrangement really changes, and the exit still writes nowhere.
    runLane(lUnnamed)
    # THE FACT THAT DISTINGUISHES THIS LANE FROM `lOff`: the binding is on, the
    # gesture took effect, and the session is still bound to no document.
    let box = newSandbox("unnamed-probe")
    try:
      let rt = newBoundRuntime(80, 24)
      ck rt.layoutBindingEnabled()
      discard rt.typeLine("dock bottom")
      ck rt.app.layoutBinding.userModified
      ck rt.layoutDocument.len == 0
      ck not rt.layoutPersistenceEnabled()
      ck rt.layoutPersistPlanOf().intent == lpiQuarantine
      ck persistLayoutForSession(rt).outcome == lpoDisabled
      ck filesUnder(box.root).len == 0
    finally:
      box.dispose()

  test "ABSENT: a first run restores nothing and leaves nothing behind":
    # The ordinary first run, across all four gestures. Only the one that
    # rearranges creates a file; the other three must not, because persisting a
    # profile default would freeze the profile on the next launch.
    runLane(lAbsent)

  test "READABLE: a document this build understands is rewritten, or deleted by a reset":
    # THE DESTRUCTIVE CELLS THAT ARE DESTRUCTIVE BY DESIGN, enumerated beside
    # the ones that must not be. A restore counts as a user modification, so
    # even `gNone` rewrites; `:reset-layout` clears the flag, so the exit
    # deletes.
    runLane(lReadable)

    # THE v1 -> v2 REPLACEMENT, NAMED. `dOlder` restores by migrating forward,
    # and the exit then writes the migrated document over the original: a file
    # REPLACED with no user gesture at all. Intended — §6 has no backward
    # migration — and asserted so it is a decision on the record rather than a
    # side effect nobody wrote down.
    let box = newSandbox("older")
    try:
      createDir(box.document.parentDir)
      writeFile(box.document, documentText(dOlder))
      let before = parseJson(readFile(box.document))
      ck before["version"].getInt == 1
      ck not before.hasKey("docked")
      let rt = newBoundRuntime(80, 24)
      ck restoreLayoutForSession(rt, box.trace).status == lrsRestored
      ck persistLayoutForSession(rt).outcome == lpoWritten
      let after = parseJson(readFile(box.document))
      checkpoint("v" & $before["version"].getInt & " -> v" &
                 $after["version"].getInt)
      ck after["version"].getInt == LayoutSchemaVersion
      ck after["version"].getInt != before["version"].getInt
      ck after.hasKey("docked")
      # …and the arrangement is the one the v1 document described, so the
      # replacement is a migration rather than a reset wearing its clothes.
      ck $after["layout"] == $before["layout"]
    finally:
      box.dispose()

  test "PRECEDENCE: a session that REARRANGED over an unreadable document leaves it alone":
    # **THE CELL THE THIRD FINDING LIVES IN, AND THE REASON `quarantined` IS
    # TESTED FIRST.** `quarantined` and `userModified` are both true here and
    # the two branches of `layoutPersistPlan` give different answers. Weaken the
    # first branch to `quarantined and (b.isNil or not b.userModified)` — a
    # change that survives every other arm in the harness — and all four of
    # these rows write a `version: 2` document over the user's file. For the
    # `dFuture` row that is a document written by a NEWER build, destroyed
    # because the user opened an older binary once and moved a pane.
    runLane(lPrecedenceModified)
    # THE TWO FLAGS, SEPARATELY, on the expensive row — so a reader can see
    # that the cell really is the disagreement and not a coincidence.
    let box = newSandbox("precedence")
    try:
      createDir(box.document.parentDir)
      writeFile(box.document, documentText(dFuture))
      let planted = readFile(box.document)
      let rt = newBoundRuntime(80, 24)
      ck restoreLayoutForSession(rt, box.trace).status == lrsUnreadable
      discard rt.typeLine("dock bottom")
      ck rt.layoutDocumentQuarantined
      ck rt.app.layoutBinding.userModified
      # BOTH TRUE AT ONCE — the input the weakening reads differently.
      ck rt.layoutDocumentQuarantined and rt.app.layoutBinding.userModified
      ck rt.layoutPersistPlanOf().intent == lpiQuarantine
      ck rt.layoutPersistPlanOf().text.len == 0
      ck persistLayoutForSession(rt).outcome == lpoQuarantined
      ck readFile(box.document) == planted
      ck parseJson(readFile(box.document))["version"].getInt == 99
    finally:
      box.dispose()

  test "PRECEDENCE: a session that did NOT rearrange over an unreadable document leaves it alone":
    # THE OTHER DIRECTION OF THE SAME DISAGREEMENT, and the one a REORDERING
    # breaks rather than a weakening: test `b.isNil or not b.userModified`
    # first, and every one of these twelve rows answers `lpiRemove` and DELETES
    # a document this build merely failed to understand. Without this case
    # "quarantine wins" is established for one half of the disagreement.
    runLane(lPrecedenceUnmodified)
    let box = newSandbox("precedence-unmodified")
    try:
      createDir(box.document.parentDir)
      writeFile(box.document, documentText(dFuture))
      let planted = readFile(box.document)
      let rt = newBoundRuntime(80, 24)
      ck restoreLayoutForSession(rt, box.trace).status == lrsUnreadable
      ck rt.layoutDocumentQuarantined
      # NOT modified — the restore failed, so nothing set the flag.
      ck not rt.app.layoutBinding.userModified
      ck rt.layoutPersistPlanOf().intent == lpiQuarantine
      ck persistLayoutForSession(rt).outcome == lpoQuarantined
      ck readFile(box.document) == planted
    finally:
      box.dispose()

  test "EACCES: a document that will not OPEN is left alone, whatever the session did":
    # THE ROW WHOSE QUARANTINE COMES FROM `markLayoutDocumentUnreadable` RATHER
    # THAN FROM `adoptLayoutDocument` — the first of the three findings, now
    # crossed with all four gestures instead of the one the behavioural suite
    # drives. THE CONDITION IS REPRODUCED, NOT INJECTED.
    #
    # A LOUD SKIP AS A UNIT. `chmod 000` denies root nothing and some
    # filesystems do not enforce permissions at all; on such a host these four
    # cells would read the document, restore it happily, and report `[OK]` over
    # a property never reached. So the lane probes first and SKIPS, which moves
    # the run's SKIPPED tally rather than passing quietly.
    let probeBox = newSandbox("eacces-probe")
    var denied = false
    try:
      createDir(probeBox.document.parentDir)
      writeFile(probeBox.document, documentText(dUnopenable))
      setFilePermissions(probeBox.document, {})
      try:
        discard readFile(probeBox.document)
      except CatchableError:
        denied = true
    finally:
      probeBox.dispose()
    if not denied:
      echo EaccesPreconditionBanner
      checkpoint(EaccesPreconditionBanner)
      eaccesLaneRan = false
      skip()
    else:
      runLane(lEacces)
      # THE POSITIVE TWIN, THROUGH THE SAME PATH AND THE SAME BYTES: with the
      # permission back and NOTHING else changed, the same document RESTORES.
      # Without it, every assertion above is also satisfied by a store that
      # refuses this document for some reason of its own.
      let box = newSandbox("eacces-twin")
      try:
        createDir(box.document.parentDir)
        writeFile(box.document, documentText(dUnopenable))
        setFilePermissions(box.document, {})
        let blocked = newBoundRuntime(80, 24)
        ck restoreLayoutForSession(blocked, box.trace).kind == UnreadableFileKind
        ck blocked.layoutDocumentQuarantined
        restorePermissions(box.document)
        let after = newBoundRuntime(80, 24)
        let good = restoreLayoutForSession(after, box.trace)
        checkpoint("with the permission back, restore -> " & $good.status)
        ck good.status == lrsRestored
        ck not after.layoutDocumentQuarantined
      finally:
        box.dispose()

  test "DURABILITY: the write is STAGED at `<path>.new` and renamed onto the document":
    # **TWO JOBS, ONE PROBE**, and they are the same probe because they are the
    # same fact seen from two sides.
    #
    #   1. `FailureTable`'s WRITE arm — the first of the two `except` arms in
    #      `persistLayoutForSession`, which the previous version of this file
    #      declared unreachable on a temporary directory. It is reachable, on
    #      an ordinary one, with no privilege and no injected failure: put a
    #      DIRECTORY where the staging file must go and `writeFile` cannot open
    #      it. Nothing else is touched — `<path>` is free, the state directory
    #      is writable, the process is unprivileged.
    #   2. **THE DURABILITY PROMISE, ASSERTED POSITIVELY.**
    #      `host/layout_store.nim`'s header says the document is written to
    #      `<path>.new` and MOVED onto `<path>`, so a process killed mid-write
    #      leaves the previous arrangement intact. Nothing asserted that:
    #      collapsing the two lines to `writeFile(path, plan.text)` left all
    #      four of PLAT-6's suites at 0 failed, and the only `.new` mentions in
    #      either suite were negative — "a stray `.new` would mean the rename
    #      did not happen" — which is trap §4a, a lone negative with no twin.
    #
    # The obstruction is what makes it a twin rather than a restatement: with
    # the collapse planted, the write goes straight to `<path>`, the directory
    # at `<path>.new` obstructs nothing, and this case reports `lpoWritten`
    # where it requires `lpoFailed`. Arm `M58`; control `S27`.
    let row = failureRow(faWriteArm)
    ck row.intent == lpiWrite
    ck not row.needsEnforcedPermissions
    let box = newSandbox("durability")
    try:
      createDir(box.document.parentDir)
      writeFile(box.document, documentText(dCurrent))
      let planted = readFile(box.document)
      let temp = box.document & LayoutDocumentTempSuffix

      createDir(temp)
      ck dirExists(temp)
      ck not fileExists(temp)

      let rt = newBoundRuntime(80, 24)
      # A RESTORE SETS `userModified`, so this session's plan is a WRITE with
      # no gesture at all — the same plan the `lReadable` rows carry.
      ck restoreLayoutForSession(rt, box.trace).status == lrsRestored
      ck rt.layoutPersistPlanOf().intent == row.intent
      ck rt.layoutPersistPlanOf().text.len > 0
      let failed = persistLayoutForSession(rt)
      checkpoint("WRITE -> outcome=" & $failed.outcome & "  " & failed.message)
      ck failed.outcome == lpoFailed
      ck failed.path == box.document
      ck failed.message.startsWith(row.messageStem)
      # **THE POSITIVE RENAME ASSERTION.** The errno the product reports names
      # the file it tried to OPEN, and it is `<path>.new` — so the bytes are
      # staged rather than written in place. This is the line the collapse
      # cannot satisfy, and it is a positive claim about `.new` rather than the
      # absence of one.
      ck failed.message.contains(temp)
      # AND THE PREVIOUS ARRANGEMENT IS INTACT, BYTE FOR BYTE — the promise the
      # staging exists to keep, asserted at the FILE like every cell above.
      ck fileExists(box.document)
      ck readFile(box.document) == planted

      # **THE TWIN, THROUGH THE SAME SESSION AND THE SAME PLAN.** Remove the
      # obstruction and NOTHING else: the same `rt`, the same `lpiWrite`, and
      # now it writes. Without this half, every assertion above is also
      # satisfied by a store that has stopped writing altogether.
      removeDir(temp)
      let written = persistLayoutForSession(rt)
      checkpoint("with `<path>.new` free, the same plan -> " & $written.outcome)
      ck written.outcome == lpoWritten
      ck written.message.len == 0
      ck readFile(box.document) != planted
      ck parseJson(readFile(box.document))["version"].getInt ==
         LayoutSchemaVersion
      # …AND THE STAGING FILE IS GONE, because it was RENAMED and not copied.
      # `filesUnder` reads the whole state root, so a surviving `.new` is
      # visible here rather than inferred.
      ck not fileExists(temp)
      ck filesUnder(box.root) ==
         @[LayoutDocumentDirName / box.document.extractFilename]
    finally:
      box.dispose()

  test "FAILED: a remove the filesystem refuses is reported, and the document stays":
    # `FailureTable`'s REMOVE arm — the second `except` arm, and the one whose
    # obstruction a privileged run defeats, so it carries the same LOUD SKIP as
    # the `EACCES` lane and for the same reason. The technique is that lane's
    # own: a real `setFilePermissions`, never an injected failure.
    #
    # THE DEFECT THIS GRADES is a remove that failed being reported as done.
    # `:reset-layout` promises the stale document is gone; a session that says
    # `removed` over a file still on disk has told the user the arrangement
    # they abandoned will not come back, and the next launch restores it. Arm
    # `M59`; control `S28`.
    let row = failureRow(faRemoveArm)
    ck row.intent == lpiRemove
    ck row.needsEnforcedPermissions
    # THE PRECONDITION, MEASURED ON ITS OWN SANDBOX BEFORE ANYTHING IS GRADED.
    let probeBox = newSandbox("remove-failure-probe")
    var refused = false
    try:
      createDir(probeBox.document.parentDir)
      writeFile(probeBox.document, documentText(dCurrent))
      setFilePermissions(probeBox.document.parentDir, {fpUserRead, fpUserExec})
      try:
        removeFile(probeBox.document)
      except CatchableError:
        refused = true
    finally:
      probeBox.dispose()
    if not refused:
      echo RemoveFailurePreconditionBanner
      checkpoint(RemoveFailurePreconditionBanner)
      removeFailureLaneRan = false
      skip()
    else:
      let box = newSandbox("remove-failure")
      try:
        createDir(box.document.parentDir)
        writeFile(box.document, documentText(dCurrent))
        let planted = readFile(box.document)
        let rt = newBoundRuntime(80, 24)
        ck restoreLayoutForSession(rt, box.trace).status == lrsRestored
        # `:reset-layout` clears `userModified`, so the plan is the REMOVE the
        # `lReadable` rows reach — this case obstructs it and they do not.
        discard rt.typeLine("reset-layout")
        ck rt.layoutPersistPlanOf().intent == row.intent

        setFilePermissions(box.document.parentDir, {fpUserRead, fpUserExec})
        let failed = persistLayoutForSession(rt)
        checkpoint("REMOVE -> outcome=" & $failed.outcome & "  " &
                   failed.message)
        ck failed.outcome == lpoFailed
        ck failed.path == box.document
        ck failed.message.startsWith(row.messageStem)
        # THE PATH IS NAMED. A save that could not be made is a fact about the
        # user's disk and the report has to say WHICH file.
        ck failed.message.contains(box.document)
        # AND THE DOCUMENT IS STILL THERE, byte for byte.
        ck fileExists(box.document)
        ck readFile(box.document) == planted

        # THE TWIN, same session and same plan: give the directory its write
        # permission back and nothing else, and the remove happens.
        restoreDirectoryPermissions(box.document.parentDir)
        let removed = persistLayoutForSession(rt)
        checkpoint("with the directory writable, the same plan -> " &
                   $removed.outcome)
        ck removed.outcome == lpoRemoved
        ck removed.message.len == 0
        ck not fileExists(box.document)
        ck filesUnder(box.root).len == 0
      finally:
        box.dispose()

  test "the plan table: six cells, four reachable and two a session cannot present":
    # `layoutPersistPlan`'s OWN inputs, exhaustively and as a direct call —
    # which is what makes the two unreachable cells assertable at all: the
    # routine answers them, and nothing in the product can ask.
    ck PlanTable.len == ExpectedPlanCells
    var reachable = 0
    var covered: array[PlanBindingKind, array[bool, int]]
    let nilBinding: LayoutBinding = nil
    var asserted = 0
    for row in PlanTable:
      inc asserted
      inc covered[row.binding][row.quarantined]
      if row.reachable:
        inc reachable
        ck row.reason.len == 0
      else:
        # AN UNREACHABLE CELL WITH NO REASON IS AN UNTESTED ONE WEARING A LABEL.
        ck row.reason.len > 40
      let b =
        case row.binding
        of pbNil: nilBinding
        of pbUnmodified: newBoundRuntime(80, 24).app.layoutBinding
        of pbModified:
          let rt = newBoundRuntime(80, 24)
          discard rt.typeLine("dock bottom")
          rt.app.layoutBinding
      if row.binding == pbModified:
        ck b.userModified
      elif row.binding == pbUnmodified:
        ck not b.userModified
      let plan = layoutPersistPlan(b, row.quarantined)
      checkpoint($row.binding & " quarantined=" & $row.quarantined & " -> " &
                 $plan.intent & " textLen=" & $plan.text.len)
      ck plan.intent == row.intent
      ck (plan.text.len > 0) == row.writesText
    ck asserted == ExpectedPlanCells
    ck reachable == ExpectedPlanReachable
    # EVERY (binding, quarantined) PAIR EXACTLY ONCE — the same completeness
    # proof the session matrix makes, at this table's own size.
    for pb in PlanBindingKind:
      for q in [false, true]:
        ck covered[pb][q] == 1

    # **THE UNREACHABILITY, ASSERTED RATHER THAN CLAIMED.** The two `pbNil`
    # rows are unreachable because `layoutPersistPlanOf` returns before it can
    # call this routine. That is one guard, and this is the measurement that
    # fails if it goes: a runtime with no binding answers `lpiQuarantine`,
    # which is NOT what `layoutPersistPlan(nil, false)` answers.
    ck layoutPersistPlan(nilBinding, false).intent == lpiRemove
    let bare = newRuntime(80, 24)
    ck not bare.layoutBindingEnabled()
    ck not bare.layoutPersistenceEnabled()
    ck bare.layoutDocumentQuarantined == false
    # If the guard in `layoutPersistPlanOf` were removed, this would answer
    # `lpiRemove` — the nil arm's answer — and go red. That is the whole proof
    # that the nil arm has no caller in the product.
    ck bare.layoutPersistPlanOf().intent == lpiQuarantine
    # …and the second half of the same guard: a binding, no document.
    let unnamed = newBoundRuntime(80, 24)
    ck unnamed.layoutBindingEnabled()
    ck not unnamed.layoutPersistenceEnabled()
    ck unnamed.layoutPersistPlanOf().intent == lpiQuarantine

  test "the failure-kind table: thirteen kinds, eleven produced and two unreachable":
    # EVERY VALUE `LayoutRestoreReport.kind` CAN TAKE, enumerated. The session
    # matrix collapses all of these to "unreadable"; this table is what says the
    # collapse is over a KNOWN set rather than over the four somebody happened
    # to write a case for.
    ck KindTable.len == ExpectedKindCells
    # THE SUBJECT IS THE WHOLE ENUM. A ninth `LayoutDecodeErrorKind` added
    # upstream must appear here or this fails — the table cannot silently
    # answer a smaller question than it appears to (§6).
    var decodeKinds = 0
    for k in LayoutDecodeErrorKind:
      inc decodeKinds
      var listed = 0
      for row in KindTable:
        if row.kind == $k:
          inc listed
      if listed != 1:
        checkpoint("decode kind " & $k & " appears " & $listed & " times")
      ck listed == 1
    checkpoint("LayoutDecodeErrorKind values: " & $decodeKinds)
    # 8 decode kinds + NotJson + EmptyDocument + UnreadableFile + Refused + "".
    ck decodeKinds == 8
    ck ExpectedKindCells == decodeKinds + 5

    let rt = newBoundRuntime(80, 24)
    var produced = 0
    var refusalsWithoutAKind = 0
    var asserted = 0
    for row in KindTable:
      inc asserted
      if not row.reachable:
        ck row.reason.len > 60
        ck row.text.len == 0
        continue
      if row.kind == UnreadableFileKind:
        # Its DOCUMENT-less producer: the nil-binding arm, which
        # `restoreLayoutForSession` cannot reach for the same reason `pbNil` is
        # unreachable. The host's `readFile` failure is the other producer and
        # the EACCES lane above owns it.
        inc produced
        let nilBinding: LayoutBinding = nil
        let report = nilBinding.adoptLayoutDocument("/nowhere/doc.json", "{}")
        ck report.status == lrsUnreadable
        ck report.kind == UnreadableFileKind
        continue
      inc produced
      let fresh = newBoundRuntime(80, 24)
      let report = fresh.app.layoutBinding.adoptLayoutDocument("/p/doc.json",
                                                              row.text)
      checkpoint("kind '" & row.kind & "' <- " & row.text[0 ..< min(60, row.text.len)] &
                 " -> [" & report.kind & "] " & $report.status)
      ck report.kind == row.kind
      ck (report.status == lrsRestored) == (row.kind.len == 0)
    ck asserted == ExpectedKindCells
    ck produced == ExpectedKindReachable

    # **`Refused` IS UNREACHABLE, ASSERTED OVER THE WHOLE CORPUS.** The literal
    # is composed when `restoreDocument` refuses without reporting a kind, and
    # `binding.restoreDocument` has exactly one non-applied return, which sets
    # `problem`. So: every failing document in this table refuses WITH a kind.
    var refusalsSeen = 0
    for row in KindTable:
      if not row.reachable or row.text.len == 0:
        continue
      var doc: JsonNode = nil
      try:
        doc = parseJson(row.text)
      except CatchableError:
        continue
      var problem = none(LayoutDecodeErrorKind)
      let acted = rt.app.layoutBinding.restoreDocument(doc, problem)
      if acted.status != lasApplied:
        inc refusalsSeen
        if not problem.isSome:
          inc refusalsWithoutAKind
        ck problem.isSome
    checkpoint("refusals carrying a typed kind: " & $refusalsSeen)
    # THE NON-VACUITY FLOOR (§4): a corpus that refused nothing would satisfy
    # "every refusal carries a kind" completely.
    ck refusalsSeen == 7
    ck refusalsWithoutAKind == 0

    # **`DockedPanesUnsupported` IS UNREACHABLE THROUGH THIS PATH**, and the
    # proof is two-sided: the same document decodes here and RAISES at the
    # bare-node entry point. A one-sided "it never appears" would be satisfied
    # by a kind this build cannot produce anywhere.
    let dockedDoc = parseJson(
      """{"version": 2, "layout": {"kind": "pane", "pane": "calltrace"},
          "docked": [{"pane": "editor", "edge": "bottom", "order": 0}]}""")
    let viaDocument = restoreLayoutDocument(dockedDoc)
    ck viaDocument.docked.len == 1
    var raisedKind = ""
    try:
      discard restoreLayout(dockedDoc)
    except LayoutDecodeError as e:
      raisedKind = $e.kind
    checkpoint("restoreLayout on a docked document raises '" & raisedKind & "'")
    ck raisedKind == $ldeDockedPanesUnsupported
    # …and the session path never answers with it.
    let viaSession = rt.app.layoutBinding.adoptLayoutDocument("/p/d.json",
                                                              $dockedDoc)
    ck viaSession.status == lrsRestored
    ck viaSession.kind != $ldeDockedPanesUnsupported

  test "cell count":
    # §4b's fingerprint, promoted into the check (§4c). A lane that returned
    # early, a filter that matched nothing, a row that drifted out of every
    # lane — none of them can reach this line with the right number.
    checkpoint("CELLS: " & $countedCells)
    echo "CELLS: ", countedCells
    if eaccesLaneRan:
      check countedCells == ExpectedCells
    else:
      echo EaccesPreconditionBanner
      check countedCells == ExpectedCells - EaccesLaneCells

  test "assertion count":
    checkpoint("CHECKS: " & $countedAssertions)
    echo "CHECKS: ", countedAssertions
    # TWO INDEPENDENT SKIPS, AND NEITHER IS A RELAXATION. Every one of the four
    # worlds has its own EXACT number; what a failed precondition moves is
    # which number applies, never an `==` into a `>=`. Each skip announces
    # itself on the way past, and the arithmetic is a subtraction of the lane
    # that did not run rather than a tolerance.
    var expected = ExpectedAssertions
    if not eaccesLaneRan:
      echo EaccesPreconditionBanner
      checkpoint(EaccesPreconditionBanner)
      expected -= EaccesLaneAssertions
    if not removeFailureLaneRan:
      echo RemoveFailurePreconditionBanner
      checkpoint(RemoveFailurePreconditionBanner)
      expected -= RemoveFailureLaneAssertions
    checkpoint("expecting " & $expected & " (eacces lane ran: " &
               $eaccesLaneRan & ", remove-failure lane ran: " &
               $removeFailureLaneRan & ")")
    check countedAssertions == expected
