## pixel_capture.nim — the GPUI front-end's OWN scene, rendered to pixels.
##
## ## What this is for
##
## PLAT-35's loop is *capture → review → fix → re-capture*, and on
## aarch64-darwin it had no capture step at all. PLAT-37 measured why, and
## the two halves of the measurement are both recorded here because the
## remedy only makes sense against both:
##
##   1. A `codetracer-gpui` WINDOW does open on macOS and can be observed
##      without any entitlement — `CGWindowListCopyWindowInfo` reports
##      `owner=codetracer-gpui bounds=1280x829 layer=0`. Reading that
##      window's PIXELS is refused: `screencapture -x -o -l<id>` answers
##      *"could not create image from window"*, rc 1, because the session
##      is in the Background bootstrap namespace with no TCC grant. That is
##      a HOST fact, and `grim` — which every one of the nine window-capture
##      lanes calls — speaks a Wayland protocol that does not exist here.
##   2. `isonim-gpui`'s SECOND pixel path does work here.
##      `ci/test/plat37_headless_probe.nim` runs unmodified and reports
##      `rc 0`, 256,000 of 256,000 bytes non-zero, 21 distinct byte values
##      out of `gpui_render_to_pixels` — Zed's
##      `HeadlessAppContext::with_platform` + `Window::render_to_image`,
##      which needs no compositor and no entitlement.
##
## **And the probe's scene is not the product's.** It builds two nested
## divs 320x200 and renders them, which answers *"can this host rasterise
## at all"* and nothing about the front-end. So the enabling work is to put
## the FRONT-END's own tree through that same call, which is all this
## module does.
##
## ## The tier this produces, said plainly
##
## An off-screen RGBA buffer is a FRAME and it is **not a window**, so this
## path does not satisfy PLAT-23's G1 and `satisfiesG1` is written `false`
## in every record it emits — the same label `plat37_headless_probe.nim`
## carries, for the same reason, kept identical so a reader cannot infer
## one path's standing from the other's. What it does satisfy is the
## methodology's capture step: an image file at a named path, for a named
## view at a named viewport, that a review sub-agent can look at.
##
## ## Why the census is part of the answer rather than a caller's business
##
## *A capture that writes a file is not evidence the scene rendered.* A
## renderer handed a tree it cannot draw returns a correctly-sized buffer
## of zeroes, and a lane that asserts `test -s <file>` passes on it. So
## `renderRootToPixels` counts the non-zero bytes and the distinct byte
## values before it returns, every caller gets them, and
## `captureIsBlank` is the one predicate that separates *drew something*
## from *produced a buffer*. This is exactly the shape the headless probe
## already uses and the reason it uses it.

when defined(js):
  {.error: "gpui/host/pixel_capture is native-only: it writes image files.".}

import std/[json, os, strutils]

import isonim_gpui/bindings

import ../../../common/png

type
  PixelCaptureStatus* = enum
    ## The shim's own numeric contract, named.
    ##
    ## The NUMBERS are the stable part of the FFI — `gpui_headless.rs`'s
    ## `ErrorCode` lives inside a `#[cfg]`-gated Rust module, so the enum
    ## itself is not visible to a featureless build while the codes are —
    ## and `bindings.nim` documents them. `plat37_headless_probe.nim`
    ## mirrors the same three it needs as bare literals; this enum covers
    ## all of them because a front-end has to tell a user which one
    ## happened.
    pcsOk = 0
    pcsInvalidArgs = 1
    pcsRendererUnavailable = 2
    pcsWindowOpenFailed = 3
    pcsCaptureFailed = 4
    pcsSizeMismatch = 5
    pcsPanic = 6
    pcsUnknown = 7
      ## A code this build has no name for. Reported with the raw `rc`
      ## beside it rather than folded into one of the known ones.
    pcsShortBuffer = 8
      ## `rc` was 0 and the byte count was not `width * height * 4`. A
      ## SEPARATE state from `pcsSizeMismatch`, which is the shim's own
      ## verdict about the capture it took: this one is the caller
      ## disagreeing with a success, and the two have different causes.

  PixelCapture* = object
    ## One capture, with everything a gate needs to grade it.
    status*: PixelCaptureStatus
    rc*: int
      ## The shim's raw return code, carried even when `status` names it,
      ## because a future code this build does not know is reportable only
      ## as a number.
    width*, height*: int
    bytes*, expectedBytes*: int
    nonZeroBytes*: int
      ## **Not a length.** A buffer of the right size that is all zeroes is
      ## the "opened and painted nothing" state this whole module exists to
      ## be able to see.
    distinctByteValues*: int
      ## How many of the 256 possible byte values occur. A solid fill has
      ## two (the colour's components); a drawn surface with text has
      ## dozens. It separates "one flat rectangle" from "a scene", which
      ## the non-zero count alone cannot.
    rgba*: seq[uint8]
      ## Empty unless `status == pcsOk`.

