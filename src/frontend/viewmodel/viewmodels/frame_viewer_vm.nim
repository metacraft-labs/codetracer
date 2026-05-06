## FrameViewerVM — ViewModel for MCR visual replay frames.

import std/[options, strutils]

import isonim/core/[async_compat, computation, graph, owner, signals]
import isonim/viewmodel

import ../store/replay_data_store
import visual_replay_client

type
  FrameViewerPixel* = object
    x*: int
    y*: int

  FrameViewerPixelSelectionHandler* = proc(x, y, frame: int;
                                           geid: Option[uint64])

  FrameViewerVM* = ref object of ViewModel
    client*: VisualReplayClient
    store*: ReplayDataStore
    reactiveOwner: OwnerBase
    frameRequestSerial: int
    lastStoreGeid: Option[uint64]

    visualReplayAvailable*: Signal[bool]
    playerUrl*: Signal[string]
    currentGeid*: Signal[Option[uint64]]
    currentFrame*: Signal[int]
    frameCount*: Signal[int]
    frameImageSrc*: Signal[string]
    frameWidth*: Signal[int]
    frameHeight*: Signal[int]
    loading*: Signal[bool]
    error*: Signal[string]
    selectedPixel*: Signal[Option[FrameViewerPixel]]
    drawCalls*: Signal[seq[VisualReplayDrawCall]]
    selectedDrawCall*: Signal[Option[int]]
    onPixelSelected*: FrameViewerPixelSelectionHandler

proc setFrame(vm: FrameViewerVM; frame: VisualReplayFrame) =
  vm.frameImageSrc.val = frame.imageSrc
  vm.frameWidth.val = frame.width
  vm.frameHeight.val = frame.height
  if frame.geid.isSome:
    vm.currentGeid.val = frame.geid
  if frame.frame.isSome:
    vm.currentFrame.val = frame.frame.get

proc failFrame(vm: FrameViewerVM; message: string) =
  vm.loading.val = false
  vm.error.val = message
  vm.frameImageSrc.val = ""
  vm.drawCalls.val = @[]
  vm.selectedDrawCall.val = none(int)

proc beginFrameLoad(vm: FrameViewerVM): int =
  inc vm.frameRequestSerial
  result = vm.frameRequestSerial
  vm.loading.val = true
  vm.error.val = ""
  vm.frameImageSrc.val = ""

proc isCurrentFrameRequest(vm: FrameViewerVM; serial: int): bool =
  serial == vm.frameRequestSerial

proc loadDrawCalls*(vm: FrameViewerVM) =
  let fut = vm.client.getDrawCalls()
  async_compat.onComplete(fut,
    onSuccess = proc(calls: seq[VisualReplayDrawCall]) =
      vm.drawCalls.val = calls
      if vm.selectedDrawCall.val.isSome and
          vm.selectedDrawCall.val.get >= calls.len:
        vm.selectedDrawCall.val = none(int),
    onError = proc(message: string) =
      vm.error.val = message
      vm.drawCalls.val = @[]
      vm.selectedDrawCall.val = none(int))

proc loadFrameForGeid*(vm: FrameViewerVM; geid: uint64) =
  let serial = vm.beginFrameLoad()
  vm.currentGeid.val = some(geid)
  let fut = vm.client.getFrameByGeid(geid)
  async_compat.onComplete(fut,
    onSuccess = proc(frame: VisualReplayFrame) =
      if not vm.isCurrentFrameRequest(serial):
        return
      vm.setFrame(frame)
      vm.loading.val = false
      vm.loadDrawCalls(),
    onError = proc(message: string) =
      if vm.isCurrentFrameRequest(serial):
        vm.failFrame(message))

proc loadFrameByIndex*(vm: FrameViewerVM; frame: int) =
  let nextFrame = max(frame, 0)
  let serial = vm.beginFrameLoad()
  vm.currentFrame.val = nextFrame
  vm.currentGeid.val = none(uint64)
  let fut = vm.client.getFrameByFrame(nextFrame)
  async_compat.onComplete(fut,
    onSuccess = proc(frameData: VisualReplayFrame) =
      if not vm.isCurrentFrameRequest(serial):
        return
      vm.setFrame(frameData)
      vm.loading.val = false
      vm.loadDrawCalls(),
    onError = proc(message: string) =
      if vm.isCurrentFrameRequest(serial):
        vm.failFrame(message))

proc loadFrameForDraw*(vm: FrameViewerVM; draw: int;
                       seekSource: bool = false;
                       sourceGeid: Option[uint64] = none(uint64)) =
  let nextDraw = max(draw, 0)
  let serial = vm.beginFrameLoad()
  vm.selectedDrawCall.val = some(nextDraw)
  if sourceGeid.isSome:
    vm.lastStoreGeid = sourceGeid
  let fut = vm.client.getFrameByDraw(nextDraw)
  async_compat.onComplete(fut,
    onSuccess = proc(frame: VisualReplayFrame) =
      if not vm.isCurrentFrameRequest(serial):
        return
      vm.setFrame(frame)
      vm.loading.val = false
      if seekSource and not vm.store.isNil:
        let targetGeid =
          if sourceGeid.isSome: sourceGeid
          else: frame.geid
        if targetGeid.isSome:
          vm.lastStoreGeid = targetGeid
          vm.store.requestSeekToGeid(targetGeid.get)
      vm.loadDrawCalls(),
    onError = proc(message: string) =
      if vm.isCurrentFrameRequest(serial):
        vm.failFrame(message))

