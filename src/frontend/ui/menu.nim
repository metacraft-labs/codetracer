from std / dom import Document
import ui_imports, ../ui_helpers, debug

const FONT_UPPERCASE_WIDTH_FACTOR = 1.5

proc enterElement*(self: MenuComponent, node: MenuNode)

proc runAction*(self: MenuComponent, action: proc: void)

proc closeMenu(self: MenuComponent) =
  self.activePath = @[]
  self.activePathWidths = JsAssoc[int, int]{}
  self.activePathOffsets = JsAssoc[int, int]{}
  self.activeIndex = 0
  self.activeLength = 0
  self.searchResults = @[]
  self.activeSearchIndex = 0
  self.searchQuery = j""

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
    (StyleAttr.top, cstring(fmt"{value * 28 + separators * 28 - 28}px")),
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
      result = result & j" " & shortcutName

proc iconClass(name: cstring): cstring =
  ui_imports.lib.join(name.toLowerCase().split(" "), "-")

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
      j"menu-active-node"
    else:
      j""

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
        j"menu-active-search-result"
      else:
        j""
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

proc runAction*(self: MenuComponent, action: proc: void) =
  if not action.isNil:
    action()
    self.active = false
    self.closeMenu()

proc enterElement*(self: MenuComponent, node: MenuNode) =
  if node.enabled:
    var action = self.data.actions[node.action]
    self.runAction(action)

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
        j""
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

  # proc search(value: cstring) {.async.} =
  #   self.searchQuery = value
  #   self.data.redraw()
  #   jq("#menu-search-text").focus()

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
      onclick = proc (ev: Event, tg: VNode) =
        ev.stopPropagation()
        toggle(self)
        discard setTimeout(proc() = jq("#navigation-menu").focus(), 10)):
      tdiv(id="menu-root-logo"):
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
              menuNodeView(
                self,
                element,
                i,
                0,
                menu.elements.len,
                nameAndShortcutWidths.name,
                nameAndShortcutWidths.shortcut)
          # For now disable search input
          # tdiv(
          #   id="menu-search",
          #   onmousedown = proc(ev: Event, tg: VNode) =
          #     ev.stopPropagation()
          #     self.search = true
          #     self.openMainMenu()):
          #   input(
          #     id="menu-search-text",
          #     `type`="text",
          #     placeholder="Search menu",
          #     onkeydown = proc(e: KeyboardEvent, v: VNode) =
          #       # self.openMainMenu()
          #       if e.keyCode == UP_KEY_CODE:
          #         discard self.onUp()
          #       elif e.keyCode == DOWN_KEY_CODE:
          #         discard self.onDown()
          #       elif e.keyCode == ENTER_KEY_CODE:
          #         discard self.onEnter()
          #       elif e.keyCode == ESC_KEY_CODE:
          #         document.toJs.activeElement.blur(),
          #     oninput = proc(e: Event, v: VNode) =
          #         # echo e.keyCode
          #         # TODO learn about target coming from right place?
          #       let value = jq("#menu-search-text").toJs.value.to(cstring)
          #       discard search(value))
            # span(class="menu-search-icon", onclick = proc =
            #   let value = jq("#menu-search-text").toJs.value.to(cstring)
            #   discard search(value)):
            #   fa "search"

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


method render*(self: MenuComponent): VNode =
  if not self.data.ui.menuNode.isNil and
    not self.data.isNil:
      self.prepared = prepareSearch(self.data.ui.menuNode)
      self.nameMap = generateNameMap(self.data.ui.menuNode)
  buildHtml(tdiv()):
    if not self.data.ui.menuNode.isNil:
      navigationMenuView(self)

    if not self.data.startOptions.shellUi:
      let debug = self.debug.render()
      debug

    windowMenu(self.data)


