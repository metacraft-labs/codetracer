## app/views/context_menu.nim — PLAT-50: the terminal's spelling of the
## desktop's right-click menus and of its "show the event's content" view.
##
## The MENU is `headless_app/pane_clicks.ContextMenuState` — its entries,
## which one the keyboard is on, what choosing one means — and nothing here
## decides any of that. This module only places it (at the cell that was
## right-clicked, kept on the screen), paints it on the desktop's dropdown
## surface inside the desktop's dropdown border (`top_bar.paintDropdownFrame`,
## the same frame the program menu has), and hit-tests a cell against what it
## painted.
##
## The CONTENT OVERLAY is what a right-click on an event-log row opens: the
## desktop opens the event's full content in a read-only editor view
## (`ui/event_log.handlerRightClick`); a terminal shows it in a framed box over
## the body, wrapped, until Esc or a click.

import std/[base64, strutils, unicode]

import headless_app/pane_clicks

import ../layout/cells
import ../layout/project
import ./styled_row
import ./header
import ./top_bar

export pane_clicks

const
  TerminalMenuHint* = "Terminal menu: Shift + right-click"
    ## PLAT-51: the INERT last row of every context menu the terminal draws
    ## (Native-Front-End-Parity.md §1) — not an entry of the model, not
    ## selectable, not hit by a press: the terminal's own menu is Shift +
    ## right-click, which the TUI leaves to the terminal.
  ContextMenuMaxWidth* = 60
  ContentOverlayMaxWidth* = 100
  ContentOverlayMaxHeight* = 24

proc contextMenuArea*(s: ContextMenuState; width, height: int): CellArea =
  ## The framed box the open menu occupies: its top-left at the cell below
  ## and right of the press (the desktop's menu opens at the pointer), moved
  ## left / up so it stays on the screen, never over row 0 (the top bar).
  if not s.open or s.menu.entries.len == 0 or width <= 2 or height <= 3:
    return CellArea()
  var label = 0
  var hint = 0
  for e in s.menu.entries:
    label = max(label, textCells(e.label))
    hint = max(hint, textCells(e.hint))
  let inner = max(1 + label + (if hint > 0: 3 + hint else: 0) + 1,
                  1 + textCells(TerminalMenuHint) + 1)
  let w = min(min(width, ContextMenuMaxWidth),
              inner + 2 * DropdownFrameCells)
  # The entries, then the inert hint row.
  let h = min(height - 1, s.menu.entries.len + 1 + 2 * DropdownFrameCells)
  let col = max(0, min(s.anchorCol, width - w))
  let row = max(1, min(s.anchorRow + 1, height - h))
  CellArea(col: col, row: row, width: w, height: h)

proc paintContextMenu*(g: var StyledGrid; s: ContextMenuState;
                       area: CellArea) =
  ## The open menu: framed on the dropdown surface; the selected entry on the
  ## selection surface; a disabled entry muted; the hint right-aligned.
  if area.width <= 0 or area.height <= 0:
    return
  paintDropdownFrame(g, area)
  const f = DropdownFrameCells
  let ic = area.col + f
  let iw = max(0, area.width - 2 * f)
  for i, e in s.menu.entries:
    let row = area.row + f + i
    if row >= area.row + area.height - f:
      break
    let selected = i == s.selected
    let surface = if selected and e.enabled: srSurfaceSelection
                  else: srSurfaceMenu
    let role = if not e.enabled: srChromeMuted
               elif selected: srTabActive
               else: srChromeText
    g.fillSurface(row, ic, iw, 1, surface)
    g.paint(row, ic, fitCells(" " & e.label, iw),
            CellStyle(role: role, bold: selected and e.enabled,
                      italic: not e.enabled, surface: surface))
    if e.hint.len > 0:
      let hw = textCells(e.hint) + 1
      if hw + textCells(e.label) + 3 <= iw:
        g.paint(row, ic + iw - hw, e.hint & " ",
                CellStyle(role: srChromeMuted, surface: surface))
  # PLAT-51: the inert hint row, last, muted and never selected.
  let hintRow = area.row + f + s.menu.entries.len
  if hintRow < area.row + area.height - f:
    g.fillSurface(hintRow, ic, iw, 1, srSurfaceMenu)
    g.paint(hintRow, ic, fitCells(" " & TerminalMenuHint, iw),
            CellStyle(role: srChromeMuted, italic: true,
                      surface: srSurfaceMenu))

