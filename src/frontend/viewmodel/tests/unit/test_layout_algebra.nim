## SDK-CONSUMER: the layout command algebra belongs to the shell, not to the
## SDK, for the reason `test_layout_model.nim`'s header gives — arranging
## panes is the embedder's job, and this suite needs nothing from the facade.
##
## test_layout_algebra.nim
##
## PLAT-4 (CodeTracer-Platform.milestones.org) / Layout-ViewModel §2, §3, §3A,
## §6, §7.
##
## ## NO MOCKS, AND NOTHING TO JUSTIFY
##
## The workspace policy asks every use of a mock object to be justified in a
## test file's header. **This file uses none**, and it is worth saying why
## there is nothing to justify rather than leaving the absence to be inferred:
## the subject is a pure value transformation over a data structure. `apply`
## reads a `Layout` and returns a `LayoutOutcome`; it opens no file, spawns no
## process, and reaches no renderer, no engine and no clock. There is no
## boundary here that a mock could stand in for, which is the same property
## that makes the model worth having.
##
## ## WHAT THIS SUITE IS FOR
##
## Four claims, in the milestone's own order:
##
##   1. **Every command against every structural shape**, with refusals
##      asserted AS REFUSALS — by `problem.kind` — rather than as "it did not
##      crash". A refusal that is only checked for `!= loApplied` passes
##      whether the model refused for the right reason or the wrong one.
##   2. **A pane in the tree AND in `docked` fails `validate`** — §3.3's
##      invariant, the one that makes `allPanes` still mean what it says.
##   3. **Round trip including docked panes**, which the format could not
##      express at all before this milestone.
##   4. **`revealed` is not persisted.** A restore that reopened overlays is a
##      defect, and the assertion is written so that it fails if `toJson` ever
##      starts writing the field.
##
## ## TRAP 13 (Verification-Harness-Traps §13)
##
## `unittest.check` inside a plain `proc` assigns a MODULE-LEVEL
## `testStatusIMPL` and leaves the running test's own status untouched — the
## test prints its failed comparison and still reports `[OK]`. **Every
## assertion helper in this file is a `template`**, which expands in the test
## body where `testStatusIMPL` is the test's own. `grep -n 'proc ' ` over this
## file should find no `check` inside any of them; there are no assertion
## `proc`s at all.
##
## Compile and run:
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_layout_algebra.nim
##   nim js -d:nodejs -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_layout_algebra.nim

import std/[json, options, sets, strutils, unittest]

import headless_app/layout_model
import headless_app/window_set

# ---------------------------------------------------------------------------
# Assertion helpers. TEMPLATES, NOT PROCS — see the header, trap 13.
# ---------------------------------------------------------------------------

template checkRefused(outcome: LayoutOutcome; expected: LayoutProblemKind) =
  ## A refusal asserted as a refusal: the outcome kind AND the reason. The
  ## milestone asks for exactly this, because `outcome.kind != loApplied` is
  ## satisfied by a no-op and by a refusal for an unrelated reason.
  let o = outcome
  checkpoint("outcome was: " & $o)
  check o.kind == loRefused
  if o.kind == loRefused:
    check o.problem.kind == expected

template checkNoOp(outcome: LayoutOutcome) =
  let o = outcome
  checkpoint("outcome was: " & $o)
  check o.kind == loNoOp

template checkApplied(outcome: LayoutOutcome) =
  let o = outcome
  checkpoint("outcome was: " & $o)
  check o.kind == loApplied

template checkValid(l: Layout) =
  let v = l
  let problems = validate(v)
  var kinds: seq[string] = @[]
  for p in problems:
    kinds.add($p.kind & "@'" & p.path & "'")
  checkpoint("layout: " & $v & " problems: " & kinds.join(", "))
  check problems.len == 0

# ---------------------------------------------------------------------------
# Fixtures. Plain constructors over the real model — no builders, no fakes.
# ---------------------------------------------------------------------------

proc collectNodes(n: LayoutNode; acc: var seq[LayoutNode]) =
  ## Every node of a tree, as refs, for identity comparison. A `proc` rather
  ## than a `template` is correct here and not an exception to the header's
  ## trap-13 rule: the rule is about helpers containing `check`, and this one
  ## contains none — it collects, and the test does the asserting.
  if n.isNil:
    return
  acc.add(n)
  for c in n.children:
    collectNodes(c, acc)

proc twoPaneRow(): Layout =
  initLayout(row([pane(paneEditor, "Editor", weight = 3.0),
                  pane(paneState, "State", weight = 1.0)]))

proc stackedLayout(): Layout =
  ## A row whose right half is a two-tab stack: the shape every tab command
  ## needs and the one the default replay layout has.
  initLayout(row([
    pane(paneEditor, "Editor", weight = 3.0),
    stack([pane(paneState, "State"), pane(paneEventLog, "Event Log")],
          activeIndex = 0, weight = 1.0)]))

proc twoStacks(): Layout =
  initLayout(row([
    stack([pane(paneEditor, "Editor"), pane(paneFlow, "Flow")],
          activeIndex = 0, weight = 2.0),
    stack([pane(paneState, "State"), pane(paneEventLog, "Event Log")],
          activeIndex = 0, weight = 1.0)]))

proc deepTree(): Layout =
  initLayout(column([
    pane(paneDebugControls, "Controls", weight = 1.0),
    row([
      pane(paneEditor, "Editor", weight = 3.0),
      column([
        pane(paneCalltrace, "Call Trace", weight = 1.0),
        stack([pane(paneState, "State"), pane(paneEventLog, "Event Log")],
              activeIndex = 0, weight = 1.0)],
        weight = 2.0)],
      weight = 9.0)]))

const AllShapes = ["bare pane", "two-pane row", "stacked", "two stacks",
                   "deep tree"]

proc shape(name: string): Layout =
  case name
  of "bare pane": initLayout(pane(paneEditor, "Editor"))
  of "two-pane row": twoPaneRow()
  of "stacked": stackedLayout()
  of "two stacks": twoStacks()
  of "deep tree": deepTree()
  else: initLayout(nil)

# ---------------------------------------------------------------------------
# §2.1 — purity
# ---------------------------------------------------------------------------

