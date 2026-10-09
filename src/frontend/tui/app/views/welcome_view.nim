## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/views/welcome_view.nim — PLAT-51 deliverable 8: THE WELCOME SCREEN OF
## A NEW TAB, in cells.
##
## Multi-Window-Tab-Management.md rule 3: the strip's "+" opens a tab showing
## the Welcome Screen (Welcome-Screen.md) — the heading, the two recent
## panels side by side (Recent folders | Recent traces, each with its empty
## sentence), the strip of the six start options in their order, and under
## it the one-line form a chosen option opens (or what the screen has to
## say). Drawn from `viewmodels/native_welcome`'s rows — the model GPUI draws
## too — over the whole body, in place of the panes. `welcomeLayout` is the
## one placement both the paint and the hit-test read.

import std/strutils

import codetracer_embed   # `native_welcome` (PLAT-51)

import ../layout/cells
import ../layout/profile
import ./header
import ./styled_row

export native_welcome

type
  WelcomeView* = object
    ## What the shell draws when a welcome tab is shown.
    shown*: bool
    rows*: seq[NativeWelcomeRow]
    focus*: int
    form*: NativeWelcomeForm
    input*: string
    placeholder*: string
    message*: string

  WelcomeLayout* = object
    heading*: CellArea
    foldersPanel*: CellArea
    tracesPanel*: CellArea
    rowAreas*: seq[CellArea]
      ## Per row of `WelcomeView.rows`, where it is drawn (an empty area for
      ## an entry past its panel's height).
    line*: CellArea
      ## The form's field, or the message.

const
  WelcomeButtonGap* = 2
    ## Cells between two start options.
  WelcomeHeadingStyle = CellStyle(role: srChromeTitleFocused, bold: true)
  WelcomePanelTitleStyle = CellStyle(role: srChromeTitle)
  WelcomeEmptyStyle = CellStyle(role: srChromeMuted, italic: true)
  WelcomeEntryStyle = CellStyle(role: srChromeText)
  WelcomeDetailStyle = CellStyle(role: srChromeMuted)
  WelcomeOptionStyle = CellStyle(role: srTabActive, surface: srTabActive)
  WelcomeRefusedStyle = CellStyle(role: srTabInactive, surface: srTabBar)
  WelcomeFocusStyle = CellStyle(role: srChromeText, surface: srSurfaceSelection,
                                bold: true)
  WelcomePromptStyle = CellStyle(role: srChromePrompt)
  WelcomeInputStyle = CellStyle(role: srChromeText, surface: srSurfaceInput)
  WelcomeMessageStyle = CellStyle(role: srChromeNotification)

proc optionLabel(r: NativeWelcomeRow): string = " " & r.label & " "

proc welcomeLayout*(v: WelcomeView; body: CellArea): WelcomeLayout =
  ## Where everything goes in `body`.
  if body.width <= 0 or body.height <= 0:
    return
  var row = body.row + 1
  result.heading = CellArea(col: body.col, row: row, width: body.width,
                            height: 1)
  row += 2
  var folders, traces, options: seq[int] = @[]
  for i, r in v.rows:
    case r.kind
    of nwrRecentFolder: folders.add i
    of nwrRecentTrace: traces.add i
    of nwrOption: options.add i
  result.rowAreas = newSeq[CellArea](v.rows.len)
  # THE TWO PANELS, side by side, as tall as the longer list (at least one
  # line for the empty sentence), capped so the strip below stays on screen.
  let gap = 2
  let margin = 2
  let panelW = max(10, (body.width - 2 * margin - gap) div 2)
  let reserve = 6
  let maxEntries = max(1, body.height - (row - body.row) - reserve)
  let entries = min(maxEntries, max(1, max(folders.len, traces.len)))
  result.foldersPanel = CellArea(col: body.col + margin, row: row,
                                 width: panelW, height: entries + 1)
  result.tracesPanel = CellArea(col: body.col + margin + panelW + gap,
                                row: row, width: panelW, height: entries + 1)
  for k, i in folders:
    if k < entries:
      result.rowAreas[i] = CellArea(col: result.foldersPanel.col,
                                    row: row + 1 + k, width: panelW, height: 1)
  for k, i in traces:
    if k < entries:
      result.rowAreas[i] = CellArea(col: result.tracesPanel.col,
                                    row: row + 1 + k, width: panelW, height: 1)
  row += entries + 2
  # THE START OPTIONS, one flex row (Welcome-Screen.md: `.start-options` is a
  # single row); wrapped only when the body is narrower than the six.
  var col = body.col + margin
  for i in options:
    let w = textCells(optionLabel(v.rows[i]))
    if col + w > body.col + body.width - margin and col > body.col + margin:
      col = body.col + margin
      row += 2
    result.rowAreas[i] = CellArea(col: col, row: row, width: w, height: 1)
    col += w + WelcomeButtonGap
  row += 2
  result.line = CellArea(col: body.col + margin, row: row,
                         width: max(0, body.width - 2 * margin), height: 1)

