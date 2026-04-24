import
  asyncjs, strformat, strutils, sequtils, jsffi, algorithm,
  karax, karaxdsl, vstyles,
  state, editor, debug, menu, status, command, search_results, shell, deepreview, session_tabs,
  session_switch, panel_transfer, auto_hide,
  ../[ types, renderer, config ],
  ../lib/[ logging, misc_lib, jslib ]

import kdom except Location
import vdom except Event
from dom import Element, getAttribute, Node, preventDefault, document,
                getElementById, querySelectorAll, querySelector

type
  ContextHandler* = proc(tab: js, args: seq[string])

# context handlers for each shortcut
var contextHandlers*: JsAssoc[cstring, JsAssoc[cstring, ContextHandler]] = JsAssoc[cstring, JsAssoc[cstring, ContextHandler]]{} # app-global

# SEARCH

proc onSearchSubmit(ev: Event, v: VNode) =
  cast[dom.Event](ev).preventDefault()


const RESULT_LIMIT = 20

# FIND

proc historyFind*(tab: js, args: seq[string]) =
  log "history find"

proc focus: js = # nil?
  if data.ui.focusHistory.len > 0:
    return data.ui.focusHistory[^1]
  else:
    return nil

proc changeFocus*(panel: js) =
  if data.ui.focusHistory.len == 0 or panel != data.ui.focusHistory[^1]:
    data.ui.focusHistory.add(panel)

proc contextBind*(shortcut: string, arg: js, handler: ContextHandler) =
  var c = contextHandlers[shortcut]
  if c.isNil:

    c = JsAssoc[cstring, ContextHandler]{}
    contextHandlers[shortcut] = c

    Mousetrap.`bind`(cstring(shortcut)) do ():
      var focused = focus()
      if focused.isNil: return

proc configureFind =
  discard

var document {.importc.}: js

proc newGoldenLayout*(
  root: JsObject,
  bindComponentCallback: proc,
  unbindComponentCallback: proc
): GoldenLayout {.importjs: "new GoldenLayout(#, #, #)".}

proc convertTabTitle(content: cstring): cstring =
  var title: cstring = ""
  var label = content
  let pattern = regex("[A-Z][a-z0-9]*")
  var matches = label.matchAll(pattern)

  return (matches.mapIt(it[0].toUpperCase())).join(cstring" ")

proc clearSaveHistoryTimeout(editorService: EditorService) =
  if editorService.hasSaveHistoryTimeout:
    windowClearTimeout(editorService.saveHistoryTimeoutId)
    editorService.hasSaveHistoryTimeout = false
    editorService.saveHistoryTimeoutId = -1

proc addTabToHistory(editorService: EditorService, tab: EditorViewTabArgs) =
  cdebug "tabs: addTabToHistory " & $tab
  editorService.tabHistory = editorService.tabHistory.filterIt(
    it.name != tab.name
  )
  editorService.tabHistory.add(tab)
  editorService.historyIndex = editorService.tabHistory.len - 1
  cdebug "tabs: addTabToHistory: historyIndex -> " & $editorService.historyIndex


proc eventuallyUpdateTabHistory(editorService: EditorService, tab: EditorViewTabArgs) =
  editorService.clearSaveHistoryTimeout()
  editorService.saveHistoryTimeoutId = windowSetTimeout(
    proc = editorService.addTabToHistory(tab),
    editorService.switchTabHistoryLimit)
  editorService.hasSaveHistoryTimeout = true

type
  ContextMenuOption = object
    label: cstring
    action: proc(container: GoldenContainer, state: GoldenItemState)

# ---------------------------------------------------------------------------
# M21: "Send to Window" context menu on GL tabs
# ---------------------------------------------------------------------------

proc addPanelTransferContextMenu(tab: GoldenTab, contentItem: GoldenContentItem) =
  ## Attach a right-click context menu to a GL tab element that offers
  ## "Send to Window" for cross-window panel transfer (M21/M22).
  let tabElement = tab.element
  if tabElement.isNil or tabElement.isUndefined:
    return

  tabElement.addEventListener(cstring"contextmenu", proc(event: JsObject) =
    event.preventDefault()
    let sessionId = if data.sessions.len > 0:
        int(data.activeSessionIndex)
      else:
        0

    discard requestWindowList().then(proc(response: JsObject) =
      let items = buildSendToWindowMenuItems(contentItem, sessionId, response)
      let x = event.clientX.to(int)
      let y = event.clientY.to(int)
      showContextMenu(items, x, y)))

