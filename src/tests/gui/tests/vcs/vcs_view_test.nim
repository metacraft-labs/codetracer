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

proc findAllByTag(node: MockNode; tag: string; acc: var seq[MockNode]) =
  if node.kind == mnkElement and node.tag == tag:
    acc.add(node)
  for child in node.children:
    findAllByTag(child, tag, acc)

proc findAllByTag(node: MockNode; tag: string): seq[MockNode] =
  result = @[]
  findAllByTag(node, tag, result)

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

# ---------------------------------------------------------------------------
# The trace-context selector and the review stats (DR-R2)
# ---------------------------------------------------------------------------
#
# DeepReview-GUI.md §2 assigns both to the VCS panel header:
#   "Trace context selector | The VCS panel header, populated only in
#    DeepReview mode"
#   "Session title / stats   | The VCS panel header"
# and §6 requires the selected context be changeable "without leaving the
# review, from the selector in the VCS panel header".  Until DR-R2 the control
# existed only in the standalone DeepReview panel (`isonim_deepreview_view`),
# and the VCS panel rendered no `select` element in any mode.

const TraceContexts = @[
  VCSTraceContextRow(id: 0, label: "latest passing run"),
  VCSTraceContextRow(id: 1, label: "previous run"),
]

proc populateReviewPanelWithContexts(vm: VCSVM) =
  populateReviewPanel(vm)
  vm.setHeader("Review: parser cleanup", statsText = "3 files +16 -10")
  vm.setTraceContexts(TraceContexts)
  vm.setSelectedTraceContextId(1)

suite "VCS panel — trace-context selector in the header (DR-R2)":

  test "test_vcs_panel_renders_trace_selector_in_review_mode":
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()
      let r = MockRenderer()
      let panel = renderVCSPanel(r, vm)

      populateReviewPanelWithContexts(vm)

      let selector = findByClass(panel, "vcs-review-trace-selector")
      check selector != nil
      let selects = findAllByTag(panel, "select")
      check selects.len == 1
      if selects.len == 1:
        let options = findAllByTag(selects[0], "option")
        check options.len == 2
        check options[0].textContent == "latest passing run"
        check options[1].textContent == "previous run"
        check options[0].attributes.getOrDefault("value", "") == "0"
        check options[1].attributes.getOrDefault("value", "") == "1"
        # The selected context is the one marked, and only that one: an
        # attribute that is merely present marks an option selected in a real
        # browser, so an empty `selected=""` on the others would select all.
        check not options[0].attributes.hasKey("selected")
        check options[1].attributes.getOrDefault("selected", "") == "selected"

      # It sits in the header, alongside the session title, not in the file
      # list (§2's "The VCS panel header").
      let header = findByClass(panel, "vcs-branch-picker")
      check header != nil
      if header != nil:
        check findByClass(header, "vcs-review-trace-selector") != nil
        check findByClass(header, "vcs-branch-name").textContent ==
          "Review: parser cleanup"

      dispose()

  test "a review with fewer than two contexts offers no selector":
    ## A dropdown whose only option is the current selection is not a choice.
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()
      let r = MockRenderer()
      let panel = renderVCSPanel(r, vm)

      populateReviewPanel(vm)
      vm.setTraceContexts(@[VCSTraceContextRow(id: 0, label: "only run")])

      check findByClass(panel, "vcs-review-trace-selector") == nil
      check findAllByTag(panel, "select").len == 0

      vm.setTraceContexts(TraceContexts)
      check findByClass(panel, "vcs-review-trace-selector") != nil

      dispose()

  test "test_vcs_trace_selector_change_updates_selection":
    ## The control has to *do* something.  The MockRenderer path exercises the
    ## view's VM-level fallback (no host callback registered); the host
    ## callback path is asserted below.
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()
      let r = MockRenderer()
      let panel = renderVCSPanel(r, vm)

      populateReviewPanelWithContexts(vm)
      check vm.selectedTraceContextId.val == 1

      let selects = findAllByTag(panel, "select")
      check selects.len == 1
      if selects.len == 1:
        r.setInputValue(selects[0], "0")
        selects[0].fireEvent("change")
        check vm.selectedTraceContextId.val == 0

        # ...and the re-render marks the newly chosen option.
        let options = findAllByTag(panel, "option")
        check options.len == 2
        check options[0].attributes.getOrDefault("selected", "") == "selected"
        check not options[1].attributes.hasKey("selected")

      dispose()

  test "the host callback receives the chosen context id":
    ## `onSetTraceContext` follows the `onToggleUnifiedDiff` pattern: when a
    ## host is wired the host decides, because switching context has effects
    ## outside this panel (the review's decorations).
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()
      let r = MockRenderer()
      var reported = -1
      let callbacks = VCSCallbacks(
        onSetTraceContext: proc(id: int) = (reported = id))
      let panel = renderVCSPanel(r, vm, callbacks)

      populateReviewPanelWithContexts(vm)

      let selects = findAllByTag(panel, "select")
      check selects.len == 1
      if selects.len == 1:
        r.setInputValue(selects[0], "0")
        selects[0].fireEvent("change")

      check reported == 0
      # The host owns the write-back; the view must not have guessed it.
      check vm.selectedTraceContextId.val == 1

      dispose()

  test "the review stats render in the header":
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()
      let r = MockRenderer()
      let panel = renderVCSPanel(r, vm)

      populateReviewPanelWithContexts(vm)

      let stats = findByClass(panel, "vcs-review-stats")
      check stats != nil
      if stats != nil:
        check stats.textContent == "3 files +16 -10"

      # A review with no stats to report renders no empty row.
      vm.setHeader("Review: parser cleanup")
      check findByClass(panel, "vcs-review-stats") == nil

      dispose()

  test "a normal git session shows neither the selector nor the stats":
    ## The regression guard for the shared header: DR-R2 adds two elements to
    ## a header both modes render, and VCS-Panel.md's "Normal Development
    ## Mode" has neither recordings nor a fixed changeset.  Neither element
    ## may appear — or take space — in a live working-tree session.
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()
      let r = MockRenderer()
      let panel = renderVCSPanel(r, vm)

      vm.setGitRepoState(true)
      vm.setHeader("main")
      vm.setCommits(@[
        VCSCommitRow(hash: "abc123", message: "initial", relativeTime: "1h"),
      ], selectedIndices = @[])
      # Even with review state left over from a previous session on this VM.
      vm.setTraceContexts(TraceContexts)

      check findByClass(panel, "vcs-review-trace-selector") == nil
      check findByClass(panel, "vcs-review-stats") == nil
      check findAllByTag(panel, "select").len == 0
      check findByClass(panel, "vcs-commit-history") != nil

      dispose()
