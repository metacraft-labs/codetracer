## FrameViewerVM — ViewModel for MCR visual replay frames.

import std/[algorithm, options, strutils]

import isonim/core/[async_compat, computation, graph, owner, signals]
import isonim/viewmodel

import ../store/replay_data_store
import visual_replay_client

const
  FrameFetchWindowSize* = 8
    ## Ring-buffer size for fetch-latency samples.  Eight samples is wide
    ## enough to dampen single-frame jitter (one slow request followed by
    ## seven fast ones won't trip the degrade flag) but narrow enough to
    ## react inside ~150 ms at 60 fps so the buffering signal feels live.
    ## Spec: codetracer-specs/GUI/Debugging-Features/Visual-Replay.md
    ## §Frame Rate and Buffering — "median fetch time over the last N
    ## frames".

type
  FrameViewerPixel* = object
    x*: int
    y*: int

  FrameViewerPixelSelectionHandler* = proc(x, y, frame: int;
                                           geid: Option[uint64])

  FrameFetchRing* = object
    ## Pure ring-buffer of fetch durations in milliseconds.  Kept as a
    ## value-type so the median-detection helpers can be unit-tested
    ## without instantiating a FrameViewerVM.
    samples*: array[FrameFetchWindowSize, int]
    count*: int             ## Number of valid samples (<= FrameFetchWindowSize).
    nextSlot*: int          ## Write cursor; wraps modulo window size.

  FrameViewerVM* = ref object of ViewModel
    client*: VisualReplayClient
    store*: ReplayDataStore
    reactiveOwner: OwnerBase
    frameRequestSerial: int
    drawCallsFrame: int
      ## The frame whose draw calls `drawCalls` holds; -1 for none. A frame
      ## whose list is held is not asked for again.
    frameInFlight: bool
    pendingFrame: Option[int]
      ## The frame asked for while another frame's load was in flight:
      ## fetched when that load lands, the latest request winning.
    lastStoreGeid: Option[uint64]
    fetchRing: FrameFetchRing
    imageWidth, imageHeight: int
      ## The shown image's own size — the framebuffer scaled to the size it
      ## was asked for (`setFrameSize`).
    reloadShown: proc() {.closure.}
      ## Fetch the frame shown again (at a new size): the last load's target.

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

    ## M5-followup (Visual-Replay.milestones.org): clear-frame indices
    ## from ``/info``, fed into ``layoutScrubTicks`` to render scrub-
    ## slider tick marks at scene boundaries.  Updated once per
    ## ``loadInfo``; empty seq on legacy traces / traces with no
    ## flagged frames.
    clearFrames*: Signal[seq[int]]

    ## Median fetch latency over the last FrameFetchWindowSize samples
    ## (milliseconds).  Updated each time a frame request completes; -1
    ## when no samples have been recorded yet so consumers can
    ## distinguish "no data" from "0 ms" without an extra signal.
    ##
    ## Consumed by VideoPlayerVM to drive the M5 buffering detection.
    medianFetchMs*: Signal[int]

# ---------------------------------------------------------------------------
# Pure ring-buffer helpers (no signals, no I/O) — unit-tested directly.
# ---------------------------------------------------------------------------

proc recordFetchSample*(ring: var FrameFetchRing; durationMs: int) =
  ## Append a fetch duration sample to the ring buffer, evicting the
  ## oldest sample when the window is full.  Negative durations are
  ## clamped to 0 — the only time we'd see one is from a clock-skew
  ## hiccup, and reporting a negative would propagate as a phantom
  ## "instant" sample to the median which is worse than the clamp.
  let clamped = if durationMs < 0: 0 else: durationMs
  ring.samples[ring.nextSlot] = clamped
  ring.nextSlot = (ring.nextSlot + 1) mod FrameFetchWindowSize
  if ring.count < FrameFetchWindowSize:
    inc ring.count

proc medianFetchMsFromRing*(ring: FrameFetchRing): int =
  ## Compute the median of the buffered samples; returns ``-1`` when the
  ## ring is empty so callers can distinguish "no data" from "0 ms".
  if ring.count == 0:
    return -1
  var values: seq[int] = @[]
  for i in 0 ..< ring.count:
    values.add(ring.samples[i])
  values.sort()
  if (ring.count and 1) == 1:
    values[ring.count div 2]
  else:
    ## Average of the two middle samples for an even-sized window.  Using
    ## integer division here is fine — the buffering threshold below
    ## uses an explicit hysteresis margin so a 1 ms truncation never
    ## flips the flag on its own.
    (values[ring.count div 2 - 1] + values[ring.count div 2]) div 2

