## window_geometry.nim — where everything is in the GPUI window, in PIXELS,
## and the hit-test that turns a pointer into the layout model's vocabulary.
##
## ## Why this module exists
##
## The window lays its panes out from the projected dock document
## (`dock_projection.projectDock`): a `StackPanel` is a row or a column whose
## children take its sizes, a `TabPanel` is a pane (or a stack of them, under a
## tab strip). Until PLAT-47 that arithmetic lived inside `main.nim`'s root
## builder and nothing else knew where a pane had landed — so the window could
## not tell which divider a press was on, which tab a drag picked up, or which
## half of a pane a drop would take.
##
## `windowGeometryOf` is now the ONE computation: the root builder draws the
## rectangles it answers (every box gets exactly the width and height here),
## and the hit-test reads the same rectangles. A drawing and a hit-test that
## computed their own would disagree by a gap somewhere, and the drag would
## land one pane over from where the user let go.
##
## ## What the hit-test answers, and what it does not decide
##
## Layout-ViewModel §5's second obligation: a binding converts ITS medium's
## pointer into a `LayoutPointer` (a node path and a zone), and a drop region
## back into its own measurement. Nothing here decides whether a drop is
## legal — `layout_interaction.dropTargetsFor` / `hoverAt` do, from the
## pointer this answers — exactly as the terminal's `binding.pointerAt` hands
## cells to the same functions. The resolution order is the terminal's:
##
##   0. an auto-hide strip: the dock of its edge (`dzOutside<edge>`);
##   1. outside the layout area: the nearest DOCK edge this front-end can
##      place (gpui-kit's dock has no top placement, so the top margin names
##      no target — `dock_projection` would refuse the document a top dock
##      produced, and the window would have nothing to draw);
##   2. a stack's tab strip: the tab under the pointer (`dzTabStrip` on that
##      tab's path), or past the last label `dzCentre` ("append");
##   3. the four edge bands of the pane's body (a quarter of its extent each,
##      nearest side wins, ties left, right, top, bottom), then the centre.
##
## A divider is the GAP between two siblings of a row or a column: a press
## there begins `beginResizeDivider(container, index)`, and the pointer's
## position becomes the fraction `proposeDivider` takes (`dividerFractionAt`).
##
## Pure: integers and the model's values, no renderer, no window.

import std/[json, options, strutils]

import headless_app/layout_model
import headless_app/layout_interaction
import ./chrome
import ./app/pane_names

export layout_model, layout_interaction

const
  TabStripPx* = 30
    ## PLAT-45. The height of a stack's tab strip in the window: one line of
    ## the pane-title face plus the strip's own padding.
  TabPadPx* = 10
    ## The padding either side of a tab's label.
  TabCharPx* = 10
    ## The width budgeted per label character. A tab is given an EXPLICIT
    ## width (`tabWidthPx`) rather than sized by its text, so the strip's
    ## geometry is known here without measuring a font: a click, a drop caret
    ## and the drawn tab cannot disagree about where tab `i` starts. Ten pixels
    ## is wider than the bold face's average advance at the window's text
    ## size, so a label never overflows its tab.
  StripInsetPx* = ChromePaddingPx div 2
    ## The strip's own left padding before the first tab.
  DockBandPx* = 48
    ## How deep the tint of a dock drop is, along the layout's edge.
  DockStripPx* = 24
    ## How thick an AUTO-HIDE STRIP is: the band along a window edge that
    ## holds the panes docked there, one label each (Layout-ViewModel §3.1's
    ## collapsed tabs; the terminal draws the same strip one cell thick).
  DockCharPx* = 16
    ## One character's row in a left or right strip, whose labels read
    ## top to bottom one character per row (GPUI draws no rotated text).
  RevealShareDenominator* = 3
    ## A revealed docked pane takes a third of the tree area on its axis —
    ## the terminal's `binding.RevealShareDenominator`: a peek, with the
    ## arrangement behind it still readable.

