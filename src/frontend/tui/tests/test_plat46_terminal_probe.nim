## test_plat46_terminal_probe.nim — PLAT-46 deliverables 5 and 8, Tier 1: what
## the start-up query round ASKS and how its ANSWERS are read.
##
## `app/tests/test_capability_resolution.nim` asserts what a `TerminalProbe`
## MEANS. This suite asserts how one is FILLED — from real reply bytes, framed by
## the driver's own `InputFramer`, parsed by `host/terminal_probe.noteReply` —
## and what is written down the tty for each command line. The real-terminal
## half (a PTY that answers, a real tmux) is
## `tests/real_terminal/test_plat46_design_tokens.nim`.
##
## ## No mocks
##
## The reply strings are the byte sequences xterm, kitty and tmux send, written
## out here; the framer and the parser are the shipped ones. Nothing is
## substituted.

import std/[strutils, unittest]

import ../host/terminal_driver
import ../host/terminal_probe

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 45

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

proc frame(bytes: string; expect: bool): seq[string] =
  ## Every complete token `bytes` frames into, with reply strings expected or
  ## not.
  var f = initInputFramer()
  f.expectStrings = expect
  for b in bytes:
    let (complete, token) = f.feed(b)
    if complete:
      result.add token

suite "PLAT-46: the start-up query round":

  test "what is asked depends on what is still a question":
    let all = queriesFor(initCapabilityFlags())
    ck all.contains(Osc11Query)
    ck all.contains(XtGetTcapQuery)
    ck all.contains(DecrqssQuery)
    ck all.endsWith(Da1Query)
    # --theme pins the mode: the background is not asked.
    let pinned = queriesFor(initCapabilityFlags(theme = utLight,
                                                themePinned = true))
    ck not pinned.contains(Osc11Query)
    ck pinned.contains(DecrqssQuery)
    # --truecolor pins the depth: no 24-bit question, and no 24-bit SGR.
    let forced = queriesFor(initCapabilityFlags(forceTrueColor = true))
    ck forced.contains(Osc11Query)
    ck not forced.contains(DecrqssQuery)
    ck not forced.contains("48:2")
    # --palette=terminal: sixteen colours were asked for, so no 24-bit probe
    # SGR may enter the byte stream.
    let term = queriesFor(initCapabilityFlags(palette = pkTerminal))
    ck not term.contains("48:2")
    ck not term.contains(XtGetTcapQuery)
    ck term.contains(Osc11Query)

  test "the framer delivers each reply whole, only while replies are expected":
    let burst = "\x1b]11;rgb:ffff/ffff/ffff\x1b\\" &
                "\x1bP1+r524742=\x1b\\" &
                "\x1bP1$r0;48:2::1:2:3m\x1b\\" &
                "\x1b[?62;22c"
    let tokens = frame(burst, expect = true)
    checkpoint($tokens)
    ck tokens.len == 4
    for t in tokens:
      ck isReplyToken(t)
    # OUTSIDE the round, `ESC ]` keeps meaning Alt+`]`: the ESC is dropped and
    # the byte honoured, so a late-typed Alt key is never swallowed.
    let keys = frame("\x1b]", expect = false)
    ck keys == @["]"]
    # A BEL-terminated OSC is a whole token too (xterm answers in the query's
    # own terminator).
    ck frame("\x1b]11;rgb:1e/1e/2e\x07", expect = true).len == 1

  test "each answer lands in the probe":
    var p = TerminalProbe()
    ck noteReply(p, "\x1b]11;rgb:ffff/ffff/ffff\x1b\\")
    ck p.hasBackground
    ck p.background == (255, 255, 255)
    var dec = TerminalProbe()
    for reply in ["\x1bP1$r0;48:2::1:2:3m\x1b\\", "\x1bP1$r48:2:1:2:3m\x1b\\",
                  "\x1bP1$r0;48;2;1;2;3m\x1b\\"]:
      dec = TerminalProbe()
      ck noteReply(dec, reply)
      ck dec.truecolor
      ck dec.truecolorVia == "decrqss"
    # An APPROXIMATED colour is not 24-bit: xterm without direct colour
    # answers with a palette index.
    var approx = TerminalProbe()
    ck noteReply(approx, "\x1bP1$r0;48;5;16m\x1b\\")
    ck not approx.truecolor
    # An INVALID DECRQSS (`0$r`) is a reply and claims nothing.
    var invalid = TerminalProbe()
    ck noteReply(invalid, "\x1bP0$r\x1b\\")
    ck not invalid.truecolor
    # XTGETTCAP: `RGB` hex-encoded is 524742.
    var cap = TerminalProbe()
    ck noteReply(cap, "\x1bP1+r524742=382f382f38\x1b\\")
    ck cap.truecolor
    ck cap.truecolorVia == "xtgettcap"
    var tc = TerminalProbe()
    ck noteReply(tc, "\x1bP1+r5463\x1b\\")
    ck tc.truecolor
    # DA1: the fence.
    var da = TerminalProbe()
    ck noteReply(da, "\x1b[?62;22c")
    ck da.answered
    # A KEY is not a reply.
    var key = TerminalProbe()
    ck not noteReply(key, "\x1b[A")
    ck not noteReply(key, "q")
    ck not key.attempted

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    check countedAssertions == ExpectedAssertions
