## Headless tests for the ct-test editor/ViewModel integration.
##
## Compile and run:
##   nim c -r src/frontend/viewmodel/tests/unit/test_test_explorer_vm.nim

import std/[json, options, os, tables, unittest]

import ../../../../ct_test/[contracts, run_store]
import ../../viewmodels/test_explorer_vm

type
  MockCtTestService = ref object
    commands: seq[CtTestCommand]

  MockTraceOpenService = ref object
    opened: seq[TraceOpenRequest]

const
  Workspace = "/repo"
  FileA = "tests/test_alpha.nim"
  FileB = "tests/test_beta.nim"
  ProviderId = "nim-unittest"

proc newMockCtTestService(): tuple[mock: MockCtTestService,
    service: CtTestService] =
  let mock = MockCtTestService(commands: @[])
  let service = CtTestService()
  service.sendProc = proc(command: CtTestCommand) =
    mock.commands.add command
  (mock, service)

proc newMockTraceOpenService(): tuple[mock: MockTraceOpenService,
    service: TraceOpenService] =
  let mock = MockTraceOpenService(opened: @[])
  let service = TraceOpenService()
  service.openProc = proc(request: TraceOpenRequest) =
    mock.opened.add request
  (mock, service)

proc newVm(): tuple[
    vm: TestExplorerViewModel,
    ct: MockCtTestService,
    trace: MockTraceOpenService] =
  let (ctMock, ctService) = newMockCtTestService()
  let (traceMock, traceService) = newMockTraceOpenService()
  (createTestExplorerViewModel(Workspace, ctService, traceService),
    ctMock, traceMock)

proc newVmWithStore(store: LocalRunStore): tuple[
    vm: TestExplorerViewModel,
    ct: MockCtTestService,
    trace: MockTraceOpenService] =
  let (ctMock, ctService) = newMockCtTestService()
  let (traceMock, traceService) = newMockTraceOpenService()
  (createTestExplorerViewModel(Workspace, ctService, traceService, store),
    ctMock, traceMock)

proc tempRoot(name: string): string =
  result = getTempDir() / ("codetracer-vm-m14-" & name & "-" &
      $getCurrentProcessId())
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc capabilities(): TestCapabilities =
  TestCapabilities(
    canDiscoverProject: true,
    canDiscoverFile: true,
    canLocateTests: true,
    canRunProject: true,
    canRunFile: true,
    canRunSingle: true,
    canRecordProject: true,
    canRecordFile: true,
    canRecordSingle: true,
    canCapturePerTestOutput: true,
    canMapTraceEntryPoints: true,
    emitsStructuredEvents: true)

proc providerInfo(version = "m3-fixture"): TestProviderInfo =
  TestProviderInfo(
    id: ProviderId,
    language: "nim",
    framework: "std/unittest",
    displayName: "Nim unittest",
    version: version,
    capabilities: capabilities())

proc sourceRange(line: int): SourceRange =
  SourceRange(
    startLine: line,
    startColumn: 3,
    endLine: line,
    endColumn: 24)

proc item(file, name, selector: string; line: int): TestItem =
  TestItem(
    id: makeTestItemId(ProviderId, "nim", "std/unittest", file, selector),
    providerId: ProviderId,
    language: "nim",
    framework: "std/unittest",
    name: name,
    kind: tikCase,
    file: file,
    range: sourceRange(line),
    selector: selector,
    parentId: "",
    tags: @[],
    location: LocationProvenance(
      source: lskParser,
      detail: "M3 fixture",
      confidence: lcHigh),
    stale: false,
    staleReason: "")

proc catalog(items: seq[TestItem]): TestCatalog =
  TestCatalog(
    schemaVersion: TestCatalogSchemaVersion,
    provider: providerInfo(),
    items: items,
    diagnostics: @[])

proc trace(path: string): TraceMetadata =
  TraceMetadata(
    traceId: "trace-1",
    recordingId: "recording-1",
    path: path,
    backend: "db-backend",
    entryPoint: "test_alpha",
    metadata: initTable[string, string]())

