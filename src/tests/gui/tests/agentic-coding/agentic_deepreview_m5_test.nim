## Headless integration tests for M5 agent evidence command and DeepReview handoff.

import std/[json, os, osproc, sequtils, strutils, times, unittest]

import isonim/core/[owner, signals]
import nim_acp
import nim_agents

import agent_evidence
import agent_service
import backend/mock_backend
import store/[replay_data_store, types]
import viewmodels/[agent_activity_vm, agent_workspace_vm, agentic_session_vm,
  deepreview_vm, editor_vm, vcs_vm]

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

proc evidenceArgs(f: M5Fixture; extra: seq[string] = @[]): seq[string] =
  @[
    "--session", "agent:acp:m5",
    "--tab", "agent:acp:m5",
    "--workspace", f.worktree,
    "--trace-id", "trace-m5-001",
    "--trace-path", f.worktree / ".codetracer" / "trace-m5-001",
    "--test-name", "m5 integration test",
    "--test-command", "nim test",
    "--exit-code", "0"
  ] & extra

proc captureSender(target: EvidenceCapture):
    AgentEvidenceRpcSender =
  proc(notification: AgentEvidenceNotification) {.gcsafe.} =
    target.notifications.add notification

proc buildAgentEvidenceCliWrapper(): string =
  let root = getCurrentDir()
  let wrapperDir = getTempDir() / ("codetracer-agent-evidence-cli-" &
    $getCurrentProcessId() & "-" & $epochTime().int)
  createDir(wrapperDir)
  let wrapperPath = wrapperDir / "agent_evidence_cli_wrapper.nim"
  result = wrapperDir / "agent_evidence_cli_wrapper"
  writeFile(wrapperPath, """
import std/os
import agent_evidence

quit(runAgentEvidenceCli(commandLineParams()))
""")
  let command = [
    "nim", "c", "--hints:off", "--warnings:off",
    "--path:" & shellQuote(root / "src" / "frontend" / "viewmodel"),
    "-o:" & shellQuote(result),
    shellQuote(wrapperPath)
  ].join(" ")
  sh(root, command)

proc runAgentEvidenceCli(f: M5Fixture; rpcPath: string): tuple[output: string;
    exitCode: int] =
  let cli = buildAgentEvidenceCliWrapper()
  putEnv("CODETRACER_AGENT_EVIDENCE_RPC_PATH", rpcPath)
  let command = cli.shellQuote() & " agent evidence " &
    f.evidenceArgs().mapIt(it.shellQuote()).join(" ")
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

      let notification = executeAgentEvidenceCommand(
        f.evidenceArgs(), cwd = f.worktree, sendRpc = captureSender(f.captured))
      f.service.registerAgentEvidence(notification)

      let state = f.store.agentSessions.val
      let session = state.sessions[0]
      check f.captured.notifications.len == 1
      check f.captured.notifications[0].status == aesReady
      check session.evidence.state == asesReady
      check session.evidence.traceId == "trace-m5-001"
      check session.evidence.workspacePath == f.worktree
      check session.evidence.testName == "m5 integration test"
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
      check f.vcs.unifiedDiffActive.val
      check f.vcs.diffFiles.val[0].path == f.vcs.changedFiles.val[0].path
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

  test "test_agentic_deepreview_handoff_error_states":
    createRoot proc(dispose: proc()) =
      var f = makeFixture()
      defer:
        f.cleanup()
        dispose()

      let missingRecording = executeAgentEvidenceCommand(
        f.evidenceArgs(@["--trace-id", "", "--trace-path", ""]),
        cwd = f.worktree,
        sendRpc = captureSender(f.captured))
      check not f.vm.handleAgentEvidenceNotification(missingRecording)
      check not f.vcs.deepReviewMode.val
      check not f.deepReview.hasData.val
      check f.store.agentSessions.val.sessions[0].evidence.state ==
        asesNoRecording

      let failedTest = executeAgentEvidenceCommand(
        f.evidenceArgs(@["--exit-code", "7"]), cwd = f.worktree,
        sendRpc = captureSender(f.captured))
      check not f.vm.handleAgentEvidenceNotification(failedTest)
      check f.store.agentSessions.val.sessions[0].evidence.state ==
        asesFailedTests

      let metadataPath = f.worktree / "broken-evidence.json"
      writeFile(metadataPath, "{not-json")
      let malformed = executeAgentEvidenceCommand(
        f.evidenceArgs(@["--metadata", metadataPath]), cwd = f.worktree,
        sendRpc = captureSender(f.captured))
      check not f.vm.handleAgentEvidenceNotification(malformed)
      check f.store.agentSessions.val.sessions[0].evidence.state ==
        asesMalformedMetadata

      sh(f.worktree, "git checkout -- src/feature.nim")
      let mismatch = executeAgentEvidenceCommand(
        f.evidenceArgs(), cwd = f.worktree, sendRpc = captureSender(f.captured))
      check not f.vm.handleAgentEvidenceNotification(mismatch)
      check f.store.agentSessions.val.sessions[0].evidence.state ==
        asesDiffTraceMismatch
      check f.activity.messages.val.anyIt(it.content.contains("error"))
