## VideoPlayerVM — playback chrome over the visual replay frame viewer.
##
## Owns playback state (play / pause, rate, direction, target frame), the
## pixel-picker toggle, and the magnifier cursor position. Frame fetching and
## image-source signals stay on the underlying FrameViewerVM, which already
## coalesces requests through its serial counter.
##
## The playback state machine is split out into pure helpers so it can be
## unit-tested without a DOM. See video_player_vm_test.nim.
##
## Spec: codetracer-specs/GUI/Debugging-Features/Visual-Replay.md
## Milestones: codetracer-specs/GUI/Debugging-Features/Visual-Replay.milestones.org

import std/options

import isonim/core/[graph, owner, signals]
import isonim/viewmodel

import frame_viewer_vm
import visual_replay_client

type
  VideoPlayerDirection* = enum
    Forward, Reverse

  VideoPlayerPlayState* = enum
    Paused, Playing

  ## Playback rate — restricted to the documented 1× / 2× / 4× / 8× cycle.
  VideoPlayerRate* = enum
    Rate1x = 1
    Rate2x = 2
    Rate4x = 4
    Rate8x = 8

  VideoPlayerPickerState* = enum
    PickerOff, PickerActive

  MagnifierPosition* = object
    ## Cursor position used to drive the loupe overlay. Coordinates are in
    ## *source pixel* space (not display space) so the loupe samples the same
    ## pixels regardless of canvas zoom.
    sourceX*: int
    sourceY*: int
    ## Display-space coordinates for positioning the loupe DOM overlay.
    displayX*: float
    displayY*: float

  VideoPlayerVM* = ref object of ViewModel
    frameVm*: FrameViewerVM
    reactiveOwner: OwnerBase

    playState*: Signal[VideoPlayerPlayState]
    direction*: Signal[VideoPlayerDirection]
    rate*: Signal[VideoPlayerRate]
    ## Direction + rate to resume to when togglePlay is pressed from paused.
    ## Reset to (Forward, Rate1x) for a fresh session.
    resumeDirection: VideoPlayerDirection
    resumeRate: VideoPlayerRate

    pickerState*: Signal[VideoPlayerPickerState]
    magnifier*: Signal[Option[MagnifierPosition]]

    bufferingDegraded*: Signal[bool]

# ---------------------------------------------------------------------------
# Pure state-machine helpers (no I/O, no signals — easy to unit-test).
# ---------------------------------------------------------------------------

proc nextRate*(rate: VideoPlayerRate): VideoPlayerRate =
  ## Double the rate, wrapping 8× back to 1× as documented in Visual-Replay.md.
  case rate
  of Rate1x: Rate2x
  of Rate2x: Rate4x
  of Rate4x: Rate8x
  of Rate8x: Rate1x

proc pressFastForward*(
    state: VideoPlayerPlayState;
    direction: VideoPlayerDirection;
    rate: VideoPlayerRate):
    tuple[state: VideoPlayerPlayState; direction: VideoPlayerDirection;
          rate: VideoPlayerRate] =
  ## Compute the next (state, direction, rate) tuple after a Fast-Forward press.
  ##
  ## Rules (Visual-Replay.md §Playback State Machine):
  ## - From paused → play forward 1×.
  ## - From playing forward → double the rate (wrapping 8× → 1×).
  ## - From playing reverse → flip to forward 1× regardless of current rate.
  if state == Paused or direction == Reverse:
    (Playing, Forward, Rate1x)
  else:
    (Playing, Forward, nextRate(rate))

proc pressRewind*(
    state: VideoPlayerPlayState;
    direction: VideoPlayerDirection;
    rate: VideoPlayerRate):
    tuple[state: VideoPlayerPlayState; direction: VideoPlayerDirection;
          rate: VideoPlayerRate] =
  ## Symmetric to pressFastForward.
  if state == Paused or direction == Forward:
    (Playing, Reverse, Rate1x)
  else:
    (Playing, Reverse, nextRate(rate))

