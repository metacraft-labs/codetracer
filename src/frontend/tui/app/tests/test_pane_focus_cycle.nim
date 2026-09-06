## test_pane_focus_cycle.nim — CTUI-9, Tier 1, PURE.
##
## ## What this suite is for
##
## CTUI-9: "`Tab` visits every focusable pane exactly once per cycle in a stable
## order, in all three layout profiles."
##
## Three profiles, because the profiles do not have the same panes: the Compact
## one puts Variables, Timeline and Tracepoints in a `stack` so only the active
## tab is a region, Standard shows four panes and Ultra-wide five. A cycle
## asserted at one geometry says nothing about the other two, and "exactly once"
## is the property a chain built from a stack is most likely to get wrong —
## a stack whose three children all joined the chain would visit two panes that
## are not on screen.
##
## ## THE CHAIN IS ISONIM-TUI's, AND THIS SUITE PROVES IT IS
##
## CTUI-9 asks that `isonim-tui`'s focus manager be reused rather than
## reimplemented. `app/input/motions.PaneFocus` builds a `TerminalNode` per
## VISIBLE pane and hands them to `FocusManager`; `focusOrder` reads
## `FocusManager.focusChain`, so the order this suite asserts is the library's
## DFS pre-order and not a sequence this repository maintains. The assertion
## that `focusOrder` and the projection agree pane-for-pane is what makes that a
## checked claim rather than a comment.
##
## ## THE DIRECTIONAL EXPECTATIONS ARE §3.2's, NOT THE CODE's
##
## Every `Ctrl+w` expectation below is a literal pane name read off §3.2's own
## description of the three profiles — three columns over a timeline strip in
## Standard, two columns over a tab stack in Compact, four columns over a strip
## in Ultra-wide. None of them is computed by `motions.nim`.
##
## ## No mocks
##
## A projection, a focus manager and integers. No session, no renderer output,
## no terminal.
##
## ## Templates, not procs, for anything that calls `check`

import std/[strutils, unittest]

import headless_app/layout_model

import ../input/motions
import ../layout/profile
import ../layout/project

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 243

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

type
  Geometry = object
    name: string
    profile: LayoutProfile
    cols, rows: int
    panes: seq[PaneKind]
      ## The panes §3.2 puts on screen in this profile, in layout order.

const
  Geometries = [
    # 80x24 — §3.1's Compact drawing. Height decides first (see
    # `app/layout/profile.nim`'s header), so this is Compact at any width.
    Geometry(name: "compact 80x24", profile: lpCompact, cols: 80, rows: 24,
             panes: @[paneCalltrace, paneEditor, paneState]),
    # 120x40 — §3.1's Standard drawing: Call Stack | Source | Variables over a
    # Timeline & Tracepoints strip.
    Geometry(name: "standard 120x40", profile: lpStandard, cols: 120, rows: 40,
             panes: @[paneCalltrace, paneEditor, paneState, paneTimeline]),
    # 200x50 — Ultra-wide: the Event Log gets a column of its own.
    Geometry(name: "ultra-wide 200x50", profile: lpUltraWide, cols: 200,
             rows: 50,
             panes: @[paneCalltrace, paneEditor, paneState, paneEventLog,
                      paneTimeline]),
  ]

  GeometryCount = 3
  TotalVisiblePanes = 12
    ## 3 + 4 + 5. The NON-VACUITY FLOOR for every per-geometry sweep below: a
    ## projection that produced no regions would satisfy "each pane visited
    ## once" for free.

proc focusFor(g: Geometry): PaneFocus =
  let body = bodyArea(g.cols, g.rows)
  newPaneFocus(projectLayout(profileLayout(g.profile), body))

