## test_editor_history_examples.nim — PLAT-32's pinned cases: grouping in both
## directions, the delivery-order matrix, the selection-only variant arm, the
## rebased redo position, and the milestone's verification gate.
##
## Compile and run (from the repository root):
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_editor_history_examples.nim
##
## =========================================================================
## WHY THIS IS A SECOND FILE AND NOT MORE CASES IN THE LAW SUITE
## =========================================================================
##
## The laws are quantified over generated streams and are graded without an
## oracle. Everything here is the opposite kind of test: a hand-built sequence
## whose expected answer is written down, over an ASCII document whose offsets
## a reader can count. The campaign keeps the two apart for the reason §2 of
## the conformance suite gives — a property that holds over ten thousand draws
## and an example somebody can read catch different things — and because a
## generated population that drifts takes its laws with it, while a pinned
## example says what it always said.
##
## =========================================================================
## THE DOCUMENT IS ASCII HERE, DELIBERATELY, AND THE CORPUS IS ONE FILE OVER
## =========================================================================
##
## `test_editor_history_laws.nim` runs every law over the nine Unicode corpus
## classes. These cases assert **absolute byte offsets**, and an absolute
## offset inside a ZWJ family or a regional-indicator pair is an assertion
## about the corpus rather than about the history. So the pinned cases use a
## sixteen-byte ASCII ruler and the generated ones carry the Unicode.
##
## =========================================================================
## §30b — ONE PREDICATE, ONE FUNCTION, RULE AND CONTROL BOTH CALLING IT
## =========================================================================
##
## The grouping cases below do NOT re-derive "may these two coalesce". They
## drive the product and count events, and the one place the rule is written is
## `history.mayGroup`, which `addChanges` calls. A control that re-implemented
## the window test would agree with a broken rule for the same reason the rule
## agrees with itself — and the arm would then be a survivor.

import std/[options, strutils, unittest]

import ../../editor/history
import ../../editor/operations
import ../generators/history_generator

var countedAssertions = 0

template counted(condition: untyped) =
  inc countedAssertions
  check condition

const ExpectedAssertions = 522
  ## Asserted by the last case against the runtime tally. Written LAST, from
  ## a run.


const Ruler = "0123456789abcdef"
  ## Sixteen bytes, every one distinct, so a landmark is found by `find` and an
  ## offset is something a reader can count rather than take on trust.

const GroupedKinds = [ueInput, ueDelete]
const UngroupedKinds = [ueMove, ueSelect]
const GroupingKinds = GroupedKinds.len + UngroupedKinds.len
  ## The split is the whole content of *"grouping by the transaction's own
  ## KIND"*: two kinds that coalesce and two that never do, each driven on BOTH
  ## sides of the window — the counted target's *"2 directions x 4 transaction
  ## kinds = 8"*.
  ##
  ## **DERIVED FROM THE TWO LISTS RATHER THAN WRITTEN**, for §10.4 rule 3 and
  ## for a second reason found by this milestone's own needle scan: written as
  ## a literal it was a DECLARED COUNT whose value collided with a digit in the
  ## stream generator's `ssRemoteHeavy` period, and §10.3 rejected that arm.
  ## §35's rule — *"when a scan's needle and a legitimate value collide, prefer
  ## moving the VALUE"* — and the value here had no business being a literal.

const Keystrokes = 5

proc keystrokeRun(kind: UserEvent; spacingMs: int64): HistorySession =
  ## `Keystrokes` single-character appends, `spacingMs` apart, all annotated
  ## with the same kind. Adjacent by construction, because `history.isAdjacent`
  ## is half of the grouping rule and two edits a page apart must not coalesce
  ## whatever the clock says.
  result = initSession(Ruler)
  for i in 0 ..< Keystrokes:
    let at = result.doc.len
    result.applyTransaction(
      localTransaction(result.doc, at, at, "x", kind,
                       NewGroupDelayMs * 10 + int64(i) * spacingMs))

