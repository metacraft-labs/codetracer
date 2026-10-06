## test_plat52_terminal_output_model.nim — PLAT-52, the Terminal Output pane's
## SHARED model (`viewmodels/terminal_output_model`, `scrollbar_scrubber`), the
## one the desktop, the terminal and the GPUI window draw:
##
##   * the SGR attributes of a recorded write, decoded AS DATA — every colour
##     form (16, bright, 256, direct, the `:` form), every attribute, resets;
##   * the LINE view: lines and fragments as the desktop's line cache grouped
##     them (a run per write per style), non-SGR sequences dropped, tabs to
##     the next multiple of eight, an empty line still owned by its write, an
##     escape sequence split across two writes still one sequence;
##   * past / active / future against the current tick, and the line of the
##     current position;
##   * the SCREEN emulator: cursor addressing, erase in display / line,
##     autowrap, insert / delete characters and lines, scroll regions, the
##     alternate screen with its saved cursor, reverse index — each against
##     the screen it must produce;
##   * the screen over time: the screen after any write equals a replay from
##     byte 0, while a move replays at most `snapshotEvery` writes (§3
##     "Cost"); the marks of clears and alternate-screen switches; the write
##     at a tick; the built-in scrubber's track ↔ write mapping;
##   * the scrollbar SCRUBBER model, swept as a pure function over totals
##     0..10^9 and track extents 1..400 (Scrollbar-Scrubbers.md §5): the thumb
##     never leaves the track, a click at fraction f names row
##     round(f * (total - 1)), a drag is monotonic, the fetched window holds
##     the named row, and a drag's fetches coalesce to a bounded number.
##
## Pure (values in, values out), on all three backends (vm-unit, vm-unit-js,
## vm-unit-wasm). No mocks. The screen is checked against libvterm itself on a
## real recording in `tui/tests/real_terminal/test_plat52_screen_reference.nim`.

import std/[json, math, strutils, tables, unittest]

import store/types
import viewmodels/terminal_output_model
import viewmodels/scrollbar_scrubber

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 154

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

proc ev(content: string; ticks: uint64; index = 0): TerminalOutputEvent =
  TerminalOutputEvent(content: content, rrTicks: ticks, eventIndex: index,
                      logIndex: index)

proc evs(contents: varargs[string]): seq[TerminalOutputEvent] =
  for i, c in contents:
    result.add ev(c, uint64(10 * (i + 1)), i)

proc screenOf(contents: varargs[string]): TermScreen =
  result = newTermScreen(20, 6)
  for c in contents:
    result.feed(c)

proc text(s: TermScreen): seq[string] =
  ## Every row, trailing blanks dropped.
  for r in 0 ..< s.rows:
    result.add s.screenRowText(r).strip(leading = false)

proc sameScreen(a, b: TermScreen): bool =
  if a.rows != b.rows or a.cols != b.cols:
    return false
  for r in 0 ..< a.rows:
    for c in 0 ..< a.cols:
      let x = a.cellAt(r, c)
      let y = b.cellAt(r, c)
      if x.ch != y.ch or x.wide != y.wide or a.attrsOf(x) != b.attrsOf(y):
        return false
  a.row == b.row and a.col == b.col and a.altActive == b.altActive

suite "PLAT-52: SGR attributes, as data":

  test "the sixteen colours, bright, 256 and direct, and the resets":
    let lines = buildTerminalLines(evs(
      "\e[31mr\e[42mg\e[0mp\e[91mb\e[38;5;208mo\e[38;2;1;2;3mt" &
      "\e[48:5:17mx\e[38:2::9:8:7my\e[39;49mz\n"))
    ck lines.len == 1
    let f = lines[0].fragments
    ck f.len == 9
    ck f[0].text == "r" and f[0].style.fg == termIndexed(1)
    ck f[1].style.fg == termIndexed(1) and f[1].style.bg == termIndexed(2)
    ck f[2].style == TermAttrs()
    ck f[3].style.fg == termIndexed(9)
    ck f[4].style.fg == termIndexed(208)
    ck f[5].style.fg == termRgbColor(1, 2, 3)
    ck f[6].style.bg == termIndexed(17)
    ck f[7].style.fg == termRgbColor(9, 8, 7)
    ck f[8].style.fg.kind == tckDefault and f[8].style.bg.kind == tckDefault

  test "every attribute on, and off again":
    var a = TermAttrs()
    var sc = AnsiScanner()
    for t in sc.scanAnsi("\e[1;2;3;4;5;7;8;9m"):
      if t.kind == atCsi: a.applySgr(t)
    ck a.bold and a.faint and a.italic and a.underline and a.blink and
       a.reverse and a.hidden and a.strike
    for t in sc.scanAnsi("\e[22;23;24;25;27;28;29m"):
      if t.kind == atCsi: a.applySgr(t)
    ck a == TermAttrs()
    for t in sc.scanAnsi("\e[1;31m\e[m"):
      if t.kind == atCsi: a.applySgr(t)
    ck a == TermAttrs()

  test "the desktop's palette and its CSS":
    ck termColorRgb(termIndexed(1)) == (187, 0, 0)
    ck termColorRgb(termIndexed(9)) == (255, 85, 85)
    ck termColorRgb(termIndexed(16)) == (0, 0, 0)
    ck termColorRgb(termIndexed(231)) == (255, 255, 255)
    ck termColorRgb(termIndexed(232)) == (8, 8, 8)
    ck termHex(termIndexed(2)) == "#00bb00"
    ck termHex(TermColor()) == ""
    ck cssOf(TermAttrs(fg: termIndexed(1), bold: true)) ==
       "color:rgb(187,0,0);font-weight:bold"
    ck cssOf(TermAttrs(bg: termIndexed(4), italic: true, underline: true)) ==
       "background-color:rgb(0,0,187);font-style:italic;" &
       "text-decoration:underline"
    ck cssOf(TermAttrs()) == ""

