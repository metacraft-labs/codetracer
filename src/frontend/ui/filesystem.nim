## Filesystem Panel — file-tree explorer.
##
## ---------------------------------------------------------------------------
## ViewModel layer — IsoNim is the primary renderer.
##
## The legacy Karax ``method render`` was dropped in favour of an IsoNim
## view (``viewmodel/views/isonim_filesystem_view.nim``) that mounts
## directly into the GoldenLayout container.  The legacy
## ``FilesystemComponent`` retains its module-level helpers so the
## frontend's existing wiring (``filesystem-loaded`` /
## ``filesystem-category-loaded`` IPC handlers, the diff sidecar, the
## deep-review surface) keeps feeding the panel; every state mutation
## now mirrors into the parallel ``FilesystemVM`` so the IsoNim view is
## the single source of truth for the panel's DOM.
##
## Lifecycle:
## 1. ``utils.nim::makeFilesystemComponent`` constructs the legacy
##    ``FilesystemComponent`` and registers it under
##    ``Content.Filesystem`` (one instance per panel id).
## 2. GoldenLayout's component factory (``layout.nim``) builds the
##    pane's container and the panel host (``ui/panel_host``) mounts the
##    generic view into it; reactive effects keep the DOM in sync with the
##    VM.
## 3. The legacy event handlers feed the session's VM.
## 4. ``configureMiddleware`` (in ``ui_js.nim``) installs the shared-
##    store version of the VM via ``initFilesystemVMFromSession`` so the
##    panel uses the production ``ReplayDataStore``.
##
## NOTE: rich jstree affordances (animated open/close, contextmenu
## plugin, search plugin, drag-and-drop) remain a follow-up.  The
## IsoNim view renders a dependency-free collapsible tree; the legacy
## ``changeIcons`` helper is kept exported because ui_js.nim's
## ``filesystem-category-loaded`` handler uses it to populate the
## devicon class on freshly-loaded subtrees.
## ---------------------------------------------------------------------------

import
  ui_imports,
  # A MOUNT LATCH THAT DIES WITH ITS CONTAINER.
  isonim_panel_mount,
  ../[ types, communication ],
  tables,
  sets,
  isonim/core/signals

import std/json
from ../viewmodel/backend/backend_service import BackendService, BackendFuture
import ../viewmodel/store/replay_data_store
from ../viewmodel/store/types as vmtypes import
  FilesystemEntryNode, FilesystemDiffEntry, FilesystemDiffClass,
  fdcNone, fdcAdded, fdcChanged, fdcDeleted
from ../viewmodel/viewmodels/filesystem_vm import
  FilesystemVM, createFilesystemVM,
  setRoot, clearRoot, toggleExpanded, expandPath, collapsePath,
  setExpandedPaths, isExpanded, setDiffEntries, emptyEntry, failLoad

proc jsHasKey(obj: JsObject; key: cstring): bool {.importjs: "#.hasOwnProperty(#)".}

# ---------------------------------------------------------------------------
# Devicon mapping (preserved from the legacy module).
#
# Used by the ``filesystem-category-loaded`` IPC handler in ui_js.nim
# (``response.content.changeIcons()``) so the VM bridge below can query
# the devicon when translating a CodetracerFile into a
# FilesystemEntryNode.  Kept verbatim from the legacy implementation so
# any historical caller keeps the same icon mapping.
# ---------------------------------------------------------------------------