proc event(kind: TestEventKind; testId: string;
    runId = "run-1";
    status = none(TestResultStatus);
    message = "";
    output = "";
    durationMs = 0;
    traceValue = none(TraceMetadata);
    diagnostic = none(TestDiagnostic)): TestEvent =
  TestEvent(
    schemaVersion: TestEventSchemaVersion,
    kind: kind,
    providerId: ProviderId,
    runId: runId,
    testId: testId,
    status: status,
    message: message,
    output: output,
    durationMs: durationMs,
    trace: traceValue,
    diagnostic: diagnostic)

suite "ct-test TestExplorerViewModel M3":

  test "viewmodel_ingests_catalog_and_builds_editor_actions":
    let (vm, _, _) = newVm()
    let alpha = item(FileA, "adds numbers",
        "tests/test_alpha.nim::adds numbers", 12)
    let beta = item(FileA, "subtracts numbers",
        "tests/test_alpha.nim::subtracts numbers", 24)

    vm.ingestCatalog(catalog(@[alpha, beta]))

    let actions = vm.editorActionsForFile(FileA)
    check actions.len == 4
    check actions[0].line == 12
    check actions[0].range == sourceRange(12)
    check actions[0].kind == teakRunTest
    check actions[0].command.argv == @[
      "ct", "test", "run", "--selector",
      "tests/test_alpha.nim::adds numbers", "--json-events"]
    check actions[1].kind == teakRecordTest
    check actions[1].command.argv == @[
      "ct", "test", "record", "--selector",
      "tests/test_alpha.nim::adds numbers", "--json-events",
      "--open-policy=current-tab"]
    check actions[2].line == 24
    check actions[3].line == 24

  test "viewmodel_refresh_one_file_preserves_other_trace_state":
    let (vm, _, _) = newVm()
    let alpha = item(FileA, "alpha", "tests/test_alpha.nim::alpha", 10)
    let beta = item(FileB, "beta", "tests/test_beta.nim::beta", 20)
    vm.ingestCatalog(catalog(@[alpha, beta]))

    vm.handleEvent(event(tekTestFinished, beta.id,
      status = some(tsPassed),
      durationMs = 19,
      traceValue = some(trace("/repo/.codetracer/beta.trace"))))

    let refreshedAlpha = item(FileA, "alpha moved",
        "tests/test_alpha.nim::alpha", 14)
    vm.ingestFileCatalog(FileA, catalog(@[refreshedAlpha]))

    check vm.editorActionsForFile(FileA)[0].line == 14
    check vm.editorActionsForFile(FileB)[0].line == 20
    check vm.runStates[beta.id].status == tesPassed
    check vm.runStates[beta.id].durationMs == 19

    vm.ingestFileCatalog(FileA, catalog(@[]))

    check vm.editorActionsForFile(FileA).len == 0
    check vm.editorActionsForFile(FileB)[0].line == 20
    check vm.runStates[beta.id].trace.get.path == "/repo/.codetracer/beta.trace"

  test "viewmodel_record_event_opens_trace_current_tab":
    let (vm, _, traceMock) = newVm()
    let alpha = item(FileA, "alpha", "tests/test_alpha.nim::alpha", 10)
    vm.ingestCatalog(catalog(@[alpha]))

    vm.handleEvent(event(tekRecordStarted, alpha.id, runId = "record-alpha"),
      topCurrentTab)
    vm.handleEvent(event(tekRecordingCreated, alpha.id,
      runId = "record-alpha",
      traceValue = some(trace("/repo/.codetracer/alpha.trace"))),
      topCurrentTab)

    check traceMock.opened.len == 1
    check traceMock.opened[0].tracePath == "/repo/.codetracer/alpha.trace"
    check traceMock.opened[0].testId == alpha.id
    check traceMock.opened[0].policy == topCurrentTab
    check vm.runStates[alpha.id].trace.get.path ==
      "/repo/.codetracer/alpha.trace"

  test "viewmodel_record_event_opens_trace_new_tab":
    let (vm, _, traceMock) = newVm()
    let alpha = item(FileA, "alpha", "tests/test_alpha.nim::alpha", 10)
    vm.ingestCatalog(catalog(@[alpha]))

    vm.handleEvent(event(tekRecordStarted, alpha.id, runId = "record-alpha"),
      topNewTab)
    vm.handleEvent(event(tekRecordingCreated, alpha.id,
      runId = "record-alpha",
      traceValue = some(trace("/repo/.codetracer/alpha.trace"))),
      topCurrentTab)

    check traceMock.opened.len == 1
    check traceMock.opened[0].policy == topNewTab

  test "viewmodel_record_failure_does_not_open_trace_and_records_diagnostics":
    let (vm, _, traceMock) = newVm()
    let alpha = item(FileA, "alpha", "tests/test_alpha.nim::alpha", 10)
    vm.ingestCatalog(catalog(@[alpha]))

    vm.handleEvent(event(tekRecordStarted, alpha.id, runId = "record-alpha"),
      topCurrentTab)
    vm.handleEvent(event(tekFailure, alpha.id,
      runId = "record-alpha",
      message = "recorder could not start"),
      topCurrentTab)

    check traceMock.opened.len == 0
    check vm.runStates[alpha.id].status == tesFailed
    check vm.runStates[alpha.id].diagnostics.len == 1
    check vm.runStates[alpha.id].diagnostics[0].message ==
      "recorder could not start"
    check vm.runStates[alpha.id].trace.isNone

  test "viewmodel_selector_and_file_actions_construct_exact_ct_test_commands":
    let (vm, ctMock, _) = newVm()
    let alpha = item(FileA, "alpha", "tests/test_alpha.nim::alpha", 10)
    vm.ingestCatalog(catalog(@[alpha]))

    vm.discoverWorkspace()
    vm.discoverFile(FileA)
    vm.runTest(alpha.id)
    vm.recordTest(alpha.id, topNewTab)
    vm.runFile(FileA)
    vm.recordFile(FileA, topCurrentTab)

    check ctMock.commands.len == 6
    check ctMock.commands[0].argv == @[
      "ct", "test", "discover", "--workspace", Workspace, "--json"]
    check ctMock.commands[1].argv == @[
      "ct", "test", "discover", "--workspace", Workspace, "--file", FileA,
      "--json"]
    check ctMock.commands[2].argv == @[
      "ct", "test", "run", "--selector", "tests/test_alpha.nim::alpha",
      "--json-events"]
    check ctMock.commands[3].argv == @[
      "ct", "test", "record", "--selector",
      "tests/test_alpha.nim::alpha",
      "--json-events", "--open-policy=new-tab"]
    check ctMock.commands[4].argv == @[
      "ct", "test", "run", "--file", FileA, "--json-events"]
    check ctMock.commands[5].argv == @[
      "ct", "test", "record", "--file", FileA, "--json-events",
      "--open-policy=current-tab"]

  test "viewmodel_consumes_json_event_lines":
    let (vm, _, traceMock) = newVm()
    let alpha = item(FileA, "alpha", "tests/test_alpha.nim::alpha", 10)
    vm.ingestCatalog(catalog(@[alpha]))

    let outputLine = $event(tekOutput, alpha.id,
      output = "stdout from alpha").toJson
    vm.handleJsonEventLine(outputLine)

    let diagnostic = TestDiagnostic(
      severity: dsError,
      message: "assertion failed",
      file: FileA,
      range: some(sourceRange(10)))
    let diagnosticLine = $event(tekDiagnostic, alpha.id,
      diagnostic = some(diagnostic)).toJson
    vm.handleJsonEventLine(diagnosticLine)

    let recordStartedLine = $event(tekRecordStarted, alpha.id,
      runId = "record-alpha").toJson
    vm.handleJsonEventLine(recordStartedLine, topNewTab)

    let recordingLine = $event(tekRecordingCreated, alpha.id,
      runId = "record-alpha",
      traceValue = some(trace("/repo/.codetracer/json-alpha.trace"))).toJson
    vm.handleJsonEventLine(recordingLine)

    let finishedLine = $event(tekTestFinished, alpha.id,
      status = some(tsFailed),
      durationMs = 42,
      traceValue = some(trace("/repo/.codetracer/json-alpha.trace"))).toJson
    vm.handleJsonEventLine(finishedLine)

    check vm.runStates[alpha.id].status == tesFailed
    check vm.runStates[alpha.id].output == "stdout from alpha"
    check vm.runStates[alpha.id].diagnostics.len == 1
    check vm.runStates[alpha.id].diagnostics[0].message == "assertion failed"
    check vm.runStates[alpha.id].durationMs == 42
    check vm.runStates[alpha.id].trace.get.path ==
      "/repo/.codetracer/json-alpha.trace"
    check traceMock.opened.len == 1
    check traceMock.opened[0].policy == topNewTab

