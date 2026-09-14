## terminal_graphics/oklab.nim — PLAT-14 deliverable 2's colour space.
##
## §2.3: *"Work in a perceptual colour space. Minimising squared error in sRGB
## weights green wrongly and produces visible banding on gradients. Oklab or
## CIELAB."*
##
## Oklab, per Björn Ottosson's definition:
## https://bottosson.github.io/posts/oklab/ — the sRGB transfer function, the
## published 3x3 to LMS, the cube root, and the published 3x3 to Lab. The
## constants below are that document's, unmodified.
##
## ## WHY THE DISTANCE IS SQUARED AND NEVER ROOTED
##
## Every consumer is an `argmin` over a fixed candidate set, and `sqrt` is
## monotone, so the root changes no decision and costs one call per candidate
## per cell. The type is named `oklabDistanceSq` rather than `oklabDistance` so
## a caller cannot mistake the units — the campaign's rule that a bound, a
## claim and a measurement name the same quantity applies to a metric too.
##
## ## THE CONVERSION IS PURE AND HAS NO TABLE
##
## A 256-entry sRGB-to-linear table would be faster and is deliberately absent:
## it would be a second copy of the transfer function that has to keep agreeing
## with this one, and this package makes no timing claim anywhere that a table
## would be needed to keep.

import std/math

import ./raster

type
  Oklab* = object
    l*: float
    a*: float
    b*: float

func srgbToLinear(channel: uint8): float =
  ## The sRGB electro-optical transfer function, on 0..1.
  let c = float(channel) / 255.0
  if c <= 0.04045: c / 12.92
  else: pow((c + 0.055) / 1.055, 2.4)

func toOklab*(c: Rgb): Oklab =
  ## sRGB bytes to Oklab. Ottosson's `linear_srgb_to_oklab`.
  let r = srgbToLinear(c.r)
  let g = srgbToLinear(c.g)
  let b = srgbToLinear(c.b)

  let l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
  let m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
  let s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b

  let lc = cbrt(l)
  let mc = cbrt(m)
  let sc = cbrt(s)

  Oklab(
    l: 0.2104542553 * lc + 0.7936177850 * mc - 0.0040720468 * sc,
    a: 1.9779984951 * lc - 2.4285922050 * mc + 0.4505937099 * sc,
    b: 0.0259040371 * lc + 0.7827717662 * mc - 0.8086757660 * sc)

func oklabDistanceSq*(a, b: Oklab): float =
  ## Squared Euclidean distance in Oklab. See the header for why it is squared.
  let dl = a.l - b.l
  let da = a.a - b.a
  let db = a.b - b.b
  dl * dl + da * da + db * db

func oklabDistanceSq*(a, b: Rgb): float {.inline.} =
  oklabDistanceSq(toOklab(a), toOklab(b))
