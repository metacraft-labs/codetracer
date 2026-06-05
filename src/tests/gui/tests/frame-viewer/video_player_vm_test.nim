## Headless tests for VideoPlayerVM.
##
## Pure state-machine helpers (nextRate / pressFastForward / pressRewind /
## pressTogglePlay / stepFrameDelta) carry the spec rules; we test them
## exhaustively. The integration paths (stepFrame, stepDrawCall, scrubTo)
## delegate to FrameViewerVM and are covered via a fake VisualReplayClient.
##
## Spec: codetracer-specs/GUI/Debugging-Features/Visual-Replay.md

import std/[options, unittest]

import isonim/core/signals
import vm_test_helpers
import viewmodels/frame_viewer_vm
import viewmodels/video_player_vm
import viewmodels/visual_replay_client

# ---------------------------------------------------------------------------
# Pure state-machine helpers — exhaustive coverage of the documented table.
# ---------------------------------------------------------------------------

suite "VideoPlayerVM pure state machine":
  test "nextRate doubles and wraps 8x to 1x":
    check nextRate(Rate1x) == Rate2x
    check nextRate(Rate2x) == Rate4x
    check nextRate(Rate4x) == Rate8x
    check nextRate(Rate8x) == Rate1x

  test "pressFastForward from paused starts at forward 1x":
    let r = pressFastForward(Paused, Forward, Rate4x)
    check r.state == Playing
    check r.direction == Forward
    check r.rate == Rate1x

  test "pressFastForward from playing forward doubles the rate":
    check pressFastForward(Playing, Forward, Rate1x).rate == Rate2x
    check pressFastForward(Playing, Forward, Rate2x).rate == Rate4x
    check pressFastForward(Playing, Forward, Rate4x).rate == Rate8x
    check pressFastForward(Playing, Forward, Rate8x).rate == Rate1x

  test "pressFastForward from playing reverse flips to forward 1x":
    let r = pressFastForward(Playing, Reverse, Rate8x)
    check r.state == Playing
    check r.direction == Forward
    check r.rate == Rate1x

  test "pressRewind from paused starts at reverse 1x":
    let r = pressRewind(Paused, Forward, Rate2x)
    check r.state == Playing
    check r.direction == Reverse
    check r.rate == Rate1x

  test "pressRewind from playing reverse doubles the rate":
    check pressRewind(Playing, Reverse, Rate1x).rate == Rate2x
    check pressRewind(Playing, Reverse, Rate2x).rate == Rate4x
    check pressRewind(Playing, Reverse, Rate4x).rate == Rate8x
    check pressRewind(Playing, Reverse, Rate8x).rate == Rate1x

  test "pressRewind from playing forward flips to reverse 1x":
    let r = pressRewind(Playing, Forward, Rate8x)
    check r.state == Playing
    check r.direction == Reverse
    check r.rate == Rate1x

  test "pressTogglePlay paused resumes at remembered direction and rate":
    let r = pressTogglePlay(Paused, Reverse, Rate4x)
    check r.state == Playing
    check r.direction == Reverse
    check r.rate == Rate4x

  test "pressTogglePlay playing transitions to paused without losing slots":
    let r = pressTogglePlay(Playing, Forward, Rate2x)
    check r.state == Paused
    check r.direction == Forward
    check r.rate == Rate2x

  test "stepFrameDelta clamps to [0, frameCount-1] when frameCount > 0":
    check stepFrameDelta(1, 0, 10) == 1
    check stepFrameDelta(-1, 0, 10) == 0
    check stepFrameDelta(1, 9, 10) == 9
    check stepFrameDelta(-1, 5, 10) == 4
    check stepFrameDelta(-1, 0, 0) == 0
    check stepFrameDelta(1, 7, 0) == 8

# ---------------------------------------------------------------------------
# Integration: VideoPlayerVM driving a real FrameViewerVM with a fake client.
# ---------------------------------------------------------------------------

