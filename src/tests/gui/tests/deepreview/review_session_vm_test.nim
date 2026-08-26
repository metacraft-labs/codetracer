## A review loads the agent session that produced it (RV-6).
##
## `codetracer-specs/DeepReview/DeepReview-GUI.md` §2.1: "The primary thing
## the panel shows in a review is **the agent session that produced it**.  A
## review dataset MAY carry an optional reference to that session; when it
## does, opening the review loads the session into the Agent Activity panel."
##
## Four claims are asserted here, and they are the milestone's own
## verification entries minus the two that belong to the sibling repositories
## (`nim-acp`'s `session/load` and `nim-agents`' `loadSession`, which are
## covered in those repositories' suites):
##
##   1. **A dataset with no session reference reviews normally.**  Absence is
##      the ordinary case — a human ran `ct review collect` — and it must
##      produce neither an error nor an empty shell, and must not disturb a
##      conversation the panel already has.
##   2. **A resolvable reference renders the session's messages.**
##   3. **An unresolvable reference renders an explicit state.**  Three
##      distinguishable ones: the agent cannot replay sessions at all, this
##      particular session could not be fetched, and the session loaded but is
##      empty.  All three render an identical *empty message list*, so the
##      sentence is the only thing that tells a reviewer what happened.  §2.1
##      calls the alternative a defect: "It must not silently render an empty
##      session, which reads as 'the agent did nothing'."
##   4. **The dataset carries a reference, never a transcript.**  Asserted at
##      the reader: a `review.json` with a session block yields an id plus the
##      context needed to resolve it and no conversation content at all.
##
## The last suite covers `src/ct/review_session.nim`'s pure half — what the
## agent's environment *means*, and what stamping a reference into a dataset
## does — because that is where deliverable 4 ("the collectors record the
## reference when the environment identifies a session; absence is normal, not
## an error") is decided.  It is a pure function of its inputs by design, so
## it is checkable on both Nim backends with no environment mutation and no
## collector installed.
##
## ## Test doubles
##
## Only `MockBackendService`, which every ViewModel suite uses to construct a
## `ReplayDataStore` and which stands in for the debugger backend, not for
## anything under test here.  There is deliberately **no** fake agent in this
## file: by the time the renderer sees a session it is already a resolved
## document, and the agent-facing half — the ACP `session/load` round trip and
## the two-backend `loadSession` — is exercised against the sanctioned
## `nim_acp/fake.nim` seam and an in-process Harbor HTTP transport in
## `nim-acp/tests/test_session_load.nim` and
## `nim-agents/tests/test_session_load_client.nim`.  Duplicating that here
## would test those repositories' code through a second, weaker imitation of
## their own fakes.  Everything below — the projection, the notice text, the
## entry routine, the environment reading, the stamping — is production code.

import std/[json, strutils, unittest]

import isonim/core/[computation, owner, signals]

import backend/mock_backend
import store/[replay_data_store, types]
import viewmodels/[agent_activity_vm,
  review_entry, review_session, vcs_vm]
import ../../../../ct/review_session as ct_review_session
import ../../../../common/types as ct_types
import lib/review_dataset_json

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

proc sampleDataset(): ReviewDataset =
  ## A two-file changeset, enough for the review to have somewhere to land.
  ReviewDataset(
    title: "Review: parser cleanup",
    commit: "a1b2c3d4e5f6...",
    files: @[
      ReviewFile(path: "src/main.rs", baseName: "main.rs", status: "M",
        additions: 4, deletions: 1, coveredLines: 15, totalLines: 17,
        hasFlow: true),
      ReviewFile(path: "src/utils.rs", baseName: "utils.rs", status: "M",
        additions: 2, deletions: 0, coveredLines: 5, totalLines: 7,
        hasFlow: false)],
    traceContexts: @[],
    functionsTraced: 3)

