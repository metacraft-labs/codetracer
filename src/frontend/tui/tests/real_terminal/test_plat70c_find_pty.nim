## test_plat70c_find_pty.nim — PLAT-70 Part C (Find-And-Incremental-Search.md
## §3, §4), the shipped `codetracer-tui` on a REAL pseudo-terminal
## (TermAssert: a real pty, the screen read back through libvterm):
##
##   * CUA, over a real recording's source in the READ-ONLY Debug editor
##     (`calc` against the real `replay-server`): `Ctrl+F` with the caret in a
##     word opens the field seeded with it; a query typed one character at a
##     time highlights exactly `matchesOf`'s spans after every key — read off
##     the painted cells' grounds, the current match told apart (FS-3) — and
##     the count is shown; `Enter` / `F3` / `Shift+F3` walk them and the wrap
##     is reported; `Escape` closes and keeps the match selected (FS-5, the
##     user's OQ-F1: `Ctrl+C` copies the match); the palette's **Find: Cancel
##     and Return** puts the selection and both scroll offsets back
##     byte-for-byte (FS-4: the editor's rows read before and after, on
##     `wide_lines`, whose match is far to the right); `Ctrl+F3` with the
##     widget closed selects the next WHOLE-WORD occurrence; the execution
##     pointer and the tick never move;
##   * Vim, in Edit mode over a real project file: `*` moves to the next
##     whole-word occurrence, `n` continues, `#` goes back, `g*` matches
##     inside longer words; `/foo Escape` abandons the search and the cursor
##     returns; `/foo Enter` keeps and `n` continues (FS-2);
##   * Kakoune: `[ w *` (this base's `<a-i> w *`) then `n` finds the word's
##     next occurrence; `s` no longer sets the search pattern;
##   * Emacs: `C-s`, typing, `C-w` twice pulls two words, `C-s` walks, `C-g`
##     restores; `M-s .` on a symbol finds its next occurrence; `Enter`
##     keeps.
##
## No mocks: the binary, the engine and the recordings are real; the Edit
## mode project is a real directory with a real file the binary reads.

import std/[algorithm, base64, monotimes, os, strutils, times, unicode, unittest]

import term_assert
import nim_libvterm

import codetracer_embed

import ../fixtures/fixture_provider
import ./lifecycle_support
import ../../app/theme/colour_math
import ../../app/theme/roles
from ../../host/terminal_probe import ReplyWindowMs

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 36

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 200
  Rows = 50
  StatusRow = Rows - 1
  CtrlC = "\x03"
  CtrlF = "\x06"
  CtrlG = "\x07"
  CtrlP = "\x10"
  CtrlQ = "\x11"
  CtrlS = "\x13"
  CtrlW = "\x17"
  F1 = "\eOP"
  F3 = "\eOR"
  CtrlF3 = "\e[1;5R"
  Esc = "\e"
  ProjectText = "foo bar foobar\n" &
                "baz foo qux\n" &
                "one two three foo\n" &
                "foo_x foo\n"

type Snapshot = seq[seq[Cell]]

var spawned = 0

proc freshDir(): string =
  inc spawned
  result = getTempDir() / ("plat70c-pty-" & $getCurrentProcessId() & "-" &
                           $spawned)
  removeDir(result)
  createDir(result)

proc withEnv(b: TuiTestBuilder; state: string): TuiTestBuilder =
  b.width(Cols).height(Rows).transcript()
    .envRemove("TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE", "TMUX", "STY",
               "NERD_FONT", "NERDFONT", "COLORFGBG")
    .envSet("TERM", "xterm-256color").envSet("LANG", "en_US.UTF-8")
    .envSet("COLORTERM", "truecolor")
    .envSet("XDG_STATE_HOME", state)
    .envSet("XDG_CONFIG_HOME", state / "config")
    .envSet("CODETRACER_HOME", state / "ct-home")
    .envSet("CODETRACER_TUI_LAYOUT_DIR", state / "layout")

