## collab_text.nim — PLAT-33: text edits merged by REBASE AGAINST A CENTRAL
## AUTHORITY, and the fourth and fifth of the five places that call the ONE
## rebase primitive.
##
## Owns: `Architecture/Editor-ViewModel.md` §12.2 (the algorithm) and §12.2a
## (how it meets the ViewOp stream). Nothing in this file knows what a
## `ViewOpEnvelope` is — the bridge that puts these updates on the wire is
## `viewmodel/collab/text_ops.nim`, and it depends on this module rather than
## the other way round, so the algorithm can be driven from a test with no
## session, no transport and no capability in sight.
##
## =========================================================================
## WHY A REBASE AND NOT A CRDT — the decision, restated where it is executed
## =========================================================================
##
## Zed uses a real sequence CRDT because it is collaborative from the ground
## up; Helix has none; CodeMirror's `@codemirror/collab` (vendored read-only
## at `refs/codemirror-collab/`, MIT) takes the middle road and it is the one
## §12 takes: a central authority holds the canonical sequence of updates and
## assigns versions, a peer submits its unconfirmed local changes tagged with
## the version it had seen, and whoever is behind rebases.
##
## The whole of that fits in this file because PLAT-25 already built the hard
## part. `change_set.rebase(a, b)` returns BOTH arms of the double mapping, so
## the two sites CodeMirror hand-writes here — `receiveUpdates`
## (`collab.ts:97,111`) and `rebaseUpdates` (`collab.ts:171,181`) — are one
## call each instead of two, and the `before` flag is not spelled anywhere in
## this module. It cannot be: `mapOver` is private to `change_set.nim` and
## `test_editor_change_algebra.nim` scans this directory to keep it that way.
##
## =========================================================================
## THE THREE PLACES THIS DIVERGES FROM THE REFERENCE, EACH FOR A MEASUREMENT
## =========================================================================
##
## 1. **THE AUTHORITY HAS A STATED TIE-BREAK AND THE REFERENCE HAS NONE.**
##    `@codemirror/collab` leaves the order of two submissions at the same
##    version to whatever order the server dequeued them in, which makes the
##    authority's log a function of arrival timing. Two inserts at one offset
##    then produce `AB` or `BA` depending on which TCP segment landed first,
##    and that is not a property anything can assert. `acceptConcurrent`
##    orders a batch of same-version submissions by `(producer, updateId)`
##    ascending, so the log's fold is a function of the SET of concurrent
##    submissions. `LAW-X3` is that sentence, and its published killer — "tie
##    break on arrival order" — is exactly the reference's behaviour, which is
##    why the divergence is recorded here rather than left implicit.
##
##    The cost is real and is not hidden: a peer whose submission sorts late
##    has its insert placed after one it may have typed first. The benefit is
##    that the authority is deterministic and replayable, which a debugger's
##    collaboration layer needs more than it needs wall-clock fairness.
##
## 2. **THE AUTHORITY NEVER READS THE INSERTED TEXT OF ITS OWN LOG, AND THAT
##    IS MEASURED RATHER THAN TYPED.** §12.2 says the authority needs "each
##    update's change *description* and the id of the peer that produced it —
##    never the inserted text". The reference expresses that with a second
##    type, `ChangeDesc`. We do not have one and deliberately did not add one:
##    a parallel change-set type with its own `compose` and its own `map` is a
##    re-derivation of `change_set.nim`, which is
##    `Verification-Harness-Traps.md` §30a's most expensive shape.
##
##    What replaces the type is a property, and it is strictly stronger than a
##    type would have been because a type can be bypassed by a cast and this
##    cannot: **replacing every inserted byte in the authority's log with
##    different bytes of the same length leaves every rebased submission
##    byte-identical**. It holds because `mapOver` reads `setB`'s section
##    LENGTHS and never `setB`'s text — verified by reading the routine, and
##    asserted by `LAW-X3`'s text-blindness case.
##
## 3. **`receiveUpdates` RETURNS A VALUE, IT DOES NOT BUILD A TRANSACTION.**
##    The reference calls `state.update({changes, annotations: [...],
##    filter: false})` and hands back a `Transaction`. Ours hands back the
##    composed change set and lets `applyRemoteChange` decide what to do with
##    it, because §12.2's three "not incidental" properties — no history
##    event, no filters, no selection assignment — are properties of the
##    APPLICATION and each one has to be separately observable for `LAW-X4`'s
##    three arms. A single `Transaction` carrying three annotations is one
##    thing a test can look at; three code paths is three.

