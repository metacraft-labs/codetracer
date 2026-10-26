## test_plat54_gpui_agent_activity.nim — PLAT-54: **Agent Activity in the
## GPUI window**, read from the window's own render plan.
##
## The shipped `codetracer-gpui` (`just build-gpui`) on the `calc` recording,
## with `--report-window-plan` and `--window-ops` events dispatched through
## the window's own pointer and key handlers. Asserted:
##
##   * A RECORDED SESSION, resolved the way `ct review` resolves it (the
##     production `ct/review_session.resolveReviewSession` over the AA-3
##     replay agent through `nim-agents`, `writeResolvedReviewSession`'s
##     document handed over as `--review-session`): the pane's lines are the
##     shared feed's, with one evidence card per handoff in its state and an
##     `[Open review]` exactly where the dataset was read;
##   * AN EVIDENCE CLICK LOADS THE DATASET: the card's button, pressed where
##     the window drew it, enters the review in the VCS pane, which then
##     shows that dataset's title and its Changed Files; the second card's
##     button replaces it with the other dataset's;
##   * A `ct test` RUN: the summary card opens to its tests on a press, and a
##     recorded test's `[Open in new tab]` opens the recording AS A SESSION
##     TAB (the strip gains the tab);
##   * A LIVE SESSION OVER THE REAL ACP IPC: `/ai <prompt>` typed into the
##     omnibox starts the replay agent (answering `session/new` and streaming
##     `session/prompt` updates) on the worker thread; after the turn the
##     pane holds the agent's rows, the user's turn first, and the session
##     tab's agent indicator (`data-ct-tab-agent`) says the agent completed
##     while the pane's control says Send — the two read one store entry.
##
## No mocks. The agent is the AA suites' documented ACP test double
## (`agent-activity-deepreview/fixtures/acp-replay-agent.js`, justified in
## its header); the window, its host and every projection are production
## code.

import replay_prerequisite
import std/[json, os, osproc, streams, strtabs, strutils, tempfiles, unittest]

import ../../tui/tests/fixtures/fixture_provider
import ../../../ct/review_session

var CHECKS = 0
template ck(cond: untyped) =
  inc CHECKS
  check(cond)

const
  ExpectedAssertions = 28
  StateDirEnvVar = "CODETRACER_TUI_LAYOUT_DIR"
  W = 1600
  H = 1000

let repo = getEnv("CODETRACER_REPO_ROOT", getCurrentDir())
let bin = repo / "build/bin/codetracer-gpui"
let shimDir = getEnv("ISONIM_GPUI_SHIM_DIR",
                   repo.parentDir / "isonim-gpui/rust/target/debug")
let replayAgent = repo / "src/tests/gui/tests/agent-activity-deepreview" /
                  "fixtures/acp-replay-agent.js"
let sampleReview = repo / "src/tests/gui/tests/deepreview/fixtures" /
                   "sample-review.json"
let scratch = createTempDir("plat54-gpui-", "")
let evidenceDir = scratch / "evidence"

let calc = resolveFixture("calc")
doAssert calc.outcome == foRecorded, calc.detail
let trace = calc.tracePath

proc writeDataset(target, title: string; first, last: int) =
  var d = parseJson(readFile(sampleReview))
  d["sessionTitle"] = %title
  var files = newJArray()
  for i in first ..< last:
    files.add d["files"][i]
  d["files"] = files
  createDir(parentDir(target))
  writeFile(target, $d)

proc resolveSession(args: seq[string]): string =
  ## What `ct review <PATH>` does with a dataset's session reference.
  let spec = ReviewSessionRefSpec(sessionId: "session-fixture", backend: "acp",
                                  workspacePath: scratch,
                                  agentCommand: findExe("node"),
                                  agentArgs: @[replayAgent] & args)
  writeResolvedReviewSession(resolveReviewSession(spec), scratch)