var settledAt: MonoTime
  ## When the last `openReplay` saw the debugger's first frame settle
  ## (`afterReplyWindow`). The start-up round is written before that frame,
  ## so its reply window opened earlier than this, however loaded the
  ## machine is; timing the wait from the spawn instead was too short when
  ## the binary was slow to start.

proc openReplay(fixture: string; extra: seq[string] = @[]): TuiTestSession =
  let resolved = if fixture == "wide_lines":
                   resolveFixture(FixtureSpec(
                     name: "wide_lines",
                     program: "test-programs/wide_lines/main.py",
                     recorder: "codetracer-python-recorder",
                     probe: FixtureProbe(kind: pkPythonRecorder),
                     buildHint: "Install codetracer_python_recorder into " &
                                "the interpreter `ct` will use.",
                     blockedOn: ""))
                 else: resolveFixture(fixture)
  doAssert resolved.outcome == foRecorded, resolved.detail
  let state = freshDir()
  result = newTuiTest(tuiBinary(), @["--theme=dark"] & extra &
                      @[resolved.tracePath]).withEnv(state).spawn()
  settleOnDebugger(result, Cols, Rows)
  settledAt = getMonoTime()

proc afterReplyWindow(sess: var TuiTestSession) =
  ## The pty's terminal answers none of the start-up round, so the round's
  ## reply window stays open for `ReplyWindowMs`, and inside it a
  ## `CSI 1 ; 5 R` is taken for a cursor report — Terminal-Adaptation §4.3's
  ## documented loss. A test that types legacy xterm's Ctrl+F3 waits it out.
  let closesAt = settledAt + initDuration(milliseconds = ReplyWindowMs + 500)
  while getMonoTime() < closesAt:
    discard sess.drainOutput(50)

proc snap(sess: var TuiTestSession): Snapshot =
  discard sess.drainOutput(80)
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

proc findRow(s: Snapshot; needle: string): (int, int) =
  for r in 0 ..< Rows:
    let c = s.text(r).cellFind(needle)
    if c >= 0: return (r, c)
  (-1, -1)

proc status(s: Snapshot): string = s.text(StatusRow).strip()

proc waitUntil(sess: var TuiTestSession; what: string;
               cond: proc(s: Snapshot): bool; timeoutMs = 20000): Snapshot =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    result = sess.snap()
    if cond(result): return
    sleep(40)
  var dump = ""
  for r in 0 ..< Rows: dump.add result.text(r) & "\n"
  raise newException(AssertionFailedError, "never: " & what & "\n" & dump)

proc mouse(sess: var TuiTestSession; code, row, col: int; release = false) =
  sess.send("\x1b[<" & $code & ";" & $(col + 1) & ";" & $(row + 1) &
            (if release: "m" else: "M"))

proc press(sess: var TuiTestSession; row, col: int) =
  sess.mouse(0, row, col)
  sess.mouse(0, row, col, release = true)

proc key(sess: var TuiTestSession; bytes: string) =
  sess.send(bytes)
  discard sess.drainOutput(if bytes == Esc: 300 else: 60)

proc quit(sess: var TuiTestSession) =
  sess.send(CtrlQ)
  discard sess.waitExit(initDuration(seconds = 15))
  sess.terminate()
  sess.close()

proc bgHex(c: Cell): string =
  if c.bg.kind == ckRgb: hexOf((c.bg.r.int, c.bg.g.int, c.bg.b.int)) else: ""

let
  matchHex = tokenHex(RoleSpecs[srSurfaceFindMatch].bg, dmDark)
  currentHex = tokenHex(RoleSpecs[srSurfaceFindMatchCurrent].bg, dmDark)
  selectionHex = tokenHex(RoleSpecs[srSurfaceSelection].bg, dmDark)

proc tick(s: Snapshot): int =
  let line = s.text(0)
  let at = line.find("tick: ")
  if at < 0: return -1
  var digits = ""
  for c in line[at + "tick: ".len .. ^1]:
    if c in {'0' .. '9'}: digits.add c
    elif c == ',': discard
    else: break
  if digits.len == 0: -1 else: parseInt(digits)

