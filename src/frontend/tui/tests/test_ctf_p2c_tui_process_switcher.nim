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
##   action role, the ring on `+N` when it hides that process; a click on a
##   button is routed and selects its process. The tab hands any slot the
##   viewmodel's buttons and the press route, and makes room for it before
##   cutting the name.
## * **Keys are routed**: `CSI 6;7~` / `CSI 5;7~` (`Ctrl+Alt+PageDown` /
##   `PageUp`, as a terminal sends them) step the processes; a digit picks
##   one, and picking the ringed process clears the ring.
##
## One stand-in, justified: `markingSlot` and `wideSlot` below are slots
## written in this test, to observe what the tab hands a slot (the buttons,
## the room, the press route) independently of the real drawing's widths;
## the real slot is checked through the story above. Everything else is the stories'
## own viewmodel drawn by the real view onto the real canvas.

import std/[sequtils, strutils, unittest]

import ../agent_harbor/ah_tui_stories
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

  test "the ringed process's number is underlined in the action role":
    for mode in [dmDark, dmLight]:
      let m = mount("correlation", mode = mode)
      let b = m.tab.all("recording")
      check b.mapIt(it.attr("recording-ringed")) == @["false", "true", "false"]
      let st = m.canvas.grid.styleAt(b[1].row, b[1].col + 1)
      check st.underline and st.underlineColor == m.canvas.p.borderAction
      check not m.canvas.grid.styleAt(b[0].row, b[0].col + 1).underline
      m.dispose()

  test "behind +N, the ring is on the chip":
    let m = mount("many")
    check m.processes.markCorrelation("envelope-worker-6", "x")
    m.draw()
    let more = m.tab.all("recordings-hidden")[0]
    check more.attr("recordings-hidden-ringed") == "true"
    check m.tab.all("recording").allIt(it.attr("recording-ringed") == "false")
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