const LoadedSessionJson = """
{
  "state": "loaded",
  "sessionId": "session-abc",
  "backend": "acp",
  "message": "",
  "events": [
    {"kind": "thought_chunk", "text": "reading the failing test",
     "status": "", "toolName": "", "toolCallId": "", "filePath": ""},
    {"kind": "tool_call", "text": "", "status": "",
     "toolName": "Run tests", "toolCallId": "tool-3", "filePath": ""},
    {"kind": "message_chunk", "text": "fixed the off-by-one",
     "status": "", "toolName": "", "toolCallId": "", "filePath": ""},
    {"kind": "file_edit", "text": "", "status": "applied",
     "toolName": "", "toolCallId": "", "filePath": "src/main.rs"}
  ]
}
"""

const PrunedSessionJson = """
{
  "state": "unavailable",
  "sessionId": "session-long-gone",
  "backend": "acp",
  "message": "unknown session: session-long-gone",
  "events": []
}
"""

const UnsupportedSessionJson = """
{
  "state": "unsupported",
  "sessionId": "session-abc",
  "backend": "acp",
  "message": "session/load: the agent does not advertise the loadSession capability",
  "events": []
}
"""

const EmptySessionJson = """
{
  "state": "loaded",
  "sessionId": "session-quiet",
  "backend": "harbor",
  "message": "",
  "events": []
}
"""

const DatasetWithSessionJson = """
{
  "commitSha": "a1b2c3d4e5f6a1b2c3d4",
  "baseCommitSha": "0000111122223333aaaa",
  "collectionTimeMs": 12,
  "recordingCount": 1,
  "sessionTitle": "parser cleanup",
  "traceContexts": [],
  "files": [],
  "session": {
    "sessionId": "session-abc",
    "backend": "acp",
    "workspacePath": "/work/repo",
    "taskId": "",
    "agentCommand": "claude-code-acp",
    "agentArgs": ["--flag"],
    "endpoint": ""
  }
}
"""

const DatasetWithoutSessionJson = """
{
  "commitSha": "a1b2c3d4e5f6a1b2c3d4",
  "baseCommitSha": "0000111122223333aaaa",
  "collectionTimeMs": 12,
  "recordingCount": 1,
  "sessionTitle": "parser cleanup",
  "traceContexts": [],
  "files": []
}
"""

proc noSession(): ReviewSession =
  ## What the renderer projects when the dataset named no session: `ct` wrote
  ## no resolved-session document, so `StartOptions.reviewSession` is nil.
  let absent: ct_types.DeepReviewSessionTranscript = nil
  reviewSessionFrom(absent)

proc sessionOf(fixture: string): ReviewSession =
  ## The production projection, over the production decode of the document
  ## `ct` writes.
  reviewSessionFrom(decodeReviewSessionTranscript(fixture))

template withReviewPanels(body: untyped) =
  ## The two ViewModels a review touches, inside one reactive root.  There were
  ## three until AA-1 deleted the Agent Activity roll-up.
  createRoot proc(dispose: proc()) =
    let mock {.inject.} = newMockBackendService()
    let store {.inject.} = createReplayDataStore(mock.toBackendService())
    let vcs {.inject.} = createVCSVM()
    let conversation {.inject.} = createAgentActivityVM(store)
    body
    dispose()

# ---------------------------------------------------------------------------
# 1. A dataset with no session reference reviews normally
# ---------------------------------------------------------------------------