proc resetFetchRing*(ring: var FrameFetchRing) =
  ## Drop every pending sample.  Used when the underlying player URL
  ## changes (a new player means historical latencies are meaningless).
  ring.count = 0
  ring.nextSlot = 0
  for i in 0 ..< FrameFetchWindowSize:
    ring.samples[i] = 0

# ---------------------------------------------------------------------------
# Cross-platform monotonic millisecond clock for fetch-latency timing.
# ---------------------------------------------------------------------------
#
# JS uses ``performance.now()`` (monotonic, sub-millisecond resolution).
# Native uses ``epochTime() * 1000`` from std/times — adequate for tests
# and the desktop-Nim CLI path.  Both are exposed as plain floats so the
# (now - start) subtraction in onSuccess closures stays trivial.

when defined(js):
  proc nowMs*(): float {.importjs: "performance.now()".}
else:
  import std/times
  proc nowMs*(): float =
    epochTime() * 1000.0

proc recordFetchLatency(vm: FrameViewerVM; startMs: float) =
  ## Wrap the ring-buffer write + signal update so all three frame
  ## fetchers share the same accounting.  ``startMs`` is captured before
  ## the request is issued; we subtract from ``nowMs()`` once the async
  ## callback fires (success or failure path — both feed the median so a
  ## slow error response still triggers degradation rather than
  ## hiding the network problem).
  let elapsed = int(nowMs() - startMs)
  vm.fetchRing.recordFetchSample(elapsed)
  vm.medianFetchMs.val = medianFetchMsFromRing(vm.fetchRing)

proc setFrame(vm: FrameViewerVM; frame: VisualReplayFrame) =
  vm.frameImageSrc.val = frame.imageSrc
  # PIXELS ARE THE FRAMEBUFFER'S: a click on a scaled image maps to the
  # framebuffer's coordinates, which pixel history and the shader debugger
  # take. The image's own size is kept to know when it is too small.
  vm.frameWidth.val = (if frame.sourceWidth > 0: frame.sourceWidth
                       else: frame.width)
  vm.frameHeight.val = (if frame.sourceHeight > 0: frame.sourceHeight
                        else: frame.height)
  vm.imageWidth = frame.width
  vm.imageHeight = frame.height
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
  ## The draw calls of the frame shown — asked for only when the frame
  ## changed (Viewport-Driven-Loading audit finding 20: it used to fetch the
  ## whole list after every frame load).
  let frame = vm.currentFrame.val
  if frame == vm.drawCallsFrame:
    return
  vm.drawCallsFrame = frame
  let fut = vm.client.getDrawCalls(frame)
  async_compat.onComplete(fut,
    onSuccess = proc(calls: seq[VisualReplayDrawCall]) =
      vm.drawCalls.val = calls
      if vm.selectedDrawCall.val.isSome and
          vm.selectedDrawCall.val.get >= calls.len:
        vm.selectedDrawCall.val = none(int),
    onError = proc(message: string) =
      vm.drawCallsFrame = -1
      vm.error.val = message
      vm.drawCalls.val = @[]
      vm.selectedDrawCall.val = none(int))

proc loadFrameForGeid*(vm: FrameViewerVM; geid: uint64) =
  vm.reloadShown = proc() = vm.loadFrameForGeid(geid)
  let serial = vm.beginFrameLoad()
  let startMs = nowMs()
  vm.currentGeid.val = some(geid)
  let fut = vm.client.getFrameByGeid(geid)
  async_compat.onComplete(fut,
    onSuccess = proc(frame: VisualReplayFrame) =
      vm.recordFetchLatency(startMs)
      if not vm.isCurrentFrameRequest(serial):
        return
      vm.setFrame(frame)
      vm.loading.val = false
      vm.loadDrawCalls(),
    onError = proc(message: string) =
      vm.recordFetchLatency(startMs)
      if vm.isCurrentFrameRequest(serial):
        vm.failFrame(message))

