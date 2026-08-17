## Unit tests for ``DeepReviewVM``.
##
## The last suite renders the real IsoNim DeepReview view through
## ``MockRenderer`` rather than asserting on VM state alone.  It lives here
## because the defect it guards (issue #610) is a *view* decision keyed off a
## VM flag: the mode toggle used to be suppressed whenever ``glEmbedded`` was
## set, and ``glEmbedded`` is set for every ``--deepreview`` session — so no
## VM-level assertion could observe it.

import std/[json, strutils, tables, unittest]
import isonim/core/[signals, computation, owner]
import isonim/testing/mock_dom
import backend/mock_backend
import store/types
import store/replay_data_store
import viewmodels/deepreview_vm
import viewmodels/review_entry
import viewmodels/vcs_vm
import views/isonim_deepreview_view

proc makeStoreWithMock(autoRespond: bool = true):
    tuple[store: ReplayDataStore, mock: MockBackendService] =
  let mock = newMockBackendService(autoRespond = autoRespond)
  let store = createReplayDataStore(mock.toBackendService())
  (store, mock)

proc makeFile(path: string; status = "M"; coverage = "1/2";
              added = 3; removed = 1):
    DeepReviewFileEntry =
  DeepReviewFileEntry(
    path: path,
    diffStatus: status,
    linesAdded: added,
    linesRemoved: removed,
    coverageText: coverage,
    hasCoverage: true,
    hasFlow: false,
  )

proc makeUnifiedFile(fileIndex: int; path, status: string;
                     added, removed: int; hunkHeader: tuple[
                       oldStart, oldCount, newStart, newCount: int]):
    DeepReviewUnifiedFileEntry =
  DeepReviewUnifiedFileEntry(
    fileIndex: fileIndex,
    path: path,
    diffStatus: status,
    linesAdded: added,
    linesRemoved: removed,
    hunks: @[
      DeepReviewHunkEntry(
        oldStart: hunkHeader.oldStart,
        oldCount: hunkHeader.oldCount,
        newStart: hunkHeader.newStart,
        newCount: hunkHeader.newCount,
        lines: @[
          DeepReviewDiffLineEntry(
            lineType: "removed",
            content: "let oldValue = parse(input)",
            oldLine: hunkHeader.oldStart,
          ),
          DeepReviewDiffLineEntry(
            lineType: "added",
            content: "let newValue = parseChecked(input)",
            newLine: hunkHeader.newStart,
            values: @[
              DeepReviewFlowValueEntry(
                name: "newValue",
                value: "42",
                truncated: false,
              ),
            ],
          ),
        ],
      )
    ],
  )

proc makeCallNode(name: string; executionCount, depth: int):
    DeepReviewCallNodeEntry =
  DeepReviewCallNodeEntry(
    name: name,
    executionCount: executionCount,
    depth: depth,
  )

suite "DeepReviewVM initial state":

  test "defaults reflect an unloaded panel":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDeepReviewVM(store)

      check not vm.hasData.val
      check not vm.glEmbedded.val
      check vm.viewMode.val == drpvmFullFiles
      check vm.files.val.len == 0
      check vm.fileCount.val == 0
      check vm.selectedFileIndex.val == 0
      check vm.selectedFile.val.path == ""
      check vm.flowCount.val == 0
      check vm.maxIterations.val == 0
      check vm.unifiedFiles.val.len == 0
      check vm.callNodes.val.len == 0

      dispose()

