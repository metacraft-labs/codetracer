## test_stop_path_parent_component.nim — **a stop whose recorded path has a
## `..` component shows THAT file's source**, in the shipped `codetracer-tui`,
## in a real terminal.
##
## The user, 2026-10-12, on `multi_root`: "When I click on add or scale in the
## call trace … I'm not taken to helpers.py as expected, but rather to
## extra.py and an error message 'No verified source for this revision'".
##
## `multi_root`'s runner is `app/main.py`; it puts `app/../shared` on
## `sys.path`, so the recorder reports the stops inside `helpers.add` and
## `extra.scale` at `…/multi_root/app/../shared/helpers.py` and
## `…/multi_root/app/../shared/pkg/extra.py` — the path exactly as Python saw
## it — while the recording's `files/` store holds both under their
## NORMALISED paths (`…/multi_root/shared/helpers.py`). The editor must show
## the stop's own file, from the recording (no "No verified source" banner),
## and never a different file.
##
## Each case clicks a call-trace row, as a terminal sends the press (SGR-1006),
## and asserts the editor's tab names the call's file and a line of that
## file's real source is drawn.
##
## No mocks: the real binary, the real `multi_root` recording made by the
## Python recorder, a real `replay-server`, a real pty (TermAssert + libvterm).

import std/[monotimes, os, strutils, times, unicode, unittest]

import term_assert
import nim_libvterm

import ../fixtures/fixture_provider
import ./lifecycle_support

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 52

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 200
  Rows = 50
  NoVerifiedSource = "No verified source"

var spawned = 0

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

proc open(tracePath = ""): TuiTestSession =
  let trace = if tracePath.len > 0: tracePath else: multiRoot()
  inc spawned
  let state = getTempDir() / ("dotdot-stop-" & $getCurrentProcessId() &
                              "-" & $spawned)
  removeDir(state)
  createDir(state)
  result = newTuiTest(tuiBinary(), @["--theme=dark", trace])
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

proc screen(sess: var TuiTestSession): seq[string] =
  discard sess.drainOutput(80)
  for r in 0 ..< Rows:
    var line = ""
    for c in 0 ..< Cols:
      let cell = sess.cellAt(r, c)
      line.add(if int(cell.rune) == 0: " " else: $cell.rune)
    result.add line

proc anyRow(s: seq[string]; needle: string): bool =
  for line in s:
    if line.contains(needle):
      return true
  false

proc waitFor(sess: var TuiTestSession; needle: string;
             timeoutMs = 20000): bool =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    if sess.screen().anyRow(needle):
      return true
    sleep(40)
  false

proc waitGone(sess: var TuiTestSession; needle: string;
              timeoutMs = 5000): bool =
  ## Whether `needle` is (or within `timeoutMs` becomes) absent from the
  ## screen — a row that arrives a frame after the source line does is not a
  ## failure; one that never arrives is.
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    if not sess.screen().anyRow(needle):
      return true
    sleep(40)
  false

proc wrappedMessage(s: seq[string]; head: string): string =
  ## The editor's degraded message, which the pane WRAPS over its rows when
  ## no line is drawn: the row holding `head` and the rows under it, each
  ## read from the message's column to the pane's right divider, rejoined.
  for r in 0 ..< s.len:
    let at = s[r].find(head)
    if at < 0: continue
    let col = s[r][0 ..< at].runeLen
    for rr in r ..< min(s.len, r + 4):
      let runes = s[rr].toRunes
      var piece = ""
      for c in col ..< runes.len:
        if $runes[c] == "▏": break
        piece.add $runes[c]
      result.add piece.strip(leading = false)
    return
  ""

proc callRow(sess: var TuiTestSession; head, args: string): (int, int) =
  ## The call-trace row starting with `head` that lists `args`, found by what
  ## the call is rather than by its index.
  let deadline = getMonoTime() + initDuration(milliseconds = 20000)
  while getMonoTime() < deadline:
    let s = sess.screen()
    for r in 0 ..< Rows:
      # The arguments when the pane is wide enough to show them; the head
      # alone (unique in this trace) when it is not.
      let h = s[r].find(head)
      let a = s[r].find(args)
      if h >= 0 and (a < 0 or h < a):
        return (r, s[r][0 ..< h].runeLen)
    sleep(40)
  (-1, -1)

proc press(sess: var TuiTestSession; row, col: int) =
  for suffix in ["M", "m"]:
    sess.send("\x1b[<0;" & $(col + 1) & ";" & $(row + 1) & suffix)