const ICON_MAP = {
  "py".cstring: "devicon-python-plain".cstring,
  "js": "devicon-javascript-plain",
  "ts": "devicon-typescript-plain",
  "html": "devicon-html5-plain",
  "css": "devicon-css3-plain",
  "java": "devicon-java-plain",
  "c": "devicon-c-plain",
  "cpp": "devicon-cplusplus-plain",
  "rb": "devicon-ruby-plain",
  "php": "devicon-php-plain",
  "go": "devicon-go-plain",
  "rs": "devicon-rust-original",
  "swift": "devicon-swift-plain",
  "kt": "devicon-kotlin-plain",
  "dart": "devicon-dart-plain",
  "pl": "devicon-perl-plain",
  "r": "devicon-r-plain",
  "lua": "devicon-lua-plain",
  "cs": "devicon-csharp-plain",
  "sh": "devicon-bash-plain",
  "json": "devicon-json-plain",
  "md": "devicon-markdown-original",
  "sql": "devicon-mysql-plain",
  "coffee": "devicon-coffeescript-original",
  "xml": "devicon-xml-plain",
  "yaml": "devicon-yaml-plain",
  "yml": "devicon-yaml-plain",
  "dockerfile": "devicon-docker-plain",
  "asm": "devicon-assembly-plain",
  "vim": "devicon-vim-plain",
  "toml": "devicon-rust-original",
  "ini": "devicon-config-original",
  "lock": "devicon-yarn-original",
  "nix": "devicon-nixos-plain",
  "elm": "devicon-elm-plain",
  "jl": "devicon-julia-plain",
  "cr": "devicon-crystal-plain",
  "sol": "devicon-solidity-plain",
  "nim": "devicon-nim-plain",
  "cjs": "devicon-javascript-plain",
  "ejs": "devicon-javascript-plain",
  "nr": "custom-noir-icon",

  # Framework and Build Files
  "babelrc": "devicon-babel-plain",
  "webpack": "devicon-webpack-plain",
  "gruntfile": "devicon-grunt-plain",
  "gulpfile": "devicon-gulp-plain",
  "package.json": "devicon-npm-original-wordmark",
  "composer.json": "devicon-composer-plain",
  "gemfile": "devicon-ruby-plain",
  "makefile": "devicon-makefile-original",
  "cmake": "devicon-cmake-plain",

  # Version Control
  "git": "devicon-git-plain",
  "gitignore": "devicon-git-plain",
  "gitattributes": "devicon-git-plain",
  "gitmodules": "devicon-git-plain",

  # Editors and Config Files
  "editorconfig": "devicon-readthedocs-original",
  "vscode": "devicon-visualstudio-plain",
  "eslintrc": "devicon-eslint-plain",
  "prettierrc": "devicon-prettier-plain",
  "stylelintrc": "devicon-stylelint-plain",
  "node_modules": "devicon-nodejs-plain", # Node Modules directory
  "cfg": "devicon-pandas-plain",
  "config": "devicon-pandas-plain",

  # Data Files
  "csv": "devicon-database-plain",
  "xlsx": "devicon-excel-plain",
  "xls": "devicon-excel-plain",
  "copyright": "devicon-readthedocs-original",
  "license": "devicon-readthedocs-original",

  # Other
  "log": "devicon-log-plain",
  "txt": "devicon-txt-plain",
  "pdf": "devicon-pdf-plain",
  "svg": "devicon-svg-plain",
  "png": "devicon-image-plain",
  "jpg": "devicon-image-plain",
  "jpeg": "devicon-image-plain",
  "gif": "devicon-image-plain",
  "ico": "devicon-image-plain",
  "zip": "devicon-zip-plain",
  "tar": "devicon-archive-plain",
  "gz": "devicon-archive-plain",
  "7z": "devicon-archive-plain",
  "rar": "devicon-archive-plain",
  "rc": "devicon-purescript-original",
  "sample": "devicon-purescript-original",
  "bat": "devicon-windows8-original",
  "nimble": "devicon-nimble-plain",
  "txt": "devicon-readthedocs-original",
}.toTable()

proc toDevicon(str: cstring): cstring =
  ICON_MAP[str]

