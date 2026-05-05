from std / dom import Document
import
  ui_imports, debug, command

proc closeMenu(self: MenuComponent)

when defined(js):
  proc requestMenuRender*(self: MenuComponent)

when defined(js):
  import isonim/web/web_renderer
  from isonim/web/dom_api import nil
  from ../viewmodel/views/isonim_menu_shell_view import
    MenuNestedRecord, MenuNodeRecord, MenuNodeRecordKind, MenuRecordElement,
    MenuRecordFolder, MenuSearchResultRecord, MenuShellCallbacks,
    MenuShellModel, NavigationMenuId, renderMenuShellInto

  proc isWindowMaximizedForMenu(): bool {.importjs: "(window.outerWidth == screen.availWidth) && (window.outerHeight == screen.availHeight)".} =
    false

  var documentMenuDismissWired = false
  var activeMenuComponentForDismiss: MenuComponent

  proc handleDocumentMenuMouseDown(ev: dom_api.Event) =
    var insideMenu = false
    {.emit: """
      const target = `ev`.target;
      `insideMenu` = !!(target && target.closest &&
        target.closest('#navigation-menu, #menu-main, .menu-nested-elements'));
    """.}
    if not insideMenu and not activeMenuComponentForDismiss.isNil and
        activeMenuComponentForDismiss.active:
      activeMenuComponentForDismiss.active = false
      activeMenuComponentForDismiss.closeMenu()
      activeMenuComponentForDismiss.data.redraw()
      activeMenuComponentForDismiss.requestMenuRender()

const FONT_UPPERCASE_WIDTH_FACTOR = 1.5

proc seqIsNil[T](s: seq[T]): bool {.importjs: "(# == null)".}

proc menuNodeChildren(node: MenuNode): seq[MenuNode] =
  if node.isNil or seqIsNil(node.elements):
    @[]
  else:
    node.elements

proc enterElement*(self: MenuComponent, node: MenuNode)

proc runAction*(self: MenuComponent, action: ClientActionHandler, actionData: JsObject = nil)

proc closeMenu(self: MenuComponent) =
  self.activePath = @[]
  self.activePathWidths = JsAssoc[int, int]{}
  self.activePathOffsets = JsAssoc[int, int]{}
  self.activeIndex = 0
  self.activeLength = 0
  self.searchResults = @[]
  self.activeSearchIndex = 0
  self.searchQuery = cstring""

proc openMainMenu(self: MenuComponent) =
  self.data.focusComponent(self)
  self.activeIndex = 0
  self.activeLength = menuNodeChildren(self.data.ui.menuNode).len
  self.activePath = @[]
  self.activePathWidths = JsAssoc[int, int]{}
  self.activePathOffsets = JsAssoc[int, int]{}

proc loadShortcut*(action: ClientAction, config: Config): cstring =
  # load a shortcut for this node from config
  # if we update config it should effect it
  result = cstring""

  for index, shortcutValue in config.shortcutMap.actionShortcuts[action]:
    var shortcutName = shortcutValue.renderer.toUpperCase()

    if shortcutName == "CTRL+PAGEUP":
      shortcutName = "CTRL+PGUP"
    elif shortcutName == "CTRL+PAGEDOWN":
      shortcutName = "CTRL+PGDN"

    if index == 0:
      result = result & shortcutName
    else:
      result = result & cstring" " & shortcutName

proc iconClass(name: cstring): cstring =
  ui_imports.jslib.join(name.toLowerCase().split(" "), "-")

proc nodeAtPath(self: MenuComponent; path: seq[int]): MenuNode =
  result = self.data.ui.menuNode
  for index in path:
    let elements = menuNodeChildren(result)
    if index < 0 or index >= elements.len:
      return nil
    result = elements[index]

proc parentNodeAtPath(self: MenuComponent; path: seq[int]): MenuNode =
  result = self.data.ui.menuNode
  if path.len == 0:
    return
  for index in path[0 ..< path.len - 1]:
    let elements = menuNodeChildren(result)
    if index < 0 or index >= elements.len:
      return nil
    result = elements[index]

