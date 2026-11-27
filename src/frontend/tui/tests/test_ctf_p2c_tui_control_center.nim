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
## * **A session's status word holds 4.5:1** (WCAG 2.2 SC 1.4.3) on the
##   ground it is drawn on, in both modes: the Initiatives panel's (the
##   panel, the stripe and the selected initiative) and the waiting rows'.
##   In Light `running`, `needs input` and `failed` take their role's 800
##   step wherever it holds and a darker ink only where it does not; one
##   word on one ground is one ink in both places; the web's rules resolve
##   to the same inks on the grounds the web draws them on.
## * **The Initiatives panel's status marks hold 3:1 on the plain panel**
##   (WCAG 2.2 SC 1.4.11): its initiatives' and sessions' dots, its
##   milestone legend's marks and its bar's segments take `markOnPanel` on
##   the panel ground and keep their icon inks on the band and the selected
##   row; a planned mark and segment are grey/400 in Light on every ground;
##   the web's plain-row rules and the popup header's rules resolve to the
##   same inks.
## * **The gaze mark**: off draws nothing; tracking and paused draw the eye
##   (struck when paused) and the words at the status line's end; the pause
##   key (`Ctrl+Alt+Y`, ESC then ^Y as a terminal sends it) and a click
##   pause it.
##
## No mocks: the stories' own viewmodels over the scripted router and action
## source, drawn by the real views onto the real canvas.

import std/[os, sequtils, strutils, unittest]

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

proc wordProblems(p: AhPalette; attention: SessionAttention; fg, bg, where: string): seq[string] =
  ## A session's status word drawn in `fg` on `bg`, against the rule for it
  ## (`initiativeSessionWordColour`) and what the rule must give: 4.5:1 on
  ## that ground (WCAG 2.2 SC 1.4.3); in Light the role's 800 step wherever
  ## it holds 4.5:1 there and a darker ink only where it does not; in Dark
  ## the role's text step; the label role for a state with no status role.
  let ratio = contrastOf(fg, bg)
  if fg != p.initiativeSessionWordColour(attention, bg):
    result.add where & ": " & fg & " on " & bg & ", the palette's " &
               p.initiativeSessionWordColour(attention, bg)
  if ratio < StatusTextFloor:
    result.add where & ": " & fg & " on " & bg & " is " & formatFloat(ratio, ffDecimal, 2) & ":1"
  if attention notin {saNeedsInput, saRunning, saFailed}:
    if fg != p.textLabel: result.add where & ": " & fg & ", not the label role"
  elif p.mode == dmDark:
    let role = case attention
               of saNeedsInput: p.textWarning
               of saRunning: p.textSuccess
               else: p.textError
    if fg != role: result.add where & ": " & fg & ", not its role " & role
  else:
    let step = p.statusStep800(pieRoleOf(attention))
    if contrastOf(step, bg) >= StatusTextFloor:
      if fg != step: result.add where & ": " & fg & " on " & bg & ", not the 800 step " & step
    elif fg == step or inkLuminance(fg) >= inkLuminance(step):
      result.add where & ": " & fg & " on " & bg & " is not darker than the 800 step " & step

proc tokenHex(name: string; mode: DesignMode): string =
  ## The hex of the design token `name` spells (`colors-ui-…`, or a
  ## primitive step such as `colors-warning-800`), or "".
  for t in DesignToken:
    if ($t).replace('/', '-') == name: return DesignTokenHex[t][mode]
  for t in DesignPrimitive:
    if ($t).replace('/', '-') == name: return DesignPrimitiveHex[t][mode]

proc modeArgs(args: string): seq[string] =
  ## `args` split at its top-level commas: a `mix-ink(…)` stays whole.
  var depth = 0
  var arg = ""
  for ch in args:
    if ch == ',' and depth == 0:
      result.add arg.strip
      arg = ""
      continue
    if ch == '(': inc depth
    elif ch == ')': dec depth
    arg.add ch
  result.add arg.strip

