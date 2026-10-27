## Step List panel — linear list of recently-executed source lines
## around the current debugger position.
##
## ---------------------------------------------------------------------------
## ViewModel layer — IsoNim is the primary renderer.
##
## The legacy Karax ``method render`` was dropped in favour of an IsoNim
## view (``viewmodel/views/isonim_step_list_view.nim``) that the panel host
## (``ui/panel_host``) mounts into the GoldenLayout container.  The legacy
## ``StepListComponent`` retains its event-bus subscriptions so the
## frontend's existing wiring (``CtCompleteMove`` → re-fetch step lines,
## ``updated-load-step-lines`` IPC → append-and-sort) keeps feeding
## data; the component now mirrors every update into a ``StepListVM``
## whose signals drive the IsoNim view.
## ---------------------------------------------------------------------------

import ui_imports, value, session_viewmodels, ../[types, utils, communication]

import std/algorithm
import ./presented_value
from ../viewmodel/store/types as vmtypes import
  StepLine, StepLineKind, StepLineLocation, StepLineFlowValue
from ../viewmodel/viewmodels/step_list_vm import
  StepListVM,
  setLineSteps, appendLineSteps, clearLineSteps,
  setCurrentLocation, setViewport, Viewport,
  loadStepLinesFor, jumpToStepLine, DEFAULT_STEP_LIST_PANEL_HEIGHT

const STEP_LINE_HEIGHT_PX = 26

# The session's ViewModel and the registered component, so the legacy
# event-bus handlers can feed the one and replay the other.
var stepListVMInstance*: StepListVM
  ## The SHOWN tab's StepListVM; a component's handlers feed their own
  ## tab's (`paneVM`).
var stepListComponentRef: StepListComponent

proc paneVM(self: StepListComponent): StepListVM =
  ## The StepListVM of the tab that holds `self` (`ownPaneVM`).
  ownPaneVM(self, stepListVMInstance, stepListVM)


# ---------------------------------------------------------------------------
# Legacy → VM translation helpers.
# ---------------------------------------------------------------------------

proc safeStr(s: cstring): string =
  ## Convert a possibly-null cstring to an empty string.  Mirrors the
  ## helper used by build / errors / search_results — E2E paths can land
  ## a null cstring in the legacy record, and naive ``$`` would throw
  ## inside ``cstrToNimstr``.
  if s.isNil:
    ""
  else:
    $s

proc lineStepKindToVm(kind: LineStepKind): StepLineKind =
  ## Map the ``LineStepKind`` (legacy ``{.pure.}`` enum) to the
  ## platform-neutral ``StepLineKind`` exposed by the ViewModel layer.
  case kind
  of LineStepKind.Line: slkLine
  of LineStepKind.Call: slkCall
  of LineStepKind.Return: slkReturn

proc lineStepValueToVm(v: LineStepValue): StepLineFlowValue =
  ## Pre-render the ``Value`` so the view layer does not have to depend on the
  ## JS-only ``Value`` type tree.
  ##
  ## PLAT-2: at the `tracepoint` budget. A step-list row is one line of a
  ## tracepoint's answer — the same surface and therefore the same budget,
  ## stated here rather than left implicit, because a seventh budget for a
  ## surface that is a sixth one's row is how six formatters became seven.
  StepLineFlowValue(
    expression: safeStr(cast[cstring](v.expression)),
    value: safeStr(tracepointValue(v.value).root.text))

proc locationToVm(loc: types.Location): StepLineLocation =
  StepLineLocation(
    path: safeStr(loc.path),
    line: loc.line,
    functionName: safeStr(loc.functionName),
    rrTicks: loc.rrTicks)

proc lineStepToVm(line: LineStep): StepLine =
  var values: seq[StepLineFlowValue] = @[]
  for v in line.values:
    values.add(lineStepValueToVm(v))
  StepLine(
    kind: lineStepKindToVm(line.kind),
    delta: line.delta,
    location: locationToVm(line.location),
    sourceLine: safeStr(cast[cstring](line.sourceLine)),
    values: values)

proc lineStepsToVm(lines: seq[LineStep]): seq[StepLine] =
  result = newSeqOfCap[StepLine](lines.len)
  for line in lines:
    result.add(lineStepToVm(line))

# ---------------------------------------------------------------------------
# Legacy panel-height helper kept verbatim — the GL container's
# ``offsetHeight`` cannot be measured from the headless ViewModel layer,
# so we still consult the live DOM here and forward the result into the
# VM via ``setViewport``.
# ---------------------------------------------------------------------------

proc panelHeight*(self: StepListComponent): int =
  ## Rows the panel can show — measured off the live GL container, or the
  ## ViewModel's documented default when there is no container to measure.
  ##
  ## A PANEL THAT IS NOT IN THE LAYOUT IS AN ORDINARY STATE, NOT A FAILURE.
  ## The component keeps its `CtCompleteMove` subscription whether or not its
  ## pane is open, and the debugging layout a web replay loads does not carry
  ## a Step List pane at all. `jq` is `document.querySelector`, so this used to
  ## read `.offsetHeight` off `null` and THROW — once per step, from inside
  ## `onCompleteMove`, taking the rest of that move's handling with it.
  ##
  ## Measured on the assembled bundle: nine steps over three round trips
  ## produced nine uncaught `Cannot read properties of null (reading
  ## 'offsetHeight')`, and the debugger's painted caret never moved.
  let host = jq("#stepListComponent")
  if host.isNil:
    return DEFAULT_STEP_LIST_PANEL_HEIGHT
  let rows = cast[int](host.offsetHeight) div STEP_LINE_HEIGHT_PX
  if rows <= 0: DEFAULT_STEP_LIST_PANEL_HEIGHT else: rows

