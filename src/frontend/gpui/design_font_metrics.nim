## design_font_metrics.nim — how wide the design system's interface face sets
## a string, without a text system.
##
## The window's geometry (`window_geometry`, `window_top_bar`) is integer
## arithmetic computed before anything is drawn, so a click, a drop caret and
## the drawn element agree about where each label is. It used to budget a
## flat `TabCharPx` (10 px) a character, which is no face's metric: the
## desktop's footer labels are sized by their text, and BUILD there is 54 px
## where ten pixels a letter made it 66.
##
## The advances below are Space Grotesk Regular's own (`hmtx`, units per em
## 1000, printable ASCII from the space), read from
## `libs/codetracer-design-system/SpaceGrotesk_Complete/Fonts/SpaceGrotesk_OTF/
## SpaceGrotesk-Regular.otf` with fontTools on 2026-10-17. Kerning is not
## applied, as the desktop's labels measure without it to the pixel (BUILD
## 38 px, PROBLEMS 71, FIND IN FILES 83, REQUESTS 67 at 14 px with the
## desktop's -0.14 px letter spacing). A character outside the table is
## budgeted as ONE capital M -- one per character, not one per UTF-8 byte:
## until 2026-11-08 a "…" counted three Ms and a "×" or "·" two, which
## over-budgeted the Agent Harbor views' flex bases (an active initiative
## tab holding "2…" and "3×" recording buttons took about 12 px more of a
## full bar than the browser gives it).
##
## Pure: no renderer, no font file at run time.

import std/[math, unicode]

const
  GroteskRegularAdvance: array[32 .. 126, int] = [
    257, 250, 420, 628, 614, 773, 605, 249, 378, 376, 519, 620, 249, 456, 250,
    369, 641, 416, 603, 604, 624, 599, 612, 565, 624, 612, 250, 250, 620, 620,
    620, 580, 1027, 630, 661, 642, 663, 564, 540, 660, 656, 243, 594, 610, 546,
    864, 663, 669, 601, 669, 631, 614, 588, 666, 620, 874, 637, 609, 578, 334,
    369, 334, 620, 620, 280, 575, 644, 599, 644, 593, 442, 643, 613, 244, 246,
    536, 244, 860, 613, 618, 644, 644, 376, 527, 461, 612, 539, 802, 594, 612,
    521, 430, 239, 430, 620]
  GroteskUnitsPerEm = 1000
  LabelLetterSpacing* = -0.14
    ## The desktop's tab and strip labels (`.lm_tab` `letter-spacing`).

func groteskTextWidth*(s: string; sizePx: float; letterSpacing = 0.0): float =
  ## How wide Space Grotesk Regular sets `s` at `sizePx`, unrounded: the
  ## width a browser's fractional layout works with when it decides whether
  ## items still fit on a line. Per character (a UTF-8 rune): one outside
  ## the table counts as a capital M, which over-budgets rather than clips;
  ## letter spacing is added once per character, as a browser adds it.
  var units = 0
  var chars = 0
  for r in s.runes:
    let o = int(r)
    units += (if o in GroteskRegularAdvance.low .. GroteskRegularAdvance.high:
                GroteskRegularAdvance[o]
              else: GroteskRegularAdvance[ord('M')])
    inc chars
  float(units) * sizePx / float(GroteskUnitsPerEm) + letterSpacing * float(chars)

func groteskTextPx*(s: string; sizePx: float; letterSpacing = 0.0): int =
  ## `groteskTextWidth` to the nearest pixel (the desktop's fractional layout
  ## lands its labels there).
  int(round(groteskTextWidth(s, sizePx, letterSpacing)))