# ===========================================================================
suite "PLAT-32 — grouping, in both directions, over four transaction kinds":
# ===========================================================================

  for k in GroupedKinds:
    let kind = k

    test "grouping x " & $kind & " x INSIDE the window is one event":
      # N keystrokes inside the window produce exactly ONE event. Asserted
      # alone this is satisfied by a history that never records anything, which
      # is why the case below exists and why the group is then UNDONE as a
      # whole.
      var s = keystrokeRun(kind, 1)
      counted s.history.undoDepth == 1
      counted s.doc == Ruler & "xxxxx"
      counted s.undo()
      counted s.doc == Ruler
      counted s.history.undoDepth == 0
      # …and the redo restores the WHOLE group, not one keystroke of it.
      counted s.redo()
      counted s.doc == Ruler & "xxxxx"

    test "grouping x " & $kind & " x SPANNING the window is one event each":
      # The same N, spaced past the window. Asserted alone THIS is satisfied by
      # a history that never groups — which is the other half, and why
      # `LAW-H5`'s published killer names both mutations.
      var s = keystrokeRun(kind, NewGroupDelayMs + 1)
      counted s.history.undoDepth == Keystrokes
      var undone = 0
      while s.undo(): inc undone
      counted undone == Keystrokes
      counted s.doc == Ruler

  for k in UngroupedKinds:
    let kind = k

    test "grouping x " & $kind & " x INSIDE the window is still N events":
      # **THE KIND IS PART OF THE RULE.** A transaction the user did not
      # produce by typing never coalesces, however fast it arrived. Without
      # these two kinds the sweep would assert that grouping happens and never
      # that it is keyed on anything.
      var s = keystrokeRun(kind, 1)
      counted s.history.undoDepth == Keystrokes
      counted s.doc == Ruler & "xxxxx"

    test "grouping x " & $kind & " x SPANNING the window is N events":
      var s = keystrokeRun(kind, NewGroupDelayMs + 1)
      counted s.history.undoDepth == Keystrokes

# ===========================================================================
suite "PLAT-32 — grouping's boundary, its isolation annotation, and its bound":
# ===========================================================================

  test "AT the window exactly: a new event; one millisecond inside it: the same one":
    # The bound is a named constant so the assertion can be AT it and one past
    # it rather than somewhere plausible — PLAT-31's `M3` is the same rule for
    # the chord timeout.
    var atBound = initSession(Ruler)
    atBound.applyTransaction(
      localTransaction(atBound.doc, 16, 16, "a", ueInput, 1000))
    atBound.applyTransaction(
      localTransaction(atBound.doc, 17, 17, "b", ueInput,
                       1000 + NewGroupDelayMs))
    counted atBound.history.undoDepth == 2

    var inside = initSession(Ruler)
    inside.applyTransaction(
      localTransaction(inside.doc, 16, 16, "a", ueInput, 1000))
    inside.applyTransaction(
      localTransaction(inside.doc, 17, 17, "b", ueInput,
                       1000 + NewGroupDelayMs - 1))
    counted inside.history.undoDepth == 1

  test "two edits a page apart inside one window are TWO events":
    # `isAdjacent` is the other half of the rule. An undo that removed both
    # would remove an edit the user cannot see being removed.
    var s = initSession(Ruler)
    s.applyTransaction(localTransaction(s.doc, 0, 0, "A", ueInput, 1000))
    s.applyTransaction(localTransaction(s.doc, s.doc.len, s.doc.len, "B",
                                        ueInput, 1001))
    counted s.history.undoDepth == 2
    counted s.undo()
    counted s.doc == "A" & Ruler

  test "THE ISOLATION ANNOTATION, two-sidedly":
    # §13.1's *"explicit isolation annotation for a transaction that must not
    # merge with its neighbourS"* — both neighbours, which is why the arriving
    # transaction and the event it creates are both marked.
    var joined = initSession(Ruler)
    for i in 0 ..< 3:
      let at = joined.doc.len
      joined.applyTransaction(
        localTransaction(joined.doc, at, at, "x", ueInput, 1000 + int64(i)))
    counted joined.history.undoDepth == 1

    var isolated = initSession(Ruler)
    for i in 0 ..< 3:
      let at = isolated.doc.len
      var tr = localTransaction(isolated.doc, at, at, "x", ueInput,
                                1000 + int64(i))
      if i == 1:
        tr.annotations.add Annotation(kind: anGroupWithPrevious,
                                      groupWithPrevious: false)
      isolated.applyTransaction(tr)
    # The middle transaction merges with neither side: three events.
    counted isolated.history.undoDepth == 3
    counted isolatedOf(
      localTransaction(Ruler, 0, 0, "x", ueInput, 0)) == false

  test "an UNDO isolates: the next edit does not coalesce into a generated event":
    var s = initSession(Ruler)
    s.applyTransaction(localTransaction(s.doc, 16, 16, "a", ueInput, 1000))
    counted s.undo()
    s.applyTransaction(localTransaction(s.doc, 16, 16, "b", ueInput, 1001))
    # The redo branch is cleared by a new edit, and the new edit is its own
    # event rather than being merged into the undo's.
    counted s.history.undoDepth == 1
    counted s.history.redoDepth == 0
    counted s.doc == Ruler & "b"

  test "the branch is BOUNDED, and the bound is the published one":
    var s = initSession(Ruler)
    for i in 0 .. MaxHistoryDepth + 4:
      let at = s.doc.len
      s.applyTransaction(
        localTransaction(s.doc, at, at, "x", ueInput,
                         int64(i) * (NewGroupDelayMs + 1)))
    counted s.history.done.len == MaxHistoryDepth
    counted s.history.undoDepth == MaxHistoryDepth

