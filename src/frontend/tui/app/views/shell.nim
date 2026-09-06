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

import ../layout/profile
import ../layout/project
import ../syntax/highlighter
import ./call_stack
import ./event_log
import ./header
import ./source_pane
import ./status_bar
import ./styled_row
import ./timeline_bar
import ./tracepoint_manager
import ./variables

export header, status_bar, profile, project, source_pane, styled_row
export call_stack, variables
export event_log, timeline_bar, tracepoint_manager

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
    highlighting*: HighlighterCache
      ## CTUI-5's risk mitigation, carried on the model rather than created per
      ## frame: "parse once per (path, generation) and cache the token spans".
      ## `nil` means parse every frame, which is what the cold-parse benchmark
      ## measures.

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

const
  PaneRuleGlyph* = "─"
    ## What fills the rest of a pane's title row. One cell wide (U+2500), so
    ## the row's cell count is its rune count.
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

proc newShellModel*(width, height: int; hdr = initHeaderModel();
                    mode = umNormal; notification = ""): ShellModel =
  ## A shell sized for this terminal, with a fresh layout for the profile that
  ## size selects.
  let selected = selectProfile(width, height)
  ShellModel(
    header: hdr,
    status: initStatusBarModel(mode = mode, profile = selected,
                               notification = notification),
    layout: profileLayout(selected),
    profile: selected)

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
  model.layout = profileLayout(selected)
  true

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

proc tabRow(tabs: seq[string]; active, width: int): string =
  ## `[Variables] Timeline Tracepoints ─────` — a stack's first row.
  ##
  ## The active tab is bracketed, which is exactly what §3.1's Compact drawing
  ## shows. This row is the ONLY on-screen consequence of `LayoutNode.activate`,
  ## so `test_layout_profiles.nim` asserts it moves when `activate` is called.
  if width <= 0:
    return ""
  var line = ""
  for i, t in tabs:
    if i > 0:
      line.add " "
    line.add(if i == active: "[" & t & "]" else: " " & t & " ")
  if textCells(line) + 1 <= width:
    line.add " "
    line.add repeatGlyph(PaneRuleGlyph, width - textCells(line))
  fitCells(line, width)

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
  if region.pane == paneEditor and not model.source.isEmpty and
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
  let projection = projectLayout(model.layout, body, policy)
  result = ShellScreen(rows: @[], styledRows: @[], body: body,
                       projection: projection,
                       overlay: (if model.tracepoints.open:
                                   tracepointOverlayArea(body)
                                 else: CellArea()))
  if width <= 0 or height <= 0:
    return

  var g = newStyledGrid(width, height)
  g.paint(0, 0, headerText(model.header, width))

  for region in projection.regions:
    paintPane(g, region, model, body)
  if projection.status != prOk and body.height > 0:
    g.paint(body.row, body.col, degradedBanner(projection.status, width))

  # THE TRACEPOINT DIALOG IS AN OVERLAY, painted AFTER every pane and over
  # whichever ones it covers. It is deliberately not one of `projectLayout`'s
  # rectangles: a modal that took a share of the layout would shrink the source
  # pane on a profile that has no room to spare, and every profile would have to
  # be re-measured to add it. `tracepointOverlayArea` is the rectangle, derived
  # from the body, and it is REPORTED on `ShellScreen` so a test reads the same
  # coordinates the paint used.
  if model.tracepoints.open:
    discard paintTracepointManager(g, tracepointOverlayArea(body),
                                   model.tracepoints)

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