proc resolved(value: string; mode: DesignMode): string =
  ## A mode's value as the stylesheet resolves it (a token's name, or
  ## `mix-ink(<token>, <token>, <n>%)`, which `defaults.styl` defines as the
  ## palette's `mixInk`), or "" for anything this does not read.
  if value.startsWith("mix-ink(") and value.endsWith(")"):
    let args = modeArgs(value["mix-ink(".len ..< value.high])
    if args.len != 3 or not args[2].endsWith("%"): return ""
    let (a, b) = (tokenHex(args[0], mode), tokenHex(args[1], mode))
    if a.len == 0 or b.len == 0: return ""
    return mixInk(a, b, parseInt(args[2][0 ..< args[2].high]))
  tokenHex(value, mode)

proc byModeOf(value: string; mode: DesignMode): string =
  ## A `by-mode(<Dark>, <Light>)` value's `mode` half, unresolved, or "".
  if not (value.startsWith("by-mode(") and value.endsWith(")")): return ""
  let names = modeArgs(value["by-mode(".len ..< value.high])
  if names.len == 2: names[ord(mode)] else: ""

proc stylesheet(name: string): seq[string] =
  ## A component stylesheet's lines (`styles/components/<name>`).
  readFile(currentSourcePath().parentDir.parentDir.parentDir / "styles" / "components" /
           name).splitLines

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

  test "the error block's title holds 4.5:1 on its ground, in the error rule's one red":
    # Terminal review round 3 (2026-11-26): Light's `Could not load the
    # initiatives` was the error role, #dc2626, 3.74:1 on the panel, beside
    # `Could not launch: ...` in red/700 (#b91c1c, 5.01:1). The title takes
    # the palette's rule for status text on its ground (`statusTextInk`).
    var titles = 0
    for (surface, fixture) in [("agent-harbor-control-center", "error"),
                               ("agent-harbor-initiatives", "error")]:
      for (cols, rows) in [(180, 56), (45, 56), (220, 56)]:
        for mode in [dmDark, dmLight]:
          let m = mountAgentHarborStoryTui(surface, fixture, cols, rows, mode)
          let p = m.canvas.p
          for n in m.canvas.root.all("notice"):
            if n.attr("notice") != "error": continue
            let t = n.first("error-title")
            check not t.isNil
            if t.isNil: continue
            inc titles
            for col in t.col ..< t.col + t.width:
              if m.canvas.grid.runeAt(t.row, col).strip.len == 0: continue
              let st = m.canvas.grid.styleAt(t.row, col)
              check st.fg == p.statusTextInk(prError, st.bg)
              check contrastOf(st.fg, st.bg) >= StatusTextFloor
              if mode == dmLight:
                # The same red as `Could not launch` (red/700), not the role.
                check st.fg == tokenHexOf(dtColorsUiTextErrorPrimaryHover, dmLight)
                check contrastOf(p.textError, st.bg) < StatusTextFloor   # the control
          m.dispose()
    check titles >= 12

  test "the selected initiative's bar holds 3:1 on the selected row, in the ring step":
    # Terminal review round 3 (2026-11-26): the bar `▎` was the action border
    # (#6366f1), 2.52:1 on Light's #c8c2b5 and 2.47:1 on Dark's #3c3c3c. It
    # is the action colour's ring step (`actionRingInk`, the correlation
    # ring's step).
    var bars = 0
    for (cols, rows) in [(180, 56), (45, 56)]:
      for mode in [dmDark, dmLight]:
        let m = mountAgentHarborStoryTui("agent-harbor-initiatives", "selected", cols, rows, mode)
        let p = m.canvas.p
        for row in m.canvas.root.all("initiative"):
          if row.attr("selected") != "true": continue
          for r in row.row ..< min(row.row + row.height, m.rows):
            check m.canvas.grid.runeAt(r, row.col) == BarGlyph
            let st = m.canvas.grid.styleAt(r, row.col)
            inc bars
            check st.fg == p.actionRingInk
            check st.bg == p.activeRow
            check contrastOf(st.fg, st.bg) >= 3.0
            check contrastOf(p.borderAction, st.bg) < 3.0   # the control
        m.dispose()
    check bars >= 4
    check actionRingInk(ahPalette(dmLight)) == "#4338ca"   # brand/700
    check actionRingInk(ahPalette(dmDark)) == "#818cf8"    # brand/400

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

  test "a waiting row's state word is a session's status word on its ground":
    # The waiting list's state words and the Initiatives panel's status words
    # are one rule (`initiativeSessionWordColour`): `needs input` in Light is
    # orange/800 on the panel, not the warning role's 700 step it was
    # (#c2410c, 4.01:1 there), and an ended turn's word is in the label role
    # as the panel's are, not the caption (#7a756a, 3.55:1 on the panel).
    for mode in [dmDark, dmLight]:
      let m = mount("populated", mode = mode)
      let p = m.canvas.p
      let words = m.view.all("state-word")
      check words.len == 3
      let ask = m.canvas.grid.styleAt(words[0].row, words[0].col)
      let idle = m.canvas.grid.styleAt(words[2].row, words[2].col)
      check ask.fg == p.initiativeSessionWordColour(saNeedsInput, ask.bg)
      check idle.fg == p.textLabel
      if mode == dmLight:
        check ask.bg == p.panel
        check ask.fg == "#92400e"            # amber/800
      else:
        check ask.fg == p.textWarning
      for w in words:
        let st = m.canvas.grid.styleAt(w.row, w.col)
        check contrastOf(st.fg, st.bg) >= StatusTextFloor
      m.dispose()

  test "the Initiatives panel's session status words hold 4.5:1 on every ground; their dots take markOnPanel":
    # The status word is a session line's only word for its state, beside a
    # dot of the same hue, so it is text (WCAG 2.2 SC 1.4.3): 4.5:1 against
    # the ground it is drawn on, the selected initiative's (#c8c2b5 in
    # Light) included. Light takes the role's 800 step wherever that holds
    # and a darker ink only where it does not (`wordProblems`).
    var problems: seq[string]
    var seen: seq[string]   # "<mode> <attention> <ground>", each word checked
    for (surface, fixture) in [("agent-harbor-control-center", "populated"),
                               ("agent-harbor-initiatives", "populated"),
                               ("agent-harbor-initiatives", "selected")]:
      for (cols, rows) in [(95, 40), (45, 56), (180, 56)]:
        for mode in [dmDark, dmLight]:
          let m = mountAgentHarborStoryTui(surface, fixture, cols, rows, mode)
          let p = m.canvas.p
          let panels = m.canvas.root.all("surface").filterIt(
            it.attr("surface") == "agent-harbor-initiatives")
          check panels.len == 1
          for panel in panels:
            for s in panel.all("session"):
              let where = $mode & " " & surface & " " & $cols & "x" & $rows & " " &
                          s.attr("session")
              let attention = parseEnum[SessionAttention](s.attr("attention"))
              let mark = s.first("mark")
              let word = s.first("status")
              if mark.isNil or word.isNil:
                problems.add where & ": no mark or no status word"
                continue
              # A line laid out past the screen's last row is not drawn.
              if word.row >= m.rows or mark.row >= m.rows: continue
              # The dot is its icon colour, readable on the plain panel
              # (`markOnPanel`; the marks test below).
              let dot = m.canvas.grid.styleAt(mark.row, mark.col)
              let dotInk = p.markOnPanel(p.markOf(attention), dot.bg).colour
              if dot.fg != dotInk:
                problems.add where & ": the dot is " & dot.fg & ", not " & dotInk
              let st = m.canvas.grid.styleAt(word.row, word.col)
              if st.fg.len == 0 or st.bg.len == 0:
                problems.add where & ": the status word's cell has no colours"
                continue
              problems.add wordProblems(p, attention, st.fg, st.bg,
                                        where & " '" & word.attr("status") & "'")
              let ground = if st.bg == m.canvas.tone.body: "panel"
                           elif st.bg == m.canvas.tone.band: "stripe"
                           elif st.bg == p.activeRow: "selected"
                           else: st.bg
              seen.add $mode & " " & $attention & " " & ground
          m.dispose()
    for problem in problems: echo "  ", problem
    check problems.len == 0
    # A check that ran on no word proves nothing: the fixtures must put a
    # running and a waiting session on the panel ground, on the stripe and
    # on the selected initiative, in each mode.
    for mode in [dmDark, dmLight]:
      for attention in [saRunning, saNeedsInput]:
        for ground in ["panel", "stripe", "selected"]:
          let key = $mode & " " & $attention & " " & ground
          if key notin seen: echo "  never checked: ", key
          check key in seen

  test "the Initiatives panel's status marks hold 3:1 on the plain panel, by markOnPanel":
    # In Light the success and warning icon inks are 2.55 and 2.76:1 on the
    # panel (#e6e2db), a milestone's other mark 2.42:1 and the planned track
    # (the border role, #aca494) 1.92:1, under WCAG 2.2 SC 1.4.11's 3:1. On
    # the plain panel ground each status mark takes `markOnPanel` (the pie's
    # ink for its role there); on the band and the selected row it keeps its
    # icon ink (the selected row's gap is tracked on its own); the planned
    # mark is grey/400 on every ground. The bar's planned remainder is the
    # bar's own ground, not a mark: it stays the light border role, so a bar
    # does not read as full.
    let grey400 = DesignPrimitiveHex[dpColorsGrey400][dmLight]
    check grey400 == "#727272"
    check ahPalette(dmLight).plannedMark == grey400
    check ahPalette(dmLight).markOf(mscPlanned).colour == grey400
    check ahPalette(dmDark).plannedMark == tokenHexOf(dtColorsUiIconPrimarySubtle, dmDark)
    check ahPalette(dmLight).trackPlanned == tokenHexOf(dtColorsUiBorderPrimary, dmLight)
    check ahPalette(dmLight).trackPlanned == "#aca494"
    check ahPalette(dmDark).trackPlanned == tokenHexOf(dtColorsUiIconPrimarySubtle, dmDark)
    var problems: seq[string]
    var onPanel: seq[string]   # "<kind> <status>", checked on the panel in Light
    var planned, offPanel = 0
    proc checkCell(m: AhTuiMount; r, col: int; want: MarkStyle; kind, status, where: string;
                   problems: var seq[string]; onPanel: var seq[string]; offPanel: var int) =
      ## The cell at (`r`, `col`) is `want` by `markOnPanel` on its ground,
      ## and holds 3:1 where that ground is the panel.
      let p = m.canvas.p
      let st = m.canvas.grid.styleAt(r, col)
      let wanted = p.markOnPanel(want, st.bg).colour
      let what = kind & " " & status & " " & where
      if st.fg != wanted:
        problems.add what & " is " & st.fg & " on " & st.bg & ", not " & wanted
      if st.bg == p.panel:
        if contrastOf(st.fg, st.bg) < StatusMarkFloor:
          problems.add what & " is " & formatFloat(contrastOf(st.fg, st.bg), ffDecimal, 2) &
                       ":1 on the panel"
        if p.mode == dmLight: onPanel.add kind & " " & status
      elif st.fg == want.colour: inc offPanel
    var legends = 0
    for (surface, fixture) in [("agent-harbor-control-center", "populated"),
                               ("agent-harbor-initiatives", "populated"),
                               ("agent-harbor-initiatives", "selected")]:
      for (cols, rows) in [(95, 40), (45, 56), (180, 56)]:
        for mode in [dmDark, dmLight]:
          let m = mountAgentHarborStoryTui(surface, fixture, cols, rows, mode)
          let p = m.canvas.p
          let at = $mode & " " & surface & "/" & fixture & " " & $cols & "x" & $rows
          for panel in m.canvas.root.all("surface"):
            if panel.attr("surface") != "agent-harbor-initiatives": continue
            for row in panel.all("initiative"):
              let where = at & " " & row.attr("initiative")
              let mark = row.first("mark")
              if not mark.isNil and mark.row < m.rows:
                m.checkCell(mark.row, mark.col,
                            p.markOf(parseEnum[InitiativeState](row.attr("state"))),
                            "initiative", row.attr("state"), where, problems, onPanel, offPanel)
              for s in row.all("session"):
                let mk = s.first("mark")
                if mk.isNil or mk.row >= m.rows: continue
                m.checkCell(mk.row, mk.col,
                            p.markOf(parseEnum[SessionAttention](s.attr("attention"))),
                            "session", s.attr("attention"), where, problems, onPanel, offPanel)
              for bar in row.all("milestone-bar"):
                # The segments, cell by cell; the legend's marks follow in the
                # bar's order, one per status present.
                var present: seq[MilestoneStatusClass]
                for seg in bar.all("segment"):
                  let status = parseEnum[MilestoneStatusClass](seg.attr("segment").split(':')[0])
                  present.add status
                  if seg.row >= m.rows: continue
                  for col in seg.col ..< seg.col + seg.width:
                    if status == mscPlanned:
                      inc planned
                      let st = m.canvas.grid.styleAt(seg.row, col)
                      if st.fg != p.trackPlanned:
                        problems.add "segment planned " & where & " is " & st.fg & ", not " &
                                     p.trackPlanned
                    else:
                      m.checkCell(seg.row, col, p.markOf(status), "segment", $status, where,
                                  problems, onPanel, offPanel)
                var marks: seq[AhNode]
                for legend in bar.all("ms-legend"): marks.add legend.all("mark")
                if marks.len != present.len:
                  problems.add "legend " & where & ": " & $marks.len & " marks for " &
                               $present.len & " statuses"
                for i in 0 ..< min(marks.len, present.len):
                  if marks[i].row >= m.rows: continue
                  inc legends
                  m.checkCell(marks[i].row, marks[i].col, p.markOf(present[i]), "legend",
                              $present[i], where, problems, onPanel, offPanel)
          m.dispose()
    for problem in problems: echo "  ", problem
    check problems.len == 0
    # A check that ran on no mark proves nothing: the fixtures put the roles
    # Light changes on the plain panel, leave marks off it in their icon
    # inks, and draw a planned segment and the legends.
    for key in ["session running", "session needs-input", "segment completed",
                "legend completed", "initiative working"]:
      if key notin onPanel: echo "  never on the panel: ", key
      check key in onPanel
    check offPanel > 0
    check planned > 0
    check legends > 0

  test "one ink per status word per ground across WAITING FOR YOU and the Initiatives panel":
    # The tab draws a session's state in two places, its waiting row and its
    # line under its initiative: a word on one ground must be one ink in
    # both, and each must be the rule's ink for that ground.
    var problems: seq[string]
    var both = 0
    for (cols, rows) in [(95, 40), (45, 56), (180, 56)]:
      for mode in [dmDark, dmLight]:
        let m = mount("populated", cols, rows, mode)
        let p = m.canvas.p
        var inks: seq[(string, string, string, string)]   # word, ground, ink, where
        for w in m.view.all("waiting-session"):
          let word = w.first("state-word")
          if word.isNil or word.row >= m.rows: continue
          let st = m.canvas.grid.styleAt(word.row, word.col)
          let attention = parseEnum[SessionAttention](w.attr("waiting-state").replace(' ', '-'))
          problems.add wordProblems(p, attention, st.fg, st.bg,
                                    $mode & " waiting '" & word.attr("state-word") & "'")
          inks.add (word.attr("state-word"), st.bg, st.fg, "waiting")
        for s in m.canvas.root.all("session"):
          let word = s.first("status")
          if word.isNil or word.row >= m.rows: continue
          let st = m.canvas.grid.styleAt(word.row, word.col)
          inks.add (word.attr("status"), st.bg, st.fg, "initiatives")
        for a in inks:
          for b in inks:
            if a[0] == b[0] and a[1] == b[1] and a[2] != b[2]:
              problems.add $mode & " " & $cols & "x" & $rows & ": '" & a[0] & "' on " & a[1] &
                           " is " & a[2] & " in " & a[3] & " and " & b[2] & " in " & b[3]
            if a[3] == "waiting" and b[3] == "initiatives" and a[0] == b[0] and a[1] == b[1]:
              inc both
        m.dispose()
    for problem in problems: echo "  ", problem
    check problems.len == 0
    # `needs input` is drawn on the panel ground in both places.
    check both > 0

  test "the web's session status rules resolve to the palette's words on their grounds":
    # The web does not read the palette: a session's status word takes its
    # colour from `agent_harbor.styl`. Each state's rule must resolve, in
    # each mode, to the ink the palette gives on the grounds the web draws it
    # on: the default rule on the panel, the card band and a popup's
    # surface, the hover rule on `secondary-hover` (a hovered or selected
    # initiative, a hovered waiting row). A mode's value is a design token's
    # name (`colors-ui-…`, or a primitive step such as `colors-warning-800`)
    # or `mix-ink(<token>, <token>, <n>%)`, which `defaults.styl` defines as
    # the palette's `mixInk`.
    let styl = readFile(currentSourcePath().parentDir.parentDir.parentDir /
                        "styles" / "components" / "agent_harbor.styl").splitLines
    proc colourOf(selector: string): string =
      ## The colour of the rule whose selector list holds `selector`.
      for i, line in styl:
        if line.strip(leading = false, chars = {','}) == selector:
          var k = i + 1
          while k < styl.len and styl[k].len > 0 and styl[k][0] != ' ': inc k
          if k < styl.len and styl[k].strip.startsWith("color:"):
            return styl[k].strip["color:".len .. ^1].strip
    let initiativesHover = ".ah-initiative-row:hover "
    let selected = ".ah-initiative-row-selected "
    let waitingHover = ".ah-cc-waiting-row:hover "
    var resolvedRules = 0
    for (cls, attention) in [("needs-input", saNeedsInput), ("running", saRunning),
                             ("failed", saFailed)]:
      let line = ".ah-att-" & cls & " .ah-initiative-session-status"
      let waiting = ".ah-cc-waiting-state.ah-att-" & cls
      for mode in [dmDark, dmLight]:
        let p = ahPalette(mode)
        # (selector, the grounds the web draws it on)
        var rules = @[(line, @[p.panel, p.menu, p.ground]), (waiting, @[p.panel])]
        # The hover rules exist where the 800 step falls under the floor on
        # `secondary-hover`; elsewhere the default rule stands there too.
        let darker = colourOf(initiativesHover & line).len > 0
        if darker:
          rules.add @[(initiativesHover & line, @[p.hover]), (selected & line, @[p.hover]),
                      (waitingHover & waiting, @[p.hover])]
        else:
          rules[0][1].add p.hover
          rules[1][1].add p.hover
        if mode == dmLight:
          # The hover rules are there exactly where Light needs them.
          check darker == (contrastOf(p.statusStep800(pieRoleOf(attention)), p.hover) <
                           StatusTextFloor)
        for (selector, grounds) in rules:
          let value = colourOf(selector)
          check value.startsWith("by-mode(") and value.endsWith(")")
          if not (value.startsWith("by-mode(") and value.endsWith(")")):
            echo "  no by-mode rule for ", selector
            continue
          let names = modeArgs(value["by-mode(".len ..< value.high])
          check names.len == 2
          if names.len != 2: continue
          let hex = resolved(names[ord(mode)], mode)
          check hex.len > 0
          for ground in grounds:
            let wanted = p.initiativeSessionWordColour(attention, ground)
            if hex != wanted:
              echo "  ", $mode, " ", selector, " on ", ground, " is ", hex, ", not ", wanted
            check hex == wanted
            if hex.len > 0 and hex == wanted: inc resolvedRules
    # In each mode: needs input and running, the line's rule on 3 grounds,
    # the waiting row's on 1 and 3 hover rules on 1; failed, the line's rule
    # on 4 grounds and the waiting row's on 2.
    check resolvedRules == 2 * 2 * (3 + 1 + 3) + 2 * (4 + 2)

  test "the web's plain-panel mark rules, planned rule and popup header resolve to the palette":
    # The web does not read the palette. The Initiatives panel's marks on a
    # plain panel row read `--ah-mark-panel-<role>`, which the palette writes
    # into agent_harbor_pie_inks.styl (`markOnPanel`); planned's rule names
    # grey/400 in Light; the popup header's state word names the tokens
    # `popupStateWordColour` resolves to on the popup's default surface.
    let sheet = stylesheet("agent_harbor.styl")
    let inks = stylesheet("agent_harbor_pie_inks.styl")
    proc panelVar(name: string; mode: DesignMode): string =
      ## `--ah-mark-panel-<name>`'s `mode` hex in the generated sheet, or "".
      for line in inks:
        let l = line.strip
        if l.startsWith("--ah-mark-panel-" & name & ":"):
          return byModeOf(l[l.find(':') + 1 .. ^1].strip, mode)
    # The plain row's block: each selector under it and the variable it reads.
    const Plain = ".agent-harbor-initiatives .ah-initiative-row:nth-child(odd)" &
                  ":not(.ah-initiative-row-selected):not(:hover)"
    var rules: seq[(string, string)]   # (selector, variable name)
    var start = -1
    for i, line in sheet:
      if line == Plain: start = i
    check start >= 0
    if start >= 0:
      var pending: seq[string]
      var i = start + 1
      while i < sheet.len and (sheet[i].len == 0 or sheet[i].startsWith(" ")):
        let l = sheet[i]
        if l.startsWith("    background: var(--ah-mark-panel-") and l.endsWith(")"):
          let name = l.strip["background: var(--ah-mark-panel-".len ..< l.strip.high]
          for sel in pending: rules.add (sel, name)
          pending = @[]
        elif l.startsWith("  ") and not l.startsWith("   ") and l.strip.len > 0:
          pending.add l.strip.strip(leading = false, chars = {','})
        inc i
    proc wantedOf(p: AhPalette; selector: string): MarkStyle =
      ## The mark a plain-row selector draws, by the class it names.
      for att in SessionAttention:
        if selector == ".ah-att-" & $att & " .ah-tab-mark": return p.markOf(att)
      for st in InitiativeState:
        if selector == "&.ah-ist-" & $st & " > .ah-initiative-info > .ah-initiative-head > .ah-tab-mark":
          return p.markOf(st)
      for ms in MilestoneStatusClass:
        let cls = case ms
                  of mscInProgress: "in-progress"
                  of mscPartial: "partial"
                  of mscBlocked: "blocked"
                  of mscPlanned: "planned"
                  of mscCompleted: "completed"
                  of mscOther: "other"
        if selector in [".ah-ms-" & cls & " .ah-ms-mark", ".ah-ms-seg.ah-ms-" & cls]:
          return p.markOf(ms)
      MarkStyle()
    var checked = 0
    for mode in [dmDark, dmLight]:
      let p = ahPalette(mode)
      for (selector, name) in rules:
        let want = p.wantedOf(selector)
        check want.colour.len > 0
        if want.colour.len == 0:
          echo "  a plain-row selector this test does not know: ", selector
          continue
        let hex = panelVar(name, mode)
        let wanted = p.markOnPanel(want, p.panel).colour
        if hex != wanted: echo "  ", $mode, " ", selector, " reads ", name, " = ", hex, ", not ", wanted
        check hex == wanted
        check contrastOf(hex, p.panel) >= StatusMarkFloor
        inc checked
    # Every status class the panel draws a mark for has its rule, in both
    # modes: the session dots (needs input, running, queued, failed), the
    # initiative dots (needs input, working, blocked), the legend's and the
    # bar's (completed, in progress, partial, blocked, other).
    check rules.len == 4 + 3 + 2 * 5
    check checked == 2 * rules.len
    # Planned: the last rule that paints it, the segment (the bar's
    # remainder, `trackPlanned`) and the mark (`plannedMark`) apart.
    for mode in [dmDark, dmLight]:
      let p = ahPalette(mode)
      for (selector, wanted) in [(".ah-ms-seg.ah-ms-planned", p.trackPlanned),
                                 (".ah-ms-planned .ah-ms-mark", p.plannedMark)]:
        var value = ""
        for i, line in sheet:
          if line == selector and i + 1 < sheet.len and
             sheet[i + 1].strip.startsWith("background:"):
            value = sheet[i + 1].strip["background:".len .. ^1].strip
        let hex = resolved(byModeOf(value, mode), mode)
        if hex != wanted: echo "  ", $mode, " ", selector, " is ", value, " = ", hex
        check hex == wanted
    check resolved(byModeOf("by-mode(colors-ui-icon-primary-subtle, colors-grey-400)",
                            dmLight), dmLight) == "#727272"
    # The popup header's state word, on the popup's default surface.
    var headers = 0
    for (cls, state) in [("needs-input", isNeedsInput), ("working", isWorking),
                         ("blocked", isBlocked)]:
      var value = ""
      for i, line in sheet:
        if line == ".ah-popup-state-" & cls and i + 1 < sheet.len:
          value = sheet[i + 1].strip["color:".len .. ^1].strip
      for mode in [dmDark, dmLight]:
        let p = ahPalette(mode)
        let hex = resolved(byModeOf(value, mode), mode)
        let wanted = p.popupStateWordColour(state, p.ground)
        if hex != wanted: echo "  ", $mode, " .ah-popup-state-", cls, " is ", value, " = ", hex,
                               ", not ", wanted
        check hex == wanted
        check contrastOf(hex, p.ground) >= StatusTextFloor
        inc headers
    check headers == 6

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