import std/[algorithm, options, strutils]

import ./change_set
import ./editor_state
import ./selection
import ./transaction

export editor_state

type
  PeerId* = string
    ## Who produced an update. The authority recognises a peer's own
    ## resubmissions by this and by log order, which is §12.2's dedup.

  UpdateId* = string
    ## A stable per-update handle. On the wire this is the envelope's `opId`,
    ## which is also what the reducer dedups on; in a pure test it is whatever
    ## the generator minted. This module never interprets it except to ORDER
    ## concurrent submissions (divergence 1 above).

  TextUpdate* = object
    ## One accepted or submitted change, with its producer.
    changes*: ChangeSet
    producer*: PeerId
    updateId*: UpdateId

  TextAuthority* = object
    ## §12.2's append-only, totally ordered log. **A version IS the length of
    ## this log** and there is no second counter — `SharedSessionViewState.
    ## revision` is a LOCAL count of applied ops and does not travel, and
    ## `lamport` orders events rather than recording what a peer had seen.
    ##
    ## `entries` is private for the same reason `ChangeSet.sections` is: a log
    ## that can be spliced field by field is a log whose append-only-ness is
    ## advice. It grows through `accept` and through nothing else.
    entries: seq[TextUpdate]
    baseLen: int
      ## The byte length of the document version 0 was expressed over.

  Submission* = object
    ## What a peer sends: its unconfirmed updates, and the authority version
    ## it produced them against.
    updates*: seq[TextUpdate]
    atVersion*: int

  AcceptStatus* = enum
    asAccepted
    asRefused

  AcceptOutcome* = object
    ## The outcome of one submission.
    ##
    ## **A PLAIN OBJECT AND NOT A `case` OBJECT.** It was a variant first —
    ## `asAccepted` carrying a `seq[TextUpdate]` and an `int`, `asRefused` a
    ## `string`.
    ##
    ## An earlier version of this comment credited the change to a
    ## memory-management hunt (`Verification-Harness-Traps.md` §38). That
    ## crash does not exist and §38 has been withdrawn, so the only reason
    ## left is the one that stands on its own and is the better one anyway:
    ## the four fields are always readable, so a caller that wants the version
    ## after a REFUSAL can have it, which the variant made unrepresentable.
    ##
    ## The property the variant was for is kept without it: a refusal is
    ## `status == asRefused` **and** a non-empty `reason`, so "refused" and
    ## "accepted nothing" stay distinguishable — an accepted empty submission
    ## has an empty reason.
    status*: AcceptStatus
    accepted*: seq[TextUpdate]
      ## The submission, rebased onto the log's head. These are what every
      ## peer is sent, in this order. Empty on a refusal.
    version*: int
      ## The authority version AFTER the append; unchanged on a refusal.
    reason*: string
      ## Non-empty exactly when `status == asRefused`.

  PeerSession* = object
    ## A peer's half: how far it has synced, and what it has not had confirmed.
    clientId*: PeerId
    version*: int
    unconfirmed*: seq[TextUpdate]

  Received* = object
    ## What `receiveUpdates` produced. `changes` is expressed against the
    ## peer's CURRENT document — that is, the remote work already rebased past
    ## everything the peer has locally and not yet had confirmed, which is the
    ## step `LAW-X1`'s killer removes.
    changes*: ChangeSet
    hasChanges*: bool

  CollabTextError* = object of ValueError
    ## Raised when a submission does not meet the log it is submitted against.
    ## §36a: a guard that repairs a version silently is a guard whose every
    ## wrong answer is invisible, so this raises and the harness counts the
    ## raises rather than clamping the version into range.

# ===========================================================================
# THE AUTHORITY
# ===========================================================================

proc initTextAuthority*(baseLen: int): TextAuthority =
  ## An authority over a document of `baseLen` bytes at version 0.
  if baseLen < 0:
    raise newException(CollabTextError,
      "initTextAuthority: a document cannot be " & $baseLen & " bytes long")
  TextAuthority(entries: @[], baseLen: baseLen)

func version*(a: TextAuthority): int =
  ## **The version IS the log length.** §12.2, stated as a one-line function
  ## so no caller can keep a second copy that drifts.
  a.entries.len

func logFrom*(a: TextAuthority; fromVersion: int): seq[TextUpdate] =
  ## `log[fromVersion..]` — what a peer at `fromVersion` has not seen.
  if fromVersion < 0 or fromVersion > a.entries.len:
    raise newException(CollabTextError,
      "logFrom: version " & $fromVersion & " is outside 0 .. " &
      $a.entries.len)
  a.entries[fromVersion .. ^1]

