## viewmodels/agent_workspace_vm.nim
##
## AgentWorkspaceVM — ViewModel for the Agent Workspace panel.
##
## The legacy ``AgentWorkspaceComponent`` remains the ACP/DeepReview IPC
## state carrier and Monaco owner.  This VM carries the platform-neutral
## DOM snapshot rendered by ``isonim_agent_workspace_view``: workspace
## metadata, summary counts, file rows, selected file, overlay toggle,
## and notification count.

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ../store/[replay_data_store, types]
import nim_agents/workspace

export workspace

type
  AgentWorkspaceVM* = ref object of ViewModel
    store*: ReplayDataStore

    viewKind*: Signal[AgentWorkspaceViewKind]
    workspacePath*: Signal[string]
    sessionId*: Signal[string]
    summary*: Signal[AgentWorkspaceSummary]
    files*: Signal[seq[AgentWorkspaceFileEntry]]
    selectedFileIndex*: Signal[int]
    coverageOverlayEnabled*: Signal[bool]
    notificationCount*: Signal[int]

    fileCount*: Memo[int]
    hasWorkspace*: Memo[bool]
    selectedFile*: Memo[AgentWorkspaceFileEntry]
    selectedCoverageText*: Memo[string]

# `clampSelectedIndex`, `coverageBadgeText`, `selectedFileOf` and
# `hasWorkspaceOf` live in `nim_agents/workspace` (CTF-M1), re-exported above.

proc setViewKind*(vm: AgentWorkspaceVM; kind: AgentWorkspaceViewKind) =
  vm.viewKind.val = kind

proc setWorkspaceMetadata*(vm: AgentWorkspaceVM; path, sessionId: string) =
  vm.workspacePath.val = path
  vm.sessionId.val = sessionId

proc setSummary*(vm: AgentWorkspaceVM; summary: AgentWorkspaceSummary) =
  vm.summary.val = summary

proc setFiles*(vm: AgentWorkspaceVM; files: openArray[AgentWorkspaceFileEntry]) =
  vm.files.val = @files
  vm.selectedFileIndex.val = clampSelectedIndex(
    vm.selectedFileIndex.val, vm.files.val.len)

proc setSelectedFileIndex*(vm: AgentWorkspaceVM; index: int) =
  vm.selectedFileIndex.val = clampSelectedIndex(index, vm.files.val.len)

proc setCoverageOverlayEnabled*(vm: AgentWorkspaceVM; enabled: bool) =
  vm.coverageOverlayEnabled.val = enabled

proc toggleCoverageOverlay*(vm: AgentWorkspaceVM) =
  vm.coverageOverlayEnabled.val = not vm.coverageOverlayEnabled.val

proc setNotificationCount*(vm: AgentWorkspaceVM; count: int) =
  vm.notificationCount.val = max(0, count)

proc clearWorkspace*(vm: AgentWorkspaceVM) =
  vm.workspacePath.val = ""
  vm.sessionId.val = ""
  vm.summary.val = AgentWorkspaceSummary()
  vm.files.val = @[]
  vm.selectedFileIndex.val = 0
  vm.coverageOverlayEnabled.val = true
  vm.notificationCount.val = 0

proc createAgentWorkspaceVM*(store: ReplayDataStore): AgentWorkspaceVM =
  withViewModel proc(dispose: proc()): AgentWorkspaceVM =
    let viewKind = createSignal(awvkAgentWorkspace)
    let workspacePath = createSignal("")
    let sessionId = createSignal("")
    let summary = createSignal(AgentWorkspaceSummary())
    let files = createSignal(newSeq[AgentWorkspaceFileEntry]())
    let selectedFileIndex = createSignal(0)
    let coverageOverlayEnabled = createSignal(true)
    let notificationCount = createSignal(0)

    let fileCount = createMemo[int] proc(): int =
      files.val.len

    let hasWorkspace = createMemo[bool] proc(): bool =
      hasWorkspaceOf(files.val.len, sessionId.val)

    let selectedFile = createMemo[AgentWorkspaceFileEntry] proc():
        AgentWorkspaceFileEntry =
      selectedFileOf(files.val, selectedFileIndex.val)

    let selectedCoverageText = createMemo[string] proc(): string =
      coverageBadgeText(selectedFile.val)

    AgentWorkspaceVM(
      store: store,
      viewKind: viewKind,
      workspacePath: workspacePath,
      sessionId: sessionId,
      summary: summary,
      files: files,
      selectedFileIndex: selectedFileIndex,
      coverageOverlayEnabled: coverageOverlayEnabled,
      notificationCount: notificationCount,
      fileCount: fileCount,
      hasWorkspace: hasWorkspace,
      selectedFile: selectedFile,
      selectedCoverageText: selectedCoverageText,
      disposeProc: dispose,
    )
