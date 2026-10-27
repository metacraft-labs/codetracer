## test_plat57_find_in_files_pty.nim — PLAT-57, Tier 2. **Find in Files on a
## real terminal.**
##
## The shipped `codetracer-tui` on the `multi_root` recording (its sources in
## two sibling folders), driven as a user drives it, read back off the screen
## through libvterm:
##
##   * `:grep <text>` typed into the omnibox shows the FIND IN FILES pane —
##     nothing opens (the user's OQ-F2) — and the pane's rows are the
##     recording's sources searched by an oracle in this suite (a plain scan of
##     the recording's `files/` store, independent of the runner): the summary's
##     counts, and every listed (file, line) pair;
##   * the runner's match is painted in the search-match colours;
##   * a press on a result opens its file in the editor at its line, and the
##     recording position (the header's tick) does not move (K35, Editor-
##     Pane.md);
##   * `:cnext` opens the next result, `F4` the next, `Shift+F4` the previous;
##   * the pane's `Aa` toggle runs the search again case-sensitively;
##   * the Edit menu's Find in Files opens the omnibox on `:grep <query>`, the
##     pane's field; there `Alt+C` flips Match Case and `Alt+R` Use Regular
##     Expression (each running the search again), and a regular expression
##     lists exactly the lines the oracle's own reading of it finds.
##
## No mocks: the real binary, a real recording made by the Python recorder, a
## real `replay-server`, a real pty (TermAssert + libvterm). The search is the
## shared runner, with `rg` when the lane's PATH has it.

import std/[algorithm, monotimes, os, strutils, times, unittest]
from std/unicode import runeLen

import term_assert

import ../fixtures/fixture_provider
import ./lifecycle_support

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 21

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 200
  Rows = 50
  CtrlP = "\x10"
  Enter = "\r"
  Pattern = "scale"

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

proc rowOf(sess: var TuiTestSession; row: int): string =
  discard sess.drainOutput(40)
  sess.regionText(row, 0, Cols, 1).split('\n')[0]

proc screen(sess: var TuiTestSession): seq[string] =
  discard sess.drainOutput(60)
  for r in 0 ..< Rows:
    result.add sess.rowOf(r)

proc waitScreen(sess: var TuiTestSession; needle: string;
                timeoutMs = 60000): seq[string] =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    result = sess.screen()
    for line in result:
      if line.contains(needle):
        return
    sleep(50)
  raise newException(AssertionFailedError,
    "'" & needle & "' never appeared; screen:\n" & result.join("\n"))

proc noteShowsPath(row, path: string; line: int): bool =
  ## Whether status row `row` carries the note `opened <path>:<line>` as the
  ## terminal draws it. The note is right-aligned after the file info and the
  ## dock labels, and a note naming an absolute path has that path's
  ## directories give way to `…` when the row is short of room
  ## (`status_bar.fitNoteCells`), so the path may be shown as `…` and its
  ## END — its last component always. How much is kept depends on how long
  ## the checkout's path is, which is a fact about the host, not the product.
  let at = row.find("opened ")
  if at < 0:
    return false
  let rest = row[at + "opened ".len .. ^1].strip(leading = false)
  let want = ":" & $line
  if not rest.endsWith(want):
    return false
  let shown = rest[0 ..< rest.len - want.len]
  if shown == path:
    return true
  let name = path[path.rfind('/') + 1 .. ^1]
  if not shown.startsWith("…"):
    return false
  let tail = shown["…".len .. ^1]
  tail.len > name.len and path.endsWith(tail)

proc waitOpened(sess: var TuiTestSession; path: string; line: int;
                timeoutMs = 60000): seq[string] =
  ## Wait for the status row's `opened <path>:<line>` note (`noteShowsPath`).
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    result = sess.screen()
    if noteShowsPath(result[Rows - 1], path, line):
      return
    sleep(50)
  raise newException(AssertionFailedError,
    "'opened " & path & ":" & $line & "' never appeared on the status row; " &
    "screen:\n" & result.join("\n"))

proc tickOf(line: string): int =
  let at = line.find("tick: ")
  if at < 0: return -1
  var n = ""
  for ch in line[at + 6 .. ^1]:
    if ch in {'0' .. '9'}: n.add ch
    elif ch == ',': discard
    else: break
  if n.len == 0: -1 else: parseInt(n)

proc press(sess: var TuiTestSession; row, col: int) =
  sess.send("\x1b[<0;" & $(col + 1) & ";" & $(row + 1) & "M")
  sess.send("\x1b[<0;" & $(col + 1) & ";" & $(row + 1) & "m")

proc omnibox(sess: var TuiTestSession; line: string) =
  sess.send(CtrlP)
  sleep(150)
  sess.send(line)
  sleep(100)
  sess.send(Enter)

proc oracle(traceFolder, pattern: string): seq[(string, int)] =
  ## An independent reading: every line of every file in the recording's
  ## `files/` store that contains `pattern`, any case — the store's prefix
  ## removed, as the recording names its sources.
  let store = traceFolder / "files"
  var files: seq[string] = @[]
  for path in walkDirRec(store):
    files.add path
  files.sort()
  for path in files:
    let name = path.extractFilename
    if name.startsWith("."): continue
    let text = readFile(path)
    if '\0' in text: continue
    var n = 0
    for line in text.splitLines():
      inc n
      if line.toLowerAscii.contains(pattern.toLowerAscii):
        result.add (path[store.len .. ^1], n)

