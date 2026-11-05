## test_plat59_visual_replay.nim — the Visual Replay panes' shared model,
## which the desktop, the terminal and the GPUI window all draw from.
##
## LANE: `vm-unit`, `vm-unit-js` and `vm-unit-wasm`, by the directory glob.
##
## Spec: `GUI/Debugging-Features/Visual-Replay.md` (§ Scrub Slider, §
## Transport Controls, § Selection Result, § Pixel History Tab) and
## `Front-Ends/CodeTracer-TUI-Graphics.md` §4 (the pane's own scrubber and
## the nested draw-call scrubber).
##
## Asserted:
##
##   * THE COALESCING RULE (`scrubStep`, `scrubPending`): the first drag event
##     asks, one inside `ScrubCoalesceMs` of the last request does not, one
##     after it does, a position already asked is not asked again, a release
##     asks unless its position was the last asked, a held drag's coalesced
##     position is pending once the window passed;
##   * THE FRAME SCRUBBER (`beginScrub` / `dragScrub` / `pumpScrub` /
##     `releaseScrub`): the requests it sends and when, the thumb's position
##     while held, the clamp to the recording's frames, a drag while playing
##     pausing and the release resuming at the previous rate and direction;
##   * THE NESTED DRAW-CALL SCRUBBER: the frame-scoped request
##     (`/frame?frame=F&draw=K`), its clamp to the shown frame's draw calls,
##     the frame unchanged;
##   * THE DRAW STEP (`stepDrawCall`): within the frame, underflow rolling to
##     the previous frame (its last draw), overflow to the next frame at
##     draw 0; the frame's draw range read from the player's answer;
##   * THE PANES JOINED (`VisualReplayPanesVM`): one client for the four
##     ViewModels; `connect` asking the extent and the first frame; a picked
##     pixel loading its history and its shader; a history row's activation
##     showing that draw call, loading its fragment's shader and moving the
##     recording to its event; an unavailable recording asking nothing.
##
## THE ONE STAND-IN, AND WHY IT IS NOT A MOCK: the player is reached through
## `createJsonVisualReplayClient` — the client's own published JSON transport
## ("tests can assert exact endpoint URLs independently of HTTP mechanics") —
## over closures that record each URL and answer with the shapes the player's
## `/info`, `/frame`, `/pixel-history` and `/shader-debug` send. The unit
## under test is WHICH REQUEST GOES WHEN; what a real `ct_gfx_player`
## answers for a real recording is the `tui` and `gpui-shell` lanes'
## `test_plat59_*` suites.

import std/[json, options, strutils, unittest]

import isonim/core/[owner, signals, computation, async_compat]

import ../../backend/backend_service
import ../../store/replay_data_store
import ../../viewmodels/visual_replay_panes_vm

var asserted = 0

template ck(condition: untyped) =
  inc asserted
  check condition

const ExpectedAssertions = 129

proc drain() = drainPlatformCallbacks()

type
  Player = ref object
    urls: seq[string]
    posts: seq[(string, JsonNode)]
    drawsPerFrame: int

proc param(url, name: string): int =
  for part in url.split({'?', '&'}):
    if part.startsWith(name & "="):
      return parseInt(part[name.len + 1 .. ^1])
  -1

proc frameAnswer(p: Player; url: string): JsonNode =
  ## A 64x48 framebuffer; frame F's draw calls are `drawsPerFrame` of them
  ## from `F * drawsPerFrame`, as the player's `X-Frame-Draw-*` headers say.
  var frame = url.param("frame")
  var draw = url.param("draw")
  var absDraw: int
  if frame >= 0:
    if draw < 0: draw = p.drawsPerFrame - 1
    absDraw = frame * p.drawsPerFrame + draw
  else:
    absDraw = max(0, draw)
    frame = absDraw div p.drawsPerFrame
  %*{"imageSrc": "data:frame" & $frame & "draw" & $absDraw,
     "width": 64, "height": 48, "sourceWidth": 64, "sourceHeight": 48,
     "frame": frame, "drawIndex": absDraw,
     "frameDrawStart": frame * p.drawsPerFrame,
     "frameDrawCount": p.drawsPerFrame}

