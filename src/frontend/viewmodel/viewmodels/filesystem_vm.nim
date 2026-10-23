## viewmodels/filesystem_vm.nim
##
## FilesystemVM — ViewModel for the Filesystem panel.
##
## The Filesystem panel renders the project's source tree.  The legacy
## ``FilesystemComponent`` (see ``frontend/ui/filesystem.nim``) used a
## Karax ``method render`` plus jstree to draw the tree, and a parallel
## ``diff-files-list`` div when ``data.startOptions.diff`` was
## populated.  Section §1.71 (mission goal #3) replaces the Karax
## render with an IsoNim view.  The row context menu (Create, Rename,
## Delete, Edit) is decided here — see "Context menu" below; jstree's
## animated open/close and search plugin have no counterpart yet.
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
## - ``failLoad``            — end a root load that failed: ``lsError``
##                             plus the reason, so the pane never waits
##                             forever (GitHub #785).
## - ``showNoProjectFolder``  — the session has no project folder (New
##                             File): an empty project, not a load to
##                             wait for.
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
import std/json
import ./action_sink

import isonim/core/[signals, computation, owner]
# Selective import: ``isonim/core/batch`` re-exports a ``HashSet`` that
# would otherwise collide with ``std/sets``' one in this module.
from isonim/core/batch import untrack
import isonim/viewmodel

import ../store/[replay_data_store, types]
import ../../../common/trace_source_paths
import ../../../common/file_entry_names
from ./edit_mode_toolbar import ToolbarMode, isEditing
export ToolbarMode
export file_entry_names

const
  ReadOnlySourcesReason* = "A recording's sources are read-only"
    ## Create, Rename and Delete in a replay session: the tree is the
    ## recording's source set, and changing it would make the sources
    ## disagree with the recording.
  NotOnDiskReason* = "Not a folder on disk"
    ## Create, Rename and Delete on the synthetic "source folders" container
    ## (the only row with an empty ``path``).
  OnlyFilesOpenReason* = "Only a file can be opened in the editor"
    ## Edit on a folder (and on the container).
  NoFileOperationsReason* = "This front end cannot change files"
    ## Create, Rename and Delete where no index process carries them out
    ## (the web IDE).
  OpenedFolderRowReason* =
    "The opened folder cannot be renamed or deleted from the tree"
    ## Rename and Delete on the opened folder's own row.

type
  FileTreeHostFacts* = object
    ## The facts the context menu depends on that the ViewModel cannot see:
    ## the bridge (``ui/filesystem``) supplies them.
    layout*: ToolbarMode
      ## The session's layout (``data.ui.mode``, mirrored).
    openedFolder*: string
      ## The folder the session opened in edit mode, whose contents the
      ## tree shows; ``""`` when the tree is a recording's source set, or
      ## the session has no folder.
    hasIndexProcess*: bool
      ## Whether something answers Create, Rename and Delete. False on a
      ## front end with no index process (the web IDE).
    canTrash*: bool
      ## Whether the index process can move a path to the trash.

type
  FileTreeAction* = enum
    ## The Files pane's context-menu entries, in the order the menu lists
    ## them.
    ftaCreate = "Create"
    ftaRename = "Rename"
    ftaDelete = "Delete"
    ftaEdit = "Edit"

  FileTreeMenuEntry* = object
    ## One entry of a row's context menu, renderer-agnostic. The web view
    ## turns it into a ``ContextMenuItem`` for ``showContextMenu``.
    action*: FileTreeAction
    label*: string
    disabled*: bool
    disabledReason*: string
      ## Why the entry cannot act, shown as its sublabel; ``""`` when it is
      ## enabled.
    run*: proc() {.closure.}
      ## What choosing the entry does; ``nil`` when it is disabled.

  FileTreeNameEditKind* = enum
    fneNone      ## no name field is open
    fneCreate    ## a new file's name, first in ``folder``
    fneRename    ## the new name of the entry at ``path``

  FileTreeNameEdit* = object
    ## The inline name field Create and Rename open in the tree.
    kind*: FileTreeNameEditKind
    folder*: string
      ## The folder the name is in: Create's target folder, or the renamed
      ## entry's parent.
    path*: string
      ## The entry being renamed; ``""`` for Create.
    name*: string
      ## The name the field opened with, or the name last refused.
    error*: string
      ## Why the last name was refused; ``""`` when none was.

