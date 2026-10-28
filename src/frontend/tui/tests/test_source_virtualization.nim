## test_source_virtualization.nim — CTUI-5, Tier 1, over a real provider.
##
## ## What this suite establishes
##
## CTUI-5: "on a >10,000-line file: asserts the number of lines materialized
## stays within window+overscan across a long scroll, and that RSS does not
## grow monotonically. This is the only test that can catch the memory target
## regressing before CTUI-14 measures it."
##
## Three bounds, all asserted rather than described:
##
##   1. **`SourceVM` holds at most `viewport + 2 * overscan` lines**, at EVERY
##      one of the scroll's stops. `trimToWindow` runs before every request, so
##      this is a property of the seam CTUI-4 built; the assertion here is that
##      the PANE does not defeat it — a pane that accumulated its own copy
##      would still see a trimmed VM.
##   2. **The pane materializes at most one row of source per body row.**
##      `SourcePaneScreen.materializedLines` counts what the frame read out of
##      the model, so a pane that walked the whole file to find the visible
##      part would report a number larger than the pane is tall.
##   3. **The highlighter's cache is bounded.** The cache key includes the
##      WINDOW, so a long scroll produces one entry per window visited; an
##      unbounded cache would make "the pane holds only its window" true of the
##      text and false of the process. `MaxCachedWindows` caps it and this
##      suite asserts the cap holds across 300 windows.
##
## …and then RSS, which is the milestone's own instrument and is reported with
## its limits stated rather than presented as a memory measurement it is not.
##
## ## WHERE THE 12 000-LINE FILE COMES FROM, AND WHY IT IS NOT A FIXTURE
##
## No recorded fixture in this campaign's corpus has a file that long — `calc`
## is 116 lines and `noir_space_ship`'s `main.nr` is 38. So this suite writes
## one, into a trace folder's `files/` payload at the path
## `ct/trace/ctfs_sources.safePayloadPath` puts it, and reads it back through
## the PRODUCTION `SourceProvider` (`spkCtfsMaterialized`) — the same code path
## a `.ct` container's unpacked sources take. The recorded path is absolute and
## does not exist on any machine running this suite, and the provider is built
## with `allowWorkingTree = false`, so the payload is the only thing that can
## answer.
##
## The STORE, the `EditorVM` and the `SourceVM` are a real
## `HeadlessDebugSession` over a real `replay-server` on the `calc` fixture.
## `store.updateDebuggerPosition` — the production call
## `headless_session.updatePositionFromCompleteMove` makes on every
## `ct/complete-move` event — is what points that session's `SourceVM` at the
## large file. Nothing here is mocked: there is no `MockBackendService`, and
## the only synthetic thing in the suite is the CONTENT of a file, which is the
## subject rather than the instrument.
##
## ## WHY THIS FILE IS NOT UNDER `app/tests/`
##
## Same reason as `test_source_stepping_forward_backward.nim`: `app/tests/` is
## walked by `tests/test_tui_facade_boundary.nim`, which forbids
## `viewmodel/headless_session`.
##
## ## M73 (#840): THE WINDOW MOVES UNDER THE USER'S INPUT, NOT ONLY UNDER A STOP
##
## The CTUI-5 suite below scrolls by calling `SourceVM.scrollTo` itself, so it
## could not see that nothing a USER does reached that call: in Debug mode the
## pane drew `SourceVM`'s window and only `followExecutionPointer` (after a
## stop) moved it. The wheel was routed to the Call Trace, the Event Log, Find
## in Files and the Terminal Output only; `j`/`k`, `Ctrl+d`/`Ctrl+u` and `.`
## answered for the Call Trace and the Terminal Output only; the caret lived in
## the read-only document (`runtime.debugBuffer`), whose own window the Debug
## pane does not draw, so a caret moved below the last row left the screen;
## and the pane had no vertical bar (Pxor-Bugs M73, codetracer#840).
##
## So the M73 suite drives a real `TuiSession` (a real `replay-server` on the
## `calc` recording, whose 116-line `main.py` is longer than the pane) through
## the product's own entry points only: `handleToken` with the bytes a
## terminal sends — SGR-1006 wheel reports over the editor, keys, clicks — and
## `applyOutcome` as `main.interactive` runs it. Every expectation is read off
## the painted frame (`shellScreenOf`): the first line number the gutter shows,
## the execution line, and the vertical bar's thumb in the pane's last column
## (Scrollbar-Scrubbers.md §4, §6). Specs: CodeTracer-TUI.md §4.4 (the wheel
## "scrolls the pane beneath the pointer ... without requiring pane focus"),
## §4.2 Source Navigation (scroll "without moving execution pointer"; `.`
## "Reset source scroll so the current execution pointer is centered"), and
## Editor-Pane.md § The caret in a read-only editor.
##
## ## Templates, not procs, for anything that calls `check`