proc contextMenuHitAt*(s: ContextMenuState; area: CellArea;
                       row, col: int): tuple[inside: bool, index: int] =
  ## `inside` for any cell of the framed box (the frame included); `index`
  ## the entry on that row, -1 on the frame and on the inert hint row.
  if area.width <= 0 or not area.contains(row, col):
    return (false, -1)
  let i = row - area.row - DropdownFrameCells
  if i < 0 or i >= s.menu.entries.len or
     row >= area.row + area.height - DropdownFrameCells or
     col < area.col + DropdownFrameCells or
     col >= area.col + area.width - DropdownFrameCells:
    return (true, -1)
  (true, i)

# ---------------------------------------------------------------------------
# The content overlay
# ---------------------------------------------------------------------------

type
  ContentOverlay* = object
    ## A text shown over the body: an event's full content, a value's
    ## history, a changed file's diff.
    open*: bool
    title*: string
    text*: string
    diff*: bool
      ## PLAT-50 (K34): the text is a unified diff — its added, removed and
      ## hunk-header lines in the diff colours.
    top*: int
      ## The first line shown, for a text longer than the box (the wheel and
      ## Up / Down / Page Up / Page Down scroll it).

proc wrapLines(text: string; width: int): seq[string] =
  ## `text` (its `\n` escapes as line breaks, as the desktop's view shows
  ## them) cut into lines of at most `width` cells.
  for raw in text.replace("\\n", "\n").splitLines():
    var line = ""
    var used = 0
    for r in raw.runes:
      let w = max(1, textCells($r))
      if used + w > width:
        result.add line
        line = ""
        used = 0
      line.add $r
      used += w
    result.add line

proc contentOverlayArea*(o: ContentOverlay; body: CellArea): CellArea =
  ## Centred in the body, as wide as the text needs up to
  ## `ContentOverlayMaxWidth`, framed.
  if not o.open or body.width < 8 or body.height < 4:
    return CellArea()
  var widest = textCells(o.title) + 2
  for l in o.text.replace("\\n", "\n").splitLines():
    widest = max(widest, textCells(l))
  let w = min(body.width, min(ContentOverlayMaxWidth, widest + 4))
  let lines = wrapLines(o.text, max(1, w - 4))
  let h = min(body.height, min(max(ContentOverlayMaxHeight,
                                   body.height * 3 div 4), lines.len + 4))
  CellArea(col: body.col + (body.width - w) div 2,
           row: body.row + (body.height - h) div 2, width: w, height: h)

proc scroll*(o: var ContentOverlay; delta: int) =
  ## Move the first line shown by `delta`, kept inside the text.
  let n = o.text.replace("\\n", "\n").countLines()
  o.top = max(0, min(o.top + delta, n - 1))

func diffLineRole(line: string): SemanticRole =
  ## A unified diff line's colour: added and removed as the desktop's diff
  ## view colours them (success / error), a hunk header muted.
  if line.startsWith("+++") or line.startsWith("---"): srChromeTitle
  elif line.startsWith("+"): srChromeSuccess
  elif line.startsWith("-"): srChromeError
  elif line.startsWith("@@"): srChromeMuted
  else: srChromeText

proc paintContentOverlay*(g: var StyledGrid; o: ContentOverlay;
                          area: CellArea) =
  ## The framed box: the title on its first inner row, a blank row, then the
  ## content wrapped to the box from line `top`.
  if area.width <= 0 or area.height <= 0:
    return
  paintDropdownFrame(g, area)
  let iw = max(0, area.width - 4)
  g.paint(area.row + 1, area.col + 2, fitCells(o.title, iw),
          CellStyle(role: srChromeTitle, surface: srSurfaceMenu))
  var row = area.row + 3
  let lines = wrapLines(o.text, max(1, iw))
  for i in min(o.top, max(0, lines.high)) ..< lines.len:
    if row >= area.row + area.height - 1:
      break
    let l = lines[i]
    g.paint(row, area.col + 2, fitCells(l, iw),
            CellStyle(role: (if o.diff: diffLineRole(l) else: srChromeText),
                      surface: srSurfaceMenu))
    inc row

# ---------------------------------------------------------------------------
# The clipboard
# ---------------------------------------------------------------------------

func osc52Copy*(text: string): string =
  ## PLAT-50: the bytes that put `text` on the terminal's clipboard — OSC 52
  ## with the clipboard selection (`c`) and the text in base64, ended by BEL
  ## (xterm's "Manipulate Selection Data"; tmux, kitty, WezTerm, iTerm2 and
  ## Windows Terminal forward it).
  "\e]52;c;" & base64.encode(text) & "\a"