type
  FilesystemVM* = ref object of ViewModel
    ## Reactive state for the Filesystem panel.
    actionSink*: ActionSink
      ## Set in a mirror session: user actions go to the primary
      ## (`action_sink`); nil on a primary.
    store*: ReplayDataStore

    # -- Mutable state --
    rootEntry*: Signal[FilesystemEntryNode]
    loadingState*: Signal[LoadingState]
    loadError*: Signal[string]
      ## Why the last root load failed, when ``loadingState`` is ``lsError``;
      ## ``""`` otherwise.  The view shows it in place of "Loading...".
    noProjectFolder*: Signal[bool]
      ## True while the session has NO project folder (Welcome screen → New
      ## File).  The tree is then empty because there is nothing to list, not
      ## because a load is outstanding, and the view's empty state says so
      ## ("No project folder is open.") instead of "No filesystem loaded
      ## yet.", which reads as a load still to come.  Set only by
      ## ``showNoProjectFolder``; every other root transition clears it.
    expandedPaths*: Signal[HashSet[string]]
    diffEntries*: Signal[seq[FilesystemDiffEntry]]
    onOpenFile*: proc(path: string)
      ## Called by file-row click handlers. The legacy component wires this to
      ## ``data.openTab(path, ViewSource)`` so CTFS-imported traces resolve
      ## through the normal editor source-loading path.
    onFolderExpanded*: proc(path: string)
      ## Called when a folder is expanded. Used by the legacy bridge to
      ## load subdirectory content partially from the index process.

    # -- Context menu (Filesystem-Pane.md § "Context menu") --
    hostFacts*: proc(): FileTreeHostFacts
      ## What the session and the front end are, asked each time a menu
      ## opens, so a layout switch needs no notification. ``nil`` reads as
      ## ``FileTreeHostFacts()``: a replay layout, no opened folder, nothing
      ## to carry the operations out, no trash.
    onCreateFile*: proc(folder, name: string)
      ## Ask the index process to create the empty file ``name`` in
      ## ``folder``.
    onRenamePath*: proc(path, newName: string)
      ## Ask the index process to rename the entry at ``path``.
    onDeletePath*: proc(path: string)
      ## Ask the index process to move the entry at ``path`` to the trash.
    lastContextMenu*: seq[FileTreeMenuEntry]
      ## The menu the last right-click opened, for the headless tests (the
      ## web view hands the same entries to ``showContextMenu``). A plain
      ## field, not a signal: nothing reacts to it, and its entries hold
      ## closures, which a mirror session cannot carry
      ## (``sync/synced_signals`` skips such a signal, and
      ## ``test_session_mirroring`` holds that list to the one it has).
    nameEdit*: Signal[FileTreeNameEdit]
      ## The open name field, if any.
    nameEditDraft*: string
      ## What the open field holds as the user types. Deliberately not a
      ## signal: typing must not rebuild the tree. The view writes it on
      ## every input and reads it whenever it rebuilds the field (a lazy
      ## load re-renders the tree while the field is open), so a rebuild
      ## keeps the typed text.

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

