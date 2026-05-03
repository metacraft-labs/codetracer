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

proc makeFile(path: string; status = "M"; coverage = "1/2"):
    DeepReviewFileEntry =
  DeepReviewFileEntry(
    path: path,
    diffStatus: status,
    linesAdded: 3,
    linesRemoved: 1,
    coverageText: coverage,
    hasCoverage: true,
    hasFlow: false,
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

suite "DeepReviewVM helpers":

  test "clampDeepReviewIndex handles empty and out-of-range inputs":
    check clampDeepReviewIndex(-1, 0) == 0
    check clampDeepReviewIndex(-1, 3) == 0
    check clampDeepReviewIndex(7, 3) == 2
    check clampDeepReviewIndex(1, 3) == 1