proc deviconForName*(name: string): string =
  ## Resolve the devicon CSS class for a file basename.  Mirrors the
  ## per-extension lookup the legacy ``changeIcons`` proc did but
  ## returns a plain string so the VM bridge can call it without
  ## ``cstring`` round-tripping.  Returns "" when no mapping exists.
  if name.len == 0:
    return ""
  let dotIdx = name.rfind('.')
  let ext = if dotIdx >= 0: name[dotIdx + 1 .. ^1].toLowerAscii() else: name
  let key = cstring(ext)
  if ICON_MAP.hasKey(key):
    $ICON_MAP[key]
  else:
    ""

proc changeIcons*(file: CodetracerFile) =
  ## Walk the legacy ``CodetracerFile`` tree and populate each node's
  ## ``icon`` cstring with the matching devicon class.  Preserved as
  ## an exported proc because ui_js.nim's ``filesystem-category-loaded``
  ## handler invokes it after loading a freshly-streamed subtree.
  for child in file.children:
    let str = child.text.split(".")[^1].toLowerCase()

    if ICON_MAP.hasKey(str):
      child.icon = toDevicon(str)
    elif not child.icon.isNil and child.icon.split(" ")[0] == "icon".cstring:
      child.icon = "jstree-default jstree-file"

    child.changeIcons()


proc openTab*(currentPath: cstring) =
  ## Dispatch a ``ViewSource`` open on ``currentPath`` through the
  ## legacy ``data.openTab`` plumbing.  Exported because the IsoNim
  ## view's bridge invokes it from row-click handlers.
  data.openTab(currentPath, ViewSource)

# ---------------------------------------------------------------------------
# Module-level VM/store/component slots so the IsoNim mount and any
# legacy bridge handlers can find each other across calls.  Mirrors
# the pattern used by trace_log / scratchpad / request_panel / step_list.
# ---------------------------------------------------------------------------

# The session's ViewModel and the registered component, so the legacy
# event-bus handlers can feed the one and replay the other. The pane's view
# is mounted by the panel host (`ui/panel_host`).
var filesystemVMInstance*: FilesystemVM
var filesystemComponentRef: FilesystemComponent


proc findFileByPath(file: CodetracerFile; path: string): CodetracerFile =
  if file.isNil:
    return nil
  if not file.original.path.isNil and $file.original.path == path:
    return file
  for child in file.children:
    let found = findFileByPath(child, path)
    if not found.isNil:
      return found
  return nil

proc nodeForPathContent*(root: CodetracerFile; parentIndices: seq[int];
                         index: int; path: string): CodetracerFile =
  ## The tree node an ``update-path-content`` answer replaces: the stub at
  ## ``parentIndices`` / ``index`` below ``root``, when that walk stays in
  ## bounds and lands on a node whose path is ``path``; otherwise the node
  ## found by ``path``.  ``nil`` when neither finds it.
  ##
  ## The indices alone are not trusted.  They are positions within the tree
  ## ONE root load built, and ``ui_js.onFilesystemCategoryLoaded`` wraps
  ## that tree in a new "Files" root when a second category arrives, which
  ## shifts every walk by one level.  Writing the answer over whatever node
  ## a stale walk reaches would replace an unrelated folder; the path check
  ## turns that into a lookup.  Now that every folder below a root arrives
  ## as a stub (``index/files.FilesystemLoadDepth``), these answers are
  ## the common case rather than the exception.
  var node = root
  var walked = not root.isNil
  if walked:
    for position in parentIndices:
      if position < 0 or position >= node.children.len:
        walked = false
        break
      node = node.children[position]
  if walked and index >= 0 and index < node.children.len:
    let candidate = node.children[index]
    if not candidate.original.path.isNil and
        $candidate.original.path == path:
      return candidate
  findFileByPath(root, path)

