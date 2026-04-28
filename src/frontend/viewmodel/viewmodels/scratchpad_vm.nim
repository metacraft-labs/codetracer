## viewmodels/scratchpad_vm.nim
##
## ScratchpadVM — ViewModel for the Scratchpad panel.
##
## Holds reactive state for:
## - Which scratchpad item is selected
## - Whether comparison mode is active (side-by-side view of two values
##   at different execution points)
##
## Usage:
##   let vm = createScratchpadVM(store)
##   echo vm.comparisonMode.val     # false
##   vm.toggleComparisonMode()
##   echo vm.comparisonMode.val     # true

import std/options

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ../store/replay_data_store

type
  ScratchpadVM* = ref object of ViewModel
    ## Reactive state for the Scratchpad panel.
    ##
    ## Mutable signals:
    ##   selectedItem    — index of the selected scratchpad item, or none
    ##   comparisonMode  — whether two values are shown side by side
    ##
    ## The store reference is kept for potential future backend queries.
    store*: ReplayDataStore

    # -- Mutable state --
    selectedItem*: Signal[Option[int]]
    comparisonMode*: Signal[bool]

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

proc selectItem*(vm: ScratchpadVM; index: Option[int]) =
  ## Set the selected scratchpad item. Pass `none(int)` to clear.
  vm.selectedItem.val = index

proc toggleComparisonMode*(vm: ScratchpadVM) =
  ## Toggle comparison mode on or off.
  vm.comparisonMode.val = not vm.comparisonMode.val

# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

proc createScratchpadVM*(store: ReplayDataStore): ScratchpadVM =
  ## Create a ScratchpadVM inside a reactive root owned by `withViewModel`.
  ## The reactive root is disposed via `vm.dispose()`.
  ##
  ## Sets up mutable signals with sensible defaults.
  withViewModel proc(dispose: proc()): ScratchpadVM =
    ScratchpadVM(
      store: store,
      selectedItem: createSignal(none(int)),
      comparisonMode: createSignal(false),
      disposeProc: dispose,
    )