# ===========================================================================
suite "PLAT-32 — the delivery-order matrix: 6 orders x 3 event shapes":
# ===========================================================================

  # **SIX IS `C(4,2)`, WHICH IS A CARDINALITY AND NOT A ROUND NUMBER**
  # (§10.4 rule 3): every way of placing two remote changes, in order, among
  # two local edits, in order.

  test "the delivery-order table is the whole set, and every row is distinct":
    let orders = deliveryOrders()
    counted orders.len == 6
    var ids: seq[string] = @[]
    for o in orders:
      counted o.slots.len == 4
      var locals = 0
      var remotes = 0
      for k in o.slots:
        if k == stLocal: inc locals else: inc remotes
      counted locals == 2
      counted remotes == 2
      counted o.id notin ids
      ids.add o.id
    counted ids.len == 6
    counted RemoteSiteCount == 3

  for o in deliveryOrders():
    for st in RemoteSite:
      let order = o
      let site = st

      test "delivery " & order.id & " x " & $site:
        # Landmarks are found by `find` at the moment of use, so a row's
        # positions are correct whatever arrived before it — which is the only
        # way six orders can share one script.
        var s = initSession(Ruler)
        var localsDone = 0
        var remotesDone = 0
        var t: int64 = 0
        for slot in order.slots:
          case slot
          of stLocal:
            inc localsDone
            t += NewGroupDelayMs * 4
            let mark = if localsDone == 1: "8" else: "c"
            let at = s.doc.find(mark)
            counted at >= 0
            s.applyTransaction(
              localTransaction(s.doc, at, at, "<" & $localsDone & ">",
                               ueInput, t))
          of stRemote:
            inc remotesDone
            let mark = case site
                       of rsBefore: "2"
                       of rsAtEdge: "8"
                       of rsAfter: "e"
            let at = s.doc.find(mark)
            counted at >= 0
            s.applyTransaction(
              remoteTransaction(s.doc, at, at, "<r" & $remotesDone & ">"))
          of stSelection: discard

        counted localsDone == 2
        counted remotesDone == 2
        counted s.history.undoDepth == 2

        # **UNDO MINE, NOT THEIRS.** Both local edits go; both remote edits
        # stay; what is left is the ruler with the two remote markers in it.
        var undone = 0
        while s.undo(): inc undone
        counted undone == 2
        counted not s.doc.contains("<1>")
        counted not s.doc.contains("<2>")
        counted s.doc.contains("<r1>")
        counted s.doc.contains("<r2>")
        counted s.doc.replace("<r1>", "").replace("<r2>", "") == Ruler

        # …and redo puts them back, in the rebased positions.
        var redone = 0
        while s.redo(): inc redone
        counted redone == 2
        counted s.doc.contains("<1>")
        counted s.doc.contains("<2>")
        counted s.doc.replace("<r1>", "").replace("<r2>", "")
                    .replace("<1>", "").replace("<2>", "") == Ruler

