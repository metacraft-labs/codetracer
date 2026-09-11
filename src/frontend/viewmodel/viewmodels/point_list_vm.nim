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
  PointListEntry* = object
    kind*: string
    label*: string
    path*: string
    line*: int
      ## Where the point is, 1-based. **0 when it could not be located** —
      ## see `resolution` below. A row with `line == 0` is a row a pane must
      ## not offer as a jump target.
    enabled*: bool

    # -- PLAT-11 -----------------------------------------------------------
    #
    # Three fields added on 2026-09-11, when project definitions became the
    # first producer of this signal. Every one of them has a zero value that
    # is the pre-existing behaviour, so the two existing constructors — the
    # storybook fixture and this file's own default — are unchanged.
    collection*: string
      ## The named collection (Project-Definitions.md §4) this point came
      ## from, or "" for a point the user created. Collections "may be
      ## enabled and disabled as a unit", which a pane cannot offer if the
      ## unit is not on the row.
    resolution*: string
      ## What became of the point's anchor: `resolved`, `moved`,
      ## `unresolvable`, `file absent` — `resolve.describe`'s own words, never
      ## a second spelling of them.
      ##
      ## §4: "**A point whose location no longer resolves is reported, not
      ## dropped.** A collection that silently loses half its points as a file
      ## evolves is worse than one that says so." An unresolvable point is
      ## therefore IN this list, with this field saying so, rather than
      ## filtered out of it.
    detail*: string
      ## Why, for a point that did not resolve cleanly. What the user needs in
      ## order to fix the definition; empty for `resolved`.

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
  vm.points.val = @points

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
      points: createSignal(newSeq[PointListEntry]()),
      disposeProc: dispose,
    )