type
  PxRect* = object
    ## A rectangle in logical window pixels.
    x*, y*, w*, h*: int

  GeomNodeKind* = enum
    gnSplit
      ## A row or a column: its children tile it with `ChromeGapPx` between.
    gnTabs
      ## A pane, or a stack of panes under a tab strip.

  GeomNode* = object
    path*: string
      ## The LAYOUT node's path (`layout_interaction`'s spelling).
    rect*: PxRect
      ## The node's rectangle. For `gnTabs`, the pane's outer box — its 1px
      ## focus border included.
    case kind*: GeomNodeKind
    of gnSplit:
      horizontal*: bool
      children*: seq[int]
        ## Indices into `WindowGeometry.nodes`.
    of gnTabs:
      stacked*: bool
        ## The layout node is a stack (`lnStack`); a bare pane is not.
      panes*: seq[string]
        ## The pane ids, in tab order.
      labels*: seq[string]
      active*: int
      strip*: PxRect
        ## The tab strip, or a zero rectangle when none is drawn (a bare
        ## pane, or a stack of one).
      tabs*: seq[PxRect]
      body*: PxRect
        ## The pane's own content box: inside the border, below the strip.

  GeomDivider* = object
    container*: string
      ## The row's or column's path.
    index*: int
      ## Between child `index` and `index + 1`.
    horizontal*: bool
      ## The container is a ROW (the divider is a vertical gap).
    rect*: PxRect
    start*: int
      ## The container's first pixel on its axis.
    extent*: int
      ## The container's extent on its axis, gaps EXCLUDED — what its
      ## children's shares divide.

  GeomSlot* = object
    ## One docked pane's label in its edge's strip.
    pane*: string
    label*: string
    rect*: PxRect
      ## Where the label is drawn: a press here reveals the pane, a drag from
      ## here picks it up.

  GeomStrip* = object
    ## One edge's auto-hide strip.
    edge*: LayoutEdge
    rect*: PxRect
    slots*: seq[GeomSlot]

  WindowGeometry* = object
    viewport*: PxRect
    area*: PxRect
      ## The layout's own area: the window minus its padding.
    inner*: PxRect
      ## `area` minus the auto-hide strips (and the gap beside each): what the
      ## TREE is laid out in. Equal to `area` when nothing is docked.
    strips*: seq[GeomStrip]
      ## One per edge that has docked panes, in left, right, top, bottom
      ## order.
    nodes*: seq[GeomNode]
    root*: int
      ## Index of the root node, or -1 when the document drew nothing.
    dividers*: seq[GeomDivider]

func contains*(r: PxRect; x, y: int): bool =
  x >= r.x and x < r.x + r.w and y >= r.y and y < r.y + r.h

func isEmpty*(r: PxRect): bool = r.w <= 0 or r.h <= 0

func tabWidthPx*(label: string): int =
  ## One tab's width: its label at `TabCharPx` a character, padded.
  2 * TabPadPx + TabCharPx * label.len

func labelOf*(paneId: string): string =
  ## The name a tab shows: this window's own name for a built-in pane, the
  ## id for anything else.
  for k in PaneKind:
    if $k == paneId:
      return gpuiPaneName(k)
  paneId

func childPathStr(prefix: string; index: int): string =
  if prefix.len == 0: $index else: prefix & "/" & $index

