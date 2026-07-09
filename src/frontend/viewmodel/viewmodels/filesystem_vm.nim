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
## - ``deepReviewActive``    — true while the deep-review surface is
##                             active.  Mirrors the legacy
##                             ``data.deepReviewActive`` flag — when
##                             set, the IsoNim view renders the
##                             compact one-line-per-file list instead
##                             of the standard tree.
## - ``deepReviewFiles``     — flat list of files surfaced by the
##                             deep-review surface (mirrors
##                             ``data.deepReviewData.files``).  The
##                             view renders one ``deepreview-file-item-
##                             compact`` row per entry with status,
##                             basename, line counts, and coverage.
##
## Derived:
## - ``isEmpty``             — convenience for the empty-state
##                             placeholder (true when ``rootEntry``
##                             carries no children AND no diff entries
##                             AND no deep-review entries).
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
## - ``setDeepReview``       — toggle the deep-review surface on /
##                             off + push the file list (mirrors the
##                             legacy ``deepReviewActive`` /
##                             ``deepReviewData`` pair).
##
## ``string`` / ``bool`` / ``seq`` are used everywhere so the same
## value works on both native (``test-vm-native``) and JS
## (``test-vm-js``) backends without ``cstring`` / ``langstring``
## conversion noise.

import std/[sets, sequtils]

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ../store/[replay_data_store, types]

type
  FilesystemDeepReviewFile* = object
    ## Compact row the deep-review surface renders.  Mirrors the
    ## fields the legacy ``deepReviewData.files`` walk consumed
    ## (status badge, basename, line counts, coverage).  Carrying the
    ## already-derived ``baseName`` keeps the view free of path-parsing
    ## logic so the same shape works on both native and JS backends.
    ##
    ## ``path``        — full source path the row links to.  Click
    ##                   opens it via the bridge.
    ## ``baseName``    — display name (legacy view used
    ##                   ``rfind('/')`` to derive it).
    ## ``status``      — single-letter diff status (``"A"`` / ``"M"`` /
    ##                   ``"D"`` / ``""``).
    ## ``linesAdded`` /
    ## ``linesRemoved`` — diff-line counts.  Both zero hides the badge.
    ## ``coverageExecuted`` /
    ## ``coverageTotal`` — coverage summary.  ``coverageTotal == 0``
    ##                    hides the summary span.
    path*: string
    baseName*: string
    status*: string
    linesAdded*: int
    linesRemoved*: int
    coverageExecuted*: int
    coverageTotal*: int

  FilesystemVM* = ref object of ViewModel
    ## Reactive state for the Filesystem panel.
    store*: ReplayDataStore

    # -- Mutable state --
    rootEntry*: Signal[FilesystemEntryNode]
    loadingState*: Signal[LoadingState]
    expandedPaths*: Signal[HashSet[string]]
    diffEntries*: Signal[seq[FilesystemDiffEntry]]
    deepReviewActive*: Signal[bool]
    deepReviewFiles*: Signal[seq[FilesystemDeepReviewFile]]
    onOpenFile*: proc(path: string)
      ## Called by file-row click handlers. The legacy component wires this to
      ## ``data.openTab(path, ViewSource)`` so CTFS-imported traces resolve
      ## through the normal editor source-loading path.

    # -- Derived state --
    isEmpty*: Memo[bool]
    hasDiff*: Memo[bool]
    totalEntryCount*: Memo[int]

proc `==`*(a, b: FilesystemDeepReviewFile): bool {.noSideEffect.} =
  ## Explicit equality so ``Signal[seq[FilesystemDeepReviewFile]]``
  ## compiles under Nim's side-effect inference.  Mirrors the
  ## ``FilesystemEntryNode`` / ``FilesystemDiffEntry`` overrides in
  ## ``store/types.nim`` (same root cause: the default structural
  ## ``==`` is inferred as side-effecting because the value type
  ## carries ``string`` fields whose ``==`` triggers the same
  ## inference walk).
  a.path == b.path and a.baseName == b.baseName and
    a.status == b.status and a.linesAdded == b.linesAdded and
    a.linesRemoved == b.linesRemoved and
    a.coverageExecuted == b.coverageExecuted and
    a.coverageTotal == b.coverageTotal

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
  vm.expandedPaths.val = current

proc expandPath*(vm: FilesystemVM; path: string) =
  ## Mark ``path`` as expanded.  Idempotent.
  var current = vm.expandedPaths.val
  if path in current:
    return
  current.incl(path)
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

proc setDeepReview*(vm: FilesystemVM; active: bool;
                    files: openArray[FilesystemDeepReviewFile] = @[]) =
  ## Toggle the deep-review surface.  When ``active`` is false the
  ## file list is wiped regardless of ``files`` so a stale list can't
  ## leak through.
  vm.deepReviewActive.val = active
  if active:
    vm.deepReviewFiles.val = @files
  else:
    vm.deepReviewFiles.val = @[]

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
    # The recursive ``FilesystemEntryNode`` plus the diff / deep-review
    # value types carry explicit ``{.noSideEffect.}`` ``==`` overrides
    # (see ``store/types.nim`` and the ``FilesystemDeepReviewFile``
    # override above).  Without those, the signal write path would not
    # compile under Nim's side-effect inference for compound types.
    let rootEntry = createSignal(emptyEntry())
    let loadingState = createSignal(lsLoading)
    let expandedPaths = createSignal(initHashSet[string]())
    let diffEntries = createSignal(newSeq[FilesystemDiffEntry]())
    let deepReviewActive = createSignal(false)
    let deepReviewFiles = createSignal(newSeq[FilesystemDeepReviewFile]())

    let isEmpty = createMemo[bool] proc(): bool =
      let r = rootEntry.val
      let rootEmpty = r.text.len == 0 and r.children.len == 0
      rootEmpty and diffEntries.val.len == 0 and
        deepReviewFiles.val.len == 0

    let hasDiff = createMemo[bool] proc(): bool =
      diffEntries.val.len > 0

    let totalEntryCount = createMemo[int] proc(): int =
      countNodes(rootEntry.val)

    FilesystemVM(
      store: store,
      rootEntry: rootEntry,
      loadingState: loadingState,
      expandedPaths: expandedPaths,
      diffEntries: diffEntries,
      deepReviewActive: deepReviewActive,
      deepReviewFiles: deepReviewFiles,
      isEmpty: isEmpty,
      hasDiff: hasDiff,
      totalEntryCount: totalEntryCount,
      disposeProc: dispose,
    )
