from std / dom import Document
import
  ui_imports, debug

when defined(js):
  import isonim/web/web_renderer
  from isonim/web/dom_api import nil
  from ../viewmodel/views/isonim_menu_shell_view import
    MenuNestedRecord, MenuNodeRecord, MenuNodeRecordKind, MenuRecordElement,
    MenuRecordFolder, MenuSearchResultRecord, MenuShellCallbacks,
    MenuShellModel, NavigationMenuId, renderMenuShellInto

  proc isWindowMaximizedForMenu(): bool {.importjs: "(window.outerWidth == screen.availWidth) && (window.outerHeight == screen.availHeight)".} =
    false

const FONT_UPPERCASE_WIDTH_FACTOR = 1.5

proc enterElement*(self: MenuComponent, node: MenuNode)

proc runAction*(self: MenuComponent, action: ClientActionHandler, actionData: JsObject = nil)

when defined(js):
  proc requestMenuRender*(self: MenuComponent)

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
  self.activeLength = self.data.ui.menuNode.elements.len
  self.activePath = @[]
  self.activePathWidths = JsAssoc[int, int]{}
  self.activePathOffsets = JsAssoc[int, int]{}

proc menuNestedStyle*(self: MenuComponent, value: int, depth: int, separators: int, width: int): VStyle =
  var left = cast[int](jq("#menu-main").toJs.clientWidth)

  if depth != 1:
    for i in 1..<depth:
      left += cast[int](jq(cstring(fmt"#menu-nested-elements-{i}")).toJs.clientWidth)

  result = style(
    (StyleAttr.top, cstring(fmt"{value * 28 + separators * 28 - 56}px")),
    (StyleAttr.left, cstring(fmt"calc({left}px + {2 * depth}px)"))
  )

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
    if result.isNil or index < 0 or index >= result.elements.len:
      return nil
    result = result.elements[index]

proc parentNodeAtPath(self: MenuComponent; path: seq[int]): MenuNode =
  result = self.data.ui.menuNode
  if path.len == 0:
    return
  for index in path[0 ..< path.len - 1]:
    if result.isNil or index < 0 or index >= result.elements.len:
      return nil
    result = result.elements[index]

proc menuElementView*(
  self: MenuComponent,
  node: MenuNode,
  i: int,
  depth: int,
  nameWidth: int,
  shortcutWidth: int): VNode =

  let enabledClass = if node.enabled: "menu-enabled" else: "menu-disabled"
  let shortcut = loadShortcut(node.action, self.data.config)

  buildHtml(
    tdiv(
      id = cstring(fmt"menu-element-{depth} {i}"),
      class = cstring(fmt"menu-element menu-node {enabledClass}"),
      onmouseover = proc =
        if not self.keyNavigation:
          self.activeIndex = i
          self.activePath.setLen(depth + 1)

          if self.activePath[depth] != i:
              self.activePath[depth] = i

        if self.keyNavigation and (self.activeIndex != i or (self.activePath.len() > 1 and self.activePath[^1] != i)):
          self.keyNavigation = false

        self.data.redraw(),
      onclick = proc =
        self.enterElement(node)
    )
  ):
    span(class = "menu-node-icon"):
      text ""
    span(class = cstring(fmt"menu-node-name menu-element-{convertStringToHtmlClass(node.name)}"),
         style = style(StyleAttr.width, cstring(fmt"{nameWidth}ch"))):
      text node.name
    if shortcut != "":
      span(class = "menu-node-shortcut"):
        text shortcut

proc menuFolderView*(
  self: MenuComponent,
  node: MenuNode,
  i: int,
  depth: int,
  parentLength: int,
  nameWidth: int
): VNode =
  let enabledClass = if node.enabled: "menu-enabled" else: "menu-disabled"

  buildHtml(
    tdiv(
      class = cstring(fmt"menu-folder menu-node {enabledClass}"),
      onmouseover = proc =
        if node.enabled and not self.keyNavigation:
          if node.elements.len > 0:
            self.activePath.setLen(depth + 1)
            self.activeIndex = 0
            self.activeLength = node.elements.len

            if self.activePath[depth] != i:
              self.activePath[depth] = i

        if self.keyNavigation and (self.activeIndex != i or (self.activePath.len() > 1 and self.activePath[^1] != i)):
          self.keyNavigation = false

        self.data.redraw()
    )
  ):
    span(class = "menu-node-icon"):
      tdiv(class = "icon " & iconClass(node.name))
    span(class = cstring(fmt"menu-node-name menu-folder-{convertStringToHtmlClass(node.name)}"),
         style = style(StyleAttr.width, cstring(fmt"{nameWidth}ch"))):
      text node.name
      if node.elements.len > 0:
        span(class = "menu-expand")

proc menuSubGroupSeparatorView*(self: MenuComponent): VNode =
  buildHtml(hr(class = "menu-sub-group-separator"))