suite "DeepReviewVM setters":

  test "header trace context and mode state update independently":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDeepReviewVM(store)

      vm.setHasData(true)
      vm.setGlEmbedded(true)
      vm.setHeader("Review session", "abcdef123456...", "2 files | 1 recordings | 9ms")
      vm.setTraceContexts(@[
        DeepReviewTraceContextEntry(id: 1, label: "latest"),
        DeepReviewTraceContextEntry(id: 2, label: "previous"),
      ])
      vm.setSelectedTraceContextId(2)
      vm.setViewMode(drpvmUnified)

      check vm.hasData.val
      check vm.glEmbedded.val
      check vm.sessionTitle.val == "Review session"
      check vm.commitDisplay.val == "abcdef123456..."
      check vm.statsText.val == "2 files | 1 recordings | 9ms"
      check vm.traceContexts.val.len == 2
      check vm.selectedTraceContextId.val == 2
      check vm.viewMode.val == drpvmUnified

      dispose()

  test "file selection clamps to the available file rows":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDeepReviewVM(store)

      vm.setFiles(@[
        makeFile("/repo/a.nim"),
        makeFile("/repo/b.nim", status = "A", coverage = "4/4"),
      ])
      vm.setSelectedFileIndex(9)

      check vm.fileCount.val == 2
      check vm.selectedFileIndex.val == 1
      check vm.selectedFile.val.path == "/repo/b.nim"
      check vm.selectedFile.val.diffStatus == "A"

      vm.setFiles(@[makeFile("/repo/only.nim")])
      check vm.selectedFileIndex.val == 0
      check vm.selectedFile.val.path == "/repo/only.nim"

      dispose()

  test "execution iteration hunk and clear state are bounded":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDeepReviewVM(store)

      vm.setExecutionState(10, 3, "main")
      vm.setIterationState(6, 2)
      vm.setSelectedHunks(@[(1, 2), (1, 3)])
      vm.setHunkCopyFeedback(true)

      check vm.selectedExecutionIndex.val == 2
      check vm.flowCount.val == 3
      check vm.currentFunctionKey.val == "main"
      check vm.selectedIteration.val == 1
      check vm.maxIterations.val == 2
      check vm.hunkToolbarVisible.val
      check vm.selectedHunks.val.len == 2
      check vm.hunkCopyFeedback.val

      vm.clearPanel()
      check not vm.hasData.val
      check vm.files.val.len == 0
      check vm.selectedHunks.val.len == 0
      check not vm.hunkToolbarVisible.val
      check not vm.hunkCopyFeedback.val

      dispose()

suite "DeepReviewVM smoke pairing":

  test "offline review rows mode switch and hunk selection stay in VM state":
    ## Smoke-level companion for deepreview-gui.spec.ts:
    ## header metadata, trace-context options, file rows, file selection,
    ## unified diff sections, and hunk selection are all user-visible
    ## DeepReview flows, but are deterministic VM state here.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDeepReviewVM(store)

      vm.setHasData(true)
      vm.setHeader("DeepReview: parser cleanup",
                   "a1b2c3d4e5f6...",
                   "3 files | 2 recordings | 1542ms")
      vm.setTraceContexts(@[
        DeepReviewTraceContextEntry(id: 101, label: "latest passing run"),
        DeepReviewTraceContextEntry(id: 77, label: "previous run"),
      ])
      vm.setSelectedTraceContextId(101)
      vm.setFiles(@[
        makeFile("src/main.rs", status = "M", coverage = "5/8",
                 added = 8, removed = 3),
        makeFile("src/utils.rs", status = "A", coverage = "8/8",
                 added = 8, removed = 0),
        makeFile("src/config.rs", status = "D", coverage = "0/7",
                 added = 0, removed = 7),
      ])
      vm.setSelectedFileIndex(1)
      vm.setUnifiedFiles(@[
        makeUnifiedFile(0, "src/main.rs", "M", 8, 3, (2, 5, 2, 10)),
        makeUnifiedFile(1, "src/utils.rs", "A", 8, 0, (0, 0, 1, 8)),
        makeUnifiedFile(2, "src/config.rs", "D", 0, 7, (1, 7, 0, 0)),
      ])
      vm.setViewMode(drpvmUnified)
      vm.setSelectedHunks(@[(1, 0)])

      check vm.hasData.val
      check vm.sessionTitle.val == "DeepReview: parser cleanup"
      check vm.commitDisplay.val == "a1b2c3d4e5f6..."
      check vm.statsText.val == "3 files | 2 recordings | 1542ms"
      check vm.traceContexts.val.len == 2
      check vm.traceContexts.val[0].label == "latest passing run"
      check vm.selectedTraceContextId.val == 101
      check vm.fileCount.val == 3
      check vm.selectedFileIndex.val == 1
      check vm.selectedFile.val.path == "src/utils.rs"
      check vm.selectedFile.val.diffStatus == "A"
      check vm.selectedFile.val.linesAdded == 8
      check vm.selectedFile.val.linesRemoved == 0
      check vm.viewMode.val == drpvmUnified
      check vm.unifiedFiles.val.len == 3
      check vm.unifiedFiles.val[0].path == "src/main.rs"
      check vm.unifiedFiles.val[0].hunks[0].oldStart == 2
      check vm.unifiedFiles.val[1].hunks[0].newCount == 8
      check vm.unifiedFiles.val[2].diffStatus == "D"
      check vm.selectedHunks.val == @[(1, 0)]
      check vm.hunkToolbarVisible.val

      dispose()

  test "calltrace execution and iteration state stay in VM state":
    ## Bounded companion for the DeepReview calltrace scenarios:
    ## flattened call nodes, execution slider state, selected function, and
    ## loop-iteration state are owned by DeepReviewVM. Monaco decorations and
    ## expand-context controls remain outside this VM-level slice.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDeepReviewVM(store)

      vm.setHasData(true)
      vm.setFiles(@[
        makeFile("src/review_target.rs", status = "M", coverage = "12/18",
                 added = 5, removed = 2),
      ])
      vm.setSelectedFileIndex(0)
      vm.setExecutionState(2, 4, "parse_input")
      vm.setIterationState(3, 6)
      vm.setCallNodes(@[
        makeCallNode("main", executionCount = 1, depth = 0),
        makeCallNode("parse_input", executionCount = 4, depth = 1),
        makeCallNode("validate_token", executionCount = 2, depth = 2),
      ])

      check vm.hasData.val
      check vm.selectedFile.val.path == "src/review_target.rs"
      check vm.flowCount.val == 4
      check vm.selectedExecutionIndex.val == 2
      check vm.currentFunctionKey.val == "parse_input"
      check vm.maxIterations.val == 6
      check vm.selectedIteration.val == 3
      check vm.callNodes.val.len == 3
      check vm.callNodes.val[0].name == "main"
      check vm.callNodes.val[0].depth == 0
      check vm.callNodes.val[1].name == "parse_input"
      check vm.callNodes.val[1].executionCount == 4
      check vm.callNodes.val[2].depth == 2

      vm.setExecutionState(9, 4, "validate_token")
      vm.setIterationState(99, 6)

      check vm.selectedExecutionIndex.val == 3
      check vm.currentFunctionKey.val == "validate_token"
      check vm.selectedIteration.val == 5

      dispose()

