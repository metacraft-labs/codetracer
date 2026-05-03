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
## 2. ``layout.nim`` registers the GL container, then detects
##    ``Content.Filesystem`` is in ``isIsoNimComponent`` and calls
##    ``tryMountIsoNimFilesystemPanel`` instead of invoking Karax.
## 3. The mount helper appends the IsoNim panel inside the
##    ``filesystemComponent-{id}`` container and the reactive effects
##    keep the DOM in sync with the VM.
## 4. ``configureMiddleware`` (in ``ui_js.nim``) installs the shared-
##    store version of the VM via ``initFilesystemVMWithStore`` so the
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
  ../[ types, communication ],
  tables

import std/json
from ../viewmodel/backend/backend_service import BackendService, BackendFuture
import ../viewmodel/store/replay_data_store
from ../viewmodel/store/types as vmtypes import
  FilesystemEntryNode, FilesystemDiffEntry, FilesystemDiffClass,
  fdcNone, fdcAdded, fdcChanged, fdcDeleted
from ../viewmodel/viewmodels/filesystem_vm import
  FilesystemVM, createFilesystemVM, FilesystemDeepReviewFile,
  setRoot, clearRoot, toggleExpanded, expandPath, collapsePath,
  isExpanded, setDiffEntries, setDeepReview, emptyEntry
when defined(js):
  from isonim/web/dom_api import nil
  from ../viewmodel/views/isonim_filesystem_view import
    mountIsoNimFilesystemPanel

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
  data.openTab(data.trace.outputFolder & "files".cstring & currentPath, ViewSource)

# ---------------------------------------------------------------------------
# Module-level VM/store/component slots so the IsoNim mount and any
# legacy bridge handlers can find each other across calls.  Mirrors
# the pattern used by trace_log / scratchpad / request_panel / step_list.
# ---------------------------------------------------------------------------

var filesystemVMInstance*: FilesystemVM
var filesystemVMStore: ReplayDataStore
var filesystemComponentRef: FilesystemComponent
# Track which FilesystemComponent ids have already mounted their IsoNim
# view.  The GL container is keyed by ``filesystemComponent-{id}`` so
# each panel instance gets its own mount.
var isoNimFilesystemMountedIds {.used.}: JsAssoc[int, bool] =
  JsAssoc[int, bool]{}

proc tryMountIsoNimFilesystemPanel*()

# ---------------------------------------------------------------------------
# Component extension (ctInExtension boiler-plate).
#
# Preserved from the legacy module so the extension entry-point still
# resolves to a valid ``FilesystemComponent``; the in-extension render
# path installs an empty shell since the IsoNim view is the production
# renderer.  Same pattern as
# request_panel §1.51 / scratchpad §1.70.
# ---------------------------------------------------------------------------

when defined(ctInExtension):
  var filesystemComponentForExtension* {.exportc.}: FilesystemComponent =
    makeFilesystemComponent(data, 0)

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
  if filesystemVMInstance.isNil or self.isNil:
    return
  if not self.service.isNil and not self.service.filesystem.isNil:
    filesystemVMInstance.setRoot(legacyFileToVm(self.service.filesystem))
  else:
    filesystemVMInstance.clearRoot()
  filesystemVMInstance.setDiffEntries(legacyDiffEntries())

# ---------------------------------------------------------------------------
# VM bootstrap
# ---------------------------------------------------------------------------

proc initFilesystemVMWithStore*(store: ReplayDataStore) =
  ## Initialise (or replace) the parallel ``FilesystemVM`` using an
  ## externally-provided ``ReplayDataStore`` (typically the shared
  ## store from ``SessionViewModel``).  Called from
  ## ``ui_js.configureMiddleware``.  If a stub-backed instance already
  ## exists (created by ``initFilesystemVM`` before the real backend
  ## was available) it is replaced so the panel uses the real backend.
  if filesystemVMInstance != nil:
    clog "FilesystemVM: replacing existing instance with shared-store version"
    isoNimFilesystemMountedIds = JsAssoc[int, bool]{}
  filesystemVMStore = store
  filesystemVMInstance = createFilesystemVM(store)
  clog "FilesystemVM: parallel ViewModel instance created (shared store)"
  tryMountIsoNimFilesystemPanel()

