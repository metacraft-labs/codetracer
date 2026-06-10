## ViewModel coordinator for agentic-coding sessions.
##
## This composes the shared agent service/store state with the existing
## activity, workspace, editor, and VCS ViewModels.  It is intentionally thin:
## backend protocol details stay in ``agent_service``/``nim-agents`` while this
## layer owns the product-visible tab/workspace projection.

import std/[os, strutils]

import isonim/core/[computation, owner, signals]
import isonim/viewmodel
import nim_agents

import ../agent_service
import ../store/[replay_data_store, types]
import agent_activity_vm, agent_workspace_vm, editor_vm, vcs_vm

type
  AgenticWorkspaceMode* = enum
    awmUserWorkspace
    awmAgentWorkspace

  AgenticEditorSnapshot* = object
    path*: string
    content*: string
    activeTabIndex*: int
    cursorLine*: int
    cursorColumn*: int
    dirty*: bool

  AgenticSessionVM* = ref object of ViewModel
    store*: ReplayDataStore
    service*: CodeTracerAgentService
    editor*: EditorVM
    activity*: AgentActivityVM
    workspace*: AgentWorkspaceVM
    vcs*: VCSVM

    workspaceMode*: Signal[AgenticWorkspaceMode]
    activeEditorPath*: Signal[string]
    activeEditorContent*: Signal[string]
    userEditorSnapshot*: Signal[AgenticEditorSnapshot]
    agentEditorSnapshot*: Signal[AgenticEditorSnapshot]

    activeTabId*: Memo[string]
    activeCaption*: Memo[string]

proc findSession*(state: AgentSessionsState; tabId: string):
    AgentServiceSessionEntry =
  for session in state.sessions:
    if session.tabId == tabId:
      return session
  AgentServiceSessionEntry()

proc activeSession*(vm: AgenticSessionVM): AgentServiceSessionEntry =
  vm.store.agentSessions.val.findSession(vm.store.agentSessions.val.activeTabId)

proc captionForSession*(session: AgentServiceSessionEntry): string =
  result =
    if session.title.len > 0: session.title
    elif session.tabId.len > 0: session.tabId
    else: "Agent task"
  if session.milestonesTotal > 0:
    result.add " " & $session.milestonesCompleted & "/" &
      $session.milestonesTotal

proc agentTabCaptions*(vm: AgenticSessionVM): seq[string] =
  for session in vm.store.agentSessions.val.sessions:
    result.add session.captionForSession()

proc rememberUserEditor(vm: AgenticSessionVM) =
  if vm.workspaceMode.val == awmUserWorkspace:
    vm.userEditorSnapshot.val = AgenticEditorSnapshot(
      path: vm.activeEditorPath.val,
      content: vm.activeEditorContent.val,
      activeTabIndex: vm.editor.activeTabIndex.val,
      cursorLine: vm.editor.cursorLine.val,
      cursorColumn: vm.editor.cursorColumn.val,
      dirty: vm.userEditorSnapshot.val.dirty)

proc setUserEditorState*(vm: AgenticSessionVM; path, content: string;
    activeTabIndex = 0; cursorLine = 1; cursorColumn = 1; dirty = false) =
  vm.workspaceMode.val = awmUserWorkspace
  vm.activeEditorPath.val = path
  vm.activeEditorContent.val = content
  vm.editor.switchTab(activeTabIndex)
  vm.editor.setCursor(cursorLine, cursorColumn)
  vm.userEditorSnapshot.val = AgenticEditorSnapshot(
    path: path,
    content: content,
    activeTabIndex: activeTabIndex,
    cursorLine: max(1, cursorLine),
    cursorColumn: max(1, cursorColumn),
    dirty: dirty)

proc restoreUserWorkspace*(vm: AgenticSessionVM) =
  let snap = vm.userEditorSnapshot.val
  vm.workspaceMode.val = awmUserWorkspace
  vm.workspace.setViewKind(awvkUserWorkspace)
  vm.activeEditorPath.val = snap.path
  vm.activeEditorContent.val = snap.content
  vm.editor.switchTab(snap.activeTabIndex)
  vm.editor.setCursor(snap.cursorLine, snap.cursorColumn)

