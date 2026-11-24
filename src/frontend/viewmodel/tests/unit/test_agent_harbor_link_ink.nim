## The `link` role's ink and its web spelling: `agent_harbor_palette`'s
## `linkInk` on every ground a link sits on, in both colour modes, against
## the rules the palette's roles keep, and the web stylesheet that carries
## those inks, held equal to what the palette resolves.
##
## The rules: the ink holds 3.3:1 on its ground (WCAG 2.2 SC 1.4.11's 3:1
## for a graphical object, https://www.w3.org/TR/WCAG22/#non-text-contrast,
## with the pie's margin), and it stands CIEDE2000 20 or more from every
## pie role's ink on that ground and from the body text, so a link never
## reads as a status mark or as the prose it sits in. The contrast is
## measured with this file's own WCAG formula and the stated thresholds,
## not the palette's constants, so a wrong formula or a moved constant in
## the palette cannot pass its own check; the colour difference uses the
## palette's CIEDE2000, which `test_agent_harbor_pie` checks against the
## published test pairs.
##
## No mocks: the palette and the stylesheet are the production ones.

import std/[math, strutils, unittest]
import ../../views/agent_harbor_palette

const LinkInksSheet = staticRead("../../../styles/components/agent_harbor_link_inks.styl")

proc luminance(hex: string): float =
  ## WCAG 2 relative luminance (https://www.w3.org/TR/WCAG22/#dfn-relative-luminance).
  for i, weight in [0.2126, 0.7152, 0.0722]:
    let v = parseHexInt(hex[1 + 2 * i .. 2 + 2 * i]).float / 255.0
    result += weight * (if v <= 0.04045: v / 12.92 else: pow((v + 0.055) / 1.055, 2.4))

proc ratio(a, b: string): float =
  let (x, y) = (luminance(a), luminance(b))
  (max(x, y) + 0.05) / (min(x, y) + 0.05)

suite "the link ink holds the palette's rules":
  test "on every ground, in both modes":
    var checked = 0
    for mode in [dmDark, dmLight]:
      let p = ahPalette(mode)
      for ground in PieGround:
        let g = p.pieGroundColour(ground)
        let ink = p.linkInk(ground)
        let at = $mode & " " & $ground & ": " & ink & " on " & g
        checkpoint at
        check ink.len == 7 and ink[0] == '#'
        check ratio(ink, g) >= 3.3
        let roles = p.roleInks(g)
        for role in PieRole:
          checkpoint at & " against " & $role & " " & roles[role]
          check deltaE2000(ink, roles[role]) >= 20.0
        check deltaE2000(ink, p.textBody) >= 20.0
        check p.linkInkReport(g).shortOf == ""
        inc checked
    check checked == 2 * (ord(high(PieGround)) + 1)

  test "the role's own ink is kept exactly where it meets both rules":
    # Both directions on every ground: kept where it meets them, moved
    # where it does not. (Today the role's own ink is the pie's info ink, so
    # it is moved on every ground; asserting only the "kept" direction
    # would check nothing.)
    var grounds = 0
    for mode in [dmDark, dmLight]:
      let p = ahPalette(mode)
      for ground in PieGround:
        let g = p.pieGroundColour(ground)
        let base = p.textInfo
        var meets = ratio(base, g) >= 3.3 and deltaE2000(base, p.textBody) >= 20.0
        for role in PieRole:
          if deltaE2000(base, p.roleInks(g)[role]) < 20.0: meets = false
        checkpoint $mode & " " & $ground & ": base " & base & ", meets " & $meets
        check (p.linkInk(ground) == base) == meets
        inc grounds
    check grounds == 2 * (ord(high(PieGround)) + 1)

  test "a link differs from the body text on every ground":
    # Not by hue alone: the terminal's fallback relies on the ink and an
    # underline, so the ink must also be told from the body text by eye.
    for mode in [dmDark, dmLight]:
      let p = ahPalette(mode)
      for ground in PieGround:
        check p.linkInk(ground) != p.textBody

suite "the web carries the palette's link inks":
  test "the stylesheet is linkStylesheet's text":
    check LinkInksSheet == linkStylesheet()

  test "one custom property per ground, both modes":
    for ground in PieGround:
      let name = "--ah-link-ink-" & $ground & ": by-mode("
      check LinkInksSheet.count(name) == 1
      let dark = ahPalette(dmDark).linkInk(ground)
      let light = ahPalette(dmLight).linkInk(ground)
      check (name & dark & ", " & light & ")") in LinkInksSheet
