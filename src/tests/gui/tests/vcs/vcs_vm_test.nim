## Unit tests for ``VCSVM`` and for the layout-routing rule that decides where
## a VCS "View Diff" tab is opened.

import std/[strutils, unittest]

import isonim/core/[signals, computation, owner]
import viewmodels/vcs_vm
import viewmodels/context_expansion
import viewmodels/diff_document
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

suite "VCSVM trace contexts and review stats (DR-R2)":
  ## DeepReview-GUI.md §2 assigns the trace-context selector and the review's
  ## session title/stats to the VCS panel header, and §6 requires that "the
  ## selected trace context can be changed without leaving the review, from
  ## the selector in the VCS panel header".  Before DR-R2 `VCSVM` carried no
  ## trace-context state at all — the control existed only inside the
  ## standalone DeepReview panel DR-R8 deletes.

  proc reviewContexts(): seq[VCSTraceContextRow] =
    ## The two contexts of
    ## `src/tests/gui/tests/deepreview/fixtures/sample-review.json`.
    @[
      VCSTraceContextRow(id: 0, label: "latest passing run"),
      VCSTraceContextRow(id: 1, label: "previous run"),
    ]

  test "test_vcs_vm_holds_trace_contexts_and_selection":
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()
      vm.setDeepReviewMode(true)

      # A panel that has never seen a review offers no choice.
      check vm.traceContexts.val.len == 0
      check not vm.hasTraceContextChoice()

      vm.setTraceContexts(reviewContexts())
      vm.setSelectedTraceContextId(1)

      check vm.traceContexts.val.len == 2
      check vm.traceContexts.val[0].label == "latest passing run"
      check vm.traceContexts.val[1] == VCSTraceContextRow(
        id: 1, label: "previous run")
      check vm.selectedTraceContextId.val == 1
      check vm.hasTraceContextChoice()

      vm.clearPanel()
      check vm.traceContexts.val.len == 0
      check vm.selectedTraceContextId.val == 0
      check not vm.hasTraceContextChoice()

      dispose()

  test "the selector is a review-only control":
    ## VCS-Panel.md, "Normal Development Mode": the panel then watches a live
    ## working tree, which has no recordings behind it.  The header must not
    ## offer a trace context there even if one was left over from a review.
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()
      vm.setTraceContexts(reviewContexts())

      check not vm.deepReviewMode.val
      check not vm.hasTraceContextChoice()

      vm.setDeepReviewMode(true)
      check vm.hasTraceContextChoice()

      # A review that declares a single context has nothing to choose
      # between; the dropdown would offer only the current selection.
      vm.setTraceContexts(@[VCSTraceContextRow(id: 0, label: "only run")])
      check not vm.hasTraceContextChoice()

      dispose()

  test "the selected context falls back to the review's first":
    ## `DeepReviewTraceContext`: "The first entry is selected by default."  A
    ## stored selection that no longer names a declared context (a different
    ## review was loaded, or nothing has been chosen yet) must not leave the
    ## dropdown showing nothing as selected.
    let contexts = reviewContexts()
    check resolveTraceContextId(contexts, 1) == 1
    check resolveTraceContextId(contexts, 0) == 0
    check resolveTraceContextId(contexts, 99) == 0
    check resolveTraceContextId(
      @[VCSTraceContextRow(id: 7, label: "seven")], 0) == 7
    check resolveTraceContextId(@[], 3) == 0

  test "the review stats summarise the changeset the panel shows":
    ## DeepReview-GUI.md §2, "Session title / stats → The VCS panel header".
    ## Only what the review dataset carries is summarised — file count and
    ## the changeset's total +/-.  `DeepReviewData` has no test-results
    ## field, so no test stat is reported rather than a plausible zero.
    let rows = @[
      VCSFileRow(status: "M", path: "src/main.rs", baseName: "main.rs",
                 additions: 8, deletions: 3),
      VCSFileRow(status: "A", path: "src/utils.rs", baseName: "utils.rs",
                 additions: 8, deletions: 0),
      VCSFileRow(status: "D", path: "src/config.rs", baseName: "config.rs",
                 additions: 0, deletions: 7),
    ]
    check reviewStatsText(rows) == "3 files +16 -10"
    check reviewStatsText(rows[0 .. 0]) == "1 file +8 -3"
    # A changeset with no line counts still reports its size.
    check reviewStatsText(@[VCSFileRow(status: "M", path: "a")]) == "1 file"
    # An empty review has nothing to say, and says nothing.
    check reviewStatsText([]) == ""

  test "the header setter carries the stats and clears them by default":
    ## Mirrors `DeepReviewVM.setHeader`'s third argument.  The default matters
    ## as much as the value: a panel that leaves review mode must not keep
    ## describing the review's changeset.
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()

      vm.setHeader("Review: parser cleanup", statsText = "3 files +16 -10")
      check vm.headerTitle.val == "Review: parser cleanup"
      check vm.statsText.val == "3 files +16 -10"

      vm.setHeader("main")
      check vm.statsText.val == ""

      vm.setHeader("Review", statsText = "1 file")
      vm.clearPanel()
      check vm.statsText.val == ""

      dispose()

