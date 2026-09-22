## chrome.nim — PLAT-37. The colours `codetracer-gpui` paints its window with.
##
## ## Why this module exists at all, and what it is NOT
##
## PLAT-20 through PLAT-23 built a shadow tree and never opened a window, so
## nothing in this front-end had ever needed a colour. The whole of
## `gpui/app/leaves.nim` sets **two** styles, both `display: flex`, and
## `gpui_app.rs`'s `apply_styles_to_div` does not even read that key — so the
## tree this front-end produces, handed to a real renderer, paints
## default-coloured text on a default background. PLAT-37's claim is *"there
## is a window and its pixels are not the pixels of a blank screen"*, plus the
## OCR join, and neither is reachable from a tree with no colours in it.
##
## **This is NOT a design-system alignment claim, and reading it as one would
## be the tier confusion PLAT-37's instrument contract is written against.**
## Alignment with the Electron design is PLAT-35's, measured per question and
## per scenario, and `PLAT35-VG5` (*"the two front-ends open on different
## default layouts"*) and `PLAT35-VG8` (*"the GPUI state pane publishes no text
## role"*) are filed and stay filed. What is here is the minimum a frame needs
## to exist and be legible: a surface, a foreground, a pane fill, and a title
## colour. Four values.
##
## **Where the four values came from, said plainly rather than implied.** They
## are chosen here, in this milestone, and they are not read out of
## `codetracer-design-system` — because that repository publishes no hex for
## any member of `layout_questions.DesignTokenAlphabet` (checked 2026-09-22:
## `grep -rl 'editor.code.foreground' ../codetracer-design-system` is empty,
## and the Electron front-end resolves a token from a rendered CLASS, never
## from a colour, in `src/tests/gui/tools/layout-answers.ts`'s `q7`). Inventing
## a palette and calling it the design system's would be worse than choosing
## one and saying so. When a published mapping exists, this module is where it
## lands and these constants are what it replaces.
##
## ## The one property that IS asserted rather than asserted-by-eye
##
## A chrome whose foreground and background are close together is a window
## that opens, paints, and photographs as a blank screen — the exact failure
## PLAT-37 exists to make impossible, arriving through the palette instead of
## through the renderer. So contrast is COMPUTED, from the WCAG 2.x relative
## luminance definition, and the floor is a constant the suite reads.
##
## https://www.w3.org/TR/WCAG21/#dfn-relative-luminance
## https://www.w3.org/TR/WCAG21/#dfn-contrast-ratio

import std/[strutils, math]

type
  ChromeRole* = enum
    ## The closed set of things this front-end paints. Closed on purpose: a
    ## role added here is a role `chromeContrastFloorHolds` must then account
    ## for, which is what stops the palette growing a member nobody looked at.
    crWindowBackground = "window.background"
    crWindowForeground = "window.foreground"
    crPaneBackground = "pane.background"
    crPaneTitleForeground = "pane.title.foreground"

const
  WindowChrome*: array[ChromeRole, string] = [
    "#12161c", # crWindowBackground — the surface behind every pane
    "#e6edf3", # crWindowForeground — body text
    "#1b222c", # crPaneBackground — one pane's fill, lifted off the surface
    "#7ee3c8", # crPaneTitleForeground — the pane heading
  ]
    ## Indexed by `ChromeRole`, so a role with no colour does not compile.

  MinimumContrastRatio* = 4.5
    ## WCAG 2.x AA for body text. It is a FLOOR on a computed quantity and not
    ## a description of the values above: raising it is how a future palette is
    ## held to the same standard, and lowering it would be the silent repair
    ## §36a names.
    ##
    ## HISTORY: introduced 2026-09-22 at 4.5. It has never been lowered.

  ChromeGapPx* = 8
  ChromePaddingPx* = 12
    ## The window's own padding and the gap between panes, in device pixels.
    ## They are here rather than in `main.nim` because `paneWidthPx` below has
    ## to subtract exactly these, and two spellings of one number is §30.

func hexChannel(hex: string; index: int): float =
  ## One 8-bit channel of `#rrggbb`, as 0.0 .. 1.0.
  ##
  ## `func`, and it raises `ValueError` on a malformed string rather than
  ## defaulting to zero: a palette entry that is not a colour must fail where
  ## it is written, not paint black and look like a rendering defect.
  let body = if hex.len > 0 and hex[0] == '#': hex[1 .. ^1] else: hex
  if body.len != 6:
    raise newException(ValueError, "not a #rrggbb colour: '" & hex & "'")
  float(parseHexInt(body[index * 2 .. index * 2 + 1])) / 255.0

func relativeLuminance*(hex: string): float =
  ## WCAG 2.x relative luminance of an sRGB colour.
  var linear: array[3, float]
  for i in 0 .. 2:
    let c = hexChannel(hex, i)
    linear[i] =
      if c <= 0.04045: c / 12.92
      else: pow((c + 0.055) / 1.055, 2.4)
  0.2126 * linear[0] + 0.7152 * linear[1] + 0.0722 * linear[2]

func contrastRatio*(a, b: string): float =
  ## The WCAG contrast ratio between two colours, in 1.0 .. 21.0. Symmetric,
  ## which is why the lighter of the two is chosen rather than assumed.
  let (la, lb) = (relativeLuminance(a), relativeLuminance(b))
  let (lighter, darker) = if la >= lb: (la, lb) else: (lb, la)
  (lighter + 0.05) / (darker + 0.05)

func chromeOf*(role: ChromeRole): string =
  WindowChrome[role]

func paneWidthPx*(viewportWidth, paneCount: int): int =
  ## How wide one pane is when `paneCount` of them tile the window's width.
  ##
  ## Derived rather than declared, because the number that matters is the one
  ## the renderer receives: `gpui_app.rs`'s `apply_styles_to_div` accepts
  ## `100%` / `full` or a pixel value and NOTHING ELSE — no `50%`, no `1fr` —
  ## so a front-end that wants two panes side by side has to do this division
  ## itself. Returns at least 1 so a degenerate viewport produces a visible
  ## sliver rather than a zero-width div the renderer silently drops.
  if paneCount <= 0:
    return max(1, viewportWidth - 2 * ChromePaddingPx)
  let usable = viewportWidth - 2 * ChromePaddingPx - (paneCount - 1) * ChromeGapPx
  max(1, usable div paneCount)
