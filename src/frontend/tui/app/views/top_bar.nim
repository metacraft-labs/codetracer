## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/views/top_bar.nim — PLAT-48 deliverables 1–5, the terminal's
## rendering. THE DESKTOP'S TOP BAR IN ONE ROW: the program menu, the
## debugger controls, the omnibar and the session tabs, then the header's own
## trace and tick fields and the status badge.
##
## ## Logical state in, cells out
##
## Nothing here owns state. The menu is the shared `MenuVM`, the omnibar the
## shared `OmnibarVM`, the tabs `session_tabs.tabsOf` over `HeadlessApp`,
## the controls `transport_icons.TransportControls` with the ViewModel's
## availability — the desktop renders the same models its own way. This
## module decides only what a TERMINAL decides: which cells each part gets,
## what a dropdown looks like, and which part a cell belongs to.
##
## ## Laid out by priority when the row is short
##
## `topBarLayout` hands out the row in this order (each part takes what it
## needs if it still fits):
##
##   1. the status badge, right-aligned — it is what says the program's
##      state, and it was the header's last field to go before PLAT-48;
##   2. the menu as one `≡` button, and the omnibar as one `⌕` button (the
##      omnibar collapses to an icon, deliverable 5) — or, while it is OPEN,
##      as a field wide enough to type in;
##   3. the header's trace and tick, at its narrowest detail;
##   4. the debugger controls: every control that fits, dropping from the
##      end of `transport_icons.TextPriority` first (text mode keeps exactly
##      a priority prefix; the icon modes use the same rule when even glyphs
##      do not fit);
##   5. the menu's folder titles, replacing `≡`;
##   6. the omnibar's field, replacing `⌕`;
##   7. the session tabs, scrolled so the active tab shows;
##   8. the header's fuller detail.
##
## ## Shaped by colour, not glyphs (PLAT-47's rule)
##
## No brackets around the active tab or the open menu, no rules through the
## row: a part is a run of cells on its role's surface. The one exception is
## the status badge, which has always been `[PAUSED]` and is not a tab.

import std/[strutils, unicode]

import isonim_tui

import codetracer_embed   # the Menu / Omnibar ViewModels, the controls
import headless_app/session_tabs

import ../layout/cells
import ../layout/project
import ./header
import ./styled_row

export session_tabs

type
  TopBarPart* = enum
    tpMenuButton = "menu"
    tpMenuTitle = "menu-title"
    tpControl = "control"
    tpOmnibar = "omnibar"
    tpTab = "tab"
    tpTabMore = "tab-more"
    tpHeader = "header"
    tpBadge = "badge"

  TopBarSegment* = object
    part*: TopBarPart
    col*, width*: int
    index*: int
      ## The top-level menu folder's index in `MenuVM.root.children` for a
      ## title; the `TransportControls` index for a control; the tab's index
      ## for a tab (`tpTabMore`: -1 = scroll left, +1 = scroll right).

  TopBarModel* = object
    ## Everything the row shows, as values and the shared ViewModels.
    menu*: MenuVM
    omnibar*: OmnibarVM
    icons*: IconsMode
    graphicsDrawn*: bool
      ## The terminal was measured to draw pictures (kitty graphics). In
      ## `graphics` mode without it the controls fall back to `unicode`
      ## glyphs — a mode the terminal cannot show is never drawn as blanks.
    controlsEnabled*: seq[bool]
      ## Per `TransportControls`, from the ViewModel's `transportAvailable`.
      ## Empty means "no session": every control is drawn disabled.
    hoveredControl*: int
      ## The control under the pointer (or keyboard-focused), -1 for none.
    tabs*: seq[SessionTabView]
    tabScroll*: int
    header*: HeaderModel

  TopBarLayout* = object
    width*: int
    segments*: seq[TopBarSegment]
    menuExpanded*: bool
    omnibarField*: bool
    effectiveIcons*: IconsMode
    shownControls*: seq[int]
    tabFirst*: int

  DropdownRow* = object
    ## One row of a dropdown: an item (its index in the level's folder), or a
    ## separator gap (`item == -1`).
    row*: int
    item*: int

  MenuDropdown* = object
    area*: CellArea
    level*: MenuLevelView
    rows*: seq[DropdownRow]

  TopBarHitKind* = enum
    thNone, thMenuButton, thMenuTitle, thControl, thOmnibar, thTab, thTabMore

  TopBarHit* = object
    kind*: TopBarHitKind
    index*: int

