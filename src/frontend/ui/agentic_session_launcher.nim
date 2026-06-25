## Product-facing agentic session launcher/coordinator.
##
## This module owns the frontend lifecycle for worktree-isolated Agent Harbor
## sessions.  The authoritative state lives in ``CodeTracerAgentService`` and
## ``AgenticSessionVM`` on the running GUI ``ReplayDataStore``.  The M7 test
## hook may provide deterministic launch config and external shell actions, but
## it does not provide GUI snapshots.

import std/[json, sequtils, strutils]

import nim_agent_harbor
import nim_agents
import nim_everywhere
import isonim/core/signals

import ui_imports
import ../event_helpers
import ../utils
import ../viewmodel/agent_service
import ../viewmodel/store/replay_data_store
import ../viewmodel/store/types
import ../viewmodel/viewmodels/[agent_activity_vm, agent_workspace_vm,
  agentic_session_vm, deepreview_vm, editor_vm, vcs_vm]
import agent_activity, agent_workspace, caption_bar_progress, deepreview, vcs

const
  AgentActivityId* = 7901
  AgentWorkspaceId* = 7901
  VcsId* = 7901
  DeepReviewId* = 7901
  CaptionId* = 7901
  ProductLauncherName* = "CodeTracerAgenticSessionLauncher"
  DefaultM7Scenario* =
    "../agent-harbor/tests/scenarios/e2e/codetracer_m7_worktree_feature.yaml"

type
  AgenticSessionExternalAction* =
    proc(command, inputRaw: cstring): cstring {.nimcall.}

  AgenticSessionLauncher* = ref object
    store*: ReplayDataStore
    service*: CodeTracerAgentService
    vm*: AgenticSessionVM
    externalAction*: AgenticSessionExternalAction
    lastInputRaw*: string
    lastSnapshot*: JsonNode
    activeTabId*: string
    activeSession*: AgentSession
    userWorkspacePath*: string
    agentWorkspacePath*: string
    harborBaseUrl*: string
    harborApiKey*: string

var currentAgenticSessionLauncher*: AgenticSessionLauncher

when defined(js):
  proc syncHttpRequest(httpMethod, url, body: cstring,
      headers: seq[HttpHeader]): js {.importjs: """
    (function(method, url, body, headers) {
      function nimString(value) {
        if (value == null) return '';
        if (typeof value === 'string') return value;
        if (Array.isArray(value)) return String.fromCharCode.apply(null, value);
        return String(value);
      }
      var xhr = new XMLHttpRequest();
      xhr.open(String(method), String(url), false);
      for (var i = 0; i < headers.length; i++) {
        var h = headers[i];
        if (h && h.name) xhr.setRequestHeader(nimString(h.name),
          nimString(h.value));
      }
      xhr.send(body && String(body).length > 0 ? String(body) : null);
      return {
        status: xhr.status,
        body: xhr.responseText || '',
        headers: xhr.getAllResponseHeaders() || ''
      };
    })(#, #, #, #)
  """.}

proc methodName(httpMethod: HttpMethod): string =
  case httpMethod
  of hmGet: "GET"
  of hmPost: "POST"
  of hmPut: "PUT"
  of hmDelete: "DELETE"

proc parseResponseHeaders(raw: string): seq[HttpHeader] =
  for line in raw.splitLines():
    let idx = line.find(':')
    if idx > 0:
      result.add header(line[0 ..< idx].strip(), line[idx + 1 .. ^1].strip())

proc rendererHttpTransport*(): HttpTransport =
  proc(req: HttpRequest): HttpResponse =
    when defined(js):
      let raw = syncHttpRequest(cstring req.httpMethod.methodName(),
        cstring req.url, cstring req.body, req.headers)
      result.status = raw.status.to(int)
      result.body = $raw.body
      result.headers = parseResponseHeaders($raw.headers)
    else:
      raise newException(ValueError,
        "rendererHttpTransport is only available in the JS renderer")