proc pressTogglePlay*(
    state: VideoPlayerPlayState;
    resumeDirection: VideoPlayerDirection;
    resumeRate: VideoPlayerRate):
    tuple[state: VideoPlayerPlayState; direction: VideoPlayerDirection;
          rate: VideoPlayerRate] =
  ## Pause → resume at the last non-paused state.
  ## Play  → pause; caller is expected to capture the current (dir, rate) into
  ## the resume slots *before* calling this so the next press restores them.
  if state == Paused:
    (Playing, resumeDirection, resumeRate)
  else:
    (Paused, resumeDirection, resumeRate)

proc stepFrameDelta*(direction: int; currentFrame, frameCount: int): int =
  ## Compute the target frame for a Step-Frame press. direction is ±1.
  ## Clamps at [0, frameCount-1] when frameCount > 0; otherwise allows any
  ## non-negative value.
  let raw = currentFrame + direction
  if frameCount > 0:
    max(0, min(raw, frameCount - 1))
  else:
    max(0, raw)

# ---------------------------------------------------------------------------
# Side-effecting wrappers — drive the underlying FrameViewerVM.
# ---------------------------------------------------------------------------

proc applyPlayState(vm: VideoPlayerVM; state: VideoPlayerPlayState;
                    direction: VideoPlayerDirection;
                    rate: VideoPlayerRate) =
  vm.playState.val = state
  vm.direction.val = direction
  vm.rate.val = rate
  if state == Playing:
    vm.resumeDirection = direction
    vm.resumeRate = rate

proc fastForward*(vm: VideoPlayerVM) =
  let next = pressFastForward(vm.playState.val, vm.direction.val, vm.rate.val)
  vm.applyPlayState(next.state, next.direction, next.rate)

proc rewind*(vm: VideoPlayerVM) =
  let next = pressRewind(vm.playState.val, vm.direction.val, vm.rate.val)
  vm.applyPlayState(next.state, next.direction, next.rate)

proc togglePlay*(vm: VideoPlayerVM) =
  if vm.playState.val == Playing:
    ## Capture current direction/rate so the next toggle resumes here.
    vm.resumeDirection = vm.direction.val
    vm.resumeRate = vm.rate.val
  let next = pressTogglePlay(vm.playState.val, vm.resumeDirection, vm.resumeRate)
  vm.applyPlayState(next.state, next.direction, next.rate)

proc pause*(vm: VideoPlayerVM) =
  ## Force a transition to Paused (used implicitly when entering picker mode
  ## or when the user scrubs the slider mid-playback).
  if vm.playState.val == Playing:
    vm.resumeDirection = vm.direction.val
    vm.resumeRate = vm.rate.val
    vm.playState.val = Paused

proc stepFrame*(vm: VideoPlayerVM; delta: int) =
  ## Step-Frame (±1). No-op when playing — the spec ties this to the paused
  ## state. Callers wiring keyboard shortcuts may choose to auto-pause first.
  if vm.playState.val == Playing: return
  let target = stepFrameDelta(delta, vm.frameVm.currentFrame.val,
                              vm.frameVm.frameCount.val)
  vm.frameVm.loadFrameByIndex(target)

proc stepDrawCall*(vm: VideoPlayerVM; delta: int) =
  ## Step by a single draw call. Delegates to /frame?draw=N which auto-rolls
  ## across frame boundaries on the server side.
  if vm.playState.val == Playing: return
  let calls = vm.frameVm.drawCalls.val
  let currentIdx =
    if vm.frameVm.selectedDrawCall.val.isSome:
      vm.frameVm.selectedDrawCall.val.get
    else:
      0
  let target =
    if calls.len == 0:
      max(0, currentIdx + delta)
    else:
      max(0, min(currentIdx + delta, calls.len - 1))
  vm.frameVm.loadFrameForDraw(target, seekSource = false)

