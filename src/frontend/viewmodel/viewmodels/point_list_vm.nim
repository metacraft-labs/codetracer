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
import ../store/types as store_types

# `PointListEntry` MOVED TO `store/types.nim` and is re-exported here.
#
# It had to move for `points` to become the store's signal: the store is below
# every ViewModel in the import graph and cannot name a type this module
# declares. Re-exported so that the consumers which reach the type through
# `point_list_vm` — the storybook, `pane_views`, `point_collection_source`, the
# suites — are untouched.
export store_types.PointListEntry

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

    points*: Signal[seq[PointListEntry]]
      ## Alias of `store.pointList.rows` — the store's own signal, not a copy
      ## (a `Signal[T]` is a ref).
      ##
      ## This is what gives the pane TWO producers without a bridge between
      ## them: `point_collection_source.applyCollections` writes the points a
      ## project declares, and `ReplayDataStore.applyTracepointResults` writes
      ## what a `ct/run-tracepoints` sweep found. Before the rows moved to the
      ## store the second producer could not exist at all — a sweep is answered
      ## on the DAP channel, which the store owns and the ViewModel does not.

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

proc setPoints*(vm: PointListVM; points: openArray[PointListEntry]) =
  ## Replace the declared point rows.
  ##
  ## Routed through `ReplayDataStore.applyPointRows` rather than assigning the
  ## signal here, so that the definition-side producer and the engine-side one
  ## meet in the store instead of in whichever ViewModel happened to be built.
  ##
  ## The storeless branch is not a fallback for a bug: a `PointListVM` built on
  ## a `nil` store is a supported shape, and one suite uses it deliberately (see
  ## `createPointListVM`). Both branches write the SAME signal object when a
  ## store exists, so the only thing the store branch adds is settling
  ## `loadingState` — which a storeless VM has no reader for.
  if vm.store.isNil:
    vm.points.val = @points
  else:
    vm.store.applyPointRows(@points)

# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

proc createPointListVM*(store: ReplayDataStore): PointListVM =
  ## Create a PointListVM inside a reactive root owned by `withViewModel`.
  ## The reactive root is disposed via `vm.dispose()`.
  ##
  ## Sets up mutable signals with sensible defaults.
  ##
  ## `store` MAY BE NIL, and that is a supported shape rather than an
  ## oversight. `test_point_collections_fill_the_point_list.nim` passes `nil`
  ## on purpose — its claim is that the project-definitions producer talks to
  ## no backend at all, and a `nil` store is the strongest available statement
  ## of that. A VM built that way owns its own `points` signal; every other VM
  ## shares the store's, which is what lets a sweep and a collection write one
  ## list.
  withViewModel proc(dispose: proc()): PointListVM =
    PointListVM(
      store: store,
      selectedPoint: createSignal(none(int)),
      editingPoint: createSignal(none(int)),
      points:
        if store.isNil: createSignal(newSeq[PointListEntry]())
        else: store.pointList.rows,
      disposeProc: dispose,
    )
