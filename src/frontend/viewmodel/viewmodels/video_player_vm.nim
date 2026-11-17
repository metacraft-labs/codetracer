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

const
  ## Nominal frame rate the recording is paced at.  Spec
  ## (Visual-Replay.md §Frame Rate and Buffering):
  ##   "The base rate (1×) targets the recording's nominal frame rate
  ##    read from gfxfrm.idx (typically 60 fps)."
  ##
  ## The /info endpoint does not surface this number today, so we hold
  ## it as a constant here.  When the backend learns to report the
  ## nominal rate, pipe it onto FrameViewerVM and read from a signal
  ## instead — the tick math below already accepts a parameterised
  ## interval.
  NominalFrameRateHz* = 60

  ## Hysteresis: the buffering flag is sticky for this many milliseconds
  ## after the median falls back below threshold so the indicator
  ## doesn't flicker on a single fast frame.  Spec calls for "1 s"
  ## hysteresis; we use 1000 ms exactly.
  BufferingClearHysteresisMs* = 1_000

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

  VideoPlayerAction* = enum
    ## Enumerates the M4 keyboard shortcuts so the dispatcher can be unit-
    ## tested independently of the global ClientAction enum and the JS-only
    ## handler-array wiring in ui_js.nim.  The names mirror the ClientAction
    ## entries one-for-one — see ``frontend.nim`` (codetracer_features) — but
    ## live here because the VM dispatcher is what executes them.
    VpaTogglePlay,
    VpaRewind,
    VpaFastForward,
    VpaStepFrameBack,
    VpaStepFrameForward,
    VpaStepDrawBack,
    VpaStepDrawForward,
    VpaJumpStart,
    VpaJumpEnd,
    VpaTogglePicker,
    VpaCancelPicker

const
  VideoPlayerOperations*: array[VideoPlayerAction, string] = [
    VpaTogglePlay: "video-player.toggle-play",
    VpaRewind: "video-player.rewind",
    VpaFastForward: "video-player.fast-forward",
    VpaStepFrameBack: "video-player.step-frame-back",
    VpaStepFrameForward: "video-player.step-frame-forward",
    VpaStepDrawBack: "video-player.step-draw-back",
    VpaStepDrawForward: "video-player.step-draw-forward",
    VpaJumpStart: "video-player.jump-start",
    VpaJumpEnd: "video-player.jump-end",
    VpaTogglePicker: "video-player.toggle-picker",
    VpaCancelPicker: "video-player.cancel-picker"]
    ## Each action as the operation that names it (Input-Routing §3): what a
    ## key's row and a transport button's press both run, through each
    ## front-end's operation tables.

type
  ScrubAxis* = enum
    ## The pane's two scrubbers (CodeTracer-TUI-Graphics.md §4): the frame
    ## scrubber over the recording's frames, and the nested draw-call
    ## scrubber over the shown frame's draw calls.
    scrubFrame
    scrubDraw

  ScrubGesture* = object
    ## One scrubber's drag (Visual-Replay.md § Scrub Slider), as a value: the
    ## pane shows `position` at once; the player is asked for it at most
    ## every `ScrubCoalesceMs` while held (`requested` is what it was last
    ## asked for), and once more where it is released.
    held*: bool
    position*: int
    requested*: int
      ## -1 before the first request of this drag.
    lastRequestMs*: float
    resumePlaying*: bool
      ## Playback was running when the drag began: the release resumes it at
      ## the previous rate and direction ("Dragging while playing implicitly
      ## pauses; releasing resumes at the previous rate").

  VideoPlayerVM* = ref object of ViewModel
    frameVm*: FrameViewerVM
    scrubRevision*: Signal[int]
      ## Bumped by every change to the two gestures, and read by every read of
      ## where a scrubber is (`scrubPosition`). The gestures are plain fields;
      ## without this a reactive label followed no drag and, having returned
      ## the gesture's position without reading the frame while held, lost its
      ## dependency on the frame and froze on the pressed one for good.
    frameScrub*: ScrubGesture
    drawScrub*: ScrubGesture
      ## The two scrubbers' drags (`beginScrub` / `dragScrub` / `pumpScrub` /
      ## `releaseScrub`). Shared by every front-end, so the desktop's slider,
      ## the terminal's bottom row and the GPUI track coalesce and release
      ## alike.
    stageWidth, stageHeight: int
      ## The frame stage's size in device pixels (`setStageSize`).
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
    ## RGBA channel values (0..1) sampled from the mirror canvas at the
    ## magnifier centre. Populated by the view's JS sampling routine and
    ## surfaced here so the loupe footer can render it reactively.
    magnifierCenterColor*: Signal[Option[VisualReplayPixelColor]]

    bufferingDegraded*: Signal[bool]
    ## Timestamp (ms from the JS monotonic clock) of the last tick at
    ## which the median fetch latency was *below* the inter-frame
    ## interval.  Used to drive the 1-second hysteresis on the buffering
    ## flag — once latency drops back under threshold, the flag stays
    ## sticky until this much time has passed.  -1 means "never seen a
    ## fast tick since the last degrade".
    bufferingLastUnderMs*: float
    ## Time of the previous rAF tick.  0.0 sentinels "this is the first
    ## tick after Playing was entered" so the math doesn't burn a single
    ## huge frame jump from a stale "now".
    lastTickMs*: float
    ## Floating accumulator for partial-frame advance — at 8× we tick a
    ## new frame every two rAF callbacks; at 1× we tick approximately
    ## every callback.  Carrying the fractional remainder over keeps the
    ## perceived rate stable instead of dropping every other frame at
    ## low rates.
    frameAccumulator*: float

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

