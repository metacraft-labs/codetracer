## test_plat54_agent_activity.nim — PLAT-54, Tier 1: **the terminal's Agent
## Activity pane**, painted from its value and driven through the product's
## runtime over the REAL host, a REAL replay session and a REAL agent.
##
## Specs: DeepReview-GUI.md §2.1 (the panel in a review), §2.1.1 (evidence
## tool calls load their dataset), §2.1.2 (`ct test` runs as summaries);
## Agent-Activity-Panel.milestones.org AA-2 / AA-3; PLAT-54's deliverables.
##
##   * THE RECORDED SESSION, resolved the way `ct review` resolves it: the
##     production `ct/review_session.resolveReviewSession` spawns the AA-3
##     replay agent over real stdio through `nim-agents`, issues
##     `session/load`, and `writeResolvedReviewSession` writes the document
##     `--review-session` hands a window. The pane paints one evidence card per
##     handoff, each in its state (ready with its shape and `[Open review]`,
##     unavailable naming the reader, failed with the command's own output,
##     unreported), and no runner bytes;
##   * AN EVIDENCE CLICK LOADS THE DATASET: `[Open review]`, pressed with SGR
##     bytes on the cell it was painted in, enters a review through the
##     production `review_entry.enterReview` over the VCS pane's own
##     `VCSVM` — the pane then shows that dataset's title and Changed Files —
##     and the second card REPLACES it with the other dataset's changeset;
##   * A `ct test` RUN (the AA-2 replay): a summary card, expanded by a press,
##     its recorded test's `[Open in new tab]` handing the window a real
##     recording (the calc fixture's folder), its failed test offering none;
##   * A LIVE SESSION OVER THE REAL ACP IPC: `/ai <prompt>` typed into the
##     omnibox starts the agent (the same replay agent, now answering
##     `session/new` and streaming `session/prompt` updates 150 ms apart) on
##     its worker thread; rows arrive tick by tick; the session tab's agent
##     indicator (`session_tabs.agentOf`, what the strip draws) says running
##     exactly while the pane's prompt says Stop, and both say done at the end;
##     a reader who scrolled up stays on their line while rows arrive;
##   * THE STATUS LINE after a recording button: both open a NEW session tab
##     natively, and the status line says so — and, for `[Open recording]`,
##     why (§2.2.4);
##   * THE PROMPT'S "ADD CONTEXT" MENU (§2.2.7): `[+]` pressed with SGR bytes
##     opens the desktop's four items; *Editor selection* attaches the shown
##     file at the caret's line, *Files & folders* and *Recording / trace*
##     open the omnibox on `:attach ` / `:attach-recording ` and attach what
##     is chosen there, a path that does not exist is refused on the status
##     line; each attachment is a row with `[×]`, which removes it; the next
##     `/ai` prompt reaches the REAL agent process with the desktop's
##     `Context paths:` header (read back from the agent's own `--prompt-log`)
##     and the attachments are cleared.
##
## No mocks. The agent is the documented ACP test double of the AA suites
## (`agent-activity-deepreview/fixtures/acp-replay-agent.js`, whose header
## justifies it: a production agent cannot hold a known session on demand);
## everything on CodeTracer's side is production code. THE ONE STAND-IN is
## the window's `openRecording` seam — in the shipped terminal
## `app.recordingOpener`, which starts a replay in a new tab (the PTY suite,
## `real_terminal/test_plat54_agent_activity_pty.nim`, drives that half).
## Here it records the request, and the suite checks the folder it names is
## a real recording: it captures, it does not pretend.

import std/[json, os, osproc, strutils, monotimes, times, unittest]

import codetracer_embed

import ../app/runtime
import ../app/tui_app
import ../app/theme/capabilities
import ../app/views/shell
import ../app/views/agent_activity_pane
import ../host/tui_session
import ../host/vcs_source
from ../host/native_host import traceFolderProblem
import ../../viewmodel/host/native_agent_host
import ../../viewmodel/viewmodels/trace_open
import ../../headless_app/session_tabs
import ../../../ct/review_session as ct_review_session
import ./fixtures/fixture_provider

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count.
const ExpectedAssertions = 93

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 160
  Rows = 48
  LiveBudgetMs = 60_000