proc loadFolderContentIfNeeded*(path: string) =
  ## Ask the index process for the entries of the folder at ``path`` when
  ## it is still a "Loading..." stub — every folder below a root arrives as
  ## one (``index/files.FilesystemLoadDepth``).  The stub's
  ## ``payloadPath`` goes with the request: it is where a self-contained
  ## trace's payload holds the folder, which the display path alone does
  ## not say for a folder overlaid from the payload's top level.
  if data.isNil or data.services.editor.filesystem.isNil:
    return
  let file = findFileByPath(data.services.editor.filesystem, path)
  if file.isNil:
    return
  if file.children.len > 0 and $file.children[0].text == "Loading...":
    let nodeId = "j1_" & $file.index
    let nodeIndex = file.index
    let nodeParentIndices = file.parentIndices
    # Absent (`undefined`) on a node an older index process sent.
    let payloadPathValue = file.original.payloadPath.toJs
    let payloadPath =
      if payloadPathValue.isNull or payloadPathValue.isUndefined: cstring""
      else: file.original.payloadPath
    data.ipc.send "CODETRACER::load-path-content", js{
      path: cstring(path),
      payloadPath: payloadPath,
      nodeId: cstring(nodeId),
      nodeIndex: nodeIndex,
      nodeParentIndices: nodeParentIndices
    }

proc wireFilesystemOpenBridge() =
  if filesystemVMInstance.isNil:
    return
  filesystemVMInstance.onOpenFile = proc(path: string) =
    openTab(cstring(path))
  filesystemVMInstance.onFolderExpanded = proc(path: string) =
    loadFolderContentIfNeeded(path)

# ---------------------------------------------------------------------------
# Legacy → VM translation helpers
# ---------------------------------------------------------------------------

proc safeStr(s: cstring): string =
  ## Convert a possibly-null cstring to an empty string.  The legacy
  ## record carries cstring everywhere; an unconditional ``$`` would
  ## throw inside ``cstrToNimstr`` for null cstrings.
  if s.isNil:
    ""
  else:
    $s

proc resolveDiffClass(path: string): FilesystemDiffClass =
  ## Compare ``path`` against the diff fixture in
  ## ``data.startOptions.diff`` (when populated) and return the matching
  ## diff class.  Mirrors the legacy ``mapDiff`` logic at the data-only
  ## level so the IsoNim bridge does not need to walk jstree's DOM.
  if data.isNil or data.startOptions.diff.isNil:
    return fdcNone
  for fileDiff in data.startOptions.diff.files:
    if safeStr(fileDiff.currentPath) == path:
      case fileDiff.change
      of FileAdded: return fdcAdded
      of FileDeleted: return fdcDeleted
      of FileChanged: return fdcChanged
      of FileRenamed: return fdcNone
  fdcNone

proc legacyFileToVm*(file: CodetracerFile): FilesystemEntryNode =
  ## Translate a legacy ``CodetracerFile`` (the jstree input) to a
  ## platform-neutral ``FilesystemEntryNode`` value.  Recurses on
  ## children so the same call mirrors the entire subtree in one shot.
  ## ``isFolder`` is derived from "has at least one child" — the
  ## legacy record does not carry an explicit "is folder" bit but
  ## jstree treated any node with children as a folder.
  if file.isNil:
    return emptyEntry()
  let displayText = safeStr(file.text)
  let path = safeStr(file.original.path)
  let icon = safeStr(file.icon)
  result = FilesystemEntryNode(
    id: $file.index,
    text: displayText,
    path: path,
    icon: icon,
    isFolder: file.children.len > 0,
    isExpanded: false,
    diffClass: resolveDiffClass(path),
    children: @[],
  )
  for child in file.children:
    result.children.add(legacyFileToVm(child))

proc legacyFileIsOpened(file: CodetracerFile): bool =
  if file.isNil or file.state.isNil:
    return false
  try:
    if jsHasKey(file.state, cstring"opened"):
      return file.state.opened.to(bool)
  except:
    discard
  false

proc collectLegacyOpenedPaths(file: CodetracerFile;
                              openedPaths: var HashSet[string]) =
  if file.isNil:
    return
  if file.legacyFileIsOpened():
    openedPaths.incl(safeStr(file.original.path))
  for child in file.children:
    collectLegacyOpenedPaths(child, openedPaths)

