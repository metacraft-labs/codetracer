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

import std/[options, sets, strutils, unicode, wordwrap]

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
import ./call_trace
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
import ./top_bar
import ./tracepoint_manager
import ./vcs_pane
import ./frame_overlay
import ./variables

export header, status_bar, profile, project, source_pane, styled_row
# PLAT-48: the top bar is painted by this module from a `ShellModel` field.
export top_bar
# PLAT-6 moved `tabRow` and `PaneRuleGlyph` to `app/layout/tab_strip.nim`, so
# the painter and the binding's hit-test read ONE answer about where tab `i`
# sits. Re-exported here because this module declared both before, and every
# CTUI-3 call site must keep resolving.
export tab_strip
export binding
export call_stack, call_trace, variables
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
    fileInfo*: string
      ## The status bar's file info — the current file's language and
      ## encoding (`headless_app/footer_info`), drawn first on the status row
      ## as the desktop draws it; the bottom labels follow it.
    topBar*: TopBarModel
      ## PLAT-48. Row 0: the program menu, the debugger controls, the
      ## omnibar, the session tabs, then `header`'s trace and tick and the
      ## badge (`views/top_bar`). Its menu and omnibar are the shared
      ## ViewModels the runtime holds; a shell built with none (a Tier-1
      ## suite's) draws the row with a closed menu button and omnibar icon.
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
    callTraceLoaded*: bool
      ## Whether a session asked for the call trace (so an empty `callTrace`
      ## means "this recording has none", not "nothing asked yet").
    callTrace*: CallTraceModel
      ## PLAT-47. The recording's call TRACE, as the desktop's calltrace pane
      ## lists it. When it has rows the `calltrace` rectangle draws it; when
      ## the recording provides none, the rectangle falls back to `callStack`
      ## below and says so (`call_trace.StackFallbackTitle`).
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
    vcs*: VcsPaneModel
      ## PLAT-47 deliverable 4. The VCS pane, as a value: the shared `VCSVM`
      ## the desktop's VCS panel draws, read by `host/vcs_source.nim`. Not
      ## loaded by default, so a shell with no repository read paints the
      ## generic title it always did.
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
    dragPointer*: Option[(int, int)]
      ## PLAT-47: the pointer's cell during a drag (row, column) — the
      ## binding's measurement, where the ghost label is drawn. `none` when no
      ## drag is in flight or no pointer is known.
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
    focused*: PaneKind
    hasFocus*: bool
      ## PLAT-46. The pane the keyboard's focus is in (the runtime's
      ## `PaneFocus`), so the shell can give it the FOCUSED border role —
      ## the focused pane is distinguished by its border's colour and weight,
      ## not only by the glyphs every pane shares. `hasFocus` false (the zero
      ## value) paints every pane with the ordinary border role.
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
    topBarLayout*: TopBarLayout
      ## PLAT-48. Where row 0's parts are, so a click is hit-tested against
      ## the cells the paint used (`top_bar.topBarHitAt`).
    topBar*: TopBarModel
      ## PLAT-49: the top bar's model as painted (the header folded in), so
      ## the host can place the omnibar's caret without rebuilding it.
    menuDropdowns*: seq[MenuDropdown]
      ## PLAT-48. The open menu's dropdowns, over everything else.
    frameOverlays*: seq[FrameOverlay]
      ## PLAT-47 deliverable 6: what the compositor draws OVER this frame's
      ## cells — a drag's drop tint and insertion caret (re-colouring, never
      ## replacing, the cells of the region the drop would occupy) and the
      ## ghost label following the pointer. Derived from `decorations`.

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
  ## saved layout carries — and `cells.terminalPaneName` is only the default
  ## `layout_model` documents as "use the pane's own default, which this module
  ## does not decide either". Every pane of the shared default (PLAT-45) takes
  ## that default: its titles are empty on purpose.
  if fallback.len > 0:
    return fallback
  terminalPaneName(kind)

const TerminalCaps = terminalCapability()
  ## PLAT-45 deliverable 2: what this front-end can draw, evaluated once. A
  ## placed pane outside it is painted as a REPORT (`paintReport`), never as an
  ## empty rectangle.

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
                               product = product,
                               fold = foldNote(product, selected)),
    layout: layoutForMode(product, selected),
    profile: selected,
    product: product)






