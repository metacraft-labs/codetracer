## The project the full-window layout stories show: one invented repository,
## `noir-space-ship` (the story program, test-programs/noir_space_ship), and
## the Agent Harbor work on it -- initiatives, the sessions behind each, the
## recordings CodeTracer has loaded for them, what each agent says, and the
## tests they ran.
##
## Every layout story (`codetracer_stories.nim`, the `agentic-window`
## surface) tells one moment of this project, so the panels of one window
## agree with each other: the editor, the call trace and Variables replay
## `src/shield.nr` stopped at line 7 in pass 2 of `iterate_asteroids`
## (`storybook_components.nim`, `review_story_data.nim`); the Deep Review is
## of the agent's change that clamps a hit's damage to the shield that is
## left (commit `4f2c9e1b`, "fix(shield): clamp the shield at zero after a
## hit", on `fix/clamp-shield-at-zero`), and the test that exposed it is
## `shield_never_negative`, added on `test/drained-field`. The sessions,
## initiatives, branches, hosts and test runs are invented, in Agent Harbor's
## wire shapes (`FleetSession`, `Initiative`) and `ct test`'s event shapes;
## nothing here is captured from a real fleet.
##
## A session's last activity line follows from its own task and its state:
## no two sessions of a moment say the same thing
## (`src/frontend/tests/agent_harbor_story_data_test.nim` fails if they do).
##
## Plain data: compiles natively (for that test) and to JavaScript (for the
## StoryBook bundle and the IsoNim Editor).

import std/[json, strutils]
import nim_agents/agent_harbor/initiatives
import nim_agents_isonim_viewmodels/agent_harbor/[records, recording_switcher]
import ../viewmodel/store/types
import ../../ct_test/contracts as ct_test_contracts

export recording_switcher

const
  ProjectRepository* = "noir-space-ship"
  LayoutScenarios* = [
    "debug-failing-test", "review-agent-change", "needs-input",
    "harbor-arrangement", "remote-test-runs", "initiatives-popup",
    "control-center", "agent-delivers-review", "session-sidebar",
    "top-bar-one-row", "top-bar-rows", "omnibox-routing", "inbox-next",
    "remote-test-triage"]
    ## Every moment a layout story names (its fixture).

  ShieldInitiative* = "shield-hardening"
  FixturesInitiative* = "asteroid-fixtures"
  RunnersInitiative* = "remote-runners"
  ReleaseInitiative* = "release-0-4"

  ClampSession* = "5c1a3e70-7b2d-4c11-9a0e-3f6d2b8c1a01"
    ## "Clamp the shield at zero after a hit": the change under review.
  DrainedTestSession* = "5c1a3e70-7b2d-4c11-9a0e-3f6d2b8c1a02"
  RegenCapSession* = "5c1a3e70-7b2d-4c11-9a0e-3f6d2b8c1a03"
  OverflowSession* = "5c1a3e70-7b2d-4c11-9a0e-3f6d2b8c1a04"
  StatusReportSession* = "5c1a3e70-7b2d-4c11-9a0e-3f6d2b8c1a05"
  FixtureLoaderSession* = "5c1a3e70-7b2d-4c11-9a0e-3f6d2b8c1a06"
  SeededFieldSession* = "5c1a3e70-7b2d-4c11-9a0e-3f6d2b8c1a07"
  RemoteRunSession* = "5c1a3e70-7b2d-4c11-9a0e-3f6d2b8c1a08"
  UploadSession* = "5c1a3e70-7b2d-4c11-9a0e-3f6d2b8c1a09"
  MacTimeoutSession* = "5c1a3e70-7b2d-4c11-9a0e-3f6d2b8c1a10"
  ChangelogSession* = "5c1a3e70-7b2d-4c11-9a0e-3f6d2b8c1a11"
  WorkspaceAnswerSession* = "5c1a3e70-7b2d-4c11-9a0e-3f6d2b8c1a12"

type
  WorkState = enum
    ## The states a project session is drawn in (Agent Harbor's status plus
    ## the wait it is in).
    wsRunning, wsQuestion, wsIdle, wsQueued, wsFailed, wsCompleted

  ProjectWork = object
    ## One session of the project, as a moment shows it.
    id, title, planId, agent, version, origin, host, branch: string
    state: WorkState
    tool: string        ## the command or edit it last ran ("" for none)
    last: string        ## what it last said
    startedMinutesAgo, activeMinutesAgo: int

