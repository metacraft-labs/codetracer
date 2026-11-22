## The progress pie's inks and its web spelling: `agent_harbor_palette`'s
## `pieInks` on every ground a pie sits on, in both colour modes, against the
## pie's contrast floors; the web stylesheet that carries those inks, held
## equal to what the palette resolves; the pie's shape (a ring in the role's
## ink, the wedge filled inside it in the same ink, the rest the ground) and
## its geometry at native size; the wedge's stop and gradient spellings
## every front end shares; the web view's classes; and the story's data.
##
## The rules (the ink, the wedge's and the edge's, 3.3:1 on the ground, WCAG
## 2.2 SC 1.4.11's 3:1, https://www.w3.org/TR/WCAG22/#non-text-contrast,
## with a margin for the antialiased edge; two roles' inks CIEDE2000 20
## apart; warning and error 1.3:1 apart in luminance; ended a grey of chroma
## 12 or less) are measured here with this file's own WCAG contrast measure
## and the stated thresholds, not the palette's constants, so a wrong formula
## or a moved constant in the palette cannot pass its own check.
##
## No mocks: the palette, the stylesheet and the story data are the
## production ones; nothing is drawn (the wedge's pixels are counted from the
## pie's own geometry, `pieWedgeInsetPx`, by supersampling).

import std/[math, sequtils, strutils, tables, unittest]
import isonim/testing/mock_dom
import ../../views/agent_harbor_palette
import ../../views/isonim_agent_harbor_pie_view

const PieInksSheet = staticRead("../../../styles/components/agent_harbor_pie_inks.styl")
const PieSheet = staticRead("../../../styles/components/agent_harbor_pie.styl")

proc luminance(hex: string): float =
  ## WCAG 2 relative luminance (https://www.w3.org/TR/WCAG22/#dfn-relative-luminance).
  for i, weight in [0.2126, 0.7152, 0.0722]:
    let v = parseHexInt(hex[1 + 2 * i .. 2 + 2 * i]).float / 255.0
    result += weight * (if v <= 0.04045: v / 12.92 else: pow((v + 0.055) / 1.055, 2.4))

proc ratio(a, b: string): float =
  let (x, y) = (luminance(a), luminance(b))
  (max(x, y) + 0.05) / (min(x, y) + 0.05)

