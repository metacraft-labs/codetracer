## test_plat70b_tables_pty.nim — PLAT-70 Part B (Horizontal-Overflow.md §5),
## the shipped `codetracer-tui` on a REAL pseudo-terminal (TermAssert: a real
## pty, the screen read back through libvterm), over a real recording of
## `test-programs/wide_lines` (an output line, a call argument and module
## values far wider than any pane) against the real `replay-server`:
##
##   * HO-8 — in the Variables, Event Log and Call Trace panes, a cell ends in
##     `…` EXACTLY when the shared decision cut it: a plain-text cell (a name,
##     a type, an event's text, a call's text) is the shared `fitCell` of its
##     whole text at its column's width, both directions; a value's cut is
##     the presenter's, and a cut value is exactly a cell with a tooltip;
##   * §5.3 hover — the pointer resting on a cut cell (`?1003` motion, the
##     exact SGR bytes `CSI < 35 ; c ; r M`) shows its whole text after
##     500 ms, and on a cell that fits shows nothing; a key takes it away;
##   * §5.3 detail — a press on a cut cell's `…` opens its row's whole text
##     under the row, at most `DetailMaxLines`, and moves neither the
##     debugger nor its tick; again closes it; Vim's `Shift+K` and the CUA
##     palette's **Show Detail** open the focused row's;
##   * `list.copy` — `Ctrl+C` on the focused variable puts its WHOLE value on
##     the clipboard (OSC 52), every character of it;
##   * §5.2 — the Event Log's separators: a drag on one (the exact SGR press,
##     motion and release) resizes the column to its left, never under three
##     cells, and the width is written to the ONE remembered document every
##     front-end reads (`table-columns`, HO-9's write half); `:column-width`
##     sets one by name; the palette's **Widen Column** widens the focused
##     column.
##
## No mocks: the binary, the engine and the recording are real. State in a
## scratch directory.

import std/[base64, monotimes, os, strutils, times, unicode, unittest]

import term_assert
import nim_libvterm

import codetracer_embed

import ../fixtures/fixture_provider
from ../../app/views/tree_node import fieldWidths, nameFieldColumn,
  valueFieldColumn
import ./lifecycle_support

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 35

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 150
  Rows = 44
  Program = "test-programs/wide_lines/main.py"
  Ellipsis = "…"
  HoverWaitMs = 900
    ## More than §5.3's 500 ms, with the loop's tick and a loaded host.
  ColumnsFile = "table-columns"

type Snapshot = seq[seq[Cell]]

var spawned = 0
var lastState = ""

proc trace(): string =
  let resolved = resolveFixture(FixtureSpec(
    name: "wide_lines", program: Program,
    recorder: "codetracer-python-recorder",
    probe: FixtureProbe(kind: pkPythonRecorder),
    buildHint: "Install codetracer_python_recorder into the interpreter " &
               "`ct` will use.",
    blockedOn: ""))
  doAssert resolved.outcome == foRecorded, resolved.detail
  resolved.tracePath

proc open(extra: seq[string] = @[]): TuiTestSession =
  inc spawned
  let state = getTempDir() / ("plat70b-pty-" & $getCurrentProcessId() & "-" &
                              $spawned)
  removeDir(state)
  createDir(state)
  lastState = state
  # The scrollbars do not fade (Scrollbar-Scrubbers.md §7.5): a pointer
  # crossing a pane wakes its faded bars, which would read here as a tooltip
  # drawn over a cell that fits.
  result = newTuiTest(tuiBinary(), @["--theme=dark", "--scrollbar-fade=off"] &
                      extra & @[trace()])
    .width(Cols).height(Rows).transcript()
    .envRemove("TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE", "TMUX", "STY",
               "NERD_FONT", "NERDFONT", "COLORFGBG")
    .envSet("TERM", "xterm-256color").envSet("LANG", "en_US.UTF-8")
    .envSet("COLORTERM", "truecolor")
    .envSet("XDG_STATE_HOME", state)
    .envSet("CODETRACER_HOME", state / "ct-home")
    .envSet("CODETRACER_TUI_LAYOUT_DIR", state / "layout")
    .spawn()
  settleOnDebugger(result, Cols, Rows)