func statusOf(rc: int): PixelCaptureStatus =
  if rc >= ord(pcsOk) and rc <= ord(pcsPanic):
    PixelCaptureStatus(rc)
  else:
    pcsUnknown

func reasonOf*(c: PixelCapture): string =
  ## One line a user can act on, for every failing status.
  case c.status
  of pcsOk: ""
  of pcsInvalidArgs:
    "the shim refused the request as invalid (zero or oversized extent)"
  of pcsRendererUnavailable:
    "this shim has no headless renderer. `gpui_render_to_pixels` is " &
    "exported by every build and answers 2 unless the shim was built " &
    "with `--features gpui-headless`; stage that build at the path this " &
    "binary dlopens (`isonim-gpui/rust/target/debug/`), as " &
    "`just plat37-shims` produces it"
  of pcsWindowOpenFailed:
    "the headless renderer could not open its off-screen window"
  of pcsCaptureFailed:
    "`Window::render_to_image` failed inside the shim"
  of pcsSizeMismatch:
    "the shim captured an image of a size it did not expect"
  of pcsPanic:
    "the shim panicked, and the panic was caught at the FFI boundary"
  of pcsUnknown:
    "the shim answered " & $c.rc & ", which this build has no name for"
  of pcsShortBuffer:
    "the shim reported success and handed back " & $c.bytes &
    " bytes where " & $c.expectedBytes & " were expected"

func captureIsBlank*(c: PixelCapture): bool =
  ## Whether the frame is indistinguishable from a blank screen.
  ##
  ## TWO conditions, because each catches a different failure and neither
  ## implies the other: an all-zero buffer is a renderer that drew nothing,
  ## and a buffer with one or two distinct byte values is a renderer that
  ## filled the surface and drew no content on it. A capture lane that
  ## checked only the first would publish a solid-colour rectangle as a
  ## frame of the product.
  c.nonZeroBytes == 0 or c.distinctByteValues <= 2

proc renderRootToPixels*(root: GpuiElement; width, height: int): PixelCapture =
  ## Render the shadow tree under `root` off screen, at `width x height`
  ## logical pixels, and census the result.
  ##
  ## `gpui_set_root_element` is what makes this the FRONT-END's scene
  ## rather than an empty one: callers that build a tree without going
  ## through `gpui_launch` have to name the root the headless renderer
  ## reads (`bindings.nim`'s own note on that function). The buffer the
  ## shim returns is RGBA8888 non-premultiplied, row-major, exactly
  ## `width * height * 4` bytes — `gpui_headless.rs` downsamples the test
  ## platform's 2x oversample before it answers — which is PNG colour type
  ## 6's own layout, so nothing between here and the file reorders a
  ## channel.
  ##
  ## The scale argument is 1.0 and deliberately so: the shim's own comment
  ## records that `scale` is validated and then NOT plumbed through the
  ## test platform, so passing anything else would be a parameter that
  ## reads as if it did something.
  result = PixelCapture(width: width, height: height,
                        expectedBytes: width * height * png.RgbaChannels)
  if root.isNil:
    result.status = pcsInvalidArgs
    result.rc = ord(pcsInvalidArgs)
    return
  gpui_set_root_element(root)
  var pixels: ptr uint8 = nil
  var length: csize_t = 0
  let rc = int(gpui_render_to_pixels(cuint(width), cuint(height), 1.0'f32,
                                     addr pixels, addr length))
  result.rc = rc
  result.bytes = int(length)
  if rc != ord(pcsOk):
    result.status = statusOf(rc)
    return
  if pixels.isNil or int(length) != result.expectedBytes:
    result.status = pcsShortBuffer
    if not pixels.isNil:
      gpui_free_pixels(pixels, length)
    return
  let base = cast[ptr UncheckedArray[uint8]](pixels)
  var seen: array[256, bool]
  result.rgba = newSeq[uint8](int(length))
  for i in 0 ..< int(length):
    let b = base[i]
    result.rgba[i] = b
    if b != 0'u8: inc result.nonZeroBytes
    if not seen[int(b)]:
      seen[int(b)] = true
      inc result.distinctByteValues
  gpui_free_pixels(pixels, length)
  result.status = pcsOk

