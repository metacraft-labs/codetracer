## Editor-facing placement model for ct-test controls.
##
## This layer consumes the normalized M3 TestExplorerViewModel editor actions
## and produces compact render records for gutter and above-line editor
## surfaces. It intentionally contains no Monaco/browser-specific logic.

import std/[algorithm, options, sequtils, sets, tables]

import ./test_explorer_vm

type
  EditorTestControlPlacement* = enum
    etcpGutter = "gutter"
    etcpAboveLine = "above-line"
    etcpBoth = "both"
    etcpDisabled = "disabled"

  EditorTestControlSurface* = enum
    etcsGutter = "gutter"
    etcsAboveLine = "above-line"

  EditorTestGutterSlot* = enum
    etgsPrimary = "primary"
    etgsSecondary = "secondary"

  EditorTestControlActionKind* = enum
    etcakRun = "run"
    etcakRecord = "record"
    etcakOpenLastTrace = "open-last-trace"
    etcakStatus = "status"

  EditorLineMarkerKind* = enum
    elmBreakpoint = "breakpoint"
    elmTracepoint = "tracepoint"
    elmCurrentExecution = "current-execution"
    elmFolding = "folding"
    elmDiagnostic = "diagnostic"

  EditorLineMarker* = object
    line*: int
    kind*: EditorLineMarkerKind

  EditorTestControlAction* = object
    kind*: EditorTestControlActionKind
    commandName*: string
    ariaLabel*: string
    enabled*: bool
    status*: string

  EditorTestControl* = object
    testId*: string
    selector*: string
    file*: string
    line*: int
    surface*: EditorTestControlSurface
    gutterSlot*: EditorTestGutterSlot
    collisionMarkers*: seq[EditorLineMarkerKind]
    actions*: seq[EditorTestControlAction]

  EditorTestControlSettings* = object
    placement*: EditorTestControlPlacement

  EditorTestControlRenderPlan* = object
    file*: string
    placement*: EditorTestControlPlacement
    scrollAnchorBefore*: int
    scrollAnchorAfter*: int
    controls*: seq[EditorTestControl]

const
  DefaultEditorTestControlSettings* = EditorTestControlSettings(
    placement: etcpGutter)

proc commandName*(kind: EditorTestControlActionKind): string =
  case kind
  of etcakRun: "ct.test.run"
  of etcakRecord: "ct.test.record"
  of etcakOpenLastTrace: "ct.test.openLastTrace"
  of etcakStatus: "ct.test.status"

proc `$`*(placement: EditorTestControlPlacement): string =
  case placement
  of etcpGutter: "gutter"
  of etcpAboveLine: "above-line"
  of etcpBoth: "both"
  of etcpDisabled: "disabled"

proc `$`*(surface: EditorTestControlSurface): string =
  case surface
  of etcsGutter: "gutter"
  of etcsAboveLine: "above-line"

proc `$`*(slot: EditorTestGutterSlot): string =
  case slot
  of etgsPrimary: "primary"
  of etgsSecondary: "secondary"

proc `$`*(kind: EditorTestControlActionKind): string =
  case kind
  of etcakRun: "run"
  of etcakRecord: "record"
  of etcakOpenLastTrace: "open-last-trace"
  of etcakStatus: "status"

proc `$`*(kind: EditorLineMarkerKind): string =
  case kind
  of elmBreakpoint: "breakpoint"
  of elmTracepoint: "tracepoint"
  of elmCurrentExecution: "current-execution"
  of elmFolding: "folding"
  of elmDiagnostic: "diagnostic"

proc markerPriority(kind: EditorLineMarkerKind): int =
  case kind
  of elmBreakpoint: 10
  of elmTracepoint: 20
  of elmCurrentExecution: 30
  of elmFolding: 40
  of elmDiagnostic: 50

proc collisionMarkersForLine(markers: seq[EditorLineMarker];
                             line: int): seq[EditorLineMarkerKind] =
  var seen = initHashSet[EditorLineMarkerKind]()
  for marker in markers:
    if marker.line == line and marker.kind notin seen:
      seen.incl marker.kind
      result.add marker.kind
  result.sort proc(a, b: EditorLineMarkerKind): int =
    cmp(markerPriority(a), markerPriority(b))

