from std / dom import Document
import std / tables
import
  ui_imports, debug, command
from shortcut_labels import renderChord
# PLAT-48: the menu's logical state is the shared Menu ViewModel's.
import ../viewmodel/viewmodels/menu_vm

# NS1 / Noir-Studio.md §1a.2. Three decisions below used to be build checks
# (`defined(ctmacos)`, `electron_lib.inElectron`); they are now capability
# queries against the running platform, so an action is absent because its
# capability is rather than because the code asked which build it was.
# `topbar_actions.nim` is pure and its decisions are asserted headlessly in
# `viewmodel/tests/unit/test_platform_facade.nim`, on both backends.
from ../platform_host import
  TopbarAction, TopbarModel, ctTopbar, has, tbaInPageMenu, tbaWindowControls,
  ctPlatform, can, capWindowControls

proc closeMenu(self: MenuComponent)

when defined(js):
  proc requestMenuRender*(self: MenuComponent)

when defined(js):
  import isonim/web/web_renderer
  from isonim/web/dom_api import nil
  from ../viewmodel/views/isonim_menu_shell_view import
    DebugControlsHostId, MenuNestedRecord, MenuNodeRecord, MenuNodeRecordKind,
    MenuRecordElement, MenuRecordFolder, MenuSearchResultRecord,
    MenuShellCallbacks, MenuShellModel, NavigationMenuId,
    captionBarHostClasses, renderMenuShellInto
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
    # `reserveWindowControls = defined(ctmacos)` until NS1. The reservation is
    # a fact about the *window system* — macOS paints traffic lights over the
    # caption bar — not about the build, and the same bundle rendering into a
    # browser tab has no lights to avoid. `TopbarModel` derives both this and
    # the fullscreen release from the platform profile.
    let bar = ctTopbar(fullscreen = captionBarFullscreen)
    host.setAttribute(
      cstring"class",
      cstring(captionBarHostClasses(
        existing,
        reserveWindowControls =
          bar.reserveWindowControlSpace or bar.captionBarFullscreen,
        fullscreen = bar.captionBarFullscreen)))

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
        activeMenuComponentForDismiss.vm.isOpen:
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
  ## Close the menu: the ViewModel's `close`, plus the DOM measurements this
  ## renderer keeps for the submenus it drew.
  self.vm.close()
  self.activePathWidths = JsAssoc[int, int]{}
  self.activePathOffsets = JsAssoc[int, int]{}

proc syncMenuVM*(self: MenuComponent)

proc openMainMenu(self: MenuComponent) =
  self.data.focusComponent(self)
  self.syncMenuVM()
  self.vm.open(keyboard = false)
  self.activePathWidths = JsAssoc[int, int]{}
  self.activePathOffsets = JsAssoc[int, int]{}

proc loadShortcut*(action: ClientAction, config: Config): cstring =
  ## The chord shown beside a menu item, from the live config.
  ##
  ## The body moved to `ui/shortcut_labels.nim` so the debug toolbar's
  ## tooltips render chords through the SAME code. They previously did not
  ## render them at all — the tooltips carried the chord as a hardcoded
  ## literal — and two implementations of "spell this binding" would have been
  ## free to disagree about the very strings this is here to keep honest.
  cstring(renderChord(action, config))

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
  ## `Right`: enter the highlighted folder (the ViewModel's rule).
  if self.vm.enterFolder():
    self.data.redraw()

proc closeFolder*(self: MenuComponent) =
  ## `Left` / `Esc` inside a folder: back to its parent.
  if self.vm.leaveFolder():
    self.data.redraw()

proc runAction*(self: MenuComponent, action: ClientActionHandler, actionData: JsObject = nil) =
  if not action.isNil:
    action(actionData)
    self.closeMenu()

proc enterElement*(self: MenuComponent, node: MenuNode) =
  if node.enabled and node.kind == MenuElement:
    var action = self.data.actions[node.action]
    self.runAction(action, node.actionData)

proc runActivation(self: MenuComponent; activation: MenuActivation) =
  ## Run what the ViewModel chose. The action is looked up on the `MenuNode`
  ## at the chosen path, because the node — not the ViewModel — carries the
  ## desktop's `actionData` (a launch configuration's index).
  if not activation.ran:
    return
  let node = self.nodeAtPath(activation.path)
  if not node.isNil:
    self.enterElement(node)

proc enterElement*(self: MenuComponent) =
  ## `Enter`: the ViewModel activates the highlighted item (or search
  ## result); an action runs, a folder is entered.
  let activation = self.vm.activate()
  if activation.ran:
    self.runActivation(activation)
  self.data.redraw()

