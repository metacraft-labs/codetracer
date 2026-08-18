## Headless integration tests for M5 agent evidence command and DeepReview handoff.
##
## RV-7 changed what the command is given, not what CodeTracer does with the
## result: `ct agent evidence` now takes the **review dataset**
## (`ct review collect`'s output) and reads the session from the environment,
## instead of taking a dozen flags that asserted the same facts.  So the
## fixture below produces a dataset where it used to assemble a flag vector,
## and every assertion downstream of the notification is unchanged — which is
## the point: the handoff into DeepReview is the same handoff.

import std/[json, os, osproc, sequtils, strutils, times, unittest]

import isonim/core/[computation, owner, signals]
import nim_acp
import nim_agents

import ../../../../ct/agent_cli
import agent_service
import backend/mock_backend
import store/[replay_data_store, types]
import viewmodels/[agent_activity_deepreview_vm, agent_activity_vm,
  agent_workspace_vm, agentic_session_vm, deepreview_vm, editor_vm,
  review_entry, vcs_vm]
import ../deepreview/lib/review_dataset_fixture

type
  M5Fixture = object
    store: ReplayDataStore
    service: CodeTracerAgentService
    vm: AgenticSessionVM
    activity: AgentActivityVM
    workspace: AgentWorkspaceVM
    vcs: VCSVM
    deepReview: DeepReviewVM
    worktree: string
    captured: EvidenceCapture

  EvidenceCapture = ref object
    notifications: seq[AgentEvidenceNotification]

proc sh(cwd: string; command: string) =
  let (output, code) = execCmdEx(command, workingDir = cwd)
  doAssert code == 0, command & "\n" & output

proc shellQuote(value: string): string =
  "'" & value.replace("'", "'\\''") & "'"

proc makeWorktree(): string =
  result = getTempDir() / ("codetracer-agentic-m5-" & $getCurrentProcessId() &
    "-" & $epochTime().int)
  createDir(result)
  sh(result, "git init")
  sh(result, "git config user.email m5@example.invalid")
  sh(result, "git config user.name 'M5 Test'")
  createDir(result / "src")
  writeFile(result / "src" / "feature.nim", "proc answer(): int = 1\n")
  sh(result, "git add src/feature.nim")
  sh(result, "git commit -m initial")
  writeFile(result / "src" / "feature.nim", "proc answer(): int = 42\n")

proc makeStore(): ReplayDataStore =
  let mock = newMockBackendService()
  createReplayDataStore(mock.toBackendService())

proc makeService(store: ReplayDataStore; worktree: string):
    CodeTracerAgentService =
  let acpTransport = newFakeAcpTransport(@[
    promptTurn(@[
      %*{"sessionUpdate": "workspace", "workspacePath": worktree,
          "workingCopyMode": "git_worktree"},
      %*{"sessionUpdate": "diff", "path": "src/feature.nim",
          "lines_added": 1, "lines_removed": 1,
          "diff": "@@ -1 +1 @@\n-proc answer(): int = 1\n+proc answer(): int = 42\n"},
      statusUpdate("completed")
    ])
  ])
  var acpClient = newAcpClient(acpTransport)
  newCodeTracerAgentService(store, fromAcp(acpClient))

proc launchConfig(worktree: string): CodeTracerAgentLaunchConfig =
  CodeTracerAgentLaunchConfig(
    backend: ctabAcp,
    cwd: worktree,
    taskTitle: "M5 feature",
    instructions: "Implement the M5 feature.",
    acpBinary: "codex-acp",
    model: "test-model",
    sessionKey: "m5")

proc makeFixture(): M5Fixture =
  result.worktree = makeWorktree()
  result.store = makeStore()
  result.service = makeService(result.store, result.worktree)
  result.activity = createAgentActivityVM(result.store)
  result.workspace = createAgentWorkspaceVM(result.store)
  result.vcs = createVCSVM()
  result.deepReview = createDeepReviewVM(result.store)
  result.captured = EvidenceCapture()
  let editor = createEditorVM(result.store)
  result.vm = createAgenticSessionVM(result.store, result.service, editor,
    result.activity, result.workspace, result.vcs, result.deepReview)
  discard result.service.startAgentSession(launchConfig(result.worktree))
  result.vm.activateAgentTab("agent:acp:m5")

proc m5Dataset(f: M5Fixture; recordings: seq[FixtureRecording] = @[
    fixtureRecording("trace-m5-001", "m5 integration test")];
    files: seq[FixtureFile] = @[
      fixtureFile("src/feature.nim", @[
        hunkLine("removed", "-proc answer(): int = 1"),
        hunkLine("added", "+proc answer(): int = 42")])]): string =
  ## The review dataset the agent hands over — `ct review collect`'s output,
  ## which after RV-7 is the whole argument of `ct agent evidence`.
  writeReviewDataset(f.worktree / ".ct" / "review" / "review.json",
    files, recordings, sessionTitle = "M5 feature")