proc requireString(payload: JsonNode; name: string): string =
  result = payload{name}.getStr()
  if result.len == 0:
    raise newException(ValueError, "agentic worktree launch requires `" &
      name & "`")

proc stringSeq(payload: JsonNode; name: string; fallback: seq[string] = @[]):
    seq[string] =
  let node = payload{name}
  if node.isNil:
    result = fallback
  elif node.kind == JArray:
    for item in node.items:
      result.add item.getStr()
  else:
    result = fallback

proc buildLaunchConfig(payload: JsonNode): CodeTracerAgentLaunchConfig =
  let cwd = payload.requireString("userWorkspacePath")
  CodeTracerAgentLaunchConfig(
    backend: ctabHarbor,
    cwd: cwd,
    taskTitle: payload{"taskTitle"}.getStr("Agent worktree task"),
    instructions: payload.requireString("prompt"),
    context: payload.stringSeq("context", @[
      "Scenario format: Agent Harbor acp-client-runs-scenario"]),
    acpBinary: payload{"acpBinary"}.getStr("mock-agent-acp"),
    acpArgs: payload.stringSeq("acpArgs", @["--scenario", DefaultM7Scenario]),
    model: payload{"model"}.getStr("llm-api-proxy-scenario"),
    tenantId: payload{"tenantId"}.getStr("tenant-m7"),
    projectId: payload{"projectId"}.getStr("project-m7"),
    repoUrl: payload{"repoUrl"}.getStr("file://" & cwd),
    branch: payload{"branch"}.getStr("main"),
    commit: payload{"commit"}.getStr("HEAD"),
    executionHostId: payload{"executionHostId"}.getStr("local"),
    labels: payload{"labels"},
    sessionKey: payload{"sessionKey"}.getStr("m7"))

proc installHarborService(launcher: AgenticSessionLauncher; payload: JsonNode) =
  let baseUrl = payload.requireString("agentHarborBaseUrl")
  let apiKey = payload{"agentHarborApiKey"}.getStr()
  let auth =
    if apiKey.len > 0: apiKeyAuth(apiKey)
    else: HarborAuth(kind: akNone)
  let harborClient = newHarborClient(baseUrl, rendererHttpTransport(), auth)
  launcher.service = newCodeTracerAgentService(launcher.store,
    fromHarbor(harborClient))
  let editor = createEditorVM(launcher.store)
  launcher.vm = createAgenticSessionVM(launcher.store, launcher.service,
    editor, createAgentActivityVM(launcher.store),
    createAgentWorkspaceVM(launcher.store), createVCSVM(),
    createDeepReviewVM(launcher.store))
  launcher.harborBaseUrl = baseUrl
  launcher.harborApiKey = apiKey

proc activeEntry(launcher: AgenticSessionLauncher): AgentServiceSessionEntry =
  if launcher.activeTabId.len > 0:
    return launcher.store.agentSessions.val.findSession(launcher.activeTabId)
  launcher.vm.activeSession()

proc lifecycleString(value: AgentServiceLifecycle): string =
  case value
  of aslConnecting: "connecting"
  of aslRunning: "running"
  of aslCompleted: "completed"
  of aslCancelled: "cancelled"
  of aslError: "error"
  of aslDisconnected: "disconnected"

proc progressState(value: AgentServiceLifecycle): AgentProgressState =
  case value
  of aslCompleted: AgentCompleted
  of aslCancelled: AgentPaused
  of aslError: AgentFailed
  of aslConnecting: AgentInitializing
  else: AgentWorking

proc milestoneStatus(i, completed: int; lifecycle: AgentServiceLifecycle):
    MilestoneStatus =
  if lifecycle == aslError: MilestoneFailed
  elif lifecycle == aslCancelled: MilestoneFailed
  elif i < completed: MilestoneCompleted
  elif i == completed: MilestoneInProgress
  else: MilestonePending

