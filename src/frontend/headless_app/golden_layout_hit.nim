## headless_app/golden_layout_hit.nim — Layout-ViewModel §4.2.2: THE DROP
## ZONES ARE GOLDENLAYOUT'S, PORTED, NOT APPROXIMATED (PLAT-51 deliverable 10).
##
## ## What this is
##
## The hit-testing of the GoldenLayout the desktop ships — **golden-layout
## 2.6.0** (`node_modules/golden-layout/src/ts/`) — function for function, as
## pure arithmetic over a GEOMETRY a front-end measured from what it drew:
##
##   | GoldenLayout 2.6.0                                  | here                |
##   |-----------------------------------------------------|---------------------|
##   | `LayoutManager.calculateItemAreas` (layout-manager) | `glItemAreas`       |
##   | `GroundItem.createSideAreas` (items/ground-item)    | `glSideAreas`       |
##   | `Stack.getArea` / `_contentAreaDimensions`          | `glStackAreas`      |
##   | `LayoutManager.getArea(x, y)`                       | `glAreaAt`          |
##   | `Stack.highlightDropZone(x, y)`                     | `glStackSegmentAt`  |
##   | `Stack.highlightHeaderDropZone(x)` (+ placeholder)  | `glHeaderIndexAt`   |
##   | `DragProxy.setDropPosition` (`_area`, `_lastValidArea`) | `glPointerStep` |
##
## Every comparison keeps GoldenLayout's own strictness: `getArea` takes
## `x1 <= x < x2` and the SMALLEST surface (`smallestSurface > area.surface`,
## so on a tie the area listed first wins); a stack's segments are tested
## with STRICT inequalities in declaration order (header, then body or left,
## top, right, bottom), and a point on a boundary matches none and LEAVES the
## stack's previous segment in place; the header's insertion index comes from
## the tabs' midpoints with GoldenLayout's own "give up left of the tabs"
## rule; and the tab-drop PLACEHOLDER (`.lm_drop_tab_placeholder`, one
## element for the whole layout, 100 px in the desktop's stylesheet) is
## inserted where the index says and SHIFTS the tabs after it — which is why
## the header's answer depends on where the placeholder was a moment ago, and
## why this module carries a small `GlDragState` from sample to sample.
##
## ## The one deviation, by the user's direction (2026-10-08)
##
## GoldenLayout's top and bottom segments are the whole upper and lower
## halves of a stack's middle column, so a non-empty stack's body has no
## centre and joining it happens only on its header. The user kept a JOIN in
## the middle of a pane, made SMALLER so it feels closer to GoldenLayout:
## `centreShare` > 0 carves a centred box of that share of the content area
## on both axes OUT OF the top and bottom segments (tested before them), and
## a drop there joins the stack (`segCentre`). The edge segments keep
## GoldenLayout's arithmetic everywhere outside that box, so with
## `centreShare == 0` this module IS GoldenLayout's algorithm — which is how
## the pointer-trace differential proves the port (`test_golden_layout_hit`
## against the real Electron app's own `getArea` / `_dropSegment` /
## `_dropIndex`), and then proves the deviation is exactly the box.
##
## ## Units
##
## GoldenLayout works in CSS pixels. GPUI feeds window pixels; the terminal
## feeds SGR-pixel coordinates (DECSET 1016) when the terminal reports them,
## else the CENTRE of the reported cell through the measured cell size — the
## geometry of its cells is converted through the same size, so the 50 px
## ground band is never rounded away.
##
## Pure: floats and sequences, no layout model, no medium. C and JavaScript
## backends.

import std/math

