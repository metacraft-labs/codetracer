## CodeTracer agentic-coding service.
##
## This service is the production-facing bridge between CodeTracer's
## ViewModel store and the shared nim-agents abstraction. It replaces the
## previous ACP-only launch shape with one CodeTracer interface that can start
## either a direct ACP session or an Agent Harbor task.

import std/[json, sequtils, strutils]

import isonim/core/signals
import nim_agents

import agent_evidence
import store/[replay_data_store, types]

type
  CodeTracerAgentBackend* = enum
    ctabAcp
    ctabHarbor

  CodeTracerAgentLaunchConfig* = object
    backend*: CodeTracerAgentBackend
    cwd*: string
    taskTitle*: string
    instructions*: string
    context*: seq[string]
    acpBinary*: string
    acpArgs*: seq[string]
    model*: string
    tenantId*: string
    projectId*: string
    repoUrl*: string
    branch*: string
    commit*: string
    executionHostId*: string
    labels*: JsonNode
    sessionKey*: string

  CodeTracerAgentService* = ref object
    store*: ReplayDataStore
    client*: AgentClient
    backend*: CodeTracerAgentBackend
    nextSessionOrdinal*: int
    lastPromptBlocks*: seq[ContentBlock]

const
  DefaultEvidenceRequirement* =
    "Before finishing, run one or more tests that demonstrate the change, " &
    "then run this CodeTracer evidence command so the GUI can switch to " &
    "DeepReview for the recorded test execution."

proc toStoreBackend(backend: CodeTracerAgentBackend): AgentServiceBackend =
  case backend
  of ctabAcp: asbAcp
  of ctabHarbor: asbHarbor

proc toAgentBackend(backend: CodeTracerAgentBackend): AgentBackendKind =
  case backend
  of ctabAcp: abkAcp
  of ctabHarbor: abkHarbor

proc defaultTitle(config: CodeTracerAgentLaunchConfig): string =
  if config.taskTitle.len > 0:
    config.taskTitle
  elif config.instructions.len > 0:
    let firstLine = config.instructions.splitLines()[0].strip()
    if firstLine.len > 48: firstLine[0 .. 47] else: firstLine
  else:
    "Agent task"

proc promptText*(blocks: openArray[ContentBlock]): string =
  for item in blocks:
    if item.kind == cbText and item.text.len > 0:
      if result.len > 0:
        result.add "\n\n"
      result.add item.text

proc evidenceCommandForTab*(tabId: string): string =
  "ct agent evidence --session " & tabId

proc buildAgentTabId*(backend: CodeTracerAgentBackend;
    sessionKey: string): string =
  let backendPart =
    case backend
    of ctabAcp: "acp"
    of ctabHarbor: "harbor"
  "agent:" & backendPart & ":" & sessionKey

proc ensureSessionKey(service: CodeTracerAgentService;
    config: CodeTracerAgentLaunchConfig): string =
  if config.sessionKey.len > 0:
    config.sessionKey
  else:
    inc service.nextSessionOrdinal
    "session-" & $service.nextSessionOrdinal

proc buildLaunchPrompt*(config: CodeTracerAgentLaunchConfig;
    tabId: string): seq[ContentBlock] =
  let workspaceConstraint =
    if config.backend == ctabHarbor:
      "Work only inside the Agent Harbor git worktree workspace for this task."
    else:
      "Work only inside the CodeTracer session workspace for this task."
  taskPrompt(
    config.instructions,
    context = config.context & @[workspaceConstraint],
    evidenceCommand = evidenceCommandForTab(tabId),
    evidenceRequirement = DefaultEvidenceRequirement)

proc newCodeTracerAgentService*(store: ReplayDataStore;
    client: AgentClient): CodeTracerAgentService =
  CodeTracerAgentService(
    store: store,
    client: client,
    backend:
    if client.backend == abkHarbor: ctabHarbor
      else: ctabAcp)

proc eventKind(event: AgentEvent): AgentServiceEventKind =
  case event.kind
  of aekConnection: aseConnection
  of aekMessageChunk: aseMessage
  of aekThoughtChunk: aseThought
  of aekPlan: asePlan
  of aekToolCall, aekToolCallUpdate: aseTool
  of aekFileEdit: aseFileEdit
  of aekDiff: aseDiff
  of aekMilestoneProgress: aseProgress
  of aekWorkspaceReady: aseWorkspace
  of aekCompleted: aseCompleted
  of aekCancelled: aseCancelled
  of aekError: aseError
  else: aseStatus