# ---------------------------------------------------------------------------
# Legacy event-bus handlers — kept so the existing IPC + mediator wiring
# keeps flowing.  Each handler also feeds the IsoNim VM so the panel
# stays in sync.
# ---------------------------------------------------------------------------

method onUpdatedLoadStepLines*(self: StepListComponent, stepLinesUpdate: LoadStepLinesUpdate) {.async.} =
  ## Called when the backend streams a fresh batch of step lines.
  ## Appends to the legacy cache (still consulted by other Karax-driven
  ## fallback paths) and mirrors the same data into the IsoNim VM so
  ## the live panel re-renders.
  self.lineSteps = self.lineSteps.concat(stepLinesUpdate.results)
  sort(self.lineSteps, func (x, y: LineStep): int = cmp(x.delta, y.delta))

  let vm = self.paneVM()
  if not vm.isNil:
    vm.appendLineSteps(lineStepsToVm(stepLinesUpdate.results))

proc loadStepLinesFor*(self: StepListComponent, location: types.Location) =
  ## Issue a fresh load-step-lines request for ``location``.  Resets
  ## the legacy + VM row lists before the streamed responses arrive,
  ## mirroring the legacy proc.
  self.lineSteps = @[]
  let count = self.panelHeight()
  self.service.loadStepLines(location, count)

  let vm = self.paneVM()
  if not vm.isNil:
    vm.setViewport(Viewport(rows: count))
    let vmLoc = locationToVm(location)
    vm.setCurrentLocation(vmLoc)
    vm.clearLineSteps()

method onCompleteMove*(self: StepListComponent, response: MoveState) {.async.} =
  ## Fires whenever the live debugger position advances.  Re-fetch the
  ## step lines for the new position so the panel content tracks the
  ## debugger.
  self.loadStepLinesFor(response.location)

# ---------------------------------------------------------------------------
# IsoNim VM bridge
# ---------------------------------------------------------------------------

proc syncLegacyStepListIntoVM*(self: StepListComponent) =
  ## Bulk-replay the legacy ``self.lineSteps`` cache into the VM.
  ## Used by the layout when the panel container becomes visible (or
  ## is rebuilt) so the panel reflects every row already accumulated
  ## by the previous load-step-lines stream.  Per-row updates go
  ## through ``onUpdatedLoadStepLines`` directly; this proc covers the
  ## bulk-replace scenario (e.g. opening the panel after some debugger
  ## navigation already happened).
  if self.isNil:
    return
  let vm = self.paneVM()
  if vm.isNil:
    return
  vm.setLineSteps(lineStepsToVm(self.lineSteps))
  # The location of this component's own tab, from that tab's debugger
  # service.
  let ownTab = data.sessionOfComponent(self)
  let dbgLoc =
    if ownTab.isNil or ownTab.services.isNil: data.services.debugger.location
    else: ownTab.services.debugger.location
  vm.setCurrentLocation(locationToVm(dbgLoc))

# ---------------------------------------------------------------------------
# VM bootstrap
# ---------------------------------------------------------------------------

proc initStepListVMFromSession*(vm: StepListVM) =
  ## Hand the pane the session's `StepListVM` — the one
  ## `initializePanelViewModels` built on the session's store, so every
  ## reader of the session sees the same instance (Shared-DOM-Front-Ends D1).
  ##
  ## The panel host (`ui/panel_host`) mounts the pane over this ViewModel;
  ## rows the shown tab's component received before now are replayed into
  ## it once, when the ViewModel is first handed over.
  stepListVMInstance = vm
  if firstBinding(vm):
    let component = data.shownTabComponent(Content.StepList)
    if not component.isNil:
      syncLegacyStepListIntoVM(StepListComponent(component))

# ---------------------------------------------------------------------------
# Component registration. The pane's view is mounted by the panel host.
# ---------------------------------------------------------------------------

method unregister*(self: StepListComponent) =
  ## Release the module-global slot before the base implementation drops the
  ## event-bus subscriptions: `register` assigns `stepListComponentRef` only
  ## `if isNil`, so a slot left pointing at an unregistered component would
  ## keep the next one from being fed (`ui/session_switch` unregisters every
  ## component of a closing session; `ui/layout` a closed panel).
  ##
  ## The VM is deliberately NOT reset: it is a singleton by design and holds
  ## state about the trace rather than about this panel, so dropping it would
  ## make closing and reopening the pane lose data that is still true.
  ##
  ## Modelled on `ui/constraints.nim`, which is the worked example, and
  ## `ui/scratchpad.nim`, which is the original.
  if stepListComponentRef == self:
    stepListComponentRef = nil
  procCall unregister(Component(self))

method register*(self: StepListComponent, api: MediatorWithSubscribers) =
  ## Register the StepListComponent with the mediator. Its event handlers
  ## feed the session's `StepListVM` once `initStepListVMFromSession` has
  ## installed it.
  self.api = api
  if stepListComponentRef.isNil:
    stepListComponentRef = self
