## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/views/shell.nim — CTUI-3. The root view: header, multi-pane body,
## timeline strip, status bar.
##
## ## The screen is composed ROW BY ROW, and that is a measured decision
##
## isonim-tui's compositor is a flatten-to-rows walk: `walkLayoutImpl`
## increments one row counter per emitted entry, and `tests/apps/app_overlay.nim`
## records the consequence in its own header — "what it does NOT do today is put
## two entries on the same ROW". So a component tree of nested boxes cannot
## produce two panes side by side, whatever styles it carries.
##
## The geometry therefore comes from `app/layout/project.nim` — which is a real
## Yoga tree over the real `LayoutNode` — and this module paints each pane into
## its rectangle on a cell grid, then emits one `div` per screen row. That is
## the same construction `tests/apps/app_borders.nim` uses, and it keeps the
## claim honest in both directions: the layout arithmetic is Yoga's and is
## asserted against the cell grid, and the painting is a pure function from a
## model to `height` strings of exactly `width` cells.
##
## `shellRows` is that pure function, and it is what makes the Tier-1 half of
## this milestone assertable: a row is a string, a string can be compared
## exactly, and `tests/real_terminal/test_real_shell_geometry.nim` then compares
## the SAME strings against what a terminal actually shows.
##
## ## A degraded projection is DRAWN AS DEGRADED
##
## CTUI-3: never a silently misdrawn screen. When `projectLayout` reports
## anything but `prOk` the body carries a banner saying so, naming the status,
## and the status bar carries it as a notification. A fallback that looked like
## an ordinary single-pane layout would be indistinguishable from a deliberate
## one, which is the failure the rule is written against.

import std/strutils

import isonim_tui

import headless_app/layout_model

import ../layout/binding
import ../layout/profile
import ../layout/project
import ../layout/tab_strip
import ../syntax/highlighter
# PLAT-16. `ProductMode` from the core, through the sanctioned facade. The
# shell needs it for two things and only two: which pane set to project, and
# which model the `editor` rectangle is painted from.
import codetracer_embed
import ./build_output
import ./call_stack
import ./edit_pane
import ./file_tree
import ./event_log
import ./frame_viewer
import ./header
import ./point_list
import ./source_pane
import ./status_bar
import ./styled_row
import ./timeline_bar
import ./tracepoint_manager
import ./variables

export header, status_bar, profile, project, source_pane, styled_row
# PLAT-6 moved `tabRow` and `PaneRuleGlyph` to `app/layout/tab_strip.nim`, so
# the painter and the binding's hit-test read ONE answer about where tab `i`
# sits. Re-exported here because this module declared both before, and every
# CTUI-3 call site must keep resolving.
export tab_strip
export binding
export call_stack, variables
export event_log, timeline_bar, tracepoint_manager
# PLAT-15's frame viewer, on exactly the rule the four lines above follow: a
# `ShellModel` field is painted by this module, so every consumer that builds
# one needs the model type in scope from this one import.
export frame_viewer
# PLAT-16's two Edit-mode panes, on exactly that rule: both are `ShellModel`
# fields painted by this module.
export edit_pane, file_tree, build_output

