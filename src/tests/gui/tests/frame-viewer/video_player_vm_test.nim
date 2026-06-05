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

# ---------------------------------------------------------------------------
# Pixel-picker / loupe — M2 deliverables.
# ---------------------------------------------------------------------------

suite "VideoPlayerVM pixel picker":
  test "pixel-picker/edge-clamping — magnifier source coords stay in-bounds at all four corners":
    ## Spec (Visual-Replay.md §Loupe Specification): "when the cursor is
    ## within five source pixels of the frame edge, the loupe samples are
    ## clamped … and the centre marker stays under the cursor."
    ## The VM is responsible for the clamp; out-of-bounds *sample* fill is
    ## the JS render routine's job (and is exercised by the playwright
    ## suite once it lands in M2).
    let vm = createVideoPlayerVM(createFrameViewerVM(makeMinimalClient()))
    let w = 320
    let h = 240
    vm.frameVm.frameWidth.val = w
    vm.frameVm.frameHeight.val = h
    vm.enterPickerMode()

    ## Top-left corner (0, 0): cursor coordinate maps exactly to source (0,0).
    vm.updateMagnifier(0.0, 0.0, float(w), float(h))
    check vm.magnifier.val.isSome
    let tl = vm.magnifier.val.get
    check tl.sourceX == 0
    check tl.sourceY == 0
    check tl.sourceX >= 0
    check tl.sourceY >= 0
    check tl.sourceX <= w - 1
    check tl.sourceY <= h - 1

    ## Top-right corner (W-1, 0): cursor at right edge of display rect.
    vm.updateMagnifier(float(w) - 0.001, 0.0, float(w), float(h))
    check vm.magnifier.val.isSome
    let tr = vm.magnifier.val.get
    check tr.sourceX == w - 1
    check tr.sourceY == 0
    check tr.sourceX <= w - 1
    check tr.sourceY >= 0

    ## Bottom-left corner (0, H-1).
    vm.updateMagnifier(0.0, float(h) - 0.001, float(w), float(h))
    check vm.magnifier.val.isSome
    let bl = vm.magnifier.val.get
    check bl.sourceX == 0
    check bl.sourceY == h - 1
    check bl.sourceX >= 0
    check bl.sourceY <= h - 1

    ## Bottom-right corner (W-1, H-1).
    vm.updateMagnifier(float(w) - 0.001, float(h) - 0.001, float(w), float(h))
    check vm.magnifier.val.isSome
    let br = vm.magnifier.val.get
    check br.sourceX == w - 1
    check br.sourceY == h - 1

    ## Past-edge cursor (should still clamp instead of yielding negatives or
    ## values past the frame extents — defends against fractional rounding in
    ## the JS bridge and against future regressions of the int truncation).
    vm.updateMagnifier(-5.0, -5.0, float(w), float(h))
    check vm.magnifier.val.isSome
    let neg = vm.magnifier.val.get
    check neg.sourceX >= 0
    check neg.sourceY >= 0

    vm.updateMagnifier(float(w) + 50.0, float(h) + 50.0, float(w), float(h))
    check vm.magnifier.val.isSome
    let over = vm.magnifier.val.get
    check over.sourceX <= w - 1
    check over.sourceY <= h - 1

  test "pixel-picker/loupe-coordinates — mapping is invariant under canvas resize":
    ## Spec: pixel-picker/loupe-coordinates — "source-pixel coordinates
    ## remain correct under arbitrary canvas zoom (window resizing)."
    let vm = createVideoPlayerVM(createFrameViewerVM(makeMinimalClient()))
    vm.frameVm.frameWidth.val = 200
    vm.frameVm.frameHeight.val = 100
    vm.enterPickerMode()

    ## Cursor at (75, 25) on a 150×50 canvas → 75/150*200 = 100, 25/50*100 = 50.
    vm.updateMagnifier(75.0, 25.0, 150.0, 50.0)
    check vm.magnifier.val.isSome
    let small = vm.magnifier.val.get
    check small.sourceX == 100
    check small.sourceY == 50

    ## Same cursor coordinates on a 300×100 canvas → 75/300*200 = 50,
    ## 25/100*100 = 25. The display coords are identical but the source
    ## coords have to halve because the canvas doubled.
    vm.updateMagnifier(75.0, 25.0, 300.0, 100.0)
    check vm.magnifier.val.isSome
    let big = vm.magnifier.val.get
    check big.sourceX == 50
    check big.sourceY == 25

    ## And a non-uniform stretch (canvas wider in X than tall): mapping
    ## treats X and Y independently.
    vm.updateMagnifier(400.0, 25.0, 800.0, 50.0)
    check vm.magnifier.val.isSome
    let stretched = vm.magnifier.val.get
    check stretched.sourceX == 100
    check stretched.sourceY == 50

  test "pixel-picker/escape-cancels-via-vm — cancelPicker exits without committing":
    ## VM-level hook for the DOM Escape handler. The DOM-side wiring lives
    ## in installEscapeHandler (isonim_video_player_view.nim) and is covered
    ## by the playwright spec; this test pins the VM contract.
    let vm = createVideoPlayerVM(createFrameViewerVM(makeMinimalClient()))
    vm.frameVm.frameWidth.val = 64
    vm.frameVm.frameHeight.val = 64
    vm.enterPickerMode()
    vm.updateMagnifier(10.0, 10.0, 64.0, 64.0)
    check vm.pickerState.val == PickerActive
    check vm.magnifier.val.isSome
    let beforePixel = vm.frameVm.selectedPixel.val
    vm.cancelPicker()
    check vm.pickerState.val == PickerOff
    check vm.magnifier.val.isNone
    check vm.magnifierCenterColor.val.isNone
    ## Cancel must not commit a pixel selection.
    check vm.frameVm.selectedPixel.val == beforePixel

  test "pixel-picker/escape-cancels-via-vm — cancelPicker is a no-op when picker is inactive":
    ## A defensive contract for the global key handler: invoking cancel
    ## while picker mode is off must not perturb other VM state.
    let vm = createVideoPlayerVM(createFrameViewerVM(makeMinimalClient()))
    let stateBefore = vm.pickerState.val
    let magBefore = vm.magnifier.val
    let colorBefore = vm.magnifierCenterColor.val
    vm.cancelPicker()
    check vm.pickerState.val == stateBefore
    check vm.magnifier.val == magBefore
    check vm.magnifierCenterColor.val == colorBefore

  test "pixel-picker/auto-pause — entering picker mode preserves resume state":
    ## M2 deliverable: "verify the existing behaviour and ensure the
    ## resume-state (direction, rate) is correctly preserved so M1's
    ## togglePlay-after-cancel still works."
    let vm = createVideoPlayerVM(createFrameViewerVM(makeMinimalClient()))
    vm.fastForward()              ## forward 1x
    vm.fastForward()              ## forward 2x
    check vm.playState.val == Playing
    check vm.direction.val == Forward
    check vm.rate.val == Rate2x
    vm.enterPickerMode()          ## must auto-pause
    check vm.pickerState.val == PickerActive
    check vm.playState.val == Paused
    ## Cancelling and resuming via togglePlay must return us to forward 2x.
    vm.cancelPicker()
    vm.togglePlay()
    check vm.playState.val == Playing
    check vm.direction.val == Forward
    check vm.rate.val == Rate2x

  test "video-player/keyboard-dispatch — every action routes onto a VM proc":
    ## M4 deliverable: ``dispatchVideoPlayerAction`` is the pure routing
    ## layer for ClientAction.videoPlayerXxx → VideoPlayerVM proc.  Exercise
    ## every variant so the wiring stays comprehensive across refactors.
    ## Spec: codetracer-specs/GUI/Debugging-Features/Visual-Replay.md
    ## §Keyboard Shortcuts.
    let vm = createVideoPlayerVM(createFrameViewerVM(makeMinimalClient()))
    vm.frameVm.frameCount.val = 10
    vm.frameVm.currentFrame.val = 5

    check dispatchVideoPlayerAction(vm, VpaTogglePlay)
    check vm.playState.val == Playing
    check dispatchVideoPlayerAction(vm, VpaTogglePlay)
    check vm.playState.val == Paused

    check dispatchVideoPlayerAction(vm, VpaFastForward)
    check vm.playState.val == Playing
    check vm.direction.val == Forward
    check vm.rate.val == Rate1x
    check dispatchVideoPlayerAction(vm, VpaFastForward)
    check vm.rate.val == Rate2x

    check dispatchVideoPlayerAction(vm, VpaRewind)
    check vm.direction.val == Reverse
    check vm.rate.val == Rate1x

    ## Step actions are no-ops while playing (per spec).  Pause first.
    vm.togglePlay()                    ## now paused
    check vm.playState.val == Paused
    vm.frameVm.currentFrame.val = 5
    check dispatchVideoPlayerAction(vm, VpaStepFrameForward)
    check vm.frameVm.currentFrame.val == 6
    check dispatchVideoPlayerAction(vm, VpaStepFrameBack)
    check vm.frameVm.currentFrame.val == 5

    ## Draw stepping delegates to FrameViewerVM.loadFrameForDraw.  We can't
    ## inspect the request stream cheaply, but the call must not raise.
    check dispatchVideoPlayerAction(vm, VpaStepDrawForward)
    check dispatchVideoPlayerAction(vm, VpaStepDrawBack)

    check dispatchVideoPlayerAction(vm, VpaJumpStart)
    check vm.frameVm.currentFrame.val == 0
    check dispatchVideoPlayerAction(vm, VpaJumpEnd)
    check vm.frameVm.currentFrame.val == 9

    check dispatchVideoPlayerAction(vm, VpaTogglePicker)
    check vm.pickerState.val == PickerActive
    check dispatchVideoPlayerAction(vm, VpaTogglePicker)
    check vm.pickerState.val == PickerOff

  test "video-player/keyboard-dispatch — CancelPicker falls through when picker is off":
    ## Spec contract: ``VideoPlayerCancelPicker`` must NOT consume Escape
    ## when picker mode is inactive — the dispatcher returns ``false`` so
    ## the shortcuts overlay can fall through to ``aEscape`` (active focus
    ## onEscape, modal dismiss, etc.).
    let vm = createVideoPlayerVM(createFrameViewerVM(makeMinimalClient()))
    check vm.pickerState.val == PickerOff
    check not dispatchVideoPlayerAction(vm, VpaCancelPicker)
    check vm.pickerState.val == PickerOff
    ## Entering picker mode and cancelling consumes the key (returns true).
    vm.enterPickerMode()
    check vm.pickerState.val == PickerActive
    check dispatchVideoPlayerAction(vm, VpaCancelPicker)
    check vm.pickerState.val == PickerOff
    ## Second cancel returns to fall-through behaviour.
    check not dispatchVideoPlayerAction(vm, VpaCancelPicker)

  test "video-player/keyboard-dispatch — nil VM is a safe no-op fall-through":
    ## Defensive contract for the global handler: pressing a player key
    ## before the panel mounts (or after it is disposed) must not crash
    ## and must report the key as not-consumed so the binding falls
    ## through to whatever else might handle it.
    let nilVm: VideoPlayerVM = nil
    for action in VideoPlayerAction:
      check not dispatchVideoPlayerAction(nilVm, action)

  test "video-player/action-name-parser — known names map, unknown rejected":
    ## The Playwright test hook exposes string names; verify the parser
    ## covers every spec-defined entry verbatim.
    check parseVideoPlayerActionName("VideoPlayerTogglePlay") ==
      some(VpaTogglePlay)
    check parseVideoPlayerActionName("VideoPlayerFastForward") ==
      some(VpaFastForward)
    check parseVideoPlayerActionName("VideoPlayerCancelPicker") ==
      some(VpaCancelPicker)
    check parseVideoPlayerActionName("Bogus").isNone
    check parseVideoPlayerActionName("").isNone

  test "pixel-picker/centre-color-tracks-magnifier — signal is settable as the JS bridge does":
    ## Centre-color sampling happens in JS via canvas reads; here we
    ## simulate the bridge by setting the signal directly and verify it
    ## clears when picker mode exits.
    let vm = createVideoPlayerVM(createFrameViewerVM(makeMinimalClient()))
    vm.frameVm.frameWidth.val = 16
    vm.frameVm.frameHeight.val = 16
    vm.enterPickerMode()
    vm.updateMagnifier(8.0, 8.0, 16.0, 16.0)
    ## Bridge would compute and assign these values:
    let known = VisualReplayPixelColor(r: 0.94, g: 0.71, b: 0.13, a: 1.0)
    vm.magnifierCenterColor.val = some(known)
    check vm.magnifierCenterColor.val.isSome
    check vm.magnifierCenterColor.val.get == known
    ## Cancelling picker mode clears the cached color so the next entry
    ## starts blank (otherwise the loupe would flash stale RGBA before the
    ## first mousemove).
    vm.cancelPicker()
    check vm.magnifierCenterColor.val.isNone
