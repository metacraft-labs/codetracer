## test_plat54_agent_activity_pty.nim — PLAT-54, Tier 2. **Agent Activity on
## a real terminal.**
##
## The shipped `codetracer-tui` on the `calc` recording, driven as a user
## drives it, read back off the screen through libvterm:
##
##   * `--review-session=<file>` — the document `ct review` writes for a
##     review's agent session, produced here by the production
##     `ct/review_session.resolveReviewSession` over the AA-3 replay agent
##     through `nim-agents` — fills Agent Activity: its tab pressed, the
##     session's evidence cards are on the screen with `[Open review]`;
##   * a press on the first `[Open review]` enters that dataset's review: the
##     VCS pane, its tab pressed, shows the review's title and its files;
##   * A LIVE SESSION: `Ctrl+P`, `/ai collect the review`, `Enter` — the
##     replay agent started over its real stdio, answering `session/prompt`
##     with streamed updates — and the agent's rows arrive on the screen; the
##     session tab carries the agent's indicator, ✓ once the turn is over, and
##     the prompt row's control is `[Send]` again.
##
## No mocks: the real binary, a real recording, a real `replay-server`, a
## real pty (TermAssert + libvterm), a real agent process speaking ACP. The
## agent is the AA suites' documented test double
## (`agent-activity-deepreview/fixtures/acp-replay-agent.js`, justified in its
## header: a production agent cannot hold a known session on demand).

import std/[json, monotimes, os, strutils, times, unittest]
from std/unicode import runeLen

import term_assert

import ../fixtures/fixture_provider
import ./lifecycle_support
import ../../../../ct/review_session

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 10

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 200
  Rows = 50
  CtrlP = "\x10"
  Enter = "\r"

let root = lifecycle_support.repoRoot()
let replayAgent = root / "src/tests/gui/tests/agent-activity-deepreview" /
                  "fixtures/acp-replay-agent.js"
let sampleReview = root / "src/tests/gui/tests/deepreview/fixtures" /
                   "sample-review.json"
let scratch = getTempDir() / ("plat54-pty-" & $getCurrentProcessId())
let evidenceDir = scratch / "evidence"

proc writeDataset(target, title: string; first, last: int) =
  var d = parseJson(readFile(sampleReview))
  d["sessionTitle"] = %title
  var files = newJArray()
  for i in first ..< last:
    files.add d["files"][i]
  d["files"] = files
  createDir(parentDir(target))
  writeFile(target, $d)

proc rowOf(sess: var TuiTestSession; row: int): string =
  sess.regionText(row, 0, Cols, 1).split('\n')[0]

proc screen(sess: var TuiTestSession): seq[string] =
  discard sess.drainOutput(60)
  for r in 0 ..< Rows:
    result.add sess.rowOf(r)

proc waitScreen(sess: var TuiTestSession; needle: string;
                timeoutMs = 60000): seq[string] =
  let deadline = getMonoTime() + initDuration(milliseconds = timeoutMs)
  while getMonoTime() < deadline:
    result = sess.screen()
    for line in result:
      if line.contains(needle):
        return
    sleep(50)
  raise newException(AssertionFailedError,
    "'" & needle & "' never appeared; screen:\n" & result.join("\n"))

proc find(s: seq[string]; needle: string): (int, int) =
  for r, line in s:
    let at = line.find(needle)
    if at >= 0:
      return (r, line[0 ..< at].runeLen)
  (-1, -1)

proc press(sess: var TuiTestSession; row, col: int) =
  sess.send("\x1b[<0;" & $(col + 1) & ";" & $(row + 1) & "M")
  sess.send("\x1b[<0;" & $(col + 1) & ";" & $(row + 1) & "m")

proc wheelUp(sess: var TuiTestSession; row, col, times: int) =
  for _ in 0 ..< times:
    sess.send("\x1b[<64;" & $(col + 1) & ";" & $(row + 1) & "M")
    sleep(10)

proc spawnTui(args: seq[string]; env: seq[(string, string)] = @[]):
    TuiTestSession =
  var builder = newTuiTest(tuiBinary(), args)
    .width(Cols).height(Rows)
    .transcript()
    .envRemove("COLORTERM", "TERM_PROGRAM", "NO_COLOR", "LC_ALL", "LC_CTYPE")
    .envSet("TERM", "xterm-256color")
    .envSet("LANG", "en_US.UTF-8")
    .envSet("CODETRACER_TUI_LAYOUT_DIR", scratch / "layout")
    .carryRunMark()
  for (k, v) in env:
    builder = builder.envSet(k, v)
  builder.spawn()

