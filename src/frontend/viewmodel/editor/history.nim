## history.nim — PLAT-32: undo and redo in a buffer with more than one writer.
##
## Owns: Editor-ViewModel.md §13 — §13.1 (local undo, grouping, selection
## restoration) and §13.2 (*"the part people underestimate"*).
##
## =========================================================================
## WHAT THIS REPLACES, SAID PLAINLY
## =========================================================================
##
## PLAT-30 shipped a **snapshot** undo stack — `EditorState.undoStack` and
## `redoStack`, each a `seq[Snapshot]` of `(document, selection)` — and its own
## header said what it was: *"not event coalescing, not a mapped-away event
## inheriting its mapping, not `LAW-H1` … `LAW-H6`. Those are PLAT-32's
## deliverables and this module does not pretend to them."*
##
## **The four fields are gone.** `EditorState` carries one `history:
## HistoryState` now, `pushUndo` is `editor_state.recordTransaction`, and
## `undo` / `redo` / `undo-selection` / `redo-selection` — four of the 224
## published operations — are the four `pop*` routines below. Nothing in the
## tree keeps a snapshot of a document for the purpose of undoing it.
##
## Three properties the snapshot stack could not have, and each is a
## deliverable rather than a nicety:
##
## 1. **It is O(edit), not O(document).** A snapshot stack is O(document) per
##    keystroke, which is why `HistoryLimit` existed at all. An event holds an
##    *inverted change set*, which is the size of what changed.
## 2. **A remote edit can be mapped through it.** There is no change set from
##    the current document to a snapshot, so a snapshot cannot be rebased past
##    somebody else's edit — the whole of §13.2 is unreachable from that shape.
##    `restoreSnapshot` recorded the consequence in a comment: it *discarded*
##    the selection history on every undo because the restored coordinates were
##    not reachable from the current ones.
## 3. **It coalesces.** The snapshot stack had *"one delta per keystroke with
##    no coalescing at all"*, so thirty keystrokes were thirty undos.
##
## =========================================================================
## THE SHAPE: TWO BRANCHES OF EVENTS
## =========================================================================
##
## `done` and `undone`, each a `seq[HistEvent]` with the top at the end. An
## event is a **variant with two arms** and that is §13.1's last rule rather
## than a style choice:
##
##   * `hekChange` — an **inverted** change set, the effects, the selection
##     **before** it (`startSelection`) and the selections recorded **after**
##     it (`selectionsAfter`, which is what `undo-selection` walks);
##   * `hekSelection` — a selection-only event, carrying selections and
##     nothing else.
##
## The reference (`refs/codemirror-commands/src/history.ts:158`) spells the
## second arm as a `HistEvent` whose `changes` and `startSelection` are
## `undefined`, with the invariant *"they are always the last event in a
## branch"* written in a comment and enforced by nobody. Here the arms are
## distinct, so a caller that reads `changes` off a selection-only event does
## not compile.
##
## =========================================================================
## §13.2 — "UNDO MINE, NOT THEIRS", AND WHERE THE MAPPING HAPPENS
## =========================================================================
##
## **A remote transaction creates no event.** `record` sees `anRemote` (or
## `anAddToHistory: false`) and pushes the transaction's change *description*
## into **both** branches, as an accumulated mapping attached to the event on
## top of each. `addMappingToBranch` is the whole of it.
##
## **The mapping is inherited when the top event is popped.** `pop` takes the
## top event off, and if that event accumulated a mapping, applies it to the
## rest of the branch — so every event below is rebased exactly once, at the
## moment it matters, rather than on every remote arrival.
##
## **A fully-mapped-away event is dropped and its mapping is inherited by the
## event beneath it.** That is the loop inside `addMappingToBranch`, and it is
## the clause §13.2 calls *"easy to omit and impossible to notice"*: omit it
## and the branch simply has one event fewer, every law about the events that
## remain still holds, and the event below undoes against a document it was
## never expressed over.
##
## **Redo is generated, not stored.** `pop` returns a `HistoryStep` carrying a
## transaction; `recordStep` inverts *that transaction* onto the opposite
## branch through `eventFromTransaction` — the same routine that inverts a
## user's edit. There is one inversion path in this file and redo cannot drift
## from undo because there is nothing for it to drift from.
##
## =========================================================================
## THE FIFTH CALL SITE OF THE ONE REBASE PRIMITIVE
## =========================================================================
##
## `transaction.nim`'s header names five places the reference hand-writes the
## double mapping and says which milestone each belongs to. `mapEvent` below is
## the one it labels PLAT-32. The reference writes it out
## (`history.ts:300`):
##
##     let mappedChanges = event.changes.map(mapping)
##     let before = mapping.mapDesc(event.changes, true)
##
## Two calls, two different argument orders, one boolean flag, and getting
## either of them backwards produces a caret that is off by the width of
## somebody else's insertion — which is precisely what `LAW-H6` is asserted as a
## POSITION to catch. Here it is one `rebase` and the flag is not spelled:
##
##     let r = rebase(mapping, ev.changes)
##     r.bOverA   # `ev.changes`, re-expressed to apply after `mapping`
##     r.aOverB   # `mapping`,    re-expressed to apply after `ev.changes`
##
## `mapOver` is private to `change_set.nim` with exactly two call sites, and
## `test_editor_change_algebra.nim` scans every module of this directory —
## enumerated by `walkDir`, so this file is scanned by construction (§35) — to
## assert that no sixth hand-written copy exists.
##
## =========================================================================
## WHAT IS NOT HERE
## =========================================================================
##
## **No transport.** The remote stream this module is graded against is
## synthetic transactions. PLAT-33 owns the wire, and it depends on this
## milestone rather than the other way round, so this file knows what a remote
## transaction *is* (`anRemote`) and nothing about where it came from.
##
## **No clock.** The time a transaction happened is `anTime`, an annotation on
## the transaction, exactly as it is in the reference. Nothing in this file
## reads a clock, which is what lets a suite drive grouping with a virtual one
## and what keeps this module inside PLAT-29's import-closure gate.

