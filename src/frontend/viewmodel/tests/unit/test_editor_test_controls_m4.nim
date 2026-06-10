## Headless tests for M4 ct-test editor control placement/rendering.
##
## Compile and run:
##   nim c -r src/frontend/viewmodel/tests/unit/test_editor_test_controls_m4.nim

import std/[options, os, strutils, tables, unittest]

import isonim/testing/mock_dom
import isonim/viewmodel

import ../../../../ct_test/[contracts, run_store]
import ../../backend/mock_backend
import ../../store/replay_data_store
import ../../viewmodels/[editor_test_controls_vm, editor_vm, test_explorer_vm]
import ../../views/[isonim_editor_test_controls_view, isonim_editor_view]

const
  Workspace = "/repo"
  FileA = "tests/test_alpha.nim"
  ProviderId = "nim-unittest"

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

proc providerInfo(): TestProviderInfo =
  TestProviderInfo(
    id: ProviderId,
    language: "nim",
    framework: "std/unittest",
    displayName: "Nim unittest",
    version: "m4-fixture",
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
      detail: "M4 fixture",
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
    traceValue = none(TraceMetadata);
    status = none(TestResultStatus)): TestEvent =
  TestEvent(
    schemaVersion: TestEventSchemaVersion,
    kind: kind,
    providerId: ProviderId,
    runId: "run-1",
    testId: testId,
    status: status,
    message: "",
    output: "",
    durationMs: 0,
    trace: traceValue,
    diagnostic: none(TestDiagnostic))

proc newVmWith(items: seq[TestItem]): TestExplorerViewModel =
  result = createTestExplorerViewModel(
    Workspace,
    CtTestService(sendProc: proc(command: CtTestCommand) = discard),
    TraceOpenService(openProc: proc(request: TraceOpenRequest) = discard))
  result.ingestCatalog(catalog(items))

proc newVmWith(items: seq[TestItem]; store: LocalRunStore):
    TestExplorerViewModel =
  result = createTestExplorerViewModel(
    Workspace,
    CtTestService(sendProc: proc(command: CtTestCommand) = discard),
    TraceOpenService(openProc: proc(request: TraceOpenRequest) = discard),
    store)
  result.ingestCatalog(catalog(items))

proc tempRoot(name: string): string =
  result = getTempDir() / ("codetracer-controls-m14-" & name & "-" &
      $getCurrentProcessId())
  if dirExists(result):
    removeDir(result)
  createDir(result)

proc collectByAttr(node: MockNode; attr, value: string;
    outNodes: var seq[MockNode]) =
  if node.kind == mnkElement and
      node.attributes.getOrDefault(attr, "") == value:
    outNodes.add node
  for child in node.children:
    collectByAttr(child, attr, value, outNodes)

proc nodesByAttr(node: MockNode; attr, value: string): seq[MockNode] =
  collectByAttr(node, attr, value, result)

proc firstByAttr(node: MockNode; attr, value: string): MockNode =
  let nodes = nodesByAttr(node, attr, value)
  if nodes.len == 0: nil else: nodes[0]

proc attr(node: MockNode; name: string): string =
  node.attributes.getOrDefault(name, "")