proc document*(a: TextAuthority; base: string): string =
  ## §12.2's *"the document is the fold of the log's change sets over the
  ## empty document"* — over `base` rather than over the empty document,
  ## because a collaborative session starts from a file that already exists.
  if base.len != a.baseLen:
    raise newException(CollabTextError,
      "document: the authority is over " & $a.baseLen & " bytes and the base " &
      "is " & $base.len)
  result = base
  for entry in a.entries:
    result = entry.changes.apply(result)

proc documentLength*(a: TextAuthority): int =
  ## The fold's length, without folding the text. Cheap, and it is what
  ## `accept` checks a submission against.
  result = a.baseLen
  for entry in a.entries:
    result = entry.changes.newLength

# ===========================================================================
# `rebaseUpdates` — THE FOURTH CALL SITE
# ===========================================================================

# ===========================================================================
# BOTH ARMS ARE NAMED BEFORE EITHER IS USED, AND IT IS ONLY LEGIBILITY
# ===========================================================================
#
# The two loops below bind `moved` and `advanced` out of the `Rebased` instead
# of reading `r.bOverA` and `r.aOverB` inline. That is a READING aid and
# nothing more: the asymmetry between the two arms is the whole content of the
# primitive, and at a call site that also reassigns its accumulator the
# inline spelling makes it easy to mix them up. `selection_ops.nim`'s
# accumulator loop names them the same way, for the same reason.
#
# **IT IS NOT A CORRECTNESS REMEDY, AND AN EARLIER VERSION OF THIS COMMENT
# SAID IT WAS.** That comment claimed the inline spelling —
#
#     let r = rebase(running, update.changes)
#     result.add TextUpdate(changes: r.bOverA, …)
#     running = r.aOverB
#
# — was a heap use-after-free under `--mm:orc`, and `Verification-Harness-
# Traps.md` §38 was written up from it. The defect does not exist. Both sites
# were reverted to exactly that spelling and run under ORC release, ORC debug,
# and ORC + `-d:useMalloc` + AddressSanitizer: all three clean, zero ASAN
# reports, 1105 and 138 checks, identical to the bound-locals version. §38 has
# been withdrawn; see its entry for the record.
#
# It is structurally impossible as it was described. `rebase` is
# `Rebased(aOverB: mapOver(a, b, …), bOverA: mapOver(b, a, …))` and `mapOver`
# returns `builder.finish()` — both arms are freshly built and neither
# aliases the accumulator passed in, so there is no buffer for a move out of
# the result to free out from under a live reference.
#
# **ONE** long-standing accumulator site uses the inline spelling and always
# has: `change_set.changeSetOrdered`, which is `total = compose(total,
# rebase(total, part).bOverA)` — the flagged shape without the prescribed
# remedy. It has never misbehaved, which is the same evidence from a different
# direction.
#
# An earlier version of this comment counted TWO, adding
# `selection_ops.changeByRange`. That is wrong, and wrong in the direction
# that flatters the argument. `selection_ops.nim:288` does the opposite: it
# binds `let rb = rebase(changes, newChanges)` and then `let newMapped =
# rb.bOverA` / `let mapBy = rb.aOverB` — which is why the paragraph above
# cites it as the precedent for naming the arms here. A count of the tree
# settles it: of the TEN `rebase(` call sites in `viewmodel/editor/`,
# `change_set.nim:798` is the only inline one; the other NINE — anchor 194,
# transaction 309, reconcile 462, history 414, selection_ops 288 and the four
# in this file — all bind the result first.
#
# **THE TOTAL WAS WRONG TWICE MORE BEFORE IT WAS RIGHT, AND THE SENTENCE
# CONTAINED ITS OWN REFUTATION BOTH TIMES.** It read "nine ... the other
# eight" while the enumeration that follows it — anchor, transaction,
# reconcile, history, selection_ops, and the FOUR in this file — lists NINE
# binders, and 1 + 9 is 10. Two mechanical counts in the tree said 10 the
# whole time: `Editor-ViewModel.md`'s measurement table ("textual `rebase(`
# call sites in code | 10") and `test_editor_change_algebra.nim`'s
# `RebaseSites`, whose rows sum to 10 and which is GREEN — so the prose
# disagreed with a passing test in the same repository. The count is now
# derived the way the test derives it: add the rows up, or run the scan.
# Do not re-state it from the paragraph above.

