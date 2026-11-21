## The suggested UI actions stories' viewmodel constructors.
##
## A story of the `agent-harbor-suggested-actions` surface (declared in
## `codetracer_stories.nim`) is the session activity timeline of one
## session (`SessionTimelineVM`, P2b's view) with a suggested-actions block
## at its end (`SuggestedActionsVM`), both built by
## `createSuggestedActionsStory` for the story's fixture.
##
## Every story is a moment of the CTF-P2L project (`layout_story_data.nim`,
## the invented `noir-space-ship` repository; P2c study D26): the session is
## the drained-field test's (`Add a test for an asteroid field that drains
## the shield`), whose agent wrote `drained_field_fails`, ran it (it fails,
## as it should before the clamp), recorded it, and asks whether it should
## expect the shield at exactly 0 after pass 5. Its timeline is built here
## from that conversation (`layout_story_data.projectConversation`) with the
## viewmodels' event builders (`session_events`), served by a
## `TimelineDataSource`; the suggestion is the one its agent makes about it
## (`projectSuggestion`), the same one CTF-P2L's L3 window shows.
##
## No suggestion source, performer or Agent Harbor reply is wired yet, and
## the prototypes never write to a server, so the actions are performed by a
## `ScriptedActionPerformer` and the decision goes to a
## `ScriptedActionSource` (the seams' own implementations); every decided
## state is reached by driving the viewmodel as the operator would
## (unchecking, approving, dismissing), never by setting its fields.

import std/json
import nim_agents_isonim_viewmodels/agent_harbor/[session_events, session_timeline_vm,
  suggested_actions_vm, suggested_action_sources, scripted_actions, data_source]
import ./layout_story_data

export session_timeline_vm, suggested_actions_vm

const
  suggestedActionsFixtures* = ["one", "several", "partial", "unsupported",
                               "approved", "dismissed", "auto-approved"]
    ## Every fixture an `agent-harbor-suggested-actions` story may name.
  SuggestionRequestId* = "suggest-drained-field-pass-5"
  SuggestionReason* = "Look at the drained-field test's recording at pass 5 " &
    "before deciding what it should expect."

type
  SuggestedActionsStory* = object
    ## What a story mounts: the session's timeline and the block at its end.
    timeline*: SessionTimelineVM
    suggestion*: SuggestedActionsVM

proc drainedFieldEvents*(): seq[JsonNode] =
  ## The drained-field session's events up to its question, oldest first,
  ## stamped a few seconds apart.
  let conversation = projectConversation("needs-input")
  var seconds = 0
  var list: seq[JsonNode]
  proc add(body: JsonNode; after = 4) =
    seconds += after
    var event = body.copy
    event["timestamp"] = %(int64(seconds) * 1_000_000)
    list.add event
  add statusEvent("running")
  add userInput(conversation.messages[0].content)
  add fileRead("src/tests.nr")
  add fileRead("src/shield.nr")
  add fileEdit("src/tests.nr", 14, 0, "Added drained_field_fails.")
  add commandCall("c1", "nargo test drained_field_fails")
  add toolResult("c1", "runCmd", 1,
                 "test drained_field_fails ... FAILED: Failed assertion at src/tests.nr:31")
  add commandCall("c2", "ct record-test drained_field_fails")
  add toolResult("c2", "runCmd", 0, "Recorded drained_field_fails; trace uploaded")
  add agentReply("Wrote `drained_field_fails` with masses [2000, 3000, 6000, 1600, " &
                 "1290, 1110, 1, 1]; the shield reaches 0 at pass 5.")
  add agentQuestion("Should drained_field_fails expect the shield at exactly 0 after " &
                    "pass 5, or anything below 1?", ["Exactly 0", "Anything below 1"])
  list

proc openRecording(): SuggestedAction =
  SuggestedAction(id: "open-recording", action: "open-url",
    args: @[("url", "codetracer://recordings/drained_field_fails?pass=5")],
    description: "Open the recording of drained_field_fails in a new tab, at pass 5",
    doneText: "Opened the recording of drained_field_fails in a new tab, at pass 5")

proc showCallTrace(): SuggestedAction =
  SuggestedAction(id: "show-calltrace", action: "arrange-layout",
    args: @[("layout", "editor|calltrace")],
    description: "Show the call trace beside the editor",
    doneText: "Showed the call trace beside the editor")

proc showVariables(): SuggestedAction =
  SuggestedAction(id: "show-variables", action: "show-panel",
    args: @[("panel", "variables")],
    description: "Show the Variables panel",
    doneText: "Showed the Variables panel")

proc openMacRecording(): SuggestedAction =
  SuggestedAction(id: "open-mac-recording", action: "open-url",
    args: @[("url", "codetracer://recordings/drained_field_fails?runner=macos-arm64")],
    description: "Open the recording of drained_field_fails on macos-arm64",
    unavailable: "No recording of drained_field_fails on macos-arm64 has been uploaded")

proc projectSuggestion*(fixture: string): ActionSuggestion =
  ## The drained-field agent's suggestion a story of `fixture` shows.
  result = ActionSuggestion(requestId: SuggestionRequestId,
                            sessionId: DrainedTestSession, reason: SuggestionReason)
  case fixture
  of "one": result.actions = @[openRecording()]
  of "unsupported":
    result.actions = @[openRecording(), showCallTrace(), openMacRecording()]
  of "auto-approved": result.actions = @[showVariables()]
  of "dismissed": result.actions = @[openRecording(), showCallTrace()]
  else: result.actions = @[openRecording(), showCallTrace(), showVariables()]

proc newDrainedFieldTimeline*(): SessionTimelineVM =
  ## The drained-field session's timeline, loaded, following its end (the
  ## block is at the end). Call inside a reactive root.
  let source = newTimelineDataSource(@[(DrainedTestSession, drainedFieldEvents())],
                                     label = "the drained-field session")
  result = newSessionTimelineVM(source, DrainedTestSession)
  result.load()

proc createSuggestedActionsStory*(fixture: string): SuggestedActionsStory =
  ## The timeline and the block a story of `fixture` shows, reached by
  ## driving the block as the operator would. Call inside a reactive root;
  ## the caller disposes both. An unknown fixture raises rather than showing
  ## some other state under its name.
  if fixture notin suggestedActionsFixtures:
    raise newException(ValueError, "no suggested actions story fixture named " & fixture)
  let performer = newScriptedActionPerformer("the story's UI-action performer")
  let actions = newScriptedActionSource("the story's actions")
  let held = newSuggestedActionsVM(projectSuggestion(fixture), performer, actions,
                                    autoApproved = fixture == "auto-approved")
  case fixture
  of "partial":
    held.toggle("show-calltrace")
  of "approved":
    held.toggle("show-variables")
    held.approve()
  of "dismissed":
    held.dismiss()
  else: discard
  SuggestedActionsStory(timeline: newDrainedFieldTimeline(), suggestion: held)

proc dispose*(story: SuggestedActionsStory) =
  if story.suggestion != nil: story.suggestion.dispose()
  if story.timeline != nil: story.timeline.dispose()