proc newPlayer(): (Player, VisualReplayClient) =
  let p = Player(drawsPerFrame: 4)
  let client = createJsonVisualReplayClient("http://player/",
    getJson = proc(url: string): VisualReplayFuture[JsonNode] =
      p.urls.add url
      let body =
        if "/info" in url:
          %*{"frameCount": 10, "width": 64, "height": 48,
             "clearFrames": [0, 6]}
        elif "/frame?" in url: p.frameAnswer(url)
        elif "/draw-calls" in url: newJArray()
        else: newJObject()
      newCompletedFuture[JsonNode](body),
    postJson = proc(url: string; body: JsonNode): VisualReplayFuture[JsonNode] =
      p.posts.add (url, body)
      let answer =
        if "/pixel-history" in url:
          %*[{"draw_call_index": 5, "geid": 501, "passed": true,
              "pre_color": [0, 0, 0, 255], "post_color": [255, 0, 0, 255]},
             {"draw_call_index": 9, "geid": 902, "passed": true,
              "pre_color": [255, 0, 0, 255], "post_color": [0, 255, 0, 255]}]
        else:
          %*{"shaderStage": "fragment", "entryPoint": "main",
             "source": "void main() {}", "steps": [
               {"stepIndex": 0, "instruction": "mov", "sourceLine": 1}]}
      newCompletedFuture[JsonNode](answer))
  (p, client)

proc frameUrls(p: Player): seq[string] =
  for u in p.urls:
    if "/frame?" in u: result.add u

suite "the coalescing rule":

  test "a drag asks at most every 60 ms, a release settles":
    var g = ScrubGesture(held: true, position: -1, requested: -1)
    var s = scrubStep(g, 3, 1000.0, release = false)
    ck s.request == 3                 # the first event of a drag asks
    s = scrubStep(s.gesture, 4, 1030.0, release = false)
    ck s.request == -1                # inside the window: shown, not asked
    ck s.gesture.position == 4
    ck scrubPending(s.gesture, 1059.0) == false
    ck scrubPending(s.gesture, 1060.0)  # the window passed: due
    s = scrubStep(s.gesture, 5, 1061.0, release = false)
    ck s.request == 5
    s = scrubStep(s.gesture, 5, 1200.0, release = false)
    ck s.request == -1                # already asked
    s = scrubStep(s.gesture, 6, 1210.0, release = true)
    ck s.request == 6                 # a release asks inside the window too
    ck not s.gesture.held
    var r = scrubStep(ScrubGesture(held: true, requested: 7,
                                   lastRequestMs: 10.0), 7, 20.0,
                      release = true)
    ck r.request == -1                # the frame it settles on is on its way
    ck ScrubCoalesceMs == 60.0