proc reprofile*(model: var ShellModel; width, height: int): bool =
  ## Re-derive the default for a new terminal size, replacing the layout tree
  ## only when the DEFAULT actually changed — i.e. when the new size needs a
  ## different fold depth (PLAT-45).
  ##
  ## Returns whether it changed, and the guard is the point: a resize that
  ## needs the same depth must NOT throw away which tab the user selected, and
  ## a reflow that rebuilt the tree unconditionally would silently reset
  ## `activeIndex` to 0 on every column of a drag.
  let selected = selectProfile(width, height)
  let before = depthFor(model.product, model.profile)
  let after = depthFor(model.product, selected)
  model.status.profile = selected
  model.status.fold = foldNote(model.product, selected)
  model.profile = selected
  if before == after:
    resizeShares(model.layout, model.product, selected)
    return false
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

const
  PaneRuleStyle = CellStyle(role: srBorderPane)
  DividerSurface* = srSurfacePanel
    ## The background every divider cell is painted on: the panes' own
    ## (PLAT-49 finding 13), never a ground of its own.

proc paintTabRow(g: var StyledGrid; row, col: int; tabs: seq[string];
                 active, width: int) =
  ## A tab strip: the strip on its own surface, the active tab lifted onto the
  ## pane's surface and every other tab on the strip's — PLAT-46 deliverable 4,
  ## the desktop's GoldenLayout strip in cells. The TEXT is `tabRow`'s,
  ## unchanged, so every column the hit-test reads is where it was.
  let text = tabRow(tabs, active, width)
  g.fillSurface(row, col, width, 1, srTabBar)
  g.paint(row, col, text, CellStyle(role: srTabBar))
  for span in tabSpans(tabs, active):
    let start = col + span.startCol
    let w = min(span.width, col + width - start)
    if w <= 0:
      continue
    let tabRole = if span.index == active: srTabActive else: srTabInactive
    g.fillSurface(row, start, w, 1, tabRole)
    g.restyleRole(row, start, w, srTabBar, tabRole)

type
  PaneFrame* = object
    ## Where a pane's own box ends and its dividers begin (PLAT-47).
    box*: CellArea
      ## The cells the pane's painters get: its rectangle minus its dividers.
    rightDivider*: bool
      ## The rectangle's last column is a `│` divider: another pane is to the
      ## right. A pane flush with the body's right edge has none.
    bottomDivider*: bool
      ## The rectangle's last row is a `─` divider: another pane is below.
      ## New in PLAT-47. Until then vertically adjacent panes had no line
      ## between them — the lower pane's tab strip, whose `────` rule ran
      ## through it, did that job — and the strip is now shaped by colour
      ## alone (deliverable 8), so the line moved to where the desktop has its
      ## splitter: BETWEEN the panes. It is also what gives the focused pane
      ## an outline on all four sides.

proc paneFrame*(area, body: CellArea): PaneFrame =
  ## A pane's frame inside `body`. A rectangle one cell wide or tall keeps
  ## that cell for its content rather than giving it to a divider.
  let right = area.col + area.width < body.col + body.width and area.width > 1
  let bottom = area.row + area.height < body.row + body.height and
               area.height > 1
  PaneFrame(
    box: CellArea(col: area.col, row: area.row,
                  width: area.width - (if right: 1 else: 0),
                  height: area.height - (if bottom: 1 else: 0)),
    rightDivider: right, bottomDivider: bottom)

proc dividerCells*(regions: seq[PaneRegion]; body: CellArea): HashSet[(int, int)] =
  ## Every divider cell of the screen, as `(row, col)`.
  result = initHashSet[(int, int)]()
  for region in regions:
    let a = region.area
    if a.width <= 0 or a.height <= 0:
      continue
    let f = paneFrame(a, body)
    if f.rightDivider:
      for row in a.row ..< a.row + a.height:
        result.incl (row, a.col + a.width - 1)
    if f.bottomDivider:
      for col in a.col ..< a.col + f.box.width:
        result.incl (a.row + a.height - 1, col)

proc junctionGlyph*(up, down, left, right: bool): string =
  ## The box-drawing glyph that joins a divider cell to the neighbouring
  ## divider cells it touches. `borders.asciiFor` degrades each to `+`, `|`
  ## or `-`.
  let vertical = up or down
  let horizontal = left or right
  if vertical and not horizontal: return PaneSeparatorGlyph
  if horizontal and not vertical: return PaneRuleGlyph
  if up and down and left and right: return "┼"
  if up and down: return (if left: "┤" else: "├")
  if left and right: return (if up: "┴" else: "┬")
  if up: return (if left: "┘" else: "└")
  if left: "┐" else: "┌"