proc enterFolder*(self: MenuComponent) =
  var node = self.data.ui.menuNode

  for index in self.activePath:
    let elements = menuNodeChildren(node)
    if index < 0 or index >= elements.len:
      return
    node = elements[index]

  let elements = menuNodeChildren(node)
  if self.activeIndex < 0 or self.activeIndex >= elements.len:
    return
  var enteredNode = elements[self.activeIndex]

  if enteredNode.enabled and enteredNode.kind == MenuFolder:
    self.activePath.add(self.activeIndex)
    self.activeIndex = 0
    self.activeLength = menuNodeChildren(enteredNode).len
    self.data.redraw()

proc closeFolder*(self: MenuComponent) =
  if self.activePath.len > 0:
    self.activeIndex = self.activePath.pop()

    var node = self.data.ui.menuNode

    for index in self.activePath:
      let elements = menuNodeChildren(node)
      if index < 0 or index >= elements.len:
        self.activeLength = 0
        self.data.redraw()
        return
      node = elements[index]

    self.activeLength = menuNodeChildren(node).len
    self.data.redraw()

proc runAction*(self: MenuComponent, action: ClientActionHandler, actionData: JsObject = nil) =
  if not action.isNil:
    action(actionData)
    self.active = false
    self.closeMenu()

proc enterElement*(self: MenuComponent, node: MenuNode) =
  if node.enabled:
    var action = self.data.actions[node.action]
    self.runAction(action, node.actionData)

proc enterElement*(self: MenuComponent) =
  var enteredNode: MenuNode

  if self.searchResults.len == 0:
    var node = self.data.ui.menuNode

    for index in self.activePath:
      let elements = menuNodeChildren(node)
      if index < 0 or index >= elements.len:
        return
      node = elements[index]

    enteredNode = node

    if enteredNode.kind == MenuFolder:
      let elements = menuNodeChildren(enteredNode)
      if self.activeIndex < 0 or self.activeIndex >= elements.len:
        return
      enteredNode = elements[self.activeIndex]

    if enteredNode.enabled and enteredNode.kind == MenuElement:
      self.enterElement(enteredNode)
      self.data.redraw()
  else:
    let action = self.data.actions[self.nameMap[self.searchResults[self.activeSearchIndex]]]
    self.runAction(action)
    self.data.redraw()

method onUp*(self: MenuComponent) {.async.} =
  self.keyNavigation = true

  if self.searchResults.len == 0:
    if self.activeIndex > 0:
      self.activeIndex -= 1
  else:
    if self.activeSearchIndex > 0:
      self.activeSearchIndex -= 1

  self.data.redraw()

method onDown*(self: MenuComponent) {.async.} =
  self.keyNavigation = true

  if self.searchResults.len == 0:
    if self.activeIndex < self.activeLength - 1:
      self.activeIndex += 1
  else:
    if self.activeSearchIndex < self.searchResults.len:
      self.activeSearchIndex += 1

  self.data.redraw()

method onRight*(self: MenuComponent) {.async.} =
  self.keyNavigation = true
  enterFolder(self)

method onLeft*(self: MenuComponent) {.async.} =
  self.keyNavigation = true
  closeFolder(self)

method onEnter*(self: MenuComponent) {.async.} =
  self.enterElement()

method onEscape*(self: MenuComponent) {.async.} =
  self.closeFolder()

proc countSeparators(node: MenuNode, i: int): int =
  for index, n in menuNodeChildren(node):
    if index >= i:
      break
    if n.isBeforeNextSubGroup:
      result += 1

# let MENU_FUZZY_OPTIONS = FuzzyOptions(
#   limit: 20,
#   allowTypo: true,
#   threshold: -10000)

proc toggle*(self: MenuComponent) =
  if self.active:
    self.closeMenu()
  else:
    self.openMainMenu()

  self.active = not self.active
  self.data.redraw()

