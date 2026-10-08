## SDK-CONSUMER: the transient interaction machine sits beside the layout
## algebra on the SHELL side of the SDK boundary, for the reason
## `test_layout_algebra.nim`'s header gives — arranging panes is the
## embedder's job, and this suite needs nothing from the facade.
##
## test_layout_interaction.nim
##
## PLAT-5 (CodeTracer-Platform.milestones.org) / Layout-ViewModel §4.
##
## ## NO MOCKS, AND NOTHING TO JUSTIFY
##
## The workspace policy asks every use of a mock object to be justified in a
## test file's header. **This file uses none.** The subject is a pure value
## transformation: `dropTargetsFor` reads a `Layout` and a `LayoutPointer` and
## returns a `seq[DropTarget]`; `commit` reads a `Layout` and an `Interaction`
## and returns an `Option[LayoutCommand]`. Nothing here opens a file, spawns a
## process, or reaches a renderer, an engine or a clock — so there is no
## boundary a mock could stand in for. That absence is the milestone's point
## rather than an accident: §4.2 says the drop-target computation is pure so
## that drag behaviour can be asserted with no pointing device, and a suite
## that needed a fake pointer would be evidence the purity had been lost.
##
## ## WHAT THIS SUITE IS FOR
##
## The milestone's four claims, in its order:
##
##   1. **Drop-target computation is tested without any pointer**, because it
##      is pure. Asserted in the strongest available form — `not compiles(...)`
##      over a `LayoutPointer` carrying a coordinate, and a field walk finding
##      no measurement on either `LayoutPointer` or `DropRegion` — plus a
##      demonstration that a pixel hit-test and a cell hit-test that land on
##      the same node produce byte-identical candidate lists.
##   2. **A cancelled drag leaves the committed layout byte-identical**, and
##      the comparison is over the SERIALISED BYTES (`$saveLayout(...)`), not
##      over a summary that could agree while the document differed.
##   3. **A drag ending where it began commits `none` and pushes no undo
##      entry** — and the agreement between that `none` and PLAT-4's `loNoOp`
##      is asserted over the whole candidate sweep, not only on the one case.
##   4. **Every `DropTarget` kind against every structural shape**, with
##      refusals asserted AS REFUSALS — by `problem.kind` — rather than as
##      "no candidate appeared".
##
## And the milestone's risk mitigation: **`Interaction` is a separate type; a
## structural check keeps it out of `Layout`.** Two checks, because the leak
## has two shapes. A leak that names the real type cannot compile — this
## module imports `layout_model`, so the reverse import is a cycle — and the
## suite asserts that by reading `layout_model.nim`'s own source. A leak that
## only smells like one (a `hover: string`) does compile, and the field-name
## walk over the persisted types is what catches it.
##
## ## TRAP 13 (Verification-Harness-Traps §13)
##
## `unittest.check` inside a plain `proc` assigns a MODULE-LEVEL
## `testStatusIMPL` and leaves the running test's own status untouched — the
## test prints its failed comparison and still reports `[OK]`. **Every
## assertion helper in this file is a `template`.** The handful of `proc`s
## here collect values and contain no `check` at all; `grep -n 'proc '` over
## this file, read together with `grep -n check`, is the sweep.
##
## Compile and run:
##   nim c -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_layout_interaction.nim
##   nim js -d:nodejs -r --path:src/frontend/viewmodel \
##     src/frontend/viewmodel/tests/unit/test_layout_interaction.nim

import std/[json, options, sets, strutils, unittest]

import headless_app/layout_model
import headless_app/layout_interaction

# ---------------------------------------------------------------------------
# Assertion helpers. TEMPLATES, NOT PROCS — see the header, trap 13.
# ---------------------------------------------------------------------------

template checkRefused(outcome: LayoutOutcome; expected: LayoutProblemKind) =
  ## A refusal asserted as a refusal: the outcome kind AND the reason.
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
  let problems = validate(v, {})
  var kinds: seq[string] = @[]
  for p in problems:
    kinds.add($p.kind & "@'" & p.path & "'")
  checkpoint("layout: " & $v & " problems: " & kinds.join(", "))
  check problems.len == 0

# ---------------------------------------------------------------------------
# Fixtures. Plain constructors over the real model — no builders, no fakes.
# ---------------------------------------------------------------------------

proc barePane(): Layout =
  initLayout(pane(paneEditor, "Editor"))

proc twoPaneRow(): Layout =
  initLayout(row([pane(paneEditor, "Editor", weight = 3.0),
                  pane(paneState, "State", weight = 1.0)]))

proc stackedLayout(): Layout =
  ## A row whose right half is a two-tab stack.
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

proc withDocked(): Layout =
  ## `stackedLayout` with the Event Log docked to the bottom, so a docked
  ## source has somewhere to be dragged FROM.
  let o = apply(stackedLayout(), cmdDock(paneEventLog, leBottom))
  if o.kind == loApplied: o.layout else: stackedLayout()

proc dockedBesideStacks(): Layout =
  ## `twoStacks` with Flow docked to the left: a docked source, and a
  ## destination stack with TWO tabs, so it has three insertion slots.
  let o = apply(twoStacks(), cmdDock(paneFlow, leLeft))
  if o.kind == loApplied: o.layout else: twoStacks()

proc threeInARow(): Layout =
  ## Three panes with equal weights: the smallest shape in which a divider
  ## drag and a one-node share resize are different gestures.
  initLayout(row([pane(paneEditor, "Editor", weight = 1.0),
                  pane(paneState, "State", weight = 1.0),
                  pane(paneFlow, "Flow", weight = 1.0)]))

proc rowOfColumns(): Layout =
  ## A divider between two CONTAINERS, neither of which is a pane or a stack.
  initLayout(row([
    column([pane(paneEditor, "Editor"), pane(paneFlow, "Flow")], weight = 2.0),
    column([pane(paneState, "State"), pane(paneCalltrace, "Call Trace")],
           weight = 1.0)]))

const
  AllShapes = ["bare pane", "two-pane row", "stacked", "two stacks",
               "deep tree", "with docked"]

  AllZones = [dzTabStrip, dzCentre, dzLeftEdge, dzRightEdge, dzTopEdge,
              dzBottomEdge, dzOutsideLeft, dzOutsideRight, dzOutsideTop,
              dzOutsideBottom, dzRootLeft, dzRootRight, dzRootTop,
              dzRootBottom]

proc shape(name: string): Layout =
  case name
  of "bare pane": barePane()
  of "two-pane row": twoPaneRow()
  of "stacked": stackedLayout()
  of "two stacks": twoStacks()
  of "deep tree": deepTree()
  of "with docked": withDocked()
  else: initLayout(nil)

proc panePathsAux(node: LayoutNode; prefix: string; acc: var seq[string]) =
  ## Collects. Contains no `check` — see the header's trap-13 note.
  if node.isNil:
    return
  if node.kind == lnPane:
    acc.add(prefix)
    return
  for i, c in node.children:
    panePathsAux(c, (if prefix.len == 0: $i else: prefix & "/" & $i), acc)

proc panePaths(l: Layout): seq[string] =
  result = @[]
  panePathsAux(l.tree, "", result)

proc dividersAux(node: LayoutNode; prefix: string;
                 acc: var seq[(string, int)]) =
  ## Collects every (container path, divider index) of a tree. No `check`.
  if node.isNil or node.kind == lnPane:
    return
  if node.kind in {lnRow, lnColumn}:
    for d in 0 ..< node.children.len - 1:
      acc.add((prefix, d))
  for i, c in node.children:
    dividersAux(c, (if prefix.len == 0: $i else: prefix & "/" & $i), acc)