suite "Layout algebra — apply never mutates its argument":

  test "every command leaves the input layout byte-identical":
    # The property the whole design rests on: undo is a replay of a command
    # log ONLY because replaying from the same start reaches the same place.
    # A single in-place mutation anywhere in `apply` breaks that silently,
    # and this is the check that would not let it.
    let commands = @[
      cmdActivateTab(paneEventLog),
      cmdSetWeight(paneEditor, 9.0),
      cmdAddPane(paneShell, "Shell"),
      cmdRemovePane(paneCalltrace),
      cmdMoveTab(paneEditor, paneState, 0),
      cmdSplit(paneEditor, paneScratchpad, saColumn),
      cmdMergeIntoStack(paneEditor, paneState),
      cmdDock(paneEditor, leBottom),
      cmdRestoreDocked(paneShell),
      cmdRename(paneEditor, "Renamed")]
    for name in AllShapes:
      for cmd in commands:
        let before = shape(name)
        let printed = $before
        discard apply(before, cmd)
        checkpoint(name & " / " & $cmd)
        check $before == printed
        check $before.tree == printed.split(" +docked")[0]

  test "the outcome's layout does not alias the input's tree":
    let before = stackedLayout()
    let outcome = apply(before, cmdRename(paneEditor, "Changed"))
    check outcome.kind == loApplied
    if outcome.kind == loApplied:
      # Mutating the RESULT must not reach back into the input. If `apply`
      # returned the same refs, this assignment would change `before` too.
      outcome.layout.tree.find(paneEditor).title = "Mutated"
      check before.tree.find(paneEditor).title == "Editor"

  test "the result shares NO node object with the input, on any command":
    # The case above catches "apply returned the same tree". It does NOT catch
    # a result that shares a SUBTREE, which is the subtler aliasing bug —
    # `copyOf` in this module is deliberately shallow (`children: n.children`),
    # so shared substructure is a thing the implementation could produce. Node
    # identity is compared with `==` on the refs rather than a cast, so this
    # means the same thing on the C and the JS backend.
    let commands = @[
      cmdActivateTab(paneEventLog), cmdSetWeight(paneEditor, 9.0),
      cmdAddPane(paneShell, "Shell"), cmdRemovePane(paneCalltrace),
      cmdMoveTab(paneEditor, paneState, 0),
      cmdSplit(paneEditor, paneScratchpad, saColumn),
      cmdMergeIntoStack(paneEditor, paneState),
      cmdDock(paneEditor, leBottom), cmdRestoreDocked(paneShell),
      cmdRename(paneEditor, "Renamed")]
    var appliedArms = 0
    for name in AllShapes:
      for cmd in commands:
        let before = shape(name)
        var inputNodes: seq[LayoutNode] = @[]
        collectNodes(before.tree, inputNodes)
        let o = apply(before, cmd)
        if o.kind != loApplied:
          continue
        inc appliedArms
        var outNodes: seq[LayoutNode] = @[]
        collectNodes(o.layout.tree, outNodes)
        var shared = 0
        for a in inputNodes:
          for b in outNodes:
            if a == b:
              inc shared
        checkpoint(name & " / " & $cmd & " shared nodes: " & $shared)
        check shared == 0
    # Positive control (Verification-Harness-Traps §4b): a sweep in which
    # nothing APPLIED asserts nothing at all, and the membership here is
    # knowable — so assert the COUNT, not that it is non-zero.
    checkpoint("arms that applied: " & $appliedArms)
    check appliedArms == 35

# ---------------------------------------------------------------------------
# §2.2 / §2.3 — every command against every shape
# ---------------------------------------------------------------------------

suite "Layout algebra — activate":

  test "activating a hidden tab applies; activating a visible one is a no-op":
    let l = stackedLayout()
    checkNoOp apply(l, cmdActivateTab(paneState))
    let o = apply(l, cmdActivateTab(paneEventLog))
    checkApplied o
    if o.kind == loApplied:
      check o.layout.tree.isVisible(paneEventLog)
      check not o.layout.tree.isVisible(paneState)

  test "activating an absent pane is refused by kind, on every shape":
    for name in AllShapes:
      checkpoint(name)
      checkRefused apply(shape(name), cmdActivateTab(paneScratchpad)),
                   lpPaneNotPlaced

  test "a docked pane cannot be activated — it has no region to become visible in":
    let docked = apply(stackedLayout(), cmdDock(paneEventLog, leBottom))
    checkApplied docked
    if docked.kind == loApplied:
      checkRefused apply(docked.layout, cmdActivateTab(paneEventLog)),
                   lpPaneNotPlaced

suite "Layout algebra — set weight":

  test "a new weight applies; the same weight is a no-op":
    let l = twoPaneRow()
    checkNoOp apply(l, cmdSetWeight(paneEditor, 3.0))
    let o = apply(l, cmdSetWeight(paneEditor, 5.0))
    checkApplied o
    if o.kind == loApplied:
      check o.layout.tree.find(paneEditor).weight == 5.0

  test "a negative share is refused by kind rather than stored":
    for name in AllShapes:
      checkpoint(name)
      checkRefused apply(shape(name), cmdSetWeight(paneEditor, -0.5)),
                   lpNegativeWeight

  test "weighting an absent pane is refused by kind":
    checkRefused apply(twoPaneRow(), cmdSetWeight(paneShell, 1.0)),
                 lpPaneNotPlaced

suite "Layout algebra — add and remove":

  test "adding into the root container applies on every container shape":
    for name in AllShapes:
      let before = shape(name)
      let o = apply(before, cmdAddPane(paneShell, "Shell"))
      checkpoint(name & ": " & $o)
      checkApplied o
      if o.kind == loApplied:
        check o.layout.tree.contains(paneShell)
        checkValid o.layout

  test "adding beside a pane lands in that pane's own container":
    let o = apply(deepTree(), cmdAddPane(paneShell, "Shell",
                                         after = some(paneCalltrace)))
    checkApplied o
    if o.kind == loApplied:
      let leaf = o.layout.tree.find(paneShell)
      let holder = parentOf(o.layout.tree, leaf)
      check not holder.isNil
      check holder.kind == lnColumn
      check holder.contains(paneCalltrace)

  test "adding beside a pane of a STACK makes it a tab and selects it":
    let o = apply(stackedLayout(), cmdAddPane(paneShell, "Shell",
                                              after = some(paneState)))
    checkApplied o
    if o.kind == loApplied:
      let holder = parentOf(o.layout.tree, o.layout.tree.find(paneShell))
      check holder.kind == lnStack
      check o.layout.tree.isVisible(paneShell)

  test "a bare-pane root is wrapped rather than refused":
    # "There is nowhere to put it" is not an answer a user can act on.
    let o = apply(initLayout(pane(paneEditor, "Editor")),
                  cmdAddPane(paneState, "State"))
    checkApplied o
    if o.kind == loApplied:
      check o.layout.tree.kind == lnRow
      check o.layout.tree.allPanes() == @[paneEditor, paneState]

  test "adding a pane that is already placed is refused by kind":
    for name in AllShapes:
      checkpoint(name)
      checkRefused apply(shape(name), cmdAddPane(paneEditor)), lpDuplicatePane

  test "adding a pane that is DOCKED is refused as both-placed-and-docked":
    let docked = apply(stackedLayout(), cmdDock(paneEventLog, leBottom))
    checkApplied docked
    if docked.kind == loApplied:
      checkRefused apply(docked.layout, cmdAddPane(paneEventLog)),
                   lpPaneBothPlacedAndDocked

  test "adding beside an absent anchor is refused by kind":
    checkRefused apply(twoPaneRow(), cmdAddPane(paneShell, "",
                                                after = some(paneScratchpad))),
                 lpPaneNotPlaced

  test "removing applies on every shape that has more than one pane":
    var removable = 0
    for name in AllShapes:
      let before = shape(name)
      if before.tree.allPanes().len <= 1:
        continue
      inc removable
      let o = apply(before, cmdRemovePane(paneEditor))
      checkpoint(name & ": " & $o)
      checkApplied o
      if o.kind == loApplied:
        check not o.layout.tree.contains(paneEditor)
        checkValid o.layout
    # The `continue` above is a silent skip, and a skip that shrank to every
    # shape would leave this case asserting nothing while staying green
    # (Verification-Harness-Traps §4b). The membership is knowable — four of
    # the five shapes have more than one pane — so assert the COUNT.
    checkpoint("shapes with more than one pane: " & $removable)
    check removable == 4

  test "removing an absent pane is refused by kind":
    for name in AllShapes:
      checkpoint(name)
      checkRefused apply(shape(name), cmdRemovePane(paneScratchpad)),
                   lpPaneNotPlaced

  test "removing the last pane is refused as an empty root, not performed":
    # §2.4 rule 3. There is no valid layout with no panes.
    checkRefused apply(initLayout(pane(paneEditor)),
                       cmdRemovePane(paneEditor)), lpEmptyRoot

