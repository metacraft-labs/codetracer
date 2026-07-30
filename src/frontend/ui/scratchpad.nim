## Scratchpad Panel — pinned-value inspector.
##
## ---------------------------------------------------------------------------
## ViewModel layer — IsoNim is the primary renderer.
##
## The legacy Karax ``method render`` was dropped in favour of an IsoNim
## view (``viewmodel/views/isonim_scratchpad_view.nim``) that mounts
## directly into the GoldenLayout container.  The legacy
## ``ScratchpadComponent`` retains its event-bus-carrier methods so the
## frontend's existing wiring (``InternalAddToScratchpad`` /
## ``InternalAddToScratchpadFromExpression`` / ``CtLoadLocalsResponse``)
## keeps feeding the panel; every state mutation now mirrors into the
## parallel ``ScratchpadVM`` so the IsoNim view is the single source of
## truth for the panel's DOM.
##
## Lifecycle:
## 1. ``utils.nim::makeScratchpadComponent`` constructs the legacy
##    ``ScratchpadComponent`` and registers it under
##    ``Content.Scratchpad`` (one instance per panel id).
## 2. ``layout.nim`` registers the GL container, then detects
##    ``Content.Scratchpad`` is in ``isIsoNimComponent`` and calls
##    ``tryMountIsoNimScratchpadPanel`` instead of invoking Karax.
## 3. The mount helper appends the IsoNim panel inside the
##    ``scratchpadComponent-{id}`` container and the reactive effects
##    keep the DOM in sync with the VM.
## 4. ``configureMiddleware`` (in ``ui_js.nim``) installs the shared-
##    store version of the VM via ``initScratchpadVMWithStore`` so the
##    panel uses the production ``ReplayDataStore``.
##
## NOTE: the rich ``ValueComponent`` rendering remains a follow-up — the
## IsoNim view renders a single-line ``expression: valueText``
## placeholder per row.  See the doc-comment in
## ``viewmodel/views/isonim_scratchpad_view.nim`` for details.
## ---------------------------------------------------------------------------

import
  ui_imports,
  state,
  ../[ types, communication ],
  ../../common/ct_event

import std/json
from ../viewmodel/backend/backend_service import BackendService, BackendFuture
import ../viewmodel/store/replay_data_store
from ../viewmodel/store/types as vmtypes import ScratchpadValueEntry
from ../viewmodel/viewmodels/scratchpad_vm import
  ScratchpadVM, createScratchpadVM,
  addValue, removeValue, clearValues, setLocals, addFromExpression
when defined(js):
  from isonim/web/dom_api import nil
  from ../viewmodel/views/isonim_scratchpad_view import
    mountIsoNimScratchpadPanel

# ---------------------------------------------------------------------------
# Module-level VM/store/component slots so the IsoNim mount and the
# legacy event-bus handlers can find each other across calls.  Mirrors
# the pattern used by trace_log / request_panel / step_list / repl /
# low_level_code.
# ---------------------------------------------------------------------------

var scratchpadVMInstance*: ScratchpadVM
var scratchpadVMStore: ReplayDataStore
var scratchpadComponentRef: ScratchpadComponent
# Track which ScratchpadComponent ids have already mounted their IsoNim
# view.  The GL container is keyed by ``scratchpadComponent-{id}`` so
# each panel instance gets its own mount.
var isoNimScratchpadMountedIds {.used.}: JsAssoc[int, bool] =
  JsAssoc[int, bool]{}

proc tryMountIsoNimScratchpadPanel*()

# ---------------------------------------------------------------------------
# Component extension (ctInExtension boiler-plate).
#
# Preserved from the legacy module so the extension entry-point still
# resolves to a valid ``ScratchpadComponent``; the in-extension
# surface has no panel markup of its own because the IsoNim view is
# the production renderer.
# ---------------------------------------------------------------------------

when defined(ctInExtension):
  var scratchpadComponentForExtension* {.exportc.}: ScratchpadComponent =
    makeScratchpadComponent(data, 0, inExtension = true)

  proc bindScratchpadExtensionHost(component: ScratchpadComponent) =
    if component.extensionRendererId.len == 0:
      return

    let host = document.getElementById(component.extensionRendererId)
    if host.isNil:
      return

    # The extension scratchpad surface is an empty compatibility host; keep the
    # exported component usable without retaining a Karax renderer.
    host.innerHTML = cstring""

  proc makeScratchpadComponentForExtension*(id: cstring): ScratchpadComponent {.exportc.} =
    if scratchpadComponentForExtension.extensionRendererId.len == 0:
      scratchpadComponentForExtension.extensionRendererId = id
      scratchpadComponentForExtension.bindScratchpadExtensionHost()
    result = scratchpadComponentForExtension