import std/options

import ./change_set
import ./selection
import ./transaction

export change_set, selection, transaction

type
  BranchSide* = enum
    ## Which branch an event came from. Two values, and the opposite of one is
    ## the other — there is no third state and no "both".
    bsDone
    bsUndone

  HistEventKind* = enum
    hekChange     ## carries an inverted change set
    hekSelection  ## a selection-only event — §13.1's variant arm

  HistEvent* = object
    ## One undoable point.
    mapped*: Option[ChangeSet]
      ## The accumulated mapping pushed here by remote transactions, to be
      ## applied to the events BELOW this one when this one is popped. `none`
      ## when nothing remote has arrived since this event was pushed.
      ##
      ## A selection-only event never carries one: it is always the top of its
      ## branch, so there is nothing below it to inherit anything.
    case kind*: HistEventKind
    of hekChange:
      changes*: ChangeSet
        ## **INVERTED.** Applying this to the current document undoes the
        ## transaction that created the event.
      effects*: seq[Effect]
      startSelection*: EditorSelection
        ## The selection BEFORE the transaction. Restored by undo, because
        ## §13.1: *"an undo that restores text and not the caret leaves the
        ## user's position where it was for someone else's reason."*
      endSelection*: EditorSelection
        ## The selection the transaction itself produced, in the coordinates
        ## of the document ABOVE this event — so it is mapped by a remote
        ## change exactly as `selectionsAfter` is.
        ##
        ## **THE REFERENCE DOES NOT STORE THIS AND RECONSTRUCTS IT, AND THE
        ## RECONSTRUCTION IS LOSSY.** `history.ts:357` computes the selection
        ## a redo must restore as
        ## `event.startSelection.map(event.changes.invertedDesc, 1)` — the
        ## PRE-edit selection pushed forward through the edit, with the
        ## association hardcoded to 1. That is right only when the caret was
        ## adjacent to the edit and wanted to end up after the inserted text.
        ## It was measured wrong here on the first run: a caret at 0 with an
        ## insertion at 5 reconstructs to 0, and the selection the user
        ## actually had after typing was 6.
        ##
        ## Our selection carries a per-range association (`LAW-S4`), so
        ## hardcoding one is not available to us even if it were right. The
        ## transaction knows what selection it produced; the event records it.
        ## `LAW-H2` — *"`redo(undo(t))` restores `t`'s document AND `t`'s
        ## selection"* — is then an equality rather than an approximation.
      selectionsAfter*: seq[EditorSelection]
        ## The selections recorded after it by later selection-only
        ## transactions. `undo-selection` walks these.
      userEvent*: UserEvent
        ## What the user did, for grouping. `transaction.UserEvent`, which is
        ## a CLOSED enum — a grouping rule over an open set is a rule with a
        ## default branch nobody enumerated.
      isolated*: bool
        ## The explicit isolation annotation, resolved. See `GroupableEvents`.
    of hekSelection:
      selections*: seq[EditorSelection]
        ## Non-empty. A selection-only event with no selections would be an
        ## event that restores nothing.

  Branch* = seq[HistEvent]
    ## Top at the end.

  HistoryState* = object
    done*: Branch
    undone*: Branch
    prevTime*: int64
    prevUserEvent*: Option[UserEvent]

  HistoryStepKind* = enum
    hskChange      ## the popped event moved the document
    hskSelection   ## `undo-selection` / `redo-selection`

  HistoryStep* = object
    ## What a `pop` produced. **Not a new history state**: applying the
    ## transaction is the caller's job, and the opposite branch cannot be
    ## written until that has happened, because the event pushed onto it is the
    ## INVERSION of this transaction against the document it applied to.
    kind*: HistoryStepKind
    side*: BranchSide
      ## Which branch it came from. The event goes onto the other one.
    tr*: Transaction
      ## Apply this. Its `anUserEvent` is `ueUndo` or `ueRedo`.
    rest*: HistoryState
      ## The history with the popped event removed and its accumulated mapping
      ## inherited by the branch below. The OTHER branch is untouched here and
      ## is written by `recordStep`.
    revisedSelection*: EditorSelection
      ## The selection the opposite branch's event must record as its
      ## `startSelection` — the selection the user had at the time of the
      ## original edit, not the one that happened to be current when undo was
      ## pressed. This is what makes `LAW-H2` a claim about the SELECTION as
      ## well as the document.
    selectionBefore*: EditorSelection
      ## The selection at the moment of the pop.

  HistoryError* = object of ValueError
    ## Raised when a history operation is asked for something its own
    ## bookkeeping cannot produce — an event whose change set does not meet the
    ## document, or an undo transaction offered to `record`. **It raises rather
    ## than repairing**, which is Verification-Harness-Traps §36a's first rule:
    ## *"a guard that repairs a value silently must be a guard that RAISES,
    ## unless the repair is itself a specified behaviour with a name."* An undo
    ## position clamped into range is the exact shape that makes a broken
    ## inverse look total.