proc rebaseUpdates*(updates: openArray[TextUpdate];
                    over: openArray[TextUpdate]): seq[TextUpdate] =
  ## `codemirror-collab/src/collab.ts:165-188`, ported, with its two
  ## hand-written `map` calls replaced by the one `rebase`. Compare:
  ##
  ##     changes = changes.mapDesc(other.changes, true)   // the skip arm
  ##     updateChanges = update.changes.map(changes)      // before defaulted false
  ##     changes = changes.mapDesc(update.changes, true)
  ##
  ## The last two are ONE `rebase(changes, update.changes)` here and both arms
  ## come out of it, which is the only reason the two cannot disagree about
  ## which of them carries the flag.
  ##
  ## Two jobs in one walk, which is the reference's design and is kept:
  ##
  ##  * **dedup** — an update the authority already holds is recognised by its
  ##    producer's id in log order and dropped (`skip`). That is §12.2's
  ##    *"deduplication of a resubmission falls out of the same walk"*, and it
  ##    is what makes a reconnecting peer's retry safe.
  ##  * **rebase** — whatever is left is moved over the rest of `over`.
  if over.len == 0 or updates.len == 0:
    return @updates

  var changes = none(ChangeSet)
  var skip = 0
  for entry in over:
    let mineIsNext = skip < updates.len and
                     updates[skip].producer == entry.producer
    if mineIsNext:
      # One of ours, already accepted. Skip it, and advance the accumulated
      # remote change past it so the next one rebases against the right thing.
      if changes.isSome:
        let r = rebase(changes.get, updates[skip].changes)
        let advanced = r.aOverB
        changes = some(advanced)
      inc skip
    else:
      if changes.isSome:
        let composed = compose(changes.get, entry.changes)
        changes = some(composed)
      else:
        changes = some(entry.changes)

  var rest = if skip > 0: @(updates[skip .. ^1]) else: @updates
  if changes.isNone or rest.len == 0:
    return rest

  result = newSeqOfCap[TextUpdate](rest.len)
  var running = changes.get
  for update in rest:
    let r = rebase(running, update.changes)
    let moved = r.bOverA       # the update, re-expressed after `running`
    let advanced = r.aOverB    # `running`, carried past this update
    result.add TextUpdate(changes: moved,
                          producer: update.producer,
                          updateId: update.updateId)
    running = advanced

proc accept*(a: var TextAuthority; submission: Submission): AcceptOutcome =
  ## §12.2's *"sending"* half, on the authority side. If the peer's version
  ## equals ours the updates are appended verbatim; if it is behind they are
  ## rebased over `log[peerVersion..]` first.
  ##
  ## A version ABOVE ours is refused rather than clamped: a peer claiming to
  ## have seen updates we have not issued is a peer we cannot rebase for, and
  ## §36a's first rule says a value our own bookkeeping cannot produce is a
  ## refusal rather than a plausible landing.
  if submission.atVersion < 0:
    return AcceptOutcome(status: asRefused, version: a.entries.len,
      reason: "negative version " & $submission.atVersion)
  if submission.atVersion > a.entries.len:
    return AcceptOutcome(status: asRefused, version: a.entries.len,
      reason: "version " & $submission.atVersion &
        " is ahead of the authority at " & $a.entries.len)
  if submission.updates.len == 0:
    return AcceptOutcome(status: asAccepted, accepted: @[],
                         version: a.entries.len)

  let over = a.entries[submission.atVersion .. ^1]
  let rebased = rebaseUpdates(submission.updates, over)

  # Every accepted update has to meet the document the log folds to, or the
  # log stops being foldable and `document` raises later, somewhere that
  # cannot say which submission broke it.
  var expected = a.documentLength
  for update in rebased:
    if update.changes.length != expected:
      return AcceptOutcome(status: asRefused, version: a.entries.len,
        reason: "update " & update.updateId & " is over " &
          $update.changes.length & " bytes and the log folds to " & $expected)
    expected = update.changes.newLength

  for update in rebased:
    a.entries.add update
  AcceptOutcome(status: asAccepted, accepted: rebased, version: a.entries.len)

