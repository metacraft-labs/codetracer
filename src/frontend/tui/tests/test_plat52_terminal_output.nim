## test_plat52_terminal_output.nim — PLAT-52, the terminal's Terminal Output
## pane over a REAL session (Tier 1: the runtime and the shell in process, a
## real `replay-server`, real recordings):
##
##   * `terminal_colours` — a program that writes coloured lines: the
##     fragments carry the recorded SGR attributes AS DATA, and the pane paints
##     each run in them (the desktop's palette, literal colours), the future
##     ones muted; a click on a fragment lands at the tick its write was
##     produced, and the source, the stack and the variables agree about where
##     that is; the scrollbar is a SCRUBBER over the whole output — a press at
##     its end shows the LAST line of the output (not of the rows on screen),
##     a drag is monotonic, the current line is marked on the track, and none
##     of it moves the debugger;
##   * `terminal_screen` — a real full-screen program (alternate screen,
##     cursor addressing, erase, scroll regions): the pane offers and opens the
##     SCREEN view, which shows the shared model's screen at the current tick;
##     its built-in scrubber is REAL-TIME — a drag moves the debugger to each
##     write it crosses, before any release (the user, 2026-10-06); Left /
##     Right step a write; the view the user chose is remembered for the
##     recording across sessions;
##   * the report leaf is gone: the terminal's capability draws the pane.
##
## Everything through the product's own entry points (`handleToken` with the
## bytes a terminal sends, `applyOutcome` as the shipped loop runs it,
## `shellScreenOf` for the frame). No mocks: the state directory is a scratch
## one (`CODETRACER_TUI_LAYOUT_DIR`), the engine and the recordings are real.

import std/[os, strutils, unicode, unittest]

import isonim/core/[signals, computation]

import headless_session
import store/types
import viewmodels/terminal_output_vm
import viewmodels/scrollbar_scrubber
import headless_app/layout_model
import view_vocabulary/pane_views
import ../../../common/view_vocabulary

import ../app/runtime
import ../app/tui_app
import ../app/theme/capabilities
import ../app/theme/roles
import ../app/views/shell
import ../app/views/styled_row
import ../app/layout/profile
import ../host/tui_session
import ./fixtures/fixture_provider

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 105

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 160
  Rows = 48

proc pythonSpec(name: string): FixtureSpec =
  FixtureSpec(
    name: name, program: "test-programs/" & name & "/main.py",
    recorder: "codetracer-python-recorder",
    probe: FixtureProbe(kind: pkPythonRecorder),
    buildHint: "Install codetracer_python_recorder into the interpreter " &
               "`ct` will use (the repo's .python-recorder-venv, or " &
               "$CODETRACER_PYTHON_INTERPRETER).",
    blockedOn: "")

proc newRuntime(): TuiRuntime =
  let caps = resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"), initCapabilityFlags())
  result = newTuiRuntime(newTuiApp(), caps, Cols, Rows)
  discard result.enableLayoutBinding()

proc sgr(code, row, col: int; release = false; motion = false): string =
  "\x1b[<" & $(code + (if motion: 32 else: 0)) & ";" & $(col + 1) & ";" &
    $(row + 1) & (if release: "m" else: "M")

proc send(s: TuiSession; rt: TuiRuntime; token: string) =
  let outcome = rt.handleToken(token, 0)
  s.applyOutcome(rt, outcome)

proc click(s: TuiSession; rt: TuiRuntime; row, col: int) =
  s.send(rt, sgr(0, row, col))
  s.send(rt, sgr(0, row, col, release = true))

proc cellOf(line, needle: string): int =
  let at = line.find(needle)
  if at < 0: -1 else: line[0 ..< at].runeLen

proc open(path: string): (TuiRuntime, TuiSession) =
  let rt = newRuntime()
  let s = openTuiSession(path, viewportHeight = Rows - 8)
  s.header(rt)
  s.learnExtent()
  s.refresh(rt)
  (rt, s)

proc showTerminalOutput(s: TuiSession; rt: TuiRuntime): bool =
  ## Activate the pane's tab where the strip draws it.
  let rows = rt.shellScreenOf().rows
  for r, line in rows:
    let c = line.cellOf(" Terminal Output ")
    if c >= 0 and r > 0 and line.contains(" Event Log "):
      s.click(rt, r, c + 2)
      return rt.shellScreenOf().geometry.projection.regions.len > 0
  false