# ===========================================================================
suite "PLAT-32 — the selection-only event is a VARIANT ARM":
# ===========================================================================

  test "a selection change with an empty branch becomes a selection-only event":
    var s = initSession(Ruler)
    s.history = recordSelectionChange(s.history, caretSelection(3), 1000)
    counted s.history.done.len == 1
    counted s.history.done[0].kind == hekSelection
    counted s.history.done[0].selections == @[caretSelection(3)]
    # It is NOT an undoable step, which is what `undoDepth` subtracts.
    counted s.history.undoDepth == 0

  test "a selection change above an event hangs off that event":
    var s = initSession(Ruler)
    s.applyTransaction(localTransaction(s.doc, 16, 16, "a", ueInput, 1000))
    s.history = recordSelectionChange(s.history, caretSelection(3),
                                      1000 + NewGroupDelayMs * 4)
    counted s.history.done.len == 1
    counted s.history.done[0].kind == hekChange
    counted s.history.done[0].selectionsAfter == @[caretSelection(3)]

  test "undo-selection restores the selection and leaves the document alone":
    var s = initSession(Ruler)
    s.applyTransaction(localTransaction(s.doc, 16, 16, "a", ueInput, 1000))
    let doc0 = s.doc
    s.selection = caretSelection(3)
    s.history = recordSelectionChange(s.history, caretSelection(3),
                                      1000 + NewGroupDelayMs * 4)
    s.selection = caretSelection(9)
    counted s.undoSelection()
    counted s.selection == caretSelection(3)
    counted s.doc == doc0

  test "redo-selection walks it forward again":
    var s = initSession(Ruler)
    s.applyTransaction(localTransaction(s.doc, 16, 16, "a", ueInput, 1000))
    s.selection = caretSelection(3)
    s.history = recordSelectionChange(s.history, caretSelection(3),
                                      1000 + NewGroupDelayMs * 4)
    s.selection = caretSelection(9)
    counted s.undoSelection()
    counted s.selection == caretSelection(3)
    counted s.redoSelection()
    counted s.selection == caretSelection(9)

  test "A SELECTION RECORDED PAST SOMEBODY ELSE'S EDIT COMES BACK IN THE RIGHT COORDINATES":
    # The half of `undo-selection` that only a remote writer can break: the
    # selections hanging off an event are expressed against the document ABOVE
    # it, and a remote change moves that document WITHOUT adding an event. This
    # is PLAT-30's `FUZZ-8` class — *"a range recorded against a longer document
    # handed back in a shorter one"* — arriving by the one route the event
    # history leaves open.
    var s = initSession(Ruler)
    s.applyTransaction(localTransaction(s.doc, 16, 16, "a", ueInput, 1000))
    s.selection = caretSelection(9)
    s.history = recordSelectionChange(s.history, caretSelection(9),
                                      1000 + NewGroupDelayMs * 4)
    s.selection = caretSelection(2)
    # Somebody else inserts three bytes before the recorded caret.
    s.applyTransaction(remoteTransaction(s.doc, 0, 0, "<R>"))
    counted s.undoSelection()
    # 9 + 3: the recorded caret names the same TEXT it named, which is the
    # claim, and it is asserted as an offset because a caret that names
    # different text is still a valid caret.
    counted s.selection == caretSelection(12)
    counted s.doc == "<R>" & Ruler & "a"

  test "AN ISOLATED SELECTION-ONLY TRANSACTION IS NOT DEDUPED AGAINST ITS PREDECESSOR":
    # `recordSelectionChange` drops a same-shape selection change that arrives
    # inside the window, so a caret sweeping a line is one entry and not forty.
    # The isolation annotation is what says "record this one anyway", and it is
    # the ONE behaviour that reads `HistoryState.isolate` — without this case
    # that routine is a line no assertion observes, which is how an arm that
    # deletes it comes back SURVIVED.
    proc selectionTr(doc: string; to: int; ms: int64;
                     isolated: bool): Transaction =
      result = transaction(identityChangeSet(doc.len), some(caretSelection(to)),
                           @[], @[Annotation(kind: anUserEvent,
                                             userEvent: ueSelect),
                                  Annotation(kind: anTime, timeMs: ms)])
      if isolated:
        result.annotations.add Annotation(kind: anGroupWithPrevious,
                                          groupWithPrevious: false)

    var deduped = initSession(Ruler)
    deduped.selection = caretSelection(3)
    deduped.applyTransaction(selectionTr(deduped.doc, 5, 10_000, false))
    deduped.applyTransaction(selectionTr(deduped.doc, 7, 10_001, false))
    counted deduped.history.done.len == 1
    counted deduped.history.done[0].selections.len == 1

    var kept = initSession(Ruler)
    kept.selection = caretSelection(3)
    kept.applyTransaction(selectionTr(kept.doc, 5, 10_000, false))
    kept.applyTransaction(selectionTr(kept.doc, 7, 10_001, true))
    counted kept.history.done.len == 1
    counted kept.history.done[0].selections.len == 2

  test "a selection-only event REFUSES a document undo rather than skipping past it":
    # The invariant the reference carries in a comment — *"they are always the
    # last event in a branch"* — with nothing enforcing it. Here the arm is a
    # different constructor, and `pop` answers `none` rather than walking down
    # to the event below and undoing a change nobody asked about.
    var s = initSession(Ruler)
    s.history = recordSelectionChange(s.history, caretSelection(3), 1000)
    counted not s.undo()
    counted s.doc == Ruler
    counted popUndo(s.history, s.doc, s.selection).isNone

  test "the two arms are a VARIANT, so a change-less event has no change set":
    # §13.1's *"which in Nim is a variant arm, not a nullable field carrying an
    # invariant that nothing enforces"* — asserted by the compiler, which is
    # the only thing that can assert it.
    let sel = selectionEvent(@[caretSelection(0)])
    counted sel.kind == hekSelection
    # **THE COMPILER REFUSES TO BUILD THE MIXED SHAPE**, which is the half a
    # nullable field cannot have: an event carrying selections AND a change set
    # is not a value that exists.
    counted not compiles(HistEvent(kind: hekSelection,
                                   changes: identityChangeSet(0)))
    counted not compiles(HistEvent(kind: hekChange,
                                   selections: @[caretSelection(0)]))
    # …and READING the wrong arm is a typed runtime refusal rather than a zero
    # value. Nim's variant field access compiles and checks at run time, which
    # is measured here rather than assumed — the first spelling of this case
    # asserted `not compiles(sel.changes)` and was WRONG.
    var wrongArm = false
    try:
      discard sel.changes.length
    except FieldDefect:
      wrongArm = true
    counted wrongArm
    # …and the twin, so the refusals above are not satisfied by a type nobody
    # can use at all.
    let ch = eventFromTransaction(
      localTransaction(Ruler, 0, 0, "a", ueInput, 0), Ruler, caretSelection(0))
    counted ch.isSome
    counted ch.get.kind == hekChange
    counted ch.get.changes.length > 0