proc pointerRow(s: Snapshot): int =
  ## The screen row the execution pointer's band is on (`-->`).
  for r in 0 ..< Rows:
    if s.text(r).contains("-->"): return r
  -1

type Painted = tuple[found: seq[int], current: seq[int]]
  ## The cells of a row painted on the find ground, and on the current
  ## match's, as column offsets from the code's first cell.

proc paintedOn(s: Snapshot; row, code, width: int): Painted =
  for c in code ..< min(Cols, code + width):
    let h = s[row][c].bgHex
    if h == matchHex: result.found.add c - code
    elif h == currentHex: result.current.add c - code

proc expectedOn(line, query: string; opts: MatchOptions): seq[int] =
  for m in matchesOf(line, query, opts):
    for c in line[0 ..< m.a].runeLen ..< line[0 ..< m.b].runeLen:
      result.add c

# ---------------------------------------------------------------------------

let calcLines = readFile(lifecycle_support.repoRoot() / "test-programs/calc/main.py").splitLines

proc shownLines(s: Snapshot): seq[tuple[row, code, line: int]] =
  ## Every editor row whose text is a calc line long enough to be told
  ## apart, located by its text: (screen row, first code cell, 1-based line).
  for i, l in calcLines:
    if l.strip.len < 18: continue
    var hits = 0
    for other in calcLines:
      if other == l: inc hits
    if hits != 1: continue
    let (r, c) = s.findRow(l)
    if r >= 0: result.add (r, c, i + 1)