proc progressFromSession(session: AgentServiceSessionEntry): AgentProgress =
  let total = max(session.milestonesTotal, 1)
  let completed = clamp(session.milestonesCompleted, 0, total)
  var milestones: seq[Milestone] = @[]
  for i in 0 ..< total:
    milestones.add Milestone(
      id: cstring("milestone-" & $i),
      content: cstring(
        if i == total - 1: "ct agent evidence" else: "agent milestone " & $(i + 1)),
      priority: if i == total - 1: cstring"high" else: cstring"medium",
      status: milestoneStatus(i, completed, session.lifecycle))
  AgentProgress(
    state: session.lifecycle.progressState(),
    taskName: cstring session.captionForSession(),
    milestonesCompleted: completed,
    milestonesTotal: total,
    currentMilestone: cstring(
      if session.evidenceCommand.len > 0: session.evidenceCommand
      else: "agent worktree"),
    milestones: milestones)

proc changedRows(vm: AgenticSessionVM): seq[VCSChangedFile] =
  for file in vm.vcs.changedFiles.val:
    result.add VCSChangedFile(
      status: cstring file.status,
      filename: cstring file.path,
      additions: file.additions,
      deletions: file.deletions)

proc workspaceRows(vm: AgenticSessionVM): seq[ActivityFileEntry] =
  for file in vm.workspace.files.val:
    result.add ActivityFileEntry(
      path: cstring file.path,
      coveredLines: file.coveredLines,
      totalLines: if file.totalLines > 0: file.totalLines else: 1,
      hasFlow: file.hasFlow)

proc diffLineType(line: string): cstring =
  if line.startsWith("+") and not line.startsWith("+++"): cstring"added"
  elif line.startsWith("-") and not line.startsWith("---"): cstring"removed"
  else: cstring"context"

proc deepReviewHunks(vm: AgenticSessionVM): seq[DeepReviewHunk] =
  var oldLine = 0
  var newLine = 0
  var hunk = DeepReviewHunk(oldStart: 1, oldCount: 1, newStart: 1,
    newCount: 1, lines: @[])
  for line in vm.activeEditorContent.val.splitLines():
    if line.startsWith("@@"):
      continue
    let kind = line.diffLineType()
    case $kind
    of "added":
      inc newLine
      hunk.lines.add DeepReviewHunkLine(`type`: kind, content: cstring line,
        oldLine: 0, newLine: newLine)
    of "removed":
      inc oldLine
      hunk.lines.add DeepReviewHunkLine(`type`: kind, content: cstring line,
        oldLine: oldLine, newLine: 0)
    else:
      inc oldLine
      inc newLine
      hunk.lines.add DeepReviewHunkLine(`type`: kind, content: cstring line,
        oldLine: oldLine, newLine: newLine)
  result = @[hunk]

proc deepReviewData(launcher: AgenticSessionLauncher): DeepReviewData =
  let vm = launcher.vm
  let session = launcher.activeEntry()
  var files: seq[DeepReviewFileData] = @[]
  for file in vm.vcs.changedFiles.val:
    files.add DeepReviewFileData(
      path: cstring file.path,
      contentHash: cstring"",
      sourceContent: cstring vm.activeEditorContent.val,
      symbols: @[],
      coverage: @[],
      functions: @[],
      loops: @[],
      flow: @[],
      flags: DeepReviewFileFlags(
        hasSymbols: false,
        hasCoverage: vm.vcs.deepReviewMode.val,
        hasFlow: vm.vcs.deepReviewMode.val,
        isUnreachable: false,
        isPartial: false),
      diff: DeepReviewFileDiff(
        status: cstring file.status,
        linesAdded: file.additions,
        linesRemoved: file.deletions,
        hunks: vm.deepReviewHunks()))
  DeepReviewData(
    commitSha: cstring session.taskId,
    baseCommitSha: cstring"",
    collectionTimeMs: 0,
    recordingCount: if vm.vcs.deepReviewMode.val: 1 else: 0,
    sessionTitle: cstring("DeepReview: " & session.captionForSession()),
    traceContexts: @[DeepReviewTraceContext(id: 1,
      label: cstring(
        if vm.deepReview.traceContexts.val.len > 0:
          vm.deepReview.traceContexts.val[0].label
        else: "recorded test"),
      recordingId: cstring(
        if session.evidence.traceId.len > 0: session.evidence.traceId
        else: "trace-m7-001"))],
    files: files,
    callTrace: DeepReviewCallTrace(nodes: @[]))