proc focusRing*(focused: CellArea; body: CellArea): HashSet[(int, int)] =
  ## The cells ALL AROUND the focused pane's box — the column left of it, the
  ## column right of it, the row above and the row below, corners included —
  ## whichever pane's divider happens to be in each. Intersected with the
  ## divider cells by the caller, this is the focused pane's outline, closed
  ## and symmetric whichever neighbour OWNS a shared divider: the defect the
  ## user reported on 2026-09-27 was a highlight on the sides the focused pane
  ## drew itself and not on the ones its neighbours drew.
  result = initHashSet[(int, int)]()
  let box = paneFrame(focused, body).box
  let top = box.row - 1
  let bottom = box.row + box.height
  let left = box.col - 1
  let right = box.col + box.width
  for col in left .. right:
    result.incl (top, col)
    result.incl (bottom, col)
  for row in top .. bottom:
    result.incl (row, left)
    result.incl (row, right)

proc paintDividers(g: var StyledGrid; regions: seq[PaneRegion];
                   body: CellArea; focused: CellArea; hasFocus: bool) =
  ## Settle every divider cell once all panes are painted: the glyph that
  ## joins it to its neighbours (a `┬` where a vertical divider meets a
  ## horizontal one, …), and — for the cells around the focused pane — the
  ## focused border role (`focusRing`).
  let cells = dividerCells(regions, body)
  var ring = initHashSet[(int, int)]()
  if hasFocus and focused.width > 0 and focused.height > 0:
    ring = focusRing(focused, body)
  for cell in cells:
    let (row, col) = cell
    if row < 0 or row >= g.height or col < 0 or col >= g.width:
      continue
    let glyph = junctionGlyph(
      up = (row - 1, col) in cells, down = (row + 1, col) in cells,
      left = (row, col - 1) in cells, right = (row, col + 1) in cells)
    let role = if cell in ring: srBorderFocused else: srBorderPane
    # ON THE PANES' OWN SURFACE (PLAT-49, the user, 2026-10-01): a divider is
    # a thin line in the subtle-contrast border foreground, drawn on the same
    # background as the panes either side of it. It used to sit on the canvas
    # — a darker ground than the panels — so every divider read as a band two
    # shades wide rather than a line.
    g.paint(row, col, glyph, CellStyle(role: role, surface: DividerSurface))

