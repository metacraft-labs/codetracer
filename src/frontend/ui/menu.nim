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
    MenuShellModel, NavigationMenuId, captionBarHostClasses, renderMenuShellInto
  from menu_render_gate import
    MenuRenderGate, invalidate, menuRenderSignature, noteRendered, shouldRender

  var captionBarFullscreen = false
    ## Whether the window is in native fullscreen.  Owned here because no render
    ## pass knows about it: it changes from OS window events, not from state.

  proc applyCaptionBarWindowMode*() =
    ## Reconcile the caption-bar host (`#menu`) with the current window mode.
    ##
    ## Applied here rather than during a menu render because the wrapper the
    ## shell view builds is discarded by `renderMenuShellInto` — only its
    ## children survive — and because `ui/session_tabs.nim` renders the session
    ## tab bar into the same host independently of the shell.  On the welcome
    ## screen that tab bar is the only occupant, so a render-time hook would
    ## leave it sitting under the window buttons.
    let host = ui_imports.kdom.document.getElementById(cstring"menu")
    if host.isNil:
      return
    let existing = $host.getAttribute(cstring"class")
    host.setAttribute(
      cstring"class",
      cstring(captionBarHostClasses(
        existing,
        reserveWindowControls = defined(ctmacos),
        fullscreen = captionBarFullscreen)))

  proc setCaptionBarFullscreen*(fullscreen: bool) =
    ## Called from the `window-fullscreen-changed` IPC message that
    ## `index/window.nim` sends on the OS enter/leave-fullscreen events.
    if captionBarFullscreen == fullscreen:
      return
    captionBarFullscreen = fullscreen
    applyCaptionBarWindowMode()

  # Issue #555 — "Redraw issue on new file open".
  #
  # `requestMenuRender` is reached from `renderer.sharedDirectRedraw`, i.e.
  # from EVERY `data.redraw()` in the renderer, and it used to rebuild the
  # whole caption chrome each time.  `renderMenuShellInto` starts by clearing
  # the `#menu` host, and the shell view is what emits `#isonim-debug-controls`
  # and `#debug`, so each rebuild destroyed the mounted debug toolbar and
  # forced `ui/debug.nim` to mount a new one.  A trace open issues dozens of
  # redraws; the buttons blinked once per redraw.
  #
  # This gate remembers what was last committed and skips the teardown when
  # nothing the shell renders has changed.  See `ui/menu_render_gate.nim` and
  # `src/tests/gui/tests/session-chrome/menu_redraw_storm_test.nim`.
  var menuShellGate = MenuRenderGate()

  # `MenuComponent` is per ReplaySession (`session_switch.nim` builds one for
  # every session) while `#menu` is a single shared host, and the shell's
  # callbacks close over whichever component rendered it.  Two sessions can
  # easily produce the same menu signature, so the gate must additionally be
  # invalidated whenever the owning component changes — otherwise a session
  # switch would leave the previous session's click handlers wired up.
  var menuShellGateOwner: MenuComponent

  proc isWindowMaximizedForMenu(): bool {.importjs: "(window.outerWidth == screen.availWidth) && (window.outerHeight == screen.availHeight)".} =
    false
  proc eventTarget(ev: dom_api.Event): dom_api.Element {.importjs: "#.target".}
  proc closestElement(node: dom_api.Element; selector: cstring): dom_api.Element {.importjs: "#.closest(#)".}
  proc addDocumentMouseDownListener(handler: proc(ev: dom_api.Event) {.closure.}) {.importjs: "document.addEventListener('mousedown', #, true)".}
  proc eventKeyCode(ev: dom_api.Event): int {.importjs: "(#.keyCode || 0)".}
  proc stopPropagation(ev: dom_api.Event) {.importcpp: "#.stopPropagation()".}
  proc focusElement(node: dom_api.Element) {.importcpp: "#.focus()".}
  proc requestSessionTabsRenderSoon() {.importjs: "if (window.__ctRequestSessionTabsRender) { window.setTimeout(window.__ctRequestSessionTabsRender, 0); }".}

  var documentMenuDismissWired = false
  var activeMenuComponentForDismiss: MenuComponent

  proc eventTargetInsideMenu(ev: dom_api.Event): bool =
    let target = ev.eventTarget()
    if dom_api.isNodeNil(dom_api.Node(target)):
      return false
    let closest = target.closestElement(cstring"#navigation-menu, #menu-main, .menu-nested-elements")
    not dom_api.isNodeNil(dom_api.Node(closest))

  proc handleDocumentMenuMouseDown(ev: dom_api.Event) =
    if not ev.eventTargetInsideMenu() and not activeMenuComponentForDismiss.isNil and
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

  self.requestMenuRender()

method onDown*(self: MenuComponent) {.async.} =
  self.keyNavigation = true

  if self.searchResults.len == 0:
    if self.activeIndex < self.activeLength - 1:
      self.activeIndex += 1
  else:
    if self.activeSearchIndex < self.searchResults.len:
      self.activeSearchIndex += 1

  self.requestMenuRender()

method onRight*(self: MenuComponent) {.async.} =
  self.keyNavigation = true
  enterFolder(self)
  self.requestMenuRender()