proc dividers(l: Layout): seq[(string, int)] =
  result = @[]
  dividersAux(l.tree, "", result)

proc weightsOf(l: Layout; containerPath: string): seq[float] =
  ## The effective weights of a container's children, read off the tree.
  result = @[]
  let c = nodeAtPath(l.tree, containerPath)
  if not c.isNil:
    for child in c.children:
      result.add(effectiveWeight(child))

proc renderTargets(targets: seq[DropTarget]): string =
  ## A stable rendering of a whole candidate list, for byte comparison.
  var parts: seq[string] = @[]
  for t in targets:
    parts.add($t)
  parts.join(" | ")

# ---------------------------------------------------------------------------
# Two media, one pointer. These are the front-end's half of §5's second
# obligation — "turn a pointer into a node path" — written twice on purpose,
# once in pixels and once in cells, over the same toy geometry. They exist so
# the suite can demonstrate that the model below them cannot tell which one
# called it. NEITHER IS A MOCK: they stand in for nothing, they are the
# medium-specific half that PLAT-6 will write for real.
# ---------------------------------------------------------------------------

type
  PixelPoint = object
    x, y: int
  CellPoint = object
    col, row: int

const
  PixelWidth = 1200
  PixelHeight = 800
  CellColumns = 120
  CellRows = 40

proc zoneFromFractions(fx, fy: float): DropZone =
  ## The one geometric rule, shared by both hit-tests below: an outer eighth
  ## on any side is that side's strip, the top twentieth is the tab strip, and
  ## the rest is the body.
  if fx < 0.0: return dzOutsideLeft
  if fx >= 1.0: return dzOutsideRight
  if fy < 0.0: return dzOutsideTop
  if fy >= 1.0: return dzOutsideBottom
  if fy < 0.05: return dzTabStrip
  if fx < 0.125: return dzLeftEdge
  if fx > 0.875: return dzRightEdge
  if fy < 0.2: return dzTopEdge
  if fy > 0.8: return dzBottomEdge
  dzCentre

proc hitTestPixels(path: string; p: PixelPoint): LayoutPointer =
  LayoutPointer(path: path,
                zone: zoneFromFractions(p.x / PixelWidth, p.y / PixelHeight))

proc hitTestCells(path: string; c: CellPoint): LayoutPointer =
  LayoutPointer(path: path,
                zone: zoneFromFractions(c.col / CellColumns,
                                        c.row / CellRows))

# ---------------------------------------------------------------------------
# §4.1 — the transient machine is a separate type and never touches the
# committed layout
# ---------------------------------------------------------------------------

suite "Interaction — separate from Layout, structurally (§4.1)":

  test "no persisted layout type carries a transient interaction field":
    # The leak this catches is the one that COMPILES: a `hover: string` or a
    # `dragging: bool` on `Layout`. The leak that names the real type cannot
    # compile at all, and the next case is what asserts that.
    #
    # `revealed` is deliberately NOT on this list. Layout-ViewModel §3.2 puts
    # it on `DockedPane` for locality and keeps it out of `toJson`; PLAT-5's
    # answer is that this module never writes it.
    #
    # THAT ONE IS HELD UP BY THE SIGNATURES, NOT BY A CASE BELOW, and saying so
    # matters because the obvious reading is wrong. Every routine in
    # `layout_interaction` takes `layout: Layout` BY VALUE and `docked` is a
    # `seq` of values inside it, so `layout.docked[at].revealed = true` does
    # not compile at all — Nim rejects it with "cannot be assigned to".
    # Neither of the two checks that look like they cover it actually could:
    # the byte comparison cannot see `revealed` because `toJson` omits it
    # (§3.2), and the `revealed == false` assertion in the reveal case below
    # is over the CALLER's copy, which a write inside a value parameter could
    # not reach either way. The guarantee is real and it is stronger than an
    # assertion; it is just not an assertion.
    const Transient = ["hover", "hovered", "interaction", "drag", "dragging",
                       "pointer", "dropTarget", "dropTargets", "zone",
                       "proposed", "gesture", "origin"]
    var checkedFields = 0
    var offenders: seq[string] = @[]
    var node = pane(paneEditor)
    for name, _ in node[].fieldPairs:
      inc checkedFields
      if name in Transient:
        offenders.add("LayoutNode." & name)
    var dock = DockedPane(pane: paneEditor, edge: leLeft, order: 0)
    for name, _ in dock.fieldPairs:
      inc checkedFields
      if name in Transient:
        offenders.add("DockedPane." & name)
    var lay = initLayout(pane(paneEditor))
    for name, _ in lay.fieldPairs:
      inc checkedFields
      if name in Transient:
        offenders.add("Layout." & name)
    checkpoint("offending fields: " & offenders.join(", "))
    check offenders.len == 0
    # Positive control (Verification-Harness-Traps §4): a walk that visited
    # nothing would report no offenders either.
    # PLAT-9 added `LayoutNode.contributedPane`, so the node's arity is 7.
    # PLAT-48 added `DockedPane.beside` (the pane it was docked from),
    # `DockedPane.weight` (its share there) and `DockedPane.besideBefore`
    # (which side of `beside`), so the docked pane's is 8 — where it goes
    # back to, never where it is drawn. PLAT-49 part B added `DockedPane.open`
    # (docked OPEN, inline at its edge: a state a command sets, like
    # `revealed` not persisted, and no extent — the binding derives the band),
    # so the docked pane's arity is 9.
    check checkedFields == 7 + 9 + 3

  test "layout_model names none of the transient types, and cannot":
    # `layout_interaction` imports `layout_model`; the reverse import is a
    # cycle Nim rejects, so a `Layout` field of type `Interaction` is not a
    # review question. This reads the module's own source to say so, and the
    # positive control is what stops a mistyped path from passing vacuously.
    const modelSource = staticRead("../../../headless_app/layout_model.nim")
    check modelSource.len > 10_000
    check modelSource.contains("Layout* = object")   # we read the right file
    for name in ["layout_interaction", "Interaction", "DropTarget",
                 "LayoutPointer", "DropRegion", "InteractionKind"]:
      checkpoint("looking for '" & name & "' in layout_model.nim")
      check not modelSource.contains(name)

  test "a cancelled drag leaves the committed layout byte-identical":
    # BYTES, not a summary. `$saveLayout` is the document a shell persists,
    # and comparing it is the only comparison that would notice a field this
    # test does not know about.
    for name in AllShapes:
      let committed = shape(name)
      let before = $saveLayout(committed)
      let treeBefore = committed.tree
      for source in committed.allPanes():
        var started = beginDragTab(committed, source)
        check started.isSome
        if started.isNone:
          continue
        var gesture = started.get
        for path in panePaths(committed):
          for zone in AllZones:
            gesture = gesture.hoverAt(committed,
                                      LayoutPointer(path: path, zone: zone))
        let ended = cancel(gesture)
        check ended.kind == ikNone
        checkpoint(name & " / " & $source)
        check $saveLayout(committed) == before
        # Not merely equal bytes: the same tree object, never rebuilt.
        check committed.tree == treeBefore

  test "cancel has no layout to change":
    # The signature IS the guarantee. A `cancel` that could reach a layout
    # would need one in scope.
    let gesture = beginDragTab(twoPaneRow(), paneState)
    check gesture.isSome
    if gesture.isSome:
      check compiles(cancel(gesture.get))
      check not compiles(cancel(gesture.get, twoPaneRow()))
      check cancel(gesture.get).kind == ikNone

  test "revealing a dock does not write revealed on the committed layout":
    let committed = withDocked()
    let before = $saveLayout(committed)
    check committed.docked.len == 1
    let revealing = beginReveal(committed, paneEventLog)
    check revealing.isSome
    if revealing.isSome:
      check revealing.get.kind == ikRevealingDock
      check revealing.get.edge == leBottom
      check revealing.get.isRevealed(paneEventLog)
      check not revealing.get.isRevealed(paneState)
      # The authority moved; the committed field stayed false.
      #
      # This comparison STATES the invariant rather than guarding it, and the
      # difference is worth a line: `beginReveal` takes its layout by value, so
      # no write inside it could reach `committed` and no mutation of it can
      # make this line fail. The guard is the signature — see the field-walk
      # case above. The next line, over the serialised bytes, IS a guard: it is
      # what catches a write through `Layout.tree`, which is a `ref` and does
      # escape.
      check committed.docked[0].revealed == false
      check $saveLayout(committed) == before
      # And committing a reveal issues nothing: pinning is `cmdRestoreDocked`,
      # an explicit command, not something a hover can decide.
      check commit(committed, revealing.get).isNone
    check beginReveal(committed, paneEditor).isNone

  test "a drag records where it came from, for all three origins":
    let stacked = stackedLayout()
    let fromStack = beginDragTab(stacked, paneState)
    check fromStack.isSome
    if fromStack.isSome:
      check fromStack.get.origin.kind == doStack
      check fromStack.get.origin.stackPath == "1"
      check fromStack.get.origin.index == 0
    let fromRegion = beginDragTab(stacked, paneEditor)
    check fromRegion.isSome
    if fromRegion.isSome:
      check fromRegion.get.origin.kind == doRegion
      check fromRegion.get.origin.regionPath == "0"
    let docked = withDocked()
    let fromDock = beginDragTab(docked, paneEventLog)
    check fromDock.isSome
    if fromDock.isSome:
      check fromDock.get.origin.kind == doDock
      check fromDock.get.origin.dockEdge == leBottom
    check beginDragTab(stacked, paneScratchpad).isNone

