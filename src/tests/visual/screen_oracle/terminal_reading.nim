## PLAT-40 — the terminal's screen, read into PLAT-39's domain types.
##
## **THE SAME GRAMMAR AS THE PIXEL READER, OVER A TEXT FRAME.** A terminal's
## screen IS text: `terminal_driver.plainFrame` composites the panes into the
## rows a terminal shows, and `--headless` prints exactly those rows. So the
## terminal needs no OCR — what it needs is the same REGION step the pixel
## reader has (find a pane by its title, take its rectangle) and the same row
## rules (`pane_grammar`). Nothing here imports a ViewModel, a store or the
## terminal's own view modules: a reading is taken off the frame's characters,
## as a user reads the screen.
##
## A pane's region (PLAT-49: a pane has no title row; its TAB STRIP names it):
## its STRIP ROW is the row where the pane's tab label stands padded by a
## space either side (` Breakpoints `); its columns run from the cell after
## the nearest `|` separator to the label's left (or the frame's edge) to the
## next separator on that row (or the frame's edge); its body is every row
## below the strip until a row whose slice is a horizontal divider (`───`,
## `---`, junctions), or the frame ends.

import std/[sequtils, strutils]
from std/unicode import Rune, toRunes, runeLen, `$`
import ./screen_reading
import ./domain_models
import ./pane_grammar

type
  TerminalPane* = object
    title*: string
    row*, col*, width*: int
      ## In CELLS — runes — never bytes: a frame's rows carry box-drawing
      ## glyphs (`│`, `─`) and marks (`●`) that are one cell and three bytes,
      ## so a byte column drifts from row to row.
    body*: seq[string]

const
  PaneSeparators = ["|", "│", "▏"]
    ## The glyph between two side-by-side panes: ASCII under
    ## `--ascii-borders`, the box-drawing one before PLAT-50, the edge
    ## one-eighth block (`shell.DividerGlyph`) since.
  DividerCells = ["─", "-", "┼", "┬", "┴", "├", "┤", "└", "┘", "┌", "┐", "+"]
    ## What a horizontal divider row between two stacked panes is made of,
    ## in both spellings (box-drawing, and `--ascii-borders`).

func cells(line: string): seq[Rune] = line.toRunes

func sliceCells(r: seq[Rune]; start, width: int): string =
  if start >= r.len: return ""
  $r[start ..< min(r.len, start + width)]

func isDividerSlice(s: string): bool =
  ## A horizontal divider: a non-empty run of divider cells and nothing else.
  let r = s.strip().toRunes
  if r.len == 0: return false
  for c in r:
    if $c notin DividerCells: return false
  true

func separatorAt(r: seq[Rune]; start: int): int =
  ## The first pane separator at or after cell `start`, or `r.len`.
  for i in start ..< r.len:
    if $r[i] in PaneSeparators: return i
  r.len

proc locateTerminalPane*(frame: openArray[string]; title: string): TerminalPane =
  ## The first pane whose tab strip carries `title` as a tab label. A pane
  ## that is not on the screen answers `row == -1`.
  result = TerminalPane(title: title, row: -1)
  let label = " " & title
  for r, line in frame:
    let rs = cells(line)
    let text = $rs
    var at = text.find(label)
    # Padded on the right as well — or at the end of a row whose trailing
    # blanks were trimmed — so `Event Log` is not found inside a longer label.
    while at >= 0 and at + label.len < text.len and
          text[at + label.len] != ' ':
      at = text.find(label, at + 1)
    if at < 0: continue
    let col = text[0 ..< at].runeLen
    var left = col
    while left > 0 and $rs[left - 1] notin PaneSeparators:
      dec left
    # The pane's right edge: the next separator on the strip row — or, when
    # the pane is the rightmost, the frame's edge (the widest row: a row's
    # trailing blanks may have been trimmed).
    var stop = separatorAt(rs, col + 1)
    if stop == rs.len:
      for other in frame:
        stop = max(stop, cells(other).len)
    result.row = r
    result.col = left
    result.width = stop - left
    break
  if result.row < 0: return
  for r in result.row + 1 .. frame.high:
    let slice = sliceCells(cells(frame[r]), result.col, result.width)
    if isDividerSlice(slice): break
    result.body.add slice.strip(leading = false)

proc readTerminalEventLog*(frame: openArray[string]; title = "Event Log"):
    ScreenReading[EventLogModel] =
  let pane = locateTerminalPane(frame, title)
  if pane.row < 0:
    return unreadable[EventLogModel](urRegionNotLocated,
      "no tab strip carries " & title)
  var model = EventLogModel(isVisible: true)
  var candidates = 0
  for line in pane.body:
    if line.strip().len == 0: continue
    inc candidates
    let row = parseTerminalEventRow(line)
    if row.ok: model.events.add EventDataModel(consoleOutput: row.consoleOutput)
  if model.events.len == 0:
    if candidates == 0: return empty[EventLogModel]()
    return unreadable[EventLogModel](urGrammarMismatch,
      $candidates & " candidate rows and none matched " &
      TerminalEventRowGrammar.shape)
  model.ofRows = model.events.len
  read(model)

proc readTerminalPointList*(frame: openArray[string]; title = "Breakpoints"):
    ScreenReading[PointListModel] =
  let pane = locateTerminalPane(frame, title)
  if pane.row < 0:
    return unreadable[PointListModel](urRegionNotLocated,
      "no tab strip carries " & title)
  var model = PointListModel(isVisible: true)
  var candidates = 0
  for line in pane.body:
    let s = line.strip()
    if s.len == 0: continue
    if s.toLowerAscii.contains("no breakpoints or tracepoints"):
      return empty[PointListModel]()
    inc candidates
    let row = parsePointRow(s)
    if row.ok:
      model.points.add PointRowModel(kind: row.kind, fileName: row.fileName,
                                     lineNumber: row.lineNumber)
  if model.points.len == 0:
    if candidates == 0: return empty[PointListModel]()
    return unreadable[PointListModel](urGrammarMismatch,
      $candidates & " candidate rows and none matched " &
      PointListGrammar.shape)
  read(model)
