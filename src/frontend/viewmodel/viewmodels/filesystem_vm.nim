## viewmodels/filesystem_vm.nim
##
## FilesystemVM — ViewModel for the Filesystem panel.
##
## The Filesystem panel renders the project's source tree.  The legacy
## ``FilesystemComponent`` (see ``frontend/ui/filesystem.nim``) used a
## Karax ``method render`` plus jstree to draw the tree, and a parallel
## ``diff-files-list`` div when ``data.startOptions.diff`` was
## populated.  Section §1.71 (mission goal #3) replaces the Karax
## render with an IsoNim view; the rich jstree affordances (animated
## open/close, contextmenu plugin, search plugin) remain a follow-up.
##
## Reactive surface:
## - ``rootEntry``           — top-level ``FilesystemEntryNode`` (the
##                             whole tree).  An empty / nil-shaped
##                             ``FilesystemEntryNode`` (text == "" and
##                             children == @[]) means "no filesystem
##                             loaded yet" so the view renders the
##                             empty-state placeholder.
## - ``expandedPaths``       — set of paths whose subtree should be
##                             rendered expanded.  Mirrors jstree's
##                             internal "open" set.  Toggled by the
##                             per-entry twisty click.
## - ``diffEntries``         — synthetic flat list rendered below the
##                             tree when the recording carries a diff
##                             (the legacy ``diff-files-list``).  Empty
##                             seq disables the section.
##
## Derived:
## - ``isEmpty``             — convenience for the empty-state
##                             placeholder (true when ``rootEntry``
##                             carries no children AND no diff entries).
## - ``hasDiff``             — true when ``diffEntries`` is non-empty.
## - ``totalEntryCount``     — total entry count across the tree (used
##                             by tests).
##
## Actions:
## - ``setRoot``             — bulk-replace the root entry (mirrors the
##                             legacy ``filesystem-loaded`` event /
##                             ``EditorService.filesystem`` assignment).
## - ``clearRoot``           — wipe the tree (used during a session
##                             switch / fresh debugging run).
## - ``toggleExpanded``      — toggle a path's expansion state.  No-op
##                             when the path is not present in the
##                             tree.
## - ``expandPath`` /
##   ``collapsePath``        — explicit setters; idempotent.
## - ``isExpanded``          — predicate the view uses to decide
##                             whether to render a folder's children.
## - ``setDiffEntries``      — bulk-replace the diff list (mirrors the
##                             legacy ``data.startOptions.diff.files``
##                             read inside the Karax method).
##
## ``string`` / ``bool`` / ``seq`` are used everywhere so the same
## value works on both native (``test-vm-native``) and JS
## (``test-vm-js``) backends without ``cstring`` / ``langstring``
## conversion noise.

import std/[sets, sequtils]

import isonim/core/[signals, computation, owner]
# Selective import: ``isonim/core/batch`` re-exports a ``HashSet`` that
# would otherwise collide with ``std/sets``' one in this module.
from isonim/core/batch import untrack
import isonim/viewmodel

import ../store/[replay_data_store, types]
import ../../../common/trace_source_paths

type
  FilesystemVM* = ref object of ViewModel
    ## Reactive state for the Filesystem panel.
    store*: ReplayDataStore

    # -- Mutable state --
    rootEntry*: Signal[FilesystemEntryNode]
    loadingState*: Signal[LoadingState]
    expandedPaths*: Signal[HashSet[string]]
    diffEntries*: Signal[seq[FilesystemDiffEntry]]
    onOpenFile*: proc(path: string)
      ## Called by file-row click handlers. The legacy component wires this to
      ## ``data.openTab(path, ViewSource)`` so CTFS-imported traces resolve
      ## through the normal editor source-loading path.
    onFolderExpanded*: proc(path: string)
      ## Called when a folder is expanded. Used by the legacy bridge to
      ## load subdirectory content partially from the index process.

    # -- Derived state --
    isEmpty*: Memo[bool]
    hasDiff*: Memo[bool]
    totalEntryCount*: Memo[int]

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc countNodes(entry: FilesystemEntryNode): int =
  ## Recursive count of ``entry`` plus every descendant, treating an
  ## "empty" placeholder root (text == "" AND children empty) as zero.
  ## Mirrors the heuristic the IsoNim view uses to detect "no
  ## filesystem loaded yet" — see the ``setRoot`` doc-comment.
  if entry.text.len == 0 and entry.children.len == 0:
    return 0
  result = 1
  for child in entry.children:
    result += countNodes(child)

proc emptyEntry*(): FilesystemEntryNode =
  ## Convenience builder for the empty-state placeholder root.  Used
  ## by ``createFilesystemVM`` to seed ``rootEntry`` and by the legacy
  ## bridge to clear it on a session reset.
  FilesystemEntryNode(
    id: "",
    text: "",
    path: "",
    icon: "",
    isFolder: false,
    isExpanded: false,
    diffClass: fdcNone,
    children: @[],
  )