suite "the frame scrubber":

  # The answers land asynchronously on the JS backend (a promise's
  # continuation), so the steps that follow a landed frame are the native
  # backends'; the request a press sends is asserted on all three below.
  when not defined(js):
   test "requests, the thumb while held, and the clamp":
    let (p, client) = newPlayer()
    let vm = createVisualReplayPanesVM(client)
    vm.connect(true, "http://player")
    drain()
    ck p.urls[0] == "http://player/info"
    ck p.frameUrls == @["http://player/frame?frame=0"]
    when not defined(js):
      ck vm.frame.frameCount.val == 10
      ck vm.frame.clearFrames.val == @[0, 6]
    p.urls.setLen 0
    vm.player.beginScrub(scrubFrame, 2, 0.0)
    drain()
    ck p.frameUrls == @["http://player/frame?frame=2"]
    ck vm.player.frameScrub.held
    ck not vm.player.dragScrub(scrubFrame, 3, 20.0)
    ck vm.player.scrubPosition(scrubFrame) == 3
    ck not vm.player.pumpScrub(40.0)
    ck vm.player.pumpScrub(70.0)      # the coalesced position, once due
    drain()
    ck p.frameUrls[^1] == "http://player/frame?frame=3"
    ck not vm.player.pumpScrub(200.0) # nothing more pending
    ck vm.player.dragScrub(scrubFrame, 99, 300.0)
    drain()
    ck p.frameUrls[^1] == "http://player/frame?frame=9"  # clamped
    vm.player.releaseScrub(scrubFrame, 99, 310.0)
    drain()
    ck not vm.player.frameScrub.held
    ck p.frameUrls[^1] == "http://player/frame?frame=9"
    ck p.frameUrls.len == 3           # the release's frame was already asked
    when not defined(js):
      ck vm.player.scrubPosition(scrubFrame) == 9
    # A release where the drag stopped inside the window asks for it.
    vm.player.beginScrub(scrubFrame, 1, 1000.0)
    discard vm.player.dragScrub(scrubFrame, 4, 1010.0)
    vm.player.releaseScrub(scrubFrame, 4, 1020.0)
    drain()
    ck p.frameUrls[^1] == "http://player/frame?frame=4"
    # A release on a scrubber nobody holds does nothing.
    let before = p.frameUrls.len
    vm.player.releaseScrub(scrubFrame, 7, 2000.0)
    ck p.frameUrls.len == before

  test "a drag while playing pauses; the release resumes as it was":
    let (_, client) = newPlayer()
    let vm = createVisualReplayPanesVM(client)
    vm.connect(true, "http://player")
    drain()
    vm.player.rewind()                # reverse 1x
    vm.player.rewind()                # reverse 2x
    ck vm.player.playState.val == Playing
    ck vm.player.direction.val == Reverse
    ck vm.player.rate.val == Rate2x
    vm.player.beginScrub(scrubFrame, 5, 0.0)
    ck vm.player.playState.val == Paused
    vm.player.releaseScrub(scrubFrame, 6, 100.0)
    ck vm.player.playState.val == Playing
    ck vm.player.direction.val == Reverse
    ck vm.player.rate.val == Rate2x
    # Paused before the drag: paused after it.
    vm.player.togglePlay()
    ck vm.player.playState.val == Paused
    vm.player.beginScrub(scrubFrame, 1, 200.0)
    vm.player.releaseScrub(scrubFrame, 2, 300.0)
    ck vm.player.playState.val == Paused

