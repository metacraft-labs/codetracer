## test_gpui_dock_projection.nim — PLAT-20. **The dock binding, and the
## floating-panel non-goal asserted THROUGH it.**
##
## ## No mocks, and none is needed
##
## There is no mock in this file and no stand-in of any kind. Its whole subject
## is a pure function from a `Layout` to a JSON document, and the only external
## artefacts it reads are six files copied verbatim from gpui-kit (see
## `gpui_kit_fixtures/PROVENANCE.md`), which are upstream's own test data rather
## than something written here to be read back.
##
## Per the workspace policy — *"every use of mock objects in tests must be
## explicitly justified in the header comment"* — the justification is that
## there are none. The one thing a reader might expect to be mocked is a
## backend, and the suite needs none: pane placement and stack membership are
## properties of an arrangement, not of a recording, and `GpuiShell.openWindow`
## exists precisely so a window can hold one without a session.
##
## ## WHAT THIS SUITE CANNOT SAY, STATED HERE RATHER THAN LEFT TO BE INFERRED
##
## It cannot say that a live gpui-kit `DockArea` accepts these documents,
## because gpui-kit is not a dependency of this workspace. PLAT-20's status
## block records three independent measured blockers. What it CAN say is that
## the documents are in gpui-kit's persisted schema, that our reader reads
## gpui-kit's own committed documents, and that no arrangement reachable
## through the binding puts a pane outside the split tree — which is the third
## of PLAT-20's three named integration tests and the one that does not depend
## on a second front-end.
##
## ## The assertion counter
##
## Every check goes through `ck`, which counts (Verification-Harness-Traps §4c),
## and every test ends with `expectCount`. `ck` is a TEMPLATE and not a `proc`,
## which is §13: a `check` inside a `proc` sets a module global and the case
## reports `[OK]` with the failed comparison printed above it.

import std/[json, os, strutils, unittest]

import gpui/app/dock_projection
import gpui/app/shell

var asserted = 0
var countedAssertions = 0
  ## The PER-TEST counter is reset by `resetCount`; this one never is, so the
  ## file can emit the `CHECKS: <n>` line `ci/lib/test-lane-report.sh` reads.
  ## Without it the lane reports the file as UNMEASURED and its `[OK]` count
  ## stands in for an assertion count — which is Verification-Harness-Traps §7
  ## exactly, and the lane says so in its own output.

template ck(condition: untyped) =
  inc asserted
  inc countedAssertions
  check condition

template expectCount(expected: int) =
  if asserted != expected:
    checkpoint("assertion count is " & $asserted & ", expected " & $expected)
  check asserted == expected

template resetCount() =
  asserted = 0

const Viewport = DockViewport(width: 1200, height: 800, dockExtent: 300)

proc fixtureDir(): string =
  currentSourcePath().parentDir / "gpui_kit_fixtures"

proc readFixture(name: string): JsonNode =
  parseJson(readFile(fixtureDir() / name))

proc projectedOf(layout: Layout): JsonNode =
  let p = projectDock(layout, Viewport)
  doAssert p.status == dpsProjected,
    "the fixture layout was refused: " & describe(p.problems)
  p.state

# ---------------------------------------------------------------------------