proc ensurePanel(content: Content; id: int) =
  if data.ui.layout.isNil:
    raise newException(ValueError,
      "M7 requires the normal CodeTracer GoldenLayout to be initialized")
  if data.ui.componentMapping[content].hasKey(id) and
      not data.ui.componentMapping[content][id].layoutItem.isNil:
    data.ui.componentMapping[content][id].layoutItem.parent.setActiveContentItem(
      data.ui.componentMapping[content][id].layoutItem)
    return
  data.openLayoutTab(content, id = id)

proc ensureAgenticPanels*(includeDeepReview: bool) =
  ensurePanel(Content.CaptionBarProgress, CaptionId)
  ensurePanel(Content.AgentActivity, AgentActivityId)
  ensurePanel(Content.AgentWorkspace, AgentWorkspaceId)
  ensurePanel(Content.VCS, VcsId)
  if includeDeepReview:
    ensurePanel(Content.DeepReview, DeepReviewId)

proc syncCaption(launcher: AgenticSessionLauncher) =
  let session = launcher.activeEntry()
  let comp = CaptionBarProgressComponent(
    data.ui.componentMapping[Content.CaptionBarProgress][CaptionId])
  comp.progress = session.progressFromSession()
  comp.viewState = WorkspaceViewState(
    activeView:
      if launcher.vm.workspaceMode.val == awmAgentWorkspace:
        AgentWorkspace
      else:
        UserWorkspace,
    agentWorkspacePath: cstring session.workspacePath,
    agentSessionId: cstring session.sessionId)
  caption_bar_progress.requestCaptionBarProgressRender(comp)

proc syncActivity(launcher: AgenticSessionLauncher) =
  let session = launcher.activeEntry()
  let comp = AgentActivityComponent(
    data.ui.componentMapping[Content.AgentActivity][AgentActivityId])
  comp.sessionId = cstring session.sessionId
  comp.pendingSessionId = cstring session.tabId
  comp.workspaceDir = cstring session.workspacePath
  comp.isLoading = session.lifecycle in {aslConnecting, aslRunning}
  comp.wasCancelled = session.lifecycle == aslCancelled
  comp.messageOrder = @[]
  comp.sessionMessageIds = JsAssoc[cstring, seq[AgentMessage]]{}

  var messages: seq[AgentMessage] = @[]
  for i, message in launcher.vm.activity.messages.val:
    let id = cstring(
      if message.id.len > 0: message.id else: "activity-" & $i)
    messages.add AgentMessage(
      id: id,
      content: cstring message.content,
      role: AgentMessageAgent,
      canceled: message.canceled,
      isLoading: message.isLoading,
      sessionDiffs: @[])
    comp.messageOrder.add id
  comp.sessionMessageIds[comp.sessionId] = messages
  comp.requestAgentActivityPanelRefresh()

