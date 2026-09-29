## test_plat45_fold.nim — PLAT-45, Tier 1. **The fold at every terminal
## size**, read from the terminal's own painted frame.
##
## Run:
##   nim c -r <tui lane flags> src/frontend/tui/tests/test_plat45_fold.nim
##
## PLAT-45 deliverable 5 makes the terminal's default a DERIVATION: the one
## shared arrangement, folded exactly as far as the terminal's cells require
## (`profile.depthFor`). Its real-stack row asks, for every terminal size from
## 80x24 to 300x100 in a coarse grid:
##
##   * the chosen depth satisfies every visible pane's minimum;
##   * the next shallower depth does not (so the fold is not deeper than the
##     cells require — the user's rule: fold ONLY when too small);
##   * every pane of the shared tree is reachable, visible or as a tab.
##
## ## Read from the frame, not from the model
##
## Each size builds the shell a terminal of that size opens with
## (`views/shell.newShellModel`, the Debug default) and PAINTS it
## (`shellScreen`). The regions checked are the ones the frame was painted from
## (`ShellScreen.projection`), and the tabs are read off the painted TAB STRIP
## text of each region's first row — so a projection that dropped a tab, or a
## painter that stopped drawing a strip, fails here even though the model
## would still say the pane was placed (Verification-Harness-Traps §4a).
##
## The three sizes the old §3.2 named are also compared against the OLD
## hand-tuned profiles (`app/tests/plat45_old_profiles.nim`), which is PLAT-45's
## risk mitigation: the numbers are printed and the structural claims asserted,
## so a reader sees exactly what a compact user gained and lost.
##
## A real PTY reading of the same three sizes is
## `real_terminal/test_real_plat45_fold.nim`.
##
## No mocks: the shell, the projection and the painter are the product's.

import std/[sets, strutils, unicode, unittest]

import headless_app/layout_model
import codetracer_embed

import ../app/layout/profile
import ../app/layout/project
import ../app/views/shell
import ../app/tests/plat45_old_profiles

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

proc paneOfName(name: string): string =
  ## The terminal's tab label back to the pane it names.
  for k in PaneKind:
    if terminalPaneName(k) == name:
      return $k
  ""

proc stripTabs(row: string): seq[string] =
  ## The tab labels a painted strip shows: `[Active]  Other  Third  ----`.
  ## Split on the two-space gaps the strip draws between tabs, with the
  ## brackets of the active tab and the trailing rule removed.
  ## A region's right border (`│`) is not part of any label: where a region
  ## is exactly as wide as its active tab's bracketed name, the border touches
  ## the closing bracket.
  for raw in row.replace("─", " ").replace("│", " ").split("  "):
    var t = raw.strip(chars = {' ', '-', '|', '[', ']'})
    if t.len > 0:
      result.add t

proc sharedPanes(): HashSet[string] =
  for p in allPanes(sharedDefaultLayout().tree):
    result.incl $p

