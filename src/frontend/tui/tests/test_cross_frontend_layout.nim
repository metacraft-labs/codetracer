## test_cross_frontend_layout.nim — PLAT-20. **The two cross-front-end
## integration tests the milestone names, run against both real projections.**
##
## PLAT-20's "Real-stack integration tests (no mocks)" asks for three, and two
## of them are here because they are the two that need BOTH front-ends in one
## process:
##
##   1. *"The same layout command sequence applied to the model produces
##      equivalent arrangements in the terminal projection and the GPUI
##      projection, compared on the model's own terms — pane placement and stack
##      membership — not on appearance."*
##   2. *"A saved layout written by one front-end restores in the other. If it
##      does not, the model is not authoritative and the milestone is not
##      done."*
##
## The third — the floating-panel non-goal through the dock binding — needs only
## the GPUI side and lives in `gpui/tests/test_gpui_dock_projection.nim`.
##
## ## No mocks, and the reason there is no backend here at all
##
## There is no mock in this file, no stub renderer and no stand-in. The
## workspace policy requires a use of one to be justified in the header; there
## is none to justify, and that is not luck. The subject is *an arrangement*,
## and an arrangement is a property of a `Layout` rather than of a recording:
## the terminal side goes through the REAL `tui/app/layout/project.projectLayout`
## (which really does run the tree through Yoga via `isonim_tui`) and the GPUI
## side through the REAL `gpui/app/dock_projection.projectDock`. Neither needs a
## `replay-server`, a `BackendService` or a pane's data, and inventing one to
## have something to inject would have made the test about the injection.
##
## ## WHY THE COMPARISON IS NOT "BOTH READ THE SAME MODEL"
##
## The cheapest way to write case 1 is to derive both sides from the `Layout`
## and observe that they agree — which is a comparison of the model with itself
## and would pass over two projections that had both stopped reading it
## (Verification-Harness-Traps §4a). So each side is read out of ITS OWN
## PROJECTION'S OUTPUT: the terminal's from the `CellArea` rectangles
## `projectLayout` returns, the GPUI side's from the JSON document `projectDock`
## returns. The two vocabularies are then reduced to one medium-independent
## one — a pairwise BEFORE relation and a tab-group size and index — and that
## reduction is what "compared on the model's own terms, not on appearance"
## means here.
##
## `test_the_comparison_can_fail` is the twin (§4a): it runs the same reduction
## over two arrangements that really do differ and requires it to report the
## difference. Without it, a reducer that returned an empty relation would make
## every agreement true for free.
##
## ## Trap 13
##
## Every helper that calls `check` is a `template`. The ones that are `proc`s
## return values and call `check` nowhere.

import std/[algorithm, json, options, sets, strutils, unittest]

import headless_app/layout_model
import headless_app/window_set

import ../app/layout/project
import ../app/layout/profile
import ../app/layout/binding

import gpui/app/dock_projection
import gpui/app/shell
import gpui/window_geometry
from gpui/chrome import ChromeGapPx

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count.
const ExpectedAssertions = 95

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Viewport = DockViewport(width: 1200, height: 800)
  Body = CellArea(col: 0, row: 0, width: 120, height: 40)

# ---------------------------------------------------------------------------
# The medium-independent vocabulary
# ---------------------------------------------------------------------------

type
  Arrangement = object
    ## What both front-ends must agree about.
    ##
    ## Three facts, and not one of them is a pixel, a cell, a colour or a
    ## title:
    ##
    ##   * `visible` — which panes occupy a region at all;
    ##   * `before`  — for each ordered pair of visible panes, whether the
    ##     first comes before the second in reading order (left of, or above).
    ##     This is the PLACEMENT half, expressed so a 120x40 cell grid and a
    ##     1200x800 pixel viewport can answer the same question;
    ##   * `group`   — for each visible pane, the size of its tab group and the
    ##     index of the active tab. This is the STACK MEMBERSHIP half.
    visible: HashSet[string]
    before: HashSet[string]
    group: seq[(string, int, int)]

proc groupSorted(a: Arrangement): seq[(string, int, int)] =
  result = a.group
  result.sort(proc (x, y: (string, int, int)): int = cmp(x[0], y[0]))