proc quit(sess: var TuiTestSession) =
  sess.send("\x11")
  discard sess.waitExit(initDuration(seconds = 10))
  sess.terminate()
  sess.close()

proc clickCallAndExpect(sess: var TuiTestSession;
                        head, args, tab, sourceLine, otherTab: string) =
  let (r, c) = sess.callRow(head, args)
  ck r > 0
  sess.press(r, c + 4)
  # The tab names the call's file, and a line of THAT file's source is drawn.
  ck sess.waitFor(sourceLine)
  let settled = sess.waitGone("⋯ loading")
  let s = sess.screen()
  ck s[1].contains(" " & tab & " ")
  ck not s[1].contains(" " & otherTab & " ")
  # From the recording itself: no degraded-source banner, no unloaded line.
  ck not s.anyRow(NoVerifiedSource)
  ck settled and not s.anyRow("⋯ loading")
  # And the status line names the stop's file.
  ck s[Rows - 1].contains(tab)

const
  Add = ("· add #", "(left=2, right=3)", "helpers.py", "return left + right",
         "extra.py")
  Scale = ("· scale #", "(value=5, factor=4)", "extra.py",
           "result = value * factor", "helpers.py")

suite "a stop path with a `..` component, in a real terminal":

  test "clicking `add` in the call trace shows helpers.py's source":
    var sess = open()
    sess.clickCallAndExpect(Add[0], Add[1], Add[2], Add[3], Add[4])
    sess.quit()

  test "clicking `scale` in the call trace shows extra.py's source":
    var sess = open()
    sess.clickCallAndExpect(Scale[0], Scale[1], Scale[2], Scale[3], Scale[4])
    sess.quit()

  test "add, then scale, then add again: each click shows its call's file":
    var sess = open()
    sess.clickCallAndExpect(Add[0], Add[1], Add[2], Add[3], Add[4])
    sess.clickCallAndExpect(Scale[0], Scale[1], Scale[2], Scale[3], Scale[4])
    sess.clickCallAndExpect(Add[0], Add[1], Add[2], Add[3], Add[4])
    sess.quit()

  test "a file opened from Files first, then `add`: the call's file, not the open one":
    var sess = open()
    # Open extra.py from the Files pane, as a reader would before going to a
    # call in another file.
    var (rf, cf) = (-1, -1)
    let deadline = getMonoTime() + initDuration(milliseconds = 20000)
    while getMonoTime() < deadline and rf < 0:
      let s = sess.screen()
      for r in 2 ..< Rows - 1:
        let at = s[r].find("extra.py")
        if at >= 0 and s[r][0 ..< at].runeLen < 30:
          (rf, cf) = (r, s[r][0 ..< at].runeLen)
          break
      sleep(40)
    ck rf > 1
    sess.press(rf, cf + 2)
    ck sess.waitFor("result = value * factor")
    sess.clickCallAndExpect(Add[0], Add[1], Add[2], Add[3], Add[4])
    sess.quit()

  test "a stop in a file the recording lacks says so, naming the path":
    # The same recording with helpers.py taken out of its `files/` store: the
    # lookup must not answer with a neighbour (extra.py is in the store), and
    # the editor must say which file is missing rather than draw rows that
    # will never load.
    let copy = getTempDir() / ("dotdot-missing-" & $getCurrentProcessId())
    removeDir(copy)
    copyDir(multiRoot(), copy)
    var removed = 0
    for f in walkDirRec(copy / "files"):
      if f.extractFilename == "helpers.py":
        removeFile(f)
        inc removed
    ck removed == 1
    var sess = open(copy)
    let (r, c) = sess.callRow(Add[0], Add[1])
    ck r > 0
    sess.press(r, c + 4)
    ck sess.waitFor("No source for ")
    ck sess.waitGone("⋯ loading")
    let s = sess.screen()
    checkpoint("the message: " & s.wrappedMessage("No source for "))
    ck s.wrappedMessage("No source for ").contains(
      "/multi_root/app/../shared/helpers.py in this recording.")
    ck s[1].contains(" helpers.py ")
    ck not s.anyRow("def scale(value, factor):")
    ck not s.anyRow(NoVerifiedSource)
    sess.quit()
    removeDir(copy)

  test "the assertion count matches the declared constant":
    check countedAssertions == ExpectedAssertions