type
  ShellModel* = object
    ## Everything the screen shows, as a value. Constructed by
    ## `app/tui_app.nim` from a `HeadlessApp`; this module never learns that a
    ## debugger exists.
    header*: HeaderModel
    status*: StatusBarModel
    layout*: LayoutNode
      ## THE SAME TREE THE DESKTOP PERSISTS. Held rather than derived, because
      ## `Alt+1/2/3` is `LayoutNode.activate` on this node — the milestone's
      ## load-bearing contract — and a tree rebuilt from the profile on every
      ## frame would throw the active tab away on the next repaint.
    profile*: LayoutProfile
    source*: SourcePaneModel
      ## CTUI-5's source pane, as a value.
      ##
      ## EMPTY BY DEFAULT, and that is what keeps CTUI-3's screen unchanged:
      ## `paintPane` delegates the `editor` rectangle to
      ## `app/views/source_pane.nim` only when `source.path` is non-empty, so
      ## a shell built with no session open paints exactly the title row it
      ## painted before this milestone. `app_shell.nim`'s cross-tier golden is
      ## therefore the same screen it was, and CTUI-3's suites still read it.
    variables*: VariablesModel
      ## CTUI-7's variables pane, as a value.
      ##
      ## EMPTY BY DEFAULT, on exactly the same rule as `source` and
      ## `callStack` below and for exactly the same reason: `paintPane`
      ## delegates the `state` rectangle to `app/views/variables.nim` only when
      ## the model has scopes, so a shell with no session open paints the tab
      ## strip CTUI-3 painted, `app_shell.nim`'s cross-tier golden is unchanged,
      ## and every CTUI-3, CTUI-5 and CTUI-6 assertion that reads that row still
      ## reads it.
    callStack*: CallStackModel
      ## CTUI-6's call stack pane, as a value.
      ##
      ## EMPTY BY DEFAULT, on exactly the same rule as `source` above and for
      ## exactly the same reason: `paintPane` delegates the `calltrace`
      ## rectangle to `app/views/call_stack.nim` only when the model has
      ## frames, so a shell with no session open paints the plain
      ## `CALL STACK ────` title row CTUI-3 painted, `app_shell.nim`'s
      ## cross-tier golden is unchanged, and every CTUI-3 and CTUI-5 assertion
      ## that reads that row still reads it.
    timeline*: TimelineBarModel
      ## CTUI-8's scrubber, as a value.
      ##
      ## EMPTY BY DEFAULT, on exactly the same rule as `source`, `callStack` and
      ## `variables` above: `paintPane` delegates the `timeline` rectangle to
      ## `app/views/timeline_bar.nim` only when the model has BOUNDS, so a shell
      ## with no session open paints CTUI-3's own `timelineScrubber` row and
      ## every CTUI-3 assertion that reads it still reads it.
    eventLog*: EventLogModel
    points*: PointListPaneModel
      ## PLAT-40. The Points pane, as a value. NOT LOADED BY DEFAULT, so a shell
      ## with no session paints the plain `POINTS ────` title row it always did.
      ## CTUI-8's event log, as a value. It shares the `timeline` rectangle with
      ## the scrubber — §3.3.5 is ONE pane holding both, and the Standard and
      ## Ultra-wide layouts call that pane "Timeline & Tracepoints" — so the bar
      ## takes the top `TimelineBarRows` rows and this takes the rest. In the
      ## Compact profile they are two tabs of one stack and each owns its whole
      ## rectangle.
    tracepoints*: TracepointManagerModel
      ## CTUI-8's post-hoc tracepoint dialog. An OVERLAY: when `open` it is
      ## painted over the middle of the body, after every pane, so it is not
      ## one of `projectLayout`'s rectangles and no profile has to make room for
      ## it. Closed by default, so a shell that never opens it paints exactly
      ## the screen it painted before.
    frameViewer*: FrameViewerModel
      ## PLAT-15's frame viewer, magnifier and pixel history. AN OVERLAY, on
      ## exactly `tracepoints`' rule and for the reason
      ## `CodeTracer-TUI-Graphics.md` §8 decision 1 gives: *"a pane that is
      ## available and not placed by default, appearing when a recording
      ## carries graphics events — which is a `Layout-ViewModel` capability (a
      ## pane added programmatically) rather than a graphics one."* Making it
      ## one of `projectLayout`'s rectangles would give every profile a pane
      ## that is meaningless for the programs that draw nothing, which is most
      ## of them.
      ##
      ## CLOSED BY DEFAULT (`initFrameViewerModel`), so a shell that never
      ## opens it paints exactly the screen it painted before this milestone
      ## and every golden written against CTUI-3, CTUI-5, CTUI-6, CTUI-8 and
      ## PLAT-6 is byte-identical.
    highlighting*: HighlighterCache
      ## CTUI-5's risk mitigation, carried on the model rather than created per
      ## frame: "parse once per (path, generation) and cache the token spans".
      ## `nil` means parse every frame, which is what the cold-parse benchmark
      ## measures.
    docked*: seq[DockedPane]
      ## PLAT-6. The auto-hidden panes beside `layout`, which together with it
      ## are the `Layout` this screen is a rendering of.
      ##
      ## A SECOND FIELD RATHER THAN A `Layout`, and that is not squeamishness:
      ## `layout` is a `LayoutNode` because CTUI-3 made it the SESSION'S OWN
      ## tree — the very node `HeadlessApp` created and `saveLayouts`
      ## persists — and replacing it with a `Layout` value would copy the tree
      ## per frame and break that identity. `binding.geometryOf` recombines the
      ## two, and an empty `docked` recombines to exactly the projection CTUI-3
      ## drew, so every golden written before PLAT-6 is byte-identical.
    interaction*: Interaction
      ## PLAT-6. The gesture in flight, READ and never stored: §5's third
      ## obligation is that a binding draws transient state from `Interaction`,
      ## and this field is that reading. Its zero value is `ikNone`, so a shell
      ## that never starts a gesture paints the screen it painted before.
    product*: ProductMode
      ## PLAT-16. Which PRODUCT mode this screen is of.
      ##
      ## `pmDebug` is the zero value, so a shell nobody switched paints exactly
      ## the screen CTUI-3 painted. It is a field of its own beside
      ## `status.mode`, which is the INPUT mode: the two indicators are true at
      ## once and neither is derivable from the other
      ## (CodeTracer-TUI-Edit-Mode.md §1.2).
    fileTree*: FileTreeModel
      ## PLAT-16. Edit mode's `paneFileTree`, as a value. EMPTY BY DEFAULT, on
      ## the rule every pane above follows.
    build*: BuildPaneModel
      ## PLAT-16. Edit mode's `paneBuildOutput`, as a value. Its zero verdict is
      ## `bvIdle`, which is what a project nobody has built is in.
    edit*: EditPaneModel
      ## PLAT-16. Edit mode's Source pane, as a value.
      ##
      ## EMPTY BY DEFAULT, on exactly the rule `source`, `callStack`,
      ## `variables` and `timeline` are built on: `paintPane` delegates the
      ## `editor` rectangle to `views/edit_pane.nim` only in `pmEdit` AND only
      ## with a file open, so a Debug shell paints the pane it always painted.
      ##
      ## A SECOND FIELD BESIDE `source` RATHER THAN A REPLACEMENT FOR IT, which
      ## is §2.1 consequence 1 in the model: the two modes show different
      ## sources through different models, and a screen cannot hold both at
      ## once but a SESSION can — the Debug pane's window survives a trip
      ## through Edit mode because nothing overwrote it.

  ShellScreen* = object
    ## One painted frame, plus the geometry it was painted from, so a test that
    ## reads a row can say which pane owns it without projecting again.
    rows*: seq[string]
    styledRows*: seq[StyledRow]
      ## The same rows, carrying the style CTUI-5's panes paint with. `rows` is
      ## the text of exactly these, so a suite that asserts on text and one
      ## that asserts on colour are reading one screen rather than two.
    body*: CellArea
    projection*: Projection
    overlay*: CellArea
      ## Where the tracepoint dialog was painted, or a zero rectangle when it
      ## was closed. Reported rather than recomputed by the caller, for
      ## `frame_item.FrameItem`'s reason.
    frameViewerOverlay*: CellArea
      ## PLAT-15. Where the frame viewer was painted, or a zero rectangle when
      ## it was closed. A SECOND FIELD rather than a reuse of `overlay`,
      ## because both can be open at once and a single field would report one
      ## of two rectangles with nothing saying which.
    frameViewer*: FrameViewerScreen
      ## PLAT-15. What the frame viewer painted: the tier it drew at, how many
      ## picture rows, how many pixel-history rows, and the candidate masks the
      ## per-cell argmin evaluated. Reported for `projection`'s reason — a test
      ## asserting that the picture degraded while the rest of the pane did not
      ## reads the counts the paint produced rather than recomputing them and
      ## agreeing with itself.
    geometry*: LayoutGeometry
      ## PLAT-6. The dock strips, the inner area the tree was projected into,
      ## and the pane->path resolution — reported for the same reason
      ## `projection` is, so a hit-test in a test reads the coordinates the
      ## paint used rather than recomputing them and agreeing with itself.
    decorations*: seq[LayoutDecoration]
      ## What was painted over the panes: the strips, and whatever the gesture
      ## in flight asked for. Empty when there is no gesture and nothing docked.

