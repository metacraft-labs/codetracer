## Headless ViewModel state for CodeTracer test discovery and execution.
##
## This module intentionally contains no rendering logic.  It converts the
## normalized ct-test contracts into per-file editor action records and tracks
## run/record event state for GUI consumers.

import std/[json, options, strutils, tables]

import ../../../ct_test/[contracts, run_store]

type
  TestExplorerActionKind* = enum
    teakRunTest = "run-test"
    teakRecordTest = "record-test"

  TestExplorerStatus* = enum
    tesIdle = "idle"
    tesRunning = "running"
    tesRecording = "recording"
    tesPassed = "passed"
    tesFailed = "failed"
    tesSkipped = "skipped"
    tesErrored = "errored"
    tesCancelled = "cancelled"

  TraceOpenPolicy* = enum
    topCurrentTab = "current-tab"
    topNewTab = "new-tab"

  CtTestCommand* = object
    argv*: seq[string]

  CtTestService* = ref object
    sendProc*: proc(command: CtTestCommand)

  TraceOpenRequest* = object
    tracePath*: string
    traceId*: string
    recordingId*: string
    testId*: string
    policy*: TraceOpenPolicy

  TraceOpenService* = ref object
    openProc*: proc(request: TraceOpenRequest)

  EditorTestAction* = object
    kind*: TestExplorerActionKind
    testId*: string
    selector*: string
    file*: string
    line*: int
    range*: SourceRange
    command*: CtTestCommand

  TestExplorerDiagnostics* = object
    diagnostics*: seq[TestDiagnostic]

  TestRunState* = object
    status*: TestExplorerStatus
    output*: string
    durationMs*: int
    diagnostics*: seq[TestDiagnostic]
    trace*: Option[TraceMetadata]

  TestCatalogState* = object
    catalog*: TestCatalog
    actions*: seq[EditorTestAction]

  TestExplorerViewModel* = ref object
    workspaceRoot*: string
    ctTest*: CtTestService
    traceOpen*: TraceOpenService
    runStore*: LocalRunStore
    catalogsByFile*: Table[string, TestCatalogState]
    runStates*: Table[string, TestRunState]
    runOpenPolicies*: Table[string, TraceOpenPolicy]
    environmentFingerprints*: Table[string, string]
    diagnostics*: seq[TestDiagnostic]

proc command*(args: varargs[string]): CtTestCommand =
  CtTestCommand(argv: @args)

proc buildDiscoverWorkspaceCommand*(workspaceRoot: string): CtTestCommand =
  command("ct", "test", "discover", "--workspace", workspaceRoot, "--json")

proc buildDiscoverFileCommand*(workspaceRoot, file: string): CtTestCommand =
  command("ct", "test", "discover", "--workspace", workspaceRoot, "--file",
      file, "--json")

proc buildRunSelectorCommand*(selector: string): CtTestCommand =
  command("ct", "test", "run", "--selector", selector, "--json-events")

proc buildRecordSelectorCommand*(selector: string;
    policy: TraceOpenPolicy): CtTestCommand =
  command("ct", "test", "record", "--selector", selector, "--json-events",
      "--open-policy=" & $policy)

proc buildRunFileCommand*(file: string): CtTestCommand =
  command("ct", "test", "run", "--file", file, "--json-events")

proc buildRecordFileCommand*(file: string;
    policy: TraceOpenPolicy): CtTestCommand =
  command("ct", "test", "record", "--file", file, "--json-events",
      "--open-policy=" & $policy)

proc send*(service: CtTestService; command: CtTestCommand) =
  if not service.isNil and not service.sendProc.isNil:
    service.sendProc(command)

proc openTrace*(service: TraceOpenService; request: TraceOpenRequest) =
  if not service.isNil and not service.openProc.isNil:
    service.openProc(request)

proc createTestExplorerViewModel*(
    workspaceRoot: string;
    ctTest: CtTestService;
    traceOpen: TraceOpenService;
    runStore: LocalRunStore = nil): TestExplorerViewModel =
  TestExplorerViewModel(
    workspaceRoot: workspaceRoot,
    ctTest: ctTest,
    traceOpen: traceOpen,
    runStore: runStore,
    catalogsByFile: initTable[string, TestCatalogState](),
    runStates: initTable[string, TestRunState](),
    runOpenPolicies: initTable[string, TraceOpenPolicy](),
    environmentFingerprints: initTable[string, string](),
    diagnostics: @[])

proc toExplorerStatus(status: TestResultStatus): TestExplorerStatus =
  case status
  of tsPassed: tesPassed
  of tsFailed: tesFailed
  of tsSkipped: tesSkipped
  of tsErrored: tesErrored

proc defaultRunState(): TestRunState =
  TestRunState(
    status: tesIdle,
    output: "",
    durationMs: 0,
    diagnostics: @[],
    trace: none(TraceMetadata))