proc collectSmartExpansionPaths(node: FilesystemEntryNode; paths: var HashSet[string]) =
  ## Recursively collect folder paths where node has exactly one child and that
  ## child is also a folder.
  if node.isFolder:
    if node.children.len == 1 and node.children[0].isFolder:
      paths.incl(node.path)
    for child in node.children:
      collectSmartExpansionPaths(child, paths)

proc collectActiveFileAncestors*(node: FilesystemEntryNode;
                                 target: string;
                                 acc: var seq[string]) =
  ## Collect, **root-first**, the paths of every tree node in ``node``'s
  ## subtree that is an ancestor directory of ``target``.
  ##
  ## The walk is over the REAL tree rather than over a textual split of
  ## ``target`` because the tree's shape is not derivable from the path
  ## alone:
  ## - the top-level node is the synthetic "source folders" container,
  ##   whose ``path`` is empty; it must be descended through but is not
  ##   itself expandable,
  ## - a self-contained trace's tree is rooted at the recorded source
  ##   folder, not at the filesystem root,
  ## - folders that are still lazy "Loading..." stubs carry no children
  ##   yet, and the walk must simply stop there (the caller re-runs once
  ##   the stub is filled).
  ##
  ## Root-first order matters: expanding an ancestor is what triggers
  ## the lazy load of its children, so parents must be expanded before
  ## the deeper nodes they reveal.
  if target.len == 0:
    return

  let isRealAncestor = node.path.len > 0 and isAncestorPathOf(node.path, target)
  # A node with an empty path is the synthetic container root — descend
  # into it unconditionally, since its children carry the real paths.
  let isSyntheticContainer = node.path.len == 0
  if not isRealAncestor and not isSyntheticContainer:
    return

  if isRealAncestor:
    acc.add(node.path)

  for child in node.children:
    collectActiveFileAncestors(child, target, acc)

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

proc setRoot*(vm: FilesystemVM; root: FilesystemEntryNode) =
  ## Replace the root entry with ``root``.  Mirrors the legacy
  ## ``filesystem-loaded`` event handler in ``ui_js`` which assigns
  ## ``data.services.editor.filesystem``.  The view re-renders the
  ## tree as a side effect.
  vm.rootEntry.val = root
  vm.loadingState.val = lsIdle

  # Perform smart auto-expansion for single-child folders on load
  var paths = vm.expandedPaths.val
  collectSmartExpansionPaths(root, paths)
  vm.expandedPaths.val = paths

proc clearRoot*(vm: FilesystemVM) =
  ## Drop the entire tree — used during session resets.  After this
  ## call ``isEmpty`` is true so the empty-state placeholder shows.
  vm.rootEntry.val = emptyEntry()
  vm.loadingState.val = lsLoading

proc toggleExpanded*(vm: FilesystemVM; path: string) =
  ## Toggle ``path``'s expanded state.  Folders not yet in the
  ## expanded set become expanded; folders already expanded collapse.
  ## File paths are silently allowed (a future click handler may key
  ## on them too).
  var current = vm.expandedPaths.val
  if path in current:
    current.excl(path)
  else:
    current.incl(path)
    if not vm.onFolderExpanded.isNil:
      vm.onFolderExpanded(path)
  vm.expandedPaths.val = current

proc expandPath*(vm: FilesystemVM; path: string) =
  ## Mark ``path`` as expanded.  Idempotent.
  var current = vm.expandedPaths.val
  if path in current:
    return
  current.incl(path)
  if not vm.onFolderExpanded.isNil:
    vm.onFolderExpanded(path)
  vm.expandedPaths.val = current

proc collapsePath*(vm: FilesystemVM; path: string) =
  ## Mark ``path`` as collapsed.  Idempotent.
  var current = vm.expandedPaths.val
  if path notin current:
    return
  current.excl(path)
  vm.expandedPaths.val = current

proc setExpandedPaths*(vm: FilesystemVM; paths: HashSet[string]) =
  ## Bulk-replace the expansion set. Used by the legacy bridge to preserve
  ## jstree's ``state.opened`` flags when mirroring a loaded filesystem.
  # Merge with existing paths so smart-expanded paths are preserved
  var current = vm.expandedPaths.val
  for p in paths:
    current.incl(p)
  vm.expandedPaths.val = current

proc isExpanded*(vm: FilesystemVM; path: string): bool =
  ## Predicate the view uses to decide whether to render a folder's
  ## children.  Pure read-only.
  path in vm.expandedPaths.val

proc setDiffEntries*(vm: FilesystemVM;
                     entries: openArray[FilesystemDiffEntry]) =
  ## Replace the synthetic diff-files list (legacy
  ## ``data.startOptions.diff.files`` read).  Pass an empty seq to
  ## hide the section.
  vm.diffEntries.val = @entries

