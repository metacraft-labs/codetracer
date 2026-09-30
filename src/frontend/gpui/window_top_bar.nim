## window_top_bar.nim — PLAT-48 deliverables 1–5, GPUI's rendering: WHERE THE
## TOP BAR'S PARTS ARE, IN PIXELS, and which part a pointer is on.
##
## The window's title band holds what the desktop's caption bar holds: the
## program menu (a `≡` button and, when the band is wide enough, the folder
## titles), the debugger controls (the desktop's own marks), the omnibar and
## the session tabs. The logical state is the shared ViewModels'
## (`MenuVM`, `OmnibarVM`, `session_tabs.tabsOf`, `TransportControls`); this
## module lays it out and hit-tests it, exactly as `window_geometry` does for
## the arrangement below it — one computation the drawing and the pointer
## both read, so a click lands on what is drawn.
##
## Laid out by priority when the window is narrow: the menu button, then the
## controls (dropping from the end of `TextPriority`, the terminal's rule),
## then the omnibar as an icon, then the folder titles, the omnibar's field,
## and the tabs.
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
  OmnibarFieldPx* = 300
  OmnibarFieldMinPx* = 160
  MenuItemPx* = 26
    ## One menu or omnibar row.
  MenuPopoverMinPx* = 240
  OmnibarRows* = 10
  PartGapPx* = 12
    ## The space between two parts of the band.

type
  GTopPart* = enum
    gtMenuButton = "menu"
    gtMenuTitle = "menu-title"
    gtControl = "control"
    gtOmnibar = "omnibar"
    gtTab = "tab"

  GTopSeg* = object
    part*: GTopPart
    rect*: PxRect
    index*: int
      ## The top-level folder's index for a title, the control's
      ## `TransportControls` index, the tab's index.

  GTopLayout* = object
    band*: PxRect
    segs*: seq[GTopSeg]
    menuExpanded*: bool
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

proc gpuiTopBarLayout*(menu: MenuVM; omnibar: OmnibarVM;
                       tabs: seq[SessionTabView]; width: int): GTopLayout =
  ## Where each part goes in a `width`-pixel window. See the header for the
  ## priority order.
  let band = PxRect(x: ChromePaddingPx, y: ChromePaddingPx,
                    w: max(1, width - 2 * ChromePaddingPx), h: TopBarPx)
  result.band = band
  var used = 0
  let avail = band.w
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
  var titlesW = 0
  if not menu.isNil:
    for i in menu.root.visibleChildren():
      titlesW += titlePx(menu.root.children[i].label)
  if titlesW > 0 and take(titlesW - MenuButtonPx):
    result.menuExpanded = true
  if omniW > 0:
    let room = avail - used
    let grow = min(OmnibarFieldPx - omniW, room)
    if omniW + grow >= OmnibarFieldMinPx or omnibarOpen and grow > 0:
      used += grow
      omniW += grow
      result.omnibarField = true
  var tabW: seq[int] = @[]
  if tabs.len >= 2:
    for t in tabs:
      tabW.add titlePx(t.title)

  # Place.
  var x = band.x
  if result.menuExpanded:
    for i in menu.root.visibleChildren():
      let w = titlePx(menu.root.children[i].label)
      result.segs.add GTopSeg(part: gtMenuTitle, index: i,
                              rect: PxRect(x: x, y: band.y, w: w, h: band.h))
      x += w
  else:
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
    result.segs.add GTopSeg(part: gtOmnibar,
                            rect: PxRect(x: x, y: band.y + 3, w: omniW,
                                         h: band.h - 6))
    x += omniW + PartGapPx
  for i, w in tabW:
    if x + w > band.x + band.w:
      break
    result.segs.add GTopSeg(part: gtTab, index: i,
                            rect: PxRect(x: x, y: band.y, w: w, h: band.h))
    x += w

