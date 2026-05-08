import
  asyncjs, strformat, strutils, sequtils, jsffi, algorithm,
  karax, karaxdsl, vstyles,
  state, editor, debug, menu, status, command, search_results, shell, deepreview, session_tabs,
  session_switch, panel_transfer, auto_hide, auto_hide_overlay,
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

proc enforceMinStackWidth*(layout: GoldenLayout) =
  ## Walk every stack in the layout tree and distribute the desired constant
  ## minimum width evenly across its component items so GL's per-component sum
  ## always equals MIN_STACK_PX regardless of how many tabs are open.
  ## SizeUnitEnum.Pixel is the string "px" in GL 2.x.
  {.emit: """
    const MIN_STACK_PX = 150;
    const MIN_STACK_PX_H = 50;
    function visit(item) {
      if (!item || !item.contentItems) return;
      if (item.isStack) {
        const n = item.contentItems.length;
        if (n > 0) {
          const perW = Math.ceil(MIN_STACK_PX / n);
          const perH = Math.ceil(MIN_STACK_PX_H / n);
          for (const ci of item.contentItems) {
            ci.minSize     = `layout`.isColumn ? perH : perW;
            ci.minSizeUnit = "px";
          }
        }
      } else {
        for (const ci of item.contentItems) visit(ci);
      }
    }
    if (`layout`.groundItem) visit(`layout`.groundItem);
  """.}

proc newGoldenLayout*(
  root: JsObject,
  bindComponentCallback: proc,
  unbindComponentCallback: proc
): GoldenLayout {.importjs: "new GoldenLayout(#, #, #)".}

proc convertTabTitle(content: cstring): cstring =
  ## Derive a human-readable uppercase tab title from a Content enum name.
  ## Special-case overrides are listed first; the generic fallback splits
  ## CamelCase into separate uppercase words (e.g. "EventLog" -> "EVENT LOG").
  if content == cstring"BuildErrors":
    return cstring"PROBLEMS"
  if content == cstring"VCS":
    return cstring"VCS"
  if content == cstring"Filesystem":
    return cstring"FILES"

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
    let x = event.clientX.to(int)
    let y = event.clientY.to(int)

    # Use an async wrapper so we can await the window list without relying on
    # Future.then, which is only available on Nim >= 1.5.1.
    proc showWindowMenu() {.async.} =
      let response = await requestWindowList()
      let items = buildSendToWindowMenuItems(contentItem, sessionId, response)
      showContextMenu(items, x, y)

    discard showWindowMenu())

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

proc pinActiveContentItem(layout: js, stack: js, edge: AutoHideEdge) =
  ## Pin the currently active tab in `stack` to the given auto-hide edge.
  ## Uses `getActiveContentItem` to find what to detach.
  let activeItem = stack.getActiveContentItem()
  if activeItem.isNil or activeItem.isUndefined:
    cwarn "auto_hide: no active content item in stack"
    return
  pinPanel(cast[GoldenLayout](layout), cast[GoldenContentItem](activeItem), edge)

