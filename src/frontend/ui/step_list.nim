## Step List panel — linear list of recently-executed source lines
## around the current debugger position.
##
## ---------------------------------------------------------------------------
## ViewModel layer — IsoNim is the primary renderer.
##
## The legacy Karax ``method render`` was dropped in favour of an IsoNim
## view (``viewmodel/views/isonim_step_list_view.nim``) that mounts
## directly into the GoldenLayout container.  The legacy
## ``StepListComponent`` retains its event-bus subscriptions so the
## frontend's existing wiring (``CtCompleteMove`` → re-fetch step lines,
## ``updated-load-step-lines`` IPC → append-and-sort) keeps feeding
## data; the component now mirrors every update into a ``StepListVM``
## whose signals drive the IsoNim view.
## ---------------------------------------------------------------------------

import ui_imports, value, ../[types, utils, communication]

import std/[algorithm, json]
from ../viewmodel/backend/backend_service import BackendService, BackendFuture
import ../viewmodel/store/replay_data_store
from ../viewmodel/store/types as vmtypes import
  StepLine, StepLineKind, StepLineLocation, StepLineFlowValue
from ../viewmodel/viewmodels/step_list_vm import
  StepListVM, createStepListVM,
  setLineSteps, appendLineSteps, clearLineSteps,
  setCurrentLocation, setPanelHeight,
  loadStepLinesFor, jumpToStepLine
when defined(js):
  from isonim/web/dom_api import nil
  from ../viewmodel/views/isonim_step_list_view import mountIsoNimStepList

const STEP_LINE_HEIGHT_PX = 26

# Module-level VM/store/component slots so the IsoNim mount and the
# legacy event-bus handlers can find each other across calls.  Mirrors
# the pattern used by terminal_output, search_results and event_log.
var stepListVMInstance*: StepListVM
var stepListVMStore: ReplayDataStore
var stepListComponentRef: StepListComponent
# Track which StepListComponent ids have already mounted their IsoNim
# view.  The GL container is keyed by ``stepListComponent-{id}`` so each
# panel instance gets its own mount.
var isoNimStepListMountedIds {.used.}: JsAssoc[int, bool] = JsAssoc[int, bool]{}

proc tryMountIsoNimStepListPanel*()

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
  ## Pre-render the ``Value`` to its text repr so the view layer does
  ## not have to depend on the JS-only ``Value`` type tree.
  StepLineFlowValue(
    expression: safeStr(cast[cstring](v.expression)),
    value: safeStr(v.value.textRepr))

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
# VM via ``setPanelHeight``.
# ---------------------------------------------------------------------------

proc panelHeight*(self: StepListComponent): int =
  cast[int](jq("#stepListComponent").offsetHeight) div STEP_LINE_HEIGHT_PX

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

  if not stepListVMInstance.isNil:
    stepListVMInstance.appendLineSteps(lineStepsToVm(stepLinesUpdate.results))

proc loadStepLinesFor*(self: StepListComponent, location: types.Location) =
  ## Issue a fresh load-step-lines request for ``location``.  Resets
  ## the legacy + VM row lists before the streamed responses arrive,
  ## mirroring the legacy proc.
  self.lineSteps = @[]
  let count = self.panelHeight()
  self.service.loadStepLines(location, count)

  if not stepListVMInstance.isNil:
    stepListVMInstance.setPanelHeight(count)
    let vmLoc = locationToVm(location)
    stepListVMInstance.setCurrentLocation(vmLoc)
    stepListVMInstance.clearLineSteps()

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
  if stepListVMInstance.isNil or self.isNil:
    return
  stepListVMInstance.setLineSteps(lineStepsToVm(self.lineSteps))
  let dbgLoc = data.services.debugger.location
  stepListVMInstance.setCurrentLocation(locationToVm(dbgLoc))

# ---------------------------------------------------------------------------
# VM bootstrap
# ---------------------------------------------------------------------------

proc initStepListVMWithStore*(store: ReplayDataStore) =
  ## Initialise (or replace) the parallel ``StepListVM`` using an
  ## externally-provided ``ReplayDataStore`` (typically the shared
  ## store from ``SessionViewModel``).  Called from
  ## ``ui_js.configureMiddleware``.  If a stub-backed instance already
  ## exists (created by ``initStepListVM`` before the real backend was
  ## available) it is replaced so the panel uses the real backend.
  if stepListVMInstance != nil:
    clog "StepListVM: replacing existing instance with shared-store version"
    isoNimStepListMountedIds = JsAssoc[int, bool]{}
  stepListVMStore = store
  stepListVMInstance = createStepListVM(store)
  clog "StepListVM: parallel ViewModel instance created (shared store)"
  tryMountIsoNimStepListPanel()