func work(id, title, planId, agent, version, origin, host, branch: string;
          state: WorkState; tool, last: string;
          started, active: int): ProjectWork =
  ProjectWork(id: id, title: title, planId: planId, agent: agent,
              version: version, origin: origin, host: host, branch: branch,
              state: state, tool: tool, last: last,
              startedMinutesAgo: started, activeMinutesAgo: active)

proc projectWork(moment: string): seq[ProjectWork] =
  ## The project's sessions at `moment`. The clamp session and the test that
  ## exposed the bug change state with the story; the rest of the project
  ## carries on around them.
  if moment notin LayoutScenarios:
    raise newException(ValueError, "no layout story moment named " & moment)
  let reviewed = moment in ["review-agent-change", "agent-delivers-review",
                            "control-center", "inbox-next", "harbor-arrangement"]
  let clamp =
    if reviewed:
      work(ClampSession, "Clamp the shield at zero after a hit", ShieldInitiative,
           "Claude", "2.1.0", "codetracer", "ws-ada", "fix/clamp-shield-at-zero",
           wsCompleted, "Ran nargo test",
           "The clamp is in calculate_damage; nargo test passes 6 of 6 with the " &
             "recording attached for review.", 52, 4)
    else:
      work(ClampSession, "Clamp the shield at zero after a hit", ShieldInitiative,
           "Claude", "2.1.0", "codetracer", "ws-ada", "fix/clamp-shield-at-zero",
           wsRunning, "Ran nargo test shield_never_negative",
           "Clamped the damage to remaining_shield at src/shield.nr:34; re-running " &
             "shield_never_negative.", 38, 1)
  let drained =
    if moment == "needs-input":
      work(DrainedTestSession, "Add a test for an asteroid field that drains the shield",
           ShieldInitiative, "Codex", "0.9.4", "codetracer", "ws-ada",
           "test/drained-field", wsQuestion, "Ran nargo test drained_field_fails",
           "Should drained_field_fails expect the shield at exactly 0 after pass 5, " &
             "or anything below 1?", 61, 2)
    else:
      work(DrainedTestSession, "Add a test for an asteroid field that drains the shield",
           ShieldInitiative, "Codex", "0.9.4", "codetracer", "ws-ada",
           "test/drained-field", wsCompleted, "Ran nargo test drained_field_fails",
           "drained_field_fails is in src/tests.nr and fails before the clamp, " &
             "as it should.", 61, 17)
  let macTimeout =
    if moment == "inbox-next":
      # The inbox moved here: the operator answered the drained-field
      # question, and this is the next session waiting.
      work(MacTimeoutSession, "Fix the negative-field test that times out on macOS",
           RunnersInitiative, "Grok", "1.2.0", "codetracer", "mac-arm64-2",
           "fix/macos-test-timeout", wsQuestion, "Ran nargo test negative_field_fails",
           "negative_field_fails takes 41 s on macos-arm64 against 6 s on Linux; " &
             "raise its timeout, or split the field into two tests?", 33, 3)
    else:
      work(MacTimeoutSession, "Fix the negative-field test that times out on macOS",
           RunnersInitiative, "Grok", "1.2.0", "codetracer", "mac-arm64-2",
           "fix/macos-test-timeout", wsQuestion, "Ran nargo test negative_field_fails",
           "negative_field_fails takes 41 s on macos-arm64 against 6 s on Linux; " &
             "raise its timeout, or split the field into two tests?", 33, 9)
  @[
    clamp,
    drained,
    work(RegenCapSession, "Cap shield regeneration at the initial shield",
         ShieldInitiative, "Claude", "2.1.0", "webui", "linux-x64-4", "fix/regen-cap",
         wsRunning, "Ran nargo test regeneration_never_exceeds_capacity",
         "Checking that calculate_shield_regeneration stops at 10000 when a pass " &
           "starts at 9500.", 27, 1),
    work(OverflowSession, "Make calculate_damage safe for masses above u32",
         ShieldInitiative, "Grok", "1.2.0", "cli", "linux-x64-4", "fix/damage-overflow",
         wsQuestion, "Ran nargo test heavy_asteroid_does_not_wrap",
         "Cast the masses to u64 before multiplying, or keep Field arithmetic and " &
           "range-check the product?", 74, 12),
    work(StatusReportSession, "Print the shield percentage after every hit",
         ShieldInitiative, "Opencode", "0.6.1", "codetracer", "ws-ada",
         "feat/status-percentage", wsCompleted, "Ran nargo execute",
         "status_report prints \"Shield status 90% 9000\" after every hit; both " &
           "fields' output checked.", 125, 48),
    work(FixtureLoaderSession, "Load the asteroid fields from fixtures/*.toml",
         FixturesInitiative, "Claude", "2.1.0", "codetracer", "ws-ada",
         "feat/fixture-loader", wsRunning, "Edited src/fields.nr",
         "Reading fixtures/positive.toml and fixtures/negative.toml into the " &
           "[Field; 8] masses.", 19, 1),
    work(SeededFieldSession, "Generate the negative asteroid field from a seed",
         FixturesInitiative, "Codex", "0.9.4", "tui", "linux-x64-4", "feat/seeded-field",
         wsQueued, "",
         "Queued until the fixture loader lands; it will start from " &
           "fixtures/negative.toml.", 6, 6),
    work(RemoteRunSession, "Run nargo test on the arm64 and macOS runners",
         RunnersInitiative, "Claude", "2.1.0", "codetracer", "ws-ada",
         "ci/remote-test-runs", wsRunning,
         "Started nargo test on linux-arm64 and macos-arm64",
         "4 of 6 tests passed on linux-arm64; macos-arm64 is still compiling the " &
           "circuit.", 14, 0),
    work(UploadSession, "Upload the test recordings from the remote runners",
         RunnersInitiative, "Codex", "0.9.4", "cli", "mac-arm64-2",
         "ci/upload-recordings", wsFailed, "Ran ct upload --from macos-arm64",
         "The upload from macos-arm64 failed: the runner has no write token for " &
           "the recording store.", 44, 21),
    macTimeout,
    work(ChangelogSession, "Write the 0.4 changelog", ReleaseInitiative,
         "Opencode", "0.6.1", "webui", "linux-x64-4", "release/0.4", wsIdle,
         "Edited CHANGELOG.md",
         "The 0.4 changelog lists the clamp, the regeneration cap and the fixture " &
           "loader; over to you for the wording.", 90, 31),
    work(WorkspaceAnswerSession, "Answer the question about Nargo workspaces", "",
         "Claude", "2.1.0", "telegram", "linux-x64-4", "", wsCompleted,
         "Read the Nargo.toml reference",
         "Answered: a workspace lists its crates under [workspace] members, and " &
           "nargo test runs every one of them.", 210, 160),
  ]