proc snap(sess: var TuiTestSession): Snapshot =
  discard sess.drainOutput(80)
  for r in 0 ..< Rows:
    var row: seq[Cell] = @[]
    for c in 0 ..< Cols:
      row.add sess.cellAt(r, c)
    result.add row

proc glyph(c: Cell): string =
  if int(c.rune) == 0: " " else: $c.rune

proc text(s: Snapshot; r: int): string =
  for c in s[r]:
    result.add c.glyph

proc cells(s: Snapshot; r, c0, n: int): string =
  for c in c0 ..< min(Cols, c0 + n):
    result.add s[r][c].glyph

proc cellFind(line, needle: string): int =
  let at = line.find(needle)
  if at < 0: -1 else: line[0 ..< at].runeLen

proc findRow(s: Snapshot; needle: string; fromRow = 0): (int, int) =
  for r in fromRow ..< Rows:
    let c = s.text(r).cellFind(needle)
    if c >= 0: return (r, c)
  (-1, -1)

proc dump(s: Snapshot): string =
  for r in 0 ..< Rows: result.add s.text(r) & "\n"

proc waitUntil(sess: var TuiTestSession; what: string;
               cond: proc(s: Snapshot): bool; timeoutMs = 20000): Snapshot =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    result = sess.snap()
    if cond(result): return
    sleep(40)
  raise newException(AssertionFailedError, "never: " & what & "\n" &
                     result.dump)

proc waitFor(sess: var TuiTestSession; needle: string): (int, int) =
  let s = sess.waitUntil("'" & needle & "' on screen",
                         proc(s: Snapshot): bool = s.findRow(needle)[0] >= 0)
  s.findRow(needle)

proc mouse(sess: var TuiTestSession; code, row, col: int; release = false) =
  ## One SGR-1006 report — the exact bytes a terminal writes.
  sess.send("\x1b[<" & $code & ";" & $(col + 1) & ";" & $(row + 1) &
            (if release: "m" else: "M"))

proc hover(sess: var TuiTestSession; row, col: int) =
  ## The pointer passing over `(row, col)` with no button (`?1003`: 32 + 3).
  sess.mouse(35, row, col)

proc press(sess: var TuiTestSession; row, col: int) =
  sess.mouse(0, row, col)
  sess.mouse(0, row, col, release = true)

proc tick(sess: var TuiTestSession): int =
  let line = sess.snap().text(0)
  let at = line.find("tick: ")
  if at < 0: return -1
  var digits = ""
  for c in line[at + "tick: ".len .. ^1]:
    if c in {'0' .. '9'}: digits.add c
    elif c == ',': discard
    else: break
  if digits.len == 0: -1 else: parseInt(digits)

proc quit(sess: var TuiTestSession) =
  sess.send("\x11")  # Ctrl+Q, the CUA base's quit
  discard sess.waitExit(initDuration(seconds = 10))
  sess.terminate()
  sess.close()

proc osc52(sess: var TuiTestSession): seq[string] =
  ## Every text the terminal was asked to put on its clipboard (OSC 52).
  let bytes = sess.transcriptBytes()
  var at = 0
  while true:
    let start = bytes.find("\e]52;c;", at)
    if start < 0: break
    let stop = bytes.find("\a", start)
    if stop < 0: break
    result.add base64.decode(bytes[start + 7 ..< stop])
    at = stop + 1

# ---------------------------------------------------------------------------
# The panes, read off the screen
# ---------------------------------------------------------------------------

type Pane = tuple[top, bottom, left, width: int]

