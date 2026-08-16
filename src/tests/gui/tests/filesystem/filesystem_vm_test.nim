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

proc makeSourceFoldersRoot(children: seq[FilesystemEntryNode]):
    FilesystemEntryNode =
  ## The production tree root: the synthetic "source folders" container
  ## that ``loadFilesystem`` builds.  It carries an EMPTY path because it
  ## is not a folder on disk, only a grouping node for the (possibly
  ## non-sibling) source folders below it.
  FilesystemEntryNode(
    id: "0",
    text: "source folders",
    path: "",
    icon: "",
    isFolder: true,
    isExpanded: true,
    diffClass: fdcNone,
    children: children,
  )

proc makeActiveFileTree(): FilesystemEntryNode =
  ## Tree used by the "reveal the active file" suite:
  ##
  ##   source folders            (synthetic, path "")
  ##   └── /proj
  ##       ├── /proj/src
  ##       │   ├── /proj/src/db
  ##       │   │   └── /proj/src/db/main.rs
  ##       │   └── /proj/src/ui
  ##       │       └── /proj/src/ui/view.rs
  ##       └── /proj/README.md
  ##
  ## ``src`` deliberately has TWO folder children and ``/proj`` has a
  ## folder plus a file, so the pre-existing single-child chain collapse
  ## (``collectSmartExpansionPaths``) contributes NOTHING below the
  ## synthetic root.  Any expansion of ``/proj``, ``/proj/src`` or
  ## ``/proj/src/db`` can therefore only have come from the active-file
  ## ancestor walk — without this shape the assertions would pass for
  ## the wrong reason.
  makeSourceFoldersRoot(@[
    makeEntry("proj", path = "/proj", isFolder = true, children = @[
      makeEntry("src", path = "/proj/src", isFolder = true, children = @[
        makeEntry("db", path = "/proj/src/db", isFolder = true, children = @[
          makeEntry("main.rs", path = "/proj/src/db/main.rs"),
        ]),
        makeEntry("ui", path = "/proj/src/ui", isFolder = true, children = @[
          makeEntry("view.rs", path = "/proj/src/ui/view.rs"),
        ]),
      ]),
      makeEntry("README.md", path = "/proj/README.md"),
    ]),
  ])

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