# ===========================================================================
suite "PLAT-32 — the rebased redo POSITION":
# ===========================================================================

  # The milestone's gate: *"redo after undo after a remote edit restores the
  # local edit at its REBASED position, asserted as a position rather than as a
  # document equality, because two wrong rebases can produce the same
  # document."* Three remote sites, and two arrival orders each — before the
  # undo and after it — because the undone event and the undone-branch event
  # are mapped by two different calls.

  for st in RemoteSite:
    for afterUndo in [false, true]:
      let site = st
      let late = afterUndo

      test "rebased redo x " & $site &
           (if late: " x remote AFTER the undo" else: " x remote BEFORE the undo"):
        var s = initSession(Ruler)
        let localAt = s.doc.find("8")
        counted localAt == 8
        s.applyTransaction(
          localTransaction(s.doc, localAt, localAt, "<L>", ueInput, 1000))
        counted s.doc == "01234567<L>89abcdef"

        let remoteMark = case site
                         of rsBefore: "2"
                         of rsAtEdge: "8"
                         of rsAfter: "e"

        proc deliverRemote(sess: var HistorySession) =
          let at = sess.doc.find(remoteMark)
          sess.applyTransaction(remoteTransaction(sess.doc, at, at, "<R>"))

        if not late: deliverRemote(s)
        # Where the local edit sits at the moment the undo is taken. Every
        # expectation below is derived from THIS measurement rather than from
        # the final document, so the assertion cannot be satisfied by reading
        # the answer back out of the thing under test.
        let posBeforeUndo = s.doc.find("<L>")
        counted posBeforeUndo >= 0
        counted s.undo()
        var shift = 0
        if late:
          deliverRemote(s)
          # A remote insertion at or before the local edit's offset moves it by
          # exactly its own width; one after it does not move it at all.
          if s.doc.find("<R>") <= posBeforeUndo: shift = "<R>".len
        counted not s.doc.contains("<L>")
        counted s.doc.contains("<R>")

        counted s.redo()
        # **THE POSITION, NOT THE DOCUMENT.** *"Two wrong rebases can produce
        # the same document"*, so what is asserted is the OFFSET the local edit
        # comes back at: the offset it held before the undo, moved by exactly
        # the remote text that arrived afterwards and landed at or before it.
        counted s.doc.find("<L>") == posBeforeUndo + shift
        counted s.doc.contains("<R>")
        # And the document, which is the assertion this one is not.
        counted s.doc.replace("<R>", "") == "01234567<L>89abcdef"