# ---------------------------------------------------------------------------
# §4.2 — the drop-target model, computed with no pointing device
# ---------------------------------------------------------------------------

suite "dropTargetsFor — pure, and medium-free (§4.2)":

  test "a LayoutPointer cannot carry a measurement":
    # The "would not compile" form the milestone asks for. A pixel pointer and
    # a cell cursor are different measurements of the same thing; a pointer
    # type that could hold either would have to pick one to be wrong about.
    let l = twoPaneRow()
    check compiles(dropTargetsFor(l, paneState,
                                  LayoutPointer(path: "0", zone: dzCentre)))
    check not compiles(LayoutPointer(path: "0", zone: dzCentre, x: 4))
    check not compiles(LayoutPointer(x: 3, y: 9))
    check not compiles(LayoutPointer(column: 3, row: 9))
    check not compiles(dropTargetsFor(l, paneState, 12))
    check not compiles(dropTargetsFor(l, paneState, 4, 9))

  test "no field of a pointer or a region is a measurement":
    var checkedFields = 0
    var offenders: seq[string] = @[]
    var p = LayoutPointer(path: "0", zone: dzCentre)
    for name, value in p.fieldPairs:
      inc checkedFields
      when value is SomeNumber:
        offenders.add("LayoutPointer." & name)
    # Every region shape, so the walk sees every branch of the variant.
    var whole = DropRegion(kind: drWholeNode, path: "0")
    for name, value in whole.fieldPairs:
      inc checkedFields
      when value is SomeFloat:
        offenders.add("DropRegion(whole)." & name)
    var strip = DropRegion(kind: drNodeStrip, path: "0", side: leLeft)
    for name, value in strip.fieldPairs:
      inc checkedFields
      when value is SomeFloat:
        offenders.add("DropRegion(strip)." & name)
    var slot = DropRegion(kind: drTabSlot, path: "1", slot: 2)
    for name, value in slot.fieldPairs:
      inc checkedFields
      when value is SomeFloat:
        offenders.add("DropRegion(slot)." & name)
    checkpoint("offending fields: " & offenders.join(", "))
    check offenders.len == 0
    # Positive control. LayoutPointer has 2; the three regions have
    # (path, kind) = 2, (path, kind, side) = 3, (path, kind, slot) = 3.
    check checkedFields == 2 + 2 + 3 + 3

  test "a pixel hit-test and a cell hit-test agree, byte for byte":
    # One implementation serving both media, demonstrated rather than
    # asserted about the source: two INDEPENDENT front-end halves, in
    # different units, reduced to the same `LayoutPointer` and therefore to
    # the same candidate list.
    let l = stackedLayout()
    var compared = 0
    for path in panePaths(l):
      for spot in [(0.02, 0.5), (0.5, 0.5), (0.95, 0.5), (0.5, 0.02),
                   (0.5, 0.95), (0.5, 0.1)]:
        let pixels = hitTestPixels(path, PixelPoint(
          x: int(spot[0] * PixelWidth.float),
          y: int(spot[1] * PixelHeight.float)))
        let cells = hitTestCells(path, CellPoint(
          col: int(spot[0] * CellColumns.float),
          row: int(spot[1] * CellRows.float)))
        checkpoint(path & " @ " & $spot & " -> " & $pixels.zone & " / " &
                   $cells.zone)
        check pixels.zone == cells.zone
        check renderTargets(dropTargetsFor(l, paneEditor, pixels)) ==
              renderTargets(dropTargetsFor(l, paneEditor, cells))
        inc compared
    # Positive control: a loop that compared nothing would pass too.
    check compared == 3 * 6

  test "every candidate offered is a candidate apply accepts":
    # The list is "the places this drag can land", so a caller may highlight
    # all of it without re-checking. That property is only worth having if it
    # is asserted against the ALGEBRA rather than against a restated rule.
    var considered = 0
    for name in AllShapes:
      let l = shape(name)
      for source in l.allPanes():
        for path in panePaths(l):
          for zone in AllZones:
            let pointer = LayoutPointer(path: path, zone: zone)
            for target in dropTargetsFor(l, source, pointer):
              inc considered
              let cmd = commandFor(l, source, target)
              checkpoint(name & " / " & $source & " / " & path & " / " &
                         $zone & " -> " & $target)
              check cmd.isSome
              if cmd.isSome:
                check apply(l, cmd.get).kind != loRefused
    checkpoint("candidates considered: " & $considered)
    check considered > 0

  test "the hovered target is always one of the candidates":
    var hovered = 0
    for name in AllShapes:
      let l = shape(name)
      for source in l.allPanes():
        for path in panePaths(l):
          for zone in AllZones:
            let pointer = LayoutPointer(path: path, zone: zone)
            let hit = hoveredTarget(l, source, pointer)
            if hit.isNone:
              continue
            inc hovered
            var found = false
            for target in dropTargetsFor(l, source, pointer):
              if target == hit.get:
                found = true
            checkpoint(name & " / " & $source & " / " & path & " / " &
                       $zone & " -> " & $hit.get)
            check found
    checkpoint("hovered targets seen: " & $hovered)
    check hovered > 0

  test "every DropTarget kind is reachable, and each shape says which":
    # The milestone's "every DropTarget kind against every structural shape".
    # The per-shape expectation is written out rather than summed, because a
    # shape reaching FEWER kinds than it should is the interesting failure and
    # a total would hide it.
    var perShape: seq[string] = @[]
    var everywhere: HashSet[DropTargetKind]
    everywhere.init()
    for name in AllShapes:
      let l = shape(name)
      var kinds: HashSet[DropTargetKind]
      kinds.init()
      for source in l.allPanes():
        for path in panePaths(l):
          for zone in AllZones:
            for target in dropTargetsFor(
                l, source, LayoutPointer(path: path, zone: zone)):
              kinds.incl(target.kind)
              everywhere.incl(target.kind)
      var listed: seq[string] = @[]
      for k in DropTargetKind:
        if k in kinds:
          listed.add($k)
      perShape.add(name & "=[" & listed.join(",") & "]")
    checkpoint(perShape.join("  "))
    # A bare pane is the one shape that offers NOTHING, and the refusals that
    # make that true are asserted by kind in the next suite.
    # PLAT-49 part B: every other shape offers the root split too
    # (GoldenLayout's ground side areas).
    check perShape[0] == "bare pane=[]"
    check perShape[1] ==
      "two-pane row=[intoStack,splitBefore,splitAfter,dockEdge,splitRoot]"
    check perShape[2] ==
      "stacked=[intoStack,splitBefore,splitAfter,dockEdge,splitRoot]"
    check perShape[3] ==
      "two stacks=[intoStack,splitBefore,splitAfter,dockEdge,splitRoot]"
    check perShape[4] ==
      "deep tree=[intoStack,splitBefore,splitAfter,dockEdge,splitRoot]"
    check perShape[5] ==
      "with docked=[intoStack,splitBefore,splitAfter,dockEdge,splitRoot]"
    for k in DropTargetKind:
      check k in everywhere

  test "a pointer over a container, or over nothing, offers nothing":
    let l = deepTree()
    # "1" is the inner row: a container has no region that is not some pane's,
    # so a hit-test landing on one is not a drop location. The source is a
    # pane the row does NOT hold, so a container that leaked through would
    # produce candidates rather than being refused for an unrelated reason —
    # a flat record's `pane` field defaults to `PaneKind.low`, and a check
    # dragging `paneEditor` would be satisfied by the duplicate refusal.
    check dropTargetsFor(l, paneCalltrace,
                         LayoutPointer(path: "1", zone: dzCentre)).len == 0
    check dropTargetsFor(l, paneCalltrace,
                         LayoutPointer(path: "9/9", zone: dzCentre)).len == 0
    check dropTargetsFor(l, paneCalltrace,
                         LayoutPointer(path: "x", zone: dzCentre)).len == 0
    # A pane the layout does not have is not being dragged.
    check dropTargetsFor(l, paneScratchpad,
                         LayoutPointer(path: "0", zone: dzCentre)).len == 0

  test "paths round-trip against the model's own spelling":
    let l = deepTree()
    for path in panePaths(l):
      let node = nodeAtPath(l.tree, path)
      check not node.isNil
      if not node.isNil:
        check node.kind == lnPane
        check nodePath(l.tree, node) == some(path)
        check panePath(l, node.pane) == some(path)
    check nodePath(l.tree, l.tree) == some("")
    check nodeAtPath(l.tree, "") == l.tree
    check panePath(l, paneScratchpad).isNone