proc isEmptyRoot*(root: FilesystemEntryNode): bool =
  ## Does ``root`` hold nothing to show?  True for the empty placeholder
  ## (``emptyEntry``) and for a synthetic container — the "source
  ## folders" group ``loadFilesystem`` builds, whose ``path`` is empty
  ## because it is not a folder on disk — that came back with no
  ## children.  A load that found nothing must end on the empty state,
  ## not on one bare container row (GitHub #785).
  root.children.len == 0 and (root.text.len == 0 or root.path.len == 0)

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
  ##   folder, not at the filesystem root, and when its roots are payload
  ##   folders (a Noir recording's `src`) its nodes carry paths RELATIVE to
  ##   the payload while ``target`` is absolute (`isTreeAncestorOf`),
  ## - folders that are still lazy "Loading..." stubs carry no children
  ##   yet, and the walk must simply stop there (the caller re-runs once
  ##   the stub is filled).  That is every folder below a root's own
  ##   entries until it is expanded: the index process lists one level
  ##   per load (`index/files.FilesystemLoadDepth`), for a trace payload
  ##   as for the live disk, so revealing a file N folders below a root
  ##   takes N round-trips.
  ##
  ## Root-first order matters: expanding an ancestor is what triggers
  ## the lazy load of its children, so parents must be expanded before
  ## the deeper nodes they reveal.
  if target.len == 0:
    return

  # `isTreeAncestorOf`, not `isAncestorPathOf`: an imported trace's nodes
  # carry paths relative to its payload (`src`, `src/sub`) while `target`
  # is the absolute path the debugger reports.
  let isRealAncestor = node.path.len > 0 and isTreeAncestorOf(node.path, target)
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
  vm.loadError.val = ""
  vm.noProjectFolder.val = false

  # Perform smart auto-expansion for single-child folders on load
  var paths = vm.expandedPaths.val
  collectSmartExpansionPaths(root, paths)
  vm.expandedPaths.val = paths

proc clearRoot*(vm: FilesystemVM) =
  ## Drop the entire tree — used during session resets.  After this
  ## call ``isEmpty`` is true so the empty-state placeholder shows.
  vm.rootEntry.val = emptyEntry()
  vm.loadingState.val = lsLoading
  vm.loadError.val = ""
  vm.noProjectFolder.val = false
  # A name field belongs to the tree it was opened in.
  vm.nameEditDraft = ""
  vm.nameEdit.val = FileTreeNameEdit()

proc resetToInitial*(vm: FilesystemVM) =
  ## Put back what a freshly created VM shows: no tree (waiting for a root
  ## load), nothing expanded, no diff section.
  ##
  ## Unlike `clearRoot` this also forgets the expanded folders, which
  ## `setRoot` and `setExpandedPaths` otherwise MERGE into: for a window tab
  ## that has never been shown (`shared_pane_state`), the folders another
  ## project had open would be re-expanded in this one. The store and the
  ## open-file / folder-expanded callbacks are the window's and stay.
  vm.clearRoot()
  vm.expandedPaths.val = initHashSet[string]()
  vm.diffEntries.val = newSeq[FilesystemDiffEntry]()

proc failLoad*(vm: FilesystemVM; reason: string) =
  ## End a root load that failed.  The index process answers every root
  ## load on ``CODETRACER::filesystem-loaded``, with the tree or with an
  ## ``error`` naming the reason it has none; this is the second answer.
  ## Without it the pane had no state to end in but the ``lsLoading`` it
  ## starts in, and showed "Loading..." for good (GitHub #785).
  ##
  ## The tree is dropped: whatever it held belonged to an earlier load.
  ## The next ``setRoot`` clears the failure; a ``clearRoot`` (session
  ## reset) puts the pane back to waiting.
  vm.rootEntry.val = emptyEntry()
  vm.loadError.val = if reason.len > 0: reason
                     else: "The file tree could not be loaded."
  vm.loadingState.val = lsError
  vm.noProjectFolder.val = false