proc initStepListVM*() =
  ## Lazy fallback used when no shared store has been provided yet.
  ## Same shape as ``initTerminalOutputVM`` /
  ## ``initSearchResultsVM`` — a stub backend so the panel can still
  ## render before ``configureMiddleware`` runs.
  if stepListVMInstance != nil:
    return

  let stubSend = proc(command: string, args: JsonNode): BackendFuture[JsonNode] =
    when defined(js):
      result = newPromise proc(resolve: proc(resp: JsonNode)) =
        resolve(%*{})
    else:
      var fut = newFuture[JsonNode]("stub-backend")
      fut.complete(%*{})
      result = fut

  let stubBackend = BackendService(
    sendProc: stubSend,
    onEventProc: proc(handler: proc(event: JsonNode)) = discard,
    disconnectProc: proc() = discard,
  )

  stepListVMStore = createReplayDataStore(stubBackend)
  stepListVMInstance = createStepListVM(stepListVMStore)
  clog "StepListVM: parallel ViewModel instance created (stub backend)"
  tryMountIsoNimStepListPanel()

# ---------------------------------------------------------------------------
# Mount helper — Web only
# ---------------------------------------------------------------------------

when defined(js):
  proc tryMountIsoNimStepListPanel*() =
    ## Mount the IsoNim step-list view into the GoldenLayout-managed
    ## container.  The container's id is ``stepListComponent-{id}``;
    ## each open Step List panel instance has its own mount.
    ##
    ## Safe to call multiple times — mounts only once per component id.
    ## Retries via ``setTimeout`` until the DOM container appears
    ## (capped at 200 attempts, ~2 s) since GoldenLayout creates the
    ## host slightly after the layout state changes.
    if stepListVMInstance.isNil:
      return
    if stepListComponentRef.isNil:
      return
    let componentId = stepListComponentRef.id
    if isoNimStepListMountedIds.hasKey(componentId):
      return

    let key = cstring("stepListComponent-" & $componentId)
    var retryCount = 0
    proc doMount() =
      if isoNimStepListMountedIds.hasKey(componentId):
        return
      retryCount += 1
      let container = dom_api.getElementById(dom_api.document, key)
      if dom_api.isNodeNil(dom_api.Node(container)):
        if retryCount > 200:
          cerror "tryMountIsoNimStepListPanel: not ready after 200 retries, giving up"
          return
        discard setTimeout(proc() = doMount(), 10)
        return

      # Replace any prior content (Karax may have planted a stub
      # element before the IsoNim mount fires).
      let containerNode = dom_api.Node(container)
      while not dom_api.isNodeNil(containerNode.firstChild):
        discard dom_api.removeChild(containerNode, containerNode.firstChild)

      isoNimStepListMountedIds[componentId] = true
      try:
        mountIsoNimStepList(container, stepListVMInstance)
      except:
        cerror "tryMountIsoNimStepListPanel: mount EXCEPTION: " &
          getCurrentExceptionMsg()

      # Re-sync any rows the legacy component already carries so the
      # freshly-mounted view reflects the latest list.
      if not stepListComponentRef.isNil:
        syncLegacyStepListIntoVM(stepListComponentRef)

    doMount()
else:
  proc tryMountIsoNimStepListPanel*() =
    ## Native compilation has no DOM — keep the proc available so
    ## callers (``initStepListVM*``) compile on every backend.
    discard

# ---------------------------------------------------------------------------
# Component registration — IsoNim primary renderer; no Karax method
# render.  The base ``Component.render()`` returns a valid empty VNode
# for any generic callers.
# ---------------------------------------------------------------------------

method register*(self: StepListComponent, api: MediatorWithSubscribers) =
  ## Register the StepListComponent with the mediator.  Bring up the
  ## IsoNim StepListVM lazily so the mount procedure can find it; the
  ## shared-store version is installed by ``configureMiddleware`` if
  ## the ViewModel layer is enabled.
  self.api = api
  initStepListVM()
  if stepListComponentRef.isNil:
    stepListComponentRef = self
    tryMountIsoNimStepListPanel()