const
  PaneSeparatorGlyph* = "│"
    ## The right-hand edge a pane draws when it is not flush with the body's
    ## right edge.
  TimelineTrackGlyph* = "─"
  TimelineCursorGlyph* = "▲"
    ## §3.3.5's execution-pointer marker on the scrubber. The same glyph
    ## `app/views/timeline_bar.NeedleGlyph` paints; kept here because CTUI-3's
    ## own one-line fallback scrubber still uses it when no bounds are known.

  TracepointOverlayWidth* = 64
  TracepointOverlayHeight* = 14
    ## The tracepoint dialog's ceiling. Clamped to the body, so an 80x24
    ## terminal gets a smaller one rather than a clipped one.

  FrameViewerOverlayWidth* = 72
  FrameViewerOverlayHeight* = 18
    ## The frame viewer's ceiling, clamped to the body on the same rule.
    ##
    ## WIDER AND TALLER THAN THE TRACEPOINT DIALOG because what it holds is a
    ## PICTURE, and the picture's fidelity is the pane's whole purpose: at the
    ## default 1:2 cell a square frame occupies twice as many columns as rows
    ## (`aspect.fitToCells`), so a rectangle as tall as it is wide would waste
    ## half of itself. 72x18 is 72 columns of picture over 36 source-pixel rows
    ## at tier 1, which is enough for a magnifier at two cells per pixel to show
    ## a 36x16-pixel neighbourhood.