proc showNoProjectFolder*(vm: FilesystemVM) =
  ## The session has no project folder: show an EMPTY PROJECT.
  ##
  ## `Welcome-Screen.md` §"New file, and what it creates": *"The session's
  ## folder is empty, so the Files panel shows an empty project rather than
  ## a tree"*.  That is a settled answer, not a load in flight — there is no
  ## folder to walk and nothing will ever answer a root load — so the state
  ## is ``lsIdle`` with no tree, and ``noProjectFolder`` tells the view to
  ## name the reason (the same "No project folder is open." the Test
  ## Results and Constraints panes show) rather than the generic "No
  ## filesystem loaded yet.", which promises a tree that is not coming.
  ##
  ## The tree is dropped: one FilesystemVM serves every tab of a window
  ## (`shared_pane_state`), so whatever it held was another session's.  The
  ## expanded folders are left alone, as ``setRoot`` leaves them; the
  ## session switch restores or resets them.
  vm.rootEntry.val = emptyEntry()
  vm.loadError.val = ""
  vm.loadingState.val = lsIdle
  vm.noProjectFolder.val = true

proc toggleExpanded*(vm: FilesystemVM; path: string) =
  ## Toggle ``path``'s expanded state.  Folders not yet in the
  ## expanded set become expanded; folders already expanded collapse.
  ## File paths are silently allowed (a future click handler may key
  ## on them too).
  if vm.actionSink.forwards("fileTree", "toggleExpanded",
      %*{"path": path}):
    return
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
  if vm.actionSink.forwards("fileTree", "expandPath", %*{"path": path}):
    return
  var current = vm.expandedPaths.val
  if path in current:
    return
  current.incl(path)
  if not vm.onFolderExpanded.isNil:
    vm.onFolderExpanded(path)
  vm.expandedPaths.val = current

proc collapsePath*(vm: FilesystemVM; path: string) =
  ## Mark ``path`` as collapsed.  Idempotent.
  if vm.actionSink.forwards("fileTree", "collapsePath",
      %*{"path": path}):
    return
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
  if vm.actionSink.forwards("fileTree", "expandToFile",
      %*{"filePath": filePath}):
    return
  if filePath.len == 0:
    return
  var ancestors: seq[string] = @[]
  collectActiveFileAncestors(vm.rootEntry.val, filePath, ancestors)
  for path in ancestors:
    vm.expandPath(path)

proc openFile*(vm: FilesystemVM; path: string) =
  ## Open a file entry through the installed editor bridge.
  if vm.actionSink.forwards("fileTree", "openFile", %*{"path": path}):
    return
  if path.len == 0 or vm.onOpenFile.isNil:
    return
  vm.onOpenFile(path)

# ---------------------------------------------------------------------------
# Context menu
# ---------------------------------------------------------------------------

#
# codetracer-pm `spec/GUI/Core-Panes/Filesystem-Pane.md` § "Context menu".
# Right-clicking a row lists Create, Rename, Delete and Edit — always all
# four, always in that order, so each is in the same place on every row. An
# entry that cannot act is disabled with its reason, never left out. The
# decisions live here so every renderer shares them; the view only binds
# ``contextmenu`` and draws the name field, and the bridge
# (``ui/filesystem``) carries the requests to the index process.

type TreeLocation = object
  found: bool
  entry: FilesystemEntryNode
  hasParent: bool
  parent: FilesystemEntryNode

proc locate(node: FilesystemEntryNode; path: string; loc: var TreeLocation) =
  ## Find the row whose ``path`` is ``path``, and the row it is listed
  ## under. ``path`` must not be empty: the empty path names the synthetic
  ## container and the "Loading..." stubs alike.
  for child in node.children:
    if loc.found:
      return
    if child.path == path:
      loc = TreeLocation(found: true, entry: child, hasParent: true,
                         parent: node)
      return
    locate(child, path, loc)

proc locateEntry(vm: FilesystemVM; path: string): TreeLocation =
  if path.len == 0:
    return
  let root = vm.rootEntry.val
  if root.path == path:
    return TreeLocation(found: true, entry: root)
  locate(root, path, result)

proc parentDirOf(path: string): string =
  ## The folder part of ``path``, for an entry whose parent row is not in
  ## the tree. Both separators count: a Windows tree's paths use ``\``.
  for i in countdown(path.high, 0):
    if path[i] == '/' or path[i] == '\\':
      return (if i == 0: path[0 .. 0] else: path[0 ..< i])
  ""

