## View-level tests for the VCS panel's DeepReview (review-mode) branch.
##
## These render the real IsoNim VCS view through ``MockRenderer``, so they are
## Layer 5c/6 headless tests: no browser, no GoldenLayout, no Electron.
##
## Why a separate file from ``src/tests/gui/tests/views/isonim_views_test.nim``:
## that file covers the panel's *normal git* branches, and this campaign
## (DeepReview-GUI.milestones.org, DR-R1..DR-R8) keeps growing the review-mode
## branch.  Keeping the review-mode view assertions together makes the campaign
## reviewable; both files are reached by ``just test-vm`` (which globs
## ``src/tests/gui/tests/**/*_test.nim``) and this one is registered in
## ``CoreViewModelGateTests`` (``src/ct_test/release_gate.nim``).
##
## Spec: codetracer-specs/GUI/Core-Panes/VCS-Panel.md, "View mode toggle" and
## "DeepReview Mode"; codetracer-specs/DeepReview/DeepReview-GUI.md §1, §3.

import std/[strutils, tables, unittest]

import isonim/core/[signals, computation, owner]
import isonim/testing/mock_dom
import viewmodels/vcs_vm
import views/isonim_vcs_view

proc findByClass(node: MockNode; className: string): MockNode =
  if node.kind == mnkElement and
      className in node.attributes.getOrDefault("class", ""):
    return node
  for child in node.children:
    let found = findByClass(child, className)
    if found != nil:
      return found
  nil

proc findAllByClass(node: MockNode; className: string;
                    acc: var seq[MockNode]) =
  if node.kind == mnkElement and
      className in node.attributes.getOrDefault("class", ""):
    acc.add(node)
  for child in node.children:
    findAllByClass(child, className, acc)

proc findAllByClass(node: MockNode; className: string): seq[MockNode] =
  result = @[]
  findAllByClass(node, className, result)

proc containsText(node: MockNode; needle: string): bool =
  ## Whole-subtree text search.  ``textContent`` on the panel root is the
  ## concatenation of every descendant's text, which is exactly what the
  ## "the Refresh affordance must be gone" assertion needs.
  needle in node.textContent

proc populateReviewPanel(vm: VCSVM) =
  ## Minimum state for a VCS panel showing a review changeset.
  vm.setDeepReviewMode(true)
  vm.setHeader("Review: parser cleanup")
  vm.setChangedFiles(@[
    VCSFileRow(status: "M", path: "src/main.rs", baseName: "main.rs",
               additions: 8, deletions: 3, coverageText: "5/8", selected: true),
    VCSFileRow(status: "A", path: "src/utils.rs", baseName: "utils.rs",
               additions: 8, deletions: 0, coverageText: "8/8"),
  ])

suite "VCS panel — review mode view (DR-R1)":

  test "test_vcs_panel_renders_view_mode_toggle_in_review_mode":
    ## VCS-Panel.md, "View mode toggle": "A switch at the top-right of the
    ## Changed Files section controls what happens when a file is clicked".
    ## DeepReview-GUI.md §1 promises the reviewer both representations, so the
    ## switch must be reachable in review mode — the review-mode render branch
    ## used to draw only the header and the file list.
    ##
    ## VCS-Panel.md, "DeepReview Mode": "File watching: Disabled — the
    ## changeset is immutable", so the Refresh affordance that shares the
    ## toggle row must not be offered.
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()
      let r = MockRenderer()
      let panel = renderVCSPanel(r, vm)

      populateReviewPanel(vm)

      let toggle = findByClass(panel, "vcs-diff-toggle")
      check toggle != nil
      if toggle != nil:
        check containsText(toggle, "Unified Diff")
        # Unified Diff is the spec default (`vcs.defaultView: "unified-diff"`),
        # so the switch comes up active.
        check findByClass(toggle, "vcs-toggle-button").attributes
          .getOrDefault("class", "") == "vcs-toggle-button vcs-toggle-active"

      # The changed-files list is still there: the toggle is added to the
      # review branch, it does not replace it.
      check findByClass(panel, "vcs-changed-files") != nil
      check findAllByClass(panel, "vcs-file-item").len == 2

      # Read-only changeset: no Refresh.
      check findByClass(panel, "vcs-refresh") == nil
      check not containsText(panel, "Refresh")

      dispose()

  test "the toggle still carries Refresh in normal git mode":
    ## The suppression above must be scoped to review mode: a live working
    ## tree is refreshable, and VCS-Panel.md keeps the auto-refresh behaviour
    ## for normal development mode.
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()
      let r = MockRenderer()
      let panel = renderVCSPanel(r, vm)

      vm.setGitRepoState(true)
      vm.setHeader("main")
      vm.setCommits(@[
        VCSCommitRow(hash: "abc123", message: "initial", relativeTime: "1h"),
      ], selectedIndices = @[])

      let toggle = findByClass(panel, "vcs-diff-toggle")
      check toggle != nil
      if toggle != nil:
        check findByClass(toggle, "vcs-refresh") != nil

      dispose()

  test "toggling the switch in review mode moves the view mode":
    ## The switch has to *do* something: DR-R1 makes `VCSVM.viewMode` the
    ## single input the click resolver reads, in review mode as well as in
    ## normal git mode.  The MockRenderer path exercises the view's VM-level
    ## fallback (no host callback registered).
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()
      let r = MockRenderer()
      let panel = renderVCSPanel(r, vm)

      populateReviewPanel(vm)
      check vm.viewMode.val == vmUnifiedDiff

      let button = findByClass(panel, "vcs-toggle-button")
      check button != nil
      if button != nil:
        button.fireEvent("click")
        check vm.viewMode.val == vmOpenFile
        # The panel is still the changed-files list — the toggle changes what
        # a click *opens*, never what the panel renders (issue #561).
        check findByClass(panel, "vcs-changed-files") != nil
        check findByClass(panel, "deepreview-unified-diff") == nil

      dispose()
