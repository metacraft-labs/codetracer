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
##     div.diff-files-list                          (when hasDiff)
##       div.diff-file-path[.path-even|.path-odd]
##                                       (one per FilesystemDiffEntry)
##     div.deepreview-file-list             (when deepReviewActive)
##       div.deepreview-file-item-compact   (one per deep-review row)
##         span.deepreview-diff-status-compact[.deepreview-diff-…]
##         span.deepreview-file-name-compact
##         span.deepreview-diff-lines-compact[.deepreview-diff-…]
##         span.deepreview-coverage-compact
##
## Reactive surface:
## - One outer ``createRenderEffect`` rebuilds the tree, the diff
##   list, the deep-review list, and toggles the empty-state placeholder
##   whenever any source signal (``rootEntry`` / ``expandedPaths`` /
##   ``diffEntries`` / ``deepReviewActive`` / ``deepReviewFiles``)
##   changes.  Mirrors the trace_log / scratchpad pattern (DSL builds
##   the static shell, imperative renderer ops inside the effect
##   handle the dynamic content).

import std/[strutils, tables]

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../store/types
import ../viewmodels/filesystem_vm

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

proc deepReviewStatusClass*(status: string): string =
  ## Map the single-letter status code (``"A"``/``"M"``/``"D"``) to the
  ## CSS suffix the legacy ``deepreview-diff-…`` rule expects.
  case status
  of "A": "deepreview-diff-added"
  of "M": "deepreview-diff-modified"
  of "D": "deepreview-diff-deleted"
  else: ""

# ---------------------------------------------------------------------------
# Mock renderer — headless test DOM
# ---------------------------------------------------------------------------

proc renderMockEntry(r: MockRenderer; vm: FilesystemVM;
                     entry: FilesystemEntryNode): MockNode =
  ## Render a single tree node + its visible children.  Recurses only
  ## when the node is an expanded folder so collapsed subtrees are not
  ## materialised — matches the jstree behaviour at the DOM-shape
  ## level.
  let expandedFlag = vm.isExpanded(entry.path)
  let path = entry.path
  let row = ui(r):
    tdiv(class = rowClass(entry, expandedFlag),
         id = (if entry.id.len > 0: "j" & entry.id else: ""),
         onclick = proc() =
           if entry.isFolder:
             vm.toggleExpanded(path)):
      span(class = "filesystem-entry-twisty"):
        text twistyText(entry, expandedFlag)
      tdiv(class = "filesystem-entry-icon"):
        text entry.icon
      span(class = "filesystem-entry-label"):
        text entry.text
      tdiv(class = "filesystem-entry-children"):
        discard
  if entry.isFolder and expandedFlag:
    let children = entry.children
    var lastChildContainer: MockNode = nil
    for child in row.children:
      if child.kind == mnkElement and
         child.attributes.getOrDefault("class", "") == "filesystem-entry-children":
        lastChildContainer = child
        break
    if lastChildContainer != nil:
      for child in children:
        let childNode = renderMockEntry(r, vm, child)
        r.appendChild(lastChildContainer, childNode)
  row

