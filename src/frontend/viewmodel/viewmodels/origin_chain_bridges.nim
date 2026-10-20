## viewmodels/origin_chain_bridges.nim
##
## The bridges that connect the State Pane's origin badge, the
## `OriginChainVM` and the Scratchpad (Value-Origin-Tracking.md §3.2.1,
## §3.2.2, §3.3, §3.5).
##
## `StateVM` does not import `OriginChainVM`, and `OriginChainVM` does not
## import `ScratchpadVM`; each exposes a nilable proc field the host fills
## in. This module is the ONE place that fills them, so the renderer
## (`ui/state.nim`) and the headless suites
## (`tests/unit/test_origin_chain_vm.nim`) exercise the same wiring. When
## each wrote its own closures, the suites assigned a pin bridge the
## renderer never installed, and "Pin to scratchpad" did nothing in the
## product while its test passed (codetracer#856).

import std/options

import isonim/core/signals

import ../store/types
from ../store/stop_timeline import stopIdentityOf
import origin_chain_types
import origin_chain_vm
import state_vm
import scratchpad_vm

proc wireOriginChainBridges*(stateVM: StateVM; originVM: OriginChainVM;
                             scratchpad: proc(): ScratchpadVM) =
  ## Install every bridge between `stateVM`, `originVM` and the Scratchpad:
  ##
  ## - `StateVM.onShowOriginProc` — "Show value origin" (the row's context
  ##   menu, the command palette, `origin(expr)` watches): fetch the chain
  ##   and open the side panel (§3.1, §3.2.2).
  ## - `StateVM.onLoadOriginChainProc` — the badge expanding a row, or a row
  ##   left expanded across a move (`StateVM`'s re-ask effect), whose
  ##   chain at this stop is not held: fetch it for the in-row block, once
  ##   per row per stop, leaving the side panel, its chain and its pending
  ##   request alone (§3.2.1).
  ## - `StateVM.originChainLookup` — the chain the in-row block draws: the
  ##   row's own chain, answered at the current stop
  ##   (`OriginChainVM.rowChainAt`).
  ## - `OriginChainVM.onPinChainProc` — "Pin to scratchpad" (§3.3, §3.5):
  ##   append the chain to the Scratchpad's chain cards.
  ##
  ## `scratchpad` is resolved at each pin, not now: the renderer builds the
  ## OriginChainVM before the Scratchpad pane's VM exists and later swaps
  ## that VM for the session's. While it returns nil a pin is still
  ## recorded in `OriginChainVM.pinnedChains`, and reaches no Scratchpad.
  stateVM.onShowOriginProc = proc(expression: string; location: Location) =
    originVM.onShowOrigin(expression, location)
  stateVM.onLoadOriginChainProc = proc(expression: string;
                                       location: Location) =
    originVM.loadRowChain(expression, location)
  stateVM.originChainLookup = proc(name: string): Option[OriginChain] =
    # Reactive in both the stop and the answers: a move hides the previous
    # stop's chain at once, and an answer draws as soon as it lands.
    if stateVM.store.isNil:
      return none(OriginChain)
    originVM.rowChainAt(name, stopIdentityOf(stateVM.store.debugger.val))
  originVM.onPinChainProc = proc(chain: OriginChain) =
    let target = if scratchpad.isNil: nil else: scratchpad()
    if not target.isNil:
      target.addChain(chain)
  # Sync the OriginChainVM preferences signal into the StateVM mirror
  # so badge text / icon / function-suffix follow the user's chosen
  # style.  The OriginChainVM owns the canonical preferences; the
  # StateVM mirror is read by the row renderer.
  stateVM.originPreferences.val = originVM.preferences.val