proc expandToFile*(vm: FilesystemVM; filePath: string) =
  ## Reveal ``filePath`` by expanding every folder between the tree root
  ## and it.
  ##
  ## Deliberately routed through ``expandPath`` per ancestor instead of a
  ## single bulk ``expandedPaths`` write: ``expandPath`` fires the
  ## ``onFolderExpanded`` bridge, which is what asks the index process
  ## for a lazily-loaded folder's children.  A bulk write would mark the
  ## folders expanded while leaving their subtrees as "Loading..." stubs,
  ## so the file would still not be visible.
  ##
  ## Only the ancestors that exist in the tree *right now* are expanded.
  ## Deeper ancestors that are still behind a stub become reachable when
  ## the requested content arrives and ``setRoot`` re-runs the effect in
  ## ``createFilesystemVM``.
  if filePath.len == 0:
    return
  var ancestors: seq[string] = @[]
  collectActiveFileAncestors(vm.rootEntry.val, filePath, ancestors)
  for path in ancestors:
    vm.expandPath(path)

proc openFile*(vm: FilesystemVM; path: string) =
  ## Open a file entry through the installed editor bridge.
  if path.len == 0 or vm.onOpenFile.isNil:
    return
  vm.onOpenFile(path)

# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

proc createFilesystemVM*(store: ReplayDataStore): FilesystemVM =
  ## Create a FilesystemVM inside a reactive root owned by
  ## ``withViewModel``.  The reactive root is disposed via
  ## ``vm.dispose()``.  Sets every signal to its empty/inert default
  ## so the view renders the empty-state placeholder on first paint.
  withViewModel proc(dispose: proc()): FilesystemVM =
    # The recursive ``FilesystemEntryNode`` and the diff value type carry
    # explicit ``{.noSideEffect.}`` ``==`` overrides (see
    # ``store/types.nim``).  Without those, the signal write path would not
    # compile under Nim's side-effect inference for compound types.
    let rootEntry = createSignal(emptyEntry())
    let loadingState = createSignal(lsLoading)
    let expandedPaths = createSignal(initHashSet[string]())
    let diffEntries = createSignal(newSeq[FilesystemDiffEntry]())

    let isEmpty = createMemo[bool] proc(): bool =
      let r = rootEntry.val
      let rootEmpty = r.text.len == 0 and r.children.len == 0
      rootEmpty and diffEntries.val.len == 0

    let hasDiff = createMemo[bool] proc(): bool =
      diffEntries.val.len > 0

    let totalEntryCount = createMemo[int] proc(): int =
      countNodes(rootEntry.val)

    let vm = FilesystemVM(
      store: store,
      rootEntry: rootEntry,
      loadingState: loadingState,
      expandedPaths: expandedPaths,
      diffEntries: diffEntries,
      isEmpty: isEmpty,
      hasDiff: hasDiff,
      totalEntryCount: totalEntryCount,
      disposeProc: dispose,
    )

    # Reveal the file the debugger is stopped in.
    #
    # This has to be reactive rather than a one-shot at ``setRoot``,
    # because the two inputs arrive in either order and both can arrive
    # more than once:
    # - the index process sends ``filesystem-loaded`` BEFORE
    #   ``trace-loaded``, so on a fresh trace the tree exists before
    #   there is any active file;
    # - the active file only appears after the first DAP stop, and then
    #   changes on every step into another file;
    # - the tree itself is re-published each time a lazily-loaded
    #   subtree is filled in, which is how ancestors deeper than the
    #   initial depth limit become expandable at all.
    #
    # ``expandedPaths`` is deliberately NOT an input (and the expansion
    # write is ``untrack``ed so it cannot become one): a manual collapse
    # must survive for as long as the user stays on the same file in the
    # same tree, and a self-triggering effect would immediately undo it.
    #
    # Deciding whether to re-expand needs to know WHICH input woke the
    # effect.  Signals dedupe on ``==`` before notifying, so the effect
    # only ever runs because the debugger state or the tree genuinely
    # changed — and the debugger state is cheap to compare, whereas
    # comparing two trees is a full recursive walk.  So compare the
    # debugger state, and infer "the tree changed" from its absence.
    # That keeps the per-step cost at one small object comparison no
    # matter how large the project is.
    var lastActiveFile = ""
    var lastDebugger: DebuggerState
    createEffect proc() =
      let debuggerState = store.debugger.val
      # Read the tree so it is tracked as a dependency; a lazily filled
      # subtree must re-run this effect.
      discard rootEntry.val
      let treeChanged = debuggerState == lastDebugger
      lastDebugger = debuggerState

      let activeFile = debuggerState.location.file
      if activeFile.len == 0:
        # No debugger position yet, or a synthetic frame with no source.
        # Reset so the next real file counts as a change.
        lastActiveFile = ""
        return
      if activeFile == lastActiveFile and not treeChanged:
        # Same file, same tree — the user only stepped within the file.
        # Do not fight a manual collapse.
        return
      lastActiveFile = activeFile
      untrack proc() =
        vm.expandToFile(activeFile)

    vm