proc initFilesystemVM*() =
  ## Lazy fallback used when no shared store has been provided yet.
  ## Same shape as ``initScratchpadVM`` / ``initTraceLogVM`` — a stub
  ## backend so the panel can still render before
  ## ``configureMiddleware`` runs.
  if filesystemVMInstance != nil:
    return

  let stubSend = proc(command: string, args: JsonNode): BackendFuture[JsonNode] =
    when defined(js):
      result = newPromise proc(resolve: proc(resp: JsonNode)) =
        resolve(%*{})
    else:
      var fut = newFuture[JsonNode]("stub-backend")
      fut.complete(%*{})
      result = fut

  let stubBackend = BackendService(
    sendProc: stubSend,
    onEventProc: proc(handler: proc(event: JsonNode)) = discard,
    disconnectProc: proc() = discard,
  )

  filesystemVMStore = createReplayDataStore(stubBackend)
  filesystemVMInstance = createFilesystemVM(filesystemVMStore)
  clog "FilesystemVM: parallel ViewModel instance created (stub backend)"
  tryMountIsoNimFilesystemPanel()

# ---------------------------------------------------------------------------
# Mount helper — Web only
# ---------------------------------------------------------------------------

when defined(js):
  proc tryMountIsoNimFilesystemPanel*() =
    ## Mount the IsoNim Filesystem panel view into the GoldenLayout-
    ## managed container.  The container's id is
    ## ``filesystemComponent-{id}`` — each open Filesystem panel
    ## instance has its own mount.
    ##
    ## Safe to call multiple times — mounts only once per component
    ## id.  Retries via ``setTimeout`` until the DOM container appears
    ## (capped at 200 attempts, ~2 s) since GoldenLayout creates the
    ## host slightly after the layout state changes (mirrors
    ## ``tryMountIsoNimScratchpadPanel`` / ``tryMountIsoNimTraceLogPanel``).
    if filesystemVMInstance.isNil:
      return
    if filesystemComponentRef.isNil:
      return
    let componentId = filesystemComponentRef.id
    if isoNimFilesystemMountedIds.hasKey(componentId):
      return

    let key = cstring("filesystemComponent-" & $componentId)
    var retryCount = 0
    proc doMount() =
      if isoNimFilesystemMountedIds.hasKey(componentId):
        return
      retryCount += 1
      let container = dom_api.getElementById(dom_api.document, key)
      if dom_api.isNodeNil(dom_api.Node(container)):
        if retryCount > 200:
          cerror "tryMountIsoNimFilesystemPanel: not ready after 200 retries, giving up"
          return
        discard setTimeout(proc() = doMount(), 10)
        return

      # Replace any prior content (Karax may have planted a stub
      # element before the IsoNim mount fires).
      let containerNode = dom_api.Node(container)
      while not dom_api.isNodeNil(containerNode.firstChild):
        discard dom_api.removeChild(containerNode, containerNode.firstChild)

      isoNimFilesystemMountedIds[componentId] = true
      try:
        mountIsoNimFilesystemPanel(container, filesystemVMInstance)
      except:
        cerror "tryMountIsoNimFilesystemPanel: mount EXCEPTION: " &
          getCurrentExceptionMsg()

      # Re-sync any state the legacy component already carries so the
      # freshly-mounted view reflects the latest tree.
      if not filesystemComponentRef.isNil:
        syncLegacyFilesystemIntoVM(filesystemComponentRef)

    doMount()
else:
  proc tryMountIsoNimFilesystemPanel*() =
    ## Native compilation has no DOM — keep the proc available so
    ## callers (``initFilesystemVM*``) compile on every backend.
    discard

# ---------------------------------------------------------------------------
# Component registration — IsoNim primary renderer; no Karax method
# render.  Generic callers are expected to use direct IsoNim mount paths.
# ---------------------------------------------------------------------------

method register*(self: FilesystemComponent, api: MediatorWithSubscribers) =
  ## Register the FilesystemComponent with the mediator.  Bring up the
  ## IsoNim FilesystemVM lazily so the mount procedure can find it; the
  ## shared-store version is installed by ``configureMiddleware`` if
  ## the ViewModel layer is enabled.
  self.api = api
  initFilesystemVM()
  if filesystemComponentRef.isNil:
    filesystemComponentRef = self
    tryMountIsoNimFilesystemPanel()

proc registerFilesystemComponent*(component: FilesystemComponent,
                                   api: MediatorWithSubscribers) {.exportc.} =
  component.register(api)