proc paintPane(g: var StyledGrid; region: PaneRegion; model: ShellModel;
               body: CellArea) =
  ## One pane, into its own rectangle and no other.
  ##
  ## THE RECTANGLE'S LAST COLUMN AND LAST ROW ARE DIVIDERS when another pane
  ## is beyond them (`paneFrame`): the column a `│`, the row a `─` (PLAT-47).
  ## `a` below is the pane's own box — the rectangle without them — and is
  ## what every painter is handed.
  let full = region.area
  if full.width <= 0 or full.height <= 0:
    return
  let frame = paneFrame(full, body)
  let flushRight = not frame.rightDivider
  let inner = frame.box.width
  let a = CellArea(col: full.col, row: full.row, width: full.width,
                   height: frame.box.height)
  # PLAT-46: THE PANE'S SURFACE FIRST, under every cell of its rectangle, so
  # whatever the painter below leaves blank is the pane's body and not the
  # terminal's background. The editor rectangle is the editor surface.
  #
  # The editor's first row — its tab strip — stays on the strip's surface:
  # the desktop's editor tab sits on its strip, not in the editor.
  g.fillSurface(full.row, full.col, full.width, full.height, srSurfacePanel)
  if region.pane == paneEditor and a.height > 1:
    g.fillSurface(a.row + 1, a.col, inner, a.height - 1, srSurfaceEditor)

  # PLAT-49 (the user, 2026-10-01): NO TITLE ROW INSIDE A PANE. Every pane's
  # first row is a TAB STRIP — a stack's tabs, or a lone pane's one tab with
  # its name — and the strip is what identifies the pane, as the desktop's
  # GoldenLayout header does. The `FILES ─────` / `CALL TRACE 28 call(s) ───`
  # rows the painters below draw first are their own headings; each painter is
  # handed the rectangle FROM THE STRIP'S ROW (`underStrip`), so its heading
  # lands on that row and the strip, painted last, takes its place. Their
  # unit-level output (and every CTUI suite that reads a painter on its own)
  # keeps the heading; the shell never shows it. A painter with NO heading of
  # its own (the timeline, the build pane and the VCS pane, whose first row is
  # content — the build verdict, the branch) is handed the rows BELOW the
  # strip instead (`belowStrip`).
  let stacked = region.activeTab >= 0 and region.tabs.len > 0
  # A LONE EDITOR'S TAB IS ITS FILE, as the desktop's editor tab is: the open
  # file's name (`●` after it while an Edit-mode buffer is modified). A lone
  # pane's strip is not hit-tested tab by tab (pressing anywhere on it picks
  # the pane up, `binding.onMouse`), so the label's width moves nothing.
  var lone = paneTitle(region.pane, region.title)
  if region.pane == paneEditor:
    let file =
      if model.product == pmEdit: editorTabLabel(model.edit.path,
                                                 model.edit.dirty)
      else: editorTabLabel(model.source.path, false)
    if file.len > 0:
      lone = file
  let stripTabs = if stacked: region.tabs else: @[lone]
  let stripActive = if stacked: region.activeTab else: 0
  let under = CellArea(col: a.col, row: a.row, width: inner, height: a.height)
  let content = CellArea(col: a.col, row: a.row + 1, width: inner,
                         height: max(0, a.height - 1))
  template underStrip(body: untyped) =
    if under.height > 1:
      body
  template belowStrip(body: untyped) =
    if content.height > 0:
      body
  # PLAT-16: WHICH MODEL THE `editor` RECTANGLE IS PAINTED FROM IS DECIDED BY
  # THE PRODUCT MODE, AND BY NOTHING ELSE (CodeTracer-TUI-Edit-Mode.md §2):
  # Debug shows the recording's source through `SourceVM`'s window, Edit the
  # working tree through a whole mutable buffer — two models, two painters,
  # and the branch is on `model.product`, never on "is there an edit buffer".
  if region.pane == paneEditor and model.product == pmEdit:
    underStrip:
      discard paintEditPane(g, under, model.edit, model.highlighting)
  elif region.pane == paneFileTree and not model.fileTree.isEmpty:
    underStrip:
      discard paintFileTree(g, under, model.fileTree)
  elif region.pane == paneVcs and model.vcs.loaded:
    belowStrip:
      discard paintVcsPane(g, content, model.vcs)
  elif region.pane == paneBuildOutput:
    # NO EMPTINESS GUARD: an idle BUILD pane is a statement — `[idle] build:
    # not started` — and a user who has just pressed `:build` needs to see the
    # verdict change from it.
    belowStrip:
      discard paintBuildOutput(g, content, model.build)
  elif region.pane == paneEditor and not model.source.isEmpty:
    # CTUI-5's provenance marker stays visible: the gutter carries it on
    # every line (`gutter.initGutterLineSpec`'s `provenance`).
    underStrip:
      discard paintSourcePane(g, under, model.source, model.highlighting)
  elif region.pane == paneCalltrace and not model.callTrace.isEmpty:
    underStrip:
      discard paintCallTrace(g, under, model.callTrace)
  elif region.pane == paneCalltrace and not model.callStack.isEmpty:
    # THE FALLBACK SAYS SO (PLAT-47): the pane where the desktop lists the
    # recording's calls is showing only the stack, because this recording
    # carries no call trace — once a session is open (`callTraceLoaded` is
    # the session's statement that it asked and got nothing). The note is
    # the pane's first content row, in place of the stack's heading.
    if model.callTraceLoaded:
      belowStrip:
        discard paintCallStack(g, content, model.callStack)
        paintFallbackCaption(g, content)
    else:
      underStrip:
        discard paintCallStack(g, under, model.callStack)
  elif region.pane == paneState and not model.variables.isEmpty:
    underStrip:
      discard paintVariables(g, under, model.variables)
  elif region.pane == paneEventLog and model.eventLog.hasContent:
    underStrip:
      discard paintEventLog(g, under, model.eventLog)
  # PLAT-40. THE POINTS PANE, when a session has supplied its rows.
  elif region.pane == panePointList and model.points.loaded:
    underStrip:
      discard paintPointList(g, under, model.points)
  elif not TerminalCaps.canDraw(region.pane):
    # PLAT-45: A REPORT LEAF. The shared default places this pane and the
    # terminal has no view for it, so the slot says which pane it is and why
    # it is not drawn — never an empty rectangle that looks like a pane with
    # nothing in it (PLAT-41's data-or-report rule).
    let report = reportText(
      ReportLeaf(pane: region.pane, frontEnd: feTerminal,
                 reason: TerminalCaps.reasons[region.pane]),
      terminalPaneName(region.pane))
    var line = 0
    if inner > 0:
      for piece in wrapWords(report, max(1, inner)).splitLines():
        if content.row + line >= a.row + a.height:
          break
        g.paint(content.row + line, a.col, fitCells(piece, inner))
        inc line
  paintTabRow(g, a.row, a.col, stripTabs, stripActive, inner)
  # THE EDITOR SAYS WHICH SOURCE IT SHOWS, ALWAYS (CodeTracer-TUI-Edit-Mode
  # §2's Requirement; Mode-Transitions §7): with no title row to carry it, the
  # mode's source statement (`product_mode.sourceStatementFor` — "the working
  # tree" in Edit mode) stands on the strip, right-aligned in the inactive
  # tabs' tier, beside the file's tab — never in a row of the pane.
  if region.pane == paneEditor and not stacked:
    let statement =
      if model.product == pmEdit and model.edit.sourceStatement.len > 0:
        model.edit.sourceStatement
      else: sourceStatementFor(model.product)
    let spans = tabSpans(stripTabs, stripActive)
    let tabEnd = if spans.len > 0: spans[^1].startCol + spans[^1].width else: 0
    let w = textCells(statement) + 1
    if statement.len > 0 and tabEnd + 2 + w <= inner:
      g.paint(a.row, a.col + inner - w, statement & " ",
              CellStyle(role: srTabInactive, surface: srTabBar))

  # THE TIMELINE RECTANGLE HOLDS TWO PANES, which is what §3.3.5 describes and
  # what the Standard and Ultra-wide layouts call "Timeline & Tracepoints". The
  # scrubber takes the top `TimelineBarRows` rows and the event log takes the
  # rest. CTUI-3's own one-line `timelineScrubber` stays as the fallback for a
  # shell with no bounds — see `ShellModel.timeline`.
  #
  # PLAT-45: THE TIMELINE IS A TAB in the shared default (of the event stack),
  # so it is painted UNDER the strip rather than over it — `content`, not the
  # whole rectangle — and the strip stays the thing that says which tab this
  # is, as every other stacked pane's does.
  if region.pane == paneTimeline and content.height >= 2:
    if model.timeline.boundsKnown:
      discard paintTimelineBar(g, content, model.timeline)
      if content.height > TimelineBarRows:
        discard paintEventLog(
          g, CellArea(col: content.col, row: content.row + TimelineBarRows,
                      width: inner, height: content.height - TimelineBarRows),
          model.eventLog)
    else:
      g.paint(content.row + 1, content.col,
              timelineScrubber(model.header.tick, model.header.totalTicks,
                               inner))
  # THE DIVIDERS, in the pane-border role. Their junction glyphs and the
  # focused pane's outline are settled once every pane is painted
  # (`paintDividers`), because both depend on the NEIGHBOURS' dividers.
  if frame.rightDivider:
    for row in full.row ..< full.row + full.height:
      g.paint(row, full.col + full.width - 1, PaneSeparatorGlyph,
              PaneRuleStyle)
  if frame.bottomDivider:
    g.paint(full.row + full.height - 1, full.col,
            repeatGlyph(PaneRuleGlyph, inner), PaneRuleStyle)

