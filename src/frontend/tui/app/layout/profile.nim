## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
##
## A module here may import `codetracer_embed`, `headless_app`, `isonim`,
## `isonim_tui` and `std/*` modules that touch neither a process nor a
## terminal. Nothing else. `src/frontend/tui/tests/test_tui_facade_boundary.nim`
## walks this directory's import graph on every run.
##
## app/layout/profile.nim — which arrangement the screen opens with, decided
## from its size alone.
##
## ## PLAT-45: THE TERMINAL DERIVES ITS DEFAULT, IT DOES NOT AUTHOR ONE
##
## Until PLAT-45 this module held three hand-written trees — Compact,
## Standard and Ultra-wide — selected by breakpoints (CodeTracer-TUI.md §3.2 as
## it then read). The desktop and the GPUI window each had a default of their
## own, and the three shared nothing but the tree type. Now every product opens
## with ONE arrangement, `layout_model.sharedDefaultLayout()`, and this module's
## job is to say how much of it this terminal can show:
##
##   profileLayout(p) == foldLayout(sharedDefaultLayout(), depthFor(w, h))
##
## `depthFor` is the smallest fold depth whose PROJECTION gives every visible
## region at least its panes' `minPaneWidth` / `minPaneHeight` — the cell
## contract CTUI-3 wrote, now a search over depths instead of three
## breakpoints. At any size that fits, depth is 0 and the terminal's first
## screen is the arrangement the desktop opens with; only when some pane cannot
## get its minimum does the lowest-ranked region fold into tabs, and the status
## line says so (`foldNote`). The cells stay here, in the binding; the shared
## model knows only the unitless fold ORDER (Layout-ViewModel §8.2 as PLAT-45
## rewrote it).
##
## Two things are the terminal's own, not the shared model's (PLAT-45's
## review): the ORDER the fold is applied in — every step whose region holds
## only panes this front-end cannot draw goes first (`terminalFolds`), so a
## region of report leaves never keeps its cells while a region of data gives
## its up — and the SHARES: the folded tree is sized minimums-first
## (`sizeForCells`), because the desktop's proportions give the source pane a
## quarter of the width however far the fold goes. The ARRANGEMENT (what is
## beside, above and tabbed with what) is the shared one at every size that
## fits; the cells are the medium's.
##
## Edit mode gets the same treatment over `sharedEditLayout()`.
##
## The old three trees are kept as TEST FIXTURES
## (`app/tests/plat45_old_profiles.nim`), not as product code: PLAT-45's risk
## note compares the folded compact result against them.
##
## ## WHAT A "PROFILE" IS NOW
##
## `LayoutProfile` is the terminal SIZE the default is derived for — a value
## that answers "which depth" per product mode — plus `hintDensity`, the one
## thing the old breakpoint table still decides: how much of the key-hint strip
## fits on the status line. The breakpoints no longer choose an arrangement.
##
## ## THIS MODULE NOW IMPORTS THE PROJECTION
##
## `depthFor` has to project a candidate to know whether it fits, so this
## module imports `project.nim`; the cycle that would have made is broken by
## `cells.nim`, which holds what `project.nim` used to take from here.

import std/strutils

import headless_app/layout_model

# PLAT-16. `ProductMode` from the core: a mode's default layout is a function
# OF THE MODE (Mode-Transitions.md §4a).
import codetracer_embed

import ./cells
import ./project

export cells

type
  LayoutProfile* = object
    ## The terminal size a default arrangement is derived for. A VALUE, so two
    ## sizes compare equal exactly when they would produce the same default.
    width*: int
    height*: int

  HintDensity* = enum
    ## How much of §3.3.6's key-hint strip the status line has room for. The
    ## ONE decision the old breakpoint table still makes: it no longer picks an
    ## arrangement (the fold does), only which hint strip is drawn.
    hdCompact = "compact"
    hdStandard = "standard"
    hdUltraWide = "ultra-wide"