proc loadFrameByIndex*(vm: FrameViewerVM; frame: int) =
  ## Show frame `frame`. ONE FRAME REQUEST AT A TIME (UI-Data-Loading-
  ## Guidelines Pattern 6): playback ticks and scrub events arrive faster than
  ## frames load, so while one is in flight a newer target replaces the
  ## pending one instead of being sent, and the latest is fetched when the
  ## in-flight load lands.
  let nextFrame = max(frame, 0)
  vm.reloadShown = proc() = vm.loadFrameByIndex(nextFrame)
  if vm.frameInFlight:
    vm.pendingFrame = some(nextFrame)
    vm.currentFrame.val = nextFrame
    return
  vm.frameInFlight = true
  let serial = vm.beginFrameLoad()
  let startMs = nowMs()
  vm.currentFrame.val = nextFrame
  vm.currentGeid.val = none(uint64)
  let fut = vm.client.getFrameByFrame(nextFrame)
  proc landed(vm: FrameViewerVM): bool =
    ## Release the in-flight slot; `true` when a newer frame was asked for
    ## meanwhile and has now been requested instead.
    vm.frameInFlight = false
    if vm.pendingFrame.isSome:
      let next = vm.pendingFrame.get
      vm.pendingFrame = none(int)
      if next != nextFrame:
        vm.loadFrameByIndex(next)
        return true
    false
  async_compat.onComplete(fut,
    onSuccess = proc(frameData: VisualReplayFrame) =
      vm.recordFetchLatency(startMs)
      if vm.landed() or not vm.isCurrentFrameRequest(serial):
        return
      vm.setFrame(frameData)
      vm.loading.val = false
      vm.loadDrawCalls(),
    onError = proc(message: string) =
      vm.recordFetchLatency(startMs)
      if vm.landed():
        return
      if vm.isCurrentFrameRequest(serial):
        vm.failFrame(message))

proc loadFrameForDraw*(vm: FrameViewerVM; draw: int;
                       seekSource: bool = false;
                       sourceGeid: Option[uint64] = none(uint64)) =
  let nextDraw = max(draw, 0)
  vm.reloadShown = proc() = vm.loadFrameForDraw(nextDraw)
  let serial = vm.beginFrameLoad()
  let startMs = nowMs()
  vm.selectedDrawCall.val = some(nextDraw)
  if sourceGeid.isSome:
    vm.lastStoreGeid = sourceGeid
  let fut = vm.client.getFrameByDraw(nextDraw)
  async_compat.onComplete(fut,
    onSuccess = proc(frame: VisualReplayFrame) =
      vm.recordFetchLatency(startMs)
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
      vm.recordFetchLatency(startMs)
      if vm.isCurrentFrameRequest(serial):
        vm.failFrame(message))

proc setFrameSize*(vm: FrameViewerVM; width, height: int) =
  ## The size, in device pixels, the frame is shown at (Viewport-Driven-
  ## Loading, Decided Q5 — "Frames sized"): every frame is asked for scaled
  ## to fit it. 0 for no limit (the framebuffer as it is — the loupe's 1:1
  ## pixels). The frame shown is fetched again only when the pane grew past
  ## the image while the framebuffer is larger still; a smaller pane keeps
  ## the larger image.
  let w = max(0, width)
  let h = max(0, height)
  if w == vm.client.maxFrameWidth and h == vm.client.maxFrameHeight:
    return
  vm.client.maxFrameWidth = w
  vm.client.maxFrameHeight = h
  if vm.frameImageSrc.val.len == 0 or vm.reloadShown.isNil:
    return
  let want = fittedFrameSize(vm.frameWidth.val, vm.frameHeight.val, w, h)
  if want.width > vm.imageWidth or want.height > vm.imageHeight:
    vm.reloadShown()

proc loadInfo*(vm: FrameViewerVM) =
  let fut = vm.client.getInfo()
  async_compat.onComplete(fut,
    onSuccess = proc(info: VisualReplayInfo) =
      vm.frameCount.val = info.frameCount
      if vm.frameWidth.val == 0: vm.frameWidth.val = info.width
      if vm.frameHeight.val == 0: vm.frameHeight.val = info.height
      ## M5-followup: surface the clear-frame indices so the scrub
      ## slider can render tick marks.  An empty seq is the normal
      ## case for legacy traces — the view degrades to no ticks via
      ## ``layoutScrubTicks``'s empty-input early return.
      vm.clearFrames.val = info.clearFrames,
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
      drawCallsFrame: -1,
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
      medianFetchMs: createSignal(-1),
      clearFrames: createSignal(newSeq[int]()),
      disposeProc: dispose,
    )
    vm.bindReplayStore(store)
    vm