suite "CTUI-9: Tab cycles every visible pane once, in every profile":

  test "the three profiles are the three §3.2 describes, at these sizes":
    var checkedGeometries = 0
    var totalPanes = 0
    for g in Geometries:
      inc checkedGeometries
      # The profile is SELECTED from the size, not asserted about a constant:
      # a geometry that stopped selecting the profile it is named for would
      # make every expectation below an expectation about a different screen.
      checkpoint(g.name & " -> " & $selectProfile(g.cols, g.rows))
      ck selectProfile(g.cols, g.rows) == g.profile
      let body = bodyArea(g.cols, g.rows)
      let projection = projectLayout(profileLayout(g.profile), body)
      ck projection.status == prOk
      ck projection.regions.len == g.panes.len
      totalPanes += projection.regions.len
      var placed: seq[PaneKind] = @[]
      for region in projection.regions:
        placed.add region.pane
      checkpoint(g.name & " regions: " & $placed)
      ck placed == g.panes
    ck checkedGeometries == GeometryCount
    ck totalPanes == TotalVisiblePanes

  test "Tab visits every visible pane exactly once per cycle, in each profile":
    var checkedGeometries = 0
    var stepsTaken = 0
    for g in Geometries:
      inc checkedGeometries
      let pf = focusFor(g)
      # The chain comes from `FocusManager.focusChain`, and it is the layout
      # order. Asserted against §3.2's list rather than against the projection
      # a second time, so a manager that returned the panes shuffled is red.
      checkpoint(g.name & " order: " & describeFocusOrder(pf))
      ck pf.focusOrder() == g.panes
      let (opened, first) = pf.focusedPane()
      ck opened
      ck first == g.panes[0]

      # ONE FULL CYCLE. Each pane exactly once, and the last `Tab` returns to
      # the first — which is what "cycle" means and what a chain that dropped a
      # member would fail on the count rather than on the membership.
      var visited: seq[PaneKind] = @[]
      visited.add first
      for _ in 1 ..< g.panes.len:
        inc stepsTaken
        let (moved, kind) = pf.focusNextPane()
        ck moved
        visited.add kind
      ck visited == g.panes
      var uniqueVisited: seq[string] = @[]
      for p in visited:
        if $p notin uniqueVisited:
          uniqueVisited.add $p
      ck uniqueVisited.len == g.panes.len
      inc stepsTaken
      let (wrapped, backToFirst) = pf.focusNextPane()
      ck wrapped
      ck backToFirst == g.panes[0]

      # …AND THE CYCLE IS STABLE. A second lap visits the same panes in the
      # same order, so the chain is a property of the layout rather than of how
      # often it has been walked.
      var secondLap: seq[PaneKind] = @[]
      for _ in 1 .. g.panes.len:
        inc stepsTaken
        let (moved, kind) = pf.focusNextPane()
        ck moved
        secondLap.add kind
      var expectedSecond = g.panes[1 .. ^1]
      expectedSecond.add g.panes[0]
      checkpoint(g.name & " second lap: " & $secondLap)
      ck secondLap == expectedSecond
    ck checkedGeometries == GeometryCount
    # The sweep's own size, from its parameters: 3 + 4 + 5 panes means
    # (n-1) + 1 + n steps per geometry = 2n steps, so 6 + 8 + 10 = 24.
    checkpoint("Tab presses: " & $stepsTaken)
    ck stepsTaken == 2 * TotalVisiblePanes
    ck stepsTaken == 24

  test "Shift+Tab is exactly the reverse cycle":
    var checkedGeometries = 0
    var stepsTaken = 0
    for g in Geometries:
      inc checkedGeometries
      let pf = focusFor(g)
      var visited: seq[PaneKind] = @[]
      for _ in 1 .. g.panes.len:
        inc stepsTaken
        let (moved, kind) = pf.focusPrevPane()
        ck moved
        visited.add kind
      var expected: seq[PaneKind] = @[]
      for i in countdown(g.panes.len - 1, 0):
        expected.add g.panes[i]
      # From the FIRST pane, `Shift+Tab` wraps to the last and walks back to
      # the first, which is the reverse of the forward lap.
      checkpoint(g.name & " reverse: " & $visited & " want " & $expected)
      ck visited == expected
      let (back, kind) = pf.focusedPane()
      ck back
      ck kind == g.panes[0]
    ck checkedGeometries == GeometryCount
    checkpoint("Shift+Tab presses: " & $stepsTaken)
    ck stepsTaken == TotalVisiblePanes

  test "`1` `2` `3` `4` select by pane, and say so when a profile hides one":
    var checkedGeometries = 0
    var selections = 0
    let wanted = [(kaSelectCallStack, paneCalltrace),
                  (kaSelectSource, paneEditor),
                  (kaSelectVariables, paneState),
                  (kaSelectTimeline, paneTimeline)]
    for g in Geometries:
      inc checkedGeometries
      let pf = focusFor(g)
      for pair in wanted:
        inc selections
        let (isSelect, kind) = directSelectPane(pair[0])
        ck isSelect
        ck kind == pair[1]
        let visible = kind in g.panes
        let ok = pf.focusPaneKind(kind)
        checkpoint(g.name & ": " & $pair[0] & " -> visible=" & $visible &
                   " focused=" & $ok)
        ck ok == visible
        if visible:
          let (has, focused) = pf.focusedPane()
          ck has
          ck focused == kind
    ck checkedGeometries == GeometryCount
    ck selections == GeometryCount * 4
    ck selections == 12
    # THE NEGATIVE THAT MATTERS, named: the Compact profile shows the Timeline
    # only as a tab of a stack, so §4.2's `4` has nothing to focus there and
    # reports that rather than focusing something else.
    let compact = focusFor(Geometries[0])
    ck not compact.focusPaneKind(paneTimeline)
    let (stillThere, unchanged) = compact.focusedPane()
    ck stillThere
    ck unchanged == paneCalltrace
    # …and an action that is not a pane selection is refused by the same
    # function, so `directSelectPane` cannot be a constant that always answers.
    let (notSelect, _) = directSelectPane(kaStepOver)
    ck not notSelect

  test "`Ctrl+w` h/j/k/l moves by geometry, and stops at the edge":
    # Every expectation is §3.2's layout read as a picture; none is computed.
    # Standard: [Call Stack | Source | Variables] over [Timeline].
    let standard = focusFor(Geometries[1])
    ck standard.focusPaneKind(paneEditor)
    var moves = 0
    for probe in [(fdLeft, true, paneCalltrace), (fdRight, true, paneState),
                  (fdDown, true, paneTimeline), (fdUp, false, paneEditor)]:
      inc moves
      let (found, kind) = standard.paneInDirection(probe[0])
      checkpoint("standard, from Source, " & $probe[0] & " -> found=" &
                 $found & " " & $kind)
      ck found == probe[1]
      if probe[1]:
        ck kind == probe[2]
    # The edges do not wrap: nothing is above the top row of panes, and nothing
    # is left of the Call Stack.
    ck standard.focusPaneKind(paneCalltrace)
    let (leftOfLeftmost, _) = standard.paneInDirection(fdLeft)
    ck not leftOfLeftmost
    # …and a refused move leaves focus exactly where it was, which is what
    # makes "does not wrap" observable rather than merely claimed.
    let (unmoved, stayed) = standard.focusDirection(fdLeft)
    ck not unmoved
    let (has, still) = standard.focusedPane()
    ck has
    ck still == paneCalltrace
    ck stayed == paneEditor      # the sentinel `focusDirection` returns

    # From the timeline strip, `Ctrl+w k` lands on the column whose centre is
    # nearest — the Source pane, which is the middle of three.
    ck standard.focusPaneKind(paneTimeline)
    let (up, above) = standard.paneInDirection(fdUp)
    checkpoint("standard, from Timeline, up -> " & $above)
    ck up
    ck above == paneEditor
    let (movedUp, landed) = standard.focusDirection(fdUp)
    ck movedUp
    ck landed == paneEditor

    # Compact: [Call Stack | Source] over the tab stack.
    let compact = focusFor(Geometries[0])
    ck compact.focusPaneKind(paneEditor)
    let (cLeft, cLeftPane) = compact.paneInDirection(fdLeft)
    ck cLeft
    ck cLeftPane == paneCalltrace
    let (cDown, cDownPane) = compact.paneInDirection(fdDown)
    ck cDown
    ck cDownPane == paneState
    let (cRight, _) = compact.paneInDirection(fdRight)
    ck not cRight

    # Ultra-wide: [Call Stack | Source | Variables | Event Log] over
    # [Timeline]. `l` from Variables is the Event Log, which exists in no
    # other profile — so the four columns are really four.
    let wide = focusFor(Geometries[2])
    ck wide.focusPaneKind(paneState)
    let (wRight, wRightPane) = wide.paneInDirection(fdRight)
    ck wRight
    ck wRightPane == paneEventLog
    ck wide.focusPaneKind(paneEventLog)
    let (wRight2, _) = wide.paneInDirection(fdRight)
    ck not wRight2
    let (wLeft, wLeftPane) = wide.paneInDirection(fdLeft)
    ck wLeft
    ck wLeftPane == paneState
    ck moves == 4

    # THE DIRECTIONS ARE THE KEYMAP's. `Ctrl+w` h/j/k/l map onto the four
    # directions and nothing else does.
    var mapped = 0
    for pair in [(kaFocusLeft, fdLeft), (kaFocusDown, fdDown),
                 (kaFocusUp, fdUp), (kaFocusRight, fdRight)]:
      inc mapped
      let (isDir, dir) = directionFor(pair[0])
      ck isDir
      ck dir == pair[1]
    ck mapped == 4
    let (notDir, _) = directionFor(kaMaximizePane)
    ck not notDir

  test "`z` maximizes the focused pane and restores the profile":
    var state = initMaximizeState()
    ck not state.active
    # A maximized layout is ONE pane, projected by the same projector, so its
    # totality is checked by the same coverage rules.
    ck toggleMaximize(state, paneEditor)
    ck state.active
    ck state.pane == paneEditor
    let body = bodyArea(120, 40)
    let maxed = projectLayout(layoutFor(state, lpStandard), body)
    ck maxed.status == prOk
    ck maxed.regions.len == 1
    ck maxed.regions[0].pane == paneEditor
    ck maxed.regions[0].area.width == body.width
    ck maxed.regions[0].area.height == body.height
    # …and the focus chain of a maximized screen has one member, so `Tab` is a
    # no-op rather than a jump to a pane nobody can see.
    let pf = newPaneFocus(maxed)
    ck pf.focusOrder() == @[paneEditor]
    let (moved, kind) = pf.focusNextPane()
    ck moved
    ck kind == paneEditor

    # `z` on ANOTHER pane maximizes that one instead of restoring — one
    # keystroke, not two.
    ck toggleMaximize(state, paneState)
    ck state.active
    ck state.pane == paneState
    # `z` on the pane that is already maximized restores.
    ck not toggleMaximize(state, paneState)
    ck not state.active
    let restored = projectLayout(layoutFor(state, lpStandard), body)
    ck restored.regions.len == 4
    var kinds: seq[PaneKind] = @[]
    for region in restored.regions:
      kinds.add region.pane
    ck kinds == Geometries[1].panes

  test "the scroll motions are §4.2's, and a half page is never zero":
    # `j` / `k` are one line; `Ctrl+d` / `Ctrl+u` are half the body.
    var checkedActions = 0
    for probe in [(kaScrollLineDown, 1), (kaScrollLineUp, -1),
                  (kaHalfPageDown, 10), (kaHalfPageUp, -10)]:
      inc checkedActions
      let (scrolls, delta) = scrollDelta(probe[0], 20)
      checkpoint($probe[0] & " over 20 rows -> " & $delta)
      ck scrolls
      ck delta == probe[1]
    ck checkedActions == 4
    # An action that is not a scroll answers so, which is what stops
    # `scrollDelta` from being a function that always moves something.
    let (notScroll, zero) = scrollDelta(kaQuit, 20)
    ck not notScroll
    ck zero == 0
    # A HALF PAGE IS AT LEAST ONE ROW. On a two-row pane `20 div 2` is fine but
    # `1 div 2` is zero, and a key that scrolls nothing is indistinguishable
    # from a key nothing is bound to.
    var sweptHeights = 0
    var badHeights: seq[string] = @[]
    for height in 0 .. 200:
      inc sweptHeights
      let page = halfPage(height)
      if page < 1 or (height >= 2 and page != height div 2):
        badHeights.add $height & " -> " & $page
    if badHeights.len > 0:
      checkpoint("bad half pages: " & badHeights[0 .. min(4, badHeights.high)].join(", "))
    ck badHeights.len == 0
    checkpoint("heights swept: " & $sweptHeights)
    ck sweptHeights == 201
    ck halfPage(0) == 1
    ck halfPage(1) == 1
    ck halfPage(2) == 1
    ck halfPage(3) == 1
    ck halfPage(40) == 20

  test "`g` `g` and `G` are the recording's two ends":
    var checkedEdges = 0
    for probe in [(kaJumpToStart, seStart), (kaJumpToEnd, seEnd)]:
      inc checkedEdges
      let (isEdge, edge) = seekEdgeFor(probe[0])
      ck isEdge
      ck edge == probe[1]
    ck checkedEdges == 2
    let (notEdge, _) = seekEdgeFor(kaNextCall)
    ck not notEdge
    # `noir_space_ship`'s own extent, measured through `ct/event-load` and
    # recorded by CTUI-8 in `tests/apps/app_timeline.nim`: tick 0 to 1314.
    ck edgeTick(seStart, 0'u64, 1314'u64) == 0'u64
    ck edgeTick(seEnd, 0'u64, 1314'u64) == 1314'u64
    # A recording whose bounds are unknown answers the beginning rather than a
    # tick that is not in it.
    ck edgeTick(seEnd, 7'u64, 3'u64) == 7'u64
    ck edgeTick(seStart, 7'u64, 3'u64) == 7'u64
    ck edgeTick(seEnd, 4'u64, 4'u64) == 4'u64

  test "the pane names a failure message reports are stable":
    # `describeFocusOrder` and `sortedPaneNames` are what a red run prints, so
    # they are asserted rather than trusted.
    let pf = focusFor(Geometries[1])
    ck describeFocusOrder(pf) == "calltrace -> editor -> state -> timeline"
    ck sortedPaneNames(Geometries[2].panes) ==
       @["calltrace", "editor", "eventLog", "state", "timeline"]

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
