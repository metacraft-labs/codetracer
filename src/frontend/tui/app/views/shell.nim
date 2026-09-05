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

import std/[strutils, unicode]

import isonim_tui

import headless_app/layout_model

import ../layout/profile
import ../layout/project
import ./header
import ./status_bar

export header, status_bar, profile, project

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

  ShellScreen* = object
    ## One painted frame, plus the geometry it was painted from, so a test that
    ## reads a row can say which pane owns it without projecting again.
    rows*: seq[string]
    body*: CellArea
    projection*: Projection

const
  PaneRuleGlyph* = "─"
    ## What fills the rest of a pane's title row. One cell wide (U+2500), so
    ## the row's cell count is its rune count.
  PaneSeparatorGlyph* = "│"
    ## The right-hand edge a pane draws when it is not flush with the body's
    ## right edge.
  TimelineTrackGlyph* = "─"
  TimelineCursorGlyph* = "▲"
    ## §3.3.5's execution-pointer marker on the scrubber.

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

type Grid = object
  ## A mutable screen of one-cell strings. A `seq[string]` per row rather than
  ## a `string` per row, because overwriting the fourth CELL of a row that
  ## contains a three-byte box-drawing glyph is not a byte index.
  width: int
  height: int
  cells: seq[string]

proc newGrid(width, height: int): Grid =
  result = Grid(width: max(0, width), height: max(0, height), cells: @[])
  result.cells = newSeq[string](result.width * result.height)
  for i in 0 ..< result.cells.len:
    result.cells[i] = " "

proc paint(g: var Grid; row, col: int; text: string) =
  ## Write `text` starting at `(row, col)`, clipped at the grid's edges.
  ##
  ## Wide glyphs are written into their first cell and a ZERO-WIDTH marker into
  ## the second, so the row's cell count stays right. This module only paints
  ## width-1 glyphs today; the branch exists so that a pane which starts
  ## painting a CJK identifier does not silently shift every cell after it.
  if row < 0 or row >= g.height:
    return
  var c = col
  for r in runes(text):
    if c >= g.width:
      break
    let w = displayWidth($r)
    if c >= 0:
      g.cells[row * g.width + c] = $r
      if w == 2 and c + 1 < g.width:
        g.cells[row * g.width + c + 1] = ""
    c += max(1, w)

proc rowText(g: Grid; row: int): string =
  result = ""
  for c in 0 ..< g.width:
    result.add g.cells[row * g.width + c]

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
    while textCells(line) < width:
      line.add PaneRuleGlyph
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
    while textCells(line) < width:
      line.add PaneRuleGlyph
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

proc paintPane(g: var Grid; region: PaneRegion; model: ShellModel;
               body: CellArea) =
  ## One pane, into its own rectangle and no other.
  let a = region.area
  if a.width <= 0 or a.height <= 0:
    return
  let flushRight = a.col + a.width >= body.col + body.width
  let inner = if flushRight: a.width else: a.width - 1

  if region.activeTab >= 0 and region.tabs.len > 0:
    g.paint(a.row, a.col, tabRow(region.tabs, region.activeTab, inner))
  else:
    g.paint(a.row, a.col, titleRow(paneTitle(region.pane, region.title), inner))

  if region.pane == paneTimeline and a.height >= 2:
    g.paint(a.row + 1, a.col,
            timelineScrubber(model.header.tick, model.header.totalTicks, inner))

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
  result = ShellScreen(rows: @[], body: body, projection: projection)
  if width <= 0 or height <= 0:
    return

  var g = newGrid(width, height)
  g.paint(0, 0, headerText(model.header, width))

  for region in projection.regions:
    paintPane(g, region, model, body)
  if projection.status != prOk and body.height > 0:
    g.paint(body.row, body.col, degradedBanner(projection.status, width))

  var status = model.status
  if projection.status != prOk and status.notification.len == 0:
    status.notification = "layout " & $projection.status
  if height > HeaderRows:
    g.paint(height - 1, 0, statusBarText(status, width))

  for row in 0 ..< height:
    result.rows.add rowText(g, row)

proc shellRows*(model: ShellModel; width, height: int;
                policy = DefaultProjectionPolicy): seq[string] =
  ## Just the rows. The shape every assertion in this milestone is written
  ## against.
  shellScreen(model, width, height, policy).rows

proc renderShellTree*(model: ShellModel; r: TerminalRenderer;
                      width, height: int;
                      policy = DefaultProjectionPolicy): TerminalNode =
  ## The component tree for one frame: one `div` per screen row.
  ##
  ## Built through the renderer's own element API rather than the `ui` DSL, for
  ## the reason `app/tui_app.nim` records — this milestone's compile must not
  ## depend on `isonim`'s tailwind style map being generated.
  let root = r.createElement("div")
  for line in shellRows(model, width, height, policy):
    let rowNode = r.createElement("div")
    r.appendChild(rowNode, r.createTextNode(line))
    r.appendChild(root, rowNode)
  root
