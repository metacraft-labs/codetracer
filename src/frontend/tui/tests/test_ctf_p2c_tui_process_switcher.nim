## CTF-P2c step 5: the terminal's multi-process recording session tab with
## its process switcher (study §2.6, D25, D76-D83), in the story host that
## mounts it (`tui/agent_harbor/ah_tui_stories.nim`).
##
## * **The caption bar's tabs**: the recording's tab, active (the active
##   tab's ground, its name in the active tab's ink), then the plain tab in
##   the caption role, on the bar's ground; the working area below.
## * **The tab's facts** are the viewmodel's: the process count, the active
##   and the ringed process, the tooltip naming the bound keys.
## * **The buttons are the recording switcher's own drawing** (the
##   initiative bar's `drawRecordingButton` and `drawRecordingsMore`), at
##   the window's slots (five, two below 90 cells): the active one, a failed
##   worker behind `+N`, the ringed process's number underlined in the
##   ring step (D81), the ring on `+N` when it hides that process; every
##   state's text 4.5:1 or more on the buttons' ground; a click on a
##   button is routed and selects its process. The tab hands any slot the
##   viewmodel's buttons and the press route, and makes room for it before
##   cutting the name.
## * **Keys are routed**: `CSI 6;7~` / `CSI 5;7~` (`Ctrl+Alt+PageDown` /
##   `PageUp`, as a terminal sends them) step the processes; a digit picks
##   one, and picking the ringed process clears the ring.
## * **The status line's hint** (a terminal draws no tooltip):
##   while the switcher has the focus, the window's last row shows the
##   focused (active) button's tooltip, readable on the line's ground, cut
##   with `…` where the line cannot hold it; without the focus the line is
##   empty; a press on a button gives the switcher the focus.
##
## One stand-in, justified: `markingSlot` and `wideSlot` below are slots
## written in this test, to observe what the tab hands a slot (the buttons,
## the room, the press route) independently of the real drawing's widths;
## the real slot is checked through the story above. Everything else is the stories'
## own viewmodel drawn by the real view onto the real canvas.

import std/[sequtils, strutils, unittest]

import ../agent_harbor/ah_tui_stories
import ../agent_harbor/ah_tui_initiative_tab_bar
import ../../stories/agent_harbor_process_switcher_stories

proc mount(fixture: string; cols = 180; rows = 56; mode = dmDark): AhTuiMount =
  mountAgentHarborStoryTui("agent-harbor-process-switcher", fixture, cols, rows, mode)

proc tab(m: AhTuiMount): AhNode =
  m.view.all("tab").filterIt(it.attr("active") == "true")[0]