suite "the pie's inks hold the floors":
  test "on every ground, in both modes, for every role":
    var checked = 0
    for mode in [dmDark, dmLight]:
      let p = ahPalette(mode)
      for ground in PieGround:
        let g = p.pieGroundColour(ground)
        for role in PieRole:
          let inks = p.pieInks(role, ground)
          let at = $mode & " " & $ground & " " & $role
          checkpoint at & ": " & $inks
          check inks.ground == g
          # One ink: the wedge is the edge's full ink, never a mix of it.
          check inks.edge == inks.wedge
          check inks.wedge == p.roleInks(g)[role]
          check ratio(inks.wedge, g) >= 3.3
          check ratio(inks.edge, g) >= 3.3
          inc checked
    check checked == 2 * (ord(high(PieGround)) + 1) * (ord(high(PieRole)) + 1)

  test "a role's own ink is kept wherever it meets every rule":
    # Against the roles resolved before it (`PieRoleOrder`): 3.3:1 on the
    # ground, 20 from their inks, error 1.3:1 from warning, ended a grey. A
    # role that later gave way to the next one (`gaveWay`) is the exception,
    # checked below.
    for mode in [dmDark, dmLight]:
      let p = ahPalette(mode)
      for ground in PieGround:
        let g = p.pieGroundColour(ground)
        let report = p.roleInkReport(g)
        var earlier: seq[PieRole]
        for role in PieRoleOrder:
          let own = p.roleInk(role)
          var meets = ratio(own, g) >= 3.3
          for other in earlier:
            if deltaE2000(own, p.pieInks(other, ground).wedge) < 20.0: meets = false
          if role == prError and ratio(own, p.pieInks(prWarning, ground).wedge) < 1.3:
            meets = false
          if role == prEnded and inkChroma(own) > 12.0: meets = false
          checkpoint $mode & " " & $ground & " " & $role
          if role in report.gaveWay: check p.pieInks(role, ground).wedge != own
          elif meets: check p.pieInks(role, ground).wedge == own
          else: check p.pieInks(role, ground).wedge != own
          earlier.add role

  test "the roles keep the status marks' colours on the panel in Dark":
    let p = ahPalette(dmDark)
    check p.pieInks(prWarning, pgPanel).wedge == p.iconWarning
    check p.pieInks(prSuccess, pgPanel).wedge == p.iconSuccess
    check p.pieInks(prInfo, pgPanel).wedge == p.iconInfo
    check p.pieInks(prIdle, pgPanel).wedge == p.iconDefault
    check p.pieInks(prEnded, pgPanel).wedge == p.endedMark
    # Error but: Dark's warning and error marks are 1.12:1 apart in
    # luminance, so error is moved to 1.3:1.
    check ratio(p.iconWarning, p.iconError) < 1.3
    check p.pieInks(prError, pgPanel).wedge != p.iconError
    check ratio(p.pieInks(prError, pgPanel).wedge, p.iconWarning) >= 1.3

  test "Light's warning on the active tab is darkened to hold 3.3:1":
    let p = ahPalette(dmLight)
    check ratio(p.iconWarning, p.activeTab) < 3.3
    let inks = p.pieInks(prWarning, pgActiveTab)
    check inks.wedge != p.iconWarning
    check ratio(inks.wedge, p.activeTab) >= 3.3

  test "a mix is per sRGB channel, rounded":
    check mixInk("#000000", "#ffffff", 50) == "#808080"
    check mixInk("#102030", "#102030", 55) == "#102030"
    check mixInk("#ff0000", "#0000ff", 0) == "#ff0000"
    check mixInk("#ff0000", "#0000ff", 100) == "#0000ff"