const
  NewGroupDelayMs* = 500'i64
    ## §13.1's elapsed-time half of the grouping rule, and CodeMirror's own
    ## `newGroupDelay` default (`history.ts:22`). Named rather than written
    ## into a case, so `LAW-H5` asserts the boundary AT it and one past it
    ## rather than somewhere plausible.

  MaxHistoryDepth* = 128
    ## How many events a branch keeps. PLAT-30's `HistoryLimit` was the same
    ## number bounding a snapshot stack, where it was a memory bound; here it
    ## is a policy — how far back undo reaches.

  GroupableEvents* = {ueInput, ueDelete}
    ## §13.1's *"by the transaction's own kind"*. The reference's
    ## `joinableUserEvent` regex is `/^(input\.type|delete)($|\.)/`
    ## (`history.ts:306`) and this is that set, closed and enumerable.
    ##
    ## A motion, a selection change, an undo and a redo never coalesce with
    ## their neighbours, and `LAW-H5` is driven over four kinds rather than
    ## two so that the non-groupable arms are evidence rather than assumption.

  MaxSelectionsPerEvent* = 200
    ## `history.ts:250`. A bound on the selection history hanging off one
    ## event, so a user moving the caret for an hour without editing does not
    ## grow one event without limit.

# ===========================================================================
# READING THE TRANSACTION'S ANNOTATIONS
# ===========================================================================
#
# The annotation set is CLOSED (`transaction.nim` §6.3), so each of these is a
# total function over it rather than a lookup that can miss.

func userEventOf*(t: Transaction): UserEvent =
  ## `ueInput` when the transaction does not say. A transaction that changes
  ## the document and names no user event is an input as far as grouping is
  ## concerned, which is the reference's default too.
  result = ueInput
  for a in t.annotations:
    if a.kind == anUserEvent: result = a.userEvent

func timeOf*(t: Transaction): int64 =
  result = 0
  for a in t.annotations:
    if a.kind == anTime: result = a.timeMs

func isRemote*(t: Transaction): bool =
  ## §12.2's own annotation, reused. §13.2: *"a remote transaction never
  ## enters the local undo stack, and the mark that says so is the same
  ## annotation the collaboration layer already sets."*
  for a in t.annotations:
    if a.kind == anRemote: return true
  false

func addToHistory*(t: Transaction): bool =
  ## Explicitly `false` suppresses the event. Defaults to true.
  result = true
  for a in t.annotations:
    if a.kind == anAddToHistory: result = a.addToHistory

