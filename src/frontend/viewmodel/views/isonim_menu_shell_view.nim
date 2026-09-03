## IsoNim view for the global menu shell.
##
## State derivation and legacy menu actions stay in ``ui/menu.nim``.  This view
## owns the shared ``#menu`` host structure so the global menu chrome no longer
## needs a Karax ``setRenderer`` registration.

import std/[strutils, tables]
import isonim/dsl/ui
from isonim/core/computation import createRenderEffect
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

type
  MenuNodeRecordKind* = enum
    MenuRecordElement
    MenuRecordFolder

  MenuNodeRecord* = ref object
    kind*: MenuNodeRecordKind
    name*: string
    shortcut*: string
    enabled*: bool
    iconClass*: string
    nameClass*: string
    nodeClass*: string
    path*: seq[int]
    nameWidth*: int
    beforeNextSubGroup*: bool
    children*: seq[MenuNodeRecord]

  MenuSearchResultRecord* = object
    label*: string
    shortcut*: string
    iconClass*: string
    active*: bool

  MenuNestedRecord* = object
    id*: string
    className*: string
    style*: string
    nodes*: seq[MenuNodeRecord]

  MenuShellModel* = object
    showNavigation*: bool
    active*: bool
    searchQuery*: string
    rootNodes*: seq[MenuNodeRecord]
    searchResults*: seq[MenuSearchResultRecord]
    nestedMenus*: seq[MenuNestedRecord]
    showWindowMenu*: bool
    maximized*: bool

  MenuShellCallbacks* = object
    onToggleMenu*: proc()
    onNavBlur*: proc()
    onNavMouseDown*: proc()
    onMainMouseOver*: proc()
    onNodeMouseOver*: proc(path: seq[int])
    onNodeClick*: proc(path: seq[int])
    onSearchResultClick*: proc(index: int)
    onMinimizeWindow*: proc()
    onMaximizeWindow*: proc()
    onRestoreWindow*: proc()
    onCloseWindow*: proc()

const
  MenuShellRootClass* = "menu-shell"
  ## Set on the caption-bar host (`#menu`) while the platform paints its own
  ## window controls over the bar and space must be reserved for them.
  MenuShellReservedControlsClass* = "menu-shell--reserved-window-controls"
  ## Set on the same host while the window is in native fullscreen, where those
  ## controls are hidden and the bar reclaims the space.
  MenuShellFullscreenClass* = "menu-shell--native-fullscreen"
  NavigationMenuId* = "navigation-menu"
  DebugControlsHostId* = "isonim-debug-controls"
    ## The topbar host, named once because three modules have to agree on it:
    ## this view emits it, `ui/debug.nim` mounts the toolbar into it, and
    ## `ui/menu.nim` asks whether it is still on screen before trusting the
    ## render gate.
  MenuShellSessionTabBarId* = "session-tab-bar"
  MenuRootId* = "menu-root"
  MenuMainId* = "menu-main"
  MenuElementsId* = "menu-elements"
  MenuSearchResultsId* = "menu-search-results"
  WindowMenuClass* = "window-menu"

proc captionBarHostClasses*(
    existing: string;
    reserveWindowControls: bool;
    fullscreen: bool): string =
  ## Pure decision logic for the classes on the caption-bar host (`#menu` in
  ## index.html) — kept free of any DOM call so it can be exercised headlessly,
  ## in the spirit of `ui/menu_render_gate.nim`.
  ##
  ## Three states, only distinguishable at runtime:
  ##
  ## * platform draws its own frame (Windows/Linux) — neither class;
  ## * macOS windowed — `MenuShellReservedControlsClass`, so the bar starts
  ##   clear of the traffic-light buttons the OS paints over it;
  ## * macOS fullscreen — `MenuShellFullscreenClass`; the buttons are gone, so
  ##   the bar reclaims the space and left-aligns instead.
  ##
  ## Classes it does not own (`menu`, and anything added elsewhere) are
  ## preserved in their original order.
  var kept: seq[string] = @[]
  for cls in existing.split({' ', '\t', '\n'}):
    if cls.len > 0 and
       cls != MenuShellReservedControlsClass and
       cls != MenuShellFullscreenClass:
      kept.add(cls)
  if reserveWindowControls:
    kept.add(
      if fullscreen: MenuShellFullscreenClass
      else: MenuShellReservedControlsClass)
  kept.join(" ")