proc isStartupSpinnerVisible*(
    visualReplayAvailable: bool;
    playerUrl: string;
    frameCount: int;
    errorMessage: string): bool =
  ## Spec (Visual-Replay.md §Status Indicators / "Player connecting"):
  ##   "Spinner badge over centre of canvas, 'Starting player…'.
  ##    ct_gfx_player process launched; waiting for /info to succeed."
  ##
  ## Pure decision so the view can call this from a reactive computed
  ## without smuggling DOM state into the rule.  Visible iff the
  ## session is visual-capable, a player URL exists, /info hasn't
  ## reported a frame count yet, and no terminal error is showing.
  visualReplayAvailable and playerUrl.len > 0 and frameCount == 0 and
    errorMessage.len == 0

proc previousRate*(rate: VideoPlayerRate): VideoPlayerRate =
  ## Inverse of nextRate — used by buffering detection to downgrade one
  ## step when the fetch latency outpaces the inter-frame interval.
  ## At Rate1x there is no slower step in the spec'd cycle; we stay at
  ## 1× and let the caller cap the buffering flag instead.
  case rate
  of Rate1x: Rate1x
  of Rate2x: Rate1x
  of Rate4x: Rate2x
  of Rate8x: Rate4x

proc nominalIntervalMs*(rate: VideoPlayerRate;
                        nominalRateHz: int = NominalFrameRateHz): float =
  ## Wall-clock ms between successive frames at the given playback rate.
  ## At 60 fps base: 1× → 16.66 ms, 2× → 8.33 ms, 4× → 4.16 ms, 8× → 2.08 ms.
  ## Spec: Visual-Replay.md §Frame Rate and Buffering.
  let safeHz = max(1, nominalRateHz)
  1000.0 / (float(safeHz) * float(int(rate)))

type
  BufferingDetectionInput* = object
    medianFetchMs*: int
    rate*: VideoPlayerRate
    nominalRateHz*: int
    playing*: bool
    currentlyDegraded*: bool
    lastUnderMs*: float
    nowMs*: float

  BufferingDetectionOutcome* = object
    ## Result of a single buffering-detection tick.
    ## - ``newDegraded``:  the value to write to bufferingDegraded.val.
    ## - ``shouldDegrade``: rate should drop one step.
    ## - ``lastUnderMs``:  the value to write back to bufferingLastUnderMs.
    newDegraded*: bool
    shouldDegrade*: bool
    lastUnderMs*: float