proc paneTitle*(kind: PaneKind; fallback: string): string =
  ## What a pane calls itself. The `LayoutNode`'s own title wins — it is what a
  ## saved layout carries — and the constant below is only the default
  ## `layout_model` documents as "use the pane's own default, which this module
  ## does not decide either".
  if fallback.len > 0:
    return fallback
  case kind
  of paneEditor: "Source"
  of paneCalltrace: "Call Stack"
  of paneState: "Variables"
  of paneEventLog: "Event Log"
  of paneTimeline: "Timeline"
  of paneDebugControls: "Debug Controls"
  of paneFlow: "Flow"
  of paneSearch: "Search"
  of panePointList: "Points"
  of paneScratchpad: "Scratchpad"
  of paneShell: "Shell"
  of paneFileTree: "Files"
  of paneBuildOutput: "Build & Run"

proc newShellModel*(width, height: int; hdr = initHeaderModel();
                    mode = umNormal; notification = "";
                    product = pmDebug): ShellModel =
  ## A shell sized for this terminal, with a fresh layout for the profile that
  ## size selects and the product mode it was asked for.
  ##
  ## `product` is LAST and defaults to `pmDebug`, so every call site written
  ## before PLAT-16 builds exactly the shell it built.
  let selected = selectProfile(width, height)
  result = ShellModel(
    header: hdr,
    status: initStatusBarModel(mode = mode, profile = selected,
                               notification = notification,
                               product = product),
    layout: layoutForMode(product, selected),
    profile: selected,
    product: product)






proc reprofile*(model: var ShellModel; width, height: int): bool =
  ## Re-select the profile for a new terminal size, replacing the layout tree
  ## only when the profile actually changed.
  ##
  ## Returns whether it changed, and the guard is the point: a resize inside
  ## one profile's band must NOT throw away which tab the user selected, and a
  ## reflow that rebuilt the tree unconditionally would silently reset
  ## `activeIndex` to 0 on every column of a drag.
  let selected = selectProfile(width, height)
  model.status.profile = selected
  if selected == model.profile:
    return false
  model.profile = selected
  model.layout = layoutForMode(model.product, selected)
  true

# ---------------------------------------------------------------------------
# PLAT-16 — the mode register
# ---------------------------------------------------------------------------

type
  ModeRegister* = object
    ## Mode-Transitions.md §4b tier 1: *"the arrangement as the user left this
    ## mode **in this session**"*, plus which mode the session is in.
    ##
    ## ADDRESSED BY THE MODE, and that is the whole design. §4b: *"Not one slot
    ## per direction — a slot filled on the way out of a mode and consumed on
    ## the way back is §6's failure, and it is the shape this section exists to
    ## forbid. A register keyed by the mode makes the nth switch read the cell
    ## the first one wrote."* An `array[ProductMode, LayoutNode]` is that
    ## sentence as a type: there is no cell that is not a mode's, and no mode
    ## without a cell, so the "works once" implementation is not expressible.
    ##
    ## `nil` in a cell means "this mode has not been left in this session
    ## yet", and `switchTo` then falls to §4b's third tier — the mode's own
    ## default. Distinguishing the two matters for §4c obligation 3: *"Only a
    ## real loss is announced. A first visit to a mode is not a degradation."*
    ##
    ## ## A STORED CELL HOLDS THE NODE, NOT A COPY OF IT
    ##
    ## `switchTo` is handed the tree that was on screen and stores that very
    ## `LayoutNode` ref. For Debug mode that node is the SESSION's own — the
    ## one `HeadlessApp` created and `saveLayouts` persists — so returning to
    ## Debug returns the session's tree rather than a snapshot of it, and
    ## `tui_app.shellModel`'s existing rule and this register cannot become two
    ## authorities over one arrangement. Copying here is what would have made
    ## them two, and it is the same hazard PLAT-6 recorded about
    ## `newLayoutHistory` cloning.
    product*: ProductMode
    layouts*: array[ProductMode, LayoutNode]

proc initModeRegister*(product = pmDebug): ModeRegister =
  ModeRegister(product: product)

