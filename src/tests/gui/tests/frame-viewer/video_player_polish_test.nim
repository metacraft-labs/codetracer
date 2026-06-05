## Headless tests for the M5 Video Player polish deliverables:
##
##  - rAF tick math (``computeTickAdvance`` + the side-effecting
##    ``tickPlayback`` wrapper).
##  - Buffering detection (``detectBuffering``, the ``FrameFetchRing``
##    pure helpers, and the integrated ``tickPlayback`` path that
##    consults the FrameViewerVM ``medianFetchMs`` signal).
##  - Startup-spinner predicate.
##  - Scrub-slider clear-frame tick rendering helper
##    (``layoutScrubTicks``) — pure layout math even though the live
##    view feeds an empty seq today.
##
## Spec: codetracer-specs/GUI/Debugging-Features/Visual-Replay.md
## Milestone: codetracer-specs/GUI/Debugging-Features/Visual-Replay.milestones.org M5.

import std/[options, unittest]

import isonim/core/signals
import vm_test_helpers
import viewmodels/frame_viewer_vm
import viewmodels/video_player_vm
import viewmodels/visual_replay_client

# ---------------------------------------------------------------------------
# FrameFetchRing pure helpers (no signals; no DOM).
# ---------------------------------------------------------------------------

suite "FrameFetchRing":
  test "medianFetchMsFromRing returns -1 when empty":
    var ring: FrameFetchRing
    check medianFetchMsFromRing(ring) == -1

  test "recordFetchSample fills the ring and the median tracks the input":
    var ring: FrameFetchRing
    ring.recordFetchSample(10)
    check medianFetchMsFromRing(ring) == 10
    ring.recordFetchSample(30)
    ## Even count of samples → median of the two middle values
    ## (here just the two we recorded).
    check medianFetchMsFromRing(ring) == 20
    ring.recordFetchSample(20)
    ## Odd count of samples → straight middle.
    check medianFetchMsFromRing(ring) == 20

  test "recordFetchSample evicts oldest sample when ring is full":
    var ring: FrameFetchRing
    for i in 1 .. FrameFetchWindowSize:
      ring.recordFetchSample(i * 10)
    ## At this point samples are 10..80 ms; median = (40 + 50) / 2 = 45.
    check medianFetchMsFromRing(ring) == 45
    ## Push a slow sample; ring is full so the oldest (10 ms) is dropped.
    ring.recordFetchSample(1000)
    ## Samples are now 20, 30, 40, 50, 60, 70, 80, 1000 — sorted
    ## middle pair (50, 60), median = 55.
    check medianFetchMsFromRing(ring) == 55

  test "recordFetchSample clamps negative durations to zero":
    var ring: FrameFetchRing
    ring.recordFetchSample(-7)
    check medianFetchMsFromRing(ring) == 0

  test "resetFetchRing drops every pending sample":
    var ring: FrameFetchRing
    ring.recordFetchSample(100)
    ring.recordFetchSample(200)
    check medianFetchMsFromRing(ring) > 0
    resetFetchRing(ring)
    check medianFetchMsFromRing(ring) == -1

# ---------------------------------------------------------------------------
# rAF tick math — pure ``computeTickAdvance``.
# ---------------------------------------------------------------------------

