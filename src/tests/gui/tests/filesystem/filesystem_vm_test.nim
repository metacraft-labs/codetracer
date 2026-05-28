## test_filesystem_vm.nim
##
## Unit tests for FilesystemVM — the ViewModel for the Filesystem panel.
##
## Verifies:
## - Initial-state defaults (rootEntry, expandedPaths, diff/deep-review,
##   isEmpty/hasDiff/totalEntryCount memos).
## - setRoot / clearRoot (filesystem-loaded event flow + session reset).
## - toggleExpanded / expandPath / collapsePath / isExpanded
##   (twisty / jstree-open-state mirror).
## - setDiffEntries (legacy ``data.startOptions.diff.files`` read).
## - setDeepReview (legacy ``deepReviewActive`` / ``deepReviewData`` pair,
##   including the wipe-on-deactivate guarantee).
##
## Co-located per the Test-Co-Location-Convention so the panel's
## ViewModel tests live alongside the panel module's surface area in
## the gui-tests tree.
##
## Compile and run:
##   nim c -r src/tests/gui/tests/filesystem/filesystem_vm_test.nim

import std/[sets, unittest]
import vm_test_helpers
import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import backend/backend_service
import backend/mock_backend
import store/types
import store/replay_data_store
import viewmodels/filesystem_vm
import ../../../../common/trace_source_paths

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc makeStoreWithMock(autoRespond: bool = true):
    tuple[store: ReplayDataStore, mock: MockBackendService] =
  let mock = newMockBackendService(autoRespond = autoRespond)
  let store = createReplayDataStore(mock.toBackendService())
  (store, mock)

proc makeEntry(text: string;
               path: string = "";
               isFolder: bool = false;
               children: seq[FilesystemEntryNode] = @[];
               diffClass: FilesystemDiffClass = fdcNone): FilesystemEntryNode =
  ## Test fixture builder for ``FilesystemEntryNode`` rows.  Mirrors
  ## the helper in ``isonim_views_test.nim`` so the same shape works
  ## for both the headless view tests and the VM-only tests here.
  FilesystemEntryNode(
    id: "",
    text: text,
    path: (if path.len > 0: path else: text),
    icon: "",
    isFolder: isFolder,
    isExpanded: false,
    diffClass: diffClass,
    children: children,
  )

proc makeRoot(children: seq[FilesystemEntryNode]): FilesystemEntryNode =
  ## Build a synthetic non-empty root holding ``children``.
  FilesystemEntryNode(
    id: "0",
    text: "/",
    path: "/",
    icon: "",
    isFolder: true,
    isExpanded: true,
    diffClass: fdcNone,
    children: children,
  )

# ---------------------------------------------------------------------------
# Initial state
# ---------------------------------------------------------------------------

suite "self-contained source path candidates":

  test "absolute Noir replay paths also resolve relative to the recorded workdir":
    let candidates = selfContainedSourcePayloadCandidates(
      "/home/dev/project/src/main.nr",
      "/home/dev/project")
    check candidates == @[
      "home/dev/project/src/main.nr",
      "src/main.nr"
    ]

  test "source folders provide a portable fallback when workdir is unavailable":
    let candidates = selfContainedSourcePayloadCandidates(
      "/workspace/project/src/main.c",
      "",
      ["/workspace/project"])
    check candidates == @[
      "workspace/project/src/main.c",
      "src/main.c"
    ]

  test "relative payload paths are preserved without adding root-stripped variants":
    let candidates = selfContainedSourcePayloadCandidates(
      "src/shield.nr",
      "/home/dev/project")
    check candidates == @["src/shield.nr"]

  test "windows absolute paths resolve to drive-stripped and workdir-relative payloads":
    let candidates = selfContainedSourcePayloadCandidates(
      "D:\\repo\\game\\src\\main.nr",
      "D:\\repo\\game")
    check candidates == @[
      "repo/game/src/main.nr",
      "src/main.nr"
    ]

suite "FilesystemVM initial state":

  test "rootEntry defaults to the empty placeholder":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)

      check vm.rootEntry.val.text == ""
      check vm.rootEntry.val.path == ""
      check vm.rootEntry.val.children.len == 0
      check vm.rootEntry.val.diffClass == fdcNone

      dispose()

  test "expanded set + diff + deep-review default to empty":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)

      check vm.expandedPaths.val.len == 0
      check vm.diffEntries.val.len == 0
      check not vm.deepReviewActive.val
      check vm.deepReviewFiles.val.len == 0

      dispose()

  test "isEmpty / hasDiff / totalEntryCount memos report the empty branch":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)

      check vm.isEmpty.val
      check not vm.hasDiff.val
      check vm.totalEntryCount.val == 0

      dispose()

  test "store reference is preserved":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)

      # The VM holds the same store ref the factory was given.  We
      # assert ``not nil`` plus a behavioural sanity check (the store
      # is the one constructed via ``makeStoreWithMock``) without
      # using ``cast[pointer]`` — that does not survive the JS
      # backend's emit (it lowers to ``==`` of empty operands and
      # crashes node).
      check not vm.store.isNil
      check vm.store == store

      dispose()

# ---------------------------------------------------------------------------
# setRoot / clearRoot
# ---------------------------------------------------------------------------

