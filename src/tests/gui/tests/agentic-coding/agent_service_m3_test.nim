## Headless integration tests for M3 CodeTracer agent service migration.

import std/[json, sequtils, strutils, unittest]

import isonim/core/[owner, signals]
import nim_acp
import nim_agent_harbor
import nim_agents
import nim_everywhere

import agent_service
import backend/mock_backend
import store/[replay_data_store, types]

type
  CapturedHarbor = ref object
    requests: seq[HttpRequest]

proc makeStore(): ReplayDataStore =
  let mock = newMockBackendService()
  createReplayDataStore(mock.toBackendService())

proc requestBody(capture: CapturedHarbor; suffix: string): JsonNode =
  for req in capture.requests:
    if req.url.endsWith(suffix):
      return parseJson(req.body)
  doAssert false, "missing captured request ending with " & suffix
  newJObject()

proc harborTransport(capture: CapturedHarbor): HttpTransport =
  proc(req: HttpRequest): HttpResponse =
    capture.requests.add req
    if req.httpMethod == hmPost and req.url.endsWith("/api/v1/tasks"):
      return HttpResponse(status: 201, body: $(%*{
        "task_id": "task-harbor-1",
        "session_ids": ["session-harbor-1"],
        "status": "queued",
        "links": {
          "self": "/api/v1/sessions/session-harbor-1",
          "events": "/api/v1/sessions/session-harbor-1/events",
          "logs": "/api/v1/sessions/session-harbor-1/logs"
        }
      }))
    if req.httpMethod == hmGet and req.url.contains("/api/v1/sessions/session-harbor-1/events/history"):
      return HttpResponse(status: 200, body: $(%*{
        "events": [
          {"type": "workspace", "status": "ready",
              "mountPath": "/tmp/harbor-worktree",
              "workingCopyMode": "git_worktree", "timestamp": 10},
          {"type": "tool_use", "tool_name": "bash",
              "tool_execution_id": "tool-1", "status": "started",
              "message": "run tests", "timestamp": 11},
          {"type": "diff", "file_path": "src/app.nim", "lines_added": 3,
              "lines_removed": 1, "diff": "@@ -1 +1 @@", "timestamp": 12},
          {"type": "status", "status": "completed", "message": "done",
              "timestamp": 13}
        ],
        "has_more": false,
        "oldest_timestamp": 10,
        "total_count": 4
      }))
    if req.httpMethod == hmGet and req.url.contains("/api/v1/sessions/session-harbor-1/events"):
      return HttpResponse(status: 200, body:
        "event: message\n" &
        "data: {\"type\":\"workspace\",\"status\":\"ready\",\"mountPath\":\"/tmp/harbor-worktree\",\"workingCopyMode\":\"git_worktree\",\"timestamp\":1}\n\n" &
        "event: message\n" &
        "data: {\"type\":\"tool_use\",\"tool_name\":\"bash\",\"tool_execution_id\":\"tool-1\",\"status\":\"started\",\"message\":\"run tests\",\"timestamp\":2}\n\n" &
        "event: message\n" &
        "data: {\"type\":\"diff\",\"file_path\":\"src/app.nim\",\"lines_added\":3,\"lines_removed\":1,\"diff\":\"@@ -1 +1 @@\",\"timestamp\":3}\n\n" &
        "event: message\n" &
        "data: {\"type\":\"status\",\"status\":\"completed\",\"message\":\"done\",\"timestamp\":4}\n\n")
    if req.httpMethod == hmGet and req.url.endsWith("/api/v1/sessions/session-harbor-1/info"):
      return HttpResponse(status: 200, body: $(%*{
        "id": "session-harbor-1",
        "status": "completed",
        "workspacePath": "/tmp/harbor-worktree",
        "endpoints": {"events": "/api/v1/sessions/session-harbor-1/events"},
        "fleet": {"leader": "agent-1"}
      }))
    if req.httpMethod == hmGet and req.url.endsWith("/api/v1/tasks/task-harbor-1/milestones"):
      return HttpResponse(status: 200, body: $(%*{
        "taskId": "task-harbor-1",
        "files": [
          {
            "path": "codetracer-specs/DeepReview/Agentic-Coding-Integration.milestones.org",
            "title": "Agentic Coding Integration",
            "currentMilestone": "M3",
            "status": "in_progress",
            "summary": {
              "totalMilestones": 3,
              "completedMilestones": 2,
              "progressPercent": 67
            }
          }
        ],
        "pendingFeedback": []
      }))
    HttpResponse(status: 404, body: "not found: " & req.url)

proc makeAcpService(store: ReplayDataStore): CodeTracerAgentService =
  let acpTransport = newFakeAcpTransport(@[
    promptTurn(@[
      %*{"sessionUpdate": "workspace", "workspacePath": "/tmp/acp-workspace",
          "workingCopyMode": "none"},
      toolCall("tool-1", "bash", """{"cmd":"nim test"}"""),
      %*{"sessionUpdate": "diff", "path": "src/app.nim", "lines_added": 3,
          "lines_removed": 1, "diff": "@@ -1 +1 @@"},
      %*{"sessionUpdate": "milestone_progress", "completed": 1, "total": 2},
      statusUpdate("completed")
    ])
  ])
  var acpClient = newAcpClient(acpTransport)
  newCodeTracerAgentService(store, fromAcp(acpClient))