suite "CTF-P2c: the terminal process switcher's tab":
  test "the recording's tab, active, then the plain tab, on the bar's ground":
    for mode in [dmDark, dmLight]:
      for cols in [180, 95, 45]:
        let m = mount("three", cols, mode = mode)
        let t = m.tab
        check t.attr("tab") == EnvelopeFlowTitle
        check t.row == m.view.row
        check m.canvas.bgAt(t.row, t.col) == m.canvas.p.activeTab
        let label = t.all("label")[0]
        check m.canvas.grid.styleAt(label.row, label.col).fg == m.canvas.p.activeTabText
        check m.canvas.bgAt(m.view.row, 0) == m.canvas.tone.frame
        let others = m.view.all("tab").filterIt(it.attr("active") == "false")
        check others.len == 1 and others[0].attr("tab") == OtherTabTitle
        check m.canvas.grid.styleAt(others[0].row, others[0].col + 1).fg ==
          m.canvas.p.textCaption
        # The bar declares no area of its own, as the initiative bar does
        # (`test_ctf_p1b_tui_no_box_borders_between_areas`).
        check not m.canvas.areas.anyIt(it.name in ["caption-bar", "tab", "working-area"])
        m.dispose()

  test "the tab's facts are the viewmodel's":
    let m = mount("correlation")
    let t = m.tab
    check t.attr("processes") == "3"
    check t.attr("process-active") == "1"
    check t.attr("process-ringed") == "2"
    check t.attr("process-ringed-hidden") == "false"
    check t.attr("tooltip").endsWith(
      "Ctrl+Alt+PageDown / Ctrl+Alt+PageUp to move between them")
    m.dispose()

  test "the buttons are the recording switcher's, at the window's slots":
    for (fixture, cols, shown, hidden) in [("three", 180, 3, 0), ("three", 45, 2, 1),
                                           ("many", 180, 5, 3), ("many", 45, 2, 6)]:
      let m = mount(fixture, cols)
      let buttons = m.tab.all("recording")
      check buttons.len == shown
      check buttons[0].attr("recording-active") == "true"
      let more = m.tab.all("recordings-hidden")
      check more.len == (if hidden > 0: 1 else: 0)
      if hidden > 0: check more[0].attr("recordings-hidden") == $hidden
      if fixture == "many":
        check more[0].attr("recordings-hidden-severity") == "failed"
      m.dispose()

  test "the ringed process's number is underlined in the ring step":
    # The action colour's ring step (brand/400 Dark, brand/700 Light), the
    # web's and GPUI's ring ink (study D81); the action border (brand/500)
    # it replaced is the control: it is not the ring step in either theme.
    for mode in [dmDark, dmLight]:
      let m = mount("correlation", mode = mode)
      let b = m.tab.all("recording")
      check b.mapIt(it.attr("recording-ringed")) == @["false", "true", "false"]
      let st = m.canvas.grid.styleAt(b[1].row, b[1].col + 1)
      check st.underline and st.underlineColor == ringUnderlineInk(m.canvas.p)
      check st.underlineColor != m.canvas.p.borderAction
      check contrastOf(st.underlineColor, m.canvas.p.panel) >= 4.5
      check not m.canvas.grid.styleAt(b[0].row, b[0].col + 1).underline
      m.dispose()
    check ringUnderlineInk(ahPalette(dmDark)) == "#818cf8"   # brand/400
    check ringUnderlineInk(ahPalette(dmLight)) == "#4338ca"  # brand/700

  test "behind +N, the ring is on the chip":
    for mode in [dmDark, dmLight]:
      let m = mount("many", mode = mode)
      check m.processes.markCorrelation("envelope-worker-6", "x")
      m.draw()
      let more = m.tab.all("recordings-hidden")[0]
      check more.attr("recordings-hidden-ringed") == "true"
      check m.tab.all("recording").allIt(it.attr("recording-ringed") == "false")
      # Its count underlined in the ring step, as a ringed button's number.
      var underlined = 0
      for col in more.col ..< more.col + more.width:
        let st = m.canvas.grid.styleAt(more.row, col)
        if st.underline:
          inc underlined
          check st.underlineColor == ringUnderlineInk(m.canvas.p)
      check underlined == 2   # `+3`
      m.dispose()

  test "every state's number and mark holds 4.5:1 on the buttons' ground":
    # Terminal review of 2026-11-25: on Light's warm panel the warning role
    # was 2.76:1 (`3?`), the caption role 3.55:1 (`2…`), the error role
    # 3.74:1 (`● +3`). Each state's text, and `+N`'s mark and count, are
    # read off the canvas, in both themes, at every size.
    for mode in [dmDark, dmLight]:
      for cols in [180, 95, 45]:
        for fixture in ["loading-and-missing", "many"]:
          let m = mount(fixture, cols, mode = mode)
          let ground = m.canvas.p.panel
          for b in m.tab.all("recording"):
            if b.attr("recording-active") == "true": continue
            for col in b.col ..< b.col + b.width:
              let ch = m.canvas.grid.runeAt(b.row, col)
              if ch.strip.len == 0: continue
              let st = m.canvas.grid.styleAt(b.row, col)
              check st.bg == ground
              if contrastOf(st.fg, ground) < 4.5:
                checkpoint $mode & " " & $cols & " " & fixture & " button " &
                  b.attr("recording-label") & " '" & ch & "' " & st.fg
              check contrastOf(st.fg, ground) >= 4.5
          for chip in m.tab.all("recordings-hidden"):
            for col in chip.col ..< chip.col + chip.width:
              let ch = m.canvas.grid.runeAt(chip.row, col)
              if ch.strip.len == 0: continue
              let st = m.canvas.grid.styleAt(chip.row, col)
              if contrastOf(st.fg, ground) < 4.5:
                checkpoint $mode & " " & $cols & " " & fixture & " +N '" & ch & "' " & st.fg
              check contrastOf(st.fg, ground) >= 4.5
          m.dispose()
    # Dark is unchanged: its state roles themselves.
    let d = ahPalette(dmDark)
    check buttonStateInk(d, rsFailed) == d.textError
    check buttonStateInk(d, rsMissing) == d.textWarning
    check buttonStateInk(d, rsLoading) == d.textCaption
    # The control: Light's own roles, which the drawing used, are under it.
    let l = ahPalette(dmLight)
    check contrastOf(l.textWarning, l.panel) < 3.0
    check contrastOf(l.textError, l.panel) < 4.5
    check contrastOf(l.textCaption, l.panel) < 4.5

  test "a stated button keeps its padding on both sides":
    # Terminal review, 2026-11-25: `␣2…` and `␣3?` spent the right pad on
    # the mark, which touched the button's edge; the web draws `2 …`.
    let m = mount("loading-and-missing")
    let b = m.tab.all("recording")
    check b.mapIt(it.attr("recording-label")) ==
      @[" 1 ", " 2\xE2\x80\xA6 ", " 3? "]
    for e in b:
      let last = e.col + e.width - 1
      check m.canvas.grid.runeAt(e.row, e.col) == " "
      check m.canvas.grid.runeAt(e.row, last) == " "
      check m.canvas.bgAt(e.row, last) == m.canvas.bgAt(e.row, e.col)
    m.dispose()

  test "+N is a button on the numbered buttons' ground, not the tab's":
    # The web's `.ah-rec-more`: a button like its siblings. Its control: the
    # chip's old ground, `tone.chip`, IS the active tab's fill in both
    # themes, so the old drawing showed no button at all (follow-up review).
    for mode in [dmDark, dmLight]:
      for cols in [180, 45]:
        let m = mount("many", cols, mode = mode)
        let chips = m.view.all("recordings-hidden")
        check chips.len == 1
        if chips.len == 1:
          let chip = chips[0]
          let numbered = m.view.all("recording").filterIt(it.attr("recording-active") != "true")
          check numbered.len > 0
          for col in chip.col ..< chip.col + chip.width:
            check m.canvas.bgAt(chip.row, col) == m.canvas.p.panel
            check m.canvas.bgAt(chip.row, col) != m.canvas.p.activeTab
          if numbered.len > 0:
            check m.canvas.bgAt(numbered[0].row, numbered[0].col) == m.canvas.p.panel
        check m.canvas.tone.chip == m.canvas.p.activeTab   # the old ground
        m.dispose()

  test "a click on a button is routed and selects its process":
    let m = mount("correlation")
    let b = m.tab.all("recording")[1]
    check m.handleInput("\x1b[<0;" & $(b.col + 2) & ";" & $(b.row + 1) & "M")
    check m.lastOperation == ProcessSelectOperation
    check m.tab.attr("process-active") == "2"
    check m.tab.attr("process-ringed") == "0"
    m.dispose()