proc syncWorkspace(launcher: AgenticSessionLauncher) =
  let session = launcher.activeEntry()
  let comp = AgentWorkspaceComponent(
    data.ui.componentMapping[Content.AgentWorkspace][AgentWorkspaceId])
  let isAgent = launcher.vm.workspaceMode.val == awmAgentWorkspace
  comp.viewState = WorkspaceViewState(
    activeView: if isAgent: AgentWorkspace else: UserWorkspace,
    agentWorkspacePath: cstring(
      if isAgent: session.workspacePath else: launcher.userWorkspacePath),
    agentSessionId: cstring session.sessionId)
  comp.progress = session.progressFromSession()
  comp.drSummary = ActivityDeepReviewSummary(
    totalLinesCovered: if launcher.vm.vcs.deepReviewMode.val: 1 else: 0,
    totalLinesUncovered: if launcher.vm.vcs.deepReviewMode.val: 0 else: 1,
    coveragePercent: if launcher.vm.vcs.deepReviewMode.val: 100.0 else: 0.0,
    testsRun: if launcher.vm.vcs.deepReviewMode.val: 1 else: 0,
    testsPassed: if launcher.vm.vcs.deepReviewMode.val: 1 else: 0,
    testsFailed: 0,
    functionsTraced: if launcher.vm.vcs.deepReviewMode.val: 1 else: 0,
    lastUpdatedMs: 0)
  comp.fileEntries = launcher.vm.workspaceRows()
  comp.selectedFileIndex = launcher.vm.workspace.selectedFileIndex.val
  comp.coverageOverlayEnabled = launcher.vm.workspace.coverageOverlayEnabled.val
  comp.notifications = @[]
  comp.requestAgentWorkspacePanelRefresh()

proc syncVcs(launcher: AgenticSessionLauncher) =
  launcher.vm.vcs.setHeader("agent-worktree")
  launcher.vm.vcs.setGitRepoState(true)
  launcher.vm.vcs.setBranchState("agent-worktree", ["agent-worktree"], false)
  launcher.vm.vcs.setCommits([], [])
  launcher.vm.vcs.setUnifiedDiff(launcher.vm.vcs.unifiedDiffActive.val,
    launcher.vm.vcs.diffFiles.val)
  launcher.vm.vcs.setHunkState([], false, false)
  if not data.ui.componentMapping[Content.VCS].hasKey(VcsId):
    return
  let comp = VCSComponent(data.ui.componentMapping[Content.VCS][VcsId])
  if comp.isNil:
    return
  comp.currentBranch = cstring"agent-worktree"
  comp.branches = @[cstring"agent-worktree"]
  comp.commits = @[]
  comp.selectedCommitIndices = @[]
  comp.lastClickedCommitIndex = -1
  comp.initialized = true
  comp.isGitRepo = true
  comp.errorMessage = cstring""
  comp.changedFiles = launcher.vm.changedRows()
  comp.unifiedDiffActive = launcher.vm.vcs.unifiedDiffActive.val
  comp.gitDiffData = launcher.deepReviewData()
  comp.selectedHunks = @[]
  comp.hunkToolbarVisible = false
  comp.syncLegacyVCSIntoVM()
  vcs.tryMountIsoNimVCSPanel(comp.id)

proc syncDeepReview(launcher: AgenticSessionLauncher) =
  data.deepReviewActive = true
  data.deepReviewSelectedFileIndex = 0
  data.deepReviewData = launcher.deepReviewData()
  data.startOptions.deepReview = data.deepReviewData
  data.startOptions.withDeepReview = true
  let comp = DeepReviewComponent(
    data.ui.componentMapping[Content.DeepReview][DeepReviewId])
  comp.drData = data.deepReviewData
  comp.glEmbedded = true
  comp.viewMode = Unified
  comp.selectedFileIndex = 0
  comp.selectedTraceContextId = 1
  comp.selectedExecutionIndex = 0
  comp.selectedIteration = 0
  comp.requestDeepReviewPanelRefresh()

proc syncEditor(launcher: AgenticSessionLauncher) =
  let path = cstring launcher.vm.activeEditorPath.val
  if path.len == 0:
    return
  let content = cstring launcher.vm.activeEditorContent.val
  data.services.editor.open[path] = TabInfo(
    name: path,
    path: path,
    source: content,
    sourceLines: ($content).splitLines().mapIt(cstring it),
    loading: false,
    received: true,
    changed: launcher.vm.workspaceMode.val == awmAgentWorkspace,
    lang: LangNim)
  data.services.editor.active = path

