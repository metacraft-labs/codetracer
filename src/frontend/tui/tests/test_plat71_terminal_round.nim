## test_plat71_terminal_round.nim — PLAT-71, Tier 1. The start-up round as
## bytes (CodeTracer-TUI-Terminal-Adaptation.md §4.2, §4.3): what is asked and
## in what order, the restricted round for the Linux console, and §4.3's F3
## rule — a `CSI 1 ; 5 R` is a cursor report only while the width probe waits.
##
## Here rather than beside `app/tests/test_plat71_terminal_profile.nim`
## because the round is `host/terminal_probe`'s, which `app/tests/` may not
## import. No mocks: the subject is the shipped round and reply reader,
## called directly on bytes a terminal's documentation gives.
##
## Templates, not procs, for anything that calls `check`.

import std/[strutils, unittest]

import ../host/terminal_probe

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count.
const ExpectedAssertions = 48

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

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions
