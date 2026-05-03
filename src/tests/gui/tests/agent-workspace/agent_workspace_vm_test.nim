## agent_workspace_vm_test.nim
##
## Unit tests for ``AgentWorkspaceVM`` — the ViewModel for the ACP
## Agent Workspace panel.

import std/[json, unittest]
import isonim/core/[signals, computation, owner]
import backend/mock_backend
import store/types
import store/replay_data_store
import viewmodels/agent_workspace_vm

const AgenticSessionFixtureJson =
  staticRead("../agentic-coding/fixtures/agent-session.json")

proc makeStoreWithMock(autoRespond: bool = true):
    tuple[store: ReplayDataStore, mock: MockBackendService] =
  let mock = newMockBackendService(autoRespond = autoRespond)
  let store = createReplayDataStore(mock.toBackendService())
  (store, mock)

proc makeFile(path: string; covered = 0; total = 0; hasFlow = false):
    AgentWorkspaceFileEntry =
  AgentWorkspaceFileEntry(
    path: path,
    coveredLines: covered,
    totalLines: total,
    hasFlow: hasFlow,
  )

proc agenticSessionFixture(): JsonNode =
  ## Shared GUI fixture used by ``agentic-deepreview.spec.ts``.  The
  ## workspace smoke exercises only the VM-visible session/workspace
  ## state; live workspace-view IPC stays covered by the GUI spec.
  parseJson(AgenticSessionFixtureJson)

suite "AgentWorkspaceVM initial state":

  test "defaults reflect an empty agent workspace":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentWorkspaceVM(store)

      check vm.viewKind.val == awvkAgentWorkspace
      check vm.workspacePath.val == ""
      check vm.sessionId.val == ""
      check vm.files.val.len == 0
      check vm.selectedFileIndex.val == 0
      check vm.coverageOverlayEnabled.val
      check vm.notificationCount.val == 0
      check vm.fileCount.val == 0
      check not vm.hasWorkspace.val
      check vm.selectedFile.val.path == ""
      check vm.selectedCoverageText.val == "--"

      dispose()

suite "AgentWorkspaceVM setters":

  test "metadata and view kind update workspace presence":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentWorkspaceVM(store)

      vm.setViewKind(awvkUserWorkspace)
      vm.setWorkspaceMetadata("/tmp/agent", "session-1")

      check vm.viewKind.val == awvkUserWorkspace
      check vm.workspacePath.val == "/tmp/agent"
      check vm.sessionId.val == "session-1"
      check vm.hasWorkspace.val

      dispose()

  test "setFiles clamps selection and computes coverage text":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentWorkspaceVM(store)

      vm.setFiles(@[
        makeFile("/repo/a.nim", covered = 1, total = 2),
        makeFile("/repo/b.nim", covered = 4, total = 4, hasFlow = true),
      ])
      vm.setSelectedFileIndex(10)

      check vm.fileCount.val == 2
      check vm.selectedFileIndex.val == 1
      check vm.selectedFile.val.path == "/repo/b.nim"
      check vm.selectedCoverageText.val == "4/4"
      check vm.selectedFile.val.hasFlow

      vm.setFiles(@[makeFile("/repo/only.nim", covered = 0, total = 0)])
      check vm.selectedFileIndex.val == 0
      check vm.selectedCoverageText.val == "--"

      dispose()

  test "summary overlay and notification setters update scalars":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentWorkspaceVM(store)

      vm.setSummary(AgentWorkspaceSummary(
        totalLinesCovered: 8,
        totalLinesUncovered: 2,
        coveragePercent: 80.0,
        testsRun: 5,
        testsPassed: 4,
        testsFailed: 1,
        functionsTraced: 3,
      ))
      vm.setCoverageOverlayEnabled(false)
      vm.setNotificationCount(-1)

      check vm.summary.val.coveragePercent == 80.0
      check vm.summary.val.testsFailed == 1
      check not vm.coverageOverlayEnabled.val
      check vm.notificationCount.val == 0

      vm.toggleCoverageOverlay()
      vm.setNotificationCount(7)
      check vm.coverageOverlayEnabled.val
      check vm.notificationCount.val == 7

      dispose()

  test "clearWorkspace resets transient panel state":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentWorkspaceVM(store)

      vm.setWorkspaceMetadata("/tmp/agent", "session-1")
      vm.setFiles(@[makeFile("/repo/a.nim", 1, 1)])
      vm.setSelectedFileIndex(1)
      vm.setCoverageOverlayEnabled(false)
      vm.setNotificationCount(3)
      vm.setSummary(AgentWorkspaceSummary(coveragePercent: 50.0))

      vm.clearWorkspace()

      check vm.workspacePath.val == ""
      check vm.sessionId.val == ""
      check vm.files.val.len == 0
      check vm.selectedFileIndex.val == 0
      check vm.coverageOverlayEnabled.val
      check vm.notificationCount.val == 0
      check vm.summary.val.coveragePercent == 0.0
      check not vm.hasWorkspace.val

      dispose()