let root = repoRoot()
let replayAgent = root / "src/tests/gui/tests/agent-activity-deepreview" /
                  "fixtures/acp-replay-agent.js"
let sampleReview = root / "src/tests/gui/tests/deepreview/fixtures" /
                   "sample-review.json"
let scratch = getTempDir() / ("ct-plat54-tui-" & $getCurrentProcessId())
let evidenceDir = scratch / "evidence"

proc caps(): TerminalCapabilities =
  resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"), initCapabilityFlags())

proc sgr(button, row, col: int; pressed: bool): string =
  "\x1b[<" & $button & ";" & $(col + 1) & ";" & $(row + 1) &
    (if pressed: "M" else: "m")

proc send(s: TuiSession; rt: TuiRuntime; token: string) =
  s.applyOutcome(rt, rt.handleToken(token, 0))

proc press(s: TuiSession; rt: TuiRuntime; row, col: int) =
  s.send(rt, sgr(0, row, col, true))
  s.send(rt, sgr(0, row, col, false))

proc screenRows(rt: TuiRuntime): seq[string] = rt.shellScreenOf().rows

proc findOnScreen(rt: TuiRuntime; needle: string): (int, int) =
  for r, line in rt.screenRows():
    let c = line.find(needle)
    if c >= 0:
      return (r, cellWidthOf(line[0 ..< c]))
  (-1, -1)

proc spansText(r: AgentFeedRow): string =
  for sp in r.spans: result.add sp.text

proc lineText(l: AgentFeedLine): string =
  for sp in l.spans: result.add sp.text

proc paneText(rt: TuiRuntime): seq[string] =
  ## Every line of the session as the pane wraps it, on screen or not — the
  ## whole session is what the pane can show.
  for l in rt.agentPaneScreen().screen.lines:
    result.add l.lineText

proc paneFlat(rt: TuiRuntime): string =
  ## The session's text with the wrapping undone: a continuation line's
  ## indent dropped and the lines joined, so a phrase the pane broke at a
  ## space reads whole again.
  let screen = rt.agentPaneScreen().screen
  let rows = markedRows(rt.app.agent.rows)
  for l in screen.lines:
    var t = l.lineText
    if l.part > 0:
      t = t[min(t.len, rows[l.row].indentText.len) .. ^1]
    else:
      result.add "\n"
    result.add t

proc paneHas(rt: TuiRuntime; needle: string): bool =
  needle in rt.paneFlat()

proc pressLine(s: TuiSession; rt: TuiRuntime; line: int; cell: string): bool =
  ## Scroll line `line` of the session into view and press `cell` on it (its
  ## first cell when `cell` is "").
  rt.scrollAgentTo(line)
  let (area, screen) = rt.agentPaneScreen()
  let k = line - screen.top
  if existsEnv("P54_DEBUG"):
    echo "pressLine line=", line, " top=", screen.top, " painted=",
      screen.painted.len, " lines=", screen.lines.len, " rows=",
      screen.listRows, " follow=", rt.app.agent.scroll.follow
  if k < 0 or k >= screen.painted.len:
    return false
  let text = screen.painted[k]
  let at = if cell.len == 0: 0 else: text.find(cell)
  if at < 0:
    return false
  s.press(rt, area.row + k, area.col + cellWidthOf(text[0 ..< at]) + 1)
  true

proc pressButton(s: TuiSession; rt: TuiRuntime; label: string;
                 nth = 0): bool =
  ## Press the `nth` button captioned `label`, where it was painted.
  var n = 0
  for i, l in rt.agentPaneScreen().screen.lines:
    if label in l.lineText:
      if n == nth:
        return s.pressLine(rt, i, label)
      inc n
  false

proc pressRow(s: TuiSession; rt: TuiRuntime; kind: AgentFeedRowKind;
              containing = ""): bool =
  ## Press the first line of the first row of `kind` (holding `containing`).
  let rows = rt.app.agent.rows
  for i, l in rt.agentPaneScreen().screen.lines:
    if l.part == 0 and rows[l.row].kind == kind and
       containing in rows[l.row].spansText:
      return s.pressLine(rt, i, "")
  false

proc showAgentTab(s: TuiSession; rt: TuiRuntime) =
  let (r, c) = rt.findOnScreen("Agent Activity")
  doAssert r >= 0, "no Agent Activity tab:\n" & rt.screenRows().join("\n")
  s.press(rt, r, c + 1)

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

