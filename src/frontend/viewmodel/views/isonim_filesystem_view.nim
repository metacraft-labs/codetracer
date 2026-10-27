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
## the tree.  jstree's animated open/close and its search plugin have no
## counterpart yet.
##
## A right-click on a row opens the shared CodeTracer context menu
## (`context_menu_bridge.showContextMenu`, `#context-menu-container`) with
## the entries `FilesystemVM.fileTreeMenu` decides (codetracer-pm
## `spec/GUI/Core-Panes/Filesystem-Pane.md` § "Context menu"), and the
## browser's own menu is suppressed. The diff-list rows have no menu. While
## Create or Rename is open, the tree also draws the inline name field
## (`FilesystemVM.nameEdit`): as the first child of Create's folder, or in
## place of the renamed row's label.
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
##           text "No filesystem loaded yet.", or "No project folder is
##           open." for a session with no project folder (New File)
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
  import kdom except Location
  from ./context_menu_bridge import showContextMenu
  from ../../context_menu_item import ContextMenuItem

# The headless tests render through `MockRenderer`; its event type is what
# the Mock arm of the row's right-click and the name field's keys receive.
import isonim/testing/mock_dom

import ../store/types
import ../viewmodels/filesystem_vm
import ../viewmodels/no_project_folder

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

const FilesystemNoProjectFolderText* = NoProjectFolderText
  ## The empty state of a session with NO project folder (Welcome screen →
  ## New File; ``FilesystemVM.showNoProjectFolder``).  `Welcome-Screen.md`
  ## §"New file, and what it creates" calls it "an empty project": no tree,
  ## no loading indicator, and this sentence — the one the Test Results and
  ## Constraints panes show for the same session — where the generic empty
  ## state would say "No filesystem loaded yet." and so promise a tree that
  ## is not coming.

proc emptyStateText*(vm: FilesystemVM): string =
  ## The sentence the empty-state overlay shows for ``vm``'s state.
  if vm.noProjectFolder.val: FilesystemNoProjectFolderText
  else: FilesystemEmptyStateText

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
  proc fsPreventDefault(ev: isonim_dom.Event) {.importcpp: "#.preventDefault()".}
  proc fsStopPropagation(ev: isonim_dom.Event) {.importcpp: "#.stopPropagation()".}
  proc eventClientX(ev: isonim_dom.Event): int {.importcpp: "(#.clientX || 0)".}
  proc eventClientY(ev: isonim_dom.Event): int {.importcpp: "(#.clientY || 0)".}
  proc eventKey(ev: isonim_dom.Event): cstring {.importcpp: "(#.key || '')".}
  proc fieldValue(e: isonim_dom.Element): cstring {.importcpp: "(#.value || '')".}
  proc setFieldValue(e: isonim_dom.Element; v: cstring) {.importcpp: "#.value = #".}
  proc focusFieldSoon(e: isonim_dom.Element) {.importjs: """
    (function (e) {
      setTimeout(function () {
        if (e.isConnected) {
          e.focus();
          var n = e.value.length;
          try { e.setSelectionRange(n, n); } catch (_) {}
        }
      }, 0);
    })(#)""".}
    ## Focus the name field once the row holding it is in the document (the
    ## render effect builds a row before attaching it), caret at the end.
  proc cancelIfStillShown(e: isonim_dom.Element; cancel: proc()) {.importjs: """
    (function (e, cancel) {
      setTimeout(function () { if (e.isConnected) { cancel(); } }, 0);
    })(#, #)""".}
    ## Leaving the field cancels it — but a field the tree REBUILT (a lazy
    ## load or a refused name re-renders it) is replaced, not left: Chromium
    ## may report a blur for the removed element, and by the next task it is
    ## no longer connected, so only a field the user really left cancels.

  proc toContextMenuItem(entry: FileTreeMenuEntry): ContextMenuItem =
    ## The shared menu's item for one ViewModel entry: a disabled entry
    ## keeps its row and shows its reason as the sublabel.
    let run = entry.run
    ContextMenuItem(
      name: cstring(entry.label),
      hint: cstring"",
      disabled: entry.disabled,
      disabledReason: cstring(entry.disabledReason),
      handler: proc(ev: kdom.Event) =
        if not run.isNil:
          run())

  proc showFileTreeMenu(vm: FilesystemVM; path: string; ev: isonim_dom.Event) =
    var items: seq[ContextMenuItem] = @[]
    for entry in vm.openFileTreeMenu(path):
      items.add toContextMenuItem(entry)
    showContextMenu(items, ev.eventClientX(), ev.eventClientY())

# This module's own names for the two event calls. Generic code that called
# `preventDefault` would leave it an open symbol (kdom and mock_dom both
# declare one), and the instantiating module also sees `isonim_state_view`'s,
# so the call would be ambiguous there.
template isDomElement(N: typedesc): bool =
  ## Whether `N` is the browser DOM's element: the web arm of a binding. The
  ## Mock arm must stay reachable on the JS backend too, where the headless
  ## suites also run (`vm-js`).
  when defined(js): N is isonim_dom.Element else: false

proc fsPreventDefault(ev: MockEvent) = ev.preventDefault()
proc fsStopPropagation(ev: MockEvent) = ev.stopPropagation()

proc bindRowContextMenu[R, N](r: R; vm: FilesystemVM; row: N; path: string) =
  ## A right-click anywhere on the row (its whole-row band, icon or label)
  ## opens that row's menu. The browser's own menu is suppressed, and the
  ## event stops at the row so an enclosing folder's row does not open its
  ## menu on top. A factory, so each row's closure owns its own `path`.
  mixin addEventListener
  when isDomElement(N):
    isonim_dom.addEventListener(isonim_dom.Node(row), cstring"contextmenu",
      proc(ev: isonim_dom.Event) =
        ev.fsPreventDefault()
        ev.fsStopPropagation()
        showFileTreeMenu(vm, path, ev))
  elif N is MockNode:
    r.addEventListener(row, "contextmenu", proc(ev: MockEvent) =
      ev.fsPreventDefault()
      ev.fsStopPropagation()
      discard vm.openFileTreeMenu(path))

