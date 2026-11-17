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
const ExpectedAssertions = 61

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

proc frame(bytes: string; expect: bool; kitty = false): seq[string] =
  ## Every complete token `bytes` frames into, with reply strings expected or
  ## not, and with the Kitty keyboard protocol on or not.
  var f = initInputFramer()
  f.expectStrings = expect
  f.altChordsAsCsiU = kitty
  for b in bytes:
    let (complete, token) = f.feed(b)
    if complete:
      result.add token
    if f.extra.len > 0:
      result.add f.extra     # the byte that broke a held introducer (§4.3)
      f.extra = ""

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
    # OUTSIDE the round, `ESC ]` is HELD (§4.3): nothing is delivered until
    # the next byte, or `EscDelayMs` with none, says whether an answer
    # follows. Alone it is still Alt+`]` — the byte honoured, the ESC
    # dropped — so a late-typed Alt key is never swallowed.
    var held = initInputFramer()
    for b in "\x1b]": discard held.feed(b)
    ck held.holdsStringIntro
    ck held.escDue(held.escSinceMs + EscDelayMs)
    ck held.introKey == "]"
    # Followed by a byte that begins no answer, it is that key, then the byte.
    ck frame("\x1b]x", expect = false) == @["]", "x"]
    ck frame("\x1bPq", expect = false) == @["P", "q"]
    # A BEL-terminated OSC is a whole token too (xterm answers in the query's
    # own terminator).
    ck frame("\x1b]11;rgb:1e/1e/2e\x07", expect = true).len == 1

  test "under the Kitty protocol a reply is framed whole even outside the round":
    # Kitty's flag 1 sends Alt+<key> as `CSI … u`, so `ESC ]` can only be a
    # terminal's answer: a LATE OSC 52 answer — kitty and Ghostty ask the
    # user before a program may read the clipboard, so theirs arrives after
    # the paste's wait — is one reply token, not `]` and text.
    let late = "\x1b]52;c;WlFYSi1sYXRl\x1b\\"
    let tokens = frame(late, expect = false, kitty = true)
    checkpoint($tokens)
    ck tokens == @[late]
    # tmux answers with an empty selection field, in BEL.
    ck frame("\x1b]52;;WlFYSg==\x07", expect = false, kitty = true).len == 1
    # Without the protocol, outside the round, it is an answer too (§4.3):
    # framed whole, and dropped by the loop as a string — never text.
    ck frame(late, expect = false) == @[late]

  test "§4.3: an answer outside the reply window is framed whole and never typed":
    # A DECRQSS answer arriving after the window (a slow link, or a terminal
    # that answered after the fence) once reached the document as `P1$r…`.
    let late = "\x1bP1$r48:2:1:2:3m\x1b\\"
    let tokens = frame(late, expect = false)
    ck tokens == @[late]
    ck isStringToken(tokens[0])
    ck frame("\x1bP>|kitty(0.44.0)\x1b\\", expect = false).len == 1
    ck frame("\x1b]11;rgb:1e/1e/2e\x07", expect = false).len == 1
    ck frame("\x1b_Gi=31;OK\x1b\\", expect = false).len == 1
    # Split across two reads, the answer is still one token.
    var f = initInputFramer()
    var got: seq[string] = @[]
    for part in ["\x1bP1$r48:2", ":1:2:3m\x1b\\"]:
      for b in part:
        let (complete, token) = f.feed(b)
        if complete: got.add token
    ck got == @[late]
    # Keys are not strings: an Alt chord, a CSI key, a lone byte.
    ck not isStringToken("\x1bp")
    ck not isStringToken("\x1b[1;5R")
    ck not isStringToken("P")

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