suite "RV-6: a review with no session":
  test "review_session_absent_dataset_reviews_normally":
    ## §2.1: "A dataset collected by a human, or by an agent whose backend
    ## cannot replay sessions, is a complete review; the panel simply shows no
    ## session rather than an error or an empty shell."
    withReviewPanels:
      let session = noSession()
      check session.state == rssAbsent
      check not session.hasSession()
      check session.sessionNoticeText() == ""

      discard enterReview(vcs, sampleDataset(), nil,
        conversation = conversation, session = session)

      # The review itself is untouched by the absence.
      check vcs.changedFiles.val.len == 2
      check vcs.reviewCommit.val == "a1b2c3d4e5f6..."
      check vcs.deepReviewMode.val
      # No session, no conversation, and — critically — no notice: there is
      # nothing to explain.
      check conversation.messages.val.len == 0
      check conversation.sessionNotice.val == ""
      check not conversation.hasSessionNotice.val

  test "review_session_absent_does_not_clear_a_live_conversation":
    ## The agentic handoff enters a review from *inside* a running session.
    ## A review that names no session of its own must not erase the
    ## conversation the reviewer arrived from — that would delete the very
    ## thing §2.1 wants kept readable.
    withReviewPanels:
      conversation.setMessages(@[
        AgentActivityMessageEntry(id: "live:0", content: "still talking",
          role: aamrAgent)])

      discard enterReview(vcs, sampleDataset(), nil,
        conversation = conversation,
        session = noSession())

      check conversation.messages.val.len == 1
      check conversation.messages.val[0].content == "still talking"

  test "review_session_absent_leaves_the_panel_saying_nothing":
    ## RV-6 used to demote a coverage roll-up here when a session was present
    ## and leave it open when one was not.  AA-1 deleted the roll-up, so the
    ## only thing left to assert is the honest one: with no session the panel
    ## has nothing to show and says nothing — it does not invent a notice, and
    ## it certainly does not fall back to a summary of the dataset.
    withReviewPanels:
      discard enterReview(vcs, sampleDataset(), nil,
        conversation = conversation,
        session = noSession())
      check conversation.messages.val.len == 0
      check conversation.sessionNotice.val == ""
      check not conversation.hasSessionNotice.val

# ---------------------------------------------------------------------------
# 2. A resolvable reference renders the session's messages
# ---------------------------------------------------------------------------

suite "RV-6: a review whose session resolves":
  test "review_session_resolvable_renders_the_sessions_messages":
    withReviewPanels:
      let session = sessionOf(LoadedSessionJson)
      check session.state == rssLoaded
      check session.sessionId == "session-abc"
      check session.events.len == 4

      discard enterReview(vcs, sampleDataset(), nil,
        conversation = conversation, session = session)

      let messages = conversation.messages.val
      check messages.len == 4
      # In the order the agent produced them.
      check messages[0].content == "reading the failing test"
      # An event with no text of its own is named by what it did, not left
      # blank: a blank row is indistinguishable from a missing one.
      check messages[1].content == "Run tests"
      check messages[2].content == "fixed the off-by-one"
      check messages[3].content == "src/main.rs"
      # Ids match the live path's scheme so the two cannot collide in the DOM.
      check messages[0].id == "session-abc:0"
      check messages[3].id == "session-abc:3"
      # Nothing is in flight: this session has finished.
      for message in messages:
        check not message.isLoading
      check not conversation.isLoading.val
      check conversation.sessionKey.val == "session-abc"
      # A conversation that speaks for itself needs no explanation.
      check conversation.sessionNotice.val == ""

  test "review_session_resolvable_leaves_the_panel_to_the_session":
    ## RV-6 demoted a coverage roll-up here so the session came first; AA-1
    ## removed the roll-up outright, so §2.1's "the primary thing the panel
    ## shows in a review is the agent session that produced it" is now literal.
    ## The dataset's coverage did not vanish with it — it is the VCS panel's,
    ## which is where the reviewer reads it.
    withReviewPanels:
      discard enterReview(vcs, sampleDataset(), nil,
        conversation = conversation, session = sessionOf(LoadedSessionJson))
      check conversation.messages.val.len == 4
      check vcs.changedFiles.val.len == 2
      # The exact numbers the deleted roll-up used to assert (15/17 and 5/7 of
      # `sampleDataset`, 20 covered lines in total), read off the surface that
      # replaced it.  Asserted exactly rather than as "not empty", because a
      # badge that renders the wrong coverage is the failure worth catching.
      check vcs.changedFiles.val[0].coverageText == "15/17"
      check vcs.changedFiles.val[1].coverageText == "5/7"

  test "review_session_entry_is_re_runnable":
    ## Every launch path re-syncs its data, and `enterReview` is re-run each
    ## time.  Re-entering must not duplicate the conversation.
    withReviewPanels:
      let session = sessionOf(LoadedSessionJson)
      discard enterReview(vcs, sampleDataset(), nil,
        conversation = conversation, session = session)
      discard enterReview(vcs, sampleDataset(), nil,
        conversation = conversation, session = session)
      check conversation.messages.val.len == 4