proc terminalArea(rt: TuiRuntime): CellArea =
  let screen = rt.shellScreenOf()
  for region in screen.geometry.projection.regions:
    if region.pane == paneTerminalOutput:
      return region.area
  CellArea()

proc paneRows(rt: TuiRuntime): seq[string] =
  ## The pane's rows as painted, below its strip, without the track column.
  let a = rt.terminalArea()
  let rows = rt.shellScreenOf().rows
  for r in a.row + 1 ..< a.row + a.height:
    if r < rows.len:
      result.add rows[r].runeSubStr(a.col, max(0, a.width - 1))

proc rowWith(rt: TuiRuntime; needle: string): int =
  let rows = rt.shellScreenOf().rows
  for r, line in rows:
    if line.contains(needle): return r
  -1

proc styleAtText(rt: TuiRuntime; row: int; needle: string): CellStyle =
  ## The style of the first cell of `needle` on screen row `row`.
  let screen = rt.shellScreenOf()
  let col = screen.rows[row].cellOf(needle)
  var c = 0
  for span in screen.styledRows[row]:
    let w = span.text.runeLen
    if col >= c and col < c + w:
      return span.style
    c += w
  CellStyle()

let colours = resolveFixture(pythonSpec("terminal_colours"))
let screenRec = resolveFixture(pythonSpec("terminal_screen"))

