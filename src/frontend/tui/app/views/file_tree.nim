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

import std/strutils

import ../layout/profile
import ./styled_row

export styled_row, profile

type
  FileTreeEntry* = object
    ## One row of a REPLAY session's file tree, as the desktop's Files pane
    ## draws it (PLAT-47): the entry's own label at its depth, folders
    ## expanded. `path` is the entry's recording-relative path.
    text*: string
    depth*: int
    isFolder*: bool
    path*: string
    expanded*: bool
      ## PLAT-50: a folder whose children follow it (the VM's
      ## `isExpanded`); a collapsed one is marked `CollapsedFolderGlyph`.

  FileTreeModel* = object
    entries*: seq[FileTreeEntry]
      ## PLAT-47: a replay session's tree — the recording's source folders,
      ## the SAME `FilesystemEntryNode` tree the desktop's Files pane renders
      ## (`native_host.recordingFileTree`, loaded into the session's
      ## `FilesystemVM` by `loadRecordingPanes`) — row for row, so the two
      ## panes list the same entries under the same labels. Empty in Edit
      ## mode, which lists `files` (the project walk) instead.
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
  FileTreeTitleStyle* = CellStyle(role: srModeEdit, bold: true)
  FileTreeRuleStyle* = CellStyle(role: srBorderPane)
  FileTreeOpenStyle* = CellStyle(role: srChromeText, bold: true)
  FileTreePlainStyle* = CellStyle(role: srChromeMuted)
  FileTreeSelectedBackground* = srSurfaceSelection
  FileTreeTruncatedStyle* = CellStyle(role: srChromeNotification)
  OpenMarker* = "•"
    ## Beside the file the editor holds. One cell, so the paths stay aligned.

proc initFileTreeModel*(files: seq[string] = @[]; selected = -1;
                        scrollTop = 0; truncated = false;
                        openPath = ""): FileTreeModel =
  FileTreeModel(files: files, selected: selected, scrollTop: scrollTop,
                truncated: truncated, openPath: openPath)

proc isEmpty*(model: FileTreeModel): bool =
  model.files.len == 0 and model.entries.len == 0

const FolderGlyph* = "▼"
  ## Beside an expanded folder, as the desktop's twisty. One cell;
  ## `borders.asciiFor` degrades it to `v`.
const CollapsedFolderGlyph* = "▶"
  ## PLAT-50: beside a COLLAPSED folder (a click opens it). `asciiFor`: `>`.

proc entryText*(e: FileTreeEntry): string =
  ## What one tree row says: indented by depth, a folder marked.
  repeat("  ", max(0, e.depth)) &
    (if not e.isFolder: "  "
     elif e.expanded: FolderGlyph & " "
     else: CollapsedFolderGlyph & " ") & e.text

proc initFileTreeModel*(entries: seq[FileTreeEntry]): FileTreeModel =
  ## A replay session's file tree.
  FileTreeModel(entries: entries, selected: -1)

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
  if model.entries.len > 0:
    for i in 0 ..< bodyRows:
      let idx = model.scrollTop + i
      if idx < 0 or idx >= model.entries.len:
        break
      let e = model.entries[idx]
      let isOpen = not e.isFolder and model.openPath.len > 0 and
                   e.path.endsWith(model.openPath)
      let style = if isOpen: FileTreeOpenStyle else: FileTreePlainStyle
      let text = truncateToCells(entryText(e), area.width)
      g.paint(area.row + 1 + i, area.col, text, style)
      inc result.renderedRows
      result.rows.add @[StyledSpan(text: text, style: style)]
    return
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
                  out2.surface = FileTreeSelectedBackground
                  out2)
    inc result.renderedRows
    result.rows.add @[StyledSpan(text: text, style: style)]
