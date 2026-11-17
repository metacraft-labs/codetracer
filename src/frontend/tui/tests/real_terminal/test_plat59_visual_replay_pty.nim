## test_plat59_visual_replay_pty.nim — PLAT-59 on a REAL terminal: **the
## shipped `codetracer-tui` opens a real visual recording and shows its
## graphics — the Video Player beside the editor with its frame, its
## transport and its scrubbers; a scrub, the desktop's keys, the picker and a
## picked pixel's history** — through a real pty and libvterm (TermAssert).
##
## The recording is `fixtures/visual_fixture`'s `gl_scene` (`ct-mcr`'s), the
## player a real `ct_gfx_player` the binary starts itself (its producer,
## `attachVisualReplay`), found as `ct gfx-replay` finds it. The terminal is
## `xterm-256color` with truecolor, so the frame is drawn as cells at the tier
## the binary resolves (named in the pane's title).
##
## No mocks: the binary, the engine, the player and the recording are the
## product's.

import std/[monotimes, os, strutils, times, unittest]
from std/unicode import runeLen, runeSubStr

import term_assert

import ../fixtures/fixture_provider
import ../fixtures/visual_fixture
import ./lifecycle_support

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 12

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 200
  Rows = 56

proc screen(sess: var TuiTestSession): seq[string] =
  ## One drain, then every row read from it: a drain per row made one read
  ## take longer than the whole recording plays at 1x.
  discard sess.drainOutput(60)
  for r in 0 ..< Rows:
    result.add sess.regionText(r, 0, Cols, 1).split('\n')[0]

proc waitScreen(sess: var TuiTestSession; needle: string;
                timeoutMs = 120000): seq[string] =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    result = sess.screen()
    for line in result:
      if line.contains(needle):
        return
    sleep(50)
  raise newException(AssertionFailedError,
    "'" & needle & "' never appeared; screen:\n" & result.join("\n"))

proc waitScreenAny(sess: var TuiTestSession; needles: openArray[string];
                   timeoutMs = 120000): seq[string] =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    result = sess.screen()
    for line in result:
      for needle in needles:
        if line.contains(needle):
          return
    sleep(50)
  raise newException(AssertionFailedError,
    "none of " & $(@needles) & " appeared; screen:\n" & result.join("\n"))

proc press(sess: var TuiTestSession; row, col: int; release = true) =
  sess.send("\x1b[<0;" & $(col + 1) & ";" & $(row + 1) & "M")
  if release:
    sess.send("\x1b[<0;" & $(col + 1) & ";" & $(row + 1) & "m")

proc cellOf(line, needle: string): int =
  let at = line.find(needle)
  if at < 0: -1 else: line[0 ..< at].runeLen

proc rowWith(s: seq[string]; needle: string): int =
  for r, t in s:
    if t.contains(needle):
      return r
  -1

let skip = visualFixtureSkip()

suite "PLAT-59 on a real terminal: the Visual Replay panes":
  if skip.len > 0:
    test "the Visual Replay suites need a visual recording and its player":
      echo skip
      skip()
  else:
    test "the Video Player, a scrub, the keys, a picked pixel's history":
      let state = getTempDir() / ("plat59-pty-" & $getCurrentProcessId())
      removeDir(state)
      createDir(state)
      var sess = newTuiTest(tuiBinary(), @["--theme=dark",
                                          visualFixtureFolder()])
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
      # The Video Player's tab, beside the editor's; Pixel History's and
      # Shader Debug's beside the state pane's.
      var s = sess.waitScreen("Video Player")
      ck s.join("\n").contains("Pixel History")
      ck s.join("\n").contains("Shader Debug")
      let tabRow = s.rowWith("Video Player")
      sess.press(tabRow, s[tabRow].cellOf("Video Player") + 2)
      s = sess.waitScreen("Frame 0 / 59")
      let title = s.rowWith("FRAME VIEWER")
      ck title >= 0
      ck s[title].contains("256x256px")
      ck s[title].contains("image-tier=")
      # The transport row and the frame scrubber under it.
      let transport = s.rowWith("[|<][<<][>][>>][>|]")
      ck transport > title
      # End: the last frame.
      sess.press(title, s[title].cellOf("FRAME VIEWER") + 1)
      sess.send("\x1b[F")
      s = sess.waitScreen("Frame 59 / 59")
      ck s[s.rowWith("FRAME VIEWER")].contains("Draw 3 / 3")
      # A press on the frame scrubber's first cell: the first frame.
      let paneCol = s[transport].cellOf("[|<]")
      sess.press(transport + 1, paneCol)
      s = sess.waitScreen("Frame 0 / 59")
      ck s.rowWith("Frame 0 / 59") >= 0
      # Right: the next frame; `l` plays at 1x; Space pauses.
      sess.send("\x1b[C")
      s = sess.waitScreen("Frame 1 / 59")
      # The recording plays in under three seconds, which a read of the screen
      # on a loaded host can straddle: playback seen at 1x is paused by Space,
      # and playback that already reached the last frame has paused itself.
      sess.send("l")
      s = sess.waitScreenAny(["1x >", "Frame 59 / 59"])
      if s.join("\n").contains("1x >"):
        # Playback seen is not playback that has moved yet: on a loaded host
        # Space can land while frame 1 is still shown, and the check below
        # then reads a pause as no movement. Pause once it has moved.
        var later: seq[string] = @[]
        for f in 2 .. 59:
          later.add "Frame " & $f & " / 59"
        discard sess.waitScreenAny(later)
        sess.send(" ")
      s = sess.waitScreen("paused")
      ck s.rowWith("Frame 1 / 59") < 0   # it moved
      # The picker: `p` opens the magnifier, Enter commits its pixel.
      sess.send("p")
      s = sess.waitScreen("Enter picks")
      sess.send("\r")
      s = sess.waitScreen("its history and its shader")
      let status = s[Rows - 1]
      ck status.contains("pixel ")
      # Pixel History lists the draw calls that wrote it. Its rows are waited
      # for by their own words: "Draw " is also the frame viewer's title,
      # which is on screen before the history has been asked for, so on a
      # loaded host a wait for it returned before any row was drawn.
      s = sess.waitScreen("GEID ")
      ck s.join("\n").contains("GEID ")
      ck s.join("\n").contains("Passed")
      sess.send("q")
      removeDir(state)

  test "every assertion ran":
    if skip.len == 0:
      check countedAssertions == ExpectedAssertions