proc wordEndLines(traceFolder, name: string): seq[(string, int)] =
  ## The oracle's reading of the regular expression `sc[a]le\b` (`name`
  ## followed by no word character): the lines holding an occurrence of
  ## `name`, any case, that a word character does not continue.
  let store = traceFolder / "files"
  var files: seq[string] = @[]
  for path in walkDirRec(store):
    if not path.extractFilename.startsWith("."): files.add path
  files.sort()
  for path in files:
    var n = 0
    for line in readFile(path).splitLines():
      inc n
      let t = line.toLowerAscii
      var at = t.find(name.toLowerAscii)
      while at >= 0:
        let after = at + name.len
        if after >= t.len or t[after] notin IdentChars:
          result.add (path[store.len .. ^1], n)
          break
        at = t.find(name.toLowerAscii, at + 1)

proc shortPath(path: string): string =
  let parts = path.split('/')
  parts[^2] & "/" & parts[^1]

proc paneRows(s: seq[string]; summaryRow: int;
              oracleFiles: seq[string]): seq[(string, int)] =
  ## The (file, line) pairs the pane lists below its summary: a file header
  ## names the group (its short path); a match row starts with its number.
  var file = ""
  for r in summaryRow + 1 ..< s.len:
    let t = s[r].strip(trailing = true)
    let cap = t.find(" · ")
    if cap > 0:
      file = ""
      let short = t[0 ..< cap].strip()
      for f in oracleFiles:
        if shortPath(f) == short: file = f
      continue
    let words = t.strip().splitWhitespace()
    if file.len > 0 and words.len >= 2 and words[0].allCharsInSet(Digits):
      result.add (file, parseInt(words[0]))
    elif file.len > 0 and t.strip().len == 0:
      break