proc invokeToggle(callbacks: MenuShellCallbacks) =
  if not callbacks.onToggleMenu.isNil:
    callbacks.onToggleMenu()

proc invokeNavBlur(callbacks: MenuShellCallbacks) =
  if not callbacks.onNavBlur.isNil:
    callbacks.onNavBlur()

proc invokeNavMouseDown(callbacks: MenuShellCallbacks) =
  if not callbacks.onNavMouseDown.isNil:
    callbacks.onNavMouseDown()

proc invokeMainMouseOver(callbacks: MenuShellCallbacks) =
  if not callbacks.onMainMouseOver.isNil:
    callbacks.onMainMouseOver()

proc invokeNodeMouseOver(callbacks: MenuShellCallbacks; path: seq[int]) =
  if not callbacks.onNodeMouseOver.isNil:
    callbacks.onNodeMouseOver(path)

proc invokeNodeClick(callbacks: MenuShellCallbacks; path: seq[int]) =
  if not callbacks.onNodeClick.isNil:
    callbacks.onNodeClick(path)

proc invokeSearchResult(callbacks: MenuShellCallbacks; index: int) =
  if not callbacks.onSearchResultClick.isNil:
    callbacks.onSearchResultClick(index)

proc nodeMouseOverHandler(
    callbacks: MenuShellCallbacks;
    path: seq[int]): proc() =
  let capturedPath = path
  result = proc() = callbacks.invokeNodeMouseOver(capturedPath)

proc nodeClickHandler(
    callbacks: MenuShellCallbacks;
    path: seq[int]): proc() =
  let capturedPath = path
  result = proc() = callbacks.invokeNodeClick(capturedPath)

proc searchResultClickHandler(
    callbacks: MenuShellCallbacks;
    index: int): proc() =
  let capturedIndex = index
  result = proc() = callbacks.invokeSearchResult(capturedIndex)

proc invokeMinimize(callbacks: MenuShellCallbacks) =
  if not callbacks.onMinimizeWindow.isNil:
    callbacks.onMinimizeWindow()

proc invokeMaximize(callbacks: MenuShellCallbacks) =
  if not callbacks.onMaximizeWindow.isNil:
    callbacks.onMaximizeWindow()

proc invokeRestore(callbacks: MenuShellCallbacks) =
  if not callbacks.onRestoreWindow.isNil:
    callbacks.onRestoreWindow()

proc invokeClose(callbacks: MenuShellCallbacks) =
  if not callbacks.onCloseWindow.isNil:
    callbacks.onCloseWindow()

proc searchResultClass(searchResult: MenuSearchResultRecord): string =
  if searchResult.active:
    "menu-node-name menu-active-search-result"
  else:
    "menu-node-name "