const
  MenuButtonGlyph* = "≡"
  OmnibarGlyph* = "⌕"
  FolderMarker* = "›"
  OmnibarOpenMinCells* = 16
  OmnibarOpenMaxCells* = 40
  OmnibarFieldMaxCells* = 28
  OmnibarFieldMinCells* = 14
  OmnibarResultRows* = 10
  GraphicsControlCells* = 2
    ## A picture control is two cells wide and one tall: about square at the
    ## usual 1:2 cell, which is what the desktop's 16x16 marks are drawn in.
  TopBarPlaceholder* = "Search files, :commands, :sym, #tick"

# ---------------------------------------------------------------------------
# Widths
# ---------------------------------------------------------------------------

proc effectiveIconsOf*(m: TopBarModel): IconsMode =
  if m.icons == imGraphics and not m.graphicsDrawn: imUnicode else: m.icons

proc controlCells*(mode: IconsMode; i: int): int =
  ## One control's cells, its padding included.
  case mode
  of imGraphics: GraphicsControlCells + 1
  of imText: textButtonCells(TransportControls[i])
  else: textCells(TransportControls[i].glyphFor(mode)) + 2

proc controlsSubset*(mode: IconsMode; budget: int): seq[int] =
  ## The controls that fit `budget` cells: every one when they all do, else
  ## the longest prefix of `TextPriority` that fits — the text mode's rule,
  ## used by every mode — in toolbar order.
  if mode == imText:
    return textPrioritySubset(budget, gap = 1)
  var total = 0
  for i in 0 ..< TransportControls.len:
    total += controlCells(mode, i)
  if total <= budget:
    for i in 0 ..< TransportControls.len: result.add i
    return
  var chosen: seq[int] = @[]
  var used = 0
  for id in TextPriority:
    let i = controlIndex(id)
    let w = controlCells(mode, i)
    if used + w > budget:
      break
    used += w
    chosen.add i
  for i in 0 ..< TransportControls.len:
    if i in chosen:
      result.add i

proc controlsWidth(mode: IconsMode; shown: seq[int]): int =
  for k, i in shown:
    result += controlCells(mode, i)
    if mode == imText and k > 0:
      inc result

proc menuTitlesWidth(vm: MenuVM): int =
  for i in vm.root.visibleChildren():
    result += textCells(vm.root.children[i].label) + 2

# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------

