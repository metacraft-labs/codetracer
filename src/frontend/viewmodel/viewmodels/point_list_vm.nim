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
import std/json
import ./action_sink

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
    actionSink*: ActionSink
      ## Set in a mirror session: user actions go to the primary
      ## (`action_sink`); nil on a primary.
    store*: ReplayDataStore

    # -- Mutable state --
    selectedPoint*: Signal[Option[int]]
      ## The selected row's INDEX in `points`, for a painter that draws rows by
      ## position. Local: a peer's list may hold the same points in another
      ## order, so an index is not something two front-ends can agree on.
    editingPoint*: Signal[Option[int]]
    selectedPointId*: Signal[string]
      ## THE SELECTION AS A PEER SEES IT: the selected row's stable `id`
      ## (`PointListEntry.id`), or "" for none. This is the field a shared
      ## session publishes; `selectPointById` is how an incoming selection
      ## lands, and it lands on the same POINT whatever position it holds here.

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
  ## Set the selected point index. Pass `none(int)` to clear. The stable id of
  ## the row at that index is selected with it, and that id — not the index —
  ## is what a mirror forwards, so the primary selects the same point even
  ## when its list is in a different order.
  let rows = vm.points.val
  let id =
    if index.isSome and index.get >= 0 and index.get < rows.len:
      rows[index.get].id
    else: ""
  if id.len > 0 and vm.actionSink.forwards("pointList", "selectPointById",
      %*{"id": id}):
    return
  if id.len == 0 and vm.actionSink.forwards("pointList", "selectPoint",
      %*{"index": sinkArg(index)}):
    return
  vm.selectedPoint.val = index
  vm.selectedPointId.val = id

proc selectPointById*(vm: PointListVM; id: string) =
  ## Select the row whose stable id is `id`, wherever it is in the list; ""
  ## (or an id no row carries) clears the selection.
  if vm.actionSink.forwards("pointList", "selectPointById", %*{"id": id}):
    return
  var index = none(int)
  for i, r in vm.points.val:
    if id.len > 0 and r.id == id:
      index = some(i)
      break
  vm.selectedPoint.val = index
  vm.selectedPointId.val = if index.isSome: id else: ""

proc indexOfPoint*(vm: PointListVM; id: string): int =
  ## Where the point with stable id `id` is in the list now, or -1.
  for i, r in vm.points.val:
    if r.id == id: return i
  -1

proc startEditing*(vm: PointListVM; index: int) =
  ## Begin editing the point at `index`. Also selects that point.
  if vm.actionSink.forwards("pointList", "startEditing",
      %*{"index": index}):
    return
  vm.editingPoint.val = some(index)
  vm.selectedPoint.val = some(index)

proc stopEditing*(vm: PointListVM) =
  ## Stop editing any point. Clears the editingPoint signal.
  if vm.actionSink.forwards("pointList", "stopEditing", %*{}):
    return
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
      selectedPointId: createSignal(""),
      points:
        if store.isNil: createSignal(newSeq[PointListEntry]())
        else: store.pointList.rows,
      disposeProc: dispose,
    )