# ---------------------------------------------------------------------------
# §4.2 — refusals, asserted as refusals
# ---------------------------------------------------------------------------

suite "dropTargetsFor — refusals asserted as refusals (§4.2)":

  test "the only pane of a layout can be dragged nowhere, and each refusal says why":
    let l = barePane()
    let gesture = beginDragTab(l, paneEditor)
    check gesture.isSome
    for zone in AllZones:
      check dropTargetsFor(l, paneEditor,
                           LayoutPointer(path: "", zone: zone)).len == 0
    # Not "no candidate appeared" — the reason, by kind, from the algebra.
    checkRefused apply(l, cmdDock(paneEditor, leLeft)), lpEmptyRoot
    checkRefused apply(l, cmdMergeIntoStack(paneEditor, paneEditor)),
      lpDuplicatePane
    checkRefused apply(l, cmdSplitMove(paneEditor, paneEditor, saRow)),
      lpDuplicatePane
    checkRefused apply(l, cmdSplitRootMove(paneEditor, saRow)), lpEmptyRoot

  test "a docked pane is split into the tree in one command":
    # PLAT-5 recorded this gesture as MISSING: `lcSplit` refused a docked
    # source, and restore-then-split is two commands, which §4.3 forbids this
    # layer to sequence. PLAT-4's closing pass (2026-09-26) made the decision
    # it was waiting on — `splitMovesPane` takes the pane from the strip as
    # well as from the tree — so the absence this case used to assert is now
    # a presence, over EVERY pane and EVERY edge, each one applied.
    let l = withDocked()
    check l.dockedIndex(paneEventLog) >= 0
    var offered = 0
    for path in panePaths(l):
      # `dropTargetsFor` offers a node's FOUR edge strips whichever zone the
      # pointer is in (the zone picks the hovered one), so one zone per node.
      block:
        var splits = 0
        for target in dropTargetsFor(l, paneEventLog,
                                     LayoutPointer(path: path, zone: dzLeftEdge)):
          if target.kind notin {dtSplitBefore, dtSplitAfter}:
            continue
          inc splits
          let cmd = commandFor(l, paneEventLog, target)
          check cmd.isSome
          if cmd.isNone:
            continue
          check cmd.get.kind == lcSplit
          check cmd.get.splitMovesPane
          let outcome = apply(l, cmd.get)
          checkpoint($target & " -> " & $outcome)
          checkApplied outcome
          if outcome.kind == loApplied:
            checkValid outcome.layout
            check outcome.layout.placement(paneEventLog) == plPlaced
            check outcome.layout.docked.len == 0
            # The strip's title travels with the pane, as `ahRestore`'s does.
            check outcome.layout.tree.find(paneEventLog).title == "Event Log"
        checkpoint("path " & path & ": " & $splits & " split target(s)")
        # Four edge strips, four split targets, every one of them legal.
        check splits == 4
        offered += splits
    check offered == 4 * panePaths(l).len
    # What is STILL refused, by kind: the non-moving split keeps "must not be
    # in the layout", a pane that is nowhere cannot be moved, and a layout
    # that already breaks §3.3 (both placed AND docked) is not guessed at.
    checkRefused apply(l, cmdSplit(paneEditor, paneEventLog, saRow)),
      lpPaneBothPlacedAndDocked
    checkRefused apply(l, cmdSplitMove(paneEditor, paneShell, saRow)),
      lpPaneNotPlaced
    let both = Layout(tree: stackedLayout().tree, docked: @[DockedPane(
      pane: paneEventLog, title: "Event Log", edge: leBottom, order: 0)],
      version: LayoutSchemaVersion)
    checkRefused apply(both, cmdSplitMove(paneEditor, paneEventLog, saRow)),
      lpPaneBothPlacedAndDocked

  test "a docked pane is offered every tab slot, the first included":
    # PLAT-5 recorded this as deliberate: `ahRestore` places AFTER an anchor,
    # so a docked pane had no command reaching a stack's first slot, and slot
    # 0 was not offered. The closing pass (2026-09-27) gave `lcMoveTab` a
    # docked source — PLAT-4's `splitMovesPane` decision, applied to the tab
    # strip — so the absence this case used to assert is now a presence, over
    # EVERY slot, each one committed, applied, validated and landed where the
    # slot says.
    let l = dockedBesideStacks()
    check l.placement(paneFlow) == plDocked
    var slots: seq[int] = @[]
    for zone in AllZones:
      for target in dropTargetsFor(l, paneFlow,
                                   LayoutPointer(path: "1/0", zone: zone)):
        if target.kind == dtIntoStack and target.index notin slots:
          slots.add(target.index)
    checkpoint("slots offered to the docked pane: " & $slots)
    check slots == @[0, 1, 2]
    var landed = 0
    for slot in slots:
      let target = DropTarget(kind: dtIntoStack, stackAnchor: paneState,
                              index: slot,
                              region: DropRegion(kind: drTabSlot, path: "1",
                                                 slot: slot))
      let cmd = commandFor(l, paneFlow, target)
      check cmd.isSome
      if cmd.isNone:
        continue
      check cmd.get.kind == lcMoveTab
      check cmd.get.moveIndex == slot
      let outcome = apply(l, cmd.get)
      checkpoint("slot " & $slot & " -> " & $outcome)
      checkApplied outcome
      if outcome.kind == loApplied:
        checkValid outcome.layout
        check outcome.layout.docked.len == 0
        let stackNode = nodeAtPath(outcome.layout.tree, "1")
        check stackNode.kind == lnStack
        check stackNode.children.len == 3
        check stackNode.children[slot].pane == paneFlow
        check stackNode.activeIndex == slot
        # The strip's title travels with the pane.
        check stackNode.children[slot].title == "Flow"
        inc landed
    check landed == 3
    # The body of a BARE pane is offered too, and makes a two-tab stack.
    let bare = withDocked()   # Editor is a bare pane, Event Log is docked
    var merges = 0
    for target in dropTargetsFor(bare, paneEventLog,
                                 LayoutPointer(path: "0", zone: dzCentre)):
      if target.kind != dtIntoStack:
        continue
      inc merges
      let cmd = commandFor(bare, paneEventLog, target)
      check cmd.isSome
      if cmd.isSome:
        check cmd.get.kind == lcMergeIntoStack
        let outcome = apply(bare, cmd.get)
        checkApplied outcome
        if outcome.kind == loApplied:
          checkValid outcome.layout
          let merged = nodeAtPath(outcome.layout.tree, "0")
          check merged.kind == lnStack
          check merged.children.len == 2
          check merged.children[1].pane == paneEventLog
          check merged.children[1].title == "Event Log"
          check outcome.layout.docked.len == 0
    check merges == 1
    # What is STILL refused, by kind: an index past the end, a pane that is
    # nowhere, and a layout already breaking §3.3 (placed AND docked).
    checkRefused apply(l, cmdMoveTab(paneFlow, paneState, 3)),
      lpIndexOutOfRange
    checkRefused apply(l, cmdMoveTab(paneFlow, paneState, -1)),
      lpIndexOutOfRange
    checkRefused apply(l, cmdMoveTab(paneShell, paneState, 0)),
      lpPaneNotPlaced
    checkRefused apply(bare, cmdMergeIntoStack(paneShell, paneEditor)),
      lpPaneNotPlaced
    let both = Layout(tree: twoStacks().tree, docked: @[DockedPane(
      pane: paneFlow, title: "Flow", edge: leLeft, order: 0)],
      version: LayoutSchemaVersion)
    checkRefused apply(both, cmdMoveTab(paneFlow, paneState, 0)),
      lpPaneBothPlacedAndDocked
    checkRefused apply(both, cmdMergeIntoStack(paneFlow, paneState)),
      lpPaneBothPlacedAndDocked

  test "moving a tab out of its own stack at an index that does not exist is refused":
    let l = stackedLayout()
    # The stack has two tabs, so the in-stack indices are 0 and 1; slot 2 is
    # an insertion point only for a pane arriving from elsewhere.
    checkRefused apply(l, cmdMoveTab(paneState, paneState, 2)),
      lpIndexOutOfRange
    var slots: seq[int] = @[]
    for target in dropTargetsFor(l, paneState,
                                 LayoutPointer(path: "1/0", zone: dzTabStrip)):
      if target.kind == dtIntoStack:
        slots.add(target.index)
    checkpoint("slots offered: " & $slots)
    check slots == @[0, 1]
    # And a pane arriving from outside the stack gets the third slot.
    var outside: seq[int] = @[]
    for target in dropTargetsFor(l, paneEditor,
                                 LayoutPointer(path: "1/0", zone: dzTabStrip)):
      if target.kind == dtIntoStack:
        outside.add(target.index)
    check outside == @[0, 1, 2]

  test "dropping a whole tabbed region into a tab is refused by kind":
    # §8 decision 1, reached from PLAT-5's side: the gesture stays
    # EXPRESSIBLE so it can be refused rather than silently reinterpreted.
    let l = twoStacks()
    checkRefused apply(l, cmdMergeIntoStack(paneEditor, paneState,
                                            wholeRegion = true)),
      lpStackChildNotPane