proc switchTo*(reg: var ModeRegister; leaving: LayoutNode;
               target: ProductMode; profile: LayoutProfile): bool =
  ## Move the register into `target`, preserving the mode it leaves.
  ##
  ## `leaving` is the tree currently on screen, whatever produced it. Returns
  ## whether anything changed.
  ##
  ## ## THE FOUR REQUIREMENTS THIS IS, LINE BY LINE
  ##
  ##   * §6 — *"Switching to the mode the session is already in changes
  ##     nothing."* The guard, and it returns BEFORE the save, so an idempotent
  ##     switch cannot overwrite the other mode's cell either. §6 asks for
  ##     exactly that: *"In particular it must not overwrite the other mode's
  ##     saved arrangement with the current one."*
  ##   * §4 requirement 2 — *"A switch preserves the leaving mode's layout, so
  ##     that returning restores it."*
  ##   * §4 requirement 1 — *"A switch restores the entering mode's layout as
  ##     the user last left it"*: this session's register, then the mode's
  ##     default. *"It never rebuilds from the default when a user arrangement
  ##     exists."*
  ##   * §4 requirement 4 — *"Mode and layout are changed together or not at
  ##     all."* There is no path through this procedure that writes `product`
  ##     without also settling `layouts[product]`.
  ##
  ## §4b's SECOND tier — the device-level store — is NOT implemented here, and
  ## that is stated rather than implied: `app/layout/persistence.nim` +
  ## `host/layout_store.nim` persist ONE arrangement per recording and are not
  ## keyed by mode, so an Edit arrangement made in one session is a default
  ## again in the next. See PLAT-16's status note.
  if target == reg.product:
    return false
  reg.layouts[reg.product] = leaving
  reg.product = target
  if reg.layouts[target].isNil:
    reg.layouts[target] = layoutForMode(target, profile)
  true

proc toggle*(reg: var ModeRegister; leaving: LayoutNode;
             profile: LayoutProfile): bool =
  ## `Ctrl+F5`. ONE command in both directions — Mode-Transitions.md §1 — so it
  ## is `switchTo` applied to `product_mode.toggled`, never a pair of one-way
  ## commands that can get out of step.
  reg.switchTo(leaving, toggled(reg.product), profile)

proc activeLayout*(reg: ModeRegister): LayoutNode =
  ## The tree this register says is on screen, or `nil` when the current mode
  ## has never been entered through a switch — in which case the caller's own
  ## rule decides, which for Debug mode is the session's tree.
  reg.layouts[reg.product]

# ---------------------------------------------------------------------------
# The cell grid
# ---------------------------------------------------------------------------

# CTUI-5 REPLACED THIS GRID'S CELL TYPE, AND KEPT ITS TEXT.
#
# CTUI-3's grid held one-cell STRINGS; `app/views/styled_row.StyledGrid` holds
# a string AND a `CellStyle` per cell, for the reason that module's header
# gives: a string cannot say that column 4 is a red breakpoint dot. Its
# `rowText` is byte-identical to the one this file used to carry, so every
# CTUI-3 assertion written against `shellRows` reads the same screen, and a
# screen with no styled pane on it still fuses into one `LayoutEntry` per row
# and emits the same bytes.

# ---------------------------------------------------------------------------
# Pane painting
# ---------------------------------------------------------------------------

proc titleRow(title: string; width: int): string =
  ## `CALL STACK ─────────` — a pane's first row.
  ##
  ## Uppercased because both §3.1 drawings show pane titles that way in the
  ## wider profile, and the rule glyph makes a pane's extent readable from a
  ## `regionText` at Tier 2 without a border box eating two columns.
  if width <= 0:
    return ""
  var line = toUpperAscii(title)
  if textCells(line) + 1 <= width:
    line.add " "
    # `repeatGlyph` rather than `while textCells(line) < width: line.add …` —
    # see `styled_row.repeatGlyph` for why the obvious spelling is quadratic.
    # This one is the hottest of them all: it draws EVERY pane that has no
    # painter of its own, on every repaint.
    line.add repeatGlyph(PaneRuleGlyph, width - textCells(line))
  fitCells(line, width)

# `tabRow` MOVED to `app/layout/tab_strip.nim` in PLAT-6, unchanged in
# behaviour, and is now ASSEMBLED FROM `tabSpans` — the same table the terminal
# binding's hit-test reads — so a column on screen and a tab index cannot come
# apart. (PLAT-6 landed it as a second traversal that only shared `tabLabel`
# and `TabGapCells`, so the agreement was asserted rather than constructed;
# that sentence was corrected in the module header before the code caught up
# with it.) This module re-exports it (see the `export` above), so `paintPane`'s
# three call sites below are the same call they were.