method onLeft*(self: MenuComponent) {.async.} =
  self.keyNavigation = true
  closeFolder(self)
  self.requestMenuRender()

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
    # Only highlight with the active class during keyboard navigation.
    # Mouse hover is handled purely by CSS :hover on .ct-menu-item.
    if path.len == 0 or not self.keyNavigation:
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

    # Read the actual rendered item height so the submenu position scales
    # correctly with MENU_FONT_SIZE (ct-menu-item uses em-based min-height).
    # Fallback to 28 only if the DOM measurement isn't available yet.
    let itemH = block:
      let h = cast[int](jq(cstring"#menu-elements .ct-menu-item").toJs.offsetHeight)
      if h > 0: h else: 28

    fmt"top: {value * itemH + separators * itemH - 2 * itemH}px; left: calc({left}px + {2 * depth}px)"

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

  proc ensureMenuDismissWiring(self: MenuComponent) =
    ## Claim the click-outside-to-dismiss handler for this component.
    ##
    ## Kept separate from `wireMenuKeyboard` because it must run on EVERY
    ## `requestMenuRender`, including the ones whose DOM work the render gate
    ## skips: it is the only thing that tells the document-level handler which
    ## `MenuComponent` is currently on screen, and a session switch changes
    ## that without necessarily changing the rendered menu.  The per-node
    ## listeners in `wireMenuKeyboard`, by contrast, are attached to nodes that
    ## a skipped render leaves untouched, so re-attaching them would only
    ## duplicate handlers.
    activeMenuComponentForDismiss = self
    if not documentMenuDismissWired:
      documentMenuDismissWired = true
      addDocumentMouseDownListener(proc(ev: dom_api.Event) =
        handleDocumentMenuMouseDown(ev))

  proc wireMenuKeyboard(container: dom_api.Element; self: MenuComponent) =
    ensureMenuDismissWiring(self)

    let nav = dom_api.getElementById(dom_api.document, cstring NavigationMenuId)
    if dom_api.isNodeNil(dom_api.Node(nav)):
      return
    dom_api.addEventListener(dom_api.Node(nav), cstring"keydown",
      proc(ev: dom_api.Event) =
        if ev.eventKeyCode() == ESC_KEY_CODE:
          self.active = false
          self.closeMenu()
          self.data.redraw())

    let main = dom_api.getElementById(dom_api.document, cstring"menu-main")
    if not dom_api.isNodeNil(dom_api.Node(main)):
      dom_api.addEventListener(dom_api.Node(main), cstring"mousedown",
        proc(ev: dom_api.Event) =
          ev.stopPropagation())
      dom_api.addEventListener(dom_api.Node(main), cstring"mouseover",
        proc(ev: dom_api.Event) =
          ev.stopPropagation())

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
          nav.focusElement(),
        10)

    # `buildMenuShellModel` is not a pure read: it refreshes `self.prepared`,
    # `self.nameMap` and the `activePathWidths` / `activePathOffsets` maps that
    # the keyboard-navigation code relies on.  It therefore runs on every call,
    # including the ones whose DOM work the gate goes on to skip.
    let model = self.buildMenuShellModel()

    # Issue #555: skip the teardown+rebuild when nothing the shell renders has
    # changed.  `hostIntact` is what keeps this safe — the cache may only be
    # trusted while the DOM it describes is still on screen, and the debug
    # controls host is the part whose loss we specifically have to notice,
    # because `ui/debug.nim` re-mounts the toolbar into it.
    if not (menuShellGateOwner == self):
      menuShellGate.invalidate()
      menuShellGateOwner = self

    let signature = menuRenderSignature(model, extra = $self.keyNavigation)
    let hostIntact =
      not dom_api.isNodeNil(dom_api.Node(container).firstChild) and
      not dom_api.isNodeNil(dom_api.Node(dom_api.getElementById(
        dom_api.document, cstring"isonim-debug-controls")))
    if not menuShellGate.shouldRender(signature, hostIntact):
      # The mounted chrome is already correct.  The cascade below still runs:
      # every one of those calls is an idempotent repair that returns early
      # when its own host is intact, and skipping them outright would stop the
      # command palette from picking up state changes that ride the same
      # redraw.  With the shell left alone they are now no-ops instead of
      # forty-odd toolbar re-mounts per trace open.
      ensureMenuDismissWiring(self)
      requestSessionTabsRenderSoon()
      if not self.data.startOptions.shellUi:
        self.debug.requestDebugShellRender()
        if not self.data.ui.commandPalette.isNil:
          self.data.ui.commandPalette.requestCommandPalettePanelRefresh()
        self.debug.requestDebugControlsRender()
      return

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
    menuShellGate.noteRendered(signature)
    requestSessionTabsRenderSoon()
    if not self.data.startOptions.shellUi:
      self.debug.requestDebugShellRender()
      if not self.data.ui.commandPalette.isNil:
        self.data.ui.commandPalette.requestCommandPalettePanelRefresh()
      self.debug.requestDebugControlsRender()
    wireMenuKeyboard(container, self)
    if self.keyNavigation:
      focusNavigationSoon()