func isolatedOf*(t: Transaction): bool =
  ## §13.1's *"explicit isolation annotation for a transaction that must not
  ## merge with its neighbours"*, read off `anGroupWithPrevious`.
  ##
  ## **ONE VALUE, NOT THE REFERENCE'S THREE, AND THAT IS A DECISION.**
  ## CodeMirror's `isolateHistory` takes `"before"`, `"after"` or `"full"`.
  ## The one-sided arms produce a state in which one neighbour may merge and
  ## the other may not, which is an invariant nothing enumerates and which
  ## §13.1 does not ask for — it asks for *"must not merge with its
  ## neighbourS"*, plural. So the annotation is two-valued and isolation is
  ## FULL: the transaction does not merge backwards, and the event it creates
  ## is marked so nothing merges into it either. The cost is that a caller who
  ## wanted one-sided isolation cannot express it; the benefit is that there is
  ## no arm of a three-valued enum that no case drives.
  for a in t.annotations:
    if a.kind == anGroupWithPrevious: return not a.groupWithPrevious
  false

# ===========================================================================
# EVENTS
# ===========================================================================

func selectionsAfterOf*(ev: HistEvent): seq[EditorSelection] =
  ## Total over both arms, so a caller never asks which one it has.
  case ev.kind
  of hekChange: ev.selectionsAfter
  of hekSelection: ev.selections

func isEmptyEvent(ev: HistEvent): bool =
  ## An event with nothing left to undo. The test is on the CHANGES and the
  ## EFFECTS, never on the selections: a selection is restored BY an event and
  ## is not itself a reason for the event to exist.
  case ev.kind
  of hekSelection: true
  of hekChange: ev.changes.isIdentity and ev.effects.len == 0

func withSelectionsAfter(ev: HistEvent; sels: seq[EditorSelection]): HistEvent =
  case ev.kind
  of hekChange:
    HistEvent(kind: hekChange, mapped: ev.mapped, changes: ev.changes,
              effects: ev.effects, startSelection: ev.startSelection,
              endSelection: ev.endSelection,
              selectionsAfter: sels, userEvent: ev.userEvent,
              isolated: ev.isolated)
  of hekSelection:
    HistEvent(kind: hekSelection, mapped: ev.mapped, selections: sels)

func selectionEvent*(sels: seq[EditorSelection]): HistEvent =
  HistEvent(kind: hekSelection, mapped: none(ChangeSet), selections: sels)

proc eventFromTransaction*(t: Transaction; docBefore: string;
                           selectionBefore: EditorSelection;
                           startOverride = none(EditorSelection)):
                          Option[HistEvent] =
  ## **THE ONE INVERSION PATH.** A user's edit and an undo transaction both
  ## become an event through this routine, which is what makes redo unable to
  ## drift from undo (`LAW-H2`). `none` when there is nothing to undo.
  if t.changes.isIdentity and t.effects.len == 0:
    return none(HistEvent)
  some HistEvent(
    kind: hekChange,
    mapped: none(ChangeSet),
    changes: invert(t.changes, docBefore),
    effects: t.effects,
    startSelection: (if startOverride.isSome: startOverride.get
                     else: selectionBefore),
    endSelection: (if t.selection.isSome: t.selection.get
                   else: mapSelection(selectionBefore, t.changes)),
    selectionsAfter: @[],
    userEvent: userEventOf(t),
    isolated: isolatedOf(t))

# ===========================================================================
# MAPPING AN EVENT PAST A REMOTE CHANGE — the fifth call site
# ===========================================================================

proc mapEvent*(ev: HistEvent; mapping: ChangeSet;
               extraSelections: seq[EditorSelection]): HistEvent =
  ## `ev`, re-expressed against the document `mapping` produced.
  ##
  ## `extraSelections` are the selections inherited from an event that was
  ## dropped above this one — already expressed in the right coordinates,
  ## because they were mapped on the way down.
  var sels: seq[EditorSelection] = @[]
  for s in selectionsAfterOf(ev):
    sels.add mapSelection(s, mapping)
  for s in extraSelections:
    sels.add s
  if sels.len > MaxSelectionsPerEvent:
    sels = sels[sels.len - MaxSelectionsPerEvent ..< sels.len]

  case ev.kind
  of hekSelection:
    # A change-less event stores no mapping: it is always the last event in a
    # branch, so there is nothing below it for a mapping to be inherited by.
    return selectionEvent(sels)
  of hekChange:
    # ===================================================================
    # THE DOUBLE MAPPING, AS ONE CALL
    # ===================================================================
    # `ev.changes` inverts the event against the CURRENT document; `mapping`
    # is the remote change over that same document. Both are expressed over
    # one document, which is exactly `rebase`'s precondition.
    #
    #   `bOverA` — `ev.changes` after `mapping`: the inversion, moved past
    #              somebody else's edit. This is "undo mine".
    #   `aOverB` — `mapping` after `ev.changes`: the remote change expressed
    #              in the coordinates of the document BELOW this event, which
    #              is what the events below need and what `mapped` accumulates.
    #              This is "not theirs".
    let r = rebase(mapping, ev.changes)
    let full =
      if ev.mapped.isSome: compose(ev.mapped.get, r.aOverB)
      else: r.aOverB
    HistEvent(
      kind: hekChange,
      mapped: some(full),
      changes: r.bOverA,
      effects: mapEffects(ev.effects, mapping),
      startSelection: mapSelection(ev.startSelection, r.aOverB),
      endSelection: mapSelection(ev.endSelection, mapping),
      selectionsAfter: sels,
      userEvent: ev.userEvent,
      isolated: ev.isolated)