# ---------------------------------------------------------------------------
# The desktop's capture (`plat54-agent-activity-capture.spec.ts`)
# ---------------------------------------------------------------------------

let answersPath = root / "src/tests/visual/answers" /
                  "plat54-agent-activity.electron.json"

proc calcTraceDir(): string

proc portable(text: string): string =
  text.replace(evidenceDir, "<evidence>").replace(calcTraceDir(), "<trace>")

proc orNull(rows: seq[AgentFeedRow]; i: int; kind: AgentFeedRowKind):
    JsonNode =
  if i < rows.len and rows[i].kind == kind: %portable(rows[i].spansText)
  else: newJNull()

proc evidenceCapture(rows: seq[AgentFeedRow]): JsonNode =
  ## The native feed's cards in the capture's shape: state, kind, shape,
  ## dataset, command, note, whether it offers its review, its output.
  result = newJArray()
  for i, r in rows:
    if r.kind != frEvidenceHeader:
      continue
    var shape = newJNull()
    if r.spans.len > 1:
      shape = %r.spans[1].text.strip()
    var j = i + 1
    let dataset = rows.orNull(j, frEvidenceDataset)
    inc j
    let command = rows.orNull(j, frEvidenceCommand)
    inc j
    let note = rows.orNull(j, frEvidenceNote)
    if note.kind != JNull: inc j
    var output: seq[string] = @[]
    while j < rows.len and rows[j].kind == frEvidenceOutput:
      output.add portable(rows[j].spansText)
      inc j
    result.add %*{"state": r.state, "kind": r.spans[0].text, "shape": shape,
                  "dataset": dataset, "command": command, "note": note,
                  "open": r.buttons.len > 0,
                  "output": (if output.len > 0: %output.join("\n")
                             else: newJNull())}

proc open(path: string): (TuiRuntime, TuiSession, VcsSource) =
  let rt = newTuiRuntime(newTuiApp(), caps(), Cols, Rows)
  discard rt.enableLayoutBinding()
  let s = openTuiSession(path, viewportHeight = Rows - 8)
  s.header(rt)
  s.learnExtent()
  s.refresh(rt)
  let vcs = newVcsSource(scratch)
  s.agent.vcs = vcs.vm
  rt.app.agentPress = proc(row, button: int): string =
    result = s.agentPress(rt, row, button)
    vcs.publish(rt)
  rt.app.agentPrompt = proc(text: string): string = s.agentPrompt(rt, text)
  rt.app.agentStop = proc(): string = s.agentStop(rt)
  rt.app.agentAttach = proc(context: string; mustExist: bool): string =
    s.agentAttach(rt, context, mustExist)
  (rt, s, vcs)

proc pressMenuEntry(s: TuiSession; rt: TuiRuntime; label: string): bool =
  ## Press the open menu's entry `label` on the cell it was painted in.
  if not rt.app.contextMenu.open:
    return false
  let area = rt.shellScreenOf().contextMenuArea
  for i, e in rt.app.contextMenu.menu.entries:
    if e.label == label:
      s.press(rt, area.row + 1 + i, area.col + 2)
      return true
  false

proc pressAdd(s: TuiSession; rt: TuiRuntime): bool =
  ## Press the prompt's `[+]` where it was painted.
  let (area, screen) = rt.agentPaneScreen()
  if screen.addCol < 0:
    return false
  s.press(rt, screen.promptRow, screen.addCol + 1)
  discard area
  true

createDir(scratch)
writeDataset(evidenceDir / "iteration-1.json", "Iteration one", 0, 2)
writeDataset(evidenceDir / "iteration-2.json", "Iteration two", 2, 3)
let calc = resolveFixture("calc")
proc calcTraceDir(): string = calc.tracePath