suite "FilesystemVM setRoot / clearRoot":

  test "setRoot replaces the tree wholesale":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)

      vm.setRoot(makeRoot(@[
        makeEntry("a.nim"),
        makeEntry("b.nim"),
      ]))

      check vm.rootEntry.val.children.len == 2
      check not vm.isEmpty.val
      # root + a.nim + b.nim
      check vm.totalEntryCount.val == 3

      vm.setRoot(makeRoot(@[makeEntry("only.nim")]))
      check vm.rootEntry.val.children.len == 1
      check vm.totalEntryCount.val == 2

      dispose()

  test "clearRoot returns to the empty branch":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)

      vm.setRoot(makeRoot(@[makeEntry("a.nim")]))
      check not vm.isEmpty.val

      vm.clearRoot()
      check vm.isEmpty.val
      check vm.rootEntry.val.text == ""
      check vm.totalEntryCount.val == 0

      dispose()

  test "openFile invokes the installed editor bridge":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)
      var openedPath = ""
      vm.onOpenFile = proc(path: string) =
        openedPath = path

      vm.openFile("/trace/files/Nargo.toml")
      check openedPath == "/trace/files/Nargo.toml"

      openedPath = ""
      vm.openFile("")
      check openedPath == ""

      dispose()

  test "isEmpty stays true when only deep-review is empty":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)

      vm.setDeepReview(true)
      check vm.isEmpty.val
      check vm.deepReviewActive.val
      check vm.deepReviewFiles.val.len == 0

      dispose()

  test "totalEntryCount counts every nested descendant":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)

      vm.setRoot(makeRoot(@[
        makeEntry("src", path = "src", isFolder = true, children = @[
          makeEntry("a.nim", path = "src/a.nim"),
          makeEntry("nested", path = "src/nested", isFolder = true,
                    children = @[
                      makeEntry("deep.nim", path = "src/nested/deep.nim"),
                    ]),
        ]),
        makeEntry("README.md"),
      ]))
      # root + src + a.nim + nested + deep.nim + README.md = 6
      check vm.totalEntryCount.val == 6

      dispose()

# ---------------------------------------------------------------------------
# expand / collapse / toggle
# ---------------------------------------------------------------------------

suite "FilesystemVM expand / collapse / toggle":

  test "toggleExpanded flips the membership in expandedPaths":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)

      check not vm.isExpanded("src")
      vm.toggleExpanded("src")
      check vm.isExpanded("src")
      vm.toggleExpanded("src")
      check not vm.isExpanded("src")

      dispose()

  test "expandPath / collapsePath are idempotent":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)

      vm.expandPath("a")
      vm.expandPath("a")
      vm.expandPath("a")
      check vm.expandedPaths.val.len == 1

      vm.collapsePath("missing")
      check vm.expandedPaths.val.len == 1

      vm.collapsePath("a")
      vm.collapsePath("a")
      check vm.expandedPaths.val.len == 0

      dispose()

  test "expandedPaths can hold multiple unrelated paths":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)

      vm.expandPath("a")
      vm.expandPath("b")
      vm.expandPath("c/d")
      check vm.expandedPaths.val.len == 3
      check vm.isExpanded("a")
      check vm.isExpanded("b")
      check vm.isExpanded("c/d")
      check not vm.isExpanded("c")

      dispose()

# ---------------------------------------------------------------------------
# diff entries
# ---------------------------------------------------------------------------

suite "FilesystemVM diff entries":

  test "setDiffEntries replaces the diff list and updates hasDiff":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)

      check not vm.hasDiff.val

      vm.setDiffEntries([
        FilesystemDiffEntry(path: "a.nim", zebra: false),
        FilesystemDiffEntry(path: "b.nim", zebra: true),
      ])
      check vm.diffEntries.val.len == 2
      check vm.hasDiff.val
      check not vm.isEmpty.val

      vm.setDiffEntries([])
      check vm.diffEntries.val.len == 0
      check not vm.hasDiff.val

      dispose()

# ---------------------------------------------------------------------------
# deep review
# ---------------------------------------------------------------------------

suite "FilesystemVM deep review":

  test "setDeepReview(true, files) stores the file list":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)

      vm.setDeepReview(true, [
        FilesystemDeepReviewFile(path: "a", baseName: "a", status: "A",
                                 linesAdded: 1, linesRemoved: 0,
                                 coverageExecuted: 0, coverageTotal: 0),
        FilesystemDeepReviewFile(path: "b", baseName: "b", status: "M",
                                 linesAdded: 0, linesRemoved: 1,
                                 coverageExecuted: 0, coverageTotal: 0),
      ])

      check vm.deepReviewActive.val
      check vm.deepReviewFiles.val.len == 2
      check vm.deepReviewFiles.val[0].status == "A"
      check vm.deepReviewFiles.val[1].status == "M"
      check not vm.isEmpty.val

      dispose()

  test "setDeepReview(false, files) wipes any pending list":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)

      vm.setDeepReview(true, [
        FilesystemDeepReviewFile(path: "x", baseName: "x", status: "A",
                                 linesAdded: 1, linesRemoved: 0,
                                 coverageExecuted: 0, coverageTotal: 0),
      ])
      check vm.deepReviewFiles.val.len == 1

      # Pass a non-empty seq with active=false; the VM must drop it
      # rather than leaking a stale list.
      vm.setDeepReview(false, [
        FilesystemDeepReviewFile(path: "y", baseName: "y", status: "M",
                                 linesAdded: 0, linesRemoved: 1,
                                 coverageExecuted: 0, coverageTotal: 0),
      ])
      check not vm.deepReviewActive.val
      check vm.deepReviewFiles.val.len == 0

      dispose()