proc syncProductPanels*(launcher: AgenticSessionLauncher) =
  let includeDeepReview = launcher.vm.vcs.deepReviewMode.val
  let session = launcher.activeEntry()
  data.startOptions.folder = cstring(
    if launcher.vm.workspaceMode.val == awmAgentWorkspace:
      session.workspacePath
    else:
      launcher.userWorkspacePath)
  data.deepReviewActive = includeDeepReview
  ensureAgenticPanels(includeDeepReview)
  launcher.syncEditor()
  launcher.syncCaption()
  launcher.syncActivity()
  launcher.syncWorkspace()
  launcher.syncVcs()
  if includeDeepReview:
    launcher.syncDeepReview()

proc refreshActiveHarborSession(launcher: AgenticSessionLauncher) =
  let session = launcher.activeEntry()
  if session.backend != asbHarbor or session.sessionId.len == 0:
    return
  let agentSession = AgentSession(
    id: session.sessionId,
    taskId: session.taskId,
    backend: abkHarbor)
  launcher.service.refreshHarborSessionInfo(launcher.activeTabId, agentSession,
    launcher.userWorkspacePath)
  let refreshed = launcher.activeEntry()
  if not launcher.externalAction.isNil and refreshed.workspacePath.len > 0:
    var request = parseJson(launcher.lastInputRaw)
    request["tabId"] = %launcher.activeTabId
    request["sessionId"] = %refreshed.sessionId
    request["taskId"] = %refreshed.taskId
    request["agentWorkspacePath"] = %refreshed.workspacePath
    discard launcher.externalAction(cstring"scenario-effect", cstring($request))
  try:
    launcher.service.applyEvents(launcher.activeTabId,
      launcher.service.client.eventHistory(agentSession, limit = 50))
  except CatchableError:
    discard
  launcher.service.refreshHarborSessionInfo(launcher.activeTabId, agentSession,
    launcher.userWorkspacePath)

proc snapshot*(launcher: AgenticSessionLauncher;
    cancellation: JsonNode = nil): JsonNode =
  let session = launcher.activeEntry()
  var changed = newJArray()
  for file in launcher.vm.vcs.changedFiles.val:
    changed.add %*{
      "path": file.path,
      "status": file.status,
      "additions": file.additions,
      "deletions": file.deletions
    }
  var activity = newJArray()
  for message in launcher.vm.activity.messages.val:
    activity.add %message.content
  var labels = newJArray()
  for context in launcher.vm.deepReview.traceContexts.val:
    labels.add %context.label
  var modified = newJArray()
  for file in launcher.vm.deepReview.files.val:
    modified.add %file.path
  if modified.len == 0:
    for file in launcher.vm.vcs.changedFiles.val:
      modified.add %file.path

  result = %*{
    "startedFromCodeTracer": true,
    "productLauncher": ProductLauncherName,
    "productLauncherCommand": "codetracer.agent.liveStateSnapshot",
    "backend": "harbor",
    "workingCopyMode": session.workingCopyMode,
    "tabCaption": session.captionForSession(),
    "lifecycle": session.lifecycle.lifecycleString(),
    "workspaceMode": (
      if launcher.vm.workspaceMode.val == awmAgentWorkspace: "agent"
      else: "user"
    ),
    "activity": activity,
    "userWorkspacePath": launcher.userWorkspacePath,
    "agentWorkspacePath": session.workspacePath,
    "agentHarborBaseUrl": launcher.harborBaseUrl,
    "taskId": session.taskId,
    "sessionId": session.sessionId,
    "changedFiles": changed,
    "activeEditorPath": launcher.vm.activeEditorPath.val,
    "activeEditorContent": launcher.vm.activeEditorContent.val,
    "deepReview": {
      "active": launcher.vm.vcs.deepReviewMode.val,
      "traceContextLabels": labels,
      "viewMode": (
        if launcher.vm.deepReview.viewMode.val == drpvmUnified: "unified"
        else: "fullFiles"
      ),
      "fullFilesAvailable": launcher.vm.deepReview.files.val.len > 0,
      "modifiedFiles": modified
    }
  }
  if not cancellation.isNil:
    result["cancellation"] = cancellation
  launcher.lastSnapshot = result

