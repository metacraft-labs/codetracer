## views/isonim_filesystem_view.nim
##
## IsoNim DOM-rendering view for the Filesystem panel.
##
## Renders a live, reactive DOM tree driven by ``FilesystemVM``
## signals.  Replaces the legacy Karax ``method render`` in
## ``frontend/ui/filesystem.nim`` (the IsoNim view is the single source
## of truth for the panel's DOM).
##
## The legacy panel relied on jstree for the in-Karax tree rendering
## with the contextmenu / search / wholerow plugins.  This iteration
## intentionally renders a minimal, dependency-free collapsible tree —
## one ``filesystem-entry`` row per node, an explicit twisty for
## folders, and the diff-files-list / deep-review compact rows below
## the tree.  The rich jstree affordances (animated open/close,
## contextmenu, search) remain a follow-up captured in the VM
## doc-comment.
##
## Both renderer overloads (Mock and Web) produce the same outer
## structure mirroring the legacy
## ``componentContainerClass("filesystem-container")`` layout::
##
##   div.component-container.filesystem-container
##     div.filesystem
##       div.filesystem-tree
##         div.filesystem-entry[.folder|.file][.expanded][diff-class]
##                                                      (one per node)
##           span.filesystem-entry-twisty                (folders only)
##           i.filesystem-entry-icon                     (devicon class)
##           span.filesystem-entry-label                 (basename)
##           div.filesystem-entry-children               (recursive)
##       div.filesystem-empty-overlay[.hidden]
##           text "No filesystem loaded yet."
##       div.filesystem-loading-overlay[.hidden]   (while lsLoading)
##           text "Loading..."
##       div.filesystem-error-overlay[.hidden]     (while lsError)
##           text FilesystemLoadFailedText, then the reason
##     div.diff-files-list                          (when hasDiff)
##       div.diff-file-path[.path-even|.path-odd]
##                                       (one per FilesystemDiffEntry)
##
## Reactive surface:
## - One outer ``createRenderEffect`` rebuilds the tree and the diff
##   list, and toggles the empty-state placeholder whenever any source
##   signal (``rootEntry`` / ``expandedPaths`` / ``diffEntries``)
##   changes.  Mirrors the trace_log / scratchpad pattern (DSL builds
##   the static shell, imperative renderer ops inside the effect
##   handle the dynamic content).

import std/[strutils, tables]

import isonim/core/[signals, computation]
import isonim/dsl/[ui, components]

when defined(js):
  # The DSL's calls on a `WebRenderer` resolve where the generic view is
  # instantiated; the overloads must be in scope there.
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../store/types
import ../viewmodels/filesystem_vm

# The generic view expands the DSL where it is instantiated.
export signals, computation, components

const FilesystemContainerClass* = "component-container filesystem-container"
  ## Verbatim string the legacy ``componentContainerClass(
  ## "filesystem-container")`` template produced.  Exposed for headless
  ## tests so they assert against the exact class string (and so the
  ## existing ``static/styles/components/filesystem.styl`` rules keep
  ## targeting the same selector).

const FilesystemEmptyStateText* = "No filesystem loaded yet."
  ## Placeholder copy rendered when no tree has been loaded yet.  The
  ## legacy view relied on jstree's own empty-state copy; we surface a
  ## short string here so the IsoNim view has a non-blank canvas
  ## before the first ``filesystem-loaded`` event arrives.  Kept as a
  ## constant so the view, the headless tests, and any future fixture
  ## builder share one source of truth.  Name-spaced (vs. the
  ## ``EmptyStateText`` in trace_log_view) so importing both modules
  ## from the test suite does not collide.

const FilesystemLoadFailedText* = "The file tree could not be loaded: "
  ## Lead-in of the error overlay shown when a root load failed
  ## (``FilesystemVM.loadError`` follows it).  A load ends on a tree, the
  ## empty state or this — never on a permanent "Loading..." (GitHub #785).

const FilesystemTreeContainerClass* = "filesystem-tree"
  ## CSS class on the tree's outer wrapper.  Kept distinct from the
  ## legacy ``filesystem`` class on the panel root so the IsoNim CSS
  ## can target the dependency-free tree separately from the jstree-
  ## styled selectors.

# ---------------------------------------------------------------------------
# Reactive helpers used inside the render effect
# ---------------------------------------------------------------------------

