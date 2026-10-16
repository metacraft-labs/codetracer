## window_top_bar.nim — PLAT-48 deliverables 1–5, GPUI's rendering: WHERE THE
## TOP BAR'S PARTS ARE, IN PIXELS, and which part a pointer is on.
##
## The window's title band holds what the desktop's caption bar holds: the
## program menu (ONE root `≡` button, as the desktop's: its first-level menus
## are a popover inside it and every folder opens a submenu beside its row —
## PLAT-49), the debugger controls (the desktop's own marks), the omnibar and
## the session tabs. The logical state is the shared ViewModels'
## (`MenuVM`, `OmnibarVM`, `session_tabs.tabsOf`, `TransportControls`); this
## module lays it out and hit-tests it, exactly as `window_geometry` does for
## the arrangement below it — one computation the drawing and the pointer
## both read, so a click lands on what is drawn.
##
## Laid out by priority when the window is narrow: the window buttons
## (PLAT-69: in a window the application decorates, they are how it is
## closed, so they are never squeezed out), the menu button, then the
## controls (dropping from the end of `TextPriority`, the terminal's rule),
## then the omnibar as an icon, then the omnibar's field, and the tabs.
##
## PLAT-69: in that window the band is also the window's TITLE BAR. Its
## window buttons sit at the side, and in the order, the desktop is
## configured for — left of the menu button, or right of the tabs and the
## "+" — each side's buttons in a width reserved for them (the desktop's
## `#menu:has(> .window-menu) { padding-right }`). Which buttons, and where,
## is the caller's to say (`windowButtons`): this module only places them.
##
## Pure: integers and the models' values, no renderer.

import std/[strutils, tables]

import codetracer_embed
import headless_app/session_tabs
import ./chrome
import ./window_geometry

export session_tabs, tables

const
  TopBarPx* = 34
    ## The band's height: one line of the title face plus its padding.
  GpuiTopBandPx* = TopBarPx + ChromeGapPx
    ## What the top bar takes above the arrangement (`windowGeometryOf`'s
    ## `topBandPx`).
  ControlPx* = 30
    ## One debugger control's button: the mark (`ControlIconPx`) centred.
  ControlIconPx* = 18
  MenuButtonPx* = 34
  OmnibarIconPx* = 34
  OmnibarFieldMinPx* = 160
  OmnibarDesktopFloorPx* = 384
    ## PLAT-50: `clamp(24em, 24vw, 40em)`'s floor at the desktop's 16 px em
    ## (components/menu_bar.styl, `COMMAND_PROMPT_WIDTH`).
  OmnibarDesktopCeilingPx* = 640
    ## Its ceiling.
  OmnibarDesktopShare* = 0.24
    ## Its middle term: 24% of the window (`24vw`).
  MenuItemPx* = 26
    ## One menu or omnibar row.
  MenuPopoverMinPx* = 240
  OmnibarRows* = 10
  PartGapPx* = 12
    ## The space between two parts of the band.
  WindowButtonPx* = 24
    ## PLAT-69: one window button, a circle — the desktop's `.window-menu`
    ## `.menu-button-svg` (`1.5em` at its 16 px em).
  WindowButtonGapPx* = 6
    ## Between two window buttons.
  WindowButtonEdgePx* = 5
    ## Between the outermost window button and the band's end (`.window-menu`
    ## `right: 0.3125em`).

type
  GTopPart* = enum
    gtMenuButton = "menu"
    gtControl = "control"
    gtOmnibar = "omnibar"
    gtTab = "tab"
    gtTabClose = "tab-close"
      ## PLAT-49 part B: a session tab's close control (several sessions).
    gtTabAdd = "tab-add"
      ## PLAT-49 part B: the strip's "+" (`NewSessionTabGlyph`).
    gtWindowButton = "window-button"
      ## PLAT-69: a window button — minimize, maximize / restore, close —
      ## in a window whose title bar the application draws. `index` is the
      ## button's `GWindowButton` ordinal.

  GWindowButton* = enum
    ## The buttons of a title bar, named as GNOME's `button-layout` and the
    ## renderer's window regions name them (`data-window-region`).
    gwbMinimize = "minimize"
    gwbMaximize = "maximize"
    gwbClose = "close"

  GWindowButtons* = tuple[left, right: seq[GWindowButton]]
    ## Which buttons a bar draws on each side, in order, left to right. Empty
    ## on both sides where the platform draws the window's frame.

  GTopSeg* = object
    part*: GTopPart
    rect*: PxRect
    index*: int
      ## The control's `TransportControls` index, the tab's index.

  GTopLayout* = object
    band*: PxRect
    segs*: seq[GTopSeg]
    omnibarField*: bool

  GPopover* = object
    ## One open menu level (or the omnibar's results), in window pixels.
    rect*: PxRect
    folderPath*: seq[int]
    rows*: seq[tuple[rect: PxRect, item: int]]
      ## `item` indexes the level's `MenuLevelView.items` (or the omnibar's
      ## results); -1 is a separator gap.