proc paintDockStrips*(g: var StyledGrid; geometry: LayoutGeometry) =
  ## PLAT-48 deliverable 6: every auto-hide strip, the terminal's spelling of
  ## the desktop's footer. The strip is a run of cells on the tab-strip
  ## surface; each docked pane's label is a tab on it — the revealed one in
  ## the active tab's colour and weight, the others in the inactive tier. A
  ## top or bottom strip's labels read across; a LEFT or RIGHT strip's read
  ## DOWN, one character per row (a terminal cannot rotate text).
  for strip in geometry.strips:
    let a = strip.area
    if a.isEmptyArea:
      continue
    for row in a.row ..< a.row + a.height:
      g.paint(row, a.col, spaces(a.width), CellStyle(role: srTabBar))
    g.fillSurface(a.row, a.col, a.width, a.height, srTabBar)
    for slot in strip.slots:
      let s = slot.area
      if s.isEmptyArea:
        continue
      # PLAT-49 part B: a label is lit while its pane is PREVIEWED (the hover
      # overlay) or DOCKED OPEN (the click), as the desktop's strip tab is
      # `active` in both states.
      let shown = (geometry.revealing and geometry.revealPane == slot.pane) or
                  (not geometry.openDock.isEmptyArea and
                   geometry.openDockPane == slot.pane)
      let role = if shown: srTabActive else: srTabInactive
      g.fillSurface(s.row, s.col, s.width, s.height, role)
      if strip.edge in {leTop, leBottom}:
        g.paint(s.row, s.col, fitCells(" " & slot.title & " ", s.width),
                CellStyle(role: role, bold: shown))
      else:
        var r = s.row
        for rune in runes(slot.title):
          if r >= s.row + s.height:
            break
          g.paint(r, s.col, fitCells($rune, s.width),
                  CellStyle(role: role, bold: shown))
          inc r

