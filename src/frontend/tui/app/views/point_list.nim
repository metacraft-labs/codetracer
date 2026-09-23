## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/views/point_list.nim — PLAT-40. The terminal's **Points** pane: the
## session's breakpoints and tracepoints, one row each.
##
## Until PLAT-40 the layout model's `pointList` pane reached this front-end as
## a TITLE and nothing else — `shell.paintPane` had no arm for it — so a saved
## arrangement that placed it drew `POINTS ────` over an empty rectangle while
## the same rows drew in the native window and on the desktop. The rows are
## the store's point rows (`store.pointList.rows`), the one place every
## front-end's breakpoints end, converted by `source_binding.pointListPaneModelFor`
## — this module is a pure function of that value, like its siblings.
##
## A ROW IS `<kind> <file>:<line>`: the kind first, because it is what tells a
## breakpoint from a tracepoint at a glance; the location's BASE name, because
## the pane is narrow and the directory is the part a reader already knows.
## A disabled point is drawn dim with `(disabled)` after it.

import std/strutils

import ../layout/profile
import ./header
import ./styled_row

type
  PointListPaneRow* = object
    kind*: string
      ## `breakpoint` or `tracepoint` — `store/types`' spelling.
    path*: string
    line*: int
    enabled*: bool

  PointListPaneModel* = object
    rows*: seq[PointListPaneRow]
    loaded*: bool
      ## Whether a session has supplied rows at all. A pane with no session
      ## paints the plain title row, on the rule every sibling follows.

const
  EmptyPointsText* = "no breakpoints or tracepoints"
  EmptyPointsStyle* = CellStyle(fg: "bright_black", italic: true)
  DisabledPointStyle* = CellStyle(fg: "bright_black")

proc initPointListPaneModel*(rows: seq[PointListPaneRow] = @[];
                             loaded = false): PointListPaneModel =
  PointListPaneModel(rows: rows, loaded: loaded)

proc baseName(path: string): string =
  let slash = path.rfind('/')
  if slash >= 0: path[slash + 1 .. ^1] else: path

proc rowText*(r: PointListPaneRow): string =
  ## One row as the pane draws it.
  result = r.kind & " " & baseName(r.path) & ":" & $r.line
  if not r.enabled: result.add " (disabled)"

proc titleText*(model: PointListPaneModel): string =
  "POINTS " & $model.rows.len & " point(s)"

proc paintPointList*(g: var StyledGrid; area: CellArea;
                     model: PointListPaneModel): seq[string] =
  ## Paint the pane into `area` of `g`, and answer the rows' texts as painted.
  if area.width <= 0 or area.height <= 0:
    return
  var title = model.titleText()
  if textCells(title) + 1 <= area.width:
    title.add " "
  while textCells(title) < area.width:
    title.add "-"
  g.paint(area.row, area.col, fitCells(title, area.width))
  if area.height <= 1:
    return
  if model.rows.len == 0:
    g.paint(area.row + 1, area.col, fitCells(EmptyPointsText, area.width),
            EmptyPointsStyle)
    return
  for i, r in model.rows:
    if i + 1 >= area.height: break
    let text = fitCells(r.rowText(), area.width)
    g.paint(area.row + 1 + i, area.col, text,
            if r.enabled: DefaultCellStyle else: DisabledPointStyle)
    result.add text