suite "lazy file-tree content roots (#574)":
  ## Regression cover for "Open Folder leaves the file tree on
  ## Loading...".  The index-process handler used to build the payload
  ## root with an unconditional ``join(data.trace.outputFolder, "files")``
  ## — and ``data.trace`` is nil in folder/edit mode, so the async handler
  ## rejected before it could answer and the stub was never replaced.

  test "no trace yields an empty payload root (the Open Folder case)":
    check traceFilesRootFor("") == ""

  test "a trace yields its files/ payload root":
    check traceFilesRootFor("/home/dev/.local/share/codetracer/trace-7") ==
      "/home/dev/.local/share/codetracer/trace-7/files"

  test "a trailing separator or backslashes do not double up":
    check traceFilesRootFor("/traces/trace-7/") == "/traces/trace-7/files"
    check traceFilesRootFor("D:\\traces\\trace-7") == "D:/traces/trace-7/files"

  test "folder mode reads from the live filesystem, never a trace payload":
    let root = pathContentRootFor(
      traceOutputFolder = "",
      traceImported = false,
      workspaceFolder = "/home/dev/project",
      requestedPath = "/home/dev/project/src/db")
    check root.filesRoot == ""
    check not root.selfContained

  test "an imported trace reads from its payload root":
    let root = pathContentRootFor(
      traceOutputFolder = "/traces/trace-7",
      traceImported = true,
      workspaceFolder = "",
      requestedPath = "/recorded/project/src")
    check root.filesRoot == "/traces/trace-7/files"
    check root.selfContained

  test "a stale trace does not hijack a path inside the opened folder":
    # Opening a folder does not clear the index process's previously
    # loaded trace, so without this guard the subtree would be read out
    # of an unrelated recording's payload.
    let root = pathContentRootFor(
      traceOutputFolder = "/traces/trace-7",
      traceImported = true,
      workspaceFolder = "/home/dev/project",
      requestedPath = "/home/dev/project/src/db")
    check root.filesRoot == ""
    check not root.selfContained

  test "the opened folder itself counts as inside the workspace":
    let root = pathContentRootFor(
      traceOutputFolder = "/traces/trace-7",
      traceImported = true,
      workspaceFolder = "/home/dev/project/",
      requestedPath = "/home/dev/project")
    check root.filesRoot == ""

  test "a sibling of the opened folder is not treated as inside it":
    # ``/home/dev/project-other`` must not match the ``/home/dev/project``
    # prefix — the guard compares path SEGMENTS, not raw string prefixes.
    let root = pathContentRootFor(
      traceOutputFolder = "/traces/trace-7",
      traceImported = true,
      workspaceFolder = "/home/dev/project",
      requestedPath = "/home/dev/project-other/src")
    check root.filesRoot == "/traces/trace-7/files"
    check root.selfContained

  test "isAncestorPathOf is strict, separator- and slash-tolerant":
    check isAncestorPathOf("/proj/src", "/proj/src/main.rs")
    check isAncestorPathOf("/proj/src/", "/proj/src/db/main.rs")
    check isAncestorPathOf("C:\\proj\\src", "C:/proj/src/main.rs")
    check isAncestorPathOf("/", "/proj/main.rs")
    # Not an ancestor of itself.
    check not isAncestorPathOf("/proj/src", "/proj/src")
    # Segment-aware, not a raw string prefix.
    check not isAncestorPathOf("/proj/src", "/proj/srcx/main.rs")
    # The synthetic container root is a grouping node, not a folder.
    check not isAncestorPathOf("", "/proj/main.rs")
    check not isAncestorPathOf("/proj", "")

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

  test "setRoot / clearRoot update loadingState":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)

      # Initial state is loading
      check vm.loadingState.val == lsLoading

      vm.setRoot(makeRoot(@[makeEntry("a.nim")]))
      check vm.loadingState.val == lsIdle

      vm.clearRoot()
      check vm.loadingState.val == lsLoading

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

  test "setRoot automatically performs smart expansion on single-child directories":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)

      # Build a tree:
      # /
      # └── src
      #     └── db-backend
      #         ├── file1.rs
      #         └── file2.rs
      let tree = makeRoot(@[
        makeEntry("src", path = "src", isFolder = true, children = @[
          makeEntry("db-backend", path = "src/db-backend", isFolder = true, children = @[
            makeEntry("file1.rs", path = "src/db-backend/file1.rs"),
            makeEntry("file2.rs", path = "src/db-backend/file2.rs")
          ])
        ])
      ])

      vm.setRoot(tree)

      # "/" should be expanded (only 1 child "src")
      check vm.isExpanded("/")
      # "src" should be expanded (only 1 child "db-backend")
      check vm.isExpanded("src")
      # "src/db-backend" should NOT be expanded (2 children)
      check not vm.isExpanded("src/db-backend")

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
# reveal the active file (#576)
# ---------------------------------------------------------------------------