type
  GlRect* = object
    ## A rectangle in pixels, GoldenLayout's `{x1, y1, x2, y2}`.
    x1*, y1*, x2*, y2*: float

  GlStack* = object
    ## One GoldenLayout STACK (a pane with its header, or several panes as
    ## tabs) as its front-end drew it.
    element*: GlRect
      ## The whole stack, header and content — `getElementArea(this.element)`.
    header*: GlRect
      ## Its header (the tab strip).
    content*: GlRect
      ## Its content area (`_childElementContainer`).
    tabs*: seq[GlRect]
      ## The visible tabs, in order, measured with NO drop placeholder in the
      ## strip.
    tabsAt*: seq[seq[GlRect]]
      ## The visible tabs as the strip draws them WITH the placeholder before
      ## tab `p` (`p == tabs.len`: after the last), for every `p` — GoldenLayout
      ## reads the tabs where they ARE (`getBoundingClientRect`), and a flex
      ## strip SHRINKS its items to make room for the placeholder. Empty when
      ## the front-end's strip simply pushes the tabs after the placeholder
      ## right by `placeholderPx` (both native front-ends do).
    empty*: bool
      ## No content items: GoldenLayout's single `body` segment.

  GlGeometry* = object
    ground*: GlRect
      ## The layout's whole area (`GroundItem`'s element).
    rootIsStack*: bool
      ## The root is a stack: GoldenLayout then lists no side areas ("the
      ## sides of Layout are the same").
    stacks*: seq[GlStack]
      ## In `getAllContentItems` order (depth first) — it decides which of two
      ## equal surfaces wins.
    placeholderPx*: float
      ## How far the tab-drop placeholder pushes the tabs after it: its width
      ## (100 px, `.lm_drop_tab_placeholder`) plus any gap the strip lays
      ## between flex items.

  GlSide* = enum
    ## The ground's side areas, in `GroundItem.Area.oppositeSides`' key order
    ## (`y2`, `x2`, `y1`, `x1`) — the order `createSideAreas` lists them.
    gsTop = "top"        ## `y2`: `y2 = y1 + 50`
    gsLeft = "left"      ## `x2`: `x2 = x1 + 50`
    gsBottom = "bottom"  ## `y1`: `y1 = y2 - 50`
    gsRight = "right"    ## `x1`: `x1 = x2 - 50`

  GlAreaKind* = enum
    gakSide = "side"
    gakStack = "stack"
      ## A stack's whole element (`stack.getArea()`).
    gakHeader = "header"
      ## A stack's header (`header.highlightArea`, pushed right after it).

  GlArea* = object
    rect*: GlRect
    surface*: float
    case kind*: GlAreaKind
    of gakSide:
      side*: GlSide
    of gakStack, gakHeader:
      stack*: int

  GlSegment* = enum
    ## `Stack.Segment`, plus the user's centre.
    segNone = "none"
    segHeader = "header"
    segBody = "body"
    segLeft = "left"
    segTop = "top"
    segRight = "right"
    segBottom = "bottom"
    segCentre = "centre"
      ## The deviation: the smaller middle that JOINS the stack.

  GlStackState* = object
    segment*: GlSegment
      ## `_dropSegment`: what the stack last highlighted.
    dropIndex*: int
      ## `_dropIndex`, -1 until a header hover set it.

  GlDragState* = object
    ## What a drag carries from one pointer sample to the next, as
    ## GoldenLayout's objects carry it: each stack's last segment and index,
    ## the ONE placeholder's place, and `_lastValidArea`.
    stacks*: seq[GlStackState]
    placeholderStack*: int
      ## Whose strip the placeholder is in, -1 when removed.
    placeholderIndex*: int
      ## Before which visible tab it sits (== tab count: after the last).
    lastValid*: int
      ## Index into the areas of the last non-null `getArea`, -1 for none.

  GlDecision* = object
    ## Where a drop would land after one pointer sample: the area GoldenLayout
    ## would drop on (`_area`, or `_lastValidArea` when the pointer is over
    ## none — a splitter's gap, say) and that stack's segment and index.
    found*: bool
      ## False only before any area was ever under the pointer.
    current*: bool
      ## The area is under the pointer NOW (`_area` non-null).
    area*: GlArea
    segment*: GlSegment
    headerIndex*: int

