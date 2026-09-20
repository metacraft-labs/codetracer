## transaction.nim — PLAT-25: the transaction, and the first of the five
## places that call the ONE rebase primitive.
##
## Owns: Editor-ViewModel.md §6 (*"a transaction is the only way state
## changes"*) and §6.3 (annotations and effects as CLOSED, typed sets).
##
## =========================================================================
## WHY THE SETS ARE CLOSED
## =========================================================================
##
## CodeMirror's `Annotation` and `StateEffect` are open extensible registries:
## `Annotation.define<T>()` mints a new type at run time and any package may
## do it. §6.3 takes the other side deliberately — *"a closed set is
## enumerable by a test and an open one is not"* — so both are enums here, and
## `test_editor_change_examples.nim` sweeps every member of each. A sweep
## whose cardinality is asserted is a sweep that cannot silently shrink; a
## registry has no cardinality to assert.
##
## =========================================================================
## THE CALL SITE
## =========================================================================
##
## `mergeTransactions` is the Nim counterpart of CodeMirror's
## `mergeTransaction` (`codemirror-state/src/transaction.ts:310-328`), the
## FIRST of the five places the reference hand-writes the double mapping. It
## calls `rebase` and takes both arms from it; there is no `before` in this
## file and there is no `map` it could pass one to.
##
## The other four — `changeByRange` (PLAT-26), `mapEvent` (PLAT-32),
## `receiveUpdates` and `rebaseUpdates` (PLAT-33) — belong to features that do
## not exist at this milestone. What keeps them from hand-writing their own
## copy when they arrive is not this comment: it is that `mapOver` is private
## to `change_set.nim`, and the source scan in
## `test_editor_change_algebra.nim` asserts it stays private with exactly two
## call sites.
##
## =========================================================================
## THE SELECTION IS §7's, AND THE PLACEHOLDER IS GONE — PLAT-26
## =========================================================================
##
## Until PLAT-26 this file carried a `TransactionSelection` of one anchor and
## one head, labelled PROVISIONAL in this header, because §7's selection did
## not exist yet. It exists now: `editor/selection.nim`'s `EditorSelection` —
## an ordered, non-empty, CANONICAL sequence of ranges with a primary index,
## meaning nothing overlaps and no adjacent pair is still mergeable under
## `selection.nim`'s rule — and a transaction carries one of those or none.
##
## **The placeholder was replaced rather than kept beside the real type.** A
## one-range selection type that survives the milestone that was supposed to
## remove it is exactly how "multi-cursor is the absence of a special case"
## turns into a special case: every caller that kept using it would be a
## caller with a single-range assumption compiled in. `mapSelection` below is
## one line and delegates to `selection.mapSelection`, so the biasing rule
## (`LAW-S4`) is stated once, in the module that owns it.

import std/options

import ./change_set
import ./selection

export selection

type
  UserEvent* = enum
    ## What the user did, as far as grouping for undo is concerned. Closed:
    ## §13.1's grouping rule reads this, and a grouping rule over an open set
    ## is a rule with a default branch nobody enumerated.
    ueInput
    ueDelete
    ueMove
    ueSelect
    ueUndo
    ueRedo

  AnnotationKind* = enum
    ## Facts ABOUT the transaction. Never document state.
    anUserEvent          ## which user event produced it
    anOrigin             ## a free-text provenance label
    anRemote             ## it arrived from a peer, and from which
    anAddToHistory       ## may it be undone
    anGroupWithPrevious  ## may it be coalesced with its predecessor
    anTime               ## when it happened, in milliseconds

  Annotation* = object
    case kind*: AnnotationKind
    of anUserEvent: userEvent*: UserEvent
    of anOrigin: origin*: string
    of anRemote: peer*: string
    of anAddToHistory: addToHistory*: bool
    of anGroupWithPrevious: groupWithPrevious*: bool
    of anTime: timeMs*: int64

  EffectKind* = enum
    ## Typed, non-document state changes travelling with the same atomic
    ## update. The two that carry POSITIONS are the reason effects have to be
    ## mapped at all, and they are the ones the sweep is about.
    efScrollIntoView
    efRevealRange        ## carries positions
    efFocusEditor
    efSetLanguage
    efAnnounce
    efMoveCaretTo        ## carries a position

  Effect* = object
    case kind*: EffectKind
    of efScrollIntoView: discard
    of efRevealRange:
      rangeFrom*, rangeTo*: int
    of efFocusEditor: discard
    of efSetLanguage:
      language*: string
    of efAnnounce:
      message*: string
    of efMoveCaretTo:
      caret*: int

  Transaction* = object
    ## §6: a change set, an optional selection, typed effects, typed
    ## annotations.
    changes*: ChangeSet
    selection*: Option[EditorSelection]
    effects*: seq[Effect]
    annotations*: seq[Annotation]

  # =========================================================================
  # TRANSACTION FILTERS — PLAT-33, and they exist so that §12.2's second
  # "not incidental" property is a property of something
  # =========================================================================
  #
  # `Editor-ViewModel.md` §12.2 requires a received remote transaction to
  # **bypass the local transaction filters**, on the ground that *"a local
  # read-only guard or protected-range filter that suppressed part of a remote
  # change would silently break convergence."* Until this milestone there were
  # no filters in the tree at all — so "remote changes bypass them" was a
  # sentence about a mechanism that did not exist, and `LAW-X4`'s second arm
  # would have been `Verification-Harness-Traps.md` §7c: *a green fixture
  # describing a state no shipped route can reach*.
  #
  # So the two filters §12.2 names by name are built, and they are a CLOSED
  # enum for the same reason the annotations are: a closed set is enumerable
  # by a test and an open registry is not. They are the two the spec names and
  # not a general extension point — an extension point would be a third thing
  # to test whose members nobody can count.

  FilterKind* = enum
    tfReadOnly        ## the buffer refuses every LOCAL change
    tfProtectedRange  ## local changes touching `[from, to)` are refused

  TransactionFilter* = object
    case kind*: FilterKind
    of tfReadOnly: discard
    of tfProtectedRange:
      protectedFrom*, protectedTo*: int