proc diffClassToCss*(diffClass: FilesystemDiffClass): string =
  ## Map a ``FilesystemDiffClass`` enum to the CSS modifier the legacy
  ## ``reapplyDiffClasses`` proc applied to the jstree row.  Empty
  ## string means "no modifier" so the row's class string concatenates
  ## cleanly even when the diff is absent.
  case diffClass
  of fdcNone: ""
  of fdcAdded: "diff-file-added"
  of fdcChanged: "diff-file-changed"
  of fdcDeleted: "diff-file-deleted"

proc rowClass*(entry: FilesystemEntryNode; expanded: bool): string =
  ## Outer ``.filesystem-entry`` modifier — folders carry the ``folder``
  ## modifier (and ``expanded`` when their children are visible),
  ## files carry the ``file`` modifier.  The diff modifier is appended
  ## last so the legacy ``diff-file-…`` rule order is preserved.
  let kindClass = if entry.isFolder: "folder" else: "file"
  let stateClass = if expanded and entry.isFolder: " expanded" else: ""
  let diffClass = diffClassToCss(entry.diffClass)
  let diffSuffix = if diffClass.len > 0: " " & diffClass else: ""
  "filesystem-entry " & kindClass & stateClass & diffSuffix

proc twistyText*(entry: FilesystemEntryNode; expanded: bool): string =
  ## Return the twisty glyph for a folder row.  Files render an empty
  ## string so the column lines up vertically with folders without
  ## planting a redundant element.  Mirrors the legacy jstree open/
  ## closed-arrow rendering at the data-only level — the actual
  ## glyph is a plain ASCII triangle so the headless tests assert on
  ## a stable string.
  if not entry.isFolder:
    return ""
  if expanded:
    "v"
  else:
    ">"

proc diffEntryClass*(entry: FilesystemDiffEntry): string =
  ## Outer ``.diff-file-path`` modifier mirroring the legacy zebra
  ## class string the Karax ``diffItem`` helper emitted.  ``zebra``
  ## true → ``path-odd`` (the legacy proc used ``i mod 2 == 0`` for
  ## ``path-even``; the bridge already inverts that so the VM's
  ## ``zebra`` flag means "odd row").
  let zebra = if entry.zebra: "path-odd" else: "path-even"
  "diff-file-path " & zebra

proc diffEntryLabel*(entry: FilesystemDiffEntry): string =
  ## Display label rendered inside a ``diff-file-path`` row.  The
  ## legacy ``diffItem`` proc rendered ``path.split("/")[^1]`` (i.e.
  ## the basename); we replicate that without parsing inside the view
  ## so both renderer overloads share one helper.
  let p = entry.path
  let slashIdx = p.rfind('/')
  if slashIdx < 0:
    p
  else:
    p[slashIdx + 1 .. ^1]

proc iconClass*(entry: FilesystemEntryNode): string =
  ## Add the devicon / custom file-icon class directly to the icon slot.
  ## The legacy jstree renderer did this on its theme icon span; keeping the
  ## class in the DOM lets the existing icon font and Noir SVG rules render
  ## instead of exposing the class name as row text.
  if entry.icon.len > 0:
    "filesystem-entry-icon " & entry.icon
  elif entry.isFolder:
    "filesystem-entry-icon filesystem-entry-folder-icon"
  else:
    "filesystem-entry-icon filesystem-entry-file-icon"

proc jstreeNodeId*(entry: FilesystemEntryNode): string =
  ## Legacy jstree ids use the ``j1_1`` shape.  Older IsoNim fixtures stored
  ## ids without the leading ``j``; tolerate both so bridge data stays stable.
  if entry.id.len == 0:
    ""
  elif entry.id[0] == 'j':
    entry.id
  else:
    "j" & entry.id

proc jstreeNodeClass*(entry: FilesystemEntryNode; expanded, isLast: bool): string =
  let stateClass =
    if entry.isFolder:
      if expanded: "jstree-open" else: "jstree-closed"
    else:
      "jstree-leaf"
  let lastClass = if isLast: " jstree-last" else: ""
  let diffClass = diffClassToCss(entry.diffClass)
  let diffSuffix = if diffClass.len > 0: " " & diffClass else: ""
  "jstree-node  " & stateClass & lastClass & diffSuffix