proc topBarLayout*(m: TopBarModel; width: int): TopBarLayout =
  ## Which cells each part of the row gets. See the module header for the
  ## priority order.
  result = TopBarLayout(width: width, effectiveIcons: m.effectiveIconsOf,
                        tabFirst: 0)
  if width <= 0:
    return
  let badge = "[" & $m.header.status & "]"
  let badgeW = textCells(badge)
  if badgeW >= width:
    result.segments.add TopBarSegment(part: tpBadge, col: 0, width: width)
    return
  let avail = width - badgeW - 1
  var used = 0
  proc take(n: int): bool =
    if used + n <= avail:
      used += n
      true
    else: false

  let omnibarOpen = not m.omnibar.isNil and m.omnibar.isOpen
  # 2. The menu button and the omnibar's button (or its open field).
  var menuW = if take(3): 3 else: 0
  var omniW = 0
  if omnibarOpen:
    let want = max(OmnibarOpenMinCells, min(OmnibarOpenMaxCells, width div 3))
    let room = avail - used - 1
    omniW = min(want, room)
    if omniW >= 6: discard take(omniW + 1) else: omniW = 0
    result.omnibarField = omniW > 0
  elif take(4):
    omniW = 3
  # 3. The header at its narrowest detail, leaving room for three controls.
  let firstThree = controlsWidth(result.effectiveIcons,
                                 controlsSubset(result.effectiveIcons, 1000)[0 ..< 3])
  var headerText = headerFields(m.header, hdTickOnly).join(" | ")
  var headerBudget = avail - used - firstThree - 2
  var headerW = 0
  if headerBudget >= 10:
    headerW = min(textCells(headerText), headerBudget)
    discard take(headerW + 1)
  # 4. The controls.
  let controlBudget = avail - used - 1
  result.shownControls = controlsSubset(result.effectiveIcons,
                                        max(0, controlBudget))
  let controlsW = controlsWidth(result.effectiveIcons, result.shownControls)
  if controlsW > 0:
    discard take(controlsW + 1)
  # 5. The menu titles.
  if not m.menu.isNil:
    let titles = menuTitlesWidth(m.menu)
    if titles > 0 and titles > menuW and take(titles - menuW):
      menuW = titles
      result.menuExpanded = true
  # 6. The omnibar field.
  if not omnibarOpen and omniW > 0:
    let room = avail - used
    if room >= OmnibarFieldMinCells - omniW:
      let grown = min(OmnibarFieldMaxCells, omniW + room)
      if grown >= OmnibarFieldMinCells:
        used += grown - omniW
        omniW = grown
        result.omnibarField = true
  # 7. The session tabs, only when there are several.
  var tabSegs: seq[TopBarSegment] = @[]
  var tabsW = 0
  if m.tabs.len >= 2:
    var widths: seq[int] = @[]
    var active = 0
    for i, t in m.tabs:
      widths.add textCells(t.title) + 2
      if t.active: active = i
    let room = avail - used - 1
    var total = 0
    for w in widths: total += w
    if total <= room:
      result.tabFirst = 0
      for i, w in widths:
        tabSegs.add TopBarSegment(part: tpTab, width: w, index: i)
        tabsW += w
    elif room >= 4 + widths[active]:
      # Scrolled: `‹` and `›` take a cell each.
      let first = scrollToShow(widths, active, room - 2, m.tabScroll)
      result.tabFirst = first
      tabSegs.add TopBarSegment(part: tpTabMore, width: 1, index: -1)
      tabsW = 2
      for i in first ..< widths.len:
        if tabsW + widths[i] > room:
          break
        tabSegs.add TopBarSegment(part: tpTab, width: widths[i], index: i)
        tabsW += widths[i]
      tabSegs.add TopBarSegment(part: tpTabMore, width: 1, index: 1)
    if tabsW > 0:
      discard take(tabsW + 1)
  # 8. The header's fuller detail, with what is left.
  if headerW > 0:
    let room = headerW + (avail - used)
    for detail in [hdFull, hdNoKind, hdNoArch]:
      let candidate = headerFields(m.header, detail).join(" | ")
      if textCells(candidate) <= room:
        used += textCells(candidate) - headerW
        headerText = candidate
        headerW = textCells(candidate)
        break

  # Place, left to right: menu, controls, omnibar, tabs; header and badge on
  # the right.
  var col = 0
  if menuW > 0:
    if result.menuExpanded:
      for i in m.menu.root.visibleChildren():
        let w = textCells(m.menu.root.children[i].label) + 2
        result.segments.add TopBarSegment(part: tpMenuTitle, col: col,
                                          width: w, index: i)
        col += w
    else:
      result.segments.add TopBarSegment(part: tpMenuButton, col: col,
                                        width: menuW)
      col += menuW
    inc col
  if controlsW > 0:
    for k, i in result.shownControls:
      if result.effectiveIcons == imText and k > 0:
        inc col
      let w = controlCells(result.effectiveIcons, i)
      result.segments.add TopBarSegment(part: tpControl, col: col, width: w,
                                        index: i)
      col += w
    inc col
  if omniW > 0:
    result.segments.add TopBarSegment(part: tpOmnibar, col: col, width: omniW)
    col += omniW + 1
  if tabSegs.len > 0:
    for s in tabSegs.mitems:
      s.col = col
      col += s.width
      result.segments.add s
    inc col
  if headerW > 0:
    let hcol = width - badgeW - 1 - headerW
    result.segments.add TopBarSegment(part: tpHeader, col: max(col, hcol),
                                      width: headerW)
  result.segments.add TopBarSegment(part: tpBadge, col: width - badgeW,
                                    width: badgeW)

proc headerTextOf*(m: TopBarModel; lay: TopBarLayout): string =
  ## The header text a layout's `tpHeader` segment shows.
  for s in lay.segments:
    if s.part == tpHeader:
      for detail in [hdFull, hdNoKind, hdNoArch, hdTickOnly]:
        let candidate = headerFields(m.header, detail).join(" | ")
        if textCells(candidate) <= s.width:
          return candidate
      return fitCells(headerFields(m.header, hdTickOnly).join(" | "), s.width)
  ""

proc segmentOf*(lay: TopBarLayout; part: TopBarPart; index = 0): TopBarSegment =
  for s in lay.segments:
    if s.part == part and (part notin {tpMenuTitle, tpControl, tpTab} or
                           s.index == index):
      return s
  TopBarSegment(part: part, col: -1, width: 0, index: index)

# ---------------------------------------------------------------------------
# Painting the row
# ---------------------------------------------------------------------------