func textPx*(s: string): int =
  ## The band's text width budget: the window's `TabCharPx` a character.
  TabCharPx * s.len

func titlePx(label: string): int = 2 * TabPadPx + textPx(label)

const
  SessionTabGapPx* = 4
    ## PLAT-49 part B (finding 7): the bar between two session tabs — the
    ## desktop's `.session-tab` `margin-right 0.25em` — so each is a separate
    ## item on its own ground.
  SessionTabClosePx* = 20
    ## The close control at a tab's right end (`.session-tab-close`).
  SessionTabAddPx* = 28
    ## The strip's "+", after its tabs (`.session-tab-add`, a small image
    ## button).

func sessionTabText*(t: SessionTabView): string =
  ## What a session tab says: the agent's indicator (working ⟳, completed ✓,
  ## failed ✗, stopped ■) and the label — the title with the agent's
  ## `completed/total` while it works (`SessionTabView.label`).
  let glyph =
    if not t.agent.present: ""
    else:
      case t.agent.lifecycle
      of aslConnecting, aslRunning: "⟳ "
      of aslCompleted: "✓ "
      of aslError: "✗ "
      of aslCancelled, aslDisconnected: "■ "
  glyph & (if t.label.len > 0: t.label else: t.title)

func omnibarDesktopPx*(width: int): int =
  ## PLAT-50: the omnibox's width in a `width`-pixel window — the desktop's
  ## `clamp(24em, 24vw, 40em)`.
  clamp(int(float(width) * OmnibarDesktopShare + 0.5), OmnibarDesktopFloorPx,
        OmnibarDesktopCeilingPx)

func windowButtonsReservePx*(count: int): int =
  ## The width one side's `count` window buttons reserve in the band: the
  ## buttons, the gaps between them, the margin to the band's end and the
  ## gap to the part beside them. Nothing for no buttons.
  if count <= 0: 0
  else: WindowButtonEdgePx + count * WindowButtonPx +
        (count - 1) * WindowButtonGapPx + PartGapPx