proc windowPlan(ops: string; extra: seq[string] = @[];
                env2: seq[(string, string)] = @[]):
    tuple[plan: JsonNode, trace: string] =
  ## The window's root after `ops`, and its gesture trace.
  if not fileExists(bin):
    raise newException(IOError, "prerequisite missing: " & bin &
                       " (just build-gpui)")
  let state = createTempDir("plat54-gpui-plan-", "")
  var env = newStringTable()
  for k, v in envPairs():
    env[k] = v
  env["LD_LIBRARY_PATH"] = shimDir &
    (if existsEnv("LD_LIBRARY_PATH"): ":" & getEnv("LD_LIBRARY_PATH") else: "")
  env[StateDirEnvVar] = state
  env["XDG_STATE_HOME"] = state
  env["CODETRACER_HOME"] = state / "ct-home"
  env["CODETRACER_GPUI_GESTURE_TRACE"] = "1"
  for (k, v) in env2:
    env[k] = v
  let errFile = genTempPath("plat54-gpui-plan-", ".err")
  let args = @["--report-window-plan", "--width=" & $W, "--height=" & $H,
               "--window-ops=" & ops] & extra & @[trace]
  let p = startProcess("/bin/sh",
    args = @["-c", "exec \"$0\" \"$@\" 2>" & quoteShell(errFile), bin] & args,
    env = env, options = {})
  let output = p.outputStream.readAll()
  let rc = p.waitForExit()
  p.close()
  result.trace = if fileExists(errFile): readFile(errFile) else: ""
  removeFile(errFile)
  removeDir(state)
  if rc != 0:
    checkpoint("codetracer-gpui exited " & $rc & ": " & result.trace)
    raise newException(IOError, "the window plan run failed (" & ops & ")")
  result.plan = parseJson(output)

proc attr(n: JsonNode; name: string): string =
  if n{"attributes"}.kind == JObject: n["attributes"]{name}.getStr else: ""

proc has(n: JsonNode; name: string): bool =
  n{"attributes"}.kind == JObject and n["attributes"].hasKey(name)

proc nodesWith(plan: JsonNode; attribute: string): seq[JsonNode] =
  proc walk(n: JsonNode; acc: var seq[JsonNode]) =
    if n.kind != JObject: return
    if n.has(attribute): acc.add n
    for c in n{"children"}.getElems: walk(c, acc)
  walk(plan, result)

proc textOf(n: JsonNode): string =
  if n{"kind"}.getStr == "TextNode": return n{"text"}.getStr
  for c in n{"children"}.getElems: result.add textOf(c)

proc lines(plan: JsonNode): seq[(string, string, string)] =
  ## Every painted Agent Activity row's first line: its row kind, state and
  ## text.
  for n in plan.nodesWith("data-ct-agent-line"):
    if n.attr("data-ct-agent-part") == "0":
      result.add (n.attr("data-ct-agent-line"), n.attr("data-ct-agent-state"),
                  n.attr("data-ct-agent-text"))

proc allText(plan: JsonNode): string = textOf(plan)

writeDataset(evidenceDir / "iteration-1.json", "Iteration one", 0, 2)
writeDataset(evidenceDir / "iteration-2.json", "Iteration two", 2, 3)