# ---------------------------------------------------------------------------
# Legacy → VM translation helpers.
# ---------------------------------------------------------------------------

proc safeStr(s: cstring): string =
  ## Convert a possibly-null cstring to an empty string.  Mirrors the
  ## helper used by trace_log / request_panel — E2E paths can land a
  ## null cstring in the legacy record, and a naive ``$`` would throw
  ## inside ``cstrToNimstr``.
  if s.isNil:
    ""
  else:
    $s

proc valueTextRepr*(value: Value): string =
  ## Produce a short single-line text representation of a ``Value``
  ## ref-object suitable for the IsoNim placeholder cell.  Mirrors the
  ## branches the legacy ``ValueComponent`` collapsed view used:
  ## literal strings render bare, errors render as ``msg``, and every
  ## other value defers to the canonical ``textRepr`` (which the
  ## legacy column-4 renderer in trace_log §1.69 also relied on).
  ##
  ## The IsoNim view layer applies the ``expression: <text>`` shape
  ## (``cellText`` in ``isonim_scratchpad_view``) — this proc only
  ## returns the value half so the same helper is reusable for the
  ## eventual rich ``ValueComponent`` follow-up.
  if value.isNil:
    return ""
  if value.kind == types.Error:
    return safeStr(value.msg)
  if value.isLiteral and value.kind == types.String:
    return safeStr(value.text)
  value.textRepr

proc legacyValueToVm(expression: cstring; value: Value): ScratchpadValueEntry =
  ## Map a legacy ``(expression, Value)`` pair to the platform-neutral
  ## ``ScratchpadValueEntry`` value type the ViewModel layer consumes.
  ## ``isError`` / ``isLiteral`` are surfaced so the IsoNim view (and
  ## any future rich-rendering follow-up) can apply the right CSS
  ## modifier and rendering branch without re-fetching the original
  ## ``Value`` ref-object.
  let isError = (not value.isNil) and value.kind == types.Error
  let isLiteral = (not value.isNil) and value.isLiteral and
    value.kind == types.String
  let hasChild = (if value.isNil: false else: value.elements.len > 0 or value.kind in {types.TypeKind.Pointer, types.TypeKind.Ref} or value.kind in {types.TypeKind.Instance, types.TypeKind.Union, types.TypeKind.Tuple, types.TypeKind.TableKind, types.TypeKind.Variant})
  ScratchpadValueEntry(
    expression: safeStr(expression),
    valueText: valueTextRepr(value),
    isError: isError,
    isLiteral: isLiteral,
    typeName: valueDisplayType(value),
    hasChildren: hasChild,
    children: toVariableChildren(value),
  )

proc legacyVariableToVm(variable: Variable): ScratchpadValueEntry =
  ## Same mapping for a ``Variable`` ref-object (the locals lookup
  ## uses ``Variable`` records).  Delegates to ``legacyValueToVm``
  ## once the ``expression`` / ``value`` fields are extracted.
  legacyValueToVm(variable.expression, variable.value)

# ---------------------------------------------------------------------------
# Public API — called by the legacy event-bus handlers below.  Each
# mutator updates the legacy ``programValues`` / ``values`` cache (kept
# for any non-render legacy callers) AND mirrors into the parallel VM.
# ---------------------------------------------------------------------------

proc removeValue*(self: ScratchpadComponent, i: int) =
  ## Drop the row at ``i`` from both the legacy cache and the parallel
  ## VM.  The IsoNim view's per-row close button calls
  ## ``vm.removeValue`` directly; this proc remains for any historical
  ## callers (and is exported so existing entry-points still resolve).
  if i >= 0 and i < self.programValues.len:
    self.programValues.delete(i, i)
  if i >= 0 and i < self.values.len:
    self.values.delete(i, i)
  if not scratchpadVMInstance.isNil:
    scratchpadVMInstance.removeValue(i)