# ---------------------------------------------------------------------------
# 3. An unresolvable reference renders an explicit state
# ---------------------------------------------------------------------------

suite "RV-6: a review whose session does not resolve":
  test "review_session_pruned_says_so_explicitly":
    withReviewPanels:
      let session = sessionOf(PrunedSessionJson)
      check session.state == rssUnavailable
      check session.hasSession()

      discard enterReview(vcs, sampleDataset(), nil,
        conversation = conversation, session = session)

      check conversation.messages.val.len == 0
      let notice = conversation.sessionNotice.val
      check conversation.hasSessionNotice.val
      # It names the session, so the reviewer knows *which* one is gone …
      check notice.contains("session-long-gone")
      # … and quotes the backend's own reason rather than inventing one.
      check notice.contains("unknown session: session-long-gone")

  test "review_session_unsupported_agent_says_so_explicitly":
    ## A different fact from "this session is gone": no session on this agent
    ## will load, so retrying another id is pointless and the sentence must
    ## not suggest otherwise.
    withReviewPanels:
      let session = sessionOf(UnsupportedSessionJson)
      check session.state == rssUnsupported

      discard enterReview(vcs, sampleDataset(), nil,
        conversation = conversation, session = session)

      check conversation.messages.val.len == 0
      let notice = conversation.sessionNotice.val
      check notice.contains("cannot replay sessions")
      check notice.contains("loadSession")

  test "review_session_loaded_but_empty_is_not_silence":
    ## The case the defect condition is really about: the fetch *succeeded*
    ## and there is nothing to show.  Rendering that as an empty panel is
    ## indistinguishable from the two failures above and from a healthy
    ## session, so it gets a sentence too.
    withReviewPanels:
      let session = sessionOf(EmptySessionJson)
      check session.state == rssLoaded
      check session.events.len == 0

      discard enterReview(vcs, sampleDataset(), nil,
        conversation = conversation, session = session)

      check conversation.messages.val.len == 0
      check conversation.sessionNotice.val.contains("session-quiet")
      check conversation.sessionNotice.val.contains("no messages")

  test "review_session_the_three_empty_states_are_distinguishable":
    ## The property that makes the three sentences worth having: they render
    ## the same message list, so they must not render the same sentence.
    let pruned = sessionOf(PrunedSessionJson).sessionNoticeText()
    let unsupported = sessionOf(UnsupportedSessionJson).sessionNoticeText()
    let empty = sessionOf(EmptySessionJson).sessionNoticeText()
    check pruned.len > 0
    check unsupported.len > 0
    check empty.len > 0
    check pruned != unsupported
    check pruned != empty
    check unsupported != empty

  test "review_session_an_unreadable_state_is_never_read_as_loaded":
    ## A document whose `state` we do not recognise must not be treated as a
    ## successful load: that would paint an empty conversation and attribute
    ## it to the agent.
    check parseReviewSessionState("loaded") == rssLoaded
    check parseReviewSessionState("absent") == rssAbsent
    check parseReviewSessionState("unsupported") == rssUnsupported
    check parseReviewSessionState("unavailable") == rssUnavailable
    check parseReviewSessionState("") == rssUnavailable
    check parseReviewSessionState("nonsense-from-a-newer-ct") == rssUnavailable

# ---------------------------------------------------------------------------
# 4. The dataset carries a reference, never a transcript
# ---------------------------------------------------------------------------

