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
##   front end (`initiativeSessionWordColour`), not resolved per ground;
## * a status mark and a milestone bar's status segment (graphical objects)
##   hold 3:1 (SC 1.4.11) on the cell's own ground; a neutral mark (idle,
##   ended, planned, other) has no status role and is not held here;
## * a failed `+N` draws its mark and count in one ink, the recordings'
##   `+N` failure ink, so one bar draws one red;
## * the palette's rule itself: Dark keeps the roles, Light takes the
##   readable steps pinned below, and the roles they replace are under the
##   floors (the controls: each check here fails on the old inks).
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
  ink in [p.iconDefault, p.endedMark, p.trackPlanned, p.iconSubtle]

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
    var seen, words = 0
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
              let fg = m.canvas.grid.styleAt(word.row, word.col).fg
              if attention in {saNeedsInput, saRunning, saFailed}: inc words
              if fg != m.canvas.p.initiativeSessionWordColour(attention):
                problems.add where & "session status '" & word.attr("status") & "' is " & fg &
                             ", not the panel's " & m.canvas.p.initiativeSessionWordColour(attention)
          m.dispose()
    check seen == 8
    # Each popup draws running and waiting sessions (three of them).
    check words >= 8 * 3
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
    # toward the body (5.84:1; about red/800 #991b1b, which the Nim table
    # lacks).
    check l.statusTextInk(prError, l.menu) == "#951e1e"
    # An Initiatives session's status word, one ink per state on every
    # ground. Dark keeps each role; Light takes this rule on the darkest
    # ground it is drawn on, the popup's over a panel (#c8c2b5).
    check d.initiativeSessionWordColour(saNeedsInput) == d.textWarning
    check d.initiativeSessionWordColour(saRunning) == d.textSuccess
    check d.initiativeSessionWordColour(saFailed) == d.textError
    check l.initiativeSessionWordColour(saNeedsInput) == "#753317"   # about orange/900
    check l.initiativeSessionWordColour(saRunning) == "#1e5330"      # about green/900
    check l.initiativeSessionWordColour(saFailed) == "#951e1e"       # about red/800
    for att in [saNeedsInput, saRunning, saFailed]:
      for ground in [l.panel, l.menu, l.ground, l.hover]:
        check contrastOf(l.initiativeSessionWordColour(att), ground) >= TextFloor
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