proc actionLabel(kind: EditorTestControlActionKind; testId: string;
                 status = ""): string =
  case kind
  of etcakRun:
    "Run test " & testId
  of etcakRecord:
    "Record test " & testId
  of etcakOpenLastTrace:
    "Open last test trace " & testId
  of etcakStatus:
    "Test status " & status & " for " & testId

proc compactActionsForTest(vm: TestExplorerViewModel;
                           actions: seq[EditorTestAction];
                           testId: string): seq[EditorTestControlAction] =
  var hasRun = false
  var hasRecord = false
  for action in actions:
    if action.testId != testId:
      continue
    case action.kind
    of teakRunTest:
      hasRun = true
    of teakRecordTest:
      hasRecord = true

  if hasRun:
    result.add EditorTestControlAction(
      kind: etcakRun,
      commandName: commandName(etcakRun),
      ariaLabel: actionLabel(etcakRun, testId),
      enabled: true,
      status: "")
  if hasRecord:
    result.add EditorTestControlAction(
      kind: etcakRecord,
      commandName: commandName(etcakRecord),
      ariaLabel: actionLabel(etcakRecord, testId),
      enabled: true,
      status: "")

  let state = vm.runStates.getOrDefault(testId, default(TestRunState))
  let status = if vm.runStates.hasKey(testId): $state.status else: "idle"
  if state.trace.isSome:
    result.add EditorTestControlAction(
      kind: etcakOpenLastTrace,
      commandName: commandName(etcakOpenLastTrace),
      ariaLabel: actionLabel(etcakOpenLastTrace, testId),
      enabled: true,
      status: "")

  result.add EditorTestControlAction(
    kind: etcakStatus,
    commandName: commandName(etcakStatus),
    ariaLabel: actionLabel(etcakStatus, testId, status),
    enabled: false,
    status: status)

proc baseControlsForFile(vm: TestExplorerViewModel; file: string;
                         markers: seq[EditorLineMarker]):
                         seq[EditorTestControl] =
  let actions = vm.editorActionsForFile(file)
  var byTest = initTable[string, EditorTestAction]()
  for action in actions:
    if not byTest.hasKey(action.testId):
      byTest[action.testId] = action

  for testId, firstAction in byTest:
    let collisions = collisionMarkersForLine(markers, firstAction.line)
    result.add EditorTestControl(
      testId: testId,
      selector: firstAction.selector,
      file: firstAction.file,
      line: firstAction.line,
      surface: etcsGutter,
      gutterSlot: if collisions.len == 0: etgsPrimary else: etgsSecondary,
      collisionMarkers: collisions,
      actions: compactActionsForTest(vm, actions, testId))

  result.sort proc(a, b: EditorTestControl): int =
    result = cmp(a.line, b.line)
    if result == 0:
      result = cmp(a.testId, b.testId)

proc editorTestControlPlanForFile*(
    vm: TestExplorerViewModel;
    file: string;
    settings = DefaultEditorTestControlSettings;
    markers: seq[EditorLineMarker] = @[];
    scrollAnchor = 0): EditorTestControlRenderPlan =
  result = EditorTestControlRenderPlan(
    file: file,
    placement: settings.placement,
    scrollAnchorBefore: scrollAnchor,
    scrollAnchorAfter: scrollAnchor,
    controls: @[])

  if settings.placement == etcpDisabled:
    return

  let baseControls = baseControlsForFile(vm, file, markers)
  for control in baseControls:
    case settings.placement
    of etcpGutter:
      var gutter = control
      gutter.surface = etcsGutter
      result.controls.add gutter
    of etcpAboveLine:
      var above = control
      above.surface = etcsAboveLine
      result.controls.add above
    of etcpBoth:
      var gutter = control
      gutter.surface = etcsGutter
      result.controls.add gutter
      var above = control
      above.surface = etcsAboveLine
      result.controls.add above
    of etcpDisabled:
      discard

proc controlsForSurface*(plan: EditorTestControlRenderPlan;
                         surface: EditorTestControlSurface):
                         seq[EditorTestControl] =
  plan.controls.filterIt(it.surface == surface)
