## FrameViewerVM — ViewModel for MCR visual replay frames.

import std/[options, strutils]

import isonim/core/[async_compat, signals]
import isonim/viewmodel

import visual_replay_client

type
  FrameViewerPixel* = object
    x*: int
    y*: int

  FrameViewerVM* = ref object of ViewModel
    client*: VisualReplayClient

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
  vm.loading.val = true
  vm.error.val = ""
  vm.currentGeid.val = some(geid)
  let fut = vm.client.getFrameByGeid(geid)
  async_compat.onComplete(fut,
    onSuccess = proc(frame: VisualReplayFrame) =
      vm.setFrame(frame)
      vm.loading.val = false
      vm.loadDrawCalls(),
    onError = proc(message: string) = vm.failFrame(message))

proc loadFrameByIndex*(vm: FrameViewerVM; frame: int) =
  let nextFrame = max(frame, 0)
  vm.loading.val = true
  vm.error.val = ""
  vm.currentFrame.val = nextFrame
  vm.currentGeid.val = none(uint64)
  let fut = vm.client.getFrameByFrame(nextFrame)
  async_compat.onComplete(fut,
    onSuccess = proc(frameData: VisualReplayFrame) =
      vm.setFrame(frameData)
      vm.loading.val = false
      vm.loadDrawCalls(),
    onError = proc(message: string) = vm.failFrame(message))

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
                                playerUrl: string) =
  vm.visualReplayAvailable.val = available
  vm.playerUrl.val = playerUrl
  if not available:
    vm.error.val = "Visual replay is absent for this session."
  elif playerUrl.len == 0:
    vm.error.val = "Visual replay is available, but no player is connected."
  elif vm.error.val.startsWith("Visual replay is"):
    vm.error.val = ""

proc createFrameViewerVM*(client: VisualReplayClient): FrameViewerVM =
  withViewModel proc(dispose: proc()): FrameViewerVM =
    FrameViewerVM(
      client: client,
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