proc paintTopBar*(g: var StyledGrid; m: TopBarModel; lay: TopBarLayout) =
  ## Row 0: every segment on its role's surface. The row's own surface (the
  ## header's card) is filled by the shell first.
  let menuOpenAt =
    if m.menu.isNil or not m.menu.isOpen: -2
    elif m.menu.path.len > 0: m.menu.path[0]
    else: -1
  for s in lay.segments:
    case s.part
    of tpMenuButton:
      let open = not m.menu.isNil and m.menu.isOpen
      # Closed, the button sits on the row's own card, like the desktop's
      # menu bar; open, it takes the active tab's surface.
      if open:
        g.fillSurface(0, s.col, s.width, 1, srTabActive)
      g.paint(0, s.col, fitCells(" " & MenuButtonGlyph & " ", s.width),
              if open: CellStyle(role: srTabActive, bold: true)
              else: CellStyle(role: srChromeText, surface: srSurfaceCard))
    of tpMenuTitle:
      let label = m.menu.root.children[s.index].label
      # The open folder, or the keyboard highlight on the top level, is the
      # active tab's colour and weight; the others the inactive tier.
      let active = menuOpenAt == s.index or
                   (menuOpenAt == -1 and m.menu.highlight == s.index)
      # Inactive titles are label text on the row's card (the desktop's menu
      # bar); the active one takes the active tab's surface and weight.
      if active:
        g.fillSurface(0, s.col, s.width, 1, srTabActive)
      g.paint(0, s.col, fitCells(" " & label & " ", s.width),
              if active: CellStyle(role: srTabActive, bold: true)
              else: CellStyle(role: srChromeText, surface: srSurfaceCard))
    of tpControl:
      let enabled = s.index < m.controlsEnabled.len and
                    m.controlsEnabled[s.index]
      let hovered = m.hoveredControl == s.index
      let role = if hovered: srTabActive
                 elif enabled: srChromeText
                 else: srChromeMuted
      g.fillSurface(0, s.col, s.width, 1, if hovered: srTabActive else: srTabBar)
      let c = TransportControls[s.index]
      let text =
        case lay.effectiveIcons
        of imGraphics: spaces(s.width)   # the picture is drawn over these
        of imText: " " & c.text & " "
        else: " " & c.glyphFor(lay.effectiveIcons) & " "
      g.paint(0, s.col, fitCells(text, s.width),
              CellStyle(role: role, bold: hovered))
    of tpOmnibar:
      let ob = m.omnibar
      if lay.omnibarField:
        if not ob.isNil and ob.isOpen:
          g.fillSurface(0, s.col, s.width, 1, srSurfaceInput)
          # The query, its tail kept in view, and a cursor cell after it.
          var text = OmnibarGlyph & " " & ob.query
          let room = s.width - 1
          while textCells(text) > room and text.runeLen > 2:
            text = OmnibarGlyph & " " & text.runeSubStr(3)
          g.paint(0, s.col, fitCells(text, s.width),
                  CellStyle(role: srChromeText))
          let cur = s.col + min(s.width - 1, textCells(text))
          g.paint(0, cur, " ", CellStyle(role: srChromeText, reverse: true))
        else:
          # CLOSED, the field is its placeholder on the bar's own card, in the
          # chrome text tier. The muted tier fails PLAT-46's contrast floor in
          # Light on both the input surface (2.9:1) and the card (2.2:1), so
          # the placeholder is told from a typed query by the surface (a
          # query sits on the input surface, with a cursor) rather than by a
          # colour a reader cannot see.
          g.fillSurface(0, s.col, s.width, 1, srSurfaceCard)
          g.paint(0, s.col, fitCells(OmnibarGlyph & " " & TopBarPlaceholder,
                                     s.width),
                  CellStyle(role: srChromeText, surface: srSurfaceCard))
      else:
        g.fillSurface(0, s.col, s.width, 1, srTabBar)
        g.paint(0, s.col, fitCells(" " & OmnibarGlyph & " ", s.width),
                CellStyle(role: srChromeText))
    of tpTab:
      let t = m.tabs[s.index]
      let role = if t.active: srTabActive else: srTabInactive
      g.fillSurface(0, s.col, s.width, 1, role)
      g.paint(0, s.col, fitCells(" " & t.title & " ", s.width),
              CellStyle(role: role, bold: t.active))
    of tpTabMore:
      g.fillSurface(0, s.col, 1, 1, srTabBar)
      g.paint(0, s.col, (if s.index < 0: "‹" else: "›"),
              CellStyle(role: srChromeMuted))
    of tpHeader:
      g.paint(0, s.col, fitCells(m.headerTextOf(lay), s.width))
    of tpBadge:
      g.paint(0, s.col, fitCells("[" & $m.header.status & "]", s.width))