const
  StandardMinWidth* = 120
    ## The widest terminal whose status line gets the function-key hint strip
    ## (§3.1's 80x24 drawing); from here the letter strip (its 120x40 drawing)
    ## fits.
  UltraWideMinWidth* = 180
  TallProfileMinHeight* = 35
    ## Below this height the compact hint strip is kept at every width, as the
    ## old §3.2 height clause did.

const
  lpCompact* = LayoutProfile(width: 80, height: 24)
    ## THE THREE SIZES THE OLD §3.2 NAMED, kept as named sizes. Before PLAT-45
    ## these were an enum of three hand-written arrangements; now a profile is
    ## a size and the arrangement is the shared default folded for it, so the
    ## names survive as the sizes each old profile was drawn for — the ones
    ## `test_plat45_fold.nim` and the real-PTY suite measure the change at.
  lpStandard* = LayoutProfile(width: 120, height: 40)
  lpUltraWide* = LayoutProfile(width: 200, height: 50)

proc selectProfile*(width, height: int): LayoutProfile =
  ## The profile for a `width` x `height` terminal. A pure function with no
  ## state, no I/O and no renderer.
  LayoutProfile(width: width, height: height)

proc `$`*(p: LayoutProfile): string =
  $p.width & "x" & $p.height

proc hintDensity*(p: LayoutProfile): HintDensity =
  ## The old breakpoint rule, kept for the hint strip only. Height decides
  ## first, as it did (see git history for the §3.2 overlap it resolved).
  if p.height < TallProfileMinHeight: hdCompact
  elif p.width >= UltraWideMinWidth: hdUltraWide
  elif p.width >= StandardMinWidth: hdStandard
  else: hdCompact

# ---------------------------------------------------------------------------
# PLAT-45 deliverable 2 — what the terminal can draw
# ---------------------------------------------------------------------------

proc terminalCapability*(): PaneCapability =
  ## The terminal's declared capability. Every pane of the shared default that
  ## is not in `drawable` is still PLACED, and `views/shell.paintPane` fills
  ## its slot with `reportText` — the pane's name and the reason below — so an
  ## absent view is visible rather than a gap.
  paneCapability(feTerminal,
    {paneEditor, paneCalltrace, paneState, paneEventLog, paneTimeline,
     panePointList, paneFileTree, paneBuildOutput},
    [(paneDebugControls, "the terminal steps from the keyboard and names " &
                         "the keys on its status line"),
     (paneFlow, "the terminal draws flow inside the source pane"),
     (paneSearch, "search results open in the command line, not a pane"),
     (paneScratchpad, "the terminal has no scratchpad view yet"),
     (paneShell, "the terminal has no embedded shell view yet"),
     (paneVcs, "the terminal has no version-control view yet"),
     (paneAgentActivity, "the terminal has no agent-activity view yet"),
     (paneTerminalOutput, "the recorded program's terminal output has no " &
                          "terminal view yet"),
     (paneTestResults, "the terminal has no test-results view yet"),
     (paneConstraints, "the terminal has no constraints view yet")])

# ---------------------------------------------------------------------------
# PLAT-45 deliverable 5 — the fold depth this terminal needs
# ---------------------------------------------------------------------------

proc sharedFor*(product: ProductMode): SharedLayout =
  ## The shared default a product mode folds.
  case product
  of pmDebug: sharedDefaultLayout()
  of pmEdit: sharedEditLayout()

proc regionPanes(tree: LayoutNode; visible: PaneKind): seq[PaneKind] =
  ## Every pane of the region `visible` is shown in: the whole stack when it
  ## is a tab. The minimum a region must honour is its WIDEST tab's, so that
  ## switching tabs never lands on a pane the region cannot draw — the same
  ## rule CTUI-3's `minimumWidth` applied to a stack.
  let region = regionOf(tree, visible)
  if region.isNil:
    return @[visible]
  if region.kind == lnStack:
    for c in region.children:
      if c.kind == lnPane and not c.isContributed:
        result.add c.pane
  else:
    result.add visible