proc eventToActivityMessage(event: AgentServiceEventEntry):
    AgentActivityMessageEntry =
  var content = event.text
  if content.len == 0:
    content = event.toolName
  if content.len == 0:
    content = event.filePath
  if content.len == 0:
    content = $event.kind
  AgentActivityMessageEntry(
    id: event.id,
    content: content,
    role: aamrAgent,
    canceled: event.kind == aseCancelled,
    isLoading: event.kind notin {aseCompleted, aseCancelled, aseError})

proc projectActivity(vm: AgenticSessionVM; session: AgentServiceSessionEntry) =
  var messages: seq[AgentActivityMessageEntry] = @[]
  for event in session.events:
    messages.add event.eventToActivityMessage()
  vm.activity.setMessages(messages)
  vm.activity.setLoading(session.lifecycle in {aslConnecting, aslRunning})
  vm.activity.setSessionKey(session.tabId)

proc diffRows(diff: string): seq[VCSDiffLineRow] =
  var oldLine = 0
  var newLine = 0
  for line in diff.splitLines():
    if line.startsWith("@@"):
      result.add VCSDiffLineRow(lineType: "hunk", content: line,
        oldLine: oldLine, newLine: newLine)
    elif line.startsWith("+") and not line.startsWith("+++"):
      inc newLine
      result.add VCSDiffLineRow(lineType: "add", content: line,
        oldLine: 0, newLine: newLine)
    elif line.startsWith("-") and not line.startsWith("---"):
      inc oldLine
      result.add VCSDiffLineRow(lineType: "delete", content: line,
        oldLine: oldLine, newLine: 0)
    else:
      inc oldLine
      inc newLine
      result.add VCSDiffLineRow(lineType: "context", content: line,
        oldLine: oldLine, newLine: newLine)

proc projectAcpWorkspace(vm: AgenticSessionVM;
    session: AgentServiceSessionEntry) =
  var files: seq[VCSFileRow] = @[]
  var workspaceFiles: seq[AgentWorkspaceFileEntry] = @[]
  var diffFiles: seq[VCSDiffFileRow] = @[]
  var firstPath = ""
  var firstContent = ""

  for event in session.events:
    if event.kind in {aseDiff, aseFileEdit} and event.filePath.len > 0:
      if firstPath.len == 0:
        firstPath = event.filePath
      if event.filePath == firstPath and event.diff.len > 0:
        firstContent = event.diff

      var existing = -1
      for i, file in files:
        if file.path == event.filePath:
          existing = i
          break
      let row = VCSFileRow(
        status: if event.kind == aseFileEdit: "modified" else: "diff",
        path: event.filePath,
        baseName: event.filePath.splitPath.tail)
      if existing >= 0:
        files[existing] = row
      else:
        files.add row
        workspaceFiles.add AgentWorkspaceFileEntry(path: event.filePath)
      if event.diff.len > 0:
        var diffExisting = -1
        for i, file in diffFiles:
          if file.path == event.filePath:
            diffExisting = i
            break
        let diffRow = VCSDiffFileRow(
          fileIndex: if diffExisting >= 0: diffExisting else: diffFiles.len,
          status: "modified",
          path: event.filePath,
          hunks: @[VCSHunkRow(lines: event.diff.diffRows())])
        if diffExisting >= 0:
          diffFiles[diffExisting] = diffRow
        else:
          diffFiles.add diffRow

  vm.vcs.setGitRepoState(true)
  vm.vcs.setChangedFiles(files)
  vm.vcs.setUnifiedDiff(diffFiles.len > 0, diffFiles)
  vm.workspace.setFiles(workspaceFiles)
  vm.activeEditorPath.val = firstPath
  vm.activeEditorContent.val = firstContent