proc renderNameField[R, N](r: R; vm: FilesystemVM;
                           edit: FileTreeNameEdit): N =
  ## The inline name field of Create and Rename: an input holding
  ## `vm.nameEditDraft` and, after a refused name, the reason beside it.
  ## Enter commits, Escape or leaving the field cancels. Its keys stop at
  ## the field, so the tree and the window's shortcuts do not see the
  ## letters typed into a name.
  mixin createElement, setAttribute, appendChild, createTextNode,
        addEventListener, setInputValue, inputValue
  let field = r.createElement("span")
  r.setAttribute(field, "class", "filesystem-name-field")
  let input = r.createElement("input")
  r.setAttribute(input, "class", "filesystem-name-input")
  r.setAttribute(input, "type", "text")
  r.setAttribute(input, "spellcheck", "false")
  r.setAttribute(input, "aria-label",
    if edit.kind == fneCreate: "New file name" else: "New name")
  r.appendChild(field, input)
  if edit.error.len > 0:
    let reason = r.createElement("span")
    r.setAttribute(reason, "class", "filesystem-name-error")
    r.setAttribute(reason, "role", "alert")
    r.appendChild(reason, r.createTextNode(edit.error))
    r.appendChild(field, reason)
  when isDomElement(N):
    setFieldValue(input, cstring(vm.nameEditDraft))
    let inputNode = isonim_dom.Node(input)
    isonim_dom.addEventListener(inputNode, cstring"keydown",
      proc(ev: isonim_dom.Event) =
        ev.fsStopPropagation()
        let key = $ev.eventKey()
        if key == "Enter":
          ev.fsPreventDefault()
          discard vm.commitNameEdit($fieldValue(input))
        elif key == "Escape":
          ev.fsPreventDefault()
          vm.cancelNameEdit())
    isonim_dom.addEventListener(inputNode, cstring"input",
      proc(ev: isonim_dom.Event) =
        vm.nameEditDraft = $fieldValue(input))
    isonim_dom.addEventListener(inputNode, cstring"blur",
      proc(ev: isonim_dom.Event) =
        cancelIfStillShown(input, proc() =
          if vm.nameEdit.val.kind != fneNone:
            vm.cancelNameEdit()))
    for eventName in [cstring"click", cstring"dblclick", cstring"mousedown",
                      cstring"contextmenu"]:
      # The field sits inside the row: a click in it is not a click on the
      # row, and a right-click in it edits text rather than opening the
      # row's menu.
      isonim_dom.addEventListener(inputNode, eventName,
        proc(ev: isonim_dom.Event) = ev.fsStopPropagation())
    focusFieldSoon(input)
  elif N is MockNode:
    r.setInputValue(input, vm.nameEditDraft)
    r.addEventListener(input, "keydown", proc(ev: MockEvent) =
      ev.fsStopPropagation()
      if ev.key == "Enter":
        discard vm.commitNameEdit(r.inputValue(input))
      elif ev.key == "Escape":
        vm.cancelNameEdit())
    r.addEventListener(input, "input", proc() =
      vm.nameEditDraft = r.inputValue(input))
    # The mock has no focus moves of its own: a "blur" fired by a test is
    # the user leaving the field.
    r.addEventListener(input, "blur", proc() =
      if vm.nameEdit.val.kind != fneNone:
        vm.cancelNameEdit())
  field

proc renderCreateFieldNode[R, N](r: R; vm: FilesystemVM;
                                 edit: FileTreeNameEdit; level: int): N =
  ## Create's field as a tree node: the first child of the target folder.
  mixin createElement, setAttribute, appendChild
  let node = r.createElement("li")
  r.setAttribute(node, "class",
                 "jstree-node jstree-leaf filesystem-name-field-node")
  r.setAttribute(node, "role", "treeitem")
  r.setAttribute(node, "aria-level", $level)
  r.appendChild(node, renderNameField[R, N](r, vm, edit))
  node

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
  # Bound where instantiated: on JS this module also sees WebRenderer's.
  mixin appendChild, removeChild, addEventListener, insertBefore
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
          ev.fsPreventDefault()
          ev.fsStopPropagation()
          activate())
    else:
      r.addEventListener(anchor, "click", activate)
  else:
    r.addEventListener(anchor, "click", activate)
  bindRowContextMenu[R, N](r, vm, row, entry.path)
  # The name field, when Create or Rename is open on this row. Reading
  # `nameEdit` here makes the panel's render effect follow it.
  let edit = vm.nameEdit.val
  if edit.kind == fneRename and entry.path.len > 0 and edit.path == entry.path:
    # Rename: the field replaces the row's label.
    r.insertBefore(row, renderNameField[R, N](r, vm, edit), anchor)
    r.removeChild(row, anchor)
  if isFolder and expandedFlag:
    if edit.kind == fneCreate and entry.path.len > 0 and
        edit.folder == entry.path:
      # Create: the field is the folder's first child.
      r.appendChild(children,
                    renderCreateFieldNode[R, N](r, vm, edit, level + 1))
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
  # Bound where instantiated: on JS this module also sees WebRenderer's.
  mixin clearChildren, appendChild, setAttribute, createTextNode
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
    # Its sentence depends on WHY the tree is empty (no project folder, or a
    # load that found nothing), so it is rewritten on every run.
    r.clearChildren(emptyContainer)
    r.appendChild(emptyContainer, r.createTextNode(emptyStateText(vm)))
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
