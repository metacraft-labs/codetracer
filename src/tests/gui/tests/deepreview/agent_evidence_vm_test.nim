## The agent handoff is two ordinary commands (RV-7).
##
## `codetracer-specs/DeepReview/Agentic-Coding-Integration.md` §4.4: "The
## agent's route into DeepReview is the CLI, used the way a person would use
## it. … `ct agent evidence` takes the dataset path and nothing else in the
## common case.  The session it belongs to, the task, and the workspace are
## read from the **environment variables the agent already runs under**."
##
## Four claims are asserted here, and they are the milestone's own
## verification entries:
##
##   1. **Evidence resolves session, task and workspace from the
##      environment**, through the *same* routine `ct review collect` reads
##      them with (`ct/review_session.reviewSessionRefFromEnv`).  A separate
##      reader would be a second notion of "which session am I in", and the
##      two could then disagree about a dataset one of them had just stamped.
##   2. **Explicit flags override the environment**, which §4.4 keeps "for use
##      outside a managed session and in tests".
##   3. **A missing environment yields a clear error, not a wrong guess.**
##      This is the failure mode the whole design exists to avoid: an id
##      invented here attaches a review to the wrong conversation, and nothing
##      downstream can detect that it was invented.
##   4. **The end-of-turn hook runs the same two commands.**  Asserted as the
##      argv it builds, which is what "it is not a second mechanism" means
##      concretely; that those commands actually produce a loadable dataset is
##      asserted end to end, against the shipped binary and a real recording,
##      in `src/tests/cli/agent_cli_test.nim`.
##
## Two further suites cover what the milestone's flag shrink *means*: that
## every retired flag fails with a diagnostic naming its replacement rather
## than being accepted and ignored, and that every descriptive field of the
## notification is read out of the dataset instead of asserted on the command
## line — which is the reason those flags could go.
##
## ## Test doubles
##
## **None.**  Every routine under test is a pure function of its inputs:
## `resolveAgentIdentity` takes an environment lookup as a parameter (the same
## seam `reviewSessionRefFromEnv` uses), `planAgentCli` takes argv,
## `hookCollectArgs` takes options, and `notificationFromDataset` takes a
## parsed dataset.  The datasets are the checked-in outputs of the two real
## collectors, embedded with `staticRead` so this file runs unchanged on the
## JavaScript backend, where there is no filesystem.

import std/[json, strutils, unittest]

import ../../../../ct/agent_cli
import ../../../../ct/review_session as ct_review_session

const
  MaterializedFixture = staticRead("fixtures/materialized-review.json")
    ## Real `replay-server review-collect` output over a real Noir recording
    ## (`fixtures/regenerate-materialized-review.sh`).
  NativeShapedFixture = staticRead("fixtures/sample-review.json")
    ## The native collector's dataset shape.
  CodetracerSource = staticRead("../../../../ct/codetracer.nim")

proc envOf(pairs: openArray[(string, string)]):
    proc(name: string): string {.closure.} =
  ## An environment, as the closure the resolution takes.  Injected rather
  ## than exported into this process, so the suites cannot leak into each
  ## other and so they run identically on both Nim backends.
  var captured: seq[(string, string)] = @[]
  for pair in pairs:
    captured.add pair
  proc(name: string): string =
    for (key, value) in captured:
      if key == name:
        return value
    ""

let agentEnv = envOf({
  ct_review_session.ReviewSessionIdEnvVar: "agent:acp:rv7",
  ct_review_session.ReviewSessionTaskEnvVar: "task-rv7",
  ct_review_session.ReviewSessionWorkspaceEnvVar: "/work/rv7"})

let emptyEnv = envOf({"IRRELEVANT": "1"})

