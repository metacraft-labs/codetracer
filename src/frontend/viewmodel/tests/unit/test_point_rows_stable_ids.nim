## test_point_rows_stable_ids.nim — every point row carries a stable id, and a
## selection names the point rather than its position.
##
## The collaboration registry recorded it as the blocker:
## "`PointListVM.points` … Point rows need stable ids before concurrent list
## operations" and "`selectedPoint` … Current field is an index". A peer whose
## list holds the same points in a different order — a sweep merged in, a
## project's collection re-read after an edit — selected a different point by
## the same index. Now:
##
##   * the store writes `PointListEntry.id` on every write of the list
##     (`replay_data_store.withStableIds`), derived from what the point IS;
##   * a project collection's point keeps its id when an edit MOVES its line;
##   * `selectPoint` records the selected row's id and `selectPointById`
##     lands on the same point wherever it now is;
##   * re-reading a checkout's collections keeps the user's own breakpoints
##     (`point_collection_source.mergeCollections`).
##
## ## ONE STAND-IN, AND WHY
##
## `MockBackendService` is the transport `createReplayDataStore` requires. It
## answers nothing that is asserted: every write here is a STORE write. The
## rows come from the product's own producers — the breakpoint decoder
## (`applyVerifiedBreakpoints`), the sweep decoder (`applyTracepointResults`
## is not needed here) and PLAT-11's collection producer over the real
## loader and resolver.

import std/[options, sets, unittest]

import isonim/core/signals
import isonim/viewmodel

import ../../backend/mock_backend
import ../../store/[replay_data_store, types]
import ../../viewmodels/[point_list_vm, point_collection_source]
import ../../../../common/project_definitions

proc newStore(): ReplayDataStore =
  let mock = newMockBackendService(autoRespond = true)
  createReplayDataStore(mock.toBackendService())

const Points = """
schema = "codetracer.points.v1"

[[collection]]
name = "the request path"
enabled = true

[[collection.point]]
kind = "breakpoint"
path = "src/router.nim"
anchor = "proc handleRequest"
"""

proc collectionsOf(lines: seq[string]): seq[CollectionResolution] =
  let loaded = loadProjectDefinitions([DefinitionFile(kind: dfkPoints,
    origin: doProject, scope: "", path: ".codetracer/points.toml",
    text: Points)])
  for c in allCollections(loaded):
    var r = CollectionResolution(collection: c)
    for p in c.points:
      r.points.add resolvePoint(p, lines, true)
    result.add r

suite "point rows carry stable ids":

  test "a breakpoint's id is its place; a list re-ordered keeps every id":
    let store = newStore()
    store.applyVerifiedBreakpoints("/w/a.py", [3, 9])
    let rows = store.pointList.rows.val
    check rows.len == 2
    check rows[0].id == "breakpoint:/w/a.py:3:0"
    check rows[1].id == "breakpoint:/w/a.py:9:0"
    # Another file's breakpoint written later does not renumber the first two.
    store.applyVerifiedBreakpoints("/w/b.py", [1])
    let after = store.pointList.rows.val
    check after.len == 3
    check after[0].id == rows[0].id
    check after[1].id == rows[1].id

  test "a collection point keeps its id when an edit moves its line":
    let store = newStore()
    let vm = createPointListVM(store)
    defer: vm.dispose()
    vm.mergeCollections(collectionsOf(@["import x", "proc handleRequest() ="]),
                        toHashSet(["the request path"]), "/w")
    let before = vm.points.val
    check before.len == 1
    check before[0].line == 2
    check before[0].path == "/w/src/router.nim"
    vm.mergeCollections(collectionsOf(@["# a", "# b", "import x",
                                        "proc handleRequest() ="]),
                        toHashSet(["the request path"]), "/w")
    let moved = vm.points.val
    check moved.len == 1
    check moved[0].line == 4
    check moved[0].id == before[0].id
    check moved[0].id == "collection:the request path:breakpoint:" &
                         "/w/src/router.nim:proc handleRequest"

  test "re-reading a collection keeps the user's own breakpoints":
    let store = newStore()
    let vm = createPointListVM(store)
    defer: vm.dispose()
    store.applyVerifiedBreakpoints("/w/a.py", [5])
    vm.mergeCollections(collectionsOf(@["proc handleRequest() ="]),
                        toHashSet(["the request path"]), "/w")
    vm.mergeCollections(collectionsOf(@["proc handleRequest() ="]),
                        toHashSet(["the request path"]), "/w")
    let rows = vm.points.val
    check rows.len == 2
    check rows[0].id == "breakpoint:/w/a.py:5:0"
    check rows[1].collection == "the request path"

  test "a selection names the point, wherever it is in the list":
    let store = newStore()
    let vm = createPointListVM(store)
    defer: vm.dispose()
    store.applyVerifiedBreakpoints("/w/a.py", [3, 9])
    vm.selectPoint(some(1))
    check vm.selectedPointId.val == "breakpoint:/w/a.py:9:0"
    # A peer's list holds the same points in the other order: the id lands on
    # the same point, at ITS index.
    var reordered = store.pointList.rows.val
    swap(reordered[0], reordered[1])
    store.applyPointRows(reordered)
    vm.selectPointById(vm.selectedPointId.val)
    check vm.selectedPoint.val == some(0)
    check vm.points.val[0].line == 9
    check vm.indexOfPoint("breakpoint:/w/a.py:3:0") == 1
    # An id no row carries clears the selection rather than keeping a stale
    # index.
    vm.selectPointById("breakpoint:/w/a.py:77:0")
    check vm.selectedPoint.val.isNone
    check vm.selectedPointId.val == ""

  test "two identical points are told apart, stably":
    let rows = withStableIds(@[
      PointListEntry(kind: PointKindTracepoint, path: "/w/a.py", line: 4),
      PointListEntry(kind: PointKindTracepoint, path: "/w/a.py", line: 4)])
    check rows[0].id == "tracepoint:/w/a.py:4"
    check rows[1].id == "tracepoint:/w/a.py:4#2"
    # Written again, the ids are the same ids.
    check withStableIds(rows) == rows
