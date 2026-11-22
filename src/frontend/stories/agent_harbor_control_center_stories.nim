## The control center stories' viewmodel constructors.
##
## A story of the `agent-harbor-control-center` surface (declared in
## `codetracer_stories.nim`) is a `ControlCenterVM` built by
## `createControlCenterStoryVM` for the story's fixture, and the production
## view of each host over it (the web's
## `isonim_agent_harbor_control_center_view`, GPUI's `ah_control_center`,
## the terminal's `ah_tui_control_center`).
##
## Every populated story is the CTF-P2L project at its `control-center`
## moment (`layout_story_data.nim`, the invented `noir-space-ship`
## repository; P2c study D26): the four initiatives and their sessions, two
## sessions on a question and one ended turn waiting for the operator. Its
## source is a `TimelineDataSource` (a snapshot source whose fleet-frame
## stream sends what the story sends), so a launched session joins its
## initiative with the frame that introduces it, as it would from a server.
##
## No routing agent exists, and the prototypes never write to a server: the
## composer's router is a `ScriptedRouter` whose decisions do not matter
## here (the operator chose what is launched), and every launch is answered
## by a `ScriptedActionSource` with where the session started. Every state
## is reached by driving the viewmodel as the operator would (choosing,
## typing, launching), never by setting its fields.

import nim_agents_isonim_viewmodels/agent_harbor/[control_center_vm, instruction_router,
  scripted_actions, data_source]
import ./layout_story_data
import ./agent_harbor_stories

export control_center_vm

const
  controlCenterFixtures* = ["populated", "empty", "launching", "loading", "error"]
    ## Every fixture an `agent-harbor-control-center` story may name besides
    ## its playback (`playback-front-ends`).
  ControlCenterSurfaceName* = "agent-harbor-control-center"
  ControlCenterMoment* = "control-center"
  ControlCenterNowMs* = 1_763_000_000_000'i64
    ## The project's clock: every session's age is measured from it.
  ControlCenterPlanDate* = "2026-11-17"
  Dot = " \xC2\xB7 "
  RegenConfigTask* = "Make the regeneration cap configurable per ship"
  SeededFieldsInitiative* = "Asteroid fields generated from seeds, end to end"
  EmptyShieldTask* = "Add a test for a hit on an empty shield"
  LaunchedSession* = "5c1a3e70-7b2d-4c11-9a0e-3f6d2b8c1a13"
    ## The session the launching story's launch starts.

proc noticeFor(session, executor: string): string =
  "Started on hub-a" & Dot & "executor " & executor & Dot & "session " & session

proc projectSource*(): TimelineDataSource =
  ## The project at the control-center moment, with a frame stream the story
  ## sends through.
  let (snapshot, initiatives) = projectWorkingSet(ControlCenterMoment, ControlCenterNowMs)
  result = newTimelineDataSource(@[], label = "invented project " & ProjectRepository)
  result.snapshot = snapshot
  result.initiatives = initiatives

proc storyRouter(): ScriptedRouter =
  result = newScriptedRouter("scripted router (the operator chose the launch)")
  result.decideByDefault(RoutingDecision(target: tkManager,
    reason: "It asks for new work"))

proc launchOptions(branch: string): LaunchOptions =
  LaunchOptions(repository: ProjectRepository, branch: branch, agents: @["Claude"],
                runOn: roServerChoice, openIn: oiNewTab, focus: true)

proc windowDefaults(): LaunchOptions =
  ## A launch's options before the operator changes any: the window's
  ## repository, its usual agent, the server's choice of host.
  LaunchOptions(repository: ProjectRepository, agents: @["Claude"],
                runOn: roServerChoice, openIn: oiNewTab, focus: true)

proc newStoryControlCenter(source: AgentHarborDataSource;
                           actions: ScriptedActionSource): ControlCenterVM =
  ## The control center of a window that has the project open: its launch
  ## form starts on the window's repository and its usual agent, as
  ## CodeTracer fills them from the workspace it shows.
  result = newControlCenterVM(source, storyRouter(), actions, ControlCenterPlanDate)
  result.composer.agentChoices = @["Claude", "Codex", "Grok", "Opencode", "Antigravity"]
  result.composer.executorChoices = @["linux-x64-4", "mac-arm64-2", "ws-ada"]
  result.composer.updateLaunch(windowDefaults())
  result.load()