suite "two roles are told apart on every ground":
  test "the CIEDE2000 formula reproduces Sharma's published test pairs":
    # Sharma, Wu and Dalal (2005), Table 1, pairs 1, 7 and 17.
    check abs(deltaE2000Lab([50.0, 2.6772, -79.7751], [50.0, 0.0, -82.7485]) - 2.0425) < 1e-4
    check abs(deltaE2000Lab([50.0, 0.0, 0.0], [50.0, -1.0, 2.0]) - 2.3669) < 1e-4
    check abs(deltaE2000Lab([50.0, 2.5, 0.0], [73.0, 25.0, -18.0]) - 27.1492) < 1e-4

  test "every pair, idle and ended among them: CIEDE2000 20, every ink 3.3:1":
    # No luminance alternative and no exemption: two warm hues 1.5:1 apart
    # read alike at 10-12 px, and the terminal has no shape to add. Every
    # ink rule holds on every ground at this tree (`shortOf` and `unmet` are
    # empty); were a soft one not to, its best value would be what this
    # holds.
    for mode in [dmDark, dmLight]:
      let p = ahPalette(mode)
      var worst = (Inf, "")
      for ground in PieGround:
        let g = p.pieGroundColour(ground)
        check p.roleInkReport(g).shortOf.len == 0
        check p.roleInkReport(g).unmet.len == 0
        for a in PieRole:
          check ratio(p.pieInks(a, ground).wedge, g) >= 3.3
          for b in PieRole:
            if ord(b) <= ord(a): continue
            let (x, y) = (p.pieInks(a, ground).wedge, p.pieInks(b, ground).wedge)
            let de = deltaE2000(x, y)
            checkpoint $mode & " " & $ground & " " & $a & "/" & $b & ": dE " & $de
            check de >= 20.0
            if de < worst[0]:
              worst = (de, $ground & " " & $a & "/" & $b & " dE " &
                formatFloat(de, ffDecimal, 1) & ", " & formatFloat(ratio(x, y), ffDecimal, 2) & ":1")
      echo "    ", mode, ": nearest pair ", worst[1]

  test "warning and error differ in luminance too: 1.3:1 on every ground":
    for mode in [dmDark, dmLight]:
      let p = ahPalette(mode)
      for ground in PieGround:
        checkpoint $mode & " " & $ground
        check ratio(p.pieInks(prWarning, ground).wedge, p.pieInks(prError, ground).wedge) >= 1.3

  test "ended is a neutral grey, apart from idle by lightness":
    for mode in [dmDark, dmLight]:
      let p = ahPalette(mode)
      for ground in PieGround:
        let inks = p.roleInks(p.pieGroundColour(ground))
        checkpoint $mode & " " & $ground & ": ended " & inks[prEnded]
        check inkChroma(inks[prEnded]) <= 12.0
        check deltaE2000(inks[prIdle], inks[prEnded]) >= 20.0
        # Apart by lightness: their L* differ by more than their chroma.
        check abs(inkLab(inks[prIdle])[0] - inkLab(inks[prEnded])[0]) >
          max(inkChroma(inks[prIdle]), inkChroma(inks[prEnded]))

  test "Light's idle and ended: idle gives way to ended where 3.3:1 leaves them no room":
    let p = ahPalette(dmLight)
    check deltaE2000(p.iconDefault, p.endedMark) < 20.0
    for ground in PieGround:
      let g = p.pieGroundColour(ground)
      let inks = p.roleInks(g)
      checkpoint $ground
      if ground notin [pgActiveTab, pgSelectedRow]:
        # Room for both: idle keeps its ink and ended moves.
        check p.roleInkReport(g).gaveWay.len == 0
        check inks[prIdle] == p.iconDefault
        check inks[prEnded] != p.endedMark
      else:
        # The two darkest grounds: a grey that holds 3.3:1 there is too near
        # idle's own lightness to stand 20 from it, so idle darkens and
        # ended is the lighter grey.
        check p.roleInkReport(g).gaveWay == @[prIdle]
        check inks[prIdle] != p.iconDefault
        check inkLab(inks[prEnded])[0] > inkLab(inks[prIdle])[0]

  test "Light's error gives way to its warning on the active tab":
    let p = ahPalette(dmLight)
    # The design system's own warning and error are too near (CIEDE2000
    # about 14, 1.36:1); 1.51:1 apart after the 3:1 darkening was the
    # review's "reads alike".
    check not rolesApart(p.iconWarning, p.iconError)
    for ground in [pgActiveTab, pgSelectedRow]:
      let inks = p.roleInks(p.pieGroundColour(ground))
      check deltaE2000(inks[prWarning], inks[prError]) >= 20.0
      check ratio(inks[prError], p.pieGroundColour(ground)) >= 3.3
      check ratio(inks[prWarning], inks[prError]) >= 1.3

