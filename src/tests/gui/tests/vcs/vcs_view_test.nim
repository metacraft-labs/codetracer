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
import views/isonim_unified_diff_view

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
      let panel = renderVCSPanel[MockRenderer, MockNode](r, vm)

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
      let panel = renderVCSPanel[MockRenderer, MockNode](r, vm)

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
      let panel = renderVCSPanel[MockRenderer, MockNode](r, vm)

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
      let panel = renderVCSPanel[MockRenderer, MockNode](r, vm)

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
      let panel = renderVCSPanel[MockRenderer, MockNode](r, vm)

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
      let panel = renderVCSPanel[MockRenderer, MockNode](r, vm)

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
      let panel = renderVCSPanel[MockRenderer, MockNode](r, vm, callbacks)

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
      let panel = renderVCSPanel[MockRenderer, MockNode](r, vm)

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
    ## Regression guard for the panel's header region.  `renderHeader` is
    ## reached only from the review branch of `renderVCSPanel` — the normal
    ## branch renders `renderBranchPicker` instead — so DR-R2's two elements
    ## cannot leak into a git session today.  The guard is against a future
    ## refactor that unifies the two headers: VCS-Panel.md's "Normal
    ## Development Mode" watches a live working tree, with no recordings to
    ## choose between and no fixed changeset to summarise, so neither element
    ## may appear — or take space — there.
    ##
    ## This test therefore passes before DR-R2 as well as after.  It is a
    ## guard, not evidence that the feature works.
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()
      let r = MockRenderer()
      let panel = renderVCSPanel[MockRenderer, MockNode](r, vm)

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

# ---------------------------------------------------------------------------
# The reviewed commit in the Changed Files header (DR-R8)
# ---------------------------------------------------------------------------
#
# DeepReview-GUI.md §3: "The section header shows the review's file count and,
# when the changeset came from local git history, the commit it belongs to."
#
# This is the one review header fact DR-R2 did not migrate.  It existed only
# in the standalone panel's own header (`ui/deepreview.nim` built it as
# `commitSha[0 ..< 12] & "..."` and `isonim_deepreview_view` rendered it into
# `.deepreview-commit`), so DR-R8 had to move it rather than delete it with
# the panel.  Falsifiable against the code as it stood before DR-R8: the VCS
# panel had no `reviewCommit` state at all and `changedFilesHeaderText`
# rendered only the file count in review mode.

suite "VCS panel — the reviewed commit in the Changed Files header (DR-R8)":

  test "test_vcs_changed_files_header_names_the_reviewed_commit":
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()
      let r = MockRenderer()
      let panel = renderVCSPanel[MockRenderer, MockNode](r, vm)

      populateReviewPanel(vm)
      vm.setHeader("Review: parser cleanup", statsText = "2 files +16 -3",
                   reviewCommit = "a1b2c3d4e5f6...")

      let header = findByClass(panel, "vcs-changed-files-commit")
      check header != nil
      if header != nil:
        # Both facts §3 names, in one header: how many files and which commit.
        check header.textContent == " (2 files, a1b2c3d4e5f6...)"

      dispose()

  test "a review that names no commit shows only the file count":
    ## §3 conditions the commit on the changeset coming from local git
    ## history; a standalone patch has none, and inventing one — or rendering
    ## an empty pair of parentheses — would be worse than omitting it.
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()
      let r = MockRenderer()
      let panel = renderVCSPanel[MockRenderer, MockNode](r, vm)

      populateReviewPanel(vm)
      vm.setHeader("Review: parser cleanup", statsText = "2 files +16 -3")

      check findByClass(panel, "vcs-changed-files-commit").textContent ==
        " (2 files)"

      dispose()

  test "a normal git session renders no Changed Files header at all":
    ## Regression guard: `reviewCommit` is review state, and a live working
    ## tree has no reviewed commit.  The normal branch of
    ## `renderVCSPanel` renders the commit graph rather than the review's
    ## Changed Files section, so the header carrying it must be absent — even
    ## with review state left over from a previous session on this VM.
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()
      let r = MockRenderer()
      let panel = renderVCSPanel[MockRenderer, MockNode](r, vm)

      vm.setGitRepoState(true)
      vm.setHeader("main", reviewCommit = "deadbeefcafe...")
      vm.setCommits(@[
        VCSCommitRow(hash: "abc123", message: "initial", relativeTime: "1h"),
      ], selectedIndices = @[0])

      check findByClass(panel, "vcs-changed-files-commit") == nil
      check findByClass(panel, "vcs-commit-history") != nil

      dispose()

  test "clearPanel drops the reviewed commit with the rest of the review":
    ## A panel can move out of review mode (VCS-Panel.md, "Data Sources and
    ## Instantiation Modes"), and a stale commit would then describe a
    ## changeset that is no longer on screen.
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()

      vm.setDeepReviewMode(true)
      vm.setHeader("Review: parser cleanup", statsText = "2 files",
                   reviewCommit = "a1b2c3d4e5f6...")
      check vm.reviewCommit.val == "a1b2c3d4e5f6..."

      vm.clearPanel()
      check vm.reviewCommit.val == ""

      # …and an ordinary `setHeader` clears it too, because its default is
      # empty: a working-tree session must not inherit it.
      vm.setDeepReviewMode(true)
      vm.setHeader("Review: parser cleanup", reviewCommit = "a1b2c3d4e5f6...")
      vm.setHeader("main")
      check vm.reviewCommit.val == ""