proc registerLocals*(self: ScratchpadComponent,
                     response: CtLoadLocalsResponseBody) =
  ## Refresh the locals cache used by ``addFromExpression``.  Mirrors
  ## into the VM so the parallel ``localsByExpression`` lookup stays in
  ## sync with whatever the legacy panel would have used to resolve
  ## ``InternalAddToScratchpadFromExpression``.
  self.locals = response.locals
  if not scratchpadVMInstance.isNil:
    var entries: seq[ScratchpadValueEntry] = @[]
    for v in self.locals:
      entries.add(legacyVariableToVm(v))
    scratchpadVMInstance.setLocals(entries)

proc registerValue*(self: ScratchpadComponent,
                    variable: ValueWithExpression) =
  ## Append a captured value to both the legacy cache and the parallel
  ## VM.  The legacy ``ValueComponent`` shell is still constructed so
  ## any historical non-render Karax-side caller (e.g. the in-
  ## extension build path) keeps compiling.
  let value = variable.value
  let expression = variable.expression
  self.programValues.add((expression, value))
  self.values.add(
    ValueComponent(
      expanded: JsAssoc[cstring, bool]{},
      charts: JsAssoc[cstring, ChartComponent]{},
      showInline: JsAssoc[cstring, bool]{},
      baseExpression: expression,
      baseValue: value,
      nameWidth: VALUE_COMPONENT_NAME_WIDTH,
      valueWidth: VALUE_COMPONENT_VALUE_WIDTH,
      stateID: -1
    )
  )
  if not scratchpadVMInstance.isNil:
    scratchpadVMInstance.addValue(legacyValueToVm(expression, value))

# ---------------------------------------------------------------------------
# IsoNim VM bridge
# ---------------------------------------------------------------------------

proc syncLegacyScratchpadIntoVM*(self: ScratchpadComponent) =
  ## Bulk-replay the legacy ``programValues`` / ``locals`` caches into
  ## the VM.  Used by the layout when the panel container becomes
  ## visible (or is rebuilt) so the panel reflects every entry already
  ## accumulated by the previous event-bus stream.  Per-entry updates
  ## go through ``registerValue`` directly; this proc covers the
  ## bulk-replace scenario (e.g. opening the panel after some values
  ## were already pinned).
  if scratchpadVMInstance.isNil or self.isNil:
    return
  var entries: seq[ScratchpadValueEntry] =
    newSeqOfCap[ScratchpadValueEntry](self.programValues.len)
  for (expression, value) in self.programValues:
    entries.add(legacyValueToVm(expression, value))
  # Re-seed the entry list in one shot; using ``addValue`` would
  # trigger one signal write per row.
  scratchpadVMInstance.clearValues()
  for entry in entries:
    scratchpadVMInstance.addValue(entry)
  # Refresh the locals lookup so a follow-up
  # ``addFromExpression`` call resolves against the latest snapshot.
  var localsEntries: seq[ScratchpadValueEntry] = @[]
  for v in self.locals:
    localsEntries.add(legacyVariableToVm(v))
  scratchpadVMInstance.setLocals(localsEntries)

# ---------------------------------------------------------------------------
# VM bootstrap
# ---------------------------------------------------------------------------

proc initScratchpadVMWithStore*(store: ReplayDataStore) =
  ## Initialise (or replace) the parallel ``ScratchpadVM`` using an
  ## externally-provided ``ReplayDataStore`` (typically the shared
  ## store from ``SessionViewModel``).  Called from
  ## ``ui_js.configureMiddleware``.  If a stub-backed instance already
  ## exists (created by ``initScratchpadVM`` before the real backend
  ## was available) it is replaced so the panel uses the real backend.
  if scratchpadVMInstance != nil:
    clog "ScratchpadVM: replacing existing instance with shared-store version"
    isoNimScratchpadMountedIds = JsAssoc[int, bool]{}
  scratchpadVMStore = store
  scratchpadVMInstance = createScratchpadVM(store)
  clog "ScratchpadVM: parallel ViewModel instance created (shared store)"
  tryMountIsoNimScratchpadPanel()

proc initScratchpadVM*() =
  ## Lazy fallback used when no shared store has been provided yet.
  ## Same shape as ``initRequestPanelVM`` / ``initTraceLogVM`` — a stub
  ## backend so the panel can still render before
  ## ``configureMiddleware`` runs.
  if scratchpadVMInstance != nil:
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

  scratchpadVMStore = createReplayDataStore(stubBackend)
  scratchpadVMInstance = createScratchpadVM(scratchpadVMStore)
  clog "ScratchpadVM: parallel ViewModel instance created (stub backend)"
  tryMountIsoNimScratchpadPanel()

# ---------------------------------------------------------------------------
# Mount helper — Web only
# ---------------------------------------------------------------------------

