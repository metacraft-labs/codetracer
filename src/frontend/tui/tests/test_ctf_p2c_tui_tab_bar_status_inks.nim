## CTF-P2c: the status inks of the terminal's tab bars
## on the grounds they are drawn on. Terminal review of the initiative tab
## bar, 2026-11-26 (Light): the open `+N` chip's warning dot was 1.61:1 on
## its #b5ae9f, the error banner 3.34:1 on its card, the overflow menu's
## and the initiative popup's status dots and words 2.0-2.5:1 on #dbd6cc
## and #c8c2b5, and the `+N` chip's failure count 4.47:1 on the bar, in a
## second red beside the recordings' `+N`.
##
## Each is now resolved for its ground by the palette's one rule
## (`agent_harbor_palette.statusTextInk`, `markOn`), and this suite reads
## every one back off the real view's canvas, in both themes, at the
## laptop and sidebar sizes:
##
## * a status word or count (the popup's state word and its sessions'
##   status words, a failed `+N`'s count, the error notice) holds 4.5:1
##   (WCAG 2.2 SC 1.4.3) on the cell's own ground; the popup's session
##   status words are the Initiatives panel's one rule for them in every
##   front end (`initiativeSessionWordColour`) for the ground under them:
##   in Light the role's 800 step where it holds, a darker ink where not;
## * a status mark and a milestone bar's status segment (graphical objects)
##   hold 3:1 (SC 1.4.11) on the cell's own ground; a neutral mark (idle,
##   ended, planned, other) has no status role and is not held here;
## * a failed `+N` draws its mark and count in one ink, the recordings'
##   `+N` failure ink, so one bar draws one red;
## * the palette's rule itself: Dark keeps the roles, Light takes the
##   readable steps pinned below, and the roles they replace are under the
##   floors (the controls: each check here fails on the old inks);
## * the popup's `needs input` header word is the session lines' ink on its
##   ground (`initiativeSessionWordColour`; round 3, 2026-11-26);
## * and one layout rule of the same bars: a cut session tab's label keeps
##   exactly `StatusWordGap` cells before its origin (round 3).
##
## No stand-ins: the stories' own viewmodels drawn by the real views onto
## the real canvas (`mountAgentHarborStoryTui`).

import std/[strutils, unittest]

import ../agent_harbor/ah_tui_stories
import ../agent_harbor/ah_tui_initiative_tab_bar

const
  Sizes = [("laptop", 180, 56), ("sidebar", 45, 56)]
  TextFloor = 4.5
  MarkFloor = 3.0

proc mount(surface, fixture: string; cols, rows: int; mode: DesignMode): AhTuiMount =
  mountAgentHarborStoryTui(surface, fixture, cols, rows, mode)

proc neutral(p: AhPalette; ink: string): bool =
  ## A mark with no status role: idle's ring, ended's grey, a milestone
  ## planned or other.
  ink in [p.iconDefault, p.endedMark, p.trackPlanned, p.plannedMark, p.iconSubtle]

proc inkProblems(m: AhTuiMount; n: AhNode; floor: float; what: string): seq[string] =
  ## Every drawn cell of `n` whose ink is under `floor` on its own ground.
  if n.isNil: return
  for r in n.row ..< min(n.row + max(1, n.height), m.rows):
    for col in n.col ..< min(n.col + max(1, n.width), m.cols):
      if m.canvas.grid.runeAt(r, col).strip.len == 0: continue
      let st = m.canvas.grid.styleAt(r, col)
      let ratio = contrastOf(st.fg, st.bg)
      if ratio < floor:
        result.add what & " '" & m.canvas.grid.runeAt(r, col) & "' " & st.fg & " on " &
                   st.bg & " at (" & $r & "," & $col & "): " & formatFloat(ratio, ffDecimal, 2)

proc markProblems(m: AhTuiMount; parent: AhNode; what: string): seq[string] =
  ## Every status mark under `parent` against `MarkFloor`.
  if parent.isNil: return
  for mk in parent.all("mark"):
    let st = m.canvas.grid.styleAt(mk.row, mk.col)
    if neutral(m.canvas.p, st.fg): continue
    result.add m.inkProblems(mk, MarkFloor, what & " mark")

