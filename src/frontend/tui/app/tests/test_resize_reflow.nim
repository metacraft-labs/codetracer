## test_resize_reflow.nim — CTUI-3, Tier 1.
##
## ## What this asserts
##
## CodeTracer-TUI.milestones.org, CTUI-3: "resizes 80x24 -> 140x45 in ten
## increments via `h.resize`, asserting after each that the invariants above
## still hold and that no coordinate drifts."
##
## Eleven waypoints (a start plus ten increments), and at each one:
##
##   * the projection is still a faithful partition of the body, checked over
##     the cell grid;
##   * the composited screen is `rows` strings of exactly `cols` cells;
##   * every cell of the new screen is what the model says it is — which is
##     what "no stale cells" means at Tier 1;
##   * the geometry is a FUNCTION OF THE SIZE and of nothing else, established
##     by walking the same waypoints backwards and requiring identical
##     rectangles. That is the "no coordinate drifts" clause: a projection that
##     carried state between frames would produce a different answer on the way
##     down.
##
## ## WHAT THIS FILE DELIBERATELY DOES NOT TEST, AND WHERE THAT IS TESTED
##
## `h.resize()` IS NOT A SIGNAL. It is a method call on an in-process harness;
## no SIGWINCH is delivered, no `ioctl` runs, and `host/resize.nim` is not
## involved. docs/tui-testing.md says so in its own table, and CTUI-3 says it
## again: "this is the only place SIGWINCH is genuinely exercised; `h.resize`
## does not deliver a signal".
##
## This file could not import `host/resize.nim` even if it wanted to. It lives
## under `app/`, and `src/frontend/tui/tests/test_tui_facade_boundary.nim`
## walks every `.nim` file under that directory — including this one — and
## fails on any edge into `host/` or into `std/posix`. That is the milestone's
## instruction respected structurally rather than by agreement: the real signal
## is asserted in `tests/real_terminal/test_real_shell_geometry.nim`, through a
## real pty and a real `setWindowSize`.
##
## ## No mocks
##
## The harness composites into a real `ScreenBuffer` through the real
## compositor. Nothing here is faked and no debugger is involved.
##
## ## Templates, not procs, for anything that calls `check`
##
## See `test_layout_profiles.nim`'s header.

import std/[strutils, unicode, unittest]

import isonim_tui

import headless_app/layout_model
import codetracer_embed

import ../layout/profile
import ../layout/project
import ../views/shell

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 506

const
  Waypoints = [
    (cols: 80, rows: 24), (cols: 86, rows: 26), (cols: 92, rows: 28),
    (cols: 98, rows: 31), (cols: 104, rows: 33), (cols: 110, rows: 35),
    (cols: 116, rows: 37), (cols: 122, rows: 39), (cols: 128, rows: 41),
    (cols: 134, rows: 43), (cols: 140, rows: 45)]
    ## 80x24 -> 140x45 in ten increments, as the milestone specifies. The
    ## widths step evenly by six; the heights step by two and three so the
    ## sequence crosses the 35-row height clause of §3.2 in the middle rather
    ## than at an endpoint, which is where a breakpoint test is worth anything.

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

proc rowText(h: TerminalTestHarness; row, width: int): string =
  result = ""
  for col in 0 ..< width:
    result.add $h.cellAt(row, col).rune

proc demoModel(width, height: int): ShellModel =
  newShellModel(width, height, initHeaderModel(
    traceName = "demo.ct", targetArch = "x86_64", recordingKind = "native",
    status = esStepping, tick = 1420, totalTicks = 8950))

proc geometryOf(proj: Projection): string =
  ## Every pane and its rectangle, as one comparable string. Comparing this
  ## between the forward and backward passes is what "no coordinate drifts"
  ## reduces to.
  var parts: seq[string] = @[]
  for r in proj.regions:
    parts.add $r.pane & "=" & $r.area
  parts.join(",")