suite "PLAT-54: the terminal's Agent Activity pane":

  test "a recorded session: evidence cards, a click loads each dataset":
    doAssert calc.outcome == foRecorded, calc.detail
    doAssert findExe("node").len > 0, "prerequisite missing: node"
    let (rt, s, vcs) = open(calc.tracePath)
    defer: s.close()
    let sessionFile = resolveSession(@["--evidence",
                                       "--evidence-dir=" & evidenceDir])
    ck sessionFile.len > 0
    discard s.agent.loadReviewSession(sessionFile)
    ck s.agent.vm.messages.val.len > 0
    ck s.agent.vm.sessionNotice.val == ""     # loaded, and not empty
    s.refreshAgent(rt)
    s.showAgentTab(rt)
    let text = rt.paneFlat()
    ck "iteration-1.json" in text
    ck "iteration-2.json" in text
    ck "gone.json" in text
    ck "found no recordings" in text          # the failed call's output
    ck "[Open review]" in text
    ck "2 files" in text                      # the dataset's shape, read
    ck "schemaVersion" notin text
    # THE DESKTOP'S CARDS, captured from Electron over the same transcript:
    # the native feed's are the same cards, word for word.
    let answers = parseJson(readFile(answersPath))
    let native = evidenceCapture(rt.app.agent.rows)
    checkpoint("native: " & $native)
    checkpoint("desktop: " & $answers["evidence"])
    ck native == answers["evidence"]
    # A right press on a card opens what the desktop's opens: nothing.
    let (cr, cc) = rt.findOnScreen("▌ ")
    s.send(rt, sgr(2, cr, cc + 2, true))
    s.send(rt, sgr(2, cr, cc + 2, false))
    ck answers["contextMenu"].len == 0
    ck not rt.app.contextMenu.open
    # One affordance per readable dataset, and none for the other three.
    ck text.count("[Open review]") == 2
    # THE CLICK: the first card's affordance, on the cell it was drawn in.
    ck s.pressButton(rt, "[Open review]", 0)
    ck vcs.vm.deepReviewMode.val
    ck vcs.vm.headerTitle.val == "Iteration one"
    ck vcs.vm.changedFiles.val.len == 2
    ck rt.app.vcs.review
    ck rt.app.vcs.reviewTitle == "Iteration one"
    ck rt.app.vcs.reviewFiles.len == 2
    # The second card REPLACES the review with its own changeset.
    ck s.pressButton(rt, "[Open review]", 1)
    ck vcs.vm.headerTitle.val == "Iteration two"
    ck vcs.vm.changedFiles.val.len == 1
    ck vcs.vm.changedFiles.val[0].path == "src/config.rs"
    ck s.agent.reviewsOpened == 2

  test "a ct test run: a summary, a drill-down, a real recording":
    let (rt, s, _) = open(calc.tracePath)
    defer: s.close()
    var opened: seq[TraceOpenRequest] = @[]
    s.agent.openRecording = proc(r: TraceOpenRequest): string =
      opened.add r
      ""
    let sessionFile = resolveSession(@["--test-run",
                                       "--trace-dir=" & calc.tracePath])
    discard s.agent.loadReviewSession(sessionFile)
    s.refreshAgent(rt)
    s.showAgentTab(rt)
    ck rt.paneHas("ct test record --file tests/calc.c --json-events")
    ck not rt.paneHas("test_add")             # collapsed until pressed
    ck s.pressRow(rt, frTestRun)
    ck rt.paneHas("test_add")
    ck rt.paneHas("test_sub")
    ck s.pressButton(rt, "[Open in new tab]", 0)
    ck opened.len == 1
    ck opened[0].policy == topNewTab
    ck opened[0].tracePath == calc.tracePath
    ck traceFolderProblem(opened[0].tracePath) == ""
    # THE STATUS LINE says where it went (§2.2.4): a new session tab…
    let name = extractFilename(calc.tracePath.strip(leading = false,
                                                    chars = {'/'}))
    checkpoint("status: " & rt.app.notification)
    ck rt.app.notification == "Opened " & name & " in a new session tab"
    # …and `[Open recording]`, the desktop's current-tab open, says why it
    # is a new tab here too.
    ck s.pressButton(rt, "[Open recording]", 0)
    ck opened.len == 2
    ck opened[1].policy == topCurrentTab
    checkpoint("status: " & rt.app.notification)
    ck rt.app.notification == "Opened " & name & " in a new session tab: " &
                              NoCurrentTabReplacementNote
    # THE DESKTOP'S RUN CARD, captured from Electron: title, status, state,
    # and every test's outcome, name, duration and recording affordance.
    let desk = parseJson(readFile(answersPath))["testRun"]
    var run = AgentFeedRow()
    var tests = newJArray()
    for r in rt.app.agent.rows:
      if r.kind == frTestRun: run = r
      if r.kind == frTestRow:
        tests.add %*{"outcome": r.spans[0].text,
                     "name": r.spans[1].text.strip(),
                     "duration": (if r.spans.len > 2: r.spans[2].text.strip()
                                  else: ""),
                     "recording": r.buttons.len > 0}
    ck run.state == desk["state"].getStr
    ck portable(run.spans[1].text) == desk["title"].getStr
    ck portable(run.spans[2].text.strip()) == desk["status"].getStr
    checkpoint("native tests: " & $tests)
    ck tests == desk["tests"]
    # The failed test offers no recording at all.
    var subButtons = -1
    for r in rt.app.agent.rows:
      if r.kind == frTestRow and "test_sub" in r.spansText:
        subButtons = r.buttons.len
    ck subButtons == 0

  test "a live session: rows arrive, the tab agrees, the reader stays put":
    let (rt, s, _) = open(calc.tracePath)
    defer: s.close()
    s.agent.agentCommand = findExe("node")
    s.agent.agentArgs = @[replayAgent, "--evidence",
                          "--evidence-dir=" & evidenceDir,
                          "--live-delay-ms=150"]
    s.refreshAgent(rt)
    s.showAgentTab(rt)
    ck rt.paneHas(AgentIdleHeading)
    # `/ai <prompt>` in the omnibox, as typed.
    rt.openOmnibar("/ai collect the review")
    s.send(rt, "\r")
    if existsEnv("P54_DEBUG"):
      echo "notification: ", rt.app.notification, " omnibar open: ",
        rt.app.omnibar.isOpen
    ck rt.paneHas("collect the review")       # the user's own turn
    ck rt.paneHas("You")
    var counts: seq[int] = @[]
    var agreed = true
    var sawRunning = false
    var held = false
    var heldKey = ""
    let deadline = getMonoTime() + initDuration(milliseconds = LiveBudgetMs)
    while getMonoTime() < deadline:
      if s.pumpAgent(rt):
        counts.add rt.app.agent.rows.len
      let tab = agentOf(s.session.session.store.agentSessions.val)
      if tab.running != rt.app.agent.working:
        agreed = false
      if tab.running:
        sawRunning = true
      # Mid-run, scroll to the top: the line there must stay there.
      if not held and rt.app.agent.rows.len >= 6:
        let (area, _) = rt.agentPaneScreen()
        for _ in 0 ..< 10:   # the wheel, up
          s.send(rt, sgr(64, area.row + 1, area.col + 2, true))
        let (_, screen) = rt.agentPaneScreen()
        if screen.lines.len > screen.listRows:
          heldKey = rt.app.agent.scroll.anchorKey
          held = true
      if sawRunning and not tab.running and tab.present:
        break
      sleep(30)
    if existsEnv("P54_DEBUG"):
      echo "host message: ", s.agent.message, " sessions: ",
        $s.session.session.store.agentSessions.val
    ck sawRunning
    ck agreed
    ck counts.len >= 3                        # arrived over several ticks
    ck counts[^1] > counts[0]
    let tab = agentOf(s.session.session.store.agentSessions.val)
    ck tab.present and not tab.running
    ck tab.lifecycle == aslCompleted
    ck not rt.app.agent.working
    ck rt.findOnScreen("[Send]")[0] >= 0
    ck rt.paneHas("iteration-1.json")
    ck held
    ck not rt.app.agent.scroll.follow
    ck rt.app.agent.scroll.anchorKey == heldKey

  test "the prompt's add-context menu: attachments reach the agent":
    let (rt, s, _) = open(calc.tracePath)
    defer: s.close()
    let promptLog = scratch / "prompts.jsonl"
    removeFile(promptLog)
    s.agent.agentCommand = findExe("node")
    s.agent.agentArgs = @[replayAgent, "--evidence",
                          "--evidence-dir=" & evidenceDir,
                          "--prompt-log=" & promptLog]
    s.agent.cwd = scratch
    s.refreshAgent(rt)
    s.showAgentTab(rt)
    ck rt.findOnScreen(AgentAddContextLabel & " [Send]")[0] >= 0
    # `[+]`: the desktop's four items, in its order.
    ck s.pressAdd(rt)
    ck rt.app.contextMenu.open
    ck rt.app.contextMenu.menu.kind == cmkAgentAddContext
    ck rt.app.contextMenu.menu.labels == @["Upload attachment",
      "Files & folders", "Editor selection", "Recording / trace"]
    # A replay shows a file, so *Editor selection* is live: the shown file
    # at the caret's line.
    let selection = rt.app.contextMenu.menu.target.path
    checkpoint("editor selection: " & selection)
    ck selection.startsWith(rt.app.source.path & ":")
    ck s.pressMenuEntry(rt, "Editor selection")
    ck not rt.app.contextMenu.open
    ck s.agent.vm.contextPaths.val == @[selection]
    ck rt.app.notification == "Attached " & selection &
                              ": it goes with the next prompt"
    # *Files & folders*: the omnibox on `:attach `, a folder typed there.
    ck s.pressAdd(rt)
    ck s.pressMenuEntry(rt, "Files & folders")
    ck rt.app.omnibar.isOpen and rt.app.omnibar.query == AttachQuery
    rt.app.omnibar.setQuery(AttachQuery & evidenceDir)
    s.send(rt, "\r")
    ck not rt.app.omnibar.isOpen
    ck s.agent.vm.contextPaths.val == @[selection, evidenceDir]
    # A path that is not there is refused, and says so.
    rt.openOmnibar(AttachQuery & scratch / "no-such-file")
    s.send(rt, "\r")
    ck "no such file or folder" in rt.app.notification
    ck s.agent.vm.contextPaths.val.len == 2
    # *Recording / trace*: the omnibox on `:attach-recording `.
    ck s.pressAdd(rt)
    ck s.pressMenuEntry(rt, "Recording / trace")
    ck rt.app.omnibar.isOpen and rt.app.omnibar.query == AttachRecordingQuery
    rt.app.omnibar.setQuery(AttachRecordingQuery & calc.tracePath)
    s.send(rt, "\r")
    ck s.agent.vm.contextPaths.val == @[selection, evidenceDir,
                                         calc.tracePath]
    # Each attachment is a row above the prompt; `[×]` removes its own.
    ck rt.paneHas(AgentContextChipLead & evidenceDir)
    # (A long path wraps; its `[×]` moves to the row's next line, whole.)
    var removeAt = -1
    let chipRows = rt.app.agent.rows
    for i, l in rt.agentPaneScreen().screen.lines:
      let row = chipRows[l.row]
      if row.kind == frContextPath and row.buttons.len == 1 and
         row.buttons[0].arg == evidenceDir and "[×]" in l.lineText:
        removeAt = i
    ck removeAt >= 0
    ck s.pressLine(rt, removeAt, "[×]")
    ck s.agent.vm.contextPaths.val == @[selection, calc.tracePath]
    ck not rt.paneHas(AgentContextChipLead & evidenceDir)
    # THE PROMPT: what the REAL agent process received carries the header.
    rt.openOmnibar("/ai summarize the change")
    s.send(rt, "\r")
    ck s.agent.vm.contextPaths.val.len == 0
    let deadline = getMonoTime() + initDuration(milliseconds = LiveBudgetMs)
    while getMonoTime() < deadline and not fileExists(promptLog):
      discard s.pumpAgent(rt)
      sleep(30)
    ck fileExists(promptLog)
    var sent = ""
    if fileExists(promptLog):
      let blocks = parseJson(readFile(promptLog).splitLines()[0])
      for b in blocks:
        sent.add b{"text"}.getStr("")
    checkpoint("the agent received: " & sent)
    ck sent == "Context paths:\n- " & selection & "\n- " & calc.tracePath &
               "\n\nsummarize the change"
    # The user's turn shows what was typed, as the desktop's does; no
    # attachment row is left.
    ck rt.paneHas("summarize the change")
    ck not rt.paneHas("Context paths:")
    var chips = 0
    for r in rt.app.agent.rows:
      if r.kind == frContextPath: inc chips
    ck chips == 0

  test "assertion count":
    echo "CHECKS: " & $countedAssertions
    checkpoint("counted assertions: " & $countedAssertions)
    check countedAssertions == ExpectedAssertions

removeDir(scratch)