let commonContextMenuOptions: seq[ContextMenuOption] = @[
  ContextMenuOption(
    label: "Duplicate Tab",
    action: proc(container: GoldenContainer, state: GoldenItemState) = cwarn "TODO create new tab of the same type")
]

let editorSpecificContextMenuOptions: seq[ContextMenuOption] = @[
  ContextMenuOption(
    label: "Copy full path",
    action: proc(container: GoldenContainer, state: GoldenItemState) = clipboardCopy(state.label))
]

proc createContextMenuFromOptions(
  container: GoldenContainer,
  state: GoldenItemState,
  contextMenuOptions: seq[ContextMenuOption]
): ContextMenu =

  var
    options: JsAssoc[int, cstring] = JsAssoc[int, cstring]{}
    actions: JsAssoc[int, proc()] = JsAssoc[int, proc()]{}

  for i, option in contextMenuOptions:
    options[i] = option.label
    actions[i] = proc() {.closure.} = option.action(container, state)

  return ContextMenu(
    options: options,
    actions: actions
  )

proc makeNestedButton(layout: js, ev: Event): VNode =
  buildHtml(
    tdiv(
      class = "layout-dropdown hidden",
      id = "layout-dropdown-toggle"
    )
  ):
    tdiv(
      class = "layout-dropdown-node",
      onclick = proc(e: Event, tg: VNode) =
        ev.toJs.target.parent.removeChild(ev.target)
      ):
      text "Close all"
    tdiv(
      class = "layout-dropdown-node",
      onclick = proc(e: Event, tg: VNode) =
        if cast[bool](ev.toJs.target.isMaximised):
          ev.toJs.target.minimise()
          e.target.innerHTML = "Maximise container"
        else:
          ev.toJs.target.maximise()
          e.target.innerHTML = "Minimise container"
    ):
      text "Maximise container"

proc closeLayoutTab*(data: Data, content: Content, id: int) =
  if not data.ui.componentMapping[content].hasKey(id):
    raise newException(Exception, "There is not any component with the given id.")

  # remove component from registry
  discard jsDelete(data.ui.componentMapping[content][id])

  # remove component karax instance
  discard jsDelete(kxiMap[convertComponentLabel(content, id)])

  # remove component from open components registry from the same content type (if there is any)
  if data.ui.openComponentIds[content].find(id) != -1:
    data.ui.openComponentIds[content].delete(id)

# Track whether the shared (non-GL) Karax renderers have been initialised.
# These renderers (menu, status, fixed-search, search-results, session-tab-bar)
# live outside the per-session GL container and only need to be set up once.
var sharedRenderersInitialised = false

proc ensureSharedRenderers() =
  ## Set up the Karax renderers for global chrome elements that live outside
  ## individual session GL containers.  Safe to call multiple times — it only
  ## acts on the first invocation.
  if sharedRenderersInitialised:
    return
  sharedRenderersInitialised = true

  kxiMap["menu"] = setRenderer(
    proc: VNode =
      if not data.ui.menu.isNil: data.ui.menu.render()
      else: buildHtml(tdiv()),
    "menu", proc = discard)
  kxiMap["status"] = setRenderer(
    proc: VNode =
      if not data.ui.status.isNil: data.ui.status.render()
      else: buildHtml(tdiv()),
    "status", proc = discard)
  kxiMap["fixed-search"] = setRenderer(fixedSearchView, "fixed-search", proc = discard)
  kxiMap["search-results"] = setRenderer(
    proc: VNode =
      if not data.ui.searchResults.isNil: data.ui.searchResults.render()
      else: buildHtml(tdiv()),
    "search-results", proc = discard)
  kxiMap["session-tab-bar"] = setRenderer(
    proc: VNode = renderSessionTabs(data),
    "session-tab-bar",
    proc = attachTabClickHandlers(data))

  data.ui.menu.kxi = kxiMap["menu"]
  data.ui.status.kxi = kxiMap["status"]
  data.ui.searchResults.kxi = kxiMap["search-results"]

  # Auto-hide strips: load persisted state (M11) or create empty state,
  # then create the strip DOM elements alongside the GL container.
  data.ui.autoHide = loadAutoHideState()
  setupStripElements(data.ui.autoHide)