import std/[os, strutils, tables, unittest]
from std/unicode import runeSubStr, runeLen, toRunes, `$`

import isonim/core/[signals, computation]
import isonim/viewmodel
import isonim_tui

import headless_session
import store/replay_data_store
import viewmodels/source_vm
import sdk/source_provider

import ../app/source_binding
import ../app/runtime
import ../app/tui_app
import ../app/theme/capabilities
import ../app/theme/roles
import ../app/views/shell
import ../app/views/styled_row
import ../host/tui_session
from codetracer_embed import BaseKeymap, BaseSource
import ./fixtures/fixture_provider
import ../../gpui/tests/process_meter
  # `residentKb`: the CURRENT resident set on Linux (statm x the real page
  # size) and macOS (task_info), and a named failure on any other host.

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count.
const ExpectedAssertions = 82

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  FixtureName = "calc"
  BigFileLines = 12_000
    ## ">10,000-line file", with room to spare. Each line names its own number,
    ## so an off-by-one in the window arithmetic shows up as the wrong string
    ## rather than as text that merely looks plausible.
  RecordedBigPath = "/opt/ctui5/virtualization/huge_module.py"
    ## An ABSOLUTE recorded path that exists on no machine running this suite,
    ## so the provider must resolve through the payload rather than falling
    ## through to a working-tree read that would succeed here and nowhere else.
    ## `.py` so the LEXICAL highlighter runs — the tree-sitter path on a
    ## 12 000-line window would measure the parser rather than the pane.
  PaneWidth = 90
  PaneHeight = 46
    ## The Ultra-wide profile's `editor` rectangle at 200x60, from CTUI-3's
    ## measured table: `editor (40,1 90x46)`. The tallest pane this campaign
    ## produces, so the bound below is asserted at its worst case.
  ViewportLines = PaneHeight - 1
  Overscan = 8
  MaxHeldLines = ViewportLines + 2 * Overscan
    ## `SourceVM`'s contract, spelled out: the viewport plus overscan on each
    ## side. Asserted as an upper bound at every stop of the scroll.
  ScrollStops = 150
  ScrollStride = BigFileLines div ScrollStops
    ## 80 lines per stop, which is larger than the window — so every stop is a
    ## fresh window and a fresh fetch, which is the case that would expose an
    ## accumulating VM. A stride smaller than the window would be served from
    ## the held range and would prove nothing about trimming.
  RssSampleEvery = 15
  RssGrowthCapKb = 24 * 1024
    ## 24 MB. Stated as a CEILING on the growth across the scroll rather than
    ## as the memory target: CTUI-14 owns the < 30 MB steady-state number and
    ## measures it on the APP. What this suite can say is that scrolling a
    ## 12 000-line file twice does not add tens of megabytes, which is what a
    ## pane that stopped virtualizing would do.

var
  examinedFixtures = 0
  verifiedFixtures = 0
  skippedFixtures = 0

proc bigLineText(line: int): string =
  ## Line `line` of the synthetic file. Real Python, so the lexical highlighter
  ## has something to classify, and self-describing so a wrong line is visible
  ## as a wrong number rather than as plausible text.
  "    value_" & $line & " = compute(" & $line & ")  # line " & $line &
    " of " & $BigFileLines

proc writeBigPayload(root: string): string =
  ## A trace folder holding the large file, at the payload path the WRITER
  ## chooses. Returns the trace folder.
  let traceDir = root / "trace"
  var text = newStringOfCap(BigFileLines * 64)
  for line in 1 .. BigFileLines:
    text.add bigLineText(line)
    text.add '\n'
  let payload = traceDir / "files" / RecordedBigPath[1 .. ^1]
  createDir(payload.parentDir)
  writeFile(payload, text)
  traceDir