proc captureRecord*(c: PixelCapture; view, scenario: string): JsonNode =
  ## The capture's own answer, in the shape `plat37_headless_probe.nim`
  ## writes, plus the two fields that one has no notion of: WHICH view and
  ## WHICH scenario this frame is of.
  ##
  ## `satisfiesG1` is `false` and is written rather than omitted, so a
  ## reader of this file cannot take an off-screen frame for a window.
  ##
  ## `subject` is what distinguishes this record from the headless probe's:
  ## the tree rendered here is the front-end's, built by the same
  ## `renderLeaves` the window path uses.
  %*{
    "probe": "gpui_render_to_pixels",
    "subject": "codetracer-gpui",
    "view": view,
    "scenario": scenario,
    "width": c.width,
    "height": c.height,
    "rc": c.rc,
    "rcMeaning": (if c.status == pcsOk: "ok" else: $c.status),
    "bytes": c.bytes,
    "expectedBytes": c.expectedBytes,
    "nonZeroBytes": c.nonZeroBytes,
    "distinctByteValues": c.distinctByteValues,
    "producedAFrame": c.status == pcsOk and c.bytes == c.expectedBytes and
                      c.nonZeroBytes > 0,
    "isBlank": c.captureIsBlank,
    "satisfiesG1": false,
    "whyNotG1":
      "PLAT-23's G1 asks that a window has been observed. This path " &
      "renders off screen through Window::render_to_image and opens no " &
      "window, so it cannot close G1 however many frames it produces.",
  }

proc recordPathFor*(imagePath: string): string =
  ## Where the census goes for an image at `imagePath`.
  ##
  ## `<path>.json` rather than `changeFileExt(path, "json")`, because the
  ## latter would make `--pixels-out=shell.json` silently overwrite its own
  ## image, and a capture whose two outputs can collide is a capture that
  ## can report on a file it just destroyed.
  imagePath & ".json"

proc writeCapture*(imagePath: string; c: PixelCapture;
                   view, scenario: string): string =
  ## Write the PNG and its census. Answers "" on success, the diagnosis
  ## otherwise.
  ##
  ## **The record is written even when the capture FAILED**, and that is
  ## the point of writing it at all: a lane that reads stdout cannot tell
  ## *"the capture ran and this host has no headless renderer"* from
  ## *"the capture did not run"*, and those are different states
  ## (Verification-Harness-Traps §4). The IMAGE is only written when there
  ## is one.
  let recordPath = imagePath.recordPathFor
  let dir = imagePath.parentDir
  if dir.len > 0:
    try:
      createDir(dir)
    except OSError as e:
      return "could not create " & dir & ": " & e.msg.splitLines()[0]
  try:
    writeFile(recordPath, c.captureRecord(view, scenario).pretty & "\n")
  except CatchableError as e:
    return "could not write " & recordPath & ": " & e.msg.splitLines()[0]
  if c.status != pcsOk:
    return c.reasonOf
  let failed = png.writePng(imagePath, c.width, c.height, c.rgba)
  if failed.len > 0:
    return failed
  ""