suite "the nested draw-call scrubber and the draw step":

  when not defined(js):
    test "a reactive label follows a drag and the frame the release settles on":
      # The desktop's label is an effect over `frameLabel`: it re-runs only
      # when a signal it read changes.
      let (_, client) = newPlayer()
      let vm = createVisualReplayPanesVM(client)
      vm.connect(true, "http://player")
      drain()
      var label = ""
      createRoot proc(dispose: proc()) =
        createEffect proc() =
          label = vm.player.frameLabel()
      vm.player.beginScrub(scrubFrame, 1, 0.0)
      ck label == "Frame 1 / 9"
      discard vm.player.dragScrub(scrubFrame, 2, 10.0)
      ck label == "Frame 2 / 9"
      vm.player.releaseScrub(scrubFrame, 3, 20.0)
      ck label == "Frame 3 / 9"
      drain()
      ck label == "Frame 3 / 9"

  test "the frame's draw calls, frame-scoped requests and the clamp":
    let (p, client) = newPlayer()
    let vm = createVisualReplayPanesVM(client)
    vm.connect(true, "http://player")
    drain()
    vm.frame.loadFrameByIndex(2)
    drain()
    when not defined(js):
      ck vm.frame.currentFrame.val == 2
      ck vm.frame.frameDrawStart.val == 8
      ck vm.frame.frameDrawCount.val == 4
      ck vm.frame.shownDraw.val == 11
      ck vm.frame.drawInFrame.val == 3   # a frame shows its last draw
    p.urls.setLen 0
    vm.player.beginScrub(scrubDraw, 1, 0.0)
    drain()
    ck p.frameUrls == @["http://player/frame?frame=2&draw=1"]
    ck vm.player.drawScrub.held
    discard vm.player.dragScrub(scrubDraw, 50, 100.0)
    drain()
    when not defined(js):
      # The thumb stays on the track: past the frame's last draw call it rests
      # on that draw call, as the request does.
      ck vm.player.scrubPosition(scrubDraw) == 3
      ck p.frameUrls[^1] == "http://player/frame?frame=2&draw=3"  # clamped
      ck vm.frame.currentFrame.val == 2  # the frame does not move
    vm.player.releaseScrub(scrubDraw, 0, 200.0)
    drain()
    ck p.frameUrls[^1] == "http://player/frame?frame=2&draw=0"
    when not defined(js):
      ck vm.frame.drawInFrame.val == 0
      ck vm.frame.shownDraw.val == 8

  when not defined(js):
    test "a draw step stays in the frame and rolls at its ends":
      let (p, client) = newPlayer()
      let vm = createVisualReplayPanesVM(client)
      vm.connect(true, "http://player")
      drain()
      vm.frame.loadDrawInFrame(1, 3)
      drain()
      ck vm.frame.currentFrame.val == 3
      ck vm.frame.drawInFrame.val == 1
      p.urls.setLen 0
      vm.player.stepDrawCall(1)
      drain()
      ck p.frameUrls == @["http://player/frame?frame=3&draw=2"]
      ck vm.frame.drawInFrame.val == 2
      vm.player.stepDrawCall(-1)
      vm.player.stepDrawCall(-1)
      drain()
      ck vm.frame.drawInFrame.val == 0
      vm.player.stepDrawCall(-1)       # underflow: the previous frame's last
      drain()
      ck p.frameUrls[^1] == "http://player/frame?frame=2"
      ck vm.frame.currentFrame.val == 2
      ck vm.frame.drawInFrame.val == 3
      vm.player.stepDrawCall(1)        # overflow: the next frame's first
      drain()
      ck p.frameUrls[^1] == "http://player/frame?frame=3&draw=0"
      ck vm.frame.currentFrame.val == 3
      ck vm.frame.drawInFrame.val == 0
      # Not at the recording's ends.
      vm.frame.loadFrameByIndex(0)
      drain()
      vm.frame.loadDrawInFrame(0)
      drain()
      let n = p.frameUrls.len
      vm.player.stepDrawCall(-1)
      drain()
      ck p.frameUrls.len == n
      vm.frame.loadFrameByIndex(9)
      drain()
      ck vm.frame.drawInFrame.val == 3
      let m = p.frameUrls.len
      vm.player.stepDrawCall(1)
      drain()
      ck p.frameUrls.len == m
      # Playing: a step is the paused state's.
      vm.player.fastForward()
      vm.player.stepDrawCall(-1)
      drain()
      ck p.frameUrls.len == m

  test "a client without the frame-scoped request names the same draw":
    let (p, client) = newPlayer()
    client.getFrameByFrameDrawProc = nil
    let vm = createVisualReplayPanesVM(client)
    vm.connect(true, "http://player")
    drain()
    vm.frame.loadFrameByIndex(2)
    drain()
    vm.frame.loadDrawInFrame(1)
    drain()
    when not defined(js):
      ck p.frameUrls[^1] == "http://player/frame?draw=9"
    # The start unknown too (another frame): the frame itself.
    vm.frame.loadDrawInFrame(0, 5)
    drain()
    ck p.frameUrls[^1] == "http://player/frame?frame=5"