suite "RV-6: the dataset carries a reference":
  test "review_dataset_session_reference_survives_the_reader":
    let dataset = decodeReviewDatasetJson(DatasetWithSessionJson)
    check not dataset.session.isNil
    check $dataset.session.sessionId == "session-abc"
    check $dataset.session.backend == "acp"
    check $dataset.session.workspacePath == "/work/repo"
    check $dataset.session.agentCommand == "claude-code-acp"
    check dataset.session.agentArgs.len == 1
    check $dataset.session.agentArgs[0] == "--flag"

  test "review_dataset_without_a_session_reference_decodes_to_none":
    ## Absent is nil, not an empty reference: an empty reference would be
    ## rendered as an unresolvable one, which is a statement about a session
    ## the dataset never had.
    let dataset = decodeReviewDatasetJson(DatasetWithoutSessionJson)
    check dataset.session.isNil

  test "review_dataset_reference_is_an_id_not_a_conversation":
    ## The rule §2.1 states as "by reference, never by copy", asserted as a
    ## property of the wire format: the dataset's session block contains no
    ## message, no transcript and no event list, only what is needed to ask
    ## the backend for one.
    let node = parseJson(DatasetWithSessionJson)["session"]
    check node.kind == JObject
    for key in ["events", "messages", "transcript", "updates", "conversation"]:
      check not node.hasKey(key)
    check node.hasKey("sessionId")

# ---------------------------------------------------------------------------
# The collect-side decision: what the environment means
# ---------------------------------------------------------------------------

proc envOf(pairs: openArray[(string, string)]): proc(name: string): string =
  ## An environment as a lookup closure, so the reading is checkable without
  ## mutating the test process's own environment (and therefore without
  ## ordering hazards between cases).
  let table = @pairs
  proc(name: string): string =
    for (key, value) in table:
      if key == name:
        return value
    ""

