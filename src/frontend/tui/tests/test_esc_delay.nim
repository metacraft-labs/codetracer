## The lone-`ESC` delay — the terminal driver delivers the Esc KEY.
##
## Run:
##   nim c -r <tui lane flags> src/frontend/tui/tests/test_esc_delay.nim
##
## A terminal sends the Esc key as the single byte that also begins every
## escape sequence, so only time tells them apart. Until 2026-09-23 the driver
## held a lone `ESC` until the NEXT byte and then dropped it, so under the Vim
## and Kakoune keymaps one press of `Esc` never left insert mode in a real
## terminal. `host/terminal_driver.EscDelayMs` is the repair; this suite drives
## `nextEvent` over a REAL pipe with real waits:
##
##   * a lone `ESC` becomes the `Esc` token after `EscDelayMs`, not before;
##   * an escape sequence written in one burst is still ONE token, not an Esc
##     followed by its tail;
##   * `ESC ESC` still yields exactly one `Esc` immediately — the framing every
##     earlier pty suite relies on is unchanged;
##   * an `ESC` followed by an ordinary key AFTER the delay is two tokens —
##     the key-press sequence of a Vim user leaving insert mode;
##   * a sequence already waiting behind its `ESC` is one token even when the
##     reader comes back after the delay (PLAT-48).
##
## NO MOCKS: a real pipe, the shipped driver, the shipped framer.

import std/[monotimes, os, posix, strutils, times, unittest]

import ../host/terminal_driver
import ../../../common/key_names
import ../app/theme/capabilities

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

proc caps(): TerminalCapabilities =
  resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"),
    initCapabilityFlags())

proc pipeDriver(): (TerminalDriver, cint) =
  var fds: array[2, cint]
  doAssert pipe(fds) == 0
  (newTerminalDriver(caps(), inFd = fds[0], outFd = fds[1]), fds[1])

proc put(fd: cint; bytes: string) =
  doAssert write(fd, unsafeAddr bytes[0], bytes.len) == bytes.len

proc nextToken(d: TerminalDriver; budgetMs: int): (string, int64) =
  ## The next token and how long it took, or "" if none came in `budgetMs`.
  let t0 = getMonoTime()
  while (getMonoTime() - t0).inMilliseconds < budgetMs:
    let ev = d.nextEvent(20)
    if ev.kind == dekToken:
      return (ev.token, (getMonoTime() - t0).inMilliseconds)
  ("", (getMonoTime() - t0).inMilliseconds)

suite "the lone ESC delay, over a real pipe":

  test "a lone ESC is the Esc key after EscDelayMs, and not before":
    let (d, w) = pipeDriver()
    w.put("\x1b")
    let (tok, took) = d.nextToken(1000)
    checkpoint("took " & $took & " ms")
    ck tok == "\x1b"
    # One millisecond of slack: both clocks are truncated to whole ms.
    ck took >= EscDelayMs - 1
    ck took < 500

  test "a sequence written in one burst is one token":
    let (d, w) = pipeDriver()
    w.put("\x1b[A")
    let (tok, _) = d.nextToken(1000)
    ck tok == "\x1b[A"
    let (none, _) = d.nextToken(150)
    ck none == ""

  test "ESC ESC still yields exactly one Esc, at once":
    let (d, w) = pipeDriver()
    w.put("\x1b\x1b")
    let (tok, took) = d.nextToken(1000)
    ck tok == "\x1b"
    ck took < EscDelayMs
    let (none, _) = d.nextToken(150)
    ck none == ""

  test "Esc, a pause, then `j` is two tokens — leaving insert mode, then a motion":
    # THE LOOP IS READING while the user pauses, as the shipped input loop is:
    # the Esc is delivered by the delay, and `j` is its own key after it.
    let (d, w) = pipeDriver()
    w.put("\x1b")
    let (first, _) = d.nextToken(1000)
    os.sleep(30)
    w.put("j")
    let (second, _) = d.nextToken(1000)
    ck first == "\x1b"
    ck second == "j"

  test "ESC and a letter in ONE burst are one token — Alt+<letter>":
    # What a terminal sends for Alt+<letter>, and indistinguishable from an Esc
    # and a key typed faster than one read. Until PLAT-51 the ESC was dropped
    # and the letter honoured, which made the desktop's Alt+T ("Add
    # tracepoint" on the read-only editor's caret) unreachable from a real
    # terminal. A DECISION, as this case said a change here would be: the
    # burst is framed as ONE token that `keyName` names `Alt+j`, and the
    # runtime treats an Alt chord it does not bind as the letter alone
    # (`runtime.handleToken`, pinned by `test_plat51_parity`), so what a user
    # typing Esc-then-a-key fast gets is unchanged.
    let (d, w) = pipeDriver()
    w.put("\x1bj")
    let (tok, _) = d.nextToken(1000)
    ck tok == "\x1bj"
    ck keyName(tok) == "Alt+j"
    let (none, _) = d.nextToken(150)
    ck none == ""

  test "a sequence already waiting behind its ESC is one token, however late the reader":
    # PLAT-48. The input loop does work between two `nextEvent` calls — a
    # repaint, a debugger step's round trip — and read ONE byte per call. A
    # mouse release queued behind a click on a debugger control had its `ESC`
    # read, then the loop repainted for longer than `EscDelayMs`, and the
    # held `ESC` was declared the Esc key with `[<0;51;1m` still waiting: the
    # release arrived as the keys `[`, `<`, `0`, `;`, `5`, `1`, `;`, `1`, `m`.
    # The reader here is late by construction: it takes the `ESC`, then
    # sleeps past the delay before asking again.
    let (d, w) = pipeDriver()
    w.put("\x1b[<0;51;1m")
    let first = d.nextEvent(20)
    os.sleep(int(EscDelayMs) * 3)
    var tok = ""
    if first.kind == dekToken:
      tok = first.token
    else:
      tok = d.nextToken(1000)[0]
    checkpoint("got " & tok.escape)
    ck tok == "\x1b[<0;51;1m"
    let (none, _) = d.nextToken(150)
    ck none == ""

suite "ESC delay — assertion tally":
  test "CHECKS":
    echo "CHECKS: ", CHECKS
    check CHECKS > 0