suite "PLAT-52: the terminal draws the Terminal Output pane":

  test "the report leaf is gone: the terminal's capability draws it":
    ck terminalCapability().canDraw(paneTerminalOutput)

  test "the fragments carry the recorded SGR attributes, as data":
    require colours.outcome == foRecorded
    let (rt, s) = open(colours.tracePath)
    defer: s.close()
    let vm = s.session.session.terminalOutputVM
    let lines = vm.lines.val
    checkpoint($lines.len & " lines")
    ck lines.len == 129
    ck lines[0].lineText == "red plain bold green"
    let f0 = lines[0].fragments
    ck f0.len == 3
    ck f0[0].text == "red" and f0[0].style.fg == termIndexed(1)
    ck f0[1].text == " plain " and f0[1].style == TermAttrs()
    ck f0[2].style.bold and f0[2].style.fg == termIndexed(2)
    ck lines[1].lineText == "two writes, blue ground"
    ck lines[1].fragments.len == 2
    ck lines[1].fragments[1].style.bg == termIndexed(4)
    ck lines[1].fragments[0].eventIndex != lines[1].fragments[1].eventIndex
    let f3 = lines[3].fragments
    ck f3[0].style.fg == termIndexed(208)
    ck f3[2].style.fg == termRgbColor(0, 128, 128)
    ck lines[4].lineText == "col     umns    by      tab"
    ck lines[5].lineText == ""
    ck lines[6].lineText == "one write" and lines[7].lineText == "ends two lines"
    ck lines[^1].lineText == "done"
    ck not vm.screenOffered.val

  test "the pane paints each run in its attributes; the future is muted":
    require colours.outcome == foRecorded
    let (rt, s) = open(colours.tracePath)
    defer: s.close()
    ck s.showTerminalOutput(rt)
    ck rt.app.terminalOutput.loaded
    # At the program's entry nothing has been written: every line is future.
    var row = rt.rowWith("red plain bold green")
    ck row > 0
    ck rt.styleAtText(row, "red").role == srChromeMuted
    # Go to the end: everything is past, drawn as written.
    s.send(rt, "G")
    rt.app.terminalOutput.follow = false
    rt.app.terminalOutput.scrollTop = 0
    row = rt.rowWith("red plain bold green")
    ck row > 0
    let red = rt.styleAtText(row, "red")
    checkpoint("red: " & describe(red))
    ck red.fg == "#bb0000"
    let green = rt.styleAtText(row, "bold green")
    ck green.fg == "#00bb00" and green.bold
    let blue = rt.styleAtText(rt.rowWith("blue ground"), "blue ground")
    ck blue.bg == "#0000bb"
    let teal = rt.styleAtText(rt.rowWith("truecolor teal"), "truecolor teal")
    ck teal.fg == "#008080"

  test "a click on a fragment goes to its write; source, stack, variables agree":
    require colours.outcome == foRecorded
    let (rt, s) = open(colours.tracePath)
    defer: s.close()
    ck s.showTerminalOutput(rt)
    let vm = s.session.session.terminalOutputVM
    # The line "row  10 ###..." — written by `print(row(i))` with i == 10.
    rt.app.terminalOutput.follow = false
    rt.app.terminalOutput.scrollTop = 10
    let row = rt.rowWith("row  10 ")
    ck row > 0
    let col = rt.shellScreenOf().rows[row].cellOf("row  10 ")
    let before = s.session.getCurrentRRTicks()
    s.click(rt, row, col + 1)
    var write = -1
    for l in vm.lines.val:
      if l.lineText.startsWith("row  10 "):
        write = l.fragments[0].eventIndex
    ck write >= 0
    let ev = vm.events.val[write]
    let after = s.session.getCurrentRRTicks()
    checkpoint("before " & $before & " after " & $after & " write tick " &
               $ev.rrTicks)
    ck after == ev.rrTicks
    ck after != before
    # The source: the line the write was recorded at (the engine's own
    # location for it — `highLevelPath:highLevelLine`).
    ck s.session.getCurrentLine() == ev.line
    ck s.session.getCurrentFile().endsWith("terminal_colours/main.py")
    ck s.session.getCurrentFile() == ev.path
    # The stack: its innermost frame is at that line, and the calls that
    # produced line 10 — `row` called from `main` — are on it.
    ck rt.app.callStack.frames.len > 2
    ck rt.app.callStack.frames[0].line == ev.line
    var names: seq[string] = @[]
    for f in rt.app.callStack.frames: names.add f.name
    checkpoint("stack " & $names)
    ck "row" in names and "main" in names
    # The variables: read at this stop.
    ck rt.app.variables.tickLabel == "tick " & $ev.rrTicks
    # And the pane follows: the clicked line's write is active.
    ck rt.app.terminalOutput.currentTicks == ev.rrTicks

  test "the scrollbar scrubs the WHOLE output and never moves the debugger":
    require colours.outcome == foRecorded
    let (rt, s) = open(colours.tracePath)
    defer: s.close()
    ck s.showTerminalOutput(rt)
    let a = rt.terminalArea()
    let geo = terminalPaneGeometry(rt.app.terminalOutput, a)
    checkpoint("content rows " & $geo.contentRows & ", lines " &
               $rt.app.terminalOutput.lines.len)
    ck geo.contentRows > 5
    ck geo.contentRows < rt.app.terminalOutput.lines.len
    ck geo.trackCol == a.col + a.width - 1
    # Away from the entry (where the first write's jump would land too), so
    # a scrub that moved the debugger anywhere is seen.
    s.send(rt, "G")
    let tick = s.session.getCurrentRRTicks()
    # A press at the track's END shows the LAST line of the whole output.
    s.click(rt, geo.contentTop + geo.contentRows - 1, geo.trackCol)
    ck not rt.app.terminalOutput.follow
    ck rt.paneRows().join("\n").contains("done")
    # At its START, the first.
    s.click(rt, geo.contentTop, geo.trackCol)
    ck rt.paneRows().join("\n").contains("red plain bold green")
    # A drag from the thumb down the track: the view follows, monotonically.
    var tops: seq[int] = @[]
    s.send(rt, sgr(0, geo.contentTop, geo.trackCol))
    for r in geo.contentTop .. geo.contentTop + geo.contentRows - 1:
      s.send(rt, sgr(0, r, geo.trackCol, motion = true))
      tops.add rt.app.terminalOutput.scrollTop
    s.send(rt, sgr(0, geo.contentTop + geo.contentRows - 1, geo.trackCol,
                   release = true))
    var mono = true
    for i in 1 ..< tops.len:
      if tops[i] < tops[i - 1]: mono = false
    ck mono
    ck tops[^1] == rt.app.terminalOutput.lines.len - geo.contentRows
    # None of it moved the debugger.
    ck s.session.getCurrentRRTicks() == tick

  test "the wheel scrolls the lines; a right-click opens no menu, as on the desktop":
    require colours.outcome == foRecorded
    let (rt, s) = open(colours.tracePath)
    defer: s.close()
    ck s.showTerminalOutput(rt)
    let a = rt.terminalArea()
    let geo = terminalPaneGeometry(rt.app.terminalOutput, a)
    let top0 = rt.app.terminalOutput.visibleTop(geo.contentRows)
    # Wheel down: three lines (SGR button 65).
    s.send(rt, sgr(65, geo.contentTop + 2, geo.textCol + 3))
    ck rt.app.terminalOutput.visibleTop(geo.contentRows) == top0 + 3
    ck not rt.app.terminalOutput.follow
    # The desktop opens no menu on a line (measured: `plat52-terminal
    # .electron.json` `lineContextMenu` is empty); neither does the terminal.
    let row = rt.rowWith("row   0 ")
    ck row > 0
    let tick = s.session.getCurrentRRTicks()
    s.send(rt, sgr(2, row, rt.shellScreenOf().rows[row].cellOf("row   0 ")))
    s.send(rt, sgr(2, row, rt.shellScreenOf().rows[row].cellOf("row   0 "),
                   release = true))
    ck not rt.app.contextMenu.open
    ck s.session.getCurrentRRTicks() == tick

  test "the current line is marked on the track":
    require colours.outcome == foRecorded
    let (rt, s) = open(colours.tracePath)
    defer: s.close()
    ck s.showTerminalOutput(rt)
    s.send(rt, "G")
    let a = rt.terminalArea()
    let m = rt.app.terminalOutput
    let geo = terminalPaneGeometry(m, a)
    ck m.currentLine == m.lines.len - 1
    let sm = m.scrubberOf(geo.contentRows)
    let markRow = geo.contentTop + min(geo.contentRows - 1,
      int(sm.currentFraction * float(geo.contentRows)))
    let screen = rt.shellScreenOf()
    var c = 0
    var style = CellStyle()
    for span in screen.styledRows[markRow]:
      let w = span.text.runeLen
      if geo.trackCol >= c and geo.trackCol < c + w:
        style = span.style
      c += w
    ck style.role == srScrubberMark

  test "the vocabulary view lists the lines, the current one highlighted":
    require colours.outcome == foRecorded
    let (rt, s) = open(colours.tracePath)
    defer: s.close()
    let vm = s.session.session.terminalOutputVM
    var pv = paneView(paneTerminalOutput, vm, Budget(name: "plat52", lines: 1, cells: 80), "terminal")
    ck pv.report.len == 0
    ck pv.root.kind == pkList
    ck pv.root.options.len == 129
    ck pv.root.options[0].label == "red plain bold green"
    ck pv.root.options[^1].label == "done"
    s.send(rt, "G")
    pv = paneView(paneTerminalOutput, vm, Budget(name: "plat52", lines: 1, cells: 80), "terminal")
    ck pv.root.highlight == 128

