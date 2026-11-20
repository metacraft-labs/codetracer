## The omnibox composer stories' viewmodel constructors.
##
## A story of the `agent-harbor-composer` surface (declared in
## `codetracer_stories.nim`) is an `OmniboxComposerVM` built by
## `createComposerStoryVM` over the story's fixture and the production view
## `isonim_agent_harbor_composer_view` rendered over it, in the caption bar
## of a window whose replay is stopped at `src/shield.nr:7`.
##
## Every story is a moment of the CTF-P2L project (`layout_story_data.nim`,
## the invented `noir-space-ship` repository): the window's session is the
## clamp session of Shield model hardening, its manager is that
## initiative's, and the context the window offers is what that window
## shows. No routing agent exists yet, and the prototypes never write to a
## server, so the routing decisions and UI actions are scripted
## (`ScriptedRouter`, the composer's own seam) and every delivery to Agent
## Harbor is answered by a `ScriptedActionSource` (the action seam) to agree
## with that window; every state is reached by driving the viewmodel as an
## operator would (typing, choosing, sending), never by setting its fields.

import std/[strutils, tables]
import nim_agents_isonim_viewmodels/agent_harbor/[omnibox_composer_vm, instruction_router,
                                                   scripted_actions]
import ./layout_story_data

export omnibox_composer_vm

const
  composerFixtures* = ["recent", "typing", "multi-line", "routing",
    "sends-when-routed", "manager", "ui-action", "redirected", "no-session",
    "context-edited", "add-context", "sending", "sent", "sent-again",
    "send-failed", "route-failed", "stop", "ui-done", "ui-refused",
    "ui-partial", "launch", "launch-invalid", "launch-scheduled", "launched",
    "new-initiative", "new-initiative-invalid", "gaze", "gaze-paused",
    "long-names"]
    ## Every fixture an `agent-harbor-composer` story may name.
  ComposerPlanDate* = "2026-11-17"
  Dot = " \xC2\xB7 "

  AlsoTestEmpty = "Also test a hit on an empty shield"
  WhichNext = "Which milestone of the shield work should take the damage overflow next?"
  ShowDamage = "Show calculate_damage beside the editor"
  ShowDamageAndLog = "Show calculate_damage beside the editor and open the Event Log"
  StepBack = "Go back to where the shield was last positive"
  LaunchTask = "Start a task: make the regeneration cap configurable per ship"
  NewInitiative = "Start an initiative: asteroid fields generated from seeds, end to end"
  WhyBelowZero = "Why does this go below zero here?"

proc targets(running = false; session = true;
             sessionTitle = "Clamp the shield at zero after a hit";
             managerLabel = "Shield model hardening"): seq[RouteTarget] =
  ## The window's destinations: its session (the clamp work), the manager
  ## of that session's initiative, and CodeTracer for UI actions.
  @[RouteTarget(kind: tkSession, id: (if session: ClampSession else: ""),
                label: (if session: sessionTitle else: ""),
                available: session, running: running,
                unavailableReason: (if session: "" else: "No agent session in this window")),
    RouteTarget(kind: tkManager, id: "sh-manager",
                label: "Manager of " & managerLabel, available: true),
    RouteTarget(kind: tkUiAction, id: "codetracer", label: "CodeTracer",
                available: true)]

proc windowContext(): seq[ContextItem] =
  ## What the window shows: the editor at the stopped line with its
  ## selection, the replay position, the Variables pane's selected value,
  ## and the session tab in view.
  @[ContextItem(id: "file", kind: ckFile, label: "src/shield.nr:7",
                detail: "The open file and the cursor", reference: "src/shield.nr:7"),
    ContextItem(id: "selection", kind: ckSelection, label: "remaining_shield -= damage",
                detail: "The editor's selection", reference: "src/shield.nr:7:9-35"),
    ContextItem(id: "replay", kind: ckReplay, label: "Pass 2 of iterate_asteroids",
                detail: "The replay position",
                reference: "replay:noir-space-ship#iterate_asteroids/2"),
    ContextItem(id: "pane", kind: ckPane, label: "Variables: remaining_shield = 9000",
                detail: "The focused pane and its selection",
                reference: "state:remaining_shield"),
    ContextItem(id: "session", kind: ckSession, label: "Clamp the shield at zero after a hit",
                detail: "The session tab in view",
                reference: "agent-harbor://sessions/" & ClampSession)]