suite "VCSVM hunk editor (DR-R4)":
  ## VCS-Panel.md, "Hunk Editor": per-hunk selection, shift-click ranges,
  ## ctrl-click toggling and copy-as-patch.
  ##
  ## Until DR-R4 every one of those lived in ``ui/vcs.nim`` over the raw
  ## ``DeepReviewData`` of a DOM-rendered panel — JS-only, browser-only, and
  ## tied to the renderer being replaced.  DeepReview-GUI.md §4.5 makes the
  ## hunk editor "a *constraint on the diff tab, not an optional extra*", so
  ## the model moved into this ViewModel and the Monaco tab became a
  ## dispatcher over it.  These tests are what says the capability survived.

  proc hunkFixture(): seq[VCSDiffFileRow] =
    ## Two files, two hunks each.  Flat ordinals: (0,0)=0, (0,1)=1, (1,0)=2,
    ## (1,1)=3.
    @[
      VCSDiffFileRow(
        fileIndex: 0, status: "M", path: "src/parser.rs",
        additions: 3, deletions: 2,
        hunks: @[
          VCSHunkRow(oldStart: 40, oldCount: 2, newStart: 40, newCount: 3,
            lines: @[
              VCSDiffLineRow(lineType: "context",
                             content: "fn parse(input: &str) {",
                             oldLine: 40, newLine: 40),
              VCSDiffLineRow(lineType: "removed",
                             content: "  match parse(input) {", oldLine: 41),
              VCSDiffLineRow(lineType: "added",
                             content: "  let token = parse(input);",
                             newLine: 41),
              VCSDiffLineRow(lineType: "added", content: "  match token {",
                             newLine: 42),
            ]),
          VCSHunkRow(oldStart: 80, oldCount: 1, newStart: 81, newCount: 1,
            lines: @[
              VCSDiffLineRow(lineType: "removed", content: "  legacy();",
                             oldLine: 80),
              VCSDiffLineRow(lineType: "added", content: "  modern();",
                             newLine: 81),
            ]),
        ]),
      VCSDiffFileRow(
        fileIndex: 1, status: "A", path: "src/lexer.rs",
        additions: 2, deletions: 0,
        hunks: @[
          VCSHunkRow(oldStart: 0, oldCount: 0, newStart: 1, newCount: 1,
            lines: @[VCSDiffLineRow(lineType: "added", content: "mod lexer;",
                                    newLine: 1)]),
          VCSHunkRow(oldStart: 0, oldCount: 0, newStart: 9, newCount: 1,
            lines: @[VCSDiffLineRow(lineType: "added",
                                    content: "pub fn lex() {}", newLine: 9)]),
        ]),
    ]

  proc diffVM(): VCSVM =
    result = createVCSVM()
    result.setUnifiedDiff(true, hunkFixture())

  test "test_hunk_selection_drives_the_shared_vcs_vm_state":
    ## VCS-Panel.md, "Hunk Selection": "Click a hunk header to select it.
    ## Shift-click to select a range of hunks."
    ##
    ## Driven only through ``selectHunk`` — the entry point the Monaco tab
    ## calls — and asserted only on this ViewModel's own signals and on the
    ## memo the toolbar renders (``selectedHunkCount``).  The tab holds no
    ## selection state of its own, so this is the one model: a port that
    ## introduced a second one would leave these signals empty and the toolbar
    ## unrendered, which is what the Playwright counterpart
    ## (``e2e_unified_diff_hunk_selection_and_copy``) observes.
    createRoot proc(dispose: proc()) =
      let vm = diffVM()

      check vm.selectedHunks.val.len == 0
      check not vm.hunkToolbarVisible.val
      check vm.lastHunkClickOrdinal.val == -1

      vm.selectHunk(0, 1)
      check vm.selectedHunks.val == @[(0, 1)]
      check vm.hunkToolbarVisible.val
      check vm.selectedHunkCount.val == 1
      # The anchor a shift-click extends from is the flat ordinal of the hunk
      # just clicked, not a row index: a range can span files.
      check vm.lastHunkClickOrdinal.val == 1

      vm.selectHunk(1, 0, shiftKey = true)
      check vm.selectedHunks.val == @[(0, 1), (1, 0)]
      check vm.hunkToolbarVisible.val
      check vm.selectedHunkCount.val == 2
      check vm.lastHunkClickOrdinal.val == 2

      dispose()

  test "flat ordinals round-trip across files":
    ## Shift-click ranges are expressed in ordinals, so the two conversions
    ## have to agree — including for a row list whose ``fileIndex`` values are
    ## not its positions, which is what happens whenever the changeset carries
    ## a file with no hunks.
    let files = hunkFixture()
    check flatHunkOrdinal(files, 0, 0) == 0
    check flatHunkOrdinal(files, 0, 1) == 1
    check flatHunkOrdinal(files, 1, 0) == 2
    check flatHunkOrdinal(files, 1, 1) == 3
    for ordinal in 0 .. 3:
      let pair = hunkPairFromOrdinal(files, ordinal)
      check flatHunkOrdinal(files, pair[0], pair[1]) == ordinal
    # An ordinal that names no hunk resolves to "nothing", so a range walk
    # skips it instead of selecting hunk (0, 0) by accident.
    check hunkPairFromOrdinal(files, 4) == (-1, -1)
    check hunkPairFromOrdinal(files, -1) == (-1, -1)

    var sparse = hunkFixture()
    sparse[1].fileIndex = 3
    check flatHunkOrdinal(sparse, 3, 0) == 2
    check hunkPairFromOrdinal(sparse, 3) == (3, 1)

  test "ctrl-click toggles one hunk and a plain click on the sole selection clears it":
    ## VCS-Panel.md, "Hunk Selection": "Ctrl-click to toggle individual hunk
    ## selection."  The plain-click behaviour is the pre-DR-R4 one, preserved:
    ## clicking the only selected hunk deselects it.
    createRoot proc(dispose: proc()) =
      let vm = diffVM()

      vm.selectHunk(0, 0, ctrlKey = true)
      vm.selectHunk(1, 1, ctrlKey = true)
      check vm.selectedHunks.val == @[(0, 0), (1, 1)]

      vm.selectHunk(0, 0, ctrlKey = true)
      check vm.selectedHunks.val == @[(1, 1)]
      check vm.hunkToolbarVisible.val

      vm.selectHunk(1, 1, ctrlKey = true)
      check vm.selectedHunks.val.len == 0
      check not vm.hunkToolbarVisible.val

      vm.selectHunk(0, 1)
      check vm.selectedHunks.val == @[(0, 1)]
      vm.selectHunk(0, 1)
      check vm.selectedHunks.val.len == 0
      check not vm.hunkToolbarVisible.val

      dispose()

  test "test_copy_as_patch_output_is_unchanged_by_the_monaco_port":
    ## VCS-Panel.md, "Hunk Operations": "Copy — copy selected hunks to
    ## clipboard (as patch format)".
    ##
    ## The golden below is the output of the *pre-DR-R4* builder
    ## (``VCSComponent.buildPatchFromSelectedHunks`` in ``ui/vcs.nim``),
    ## derived from its code rather than from the new one: files grouped in
    ## order of first appearance in the selection, three header lines each,
    ## hunks in selection order, one ``+``/``-``/space-prefixed line per diff
    ## line, newline-joined with a trailing newline.  A patch a user pipes into
    ## ``git apply`` must not change shape because the diff moved to Monaco.
    createRoot proc(dispose: proc()) =
      let vm = diffVM()

      vm.selectHunk(0, 1)
      vm.selectHunk(1, 0, ctrlKey = true)
      check vm.selectedHunks.val == @[(0, 1), (1, 0)]

      const goldenPatch =
        "diff --git a/src/parser.rs b/src/parser.rs\n" &
        "--- a/src/parser.rs\n" &
        "+++ b/src/parser.rs\n" &
        "@@ -80,1 +81,1 @@\n" &
        "-  legacy();\n" &
        "+  modern();\n" &
        "diff --git a/src/lexer.rs b/src/lexer.rs\n" &
        "--- a/src/lexer.rs\n" &
        "+++ b/src/lexer.rs\n" &
        "@@ -0,0 +1,1 @@\n" &
        "+mod lexer;\n"

      check vm.buildPatchFromSelectedHunks() == goldenPatch

      dispose()

  test "copy-as-patch groups by file and keeps context lines space-prefixed":
    ## The other half of the format: two hunks of one file share a single set
    ## of ``diff --git`` / ``---`` / ``+++`` headers, and a context line is
    ## emitted with a leading space so the patch applies.
    createRoot proc(dispose: proc()) =
      let vm = diffVM()

      vm.selectHunk(0, 0)
      vm.selectHunk(0, 1, ctrlKey = true)

      const goldenPatch =
        "diff --git a/src/parser.rs b/src/parser.rs\n" &
        "--- a/src/parser.rs\n" &
        "+++ b/src/parser.rs\n" &
        "@@ -40,2 +40,3 @@\n" &
        " fn parse(input: &str) {\n" &
        "-  match parse(input) {\n" &
        "+  let token = parse(input);\n" &
        "+  match token {\n" &
        "@@ -80,1 +81,1 @@\n" &
        "-  legacy();\n" &
        "+  modern();\n"

      check vm.buildPatchFromSelectedHunks() == goldenPatch
      # Nothing selected is nothing to copy — not an empty patch that would
      # land on the clipboard.
      vm.clearHunkSelection()
      check vm.buildPatchFromSelectedHunks() == ""

      dispose()

  test "a review's rows produce a patch git can apply, not `++foo`":
    ## The bug UD-1 exposed, pinned where it lives.
    ##
    ## The two producers of a hunk line's ``content`` disagree:
    ## ``ui/git_cli.parseGitDiffHunks`` strips the unified-diff marker, while
    ## the materialized review collector
    ## (``db-backend/src/deepreview/unified_diff.rs``) keeps it for added and
    ## removed lines — "the sample dataset shows added/removed lines keeping
    ## their marker", as its own comment says.  ``buildPatchFromSelectedHunks``
    ## concatenated its own prefix on top, so a *review's* patch came out as
    ## ``++foo`` / ``--foo``, which ``git apply`` rejects with "patch does not
    ## apply".
    ##
    ## The two goldens above cannot catch it: their fixture is git-shaped, so
    ## there is no marker to double.  This one is collector-shaped, which is
    ## the only shape that reproduces it.
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()
      vm.setUnifiedDiff(true, @[
        VCSDiffFileRow(
          fileIndex: 0, status: "M", path: "src/main.nr",
          additions: 1, deletions: 1,
          hunks: @[
            VCSHunkRow(oldStart: 6, oldCount: 3, newStart: 6, newCount: 3,
              lines: @[
                # Context arrives without a marker from both producers.
                VCSDiffLineRow(lineType: "context", content: "f",
                               oldLine: 6, newLine: 6),
                # ... added and removed arrive WITH one from the collector.
                VCSDiffLineRow(
                  lineType: "removed",
                  content: "-fn scale(index: Field, factor: Field) {",
                  oldLine: 7),
                VCSDiffLineRow(
                  lineType: "added",
                  content: "+fn scale(index: Field, multiplier: Field) {",
                  newLine: 7),
                VCSDiffLineRow(lineType: "context", content: "}",
                               oldLine: 8, newLine: 8),
              ]),
          ]),
      ])
      vm.selectHunk(0, 0)

      const goldenPatch =
        "diff --git a/src/main.nr b/src/main.nr\n" &
        "--- a/src/main.nr\n" &
        "+++ b/src/main.nr\n" &
        "@@ -6,3 +6,3 @@\n" &
        " f\n" &
        "-fn scale(index: Field, factor: Field) {\n" &
        "+fn scale(index: Field, multiplier: Field) {\n" &
        " }\n"

      check vm.buildPatchFromSelectedHunks() == goldenPatch

      # Stated separately from the golden so a future edit to the fixture
      # cannot quietly reintroduce the doubling: no body line of the patch may
      # carry two markers.  The `---` / `+++` file headers are exempt, and are
      # the reason a bare `"++" notin patch` would not have worked.
      let patchLines: seq[string] =
        vm.buildPatchFromSelectedHunks().splitLines()
      for i, line in patchLines:
        if i < 3 or line.len == 0:
          continue
        check not line.startsWith("++")
        check not line.startsWith("--")

      dispose()

  test "the mutating hunk operations are disabled for a review":
    ## VCS-Panel.md, "DeepReview Mode": "Commit operations: Disabled
    ## (read-only view)" — while DeepReview-GUI.md §4.5 keeps "selection and
    ## copy-as-patch ... available".
    createRoot proc(dispose: proc()) =
      let vm = diffVM()

      check vm.mutatingHunkOpsEnabled()

      vm.setDeepReviewMode(true)
      check not vm.mutatingHunkOpsEnabled()

      # Selection and copy are unaffected by the mode.
      vm.selectHunk(1, 0)
      check vm.selectedHunks.val == @[(1, 0)]
      check vm.buildPatchFromSelectedHunks().len > 0

      dispose()