suite "AgentWorkspaceVM agentic-coding smoke pairing":

  test "agentic fixture populates workspace metadata summary and files":
    ## Smoke-level companion for agentic-deepreview.spec.ts:
    ## session metadata, coverage-derived file rows, selected file,
    ## summary counters, overlay state, and notification count stay
    ## deterministic at the AgentWorkspaceVM layer.
    createRoot proc(dispose: proc()) =
      let fixture = agenticSessionFixture()
      let expected = fixture["expectedSummary"]
      let (store, _) = makeStoreWithMock()
      let vm = createAgentWorkspaceVM(store)
      var files: seq[AgentWorkspaceFileEntry] = @[]

      for notif in fixture["notifications"]:
        case notif["kind"].getStr()
        of "CoverageUpdate":
          let covered = notif["linesCovered"].len
          let total = covered + notif["linesUncovered"].len
          files.add(makeFile(notif["filePath"].getStr(),
                             covered = covered,
                             total = total))
        of "FlowUpdate", "FlowTraceUpdate":
          let flowPath = notif["flowFilePath"].getStr()
          for i in 0 ..< files.len:
            if files[i].path == flowPath:
              files[i].hasFlow = true
        else:
          discard

      vm.setViewKind(awvkAgentWorkspace)
      vm.setWorkspaceMetadata(fixture["agentWorkspacePath"].getStr(),
                              fixture["sessionId"].getStr())
      vm.setSummary(AgentWorkspaceSummary(
        totalLinesCovered: expected["totalLinesCovered"].getInt(),
        totalLinesUncovered: expected["totalLinesUncovered"].getInt(),
        coveragePercent: expected["coveragePercent"].getFloat(),
        testsRun: expected["testsRun"].getInt(),
        testsPassed: expected["testsPassed"].getInt(),
        testsFailed: expected["testsFailed"].getInt(),
        functionsTraced: expected["functionsTraced"].getInt(),
      ))
      vm.setFiles(files)
      vm.setSelectedFileIndex(2)
      vm.setCoverageOverlayEnabled(false)
      vm.setNotificationCount(fixture["notifications"].len)

      check vm.viewKind.val == awvkAgentWorkspace
      check vm.workspacePath.val == "/tmp/agent-workspace-e2e"
      check vm.sessionId.val == "agentic-e2e-test-session-001"
      check vm.hasWorkspace.val
      check vm.fileCount.val == expected["fileCount"].getInt()
      check vm.summary.val.totalLinesCovered ==
        expected["totalLinesCovered"].getInt()
      check vm.summary.val.testsPassed == expected["testsPassed"].getInt()
      check vm.summary.val.testsFailed == expected["testsFailed"].getInt()
      check vm.summary.val.functionsTraced ==
        expected["functionsTraced"].getInt()
      check vm.selectedFileIndex.val == 2
      check vm.selectedFile.val.path == "src/config.rs"
      check vm.selectedCoverageText.val == "3/12"
      check vm.files.val[0].hasFlow
      check vm.files.val[1].hasFlow
      check not vm.files.val[2].hasFlow
      check not vm.coverageOverlayEnabled.val
      check vm.notificationCount.val == fixture["notifications"].len

      dispose()

suite "AgentWorkspaceVM helpers":

  test "coverageBadgeText and clampSelectedIndex handle edge cases":
    check coverageBadgeText(makeFile("/x", 0, 0)) == "--"
    check coverageBadgeText(makeFile("/x", 2, 5)) == "2/5"
    check clampSelectedIndex(-1, 3) == 0
    check clampSelectedIndex(8, 3) == 2
    check clampSelectedIndex(0, 0) == 0
