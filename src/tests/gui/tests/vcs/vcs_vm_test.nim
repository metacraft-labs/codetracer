## Unit tests for ``VCSVM``.

import std/unittest

import isonim/core/[signals, computation, owner]
import viewmodels/vcs_vm

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
      check vm.selectedCommitIndex.val == -1
      check vm.fileCount.val == 0
      check not vm.unifiedDiffActive.val
      check vm.selectedHunkCount.val == 0

      dispose()

  test "commit selection clamps and file count derives from rows":
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()

      vm.setCommits(@[
        VCSCommitRow(hash: "abc123", message: "first", relativeTime: "1h"),
        VCSCommitRow(hash: "def456", message: "second", relativeTime: "2h"),
      ], selectedIndex = 9)
      vm.setChangedFiles(@[
        VCSFileRow(status: "M", path: "src/a.nim", baseName: "a.nim"),
        VCSFileRow(status: "A", path: "src/b.nim", baseName: "b.nim"),
      ])

      check vm.selectedCommitIndex.val == 1
      check vm.fileCount.val == 2

      vm.setCommits(@[], selectedIndex = 0)
      check vm.selectedCommitIndex.val == -1

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
