import
  asyncjs, strformat, strutils, sequtils, jsffi, algorithm,
  karax, karaxdsl, vstyles,
  state, editor, debug, menu, status, command, search_results, shell, deepreview, session_tabs, build, errors, step_list,
  welcome_screen,
  calltrace_editor, repl, low_level_code, request_panel, trace_log, scratchpad, filesystem,
  vcs,
  agent_activity, agent_activity_deepreview, agent_workspace,
  session_switch, panel_transfer, auto_hide, auto_hide_overlay,
  caption_bar_progress,
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

proc pinActiveContentItem(layout: js, stack: js, edge: AutoHideEdge) =
  ## Pin the currently active tab in `stack` to the given auto-hide edge.
  ## Uses `getActiveContentItem` to find what to detach.
  let activeItem = stack.getActiveContentItem()
  if activeItem.isNil or activeItem.isUndefined:
    cwarn "auto_hide: no active content item in stack"
    return
  pinPanel(cast[GoldenLayout](layout), cast[GoldenContentItem](activeItem), edge)

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

  # remove component karax instance (only for components that still use Karax,
  # e.g. editor tabs — IsoNim GL components no longer have kxiMap entries)
  let label = convertComponentLabel(content, id)
  if kxiMap.hasKey(label):
    discard jsDelete(kxiMap[label])

  # remove component from open components registry from the same content type (if there is any)
  if data.ui.openComponentIds[content].find(id) != -1:
    data.ui.openComponentIds[content].delete(id)

# Track whether the shared (non-GL) Karax renderers have been initialised.
# These renderers (menu, status, fixed-search, search-results, session-tab-bar)
# live outside the per-session GL container and only need to be set up once.
var sharedRenderersInitialised = false

proc renderLayoutComponent(component: Component, content: Content): VNode =
  ## Render the remaining live Karax-backed GoldenLayout components.
  ## IsoNim-owned panels must be handled by their direct mount path instead of
  ## falling back to generic Component.render dispatch.
  if content == Content.EditorView:
    EditorViewComponent(component).renderEditor()
  elif content == Content.VCS:
    VCSComponent(component).renderVCS()
  else:
    buildHtml(tdiv())