suite "PLAT-52: the line view":

  test "lines and fragments: a run per write per style":
    let lines = buildTerminalLines(evs(
      "\e[31mred\e[0m plain\n", "two writes, ", "one line\n", "a\nb\n\nc"))
    ck lines.len == 6
    ck lines[0].lineText == "red plain"
    ck lines[0].fragments.len == 2
    ck lines[1].lineText == "two writes, one line"
    ck lines[1].fragments.len == 2
    ck lines[1].fragments[0].eventIndex == 1
    ck lines[1].fragments[1].eventIndex == 2
    ck lines[1].fragments[1].rrTicks == 30'u64
    ck lines[2].lineText == "a" and lines[3].lineText == "b"
    ck lines[5].lineText == "c"
    for i, l in lines:
      ck l.lineIndex == i

  test "an empty line keeps a fragment of the write that ended it":
    let lines = buildTerminalLines(evs("x\n", "\ny\n"))
    ck lines.len == 3
    ck lines[1].fragments.len == 1
    ck lines[1].fragments[0].text == ""
    ck lines[1].fragments[0].eventIndex == 1

  test "non-SGR sequences are dropped; tabs go to the next stop":
    let lines = buildTerminalLines(evs(
      "\e[2J\e[1;1H\e]0;title\atab\tx\e[?25l\r\n", "ab\tc\n"))
    ck lines.len == 2
    ck lines[0].lineText == "tab     x"
    ck lines[1].lineText == "ab      c"

  test "a sequence split across two writes is still one sequence":
    let lines = buildTerminalLines(evs("\e[3", "1mred\e[0m\n"))
    ck lines.len == 1
    ck lines[0].fragments[0].text == "red"
    ck lines[0].fragments[0].style.fg == termIndexed(1)
    ck lines[0].fragments[0].eventIndex == 1

  test "past, active, future and the current line":
    ck fragmentTense(20, 10) == ttPast
    ck fragmentTense(20, 20) == ttActive
    ck fragmentTense(20, 30) == ttFuture
    let lines = buildTerminalLines(evs("a\n", "b\n", "c\n"))
    ck lineOfTick(lines, 5) == -1
    ck lineOfTick(lines, 10) == 0
    ck lineOfTick(lines, 25) == 1
    ck lineOfTick(lines, 1000) == 2

  test "the writes of a ct/loaded-terminal answer":
    let body = %*[
      {"content": "\e[31mhi\e[0m\n", "directLocationRRTicks": 7,
       "eventIndex": 4, "highLevelPath": "/p/main.py", "highLevelLine": 3,
       "base64Encoded": false, "stdout": true},
      {"content": "cGxhaW4=", "base64Encoded": true,
       "directLocationRRTicks": 9, "eventIndex": 5}]
    let got = terminalEventsFromJson(body)
    ck got.len == 2
    ck got[0].content == "\e[31mhi\e[0m\n"
    ck got[0].rrTicks == 7'u64
    ck got[0].logIndex == 4
    ck got[0].path == "/p/main.py" and got[0].line == 3
    ck got[1].content == "plain"
    ck got[1].eventIndex == 1