proc evidenceArgs(f: M5Fixture; dataset: string): seq[string] =
  ## The three flags RV-7 leaves.  They are passed rather than exported
  ## because this process is not itself an agent session — which is the case
  ## §4.4 keeps them for: "use outside a managed session and in tests".
  @[dataset, "--session", "agent:acp:m5", "--workspace", f.worktree]

proc captureSender(target: EvidenceCapture):
    AgentEvidenceRpcSender =
  proc(notification: AgentEvidenceNotification) {.gcsafe.} =
    target.notifications.add notification

proc buildAgentEvidenceCliWrapper(): string =
  ## Compile the checked-in `ct agent …` entry point
  ## (`agent_cli_wrapper.nim`).  It lives in the tree rather than being
  ## generated into a temp directory because `src/ct/agent_cli.nim` reaches
  ## `nim-agents` through `config.nims`, which Nim reads from the compiled
  ## file's own project directory.
  let root = getCurrentDir()
  let outDir = getTempDir() / ("codetracer-agent-cli-" &
    $getCurrentProcessId() & "-" & $epochTime().int)
  createDir(outDir)
  result = outDir / "agent_cli_wrapper"
  let command = [
    "nim", "c", "--hints:off", "--warnings:off",
    "-o:" & shellQuote(result),
    shellQuote(root / "src" / "tests" / "gui" / "tests" / "agentic-coding" /
      "agent_cli_wrapper.nim")
  ].join(" ")
  sh(root, command)

proc emptyEnv(name: string): string = ""
  ## The suites drive the identity through flags, so the ambient environment
  ## must not reach the resolution — a developer running the suite inside an
  ## agent session would otherwise get that session's id instead of `m5`'s.

proc runEvidence(f: M5Fixture; dataset: string): AgentEvidenceNotification =
  ## `ct agent evidence <dataset>`, in process, returning what it sent.
  let outcome = runAgentEvidence(dataset,
    AgentIdentityFlags(session: "agent:acp:m5", workspace: f.worktree),
    cwd = f.worktree, sendRpc = captureSender(f.captured),
    lookup = emptyEnv)
  doAssert outcome.output.len > 0, outcome.errorOutput
  evidenceNotificationFromJson(parseJson(outcome.output))

proc runAgentEvidenceCli(f: M5Fixture; rpcPath: string): tuple[output: string;
    exitCode: int] =
  let cli = buildAgentEvidenceCliWrapper()
  putEnv("CODETRACER_AGENT_EVIDENCE_RPC_PATH", rpcPath)
  let command = cli.shellQuote() & " agent evidence " &
    f.evidenceArgs(f.m5Dataset()).mapIt(it.shellQuote()).join(" ")
  execCmdEx(command, workingDir = f.worktree)

proc cleanup(f: M5Fixture) =
  if f.worktree.len > 0 and dirExists(f.worktree):
    removeDir(f.worktree)