proc startWorktreeAgentSession*(launcher: AgenticSessionLauncher;
    inputRaw: cstring): cstring =
  if launcher.isNil:
    raise newException(ValueError, "CodeTracer agentic launcher is not installed")
  let payload = parseJson($inputRaw)
  launcher.lastInputRaw = $payload
  launcher.userWorkspacePath = payload.requireString("userWorkspacePath")
  launcher.installHarborService(payload)
  launcher.vm.setUserEditorState("", "")
  let session = launcher.service.startAgentSession(payload.buildLaunchConfig())
  launcher.activeSession = session
  launcher.activeTabId = buildAgentTabId(ctabHarbor,
    payload{"sessionKey"}.getStr("m7"))
  launcher.vm.activateAgentTab(launcher.activeTabId)
  let entry = launcher.activeEntry()
  launcher.agentWorkspacePath = entry.workspacePath
  launcher.syncProductPanels()
  let response = launcher.snapshot()
  response["productLauncherCommand"] = %"codetracer.agent.startWorktreeSession"
  cstring($response)

proc openAgentTab*(launcher: AgenticSessionLauncher): cstring =
  launcher.refreshActiveHarborSession()
  launcher.vm.activateAgentTab(launcher.activeTabId)
  launcher.syncProductPanels()
  let response = launcher.snapshot()
  response["productLauncherCommand"] = %"codetracer.agent.openAgentTab"
  cstring($response)

proc restoreUserWorkspace*(launcher: AgenticSessionLauncher): cstring =
  launcher.vm.restoreUserWorkspace()
  launcher.syncProductPanels()
  let response = launcher.snapshot()
  response["productLauncherCommand"] = %"codetracer.agent.restoreUserWorkspace"
  cstring($response)

proc waitForEvidenceDeepReview*(launcher: AgenticSessionLauncher): cstring =
  if launcher.externalAction.isNil:
    raise newException(ValueError,
      "CodeTracer evidence handoff requires an external command runner")
  let request = parseJson(launcher.lastInputRaw)
  let session = launcher.activeEntry()
  request["tabId"] = %launcher.activeTabId
  request["sessionId"] = %session.sessionId
  request["taskId"] = %session.taskId
  request["agentWorkspacePath"] = %session.workspacePath
  let notificationRaw = launcher.externalAction(cstring"observe-evidence",
    cstring($request))
  if not launcher.vm.handleAgentEvidenceRpcPayload($notificationRaw):
    raise newException(ValueError,
      "CodeTracer evidence command did not activate DeepReview")
  launcher.syncProductPanels()
  let response = launcher.snapshot()
  let notification = parseJson($notificationRaw)
  response["scenarioEvidenceCommandConfigured"] =
    %notification{"scenarioEvidenceCommand"}{"configured"}.getBool(false)
  response["scenarioEvidenceCommandObserved"] =
    %notification{"scenarioEvidenceCommand"}{"observed"}.getBool(false)
  response["scenarioEvidenceCommandSource"] =
    notification{"scenarioEvidenceCommand"}{"source"}
  response["scenarioEvidenceCommands"] =
    notification{"scenarioEvidenceCommand"}{"commands"}
  response["productLauncherCommand"] = %"codetracer.agent.waitForEvidenceDeepReview"
  cstring($response)