const
  # **NO `FilterKindCount`, AND THE ABSENCE IS DELIBERATE.** The two counts
  # below exist because a SWEEP multiplies by them (§10.4 rule 3: a sweep's
  # multiplier must be an asserted cardinality). No sweep runs over the filter
  # kinds — `LAW-X4` drives each of the two by name, under two scenarios —
  # so a derived constant here would be an export nothing reads, which is a
  # reachability finding carried for the shape of a neighbour rather than for
  # a use. It was written, measured as dead by `ci/test/frontend-reachability.sh`,
  # and deleted rather than ratcheted.
  AnnotationKindCount* = ord(high(AnnotationKind)) - ord(low(AnnotationKind)) + 1
  EffectKindCount* = ord(high(EffectKind)) - ord(low(EffectKind)) + 1
    ## Derived from the enums rather than written, so the sweep's multiplier
    ## and the enum cannot drift apart (Conformance Suite §10.4, rule 3).

func `==`*(a, b: Annotation): bool =
  if a.kind != b.kind: return false
  case a.kind
  of anUserEvent: a.userEvent == b.userEvent
  of anOrigin: a.origin == b.origin
  of anRemote: a.peer == b.peer
  of anAddToHistory: a.addToHistory == b.addToHistory
  of anGroupWithPrevious: a.groupWithPrevious == b.groupWithPrevious
  of anTime: a.timeMs == b.timeMs

func `==`*(a, b: Effect): bool =
  if a.kind != b.kind: return false
  case a.kind
  of efScrollIntoView, efFocusEditor: true
  of efRevealRange: a.rangeFrom == b.rangeFrom and a.rangeTo == b.rangeTo
  of efSetLanguage: a.language == b.language
  of efAnnounce: a.message == b.message
  of efMoveCaretTo: a.caret == b.caret

func `==`*(a, b: TransactionFilter): bool =
  if a.kind != b.kind: return false
  case a.kind
  of tfReadOnly: true
  of tfProtectedRange:
    a.protectedFrom == b.protectedFrom and a.protectedTo == b.protectedTo

func touchesRange(cs: ChangeSet; rangeFrom, rangeTo: int): bool =
  ## Does `cs` change anything inside `[rangeFrom, rangeTo)`?
  ##
  ## An insertion exactly at either endpoint does NOT touch the range: it
  ## lands outside it, which is the same edge convention `LAW-S4` gives a
  ## selection and the same one `mapRange` implements. A guard that answered
  ## otherwise would refuse the caret position a user types at when their
  ## cursor sits against a protected region's edge.
  var pos = 0
  for section in cs.sections:
    case section.kind
    of skKeep:
      pos += section.keep
    of skReplace:
      let changeFrom = pos
      let changeTo = pos + section.delete
      if section.delete == 0:
        # A pure insertion: inside only if it is STRICTLY inside.
        if changeFrom > rangeFrom and changeFrom < rangeTo:
          return true
      elif changeFrom < rangeTo and changeTo > rangeFrom:
        return true
      pos = changeTo
  false

