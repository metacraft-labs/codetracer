## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule.
##
## app/views/file_tree.nim — PLAT-16. Edit mode's `paneFileTree`.
##
## A FLAT, SORTED LIST AND NOT A TREE, and that is a decision rather than a
## first draft. CodeTracer-TUI-Edit-Mode.md §8 open decision 3 recommends
## *"palette first, tree later — the palette exists, and a tree is a pane that
## costs layout work and a `PaneKind` bump."* The `PaneKind` bump is paid (§4
## names it), so the pane exists; what it does NOT yet have is expansion state,
## because a collapsed/expanded node set is persisted layout state and
## Layout-ViewModel has no place for it. A sorted list of project-relative
## paths shows the same files, is navigable with the same keys, and carries no
## state a switch could lose.
##
## The truncation is SHOWN. `host/edit_host.listProjectFiles` stops at
## `MaxProjectFiles`, and a listing missing files without saying so is one a
## user will conclude does not contain them.

import ../layout/profile
import ./styled_row

export styled_row, profile

type
  FileTreeModel* = object
    files*: seq[string]
      ## Project-relative paths, sorted, as `edit_host.listProjectFiles`
      ## produced them.
    selected*: int
      ## Index of the highlighted row, or -1 for none.
    scrollTop*: int
    truncated*: bool
    openPath*: string
      ## Which file is open in the editor, so the list can mark it. Distinct
      ## from `selected`: a user scrolling the list has not opened anything
      ## yet, and a pane that conflated the two would look like it had.

  FileTreeScreen* = object
    rows*: seq[StyledRow]
    area*: CellArea
    renderedRows*: int

const
  FileTreeTitle* = "FILES"
  FileTreeRule* = "─"
  FileTreeTitleStyle* = CellStyle(fg: "bright_yellow", bold: true)
  FileTreeRuleStyle* = CellStyle(fg: "bright_black")
  FileTreeOpenStyle* = CellStyle(fg: "white", bold: true)
  FileTreePlainStyle* = CellStyle(fg: "bright_black")
  FileTreeSelectedBackground* = "black"
  FileTreeTruncatedStyle* = CellStyle(fg: "yellow")
  OpenMarker* = "•"
    ## Beside the file the editor holds. One cell, so the paths stay aligned.

proc initFileTreeModel*(files: seq[string] = @[]; selected = -1;
                        scrollTop = 0; truncated = false;
                        openPath = ""): FileTreeModel =
  FileTreeModel(files: files, selected: selected, scrollTop: scrollTop,
                truncated: truncated, openPath: openPath)

proc isEmpty*(model: FileTreeModel): bool = model.files.len == 0

proc paintFileTree*(g: var StyledGrid; area: CellArea;
                    model: FileTreeModel): FileTreeScreen =
  result = FileTreeScreen(rows: @[], area: area, renderedRows: 0)
  if area.width <= 0 or area.height <= 0:
    return
  var title = @[StyledSpan(text: FileTreeTitle, style: FileTreeTitleStyle)]
  if model.truncated:
    title.add StyledSpan(text: " (first " & $model.files.len & ")",
                         style: FileTreeTruncatedStyle)
  var used = 0
  for span in title:
    let fitted = truncateToCells(span.text, max(0, area.width - used))
    if fitted.len == 0:
      continue
    g.paint(area.row, area.col + used, fitted, span.style)
    used += cellWidthOf(fitted)
  if used < area.width:
    g.paint(area.row, area.col + used,
            repeatGlyph(FileTreeRule, area.width - used), FileTreeRuleStyle)
  result.rows.add title

  let bodyRows = area.height - 1
  for i in 0 ..< bodyRows:
    let idx = model.scrollTop + i
    if idx < 0 or idx >= model.files.len:
      break
    let row = area.row + 1 + i
    let path = model.files[idx]
    let isOpen = path == model.openPath and path.len > 0
    let marker = if isOpen: OpenMarker else: " "
    let style = if isOpen: FileTreeOpenStyle else: FileTreePlainStyle
    let text = truncateToCells(marker & path, area.width)
    g.paint(row, area.col, text, style)
    if idx == model.selected:
      g.restyle(row, area.col, area.width,
                proc(s: CellStyle): CellStyle =
                  var out2 = s
                  out2.bg = FileTreeSelectedBackground
                  out2)
    inc result.renderedRows
    result.rows.add @[StyledSpan(text: text, style: style)]
