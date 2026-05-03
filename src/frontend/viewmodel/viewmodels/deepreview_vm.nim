## viewmodels/deepreview_vm.nim
##
## ViewModel for the standalone DeepReview panel.  The legacy
## ``DeepReviewComponent`` continues to own Monaco and bridge-only state,
## while this VM carries the flat render snapshot consumed by the IsoNim
## view.

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ../store/[replay_data_store, types]

type
  DeepReviewVM* = ref object of ViewModel
    store*: ReplayDataStore

    hasData*: Signal[bool]
    glEmbedded*: Signal[bool]
    sessionTitle*: Signal[string]
    commitDisplay*: Signal[string]
    statsText*: Signal[string]
    traceContexts*: Signal[seq[DeepReviewTraceContextEntry]]
    selectedTraceContextId*: Signal[int]
    viewMode*: Signal[DeepReviewPanelViewMode]
    files*: Signal[seq[DeepReviewFileEntry]]
    selectedFileIndex*: Signal[int]
    selectedExecutionIndex*: Signal[int]
    selectedIteration*: Signal[int]
    flowCount*: Signal[int]
    currentFunctionKey*: Signal[string]
    maxIterations*: Signal[int]
    unifiedFiles*: Signal[seq[DeepReviewUnifiedFileEntry]]
    callNodes*: Signal[seq[DeepReviewCallNodeEntry]]
    selectedHunks*: Signal[seq[(int, int)]]
    hunkToolbarVisible*: Signal[bool]
    hunkCopyFeedback*: Signal[bool]

    selectedFile*: Memo[DeepReviewFileEntry]
    fileCount*: Memo[int]

proc clampDeepReviewIndex*(index, fileCount: int): int =
  if fileCount <= 0:
    0
  elif index < 0:
    0
  elif index >= fileCount:
    fileCount - 1
  else:
    index

proc setHasData*(vm: DeepReviewVM; hasData: bool) =
  vm.hasData.val = hasData

proc setGlEmbedded*(vm: DeepReviewVM; embedded: bool) =
  vm.glEmbedded.val = embedded

proc setHeader*(vm: DeepReviewVM; sessionTitle, commitDisplay,
                statsText: string) =
  vm.sessionTitle.val = sessionTitle
  vm.commitDisplay.val = commitDisplay
  vm.statsText.val = statsText

proc setTraceContexts*(vm: DeepReviewVM;
                       contexts: openArray[DeepReviewTraceContextEntry]) =
  vm.traceContexts.val = @contexts

proc setSelectedTraceContextId*(vm: DeepReviewVM; id: int) =
  vm.selectedTraceContextId.val = id

proc setViewMode*(vm: DeepReviewVM; mode: DeepReviewPanelViewMode) =
  vm.viewMode.val = mode

proc setFiles*(vm: DeepReviewVM; files: openArray[DeepReviewFileEntry]) =
  vm.files.val = @files
  vm.selectedFileIndex.val = clampDeepReviewIndex(
    vm.selectedFileIndex.val, vm.files.val.len)

proc setSelectedFileIndex*(vm: DeepReviewVM; index: int) =
  vm.selectedFileIndex.val = clampDeepReviewIndex(index, vm.files.val.len)

proc setExecutionState*(vm: DeepReviewVM; selectedExecutionIndex,
                        flowCount: int; functionKey: string) =
  vm.flowCount.val = max(0, flowCount)
  vm.selectedExecutionIndex.val =
    clampDeepReviewIndex(selectedExecutionIndex, vm.flowCount.val)
  vm.currentFunctionKey.val = functionKey

proc setIterationState*(vm: DeepReviewVM; selectedIteration,
                        maxIterations: int) =
  vm.maxIterations.val = max(0, maxIterations)
  vm.selectedIteration.val =
    clampDeepReviewIndex(selectedIteration, vm.maxIterations.val)

proc setUnifiedFiles*(vm: DeepReviewVM;
                      files: openArray[DeepReviewUnifiedFileEntry]) =
  vm.unifiedFiles.val = @files