proc jumpToStart*(vm: VideoPlayerVM) =
  vm.pause()
  vm.frameVm.loadFrameByIndex(0)

proc jumpToEnd*(vm: VideoPlayerVM) =
  vm.pause()
  let last = max(0, vm.frameVm.frameCount.val - 1)
  vm.frameVm.loadFrameByIndex(last)

proc scrubTo*(vm: VideoPlayerVM; frame: int) =
  ## Scrub slider: implicit pause, then load the requested frame. The view is
  ## responsible for capturing the previous play state if it wants to resume
  ## on slider release (see Visual-Replay.md §Scrub Slider).
  vm.pause()
  vm.frameVm.loadFrameByIndex(frame)

# ---------------------------------------------------------------------------
# Picker mode and magnifier.
# ---------------------------------------------------------------------------

proc enterPickerMode*(vm: VideoPlayerVM) =
  vm.pause()
  vm.pickerState.val = PickerActive

proc exitPickerMode*(vm: VideoPlayerVM) =
  vm.pickerState.val = PickerOff
  vm.magnifier.val = none(MagnifierPosition)

proc togglePicker*(vm: VideoPlayerVM) =
  if vm.pickerState.val == PickerActive:
    vm.exitPickerMode()
  else:
    vm.enterPickerMode()

proc updateMagnifier*(vm: VideoPlayerVM;
                     renderedX, renderedY: float;
                     renderedWidth, renderedHeight: float) =
  ## Map a display-space cursor position to source-pixel coordinates and store
  ## both for the view to render the loupe overlay.
  if vm.pickerState.val != PickerActive: return
  if renderedWidth <= 0 or renderedHeight <= 0 or
      vm.frameVm.frameWidth.val <= 0 or vm.frameVm.frameHeight.val <= 0:
    vm.magnifier.val = none(MagnifierPosition)
    return
  let sx = int(renderedX / renderedWidth * float(vm.frameVm.frameWidth.val))
  let sy = int(renderedY / renderedHeight * float(vm.frameVm.frameHeight.val))
  let clampedX = max(0, min(sx, vm.frameVm.frameWidth.val - 1))
  let clampedY = max(0, min(sy, vm.frameVm.frameHeight.val - 1))
  vm.magnifier.val = some(MagnifierPosition(
    sourceX: clampedX,
    sourceY: clampedY,
    displayX: renderedX,
    displayY: renderedY,
  ))

proc commitPickedPixel*(vm: VideoPlayerVM) =
  ## Commit the magnifier's current source-pixel coordinates as the selected
  ## pixel and exit picker mode. No-op when the magnifier has no position.
  let pos = vm.magnifier.val
  if pos.isNone: return
  let p = pos.get
  vm.frameVm.selectPixel(p.sourceX, p.sourceY)
  vm.exitPickerMode()

# ---------------------------------------------------------------------------
# Construction.
# ---------------------------------------------------------------------------

proc createVideoPlayerVM*(frameVm: FrameViewerVM): VideoPlayerVM =
  ## Wrap an existing FrameViewerVM with the playback chrome state. The
  ## FrameViewerVM is shared with the (legacy) frame viewer pane and the
  ## downstream pixel-history / shader-debug panes, so the underlying signals
  ## stay coherent across all consumers.
  withViewModel proc(dispose: proc()): VideoPlayerVM =
    let vm = VideoPlayerVM(
      frameVm: frameVm,
      reactiveOwner: getOwner(),
      playState: createSignal(Paused),
      direction: createSignal(Forward),
      rate: createSignal(Rate1x),
      resumeDirection: Forward,
      resumeRate: Rate1x,
      pickerState: createSignal(PickerOff),
      magnifier: createSignal(none(MagnifierPosition)),
      bufferingDegraded: createSignal(false),
      disposeProc: dispose,
    )
    vm