proc terminalArrangement(node: LayoutNode): Arrangement =
  ## Read out of `projectLayout`'s OWN OUTPUT — the cell rectangles — and not
  ## out of the tree it was given.
  let projection = projectLayout(node, Body)
  doAssert projection.status == prOk,
    "the terminal projection refused: " & $projection.status
  result = Arrangement(visible: initHashSet[string](),
                       before: initHashSet[string](), group: @[])
  for r in projection.regions:
    result.visible.incl $r.pane
    # `tabs` is empty for an unstacked pane; gpui-kit calls that a tab group of
    # one, so the vocabularies are reconciled HERE rather than in either
    # projection.
    let count = if r.tabs.len == 0: 1 else: r.tabs.len
    let active = if r.activeTab < 0: 0 else: r.activeTab
    result.group.add ($r.pane, count, active)
  for a in projection.regions:
    for b in projection.regions:
      if a.pane == b.pane: continue
      # Reading order over the cell grid: strictly above, or on the same rows
      # and strictly left.
      let isBefore =
        a.area.row + a.area.height <= b.area.row or
        (a.area.row < b.area.row + b.area.height and
         a.area.col + a.area.width <= b.area.col)
      if isBefore:
        result.before.incl($a.pane & "<" & $b.pane)

proc gpuiArrangement(layout: Layout): Arrangement =
  ## Read out of `projectDock`'s OWN OUTPUT — the JSON document — and not out
  ## of the `Layout` it was given.
  let projection = projectDock(layout, Viewport)
  doAssert projection.status == dpsProjected,
    "the dock projection refused: " & describe(projection.problems)
  let arrangement = readDockArrangement(projection.state)
  result = Arrangement(visible: initHashSet[string](),
                       before: initHashSet[string](), group: @[])
  # A tab group's non-active members occupy no region — the same answer
  # `visiblePanes` gives and the same one the terminal projection gives — so
  # the VISIBLE set is the active member of each group.
  var actives: seq[DockPaneSlot] = @[]
  for s in arrangement.slots:
    if s.tabIndex == s.activeIndex:
      actives.add s
      result.visible.incl s.pane
      result.group.add (s.pane, s.tabCount, s.activeIndex)
  for a in actives:
    for b in actives:
      if a.pane == b.pane: continue
      if a.region != b.region: continue
      # Document order over the container path: the first index at which the
      # two paths differ decides, and a prefix comes first.
      var i = 0
      var decided = false
      var isBefore = false
      while i < a.path.len and i < b.path.len:
        if a.path[i] != b.path[i]:
          isBefore = a.path[i] < b.path[i]
          decided = true
          break
        inc i
      if not decided:
        isBefore = a.path.len < b.path.len
      if isBefore:
        result.before.incl(a.pane & "<" & b.pane)

# ---------------------------------------------------------------------------

const CommandSequence = @[
  cmdActivateTab(paneTerminalOutput),
  cmdSetWeight(paneEditor, 2.5),
  cmdAddPane(paneSearch),
  cmdSplit(paneState, paneScratchpad, saColumn, ssAfter),
  cmdMergeIntoStack(paneSearch, paneEventLog),
  cmdActivateTab(paneEventLog),
  cmdRename(paneEditor, "Source"),
  cmdRemovePane(paneScratchpad)]
  ## ONE sequence, applied to ONE model, projected two ways. The commands are
  ## chosen to reach every shape the two projections disagree about most
  ## easily: a split, a merge into a stack, an activation inside that stack, a
  ## weight change and a removal that triggers PLAT-4's collapse rules.

proc startingLayout(): Layout =
  initLayout(
    row([column([pane(paneEditor, "Editor"), pane(paneState, "State")]),
         stack([pane(paneEventLog, "Events"), pane(paneTerminalOutput, "Terminal")],
               activeIndex = 0)]))