# ===========================================================================
suite "PLAT-32 — the verification gate: UNDO MINE, NOT THEIRS":
# ===========================================================================

  test "THE GATE: remote edits survive an undo of the local one":
    var s = initSession("hello world")
    s.applyTransaction(localTransaction(s.doc, 5, 5, "LOCAL", ueInput, 1000))
    s.applyTransaction(remoteTransaction(s.doc, 0, 0, "R1"))
    s.applyTransaction(
      remoteTransaction(s.doc, s.doc.len, s.doc.len, "R2"))
    counted s.doc == "R1helloLOCAL worldR2"
    counted s.undo()
    counted s.doc == "R1hello worldR2"
    counted not s.doc.contains("LOCAL")
    counted s.doc.contains("R1")
    counted s.doc.contains("R2")

  test "THE NEGATIVE CONTROL: the same case with NO remote edit":
    # §7b — *"an unfalsified negative control is a self-comparison wearing a
    # negation."* A stack that ignores remote edits entirely passes the gate
    # above for the wrong reason, so the same script runs with the two remote
    # transactions removed and the ANSWER MUST DIFFER: the document after the
    # undo is the start document, not the start document with two markers in
    # it. The two are asserted against each other rather than each against a
    # constant.
    var withRemote = initSession("hello world")
    withRemote.applyTransaction(
      localTransaction(withRemote.doc, 5, 5, "LOCAL", ueInput, 1000))
    withRemote.applyTransaction(remoteTransaction(withRemote.doc, 0, 0, "R1"))
    withRemote.applyTransaction(
      remoteTransaction(withRemote.doc, withRemote.doc.len,
                        withRemote.doc.len, "R2"))
    counted withRemote.undo()

    var without = initSession("hello world")
    without.applyTransaction(
      localTransaction(without.doc, 5, 5, "LOCAL", ueInput, 1000))
    counted without.undo()
    counted without.doc == "hello world"
    counted withRemote.doc != without.doc
    counted withRemote.doc.len == without.doc.len + 4

  test "typing, pausing past the window, typing again, and undoing: TWO events":
    # The milestone's second real-stack integration test, in its own words —
    # *"asserting two events rather than one or thirty"*.
    var s = initSession("")
    for i in 0 ..< 10:
      let at = s.doc.len
      s.applyTransaction(localTransaction(s.doc, at, at, "a", ueInput,
                                          1000 + int64(i)))
    for i in 0 ..< 10:
      let at = s.doc.len
      s.applyTransaction(
        localTransaction(s.doc, at, at, "b", ueInput,
                         1000 + NewGroupDelayMs * 3 + int64(i)))
    counted s.doc == "aaaaaaaaaabbbbbbbbbb"
    counted s.history.undoDepth == 2
    counted s.undo()
    counted s.doc == "aaaaaaaaaa"
    counted s.undo()
    counted s.doc == ""
    counted not s.undo()

  test "record REFUSES an undo transaction, by name":
    # An undo routed through `record` would push a second event onto `done` and
    # both branches would grow on every undo — a VALID history whose depth is
    # wrong, which is §36's shape and the reason this is a raise rather than a
    # silent branch.
    var raised = false
    try:
      discard record(initHistory(),
        transaction(changeSet(Ruler.len, 0, 0, "x"), none(EditorSelection), @[],
                    @[Annotation(kind: anUserEvent, userEvent: ueUndo)]),
        Ruler, caretSelection(0))
    except HistoryError:
      raised = true
    counted raised

  test "a remote transaction with an IDENTITY change set changes nothing":
    # The degenerate arm of `LAW-H3`, pinned because it is the one input for
    # which "push the description into both branches" has nothing to push.
    var s = initSession(Ruler)
    s.applyTransaction(localTransaction(s.doc, 16, 16, "a", ueInput, 1000))
    let before = s.history
    s.applyTransaction(
      transaction(identityChangeSet(s.doc.len), none(EditorSelection), @[],
                  @[Annotation(kind: anRemote, peer: "p")]))
    counted s.history == before

  test "the peer is carried and is not what decides anything":
    # The peer is read off the annotation `transaction.nim` already declares,
    # not through an accessor in `history.nim`. There was one; it had no
    # product caller and no caller but this line, which is dead code rather
    # than a backlog item (`ci/test/frontend-reachability.sh`'s own
    # distinction), so it was deleted rather than ratcheted past.
    var peer = ""
    for a in remoteTransaction(Ruler, 0, 0, "x", "alice").annotations:
      if a.kind == anRemote: peer = a.peer
    counted peer == "alice"
    counted isRemote(remoteTransaction(Ruler, 0, 0, "x", "alice"))
    counted not isRemote(localTransaction(Ruler, 0, 0, "x", ueInput, 0))
    # `addToHistory: false` is the OTHER route to the same branch, and it is
    # driven so the two are not one path with two names.
    var tr = localTransaction(Ruler, 0, 0, "x", ueInput, 0)
    tr.annotations.add Annotation(kind: anAddToHistory, addToHistory: false)
    counted not addToHistory(tr)
    var s = initSession(Ruler)
    s.applyTransaction(tr)
    counted s.history.undoDepth == 0
    counted s.doc == "x" & Ruler

  test "the groupable kinds are a closed, enumerable set":
    # `card` and not a hand-written counter in `history.nim`: the set's
    # cardinality is a language primitive, and a routine that re-derives one is
    # §30a's re-derivation at its smallest — and was reached by nothing but
    # this line.
    counted card(GroupableEvents) == GroupedKinds.len
    counted GroupedKinds.len + UngroupedKinds.len == GroupingKinds
    for k in GroupedKinds: counted k in GroupableEvents
    for k in UngroupedKinds: counted k notin GroupableEvents
    counted ueUndo notin GroupableEvents
    counted ueRedo notin GroupableEvents

