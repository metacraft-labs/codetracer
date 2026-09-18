## document_version.nim — PLAT-29: the monotone document version, and the
## timeline an async result is reconciled against.
##
## Owns: Editor-ViewModel.md §11 (*"There is no async in this model. Edits
## apply synchronously and the resulting state carries a **version**"*).
##
## =========================================================================
## THE DECISION, AND THE CAUTIONARY CASE IT IS TAKEN AGAINST
## =========================================================================
##
## **xi-editor's own retrospective identifies making the core asynchronous as
## its central mistake.** A plugin architecture in which every syntax
## highlight and every edit round-trips through an async boundary makes the
## simplest operations hard to reason about and makes the correctness of the
## common case depend on message ordering.
##
## So the shape here is the other one: an edit applies **synchronously** and
## **publishes a version**; everything genuinely asynchronous computes against
## a version and is reconciled — or dropped — when its answer arrives. A
## highlight lagging one frame is fine. A keystroke waiting on a parse is not.
##
## =========================================================================
## WHAT A VERSION IS, EXACTLY
## =========================================================================
##
## A `DocumentVersion` is a `distinct int` and it is **not** a hash, a
## timestamp or a length. Each of those was considered and each loses the one
## property the whole boundary rests on:
##
##   * a HASH is not ordered, so "the document has moved on" is undecidable
##     and "how far" is unanswerable;
##   * a TIMESTAMP is a clock, and §11's third rule is that the model has no
##     clock — a model that reads one cannot be replayed and cannot be
##     compared across two hosts;
##   * a LENGTH is not injective: `replace [0,1) with "x"` leaves it
##     unchanged, so a stale result would look fresh.
##
## `distinct` rather than a bare `int` because the one operation that must
## never typecheck is arithmetic: `version + 1` computed by a caller is a
## version nothing published. The only way to obtain a new one is to apply a
## transaction. `+`, `-` and the integer literals are deliberately NOT
## borrowed; `==`, `<` and `<=` are, because "has the document moved" and
## "how far back is this" are the two questions the boundary asks.
##
## =========================================================================
## THE TIMELINE, AND WHY THE LOG IS OF CHANGE SETS
## =========================================================================
##
## `VersionedDocument` holds the text, the current version, and the change
## sets that took the document from the oldest version it still remembers to
## now. An async result computed against version `v` is reconciled by folding
## `log[v .. cur]` with `compose` into ONE change set, and moving the result
## through it with PLAT-25's primitives and nothing else.
##
## That is the whole reason the log is change sets rather than document
## snapshots. A snapshot log answers "what did the document look like", which
## nothing here asks; a change-set log answers "where did this position go",
## which is the only question the boundary has. It is also what makes the
## reconciliation reuse `mapPos` and `rebase` instead of growing a mapping of
## its own (Verification-Harness-Traps §35's shape one level up: a sixth
## hand-rolled mapping is a sixth place for the same bug).
##
## =========================================================================
## FORGETTING IS EXPLICIT, AND A FORGOTTEN VERSION IS NOT AN ERROR
## =========================================================================
##
## A log that grows forever is a leak, so `forget` exists. It moves the oldest
## remembered version forward and drops the change sets below it, which makes
## a result computed against a forgotten version **unreconcilable** — the
## intervening arithmetic is gone. That is a normal, countable outcome
## (`drVersionForgotten` in `reconcile.nim`) and not a defect: it is what an
## editor does to a highlight request issued before the buffer was reloaded.
##
## **`delta` RAISES rather than clamps, on both unreachable paths**, which is
## Verification-Harness-Traps §36a applied before it can bite: *"a clamp is a
## silent repair, and it hides the defect it clamps for exactly as long as the
## value stays out of range."* A version from the FUTURE is a programming
## error — versions are minted here and nowhere else — and clamping it to
## `cur` would make every stale result look fresh, which is precisely the
## defect the milestone exists to prevent. A version already FORGOTTEN has an
## answer the caller must decide (`knows` says so first), and clamping it to
## `oldest` would map a result through the wrong change sets and then apply
## it, silently.

import ./change_set
import ./transaction

type
  DocumentVersion* = distinct int
    ## Monotone, minted only by `apply`. See the header for why it is neither
    ## a hash, a timestamp nor a length, and why arithmetic on it does not
    ## typecheck.

  VersionError* = object of ValueError
    ## Raised by `delta` for a version this timeline cannot answer about — one
    ## from the future, or one it has forgotten. Never clamped (§36a).

  VersionedDocument* = object
    ## §11's *"edits apply synchronously and the resulting state carries a
    ## version"*, as a value.
    ##
    ## Every field is private. A `VersionedDocument` assembled field by field
    ## is a timeline whose invariant — `version - oldest == log.len` — is
    ## advice rather than a fact, and the whole boundary is built on that
    ## invariant holding.
    docText: string
    cur: DocumentVersion
    oldest: DocumentVersion
    log: seq[ChangeSet]
      ## `log[i]` takes version `oldest + i` to version `oldest + i + 1`.

const
  InitialVersion* = DocumentVersion(0)
    ## What a freshly opened document carries. Nothing depends on it being
    ## zero — `delta` is expressed in offsets from `oldest` — but a document
    ## that starts somewhere arbitrary makes every printed trace harder to
    ## read for no gain.

# ---------------------------------------------------------------------------
# The version's own vocabulary. `==`, `<` and `<=` are BORROWED; `+` and `-`
# deliberately are not.
# ---------------------------------------------------------------------------

func `==`*(a, b: DocumentVersion): bool {.borrow.}
func `<`*(a, b: DocumentVersion): bool {.borrow.}
func `<=`*(a, b: DocumentVersion): bool {.borrow.}

