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

proc findByClass*(node: MockNode; className: string): MockNode =
  let res = findAllByClass(node, className)
  if res.len > 0: res[0] else: nil

suite "VCS Component Commit Selection":
  test "test_vcs_component_lock: clicking different commits invokes callback with correct index":
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()
      let r = MockRenderer()

      vm.isGitRepo.val = true
      vm.currentBranch.val = "main"
      vm.commits.val = @[
        VCSCommitRow(hash: "abc1", message: "Commit 1", relativeTime: "1h ago"),
        VCSCommitRow(hash: "abc2", message: "Commit 2", relativeTime: "2h ago"),
        VCSCommitRow(hash: "abc3", message: "Commit 3", relativeTime: "3h ago"),
      ]
      vm.selectedCommitIndices.val = @[0]

      var selectedIndices: seq[int] = @[]
      let callbacks = VCSCallbacks(
        onToggleCommitExpand: proc(index: int; ctrl, shift: bool) =
          selectedIndices.add(index)
          vm.selectedCommitIndices.val = @[index]
      )

      let panel = renderVCSPanel(r, vm, callbacks)
      let headers = findAllByClass(panel, "vcs-commit-header")
      check headers.len == 3

      # Click on commit index 1
      headers[1].fireEvent("click")
      check selectedIndices.len > 0
      check selectedIndices[^1] == 1

      # Click on commit index 2
      headers[2].fireEvent("click")
      check selectedIndices.len > 1
      check selectedIndices[^1] == 2

      dispose()

  test "test_vcs_component_branch: selecting a branch updates branch state and dropdown status":
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()
      let r = MockRenderer()

      vm.isGitRepo.val = true
      vm.branches.val = @["main", "feature"]
      vm.currentBranch.val = "main"
      vm.branchDropdownOpen.val = true

      var checkedOut = ""
      let callbacks = VCSCallbacks(
        onCheckoutBranch: proc(branch: string) =
          checkedOut = branch
          vm.currentBranch.val = branch
          vm.branchDropdownOpen.val = false
      )

      let panel = renderVCSPanel(r, vm, callbacks)
      let dropdown = findByClass(panel, "vcs-branch-dropdown")
      check dropdown != nil

      let options = findAllByClass(dropdown, "vcs-branch-option")
      check options.len == 2

      # Click the "feature" branch option
      options[1].fireEvent("click")
      check checkedOut == "feature"
      check vm.currentBranch.val == "feature"
      check vm.branchDropdownOpen.val == false

      dispose()
