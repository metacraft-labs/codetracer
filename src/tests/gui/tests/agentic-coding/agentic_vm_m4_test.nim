## Headless ViewModel integration matrix for M4 agentic-coding behavior.

import std/[json, sequtils, strutils, unittest]

import isonim/core/[computation, owner, signals]
import nim_acp
import nim_agent_harbor
import nim_agents
import nim_everywhere

import agent_service
import backend/mock_backend
import store/[replay_data_store, types]
import viewmodels/[agent_activity_vm, agent_workspace_vm, agentic_session_vm,
  editor_vm, vcs_vm]

type
  MatrixBackend = enum
    mbAcp
    mbHarbor

  HarborFixture = ref object
    requests: seq[HttpRequest]
    terminalStatus: string

  VmFixture = object
    store: ReplayDataStore
    service: CodeTracerAgentService
    vm: AgenticSessionVM
    editor: EditorVM
    activity: AgentActivityVM
    workspace: AgentWorkspaceVM
    vcs: VCSVM
    harbor: HarborFixture
    backend: MatrixBackend

proc makeStore(): ReplayDataStore =
  let mock = newMockBackendService()
  createReplayDataStore(mock.toBackendService())

proc launchConfig(backend: CodeTracerAgentBackend; sessionKey: string):
    CodeTracerAgentLaunchConfig =
  CodeTracerAgentLaunchConfig(
    backend: backend,
    cwd: "/repo",
    taskTitle: "Implement matrix feature",
    instructions: "Implement the requested matrix feature.",
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

proc acpService(store: ReplayDataStore; terminalStatus = "completed"):
    CodeTracerAgentService =
  let acpTransport = newFakeAcpTransport(@[
    promptTurn(@[
      %*{"sessionUpdate": "workspace", "workspacePath": "/tmp/acp-workspace",
          "workingCopyMode": "none"},
      %*{"sessionUpdate": "plan", "entries": ["edit", "test", "evidence"]},
      toolCall("tool-1", "bash", """{"cmd":"nim test"}"""),
      %*{"sessionUpdate": "file_edit", "path": "src/app.nim",
          "lines_added": 2, "lines_removed": 0},
      %*{"sessionUpdate": "diff", "path": "src/app.nim", "lines_added": 2,
          "lines_removed": 1,
          "diff": "@@ -1 +1 @@\n-old\n+agent acp content\n"},
      %*{"sessionUpdate": "milestone_progress", "completed": 2, "total": 3},
      statusUpdate(terminalStatus)
    ])
  ])
  var acpClient = newAcpClient(acpTransport)
  newCodeTracerAgentService(store, fromAcp(acpClient))

proc harborTransport(fixture: HarborFixture): HttpTransport =
  proc(req: HttpRequest): HttpResponse =
    fixture.requests.add req
    if req.httpMethod == hmPost and req.url.endsWith("/api/v1/tasks"):
      return HttpResponse(status: 201, body: $(%*{
        "task_id": "task-harbor-m4",
        "session_ids": ["session-harbor-m4"],
        "status": "queued",
        "links": {
          "self": "/api/v1/sessions/session-harbor-m4",
          "events": "/api/v1/sessions/session-harbor-m4/events",
          "logs": "/api/v1/sessions/session-harbor-m4/logs"
        }
      }))
    if req.httpMethod == hmGet and
        req.url.contains("/api/v1/sessions/session-harbor-m4/events/history"):
      return HttpResponse(status: 200, body: $(%*{
        "events": [
          {"type": "workspace", "status": "ready",
           "mountPath": "/tmp/harbor-worktree",
           "workingCopyMode": "git_worktree", "timestamp": 1},
          {"type": "tool_use", "tool_name": "bash",
           "tool_execution_id": "tool-1", "status": "started",
           "message": "run tests", "timestamp": 2},
          {"type": "diff", "file_path": "src/app.nim",
           "lines_added": 2, "lines_removed": 1,
           "diff": "agent harbor content", "timestamp": 3},
          {"type": "milestone_progress", "completed": 2, "total": 3,
           "message": "M4 progress", "timestamp": 4},
          {"type": "status", "status": fixture.terminalStatus,
           "message": "terminal state", "timestamp": 5}
        ],
        "has_more": false,
        "oldest_timestamp": 1,
        "total_count": 5
      }))
    if req.httpMethod == hmGet and
        req.url.contains("/api/v1/sessions/session-harbor-m4/events"):
      return HttpResponse(status: 200, body:
        "event: message\n" &
        "data: {\"type\":\"workspace\",\"status\":\"ready\",\"mountPath\":\"/tmp/harbor-worktree\",\"workingCopyMode\":\"git_worktree\",\"timestamp\":1}\n\n" &
        "event: message\n" &
        "data: {\"type\":\"plan\",\"entries\":[\"edit\",\"test\",\"evidence\"],\"timestamp\":2}\n\n" &
        "event: message\n" &
        "data: {\"type\":\"tool_use\",\"tool_name\":\"bash\",\"tool_execution_id\":\"tool-1\",\"status\":\"started\",\"message\":\"run tests\",\"timestamp\":3}\n\n" &
        "event: message\n" &
        "data: {\"type\":\"diff\",\"file_path\":\"src/app.nim\",\"lines_added\":2,\"lines_removed\":1,\"diff\":\"agent harbor content\",\"timestamp\":4}\n\n" &
        "event: message\n" &
        "data: {\"type\":\"milestone_progress\",\"completed\":2,\"total\":3,\"message\":\"M4 progress\",\"timestamp\":5}\n\n" &
        "event: message\n" &
        "data: {\"type\":\"status\",\"status\":\"" & fixture.terminalStatus &
        "\",\"message\":\"terminal state\",\"timestamp\":6}\n\n")
    if req.httpMethod == hmGet and
        req.url.endsWith("/api/v1/sessions/session-harbor-m4/files"):
      return HttpResponse(status: 200, body: $(%*{
        "items": [
          {"path": "src/app.nim", "status": "modified",
           "linesAdded": 2, "linesRemoved": 1}
        ],
        "total": 1,
        "page": 1,
        "perPage": 50
      }))
    if req.httpMethod == hmGet and req.url.contains(
        "/api/v1/sessions/session-harbor-m4/files/content/src/app.nim"):
      return HttpResponse(status: 200,
        headers: @[header("content-type", "text/plain")],
        body: "agent harbor content\n")
    if req.httpMethod == hmGet and req.url.contains(
        "/api/v1/sessions/session-harbor-m4/diff/src/app.nim"):
      return HttpResponse(status: 200, body: $(%*{
        "path": "src/app.nim",
        "status": "modified",
        "linesAdded": 2,
        "linesRemoved": 1,
        "diff": "@@ -1 +1 @@\n-old\n+agent harbor content\n"
      }))
    if req.httpMethod == hmGet and
        req.url.endsWith("/api/v1/sessions/session-harbor-m4/info"):
      return HttpResponse(status: 200, body: $(%*{
        "id": "session-harbor-m4",
        "status": fixture.terminalStatus,
        "workspacePath": "/tmp/harbor-worktree",
        "endpoints": {"events": "/api/v1/sessions/session-harbor-m4/events"},
        "fleet": {"leader": "agent-1"}
      }))
    if req.httpMethod == hmGet and
        req.url.endsWith("/api/v1/tasks/task-harbor-m4/milestones"):
      return HttpResponse(status: 200, body: $(%*{
        "taskId": "task-harbor-m4",
        "files": [{
          "path": "codetracer-specs/DeepReview/Agentic-Coding-Integration.milestones.org",
          "title": "Agentic Coding Integration",
          "currentMilestone": "M4",
          "status": "in_progress",
          "summary": {
            "totalMilestones": 3,
            "completedMilestones": 2,
            "progressPercent": 67
        }
      }],
        "pendingFeedback": []
      }))
    HttpResponse(status: 404, body: "not found: " & req.url)

proc harborService(store: ReplayDataStore; fixture: HarborFixture):
    CodeTracerAgentService =
  let harborClient = newHarborClient(
    "http://agent-harbor.invalid",
    harborTransport(fixture))
  newCodeTracerAgentService(store, fromHarbor(harborClient))

proc makeFixture(backend: MatrixBackend; terminalStatus = "completed"):
    VmFixture =
  result.store = makeStore()
  result.backend = backend
  case backend
  of mbAcp:
    result.service = acpService(result.store, terminalStatus)
  of mbHarbor:
    result.harbor = HarborFixture(terminalStatus: terminalStatus)
    result.service = harborService(result.store, result.harbor)
  result.editor = createEditorVM(result.store)
  result.activity = createAgentActivityVM(result.store)
  result.workspace = createAgentWorkspaceVM(result.store)
  result.vcs = createVCSVM()
  result.vm = createAgenticSessionVM(result.store, result.service,
    result.editor, result.activity, result.workspace, result.vcs)

proc start(fixture: VmFixture): AgentSession =
  case fixture.backend
  of mbAcp:
    fixture.service.startAgentSession(launchConfig(ctabAcp, "m4-acp"))
  of mbHarbor:
    fixture.service.startAgentSession(launchConfig(ctabHarbor, "m4-harbor"))

proc expectedTabId(backend: MatrixBackend): string =
  case backend
  of mbAcp: "agent:acp:m4-acp"
  of mbHarbor: "agent:harbor:m4-harbor"

proc assertProgressTabsActivity(fixture: VmFixture) =
  discard fixture.start()
  fixture.vm.refreshActiveProjection()

  let state = fixture.store.agentSessions.val
  let tabId = fixture.backend.expectedTabId()
  check state.sessions.len == 1
  check state.activeTabId == tabId
  check fixture.vm.activeTabId.val == tabId
  check fixture.vm.activeCaption.val == "Implement matrix feature 2/3"
  check fixture.vm.agentTabCaptions() == @["Implement matrix feature 2/3"]
  check state.sessions[0].milestonesCompleted == 2
  check state.sessions[0].milestonesTotal == 3
  check state.sessions[0].events.anyIt(it.kind == aseWorkspace)
  check state.sessions[0].events.anyIt(it.kind == aseTool)
  check state.sessions[0].events.anyIt(it.kind == aseDiff)
  check state.sessions[0].events.anyIt(it.kind == aseProgress)
  check fixture.activity.messageCount.val >= 5
  check fixture.activity.messages.val.anyIt(it.content.contains("bash"))
  check fixture.activity.messages.val.anyIt(it.content.contains(
      "src/app.nim") or
    it.content.contains("M4 progress"))
  check not fixture.activity.isLoading.val

proc assertWorkspaceSwitch(fixture: VmFixture) =
  discard fixture.start()
  let tabId = fixture.backend.expectedTabId()
  fixture.vm.setUserEditorState("/repo/src/user.nim", "user workspace content",
    activeTabIndex = 2, cursorLine = 17, cursorColumn = 5, dirty = true)

  fixture.vm.activateAgentTab(tabId)

  check fixture.vm.workspaceMode.val == awmAgentWorkspace
  check fixture.workspace.viewKind.val == awvkAgentWorkspace
  check fixture.workspace.sessionId.val.len > 0
  check fixture.workspace.fileCount.val == 1
  check fixture.workspace.files.val[0].path == "src/app.nim"
  check fixture.vcs.fileCount.val == 1
  check fixture.vcs.changedFiles.val[0].path == "src/app.nim"
  check fixture.vcs.unifiedDiffActive.val
  check fixture.vcs.diffFiles.val.len == 1
  check fixture.vm.activeEditorPath.val == "src/app.nim"
  check fixture.vm.activeEditorContent.val.contains("agent")
  check fixture.activity.messageCount.val >= 5

  if fixture.backend == mbHarbor:
    check fixture.harbor.requests.anyIt(it.url.endsWith(
      "/api/v1/sessions/session-harbor-m4/files"))
    check fixture.harbor.requests.anyIt(it.url.contains(
      "/api/v1/sessions/session-harbor-m4/files/content/src/app.nim"))
    check fixture.harbor.requests.anyIt(it.url.contains(
      "/api/v1/sessions/session-harbor-m4/diff/src/app.nim"))

proc assertLifecycle(backend: MatrixBackend; status: string;
    expected: AgentServiceLifecycle) =
  let fixture = makeFixture(backend, status)
  discard fixture.start()
  check fixture.store.agentSessions.val.sessions[0].lifecycle == expected
  if backend == mbHarbor:
    fixture.service.reconnectHarborSession(
      tabId = backend.expectedTabId(),
      sessionId = "session-harbor-m4",
      taskId = "task-harbor-m4",
      cwd = "/repo")
    check fixture.store.agentSessions.val.sessions[0].lifecycle == expected
    check fixture.store.agentSessions.val.sessions[0].milestonesCompleted == 2
    check fixture.store.agentSessions.val.sessions[0].milestonesTotal == 3

suite "Agentic ViewModel M4 matrix":

  test "test_agentic_vm_matrix_progress_tabs_and_activity":
    createRoot proc(dispose: proc()) =
      for backend in [mbAcp, mbHarbor]:
        let fixture = makeFixture(backend)
        fixture.assertProgressTabsActivity()
      for backend in [mbAcp, mbHarbor]:
        assertLifecycle(backend, "completed", aslCompleted)
        assertLifecycle(backend, "cancelled", aslCancelled)
        assertLifecycle(backend, "error", aslError)
      dispose()

  test "test_agentic_vm_matrix_workspace_switch_updates_editors_and_vcs":
    createRoot proc(dispose: proc()) =
      for backend in [mbAcp, mbHarbor]:
        let fixture = makeFixture(backend)
        fixture.assertWorkspaceSwitch()
      dispose()

  test "test_agentic_vm_preserves_user_workspace_state":
    createRoot proc(dispose: proc()) =
      for backend in [mbAcp, mbHarbor]:
        let fixture = makeFixture(backend)
        discard fixture.start()
        fixture.vm.setUserEditorState(
          "/repo/src/user.nim",
          "original dirty user buffer",
          activeTabIndex = 3,
          cursorLine = 21,
          cursorColumn = 8,
          dirty = true)
        fixture.vm.refreshActiveProjection()
        check fixture.vm.workspaceMode.val == awmUserWorkspace
        check fixture.vm.activeEditorContent.val == "original dirty user buffer"

        fixture.vm.activateAgentTab(backend.expectedTabId())
        check fixture.vm.activeEditorPath.val == "src/app.nim"
        check fixture.vm.activeEditorContent.val.contains("agent")
        check fixture.vm.userEditorSnapshot.val.content ==
          "original dirty user buffer"
        check fixture.vm.userEditorSnapshot.val.dirty

        fixture.vm.restoreUserWorkspace()
        check fixture.vm.workspaceMode.val == awmUserWorkspace
        check fixture.vm.activeEditorPath.val == "/repo/src/user.nim"
        check fixture.vm.activeEditorContent.val ==
          "original dirty user buffer"
        check fixture.editor.activeTabIndex.val == 3
        check fixture.editor.cursorLine.val == 21
        check fixture.editor.cursorColumn.val == 8
        check fixture.vm.userEditorSnapshot.val.dirty
      dispose()