suite "PLAT-52: the screen emulator":

  test "cursor addressing, erase in line and in display":
    let s = screenOf("hello\e[2;3Hworld\e[1;3H\e[K", "\e[6;1Hbottom")
    ck s.text == @["he", "  world", "", "", "", "bottom"]
    let t = screenOf("aaaa\r\nbbbb\r\ncccc", "\e[2;3H\e[J")
    ck t.text == @["aaaa", "bb", "", "", "", ""]
    let u = screenOf("aaaa\r\nbbbb\r\ncccc", "\e[2;3H\e[1J")
    ck u.text == @["", "   b", "cccc", "", "", ""]

  test "a written line feed is CR LF (the terminal device's ONLCR)":
    let s = screenOf("ab\ncd\n")
    ck s.text[0 .. 1] == @["ab", "cd"]
    ck s.row == 2 and s.col == 0

  test "autowrap at the last column, and scrolling at the bottom":
    let s = screenOf("0123456789abcdefghijXY")
    ck s.text[0] == "0123456789abcdefghij"
    ck s.text[1] == "XY"
    let t = screenOf("1\r\n2\r\n3\r\n4\r\n5\r\n6\r\n7")
    ck t.text == @["2", "3", "4", "5", "6", "7"]

  test "insert and delete characters and lines, erase characters":
    let s = screenOf("abcdef\e[1;3H\e[2@XY")
    ck s.text[0] == "abXYcdef"
    let t = screenOf("abcdef\e[1;2H\e[2P")
    ck t.text[0] == "adef"
    let u = screenOf("abcdef\e[1;2H\e[3X")
    ck u.text[0] == "a   ef"
    let v = screenOf("1\r\n2\r\n3\r\n4\e[2;1H\e[L")
    ck v.text == @["1", "", "2", "3", "4", ""]
    let w = screenOf("1\r\n2\r\n3\r\n4\e[2;1H\e[M")
    ck w.text == @["1", "3", "4", "", "", ""]

  test "a scroll region scrolls only its rows; reverse index at its top":
    let s = screenOf("top\e[2;4r\e[4;1Ha\nb\nc\e[r\e[6;1Hbot")
    ck s.text == @["top", "a", "b", "c", "", "bot"]
    let t = screenOf("1\r\n2\r\n3\e[1;1H\eM")
    ck t.text == @["", "1", "2", "3", "", ""]

  test "the alternate screen: entered blank, left with the main screen back":
    let s = screenOf("main\e[?1049h")
    ck s.altActive
    ck s.text[0] == ""
    var t = s
    t.feed("alt")
    # The cursor stays where it was (libvterm does not home it).
    ck t.text[0] == "    alt"
    t.feed("\e[?1049l")
    ck not t.altActive
    ck t.text[0] == "main"
    # The cursor saved on entry is back.
    ck t.row == 0 and t.col == 4
    # Entered AGAIN, the alternate screen is blank: libvterm erases it on
    # every enable, not only the first.
    t.feed("\e[?1049h")
    ck t.altActive
    ck t.text[0] == ""

  test "erased cells take the pen's colours (libvterm's rule)":
    let s = screenOf("\e[44m\e[2J\e[0mx")
    ck s.attrsOf(s.cellAt(3, 3)).bg == termIndexed(4)
    ck s.attrsOf(s.cellAt(0, 0)) == TermAttrs()

  test "a wide character takes two cells":
    let s = screenOf("a世b")
    ck s.cellAt(0, 1).wide == 2
    ck s.cellAt(0, 2).wide == -1
    ck s.screenRowText(0).strip(leading = false) == "a世b"