proc jstreeIconClass*(entry: FilesystemEntryNode): string =
  if entry.icon.len > 0:
    "jstree-icon jstree-themeicon " & entry.icon & " jstree-themeicon-custom"
  elif entry.isFolder:
    "jstree-icon jstree-themeicon"
  else:
    "jstree-icon jstree-themeicon jstree-file"

# ---------------------------------------------------------------------------
# Mock renderer — headless test DOM
# ---------------------------------------------------------------------------

when defined(js):
  proc preventDefault(ev: isonim_dom.Event) {.importcpp: "#.preventDefault()".}
  proc stopPropagation(ev: isonim_dom.Event) {.importcpp: "#.stopPropagation()".}

proc entryAction(vm: FilesystemVM; path: string; isFolder: bool): proc() =
  ## A row's activation: a folder toggles, a file opens. A factory, so each
  ## row's closure owns its own path (see `diffOpenHandler`).
  result = proc() =
    if isFolder: vm.toggleExpanded(path) else: vm.openFile(path)

proc folderToggle(vm: FilesystemVM; path: string; isFolder: bool): proc() =
  ## The twisty: a folder toggles; a file's twisty does nothing.
  result = proc() =
    if isFolder: vm.toggleExpanded(path)

proc renderEntry[R, N](r: R; vm: FilesystemVM; entry: FilesystemEntryNode;
                       level: int; isLast: bool): N =
  ## One tree node in the legacy jstree markup (the visual reference is the
  ## browser's final plugin DOM: wholerow, ocl twisty, anchor, theme icon),
  ## and, for an expanded folder, its children. Collapsed subtrees are not
  ## built.
  let expandedFlag = vm.isExpanded(entry.path)
  let nodeId = jstreeNodeId(entry)
  let isFolder = entry.isFolder
  let activate = entryAction(vm, entry.path, isFolder)
  var anchor, children: N
  let row = ui(r):
    li(class = jstreeNodeClass(entry, expandedFlag, isLast), id = nodeId,
       role = "treeitem", `aria-selected` = "false",
       `aria-level` = $level,
       `aria-labelledby` = (if nodeId.len > 0: nodeId & "_anchor" else: ""),
       `aria-expanded` = (if not isFolder: "" elif expandedFlag: "true"
                          else: "false")):
      tdiv(class = "jstree-wholerow", unselectable = "on",
           role = "presentation"):
        text "\xC2\xA0"
      i(class = "jstree-icon jstree-ocl", role = "presentation",
        onclick = folderToggle(vm, entry.path, isFolder)):
        discard
      a(ref = anchor, class = "jstree-anchor",
        id = (if nodeId.len > 0: nodeId & "_anchor" else: ""),
        href = "#", tabindex = "-1"):
        i(class = jstreeIconClass(entry), role = "presentation"):
          discard
        text entry.text
      ul(ref = children, class = "jstree-children", role = "group"):
        discard
  # The anchor's click activates the row. In a browser the click must also
  # not follow the `#` link nor reach the tree beneath, which needs the event.
  when defined(js):
    when N is isonim_dom.Element:
      isonim_dom.addEventListener(isonim_dom.Node(anchor), cstring"click",
        proc(ev: isonim_dom.Event) =
          ev.preventDefault()
          ev.stopPropagation()
          activate())
    else:
      r.addEventListener(anchor, "click", activate)
  else:
    r.addEventListener(anchor, "click", activate)
  if isFolder and expandedFlag:
    for i in 0 ..< entry.children.len:
      r.appendChild(children, renderEntry[R, N](r, vm, entry.children[i],
                                                level + 1,
                                                i == entry.children.high))
  else:
    r.removeChild(row, children)
  row

proc diffOpenHandler(vm: FilesystemVM; path: string): proc() =
  ## The click handler of one diff-list row: open `path`.
  ##
  ## A FACTORY, because the diff rows are built in a `for` loop and Nim
  ## closures capture by reference: a `let` in the loop body is ONE variable
  ## for the whole loop, so an inline `proc() = vm.openFile(p)` made every
  ## row open the LAST changed file (codetracer#860 sweep;
  ## https://nim-lang.org/docs/manual.html#procedures-closures). `path` is
  ## this call's own parameter, so each row's closure owns its value.
  result = proc() = vm.openFile(path)

