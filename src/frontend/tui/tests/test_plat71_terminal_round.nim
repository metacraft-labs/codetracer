## test_plat71_terminal_round.nim — PLAT-71, Tier 1. The start-up round as
## bytes (CodeTracer-TUI-Terminal-Adaptation.md §4.2, §4.3): what is asked and
## in what order, the restricted round for the Linux console, and §4.3's F3
## rule — a `CSI 1 ; 5 R` is a cursor report only while the width probe waits.
##
## The captured personas (`app/tests/personas/`, the bytes real terminals wrote
## back to this round): the round each was captured against is this round,
## byte for byte, so a change to the round that the personas no longer answer
## shows here; and the shipped `noteReply`, fed each persona's replies, builds
## the same probe as `personas.probeOf`, the reading `app/tests/` uses because
## it may not import `host/`.
##
## Here rather than beside `app/tests/test_plat71_terminal_profile.nim`
## because the round is `host/terminal_probe`'s, which `app/tests/` may not
## import. No mocks: the subject is the shipped round and reply reader,
## called directly on bytes a terminal's documentation gives.
##
## Templates, not procs, for anything that calls `check`.

import std/[strutils, unicode, unittest]

import ../host/terminal_probe
import ../app/tests/personas/personas

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count.
const ExpectedAssertions = 78
  ## 48 -> 78, measured: the six probe code points (+6) and the six captured
  ## personas, four checks each (+24).

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

let utf8Env = initTerminalEnv(term = "xterm-256color", lang = "en_US.UTF-8")

suite "PLAT-71 Tier 1: the start-up round":

  test "§4.2: the round asks every new question, the fence last":
    let q = queriesFor(initCapabilityFlags(), utf8Env, 80)
    for query in [XtversionQuery, Da2Query, SyncModeQuery, GraphemeModeQuery]:
      ck q.contains(query)
    ck q.count(CursorReportQuery) == 6
    ck cprCountFor(utf8Env, 80) == 6
    ck q.endsWith(Da1Query)
    # The width probe is answered BEFORE the fence: every CPR query precedes
    # DA1, and the probe row is erased in the same write.
    ck q.rfind(CursorReportQuery) < q.rfind(Da1Query)
    ck q.contains("\x1b[1;1H\x1b[2K")
    for p in WidthProbe:
      ck q.contains(WidthProbeText[p] & CursorReportQuery)
    # Each probe prints the code points §4.3 names — and nothing else. The
    # real-emulator lane found P3 and P6 written as `\U0001FB87`, which Nim
    # reads as U+0001 and the text `FB87`: every terminal measured a control
    # character and four letters instead of the glyph.
    ck WidthProbeText[wpLegacy].toRunes == @[Rune(0x1FB87)]
    ck WidthProbeText[wpCluster].toRunes ==
      @[Rune(0x1F469), Rune(0x200D), Rune(0x1F4BB)]
    ck WidthProbeText[wpEllipsis].toRunes == @[Rune(0x2026)]
    ck WidthProbeText[wpBlock].toRunes == @[Rune(0x2595)]
    ck WidthProbeText[wpPicto].toRunes == @[Rune(0x23EE)]
    ck WidthProbeText[wpWide].toRunes == @[Rune(0x4E2D)]
    # The Linux console: only the width probe and the fence.
    let linux = queriesFor(initCapabilityFlags(),
                           initTerminalEnv(term = "linux"), 80)
    ck linux.endsWith(Da1Query)
    ck not linux.contains(XtversionQuery)
    ck not linux.contains(Osc11Query)
    ck linux.count(CursorReportQuery) == 6
    # A terminal narrower than three columns skips the width probe.
    ck not queriesFor(initCapabilityFlags(), utf8Env, 2).contains(
      CursorReportQuery)
    ck cprCountFor(utf8Env, 2) == 0

  test "§4.3's F3 rule: a CSI 1;5R is a reply only while the probe waits":
    var p = TerminalProbe(attempted: true, cprExpected: 2)
    ck p.cprOpen
    ck p.isReplyTokenFor("\x1b[1;5R")
    ck noteReply(p, "\x1b[1;5R")
    ck p.cprAnswers == @[4]
    ck noteReply(p, "\x1b[1;2R")
    ck not p.cprOpen
    # After the window: Ctrl+F3 again, never consumed.
    ck not p.isReplyTokenFor("\x1b[1;5R")
    ck not noteReply(p, "\x1b[1;5R")
    ck p.cprAnswers == @[4, 1]
    # The other new replies.
    ck noteReply(p, "\x1bP>|foot(1.16.2)\x1b\\")
    ck p.xtversion == "foot(1.16.2)"
    ck noteReply(p, "\x1b[>1;11602;0c")
    ck p.da2Answered and p.da2Pv == 11602
    ck noteReply(p, "\x1b[?2026;2$y")
    ck p.sync2026Answered and p.sync2026 == 2
    ck noteReply(p, "\x1b[?2027;0$y")
    ck p.grapheme2027Answered and p.grapheme2027 == 0
    # A key is never taken for an answer.
    ck not noteReply(p, "q")
    ck not noteReply(p, "\x1b[A")

  test "§4.3's F3 rule: the window closes with the round, reports owed or not":
    # A terminal that answers the fence but no cursor report: the reports
    # are asked before the fence, so none is still coming after it.
    var fenced = TerminalProbe(attempted: true, cprExpected: 6)
    ck fenced.cprOpen
    ck noteReply(fenced, "\x1b[?62;22c")
    ck not fenced.cprOpen
    ck not fenced.isReplyTokenFor("\x1b[1;5R")
    # A terminal that answers nothing: once `ReplyWindowMs` has passed (the
    # main loop's `closeReplyWindow`), Ctrl+F3 is a key again.
    var silent = TerminalProbe(attempted: true, cprExpected: 6)
    ck silent.isReplyTokenFor("\x1b[1;5R")
    silent.replyWindowClosed = true
    ck not silent.cprOpen
    ck not noteReply(silent, "\x1b[1;5R")
    ck silent.cprAnswers.len == 0

  test "the captured personas: their round is this round, and noteReply reads them as probeOf does":
    for c in capturedPersonas():
      checkpoint(c.provenance)
      ck queriesFor(initCapabilityFlags(), envOf(c), c.cols) == c.round
      var shipped = TerminalProbe(attempted: true, cprExpected: 6)
      for token in c.replies:
        discard noteReply(shipped, token)
        if shipped.answered: break
      var read = c.probeOf()
      # `noteReply` does not time the round; `runStartupProbe` does.
      read.rttMeasured = false
      read.rttMs = 0
      ck shipped == read
      ck shipped.answered
      ck shipped.cprAnswers.len == 6

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