proc toViewModelStatus(status: TestExplorerStatusCompat): TestExplorerStatus =
  case status
  of tescIdle: tesIdle
  of tescRunning: tesRunning
  of tescRecording: tesRecording
  of tescPassed: tesPassed
  of tescFailed: tesFailed
  of tescSkipped: tesSkipped
  of tescErrored: tesErrored
  of tescCancelled: tesCancelled

proc toRunState(record: RunRecord): TestRunState =
  TestRunState(
    status: toViewModelStatus(record.status),
    output: record.outputTail,
    durationMs: record.durationMs,
    diagnostics: @[],
    trace: record.trace)

proc envFor(vm: TestExplorerViewModel; catalog: TestCatalog): string =
  defaultEnvironmentFingerprint(vm.workspaceRoot, catalog.provider)

proc hydrateFromStore(vm: TestExplorerViewModel; item: TestItem; env: string) =
  if vm.runStore.isNil:
    return
  vm.environmentFingerprints[item.id] = env
  discard vm.runStore.upsertCatalogItem(item, env)
  let record = vm.runStore.getLastResult(item.id, env)
  if record.isSome:
    vm.runStates[item.id] = record.get.toRunState

proc persistEvent(vm: TestExplorerViewModel; event: TestEvent) =
  if vm.runStore.isNil or event.testId.len == 0:
    return
  let env = vm.environmentFingerprints.getOrDefault(event.testId, "")
  if env.len > 0:
    vm.runStore.updateFromEvent(event, env)

proc stateFor(vm: TestExplorerViewModel; testId: string): TestRunState =
  vm.runStates.getOrDefault(testId, defaultRunState())

proc putState(vm: TestExplorerViewModel; testId: string; state: TestRunState) =
  if testId.len > 0:
    vm.runStates[testId] = state

proc actionFor(
    kind: TestExplorerActionKind;
    item: TestItem;
    policy: TraceOpenPolicy): EditorTestAction =
  let command =
    case kind
    of teakRunTest:
      buildRunSelectorCommand(item.selector)
    of teakRecordTest:
      buildRecordSelectorCommand(item.selector, policy)
  EditorTestAction(
    kind: kind,
    testId: item.id,
    selector: item.selector,
    file: item.file,
    line: item.range.startLine,
    range: item.range,
    command: command)

proc actionsFor(catalog: TestCatalog; policy: TraceOpenPolicy): seq[
    EditorTestAction] =
  result = @[]
  for item in catalog.items:
    if item.stale:
      continue
    if catalog.provider.capabilities.canRunSingle:
      result.add actionFor(teakRunTest, item, policy)
    if catalog.provider.capabilities.canRecordSingle:
      result.add actionFor(teakRecordTest, item, policy)

proc ingestCatalog*(vm: TestExplorerViewModel; catalog: TestCatalog;
                    policy = topCurrentTab) =
  ## Replace only the per-file catalog/action state represented by `catalog`.
  ## Run/trace state is intentionally independent and is preserved.
  var grouped = initTable[string, seq[TestItem]]()
  for item in catalog.items:
    var items = grouped.getOrDefault(item.file, @[])
    items.add item
    grouped[item.file] = items

  for file, items in grouped:
    var fileCatalog = catalog
    fileCatalog.items = items
    let env = vm.envFor(fileCatalog)
    for item in items:
      vm.hydrateFromStore(item, env)
    vm.catalogsByFile[file] = TestCatalogState(
      catalog: fileCatalog,
      actions: actionsFor(fileCatalog, policy))

  for diagnostic in catalog.diagnostics:
    vm.diagnostics.add diagnostic

proc ingestFileCatalog*(vm: TestExplorerViewModel; file: string;
    catalog: TestCatalog; policy = topCurrentTab) =
  ## Replace catalog/action state for one refreshed editor file, including the
  ## empty-catalog case where a file no longer contains runnable tests.
  var fileCatalog = catalog
  var items: seq[TestItem] = @[]
  for item in catalog.items:
    if item.file == file:
      items.add item
  fileCatalog.items = items
  let env = vm.envFor(fileCatalog)
  for item in items:
    vm.hydrateFromStore(item, env)
  if items.len == 0:
    vm.catalogsByFile.del file
  else:
    vm.catalogsByFile[file] = TestCatalogState(
      catalog: fileCatalog,
      actions: actionsFor(fileCatalog, policy))

  for diagnostic in catalog.diagnostics:
    vm.diagnostics.add diagnostic

proc editorActionsForFile*(vm: TestExplorerViewModel; file: string): seq[
    EditorTestAction] =
  if vm.catalogsByFile.hasKey(file):
    vm.catalogsByFile[file].actions
  else:
    @[]

proc discoverWorkspace*(vm: TestExplorerViewModel) =
  vm.ctTest.send buildDiscoverWorkspaceCommand(vm.workspaceRoot)

proc discoverFile*(vm: TestExplorerViewModel; file: string) =
  vm.ctTest.send buildDiscoverFileCommand(vm.workspaceRoot, file)

proc runSelector*(vm: TestExplorerViewModel; selector: string) =
  vm.ctTest.send buildRunSelectorCommand(selector)

