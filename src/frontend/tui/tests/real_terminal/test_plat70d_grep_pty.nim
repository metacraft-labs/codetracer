## test_plat70d_grep_pty.nim — PLAT-70 Part D (Find-And-Incremental-Search.md
## §5): **`:grep` and `Ctrl+Shift+F` on a real terminal.**
##
## The shipped `codetracer-tui` on the `multi_root` recording (its sources in
## two sibling folders), driven as a user drives it and read back off the
## screen through libvterm, in Debug mode:
##
##   * under CUA, a word selected in the read-only editor (`Ctrl+F`,
##     `Enter`, `Escape` — which keeps the match selected, OQ-F1), then
##     `Ctrl+Shift+F` (the bytes xterm's `modifyOtherKeys`, which the
##     terminal negotiates on `xterm-256color`, sends): Find in Files' field —
##     the omnibox's `:grep` line — opens SEEDED with the selection, the seed
##     painted on the selection ground and `:grep ` not; typing replaces the
##     seed (§5.2); `Enter` lists exactly the rows an oracle in this suite
##     finds (a plain scan of the recording's `files/` store) and opens
##     nothing (OQ-F2); `F4` then opens the first result at its line and the
##     tick does not move (§5.3);
##   * `:grep` alone — typed into the omnibox after `F4` selected a match in
##     the editor — is `Ctrl+Shift+F`: the field opens on that selection;
##   * under Vim, `:grep <text>` typed at Vim's own `:` prompt shows the pane
##     with the oracle's rows (FS-7 from the command line), and `:grep` alone
##     opens the field on the pane's query, selected (nothing is selected in
##     Vim's normal mode);
##   * with no `rg` on `PATH`, `:grep <text>` gives the oracle's rows from the
##     in-process walker, and `F4` opens the first at the recording's own
##     source path (FS-8, through the shipped binary).
##
## No mocks: the real binary, a real recording made by the Python recorder, a
## real `replay-server`, a real pty (TermAssert + libvterm), the shared runner.

import std/[algorithm, monotimes, os, strutils, times, unicode, unittest]

import term_assert
import nim_libvterm

import ../fixtures/fixture_provider
import ./lifecycle_support
import ../../app/theme/colour_math
import ../../app/theme/roles

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 21

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 260
    ## Wide enough that the status row's `opened <path>:<line>` note is never
    ## cut, so the no-`rg` case reads the whole path the walker reported.
  Rows = 50
  StatusRow = Rows - 1
  CtrlF = "\x06"
  CtrlShiftF = "\e[27;6;102~"
    ## `Ctrl+Shift+F` under xterm's `modifyOtherKeys` (CSI 27 ; mods ; cp ~),
    ## the protocol the terminal negotiates with a silent `xterm-256color`.
  CtrlP = "\x10"
  CtrlQ = "\x11"
  F4 = "\eOS"
  Esc = "\e"
  Enter = "\r"

type Snapshot = seq[seq[Cell]]

var spawned = 0

proc freshDir(): string =
  inc spawned
  result = getTempDir() / ("plat70d-pty-" & $getCurrentProcessId() & "-" &
                           $spawned)
  removeDir(result)
  createDir(result)

proc multiRoot(): string =
  let resolved = resolveFixture(FixtureSpec(
    name: "multi_root",
    program: "test-programs/multi_root/app/main.py",
    recorder: "codetracer-python-recorder",
    probe: FixtureProbe(kind: pkPythonRecorder),
    buildHint: "Install codetracer_python_recorder into the interpreter " &
               "`ct` will use.",
    blockedOn: ""))
  doAssert resolved.outcome == foRecorded, resolved.detail
  resolved.tracePath

let trace = multiRoot()

proc open(extra: seq[string]; path = ""): (TuiTestSession, string) =
  let state = freshDir()
  var b = newTuiTest(tuiBinary(), @["--theme=dark"] & extra & @[trace])
    .width(Cols).height(Rows).transcript()
    .envRemove("TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE", "TMUX", "STY",
               "NERD_FONT", "NERDFONT", "COLORFGBG")
    .envSet("TERM", "xterm-256color").envSet("LANG", "en_US.UTF-8")
    .envSet("COLORTERM", "truecolor")
    .envSet("XDG_STATE_HOME", state)
    .envSet("XDG_CONFIG_HOME", state / "config")
    .envSet("CODETRACER_HOME", state / "ct-home")
    .envSet("CODETRACER_TUI_LAYOUT_DIR", state / "layout")
  if path.len > 0:
    b = b.envSet("PATH", path)
  var sess = b.spawn()
  settleOnDebugger(sess, Cols, Rows)
  (sess, state)

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

proc lines(s: Snapshot): seq[string] =
  for r in 0 ..< Rows: result.add s.text(r)

proc cellFind(line, needle: string): int =
  let at = line.find(needle)
  if at < 0: -1 else: line[0 ..< at].runeLen