suite "PLAT-20: one command sequence, two projections, one arrangement":

  test "the terminal and the GPUI projections agree at every step":
    var layout = startingLayout()
    var steps = 0
    var applied = 0
    # The starting arrangement counts too: a sequence whose every command was
    # refused would otherwise compare one layout and report agreement.
    var checkpoints: seq[Layout] = @[layout]
    for cmd in CommandSequence:
      inc steps
      let outcome = layout.apply(cmd)
      if outcome.kind == loApplied:
        inc applied
        layout = outcome.layout
        checkpoints.add layout
    # §4b: the membership is KNOWN, so the control is the COUNT rather than
    # "at least one".
    ck steps == CommandSequence.len
    # EXACT, not "at least" (§4b): the membership is written out literally two
    # screens up, so a sequence in which a command silently started being
    # refused would move this number rather than sliding under a bound. All
    # eight apply today, measured by running them.
    ck applied == 8
    ck checkpoints.len == applied + 1

    var compared = 0
    for step in checkpoints:
      let terminal = terminalArrangement(step.tree)
      let gpui = gpuiArrangement(step)
      ck terminal.visible == gpui.visible
      ck terminal.before == gpui.before
      ck groupSorted(terminal) == groupSorted(gpui)
      inc compared
    ck compared == checkpoints.len

  test "the comparison CAN fail — the positive twin over the same reducer":
    # §4a. Two arrangements that really do differ, reduced by the same two
    # functions the case above trusts. Without this, a reducer that returned
    # empty sets would make every agreement above true for free.
    let a = initLayout(row([pane(paneEditor), pane(paneState)]))
    let b = initLayout(row([pane(paneState), pane(paneEditor)]))
    let termA = terminalArrangement(a.tree)
    let termB = terminalArrangement(b.tree)
    let gpuiA = gpuiArrangement(a)
    let gpuiB = gpuiArrangement(b)
    # The VISIBLE sets are equal — the same two panes — so an arrangement
    # reduced to "which panes are there" would report agreement.
    ck termA.visible == termB.visible
    # The BEFORE relation is what distinguishes them, in BOTH media.
    ck termA.before != termB.before
    ck gpuiA.before != gpuiB.before
    ck termA.before == gpuiA.before
    ck termB.before == gpuiB.before
    # And both relations are non-empty, so the inequality is not two empty
    # sets being unequal for some other reason.
    ck termA.before.len == 1
    ck gpuiA.before.len == 1

  test "a stack's INACTIVE member is placed by both and visible to neither":
    let layout = initLayout(
      row([pane(paneEditor),
           stack([pane(paneState), pane(paneEventLog)], activeIndex = 1)]))
    let terminal = terminalArrangement(layout.tree)
    let gpui = gpuiArrangement(layout)
    ck "state" notin terminal.visible
    ck "state" notin gpui.visible
    ck "eventLog" in terminal.visible
    ck "eventLog" in gpui.visible
    # But the GPUI document still PLACES it — the tab group has two members —
    # which is what "stack membership" means and what a projection that dropped
    # the inactive tab would lose.
    let doc = projectDock(layout, Viewport)
    let full = readDockArrangement(doc.state)
    ck full.slots.len == 3
    let (found, slot) = full.slotFor("state")
    ck found
    ck slot.tabCount == 2
    ck slot.activeIndex == 1

# ---------------------------------------------------------------------------