suite "CTF-P2c: the switcher slot":
  test "a slot gets the buttons and the press route, and the tab makes room":
    var got: RecordingButtons
    var drawnAt = -1
    var route: ProcessPress
    let markingSlot = SwitcherSlot(
      cells: proc(buttons: RecordingButtons): int = 3 * buttons.buttons.len,
      draw: proc(c: var AhCanvas; parent: AhNode; buttons: RecordingButtons;
                 row, col: int; press: ProcessPress) =
        got = buttons
        drawnAt = col
        route = press)
    let vm = createProcessSwitcherStoryVM("three")
    var c = newAhCanvas(120, 10, ahPalette(dmDark))
    var pressed: seq[(string, string)]
    c.drawProcessSwitcherStory(vm, 0, 0, 120, 10, OtherTabTitle, "", "", markingSlot,
      proc(operation, target: string) = pressed.add (operation, target))
    check got.buttons.mapIt(it.number) == @[1, 2, 3]
    let t = c.root.all("tab").filterIt(it.attr("active") == "true")[0]
    # The name whole, then the slot's nine cells, then the tab's last cell.
    check drawnAt == t.col + 1 + EnvelopeFlowTitle.len
    check t.width == 1 + EnvelopeFlowTitle.len + 9 + 1
    route(ProcessSelectOperation, "envelope-worker")
    check pressed == @[(ProcessSelectOperation, "envelope-worker")]
    vm.dispose()

  test "on a narrow bar the name is cut before the slot gives up a cell":
    var drawnAt = -1
    let wideSlot = SwitcherSlot(
      cells: proc(buttons: RecordingButtons): int = 12,
      draw: proc(c: var AhCanvas; parent: AhNode; buttons: RecordingButtons;
                 row, col: int; press: ProcessPress) = drawnAt = col)
    let vm = createProcessSwitcherStoryVM("three")
    var c = newAhCanvas(30, 6, ahPalette(dmDark))
    c.drawProcessSwitcherStory(vm, 0, 0, 30, 6, OtherTabTitle, "", "", wideSlot)
    let t = c.root.all("tab").filterIt(it.attr("active") == "true")[0]
    check drawnAt + 12 == t.col + t.width - 1
    check t.all("label")[0].width < EnvelopeFlowTitle.len
    vm.dispose()