proc fitProblems*(tree: LayoutNode; width, height: int): seq[string] =
  ## Why `tree` does not fit a `width` x `height` terminal: one entry per
  ## visible region whose rectangle is smaller than its panes' minimum, or the
  ## projection's own refusal. Empty exactly when it fits.
  let projection = projectLayout(tree, bodyArea(width, height), ppDegrade)
  if projection.status != prOk:
    return @["the projection answered " & $projection.status]
  for r in projection.regions:
    var needW = 0
    var needH = 0
    for p in regionPanes(tree, r.pane):
      needW = max(needW, minPaneWidth(p))
      needH = max(needH, minPaneHeight(p))
    if r.area.width < needW or r.area.height < needH:
      result.add $r.pane & " has " & $r.area.width & "x" & $r.area.height &
                 ", needs " & $needW & "x" & $needH

proc fitsAt*(tree: LayoutNode; width, height: int): bool =
  fitProblems(tree, width, height).len == 0

# ---------------------------------------------------------------------------
# The terminal's fold ORDER: panes it cannot draw give up their space first
# ---------------------------------------------------------------------------

proc drawsAny(tree: LayoutNode; region: PaneKind; c: PaneCapability): bool =
  ## Whether the region holding `region` has at least one pane this front-end
  ## can DRAW. A region that has none is nothing but report leaves.
  for p in regionPanes(tree, region):
    if c.canDraw(p):
      return true
  false

proc terminalFolds*(shared: SharedLayout;
                    c: PaneCapability = terminalCapability()): SharedLayout =
  ## The shared fold order as the terminal applies it: **every step whose
  ## region holds only panes the terminal cannot draw comes first**, and the
  ## shared order is kept among the rest (and among those).
  ##
  ## A region of report leaves spends cells on a sentence saying a view is
  ## missing; a drawable region spends them on data. When the terminal has to
  ## give something up it gives up the sentences first — they stay reachable
  ## as tabs, and the report is still read when the tab is chosen — before
  ## any region that shows the user something. The rule is the terminal's (it
  ## is about ITS capability), so it lives here and the shared order stays the
  ## desktop's ranking. Evaluated step by step on the tree as it folds, because
  ## a step can turn a drawable region into a report-only one and back.
  ##
  ## Depth 0 is untouched by construction: this reorders steps, it adds none.
  result = SharedLayout(tree: shared.tree, folds: @[])
  var remaining = shared.folds
  var tree = clone(shared.tree)
  while remaining.len > 0:
    var pick = 0
    for i, step in remaining:
      let r = regionOf(tree, step.region)
      if not r.isNil and not drawsAny(tree, step.region, c):
        pick = i
        break
    let step = remaining[pick]
    remaining.delete(pick)
    result.folds.add step
    tree = foldLayout(SharedLayout(tree: shared.tree, folds: result.folds),
                      result.folds.len)

# ---------------------------------------------------------------------------
# The terminal's SIZING: every region its minimum first, then the rest
# ---------------------------------------------------------------------------

proc nodeMinWidth(n: LayoutNode): int =
  if n.isNil:
    return 0
  case n.kind
  of lnPane: minPaneWidth(n.pane)
  of lnRow:
    var total = 0
    for c in n.children:
      total += nodeMinWidth(c)
    total
  of lnColumn, lnStack:
    var widest = 0
    for c in n.children:
      widest = max(widest, nodeMinWidth(c))
    widest

proc nodeMinHeight(n: LayoutNode): int =
  if n.isNil:
    return 0
  case n.kind
  of lnPane: minPaneHeight(n.pane)
  of lnColumn:
    var total = 0
    for c in n.children:
      total += nodeMinHeight(c)
    total
  of lnRow, lnStack:
    var tallest = 0
    for c in n.children:
      tallest = max(tallest, nodeMinHeight(c))
    tallest

proc shareOf(n: LayoutNode): float =
  ## The projection's own reading of a weight (`project.weightShare`): `0` is
  ## an equal share, and one is the neutral share.
  if n.weight <= 0.0: 1.0 else: n.weight