suite "the pie's shapes":
  test "every role is a ring with its wedge inside; unknown outranks the role":
    for state in PieStoryStates:
      check pieShapeOf(pieOf(state, 0, 0)) == psUnknown
      for done in PieStoryDone:
        check pieShapeOf(pieOf(state, done, PieStoryTotal)) == psRing

  test "the web draws 0 % and unknown differently":
    let r = MockRenderer()
    for state in [saRunning, saIdle, saEnded]:
      let zero = pieIndicator[MockRenderer, MockNode](r, pieOf(state, 0, 50), pgPanel)
      let unknown = pieIndicator[MockRenderer, MockNode](r, pieOf(state, 0, 0), pgPanel)
      check zero.attributes["class"] != unknown.attributes["class"]
      check "ah-pie-unknown" in unknown.attributes["class"]
      check unknown.children.len == 1
      check unknown.children[0].attributes["class"] == "ah-pie-dot"
      check zero.children.len == 0
      check zero.attributes["aria-label"] != unknown.attributes["aria-label"]
    check "ah-pie-ring" in pieIndicator[MockRenderer, MockNode](
      r, pieOf(saEnded, 50, 50), pgPanel).attributes["class"]

  test "the web leaves the rest of every pie as the ground, inside a gap":
    # Every role at every share is a ring: the class that paints the wedge on
    # the content box (inset by the padding past the ring and the gap), and
    # the gradient's rest transparent, so a 0 % pie inside its ring is the
    # ground and nothing else. No rest ink is written for any role.
    let r = MockRenderer()
    for state in PieStoryStates:
      for done in PieStoryDone:
        let pie = pieOf(state, done, PieStoryTotal)
        let n = pieIndicator[MockRenderer, MockNode](r, pie, pgPanel)
        checkpoint $state & " " & $done
        check "ah-pie-ring" in n.attributes["class"]
        check n.children.len == 0
        check "padding: 0.125rem;" in n.attributes["style"]
    check ".ah-pie\n" in PieSheet
    let rule = PieSheet[PieSheet.find(".ah-pie\n") ..< PieSheet.find("\n\n", PieSheet.find(".ah-pie\n"))]
    check "  background: conic-gradient(var(--ah-pie-wedge) 0 var(--ah-pie-p), " &
      "transparent var(--ah-pie-p) 100%)\n" in rule & "\n"
    # After the shorthand, which would reset it to the border box.
    check rule.find("  background-clip: content-box") > rule.find("  background: ")
    check "--ah-pie-rest" notin PieInksSheet
    check "--ah-pie-rest" notin PieSheet

  test "GPUI's gradient leaves the rest as the ground":
    # The spelling GPUI paints (`pieConicGradient`): the rest stop is the
    # ground itself on every ground, in both modes.
    for mode in [dmDark, dmLight]:
      let p = ahPalette(mode)
      for ground in PieGround:
        for role in PieRole:
          let inks = p.pieInks(role, ground)
          checkpoint $mode & " " & $ground & " " & $role
          check inks.pieConicGradient(pieOf(saRunning, 0, 50)) ==
            "conic-gradient(" & inks.wedge & " 0 0%, " & p.pieGroundColour(ground) & " 0% 100%)"

  test "the web's bands carry the title of each mode":
    let r = MockRenderer()
    let story = renderAgentHarborPieStory[MockRenderer, MockNode](r, "every-state")
    var titles: seq[(string, string, string)]
    for band in story.children:
      if "ah-pie-band " notin band.attributes.getOrDefault("class") & " ": continue
      if not band.attributes.hasKey("data-ah-pie-ground"): continue
      var dark, light = ""
      for c in band.children:
        let cls = c.attributes.getOrDefault("class")
        if "ah-pie-title-dark" in cls: dark = c.children[0].text
        if "ah-pie-title-light" in cls: light = c.children[0].text
      titles.add (band.attributes["data-ah-pie-ground"], dark, light)
    check titles.len == 5
    check ("active-tab", "Active tab / Selected row", "Active tab") in titles
    check ("selected-row", "Active tab / Selected row", "Selected row") in titles
    # The selected row's band is shown in Light only; Dark's active-tab band
    # stands for it.
    check ".ah-pie-band-selected-row\n  background: by-mode(#3c3c3c, #c8c2b5)\n" in PieInksSheet
    check "display: by-mode(none, block)" in PieInksSheet

  test "the unknown dot is well short of the wedge's disc":
    # At native size (12 px): the dot a quarter (3 px), the wedge's disc
    # 8 px, so a whole pie and an unknown one never read alike.
    let dot = 12.0 * PieDotFraction
    let inner = float(12 - 2 * pieWedgeInsetPx(12))
    check dot <= 3.0
    check inner >= 8.0
    check dot * 2.0 < inner

  test "the ring, the gap and the wedge's disc on whole pixels":
    # 1 px of ring; 1 px of ground from 12 px up, none under it.
    check PieEdgePx == 1
    check [pieRingGapPx(9), pieRingGapPx(10), pieRingGapPx(11)] == [0, 0, 0]
    check [pieRingGapPx(12), pieRingGapPx(16), pieRingGapPx(24)] == [1, 1, 2]
    check pieWedgeInsetPx(12) == 2
    check pieWedgeInsetPx(10) == 1

  test "a 16 % wedge reads at native size: at least 6 whole pixels of ink":
    # The wedge's own geometry, sampled 16 x 16 per pixel: a pixel counts
    # when the wedge covers 90 % of it (the capture test's full-ink pixel).
    # At the pie's native sizes (10 px in tabs and menus, 12 px on lines,
    # 16 px on the caption) a 16 % share is at least `WedgePixels` such pixels; with the
    # 1 px gap kept at 10 px it would be 3.
    const WedgePixels = 6
    proc wholePixels(sizePx: int; share: float): int =
      let c = sizePx.float / 2.0
      let radius = c - pieWedgeInsetPx(sizePx).float
      for py in 0 ..< sizePx:
        for px in 0 ..< sizePx:
          var inside = 0
          for sy in 0 ..< 16:
            for sx in 0 ..< 16:
              let x = px.float + (sx.float + 0.5) / 16.0 - c
              let y = py.float + (sy.float + 0.5) / 16.0 - c
              if x * x + y * y > radius * radius: continue
              var a = arctan2(x, -y)          # clockwise from twelve o'clock
              if a < 0: a += 2.0 * PI
              if a < share * 2.0 * PI: inc inside
          if inside.float / 256.0 >= 0.9: inc result
    for size in [10, 12, 16]:
      let n = wholePixels(size, 0.16)
      echo "    ", size, " px: a 16 % wedge covers ", n, " whole pixels"
      check n >= WedgePixels
    check wholePixels(12, 0.0) == 0