proc paintRevealedPane*(g: var StyledGrid; geometry: LayoutGeometry;
                        model: ShellModel) =
  ## PLAT-48 deliverable 6: A REVEALED DOCK IS THE DOCKED PANE ITSELF, painted
  ## over the body against its edge — its title row and its content, by the
  ## same painter that draws it when it is placed — never a fill glyph, and
  ## never reflowing the arrangement behind it (the rectangle is an overlay,
  ## not one of the projection's regions). Its edge toward the body takes
  ## the focus ring's colour, so where the overlay ends is visible without a
  ## drawn border.
  let a = geometry.reveal
  var title = ""
  for strip in geometry.strips:
    for slot in strip.slots:
      if slot.pane == geometry.revealPane:
        title = slot.title
  let region = PaneRegion(pane: geometry.revealPane, title: title, area: a,
                          tabs: @[], activeTab: -1)
  # AN OVERLAY REPLACES WHAT IS UNDER IT: the cells are cleared first, so no
  # glyph of the panes behind shows through the rows the painter leaves
  # blank. The arrangement behind is not reflowed — it is simply covered.
  for row in a.row ..< a.row + a.height:
    g.paint(row, a.col, spaces(a.width), DefaultCellStyle)
  paintPane(g, region, model, a)
  g.restyle(a.row, a.col, a.width,
            proc(s: CellStyle): CellStyle =
              var r = s
              if r.role in {srChromeTitle, srBorderPane}:
                r.role = srBorderFocused
              r)

proc degradedBanner(status: ProjectionStatus; width: int): string =
  ## What a non-`prOk` projection puts on the first body row. It names the
  ## status, so a screenshot of a degraded run is self-describing.
  fitCells("LAYOUT DEGRADED (" & $status & ") — showing a single pane", width)

# ---------------------------------------------------------------------------
# The screen
# ---------------------------------------------------------------------------

const
  DragGhostStyle* = CellStyle(role: srTabActive, surface: srTabActive,
                              bold: true, reverse: true)
    ## The ghost label: an active tab, lifted off the strip by reverse video.