proc calculateMaxMenuElementWidth(self: MenuComponent, currentMenuNode: MenuNode): tuple[name, shortcut: int] =
  var maxNameWidth = 0
  var maxShortcutWidth = 0
  # calculate max name and shortcut for current menu
  for node in menuNodeChildren(currentMenuNode):
    let commandWidth = node.name.len
    if commandWidth > maxNameWidth:
      maxNameWidth = commandWidth

    let shortcut =
      if node.kind == MenuFolder:
        cstring""
      else:
        loadShortcut(node.action, self.data.config)
    let shortcutWidth =
      Math.ceil((shortcut.len).float * FONT_UPPERCASE_WIDTH_FACTOR)

    if shortcutWidth > maxShortcutWidth:
      maxShortcutWidth = shortcutWidth

  maxNameWidth += 1

  if maxShortcutWidth < 2: maxShortcutWidth = 2

  return (name: maxNameWidth, shortcut: maxShortcutWidth)

proc prepareSearch*(node: MenuNode): seq[js] =
  result = @[]
  if node.isNil or not node.enabled:
    return
  if node.kind == MenuFolder:
    for element in menuNodeChildren(node):
      result = result.concat(prepareSearch(element))
  else:
    result = @[fuzzysort.prepare(node.name)]

proc generateNameMap*(node: MenuNode, res: JsAssoc[cstring, ClientAction] = nil): JsAssoc[cstring, ClientAction] =
  if res.isNil:
    result = JsAssoc[cstring, ClientAction]{}
  else:
    result = res
  if node.isNil or not node.enabled:
    return
  if node.kind == MenuFolder:
    for element in menuNodeChildren(node):
      discard generateNameMap(element, result)
  else:
    result[node.name] = node.action
    if not res.isNil:
      res[node.name] = node.action