proc detectBuffering*(input: BufferingDetectionInput;
                      clearHysteresisMs: int = BufferingClearHysteresisMs):
                      BufferingDetectionOutcome =
  ## Pure decision function for the buffering indicator + degrade step.
  ##
  ## Inputs:
  ## - ``medianFetchMs``: most recent median latency.  -1 = no samples yet.
  ## - ``rate``: current playback rate.
  ## - ``nominalRateHz``: 60 today; piped through for testability.
  ## - ``playing``: paused → clear the flag immediately.
  ## - ``currentlyDegraded``: the previous bufferingDegraded value.
  ## - ``lastUnderMs``: timestamp of the last under-threshold tick;
  ##   ``-1.0`` sentinels "never seen one since last degrade".
  ## - ``nowMs``: monotonic clock.
  ##
  ## Outputs:
  ## - ``newDegraded``: write back to bufferingDegraded.val.
  ## - ``shouldDegrade``: caller should drop the rate one step.
  ## - ``lastUnderMs``: write back to bufferingLastUnderMs.
  ##
  ## Hysteresis (spec): the indicator stays on for clearHysteresisMs
  ## (1 s default) after latency falls back below threshold so a single
  ## fast frame doesn't blink the flag off.
  ##
  ## Spec: Visual-Replay.md §Frame Rate and Buffering — "If frame fetch
  ## latency exceeds the inter-frame interval at the current rate, the
  ## player visibly degrades to the next-lower rate and shows a yellow
  ## buffering indicator next to the rate badge."
  if not input.playing:
    return BufferingDetectionOutcome(
      newDegraded: false, shouldDegrade: false, lastUnderMs: -1.0)

  if input.medianFetchMs < 0:
    ## No samples — preserve the previous state.  Don't clear; don't
    ## degrade; don't perturb the hysteresis timer.
    return BufferingDetectionOutcome(
      newDegraded: input.currentlyDegraded,
      shouldDegrade: false,
      lastUnderMs: input.lastUnderMs)

  let intervalMs = nominalIntervalMs(input.rate, input.nominalRateHz)
  let over = float(input.medianFetchMs) > intervalMs

  if over:
    ## Degrade exactly once per over-threshold transition; don't keep
    ## stepping the rate down on every tick because the median is
    ## sampled across multiple frames and one step reliably halves the
    ## work per second.  Subsequent ticks just keep the indicator on.
    let shouldDrop = not input.currentlyDegraded and input.rate != Rate1x
    return BufferingDetectionOutcome(
      newDegraded: true, shouldDegrade: shouldDrop, lastUnderMs: -1.0)

  ## Under threshold.  Start the hysteresis clock if this is the first
  ## under-threshold tick since a degrade, otherwise check whether
  ## clearHysteresisMs have elapsed and drop the flag if so.
  if not input.currentlyDegraded:
    return BufferingDetectionOutcome(
      newDegraded: false, shouldDegrade: false, lastUnderMs: input.nowMs)
  let lastUnder =
    if input.lastUnderMs < 0: input.nowMs else: input.lastUnderMs
  let elapsedUnder = input.nowMs - lastUnder
  if elapsedUnder >= float(clearHysteresisMs):
    BufferingDetectionOutcome(
      newDegraded: false, shouldDegrade: false, lastUnderMs: -1.0)
  else:
    BufferingDetectionOutcome(
      newDegraded: true, shouldDegrade: false, lastUnderMs: lastUnder)

type
  PlaybackTickInput* = object
    rate*: VideoPlayerRate
    direction*: VideoPlayerDirection
    nominalRateHz*: int
    currentFrame*: int
    frameCount*: int
    accumulator*: float       ## carried from the previous tick
    elapsedMs*: float         ## now - lastTickMs

  PlaybackTickOutcome* = object
    ## Result of the pure tick math.
    ## - ``targetFrame``: where to seek (or the unchanged currentFrame
    ##   if no whole-frame advance happened this tick).
    ## - ``advanced``: true when targetFrame differs from currentFrame.
    ## - ``accumulator``: write back to vm.frameAccumulator.
    ## - ``shouldPause``: clamp triggered (start or end of timeline);
    ##   caller should call ``pause()``.
    targetFrame*: int
    advanced*: bool
    accumulator*: float
    shouldPause*: bool

proc computeTickAdvance*(input: PlaybackTickInput): PlaybackTickOutcome =
  ## Pure rAF tick math.  Computes how many frames to advance the
  ## current frame index given the rate, direction, elapsed wall-clock
  ## milliseconds since the last tick, and any fractional carry from
  ## the previous tick.
  ##
  ## Formula (per spec §Frame Rate and Buffering):
  ##   delta = (elapsedMs / nominalIntervalMs(1×)) × rate × directionSign
  ##         = elapsedMs × nominalRateHz × rate / 1000  × directionSign
  ##
  ## The integer portion seeks; the fractional portion is carried over
  ## via ``accumulator`` so a 1× playback at 60 fps doesn't blink
  ## every-other-frame just because of sub-millisecond rAF jitter.
  ##
  ## Clamps at ``[0, frameCount-1]`` and reports ``shouldPause = true``
  ## so the caller can park playback at the timeline edge (spec: "If
  ## the target is at the timeline edge, clamp and pause.").
  let safeHz = max(1, input.nominalRateHz)
  let directionSign = (if input.direction == Forward: 1.0 else: -1.0)
  let perFrameMs = 1000.0 / float(safeHz)
  ## Fractional frames covered by this tick.  Same formula in both
  ## directions; the sign rides on directionSign so negative values
  ## walk the accumulator backwards.
  let deltaFrames = directionSign *
    (input.elapsedMs / perFrameMs) * float(int(input.rate))
  let accum = input.accumulator + deltaFrames
  ## Take the integer whole-frame portion and leave the fraction in
  ## the accumulator.  ``int`` truncates towards zero which is what we
  ## want — the sign rides on the carry, never on the seek count.
  let wholeFrames = int(accum)
  let remainder = accum - float(wholeFrames)
  let rawTarget = input.currentFrame + wholeFrames

  if input.frameCount <= 0:
    ## We don't have a frame count yet (the /info handshake hasn't
    ## completed).  Advance the integer count anyway so test
    ## scaffolding without a frame count can still exercise the math,
    ## but don't pretend we hit a clamp.
    return PlaybackTickOutcome(
      targetFrame: max(0, rawTarget),
      advanced: wholeFrames != 0,
      accumulator: remainder,
      shouldPause: false)

  let lastFrame = input.frameCount - 1
  if rawTarget < 0:
    ## Walked past the start of the timeline — clamp to 0, pause, drop
    ## the carry so a subsequent resume doesn't immediately re-trigger.
    PlaybackTickOutcome(
      targetFrame: 0, advanced: input.currentFrame != 0,
      accumulator: 0.0, shouldPause: true)
  elif rawTarget > lastFrame:
    ## Walked past the end of the timeline — clamp to the last frame
    ## and pause.
    PlaybackTickOutcome(
      targetFrame: lastFrame,
      advanced: input.currentFrame != lastFrame,
      accumulator: 0.0, shouldPause: true)
  else:
    ## Inside the timeline — advance (possibly by 0) and carry the
    ## fractional remainder for the next tick.
    PlaybackTickOutcome(
      targetFrame: rawTarget, advanced: wholeFrames != 0,
      accumulator: remainder, shouldPause: false)