# Triage: rename to initGoldenLayout
proc initLayout*(initialLayout: GoldenLayoutResolvedConfig,
                 containerElement: kdom.Element = nil) =
  ## Initialise GoldenLayout for the active session.
  ##
  ## ``containerElement`` is the DOM element GL will bind to.  When nil
  ## (the default, used during initial page load) we look up
  ## ``session-container-<activeSessionIndex>`` inside ``#ROOT``.
  ## For new sessions created at runtime the caller passes the freshly
  ## created container element directly.
  echo "initLayout"
  echo data.ui.layout.isNil

  if data.startOptions.shellUi:
    kxiMap["menu"] = setRenderer(proc: VNode = data.ui.menu.render(), "menu", proc = discard)
    data.ui.menu.kxi = kxiMap["menu"]
    return

  if data.startOptions.withDeepReview:
    # DeepReview mode: render a standalone review UI without Golden Layout.
    # Similar to shell-ui mode, we create a single full-page component.
    clog "initLayout: setting up DeepReview renderer"
    let drComponent = data.makeDeepReviewComponent(data.generateId(Content.DeepReview))
    kxiMap["deepreview"] =
      setRenderer(
        proc: VNode =
          if not drComponent.isNil:
            drComponent.render()
          else:
            buildHtml(tdiv()),
        "deepreview",
        proc = discard)
    drComponent.kxi = kxiMap["deepreview"]
    redrawSync(kxiMap["deepreview"])
    # Hide root-container so it doesn't intercept pointer events
    # over the deepreview view (it has position: fixed and overlays
    # the entire viewport).
    let rootCont = document.getElementById(cstring"root-container")
    if not rootCont.isNil:
      rootCont.style.display = cstring"none"
    return

  if data.startOptions.welcomeScreen and data.trace.isNil:
    clog "initLayout: setting up welcome screen renderer"
    kxiMap["welcome-screen"] =
      setRenderer(
        proc: VNode =
          clog "welcome screen render proc called"
          if not data.ui.welcomeScreen.isNil:
            data.ui.welcomeScreen.render()
          else:
            buildHtml(tdiv()),
        "welcomeScreen",
        proc = discard)
    data.ui.welcomeScreen.kxi = kxiMap["welcome-screen"]
    clog "initLayout: welcome screen kxi set, calling redrawSync"
    # Force immediate redraw since window.onload may have already fired
    redrawSync(kxiMap["welcome-screen"])
    return

  # Determine the GL container element.
  # On initial load (session 0) there is no session-container-0 in the DOM
  # yet.  We create it here so that hide/show session switching can toggle
  # its visibility without special-casing the first session.
  let root = if not containerElement.isNil:
      containerElement
    else:
      let containerId = cstring("session-container-" & $data.activeSessionIndex)
      var el = document.getElementById(containerId)
      if el.isNil:
        # Create the container inside #ROOT.
        el = document.createElement("div")
        el.id = containerId
        el.class = cstring"session-container"
        let rootEl = document.getElementById(cstring"ROOT")
        if not rootEl.isNil:
          rootEl.appendChild(el)
      el

  var layout = newGoldenLayout(
    cast[JsObject](root),
    proc() = (cdebug "layout: component binded"),
    proc() = (cdebug "layout: component unbinded")
  )

  # Create nested buttons in header
  layout.on(cstring"stackCreated") do (ev: Event):
    let newElement = kdom.document.createElement("div")
    let hiddenDropdown = vnodeToDom(makeNestedButton(layout, ev), KaraxInstance())
    newElement.classList.add("layout-buttons-container")
    newElement.setAttribute("tabindex", "0")
    newElement.onclick = proc(e: Event) {.nimcall.} =
      let currentElement = cast[kdom.Element](e.toJs.currentTarget)
      let element = cast[kdom.Element](currentElement.children[0])

      if element.classList.contains("hidden"):
        element.classList.remove("hidden")
        currentElement.classList.add("active")
      else:
        element.classList.add("hidden")
        currentElement.classList.remove("active")

      cast[kdom.Element](e.target).focus()

    newElement.onblur = proc(e: Event) {.nimcall.} =
      let currentElement = cast[kdom.Element](e.toJs.currentTarget)
      e.toJs.target.children[0].classList.add("hidden")
      currentElement.classList.remove("active")

    let container = ev.toJs.target.element.childNodes[0].childNodes[1]
    let tabContainer = ev.toJs.target.element.childNodes[0].childNodes[0]

    while cast[kdom.Element](container).childNodes.len() > 0:
      container.removeChild(container.childNodes[0])

    newElement.appendChild(hiddenDropdown)
    tabContainer.appendChild(newElement)

    # M7: Subscribe to the pin event on each stack.  When the user clicks the
    # pin button in a stack header, detach the active component and move it
    # into the auto-hide strip.
    let stack = ev.toJs.target
    stack.on(cstring"pin") do ():
      let activeItem = stack.getActiveContentItem()
      if activeItem.isNil or activeItem.isUndefined:
        return

      # Detach the component from the GL tree.  Returns an object with
      # {componentItem, config, element}.
      let detached = detachChild(cast[JsObject](stack), cast[JsObject](activeItem))
      if detached.isNil or detached.isUndefined:
        return

      # Determine content type and title from the component's config/state.
      let config = detached.config
      let componentState = config.componentState
      let contentEnum = componentState.content.to(Content)
      let title = if not componentState.label.isNil and not componentState.label.isUndefined:
          componentState.label.to(cstring)
        else:
          cstring($contentEnum)

      # Determine edge heuristic: use Bottom as default (most natural for
      # non-editor panels).  A smarter heuristic can be added later.
      let edge = Bottom

      # Add to auto-hide strip.
      let autoHideState = data.ui.autoHide
      if autoHideState.isNil:
        return

      let panel = autoHideState.addPanelAndRefresh(
        edge,
        title,
        icon = cstring"",   # no icon for now
        contentEnum,
        config
      )

      # Store the detached DOM element and handle for later reattachment.
      panel.detachedElement = cast[Element](detached.element)
      panel.detachedHandle = detached

  data.ui.layout = layout
  data.ui.layoutConfig = cast[GoldenLayoutConfigClass](window.toJs.LayoutConfig)
  data.ui.contentItemConfig = cast[GoldenLayoutItemConfigClass](window.toJs.ItemConfig)

  # Set up shared (non-GL) Karax renderers once.  These live outside the
  # per-session GL container and survive session switches.
  ensureSharedRenderers()

  layout.registerComponent(cstring"editorComponent") do (container: GoldenContainer, state: GoldenItemState):
    if state.label.len == 0:
      return

    let componentLabel = cstring(fmt"editorComponent-{state.id}")

    var element = container.getElement()
    element.innerHTML = cstring(fmt"<div id={componentLabel} class=" & "\"component-container\"></div>")

    cdebug fmt"layout: registering editor component {componentLabel}"

    container.on(cstring"tab") do (tab: GoldenTab):
      data.ui.saveLayout = true
      #componentMapping -> all registered components in data
      #content -> enum {TERMINAL, TRACELOG etc..}

      if data.ui.openComponentIds[state.content].find(state.id) == -1:
        data.ui.openComponentIds[state.content].add(state.id)

      let similarComponents = data.ui.componentMapping[state.content]

      if similarComponents.len > 0:
        let openComponents = data.ui.openComponentIds[state.content]
        let lastComponentId = if openComponents.len > 0: openComponents[^1] else: 0
        let lastComponent = similarComponents[lastComponentId]

        lastComponent.layoutItem = cast[GoldenContentItem](container.tab.contentItem)

      tab.setTitle(state.label)

      if not ($state.label).startsWith("event:"):
        let tokens = state.label.split(cstring"/")
        tab.titleElement.innerHTML = if tokens.len > 1:
            tokens[^2] & cstring"/" & tokens[^1]
          else:
            tokens[^1]
      else:
        let tokens = state.label.split(cstring"/")
        tab.titleElement.innerHTML = if tokens.len > 1:
            tokens[0] & tokens[^1]
          else:
            state.label

      data.ui.activeEditorPanel = cast[GoldenContentItem](tab.contentItem.parent)

      # get latest editorPanel
      let editorPanel = data.viewerPanel()

      if not editorPanel.isNil:
        # set all editor view types panels to latest editorPanel
        for view, nilPanel in data.ui.editorPanels:
          data.ui.editorPanels[view] = editorPanel

        # setup active editor panel: used for switch/closing active tab actions: ctrl-tab/ctrl-w and other shortcuts(configurable)
          data.ui.activeEditorPanel = editorPanel

        if data.ui.openComponentIds[state.content].len == 1:
          # add activeContentItemChanged event handler
          editorPanel.toJs.on(cstring"activeContentItemChanged") do (event:  GoldenContentItem):
            let config = event.toConfig()
            let componentState = config.componentState

            if componentState.content.to(Content) != Content.EditorView:
              return

            let editorPath = componentState.fullPath.to(cstring)
            cdebug "layout: tab changed: active = " & $editorPath
            data.services.editor.active = editorPath
            let editor = data.ui.editors[editorPath]
            let tab = EditorViewTabArgs(name: editorPath, editorView: editor.editorView)
            # check if current active tab is newly created or it exists in tab history
            if data.services.editor.tabHistory.find(tab) == -1:
              # if the tab is newly created it needs to be added to history without time limit (immediately)
              data.services.editor.addTabToHistory(tab)
            else:
              # if it is existing (already is in the history), the tab history time limit should expire
              # because existing tab is added to history only if the user keeps it open
              # if the user switch to another tab before the limit expires - the tab should not be added to history
              data.services.editor.eventuallyUpdateTabHistory(tab)

      # M21: Attach "Send to Window" context menu to the tab.
      addPanelTransferContextMenu(tab, cast[GoldenContentItem](tab.contentItem))

    var containerId: cstring
    containerId = cstring(fmt"editorComponent-{state.id}")

    discard windowSetTimeout((proc =
      if not data.ui.componentMapping[state.content][state.id].isNil:
        let component = data.ui.componentMapping[state.content][state.id]

        kxiMap[state.label] = setRenderer(
          (proc: VNode = component.render()),
          containerId,
          proc = discard)
        component.kxi = kxiMap[state.label]

        EditorViewComponent(component).renderer = kxiMap[state.fullPath]

        discard component.afterInit()

      discard windowSetTimeout((proc = redrawAll()), 200)), 200)

  layout.registerComponent(cstring"genericUiComponent") do (container: GoldenContainer, state: GoldenItemState):
    if state.label.len == 0:
      return
    let editorLabel = state.label
    var element = container.getElement()
    element.innerHTML = cstring(fmt"<div id={editorLabel} class=" & "\"component-container\"></div>")

    cdebug "layout: register " & state.label

    container.on(cstring"tab") do (tab: GoldenTab):
      # prepare layout to be saved on upcoming stateChanged event
      data.ui.saveLayout = true

      # add contentItem to component
      # all components - data.ui.componentMapping
      let similarComponents = data.ui.componentMapping[state.content]

      ## check if id of the component was added to the open components register
      # data.ui.openComponentIds all components that are open
      if data.ui.openComponentIds[state.content].find(state.id) == -1:
        data.ui.openComponentIds[state.content].add(state.id)

      ## map corresponding layout item to the last component that was added
      if similarComponents.len > 0:
        let openComponents = data.ui.openComponentIds[state.content]
        # ^1 - last element of an array
        let lastComponentId = if openComponents.len > 0: openComponents[^1] else: 0
        let lastComponent = similarComponents[lastComponentId]
        # container.tab.contentItem reference to golden layout item
        lastComponent.layoutItem = cast[GoldenContentItem](container.tab.contentItem)

      tab.setTitle(cstring(convertTabTitle($state.content)))

      # M21: Attach "Send to Window" context menu to the tab.
      addPanelTransferContextMenu(tab, cast[GoldenContentItem](tab.contentItem))

    var containerId: cstring
    containerId = state.label

    discard windowSetTimeout((proc =
      if not data.ui.componentMapping[state.content][state.id].isNil:
        let component = data.ui.componentMapping[state.content][state.id]
        if state.content != Content.Shell:
          kxiMap[state.label] = setRenderer(
            (proc: VNode = component.render()),
            containerId,
            proc = discard
          )
          component.kxi = kxiMap[state.label]

        if state.content == Content.Shell:
          let shellComponent = ShellComponent(component)
          if shellComponent.shell.isNil:
            discard shellComponent.createShell()

        discard component.afterInit()
      discard windowSetTimeout((proc = redrawAll()), 200)), 200)

  layout.loadLayout(initialLayout)

  # M9: Provide the GL layout reference to the auto-hide module so it can
  # register strip tabs as DragSources for drag-back into the layout.
  setAutoHideLayout(cast[JsObject](layout))

  # M11: If auto-hide state was loaded from localStorage, refresh the strips
  # now that the GL layout is available so DragSources are registered and
  # the strip tabs render for any previously auto-hidden panels.
  if not data.ui.autoHide.isNil:
    refreshAllStrips(data.ui.autoHide)

  # M21: Register IPC handler for receiving panels from other windows.
  registerPanelAttachHandler(layout)

  layout.on(cstring"stateChanged") do (event: js):
    cdebug "layout event: stateChanged"

    # check if only one tab is left and prevent user from close/drag it
    let mainContainer = data.ui.layout.groundItem.contentItems[0]
    if mainContainer.contentItems.len == 1 and
      mainContainer.contentItems[0].isStack and
      mainContainer.contentItems[0].contentItems.len == 1 and
      mainContainer.contentItems[0].contentItems[0].isComponent:
      mainContainer.contentItems[0].contentItems[0]
        .tab.element.style.pointerEvents = cstring"none"
    else:
      let tabElements = jqAll(".lm_tab")
      for element in tabElements:
        element.style.pointerEvents = cstring"auto"

    if not data.ui.layout.isNil and data.ui.saveLayout:
      data.ui.resolvedConfig = data.ui.layout.saveLayout()
      data.saveConfig(data.ui.layoutConfig.fromResolved(data.ui.resolvedConfig))
      data.ui.saveLayout = false

  layout.on(cstring"stackCreated") do (event: js):
    cdebug "layout event: stackCreated"

    # prepare layout to be saved on upcoming stateChanged event
    data.ui.saveLayout = true

  layout.on(cstring"columnCreated") do (event: js):
    cdebug "layout event: columnCreated"

    # prepare layout to be saved on upcoming stateChanged event
    data.ui.saveLayout = true

  layout.on(cstring"rowCreated") do (event: js):
    cdebug "layout event: rowCreated"

    # prepare layout to be saved on upcoming stateChanged event
    data.ui.saveLayout = true

  layout.on(cstring"itemDestroyed") do (event: js):
    cdebug "layout event: itemDestroyed"
    let eventTarget = cast[GoldenContentItem](event.target)

    if eventTarget.isComponent:
      let componentState = cast[GoldenItemState](eventTarget.toConfig().componentState)

      if componentState.isEditor:
        let id = componentState.fullPath
        let editorService = data.services.editor

        if editorService.open.hasKey(id):
          data.closeEditorTab(id)

      data.closeLayoutTab(componentState.content, componentState.id)

    data.ui.saveLayout = true

  # -------------------------------------------------------------------------
  # M8: Drag-to-edge auto-hide handlers
  # -------------------------------------------------------------------------
  # Show edge indicators when a GL component is dragged near a container edge,
  # and auto-hide the component when it is dropped outside all GL stacks.

  layout.on(cstring"dragMove") do (x: js, y: js, componentItem: js):
    let fx = x.to(float)
    let fy = y.to(float)
    let result = detectNearestEdge(fx, fy)
    if result.near:
      showEdgeIndicator(result.edge)
    else:
      hideAllEdgeIndicators()

  layout.on(cstring"dragExternalDrop") do (componentItem: js, claimCallback: js):
    # Always hide indicators when a drag ends.
    hideAllEdgeIndicators()

    # Only claim the drop if the cursor was near an edge during the last
    # dragMove event.
    if not dragNearEdge:
      return

    # Claim the drop so GoldenLayout does not try to revert the component.
    {.emit: "`claimCallback`(true);".}

    let autoHideState = data.ui.autoHide
    if autoHideState.isNil:
      return

    # Extract panel metadata from the dropped componentItem.
    let config = componentItem.toConfig()
    let componentState = config.componentState
    let contentEnum = componentState.content.to(Content)
    let title = if not componentState.label.isNil and not componentState.label.isUndefined:
        componentState.label.to(cstring)
      else:
        cstring($contentEnum)

    let edge = lastDragEdge

    # Add the panel to the auto-hide strip on the detected edge.
    let panel = autoHideState.addPanelAndRefresh(
      edge,
      title,
      icon = cstring"",
      contentEnum,
      cast[JsObject](config)
    )

    # The componentItem has been removed from the GL tree by the drag system.
    # Store the DOM element and the componentItem itself as the detached handle
    # so that restorePanel can re-attach it later.
    panel.detachedElement = cast[Element](componentItem.element)
    panel.detachedHandle = cast[JsObject](componentItem)

  # -------------------------------------------------------------------------
  # M9: Drag-back handler — clean up auto-hide panel after a strip tab is
  # dragged back into the GL layout area.
  # -------------------------------------------------------------------------
  # When a DragSource (registered on strip tabs in auto_hide.nim) is dropped
  # into a GL drop zone, GL creates a fresh component from the config
  # callback.  The ``itemDropped`` event fires after the drop completes.
  # We check the component state for the ``fromAutoHide`` marker and, if
  # present, remove the corresponding panel from the auto-hide strip.

  layout.on(cstring"itemDropped") do (event: js):
    cdebug "layout event: itemDropped"
    let componentItem = event.toJs
    # The event target is the newly created component item.
    if componentItem.isNil or componentItem.isUndefined:
      return

    # Try to read the fromAutoHide marker from the component state.
    var panelId: int = -1
    {.emit: """
      var item = `event`;
      // itemDropped may fire with the event itself being the component, or
      // it may wrap it.  Try both shapes.
      var st = null;
      if (item && item.componentState) {
        st = item.componentState;
      } else if (item && item.target && item.target.componentState) {
        st = item.target.componentState;
      }
      if (st && st.fromAutoHide !== undefined && st.fromAutoHide !== null) {
        `panelId` = st.fromAutoHide;
      }
    """.}

    if panelId >= 0:
      let autoHideState = data.ui.autoHide
      if not autoHideState.isNil:
        # Dismiss any visible overlay for this panel before removing it.
        if not autoHideState.activeOverlay.isNil and
           autoHideState.activeOverlay.id == panelId:
          hideOverlay(autoHideState)
        autoHideState.removePanelAndRefresh(panelId)

    data.ui.saveLayout = true

# Wire the initLayout proc into session_switch to break the circular
# import dependency (layout -> session_tabs -> session_switch -> layout).
setInitLayoutProc(initLayout)

# Wire the tab-bar renderer setup so that switchSession can ensure the
# Karax renderer for ``#session-tab-bar`` exists even when initLayout is
# not called (e.g. for empty sessions).
#
# IMPORTANT: if the renderer already exists (set up by ensureSharedRenderers
# during initLayout), do NOT overwrite it — that would replace the Karax
# instance and break event delegation for the tab bar onclick handlers.
proc ensureTabBarRenderer() =
  if not kxiMap.hasKey(cstring"session-tab-bar"):
    kxiMap["session-tab-bar"] = setRenderer(
      proc: VNode = renderSessionTabs(data),
      "session-tab-bar",
      proc = attachTabClickHandlers(data))
setEnsureTabBarRendererProc(ensureTabBarRenderer)