const
  GlSideAreaPx* = 50.0
    ## `createSideAreas`' `areaSize`.
  GlPlaceholderPx* = 100.0
    ## `.lm_drop_tab_placeholder { width: 100px }` (goldenlayout-base.css).
  GlEdgeShare* = 0.25
    ## The left and right hover areas' width, and where the top and bottom
    ## ones begin and end across: `contentWidth * 0.25` / `* 0.75`.
  NativeCentreShare* = 1.0 / 3.0
    ## The user's smaller middle (2026-10-08): the centred third of the
    ## content area on each axis — a ninth of the body, where PLAT-49's
    ## centre was a quarter of it (the middle half on each axis) — carved out
    ## of GoldenLayout's top and bottom segments; everything outside it is
    ## GoldenLayout's.

func width*(r: GlRect): float = r.x2 - r.x1
func height*(r: GlRect): float = r.y2 - r.y1
func surfaceOf*(r: GlRect): float = r.width * r.height

func glRect*(x, y, w, h: float): GlRect =
  GlRect(x1: x, y1: y, x2: x + w, y2: y + h)

func containsHalfOpen(r: GlRect; x, y: float): bool =
  ## `getArea`'s test: `x1 <= x < x2`, `y1 <= y < y2`.
  x >= r.x1 and x < r.x2 and y >= r.y1 and y < r.y2

func containsStrict(r: GlRect; x, y: float): bool =
  ## `highlightDropZone`'s test: `x1 < x < x2`, `y1 < y < y2`.
  r.x1 < x and r.x2 > x and r.y1 < y and r.y2 > y

# ---------------------------------------------------------------------------
# calculateItemAreas
# ---------------------------------------------------------------------------

func glSideAreas*(ground: GlRect): seq[GlArea] =
  ## `GroundItem.createSideAreas`: four 50 px bands INSIDE the layout along
  ## its edges, top, left, bottom, right.
  for side in GlSide:
    var r = ground
    case side
    of gsTop: r.y2 = r.y1 + GlSideAreaPx
    of gsLeft: r.x2 = r.x1 + GlSideAreaPx
    of gsBottom: r.y1 = r.y2 - GlSideAreaPx
    of gsRight: r.x1 = r.x2 - GlSideAreaPx
    result.add GlArea(kind: gakSide, side: side, rect: r,
                      surface: r.surfaceOf)

func glItemAreas*(g: GlGeometry): seq[GlArea] =
  ## `LayoutManager.calculateItemAreas`: the side areas (unless the root is a
  ## stack), then per stack its element and its header.
  if g.stacks.len == 0:
    return @[]
  if not g.rootIsStack:
    result = glSideAreas(g.ground)
  for i, s in g.stacks:
    result.add GlArea(kind: gakStack, stack: i, rect: s.element,
                      surface: s.element.surfaceOf)
    result.add GlArea(kind: gakHeader, stack: i, rect: s.header,
                      surface: s.header.surfaceOf)

func glAreaAt*(areas: openArray[GlArea]; x, y: float): int =
  ## `LayoutManager.getArea`: of the areas containing the point, the one
  ## with the SMALLEST surface (the first, on a tie). -1 for none.
  result = -1
  var smallest = Inf
  for i, a in areas:
    if a.rect.containsHalfOpen(x, y) and smallest > a.surface:
      smallest = a.surface
      result = i

# ---------------------------------------------------------------------------
# A stack's segments
# ---------------------------------------------------------------------------

type
  GlSegmentArea* = object
    segment*: GlSegment
    hover*: GlRect
    highlight*: GlRect
      ## What GoldenLayout's indicator would cover (`highlightArea`).