proc makeHarborService(store: ReplayDataStore;
    capture: CapturedHarbor): CodeTracerAgentService =
  let harborClient = newHarborClient(
    "http://agent-harbor.invalid",
    harborTransport(capture))
  newCodeTracerAgentService(store, fromHarbor(harborClient))

proc launchConfig(backend: CodeTracerAgentBackend; sessionKey: string):
    CodeTracerAgentLaunchConfig =
  CodeTracerAgentLaunchConfig(
    backend: backend,
    cwd: "/repo",
    taskTitle: "Implement feature",
    instructions: "Implement the requested feature.",
    context: @["Repository root: /repo"],
    acpBinary: "codex-acp",
    acpArgs: @["--model", "test"],
    model: "test-model",
    tenantId: "tenant-1",
    projectId: "project-1",
    repoUrl: "file:///repo",
    branch: "main",
    commit: "abc123",
    executionHostId: "local",
    sessionKey: sessionKey)

suite "CodeTracer agent service M3":

  test "test_codetracer_agent_service_start_session_acp_and_harbor":
    createRoot proc(dispose: proc()) =
      let acpStore = makeStore()
      let harborStore = makeStore()
      let capture = CapturedHarbor()
      let acpService = makeAcpService(acpStore)
      let harborService = makeHarborService(harborStore, capture)

      let acpSession = acpService.startAgentSession(
        launchConfig(ctabAcp, "stable-key"))
      let harborSession = harborService.startAgentSession(
        launchConfig(ctabHarbor, "stable-key"))

      let acpState = acpStore.agentSessions.val
      let harborState = harborStore.agentSessions.val
      check acpSession.id == "fake-session-1"
      check harborSession.id == "session-harbor-1"
      check acpState.sessions.len == 1
      check harborState.sessions.len == 1
      check acpState.sessions[0].tabId == "agent:acp:stable-key"
      check harborState.sessions[0].tabId == "agent:harbor:stable-key"
      check acpState.sessions[0].lifecycle == aslCompleted
      check harborState.sessions[0].lifecycle == aslCompleted
      check acpState.sessions[0].events.anyIt(it.kind == aseWorkspace)
      check harborState.sessions[0].events.anyIt(it.kind == aseWorkspace)
      check acpState.sessions[0].events.anyIt(it.kind == aseTool)
      check harborState.sessions[0].events.anyIt(it.kind == aseTool)
      check acpState.sessions[0].events.anyIt(it.kind == aseDiff)
      check harborState.sessions[0].events.anyIt(it.kind == aseDiff)
      check harborState.sessions[0].workingCopyMode == "git_worktree"

      dispose()

  test "test_codetracer_agent_prompt_includes_recording_command":
    createRoot proc(dispose: proc()) =
      let store = makeStore()
      let capture = CapturedHarbor()
      let service = makeHarborService(store, capture)

      discard service.startAgentSession(
        launchConfig(ctabHarbor, "prompt-key"))

      let body = capture.requestBody("/api/v1/tasks")
      let outgoingPrompt = body["prompt"].getStr()
      let session = store.agentSessions.val.sessions[0]
      check body["workspace_path"].getStr() == "/repo"
      check body["working_copy_mode"].getStr() == "git_worktree"
      check session.evidenceCommand ==
        "ct agent evidence --session agent:harbor:prompt-key"
      check outgoingPrompt.contains(session.evidenceCommand)
      check outgoingPrompt.contains("Before finishing, run one or more tests")
      check outgoingPrompt.contains("DeepReview")
      check outgoingPrompt.contains("Work only inside the Agent Harbor git worktree workspace")
      check outgoingPrompt.contains("Implement the requested feature.")

      dispose()

  test "test_codetracer_agent_service_reconnect_restores_session":
    createRoot proc(dispose: proc()) =
      let store = makeStore()
      let capture = CapturedHarbor()
      let service = makeHarborService(store, capture)
      let tabId = "agent:harbor:stable-reconnect"

      service.reconnectHarborSession(
        tabId = tabId,
        sessionId = "session-harbor-1",
        taskId = "task-harbor-1",
        cwd = "/repo")

      let state = store.agentSessions.val
      check state.activeTabId == tabId
      check state.sessions.len == 1
      check state.sessions[0].tabId == tabId
      check state.sessions[0].sessionId == "session-harbor-1"
      check state.sessions[0].taskId == "task-harbor-1"
      check state.sessions[0].lifecycle == aslCompleted
      check state.sessions[0].workspacePath == "/tmp/harbor-worktree"
      check state.sessions[0].workingCopyMode == "git_worktree"
      check state.sessions[0].milestonesCompleted == 2
      check state.sessions[0].milestonesTotal == 3
      check state.sessions[0].events.len == 4
      check state.sessions[0].events.anyIt(it.kind == aseTool)
      check state.sessions[0].events.anyIt(it.kind == aseDiff)

      dispose()