proc sizeForCells(n: LayoutNode; width, height: int) =
  ## In place: give every child of every row and column AT LEAST ITS MINIMUM,
  ## then share what is left by the tree's own weights, and write the result
  ## back as the children's weights (cell counts are a valid unitless share —
  ## the projection divides the parent's extent by them and gets these counts
  ## back exactly).
  ##
  ## Without this the folded tree kept the desktop's PROPORTIONS, and the
  ## desktop gives the editor a quarter of the window: at 80 columns that was
  ## 20 cells whatever the fold did, because every step handed the space it
  ## freed to the editor's neighbours in proportion. The ARRANGEMENT is the
  ## shared one (what is beside, above and tabbed with what); the shares are
  ## the medium's, like every cell count — Layout-ViewModel §8.2.
  ##
  ## A container that cannot give every child its minimum is left as it is;
  ## `fitProblems` reports it and `depthFor` folds further.
  if n.isNil or n.kind == lnPane:
    return
  if n.kind == lnStack:
    for c in n.children:
      sizeForCells(c, width, height)
    return
  let horizontal = n.kind == lnRow
  let total = if horizontal: width else: height
  var mins: seq[int] = @[]
  var shares: seq[float] = @[]
  var need = 0
  for c in n.children:
    let m = if horizontal: nodeMinWidth(c) else: nodeMinHeight(c)
    mins.add m
    shares.add shareOf(c)
    need += m
  var cells: seq[int] = @[]
  if need <= total:
    let extra = distributeCells(total - need + n.children.len,
                                shares)
    # `distributeCells` never hands out a zero (its second property), so it is
    # asked for `children.len` more cells than the slack and each child gives
    # one back: a child whose share rounds to nothing gets exactly its minimum.
    for i in 0 ..< n.children.len:
      cells.add mins[i] + extra[i] - 1
  else:
    cells = distributeCells(total, shares)
    if cells.len != n.children.len:
      return
  for i, c in n.children:
    c.weight = float(max(cells[i], 1))
    if horizontal: sizeForCells(c, cells[i], height)
    else: sizeForCells(c, width, cells[i])

proc terminalDefaultAt*(product: ProductMode; width, height,
                        depth: int): LayoutNode =
  ## `product`'s shared default folded to `depth` in the terminal's order and
  ## sized for a `width` x `height` terminal. A fresh tree.
  result = foldLayout(terminalFolds(sharedFor(product)), depth)
  let body = bodyArea(width, height)
  sizeForCells(result, body.width, body.height)

proc depthFor*(product: ProductMode; width, height: int): int =
  ## **THE SEARCH.** The smallest fold depth of `product`'s shared default
  ## whose projection gives every visible region its minimum at this size.
  ## When no depth fits — a terminal narrower than the deepest fold's widest
  ## pane — the deepest fold, which is the most the terminal can do; the
  ## projection then degrades rather than drawing a hole.
  let deepest = maxFoldDepth(sharedFor(product))
  for d in 0 .. deepest:
    if fitsAt(terminalDefaultAt(product, width, height, d), width, height):
      return d
  deepest

proc depthFor*(product: ProductMode; p: LayoutProfile): int =
  depthFor(product, p.width, p.height)

proc profileLayout*(profile: LayoutProfile): LayoutNode =
  ## Debug mode's default at this size: the shared default, folded exactly as
  ## far as the terminal's cells require. A fresh tree on every call.
  terminalDefaultAt(pmDebug, profile.width, profile.height,
                    depthFor(pmDebug, profile))

proc editProfileLayout*(profile: LayoutProfile): LayoutNode =
  ## Edit mode's default at this size: `sharedEditLayout()` folded by the same
  ## rule. Mode-Transitions.md §4a still holds — the edit default is a tree of
  ## its own, not the debug tree with holes — it is simply the shared one.
  terminalDefaultAt(pmEdit, profile.width, profile.height,
                    depthFor(pmEdit, profile))

proc layoutForMode*(product: ProductMode; profile: LayoutProfile): LayoutNode =
  ## A mode's DEFAULT arrangement — §4b's third tier, and the fallback §4c
  ## obligation 1 names. ONE entry point for both modes, so a caller cannot
  ## reach one mode's default while believing it asked for the other's.
  case product
  of pmDebug: profileLayout(profile)
  of pmEdit: editProfileLayout(profile)

