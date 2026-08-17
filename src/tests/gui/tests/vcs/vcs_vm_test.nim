## Unit tests for ``VCSVM`` and for the layout-routing rule that decides where
## a VCS "View Diff" tab is opened.

import std/unittest

import isonim/core/[signals, computation, owner]
import viewmodels/vcs_vm
import ../../../../common/types as ct_types

suite "openLayoutTab routing":
  ## `openLayoutTab` itself drives GoldenTayout through the DOM and cannot be
  ## exercised headlessly, so the decision it turns on lives in
  ## `opensAsIndependentTab` (common_types/codetracer_features/frontend.nim),
  ## which compiles on both backends.
  ##
  ## Regression cover for #561 / #611: the VCS panel's "View Diff" opens a
  ## panel with `isEditor = true`, and that request used to be swallowed by the
  ## singleton rule — the already-active docked VCS panel was re-focused and
  ## the call returned, so the button did nothing at all.

  test "a VCS panel requested as an editor tab is independent":
    check opensAsIndependentTab(ct_types.Content.VCS, isEditor = true)

  test "the docked VCS panel stays a singleton":
    check not opensAsIndependentTab(ct_types.Content.VCS, isEditor = false)

  test "ordinary sidebar panels stay singletons":
    check not opensAsIndependentTab(ct_types.Content.Filesystem, isEditor = false)

  test "editor views keep their own reuse path":
    # EditorView tabs are reused through `data.ui.editors`, which also carries
    # tab history and source loading; they must not take the generic branch.
    check not opensAsIndependentTab(ct_types.Content.EditorView, isEditor = true)

suite "VCSVM":

  test "defaults reflect an unloaded non-repo panel":
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()

      check not vm.deepReviewMode.val
      check not vm.isGitRepo.val
      check vm.errorMessage.val == ""
      check vm.currentBranch.val == ""
      check vm.branches.val.len == 0
      check vm.commits.val.len == 0
      check vm.selectedCommitIndices.val.len == 0
      check vm.fileCount.val == 0
      check not vm.unifiedDiffActive.val
      check vm.selectedHunkCount.val == 0
      # VCS-Panel.md's `vcs.defaultView: "unified-diff"`.
      check vm.viewMode.val == vmUnifiedDiff

      dispose()

  test "the view mode never turns the panel into a diff":
    ## #561: toggling "Unified Diff" must change what a file click does, not
    ## replace the commit history with a diff.  `unifiedDiffActive` is the
    ## separate flag that means "this panel instance IS a diff".
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()

      vm.setViewMode(vmOpenFile)
      check vm.viewMode.val == vmOpenFile
      check not vm.unifiedDiffActive.val

      vm.setViewMode(vmUnifiedDiff)
      check vm.viewMode.val == vmUnifiedDiff
      check not vm.unifiedDiffActive.val

      dispose()

  test "commit selection clamps and file count derives from rows":
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()

      vm.setCommits(@[
        VCSCommitRow(hash: "abc123", message: "first", relativeTime: "1h"),
        VCSCommitRow(hash: "def456", message: "second", relativeTime: "2h"),
      ], selectedIndices = @[0, 9])
      vm.setChangedFiles(@[
        VCSFileRow(status: "M", path: "src/a.nim", baseName: "a.nim"),
        VCSFileRow(status: "A", path: "src/b.nim", baseName: "b.nim"),
      ])

      check vm.selectedCommitIndices.val == @[0]
      check vm.fileCount.val == 2

      vm.setCommits(@[], selectedIndices = @[0])
      check vm.selectedCommitIndices.val.len == 0

      dispose()