proc menuNodeView*(
  self: MenuComponent,
  node: MenuNode,
  i: int,
  depth: int,
  parentLength: int,
  nameWidth: int,
  shortcutWidth: int
): VNode =
  let activeNode =
    if (self.activePath.len == depth and self.activeIndex == i) or
        (self.activePath.len() > 0 and self.activePath.len() != depth and self.activePath[depth] == i):
      cstring"menu-active-node"
    else:
      cstring""

  buildHtml(tdiv(class = "menu-node-container " & activeNode)):
    if node.kind == MenuElement:
      menuElementView(self, node, i, depth, nameWidth, shortcutWidth)
    else:
      let folderItemWidth = nameWidth + shortcutWidth - self.folderArrowCharWidth
      menuFolderView(self, node, i, depth, parentLength, folderItemWidth)
    if node.isBeforeNextSubGroup:
      menuSubGroupSeparatorView(self)

proc menuSearchResultView*(self: MenuComponent, res: cstring, i: int): VNode =
  result = buildHtml(
    tdiv(
      class = "menu-search-result",
      onclick = proc =
        var action = self.data.actions[self.nameMap[res]]
        self.runAction(action)
    )
  ):
    let shortcut = loadShortcut(self.nameMap[res], self.data.config)
    let activeSearchResult =
      if self.activeSearchIndex == i:
        cstring"menu-active-search-result"
      else:
        cstring""
    tdiv(class = "menu-node-icon"):
      tdiv(class = "icon " & iconClass(res))
    span(class = "menu-node-name " & activeSearchResult):
      text res
    span(class = "menu-node-shortcut"):
      text shortcut

proc enterFolder*(self: MenuComponent) =
  var node = self.data.ui.menuNode

  for index in self.activePath:
    node = node.elements[index]

  var enteredNode = node.elements[self.activeIndex]

  if enteredNode.enabled and enteredNode.kind == MenuFolder:
    self.activePath.add(self.activeIndex)
    self.activeIndex = 0
    self.activeLength = enteredNode.elements.len
    self.data.redraw()

proc closeFolder*(self: MenuComponent) =
  if self.activePath.len > 0:
    self.activeIndex = self.activePath.pop()

    var node = self.data.ui.menuNode

    for index in self.activePath:
      node = node.elements[index]

    self.activeLength = node.elements.len
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
      node = node.elements[index]

    enteredNode = node

    if enteredNode.kind == MenuFolder:
      enteredNode = enteredNode.elements[self.activeIndex]

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
  for index, n in node.elements:
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
  for node in currentMenuNode.elements:
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

proc navigationMenuView*(self: MenuComponent): VNode =
  let menu = self.data.ui.menuNode

  result = buildHtml(
    tdiv(
      id = "navigation-menu",
      tabindex = "0",
      onblur = proc =
        if not self.search:
          self.active = false
          self.closeMenu()
          redrawAll(),
      onkeydown = proc(e: KeyboardEvent, tg: VNode) =
        if e.keyCode == ESC_KEY_CODE:
          self.active = false
          self.closeMenu()
          redrawAll(),
      onmousedown = proc =
        self.activeDomElement = cast[dom.Node](dom.window.document.activeElement)
    )
  ):
    tdiv(
      id = "menu-root",
      onclick = proc =
        toggle(self)
        discard setTimeout(proc() = jq("#navigation-menu").focus(), 10)):
      tdiv(id="menu-logo-img")

    if self.active:
      tdiv(
        id="menu-main",
        onmousedown = proc(ev: Event, tg: VNode) =
          ev.stopPropagation(),
        onmouseover = proc(ev: Event, tg: VNode) =
          ev.stopPropagation()
          self.search = false
          ev.currentTarget.parentNode.focus()):
        tdiv(id="menu-search-results"):
          if self.searchQuery.len > 0:
            if self.searchResults.len == 0:
              tdiv(class="menu-no-search-results"):
                text "No results found"
            else:
              for i, res in self.searchResults:
                menuSearchResultView(self, res, i)
        tdiv(id="menu-elements"):
          if self.searchQuery.len == 0:
            let nameAndShortcutWidths =
                self.calculateMaxMenuElementWidth(menu)
            var mainMenuWidth =
              nameAndShortcutWidths.name + nameAndShortcutWidths.shortcut

            self.activePathWidths[0] = mainMenuWidth
            self.activePathOffsets[0] = 0

            for i, element in menu.elements:
              var shouldRender = false
              if ui_imports.electron_lib.inElectron:
                if not cast[bool]((element.menuOs and ord(MenuNodeOSHost)) or (element.menuOs and ord(MenuNodeOSMacOS))):
                  shouldRender = true
              else:
                if not cast[bool]((element.menuOs and ord(MenuNodeOSNonHost)) or (element.menuOs and ord(MenuNodeOSMacOS))):
                  shouldRender = true

              if shouldRender:
                menuNodeView(
                  self,
                  element,
                  i,
                  0,
                  menu.elements.len,
                  nameAndShortcutWidths.name,
                  nameAndShortcutWidths.shortcut)

        var current = menu
        var sum = 0
        for depth, i in self.activePath:
          var separators = countSeparators(current, i)
          current = current.elements[i]
          sum += i
          separators += 1

          let nameAndShortcutWidths =
            self.calculateMaxMenuElementWidth(current)
          let submenuWidth =
            nameAndShortcutWidths.name + nameAndShortcutWidths.shortcut
          self.activePathWidths[depth + 1] = submenuWidth
          self.activePathOffsets[depth + 1] =
            self.activePathOffsets[depth] + self.activePathWidths[depth]

          tdiv(
            class = cstring(fmt"menu-nested-elements menu-top-{sum} {separators}"),
            id = cstring(fmt"menu-nested-elements-{depth + 1}"),
            style = menuNestedStyle(self, sum, depth + 1, separators, submenuWidth)
          ):
            for i2, element in current.elements:
              var shouldRender = false
              if ui_imports.electron_lib.inElectron:
                if not cast[bool]((element.menuOs and ord(MenuNodeOSHost)) or (element.menuOs and ord(MenuNodeOSMacOS))):
                  shouldRender = true
              else:
                if not cast[bool]((element.menuOs and ord(MenuNodeOSNonHost)) or (element.menuOs and ord(MenuNodeOSMacOS))):
                  shouldRender = true

              if shouldRender:
                menuNodeView(
                  self,
                  element,
                  i2,
                  depth + 1,
                  current.elements.len,
                  nameAndShortcutWidths.name,
                  nameAndShortcutWidths.shortcut)

