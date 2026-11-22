## CTF-P2c step 4: the terminal's control center and status line gaze mark
## (study §2.4, §2.5, D24, D64-D70), in the story host that mounts them
## (`tui/agent_harbor/ah_tui_stories.nim`).
##
## * **Two columns, one when narrow**: launching on the left and the
##   overview on the right at the laptop and wide sizes; one column,
##   launching first, at the sidebar size.
## * **The overview** is the waiting sessions in inbox order, each carrying
##   its press and no dot, then the Initiatives panel's own drawing (study
##   D73); an empty fleet says `No initiatives yet.`.
## * **The launch column is the composer's form**: its fields, its send
##   line; a launch's notice; the new session queued under its initiative.
## * **Presses and keys are routed**: a click on a mode chip, on a `For`
##   chip and on a waiting row does what it carries; `Down` and `Enter` walk
##   and open the waiting rows.
## * **Every ground and ink is a design-system role** the palette resolves.
## * **The gaze mark**: off draws nothing; tracking and paused draw the eye
##   (struck when paused) and the words at the status line's end; the pause
##   key (`Ctrl+Alt+Y`, ESC then ^Y as a terminal sends it) and a click
##   pause it.
##
## No mocks: the stories' own viewmodels over the scripted router and action
## source, drawn by the real views onto the real canvas.

import std/[sequtils, strutils, unittest]

import ../agent_harbor/ah_tui_stories
import ../../stories/agent_harbor_control_center_stories

proc mount(fixture: string; cols = 180; rows = 56; mode = dmDark): AhTuiMount =
  mountAgentHarborStoryTui("agent-harbor-control-center", fixture, cols, rows, mode)

proc gaze(fixture: string; cols = 180; rows = 56; mode = dmDark): AhTuiMount =
  mountAgentHarborStoryTui("agent-harbor-status-gaze", fixture, cols, rows, mode)

proc click(m: AhTuiMount; n: AhNode): bool =
  m.handleInput("\x1b[<0;" & $(n.col + 1) & ";" & $(n.row + 1) & "M")

proc waitingIds(m: AhTuiMount): seq[string] =
  m.view.all("waiting-session").mapIt(it.attr("waiting-session"))

