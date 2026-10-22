## test_filesystem_vm.nim
##
## Unit tests for FilesystemVM — the ViewModel for the Filesystem panel.
##
## Verifies:
## - Initial-state defaults (rootEntry, expandedPaths, diff,
##   isEmpty/hasDiff/totalEntryCount memos).
## - setRoot / clearRoot (filesystem-loaded event flow + session reset).
## - toggleExpanded / expandPath / collapsePath / isExpanded
##   (twisty / jstree-open-state mirror).
## - setDiffEntries (legacy ``data.startOptions.diff.files`` read).
## - A root load that fails or comes back empty (#785): the pane must end on
##   a tree, an empty state or an error, never on a permanent "Loading...".
##   The view is rendered through ``MockRenderer`` (isonim/testing/mock_dom),
##   the in-memory DOM the headless view tests use, because the assertion is
##   about which overlay the user sees, and only the view decides that.
## - The roots an imported trace's file tree is built from (#785).  The rule
##   is pure; the payload is described by a predicate instead of a directory
##   on disk, so each case states exactly which payload folders hold files.
## - Where a lazily loaded payload folder is read (`payloadPathOf` /
##   `payloadReadPathFor`): a location relative to `files/`, refused when it
##   is empty, absolute or leaves `files/` (`..`).
##
## DR-R8 removed ``setDeepReview`` / ``deepReviewFiles`` /
## ``FilesystemDeepReviewFile`` and the "FilesystemVM deep review" suite that
## covered them.  They were dead: no production code ever called the setter,
## so the compact one-line-per-file list the panel's view rendered from them
## was permanently empty.  The review's changed-file list is the VCS panel's
## (DeepReview-GUI.md §2, "Modified files list | The VCS panel's Changed Files
## section"), covered by ``src/tests/gui/tests/vcs/vcs_view_test.nim`` and
## ``vcs_vm_test.nim``.
##
## Co-located per the Test-Co-Location-Convention so the panel's
## ViewModel tests live alongside the panel module's surface area in
## the gui-tests tree.
##
## Compile and run:
##   nim c -r src/tests/gui/tests/filesystem/filesystem_vm_test.nim

import std/[sets, strutils, tables, unittest]
import vm_test_helpers
import isonim/core/[signals, computation, owner]
import isonim/viewmodel
import backend/backend_service
import backend/mock_backend
import store/types
import store/replay_data_store
import viewmodels/filesystem_vm
import views/isonim_filesystem_view
import isonim/testing/mock_dom
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