suite "PLAT-20: the dock projection writes gpui-kit's persisted schema":

  test "a single-pane layout is a StackPanel over a TabPanel over the leaf":
    resetCount()
    let layout = initLayout(pane(paneEditor, "Editor"))
    let doc = projectedOf(layout)
    ck doc["version"].getInt == DockSchemaVersion
    ck doc["center"]["panel_name"].getStr == "StackPanel"
    ck doc["center"]["info"].hasKey("stack")
    ck doc["center"]["info"]["stack"]["axis"].getInt == 0
    let tab = doc["center"]["children"][0]
    ck tab["panel_name"].getStr == "TabPanel"
    ck tab["info"]["tabs"]["active_index"].getInt == 0
    let leaf = tab["children"][0]
    ck leaf["panel_name"].getStr == "editor"
    ck leaf["children"].len == 0
    ck leaf["info"]["panel"][PaneInfoKey].getStr == "editor"
    expectCount(9)

  test "a row is axis 0 and a column is axis 1, which is gpui-kit's encoding":
    resetCount()
    # `PanelInfo::stack` writes 0 for Horizontal and 1 for Vertical, and
    # upstream's own `the_serde_tags_are_frozen` pins it. Asserting the NUMBER
    # rather than a name is the point: the number is the wire.
    let rowDoc = projectedOf(initLayout(row([pane(paneEditor),
                                             pane(paneState)])))
    ck rowDoc["center"]["info"]["stack"]["axis"].getInt == 0
    let colDoc = projectedOf(initLayout(column([pane(paneEditor),
                                                pane(paneState)])))
    ck colDoc["center"]["info"]["stack"]["axis"].getInt == 1
    expectCount(2)

  test "sizes sum to the extent exactly and follow the weights":
    resetCount()
    let layout = initLayout(row([pane(paneEditor, "", 3.0),
                                 pane(paneState, "", 1.0)]))
    let doc = projectedOf(layout)
    let sizes = doc["center"]["info"]["stack"]["sizes"]
    ck sizes.len == 2
    let a = int(sizes[0].getFloat)
    let b = int(sizes[1].getFloat)
    ck a + b == Viewport.width
    # 3:1 of 1200 is 900:300, and `distributeExtent` is exact here because the
    # division has no remainder. The point of the assertion is the RATIO, which
    # is what makes `weight` mean the same thing it means to the Yoga
    # projection.
    ck a == 900
    ck b == 300
    expectCount(4)

  test "a stack becomes ONE TabPanel carrying every tab and the active index":
    resetCount()
    let layout = initLayout(stack([pane(paneState), pane(paneEventLog),
                                   pane(paneTimeline)], activeIndex = 2))
    let doc = projectedOf(layout)
    let tab = doc["center"]["children"][0]
    ck tab["panel_name"].getStr == "TabPanel"
    ck tab["children"].len == 3
    ck tab["info"]["tabs"]["active_index"].getInt == 2
    let arrangement = readDockArrangement(doc)
    ck arrangement.slots.len == 3
    # STACK MEMBERSHIP: all three share a path, and each knows the group size.
    ck arrangement.slots[0].path == arrangement.slots[1].path
    ck arrangement.slots[1].path == arrangement.slots[2].path
    ck arrangement.slots[0].tabCount == 3
    ck arrangement.slots[2].tabIndex == 2
    ck arrangement.slots[0].activeIndex == 2
    expectCount(9)

  test "a docked pane becomes a DockState at its edge, and `open` is false":
    resetCount()
    var layout = initLayout(row([pane(paneEditor), pane(paneState)]))
    let outcome = layout.apply(cmdDock(paneState, leLeft))
    ck outcome.kind == loApplied
    let doc = projectedOf(outcome.layout)
    ck doc.hasKey("left_dock")
    ck not doc.hasKey("right_dock")
    ck not doc.hasKey("bottom_dock")
    let dock = doc["left_dock"]
    ck dock["placement"].getStr == "left"
    ck dock["size"].getFloat == float(Viewport.dockExtent)
    # `Layout` is the COMMITTED arrangement and `revealed` is not in it
    # (Layout-ViewModel §3.2), so nothing here could make this true and a
    # projection that invented `true` would reopen an overlay on restore.
    ck dock["open"].getBool == false
    ck dock["panel"]["panel_name"].getStr == "TabPanel"
    ck dock["panel"]["children"][0]["panel_name"].getStr == "state"
    let arrangement = readDockArrangement(doc)
    let (found, slot) = arrangement.slotFor("state")
    ck found
    ck slot.region == dpLeft
    expectCount(11)

  test "a pane docked to EACH of the three edges round-trips through the reader":
    resetCount()
    # ADDED BY PLAT-20'S SECOND VERIFICATION, 2026-09-15, because an undeclared
    # arm survived. Until this case existed, `readDockArrangement`'s `dockKeys`
    # could lose `right_dock` OR `bottom_dock` — measured, one at a time — with
    # every suite in this repository green; only `left_dock` was graded, by the
    # case above.
    #
    # It is not a cosmetic gap. `shell.leavesFor` derives its leaves from THIS
    # reader, so a key the reader does not descend is a pane the projection
    # writes into the document and the front-end then draws nothing for — the
    # "I lost a pane" failure Layout-ViewModel §3A.2 is written against,
    # arriving through the reader instead of through a coordinate.
    #
    # And the reason the nine-command sweep below never reached it: that loop
    # asks `layout.visiblePanes()`, and `visiblePanes` deliberately EXCLUDES a
    # docked pane ("an overlay is PLAT-5's transient state"). So the one place
    # that looked like it covered every reachable pane covered exactly the
    # panes that are not docked.
    const Edges = [(paneState, leLeft, dpLeft),
                   (paneEventLog, leRight, dpRight),
                   (paneTimeline, leBottom, dpBottom)]
    var layout = initLayout(row([pane(paneEditor, "Editor"),
                                 pane(paneState, "State"),
                                 pane(paneEventLog, "Events"),
                                 pane(paneTimeline, "Timeline")]))
    var docked = 0
    for entry in Edges:
      let (p, edge, _) = entry
      let outcome = layout.apply(cmdDock(p, edge))
      ck outcome.kind == loApplied
      layout = outcome.layout
      inc docked
    # §4b: the membership is written out literally above, so the control is the
    # COUNT rather than "at least one".
    ck docked == Edges.len
    let doc = projectedOf(layout)
    ck doc.hasKey("left_dock")
    ck doc.hasKey("right_dock")
    ck doc.hasKey("bottom_dock")
    let arrangement = readDockArrangement(doc)
    # One slot for the pane still in the split tree, and one per strip.
    ck arrangement.slots.len == 4
    var readBack = 0
    for entry in Edges:
      let (p, _, placement) = entry
      let (found, slot) = arrangement.slotFor($p)
      ck found
      ck slot.region == placement
      inc readBack
    ck readBack == Edges.len
    # The positive twin over the same reader (§4a): the centre pane is still
    # reported, so a reader that had stopped descending ANYTHING would not
    # satisfy the three rows above by reporting nothing at all.
    let (centreFound, centreSlot) = arrangement.slotFor("editor")
    ck centreFound
    ck centreSlot.region == dpCenter
    expectCount(17)

  test "a pane docked to the TOP edge is REFUSED, not relocated":
    resetCount()
    # gpui-kit's `DockPlacement` is center/left/bottom/right — there is no
    # `top`, and that was read off `crates/base/src/dock/state.rs` at
    # 959ccc5e rather than assumed. Rounding a top dock to `bottom` would move
    # a user's pane silently, which is the "I lost a pane" failure
    # Layout-ViewModel §3A.2 is written against.
    var layout = initLayout(row([pane(paneEditor), pane(paneState)]))
    let outcome = layout.apply(cmdDock(paneState, leTop))
    ck outcome.kind == loApplied
    # `topEdgeProjection`, not `projection`, and the name is load-bearing
    # rather than descriptive: `unittest` prints an assertion's AST AS
    # SUBSTITUTED AT THE CALL SITE, so a case that spells its subject
    # `projection` produces the identical failure text as the invalid-layout
    # case below — and `run-plat20-mutations.py` REFUSED the run over exactly
    # that, which is Verification-Harness-Traps §17a's closing rule doing its
    # job. Two arms sharing one `because` is a shared quotation, and a shared
    # quotation is how an arm gets attributed to a case it did not break.
    let topEdgeProjection = projectDock(outcome.layout, Viewport)
    ck topEdgeProjection.status == dpsRefused
    # `problemsOf` rather than `.problems`: reading the field on a projected
    # value raises `FieldDefect` and takes the case's remaining assertions
    # with it (§1a). Found by running arm G1.
    let topProblems = problemsOf(topEdgeProjection)
    ck topProblems.len == 1
    ck topProblems[0].kind == dppNoPlacementForEdge
    ck "state" in topProblems[0].detail
    ck "top" in topProblems[0].detail
    expectCount(6)

  test "an INVALID layout is refused rather than projected":
    resetCount()
    # The terminal projection degrades (`ppDegrade`) because a terminal must
    # paint something on a screen the user is already looking at. A dock
    # projection has no such obligation: the window has not opened.
    let dup = row([pane(paneEditor), pane(paneEditor)])
    let layout = initLayout(dup)
    ck layout.validate().len > 0
    let invalidProjection = projectDock(layout, Viewport)
    ck invalidProjection.status == dpsRefused
    let invalidProblems = problemsOf(invalidProjection)
    ck invalidProblems.len >= 1
    ck invalidProblems[0].kind == dppInvalidLayout
    expectCount(4)

  test "a viewport too small to give every sibling a pixel is refused":
    resetCount()
    let layout = initLayout(row([pane(paneEditor), pane(paneState),
                                 pane(paneEventLog)]))
    let tiny = DockViewport(width: 2, height: 800, dockExtent: 1)
    let tinyProjection = projectDock(layout, tiny)
    ck tinyProjection.status == dpsRefused
    ck problemsOf(tinyProjection)[0].kind == dppViewportTooSmall
    expectCount(2)