proc storyRouter(): ScriptedRouter =
  ## The decisions and receipts every story's router knows.
  result = newScriptedRouter("scripted router (invented decisions)")
  result.decide(AlsoTestEmpty, RoutingDecision(target: tkSession,
    reason: "It is about the clamp this session is changing",
    cited: @["file", "replay"]))
  result.decide(WhichNext, RoutingDecision(target: tkManager,
    reason: "It is about the initiative's plan, not one session's change"))
  result.decide(ShowDamage, RoutingDecision(target: tkUiAction,
    reason: "It asks for something CodeTracer shows",
    action: "Open calculate_damage (src/shield.nr:22) beside src/shield.nr",
    cited: @["file"]))
  result.decide(ShowDamageAndLog, RoutingDecision(target: tkUiAction,
    reason: "It asks for two things CodeTracer shows",
    action: "Open calculate_damage beside the editor, then the Event Log",
    cited: @["file"]))
  result.decide(StepBack, RoutingDecision(target: tkUiAction,
    reason: "It moves the replay",
    action: "Move the replay back to the last step where remaining_shield > 0",
    cited: @["replay", "pane"]))
  result.decide(LaunchTask, RoutingDecision(target: tkManager, intent: riLaunchTask,
    reason: "It asks for new work outside this session"))
  result.decide(NewInitiative, RoutingDecision(target: tkManager,
    intent: riNewInitiative, reason: "It states a new goal with milestones of its own"))
  result.decide(WhyBelowZero, RoutingDecision(target: tkSession,
    reason: "It asks about the line this session's change is on",
    cited: @["gaze", "file", "replay"]))
  result.decideByDefault(RoutingDecision(target: tkSession,
    reason: "It continues this session's work"))
  result.uiOutcome = Receipt(outcome: uoDone,
    result: "Opened calculate_damage (src/shield.nr:22) beside src/shield.nr")

const LaunchNotice = "Started on hub-a" & Dot & "executor linux-x64-4" & Dot &
                     "session 5c1a3e70"

proc storyActions(): ScriptedActionSource =
  ## Every delivery to Agent Harbor confirmed; a launch answered with where
  ## the new session started.
  result = newScriptedActionSource("scripted actions (invented answers)")
  result.script.setRule(oaLaunchTask, confirmedWith(LaunchNotice))

var actions: ScriptedActionSource
  ## The story's action source, set by `createComposerStoryVM`.

proc newStoryComposer(router: InstructionRouter; targets: seq[RouteTarget];
                      context = windowContext()): OmniboxComposerVM =
  result = newOmniboxComposerVM(router, actions, targets, context, ComposerPlanDate)
  result.agentChoices = @["Claude", "Codex", "Grok", "Opencode", "Antigravity"]
  result.executorChoices = @["linux-x64-4", "mac-arm64-2", "ws-ada"]
  result.open()

proc typeIn(vm: OmniboxComposerVM; text: string) =
  ## What the operator typed, as the field delivers it.
  vm.setText(text)

proc sendHistory(vm: OmniboxComposerVM; router: ScriptedRouter) =
  ## Five earlier instructions of this window, sent through this composer,
  ## so `Recent` lists them as they went; then the field is empty again.
  for text in ["Run nargo test after the clamp and record the failing test",
               WhichNext,
               ShowDamage,
               "Explain why regeneration can exceed the initial shield",
               AlsoTestEmpty]:
    vm.typeIn(text)
    vm.submit()
  vm.typeIn("")