proc addNode(g: var WindowGeometry; layout: Layout; n: JsonNode;
             path: string; x, y, w, h: int): int =
  ## One dock node at the given rectangle; answers its index, or -1.
  let kind = n{"panel_name"}.getStr
  let info = nodeInfoAtPath(layout.tree, path)
  if kind == "StackPanel":
    let kids = n{"children"}.getElems
    # THE ROOT WRAPPER: `projectDock` wraps a single-pane (or single-stack)
    # root in a one-child `StackPanel`, which no layout node stands for. Its
    # child is the root itself, at the same path and the same rectangle.
    if kids.len == 1 and info.isSome and info.get.kind in {lnPane, lnStack}:
      return g.addNode(layout, kids[0], path, x, y, w, h)
    let stack = n{"info", "stack"}
    let horizontal = stack{"axis"}.getInt == 0
    var node = GeomNode(kind: gnSplit, path: path,
                        rect: PxRect(x: x, y: y, w: max(1, w), h: max(1, h)),
                        horizontal: horizontal, children: @[])
    var total = 0.0
    for i in 0 ..< kids.len:
      total += max(0.0, stack{"sizes"}[i].getFloat)
    let extent = (if horizontal: w else: h) - (kids.len - 1) * ChromeGapPx
    var used = 0
    var cursor = if horizontal: x else: y
    var sizes: seq[int] = @[]
    for i in 0 ..< kids.len:
      let share =
        if total > 0.0: stack{"sizes"}[i].getFloat / total
        else: 1.0 / float(kids.len)
      let px = if i == kids.high: extent - used
               else: int(float(extent) * share)
      used += px
      sizes.add px
    let at = g.nodes.len
    g.nodes.add node
    var childIdx: seq[int] = @[]
    for i, c in kids:
      let px = sizes[i]
      let child =
        if horizontal: g.addNode(layout, c, childPathStr(path, i), cursor, y,
                                 px, h)
        else: g.addNode(layout, c, childPathStr(path, i), x, cursor, w, px)
      if child >= 0: childIdx.add child
      cursor += px
      if i < kids.high:
        let gap =
          if horizontal: PxRect(x: cursor, y: y, w: ChromeGapPx, h: h)
          else: PxRect(x: x, y: cursor, w: w, h: ChromeGapPx)
        g.dividers.add GeomDivider(container: path, index: i,
                                   horizontal: horizontal, rect: gap,
                                   start: (if horizontal: x else: y),
                                   extent: extent)
        cursor += ChromeGapPx
    g.nodes[at].children = childIdx
    return at
  if kind == "TabPanel":
    let tabs = n{"children"}.getElems
    let active = max(0, min(n{"info", "tabs", "active_index"}.getInt,
                            tabs.high))
    var node = GeomNode(kind: gnTabs, path: path,
                        rect: PxRect(x: x, y: y, w: max(1, w), h: max(1, h)),
                        stacked: info.isSome and info.get.kind == lnStack,
                        active: active)
    for t in tabs:
      let id = t{"info", "panel", "pane"}.getStr
      node.panes.add id
      node.labels.add labelOf(id)
    let inner = PxRect(x: x + FocusOutlinePx, y: y + FocusOutlinePx,
                       w: max(1, w - 2 * FocusOutlinePx),
                       h: max(1, h - 2 * FocusOutlinePx))
    if tabs.len > 1:
      node.strip = PxRect(x: inner.x, y: inner.y, w: inner.w, h: TabStripPx)
      var tx = inner.x + StripInsetPx
      for label in node.labels:
        let tw = tabWidthPx(label)
        node.tabs.add PxRect(x: tx, y: inner.y, w: tw, h: TabStripPx)
        tx += tw
      node.body = PxRect(x: inner.x, y: inner.y + TabStripPx, w: inner.w,
                         h: max(1, inner.h - TabStripPx))
    else:
      node.body = inner
    g.nodes.add node
    return g.nodes.high
  -1

func slotExtentPx*(edge: LayoutEdge; label: string): int =
  ## How long one strip label is along its strip: a horizontal (top/bottom)
  ## strip's is a tab's width, a vertical one's a character per row.
  case edge
  of leTop, leBottom: tabWidthPx(label)
  of leLeft, leRight: 2 * TabPadPx + DockCharPx * label.len

proc stripsOf(layout: Layout; area: PxRect):
    tuple[strips: seq[GeomStrip], inner: PxRect] =
  ## THE STRIPS COME OUT OF THE AREA FIRST, and the tree is laid out in what
  ## is left — the terminal's `binding.geometryOf` order: left and right
  ## strips span the area's height, top and bottom ones the width between
  ## them, and a `ChromeGapPx` separates each strip from the tree.
  var has: array[LayoutEdge, bool]
  for edge in LayoutEdge:
    has[edge] = layout.dockedAt(edge).len > 0
  let band = DockStripPx + ChromeGapPx
  let lw = if has[leLeft]: band else: 0
  let rw = if has[leRight]: band else: 0
  let th = if has[leTop]: band else: 0
  let bh = if has[leBottom]: band else: 0
  result.inner = PxRect(x: area.x + lw, y: area.y + th,
                        w: max(1, area.w - lw - rw),
                        h: max(1, area.h - th - bh))
  for edge in [leLeft, leRight, leTop, leBottom]:
    if not has[edge]:
      continue
    let rect =
      case edge
      of leLeft: PxRect(x: area.x, y: area.y, w: DockStripPx, h: area.h)
      of leRight: PxRect(x: area.x + area.w - DockStripPx, y: area.y,
                         w: DockStripPx, h: area.h)
      of leTop: PxRect(x: area.x + lw, y: area.y, w: max(1, area.w - lw - rw),
                       h: DockStripPx)
      of leBottom: PxRect(x: area.x + lw, y: area.y + area.h - DockStripPx,
                          w: max(1, area.w - lw - rw), h: DockStripPx)
    var strip = GeomStrip(edge: edge, rect: rect, slots: @[])
    var cursor = (if edge in {leTop, leBottom}: rect.x else: rect.y) +
                 StripInsetPx
    for d in layout.dockedAt(edge):
      let label = if d.title.len > 0: d.title else: labelOf($d.pane)
      let extent = slotExtentPx(edge, label)
      let slot =
        if edge in {leTop, leBottom}:
          PxRect(x: cursor, y: rect.y, w: extent, h: rect.h)
        else:
          PxRect(x: rect.x, y: cursor, w: rect.w, h: extent)
      strip.slots.add GeomSlot(pane: $d.pane, label: label, rect: slot)
      cursor += extent
    result.strips.add strip