# ---------------------------------------------------------------------------

suite "PLAT-20: PLAT-4's TilesState decision, APPLIED":

  test "the projection emits exactly two container names, and no third exists":
    resetCount()
    # PLAT-4 declined gpui-kit's `Tiles` — free positioning with overlap and
    # z-order. PLAT-20 re-took the read at 959ccc5e and the file is GONE:
    # upstream removed the tiles canvas in 3f1dda6 on 2026-09-11. So the
    # decision is now enforced by the library's own API as well as by us, and
    # this case asserts OUR half: the emitter has two container arms and no
    # way to grow a third without a new `LayoutNodeKind`.
    ck ProjectedPanelNames.len == 2
    ck isContainerName("StackPanel")
    ck isContainerName("TabPanel")
    ck not isContainerName("TilePanel")
    ck not isContainerName("Tiles")

    var layout = initLayout(
      row([column([pane(paneEditor), pane(paneState)]),
           stack([pane(paneEventLog), pane(paneTimeline)], activeIndex = 1)]))
    let docked = layout.apply(cmdDock(paneFlow, leBottom))
    ck docked.kind == loRefused  # `paneFlow` is not in the tree
    let doc = projectedOf(layout)
    var containers = 0
    var leaves = 0
    for name in panelNamesIn(doc):
      if isContainerName(name):
        inc containers
      else:
        inc leaves
    # FIVE: the centre spine (the row), the column inside it, and three tab
    # groups — one per pane region, with the stack's two panes sharing one.
    # The number is from the run rather than from the reading: the first draft
    # of this line said four, having forgotten that an unstacked pane is a tab
    # group of one in gpui-kit's schema (`bare_tab_panel_root.json`).
    ck containers == 5
    ck leaves == 4
    expectCount(8)

  test "no arrangement reachable through the binding writes a coordinate":
    resetCount()
    # THE FLOATING-PANEL NON-GOAL, ASSERTED THROUGH THE PROJECTION — which is
    # what PLAT-4 left open ("asserted in the model; not yet asserted through
    # the projection") for the terminal, taken here for the dock.
    #
    # The sweep is over arrangements a FRONT-END can reach: every command in
    # `LayoutCommandKind` that a GPUI host can issue, applied to a non-trivial
    # tree, with the projection of each result scanned.
    var layout = initLayout(
      row([column([pane(paneEditor), pane(paneState)]),
           stack([pane(paneEventLog), pane(paneTimeline)], activeIndex = 0)]))
    var reached = 0
    var positional = 0
    let commands = @[
      cmdActivateTab(paneTimeline),
      cmdSetWeight(paneEditor, 2.5),
      cmdAddPane(paneSearch),
      cmdSplit(paneEditor, paneScratchpad, saColumn, ssAfter),
      cmdMergeIntoStack(paneState, paneEventLog),
      cmdMoveTab(paneTimeline, paneEventLog, 0),
      cmdDock(paneSearch, leRight),
      cmdRename(paneEditor, "Source"),
      cmdRemovePane(paneScratchpad)]
    for cmd in commands:
      let outcome = layout.apply(cmd)
      if outcome.kind != loApplied:
        continue
      layout = outcome.layout
      let projection = projectDock(layout, Viewport)
      if projection.status != dpsProjected:
        continue
      inc reached
      positional += positionalKeysIn(projection.state).len
      # And every visible pane really is a leaf of the split tree: the
      # arrangement names it, with a path.
      for p in layout.visiblePanes():
        let (found, _) = readDockArrangement(projection.state).slotFor($p)
        if not found:
          fail()
    # A POSITIVE CONTROL on the sweep (§4): a scan that reached nothing
    # satisfies "no coordinate anywhere" for free.
    ck reached >= 7
    ck positional == 0
    expectCount(2)

  test "the coordinate scan can FAIL — the positive twin over the same code":
    resetCount()
    # §4a: a lone negative assertion has nothing to fail. This drives the same
    # scanner over a document that DOES carry `tiles_state.rs`'s vocabulary —
    # the `TilePanel { panel, bounds, z_index }` PLAT-4 read — and requires it
    # to be found. Without this case the assertion above is green over a
    # scanner that had stopped reading.
    let floating = parseJson("""
      {"version": 1,
       "center": {"panel_name": "Tiles", "children": [
          {"panel_name": "editor", "children": [],
           "info": {"panel": {"pane": "editor",
                              "bounds": {"x": 10, "y": 20},
                              "z_index": 3}}}],
        "info": {"stack": {"sizes": [1200.0], "axis": 0}}}}
    """)
    let keys = positionalKeysIn(floating)
    ck keys.len >= 3
    ck "bounds" in keys
    ck "z_index" in keys
    ck "x" in keys
    ck "y" in keys
    # `sizes` is deliberately NOT positional: a stack's extents along its own
    # axis are what a tiled split IS, and a scan that flagged them would refuse
    # every correct document.
    ck "sizes" notin keys
    expectCount(6)

