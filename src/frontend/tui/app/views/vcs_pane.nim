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

import ../layout/profile
import ./styled_row

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

proc paintVcsPane*(g: var StyledGrid; area: CellArea;
                   model: VcsPaneModel): VcsPaneScreen =
  ## The pane into `area` and nowhere else.
  result = VcsPaneScreen(rows: @[], fileRows: 0)
  if area.width <= 0 or area.height <= 0:
    return
  # PLAT-49: NO TITLE BAR — the tab strip above the pane names it. The
  # first row is CONTENT: the branch the working tree is on (the desktop's
  # VCS panel heads its list with it), with no `VCS ───` rule.
  var row = area.row
  let last = area.row + area.height - 1
  template line(spans: seq[StyledSpan]) =
    if row <= last:
      result.rows.add g.paintLine(row, area.col, area.width, spans)
      inc row
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
    if row > last:
      break
    result.targets.add VcsRowTarget(row: row, kind: vrFile, index: i,
                                    status: f.status, path: f.path)
    line @[StyledSpan(text: " ", style: DefaultCellStyle),
           StyledSpan(text: f.status, style: statusStyle(f.status)),
           StyledSpan(text: " " & f.path, style: VcsPathStyle)]
    inc result.fileRows
  if model.commits.len > 0:
    line @[StyledSpan(text: CommitsTitle & " (" & $model.commits.len & ")",
                      style: VcsSectionStyle)]
    for ci, c in model.commits:
      if row > last:
        break
      result.targets.add VcsRowTarget(row: row, kind: vrCommit, index: ci,
                                      hash: c.hash)
      line @[StyledSpan(text: " " & c.hash, style: VcsHashStyle),
             StyledSpan(text: " " & c.subject, style: VcsPathStyle)]
      # PLAT-50 (K53): an opened commit lists the files it changed under it,
      # indented, as the desktop's accordion does.
      if ci == model.expandedCommit:
        for fi, f in model.commitFiles:
          if row > last:
            break
          result.targets.add VcsRowTarget(row: row, kind: vrCommitFile,
                                          index: fi, status: f.status,
                                          path: f.path, hash: c.hash)
          line @[StyledSpan(text: "   ", style: DefaultCellStyle),
                 StyledSpan(text: f.status, style: statusStyle(f.status)),
                 StyledSpan(text: " " & f.path, style: VcsPathStyle)]

proc vcsTargetAt*(screen: VcsPaneScreen; row: int): VcsRowTarget =
  ## PLAT-50: the row a press on screen row `row` is on.
  for t in screen.targets:
    if t.row == row:
      return t
  VcsRowTarget(row: row, kind: vrNone)