proc timelineScrubber*(tick, totalTicks, width: int): string =
  ## §3.3.5's scrubber: `[───────▲──────]`, with the marker at the tick's own
  ## proportion of the recording.
  ##
  ## Exposed so a test can assert the marker's COLUMN rather than assert that a
  ## triangle is somewhere on the row — "contains ▲" is satisfied by a scrubber
  ## that puts it at column 0 for every tick.
  if width < 3:
    return spaces(max(0, width))
  let track = width - 2
  var pos = 0
  if totalTicks > 0 and tick > 0:
    pos = int(float(track - 1) * float(min(tick, totalTicks)) /
              float(totalTicks))
  pos = max(0, min(track - 1, pos))
  var line = "["
  for i in 0 ..< track:
    line.add(if i == pos: TimelineCursorGlyph else: TimelineTrackGlyph)
  line.add "]"
  line

proc frameViewerOverlayArea*(body: CellArea): CellArea =
  ## The rectangle PLAT-15's frame viewer occupies: centred in the body, at
  ## most `FrameViewerOverlayWidth` x `FrameViewerOverlayHeight`, never larger
  ## than the body itself. `tracepointOverlayArea`'s shape, with this pane's
  ## own ceiling — a second function rather than a parameterised one, because
  ## the two ceilings are two product decisions and a shared function would
  ## make changing one look like changing both.
  let w = min(FrameViewerOverlayWidth, max(0, body.width))
  let h = min(FrameViewerOverlayHeight, max(0, body.height))
  CellArea(col: body.col + (body.width - w) div 2,
           row: body.row + (body.height - h) div 2,
           width: w, height: h)

proc tracepointOverlayArea*(body: CellArea): CellArea =
  ## The rectangle the tracepoint dialog occupies: centred in the body, at most
  ## `TracepointOverlayWidth` x `TracepointOverlayHeight`, never larger than the
  ## body itself.
  let w = min(TracepointOverlayWidth, max(0, body.width))
  let h = min(TracepointOverlayHeight, max(0, body.height))
  CellArea(col: body.col + (body.width - w) div 2,
           row: body.row + (body.height - h) div 2,
           width: w, height: h)

