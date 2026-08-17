## The review-entry navigation step.
##
## `codetracer-specs/DeepReview/DeepReview-GUI.md` §7, "Transition into a
## Review", lists what happens when a review session starts, whichever of the
## three entry points started it:
##
##   1. the VCS panel populates with the changeset and becomes the visible tab
##      of its stack,
##   2. *the first modified file opens in the editor*,
##   3. flow data overlays onto its lines,
##   4. the Agent Activity DeepReview section populates,
##   5. every other panel keeps showing trace data.
##
## This module owns step 2 and the "list and editor agree" half of step 1.  It
## is a named, reusable routine rather than inline startup code because §7
## requires all three launch paths to converge on one routine ("All three entry
## points converge on the same routine: load the dataset, populate the three
## panels, focus the VCS panel, open the first file") — DR-R7 makes
## `ct --deepreview`, the diff-associated trace and the agentic handoff call
## it.
##
## Everything here is pure with respect to the DOM: the caller supplies the
## opener, so the step is exercisable headlessly (see
## `src/tests/gui/tests/deepreview/deepreview_vm_test.nim`) and the imperative
## host (`src/frontend/ui/vcs.nim`) supplies the GoldenLayout side effects.

import isonim/core/signals

import vcs_vm

type
  ReviewOpenProc* = proc(action: VCSOpenAction) {.closure.}
    ## Opens (or focuses) the editor document an action names.  Implemented by
    ## the host over `openLayoutTab` / `openTab`; implemented by tests over a
    ## list of document keys.

proc selectReviewRow*(vm: VCSVM; index: int): bool {.discardable.} =
  ## Mark row `index` of the changed-files list as the selected one.
  ##
  ## VCS-Panel.md, "Changed Files": "The selected row is highlighted".  The
  ## selection is exclusive: a review has exactly one file under inspection at
  ## a time, and it is the one the editor is showing.
  ##
  ## Returns true when a row was selected.
  let rows = vm.changedFiles.val
  if index < 0 or index >= rows.len:
    return false
  var updated = rows
  for i in 0 ..< updated.len:
    updated[i].selected = i == index
  vm.changedFiles.val = updated
  true

proc openReviewFile*(vm: VCSVM; index: int; open: ReviewOpenProc):
    VCSOpenAction {.discardable.} =
  ## Select row `index` and open its review representation in the editor.
  ##
  ## The representation is whatever `VCSVM.viewMode` currently selects — the
  ## VCS panel's view-mode toggle (VCS-Panel.md, "View mode toggle") — with
  ## the deleted-file rule applied by `openActionFor`.
  ##
  ## `open` is called at most once, and never for a row that does not exist:
  ## an empty changeset opens nothing rather than fabricating a document.
  result = vm.openActionForRow(index)
  if result.kind == voaNone:
    return
  discard vm.selectReviewRow(index)
  if open != nil:
    open(result)

proc openFirstReviewFile*(vm: VCSVM; open: ReviewOpenProc):
    VCSOpenAction {.discardable.} =
  ## §7 step 2: "The first modified file opens in the editor."
  vm.openReviewFile(0, open)
