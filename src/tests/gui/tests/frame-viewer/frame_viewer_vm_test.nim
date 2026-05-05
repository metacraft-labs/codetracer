## Headless tests for FrameViewerVM.

import std/[options, unittest]

import isonim/core/signals
import isonim/viewmodel
import vm_test_helpers
import viewmodels/frame_viewer_vm
import viewmodels/visual_replay_client

type
  FakeVisualReplayClient = ref object
    client: VisualReplayClient
    geidRequests: seq[uint64]
    frameRequests: seq[int]
    drawCallRequests: int
    failFrames: bool

proc makeFakeClient(): FakeVisualReplayClient =
  result = FakeVisualReplayClient()
  let fake = result
  fake.client = VisualReplayClient(
    playerUrl: "http://player.test/",
    getInfoProc: proc(): VisualReplayFuture[VisualReplayInfo] =
      newCompletedFuture(VisualReplayInfo(frameCount: 4, width: 320, height: 200)),
    getFrameByGeidProc: proc(geid: uint64): VisualReplayFuture[VisualReplayFrame] =
      fake.geidRequests.add(geid)
      if fake.failFrames:
        return newFailedFuture[VisualReplayFrame]("player failed")
      newCompletedFuture(VisualReplayFrame(
        imageSrc: "frame-geid-" & $geid,
        geid: some(geid),
        frame: some(2),
        width: 320,
        height: 200,
      )),
    getFrameByFrameProc: proc(frame: int): VisualReplayFuture[VisualReplayFrame] =
      fake.frameRequests.add(frame)
      if fake.failFrames:
        return newFailedFuture[VisualReplayFrame]("frame failed")
      newCompletedFuture(VisualReplayFrame(
        imageSrc: "frame-index-" & $frame,
        geid: some(uint64(100 + frame)),
        frame: some(frame),
        width: 320,
        height: 200,
      )),
    getDrawCallsProc: proc(): VisualReplayFuture[seq[VisualReplayDrawCall]] =
      inc fake.drawCallRequests
      newCompletedFuture(@[
        VisualReplayDrawCall(index: 0, geid: 100'u64,
                             name: "glClear", pipeline: "clear"),
        VisualReplayDrawCall(index: 1, geid: 101'u64,
                             name: "glDrawElements", pipeline: "mesh"),
      ]),
  )

suite "VisualReplayClient URL construction":
  test "constructs player endpoint URLs":
    check infoUrl("http://localhost:9000/") == "http://localhost:9000/info"
    check frameByGeidUrl("http://localhost:9000/", 42'u64) ==
      "http://localhost:9000/frame?geid=42"
    check frameByFrameUrl("http://localhost:9000/", 3) ==
      "http://localhost:9000/frame?frame=3"
    check drawCallsUrl("http://localhost:9000/") ==
      "http://localhost:9000/draw-calls"

suite "FrameViewerVM frame loading":
  test "fetches frame for GEID and updates draw calls":
    let fake = makeFakeClient()
    let vm = createFrameViewerVM(fake.client)

    vm.loadFrameForGeid(42'u64)
    drain()
    drain()

    check fake.geidRequests == @[42'u64]
    check vm.currentGeid.val == some(42'u64)
    check vm.currentFrame.val == 2
    check vm.frameImageSrc.val == "frame-geid-42"
    check vm.loading.val == false
    check vm.error.val == ""
    check fake.drawCallRequests == 1
    check vm.drawCalls.val.len == 2

    vm.dispose()

  test "switches by frame index and clears GEID before response":
    let fake = makeFakeClient()
    let vm = createFrameViewerVM(fake.client)

    vm.loadFrameForGeid(42'u64)
    drain()
    vm.loadFrameByIndex(3)
    drain()
    drain()

    check fake.frameRequests == @[3]
    check vm.currentFrame.val == 3
    check vm.currentGeid.val == some(103'u64)
    check vm.frameImageSrc.val == "frame-index-3"
    check vm.loading.val == false

    vm.dispose()

  test "handles player errors and clears stale frame data":
    let fake = makeFakeClient()
    let vm = createFrameViewerVM(fake.client)

    vm.loadFrameByIndex(1)
    drain()
    check vm.frameImageSrc.val == "frame-index-1"

    fake.failFrames = true
    vm.loadFrameByIndex(2)
    drain()

    check vm.loading.val == false
    check vm.error.val == "frame failed"
    check vm.frameImageSrc.val == ""
    check vm.drawCalls.val.len == 0
    check vm.selectedDrawCall.val.isNone

    vm.dispose()

suite "FrameViewerVM selection":
  test "maps rendered pixel coordinates into image pixel coordinates":
    let fake = makeFakeClient()
    let vm = createFrameViewerVM(fake.client)
    vm.frameWidth.val = 320
    vm.frameHeight.val = 200

    vm.selectPixelFromRenderedPoint(80.0, 50.0, 160.0, 100.0)

    check vm.selectedPixel.val.isSome
    check vm.selectedPixel.val.get.x == 160
    check vm.selectedPixel.val.get.y == 100

    vm.selectPixelFromRenderedPoint(0.0, 0.0, 0.0, 100.0)
    check vm.selectedPixel.val.isNone

    vm.dispose()

  test "selects and clears draw calls by index":
    let fake = makeFakeClient()
    let vm = createFrameViewerVM(fake.client)

    vm.loadDrawCalls()
    drain()
    vm.selectDrawCall(1)
    check vm.selectedDrawCall.val == some(1)

    vm.selectDrawCall(99)
    check vm.selectedDrawCall.val.isNone

    vm.dispose()