suite "VCSVM context expansion state (DR-R5, retargeted by UD-2)":
  ## DeepReview-GUI.md §4.2 requires the expand-above / expand-below controls.
  ##
  ## Until UD-2 the state behind them was a per-hunk counter on this ViewModel,
  ## and this suite asserted its bookkeeping: that it was per (file, hunk),
  ## that repeated expansion accumulated, that it survived a re-sync, and that
  ## it was dropped when the tab stopped describing its target.
  ##
  ## UD-2 removed the counter.  The diff tab's models are the whole file now
  ## and Monaco's ``hideUnchangedRegions`` owns which of its lines are on
  ## screen, so a counter here would be a second notion of the same window and
  ## would drift from Monaco's the moment a reader dragged a boundary.
  ##
  ## Two of the four properties do not survive that change, because there is no
  ## longer any per-hunk state to be per-hunk about.  The other two do, and they
  ## matter more than before — Monaco's expansion lives in the *editor*, so
  ## anything that re-publishes a model destroys it:
  ##
  ## - a re-sync of the same rows must produce a byte-identical document, or
  ##   the host's ``setValue`` guard fires, the models are replaced and every
  ##   region a reader had expanded collapses again;
  ## - a panel that stops describing its target must produce no document, so
  ##   the next one starts from a clean editor rather than inheriting regions
  ##   keyed on lines that now mean something else.

  proc expansionFixture(): seq[VCSDiffFileRow] =
    ## Two files, two hunks each — the same shape the hunk-editor suite uses,
    ## restated here because a ``suite`` body is its own scope.
    @[
      VCSDiffFileRow(
        fileIndex: 0, status: "M", path: "src/parser.rs",
        sourceLines: @["a1", "a2", "a3", "a4", "a5"],
        hunks: @[
          VCSHunkRow(oldStart: 2, oldCount: 1, newStart: 2, newCount: 1,
            lines: @[VCSDiffLineRow(lineType: "added", content: "a",
                                    newLine: 2)]),
          VCSHunkRow(oldStart: 4, oldCount: 1, newStart: 4, newCount: 1,
            lines: @[VCSDiffLineRow(lineType: "added", content: "b",
                                    newLine: 4)]),
        ]),
      VCSDiffFileRow(
        fileIndex: 1, status: "M", path: "src/lexer.rs",
        hunks: @[
          VCSHunkRow(oldStart: 5, oldCount: 1, newStart: 5, newCount: 1,
            lines: @[VCSDiffLineRow(lineType: "added", content: "c",
                                    newLine: 5)]),
          VCSHunkRow(oldStart: 9, oldCount: 1, newStart: 9, newCount: 1,
            lines: @[VCSDiffLineRow(lineType: "added", content: "d",
                                    newLine: 9)]),
        ]),
    ]

  proc expansionVM(): VCSVM =
    result = createVCSVM()
    result.setUnifiedDiff(true, expansionFixture())

  test "a re-sync of the same diff rebuilds a byte-identical document":
    ## The tab re-publishes its rows into the VM on every mount attempt (a tab
    ## drag, a layout restore, a GoldenLayout re-create).  The host only calls
    ## ``setValue`` when the text actually changed, so an identical document is
    ## what keeps a reader's expanded regions alive across all of those; a
    ## document that differed by so much as a line would replace the models and
    ## collapse everything, which is the concrete bug DR-R5 hit when the
    ## counters lived on the component.
    createRoot proc(dispose: proc()) =
      let vm = expansionVM()
      let before = diffPairFor(vm)

      vm.setUnifiedDiff(true, expansionFixture())
      let after = diffPairFor(vm)

      check documentText(after.modified) == documentText(before.modified)
      check documentText(after.original) == documentText(before.original)
      check after.modified.lines.len == before.modified.lines.len
      check after.unchangedRuns.len == before.unchangedRuns.len
      # ... and the document really does hold something, so the check above is
      # not two empty strings agreeing with each other.
      check before.modified.lines.len > 0

      dispose()

  test "a cleared panel produces no document, so the next tab starts clean":
    ## "Expansion state resets when the tab is closed and does not leak between
    ## files" — DR-R5's deliverable, restated for an editor that holds the
    ## state: an empty document means a fresh diff editor with no regions,
    ## rather than one carrying regions keyed on lines of a different file.
    createRoot proc(dispose: proc()) =
      let vm = expansionVM()
      check diffPairFor(vm).modified.lines.len > 0

      vm.clearPanel()
      check vm.diffFiles.val.len == 0
      check diffPairFor(vm).modified.lines.len == 0
      check diffPairFor(vm).files.len == 0

      dispose()

  test "each hunk still keeps its own identity in the whole-file document":
    ## What the per-hunk counters were keyed on, and the reason they were:
    ## expanding around one hunk must not disturb another, and a click must
    ## resolve to the hunk it landed in.  The counters are gone; the keying is
    ## not, because hunk selection and the patch builder both use it.
    createRoot proc(dispose: proc()) =
      let vm = expansionVM()
      let doc = diffPairFor(vm).modified
      var seen: seq[(int, int)] = @[]
      for i, line in doc.lines:
        if line.kind == dlkHunkHeader:
          seen.add(hunkAtLine(doc, i + 1))
      check seen == @[(0, 0), (0, 1), (1, 0), (1, 1)]
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