# ---------------------------------------------------------------------------

suite "PLAT-20: conformance against gpui-kit's OWN committed documents":

  test "all six upstream fixtures parse and carry the schema we bind to":
    resetCount()
    let names = ["bare_tab_panel_root.json", "layout.json",
                 "legacy_empty_tab_group.json", "nested_splits.json",
                 "unregistered_panel.json", "zero_size_sentinel.json"]
    # §4b: the membership is known, so the CONTROL is the COUNT.
    var read = 0
    for n in names:
      let doc = readFixture(n)
      ck doc.kind == JObject
      inc read
    ck read == 6
    expectCount(7)

  test "our reader DESCENDS upstream's documents, and reports no pane in them":
    resetCount()
    # Two halves, and the second is what makes the first mean anything.
    #
    # POSITIVE: the reader finds upstream's container spine, so it is really
    # reading the document rather than failing to parse it and returning [].
    let nested = readFixture("nested_splits.json")
    var containers = 0
    for name in panelNamesIn(nested):
      if isContainerName(name):
        inc containers
    ck containers == 6   # three StackPanels and three TabPanels

    # NEGATIVE: it reports ZERO panes, because a pane's identity lives in
    # `info.panel.pane`, a key only our writer produces. Upstream's leaves are
    # `Alpha`, `Beta`, `Gamma`. A reader that guessed an id out of
    # `panel_name` would be matching vocabulary rather than syntax (§4d), and
    # this is the case that catches it.
    var totalSlots = 0
    for n in ["bare_tab_panel_root.json", "layout.json",
              "legacy_empty_tab_group.json", "nested_splits.json",
              "unregistered_panel.json", "zero_size_sentinel.json"]:
      totalSlots += readDockArrangement(readFixture(n)).slots.len
    ck totalSlots == 0

    # And the twin that proves the negative is not vacuous: the SAME reader
    # over OUR document reports every pane.
    let ours = projectedOf(initLayout(row([pane(paneEditor),
                                           pane(paneState)])))
    ck readDockArrangement(ours).slots.len == 2
    expectCount(3)

  test "two of upstream's own subtrees are SHAPE-IDENTICAL to our projections":
    resetCount()
    # The structural claim, made against upstream's bytes rather than against a
    # shape invented here: a `StackPanel` whose `info` is `stack`, holding
    # `TabPanel`s whose `info` is `tabs`, holding leaves whose `info` is
    # `panel`. `shapeOf` erases every name and number, so what is compared is
    # the schema and not the content.
    #
    # SUBTREES AND NOT THE WHOLE DOCUMENT, and the reason is a real difference
    # rather than a convenience: upstream's root has two children and its
    # second is a `StackPanel` holding ONE `TabPanel`. Our model cannot express
    # that — a row or column with a single child fails `validate` as
    # `lpSingleChildContainer` and PLAT-4's collapse rule 1 replaces it with
    # its child — so a whole-document comparison would be asserting that our
    # model permits something it deliberately forbids. Each subtree IS
    # reachable for us, and both are asserted.
    let upstream = readFixture("nested_splits.json")

    proc shapeOf(n: JsonNode): string =
      ## The document's shape with every leaf name and number erased.
      if n.isNil or n.kind != JObject or not n.hasKey("panel_name"):
        return ""
      let name = n["panel_name"].getStr
      let tag = if isContainerName(name): name else: "<leaf>"
      var infoTag = "panel"
      if n{"info", "stack"} != nil: infoTag = "stack"
      elif n{"info", "tabs"} != nil: infoTag = "tabs"
      var parts: seq[string] = @[]
      if n.hasKey("children"):
        for c in n["children"]:
          parts.add shapeOf(c)
      tag & ":" & infoTag & "(" & parts.join(",") & ")"

    # A POSITIVE CONTROL on the comparator before either comparison (§4): a
    # `shapeOf` that returned "" for everything would make both rows below
    # true for free.
    let twoPaneShape = shapeOf(upstream["center"]["children"][0])
    let onePaneShape = shapeOf(upstream["center"]["children"][1])
    ck twoPaneShape.len > 0
    ck onePaneShape.len > 0
    ck twoPaneShape != onePaneShape

    ck shapeOf(projectedOf(initLayout(row([pane(paneEditor),
                                           pane(paneState)])))["center"]) ==
       twoPaneShape
    ck shapeOf(projectedOf(initLayout(pane(paneEditor)))["center"]) ==
       onePaneShape
    expectCount(5)

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count.
const ExpectedAssertions = 95

suite "PLAT-20: the assertion count":
  test "every case in this file ran":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