proc resizeShares*(tree: LayoutNode; product: ProductMode;
                   profile: LayoutProfile) =
  ## In place: the shares of `tree` — an UNMODIFIED default at the same fold
  ## depth — re-derived for a new size, leaving every stack's active tab as the
  ## user left it. A resize inside one depth must not throw away the chosen
  ## tab (`shell.reprofile`'s guard), and must not keep the old size's cell
  ## counts either, or a window shrunk from 200 to 120 columns would hand the
  ## editor 40% of 120.
  let fresh = layoutForMode(product, profile)
  proc copy(dst, src: LayoutNode) =
    if dst.isNil or src.isNil or dst.kind != src.kind or
       dst.children.len != src.children.len:
      return
    dst.weight = src.weight
    for i in 0 ..< dst.children.len:
      copy(dst.children[i], src.children[i])
  copy(tree, fresh)

proc foldNote*(product: ProductMode; profile: LayoutProfile): string =
  ## What the status line says when the terminal FOLDED the shared default:
  ## `""` at depth 0 (the arrangement is the one every product opens with, and
  ## there is nothing to say), else `[folded N]` — N of the shared default's
  ## regions became tabs because this terminal cannot give every pane its
  ## minimum. Short on purpose: it sits beside the mode indicators, which the
  ## status line never drops.
  let d = depthFor(product, profile)
  if d == 0: ""
  else: "[folded " & $d & "]"

proc stackTabs*(tree: LayoutNode): seq[seq[PaneKind]] =
  ## Every stack's tabs, in reading order — read out of the tree rather than
  ## written down beside it.
  var found: seq[seq[PaneKind]] = @[]
  proc walk(n: LayoutNode) =
    if n.isNil:
      return
    if n.kind == lnStack:
      var tabs: seq[PaneKind] = @[]
      for c in n.children:
        if c.kind == lnPane and not c.isContributed:
          tabs.add c.pane
      found.add tabs
      return
    for c in n.children:
      walk(c)
  walk(tree)
  found

proc minimumWidth*(tree: LayoutNode): int =
  ## The narrowest body `tree`'s widest row can be laid out in, from the
  ## per-pane contract alone (a lower bound; `fitsAt` is the real test, since
  ## weights can starve a pane in a body wider than this).
  proc walk(n: LayoutNode): int =
    if n.isNil:
      return 0
    case n.kind
    of lnPane:
      minPaneWidth(n.pane)
    of lnRow:
      var total = 0
      for c in n.children:
        total += walk(c)
      total
    of lnColumn, lnStack:
      var widest = 0
      for c in n.children:
        widest = max(widest, walk(c))
      widest
  walk(tree)

proc minimumHeight*(tree: LayoutNode): int =
  ## The shortest terminal `tree` fits in by the per-pane contract, INCLUDING
  ## the header and the status bar, so it is comparable with a terminal's own
  ## height.
  proc walk(n: LayoutNode): int =
    if n.isNil:
      return 0
    case n.kind
    of lnPane:
      minPaneHeight(n.pane)
    of lnColumn:
      var total = 0
      for c in n.children:
        total += walk(c)
      total
    of lnRow, lnStack:
      var tallest = 0
      for c in n.children:
        tallest = max(tallest, walk(c))
      tallest
  walk(tree) + ChromeRows

proc describeProfile*(profile: LayoutProfile;
                      product: ProductMode = pmDebug): string =
  ## One line for a status bar or a failure message: the size, the fold depth
  ## it chose, and what the deepest fold would need.
  $profile & " depth " & $depthFor(product, profile) & "/" &
    $maxFoldDepth(sharedFor(product))

proc profileSummary*(): string =
  ## The fold depth each of the three sizes the old §3.2 named resolves to.
  var parts: seq[string] = @[]
  for (w, h) in [(80, 24), (120, 40), (200, 50)]:
    parts.add $w & "x" & $h & ":depth " & $depthFor(pmDebug, w, h)
  parts.join(" ")