type
  ScrubTick* = object
    ## Layout descriptor for one tick mark under the scrub slider.
    ## Pure data so the tests can pin the math without a DOM.
    frame*: int          ## frame index in the timeline
    leftPercent*: float  ## position as 0..100 % across the slider track

proc layoutScrubTicks*(clearFrames: openArray[int]; frameCount: int):
    seq[ScrubTick] =
  ## Compute the geometry of clear-frame tick marks under the scrub
  ## slider.  Returns one ``ScrubTick`` per frame flagged ``clear`` in
  ## ``gfxfrm.idx`` (i.e. scene boundaries / framebuffer-cleared
  ## frames); the indices arrive on ``VisualReplayInfo.clearFrames``
  ## via the ``/info`` endpoint and ride to the view through
  ## ``FrameViewerVM.clearFrames``.
  if frameCount <= 1 or clearFrames.len == 0:
    return @[]
  let lastFrame = frameCount - 1
  for f in clearFrames:
    if f < 0 or f > lastFrame: continue
    let pct = float(f) / float(lastFrame) * 100.0
    result.add(ScrubTick(frame: f, leftPercent: pct))

const
  ScrubCoalesceMs* = 60.0
    ## Visual-Replay.md § Scrub Slider: "Continuous dragging issues
    ## getFrameByFrame requests at most every 60 ms".

type
  ScrubStep* = object
    ## What one scrub event does: the gesture after it, and the position the
    ## player is asked for now (-1 for none).
    gesture*: ScrubGesture
    request*: int

proc scrubStep*(g: ScrubGesture; position: int; nowMs: float;
                release: bool): ScrubStep =
  ## THE COALESCING RULE, pure. A drag event asks for its position when no
  ## request of this drag has gone yet or `ScrubCoalesceMs` passed since the
  ## last one, and the position differs from what was last asked; a release
  ## asks for its position unless that is exactly what was last asked (the
  ## frame it settles on is then already on its way).
  result.gesture = g
  result.gesture.position = position
  result.request = -1
  let due = g.requested < 0 or nowMs - g.lastRequestMs >= ScrubCoalesceMs
  if position != g.requested and (release or due):
    result.request = position
    result.gesture.requested = position
    result.gesture.lastRequestMs = nowMs
  if release:
    result.gesture.held = false

proc scrubPending*(g: ScrubGesture; nowMs: float): bool =
  ## A held drag whose last position was not asked for because it came
  ## inside the coalescing window, and the window has passed: the idle tick
  ## asks for it now (`pumpScrub`), so a drag that stops moving still lands
  ## on the frame under the pointer.
  g.held and g.position != g.requested and
    nowMs - g.lastRequestMs >= ScrubCoalesceMs

const
  VideoTransportOrder* = [VpaJumpStart, VpaRewind, VpaTogglePlay,
                          VpaFastForward, VpaJumpEnd, VpaStepDrawBack,
                          VpaStepDrawForward, VpaStepFrameBack,
                          VpaStepFrameForward, VpaTogglePicker]
    ## The transport's controls, left to right (Visual-Replay.md § Video
    ## Player Pane's layout): every front-end draws them in this order.
  VideoTransportLabels*: array[VideoPlayerAction, string] = [
    VpaTogglePlay: ">",
    VpaRewind: "<<",
    VpaFastForward: ">>",
    VpaStepFrameBack: "f<",
    VpaStepFrameForward: "f>",
    VpaStepDrawBack: "d<",
    VpaStepDrawForward: "d>",
    VpaJumpStart: "|<",
    VpaJumpEnd: ">|",
    VpaTogglePicker: "pick",
    VpaCancelPicker: ""]
    ## The native front-ends' spelling of the transport's icons (§ Transport
    ## Controls): `|<` Jump to Start, `<<` Rewind, `>` / `||` Play / Pause,
    ## `>>` Fast Forward, `>|` Jump to End, `d<` `d>` the draw-call step,
    ## `f<` `f>` the frame step, `pick` the Pixel Picker — ASCII, so the
    ## terminal's every tier and any GPUI font draws them.

