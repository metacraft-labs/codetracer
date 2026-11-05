## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule. This module paints a VALUE; it
## reads no ViewModel (`host/tui_session.shellModelOf` turns the session's
## shared `ShellVM` into the model below) and runs no process (the session is
## the host's, `viewmodel/host/native_shell_host.nim`).
##
## app/views/shell_session_pane.nim — PLAT-61. **THE SHELL PANE, drawn.**
##
## Spec: `codetracer-pm` `spec/Planned-Features/CodeTracer-Shell.md` §7.5.
##
## The interactive CodeTracer shell: a real shell on a pty, its output
## emulated by the shared model, every line a command reported on marked in a
## two-cell gutter — the action's glyph on its first line, a bar on the rest,
## in its status's colour:
##
##     SHELL  running — 1 recording · opened recording 0191abcd
##       $ ./build.sh
##     ● compiled calc.py
##     │ 42
##       $ █
##
## A press on a recorded command's gutter opens its recording; the right
## column is the scrollback's scrollbar. The rows, the glyphs' meaning and
## every word are the model's (`shell_vm`), which the desktop's view and GPUI's
## leaf draw too.

import std/strutils

import codetracer_embed

import ../layout/cells
import ../layout/project
import ./header
import ./styled_row
import ./scrubber_track
import ./terminal_output_pane   # `literalStyle`: a run's SGR as a cell style

export styled_row, scrubber_track

type
  ShellPaneRow* = object
    line*: int
      ## The absolute output line (`ShellRow.line`).
    mark*: ShellRowMark
    tone*: ShellTone
    action*: int
      ## Index of the action in the model, -1 for none.
    runs*: seq[ScreenRun]
    cursorCol*: int
    text*: string

  ShellPaneModel* = object
    ## The Shell pane as a value.
    loaded*: bool
    state*: ShellSessionState
    words*: string
      ## `statusWords`.
    note*: string
      ## What the pane last said (`ShellVM.note`).
    rows*: seq[ShellPaneRow]
      ## The lines the view shows now (`shellRows`).
    lineCount*, top*: int
      ## Every kept line, and the first one shown (for the scrollbar).
    cols*, height*: int
      ## The terminal size the session runs at.
    summaries*: seq[string]
      ## Per action: its words (`actionSummary`), what the status line says
      ## for a press or a hover.

  ShellPaneGeometry* = object
    headerRow*: int
    contentTop*, contentRows*: int
    gutterCol*: int
    textCol*, textWidth*: int
    trackCol*: int
      ## The scrollbar's column, -1 when the pane is too narrow.

  ShellHitKind* = enum
    shNone
    shGutter       ## an action's gutter cell: `action`
    shText         ## the output: `line`
    shTrack        ## the scrollbar
    shHeader

  ShellHit* = object
    kind*: ShellHitKind
    line*: int
    action*: int

  ShellActKind* = enum
    ## What the runtime asks of the host's ShellVM.
    shaKey         ## a key the focused pane takes: `chord` (or `text`)
    shaText        ## text typed or pasted that has no key name: `text`
    shaPress       ## a press on an action's gutter: `action`
    shaScroll      ## the wheel / the bar: `delta` lines
    shaScrollTo    ## the bar's thumb: `top`
    shaFit         ## the pane's text area: `cols` x `rows` (starts the shell)

  ShellAct* = object
    kind*: ShellActKind
    chord*, text*: string
    action*, delta*, top*, cols*, rows*: int

  ShellActResult* = object
    toApp*: bool
      ## The key is CodeTracer's (the prefix was armed): the runtime runs it.
    note*: string

const
  ShellPaneTitle* = "SHELL"
  ShellGutterCells* = 2
  HeaderStyle = CellStyle(role: srChromeMuted)
  TitleStyle = CellStyle(role: srChromeTitle, bold: true)

func toneStyle*(t: ShellTone): CellStyle =
  ## The gutter's colour for a status (§7.5): busy, success, error.
  case t
  of stWorking: CellStyle(role: srChromeNotification)
  of stOk: CellStyle(role: srChromeSuccess)
  of stError: CellStyle(role: srChromeError)