proc diskFolderOf(loc: TreeLocation): string =
  ## The folder on disk the entry at ``loc`` is listed in, or ``""`` when
  ## its row in the tree is the synthetic container (or nothing): then the
  ## tree has no folder to put a new file in or to reload.
  if loc.hasParent:
    loc.parent.path
  else:
    ""

proc factsOf(vm: FilesystemVM): FileTreeHostFacts =
  if vm.hostFacts.isNil: FileTreeHostFacts() else: vm.hostFacts()

proc treeIsOpenedFolder*(facts: FileTreeHostFacts): bool =
  ## Edit mode in the spec's sense: an editing layout
  ## (``edit_mode_toolbar.isEditing`` — Edit, Quick Edit, Interactive Edit)
  ## whose tree is the opened folder. A replay session switched to the Edit
  ## layout keeps its recording's tree and is still a replay.
  facts.layout.isEditing and facts.openedFolder.len > 0

proc menuEntry(action: FileTreeAction; reason: string;
               run: proc()): FileTreeMenuEntry =
  FileTreeMenuEntry(action: action, label: $action,
                    disabled: reason.len > 0, disabledReason: reason,
                    run: (if reason.len > 0: nil else: run))

proc startCreate*(vm: FilesystemVM; folder: string)
proc startRename*(vm: FilesystemVM; path: string)
  ## Forward declarations: the menu's entries run them.

proc fileTreeMenu*(vm: FilesystemVM; path: string): seq[FileTreeMenuEntry] =
  ## The context menu of the row at ``path`` (``""``: the synthetic
  ## container). Always the four entries in the spec's order.
  ##
  ## Where several reasons apply, the first of these is shown: "Not a folder
  ## on disk" (the spec makes it win over every other); a replay's
  ## read-only sources; no index process to carry the operation out; the
  ## opened folder's own row (Rename, Delete); no trash (Delete).
  let facts = vm.factsOf()
  let loc = vm.locateEntry(path)
  let onDisk = loc.found and loc.entry.path.len > 0
  let isFolder = onDisk and loc.entry.isFolder
  let createFolder =
    if isFolder: loc.entry.path
    elif onDisk: diskFolderOf(loc)
    else: ""
  let writeReason =
    if not onDisk: NotOnDiskReason
    elif not treeIsOpenedFolder(facts): ReadOnlySourcesReason
    elif not facts.hasIndexProcess: NoFileOperationsReason
    else: ""
  let isOpenedFolderRow =
    # `ct edit <dir>` names the folder with a trailing separator.
    onDisk and isSamePath(loc.entry.path, facts.openedFolder)
  let renameReason =
    if writeReason.len > 0: writeReason
    elif isOpenedFolderRow: OpenedFolderRowReason
    else: ""
  let createReason =
    if writeReason.len > 0: writeReason
    elif createFolder.len == 0: NotOnDiskReason
    else: ""
  let deleteReason =
    if renameReason.len > 0: renameReason
    elif not facts.canTrash: NoTrashReason
    else: ""
  let editReason = if onDisk and not isFolder: "" else: OnlyFilesOpenReason
  let target = path
  result = @[
    menuEntry(ftaCreate, createReason,
      proc() = vm.startCreate(createFolder)),
    menuEntry(ftaRename, renameReason,
      proc() = vm.startRename(target)),
    menuEntry(ftaDelete, deleteReason,
      proc() =
        if not vm.onDeletePath.isNil:
          vm.onDeletePath(target)),
    menuEntry(ftaEdit, editReason,
      proc() = vm.openFile(target)),
  ]

proc openFileTreeMenu*(vm: FilesystemVM; path: string): seq[FileTreeMenuEntry] =
  ## A right-click on the row at ``path``: build its menu and keep it
  ## in ``lastContextMenu``.
  result = vm.fileTreeMenu(path)
  vm.lastContextMenu = result

