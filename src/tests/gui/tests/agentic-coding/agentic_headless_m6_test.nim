## M6 headless integration gate for the CodeTracer agentic workflow.
##
## This test intentionally stays out of Electron/Playwright. Agent Harbor's
## real server/scenario/llm-api-proxy contract is exercised by the Agent Harbor
## E2E tests that the just target invokes; this file verifies that the same REST
## client boundary drives real CodeTracer ViewModels into DeepReview.

import std/[json, os, osproc, sequtils, strutils, times, unittest]

import isonim/core/[computation, owner, signals]
import nim_agent_harbor
import nim_agents
import nim_everywhere

import agent_evidence
import agent_service
import backend/mock_backend
import store/[replay_data_store, types]
import viewmodels/[agent_activity_vm, agent_workspace_vm, agentic_session_vm,
  deepreview_vm, editor_vm, vcs_vm]

type
  HarborScenarioFixture = ref object
    requests: seq[HttpRequest]
    worktree: string

  M6Fixture = object
    store: ReplayDataStore
    service: CodeTracerAgentService
    vm: AgenticSessionVM
    activity: AgentActivityVM
    workspace: AgentWorkspaceVM
    vcs: VCSVM
    deepReview: DeepReviewVM
    harbor: HarborScenarioFixture
    worktree: string

proc sh(cwd: string; command: string) =
  let (output, code) = execCmdEx(command, workingDir = cwd)
  doAssert code == 0, command & "\n" & output

proc shellQuote(value: string): string =
  "'" & value.replace("'", "'\\''") & "'"

proc makeWorktree(): string =
  result = getTempDir() / ("codetracer-agentic-m6-" & $getCurrentProcessId() &
    "-" & $epochTime().int)
  createDir(result)
  sh(result, "git init")
  sh(result, "git config user.email m6@example.invalid")
  sh(result, "git config user.name 'M6 Test'")
  createDir(result / "src")
  writeFile(result / "src" / "feature.nim", "proc answer(): int = 1\n")
  sh(result, "git add src/feature.nim")
  sh(result, "git commit -m initial")
  writeFile(result / "src" / "feature.nim", "proc answer(): int = 42\n")
  writeFile(result / "feature-note.txt", "M6 scenario evidence\n")

proc makeStore(): ReplayDataStore =
  let mock = newMockBackendService()
  createReplayDataStore(mock.toBackendService())

