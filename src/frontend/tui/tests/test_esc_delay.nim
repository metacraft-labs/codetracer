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
##     reader comes back after the delay (PLAT-48);
##   * an `Esc` the reader had not finished with when the next key's escape
##     sequence arrived — `ESC` and then, within the delay, `ESC O P` — is
##     `Esc` and then `F1`, never `Esc`, `O`, `P` (the keymap selector's
##     DIFF-12 pty case typed that `P` into its document on a loaded machine,
##     codetracer-pm issue 2026-10-26);
##   * a held `ESC` whose sequence's tail arrived within the delay but was
##     read late is that sequence, not `Esc` and its tail as keys (the same
##     case's second cause, issue 2026-10-29).
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

suite "an Esc, then another key's escape sequence":

  test "ESC ESC O P in one burst is Esc, then F1":
    let (d, w) = pipeDriver()
    w.put("\x1b\x1bOP")
    let (first, _) = d.nextToken(1000)
    let (second, _) = d.nextToken(1000)
    checkpoint("got " & first.escape & " " & second.escape)
    ck first == "\x1b"
    ck second == "\x1bOP"
    ck keyName(second) == "F1"
    let (none, _) = d.nextToken(150)
    ck none == ""

  test "an ESC held, then F1 within the delay: Esc, then F1":
    # The race itself: the reader holds the `Esc` (the delay has not run
    # out) when `F1`'s three bytes arrive. Before 2026-10-27 the second
    # `ESC` was consumed as the pair's `Esc` and `O`, `P` were typed.
    let (d, w) = pipeDriver()
    w.put("\x1b")
    let held = d.nextEvent(5)
    ck held.kind == dekIdle
    os.sleep(5)
    w.put("\x1bOP")
    let (first, _) = d.nextToken(1000)
    let (second, _) = d.nextToken(1000)
    checkpoint("got " & first.escape & " " & second.escape)
    ck first == "\x1b"
    ck second == "\x1bOP"
    let (none, _) = d.nextToken(150)
    ck none == ""

  test "an ESC held, F1's tail arriving within the delay, the reader back late: F1":
    # The reader holds the `ESC`; `O P` arrive 5 ms later (a split write);
    # the reader is busy past the delay before it asks again. The tail is
    # waiting, so it is read: `F1`, not `Esc`, `O`, `P`.
    let (d, w) = pipeDriver()
    w.put("\x1b")
    let held = d.nextEvent(5)
    ck held.kind == dekIdle
    os.sleep(5)
    w.put("OP")
    os.sleep(int(EscDelayMs) * 3)
    let (first, _) = d.nextToken(1000)
    checkpoint("got " & first.escape)
    ck first == "\x1bOP"
    let (none, _) = d.nextToken(150)
    ck none == ""

  test "an ESC held, a key arriving within the delay, the reader back late: Esc, then the key":
    # The same late reader, but the waiting byte begins no sequence: it is a
    # key of its own after the `Esc` (Vim's `Esc` `j`), not `Alt+j`.
    let (d, w) = pipeDriver()
    w.put("\x1b")
    discard d.nextEvent(5)
    os.sleep(5)
    w.put("j")
    os.sleep(int(EscDelayMs) * 3)
    ck d.nextToken(1000)[0] == "\x1b"
    ck d.nextToken(1000)[0] == "j"
    let (none, _) = d.nextToken(150)
    ck none == ""

  test "ESC ESC [ A is Esc, then Up; ESC ESC j is Esc, then j":
    let (d, w) = pipeDriver()
    w.put("\x1b\x1b[A")
    ck d.nextToken(1000)[0] == "\x1b"
    ck d.nextToken(1000)[0] == "\x1b[A"
    w.put("\x1b\x1bj")
    ck d.nextToken(1000)[0] == "\x1b"
    ck d.nextToken(1000)[0] == "j"
    let (none, _) = d.nextToken(150)
    ck none == ""

  test "ESC ESC ESC is two Escs, as it always was":
    let (d, w) = pipeDriver()
    w.put("\x1b\x1b\x1b")
    ck d.nextToken(1000)[0] == "\x1b"
    ck d.nextToken(1000)[0] == "\x1b"
    let (none, _) = d.nextToken(200)
    ck none == ""

suite "ESC delay — assertion tally":
  test "CHECKS":
    echo "CHECKS: ", CHECKS
    check CHECKS > 0