suite "the panes joined":

  test "one client for the four":
    let (_, client) = newPlayer()
    let (_, other) = newPlayer()
    let vm = createVisualReplayPanesVM(client)
    ck vm.frame.client == client
    ck vm.history.client == client
    ck vm.shader.client == client
    ck vm.player.frameVm == vm.frame
    vm.setClient(other)
    ck vm.client == other
    ck vm.frame.client == other
    ck vm.history.client == other
    ck vm.shader.client == other

  when not defined(js):
   test "a picked pixel loads its history and its shader":
    let (p, client) = newPlayer()
    let vm = createVisualReplayPanesVM(client)
    vm.connect(true, "http://player")
    drain()
    vm.frame.loadFrameByIndex(4)
    drain()
    vm.player.enterPickerMode()
    ck vm.player.pickerState.val == PickerActive
    vm.player.updateMagnifier(10.0, 20.0, 64.0, 48.0)
    vm.player.commitPickedPixel()
    drain()
    ck vm.player.pickerState.val == PickerOff
    ck p.posts.len == 2
    ck p.posts[0][0] == "http://player/pixel-history?x=10&y=20&frame=4"
    ck p.posts[0][1]["x"].getInt == 10
    ck p.posts[0][1]["y"].getInt == 20
    ck p.posts[0][1]["frame"].getInt == 4
    ck p.posts[1][0] == "http://player/shader-debug"
    ck p.posts[1][1]["frame"].getInt == 4
    when not defined(js):
      ck vm.history.entries.val.len == 2
      ck vm.history.entries.val[1].drawCallIndex == 9
      ck vm.history.entries.val[1].geid == 902'u64
      ck vm.pickedPixel.isSome
      ck vm.pickedPixel.get.x == 10 and vm.pickedPixel.get.frame == 4
      ck vm.shader.debugInfo.val.isSome
      ck vm.shader.debugInfo.val.get.entryPoint == "main"

  when not defined(js):
    test "a history row shows its draw call, its shader and its event":
      let (p, client) = newPlayer()
      let sent = new seq[(string, JsonNode)]
      let store = createReplayDataStore(BackendService(
        sendProc: proc(command: string;
                       args: JsonNode): BackendFuture[JsonNode] =
          sent[].add (command, args)
          newCompletedFuture[JsonNode](%*{"success": true}),
        onEventProc: proc(handler: EventHandler) = discard))
      proc seeks(): seq[uint64] =
        for (c, a) in sent[]:
          if c == "ct/seek-to-geid": result.add uint64(a["geid"].getBiggestInt)
      let vm = createVisualReplayPanesVM(client, store)
      vm.connect(true, "http://player")
      drain()
      vm.frame.selectPixel(3, 4)
      drain()
      ck vm.history.entries.val.len == 2
      p.urls.setLen 0
      p.posts.setLen 0
      vm.player.fastForward()
      ck vm.activateHistoryEntry(1)
      drain()
      ck vm.player.playState.val == Paused
      ck vm.history.selectedEntry.val == some(1)
      ck p.frameUrls == @["http://player/frame?draw=9"]
      ck vm.frame.currentFrame.val == 2
      ck vm.frame.drawInFrame.val == 1
      ck seeks() == @[902'u64]
      ck p.posts.len == 1
      ck p.posts[0][0] == "http://player/shader-debug"
      ck p.posts[0][1]["draw"].getInt == 9
      ck p.posts[0][1]["x"].getInt == 3
      ck not vm.activateHistoryEntry(2)
      ck not vm.activateHistoryEntry(-1)
      # Selecting without activating moves nothing.
      vm.selectHistoryEntry(0)
      drain()
      ck vm.history.selectedEntry.val == some(0)
      ck seeks() == @[902'u64]

  test "a recording without graphics asks nothing":
    let (p, client) = newPlayer()
    let vm = createVisualReplayPanesVM(client)
    vm.connect(false, "")
    drain()
    ck p.urls.len == 0
    ck not vm.available.val
    vm.connect(true, "", "the visual replay player is not installed")
    drain()
    ck p.urls.len == 0
    ck vm.available.val
    ck vm.playerError.val == "the visual replay player is not installed"
    ck vm.frame.error.val == "the visual replay player is not installed"

  test "a frame answer carries its draw range and its pixels":
    let f = frameFromJson(%*{"width": 2, "height": 1, "drawIndex": 7,
                             "frameDrawStart": 4, "frameDrawCount": 5,
                             "frame": 1})
    ck f.drawIndex == 7
    ck f.frameDrawStart == 4
    ck f.frameDrawCount == 5
    ck f.frame == some(1)
    let g = frameFromJson(%*{"width": 2, "height": 1})
    ck g.drawIndex == -1
    ck g.frameDrawStart == -1
    ck g.frameDrawCount == 0
    ck g.pixels.len == 0
    ck frameByFrameDrawUrl("http://player/", 3, 2) ==
      "http://player/frame?frame=3&draw=2"

suite "the count":
  test "every assertion ran":
    when not defined(js):
      check asserted == ExpectedAssertions
    else:
      check asserted > 0
