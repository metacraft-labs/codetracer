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
##   line; a launch in flight locks it (`Launch` busy, `Launching…` in the
##   body role); a launch's notice or failure; the new session queued under
##   its initiative; the one-column fold's summary wrapped whole.
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

  test "launching: the form locked, Launch busy, Launching... in the body role":
    for (cols, rows) in [(180, 56), (45, 56)]:
      for mode in [dmDark, dmLight]:
        let m = mount("launching", cols, rows, mode)
        check m.view.attr("cc-launching") == "true"
        let send = m.view.first("send")
        check send.attr("send") == "Launch"
        check send.attr("send-busy") == "true"
        check send.attr("send-enabled") == "false"
        # Busy is seen: the spinner before the label, in the action colour's
        # ring step, at 3:1 or more on the disabled button's ground (WCAG 2.2
        # SC 1.4.11; the action border was 2.5:1 there in Light).
        let spin = m.view.first("busy-spinner")
        check not spin.isNil
        if not spin.isNil:
          let st = m.canvas.grid.styleAt(spin.row, spin.col)
          check m.canvas.grid.runeAt(spin.row, spin.col) == "\xE2\xA0\x8B"
          check st.fg == m.canvas.busyInk
          check contrastOf(st.fg, st.bg) >= 3.0
        let notice = m.view.first("cc-notice-line")
        check notice.attr("cc-notice-line") == "Launching\xE2\x80\xA6"
        check m.canvas.grid.styleAt(notice.row, notice.col).fg == m.canvas.p.textBody
        # No chip takes a click while it waits: For and the mode stay.
        let toggles = m.view.all("toggle")
        check toggles.len > 0
        check toggles.allIt(it.attr("disabled") == "true")
        # The schedule's disclosure is not one to open while locked: its
        # fold in the disabled role, as the options not chosen (D74).
        if cols == 180:
          let folds = m.view.all("schedule-fold-disabled")
          check folds.len == 1
          if folds.len == 1:
            check m.canvas.grid.styleAt(folds[0].row, folds[0].col).fg ==
              m.canvas.p.textDisabled
          # The schedule's summary is part of what is launched: the label
          # role, as the form's values.
          let sums = m.view.all("schedule-summary")
          check sums.len == 1
          if sums.len == 1:
            check m.canvas.grid.styleAt(sums[0].row, sums[0].col).fg == m.canvas.p.textLabel
          # An option not chosen has no chip ground: the disabled role on the
          # column's ground, at 3:1 or more.
          for t in toggles.filterIt(it.attr("chosen") == "false"):
            let st = m.canvas.grid.styleAt(t.row, t.col + 1)
            check contrastOf(st.fg, st.bg) >= 3.0
        for t in toggles: discard m.click(t)
        check m.center.launchForTitle == "Shield model hardening"
        check m.center.mode == lmTask
        m.dispose()

  test "launch failed: Could not launch in the error role, the instruction kept":
    let m = mount("launch-failed")
    check m.view.attr("cc-launching") == "false"
    let notice = m.view.first("cc-notice-line")
    check notice.attr("cc-notice-line") == "Could not launch: " & LaunchFailure
    check m.view.first("send").attr("send-enabled") == "true"
    check m.center.composer.text == EmptyShieldTask
    m.dispose()

  test "at the panel size the fold leaves RECENT LAUNCHES on screen":
    # 95x40: two columns; where the launch column cannot hold the whole form
    # with what follows it, it folds to its summary (study D75; the empty
    # fleet, with no answer and no launch yet, keeps it whole); the summary
    # says what differs from the defaults, so the answer and the recent
    # launches stay in view (study D84), at least the label and the row
    # under it.
    for fixture in ["populated", "empty", "launching", "launched", "launch-failed"]:
      for mode in [dmDark, dmLight]:
        let m = mount(fixture, 95, 40, mode)
        check m.view.attr("columns") == "two"
        let summary = m.view.first("form-summary")
        check summary.isNil == (fixture == "empty")
        let recent = m.view.all("section").filterIt(it.attr("section") == "RECENT LAUNCHES")
        check recent.len == 1
        if recent.len == 1:
          check recent[0].row + 1 <= m.rows - 1
        m.dispose()

  test "the one-column fold's summary is wrapped whole, never cut":
    for fixture in ["populated", "launching", "launch-failed"]:
      let m = mount(fixture, 45, 56)
      let summary = m.view.first("form-summary")
      check not summary.isNil
      if summary.isNil:
        m.dispose()
        continue
      check "\xE2\x80\xA6" notin summary.attr("form-summary")
      var drawn = ""
      for r in summary.row ..< summary.row + summary.height:
        for col in summary.col ..< summary.col + summary.width:
          drawn.add m.canvas.grid.runeAt(r, col)
      check "\xE2\x80\xA6" notin drawn
      m.dispose()

  test "one column folds only where the screen cannot hold the whole form":
    # An empty fleet's overview is short: its sidebar has room for the whole
    # form under the launch column's head (study D75, follow-up review).
    let e = mount("empty", 45, 56)
    check e.view.first("form-summary").isNil
    check e.view.all("field-label").anyIt(it.attr("field-label") == "Session name")
    e.dispose()
    let p = mount("populated", 45, 56)
    check not p.view.first("form-summary").isNil
    p.dispose()
    # Locked, the folded summary is what is being launched: the label role,
    # as the whole form's values are (D74).
    let l = mount("launching", 95, 40)
    let s = l.view.first("form-summary")
    check not s.isNil
    if not s.isNil:
      check l.canvas.grid.styleAt(s.row, s.col).fg == l.canvas.p.textLabel
    l.dispose()

  test "a locked form's fields read as sent, and the instruction is never cut":
    # 95x40: the 40-character task does not fit the field's 39 cells; it
    # wraps rather than being cut in its middle (study D84). Locked, the
    # field has no field ground and its words are in the label role, above
    # the options not chosen (the disabled role) in both themes (D74).
    for mode in [dmDark, dmLight]:
      let m = mount("launching", 95, 40, mode)
      let values = m.view.all("value").filterIt(it.attr("value") == EmptyShieldTask)
      check values.len == 1
      if values.len == 1:
        let v = values[0]
        check v.attr("readonly") == "true"
        var drawn = ""
        for r in v.row ..< v.row + v.height:
          for col in v.col ..< v.col + v.width:
            drawn.add m.canvas.grid.runeAt(r, col)
        check "\xE2\x80\xA6" notin drawn
        check m.canvas.grid.styleAt(v.row, v.col).fg == m.canvas.p.textLabel
      m.dispose()
      # Every locked value of the whole form (at 180x56, where it is not
      # folded to its summary), not only the instruction.
      let whole = mount("launching", 180, 56, mode)
      let formValues = whole.view.all("value").filterIt(it.attr("readonly") == "true")
      check formValues.len > 2
      for fv in formValues:
        check whole.canvas.grid.styleAt(fv.row, fv.col).fg == whole.canvas.p.textLabel
      whole.dispose()
    let idle = mount("empty", 180, 56)
    check idle.view.first("busy-spinner").isNil
    idle.dispose()
    let open = mount("launch-failed", 95, 40)
    check open.view.all("value").filterIt(it.attr("value") == EmptyShieldTask)
      .allIt(it.attr("readonly") == "false")
    open.dispose()

  test "a waiting row's question is cut at a word, never inside one":
    # The question has at most two lines; a longer one ends in "…" after
    # its last whole word that fits, nothing dangling before the "…" (TUI
    # reviews of 2026-11-24: `over to …`, then `loader; o…`), not even the
    # word's own comma, semicolon, colon or full stop (`loader;…`).
    var cut = 0
    for (cols, rows) in [(95, 40), (45, 56), (180, 56)]:
      let m = mount("populated", cols, rows)
      for n in m.view.all("waiting-session"):
        let row = m.center.waiting.filterIt(it.item.id == n.attr("waiting-session"))
        check row.len == 1
        if row.len != 1 or n.height < 3: continue
        let why = row[0].waitingWhy
        var lines: seq[string]
        for r in n.row + 2 ..< n.row + n.height:
          var line = ""
          for col in n.col + 1 ..< n.col + n.width:
            line.add m.canvas.grid.runeAt(r, col)
          lines.add line.strip(leading = false)
        let drawn = lines.join(" ")
        check lines.len <= 2
        if drawn.endsWith("\xE2\x80\xA6"):
          inc cut
          let kept = drawn[0 ..< drawn.len - 3]
          check kept.len > 0 and kept[^1] != ' '
          check kept.len > 0 and kept[^1] notin WordCutPunctuation
          let keptWords = kept.splitWhitespace
          let words = why.splitWhitespace
          check keptWords.len <= words.len
          if keptWords.len in 1 .. words.len:
            let last = keptWords.len - 1
            check keptWords[0 ..< last] == words[0 ..< last]
            check keptWords[last] ==
              words[last].strip(leading = false, chars = WordCutPunctuation)
        else:
          check drawn.splitWhitespace == why.splitWhitespace
      m.dispose()
    # The narrow sizes do cut a question, so the rule is exercised.
    check cut > 0

  test "launched: the notice, and the new session queued under its initiative":
    let m = mount("launched")
    check m.view.first("cc-notice-line").attr("cc-notice-line").startsWith("Started on hub-a")
    check m.view.attr("cc-launch-for") == "Shield model hardening"
    var queued = false
    for line in m.canvas.root.all("session"):
      if line.attr("session") == LaunchedSession: queued = true
    check queued
    check LaunchedSession notin m.waitingIds
    m.dispose()
    # Wrapped at the sidebar's width, no line of the answer ends in its
    # ` · ` separator: the line break separates the parts.
    let s = mount("launched", 45, 56)
    let n = s.view.first("cc-notice-line")
    check not n.isNil and n.height > 1
    if not n.isNil:
      for r in n.row ..< n.row + n.height:
        var line = ""
        for col in n.col ..< n.col + n.width: line.add s.canvas.grid.runeAt(r, col)
        check not line.strip(leading = false).endsWith("\xC2\xB7")
    s.dispose()

  test "the Initiatives panel's head summary wraps with no ` · ` at a line's end":
    # TUI §3.4's one cut rule, where the summary wraps rather than is cut:
    # the line break separates the parts, so a separator the wrap leaves
    # last is dropped (`11 sessions ·` reads `11 sessions`). Issue
    # 2026-11-24-tui-initiatives-panel-head-summary-leaves-a-separator-at-a-line-end.
    var wrapped = 0
    for fixture in ["populated", "launched"]:
      for (cols, rows) in [(95, 40), (45, 56)]:
        for mode in [dmDark, dmLight]:
          let m = mount(fixture, cols, rows, mode)
          let panel = m.canvas.root.all("surface").filterIt(
            it.attr("surface") == "agent-harbor-initiatives")
          check panel.len == 1
          if panel.len == 1:
            let s = panel[0].first("summary")
            check not s.isNil and s.attr("summary").len > 0
            if not s.isNil and s.height > 1:
              inc wrapped
              var words = ""
              for r in s.row ..< s.row + s.height:
                var line = ""
                for col in s.col ..< s.col + s.width: line.add m.canvas.grid.runeAt(r, col)
                let shown = line.strip
                check not shown.endsWith("\xC2\xB7")
                check not shown.startsWith("\xC2\xB7")
                words.add " " & shown
              # Nothing else is lost: the words are the summary's, less the
              # separators the breaks stood in for.
              let want = s.attr("summary").splitWhitespace.filterIt(it != "\xC2\xB7")
              check words.splitWhitespace.filterIt(it != "\xC2\xB7") == want
          m.dispose()
    # The narrow sizes do wrap the summary, so the rule is exercised.
    check wrapped > 0

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

  test "the status line under the control center, as L7 shows it":
    for fixture in ["off", "tracking", "paused"]:
      for cols in [180, 45]:
        let m = gaze(fixture, cols)
        let centers = m.canvas.root.all("surface").filterIt(
          it.attr("surface") == "agent-harbor-control-center")
        check centers.len == 1
        check centers[0].row + centers[0].height <= m.rows - 1
        check m.view.attr("surface") == "agent-harbor-status-gaze"
        m.dispose()

  test "the pause key and a click pause and resume it":
    let m = gaze("tracking")
    check m.handleInput("\x1b\x19")                    # ESC ^Y: Ctrl+Alt+Y
    check m.lastOperation == GazeTogglePauseOperation
    check m.view.first("gaze-mark").attr("gaze-mark") == "paused"
    check m.click(m.view.first("gaze-mark"))
    check m.view.first("gaze-mark").attr("gaze-mark") == "tracking"
    m.dispose()