suite "ct-test TestExplorerViewModel M14":

  test "last_trace_survives_gui_restart":
    let root = tempRoot("last-trace")
    let store = openLocalRunStore(root)
    let alpha = item(FileA, "alpha", "tests/test_alpha.nim::alpha", 10)
    let traceDir = root / "alpha-recording"
    createDir(traceDir)

    block firstSession:
      let (vm, _, _) = newVmWithStore(store)
      vm.ingestCatalog(catalog(@[alpha]))
      vm.handleEvent(event(tekRecordStarted, alpha.id, runId = "record-alpha"),
        topCurrentTab)
      vm.handleEvent(event(tekRecordingCreated, alpha.id,
        runId = "record-alpha",
        traceValue = some(trace(traceDir))),
        topCurrentTab)

    block restartedSession:
      let reopenedStore = openLocalRunStore(root)
      let (vm, _, traceMock) = newVmWithStore(reopenedStore)
      vm.ingestCatalog(catalog(@[alpha]))

      check vm.runStates[alpha.id].trace.get.path == traceDir
      check vm.openLastTrace(alpha.id, topNewTab)
      check traceMock.opened.len == 1
      check traceMock.opened[0].tracePath == traceDir
      check traceMock.opened[0].recordingId == "recording-1"
      check traceMock.opened[0].policy == topNewTab

  test "environment_fingerprint_separates_last_result_after_reload":
    let root = tempRoot("env")
    let store = openLocalRunStore(root)
    let alpha = item(FileA, "alpha", "tests/test_alpha.nim::alpha", 10)
    let envA = defaultEnvironmentFingerprint(Workspace, providerInfo("env-a"))
    let envB = defaultEnvironmentFingerprint(Workspace, providerInfo("env-b"))
    discard store.upsertCatalogItem(alpha, envA)
    discard store.upsertCatalogItem(alpha, envB)
    store.updateFromEvent(event(tekTestFinished, alpha.id,
      status = some(tsPassed),
      traceValue = some(trace(root / "trace-a"))), envA)
    store.updateFromEvent(event(tekTestFinished, alpha.id,
      status = some(tsFailed),
      traceValue = some(trace(root / "trace-b"))), envB)

    let reopened = openLocalRunStore(root)
    check reopened.getLastResult(alpha.id, envA).get.status == tescPassed
    check reopened.getLastResult(alpha.id, envB).get.status == tescFailed

  test "stale_catalog_item_hydrates_last_result_but_exposes_no_editor_actions":
    let root = tempRoot("stale")
    let store = openLocalRunStore(root)
    let staleAlpha = item(FileA, "alpha", "tests/test_alpha.nim::alpha", 10)
    let env = defaultEnvironmentFingerprint(Workspace, providerInfo())
    discard store.upsertCatalogItem(staleAlpha, env)
    store.updateFromEvent(event(tekTestFinished, staleAlpha.id,
      status = some(tsPassed),
      traceValue = some(trace(root / "stale-trace"))), env)

    var refreshed = staleAlpha
    refreshed.stale = true
    refreshed.staleReason = "deleted from file"
    let (vm, _, _) = newVmWithStore(openLocalRunStore(root))
    vm.ingestCatalog(catalog(@[refreshed]))

    check vm.runStates[staleAlpha.id].status == tesPassed
    check vm.runStates[staleAlpha.id].trace.get.path == root / "stale-trace"
    check vm.editorActionsForFile(FileA).len == 0