suite "RV-7 — the identity comes from the environment":

  test "evidence_resolves_session_task_and_workspace_from_the_environment":
    let resolved = resolveAgentIdentity(AgentIdentityFlags(), agentEnv,
      ReviewSessionRefSpec(), cwd = "/cwd")
    check resolved.error.len == 0
    check resolved.identity.sessionId == "agent:acp:rv7"
    check resolved.identity.taskId == "task-rv7"
    check resolved.identity.workspacePath == "/work/rv7"

  test "it_is_the_same_session_ct_review_collect_stamps":
    ## RV-6 writes the session reference into `review.json` from these very
    ## variables.  If RV-7 read them with a reader of its own, a dataset and
    ## the evidence handing it over could name different sessions from one
    ## environment — so the two are required to agree here, on the same input.
    let stamped = reviewSessionRefFromEnv(agentEnv)
    let resolved = resolveAgentIdentity(AgentIdentityFlags(), agentEnv,
      ReviewSessionRefSpec(), cwd = "/cwd")
    check stamped.sessionId == resolved.identity.sessionId
    check stamped.taskId == resolved.identity.taskId
    check stamped.workspacePath == resolved.identity.workspacePath

  test "explicit_flags_override_the_environment":
    let resolved = resolveAgentIdentity(
      AgentIdentityFlags(session: "flag-session", task: "flag-task",
        workspace: "/flag/workspace"),
      agentEnv, ReviewSessionRefSpec(), cwd = "/cwd")
    check resolved.error.len == 0
    check resolved.identity.sessionId == "flag-session"
    check resolved.identity.taskId == "flag-task"
    check resolved.identity.workspacePath == "/flag/workspace"

  test "a_flag_session_still_takes_the_rest_from_the_environment":
    ## `reviewSessionRefFromEnv` returns nothing at all when no session id is
    ## exported, so the case "--session given, harness environment otherwise
    ## intact" has to be covered explicitly — it is the one a test harness
    ## actually runs in.
    let resolved = resolveAgentIdentity(
      AgentIdentityFlags(session: "flag-session"),
      envOf({ct_review_session.ReviewSessionTaskEnvVar: "task-from-env",
             ct_review_session.ReviewSessionWorkspaceEnvVar: "/env/workspace"}),
      ReviewSessionRefSpec(), cwd = "/cwd")
    check resolved.identity.sessionId == "flag-session"
    check resolved.identity.taskId == "task-from-env"
    check resolved.identity.workspacePath == "/env/workspace"

  test "a_missing_environment_is_an_error_not_a_wrong_guess":
    let resolved = resolveAgentIdentity(AgentIdentityFlags(), emptyEnv,
      ReviewSessionRefSpec(), cwd = "/cwd")
    check resolved.error.len > 0
    check resolved.identity.sessionId.len == 0
    # And the diagnostic names the variable to export, the flag to pass, and
    # the dataset it also looked in — a message that only said "cannot
    # determine session" would leave all three to guesswork.
    let message = missingSessionMessage("/tmp/review.json")
    check message.contains(ct_review_session.ReviewSessionIdEnvVar)
    check message.contains("--session")
    check message.contains("/tmp/review.json")

  test "the_dataset_reference_is_the_last_resort_never_a_default":
    ## A dataset stamped by RV-6 carries the session that collected it, which
    ## is a recorded fact rather than a guess — so it answers when nothing
    ## else does, and loses to both the flag and the environment when they
    ## speak.
    let stamped = ReviewSessionRefSpec(sessionId: "session-from-dataset",
      taskId: "task-from-dataset", workspacePath: "/dataset/workspace")
    let fromDataset = resolveAgentIdentity(AgentIdentityFlags(), emptyEnv,
      stamped, cwd = "/cwd")
    check fromDataset.error.len == 0
    check fromDataset.identity.sessionId == "session-from-dataset"
    check fromDataset.identity.workspacePath == "/dataset/workspace"

    let fromEnv = resolveAgentIdentity(AgentIdentityFlags(), agentEnv,
      stamped, cwd = "/cwd")
    check fromEnv.identity.sessionId == "agent:acp:rv7"
    check fromEnv.identity.workspacePath == "/work/rv7"

  test "the_workspace_falls_back_to_the_working_directory":
    ## The workspace has a fourth source where the session has none, because a
    ## working directory is observed rather than guessed.  The task is allowed
    ## to stay empty: a session need not belong to one.
    let resolved = resolveAgentIdentity(
      AgentIdentityFlags(session: "flag-session"), emptyEnv,
      ReviewSessionRefSpec(), cwd = "/cwd")
    check resolved.identity.workspacePath == "/cwd"
    check resolved.identity.taskId.len == 0