# ---------------------------------------------------------------------------
# §4.3 — commit and cancel
# ---------------------------------------------------------------------------

suite "commit — a command, or nothing (§4.3)":

  test "a drag ending where it began commits none, and pushes no undo entry":
    let committed = stackedLayout()
    var history = newLayoutHistory(committed)
    let started = beginDragTab(committed, paneState)
    check started.isSome
    if started.isSome:
      # Slot 0 of its own stack is exactly where State already is.
      let gesture = started.get.hoverAt(
        committed, LayoutPointer(path: "1/0", zone: dzTabStrip))
      check gesture.hover.isSome
      if gesture.hover.isSome:
        check gesture.hover.get.kind == dtIntoStack
        check gesture.hover.get.index == 0
      # The gesture HAS a command; it is the command that does nothing.
      let pending = pendingCommand(committed, gesture)
      check pending.isSome
      if pending.isSome:
        checkpoint("pending: " & $pending.get)
        checkNoOp apply(committed, pending.get)
      let produced = commit(committed, gesture)
      check produced.isNone
      if produced.isSome:
        discard history.dispatch(produced.get)
      check history.log.len == 0
      check not history.canUndo()
      check $history.value == $committed

  test "a split-drop that reproduces the same tree commits none too":
    # The tab case is `lcMoveTab`'s own `loNoOp`. This is the OTHER shape of
    # "ending where it began": dragging the right-hand pane of an evenly split
    # row back onto the right-hand edge of its neighbour rebuilds the tree it
    # already had, and `apply` says so — which is why `commit` does not have
    # to.
    let committed = initLayout(row([pane(paneEditor, "Editor"),
                                    pane(paneState, "State")]))
    var history = newLayoutHistory(committed)
    let gesture = beginDragTab(committed, paneState).get.hoverAt(
      committed, LayoutPointer(path: "0", zone: dzRightEdge))
    check gesture.hover.isSome
    if gesture.hover.isSome:
      check gesture.hover.get.kind == dtSplitAfter
    let pending = pendingCommand(committed, gesture)
    check pending.isSome
    if pending.isSome:
      check pending.get.kind == lcSplit
      check pending.get.splitMovesPane
      checkNoOp apply(committed, pending.get)
    check commit(committed, gesture).isNone
    check history.log.len == 0
    # The mirror case, so this is not a test that any split is a no-op.
    let moved = beginDragTab(committed, paneState).get.hoverAt(
      committed, LayoutPointer(path: "0", zone: dzLeftEdge))
    let producedMove = commit(committed, moved)
    check producedMove.isSome
    if producedMove.isSome:
      checkApplied apply(committed, producedMove.get)

  test "commit's none and apply's loNoOp agree, over every candidate":
    # The milestone's instruction: check the two AGREE rather than each having
    # its own idea of "nothing happened". They agree by construction — commit
    # asks apply — and this is the sweep that says so is true in fact.
    var agreed = 0
    var noOps = 0
    for name in AllShapes:
      let l = shape(name)
      for source in l.allPanes():
        for path in panePaths(l):
          for zone in AllZones:
            let pointer = LayoutPointer(path: path, zone: zone)
            let hit = hoveredTarget(l, source, pointer)
            if hit.isNone:
              continue
            var gesture = beginDragTab(l, source).get
            gesture = gesture.hoverAt(l, pointer)
            let cmd = pendingCommand(l, gesture)
            check cmd.isSome
            if cmd.isNone:
              continue
            let outcome = apply(l, cmd.get)
            let produced = commit(l, gesture)
            checkpoint(name & " / " & $source & " / " & path & " / " &
                       $zone & " -> " & $cmd.get & " => " & $outcome)
            check produced.isSome == (outcome.kind == loApplied)
            if outcome.kind == loNoOp:
              inc noOps
              check produced.isNone
            inc agreed
    checkpoint("compared " & $agreed & ", of which loNoOp: " & $noOps)
    check agreed > 0
    # Positive control for the interesting half: if no candidate anywhere was
    # a no-op, the `loNoOp` arm above never ran and this test would be an
    # assertion about `loApplied` alone.
    check noOps > 0

  test "committing every DropTarget kind produces the command it names":
    let stacked = stackedLayout()

    # dtIntoStack — into an existing stack, from outside it.
    block:
      let gesture = beginDragTab(stacked, paneEditor).get.hoverAt(
        stacked, LayoutPointer(path: "1/0", zone: dzTabStrip))
      check gesture.hover.isSome
      let produced = commit(stacked, gesture)
      check produced.isSome
      if produced.isSome:
        check produced.get.kind == lcMoveTab
        let outcome = apply(stacked, produced.get)
        checkApplied outcome
        if outcome.kind == loApplied:
          checkValid outcome.layout
          check outcome.layout.tree.contains(paneEditor)

    # dtIntoStack — onto a bare pane, which becomes a two-tab stack.
    block:
      let l = twoPaneRow()
      let gesture = beginDragTab(l, paneState).get.hoverAt(
        l, LayoutPointer(path: "0", zone: dzCentre))
      check gesture.hover.isSome
      let produced = commit(l, gesture)
      check produced.isSome
      if produced.isSome:
        check produced.get.kind == lcMergeIntoStack
        let outcome = apply(l, produced.get)
        checkApplied outcome
        if outcome.kind == loApplied:
          checkValid outcome.layout
          check outcome.layout.tree.kind == lnStack

    # dtSplitBefore / dtSplitAfter, on both axes.
    for spec in [(dzLeftEdge, ssBefore, saRow), (dzRightEdge, ssAfter, saRow),
                 (dzTopEdge, ssBefore, saColumn),
                 (dzBottomEdge, ssAfter, saColumn)]:
      let l = deepTree()
      let gesture = beginDragTab(l, paneCalltrace).get.hoverAt(
        l, LayoutPointer(path: "1/0", zone: spec[0]))
      checkpoint("zone " & $spec[0])
      check gesture.hover.isSome
      if gesture.hover.isSome:
        check gesture.hover.get.axis == spec[2]
      let produced = commit(l, gesture)
      check produced.isSome
      if produced.isSome:
        check produced.get.kind == lcSplit
        check produced.get.splitMovesPane
        check produced.get.splitSide == spec[1]
        check produced.get.splitAxis == spec[2]
        let outcome = apply(l, produced.get)
        checkApplied outcome
        if outcome.kind == loApplied:
          checkValid outcome.layout
          check outcome.layout.allPanes().len == l.allPanes().len

    # dtDockEdge, on each of the four edges.
    for edge in [(dzOutsideLeft, leLeft), (dzOutsideRight, leRight),
                 (dzOutsideTop, leTop), (dzOutsideBottom, leBottom)]:
      let gesture = beginDragTab(stacked, paneEventLog).get.hoverAt(
        stacked, LayoutPointer(path: "", zone: edge[0]))
      checkpoint("zone " & $edge[0])
      check gesture.hover.isSome
      let produced = commit(stacked, gesture)
      check produced.isSome
      if produced.isSome:
        check produced.get.kind == lcSetAutoHide
        check produced.get.autoHideDirection == ahDock
        check produced.get.autoHideEdge == edge[1]
        let outcome = apply(stacked, produced.get)
        checkApplied outcome
        if outcome.kind == loApplied:
          checkValid outcome.layout
          check outcome.layout.placement(paneEventLog) == plDocked

    # dtIntoStack — a DOCKED pane dragged back into a stack. The body of the
    # tabbed region is "append a tab", the slot past the last one; the
    # command is `lcMoveTab` from the strip, the same one a placed pane gets.
    block:
      let l = withDocked()
      let gesture = beginDragTab(l, paneEventLog).get.hoverAt(
        l, LayoutPointer(path: "1/0", zone: dzCentre))
      check gesture.hover.isSome
      if gesture.hover.isSome:
        check gesture.hover.get.kind == dtIntoStack
      let produced = commit(l, gesture)
      check produced.isSome
      if produced.isSome:
        check produced.get.kind == lcMoveTab
        check produced.get.movedPane == paneEventLog
        check produced.get.moveIndex == 1
        let outcome = apply(l, produced.get)
        checkApplied outcome
        if outcome.kind == loApplied:
          checkValid outcome.layout
          check outcome.layout.placement(paneEventLog) == plPlaced
          check outcome.layout.docked.len == 0

  test "a committed drag is the only thing that reaches the undo log":
    let committed = stackedLayout()
    var history = newLayoutHistory(committed)
    # One gesture that does nothing, then one that does.
    let idle = beginDragTab(committed, paneState).get.hoverAt(
      committed, LayoutPointer(path: "1/0", zone: dzTabStrip))
    let idleCmd = commit(committed, idle)
    check idleCmd.isNone
    let real = beginDragTab(history.value, paneEditor).get.hoverAt(
      history.value, LayoutPointer(path: "1/0", zone: dzTabStrip))
    let realCmd = commit(history.value, real)
    check realCmd.isSome
    if realCmd.isSome:
      checkApplied history.dispatch(realCmd.get)
    check history.log.len == 1
    check history.canUndo()
    check history.undo()
    check $history.value == $committed

  test "an interaction that is not dragging commits nothing":
    let l = stackedLayout()
    check commit(l, noInteraction()).isNone
    check pendingCommand(l, noInteraction()).isNone
    # A drag that was started and never hovered has landed on nothing.
    let started = beginDragTab(l, paneState)
    check started.isSome
    if started.isSome:
      check started.get.hover.isNone
      check commit(l, started.get).isNone
    # And hovering over nothing clears an earlier hover rather than keeping it.
    if started.isSome:
      let over = started.get.hoverAt(
        l, LayoutPointer(path: "0", zone: dzRightEdge))
      check over.hover.isSome
      let away = over.hoverAt(l, LayoutPointer(path: "1", zone: dzCentre))
      check away.hover.isNone
      check commit(l, away).isNone