func videoTransportLabel*(action: VideoPlayerAction; playing: bool): string =
  if action == VpaTogglePlay and playing: "||" else: VideoTransportLabels[action]

func videoTransportStatus*(playing, reverse: bool; rate: int; buffering,
                           loading: bool; error: string): string =
  ## Right of the controls (§ Status Indicators): the rate badge while
  ## playing (`2x >`, `1x <` reversed) with `buffering` beside it when
  ## degraded, `paused` otherwise, `loading` while a frame is on its way, the
  ## player's error instead of all of it.
  if error.len > 0:
    return error
  if playing:
    result = $rate & "x " & (if reverse: "<" else: ">")
    if buffering:
      result.add " buffering"
  else:
    result = "paused"
  if loading:
    result.add "  loading"

proc rateNumber*(rate: VideoPlayerRate): int =
  case rate
  of Rate1x: 1
  of Rate2x: 2
  of Rate4x: 4
  of Rate8x: 8

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
  let wasPlaying = vm.playState.val == Playing
  vm.playState.val = state
  vm.direction.val = direction
  vm.rate.val = rate
  if state == Playing:
    vm.resumeDirection = direction
    vm.resumeRate = rate
    if not wasPlaying:
      ## Reset tick state when entering Playing so the first ``tickPlayback``
      ## call captures ``now`` as the baseline (avoids a huge initial jump
      ## if the rAF callback fires with a stale ``lastTickMs`` from a
      ## previous Playing session).  ``-1.0`` is the "no baseline yet"
      ## sentinel — ``performance.now()`` can legitimately return 0.0.
      vm.lastTickMs = -1.0
      vm.frameAccumulator = 0.0
  else:
    ## Paused: clear the buffering flag and tick state.  Same contract as
    ## ``pause()`` so callers (togglePlay, fastForward → reverse flip,
    ## etc.) get a consistent "no playback, no indicator" baseline.
    vm.bufferingDegraded.val = false
    vm.bufferingLastUnderMs = -1.0
    vm.lastTickMs = -1.0
    vm.frameAccumulator = 0.0

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
  ## Spec: "When paused, clear bufferingDegraded immediately."  The flag is
  ## meaningless when no requests are being issued, and a stale yellow dot
  ## while paused would confuse users into thinking the player is broken.
  vm.bufferingDegraded.val = false
  vm.bufferingLastUnderMs = -1.0
  vm.lastTickMs = -1.0
  vm.frameAccumulator = 0.0

proc tickPlayback*(vm: VideoPlayerVM; nowMs: float) =
  ## Pure-side rAF tick entry point.  The JS rAF loop installed in the
  ## view calls this on every frame; the math is delegated to
  ## ``computeTickAdvance`` and ``detectBuffering`` so the logic can be
  ## unit-tested headlessly via ``video_player_polish_test.nim``.
  ##
  ## Spec: Visual-Replay.md §Frame Rate and Buffering.
  if vm.playState.val != Playing:
    return
  if vm.frameVm.error.val.len > 0:
    ## Errors during playback should park us at the error overlay;
    ## the controls are visibly disabled per spec.
    vm.pause()
    return
  ## First tick after entering Playing — capture the timestamp and
  ## skip the advance so the next tick has a meaningful elapsed-ms.
  ## ``-1.0`` is the explicit "no baseline yet" sentinel; a literal
  ## 0.0 ``nowMs`` is a valid timestamp (some hosts seed
  ## ``performance.now()`` from page-load time).
  if vm.lastTickMs < 0.0:
    vm.lastTickMs = nowMs
    return

  let elapsed = nowMs - vm.lastTickMs
  vm.lastTickMs = nowMs

  ## Sample the median BEFORE the new fetch — if a slow request is
  ## already in flight from a previous tick, ``frameVm.medianFetchMs``
  ## already reflects the past samples, and the detector should use
  ## those rather than risk being poisoned by the (potentially fast)
  ## stub completion of the request we're about to issue on this tick.
  let medianAtTick = vm.frameVm.medianFetchMs.val

  let advance = computeTickAdvance(PlaybackTickInput(
    rate: vm.rate.val,
    direction: vm.direction.val,
    nominalRateHz: NominalFrameRateHz,
    currentFrame: vm.frameVm.currentFrame.val,
    frameCount: vm.frameVm.frameCount.val,
    accumulator: vm.frameAccumulator,
    elapsedMs: elapsed,
  ))
  vm.frameAccumulator = advance.accumulator

  let detect = detectBuffering(BufferingDetectionInput(
    medianFetchMs: medianAtTick,
    rate: vm.rate.val,
    nominalRateHz: NominalFrameRateHz,
    playing: true,
    currentlyDegraded: vm.bufferingDegraded.val,
    lastUnderMs: vm.bufferingLastUnderMs,
    nowMs: nowMs,
  ))
  vm.bufferingDegraded.val = detect.newDegraded
  vm.bufferingLastUnderMs = detect.lastUnderMs
  if detect.shouldDegrade:
    vm.rate.val = previousRate(vm.rate.val)
    vm.resumeRate = vm.rate.val

  ## Issue the frame request after the detection decision so the new
  ## sample only influences the *next* tick, never the one that
  ## triggered it.
  if advance.advanced and
      advance.targetFrame != vm.frameVm.currentFrame.val:
    vm.frameVm.loadFrameByIndex(advance.targetFrame)

  if advance.shouldPause:
    vm.pause()