suite "the story's words are readable":
  test "4.5:1 on every ground, in both modes":
    for mode in [dmDark, dmLight]:
      let p = ahPalette(mode)
      for ground in PieGround:
        let g = p.pieGroundColour(ground)
        checkpoint $mode & " " & $ground
        check ratio(p.readableInk(g), g) >= 4.5
      check ratio(p.readableInk(p.ground), p.ground) >= 4.5

suite "the web carries the palette's inks":
  test "the committed stylesheet is what the palette writes":
    # `nim r tools/stories/emit_pie_inks.nim` rewrites it.
    check PieInksSheet == pieStylesheet()

  test "every ground and role has its rule, and every ground its band":
    let p = ahPalette(dmDark)
    let l = ahPalette(dmLight)
    for ground in PieGround:
      check ("\n.ah-pie-band-" & $ground & "\n") in PieInksSheet
      for role in PieRole:
        let rule = "\n.ah-pie-on-" & $ground & ".ah-pie-" & $role & "\n" &
          "  --ah-pie-wedge: by-mode(" & p.pieInks(role, ground).wedge & ", " &
          l.pieInks(role, ground).wedge & ")\n"
        check rule in PieInksSheet

suite "the wedge's spelling":
  test "the stop: the share as a percentage, 0 with no known progress":
    check pieOf(saRunning, 8, 50).pieStopPercent == "16%"
    check pieOf(saRunning, 1, 8).pieStopPercent == "12.5%"
    check pieOf(saRunning, 50, 50).pieStopPercent == "100%"
    check pieOf(saRunning, 0, 50).pieStopPercent == "0%"
    check pieOf(saRunning, 0, 0).pieStopPercent == "0%"
    check pieOf(saRunning, 1, 3).pieStopPercent == "33.333%"

  test "the gradient: two hard stops at the share, from the top":
    let p = ahPalette(dmDark)
    let inks = p.pieInks(prSuccess, pgPanel)
    check inks.pieConicGradient(pieOf(saRunning, 8, 50)) ==
      "conic-gradient(" & inks.wedge & " 0 16%, " & inks.ground & " 16% 100%)"

  test "the web view names the role, the ground and an unknown share":
    let known = pieOf(saNeedsInput, 8, 50)
    check pieClass(known, pgMenu) == "ah-pie ah-pie-warning ah-pie-on-menu ah-pie-ring"
    check pieClass(pieOf(saIdle, 0, 0), pgPanel) ==
      "ah-pie ah-pie-idle ah-pie-on-panel ah-pie-unknown"
    check pieClass(pieOf(saIdle, 1, 2), pgPanel) ==
      "ah-pie ah-pie-idle ah-pie-on-panel ah-pie-ring"
    check pieStyle(known, 12) ==
      "width: 0.75rem; height: 0.75rem; padding: 0.125rem; --ah-pie-p: 16%;"
    check pieStyle(known, 10) ==
      "width: 0.625rem; height: 0.625rem; padding: 0.0625rem; --ah-pie-p: 16%;"