proc windowGeometryOf*(layout: Layout; dock: JsonNode;
                       width, height: int): WindowGeometry =
  ## Where every pane, strip, tab and divider of the window is, for the dock
  ## document `dock` (projected from `layout`) in a `width` x `height` window.
  result = WindowGeometry(
    viewport: PxRect(x: 0, y: 0, w: width, h: height),
    area: PxRect(x: ChromePaddingPx, y: ChromePaddingPx,
                 w: max(1, width - 2 * ChromePaddingPx),
                 h: max(1, height - 2 * ChromePaddingPx)),
    nodes: @[], root: -1, dividers: @[])
  let (strips, inner) = stripsOf(layout, result.area)
  result.strips = strips
  result.inner = inner
  if dock.isNil or dock.kind != JObject or not dock.hasKey("center"):
    return
  result.root = result.addNode(layout, dock["center"], "",
                               result.inner.x, result.inner.y,
                               result.inner.w, result.inner.h)

proc slotAt*(g: WindowGeometry; x, y: int): tuple[strip, slot: int] =
  ## The strip label under a pixel, or (-1, -1).
  for i, st in g.strips:
    if st.rect.contains(x, y):
      for j, sl in st.slots:
        if sl.rect.contains(x, y):
          return (i, j)
  (-1, -1)

proc stripAt*(g: WindowGeometry; x, y: int): int =
  ## The strip under a pixel (on a label or not), or -1.
  for i, st in g.strips:
    if st.rect.contains(x, y):
      return i
  -1

proc revealRectOf*(g: WindowGeometry; edge: LayoutEdge): PxRect =
  ## Where a docked pane is drawn while REVEALED: over the tree, against its
  ## own edge, a third of the tree area deep (`RevealShareDenominator`) —
  ## never reflowing the arrangement behind it.
  let r = g.inner
  case edge
  of leLeft: PxRect(x: r.x, y: r.y, w: max(1, r.w div RevealShareDenominator),
                    h: r.h)
  of leRight:
    let w = max(1, r.w div RevealShareDenominator)
    PxRect(x: r.x + r.w - w, y: r.y, w: w, h: r.h)
  of leTop: PxRect(x: r.x, y: r.y, w: r.w,
                   h: max(1, r.h div RevealShareDenominator))
  of leBottom:
    let h = max(1, r.h div RevealShareDenominator)
    PxRect(x: r.x, y: r.y + r.h - h, w: r.w, h: h)

# ---------------------------------------------------------------------------
# Lookups
# ---------------------------------------------------------------------------

proc tabsNodeAt*(g: WindowGeometry; x, y: int): int =
  ## The pane box under a pixel, or -1 (a gap, the padding, outside).
  for i, n in g.nodes:
    if n.kind == gnTabs and n.rect.contains(x, y):
      return i
  -1

proc tabsNodeOfPane*(g: WindowGeometry; pane: string): int =
  ## The pane box a pane is drawn in — as the active tab or not — or -1.
  for i, n in g.nodes:
    if n.kind == gnTabs and pane in n.panes:
      return i
  -1

proc activePaneAt*(g: WindowGeometry; x, y: int): string =
  ## The pane whose content is under a pixel, or "".
  let i = g.tabsNodeAt(x, y)
  if i < 0: "" else: g.nodes[i].panes[g.nodes[i].active]

proc panePathOf(n: GeomNode; tab: int): string =
  ## The layout path of tab `tab` of a pane box.
  if n.stacked: childPathStr(n.path, tab) else: n.path

proc nodeAtPath(g: WindowGeometry; path: string): int =
  for i, n in g.nodes:
    if n.path == path:
      return i
  -1

proc dropAreaOf*(g: WindowGeometry; path: string): PxRect =
  ## The body a drop onto the node at `path` is measured against: a pane's
  ## content box (below its strip). A path INSIDE a stack names that stack's
  ## body — its tabs share one region.
  let direct = g.nodeAtPath(path)
  if direct >= 0 and g.nodes[direct].kind == gnTabs:
    return g.nodes[direct].body
  let parent = parentPath(path)
  if parent.isSome:
    let up = g.nodeAtPath(parent.get)
    if up >= 0 and g.nodes[up].kind == gnTabs:
      return g.nodes[up].body
  if direct >= 0:
    return g.nodes[direct].rect
  PxRect()