# ---------------------------------------------------------------------------
# §2.4 — the collapse rules
# ---------------------------------------------------------------------------

suite "Layout algebra — collapse rules (§2.4)":

  test "rule 1: a row left with one child is replaced by that child":
    let l = initLayout(row([pane(paneEditor, weight = 2.0),
                            column([pane(paneState), pane(paneCalltrace)],
                                   weight = 1.0)]))
    let o = apply(l, cmdRemovePane(paneEditor))
    checkApplied o
    if o.kind == loApplied:
      # The column is now the ROOT: the row that held it has one child and is
      # not a layout, it is a hole in the tree.
      check o.layout.tree.kind == lnColumn
      checkValid o.layout

  test "rule 1 does not apply to a stack — one tab is an arrangement":
    let l = initLayout(row([
      pane(paneEditor, weight = 1.0),
      stack([pane(paneState), pane(paneEventLog)], weight = 1.0)]))
    let o = apply(l, cmdRemovePane(paneEventLog))
    checkApplied o
    if o.kind == loApplied:
      let holder = parentOf(o.layout.tree, o.layout.tree.find(paneState))
      check not holder.isNil
      check holder.kind == lnStack
      check holder.children.len == 1

  test "rule 2: an emptied container is removed, recursively, up to the root":
    let l = initLayout(row([
      pane(paneEditor, weight = 1.0),
      column([row([column([pane(paneState)])])], weight = 1.0)]))
    let o = apply(l, cmdRemovePane(paneState))
    checkApplied o
    if o.kind == loApplied:
      # Three nested containers held nothing but that pane; all three go, and
      # rule 1 then collapses the row onto the editor.
      check o.layout.tree.kind == lnPane
      check o.layout.tree.pane == paneEditor

  test "rule 3: a root that would become empty is refused, not emptied":
    checkRefused apply(initLayout(stack([pane(paneEditor)])),
                       cmdRemovePane(paneEditor)), lpEmptyRoot

  test "rule 4: surviving siblings are renormalised to the same total":
    # row(3, 1, 1) with the middle removed keeps its total of 5, so a weight
    # read out of a saved layout still means the same fraction after an edit.
    let l = initLayout(row([pane(paneEditor, weight = 3.0),
                            pane(paneState, weight = 1.0),
                            pane(paneCalltrace, weight = 1.0)]))
    let o = apply(l, cmdRemovePane(paneState))
    checkApplied o
    if o.kind == loApplied:
      let a = o.layout.tree.find(paneEditor).weight
      let b = o.layout.tree.find(paneCalltrace).weight
      check abs(a + b - 5.0) < 1e-9
      check abs(a - 3.75) < 1e-9
      check abs(b - 1.25) < 1e-9

  test "rule 4 leaves an all-implicit container alone":
    # Every weight `0` means "equal share"; scaling would materialise an
    # arbitrary number into a persisted document for no visible change.
    let l = initLayout(row([pane(paneEditor), pane(paneState),
                            pane(paneCalltrace)]))
    let o = apply(l, cmdRemovePane(paneState))
    checkApplied o
    if o.kind == loApplied:
      check o.layout.tree.find(paneEditor).weight == 0.0
      check o.layout.tree.find(paneCalltrace).weight == 0.0

  test "rule 1's survivor inherits the collapsed container's share":
    let l = initLayout(column([
      pane(paneDebugControls, weight = 1.0),
      row([pane(paneEditor, weight = 7.0), pane(paneState, weight = 2.0)],
          weight = 9.0)]))
    let o = apply(l, cmdRemovePane(paneState))
    checkApplied o
    if o.kind == loApplied:
      # The editor takes the row's 9.0, because 9.0 is what the COLUMN knew
      # about and the column is not being changed.
      check o.layout.tree.find(paneEditor).weight == 9.0

# ---------------------------------------------------------------------------
# Move tab / split / merge — the three gestures GoldenLayout has and this
# model never had.
# ---------------------------------------------------------------------------

suite "Layout algebra — move tab":

  test "moving between two stacks applies and lands at the index":
    let o = apply(twoStacks(), cmdMoveTab(paneFlow, paneState, 0))
    checkApplied o
    if o.kind == loApplied:
      let holder = parentOf(o.layout.tree, o.layout.tree.find(paneFlow))
      check holder.kind == lnStack
      check holder.children[0].pane == paneFlow
      check holder.contains(paneState)
      checkValid o.layout

  test "moving a tab to where it already is pushes NO undo entry":
    # §2.3's whole reason for `loNoOp` being distinct from `loApplied`.
    var h = newLayoutHistory(twoStacks())
    let at = 0
    checkNoOp h.dispatch(cmdMoveTab(paneEditor, paneFlow, at))
    check h.log.len == 0
    check not h.canUndo()

  test "reordering within one stack applies and selects the moved tab":
    let o = apply(twoStacks(), cmdMoveTab(paneEditor, paneFlow, 1))
    checkApplied o
    if o.kind == loApplied:
      let holder = parentOf(o.layout.tree, o.layout.tree.find(paneEditor))
      check holder.children[1].pane == paneEditor
      check holder.activeIndex == 1

  test "a destination that is not a stack is refused by kind":
    for name in ["two-pane row", "deep tree"]:
      checkpoint(name)
      checkRefused apply(shape(name), cmdMoveTab(paneState, paneEditor, 0)),
                   lpTargetNotAStack

  test "an index outside the destination is refused by kind":
    checkRefused apply(twoStacks(), cmdMoveTab(paneFlow, paneState, 99)),
                 lpIndexOutOfRange
    checkRefused apply(twoStacks(), cmdMoveTab(paneFlow, paneState, -1)),
                 lpIndexOutOfRange

  test "moving an absent pane, or beside an absent one, is refused by kind":
    checkRefused apply(twoStacks(), cmdMoveTab(paneShell, paneState, 0)),
                 lpPaneNotPlaced
    checkRefused apply(twoStacks(), cmdMoveTab(paneFlow, paneShell, 0)),
                 lpPaneNotPlaced

  test "emptying the source stack collapses it, and the tree stays valid":
    let l = initLayout(row([
      stack([pane(paneEditor, "Editor")], weight = 1.0),
      stack([pane(paneState), pane(paneEventLog)], weight = 1.0)]))
    let o = apply(l, cmdMoveTab(paneEditor, paneState, 0))
    checkApplied o
    if o.kind == loApplied:
      check o.layout.tree.kind == lnStack
      check o.layout.tree.children.len == 3
      checkValid o.layout