suite "PLAT-52: a full-screen program's SCREEN, and its scrubber":

  test "the screen view is offered, opens, and shows the model's screen":
    require screenRec.outcome == foRecorded
    putEnv("CODETRACER_TUI_LAYOUT_DIR", getTempDir() / "plat52-tui-state-1")
    removeDir(getTempDir() / "plat52-tui-state-1")
    let (rt, s) = open(screenRec.tracePath)
    defer: s.close()
    let vm = s.session.session.terminalOutputVM
    ck vm.screenOffered.val
    ck vm.view.val == tvScreen
    ck vm.screen.marks.len >= 3
    ck s.showTerminalOutput(rt)
    ck rt.app.terminalOutput.screenShown
    # Seek to the end: the program has left the alternate screen.
    s.send(rt, "G")
    var text = rt.paneRows().join("\n")
    ck text.contains("dashboard finished: 6 tasks, 30 frames")
    # Step back with Left (the pane is focused by the click): the write
    # before the summary line left the alternate screen (the main screen is
    # empty); the one before it is the dashboard's last frame.
    ck rt.focus.focusPaneKind(paneTerminalOutput)
    let n = vm.screen.writeCount
    let last = rt.app.terminalOutput.shownWrite
    ck last == n - 1
    s.send(rt, "\x1b[D")
    ck rt.app.terminalOutput.shownWrite == last - 1
    ck s.session.getCurrentRRTicks() == vm.screen.writes[last - 1].rrTicks
    s.send(rt, "\x1b[D")
    let shown = rt.app.terminalOutput.shownWrite
    ck shown == last - 2
    ck s.session.getCurrentRRTicks() == vm.screen.writes[shown].rrTicks
    text = rt.paneRows().join("\n")
    ck text.contains("dashboard (second half)")
    ck not text.contains("dashboard finished")
    # The rows drawn are the shared model's screen at that write, cell for
    # cell, over every row the pane has room for.
    let model = vm.screen.screenAfter(shown)
    let a = rt.terminalArea()
    let geo = terminalPaneGeometry(rt.app.terminalOutput, a)
    let screenRows = rt.shellScreenOf().rows
    var agree, compared = 0
    for r in 0 ..< min(model.rows, geo.contentRows) - 1:
      let drawn = screenRows[geo.contentTop + r].runeSubStr(a.col, a.width)
      let want = model.screenRowText(r).runeSubStr(0, a.width)
      inc compared
      if drawn.strip(leading = false) == want.strip(leading = false):
        inc agree
      else:
        checkpoint("row " & $r & " drawn '" & drawn & "' want '" & want & "'")
    checkpoint("rows agreeing: " & $agree & " of " & $compared)
    ck compared >= 10
    ck agree == compared

  test "the screen's scrubber is REAL-TIME: a drag moves the debugger live":
    require screenRec.outcome == foRecorded
    putEnv("CODETRACER_TUI_LAYOUT_DIR", getTempDir() / "plat52-tui-state-2")
    let (rt, s) = open(screenRec.tracePath)
    defer: s.close()
    ck s.showTerminalOutput(rt)
    let vm = s.session.session.terminalOutputVM
    let a = rt.terminalArea()
    let geo = terminalPaneGeometry(rt.app.terminalOutput, a)
    ck geo.screenTrackRow > geo.contentTop
    let n = vm.screen.writeCount
    proc writeAtCol(col: int): int =
      writeAtFraction(n, fractionAt(col - geo.screenTrackCol,
                                    geo.screenTrackWidth))
    # The press: the debugger goes to the write under it at once.
    let c0 = geo.screenTrackCol + 1
    s.send(rt, sgr(0, geo.screenTrackRow, c0))
    ck rt.app.terminalOutput.previewing
    ck s.session.getCurrentRRTicks() == vm.screen.writes[writeAtCol(c0)].rrTicks
    # DURING the drag — no release yet — every write crossed moves it.
    var ticks: seq[uint64] = @[]
    let quarter = geo.screenTrackCol + geo.screenTrackWidth div 4
    let mid = geo.screenTrackCol + geo.screenTrackWidth div 2
    for col in [quarter, mid]:
      s.send(rt, sgr(0, geo.screenTrackRow, col, motion = true))
      ck rt.app.terminalOutput.previewing
      let w = writeAtCol(col)
      ck s.session.getCurrentRRTicks() == vm.screen.writes[w].rrTicks
      ck rt.app.terminalOutput.shownWrite >= w
      ticks.add s.session.getCurrentRRTicks()
    ck ticks[0] < ticks[1]
    # The other panes follow the drag (the header's tick is the stop's).
    ck rt.app.tick == int(ticks[1])
    # The release ends the drag where it is.
    s.send(rt, sgr(0, geo.screenTrackRow, mid, release = true))
    ck not rt.app.terminalOutput.previewing
    ck s.session.getCurrentRRTicks() == ticks[1]
    let shown = rt.app.terminalOutput.shownWrite
    ck vm.screen.writes[shown].rrTicks == ticks[1]

  test "the view chosen is remembered for the recording":
    require screenRec.outcome == foRecorded
    let state = getTempDir() / "plat52-tui-state-3"
    removeDir(state)
    putEnv("CODETRACER_TUI_LAYOUT_DIR", state)
    block:
      let (rt, s) = open(screenRec.tracePath)
      defer: s.close()
      ck s.showTerminalOutput(rt)
      let a = rt.terminalArea()
      let geo = terminalPaneGeometry(rt.app.terminalOutput, a)
      s.click(rt, geo.headerRow, geo.linesToggle.col + 1)
      ck rt.app.terminalOutput.view == tvLines
      ck fileExists(state / "terminal-views.json")
      ck readFile(state / "terminal-views.json").contains("\"lines\"")
    block:
      let (rt, s) = open(screenRec.tracePath)
      defer: s.close()
      ck s.session.session.terminalOutputVM.view.val == tvLines
      ck s.showTerminalOutput(rt)
      ck not rt.app.terminalOutput.screenShown
      # `v` toggles it back.
      ck rt.focus.focusPaneKind(paneTerminalOutput)
      s.send(rt, "v")
      ck rt.app.terminalOutput.view == tvScreen
    removeDir(state)

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