proc paneOf(s: Snapshot; title: string): Pane =
  ## The body of the pane whose tab says `title`: from the row under its
  ## strip to the row before the next strip (or the status row), between
  ## the dividers (`▏`) around the tab.
  let (row, col) = s.findRow(" " & title & " ")
  doAssert row >= 0, "no '" & title & "' tab\n" & s.dump
  var left = col
  while left > 0 and s[row][left - 1].glyph != "▏": dec left
  var right = col
  while right < Cols and s[row][right].glyph != "▏": inc right
  var bottom = row + 1
  while bottom < Rows - 1:
    let line = s.cells(bottom, left, right - left)
    if line.strip.len > 0 and (line.contains(" Event Log ") or
                               line.contains(" Terminal Output ")):
      break
    inc bottom
  (row + 1, bottom - 1, left, right - left)

suite "PLAT-70 Part B on a real terminal: the table panes":

  test "HO-8, hover, the `…` press and the detail, list.copy":
    var sess = open()
    defer: sess.quit()
    # Past the module's first statements: its names are the pane's rows.
    var s = sess.snap()
    let vars = s.paneOf("Variables")
    proc moduleNames(s: Snapshot): bool =
      for r in vars.top .. vars.bottom:
        if s.cells(r, vars.left, vars.width).contains("__bui"): return true
    for _ in 0 ..< 6:
      if sess.snap().moduleNames: break
      let t = sess.tick()
      sess.send("\e[21~")  # F10, step over — one at a time, each settled
      discard sess.waitUntil("a step from tick " & $t,
        proc(s: Snapshot): bool = sess.tick() != t)
      sleep(800)
    s = sess.waitUntil("the module's names in the Variables pane",
                       proc(s: Snapshot): bool = s.moduleNames)
    checkpoint("variables pane " & $vars)
    # ---- Variables: the shared fit, both directions, for names; hover ----
    let width = vars.width
    let w = fieldWidths(width)
    let nameAt = vars.left + nameFieldColumn()
    let valueAt = vars.left + valueFieldColumn(width)
    var namesSeen, cutNames, valuesSeen, cutValues = 0
    var cutValueRow = -1
    var cutValueText = ""
    var mismatches: seq[string] = @[]
    proc away(sess: var TuiTestSession) =
      # The pointer onto a blank cell of the editor, and the screen settled.
      sess.hover(Rows - 6, 30)
      sleep(250)
    for r in vars.top .. vars.bottom:
      if s.cells(r, vars.left, 1) != "L": continue
      let name = s.cells(r, nameAt, w.name).strip(leading = false)
      let value = s.cells(r, valueAt, w.value).strip(leading = false)
      if name.len == 0: continue
      inc namesSeen
      inc valuesSeen
      for (cellCol, cellText, isValue) in [(nameAt, name, false),
                                           (valueAt, value, true)]:
        let cut = cellText.endsWith(Ellipsis)
        proc differs(a, b: Snapshot): bool =
          for k in 1 ..< Rows - 1:
            if a.text(k) != b.text(k): return true
        sess.away()
        # The screen at rest before the hover: a loaded host can still be
        # drawing the previous cell's dismissed tooltip, so the reference is
        # taken once two reads agree.
        var quiet = sess.snap()
        let settle = getMonoTime() + initDuration(milliseconds = 3000)
        while getMonoTime() < settle:
          sleep(150)
          let again = sess.snap()
          if not again.differs(quiet): break
          quiet = again
        # WHAT A TOOLTIP IS, MEASURED WHERE IT GOES: `cellTooltipArea` puts
        # the box on the row UNDER the cell, starting at the cell's column
        # (a padding cell, then the text). So a tooltip changes the cells
        # just under the hovered cell's start. "Any row changed" also counted
        # a scrollbar thumb fading on its own clock, at the pane's edge,
        # between the rest snapshot and the reading — red at load 90, green
        # alone.
        let underRow = r + 1
        proc tooltipUnder(s: Snapshot): bool =
          var moved = 0
          for k in 0 .. 2:
            let c = cellCol + k
            if underRow < Rows and c < Cols and
               (glyph(s[underRow][c]) != glyph(quiet[underRow][c]) or
                $s[underRow][c].bg != $quiet[underRow][c].bg):
              inc moved
          moved >= 2
        sess.hover(r, cellCol + 1)
        var changed = false
        if cut:
          # A cut cell's tooltip, waited for (the host is loaded) …
          let deadline = getMonoTime() + initDuration(milliseconds = 5000)
          while getMonoTime() < deadline and not changed:
            sleep(100)
            changed = sess.snap().tooltipUnder()
        else:
          # … and on a cell that fits, nothing — after twice the delay.
          sleep(HoverWaitMs + 100)
          changed = sess.snap().tooltipUnder()
        # §5.3 + HO-8: a tooltip exactly on the cells drawn with `…`.
        if changed != cut:
          mismatches.add $r & ":" & cellText & " cut=" & $cut
        if cut:
          if isValue:
            inc cutValues
            if cutValueRow < 0:
              cutValueRow = r
              cutValueText = cellText
          else:
            inc cutNames
    sess.away()
    checkpoint("names " & $namesSeen & " cut " & $cutNames & "; values " &
               $valuesSeen & " cut " & $cutValues & "; mismatches " &
               $mismatches)
    ck mismatches.len == 0
    ck namesSeen >= 5
    ck cutNames > 0
    ck cutValues > 0
    ck cutValues < valuesSeen     # some fit: the mark is not on every cell
    # HO-8, recomputed: every name drawn is the shared fit of the program's
    # own name (the module's names, known from the program and Python) at
    # the name column's width — the `…` exactly where the fit cut.
    const ModuleNames = ["__builtins__", "__cached__", "__doc__", "__file__",
                         "__loader__", "__name__", "__package__", "__spec__",
                         "WIDE_SOURCE", "emit", "main", "short"]
    var recomputed = 0
    for r in vars.top .. vars.bottom:
      if s.cells(r, vars.left, 1) != "L": continue
      let name = s.cells(r, nameAt, w.name).strip(leading = false)
      if name.len == 0: continue
      var known = ""
      for m in ModuleNames:
        if fitCell(m, w.name).text == name: known = m
      if known.len > 0: inc recomputed
      else: mismatches.add "unknown name " & name
    ck recomputed == namesSeen
    ck mismatches.len == 0

    # ---- Hover on a cut value: the tooltip after 500 ms; a key hides it ----
    let before = sess.snap()
    sess.hover(cutValueRow, valueAt + 1)
    sleep(250)
    ck sess.snap().text(cutValueRow + 1) == before.text(cutValueRow + 1)
    s = sess.waitUntil("the value's tooltip",
      proc(s: Snapshot): bool = s.text(cutValueRow + 1) != before.text(cutValueRow + 1))
    let tipLine = s.text(cutValueRow + 1)
    sess.send("\e[A")   # Up: a key
    s = sess.waitUntil("the tooltip gone on a key",
      proc(s: Snapshot): bool = not s.text(cutValueRow + 1).contains(tipLine.strip))

    # ---- The `…` press: the detail under the row; the tick stays ----------
    let t0 = sess.tick()
    let dots = s.cells(cutValueRow, valueAt, w.value).strip(leading = false)
    let dotCol = valueAt + dots.runeLen - 1
    ck s.cells(cutValueRow, dotCol, 1) == Ellipsis
    sess.press(cutValueRow, dotCol)
    s = sess.waitUntil("the detail under the row",
      proc(s: Snapshot): bool =
        s.cells(cutValueRow + 1, valueAt, w.value).strip.len > 0 and
        s.cells(cutValueRow + 1, vars.left, 1) != "L")
    var detailLines = 0
    var r = cutValueRow + 1
    while r <= vars.bottom and s.cells(r, vars.left, 1) != "L" and
          s.cells(r, valueAt, w.value).strip.len > 0:
      inc detailLines
      inc r
    checkpoint("detail lines " & $detailLines)
    ck detailLines >= 2
    ck detailLines <= detailMaxLines(vars.bottom - vars.top + 1)
    ck sess.tick() == t0
    # Again closes it.
    sess.press(cutValueRow, dotCol)
    s = sess.waitUntil("the detail closed",
      proc(s: Snapshot): bool = s.cells(cutValueRow + 1, vars.left, 1) == "L")

    # ---- Ctrl+C on the focused variable: the WHOLE value (OSC 52) ----------
    sess.press(cutValueRow, nameAt)     # the row: selected (and toggled)
    sleep(400)
    sess.send("\x03")                   # Ctrl+C, `list.copy` under CUA
    let copied = sess.waitUntil("a copy",
      proc(s: Snapshot): bool = sess.osc52().len > 0)
    discard copied
    let clip = sess.osc52()[^1]
    checkpoint("copied " & $clip.runeLen & " characters")
    ck clip.runeLen > w.value
    # The tooltip showed the same whole value: its first line is the copy's
    # first characters (the cell itself is the row budget's rendering).
    ck tipLine.contains(clip.oneLine.runeSubStr(0, 20))

    # ---- Event Log: every cell the shared fit of its whole text ------------
    let events = s.paneOf("Event Log")
    let header = events.top
    let (outRow, outCol) = s.findRow("<<LEFT-EDGE>>", events.top)
    ck outRow > header
    let output = "<<LEFT-EDGE>> the quick brown fox jumps over the lazy dog, " &
                 "0123456789 the quick brown fox jumps over the lazy dog, " &
                 "0123456789 the quick brown fox jumps over the lazy dog, " &
                 "0123456789 the quick brown fox jumps over the lazy dog, " &
                 "0123456789 <<RIGHT-EDGE>>"
    var right = outCol
    while right < Cols and s[outRow][right].glyph notin ["█", "│", "▏"] and
          right < events.left + events.width - 1:
      inc right
    let drawn = s.cells(outRow, outCol, right - outCol).strip(leading = false)
    let fit = fitCell(output, right - outCol)
    ck fit.truncated
    ck drawn == fit.text
    let (shortRow, shortCol) = s.findRow("a short line", events.top)
    ck shortRow > header
    ck not s.cells(shortRow, shortCol, right - shortCol).contains(Ellipsis)

    # ---- Call Trace: the row is one cell; the long call cut, the short not -
    let calls = s.paneOf("Call Trace")
    let (emit3, at3) = s.findRow("emit #3(", calls.top)
    let (main2, at2) = s.findRow("main #2(", calls.top)
    ck emit3 >= calls.top and main2 >= calls.top
    let rightEdge = calls.left + calls.width - 2
    let long = s.cells(emit3, at3, rightEdge - at3 + 1).strip(leading = false)
    ck long.endsWith(Ellipsis)
    ck fitCell("emit #3(text=\"" & output & "\")", rightEdge - at3 + 1).text ==
       long
    # A call that fits is drawn whole, no mark.
    let short = s.cells(main2, at2, rightEdge - at2 + 1).strip(leading = false)
    ck not short.contains(Ellipsis)
    ck not fitCell(short, rightEdge - at2 + 1).truncated

  test "Vim's Shift+K and the palette's Show Detail open the focused row's":
    var sess = open(@["--keymap=vim"])
    defer: sess.quit()
    discard sess.waitFor("<<LEFT-EDGE>>")
    var s = sess.snap()
    let events = s.paneOf("Event Log")
    let (outRow, outCol) = s.findRow("<<LEFT-EDGE>>", events.top)
    sess.press(outRow, outCol + 2)  # the first event's row: selected
    sleep(1500)
    let t0 = sess.tick()
    sess.send("K")                 # Shift+K: `list.show-detail`
    s = sess.waitUntil("Vim's K opened the detail",
      proc(s: Snapshot): bool = s.findRow("RIGHT-EDGE>>", events.top)[0] >= 0)
    ck s.findRow("RIGHT-EDGE>>", events.top)[0] > outRow
    ck sess.tick() == t0           # `K` moves neither the debugger nor the tick
    let t1 = sess.tick()
    sess.send("K")
    s = sess.waitUntil("again closes it",
      proc(s: Snapshot): bool = s.findRow("RIGHT-EDGE>>", events.top)[0] < 0)
    ck sess.tick() == t1
    # The palette's **Show Detail** (`list.show-detail` by name — the reach
    # where a base binds no chord, or the terminal cannot deliver it).
    sess.send("\x10")                # Ctrl+P, the palette
    sleep(400)
    sess.send(":Show Detail")
    sleep(300)
    sess.send("\r")
    s = sess.waitUntil("the palette's Show Detail opened it",
      proc(s: Snapshot): bool = s.findRow("RIGHT-EDGE>>", events.top)[0] > outRow)
    ck sess.tick() == t1
    discard outCol

  test "the Event Log's separators, the minimum, :column-width, the document":
    var sess = open()
    defer: sess.quit()
    discard sess.waitFor("<<LEFT-EDGE>>")
    var s = sess.snap()
    let events = s.paneOf("Event Log")
    let header = events.top
    let line = s.text(header)
    let hashAt = line.cellFind(" # ")
    ck hashAt > 0
    let kindAt = line.cellFind("kind")
    ck kindAt > hashAt
    # The separator right of `#` is the gap cell before `kind`.
    let sep = kindAt - 1
    let before = kindAt
    sess.mouse(0, header, sep)                    # press on the separator
    sess.mouse(32, header, sep + 4)               # motion with the button
    sess.mouse(32, header, sep + 8)
    sess.mouse(0, header, sep + 8, release = true)
    s = sess.waitUntil("the # column wider",
      proc(s: Snapshot): bool = s.text(header).cellFind("kind") > before + 6)
    let doc = lastState / "layout" / ColumnsFile
    s = sess.waitUntil("the width remembered",
      proc(s: Snapshot): bool = fileExists(doc) and
                                readFile(doc).contains("event-log.#="))
    let entry = readFile(doc)
    checkpoint("document: " & entry)
    let decoded = decodeColumnWidths(entry)
    ck decoded.ok
    var cells = 0
    for e in decoded.entries:
      if e.table == "event-log" and e.column == "#": cells = e.cells
    ck cells >= 10
    # The minimum: dragged far left, three cells.
    let nowKind = s.text(header).cellFind("kind")
    sess.mouse(0, header, nowKind - 1)
    sess.mouse(32, header, nowKind - 20)
    sess.mouse(0, header, events.left, release = true)
    s = sess.waitUntil("the # column at the minimum",
      proc(s: Snapshot): bool = readFile(doc).contains("event-log.#=3\n"))
    ck readFile(doc).contains("event-log.#=3\n")
    # `:column-width` by name.
    sess.send("\x10")        # Ctrl+P, the palette
    sleep(300)
    sess.send(":column-width tick 12")
    sleep(200)
    sess.send("\r")
    s = sess.waitUntil(":column-width remembered",
      proc(s: Snapshot): bool = readFile(doc).contains("event-log.tick=12"))
    ck readFile(doc).contains("event-log.tick=12")
    # **Widen Column**: the focused column (the last one named) by 2.
    sess.send("\x10")
    sleep(300)
    sess.send(":Widen Column")
    sleep(300)
    sess.send("\r")
    s = sess.waitUntil("Widen Column remembered",
      proc(s: Snapshot): bool = readFile(doc).contains("event-log.tick=14"))
    ck readFile(doc).contains("event-log.tick=14")

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