proc lifecycleFromEvent(event: AgentEvent;
    current: AgentServiceLifecycle): AgentServiceLifecycle =
  case event.kind
  of aekCompleted: aslCompleted
  of aekCancelled: aslCancelled
  of aekError: aslError
  of aekConnection:
    case event.state
    of acsConnecting, acsAuthenticating: aslConnecting
    of acsDisconnected: aslDisconnected
    of acsCompleted: aslCompleted
    of acsCancelled: aslCancelled
    of acsError: aslError
    else: aslRunning
  else:
    if current in {aslCompleted, aslCancelled, aslError}: current
    else: aslRunning

proc eventText(event: AgentEvent): string =
  if event.text.len > 0:
    return event.text
  if event.planEntries.len > 0:
    return event.planEntries.join("\n")
  if event.toolName.len > 0:
    return event.toolName
  event.status

proc toStoreEvent(event: AgentEvent; index: int): AgentServiceEventEntry =
  AgentServiceEventEntry(
    id: event.sessionId & ":" & $index,
    kind: event.eventKind(),
    text: event.eventText(),
    status: event.status,
    toolName: event.toolName,
    filePath: event.filePath,
    diff: event.diff,
    milestoneCompleted: event.milestoneCompleted,
    milestoneTotal: event.milestoneTotal)

proc findSessionIndex(state: AgentSessionsState; tabId: string): int =
  for i, session in state.sessions:
    if session.tabId == tabId:
      return i
  -1

proc upsertSession(service: CodeTracerAgentService;
    entry: AgentServiceSessionEntry) =
  var state = service.store.agentSessions.val
  let index = state.findSessionIndex(entry.tabId)
  if index >= 0:
    state.sessions[index] = entry
  else:
    state.sessions.add entry
  state.activeTabId = entry.tabId
  service.store.agentSessions.val = state

proc updateSession(service: CodeTracerAgentService; tabId: string;
    update: proc(entry: var AgentServiceSessionEntry)) =
  var state = service.store.agentSessions.val
  let index = state.findSessionIndex(tabId)
  if index < 0:
    return
  update(state.sessions[index])
  state.activeTabId = tabId
  service.store.agentSessions.val = state

proc toStoreEvidenceState(status: AgentEvidenceStatus):
    AgentServiceEvidenceState =
  case status
  of aesReady: asesReady
  of aesNoRecording: asesNoRecording
  of aesFailedTests: asesFailedTests
  of aesMalformedMetadata: asesMalformedMetadata
  of aesDiffTraceMismatch: asesDiffTraceMismatch

proc toStoreEvidenceFile(file: AgentEvidenceFile):
    AgentServiceEvidenceFileEntry =
  AgentServiceEvidenceFileEntry(
    path: file.path,
    status: file.status,
    linesAdded: file.linesAdded,
    linesRemoved: file.linesRemoved,
    diff: file.diff)

proc registerAgentEvidence*(service: CodeTracerAgentService;
    notification: AgentEvidenceNotification) =
  let tabId =
    if notification.tabId.len > 0: notification.tabId
    else: notification.sessionId
  service.updateSession(tabId) do (entry: var AgentServiceSessionEntry):
    entry.evidence = AgentServiceEvidenceEntry(
      traceId: notification.traceId,
      tracePath: notification.tracePath,
      testName: notification.testName,
      testCommand: notification.testCommand,
      workspacePath: notification.workspacePath,
      state: notification.status.toStoreEvidenceState(),
      statusMessage: notification.statusMessage,
      files: notification.files.mapIt(it.toStoreEvidenceFile()))
    entry.events.add AgentServiceEventEntry(
      id: entry.tabId & ":evidence:" & $entry.events.len,
      kind: if notification.status == aesReady: aseStatus else: aseError,
      text:
      if notification.status == aesReady:
          "Recorded test evidence ready for DeepReview"
        else:
          "Recorded test evidence error: " & notification.status.statusString(),
      status: notification.status.statusString())

proc applyEvents*(service: CodeTracerAgentService; tabId: string;
    events: openArray[AgentEvent]) =
  let eventBatch = @events
  service.updateSession(tabId) do (entry: var AgentServiceSessionEntry):
    for event in eventBatch:
      entry.lifecycle = event.lifecycleFromEvent(entry.lifecycle)
      if event.workspacePath.len > 0:
        entry.workspacePath = event.workspacePath
      if event.workingCopyMode.len > 0:
        entry.workingCopyMode = event.workingCopyMode
      if event.milestoneTotal > 0:
        entry.milestonesCompleted = event.milestoneCompleted
        entry.milestonesTotal = event.milestoneTotal
      elif event.planEntries.len > 0:
        entry.milestonesTotal = event.planEntries.len
      entry.events.add event.toStoreEvent(entry.events.len)