suite "Layout algebra — split":

  test "splitting a pane replaces it with a container holding both":
    for axis in [saRow, saColumn]:
      for side in [ssBefore, ssAfter]:
        let o = apply(twoPaneRow(), cmdSplit(paneEditor, paneShell, axis, side))
        checkpoint($axis & "/" & $side)
        checkApplied o
        if o.kind == loApplied:
          let holder = parentOf(o.layout.tree, o.layout.tree.find(paneShell))
          check holder.kind == (if axis == saRow: lnRow else: lnColumn)
          check holder.children.len == 2
          let first = holder.children[0].pane
          check first == (if side == ssBefore: paneShell else: paneEditor)
          checkValid o.layout

  test "splitting a TABBED pane splits the whole stack, not the tab":
    # A stack nested inside a row inside a stack is not a shape this model
    # has (`lpStackChildNotPane`), so the region has to move as a whole.
    let o = apply(stackedLayout(), cmdSplit(paneState, paneShell, saColumn))
    checkApplied o
    if o.kind == loApplied:
      checkValid o.layout
      let holder = parentOf(o.layout.tree, o.layout.tree.find(paneShell))
      check holder.kind == lnColumn
      check holder.children[0].kind == lnStack
      check holder.children[0].contains(paneEventLog)

  test "the split container inherits the target's share":
    let l = initLayout(row([pane(paneEditor, weight = 3.0),
                            pane(paneState, weight = 1.0)]))
    let o = apply(l, cmdSplit(paneEditor, paneShell, saColumn))
    checkApplied o
    if o.kind == loApplied:
      check o.layout.tree.children[0].weight == 3.0

  test "splitting in a pane that is not there is refused by kind":
    checkRefused apply(twoPaneRow(), cmdSplit(paneScratchpad, paneShell, saRow)),
                 lpPaneNotPlaced

  test "splitting in a pane that is already placed is refused by kind":
    for name in AllShapes:
      checkpoint(name)
      checkRefused apply(shape(name), cmdSplit(paneEditor, paneEditor, saRow)),
                   lpDuplicatePane

suite "Layout algebra — merge into stack":

  test "merging a pane into an adjacent stack makes it a tab":
    let o = apply(stackedLayout(), cmdMergeIntoStack(paneEditor, paneState))
    checkApplied o
    if o.kind == loApplied:
      check o.layout.tree.kind == lnStack
      check o.layout.tree.children.len == 3
      check o.layout.tree.isVisible(paneEditor)
      checkValid o.layout

  test "merging onto a bare pane turns it into a two-tab stack":
    let o = apply(twoPaneRow(), cmdMergeIntoStack(paneEditor, paneState))
    checkApplied o
    if o.kind == loApplied:
      check o.layout.tree.kind == lnStack
      check o.layout.tree.allPanes() == @[paneState, paneEditor]
      check o.layout.tree.activeIndex == 1
      checkValid o.layout

  test "merging into the stack a pane is already in is a no-op":
    checkNoOp apply(twoStacks(), cmdMergeIntoStack(paneEditor, paneFlow))

  test "merging a pane with itself is refused by kind":
    checkRefused apply(twoPaneRow(), cmdMergeIntoStack(paneEditor, paneEditor)),
                 lpDuplicatePane

  test "dragging a WHOLE REGION into a tab is refused by kind (§8 decision 1)":
    # "Keep the restriction, and refuse that gesture with a typed outcome,
    # until a user asks." A refusal is the answer; silently reinterpreting it
    # as dragging the one pane under the cursor is not.
    checkRefused apply(deepTree(),
                       cmdMergeIntoStack(paneCalltrace, paneState,
                                         wholeRegion = true)),
                 lpStackChildNotPane

  test "merging an absent pane is refused by kind":
    checkRefused apply(twoStacks(), cmdMergeIntoStack(paneShell, paneState)),
                 lpPaneNotPlaced
    checkRefused apply(twoStacks(), cmdMergeIntoStack(paneEditor, paneShell)),
                 lpPaneNotPlaced

suite "Layout algebra — rename":

  test "renaming a placed pane applies; the same title is a no-op":
    let l = twoPaneRow()
    checkNoOp apply(l, cmdRename(paneEditor, "Editor"))
    let o = apply(l, cmdRename(paneEditor, "Source"))
    checkApplied o
    if o.kind == loApplied:
      check o.layout.tree.find(paneEditor).title == "Source"

  test "renaming a DOCKED pane applies without placing it":
    let docked = apply(stackedLayout(), cmdDock(paneEventLog, leBottom))
    checkApplied docked
    if docked.kind == loApplied:
      let o = apply(docked.layout, cmdRename(paneEventLog, "Events"))
      checkApplied o
      if o.kind == loApplied:
        check o.layout.docked[0].title == "Events"
        check o.layout.placement(paneEventLog) == plDocked

  test "renaming a pane that is nowhere is refused by kind":
    for name in AllShapes:
      checkpoint(name)
      checkRefused apply(shape(name), cmdRename(paneScratchpad, "x")),
                   lpPaneNeitherPlacedNorDocked

# ---------------------------------------------------------------------------
# §3 — auto-hide
# ---------------------------------------------------------------------------