proc tabAt*(g: WindowGeometry; x, y: int): tuple[node, tab: int] =
  ## The tab under a pixel: its pane box and its index, or (-1, -1). A bare
  ## pane's TITLE ROW counts as its one tab — the heading is what a user
  ## grabs to move it, as the terminal's title row is.
  let i = g.tabsNodeAt(x, y)
  if i < 0:
    return (-1, -1)
  let n = g.nodes[i]
  if not n.strip.isEmpty:
    for t, r in n.tabs:
      if r.contains(x, y):
        return (i, t)
    return (-1, -1)
  if y < n.body.y + TabStripPx:
    return (i, 0)
  (-1, -1)

proc dividerAt*(g: WindowGeometry; x, y: int): int =
  ## The divider under a pixel, or -1.
  for i, d in g.dividers:
    if d.rect.contains(x, y):
      return i
  -1

proc dividerFractionAt*(g: WindowGeometry; divider: int; axisPos: int): float =
  ## Where a divider would sit if its gap's leading edge were at `axisPos`
  ## (a pixel on the container's axis), as the fraction `proposeDivider`
  ## takes: the share of the container's extent BEFORE the divider.
  let d = g.dividers[divider]
  let content = axisPos - d.start - d.index * ChromeGapPx
  if d.extent <= 0:
    return 0.0
  clamp(float(content) / float(d.extent), 0.0, 1.0)

const
  GpuiEditorRowPx* = 26
    ## The pitch of one editor row in the window: one line of the editor's
    ## text face at the shim's default size, measured off the window (26 px
    ## from one row to the next on `call_pages`, where every line fits). The
    ## call trace pages by the same pitch.
  EditorLinesAbovePx* = 2 * GpuiEditorRowPx
    ## What the editor pane draws above its rows: its heading and the source
    ## statement (`leaves.renderEditor` draws the statement always).

proc editorRowsOf*(g: WindowGeometry): int =
  ## **How many source rows the editor pane SHOWS**: its body, less its
  ## padding and the two lines above the rows, at the row pitch. The editor's
  ## fetch window holds exactly these, so every row drawn is a full line high
  ## and the execution line centred in the window is centred on screen.
  ## (Until 2026-09-30 the count was the WINDOW's height over a nominal 20 px,
  ## 54 rows in a 1080 px window whose editor shows 37, and the flex column
  ## squeezed each row to 18 px, clipping its descenders.) A window that
  ## draws no editor answers for the tree area.
  let i = g.tabsNodeOfPane("editor")
  let h = if i >= 0: g.nodes[i].body.h else: g.inner.h
  max(1, (h - 2 * ChromePaddingPx - EditorLinesAbovePx) div GpuiEditorRowPx)

# ---------------------------------------------------------------------------
# §5 obligation 2, first direction: PIXELS -> `LayoutPointer`
# ---------------------------------------------------------------------------