proc prepareSearch*(node: MenuNode): seq[js] =
  result = @[]
  if not node.enabled:
    return
  if node.kind == MenuFolder:
    for element in node.elements:
      result = result.concat(prepareSearch(element))
  else:
    result = @[fuzzysort.prepare(node.name)]

proc generateNameMap*(node: MenuNode, res: JsAssoc[cstring, ClientAction] = nil): JsAssoc[cstring, ClientAction] =
  if res.isNil:
    result = JsAssoc[cstring, ClientAction]{}
  else:
    result = res
  if not node.enabled:
    return
  if node.kind == MenuFolder:
    for element in node.elements:
      discard generateNameMap(element, result)
  else:
    result[node.name] = node.action
    if not res.isNil:
      res[node.name] = node.action


proc renderMenu*(self: MenuComponent): VNode =
  ## Legacy Karax menu chrome renderer.
  ##
  ## The live shared ``#menu`` host is refreshed by ``requestMenuRender``.
  ## This compatibility proc is retained only for older call sites while the
  ## deeper menu-node helper procs above are retired in later slices.
  if not self.data.ui.menuNode.isNil and
    not self.data.isNil:
      self.prepared = prepareSearch(self.data.ui.menuNode)
      self.nameMap = generateNameMap(self.data.ui.menuNode)
  if not self.data.startOptions.shellUi:
    self.debug.kxi = self.kxi
    data.ui.commandPalette.kxi = self.kxi
    self.debug.requestDebugShellRender()
  buildHtml(tdiv()):
    if not self.data.ui.menuNode.isNil and not defined(ctmacos):
      navigationMenuView(self)

    windowMenu(self.data)

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
      beforeNextSubGroup: node.isBeforeNextSubGroup)
    if node.kind == MenuFolder:
      for childIndex, child in node.elements:
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
    let widths = self.calculateMaxMenuElementWidth(node)
    for index, child in node.elements:
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
    if not self.data.ui.menuNode.isNil and not self.data.isNil:
      self.prepared = prepareSearch(self.data.ui.menuNode)
      self.nameMap = generateNameMap(self.data.ui.menuNode)

    result.showNavigation = not self.data.ui.menuNode.isNil and not defined(ctmacos)
    result.active = self.active
    result.searchQuery = $self.searchQuery
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
      if current.isNil or index < 0 or index >= current.elements.len:
        break
      var separators = countSeparators(current, index)
      current = current.elements[index]
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
    if node.kind == MenuElement:
      if not self.keyNavigation:
        self.activeIndex = index
        self.activePath.setLen(depth + 1)
        if self.activePath[depth] != index:
          self.activePath[depth] = index
    else:
      if node.enabled and not self.keyNavigation:
        if node.elements.len > 0:
          self.activePath.setLen(depth + 1)
          self.activeIndex = 0
          self.activeLength = node.elements.len
          if self.activePath[depth] != index:
            self.activePath[depth] = index

    if self.keyNavigation and
        (self.activeIndex != index or
          (self.activePath.len() > 1 and self.activePath[^1] != index)):
      self.keyNavigation = false

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
    ## The deeper menu state and action callbacks remain on ``MenuComponent``;
    ## the next migration layer is to remove the remaining legacy VNode helper
    ## procs above once this direct shell has soaked.
    if self.isNil:
      return
    let container = dom_api.getElementById(dom_api.document, cstring"menu")
    if dom_api.isNodeNil(dom_api.Node(container)):
      return

    if not self.data.startOptions.shellUi:
      self.debug.requestDebugShellRender()

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
        if not self.search:
          self.active = false
          self.closeMenu()
          self.data.redraw(),
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
    wireMenuKeyboard(container, self)