proc buildStartMode(config: CodeTracerAgentLaunchConfig;
    prompt: seq[ContentBlock]): AgentStartMode =
  let labels = if config.labels.isNil: newJObject() else: config.labels
  let acpConfig = acpAgentConfig(
    config.acpBinary,
    config.acpArgs,
    model = if config.model.len > 0: config.model else: "default",
    displayName = "CodeTracer agent")
  case config.backend
  of ctabAcp:
    AgentStartMode(
      workspace: defaultWorkspaceContext(config.cwd),
      prompt: prompt,
      acpAgent: acpConfig,
      labels: labels)
  of ctabHarbor:
    AgentStartMode(
      workspace: gitWorktreeWorkspace(
        config.cwd,
        tenantId = config.tenantId,
        projectId = config.projectId,
        repoUrl = config.repoUrl,
        branch = config.branch,
        commit = config.commit,
        executionHostId = config.executionHostId),
      prompt: prompt,
      acpAgent: acpConfig,
      labels: labels)

proc startAgentSession*(service: CodeTracerAgentService;
    config: CodeTracerAgentLaunchConfig): AgentSession =
  if service.store.isNil:
    raise newException(ValueError, "CodeTracerAgentService requires a ReplayDataStore")
  if service.client.backend != config.backend.toAgentBackend():
    raise newException(ValueError, "agent client backend does not match launch config")

  let sessionKey = service.ensureSessionKey(config)
  let tabId = buildAgentTabId(config.backend, sessionKey)
  let prompt = buildLaunchPrompt(config, tabId)
  service.lastPromptBlocks = prompt

  service.upsertSession AgentServiceSessionEntry(
    tabId: tabId,
    backend: config.backend.toStoreBackend(),
    lifecycle: aslConnecting,
    title: config.defaultTitle(),
    prompt: prompt.promptText(),
    evidenceCommand: evidenceCommandForTab(tabId),
    workingCopyMode:
    if config.backend == ctabHarbor: $wiGitWorktree
      else: $wiNone)

  let mode = buildStartMode(config, prompt)
  let started = service.client.startSession(mode)
  result = started

  service.updateSession(tabId) do (entry: var AgentServiceSessionEntry):
    entry.sessionId = started.id
    entry.taskId = started.taskId
    entry.lifecycle = aslRunning

  case config.backend
  of ctabAcp:
    let turn = service.client.sendPrompt(started, prompt)
    service.applyEvents(tabId, acpUpdatesToAgentEvents(started.id, turn.updates))
  of ctabHarbor:
    service.applyEvents(tabId, service.client.readAgentEvents(started))

proc startFromCommandPalette*(service: CodeTracerAgentService;
    promptText: string; cwd: string; backend: CodeTracerAgentBackend;
    sessionKey = ""): AgentSession =
  service.startAgentSession(CodeTracerAgentLaunchConfig(
    backend: backend,
    cwd: cwd,
    taskTitle: "Agent task",
    instructions: promptText,
    sessionKey: sessionKey))

proc reconnectHarborSession*(service: CodeTracerAgentService; tabId, sessionId,
    taskId, cwd: string) =
  if service.client.backend != abkHarbor:
    raise newException(ValueError, "Agent Harbor reconnect requires Harbor backend")

  var workspacePath = ""
  var status = ""
  try:
    let info = service.client.sessionInfo(AgentSession(
      id: sessionId,
      taskId: taskId,
      backend: abkHarbor))
    workspacePath = info.workspacePath
    status = info.status
  except CatchableError:
    discard

  service.upsertSession AgentServiceSessionEntry(
    tabId: tabId,
    sessionId: sessionId,
    taskId: taskId,
    backend: asbHarbor,
    lifecycle:
    case status
    of "completed": aslCompleted
    of "cancelled": aslCancelled
    of "failed", "error": aslError
    of "": aslConnecting
    else: aslRunning,
    title: "Agent task",
    workspacePath: workspacePath,
    workingCopyMode: $wiGitWorktree)

  let session = AgentSession(id: sessionId, taskId: taskId, backend: abkHarbor)
  try:
    let progress = service.client.milestoneProgress(session)
    var completed = 0
    var total = 0
    for file in progress.files:
      completed += file.completedMilestones
      total += file.totalMilestones
    service.updateSession(tabId) do (entry: var AgentServiceSessionEntry):
      entry.milestonesCompleted = completed
      entry.milestonesTotal = total
  except CatchableError:
    discard

  service.applyEvents(tabId, service.client.eventHistory(session))