suite "RV-7 — the command line that is left":

  test "evidence_takes_the_dataset_path_as_its_argument":
    let plan = planAgentCli(@["agent", "evidence", "review.json"])
    check plan.kind == apkEvidence
    check plan.datasetPath == "review.json"
    check plan.identity == AgentIdentityFlags()

  test "the_three_surviving_flags_parse_and_are_the_only_ones":
    let plan = planAgentCli(@["agent", "evidence", "out/review.json",
      "--session", "s", "--task", "t", "--workspace", "/w"])
    check plan.kind == apkEvidence
    check plan.identity.session == "s"
    check plan.identity.task == "t"
    check plan.identity.workspace == "/w"
    let unknown = planAgentCli(@["agent", "evidence", "r.json", "--nope", "x"])
    check unknown.kind == apkError
    check unknown.message.contains("--nope")

  test "every_retired_flag_is_refused_and_names_its_replacement":
    ## Retired, not accepted-and-ignored: an agent that still passes
    ## `--exit-code 0` and is silently obeyed believes it asserted something.
    ## The workspace convention (`reprobuild-specs/Retired-Names.md`) is to
    ## fail and say what replaced it.
    check RetiredEvidenceFlags.len == 9
    for (flag, replacement) in RetiredEvidenceFlags:
      let plan = planAgentCli(@["agent", "evidence", "review.json", flag, "v"])
      checkpoint(flag)
      check plan.kind == apkError
      check plan.message.contains(flag)
      check plan.message.contains(replacement)
      # and the diagnostic shows the pair that replaced the whole flag set
      check plan.message.contains("ct review collect")
      check plan.message.contains("ct agent evidence review.json")

  test "evidence_without_a_dataset_says_how_to_produce_one":
    let plan = planAgentCli(@["agent", "evidence"])
    check plan.kind == apkError
    check plan.message.contains("ct review collect")
    check plan.message.contains("ct agent evidence review.json")

  test "the_group_is_intercepted_before_confutils_sees_argv":
    ## `src/ct/codetracer.nim` must keep routing `ct agent …` ahead of the
    ## parser: confutils rejects any dash-prefixed token it does not itself
    ## declare, so `--session` would be answered with "Unrecognized option"
    ## if the interception were dropped.  Asserted at the source because the
    ## wiring only exists in a linked `ct`; the shipped binary's half of it is
    ## `src/tests/cli/agent_cli_test.nim`.
    check agentNeedsRawDispatch(@["agent", "evidence", "review.json"])
    check not agentNeedsRawDispatch(@["review", "collect"])
    check CodetracerSource.contains("dispatchAgentEvidenceCli(args)")

suite "RV-7 — the notification is read out of the dataset":

  test "a_real_collector_dataset_produces_ready_evidence":
    let identity = AgentIdentity(sessionId: "agent:acp:rv7",
      workspacePath: "/work/rv7")
    let notification = notificationFromDataset(
      parseJson(MaterializedFixture), "/out/review.json", identity, "now")
    check notification.status == aesReady
    check notification.datasetPath == "/out/review.json"
    check notification.sessionId == "agent:acp:rv7"
    check notification.tabId == "agent:acp:rv7"
    # Every descriptive field comes from the file, which is why the flags that
    # used to assert them could be retired.
    check notification.testName == "run-1"
    check notification.files.len == 1
    check notification.files[0].path == "src/main.nr"
    check notification.files[0].linesAdded == 3
    check notification.files[0].linesRemoved == 2
    check notification.files[0].diff.contains(
      "+        sum = sum + contribution;")
    check notification.files[0].diff.contains("-        sum = sum + x;")
    # Nothing an agent could have asserted survives as an assertion.
    check notification.testCommand.len == 0
    check notification.exitCode == 0

  test "the_native_collector_shape_is_read_the_same_way":
    let notification = notificationFromDataset(
      parseJson(NativeShapedFixture), "/out/review.json",
      AgentIdentity(sessionId: "s"), "now")
    check notification.status == aesReady
    check notification.testName == "latest passing run"
    check notification.files.len == 3
    check notification.files[0].path == "src/main.rs"
    check notification.files[1].path == "src/utils.rs"
    check notification.files[1].status == "A"
    # A deletion is a changed file like any other, and must not be dropped on
    # the way into the evidence — a review that silently omitted deleted files
    # would show a reviewer a smaller change than the one that was made.
    check notification.files[2].path == "src/config.rs"
    check notification.files[2].status == "D"

  test "the_rendered_diff_is_a_unified_diff_every_consumer_can_parse":
    ## Collectors write the marker on added/removed content and none on
    ## context, so the marker is added only where it is missing — and context
    ## is always prefixed, because an unprefixed context line beginning with
    ## `-` is re-read as a deletion by `AgenticSessionVM.diffRows` and by
    ## `patch(1)` alike.
    check unifiedDiffLine("added", "+x") == "+x"
    check unifiedDiffLine("added", "x") == "+x"
    check unifiedDiffLine("removed", "-x") == "-x"
    check unifiedDiffLine("removed", "x") == "-x"
    check unifiedDiffLine("context", "- a list item") == " - a list item"
    let notification = notificationFromDataset(
      parseJson(MaterializedFixture), "/out/review.json",
      AgentIdentity(sessionId: "s"), "now")
    let lines = notification.files[0].diff.splitLines()
    check lines[0].startsWith("@@ -6,7 +6,8 @@")
    check lines[1] == " fn main(x: Field) {"
    check not notification.files[0].diff.contains("++")
    check not notification.files[0].diff.contains("--")

  test "a_dataset_with_no_recordings_is_reported_as_such":
    var dataset = parseJson(MaterializedFixture)
    dataset["traceContexts"] = newJArray()
    dataset["recordingCount"] = %0
    let notification = notificationFromDataset(dataset, "/out/review.json",
      AgentIdentity(sessionId: "s"), "now")
    check notification.status == aesNoRecording
    check notification.statusMessage.contains("/out/review.json")

  test "a_dataset_with_recordings_but_no_diff_is_reported_as_such":
    var dataset = parseJson(MaterializedFixture)
    dataset["files"] = newJArray()
    let notification = notificationFromDataset(dataset, "/out/review.json",
      AgentIdentity(sessionId: "s"), "now")
    check notification.status == aesDiffTraceMismatch

  test "something_that_is_not_a_dataset_is_reported_as_such":
    for node in [newJNull(), parseJson("[1, 2, 3]"), parseJson("\"text\"")]:
      let notification = notificationFromDataset(node, "/out/review.json",
        AgentIdentity(sessionId: "s"), "now")
      check notification.status == aesMalformedMetadata
      check notification.statusMessage.contains("/out/review.json")

  test "a_json_object_that_is_missing_the_datasets_arrays_is_still_read":
    ## The argument of `ct agent evidence` is whatever file an agent pointed
    ## at, so every array this reads may simply be absent — and `JsonNode`'s
    ## `items` dereferences its argument, which turned each of these into a
    ## SIGSEGV rather than into the status the table above promises.  A
    ## crashed command reports nothing to anyone: not the agent, not the GUI,
    ## and not the lane, since a signal death carries no status at all.
    ##
    ## Each shape omits one array the reader walks: the whole document
    ## (`{}`), the changeset, the recordings, a file's hunks, a hunk's lines.
    ## The last is separated because it is the one that still reads as a
    ## reviewable dataset — see below.
    for document in ["{}",
        """{"recordingCount": 1, "traceContexts": [{"recordingId": "r"}]}""",
        """{"recordingCount": 1, "files": []}""",
        """{"recordingCount": 1, "traceContexts": [],
            "files": [{"path": "a", "diff": {"status": "M"}}]}"""]:
      checkpoint(document)
      let notification = notificationFromDataset(parseJson(document),
        "/out/review.json", AgentIdentity(sessionId: "s"), "now")
      # It reports one of the "this is not reviewable" statuses rather than
      # crashing; which one depends on which half the document is missing,
      # and both are asserted case by case above.
      check notification.status != aesReady
      check notification.statusMessage.contains("/out/review.json")

    # A hunk with no `lines` renders as a bare `@@` header, which is a
    # non-empty diff by the rule `notificationFromDataset` applies — so this
    # shape reads as `ready`.  Asserted as it is rather than as one might
    # prefer it: no collector emits an empty hunk, and the bug this case
    # exists for was the dereference, not the status.
    let emptyHunk = notificationFromDataset(parseJson(
      """{"recordingCount": 1, "traceContexts": [],
          "files": [{"path": "a", "diff":
            {"status": "M", "hunks": [{"oldStart": 1}]}}]}"""),
      "/out/review.json", AgentIdentity(sessionId: "s"), "now")
    check emptyHunk.datasetPath == "/out/review.json"
    check emptyHunk.files.len == 1
    check emptyHunk.files[0].diff == "@@ -1,0 +0,0 @@\n"

  test "a_session_reference_without_agent_args_is_read_not_dereferenced":
    ## RV-7 makes the dataset's stamped session a third source of identity, so
    ## `reviewSessionRefFromJson` now runs over a file an agent supplied
    ## rather than only over one CodeTracer wrote.  `toJson` always writes
    ## `agentArgs`; a hand-edited dataset, an older writer or another tool
    ## need not, and reading that must yield the reference rather than crash.
    let spec = reviewSessionRefFromJson(parseJson(
      """{"sessionId": "ds-session", "taskId": "ds-task"}"""))
    check spec.sessionId == "ds-session"
    check spec.taskId == "ds-task"
    check spec.agentArgs.len == 0