proc cancelAndRecover*(launcher: AgenticSessionLauncher;
    inputRaw: cstring): cstring =
  discard launcher.startWorktreeAgentSession(inputRaw)
  if launcher.externalAction.isNil:
    raise newException(ValueError,
      "Agent Harbor cancellation requires an external command runner")
  var request = parseJson(launcher.lastInputRaw)
  let first = launcher.activeEntry()
  request["taskId"] = %first.taskId
  request["sessionId"] = %first.sessionId
  request["agentWorkspacePath"] = %first.workspacePath
  let cancellationRaw = launcher.externalAction(cstring"cancel", cstring($request))
  launcher.service.reconnectHarborSession(launcher.activeTabId,
    first.sessionId, first.taskId, launcher.userWorkspacePath)
  launcher.refreshActiveHarborSession()
  let cancellationResult = parseJson($cancellationRaw)
  if cancellationResult{"cancelled"}.getBool(false):
    launcher.service.markSessionCancelled(launcher.activeTabId)
  launcher.vm.activateAgentTab(launcher.activeTabId)
  launcher.syncProductPanels()
  let cancelled = launcher.snapshot()
  if cancelled{"lifecycle"}.getStr() != "cancelled":
    raise newException(ValueError,
      "Agent Harbor cancellation did not produce a cancelled GUI session state")

  var recoverInput = parseJson($inputRaw)
  recoverInput["prompt"] = %("Recover after cancellation with a fresh " &
    "worktree-isolated session.")
  recoverInput["sessionKey"] = %"m7-recovered"
  discard launcher.startWorktreeAgentSession(cstring($recoverInput))
  var cancellation = %*{
    "requested": true,
    "recovered": true,
    "cancelledTaskId": first.taskId,
    "recoveredTaskId": launcher.activeEntry().taskId,
    "cancelledLifecycle": cancelled{"lifecycle"}.getStr(),
    "cancelledWorkspaceMode": cancelled{"workspaceMode"}.getStr(),
    "cancelledSnapshot": cancelled,
    "message": "cancelled Agent Harbor task and recovered with fresh worktree session"
  }
  let response = launcher.snapshot(cancellation)
  response["productLauncherCommand"] = %"codetracer.agent.cancelAndRecover"
  cstring($response)

proc createAgenticSessionLauncher*(store: ReplayDataStore;
    externalAction: AgenticSessionExternalAction = nil): AgenticSessionLauncher =
  AgenticSessionLauncher(store: store, externalAction: externalAction,
    lastInputRaw: "{}")

proc installAgenticSessionLauncher*(store: ReplayDataStore;
    externalAction: AgenticSessionExternalAction = nil): AgenticSessionLauncher =
  currentAgenticSessionLauncher = createAgenticSessionLauncher(store,
    externalAction)
  currentAgenticSessionLauncher

proc configureAgenticWorktreeLaunch*(inputRaw: cstring) =
  if currentAgenticSessionLauncher.isNil:
    raise newException(ValueError,
      "CodeTracer agentic session launcher is not installed")
  currentAgenticSessionLauncher.lastInputRaw = $inputRaw

proc startAgenticWorktreeSessionFromCommandPalette*() =
  ensureAgenticPanels(includeDeepReview = false)
  if currentAgenticSessionLauncher.isNil:
    data.viewsApi.errorMessage(cstring(
      "Agent worktree launcher is not configured for this session"))
    return
  if currentAgenticSessionLauncher.lastInputRaw.len == 0 or
      currentAgenticSessionLauncher.lastInputRaw == "{}":
    data.viewsApi.errorMessage(cstring(
      "Agent worktree launch requires workspace, Harbor, and prompt configuration"))
    return
  try:
    discard currentAgenticSessionLauncher.startWorktreeAgentSession(
      cstring currentAgenticSessionLauncher.lastInputRaw)
  except CatchableError:
    data.viewsApi.errorMessage(cstring getCurrentExceptionMsg())