proc legacyDiffEntries*(): seq[FilesystemDiffEntry] =
  ## Build the synthetic diff-files-list rows from
  ## ``data.startOptions.diff.files``.  Returns an empty seq when no
  ## diff is loaded, hiding the section.
  result = @[]
  if data.isNil or data.startOptions.diff.isNil:
    return
  for i, fd in data.startOptions.diff.files:
    let path = safeStr(fd.currentPath)
    if path.len == 0:
      continue
    # The legacy ``diffItem`` proc used ``i mod 2 == 0`` for
    # ``path-even``; flip the sense so the VM stores "true == odd
    # row" which matches the helper name.
    result.add(FilesystemDiffEntry(
      path: path,
      zebra: (i mod 2 != 0),
    ))

# ---------------------------------------------------------------------------
# IsoNim VM bridge
# ---------------------------------------------------------------------------

proc syncLegacyFilesystemIntoVM*(self: FilesystemComponent) =
  ## Bulk-replay the legacy filesystem into the VM.  Used by the
  ## layout when the panel container becomes visible (or is rebuilt)
  ## so the panel reflects whatever ``EditorService.filesystem`` /
  ## ``data.startOptions.diff`` already accumulated.
  if self.isNil:
    return
  filesystemComponentRef = self
  if filesystemVMInstance.isNil:
    return
  if not self.service.isNil and not self.service.filesystem.isNil:
    var openedPaths = initHashSet[string]()
    collectLegacyOpenedPaths(self.service.filesystem, openedPaths)
    filesystemVMInstance.setRoot(legacyFileToVm(self.service.filesystem))
    var mergedPaths = filesystemVMInstance.expandedPaths.val
    for path in openedPaths:
      mergedPaths.incl(path)
    filesystemVMInstance.setExpandedPaths(mergedPaths)
  elif not self.service.isNil and not self.service.filesystemLoadError.isNil and
      self.service.filesystemLoadError.len > 0:
    # The root load answered with a failure: end the pane on it rather
    # than on "Loading..." (GitHub #785).
    filesystemVMInstance.failLoad($self.service.filesystemLoadError)
  else:
    # No answer yet: the pane waits for ``filesystem-loaded``.
    filesystemVMInstance.clearRoot()
  filesystemVMInstance.setDiffEntries(legacyDiffEntries())

proc refreshIsoNimFilesystemPanel*() =
  ## Re-sync the session's ViewModel after IPC handlers mutate the legacy
  ## EditorService filesystem cache; the mounted view follows it.
  if not filesystemComponentRef.isNil:
    syncLegacyFilesystemIntoVM(filesystemComponentRef)

# ---------------------------------------------------------------------------
# VM bootstrap
# ---------------------------------------------------------------------------

proc initFilesystemVMFromSession*(vm: FilesystemVM) =
  ## Hand the pane the session's `FilesystemVM` — the one
  ## `initializePanelViewModels` built on the session's store, so every
  ## reader of the session sees the same instance (Shared-DOM-Front-Ends D1).
  filesystemVMInstance = vm
  wireFilesystemOpenBridge()
  when defined(js):
    if not data.isNil:
      if data.ui.componentMapping[Content.Filesystem].len == 0:
        discard data.makeFilesystemComponent(0)
      for _, component in data.ui.componentMapping[Content.Filesystem]:
        syncLegacyFilesystemIntoVM(FilesystemComponent(component))
        break

# ---------------------------------------------------------------------------
# Component registration. The pane's view is mounted by the panel host.
# ---------------------------------------------------------------------------

method register*(self: FilesystemComponent, api: MediatorWithSubscribers) =
  ## Register the FilesystemComponent with the mediator. Its handlers feed
  ## the session's `FilesystemVM` once `initFilesystemVMFromSession` has
  ## installed it.
  self.api = api
  filesystemComponentRef = self