suite "VideoPlayerVM tick math":
  test "computeTickAdvance at 1x 60Hz with one frame interval elapsed advances one frame":
    ## 1× × 60 fps × 16.66 ms = 1 frame.
    let r = computeTickAdvance(PlaybackTickInput(
      rate: Rate1x, direction: Forward, nominalRateHz: 60,
      currentFrame: 0, frameCount: 600, accumulator: 0.0,
      elapsedMs: 1000.0 / 60.0))
    check r.advanced
    check r.targetFrame == 1
    check not r.shouldPause

  test "computeTickAdvance carries fractional remainder across ticks":
    ## At 1× 60 Hz with a 10 ms tick we cover 10/16.66 ≈ 0.60 frames; no
    ## whole frame advances and the accumulator carries the remainder.
    ## A second 10 ms tick pushes the carry past 1.0 (≈ 1.20) so one
    ## frame advances and the leftover ≈ 0.20 carries forward.
    let first = computeTickAdvance(PlaybackTickInput(
      rate: Rate1x, direction: Forward, nominalRateHz: 60,
      currentFrame: 0, frameCount: 600, accumulator: 0.0, elapsedMs: 10.0))
    check not first.advanced
    check first.targetFrame == 0
    check first.accumulator > 0.0 and first.accumulator < 1.0
    let second = computeTickAdvance(PlaybackTickInput(
      rate: Rate1x, direction: Forward, nominalRateHz: 60,
      currentFrame: 0, frameCount: 600,
      accumulator: first.accumulator, elapsedMs: 10.0))
    check second.advanced
    check second.targetFrame == 1
    check second.accumulator >= 0.0
    check second.accumulator < 1.0

  test "computeTickAdvance at 8x advances eight frames per nominal interval":
    let r = computeTickAdvance(PlaybackTickInput(
      rate: Rate8x, direction: Forward, nominalRateHz: 60,
      currentFrame: 100, frameCount: 600, accumulator: 0.0,
      elapsedMs: 1000.0 / 60.0))
    check r.advanced
    check r.targetFrame == 108

  test "computeTickAdvance reverse direction walks backwards":
    let r = computeTickAdvance(PlaybackTickInput(
      rate: Rate2x, direction: Reverse, nominalRateHz: 60,
      currentFrame: 50, frameCount: 600, accumulator: 0.0,
      elapsedMs: 1000.0 / 60.0))
    check r.advanced
    ## 2× × 1 frame backwards → frame 48 (50 - 2).
    check r.targetFrame == 48

  test "computeTickAdvance clamps and signals pause at the timeline end":
    let r = computeTickAdvance(PlaybackTickInput(
      rate: Rate8x, direction: Forward, nominalRateHz: 60,
      currentFrame: 595, frameCount: 600, accumulator: 0.0,
      elapsedMs: 1000.0 / 60.0))
    check r.advanced
    check r.targetFrame == 599
    check r.shouldPause

  test "computeTickAdvance clamps and signals pause at the start of the timeline":
    let r = computeTickAdvance(PlaybackTickInput(
      rate: Rate4x, direction: Reverse, nominalRateHz: 60,
      currentFrame: 3, frameCount: 600, accumulator: 0.0,
      elapsedMs: 1000.0 / 60.0))
    check r.advanced
    check r.targetFrame == 0
    check r.shouldPause

# ---------------------------------------------------------------------------
# Side-effecting tickPlayback wrapper.
# ---------------------------------------------------------------------------

