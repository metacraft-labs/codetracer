## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule. This module paints a VALUE; it
## reads no ViewModel (`host/tui_session.searchModelOf` turns the shared
## `SearchResultsVM` into the model below).
##
## app/views/search_results_pane.nim — PLAT-57. **FIND IN FILES, as a pane.**
##
## The desktop's FIND IN FILES panel (`viewmodel/views/
## isonim_search_results_view.nim`) draws the query field with its three
## toggles, then the results grouped by file: a header per file (its short
## path and its count) and a row per matching line (the line number, the
## text, the match highlighted). This pane draws the same, from the same
## ViewModel, with the same words — the captions, the counts and the
## highlight split are the ViewModel's (`shortResultPath`, `matchCountLabel`,
## `rowParts`), never re-derived here:
##
##     ╶ handle                        Aa  ab  .*
##     12 results in 3 files
##     src/main.py · 2 matches
##       12  def handle(event):
##       40  handle(e)
##     lib/util.py · 1 match
##        7  # handle the rest
##
## The query is typed in the omnibox (`:grep <text>`, Find-And-Incremental-
## Search.md §5.1), where `Alt+C` / `Alt+W` / `Alt+R` flip the toggles; the
## field here shows it. A press on a row opens the
## result (K35, never moving the recording position), on a toggle flips it,
## and the rightmost column is the list's scrollbar scrubber when the rows
## overflow (Scrollbar-Scrubbers.md: a list scrubber moves the VIEW).

import codetracer_embed

import ../layout/profile
import ../layout/project
import ./header
import ./styled_row
import ./scrubber_track

export styled_row, profile, scrubber_track

type
  SearchPaneRowKind* = enum
    spFile    ## a file group's header
    spMatch   ## one matching line

  SearchPaneRow* = object
    kind*: SearchPaneRowKind
    caption*: string
      ## spFile: the group's short path.
    count*: string
      ## spFile: "3 matches".
    path*: string
      ## The row's file.
    index*: int
      ## spMatch: the row's index in `SearchResultsVM.results`.
    line*: int
    before*, hit*, after*: string
      ## spMatch: the text split around the runner's match.

  SearchPaneOption* = object
    ## One toggle as the ViewModel labels it (`Aa`), and the operation that
    ## flips it (`search.toggle-case`) — what a press on it runs, as its key
    ## in the field does.
    operation*, label*: string
    on*: bool

  SearchResultsPaneModel* = object
    loaded*: bool
      ## Whether a session supplied the pane at all.
    query*: string
    options*: seq[SearchPaneOption]
      ## The toggles, in the ViewModel's order (`SearchOption`).
    summary*: string
      ## Where the search is ("12 results in 3 files", "Searching…").
    empty*: string
      ## What the body says with no rows.
    rows*: seq[SearchPaneRow]
    selected*: int
      ## The selected result's index, -1 for none.
    scrollTop*: int
      ## The first list row shown.

  SearchPaneTargetKind* = enum
    stNone, stQuery, stOption, stFile, stMatch, stTrack

  SearchPaneTarget* = object
    kind*: SearchPaneTargetKind
    index*: int
      ## stMatch: the result index.
    option*: string
      ## stOption: the toggle's operation.
    path*: string

  SearchPaneScreen* = object
    listTop*, listRows*: int
      ## The rows the list occupies.
    trackCol*: int
      ## The scrubber's column, -1 when the list does not overflow.
    optionCols*: seq[int]
      ## Where each of the model's toggles starts (row 0); empty when they
      ## did not fit.
    painted*: seq[string]
      ## Every painted list row's text, in order (for the suites).

const
  SearchPlaceholder* = "Search in files..."
    ## The desktop field's placeholder.
  SearchFieldStyle = CellStyle(role: srSurfaceInput, surface: srSurfaceInput)
  SearchPlaceholderStyle = CellStyle(role: srChromeMuted,
                                     surface: srSurfaceInput, italic: true)
  SearchOptionOffStyle = CellStyle(role: srChromeMuted)
  SearchOptionOnStyle = CellStyle(role: srChromeTitle, bold: true,
                                  surface: srSurfaceSelection)
  SearchSummaryStyle = CellStyle(role: srChromeMuted)
  SearchFileStyle = CellStyle(role: srChromeTitle, bold: true)
  SearchCountStyle = CellStyle(role: srChromeMuted)
  SearchLineNumberStyle = CellStyle(role: srChromeMuted)
  SearchTextStyle = CellStyle(role: srChromeText)
  SearchHitStyle* = CellStyle(role: srLineSearchMatch, surface: srLineSearchMatch)
    ## The match, on the editor's search-match colours.
  SearchSelectedSurface = srSurfaceSelection
  SearchOptionCells = 4
    ## " Aa " — a toggle and its padding.

proc lineNumberCells(model: SearchResultsPaneModel): int =
  ## The width of the line-number column: the widest number listed.
  result = 1
  for r in model.rows:
    if r.kind == spMatch:
      result = max(result, len($r.line))

proc clampScrollTop*(model: SearchResultsPaneModel; top, listRows: int): int =
  clamp(top, 0, max(0, model.rows.len - max(1, listRows)))

proc scrubberOf*(model: SearchResultsPaneModel; listRows: int): ScrubberModel =
  ## The list's scrollbar scrubber: the rows, the view's top, no current mark
  ## (a search result has no "where the debugger is").
  scrubberModel(model.rows.len, model.clampScrollTop(model.scrollTop, listRows),
                listRows)