proc segmentProblems(m: AhTuiMount; parent: AhNode; what: string): seq[string] =
  ## A milestone bar's status segments against `MarkFloor` (planned and
  ## other are neutral).
  if parent.isNil: return
  for seg in parent.all("segment"):
    let status = seg.attr("segment").split(':')[0]
    if status in ["planned", "other"]: continue
    result.add m.inkProblems(seg, MarkFloor, what & " segment " & status)

suite "CTF-P2c: the tab bars' status inks on their grounds":
  test "the initiative popup's marks, segments, state word and status words":
    var problems: seq[string]
    var seen, words, on800, darker = 0
    for fixture in ["popup", "popup-over-panel"]:
      for (size, cols, rows) in Sizes:
        for mode in [dmDark, dmLight]:
          let m = mount("agent-harbor-initiative-tabs", fixture, cols, rows, mode)
          let where = fixture & " " & size & " " & $mode & ": "
          for popup in m.view.all("popup"):
            inc seen
            problems.add m.markProblems(popup, where & "popup")
            problems.add m.segmentProblems(popup, where & "popup")
            problems.add m.inkProblems(popup.first("state"), TextFloor, where & "state word")
            for s in popup.all("status"):
              problems.add m.inkProblems(s, TextFloor, where & "session status")
            for line in popup.all("session"):
              let word = line.first("status")
              if word.isNil or word.row >= m.rows: continue
              let attention = parseEnum[SessionAttention](line.attr("attention"))
              let st = m.canvas.grid.styleAt(word.row, word.col)
              let p = m.canvas.p
              if attention in {saNeedsInput, saRunning, saFailed}: inc words
              let wanted = p.initiativeSessionWordColour(attention, st.bg)
              if st.fg != wanted:
                problems.add where & "session status '" & word.attr("status") & "' is " & st.fg &
                             " on " & st.bg & ", not the panel's " & wanted
              # In Light, the role's 800 step wherever it holds 4.5:1 on the
              # ground, and a darker ink only where it does not.
              if mode == dmLight and attention in {saNeedsInput, saRunning, saFailed}:
                let step = p.statusStep800(pieRoleOf(attention))
                if contrastOf(step, st.bg) >= TextFloor:
                  inc on800
                  if st.fg != step:
                    problems.add where & "session status '" & word.attr("status") & "' is " &
                                 st.fg & " on " & st.bg & ", not the 800 step " & step
                else:
                  inc darker
                  if inkLuminance(st.fg) >= inkLuminance(step):
                    problems.add where & "session status '" & word.attr("status") & "' " &
                                 st.fg & " on " & st.bg & " is not darker than " & step
          m.dispose()
    check seen == 8
    # Each popup draws running and waiting sessions (three of them).
    check words >= 8 * 3
    # Light's popup draws its words on the card (the 800 steps hold) and,
    # over a panel, on #c8c2b5 (orange and green/800 do not).
    check on800 > 0
    check darker > 0
    if problems.len > 0: echo problems.join("\n")
    check problems.len == 0

  test "the popup's needs-input header word is the session lines' ink on its ground":
    # Terminal review round 3 (2026-11-26): the header drew `needs input`
    # by the tab bar's rule (#9b3a12, #753317 over a panel) above session
    # lines in the Initiatives rule (now #92400e, #78350f): one word, two inks
    # on one ground.
    var problems: seq[string]
    var headers, lines = 0
    for fixture in ["popup", "popup-over-panel"]:
      for (size, cols, rows) in Sizes:
        for mode in [dmDark, dmLight]:
          let m = mount("agent-harbor-initiative-tabs", fixture, cols, rows, mode)
          let p = m.canvas.p
          let where = fixture & " " & size & " " & $mode & ": "
          for popup in m.view.all("popup"):
            let state = popup.first("state")
            if state.isNil or state.attr("state") != "needs input": continue
            inc headers
            let st = m.canvas.grid.styleAt(state.row, state.col)
            let wanted = p.initiativeSessionWordColour(saNeedsInput, st.bg)
            if st.fg != wanted:
              problems.add where & "header 'needs input' " & st.fg & " on " & st.bg &
                           ", not the session lines' " & wanted
            for line in popup.all("session"):
              let word = line.first("status")
              if word.isNil or word.row >= m.rows or line.attr("attention") != "needs-input": continue
              let ws = m.canvas.grid.styleAt(word.row, word.col)
              if ws.bg != st.bg: continue
              inc lines
              if ws.fg != st.fg:
                problems.add where & "header " & st.fg & " and session line " & ws.fg &
                             " on " & st.bg
          m.dispose()
    check headers == 8
    check lines >= 8
    if problems.len > 0: echo problems.join("\n")
    check problems.len == 0

  test "the menus' marks: overflow and sessions elsewhere":
    var problems: seq[string]
    var menus = 0
    for (surface, fixture) in [("agent-harbor-initiative-tabs", "overflow-menu-over-panel"),
                               ("agent-harbor-initiative-tabs", "overflow-menu-near-left"),
                               ("agent-harbor-initiative-tabs", "elsewhere"),
                               ("agent-harbor-initiative-tabs", "elsewhere-over-panel"),
                               ("agent-harbor-session-tabs", "menu-over-panel")]:
      for (size, cols, rows) in Sizes:
        for mode in [dmDark, dmLight]:
          let m = mount(surface, fixture, cols, rows, mode)
          for menu in m.view.all("menu"):
            inc menus
            problems.add m.markProblems(menu, fixture & " " & size & " " & $mode & ": menu " &
                                        menu.attr("menu"))
          m.dispose()
    check menus >= 16
    if problems.len > 0: echo problems.join("\n")
    check problems.len == 0

  test "the +N chip: its mark at rest and open, its failure count in the bar's one red":
    var problems: seq[string]
    var chips, failed, atRest = 0
    for (surface, fixture) in [("agent-harbor-initiative-tabs", "overflow-menu-over-panel"),
                               ("agent-harbor-initiative-tabs", "overflow-menu-near-left"),
                               ("agent-harbor-initiative-tabs", "long-names"),
                               ("agent-harbor-initiative-tabs", "overflow-40"),
                               ("agent-harbor-session-tabs", "menu-over-panel"),
                               ("agent-harbor-session-tabs", "single-line-40")]:
      for (size, cols, rows) in Sizes:
        for mode in [dmDark, dmLight]:
          let m = mount(surface, fixture, cols, rows, mode)
          let where = fixture & " " & size & " " & $mode & ": "
          for chip in m.view.all("overflow"):
            inc chips
            problems.add m.markProblems(chip, where & "+N")
            if chip.attr("overflow-severity") == "failed":
              inc failed
              problems.add m.inkProblems(chip, TextFloor, where & "failed +N")
              # One ink for the mark and the count: at rest, on the bar,
              # the recordings' `+N` failure ink, so one bar draws one red;
              # open, on the chip's own ground, the same rule's step there.
              var inks: seq[string]
              for col in chip.col ..< chip.col + chip.width:
                if m.canvas.grid.runeAt(chip.row, col).strip.len == 0: continue
                let fg = m.canvas.grid.styleAt(chip.row, col).fg
                if fg notin inks: inks.add fg
              let ground = m.canvas.bgAt(chip.row, chip.col)
              let wanted = if ground == m.canvas.tone.frame: buttonStateInk(m.canvas.p, rsFailed)
                           else: m.canvas.p.statusTextInk(prError, ground)
              if ground == m.canvas.tone.frame: inc atRest
              if inks != @[wanted]:
                problems.add where & "failed +N on " & ground & " draws " & inks.join(", ") &
                             ", not " & wanted
          m.dispose()
    check chips >= 16
    check failed >= 2
    check atRest >= 1
    if problems.len > 0: echo problems.join("\n")
    check problems.len == 0

  test "the error notice's text":
    var problems: seq[string]
    var notices = 0
    for surface in ["agent-harbor-initiative-tabs", "agent-harbor-session-tabs"]:
      for (size, cols, rows) in Sizes:
        for mode in [dmDark, dmLight]:
          let m = mount(surface, "error", cols, rows, mode)
          for n in m.view.all("notice"):
            if n.attr("notice") != "error": continue
            inc notices
            problems.add m.inkProblems(n.first("error"), TextFloor,
                                       surface & " " & size & " " & $mode & ": error notice")
          m.dispose()
    check notices == 8
    if problems.len > 0: echo problems.join("\n")
    check problems.len == 0

