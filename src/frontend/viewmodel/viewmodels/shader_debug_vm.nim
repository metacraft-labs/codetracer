## ShaderDebugVM — ViewModel for visual replay shader interpreter traces.

import std/options

import isonim/core/[async_compat, signals]
import isonim/viewmodel

import ../store/replay_data_store
import visual_replay_client

type
  ShaderDebugVM* = ref object of ViewModel
    client*: VisualReplayClient
    store*: ReplayDataStore
    requestSerial: int

    selectedContext*: Signal[Option[VisualReplayShaderDebugRequest]]
    debugInfo*: Signal[Option[VisualReplayShaderDebugInfo]]
    currentStepIndex*: Signal[int]
    loading*: Signal[bool]
    error*: Signal[string]
    onDebugLoaded*: proc(error: string; loading: bool)
    onStepChanged*: proc(stepIndex: int)

proc beginLoad(vm: ShaderDebugVM): int =
  inc vm.requestSerial
  result = vm.requestSerial
  vm.loading.val = true
  vm.error.val = ""
  vm.debugInfo.val = none(VisualReplayShaderDebugInfo)
  vm.currentStepIndex.val = 0

proc clampStep(vm: ShaderDebugVM; index: int): int =
  if vm.debugInfo.val.isNone or vm.debugInfo.val.get.steps.len == 0:
    return 0
  max(0, min(index, vm.debugInfo.val.get.steps.len - 1))

proc currentStep*(vm: ShaderDebugVM): Option[VisualReplayShaderStep] =
  if vm.debugInfo.val.isNone:
    return none(VisualReplayShaderStep)
  let info = vm.debugInfo.val.get
  if info.steps.len == 0:
    return none(VisualReplayShaderStep)
  some(info.steps[vm.clampStep(vm.currentStepIndex.val)])

proc currentSourceLine*(vm: ShaderDebugVM): int =
  let step = vm.currentStep()
  if step.isSome:
    step.get.sourceLine
  else:
    0

proc loadShaderDebug*(vm: ShaderDebugVM;
                      request: VisualReplayShaderDebugRequest) =
  let normalized = VisualReplayShaderDebugRequest(
    x: max(request.x, 0),
    y: max(request.y, 0),
    frame: request.frame,
    geid: request.geid,
    drawCallIndex: request.drawCallIndex,
    fragmentIndex: request.fragmentIndex,
    primitiveId: request.primitiveId)
  let serial = vm.beginLoad()
  vm.selectedContext.val = some(normalized)
  let fut = vm.client.getShaderDebug(normalized)
  async_compat.onComplete(fut,
    onSuccess = proc(info: VisualReplayShaderDebugInfo) =
      if serial != vm.requestSerial:
        return
      vm.debugInfo.val = some(info)
      vm.currentStepIndex.val = 0
      vm.loading.val = false
      if not vm.onDebugLoaded.isNil:
        vm.onDebugLoaded("", false),
    onError = proc(message: string) =
      if serial == vm.requestSerial:
        vm.loading.val = false
        vm.error.val = message
        vm.debugInfo.val = none(VisualReplayShaderDebugInfo)
        if not vm.onDebugLoaded.isNil:
          vm.onDebugLoaded(message, false))

proc loadFromPixel*(vm: ShaderDebugVM; x, y, frame: int;
                    geid: Option[uint64] = none(uint64)) =
  vm.loadShaderDebug(VisualReplayShaderDebugRequest(
    x: x,
    y: y,
    frame: some(max(frame, 0)),
    geid: geid,
    drawCallIndex: none(int),
    fragmentIndex: none(int),
    primitiveId: none(int)))

proc loadFromPixelHistoryEntry*(vm: ShaderDebugVM; x, y, frame: int;
                                entry: VisualReplayPixelHistoryEntry) =
  vm.loadShaderDebug(VisualReplayShaderDebugRequest(
    x: x,
    y: y,
    frame: some(max(frame, 0)),
    geid: some(entry.geid),
    drawCallIndex: some(entry.drawCallIndex),
    fragmentIndex: some(entry.fragmentIndex),
    primitiveId: some(entry.primitiveId)))

proc stepForward*(vm: ShaderDebugVM) =
  vm.currentStepIndex.val = vm.clampStep(vm.currentStepIndex.val + 1)
  if not vm.onStepChanged.isNil:
    vm.onStepChanged(vm.currentStepIndex.val)

proc stepBackward*(vm: ShaderDebugVM) =
  vm.currentStepIndex.val = vm.clampStep(vm.currentStepIndex.val - 1)
  if not vm.onStepChanged.isNil:
    vm.onStepChanged(vm.currentStepIndex.val)

proc stepFirst*(vm: ShaderDebugVM) =
  vm.currentStepIndex.val = vm.clampStep(0)
  if not vm.onStepChanged.isNil:
    vm.onStepChanged(vm.currentStepIndex.val)

proc stepLast*(vm: ShaderDebugVM) =
  if vm.debugInfo.val.isSome:
    vm.currentStepIndex.val = vm.clampStep(vm.debugInfo.val.get.steps.len - 1)
  else:
    vm.currentStepIndex.val = 0
  if not vm.onStepChanged.isNil:
    vm.onStepChanged(vm.currentStepIndex.val)

proc bindReplayStore*(vm: ShaderDebugVM; store: ReplayDataStore) =
  if store.isNil or vm.store == store:
    return
  vm.store = store

proc createShaderDebugVM*(client: VisualReplayClient;
                          store: ReplayDataStore = nil): ShaderDebugVM =
  withViewModel proc(dispose: proc()): ShaderDebugVM =
    let vm = ShaderDebugVM(
      client: client,
      selectedContext: createSignal(none(VisualReplayShaderDebugRequest)),
      debugInfo: createSignal(none(VisualReplayShaderDebugInfo)),
      currentStepIndex: createSignal(0),
      loading: createSignal(false),
      error: createSignal(""),
      disposeProc: dispose,
    )
    vm.bindReplayStore(store)
    vm