suite "FilesystemVM reveals the active file":
  ## The Filesystem panel must auto-expand down to the file the debugger
  ## is stopped in.  Note that the pre-existing
  ## ``collectSmartExpansionPaths`` is a DIFFERENT feature (it collapses
  ## single-child folder chains, the VS Code "compact folders"
  ## affordance) and cannot satisfy any of the assertions below — see
  ## ``makeActiveFileTree``.

  test "trace load expands every ancestor of the active file":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)

      vm.setRoot(makeActiveFileTree())
      # Nothing on the way to the file is expanded by tree load alone.
      check not vm.isExpanded("/proj")
      check not vm.isExpanded("/proj/src")
      check not vm.isExpanded("/proj/src/db")

      store.updateDebuggerPosition(rrTicks = 1'u64,
                                   file = "/proj/src/db/main.rs",
                                   line = 12)

      check vm.isExpanded("/proj")
      check vm.isExpanded("/proj/src")
      check vm.isExpanded("/proj/src/db")
      # Siblings off the path stay closed …
      check not vm.isExpanded("/proj/src/ui")
      # … and the file itself is not a folder.
      check not vm.isExpanded("/proj/src/db/main.rs")

      dispose()

  test "expansion also happens when the tree arrives after the active file":
    # The index process sends ``filesystem-loaded`` before
    # ``trace-loaded``, but a re-mounted panel (or a session restore) can
    # deliver the tree after the debugger already has a position.  Both
    # orderings must reveal the file.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)

      store.updateDebuggerPosition(rrTicks = 1'u64,
                                   file = "/proj/src/db/main.rs",
                                   line = 12)
      check not vm.isExpanded("/proj/src/db")

      vm.setRoot(makeActiveFileTree())

      check vm.isExpanded("/proj")
      check vm.isExpanded("/proj/src")
      check vm.isExpanded("/proj/src/db")

      dispose()

  test "onFolderExpanded fires for each ancestor so lazy subtrees load":
    # Folders deeper than the edit-mode depth limit arrive as
    # "Loading..." stubs; only the ``onFolderExpanded`` bridge asks the
    # index process for their children.  A bulk ``expandedPaths`` write
    # would mark them open and leave them empty, so the ordering AND the
    # per-ancestor callback are both load-bearing.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)
      var expandedOrder: seq[string] = @[]
      vm.onFolderExpanded = proc(path: string) =
        expandedOrder.add(path)

      vm.setRoot(makeActiveFileTree())
      store.updateDebuggerPosition(rrTicks = 1'u64,
                                   file = "/proj/src/db/main.rs",
                                   line = 12)

      # Root-first: a parent must be expanded before the child it reveals.
      check expandedOrder == @["/proj", "/proj/src", "/proj/src/db"]

      dispose()

  test "a lazily filled subtree expands the next-deeper ancestor":
    # In folder/edit mode the tree is only loaded two levels deep, so
    # ``/proj/src/db`` is not in the tree at first.  When the index
    # process answers ``load-path-content`` the bridge re-publishes the
    # tree, and the newly revealed ancestor must expand in turn.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)
      var expandedOrder: seq[string] = @[]
      vm.onFolderExpanded = proc(path: string) =
        expandedOrder.add(path)

      # Depth-limited tree: ``/proj/src`` still shows the stub child.
      vm.setRoot(makeSourceFoldersRoot(@[
        makeEntry("proj", path = "/proj", isFolder = true, children = @[
          makeEntry("src", path = "/proj/src", isFolder = true, children = @[
            makeEntry("Loading...", path = ""),
          ]),
          makeEntry("README.md", path = "/proj/README.md"),
        ]),
      ]))
      store.updateDebuggerPosition(rrTicks = 1'u64,
                                   file = "/proj/src/db/main.rs",
                                   line = 12)

      check expandedOrder == @["/proj", "/proj/src"]
      check not vm.isExpanded("/proj/src/db")

      # The requested content arrives and the bridge re-publishes.
      vm.setRoot(makeActiveFileTree())

      check expandedOrder == @["/proj", "/proj/src", "/proj/src/db"]
      check vm.isExpanded("/proj/src/db")

      dispose()

  test "a manual collapse survives while the active file is unchanged":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)

      vm.setRoot(makeActiveFileTree())
      store.updateDebuggerPosition(rrTicks = 1'u64,
                                   file = "/proj/src/db/main.rs",
                                   line = 12)
      check vm.isExpanded("/proj/src/db")

      vm.collapsePath("/proj/src/db")
      check not vm.isExpanded("/proj/src/db")

      # Stepping within the same file must not fight the user.
      store.updateDebuggerPosition(rrTicks = 2'u64,
                                   file = "/proj/src/db/main.rs",
                                   line = 13)
      check not vm.isExpanded("/proj/src/db")

      # Moving to another file reveals that file's ancestors …
      store.updateDebuggerPosition(rrTicks = 3'u64,
                                   file = "/proj/src/ui/view.rs",
                                   line = 4)
      check vm.isExpanded("/proj/src/ui")
      # … and leaves the collapsed folder that is not on the new path alone.
      check not vm.isExpanded("/proj/src/db")

      # Coming back re-reveals it.
      store.updateDebuggerPosition(rrTicks = 4'u64,
                                   file = "/proj/src/db/main.rs",
                                   line = 12)
      check vm.isExpanded("/proj/src/db")

      dispose()

  test "a position with no source file expands nothing":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)

      vm.setRoot(makeActiveFileTree())
      store.updateDebuggerPosition(rrTicks = 1'u64, file = "", line = 0)

      check not vm.isExpanded("/proj")
      check not vm.isExpanded("/proj/src")

      dispose()

  test "a file outside the tree expands nothing":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)

      vm.setRoot(makeActiveFileTree())
      store.updateDebuggerPosition(rrTicks = 1'u64,
                                   file = "/elsewhere/lib/other.rs",
                                   line = 1)

      check not vm.isExpanded("/proj")
      check not vm.isExpanded("/proj/src")
      check not vm.isExpanded("/elsewhere")
      check not vm.isExpanded("/elsewhere/lib")

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