proc revealRow*(model: SearchResultsPaneModel; rowIndex, listRows: int): int =
  ## The scroll top that keeps list row `rowIndex` in view.
  let rows = max(1, listRows)
  if rowIndex < model.scrollTop: rowIndex
  elif rowIndex >= model.scrollTop + rows: rowIndex - rows + 1
  else: model.scrollTop

proc rowOfResult*(model: SearchResultsPaneModel; index: int): int =
  ## The list row of result `index`, -1 when it is not listed.
  for i, r in model.rows:
    if r.kind == spMatch and r.index == index:
      return i
  -1

proc listGeometry*(area: CellArea): tuple[top, rows: int] =
  ## The list's rows inside `area`: below the field and the summary.
  (area.row + 2, max(0, area.height - 2))

proc paintSpans(g: var StyledGrid; row, col, width: int;
                spans: openArray[StyledSpan]): string =
  var used = 0
  for span in spans:
    if used >= width:
      break
    let fitted = truncateToCells(span.text, width - used)
    if fitted.len == 0:
      continue
    g.paint(row, col + used, fitted, span.style)
    result.add fitted
    used += cellWidthOf(fitted)

proc paintSearchResults*(g: var StyledGrid; area: CellArea;
                         model: SearchResultsPaneModel): SearchPaneScreen =
  ## The pane into `area` (the rows below its tab strip) and nowhere else.
  result = SearchPaneScreen(trackCol: -1)
  if area.width <= 0 or area.height <= 0:
    return
  # Row 0: the field, then the toggles at the right edge.
  let optionsCells = model.options.len * SearchOptionCells
  let fieldCells = if area.width > optionsCells + 4: area.width - optionsCells
                   else: area.width
  g.fillSurface(area.row, area.col, fieldCells, 1, srSurfaceInput)
  if model.query.len > 0:
    g.paint(area.row, area.col + 1, fitCells(model.query, max(0, fieldCells - 2)),
            SearchFieldStyle)
  else:
    g.paint(area.row, area.col + 1,
            fitCells(SearchPlaceholder, max(0, fieldCells - 2)),
            SearchPlaceholderStyle)
  if fieldCells < area.width:
    for i, o in model.options:
      result.optionCols.add area.col + fieldCells + i * SearchOptionCells
      g.paint(area.row, result.optionCols[i], " " & o.label & " ",
              if o.on: SearchOptionOnStyle else: SearchOptionOffStyle)
  if area.height < 2:
    return
  # Row 1: where the search is, or the empty state's sentence.
  let status = if model.summary.len > 0: model.summary else: model.empty
  g.paint(area.row + 1, area.col, fitCells(status, area.width),
          SearchSummaryStyle)
  let (top, rows) = listGeometry(area)
  result.listTop = top
  result.listRows = rows
  if rows <= 0 or model.rows.len == 0:
    return
  let overflow = model.rows.len > rows
  let width = if overflow: area.width - ScrubberTrackCells else: area.width
  if overflow:
    result.trackCol = area.col + area.width - ScrubberTrackCells
  let numberCells = lineNumberCells(model)
  let first = model.clampScrollTop(model.scrollTop, rows)
  for k in 0 ..< rows:
    let i = first + k
    if i >= model.rows.len:
      break
    let r = model.rows[i]
    let y = top + k
    case r.kind
    of spFile:
      result.painted.add g.paintSpans(y, area.col, width, [
        StyledSpan(text: r.caption, style: SearchFileStyle),
        StyledSpan(text: " " & g.glyphText(grSeparator) & " " & r.count,
                   style: SearchCountStyle)])
    of spMatch:
      let selected = r.index == model.selected
      if selected:
        g.fillSurface(y, area.col, width, 1, SearchSelectedSurface)
      var number = $r.line
      while number.len < numberCells:
        number = " " & number
      result.painted.add g.paintSpans(y, area.col, width, [
        StyledSpan(text: "  " & number & "  ", style: SearchLineNumberStyle),
        StyledSpan(text: r.before, style: SearchTextStyle),
        StyledSpan(text: r.hit, style: SearchHitStyle),
        StyledSpan(text: r.after, style: SearchTextStyle)])
  if overflow:
    g.paintVerticalScrubber(result.trackCol, top, rows,
                            model.scrubberOf(rows))

proc searchTargetAt*(model: SearchResultsPaneModel; screen: SearchPaneScreen;
                     area: CellArea; row, col: int): SearchPaneTarget =
  ## What a press at `(row, col)` is on, by the arithmetic that painted it.
  if area.width <= 0 or not area.contains(row, col):
    return SearchPaneTarget(kind: stNone)
  if row == area.row:
    for i, at in screen.optionCols:
      if col >= at and col < at + SearchOptionCells and i < model.options.len:
        return SearchPaneTarget(kind: stOption,
                                option: model.options[i].operation)
    return SearchPaneTarget(kind: stQuery)
  if screen.trackCol >= 0 and col == screen.trackCol and
     row >= screen.listTop and row < screen.listTop + screen.listRows:
    return SearchPaneTarget(kind: stTrack)
  if row < screen.listTop or row >= screen.listTop + screen.listRows:
    return SearchPaneTarget(kind: stNone)
  let i = model.clampScrollTop(model.scrollTop, screen.listRows) +
          (row - screen.listTop)
  if i < 0 or i >= model.rows.len:
    return SearchPaneTarget(kind: stNone)
  let r = model.rows[i]
  case r.kind
  of spFile: SearchPaneTarget(kind: stFile, path: r.path)
  of spMatch: SearchPaneTarget(kind: stMatch, index: r.index, path: r.path)