proc menuItemClass*(node: MenuNodeRecord): string =
  ## Class list for one rendered menu row (both the root menu and every
  ## submenu use it, so the two stay addressable by the same selectors).
  ##
  ## Two vocabularies live on the row on purpose:
  ##
  ## * the design-system component classes — ``ct-menu-item`` plus the
  ##   ``--active`` / ``--disabled`` modifiers — carry *all* of the visual
  ##   styling (``styles/components/menu_item.styl``);
  ## * the semantic hooks — ``menu-node``, ``menu-element`` / ``menu-folder``,
  ##   the per-entry identity class in ``node.nameClass`` (``menu-folder-debug``,
  ##   ``menu-element-ruby-fibonacci``, …, built in ``ui/menu.nim``) and
  ##   ``menu-enabled`` / ``menu-disabled`` — carry no styling at all.  They
  ##   exist so the menu remains *addressable*: they are the published contract
  ##   the GUI test suite selects on
  ##   (``codetracer-specs/Testing/UI-Test-Catalog.md`` § Launch Configuration
  ##   Tests: ".menu-folder-debug", ".menu-folder-launch-configurations",
  ##   ".menu-element-python-fibonacci", ".menu-element-ruby-fibonacci" and
  ##   "Verifies `.menu-enabled` class on launch config elements"), and what
  ##   ``welcome-screen/launch_config.spec.ts`` drives the Debug ▸ Launch
  ##   Configurations flow through.
  ##
  ## They were dropped when the rows were restyled onto ``ct-menu-item``, which
  ## silently unhooked every one of those selectors — hence this helper, so the
  ## four call sites below cannot drift apart again.
  let kindClass =
    if node.kind == MenuRecordElement: "menu-element" else: "menu-folder"
  result = "ct-menu-item menu-node " & kindClass
  if node.nameClass.len > 0:
    result.add ' '
    result.add node.nameClass
  result.add(if node.enabled: " menu-enabled" else: " menu-disabled")
  if node.nodeClass == "menu-active-node":
    result.add " ct-menu-item--active"
  if not node.enabled:
    result.add " ct-menu-item--disabled"

template renderMenuShellImpl(
    r: untyped;
    model: MenuShellModel;
    callbacks: MenuShellCallbacks): untyped =
  ui(r):
    tdiv(id = "menu", class = MenuShellRootClass):
      if model.showNavigation:
        tdiv(
            id = NavigationMenuId,
            tabindex = "0",
            onblur = proc() = callbacks.invokeNavBlur(),
            onmousedown = proc() = callbacks.invokeNavMouseDown()):
          button(
              class = "ct-button-image-md-secondary ct-button-no-border",
              id = MenuRootId,
              onclick = proc() = callbacks.invokeToggle()):
            tdiv(id = "menu-logo-img"):
              discard
          if model.active:
            tdiv(
                id = MenuMainId,
                onmouseover = proc() = callbacks.invokeMainMouseOver()):
              tdiv(id = MenuSearchResultsId):
                if model.searchQuery.len > 0:
                  if model.searchResults.len == 0:
                    tdiv(class = "menu-no-search-results"):
                      text "No results found"
                  else:
                    for searchIndex, searchResult in model.searchResults:
                      let currentSearchIndex = searchIndex
                      tdiv(
                          class = "menu-search-result",
                          onclick = searchResultClickHandler(
                            callbacks, currentSearchIndex)):
                        tdiv(class = "menu-node-icon"):
                          tdiv(class = "icon " & searchResult.iconClass):
                            discard
                        span(class = searchResultClass(searchResult)):
                          text searchResult.label
                        span(class = "menu-node-shortcut"):
                          text searchResult.shortcut
              tdiv(id = MenuElementsId):
                if model.searchQuery.len == 0:
                  for rootIndex in 0 ..< model.rootNodes.len:
                    let node = model.rootNodes[rootIndex]
                    tdiv(
                        class = "menu-node-container " & node.nodeClass,
                        onmouseover = nodeMouseOverHandler(callbacks, node.path),
                        onclick =
                          if node.kind == MenuRecordElement:
                            nodeClickHandler(callbacks, node.path)
                          else:
                            nil):
                      if node.kind == MenuRecordElement:
                        tdiv(
                            id = "menu-element-" & $node.path.len & " " & $node.path[^1],
                            class = menuItemClass(node),
                            onmouseover = nodeMouseOverHandler(callbacks, node.path),
                            onclick = nodeClickHandler(callbacks, node.path)):
                          span(class = "ct-menu-item-label"):
                            text node.name
                          if node.shortcut.len > 0:
                            span(class = "ct-menu-item-sublabel"):
                              text node.shortcut
                      else:
                        tdiv(
                            class = menuItemClass(node),
                            onmouseover = nodeMouseOverHandler(callbacks, node.path)):
                          span(class = "ct-menu-item-label"):
                            text node.name
                          span(class = "ct-menu-item-trailing"):
                            discard
                      if node.beforeNextSubGroup:
                        hr(class = "menu-sub-group-separator"):
                          discard
              for nestedIndex in 0 ..< model.nestedMenus.len:
                var nested = model.nestedMenus[nestedIndex]
                tdiv(
                    class = nested.className,
                    id = nested.id,
                    style = nested.style):
                  for nodeIndex in 0 ..< nested.nodes.len:
                    let node = nested.nodes[nodeIndex]
                    tdiv(
                        class = "menu-node-container " & node.nodeClass,
                        onmouseover = nodeMouseOverHandler(callbacks, node.path),
                        onclick =
                          if node.kind == MenuRecordElement:
                            nodeClickHandler(callbacks, node.path)
                          else:
                            nil):
                      if node.kind == MenuRecordElement:
                        tdiv(
                            id = "menu-element-" & $node.path.len & " " & $node.path[^1],
                            class = menuItemClass(node),
                            onmouseover = nodeMouseOverHandler(callbacks, node.path),
                            onclick = nodeClickHandler(callbacks, node.path)):
                          span(class = "ct-menu-item-label"):
                            text node.name
                          if node.shortcut.len > 0:
                            span(class = "ct-menu-item-sublabel"):
                              text node.shortcut
                      else:
                        tdiv(
                            class = menuItemClass(node),
                            onmouseover = nodeMouseOverHandler(callbacks, node.path)):
                          span(class = "ct-menu-item-label"):
                            text node.name
                          span(class = "ct-menu-item-trailing"):
                            discard
                      if node.beforeNextSubGroup:
                        hr(class = "menu-sub-group-separator"):
                          discard

      tdiv(id = DebugControlsHostId):
        discard
      tdiv(id = "debug", class = "ct-header"):
        discard

      tdiv(id = MenuShellSessionTabBarId, class = "session-tab-bar"):
        discard

      if model.showWindowMenu:
        tdiv(class = WindowMenuClass):
          tdiv(
              class = "menu-button-svg minimize",
              onclick = proc() = callbacks.invokeMinimize()):
            discard
          if model.maximized:
            tdiv(
                class = "menu-button-svg restore",
                onclick = proc() = callbacks.invokeRestore()):
              discard
          else:
            tdiv(
                class = "menu-button-svg maximize",
                onclick = proc() = callbacks.invokeMaximize()):
              discard
          tdiv(
              class = "menu-button-svg close",
              onclick = proc() = callbacks.invokeClose()):
            discard