suite "VCSVM open-action resolver (DR-R1)":
  ## The single decision point for "what does clicking a changed file do".
  ##
  ## It lives in the ViewModel rather than in ``ui/vcs.nim`` because the
  ## imperative component is JS-only and unreachable without a browser: the
  ## DeepReview early-return that made clicking a review file do nothing at all
  ## could not be observed by any headless test while the decision lived there.
  ##
  ## Spec: DeepReview-GUI.md §3 ("Clicking a file opens it in the editor, in
  ## the representation the view mode toggle currently selects ... Clicking
  ## must not merely change a selection index") and VCS-Panel.md, "View mode
  ## toggle".

  proc reviewVM(): VCSVM =
    ## A review panel with the three-file changeset of
    ## ``src/tests/gui/tests/deepreview/fixtures/sample-review.json``:
    ## a modified file, an added file and a deleted file.
    result = createVCSVM()
    result.setDeepReviewMode(true)
    result.setChangedFiles(@[
      VCSFileRow(status: "M", path: "src/main.rs", baseName: "main.rs",
                 additions: 8, deletions: 3, selected: true),
      VCSFileRow(status: "A", path: "src/utils.rs", baseName: "utils.rs",
                 additions: 8, deletions: 0),
      VCSFileRow(status: "D", path: "src/config.rs", baseName: "config.rs",
                 additions: 0, deletions: 7),
    ])

  test "test_vcs_open_action_in_review_mode_opens_diff_tab":
    ## §3: a click in review mode opens the file's review representation.
    ## Before DR-R1 the review branch produced no action at all.
    createRoot proc(dispose: proc()) =
      let vm = reviewVM()

      check vm.viewMode.val == vmUnifiedDiff
      let action = vm.openActionForRow(1)

      check action.kind == voaDiffTab
      check action.index == 1
      check action.path == "src/utils.rs"
      check action.target == "file:src/utils.rs"
      # Review mode is not a special case of the decision: the same inputs in
      # normal git mode resolve the same way.
      vm.setDeepReviewMode(false)
      check vm.openActionForRow(1).kind == voaDiffTab

      dispose()

  test "test_vcs_open_action_follows_view_mode_in_review_mode":
    ## VCS-Panel.md, "View mode toggle": Unified Diff opens the diff, Open File
    ## opens the file itself.  Review mode ignored ``viewMode`` entirely before
    ## DR-R1.
    createRoot proc(dispose: proc()) =
      let vm = reviewVM()

      vm.setViewMode(vmOpenFile)
      let opened = vm.openActionForRow(1)
      check opened.kind == voaSourceFile
      check opened.path == "src/utils.rs"
      check opened.target == "file:src/utils.rs"

      vm.setViewMode(vmUnifiedDiff)
      check vm.openActionForRow(1).kind == voaDiffTab

      dispose()

  test "test_vcs_open_action_for_deleted_file":
    ## DR-R1's decision for the case the specs are silent on: a file with
    ## status ``D`` has no content in the new tree, so clicking it always opens
    ## the diff tab showing the removal — never an "open file" for a path that
    ## no longer exists.
    createRoot proc(dispose: proc()) =
      let vm = reviewVM()

      for mode in [vmUnifiedDiff, vmOpenFile]:
        vm.setViewMode(mode)
        let action = vm.openActionForRow(2)
        check action.kind == voaDiffTab
        check action.path == "src/config.rs"
        check action.target == "file:src/config.rs"
        check action.status == "D"

      # Same rule in normal git mode: a deleted file in a commit's file list
      # is just as absent from the working tree.
      vm.setDeepReviewMode(false)
      vm.setViewMode(vmOpenFile)
      check vm.openActionFor(0, "src/gone.rs", "commit:abc123:src/gone.rs",
                             "deleted").kind == voaDiffTab

      dispose()

  test "an out-of-range row or an empty path resolves to no action":
    ## Defensive: the resolver is the only decision point, so it must return a
    ## well-defined "nothing to open" rather than let a caller dispatch on
    ## garbage.
    createRoot proc(dispose: proc()) =
      let vm = reviewVM()

      check vm.openActionForRow(-1).kind == voaNone
      check vm.openActionForRow(3).kind == voaNone
      check vm.openActionFor(0, "", "", "M").kind == voaNone

      dispose()

suite "VCSVM":

  test "hunk state drives toolbar and copy feedback":
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()

      vm.setHunkState(@[(0, 1), (2, 0)], toolbarVisible = true,
                      copyFeedback = true)

      check vm.selectedHunkCount.val == 2
      check vm.hunkToolbarVisible.val
      check vm.hunkCopyFeedback.val

      vm.clearPanel()
      check vm.selectedHunkCount.val == 0
      check not vm.hunkToolbarVisible.val
      check not vm.hunkCopyFeedback.val

      dispose()