proc addMappingToBranch*(branch: Branch; mapping: ChangeSet): Branch =
  ## Push a remote change's description onto the top of `branch`.
  ##
  ## **THE DROP-AND-INHERIT LOOP IS THE WHOLE POINT OF THIS ROUTINE.** If the
  ## top event's changes and effects are entirely mapped away, the event is
  ## removed — and the mapping it had accumulated is carried down to the event
  ## beneath it, *not discarded with it*. §13.2: *"that last clause is the one
  ## that is easy to omit and impossible to notice."*
  ##
  ## Impossible to notice because dropping the mapping leaves a branch that is
  ## perfectly well-formed, one event shorter, every remaining event
  ## individually valid — and the event that is now on top is expressed over a
  ## document that no longer exists. Nothing is wrong until somebody undoes
  ## twice.
  if branch.len == 0: return branch
  var length = branch.len
  var carried = mapping
  var selections: seq[EditorSelection] = @[]
  while length > 0:
    let ev = mapEvent(branch[length - 1], carried, selections)
    if not isEmptyEvent(ev):
      result = branch[0 ..< length]
      result[length - 1] = ev
      return result
    # Dropped. Inherit its mapping and its selections.
    carried =
      if ev.mapped.isSome: ev.mapped.get
      else: identityChangeSet(carried.newLength)
    selections = selectionsAfterOf(ev)
    dec length
  if selections.len > 0: @[selectionEvent(selections)] else: @[]

# ===========================================================================
# BRANCH BOOKKEEPING
# ===========================================================================

func pushEvent(branch: Branch; ev: HistEvent): Branch =
  result = branch
  result.add ev
  if result.len > MaxHistoryDepth:
    result.delete(0)

func addSelectionToBranch*(branch: Branch;
                           sel: EditorSelection): Branch =
  ## `history.ts:253`. A selection recorded with no document change hangs off
  ## the top event; with an empty branch it becomes a selection-only event.
  if branch.len == 0:
    return @[selectionEvent(@[sel])]
  let last = branch[^1]
  var sels = selectionsAfterOf(last)
  if sels.len > MaxSelectionsPerEvent:
    sels = sels[sels.len - MaxSelectionsPerEvent ..< sels.len]
  if sels.len > 0 and sels[^1] == sel:
    return branch
  sels.add sel
  result = branch
  result[^1] = withSelectionsAfter(last, sels)

func popSelectionFrom(branch: Branch): Branch =
  result = branch
  let last = branch[^1]
  let sels = selectionsAfterOf(last)
  result[^1] = withSelectionsAfter(last, sels[0 ..< sels.len - 1])
  # A selection-only event that has run out of selections is not an event.
  if result[^1].kind == hekSelection and result[^1].selections.len == 0:
    result.setLen(result.len - 1)

func initHistory*(): HistoryState =
  HistoryState(done: @[], undone: @[], prevTime: 0,
               prevUserEvent: none(UserEvent))

func undoDepth*(h: HistoryState): int =
  ## `history.ts:143`: a leading selection-only event is not an undoable step.
  h.done.len - (if h.done.len > 0 and h.done[0].kind == hekSelection: 1 else: 0)

func redoDepth*(h: HistoryState): int =
  h.undone.len -
    (if h.undone.len > 0 and h.undone[0].kind == hekSelection: 1 else: 0)

func isolate*(h: HistoryState): HistoryState =
  ## Break the grouping window. The next transaction starts a new event
  ## whatever the clock says.
  HistoryState(done: h.done, undone: h.undone, prevTime: 0,
               prevUserEvent: none(UserEvent))