proc launchHistory(vm: ControlCenterVM; actions: ScriptedActionSource) =
  ## Two earlier launches from this tab -- a task for Shield model hardening
  ## and a new initiative -- so `Recent launches` lists them as Agent Harbor
  ## answered; then the form is empty again, on `New task`.
  vm.chooseInitiative(ShieldInitiative)
  actions.script.setRule(oaLaunchTask, confirmedWith(noticeFor("8c1a14", "linux-x64-4")))
  vm.composer.setText(RegenConfigTask)
  vm.composer.updateLaunch(launchOptions("feat/regen-cap-config"))
  vm.composer.submit()
  vm.chooseInitiative("")
  vm.newInitiative()
  actions.script.setRule(oaStartInitiative, confirmedWith("Plan started on hub-a" & Dot &
    "milestones/seeded-fields.milestones.org"))
  vm.composer.setText(SeededFieldsInitiative)
  vm.composer.updateInitiative(NewInitiativeForm(goal: SeededFieldsInitiative,
    iteration: imAuto, relatedSpecs: @["spec/Fixtures.md"]))
  vm.composer.submit()
  vm.newTask()
  vm.composer.updateLaunch(windowDefaults())

proc launchedSession(): FleetSession =
  ## The session the launch started, as the server's next frame lists it:
  ## queued, in Shield model hardening.
  FleetSession(id: LaunchedSession, prompt: EmptyShieldTask, name: EmptyShieldTask,
    agentSoftware: "Claude", agentVersion: "2.1.0", agentCount: 1, host: "linux-x64-4",
    rawStatus: "queued", status: fsQueued, createdAtMs: ControlCenterNowMs,
    updatedAtMs: ControlCenterNowMs, originFrontEnd: "codetracer",
    branch: "test/empty-shield", workspaceName: ProjectRepository,
    labelSource: "invented", planId: ShieldInitiative,
    initiative: "Shield model hardening")

proc createControlCenterStoryVM*(fixture: string; playback: AhPlayback = nil): ControlCenterVM =
  ## The control center at the moment the fixture names. Call inside a
  ## reactive root; the caller disposes it. An unknown fixture raises rather
  ## than showing some other state under its name. The playback fixture
  ## reads `playback`'s source (the `front-ends` scenario).
  let actions = newScriptedActionSource("scripted actions (invented answers)")
  if isPlaybackStory(ControlCenterSurfaceName, fixture):
    if playback.isNil or playback.surface != ControlCenterSurfaceName or
        playback.fixture != fixture:
      raise newException(ValueError, "the playback story " & ControlCenterSurfaceName &
                         "/" & fixture & " needs its own playback")
    return newStoryControlCenter(playback.source, actions)
  if fixture notin controlCenterFixtures:
    raise newException(ValueError, "no control center story fixture named " & fixture)
  case fixture
  of "loading":
    result = newStoryControlCenter(newPendingDataSource("waiting for the Agent Harbor server"),
                                   actions)
  of "error":
    result = newStoryControlCenter(newFailingDataSource(
      "GET /api/v1/initiatives failed: connection refused (the server is not running, " &
      "or its address is wrong)", "unreachable server"), actions)
  of "empty":
    result = newStoryControlCenter(newSnapshotDataSource(
      FleetSnapshot(capturedAtMs: ControlCenterNowMs, sourceLabel: "empty server"),
      "empty server"), actions)
  of "launching":
    let source = projectSource()
    result = newStoryControlCenter(source, actions)
    result.launchHistory(actions)
    result.chooseInitiative(ShieldInitiative)
    actions.script.setRule(oaLaunchTask, confirmedWith(noticeFor("8c1a13", "ws-ada")))
    result.composer.setText(EmptyShieldTask)
    result.composer.updateLaunch(launchOptions("test/empty-shield"))
    result.composer.submit()
    # The server's next frame: the session the launch started, queued.
    discard source.sendFrame(FleetFrame(kind: ffSession, session: launchedSession()))
  else:
    result = newStoryControlCenter(projectSource(), actions)
    result.launchHistory(actions)