suite "Layout algebra — auto-hide (§3)":

  test "docking removes the pane from the tree and appends a DockedPane":
    let o = apply(stackedLayout(), cmdDock(paneEventLog, leBottom))
    checkApplied o
    if o.kind == loApplied:
      check not o.layout.tree.contains(paneEventLog)
      check o.layout.docked.len == 1
      check o.layout.docked[0].edge == leBottom
      check o.layout.docked[0].title == "Event Log"
      check o.layout.placement(paneEventLog) == plDocked
      checkValid o.layout

  test "docking applies the collapse rules at the source for free":
    let l = initLayout(row([pane(paneEditor, weight = 1.0),
                            column([pane(paneState)], weight = 1.0)]))
    let o = apply(l, cmdDock(paneState, leLeft))
    checkApplied o
    if o.kind == loApplied:
      check o.layout.tree.kind == lnPane
      checkValid o.layout

  test "docking the same pane to the same edge and order is a no-op":
    let o = apply(stackedLayout(), cmdDock(paneEventLog, leBottom))
    checkApplied o
    if o.kind == loApplied:
      checkNoOp apply(o.layout, cmdDock(paneEventLog, leBottom))

  test "moving a docked pane to another edge applies without touching the tree":
    let o = apply(stackedLayout(), cmdDock(paneEventLog, leBottom))
    checkApplied o
    if o.kind == loApplied:
      let moved = apply(o.layout, cmdDock(paneEventLog, leRight))
      checkApplied moved
      if moved.kind == loApplied:
        check moved.layout.docked[0].edge == leRight
        check $moved.layout.tree == $o.layout.tree

  test "a taken (edge, order) slot is refused by kind":
    var l = stackedLayout()
    let a = apply(l, cmdDock(paneEventLog, leBottom, order = 0))
    checkApplied a
    if a.kind == loApplied:
      checkRefused apply(a.layout, cmdDock(paneState, leBottom, order = 0)),
                   lpDockOrderCollision

  test "a negative order appends to the end of that edge's strip":
    let a = apply(deepTree(), cmdDock(paneEventLog, leBottom))
    checkApplied a
    if a.kind == loApplied:
      let b = apply(a.layout, cmdDock(paneState, leBottom))
      checkApplied b
      if b.kind == loApplied:
        check b.layout.dockedAt(leBottom).len == 2
        check b.layout.dockedAt(leBottom)[0].pane == paneEventLog
        check b.layout.dockedAt(leBottom)[1].pane == paneState
        check b.layout.dockedAt(leBottom)[1].order == 1

  test "docking the last placed pane is refused as an empty root":
    checkRefused apply(initLayout(pane(paneEditor)),
                       cmdDock(paneEditor, leLeft)), lpEmptyRoot

  test "docking a pane that is nowhere is refused by kind":
    checkRefused apply(twoPaneRow(), cmdDock(paneScratchpad, leTop)),
                 lpPaneNotPlaced

  test "restoring puts a docked pane back into the tree":
    let a = apply(stackedLayout(), cmdDock(paneEventLog, leBottom))
    checkApplied a
    if a.kind == loApplied:
      let b = apply(a.layout, cmdRestoreDocked(paneEventLog,
                                               beside = some(paneState)))
      checkApplied b
      if b.kind == loApplied:
        check b.layout.docked.len == 0
        check b.layout.tree.contains(paneEventLog)
        check b.layout.placement(paneEventLog) == plPlaced
        checkValid b.layout

  test "restoring a pane that is not docked is refused by kind":
    for name in AllShapes:
      checkpoint(name)
      checkRefused apply(shape(name), cmdRestoreDocked(paneEditor)),
                   lpPaneNotDocked

  test "restoring beside an absent anchor is refused by kind":
    let a = apply(stackedLayout(), cmdDock(paneEventLog, leBottom))
    checkApplied a
    if a.kind == loApplied:
      checkRefused apply(a.layout,
                         cmdRestoreDocked(paneEventLog,
                                          beside = some(paneScratchpad))),
                   lpPaneNotPlaced

  test "a docked pane is not visible, even though it is in the layout":
    let a = apply(stackedLayout(), cmdDock(paneEventLog, leBottom))
    checkApplied a
    if a.kind == loApplied:
      check paneEventLog in a.layout.allPanes()
      check paneEventLog notin a.layout.visiblePanes()

# ---------------------------------------------------------------------------
# §7 — the new invariants
# ---------------------------------------------------------------------------

suite "Layout algebra — invariants (§7)":

  test "a pane in the tree AND in docked fails validate":
    # The milestone's named test. This is the invariant that keeps `allPanes`
    # meaning what it says.
    let bad = initLayout(row([pane(paneEditor), pane(paneState)]),
                         @[DockedPane(pane: paneState, edge: leLeft, order: 0)])
    var kinds: seq[LayoutProblemKind] = @[]
    for p in validate(bad):
      kinds.add(p.kind)
    checkpoint($kinds)
    check lpPaneBothPlacedAndDocked in kinds
    check not bad.isValid()

  test "a pane the shell owns that is nowhere fails validate":
    let l = initLayout(row([pane(paneEditor), pane(paneState)]))
    check l.isValid()
    var kinds: seq[LayoutProblemKind] = @[]
    for p in validate(l, owned = {paneEditor, paneState, paneCalltrace}):
      kinds.add(p.kind)
    check lpPaneNeitherPlacedNorDocked in kinds
    # And the same layout with the pane docked is fine — which is what makes
    # the check about PRESENCE rather than about placement.
    let withDock = initLayout(row([pane(paneEditor), pane(paneState)]),
                              @[DockedPane(pane: paneCalltrace, edge: leLeft,
                                           order: 0)])
    check withDock.isValid(owned = {paneEditor, paneState, paneCalltrace})

  test "a single-child row or column fails validate":
    for tree in [row([pane(paneEditor)]), column([pane(paneEditor)])]:
      var kinds: seq[LayoutProblemKind] = @[]
      for p in validate(initLayout(tree)):
        kinds.add(p.kind)
      checkpoint($tree & " -> " & $kinds)
      check lpSingleChildContainer in kinds
    # A single-TAB stack is not a defect: one tab is an arrangement.
    check initLayout(stack([pane(paneEditor)])).isValid()

  test "two docked panes on the same (edge, order) fail validate":
    let bad = initLayout(pane(paneEditor), @[
      DockedPane(pane: paneState, edge: leBottom, order: 2),
      DockedPane(pane: paneShell, edge: leBottom, order: 2)])
    var kinds: seq[LayoutProblemKind] = @[]
    for p in validate(bad):
      kinds.add(p.kind)
    check lpDockOrderCollision in kinds
    # The same orders on DIFFERENT edges are two strips, not a collision.
    check initLayout(pane(paneEditor), @[
      DockedPane(pane: paneState, edge: leBottom, order: 2),
      DockedPane(pane: paneShell, edge: leTop, order: 2)]).isValid()

  test "an empty root fails validate":
    var kinds: seq[LayoutProblemKind] = @[]
    for p in validate(initLayout(column([]))):
      kinds.add(p.kind)
    check lpEmptyRoot in kinds

  test "every refusal-only problem kind is reachable from some command":
    # The mirror of `test_layout_model.nim`'s structural witness table, and
    # the other half of the partition `problemSources` declares. The `case` is
    # exhaustive, so a new `LayoutProblemKind` without an entry here is a
    # compile error.
    let stacked = stackedLayout()
    let dockedLayout =
      block:
        let o = apply(stacked, cmdDock(paneEventLog, leBottom, order = 0))
        if o.kind == loApplied: o.layout else: stacked
    var refusalCovered = 0
    for kind in LayoutProblemKind:
      let witness: Option[LayoutCommand] =
        case kind
        of lpDuplicatePane: some(cmdAddPane(paneEditor))
        of lpNegativeWeight: some(cmdSetWeight(paneEditor, -1.0))
        of lpStackChildNotPane:
          some(cmdMergeIntoStack(paneEditor, paneState, wholeRegion = true))
        of lpPaneBothPlacedAndDocked: some(cmdAddPane(paneEventLog))
        of lpEmptyRoot: some(cmdRemovePane(paneEditor))
        of lpDockOrderCollision:
          some(cmdDock(paneState, leBottom, order = 0))
        of lpPaneNeitherPlacedNorDocked: some(cmdRename(paneScratchpad, "x"))
        of lpPaneNotPlaced: some(cmdActivateTab(paneScratchpad))
        of lpPaneNotDocked: some(cmdRestoreDocked(paneEditor))
        of lpTargetNotAStack: some(cmdMoveTab(paneState, paneEditor, 0))
        of lpIndexOutOfRange: some(cmdMoveTab(paneEditor, paneState, 99))
        of lpEmptyContainer, lpPaneWithChildren, lpContainerWithPaneField,
           lpActiveIndexOutOfRange, lpSingleChildContainer:
          none(LayoutCommand)
      checkpoint("witness for " & $kind)
      if lpsRefusal in problemSources(kind):
        check witness.isSome
        if witness.isSome:
          inc refusalCovered
          # `lpEmptyRoot`'s witness needs a one-pane layout; every other one
          # runs against the docked fixture, which has a stack, two panes and
          # one docked pane — enough shape for all of them.
          let subject =
            if kind == lpEmptyRoot: initLayout(pane(paneEditor))
            else: dockedLayout
          checkRefused apply(subject, witness.get), kind
      else:
        check witness.isNone
    # A positive control: if `problemSources` declared everything structural,
    # every branch would be skipped and this test would still be green.
    check refusalCovered == 11