proc setCallNodes*(vm: DeepReviewVM;
                   nodes: openArray[DeepReviewCallNodeEntry]) =
  vm.callNodes.val = @nodes

proc setSelectedHunks*(vm: DeepReviewVM; selected: openArray[(int, int)]) =
  vm.selectedHunks.val = @selected
  vm.hunkToolbarVisible.val = selected.len > 0

proc setHunkToolbarVisible*(vm: DeepReviewVM; visible: bool) =
  vm.hunkToolbarVisible.val = visible

proc setHunkCopyFeedback*(vm: DeepReviewVM; copied: bool) =
  vm.hunkCopyFeedback.val = copied

proc clearPanel*(vm: DeepReviewVM) =
  vm.hasData.val = false
  vm.sessionTitle.val = ""
  vm.commitDisplay.val = ""
  vm.statsText.val = ""
  vm.traceContexts.val = @[]
  vm.selectedTraceContextId.val = 0
  vm.files.val = @[]
  vm.selectedFileIndex.val = 0
  vm.selectedExecutionIndex.val = 0
  vm.selectedIteration.val = 0
  vm.flowCount.val = 0
  vm.currentFunctionKey.val = ""
  vm.maxIterations.val = 0
  vm.unifiedFiles.val = @[]
  vm.callNodes.val = @[]
  vm.selectedHunks.val = @[]
  vm.hunkToolbarVisible.val = false
  vm.hunkCopyFeedback.val = false

proc createDeepReviewVM*(store: ReplayDataStore): DeepReviewVM =
  withViewModel proc(dispose: proc()): DeepReviewVM =
    let hasData = createSignal(false)
    let glEmbedded = createSignal(false)
    let sessionTitle = createSignal("")
    let commitDisplay = createSignal("")
    let statsText = createSignal("")
    let traceContexts = createSignal(newSeq[DeepReviewTraceContextEntry]())
    let selectedTraceContextId = createSignal(0)
    let viewMode = createSignal(drpvmFullFiles)
    let files = createSignal(newSeq[DeepReviewFileEntry]())
    let selectedFileIndex = createSignal(0)
    let selectedExecutionIndex = createSignal(0)
    let selectedIteration = createSignal(0)
    let flowCount = createSignal(0)
    let currentFunctionKey = createSignal("")
    let maxIterations = createSignal(0)
    let unifiedFiles = createSignal(newSeq[DeepReviewUnifiedFileEntry]())
    let callNodes = createSignal(newSeq[DeepReviewCallNodeEntry]())
    let selectedHunks = createSignal(newSeq[(int, int)]())
    let hunkToolbarVisible = createSignal(false)
    let hunkCopyFeedback = createSignal(false)

    let fileCount = createMemo[int] proc(): int =
      files.val.len

    let selectedFile = createMemo[DeepReviewFileEntry] proc():
        DeepReviewFileEntry =
      let entries = files.val
      if entries.len == 0:
        DeepReviewFileEntry()
      else:
        entries[clampDeepReviewIndex(selectedFileIndex.val, entries.len)]

    DeepReviewVM(
      store: store,
      hasData: hasData,
      glEmbedded: glEmbedded,
      sessionTitle: sessionTitle,
      commitDisplay: commitDisplay,
      statsText: statsText,
      traceContexts: traceContexts,
      selectedTraceContextId: selectedTraceContextId,
      viewMode: viewMode,
      files: files,
      selectedFileIndex: selectedFileIndex,
      selectedExecutionIndex: selectedExecutionIndex,
      selectedIteration: selectedIteration,
      flowCount: flowCount,
      currentFunctionKey: currentFunctionKey,
      maxIterations: maxIterations,
      unifiedFiles: unifiedFiles,
      callNodes: callNodes,
      selectedHunks: selectedHunks,
      hunkToolbarVisible: hunkToolbarVisible,
      hunkCopyFeedback: hunkCopyFeedback,
      selectedFile: selectedFile,
      fileCount: fileCount,
      disposeProc: dispose,
    )
