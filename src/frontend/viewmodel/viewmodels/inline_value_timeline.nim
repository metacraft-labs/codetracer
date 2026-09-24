## viewmodels/inline_value_timeline.nim — PLAT-29: inline values are drawn
## only when the locals they come from are about the stop the debugger is at.
##
## Editor-ViewModel.md §11 lists *"the DAP data that feeds inline values"*
## among the producers that compute outside, against a version, and are
## reconciled or discarded when stale. The version is the STOP
## (`store/stop_timeline`): every `ct/load-locals` answer names the stop it
## was requested at, and `ReplayDataStore.applyLocalsResponse` drops one the
## debugger has moved past, counted in `store.stops.report`.
##
## That is the ARRIVAL half. This module is the DRAW half, and it is needed
## because a dropped answer leaves the store holding the PREVIOUS stop's
## locals — and so does a move whose answer has not arrived yet. Either way
## the values in the store are about a stop the debugger has left, and a
## surface that drew them would put `x: 42` beside a line where `x` is now 7.
## So a surface asks here before it draws: the values when the locals are
## about the current stop, none otherwise. The verdict is `reconcile`'s,
## through the stop timeline — the same `pkInlineValues` row of its table the
## arrival went through — not a comparison written here.
##
## Every draw is counted in the gate's own `report`, apart from the store's
## arrival report, so "how often was a frame drawn with values withheld" is a
## number and cannot inflate the arrival figures.
##
## ## What is true of the shipped front-ends, said plainly
##
## The terminal and the GPUI window load the locals SYNCHRONOUSLY after each
## move (`native_host.loadStopPanes`), so by the time they draw, the answer
## for the current stop has arrived and the gate answers `roApplied`. The web
## renderer's answers are genuinely asynchronous and go through the same
## arrival reconciliation (`ui/state.syncStoreLocals`). The withheld arm on a
## native host is observed by `test_plat29_inline_values.nim`, which moves a
## REAL debugger between a real request and its answer.

import ../editor/reconcile
import ../store/replay_data_store
import ../../../common/view_vocabulary/editor_rows

type
  InlineValueGate* = object
    report*: StalenessReport
      ## One count per DRAW: `roApplied` when the values were drawn,
      ## `roDropped` when they were withheld.

proc installable*(g: var InlineValueGate; store: ReplayDataStore;
                  values: seq[EditorValue]): seq[EditorValue] =
  ## The values to draw now: `values` when the store's locals are about the
  ## stop the debugger is at, none when they are not — or when no request
  ## named the stop they were computed at.
  if store.isNil:
    return @[]
  store.observeStop()
  if not store.hasLocalsStamp:
    g.report.record(pkInlineValues, roDropped, drEvidenceDeleted)
    return @[]
  case store.stops.reconcileStamp(store.localsStamp, g.report)
  of roApplied, roMapped: values
  of roDropped: @[]