suite "payload locations of lazily loaded folders":
  ## A trace payload's Files tree arrives one level at a time
  ## (`Viewport-Driven-Loading.md` § V5, codetracer-pm issue
  ## 2026-10-21-filesystem-pane-renders-the-whole-enclosing-checkout-
  ## expanded-and-freezes-the-window.md).  Each payload node carries the
  ## place it was read from (`payloadPath`), and the lazy load of a folder
  ## reads from there again.  The value comes back from the renderer, so the
  ## index process may only follow it INSIDE the payload.

  const filesRoot = "/traces/trace-7/files"

  test "a node's payload location is relative to files/":
    check payloadPathOf(filesRoot, "/traces/trace-7/files/src") == "src"
    check payloadPathOf(filesRoot, "/traces/trace-7/files/home/dev/p/lib") ==
      "home/dev/p/lib"
    check payloadPathOf("D:\\traces\\t\\files", "D:\\traces\\t\\files\\src\\a") ==
      "src/a"

  test "a node outside the payload has no payload location":
    check payloadPathOf(filesRoot, "/home/dev/p/src") == ""
    check payloadPathOf(filesRoot, filesRoot) == ""
    check payloadPathOf(filesRoot, "/traces/trace-7/filesx/src") == ""
    check payloadPathOf("", "/traces/trace-7/files/src") == ""

  test "a relative payload location is read below files/":
    check payloadReadPathFor(filesRoot, "src") == "/traces/trace-7/files/src"
    check payloadReadPathFor(filesRoot, "home/dev/p/lib") ==
      "/traces/trace-7/files/home/dev/p/lib"
    check payloadReadPathFor(filesRoot & "/", "src\\lib") ==
      "/traces/trace-7/files/src/lib"
    check payloadReadPathFor(filesRoot, "./src//lib/") ==
      "/traces/trace-7/files/src/lib"

  test "the location round-trips through payloadPathOf":
    let readPath = "/traces/trace-7/files/home/dev/p/src"
    check payloadReadPathFor(filesRoot, payloadPathOf(filesRoot, readPath)) ==
      readPath

  test "an empty location, or no payload, is refused":
    check payloadReadPathFor(filesRoot, "") == ""
    check payloadReadPathFor(filesRoot, ".") == ""
    check payloadReadPathFor(filesRoot, "/") == ""
    check payloadReadPathFor("", "src") == ""

  test "a location with a .. segment is refused":
    check payloadReadPathFor(filesRoot, "..") == ""
    check payloadReadPathFor(filesRoot, "../trace-8/files/src") == ""
    check payloadReadPathFor(filesRoot, "src/../../../etc") == ""
    check payloadReadPathFor(filesRoot, "src\\..\\..\\etc") == ""
    # Even one that would land back inside the payload.
    check payloadReadPathFor(filesRoot, "src/../src") == ""

  test "an absolute location is refused":
    check payloadReadPathFor(filesRoot, "/etc") == ""
    check payloadReadPathFor(filesRoot, "/traces/trace-7/files/src") == ""
    check payloadReadPathFor(filesRoot, "\\etc") == ""
    check payloadReadPathFor(filesRoot, "C:\\Windows") == ""
    check payloadReadPathFor(filesRoot, "C:/Windows") == ""
    check payloadReadPathFor(filesRoot, "C:Windows") == ""
    check payloadReadPathFor(filesRoot, "\\\\server\\share") == ""

  test "a location with a NUL byte is refused":
    check payloadReadPathFor(filesRoot, "src\0/x") == ""