suite "PLAT-54: Agent Activity in the GPUI window":

  test "a recorded session: the cards, and a click loads each dataset":
    let session = resolveSession(@["--evidence",
                                   "--evidence-dir=" & evidenceDir])
    ck session.len > 0
    let flag = "--review-session=" & session
    let (plan, _) = windowPlan("agent:show", @[flag])
    let pane = plan.nodesWith("data-ct-agent")
    ck pane.len == 1
    # The pane follows the session's newest turn: its last card — the
    # unreported handoff — is on screen, in its state.
    var states: seq[string] = @[]
    for (kind, state, _) in plan.lines:
      if kind == "evidence-header": states.add state
    ck "unreported" in states
    ck "schemaVersion" notin plan.allText
    # THE CLICK: the first card's `[Open review]`, where it was drawn.
    let (first, tr1) = windowPlan("agent:show,agent:button:Open review:0," &
                                  "agent:vcs", @[flag])
    ck tr1.contains("Review: Iteration one")
    ck first.allText.contains("Iteration one")
    ck first.allText.contains("main.rs")
    ck first.allText.contains("utils.rs")
    let (second, tr2) = windowPlan("agent:show,agent:button:Open review:0," &
                                   "agent:button:Open review:1,agent:vcs",
                                   @[flag])
    ck tr2.contains("Review: Iteration two")
    ck second.allText.contains("Iteration two")
    ck second.allText.contains("config.rs")
    ck not second.allText.contains("utils.rs")

  test "a ct test run: the card opens, a recording opens as a tab":
    let session = resolveSession(@["--test-run", "--trace-dir=" & trace])
    let flag = "--review-session=" & session
    let (closed, _) = windowPlan("agent:show", @[flag])
    var runs = 0
    var rows = 0
    for (kind, state, _) in closed.lines:
      if kind == "test-run":
        inc runs
        ck state == "failed"
      if kind == "test-row": inc rows
    ck runs == 1
    ck rows == 0
    let (open, _) = windowPlan("agent:show,agent:row:test-run", @[flag])
    var names: seq[string] = @[]
    for (kind, state, text) in open.lines:
      if kind == "test-row": names.add text
    ck names.len == 3
    ck names.join(" ").contains("test_add")
    # One session: no strip (the desktop draws its tabs from two on).
    ck open.nodesWith("data-ct-session-tab").len == 0
    let (tabbed, tr) = windowPlan("agent:show,agent:row:test-run," &
                                  "agent:button:Open in new tab:0", @[flag])
    ck tr.contains("opened " & trace)
    ck tabbed.nodesWith("data-ct-session-tab").len == 2

  test "a live session: rows arrive over ACP, the tab and the pane agree":
    let env2 = @[("CODETRACER_AGENT_ACP_COMMAND", findExe("node")),
                 ("CODETRACER_AGENT_ACP_ARGS",
                  replayAgent & " --evidence --evidence-dir=" & evidenceDir &
                  " --live-delay-ms=50")]
    let (idle, _) = windowPlan("agent:show", env2 = env2)
    var idleKinds: seq[string] = @[]
    for (kind, _, _) in idle.lines: idleKinds.add kind
    ck "idle-heading" in idleKinds
    # A second session tab first — the recorded test's recording, opened
    # from a review's run card — so the strip, which the desktop draws from
    # two sessions on, is there to carry the agent's indicator.
    let session = resolveSession(@["--test-run", "--trace-dir=" & trace])
    let (plan, tr) = windowPlan("agent:show,agent:row:test-run," &
                                "agent:button:Open in new tab:0,agent:show," &
                                "key:p:control," &
                                "type:/ai collect the review,key:enter," &
                                "wait:20000",
                                @["--review-session=" & session], env2 = env2)
    ck tr.contains("agent: sent collect the review")
    var kinds: seq[string] = @[]
    var texts = ""
    for (kind, _, text) in plan.lines:
      kinds.add kind
      texts.add text & "\n"
    ck "evidence-header" in kinds
    ck texts.contains("Collected review evidence")
    # The tab the agent ran in says it completed; the review's tab has no
    # agent at all.
    let tabs = plan.nodesWith("data-ct-tab-agent")
    ck tabs.len == 1
    ck tabs[0].attr("data-ct-tab-agent") == "aslCompleted"
    let control = plan.nodesWith("data-ct-agent-control")
    ck control.len == 1 and control[0].attr("data-ct-agent-control") == "Send"
    let pane = plan.nodesWith("data-ct-agent")
    ck pane.len == 1 and pane[0].attr("data-ct-agent-working") == "false"

  test "assertion count":
    echo "CHECKS: " & $CHECKS
    check CHECKS == ExpectedAssertions

removeDir(scratch)