suite "DeepReviewVM helpers":

  test "clampDeepReviewIndex handles empty and out-of-range inputs":
    check clampDeepReviewIndex(-1, 0) == 0
    check clampDeepReviewIndex(-1, 3) == 0
    check clampDeepReviewIndex(7, 3) == 2
    check clampDeepReviewIndex(1, 3) == 1

# ---------------------------------------------------------------------------
# View-level guards for issue #610 (M42a)
# ---------------------------------------------------------------------------

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

proc findById(node: MockNode; id: string): MockNode =
  ## Used for the Monaco host div rather than `findByClass`: the editor's
  ## class (`deepreview-editor`) is a prefix of its container's
  ## (`deepreview-editor-area`), so a substring class match cannot tell the
  ## two apart.
  if node.kind == mnkElement and node.attributes.getOrDefault("id", "") == id:
    return node
  for child in node.children:
    let found = findById(child, id)
    if found != nil:
      return found
  nil

proc populateEmbeddedPanel(vm: DeepReviewVM) =
  ## Minimum state for a GL-embedded review panel with something to show.
  vm.setHasData(true)
  vm.setGlEmbedded(true)
  vm.setHeader("DeepReview: parser", "abcdef123456...",
               "1 files | 1 recordings | 9ms")
  vm.setFiles(@[makeFile("/repo/src/main.rs")])
  vm.setViewMode(drpvmUnified)

