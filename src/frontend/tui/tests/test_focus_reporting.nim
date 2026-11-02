## Focus reporting (DECSET 1004) — the terminal driver asks for it, frames the
## reports, and never lets one through as a key.
##
## Run:
##   nim c -r <tui lane flags> src/frontend/tui/tests/test_focus_reporting.nim
##
## The desktop's VCS panel re-reads the repository whenever its window regains
## focus (VCS-Panel.md's focus-gain refresh, `ui/vcs.nim` `startFileWatching`).
## The terminal's equivalent is xterm's focus reporting: with mode 1004 set
## the terminal writes `CSI I` when its window gains focus and `CSI O` when it
## loses it (https://invisible-island.net/xterm/ctlseqs/ctlseqs.html, "FocusIn/
## FocusOut"). Until codetracer-pm issue 2026-09-30 ("the terminal's and
## GPUI's VCS panes do not refresh when their window regains focus") the
## driver requested no mode 1004 and the loop had no focus event, so the pane
## refreshed on its 5 s interval only. This suite pins the driver's half:
##
##   * the decode — `CSI I` / `CSI O` are focus reports, and nothing that a
##     KEY produces is (`Esc` then `I`, Alt+Shift+I, a modified CSI `I`);
##   * the framing — a report written in one burst is ONE token, which the
##     key decoder names as no key at all;
##   * the event — over a real pipe, `nextEvent` answers `dekFocus` for a
##     report and never `dekToken`, including for a report that
##     `absorbInterruptByte` queued while a trace was opening;
##   * the request — `start` writes `CSI ? 1004 h` with the mouse negotiated
##     AND without it (`--no-mouse`), and `stop` writes `CSI ? 1004 l` before
##     it leaves the alternate screen.
##
## The real-terminal half — the shipped binary re-reading its VCS pane on a
## `CSI I` before the interval could have — is
## `real_terminal/test_plat47_vcs_focus_refresh.nim`.
##
## NO MOCKS: the shipped driver, the shipped framer and key decoder, over a
## real pipe for input and a real pseudo-terminal (`nim_pty.openPty`, no
## child process) for the request. The request is read off the pty's MASTER
## side, exactly the bytes a terminal emulator would receive: `start` puts the
## slave into raw mode first (`cfmakeraw` clears `OPOST`), so nothing is
## translated on the way.

import std/[monotimes, posix, strutils, times, unittest]

import nim_pty

import ../host/terminal_driver
import ../../../common/key_names
import ../app/theme/capabilities

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

proc caps(noMouse = false): TerminalCapabilities =
  resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"),
    initCapabilityFlags(noMouse = noMouse))

proc inPipe(): (TerminalDriver, cint) =
  ## A driver reading from a pipe; the write end is returned.
  var fds: array[2, cint]
  doAssert pipe(fds) == 0
  (newTerminalDriver(caps(), inFd = fds[0], outFd = fds[1]), fds[1])

proc put(fd: cint; bytes: string) =
  doAssert write(fd, unsafeAddr bytes[0], bytes.len) == bytes.len

proc frame(bytes: string): seq[string] =
  ## Every complete token the framer makes of `bytes`, fed one at a time.
  var f = initInputFramer()
  for b in bytes:
    let (complete, token) = f.feed(b)
    if complete: result.add token

proc nextNonIdle(d: TerminalDriver; budgetMs = 1000): DriverEvent =
  ## The next event that is not `dekIdle`, or `dekIdle` if none came.
  let t0 = getMonoTime()
  while (getMonoTime() - t0).inMilliseconds < budgetMs:
    let ev = d.nextEvent(20)
    if ev.kind != dekIdle:
      return ev
  DriverEvent(kind: dekIdle)

proc drain(fd: cint): string =
  ## Everything waiting on `fd`, without blocking.
  var buf: array[4096, char]
  while true:
    var rs: TFdSet
    FD_ZERO(rs)
    FD_SET(fd, rs)
    var tv = Timeval(tv_sec: posix.Time(0), tv_usec: 0)
    if select(fd + 1, addr rs, nil, nil, addr tv) <= 0:
      break
    let got = read(fd, addr buf[0], buf.len)
    if got <= 0:
      break
    for i in 0 ..< got: result.add buf[i]

