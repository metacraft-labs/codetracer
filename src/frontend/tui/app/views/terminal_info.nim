## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule.
##
## app/views/terminal_info.nim — PLAT-71 (CodeTracer-TUI-Terminal-
## Adaptation.md §10.1, §10.3): `:terminal-info`, the palette's **Terminal:
## Show Capabilities** — the live report and the glyph test card over the
## panes, re-run on demand (`r`).
##
## It is the one form of the report that can test the INTERACTIVE features:
## the pointer's cell as it moves, the decoded chord of any key pressed, and
## an OSC 52 copy (`c`) the user pastes back. The card's question — "do the
## Legacy Computing glyphs look right?" — is answered with `y` or `n`, which
## sets `modern-unicode` for THIS terminal (a `[terminal "<name>"]` section,
## OQ-T6): the recommended way to turn the option on.

import ../theme/capabilities
import ../layout/cells
import ./styled_row

type
  TerminalInfoView* = object
    open*: bool
    scroll*: int
      ## The first report row shown.
    lastKey*: string
      ## The chord the last key pressed decoded to ("" none yet).
    pointer*: string
      ## Where the pointer last was: `cell 12,4` (and pixels when known).
    note*: string
      ## The last answer: a re-run, a `y` / `n`, a copy.

const
  TerminalInfoTitle* = "TERMINAL CAPABILITIES"
  TerminalInfoKeys* = "r ask again, y / n Legacy Computing glyphs look " &
                      "right, c copy a test string, Up / Down scroll, " &
                      "Esc close"
  TerminalInfoCopyText* = "CodeTracer OSC 52 test"
    ## What `c` copies: paste it back to see the terminal accepted the write.
  TitleStyle = CellStyle(role: srChromeTitle, bold: true)
  KeysStyle = CellStyle(role: srChromeMuted)
  NoteStyle = CellStyle(role: srChromeAccent)

proc terminalInfoArea*(width, height: int): CellArea =
  ## The whole body: below the top bar, above the status line.
  CellArea(col: 0, row: 1, width: width, height: max(0, height - 2))

proc paintTerminalInfo*(g: var StyledGrid; area: CellArea;
                        v: TerminalInfoView; body: seq[StyledRow]) =
  ## The view over `area`: the title, the keys, the live lines, then `body`
  ## (the report and the card) from `v.scroll`.
  if area.width <= 0 or area.height <= 0:
    return
  g.fillSurface(area.row, area.col, area.width, area.height, srSurfacePanel)
  for r in area.row ..< area.row + area.height:
    g.paint(r, area.col, repeatGlyph(" ", area.width))
  var row = area.row
  g.paint(row, area.col, truncateToCells(TerminalInfoTitle & " " &
          repeatGlyph(g.glyphText(grDividerH),
                      max(0, area.width - TerminalInfoTitle.len - 1)),
          area.width), TitleStyle)
  inc row
  if row < area.row + area.height:
    g.paint(row, area.col, truncateToCells(
      (if g.glyphs.tier == tierAscii: asciiProse(TerminalInfoKeys)
       else: TerminalInfoKeys), area.width), KeysStyle)
    inc row
  let live = "key: " & (if v.lastKey.len > 0: v.lastKey else: "(press one)") &
             "   pointer: " & (if v.pointer.len > 0: v.pointer
                               else: "(move it here)") &
             (if v.note.len > 0: "   " & v.note else: "")
  if row < area.row + area.height:
    g.paint(row, area.col, truncateToCells(live, area.width), NoteStyle)
    inc row
  var i = max(0, v.scroll)
  while row < area.row + area.height and i < body.len:
    var at = area.col
    for span in body[i]:
      let room = area.col + area.width - at
      if room <= 0:
        break
      let text = truncateToCells(span.text, room, g.ambiguous)
      g.paint(row, at, text, span.style)
      at += cellWidthOf(text, g.ambiguous)
    inc row
    inc i

const
  TerminalInfoCommandTarget* = "terminalInfo:show"
  TerminalInfoLabel* = "Terminal: Show Capabilities"
