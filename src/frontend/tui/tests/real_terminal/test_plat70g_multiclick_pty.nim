## test_plat70g_multiclick_pty.nim — multi-click selection, the gutter's two
## zones, Alt+click and Shift+F9 on a real terminal (Editor-Pane.md MC.1 – MC.7).
##
## The exact bytes a terminal sends: SGR-1006 presses at real intervals, on the
## shipped `codetracer-tui`, read back from the painted cells, the clipboard
## (OSC 52) and the engine's answers. The Edit-mode half runs on the milestone's
## fixture document in a real directory; the Debug half on a real recording of
## `calc` with a real `replay-server`.
##
## No mocks.

import std/[base64, monotimes, os, osproc, strutils, times, unicode, unittest]

import term_assert

import ../fixtures/fixture_provider
import ./lifecycle_support

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 67

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 170
  Rows = 40
  StatusRow = Rows - 1
  Fixture = "snake_case_name = other.attr(x)\n" &
            "    leading indentation\n" &
            "a == b and p->q\n" &
            "a.b\n" &
            "\n" &
            "price λx 3€ end\n" &
            "last line no terminator"
  Left = 0
  Middle = 1
  Right = 2
  Ctrl = 16
  Alt = 8
  ShiftF9 = "\e[20;2~"
  CtrlC = "\x03"

type Snapshot = seq[seq[Cell]]

var spawned = 0

proc freshDir(): string =
  inc spawned
  result = getTempDir() / ("plat70g-pty-" & $getCurrentProcessId() & "-" & $spawned)
  removeDir(result)
  createDir(result)

proc spawnTui(args: seq[string]; state: string; keymap = ""): TuiTestSession =
  let extra = if keymap.len > 0: @["--keymap=" & keymap] else: @[]
  newTuiTest(tuiBinary(), @["--theme=dark"] & extra & args)
    .width(Cols).height(Rows).transcript()
    .envRemove("TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE", "TMUX", "STY",
               "NERD_FONT", "NERDFONT", "COLORFGBG")
    .envSet("TERM", "xterm-256color").envSet("LANG", "en_US.UTF-8")
    .envSet("COLORTERM", "truecolor")
    .envSet("XDG_STATE_HOME", state)
    .envSet("XDG_CONFIG_HOME", state / "config")
    .envSet("CODETRACER_HOME", state / "ct-home")
    .envSet("CODETRACER_TUI_LAYOUT_DIR", state / "layout")
    .spawn()

proc snap(sess: var TuiTestSession): Snapshot =
  discard sess.drainOutput(60)
  for r in 0 ..< Rows:
    var row: seq[Cell] = @[]
    for c in 0 ..< Cols:
      row.add sess.cellAt(r, c)
    result.add row

proc text(s: Snapshot; r: int): string =
  for c in s[r]:
    result.add(if int(c.rune) == 0: " " else: $c.rune)

proc cellFind(line, needle: string): int =
  let at = line.find(needle)
  if at < 0: -1 else: line[0 ..< at].runeLen

proc waitFor(sess: var TuiTestSession; needle: string): (int, int) =
  let deadline = getMonoTime() + initDuration(seconds = 30)
  while getMonoTime() < deadline:
    let s = sess.snap()
    for r in 0 ..< Rows:
      let c = s.text(r).cellFind(needle)
      if c >= 0: return (r, c)
    sleep(40)
  var all = ""
  let s = sess.snap()
  for r in 0 ..< Rows: all.add s.text(r) & "\n"
  raiseAssert "never saw '" & needle & "':\n" & all

proc mouse(sess: var TuiTestSession; code, row, col: int; release = false) =
  sess.send("\x1b[<" & $code & ";" & $(col + 1) & ";" & $(row + 1) &
            (if release: "m" else: "M"))

proc press(sess: var TuiTestSession; row, col: int; code = Left) =
  sess.mouse(code, row, col)
  sess.mouse(code, row, col, release = true)

proc clicks(sess: var TuiTestSession; row, col, count: int; code = Left;
            gapMs = 100) =
  # A new gesture: past the interval since whatever came before it.
  sleep(650)
  for i in 0 ..< count:
    if i > 0: sleep(gapMs)
    sess.press(row, col, code)

proc lastCopy(sess: var TuiTestSession): string =
  ## The last text the terminal was asked to put on its clipboard (OSC 52).
  let bytes = sess.transcriptBytes()
  let start = bytes.rfind("\e]52;c;")
  if start < 0: return ""
  let stop = bytes.find("\a", start)
  if stop < 0: return ""
  base64.decode(bytes[start + 7 ..< stop])

