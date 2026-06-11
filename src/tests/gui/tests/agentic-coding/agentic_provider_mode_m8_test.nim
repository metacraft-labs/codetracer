## M8 headless provider-mode parity for CodeTracer agentic sessions.
##
## AgentFS daemon-backed sessions are optional and environment-dependent. This
## test uses AgentFS-like Agent Harbor REST metadata to prove CodeTracer keeps
## the same ViewModel contract across provider modes without launching the
## privileged snapshot daemon.

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
  ProviderCase = object
    name: string
    requestedMode: string
    eventMode: string
    provider: string
    expectedMode: string

  ProviderFixture = ref object
    scenario: ProviderCase
    requests: seq[HttpRequest]
    workspace: string

  M8Fixture = object
    store: ReplayDataStore
    service: CodeTracerAgentService
    vm: AgenticSessionVM
    activity: AgentActivityVM
    workspace: AgentWorkspaceVM
    vcs: VCSVM
    deepReview: DeepReviewVM
    harbor: ProviderFixture

proc sh(cwd: string; command: string) =
  let (output, code) = execCmdEx(command, workingDir = cwd)
  doAssert code == 0, command & "\n" & output

proc makeWorkspace(name: string): string =
  result = getTempDir() / ("codetracer-agentic-m8-" & name & "-" &
    $getCurrentProcessId() & "-" & $epochTime().int)
  createDir(result)
  sh(result, "git init")
  sh(result, "git config user.email m8@example.invalid")
  sh(result, "git config user.name 'M8 Test'")
  createDir(result / "src")
  writeFile(result / "src" / "feature.nim", "proc providerValue*(): int = 1\n")
  sh(result, "git add src/feature.nim")
  sh(result, "git commit -m initial")
  writeFile(result / "src" / "feature.nim", "proc providerValue*(): int = 42\n")

proc makeStore(): ReplayDataStore =
  let mock = newMockBackendService()
  createReplayDataStore(mock.toBackendService())

proc taskId(f: ProviderFixture): string = "task-m8-" & f.scenario.name
proc sessionId(f: ProviderFixture): string = "session-m8-" & f.scenario.name
proc tabId(f: ProviderFixture): string = "agent:harbor:m8-" & f.scenario.name

proc eventBody(f: ProviderFixture): JsonNode =
  %*{
    "events": [
      {"type": "workspace", "status": "ready",
       "mountPath": f.workspace,
       "workingCopyMode": f.scenario.eventMode,
       "provider": f.scenario.provider,
       "timestamp": 1},
      {"type": "plan", "entries": ["edit", "test", "ct evidence"],
       "timestamp": 2},
      {"type": "tool_use", "tool_name": "bash",
       "tool_execution_id": "tool-m8-" & f.scenario.name,
       "status": "started",
       "message": "nim c -r feature_test.nim && ct agent evidence",
       "timestamp": 3},
      {"type": "diff", "file_path": "src/feature.nim",
       "lines_added": 1, "lines_removed": 1,
       "diff": "@@ -1 +1 @@\n-proc providerValue*(): int = 1\n+proc providerValue*(): int = 42\n",
       "timestamp": 4},
      {"type": "milestone_progress", "completed": 1, "total": 1,
       "message": "M8 provider parity complete", "timestamp": 5},
      {"type": "status", "status": "completed",
       "message": "scenario complete", "timestamp": 6}
    ],
    "has_more": false,
    "oldest_timestamp": 1,
    "total_count": 6
  }