proc ensureSharedRenderers() =
  ## Set up the Karax renderers for global chrome elements that live outside
  ## individual session GL containers.  Safe to call multiple times — it only
  ## acts on the first invocation.
  if sharedRenderersInitialised:
    return
  sharedRenderersInitialised = true

  kxiMap["menu"] = setRenderer(
    proc: VNode =
      if not data.ui.menu.isNil: data.ui.menu.renderMenu()
      else: buildHtml(tdiv()),
    "menu", proc = discard)
  kxiMap["status"] = setRenderer(
    proc: VNode =
      if not data.ui.status.isNil: data.ui.status.renderStatus()
      else: buildHtml(tdiv()),
    "status", proc = discard)
  kxiMap["fixed-search"] = setRenderer(fixedSearchView, "fixed-search", proc = discard)
  kxiMap["search-results"] = setRenderer(
    proc: VNode =
      buildHtml(tdiv()),
    "search-results", proc = discard)
  # Session tab bar: render via IsoNim WebRenderer. The Karax
  # renderSessionTabs returns an empty stub; explicit session/trace
  # mutation sites refresh the direct IsoNim mount.
  kxiMap["session-tab-bar"] = setRenderer(
    proc: VNode = renderSessionTabs(data),
    "session-tab-bar",
    proc = discard)
  # Initial render after Karax creates the container element.
  discard windowSetTimeout(proc() = requestSessionTabsRender(data), 50)

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
    kxiMap["menu"] = setRenderer(proc: VNode = data.ui.menu.renderMenu(), "menu", proc = discard)
    data.ui.menu.kxi = kxiMap["menu"]
    return

  # DeepReview mode: uses the normal GL layout path.  The DeepReview-specific
  # layout config (built in onStartDeepReview) includes a Modified Files
  # panel and an empty editor stack.  The DeepReviewComponent is registered
  # as a genericUiComponent and rendered inside the GL container like any
  # other panel.  File selection in the sidebar opens editor tabs via
  # data.openTab with diff decorations applied by the component.

  if data.startOptions.welcomeScreen and data.trace.isNil:
    clog "initLayout: mounting IsoNim welcome screen"
    if not data.ui.welcomeScreen.isNil:
      data.ui.welcomeScreen.syncLegacyWelcomeScreenIntoVM()
    welcome_screen.tryMountIsoNimWelcomeScreen()
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

    var containerId: cstring
    containerId = cstring(fmt"editorComponent-{state.id}")

    discard windowSetTimeout((proc =
      if not data.ui.componentMapping[state.content][state.id].isNil:
        let component = data.ui.componentMapping[state.content][state.id]

        kxiMap[state.label] = setRenderer(
          (proc: VNode = EditorViewComponent(component).renderEditor()),
          containerId,
          proc = discard)
        component.kxi = kxiMap[state.label]

        EditorViewComponent(component).renderer = kxiMap[state.fullPath]

        discard component.afterInit()

      ), 200)

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

    # IsoNim-migrated components mount directly into the GoldenLayout
    # container — no Karax setRenderer needed. Other components still
    # use Karax rendering.
    let isIsoNimComponent = state.content in {
      Content.Calltrace,
      Content.State,
      Content.EventLog,
      Content.Timeline,
      Content.Build,
      Content.BuildErrors,
      Content.SearchResults,
      Content.Shell,
      Content.CaptionBarProgress,
      Content.TerminalOutput,
      Content.StepList,
      Content.CalltraceEditor,
      Content.Repl,
      Content.LowLevelCode,
      Content.RequestPanel,
      Content.TraceLog,
      Content.Scratchpad,
      Content.Filesystem,
      Content.CommandPalette,
      Content.DeepReview,
      Content.AgentActivity,
      Content.AgentActivityDeepReview,
      Content.AgentWorkspace,
    }

    # When a background tab becomes visible, force Karax to redraw into the
    # now-visible DOM element. Only needed for non-IsoNim components that
    # still use Karax rendering.
    if not isIsoNimComponent:
      let label = state.label
      container.on(cstring"show") do ():
        if kxiMap.hasKey(label):
          redrawSync(kxiMap[label])

    var containerId: cstring
    containerId = state.label

    discard windowSetTimeout((proc =
      if not data.ui.componentMapping[state.content][state.id].isNil:
        let component = data.ui.componentMapping[state.content][state.id]

        if not isIsoNimComponent:
          kxiMap[state.label] = setRenderer(
            (proc: VNode = renderLayoutComponent(component, state.content)),
            containerId,
            proc = discard
          )
          component.kxi = kxiMap[state.label]

        if state.content == Content.Shell:
          let shellComponent = ShellComponent(component)
          if shellComponent.shell.isNil:
            discard shellComponent.createShell()

        # Build is now an IsoNim view — its DOM is mounted by
        # `build.tryMountIsoNimBuildPanel` against the `buildComponent-{id}`
        # container, and reactive effects keep it in sync. No direct-DOM
        # redraw hook is needed here.
        if state.content == Content.Build:
          # The IsoNim view mounts itself once `buildComponentRef` and
          # the VM are both available (the registration order between
          # `register()` and `configureMiddleware` is non-deterministic
          # under different layouts).  Calling tryMount here is safe and
          # idempotent — it short-circuits when already mounted.  Also
          # sync any data the legacy ``build`` record already carries
          # (e.g. when the GL container appears after a recorded build
          # already finished).
          build.syncLegacyBuildIntoVM(BuildComponent(component))
          build.tryMountIsoNimBuildPanel()

        # BuildErrors is now an IsoNim view -- its DOM is mounted by
        # ``errors.tryMountIsoNimErrorsPanel`` against the
        # ``errorsComponent-{id}`` container, and reactive effects keep
        # it in sync. No direct-DOM redraw hook is
        # needed here.
        if state.content == Content.BuildErrors:
          errors.syncLegacyErrorsIntoVM(ErrorsComponent(component))
          errors.tryMountIsoNimErrorsPanel()

        # SearchResults is now an IsoNim view -- its DOM is mounted by
        # ``search_results.tryMountIsoNimSearchResultsPanel`` against
        # the ``searchResultsComponent-{id}`` container, and reactive
        # effects keep it in sync. No direct-DOM redraw hook is needed here.
        if state.content == Content.SearchResults:
          search_results.syncLegacySearchResultsIntoVM(SearchResultsComponent(component))
          search_results.tryMountIsoNimSearchResultsPanel()

        # StepList is now an IsoNim view -- its DOM is mounted by
        # ``step_list.tryMountIsoNimStepListPanel`` against the
        # ``stepListComponent-{id}`` container, and reactive effects
        # keep it in sync. No direct-DOM redraw hook is needed here.
        if state.content == Content.StepList:
          step_list.syncLegacyStepListIntoVM(StepListComponent(component))
          step_list.tryMountIsoNimStepListPanel()

        # CalltraceEditor is now an IsoNim view -- its DOM is mounted
        # by ``calltrace_editor.tryMountIsoNimCalltraceEditorPanel``
        # against the GoldenLayout-managed ``<div id="calls">``
        # container.  The panel is single-instance and the legacy
        # render produced an empty placeholder, so there is no
        # legacy state to sync into the VM.
        if state.content == Content.CalltraceEditor:
          calltrace_editor.tryMountIsoNimCalltraceEditorPanel()

        # Repl is now an IsoNim view -- its DOM is mounted by
        # ``repl.tryMountIsoNimReplPanel`` against the
        # ``replComponent-{id}`` container, and reactive effects
        # keep it in sync. No direct-DOM redraw hook is needed here.
        if state.content == Content.Repl:
          repl.syncLegacyReplIntoVM(ReplComponent(component))
          repl.syncReplConfigIntoVM()
          repl.tryMountIsoNimReplPanel()

        # LowLevelCode is now an IsoNim view -- its outer container
        # is mounted by ``low_level_code.tryMountIsoNimLowLevelCodePanel``
        # against the ``lowLevelCodeComponent-{id}`` GoldenLayout host,
        # and reactive effects keep it in sync.  The Monaco-driven
        # asm buffer still lives inside the editor sub-tree (the
        # EditorViewComponent owns that DOM); the IsoNim view here
        # exposes the parity-faithful container shell + a fallback
        # row list so headless tests can exercise the same data flow
        # without Monaco.  Closes the no_source asm sub-tree
        # follow-up tracked from 1.40.
        if state.content == Content.LowLevelCode:
          low_level_code.syncLegacyLowLevelCodeIntoVM(
            LowLevelCodeComponent(component))
          low_level_code.tryMountIsoNimLowLevelCodePanel()

        # RequestPanel is now an IsoNim view -- its DOM is mounted by
        # ``request_panel.tryMountIsoNimRequestPanel`` against the
        # ``requestPanelComponent-{id}`` container, and reactive
        # effects keep it in sync. No direct-DOM redraw hook is needed here.
        # The legacy ``RequestPanelComponent``
        # remains as the event-bus carrier (M6 will subscribe to
        # ``CtUpdatedHttpRequests``) and its mutators feed the VM via
        # ``syncLegacyRequestPanelIntoVM`` so the IsoNim view tracks
        # any rows already accumulated when the panel becomes visible.
        if state.content == Content.RequestPanel:
          request_panel.syncLegacyRequestPanelIntoVM(
            RequestPanelComponent(component))
          request_panel.tryMountIsoNimRequestPanel()

        # TraceLog is now an IsoNim view -- its DOM is mounted by
        # ``trace_log.tryMountIsoNimTraceLogPanel`` against the
        # ``traceLogComponent-{id}`` container, and reactive effects
        # keep it in sync. No direct-DOM redraw hook is needed here.
        # The legacy ``TraceLogComponent`` remains
        # as the event-bus carrier (its ``register`` method still
        # subscribes to tracepoint-result events) and
        # ``syncLegacyTraceLogIntoVM`` mirrors any rows already
        # accumulated when the panel becomes visible.
        if state.content == Content.TraceLog:
          trace_log.syncLegacyTraceLogIntoVM(TraceLogComponent(component))
          trace_log.tryMountIsoNimTraceLogPanel()

        # Scratchpad is now an IsoNim view -- its DOM is mounted by
        # ``scratchpad.tryMountIsoNimScratchpadPanel`` against the
        # ``scratchpadComponent-{id}`` container, and reactive effects
        # keep it in sync. No direct-DOM redraw hook is needed here.
        # The legacy ``ScratchpadComponent`` remains
        # as the event-bus carrier (its ``register`` method still
        # subscribes to ``InternalAddToScratchpad`` /
        # ``InternalAddToScratchpadFromExpression`` /
        # ``CtLoadLocalsResponse``) and ``syncLegacyScratchpadIntoVM``
        # mirrors any rows already accumulated when the panel becomes
        # visible.  Mission goal #3 §1.70.
        if state.content == Content.Scratchpad:
          scratchpad.syncLegacyScratchpadIntoVM(
            ScratchpadComponent(component))
          scratchpad.tryMountIsoNimScratchpadPanel()

        # Filesystem is now an IsoNim view -- its DOM is mounted by
        # ``filesystem.tryMountIsoNimFilesystemPanel`` against the
        # ``filesystemComponent-{id}`` container, and reactive effects
        # keep it in sync. No direct-DOM redraw hook is
        # needed here.  The legacy ``FilesystemComponent`` remains as
        # the event-bus carrier (its existing event handlers populate
        # ``data.services.editor.filesystem``) and
        # ``syncLegacyFilesystemIntoVM`` mirrors any tree already
        # accumulated when the panel becomes visible.  Mission goal #3
        # \u00a71.71.  The rich jstree affordances (animated open/close,
        # contextmenu plugin, search plugin) remain a follow-up.
        if state.content == Content.Filesystem:
          filesystem.syncLegacyFilesystemIntoVM(
            FilesystemComponent(component))
          filesystem.tryMountIsoNimFilesystemPanel()

        # CommandPalette is now an IsoNim view -- its DOM is mounted by
        # ``command.tryMountIsoNimCommandPalettePanel`` against the
        # ``commandPaletteComponent-{id}`` container, and reactive
        # effects keep it in sync. No direct-DOM redraw hook is needed here.
        # The legacy
        # ``CommandPaletteComponent`` remains as the event-bus carrier
        # (the keyboard / interpreter / agent passthrough) and
        # ``syncLegacyCommandPaletteIntoVM`` mirrors any state already
        # accumulated when the panel becomes visible.  Mission goal #3
        # \u00a71.72.  The rich per-kind row rendering paths
        # (program-search HTML fragment, symbol-kind suffix, file-path
        # tail truncation, agent-mode passthrough) remain a follow-up.
        if state.content == Content.CommandPalette:
          command.syncLegacyCommandPaletteIntoVM(
            CommandPaletteComponent(component))
          command.tryMountIsoNimCommandPalettePanel()

        if state.content == Content.DeepReview:
          deepreview.syncLegacyDeepReviewIntoVM(
            DeepReviewComponent(component))
          deepreview.tryMountIsoNimDeepReviewPanel(component.id)

        if state.content == Content.AgentActivity:
          agent_activity.syncLegacyAgentActivityIntoVM(
            AgentActivityComponent(component))
          agent_activity.tryMountIsoNimAgentActivityPanel(component.id)

        # AgentActivityDeepReview is now an IsoNim view -- its DOM
        # is mounted by
        # ``agent_activity_deepreview.tryMountIsoNimAgentActivityDeepReviewPanel``
        # against the ``agentActivityDeepReviewComponent-{id}``
        # container, and reactive effects keep it in sync.  No
        # direct-DOM redraw hook is needed here. The
        # legacy ``AgentActivityDeepReviewComponent`` remains as the
        # event-bus carrier (the ``IPC_DEEPREVIEW_NOTIFICATION``
        # handler keeps populating ``self.fileEntries`` /
        # ``self.recentNotifications``) and
        # ``syncLegacyAgentActivityDeepReviewIntoVM`` mirrors any
        # rows already accumulated when the panel becomes visible.
        # Mission goal #3 \u00a71.73.  The rich per-row affordances
        # (per-file coverage bar, per-notification colour pills,
        # the "Functions" summary card) remain a follow-up.
        if state.content == Content.AgentActivityDeepReview:
          agent_activity_deepreview.syncLegacyAgentActivityDeepReviewIntoVM(
            AgentActivityDeepReviewComponent(component))
          agent_activity_deepreview.tryMountIsoNimAgentActivityDeepReviewPanel()

        if state.content == Content.AgentWorkspace:
          agent_workspace.syncLegacyAgentWorkspaceIntoVM(
            AgentWorkspaceComponent(component))
          agent_workspace.tryMountIsoNimAgentWorkspacePanel(component.id)

        # CaptionBarProgress: render via IsoNim WebRenderer directly
        # into the GL container. Progress and hover mutation paths refresh
        # this direct mount explicitly.
        if state.content == Content.CaptionBarProgress:
          tryMountCaptionBarProgress(
            containerId,
            CaptionBarProgressComponent(component))

        discard component.afterInit()

        # Non-IsoNim components need an explicit redrawAll() after
        # setRenderer to trigger the initial Karax render.
        if not isIsoNimComponent:
          discard windowSetTimeout(proc() = redrawAll(), 200)
      ), 200)

  layout.loadLayout(initialLayout)

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
    # DOM nodes.  The Build panel is now an IsoNim view: re-mount it
    # against the visible label so the reactive root attaches inside
    # the container that the auto-hide overlay just made visible.
    if panel.content == Content.Build:
      let buildComp = data.ui.componentMapping[Content.Build][0]
      if not buildComp.isNil:
        build.syncLegacyBuildIntoVM(BuildComponent(buildComp))
      build.isoNimBuildMounted = false
      build.tryMountIsoNimBuildPanel()
      return
    if panel.content == Content.BuildErrors:
      let errorsComp = data.ui.componentMapping[Content.BuildErrors][0]
      if not errorsComp.isNil:
        errors.syncLegacyErrorsIntoVM(ErrorsComponent(errorsComp))
      errors.isoNimErrorsMounted = false
      errors.tryMountIsoNimErrorsPanel()
      return
    if panel.content == Content.SearchResults:
      let srComp = data.ui.componentMapping[Content.SearchResults][0]
      if not srComp.isNil:
        search_results.syncLegacySearchResultsIntoVM(SearchResultsComponent(srComp))
      search_results.isoNimSearchResultsMounted = false
      search_results.tryMountIsoNimSearchResultsPanel()
      return
    let component = data.ui.componentMapping[panel.content][0]
    if not component.isNil:
      let target = kdom.document.getElementById(label)
      if not target.isNil:
        target.innerHTML = cstring""
        let vnode = renderLayoutComponent(component, panel.content)
        let dom = vnodeToDom(vnode, KaraxInstance())
        target.appendChild(dom)
    elif kxiMap.hasKey(label):
      redrawSync(kxiMap[label])

  autoHideState.onChanged = proc() =
    # Re-render the side strip tabs whenever the auto-hide state changes.
    # Left and right strip hosts are static DOM nodes in the layout row; their
    # contents and sizing classes are now refreshed through IsoNim directly.
    requestAutoHideSideStripRender(
      cstring"auto-hide-strip-left",
      AutoHideEdge.Left)
    requestAutoHideSideStripRender(
      cstring"auto-hide-strip-right",
      AutoHideEdge.Right)
    # Bottom tabs are rendered inside the status bar; trigger a status redraw.
    if kxiMap.hasKey(cstring"status"):
      redraw(kxiMap[cstring"status"])

  requestAutoHideSideStripRender(
    cstring"auto-hide-strip-left",
    AutoHideEdge.Left)
  requestAutoHideSideStripRender(
    cstring"auto-hide-strip-right",
    AutoHideEdge.Right)

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
      # its own DOM container. Build/BuildErrors/SearchResults are now
      # IsoNim-migrated and mount via the IsoNim reactive root, so they
      # need no redraw hook.

      # Create a wrapper element that the auto-hide overlay will
      # reparent when the panel is shown.
      let wrapper = kdom.document.createElement("div")
      wrapper.id = cstring("auto-hide-standalone-" & $panelDef.label)
      wrapper.class = cstring"auto-hide-standalone-container"
      wrapper.style.width = cstring"100%"
      wrapper.style.height = cstring"100%"

      # Inner div matching the component label id.
      let innerDiv = kdom.document.createElement("div")
      innerDiv.id = panelDef.label
      innerDiv.class = cstring"component-container"
      wrapper.appendChild(innerDiv)

      # Attach to the hidden host so getElementById can find the element.
      if not host.isNil:
        host.appendChild(wrapper)

      # All three standalone auto-hide panels (Build, BuildErrors,
      # SearchResults) are now IsoNim views.  Each mounts itself
      # against the inner div the next time its ``tryMountIsoNim*``
      # runs; the reactive root keeps the DOM in sync automatically.
      if panelDef.content == Content.Build:
        try:
          let buildComp = data.ui.componentMapping[Content.Build][0]
          if not buildComp.isNil:
            build.syncLegacyBuildIntoVM(BuildComponent(buildComp))
          build.isoNimBuildMounted = false
          build.tryMountIsoNimBuildPanel()
        except:
          cerror "auto_hide: tryMountIsoNimBuildPanel(standalone) EXCEPTION: " & getCurrentExceptionMsg()
      elif panelDef.content == Content.BuildErrors:
        try:
          let errorsComp = data.ui.componentMapping[Content.BuildErrors][0]
          if not errorsComp.isNil:
            errors.syncLegacyErrorsIntoVM(ErrorsComponent(errorsComp))
          errors.isoNimErrorsMounted = false
          errors.tryMountIsoNimErrorsPanel()
        except:
          cerror "auto_hide: tryMountIsoNimErrorsPanel(standalone) EXCEPTION: " & getCurrentExceptionMsg()
      elif panelDef.content == Content.SearchResults:
        try:
          let srComp = data.ui.componentMapping[Content.SearchResults][0]
          if not srComp.isNil:
            search_results.syncLegacySearchResultsIntoVM(SearchResultsComponent(srComp))
          search_results.isoNimSearchResultsMounted = false
          search_results.tryMountIsoNimSearchResultsPanel()
        except:
          cerror "auto_hide: tryMountIsoNimSearchResultsPanel(standalone) EXCEPTION: " & getCurrentExceptionMsg()
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
    ## Build, BuildErrors, and SearchResults are all IsoNim views:
    ## sync any legacy state (E2E tests inject directly into
    ## ``build.output`` / ``build.problems`` / search service results)
    ## into the VM and then re-mount.
    if contentId == int(Content.Build):
      let buildComp = data.ui.componentMapping[Content.Build][0]
      if not buildComp.isNil:
        build.syncLegacyBuildIntoVM(BuildComponent(buildComp))
      build.isoNimBuildMounted = false
      build.tryMountIsoNimBuildPanel()
      return
    if contentId == int(Content.BuildErrors):
      # ``syncLegacyBuildIntoVM`` already pushed the bulk-replay path
      # for the Build panel into both ``BuildVM`` and ``ErrorsVM``;
      # explicitly re-syncing here covers the case where E2E tests
      # call ``__ctRenderPanel(21)`` after mutating
      # ``build.problems`` directly without re-rendering the Build
      # panel first.
      let errorsComp = data.ui.componentMapping[Content.BuildErrors][0]
      if not errorsComp.isNil:
        errors.syncLegacyErrorsIntoVM(ErrorsComponent(errorsComp))
      errors.isoNimErrorsMounted = false
      errors.tryMountIsoNimErrorsPanel()
      return
    if contentId == int(Content.SearchResults):
      let srComp = data.ui.componentMapping[Content.SearchResults][0]
      if not srComp.isNil:
        search_results.syncLegacySearchResultsIntoVM(SearchResultsComponent(srComp))
      search_results.isoNimSearchResultsMounted = false
      search_results.tryMountIsoNimSearchResultsPanel()
      return

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
    requestOverlaySideEdgeTabsRender(cstring"auto-hide-overlay-side-tabs")

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

# Wire the tab-bar renderer setup so that switchSession can ensure and refresh
# the direct IsoNim mount for ``#session-tab-bar`` even when initLayout is not
# called (e.g. for empty sessions).
#
# IMPORTANT: if the renderer already exists (set up by ensureSharedRenderers
# during initLayout), do NOT overwrite it — that would replace the Karax
# instance while the surrounding chrome is alive.
proc ensureTabBarRenderer() =
  if not kxiMap.hasKey(cstring"session-tab-bar"):
    kxiMap["session-tab-bar"] = setRenderer(
      proc: VNode = renderSessionTabs(data),
      "session-tab-bar",
      proc = discard)
  requestSessionTabsRender(data)
  # Use a short delay as a fallback for paths where the Karax shell has just
  # been registered and the DOM element may not be ready until the next tick.
  discard windowSetTimeout(proc() = requestSessionTabsRender(data), 50)
setEnsureTabBarRendererProc(ensureTabBarRenderer)
