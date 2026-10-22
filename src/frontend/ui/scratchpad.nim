## Scratchpad Panel — pinned-value inspector.
##
## ---------------------------------------------------------------------------
## ViewModel layer — IsoNim is the primary renderer.
##
## The legacy Karax ``method render`` was dropped in favour of an IsoNim
## view (``viewmodel/views/isonim_scratchpad_view.nim``, one generic proc
## for every renderer) that the panel host (``ui/panel_host``) mounts into
## the GoldenLayout container, over the session's ``ScratchpadVM``. The
## legacy ``ScratchpadComponent`` retains its event-bus-carrier methods so
## the frontend's existing wiring (``InternalAddToScratchpad`` /
## ``InternalAddToScratchpadFromExpression`` / ``CtLoadLocalsResponse``)
## keeps feeding that ViewModel; ``configureMiddleware`` (in ``ui_js.nim``)
## installs it via ``initScratchpadVMFromSession``.
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
import ./presented_value
import ../viewmodel/store/replay_data_store
from ../viewmodel/store/types as vmtypes import ScratchpadValueEntry
from ../viewmodel/viewmodels/scratchpad_vm import
  ScratchpadVM, createScratchpadVM,
  addValue, removeValue, clearValues, setLocals, addFromExpression

# ---------------------------------------------------------------------------
# The session's ViewModel and the registered component, so the legacy
# event-bus handlers can feed the one and replay the other. On the desktop
# and the web the pane's view is mounted by the panel host (`ui/panel_host`).
# ---------------------------------------------------------------------------

var scratchpadVMInstance*: ScratchpadVM
var scratchpadComponentRef: ScratchpadComponent

# "Pin to scratchpad" (Value-Origin-Tracking.md §3.3, §3.5) lands in THIS
# pane's ViewModel: the session's, once `initScratchpadVMFromSession` has
# installed it. `ui/state.nim` owns the OriginChainVM that pins and cannot
# import this module (this module imports it), so the target is handed over
# as a resolver.
installScratchpadForPins(proc(): ScratchpadVM = scratchpadVMInstance)


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

proc isLiveScratchpadComponent(self: ScratchpadComponent): bool =
  ## True when ``self`` is the component whose IsoNim view is (or is about
  ## to be) mounted, i.e. the panel the user can actually see.
  ##
  ## Defence in depth for #612: the VM instance is module-global, so any
  ## ``ScratchpadComponent`` that is still subscribed to
  ## ``InternalAddToScratchpad`` writes rows into whatever panel happens to
  ## be mounted — including components belonging to panels that were closed
  ## or wiped by a layout reset.  ``Component.unregister`` is the real fix
  ## (it stops the event from ever reaching those components); this guard
  ## makes the sink itself refuse to mirror on behalf of a stale component,
  ## so a future teardown path that forgets to unregister degrades into a
  ## dropped update instead of a duplicated row.
  scratchpadComponentRef.isNil or scratchpadComponentRef == self

proc valueTextRepr*(value: Value): string =
  ## A single-line rendering of a ``Value`` for the IsoNim scratchpad cell.
  ##
  ## The IsoNim view layer applies the ``expression: <text>`` shape
  ## (``cellText`` in ``isonim_scratchpad_view``) — this proc returns the value
  ## half only.
  ##
  ## PLAT-2: one call, at the `scratchpad` budget.
  ##
  ## The three-arm ladder this replaced is why the milestone exists. Its
  ## `Error` arm returned the bare `msg` — which the IsoNim view then wrapped in
  ## `<error: …>` itself (`isonim_scratchpad_view.cellText`), so the SAME
  ## decision was made twice, in two modules, in two spellings, and the pane's
  ## error rendering differed from the state panel's (bare `msg`) and from the
  ## trace log's (`<span class="error-trace">`). The presenter renders
  ## `<error: msg>` for every surface; the view's own wrapper is removed.
  if value.isNil:
    return ""
  if value.isLiteral and value.kind == types.String:
    # A literal string in the scratchpad is the text the user typed, not a
    # recorded value being quoted back at them. A fact about this pane.
    return safeStr(value.text)
  scratchpadValue(value).root.text

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
  ## VM.
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
  if not scratchpadVMInstance.isNil and self.isLiveScratchpadComponent:
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

proc initScratchpadVMFromSession*(vm: ScratchpadVM) =
  ## Hand the pane the session's `ScratchpadVM` — the one
  ## `initializePanelViewModels` built on the session's store, so every
  ## reader of the session sees the same instance (Shared-DOM-Front-Ends D1).
  ## Values the component already holds are replayed into it once.
  scratchpadVMInstance = vm
  if not scratchpadComponentRef.isNil:
    syncLegacyScratchpadIntoVM(scratchpadComponentRef)


# ---------------------------------------------------------------------------
# Component registration. The pane's view is mounted by the panel host.
# ---------------------------------------------------------------------------


method register*(self: ScratchpadComponent, api: MediatorWithSubscribers) =
  ## Register the ScratchpadComponent with the mediator. Its handlers feed
  ## the session's `ScratchpadVM` once `initScratchpadVMFromSession` has
  ## installed it.
  self.api = api

  # Always adopt the newest registration as the live component: a closed and
  # re-opened pane registers a new one, and the handlers must feed through it.
  scratchpadComponentRef = self

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

method unregister*(self: ScratchpadComponent) =
  ## Release the module-global panel slots before handing over to the base
  ## implementation (which drops the event-bus subscriptions).
  ##
  ## Without this a closed Scratchpad panel would keep ``scratchpadComponentRef``
  ## pointing at a component that no longer receives events.
  if scratchpadComponentRef == self:
    scratchpadComponentRef = nil
  procCall unregister(Component(self))