suite "ct-test editor controls M4":

  test "m15_default_placement_is_gutter":
    let alpha = item(FileA, "alpha", "tests/test_alpha.nim::alpha", 12)
    let vm = newVmWith(@[alpha])
    let plan = vm.editorTestControlPlanForFile(FileA)

    check DefaultEditorTestControlSettings.placement == etcpGutter
    check plan.placement == etcpGutter
    check plan.controls.len == 1
    check plan.controls[0].surface == etcsGutter

  test "controls_render_for_file_with_known_test_actions_on_expected_lines":
    let alpha = item(FileA, "alpha", "tests/test_alpha.nim::alpha", 12)
    let beta = item(FileA, "beta", "tests/test_alpha.nim::beta", 24)
    let vm = newVmWith(@[alpha, beta])
    let plan = vm.editorTestControlPlanForFile(
      FileA,
      EditorTestControlSettings(placement: etcpGutter))

    check plan.controls.len == 2
    check plan.controls[0].line == 12
    check plan.controls[1].line == 24

    let r = MockRenderer()
    let dom = r.renderEditorTestControls(plan)
    let controls = nodesByAttr(dom, "data-ct-test-control", "true")
    check controls.len == 2
    check controls[0].attr("data-ct-test-line") == "12"
    check controls[1].attr("data-ct-test-line") == "24"
    check controls[0].attr("data-ct-test-surface") == "gutter"

  test "gutter_controls_shift_to_secondary_slot_when_line_markers_conflict":
    let alpha = item(FileA, "alpha", "tests/test_alpha.nim::alpha", 12)
    let vm = newVmWith(@[alpha])
    let plan = vm.editorTestControlPlanForFile(
      FileA,
      EditorTestControlSettings(placement: etcpGutter),
      markers = @[
        EditorLineMarker(line: 12, kind: elmDiagnostic),
        EditorLineMarker(line: 12, kind: elmFolding),
        EditorLineMarker(line: 12, kind: elmCurrentExecution),
        EditorLineMarker(line: 12, kind: elmTracepoint),
        EditorLineMarker(line: 12, kind: elmBreakpoint)])

    check plan.controls.len == 1
    check plan.controls[0].gutterSlot == etgsSecondary
    check plan.controls[0].collisionMarkers == @[
      elmBreakpoint, elmTracepoint, elmCurrentExecution, elmFolding,
      elmDiagnostic]

    let r = MockRenderer()
    let dom = r.renderEditorTestControls(plan)
    let control = firstByAttr(dom, "data-ct-test-control", "true")
    check control.attr("data-ct-test-gutter-slot") == "secondary"
    check control.attr("data-ct-test-collision-markers") ==
      "breakpoint,tracepoint,current-execution,folding,diagnostic"

  test "above_line_controls_preserve_scroll_anchor_model_value":
    let alpha = item(FileA, "alpha", "tests/test_alpha.nim::alpha", 12)
    let vm = newVmWith(@[alpha])
    let plan = vm.editorTestControlPlanForFile(
      FileA,
      EditorTestControlSettings(placement: etcpAboveLine),
      scrollAnchor = 42)

    check plan.scrollAnchorBefore == 42
    check plan.scrollAnchorAfter == 42
    check plan.controls.len == 1
    check plan.controls[0].surface == etcsAboveLine

    let r = MockRenderer()
    let dom = r.renderEditorTestControls(plan)
    check dom.attr("data-ct-test-scroll-anchor-before") == "42"
    check dom.attr("data-ct-test-scroll-anchor-after") == "42"

  test "disabled_placement_renders_no_controls":
    let alpha = item(FileA, "alpha", "tests/test_alpha.nim::alpha", 12)
    let vm = newVmWith(@[alpha])
    let plan = vm.editorTestControlPlanForFile(
      FileA,
      EditorTestControlSettings(placement: etcpDisabled))

    check plan.controls.len == 0

    let r = MockRenderer()
    let dom = r.renderEditorTestControls(plan)
    check nodesByAttr(dom, "data-ct-test-control", "true").len == 0

  test "both_placement_renders_gutter_and_above_line_surfaces":
    let alpha = item(FileA, "alpha", "tests/test_alpha.nim::alpha", 12)
    let vm = newVmWith(@[alpha])
    let plan = vm.editorTestControlPlanForFile(
      FileA,
      EditorTestControlSettings(placement: etcpBoth))

    check plan.controls.len == 2
    check plan.controls[0].surface == etcsGutter
    check plan.controls[1].surface == etcsAboveLine

    let r = MockRenderer()
    let dom = r.renderEditorTestControls(plan)
    check nodesByAttr(dom, "data-ct-test-surface", "gutter").len == 1
    check nodesByAttr(dom, "data-ct-test-surface", "above-line").len == 1

  test "accessibility_labels_and_command_names_exist_for_primary_actions":
    let alpha = item(FileA, "alpha", "tests/test_alpha.nim::alpha", 12)
    let vm = newVmWith(@[alpha])
    vm.handleEvent(event(tekTestFinished, alpha.id,
      traceValue = some(trace("/repo/.codetracer/alpha.trace")),
      status = some(tsPassed)))
    let plan = vm.editorTestControlPlanForFile(
      FileA,
      EditorTestControlSettings(placement: etcpAboveLine))

    let r = MockRenderer()
    let dom = r.renderEditorTestControls(plan)
    let run = firstByAttr(dom, "data-ct-test-action", "run")
    let record = firstByAttr(dom, "data-ct-test-action", "record")
    let openLastTrace = firstByAttr(
      dom, "data-ct-test-action", "open-last-trace")
    let status = firstByAttr(dom, "data-ct-test-action", "status")

    check run.attr("data-ct-test-command") == "ct.test.run"
    check record.attr("data-ct-test-command") == "ct.test.record"
    check openLastTrace.attr("data-ct-test-command") == "ct.test.openLastTrace"
    check status.attr("data-ct-test-command") == "ct.test.status"
    check status.attr("data-ct-test-status") == "passed"
    check run.attr("aria-label") == "Run test " & alpha.id
    check record.attr("aria-label") == "Record test " & alpha.id
    check openLastTrace.attr("aria-label") == "Open last test trace " & alpha.id
    check status.attr("aria-label") == "Test status passed for " & alpha.id

  test "m15_keyboard_and_accessibility_metadata_for_all_control_surfaces":
    let alpha = item(FileA, "alpha", "tests/test_alpha.nim::alpha", 12)
    let vm = newVmWith(@[alpha])
    vm.handleEvent(event(tekTestFinished, alpha.id,
      traceValue = some(trace("/repo/.codetracer/alpha.trace")),
      status = some(tsPassed)))
    let plan = vm.editorTestControlPlanForFile(
      FileA,
      EditorTestControlSettings(placement: etcpBoth))

    let r = MockRenderer()
    let dom = r.renderEditorTestControls(plan)
    for surface in ["gutter", "above-line"]:
      let surfaceControls = nodesByAttr(dom, "data-ct-test-surface", surface)
      check surfaceControls.len == 1
      for action in ["run", "record", "open-last-trace", "status"]:
        let node = firstByAttr(surfaceControls[0], "data-ct-test-action",
          action)
        check node != nil
        check node.attr("aria-label").len > 0
        check node.attr("title") == node.attr("aria-label")
        check node.attr("data-ct-test-command").startsWith("ct.test.")
      check firstByAttr(surfaceControls[0], "data-ct-test-action", "run").
        attr("data-ct-test-enabled") == "true"
      check firstByAttr(surfaceControls[0], "data-ct-test-action", "record").
        attr("data-ct-test-enabled") == "true"
      check firstByAttr(surfaceControls[0], "data-ct-test-action", "status").
        attr("data-ct-test-enabled") == "false"

  test "editor_container_default_and_disabled_plans_render_no_test_controls":
    let mock = newMockBackendService(autoRespond = true)
    let store = createReplayDataStore(mock.toBackendService())
    let editor = createEditorVM(store)
    let r = MockRenderer()

    let defaultDom = r.renderEditorContainer(
      editor, 0, FileA, isExpansion = false, expansionDepth = 0)
    check nodesByAttr(defaultDom, "data-ct-test-controls", "true").len == 0

    let staleDisabledPlan = EditorTestControlRenderPlan(
      file: FileA,
      placement: etcpDisabled,
      scrollAnchorBefore: 7,
      scrollAnchorAfter: 7,
      controls: @[EditorTestControl(
        testId: "stale",
        selector: "stale",
        file: FileA,
        line: 12,
        surface: etcsGutter,
        gutterSlot: etgsPrimary,
        collisionMarkers: @[],
        actions: @[])])
    let disabledDom = r.renderEditorContainer(
      editor, 0, FileA, isExpansion = false, expansionDepth = 0,
      testControls = staleDisabledPlan)
    check nodesByAttr(disabledDom, "data-ct-test-controls", "true").len == 0

    editor.dispose()
    store.dispose()

  test "editor_control_last_result_and_last_trace_state_after_reload":
    let root = tempRoot("reload")
    let store = openLocalRunStore(root)
    let alpha = item(FileA, "alpha", "tests/test_alpha.nim::alpha", 12)
    let env = defaultEnvironmentFingerprint(Workspace, providerInfo())
    discard store.upsertCatalogItem(alpha, env)
    store.updateFromEvent(event(tekTestFinished, alpha.id,
      traceValue = some(trace(root / "alpha.trace")),
      status = some(tsPassed)), env)

    let vm = newVmWith(@[alpha], openLocalRunStore(root))
    let plan = vm.editorTestControlPlanForFile(
      FileA,
      EditorTestControlSettings(placement: etcpAboveLine))

    let r = MockRenderer()
    let dom = r.renderEditorTestControls(plan)
    let openLastTrace = firstByAttr(
      dom, "data-ct-test-action", "open-last-trace")
    let status = firstByAttr(dom, "data-ct-test-action", "status")

    check openLastTrace != nil
    check openLastTrace.attr("data-ct-test-command") == "ct.test.openLastTrace"
    check status.attr("data-ct-test-status") == "passed"