func `$`*(v: DocumentVersion): string =
  ## `v7`, not `7`. A bare integer in a diagnostic reads as a count, a length
  ## or an index; every one of those appears in the same messages.
  "v" & $int(v)

func ordinal*(v: DocumentVersion): int =
  ## The underlying counter, for a harness that needs to compare two versions'
  ## DISTANCE — the number of transactions between them — which is the one
  ## question the borrowed operators cannot answer.
  int(v)

func distanceBetween*(earlier, later: DocumentVersion): int =
  ## How many transactions separate two versions. Negative when `later` is
  ## actually earlier, which is a fact a caller may want; it is not clamped,
  ## for §36a's reason.
  int(later) - int(earlier)

# ---------------------------------------------------------------------------
# The timeline
# ---------------------------------------------------------------------------

proc initVersionedDocument*(text: string;
                            at: DocumentVersion = InitialVersion):
    VersionedDocument =
  ## A document at rest. `at` exists so a reload can continue a timeline
  ## rather than restart one — two documents both claiming `v0` in the same
  ## session is exactly the collision the version exists to make impossible.
  VersionedDocument(docText: text, cur: at, oldest: at, log: @[])

func text*(vd: VersionedDocument): string = vd.docText
func version*(vd: VersionedDocument): DocumentVersion = vd.cur
func oldestKnownVersion*(vd: VersionedDocument): DocumentVersion = vd.oldest
func historyLen*(vd: VersionedDocument): int = vd.log.len

func knows*(vd: VersionedDocument; v: DocumentVersion): bool =
  ## True when `delta(vd, v)` can answer. **Ask this before calling `delta`**:
  ## it is the difference between a countable outcome and an exception.
  vd.oldest <= v and v <= vd.cur

proc applyChanges*(vd: var VersionedDocument; cs: ChangeSet): DocumentVersion =
  ## **THE ONLY WAY A VERSION IS MINTED.** Synchronous, unconditionally: there
  ## is no branch in this procedure that waits, polls, schedules or yields,
  ## and there is nothing in this module's import closure that could offer one
  ## (`ci/test/editor-import-closure.sh` is what says so, rather than this
  ## sentence).
  if cs.length != vd.docText.len:
    raise newException(ChangeSetError,
      "applyChanges: a change set over " & $cs.length &
      " bytes does not meet a document of " & $vd.docText.len)
  vd.docText = cs.apply(vd.docText)
  vd.log.add cs
  vd.cur = DocumentVersion(int(vd.cur) + 1)
  vd.cur

proc apply*(vd: var VersionedDocument; t: Transaction): DocumentVersion =
  ## §6: *"a transaction is the only way state changes"*, meeting §11's *"the
  ## resulting state carries a version"*. One line, and deliberately so — a
  ## transaction's other members (selection, effects, annotations) do not
  ## change the document, so they do not change the version either.
  vd.applyChanges(t.changes)

proc delta*(vd: VersionedDocument; since: DocumentVersion): ChangeSet =
  ## The ONE change set taking the document as it was at `since` to the
  ## document as it is now.
  ##
  ## `identityChangeSet` when nothing has happened, which is the arm that
  ## makes *"applied as computed"* a decidable state rather than a guess.
  ##
  ## RAISES, NEVER CLAMPS, on both out-of-range paths — see the header.
  if since > vd.cur:
    raise newException(VersionError,
      "delta: " & $since & " is ahead of this document's " & $vd.cur &
      ". A version is minted by `apply` and by nothing else, so a version " &
      "from the future is a caller that invented one. It is NOT clamped: a " &
      "clamp here would report every stale result as fresh, which is the " &
      "single defect this boundary exists to prevent " &
      "(Verification-Harness-Traps §36a).")
  if since < vd.oldest:
    raise newException(VersionError,
      "delta: " & $since & " was forgotten; this document remembers back to " &
      $vd.oldest & ". Ask `knows` first — a forgotten version is a countable " &
      "reconciliation outcome (`drVersionForgotten`), not an exception to " &
      "swallow, and clamping to the oldest known version would map a result " &
      "through change sets it was never computed against.")
  let first = int(since) - int(vd.oldest)
  var acc = identityChangeSet(
    if first < vd.log.len: vd.log[first].length else: vd.docText.len)
  for i in first ..< vd.log.len:
    acc = compose(acc, vd.log[i])
  acc

proc lengthAt*(vd: VersionedDocument; v: DocumentVersion): int =
  ## How many bytes the document had at `v`. Derived from the log rather than
  ## remembered beside it, so it cannot disagree with the change sets the
  ## mapping actually uses.
  vd.delta(v).length

proc forget*(vd: var VersionedDocument; upTo: DocumentVersion) =
  ## Drop the change sets below `upTo`, making every version before it
  ## unreconcilable. Idempotent, and a no-op for a version already forgotten.
  ##
  ## Refuses a version from the future for `delta`'s reason: forgetting
  ## forward would silently discard history that has not happened yet.
  if upTo > vd.cur:
    raise newException(VersionError,
      "forget: " & $upTo & " is ahead of this document's " & $vd.cur)
  if upTo <= vd.oldest: return
  let drop = int(upTo) - int(vd.oldest)
  # A slice assignment rather than `delete(a .. b)`: the ranged overload moved
  # between Nim releases and this repository pins 2.2.8 while the wasm lane
  # compiles the same source through a second front end. One spelling that has
  # meant the same thing in every 1.x and 2.x is worth the copy.
  vd.log = vd.log[drop .. ^1]
  vd.oldest = upTo