proc frameOverlaysOf*(decorations: seq[LayoutDecoration]): seq[FrameOverlay] =
  ## The decorations a frame draws as OVERLAYS (`OverlayDecorations`), in
  ## paint order: the tint, the caret over it, the ghost over both.
  for kind in [ldDropTarget, ldDropCaret, ldDragGhost]:
    for d in decorations:
      if d.kind != kind or d.area.isEmptyArea:
        continue
      case kind
      of ldDropTarget:
        result.add FrameOverlay(kind: foTint, row: d.area.row, col: d.area.col,
                                width: d.area.width, height: d.area.height)
      of ldDropCaret:
        result.add FrameOverlay(kind: foCaret, row: d.area.row, col: d.area.col,
                                width: d.area.width, height: d.area.height)
      else:
        result.add FrameOverlay(kind: foLabel, row: d.area.row, col: d.area.col,
                                width: d.area.width, height: 1,
                                text: d.label, style: DragGhostStyle)

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
  let geometry = geometryOf(composed, body, model.interaction, policy,
                            footerLeadCells(model.fileInfo))
  let projection = geometry.projection
  let decorations = decorationsFor(
    composed, geometry, model.interaction, policy,
    pointerRow = (if model.dragPointer.isSome: model.dragPointer.get[0] else: -1),
    pointerCol = (if model.dragPointer.isSome: model.dragPointer.get[1] else: -1))
  result = ShellScreen(rows: @[], styledRows: @[], body: body,
                       projection: projection,
                       overlay: (if model.tracepoints.open:
                                   tracepointOverlayArea(body)
                                 else: CellArea()),
                       frameViewerOverlay: (if model.frameViewer.open:
                                              frameViewerOverlayArea(body)
                                            else: CellArea()),
                       geometry: geometry, decorations: decorations,
                       frameOverlays: frameOverlaysOf(decorations))
  if width <= 0 or height <= 0:
    return

  var g = newStyledGrid(width, height)
  # PLAT-46 deliverable 8: EVERY CELL HAS A SURFACE. The canvas under all of
  # it, the header on a card; each pane fills its own rectangle in `paintPane`
  # and the status line its row below.
  g.fillSurface(0, 0, width, height, srSurfaceCanvas)
  g.fillSurface(0, 0, width, HeaderRows, srSurfaceCard)
  # PLAT-48: ROW 0 IS THE TOP BAR — the menu, the debugger controls, the
  # omnibar and the session tabs, with the header's trace, tick and badge
  # where the row leaves room (`views/top_bar`). The session tabs used to be
  # the header's own strip; they are the top bar's now.
  var bar = model.topBar
  bar.header = model.header
  let barLayout = topBarLayout(bar, width)
  result.topBarLayout = barLayout
  result.topBar = bar
  paintTopBar(g, bar, barLayout)

  for region in projection.regions:
    paintPane(g, region, model, geometry.inner)
  var focusedArea = CellArea()
  if model.hasFocus:
    for region in projection.regions:
      if region.pane == model.focused:
        focusedArea = region.area
  paintDividers(g, projection.regions, geometry.inner, focusedArea,
                model.hasFocus)
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
    let area = frameViewerOverlayArea(body)
    g.fillSurface(area.row, area.col, area.width, area.height, srSurfaceCard)
    result.frameViewer = paintFrameViewer(g, area, model.frameViewer)

  if model.tracepoints.open:
    let area = tracepointOverlayArea(body)
    g.fillSurface(area.row, area.col, area.width, area.height, srSurfaceCard)
    discard paintTracepointManager(g, area, model.tracepoints)

  # PLAT-6's transient state, painted LAST over the body, on exactly the rule
  # above: the drag ghost, the highlighted drop target, the resize guide, the
  # dock strips and a revealed dock are all chrome over the arrangement rather
  # than a share of it. `decorations` is empty when nothing is docked and no
  # gesture is in flight, so this call paints nothing on a screen CTUI-3 would
  # have painted and the goldens do not move.
  paintDecorations(g, decorations)
  # PLAT-49 part B: A DOCKED PANE SHOWN OPEN, in the band the tree gave up
  # (`geometry.openDock`) — a pane of the tiled screen, painted as a placed
  # pane is, with its one-tab strip.
  if not geometry.openDock.isEmptyArea:
    let open = PaneRegion(pane: geometry.openDockPane,
                          title: geometry.openDockTitle,
                          area: geometry.openDock, tabs: @[], activeTab: -1)
    paintPane(g, open, model, geometry.openDock)
  # PLAT-48: the dock strips as labels on the tab-strip surface, and a
  # revealed dock as the docked pane itself, over the body. (The bottom
  # strip is on the status row since PLAT-49 part B and is painted with it,
  # below.)
  paintDockStrips(g, geometry)
  if geometry.revealing and not geometry.reveal.isEmptyArea:
    paintRevealedPane(g, geometry, model)

  # PLAT-48: the menu's dropdowns and the omnibar's results are over
  # EVERYTHING — the panes, the dialogs, the strips — as the desktop's are.
  paintControlTooltip(g, bar, barLayout, width)
  result.menuDropdowns = menuDropdowns(bar, barLayout, width, height)
  paintMenuDropdowns(g, result.menuDropdowns)
  paintOmnibarDropdown(g, bar, barLayout, width, height)

  var status = model.status
  if projection.status != prOk and status.notification.len == 0:
    status.notification = "layout " & $projection.status
  if height > HeaderRows:
    # PLAT-49 part B (finding 9): THE BOTTOM AUTO-HIDE LABELS ARE IN THIS ROW,
    # as the desktop renders them inside its status bar (Auto-Hide-Panes.md
    # §3.1, "Bottom strip integration"), IN THE DESKTOP'S ORDER (measured,
    # `plat49-panes-capture.spec.ts`): the file info first — language and
    # encoding — then the labels, then the status bar's own text.
    let lead = footerLeadCells(model.fileInfo)
    var footerEnd = min(width, lead)
    for strip in geometry.strips:
      if strip.edge == leBottom and strip.area.row == height - 1 and
         not strip.area.isEmptyArea:
        footerEnd = strip.area.col + strip.area.width + 1
    let sc = min(width, footerEnd)
    let sw = width - sc
    g.fillSurface(height - 1, 0, width, 1, srSurfaceStatusLine)
    if lead > 0:
      # In the status line's own text colour, as the rest of its text.
      g.paint(height - 1, 1, fitCells(model.fileInfo, max(0, min(width - 1,
              lead - 3))))
    if sw > 0:
      g.paint(height - 1, sc, statusBarText(status, sw))
      # The two indicators in their own roles: the input mode, then the
      # product mode, exactly where `statusBarText` put them (it never drops
      # them).
      let modeCells = min(sw, textCells($status.mode))
      g.paint(height - 1, sc, fitCells($status.mode, modeCells),
              modeStyle(status.mode))
      let productText = productIndicator(status.product)
      let productCol = sc + textCells($status.mode) + 1
      if productCol < width:
        g.paint(height - 1, productCol,
                fitCells(productText, min(textCells(productText),
                                          width - productCol)),
                productStyle(status.product))
    # The labels over the row's left, after the status line's ground.
    for strip in geometry.strips:
      if strip.edge == leBottom:
        paintDockStrips(g, LayoutGeometry(strips: @[strip],
                                          revealing: geometry.revealing,
                                          revealPane: geometry.revealPane,
                                          openDock: geometry.openDock,
                                          openDockPane: geometry.openDockPane))

  for row in 0 ..< height:
    result.rows.add g.rowText(row)
    result.styledRows.add g.rowSpans(row)