suite "CTF-P2c: the palette's status inks on a ground":
  test "Dark keeps the roles; Light takes the readable steps":
    let d = ahPalette(dmDark)
    for ground in [d.ground, d.panel, d.menu, d.hover, d.activeTab]:
      check d.statusTextInk(prError, ground) == d.textError
      check d.statusTextInk(prWarning, ground) == d.textWarning
      check d.statusTextInk(prSuccess, ground) == d.textSuccess
      for att in [saNeedsInput, saRunning, saFailed, saQueued]:
        check d.markOn(d.markOf(att), ground) == d.markOf(att)
    let l = ahPalette(dmLight)
    # The recording buttons' failed and missing inks are this rule on the panel.
    check l.statusTextInk(prError, l.panel) == "#b91c1c"      # red/700
    check l.statusTextInk(prWarning, l.panel) == "#9b3a12"    # about orange/800
    # The error banner on the card: red/700 is 4.47:1 there, so a quarter
    # toward the body (5.84:1; about red/800 #991b1b, which this rule does
    # not name).
    check l.statusTextInk(prError, l.menu) == "#951e1e"
    # A session's status word on a ground. Dark keeps each role on every
    # ground. Light takes the role's 800 step, the design system's
    # `colors-<role>-800` primitive, wherever it holds 4.5:1: on the default
    # surface (#f8f6f2), the panel (#e6e2db) and the card (#dbd6cc).
    for ground in [d.ground, d.panel, d.menu, d.hover]:
      check d.initiativeSessionWordColour(saNeedsInput, ground) == d.textWarning
      check d.initiativeSessionWordColour(saRunning, ground) == d.textSuccess
      check d.initiativeSessionWordColour(saFailed, ground) == d.textError
    # Needs input starts from amber/800, not orange/800 (#9a3412), which is
    # only 7.8 CIEDE2000 from failed's red/800.
    check l.statusStep800(prWarning) == "#92400e"   # amber/800
    check deltaE2000(l.statusStep800(prWarning), l.statusStep800(prError)) >= 12.0
    check l.statusStep800(prSuccess) == "#166534"   # green/800
    check l.statusStep800(prError) == "#991b1b"     # red/800
    for att in [saNeedsInput, saRunning, saFailed]:
      for ground in [l.ground, l.panel, l.menu]:
        check l.initiativeSessionWordColour(att, ground) == l.statusStep800(pieRoleOf(att))
    # On #c8c2b5 amber and green/800 fall under it (4.00 and 4.02:1): needs
    # input takes amber/900 there, running is taken a quarter toward the
    # body text; red/800 holds.
    check contrastOf(l.statusStep800(prWarning), l.hover) < TextFloor
    check contrastOf(l.statusStep800(prSuccess), l.hover) < TextFloor
    check contrastOf(l.statusStep800(prError), l.hover) >= TextFloor
    check l.initiativeSessionWordColour(saNeedsInput, l.hover) == "#78350f"   # amber/900
    check l.initiativeSessionWordColour(saRunning, l.hover) == "#1a5530"
    check l.initiativeSessionWordColour(saFailed, l.hover) == "#991b1b"
    check l.initiativeSessionWordColour(saNeedsInput, l.hover) ==
      DesignPrimitiveHex[dpColorsAmber900][dmLight]
    # Needs input on every Light ground: amber/800 where it holds 4.5:1,
    # amber/900 where it does not, and the darkest for an unknown ground.
    for (ground, ink, ratio) in [
        (l.ground, "#92400e", 6.57),                                          # stripe
        (DesignTokenHex[dtColorsUiSurfaceBaseRaised][dmLight], "#92400e", 6.39),  # raised
        (l.panel, "#92400e", 5.49),
        (l.menu, "#92400e", 4.90),                                            # card
        (DesignTokenHex[dtColorsUiSurfaceBaseCanvas][dmLight], "#78350f", 5.68),  # canvas
        (l.hover, "#78350f", 5.11),
        ("", "#78350f", 5.11)]:
      let got = l.initiativeSessionWordColour(saNeedsInput, ground)
      check got == ink
      check abs(contrastOf(got, if ground.len > 0: ground else: l.hover) - ratio) < 0.01
    check DesignTokenHex[dtColorsUiSurfaceBaseRaised][dmLight] == "#f3f3f3"
    check DesignTokenHex[dtColorsUiSurfaceBaseCanvas][dmLight] == "#d2ccc1"
    # A cell with no ground is taken as the darkest one.
    check l.initiativeSessionWordColour(saRunning, "") == "#1a5530"
    for att in [saNeedsInput, saRunning, saFailed]:
      for ground in [l.panel, l.menu, l.ground, l.hover]:
        check contrastOf(l.initiativeSessionWordColour(att, ground), ground) >= TextFloor
    # Every other state is in the label role, on every ground.
    for att in [saIdle, saQueued, saEnded]:
      for ground in [l.panel, l.hover]:
        check l.initiativeSessionWordColour(att, ground) == l.textLabel
        check d.initiativeSessionWordColour(att, ground) == d.textLabel
    # The `+N` chip's failure on the bar: red/700, the recordings' red.
    check l.statusTextInk(prError, l.ground) == "#b91c1c"
    # The open chip's warning dot: the pie's warning ink on that fill.
    check l.markOn(l.markOf(saNeedsInput), l.tertiary).colour ==
      l.pieInks(prWarning, l.tertiary).wedge
    for ground in [l.ground, l.panel, l.menu, l.hover, l.tertiary]:
      for role in [prWarning, prSuccess, prInfo, prError]:
        check contrastOf(l.statusTextInk(role, ground), ground) >= TextFloor
      for att in [saNeedsInput, saRunning, saFailed, saQueued]:
        check contrastOf(l.markOn(l.markOf(att), ground).colour, ground) >= MarkFloor

  test "the controls: Light's own roles are under the floors there":
    let l = ahPalette(dmLight)
    check contrastOf(l.iconWarning, l.tertiary) < MarkFloor      # 1.61
    check contrastOf(l.textError, l.menu) < TextFloor            # 3.34
    check contrastOf(l.textSuccess, l.menu) < TextFloor          # 2.28
    check contrastOf(l.iconSuccess, l.hover) < MarkFloor         # 1.86
    check contrastOf(l.textError, l.ground) < TextFloor          # 4.47
    check contrastOf(tokenHexOf(dtColorsUiTextErrorPrimaryHover, dmLight), l.menu) < TextFloor
    # A mark with no status role is left as it is.
    let planned = l.markOf(mscPlanned)
    check l.markOn(planned, l.tertiary) == planned