suite "PLAT-70 Part C on a real terminal: CUA in the read-only Debug editor":

  test "Ctrl+F seeds; typing highlights matchesOf's spans after every key (FS-3)":
    var sess = openReplay("calc")
    let first = sess.snap()
    let t0 = first.tick
    let pointer = first.pointerRow
    let shown = first.shownLines
    doAssert shown.len >= 5, "calc's source is not on the screen"
    # The caret into `left` on calc's line 31, `    return left + right`,
    # a line shown whole — so the current match of every query below is on a
    # line whose every cell is on the screen.
    let (seedRow, at31) = first.findRow("    return left + right")
    doAssert seedRow >= 0, "calc's line 31 is not on the screen"
    let seedCol = at31 + "    return le".len
    let seedWord = "left"
    sess.press(seedRow, seedCol)
    sess.key(CtrlF)
    let opened = sess.waitUntil("the seeded field", proc(s: Snapshot): bool =
      s.status.contains(seedWord) and s.status.contains(" of "))
    ck opened.status.contains(seedWord)
    # Typing replaces the selected seed, one character at a time.
    let opts = MatchOptions(caseSensitive: false)
    # Every prefix's first match at or after the caret is `right` on the same
    # line, so the view moves neither way while the query is typed.
    let query = "rig"
    var typed = ""
    for ch in query:
      typed.add ch
      sess.key($ch)
      let want = typed
      proc agreeing(s: Snapshot): bool =
        if not s.status.contains(want): return false
        for sh in s.shownLines:
          let l = calcLines[sh.line - 1]
          let p = s.paintedOn(sh.row, sh.code, l.runeLen)
          var all = p.found & p.current
          all.sort()
          if all != expectedOn(l, want, opts): return false
        true
      # A frame is drawn whole before it is read: wait (bounded) for the
      # highlights of this key, then grade the screen as it then stands.
      discard sess.waitUntil("the field holds `" & want & "`",
        proc(s: Snapshot): bool = s.status.contains(want))
      let s = block:
        var last = sess.snap()
        let until = getMonoTime() + initDuration(seconds = 5)
        while not last.agreeing and getMonoTime() < until:
          sleep(100)
          last = sess.snap()
        last
      var agree, current = 0
      for sh in s.shownLines:
        let l = calcLines[sh.line - 1]
        let p = s.paintedOn(sh.row, sh.code, l.runeLen)
        let painted = p.found & p.current
        var sorted = painted
        sorted.sort()
        if sorted == expectedOn(l, typed, opts): inc agree
        if p.current.len > 0: inc current
      checkpoint("query `" & typed & "`: " & $agree & " of " &
                 $s.shownLines.len & " rows agree")
      ck agree == s.shownLines.len
      ck current == 1
      ck s.status.contains(" of ")
    # The walk: Enter, F3, Shift+F3, and the wrap reported.
    proc currentAt(s: Snapshot): (int, int) =
      for sh in s.shownLines:
        let p = s.paintedOn(sh.row, sh.code, calcLines[sh.line - 1].runeLen)
        if p.current.len > 0: return (sh.line, p.current[0])
      (-1, -1)
    let c0 = sess.snap().currentAt
    sess.key("\r")
    let c1 = sess.waitUntil("Enter walked", proc(s: Snapshot): bool =
      s.currentAt != c0).currentAt
    sess.key(F3)
    let c2 = sess.waitUntil("F3 walked", proc(s: Snapshot): bool =
      s.currentAt != c1).currentAt
    # The walk BACK is not driven here: `Shift+F3` is `CSI 1 ; 2 R` on a
    # legacy terminal, the bytes of a cursor-position report, and
    # `Shift+Enter` needs the kitty protocol libvterm does not negotiate; the
    # session's backward step is graded in `test_plat70c_find_vm.nim` and in
    # GPUI's window plan (`Shift+F3`).
    ck c1 != c0 and c2 != c1
    let total = matchesOf(calcLines.join("\n"), typed, opts).len
    var wrapped = false
    for _ in 0 .. total:
      let before = sess.snap().status
      sess.key(F3)
      # Each step's status is read once its frame is drawn.
      let after = block:
        var last = sess.snap().status
        let until = getMonoTime() + initDuration(milliseconds = 2000)
        while last == before and getMonoTime() < until:
          sleep(50)
          last = sess.snap().status
        last
      if "search hit BOTTOM" in after:
        wrapped = true
        break
    ck wrapped
    # Escape closes and KEEPS the match selected (OQ-F1): the field is gone,
    # and Ctrl+C copies the match.
    sess.key(Esc)
    let closed = sess.waitUntil("the field closed", proc(s: Snapshot): bool =
      "CUA [DEBUG]" in s.status)
    ck "FIND [" notin closed.status
    sess.key(CtrlC)
    discard sess.waitUntil("copied", proc(s: Snapshot): bool =
      "copied" in s.status)
    ck sess.transcriptBytes().contains("\e]52;c;" & base64.encode(typed))
    # The read-only editor: the pointer and the tick did not move.
    let after = sess.snap()
    ck after.tick == t0
    ck after.pointerRow == pointer or pointer < 0
    sess.quit()

  test "Ctrl+F3 with the widget closed selects the next WHOLE-WORD occurrence":
    var sess = openReplay("calc")
    let s0 = sess.snap()
    # `left` occurs as a word (`left + right`) and inside no longer word on
    # the lines of `add`; `def add(left, right):` holds it.
    let (r, c) = s0.findRow("def add(left, right):")
    doAssert r >= 0, "calc's `add` is not on the screen"
    sess.press(r, c + "def add(le".len)     # the caret inside `left`
    sess.afterReplyWindow()
    sess.key(CtrlF3)
    let s1 = sess.waitUntil("a match selected", proc(s: Snapshot): bool =
      "`left` at line" in s.status)
    let at = s1.status
    let line = parseInt(at[at.find("at line ") + "at line ".len .. ^1].strip.split(' ')[0])
    let src = calcLines[line - 1]
    ck src.contains("left")
    # Whole word: the match's line has `left` with no word letter around it.
    let w = matchesOf(src, "left", MatchOptions(caseSensitive: false,
                                                wholeWord: true))
    ck w.len > 0
    ck line > 29
    ck "FIND [" notin s1.status
    sess.quit()

  test "Find: Cancel and Return puts the selection and both offsets back (FS-4)":
    var sess = openReplay("wide_lines")
    let s0 = sess.snap()
    let (r, c) = s0.findRow("def emit(text):")
    doAssert r >= 0, "wide_lines' source is not on the screen"
    sess.press(r, c + 4)
    let before = sess.snap()
    var editorRows: seq[string] = @[]
    # The editor's cells only (the panes beside it carry their own state:
    # a scrollbar's fade, the call trace's).
    let editorCells = c + 70
    for row in 1 ..< StatusRow:
      editorRows.add before.text(row).runeSubStr(0, editorCells)
    sess.key(CtrlF)
    discard sess.waitUntil("the field", proc(s: Snapshot): bool =
      s.status.startsWith("/"))
    for ch in "RIGHT-EDGE": sess.key($ch)
    # The match is far to the right: the view scrolled sideways to it, so
    # the source line's start is no longer drawn (the Terminal Output pane
    # shows the same text as output; the source line's own start is
    # `WIDE_SOURCE = "`).
    let moved = sess.waitUntil("the view scrolled to the match",
      proc(s: Snapshot): bool = s.findRow("WIDE_SOURCE = \"<<LEFT")[0] < 0)
    ck moved.findRow("WIDE_SOURCE = \"<<LEFT")[0] < 0
    # The palette's entry.
    sess.key(F1)
    # The palette's `:` line lists its commands.
    for ch in ":Cancel and Return": sess.key($ch)
    discard sess.waitUntil("the palette's entry", proc(s: Snapshot): bool =
      s.findRow("Find: Cancel and Return")[0] >= 0)
    sess.key("\r")
    discard sess.waitUntil("the view back", proc(s: Snapshot): bool =
      s.findRow("WIDE_SOURCE = \"<<LEFT")[0] >= 0 and "PALETTE" notin s.status)
    proc sameRows(s: Snapshot): int =
      for row in 1 ..< StatusRow:
        if s.text(row).runeSubStr(0, editorCells) == editorRows[row - 1]:
          inc result
    let restored = block:
      var last = sess.snap()
      let until = getMonoTime() + initDuration(seconds = 5)
      while last.sameRows < StatusRow - 3 and getMonoTime() < until:
        sleep(100)
        last = sess.snap()
      last
    var same = 0
    for row in 1 ..< StatusRow:
      if restored.text(row).runeSubStr(0, editorCells) == editorRows[row - 1]:
        inc same
    checkpoint("rows equal to before: " & $same & " of " & $(StatusRow - 1))
    # Every row of the window but the status line and the caret's own
    # (whose ground is the caret's) is the same text as before the find.
    ck same >= StatusRow - 3
    ck restored.findRow("def emit(text):") == (r, c)
    sess.quit()