proc recordSelector*(vm: TestExplorerViewModel; selector: string;
    policy = topCurrentTab) =
  vm.ctTest.send buildRecordSelectorCommand(selector, policy)

proc runFile*(vm: TestExplorerViewModel; file: string) =
  vm.ctTest.send buildRunFileCommand(file)

proc recordFile*(vm: TestExplorerViewModel; file: string;
    policy = topCurrentTab) =
  vm.ctTest.send buildRecordFileCommand(file, policy)

proc runTest*(vm: TestExplorerViewModel; testId: string) =
  for _, catalogState in vm.catalogsByFile:
    for item in catalogState.catalog.items:
      if item.id == testId:
        vm.runSelector(item.selector)
        return

proc recordTest*(vm: TestExplorerViewModel; testId: string;
    policy = topCurrentTab) =
  for _, catalogState in vm.catalogsByFile:
    for item in catalogState.catalog.items:
      if item.id == testId:
        vm.recordSelector(item.selector, policy)
        return

proc openLastTrace*(vm: TestExplorerViewModel; testId: string;
                    policy = topCurrentTab): bool =
  var trace = none(TraceMetadata)
  if vm.runStates.hasKey(testId):
    trace = vm.runStates[testId].trace
  if trace.isNone and not vm.runStore.isNil:
    let env = vm.environmentFingerprints.getOrDefault(testId, "")
    if env.len > 0:
      trace = vm.runStore.getLastTrace(testId, env)
  if trace.isNone:
    return false
  let value = trace.get
  vm.traceOpen.openTrace TraceOpenRequest(
    tracePath: value.path,
    traceId: value.traceId,
    recordingId: value.recordingId,
    testId: testId,
    policy: policy)
  true

proc rememberOpenPolicy(vm: TestExplorerViewModel; event: TestEvent;
                        policy: TraceOpenPolicy) =
  if event.runId.len > 0:
    vm.runOpenPolicies[event.runId] = policy

proc handleEvent*(vm: TestExplorerViewModel; event: TestEvent;
                  defaultOpenPolicy = topCurrentTab) =
  vm.persistEvent(event)

  if event.testId.len == 0:
    if event.diagnostic.isSome:
      vm.diagnostics.add event.diagnostic.get
    elif event.message.len > 0 and event.kind == tekDiagnostic:
      vm.diagnostics.add TestDiagnostic(
        severity: dsError,
        message: event.message,
        file: "",
        range: none(SourceRange))
    return

  var state = vm.stateFor(event.testId)

  case event.kind
  of tekRunStarted, tekTestStarted:
    state.status = tesRunning
  of tekRecordStarted:
    state.status = tesRecording
    vm.rememberOpenPolicy(event, defaultOpenPolicy)
  of tekOutput:
    if event.output.len > 0:
      if state.output.len > 0 and not state.output.endsWith("\n"):
        state.output.add "\n"
      state.output.add event.output
  of tekFailure:
    state.status = tesFailed
    if event.diagnostic.isSome:
      state.diagnostics.add event.diagnostic.get
    elif event.message.len > 0:
      state.diagnostics.add TestDiagnostic(
        severity: dsError,
        message: event.message,
        file: "",
        range: none(SourceRange))
  of tekCancellation:
    state.status = tesCancelled
    if event.message.len > 0:
      state.diagnostics.add TestDiagnostic(
        severity: dsWarning,
        message: event.message,
        file: "",
        range: none(SourceRange))
  of tekTestFinished, tekRunFinished, tekRecordFinished:
    if event.status.isSome:
      state.status = toExplorerStatus(event.status.get)
    state.durationMs = event.durationMs
    if event.trace.isSome:
      state.trace = event.trace
  of tekRecordingCreated:
    if event.trace.isSome:
      let trace = event.trace.get
      state.trace = some(trace)
      let policy = vm.runOpenPolicies.getOrDefault(
        event.runId, defaultOpenPolicy)
      vm.traceOpen.openTrace TraceOpenRequest(
        tracePath: trace.path,
        traceId: trace.traceId,
        recordingId: trace.recordingId,
        testId: event.testId,
        policy: policy)
  of tekDiagnostic:
    if event.diagnostic.isSome:
      state.diagnostics.add event.diagnostic.get
    elif event.message.len > 0:
      state.diagnostics.add TestDiagnostic(
        severity: dsError,
        message: event.message,
        file: "",
        range: none(SourceRange))
  of tekDiscoveryStarted, tekDiscoveryFinished:
    discard

  vm.putState(event.testId, state)

proc handleJsonEventLine*(vm: TestExplorerViewModel; line: string;
                          defaultOpenPolicy = topCurrentTab) =
  let stripped = line.strip
  if stripped.len == 0:
    return
  try:
    vm.handleEvent(testEventFromJson(parseJson(stripped)), defaultOpenPolicy)
  except CatchableError as e:
    vm.diagnostics.add TestDiagnostic(
      severity: dsError,
      message: "invalid ct test event JSON: " & e.msg,
      file: "",
      range: none(SourceRange))
