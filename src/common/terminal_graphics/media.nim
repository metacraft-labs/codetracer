## terminal_graphics/media.nim — PLAT-14. WHICH §5.2 MEDIA A RESOLVED
## TERMINAL CAN DRAW.
##
## ## WHY THIS IS IN `terminal_graphics/` AND NOT IN `value_presentation/`
##
## It is a function from an `ImageTier` and an `ImageProtocol` to a
## `set[MediaClass]`, so it has to name types from both packages, and the
## direction of the dependency is a decision rather than a coin toss:
##
##   * `value_presentation/` is the PIPELINE. `ci/test/value-presentation-
##     boundary.sh`'s contract suite copies that package alone into a synthetic
##     tree and compiles it, which is what lets it plant a bypass and prove the
##     rule fires. A pipeline module importing this package would break that
##     suite for a reason that has nothing to do with the rule it checks — and
##     it did, on the first draft of this milestone.
##   * `terminal_graphics/` is the RENDERER, and a renderer knowing what a
##     media class is is ordinary. The reverse — the pipeline knowing what a
##     terminal tier is — would make `Budget` a terminal concept on the
##     desktop's surfaces too.
##
## So the arrow points this way, and `surfaces.nim` takes a plain
## `set[MediaClass]` it does not have to compute.

import ../value_presentation/vocabulary
import ../value_presentation/surfaces
import ./tiers

export tiers.ImageTier, tiers.ImageProtocol

func terminalMediaCapability*(tier: ImageTier;
                              protocol: ImageProtocol): set[MediaClass] =
  ## PLAT-14. What a TERMINAL surface can draw, given the tier and the protocol
  ## `app/theme/image_capability.resolveImageCapability` settled on.
  ##
  ## ## THE SET IS DECIDED BY THE DECODER, NOT BY THE TIER'S FIDELITY
  ##
  ## This is the part that is easy to get optimistically wrong, so it is
  ## written out. §5.2's media types name ENCODED formats; the cell tiers
  ## (`terminal_graphics/cell_render.nim`) consume a RASTER. The bridge between
  ## them is a PNG/JPEG decoder, and this build has none — see
  ## `terminal_graphics/raster.nim`'s header. So:
  ##
  ##   * **Tier 0 draws `image/png`** on Kitty and on iTerm2, because neither
  ##     needs a decoder in this process: Kitty's `f=100` and iTerm2's
  ##     `File=inline` both take the encoded bytes and decode them in the
  ##     terminal. This is the arm PLAT-12 predicted and it is now reachable.
  ##   * **Tier 0 draws `image/jpeg` on iTerm2 only.** Kitty's `f=100` is PNG;
  ##     its other `f=` values are raw pixel formats. A JPEG handed to Kitty
  ##     would be transmitted and rejected, which is a blank region with extra
  ##     steps.
  ##   * **Every cell tier draws neither**, and that is the honest answer
  ##     rather than a missing feature dressed as one. A `image/png` value on a
  ##     terminal with no graphics protocol degrades through PLAT-9's
  ##     `pdDependencyMissing`, with `describeMediaGap` naming the type, the
  ##     surface and the remedy, and with the rest of the value still
  ##     presenting.
  ##   * **`image/svg+xml`, the two audio types and the two text types are
  ##     never drawn by a terminal here.** SVG needs a rasteriser, audio needs
  ##     a device, and rendered markdown and HTML are a layout problem rather
  ##     than a pixel one. Each is outside PLAT-14 and each degrades.
  ##
  ## `mcOctetStream` is in every answer, because `builtin.byte-buffer`'s
  ## `01 02 ff … (12 bytes)` rendering has been true on every surface since
  ## CTUI-7 and PLAT-14 changes nothing about it.
  result = MediaCapabilityNote
  if tier != itProtocol:
    return
  case protocol
  of ipKitty: result.incl mcImagePng
  of ipITerm2:
    result.incl mcImagePng
    result.incl mcImageJpeg
  of ipSixel, ipNone: discard