suite "RV-7 — the end-of-turn hook runs the same two commands":

  test "the_hook_builds_an_ordinary_ct_review_collect_line":
    let hook = applyHookEnvDefaults(
      HookCollectOptions(diff: "main..HEAD"), emptyEnv)
    let collect = hookCollectArgs(hook, "/work/rv7")
    check collect.error.len == 0
    check collect.args == @["review", "collect", "--repo", "/work/rv7",
      "--diff", "main..HEAD", "--recordings", DefaultHookRecordingsDir,
      "--output", DefaultHookOutputDir]

  test "a_project_configures_the_hook_from_flags_or_the_environment":
    let fromFlags = applyHookEnvDefaults(HookCollectOptions(
      repo: "/repo", diff: "base..HEAD", recordings: "runs", output: "out",
      preset: "minimal", progress: true), emptyEnv)
    check hookCollectArgs(fromFlags, "/ignored").args == @["review", "collect",
      "--repo", "/repo", "--diff", "base..HEAD", "--recordings", "runs",
      "--output", "out", "--preset", "minimal", "--progress"]

    let fromEnv = applyHookEnvDefaults(HookCollectOptions(), envOf({
      ReviewRepoEnvVar: "/repo", ReviewDiffEnvVar: "base..HEAD",
      ReviewRecordingsEnvVar: "runs", ReviewOutputEnvVar: "out"}))
    check hookCollectArgs(fromEnv, "/ignored").args == @["review", "collect",
      "--repo", "/repo", "--diff", "base..HEAD", "--recordings", "runs",
      "--output", "out"]

  test "a_hook_with_no_diff_says_what_to_configure":
    let hook = applyHookEnvDefaults(HookCollectOptions(), emptyEnv)
    let collect = hookCollectArgs(hook, "/work/rv7")
    check collect.args.len == 0
    check collect.error.contains("--diff")
    check collect.error.contains(ReviewDiffEnvVar)

  test "the_hook_takes_the_identity_flags_too":
    let plan = planAgentCli(@["agent", "end-of-turn", "--diff", "main..HEAD",
      "--session", "s", "--workspace", "/w"])
    check plan.kind == apkEndOfTurn
    check plan.hook.diff == "main..HEAD"
    check plan.hookIdentity.session == "s"
    check plan.hookIdentity.workspace == "/w"

  test "the_hook_refuses_the_retired_flags_as_well":
    let plan = planAgentCli(@["agent", "end-of-turn", "--exit-code", "0"])
    check plan.kind == apkError
    check plan.message.contains("--exit-code")