# ---------------------------------------------------------------------------
# §3A.2 — the floating-panel non-goal, asserted structurally
# ---------------------------------------------------------------------------

suite "Layout algebra — floating panels are not expressible (§3A.2)":

  test "there are exactly three placements and none of them is a coordinate":
    # The enum IS the assertion. A floating panel needs a fourth answer —
    # "somewhere, at (x, y), over the top" — and adding one breaks every
    # exhaustive `case` rather than being a field nobody notices.
    var seen: seq[string] = @[]
    for p in PanePlacement:
      seen.add($p)
    check seen.len == 3
    let docked = apply(stackedLayout(), cmdDock(paneEventLog, leBottom))
    checkApplied docked
    if docked.kind == loApplied:
      check docked.layout.placement(paneEditor) == plPlaced
      check docked.layout.placement(paneEventLog) == plDocked
      check docked.layout.placement(paneScratchpad) == plAbsent

  test "no persisted layout type carries a position or a size":
    # A structural walk over the FIELD NAMES of everything `saveLayout`
    # writes. A floating panel is by definition outside the split tree's
    # partition, and the first thing anyone adding one would need is a
    # coordinate — so the check is that no such field exists, on the types
    # rather than on a document.
    const Positional = ["x", "y", "left", "top", "right", "bottom",
                        "width", "height", "z", "zIndex", "floating"]
    var checkedFields = 0
    var offenders: seq[string] = @[]
    var node = pane(paneEditor)
    for name, _ in node[].fieldPairs:
      inc checkedFields
      if name in Positional:
        offenders.add("LayoutNode." & name)
    var dock = DockedPane(pane: paneEditor, edge: leLeft, order: 0)
    for name, _ in dock.fieldPairs:
      inc checkedFields
      if name in Positional:
        offenders.add("DockedPane." & name)
    var lay = initLayout(pane(paneEditor))
    for name, _ in lay.fieldPairs:
      inc checkedFields
      if name in Positional:
        offenders.add("Layout." & name)
    checkpoint("offending fields: " & offenders.join(", "))
    check offenders.len == 0
    # Positive control (Verification-Harness-Traps §4): a walk that visited
    # nothing would report no offenders too.
    check checkedFields == 6 + 5 + 3

  test "every visible pane occupies a distinct region of the split tree":
    # The model's half of the projection's total-and-disjoint invariant: each
    # visible pane has exactly one leaf in the tree, so a renderer that gives
    # every leaf a rectangle gives every visible pane exactly one. The cell
    # grid half stays in `tui/app/layout/project.nim`, which is where cells
    # are known about.
    let commands = @[
      cmdSplit(paneEditor, paneShell, saRow),
      cmdMergeIntoStack(paneShell, paneState),
      cmdDock(paneCalltrace, leLeft),
      cmdMoveTab(paneShell, paneEventLog, 0),
      cmdRemovePane(paneDebugControls)]
    var l = deepTree()
    for cmd in commands:
      let o = apply(l, cmd)
      checkpoint($cmd & " -> " & $o)
      if o.kind == loApplied:
        l = o.layout
      checkValid l
      var seen = initHashSet[PaneKind]()
      for p in l.visiblePanes():
        check p notin seen
        seen.incl(p)
      # A visible pane is a leaf of the tree, never a docked one.
      for p in l.visiblePanes():
        check l.placement(p) == plPlaced
      for d in l.docked:
        check d.pane notin l.visiblePanes()

# ---------------------------------------------------------------------------
# §2.5 — undo/redo
# ---------------------------------------------------------------------------

suite "Layout algebra — undo/redo as a command log (§2.5)":

  test "undo returns to the previous layout and redo returns to the next":
    var h = newLayoutHistory(stackedLayout())
    let start = $h.value
    checkApplied h.dispatch(cmdSplit(paneEditor, paneShell, saRow))
    let afterSplit = $h.value
    checkApplied h.dispatch(cmdDock(paneEventLog, leBottom))
    let afterDock = $h.value
    check h.log.len == 2
    check h.undo()
    check $h.value == afterSplit
    check h.undo()
    check $h.value == start
    check not h.canUndo()
    check not h.undo()
    check h.redo()
    check $h.value == afterSplit
    check h.redo()
    check $h.value == afterDock
    check not h.canRedo()

  test "only loApplied commands enter the log":
    var h = newLayoutHistory(stackedLayout())
    checkNoOp h.dispatch(cmdActivateTab(paneState))     # already visible
    checkRefused h.dispatch(cmdRemovePane(paneScratchpad)), lpPaneNotPlaced
    check h.log.len == 0
    check not h.canUndo()
    checkApplied h.dispatch(cmdActivateTab(paneEventLog))
    check h.log.len == 1

  test "a new command after an undo discards the redo tail":
    var h = newLayoutHistory(twoStacks())
    checkApplied h.dispatch(cmdRename(paneEditor, "One"))
    checkApplied h.dispatch(cmdRename(paneEditor, "Two"))
    check h.undo()
    check h.canRedo()
    checkApplied h.dispatch(cmdRename(paneEditor, "Three"))
    check not h.canRedo()
    check h.log.len == 2
    check h.value.tree.find(paneEditor).title == "Three"

  test "the history's floor is a copy — mutating the caller's tree cannot move it":
    let mine = stackedLayout()
    var h = newLayoutHistory(mine)
    discard mine.tree.setWeight(paneEditor, 99.0)
    check h.initial.tree.find(paneEditor).weight == 3.0