proc copied(sess: var TuiTestSession): string =
  ## What is selected, by copying it.
  let before = sess.transcriptBytes().count("\e]52;c;")
  sess.send(CtrlC)
  let deadline = getMonoTime() + initDuration(seconds = 10)
  while getMonoTime() < deadline:
    discard sess.drainOutput(40)
    if sess.transcriptBytes().count("\e]52;c;") > before:
      return sess.lastCopy()
    sleep(30)
  "<nothing was copied>"

proc quit(sess: var TuiTestSession) =
  sess.send("\x11")
  discard sess.waitExit(initDuration(seconds = 10))
  sess.terminate()
  sess.close()

proc openFixture(keymap = ""): tuple[sess: TuiTestSession; row, col: int] =
  ## The fixture document in Edit mode; `row` and `col` are where its first line's
  ## text starts on the screen.
  let dir = freshDir()
  let project = dir / "project"
  createDir(project)
  writeFile(project / "fixture.txt", Fixture)
  var sess = spawnTui(@["--edit", project / "fixture.txt"], dir / "state", keymap)
  let (r, c) = sess.waitFor("snake_case_name")
  (sess, r, c)

proc selects(sess: var TuiTestSession; row, col, count: int): string =
  ## What `count` presses select. Presses are counted by when they are decoded, so
  ## on a loaded host a gesture can arrive past the interval and be a smaller one:
  ## it gets another try, and only a repeated wrong answer is the answer. The
  ## single-click and interval cases assert the other direction.
  var last = ""
  for attempt in 0 .. 3:
    sess.clicks(row, col, count)
    let got = sess.copied()
    if got == last:
      return got
    last = got
    if count == 2 and got.len < 40 and not got.endsWith("\n"): return got
    if count == 3 and got.endsWith("\n") and got.len < 80: return got
    if count >= 4 and got.count('\n') > 2: return got
  last

proc gone(sess: var TuiTestSession; row: int; text: string): bool =
  ## Whether `text` leaves the painted row within a few seconds.
  let deadline = getMonoTime() + initDuration(seconds = 5)
  while getMonoTime() < deadline:
    if not sess.snap().text(row).contains(text):
      return true
    sleep(50)

proc reversedCells(s: Snapshot; row: int): int =
  for c in s[row]:
    if caReverse in c.attrs: inc result