proc renderFilesystemPanel*(r: MockRenderer; vm: FilesystemVM): MockNode =
  ## Render the Filesystem panel for the Mock renderer.
  ##
  ## The static shell (outer container + filesystem wrapper +
  ## tree + empty-overlay + diff-files-list + deepreview-file-list) is
  ## built once via the DSL.  A single outer ``createRenderEffect``
  ## rebuilds the dynamic content whenever any source signal changes.
  var treeContainer: MockNode
  var emptyContainer: MockNode
  var diffContainer: MockNode
  var deepReviewContainer: MockNode

  let panel = ui(r):
    tdiv(class = FilesystemContainerClass):
      tdiv(class = "filesystem"):
        tdiv(ref = treeContainer, class = FilesystemTreeContainerClass):
          discard
        tdiv(ref = emptyContainer, class = "filesystem-empty-overlay"):
          text FilesystemEmptyStateText
      tdiv(ref = diffContainer, class = "diff-files-list"):
        discard
      tdiv(ref = deepReviewContainer, class = "deepreview-file-list"):
        discard

  createRenderEffect proc() =
    # -- Tree --
    let root = vm.rootEntry.val
    r.clearChildren(treeContainer)
    if root.children.len > 0:
      for child in root.children:
        let childNode = renderMockEntry(r, vm, child)
        r.appendChild(treeContainer, childNode)
    elif root.text.len > 0:
      # Single-node tree (rare but supported — e.g. a recording
      # captured via a single file path).  Render the root itself.
      let node = renderMockEntry(r, vm, root)
      r.appendChild(treeContainer, node)

    # -- Empty-state overlay --
    if vm.isEmpty.val:
      r.setAttribute(emptyContainer, "class", "filesystem-empty-overlay")
    else:
      r.setAttribute(emptyContainer, "class",
                     "filesystem-empty-overlay hidden")

    # -- Diff list --
    let diffs = vm.diffEntries.val
    r.clearChildren(diffContainer)
    if diffs.len == 0:
      r.setAttribute(diffContainer, "class", "diff-files-list hidden")
    else:
      r.setAttribute(diffContainer, "class", "diff-files-list")
      for diff in diffs:
        # Copy the row data into local non-lent vars so the inner
        # closure (no-op today; future bridge wires ``data.openTab``)
        # can capture them safely.  Without the copy the iterator's
        # ``lent FilesystemDiffEntry`` cannot be captured.
        let rowClsLocal = diffEntryClass(diff)
        let rowLabelLocal = diffEntryLabel(diff)
        let row = ui(r):
          tdiv(class = rowClsLocal,
               onclick = proc() =
                 # The bridge wires ``vm.openTabHandler`` (if any)
                 # through ``data.openTab``; on the headless path
                 # there is nothing to do — clicking is a no-op so
                 # tests can fire it without side effects.
                 discard):
            text rowLabelLocal
        r.appendChild(diffContainer, row)

    # -- Deep-review list --
    let drFiles = vm.deepReviewFiles.val
    let drActive = vm.deepReviewActive.val
    r.clearChildren(deepReviewContainer)
    if not drActive or drFiles.len == 0:
      r.setAttribute(deepReviewContainer, "class",
                     "deepreview-file-list hidden")
    else:
      r.setAttribute(deepReviewContainer, "class", "deepreview-file-list")
      for file in drFiles:
        # Materialise every value the DSL touches into local non-lent
        # vars — the DSL emits closures for ``text`` slots, and those
        # closures cannot capture an iterator's ``lent
        # FilesystemDeepReviewFile`` directly.
        let statusCls = deepReviewStatusClass(file.status)
        let statusFull =
          if statusCls.len > 0:
            "deepreview-diff-status-compact " & statusCls
          else:
            "deepreview-diff-status-compact"
        let linesFull =
          if statusCls.len > 0:
            "deepreview-diff-lines-compact " & statusCls
          else:
            "deepreview-diff-lines-compact"
        let statusLocal = file.status
        let nameLocal = file.baseName
        let linesText = "+" & $file.linesAdded & "/-" & $file.linesRemoved
        let coverageText = $file.coverageExecuted & "/" & $file.coverageTotal
        let row = ui(r):
          tdiv(class = "deepreview-file-item-compact"):
            span(class = statusFull):
              text statusLocal
            span(class = "deepreview-file-name-compact"):
              text nameLocal
            span(class = linesFull):
              text linesText
            span(class = "deepreview-coverage-compact"):
              text coverageText
        r.appendChild(deepReviewContainer, row)

  panel

# ---------------------------------------------------------------------------
# Web renderer — production DOM
# ---------------------------------------------------------------------------