proc stepFrame*(vm: VideoPlayerVM; delta: int) =
  ## Step-Frame (±1). No-op when playing — the spec ties this to the paused
  ## state. Callers wiring keyboard shortcuts may choose to auto-pause first.
  if vm.playState.val == Playing: return
  let target = stepFrameDelta(delta, vm.frameVm.currentFrame.val,
                              vm.frameVm.frameCount.val)
  vm.frameVm.loadFrameByIndex(target)

proc stepDrawCall*(vm: VideoPlayerVM; delta: int) =
  ## Step by a single draw call (Visual-Replay.md § Transport Controls):
  ## within the shown frame when the player said what its draw calls are —
  ## "underflow rolls into the previous frame at its last draw", "overflow
  ## rolls into the next frame at draw 0" — and otherwise over the
  ## recording's draw-call list through /frame?draw=N.
  if vm.playState.val == Playing: return
  let count = vm.frameVm.frameDrawCount.val
  if count > 0:
    let frame = vm.frameVm.currentFrame.val
    let shown =
      if vm.frameVm.drawInFrame.val >= 0: vm.frameVm.drawInFrame.val
      else: count - 1
    let target = shown + delta
    if target >= 0 and target < count:
      vm.frameVm.loadDrawInFrame(target)
    elif target < 0:
      if frame > 0:
        # A frame request shows that frame's last draw.
        vm.frameVm.loadFrameByIndex(frame - 1)
    else:
      let frames = vm.frameVm.frameCount.val
      if frames <= 0 or frame + 1 < frames:
        vm.frameVm.loadDrawInFrame(0, frame + 1)
    return
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

proc gestureOf(vm: VideoPlayerVM; axis: ScrubAxis): ScrubGesture =
  case axis
  of scrubFrame: vm.frameScrub
  of scrubDraw: vm.drawScrub

proc setGesture(vm: VideoPlayerVM; axis: ScrubAxis; g: ScrubGesture) =
  case axis
  of scrubFrame: vm.frameScrub = g
  of scrubDraw: vm.drawScrub = g
  vm.scrubRevision.val = vm.scrubRevision.val + 1

proc askScrub(vm: VideoPlayerVM; axis: ScrubAxis; position: int) =
  case axis
  of scrubFrame: vm.frameVm.loadFrameByIndex(position)
  of scrubDraw: vm.frameVm.loadDrawInFrame(position)

proc clampScrub(vm: VideoPlayerVM; axis: ScrubAxis; position: int): int =
  let count =
    case axis
    of scrubFrame: vm.frameVm.frameCount.val
    of scrubDraw: vm.frameVm.frameDrawCount.val
  if count > 0: max(0, min(position, count - 1)) else: max(0, position)

proc beginScrub*(vm: VideoPlayerVM; axis: ScrubAxis; position: int;
                 nowMs: float) =
  ## A press on a scrubber: the drag holds it, playback pauses (and is
  ## resumed on the release), and the pressed position is asked for.
  var g = ScrubGesture(held: true, position: -1, requested: -1,
                       lastRequestMs: 0.0,
                       resumePlaying: vm.playState.val == Playing)
  if g.resumePlaying:
    vm.pause()
  let p = vm.clampScrub(axis, position)
  let step = scrubStep(g, p, nowMs, release = false)
  vm.setGesture(axis, step.gesture)
  if step.request >= 0:
    vm.askScrub(axis, step.request)