proc findRow(s: Snapshot; needle: string; first = 0): (int, int) =
  for r in first ..< Rows:
    let c = s.text(r).cellFind(needle)
    if c >= 0: return (r, c)
  (-1, -1)

proc waitUntil(sess: var TuiTestSession; what: string;
               cond: proc(s: Snapshot): bool; timeoutMs = 60000): Snapshot =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    result = sess.snap()
    if cond(result): return
    sleep(50)
  var dump = ""
  for r in 0 ..< Rows: dump.add result.text(r) & "\n"
  raise newException(AssertionFailedError, "never: " & what & "\n" & dump)

proc waitText(sess: var TuiTestSession; needle: string): Snapshot =
  sess.waitUntil("`" & needle & "` on the screen", proc(s: Snapshot): bool =
    s.findRow(needle)[0] >= 0)

proc key(sess: var TuiTestSession; bytes: string) =
  sess.send(bytes)
  discard sess.drainOutput(if bytes == Esc: 300 else: 80)

proc press(sess: var TuiTestSession; row, col: int) =
  sess.send("\x1b[<0;" & $(col + 1) & ";" & $(row + 1) & "M")
  sess.send("\x1b[<0;" & $(col + 1) & ";" & $(row + 1) & "m")

proc quit(sess: var TuiTestSession; state: string) =
  sess.send(CtrlQ)
  discard sess.waitExit(initDuration(seconds = 15))
  sess.terminate()
  sess.close()
  removeDir(state)

proc bgHex(c: Cell): string =
  if c.bg.kind == ckRgb: hexOf((c.bg.r.int, c.bg.g.int, c.bg.b.int)) else: ""

let selectionHex = tokenHex(RoleSpecs[srSurfaceSelection].bg, dmDark)

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

proc selectedOnTop(s: Snapshot): string =
  ## The characters of row 0 painted on the selection ground — the field's
  ## selected seed.
  for c in s[0]:
    if c.bgHex == selectionHex:
      result.add(if int(c.rune) == 0: " " else: $c.rune)

proc oracle(pattern: string): seq[(string, int)] =
  ## An independent reading: every line of every file in the recording's
  ## `files/` store containing `pattern`, any case, the store's prefix
  ## removed — as the recording names its sources.
  let store = trace / "files"
  var files: seq[string] = @[]
  for path in walkDirRec(store):
    if not path.extractFilename.startsWith("."): files.add path
  files.sort()
  for path in files:
    let text = readFile(path)
    if '\0' in text: continue
    var n = 0
    for line in text.splitLines():
      inc n
      if line.toLowerAscii.contains(pattern.toLowerAscii):
        result.add (path[store.len .. ^1], n)

proc summaryOf(rows: seq[(string, int)]): string =
  var files: seq[string] = @[]
  for (f, _) in rows:
    if f notin files: files.add f
  $rows.len & (if rows.len == 1: " result" else: " results") & " in " &
    $files.len & (if files.len == 1: " file" else: " files")

proc paneRows(s: seq[string]; expected: seq[(string, int)]): seq[(string, int)] =
  ## The (file, line) pairs the pane lists below its summary: a file header
  ## names the group (its short path, `<folder>/<name> · <n> matches`); a
  ## match row starts with its line number.
  var summaryRow = -1
  for r, line in s:
    if line.contains(summaryOf(expected)): summaryRow = r
  if summaryRow < 0: return
  var files: seq[string] = @[]
  for (f, _) in expected:
    if f notin files: files.add f
  var file = ""
  for r in summaryRow + 1 ..< s.len:
    let t = s[r].strip(trailing = true)
    let cap = t.find(" · ")
    if cap > 0:
      file = ""
      let short = t[0 ..< cap].strip()
      for f in files:
        let parts = f.split('/')
        if parts[^2] & "/" & parts[^1] == short: file = f
      continue
    let words = strutils.splitWhitespace(t.strip())
    if file.len > 0 and words.len >= 2 and words[0].allCharsInSet(Digits):
      result.add (file, parseInt(words[0]))
    elif file.len > 0 and t.strip().len == 0:
      break

proc noteOpened(s: Snapshot; path: string; line: int): bool =
  ## The status row's `opened …<name>:<line>` note (the path may be cut to
  ## `…` and its end; `test_plat57_find_in_files_pty.noteShowsPath`).
  let row = s.text(StatusRow).strip(leading = false)
  let at = row.find("opened ")
  at >= 0 and row.endsWith(path.extractFilename & ":" & $line)

