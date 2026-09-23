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
## A pane's region: its TITLE ROW is the row where the pane's upper-case title
## starts a run followed by `-` fill (`POINTS 1 point(s) ----`); its columns
## run from the title's first cell to the next `|` separator on that row (or
## the frame's edge); its body is every row below the title until a row whose
## slice starts another title, or the frame ends.

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
  PaneSeparators = ["|", "│"]
    ## The glyph between two side-by-side panes: ASCII under
    ## `--ascii-borders`, the box-drawing one otherwise.
  TitleFills = ["---", "───"]
    ## A title row's fill, in the same two spellings.

func cells(line: string): seq[Rune] = line.toRunes

func sliceCells(r: seq[Rune]; start, width: int): string =
  if start >= r.len: return ""
  $r[start ..< min(r.len, start + width)]

func isTitleSlice(s: string): bool =
  ## A pane title row: an upper-case word first, and a fill after it.
  let t = s.strip(trailing = false)
  if t.len < 3 or t.len != s.len: return false
  if t[0] notin {'A'..'Z'}: return false
  let word = t.splitWhitespace()[0]
  word.allCharsInSet({'A'..'Z', '&'}) and word.len >= 3 and
    TitleFills.anyIt(it in t)

func separatorAt(r: seq[Rune]; start: int): int =
  ## The first pane separator at or after cell `start`, or `r.len`.
  for i in start ..< r.len:
    if $r[i] in PaneSeparators: return i
  r.len

proc locateTerminalPane*(frame: openArray[string]; title: string): TerminalPane =
  ## The first pane whose title row starts with `title` (upper case). A pane
  ## that is not on the screen answers `row == -1`.
  result = TerminalPane(title: title, row: -1)
  for r, line in frame:
    let rs = cells(line)
    let text = $rs
    var start = 0
    while true:
      let at = text.find(title, start)
      if at < 0: break
      let col = text[0 ..< at].runeLen
      let startsCell = col == 0 or $rs[col - 1] in PaneSeparators or
                       $rs[col - 1] == " "
      let stop = separatorAt(rs, col)
      let slice = sliceCells(rs, col, stop - col)
      if startsCell and slice.startsWith(title & " ") and
         TitleFills.anyIt(it in slice):
        result.row = r
        result.col = col
        result.width = stop - col
        break
      start = at + 1
    if result.row >= 0: break
  if result.row < 0: return
  for r in result.row + 1 .. frame.high:
    let slice = sliceCells(cells(frame[r]), result.col, result.width)
    if isTitleSlice(slice): break
    result.body.add slice.strip(leading = false)

proc readTerminalEventLog*(frame: openArray[string]; title = "TRACEPOINTS"):
    ScreenReading[EventLogModel] =
  let pane = locateTerminalPane(frame, title)
  if pane.row < 0:
    return unreadable[EventLogModel](urRegionNotLocated,
      "no title row starts with " & title)
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

proc readTerminalPointList*(frame: openArray[string]; title = "POINTS"):
    ScreenReading[PointListModel] =
  let pane = locateTerminalPane(frame, title)
  if pane.row < 0:
    return unreadable[PointListModel](urRegionNotLocated,
      "no title row starts with " & title)
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