# ---------------------------------------------------------------------------
# The menu's dropdowns
# ---------------------------------------------------------------------------

proc dropdownWidth(level: MenuLevelView): int =
  var label = 0
  var chord = 0
  for it in level.items:
    label = max(label, textCells(it.label))
    chord = max(chord, textCells(it.shortcut))
  # " label   chord › "
  1 + label + (if chord > 0: 3 + chord else: 0) + 3

proc menuDropdowns*(m: TopBarModel; lay: TopBarLayout;
                    width, height: int): seq[MenuDropdown] =
  ## The open menu's dropdowns, outermost first, as overlays over the body:
  ##   * with the folder titles on the row, the top level IS the row, and
  ##     each entered folder drops below its title, deeper ones cascading to
  ##     the right at their parent item's row;
  ##   * with the `≡` button, the top level drops below the button.
  ## Clamped to the screen (a dropdown that would run off the right edge is
  ## moved left; off the bottom, it is cut to the rows that fit).
  if m.menu.isNil or not m.menu.isOpen:
    return
  let levels = m.menu.openLevels()
  var startLevel = if lay.menuExpanded: 1 else: 0
  var col = 0
  var row = 1
  if lay.menuExpanded and m.menu.path.len > 0:
    col = lay.segmentOf(tpMenuTitle, m.menu.path[0]).col
  for depth in startLevel ..< levels.len:
    let lv = levels[depth]
    if lv.items.len == 0:
      continue
    let w = min(width, dropdownWidth(lv))
    var rows: seq[DropdownRow] = @[]
    var r = 0
    for k, it in lv.items:
      rows.add DropdownRow(row: r, item: k)
      inc r
      if it.separatorAfter and k < lv.items.high:
        rows.add DropdownRow(row: r, item: -1)
        inc r
    let h = min(rows.len, max(0, height - 1 - row))
    let c = max(0, min(col, width - w))
    var kept: seq[DropdownRow] = @[]
    for dr in rows:
      if dr.row < h:
        kept.add DropdownRow(row: row + dr.row, item: dr.item)
    result.add MenuDropdown(area: CellArea(col: c, row: row, width: w,
                                           height: h),
                            level: lv, rows: kept)
    # The next level opens beside the entered item.
    if depth < m.menu.path.len:
      let entered = m.menu.path[depth]
      for dr in kept:
        if dr.item >= 0 and lv.items[dr.item].index == entered:
          row = dr.row
      col = c + w

proc paintMenuDropdowns*(g: var StyledGrid; dropdowns: seq[MenuDropdown]) =
  ## Each dropdown on the card surface; the item on the open path (and the
  ## highlight) lifted onto the selection surface; a disabled item in the
  ## muted role; the chord right-aligned, muted; `›` on a folder. A
  ## separator is an empty row — spacing, not a drawn rule.
  for d in dropdowns:
    let a = d.area
    g.fillSurface(a.row, a.col, a.width, a.height, srSurfaceCard)
    for dr in d.rows:
      g.paint(dr.row, a.col, spaces(a.width), CellStyle(role: srChromeText,
                                                       surface: srSurfaceCard))
      if dr.item < 0:
        continue
      let it = d.level.items[dr.item]
      let surface = if it.active: srSurfaceSelection else: srSurfaceCard
      let role = if not it.enabled: srChromeMuted
                 elif it.active: srTabActive
                 else: srChromeText
      g.fillSurface(dr.row, a.col, a.width, 1, surface)
      g.paint(dr.row, a.col, fitCells(" " & it.label, a.width),
              CellStyle(role: role, bold: it.active))
      var tail = ""
      if it.shortcut.len > 0: tail.add it.shortcut
      tail.add (if it.folder: " " & FolderMarker & " " else: "   ")
      let tw = textCells(tail)
      if tw < a.width:
        g.paint(dr.row, a.col + a.width - tw, tail,
                CellStyle(role: (if it.folder: role else: srChromeMuted)))

proc menuHitAt*(dropdowns: seq[MenuDropdown];
                row, col: int): tuple[inside: bool, path: seq[int]] =
  ## The dropdown item under a cell: `inside` is true for any cell of any
  ## dropdown (a click on a separator does nothing but is still inside);
  ## `path` names the item.
  for d in dropdowns:
    if d.area.contains(row, col):
      for dr in d.rows:
        if dr.row == row and dr.item >= 0:
          return (true, d.level.folderPath & @[d.level.items[dr.item].index])
      return (true, @[])
  (false, @[])