proc paintPane(g: var StyledGrid; region: PaneRegion; model: ShellModel;
               body: CellArea) =
  ## One pane, into its own rectangle and no other.
  let a = region.area
  if a.width <= 0 or a.height <= 0:
    return
  let flushRight = a.col + a.width >= body.col + body.width
  let inner = if flushRight: a.width else: a.width - 1

  # THE SOURCE PANE OWNS ITS WHOLE RECTANGLE, title row included. CTUI-5's
  # provenance marker lives in that title row, so a shell that painted the
  # generic `SOURCE ────` title first and let the pane fill the body would
  # render a verified file and an unverified one identically at the top of the
  # pane — the exact thing the milestone forbids.
  #
  # PLAT-16: WHICH MODEL THE `editor` RECTANGLE IS PAINTED FROM IS DECIDED BY
  # THE PRODUCT MODE, AND BY NOTHING ELSE.
  #
  # CodeTracer-TUI-Edit-Mode.md §2: Debug shows the recording's source through
  # `SourceVM`'s window, Edit shows the working tree through a whole mutable
  # buffer. They are two models and two painters, and the branch is on
  # `model.product` rather than on "is there an edit buffer" — a branch on the
  # data would paint the edit pane in Debug mode for any session that had ever
  # opened a file, which is the silent cross-mode leak §2.1 consequence 2 warns
  # a user must be able to SEE rather than guess at.
  if region.pane == paneEditor and model.product == pmEdit and
     region.activeTab < 0:
    discard paintEditPane(
      g, CellArea(col: a.col, row: a.row, width: inner, height: a.height),
      model.edit, model.highlighting)
  elif region.pane == paneFileTree and not model.fileTree.isEmpty and
       region.activeTab < 0:
    discard paintFileTree(
      g, CellArea(col: a.col, row: a.row, width: inner, height: a.height),
      model.fileTree)
  elif region.pane == paneBuildOutput and region.activeTab < 0:
    # NO EMPTINESS GUARD, and that is the difference between this pane and
    # every other one. An empty call stack means "no session", which is what
    # the generic title row says perfectly well; an idle BUILD pane is a
    # statement — `BUILD [idle] build: not started` — and a user who has just
    # pressed `:build` needs to see the verdict change from it. A pane that
    # painted a generic title until the first line of output arrived would show
    # nothing at all for the whole of a cold compile.
    discard paintBuildOutput(
      g, CellArea(col: a.col, row: a.row, width: inner, height: a.height),
      model.build)
  elif region.pane == paneEditor and not model.source.isEmpty and
     region.activeTab < 0:
    discard paintSourcePane(
      g, CellArea(col: a.col, row: a.row, width: inner, height: a.height),
      model.source, model.highlighting)
  # THE CALL STACK PANE OWNS ITS WHOLE RECTANGLE, title row included, on the
  # same rule and for the same reason: its title carries the frame count and the
  # thread the backend named, and a shell that painted a generic title first
  # would show a 51-frame stack and a 4-frame one identically at the top.
  elif region.pane == paneCalltrace and not model.callStack.isEmpty and
       region.activeTab < 0:
    discard paintCallStack(
      g, CellArea(col: a.col, row: a.row, width: inner, height: a.height),
      model.callStack)
  # THE VARIABLES PANE IS THE FIRST ONE THAT CAN BE IN A TAB STACK, and that is
  # why this arm is shaped differently from the two above. `paneState` sits in a
  # `stack` with `paneEventLog` in every profile's layout, so the rectangle
  # already carries CTUI-3's tab strip on its first row; the pane owns what is
  # left. Its own title row (`VARIABLES 22 name(s) …`) goes below the strip
  # rather than replacing it, because the strip is what says which of the two
  # stacked panes is on screen and CTUI-9 will make it clickable.
  elif region.pane == paneState and not model.variables.isEmpty:
    if region.activeTab >= 0 and region.tabs.len > 0:
      g.paint(a.row, a.col, tabRow(region.tabs, region.activeTab, inner))
      if a.height >= 2:
        discard paintVariables(
          g, CellArea(col: a.col, row: a.row + 1, width: inner,
                      height: a.height - 1),
          model.variables)
    else:
      discard paintVariables(
        g, CellArea(col: a.col, row: a.row, width: inner, height: a.height),
        model.variables)
  # THE EVENT LOG HAS A RECTANGLE OF ITS OWN in two profiles — a column in
  # Ultra-wide, a tab of the Compact stack — and shares the `timeline` one in
  # the third. This arm is the first two; the third is below.
  elif region.pane == paneEventLog and model.eventLog.hasContent:
    if region.activeTab >= 0 and region.tabs.len > 0:
      g.paint(a.row, a.col, tabRow(region.tabs, region.activeTab, inner))
      if a.height >= 2:
        discard paintEventLog(
          g, CellArea(col: a.col, row: a.row + 1, width: inner,
                      height: a.height - 1),
          model.eventLog)
    else:
      discard paintEventLog(
        g, CellArea(col: a.col, row: a.row, width: inner, height: a.height),
        model.eventLog)
  # PLAT-40. THE POINTS PANE, when a session has supplied its rows. Before this
  # arm the pane reached the terminal as a title over an empty rectangle.
  elif region.pane == panePointList and model.points.loaded:
    if region.activeTab >= 0 and region.tabs.len > 0:
      g.paint(a.row, a.col, tabRow(region.tabs, region.activeTab, inner))
      if a.height >= 2:
        discard paintPointList(
          g, CellArea(col: a.col, row: a.row + 1, width: inner,
                      height: a.height - 1),
          model.points)
    else:
      discard paintPointList(
        g, CellArea(col: a.col, row: a.row, width: inner, height: a.height),
        model.points)
  elif region.activeTab >= 0 and region.tabs.len > 0:
    g.paint(a.row, a.col, tabRow(region.tabs, region.activeTab, inner))
  else:
    g.paint(a.row, a.col, titleRow(paneTitle(region.pane, region.title), inner))

  # THE TIMELINE RECTANGLE HOLDS TWO PANES, which is what §3.3.5 describes and
  # what the Standard and Ultra-wide layouts call "Timeline & Tracepoints". The
  # scrubber takes the top `TimelineBarRows` rows and the event log takes the
  # rest. CTUI-3's own one-line `timelineScrubber` stays as the fallback for a
  # shell with no bounds — see `ShellModel.timeline`.
  if region.pane == paneTimeline and a.height >= 2:
    if model.timeline.boundsKnown:
      discard paintTimelineBar(
        g, CellArea(col: a.col, row: a.row, width: inner, height: a.height),
        model.timeline)
      if a.height > TimelineBarRows:
        discard paintEventLog(
          g, CellArea(col: a.col, row: a.row + TimelineBarRows, width: inner,
                      height: a.height - TimelineBarRows),
          model.eventLog)
    else:
      g.paint(a.row + 1, a.col,
              timelineScrubber(model.header.tick, model.header.totalTicks,
                               inner))
  if not flushRight:
    for row in a.row ..< a.row + a.height:
      g.paint(row, a.col + a.width - 1, PaneSeparatorGlyph)

proc degradedBanner(status: ProjectionStatus; width: int): string =
  ## What a non-`prOk` projection puts on the first body row. It names the
  ## status, so a screenshot of a degraded run is self-describing.
  fitCells("LAYOUT DEGRADED (" & $status & ") — showing a single pane", width)