proc makeMinimalClient(): VisualReplayClient =
  let stubFrame = VisualReplayFrame(
    imageSrc: "stub", geid: some(0'u64), frame: some(0),
    width: 64, height: 64)
  VisualReplayClient(
    playerUrl: "http://stub/",
    getInfoProc: proc(): VisualReplayFuture[VisualReplayInfo] =
      newCompletedFuture(VisualReplayInfo(frameCount: 600, width: 64, height: 64)),
    getFrameByGeidProc: proc(geid: uint64): VisualReplayFuture[VisualReplayFrame] =
      newCompletedFuture(stubFrame),
    getFrameByFrameProc: proc(frame: int): VisualReplayFuture[VisualReplayFrame] =
      newCompletedFuture(VisualReplayFrame(
        imageSrc: "frame-" & $frame,
        geid: some(uint64(frame)), frame: some(frame),
        width: 64, height: 64)),
    getFrameByDrawProc: proc(draw: int): VisualReplayFuture[VisualReplayFrame] =
      newCompletedFuture(VisualReplayFrame(
        imageSrc: "draw-" & $draw,
        geid: some(uint64(100 + draw)), frame: some(0),
        width: 64, height: 64)),
    getDrawCallsProc: proc(): VisualReplayFuture[seq[VisualReplayDrawCall]] =
      newCompletedFuture(newSeq[VisualReplayDrawCall]()),
    getPixelHistoryProc: proc(x, y, frame: int):
        VisualReplayFuture[seq[VisualReplayPixelHistoryEntry]] =
      newCompletedFuture(newSeq[VisualReplayPixelHistoryEntry]()),
    getShaderDebugProc: proc(request: VisualReplayShaderDebugRequest):
        VisualReplayFuture[VisualReplayShaderDebugInfo] =
      newCompletedFuture(VisualReplayShaderDebugInfo()))

suite "VideoPlayerVM tickPlayback":
  test "tickPlayback is a no-op when paused":
    let vm = createVideoPlayerVM(createFrameViewerVM(makeMinimalClient()))
    vm.frameVm.frameCount.val = 600
    vm.frameVm.currentFrame.val = 10
    vm.tickPlayback(100.0)
    vm.tickPlayback(1000.0)
    check vm.frameVm.currentFrame.val == 10

  test "tickPlayback first tick captures the baseline; second tick advances":
    let vm = createVideoPlayerVM(createFrameViewerVM(makeMinimalClient()))
    vm.frameVm.frameCount.val = 600
    vm.frameVm.currentFrame.val = 100
    vm.fastForward()            ## enters Playing, Forward, 1×
    let beforeFrame = vm.frameVm.currentFrame.val
    vm.tickPlayback(1_000.0)    ## first tick: baseline only
    check vm.frameVm.currentFrame.val == beforeFrame
    vm.tickPlayback(1_000.0 + 100.0)  ## 100 ms later at 60 fps → 6 frames
    check vm.frameVm.currentFrame.val == beforeFrame + 6

  test "tickPlayback at the end of the timeline pauses playback":
    let vm = createVideoPlayerVM(createFrameViewerVM(makeMinimalClient()))
    vm.frameVm.frameCount.val = 600
    vm.frameVm.currentFrame.val = 595
    vm.fastForward()
    vm.tickPlayback(0.0)
    vm.tickPlayback(1000.0)     ## big elapsed → walks past the end
    check vm.frameVm.currentFrame.val == 599
    check vm.playState.val == Paused

  test "tickPlayback bails out when an error is showing":
    let vm = createVideoPlayerVM(createFrameViewerVM(makeMinimalClient()))
    vm.frameVm.frameCount.val = 600
    vm.frameVm.currentFrame.val = 5
    vm.fastForward()
    vm.frameVm.error.val = "Player crashed"
    let before = vm.frameVm.currentFrame.val
    vm.tickPlayback(0.0)
    vm.tickPlayback(100.0)
    check vm.frameVm.currentFrame.val == before
    check vm.playState.val == Paused

# ---------------------------------------------------------------------------
# Buffering detection — pure ``detectBuffering`` and integrated flow.
# ---------------------------------------------------------------------------

suite "VideoPlayerVM buffering detection":
  test "detectBuffering clears the flag immediately when paused":
    let r = detectBuffering(BufferingDetectionInput(
      medianFetchMs: 1_000, rate: Rate4x, nominalRateHz: 60,
      playing: false, currentlyDegraded: true,
      lastUnderMs: 0.0, nowMs: 5_000.0))
    check not r.newDegraded
    check not r.shouldDegrade
    check r.lastUnderMs == -1.0

  test "detectBuffering with no samples preserves state":
    let r = detectBuffering(BufferingDetectionInput(
      medianFetchMs: -1, rate: Rate4x, nominalRateHz: 60,
      playing: true, currentlyDegraded: true,
      lastUnderMs: 1_000.0, nowMs: 5_000.0))
    check r.newDegraded
    check not r.shouldDegrade
    check r.lastUnderMs == 1_000.0

  test "detectBuffering trips degrade once when median exceeds interval":
    ## At 4× the inter-frame interval is ~4.16 ms; a 20 ms median is
    ## well over the threshold so the next-lower rate should be
    ## requested.
    let first = detectBuffering(BufferingDetectionInput(
      medianFetchMs: 20, rate: Rate4x, nominalRateHz: 60,
      playing: true, currentlyDegraded: false,
      lastUnderMs: -1.0, nowMs: 1_000.0))
    check first.newDegraded
    check first.shouldDegrade
    ## A second over-threshold tick must not re-request a degrade
    ## because the rate has already been dropped one step.
    let second = detectBuffering(BufferingDetectionInput(
      medianFetchMs: 20, rate: Rate2x, nominalRateHz: 60,
      playing: true, currentlyDegraded: true,
      lastUnderMs: -1.0, nowMs: 1_050.0))
    check second.newDegraded
    check not second.shouldDegrade

  test "detectBuffering at 1x keeps the indicator without requesting a degrade":
    ## previousRate(Rate1x) == Rate1x so the caller can't drop further;
    ## the detector should still flag buffering for the badge but
    ## report shouldDegrade=false.
    let r = detectBuffering(BufferingDetectionInput(
      medianFetchMs: 1_000, rate: Rate1x, nominalRateHz: 60,
      playing: true, currentlyDegraded: false,
      lastUnderMs: -1.0, nowMs: 0.0))
    check r.newDegraded
    check not r.shouldDegrade

  test "detectBuffering hysteresis: first under-threshold tick starts the timer":
    let r = detectBuffering(BufferingDetectionInput(
      medianFetchMs: 5, rate: Rate2x, nominalRateHz: 60,
      playing: true, currentlyDegraded: true,
      lastUnderMs: -1.0, nowMs: 1_000.0))
    check r.newDegraded
    check not r.shouldDegrade
    check r.lastUnderMs == 1_000.0

  test "detectBuffering hysteresis: flag clears after the 1s window":
    let r = detectBuffering(BufferingDetectionInput(
      medianFetchMs: 5, rate: Rate2x, nominalRateHz: 60,
      playing: true, currentlyDegraded: true,
      lastUnderMs: 1_000.0, nowMs: 2_500.0))
    check not r.newDegraded
    check not r.shouldDegrade
    check r.lastUnderMs == -1.0

  test "tickPlayback drops rate when fetch latency outpaces the interval":
    let vm = createVideoPlayerVM(createFrameViewerVM(makeMinimalClient()))
    vm.frameVm.frameCount.val = 600
    vm.frameVm.currentFrame.val = 200
    ## Pre-load the fetch ring with values that flag buffering.
    vm.frameVm.medianFetchMs.val = 50
    vm.fastForward()            ## play 1× forward
    vm.fastForward()            ## now 2×
    vm.fastForward()            ## now 4×
    check vm.rate.val == Rate4x
    vm.tickPlayback(0.0)        ## baseline
    vm.tickPlayback(100.0)
    ## 50 ms median > 4.16 ms interval at 4× → degrade one step.
    check vm.bufferingDegraded.val
    check vm.rate.val == Rate2x

  test "tickPlayback clears buffering flag once latency improves and hysteresis elapses":
    let vm = createVideoPlayerVM(createFrameViewerVM(makeMinimalClient()))
    vm.frameVm.frameCount.val = 600
    vm.frameVm.currentFrame.val = 200
    vm.frameVm.medianFetchMs.val = 50
    vm.fastForward()            ## 1×
    vm.fastForward()            ## 2×
    vm.tickPlayback(0.0)        ## baseline
    vm.tickPlayback(50.0)
    check vm.bufferingDegraded.val
    ## Now simulate latency recovering and 1.5s elapsing.
    vm.frameVm.medianFetchMs.val = 5
    vm.tickPlayback(60.0)            ## start hysteresis timer
    vm.tickPlayback(60.0 + 1_500.0)  ## past 1s window → flag clears
    check not vm.bufferingDegraded.val

  test "pause() clears bufferingDegraded immediately":
    let vm = createVideoPlayerVM(createFrameViewerVM(makeMinimalClient()))
    vm.frameVm.frameCount.val = 600
    vm.bufferingDegraded.val = true
    vm.fastForward()
    vm.togglePlay()                    ## now paused
    check not vm.bufferingDegraded.val

# ---------------------------------------------------------------------------
# Startup-spinner predicate.
# ---------------------------------------------------------------------------

suite "VideoPlayerVM startup spinner":
  test "isStartupSpinnerVisible: hidden when visual replay is not available":
    check not isStartupSpinnerVisible(
      visualReplayAvailable = false,
      playerUrl = "http://stub/",
      frameCount = 0,
      errorMessage = "")

  test "isStartupSpinnerVisible: hidden when there is no player URL":
    check not isStartupSpinnerVisible(
      visualReplayAvailable = true,
      playerUrl = "",
      frameCount = 0,
      errorMessage = "")

  test "isStartupSpinnerVisible: hidden once frameCount is known":
    check not isStartupSpinnerVisible(
      visualReplayAvailable = true,
      playerUrl = "http://stub/",
      frameCount = 600,
      errorMessage = "")

  test "isStartupSpinnerVisible: hidden when an error is showing":
    check not isStartupSpinnerVisible(
      visualReplayAvailable = true,
      playerUrl = "http://stub/",
      frameCount = 0,
      errorMessage = "Player crashed")

  test "isStartupSpinnerVisible: visible while waiting for /info":
    check isStartupSpinnerVisible(
      visualReplayAvailable = true,
      playerUrl = "http://stub/",
      frameCount = 0,
      errorMessage = "")

# ---------------------------------------------------------------------------
# Scrub-slider clear-frame ticks (layoutScrubTicks).
# ---------------------------------------------------------------------------

suite "VideoPlayerVM scrub-slider clear-frame ticks":
  test "layoutScrubTicks returns no ticks for an empty input":
    check layoutScrubTicks(newSeq[int](), 600).len == 0

  test "layoutScrubTicks returns no ticks when frameCount <= 1":
    check layoutScrubTicks(@[0], 0).len == 0
    check layoutScrubTicks(@[0], 1).len == 0

  test "layoutScrubTicks positions ticks proportionally across the slider":
    let ticks = layoutScrubTicks(@[0, 50, 100], 101)
    check ticks.len == 3
    check ticks[0].frame == 0
    check ticks[0].leftPercent == 0.0
    check ticks[1].frame == 50
    check ticks[1].leftPercent == 50.0
    check ticks[2].frame == 100
    check ticks[2].leftPercent == 100.0

  test "layoutScrubTicks drops out-of-range indices":
    let ticks = layoutScrubTicks(@[-5, 0, 200, 300, 1000], 201)
    ## -5 and 300/1000 fall outside [0, 200]; 0 and 200 stay.
    check ticks.len == 2
    check ticks[0].frame == 0
    check ticks[1].frame == 200
    check ticks[1].leftPercent == 100.0