func submissionOrderKey*(submission: Submission): (PeerId, UpdateId) =
  ## **THE STATED TIE-BREAK** (divergence 1 in this file's header). Two
  ## submissions at the same version are ordered by their producer and then by
  ## their first update's id, so the log is a function of the SET of
  ## concurrent submissions rather than of the order a socket happened to
  ## deliver them in.
  ##
  ## It is a named function and not an inline comparator because `LAW-X3`'s
  ## killing mutation is "tie-break on arrival order instead", and a mutation
  ## needs one place to land.
  let producer = if submission.updates.len > 0: submission.updates[0].producer
                 else: ""
  let id = if submission.updates.len > 0: submission.updates[0].updateId else: ""
  (producer, id)

proc acceptConcurrent*(a: var TextAuthority;
                       pending: openArray[Submission]): seq[AcceptOutcome] =
  ## Accept a batch of submissions that arrived together, in the stated
  ## tie-break order. The returned outcomes are in the order they were
  ## ACCEPTED, not in the order they arrived, because the accepted order is
  ## the one every peer will see.
  var ordered = @pending
  ordered.sort(proc (x, y: Submission): int =
    let kx = submissionOrderKey(x)
    let ky = submissionOrderKey(y)
    if kx[0] != ky[0]: cmp(kx[0], ky[0]) else: cmp(kx[1], ky[1]))
  result = newSeqOfCap[AcceptOutcome](ordered.len)
  for submission in ordered:
    result.add a.accept(submission)

# ===========================================================================
# THE PEER — `receiveUpdates`, THE FIFTH CALL SITE
# ===========================================================================

proc initPeerSession*(clientId: PeerId; version = 0): PeerSession =
  PeerSession(clientId: clientId, version: version, unconfirmed: @[])

proc recordLocal*(p: var PeerSession; changes: ChangeSet; updateId: UpdateId) =
  ## A local edit joins the unconfirmed list. An identity change is not an
  ## edit and does not: the reference's `!tr.changes.empty` guard
  ## (`collab.ts:72`), kept, because an empty update would consume a slot in
  ## the authority's own-update recognition walk and confirm somebody else's.
  if changes.isIdentity:
    return
  p.unconfirmed.add TextUpdate(changes: changes, producer: p.clientId,
                               updateId: updateId)

func sendable*(p: PeerSession): Submission =
  ## What this peer has to send, tagged with the version it was produced
  ## against. §12.2a: *"a text update carries the authority version it was
  ## produced against"*, and that is this field.
  Submission(updates: p.unconfirmed, atVersion: p.version)

proc receiveUpdates*(p: var PeerSession;
                     updates: openArray[TextUpdate]): Received =
  ## `codemirror-collab/src/collab.ts:86-134`, ported. The peer walks the
  ## arriving updates in order: its own coming back are recognised and
  ## consumed, confirming them; everyone else's are composed into one change
  ## set. The still-unconfirmed local updates are then rebased over that
  ## composition, with the running remote change advanced past each local
  ## update in turn so the next one rebases against the right thing.
  ##
  ## **THE LAST LINE OF THE REBASE LOOP IS THE ONE `LAW-X1` IS ABOUT.** The
  ## composed remote change starts out expressed against the peer's CONFIRMED
  ## document; the peer's actual document has its unconfirmed work on top of
  ## that. `running` is that change carried forward past each unconfirmed
  ## update, so what comes back in `Received.changes` applies to the document
  ## the peer is really holding. Drop it — return the unrebased composition —
  ## and every peer still converges *when nothing is unconfirmed*, which is
  ## most of an in-order schedule. That is why `LAW-X1` is quantified over the
  ## five schedule classes and why the delayed-past-a-local-edit class has its
  ## realised count asserted.
  p.version += updates.len

  var changes = none(ChangeSet)
  var own = 0
  for update in updates:
    let oursIsNext = own < p.unconfirmed.len and
                     p.unconfirmed[own].producer == update.producer
    if oursIsNext:
      if changes.isSome:
        let r = rebase(changes.get, p.unconfirmed[own].changes)
        let advanced = r.aOverB
        changes = some(advanced)
      inc own
    else:
      if changes.isSome:
        let composed = compose(changes.get, update.changes)
        changes = some(composed)
      else:
        changes = some(update.changes)

  if own > 0:
    p.unconfirmed =
      if own >= p.unconfirmed.len: @[] else: p.unconfirmed[own .. ^1]

  if p.unconfirmed.len > 0 and changes.isSome:
    var running = changes.get
    var rebased = newSeqOfCap[TextUpdate](p.unconfirmed.len)
    for update in p.unconfirmed:
      let r = rebase(running, update.changes)
      let moved = r.bOverA
      let advanced = r.aOverB
      rebased.add TextUpdate(changes: moved,
                             producer: update.producer,
                             updateId: update.updateId)
      running = advanced
    p.unconfirmed = rebased
    let carried = running
    changes = some(carried)

  if changes.isSome:
    Received(changes: changes.get, hasChanges: true)
  else:
    Received(changes: identityChangeSet(0), hasChanges: false)