proc cancelNameEdit*(vm: FilesystemVM) =
  ## Close the name field without acting: Escape, or leaving the field.
  vm.nameEditDraft = ""
  vm.nameEdit.val = FileTreeNameEdit()

proc startCreate*(vm: FilesystemVM; folder: string) =
  ## Open an empty name field as the first child of ``folder`` and expand
  ## the folder (which loads it, when it is still a "Loading..." stub).
  if folder.len == 0:
    return
  vm.nameEditDraft = ""
  vm.nameEdit.val = FileTreeNameEdit(kind: fneCreate, folder: folder)
  vm.expandPath(folder)

proc startRename*(vm: FilesystemVM; path: string) =
  ## Replace the label of the row at ``path`` with a field holding its
  ## current name.
  let loc = vm.locateEntry(path)
  if not loc.found:
    return
  let folder = diskFolderOf(loc)
  vm.nameEditDraft = loc.entry.text
  vm.nameEdit.val = FileTreeNameEdit(
    kind: fneRename,
    folder: (if folder.len > 0: folder else: parentDirOf(path)),
    path: path,
    name: loc.entry.text)

proc nameTaken(vm: FilesystemVM; edit: FileTreeNameEdit; name: string): bool =
  ## Does an entry named ``name`` already exist in the field's folder, as
  ## far as the tree knows? The index process checks the disk again when it
  ## acts, which also catches an entry that appeared after the field opened.
  ## The "Loading..." placeholders (empty ``path``) are not entries.
  let loc = vm.locateEntry(edit.folder)
  if not loc.found:
    return false
  for child in loc.entry.children:
    if child.path.len > 0 and child.text == name and
        not (edit.kind == fneRename and child.path == edit.path):
      return true
  false

proc commitNameEdit*(vm: FilesystemVM; name: string): bool =
  ## Enter in the name field. A refused name keeps the field open with its
  ## reason and returns false; an accepted one closes the field, sends the
  ## request and returns true.
  ##
  ## Renaming an entry to the name it already has is not an operation: the
  ## field closes and nothing is sent.
  let edit = vm.nameEdit.val
  if edit.kind == fneNone:
    return false
  var reason = fileEntryNameRefusal(name)
  if reason.len == 0 and vm.nameTaken(edit, name):
    reason = alreadyExistsRefusal(name)
  if reason.len > 0:
    vm.nameEditDraft = name
    var refused = edit
    refused.name = name
    refused.error = reason
    vm.nameEdit.val = refused
    return false
  vm.cancelNameEdit()
  case edit.kind
  of fneCreate:
    if not vm.onCreateFile.isNil:
      vm.onCreateFile(edit.folder, name)
  of fneRename:
    if name != edit.name and not vm.onRenamePath.isNil:
      vm.onRenamePath(edit.path, name)
  of fneNone:
    discard
  true

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
    let noProjectFolder = createSignal(false)
    let loadError = createSignal("")
    let expandedPaths = createSignal(initHashSet[string]())
    let diffEntries = createSignal(newSeq[FilesystemDiffEntry]())
    let nameEdit = createSignal(FileTreeNameEdit())

    let isEmpty = createMemo[bool] proc(): bool =
      isEmptyRoot(rootEntry.val) and diffEntries.val.len == 0

    let hasDiff = createMemo[bool] proc(): bool =
      diffEntries.val.len > 0

    let totalEntryCount = createMemo[int] proc(): int =
      countNodes(rootEntry.val)

    let vm = FilesystemVM(
      store: store,
      rootEntry: rootEntry,
      loadingState: loadingState,
      loadError: loadError,
      noProjectFolder: noProjectFolder,
      expandedPaths: expandedPaths,
      diffEntries: diffEntries,
      nameEdit: nameEdit,
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
    #   subtree is filled in.  Every folder below a root arrives as a
    #   "Loading..." stub (one level per load, `index/files.
    #   FilesystemLoadDepth`), payload and live trees alike, so this is
    #   how any ancestor below a root's own entries becomes expandable
    #   at all: one level per answer.
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