suite "RV-6: recording the reference at collection time":
  test "review_session_env_with_no_session_is_normal_not_an_error":
    ## Deliverable 4: "absence is normal, not an error".  A human running
    ## `ct review collect` by hand has none of the variables set.
    let spec = reviewSessionRefFromEnv(envOf([]))
    check not ct_review_session.hasSessionRef(spec)
    check spec.sessionId == ""

  test "review_session_env_names_an_acp_session":
    let spec = reviewSessionRefFromEnv(envOf([
      (ReviewSessionIdEnvVar, "session-abc"),
      (ReviewSessionAcpCommandEnvVar, "claude-code-acp"),
      (ReviewSessionAcpArgsEnvVar, "  --flag   --other "),
      (ReviewSessionWorkspaceEnvVar, "/work/repo")]))
    check ct_review_session.hasSessionRef(spec)
    check spec.sessionId == "session-abc"
    check spec.backend == AcpBackendName
    check spec.agentCommand == "claude-code-acp"
    check spec.agentArgs == @["--flag", "--other"]
    check spec.workspacePath == "/work/repo"

  test "review_session_env_infers_harbor_from_an_endpoint":
    ## A harness that set a Harbor URL is running a Harbor session; making the
    ## backend variable mandatory would mean a harness that set everything
    ## else still produced no reference.
    let spec = reviewSessionRefFromEnv(envOf([
      (ReviewSessionIdEnvVar, "session-harbor"),
      (ReviewSessionHarborUrlEnvVar, "http://harbor.example"),
      (ReviewSessionTaskEnvVar, "task-9")]))
    check spec.backend == HarborBackendName
    check spec.endpoint == "http://harbor.example"
    check spec.taskId == "task-9"

  test "review_session_env_declaration_beats_inference":
    let spec = reviewSessionRefFromEnv(envOf([
      (ReviewSessionIdEnvVar, "session-abc"),
      (ReviewSessionHarborUrlEnvVar, "http://harbor.example"),
      (ReviewSessionBackendEnvVar, "acp")]))
    check spec.backend == AcpBackendName

  test "review_session_env_falls_back_to_the_collection_directory":
    ## The workspace an ACP agent resolves a session against.  With no
    ## explicit variable, where the collection ran is the best available
    ## answer — and a wrong one is reported by the agent as an unresolvable
    ## reference rather than silently replaying another tree's session.
    let spec = reviewSessionRefFromEnv(envOf([
      (ReviewSessionIdEnvVar, "session-abc")]),
      fallbackWorkspace = "/run/collect")
    check spec.workspacePath == "/run/collect"

  test "review_session_env_ignores_context_without_an_id":
    ## Half an environment is not a reference.  Stamping one with an empty id
    ## would give the review the "unresolvable" state — a statement about a
    ## session it never had.
    let spec = reviewSessionRefFromEnv(envOf([
      (ReviewSessionHarborUrlEnvVar, "http://harbor.example"),
      (ReviewSessionAcpCommandEnvVar, "claude-code-acp")]))
    check not ct_review_session.hasSessionRef(spec)

  test "review_session_stamp_writes_the_reference_into_the_dataset":
    let spec = reviewSessionRefFromEnv(envOf([
      (ReviewSessionIdEnvVar, "session-abc"),
      (ReviewSessionAcpCommandEnvVar, "claude-code-acp")]))
    let stamped = parseJson(DatasetWithoutSessionJson).withSessionRef(spec)
    check stamped["session"]["sessionId"].getStr() == "session-abc"
    check stamped["session"]["backend"].getStr() == "acp"
    check stamped["session"]["agentCommand"].getStr() == "claude-code-acp"
    # Everything else is left exactly as the collector wrote it.
    check stamped["sessionTitle"].getStr() == "parser cleanup"
    check stamped["recordingCount"].getInt() == 1

  test "review_session_stamp_removes_rather_than_nulls_a_missing_reference":
    ## A `"session": null` would be indistinguishable from a reference that
    ## failed to serialise; one of those is normal and the other is a bug.
    let stamped = parseJson(DatasetWithSessionJson).withSessionRef(
      ReviewSessionRefSpec())
    check not stamped.hasKey("session")

  test "review_session_stamp_is_idempotent":
    ## Collecting twice into the same directory must not leave a stale
    ## reference behind, nor accumulate.
    let first = reviewSessionRefFromEnv(envOf([
      (ReviewSessionIdEnvVar, "session-one")]))
    let second = reviewSessionRefFromEnv(envOf([
      (ReviewSessionIdEnvVar, "session-two")]))
    var dataset = parseJson(DatasetWithoutSessionJson)
    dataset = dataset.withSessionRef(first)
    dataset = dataset.withSessionRef(second)
    check dataset["session"]["sessionId"].getStr() == "session-two"

  test "review_session_unresolved_document_always_states_a_reason":
    ## What `ct` writes when it cannot reach the agent.  It is a *document*,
    ## not an absence, precisely so the panel can say why — and its shape is
    ## the one `reviewSessionFrom` reads.
    let spec = reviewSessionRefFromEnv(envOf([
      (ReviewSessionIdEnvVar, "session-abc")]))
    let node = unresolvedSessionJson(spec, ReviewSessionStateUnavailable,
      missingAcpCommandMessage(spec))
    check node["state"].getStr() == "unavailable"
    check node["sessionId"].getStr() == "session-abc"
    check node["message"].getStr().contains(ReviewSessionAcpCommandEnvVar)
    check node["events"].len == 0

    let session = reviewSessionFrom(decodeReviewSessionTranscript($node))
    check session.state == rssUnavailable
    check session.sessionNoticeText().contains("session-abc")
    check session.sessionNoticeText().contains(ReviewSessionAcpCommandEnvVar)

  test "review_session_state_spellings_match_nim_agents":
    ## The three strings cross a process boundary (`nim-agents` writes them,
    ## `ct` forwards them, the renderer parses them), so the round trip is
    ## pinned at both ends — here, and by
    ## `agents_load_session_state_renders_as_a_stable_string` in
    ## `nim-agents/tests/test_session_load_client.nim`.
    check parseReviewSessionState(ReviewSessionStateLoaded) == rssLoaded
    check parseReviewSessionState(ReviewSessionStateUnsupported) ==
      rssUnsupported
    check parseReviewSessionState(ReviewSessionStateUnavailable) ==
      rssUnavailable

