## test_plat58_requests_pty.nim — the Requests pane on a real terminal.
##
## Spec: `codetracer-pm` `spec/GUI/Core-Panes/Request-Panel.md` § "The terminal
## and the GPUI window (PLAT-58)".
##
## The shipped `codetracer-tui` on the RS-M4 demo session — a real `.ct`
## container with eight request spans over a recorded timeline, written by the
## canonical writer (`src/tools/demo_request_session`) — driven as a user
## drives it, read back off the screen through libvterm:
##
##   * the docked REQUESTS pane opens by itself (the recording serves
##     requests), and every row it shows is the producer's request, formatted
##     here by hand: `#`, method, URL, status, duration, size;
##   * `:requests users` typed into the omnibox narrows the rows to the URLs
##     holding `users`; `:requests` alone, with that search on, clears it;
##   * a double click on a row moves the recording to the request's handler —
##     the header's tick is the handler's step (`6 + 7 i`), the status row
##     names the handler's line — and a single click moves nothing;
##   * a right click opens the row's menu, whose Go to Handler moves.
##
## No mocks: the real binary, a real container, a real `replay-server`, a
## real pty (TermAssert + libvterm).

import std/[monotimes, os, strutils, times, unittest]

import results
import term_assert

import ./lifecycle_support
import ../../../../tools/demo_request_session

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 20

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 160
  Rows = 60
  CtrlP = "\x10"
  Enter = "\r"

proc rowOf(sess: var TuiTestSession; row: int): string =
  discard sess.drainOutput(40)
  sess.regionText(row, 0, Cols, 1).split('\n')[0]

proc screen(sess: var TuiTestSession): seq[string] =
  discard sess.drainOutput(60)
  for r in 0 ..< Rows:
    result.add sess.rowOf(r)

proc waitScreen(sess: var TuiTestSession; ok: proc(s: seq[string]): bool;
                what: string; timeoutMs = 60000): seq[string] =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    result = sess.screen()
    if ok(result):
      return
    sleep(50)
  raise newException(AssertionFailedError,
    what & " never appeared; screen:\n" & result.join("\n"))

proc tickOf(line: string): int =
  let at = line.find("tick: ")
  if at < 0: return -1
  var n = ""
  for ch in line[at + 6 .. ^1]:
    if ch in {'0' .. '9'}: n.add ch
    else: break
  if n.len == 0: -1 else: parseInt(n)

proc press(sess: var TuiTestSession; row, col: int; button = 0) =
  sess.send("\x1b[<" & $button & ";" & $(col + 1) & ";" & $(row + 1) & "M")
  sess.send("\x1b[<" & $button & ";" & $(col + 1) & ";" & $(row + 1) & "m")

proc omnibox(sess: var TuiTestSession; line: string) =
  sess.send(CtrlP)
  sleep(150)
  sess.send(line)
  sleep(100)
  sess.send(Enter)

proc handSize(bytes: int): string =
  if bytes < 1024: $bytes & " B"
  else: $(bytes div 1024) & "." & $((bytes mod 1024) * 10 div 1024) & " KB"

proc handDuration(ms: int): string =
  if ms < 1000: $ms & "ms" else: $(ms div 1000) & "." & $((ms mod 1000) div 100) & "s"

proc oracleWords(i: int): seq[string] =
  ## Request `i` of the producer's table, as the row's words.
  let d = DemoRequests[i]
  let id = i + 2
  @[(if id < 10: "0" & $id else: $id), d.httpMethod, d.url, $d.statusCode,
    handDuration(d.durationMs)] & handSize(d.responseSize).splitWhitespace()

proc requestRows(s: seq[string]): seq[(int, int)] =
  ## The (screen row, request index) of every request row on screen: a line
  ## whose words are a request's, start to end.
  for r, line in s:
    let words = line.strip().splitWhitespace()
    if words.len < 2 or words[0].len != 2 or not words[0].allCharsInSet(Digits):
      continue
    let i = parseInt(words[0]) - 2
    if i < 0 or i >= DemoRequests.len:
      continue
    let want = oracleWords(i)
    if words.len >= want.len and words[0 ..< want.len] == want:
      result.add (r, i)