proc segOf*(lay: GTopLayout; part: GTopPart; index = 0): GTopSeg =
  for s in lay.segs:
    if s.part == part and (part notin {gtMenuTitle, gtControl, gtTab} or
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
  ## The open menu's popovers, outermost first: with the folder titles in
  ## the band the top level IS the band and an entered folder drops below
  ## its title; with the `≡` button the top level drops below the button.
  ## Deeper levels open to the right of their parent row.
  if menu.isNil or not menu.isOpen:
    return
  let levels = menu.openLevels()
  var x = lay.band.x
  var y = lay.band.y + lay.band.h
  if lay.menuExpanded and menu.path.len > 0:
    x = lay.segOf(gtMenuTitle, menu.path[0]).rect.x
  let start = if lay.menuExpanded: 1 else: 0
  for depth in start ..< levels.len:
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
  tooltipFor(TransportControls[i], chord)

# ---------------------------------------------------------------------------
# The window's keymap: the DESKTOP'S bindings
# ---------------------------------------------------------------------------

const DesktopDefaultConfig = staticRead("../../config/default_config.yaml")
  ## The desktop's default configuration. Its `bindings:` block is the
  ## chord table the desktop's menu, toolbar tooltips and shortcuts read
  ## (`ui/shortcut_labels.renderChord`); the GPUI window binds and SHOWS the
  ## same chords, so its menu displays what the desktop's displays.

proc desktopBindings*(): Table[string, string] =
  ## `ClientAction` name → the chord text, spelled as the desktop's menu
  ## spells it (`renderChord`: upper case, alternatives joined by a space).
  var inBindings = false
  for raw in DesktopDefaultConfig.splitLines():
    if raw.len == 0:
      continue
    if not raw[0].isSpaceAscii and raw[0] != '#':
      inBindings = raw.startsWith("bindings:")
      continue
    if not inBindings:
      continue
    let line = raw.strip()
    if line.startsWith("#"):
      continue
    let colon = line.find(':')
    if colon <= 0:
      continue
    let action = line[0 ..< colon].strip()
    var value = line[colon + 1 .. ^1].strip()
    if value.len >= 2 and value[0] == '"' and value[^1] == '"':
      value = value[1 .. ^2]
    if value.len > 0 and action notin result:
      result[action] = value.toUpperAscii

func chordOfKey*(key: string; mods: openArray[string]): string =
  ## A GPUI key event as the desktop spells a chord: `SHIFT+F10`, `CTRL+T`.
  var parts: seq[string] = @[]
  if "control" in mods: parts.add "CTRL"
  if "alt" in mods: parts.add "ALT"
  if "shift" in mods: parts.add "SHIFT"
  parts.add key.toUpperAscii
  parts.join("+")

proc actionForChord*(bindings: Table[string, string]; chord: string): string =
  ## The action a chord runs, or "" — each binding's alternatives are
  ## separated by spaces (`forwardContinue: "F8 F2"`).
  for action, chords in bindings:
    for c in chords.splitWhitespace():
      if c == chord:
        return action
  ""

func sessionTabStepOf*(key: string; mods: openArray[string]): int =
  ## The session tabs' keys in the window: `Ctrl+Alt+PageDown` steps to the
  ## next tab, `Ctrl+Alt+PageUp` to the previous one (answers +1 / -1, or 0
  ## for any other key). NOT `Ctrl+Tab`, which the terminal binds
  ## (CodeTracer-TUI.md §3.3.1): this window binds the DESKTOP'S chords, and
  ## the desktop's `Ctrl+Tab` is Switch File (`switchTabHistory`) and its
  ## `Ctrl+PageUp` / `Ctrl+PageDown` step the editor's files — so the
  ## session step takes the one modifier those leave free, rather than
  ## giving a desktop chord a second meaning here.
  if "control" notin mods or "alt" notin mods or "shift" in mods or
     "platform" in mods:
    return 0
  case key.toLowerAscii
  of "pagedown": 1
  of "pageup": -1
  else: 0

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
