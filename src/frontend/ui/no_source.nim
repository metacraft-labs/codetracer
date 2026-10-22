## frontend/ui/no_source.nim
##
## NoSource panel host module.  The IsoNim view at
## ``viewmodel/views/isonim_no_source_view.nim`` is the primary
## renderer; this module exposes the direct DOM host helper plus the
## asm-load + history-jump helpers that feed the IsoNim ``NoSourceVM``.
##
## Lifecycle:
## 1. ``openNoSourceView`` (in ``utils.nim``) creates a
##    ``NoSourceComponent`` and stashes it on its parent
##    ``EditorViewComponent.noInfo`` field.
## 2. The editor direct GoldenLayout mount path calls
##    ``renderNoSourceShellDirect`` with the temporary
##    ``editorComponent-{id}`` placeholder.
## 3. ``renderNoSourceShellDirect`` replaces that placeholder with the
##    stable ``<div id="no-source-{id}" class="unknown-location">``
##    shell and mounts the IsoNim ``renderNoSourcePanel`` view inside it,
##    synchronously: the shell it has just inserted is the host.
##    Subsequent renders are driven by the VM's reactive signals.
## 4. Callers feed live data into the VM via ``syncNoSourceVM``.

import
  ui_imports, strutils,
  ../[ communication, event_helpers ],
  ../../common/ct_event
from ../rr_gdb import RRGDBStopSignal

# ---------------------------------------------------------------------------
# ViewModel layer — IsoNim is the primary renderer for the no-source panel.
# ---------------------------------------------------------------------------
import std/json
import ../viewmodel/store/replay_data_store
from ../viewmodel/store/types as vmtypes import
  NoSourceLocationInfo, NoSourceHistoryInfo
import ../viewmodel/viewmodels/no_source_vm
when defined(js):
  from isonim/web/dom_api import nil
  from ../viewmodel/views/isonim_no_source_view import mountIsoNimNoSource

const
  NO_CODE = -1
  NO_PATH = ""

# The session's ViewModel, handed over by ``initNoSourceVMFromSession`` from
# ``ui_js.configureMiddleware``.
var noSourceVMInstance*: NoSourceVM
var noSourceVMStore: ReplayDataStore

proc asmLoad(self: EditorService, location: types.Location): Future[Instructions] {.async.} =
  var name = cstring""
  var functionLocation = FunctionLocation(
    path: location.path,
    name: location.functionName,
    key: location.key,
    forceReload: location.path.split(".")[^1] == "nr"  # Force reload on move for noir files
  )
  name = cstring(fmt"{functionLocation.path}:{functionLocation.name}:{functionLocation.key}")

  let instructions = await self.data.asyncSend("asm-load", functionLocation, $name, Instructions)
  return instructions

proc getAsmCode(self: NoSourceComponent, location: types.Location) {.async.} =
  self.instructions = await data.services.editor.asmLoad(location)
  self.data.redraw()

proc historyJump*(self: NoSourceComponent, location: types.Location) =
  self.api.historyJump(location)

# ---------------------------------------------------------------------------
# IsoNim VM bridge
# ---------------------------------------------------------------------------

proc syncNoSourceVM*(self: NoSourceComponent) =
  ## Push the legacy component's view of the world into the IsoNim
  ## ``NoSourceVM`` so the IsoNim view re-renders.  Mirrors the data
  ## the legacy Karax ``method render`` consumed: the free-form
  ## message, the current high-level location, the optional jump
  ## history, the originating address, and the optional stop-signal
  ## text.
  ##
  ## Safe to call before the VM exists — early calls are dropped, the
  ## next sync after the VM is created will fill it in.
  if noSourceVMInstance.isNil:
    return

  noSourceVMInstance.setMessage($self.message)

  let metaInfo = data.services.debugger.location
  let location = vmtypes.NoSourceLocationInfo(
    functionName: $metaInfo.highLevelFunctionName,
    path: (if metaInfo.highLevelPath != NO_PATH: $metaInfo.highLevelPath else: ""),
    line: (if metaInfo.highLevelLine != NO_CODE: metaInfo.highLevelLine else: -1),
  )
  noSourceVMInstance.setLocation(location)

  let jumpHistory = self.data.services.debugger.jumpHistory
  if jumpHistory.len >= 2:
    let prev = jumpHistory[^2].location
    let action = jumpHistory[^1].lastOperation
    noSourceVMInstance.setHistory(vmtypes.NoSourceHistoryInfo(
      hasHistory: true,
      previousPath: $prev.path,
      action: $action,
      # THE DESTINATION, not only the caption. `prev` is a full
      # `types.Location`; the panel used to keep its path for the "We were
      # in '…'" line and drop everything the debugger navigates by, so the
      # Jump-back button had nowhere to send anyone. See
      # `NoSourceHistoryInfo.previousRRTicks`.
      previousLine: prev.line,
      previousRRTicks: prev.rrTicks,
    ))
  else:
    noSourceVMInstance.setHistory(vmtypes.NoSourceHistoryInfo())

  if self.instructions.address != 0:
    noSourceVMInstance.setOriginatingAddress("0x" & toHex(self.instructions.address))
  else:
    noSourceVMInstance.setOriginatingAddress("")

  let signal = self.data.services.debugger.stopSignal
  if signal notin {NoStopSignal, OtherStopSignal}:
    noSourceVMInstance.setStopSignalText($signal)
  else:
    noSourceVMInstance.setStopSignalText("")

# ---------------------------------------------------------------------------
# Mount helper — Web only
# ---------------------------------------------------------------------------

when defined(js):
  proc renderNoSourceShellDirect*(self: NoSourceComponent;
                                  placeholder: dom_api.Element) =
    ## Materialise the no-source shell through direct DOM and IsoNim.
    ##
    ## Preserve the stable ``no-source-{id}`` host, asm-load side effect,
    ## VM sync, and IsoNim mount lifecycle.
    let history = self.data.services.debugger.jumpHistory
    if history.len >= 1 and self.instructions == Instructions():
      discard self.getAsmCode(history[^1].location)

    syncNoSourceVM(self)

    let shell = dom_api.createElement(dom_api.document, cstring"div")
    dom_api.setAttribute(shell, cstring"id", cstring("no-source-" & $self.id))
    dom_api.setAttribute(shell, cstring"class", cstring"unknown-location")

    let parent = placeholder.parentNode
    if dom_api.isNodeNil(parent):
      return
    discard dom_api.replaceChild(
      parent,
      dom_api.Node(shell),
      dom_api.Node(placeholder))

    # The shell is the host, and it exists now: mount the view into it.
    if not noSourceVMInstance.isNil:
      mountIsoNimNoSource(shell, noSourceVMInstance)
# ---------------------------------------------------------------------------
# VM lifecycle hooks called from ui_js.configureMiddleware.
# ---------------------------------------------------------------------------

proc initNoSourceVMFromSession*(vm: NoSourceVM) =
  ## Hand the pane the session's `NoSourceVM` — the one
  ## `initializePanelViewModels` built on the session's store, so every
  ## reader of the session sees the same instance (Shared-DOM-Front-Ends D1).
  ##
  let store = vm.store
  noSourceVMStore = store
  noSourceVMInstance = vm
  clog "NoSourceVM: the session's instance installed"