suite "DeepReview view — GL-embedded panel (issue #610)":

  test "the view mode toggle is rendered even when GL-embedded":
    ## `glEmbedded` is true for the whole `--deepreview` session, so hiding
    ## the toggle behind it made Full Files mode permanently unreachable.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDeepReviewVM(store)
      let r = MockRenderer()
      let panel = renderDeepReviewPanel(r, vm, componentId = 11)

      populateEmbeddedPanel(vm)

      check vm.glEmbedded.val
      check findByClass(panel, "deepreview-mode-toggle") != nil
      check findAllByClass(panel, "deepreview-mode-btn").len == 2

      dispose()

  test "picking Full Files switches the embedded editor area":
    ## The toggle has to *do* something: `glEmbedded` legitimately drops the
    ## panel's own file list and calltrace columns (the VCS and CALLTRACE
    ## panels own those), but the editor area must still honour the mode.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDeepReviewVM(store)
      let r = MockRenderer()
      var reportedMode = drpvmUnified
      let callbacks = DeepReviewCallbacks(
        onSetViewMode: proc(mode: DeepReviewPanelViewMode) =
          (reportedMode = mode))
      let panel = renderDeepReviewPanel(r, vm, componentId = 12,
                                        callbacks = callbacks)

      populateEmbeddedPanel(vm)
      check findByClass(panel, DeepReviewUnifiedDiffClass) != nil
      check findById(panel, isonim_deepreview_view.editorId(12)) == nil

      findAllByClass(panel, "deepreview-mode-btn")[0].fireEvent("click")

      check vm.viewMode.val == drpvmFullFiles
      check reportedMode == drpvmFullFiles
      let editorHost = findById(panel, isonim_deepreview_view.editorId(12))
      check editorHost != nil
      check editorHost.attributes.getOrDefault("class", "") ==
        DeepReviewEditorClass
      check findByClass(panel, DeepReviewUnifiedDiffClass) == nil
      # The duplicated columns stay suppressed — that part of `glEmbedded`
      # is correct and must not regress.
      check findByClass(panel, DeepReviewFileListClass) == nil
      check findByClass(panel, "deepreview-calltrace") == nil

      dispose()

  test "switching back to Unified restores the diff surface":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDeepReviewVM(store)
      let r = MockRenderer()
      let panel = renderDeepReviewPanel(r, vm, componentId = 13)

      populateEmbeddedPanel(vm)
      findAllByClass(panel, "deepreview-mode-btn")[0].fireEvent("click")
      check findById(panel, isonim_deepreview_view.editorId(13)) != nil

      findAllByClass(panel, "deepreview-mode-btn")[1].fireEvent("click")
      check vm.viewMode.val == drpvmUnified
      check findById(panel, isonim_deepreview_view.editorId(13)) == nil
      check findByClass(panel, DeepReviewUnifiedDiffClass) != nil

      dispose()

# ---------------------------------------------------------------------------
# Review entry: opening the first modified file (DR-R1)
# ---------------------------------------------------------------------------
#
# DeepReview-GUI.md §7, "Transition into a Review", step 2: "The first
# modified file opens in the editor with unified diff view."  The step is a
# named, reusable routine (`viewmodels/review_entry`) because DR-R7 makes all
# three launch paths — `ct --deepreview`, opening a diff-associated trace, and
# the agentic handoff — converge on it.
#
# The changeset is read from the same `sample-review.json` fixture the
# Playwright suite launches CodeTracer over, so the headless test and the GUI
# test are describing one dataset.  The projection below mirrors
# `deepReviewRows` in `src/frontend/ui/vcs.nim`, which is JS-only (it walks the
# `DeepReviewData` JS object) and therefore not importable here.

proc fixtureDirPath(): string {.compileTime.} =
  let p = currentSourcePath()
  var cut = p.rfind('/')
  let backslash = p.rfind('\\')
  if backslash > cut:
    cut = backslash
  p[0 .. cut] & "fixtures/"

const SampleReviewJson = staticRead(fixtureDirPath() & "sample-review.json")
const EmptyReviewJson = staticRead(fixtureDirPath() & "empty-review.json")

proc reviewRowsFromFixture(fixture: string): seq[VCSFileRow] =
  ## Project a DeepReview export's `files` array into the VCS panel's changed
  ## file rows, the way `vcs.nim`'s `deepReviewRows` does.
  result = @[]
  let data = parseJson(fixture)
  if not data.hasKey("files"):
    return
  for file in data["files"].items:
    let path = file{"path"}.getStr("")
    var slash = path.rfind('/')
    let baseName = if slash >= 0: path[slash + 1 .. ^1] else: path
    let diff = file{"diff"}
    var executed = 0
    var covered = 0
    if file.hasKey("coverage"):
      for cov in file["coverage"].items:
        covered += 1
        if cov{"executed"}.getBool(false):
          executed += 1
    let status =
      if diff != nil and diff{"status"}.getStr("").len > 0:
        diff{"status"}.getStr("")
      else:
        "M"
    result.add(VCSFileRow(
      status: status,
      path: path,
      baseName: baseName,
      additions: if diff == nil: 0 else: diff{"linesAdded"}.getInt(0),
      deletions: if diff == nil: 0 else: diff{"linesRemoved"}.getInt(0),
      coverageText: if covered > 0: $executed & "/" & $covered else: "",
      selected: false,
    ))