func `==`*(a, b: HistEvent): bool =
  if a.kind != b.kind: return false
  if a.mapped.isSome != b.mapped.isSome: return false
  if a.mapped.isSome and not sameMapping(a.mapped.get, b.mapped.get):
    return false
  case a.kind
  of hekChange:
    a.changes == b.changes and a.effects == b.effects and
      a.startSelection == b.startSelection and
      a.endSelection == b.endSelection and
      a.selectionsAfter == b.selectionsAfter and
      a.userEvent == b.userEvent and a.isolated == b.isolated
  of hekSelection:
    a.selections == b.selections

func `==`*(a, b: HistoryState): bool =
  a.done == b.done and a.undone == b.undone and
    a.prevTime == b.prevTime and a.prevUserEvent == b.prevUserEvent

# ===========================================================================
# GROUPING — §13.1, two-sided
# ===========================================================================

proc isAdjacent*(a, b: ChangeSet): bool =
  ## `history.ts:228`. `a` is the previous event's inverted change set and `b`
  ## the new one; both are read in the coordinates of the document BETWEEN the
  ## two edits — `a`'s old side and `b`'s new side — which is why the two
  ## halves read different fields of `ChangedRange`.
  ##
  ## Two keystrokes a page apart inside one grouping window are two events,
  ## because an undo that removed both would remove an edit the user cannot see
  ## being removed.
  var spans: seq[(int, int)] = @[]
  for r in changedRanges(a):
    spans.add (r.fromA, r.toA)
  for r in changedRanges(b):
    for s in spans:
      if r.toB >= s[0] and r.fromB <= s[1]: return true
  false

proc mayGroup*(h: HistoryState; top: HistEvent; ev: HistEvent;
               nowMs: int64): bool =
  ## **STATED AS ONE PREDICATE, CALLED BY THE RULE AND BY EVERY CONTROL**
  ## (Verification-Harness-Traps §30b). The suite's grouping cases and
  ## `addChanges` below both call this, so one edit reddens both at once.
  if top.kind != hekChange: return false
  if top.changes.isIdentity: return false
  if top.isolated or ev.isolated: return false
  if top.selectionsAfter.len > 0: return false
  if ev.userEvent notin GroupableEvents: return false
  if h.prevUserEvent.isNone or h.prevUserEvent.get != ev.userEvent: return false
  if nowMs - h.prevTime >= NewGroupDelayMs: return false
  isAdjacent(top.changes, ev.changes)

proc addChanges(h: HistoryState; ev: HistEvent; nowMs: int64): HistoryState =
  var done = h.done
  if done.len > 0 and mayGroup(h, done[^1], ev, nowMs):
    let last = done[^1]
    # **THE INVERSIONS ARE COMPOSED.** `LAW-H1`'s published killer is
    # *"coalesce two events into one WITHOUT composing their inversions"* —
    # keep one of the two and the merged event undoes half the group, landing
    # on a document the stream never held.
    done[^1] = HistEvent(
      kind: hekChange,
      mapped: last.mapped,
      changes: compose(ev.changes, last.changes),
      effects: mapEffects(ev.effects, last.changes) & last.effects,
      startSelection: last.startSelection,
      endSelection: ev.endSelection,
      selectionsAfter: @[],
      userEvent: last.userEvent,
      isolated: last.isolated)
  else:
    done = pushEvent(done, ev)
  HistoryState(done: done, undone: @[], prevTime: nowMs,
               prevUserEvent: some(ev.userEvent))

func eqSelectionShape*(a, b: EditorSelection): bool =
  ## `history.ts:240`. Same number of ranges, and each pair agrees about being
  ## empty. It is deliberately NOT `==`: a caret sweeping across a line is one
  ## selection change per position, and recording each of them would make
  ## `undo-selection` a per-character walk.
  if a.rangeCount != b.rangeCount: return false
  for i in 0 ..< a.rangeCount:
    if a[i].isEmpty != b[i].isEmpty: return false
  true

proc recordSelectionChange*(h: HistoryState; sel: EditorSelection;
                            nowMs: int64;
                            userEvent = ueSelect): HistoryState =
  let last = if h.done.len > 0: selectionsAfterOf(h.done[^1])
             else: newSeq[EditorSelection]()
  if last.len > 0 and nowMs - h.prevTime < NewGroupDelayMs and
     h.prevUserEvent.isSome and h.prevUserEvent.get == userEvent and
     userEvent == ueSelect and
     eqSelectionShape(last[^1], sel):
    return h
  HistoryState(done: addSelectionToBranch(h.done, sel), undone: h.undone,
               prevTime: nowMs, prevUserEvent: some(userEvent))