# ---------------------------------------------------------------------------
# The omnibar's results
# ---------------------------------------------------------------------------

proc omnibarDropdown*(m: TopBarModel; lay: TopBarLayout;
                      width, height: int): tuple[area: CellArea, first: int] =
  ## Where the open omnibar's results are drawn: below its field, as wide as
  ## the field or the widest result (up to half the screen), at most
  ## `OmnibarResultRows` rows, scrolled so the selection shows. `first` is the
  ## first result drawn.
  if m.omnibar.isNil or not m.omnibar.isOpen:
    return (CellArea(), 0)
  let field = lay.segmentOf(tpOmnibar)
  if field.col < 0:
    return (CellArea(), 0)
  var w = field.width
  for r in m.omnibar.results:
    w = max(w, textCells(r.entry.label) + textCells(r.entry.detail) + 4)
  w = min(w, max(field.width, width div 2))
  let rows = max(1, min(OmnibarResultRows, m.omnibar.results.len))
  let h = min(rows, max(0, height - 2))
  let col = max(0, min(field.col, width - w))
  var first = 0
  if m.omnibar.selected >= h:
    first = m.omnibar.selected - h + 1
  (CellArea(col: col, row: 1, width: w, height: h), first)

proc paintOmnibarDropdown*(g: var StyledGrid; m: TopBarModel;
                           lay: TopBarLayout; width, height: int) =
  let (a, first) = m.omnibarDropdown(lay, width, height)
  if a.width <= 0 or a.height <= 0:
    return
  g.fillSurface(a.row, a.col, a.width, a.height, srSurfaceCard)
  if m.omnibar.results.len == 0:
    let what =
      case m.omnibar.mode
      of omProgram: "program search runs in the search pane"
      of omAgent: "the agent is not available in the terminal"
      else: "no match"
    g.paint(a.row, a.col, fitCells(" " & what, a.width),
            CellStyle(role: srChromeMuted, surface: srSurfaceCard))
    return
  for k in 0 ..< a.height:
    let i = first + k
    if i >= m.omnibar.results.len:
      break
    let r = m.omnibar.results[i]
    let selected = i == m.omnibar.selected
    let surface = if selected: srSurfaceSelection else: srSurfaceCard
    g.fillSurface(a.row + k, a.col, a.width, 1, surface)
    g.paint(a.row + k, a.col, fitCells(" " & r.entry.label, a.width),
            CellStyle(role: (if selected: srTabActive else: srChromeText),
                      bold: selected))
    if r.entry.detail.len > 0:
      let dw = textCells(r.entry.detail) + 1
      if dw + textCells(r.entry.label) + 2 <= a.width:
        g.paint(a.row + k, a.col + a.width - dw, r.entry.detail & " ",
                CellStyle(role: srChromeMuted))

proc omnibarHitAt*(m: TopBarModel; lay: TopBarLayout; width, height,
                   row, col: int): tuple[inside: bool, index: int] =
  let (a, first) = m.omnibarDropdown(lay, width, height)
  if a.width <= 0 or not a.contains(row, col):
    return (false, -1)
  let i = first + (row - a.row)
  (true, (if i < m.omnibar.results.len: i else: -1))

# ---------------------------------------------------------------------------
# Hit-testing the row
# ---------------------------------------------------------------------------

proc topBarHitAt*(lay: TopBarLayout; col: int): TopBarHit =
  for s in lay.segments:
    if col >= s.col and col < s.col + s.width:
      case s.part
      of tpMenuButton: return TopBarHit(kind: thMenuButton)
      of tpMenuTitle: return TopBarHit(kind: thMenuTitle, index: s.index)
      of tpControl: return TopBarHit(kind: thControl, index: s.index)
      of tpOmnibar: return TopBarHit(kind: thOmnibar)
      of tpTab: return TopBarHit(kind: thTab, index: s.index)
      of tpTabMore: return TopBarHit(kind: thTabMore, index: s.index)
      else: return TopBarHit(kind: thNone)
  TopBarHit(kind: thNone)

proc rowText*(m: TopBarModel; width: int): string =
  ## The row as text, for a test that asserts what the terminal shows.
  var g = newStyledGrid(width, 1)
  paintTopBar(g, m, topBarLayout(m, width))
  g.rowText(0)