suite "agentic coding M5 evidence handoff":

  test "test_agentic_ct_recording_command_registers_trace_and_diff":
    createRoot proc(dispose: proc()) =
      var f = makeFixture()
      defer:
        f.cleanup()
        dispose()

      let dataset = f.m5Dataset()
      let notification = f.runEvidence(dataset)
      f.service.registerAgentEvidence(notification)

      let state = f.store.agentSessions.val
      let session = state.sessions[0]
      check f.captured.notifications.len == 1
      check f.captured.notifications[0].status == aesReady
      check session.evidence.state == asesReady
      check session.evidence.traceId == "trace-m5-001"
      check session.evidence.workspacePath == f.worktree
      check session.evidence.testName == "m5 integration test"
      # RV-7: the session now also remembers the dataset it was handed, so a
      # review can be re-opened on the collector's own output rather than on
      # the summary projected out of it.
      check session.evidence.datasetPath == dataset
      check session.evidence.files.len == 1
      check session.evidence.files[0].path == "src/feature.nim"
      check session.evidence.files[0].diff.contains(
        "+proc answer(): int = 42")

  test "test_agentic_deepreview_handoff_from_recorded_test":
    createRoot proc(dispose: proc()) =
      var f = makeFixture()
      defer:
        delEnv("CODETRACER_AGENT_EVIDENCE_RPC_PATH")
        f.cleanup()
        dispose()

      let rpcPath = f.worktree / ".codetracer" / "agent-evidence-rpc.json"
      let (output, code) = runAgentEvidenceCli(f, rpcPath)
      check code == 0
      let notification = evidenceNotificationFromJson(parseJson(output))
      let promoted = f.vm.handleAgentEvidenceRpcFile(rpcPath)

      check notification.status == aesReady
      check fileExists(rpcPath)
      check promoted
      check f.vcs.deepReviewMode.val
      check f.vcs.changedFiles.val.len == 1
      check f.vcs.changedFiles.val[0].path == "src/feature.nim"
      # DR-R7: these two are what the review's Monaco diff tabs are built
      # from.  `ui/agentic_session_launcher.deepReviewData` turns each row of
      # `diffFiles` into that file's `DeepReviewFileDiff.hunks`, so a
      # changeset of several files gets several diffs instead of the active
      # editor's text repeated for every one.
      check f.vcs.unifiedDiffActive.val
      check f.vcs.diffFiles.val[0].path == f.vcs.changedFiles.val[0].path
      check f.vcs.diffFiles.val[0].hunks[0].lines.anyIt(
        it.content.contains("42"))
      check f.deepReview.hasData.val
      check f.deepReview.viewMode.val == drpvmUnified
      check f.deepReview.files.val.len == f.vcs.changedFiles.val.len
      check f.deepReview.files.val[0].path == "src/feature.nim"
      check f.deepReview.unifiedFiles.val.len == 1
      check f.deepReview.unifiedFiles.val[0].path == "src/feature.nim"
      check f.deepReview.traceContexts.val[0].label == "m5 integration test"
      f.deepReview.setViewMode(drpvmFullFiles)
      check f.deepReview.files.val.mapIt(it.path) ==
        f.deepReview.unifiedFiles.val.mapIt(it.path)
      check f.activity.messages.val.anyIt(it.content.contains("DeepReview"))

  test "test_agentic_handoff_needs_no_deepreview_component":
    ## DR-R7.  The M5 handoff must reach full review state with no standalone
    ## DeepReview panel involved.
    ##
    ## `DeepReview-GUI.md` §7: "There is no separate 'DeepReview mode' that
    ## replaces the UI" — a review is the Editor, the VCS panel and the Agent
    ## Activity panel.  Until DR-R7 the handoff ended by dereferencing
    ## `data.ui.componentMapping[Content.DeepReview][DeepReviewId]` and
    ## configuring that component's view mode, selected file, trace context,
    ## execution index and iteration; it would have failed outright without
    ## one, and its trace-context id was set *there* rather than on the
    ## review, so the two surfaces could disagree.
    ##
    ## Two halves, because the handoff spans two layers:
    ##   * the ViewModel layer reaches the whole review state — this test;
    ##   * the launcher constructs no component — the source contract below,
    ##     since the launcher itself needs Electron to run.
    createRoot proc(dispose: proc()) =
      var f = makeFixture()
      defer:
        delEnv("CODETRACER_AGENT_EVIDENCE_RPC_PATH")
        f.cleanup()
        dispose()

      let rpcPath = f.worktree / ".codetracer" / "agent-evidence-rpc.json"
      let (_, code) = runAgentEvidenceCli(f, rpcPath)
      check code == 0
      check f.vm.handleAgentEvidenceRpcFile(rpcPath)

      # The review dataset the launcher publishes, from the same projection it
      # builds its `DeepReviewData` with.
      let dataset = f.vm.agenticReviewDataset()
      check dataset.title.contains("DeepReview")
      check dataset.files.len == 1
      check dataset.files[0].path == "src/feature.nim"
      check dataset.traceContexts.len == 1
      check dataset.traceContexts[0].label == "m5 integration test"

      # …and the per-file half of that same review — what the launcher turns
      # into each `DeepReviewFileData`, and therefore what the file's Monaco
      # diff tab renders.  The diff here came out of a real `ct agent evidence`
      # run over a real git worktree, so this is the whole chain: recorded
      # change -> evidence -> `vcs.diffFiles` -> the review's own diff.
      #
      # This changeset has one file, so it cannot distinguish "each file's own
      # diff" from "the first file's diff for everyone" — the multi-file case
      # is `test_every_review_file_gets_its_own_diff` in
      # `src/tests/gui/tests/deepreview/deepreview_entry_test.nim`.
      let fileDiffs = f.vm.agenticReviewFileDiffs(dataset)
      check fileDiffs.len == 1
      check fileDiffs[0].path == "src/feature.nim"
      check fileDiffs[0].status == dataset.files[0].status
      check fileDiffs[0].hunks.len == 1
      check fileDiffs[0].hunks[0].lines.anyIt(
        it.kind == "added" and it.content.contains("42"))
      check fileDiffs[0].hunks[0].lines.anyIt(
        it.kind == "removed" and it.content.contains("= 1"))
      # The kinds are the ones `DeepReviewHunkLine.type` is documented to
      # carry; the `VCSDiffLineRow` spellings ("add"/"delete"/"hunk") must not
      # leak into the review.
      check fileDiffs[0].hunks[0].lines.allIt(
        it.kind in ["context", "added", "removed"])

      # …fed to the one review-entry routine, on the panels a review actually
      # uses.  Nothing here can even name a `DeepReviewComponent`: this is the
      # ViewModel layer.
      let activity = createAgentActivityDeepReviewVM(f.store)
      let panel = createVCSVM()
      var documents: seq[string] = @[]
      var focusCalls = 0
      discard enterReview(
        panel, activity, dataset,
        proc(action: VCSOpenAction) = documents.add(action.documentKey),
        proc() = focusCalls += 1)

      # §7 step 1 — the VCS panel carries the changeset and the review's run.
      check panel.deepReviewMode.val
      check panel.changedFiles.val.len == 1
      check panel.changedFiles.val[0].path == "src/feature.nim"
      check panel.changedFiles.val[0].selected
      check panel.statsText.val.len > 0
      check panel.traceContexts.val[0].label == "m5 integration test"
      check panel.currentTraceContextId() == panel.traceContexts.val[0].id
      # §7 step 2 — the first modified file opens, and the panels are focused.
      check documents == @["diff:file:src/feature.nim"]
      check focusCalls == 1
      # §7 step 4 / §2.1 — the Agent Activity panel's DeepReview section, for
      # a session that reported no coverage: populated and honest, not blank.
      check activity.reviewActive.val
      check activity.sectionVisible.val
      check activity.fileCoverage.val.len == 1
      check activity.fileCoverage.val[0].path == "src/feature.nim"
      check activity.selectedFilePath.val == "src/feature.nim"
      check not activity.testResultsAvailable.val

  test "the M5 handoff constructs no DeepReview panel (source contract)":
    ## The other half: `ui/agentic_session_launcher.nim` runs inside Electron,
    ## so what it *does* can only be asserted by reading it.  Same pattern as
    ## `src/tests/gui/tests/layout/deepreview_layout_test.nim`'s source
    ## contract, and as the DR-R7 suite in
    ## `src/tests/gui/tests/deepreview/deepreview_entry_test.nim`.
    let launcher = readFile("src/frontend/ui/agentic_session_launcher.nim")
    check not launcher.contains("DeepReviewComponent")
    check not launcher.contains("ensurePanel(Content.DeepReview")
    check not launcher.contains("requestDeepReviewPanelRefresh")
    check launcher.contains("vcs.startDeepReviewNavigation(data)")

  test "test_agentic_deepreview_handoff_error_states":
    createRoot proc(dispose: proc()) =
      var f = makeFixture()
      defer:
        f.cleanup()
        dispose()

      # RV-7 moved the triggers of these four states from flags the agent
      # asserted onto the dataset itself, which is the milestone's point: the
      # states are unchanged, and each is now a property of the file the
      # reviewer will open rather than of a claim on a command line.

      # No recordings collected — nothing to review WITH.
      let missingRecording = f.runEvidence(f.m5Dataset(recordings = @[]))
      check not f.vm.handleAgentEvidenceNotification(missingRecording)
      check not f.vcs.deepReviewMode.val
      check not f.deepReview.hasData.val
      check f.store.agentSessions.val.sessions[0].evidence.state ==
        asesNoRecording

      # A failing test run.  `--exit-code` is retired — an agent handing over
      # evidence for a red suite is told to say what failed instead
      # (`docs/agent-prompt/deepreview-evidence.md`) — but the state itself
      # stays on the RPC wire for producers other than this CLI, and the
      # ViewModel's handling of it is what this case guards.
      var failedTest = f.runEvidence(f.m5Dataset())
      failedTest.status = aesFailedTests
      failedTest.statusMessage = "recorded test command failed"
      check not f.vm.handleAgentEvidenceNotification(failedTest)
      check f.store.agentSessions.val.sessions[0].evidence.state ==
        asesFailedTests

      # A dataset that is not one.
      let brokenDataset = f.worktree / ".ct" / "broken" / "review.json"
      createDir(brokenDataset.parentDir)
      writeFile(brokenDataset, "{not-json")
      let malformed = f.runEvidence(brokenDataset)
      check not f.vm.handleAgentEvidenceNotification(malformed)
      check f.store.agentSessions.val.sessions[0].evidence.state ==
        asesMalformedMetadata

      # Recordings, but nothing changed alongside them — nothing to review.
      let mismatch = f.runEvidence(f.m5Dataset(files = @[]))
      check not f.vm.handleAgentEvidenceNotification(mismatch)
      check f.store.agentSessions.val.sessions[0].evidence.state ==
        asesDiffTraceMismatch
      check f.activity.messages.val.anyIt(it.content.contains("error"))