proc gpuiTopBarLayout*(menu: MenuVM; omnibar: OmnibarVM;
                       tabs: seq[SessionTabView]; width: int;
                       canAddTab = false;
                       windowButtons: GWindowButtons = (@[], @[])): GTopLayout =
  ## Where each part goes in a `width`-pixel window. See the header for the
  ## priority order.
  let band = PxRect(x: ChromePaddingPx, y: ChromePaddingPx,
                    w: max(1, width - 2 * ChromePaddingPx), h: TopBarPx)
  result.band = band
  # PLAT-69: the window buttons first, at the band's two ends; everything
  # else is laid out in what they leave, `inner`.
  let buttonY = band.y + (band.h - WindowButtonPx) div 2
  for i, b in windowButtons.left:
    result.segs.add GTopSeg(part: gtWindowButton, index: ord(b),
      rect: PxRect(x: band.x + WindowButtonEdgePx +
                      i * (WindowButtonPx + WindowButtonGapPx),
                   y: buttonY, w: WindowButtonPx, h: WindowButtonPx))
  let rightButtons = windowButtons.right.len
  var rightSegs: seq[GTopSeg] = @[]
  for i, b in windowButtons.right:
    let fromEnd = WindowButtonEdgePx + (rightButtons - i) * WindowButtonPx +
                  (rightButtons - 1 - i) * WindowButtonGapPx
    rightSegs.add GTopSeg(part: gtWindowButton, index: ord(b),
      rect: PxRect(x: band.x + band.w - fromEnd, y: buttonY,
                   w: WindowButtonPx, h: WindowButtonPx))
  let leftReserve = windowButtonsReservePx(windowButtons.left.len)
  let rightReserve = windowButtonsReservePx(rightButtons)
  let inner = PxRect(x: band.x + leftReserve, y: band.y,
                     w: max(0, band.w - leftReserve - rightReserve),
                     h: band.h)
  var used = 0
  let avail = inner.w
  proc take(n: int): bool =
    if used + n <= avail:
      used += n
      true
    else: false
  discard take(MenuButtonPx + PartGapPx)
  # The controls, by priority.
  var shown: seq[int] = @[]
  block:
    let room = avail - used - (OmnibarIconPx + PartGapPx)
    let fit = max(0, room div ControlPx)
    if fit >= TransportControls.len:
      for i in 0 ..< TransportControls.len: shown.add i
    else:
      var chosen: seq[int] = @[]
      for id in TextPriority:
        if chosen.len >= fit: break
        chosen.add controlIndex(id)
      for i in 0 ..< TransportControls.len:
        if i in chosen: shown.add i
    if shown.len > 0:
      discard take(shown.len * ControlPx + PartGapPx)
  let omnibarOpen = not omnibar.isNil and omnibar.isOpen
  var omniW = 0
  if take(OmnibarIconPx + PartGapPx):
    omniW = OmnibarIconPx
  if omniW > 0:
    let room = avail - used
    let grow = min(omnibarDesktopPx(width) - omniW, room)
    if omniW + grow >= OmnibarFieldMinPx or omnibarOpen and grow > 0:
      used += grow
      omniW += grow
      result.omnibarField = true
  var tabW: seq[int] = @[]
  if tabs.len >= 2:
    for t in tabs:
      tabW.add titlePx(sessionTabText(t)) +
               (if t.closable: SessionTabClosePx else: 0)

  # Place.
  var x = inner.x
  result.segs.add GTopSeg(part: gtMenuButton,
                          rect: PxRect(x: x, y: band.y, w: MenuButtonPx,
                                       h: band.h))
  x += MenuButtonPx
  x += PartGapPx
  for i in shown:
    result.segs.add GTopSeg(part: gtControl, index: i,
                            rect: PxRect(x: x, y: band.y, w: ControlPx,
                                         h: band.h))
    x += ControlPx
  if shown.len > 0:
    x += PartGapPx
  if omniW > 0:
    # PLAT-50: CENTRED in the band, as the desktop's omnibox is between its
    # two equal-share neighbours (measured: 703..1155 of a 1900 px window);
    # never left of the controls, and moved left only as far as the session
    # tabs and the "+" after it need.
    # PLAT-69: centred in what the window buttons leave of the band, so
    # buttons on one side move it by half their reserve, as the desktop's
    # bar padding moves its omnibox.
    var after = 0
    for w in tabW: after += w + SessionTabGapPx
    if canAddTab: after += SessionTabAddPx + PartGapPx
    let centred = inner.x + (inner.w - omniW) div 2
    let latest = inner.x + inner.w - after - omniW - PartGapPx
    x = max(x, min(centred, latest))
    result.segs.add GTopSeg(part: gtOmnibar,
                            rect: PxRect(x: x, y: band.y + 3, w: omniW,
                                         h: band.h - 6))
    x += omniW + PartGapPx
  for i, w in tabW:
    if x + w > inner.x + inner.w:
      break
    let r = PxRect(x: x, y: band.y + 4, w: w, h: band.h - 8)
    # The close control FIRST, so a press on it is not the tab's
    # (`topBarHitAt` answers the first segment that contains the pixel).
    if tabs[i].closable:
      result.segs.add GTopSeg(part: gtTabClose, index: i,
                              rect: PxRect(x: x + w - SessionTabClosePx,
                                           y: r.y, w: SessionTabClosePx,
                                           h: r.h))
    result.segs.add GTopSeg(part: gtTab, index: i, rect: r)
    x += w + SessionTabGapPx
  # PLAT-49 part B: the "+", after the tabs (with one session, on its own):
  # the desktop's add control is there either way.
  if canAddTab and x + SessionTabAddPx <= inner.x + inner.w:
    result.segs.add GTopSeg(part: gtTabAdd,
                            rect: PxRect(x: x, y: band.y + 4,
                                         w: SessionTabAddPx, h: band.h - 8))
  result.segs.add rightSegs

proc segOf*(lay: GTopLayout; part: GTopPart; index = 0): GTopSeg =
  for s in lay.segs:
    if s.part == part and (part notin {gtControl, gtTab, gtTabClose,
                                       gtWindowButton} or
                           s.index == index):
      return s
  GTopSeg(part: part, rect: PxRect(), index: -1)

proc topBarHitAt*(lay: GTopLayout; x, y: int): GTopSeg =
  ## The part under a pixel; `index = -1` and an empty rect for none.
  for s in lay.segs:
    if s.rect.contains(x, y):
      return s
  GTopSeg(part: gtMenuButton, rect: PxRect(), index: -1)

func popoverWidth(level: MenuLevelView): int =
  var label = 0
  var chord = 0
  for it in level.items:
    label = max(label, textPx(it.label))
    chord = max(chord, textPx(it.shortcut))
  max(MenuPopoverMinPx, 2 * TabPadPx + label + (if chord > 0: 24 + chord
                                                 else: 0) + 24)