func glStackAreas*(s: GlStack; centreShare = 0.0): seq[GlSegmentArea] =
  ## `Stack.getArea`'s `_contentAreaDimensions`, in its declaration order —
  ## header; then `body` for an empty stack, else left, top, right, bottom —
  ## with the user's centre (when `centreShare` > 0) placed BEFORE top and
  ## bottom, so it is carved out of them.
  let c = s.content
  let w = c.width
  let h = c.height
  result.add GlSegmentArea(segment: segHeader, hover: s.header,
                           highlight: s.header)
  if s.empty:
    result.add GlSegmentArea(segment: segBody, hover: c, highlight: c)
    return
  result.add GlSegmentArea(
    segment: segLeft,
    hover: GlRect(x1: c.x1, y1: c.y1, x2: c.x1 + w * GlEdgeShare, y2: c.y2),
    highlight: GlRect(x1: c.x1, y1: c.y1, x2: c.x1 + w * 0.5, y2: c.y2))
  if centreShare > 0.0:
    let lo = 0.5 - centreShare / 2.0
    let hi = 0.5 + centreShare / 2.0
    result.add GlSegmentArea(
      segment: segCentre,
      hover: GlRect(x1: c.x1 + w * lo, y1: c.y1 + h * lo,
                    x2: c.x1 + w * hi, y2: c.y1 + h * hi),
      highlight: s.header)
  result.add GlSegmentArea(
    segment: segTop,
    hover: GlRect(x1: c.x1 + w * GlEdgeShare, y1: c.y1,
                  x2: c.x1 + w * (1.0 - GlEdgeShare), y2: c.y1 + h * 0.5),
    highlight: GlRect(x1: c.x1, y1: c.y1, x2: c.x2, y2: c.y1 + h * 0.5))
  result.add GlSegmentArea(
    segment: segRight,
    hover: GlRect(x1: c.x1 + w * (1.0 - GlEdgeShare), y1: c.y1,
                  x2: c.x2, y2: c.y2),
    highlight: GlRect(x1: c.x1 + w * 0.5, y1: c.y1, x2: c.x2, y2: c.y2))
  result.add GlSegmentArea(
    segment: segBottom,
    hover: GlRect(x1: c.x1 + w * GlEdgeShare, y1: c.y1 + h * 0.5,
                  x2: c.x1 + w * (1.0 - GlEdgeShare), y2: c.y2),
    highlight: GlRect(x1: c.x1, y1: c.y1 + h * 0.5, x2: c.x2, y2: c.y2))

func glStackSegmentAt*(s: GlStack; x, y: float;
                       centreShare = 0.0): GlSegment =
  ## `Stack.highlightDropZone`'s choice: the first segment whose hover area
  ## STRICTLY contains the point, `segNone` for none (GoldenLayout then
  ## changes nothing).
  for a in glStackAreas(s, centreShare):
    if a.hover.containsStrict(x, y):
      return a.segment
  segNone

func glTabRect*(s: GlStack; i: int; placeholderAt: int;
                placeholderPx: float): GlRect =
  ## Visible tab `i` as it sits with the placeholder before tab
  ## `placeholderAt` (-1: no placeholder in this strip).
  if placeholderAt >= 0 and placeholderAt < s.tabsAt.len and
     i < s.tabsAt[placeholderAt].len:
    return s.tabsAt[placeholderAt][i]
  result = s.tabs[i]
  if placeholderAt >= 0 and i >= placeholderAt:
    result.x1 += placeholderPx
    result.x2 += placeholderPx

func glHeaderIndexAt*(s: GlStack; x: float; placeholderAt: int;
                      placeholderPx: float): int =
  ## `Stack.highlightHeaderDropZone(x)`: the insertion index, or -1 when
  ## GoldenLayout gives up (left of the tab it ended on, not over any tab).
  ## The tabs are where they are DRAWN — shifted by the placeholder when it
  ## is in this strip.
  let n = s.tabs.len
  if n == 0:
    return 0
  var tabIndex = 0
  var above = false
  var r: GlRect
  while true:
    r = glTabRect(s, tabIndex, placeholderAt, placeholderPx)
    if x >= r.x1 and x < r.x1 + r.width:
      above = true
    else:
      inc tabIndex
    if not (tabIndex < n and not above):
      break
  if not above and x < r.x1:
    return -1
  let halfX = r.x1 + r.width / 2.0
  if x < halfX: tabIndex
  else: min(tabIndex + 1, n)