proc shellRows*(model: ShellModel; width, height: int;
                policy = DefaultProjectionPolicy): seq[string] =
  ## Just the rows, as text. The shape every CTUI-3 assertion is written
  ## against, unchanged by CTUI-5.
  shellScreen(model, width, height, policy).rows

proc frameTree*(r: TerminalRenderer; screen: ShellScreen): TerminalNode =
  ## A composed frame as a component tree: its rows, then (PLAT-47) its
  ## overlays over them — the drop tint and caret, the drag ghost — at the
  ## 16-colour Dark rung `styledRowNode` resolves an undegraded row at (see
  ## `styled_row`'s header).
  result = styledRowsTree(r, screen.styledRows)
  if screen.frameOverlays.len > 0:
    for node in overlayNodes(r, screen.frameOverlays, HarnessOverlayCaps):
      r.appendChild(result, node)

proc visibleRows*(screen: ShellScreen): seq[string] =
  ## The frame's rows as a terminal SHOWS them: `rows` with the label
  ## overlays (PLAT-47's drag ghost) written over the cells they cover. Tints
  ## change colours only, so they move no character.
  var grid: seq[seq[string]] = @[]
  for line in screen.rows:
    var row: seq[string] = @[]
    for r in runes(line):
      row.add $r
    grid.add row
  for o in screen.frameOverlays:
    if o.kind != foLabel or o.row < 0 or o.row >= grid.len:
      continue
    var c = o.col
    for r in runes(o.text):
      if c >= 0 and c < grid[o.row].len:
        grid[o.row][c] = $r
      inc c
  for row in grid:
    result.add row.join("")

proc renderShellTree*(model: ShellModel; r: TerminalRenderer;
                      width, height: int;
                      policy = DefaultProjectionPolicy): TerminalNode =
  ## The component tree for one frame: one `div` per screen row.
  ##
  ## Built through the renderer's own element API rather than the `ui` DSL, for
  ## the reason `app/tui_app.nim` records — this milestone's compile must not
  ## depend on `isonim`'s tailwind style map being generated.
  frameTree(r, shellScreen(model, width, height, policy))