proc renderFilesystemPanel*[R, N](r: R; vm: FilesystemVM): N =
  ## The Filesystem panel, under any renderer (Shared-DOM-Front-Ends D3),
  ## mounted on the desktop by `ui/panel_host`, in the legacy jstree markup.
  ##
  ## The static shell (outer container + filesystem wrapper +
  ## tree + empty-overlay + diff-files-list) is
  ## built once via the DSL.  A single outer ``createRenderEffect``
  ## rebuilds the dynamic content whenever any source signal changes.
  var treeContainer, emptyContainer, loadingContainer, errorContainer,
      filesystemContainer, diffContainer: N

  let panel = ui(r):
    tdiv(class = FilesystemContainerClass):
      tdiv(ref = filesystemContainer,
           class = "filesystem jstree jstree-1 jstree-default",
           role = "tree", `aria-multiselectable` = "true",
           tabindex = "0", `aria-activedescendant` = "j1_1",
           `aria-busy` = "false"):
        ul(ref = treeContainer,
           class = "jstree-container-ul jstree-children jstree-contextmenu " &
                   "jstree-wholerow-ul jstree-no-dots " &
                   FilesystemTreeContainerClass,
           role = "group"):
          discard
        tdiv(ref = emptyContainer, class = "filesystem-empty-overlay"):
          text FilesystemEmptyStateText
        tdiv(ref = loadingContainer, class = "filesystem-loading-overlay"):
          text "Loading..."
        tdiv(ref = errorContainer, class = "filesystem-error-overlay hidden",
             role = "alert"):
          discard
      tdiv(ref = diffContainer, class = "diff-files-list"):
        discard

  createRenderEffect proc() =
    # -- Tree --
    let isLoading = vm.loadingState.val == lsLoading
    let root = vm.rootEntry.val
    let isFailed = vm.loadingState.val == lsError
    let showEmpty = not isLoading and not isFailed and isEmptyRoot(root) and
      vm.diffEntries.val.len == 0
    r.clearChildren(treeContainer)
    if isEmptyRoot(root):
      discard
    elif root.text.len > 0 and root.text != "/":
      r.appendChild(treeContainer, renderEntry[R, N](r, vm, root, 1, true))
    elif root.children.len > 0:
      for i in 0 ..< root.children.len:
        r.appendChild(treeContainer, renderEntry[R, N](r, vm,
          root.children[i], 1, i == root.children.high))
    elif root.text.len > 0:
      # Single-node tree (rare but supported — e.g. a recording
      # captured via a single file path).  Render the root itself.
      r.appendChild(treeContainer, renderEntry[R, N](r, vm, root, 1, true))

    # -- Empty-state overlay --
    if showEmpty:
      r.setAttribute(emptyContainer, "class", "filesystem-empty-overlay")
    else:
      r.setAttribute(emptyContainer, "class",
                     "filesystem-empty-overlay hidden")

    # -- Loading-state overlay --
    if isLoading:
      r.setAttribute(loadingContainer, "class", "filesystem-loading-overlay")
    else:
      r.setAttribute(loadingContainer, "class",
                     "filesystem-loading-overlay hidden")

    # -- Load-failed overlay --
    r.clearChildren(errorContainer)
    if isFailed:
      r.setAttribute(errorContainer, "class", "filesystem-error-overlay")
      r.appendChild(errorContainer,
                    r.createTextNode(FilesystemLoadFailedText & vm.loadError.val))
    else:
      r.setAttribute(errorContainer, "class",
                     "filesystem-error-overlay hidden")

    let busyVal = if isLoading: "true" else: "false"
    r.setAttribute(filesystemContainer, "aria-busy", busyVal)

    # -- Diff list --
    let diffs = vm.diffEntries.val
    r.clearChildren(diffContainer)
    if diffs.len == 0:
      r.setAttribute(diffContainer, "class", "diff-files-list hidden")
    else:
      r.setAttribute(diffContainer, "class", "diff-files-list")
      for diff in diffs:
        # Copy the row data into local non-lent vars: the DSL's attribute
        # closures cannot capture the iterator's ``lent FilesystemDiffEntry``.
        # The click goes through `diffOpenHandler`, NOT a closure over
        # `pathLocal` (one variable for the whole loop) -- see that proc.
        let rowClsLocal = diffEntryClass(diff)
        let rowLabelLocal = diffEntryLabel(diff)
        let pathLocal = diff.path
        let row = ui(r):
          tdiv(class = rowClsLocal,
               onclick = diffOpenHandler(vm, pathLocal)):
            text rowLabelLocal
        r.appendChild(diffContainer, row)

  panel
