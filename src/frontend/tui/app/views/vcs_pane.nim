## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule. This module paints a VALUE; it
## reads no repository and no ViewModel (`host/vcs_source.nim` turns the
## shared `VCSVM` into the model below).
##
## app/views/vcs_pane.nim — PLAT-47 deliverable 4. **The VCS pane.**
##
## The desktop's VCS panel (`viewmodel/views/isonim_vcs_view.nim`) draws its
## branch, the working tree's changed files with their states, and the commit
## history. This pane draws the same three from the same ViewModel, in the
## same order and with the same words:
##
##     VCS  plat47-vcs ────────────
##     WORKING TREE (3)
##      A added.txt
##      M notes.txt
##      ? scratch.txt
##     COMMITS (1)
##      496ddf7 Initial fixture commit
##
## Until PLAT-47 the terminal placed a report leaf here ("the terminal has no
## version-control view yet").

import std/strutils

# M71 (#838): the pane's ordinary scrollbar is the shared scrubber model.
from codetracer_embed import ScrubberModel, scrubberModel

import ../layout/profile
import ./styled_row
import ./scrubber_track

export styled_row, profile

type
  VcsFileLine* = object
    status*: string   ## one letter: `M`, `A`, `D`, `R`, `C`, `U` or `?`
    path*: string     ## repository-relative

  VcsCommitLine* = object
    hash*: string
    subject*: string

  VcsPaneModel* = object
    ## Everything the pane shows, as a value.
    loaded*: bool
      ## Whether a repository was read at all. An unloaded model paints
      ## nothing and the shell's generic title stands.
    isRepo*: bool
    message*: string
      ## Why there is nothing to list ("Not a git repository").
    branch*: string
    files*: seq[VcsFileLine]
    commits*: seq[VcsCommitLine]
    workingTreeTitle*: string
      ## The desktop's own caption for the section (`vcs_vm.VCSWorkingTreeTitle`),
      ## carried in the value so the two front-ends cannot word it differently.
    cleanText*: string
      ## What the section says for a clean tree (`vcs_vm.VCSCleanTreeText`).
    expandedCommit*: int
      ## PLAT-50 (K53): the commit a click opened (its files listed under
      ## it, `VCSVM.commitFilesMap`), -1 for none — the desktop's accordion.
    commitFiles*: seq[VcsFileLine]
      ## The files `expandedCommit` changed.
    scrollTop*: int
      ## M71 (#838): the first row the pane shows — the reader's position,
      ## which the host carries across refreshes (`vcs_source.publish`).

  VcsRowKind* = enum
    vrNone, vrFile, vrCommit, vrCommitFile

  VcsRowTarget* = object
    ## PLAT-50: what one painted row is, for a click.
    row*: int
    kind*: VcsRowKind
    index*: int
      ## The file's, the commit's or the commit file's index.
    status*, path*, hash*: string

  VcsPaneScreen* = object
    rows*: seq[StyledRow]
    fileRows*: int
      ## How many working-tree rows reached the screen.
    targets*: seq[VcsRowTarget]
      ## PLAT-50: every row a click acts on, as painted.
    area*: CellArea
      ## M71 (#838): the rectangle painted (every row of it a list row).
    totalRows*: int
      ## M71: every row the pane lists, on screen or not.
    top*: int
      ## M71: the index of the first row shown (`scrollTop`, clamped).
    trackCol*: int
      ## M71: the scrollbar's column (down the whole area), -1 while the
      ## rows fit.

const
  BranchMarker* = "on "
    ## The branch row's lead-in: `on main`.
  VcsBranchStyle* = CellStyle(role: srChromeText, bold: true)
  VcsSectionStyle* = CellStyle(role: srChromeTitle, bold: true)
  VcsPathStyle* = CellStyle(role: srChromeText)
  VcsHashStyle* = CellStyle(role: srChromeMuted)
  VcsMessageStyle* = CellStyle(role: srChromeMuted)
  CommitsTitle* = "COMMITS"

func statusStyle*(status: string): CellStyle =
  ## A state letter's colour: new files as a success, deletions as an error,
  ## every other change as a modification (the warning colour, as the desktop
  ## draws `M` amber) — the three families the desktop's
  ## `vcs-status-*` classes colour apart.
  case status
  of "A", "?": CellStyle(role: srChromeSuccess, bold: true)
  of "D": CellStyle(role: srChromeError, bold: true)
  else: CellStyle(role: srChromeNotification, bold: true)

proc paintLine(g: var StyledGrid; row, col, width: int;
               spans: seq[StyledSpan]; fill = ""; fillStyle = DefaultCellStyle):
    StyledRow =
  var used = 0
  for span in spans:
    let fitted = truncateToCells(span.text, max(0, width - used))
    if fitted.len == 0:
      continue
    g.paint(row, col + used, fitted, span.style)
    result.add StyledSpan(text: fitted, style: span.style)
    used += cellWidthOf(fitted)
  if fill.len > 0 and used < width:
    let rule = repeatGlyph(fill, width - used)
    g.paint(row, col + used, rule, fillStyle)
    result.add StyledSpan(text: rule, style: fillStyle)