suite "file-tree ancestors of the active file":
  ## `isTreeAncestorOf`, which reveal-active-file uses to match a tree node
  ## (absolute, or relative for a payload root such as `src`) against the
  ## absolute path the debugger reports.

  test "a relative tree folder matches an absolute target on segment boundaries":
    # A payload root is relative (`src`); the debugger's path is absolute.
    check isTreeAncestorOf("src", "/home/u/proj/src/main.nr")
    check isTreeAncestorOf("src/sub", "/home/u/proj/src/sub/deep.nr")
    check isTreeAncestorOf("src/", "/home/u/proj/src/main.nr")
    check isTreeAncestorOf("./src", "/home/u/proj/src/main.nr")
    # Absolute folders keep the strict-prefix rule.
    check isTreeAncestorOf("/home/u/proj/src", "/home/u/proj/src/main.nr")
    check not isTreeAncestorOf("/home/u/other/src", "/home/u/proj/src/main.nr")

  test "a relative tree folder does not match a partial segment or itself":
    check not isTreeAncestorOf("src", "/x/mysrc/a.nr")
    check not isTreeAncestorOf("src", "/x/srcs/a.nr")
    check not isTreeAncestorOf("src/sub", "/x/src/subway/a.nr")
    check not isTreeAncestorOf("lib", "/home/u/proj/src/main.nr")
    # A file is not the ancestor of itself.
    check not isTreeAncestorOf("src/main.nr", "/home/u/proj/src/main.nr")
    # Empty paths are never ancestors.
    check not isTreeAncestorOf("", "/home/u/proj/src/main.nr")
    check not isTreeAncestorOf("src", "")

  test "Windows separators and drive letters are matched as segments":
    check isTreeAncestorOf("src", "C:\\Users\\u\\proj\\src\\main.nr")
    check isTreeAncestorOf("src\\sub", "C:\\Users\\u\\proj\\src\\sub\\deep.nr")
    check not isTreeAncestorOf("src", "C:\\Users\\u\\mysrc\\main.nr")
    check isTreeAncestorOf("C:\\Users\\u\\proj", "C:/Users/u/proj/src/main.nr")

  test "a relative target keeps the prefix rule":
    check isTreeAncestorOf("src", "src/main.nr")
    check not isTreeAncestorOf("src", "lib/src/main.nr")

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

  test "expanded set + diff default to empty":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)

      check vm.expandedPaths.val.len == 0
      check vm.diffEntries.val.len == 0

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
    # Every folder below a root's own entries arrives as a
    # "Loading..." stub (one level per load); only the ``onFolderExpanded`` bridge asks the
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
    # The tree is listed one level per load, so ``/proj/src/db`` is not
    # in the tree at first.  When the index
    # process answers ``load-path-content`` the bridge re-publishes the
    # tree, and the newly revealed ancestor must expand in turn.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)
      var expandedOrder: seq[string] = @[]
      vm.onFolderExpanded = proc(path: string) =
        expandedOrder.add(path)

      # ``/proj/src`` still shows the stub child.
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

  test "a relative payload root reveals an absolute active file one answer at a time":
    # What a Noir recording really shows (measured in the GUI on the
    # noir_example and noir_space_ship traces): the tree's root is the
    # payload folder `src`, whose nodes carry RELATIVE paths (`src`,
    # `src/main.nr`), while the debugger reports the ABSOLUTE path it was
    # recorded at (`/…/test-programs/noir_space_ship/src/main.nr`).  When a
    # payload was walked whole every folder arrived expanded and hid the
    # mismatch; with one level per load the reveal must match the relative
    # folders itself, or a file below a stub is never shown.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)
      var listed = false

      proc publish() =
        let sub =
          if listed:
            makeEntry("sub", path = "src/sub", isFolder = true, children = @[
              makeEntry("deep.nr", path = "src/sub/deep.nr"),
              makeEntry("notes.md", path = "src/sub/notes.md")])
          else:
            makeEntry("sub", path = "src/sub", isFolder = true,
                      children = @[makeEntry("Loading...", path = "")])
        vm.setRoot(makeSourceFoldersRoot(@[
          makeEntry("src", path = "src", isFolder = true, children = @[
            sub, makeEntry("main.nr", path = "src/main.nr")]),
        ]))

      var requested: seq[string] = @[]
      var pending: seq[string] = @[]
      vm.onFolderExpanded = proc(path: string) =
        requested.add path
        pending.add path

      publish()
      store.updateDebuggerPosition(rrTicks = 1'u64,
                                   file = "/home/u/proj/src/sub/deep.nr",
                                   line = 3)
      var answers = 0
      while pending.len > 0 and answers < 10:
        let path = pending[0]
        pending.delete(0)
        inc answers
        if path == "src/sub" and not listed:
          listed = true
          publish()

      check requested == @["src", "src/sub"]
      check vm.isExpanded("src")
      check vm.isExpanded("src/sub")
      check not vm.isExpanded("src/sub/deep.nr")

      dispose()

  test "a tree listed one level per load reveals the file one answer at a time":
    # Every folder below a root's own entries arrives as a "Loading..."
    # stub, for a trace payload as for the live disk
    # (`Viewport-Driven-Loading.md` § V5; codetracer-pm issue 2026-10-21-
    # filesystem-pane-renders-the-whole-enclosing-checkout-expanded-and-
    # freezes-the-window).  A file three folders below the root therefore
    # needs three round-trips, each started by the previous answer.  The
    # index process is played by hand: a request ``onFolderExpanded`` makes
    # is answered afterwards, as the IPC answer is, by publishing the tree
    # with that folder listed — what ``ui_js.onUpdatePathContent`` →
    # ``syncLegacyFilesystemIntoVM`` does.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)
      let chain = @["/work/src", "/work/src/game", "/work/src/game/ship"]
      var listed = 0

      proc folderAt(depth: int): FilesystemEntryNode =
        ## ``chain[depth]`` as the tree holds it once ``listed`` folders of
        ## the chain have been answered.  A listed folder also holds a file,
        ## so no single-child chain lets ``collectSmartExpansionPaths``
        ## expand anything on its own.
        let folder = chain[depth]
        let children =
          if depth >= listed:
            @[makeEntry("Loading...", path = "")]
          elif depth == chain.len - 1:
            @[makeEntry("main.nr", path = folder & "/main.nr"),
              makeEntry("notes.md", path = folder & "/notes.md")]
          else:
            @[folderAt(depth + 1),
              makeEntry("notes.md", path = folder & "/notes.md")]
        makeEntry(folder.split('/')[^1], path = folder, isFolder = true,
                  children = children)

      proc publish() =
        vm.setRoot(makeSourceFoldersRoot(@[
          makeEntry("work", path = "/work", isFolder = true, children = @[
            folderAt(0), makeEntry("Nargo.toml", path = "/work/Nargo.toml")]),
        ]))

      var requested: seq[string] = @[]
      var pending: seq[string] = @[]
      vm.onFolderExpanded = proc(path: string) =
        requested.add path
        pending.add path

      publish()
      store.updateDebuggerPosition(rrTicks = 1'u64,
                                   file = "/work/src/game/ship/main.nr",
                                   line = 3)
      var answers = 0
      while pending.len > 0 and answers < 10:
        let path = pending[0]
        pending.delete(0)
        inc answers
        if listed < chain.len and path == chain[listed]:
          inc listed
          publish()

      check listed == chain.len
      check requested == @["/work"] & chain
      for folder in chain:
        check vm.isExpanded(folder)
      check not vm.isExpanded("/work/src/game/ship/main.nr")

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
# A root load that fails or comes back empty (#785)
# ---------------------------------------------------------------------------

