import
  asyncjs, strformat, strutils, sequtils, jsffi, algorithm,
  karax, karaxdsl, vstyles,
  ../lib, ../types, ../renderer, ../config, ../ui_helpers,
  state, editor, debug, menu, status, command, search_results, shell

import kdom except Location
import vdom except Event
from dom import Element, getAttribute, Node, preventDefault, document,
                getElementById, querySelectorAll, querySelector

type
  ContextHandler* = proc(tab: js, args: seq[string])

# context handlers for each shortcut
var contextHandlers*: JsAssoc[cstring, JsAssoc[cstring, ContextHandler]] = JsAssoc[cstring, JsAssoc[cstring, ContextHandler]]{}

# SEARCH

proc onSearchSubmit(ev: Event, v: VNode) =
  cast[dom.Event](ev).preventDefault()


const RESULT_LIMIT = 20

const
  STACK_HEIGHT = 200
  STACK_WIDTH = 300

proc updateDefaultDimensions(layout: GoldenLayout) =
  ## Adjust each stack or row/column to have minimum dimensions based on
  ## the number of contained tabs. ``STACK_HEIGHT`` is used for stacks and
  ## ``STACK_WIDTH`` for rows or columns. Additionally update the layout
  ## manager default dimensions to the smallest calculated values.

  if layout.isNil or layout.groundItem.contentItems.len == 0:
    return

  var
    maxStackTabs = 0
    maxRowCols = 0

  proc traverse(item: GoldenContentItem) =
    if item.isStack:
      let tabs = max(1, item.contentItems.len)
      if tabs > maxStackTabs:
        maxStackTabs = tabs
      try:
        item.toJs.config.minHeight = STACK_HEIGHT div tabs
      except:
        cerror "updateDefaultDimensions: failed to set stack height"
    elif not item.isComponent:
      # Rows or columns
      let cols = max(1, item.contentItems.len)
      if cols > maxRowCols:
        maxRowCols = cols
      try:
        item.toJs.config.minWidth = STACK_WIDTH div cols
      except:
        cerror "updateDefaultDimensions: failed to set row/column width"
    for child in item.contentItems:
      traverse(child)

  traverse(layout.groundItem.contentItems[0])

  let newHeight = STACK_HEIGHT div maxStackTabs
  let newWidth = STACK_WIDTH div maxRowCols

  try:
    let lm = layout.toJs.layoutManager
    if not lm.isNil:
      lm.layoutConfig.dimensions.minItemHeight = newHeight
      lm.layoutConfig.dimensions.minItemWidth = newWidth
  except:
    cerror "updateDefaultDimensions: failed to set dimensions"

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

    Mousetrap.`bind`(j(shortcut)) do ():
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

  return (matches.mapIt(it[0].toUpperCase())).join(j" ")

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

