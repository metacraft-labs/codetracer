## IsoNim view for the global menu shell.
##
## State derivation and legacy menu actions stay in ``ui/menu.nim``.  This view
## owns the shared ``#menu`` host structure so the global menu chrome no longer
## needs a Karax ``setRenderer`` registration.

import std/strutils
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

      tdiv(id = "isonim-debug-controls"):
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

when defined(js):
  proc renderMenuShell*(
      r: WebRenderer;
      model: MenuShellModel;
      callbacks: MenuShellCallbacks = MenuShellCallbacks()):
        isonim_dom.Element =
    renderMenuShellImpl(r, model, callbacks)

  proc renderMenuShellInto*(
      r: WebRenderer;
      container: isonim_dom.Element;
      model: MenuShellModel;
      callbacks: MenuShellCallbacks = MenuShellCallbacks()) =
    r.clearChildren(container)
    let shell = renderMenuShell(r, model, callbacks)
    let shellNode = isonim_dom.Node(shell)
    let containerNode = isonim_dom.Node(container)
    # NB: only the shell's *children* are moved into the caller's host; this
    # wrapper is discarded.  A class set on it never reaches the document, so
    # the caption-bar host classes are owned by `ui/menu.nim` instead — it also
    # has to track fullscreen, which no render pass knows about.
    while not isonim_dom.isNodeNil(shellNode.firstChild):
      discard isonim_dom.appendChild(containerNode, shellNode.firstChild)