suite "Review entry — the first modified file opens (DR-R1)":

  test "the fixture projection matches the review dataset":
    ## Guards the three tests below: if the fixture ever loses its files or
    ## changes their order, they must fail loudly rather than silently assert
    ## about an empty changeset.
    let rows = reviewRowsFromFixture(SampleReviewJson)
    check rows.len == 3
    check rows[0].path == "src/main.rs"
    check rows[0].status == "M"
    check rows[2].status == "D"
    check reviewRowsFromFixture(EmptyReviewJson).len == 0

  test "test_review_start_opens_first_modified_file":
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()
      vm.setDeepReviewMode(true)
      vm.setChangedFiles(reviewRowsFromFixture(SampleReviewJson))

      # Stands in for the editor area: one entry per open document, keyed by
      # the tab identity the host uses (`independentTabPath` for a diff tab,
      # the editor tab path for a source file), so a repeated open focuses
      # rather than duplicates.
      var documents: seq[string] = @[]
      let action = vm.openFirstReviewFile(proc(a: VCSOpenAction) =
        if a.documentKey notin documents:
          documents.add(a.documentKey))

      check documents.len == 1
      check action.kind == voaDiffTab
      check action.index == 0
      check action.path == "src/main.rs"
      check documents[0] == "diff:file:src/main.rs"

      # The VCS panel's list and the editor agree on which file is under
      # review (§7 step 1-2; VCS-Panel.md "The selected row is highlighted").
      check vm.changedFiles.val[0].selected
      check not vm.changedFiles.val[1].selected
      check not vm.changedFiles.val[2].selected

      dispose()

  test "review start honours the view mode the toggle defaults to":
    ## `vcs.defaultView: "unified-diff"` (VCS-Panel.md, Configuration) is the
    ## default; a session whose toggle sits on Open File must open the file
    ## itself instead, from the same step.
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()
      vm.setDeepReviewMode(true)
      vm.setChangedFiles(reviewRowsFromFixture(SampleReviewJson))
      vm.setViewMode(vmOpenFile)

      var documents: seq[string] = @[]
      let action = vm.openFirstReviewFile(proc(a: VCSOpenAction) =
        if a.documentKey notin documents:
          documents.add(a.documentKey))

      check documents.len == 1
      check action.kind == voaSourceFile
      check documents[0] == "src/main.rs"

      dispose()

  test "reopening an already-open file targets the same document":
    ## DR-R1: "Opening a file that is already open focuses its existing tab
    ## rather than opening a second one."  The host implements the focus in
    ## `openLayoutTab` / `openTab`, both of which key on the requested
    ## document path — so the property this layer owns is that the step asks
    ## for a *stable* key for a given row.
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()
      vm.setDeepReviewMode(true)
      vm.setChangedFiles(reviewRowsFromFixture(SampleReviewJson))

      var documents: seq[string] = @[]
      let first = vm.openFirstReviewFile(proc(a: VCSOpenAction) =
        if a.documentKey notin documents:
          documents.add(a.documentKey))
      let again = vm.openReviewFile(0, proc(a: VCSOpenAction) =
        if a.documentKey notin documents:
          documents.add(a.documentKey))

      check first.documentKey == again.documentKey
      check documents.len == 1

      dispose()

  test "an empty review opens nothing":
    ## `empty-review.json` has no files; the step must not fabricate a
    ## document or dispatch an action for a row that does not exist.
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()
      vm.setDeepReviewMode(true)
      vm.setChangedFiles(reviewRowsFromFixture(EmptyReviewJson))

      var opens = 0
      let action = vm.openFirstReviewFile(proc(a: VCSOpenAction) =
        (discard a; opens += 1))

      check action.kind == voaNone
      check opens == 0

      dispose()