method onUp*(self: MenuComponent) {.async.} =
  if self.vm.searchResults.len > 0:
    self.vm.moveSearch(-1)
  else:
    self.vm.moveHighlight(-1)
  self.requestMenuRender()

method onDown*(self: MenuComponent) {.async.} =
  if self.vm.searchResults.len > 0:
    self.vm.moveSearch(1)
  else:
    self.vm.moveHighlight(1)
  self.requestMenuRender()

method onRight*(self: MenuComponent) {.async.} =
  discard self.vm.enterFolder()
  self.requestMenuRender()

method onLeft*(self: MenuComponent) {.async.} =
  discard self.vm.leaveFolder()
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
  if self.vm.isOpen:
    self.closeMenu()
  else:
    self.openMainMenu()
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
    ## Whether a menu node belongs on this platform.
    ##
    ## The condition was `ui_imports.electron_lib.inElectron` — the last
    ## `inElectron` decision in this file, and the last thing keeping
    ## `ui_imports`' `electron_lib` re-export alive for 46 modules. NS1's own
    ## table in `viewmodel/viewmodels/topbar_actions.nim` maps `inElectron` to
    ## `capWindowControls` for `MenuShellModel.showWindowMenu`; the same
    ## mapping is used here rather than a freshly invented one, because "the
    ## platform owns the window frame" is the distinction both sites are
    ## actually drawing.
    ##
    ## **Currently this decides nothing, and that is stated rather than
    ## discovered later.** The `Host` / `NonHost` dimension exists in the menu
    ## DSL (`hostfolder`, `hostelement`, `hostexclude_*` in `ui_js.nim`) and
    ## **no menu node in the tree uses any of them** — so `menuOs` never
    ## carries either flag and both branches below reduce to the same
    ## `not (menuOs and MacOS)` for every node that exists. The change is
    ## therefore behaviour-preserving by construction, and the capability
    ## mapping is justified by the table above rather than by observed
    ## rendering. If someone gives the dimension its first user, that is when
    ## the mapping gets exercised — and `capWindowControls` is then the thing
    ## to argue with, not `inElectron`.
    if ctPlatform().can(capWindowControls):
      not cast[bool]((node.menuOs and ord(MenuNodeOSHost)) or
        (node.menuOs and ord(MenuNodeOSMacOS)))
    else:
      not cast[bool]((node.menuOs and ord(MenuNodeOSNonHost)) or
        (node.menuOs and ord(MenuNodeOSMacOS)))

  proc activeNodeClass(self: MenuComponent; path: seq[int]): string =
    ## Only a KEYBOARD highlight is marked with the active class; a hovered
    ## item is CSS `:hover` on `.ct-menu-item`. Which items are active — the
    ## open folders on the path and the highlighted item — is the Menu
    ## ViewModel's answer (`isOnPath`), not a second copy kept here.
    if path.len == 0 or not self.vm.keyNavigation:
      return ""
    if self.vm.isOnPath(path): "menu-active-node" else: ""

  proc menuItemOf(node: MenuNode): MenuItem =
    ## The Menu ViewModel's item for one desktop `MenuNode`, children
    ## included, with the platform's `hidden` decided by
    ## `shouldRenderMenuNode` — so a macOS-only folder keeps its index in the
    ## ViewModel (paths name the same node in both trees) but can never be
    ## highlighted.
    result = MenuItem(
      kind: (if node.kind == MenuFolder: mikFolder else: mikAction),
      label: $node.name,
      action: (if node.kind == MenuElement: $node.action else: ""),
      enabled: node.enabled,
      hidden: not node.shouldRenderMenuNode(),
      separatorAfter: node.isBeforeNextSubGroup,
      os: node.menuOs,
      role: (if node.role.isNil: "" else: $node.role))
    for child in menuNodeChildren(node):
      result.children.add menuItemOf(child)

  proc syncMenuVM*(self: MenuComponent) =
    ## Hand the ViewModel the tree the desktop built (`data.ui.menuNode`,
    ## after its run-time additions) and the chords the live config binds.
    ## Cheap enough to run on every render; `setTree` keeps an open path that
    ## still names folders.
    if self.data.ui.menuNode.isNil:
      return
    self.vm.setTree(menuItemOf(self.data.ui.menuNode))
    var chords = initTable[string, string]()
    for (p, it) in self.vm.root.actionItems():
      if it.action.len > 0 and not chords.hasKey(it.action):
        let node = self.nodeAtPath(p)
        if not node.isNil:
          let chord = $loadShortcut(node.action, self.data.config)
          if chord.len > 0:
            chords[it.action] = chord
    self.vm.setShortcuts(chords)

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

    # NS1: the in-page menu appears when the platform does NOT supply a native
    # menu bar to put it in — which on the desktop is "not macOS", and on the
    # web is "always", and neither is a `defined()`.
    let topbar = ctTopbar()
    result.showNavigation =
      not self.data.ui.menuNode.isNil and topbar.has(tbaInPageMenu)
    self.syncMenuVM()
    result.active = self.vm.isOpen
    result.searchQuery = self.vm.searchQuery
    # NS1: we draw the window buttons when the platform hands us the frame and
    # paints nothing over it. Was `inElectron and not defined(ctmacos)` — one
    # runtime check and one build check answering one question between them.
    result.showWindowMenu = topbar.has(tbaWindowControls)
    result.maximized = isWindowMaximizedForMenu()

    if self.data.ui.menuNode.isNil:
      return

    let menu = self.data.ui.menuNode
    result.rootNodes = self.menuRecordsForNode(menu, @[])

    for index, res in self.vm.searchResults:
      let label = self.vm.searchLabels[index]
      result.searchResults.add(MenuSearchResultRecord(
        label: label,
        shortcut: self.vm.shortcutFor(res.action),
        iconClass: $iconClass(cstring(label)),
        active: self.vm.searchIndex == index))

    var current = menu
    var sum = 0
    for depth, index in self.vm.path:
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
        nodes: self.menuRecordsForNode(current, self.vm.path[0 .. depth])))

  proc handleNodeMouseOver(self: MenuComponent; path: seq[int]) =
    ## The pointer is over an item: the ViewModel's `hoverPath` (a folder
    ## opens, an item is highlighted, not a keyboard highlight). Rendered
    ## only when that changed something.
    let before = self.vm.revision
    self.vm.hoverPath(path)
    if self.vm.revision != before:
      self.requestMenuRender()

  proc handleNodeClick(self: MenuComponent; path: seq[int]) =
    ## A click: an action runs and the menu closes; a folder opens — the
    ## Menu ViewModel's `clickPath`, so the desktop, the terminal and GPUI
    ## answer a click on the same item the same way.
    let activation = self.vm.clickPath(path)
    if activation.ran:
      self.runActivation(activation)
    self.requestMenuRender()

  proc handleSearchResultClick(self: MenuComponent; index: int) =
    if index >= 0 and index < self.vm.searchResults.len:
      self.vm.searchIndex = index
      let activation = self.vm.activate()
      self.runActivation(activation)
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

  proc setWindowProperty(name: cstring; value: JsObject) {.importjs: "window[#] = #".}

  proc exposeMenuViewModel(self: MenuComponent) =
    ## PLAT-48's VERIFICATION-GATE SEAM: `window.__ctMenuVM` reads and WRITES
    ## the Menu ViewModel this component renders, so a test can change the
    ## ViewModel's highlighted item directly and read the highlighted item
    ## back out of the DOM. If this renderer kept its own copy of the state,
    ## that write would not reach the screen — which is exactly what the
    ## gate's mutation arm checks.
    let component = self
    setWindowProperty(cstring"__ctMenuVM", js{
      state: proc(): cstring =
        cstring("{\"isOpen\":" & $component.vm.isOpen & ",\"path\":[" &
                component.vm.path.mapIt($it).join(",") & "]" & ",\"highlight\":" &
                $component.vm.highlight & ",\"keyNavigation\":" &
                $component.vm.keyNavigation & "}"),
      setHighlight: proc(path: seq[int]; highlight: int) =
        component.vm.isOpen = true
        component.vm.path = path
        component.vm.highlight = highlight
        component.vm.keyNavigation = true
        inc component.vm.revision
        component.requestMenuRender(),
      open: proc() =
        component.openMainMenu()
        component.requestMenuRender(),
      close: proc() =
        component.closeMenu()
        component.requestMenuRender()})

  proc requestMenuRender*(self: MenuComponent) =
    ## Refresh the global menu host directly through IsoNim.
    ##
    ## This replaces the old shared ``#menu`` Karax ``setRenderer`` island.
    ## The deeper menu state and action callbacks remain on ``MenuComponent``.
    if self.isNil:
      return
    self.exposeMenuViewModel()
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

    let signature = menuRenderSignature(model, extra = $self.vm.keyNavigation)
    let hostIntact =
      not dom_api.isNodeNil(dom_api.Node(container).firstChild) and
      not dom_api.isNodeNil(dom_api.Node(dom_api.getElementById(
        dom_api.document, cstring DebugControlsHostId)))
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
    if self.vm.keyNavigation:
      focusNavigationSoon()
