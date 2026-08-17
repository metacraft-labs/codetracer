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
## This module owns step 2, step 4, and the "list and editor agree" half of
## step 1.  It is a named, reusable routine rather than inline startup code
## because §7 requires all three launch paths to converge on one routine ("All
## three entry points converge on the same routine: load the dataset, populate
## the three panels, focus the VCS panel, open the first file") — DR-R7 makes
## `ct --deepreview`, the diff-associated trace and the agentic handoff call
## it.
##
## Step 4 — "The Agent Activity panel's DeepReview section populates with
## coverage and test results" — lives here for exactly the reason §2.1 gives:
## the section "must not require a live agent session: a review launched from
## the CLI over an exported dataset must populate it too".  Sharing one routine
## with the file-opening step is what makes the no-agent path and the agentic
## handoff populate the pane identically rather than by two hand-kept-in-sync
## code paths.
##
## Everything here is pure with respect to the DOM: the caller supplies the
## opener and the already-projected changeset rows, so the step is exercisable
## headlessly (see `src/tests/gui/tests/deepreview/deepreview_vm_test.nim` and
## `src/tests/gui/tests/agent-activity-deepreview/
## agent_activity_deepreview_vm_test.nim`) and the imperative host
## (`src/frontend/ui/vcs.nim`) supplies the GoldenLayout side effects.

import isonim/core/signals

import ../store/types
import agent_activity_deepreview_vm
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

# ---------------------------------------------------------------------------
# §7 step 4 — the Agent Activity panel's DeepReview section (DR-R3)
# ---------------------------------------------------------------------------

proc reviewCoverageSummary*(files: openArray[AgentDeepReviewFileCoverage];
                            functionsTraced: int):
    AgentDeepReviewCoverageSummary {.noSideEffect.} =
  ## The changeset's aggregate coverage — DeepReview-GUI.md §2.1, "Coverage
  ## summary — aggregate executed / total lines and percentage for the
  ## changeset".
  ##
  ## Every value is derived from the rows, which are themselves derived from
  ## `DeepReviewFileData.coverage`; nothing is invented.  A changeset whose
  ## files carry no coverage at all yields 0% over 0 lines rather than a
  ## division by zero.
  var covered = 0
  var total = 0
  for file in files:
    covered += file.coveredLines
    total += file.totalLines
  AgentDeepReviewCoverageSummary(
    totalLinesCovered: covered,
    totalLinesUncovered: total - covered,
    coveragePercent:
      if total > 0: (covered.float / total.float) * 100.0 else: 0.0,
    functionsTraced: functionsTraced)

proc populateReviewActivity*(activity: AgentActivityDeepReviewVM;
                             files: openArray[AgentDeepReviewFileCoverage];
                             functionsTraced: int) =
  ## §7 step 4: "The Agent Activity panel's DeepReview section populates with
  ## coverage and test results."
  ##
  ## `files` is the review's changeset already projected into coverage rows —
  ## the host walks `DeepReviewData`, which is a JS object and cannot be read
  ## from a headless build, so the projection stays on the host side and the
  ## decision stays here.
  ##
  ## Test results are *not* set: `DeepReviewData` carries none (no test name,
  ## no pass/fail, no duration), so a dataset-launched review has nothing to
  ## report and the row is marked unavailable rather than zeroed — see
  ## `setTestResultsUnavailable`.  A live agent session that already reported
  ## a run keeps it: entering a review must not erase a fact somebody
  ## observed.
  if activity.isNil:
    return
  activity.setFileCoverage(files)
  activity.setCoverageSummary(reviewCoverageSummary(files, functionsTraced))
  if not activity.testResultsAvailable.val:
    activity.setTestResultsUnavailable()
  activity.setReviewActive(true)
  # The section is collapsible, and collapsed by default so it stays out of
  # the way of an agent conversation.  A review is the case where it is the
  # point of the panel — §2.1: the review answers "what was run, what did it
  # cover, and what passed" here — so entering one opens it.  The reviewer can
  # still fold it away; nothing re-opens it afterwards.
  activity.setExpanded(true)

# ---------------------------------------------------------------------------
# §2.1 — "two views of one selection"
# ---------------------------------------------------------------------------

proc selectedReviewPath*(vm: VCSVM): string =
  ## Path of the changed-files row the VCS panel currently has selected, or
  ## the empty string when none is.
  for row in vm.changedFiles.val:
    if row.selected:
      return row.path
  ""

proc reviewRowIndexForPath*(vm: VCSVM; path: string): int =
  ## Index of the changed-files row naming `path`, or -1.  Hosts use it to
  ## turn a selection arriving from the coverage table into the same
  ## row-index gesture a click in the Changed Files list produces.
  if path.len == 0:
    return -1
  let rows = vm.changedFiles.val
  for i in 0 ..< rows.len:
    if rows[i].path == path:
      return i
  -1

proc selectReviewRowByPath*(vm: VCSVM; path: string): bool {.discardable.} =
  ## Select the changed-files row whose path is `path`.  Returns false — and
  ## changes nothing — when the review has no such file, so a selection
  ## arriving from the other view cannot blank the VCS panel's highlight.
  let index = vm.reviewRowIndexForPath(path)
  if index < 0:
    return false
  vm.selectReviewRow(index)

proc syncActivitySelectionFromVCS*(vcs: VCSVM;
                                   activity: AgentActivityDeepReviewVM):
    bool {.discardable.} =
  ## VCS panel -> per-file coverage table.  DeepReview-GUI.md §2.1:
  ## "Selecting a file in either the VCS panel or the per-file coverage table
  ## should agree with the other; they are two views of one selection."
  if vcs.isNil or activity.isNil:
    return false
  let path = vcs.selectedReviewPath()
  if path.len == 0:
    return false
  activity.setSelectedFilePath(path)
  true

proc selectActivityReviewFile*(vcs: VCSVM;
                               activity: AgentActivityDeepReviewVM;
                               path: string): bool {.discardable.} =
  ## Per-file coverage table -> VCS panel: the other direction of the same
  ## agreement.  Both views move together or neither does — a path the review
  ## does not contain is rejected rather than half-applied, which is what
  ## keeps "two views of one selection" true rather than approximately true.
  if activity.isNil or path.len == 0:
    return false
  if not vcs.isNil and not vcs.selectReviewRowByPath(path):
    return false
  activity.setSelectedFilePath(path)
  true

# ---------------------------------------------------------------------------
# The whole entry step
# ---------------------------------------------------------------------------

proc enterReview*(vcs: VCSVM;
                  activity: AgentActivityDeepReviewVM;
                  coverage: openArray[AgentDeepReviewFileCoverage];
                  functionsTraced: int;
                  open: ReviewOpenProc): VCSOpenAction {.discardable.} =
  ## The review-entry step, whichever launch path started the review.
  ##
  ## DeepReview-GUI.md §7, "Transition into a Review": the first modified file
  ## opens in the editor (step 2), the Agent Activity panel's DeepReview
  ## section populates (step 4), and the changed-files list and the coverage
  ## table end up naming the same file (step 1 + §2.1).
  ##
  ## `activity` may be nil — a host whose layout has no Agent Activity panel
  ## still gets a navigable review.
  populateReviewActivity(activity, coverage, functionsTraced)
  result = vcs.openFirstReviewFile(open)
  discard syncActivitySelectionFromVCS(vcs, activity)