# ---------------------------------------------------------------------------
# §4.1 — resizing a split
# ---------------------------------------------------------------------------

suite "Interaction — resizing a split (§4.1)":

  test "a resize proposes weights and commits one setWeight":
    let l = twoPaneRow()
    let started = beginResize(l, paneEditor)
    check started.isSome
    if started.isSome:
      var gesture = started.get
      check gesture.kind == ikResizingSplit
      check gesture.node == "0"
      check gesture.proposed == @[3.0, 1.0]
      # Proposing the share it already has is not a change.
      check commit(l, gesture).isNone
      gesture = gesture.proposeShare(l, 0.5)
      check gesture.proposed.len == 2
      check gesture.proposed[1] == 1.0        # the sibling is untouched
      check abs(gesture.proposed[0] - 1.0) < 1e-9
      let produced = commit(l, gesture)
      check produced.isSome
      if produced.isSome:
        check produced.get.kind == lcSetWeight
        check produced.get.weightTarget == paneEditor
        let outcome = apply(l, produced.get)
        checkApplied outcome
        if outcome.kind == loApplied:
          checkValid outcome.layout
          check outcome.layout.tree.find(paneEditor).weight ==
                gesture.proposed[0]
    # The committed layout was never touched by any of it.
    check l.tree.find(paneEditor).weight == 3.0

  test "a resize proposal is clamped, and never asks for a zero share":
    let l = twoPaneRow()
    let started = beginResize(l, paneEditor)
    check started.isSome
    if started.isSome:
      for share in [-5.0, 0.0, 1.0, 7.0]:
        let gesture = started.get.proposeShare(l, share)
        checkpoint("share " & $share & " -> " & $gesture.proposed)
        check gesture.proposed[0] > 0.0
        let produced = commit(l, gesture)
        check produced.isSome
        if produced.isSome:
          checkApplied apply(l, produced.get)

  test "there is nothing to resize against a stack, a root, or an absent pane":
    # Tabs share one region, so there is no divider between them: refusing at
    # `beginResize` is what stops a front-end from drawing a guide for a
    # gesture that cannot commit.
    check beginResize(stackedLayout(), paneState).isNone
    check beginResize(barePane(), paneEditor).isNone
    check beginResize(twoPaneRow(), paneScratchpad).isNone
    check beginResize(deepTree(), paneEditor).isSome
    # And a proposal on a non-resize interaction is a no-op on the value.
    let idle = noInteraction()
    check idle.proposeShare(twoPaneRow(), 0.5).kind == ikNone
    check idle.hoverAt(twoPaneRow(),
                       LayoutPointer(path: "0", zone: dzCentre)).kind == ikNone