func gutterRole*(r: ShellPaneRow): GlyphRole =
  if r.mark == srmRange: grShellRange
  else:
    case r.tone
    of stWorking: grShellWorking
    of stOk: grShellOk
    of stError: grShellError

proc shellPaneGeometry*(area: CellArea): ShellPaneGeometry =
  ## The parts of the pane painted into `area` — its first row under the tab
  ## strip is the header, the rest the output with its gutter and bar.
  result = ShellPaneGeometry(headerRow: area.row, trackCol: -1)
  result.contentTop = area.row + 1
  result.contentRows = max(0, area.height - 1)
  result.gutterCol = area.col
  result.textCol = area.col + ShellGutterCells
  result.textWidth = max(0, area.width - ShellGutterCells)
  if area.width >= ShellGutterCells + 2:
    result.trackCol = area.col + area.width - 1
    result.textWidth -= 1

proc shellPaneSize*(area: CellArea): tuple[cols, rows: int] =
  ## The terminal size the shell runs at in this pane: its text columns and
  ## its output rows.
  let geo = shellPaneGeometry(area)
  (max(1, geo.textWidth), max(1, geo.contentRows))

proc paintShellPane*(g: var StyledGrid; area: CellArea;
                     m: ShellPaneModel): seq[string] =
  ## Paint the pane into `area` and answer the output rows as painted, the
  ## gutter's glyph first (`isonim_shell_view.shellRowsText`'s shape), for a
  ## test to read.
  if area.width <= 0 or area.height <= 0:
    return
  let geo = shellPaneGeometry(area)
  let sep = g.glyphText(grSeparator)
  g.paint(geo.headerRow, area.col, fitCells(ShellPaneTitle, area.width),
          TitleStyle)
  let words = "  " & m.words & (if m.note.len > 0: " " & sep & " " & m.note
                                else: "")
  let room = area.width - ShellPaneTitle.len
  if room > 0:
    g.paint(geo.headerRow, area.col + ShellPaneTitle.len,
            fitCells(words, room), HeaderStyle)
  for i, row in m.rows:
    if i >= geo.contentRows: break
    let r = geo.contentTop + i
    var gutter = " "
    if row.mark != srmNone:
      g.paintGlyph(r, geo.gutterCol, row.gutterRole, toneStyle(row.tone))
      gutter = g.glyphText(row.gutterRole)
    for run in row.runs:
      if run.col >= geo.textWidth: break
      let blank = run.attrs == TermAttrs() and run.text.strip.len == 0
      if not blank:
        g.paint(r, geo.textCol + run.col,
                truncateToCells(run.text, geo.textWidth - run.col),
                literalStyle(run.attrs))
    if row.cursorCol >= 0 and row.cursorCol < geo.textWidth:
      var under = " "
      for run in row.runs:
        if row.cursorCol >= run.col and row.cursorCol < run.col + run.cells:
          under = cellSlice(run.text, row.cursorCol - run.col,
                            row.cursorCol - run.col + 1)
          if under.len == 0: under = " "
      var cursor = DefaultCellStyle
      cursor.reverse = true
      g.paint(r, geo.textCol + row.cursorCol, under, cursor)
    result.add gutter & " " & row.text
  if geo.trackCol >= 0 and geo.contentRows > 0:
    g.paintVerticalScrubber(geo.trackCol, geo.contentTop, geo.contentRows,
      scrubberModel(m.lineCount, m.top, geo.contentRows))

proc shellHitAt*(m: ShellPaneModel; area: CellArea; row, col: int): ShellHit =
  ## What a press at `(row, col)` lands on.
  let geo = shellPaneGeometry(area)
  if row == geo.headerRow:
    return ShellHit(kind: shHeader, action: -1)
  if row < geo.contentTop or row >= geo.contentTop + geo.contentRows or
     col < area.col or col >= area.col + area.width:
    return ShellHit(kind: shNone, action: -1)
  if col == geo.trackCol:
    return ShellHit(kind: shTrack, action: -1)
  let i = row - geo.contentTop
  if i >= m.rows.len:
    return ShellHit(kind: shText, line: -1, action: -1)
  let r = m.rows[i]
  if col < geo.textCol and r.mark != srmNone:
    return ShellHit(kind: shGutter, line: r.line, action: r.action)
  ShellHit(kind: shText, line: r.line, action: -1)