# ===========================================================================
# THE RECEIVE PATH — §12.2's THREE PROPERTIES THAT ARE "NOT INCIDENTAL"
# ===========================================================================
#
# `LAW-X4` is three arms and not one, and this routine is why. The reference
# expresses all three as options on one `state.update({…})` call:
#
#     annotations: [Transaction.addToHistory.of(false),
#                   Transaction.remote.of(true), …],
#     filter: false
#
# A suite that asserts convergence alone is green on an implementation that
# converges while putting remote edits into the local undo stack — which is
# precisely the defect PLAT-32 exists to prevent and which this milestone is
# capable of re-introducing. So each property is a separate, separately
# observable step below, with the reason it is a property rather than a
# preference stated beside it.

proc applyRemoteChange*(st: EditorState; cs: ChangeSet;
                        peer: PeerId): EditorState =
  ## Apply an authority-ordered change to a local editor state.
  ##
  ## `cs` must already be expressed against `st.doc` — that is what
  ## `receiveUpdates` returns, and rebasing it past the peer's unconfirmed
  ## work is that routine's job, not this one's. Handing an unrebased change
  ## here is `LAW-X1`'s killing mutation.
  if cs.length != st.doc.len:
    raise newException(CollabTextError,
      "applyRemoteChange: the change is over " & $cs.length &
      " bytes and the document is " & $st.doc.len & ". A remote change that " &
      "does not meet the document was not rebased past the local work.")
  result = st
  if cs.isIdentity:
    return

  let selBefore = st.selection

  # -----------------------------------------------------------------------
  # PROPERTY 1 — IT DOES NOT ENTER THE UNDO HISTORY.
  # -----------------------------------------------------------------------
  # And it is the MECHANISM rather than a policy: `anRemote` routes `record`
  # into the history's MAPPING path, where the change's description is pushed
  # into BOTH branches as an accumulated mapping instead of becoming an
  # undoable event (§13.2, PLAT-32's `addMappingToBranch`). Skipping the call
  # entirely would ALSO keep the edit out of the undo stack — and would leave
  # every event below it expressed against a document that has moved, which
  # is what `history.pop`'s raise is there to catch.
  result.recordTransaction(
    transaction(cs, none(EditorSelection), @[],
                @[Annotation(kind: anRemote, peer: peer),
                  Annotation(kind: anAddToHistory, addToHistory: false)]),
    st.doc, selBefore)

  # -----------------------------------------------------------------------
  # PROPERTY 2 — IT BYPASSES THE LOCAL TRANSACTION FILTERS.
  # -----------------------------------------------------------------------
  # There is no `refusedBy` call in this routine and that is the whole of it.
  # A read-only guard or a protected-range filter that suppressed part of a
  # remote change would leave this peer's document a prefix of everybody
  # else's, silently — the filters are a local editing policy and the
  # authority's log is not negotiable.

  # -----------------------------------------------------------------------
  # PROPERTY 3 — THE LOCAL SELECTION IS NOT SET BY IT.
  # -----------------------------------------------------------------------
  # `mapSelection` and nothing else, which is §7's ordinary rule. A remote
  # insert at the caret then does the right thing for free, and there is no
  # second place where selection mapping is decided. Note the asymmetry with
  # `commitChange`, which takes a `newSelection` because a LOCAL operation
  # knows where it put the caret; a remote one has no opinion about ours.
  result.selection = mapSelection(selBefore, cs)
  result.mapPositionTables(st, cs)
  result.doc = cs.apply(st.doc)

proc receiveInto*(p: var PeerSession; st: EditorState;
                  updates: openArray[TextUpdate]): EditorState =
  ## The whole receive step: rebase, then apply. One routine so a caller
  ## cannot do the second without the first.
  let received = p.receiveUpdates(updates)
  if not received.hasChanges:
    return st
  # The peer id on the annotation is whoever produced the FIRST foreign
  # update in this batch. It is an attribution for the history's benefit and
  # nothing branches on it; when a batch mixes producers the composition has
  # no single author and naming one of them is the honest approximation.
  var peer = ""
  for update in updates:
    if update.producer != p.clientId:
      peer = update.producer
      break
  st.applyRemoteChange(received.changes, peer)