type
  VcsLine = object
    ## One row of the pane before it is painted (M71: the pane lists them
    ## all, then draws the window `scrollTop` names).
    spans: seq[StyledSpan]
    target: VcsRowTarget
      ## What a click on it acts on; `vrNone` for a caption or a message.
    isFile: bool
      ## A working-tree row (`fileRows` counts the ones on screen).

proc vcsLines(model: VcsPaneModel): seq[VcsLine] =
  ## Every row the pane lists, in order — the branch, the working tree and
  ## its files, the commits and the files of the one opened.
  template line(s: seq[StyledSpan]; t = VcsRowTarget(kind: vrNone);
                file = false) =
    result.add VcsLine(spans: s, target: t, isFile: file)
  if model.isRepo and model.branch.len > 0:
    line @[StyledSpan(text: BranchMarker & model.branch,
                      style: VcsBranchStyle)]
  if not model.isRepo:
    line @[StyledSpan(text: (if model.message.len > 0: model.message
                             else: "Not a git repository"),
                      style: VcsMessageStyle)]
    return
  line @[StyledSpan(text: model.workingTreeTitle.toUpperAscii & " (" &
                          $model.files.len & ")", style: VcsSectionStyle)]
  if model.files.len == 0:
    line @[StyledSpan(text: " " & model.cleanText, style: VcsMessageStyle)]
  for i, f in model.files:
    line @[StyledSpan(text: " ", style: DefaultCellStyle),
           StyledSpan(text: f.status, style: statusStyle(f.status)),
           StyledSpan(text: " " & f.path, style: VcsPathStyle)],
         VcsRowTarget(kind: vrFile, index: i, status: f.status, path: f.path),
         file = true
  if model.commits.len > 0:
    line @[StyledSpan(text: CommitsTitle & " (" & $model.commits.len & ")",
                      style: VcsSectionStyle)]
    for ci, c in model.commits:
      line(@[StyledSpan(text: " " & c.hash, style: VcsHashStyle),
             StyledSpan(text: " " & c.subject, style: VcsPathStyle)],
           VcsRowTarget(kind: vrCommit, index: ci, hash: c.hash))
      # PLAT-50 (K53): an opened commit lists the files it changed under it,
      # indented, as the desktop's accordion does.
      if ci == model.expandedCommit:
        for fi, f in model.commitFiles:
          line(@[StyledSpan(text: "   ", style: DefaultCellStyle),
                 StyledSpan(text: f.status, style: statusStyle(f.status)),
                 StyledSpan(text: " " & f.path, style: VcsPathStyle)],
               VcsRowTarget(kind: vrCommitFile, index: fi, status: f.status,
                            path: f.path, hash: c.hash))

proc scrubberOf*(screen: VcsPaneScreen): ScrubberModel =
  ## M71: the pane's ordinary scrollbar over what `paintVcsPane` drew — the
  ## population is every row it lists, the view the area from `top`.
  scrubberModel(screen.totalRows, screen.top, screen.area.height)

proc paintVcsPane*(g: var StyledGrid; area: CellArea;
                   model: VcsPaneModel): VcsPaneScreen =
  ## The pane into `area` and nowhere else.
  ##
  ## PLAT-49: NO TITLE BAR — the tab strip above the pane names it. The
  ## first row is CONTENT: the branch the working tree is on (the desktop's
  ## VCS panel heads its list with it), with no `VCS ───` rule. So every
  ## row of `area` is a row of the list.
  result = VcsPaneScreen(rows: @[], fileRows: 0, area: area, trackCol: -1)
  if area.width <= 0 or area.height <= 0:
    return
  let lines = vcsLines(model)
  result.totalRows = lines.len
  let top = clamp(model.scrollTop, 0, max(0, lines.len - area.height))
  result.top = top
  # M71 (#838): WHILE THE ROWS OVERFLOW, THE RIGHTMOST COLUMN IS THE PANE'S
  # SCROLLBAR (Scrollbar-Scrubbers.md §2 names the VCS pane: its whole
  # content is in hand, so it keeps an ordinary scrollbar; §4: the pane's
  # rightmost column, inside its own rectangle), and the rows are drawn in
  # the cells left of it. Rows that fit keep the whole width.
  let overflow = lines.len > area.height and area.width > ScrubberTrackCells
  let width = if overflow: area.width - ScrubberTrackCells else: area.width
  for i in 0 ..< area.height:
    let at = top + i
    if at >= lines.len:
      break
    let row = area.row + i
    let l = lines[at]
    if l.target.kind != vrNone:
      var t = l.target
      t.row = row
      result.targets.add t
    if l.isFile:
      inc result.fileRows
    result.rows.add g.paintLine(row, area.col, width, l.spans)
  if overflow:
    result.trackCol = area.col + width
    g.paintVerticalScrubber(result.trackCol, area.row, area.height,
                            result.scrubberOf)

proc vcsTargetAt*(screen: VcsPaneScreen; row: int): VcsRowTarget =
  ## PLAT-50: the row a press on screen row `row` is on.
  for t in screen.targets:
    if t.row == row:
      return t
  VcsRowTarget(row: row, kind: vrNone)