suite "PLAT-70 Part C on a real terminal: Vim, Kakoune and Emacs in Edit mode":
  ## Where the caret is, is read OFF THE DISK: a marker typed at it and the
  ## file saved through the base's own save, then the marker's line and
  ## column in the bytes written — the terminal's caret is drawn by the
  ## terminal itself, which a screen read cannot locate in NORMAL mode.

  proc run(base: string; keys: seq[string]; status = "";
          after: seq[string] = @[]; screen: ptr Snapshot = nil):
      tuple[text, shown: string] =
    let state = freshDir()
    let project = state / "project"
    createDir(project)
    writeFile(project / "find.txt", ProjectText)
    var sess = newTuiTest(tuiBinary(), @["--theme=dark", "--keymap=" & base,
                                         "--edit", project])
                 .withEnv(state).envSet("CT_TUI_PROBE_TIMEOUT_MS", "4000").spawn()
    # The start-up probe answered as a terminal without the kitty protocol.
    let deadline = getMonoTime() + initDuration(seconds = 20)
    while getMonoTime() < deadline:
      discard sess.drainOutput(20)
      if sess.transcriptBytes().contains("\e[?u"): break
    sess.send("\e[?62;22c")
    let s0 = sess.waitUntil("the editor", proc(s: Snapshot): bool =
      s.findRow("foo bar foobar")[0] >= 0)
    let (r0, c0) = s0.findRow("foo bar foobar")
    sess.press(r0, c0)
    sleep(300)
    for k in keys:
      if k == "<pause>": sleep(300)
      else: sess.key(k)
      sleep(60)
    if status.len > 0:
      result.shown = sess.waitUntil("`" & status & "` in the status line",
        proc(s: Snapshot): bool = s.status.contains(status)).status
    for k in after:
      sess.key(k)
      sleep(60)
    if screen != nil:
      sleep(300)
      screen[] = sess.snap()
    # The find field closed (its prompt gone from the status line) before
    # the marker is typed into the document.
    discard sess.waitUntil("the find field closed", proc(s: Snapshot): bool =
      not s.status.startsWith("/") and not s.status.startsWith("?"))
    sleep(200)
    # The marker, then the base's save.
    case base
    of "emacs": sess.key("#"); sess.key("\x18"); sess.key("\x13")
    of "kakoune":
      # Kakoune's `n` selects from the caret to the match; `a` appends at the
      # selection's end — the match's start.
      sess.key("a"); sess.key("#"); sess.key(Esc); sess.key("\x13")
    else: sess.key("i"); sess.key("#"); sess.key(Esc); sess.key("\x13")
    discard sess.waitUntil("written", proc(s: Snapshot): bool =
      "wrote" in s.status)
    result.text = readFile(project / "find.txt")
    sess.quit()

  proc markAt(text: string): (int, int) =
    let ls = text.splitLines
    for i in 0 ..< ls.len:
      let c = ls[i].find('#')
      if c >= 0: return (i + 1, c)
    (-1, -1)

  test "Vim: * moves whole-word, n continues, # goes back, g* matches inside":
    ck run("vim", @["g", "g", "*"]).text.markAt == (2, 4)  # `baz foo`
    ck run("vim", @["g", "g", "*", "n"]).text.markAt == (3, 14)
    ck run("vim", @["g", "g", "*", "n", "#"]).text.markAt == (2, 4)
    ck run("vim", @["g", "g", "g", "*"]).text.markAt == (1, 8)  # in `foobar`

  test "Vim: /foo Escape returns the cursor; /foo Enter keeps, n continues":
    ck run("vim", @["g", "g", "j", "/", "t", "h", "r", "e", "e", "<pause>",
                    Esc, "<pause>"]).text.markAt == (2, 0)
    ck run("vim", @["g", "g", "j", "/", "f", "o", "o", "\r"]).text.markAt ==
         (2, 4)
    ck run("vim", @["g", "g", "j", "/", "f", "o", "o", "\r", "n"]).text.markAt ==
         (3, 14)

  test "Kakoune: [ w * then n finds the next occurrence; s sets no pattern":
    ## Kakoune's `n` SELECTS from the caret to the next match, so where it
    ## landed is read off the selection's ground on the screen: it ends just
    ## before the match.
    proc selectedTo(s: Snapshot; line: int): int =
      ## The first unselected code cell of `line` (1-based), from its start.
      let (r0, c0) = s.findRow("foo bar foobar")
      let row = r0 + line - 1
      result = 0
      while c0 + result < Cols and s[row][c0 + result].bgHex == selectionHex:
        inc result
    var s1, s2: Snapshot
    discard run("kakoune", @["g", "g", "[", "w", "*", "n"], screen = addr s1)
    ck s1.selectedTo(2) == 4          # `baz foo`: selected up to its `foo`
    discard run("kakoune", @["g", "g", "[", "w", "*", "n", "s", "n"],
                screen = addr s2)
    ck s2.selectedTo(3) == 14         # `one two three foo`: the pattern held

  test "Emacs: C-s, C-w twice pulls two words, C-g restores; M-s . ; Enter keeps":
    let pulled = run("emacs", @[CtrlS, CtrlW, CtrlW], status = "foo bar",
                     after = @["\r"])
    ck pulled.shown.contains("foo bar")
    ck run("emacs", @[CtrlS, CtrlW, CtrlW, CtrlS, CtrlG, "<pause>"]).text.markAt ==
         (1, 0)
    let symbol = run("emacs", @["\es", ".", "<pause>", "\r"]).text
    ck symbol.splitLines[1] != ProjectText.splitLines[1]   # the match on line 2
    ck symbol.splitLines[0] == ProjectText.splitLines[0]

suite "PLAT-70 Part C: the tally":
  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