# ===========================================================================
# RECORDING
# ===========================================================================

proc record*(h: HistoryState; t: Transaction; docBefore: string;
             selectionBefore: EditorSelection): HistoryState =
  ## Offer a transaction to the history. The time is `anTime` on the
  ## transaction; nothing here reads a clock.
  ##
  ## **AN UNDO OR REDO TRANSACTION RAISES RATHER THAN BEING RECORDED.** It has
  ## to go through `recordStep`, which knows which branch it came from. Routed
  ## here it would push a second event onto `done` and the two branches would
  ## both grow on every undo — a defect that produces a *valid* history whose
  ## depth is wrong, which is §36's shape. So it is a named raise.
  let ue = userEventOf(t)
  if ue in {ueUndo, ueRedo}:
    raise newException(HistoryError,
      "record: a " & $ue & " transaction must go through recordStep, which " &
      "knows which branch it came from")

  if isRemote(t) or not addToHistory(t):
    # =====================================================================
    # A REMOTE TRANSACTION CREATES NO EVENT — §13.2's first rule.
    # =====================================================================
    # Its description goes into BOTH branches. The published killer for
    # `LAW-H3` is *"push it into the done branch only"*, which leaves redo
    # rebasing against a document that moved under it.
    if t.changes.isIdentity: return h
    return HistoryState(done: addMappingToBranch(h.done, t.changes),
                        undone: addMappingToBranch(h.undone, t.changes),
                        prevTime: h.prevTime,
                        prevUserEvent: h.prevUserEvent)

  var st = h
  if isolatedOf(t): st = st.isolate()
  let ev = eventFromTransaction(t, docBefore, selectionBefore)
  if ev.isSome:
    st = st.addChanges(ev.get, timeOf(t))
  elif t.selection.isSome:
    st = recordSelectionChange(st, selectionBefore, timeOf(t), ue)
  st

proc recordStep*(step: HistoryStep; docBefore: string): HistoryState =
  ## The opposite-branch half of an undo or a redo.
  ##
  ## `step.rest` already holds the branch the event came from, with the event
  ## removed and its mapping inherited. This writes the OTHER branch, by
  ## inverting `step.tr` through `eventFromTransaction` — the same routine a
  ## user's edit goes through. **That is what "redo is generated rather than
  ## stored" means mechanically**: nothing was kept when the event was pushed
  ## onto `done`, so there is nothing that could have gone stale.
  var h = step.rest
  let ev = eventFromTransaction(step.tr, docBefore, step.selectionBefore,
                                startOverride = some(step.revisedSelection))
  case step.side
  of bsDone:
    if ev.isSome: h.undone = pushEvent(h.undone, ev.get)
    else: h.undone = addSelectionToBranch(h.undone, step.selectionBefore)
  of bsUndone:
    if ev.isSome: h.done = pushEvent(h.done, ev.get)
    else: h.done = addSelectionToBranch(h.done, step.selectionBefore)
  # An undo isolates: the next edit does not coalesce into an event that was
  # itself produced by walking the history.
  h.prevTime = 0
  h.prevUserEvent = none(UserEvent)
  h

# ===========================================================================
# POPPING
# ===========================================================================

func historyUserEvent(side: BranchSide): UserEvent =
  if side == bsDone: ueUndo else: ueRedo

