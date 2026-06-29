import std/[unittest, strutils, tables]

import isonim/core/signals
import isonim/core/owner
import isonim/testing/mock_dom

import ../../viewmodels/vcs_vm
import ../../views/isonim_vcs_view

proc findAllByClass*(node: MockNode; className: string; result: var seq[MockNode]) =
  if node.kind == mnkElement and className in node.attributes.getOrDefault("class", ""):
    result.add(node)
  for child in node.children:
    findAllByClass(child, className, result)

proc findAllByClass*(node: MockNode; className: string): seq[MockNode] =
  result = @[]
  findAllByClass(node, className, result)

suite "VCS Component Commit Selection":
  test "test_vcs_component_lock: clicking different commits invokes callback with correct index":
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()
      let r = MockRenderer()

      vm.isGitRepo.val = true
      vm.commits.val = @[
        VCSCommitRow(hash: "abc1", message: "Commit 1", relativeTime: "1h ago"),
        VCSCommitRow(hash: "abc2", message: "Commit 2", relativeTime: "2h ago"),
        VCSCommitRow(hash: "abc3", message: "Commit 3", relativeTime: "3h ago"),
      ]
      vm.selectedCommitIndex.val = 0

      var selectedIndices: seq[int] = @[]
      let callbacks = VCSCallbacks(
        onSelectCommit: proc(index: int) =
          selectedIndices.add(index)
          vm.selectedCommitIndex.val = index
      )

      let panel = renderVCSPanel(r, vm, callbacks)
      let rows = findAllByClass(panel, "vcs-commit-item")
      check rows.len == 3

      # Click on commit index 1
      rows[1].fireEvent("click")
      check selectedIndices.len > 0
      check selectedIndices[^1] == 1

      # Click on commit index 2
      rows[2].fireEvent("click")
      check selectedIndices.len > 1
      check selectedIndices[^1] == 2

      dispose()
