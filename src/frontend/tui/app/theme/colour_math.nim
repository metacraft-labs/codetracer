## LAYER RULE — `src/frontend/tui/app/` is the SDK-CONSUMING half of the TUI.
## See `app/cli.nim`'s header for the rule and
## `src/frontend/tui/tests/test_tui_facade_boundary.nim` for the walk that
## enforces it.
##
## app/theme/colour_math.nim — the arithmetic that turns a design-system hex
## into what a lesser terminal can show, and the arithmetic the contrast and
## background-detection decisions rest on. Pure functions, no I/O, no tables of
## colours of its own beyond the TERMINALS' published palettes.
##
## ## Perceptual distance: OKLab
##
## The transform itself is `common/terminal_graphics/oklab.nim`'s; this module
## adds the distance, chroma and palette searches the rungs need.
##
## The 256- and 16-colour rungs are the NEAREST palette entry to each token's
## hex. "Nearest" is measured in OKLab (Björn Ottosson, 2020,
## https://bottosson.github.io/posts/oklab/), a perceptual space in which
## Euclidean distance tracks perceived difference far better than it does in
## sRGB — a squared-RGB metric picks `blue` for a desaturated slate and `green`
## for a cyan the eye reads as blue. The same space answers "are these two
## surfaces visibly different" for the surface-distinctness tests.
##
## ## The terminals' palettes
##
## The 16 entries are xterm's defaults (the values `nearestAnsiName` has always
## used); the 6x6x6 cube and the 24-step grey ramp of the 256-colour palette are
## xterm's `256colres.pl` formula. A terminal whose user re-themed the first
## sixteen is exactly why `--palette=terminal` exists; the 256-colour rung maps
## ONLY into indices 16..255, which no mainstream terminal theme redefines.
##
## ## Contrast and luminance: WCAG 2.x
##
## https://www.w3.org/TR/WCAG21/#dfn-relative-luminance
## https://www.w3.org/TR/WCAG21/#dfn-contrast-ratio

import std/[math, strutils]

import ../../../../common/terminal_graphics/oklab
import ../../../../common/terminal_graphics/raster

type
  Rgb8* = tuple[r, g, b: int]
  Lab* = tuple[l, a, b: float]

const
  AnsiNames*: array[16, string] = [
    "black", "red", "green", "yellow", "blue", "magenta", "cyan", "white",
    "bright_black", "bright_red", "bright_green", "bright_yellow",
    "bright_blue", "bright_magenta", "bright_cyan", "bright_white"]
    ## The sixteen names `isonim_tui`'s compositor accepts, in SGR index order.

  XtermAnsiRgb*: array[16, Rgb8] = [
    (0, 0, 0), (205, 0, 0), (0, 205, 0), (205, 205, 0),
    (0, 0, 238), (205, 0, 205), (0, 205, 205), (229, 229, 229),
    (127, 127, 127), (255, 0, 0), (0, 255, 0), (255, 255, 0),
    (92, 92, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255)]
    ## xterm's default values for the sixteen, which is the palette a derived
    ## 16-colour rung is nearest to. A user's own palette may differ; that is
    ## the terminal palette's case, not this one's.

func parseHexColour*(s: string; ok: var bool): Rgb8 =
  ## `#rrggbb` -> channels. `ok` is false for anything else.
  ok = false
  if s.len != 7 or s[0] != '#':
    return (0, 0, 0)
  for i in 1 .. 6:
    if s[i] notin HexDigits:
      return (0, 0, 0)
  ok = true
  (fromHex[int](s[1 .. 2]), fromHex[int](s[3 .. 4]), fromHex[int](s[5 .. 6]))

func parseHexColour*(s: string): Rgb8 =
  ## `#rrggbb` -> channels; black for anything else. Callers that must tell a
  ## bad spelling from black use the `ok` overload.
  var ok = false
  parseHexColour(s, ok)

func hexOf*(c: Rgb8): string =
  ## Channels -> the lowercase `#rrggbb` spelling the compositor accepts.
  "#" & toHex(c.r, 2).toLowerAscii & toHex(c.g, 2).toLowerAscii &
    toHex(c.b, 2).toLowerAscii

func xterm256Rgb*(index: int): Rgb8 =
  ## The colour of one entry of xterm's 256-colour palette.
  if index < 16:
    return XtermAnsiRgb[max(0, index)]
  if index < 232:
    const Levels = [0, 95, 135, 175, 215, 255]
    let n = index - 16
    return (Levels[(n div 36) mod 6], Levels[(n div 6) mod 6], Levels[n mod 6])
  let grey = 8 + (min(index, 255) - 232) * 10
  (grey, grey, grey)