proc findOverlay(node: MockNode; cls: string): MockNode =
  ## First element under ``node`` whose class list contains ``cls``.
  if node.isNil:
    return nil
  if node.kind == mnkElement and node.attributes.hasKey("class"):
    for part in node.attributes["class"].split(' '):
      if part == cls:
        return node
  for child in node.children:
    let found = findOverlay(child, cls)
    if not found.isNil:
      return found
  nil

proc isShown(node: MockNode): bool =
  not node.isNil and "hidden" notin node.attributes["class"].split(' ')

proc emptySourceFoldersRoot(): FilesystemEntryNode =
  ## What ``legacyFileToVm`` makes of a ``filesystem-loaded`` whose
  ## ``loadFilesystem`` found nothing under any root: the synthetic
  ## "source folders" container with no children (and so, by the
  ## bridge's "has children" rule, not even a folder).
  FilesystemEntryNode(
    id: "0",
    text: "source folders",
    path: "",
    icon: "",
    isFolder: false,
    isExpanded: false,
    diffClass: fdcNone,
    children: @[],
  )

suite "FilesystemVM a root load that fails or comes back empty (#785)":
  ## GitHub #785: a Noir trace left the FILES pane on "Loading..." for good.
  ## ``createFilesystemVM`` starts at ``lsLoading`` and nothing ever set
  ## ``lsError``, so a root load that failed had no state to end in.  A
  ## load must leave the pane showing a tree, an empty state or an error
  ## (codetracer-pm ``spec/GUI/Core-Panes/Filesystem-Pane.md`` §"Loading").

  test "a failed root load leaves the loading state and says why":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)
      check vm.loadingState.val == lsLoading

      vm.failLoad("cannot read /proj: EACCES")

      check vm.loadingState.val == lsError
      check vm.loadError.val == "cannot read /proj: EACCES"
      check vm.isEmpty.val

      dispose()

  test "the panel replaces Loading... with the failure reason":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)
      let panel = renderFilesystemPanel[MockRenderer, MockNode](MockRenderer(), vm)
      check isShown(findOverlay(panel, "filesystem-loading-overlay"))

      vm.failLoad("cannot read /proj: EACCES")

      check not isShown(findOverlay(panel, "filesystem-loading-overlay"))
      check not isShown(findOverlay(panel, "filesystem-empty-overlay"))
      let errorOverlay = findOverlay(panel, "filesystem-error-overlay")
      check isShown(errorOverlay)
      check "cannot read /proj: EACCES" in errorOverlay.textContent
      check findOverlay(panel, "filesystem").attributes["aria-busy"] == "false"

      dispose()

  test "a later successful load clears the failure":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)
      let panel = renderFilesystemPanel[MockRenderer, MockNode](MockRenderer(), vm)
      vm.failLoad("cannot read /proj: EACCES")

      vm.setRoot(makeSourceFoldersRoot(@[makeEntry("main.nr", path = "src/main.nr")]))

      check vm.loadingState.val == lsIdle
      check vm.loadError.val == ""
      check not isShown(findOverlay(panel, "filesystem-error-overlay"))
      check not isShown(findOverlay(panel, "filesystem-loading-overlay"))

      dispose()

  test "a session reset after a failure waits for the next load again":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)
      vm.failLoad("cannot read /proj: EACCES")

      vm.clearRoot()

      check vm.loadingState.val == lsLoading
      check vm.loadError.val == ""

      dispose()

  test "an empty root load ends on the empty state, not on a bare container row":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)
      let panel = renderFilesystemPanel[MockRenderer, MockNode](MockRenderer(), vm)

      vm.setRoot(emptySourceFoldersRoot())

      check vm.loadingState.val == lsIdle
      check vm.isEmpty.val
      check not isShown(findOverlay(panel, "filesystem-loading-overlay"))
      check isShown(findOverlay(panel, "filesystem-empty-overlay"))
      check findOverlay(panel, "filesystem-tree").children.len == 0

      dispose()