suite "PLAT-57 on a real terminal: Find in Files":

  test ":grep shows the pane with the sources' rows; a click opens one, the tick stays; :cnext; Aa; the menu":
    let trace = multiRoot()
    let expected = oracle(trace, Pattern)
    var files: seq[string] = @[]
    for (f, _) in expected:
      if f notin files: files.add f
    checkpoint("oracle: " & $expected)
    ck expected.len >= 4 and files.len >= 2
    let state = getTempDir() / ("plat57-pty-" & $getCurrentProcessId())
    removeDir(state)
    createDir(state)
    var sess = newTuiTest(tuiBinary(), @["--theme=dark", trace])
      .width(Cols).height(Rows).transcript()
      .envRemove("TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE", "TMUX",
                 "STY", "NERD_FONT", "NERDFONT", "COLORFGBG")
      .envSet("TERM", "xterm-256color").envSet("LANG", "en_US.UTF-8")
      .envSet("COLORTERM", "truecolor")
      .envSet("XDG_STATE_HOME", state)
      .envSet("CODETRACER_HOME", state / "ct-home")
      .envSet("CODETRACER_TUI_LAYOUT_DIR", state / "layout")
      .spawn()
    settleOnDebugger(sess, Cols, Rows)
    let tick0 = tickOf(sess.rowOf(0))
    ck tick0 >= 0

    # `:grep scale` in the omnibox: the pane, its summary, its rows.
    sess.omnibox(":grep " & Pattern)
    let summaryText = $expected.len & " results in " & $files.len & " files"
    var s = sess.waitScreen(summaryText)
    var summaryRow = -1
    for r, line in s:
      if line.contains(summaryText): summaryRow = r
    ck summaryRow > 0
    let listed = paneRows(s, summaryRow, files)
    checkpoint("pane: " & $listed)
    # Every row the pane shows is one of the oracle's, in its order.
    ck listed.len >= 3
    ck listed == expected[0 ..< listed.len]
    # Nothing opened: the tick is where it was.
    ck tickOf(sess.rowOf(0)) == tick0

    # A press on the first result row opens its file at its line.
    var firstRow = -1
    for r in summaryRow + 1 ..< Rows:
      let w = s[r].strip().splitWhitespace()
      if w.len >= 2 and w[0] == $listed[0][1]:
        firstRow = r
        break
    ck firstRow > 0
    # The runner's match is painted in the search-match colours: its first
    # cell's ground is not the row's text ground just before it.
    let hitAt = s[firstRow].toLowerAscii.find(Pattern)
    let hitCol = s[firstRow][0 ..< max(0, hitAt)].runeLen
    ck hitAt > 0 and
       $sess.cellAt(firstRow, hitCol).bg != $sess.cellAt(firstRow, hitCol - 1).bg
    let col = s[firstRow].runeLen - s[firstRow].strip(leading = true).runeLen
    sess.press(firstRow, col + 1)
    discard sess.waitOpened(listed[0][0], listed[0][1])
    ck tickOf(sess.rowOf(0)) == tick0

    # `:cnext` (the palette's `:` line is the command line): the next one.
    sess.omnibox(":cnext")
    let second = expected[1]
    discard sess.waitOpened(second[0], second[1])
    ck tickOf(sess.rowOf(0)) == tick0
    # `F4` (CUA, §5.3): the next one again; `Shift+F4` back.
    sess.send("\eOS")
    discard sess.waitOpened(expected[2][0], expected[2][1])
    sess.send("\e[1;2S")
    discard sess.waitOpened(second[0], second[1])
    ck tickOf(sess.rowOf(0)) == tick0

    # A result in ANOTHER file: the editor's tab becomes that file and the
    # matched line is on screen; the tick still has not moved.
    s = sess.screen()
    var extraRow = -1
    for r in 0 ..< Rows:
      if s[r].contains("4  def scale(value, factor):"): extraRow = r
    if extraRow < 0:
      sess.omnibox(":grep " & Pattern)
      s = sess.waitScreen("4  def scale(value, factor):")
      for r in 0 ..< Rows:
        if s[r].contains("4  def scale(value, factor):"): extraRow = r
    ck extraRow > 0
    sess.press(extraRow, 3)
    s = sess.waitOpened(expected[3][0], 4)
    # The lone editor's tab is the file's folder and name since 2026-10-17
    # (`product_mode.editorTabLabel`), so the name follows a `/`. The strip
    # can repaint a frame after the status line says "opened", so the tab is
    # waited for (on row 1, the strip) rather than read once.
    let tabDeadline = getMonoTime() + initDuration(milliseconds = 5000)
    while not s[1].contains("/extra.py ") and getMonoTime() < tabDeadline:
      sleep(50)
      s = sess.screen()
    ck s[1].contains("/extra.py ")
    var shown = false
    for r in 2 ..< 30:
      # The editor's row: its gutter's line number after the Files pane's
      # divider, then the line's text.
      if s[r].contains("def scale(value, factor):") and
         s[r].contains("▏  4 "): shown = true
    ck shown
    ck tickOf(s[0]) == tick0

    # The `Aa` toggle: the same query, case-sensitively — `Scale` is nowhere.
    sess.omnibox(":grep Scale")
    s = sess.waitScreen(summaryText)
    var toggleRow, toggleCol = -1
    for r, line in s:
      let at = line.find(" Aa ")
      if at >= 0 and line.contains(" ab "):
        toggleRow = r
        toggleCol = line[0 ..< at].runeLen + 1
    ck toggleRow > 0
    sess.press(toggleRow, toggleCol)
    discard sess.waitScreen("No results for \"Scale\"")

    # The Edit menu's Find in Files: the omnibox on `:grep <query>`.
    sess.press(0, 1)
    s = sess.waitScreen(" Edit ")
    var editRow = -1
    for r in 1 ..< 12:
      if s[r].contains(" Edit "): editRow = r
    ck editRow > 0
    sess.press(editRow, s[editRow].find(" Edit ") + 2)
    s = sess.waitScreen("Find in Files")
    var itemRow, itemCol = -1
    for r in 1 ..< 20:
      let at = s[r].find("Find in Files")
      if at >= 0:
        itemRow = r
        itemCol = s[r][0 ..< at].runeLen + 1
    sess.press(itemRow, itemCol)
    let top = sess.waitScreen(":grep Scale")[0]
    ck top.contains(":grep Scale")

    # The omnibox on `:grep` is the pane's field: `Alt+C` flips Match Case
    # back off, and the search runs again — `Scale` finds the rows again.
    sess.send("\x1bc")
    discard sess.waitScreen("Match Case off")
    discard sess.waitScreen(summaryText)
    # `Alt+R`: Use Regular Expression, its toggle painted on.
    sess.send("\x1br")
    s = sess.waitScreen("Use Regular Expression on")
    var regexOn = false
    for r, line in s:
      let at = line.find(" .* ")
      if at >= 0 and line.contains(" Aa ") and line.contains(" ab "):
        let c = line[0 ..< at].runeLen + 1
        regexOn = $sess.cellAt(r, c).bg != $sess.cellAt(r, c - 6).bg
    ck regexOn
    # A regular expression: the oracle's reading of it, row for row.
    sess.send("\x1b")
    sleep(200)
    let defs = wordEndLines(trace, Pattern)
    var defFiles: seq[string] = @[]
    for (f, _) in defs:
      if f notin defFiles: defFiles.add f
    checkpoint("def oracle: " & $defs)
    ck defs.len >= 2 and defs.len < expected.len
    sess.omnibox(":grep sc[a]le\\b")
    let defSummary = $defs.len & " results in " & $defFiles.len & " files"
    s = sess.waitScreen(defSummary)
    var defRow = -1
    for r, line in s:
      if line.contains(defSummary): defRow = r
    ck paneRows(s, defRow, defFiles) == defs

    sess.send("\x1b")
    sleep(200)
    sess.send("\x11")  # Ctrl+Q, the CUA base's quit
    discard sess.waitExit(initDuration(seconds = 10))
    sess.terminate()
    sess.close()
    removeDir(state)

  test "assertion count":
    check countedAssertions == ExpectedAssertions