type VHarness = object
  session: HeadlessDebugSession
  vm: SourceVM
  provider: SourceProvider
  cache: HighlighterCache
  root: string

proc openHarness(tracePath: string): VHarness =
  let root = getTempDir() / ("ctui5-virt-" & $getCurrentProcessId())
  removeDir(root)
  createDir(root)
  let bigTrace = writeBigPayload(root)
  let session = newHeadlessDebugSession(tracePath, fixture_provider.findReplayServer())
  let vm = createSourceVM(session.session.store, session.session.editorVM)
  vm.setOverscan(Overscan)
  vm.setViewport(vm.viewport.withRows(ViewportLines))
  VHarness(
    session: session,
    vm: vm,
    provider: newCtfsSourceProvider(bigTrace, allowWorkingTree = false),
    cache: newHighlighterCache(),
    root: root)

proc closeHarness(h: VHarness) =
  h.vm.dispose()
  h.session.close()
  removeDir(h.root)

proc serveOne(h: VHarness; request: SourceLineRequest): SourceFetch =
  result = SourceFetch(status: sfsProviderUnavailable,
                       detail: "the provider callback never ran")
  var captured = result
  h.provider.fetch(request, proc(fetch: SourceFetch) = captured = fetch)
  drainSourceCallbacks()
  result = captured

proc fillWindow(h: VHarness): int =
  ## Serve everything the window lacks; return how many LINES were fetched.
  for request in h.vm.requestMissing():
    let fetch = h.serveOne(request)
    discard h.session.session.store.applySourceFetch(h.vm, fetch)
    result += fetch.lines.len

proc paneModel(h: VHarness): SourcePaneModel =
  sourcePaneModelFor(
    h.vm, h.session.session.store.degraded.sourceAvailability.val)

proc isStrictlyIncreasing(samples: seq[int]): bool =
  for i in 1 ..< samples.len:
    if samples[i] <= samples[i - 1]:
      return false
  samples.len >= 2

# ---------------------------------------------------------------------------
# M73 (#840): the Debug-mode source pane moves under the user's input
# ---------------------------------------------------------------------------

const
  M73Cols = 160
  M73Rows = 48
    ## The terminal PLAT-51's scrubber suite uses: the `calc` recording's
    ## 116-line `main.py` is several times taller than the editor here.
  WheelDown = 65
  WheelUp = 64
    ## The SGR-1006 button codes a terminal writes for one wheel notch.
  WheelRows = 3
    ## Rows one notch scrolls — the call trace's, the event log's and the
    ## terminal output's, the common terminal default.
  CalcSource = "test-programs/calc/main.py"

proc m73Runtime(): TuiRuntime =
  let caps = resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"), initCapabilityFlags())
  result = newTuiRuntime(newTuiApp(), caps, M73Cols, M73Rows)
  discard result.enableLayoutBinding()

proc m73Open(path: string): (TuiRuntime, TuiSession) =
  ## What `main.interactive` does: open, name the recording (which also hands
  ## the runtime the reader its read-only document is opened with), learn the
  ## extent, refresh — and then give `SourceVM` the PANE's height, measured
  ## off the laid-out shell, and refresh again.
  let rt = m73Runtime()
  let s = openTuiSession(path, viewportHeight = M73Rows - 8)
  s.header(rt)
  s.learnExtent()
  s.refresh(rt)
  s.setViewportHeight(max(1, rt.sourcePaneRows()))
  s.refresh(rt)
  # And what its loop does once the first frame measured the editor's width:
  # a horizontal bar (PLAT-70) takes a row from the window
  # (`runtime.editorBarShown`), so the window is given the rows that remain.
  discard rt.shellScreenOf()
  s.setViewportHeight(max(1, rt.sourcePaneRows()))
  s.refresh(rt)
  (rt, s)

proc m73Send(s: TuiSession; rt: TuiRuntime; token: string) =
  ## One token, as the shipped loop handles it.
  let outcome = rt.handleToken(token, 0)
  s.applyOutcome(rt, outcome)

