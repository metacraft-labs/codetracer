## Unit tests for ``DeepReviewVM``.

import std/unittest
import isonim/core/[signals, computation, owner]
import backend/mock_backend
import store/types
import store/replay_data_store
import viewmodels/deepreview_vm

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

suite "DeepReviewVM helpers":

  test "clampDeepReviewIndex handles empty and out-of-range inputs":
    check clampDeepReviewIndex(-1, 0) == 0
    check clampDeepReviewIndex(-1, 3) == 0
    check clampDeepReviewIndex(7, 3) == 2
    check clampDeepReviewIndex(1, 3) == 1
