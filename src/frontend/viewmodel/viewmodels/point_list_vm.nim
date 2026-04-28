## viewmodels/point_list_vm.nim
##
## PointListVM — ViewModel for the Point List (tracepoints / breakpoints)
## panel.
##
## Holds reactive state for:
## - Which point is selected
## - Which point is currently being edited (inline rename, condition, etc.)
##
## Usage:
##   let vm = createPointListVM(store)
##   echo vm.selectedPoint.val      # none(int)
##   vm.selectPoint(some(3))
##   echo vm.selectedPoint.val      # some(3)

import std/options

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ../store/replay_data_store

type
  PointListVM* = ref object of ViewModel
    ## Reactive state for the Point List panel.
    ##
    ## Mutable signals:
    ##   selectedPoint — index of the selected point, or none
    ##   editingPoint  — index of the point being edited, or none
    ##
    ## The store reference is kept for potential future backend queries
    ## (e.g. toggle-enable, delete point).
    store*: ReplayDataStore

    # -- Mutable state --
    selectedPoint*: Signal[Option[int]]
    editingPoint*: Signal[Option[int]]

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

proc selectPoint*(vm: PointListVM; index: Option[int]) =
  ## Set the selected point index. Pass `none(int)` to clear.
  vm.selectedPoint.val = index

proc startEditing*(vm: PointListVM; index: int) =
  ## Begin editing the point at `index`. Also selects that point.
  vm.editingPoint.val = some(index)
  vm.selectedPoint.val = some(index)

proc stopEditing*(vm: PointListVM) =
  ## Stop editing any point. Clears the editingPoint signal.
  vm.editingPoint.val = none(int)

# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

proc createPointListVM*(store: ReplayDataStore): PointListVM =
  ## Create a PointListVM inside a reactive root owned by `withViewModel`.
  ## The reactive root is disposed via `vm.dispose()`.
  ##
  ## Sets up mutable signals with sensible defaults.
  withViewModel proc(dispose: proc()): PointListVM =
    PointListVM(
      store: store,
      selectedPoint: createSignal(none(int)),
      editingPoint: createSignal(none(int)),
      disposeProc: dispose,
    )