suite "CTF-P2c: a cut session tab's gap before its origin":
  test "a cut label keeps exactly StatusWordGap cells before the origin":
    # Terminal review round 3 (2026-11-26): where the cut fell after a
    # space, the space went with it (no space before the "…") and the origin
    # stood three cells off (`Persist the…   TUI`); now always two.
    var problems: seq[string]
    var cut, afterSpace = 0
    for fixture in ["multi-line", "multi-line-40", "focused-initiative", "single-line",
                    "single-line-40", "long-names"]:
      for (size, cols, rows) in Sizes:
        for mode in [dmDark, dmLight]:
          let m = mount("agent-harbor-session-tabs", fixture, cols, rows, mode)
          for tab in m.view.all("tab"):
            let label = tab.first("label")
            let origin = tab.first("origin")
            if label.isNil or origin.isNil or label.row >= m.rows: continue
            let full = label.attr("label")
            if widthOf(full) <= label.width: continue   # whole: the layout's own gap
            inc cut
            let cells = label.width
            if cells < widthOf(full) and cellSlice(full, cells - 1, cells) == " ":
              inc afterSpace
            let gap = origin.col - (label.col + label.width)
            if gap != StatusWordGap:
              problems.add fixture & " " & size & " " & $mode & ": '" & full & "' cut to " &
                           $label.width & " cells, " & $gap & " before its origin"
          m.dispose()
    check cut > 0
    check afterSpace > 0   # a cut that fell after a space is among them
    if problems.len > 0: echo problems.join("\n")
    check problems.len == 0
