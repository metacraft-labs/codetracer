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
## budgeted as a capital M.
##
## Pure: no renderer, no font file at run time.

import std/math

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

func groteskTextPx*(s: string; sizePx: float; letterSpacing = 0.0): int =
  ## How many pixels Space Grotesk Regular sets `s` in at `sizePx`, to the
  ## nearest pixel (the desktop's fractional layout lands its labels there).
  ## Bytes, not runes: a multi-byte character counts once per byte as a
  ## capital M, which over-budgets rather than clips.
  var units = 0
  for c in s:
    let o = ord(c)
    units += (if o in GroteskRegularAdvance.low .. GroteskRegularAdvance.high:
                GroteskRegularAdvance[o]
              else: GroteskRegularAdvance[ord('M')])
  int(round(float(units) * sizePx / float(GroteskUnitsPerEm) +
            letterSpacing * float(s.len)))
