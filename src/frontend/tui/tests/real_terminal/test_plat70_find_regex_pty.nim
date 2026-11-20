## test_plat70_find_regex_pty.nim — the in-document find's regular expressions
## and Find in Selection (Find-And-Incremental-Search.md OQ-F5, the user's
## decision of 2026-11-20) in the shipped `codetracer-tui` on a REAL
## pseudo-terminal (TermAssert: a real pty, the screen read back through
## libvterm), under CUA in Edit mode over a real project file:
##
##   * `Alt+R` reads the field as a regular expression: the status line marks
##     it (`[.*]`), and the painted cells of every shown line are exactly
##     `matchesOf`'s spans with `regex` — read off the cells' grounds, which
##     are the design system's find tokens (OQ-F6, `RoleSpecs`); `Alt+R`
##     again reads it literally; an expression that does not compile says why;
##   * `Alt+L` with lines selected confines the search to them (`[in
##     selection]`, the count and the painted cells inside the selection
##     only), and off again searches the whole file; with nothing selected it
##     says that it needs a selection.
##
## EVERY WAIT IS ON THE SCREEN'S STATE, never on a clock: each step's effect
## is a status-line text or a painted cell, polled until it holds (or a
## generous deadline names what never happened), so a host at load 150 is
## slower, not wrong.
##
## No mocks: the binary is the shipped one and the project is a real directory
## with a real file the binary reads.

import std/[algorithm, monotimes, os, strutils, times, unicode, unittest]

import term_assert
import nim_libvterm

import codetracer_embed

import ./lifecycle_support
import ../../app/theme/colour_math
import ../../app/theme/roles

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 14

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 160
  Rows = 40
  StatusRow = Rows - 1
  CtrlF = "\x06"
  CtrlQ = "\x11"
  AltR = "\er"
  AltL = "\el"
  ShiftDown = "\e[1;2B"
  WaitMs = 60_000
    ## The deadline a state wait gives up at — it only names what never
    ## happened; a wait that succeeds returns as soon as the state holds.
  ProjectText = "let a1 = 10\n" &
                "let b22 = 200\n" &
                "# a1 and a12\n" &
                "total = a1 + b22\n"

type Snapshot = seq[seq[Cell]]

var spawned = 0

proc freshDir(): string =
  inc spawned
  result = getTempDir() / ("plat70-regex-pty-" & $getCurrentProcessId() & "-" &
                           $spawned)
  removeDir(result)
  createDir(result)

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

proc findRow(s: Snapshot; needle: string): (int, int) =
  for r in 0 ..< Rows - 1:
    let line = s.text(r)
    let at = line.find(needle)
    if at >= 0: return (r, line[0 ..< at].runeLen)
  (-1, -1)

proc status(s: Snapshot): string = s.text(StatusRow).strip()

proc waitUntil(sess: var TuiTestSession; what: string;
               cond: proc(s: Snapshot): bool): Snapshot =
  let deadline = getMonoTime() + initDuration(milliseconds = WaitMs)
  while getMonoTime() < deadline:
    result = sess.snap()
    if cond(result): return
  var dump = ""
  for r in 0 ..< Rows: dump.add result.text(r) & "\n"
  raise newException(AssertionFailedError, "never: " & what & "\n" & dump)

proc press(sess: var TuiTestSession; row, col: int) =
  sess.send("\x1b[<0;" & $(col + 1) & ";" & $(row + 1) & "M")
  sess.send("\x1b[<0;" & $(col + 1) & ";" & $(row + 1) & "m")

proc bgHex(c: Cell): string =
  if c.bg.kind == ckRgb: hexOf((c.bg.r.int, c.bg.g.int, c.bg.b.int)) else: ""

let
  matchHex = tokenHex(RoleSpecs[srSurfaceFindMatch].bg, dmDark)
  currentHex = tokenHex(RoleSpecs[srSurfaceFindMatchCurrent].bg, dmDark)
  fileLines = ProjectText.splitLines()[0 .. 3]

proc painted(s: Snapshot): tuple[cells: seq[seq[int]]; current: int] =
  ## Per project line, the code cells painted on either find ground (as
  ## offsets from the line's first cell), and how many are the current
  ## match's.
  result.cells = newSeq[seq[int]](fileLines.len)
  for i, l in fileLines:
    let (r, c) = s.findRow(l)
    if r < 0: continue
    for x in c ..< min(Cols, c + l.runeLen):
      let h = s[r][x].bgHex
      if h == matchHex or h == currentHex:
        result.cells[i].add x - c
      if h == currentHex: inc result.current

proc expected(query: string; opts: MatchOptions;
              only: seq[int] = @[]): seq[seq[int]] =
  ## `matchesOf`'s spans per line (lines `only`, 0-based, when given).
  result = newSeq[seq[int]](fileLines.len)
  for i, l in fileLines:
    if only.len > 0 and i notin only: continue
    for m in matchesOf(l, query, opts):
      for x in l[0 ..< m.a].runeLen ..< l[0 ..< m.b].runeLen:
        result[i].add x

proc openEdit(): TuiTestSession =
  ## The shipped binary in Edit mode over a one-file project, under CUA, the
  ## start-up probe answered as a terminal without the kitty protocol.
  let state = freshDir()
  let project = state / "project"
  createDir(project)
  writeFile(project / "find.txt", ProjectText)
  result = newTuiTest(tuiBinary(), @["--theme=dark", "--keymap=cua",
                                     "--edit", project])
    .width(Cols).height(Rows).transcript()
    .envRemove("TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE", "TMUX", "STY",
               "NERD_FONT", "NERDFONT", "COLORFGBG")
    .envSet("TERM", "xterm-256color").envSet("LANG", "en_US.UTF-8")
    .envSet("COLORTERM", "truecolor")
    .envSet("XDG_STATE_HOME", state)
    .envSet("XDG_CONFIG_HOME", state / "config")
    .envSet("CODETRACER_HOME", state / "ct-home")
    .envSet("CODETRACER_TUI_LAYOUT_DIR", state / "layout")
    .envSet("CT_TUI_PROBE_TIMEOUT_MS", "4000").spawn()
  var sess = result
  let deadline = getMonoTime() + initDuration(milliseconds = WaitMs)
  while getMonoTime() < deadline:
    discard sess.drainOutput(20)
    if sess.transcriptBytes().contains("\e[?u"): break
  sess.send("\e[?62;22c")
  discard sess.waitUntil("the editor", proc(s: Snapshot): bool =
    s.findRow(fileLines[0])[0] >= 0)
  result = sess

proc quit(sess: var TuiTestSession) =
  sess.send(CtrlQ)
  discard sess.waitExit(initDuration(seconds = 30))
  sess.terminate()
  sess.close()

proc typeInto(sess: var TuiTestSession; text: string) =
  ## Characters typed one at a time, each waited for in the status line's
  ## field before the next is sent.
  var typed = ""
  for ch in text:
    typed.add ch
    sess.send($ch)
    let want = typed
    discard sess.waitUntil("the field holds `" & want & "`",
      proc(s: Snapshot): bool = s.status.contains(want))