when defined(js):
  proc shouldRenderMenuNode(node: MenuNode): bool =
    if ui_imports.electron_lib.inElectron:
      not cast[bool]((node.menuOs and ord(MenuNodeOSHost)) or
        (node.menuOs and ord(MenuNodeOSMacOS)))
    else:
      not cast[bool]((node.menuOs and ord(MenuNodeOSNonHost)) or
        (node.menuOs and ord(MenuNodeOSMacOS)))

  proc activeNodeClass(self: MenuComponent; path: seq[int]): string =
    if path.len == 0:
      return ""
    let depth = path.len - 1
    let index = path[^1]
    if (self.activePath.len == depth and self.activeIndex == index) or
        (self.activePath.len > 0 and self.activePath.len != depth and
          depth < self.activePath.len and self.activePath[depth] == index):
      "menu-active-node"
    else:
      ""

  proc menuRecord(
      self: MenuComponent;
      node: MenuNode;
      path: seq[int];
      nameWidth: int;
      shortcutWidth: int): MenuNodeRecord =
    let nodeKind =
      if node.kind == MenuElement: MenuRecordElement else: MenuRecordFolder
    let shortcut =
      if node.kind == MenuElement: $loadShortcut(node.action, self.data.config)
      else: ""
    let recordNameClass =
      if node.kind == MenuElement:
        "menu-element-" & $convertStringToHtmlClass(node.name)
      else:
        "menu-folder-" & $convertStringToHtmlClass(node.name)
    let folderItemWidth =
      if node.kind == MenuFolder:
        nameWidth + shortcutWidth - self.folderArrowCharWidth
      else:
        nameWidth

    result = MenuNodeRecord(
      kind: nodeKind,
      name: $node.name,
      shortcut: shortcut,
      enabled: node.enabled,
      iconClass: $iconClass(node.name),
      nameClass: recordNameClass,
      nodeClass: self.activeNodeClass(path),
      path: path,
      nameWidth: folderItemWidth,
      beforeNextSubGroup: node.isBeforeNextSubGroup,
      children: @[])
    if node.kind == MenuFolder:
      for childIndex, child in menuNodeChildren(node):
        if child.shouldRenderMenuNode():
          let childWidths = self.calculateMaxMenuElementWidth(node)
          result.children.add(self.menuRecord(
            child,
            path & @[childIndex],
            childWidths.name,
            childWidths.shortcut))

  proc menuRecordsForNode(
      self: MenuComponent;
      node: MenuNode;
      pathPrefix: seq[int]): seq[MenuNodeRecord] =
    result = @[]
    let widths = self.calculateMaxMenuElementWidth(node)
    for index, child in menuNodeChildren(node):
      if child.shouldRenderMenuNode():
        result.add(self.menuRecord(
          child,
          pathPrefix & @[index],
          widths.name,
          widths.shortcut))

  proc nestedStyleString(self: MenuComponent; value: int; depth: int;
                         separators: int; width: int): string =
    var left = cast[int](jq("#menu-main").toJs.clientWidth)

    if depth != 1:
      for i in 1..<depth:
        left += cast[int](jq(cstring(fmt"#menu-nested-elements-{i}")).toJs.clientWidth)

    fmt"top: {value * 28 + separators * 28 - 56}px; left: calc({left}px + {2 * depth}px)"

  proc buildMenuShellModel(self: MenuComponent): MenuShellModel =
    result.rootNodes = @[]
    result.searchResults = @[]
    result.nestedMenus = @[]

    if not self.data.ui.menuNode.isNil and not self.data.isNil:
      self.prepared = prepareSearch(self.data.ui.menuNode)
      self.nameMap = generateNameMap(self.data.ui.menuNode)

    result.showNavigation = not self.data.ui.menuNode.isNil and not defined(ctmacos)
    result.active = self.active
    result.searchQuery =
      if self.searchQuery.isNil: ""
      else: $self.searchQuery
    result.showWindowMenu = ui_imports.electron_lib.inElectron and not defined(ctmacos)
    result.maximized = isWindowMaximizedForMenu()

    if self.data.ui.menuNode.isNil:
      return

    let menu = self.data.ui.menuNode
    result.rootNodes = self.menuRecordsForNode(menu, @[])

    for index, res in self.searchResults:
      result.searchResults.add(MenuSearchResultRecord(
        label: $res,
        shortcut: $loadShortcut(self.nameMap[res], self.data.config),
        iconClass: $iconClass(res),
        active: self.activeSearchIndex == index))

    var current = menu
    var sum = 0
    for depth, index in self.activePath:
      let currentElements = menuNodeChildren(current)
      if current.isNil or index < 0 or index >= currentElements.len:
        break
      var separators = countSeparators(current, index)
      current = currentElements[index]
      sum += index
      separators += 1

      let widths = self.calculateMaxMenuElementWidth(current)
      let submenuWidth = widths.name + widths.shortcut
      self.activePathWidths[depth + 1] = submenuWidth
      self.activePathOffsets[depth + 1] =
        self.activePathOffsets[depth] + self.activePathWidths[depth]

      result.nestedMenus.add(MenuNestedRecord(
        id: fmt"menu-nested-elements-{depth + 1}",
        className: fmt"menu-nested-elements menu-top-{sum} {separators}",
        style: self.nestedStyleString(sum, depth + 1, separators, submenuWidth),
        nodes: self.menuRecordsForNode(current, self.activePath[0 .. depth])))

  proc handleNodeMouseOver(self: MenuComponent; path: seq[int]) =
    let node = self.nodeAtPath(path)
    let parent = self.parentNodeAtPath(path)
    if node.isNil or parent.isNil or path.len == 0:
      return

    let depth = path.len - 1
    let index = path[^1]
    let previousActivePath = self.activePath
    let previousActiveIndex = self.activeIndex
    let previousActiveLength = self.activeLength
    self.keyNavigation = false
    if node.kind == MenuElement:
      self.activeIndex = index
      self.activePath.setLen(depth + 1)
      if self.activePath[depth] != index:
        self.activePath[depth] = index
    else:
      if node.enabled:
        let elements = menuNodeChildren(node)
        if elements.len > 0:
          self.activePath.setLen(depth + 1)
          self.activeIndex = 0
          self.activeLength = elements.len
          if self.activePath[depth] != index:
            self.activePath[depth] = index

    if self.activePath != previousActivePath or
        self.activeIndex != previousActiveIndex or
        self.activeLength != previousActiveLength:
      self.requestMenuRender()

  proc handleNodeClick(self: MenuComponent; path: seq[int]) =
    let node = self.nodeAtPath(path)
    if not node.isNil:
      self.enterElement(node)
      self.requestMenuRender()

  proc handleSearchResultClick(self: MenuComponent; index: int) =
    if index >= 0 and index < self.searchResults.len:
      let action = self.data.actions[self.nameMap[self.searchResults[index]]]
      self.runAction(action)
      self.requestMenuRender()

  proc wireMenuKeyboard(container: dom_api.Element; self: MenuComponent) =
    activeMenuComponentForDismiss = self
    if not documentMenuDismissWired:
      documentMenuDismissWired = true
      {.emit: """
        document.addEventListener('mousedown', function(ev) {
          `handleDocumentMenuMouseDown`(ev);
        }, true);
      """.}

    let nav = dom_api.getElementById(dom_api.document, cstring NavigationMenuId)
    if dom_api.isNodeNil(dom_api.Node(nav)):
      return
    dom_api.addEventListener(dom_api.Node(nav), cstring"keydown",
      proc(ev: dom_api.Event) =
        var keyCode: int
        {.emit: "`keyCode` = `ev`.keyCode || 0;".}
        if keyCode == ESC_KEY_CODE:
          self.active = false
          self.closeMenu()
          self.data.redraw())

    let main = dom_api.getElementById(dom_api.document, cstring"menu-main")
    if not dom_api.isNodeNil(dom_api.Node(main)):
      dom_api.addEventListener(dom_api.Node(main), cstring"mousedown",
        proc(ev: dom_api.Event) =
          {.emit: "`ev`.stopPropagation();".})
      dom_api.addEventListener(dom_api.Node(main), cstring"mouseover",
        proc(ev: dom_api.Event) =
          {.emit: "`ev`.stopPropagation();".})

  proc requestMenuRender*(self: MenuComponent) =
    ## Refresh the global menu host directly through IsoNim.
    ##
    ## This replaces the old shared ``#menu`` Karax ``setRenderer`` island.
    ## The deeper menu state and action callbacks remain on ``MenuComponent``.
    if self.isNil:
      return
    let container = dom_api.getElementById(dom_api.document, cstring"menu")
    if dom_api.isNodeNil(dom_api.Node(container)):
      return

    proc focusNavigationSoon() =
      discard setTimeout(proc() =
        let nav = dom_api.getElementById(
          dom_api.document,
          cstring NavigationMenuId)
        if not dom_api.isNodeNil(dom_api.Node(nav)):
          {.emit: "`nav`.focus();".},
        10)

    let model = self.buildMenuShellModel()
    let callbacks = MenuShellCallbacks(
      onToggleMenu: proc() =
        self.toggle()
        focusNavigationSoon(),
      onNavBlur: proc() =
        discard,
      onNavMouseDown: proc() =
        self.activeDomElement =
          cast[dom.Node](dom.window.document.activeElement),
      onMainMouseOver: proc() =
        self.search = false,
      onNodeMouseOver: proc(path: seq[int]) =
        self.handleNodeMouseOver(path),
      onNodeClick: proc(path: seq[int]) =
        self.handleNodeClick(path),
      onSearchResultClick: proc(index: int) =
        self.handleSearchResultClick(index),
      onMinimizeWindow: proc() =
        self.data.ipc.send("CODETRACER::minimize-window"),
      onMaximizeWindow: proc() =
        self.data.ipc.send("CODETRACER::maximize-window"),
      onRestoreWindow: proc() =
        self.data.ipc.send("CODETRACER::restore-window"),
      onCloseWindow: proc() =
        self.data.ipc.send("CODETRACER::close-app"))

    let r = WebRenderer()
    renderMenuShellInto(r, container, model, callbacks)
    {.emit: """
      if (window.__ctRequestSessionTabsRender) {
        window.setTimeout(window.__ctRequestSessionTabsRender, 0);
      }
    """.}
    if not self.data.startOptions.shellUi:
      self.debug.requestDebugShellRender()
      if not self.data.ui.commandPalette.isNil:
        self.data.ui.commandPalette.requestCommandPalettePanelRefresh()
      self.debug.requestDebugControlsRender()
    wireMenuKeyboard(container, self)