proc showAgent(sess: var TuiTestSession) =
  let s = sess.waitScreen(" Agent Activity ")
  let (r, c) = s.find("Agent Activity")
  sess.press(r, c + 1)

createDir(scratch)
writeDataset(evidenceDir / "iteration-1.json", "Iteration one", 0, 2)
writeDataset(evidenceDir / "iteration-2.json", "Iteration two", 2, 3)
let calc = resolveFixture("calc")

suite "PLAT-54 on a real terminal: Agent Activity":

  test "a review's session: the cards, and Open review fills the VCS pane":
    doAssert calc.outcome == foRecorded, calc.detail
    let spec = ReviewSessionRefSpec(sessionId: "session-fixture",
      backend: "acp", workspacePath: scratch, agentCommand: findExe("node"),
      agentArgs: @[replayAgent, "--evidence", "--evidence-dir=" & evidenceDir])
    let sessionFile = writeResolvedReviewSession(resolveReviewSession(spec),
                                                 scratch)
    ck sessionFile.len > 0
    var sess = spawnTui(@["--review-session=" & sessionFile, calc.tracePath])
    defer: sess.close()
    sess.showAgent()
    # The pane follows the session's newest turn; the wheel takes it back to
    # the start, where the first card is the first collection.
    var s = sess.waitScreen("Collected review evidence")
    let (pr, pc) = s.find("Collected review evidence")
    sess.wheelUp(pr, pc, 30)
    s = sess.waitScreen("Collecting the first review")
    let (br, bc) = s.find("[Open review]")
    ck br >= 0
    sess.press(br, bc + 2)
    let tabs = sess.screen()
    let (vr, vc) = tabs.find(" VCS ")
    ck vr >= 0
    sess.press(vr, vc + 2)
    s = sess.waitScreen("Iteration one")
    ck s.join("\n").contains("CHANGED FILES")
    ck s.join("\n").contains("main.rs")

  test "a run card opens a recording as a tab; a live agent there over ACP":
    # A review's `ct test` run, its recorded test opened in a NEW TAB — the
    # real `recordingOpener` — and in that tab a live agent, so the strip
    # (drawn from two sessions on, as the desktop's) carries its indicator.
    let spec = ReviewSessionRefSpec(sessionId: "session-fixture",
      backend: "acp", workspacePath: scratch, agentCommand: findExe("node"),
      agentArgs: @[replayAgent, "--test-run", "--trace-dir=" & calc.tracePath])
    let sessionFile = writeResolvedReviewSession(resolveReviewSession(spec),
                                                 scratch)
    var sess = spawnTui(@["--review-session=" & sessionFile, calc.tracePath], @[
      ("CODETRACER_AGENT_ACP_COMMAND", findExe("node")),
      ("CODETRACER_AGENT_ACP_ARGS", replayAgent & " --evidence " &
        "--evidence-dir=" & evidenceDir & " --live-delay-ms=100")])
    defer: sess.close()
    sess.showAgent()
    # The run's card (its edge mark, its closed triangle), pressed open.
    var s = sess.waitScreen("▌ ▸")
    let (rr, rc) = s.find("▌ ▸")
    sess.press(rr, rc + 2)
    s = sess.waitScreen("[Open in new tab]")
    let (nr, nc) = s.find("[Open in new tab]")
    sess.press(nr, nc + 2)
    s = sess.waitScreen(" × ", 120000)      # a second tab: closable tabs
    ck s[0].contains("calc")
    sess.showAgent()
    discard sess.waitScreen("Start an agent task")
    sess.send(CtrlP)
    sleep(150)
    sess.send("/ai collect the review")
    sleep(100)
    sess.send(Enter)
    s = sess.waitScreen("collect the review")
    ck s.join("\n").contains("collect the review")
    s = sess.waitScreen("Collected review evidence", 60000)
    ck s.join("\n").contains("Collected review evidence")
    # The turn over: the tab's indicator says done and the control is Send.
    let deadline = getMonoTime() + initDuration(milliseconds = 60000)
    var done = false
    while getMonoTime() < deadline:
      s = sess.screen()
      if s[0].contains("✓") and s.join("\n").contains("[Send]"):
        done = true
        break
      sleep(100)
    if not done:
      checkpoint(s.join("\n"))
    ck done
    ck not s.join("\n").contains("[Stop]")

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions

removeDir(scratch)