suite "PLAT-70 Part D on a real terminal: :grep and Ctrl+Shift+F":

  test "CUA: Ctrl+Shift+F opens the field on the selection, selected; typing replaces it; F4":
    let factor = oracle("factor")
    let scale = oracle("scale")
    checkpoint("oracle factor: " & $factor & "  scale: " & $scale)
    ck factor.len >= 2 and scale.len > factor.len
    var (sess, state) = open(@["--keymap=cua"])
    let first = sess.snap()
    let t0 = first.tick
    ck t0 >= 0
    # The caret on `scale` in `extra.scale(total, 4)`, then the word
    # selected through the find session: `Ctrl+F` seeds it, `Enter` selects
    # a match (opening the field moves nothing), `Escape` keeps it selected
    # (OQ-F1).
    let (row, at) = first.findRow("extra.scale(total")
    doAssert row >= 0, "main.py's line 26 is not on the screen"
    sess.press(row, at + "extra.".len)
    sess.key(CtrlF)
    discard sess.waitUntil("the find field on `scale`", proc(s: Snapshot): bool =
      s.text(StatusRow).contains("scale"))
    sess.key(Enter)
    sess.key(Esc)
    # `Ctrl+Shift+F`: Find in Files' field, seeded, the seed selected.
    sess.key(CtrlShiftF)
    let seeded = sess.waitUntil("the field on `:grep scale`",
      proc(s: Snapshot): bool = s.text(0).contains(":grep scale"))
    # Typing replaces the seed and keeps `:grep ` (graded first, so a seed
    # left unselected and a selection left undrawn fail on different checks).
    sess.key("factor")
    var s = sess.waitUntil("the field changed by typing", proc(s: Snapshot): bool =
      s.text(0).contains("factor"))
    ck s.text(0).contains(":grep factor") and not s.text(0).contains("scale")
    ck s.selectedOnTop == ""
    # The seed WAS selected, on the selection ground; `:grep ` was not.
    ck seeded.selectedOnTop == "scale"
    ck seeded.text(0).contains(":grep scale")
    # `Enter`: the oracle's rows; nothing opened, the tick where it was.
    sess.key(Enter)
    s = sess.waitText(summaryOf(factor))
    ck paneRows(s.lines, factor) == factor
    ck s.tick == t0
    # `F4`: the first result, at its line; the tick does not move.
    sess.key(F4)
    s = sess.waitUntil("the first result opened", proc(s: Snapshot): bool =
      s.noteOpened(factor[0][0], factor[0][1]))
    ck s.tick == t0
    # `:grep` alone is `Ctrl+Shift+F`: `F4` selected the match in the
    # editor, and the field opens on it, selected.
    sess.key(CtrlP)
    sess.key(":grep")
    sess.key(Enter)
    s = sess.waitUntil("the field reopened on `factor`", proc(s: Snapshot): bool =
      s.selectedOnTop == "factor")
    ck s.text(0).contains(":grep factor")
    ck s.tick == t0
    sess.key(Esc)
    sess.quit(state)

  test "Vim: :grep at Vim's own : prompt; :grep alone opens the field on the query":
    let scale = oracle("scale")
    var (sess, state) = open(@["--keymap=vim"])
    let t0 = sess.snap().tick
    sess.key(":")
    sess.key("grep scale")
    sess.key(Enter)
    var s = sess.waitText(summaryOf(scale))
    ck paneRows(s.lines, scale) == scale
    ck s.tick == t0
    # `:grep` alone: the field, on the pane's query, selected.
    sess.key(":")
    sess.key("grep")
    sess.key(Enter)
    discard sess.waitUntil("Vim: `:grep` alone opens the field",
      proc(s: Snapshot): bool = s.text(0).contains(":grep"))
    s = sess.waitUntil("Vim: the field on the pane's query", proc(s: Snapshot): bool =
      s.text(0).contains(":grep scale"))
    ck s.selectedOnTop == "scale"
    # Typing replaces it; `Enter` searches the new text.
    sess.key("result")
    sess.key(Enter)
    let results = oracle("result")
    s = sess.waitText(summaryOf(results))
    ck paneRows(s.lines, results) == results
    ck s.tick == t0
    sess.quit(state)

  test "no rg on PATH: the walker gives the oracle's rows":
    var path: seq[string] = @[]
    for dir in getEnv("PATH").split(':'):
      if dir.len > 0 and not fileExists(dir / "rg"): path.add dir
    ck findExe("rg").len > 0   # the lane has it; the case removes it
    var noRg = true
    for dir in path:
      if fileExists(dir / "rg"): noRg = false
    ck noRg
    let scale = oracle("scale")
    var (sess, state) = open(@["--keymap=cua"], path = path.join(":"))
    let t0 = sess.snap().tick
    sess.key(CtrlP)
    sess.key(":grep scale")
    sess.key(Enter)
    var s = sess.waitText(summaryOf(scale))
    ck paneRows(s.lines, scale) == scale
    ck s.tick == t0
    # `F4` opens the first row at the RECORDING's source path — the walker
    # names a file as `rg` does, without the materialised `files/` store's
    # prefix, which the pane's short paths would not show.
    sess.key(F4)
    s = sess.waitUntil("the first result opened", proc(s: Snapshot): bool =
      s.noteOpened(scale[0][0], scale[0][1]))
    ck s.text(StatusRow).contains("opened " & scale[0][0] & ":" & $scale[0][1])
    sess.quit(state)

  test "assertion count":
    check countedAssertions == ExpectedAssertions