proc welcomeRowAt*(lay: WelcomeLayout; row, col: int): int =
  ## The row of the screen under a cell, or -1.
  for i, a in lay.rowAreas:
    if a.width > 0 and row >= a.row and row < a.row + a.height and
       col >= a.col and col < a.col + a.width:
      return i
  -1

proc paintWelcome*(g: var StyledGrid; v: WelcomeView;
                   body: CellArea): WelcomeLayout =
  ## The screen, over the whole body.
  result = welcomeLayout(v, body)
  g.fillSurface(body.row, body.col, body.width, body.height, srSurfacePanel)
  for r in body.row ..< body.row + body.height:
    g.paint(r, body.col, spaces(body.width), CellStyle(role: srChromeText))
  let h = result.heading
  if h.width > 0:
    let t = NativeWelcomeHeading
    g.paint(h.row, h.col + max(0, (h.width - textCells(t)) div 2), t,
            WelcomeHeadingStyle)
  var anyFolder, anyTrace = false
  for r in v.rows:
    if r.kind == nwrRecentFolder: anyFolder = true
    if r.kind == nwrRecentTrace: anyTrace = true
  for (panel, title, any, empty) in [
      (result.foldersPanel, RecentFoldersHeading, anyFolder, RecentFoldersEmpty),
      (result.tracesPanel, RecentTracesHeading, anyTrace, RecentTracesEmpty)]:
    if panel.width <= 0:
      continue
    g.fillSurface(panel.row, panel.col, panel.width, panel.height,
                  srSurfaceCard)
    g.paint(panel.row, panel.col, fitCells(" " & title, panel.width),
            WelcomePanelTitleStyle)
    if not any and panel.height > 1:
      g.paint(panel.row + 1, panel.col, fitCells(" " & empty, panel.width),
              WelcomeEmptyStyle)
  for i, r in v.rows:
    let a = result.rowAreas[i]
    if a.width <= 0:
      continue
    let focused = i == v.focus and v.form == nwfNone
    case r.kind
    of nwrRecentFolder, nwrRecentTrace:
      let name = " " & r.label & "  "
      g.paint(a.row, a.col, fitCells(name, a.width),
              if focused: WelcomeFocusStyle else: WelcomeEntryStyle)
      let used = textCells(name)
      if used < a.width:
        g.paint(a.row, a.col + used, fitCells(r.detail, a.width - used),
                if focused: WelcomeFocusStyle else: WelcomeDetailStyle)
    of nwrOption:
      g.paint(a.row, a.col, optionLabel(r),
              if focused: WelcomeFocusStyle
              elif r.enabled: WelcomeOptionStyle
              else: WelcomeRefusedStyle)
  let line = result.line
  if line.width > 0:
    if v.form != nwfNone:
      let prompt = formPrompt(v.form)
      g.paint(line.row, line.col, prompt, WelcomePromptStyle)
      let fieldCol = line.col + textCells(prompt)
      let fieldW = max(1, line.col + line.width - fieldCol)
      if v.input.len == 0 and v.placeholder.len > 0:
        g.paint(line.row, fieldCol, fitCells(v.placeholder, fieldW),
                CellStyle(role: srChromeMuted, surface: srSurfaceInput,
                          italic: true))
      else:
        g.paint(line.row, fieldCol, fitCells(v.input, fieldW),
                WelcomeInputStyle)
      if line.row + 1 < body.row + body.height and v.message.len > 0:
        g.paint(line.row + 1, line.col, fitCells(v.message, line.width),
                WelcomeMessageStyle)
    elif v.message.len > 0:
      g.paint(line.row, line.col, fitCells(v.message, line.width),
              WelcomeMessageStyle)
    elif v.focus >= 0 and v.focus < v.rows.len and
         v.rows[v.focus].kind == nwrOption and not v.rows[v.focus].enabled:
      # The desktop's tooltip on a refused option, as a standing line.
      g.paint(line.row, line.col, fitCells(v.rows[v.focus].detail,
                                           line.width), WelcomeDetailStyle)

proc welcomeCursor*(v: WelcomeView; lay: WelcomeLayout): tuple[on: bool;
                                                            row, col: int] =
  ## Where the terminal's cursor goes: the form field's caret.
  if v.form == nwfNone or lay.line.width <= 0:
    return (false, 0, 0)
  let col = lay.line.col + textCells(formPrompt(v.form)) + textCells(v.input)
  (true, lay.line.row, min(col, lay.line.col + lay.line.width - 1))