when defined(js):

  proc createWebElement(tag: string; cssClass: string = "";
                        elemId: string = ""): isonim_dom.Element =
    ## Helper: create a DOM element with optional class + id
    ## attributes.
    let n = isonim_dom.createElement(isonim_dom.document, cstring(tag))
    if cssClass.len > 0:
      isonim_dom.setAttribute(n, cstring"class", cstring(cssClass))
    if elemId.len > 0:
      isonim_dom.setAttribute(n, cstring"id", cstring(elemId))
    n

  proc createWebTextElement(tag: string; textValue: string;
                            cssClass: string = "";
                            elemId: string = ""): isonim_dom.Element =
    ## Helper: create an element with a text-node child in one shot.
    let n = createWebElement(tag, cssClass, elemId)
    let t = isonim_dom.createTextNode(isonim_dom.document, cstring(textValue))
    isonim_dom.appendChild(isonim_dom.Node(n), t)
    n

  proc clearWebChildren(node: isonim_dom.Element) =
    let asNode = isonim_dom.Node(node)
    while not isonim_dom.isNodeNil(asNode.firstChild):
      discard isonim_dom.removeChild(asNode, asNode.firstChild)

  proc renderWebEntry(vm: FilesystemVM;
                      entry: FilesystemEntryNode): isonim_dom.Element =
    ## Build a tree node in the real DOM.  Same shape as the Mock
    ## variant; click handler is wired imperatively via
    ## ``addEventListener``.
    let expandedFlag = vm.isExpanded(entry.path)
    let row = createWebElement("div", rowClass(entry, expandedFlag),
                               (if entry.id.len > 0: "j" & entry.id else: ""))
    let entryPath = entry.path
    let isFolder = entry.isFolder
    isonim_dom.addEventListener(isonim_dom.Node(row), cstring"click",
                                proc(ev: isonim_dom.Event) =
      if isFolder:
        vm.toggleExpanded(entryPath))

    let twisty = createWebTextElement("span", twistyText(entry, expandedFlag),
                                      "filesystem-entry-twisty")
    isonim_dom.appendChild(isonim_dom.Node(row), isonim_dom.Node(twisty))

    let icon = createWebTextElement("div", entry.icon,
                                    "filesystem-entry-icon")
    isonim_dom.appendChild(isonim_dom.Node(row), isonim_dom.Node(icon))

    let label = createWebTextElement("span", entry.text,
                                     "filesystem-entry-label")
    isonim_dom.appendChild(isonim_dom.Node(row), isonim_dom.Node(label))

    let children = createWebElement("div", "filesystem-entry-children")
    isonim_dom.appendChild(isonim_dom.Node(row), isonim_dom.Node(children))

    if isFolder and expandedFlag:
      for child in entry.children:
        let childNode = renderWebEntry(vm, child)
        isonim_dom.appendChild(isonim_dom.Node(children),
                               isonim_dom.Node(childNode))
    row

  proc renderFilesystemPanel*(r: WebRenderer;
                              vm: FilesystemVM): isonim_dom.Element =
    ## Render the Filesystem panel for the real DOM.  Same dispatch
    ## shape as the Mock variant — outer wrapper plus a render-effect
    ## that rebuilds the tree / diff / deep-review lists and toggles
    ## the empty-state placeholder.
    var treeContainer: isonim_dom.Element
    var emptyContainer: isonim_dom.Element
    var diffContainer: isonim_dom.Element
    var deepReviewContainer: isonim_dom.Element

    let panel = ui(r):
      tdiv(class = FilesystemContainerClass):
        tdiv(class = "filesystem"):
          tdiv(ref = treeContainer, class = FilesystemTreeContainerClass):
            discard
          tdiv(ref = emptyContainer, class = "filesystem-empty-overlay"):
            text FilesystemEmptyStateText
        tdiv(ref = diffContainer, class = "diff-files-list"):
          discard
        tdiv(ref = deepReviewContainer, class = "deepreview-file-list"):
          discard

    createRenderEffect proc() =
      # -- Tree --
      let root = vm.rootEntry.val
      clearWebChildren(treeContainer)
      if root.children.len > 0:
        for child in root.children:
          let childNode = renderWebEntry(vm, child)
          isonim_dom.appendChild(isonim_dom.Node(treeContainer),
                                 isonim_dom.Node(childNode))
      elif root.text.len > 0:
        let node = renderWebEntry(vm, root)
        isonim_dom.appendChild(isonim_dom.Node(treeContainer),
                               isonim_dom.Node(node))

      # -- Empty-state overlay --
      if vm.isEmpty.val:
        isonim_dom.setAttribute(emptyContainer, cstring"class",
                                cstring"filesystem-empty-overlay")
      else:
        isonim_dom.setAttribute(emptyContainer, cstring"class",
                                cstring"filesystem-empty-overlay hidden")

      # -- Diff list --
      let diffs = vm.diffEntries.val
      clearWebChildren(diffContainer)
      if diffs.len == 0:
        isonim_dom.setAttribute(diffContainer, cstring"class",
                                cstring"diff-files-list hidden")
      else:
        isonim_dom.setAttribute(diffContainer, cstring"class",
                                cstring"diff-files-list")
        for diff in diffs:
          let row = createWebTextElement("div", diffEntryLabel(diff),
                                         diffEntryClass(diff))
          isonim_dom.appendChild(isonim_dom.Node(diffContainer),
                                 isonim_dom.Node(row))

      # -- Deep-review list --
      let drFiles = vm.deepReviewFiles.val
      let drActive = vm.deepReviewActive.val
      clearWebChildren(deepReviewContainer)
      if not drActive or drFiles.len == 0:
        isonim_dom.setAttribute(deepReviewContainer, cstring"class",
                                cstring"deepreview-file-list hidden")
      else:
        isonim_dom.setAttribute(deepReviewContainer, cstring"class",
                                cstring"deepreview-file-list")
        for file in drFiles:
          let statusCls = deepReviewStatusClass(file.status)
          let row = createWebElement("div", "deepreview-file-item-compact")
          let statusFull =
            if statusCls.len > 0:
              "deepreview-diff-status-compact " & statusCls
            else:
              "deepreview-diff-status-compact"
          let statusSpan = createWebTextElement("span", file.status,
                                                statusFull)
          isonim_dom.appendChild(isonim_dom.Node(row),
                                 isonim_dom.Node(statusSpan))

          let nameSpan = createWebTextElement("span", file.baseName,
                                              "deepreview-file-name-compact")
          isonim_dom.appendChild(isonim_dom.Node(row),
                                 isonim_dom.Node(nameSpan))

          let linesFull =
            if statusCls.len > 0:
              "deepreview-diff-lines-compact " & statusCls
            else:
              "deepreview-diff-lines-compact"
          let linesSpan = createWebTextElement(
            "span",
            "+" & $file.linesAdded & "/-" & $file.linesRemoved,
            linesFull)
          isonim_dom.appendChild(isonim_dom.Node(row),
                                 isonim_dom.Node(linesSpan))

          let coverageSpan = createWebTextElement(
            "span",
            $file.coverageExecuted & "/" & $file.coverageTotal,
            "deepreview-coverage-compact")
          isonim_dom.appendChild(isonim_dom.Node(row),
                                 isonim_dom.Node(coverageSpan))

          isonim_dom.appendChild(isonim_dom.Node(deepReviewContainer),
                                 isonim_dom.Node(row))

    panel

  proc mountIsoNimFilesystemPanel*(container: isonim_dom.Element;
                                   vm: FilesystemVM) =
    ## Mount the IsoNim Filesystem panel as a child of ``container``.
    ## Reactive effects handle every subsequent update — no manual
    ## redraw is needed.
    let r = WebRenderer()
    let panel = renderFilesystemPanel(r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container),
                           isonim_dom.Node(panel))