# ===========================================================================
# THE OFFLINE BOUND — §12.3, measured rather than asserted
# ===========================================================================

type
  DivergenceReport* = object
    ## What a reconnecting peer's rebase cost and how far its intent survived.
    ##
    ## §12.3 accepts long-offline divergence as a cost and asks for the bound
    ## to be **a number taken on real edit streams**. These are the three
    ## quantities that number is a function of, reported together so a reader
    ## can see which one moved — `Verification-Harness-Traps.md` §36b: a bound
    ## whose report is constant in the quantity being varied is a bound on the
    ## wrong quantity.
    authorityUpdates*: int   ## N — accepted while the peer was away
    localUpdates*: int       ## M — the peer produced offline
    mappings*: int           ## the rebase mappings performed, on the order of N x M
    insertsPlaced*: int      ## how many offline inserts the peer made
    contextPreserved*: int
      ## How many still sit where the user put them.
      ##
      ## **THIS METRIC AND NOT "SURVIVING BYTES", AND THE FIRST ONE WAS
      ## MEASURED AND DISCARDED.** The obvious quantity is how much of the
      ## peer's inserted text is still present in the authority's document. It
      ## was implemented, run at 4, 32 and 256 intervening remote edits, and
      ## reported 28 / 21 / 28 of 28 bytes — non-monotone, and never once
      ## crossing the bound.
      ##
      ## It could not have. A rebase never deletes an insertion: two
      ## concurrent inserts both survive, and an insert inside a range
      ## somebody else deleted is placed at the deletion point rather than
      ## dropped. So "surviving bytes" over an offline stream is a constant
      ## wearing a measurement's clothes — `Verification-Harness-Traps.md`
      ## §36b: *a bound whose report is constant in the quantity being varied
      ## is a bound on the wrong quantity*.
      ##
      ## **AND THE OBVIOUS COROLLARY IS FALSE, WHICH AN ARM FOUND.** "A
      ## rebase never drops an insertion" does not give "an insert-only
      ## remote stream cannot move this metric". It does move it — 0.98 /
      ## 0.77 / 0.58 against 0.98 / 0.79 / 0.50 for a stream that also
      ## rewrites — because a remote insert at the same offset is ORDERED
      ## before the peer's, which breaks the context just as a rewrite does.
      ##
      ## What §12.3 actually names is a result that is *"well-defined and not
      ## what anyone wanted"*, and what goes wrong is WHERE the text lands,
      ## not whether it is there. So the peer records the bytes immediately
      ## preceding each of its insertion points — the text it was aiming
      ## after — and the measurement asks whether the insert still sits
      ## directly after that same text. A neighbour somebody else deleted or
      ## rewrote takes the answer to no, which is the user-visible failure.
    beyondBound*: bool       ## whether the user must be told


const
  OfflineContextBytes* = 12
    ## How much preceding text counts as "where the user put it". Twelve bytes
    ## is a few grapheme clusters of the corpus — long enough that matching it
    ## by accident is unlikely, short enough that an edit elsewhere on the same
    ## line does not count as having moved the insert.

  OfflineDivergenceBound* = 0.75
    ## **The fraction of a peer's offline inserts that must still sit where the
    ## user put them for the rebase to be called useful.**
    ##
    ## **DERIVED FROM A MEASURED CURVE, NOT CHOSEN.** The sweep is a PROGRAM
    ## and it is in `test_editor_collab_laws.nim` (§36b rule 2: write down the
    ## program, not only the answer) — a 4,096-byte slice of the `c1-zwj-long`
    ## corpus document, four offline inserts spread by BYTE offset, a remote
    ## stream in which every third edit REWRITES a two-cluster run, and the
    ## mean of twelve trials per level:
    ##
    ##     intervening   bytes per   mean fraction still
    ##     remote edits  remote edit  where the user put it
    ##     ------------  -----------  ---------------------
    ##                0           —                    1.00
    ##                4        1024                    0.98
    ##                8         512                    1.00
    ##               16         256                    0.98
    ##               32         128                    0.90
    ##               64          64                    0.79
    ##              128          32                    0.73
    ##              256          16                    0.50
    ##
    ## **The bound is a DENSITY and not a count**, which is the correction the
    ## measurement forced. The first sweep varied the number of intervening
    ## edits on a 78-byte window and found three of them enough to destroy
    ## everything; the same counts on a 67 KB document left all four intact at
    ## 128. What predicts the damage is remote edits per byte of document, and
    ## half a peer's work is misplaced at about **one remote edit per sixteen
    ## bytes**. Degradation begins around one per 128.
    ##
    ## `0.75` is the first observable degradation rather than the halfway
    ## point, because *"not all of your edits are where you left them"* is
    ## what a user needs to be told; by the time half are gone the session is
    ## already not worth reconnecting.
    ##
    ## **Two measurement defects were found and repaired before this table was
    ## believed**, and both are §36b's shape:
    ##
    ##  1. the first metric was *surviving bytes*, which a rebase can never
    ##     reduce — a constant wearing a measurement's clothes (see
    ##     `DivergenceReport.contextPreserved`);
    ##  2. the first curve was ONE trial per level and came back
    ##     non-monotone — 2/4, then 4/4, then 3/4, then 0/4. A single sample
    ##     of a noisy quantity is [§28]'s coin flip. Twelve trials per level
    ##     make it monotone.
    ##
    ## Chosen by measurement, and the measurement is a PROGRAM rather than a
    ## table (§36b's second rule): `test_editor_collab_laws.nim`'s offline
    ## sweep runs the same three divergence levels at this threshold and
    ## prints the realised survival fraction per level, so re-taking the
    ## figure costs a run. What the threshold is FOR is that beyond it the
    ## rebase result is well-defined and not what anyone wanted, and §12.3
    ## requires the user be told rather than the result be silently applied.