suite "the story's data":
  test "each distinct ground once per theme, named by every ground it is":
    let dark = pieStoryBands("every-state", dmDark)
    check dark.mapIt(it.ground) == @[pgWindow, pgPanel, pgActiveTab, pgMenu]
    check dark[2].grounds == @[pgActiveTab, pgSelectedRow]
    check dark[2].bandTitle == "Active tab / Selected row"
    let light = pieStoryBands("every-state", dmLight)
    check light.len == ord(high(PieGround)) + 1
    check light[3].bandTitle == "Selected row"
    for mode in [dmDark, dmLight]:
      var colours: seq[string]
      for band in pieStoryBands("every-state", mode):
        colours.add ahPalette(mode).pieGroundColour(band.ground)
      check colours.deduplicate.len == colours.len
    check not bandShown(pgSelectedRow, dmDark)
    check bandShown(pgSelectedRow, dmLight)

  test "the rows name the operator's words for each role":
    check pieStoryRows().mapIt(it.word) == @["needs input", "running/working", "queued",
                                            "failed/blocked", "idle", "ended/done"]

  test "every role at each share and unknown, on every ground":
    let bands = pieStoryBands("every-state", dmLight)
    check bands.len == ord(high(PieGround)) + 1
    for i, band in bands:
      check band.ground == PieGround(i)
      var roles: seq[PieRole]
      for row in band.rows:
        roles.add row.role
        check row.pies.len == PieStoryColumns.len
        for k, share in [0, 16, 50, 84, 100]:
          check row.pies[k].known
          check row.pies[k].percent == share
          check row.pies[k].role == row.role
        check not row.pies[^1].known
        check row.pies[^1].label ==
          attentionWord(PieStoryStates[roles.len - 1]) & ", progress unknown"
      for role in PieRole: check role in roles

  test "the web's grid is the one GPUI and the terminal draw":
    # The stylesheet states the story's columns in rem (px / 16); a width
    # changed on one side only moves every pie (the `pie-first` region).
    proc rem(px: int): string =
      result = formatFloat(px.float / 16.0, ffDecimal, 4)
      result.trimZeros()
      if result.endsWith("."): result.setLen(result.len - 1)
      result.add "rem"
    check (".ah-pie-label\n  width: " & rem(PieStoryLabelPx) & "\n") in PieSheet
    for i, w in PieStoryColumnsPx:
      check (".ah-pie-col-" & $i & "\n  width: " & rem(w) & "\n") in PieSheet
    check "  justify-content: center\n" in PieSheet
    check ("  padding: " & rem(PieStoryInsetPx) & "\n") in PieSheet
    # It fits the brief's 360 px sidebar inside the two 8 px insets.
    var columns = 0
    for w in PieStoryColumnsPx: columns += w
    check PieStoryLabelPx + columns <= 360 - 4 * PieStoryInsetPx

  test "the web centres each head over its column's pies":
    let r = MockRenderer()
    let story = renderAgentHarborPieStory[MockRenderer, MockNode](r, "every-state")
    let head = story.children[0]
    check "ah-pie-head" in head.attributes["class"]
    check head.children.len == 1 + PieStoryColumns.len
    for i, name in PieStoryColumns:
      let c = head.children[1 + i]
      check c.attributes["class"] == pieColumnClass(i)
      check c.children.len == 1
      check c.children[0].attributes["data-ah-pie-head-word"] == name
    # And each pie sits in the same column class, so both are centred on
    # one line.
    let firstRow = story.children[1].children[2]
    for i in 0 ..< PieStoryColumns.len:
      check firstRow.children[1 + i].attributes["class"] == pieColumnClass(i)

  test "an unknown fixture is refused":
    expect ValueError:
      discard pieStoryBands("no-such-fixture", dmDark)
