## views/agent_harbor_changes_code.nim
##
## The Changes panel's Code tab drawn with CodeTracer's VCS panel (INV-C-08):
## an adapter from the Changes viewmodel's file rows and file diffs
## (nim-agents-isonim-viewmodels `changes_vm`, over nim-agents' `change_diff`)
## to the VCS panel's row values (`VCSFileRow`, `VCSHunkRow`, `vcs_vm.nim`).
## The view then draws each file with the VCS view's own row renderer
## (`isonim_vcs_view.renderChangedFileRow`), so the rows, the status letters
## and the `+a -r` counts are the VCS panel's, not a copy of them.
##
## ## Why the adapter lives here
##
## `VCSVM` and its row types belong to CodeTracer: they sit on CodeTracer's
## platform layer (`platform/vcs`), which the shared viewmodel repository
## must not depend on. So the shared `ChangesVM` publishes its own rows and
## this module, beside the view, turns them into the VCS panel's. The GPUI
## and terminal views reuse the same values (their VCS panes draw the same
## rows), which is why the adapter renders nothing.
##
## Two facts the VCS row has no field for are drawn beside it by the view:
## where the change is (committed, uncommitted or both) and whether the file
## is one of the plan's key source files. The row's coverage column stays
## empty: a change shown here has no trace to cover.

import nim_agents_isonim_viewmodels/agent_harbor/changes_vm
import ../viewmodels/vcs_vm

export vcs_vm

proc vcsStatus(status: ChangeStatus): string =
  ## The VCS panel's status letter of a change (`A`, `M`, `D`, `R`).
  $status

proc vcsFileRow*(row: FileRow): VCSFileRow =
  ## One Code tab row as the VCS panel's changed-file row. The VCS row draws
  ## `baseName`; the Changes panel shows the whole repository path there,
  ## because key files, renames and deep paths are told apart by it (the view
  ## cuts it in its middle).
  VCSFileRow(status: vcsStatus(row.file.status), path: row.file.path,
             baseName: row.file.path, additions: row.file.added,
             deletions: row.file.removed, coverageText: "",
             selected: row.selected)

proc vcsLineType(kind: DiffLineKind): string =
  ## `vcs_vm.diffLineText`'s line types.
  case kind
  of dlContext: "context"
  of dlAdded: "added"
  of dlRemoved: "removed"
  of dlNoNewline: "context"

proc vcsHunkRow*(hunk: DiffHunk): VCSHunkRow =
  ## One hunk as the VCS panel's hunk value. An added or removed line's
  ## content carries its marker and a context line's does not: the
  ## collectors' convention, which `vcs_vm.diffLineText` inverts. Handing it
  ## the marker-less text instead would make `diffLineText` strip a file
  ## line's own leading `+` or `-`.
  result = VCSHunkRow(oldStart: hunk.oldStart, oldCount: hunk.oldCount,
                      newStart: hunk.newStart, newCount: hunk.newCount)
  for line in hunk.lines:
    let content = case line.kind
      of dlAdded: "+" & line.text
      of dlRemoved: "-" & line.text
      else: line.text
    result.lines.add VCSDiffLineRow(lineType: vcsLineType(line.kind),
                                    content: content, oldLine: line.oldLine,
                                    newLine: line.newLine)

proc hunkHeader*(hunk: VCSHunkRow): string =
  ## `@@ -12,4 +12,6 @@`, git's hunk header
  ## (https://git-scm.com/docs/diff-format#generate_patch_text_with_p).
  "@@ -" & $hunk.oldStart & "," & $hunk.oldCount & " +" & $hunk.newStart & "," &
    $hunk.newCount & " @@"

proc lineMarker*(line: VCSDiffLineRow): string =
  ## The one-character prefix a unified diff gives the line.
  case line.lineType
  of "added": "+"
  of "removed": "-"
  else: " "