suite "CTF-P2c: the terminal control center":
  test "two columns at laptop and wide, one column, launching first, at sidebar":
    for (cols, rows, columns) in [(180, 56, "two"), (240, 67, "two"), (45, 56, "one"),
                                  (95, 40, "two")]:
      for mode in [dmDark, dmLight]:
        let m = mount("populated", cols, rows, mode)
        check m.view.attr("columns") == columns
        let launch = m.view.first("cc-launch")
        let overview = m.view.first("cc-overview")
        if columns == "two":
          check overview.col > launch.col + launch.width - 1
          check overview.row == launch.row
        else:
          check overview.row >= launch.row + launch.height
        # The columns are told apart by their grounds: the window's between
        # them, where the web has its splitter.
        let gap = if columns == "two": m.canvas.bgAt(launch.row, launch.col + launch.width)
                  else: m.canvas.bgAt(overview.row - 1, overview.col)
        check gap != m.canvas.bgAt(launch.row, launch.col)
        check gap != m.canvas.bgAt(overview.row, overview.col + 1)
        m.dispose()

  test "the waiting sessions in inbox order, then the Initiatives panel's own drawing":
    let m = mount("populated")
    let overview = m.view.first("cc-overview")
    let panels = m.canvas.root.all("surface").filterIt(
      it.attr("surface") == "agent-harbor-initiatives")
    check panels.len == 1
    # The waiting list first, at the overview's top, the panel under it
    # (study D73).
    let waiting = m.view.first("waiting-section")
    check waiting.row == overview.row
    check panels[0].col == overview.col
    check panels[0].row == waiting.row + waiting.height + 1
    check m.canvas.root.all("initiative").len == 4
    check m.view.all("waiting-title").mapIt(it.attr("waiting-title")) == @[
      "Make calculate_damage safe for masses above u32",
      "Fix the negative-field test that times out on macOS",
      "Write the 0.4 changelog"]
    for row in m.view.all("waiting-session"):
      check row.attr("operation") == ControlCenterOpenSessionOperation
      check row.all("mark").len == 0                  # no dot of its own
    check m.view.first("waiting-section").attr("waiting-section") == "3"
    m.dispose()

  test "the launch column is the composer's form and send line":
    let m = mount("populated")
    let launch = m.view.first("cc-launch")
    check launch.all("field-label").mapIt(it.attr("field-label")).anyIt(it == "Repository")
    check launch.first("send").attr("send") == "Launch"
    check launch.all("recent-launch").mapIt(it.attr("recent-launch")) == @[
      "Asteroid fields generated from seeds, end to end",
      "Make the regeneration cap configurable per ship"]
    m.dispose()

  test "launching: the notice, and the new session queued under its initiative":
    let m = mount("launching")
    check m.view.first("cc-notice-line").attr("cc-notice-line").startsWith("Started on hub-a")
    check m.view.attr("cc-launch-for") == "Shield model hardening"
    var queued = false
    for line in m.canvas.root.all("session"):
      if line.attr("session") == LaunchedSession: queued = true
    check queued
    check LaunchedSession notin m.waitingIds
    m.dispose()

  test "an empty fleet, loading and error":
    let e = mount("empty")
    check e.view.first("cc-empty-line").attr("cc-empty-line") == "No initiatives yet."
    check e.canvas.root.all("initiative").len == 0
    e.dispose()
    let l = mount("loading")
    check l.view.attr("cc-state") == "asLoading"
    check l.view.all("waiting-section").len == 0
    l.dispose()
    let x = mount("error")
    check x.view.attr("cc-state") == "asError"
    x.dispose()

  test "a click on a chip and on a waiting row does what it carries":
    let m = mount("populated")
    let initiative = m.view.all("toggle").filterIt(it.attr("toggle") == "New initiative")
    check m.click(initiative[0])
    check m.lastOperation == ControlCenterNewInitiativeOperation
    check m.view.attr("cc-mode") == "initiative"
    let shield = m.view.all("toggle").filterIt(it.attr("toggle") == "Shield model hardening")
    check m.click(shield[0])
    check m.view.attr("cc-launch-for") == "Shield model hardening"
    let row = m.view.all("waiting-session")[1]
    check m.click(row)
    check m.lastOperation == ControlCenterOpenSessionOperation
    check m.center.requestedSession.val == row.attr("waiting-session")
    m.dispose()

  test "Down and Enter walk and open the waiting rows":
    let m = mount("populated")
    check m.handleInput("\x1b[B")
    check m.lastOperation == ControlCenterNextOperation
    let focused = m.view.all("waiting-focused").filterIt(it.attr("waiting-focused") == "true")
    check focused.len == 1
    check focused[0].attr("waiting-session") == m.waitingIds[0]
    check m.handleInput("\r")
    check m.center.requestedSession.val == m.waitingIds[0]
    m.dispose()

  test "a needs-input state word is in the warning role, an ended turn's in the caption":
    for mode in [dmDark, dmLight]:
      let m = mount("populated", mode = mode)
      let words = m.view.all("state-word")
      check words.len == 3
      let ask = m.canvas.grid.styleAt(words[0].row, words[0].col).fg
      let idle = m.canvas.grid.styleAt(words[2].row, words[2].col).fg
      check ask == warningInk(m.canvas.p)
      check idle == m.canvas.p.textCaption
      m.dispose()

suite "CTF-P2c: the terminal gaze mark":
  test "off draws nothing; tracking and paused draw the eye and the words at the end":
    let off = gaze("off")
    check off.view.all("gaze-mark").len == 0
    off.dispose()
    for (fixture, shown) in [("tracking", "\xE2\x97\x89 Gaze"), ("paused", "\xE2\x8A\x98 Gaze paused")]:
      for cols in [180, 45]:
        let m = gaze(fixture, cols)
        let mark = m.view.first("gaze-mark")
        check mark.attr("gaze-mark") == fixture
        check mark.row == m.rows - 1
        check mark.col + mark.width == cols - 1
        check m.canvas.grid.runeAt(mark.row, mark.col) == shown.split(' ')[0]
        check mark.attr("tooltip").contains("Ctrl+Alt+Y")
        m.dispose()

  test "the pause key and a click pause and resume it":
    let m = gaze("tracking")
    check m.handleInput("\x1b\x19")                    # ESC ^Y: Ctrl+Alt+Y
    check m.lastOperation == GazeTogglePauseOperation
    check m.view.first("gaze-mark").attr("gaze-mark") == "paused"
    check m.click(m.view.first("gaze-mark"))
    check m.view.first("gaze-mark").attr("gaze-mark") == "tracking"
    m.dispose()
