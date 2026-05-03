## replay_lifecycle_vm.nim
##
## Small ViewModel for replay operating mode and lifecycle state.
##
## Browser materialized replay, browser MCR replay and streaming recording
## currently share store-level hooks but did not have a headless signal owner.
## This VM captures the platform-neutral state those GUI specs depend on:
## deployment mode, trace kind, source/entry metadata and streaming progress.

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ../store/[replay_data_store, types]

type
  ReplayLifecycleVM* = ref object of ViewModel
    store*: ReplayDataStore

    deploymentMode*: Signal[ReplayDeploymentMode]
    traceKind*: Signal[ReplayTraceKind]
    stage*: Signal[ReplayLifecycleStage]
    sourcePath*: Signal[string]
    entryFunction*: Signal[string]
    expectedStreamingPhases*: Signal[int]
    completedStreamingPhases*: Signal[int]
    errorMessage*: Signal[string]

    isBrowserReplay*: Memo[bool]
    isMaterializedBrowserReplay*: Memo[bool]
    isMcrBrowserReplay*: Memo[bool]
    isStreaming*: Memo[bool]
    isReady*: Memo[bool]
    hasAllStreamingPhases*: Memo[bool]

proc configureReplay*(vm: ReplayLifecycleVM;
                      deploymentMode: ReplayDeploymentMode;
                      traceKind: ReplayTraceKind;
                      sourcePath, entryFunction: string) =
  ## Set immutable-ish replay metadata for the active session.
  vm.deploymentMode.val = deploymentMode
  vm.traceKind.val = traceKind
  vm.sourcePath.val = sourcePath
  vm.entryFunction.val = entryFunction
  vm.errorMessage.val = ""

proc beginLoading*(vm: ReplayLifecycleVM) =
  vm.stage.val = rlsLoadingTrace
  vm.errorMessage.val = ""

proc markBackendReady*(vm: ReplayLifecycleVM) =
  vm.stage.val = rlsBackendReady
  vm.errorMessage.val = ""

proc beginStreaming*(vm: ReplayLifecycleVM; expectedPhases: int) =
  ## Start a streaming recording lifecycle. Negative/zero phase counts are
  ## allowed at the API boundary but treated as "no expected phase target".
  vm.expectedStreamingPhases.val = max(0, expectedPhases)
  vm.completedStreamingPhases.val = 0
  vm.stage.val = rlsStreaming
  vm.errorMessage.val = ""

proc recordStreamingPhase*(vm: ReplayLifecycleVM) =
  let nextCount = vm.completedStreamingPhases.val + 1
  vm.completedStreamingPhases.val = nextCount
  if vm.expectedStreamingPhases.val > 0 and
      nextCount >= vm.expectedStreamingPhases.val:
    vm.stage.val = rlsComplete

proc completeReplay*(vm: ReplayLifecycleVM) =
  vm.stage.val = rlsComplete
  vm.errorMessage.val = ""

proc failReplay*(vm: ReplayLifecycleVM; message: string) =
  vm.stage.val = rlsError
  vm.errorMessage.val = message

proc createReplayLifecycleVM*(store: ReplayDataStore): ReplayLifecycleVM =
  withViewModel proc(dispose: proc()): ReplayLifecycleVM =
    let deploymentMode = createSignal(rdmDesktop)
    let traceKind = createSignal(rtkUnknown)
    let stage = createSignal(rlsIdle)
    let sourcePath = createSignal("")
    let entryFunction = createSignal("")
    let expectedStreamingPhases = createSignal(0)
    let completedStreamingPhases = createSignal(0)
    let errorMessage = createSignal("")

    let isBrowserReplay = createMemo[bool] proc(): bool =
      deploymentMode.val == rdmWeb

    let isMaterializedBrowserReplay = createMemo[bool] proc(): bool =
      deploymentMode.val == rdmWeb and traceKind.val == rtkMaterialized

    let isMcrBrowserReplay = createMemo[bool] proc(): bool =
      deploymentMode.val == rdmWeb and traceKind.val == rtkMcr

    let isStreaming = createMemo[bool] proc(): bool =
      stage.val == rlsStreaming

    let isReady = createMemo[bool] proc(): bool =
      stage.val in {rlsBackendReady, rlsStreaming, rlsComplete}

    let hasAllStreamingPhases = createMemo[bool] proc(): bool =
      let expected = expectedStreamingPhases.val
      expected > 0 and completedStreamingPhases.val >= expected

    ReplayLifecycleVM(
      store: store,
      deploymentMode: deploymentMode,
      traceKind: traceKind,
      stage: stage,
      sourcePath: sourcePath,
      entryFunction: entryFunction,
      expectedStreamingPhases: expectedStreamingPhases,
      completedStreamingPhases: completedStreamingPhases,
      errorMessage: errorMessage,
      isBrowserReplay: isBrowserReplay,
      isMaterializedBrowserReplay: isMaterializedBrowserReplay,
      isMcrBrowserReplay: isMcrBrowserReplay,
      isStreaming: isStreaming,
      isReady: isReady,
      hasAllStreamingPhases: hasAllStreamingPhases,
      disposeProc: dispose,
    )