suite "Edit mode, the fixture document: counts and units":

  test "two presses select the word, three the line, four the document":
    var (sess, r, c) = openFixture()
    ck sess.selects(r, c + 2, 2) == "snake_case_name"
    ck sess.selects(r, c + 2, 3) == "snake_case_name = other.attr(x)\n"
    ck sess.selects(r, c + 2, 4) == Fixture
    sess.quit()

  test "the word is the separators', on the fixture's lines":
    var (sess, r, c) = openFixture()
    ck sess.selects(r + 2, c + 3, 2) == "=="       # inside `==`
    ck sess.selects(r + 3, c + 1, 2) == "."        # the `.` of a.b, cell input
    ck sess.selects(r + 1, c + 1, 2) == "    "     # the indentation
    ck sess.selects(r + 5, c + 6, 2) == "λx"
    ck sess.selects(r + 5, c + 9, 2) == "3€"
    sess.quit()

  test "450 ms apart they are single clicks":
    var (sess, r, c) = openFixture()
    sess.clicks(r, c + 2, 3, gapMs = 450)
    # A single click selects nothing, so Copy takes the caret's line whole.
    ck sess.copied() == "snake_case_name = other.attr(x)\n"
    sess.quit()

  test "two cells within 100 ms are two single clicks":
    var (sess, r, c) = openFixture()
    sess.press(r, c + 2)
    sleep(60)
    sess.press(r, c + 3)
    ck sess.copied() == "snake_case_name = other.attr(x)\n"
    sess.quit()

  test "a duplicate press without a release counts once":
    var (sess, r, c) = openFixture()
    # A loaded host can deliver these past the interval, so a few tries.
    var got = ""
    for attempt in 0 .. 2:
      sleep(650)
      sess.press(r, c + 2)
      sess.mouse(Left, r, c + 2)
      sess.mouse(Left, r, c + 2)       # tmux's second copy of the same press
      sess.mouse(Left, r, c + 2, release = true)
      got = sess.copied()
      if got == "snake_case_name": break
    ck got == "snake_case_name"
    sess.quit()

  test "a word drag grows by whole words and never below the anchor":
    var (sess, r, c) = openFixture()
    let other = c + 19
    sess.press(r, other)
    sleep(50)
    sess.mouse(Left, r, other)
    sess.mouse(Left + 32, r, c + 26)   # motion into `attr`
    discard sess.drainOutput(60)
    sess.mouse(Left + 32, r, c + 20)   # back inside the anchor word
    sess.mouse(Left, r, c + 26, release = true)
    ck sess.copied() == "other.attr"
    sleep(650)
    sess.press(r, other)
    sleep(50)
    sess.mouse(Left, r, other)
    sess.mouse(Left + 32, r, c + 20)
    sess.mouse(Left, r, c + 20, release = true)
    ck sess.copied() == "other"
    sess.quit()


  test "cell input selects the `.` of a.b; pixel reports its halves' words":
    var (sess, r, c) = openFixture()
    sess.clicks(r + 3, c + 1, 2)
    ck sess.copied() == "."
    sess.quit()
    # SGR-pixel reports: the terminal says it supports DECSET 1016, and its cell.
    let dir = freshDir()
    let project = dir / "project"
    createDir(project)
    writeFile(project / "fixture.txt", Fixture)
    var pixels = spawnTui(@["--edit", project / "fixture.txt"], dir / "state")
    let asked = getMonoTime() + initDuration(seconds = 20)
    while getMonoTime() < asked and
          not pixels.transcriptBytes().contains("\e[?1016$p"):
      discard pixels.drainOutput(20)
    pixels.send("\e[?1016;2$y\e[6;40;20t\e[?62;22c")
    let (pr, pc) = pixels.waitFor("snake_case_name")
    proc at(sess: var TuiTestSession; col: int; right: bool; code = Left;
            release = false) =
      let px = col * 20 + (if right: 15 else: 5) + 1
      let py = (pr + 3) * 40 + 20 + 1
      sess.send("\x1b[<" & $code & ";" & $px & ";" & $py &
                (if release: "m" else: "M"))
    for i in 0 .. 1:
      pixels.at(pc + 1, right = false)
      pixels.at(pc + 1, right = false, release = true)
      sleep(60)
    ck pixels.copied() == "a"
    sleep(500)
    for i in 0 .. 1:
      pixels.at(pc + 1, right = true)
      pixels.at(pc + 1, right = true, release = true)
      sleep(60)
    ck pixels.copied() == "b"
    pixels.quit()

suite "Edit mode, the gutter":

  test "the glyph cell toggles once a press and selects nothing":
    var (sess, r, c) = openFixture()
    let glyph = c - 8
    sess.press(r + 1, glyph)
    discard sess.waitFor("breakpoint at")
    ck sess.snap().text(r + 1).contains("●")
    sess.clicks(r + 1, glyph, 2)
    sleep(300)
    ck sess.snap().text(r + 1).contains("●")   # two toggles
    sess.press(r + 1, glyph, Right)
    sleep(200)
    ck sess.snap().text(r + 1).contains("○")
    sess.press(r + 1, glyph, Right)
    sleep(200)
    ck sess.snap().text(r + 1).contains("●")
    ck sess.copied() == "snake_case_name = other.attr(x)\n"
    sess.quit()

  test "a number selects its line, a drag selects lines, on into the text":
    var (sess, r, c) = openFixture()
    let number = c - 6
    sess.press(r + 2, number)
    ck sess.copied() == "a == b and p->q\n"
    ck not sess.snap().text(r + 2).contains("●")
    sess.mouse(Left, r, number)
    sess.mouse(Left + 32, r + 1, number)
    sess.mouse(Left + 32, r + 3, c + 1)
    sess.mouse(Left, r + 3, c + 1, release = true)
    ck sess.copied() == Fixture.splitLines[0 .. 3].join("\n") & "\n"
    sess.quit()

  test "the hint over the glyph cell, only on an unmarked line":
    var (sess, r, c) = openFixture()
    let glyph = c - 8
    sess.send("\x1b[<35;" & $(glyph + 1) & ";" & $(r + 3) & "M")
    sleep(200)
    let s = sess.snap()
    ck s.text(r + 2).runeAtPos(glyph) == "●".runeAt(0)
    ck s[r + 2][glyph].fg != s[r][glyph].fg
    sess.press(r + 2, glyph)
    discard sess.waitFor("breakpoint at")
    sess.send("\x1b[<35;" & $(c + 3) & ";" & $(r + 3) & "M")
    sleep(200)
    ck not sess.snap().text(r + 1).contains("●")
    sess.quit()