proc m73Sgr(code, row, col: int; release = false): string =
  "\x1b[<" & $code & ";" & $(col + 1) & ";" & $(row + 1) &
    (if release: "m" else: "M")

proc m73Click(s: TuiSession; rt: TuiRuntime; row, col: int) =
  s.m73Send(rt, m73Sgr(0, row, col))
  s.m73Send(rt, m73Sgr(0, row, col, release = true))

proc editorArea(rt: TuiRuntime): CellArea =
  ## The editor's rectangle, from its strip's row — what `shell.paintPane`
  ## hands the pane's painter (its first row is covered by the strip).
  let screen = rt.shellScreenOf()
  for region in screen.geometry.projection.regions:
    if region.pane == paneEditor:
      let frame = paneFrame(region.area, screen.geometry.body)
      return CellArea(col: region.area.col, row: region.area.row,
                      width: frame.box.width, height: frame.box.height)
  CellArea()

proc gutterNumber(row: string; col, cells: int): int =
  ## The line number a gutter shows, or 0 for a row with none.
  var digits = ""
  for ch in row.runeSubStr(col, cells).toRunes:
    let c = $ch
    if c.len == 1 and c[0] in {'0' .. '9'}:
      digits.add c
    elif digits.len > 0:
      break
  if digits.len == 0: 0 else: parseInt(digits)

type PaintedEditor = object
  ## What the editor shows on the frame, read back off the painted cells.
  firstLine: int
    ## The line number on the editor's first body row.
  firstRow: int
    ## The screen row it is painted on.
  lines: seq[int]
    ## Every body row's line number from the first, top to bottom (0 for a
    ## row with none — the horizontal bar's row, past the end of the file).
  firstText: string
    ## The cells right of the gutter on the first body row.
  thumbRows: seq[int]
    ## The rows of the pane's LAST column painted in the scrubber thumb's
    ## role — the vertical bar (Scrollbar-Scrubbers.md §4).

proc painted(rt: TuiRuntime): PaintedEditor =
  let a = rt.editorArea()
  let screen = rt.shellScreenOf()
  let gutter = min(a.width, rt.app.source.paneGutterWidth())
  let lastCol = a.col + a.width - 1
  for r in a.row + 1 ..< a.row + a.height:
    if r >= screen.rows.len: break
    let n = gutterNumber(screen.rows[r], a.col, gutter)
    if n > 0 and result.firstLine == 0:
      result.firstLine = n
      result.firstRow = r
      result.firstText = screen.rows[r].runeSubStr(a.col + gutter,
                                                   max(0, a.width - gutter))
    if result.firstLine > 0 and n > 0:
      result.lines.add n
    # The last column's cell, found by walking the styled spans.
    var c = 0
    for span in screen.styledRows[r]:
      let w = span.text.runeLen
      if lastCol >= c and lastCol < c + w:
        if span.style.role.isScrollbarThumbRole:
          result.thumbRows.add r
        break
      c += w

proc calcLine(n: int): string =
  readFile(CalcSource).splitLines()[n - 1]

proc showsLine(p: PaintedEditor; n: int): bool =
  ## Whether the first body row carries line `n`'s text — its first cells,
  ## which no inline value and no overflow marker covers.
  let want = calcLine(n)
  let head = want[0 ..< min(want.len, 12)]
  head.strip.len == 0 or p.firstText.startsWith(head)

let m73Recording = resolveFixture(FixtureName)