proc loadInfo*(vm: FrameViewerVM) =
  let fut = vm.client.getInfo()
  async_compat.onComplete(fut,
    onSuccess = proc(info: VisualReplayInfo) =
      vm.frameCount.val = info.frameCount
      if vm.frameWidth.val == 0: vm.frameWidth.val = info.width
      if vm.frameHeight.val == 0: vm.frameHeight.val = info.height,
    onError = proc(message: string) = vm.error.val = message)

proc selectPixel*(vm: FrameViewerVM; x, y: int) =
  let clampedX = max(0, min(x, max(vm.frameWidth.val - 1, 0)))
  let clampedY = max(0, min(y, max(vm.frameHeight.val - 1, 0)))
  vm.selectedPixel.val = some(FrameViewerPixel(x: clampedX, y: clampedY))
  if not vm.onPixelSelected.isNil:
    vm.onPixelSelected(clampedX, clampedY, vm.currentFrame.val, vm.currentGeid.val)

proc selectPixelFromRenderedPoint*(vm: FrameViewerVM;
                                   renderedX, renderedY: float;
                                   renderedWidth, renderedHeight: float) =
  if renderedWidth <= 0 or renderedHeight <= 0 or
      vm.frameWidth.val <= 0 or vm.frameHeight.val <= 0:
    vm.selectedPixel.val = none(FrameViewerPixel)
    return
  let px = int(renderedX / renderedWidth * float(vm.frameWidth.val))
  let py = int(renderedY / renderedHeight * float(vm.frameHeight.val))
  vm.selectPixel(px, py)

proc selectDrawCall*(vm: FrameViewerVM; index: int) =
  if index >= 0 and index < vm.drawCalls.val.len:
    vm.selectedDrawCall.val = some(index)
  else:
    vm.selectedDrawCall.val = none(int)

proc scrubToDrawCall*(vm: FrameViewerVM; index: int; seekSource = true) =
  if index >= 0 and index < vm.drawCalls.val.len:
    let call = vm.drawCalls.val[index]
    vm.loadFrameForDraw(call.index, seekSource = seekSource,
                        sourceGeid = some(call.geid))
  else:
    vm.selectedDrawCall.val = none(int)

proc nextFrame*(vm: FrameViewerVM) =
  let limit = vm.frameCount.val
  let nextValue =
    if limit > 0: min(vm.currentFrame.val + 1, limit - 1)
    else: vm.currentFrame.val + 1
  vm.loadFrameByIndex(nextValue)

proc previousFrame*(vm: FrameViewerVM) =
  vm.loadFrameByIndex(max(vm.currentFrame.val - 1, 0))

proc setVisualReplayConnection*(vm: FrameViewerVM;
                                available: bool;
                                playerUrl: string;
                                errorMessage = "") =
  vm.visualReplayAvailable.val = available
  vm.playerUrl.val = playerUrl
  if not available:
    vm.error.val = "Visual replay is absent for this session."
  elif errorMessage.len > 0:
    vm.error.val = errorMessage
  elif playerUrl.len == 0:
    vm.error.val = "Visual replay is available, but no player is connected."
  elif vm.error.val.startsWith("Visual replay is"):
    vm.error.val = ""

proc bindReplayStore*(vm: FrameViewerVM; store: ReplayDataStore) =
  if store.isNil or vm.store == store:
    return
  vm.store = store
  let boundStore = store

  proc attachEffect() =
    createEffect proc() =
      let geid = boundStore.currentGeid.val
      if vm.store == boundStore and geid.isSome and vm.lastStoreGeid != geid:
        vm.lastStoreGeid = geid
        vm.loadFrameForGeid(geid.get)

  if vm.reactiveOwner.isNil:
    attachEffect()
  else:
    runWithOwner(vm.reactiveOwner, attachEffect)

proc createFrameViewerVM*(client: VisualReplayClient;
                          store: ReplayDataStore = nil): FrameViewerVM =
  withViewModel proc(dispose: proc()): FrameViewerVM =
    let vm = FrameViewerVM(
      client: client,
      reactiveOwner: getOwner(),
      visualReplayAvailable: createSignal(false),
      playerUrl: createSignal(client.playerUrl),
      currentGeid: createSignal(none(uint64)),
      currentFrame: createSignal(0),
      frameCount: createSignal(0),
      frameImageSrc: createSignal(""),
      frameWidth: createSignal(0),
      frameHeight: createSignal(0),
      loading: createSignal(false),
      error: createSignal(""),
      selectedPixel: createSignal(none(FrameViewerPixel)),
      drawCalls: createSignal(newSeq[VisualReplayDrawCall]()),
      selectedDrawCall: createSignal(none(int)),
      disposeProc: dispose,
    )
    vm.bindReplayStore(store)
    vm