suite "PLAT-52: the screen over time — snapshots, marks, the scrubber":

  proc program(n: int): seq[TerminalOutputEvent] =
    result.add ev("\e[?1049h\e[2J", 1, 0)
    for i in 1 ..< n:
      var s = "\e[" & $(1 + i mod 20) & ";1H\e[3" & $(i mod 8) & "mline " & $i
      if i == n div 2: s = "\e[2J" & s
      result.add ev(s, uint64(1 + i * 3), i)
    result.add ev("\e[?1049ldone\n", uint64(3 * n + 5), n)

  test "the screen after any write equals a replay from byte 0":
    let events = program(300)
    let m = newTerminalScreenModel(events, 40, 22)
    ck m.offered
    var checked = 0
    for w in [0, 1, 15, 16, 17, 63, 64, 150, 151, 299, 300, 10, 299, 0]:
      var full = newTermScreen(40, 22)
      for i in 0 .. w:
        full.feed(events[i].content)
      if not sameScreen(m.screenAfter(w), full):
        checkpoint("screen after write " & $w & " differs from the replay")
      ck sameScreen(m.screenAfter(w), full)
      inc checked
    ck checked == 14

  test "a move replays at most one snapshot interval, never from byte 0":
    let events = program(2000)
    let m = newTerminalScreenModel(events, 40, 22)
    ck m.snapshotEvery >= MinSnapshotEvery
    ck (events.len + m.snapshotEvery - 1) div m.snapshotEvery <= MaxSnapshots
    var worst = 0
    for w in [1999, 3, 1000, 1001, 1500, 7, 1999, 1200]:
      discard m.screenAfter(w)
      worst = max(worst, m.replayed)
    checkpoint("worst replay " & $worst & " of " & $events.len &
               " writes, snapshot every " & $m.snapshotEvery)
    ck worst <= m.snapshotEvery
    ck worst < events.len div 4

  test "the marks: the alternate screen entered and left, a clear":
    let events = program(100)
    let m = newTerminalScreenModel(events, 40, 22)
    ck m.marks.len == 3
    ck m.marks[0] == ScreenMark(write: 0, kind: smAltEnter)
    ck m.marks[1] == ScreenMark(write: 50, kind: smClear)
    ck m.marks[2] == ScreenMark(write: 100, kind: smAltLeave)

  test "a line-oriented program is not offered the screen":
    let m = newTerminalScreenModel(evs("hello\n", "\e[31mred\e[0m\n"))
    ck not m.offered
    ck defaultViewFor(m.offered) == tvLines
    ck defaultViewFor(true) == tvScreen

  test "the write at a tick, and the track's mapping":
    let events = program(10)
    let m = newTerminalScreenModel(events)
    ck m.writeAtTick(0) == -1
    ck m.writeAtTick(1) == 0
    ck m.writeAtTick(4) == 1
    ck m.writeAtTick(5) == 1
    ck m.writeAtTick(1_000_000) == 10
    ck writeAtFraction(11, 0.0) == 0
    ck writeAtFraction(11, 1.0) == 10
    ck writeAtFraction(11, 0.5) == 5
    ck writeAtFraction(0, 0.5) == -1
    ck fractionOfWrite(11, 10) == 1.0
    ck fractionOfWrite(11, 0) == 0.0

  test "the remembered view choices round-trip":
    var t = viewMemoryFromJson("""{"/a": "screen", "/b": "lines", "/c": 3}""")
    ck t.len == 2
    ck t["/a"] == tvScreen and t["/b"] == tvLines
    let back = viewMemoryFromJson(viewMemoryToJson(t))
    ck back == t
    ck viewMemoryFromJson("not json").len == 0
    # An empty store (a fresh profile) is no choices — on the JS backend a
    # parse of "" throws a JavaScript error nothing catches.
    ck viewMemoryFromJson("").len == 0
    ck viewMemoryFromJson("  ").len == 0
    ck viewMemoryFromJson("{\"/a\": ").len == 0

suite "PLAT-52: the scrollbar scrubber model (Scrollbar-Scrubbers.md §5)":

  test "swept: the thumb stays on the track; a click names its row":
    var cases = 0
    var bad = 0
    for total in [0, 1, 2, 3, 7, 10, 99, 100, 101, 1_000, 65_537,
                  1_000_000, 123_456_789, 1_000_000_000]:
      for track in [1, 2, 3, 8, 13, 40, 99, 160, 255, 400]:
        for visible in [1, 5, 24]:
          let m = scrubberModel(total, 0, visible)
          for k in 0 .. 20:
            let f = k / 20
            let row = m.rowAtFraction(f)
            if total > 0 and
               abs(row - int(round(f * float(total - 1)))) > 1:
              inc bad
            let first = m.clickAt(f)
            let moved = scrubberModel(total, first, visible)
            let span = moved.thumbSpan(track * 8, 8)
            if span.start < 0 or span.start + span.length > track * 8:
              inc bad
            # The clicked row is shown (centred, clamped at the ends).
            if total > 0 and (row < first or row >= first + max(1, visible)):
              inc bad
            inc cases
    checkpoint($cases & " cases, " & $bad & " violations")
    ck cases == 14 * 10 * 3 * 21
    ck bad == 0

  test "a drag is monotonic and reaches the last row":
    for total in [10, 500, 1_000_000]:
      let m = scrubberModel(total, 0, 20)
      var last = -1
      var mono = true
      for k in 0 .. 200:
        let top = m.dragTo(k / 200)
        if top < last: mono = false
        last = top
      ck mono
      ck last == max(0, total - 20)
      # A click at the track's end shows the LAST row of the whole population.
      let first = m.clickAt(1.0)
      ck first + 20 >= total

  test "the current-position mark sits on its row":
    let m = scrubberModel(1000, 0, 50, current = 750)
    ck abs(m.currentFraction - 0.7505) < 0.0001
    ck scrubberModel(1000, 0, 50).currentFraction < 0.0
    ck m.thumbLength == 0.05
    ck scrubberModel(10, 0, 50).thumbLength == 1.0
    ck scrubberModel(100, 0, 10, totalKnown = false).thumbLength == 1.0

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