suite "focus reports: the decode":

  test "CSI I is a gained focus and CSI O a lost one":
    ck focusReportOf("\e[I") == frGained
    ck focusReportOf("\e[O") == frLost
    ck FocusInToken == "\e[I"
    ck FocusOutToken == "\e[O"

  test "nothing a key sends is a focus report":
    # `I` alone, Alt+Shift+I (`ESC I` in one burst), SS3 `I`, a CSI `I` with
    # parameters, and the neighbouring cursor keys.
    for token in ["I", "O", "\eI", "\eO", "\eOI", "\e[1;5I", "\e[2I",
                  "\e[A", "\e[Z", "\e", ""]:
      checkpoint("token " & token.escape)
      ck focusReportOf(token) == frNone

suite "focus reports: the framing":

  test "a report in one burst is one token, and names no key":
    ck frame("\e[I") == @["\e[I"]
    ck frame("\e[O") == @["\e[O"]
    # `keyName` answers "" for what is not a key — a report must never be
    # resolved by a keymap as, say, Shift+I or the `O` of an "open" binding.
    ck keyName("\e[I") == ""
    ck keyName("\e[O") == ""

  test "Esc followed by I in one burst is Alt+Shift+I, not a focus report":
    # The two-byte `ESC I` is a key chord (`InputFramer.feed`'s Alt arm), and
    # it does not become a report however it is read.
    let toks = frame("\eI")
    ck toks == @["\eI"]
    ck focusReportOf(toks[0]) == frNone
    ck keyName(toks[0]) == "Shift+Alt+i"

  test "a report between keys leaves the keys as they were":
    ck frame("a\e[Ib\e[Oc") == @["a", "\e[I", "b", "\e[O", "c"]

suite "focus reports: the driver's event, over a real pipe":

  test "CSI I arrives as dekFocus gained, never as a token":
    let (d, w) = inPipe()
    w.put("\e[I")
    let ev = d.nextNonIdle()
    ck ev.kind == dekFocus
    ck ev.focused
    ck d.nextNonIdle(150).kind == dekIdle

  test "CSI O arrives as dekFocus lost":
    let (d, w) = inPipe()
    w.put("\e[O")
    let ev = d.nextNonIdle()
    ck ev.kind == dekFocus
    ck not ev.focused

  test "a key behind a report is still the key":
    let (d, w) = inPipe()
    w.put("\e[Ij")
    let first = d.nextNonIdle()
    let second = d.nextNonIdle()
    ck first.kind == dekFocus and first.focused
    ck second.kind == dekToken and second.token == "j"

  test "a report absorbed while a trace was opening is still a focus event":
    # `absorbInterruptByte` frames the user's bytes during the handshake and
    # queues them for `nextEvent`; a window switch made then must come out as
    # focus, not as a token handed to the keymap after the trace opens.
    let (d, w) = inPipe()
    w.put("\e[I")
    var interrupted = false
    for _ in 0 ..< 3:
      interrupted = interrupted or d.absorbInterruptByte()
    ck not interrupted
    ck d.buffered == @["\e[I"]
    let ev = d.nextNonIdle()
    ck ev.kind == dekFocus and ev.focused

suite "focus reports: the request":

  proc startStopBytes(noMouse: bool): (string, string) =
    ## What `start` and then `stop` write to a real terminal, read back off
    ## the pty's master side.
    var (master, slave) = openPty()
    let d = newTerminalDriver(caps(noMouse), inFd = slave.fd,
                              outFd = slave.fd)
    d.start()
    let started = drain(master.fd)
    d.stop()
    let stopped = drain(master.fd)
    slave.close()
    master.close()
    (started, stopped)

  test "start asks for focus reporting with the mouse negotiated":
    let (started, stopped) = startStopBytes(noMouse = false)
    checkpoint("start: " & started.escape & "  stop: " & stopped.escape)
    ck started.contains("\e[?1000h")
    ck started.contains("\e[?1004h")
    ck stopped.contains("\e[?1004l")

  test "and without it: --no-mouse keeps the focus refresh":
    let (started, stopped) = startStopBytes(noMouse = true)
    checkpoint("start: " & started.escape & "  stop: " & stopped.escape)
    ck not started.contains("\e[?1000h")
    ck started.contains("\e[?1004h")
    ck stopped.contains("\e[?1004l")

  test "stop undoes it before the alternate screen is left":
    let (_, stopped) = startStopBytes(noMouse = false)
    let off = stopped.find("\e[?1004l")
    let leave = stopped.find("\e[?1049l")
    ck off >= 0
    ck leave >= 0
    ck off < leave

suite "focus reporting — assertion tally":
  test "CHECKS":
    echo "CHECKS: ", CHECKS
    check CHECKS == 42