proc renderMenuShell*(
    r: MockRenderer;
    model: MenuShellModel;
    callbacks: MenuShellCallbacks = MenuShellCallbacks()): MockNode =
  renderMenuShellImpl(r, model, callbacks)

# ---------------------------------------------------------------------------
# Rebuilding the shell around a host that must NOT be rebuilt
# ---------------------------------------------------------------------------
#
# `renderMenuShellInto` clears its host and re-creates the whole subtree, and
# `#isonim-debug-controls` is part of that subtree — so every shell rebuild
# used to hand `ui/debug.nim` a brand-new, empty host and take the mounted
# debugger toolbar with it.  Issue #555's flicker was one consequence and
# `ui/menu_render_gate.nim` addressed it by rebuilding LESS OFTEN; this is the
# other consequence, and rebuilding less often cannot fix it:
#
#   THE REBUILD DESTROYS THE NEXT CLICK, not merely the current paint.  A
#   pointer press is `mousedown` then `mouseup`, and per the DOM spec the
#   browser fires a `click` ONLY when both landed on the same node.  A rebuild
#   that happens between them replaces every button in the toolbar, the two
#   land on different nodes, and NO `click` EVENT IS PRODUCED AT ALL.  Measured
#   in one tab, four arms, capture-phase listeners on `window`:
#
#     nothing beforehand           mousedown/mouseup/click, same node -> ran
#     click the topbar background  mousedown+mouseup, DIFFERENT nodes,
#                                  no click event whatsoever          -> nothing
#     click inside the editor      same node                          -> ran
#     blur via JS                  same node                          -> ran
#
#   Clicking the menu bar's own background is enough, because
#   `#isonim-debug-controls` is a CHILD of `#menu`.  So a user who touches the
#   caption bar and then presses Run, or Step, or Stop, gets one silently
#   discarded press — the control is painted, hit-testable and dead.
#
# The fix is structural: the shell is rebuilt AROUND the existing host rather
# than over it.  Everything else in the caption bar is removed, the host stays
# exactly where it is, and the new siblings are inserted before and after it —
# so its node identity, and every button the toolbar mounted inside it,
# survives a rebuild.
#
# A DETACH THAT IS IMMEDIATELY UNDONE IS NOT GOOD ENOUGH, and that is a
# measurement rather than a precaution.  The first version of this preserved
# the node but took it out of the container while the shell was rebuilt and put
# it back after; in a browser, `mousedown` and `mouseup` then BOTH landed on
# `#next-image` — the same node, tags intact all the way up the ancestor chain
# — and the browser still produced no `click`.  Removing an element from the
# document cancels the click sequence its press had started, whether or not the
# element comes back.  So the host is never removed at all.
#
# NOT a synthetic re-dispatch of the lost click.  Node identity is the actual
# problem; re-dispatching would paper over the one gesture a test happens to
# drive while leaving every other control equally affected.
#
# The host carries no attribute but its `id` and no listener of its own (the
# view emits it with an empty body), so carrying the old node forward loses
# nothing the render would have set on it.  If it ever gains one, this swap is
# the place that has to start reconciling it.
#
# The helpers below exist so that ONE implementation serves both backends: the
# mock renderer is what lets the identity property be asserted headlessly
# (`src/tests/gui/tests/session-chrome/menu_redraw_storm_test.nim`), and a
# JS-only fix would have been a fix nothing could test.