proc dragScrub*(vm: VideoPlayerVM; axis: ScrubAxis; position: int;
                nowMs: float): bool =
  ## The pointer moved while the scrubber is held: the pane shows
  ## `position` at once; the player is asked for it only outside the
  ## coalescing window. Whether a request went.
  if not vm.gestureOf(axis).held:
    return false
  let step = scrubStep(vm.gestureOf(axis), vm.clampScrub(axis, position),
                       nowMs, release = false)
  vm.setGesture(axis, step.gesture)
  if step.request >= 0:
    vm.askScrub(axis, step.request)
  step.request >= 0

proc pumpScrub*(vm: VideoPlayerVM; nowMs: float): bool =
  ## The idle tick: a held drag's coalesced position asked for once its
  ## window has passed. Whether a request went.
  for axis in ScrubAxis:
    let g = vm.gestureOf(axis)
    if scrubPending(g, nowMs):
      var next = g
      next.requested = g.position
      next.lastRequestMs = nowMs
      vm.setGesture(axis, next)
      vm.askScrub(axis, g.position)
      result = true

proc releaseScrub*(vm: VideoPlayerVM; axis: ScrubAxis; position: int;
                   nowMs: float) =
  ## The release settles on `position` (asked for unless it already was)
  ## and resumes playback when the drag paused it.
  let before = vm.gestureOf(axis)
  if not before.held:
    return
  let step = scrubStep(before, vm.clampScrub(axis, position), nowMs,
                       release = true)
  vm.setGesture(axis, step.gesture)
  if step.request >= 0:
    vm.askScrub(axis, step.request)
  if before.resumePlaying:
    vm.applyPlayState(Playing, vm.resumeDirection, vm.resumeRate)

proc scrubPosition*(vm: VideoPlayerVM; axis: ScrubAxis): int =
  ## Where a scrubber's thumb is: under the pointer while held, else the
  ## frame (or the draw call within it) shown.
  discard vm.scrubRevision.val
  let g = vm.gestureOf(axis)
  if g.held: return g.position
  case axis
  of scrubFrame: vm.frameVm.currentFrame.val
  of scrubDraw: vm.frameVm.drawInFrame.val

proc frameLabel*(vm: VideoPlayerVM): string =
  ## The frame shown, over the last frame's index (the desktop's label,
  ## Visual-Replay.md § Video Player Pane): `Frame 30 / 59`; the thumb's
  ## frame while the scrubber is held.
  let total = vm.frameVm.frameCount.val
  let at = vm.scrubPosition(scrubFrame)
  if total > 0: "Frame " & $at & " / " & $(total - 1)
  else: "Frame " & $at

proc drawLabel*(vm: VideoPlayerVM): string =
  ## The draw call shown within its frame, over the frame's last draw call's
  ## index: `Draw 1 / 3` — or, when the player did not say what the frame's
  ## draw calls are, over the recording's draw-call list.
  let count = vm.frameVm.frameDrawCount.val
  if count > 0:
    let at = vm.scrubPosition(scrubDraw)
    return "Draw " & $(if at >= 0: at else: count - 1) & " / " & $(count - 1)
  let calls = vm.frameVm.drawCalls.val
  if vm.frameVm.selectedDrawCall.val.isSome:
    "Draw " & $vm.frameVm.selectedDrawCall.val.get & " / " &
      (if calls.len > 0: $(calls.len - 1) else: "?")
  elif calls.len > 0:
    "Draw 0 / " & $(calls.len - 1)
  else:
    ""

proc applyFrameSize(vm: VideoPlayerVM) =
  ## Frames at the stage's size (Viewport-Driven-Loading, Decided Q5) — and
  ## at the framebuffer's own while the pixel picker is on, because its loupe
  ## samples source pixels 1:1 (Visual-Replay.md §Loupe Specification).
  if vm.pickerState.val == PickerActive:
    vm.frameVm.setFrameSize(0, 0)
  elif vm.stageWidth > 0 and vm.stageHeight > 0:
    vm.frameVm.setFrameSize(vm.stageWidth, vm.stageHeight)

proc setStageSize*(vm: VideoPlayerVM; width, height: int) =
  ## The size, in device pixels, the frame stage shows the frame at. A hidden
  ## stage (no size) changes nothing.
  if width <= 0 or height <= 0:
    return
  vm.stageWidth = width
  vm.stageHeight = height
  vm.applyFrameSize()

proc enterPickerMode*(vm: VideoPlayerVM) =
  vm.pause()
  vm.pickerState.val = PickerActive
  vm.applyFrameSize()

proc exitPickerMode*(vm: VideoPlayerVM) =
  vm.pickerState.val = PickerOff
  vm.applyFrameSize()
  vm.magnifier.val = none(MagnifierPosition)
  vm.magnifierCenterColor.val = none(VisualReplayPixelColor)