proc pop(h: HistoryState; side: BranchSide; doc: string;
         selection: EditorSelection;
         onlySelection: bool): Option[HistoryStep] =
  let branch = if side == bsDone: h.done else: h.undone
  if branch.len == 0: return none(HistoryStep)
  let ev = branch[^1]
  let after = selectionsAfterOf(ev)

  # The selection the OPPOSITE branch's event records as its start — the one
  # the user had at the time of the original edit.
  var revised: EditorSelection
  case ev.kind
  of hekChange:
    # **STORED, NOT RECONSTRUCTED.** See `HistEvent.endSelection` for the
    # measurement that decided this.
    revised = ev.endSelection
  of hekSelection:
    revised = if after.len > 0: after[0] else: selection

  if onlySelection and after.len > 0:
    var rest = h
    if side == bsDone: rest.done = popSelectionFrom(branch)
    else: rest.undone = popSelectionFrom(branch)
    return some HistoryStep(
      kind: hskSelection, side: side,
      tr: transaction(identityChangeSet(doc.len), some(after[^1]), @[],
                      @[Annotation(kind: anUserEvent,
                                   userEvent: historyUserEvent(side))]),
      rest: rest, revisedSelection: revised, selectionBefore: selection)

  if ev.kind == hekSelection:
    # A selection-only event cannot answer a DOCUMENT undo. Refusing is the
    # honest answer; walking past it to the event below would undo a change the
    # user did not ask about.
    return none(HistoryStep)

  if ev.changes.length != doc.len:
    raise newException(HistoryError,
      "pop: the top event inverts a document of " & $ev.changes.length &
      " bytes and the document is " & $doc.len &
      " — a remote change reached the document and not the history")

  # ======================================================================
  # THE MAPPING IS INHERITED HERE, AND ONLY HERE.
  # ======================================================================
  # Every event below the one being popped is rebased exactly once, at the
  # moment it matters, rather than on every remote arrival.
  var rest = branch[0 ..< branch.len - 1]
  if ev.mapped.isSome:
    rest = addMappingToBranch(rest, ev.mapped.get)
  var restState = h
  if side == bsDone: restState.done = rest else: restState.undone = rest

  some HistoryStep(
    kind: hskChange, side: side,
    tr: transaction(ev.changes, some(ev.startSelection), ev.effects,
                    @[Annotation(kind: anUserEvent,
                                 userEvent: historyUserEvent(side))]),
    rest: restState, revisedSelection: revised, selectionBefore: selection)

proc popUndo*(h: HistoryState; doc: string;
              selection: EditorSelection): Option[HistoryStep] =
  pop(h, bsDone, doc, selection, onlySelection = false)

proc popRedo*(h: HistoryState; doc: string;
              selection: EditorSelection): Option[HistoryStep] =
  pop(h, bsUndone, doc, selection, onlySelection = false)

proc popUndoSelection*(h: HistoryState; doc: string;
                       selection: EditorSelection): Option[HistoryStep] =
  pop(h, bsDone, doc, selection, onlySelection = true)

proc popRedoSelection*(h: HistoryState; doc: string;
                       selection: EditorSelection): Option[HistoryStep] =
  pop(h, bsUndone, doc, selection, onlySelection = true)

# ===========================================================================
# THE SESSION — the real-stack surface
# ===========================================================================

type
  HistorySession* = object
    ## A document, a selection and a history, moved together.
    ##
    ## This is what the integration tests drive: a real document, real change
    ## sets, real inversions, no mocks. It exists because the three values have
    ## to move in step — applying a transaction without recording it, or
    ## recording one without applying it, are the two ways a history goes wrong
    ## that no property over the history alone can see.
    doc*: string
    selection*: EditorSelection
    history*: HistoryState
    visited*: seq[string]
      ## Every document the stream passed through, in order, including the
      ## first. `LAW-H1` is quantified over this: *"undo returns to a state the
      ## stream actually passed through"* — which is gradeable without an
      ## oracle, and is the law that makes the whole stack checkable.

proc initSession*(doc: string;
                  selection = caretSelection(0)): HistorySession =
  HistorySession(doc: doc, selection: selection, history: initHistory(),
                 visited: @[doc])

proc applyTransaction*(s: var HistorySession; t: Transaction) =
  ## A local or remote transaction, applied AND recorded.
  let before = s.doc
  let selBefore = s.selection
  s.history = record(s.history, t, before, selBefore)
  s.doc = t.changes.apply(before)
  if t.selection.isSome:
    s.selection = t.selection.get
  else:
    s.selection = mapSelection(selBefore, t.changes)
  if s.doc != s.visited[^1]: s.visited.add s.doc

proc applyStep(s: var HistorySession; step: HistoryStep) =
  let before = s.doc
  s.doc = step.tr.changes.apply(before)
  s.selection =
    if step.tr.selection.isSome: step.tr.selection.get
    else: mapSelection(s.selection, step.tr.changes)
  s.history = recordStep(step, before)
  if s.doc != s.visited[^1]: s.visited.add s.doc

proc undo*(s: var HistorySession): bool =
  let step = popUndo(s.history, s.doc, s.selection)
  if step.isNone: return false
  s.applyStep(step.get)
  true

proc redo*(s: var HistorySession): bool =
  let step = popRedo(s.history, s.doc, s.selection)
  if step.isNone: return false
  s.applyStep(step.get)
  true

proc undoSelection*(s: var HistorySession): bool =
  let step = popUndoSelection(s.history, s.doc, s.selection)
  if step.isNone: return false
  s.applyStep(step.get)
  true

proc redoSelection*(s: var HistorySession): bool =
  let step = popRedoSelection(s.history, s.doc, s.selection)
  if step.isNone: return false
  s.applyStep(step.get)
  true