# ---------------------------------------------------------------------------
# §6 — persistence, versioning and the migration chain
# ---------------------------------------------------------------------------

suite "Layout algebra — persistence (§6)":

  test "a layout with docked panes round-trips, which it could not before":
    var l = deepTree()
    let a = apply(l, cmdDock(paneEventLog, leBottom, order = 0))
    checkApplied a
    if a.kind == loApplied:
      let b = apply(a.layout, cmdDock(paneCalltrace, leLeft, order = 3))
      checkApplied b
      if b.kind == loApplied:
        l = b.layout
        let restored = restoreLayoutDocument(saveLayout(l))
        check $restored == $l
        check restored.docked.len == 2
        check restored.docked[0].pane == paneEventLog
        check restored.docked[0].edge == leBottom
        check restored.docked[0].order == 0
        check restored.docked[0].title == "Event Log"
        check restored.docked[1].edge == leLeft
        check restored.docked[1].order == 3
        check $restored.tree == $l.tree

  test "revealed is NOT persisted — a restore reopens no overlay":
    # §3.2. A restore that reopened four overlays would be a bug, and the
    # field not being written is what prevents it. Asserted from BOTH ends:
    # the encoder does not emit the key, and the decoder forces the field
    # false even for a document that carries it.
    var l = initLayout(row([pane(paneEditor), pane(paneState)]))
    l.docked.add(DockedPane(pane: paneShell, title: "Shell", edge: leBottom,
                            order: 0, revealed: true))
    let doc = saveLayout(l)
    check not doc["docked"][0].hasKey("revealed")
    let restored = restoreLayoutDocument(doc)
    check restored.docked.len == 1
    check not restored.docked[0].revealed
    # And a hand-edited document that DOES carry it still restores closed.
    var forged = saveLayout(l)
    forged["docked"][0]["revealed"] = %true
    check not restoreLayoutDocument(forged).docked[0].revealed

  test "docked is written even when empty, so gaining auto-hide is not a bump":
    let doc = saveLayout(defaultReplayLayoutValue())
    check doc.hasKey("docked")
    check doc["docked"].kind == JArray
    check doc["docked"].len == 0

  test "a version-1 document migrates forward and restores":
    # The chain, exercised on a real v1 document rather than on a description
    # of one: v1 had no `docked` key at all.
    let v1 = %*{
      "version": 1,
      "layout": {
        "kind": "row",
        "children": [
          {"kind": "pane", "pane": "editor", "title": "Editor", "weight": 3.0},
          {"kind": "pane", "pane": "state", "title": "State"}]}}
    let restored = restoreLayoutDocument(v1)
    check restored.version == LayoutSchemaVersion
    check restored.docked.len == 0
    check restored.tree.allPanes() == @[paneEditor, paneState]
    check restored.tree.find(paneEditor).weight == 3.0
    check restored.isValid()

  test "a version above this build's is still refused, loudly":
    # There is no backward migration and there must not be one: an older
    # build refusing a newer layout is correct.
    var doc = saveLayout(defaultReplayLayoutValue())
    doc["version"] = %(LayoutSchemaVersion + 1)
    var caught = false
    try:
      discard restoreLayoutDocument(doc)
    except LayoutDecodeError as e:
      caught = true
      check e.kind == ldeUnknownVersion
      check e.detail == $(LayoutSchemaVersion + 1)
    check caught

  test "a version below the oldest readable one is refused by the same kind":
    var doc = saveLayout(defaultReplayLayoutValue())
    doc["version"] = %(FirstLayoutSchemaVersion - 1)
    var caught = false
    try:
      discard restoreLayoutDocument(doc)
    except LayoutDecodeError as e:
      caught = true
      check e.kind == ldeUnknownVersion
    check caught

  test "an unknown edge is a typed refusal, not a silently dropped strip":
    # The same rule `ldeUnknownPane` embodies, applied to the second
    # persisted vocabulary.
    let doc = %*{
      "version": LayoutSchemaVersion,
      "layout": {"kind": "pane", "pane": "editor"},
      "docked": [{"pane": "shell", "edge": "northwest", "order": 0}]}
    var caught = false
    try:
      discard restoreLayoutDocument(doc)
    except LayoutDecodeError as e:
      caught = true
      check e.kind == ldeUnknownEdge
      check e.detail == "northwest"
    check caught

  test "an unknown docked pane is a typed refusal, never a blank strip":
    let doc = %*{
      "version": LayoutSchemaVersion,
      "layout": {"kind": "pane", "pane": "editor"},
      "docked": [{"pane": "notARealPane", "edge": "left", "order": 0}]}
    var caught = false
    try:
      discard restoreLayoutDocument(doc)
    except LayoutDecodeError as e:
      caught = true
      check e.kind == ldeUnknownPane
    check caught

  test "every edge name survives a round trip":
    # The enum's string values ARE the wire format, exactly as `PaneKind`'s
    # are, so all four are round-tripped rather than a representative sample.
    for e in LayoutEdge:
      let l = initLayout(pane(paneEditor),
                         @[DockedPane(pane: paneShell, edge: e, order: 0)])
      checkpoint($e)
      check restoreLayoutDocument(saveLayout(l)).docked[0].edge == e

  test "a docked entry missing a required field is refused by kind":
    for missing in ["pane", "edge", "order"]:
      var doc = saveLayout(initLayout(pane(paneEditor),
        @[DockedPane(pane: paneShell, edge: leLeft, order: 0)]))
      doc["docked"][0].delete(missing)
      var caught = false
      try:
        discard restoreLayoutDocument(doc)
      except LayoutDecodeError as e:
        caught = true
        check e.kind == ldeMissingField
        check e.detail == "docked." & missing
      checkpoint("missing: " & missing)
      check caught

  test "the tree-only decoder REFUSES a document carrying docked panes":
    # A bare `LayoutNode` cannot represent a docked pane, so returning one
    # would drop the panes silently — §1.3's blank-slot failure, one level up.
    let doc = saveLayout(initLayout(pane(paneEditor),
      @[DockedPane(pane: paneShell, edge: leLeft, order: 0)]))
    var caught = false
    try:
      discard restoreLayout(doc)
    except LayoutDecodeError as e:
      caught = true
      check e.kind == ldeDockedPanesUnsupported
    check caught
    # And it still works for a document with none, which is what keeps every
    # existing caller unchanged.
    check restoreLayout(saveLayout(defaultReplayLayout())).allPanes().len == 5