suite "CTUI-3: reflow across ten resize increments":

  test "the invariants hold at every one of the eleven waypoints":
    var model = demoModel(Waypoints[0].cols, Waypoints[0].rows)
    let h = newTerminalTestHarness(Waypoints[0].cols, Waypoints[0].rows)
    var visited = 0
    var profileChanges = 0
    var checkedRows = 0
    var staleCells = 0
    for w in Waypoints:
      inc visited
      # THE REFLOW, in the order a real front-end performs it: the terminal's
      # size changes, the profile is re-selected, and the tree is rebuilt for
      # the new size. `h.resize` alone repaints the OLD tree into a new buffer,
      # which is exactly the stale screen the last assertion in this case is
      # written against.
      if model.reprofile(w.cols, w.rows):
        inc profileChanges
      h.resize(w.cols, w.rows)
      h.mount(proc(r: TerminalRenderer): TerminalNode =
        renderShellTree(model, r, w.cols, w.rows))

      let body = bodyArea(w.cols, w.rows)
      let proj = projectLayout(model.layout, body)
      let found = coverageProblems(proj.regions, body)
      if found.len > 0:
        checkpoint($w.cols & "x" & $w.rows & ": " & describe(found))
      ck proj.status == prOk
      ck found.len == 0
      ck coveredCells(proj.regions, body) == body.cellCount()
      ck proj.visiblePaneKinds() == visiblePanes(model.layout)

      let screen = model.shellScreen(w.cols, w.rows)
      ck screen.rows.len == w.rows
      for row in 0 ..< w.rows:
        inc checkedRows
        if textCells(screen.rows[row]) != w.cols:
          checkpoint($w.cols & "x" & $w.rows & " row " & $row & " is " &
                     $textCells(screen.rows[row]) & " cells")
        ck textCells(screen.rows[row]) == w.cols
        # NO STALE CELLS: the composited buffer at the NEW size is what the
        # model says, cell for cell. A repaint that left the previous, larger
        # frame's content in the cells beyond the new content would show up
        # here and nowhere else at this tier.
        if rowText(h, row, w.cols) != screen.rows[row]:
          inc staleCells
    checkpoint("waypoints " & $visited & ", profile changes " &
               $profileChanges & ", rows checked " & $checkedRows &
               ", stale rows " & $staleCells)
    ck visited == 11
    ck checkedRows == 24 + 26 + 28 + 31 + 33 + 35 + 37 + 39 + 41 + 43 + 45
    ck staleCells == 0
    # EXACTLY THREE default changes over the walk — one per fold depth the walk
    # crosses (4 -> 3 -> 2 -> 0, measured in the next case). Asserting the
    # COUNT rather than "at least one" is what catches a `reprofile` that
    # rebuilt the tree on every frame — which would also reset the active tab
    # on every frame.
    ck profileChanges == 3
    h.dispose()

  test "the default changes where the fold depth does, and not before":
    # PLAT-45: the default is the shared arrangement folded for the size, so
    # it changes exactly where `depthFor` answers differently — measured, not
    # tabulated: the source pane's 60-cell minimum folds 80x24 four times,
    # and each few columns more gives regions back until 116x37 needs none.
    var changedAt: seq[string] = @[]
    var previous = depthFor(pmDebug, Waypoints[0].cols, Waypoints[0].rows)
    ck previous == 4
    for i in 1 ..< Waypoints.len:
      let w = Waypoints[i]
      let now = depthFor(pmDebug, w.cols, w.rows)
      if now != previous:
        changedAt.add $w.cols & "x" & $w.rows & " -> depth " & $now
      previous = now
    checkpoint("transitions: " & changedAt.join(", "))
    ck changedAt.len == 3
    ck changedAt[0] == "92x28 -> depth 3"
    ck changedAt[2] == "116x37 -> depth 0"
    # The waypoint before it, and the same width a little shorter: the fold
    # is decided by the cells, not by one axis.
    ck depthFor(pmDebug, 110, 35) == 2
    ck depthFor(pmDebug, 116, 37) == 0
    ck previous == 0

  test "no coordinate drifts: the walk backwards reproduces the walk forwards":
    # THE DRIFT ARM. A projection that carried state between frames — a cached
    # remainder, an accumulated offset — would produce one answer on the way up
    # and a different one on the way down. Comparing the two passes is the only
    # cheap way to see that, and it is what the milestone's "no coordinate
    # drifts" asks for.
    var forward: seq[string] = @[]
    var forwardModel = demoModel(Waypoints[0].cols, Waypoints[0].rows)
    for w in Waypoints:
      discard forwardModel.reprofile(w.cols, w.rows)
      forward.add geometryOf(projectLayout(forwardModel.layout,
                                           bodyArea(w.cols, w.rows)))
    ck forward.len == Waypoints.len

    var backward = newSeq[string](Waypoints.len)
    var backwardModel = demoModel(Waypoints[^1].cols, Waypoints[^1].rows)
    for i in countdown(Waypoints.len - 1, 0):
      let w = Waypoints[i]
      discard backwardModel.reprofile(w.cols, w.rows)
      backward[i] = geometryOf(projectLayout(backwardModel.layout,
                                             bodyArea(w.cols, w.rows)))

    var matched = 0
    for i in 0 ..< Waypoints.len:
      if forward[i] == backward[i]:
        inc matched
      else:
        checkpoint($Waypoints[i].cols & "x" & $Waypoints[i].rows &
                   " drifted:\n  up:   " & forward[i] &
                   "\n  down: " & backward[i])
      ck forward[i] == backward[i]
    ck matched == Waypoints.len
    # The positive control on the comparison: the eleven geometries are not all
    # the same string, so "they matched" is a statement about eleven different
    # answers rather than about one repeated constant.
    var distinct1: seq[string] = @[]
    for f in forward:
      if f notin distinct1:
        distinct1.add f
    checkpoint("distinct geometries over the walk: " & $distinct1.len)
    ck distinct1.len == Waypoints.len

  test "a resize inside one profile band keeps the active tab":
    # The half of `reprofile` that matters to a user: dragging a window one
    # column wider must not throw away which tab they selected. A shell that
    # rebuilt the tree from the profile on every frame would look correct in
    # every screenshot and be wrong the moment somebody pressed Alt+2 first.
    # Opened at 86x26 and dragged NARROWER, so a tree that kept the opening
    # size's cell counts would be measured where it hurts (PLAT-45).
    var model = demoModel(86, 26)
    ck depthFor(pmDebug, model.profile) == depthFor(pmDebug, lpCompact)
    ck model.layout.activate(paneTimeline)
    ck isVisible(model.layout, paneTimeline)
    var widened = 0
    # Every size here needs the same four folds as 80x24 (PLAT-45), so the
    # default's arrangement does not change — only its cell shares do — and
    # the tab the user chose must survive.
    for cols in [84, 83, 82, 81, 80]:
      ck not model.reprofile(cols, 26)
      inc widened
      ck isVisible(model.layout, paneTimeline)
      ck not isVisible(model.layout, paneEventLog)
      let body = bodyArea(cols, 26)
      let proj = projectLayout(model.layout, body)
      ck coverageProblems(proj.regions, body).len == 0
      ck paneTimeline in proj.visiblePaneKinds()
      # THE SHARES FOLLOW THE SIZE even though the arrangement does not: a
      # tree that kept 86 columns' cell counts would hand the source pane
      # 62/86 of 80 columns, below its minimum.
      ck proj.regionFor(paneEditor).width >= minPaneWidth(paneEditor)
    ck widened == 5
    # And crossing to a size that needs a DIFFERENT fold does replace the tree
    # — the default is re-derived, and its event stack opens on its own first
    # tab again.
    ck model.reprofile(140, 45)
    ck model.profile == selectProfile(140, 45)
    ck isVisible(model.layout, paneEventLog)
    ck not isVisible(model.layout, paneTimeline)

  test "the reflowed screen is repainted, not merely resized":
    # `h.resize` repaints the EXISTING tree into the new buffer. For this shell
    # that tree is a list of pre-composed rows, so a resize WITHOUT a rebuild
    # leaves the old rows on the new screen — which is precisely the stale
    # frame the first case asserts against, shown here happening so that
    # assertion is known to be able to fail.
    var model = demoModel(80, 24)
    let h = newTerminalTestHarness(80, 24)
    h.mount(proc(r: TerminalRenderer): TerminalNode =
      renderShellTree(model, r, 80, 24))
    let narrow = rowText(h, 0, 80)
    ck textCells(narrow) == 80

    h.resize(140, 45)
    let stale = rowText(h, 0, 140)
    checkpoint("after resize without rebuild: '" & stale.strip() & "'")
    # The old header is still there, padded with blanks to the new width: the
    # first 80 cells are unchanged and the rest are empty.
    ck stale[0 ..< narrow.len] == narrow
    ck stale.strip() == narrow.strip()

    discard model.reprofile(140, 45)
    h.mount(proc(r: TerminalRenderer): TerminalNode =
      renderShellTree(model, r, 140, 45))
    let fresh = rowText(h, 0, 140)
    checkpoint("after rebuild: '" & fresh.strip() & "'")
    ck textCells(fresh) == 140
    ck fresh != stale
    ck fresh == model.shellRows(140, 45)[0]
    h.dispose()

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