suite "OQ-F5 on a real terminal: Alt+R":

  test "Alt+R reads the field as a regular expression, and back":
    var sess = openEdit()
    let s0 = sess.snap()
    let (r0, c0) = s0.findRow(fileLines[0])
    sess.press(r0, c0)
    sess.send(CtrlF)
    # The seed (the word at the caret) is selected, so typing replaces it.
    discard sess.waitUntil("the find field", proc(s: Snapshot): bool =
      s.status.contains("let"))
    sess.typeInto("a1\\d*")
    let literal = sess.waitUntil("the literal finds nothing",
      proc(s: Snapshot): bool = s.status.contains(NoMatchesText))
    ck not literal.status.contains("[.*]")
    sess.send(AltR)
    let rx = MatchOptions(caseSensitive: false, regex: true)
    let want = expected("a1\\d*", rx)
    let on = sess.waitUntil("the expression's matches painted",
      proc(s: Snapshot): bool =
        s.status.contains("[.*]") and s.status.contains("1 of 4") and
          s.painted.cells == want)
    ck on.painted.cells == want
    ck on.painted.current == 2                 # `a1`, the first match
    ck want[2] == @[2, 3, 9, 10, 11]           # `a1` and `a12` on line 3
    sess.send(AltR)
    let off = sess.waitUntil("literal again", proc(s: Snapshot): bool =
      not s.status.contains("[.*]") and s.status.contains(NoMatchesText))
    ck off.painted.current == 0
    sess.send(AltR)
    discard sess.waitUntil("regex again", proc(s: Snapshot): bool =
      s.status.contains("[.*]"))
    sess.typeInto("(")
    let bad = sess.waitUntil("the refusal", proc(s: Snapshot): bool =
      s.status.contains("invalid regular expression"))
    ck bad.status.contains("invalid regular expression")
    ck bad.painted.cells == expected("x", rx, only = @[-1])
    sess.quit()

suite "OQ-F5 on a real terminal: Alt+L":

  test "Alt+L confines the search to the selected lines, and back":
    var sess = openEdit()
    let s0 = sess.snap()
    let (r1, c1) = s0.findRow(fileLines[1])
    sess.press(r1, c1)
    # Lines 2 and 3, the selection ending at line 4's start; the keys are
    # read in the order they are written, so the field opens over the
    # selection and Alt+L takes it.
    let selectionHex = tokenHex(RoleSpecs[srSurfaceSelection].bg, dmDark)
    sess.send(ShiftDown)
    sess.send(ShiftDown)
    discard sess.waitUntil("two lines selected", proc(s: Snapshot): bool =
      let (r2, c2) = s.findRow(fileLines[2])
      r2 >= 0 and s[r1][c1].bgHex == selectionHex and
        s[r2][c2].bgHex == selectionHex)
    sess.send(CtrlF)
    sess.send(AltL)
    let scoped = sess.waitUntil("Find in Selection on",
      proc(s: Snapshot): bool = s.status.contains("[in selection]"))
    ck scoped.status.contains("[in selection]")
    sess.typeInto("a1")
    let opts = MatchOptions(caseSensitive: false)
    let inside = expected("a1", opts, only = @[1, 2])
    let s1 = sess.waitUntil("the scope's two matches painted",
      proc(s: Snapshot): bool =
        s.status.contains("1 of 2") and s.painted.cells == inside)
    ck s1.painted.cells == inside
    ck s1.painted.cells[0].len == 0 and s1.painted.cells[3].len == 0
    ck s1.painted.current == 2
    sess.send(AltL)
    let whole = sess.waitUntil("the whole file again",
      proc(s: Snapshot): bool =
        not s.status.contains("in selection") and s.status.contains(" of 4") and
          s.painted.cells == expected("a1", opts))
    ck whole.painted.cells == expected("a1", opts)
    sess.quit()

  test "Alt+L with nothing selected says it needs a selection":
    var sess = openEdit()
    let s0 = sess.snap()
    let (r0, c0) = s0.findRow(fileLines[0])
    sess.press(r0, c0)
    sess.send(CtrlF)
    discard sess.waitUntil("the find field", proc(s: Snapshot): bool =
      s.status.contains("let"))
    sess.send(AltL)
    let refused = sess.waitUntil("the note", proc(s: Snapshot): bool =
      s.status.contains(NoSelectionScopeText))
    ck refused.status.contains(NoSelectionScopeText)
    ck not refused.status.contains("[in selection]")
    sess.quit()

suite "OQ-F5 on a real terminal: the tally":
  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