# ---------------------------------------------------------------------------
# §4.3 — dragging ONE divider. PLAT-5 recorded "a resize moves one node's
# share against its siblings, not a divider between two" as a documented
# generalisation; the closing pass (2026-09-27) makes the divider drag a
# gesture of its own, still committing ONE command.
# ---------------------------------------------------------------------------

suite "Interaction — dragging one divider (§4.3)":

  test "a divider drag moves the two weights beside it and no other":
    let l = threeInARow()
    let before = $saveLayout(l)
    # The divider between State (child 1) and Flow (child 2).
    let started = beginResizeDivider(l, "", 1)
    check started.isSome
    if started.isSome:
      check started.get.kind == ikResizingSplit
      check started.get.node == "1"
      check started.get.divider == some(ssAfter)
      check started.get.proposed == @[1.0, 1.0, 1.0]
      # Where the divider already is (two thirds along) commits none, and
      # `apply` agrees that it is a no-op.
      let still = started.get.proposeDivider(l, 2.0 / 3.0)
      check still.proposed == @[1.0, 1.0, 1.0]
      check commit(l, still).isNone
      let stillCmd = pendingCommand(l, still)
      check stillCmd.isSome
      if stillCmd.isSome:
        checkNoOp apply(l, stillCmd.get)
      # The same move asked as a SHARE of the row: the neighbour absorbs it
      # too, rather than every sibling.
      let byShare = started.get.proposeShare(l, 0.5 / 3.0)
      checkpoint($byShare)
      check byShare.proposed.len == 3
      check byShare.proposed[0] == 1.0
      check abs(byShare.proposed[1] - 0.5) < 1e-9
      check abs(byShare.proposed[2] - 1.5) < 1e-9
      # Halfway along the row: State shrinks to half a share, Flow takes it.
      let moved = started.get.proposeDivider(l, 0.5)
      checkpoint($moved)
      check moved.proposed == @[1.0, 0.5, 1.5]
      let produced = commit(l, moved)
      check produced.isSome
      if produced.isSome:
        check produced.get.kind == lcSetWeight
        check produced.get.weightTarget == paneState
        check produced.get.weightDivider == some(ssAfter)
        check produced.get.weightLevel == 0
        let outcome = apply(l, produced.get)
        checkApplied outcome
        if outcome.kind == loApplied:
          checkValid outcome.layout
          # Every weight is the proposal's — and the one NOT beside the
          # divider is exactly what it was, which is the whole claim.
          check weightsOf(outcome.layout, "") == moved.proposed
          check weightsOf(outcome.layout, "")[0] == 1.0
    # The SAME share asked of the one-node resize moves the far pane too:
    # this is the difference, measured rather than described.
    let shared = beginResize(l, paneState)
    check shared.isSome
    if shared.isSome:
      let proposal = shared.get.proposeShare(l, 0.5 / 3.0)
      let cmd = commit(l, proposal)
      check cmd.isSome
      if cmd.isSome:
        let o = apply(l, cmd.get)
        checkApplied o
        if o.kind == loApplied:
          let w = weightsOf(o.layout, "")
          let editorShare = w[0] / (w[0] + w[1] + w[2])
          checkpoint("editor share after a one-node resize: " & $editorShare)
          check abs(editorShare - 1.0 / 3.0) > 0.01
    # And none of it touched the committed layout.
    check $saveLayout(l) == before

  test "a divider between stacks, or between whole containers, is draggable":
    # `beginResize` names a PANE and refuses a tab; a divider is named by its
    # container and index, so the two sides may be stacks or nested rows —
    # the default layout's tabbed region included. The command stays
    # pane-named: the node is `weightLevel` levels above a pane's leaf.
    for spec in [("two stacks", 1), ("row of columns", 1), ("deep tree", 0),
                 ("default", 0)]:
      let l =
        case spec[0]
        of "two stacks": twoStacks()
        of "row of columns": rowOfColumns()
        of "deep tree": deepTree()
        else: initLayout(defaultReplayLayout())
      let container =
        if spec[0] == "default": "1/1" else: ""
      let started = beginResizeDivider(l, container, 0)
      checkpoint(spec[0] & " @ '" & container & "'")
      check started.isSome
      if started.isNone:
        continue
      let moved = started.get.proposeDivider(l, 0.3)
      let produced = commit(l, moved)
      check produced.isSome
      if produced.isNone:
        continue
      checkpoint($produced.get)
      check produced.get.weightLevel == spec[1]
      let outcome = apply(l, produced.get)
      checkApplied outcome
      if outcome.kind == loApplied:
        checkValid outcome.layout
        let after = weightsOf(outcome.layout, container)
        check after.len == moved.proposed.len
        for i in 0 ..< after.len:
          check abs(after[i] - moved.proposed[i]) < 1e-9
        # The divider sits where it was asked to: 30% along the container.
        var total = 0.0
        for w in after:
          total += w
        check abs(after[0] / total - 0.3) < 1e-9

  test "every divider of every shape: cancelled untouched, committed as proposed":
    # The sweep form of the two claims above, over every divider the fixture
    # shapes have and five positions each — including both ends, which clamp.
    var swept = 0
    var noOps = 0
    for name in AllShapes:
      let l = shape(name)
      let bytes = $saveLayout(l)
      let treeBefore = l.tree
      for (path, d) in dividers(l):
        let started = beginResizeDivider(l, path, d)
        check started.isSome
        if started.isNone:
          continue
        for position in [-1.0, 0.0, 0.25, 0.75, 2.0]:
          let gesture = started.get.proposeDivider(l, position)
          checkpoint(name & " / '" & path & "' #" & $d & " @ " & $position &
                     " -> " & $gesture)
          # Exactly two entries may differ, and their sum is conserved.
          var changed = 0
          for i in 0 ..< gesture.proposed.len:
            if gesture.proposed[i] != started.get.proposed[i]:
              inc changed
            check gesture.proposed[i] > 0.0
          check changed in {0, 2}
          let pending = pendingCommand(l, gesture)
          check pending.isSome
          if pending.isNone:
            continue
          let outcome = apply(l, pending.get)
          let produced = commit(l, gesture)
          check produced.isSome == (outcome.kind == loApplied)
          check outcome.kind != loRefused
          if outcome.kind == loNoOp:
            inc noOps
          if outcome.kind == loApplied:
            checkValid outcome.layout
            let after = weightsOf(outcome.layout, path)
            for i in 0 ..< after.len:
              check abs(after[i] - gesture.proposed[i]) < 1e-9
          inc swept
          discard cancel(gesture)
      check $saveLayout(l) == bytes
      check l.tree == treeBefore
    checkpoint("divider proposals swept: " & $swept & ", no-ops: " & $noOps)
    # Positive controls: the fixture shapes have SEVEN dividers between them
    # (0 + 1 + 1 + 1 + 3 + 1), five positions each — and at least one
    # position is where its divider already sits (the two-pane row's 3:1 is
    # 0.75), so the `loNoOp` arm of the agreement above actually ran.
    check swept == 7 * 5
    check noOps > 0

  test "there is no divider in a stack, past either end, or at the root":
    let l = stackedLayout()
    check beginResizeDivider(l, "", 0).isSome
    check beginResizeDivider(l, "", 1).isNone       # past the last divider
    check beginResizeDivider(l, "", -1).isNone
    check beginResizeDivider(l, "1", 0).isNone      # a stack: tabs share
    check beginResizeDivider(l, "0", 0).isNone      # a pane
    check beginResizeDivider(l, "7", 0).isNone      # nothing
    check beginResizeDivider(barePane(), "", 0).isNone
    # And the command's own refusals, by kind.
    checkRefused apply(l, cmdSetDivider(paneEditor, 1.0, ssBefore)),
      lpNoDivider                                   # the first child's left
    checkRefused apply(l, cmdSetDivider(paneState, 1.0, ssAfter)),
      lpNoDivider                                   # a tab, at level 0
    checkApplied apply(l, cmdSetDivider(paneState, 0.5, ssBefore, level = 1))
    checkRefused apply(l, cmdSetDivider(paneState, 1.0, ssAfter, level = 3)),
      lpNoDivider                                   # climbed past the root
    checkRefused apply(l, cmdSetDivider(paneEditor, 1.0, ssAfter, level = -1)),
      lpNoDivider
    checkRefused apply(l, cmdSetDivider(paneEditor, 0.0, ssAfter)),
      lpNegativeWeight
    checkRefused apply(l, cmdSetDivider(paneEditor, 4.0, ssAfter)),
      lpNegativeWeight                              # squeezes State to 0
    checkRefused apply(l, cmdSetDivider(paneShell, 1.0, ssAfter)),
      lpPaneNotPlaced
    # A divider proposal on anything but a divider drag changes nothing.
    let shared = beginResize(l, paneEditor)
    check shared.isSome
    if shared.isSome:
      check shared.get.proposeDivider(l, 0.5).proposed == shared.get.proposed
    check noInteraction().proposeDivider(l, 0.5).kind == ikNone

  test "a region holding only contributed panes is dragged from its neighbour's side":
    # Every command but PLAT-9's contributed pair is typed on `PaneKind`, so a
    # contributed leaf cannot anchor `cmdSetDivider`. The SAME divider is
    # named from the other side instead, and moves the same two weights.
    let l = initLayout(row([contributedPaneNode("acme.graph", "Graph"),
                            pane(paneState, "State")]))
    let started = beginResizeDivider(l, "", 0)
    check started.isSome
    if started.isSome:
      let moved = started.get.proposeDivider(l, 0.25)
      let produced = commit(l, moved)
      check produced.isSome
      if produced.isSome:
        check produced.get.weightTarget == paneState
        check produced.get.weightDivider == some(ssBefore)
        let outcome = apply(l, produced.get)
        checkApplied outcome
        if outcome.kind == loApplied:
          let after = weightsOf(outcome.layout, "")
          check abs(after[0] - moved.proposed[0]) < 1e-9
          check abs(after[1] - moved.proposed[1]) < 1e-9