proc menuShellFindChild(r: MockRenderer; parent: MockNode; id: string): MockNode =
  ## The host is a DIRECT child of the shell root, so this deliberately does
  ## not recurse: a nested element that happened to share the id must not be
  ## mistaken for it.
  for child in parent.children:
    if child.kind == mnkElement and
        child.attributes.getOrDefault("id", "") == id:
      return child
  nil

proc menuShellIsNilNode(node: MockNode): bool = node.isNil

proc menuShellClearExcept(r: MockRenderer; container, keep: MockNode) =
  let existing = container.children
  for child in existing:
    if child != keep:
      r.removeChild(container, child)

proc menuShellMoveChildren(r: MockRenderer; destination, source: MockNode) =
  ## Over a COPY of the child list: `appendChild` detaches first, so iterating
  ## `source.children` directly would skip every other node.
  let moving = source.children
  for child in moving:
    r.appendChild(destination, child)

proc menuShellMoveChildrenAround(
    r: MockRenderer; destination, source, anchor: MockNode) =
  var seenPlaceholder = false
  let moving = source.children
  for child in moving:
    if child.kind == mnkElement and
        child.attributes.getOrDefault("id", "") == DebugControlsHostId:
      seenPlaceholder = true
      r.removeChild(source, child)
      continue
    if seenPlaceholder:
      r.appendChild(destination, child)
    else:
      r.insertBefore(destination, child, anchor)