suite "M73 (#840): the Debug-mode source pane moves under the user's input":

  test "wheel, j/k, the caret, Ctrl+d/Ctrl+u and `.` move the painted window; the execution line stays":
    require m73Recording.outcome == foRecorded
    putEnv("CODETRACER_TUI_LAYOUT_DIR",
           getTempDir() / ("m73-source-" & $getCurrentProcessId()))
    let (rt, s) = m73Open(m73Recording.tracePath)
    defer: s.close()

    # Into the program first, with F10 (step over), so the execution line is
    # well inside the file: `.` then has something to centre that the top of
    # the file would not clamp away.
    for _ in 0 ..< 60:
      if rt.app.source.executionLine >= 60: break
      s.m73Send(rt, "\x1b[21~")

    let rows = rt.sourcePaneRows()
    let total = rt.app.source.totalLineCount
    let exec0 = rt.app.source.executionLine
    let tick0 = s.session.getCurrentRRTicks()
    let start = rt.painted()
    echo "M73: pane rows " & $rows & ", file " & $total & " line(s), " &
         "execution line " & $exec0 & ", first painted line " &
         $start.firstLine & ", focus " & $rt.focus.focusedPane()
    # The positive control: the file IS longer than the pane, the pane paints
    # its window, and the execution line is on it.
    ck total >= 116
    ck rows >= 10 and total > rows + 12 * WheelRows
    ck start.firstLine >= 1
    ck exec0 >= start.firstLine and exec0 < start.firstLine + rows
    ck start.showsLine(start.firstLine)

    # ---- 1. A wheel notch DOWN over the editor's body, editor unfocused ----
    let a = rt.editorArea()
    let focusBefore = rt.focus.focusedPane()
    let bodyRow = a.row + 3
    let bodyCol = a.col + a.width div 2
    s.m73Send(rt, m73Sgr(WheelDown, bodyRow, bodyCol))
    let afterWheel = rt.painted()
    echo "M73: after a wheel notch down the first painted line is " &
         $afterWheel.firstLine & " (was " & $start.firstLine & ")"
    ck afterWheel.firstLine == start.firstLine + WheelRows
    ck afterWheel.showsLine(afterWheel.firstLine)
    # The pointer did not move, and the focus neither moved nor was needed
    # (§4.4: "without requiring pane focus").
    ck rt.app.source.executionLine == exec0
    ck s.session.getCurrentRRTicks() == tick0
    ck rt.focus.focusedPane() == focusBefore
    # The vertical bar's thumb moved down with the lines (§4: the pane's
    # rightmost column, the thumb in the scrubber's role).
    ck start.thumbRows.len > 0
    ck afterWheel.thumbRows.len > 0
    ck start.thumbRows.len > 0 and afterWheel.thumbRows.len > 0 and
       afterWheel.thumbRows[^1] > start.thumbRows[^1]
    # A notch UP brings it back.
    s.m73Send(rt, m73Sgr(WheelUp, bodyRow, bodyCol))
    ck rt.painted().firstLine == start.firstLine

    # ---- 2. Focus the editor with a click; `j` / `k` scroll one line ------
    s.m73Click(rt, a.row + 2, bodyCol)
    ck rt.focus.focusedPane() == (true, paneEditor)
    s.m73Send(rt, "j")
    ck rt.painted().firstLine == start.firstLine + 1
    s.m73Send(rt, "j")
    ck rt.painted().firstLine == start.firstLine + 2
    s.m73Send(rt, "k")
    ck rt.painted().firstLine == start.firstLine + 1
    ck rt.app.source.executionLine == exec0
    ck s.session.getCurrentRRTicks() == tick0

    # ---- 3. A caret moved below the last row brings the window with it ----
    # The caret onto the LAST body row by a click, then one `Down`: the caret
    # is on the line below the window, and the window follows it by the least
    # amount — one line (Editor-Pane.md: the keyboard moves the caret through
    # the file; the pane keeps it on screen).
    let before = rt.painted()
    let lastRow = before.firstRow + before.lines.len - 1
    let lastLine = before.lines[^1]
    echo "M73: last body row " & $lastRow & " shows line " & $lastLine &
         " (editor rows " & $rt.editorArea().row & "+" & $rt.editorArea().height &
         ", painted " & $before.lines & ")"
    ck lastLine == before.firstLine + rows - 1
    s.m73Click(rt, lastRow, bodyCol)
    ck rt.app.caret.line == lastLine
    s.m73Send(rt, "\x1b[B")   # Down
    ck rt.app.caret.line == lastLine + 1
    let followed = rt.painted()
    echo "M73: after Down below the last row the first painted line is " &
         $followed.firstLine
    ck followed.firstLine == before.firstLine + 1
    ck followed.lines.len > 0 and followed.lines[^1] == lastLine + 1
    ck rt.app.source.executionLine == exec0
    ck s.session.getCurrentRRTicks() == tick0

    # ---- 4. A breakpoint set on a scrolled-to line keeps the scroll -------
    # The gutter click refreshes the session's panes; the window stays where
    # the user put it (following the pointer belongs to a STOP).
    let scrolledTop = rt.painted().firstLine
    s.m73Click(rt, followed.firstRow + 1, a.col)
    ck rt.painted().firstLine == scrolledTop

    # ---- 5. `.` centres the execution pointer ------------------------------
    for _ in 0 ..< 12:
      s.m73Send(rt, m73Sgr(WheelDown, bodyRow, bodyCol))
    let away = rt.painted()
    echo "M73: scrolled away to line " & $away.firstLine
    ck away.firstLine > exec0 or away.firstLine + rows - 1 < exec0
    s.m73Send(rt, ".")
    let centred = rt.painted()
    let wantTop = clampTop(exec0 - (rows - 1) div 2, rows, total)
    echo "M73: after `.` the first painted line is " & $centred.firstLine &
         " (centring line " & $exec0 & " wants " & $wantTop & ")"
    ck centred.firstLine == wantTop
    ck rt.app.source.executionLine == exec0
    ck s.session.getCurrentRRTicks() == tick0

    # ---- 6. Ctrl+d / Ctrl+u, under the base that binds them ---------------
    # §4.2's `Ctrl+u` / `Ctrl+d` are the navigation table's (Vim, Kakoune);
    # CUA keeps VS Code's `Ctrl+D` (add cursor at next match). So the base
    # is switched as `--keymap=vim` switches it at start-up (`main` calls
    # `selectBase` with the flag as the source; `:keymap` is an Edit-mode
    # verb).
    rt.selectBase(bkVim, ksFlag)
    ck rt.keymapModel == bkVim
    ck rt.focus.focusedPane() == (true, paneEditor)
    ck rt.probeKey(rt.keyOf("\x04")).operation ==
       "editor.scroll-half-page-down"
    let half = max(1, rows div 2)
    let top0 = rt.painted().firstLine
    s.m73Send(rt, "\x04")     # Ctrl+D
    let down = rt.painted()
    echo "M73: Ctrl+D moved the first painted line " & $top0 & " -> " &
         $down.firstLine
    ck down.firstLine == clampTop(top0 + half, rows, total)
    ck down.firstLine > top0
    ck down.showsLine(down.firstLine)
    s.m73Send(rt, "\x15")     # Ctrl+U
    ck rt.painted().firstLine == top0
    ck rt.app.source.executionLine == exec0
    ck s.session.getCurrentRRTicks() == tick0

    # ---- 7. Both ends of the file clamp the window ------------------------
    # Far more notches than the file has lines: the window rests with the
    # file's last line on the pane's last body row, and one `k` from there is
    # one line up (a clamp that took it back would trap the window at the
    # end). Then as far up: line 1 on the first row.
    rt.selectBase(bkCua, ksFlag)
    for _ in 0 ..< 60:
      s.m73Send(rt, m73Sgr(WheelDown, bodyRow, bodyCol))
    let bottom = rt.painted()
    echo "M73: at the file's end the painted lines are " &
         $bottom.firstLine & ".." & $bottom.lines[^1]
    ck bottom.firstLine == total - rows + 1
    ck bottom.lines.len > 0 and bottom.lines[^1] == total
    s.m73Send(rt, "k")
    ck rt.painted().firstLine == total - rows
    for _ in 0 ..< 60:
      s.m73Send(rt, m73Sgr(WheelUp, bodyRow, bodyCol))
    ck rt.painted().firstLine == 1
    ck rt.app.source.executionLine == exec0
    ck s.session.getCurrentRRTicks() == tick0

    # ---- 8. A NEW stop still follows the pointer --------------------------
    # The window the user left (line 1 at the top, the pointer below the last
    # row) is the user's until the debugger moves; a step is a new stop, and
    # the pointer it lands on is shown.
    ck exec0 >= 1 + rows
    s.m73Send(rt, "\x1b[21~")   # F10, step over
    let stepped = rt.painted()
    let exec1 = rt.app.source.executionLine
    echo "M73: after a step the execution line is " & $exec1 &
         " and the first painted line " & $stepped.firstLine
    ck s.session.getCurrentRRTicks() != tick0
    ck exec1 >= stepped.firstLine and exec1 < stepped.firstLine + rows

  test "a file shorter than the pane draws no vertical bar and does not scroll":
    # `wide_lines`' 34 lines fit the pane at this size: no vertical bar is
    # painted (the bar is overflow-only, as the horizontal one is), and the
    # wheel over the editor leaves line 1 on the first row.
    let wide = resolveFixture(FixtureSpec(
      name: "wide_lines", program: "test-programs/wide_lines/main.py",
      recorder: "codetracer-python-recorder",
      probe: FixtureProbe(kind: pkPythonRecorder),
      buildHint: "Install codetracer_python_recorder into the interpreter " &
                 "`ct` will use.",
      blockedOn: ""))
    require wide.outcome == foRecorded
    putEnv("CODETRACER_TUI_LAYOUT_DIR",
           getTempDir() / ("m73-short-" & $getCurrentProcessId()))
    let (rt, s) = m73Open(wide.tracePath)
    defer: s.close()
    let rows = rt.sourcePaneRows()
    let total = rt.app.source.totalLineCount
    let start = rt.painted()
    echo "M73: short file " & $total & " line(s) in " & $rows & " row(s)"
    ck total > 0 and total <= rows
    ck start.firstLine == 1
    ck start.thumbRows.len == 0
    let a = rt.editorArea()
    s.m73Send(rt, m73Sgr(WheelDown, a.row + 3, a.col + a.width div 2))
    ck rt.painted().firstLine == 1
    ck rt.painted().thumbRows.len == 0