suite "PLAT-45: the terminal's fold at every size":

  test "a coarse grid from 80x24 to 300x100: minimums, minimality, reachability":
    var sizes = 0
    var folded = 0
    var depths = initHashSet[int]()
    for w in countup(80, 300, 20):
      for h in countup(24, 100, 8):
        inc sizes
        let model = newShellModel(w, h)
        let screen = shellScreen(model, w, h, ppDegrade)
        let d = depthFor(pmDebug, w, h)
        depths.incl d
        if d > 0: inc folded
        checkpoint($w & "x" & $h & " depth " & $d)
        ck screen.projection.status == prOk
        # THE CHOSEN DEPTH SATISFIES EVERY VISIBLE PANE'S MINIMUM, measured on
        # the regions the frame was painted from.
        var reachable = initHashSet[string]()
        for r in screen.projection.regions:
          var tabs: seq[string] = @[]
          if r.activeTab >= 0 and r.tabs.len > 0:
            for title in r.tabs:
              tabs.add paneOfName(title)
            # THE PAINTED STRIP: its first label is the active tab's name, or
            # a prefix of it where the region is too narrow to spell it all —
            # the strip truncates labels to the region, and a tab whose label
            # was cut is still a tab of the region (the wheel and `Alt`
            # cycle to it).
            let rowText = screen.rows[r.area.row]
            let painted = stripTabs(rowText.runeSubStr(r.area.col, r.area.width))
            ck painted.len > 0
            if painted.len > 0:
              ck r.tabs[r.activeTab].startsWith(painted[0])
          else:
            tabs.add $r.pane
          var needW, needH = 0
          for t in tabs:
            reachable.incl t
            for k in PaneKind:
              if $k == t:
                needW = max(needW, minPaneWidth(k))
                needH = max(needH, minPaneHeight(k))
          ck r.area.width >= needW
          ck r.area.height >= needH
        # EVERY PANE OF THE SHARED TREE IS REACHABLE, visible or as a tab.
        ck reachable == sharedPanes()
        # AND NO SHALLOWER DEPTH FITS — the fold is exactly as deep as the
        # cells require, never deeper.
        if d > 0:
          ck not fitsAt(terminalDefaultAt(pmDebug, w, h, d - 1), w, h)
        # THE STATUS LINE SAYS SO, exactly when it folded.
        let status = screen.rows[^1]
        ck status.contains("[folded " & $d & "]") == (d > 0)
    checkpoint("sizes " & $sizes & ", folded at " & $folded)
    # Non-vacuity: the grid is the size it claims, it reaches the unfolded
    # arrangement, and it really folds somewhere — or every "fits" above would
    # be a statement about one depth.
    ck sizes == 12 * 10
    ck 0 in depths
    ck folded > 0

  test "every depth the search can choose is reached by some size":
    var reached = initHashSet[int]()
    for w in countup(20, 300, 4):
      for h in countup(6, 100, 2):
        reached.incl depthFor(pmDebug, w, h)
    # The deepest fold is where a terminal too small for anything lands.
    ck maxFoldDepth(sharedDefaultLayout()) in reached
    ck 0 in reached

  test "edit mode folds its own shared default by the same rule":
    for (w, h) in [(80, 24), (120, 40), (200, 50), (40, 12)]:
      let d = depthFor(pmEdit, w, h)
      let tree = terminalDefaultAt(pmEdit, w, h, d)
      ck equalTrees(editProfileLayout(selectProfile(w, h)), tree)
      if d < maxFoldDepth(sharedEditLayout()):
        ck fitsAt(tree, w, h)
      if d > 0:
        ck not fitsAt(terminalDefaultAt(pmEdit, w, h, d - 1), w, h)

  test "the old three profiles, side by side with the fold (risk mitigation)":
    for p in OldProfile:
      let (w, h) = OldProfileSizes[p]
      let old = projectLayout(oldProfileLayout(p), bodyArea(w, h), ppDegrade)
      let now = projectLayout(profileLayout(selectProfile(w, h)),
                              bodyArea(w, h), ppDegrade)
      let editorOld = old.regionFor(paneEditor)
      let editorNow = now.regionFor(paneEditor)
      echo "  PLAT-45 vs old " & $p & " " & $w & "x" & $h & ": depth " &
                 $depthFor(pmDebug, w, h) & ", regions " & $old.regions.len &
                 " -> " & $now.regions.len & ", editor " & $editorOld.width &
                 "x" & $editorOld.height & " -> " & $editorNow.width & "x" &
                 $editorNow.height
      # THE STRUCTURAL CLAIMS: every pane the old profile showed is still
      # reachable, and the editor still has at least its minimum.
      var nowPanes = initHashSet[string]()
      for p2 in allPanes(profileLayout(selectProfile(w, h))):
        nowPanes.incl $p2
      for p2 in allPanes(oldProfileLayout(p)):
        ck ($p2) in nowPanes
      ck editorNow.width >= minPaneWidth(paneEditor)

  test "the source pane stays usable: editor width at 80x24, 120x40, 200x60":
    # THE REVIEW FINDING THIS PINS: with the desktop's proportions kept, the
    # shared default gave the terminal's source pane a quarter of the width
    # (20 cells at 80x24, 30 at 120x40), and panes the terminal cannot draw
    # held the rest as report leaves. The editor's width is read from the
    # PAINTED frame's regions and compared with what the pre-shared-default
    # profiles gave at the same size (`plat45_old_profiles`, the trees
    # origin/agents shipped, projected by the same projection):
    #
    #   * 80x24 and 120x40 — at least the old width (56 and 60);
    #   * 200x60 — the old ultra-wide profile gave 90 by showing FOUR panes;
    #     the shared arrangement fits at 200 columns (every pane gets its
    #     minimum), and the rule is to fold ONLY when a pane cannot get its
    #     minimum, so the bound here is the terminal's own sizing rule: the
    #     editor's minimum plus at least the desktop's quarter share of the
    #     columns left over once every visible region has its minimum.
    const Sizes = [(80, 24, opCompact), (120, 40, opStandard),
                   (200, 60, opUltraWide)]
    for (w, h, oldProfile) in Sizes:
      let old = projectLayout(oldProfileLayout(oldProfile), bodyArea(w, h),
                              ppDegrade)
      let screen = shellScreen(newShellModel(w, h), w, h, ppDegrade)
      var editorNow = -1
      var reachable = initHashSet[string]()
      for r in screen.projection.regions:
        if r.pane == paneEditor:
          editorNow = r.area.width
        if r.activeTab >= 0 and r.tabs.len > 0:
          for title in r.tabs:
            reachable.incl paneOfName(title)
        else:
          reachable.incl $r.pane
      let editorOld = old.regionFor(paneEditor).width
      echo "  editor at " & $w & "x" & $h & ": old " & $editorOld & ", now " &
           $editorNow & " (depth " & $depthFor(pmDebug, w, h) & ")"
      ck editorNow >= minPaneWidth(paneEditor)
      if oldProfile == opUltraWide:
        let slack = w - minimumWidth(sharedDefaultLayout().tree)
        ck slack > 0
        ck editorNow >= minPaneWidth(paneEditor) + slack div 4
      else:
        ck editorNow >= editorOld
      # NO PANE IS LOST: every pane of the shared tree is visible or a tab.
      ck reachable == sharedPanes()
    # The minimum itself is the old STANDARD profile's source width — the
    # most any old profile below ultra-wide gave the source — not a number
    # chosen to make the lines above pass at one size.
    ck minPaneWidth(paneEditor) ==
       projectLayout(oldProfileLayout(opStandard), bodyArea(120, 40),
                     ppDegrade).regionFor(paneEditor).width

  test "report-only regions fold before any region that draws data":
    # The terminal's fold order puts every region made only of panes it
    # cannot draw (report leaves) ahead of every region with a drawable pane.
    # Checked on the shipped order AND on a shuffled one, so the rule is the
    # code's and not an accident of how the shared order is written.
    let cap = terminalCapability()
    proc checkOrder(s: SharedLayout) =
      let t = terminalFolds(s, cap)
      ck t.folds.len == s.folds.len
      var sawDrawable = false
      for d in 0 ..< t.folds.len:
        let tree = foldLayout(t, d)
        var draws = false
        let region = regionOf(tree, t.folds[d].region)
        if region.kind == lnStack:
          for c in region.children:
            if c.kind == lnPane and cap.canDraw(c.pane): draws = true
        elif cap.canDraw(region.pane):
          draws = true
        if draws: sawDrawable = true
        else: ck not sawDrawable
    let shipped = sharedDefaultLayout()
    checkOrder(shipped)
    # PLAT-47: the shipped default (the desktop's Debug layout) has no
    # report-only REGION left — VCS and Tests are tabs of the FILES panel, Agent
    # Activity of the call trace's, Terminal Output of the event log's — so the
    # rule is exercised on the BUNDLED tree, whose right column of report
    # leaves (Test Results over Constraints) is exactly the case it exists
    # for, with PLAT-45's order for it, and on a shuffle of that order.
    let bundled = SharedLayout(tree: sharedBundledLayout(), folds: @[
      FoldStep(region: paneConstraints, into: paneTestResults),
      FoldStep(region: paneTestResults, into: paneEventLog),
      FoldStep(region: paneFileTree, into: paneCalltrace),
      FoldStep(region: paneCalltrace, into: paneState),
      FoldStep(region: paneEventLog, into: paneState),
      FoldStep(region: paneState, into: paneEditor)])
    checkOrder(bundled)
    var shuffled = bundled
    shuffled.folds = @[bundled.folds[2], bundled.folds[3], bundled.folds[0],
                       bundled.folds[4], bundled.folds[1], bundled.folds[5]]
    checkOrder(shuffled)
    # The shuffled order's first two terminal steps are the report-only ones.
    let t = terminalFolds(shuffled, cap)
    ck t.folds[0].region == paneConstraints
    ck t.folds[1].region == paneTestResults
    # And at every size the shipped default keeps TESTS where the desktop
    # keeps it — a tab of the FILES panel — whatever the terminal folds.
    for w in countup(80, 300, 20):
      for h in countup(24, 100, 8):
        let tree = profileLayout(selectProfile(w, h))
        ck regionOf(tree, paneTestResults) == regionOf(tree, paneFileTree)
        ck not tree.contains(paneConstraints)

echo "CHECKS: ", CHECKS