when defined(js):
  proc renderMenuShell*(
      r: WebRenderer;
      model: MenuShellModel;
      callbacks: MenuShellCallbacks = MenuShellCallbacks()):
        isonim_dom.Element =
    renderMenuShellImpl(r, model, callbacks)

  proc menuShellFindChild(r: WebRenderer; parent: isonim_dom.Element;
                          id: string): isonim_dom.Element =
    var child = isonim_dom.Node(parent).firstChild
    while not isonim_dom.isNodeNil(child):
      # `nodeType == 1` is ELEMENT_NODE; `getAttribute` does not exist on the
      # text nodes a shell render can leave between elements.
      if child.nodeType == 1:
        let element = cast[isonim_dom.Element](child)
        let raw = isonim_dom.getAttribute(element, cstring"id")
        if not raw.isNil and $raw == id:
          return element
      child = child.nextSibling
    nil

  proc menuShellIsNilNode(node: isonim_dom.Element): bool =
    isonim_dom.isNodeNil(isonim_dom.Node(node))

  proc menuShellSameNode(a, b: isonim_dom.Node): bool {.importjs: "(# === #)".}

  proc menuShellIsHostPlaceholder(node: isonim_dom.Node): bool =
    if node.nodeType != 1:
      return false
    let raw = isonim_dom.getAttribute(
      cast[isonim_dom.Element](node), cstring"id")
    not raw.isNil and $raw == DebugControlsHostId

  proc menuShellClearExcept(r: WebRenderer;
                            container, keep: isonim_dom.Element) =
    let containerNode = isonim_dom.Node(container)
    let keepNode = isonim_dom.Node(keep)
    var child = containerNode.firstChild
    while not isonim_dom.isNodeNil(child):
      let next = child.nextSibling
      if not menuShellSameNode(child, keepNode):
        discard isonim_dom.removeChild(containerNode, child)
      child = next

  proc menuShellMoveChildren(r: WebRenderer;
                             destination, source: isonim_dom.Element) =
    let destinationNode = isonim_dom.Node(destination)
    let sourceNode = isonim_dom.Node(source)
    while not isonim_dom.isNodeNil(sourceNode.firstChild):
      discard isonim_dom.appendChild(destinationNode, sourceNode.firstChild)

  proc menuShellMoveChildrenAround(
      r: WebRenderer; destination, source, anchor: isonim_dom.Element) =
    let destinationNode = isonim_dom.Node(destination)
    let sourceNode = isonim_dom.Node(source)
    let anchorNode = isonim_dom.Node(anchor)
    var seenPlaceholder = false
    while not isonim_dom.isNodeNil(sourceNode.firstChild):
      let child = sourceNode.firstChild
      if menuShellIsHostPlaceholder(child):
        seenPlaceholder = true
        discard isonim_dom.removeChild(sourceNode, child)
        continue
      if seenPlaceholder:
        discard isonim_dom.appendChild(destinationNode, child)
      else:
        discard isonim_dom.insertBefore(destinationNode, child, anchorNode)

# BELOW THE BACKEND HELPERS ON PURPOSE. A template binds the overloads it can
# already see at its definition site, so a template declared above the
# `when defined(js)` block would resolve `menuShellFindChild` and friends to
# the mock ones and fail to compile for the web.
template renderMenuShellIntoImpl(
    r: untyped;
    container: untyped;
    model: MenuShellModel;
    callbacks: MenuShellCallbacks): untyped =
  let preservedHost = menuShellFindChild(r, container, DebugControlsHostId)
  let hasPreserved = not menuShellIsNilNode(preservedHost)
  # NB: only the shell's *children* reach the caller's host; the wrapper the
  # render produced is discarded.  A class set on it never reaches the
  # document, so the caption-bar host classes are owned by `ui/menu.nim`
  # instead — it also has to track fullscreen, which no render pass knows
  # about.
  if hasPreserved:
    # THE HOST NEVER LEAVES THE DOCUMENT. Everything around it is removed and
    # the new siblings are inserted before and after it, rather than the host
    # being detached and put back — see the header for why a detach that is
    # immediately undone is still enough to lose a press.
    menuShellClearExcept(r, container, preservedHost)
    let shell = renderMenuShell(r, model, callbacks)
    menuShellMoveChildrenAround(r, container, shell, preservedHost)
  else:
    r.clearChildren(container)
    let shell = renderMenuShell(r, model, callbacks)
    menuShellMoveChildren(r, container, shell)

proc renderMenuShellInto*(
    r: MockRenderer;
    container: MockNode;
    model: MenuShellModel;
    callbacks: MenuShellCallbacks = MenuShellCallbacks()) =
  renderMenuShellIntoImpl(r, container, model, callbacks)

when defined(js):
  proc renderMenuShellInto*(
      r: WebRenderer;
      container: isonim_dom.Element;
      model: MenuShellModel;
      callbacks: MenuShellCallbacks = MenuShellCallbacks()) =
    renderMenuShellIntoImpl(r, container, model, callbacks)