suite "the drop indication — what a front-end draws (PLAT-47)":

  test "every hovered drop maps to the region it would occupy, with no measurement":
    # GoldenLayout's drop zone, logically: a split shows the HALF on the
    # drop's side, a join the stack's tab strip at the insertion slot, a join
    # onto a bare pane the whole pane, a dock the layout edge. Swept over every
    # shape, source, pane path and zone, so each mapping is exercised where it
    # can occur.
    var seen: set[DropIndicationKind] = {}
    var checked = 0
    for name in AllShapes:
      let l = shape(name)
      for source in l.allPanes():
        let started = beginDragTab(l, source)
        if started.isNone:
          continue
        for path in panePaths(l):
          for zone in AllZones:
            let moved = started.get.hoverAt(l, LayoutPointer(path: path,
                                                             zone: zone))
            let ind = dropIndicationOf(moved)
            seen.incl ind.kind
            check ind.source == source
            if moved.hover.isNone:
              check ind.kind == diNone
              continue
            inc checked
            let t = moved.hover.get
            case t.kind
            of dtSplitBefore, dtSplitAfter:
              check ind.kind == diSplitHalf
              check ind.path == t.region.path
              check ind.axis == t.axis
              # The half is on the side the pointer's edge strip names.
              check t.region.kind == drNodeStrip
              check ind.side == t.region.side
            of dtIntoStack:
              if t.region.kind == drTabSlot:
                check ind.kind == diTabSlot
                check ind.slot == t.region.slot
              else:
                check ind.kind == diWholeNode
              check ind.path == t.region.path
            of dtDockEdge:
              check ind.kind == diLayoutEdge
              check ind.side == t.edge
            of dtSplitRoot:
              # PLAT-49 part B: a root split shows the band along that edge
              # of the whole layout (GoldenLayout's ground side area).
              check ind.kind == diRootBand
              check ind.side == t.edge
              check t.region.kind == drRootBand
    checkpoint("hovered drops checked: " & $checked)
    check checked > 100
    check seen == {diNone, diSplitHalf, diTabSlot, diWholeNode, diLayoutEdge,
                   diRootBand}

  test "nothing is indicated when nothing is dragged":
    let l = shape(AllShapes[1])
    check dropIndicationOf(noInteraction()).kind == diNone
    let resizing = beginResize(l, l.allPanes()[0])
    if resizing.isSome:
      check dropIndicationOf(resizing.get).kind == diNone

  test "a DropIndication carries no measurement":
    # PLAT-5's purity law, for the value a renderer reads: its only integer is
    # an index into the model (the tab slot), and its only string a path.
    var names: seq[string] = @[]
    for name, _ in DropIndication().fieldPairs:
      names.add name
    check names == @["kind", "source", "path", "side", "slot", "axis"]
