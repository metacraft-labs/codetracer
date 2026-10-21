## shared_pane_state.nim
##
## What one window tab shows in the panes whose ViewModel is shared by every
## tab of the window: Files, Test Results and Constraints.
##
## ## Why these panes need it
##
## Each tab of a window is its own session (`GUI/Multi-Window-Tab-Management.md`
## §Tab Behavior, rule 1), and keeps its state across switches (rule 6). These
## three panes do not have a ViewModel per tab: the renderer creates one
## `FilesystemVM`, one `TestResultsVM` and one `ConstraintsVM` for the whole
## window, so whatever the active tab writes into them is what every other tab
## shows too. Making them per tab would take one `SessionViewModel` per tab, a
## redesign rather than a fix. Only the active tab is ever visible, so shared
## instances that always hold the ACTIVE tab's state show every tab correctly,
## and that is what this module provides:
##
## * `captureSharedPanes` keeps a copy of what the tab being left showed;
## * `restoreSharedPanes` gives it back when that tab is entered again;
## * `resetSharedPanes` gives a tab that has never been shown what a freshly
##   started window shows, instead of the previous tab's project. A tab that
##   then opens a recording would otherwise keep it for good: a replay never
##   asks the host for these panes, so nothing else would overwrite it.
##
## Files is the odd one out. Its tree is restored by the caller from the
## entered tab's own legacy `FilesystemComponent`, whose `EditorService` is the
## source of truth for it; only the expanded folders, which live in the VM
## alone, are kept here.
##
## Every VM argument may be nil: each is created lazily, when its pane first
## mounts, and a pane that does not exist has nothing to keep or reset.
##
## Pure ViewModel code: no DOM, no `Data`, so it runs in the headless VM
## lanes on both backends.

import std/sets

import isonim/core/signals

import ../../../ct_test/contracts
import ./test_results_vm
import ./constraints_vm
import ./filesystem_vm

type
  SharedPaneSnapshot* = ref object
    ## What one tab last showed in the shared panes. Each part is present
    ## only when its ViewModel existed when the tab was left.
    hasTestResults*: bool
    testCatalog*: seq[TestItem]
    testSummary*: TestRunSummary
    testRunAbsence*: string
    testProjectName*: string
    testRecordings*: seq[TestRecordingRef]
    hasConstraints*: bool
    constraintsReport*: ConstraintReport
    constraintsProjectName*: string
    hasFilesystem*: bool
    expandedPaths*: HashSet[string]

proc captureSharedPanes*(tests: TestResultsVM; constraints: ConstraintsVM;
                         files: FilesystemVM): SharedPaneSnapshot =
  ## Keep what the shared panes show now, as their tab is left.
  ##
  ## The same fields `resetToInitial` clears, so a tab that is left and
  ## entered again gets back exactly what a reset would otherwise take away.
  result = SharedPaneSnapshot()
  if not tests.isNil:
    result.hasTestResults = true
    result.testCatalog = tests.catalog.val
    result.testSummary = tests.summary.val
    result.testRunAbsence = tests.runAbsence.val
    result.testProjectName = tests.projectName.val
    result.testRecordings = tests.recordings.val
  if not constraints.isNil:
    result.hasConstraints = true
    result.constraintsReport = constraints.report.val
    result.constraintsProjectName = constraints.projectName.val
  if not files.isNil:
    result.hasFilesystem = true
    result.expandedPaths = files.expandedPaths.val

proc restoreSharedPanes*(snapshot: SharedPaneSnapshot; tests: TestResultsVM;
                         constraints: ConstraintsVM; files: FilesystemVM) =
  ## Put back what `snapshot` kept, for every pane it has a part for and that
  ## exists now. The Files tree is the caller's to re-sync first; this puts
  ## back only its expanded folders.
  if snapshot.isNil:
    return
  if snapshot.hasTestResults and not tests.isNil:
    tests.catalog.val = snapshot.testCatalog
    tests.summary.val = snapshot.testSummary
    tests.runAbsence.val = snapshot.testRunAbsence
    tests.projectName.val = snapshot.testProjectName
    tests.recordings.val = snapshot.testRecordings
  if snapshot.hasConstraints and not constraints.isNil:
    constraints.report.val = snapshot.constraintsReport
    constraints.projectName.val = snapshot.constraintsProjectName
  if snapshot.hasFilesystem and not files.isNil:
    files.expandedPaths.val = snapshot.expandedPaths

proc resetSharedPanes*(tests: TestResultsVM; constraints: ConstraintsVM;
                       files: FilesystemVM) =
  ## Show what a freshly started window shows, for a tab that has never been
  ## shown. The session that tab becomes writes the panes itself if it has
  ## anything to say (edit mode answers `ns9-panes`; a loaded tree re-syncs
  ## Files); a replay does not, and keeps these values.
  if not tests.isNil:
    tests.resetToInitial()
  if not constraints.isNil:
    constraints.resetToInitial()
  if not files.isNil:
    files.resetToInitial()