# ---------------------------------------------------------------------------
# The stamp on a real filesystem (native only)
# ---------------------------------------------------------------------------

when not defined(js):
  import std/os

  proc scratchDir(name: string): string =
    result = getTempDir() / ("ct-rv6-stamp-" & name & "-" & $getCurrentProcessId())
    removeDir(result)
    createDir(result)

  suite "RV-6: stamping a dataset on disk":
    test "review_session_stamp_without_a_session_does_not_demand_a_dataset":
      ## A regression guard.  The first implementation reported a missing
      ## `review.json` as an error *unconditionally*, which made every
      ## ordinary `ct review collect` — the ones with no agent session at all
      ## — depend on a post-condition the collectors' own success reporting
      ## does not make, and broke the native collector's routing case.
      ## Absence of a session must stay costless (DeepReview-GUI.md §2.1).
      let dir = scratchDir("absent")
      defer: removeDir(dir)
      let missing = dir / "review.json"
      check stampReviewSessionRef(missing, ReviewSessionRefSpec()) == ""
      check not fileExists(missing)

    test "review_session_stamp_with_a_session_reports_a_missing_dataset":
      ## The other side of it: somebody who *did* set the variables asked for
      ## an association and must be told they did not get one, rather than
      ## the reference being dropped silently.
      let dir = scratchDir("missing")
      defer: removeDir(dir)
      let missing = dir / "review.json"
      let spec = reviewSessionRefFromEnv(envOf([
        (ReviewSessionIdEnvVar, "session-abc")]))
      let failure = stampReviewSessionRef(missing, spec)
      check failure.len > 0
      check failure.contains(missing)

    test "review_session_stamp_round_trips_through_a_real_dataset_file":
      ## End to end over the filesystem: stamp, read back with the production
      ## reader, and confirm nothing else in the dataset moved.
      let dir = scratchDir("roundtrip")
      defer: removeDir(dir)
      let path = dir / "review.json"
      writeFile(path, DatasetWithoutSessionJson)
      let spec = reviewSessionRefFromEnv(envOf([
        (ReviewSessionIdEnvVar, "session-abc"),
        (ReviewSessionAcpCommandEnvVar, "claude-code-acp"),
        (ReviewSessionAcpArgsEnvVar, "--flag")]))
      check stampReviewSessionRef(path, spec) == ""

      let readBack = reviewSessionRefOfDataset(path)
      check readBack.sessionId == "session-abc"
      check readBack.backend == AcpBackendName
      check readBack.agentCommand == "claude-code-acp"
      check readBack.agentArgs == @["--flag"]
      let dataset = decodeReviewDatasetJson(readFile(path))
      check $dataset.sessionTitle == "parser cleanup"
      check dataset.recordingCount == 1

      # And re-stamping with nothing removes it again, so a dataset cannot
      # keep pointing at a session a later collection had no knowledge of.
      check stampReviewSessionRef(path, ReviewSessionRefSpec()) == ""
      check not hasSessionRef(reviewSessionRefOfDataset(path))

    test "review_session_ref_of_an_unreadable_dataset_is_no_reference":
      ## A malformed dataset is the renderer's diagnosis to make, not this
      ## module's; answering "no session" keeps the better error.
      let dir = scratchDir("malformed")
      defer: removeDir(dir)
      let path = dir / "review.json"
      writeFile(path, "{ this is not json")
      check not hasSessionRef(reviewSessionRefOfDataset(path))
      check not hasSessionRef(reviewSessionRefOfDataset(dir / "nothing.json"))