when defined(js):
  proc tryMountIsoNimScratchpadPanel*() =
    ## Mount the IsoNim Scratchpad panel view into the GoldenLayout-
    ## managed container.  The container's id is
    ## ``scratchpadComponent-{id}`` — each open Scratchpad panel
    ## instance has its own mount.
    ##
    ## Safe to call multiple times — mounts only once per component
    ## id.  Retries via ``setTimeout`` until the DOM container appears
    ## (capped at 200 attempts, ~2 s) since GoldenLayout creates the
    ## host slightly after the layout state changes (mirrors
    ## ``tryMountIsoNimRequestPanel`` / ``tryMountIsoNimTraceLogPanel``).
    if scratchpadVMInstance.isNil:
      return
    if scratchpadComponentRef.isNil:
      return
    let componentId = scratchpadComponentRef.id
    if isoNimScratchpadMountedIds.hasKey(componentId):
      return

    let key = cstring("scratchpadComponent-" & $componentId)
    var retryCount = 0
    proc doMount() =
      if isoNimScratchpadMountedIds.hasKey(componentId):
        return
      retryCount += 1
      let container = dom_api.getElementById(dom_api.document, key)
      if dom_api.isNodeNil(dom_api.Node(container)):
        if retryCount > 200:
          cerror "tryMountIsoNimScratchpadPanel: not ready after 200 retries, giving up"
          return
        discard setTimeout(proc() = doMount(), 10)
        return

      # Replace any prior content (Karax may have planted a stub
      # element before the IsoNim mount fires).
      let containerNode = dom_api.Node(container)
      while not dom_api.isNodeNil(containerNode.firstChild):
        discard dom_api.removeChild(containerNode, containerNode.firstChild)

      isoNimScratchpadMountedIds[componentId] = true
      try:
        mountIsoNimScratchpadPanel(container, scratchpadVMInstance)
      except:
        cerror "tryMountIsoNimScratchpadPanel: mount EXCEPTION: " &
          getCurrentExceptionMsg()

      # Re-sync any rows the legacy component already carries so the
      # freshly-mounted view reflects the latest list.
      if not scratchpadComponentRef.isNil:
        syncLegacyScratchpadIntoVM(scratchpadComponentRef)

    doMount()
else:
  proc tryMountIsoNimScratchpadPanel*() =
    ## Native compilation has no DOM — keep the proc available so
    ## callers (``initScratchpadVM*``) compile on every backend.
    discard

# ---------------------------------------------------------------------------
# Component registration — IsoNim primary renderer; no Karax method
# render.  Generic callers are expected to use direct IsoNim mount paths.
# ---------------------------------------------------------------------------

when defined(ctInExtension):
  method redrawForExtension*(self: ScratchpadComponent) =
    self.bindScratchpadExtensionHost()

method register*(self: ScratchpadComponent, api: MediatorWithSubscribers) =
  ## Register the ScratchpadComponent with the mediator.  Bring up the
  ## IsoNim ScratchpadVM lazily so the mount procedure can find it; the
  ## shared-store version is installed by ``configureMiddleware`` if
  ## the ViewModel layer is enabled.
  self.api = api
  initScratchpadVM()
  if scratchpadComponentRef.isNil:
    scratchpadComponentRef = self
    tryMountIsoNimScratchpadPanel()

  api.subscribe(InternalAddToScratchpad,
    proc(kind: CtEventKind, response: ValueWithExpression, sub: Subscriber) =
      self.registerValue(response)
  )
  api.subscribe(InternalAddToScratchpadFromExpression,
    proc(kind: CtEventKind, response: cstring, sub: Subscriber) =
      var found: Variable
      var foundIt = false

      for v in self.locals:
        if v.expression == response:
          found = v
          foundIt = true
          break

      if foundIt:
        self.registerValue(ValueWithExpression(expression: found.expression,
                                               value: found.value))
      else:
        # The legacy implementation echoed "Variable not found." here;
        # the new flow drops the noise and keeps the no-op semantics
        # (mirrors the same decision in ScratchpadVM.addFromExpression).
        discard
  )
  api.subscribe(CtLoadLocalsResponse,
    proc(kind: CtEventKind, response: CtLoadLocalsResponseBody, sub: Subscriber) =
      self.registerLocals(response)
  )

proc registerScratchpadComponent*(component: ScratchpadComponent,
                                   api: MediatorWithSubscribers) {.exportc.} =
  component.register(api)