func refusedBy*(filters: openArray[TransactionFilter];
                cs: ChangeSet): bool =
  ## **THE ONE PREDICATE**, called by the local commit path and by every case
  ## that asserts a filter fired or did not. `Verification-Harness-Traps.md`
  ## §30: a rule and its control that each spell the test out get to disagree
  ## about it; one function they both call cannot.
  ##
  ## Note what is NOT here: there is no `remote` parameter and no bypass flag.
  ## The remote path does not pass `true` to this — it does not CALL it, which
  ## is a difference a source scan can see and a boolean argument is not.
  if cs.isIdentity:
    return false
  for f in filters:
    case f.kind
    of tfReadOnly:
      return true
    of tfProtectedRange:
      if cs.touchesRange(f.protectedFrom, f.protectedTo):
        return true
  false

func carriesPositions*(e: Effect): bool =
  ## Which arms have to be mapped. Stated as a function rather than as a
  ## comment so the sweep can assert both halves: every arm that carries a
  ## position moves under a change set, and every arm that does not is
  ## unchanged by one.
  e.kind in {efRevealRange, efMoveCaretTo}

proc mapEffect*(e: Effect; cs: ChangeSet): Effect =
  ## An effect, moved into the document `cs` produced.
  ##
  ## The `side` choice is not arbitrary and it is not the same for both ends
  ## of a range: a revealed range's start is forward-biased and its end
  ## backward-biased, so text inserted at either edge is not swallowed into
  ## the reveal. That is `LAW-S4`'s rule one milestone early, applied to the
  ## only positioned values that exist yet.
  case e.kind
  of efScrollIntoView, efFocusEditor, efSetLanguage, efAnnounce:
    e
  of efRevealRange:
    Effect(kind: efRevealRange,
           rangeFrom: cs.mapPosOr(e.rangeFrom, sideAfter),
           rangeTo: cs.mapPosOr(e.rangeTo, sideBefore))
  of efMoveCaretTo:
    Effect(kind: efMoveCaretTo, caret: cs.mapPosOr(e.caret, sideBefore))

proc mapEffects*(effects: seq[Effect]; cs: ChangeSet): seq[Effect] =
  result = newSeqOfCap[Effect](effects.len)
  for e in effects: result.add mapEffect(e, cs)

proc transaction*(changes: ChangeSet;
                  selection = none(EditorSelection);
                  effects: seq[Effect] = @[];
                  annotations: seq[Annotation] = @[]): Transaction =
  Transaction(changes: changes, selection: selection, effects: effects,
              annotations: annotations)

proc apply*(t: Transaction; doc: string): string =
  t.changes.apply(doc)

# ===========================================================================
# THE CALL SITE — `mergeTransaction`, ported, calling `rebase`
# ===========================================================================

proc mergeTransactions*(a, b: Transaction; sequential: bool): Transaction =
  ## Merge two transaction specs into one.
  ##
  ## `sequential` says `b`'s change set is expressed against the document `a`
  ## produced; otherwise both are expressed against the SAME document and have
  ## to be rebased over each other — which is where the primitive is.
  ##
  ## This is `codemirror-state/src/transaction.ts:310-328` with its two
  ## hand-written `map` calls replaced by the one `rebase`. Compare:
  ##
  ##     mapForA = b.changes.map(a.changes)          // before defaulted false
  ##     mapForB = a.changes.mapDesc(b.changes, true)
  ##
  ## Those two lines are written again, by hand, in four other files there.
  ## Here they are one call, and the flag is not spelled at all.
  var mapForA, mapForB, changes: ChangeSet
  if sequential:
    if a.changes.newLength != b.changes.length:
      raise newException(ChangeSetError,
        "mergeTransactions(sequential): " & $a.changes.newLength &
        " does not meet " & $b.changes.length)
    mapForA = b.changes
    mapForB = identityChangeSet(b.changes.newLength)
    changes = compose(a.changes, b.changes)
  else:
    let r = rebase(a.changes, b.changes)
    mapForA = r.bOverA
    mapForB = r.aOverB
    changes = compose(a.changes, mapForA)
  var selection = none(EditorSelection)
  if b.selection.isSome:
    selection = some(mapSelection(b.selection.get, mapForB))
  elif a.selection.isSome:
    selection = some(mapSelection(a.selection.get, mapForA))
  Transaction(
    changes: changes,
    selection: selection,
    effects: mapEffects(a.effects, mapForA) & mapEffects(b.effects, mapForB),
    annotations: a.annotations & b.annotations)