proc rowOfRequest(s: seq[string]; id: int): int =
  for (r, i) in s.requestRows:
    if i + 2 == id:
      return r
  -1

suite "PLAT-58 on a real terminal: the Requests pane":

  test "revealed with the producer's rows; :requests; a double click goes to the handler; the menu":
    let folder = getTempDir() / ("plat58-pty-" & $getCurrentProcessId())
    removeDir(folder)
    createDir(folder)
    doAssert writeDemoRequestSession(folder).isOk
    let state = folder & "-state"
    removeDir(state)
    createDir(state)
    var sess = newTuiTest(tuiBinary(), @["--theme=dark", folder])
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

    # REVEALED, with the producer's rows.
    var s = sess.waitScreen(proc(s: seq[string]): bool = s.requestRows.len >= 3,
                            "the Requests pane's rows")
    let shown = s.requestRows
    checkpoint("rows: " & $shown)
    ck shown.len >= 3
    for k, (r, i) in shown:
      ck i == k                                  # in capture order, from #02
    var header = false
    for line in s:
      if line.contains("method") and line.contains("URL") and
         line.contains("Duration"):
        header = true
    ck header

    # `:requests users`: only the URLs holding `users`.
    sess.omnibox(":requests users")
    s = sess.waitScreen(proc(s: seq[string]): bool =
      s.rowOfRequest(5) < 0 and s.rowOfRequest(6) >= 0, "the users filter")
    var ids: seq[int] = @[]
    for (_, i) in s.requestRows: ids.add i + 2
    ck ids == @[2, 3, 4, 6]
    sess.omnibox(":requests")                    # with a search on: clears
    s = sess.waitScreen(proc(s: seq[string]): bool = s.rowOfRequest(5) >= 0,
                        "the cleared filter")
    ck s.rowOfRequest(5) >= 0

    # ONE click selects and moves nothing; a DOUBLE click goes to the
    # handler of request 4 (i = 2): step 6 + 7 * 2.
    let r4 = s.rowOfRequest(4)
    ck r4 > 0
    sess.press(r4, 20)
    sleep(800)                                   # past the double-click time
    s = sess.screen()
    ck tickOf(s[0]) == tick0
    sess.press(r4, 20)
    sess.press(r4, 20)
    s = sess.waitScreen(proc(s: seq[string]): bool = tickOf(s[0]) == 6 + 7 * 2,
                        "the handler's tick")
    ck tickOf(s[0]) == 6 + 7 * 2
    ck s[Rows - 1].contains("the handler of /api/users/42")

    # THE MENU: a right click on request 8, then Go to Handler.
    let r8 = s.rowOfRequest(8)
    ck r8 > 0
    sess.press(r8, 20, button = 2)
    s = sess.waitScreen(proc(s: seq[string]): bool =
      for line in s:
        if line.contains("Go to Handler"): return true
      false, "the row's menu")
    var menuRow = -1
    var menuCol = -1
    for r, line in s:
      let at = line.find("Go to Handler")
      if at >= 0:
        menuRow = r
        menuCol = line[0 ..< at].len
    var hasCopy = false
    for line in s:
      if line.contains("Copy URL"): hasCopy = true
    ck hasCopy
    sess.press(menuRow, menuCol + 2)
    s = sess.waitScreen(proc(s: seq[string]): bool = tickOf(s[0]) == 6 + 7 * 6,
                        "request 8's handler")
    ck tickOf(s[0]) == 6 + 7 * 6

    sess.send("\x11")   # Ctrl+Q, the CUA base's quit
    discard sess.waitExit(initDuration(seconds = 10))
    sess.terminate()
    sess.close()
    removeDir(folder)
    removeDir(state)

  test "the assertion count":
    check countedAssertions == ExpectedAssertions