# ---------------------------------------------------------------------------
# #753 — every diff target the VCS panel mints names exactly one file
# ---------------------------------------------------------------------------

proc namesExactlyOneFile(target: string): bool =
  ## Whether a unified-diff target addresses a single file.
  ##
  ## DeepReview-GUI.md §4.1: "Each diff tab shows a single file.  Cross-file
  ## navigation is the Changed Files list (§3); a review does not concatenate
  ## every file into one scrolling document."  Only two of the shapes
  ## `unified_diff.loadFromGit` accepts satisfy that — `file:<path>` and
  ## `commit:<hash>:<path>`.  The pathless ones (`commit:<hash>`, and the
  ## empty / "Working Tree" target) fan out to every file git reports, which is
  ## the concatenated document #753 reported.
  if target.startsWith("file:"):
    return target.len > "file:".len
  if target.startsWith("commit:"):
    let commitPart = target["commit:".len .. ^1]
    let colonIdx = commitPart.find(':')
    return colonIdx >= 0 and colonIdx + 1 < commitPart.len
  false

suite "VCS panel — diff targets name one file (#753)":

  test "test_vcs_panel_commit_routes":
    ## The routes of the owner's 2026-10-23 decision on #753 (VCS-Panel.md,
    ## "Commit History", "Changed Files"): a commit row's header opens the
    ## commit's whole-commit document, `commit:<hash>`; its expand control only
    ## expands; a file under it targets that document with the file's path, so
    ## the host scrolls to it; and the per-file "View Diff" buttons still open
    ## one file each.
    ##
    ## Until that decision this case asserted the opposite — that no route
    ## minted the pathless `commit:<hash>`. The per-file half of it is kept:
    ## every `-diff-btn` affordance the panel renders is fired, and each must
    ## name exactly one file, so a new button that opens a whole commit has to
    ## be the header's job, not a button's.
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()
      let r = MockRenderer()
      var targets: seq[string] = @[]
      var opened: seq[(int, string)] = @[]
      var toggled: seq[(int, bool, bool)] = @[]
      var selected: seq[(string, string)] = @[]
      let callbacks = VCSCallbacks(
        onOpenFileDiff: proc(target: string) = targets.add(target),
        onOpenCommit: proc(index: int; target: string) =
          opened.add((index, target)),
        onToggleCommitExpand: proc(index: int; ctrl, shift: bool) =
          toggled.add((index, ctrl, shift)),
        onSelectFile: proc(index: int; path, target, status: string) =
          selected.add((path, target)),
      )
      let panel = renderVCSPanel[MockRenderer, MockNode](r, vm, callbacks)

      vm.setGitRepoState(true)
      vm.setHeader("main")
      vm.setBranchState("main", @["main"], false)
      vm.setCommits(@[
        VCSCommitRow(hash: "abc123", message: "touch several files",
                     relativeTime: "1h"),
      ], selectedIndices = @[0])
      vm.setCommitFiles(0, @[
        VCSFileRow(status: "M", path: "src/main.nim", baseName: "main.nim",
                   additions: 2, deletions: 1),
        VCSFileRow(status: "A", path: "scripts/build.sh", baseName: "build.sh",
                   additions: 19, deletions: 0),
      ])

      # The per-file buttons: each names one file.
      var buttons: seq[MockNode] = @[]
      findAllByClass(panel, "diff-btn", buttons)
      check buttons.len == 2
      for button in buttons:
        button.fireEvent("click")
      check targets == @["commit:abc123:src/main.nim",
                         "commit:abc123:scripts/build.sh"]
      for target in targets:
        checkpoint("diff target: " & target)
        check namesExactlyOneFile(target)
      # The hover button that opened the whole commit is gone: the header
      # does it now.
      check findByClass(panel, "vcs-commit-diff-btn") == nil

      # The header opens the whole commit.
      findByClass(panel, "vcs-commit-header-selected").fireEvent("click")
      check opened == @[(0, "commit:abc123")]
      check toggled.len == 0

      # The expand control only toggles the expansion, as a Ctrl-click would.
      findByClass(panel, "vcs-commit-toggle").fireEvent("click")
      check toggled == @[(0, true, false)]
      check opened.len == 1

      # A file under the commit targets the commit's document, with its path.
      var candidates: seq[MockNode] = @[]
      findAllByClass(panel, "vcs-accordion-file", candidates)
      # This file's lookup matches class substrings; keep the rows themselves.
      var rows: seq[MockNode] = @[]
      for node in candidates:
        if node.attributes.getOrDefault("class") == "vcs-accordion-file":
          rows.add(node)
      check rows.len == 2
      rows[1].fireEvent("click")
      check selected == @[("scripts/build.sh", "commit:abc123")]

      dispose()