proc harborTransport(fixture: HarborScenarioFixture): HttpTransport =
  proc(req: HttpRequest): HttpResponse =
    fixture.requests.add req
    if req.httpMethod == hmPost and req.url.endsWith("/api/v1/tasks"):
      return HttpResponse(status: 201, body: $(%*{
        "task_id": "task-codetracer-m6",
        "session_ids": ["session-codetracer-m6"],
        "status": "queued",
        "links": {
          "self": "/api/v1/sessions/session-codetracer-m6",
          "events": "/api/v1/sessions/session-codetracer-m6/events",
          "logs": "/api/v1/sessions/session-codetracer-m6/logs"
        }
      }))
    if req.httpMethod == hmGet and req.url.contains(
        "/api/v1/sessions/session-codetracer-m6/events"):
      return HttpResponse(status: 200, body:
        "event: message\n" &
        "data: {\"type\":\"workspace\",\"status\":\"ready\",\"mountPath\":\"" &
        fixture.worktree.replace("\\", "\\\\") &
        "\",\"workingCopyMode\":\"git_worktree\",\"timestamp\":1}\n\n" &
        "event: message\n" &
        "data: {\"type\":\"plan\",\"entries\":[\"edit\",\"test\",\"ct evidence\"],\"timestamp\":2}\n\n" &
        "event: message\n" &
        "data: {\"type\":\"tool_use\",\"tool_name\":\"bash\",\"tool_execution_id\":\"tool-tests\",\"status\":\"started\",\"message\":\"nim test && ct agent evidence\",\"timestamp\":3}\n\n" &
        "event: message\n" &
        "data: {\"type\":\"diff\",\"file_path\":\"src/feature.nim\",\"lines_added\":1,\"lines_removed\":1,\"diff\":\"@@ -1 +1 @@\\n-proc answer(): int = 1\\n+proc answer(): int = 42\\n\",\"timestamp\":4}\n\n" &
        "event: message\n" &
        "data: {\"type\":\"milestone_progress\",\"completed\":1,\"total\":1,\"message\":\"M6 complete\",\"timestamp\":5}\n\n" &
        "event: message\n" &
        "data: {\"type\":\"status\",\"status\":\"completed\",\"message\":\"scenario complete\",\"timestamp\":6}\n\n")
    if req.httpMethod == hmGet and
        req.url.endsWith("/api/v1/sessions/session-codetracer-m6/files"):
      return HttpResponse(status: 200, body: $(%*{
        "items": [
          {"path": "src/feature.nim", "status": "modified",
           "linesAdded": 1, "linesRemoved": 1},
          {"path": "feature-note.txt", "status": "added",
           "linesAdded": 1, "linesRemoved": 0}
        ],
        "total": 2,
        "page": 1,
        "perPage": 50
      }))
    if req.httpMethod == hmGet and req.url.contains(
        "/api/v1/sessions/session-codetracer-m6/files/content/src/feature.nim"):
      return HttpResponse(status: 200,
        headers: @[header("content-type", "text/plain")],
        body: "proc answer(): int = 42\n")
    if req.httpMethod == hmGet and req.url.contains(
        "/api/v1/sessions/session-codetracer-m6/diff/src/feature.nim"):
      return HttpResponse(status: 200, body: $(%*{
        "path": "src/feature.nim",
        "status": "modified",
        "linesAdded": 1,
        "linesRemoved": 1,
        "diff": "@@ -1 +1 @@\n-proc answer(): int = 1\n+proc answer(): int = 42\n"
      }))
    if req.httpMethod == hmGet and req.url.contains(
        "/api/v1/sessions/session-codetracer-m6/diff/feature-note.txt"):
      return HttpResponse(status: 200, body: $(%*{
        "path": "feature-note.txt",
        "status": "added",
        "linesAdded": 1,
        "linesRemoved": 0,
        "diff": "new file mode 100644\n@@ -0,0 +1 @@\n+M6 scenario evidence\n"
      }))
    HttpResponse(status: 404, body: "not found: " & req.url)

