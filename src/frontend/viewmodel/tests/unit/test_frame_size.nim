## test_frame_size.nim — Tier 1 for frames at the pane's size
## (Viewport-Driven-Loading, Decided Q5 — "Frames sized").
##
## The frame viewer tells the player the size it shows frames at; every
## frame request carries it, pixel coordinates stay the framebuffer's, and
## the shown frame is fetched again only when the pane outgrows its image.
##
## WHY A SCRIPTED TRANSPORT: the property under test is the URL the client
## writes and what the ViewModel does with a frame of the player's shape;
## the player's scaling is tested where it lives
## (codetracer-visual-replay `tests/test_frame_scale.nim`). The JSON
## transport `createJsonVisualReplayClient` takes is the production seam.
##
## Runs on the C and JS backends; the two cases that read a frame back are
## C-only, because on JS `createJsonVisualReplayClient` settles every answer
## through a Promise, in a microtask a synchronous test cannot wait for.

import std/[json, options, strutils, unittest]

import isonim/core/[signals, computation, async_compat]

import viewmodels/[visual_replay_client, frame_viewer_vm]

proc drain() = drainPlatformCallbacks()

proc frameAnswer(url: string): JsonNode =
  ## An 800x600 framebuffer, sent at the size the URL asks for.
  var maxW, maxH = 0
  for part in url.split({'?', '&'}):
    if part.startsWith("maxWidth="): maxW = parseInt(part[9 .. ^1])
    if part.startsWith("maxHeight="): maxH = parseInt(part[10 .. ^1])
  let (w, h) = fittedFrameSize(800, 600, maxW, maxH)
  %*{"imageSrc": "data:" & $w & "x" & $h, "width": w, "height": h,
     "sourceWidth": 800, "sourceHeight": 600, "frame": 3}

proc setup(): (ref seq[string], FrameViewerVM) =
  let urls = new seq[string]
  let client = createJsonVisualReplayClient("http://player",
    getJson = proc(url: string): VisualReplayFuture[JsonNode] =
      urls[].add url
      let body = if "/frame?" in url: frameAnswer(url)
                 elif "/draw-calls" in url: newJArray()
                 else: newJObject()
      newCompletedFuture[JsonNode](body))
  (urls, createFrameViewerVM(client))

proc frameUrls(urls: ref seq[string]): seq[string] =
  for u in urls[]:
    if "/frame?" in u: result.add u

suite "frames at the size the pane shows them":

  test "the fit is the player's rule":
    check fittedFrameSize(1600, 900, 800, 800) == (800, 450)
    check fittedFrameSize(640, 480, 1920, 1080) == (640, 480)
    check fittedFrameSize(640, 480, 0, 0) == (640, 480)

  test "a frame request carries the pane's size":
    let (urls, vm) = setup()
    vm.setFrameSize(400, 300)
    vm.loadFrameByIndex(3)
    drain()
    check urls.frameUrls[^1].endsWith("&maxWidth=400&maxHeight=300")

  when not defined(js):
    test "pixels are the framebuffer's, whatever the image's size":
      let (_, vm) = setup()
      vm.setFrameSize(400, 300)
      vm.loadFrameByIndex(3)
      drain()
      check vm.frameWidth.val == 800 and vm.frameHeight.val == 600
      vm.selectPixelFromRenderedPoint(200.0, 150.0, 400.0, 300.0)
      check vm.selectedPixel.val.isSome
      check vm.selectedPixel.val.get.x == 400
      check vm.selectedPixel.val.get.y == 300

    test "a smaller pane keeps the image; a larger one fetches it again":
      let (urls, vm) = setup()
      vm.setFrameSize(400, 300)
      vm.loadFrameByIndex(3)
      drain()
      let before = urls.frameUrls.len
      vm.setFrameSize(200, 150)
      drain()
      check urls.frameUrls.len == before
      vm.setFrameSize(640, 480)
      drain()
      check urls.frameUrls.len == before + 1
      check urls.frameUrls[^1].contains("frame=3&maxWidth=640&maxHeight=480")
      # The framebuffer itself: no limit, and the image is now 1:1.
      vm.setFrameSize(0, 0)
      drain()
      check urls.frameUrls.len == before + 2
      check not urls.frameUrls[^1].contains("maxWidth")
      vm.setFrameSize(900, 700)          # larger than the framebuffer: no gain
      drain()
      check urls.frameUrls.len == before + 2