proc pointerAt*(g: WindowGeometry; x, y: int): Option[LayoutPointer] =
  ## **The hit-test.** A window pixel, in the layout's own vocabulary. See
  ## the module header for the order.
  if g.root < 0:
    return none(LayoutPointer)
  # An auto-hide strip is the dock of its edge: dropping on it docks there.
  let strip = g.stripAt(x, y)
  if strip >= 0:
    let zone =
      case g.strips[strip].edge
      of leLeft: dzOutsideLeft
      of leRight: dzOutsideRight
      of leTop: dzOutsideTop
      of leBottom: dzOutsideBottom
    return some(LayoutPointer(path: "", zone: zone))
  let a = g.area
  if not a.contains(x, y):
    # The nearest dock edge this front-end can place; the top margin has
    # none (see the header).
    let dl = x - a.x
    let dr = a.x + a.w - 1 - x
    let db = a.y + a.h - 1 - y
    let dt = y - a.y
    if dt < 0 and dt <= min(dl, min(dr, db)):
      return none(LayoutPointer)
    var best = dl
    var zone = dzOutsideLeft
    if dr < best:
      best = dr
      zone = dzOutsideRight
    if db < best:
      zone = dzOutsideBottom
    return some(LayoutPointer(path: "", zone: zone))
  let i = g.tabsNodeAt(x, y)
  if i < 0:
    return none(LayoutPointer)
  let n = g.nodes[i]
  if not n.strip.isEmpty and n.strip.contains(x, y):
    for t, r in n.tabs:
      if r.contains(x, y):
        return some(LayoutPointer(path: n.panePathOf(t), zone: dzTabStrip))
    return some(LayoutPointer(path: n.panePathOf(n.active), zone: dzCentre))
  let path = n.panePathOf(n.active)
  let b = n.body
  if not b.contains(x, y):
    # The border pixel, or the strip's edge: the centre, as the terminal
    # answers for a cell outside the drop area.
    return some(LayoutPointer(path: path, zone: dzCentre))
  let dl = x - b.x
  let dr = b.x + b.w - 1 - x
  let dt = y - b.y
  let db = b.y + b.h - 1 - y
  let bandH = max(1, b.w div 4)
  let bandV = max(1, b.h div 4)
  var zone = dzCentre
  var best = high(int)
  if dl < bandH and dl < best:
    best = dl
    zone = dzLeftEdge
  if dr < bandH and dr < best:
    best = dr
    zone = dzRightEdge
  if dt < bandV and dt < best:
    best = dt
    zone = dzTopEdge
  if db < bandV and db < best:
    zone = dzBottomEdge
  some(LayoutPointer(path: path, zone: zone))

# ---------------------------------------------------------------------------
# §5 obligation 2, second direction: the drop indication -> PIXELS
# ---------------------------------------------------------------------------

func halfOf*(r: PxRect; side: LayoutEdge): PxRect =
  ## The half of `r` on `side`: what a split's new pane would take.
  case side
  of leLeft: PxRect(x: r.x, y: r.y, w: (r.w + 1) div 2, h: r.h)
  of leRight:
    let w = (r.w + 1) div 2
    PxRect(x: r.x + r.w - w, y: r.y, w: w, h: r.h)
  of leTop: PxRect(x: r.x, y: r.y, w: r.w, h: (r.h + 1) div 2)
  of leBottom:
    let h = (r.h + 1) div 2
    PxRect(x: r.x, y: r.y + r.h - h, w: r.w, h: h)

const DropCaretPx* = 3
  ## The insertion caret's width on a tab strip.

proc dropIndicationRects*(g: WindowGeometry; ind: DropIndication):
    tuple[tint, caret: PxRect] =
  ## **The drop indication, resolved against the window's geometry** — the
  ## pixel twin of the terminal's `binding.dropIndicationCells`, from the
  ## same `dropIndicationOf` value:
  ##
  ##   * a split tints the HALF of the target pane's body on the drop's side;
  ##   * a join tints the stack's whole tab strip and marks the insertion
  ##     point with a caret at the slot's left edge (past the last tab: the
  ##     last tab's right edge);
  ##   * a join onto a bare pane tints its whole body;
  ##   * a dock tints a band along that edge of the layout area.
  case ind.kind
  of diNone:
    (tint: PxRect(), caret: PxRect())
  of diSplitHalf:
    (tint: halfOf(g.dropAreaOf(ind.path), ind.side), caret: PxRect())
  of diWholeNode:
    (tint: g.dropAreaOf(ind.path), caret: PxRect())
  of diLayoutEdge:
    let a = g.area
    let band =
      case ind.side
      of leLeft: PxRect(x: a.x, y: a.y, w: DockBandPx, h: a.h)
      of leRight: PxRect(x: a.x + a.w - DockBandPx, y: a.y, w: DockBandPx,
                         h: a.h)
      of leTop: PxRect(x: a.x, y: a.y, w: a.w, h: DockBandPx)
      of leBottom: PxRect(x: a.x, y: a.y + a.h - DockBandPx, w: a.w,
                          h: DockBandPx)
    (tint: band, caret: PxRect())
  of diTabSlot:
    let i = g.nodeAtPath(ind.path)
    if i < 0 or g.nodes[i].kind != gnTabs or g.nodes[i].strip.isEmpty:
      return (tint: PxRect(), caret: PxRect())
    let n = g.nodes[i]
    let cx =
      if ind.slot < n.tabs.len: n.tabs[max(0, ind.slot)].x
      else: n.tabs[^1].x + n.tabs[^1].w
    (tint: n.strip,
     caret: PxRect(x: max(n.strip.x, cx - DropCaretPx div 2), y: n.strip.y,
                   w: DropCaretPx, h: n.strip.h))