proc cancelPicker*(vm: VideoPlayerVM) =
  ## Spec: "Press Escape, or click the Picker button again. → Exit picker mode
  ## without committing." (Visual-Replay.md §Pixel Picker Mode → Activation).
  ##
  ## A pure no-op when picker mode is already off so callers wired to a global
  ## Escape handler don't accidentally fight other consumers of the key.
  if vm.pickerState.val != PickerActive: return
  vm.exitPickerMode()

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
    vm.magnifierCenterColor.val = none(VisualReplayPixelColor)
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

proc parseVideoPlayerActionName*(name: string): Option[VideoPlayerAction] =
  ## Parse a spec-defined ClientAction name into a typed VideoPlayerAction.
  ## Used by the JS-side ``__CODETRACER_TEST__.videoPlayerAction`` hook so
  ## Playwright specs can drive every shortcut by name without depending on
  ## focused-and-hovered Video Player state.  Accepts the names verbatim
  ## (case sensitive) to match the spec table in Visual-Replay.md.
  case name
  of "VideoPlayerTogglePlay":       some(VpaTogglePlay)
  of "VideoPlayerRewind":           some(VpaRewind)
  of "VideoPlayerFastForward":      some(VpaFastForward)
  of "VideoPlayerStepFrameBack":    some(VpaStepFrameBack)
  of "VideoPlayerStepFrameForward": some(VpaStepFrameForward)
  of "VideoPlayerStepDrawBack":     some(VpaStepDrawBack)
  of "VideoPlayerStepDrawForward":  some(VpaStepDrawForward)
  of "VideoPlayerJumpStart":        some(VpaJumpStart)
  of "VideoPlayerJumpEnd":          some(VpaJumpEnd)
  of "VideoPlayerTogglePicker":     some(VpaTogglePicker)
  of "VideoPlayerCancelPicker":     some(VpaCancelPicker)
  else: none(VideoPlayerAction)

proc dispatchVideoPlayerAction*(vm: VideoPlayerVM;
                                action: VideoPlayerAction): bool =
  ## Route an M4 keyboard ClientAction onto the matching VideoPlayerVM proc.
  ##
  ## Returns ``true`` when the action was consumed (handler ran), ``false``
  ## when the dispatcher chose to let the key fall through.  The only
  ## fall-through case today is ``VpaCancelPicker`` while picker mode is
  ## inactive — Escape must reach other consumers (modals, search bars, the
  ## debugger) in that situation.  All other actions return ``true`` even
  ## when the underlying VM proc is a documented no-op (e.g. stepFrame while
  ## playing); the key was meant for the Video Player.
  ##
  ## Pure with respect to focus scoping — caller is expected to gate this
  ## proc on Video Player focus before invoking.  Lives here (not in
  ## ``ui_js.nim``) so it can be unit-tested without a DOM.
  ##
  ## Spec: Visual-Replay.md §Keyboard Shortcuts.
  if vm.isNil: return false
  case action
  of VpaTogglePlay:
    vm.togglePlay()
    true
  of VpaRewind:
    vm.rewind()
    true
  of VpaFastForward:
    vm.fastForward()
    true
  of VpaStepFrameBack:
    ## Spec: "(paused only)".  The VM proc itself enforces this contract
    ## (no-op while playing); we still report consumption so the key does
    ## not bubble to debugger handlers that would step the wrong subsystem.
    vm.stepFrame(-1)
    true
  of VpaStepFrameForward:
    vm.stepFrame(1)
    true
  of VpaStepDrawBack:
    vm.stepDrawCall(-1)
    true
  of VpaStepDrawForward:
    vm.stepDrawCall(1)
    true
  of VpaJumpStart:
    vm.jumpToStart()
    true
  of VpaJumpEnd:
    vm.jumpToEnd()
    true
  of VpaTogglePicker:
    vm.togglePicker()
    true
  of VpaCancelPicker:
    ## Only consume Escape when picker mode is actually active; otherwise the
    ## key must fall through to other Escape consumers (modals, search bars,
    ## conventional Component.onEscape methods).
    if vm.pickerState.val != PickerActive:
      return false
    vm.cancelPicker()
    true

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
      magnifierCenterColor: createSignal(none(VisualReplayPixelColor)),
      bufferingDegraded: createSignal(false),
      bufferingLastUnderMs: -1.0,
      lastTickMs: -1.0,
      frameAccumulator: 0.0,
      scrubRevision: createSignal(0),
      frameScrub: ScrubGesture(requested: -1, position: -1),
      drawScrub: ScrubGesture(requested: -1, position: -1),
      disposeProc: dispose,
    )
    vm