proc fleetSessionOf(w: ProjectWork; nowMs: int64): FleetSession =
  let minute = 60_000'i64
  let status = case w.state
    of wsQueued: fsQueued
    of wsFailed: fsFailed
    of wsCompleted: fsCompleted
    else: fsRunning
  let started = nowMs - int64(w.startedMinutesAgo) * minute
  let updated = nowMs - int64(w.activeMinutesAgo) * minute
  result = FleetSession(
    id: w.id, prompt: w.title, agentSoftware: w.agent, agentVersion: w.version,
    agentCount: 1, host: w.host, rawStatus: $status, status: status,
    createdAtMs: started, startedAtMs: started, updatedAtMs: updated,
    endedAtMs: (if status.isActive: 0'i64 else: updated),
    awaitingInput: w.state in {wsQuestion, wsIdle},
    awaitingInputSource:
      if w.state == wsQuestion: w.id & ":native-question:1"
      elif w.state == wsIdle: "claude-stop-hook"
      else: "",
    originFrontEnd: w.origin, branch: w.branch, workspaceName: ProjectRepository,
    labelSource: "invented", planId: w.planId)
  if w.state == wsFailed: result.failureReason = "[exit] status=1"
  if w.tool.len > 0:
    result.recent.add FleetActivity(kind: fakToolUse, text: w.tool,
                                    timestampMs: updated - minute)
  result.recent.add FleetActivity(kind: fakLog,
                                  level: (if w.state == wsFailed: "error" else: "info"),
                                  text: "assistant: " & w.last, timestampMs: updated)

proc milestone(id, title, status: string; done, total, passing, failing: int):
    MilestoneDetail =
  MilestoneDetail(id: id, title: title, status: status,
                  deliverables: DeliverableCounts(done: done, total: total),
                  verifications: VerificationCounts(
                    passing: passing, failing: failing,
                    pending: max(0, total - passing - failing)))

proc initiative(id, title, summary, current, manager: string;
                milestones: seq[MilestoneDetail]): Initiative =
  var progress = MilestoneFileProgress(
    path: "milestones/" & id & ".milestones.org", title: title & " Milestones",
    status: "in_progress", lastUpdated: "2026-11-05", currentMilestone: current,
    milestones: milestones)
  progress.summarize()
  Initiative(id: id, title: title, repository: ProjectRepository,
             planPath: progress.path, manager: manager, executiveSummary: summary,
             progress: progress)

proc projectInitiatives(): seq[Initiative] =
  @[
    initiative(ShieldInitiative, "Shield model hardening",
      "A hit can no longer take the shield below zero, regeneration never " &
        "exceeds the shield's capacity, and heavy asteroids cannot overflow the " &
        "damage calculation. The specification and the per-hit status report " &
        "are done; the clamp and the regeneration cap are in progress, and the " &
        "overflow fix waits on a decision about Field arithmetic.",
      "SH-M1", "sh-manager", @[
        milestone("SH-M0", "Specification", "completed", 3, 3, 2, 0),
        milestone("SH-M1", "Clamp at zero", "in_progress", 2, 3, 1, 0),
        milestone("SH-M2", "Regeneration cap", "in_progress", 1, 3, 0, 0),
        milestone("SH-M3", "Damage overflow", "blocked", 0, 2, 0, 1),
        milestone("SH-M4", "Per-hit status report", "completed", 2, 2, 2, 0)]),
    initiative(FixturesInitiative, "Asteroid fields as fixtures",
      "The asteroid fields move out of Prover.toml into fixture files the tests " &
        "load, so a new field needs no code change. The fixture format is " &
        "settled; the loader is being written, and seeded random fields follow it.",
      "AF-M2", "", @[
        milestone("AF-M0", "Specification", "completed", 2, 2, 1, 0),
        milestone("AF-M1", "Fixture format", "completed", 3, 3, 2, 0),
        milestone("AF-M2", "Fixture loader", "in_progress", 1, 3, 0, 0),
        milestone("AF-M3", "Seeded fields", "planned", 0, 2, 0, 0)]),
    initiative(RunnersInitiative, "Tests on the arm64 and macOS runners",
      "nargo test runs on the linux-arm64 and macos-arm64 runners as well as " &
        "locally, and every remote run uploads a recording CodeTracer can open. " &
        "The runner images are ready and the first remote runs are going; the " &
        "upload is blocked on a write token, and macOS needs its own timeouts.",
      "RR-M1", "rr-manager", @[
        milestone("RR-M0", "Runner images", "completed", 2, 2, 2, 0),
        milestone("RR-M1", "Remote test runs", "in_progress", 1, 3, 1, 0),
        milestone("RR-M2", "Recording upload", "blocked", 0, 2, 0, 1),
        milestone("RR-M3", "Timeouts per platform", "planned", 0, 2, 0, 0)]),
    initiative(ReleaseInitiative, "Release 0.4",
      "The 0.4 release ships the shield clamp, the regeneration cap and the " &
        "fixture loader. The changelog is drafted and waits for review; the " &
        "version bump and the tag follow once the shield work lands.",
      "R4-M0", "", @[
        milestone("R4-M0", "Changelog", "in_progress", 1, 2, 0, 0),
        milestone("R4-M1", "Version bump", "planned", 0, 1, 0, 0),
        milestone("R4-M2", "Tag and publish", "planned", 0, 2, 0, 0)]),
  ]

proc projectWorkingSet*(moment: string; nowMs: int64): tuple[
    snapshot: FleetSnapshot, initiatives: seq[Initiative]] =
  ## The project's sessions and initiatives at `moment` (one of
  ## `LayoutScenarios`); raises on an unknown one.
  result.snapshot = FleetSnapshot(capturedAtMs: nowMs,
                                  sourceLabel: "invented project: " & ProjectRepository)
  result.initiatives = projectInitiatives()
  for w in projectWork(moment):
    var session = fleetSessionOf(w, nowMs)
    for plan in result.initiatives.mitems:
      if plan.id == w.planId:
        session.initiative = plan.title
        plan.sessionIds.add session.id
    result.snapshot.sessions.add session
  result.snapshot.total = result.snapshot.sessions.len

# ---------------------------------------------------------------------------
# Recordings CodeTracer has loaded for an initiative
# ---------------------------------------------------------------------------

proc projectRecordings*(initiativeId, moment: string): seq[RecordingEntry] =
  ## The replays loaded for an initiative's tab: the test traces and program
  ## runs its sessions produced. The shield initiative's first is the one
  ## the editor, the call trace and Variables show.
  case initiativeId
  of ShieldInitiative:
    @[
      RecordingEntry(id: "rec-shield-never-negative", name: "shield_never_negative",
                     revision: "9b81d02", origin: "nargo test, session Add a test for " &
                       "an asteroid field that drains the shield", state: rsReady),
      RecordingEntry(id: "rec-nargo-execute", name: "nargo execute, both asteroid fields",
                     revision: "4f2c9e1", origin: "ct record", state: rsReady),
      RecordingEntry(id: "rec-drained-field", name: "drained_field_fails",
                     revision: "9b81d02", origin: "nargo test", state: rsReady),
    ]
  of RunnersInitiative:
    @[
      RecordingEntry(id: "rec-negative-macos", name: "negative_field_fails on macos-arm64",
                     revision: "4f2c9e1", origin: "remote run on mac-arm64-2",
                     state: rsReady),
      RecordingEntry(id: "rec-shield-arm64", name: "shield_never_negative on linux-arm64",
                     revision: "4f2c9e1", origin: "remote run on linux-arm64-1",
                     state: rsReady),
      RecordingEntry(id: "rec-drained-macos", name: "drained_field_fails on macos-arm64",
                     revision: "4f2c9e1", origin: "remote run on mac-arm64-2",
                     state: (if moment == "remote-test-runs": rsLoading else: rsReady)),
    ]
  else: @[]

# ---------------------------------------------------------------------------
# The tests: catalog and runner events, as `ct test` reports them
# ---------------------------------------------------------------------------

type
  ProjectTest = object
    name, file: string
    line: int

const
  NoirProvider = "noir-nargo"
  ProjectTests = [
    ProjectTest(name: "shield_never_negative", file: "src/tests.nr", line: 4),
    ProjectTest(name: "drained_field_fails", file: "src/tests.nr", line: 15),
    ProjectTest(name: "regeneration_never_exceeds_capacity", file: "src/tests.nr", line: 27),
    ProjectTest(name: "positive_field_survives", file: "src/tests.nr", line: 38),
    ProjectTest(name: "negative_field_fails", file: "src/tests.nr", line: 46),
    ProjectTest(name: "status_report_prints_percentage", file: "src/tests.nr", line: 55),
  ]

proc testIdOf(t: ProjectTest): string =
  NoirProvider & "/noir/nargo/" & t.file & "::" & t.name

proc projectTestCatalog*(): TestCatalog =
  ## The crate's tests, as discovery lists them.
  result = TestCatalog(schemaVersion: 1,
                       provider: TestProviderInfo(id: NoirProvider))
  for t in ProjectTests:
    result.items.add TestItem(id: t.testIdOf, providerId: NoirProvider,
      language: "noir", framework: "nargo", name: t.name, kind: tikCase,
      file: t.file, range: SourceRange(startLine: t.line, endLine: t.line),
      selector: t.name)

proc testEvent(kind, runId: string; t: ProjectTest; status = ""; message = "";
               output = ""; durationMs = 0; recordingId = ""): TestEvent =
  var node = %*{"schemaVersion": 1, "kind": kind, "providerId": NoirProvider,
                "runId": runId, "testId": t.testIdOf, "status": newJNull(),
                "message": message, "output": output, "durationMs": durationMs,
                "trace": newJNull(), "diagnostic": newJNull()}
  if status.len > 0: node["status"] = %status
  if recordingId.len > 0:
    node["trace"] = %*{"traceId": recordingId, "recordingId": recordingId,
                       "path": "recordings/" & recordingId, "backend": "noir",
                       "entryPoint": t.name, "metadata": {"recordedAt": "2026-11-05 14:12"}}
  eventFromJsonLine($node)

proc runEvent(kind, runId: string): TestEvent =
  eventFromJsonLine($ %*{"schemaVersion": 1, "kind": kind, "providerId": NoirProvider,
    "runId": runId, "testId": "", "status": newJNull(), "message": "", "output": "",
    "durationMs": 0, "trace": newJNull(), "diagnostic": newJNull()})

proc projectTestEvents*(moment: string): tuple[events: seq[TestEvent], finished: bool] =
  ## The run a moment's Test Results pane shows: after the clamp, every test
  ## passes with its recording; on the remote runners, a run still streaming
  ## (`finished` false) or one whose macOS test failed.
  let runId = "noir-space-ship-" & moment
  result.events.add runEvent("run-started", runId)
  case moment
  of "remote-test-runs", "remote-test-triage":
    let streaming = moment == "remote-test-runs"
    for i, t in ProjectTests:
      result.events.add testEvent("test-started", runId, t)
      if streaming and i >= 4: continue   # still running on macos-arm64
      if t.name == "negative_field_fails" and not streaming:
        # The runner prints why it failed as the test's output (the row's
        # message).
        result.events.add testEvent("failure", runId, t,
          message = "timed out after 30 s",
          output = "negative_field_fails timed out after 30 s on macos-arm64 " &
            "(6.1 s on linux-arm64): compiling the circuit took 27 s")
        result.events.add testEvent("test-finished", runId, t, status = "failed",
          durationMs = 30_000)
        result.events.add testEvent("recording-created", runId, t,
          recordingId = "rec-negative-macos")
        continue
      result.events.add testEvent("test-finished", runId, t, status = "passed",
        durationMs = 380 + i * 170)
      result.events.add testEvent("recording-created", runId, t,
        recordingId = "rec-remote-" & t.name)
    result.finished = not streaming
  else:
    for i, t in ProjectTests:
      result.events.add testEvent("test-started", runId, t)
      result.events.add testEvent("test-finished", runId, t, status = "passed",
        durationMs = 120 + i * 45)
      result.events.add testEvent("recording-created", runId, t,
        recordingId = "rec-" & t.name.replace('_', '-'))
    result.finished = true
  if result.finished: result.events.add runEvent("run-finished", runId)

# ---------------------------------------------------------------------------
# What the agent in view says
# ---------------------------------------------------------------------------

proc projectTestRunText*(moment: string): string =
  ## The runner's NDJSON the agent's `nargo test` call printed: the Agent
  ## Activity pane draws a message carrying it as a test-run card.
  for e in projectTestEvents(moment).events: result.add $(ct_test_contracts.toJson(e)) & "\n"

proc agentTurn(id, text: string; tools: openArray[(string, string)];
               finalText: string; createdAtMs: float; durationSec: float;
               working = false): AgentActivityMessageEntry =
  # No clock times: a story renders the same on every run and in every time
  # zone. A turn still at work has thought for 4 s; a finished one says how
  # long it took.
  result = AgentActivityMessageEntry(id: id, role: aamrAgent, createdAt: createdAtMs,
                                     duration: durationSec, isLoading: working,
                                     thinkingEndedAt: (if working: createdAtMs + 4000.0 else: 0.0))
  if text.len > 0:
    result.segments.add AgentActivitySegment(content: text)
  for i, (tool, status) in tools:
    let callId = id & "-tool-" & $i
    result.segments.add AgentActivitySegment(isToolCall: true, toolCallId: callId,
                                             toolName: tool, toolStatus: status)
    result.toolCalls.add AgentActivityToolCallEntry(toolCallId: callId, name: tool,
                                                    status: status)
  if finalText.len > 0:
    result.segments.add AgentActivitySegment(content: finalText)
  result.content = text & (if finalText.len > 0: "\n\n" & finalText else: "")

proc userTurn(id, text: string; createdAtMs: float): AgentActivityMessageEntry =
  AgentActivityMessageEntry(id: id, role: aamrUser, content: text, createdAt: createdAtMs)

type
  AgentConversation* = object
    ## What the Agent Activity pane of a moment shows: the session in view,
    ## its branch and model, the conversation, and a pending request.
    sessionId*: string
    branch*: string
    model*: string
    messages*: seq[AgentActivityMessageEntry]

const
  ClampOriginal = "    damage"
  ClampModified = "    if(damage as u32 > remaining_shield as u32){\n" &
    "        damage = remaining_shield;\n        }\n    damage as Field"

proc projectConversation*(moment: string): AgentConversation =
  ## The conversation of the session a moment has in view.
  case moment
  of "needs-input":
    AgentConversation(sessionId: DrainedTestSession, branch: "test/drained-field",
      model: "Codex GPT5", messages: @[
        userTurn("u1", "Add a test with an asteroid field heavy enough to drain the " &
          "shield, so the clamp has something to fail on.", 0.0),
        agentTurn("a1", "Wrote `drained_field_fails` with masses [2000, 3000, 6000, " &
          "1600, 1290, 1110, 1, 1]; the shield reaches 0 at pass 5.",
          [("Edited src/tests.nr", "completed"),
           ("nargo test drained_field_fails", "completed"),
           ("ct record-test drained_field_fails", "completed")],
          "The test fails as expected before the clamp. Should it expect the " &
            "shield at exactly 0 after pass 5, or anything below 1? I can open " &
            "its recording in a new tab at pass 5 so you can look first.",
          0.0, 94.0)])
  of "inbox-next":
    AgentConversation(sessionId: MacTimeoutSession, branch: "fix/macos-test-timeout",
      model: "Grok 4", messages: @[
        userTurn("u1", "negative_field_fails times out on the macOS runner only. " &
          "Find out why and fix it.", 0.0),
        agentTurn("a1", "Ran it on both runners: 6.1 s on linux-arm64, 41 s on " &
          "macos-arm64. The recording shows the time goes into compiling the " &
          "circuit, not into the eight passes.",
          [("nargo test negative_field_fails --runner linux-arm64", "completed"),
           ("nargo test negative_field_fails --runner macos-arm64", "completed")],
          "Raise its timeout to 60 s on macOS, or split the field into two " &
            "tests of four asteroids each?", 0.0, 212.0)])
  of "remote-test-runs", "remote-test-triage":
    let triage = moment == "remote-test-triage"
    var messages = @[
      userTurn("u1", "Run the whole crate's tests on linux-arm64 and macos-arm64 " &
        "and record each test, so I can open any of them here.", 0.0),
      agentTurn("a1", "Started `nargo test` on both runners with recording on; " &
        "each finished test uploads its trace.",
        [("Started nargo test on linux-arm64", "completed"),
         ("Started nargo test on macos-arm64", (if triage: "completed" else: "in_progress"))],
        (if triage: "5 of 6 passed. negative_field_fails timed out after 30 s on " &
           "macos-arm64; its recording is loaded in the Runners tab."
         else: "4 of 6 passed on linux-arm64 so far; macos-arm64 is still " &
           "compiling the circuit."),
        0.0, (if triage: 742.0 else: 0.0), working = not triage)]
    if triage:
      var run = AgentActivityMessageEntry(id: "a2-run", role: aamrAgent,
        content: projectTestRunText(moment), createdAt: 0.0, toolName: "nargo test")
      messages.add run
    AgentConversation(sessionId: RemoteRunSession, branch: "ci/remote-test-runs",
      model: "Claude Opus", messages: messages)
  of "review-agent-change", "agent-delivers-review", "control-center",
     "harbor-arrangement":
    var result = AgentConversation(sessionId: ClampSession,
      branch: "fix/clamp-shield-at-zero", model: "Claude Opus", messages: @[
        userTurn("u1", "shield_never_negative fails on the negative field. Find where " &
          "the shield goes below zero and fix it; I'm stepping through the " &
          "recording too.", 0.0),
        agentTurn("a1", "In the recording, pass 2 of `iterate_asteroids` hits for " &
          "2000 with 9000 left, and nothing stops a later hit from taking more " &
          "than is left: `calculate_damage` returns the raw damage.",
          [("nargo test shield_never_negative", "completed"),
           ("ct record-test shield_never_negative", "completed"),
           ("Edited src/shield.nr", "completed"),
           ("nargo test", "completed")],
          "Clamped the damage to `remaining_shield` in `calculate_damage`. " &
            "nargo test passes 6 of 6; the change and the recording are ready " &
            "for review in Deep Review.", 0.0, 1324.0)])
    result.messages[^1].diffs = @[AgentActivityDiffEntry(id: 1, path: "src/shield.nr",
      original: ClampOriginal, modified: ClampModified)]
    result.messages.add AgentActivityMessageEntry(id: "a2-run", role: aamrAgent,
      content: projectTestRunText(moment), createdAt: 0.0, toolName: "nargo test")
    result
  else:
    # The clamp session at work while the operator debugs the failing test.
    AgentConversation(sessionId: ClampSession, branch: "fix/clamp-shield-at-zero",
      model: "Claude Opus", messages: @[
        userTurn("u1", "shield_never_negative fails on the negative field. Find where " &
          "the shield goes below zero and fix it; I'm stepping through the " &
          "recording too.", 0.0),
        agentTurn("a1", "Reproduced it and recorded the test.",
          [("nargo test shield_never_negative", "completed"),
           ("ct record-test shield_never_negative", "completed"),
           ("Read src/shield.nr", "completed")],
          "Pass 2 of `iterate_asteroids` hits for 2000 with 9000 left, and " &
            "`calculate_damage` returns the raw damage, so a later hit can take " &
            "more than is left. Clamped it to `remaining_shield` at " &
            "src/shield.nr:34; re-running `shield_never_negative`.",
          0.0, 0.0, working = true)])

# ---------------------------------------------------------------------------
# The build pane: the failing run the operator started
# ---------------------------------------------------------------------------

type
  BuildLine* = object
    raw*: string          ## as the tool wrote it, ANSI included
    isStdout*: bool
    error*, warning*: bool
    path*: string
    line*: int

proc projectFailingTestRun*(): seq[BuildLine] =
  ## `nargo test` before the clamp: shield_never_negative fails on the
  ## negative field.
  @[
    BuildLine(raw: "$ nargo test --package noir_space_ship", isStdout: true),
    BuildLine(raw: "[noir_space_ship] Running 6 test functions", isStdout: true),
    BuildLine(raw: "[noir_space_ship] Testing positive_field_survives... \e[32mok\e[0m", isStdout: true),
    BuildLine(raw: "[noir_space_ship] Testing negative_field_fails... \e[32mok\e[0m", isStdout: true),
    BuildLine(raw: "[noir_space_ship] Testing shield_never_negative... \e[31mFAIL\e[0m", isStdout: true),
    BuildLine(raw: "\e[91merror:\e[0m Failed assertion: \"the shield never goes below zero\"",
              error: true, path: "src/tests.nr", line: 9),
    BuildLine(raw: "   \xE2\x94\x8C\xE2\x94\x80 src/tests.nr:9:5", error: true,
              path: "src/tests.nr", line: 9),
    BuildLine(raw: "   \xE2\x94\x82  assert(remaining as u32 <= 10000, \"the shield never goes below zero\");",
              error: true),
    BuildLine(raw: "[noir_space_ship] Testing drained_field_fails... \e[32mok\e[0m", isStdout: true),
    BuildLine(raw: "[noir_space_ship] Testing regeneration_never_exceeds_capacity... \e[32mok\e[0m", isStdout: true),
    BuildLine(raw: "[noir_space_ship] Testing status_report_prints_percentage... \e[32mok\e[0m", isStdout: true),
    BuildLine(raw: "[noir_space_ship] 5 tests passed, 1 test failed", isStdout: true),
  ]