proc injectPinButton(tabElement: JsObject, onPin: proc()) =
  ## Insert a pin button to the left of the GL close button inside a tab element.
  ## Clicking it calls `onPin`, which sends the panel to the auto-hide sidebar.
  if tabElement.isNil or tabElement.isUndefined:
    return
  {.emit: """
    var _pinBtn = document.createElement('div');
    _pinBtn.className = 'lm_pin_tab';
    var _closeEl = `tabElement`.querySelector('.lm_close_tab');
    if (_closeEl) {
      `tabElement`.insertBefore(_pinBtn, _closeEl);
    } else {
      `tabElement`.appendChild(_pinBtn);
    }
    var _onPin = `onPin`;
    _pinBtn.addEventListener('click', function(e) {
      e.stopPropagation();
      _onPin();
    });
  """.}

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
    # Auto-hide: pin the active tab to an edge strip.
    tdiv(
      class = "layout-dropdown-node",
      onclick = proc(e: Event, tg: VNode) =
        pinActiveContentItem(layout, ev.toJs.target, AutoHideEdge.Bottom)
    ):
      text "Pin to Bottom"
    tdiv(
      class = "layout-dropdown-node",
      onclick = proc(e: Event, tg: VNode) =
        pinActiveContentItem(layout, ev.toJs.target, AutoHideEdge.Left)
    ):
      text "Pin to Left"
    tdiv(
      class = "layout-dropdown-node",
      onclick = proc(e: Event, tg: VNode) =
        pinActiveContentItem(layout, ev.toJs.target, AutoHideEdge.Right)
    ):
      text "Pin to Right"

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

  # DeepReview mode: uses the normal GL layout path.  The DeepReview-specific
  # layout config (built in onStartDeepReview) includes a Modified Files
  # panel and an empty editor stack.  The DeepReviewComponent is registered
  # as a genericUiComponent and rendered inside the GL container like any
  # other panel.  File selection in the sidebar opens editor tabs via
  # data.openTab with diff decorations applied by the component.

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
      let editorContentItem = cast[GoldenContentItem](tab.contentItem)
      injectPinButton(tab.element, proc() =
        pinPanel(cast[GoldenLayout](layout), editorContentItem, AutoHideEdge.Left))

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
      let genericContentItem = cast[GoldenContentItem](tab.contentItem)
      injectPinButton(tab.element, proc() =
        pinPanel(cast[GoldenLayout](layout), genericContentItem, AutoHideEdge.Left))

    # When a background tab becomes visible, force Karax to redraw into the
    # now-visible DOM element.  Without this, panels like BUILD, PROBLEMS and
    # SEARCH RESULTS stay blank if they were initialised while hidden.
    let label = state.label
    container.on(cstring"show") do ():
      if kxiMap.hasKey(label):
        redrawSync(kxiMap[label])

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

  # Widen the splitter grab zone so it is easier to grab with the mouse.
  # The per-stack minimum width is enforced dynamically by enforceMinStackWidth
  # (called after loadLayout and on every stateChanged) so it stays constant
  # regardless of how many tabs are open in the stack.
  {.emit: """
    if (!`initialLayout`.dimensions) `initialLayout`.dimensions = {};
    `initialLayout`.dimensions.borderGrabWidth = 8;
  """.}
  layout.loadLayout(initialLayout)
  enforceMinStackWidth(layout)

  # M21: Register IPC handler for receiving panels from other windows.
  registerPanelAttachHandler(layout)

  # Auto-hide panes: initialise state and set up the edge strip renderer
  # and overlay event handlers.
  initAutoHideState()
  # When an auto-hide panel's overlay is shown, trigger a Karax redraw
  # for that panel's renderer so standalone panels display current content.
  autoHideState.onPanelShown = proc(panel: AutoHidePanel) =
    # Map Content type to the kxiMap label used by standalone panels.
    let label = case panel.content
      of Content.Build:         cstring"buildComponent-0"
      of Content.BuildErrors:   cstring"errorsComponent-0"
      of Content.SearchResults: cstring"searchResultsComponent-0"
      else:
        # For panels pinned from GL, try the standard label format.
        convertComponentLabel(panel.content, panel.componentId)
    # For standalone auto-hide panels, Karax's setRenderer doesn't work
    # reliably because the element starts in a hidden/offscreen host.
    # Instead, render the component's VNode directly into the container
    # using vnodeToDom, which bypasses Karax's diffing and produces fresh
    # DOM nodes.
    let component = data.ui.componentMapping[panel.content][0]
    if not component.isNil:
      let target = kdom.document.getElementById(label)
      if not target.isNil:
        target.innerHTML = cstring""
        let vnode = component.render()
        let dom = vnodeToDom(vnode, KaraxInstance())
        target.appendChild(dom)
    elif kxiMap.hasKey(label):
      redrawSync(kxiMap[label])

  autoHideState.onChanged = proc() =
    # Re-render the side strip tabs whenever the auto-hide state changes.
    # Left and right strips are separate Karax renderers in the layout row.
    if kxiMap.hasKey(cstring"auto-hide-strip-left"):
      redraw(kxiMap[cstring"auto-hide-strip-left"])
    if kxiMap.hasKey(cstring"auto-hide-strip-right"):
      redraw(kxiMap[cstring"auto-hide-strip-right"])
    # Bottom tabs are rendered inside the status bar; trigger a status redraw.
    if kxiMap.hasKey(cstring"status"):
      redraw(kxiMap[cstring"status"])

  kxiMap["auto-hide-strip-left"] = setRenderer(
    proc: VNode = renderAutoHideLeftStrip(),
    "auto-hide-strip-left",
    proc = discard)

  kxiMap["auto-hide-strip-right"] = setRenderer(
    proc: VNode = renderAutoHideRightStrip(),
    "auto-hide-strip-right",
    proc = discard)

  # Wire overlay header buttons and dismissal handlers.
  setupAutoHideOverlay(layout)

  # Register BUILD, PROBLEMS, and SEARCH RESULTS as standalone auto-hide
  # bottom panes. These panels are not part of the GL layout — they live
  # exclusively in the auto-hide state and appear as clickable labels in
  # the status bar footer.
  #
  # We use a short timeout to run after GL has finished creating all
  # component containers from the layout config. This lets us detect
  # whether these panels exist as GL tabs (from a saved layout that
  # still includes them) and pin them from GL, or create standalone
  # auto-hide panels if they were never in GL (the default layout).
  # Create a hidden container in the DOM to host standalone auto-hide
  # panel elements. Karax's setRenderer requires the target element to
  # be in the DOM (it uses getElementById), so we keep a hidden host.
  # The auto-hide overlay will reparent the wrapper elements when shown.
  var autoHideHost = kdom.document.getElementById(cstring"auto-hide-standalone-host")
  if autoHideHost.isNil:
    autoHideHost = kdom.document.createElement("div")
    autoHideHost.id = cstring"auto-hide-standalone-host"
    # Use offscreen positioning instead of display:none — Karax cannot
    # render into elements with display:none (zero dimensions).
    autoHideHost.style.position = cstring"absolute"
    autoHideHost.style.left = cstring"-9999px"
    autoHideHost.style.width = cstring"1px"
    autoHideHost.style.height = cstring"1px"
    autoHideHost.style.overflow = cstring"hidden"
    kdom.document.body.appendChild(autoHideHost)

  discard windowSetTimeout(proc() =
    type AutoHidePanelDef = tuple
      content: Content
      title: cstring
      label: cstring   ## The component label used as DOM id and kxiMap key

    let standaloneAutoHidePanels: seq[AutoHidePanelDef] = @[
      (content: Content.Build,         title: cstring"BUILD",          label: cstring"buildComponent-0"),
      (content: Content.BuildErrors,   title: cstring"PROBLEMS",       label: cstring"errorsComponent-0"),
      (content: Content.SearchResults, title: cstring"SEARCH RESULTS", label: cstring"searchResultsComponent-0"),
    ]

    let host = kdom.document.getElementById(cstring"auto-hide-standalone-host")

    for panelDef in standaloneAutoHidePanels:
      # Skip if this content is already in the auto-hide state (e.g.
      # restored from a saved layout or previously pinned by the user).
      if not autoHideState.isNil and
         not autoHideState.findPanelByContent(panelDef.content).isNil:
        continue

      # Check if GL created a container for this component (from a saved
      # layout that still includes it). If so, find the GL content item
      # and pin it rather than creating a standalone panel.
      let glContainerDiv = kdom.document.getElementById(panelDef.label)
      if not glContainerDiv.isNil and not glContainerDiv.parentNode.isNil:
        # The component exists in GL. Find its content item by walking
        # up from the component mapping's layoutItem.
        let component = data.ui.componentMapping[panelDef.content][0]
        if not component.isNil and not component.layoutItem.isNil:
          cdebug "auto_hide: pinning GL panel '" & $panelDef.title & "' to bottom auto-hide"
          pinPanel(layout, component.layoutItem, AutoHideEdge.Bottom)
          continue

      # Panel is not in GL — create a standalone auto-hide panel with
      # its own DOM container and Karax renderer.

      # Create a wrapper element that the auto-hide overlay will
      # reparent when the panel is shown. It lives inside the hidden
      # host so that Karax's getElementById call succeeds during
      # setRenderer.
      let wrapper = kdom.document.createElement("div")
      wrapper.id = cstring("auto-hide-standalone-" & $panelDef.label)
      wrapper.class = cstring"auto-hide-standalone-container"
      wrapper.style.width = cstring"100%"
      wrapper.style.height = cstring"100%"

      # Inner div matching the component label id that the Karax
      # renderer expects (same as the GL container would create).
      let innerDiv = kdom.document.createElement("div")
      innerDiv.id = panelDef.label
      innerDiv.class = cstring"component-container"
      wrapper.appendChild(innerDiv)

      # Attach to the hidden host so setRenderer can find the element.
      if not host.isNil:
        host.appendChild(wrapper)

      # Look up the singleton component from the mapping and set up a
      # Karax renderer only if GL did not already create one.
      let component = data.ui.componentMapping[panelDef.content][0]
      if not component.isNil and not kxiMap.hasKey(panelDef.label):
        kxiMap[panelDef.label] = setRenderer(
          (proc: VNode = component.render()),
          panelDef.label,
          proc = discard)
        component.kxi = kxiMap[panelDef.label]

      addStandaloneAutoHidePanel(
        panelDef.title,
        panelDef.content,
        componentId = 0,
        liveElement = wrapper,
        edge = AutoHideEdge.Bottom)
  , 500)  # 500ms delay lets GL finish its internal layout cycle

  # Expose redrawAll on window so E2E tests can trigger Karax re-renders
  # after injecting data into component state.
  # Also expose a helper to re-render a specific auto-hide panel by content ID.
  # Expose helper functions on window for E2E tests.
  proc renderAutoHidePanelById(contentId: int) =
    ## Re-render a standalone auto-hide panel by content ID.
    ## Uses vnodeToDom to bypass Karax's broken hidden-host rendering.
    let labels = [
      (11, cstring"buildComponent-0"),
      (21, cstring"errorsComponent-0"),
      (20, cstring"searchResultsComponent-0"),
    ]
    for (cid, label) in labels:
      if contentId == cid:
        let component = data.ui.componentMapping[Content(cid)][0]
        if not component.isNil:
          let target = kdom.document.getElementById(label)
          if not target.isNil:
            target.innerHTML = cstring""
            let vnode = component.render()
            let dom = vnodeToDom(vnode, KaraxInstance())
            target.appendChild(dom)
        break

  # Expose a helper to pin a GL content item to an auto-hide edge.
  # Used by E2E tests to bypass the dropdown UI which has blur race issues.
  # Edge: 0 = Left, 1 = Right, 2 = Bottom.
  proc pinContentItemToEdge(contentItemJs: js, edgeInt: int) =
    let edge = AutoHideEdge(edgeInt)
    let contentItem = cast[GoldenContentItem](contentItemJs)
    pinPanel(layout, contentItem, edge)

  # Expose a helper to create a new session tab.
  # Used by E2E tests because the "+" button is hidden when only one
  # session exists (the tab bar in the caption bar has `display: none`
  # via `.single-session`).
  proc createNewSessionHelper() =
    createNewSession(data)

  # Force collapsed mode on/off for E2E tests.  Bypasses maximize
  # detection so tests can capture collapsed-mode screenshots without
  # actually maximizing the window.
  proc forceCollapsedMode(enable: bool) =
    if autoHideState.isNil:
      initAutoHideState()
    autoHideState.collapsedMode = enable
    autoHideState.leftBounded = enable
    autoHideState.rightBounded = enable
    if not autoHideState.onChanged.isNil:
      autoHideState.onChanged()

  # Render side-edge tabs into the overlay's side-tab container.
  # Called from onPanelShown and whenever the overlay edge changes.
  proc renderOverlaySideTabs() =
    let container = kdom.document.getElementById(cstring"auto-hide-overlay-side-tabs")
    if container.isNil:
      return
    container.innerHTML = cstring""
    let vnode = renderOverlaySideEdgeTabs()
    let dom = vnodeToDom(vnode, KaraxInstance())
    container.appendChild(dom)

  # Wire onPanelShown to also render side-edge tabs.
  let originalOnPanelShown = autoHideState.onPanelShown
  autoHideState.onPanelShown = proc(panel: AutoHidePanel) =
    if not originalOnPanelShown.isNil:
      originalOnPanelShown(panel)
    renderOverlaySideTabs()

  {.emit: """
    window.__ctRedrawAll = function() {
      `redrawAll`();
    };
    window.__ctRenderPanel = function(contentId) {
      `renderAutoHidePanelById`(contentId);
    };
    window.__ctPinPanel = function(contentItemJs, edgeInt) {
      `pinContentItemToEdge`(contentItemJs, edgeInt);
    };
    window.__ctCreateNewSession = function() {
      `createNewSessionHelper`();
    };
    window.__ctForceCollapsedMode = function(enable) {
      `forceCollapsedMode`(enable);
    };
  """.}

  # ---------------------------------------------------------------------------
  # Maximize detection for collapsed-mode auto-hide strips.
  # When the window is maximized and an edge is bounded (no adjacent monitor),
  # side strips collapse to a 1px accent line.
  # ---------------------------------------------------------------------------
  proc updateCollapsedMode() =
    ## Check if the window is maximized and update collapsed mode.
    ## Each edge is evaluated independently for adjacent monitors.
    ## This is a simplified check — full multi-monitor detection requires
    ## Electron's screen API (done via IPC in main process).
    ## For now, we use a heuristic: if outerWidth ~= screen.availWidth
    ## and outerHeight ~= screen.availHeight, the window is maximized.
    {.emit: """
      var isMax = (window.outerWidth >= screen.availWidth - 8) &&
                  (window.outerHeight >= screen.availHeight - 8);
    """.}
    var isMax {.importc, nodecl.}: bool
    if not autoHideState.isNil:
      let wasCollapsed = autoHideState.collapsedMode
      autoHideState.collapsedMode = isMax
      # Simplified bounded-edge detection: when maximized, assume both
      # left and right edges are bounded.  Full multi-monitor detection
      # via Electron's screen API is a future enhancement.
      autoHideState.leftBounded = isMax
      autoHideState.rightBounded = isMax
      if wasCollapsed != isMax:
        if not autoHideState.onChanged.isNil:
          autoHideState.onChanged()

  # Check on initial load and on window resize/maximize.
  discard windowSetTimeout(proc() = updateCollapsedMode(), 1000)
  {.emit: """
    window.addEventListener('resize', function() {
      `updateCollapsedMode`();
    });
  """.}

  layout.on(cstring"stateChanged") do (event: js):
    cdebug "layout event: stateChanged"
    enforceMinStackWidth(layout)

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

      # Persist auto-hide panel state alongside the GL layout config.
      # The auto-hide state is saved as a separate IPC message so that
      # the existing config loading path does not need modification.
      let autoHideSerialized = serializeAutoHideState()
      if not autoHideSerialized.isNil and not autoHideSerialized.isUndefined:
        ipc.send "CODETRACER::save-auto-hide-state", js{
          state: JSON.stringify(autoHideSerialized)
        }

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
