## IsoNim view for the global menu shell.
##
## State derivation and legacy menu actions stay in ``ui/menu.nim``.  This view
## owns the shared ``#menu`` host structure so the global menu chrome no longer
## needs a Karax ``setRenderer`` registration.

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
  NavigationMenuId* = "navigation-menu"
  MenuRootId* = "menu-root"
  MenuMainId* = "menu-main"
  MenuElementsId* = "menu-elements"
  MenuSearchResultsId* = "menu-search-results"
  WindowMenuClass* = "window-menu"

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

template renderMenuShellImpl(
    r: untyped;
    model: MenuShellModel;
    callbacks: MenuShellCallbacks): untyped =
  ui(r):
    tdiv(class = MenuShellRootClass):
      if model.showNavigation:
        tdiv(
            id = NavigationMenuId,
            tabindex = "0",
            onblur = proc() = callbacks.invokeNavBlur(),
            onmousedown = proc() = callbacks.invokeNavMouseDown()):
          tdiv(
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
                          onclick = proc() =
                            callbacks.invokeSearchResult(currentSearchIndex)):
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
                    tdiv(class = "menu-node-container " & node.nodeClass):
                      if node.kind == MenuRecordElement:
                        tdiv(
                            id = "menu-element-" & $node.path.len & " " & $node.path[^1],
                            class = "menu-element menu-node " &
                              (if node.enabled: "menu-enabled" else: "menu-disabled"),
                            onmouseover = proc() = callbacks.invokeNodeMouseOver(node.path),
                            onclick = proc() = callbacks.invokeNodeClick(node.path)):
                          span(class = "menu-node-icon"):
                            text ""
                          span(
                              class = "menu-node-name " & node.nameClass,
                              style = "width: " & $node.nameWidth & "ch"):
                            text node.name
                          if node.shortcut.len > 0:
                            span(class = "menu-node-shortcut"):
                              text node.shortcut
                      else:
                        tdiv(
                            class = "menu-folder menu-node " &
                              (if node.enabled: "menu-enabled" else: "menu-disabled"),
                            onmouseover = proc() = callbacks.invokeNodeMouseOver(node.path)):
                          span(class = "menu-node-icon"):
                            tdiv(class = "icon " & node.iconClass):
                              discard
                          span(
                              class = "menu-node-name " & node.nameClass,
                              style = "width: " & $node.nameWidth & "ch"):
                            text node.name
                            if node.children.len > 0:
                              span(class = "menu-expand"):
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
                    tdiv(class = "menu-node-container " & node.nodeClass):
                      if node.kind == MenuRecordElement:
                        tdiv(
                            id = "menu-element-" & $node.path.len & " " & $node.path[^1],
                            class = "menu-element menu-node " &
                              (if node.enabled: "menu-enabled" else: "menu-disabled"),
                            onmouseover = proc() = callbacks.invokeNodeMouseOver(node.path),
                            onclick = proc() = callbacks.invokeNodeClick(node.path)):
                          span(class = "menu-node-icon"):
                            text ""
                          span(
                              class = "menu-node-name " & node.nameClass,
                              style = "width: " & $node.nameWidth & "ch"):
                            text node.name
                          if node.shortcut.len > 0:
                            span(class = "menu-node-shortcut"):
                              text node.shortcut
                      else:
                        tdiv(
                            class = "menu-folder menu-node " &
                              (if node.enabled: "menu-enabled" else: "menu-disabled"),
                            onmouseover = proc() = callbacks.invokeNodeMouseOver(node.path)):
                          span(class = "menu-node-icon"):
                            tdiv(class = "icon " & node.iconClass):
                              discard
                          span(
                              class = "menu-node-name " & node.nameClass,
                              style = "width: " & $node.nameWidth & "ch"):
                            text node.name
                            if node.children.len > 0:
                              span(class = "menu-expand"):
                                discard
                      if node.beforeNextSubGroup:
                        hr(class = "menu-sub-group-separator"):
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
    while not isonim_dom.isNodeNil(shellNode.firstChild):
      discard isonim_dom.appendChild(containerNode, shellNode.firstChild)