proc createComposerStoryVM*(fixture: string): OmniboxComposerVM =
  ## The composer at the moment the fixture names.
  let router = storyRouter()
  actions = storyActions()
  case fixture
  of "recent":
    result = newStoryComposer(router, targets())
    result.sendHistory(router)
  of "typing":
    result = newStoryComposer(router, targets())
    result.typeIn(AlsoTestEmpty)
  of "multi-line":
    result = newStoryComposer(router, targets())
    result.typeIn(AlsoTestEmpty & "\nStart the field at zero shield and one asteroid of mass 1." &
                "\nThe status report must still say the ship survived.")
  of "routing":
    router.hold = true
    result = newStoryComposer(router, targets())
    result.typeIn(AlsoTestEmpty)
  of "sends-when-routed":
    router.hold = true
    result = newStoryComposer(router, targets())
    result.typeIn(AlsoTestEmpty)
    result.submit()
  of "manager":
    result = newStoryComposer(router, targets())
    result.typeIn(WhichNext)
  of "ui-action":
    result = newStoryComposer(router, targets())
    result.typeIn(ShowDamage)
  of "redirected":
    result = newStoryComposer(router, targets())
    result.typeIn(WhichNext)
    result.choose(tkSession)
  of "no-session":
    result = newStoryComposer(router, targets(session = false), @[])
    result.typeIn(WhichNext)
  of "context-edited":
    result = newStoryComposer(router, targets())
    result.typeIn(AlsoTestEmpty)
    result.toggleContext("replay")     # the router's citation, uncited
    result.toggleContext("pane")       # cited by the operator
  of "add-context":
    result = newStoryComposer(router, targets())
    result.typeIn(AlsoTestEmpty)
    result.toggleAddContext()
  of "sending":
    actions.script.setRule(oaSendInstruction, neverAnswered())
    result = newStoryComposer(router, targets())
    result.typeIn(AlsoTestEmpty)
    result.submit()                    # the receipt never comes
  of "sent":
    result = newStoryComposer(router, targets())
    result.typeIn(AlsoTestEmpty)
    result.submit()
  of "sent-again":
    result = newStoryComposer(router, targets())
    result.typeIn(AlsoTestEmpty)
    result.submit()
    result.sendAgain(tkManager)
  of "send-failed":
    actions.script.setRule(oaInstructManager,
      failedWith("Agent Harbor answered 503 (the hub is restarting)"))
    result = newStoryComposer(router, targets())
    result.typeIn(WhichNext)
    result.submit()
  of "route-failed":
    router.routeFailure = "the routing agent did not answer within 20 s"
    result = newStoryComposer(router, targets())
    result.typeIn(AlsoTestEmpty)
  of "stop":
    result = newStoryComposer(router, targets(running = true))
    result.typeIn(AlsoTestEmpty)
  of "ui-done":
    result = newStoryComposer(router, targets())
    result.typeIn(ShowDamage)
    result.submit()
  of "ui-refused":
    router.uiOutcome = Receipt(outcome: uoRefused,
      result: "the replay cannot move back: the recording has no step before " &
              "pass 1 where remaining_shield > 0")
    result = newStoryComposer(router, targets())
    result.typeIn(StepBack)
    result.submit()
  of "ui-partial":
    router.uiOutcome = Receipt(outcome: uoPartial,
      result: "Done 1 of 2: opened calculate_damage beside the editor; " &
              "the Event Log is not offered for Noir recordings")
    result = newStoryComposer(router, targets())
    result.typeIn(ShowDamageAndLog)
    result.submit()
  of "launch", "launch-scheduled", "launched":
    result = newStoryComposer(router, targets())
    result.typeIn(LaunchTask)
    var o = LaunchOptions(repository: ProjectRepository, branch: "feat/regen-cap-config",
                          agents: @["Claude"], runOn: roServerChoice, openIn: oiNewTab,
                          focus: true)
    if fixture == "launch-scheduled":
      o.runOn = roExecutor
      o.executor = "linux-x64-4"
      o.schedule = Schedule(enabled: true, cron: "30 6 * * 1-5",
                            timezone: "Europe/Sofia", jitterSeconds: 120,
                            concurrency: ccForbidOverlap, misfire: mfRunOnce)
      result.toggleSchedule()
    result.updateLaunch(o)
    if fixture == "launched": result.submit()
  of "launch-invalid":
    result = newStoryComposer(router, targets())
    result.typeIn(LaunchTask)
    result.updateLaunch(LaunchOptions(runOn: roExecutor, openIn: oiNewTab,
      schedule: Schedule(enabled: true, cron: "30 25 * * 1-5", timezone: "Europe/Sofia")))
    # The schedule stays folded: its first problem shows on its head line.
  of "new-initiative":
    result = newStoryComposer(router, targets())
    result.typeIn(NewInitiative)
    result.updateInitiative(NewInitiativeForm(
      goal: "Asteroid fields generated from seeds, end to end", iteration: imAuto,
      relatedSpecs: @["spec/Fixtures.md", "spec/Shield-Model.md"]))
  of "new-initiative-invalid":
    result = newStoryComposer(router, targets())
    result.typeIn(NewInitiative)
    result.updateInitiative(NewInitiativeForm(
      goal: "Asteroid fields generated from seeds, end to end", iteration: imCount,
      iterations: 0, planPath: "../plans/seeded-fields.org"))
  of "gaze":
    result = newStoryComposer(router, targets())
    result.setGaze(gsTracking, gazeChip("gaze", "remaining_shield -= damage",
                                        "src/shield.nr:7:9-35", 1400))
    result.typeIn(WhyBelowZero)
  of "gaze-paused":
    result = newStoryComposer(router, targets())
    result.setGaze(gsPaused)
    result.typeIn(WhyBelowZero)
  of "long-names":
    router.decide("Also test a hit on an empty shield when the regeneration cap is " &
                  "configured per ship and the asteroid field comes from a seed",
                  RoutingDecision(target: tkSession,
                    reason: "It is about the clamp this session is changing, and the " &
                            "regeneration cap and the seeded fields it now meets",
                    cited: @["file", "selection", "replay", "pane"]))
    result = newStoryComposer(router, targets(
      sessionTitle = "Clamp the shield at zero after a hit, and keep regeneration " &
                     "from exceeding the initial shield on every ship class",
      managerLabel = "Shield model hardening for the 0.4 release and the remote runners"))
    result.typeIn("Also test a hit on an empty shield when the regeneration cap is " &
                "configured per ship and the asteroid field comes from a seed")
  else:
    raise newException(ValueError, "no composer story fixture " & fixture &
                       "; known: " & composerFixtures.join(", "))
