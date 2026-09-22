## plat37_headless_probe.nim — PLAT-37's SECOND pixel path, measured.
##
## ## What this is for, and what it deliberately is NOT for
##
## `isonim-gpui`'s shim carries two coexisting features that both end in
## pixels, and this campaign had never priced the second one:
##
##   `gpui-backend`   opens a real window through `gpui_launch` ->
##                    `Application::run`. Needs a compositor. The windowed
##                    path, captured with `grim`.
##   `gpui-headless`  `gpui_render_to_pixels` over Zed's
##                    `HeadlessAppContext::with_platform` +
##                    `Window::render_to_image`, with its own Rust suites
##                    (`test_headless_render.rs`, `test_async_render.rs`).
##                    Needs NO compositor at all.
##
## **THE HEADLESS PATH IS NOT A SUBSTITUTE FOR THE WINDOWED ONE, AND THE
## REASON IS PLAT-23'S OWN THRESHOLD.** G1 asks that *"a window has been
## observed"*. An off-screen RGBA buffer is a frame; it is not a window. So
## the two are specified together and LABELLED per row — the windowed path
## carries G1, this one is measured beside it as the cheaper lane every later
## milestone's per-frame assertions can use — and `manifest.json`'s
## `pixelPaths` records `satisfiesG1` explicitly for each, so a future reader
## cannot infer one from the other.
##
## This also RE-MEASURES a sentence rather than re-quoting it. PLAT-19's
## residual reads *"Linux headless pixel capture is upstream's gap at
## `562a0e03`, gated `#[cfg(target_os = "macos")]` alone"*. That is a
## statement about that revision. The shim has since been pinned to `gpui-pre`
## `0.3.5` and grown `gpui-headless`, so the sentence has to be re-taken, and
## this file is what takes it. The answer it writes is the answer, whichever
## way it comes out: a `RendererUnavailable` here is a MEASUREMENT, not a
## failure of this probe, and the gate asserts what the measurement says
## rather than what anyone hoped it would say.
##
## ## Why it writes a file instead of printing
##
## `-d:plat37HeadlessOut=<path>` is read at compile time and the answer is
## written there, so the lane can tell "the probe ran and the path is
## unavailable" from "the probe did not run". Those are different states and a
## script that reads stdout cannot distinguish them from a crash
## (Verification-Harness-Traps §4).

import std/[json, os, strutils]

import isonim_gpui/bindings

const OutPath {.strdefine: "plat37HeadlessOut".} = ""

when OutPath.len == 0:
  {.error: "plat37_headless_probe needs -d:plat37HeadlessOut=<path>".}

const
  ProbeWidth = 320'u32
  ProbeHeight = 200'u32
  ProbeScale = 1.0'f32

  # `gpui_headless.rs`'s own numeric contract, mirrored here as literals
  # because the enum lives inside a `#[cfg]`-gated Rust module and the
  # NUMBERS are the stable part of the FFI. `bindings.nim` documents them.
  ErrOk = 0
  ErrInvalidArgs = 1
  ErrRendererUnavailable = 2

proc main() =
  # A SCENE, because a renderer handed an empty tree can return a buffer and
  # say nothing about whether it can draw. Two nested divs with a background
  # each: the same shape the windowed path paints, one tenth the size.
  let root = gpui_create_element("div".cstring)
  gpui_set_style(root, "background-color".cstring, "#12161c".cstring)
  gpui_set_style(root, "width".cstring, "100%".cstring)
  gpui_set_style(root, "height".cstring, "100%".cstring)
  let box = gpui_create_element("div".cstring)
  gpui_set_style(box, "background-color".cstring, "#7ee3c8".cstring)
  gpui_set_style(box, "width".cstring, "80px".cstring)
  gpui_set_style(box, "height".cstring, "40px".cstring)
  gpui_append_child(root, box)
  gpui_set_root_element(root)

  var pixels: ptr uint8 = nil
  var length: csize_t = 0
  let rc = gpui_render_to_pixels(ProbeWidth, ProbeHeight, ProbeScale,
                                 addr pixels, addr length)

  # NON-NUL BYTES, not merely a length. A buffer of the right size that is all
  # zeroes is exactly the "opened and painted nothing" state this milestone
  # exists to be able to see, and a length check cannot tell them apart.
  var nonZero = 0
  var distinctBytes: array[256, bool]
  var distinctCount = 0
  if rc == ErrOk and not pixels.isNil and length > 0:
    let base = cast[ptr UncheckedArray[uint8]](pixels)
    for i in 0 ..< int(length):
      let b = base[i]
      if b != 0'u8: inc nonZero
      if not distinctBytes[int(b)]:
        distinctBytes[int(b)] = true
        inc distinctCount
    gpui_free_pixels(pixels, length)

  let expected = int(ProbeWidth) * int(ProbeHeight) * 4
  let answer = %*{
    "probe": "gpui_render_to_pixels",
    "width": int(ProbeWidth),
    "height": int(ProbeHeight),
    "rc": rc,
    "rcMeaning":
      if rc == ErrOk: "ok"
      elif rc == ErrRendererUnavailable: "renderer-unavailable"
      elif rc == ErrInvalidArgs: "invalid-args"
      else: "unknown-" & $rc,
    "bytes": int(length),
    "expectedBytes": expected,
    "nonZeroBytes": nonZero,
    "distinctByteValues": distinctCount,
    # THE TWO CLAIMS, ANSWERED SEPARATELY AND NEITHER INFERRED FROM THE OTHER.
    "producedAFrame": rc == ErrOk and int(length) == expected and nonZero > 0,
    "satisfiesG1": false,
    "whyNotG1":
      "PLAT-23's G1 asks that a window has been observed. This path renders " &
      "off screen through Window::render_to_image and opens no window, so it " &
      "cannot close G1 however many frames it produces.",
  }
  writeFile(OutPath, answer.pretty)
  echo "plat37 headless probe: rc=", rc, " bytes=", length,
       " nonZero=", nonZero, " -> ", OutPath.splitPath.tail

when isMainModule:
  main()