proc projectHarborWorkspace(vm: AgenticSessionVM;
    session: AgentServiceSessionEntry) =
  let agentSession = AgentSession(id: session.sessionId,
    taskId: session.taskId, backend: abkHarbor)
  let changed = vm.service.client.changedFiles(agentSession)
  var files: seq[VCSFileRow] = @[]
  var workspaceFiles: seq[AgentWorkspaceFileEntry] = @[]
  var diffFiles: seq[VCSDiffFileRow] = @[]

  for i, item in changed.items:
    files.add VCSFileRow(
      status: item.status,
      path: item.path,
      baseName: item.path.splitPath.tail,
      additions: item.linesAdded,
      deletions: item.linesRemoved,
      selected: i == 0)
    workspaceFiles.add AgentWorkspaceFileEntry(path: item.path)
    let diff = vm.service.client.fileDiff(agentSession, item.path)
    diffFiles.add VCSDiffFileRow(
      fileIndex: i,
      status: diff.status,
      path: diff.path,
      additions: diff.linesAdded,
      deletions: diff.linesRemoved,
      hunks: @[VCSHunkRow(lines: diff.diff.diffRows())])
    if i == 0:
      let content = vm.service.client.fileContent(agentSession, item.path)
      vm.activeEditorPath.val = item.path
      vm.activeEditorContent.val = content.content

  vm.vcs.setGitRepoState(true)
  vm.vcs.setChangedFiles(files)
  vm.vcs.setUnifiedDiff(diffFiles.len > 0, diffFiles)
  vm.workspace.setFiles(workspaceFiles)

proc activateAgentTab*(vm: AgenticSessionVM; tabId: string) =
  var state = vm.store.agentSessions.val
  let session = state.findSession(tabId)
  if session.tabId.len == 0:
    return

  vm.rememberUserEditor()
  state.activeTabId = tabId
  vm.store.agentSessions.val = state
  vm.workspaceMode.val = awmAgentWorkspace
  vm.workspace.setViewKind(awvkAgentWorkspace)
  vm.workspace.setWorkspaceMetadata(session.workspacePath, session.sessionId)
  vm.workspace.setNotificationCount(session.events.len)
  vm.projectActivity(session)

  case session.backend
  of asbHarbor:
    vm.projectHarborWorkspace(session)
  of asbAcp:
    vm.projectAcpWorkspace(session)

  vm.agentEditorSnapshot.val = AgenticEditorSnapshot(
    path: vm.activeEditorPath.val,
    content: vm.activeEditorContent.val,
    activeTabIndex: vm.editor.activeTabIndex.val,
    cursorLine: vm.editor.cursorLine.val,
    cursorColumn: vm.editor.cursorColumn.val,
    dirty: false)

proc refreshActiveProjection*(vm: AgenticSessionVM) =
  let session = vm.activeSession()
  if session.tabId.len > 0:
    vm.projectActivity(session)

proc createAgenticSessionVM*(store: ReplayDataStore;
    service: CodeTracerAgentService; editor: EditorVM;
    activity: AgentActivityVM; workspace: AgentWorkspaceVM;
    vcs: VCSVM): AgenticSessionVM =
  withViewModel proc(dispose: proc()): AgenticSessionVM =
    let activeTabId = createMemo[string] proc(): string =
      store.agentSessions.val.activeTabId
    let activeCaption = createMemo[string] proc(): string =
      store.agentSessions.val.findSession(
        store.agentSessions.val.activeTabId).captionForSession()
    AgenticSessionVM(
      store: store,
      service: service,
      editor: editor,
      activity: activity,
      workspace: workspace,
      vcs: vcs,
      workspaceMode: createSignal(awmUserWorkspace),
      activeEditorPath: createSignal(""),
      activeEditorContent: createSignal(""),
      userEditorSnapshot: createSignal(AgenticEditorSnapshot()),
      agentEditorSnapshot: createSignal(AgenticEditorSnapshot()),
      activeTabId: activeTabId,
      activeCaption: activeCaption,
      disposeProc: dispose)