proc diffFile(index: int; path, status: string): VCSDiffFileRow =
  ## One changed file with one modified line, the shape `diffRows` hands a
  ## diff tab's ViewModel.
  VCSDiffFileRow(
    fileIndex: index, status: status, path: path, additions: 1, deletions: 1,
    hunks: @[VCSHunkRow(oldStart: 1, oldCount: 1, newStart: 1, newCount: 1,
      lines: @[
        VCSDiffLineRow(lineType: "removed", content: "old", oldLine: 1),
        VCSDiffLineRow(lineType: "added", content: "new", newLine: 1)])])

suite "unified diff — headings and the whole-commit document (#753)":
  ## VCS-Panel.md, "Unified Diff View (Editor Integration)" and "Whole-Commit
  ## Document": the owner's 2026-10-23 decision.

  test "the heading's file name opens the full file":
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()
      vm.setUnifiedDiff(true, @[diffFile(0, "src/main.nim", "M")])
      var opened: seq[string] = @[]
      let tab = renderUnifiedDiffTab[MockRenderer, MockNode](
        MockRenderer(), vm, "unifiedDiffEditor-1",
        UnifiedDiffCallbacks(onOpenFullFile: proc(path: string) =
          opened.add(path)))
      let link = findByClass(tab, "unified-diff-file-header-link")
      check link != nil
      check link.textContent == "src/main.nim"
      link.fireEvent("click")
      check opened == @["src/main.nim"]
      dispose()

  test "a deleted file's heading opens nothing":
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()
      vm.setUnifiedDiff(true, @[diffFile(0, "src/gone.nim", "D")])
      var opened: seq[string] = @[]
      let tab = renderUnifiedDiffTab[MockRenderer, MockNode](
        MockRenderer(), vm, "unifiedDiffEditor-1",
        UnifiedDiffCallbacks(onOpenFullFile: proc(path: string) =
          opened.add(path)))
      # The positive control above finds the link; here there is none.
      check findByClass(tab, "unified-diff-file-header-link") == nil
      let path = findByClass(tab, "unified-diff-file-header-path")
      check path != nil
      path.fireEvent("click")
      check opened.len == 0
      dispose()

  test "a document has one section per file, in order, each its file's diff":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let document = createVCSVM()
      let files = @[diffFile(0, "src/main.nim", "M"),
                    diffFile(1, "lib/util.nim", "A")]
      document.setUnifiedDiff(true, files)
      check document.isDiffDocument()
      var filled: seq[(int, string)] = @[]
      let root = renderUnifiedDiffDocument[MockRenderer, MockNode](r, document,
        proc(index: int; path: string; host: MockNode) =
          filled.add((index, path))
          # What the browser host does: the file's own single-file tab.
          let sectionVM = createVCSVM()
          sectionVM.setUnifiedDiff(true, @[files[index]])
          r.appendChild(host, renderUnifiedDiffTab[MockRenderer, MockNode](
            r, sectionVM, "unifiedDiffEditor-section-" & $index)))
      check filled == @[(0, "src/main.nim"), (1, "lib/util.nim")]
      # This file's lookup matches class substrings, which also finds the
      # sections' container; the sections are the nodes carrying a path.
      var sections: seq[MockNode] = @[]
      for node in findAllByClass(root, "unified-diff-document-section"):
        if node.attributes.hasKey("data-path"):
          sections.add(node)
      check sections.len == 2
      check sections[0].attributes["data-path"] == "src/main.nim"
      check sections[1].attributes["data-path"] == "lib/util.nim"
      # Each section's heading is its own file's, and each has an editor.
      check findByClass(sections[0], "unified-diff-file-header-path")
        .textContent == "src/main.nim"
      check findByClass(sections[1], "unified-diff-file-header-path")
        .textContent == "lib/util.nim"
      check findAllByClass(root, "unified-diff-editor").len == 2
      dispose()

  test "a scroll request reaches the document":
    createRoot proc(dispose: proc()) =
      let r = MockRenderer()
      let document = createVCSVM()
      document.setUnifiedDiff(true, @[diffFile(0, "a.nim", "M"),
                                      diffFile(1, "b.nim", "M")])
      let root = renderUnifiedDiffDocument[MockRenderer, MockNode](r, document,
        proc(index: int; path: string; host: MockNode) = discard)
      check root.attributes["data-scrolled-to"] == ""
      document.requestDocumentScroll("b.nim")
      check root.attributes["data-scrolled-to"] == "b.nim"
      dispose()