proc buildAgentEvidenceCliWrapper(): string =
  let root = getCurrentDir()
  let wrapperDir = getTempDir() / ("codetracer-agent-evidence-m6-cli-" &
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

proc evidenceArgs(f: M6Fixture): seq[string] =
  @[
    "--session", "agent:harbor:m6",
    "--tab", "agent:harbor:m6",
    "--workspace", f.worktree,
    "--trace-id", "trace-m6-001",
    "--trace-path", f.worktree / ".codetracer" / "trace-m6-001",
    "--test-name", "e2e_codetracer_headless_agent_harbor_worktree_deepreview",
    "--test-command", "nim c -r src/tests/gui/tests/agentic-coding/agentic_headless_m6_test.nim",
    "--exit-code", "0"
  ]

proc runAgentEvidenceCli(f: M6Fixture; rpcPath: string):
    tuple[output: string; exitCode: int] =
  let cli = buildAgentEvidenceCliWrapper()
  putEnv("CODETRACER_AGENT_EVIDENCE_RPC_PATH", rpcPath)
  let command = cli.shellQuote() & " agent evidence " &
    f.evidenceArgs().mapIt(it.shellQuote()).join(" ")
  execCmdEx(command, workingDir = f.worktree)

proc launchConfig(worktree: string): CodeTracerAgentLaunchConfig =
  CodeTracerAgentLaunchConfig(
    backend: ctabHarbor,
    cwd: worktree,
    taskTitle: "M6 headless worktree task",
    instructions: "Implement the M6 headless worktree feature.",
    context: @["Scenario format: Agent Harbor acp-client-runs-scenario"],
    acpBinary: "mock-agent-acp",
    acpArgs: @["--scenario",
      "../agent-harbor/tests/scenarios/e2e/codetracer_contract_worktree_file_edges.yaml"],
    model: "llm-api-proxy-scenario",
    tenantId: "tenant-m6",
    projectId: "project-m6",
    repoUrl: "file://" & worktree,
    branch: "main",
    commit: "HEAD",
    executionHostId: "local",
    sessionKey: "m6")

proc makeFixture(): M6Fixture =
  result.worktree = makeWorktree()
  result.harbor = HarborScenarioFixture(worktree: result.worktree)
  result.store = makeStore()
  let harborClient = newHarborClient("http://agent-harbor.invalid",
    harborTransport(result.harbor))
  result.service = newCodeTracerAgentService(result.store,
    fromHarbor(harborClient))
  result.activity = createAgentActivityVM(result.store)
  result.workspace = createAgentWorkspaceVM(result.store)
  result.vcs = createVCSVM()
  result.deepReview = createDeepReviewVM(result.store)
  let editor = createEditorVM(result.store)
  result.vm = createAgenticSessionVM(result.store, result.service, editor,
    result.activity, result.workspace, result.vcs, result.deepReview)

proc cleanup(f: M6Fixture) =
  if f.worktree.len > 0 and dirExists(f.worktree):
    removeDir(f.worktree)

suite "CodeTracer agentic M6 headless integration gate":

  test "e2e_codetracer_headless_agent_harbor_worktree_deepreview":
    createRoot proc(dispose: proc()) =
      var f = makeFixture()
      defer:
        delEnv("CODETRACER_AGENT_EVIDENCE_RPC_PATH")
        f.cleanup()
        dispose()

      let session = f.service.startAgentSession(launchConfig(f.worktree))
      check session.id == "session-codetracer-m6"
      check session.taskId == "task-codetracer-m6"

      let state = f.store.agentSessions.val
      check state.activeTabId == "agent:harbor:m6"
      check state.sessions.len == 1
      check state.sessions[0].workingCopyMode == "git_worktree"
      check state.sessions[0].workspacePath == f.worktree
      check state.sessions[0].milestonesCompleted == 1
      check state.sessions[0].milestonesTotal == 1
      check state.sessions[0].lifecycle == aslCompleted

      check f.harbor.requests.anyIt(it.httpMethod == hmPost and
        it.url.endsWith("/api/v1/tasks"))
      let taskBody = parseJson(f.harbor.requests[0].body)
      check taskBody["workspace"]["workingCopyMode"].getStr() == "git_worktree"
      check ($taskBody["prompt"]).contains(
        "ct agent evidence --session agent:harbor:m6")
      check ($taskBody["agents"][0]["acpStdioLaunchCommand"]).contains(
        "codetracer_contract_worktree_file_edges.yaml")

      f.vm.activateAgentTab("agent:harbor:m6")
      check f.vm.workspaceMode.val == awmAgentWorkspace
      check f.workspace.viewKind.val == awvkAgentWorkspace
      check f.workspace.workspacePath.val == f.worktree
      check f.vcs.fileCount.val == 2
      check f.vcs.changedFiles.val.anyIt(it.path == "src/feature.nim")
      check f.vcs.changedFiles.val.anyIt(it.path == "feature-note.txt")
      check f.vcs.diffFiles.val.anyIt(it.path == "src/feature.nim" and
        it.hunks[0].lines.anyIt(it.content.contains("42")))
      check f.vm.activeEditorPath.val == "src/feature.nim"
      check f.vm.activeEditorContent.val.contains("42")
      check f.activity.messages.val.anyIt(it.content.contains("bash"))

      let rpcPath = f.worktree / ".codetracer" / "agent-evidence-rpc.json"
      let (output, code) = runAgentEvidenceCli(f, rpcPath)
      check code == 0
      check evidenceNotificationFromJson(parseJson(output)).status == aesReady
      check fileExists(rpcPath)
      check f.vm.handleAgentEvidenceRpcFile(rpcPath)

      check f.vcs.deepReviewMode.val
      check f.deepReview.hasData.val
      check f.deepReview.traceContexts.val[0].label ==
        "e2e_codetracer_headless_agent_harbor_worktree_deepreview"
      check f.deepReview.files.val.anyIt(it.path == "src/feature.nim")
      check f.deepReview.unifiedFiles.val.anyIt(it.path == "src/feature.nim")
      check f.activity.messages.val.anyIt(it.content.contains("DeepReview"))