# ---------------------------------------------------------------------------
# The screen
# ---------------------------------------------------------------------------

proc shellScreen*(model: ShellModel; width, height: int;
                  policy = DefaultProjectionPolicy): ShellScreen =
  ## The whole frame: `height` rows of exactly `width` cells, plus the geometry
  ## they were painted from.
  let body = bodyArea(width, height)
  # PLAT-6: the dock strips come out of the body first and the tree is
  # projected into what is left. With nothing docked, `geometry.inner == body`
  # and `geometry.projection` is exactly `projectLayout(model.layout, body)` —
  # so this is the same call CTUI-3 made, and every golden written before
  # PLAT-6 is byte-identical.
  let composed = initLayout(model.layout, model.docked)
  let geometry = geometryOf(composed, body, model.interaction, policy)
  let projection = geometry.projection
  let decorations = decorationsFor(composed, geometry, model.interaction,
                                   policy)
  result = ShellScreen(rows: @[], styledRows: @[], body: body,
                       projection: projection,
                       overlay: (if model.tracepoints.open:
                                   tracepointOverlayArea(body)
                                 else: CellArea()),
                       frameViewerOverlay: (if model.frameViewer.open:
                                              frameViewerOverlayArea(body)
                                            else: CellArea()),
                       geometry: geometry, decorations: decorations)
  if width <= 0 or height <= 0:
    return

  var g = newStyledGrid(width, height)
  g.paint(0, 0, headerText(model.header, width))

  for region in projection.regions:
    paintPane(g, region, model, geometry.inner)
  if projection.status != prOk and body.height > 0:
    g.paint(body.row, body.col, degradedBanner(projection.status, width))

  # THE TRACEPOINT DIALOG IS AN OVERLAY, painted AFTER every pane and over
  # whichever ones it covers. It is deliberately not one of `projectLayout`'s
  # rectangles: a modal that took a share of the layout would shrink the source
  # pane on a profile that has no room to spare, and every profile would have to
  # be re-measured to add it. `tracepointOverlayArea` is the rectangle, derived
  # from the body, and it is REPORTED on `ShellScreen` so a test reads the same
  # coordinates the paint used.
  # PLAT-15's frame viewer, on the same rule and BELOW the tracepoint dialog in
  # paint order: the dialog is modal and takes text input, so a picture painted
  # over it would obscure the field a user is typing into. The frame viewer is
  # painted first and the dialog, when both are open, is on top.
  if model.frameViewer.open:
    result.frameViewer = paintFrameViewer(g, frameViewerOverlayArea(body),
                                          model.frameViewer)

  if model.tracepoints.open:
    discard paintTracepointManager(g, tracepointOverlayArea(body),
                                   model.tracepoints)

  # PLAT-6's transient state, painted LAST over the body, on exactly the rule
  # above: the drag ghost, the highlighted drop target, the resize guide, the
  # dock strips and a revealed dock are all chrome over the arrangement rather
  # than a share of it. `decorations` is empty when nothing is docked and no
  # gesture is in flight, so this call paints nothing on a screen CTUI-3 would
  # have painted and the goldens do not move.
  paintDecorations(g, decorations)

  var status = model.status
  if projection.status != prOk and status.notification.len == 0:
    status.notification = "layout " & $projection.status
  if height > HeaderRows:
    g.paint(height - 1, 0, statusBarText(status, width))

  for row in 0 ..< height:
    result.rows.add g.rowText(row)
    result.styledRows.add g.rowSpans(row)

proc shellRows*(model: ShellModel; width, height: int;
                policy = DefaultProjectionPolicy): seq[string] =
  ## Just the rows, as text. The shape every CTUI-3 assertion is written
  ## against, unchanged by CTUI-5.
  shellScreen(model, width, height, policy).rows

proc shellStyledRows*(model: ShellModel; width, height: int;
                      policy = DefaultProjectionPolicy): seq[StyledRow] =
  ## The rows with their style. What CTUI-5's pane assertions and the component
  ## tree below both read.
  shellScreen(model, width, height, policy).styledRows

proc renderShellTree*(model: ShellModel; r: TerminalRenderer;
                      width, height: int;
                      policy = DefaultProjectionPolicy): TerminalNode =
  ## The component tree for one frame: one `div` per screen row.
  ##
  ## Built through the renderer's own element API rather than the `ui` DSL, for
  ## the reason `app/tui_app.nim` records — this milestone's compile must not
  ## depend on `isonim`'s tailwind style map being generated.
  styledRowsTree(r, shellStyledRows(model, width, height, policy))