suite "PLAT-20: a layout saved by one front-end restores in the other":

  test "terminal -> GPUI, through the model's own document":
    # The terminal front-end's REAL persistence path: `LayoutBinding
    # .saveDocument`, which is what `app/layout/persistence.layoutPersistPlan`
    # writes to disk.
    var b = newLayoutBinding(startingLayout(), selectProfile(120, 40))
    var moved = 0
    for cmd in CommandSequence:
      if b.dispatch(cmd).status == lasApplied:
        inc moved
    ck moved == 8
    let document = b.saveDocument()
    ck document["version"].getInt == LayoutSchemaVersion

    # The GPUI front-end reads the SAME BYTES.
    var shell = newGpuiShell(Viewport)
    let windowId = WindowId(0)
    ck shell.openWindow(windowId, defaultReplayLayoutValue()).kind == wsApplied
    let restored = shell.restoreWindowLayout(windowId, document)
    ck restored.kind == wsApplied

    # Compared on the model's own terms, through each front-end's OWN
    # projection rather than through the document both were given.
    let terminal = terminalArrangement(b.layout.tree)
    let gpui = gpuiArrangement(shell.windows.windows[0].layout)
    ck terminal.visible == gpui.visible
    ck terminal.before == gpui.before
    ck groupSorted(terminal) == groupSorted(gpui)

  test "GPUI -> terminal, through the model's own document":
    var shell = newGpuiShell(Viewport)
    let windowId = WindowId(7)
    ck shell.openWindow(windowId, startingLayout()).kind == wsApplied
    var moved = 0
    for cmd in CommandSequence:
      if shell.applyIn(windowId, cmd).kind == wsApplied:
        inc moved
    ck moved == 8
    let document = shell.saveWindowLayout(windowId)
    ck document["version"].getInt == LayoutSchemaVersion

    var b = newLayoutBinding(defaultReplayLayoutValue(), selectProfile(120, 40))
    var problem = none(LayoutDecodeErrorKind)
    let acted = b.restoreDocument(document, problem)
    ck acted.status == lasApplied
    ck problem.isNone

    let terminal = terminalArrangement(b.layout.tree)
    let gpui = gpuiArrangement(shell.windows.windows[0].layout)
    ck terminal.visible == gpui.visible
    ck terminal.before == gpui.before
    ck groupSorted(terminal) == groupSorted(gpui)

  test "the GPUI front-end persists the MODEL, not a DockAreaState":
    # PLAT-20's risk mitigation, asserted on the bytes: *"`DockState` becomes
    # the source of truth because it is the thing the library wants to own, and
    # the model degrades into a serialisation format."*
    #
    # The document the GPUI side writes carries `layout_model`'s vocabulary and
    # none of gpui-kit's. A front-end that had started persisting its dock
    # would fail this even while the round trips above still passed between two
    # GPUI instances — which is exactly the state the mitigation names.
    var shell = newGpuiShell(Viewport)
    ck shell.openWindow(WindowId(0), startingLayout()).kind == wsApplied
    let text = $shell.saveWindowLayout(WindowId(0))
    ck "\"tree\"" in text or "\"kind\"" in text
    ck "StackPanel" notin text
    ck "TabPanel" notin text
    ck "panel_name" notin text
    ck "active_index" notin text
    # The positive twin, so the four `notin` lines above are not satisfied by
    # an empty string (§4a): the dock document for the SAME layout does carry
    # them.
    let dockText = $projectDock(shell.windows.windows[0].layout,
                                Viewport).state
    ck "StackPanel" in dockText
    ck "panel_name" in dockText

  test "a document the build cannot read is refused BY KIND, not defaulted":
    var shell = newGpuiShell(Viewport)
    ck shell.openWindow(WindowId(0), startingLayout()).kind == wsApplied
    let future = %*{"version": LayoutSchemaVersion + 5,
                    "layout": {"kind": "pane", "pane": "editor"}}
    var raised = false
    var kind = ldeNotAnObject
    try:
      discard shell.restoreWindowLayout(WindowId(0), future)
    except LayoutDecodeError as e:
      raised = true
      kind = e.kind
    ck raised
    ck kind == ldeUnknownVersion
    # And the window still holds what it held: a refused restore is not a
    # half-restore.
    ck shell.windows.windows[0].layout.visiblePanes().len ==
       startingLayout().visiblePanes().len

