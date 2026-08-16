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