# ===========================================================================
suite "PLAT-32 — the four published operations, over the event history":
# ===========================================================================

  # PLAT-30 made `undo`, `redo`, `undo-selection` and `redo-selection`
  # executable over a SNAPSHOT STACK and said so in `editor_state.nim`'s
  # header. This milestone replaced the stack; these cases are what says the
  # four are still four, reached the way the vocabulary reaches them — BY NAME
  # through `applyOperation`, never by synthesising a keystroke.

  let settings = wrapSettings(80)

  proc typed(st: EditorState; text: string; nowMs: int64): EditorState =
    applyOperation(st, "insert-text", OpArgs(text: text), settings, 20,
                   nowMs).state

  test "VOCAB undo and redo walk the event history":
    var st = initEditorState(Ruler)
    st = typed(st, "A", 1000)
    st = typed(st, "B", 1000 + NewGroupDelayMs * 4)
    counted st.history.undoDepth == 2
    let r1 = applyOperation(st, "undo", OpArgs(), settings)
    counted r1.outcome == ooActed
    counted r1.state.doc == "A" & Ruler
    let r2 = applyOperation(r1.state, "undo", OpArgs(), settings)
    counted r2.state.doc == Ruler
    let r3 = applyOperation(r2.state, "redo", OpArgs(), settings)
    counted r3.state.doc == "A" & Ruler

  test "VOCAB undo REFUSES on an empty history, by name":
    let st = initEditorState(Ruler)
    let r = applyOperation(st, "undo", OpArgs(), settings)
    counted r.outcome == ooRefused
    counted r.refusal == rrEmptyHistory
    let r2 = applyOperation(st, "redo", OpArgs(), settings)
    counted r2.refusal == rrEmptyHistory

  test "VOCAB undo-selection is a SELECTION walk and moves no text":
    # It shares the `done` branch with `undo` now instead of owning a second
    # stack. The claim that survived the change is the one PLAT-30 made when it
    # kept them apart: *"two of the four would be unreachable"* — they are not.
    var st = initEditorState(Ruler)
    st = typed(st, "A", 1000)
    let doc0 = st.doc
    let moved = applyOperation(st, "select-all", OpArgs(), settings).state
    counted moved.selection != st.selection
    let r = applyOperation(moved, "undo-selection", OpArgs(), settings)
    counted r.outcome == ooActed
    counted r.state.doc == doc0
    counted r.state.selection == st.selection
    counted r.state.history.undoDepth == moved.history.undoDepth

  test "VOCAB redo-selection walks it forward, and the document never moves":
    var st = initEditorState(Ruler)
    st = typed(st, "A", 1000)
    let moved = applyOperation(st, "select-all", OpArgs(), settings).state
    let undone = applyOperation(moved, "undo-selection", OpArgs(),
                                settings).state
    let redone = applyOperation(undone, "redo-selection", OpArgs(), settings)
    counted redone.outcome == ooActed
    counted redone.state.selection == moved.selection
    counted redone.state.doc == moved.doc

  test "VOCAB an edit through the vocabulary GROUPS by the published rule":
    # The clock reaches the operation through `OpEnv`, not through a call to
    # one — which is what keeps every operation a pure function of its
    # arguments and inside PLAT-29's import-closure gate.
    var inside = initEditorState("")
    for i in 0 ..< Keystrokes:
      inside = typed(inside, "x", 1000 + int64(i))
    counted inside.history.undoDepth == 1
    var spanning = initEditorState("")
    for i in 0 ..< Keystrokes:
      spanning = typed(spanning, "x", 1000 + NewGroupDelayMs * int64(i + 1) * 2)
    counted spanning.history.undoDepth == Keystrokes
    counted inside.doc == spanning.doc

  test "VOCAB the snapshot stack is GONE, not kept beside the history":
    # A snapshot stack that survived the milestone meant to remove it would be
    # a second history for the same four operations to disagree about. The
    # compiler is the only thing that can assert an absence.
    let st = initEditorState(Ruler)
    counted not compiles(st.undoStack)
    counted not compiles(st.redoStack)
    counted not compiles(st.selUndo)
    counted not compiles(st.selRedo)
    counted compiles(st.history)

# ===========================================================================
suite "PLAT-32 — the tally":
# ===========================================================================
  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
