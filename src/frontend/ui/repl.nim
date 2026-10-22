## REPL panel — interactive prompt over the live debugger session.
##
## ---------------------------------------------------------------------------
## ViewModel layer — IsoNim is the primary renderer.
##
## The legacy Karax ``method render`` was dropped in favour of an IsoNim
## view (``viewmodel/views/isonim_repl_view.nim``) that mounts directly
## into the GoldenLayout container.  The legacy ``ReplComponent``
## retains its event-bus subscriptions so the existing wiring
## (``onDebugOutput`` dispatched from
## ``services/debugger_service.nim::onDebugOutput`` via the
## ``debug-output`` IPC handler) keeps feeding data; the component now
## mirrors every update into a parallel ``ReplVM`` whose signals drive
## the IsoNim view.
##
## Lifecycle:
## 1. ``utils.nim::makeReplComponent`` constructs the legacy
##    ``ReplComponent`` and registers it under ``Content.Repl`` (one
##    instance per panel id — typically id = 0 since the layout opens
##    a single REPL pane).
## 2. GoldenLayout's component factory (``layout.nim``) builds the
##    pane's container and the panel host (``ui/panel_host``) mounts the
##    generic view into it; reactive effects keep the DOM in sync with the
##    VM.
## 3. The legacy event handlers feed the session's VM.
## 4. ``configureMiddleware`` (in ``ui_js.nim``) installs the shared-
##    store version of the VM via ``initReplVMFromSession`` so the panel
##    uses the production ``ReplayDataStore``.
## ---------------------------------------------------------------------------

import
  std/[strutils, json],
  ui_imports, value, ../[types, communication]

import isonim/core/signals
import ../viewmodel/viewmodels/repl_vm

# ---------------------------------------------------------------------------
# The session's ViewModel and the registered component, so the legacy
# event-bus handlers can feed the one and replay the other. The pane's view
# is mounted by the panel host (`ui/panel_host`).
# ---------------------------------------------------------------------------

var replVMInstance*: ReplVM
var replComponentRef: ReplComponent


# ---------------------------------------------------------------------------
# Legacy → VM translation helpers.
# ---------------------------------------------------------------------------

proc safeStr(s: cstring): string =
  ## Convert a possibly-null cstring to an empty string.  Mirrors the
  ## helper used by step_list — E2E paths can land a null cstring in
  ## the legacy record, and naive ``$`` would throw inside
  ## ``cstrToNimstr``.
  if s.isNil:
    ""
  else:
    $s

proc debugOutputKindToVm(kind: DebugOutputKind): ReplOutputKind =
  ## Map the legacy ``DebugOutputKind`` (in ``common_types/graveyard``)
  ## to the platform-neutral ``ReplOutputKind`` used by the VM.
  case kind
  of DebugLoading: rokLoading
  of DebugResult: rokResult
  of DebugMove: rokMove
  of DebugError: rokError

proc debugOutputToVm(o: DebugOutput): ReplOutput =
  ReplOutput(
    kind: debugOutputKindToVm(o.kind),
    output: safeStr(cast[cstring](o.output)))

proc debugInteractionToVm(i: DebugInteraction): ReplInteraction =
  ReplInteraction(
    input: safeStr(cast[cstring](i.input)),
    output: debugOutputToVm(i.output))

proc historyToVm(history: seq[DebugInteraction]): seq[ReplInteraction] =
  result = newSeqOfCap[ReplInteraction](history.len)
  for entry in history:
    result.add(debugInteractionToVm(entry))

# ---------------------------------------------------------------------------
# Legacy event-bus handlers — kept so the existing IPC + mediator wiring
# keeps flowing.  Each handler also feeds the IsoNim VM so the panel
# stays in sync.
# ---------------------------------------------------------------------------

method onDebugOutput*(self: ReplComponent, response: DebugOutput) {.async.} =
  ## Dispatched by the ``debug-output`` IPC subscription whenever the
  ## live debugger streams a response back.  Updates the legacy cache
  ## (still consulted by other Karax-driven fallback paths) AND the
  ## parallel ``ReplVM`` so the IsoNim view re-renders.
  if self.history.len > 0:
    self.history[^1].output = response
    self.data.redraw()
  if not replVMInstance.isNil:
    replVMInstance.onDebugOutput(debugOutputToVm(response))