proc harborTransport(f: ProviderFixture): HttpTransport =
  proc(req: HttpRequest): HttpResponse =
    f.requests.add req
    if req.httpMethod == hmPost and req.url.endsWith("/api/v1/tasks"):
      return HttpResponse(status: 201, body: $(%*{
        "task_id": f.taskId(),
        "session_ids": [f.sessionId()],
        "status": "queued",
        "links": {
          "self": "/api/v1/sessions/" & f.sessionId(),
          "events": "/api/v1/sessions/" & f.sessionId() & "/events",
          "logs": "/api/v1/sessions/" & f.sessionId() & "/logs"
        }
      }))
    if req.httpMethod == hmGet and req.url.contains(
        "/api/v1/sessions/" & f.sessionId() & "/events/history"):
      return HttpResponse(status: 200, body: $(f.eventBody()))
    if req.httpMethod == hmGet and req.url.contains(
        "/api/v1/sessions/" & f.sessionId() & "/events"):
      return HttpResponse(status: 200, body:
        "event: message\n" &
        "data: {\"type\":\"workspace\",\"status\":\"ready\",\"mountPath\":\"" &
        f.workspace.replace("\\", "\\\\") & "\",\"workingCopyMode\":\"" &
        f.scenario.eventMode & "\",\"provider\":\"" & f.scenario.provider &
        "\",\"timestamp\":1}\n\n")
    if req.httpMethod == hmGet and
        req.url.endsWith("/api/v1/sessions/" & f.sessionId() & "/info"):
      return HttpResponse(status: 200, body: $(%*{
        "id": f.sessionId(),
        "status": "completed",
        "workspacePath": f.workspace,
        "workingCopyMode": f.scenario.eventMode,
        "provider": f.scenario.provider,
        "endpoints": {"events": "/api/v1/sessions/" & f.sessionId() &
            "/events"},
        "fleet": {"leader": "agent-m8"}
      }))
    if req.httpMethod == hmGet and
        req.url.endsWith("/api/v1/tasks/" & f.taskId() & "/milestones"):
      return HttpResponse(status: 200, body: $(%*{
        "taskId": f.taskId(),
        "files": [{
          "path": "codetracer-specs/DeepReview/Agentic-Coding-Integration.milestones.org",
          "title": "Agentic Coding Integration",
          "currentMilestone": "M8",
          "status": "in_progress",
          "summary": {"totalMilestones": 1, "completedMilestones": 1,
            "progressPercent": 100}
        }],
        "pendingFeedback": []
      }))
    if req.httpMethod == hmGet and
        req.url.endsWith("/api/v1/sessions/" & f.sessionId() & "/files"):
      return HttpResponse(status: 200, body: $(%*{
        "items": [
          {"path": "src/feature.nim", "status": "modified",
           "linesAdded": 1, "linesRemoved": 1}
        ],
        "total": 1,
        "page": 1,
        "perPage": 50
      }))
    if req.httpMethod == hmGet and req.url.contains(
        "/api/v1/sessions/" & f.sessionId() & "/files/content/src/feature.nim"):
      return HttpResponse(status: 200,
        headers: @[header("content-type", "text/plain")],
        body: "proc providerValue*(): int = 42\n")
    if req.httpMethod == hmGet and req.url.contains(
        "/api/v1/sessions/" & f.sessionId() & "/diff/src/feature.nim"):
      return HttpResponse(status: 200, body: $(%*{
        "path": "src/feature.nim",
        "status": "modified",
        "linesAdded": 1,
        "linesRemoved": 1,
        "diff": "@@ -1 +1 @@\n-proc providerValue*(): int = 1\n+proc providerValue*(): int = 42\n"
      }))
    HttpResponse(status: 404, body: "not found: " & req.url)

proc launchConfig(f: ProviderFixture): CodeTracerAgentLaunchConfig =
  CodeTracerAgentLaunchConfig(
    backend: ctabHarbor,
    cwd: f.workspace,
    taskTitle: "M8 provider parity " & f.scenario.name,
    instructions: "Implement the M8 provider parity feature.",
    context: @["Scenario format: Agent Harbor provider metadata parity"],
    acpBinary: "mock-agent-acp",
    acpArgs: @["--scenario", "codetracer_m8_provider_mode.yaml"],
    model: "llm-api-proxy-scenario",
    tenantId: "tenant-m8",
    projectId: "project-m8",
    repoUrl: "file://" & f.workspace,
    branch: "main",
    commit: "HEAD",
    executionHostId: "local",
    workingCopyMode: f.scenario.requestedMode,
    sessionKey: "m8-" & f.scenario.name)

proc makeFixture(scenario: ProviderCase): M8Fixture =
  result.harbor = ProviderFixture(scenario: scenario,
    workspace: makeWorkspace(scenario.name))
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

proc cleanup(f: M8Fixture) =
  if f.harbor.workspace.len > 0 and dirExists(f.harbor.workspace):
    removeDir(f.harbor.workspace)