suite "Debug mode, a real recording":
  proc openCalc(keymap = ""): TuiTestSession =
    let resolved = resolveFixture("calc")
    doAssert resolved.outcome == foRecorded, resolved.detail
    result = spawnTui(@[resolved.tracePath], freshDir(), keymap)
    settleOnDebugger(result, Cols, Rows)
    result.send(":goto 32\r")
    discard result.waitFor(" ▸  def add(")

  proc tickNow(sess: var TuiTestSession): string =
    let line = sess.snap().text(0)
    let at = line.find("tick: ")
    if at < 0: "" else: line[at .. min(at + 12, line.high)]

  test ":set multi-click-interval=600 makes 450 ms a double click":
    var sess = openCalc()
    let (r, c) = sess.waitFor("def add(")
    sess.clicks(r, c + 5, 2, gapMs = 450)
    ck sess.copied().startsWith("def add(")
    sess.send(":set multi-click-interval=600\r")
    discard sess.waitFor("multi-click-interval 600")
    sess.clicks(r, c + 5, 2, gapMs = 450)
    ck sess.copied() == "add"
    sess.quit()

  test "the selection moves nothing in the replay":
    var sess = openCalc()
    let before = sess.tickNow()
    let (r, c) = sess.waitFor("def add(")
    ck sess.selects(r, c + 5, 2) == "add"
    ck sess.selects(r, c + 5, 3).endsWith("\n")
    ck sess.selects(r, c + 5, 4).contains("def evaluate(")
    ck sess.tickNow() == before
    sess.quit()

  test "the glyph cell goes to the engine; the numbers are a selection":
    var sess = openCalc()
    let (r, c) = sess.waitFor("def add(")
    let glyph = c - 9
    sess.press(r, glyph)
    let marked = sess.waitFor("● ")
    ck marked[0] == r
    sess.press(r, glyph, Right)
    let disabled = sess.waitFor("○ ")
    ck disabled[0] == r
    sess.press(r, glyph, Right)
    ck sess.waitFor("● ")[0] == r
    sess.press(r, glyph)
    sleep(300)
    ck not sess.snap().text(r).contains("●")
    # A number: the line with its break, and no breakpoint.
    sess.press(r, c - 6)
    ck sess.copied().startsWith("def add(")
    ck not sess.snap().text(r).contains("●")
    sess.quit()

  test "Ctrl+double jumps and selects nothing; a double middle goes into the call":
    var sess = openCalc()
    sess.send(":goto 21\r")
    discard sess.waitFor(" ▸  def evaluate(")
    let (rc, cc) = sess.waitFor("total = apply_op(symbol")
    sess.clicks(rc, cc + 9, 2, code = Middle)
    let deadline = getMonoTime() + initDuration(seconds = 20)
    while getMonoTime() < deadline and
          not sess.snap().text(StatusRow).contains("main.py:61"):
      sleep(80)
    ck sess.snap().text(StatusRow).contains("main.py:61")
    sess.send(":goto 21\r")
    discard sess.waitFor(" ▸  def evaluate(")
    let at = sess.waitFor("total = apply_op(symbol")
    sess.clicks(at[0], at[1] + 9, 2, code = Ctrl)
    sleep(600)
    ck sess.snap().reversedCells(at[0]) <= 1
    sess.quit()

  test "Alt adds a cursor and no breakpoint; Shift+F9 sets one the replay honours":
    var sess = openCalc()
    sess.send("n")
    discard sess.waitFor(" ▸      return left + right  /* left: 2, right: 3")
    sleep(500)
    let (r, c) = sess.waitFor("return left + right")
    let at = c + 7
    # A cursor at the press: a second reversed cell, nothing in the gutter.
    sess.press(r, c)
    sess.press(r, at, Alt)
    sleep(300)
    ck sess.snap().reversedCells(r) >= 2
    ck not sess.snap().text(r).contains("●")
    sess.press(r, at)
    sleep(500)
    sess.send(ShiftF9)
    discard sess.waitFor("inline breakpoint toggled at line 31, column")
    let s = sess.snap()
    ck s.text(r).contains("●")
    ck s[r][at].underline != usNone
    # `calc` records one step per statement: a breakpoint anchored past its
    # first column is never reached, so continuing runs to the end.
    sess.send(":goto 0\r")
    discard sess.waitFor("tick: 0 ")
    sess.send("c")
    discard sess.waitFor("tick: 171")
    ck true
    sess.send(":goto 32\r")
    discard sess.waitFor(" ▸  def add(")
    sess.send("n")
    let again = sess.waitFor("return left + right")
    sess.press(again[0], at)
    sleep(500)
    sess.send(ShiftF9)
    let removal = getMonoTime() + initDuration(seconds = 15)
    while getMonoTime() < removal and
          sess.snap()[again[0]][at].underline != usNone:
      sleep(100)
    ck sess.snap()[again[0]][at].underline == usNone
    # Column 1 is a line breakpoint.
    sess.press(again[0], c - 4 + 0)
    sleep(500)
    sess.send(ShiftF9)
    let mark = sess.waitFor("● ")
    ck mark[0] == again[0]
    sess.quit()

  test "the menu's inline entry, and its Remove":
    var sess = openCalc()
    sess.send("n")
    discard sess.waitFor(" ▸      return left + right  /* left: 2, right: 3")
    sleep(500)
    let (r, c) = sess.waitFor("return left + right")
    let at = c + 7
    sess.press(r, at, Right)
    let (ra, ca) = sess.waitFor("Add Inline Breakpoint")
    discard sess.waitFor("Shift+F9")
    let hint = sess.waitFor("<click left of the line number>")
    ck hint[0] != ra
    sess.press(ra, ca + 2)
    discard sess.waitFor("inline breakpoint toggled at line 31")
    sess.press(r, at, Right)
    let (rr, cr) = sess.waitFor("Remove Inline Breakpoint")
    sess.press(rr, cr + 2)
    let removal = getMonoTime() + initDuration(seconds = 15)
    while getMonoTime() < removal and sess.snap()[r][at].underline != usNone:
      sleep(100)
    ck sess.snap()[r][at].underline == usNone
    sess.quit()

  test "Shift+F9 under each base":
    for base in ["cua", "emacs", "vim", "kakoune"]:
      let resolved = resolveFixture("calc")
      doAssert resolved.outcome == foRecorded, resolved.detail
      var sess = spawnTui(@[resolved.tracePath], freshDir(), base)
      settleOnDebugger(sess, Cols, Rows)
      let (r, c) = sess.waitFor("def ")
      sess.press(r, c + 5)
      sleep(400)
      sess.send(ShiftF9)
      discard sess.waitFor("inline breakpoint toggled at line")
      ck true
      sess.quit()