# Triage: rename to initGoldenLayout
proc initLayout*(initialLayout: GoldenLayoutResolvedConfig) =

  if data.startOptions.shellUi:
    kxiMap["menu"] = setRenderer(proc: VNode = data.ui.menu.render(), "menu", proc = discard)
    return

  if data.startOptions.welcomeScreen and data.trace.isNil:
    kxiMap["welcome-screen"] =
      setRenderer(
        proc: VNode = data.ui.welcomeScreen.render(),
        "welcomeScreen",
        proc = discard)

    return

  let root = document.getElementById(j"ROOT")

  var layout = newGoldenLayout(
    root,
    proc() = (cdebug "layout: component binded"),
    proc() = (cdebug "layout: component unbinded")
  )

  # Create nested buttons in header
  layout.on(j"stackCreated") do (ev: Event):
    let newElement = kdom.document.createElement("div")
    let hiddenDropdown = vnodeToDom(makeNestedButton(layout, ev), KaraxInstance())
    newElement.classList.add("layout-buttons-container")
    newElement.setAttribute("tabindex", "0")
    newElement.onclick = proc(e: Event) {.nimcall.} =
      let element = cast[kdom.Element](e.target.children[0])

      if element.classList.contains("hidden"):
        element.classList.remove("hidden")
        newElement.classList.add("active")
      else:
        element.classList.add("hidden")
        newElement.classList.remove("active")

      cast[kdom.Element](e.target).focus()

    newElement.onblur = proc(e: Event) {.nimcall.} =
      e.toJs.target.children[0].classList.add("hidden")
      newElement.classList.remove("active")

    let container = ev.toJs.target.element.childNodes[0].childNodes[1]
    let tabContainer = ev.toJs.target.element.childNodes[0].childNodes[0]

    while cast[kdom.Element](container).childNodes.len() > 0:
      container.removeChild(container.childNodes[0])

    newElement.appendChild(hiddenDropdown)
    tabContainer.appendChild(newElement)

  data.ui.layout = layout
  data.ui.layoutConfig = cast[GoldenLayoutConfigClass](window.toJs.LayoutConfig)
  data.ui.contentItemConfig = cast[GoldenLayoutItemConfigClass](window.toJs.ItemConfig)

  kxiMap["menu"] = setRenderer(proc: VNode = data.ui.menu.render(), "menu", proc = discard)
  kxiMap["status"] = setRenderer(proc: VNode = data.ui.status.render(), "status", proc = discard)
  kxiMap["fixed-search"] = setRenderer(fixedSearchView, "fixed-search", proc = discard)
  kxiMap["search-results"] = setRenderer(proc: VNode = data.ui.searchResults.render(), "search-results", proc = discard)

  layout.registerComponent(j"editorComponent") do (container: GoldenContainer, state: GoldenItemState):
    if state.label.len == 0:
      return

    let componentLabel = j(&"editorComponent-{state.id}")

    var element = container.getElement()
    element.innerHTML = cstring(&"<div id={componentLabel} class=\"component-container\"></div>")

    cdebug &"layout: registering editor component {componentLabel}"

    container.on(j"tab") do (tab: GoldenTab):
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
          editorPanel.toJs.on(j"activeContentItemChanged") do (event:  GoldenContentItem):
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

    var containerId: cstring
    containerId = j(&"editorComponent-{state.id}")

    discard windowSetTimeout((proc =
      if not data.ui.componentMapping[state.content][state.id].isNil:
        let component = data.ui.componentMapping[state.content][state.id]

        kxiMap[state.label] = setRenderer(
          (proc: VNode = component.render()),
          containerId,
          proc = discard)

        EditorViewComponent(component).renderer = kxiMap[state.fullPath]

        discard component.afterInit()

      discard windowSetTimeout((proc = redrawAll()), 200)), 200)

  layout.registerComponent(j"genericUiComponent") do (container: GoldenContainer, state: GoldenItemState):
    if state.label.len == 0:
      return
    let editorLabel = state.label
    var element = container.getElement()
    element.innerHTML = cstring(&"<div id={editorLabel} class=\"component-container\"></div>")

    cdebug "layout: register " & state.label

    container.on(j"tab") do (tab: GoldenTab):
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

      tab.setTitle(j(convertTabTitle($state.content)))

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

        if state.content == Content.Shell:
          let shellComponent = ShellComponent(component)
          if shellComponent.shell.isNil:
            shellComponent.createShell()

        discard component.afterInit()
      discard windowSetTimeout((proc = redrawAll()), 200)), 200)

  layout.loadLayout(initialLayout)

  layout.on(cstring"stateChanged") do (event: js):
    cdebug "layout event: stateChanged"

    updateDefaultDimensions(data.ui.layout)

    # check if only one tab is left and prevent user from close/drag it
    let mainContainer = data.ui.layout.groundItem.contentItems[0]
    if mainContainer.contentItems.len == 1 and
      mainContainer.contentItems[0].isStack and
      mainContainer.contentItems[0].contentItems.len == 1 and
      mainContainer.contentItems[0].contentItems[0].isComponent:
      mainContainer.contentItems[0].contentItems[0]
        .tab.element.style.pointerEvents = j"none"
    else:
      let tabElements = jqAll(".lm_tab")
      for element in tabElements:
        element.style.pointerEvents = j"auto"

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