suite "PLAT-20: the dock's size is the model's, and every medium draws it":
  # Residue 3: `DockViewport.dockExtent` was the GPUI host's, and the
  # terminal and the window each cut an open dock's band from a constant of
  # their own. The size now lives on the docked pane (`openShare`), so ONE
  # command sizes the band in the terminal, the window and the dock
  # document, and the size survives a save and a restore.

  proc bottomDocked(share: int): Layout =
    ## The editor and the state pane, with the event log docked at the
    ## bottom and shown open; `share` 0 leaves the size unset.
    var layout = initLayout(row([pane(paneEditor), pane(paneState),
                                 pane(paneEventLog)]))
    layout = layout.apply(cmdDock(paneEventLog, leBottom)).layout
    layout = layout.apply(cmdOpenDocked(paneEventLog)).layout
    if share > 0:
      layout = layout.apply(cmdSetDockShare(paneEventLog, share)).layout
    layout

  proc terminalBand(layout: Layout): tuple[band, axis: int] =
    ## The terminal's open band, and the extent it was cut from.
    let g = geometryOf(layout, Body)
    (g.openDock.height, g.inner.height + g.openDock.height)

  proc windowBand(layout: Layout): tuple[band, axis: int] =
    ## The GPUI window's open band, and the extent it was cut from (the tree
    ## gives the band its height and a gap).
    let proj = projectDock(layout, Viewport)
    let g = windowGeometryOf(layout, proj.state, Viewport.width,
                             Viewport.height)
    (g.openDock.h, g.inner.h + g.openDock.h + ChromeGapPx)

  test "one command sizes the open dock in the terminal, the window and the document":
    let layout = bottomDocked(40)
    ck layout.docked[0].openShare == 40
    let t = terminalBand(layout)
    let w = windowBand(layout)
    checkpoint("terminal " & $t & " window " & $w)
    # Each medium against a number written here, not against the model's
    # own arithmetic: 40 % of the axis each cut its band from.
    ck t.band == t.axis * 40 div 100
    ck w.band == w.axis * 40 div 100
    let doc = projectDock(layout, Viewport).state
    ck doc["bottom_dock"]["size"].getFloat ==
       float(Viewport.height * 40 div 100)
    # The positive twin: with no size set, every medium draws a DIFFERENT
    # band — the default — so the three assertions above are not satisfied
    # by a band that ignores the model.
    let unset = bottomDocked(0)
    ck terminalBand(unset).band != t.band
    ck windowBand(unset).band != w.band
    ck terminalBand(unset).band ==
       terminalBand(unset).axis * DefaultDockOpenSharePercent div 100

  test "the size survives a save and a restore, and an old document has none":
    let layout = bottomDocked(40)
    let saved = saveLayout(layout)
    ck saved["docked"][0]{"openShare"}.getInt == 40
    let back = restoreLayoutDocument(saved)
    ck back.docked[0].openShare == 40
    # `open` is not persisted (the desktop does not persist it either), so
    # the restored pane is opened again before its band is compared.
    let reopened = back.apply(cmdOpenDocked(paneEventLog)).layout
    ck terminalBand(reopened) == terminalBand(layout)
    # An unset size is not written, so a v11 document is still the same
    # document; a v11 document migrates and takes the default.
    ck not saveLayout(bottomDocked(0))["docked"][0].hasKey("openShare")
    var old = saveLayout(bottomDocked(0))
    old["version"] = %11
    ck restoreLayoutDocument(old).docked[0].openSharePercent ==
       DefaultDockOpenSharePercent

  test "the terminal's `:resize` sizes a focused docked pane, and the window draws that size":
    var b = newLayoutBinding(bottomDocked(0), selectProfile(120, 40),
                             focus = paneEventLog)
    let act = b.runLayoutCommand(geometryOf(b.layout, Body), ":resize 40")
    checkpoint($act.status & " " & act.message)
    ck act.status == lasApplied
    ck b.layout.docked[0].openShare == 40
    ck windowBand(b.layout) == windowBand(bottomDocked(40))

  test "the size is clamped, refused for a pane that is not docked, and a no-op when unchanged":
    let big = bottomDocked(0).apply(cmdSetDockShare(paneEventLog, 99))
    ck big.kind == loApplied
    ck big.layout.docked[0].openShare == MaxDockSharePercent
    let small = bottomDocked(0).apply(cmdSetDockShare(paneEventLog, 1))
    ck small.layout.docked[0].openShare == MinDockSharePercent
    let placed = bottomDocked(0).apply(cmdSetDockShare(paneEditor, 40))
    ck placed.kind == loRefused
    ck placed.problem.kind == lpPaneNotDocked
    ck bottomDocked(40).apply(cmdSetDockShare(paneEventLog, 40)).kind == loNoOp
    # A hand-edited document cannot hand a front-end a band it has no room
    # for: the decoder clamps as the command does.
    var forged = saveLayout(bottomDocked(40))
    forged["docked"][0]["openShare"] = %500
    ck restoreLayoutDocument(forged).docked[0].openShare == MaxDockSharePercent

suite "PLAT-20: the assertion count":
  test "every case ran":
    check countedAssertions == ExpectedAssertions