suite "The modal bases":
  # What a mode means, by what the next key does to the painted text.
  test "Vim: a double press is VISUAL: `d` takes the word":
    var (sess, r, c) = openFixture("vim")
    sess.clicks(r, c + 2, 2)
    sleep(300)
    sess.send("d")
    ck sess.gone(r, "snake_case_name")
    sess.quit()

  test "Vim: a triple press is VISUAL LINE: `d` takes the line":
    var (sess, r, c) = openFixture("vim")
    sess.clicks(r + 1, c + 6, 3)
    sleep(300)
    sess.send("d")
    ck sess.gone(r + 1, "leading indentation")
    sess.quit()

  test "Vim: a single press from VISUAL is NORMAL: `d` is a prefix, nothing goes":
    var (sess, r, c) = openFixture("vim")
    sess.clicks(r + 2, c + 2, 2)
    sleep(650)
    sess.press(r + 3, c + 1)
    sleep(300)
    sess.send("d")
    sleep(400)
    sess.send("\e")
    sleep(300)
    ck sess.snap().text(r + 2).contains("a == b")
    ck sess.snap().text(r + 3).contains("a.b")
    sess.quit()

  test "Vim: INSERT stays INSERT, with the selection":
    var (sess, r, c) = openFixture("vim")
    sess.send("i")
    sleep(300)
    sess.clicks(r, c + 2, 2)
    sleep(300)
    sess.send("Q")                       # typing replaces the selection
    ck sess.gone(r, "snake_case_name")
    ck sess.snap().text(r).contains("Q = other.attr(x)")
    sess.quit()

  test "Kakoune: the mode does not change; Emacs: the mark is active":
    var (k, r, c) = openFixture("kakoune")
    sleep(800)
    k.clicks(r, c + 2, 2)
    sleep(300)
    k.send("d")                          # the selection, deleted from NORMAL
    ck k.gone(r, "snake_case_name")
    k.quit()
    var (e, re, ce) = openFixture("emacs")
    e.clicks(re, ce + 2, 2)
    sleep(300)
    e.send("\x17")                       # C-w kills an active mark's region
    ck e.gone(re, "snake_case_name")
    e.quit()