# ---------------------------------------------------------------------------
# §3A — windows
# ---------------------------------------------------------------------------

suite "WindowSet — one window is not a degraded case (§3A.1)":

  test "a single-window front-end holds a set of size one and pays nothing":
    let ws = singleWindow(defaultReplayLayoutValue())
    check ws.windows.len == 1
    check ws.capacity == wcSingleWindow
    check ws.isValid()
    # Every ordinary layout command reaches it unchanged — there is no
    # single-window arm anywhere in the module.
    let o = ws.applyIn(WindowId(0), cmdActivateTab(paneEventLog))
    check o.kind == wsApplied
    if o.kind == wsApplied:
      check o.windows.focusedLayout().tree.isVisible(paneEventLog)

  test "opening a second window is refused on a declared single-window set":
    let ws = singleWindow(defaultReplayLayoutValue())
    let o = ws.openWindow(WindowId(1), initLayout(pane(paneShell)))
    check o.kind == wsRefused
    if o.kind == wsRefused:
      check o.problem.kind == wpSingleWindowOnly

  test "a layout refusal is carried through by kind, not flattened":
    let ws = singleWindow(initLayout(pane(paneEditor)))
    let o = ws.applyIn(WindowId(0), cmdRemovePane(paneEditor))
    check o.kind == wsRefused
    if o.kind == wsRefused:
      check o.problem.kind == wpLayoutRefused
      check o.problem.layoutProblem.isSome
      check o.problem.layoutProblem.get.kind == lpEmptyRoot

suite "WindowSet — moving a tab between windows (§3A.1)":

  test "it composes from lcRemovePane and lcAddPane":
    var ws = multiWindow([stackedLayout(), initLayout(pane(paneShell, "Shell"))])
    let o = ws.moveTabToWindow(paneEventLog, WindowId(0), WindowId(1))
    check o.kind == wsApplied
    if o.kind == wsApplied:
      let src = o.windows.windows[0].layout
      let dst = o.windows.windows[1].layout
      check not src.tree.contains(paneEventLog)
      check dst.tree.contains(paneEventLog)
      check dst.tree.find(paneEventLog).title == "Event Log"
      check o.windows.isValid()
      # The source inherited §2.4 for free: the stack it left had two tabs and
      # is now a one-tab stack, and the row is untouched.
      check src.isValid()

  test "the source's collapse rules apply without this layer knowing them":
    var ws = multiWindow([
      initLayout(row([pane(paneEditor, weight = 1.0),
                      column([pane(paneState)], weight = 1.0)])),
      initLayout(pane(paneShell))])
    let o = ws.moveTabToWindow(paneState, WindowId(0), WindowId(1))
    check o.kind == wsApplied
    if o.kind == wsApplied:
      check o.windows.windows[0].layout.tree.kind == lnPane
      check o.windows.isValid()

  test "dragging a window's LAST pane away is refused, by the layout's kind":
    var ws = multiWindow([initLayout(pane(paneEditor)),
                          initLayout(pane(paneShell))])
    let o = ws.moveTabToWindow(paneEditor, WindowId(0), WindowId(1))
    check o.kind == wsRefused
    if o.kind == wsRefused:
      check o.problem.kind == wpLayoutRefused
      check o.problem.layoutProblem.isSome
      check o.problem.layoutProblem.get.kind == lpEmptyRoot

  test "a refused insertion discards the removal — the move is atomic":
    # The destination already has the pane, so `lcAddPane` refuses. Nothing
    # about the source may have changed, and no transaction was needed to say
    # so: `apply` returns values.
    var ws = multiWindow([twoPaneRow(), initLayout(pane(paneState, "State"))])
    let before = $ws.windows[0].layout
    let o = ws.moveTabToWindow(paneState, WindowId(0), WindowId(1))
    check o.kind == wsRefused
    if o.kind == wsRefused:
      check o.problem.kind == wpPaneInTwoWindows
    check $ws.windows[0].layout == before
    check ws.windows[0].layout.tree.contains(paneState)

  test "source and destination being the same window is refused by kind":
    var ws = multiWindow([twoStacks(), initLayout(pane(paneShell))])
    let o = ws.moveTabToWindow(paneEditor, WindowId(0), WindowId(0))
    check o.kind == wsRefused
    if o.kind == wsRefused:
      check o.problem.kind == wpSameWindow

  test "an unknown window is refused by kind":
    var ws = multiWindow([twoStacks()])
    let o = ws.moveTabToWindow(paneEditor, WindowId(0), WindowId(7))
    check o.kind == wsRefused
    if o.kind == wsRefused:
      check o.problem.kind == wpUnknownWindow

  test "a pane in two windows fails validate":
    var ws = multiWindow([initLayout(row([pane(paneEditor), pane(paneState)])),
                          initLayout(pane(paneState))])
    var kinds: seq[WindowSetProblemKind] = @[]
    for p in validate(ws):
      kinds.add(p.kind)
    check wpPaneInTwoWindows in kinds

suite "WindowSet — persistence restores the window SET (§3A.1)":

  test "a two-window set with docked panes round-trips":
    var ws = multiWindow([stackedLayout(),
                          initLayout(row([pane(paneShell, "Shell"),
                                          pane(paneScratchpad, "Scratch")]))])
    let docked = apply(ws.windows[0].layout, cmdDock(paneEventLog, leBottom))
    check docked.kind == loApplied
    if docked.kind == loApplied:
      ws.windows[0].layout = docked.layout
      ws.windows[1].bounds = some(WindowBounds(x: 10, y: 20, width: 800,
                                               height: 600))
      ws.focused = 1
      let restored = restoreWindowSet(saveWindowSet(ws))
      check restored.windows.len == 2
      check restored.focused == 1
      check restored.capacity == wcMultiWindow
      check $restored.windows[0].layout == $ws.windows[0].layout
      check restored.windows[0].layout.docked.len == 1
      check restored.windows[1].bounds.isSome
      check restored.windows[1].bounds.get.width == 800
      check restored.isValid()

  test "a single-window set records its capacity across a restore":
    let ws = singleWindow(defaultReplayLayoutValue())
    let restored = restoreWindowSet(saveWindowSet(ws))
    check restored.capacity == wcSingleWindow
    check restored.openWindow(WindowId(9),
                              initLayout(pane(paneShell))).kind == wsRefused

  test "a window set from an unknown version is refused by kind":
    var doc = saveWindowSet(singleWindow(defaultReplayLayoutValue()))
    doc["version"] = %(WindowSetSchemaVersion + 1)
    var caught = false
    try:
      discard restoreWindowSet(doc)
    except LayoutDecodeError as e:
      caught = true
      check e.kind == ldeUnknownVersion
    check caught