proc makeMinimalClient(): VisualReplayClient =
  ## A minimal in-memory VisualReplayClient that always succeeds. The
  ## VideoPlayerVM integration tests only care that the right FrameViewerVM
  ## procs get exercised; we don't care about response shapes here.
  let stubFrame = VisualReplayFrame(
    imageSrc: "stub", geid: some(0'u64), frame: some(0),
    width: 64, height: 64,
  )
  VisualReplayClient(
    playerUrl: "http://stub/",
    getInfoProc: proc(): VisualReplayFuture[VisualReplayInfo] =
      newCompletedFuture(VisualReplayInfo(frameCount: 10, width: 64, height: 64)),
    getFrameByGeidProc: proc(geid: uint64): VisualReplayFuture[VisualReplayFrame] =
      newCompletedFuture(stubFrame),
    getFrameByFrameProc: proc(frame: int): VisualReplayFuture[VisualReplayFrame] =
      newCompletedFuture(VisualReplayFrame(
        imageSrc: "frame-" & $frame,
        geid: some(uint64(frame)), frame: some(frame),
        width: 64, height: 64,
      )),
    getFrameByDrawProc: proc(draw: int): VisualReplayFuture[VisualReplayFrame] =
      newCompletedFuture(VisualReplayFrame(
        imageSrc: "draw-" & $draw,
        geid: some(uint64(100 + draw)), frame: some(0),
        width: 64, height: 64,
      )),
    getDrawCallsProc: proc(): VisualReplayFuture[seq[VisualReplayDrawCall]] =
      newCompletedFuture(@[
        VisualReplayDrawCall(index: 0, geid: 0'u64, name: "a", pipeline: ""),
        VisualReplayDrawCall(index: 1, geid: 1'u64, name: "b", pipeline: ""),
        VisualReplayDrawCall(index: 2, geid: 2'u64, name: "c", pipeline: ""),
      ]),
    getPixelHistoryProc: proc(x, y, frame: int):
        VisualReplayFuture[seq[VisualReplayPixelHistoryEntry]] =
      newCompletedFuture(newSeq[VisualReplayPixelHistoryEntry]()),
    getShaderDebugProc: proc(request: VisualReplayShaderDebugRequest):
        VisualReplayFuture[VisualReplayShaderDebugInfo] =
      newCompletedFuture(VisualReplayShaderDebugInfo()),
  )

suite "VideoPlayerVM integration":
  test "fastForward cycles rate then wraps":
    let vm = createVideoPlayerVM(createFrameViewerVM(makeMinimalClient()))
    vm.fastForward()
    check vm.playState.val == Playing
    check vm.direction.val == Forward
    check vm.rate.val == Rate1x
    vm.fastForward()
    check vm.rate.val == Rate2x
    vm.fastForward()
    check vm.rate.val == Rate4x
    vm.fastForward()
    check vm.rate.val == Rate8x
    vm.fastForward()
    check vm.rate.val == Rate1x

  test "rewind flips direction when playing forward":
    let vm = createVideoPlayerVM(createFrameViewerVM(makeMinimalClient()))
    vm.fastForward()
    vm.fastForward()      ## now forward 2x
    check vm.direction.val == Forward
    check vm.rate.val == Rate2x
    vm.rewind()           ## should flip to reverse 1x
    check vm.direction.val == Reverse
    check vm.rate.val == Rate1x

  test "togglePlay pauses, then resumes at the captured rate":
    let vm = createVideoPlayerVM(createFrameViewerVM(makeMinimalClient()))
    vm.fastForward()
    vm.fastForward()      ## forward 2x
    vm.togglePlay()       ## pause
    check vm.playState.val == Paused
    vm.togglePlay()       ## resume
    check vm.playState.val == Playing
    check vm.direction.val == Forward
    check vm.rate.val == Rate2x

  test "stepFrame is a no-op while playing":
    let vm = createVideoPlayerVM(createFrameViewerVM(makeMinimalClient()))
    vm.fastForward()
    let frameBefore = vm.frameVm.currentFrame.val
    vm.stepFrame(1)
    check vm.frameVm.currentFrame.val == frameBefore

  test "stepFrame advances by one when paused":
    let vm = createVideoPlayerVM(createFrameViewerVM(makeMinimalClient()))
    vm.frameVm.frameCount.val = 10
    vm.frameVm.currentFrame.val = 3
    vm.stepFrame(1)
    check vm.frameVm.currentFrame.val == 4

  test "stepFrame clamps at the end of the timeline":
    let vm = createVideoPlayerVM(createFrameViewerVM(makeMinimalClient()))
    vm.frameVm.frameCount.val = 10
    vm.frameVm.currentFrame.val = 9
    vm.stepFrame(1)
    check vm.frameVm.currentFrame.val == 9

  test "jumpToStart and jumpToEnd pause then seek":
    let vm = createVideoPlayerVM(createFrameViewerVM(makeMinimalClient()))
    vm.frameVm.frameCount.val = 10
    vm.fastForward()
    vm.jumpToStart()
    check vm.playState.val == Paused
    check vm.frameVm.currentFrame.val == 0
    vm.jumpToEnd()
    check vm.frameVm.currentFrame.val == 9

  test "picker mode toggles and pauses playback":
    let vm = createVideoPlayerVM(createFrameViewerVM(makeMinimalClient()))
    vm.fastForward()
    check vm.playState.val == Playing
    vm.togglePicker()
    check vm.pickerState.val == PickerActive
    check vm.playState.val == Paused

  test "updateMagnifier converts display coords to source pixels":
    let vm = createVideoPlayerVM(createFrameViewerVM(makeMinimalClient()))
    vm.frameVm.frameWidth.val = 200
    vm.frameVm.frameHeight.val = 100
    vm.enterPickerMode()
    vm.updateMagnifier(50.0, 25.0, 100.0, 50.0)
    check vm.magnifier.val.isSome
    let m = vm.magnifier.val.get
    ## 50 / 100 * 200 = 100; 25 / 50 * 100 = 50
    check m.sourceX == 100
    check m.sourceY == 50

  test "commitPickedPixel uses source coords and exits picker":
    let vm = createVideoPlayerVM(createFrameViewerVM(makeMinimalClient()))
    vm.frameVm.frameWidth.val = 200
    vm.frameVm.frameHeight.val = 100
    vm.enterPickerMode()
    vm.updateMagnifier(50.0, 25.0, 100.0, 50.0)
    vm.commitPickedPixel()
    check vm.pickerState.val == PickerOff
    check vm.frameVm.selectedPixel.val.isSome
    let p = vm.frameVm.selectedPixel.val.get
    check p.x == 100
    check p.y == 50