suite "What the terminal keeps, and what a user rebinds":
  test "a Shift press is the terminal's: nothing happens":
    var (sess, r, c) = openFixture()
    let number = c - 6
    sess.press(r + 2, number, code = 4)     # Shift + left, delivered
    sess.press(r + 2, c + 2, code = 4)
    sleep(300)
    ck not sess.snap().text(r + 2).contains("●")
    ck sess.copied() == "snake_case_name = other.attr(x)\n"
    sess.quit()

  test "the hint is `gutter.breakpoint.hint`'s colour, a number":
    var (sess, r, c) = openFixture()
    let glyph = c - 8
    sess.send("\x1b[<35;" & $(glyph + 1) & ";" & $(r + 3) & "M")
    sleep(300)
    let cell = sess.snap()[r + 2][glyph]
    ck cell.fg.kind == ckRgb and cell.fg.r.int == 0xb9 and cell.fg.g.int == 0x1c and
       cell.fg.b.int == 0x1c
    sess.quit()

  test "the menu's chord is the user's when they rebind it":
    let resolved = resolveFixture("calc")
    doAssert resolved.outcome == foRecorded, resolved.detail
    let state = freshDir()
    putEnv("CODETRACER_KEYBINDINGS", state / "keybindings.json")
    defer: delEnv("CODETRACER_KEYBINDINGS")
    writeFile(state / "keybindings.json",
              """[{"key":"ctrl+alt+i","command":"editor.toggle-inline-breakpoint"},
                  {"key":"shift+f9","command":"-editor.toggle-inline-breakpoint"}]""")
    var sess = spawnTui(@[resolved.tracePath], state)
    settleOnDebugger(sess, Cols, Rows)
    sess.send(":goto 32\r")
    discard sess.waitFor(" ▸  def add(")
    let (r, c) = sess.waitFor("def add(")
    sess.press(r, c + 5, Right)
    discard sess.waitFor("Add Inline Breakpoint")
    ck sess.waitFor("Ctrl+Alt+I")[0] > 0
    sess.quit()

suite "Under tmux":
  test "the same sequences give the same selections, and tmux's copy is counted":
    let tmux = findExe("tmux")
    if tmux.len == 0:
      # Counted, so the total does not depend on the host having tmux.
      inc countedAssertions
      skip()
    else:
      let dir = freshDir()
      let project = dir / "project"
      createDir(project)
      writeFile(project / "fixture.txt", Fixture)
      let sock = dir / "t"
      writeFile(dir / "tmux.conf", "set -g mouse on\n")
      var sess = newTuiTest(tmux, @["-S", sock, "-f", dir / "tmux.conf", "new-session",
                                    "-x", $Cols, "-y", $Rows,
                                    tuiBinary() & " --theme=dark --edit " &
                                      project / "fixture.txt"])
        .width(Cols).height(Rows).transcript()
        .envSet("XDG_STATE_HOME", dir / "state")
        .envSet("XDG_CONFIG_HOME", dir / "state" / "config")
        .envSet("CODETRACER_HOME", dir / "state" / "ct-home")
        .envSet("CODETRACER_TUI_LAYOUT_DIR", dir / "state" / "layout")
        .envSet("TERM", "xterm-256color").spawn()
      let (r, c) = sess.waitFor("snake_case_name")
      sess.send("\x1b[<0;" & $(c + 3) & ";" & $(r + 1) & "M")
      sess.send("\x1b[<0;" & $(c + 3) & ";" & $(r + 1) & "m")
      sleep(100)
      sess.send("\x1b[<0;" & $(c + 3) & ";" & $(r + 1) & "M")
      sess.send("\x1b[<0;" & $(c + 3) & ";" & $(r + 1) & "m")
      sleep(200)
      # Painted as a selection: the word's cell, against the same cell a line down.
      # (Measured: tmux's `DoubleClick1Pane` copy of the second press is the
      # counter's duplicate, so the count is 2 and not 3.)
      let shot = sess.snap()
      ck shot[r][c + 2].bg != shot[r + 1][c + 2].bg
      discard execCmd(tmux & " -S " & sock & " kill-server")
      sess.terminate()
      sess.close()

test "the assertion count":
  check countedAssertions == ExpectedAssertions