suite "CTF-P2c: the terminal process switcher's keys":
  test "Ctrl+Alt+PageDown / PageUp step the processes; a digit picks one":
    let m = mount("three")
    check m.handleInput("\e[6;7~")
    check m.lastOperation == ProcessNextOperation
    check m.tab.attr("process-active") == "2"
    check m.handleInput("\e[5;7~")
    check m.tab.attr("process-active") == "1"
    check m.handleInput("3")
    check m.lastOperation == ProcessSelectOperation
    check m.tab.attr("process-active") == "3"
    check not m.handleInput("9")
    m.dispose()

  test "picking the ringed process clears the ring":
    let m = mount("correlation")
    check m.handleInput("2")
    check m.tab.attr("process-active") == "2"
    check m.tab.attr("process-ringed") == "0"
    m.dispose()

  test "a press is routed and selects its process":
    let m = mount("three")
    check m.pressProcessSwitcher(ProcessSelectOperation, "envelope-worker")
    check m.lastOperation == ProcessSelectOperation
    check m.tab.attr("process-active") == "3"
    m.dispose()

proc lineText(m: AhTuiMount; row: int): string =
  for col in 0 ..< m.cols: result.add m.canvas.grid.runeAt(row, col)

proc frontendTooltip(): string =
  "frontend \xC2\xB7 pid 4180 \xC2\xB7 /srv/envelope/bin/frontend"

suite "CTF-P2c: the process switcher's hint in the status line":
  test "focused: the focused button's tooltip, on the status line's ground":
    for mode in [dmDark, dmLight]:
      for cols in [180, 95]:
        let m = mount("correlation", cols, mode = mode)
        check m.processes.focused.val
        let lines = m.view.all("status-line")
        check lines.len == 1
        let line = lines[0]
        check line.row == m.rows - 1
        let (ground, ink) = statusLineInks(m.canvas)
        check m.canvas.bgAt(line.row, 0) == ground
        let hints = m.view.all("hint")
        check hints.len == 1
        if hints.len == 1:
          let h = hints[0]
          # The focused button is the active one; its tooltip, whole.
          check h.attr("hint") == frontendTooltip()
          check h.attr("hint") == m.tab.all("recording").filterIt(
            it.attr("recording-active") == "true")[0].attr("tooltip")
          check m.lineText(line.row).strip == frontendTooltip()
          check h.col == 1
          let st = m.canvas.grid.styleAt(h.row, h.col)
          check st.fg == ink
          check contrastOf(st.fg, st.bg) >= 4.5
        m.dispose()

  test "unfocused: the status line holds no hint":
    for mode in [dmDark, dmLight]:
      let m = mount("three", mode = mode)
      check not m.processes.focused.val
      check m.processes.focusHint == ""
      check m.view.all("status-line").len == 1
      check m.view.all("hint").len == 0
      check m.lineText(m.rows - 1).strip == ""
      m.dispose()
    # The control: the same story given the focus shows it, and taking the
    # focus away clears it.
    let m = mount("three")
    m.processes.focused.val = true
    m.draw()
    check m.view.all("hint").mapIt(it.attr("hint")) == @[frontendTooltip()]
    m.processes.focused.val = false
    m.draw()
    check m.view.all("hint").len == 0
    m.dispose()

  test "the hint follows the selection, and names a state that is not ready":
    let m = mount("many")
    check m.handleInput("6")   # worker-4, whose trace failed to load
    check m.view.all("hint").mapIt(it.attr("hint")) ==
      @["worker-4 \xC2\xB7 pid 4193 \xC2\xB7 /srv/envelope/bin/worker" &
        " (failed to load: trace file truncated)"]
    m.dispose()

  test "a press on a button gives the switcher the focus":
    let m = mount("three")
    check m.view.all("hint").len == 0
    check m.pressProcessSwitcher(ProcessSelectOperation, "envelope-backend")
    check m.processes.focused.val
    check m.view.all("hint").mapIt(it.attr("hint")) ==
      @["backend \xC2\xB7 pid 4182 \xC2\xB7 /srv/envelope/bin/backend"]
    # A press on the active button only focuses: drawn again all the same.
    m.processes.focused.val = false
    m.draw()
    check m.pressProcessSwitcher(ProcessSelectOperation, "envelope-backend")
    check m.view.all("hint").len == 1
    m.dispose()

  test "a tooltip longer than the line is cut with an ellipsis":
    for mode in [dmDark, dmLight]:
      # At the sidebar's 45 cells the line holds 43; the front end's
      # tooltip is 48.
      let m = mount("many", 45, mode = mode)
      let h = m.view.all("hint")
      check h.len == 1
      if h.len == 1:
        check h[0].attr("hint") == frontendTooltip()   # the fact: whole
        let shown = m.lineText(h[0].row).strip
        check shown.endsWith("\xE2\x80\xA6")
        check widthOf(shown) == 43
        check frontendTooltip().startsWith(shown[0 ..< shown.len - 3])
        # A cell clear at either end of the line.
        check m.canvas.grid.runeAt(h[0].row, 0) == " "
        check m.canvas.grid.runeAt(h[0].row, 44) == " "
      m.dispose()