method run*(self: ReplComponent, input: cstring) {.async.} =
  ## Submit a user-entered REPL expression.  Mirrors the legacy
  ## ``run`` method semantics: append a pending interaction to the
  ## legacy cache, mirror it into the VM, and dispatch the
  ## ``debugRepl`` IPC call.  The ``stableBusy`` gate stays here so
  ## any callers that hit ``run`` directly preserve the legacy
  ## guard; the VM dispatcher path also goes through ``debugRepl``
  ## which has the same gate at the service layer.
  if not self.service.stableBusy:
    self.history.add(
      DebugInteraction(
        input: input,
        output: DebugOutput(kind: DebugLoading, output: cstring"")
      )
    )
    debugRepl(self.history[^1].input)
    if not replVMInstance.isNil:
      # Append directly so we do not double-dispatch ``debugRepl``
      # (the VM action would call it again via the dispatcher).
      var entries = replVMInstance.history.val
      entries.add(ReplInteraction(
        input: safeStr(input),
        output: ReplOutput(kind: rokLoading, output: ""),
      ))
      replVMInstance.history.val = entries

# ---------------------------------------------------------------------------
# IsoNim VM bridge
# ---------------------------------------------------------------------------

proc syncLegacyReplIntoVM*(self: ReplComponent) =
  ## Bulk-replay the legacy ``self.history`` cache into the VM.
  ## Used by the layout when the panel container becomes visible (or
  ## is rebuilt) so the panel reflects every interaction already
  ## accumulated by the previous IPC stream.
  if replVMInstance.isNil or self.isNil:
    return
  replVMInstance.setHistory(historyToVm(self.history))

proc syncReplConfigIntoVM*() =
  ## Refresh the materialized / replEnabled / langName signals from
  ## the live ``data`` global.  Called whenever the panel is mounted
  ## so the view picks up the latest config without waiting for an
  ## interaction.  Defensive: ``data`` may be partially initialised
  ## during early renderer bring-up, so each access is guarded.
  if replVMInstance.isNil:
    return
  when defined(js):
    if data.isNil:
      return
    var langUsesMaterialized = false
    var langDisplayName = ""
    if not data.trace.isNil:
      # LRS-5 (b), one of the four sites: the REPL panel's disabled mode is a
      # property of the RECORDING, and it now reads the recording's own
      # approach (`Trace.approach`, from the four-axis `recordings.lang` cell)
      # rather than `usesMaterializedTraces(trace.lang)`.  For a wasm Rust
      # recording the summary is `LangRust` -- which is right for the language
      # NAME below and was never able to answer this question without a
      # `LangRustWasm` member.
      langUsesMaterialized = data.trace.usesMaterializedTraces()
      langDisplayName = data.trace.lang.toName()
    replVMInstance.setMaterialized(langUsesMaterialized)
    replVMInstance.setLangName(langDisplayName)
    replVMInstance.setReplEnabled(data.config.repl)

# ---------------------------------------------------------------------------
# VM bootstrap
# ---------------------------------------------------------------------------

proc replDispatcher(): ReplDispatcher =
  ## Production dispatcher: forwards the user-entered expression to
  ## the IPC layer via ``debugRepl``.  ``debugRepl`` has its own
  ## ``stableBusy`` gate at the service layer so the VM path is safe
  ## to call even while a request is in flight.
  result = proc(input: string) =
    debugRepl(cstring(input))

proc initReplVMFromSession*(vm: ReplVM) =
  ## Hand the pane the session's `ReplVM` — the one
  ## `initializePanelViewModels` built on the session's store, so every
  ## reader of the session sees the same instance (Shared-DOM-Front-Ends D1).
  ##
  ## The REPL's dispatcher is the renderer's (`replDispatcher`), so it is
  ## installed here, before the pane can send anything. The history the
  ## component already holds is replayed into it once.
  vm.dispatcher = replDispatcher()
  replVMInstance = vm
  syncReplConfigIntoVM()
  if not replComponentRef.isNil:
    syncLegacyReplIntoVM(replComponentRef)

# ---------------------------------------------------------------------------
# Component registration. The pane's view is mounted by the panel host.
# ---------------------------------------------------------------------------

method unregister*(self: ReplComponent) =
  ## Release the module-global slot before the base implementation drops the
  ## event-bus subscriptions: `register` assigns `replComponentRef` only
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
  if replComponentRef == self:
    replComponentRef = nil
  procCall unregister(Component(self))

method register*(self: ReplComponent, api: MediatorWithSubscribers) =
  ## Register the ReplComponent with the mediator. Its handlers feed the
  ## session's `ReplVM` once `initReplVMFromSession` has installed it.
  self.api = api
  if replComponentRef.isNil:
    replComponentRef = self