suite "CTUI-5: the source pane stays a window on a 12 000-line file":

  test "a long scroll never materializes more than window + overscan":
    inc examinedFixtures
    let resolution = resolveFixture(FixtureName)
    if resolution.outcome == foMissingPrereq:
      inc skippedFixtures
      let message = missingPrereqMessage(resolution.spec, resolution.detail)
      echo "  ", message
      ck message.startsWith(MissingPrereqSkipPrefix)
      ck resolution.tracePath.len == 0
      skip()
    else:
      inc verifiedFixtures
      let h = openHarness(resolution.tracePath)
      defer: h.closeHarness()

      # ---- point the session's SourceVM at the large file ------------------
      # `updateDebuggerPosition` is the production call `headless_session`
      # makes on every `ct/complete-move` event; nothing here reaches into the
      # VM's own signals.
      h.session.session.store.updateDebuggerPosition(
        rrTicks = 0, file = RecordedBigPath, line = 1)
      ck h.vm.revision.val.path == RecordedBigPath
      ck h.vm.executionLine.val == 1

      # ---- the positive control: the payload really answers ----------------
      let first = h.fillWindow()
      ck first > 0
      ck h.vm.totalLineCount.val == BigFileLines
      ck h.vm.lineAt(1).kind == srkHeld
      ck h.vm.lineAt(1).text == bigLineText(1)
      # …and it is the RECORDING's copy, not this machine's: the provider was
      # built refusing the working tree and the recorded path exists nowhere.
      ck not fileExists(RecordedBigPath)

      # ---- the scroll ------------------------------------------------------
      var maxHeld = 0
      var maxMaterialized = 0
      var maxRows = 0
      var totalFetched = first
      var stops = 0
      var rss: seq[int] = @[]
      var overBound: seq[string] = @[]
      var textWrong = 0

      for direction in [1, -1]:
        for i in 0 ..< ScrollStops:
          let top =
            if direction == 1: 1 + i * ScrollStride
            else: BigFileLines - i * ScrollStride
          h.vm.scrollTo(top)
          totalFetched += h.fillWindow()
          inc stops

          let held = h.vm.heldLines.val.len
          if held > maxHeld: maxHeld = held
          if held > MaxHeldLines:
            overBound.add "top " & $top & ": held " & $held &
              " line(s), bound is " & $MaxHeldLines

          let model = h.paneModel()
          let screen = sourcePaneScreen(model, PaneWidth, PaneHeight, h.cache)
          if screen.materializedLines > maxMaterialized:
            maxMaterialized = screen.materializedLines
          if screen.rows.len > maxRows:
            maxRows = screen.rows.len
          # Every visible held line carries the text that file really has at
          # that number. Counted rather than asserted per line, so the stop
          # count stays the assertion.
          for offset in 0 ..< model.heldLines.len:
            if model.heldLines[offset] !=
               bigLineText(model.firstHeldLine + offset):
              inc textWrong

          if stops mod RssSampleEvery == 0:
            rss.add residentKb()

      # ECHOED, not only checkpointed: `std/unittest` flushes checkpoints from
      # `fail()` alone, and these are the numbers a reader of a GREEN run needs
      # to watch trend. Same reason CTUI-3 echoes its projection timing.
      echo "CTUI-5 VIRTUALIZATION: " & $stops & " stop(s), max held " &
           $maxHeld & " line(s) (bound " & $MaxHeldLines & "), max " &
           "materialized " & $maxMaterialized & " (pane body " &
           $(PaneHeight - 1) & "), " & $totalFetched & " line(s) fetched " &
           "from a " & $BigFileLines & "-line file"
      checkpoint("stops: " & $stops & ", max held: " & $maxHeld &
                 ", max materialized: " & $maxMaterialized &
                 ", total lines fetched: " & $totalFetched)
      ck stops == 2 * ScrollStops
      ck overBound.len == 0
      # THE EXACT BOUND, and the positive twin beside it: the window really was
      # filled (a VM that held nothing would satisfy the upper bound for free).
      ck maxHeld <= MaxHeldLines
      ck maxHeld >= ViewportLines
      ck maxMaterialized <= ViewportLines
      ck maxMaterialized >= 1
      ck maxRows == PaneHeight
      ck textWrong == 0

      # ---- the pane FETCHED a window per stop, not a file per stop ---------
      # 300 stops over a 12 000-line file. Fetching the window each time is
      # about 300 * (viewport + overscan); fetching the file each time would be
      # 300 * 12 000. The bound is stated against the second, with a floor
      # against the first so a provider that answered nothing cannot pass.
      checkpoint("lines fetched across the scroll: " & $totalFetched &
                 " (a window per stop is ~" & $(stops * MaxHeldLines) &
                 ", a file per stop would be " & $(stops * BigFileLines) & ")")
      ck totalFetched <= stops * MaxHeldLines
      ck totalFetched >= stops * ViewportLines

      # ---- the highlighting cache is bounded -------------------------------
      # 300 distinct windows visited; the cache keeps `MaxCachedWindows`.
      checkpoint("highlight cache: " & $h.cache.entries.len & " entrie(s), " &
                 $h.cache.parseCount & " parse(s), " &
                 $h.cache.evictions & " eviction(s)")
      ck h.cache.entries.len <= MaxCachedWindows
      ck h.cache.parseCount > MaxCachedWindows
      ck h.cache.evictions > 0

      # ---- RSS -------------------------------------------------------------
      # WHAT THIS NUMBER IS AND IS NOT. It is the whole process's resident set,
      # which carries a `replay-server` client, an open trace, the Nim runtime
      # and this suite's own 12 000-line string. It cannot attribute a
      # kilobyte to the pane. What it CAN do is fail when the pane stops
      # virtualizing, because that failure is tens of megabytes over 300
      # stops, and that is the regression CTUI-5 asks this suite to catch
      # before CTUI-14 measures the target properly.
      echo "CTUI-5 RSS ACROSS THE SCROLL: " & $rss & " KB (samples every " &
           $RssSampleEvery & " stops)"
      ck rss.len == (2 * ScrollStops) div RssSampleEvery
      ck rss[0] > 0
      # The milestone's own words: "RSS does not grow monotonically".
      ck not isStrictlyIncreasing(rss)
      let growth = rss[^1] - rss[0]
      echo "CTUI-5 RSS GROWTH: " & $growth & " KB across " & $stops &
           " scroll stops (cap " & $RssGrowthCapKb & " KB)"
      ck growth < RssGrowthCapKb

  test "assertion count":
    ck examinedFixtures == 1
    ck verifiedFixtures + skippedFixtures == examinedFixtures
    ck verifiedFixtures >= 1
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
