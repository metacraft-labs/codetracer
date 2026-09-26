## derived_colours.nim — PLAT-46: the ANSI index a role paints with on the
## 16-colour rung, for the Tier-2 suites that read `ckIndexed` cells.
##
## Before PLAT-46 those suites asserted the ANSI name a view SPELLED
## (`bright_yellow` = 11). Views now paint design-system roles and the
## 16-colour rung is DERIVED from each role's token hex (the nearest xterm
## entry in OKLab), so the expected index is that derivation's answer, taken
## from the product's own `roleStyle` — the same function the shipped binary
## resolves with — rather than a number restated in the test. What the suites
## still assert on their own is the part a derivation cannot vouch for: that
## the cell was painted at all, with the role they name, at the column they
## name, and that two roles a reader must tell apart do not share an index.
##
## A row composited WITHOUT `degradeRows` (the snapshot apps under `apps/`) is
## resolved at this same rung in the Dark mode (`styled_row.styledRowNode`), so
## this answer holds for the apps and for the shipped binary under a
## 16-colour `TERM` alike.

import ../../app/theme/colour_math
import ../../app/theme/degradation

proc ansiIndexOf*(role: SemanticRole; background = false;
                  mode = dmDark): uint8 =
  ## The xterm index (0..15) `role` paints its foreground (or background) with
  ## on the 16-colour rung. 255 when the role paints none there.
  let s = roleStyle(role, cdAnsi16, mode)
  let name = if background: s.bg else: s.fg
  for i, n in AnsiNames:
    if n == name:
      return uint8(i)
  255'u8