proc evidencePayload(f: M8Fixture): string =
  let notification = AgentEvidenceNotification(
    sessionId: f.harbor.sessionId(),
    taskId: f.harbor.taskId(),
    tabId: f.harbor.tabId(),
    workspacePath: f.harbor.workspace,
    traceId: "trace-m8-" & f.harbor.scenario.name,
    tracePath: f.harbor.workspace / ".codetracer" / "trace-m8",
    testName: "test_agentic_workspace_provider_mode_parity",
    testCommand: "nim c -r src/tests/gui/tests/agentic-coding/agentic_provider_mode_m8_test.nim",
    exitCode: 0,
    status: aesReady,
    statusMessage: "ready",
    createdAt: "2026-06-11T00:00:00Z",
    files: @[AgentEvidenceFile(
      path: "src/feature.nim",
      status: "modified",
      linesAdded: 1,
      linesRemoved: 1,
      diff: "@@ -1 +1 @@\n-proc providerValue*(): int = 1\n+proc providerValue*(): int = 42\n")],
    rawMetadata: %*{"providerMode": f.harbor.scenario.expectedMode})
  $(%notification)

proc assertProviderContract(f: M8Fixture) =
  let started = f.service.startAgentSession(f.harbor.launchConfig())
  check started.id == f.harbor.sessionId()
  check started.taskId == f.harbor.taskId()

  let taskBody = parseJson(f.harbor.requests[0].body)
  check taskBody["working_copy_mode"].getStr() ==
    f.harbor.scenario.expectedMode
  check taskBody["prompt"].getStr().contains(
    "ct agent evidence --session " & f.harbor.tabId())

  let state = f.store.agentSessions.val
  check state.sessions.len == 1
  check state.sessions[0].workingCopyMode == f.harbor.scenario.expectedMode
  check state.sessions[0].workspacePath == f.harbor.workspace
  check state.sessions[0].milestonesCompleted == 1
  check state.sessions[0].milestonesTotal == 1
  check state.sessions[0].events.anyIt(it.kind == aseWorkspace)
  check state.sessions[0].events.anyIt(it.kind == aseTool)
  check state.sessions[0].events.anyIt(it.kind == aseDiff)

  f.vm.activateAgentTab(f.harbor.tabId())
  check f.vm.workspaceMode.val == awmAgentWorkspace
  check f.workspace.viewKind.val == awvkAgentWorkspace
  check f.workspace.workspacePath.val == f.harbor.workspace
  check f.workspace.fileCount.val == 1
  check f.vcs.fileCount.val == 1
  check f.vcs.changedFiles.val[0].path == "src/feature.nim"
  check f.vcs.diffFiles.val.anyIt(it.path == "src/feature.nim" and
    it.hunks[0].lines.anyIt(it.content.contains("42")))
  check f.vm.activeEditorPath.val == "src/feature.nim"
  check f.vm.activeEditorContent.val.contains("42")
  check f.activity.messages.val.anyIt(it.content.contains("bash"))

  check f.vm.handleAgentEvidenceRpcPayload(f.evidencePayload())
  check f.vcs.deepReviewMode.val
  check f.deepReview.hasData.val
  check f.deepReview.traceContexts.val[0].label ==
    "test_agentic_workspace_provider_mode_parity"
  check f.deepReview.files.val.anyIt(it.path == "src/feature.nim")
  check f.deepReview.unifiedFiles.val.anyIt(it.path == "src/feature.nim")
  check f.activity.messages.val.anyIt(it.content.contains("DeepReview"))

suite "CodeTracer agentic M8 provider-mode parity":

  test "test_agentic_workspace_provider_mode_parity":
    createRoot proc(dispose: proc()) =
      let cases = @[
        ProviderCase(name: "worktree", requestedMode: "git_worktree",
          eventMode: "git", provider: "git", expectedMode: "git_worktree"),
        ProviderCase(name: "agentfs", requestedMode: "agentfs",
          eventMode: "overlay", provider: "agentfs", expectedMode: "agentfs")
      ]
      for scenario in cases:
        var f = makeFixture(scenario)
        try:
          f.assertProviderContract()
        finally:
          f.cleanup()
      dispose()