proc gpuiMenuPopovers*(menu: MenuVM; lay: GTopLayout;
                       windowW, windowH: int): seq[GPopover] =
  ## The open menu's popovers, outermost first — the desktop's menu: the
  ## first level (File, Edit, …) drops below the root `≡` button and every
  ## entered folder cascades to the RIGHT of the popover that holds it,
  ## level with its parent row.
  if menu.isNil or not menu.isOpen:
    return
  let levels = menu.openLevels()
  var x = max(lay.band.x, lay.segOf(gtMenuButton).rect.x)
  var y = lay.band.y + lay.band.h
  for depth in 0 ..< levels.len:
    let lv = levels[depth]
    if lv.items.len == 0:
      continue
    let w = popoverWidth(lv)
    let px = max(0, min(x, windowW - w))
    var rows: seq[tuple[rect: PxRect, item: int]] = @[]
    var ry = y + 4
    for k, it in lv.items:
      if ry + MenuItemPx > windowH:
        break
      rows.add (rect: PxRect(x: px, y: ry, w: w, h: MenuItemPx), item: k)
      ry += MenuItemPx
      if it.separatorAfter and k < lv.items.high:
        rows.add (rect: PxRect(x: px, y: ry, w: w, h: 8), item: -1)
        ry += 8
    result.add GPopover(rect: PxRect(x: px, y: y, w: w, h: ry - y + 4),
                        folderPath: lv.folderPath, rows: rows)
    if depth < menu.path.len:
      let entered = menu.path[depth]
      for r in rows:
        if r.item >= 0 and lv.items[r.item].index == entered:
          y = r.rect.y - 4
      x = px + w

proc gpuiMenuHitAt*(pops: seq[GPopover]; menu: MenuVM;
                    x, y: int): tuple[inside: bool, path: seq[int]] =
  let levels = menu.openLevels()
  for p in pops:
    if p.rect.contains(x, y):
      for r in p.rows:
        if r.item >= 0 and r.rect.contains(x, y):
          for lv in levels:
            if lv.folderPath == p.folderPath:
              return (true, p.folderPath & @[lv.items[r.item].index])
      return (true, @[])
  (false, @[])

proc gpuiOmnibarPopover*(omnibar: OmnibarVM; lay: GTopLayout;
                         windowH: int): GPopover =
  if omnibar.isNil or not omnibar.isOpen:
    return
  let field = lay.segOf(gtOmnibar).rect
  if field.w <= 0:
    return
  var w = max(field.w, 360)
  let first = max(0, omnibar.selected - OmnibarRows + 1)
  var y = field.y + field.h + 4
  var rows: seq[tuple[rect: PxRect, item: int]] = @[]
  for i in first ..< min(omnibar.results.len, first + OmnibarRows):
    if y + MenuItemPx > windowH:
      break
    rows.add (rect: PxRect(x: field.x, y: y, w: w, h: MenuItemPx), item: i)
    y += MenuItemPx
  if rows.len == 0:
    rows.add (rect: PxRect(x: field.x, y: y, w: w, h: MenuItemPx), item: -1)
    y += MenuItemPx
  GPopover(rect: PxRect(x: field.x, y: field.y + field.h, w: w,
                        h: y - (field.y + field.h) + 4), rows: rows)

func controlTooltip*(i: int; chord: string): string =
  ## The hover popover's text: the ViewModel's tooltip for the control
  ## (`debug_controls_vm.transportTooltip`, PLAT-49).
  transportTooltip(TransportControls[i].id, chord)

# ---------------------------------------------------------------------------
# The desktop's default bindings — the YAML block the desktop's own menu reads
# (the window resolves its keys through `keymap_router` since PLAT-68)
# ---------------------------------------------------------------------------

const DesktopDefaultConfig* = staticRead("../../config/default_config.yaml")
  ## The desktop's default configuration. Its `bindings:` block is the
  ## chord table the desktop's menu, toolbar tooltips and shortcuts read
  ## (`ui/shortcut_labels.renderChord`); the window hands it to
  ## `keymap_importers` for the one-time import of an EDITED copy into
  ## `keybindings.json`.

func overlaps*(a, b: PxRect): bool =
  ## Whether two rectangles share a pixel.
  a.w > 0 and a.h > 0 and b.w > 0 and b.h > 0 and
    a.x < b.x + b.w and b.x < a.x + a.w and
    a.y < b.y + b.h and b.y < a.y + a.h

func pinButtonShown*(pin: PxRect; covers: openArray[PxRect]): bool =
  ## Whether a pane box's pin button is drawn (and can be pressed): not
  ## while something drawn OVER the tree covers it — a revealed pane, a drag's
  ## drop tint or caret, the drag's ghost label. Those are overlays, and a
  ## button of the tree beneath one painted over it (or pressed through it)
  ## would be the tree showing through what sits on top.
  for c in covers:
    if pin.overlaps(c):
      return false
  true