# ---------------------------------------------------------------------------
# The roots of an imported trace's file tree (#785)
# ---------------------------------------------------------------------------

proc payloadWith(roots: openArray[string]): proc(root: string): bool =
  ## A trace payload in which exactly ``roots`` hold files.
  let present = @roots
  result = proc(root: string): bool = root in present

suite "the roots of an imported trace's file tree (#785)":
  ## The reporter's shape, measured with ``ct record`` on
  ## ``test-programs/noir_example`` at codetracer ``cdeb13b12``: nargo
  ## records RELATIVE paths (``src/main.nr``, ``std/lib.nr``), so the
  ## recording's ``source_folders`` column is the git root the program
  ## lives in; the payload holds ``files/src/main.nr`` and an empty
  ## ``files/std`` (the std sources are not copied), and no ``paths.json``
  ## sidecar is written.  The tree was rooted at the live git root and the
  ## index process walked the whole repository.

  const gitRoot = "/home/dev/repo"
  const noirWorkdir = "/home/dev/repo/test-programs/noir_example"

  test "a Noir trace without paths.json is rooted in its payload, not the recorded git root":
    let roots = importedTraceTreeRoots(
      ImportedTraceTreeInputs(
        recordedSourceFolders: @[gitRoot],
        workdir: noirWorkdir,
        tracePathsRead: false,
        payloadTopLevel: @["src", "std"],
        liveFallback: @[noirWorkdir]),
      payloadWith(["src"]))
    check roots == @["src"]

  test "a paths.json root that is empty in the payload does not send the tree to the live disk":
    let roots = importedTraceTreeRoots(
      ImportedTraceTreeInputs(
        recordedSourceFolders: @[gitRoot],
        workdir: noirWorkdir,
        tracePathsRead: true,
        tracePaths: @["src/main.nr", "std/lib.nr"],
        payloadTopLevel: @["src", "std"],
        liveFallback: @[noirWorkdir]),
      payloadWith(["src"]))
    check roots == @["src"]

  test "a trace with no payload still falls back to its recorded folders":
    # Unchanged: with nothing in the payload, the live folders are all
    # there is, and the loader reads them with the live-filesystem limits.
    let roots = importedTraceTreeRoots(
      ImportedTraceTreeInputs(
        recordedSourceFolders: @[gitRoot],
        workdir: noirWorkdir,
        tracePathsRead: false,
        liveFallback: @[noirWorkdir]),
      payloadWith([]))
    check roots == @[gitRoot]

  test "a workdir mirrored in the payload is the root":
    # Unchanged: the root-stripped absolute layout (`files/home/dev/repo/...`).
    let roots = importedTraceTreeRoots(
      ImportedTraceTreeInputs(
        recordedSourceFolders: @[gitRoot],
        workdir: noirWorkdir,
        payloadTopLevel: @["home"]),
      payloadWith([noirWorkdir]))
    check roots == @[noirWorkdir]

  test "paths.json roots that are all in the payload are the roots":
    # Unchanged: the shape every recorder that writes paths.json produces.
    let roots = importedTraceTreeRoots(
      ImportedTraceTreeInputs(
        recordedSourceFolders: @[gitRoot],
        workdir: noirWorkdir,
        tracePathsRead: true,
        tracePaths: @["src/main.nr", "lib/util.nr"],
        payloadTopLevel: @["src", "lib"]),
      payloadWith(["src", "lib"]))
    check roots == @["src", "lib"]