proc divergenceReport*(authorityUpdates, localUpdates, mappings: int;
                       insertsPlaced, contextPreserved: int): DivergenceReport =
  ## Assemble a report and decide the bound in ONE place, so the product's
  ## "tell the user" branch and the suite's assertion read the same predicate
  ## (`Verification-Harness-Traps.md` §30: one predicate, one function).
  DivergenceReport(
    authorityUpdates: authorityUpdates,
    localUpdates: localUpdates,
    mappings: mappings,
    insertsPlaced: insertsPlaced,
    contextPreserved: contextPreserved,
    beyondBound: insertsPlaced > 0 and
      contextPreserved.float / insertsPlaced.float < OfflineDivergenceBound)

proc divergenceMessage*(r: DivergenceReport): string =
  ## What the user is told when the bound is passed. Empty when it is not —
  ## and the suite asserts BOTH halves, because a message that is always
  ## produced is a message that says nothing.
  ##
  ## The shape is the `.cttui-keys` loader's: name the thing, name the
  ## measurement, do not editorialise.
  if not r.beyondBound:
    return ""
  "reconnected after " & $r.authorityUpdates &
    " remote edits with " & $r.localUpdates & " of your own; only " &
    $r.contextPreserved & " of " & $r.insertsPlaced &
    " of your edits still sit where you put them"

proc reconnect*(p: var PeerSession; a: var TextAuthority;
                base: string): tuple[received: Received;
                                     report: DivergenceReport] =
  ## The whole offline round trip, in one routine so the suite drives the real
  ## thing: the peer submits everything it has, the authority rebases it over
  ## what happened meanwhile, the peer receives the intervening work, and the
  ## cost is reported.
  let away = a.version - p.version
  let mine = p.unconfirmed.len

  # What each offline insert was AIMED AFTER: the bytes immediately preceding
  # its insertion point, in the peer's own document. Collected before the
  # submission, because that document is about to stop existing.
  var aims: seq[(string, string)] = @[]
  var walk = base
  for update in p.unconfirmed:
    var at = 0
    for section in update.changes.sections:
      case section.kind
      of skKeep: at += section.keep
      of skReplace:
        if section.insert.len > 0:
          let ctxStart = max(0, at - OfflineContextBytes)
          aims.add (walk[ctxStart ..< at], section.insert)
        at += section.delete
    walk = update.changes.apply(walk)

  let missed = a.logFrom(p.version)
  let outcome = a.accept(p.sendable)
  let received = p.receiveUpdates(missed)
  if outcome.status == asAccepted:
    p.version = a.version
    p.unconfirmed = @[]

  # Did each insert end up directly after the text it was aiming at? A
  # substring search and nothing else — no change set, no mapping, no call
  # into the layer being measured (§30a).
  let finalDoc = a.document(base)
  var preserved = 0
  for (context, inserted) in aims:
    if inserted.len > 0 and finalDoc.contains(context & inserted):
      inc preserved

  (received, divergenceReport(away, mine, away * mine, aims.len, preserved))