# ---------------------------------------------------------------------------
# One pointer sample, as `DragProxy.setDropPosition` runs it
# ---------------------------------------------------------------------------

func glDragState*(g: GlGeometry): GlDragState =
  ## A drag's state before its first sample: no segment anywhere, no
  ## placeholder, no valid area yet.
  result = GlDragState(placeholderStack: -1, placeholderIndex: -1,
                       lastValid: -1)
  for _ in g.stacks:
    result.stacks.add GlStackState(segment: segNone, dropIndex: -1)

func glClamp*(g: GlGeometry; x, y: float): (float, float) =
  ## `constrainDragToContainer` (the desktop sets it): a pointer outside the
  ## layout is moved onto its edge before anything is asked — `ceil` of the
  ## left / top edge, `floor` of the right / bottom one, as `setDropPosition`
  ## rounds. So the right and bottom edges land ON `x2` / `y2`, which
  ## `getArea`'s half-open test excludes: past them a fresh drag finds no
  ## area and a drag in flight keeps its last valid one (GoldenLayout's
  ## asymmetry, kept).
  var px = x
  var py = y
  if px <= g.ground.x1: px = ceil(g.ground.x1)
  elif px >= g.ground.x2: px = floor(g.ground.x2)
  if py <= g.ground.y1: py = ceil(g.ground.y1)
  elif py >= g.ground.y2: py = floor(g.ground.y2)
  (px, py)

proc glPointerStep*(g: GlGeometry; areas: openArray[GlArea];
                    state: var GlDragState; x, y: float;
                    centreShare = 0.0): GlDecision =
  ## One pointer position through GoldenLayout: `getArea`, then the chosen
  ## item's `highlightDropZone` — which updates the stack's segment, its
  ## index and the placeholder — and the decision a release would act on
  ## (`onDrop` on `_area`, else on `_lastValidArea`). `x`, `y` are taken as
  ## given; a front-end that constrains the drag calls `glClamp` first.
  let at = glAreaAt(areas, x, y)
  if at >= 0:
    state.lastValid = at
    let a = areas[at]
    case a.kind
    of gakSide:
      # `GroundItem.highlightDropZone` removes the placeholder.
      state.placeholderStack = -1
      state.placeholderIndex = -1
    of gakStack, gakHeader:
      let s = g.stacks[a.stack]
      let seg = glStackSegmentAt(s, x, y, centreShare)
      case seg
      of segNone:
        discard
      of segHeader:
        state.stacks[a.stack].segment = segHeader
        let ph = if state.placeholderStack == a.stack: state.placeholderIndex
                 else: -1
        let idx = glHeaderIndexAt(s, x, ph, g.placeholderPx)
        if s.tabs.len == 0:
          # An empty strip: index 0, and the placeholder is not moved.
          state.stacks[a.stack].dropIndex = 0
        elif idx >= 0:
          state.stacks[a.stack].dropIndex = idx
          state.placeholderStack = a.stack
          state.placeholderIndex = idx
      else:
        # `resetHeaderDropZone` then `highlightBodyDropZone(segment)`.
        state.placeholderStack = -1
        state.placeholderIndex = -1
        state.stacks[a.stack].segment = seg
  if state.lastValid < 0:
    return GlDecision(found: false, current: false, segment: segNone,
                      headerIndex: -1)
  let a = areas[state.lastValid]
  result = GlDecision(found: true, current: at >= 0, area: a,
                      segment: segNone, headerIndex: -1)
  if a.kind != gakSide:
    result.segment = state.stacks[a.stack].segment
    result.headerIndex = state.stacks[a.stack].dropIndex