func srgbToLinear(c: int): float =
  let v = c.float / 255.0
  if v <= 0.04045: v / 12.92 else: pow((v + 0.055) / 1.055, 2.4)

func toOklab*(c: Rgb8): Lab =
  ## sRGB -> OKLab. DELEGATES to `common/terminal_graphics/oklab.toOklab`
  ## (Ottosson's reference transform, already this tree's for PLAT-15's cell
  ## renderer) rather than carrying a second copy of the matrices.
  let o = oklab.toOklab(Rgb(r: uint8(clamp(c.r, 0, 255)),
                            g: uint8(clamp(c.g, 0, 255)),
                            b: uint8(clamp(c.b, 0, 255))))
  (o.l, o.a, o.b)

func labDistance*(a, b: Lab): float =
  sqrt((a.l - b.l) ^ 2 + (a.a - b.a) ^ 2 + (a.b - b.b) ^ 2)

func oklabDistance*(x, y: Rgb8): float =
  ## Euclidean distance in OKLab. About 0.02 is a just-noticeable difference.
  labDistance(toOklab(x), toOklab(y))

func chroma*(c: Rgb8): float =
  ## OKLab chroma: how far from grey. Below about 0.04 a colour reads as a
  ## neutral.
  let lab = toOklab(c)
  sqrt(lab.a * lab.a + lab.b * lab.b)

let XtermLab: array[256, Lab] = block:
  ## xterm's 256 entries in OKLab, converted ONCE. The palette searches below
  ## run for every role in every mode when the role table is derived at start-
  ## up; converting the palette per search (256 `cbrt` triples each time) was
  ## measured at ~25 ms of cold start on a loaded host — half of CTUI-11's
  ## 50 ms budget — and this table is what takes it back out.
  var t: array[256, Lab]
  for i in 0 .. 255:
    t[i] = toOklab(xterm256Rgb(i))
  t

proc nearestIn(c: Rgb8; candidates: openArray[int]): int =
  let lab = toOklab(c)
  var bestD = Inf
  result = candidates[0]
  for i in candidates:
    let d = labDistance(lab, XtermLab[i])
    if d < bestD:
      bestD = d
      result = i

const
  AllAnsi = [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
  NeutralChroma* = 0.04
    ## OKLab chroma below which a colour reads as a GREY.
  ChromaticAnsi* = [1, 2, 3, 4, 5, 6, 9, 10, 11, 12, 13, 14]
    ## The six hues and their bright twins.
  NeutralAnsi* = [0, 7, 8, 15]
    ## Black, white, bright black, bright white.

proc nearestAnsi16*(c: Rgb8): int =
  ## The index (0..15) of the xterm default nearest to `c` in OKLab.
  nearestIn(c, AllAnsi)

proc nearestAnsi16Family*(c: Rgb8): int =
  ## THE 16-COLOUR DERIVATION: the nearest xterm default IN THE COLOUR'S OWN
  ## FAMILY. A chromatic colour (OKLab chroma >= `NeutralChroma`) maps to the
  ## nearest of the twelve chromatic entries — its HUE family — and a neutral
  ## to the nearest of the four greys.
  ##
  ## Measured, not assumed: plain nearest-in-OKLab sends a dark saturated green
  ## (`ui/surface/alert/success` `#15803d`) to `bright_black`, because the grey
  ## is closer in LIGHTNESS than any ANSI green is — which put the "modified"
  ## tag and a selected row's background on ONE index. A hue is what a
  ## sixteen-colour palette can carry; lightness it mostly cannot.
  if chroma(c) >= NeutralChroma: nearestIn(c, ChromaticAnsi)
  else: nearestIn(c, NeutralAnsi)

proc nearestXterm256*(c: Rgb8): int =
  ## The index (16..255) of the xterm 256-palette entry nearest to `c` in
  ## OKLab. The first sixteen are excluded on purpose: they are the entries a
  ## user's theme redefines, so a derived 256-colour rung that landed on one
  ## would be painting the user's palette rather than the design's.
  let lab = toOklab(c)
  var bestD = Inf
  result = 16
  for i in 16 .. 255:
    let d = labDistance(lab, XtermLab[i])
    if d < bestD:
      bestD = d
      result = i

func relativeLuminance*(c: Rgb8): float =
  ## WCAG 2.x relative luminance.
  0.2126 * srgbToLinear(c.r) + 0.7152 * srgbToLinear(c.g) +
    0.0722 * srgbToLinear(c.b)

func contrastRatio*(x, y: Rgb8): float =
  ## WCAG 2.x contrast ratio, 1.0 .. 21.0, order-independent.
  let a = relativeLuminance(x)
  let b = relativeLuminance(y)
  (max(a, b) + 0.05) / (min(a, b) + 0.05)
