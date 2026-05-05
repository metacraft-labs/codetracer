## test_isonim_views.nim
##
## Unit tests for the IsoNim DOM-rendering State panel view.
##
## Verifies that `renderStatePanel` produces the correct MockNode tree
## and that reactive updates (tab switching, variable list changes,
## loading state) propagate to the DOM automatically.
##
## Uses MockRenderer for headless testing — no browser required.
##
## Compile and run:
##   nim c -r src/frontend/viewmodel/tests/test_isonim_views.nim

import std/[unittest, strutils, tables, options, sets, json]
import vm_test_helpers
import isonim/core/[signals, computation, owner]
import isonim/testing/mock_dom
import backend/backend_service
import backend/mock_backend
import store/types
import store/replay_data_store
import viewmodels/state_vm
import viewmodels/calltrace_vm
import viewmodels/debug_controls_vm
import viewmodels/event_log_vm
import viewmodels/flow_vm
import viewmodels/timeline_vm
import viewmodels/search_vm
import viewmodels/point_list_vm
import viewmodels/scratchpad_vm
import viewmodels/shell_vm
import viewmodels/terminal_output_vm
import viewmodels/build_vm
import viewmodels/errors_vm
import viewmodels/search_results_vm
import viewmodels/no_source_vm
import viewmodels/step_list_vm
import viewmodels/calltrace_editor_vm
import viewmodels/repl_vm
import viewmodels/low_level_code_vm
import viewmodels/request_panel_vm
import viewmodels/trace_log_vm except NO_SELECTED_INDEX
import viewmodels/filesystem_vm
import viewmodels/command_palette_vm
import viewmodels/agent_activity_vm
import viewmodels/agent_activity_deepreview_vm
import viewmodels/agent_workspace_vm
import viewmodels/deepreview_vm
import viewmodels/vcs_vm
import viewmodels/welcome_screen_vm
import viewmodels/editor_vm
import app/isonim_app_shell
import views/isonim_state_view
import views/isonim_calltrace_view
import views/isonim_debug_controls_view
import views/isonim_event_log_view
import views/isonim_flow_view
import views/isonim_timeline_view
import views/isonim_search_view
import views/isonim_point_list_view
import views/isonim_scratchpad_view
import views/isonim_shell_view
import views/isonim_terminal_output_view
import views/isonim_build_view
import views/isonim_errors_view
import views/isonim_search_results_view
import views/isonim_no_source_view
import views/isonim_step_list_view
import views/isonim_calltrace_editor_view
import views/isonim_repl_view
import views/isonim_low_level_code_view
import views/isonim_request_panel_view
import views/isonim_trace_log_view
import views/isonim_filesystem_view
import views/isonim_command_palette_view
import views/isonim_agent_activity_view
import views/isonim_agent_activity_deepreview_view
import views/isonim_agent_workspace_view
import views/isonim_deepreview_view
import views/isonim_vcs_view
import views/isonim_welcome_screen_view
import views/isonim_session_tabs_view
import views/isonim_debug_shell_view
import views/isonim_auto_hide_overlay_tabs_view
import views/isonim_auto_hide_collapsed_icons_view
import views/isonim_auto_hide_bottom_tabs_view
import views/isonim_auto_hide_side_strip_view
import views/isonim_status_view
import views/isonim_menu_shell_view
import views/isonim_editor_view

# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------


proc makeStoreWithMock(autoRespond: bool = true):
    tuple[store: ReplayDataStore, mock: MockBackendService] =
  let mock = newMockBackendService(autoRespond = autoRespond)
  let store = createReplayDataStore(mock.toBackendService())
  (store, mock)

proc findByClass*(node: MockNode; cls: string): MockNode =
  ## Find the first descendant (or self) whose "class" attribute
  ## contains `cls` as a whole word. Returns nil if not found.
  if node.kind == mnkElement:
    let nodeClass = node.attributes.getOrDefault("class", "")
    # Check if cls appears as a whole word in the class attribute.
    for part in nodeClass.split(' '):
      if part == cls:
        return node
  for child in node.children:
    let found = findByClass(child, cls)
    if found != nil:
      return found
  return nil

proc findById*(node: MockNode; id: string): MockNode =
  ## Find the first descendant (or self) with the given id.
  if node.kind == mnkElement and node.attributes.getOrDefault("id", "") == id:
    return node
  for child in node.children:
    let found = findById(child, id)
    if found != nil:
      return found
  return nil

suite "IsoNim Editor Panel - structure":

  test "top-level editor keeps legacy editorComponent host id":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEditorVM(store)
      let r = MockRenderer()

      let panel = renderEditorPanel(
        r,
        vm,
        index = 7,
        path = "src/main.nim",
        isExpansion = false,
        expansionDepth = 0)

      check panel.attributes["id"] == "editorComponent-7"
      check panel.attributes["class"] == "editor code-editor tab"
      check panel.attributes["data-label"] == "src/main.nim"
      check panel.attributes["tabindex"] == "2"

      dispose()

  test "expanded editor can reuse Monaco view-zone host id":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEditorVM(store)
      let r = MockRenderer()

      let panel = renderEditorPanel(
        r,
        vm,
        index = 8,
        path = "expanded-42",
        isExpansion = true,
        expansionDepth = 2,
        hostId = "expanded-42")

      check panel.attributes["id"] == "expanded-42"
      check panel.attributes["class"] == "editor code-editor tab expansion expansion-2"
      check panel.attributes["data-label"] == "expanded-42"
      check panel.attributes["tabindex"] == "2"

      dispose()

proc findAllByClass*(node: MockNode; cls: string): seq[MockNode] =
  ## Find all descendants (including self) whose "class" attribute
  ## contains `cls` as a whole word.
  if node.kind == mnkElement:
    let nodeClass = node.attributes.getOrDefault("class", "")
    for part in nodeClass.split(' '):
      if part == cls:
        result.add(node)
        break
  for child in node.children:
    result.add(findAllByClass(child, cls))

proc findByTag*(node: MockNode; tag: string): MockNode =
  ## Find the first descendant (or self) with the given tag name.
  if node.kind == mnkElement and node.tag == tag:
    return node
  for child in node.children:
    let found = findByTag(child, tag)
    if found != nil:
      return found
  return nil

suite "IsoNim Debug Shell — structure":

  test "renders static debug host with command palette mount":
    let r = MockRenderer()
    let panel = renderDebugChromePanel(r, commandPaletteComponentId = 7)

    check panel.attributes["id"] == DebugShellId
    check panel.attributes["class"] == DebugShellClass
    let host = findByClass(panel, DebugCommandPaletteHostClass)
    check host != nil
    check host.attributes["id"] == commandPaletteHostId(7)

  test "omits command palette mount until the component exists":
    let r = MockRenderer()
    let panel = renderDebugChromePanel(r, commandPaletteComponentId = -1)

    check panel.attributes["id"] == DebugShellId
    check findByClass(panel, DebugCommandPaletteHostClass).isNil

suite "IsoNim Auto-hide Overlay Tabs — structure":

  test "hidden state renders only the hidden container":
    let r = MockRenderer()
    let panel = renderAutoHideOverlayTabsPanel(
      r,
      tabs = @[],
      visible = false,
      edgeClass = "")

    check panel.attributes["class"] == AutoHideOverlayTabsHiddenClass
    check panel.children.len == 0

  test "left edge renders sibling tabs with active modifier":
    let r = MockRenderer()
    let panel = renderAutoHideOverlayTabsPanel(
      r,
      tabs = @[
        AutoHideOverlayTabRecord(title: "FILES", active: true),
        AutoHideOverlayTabRecord(title: "CALLTRACE", active: false)
      ],
      visible = true,
      edgeClass = " side-tabs-left")

    check panel.attributes["class"] == AutoHideOverlayTabsLeftClass
    check panel.children.len == 2
    check panel.children[0].attributes["class"] == AutoHideOverlayTabActiveClass
    check panel.children[0].textContent == "FILES"
    check panel.children[1].attributes["class"] == AutoHideOverlayTabClass
    check panel.children[1].textContent == "CALLTRACE"

  test "select callback receives tab index":
    let r = MockRenderer()
    var selected = -1
    let panel = renderAutoHideOverlayTabsPanel(
      r,
      tabs = @[
        AutoHideOverlayTabRecord(title: "STATE", active: false),
        AutoHideOverlayTabRecord(title: "EVENT LOG", active: true)
      ],
      visible = true,
      edgeClass = " side-tabs-right",
      callbacks = AutoHideOverlayTabsCallbacks(
        onSelect: proc(index: int) = selected = index))

    check panel.attributes["class"] == AutoHideOverlayTabsRightClass
    panel.children[0].fireEvent("click")
    check selected == 0

suite "IsoNim Auto-hide Collapsed Icons — structure":

  test "empty state renders only the base icon-zone container":
    let r = MockRenderer()
    let panel = renderAutoHideCollapsedIconsPanel(r, icons = @[])

    check panel.attributes["class"] == AutoHideCollapsedIconZoneClass
    check panel.children.len == 0

  test "icons render titles and has-icons modifier":
    let r = MockRenderer()
    let panel = renderAutoHideCollapsedIconsPanel(
      r,
      icons = @[
        AutoHideCollapsedIconRecord(icon: "F", title: "FILES"),
        AutoHideCollapsedIconRecord(icon: "S", title: "STATE")
      ])

    check panel.attributes["class"] == AutoHideCollapsedIconZoneWithIconsClass
    check panel.children.len == 2
    check panel.children[0].attributes["class"] == AutoHideCollapsedIconClass
    check panel.children[0].attributes["title"] == "FILES"
    check panel.children[0].textContent == "F"
    check panel.children[1].attributes["title"] == "STATE"
    check panel.children[1].textContent == "S"

  test "select callback receives icon index":
    let r = MockRenderer()
    var selected = -1
    let panel = renderAutoHideCollapsedIconsPanel(
      r,
      icons = @[
        AutoHideCollapsedIconRecord(icon: "C", title: "CALLTRACE"),
        AutoHideCollapsedIconRecord(icon: "E", title: "EVENT LOG")
      ],
      callbacks = AutoHideCollapsedIconCallbacks(
        onSelect: proc(index: int) = selected = index))

    panel.children[1].fireEvent("click")
    check selected == 1

suite "IsoNim Auto-hide Bottom Tabs — structure":

  test "empty state renders the bottom-tabs host without tab children":
    let r = MockRenderer()
    let panel = renderAutoHideBottomTabsPanel(r, tabs = @[])

    check panel.attributes["class"] == AutoHideBottomTabsClass
    check panel.children.len == 0

  test "bottom tabs render strip-tab selector contract and titles":
    let r = MockRenderer()
    let panel = renderAutoHideBottomTabsPanel(
      r,
      tabs = @[
        AutoHideBottomTabRecord(title: "BUILD"),
        AutoHideBottomTabRecord(title: "PROBLEMS"),
        AutoHideBottomTabRecord(title: "SEARCH RESULTS")
      ])

    check panel.attributes["class"] == AutoHideBottomTabsClass
    check panel.children.len == 3
    check panel.children[0].attributes["class"] == AutoHideBottomTabClass
    check panel.children[0].textContent == "BUILD"
    check panel.children[1].textContent == "PROBLEMS"
    check panel.children[2].textContent == "SEARCH RESULTS"

  test "select callback receives bottom tab index":
    let r = MockRenderer()
    var selected = -1
    let panel = renderAutoHideBottomTabsPanel(
      r,
      tabs = @[
        AutoHideBottomTabRecord(title: "BUILD"),
        AutoHideBottomTabRecord(title: "SEARCH RESULTS")
      ],
      callbacks = AutoHideBottomTabsCallbacks(
        onSelect: proc(index: int) = selected = index))

    panel.children[1].fireEvent("click")
    check selected == 1

suite "IsoNim Auto-hide Side Strips — structure":

  test "empty expanded strip has no sizing class and no tab children":
    let r = MockRenderer()
    let panel = renderAutoHideSideStripPanel(
      r,
      tabs = @[],
      collapsed = false)

    check panel.attributes["class"] == ""
    check panel.children.len == 0

  test "expanded strip renders strip tabs and select callback":
    let r = MockRenderer()
    var selected = -1
    let panel = renderAutoHideSideStripPanel(
      r,
      tabs = @[
        AutoHideSideStripRecord(title: "FILES"),
        AutoHideSideStripRecord(title: "CALLTRACE")
      ],
      collapsed = false,
      callbacks = AutoHideSideStripCallbacks(
        onSelect: proc(index: int) = selected = index))

    check panel.attributes["class"] == AutoHideSideStripHasTabsClass
    check panel.children.len == 2
    check panel.children[0].attributes["class"] == AutoHideSideStripTabClass
    check panel.children[0].textContent == "FILES"
    check panel.children[1].textContent == "CALLTRACE"

    panel.children[1].fireEvent("click")
    check selected == 1

  test "collapsed strip renders only the collapsed click line":
    let r = MockRenderer()
    var clicked = false
    let panel = renderAutoHideSideStripPanel(
      r,
      tabs = @[AutoHideSideStripRecord(title: "FILES")],
      collapsed = true,
      callbacks = AutoHideSideStripCallbacks(
        onCollapsedSelect: proc() = clicked = true))

    check panel.attributes["class"] == AutoHideSideStripCollapsedClass
    check panel.children.len == 1
    check panel.children[0].attributes["class"] == AutoHideCollapsedStripLineClass
    check panel.children[0].textContent == ""

    panel.children[0].fireEvent("click")
    check clicked

suite "IsoNim Status Shell — structure":

  proc baseStatusModel(): StatusShellModel =
    StatusShellModel(
      base: StatusBaseModel(
        language: "Nim",
        encoding: "UTF-8",
        processClass: "ready-status",
        processText: "stable: ready",
        showTestMovement: true,
        testMovementText: "7",
        showDisconnected: true,
        disconnectedText: "Disconnected",
        disconnectedTitle: "Lost connection to the host.",
        showFinished: false,
        locationText: "/tmp/main.nim:12#44",
        locationTitle: "/tmp/main.nim:12#44",
        copyTooltipActive: true))

  test "renders status base hosts and right-side location state":
    let r = MockRenderer()
    let panel = renderStatusShell(r, baseStatusModel())

    check panel.attributes["class"] == StatusRootClass
    check findByClass(panel, CollapsedIconZoneClass).attributes["id"] ==
      CollapsedIconZoneHostId
    check findByClass(panel, BottomTabsClass).attributes["id"] ==
      BottomTabsHostId
    check findByClass(panel, "file-info-status-language").textContent == "Nim"
    check findByClass(panel, "file-info-status-encoding").textContent == "UTF-8"
    check findByClass(panel, "test-movement").textContent == "7"
    check findByClass(panel, "disconnected-status").textContent == "Disconnected"
    check findByClass(panel, "location-path").textContent == "/tmp/main.nim:12#44"
    check findByClass(panel, "custom-tooltip").attributes["class"] ==
      "custom-tooltip active"

  test "active notification callbacks preserve dismiss and action indices":
    let r = MockRenderer()
    var dismissed = -1
    var actionHit = (-1, -1)
    let model = StatusShellModel(
      activeNotifications: @[
        StatusNotificationRecord(
          index: 3,
          kindClass: "warning",
          variantClass: "primary",
          text: "Reconnect?",
          dismissible: true,
          actions: @[StatusNotificationActionRecord(label: "Retry")])
      ],
      base: StatusBaseModel())
    let panel = renderStatusShell(
      r,
      model,
      StatusShellCallbacks(
        onDismissNotification: proc(index: int) = dismissed = index,
        onNotificationAction: proc(index: int; actionIndex: int) =
          actionHit = (index, actionIndex)))

    let dismissButton = findByClass(panel, "dismiss-notification-button")
    let actionButton = findByClass(panel, "notification-action-button")
    check dismissButton != nil
    check actionButton != nil
    if not dismissButton.isNil:
      dismissButton.fireEvent("click")
    if not actionButton.isNil:
      actionButton.fireEvent("click")

    check dismissed == 3
    check actionHit == (3, 0)

  test "notification history renders newest-first records from model":
    let r = MockRenderer()
    let model = StatusShellModel(
      showNotifications: true,
      notificationHistory: @[
        StatusNotificationRecord(
          index: 2,
          kindClass: "error",
          variantClass: "secondary",
          text: "second",
          dismissible: false),
        StatusNotificationRecord(
          index: 1,
          kindClass: "info",
          variantClass: "secondary",
          text: "first",
          dismissible: false)
      ],
      base: StatusBaseModel())
    let panel = renderStatusShell(r, model)
    let messages = findAllByClass(panel, "notification-message")

    check findByClass(panel, "status-notification-header").textContent ==
      "NOTIFICATIONS:"
    check messages.len == 2
    check messages[0].textContent == "second"
    check messages[1].textContent == "first"

suite "IsoNim Menu Shell — structure":

  proc menuNode(
      name: string;
      path: seq[int];
      kind: MenuNodeRecordKind = MenuRecordElement;
      enabled: bool = true;
      shortcut: string = "";
      nodeClass: string = ""): MenuNodeRecord =
    MenuNodeRecord(
      kind: kind,
      name: name,
      shortcut: shortcut,
      enabled: enabled,
      iconClass: name.toLowerAscii,
      nameClass: "menu-element-" & name.toLowerAscii,
      nodeClass: nodeClass,
      path: path,
      nameWidth: name.len + 1)

  test "hidden menu renders root trigger and window controls only":
    let r = MockRenderer()
    let panel = renderMenuShell(
      r,
      MenuShellModel(
        showNavigation: true,
        active: false,
        rootNodes: @[menuNode("File", @[0], kind = MenuRecordFolder)],
        showWindowMenu: true,
        maximized: false))

    check panel.attributes["class"] == MenuShellRootClass
    check findById(panel, NavigationMenuId) != nil
    check findById(panel, MenuRootId) != nil
    check findById(panel, "menu-logo-img") != nil
    check findById(panel, DebugShellId) != nil
    check findById(panel, "isonim-debug-controls") != nil
    check panel.children[0].attributes["id"] == NavigationMenuId
    check panel.children[1].attributes["id"] == "isonim-debug-controls"
    check panel.children[2].attributes["id"] == DebugShellId
    check findByClass(panel, WindowMenuClass) != nil
    check findByClass(panel, "maximize") != nil
    check findByClass(panel, "restore").isNil
    check findAllByClass(panel, "menu-node").len == 0

  test "caption bar hosts survive without navigation menu":
    let r = MockRenderer()
    let panel = renderMenuShell(
      r,
      MenuShellModel(
        showNavigation: false,
        active: false,
        showWindowMenu: false))

    check findById(panel, NavigationMenuId).isNil
    check findById(panel, DebugShellId) != nil
    check findById(panel, "isonim-debug-controls") != nil
    check findByClass(panel, WindowMenuClass).isNil

  test "visible menu renders search host, root nodes, and window restore":
    let r = MockRenderer()
    let panel = renderMenuShell(
      r,
      MenuShellModel(
        showNavigation: true,
        active: true,
        rootNodes: @[
          menuNode("File", @[0], kind = MenuRecordFolder,
            nodeClass = "menu-active-node"),
          menuNode("Run", @[1], shortcut = "CTRL+R")
        ],
        showWindowMenu: true,
        maximized: true))

    check findByClass(panel, "menu-active-node") != nil
    check findAllByClass(panel, "menu-node").len == 2
    check findById(panel, DebugShellId).attributes["class"] == DebugShellClass
    check findById(panel, "isonim-debug-controls") != nil
    check findByClass(panel, "menu-node-shortcut").textContent == "CTRL+R"
    check findByClass(panel, "restore") != nil
    check findByClass(panel, "maximize").isNil

  test "shell UI model can render menu without window controls":
    let r = MockRenderer()
    let panel = renderMenuShell(
      r,
      MenuShellModel(
        showNavigation: true,
        active: true,
        rootNodes: @[menuNode("Shell", @[0], kind = MenuRecordFolder)],
        showWindowMenu: false))

    check findByClass(panel, WindowMenuClass).isNil
    check findById(panel, DebugShellId) != nil
    check findById(panel, "isonim-debug-controls") != nil
    check findByClass(panel, "menu-folder").textContent.contains("Shell")

  test "caption shell keeps chrome hosts when menu nodes are unavailable":
    ## Regression guard for welcome / newly-created empty sessions: the caption
    ## bar must still provide the CodeTracer logo/menu trigger, command-palette
    ## host, and debugger-toolbar host before the menu model has populated its
    ## root menu tree. Earlier tests only covered populated trace sessions, so a
    ## blank New Trace tab could lose the shared chrome without being detected.
    let r = MockRenderer()
    let panel = renderMenuShell(
      r,
      MenuShellModel(
        showNavigation: true,
        active: false,
        rootNodes: @[],
        showWindowMenu: true,
        maximized: false))

    let navigation = findById(panel, NavigationMenuId)
    let logo = findById(panel, "menu-logo-img")
    let debugHost = findById(panel, DebugShellId)
    let toolbarHost = findById(panel, "isonim-debug-controls")

    check navigation != nil
    check logo != nil
    check debugHost != nil
    check debugHost.attributes["class"] == DebugShellClass
    check toolbarHost != nil
    check findByClass(panel, WindowMenuClass) != nil

suite "IsoNim Session Tabs — structure":

  test "single session uses hidden modifier and renders add button":
    let r = MockRenderer()
    let panel = renderSessionTabsPanel(
      r,
      @[SessionTabRecord(label: "main.py")],
      activeIndex = 0)

    check panel.attributes["id"] == SessionTabBarId
    check panel.attributes["class"] == SessionTabBarSingleClass
    check findAllByClass(panel, SessionTabClass).len == 1
    check findByClass(panel, SessionTabAddClass).textContent == "+"
    check panel.textContent.contains("main.py")

  test "multiple sessions mark the active tab and show close buttons":
    let r = MockRenderer()
    let panel = renderSessionTabsPanel(
      r,
      @[
        SessionTabRecord(label: "Trace 1"),
        SessionTabRecord(label: "server.rb")
      ],
      activeIndex = 1)

    check panel.attributes["class"] == SessionTabBarClass
    let tabs = findAllByClass(panel, SessionTabClass)
    check tabs.len == 2
    check tabs[0].attributes["class"] == SessionTabClass
    check tabs[1].attributes["class"] == SessionTabActiveClass
    check findAllByClass(panel, SessionTabCloseClass).len == 2
    check panel.textContent.contains("server.rb")

  test "click callbacks receive selected, closed, and add actions":
    var selected: seq[int] = @[]
    var closed: seq[int] = @[]
    var addCount = 0
    let callbacks = SessionTabsCallbacks(
      onSelect: proc(index: int) = selected.add(index),
      onClose: proc(index: int) = closed.add(index),
      onAdd: proc() = inc addCount)
    let r = MockRenderer()
    let panel = renderSessionTabsPanel(
      r,
      @[
        SessionTabRecord(label: "Trace 1"),
        SessionTabRecord(label: "Trace 2")
      ],
      activeIndex = 0,
      callbacks = callbacks)

    let tabs = findAllByClass(panel, SessionTabClass)
    let closeButtons = findAllByClass(panel, SessionTabCloseClass)
    let addButton = findByClass(panel, SessionTabAddClass)

    tabs[1].fireEvent("click")
    closeButtons[0].fireEvent("click")
    addButton.fireEvent("click")

    check selected == @[1]
    check closed == @[0]
    check addCount == 1

  test "helper class functions preserve legacy CSS contract":
    check tabBarClass(0) == SessionTabBarSingleClass
    check tabBarClass(1) == SessionTabBarSingleClass
    check tabBarClass(2) == SessionTabBarClass
    check tabClass(false) == SessionTabClass
    check tabClass(true) == SessionTabActiveClass

proc findAllByTag*(node: MockNode; tag: string): seq[MockNode] =
  ## Find all descendants (including self) with the given tag name.
  if node.kind == mnkElement and node.tag == tag:
    result.add(node)
  for child in node.children:
    result.add(findAllByTag(child, tag))

# ---------------------------------------------------------------------------
# Structure tests
# ---------------------------------------------------------------------------

suite "IsoNim State Panel — structure":

  test "renders root with state-component class":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      let r = MockRenderer()

      let panel = renderStatePanel(r, vm)

      check panel.kind == mnkElement
      check panel.tag == "div"
      check "component-container" in panel.attributes["class"]
      check "active-state" in panel.attributes["class"]
      check "state-component" in panel.attributes["class"]

      dispose()

  test "renders three tab buttons":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      let r = MockRenderer()

      let panel = renderStatePanel(r, vm)

      let tabBar = findByClass(panel, "state-tabs")
      check tabBar != nil
      check tabBar.tag == "div"

      let localsBtn = findByClass(panel, "tab-locals")
      let globalsBtn = findByClass(panel, "tab-globals")
      let watchesBtn = findByClass(panel, "tab-watches")

      check localsBtn != nil
      check globalsBtn != nil
      check watchesBtn != nil

      check localsBtn.tag == "button"
      check globalsBtn.tag == "button"
      check watchesBtn.tag == "button"

      # Locals tab should have the "active" class by default
      check "active" in localsBtn.attributes["class"]
      check "active" notin globalsBtn.attributes["class"]
      check "active" notin watchesBtn.attributes["class"]

      dispose()

  test "renders variable list container":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      let r = MockRenderer()

      let panel = renderStatePanel(r, vm)

      let container = findByClass(panel, "value-components-container")
      check container != nil
      check container.tag == "div"

      dispose()

  test "renders loading indicator (hidden by default)":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      drain()  # flush auto-load effect's loading→idle transition
      let r = MockRenderer()

      let panel = renderStatePanel(r, vm)

      let indicator = findByClass(panel, "loading-indicator")
      check indicator != nil
      check indicator.styles.getOrDefault("display", "none") == "none"

      dispose()

  test "renders watch input container (hidden by default)":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      let r = MockRenderer()

      let panel = renderStatePanel(r, vm)

      let watchContainer = findByClass(panel, "watch-input-container")
      check watchContainer != nil
      check watchContainer.styles.getOrDefault("display", "none") == "none"

      dispose()

# ---------------------------------------------------------------------------
# Tab switching tests
# ---------------------------------------------------------------------------

suite "IsoNim State Panel — tab switching":

  test "clicking globals tab updates active class":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      let r = MockRenderer()

      let panel = renderStatePanel(r, vm)

      let globalsBtn = findByClass(panel, "tab-globals")
      check globalsBtn != nil
      globalsBtn.fireEvent("click")

      check vm.activeTab.val == stGlobals

      # Active class should have moved
      check "active" in globalsBtn.attributes["class"]

      let localsBtn = findByClass(panel, "tab-locals")
      check "active" notin localsBtn.attributes["class"]

      dispose()

  test "clicking watches tab shows watch input":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      let r = MockRenderer()

      let panel = renderStatePanel(r, vm)

      let watchesBtn = findByClass(panel, "tab-watches")
      check watchesBtn != nil
      watchesBtn.fireEvent("click")

      check vm.activeTab.val == stWatches

      let watchContainer = findByClass(panel, "watch-input-container")
      check watchContainer != nil
      check watchContainer.styles["display"] == "block"

      dispose()

  test "switching back to locals hides watch input":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      let r = MockRenderer()

      let panel = renderStatePanel(r, vm)

      # Go to watches
      let watchesBtn = findByClass(panel, "tab-watches")
      watchesBtn.fireEvent("click")

      let watchContainer = findByClass(panel, "watch-input-container")
      check watchContainer.styles["display"] == "block"

      # Go back to locals
      let localsBtn = findByClass(panel, "tab-locals")
      localsBtn.fireEvent("click")

      check watchContainer.styles["display"] == "none"

      dispose()

# ---------------------------------------------------------------------------
# Variable rendering tests
# ---------------------------------------------------------------------------

suite "IsoNim State Panel — variables":

  test "renders local variables":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      let r = MockRenderer()

      store.updateLocals(@[
        makeVariable("x", "42", "int"),
        makeVariable("y", "hello", "string"),
      ])

      let panel = renderStatePanel(r, vm)
      let container = findByClass(panel, "value-components-container")
      check container != nil

      # Rows use the Karax-compatible "value-expanded" class
      let rows = findAllByClass(container, "value-expanded")
      check rows.len == 2

      # Check first variable content
      let firstText = rows[0].textContent
      check "x" in firstText
      check "42" in firstText
      check "int" in firstText

      # Check second variable content
      let secondText = rows[1].textContent
      check "y" in secondText
      check "hello" in secondText

      dispose()

  test "variables update reactively when store changes":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      let r = MockRenderer()

      let panel = renderStatePanel(r, vm)

      # Initially no variables — use value-expanded class to find rows
      let container = findByClass(panel, "value-components-container")
      check findAllByClass(container, "value-expanded").len == 0

      # Add variables
      store.updateLocals(@[
        makeVariable("count", "7", "int"),
      ])

      let rows1 = findAllByClass(container, "value-expanded")
      check rows1.len == 1
      check "count" in rows1[0].textContent
      check "7" in rows1[0].textContent

      # Update variables
      store.updateLocals(@[
        makeVariable("count", "8", "int"),
        makeVariable("name", "\"world\"", "string"),
      ])

      let rows2 = findAllByClass(container, "value-expanded")
      check rows2.len == 2
      check "8" in rows2[0].textContent
      check "name" in rows2[1].textContent

      dispose()

  test "switching to globals shows global variables":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      let r = MockRenderer()

      store.updateLocals(@[
        makeVariable("localVar", "1", "int"),
      ])
      store.locals.globals.val = @[
        Variable(name: "globalVar", value: "99", typeName: "int",
                 hasChildren: false, children: @[]),
      ]

      let panel = renderStatePanel(r, vm)

      # Initially shows locals
      let container = findByClass(panel, "value-components-container")
      let localRows = findAllByClass(container, "value-expanded")
      check localRows.len == 1
      check "localVar" in localRows[0].textContent

      # Switch to globals
      vm.selectTab(stGlobals)

      let globalRows = findAllByClass(container, "value-expanded")
      check globalRows.len == 1
      check "globalVar" in globalRows[0].textContent

      dispose()

  test "expanded variable shows children":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      let r = MockRenderer()

      store.updateLocals(@[
        makeVariable("obj", "{...}", "MyObj",
          hasChildren = true,
          children = @[
            makeVariable("field1", "10", "int"),
            makeVariable("field2", "20", "int"),
          ]),
      ])

      let panel = renderStatePanel(r, vm)
      let container = findByClass(panel, "value-components-container")

      # Initially collapsed: only the parent row
      let rows1 = findAllByClass(container, "value-expanded")
      check rows1.len == 1

      # Expand
      vm.toggleExpand("obj")

      # Now should show parent + 2 children = 3 rows
      let rows2 = findAllByClass(container, "value-expanded")
      check rows2.len == 3
      check "obj" in rows2[0].textContent
      check "field1" in rows2[1].textContent
      check "field2" in rows2[2].textContent

      dispose()

# ---------------------------------------------------------------------------
# Loading state tests
# ---------------------------------------------------------------------------

suite "IsoNim State Panel — loading":

  test "loading indicator becomes visible when loading":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      drain()  # flush auto-load effect's loading→idle transition
      let r = MockRenderer()

      let panel = renderStatePanel(r, vm)
      let indicator = findByClass(panel, "loading-indicator")

      check indicator.styles["display"] == "none"

      store.locals.loadingState.val = lsLoading
      check indicator.styles["display"] == "block"

      store.locals.loadingState.val = lsIdle
      check indicator.styles["display"] == "none"

      dispose()

# ---------------------------------------------------------------------------
# Text content tests
# ---------------------------------------------------------------------------

suite "IsoNim State Panel — text content":

  test "tab buttons have correct text":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      let r = MockRenderer()

      let panel = renderStatePanel(r, vm)

      let localsBtn = findByClass(panel, "tab-locals")
      let globalsBtn = findByClass(panel, "tab-globals")
      let watchesBtn = findByClass(panel, "tab-watches")

      check localsBtn.textContent == "Locals"
      check globalsBtn.textContent == "Globals"
      check watchesBtn.textContent == "Watches"

      dispose()

  test "loading indicator shows Loading text":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      let r = MockRenderer()

      let panel = renderStatePanel(r, vm)
      let indicator = findByClass(panel, "loading-indicator")

      check indicator.textContent == "Loading..."

      dispose()

  test "watch input has placeholder":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      let r = MockRenderer()

      let panel = renderStatePanel(r, vm)
      let input = findByClass(panel, "watch-input")

      check input != nil
      check input.attributes["placeholder"] == "Add watch expression..."

      dispose()

# ---------------------------------------------------------------------------
# Code-state-line tests
#
# The legacy Karax ``StateComponent.excerpt`` proc rendered a
# ``#code-state-line-{id}`` element above the variables list with text
# "<line> | <sourceCode>" (or empty + ``no-code`` class when source
# was unavailable).  Several Playwright tests assert this element's
# presence / text — the IsoNim view must emit the same DOM contract.
# ---------------------------------------------------------------------------

suite "IsoNim State Panel — code-state-line":

  proc findCodeStateLine(panel: MockNode): MockNode =
    ## Walk the rendered tree looking for the ``code-state-line``
    ## div regardless of whether it carries the ``no-code`` modifier.
    let populated = findByClass(panel, "code-state-line")
    if populated != nil:
      return populated
    # Fall back: when the element only carries the ``no-code``
    # modifier the ``findByClass`` whole-word match still succeeds
    # because both classes are present, but be defensive in case
    # someone tweaks the markup.
    findByClass(panel, "no-code")

  test "renders #code-state-line-0 element regardless of trace state":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      let r = MockRenderer()

      let panel = renderStatePanel(r, vm)

      let line = findCodeStateLine(panel)
      check line != nil
      check line.attributes["id"] == "code-state-line-0"

      dispose()

  test "starts in no-code state when source is empty":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      let r = MockRenderer()

      let panel = renderStatePanel(r, vm)
      let line = findCodeStateLine(panel)

      # Initial value: empty string → no-code class is present.
      check "no-code" in line.attributes["class"]
      # Inner span is empty so the legacy "no source loaded yet"
      # behaviour is preserved — the element is in the DOM but its
      # text content is empty.
      check line.textContent == ""

      dispose()

  test "DB-trace move populates #code-state-line-0 with formatted text":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      let r = MockRenderer()

      let panel = renderStatePanel(r, vm)
      let line = findCodeStateLine(panel)

      # Simulate the DB-trace move handler in ``state.nim``: it pushes
      # the resolved source-line into the store. The view must update
      # reactively (matching the wasm_example "state panel loaded
      # initially" GUI assertion which waits for the text).
      store.updateCodeStateLine(11, "let x = 3;")

      # After the update the element no longer carries the ``no-code``
      # modifier and its text matches the legacy ``excerpt`` markup.
      check "no-code" notin line.attributes["class"]
      check "code-state-line" in line.attributes["class"]
      check line.textContent == "11 | let x = 3;"
      # Mirrors the Playwright assertion shape: the test waits for
      # ``${ENTRY_LINE} | `` to appear in the locator's text.
      check "11 | " in line.textContent

      dispose()

  test "code-state-line text falls back to no-code when source clears":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      let r = MockRenderer()

      let panel = renderStatePanel(r, vm)
      let line = findCodeStateLine(panel)

      store.updateCodeStateLine(10, "fn main() {")
      check "no-code" notin line.attributes["class"]
      check line.textContent == "10 | fn main() {"

      # Editor unloaded / source no longer available — fall back to
      # the no-code state so the element is still present in the DOM.
      store.updateCodeStateLine(10, "")
      check "no-code" in line.attributes["class"]
      check line.textContent == ""

      dispose()

# ===========================================================================
# Calltrace panel tests
# ===========================================================================

# ---------------------------------------------------------------------------
# Calltrace helpers
# ---------------------------------------------------------------------------

proc makeTestCallLine(index: int64; name: string; depth: int = 0;
                      rrTicks: uint64 = 100; file: string = "test.nim";
                      line: int = 1; callKey: string = ""): CallLine =
  CallLine(
    index: index,
    name: name,
    depth: depth,
    rrTicks: rrTicks,
    location: Location(file: file, line: line),
    callKey: callKey,
  )

# ---------------------------------------------------------------------------
# Calltrace structure tests
# ---------------------------------------------------------------------------

suite "IsoNim Calltrace Panel — structure":

  test "renders root with calltrace-component class":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      let r = MockRenderer()

      let panel = renderCalltracePanel(r, vm)

      check panel.kind == mnkElement
      check panel.tag == "div"
      check panel.attributes["class"] == "calltrace-component"

      dispose()

  test "renders scroll indicators":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      let r = MockRenderer()

      let panel = renderCalltracePanel(r, vm)

      let moreAbove = findByClass(panel, "more-above")
      let moreBelow = findByClass(panel, "more-below")

      check moreAbove != nil
      check moreBelow != nil

      # Both hidden by default (scroll at 0, no data)
      check moreAbove.styles.getOrDefault("display", "none") == "none"
      check moreBelow.styles.getOrDefault("display", "none") == "none"

      dispose()

  test "renders calltrace lines container":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      let r = MockRenderer()

      let panel = renderCalltracePanel(r, vm)

      let container = findByClass(panel, "calltrace-lines")
      check container != nil
      check container.tag == "div"

      dispose()

  test "renders search input":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      let r = MockRenderer()

      let panel = renderCalltracePanel(r, vm)

      let input = findByClass(panel, "calltrace-search-input")
      check input != nil
      check input.attributes["placeholder"] == "Search calltrace..."

      dispose()

  test "renders loading indicator (hidden by default)":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      drain()  # flush auto-load effect's loading→idle transition
      let r = MockRenderer()

      let panel = renderCalltracePanel(r, vm)

      let indicator = findByClass(panel, "calltrace-loading")
      check indicator != nil
      check indicator.styles.getOrDefault("display", "none") == "none"

      dispose()

# ---------------------------------------------------------------------------
# Calltrace call line rendering tests
# ---------------------------------------------------------------------------

suite "IsoNim Calltrace Panel — call lines":

  test "renders visible lines":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      let r = MockRenderer()

      store.updateCalltraceSection(
        @[
          makeTestCallLine(0, "main", depth = 0),
          makeTestCallLine(1, "foo", depth = 1),
          makeTestCallLine(2, "bar", depth = 2),
        ],
        startIndex = 0'i64,
        totalCount = 3'u64,
      )

      # Set viewport height so lines are visible
      vm.setViewportHeight(10)

      let panel = renderCalltracePanel(r, vm)
      let container = findByClass(panel, "calltrace-lines")
      check container != nil

      let rows = findAllByClass(container, "calltrace-call-line")
      check rows.len == 3

      check "main" in rows[0].textContent
      check "foo" in rows[1].textContent
      check "bar" in rows[2].textContent

      dispose()

  test "depth indentation via padding-left":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      let r = MockRenderer()

      store.updateCalltraceSection(
        @[
          makeTestCallLine(0, "main", depth = 0),
          makeTestCallLine(1, "inner", depth = 3),
        ],
        startIndex = 0'i64,
        totalCount = 2'u64,
      )

      vm.setViewportHeight(10)

      let panel = renderCalltracePanel(r, vm)
      let container = findByClass(panel, "calltrace-lines")
      let rows = findAllByClass(container, "calltrace-call-line")
      check rows.len == 2

      # depth 0 => "0px", depth 3 => "48px"
      check rows[0].styles["padding-left"] == "0px"
      check rows[1].styles["padding-left"] == "48px"

      dispose()

  test "click selects entry":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      let r = MockRenderer()

      store.updateCalltraceSection(
        @[
          makeTestCallLine(0, "main", depth = 0),
          makeTestCallLine(1, "foo", depth = 1),
        ],
        startIndex = 0'i64,
        totalCount = 2'u64,
      )

      vm.setViewportHeight(10)

      let panel = renderCalltracePanel(r, vm)
      let container = findByClass(panel, "calltrace-lines")
      let rows = findAllByClass(container, "calltrace-call-line")

      check vm.selectedEntry.val.isNone

      # Click the second row
      rows[1].fireEvent("click")

      check vm.selectedEntry.val.isSome
      check vm.selectedEntry.val.get == 1'i64

      dispose()

  test "selected entry gets highlighted class":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      let r = MockRenderer()

      store.updateCalltraceSection(
        @[
          makeTestCallLine(0, "main", depth = 0),
          makeTestCallLine(1, "foo", depth = 1),
        ],
        startIndex = 0'i64,
        totalCount = 2'u64,
      )

      vm.setViewportHeight(10)

      let panel = renderCalltracePanel(r, vm)
      let container = findByClass(panel, "calltrace-lines")
      let rows = findAllByClass(container, "calltrace-call-line")

      # Select entry 0
      vm.selectEntry(some(0'i64))

      check "selected" in rows[0].attributes["class"]
      check "selected" notin rows[1].attributes["class"]

      dispose()

  test "double-click navigates":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      let r = MockRenderer()

      store.updateCalltraceSection(
        @[
          makeTestCallLine(0, "main", depth = 0, file = "main.nim", line = 10),
        ],
        startIndex = 0'i64,
        totalCount = 1'u64,
      )

      vm.setViewportHeight(10)

      let panel = renderCalltracePanel(r, vm)
      let container = findByClass(panel, "calltrace-lines")
      let rows = findAllByClass(container, "calltrace-call-line")

      let beforeCount = mock.receivedCommands.len

      rows[0].fireEvent("dblclick")

      drain()

      # Should have sent a navigation command
      check mock.receivedCommands.len > beforeCount

      dispose()

  test "lines update reactively when store changes":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      let r = MockRenderer()

      vm.setViewportHeight(10)

      let panel = renderCalltracePanel(r, vm)
      let container = findByClass(panel, "calltrace-lines")

      # Initially no lines
      check container.children.len == 0

      # Add lines
      store.updateCalltraceSection(
        @[
          makeTestCallLine(0, "start", depth = 0),
        ],
        startIndex = 0'i64,
        totalCount = 1'u64,
      )

      check container.children.len == 1
      check "start" in container.children[0].textContent

      dispose()

# ---------------------------------------------------------------------------
# Calltrace call argument rendering tests
# ---------------------------------------------------------------------------
#
# Backs TODO 5.2(l): the IsoNim calltrace view must emit one ``.call-arg``
# element per argument with nested ``.call-arg-name`` / ``.call-arg-text``
# children, so Playwright's ``CallTraceEntry.arguments()`` page object
# can locate args after navigating to a function in the calltrace.
# Mirrors the historical Karax call-argument markup.

suite "IsoNim Calltrace Panel — call arguments":

  test "syncs args into store via updateCalltraceSection":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()

      var argsTable = initTable[string, seq[CallArg]]()
      argsTable["call-key-foo"] = @[
        CallArg(name: "board", text: "[1,2,3]"),
        CallArg(name: "depth", text: "0"),
      ]

      store.updateCalltraceSection(
        @[
          makeTestCallLine(0, "solve_sudoku", depth = 0,
                           callKey = "call-key-foo"),
        ],
        startIndex = 0'i64,
        totalCount = 1'u64,
        args = argsTable,
      )

      let stored = store.calltrace.args.val
      check stored.len == 1
      check "call-key-foo" in stored
      check stored["call-key-foo"].len == 2
      check stored["call-key-foo"][0].name == "board"
      check stored["call-key-foo"][0].text == "[1,2,3]"
      check stored["call-key-foo"][1].name == "depth"
      check stored["call-key-foo"][1].text == "0"

      dispose()

  test "renders one .call-arg element per arg in row":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      let r = MockRenderer()

      var argsTable = initTable[string, seq[CallArg]]()
      argsTable["k-main"] = @[
        CallArg(name: "argc", text: "1"),
        CallArg(name: "argv", text: "[\"prog\"]"),
      ]
      argsTable["k-solve"] = @[
        CallArg(name: "board", text: "[[1,2,3]]"),
      ]

      store.updateCalltraceSection(
        @[
          makeTestCallLine(0, "main", depth = 0, callKey = "k-main"),
          makeTestCallLine(1, "solve_sudoku", depth = 1,
                           callKey = "k-solve"),
        ],
        startIndex = 0'i64,
        totalCount = 2'u64,
        args = argsTable,
      )

      vm.setViewportHeight(10)

      let panel = renderCalltracePanel(r, vm)
      let container = findByClass(panel, "calltrace-lines")
      let rows = findAllByClass(container, "calltrace-call-line")
      check rows.len == 2

      # First row (main) has two args.
      let mainArgs = findAllByClass(rows[0], "call-arg")
      check mainArgs.len == 2

      let mainNames = findAllByClass(rows[0], "call-arg-name")
      check mainNames.len == 2
      check mainNames[0].textContent == "argc="
      check mainNames[1].textContent == "argv="

      let mainTexts = findAllByClass(rows[0], "call-arg-text")
      check mainTexts.len == 2
      check mainTexts[0].textContent == "1"
      check mainTexts[1].textContent == "[\"prog\"]"

      # Second row (solve_sudoku) has a single ``board`` arg — exactly
      # the case the python-sudoku ``variable inspection board via call
      # trace argument`` GUI test exercises.
      let solveArgs = findAllByClass(rows[1], "call-arg")
      check solveArgs.len == 1

      let solveNames = findAllByClass(rows[1], "call-arg-name")
      check solveNames.len == 1
      check solveNames[0].textContent == "board="

      let solveTexts = findAllByClass(rows[1], "call-arg-text")
      check solveTexts.len == 1
      check solveTexts[0].textContent == "[[1,2,3]]"

      dispose()

  test "row with unknown callKey renders no .call-arg children":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      let r = MockRenderer()

      # No args supplied for this row — the args container must remain
      # empty so we don't emit stale ``.call-arg`` elements that the
      # legacy view's ``()`` placeholder used to mask.
      store.updateCalltraceSection(
        @[
          makeTestCallLine(0, "noargs", depth = 0, callKey = "k-noargs"),
        ],
        startIndex = 0'i64,
        totalCount = 1'u64,
      )

      vm.setViewportHeight(10)

      let panel = renderCalltracePanel(r, vm)
      let container = findByClass(panel, "calltrace-lines")
      let rows = findAllByClass(container, "calltrace-call-line")
      check rows.len == 1

      let argEntries = findAllByClass(rows[0], "call-arg")
      check argEntries.len == 0

      dispose()

  test "args update reactively when store changes":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      let r = MockRenderer()

      store.updateCalltraceSection(
        @[
          makeTestCallLine(0, "fn", depth = 0, callKey = "k-fn"),
        ],
        startIndex = 0'i64,
        totalCount = 1'u64,
      )

      vm.setViewportHeight(10)

      let panel = renderCalltracePanel(r, vm)
      let container = findByClass(panel, "calltrace-lines")
      let rows = findAllByClass(container, "calltrace-call-line")
      check rows.len == 1
      check findAllByClass(rows[0], "call-arg").len == 0

      # Now feed args for the same row and confirm the DOM updates.
      var freshArgs = initTable[string, seq[CallArg]]()
      freshArgs["k-fn"] = @[CallArg(name: "x", text: "42")]
      store.updateCalltraceArgs(freshArgs)

      let argsAfter = findAllByClass(rows[0], "call-arg")
      check argsAfter.len == 1
      let nameEl = findByClass(argsAfter[0], "call-arg-name")
      check nameEl != nil
      check nameEl.textContent == "x="
      let textEl = findByClass(argsAfter[0], "call-arg-text")
      check textEl != nil
      check textEl.textContent == "42"

      dispose()

# ---------------------------------------------------------------------------
# Calltrace scroll indicator tests
# ---------------------------------------------------------------------------

suite "IsoNim Calltrace Panel — scroll indicators":

  test "hasMoreAbove shown when scrolled down":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      let r = MockRenderer()

      store.updateCalltraceSection(
        @[
          makeTestCallLine(5, "fn5", depth = 0),
        ],
        startIndex = 5'i64,
        totalCount = 20'u64,
      )

      vm.setViewportHeight(5)

      let panel = renderCalltracePanel(r, vm)
      let moreAbove = findByClass(panel, "more-above")

      # Initially at position 0
      check moreAbove.styles["display"] == "none"

      # Scroll down
      vm.scroll(5)

      check moreAbove.styles["display"] == "block"

      dispose()

  test "hasMoreBelow shown when not at end":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      let r = MockRenderer()

      store.updateCalltraceSection(
        @[
          makeTestCallLine(0, "fn0", depth = 0),
          makeTestCallLine(1, "fn1", depth = 0),
          makeTestCallLine(2, "fn2", depth = 0),
        ],
        startIndex = 0'i64,
        totalCount = 20'u64,
      )

      vm.setViewportHeight(3)

      let panel = renderCalltracePanel(r, vm)
      let moreBelow = findByClass(panel, "more-below")

      # At position 0 with 3 visible and 20 total, there should be more below
      check moreBelow.styles["display"] == "block"

      dispose()

# ---------------------------------------------------------------------------
# Calltrace loading tests
# ---------------------------------------------------------------------------

suite "IsoNim Calltrace Panel — loading":

  test "loading indicator becomes visible when loading":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      drain()  # flush auto-load effect's loading→idle transition
      let r = MockRenderer()

      let panel = renderCalltracePanel(r, vm)
      let indicator = findByClass(panel, "calltrace-loading")

      check indicator.styles["display"] == "none"

      store.calltrace.loadingState.val = lsLoading
      check indicator.styles["display"] == "block"

      store.calltrace.loadingState.val = lsIdle
      check indicator.styles["display"] == "none"

      dispose()

# ===========================================================================
# Debug Controls panel tests
# ===========================================================================

# ---------------------------------------------------------------------------
# Debug Controls structure tests
# ---------------------------------------------------------------------------

suite "IsoNim Debug Controls Panel — structure":

  test "renders root with debug-controls class":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)
      let r = MockRenderer()

      let panel = renderDebugControlsPanel(r, vm)

      check panel.kind == mnkElement
      check panel.tag == "div"
      check panel.attributes["class"] == "debug-controls"

      dispose()

  test "renders all six control buttons":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)
      let r = MockRenderer()

      let panel = renderDebugControlsPanel(r, vm)

      let stepFwd = findByClass(panel, "step-forward")
      let stepBwd = findByClass(panel, "step-backward")
      let stepIn = findByClass(panel, "step-in")
      let stepOut = findByClass(panel, "step-out")
      let continueBtn = findByClass(panel, "continue-btn")
      let revContinue = findByClass(panel, "reverse-continue")

      check stepFwd != nil
      check stepBwd != nil
      check stepIn != nil
      check stepOut != nil
      check continueBtn != nil
      check revContinue != nil

      check stepFwd.tag == "button"
      check stepBwd.tag == "button"
      check stepIn.tag == "button"
      check stepOut.tag == "button"
      check continueBtn.tag == "button"
      check revContinue.tag == "button"

      dispose()

  test "renders status text":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)
      let r = MockRenderer()

      let panel = renderDebugControlsPanel(r, vm)

      let status = findByClass(panel, "debug-status-text")
      check status != nil
      check status.textContent == "Idle"

      dispose()

# ---------------------------------------------------------------------------
# Debug Controls button state tests
# ---------------------------------------------------------------------------

suite "IsoNim Debug Controls Panel — button states":

  test "buttons enabled when debugger is idle":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)
      let r = MockRenderer()

      # Debugger starts idle
      let panel = renderDebugControlsPanel(r, vm)

      let stepFwd = findByClass(panel, "step-forward")
      let continueBtn = findByClass(panel, "continue-btn")

      # canStepForward should be true when idle
      check "disabled" notin stepFwd.attributes
      check "disabled" notin continueBtn.attributes

      dispose()

  test "step-backward disabled at start of timeline":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)
      let r = MockRenderer()

      # debugger at rrTicks=0, minRRTicks=0 => canStepBackward = false
      let panel = renderDebugControlsPanel(r, vm)

      let stepBwd = findByClass(panel, "step-backward")
      check stepBwd.attributes.getOrDefault("disabled", "") == "true"

      dispose()

  test "step-backward enabled when past start":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)
      let r = MockRenderer()

      # Move debugger past the start
      var dbg = store.debugger.val
      dbg.rrTicks = 100'u64
      store.debugger.val = dbg

      let panel = renderDebugControlsPanel(r, vm)

      let stepBwd = findByClass(panel, "step-backward")
      check "disabled" notin stepBwd.attributes

      dispose()

  test "buttons disabled when debugger is stepping":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)
      let r = MockRenderer()

      let panel = renderDebugControlsPanel(r, vm)

      # Put debugger in stepping state
      var dbg = store.debugger.val
      dbg.status = dsStepping
      store.debugger.val = dbg

      let stepFwd = findByClass(panel, "step-forward")
      let continueBtn = findByClass(panel, "continue-btn")

      check stepFwd.attributes.getOrDefault("disabled", "") == "true"
      check continueBtn.attributes.getOrDefault("disabled", "") == "true"

      dispose()

# ---------------------------------------------------------------------------
# Debug Controls action tests
# ---------------------------------------------------------------------------

suite "IsoNim Debug Controls Panel — actions":

  test "click step-forward triggers action":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)
      let r = MockRenderer()

      let panel = renderDebugControlsPanel(r, vm)

      let stepFwd = findByClass(panel, "step-forward")
      let beforeCount = mock.receivedCommands.len

      stepFwd.fireEvent("click")
      drain()

      check mock.receivedCommands.len > beforeCount

      dispose()

  test "click step-backward is no-op at start":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)
      let r = MockRenderer()

      let panel = renderDebugControlsPanel(r, vm)

      let stepBwd = findByClass(panel, "step-backward")
      let beforeCount = mock.receivedCommands.len

      stepBwd.fireEvent("click")
      drain()

      # No command should have been sent (canStepBackward is false)
      check mock.receivedCommands.len == beforeCount

      dispose()

  test "click continue triggers action":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)
      let r = MockRenderer()

      let panel = renderDebugControlsPanel(r, vm)

      let continueBtn = findByClass(panel, "continue-btn")
      let beforeCount = mock.receivedCommands.len

      continueBtn.fireEvent("click")
      drain()

      check mock.receivedCommands.len > beforeCount

      dispose()

# ---------------------------------------------------------------------------
# Debug Controls status text tests
# ---------------------------------------------------------------------------

suite "IsoNim Debug Controls Panel — status text":

  test "status text updates reactively":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)
      let r = MockRenderer()

      let panel = renderDebugControlsPanel(r, vm)
      let status = findByClass(panel, "debug-status-text")

      check status.textContent == "Idle"

      # Change debugger status to stepping
      var dbg = store.debugger.val
      dbg.status = dsStepping
      store.debugger.val = dbg

      check status.textContent == "Stepping..."

      # Change to finished
      dbg.status = dsFinished
      store.debugger.val = dbg

      check status.textContent == "Finished"

      dispose()

# ===========================================================================
# Event Log panel tests
# ===========================================================================

proc makeTestEvent(eventId: uint64; kind: string; line: int;
                   value: string): EventLogRow =
  EventLogRow(eventId: eventId, kind: kind, line: line, value: value)

# ---------------------------------------------------------------------------
# Event Log structure tests
# ---------------------------------------------------------------------------

suite "IsoNim Event Log Panel — structure":

  test "renders root with event-log-component class":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEventLogVM(store)
      let r = MockRenderer()

      let panel = renderEventLogPanel(r, vm)

      check panel.kind == mnkElement
      check panel.tag == "div"
      check panel.attributes["class"] == "event-log-component"

      dispose()

  test "renders search input":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEventLogVM(store)
      let r = MockRenderer()

      let panel = renderEventLogPanel(r, vm)

      let input = findByClass(panel, "event-log-search-input")
      check input != nil
      check input.attributes["placeholder"] == "Search events..."

      dispose()

  test "renders column headers":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEventLogVM(store)
      let r = MockRenderer()

      let panel = renderEventLogPanel(r, vm)

      let headerRow = findByClass(panel, "event-log-header-row")
      check headerRow != nil

      let col0 = findByClass(panel, "column-0")
      let col1 = findByClass(panel, "column-1")
      let col2 = findByClass(panel, "column-2")
      let col3 = findByClass(panel, "column-3")

      check col0 != nil
      check col1 != nil
      check col2 != nil
      check col3 != nil

      check "ID" in col0.textContent
      check "Kind" in col1.textContent
      check "Line" in col2.textContent
      check "Value" in col3.textContent

      dispose()

  test "renders pagination controls":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEventLogVM(store)
      let r = MockRenderer()

      let panel = renderEventLogPanel(r, vm)

      let prevBtn = findByClass(panel, "page-prev")
      let nextBtn = findByClass(panel, "page-next")
      let indicator = findByClass(panel, "page-indicator")

      check prevBtn != nil
      check nextBtn != nil
      check indicator != nil

      check prevBtn.tag == "button"
      check nextBtn.tag == "button"

      dispose()

  test "renders loading indicator (hidden by default)":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEventLogVM(store)
      let r = MockRenderer()

      let panel = renderEventLogPanel(r, vm)

      let indicator = findByClass(panel, "event-log-loading")
      check indicator != nil
      check indicator.styles.getOrDefault("display", "none") == "none"

      dispose()

# ---------------------------------------------------------------------------
# Event Log row rendering tests
# ---------------------------------------------------------------------------

suite "IsoNim Event Log Panel — rows":

  test "renders event rows":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEventLogVM(store)
      let r = MockRenderer()

      vm.eventRows.val = @[
        makeTestEvent(1, "call", 10, "foo()"),
        makeTestEvent(2, "return", 15, "42"),
      ]

      let panel = renderEventLogPanel(r, vm)
      let container = findByClass(panel, "event-log-rows")
      check container != nil

      let rows = findAllByClass(container, "event-row")
      check rows.len == 2

      check "1" in rows[0].textContent
      check "call" in rows[0].textContent
      check "foo()" in rows[0].textContent

      check "2" in rows[1].textContent
      check "return" in rows[1].textContent
      check "42" in rows[1].textContent

      dispose()

  test "click selects row":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEventLogVM(store)
      let r = MockRenderer()

      vm.eventRows.val = @[
        makeTestEvent(1, "call", 10, "foo()"),
        makeTestEvent(2, "return", 15, "42"),
      ]

      let panel = renderEventLogPanel(r, vm)
      let container = findByClass(panel, "event-log-rows")
      let rows = findAllByClass(container, "event-row")

      check vm.selectedRow.val.isNone

      rows[1].fireEvent("click")

      check vm.selectedRow.val.isSome
      check vm.selectedRow.val.get == 1

      dispose()

  test "selected row gets highlighted class":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEventLogVM(store)
      let r = MockRenderer()

      vm.eventRows.val = @[
        makeTestEvent(1, "call", 10, "foo()"),
        makeTestEvent(2, "return", 15, "42"),
      ]

      let panel = renderEventLogPanel(r, vm)
      let container = findByClass(panel, "event-log-rows")
      let rows = findAllByClass(container, "event-row")

      vm.selectRow(some(0))

      check "selected" in rows[0].attributes["class"]
      check "selected" notin rows[1].attributes["class"]

      dispose()

# ---------------------------------------------------------------------------
# Event Log sort tests
# ---------------------------------------------------------------------------

suite "IsoNim Event Log Panel — sorting":

  test "click column header toggles sort":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEventLogVM(store)
      let r = MockRenderer()

      let panel = renderEventLogPanel(r, vm)

      let col1 = findByClass(panel, "column-1")
      check col1 != nil

      col1.fireEvent("click")

      check vm.sortColumn.val == 1
      check vm.sortAscending.val == true

      # Click again to toggle direction
      col1.fireEvent("click")

      check vm.sortColumn.val == 1
      check vm.sortAscending.val == false

      dispose()

  test "sort indicator shown on active column":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEventLogVM(store)
      let r = MockRenderer()

      let panel = renderEventLogPanel(r, vm)

      # Sort by column 0 (default)
      let col0 = findByClass(panel, "column-0")
      check col0 != nil
      check "sort-active" in col0.attributes["class"]

      dispose()

# ---------------------------------------------------------------------------
# Event Log pagination tests
# ---------------------------------------------------------------------------

suite "IsoNim Event Log Panel — pagination":

  test "prev button disabled on first page":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEventLogVM(store)
      let r = MockRenderer()

      let panel = renderEventLogPanel(r, vm)

      let prevBtn = findByClass(panel, "page-prev")
      check prevBtn.attributes.getOrDefault("disabled", "") == "true"

      dispose()

  test "page indicator shows correct text":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEventLogVM(store)
      let r = MockRenderer()

      vm.totalEventCount.val = 150

      let panel = renderEventLogPanel(r, vm)

      let indicator = findByClass(panel, "page-indicator")
      check indicator != nil
      check "Page 1" in indicator.textContent

      dispose()

# ---------------------------------------------------------------------------
# Event Log loading tests
# ---------------------------------------------------------------------------

suite "IsoNim Event Log Panel — loading":

  test "loading indicator becomes visible when loading":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createEventLogVM(store)
      let r = MockRenderer()

      let panel = renderEventLogPanel(r, vm)
      let indicator = findByClass(panel, "event-log-loading")

      check indicator.styles["display"] == "none"

      vm.loadingState.val = lsLoading
      check indicator.styles["display"] == "block"

      vm.loadingState.val = lsIdle
      check indicator.styles["display"] == "none"

      dispose()

# ===========================================================================
# Flow panel tests
# ===========================================================================

# ---------------------------------------------------------------------------
# Flow structure tests
# ---------------------------------------------------------------------------

suite "IsoNim Flow Panel — structure":

  test "renders root with flow-component class":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)
      let r = MockRenderer()

      let panel = renderFlowPanel(r, vm)

      check panel.kind == mnkElement
      check panel.tag == "div"
      check panel.attributes["class"] == "flow-component"

      dispose()

  test "renders three mode buttons":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)
      let r = MockRenderer()

      let panel = renderFlowPanel(r, vm)

      let modeBar = findByClass(panel, "flow-mode-selector")
      check modeBar != nil

      let callBtn = findByClass(panel, "mode-call")
      let lineBtn = findByClass(panel, "mode-line")
      let funcBtn = findByClass(panel, "mode-function")

      check callBtn != nil
      check lineBtn != nil
      check funcBtn != nil

      check callBtn.tag == "button"
      check lineBtn.tag == "button"
      check funcBtn.tag == "button"

      check callBtn.textContent == "Call"
      check lineBtn.textContent == "Line"
      check funcBtn.textContent == "Function"

      # Call mode active by default
      check "active" in callBtn.attributes["class"]
      check "active" notin lineBtn.attributes["class"]
      check "active" notin funcBtn.attributes["class"]

      dispose()

  test "renders iteration slider":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)
      let r = MockRenderer()

      let panel = renderFlowPanel(r, vm)

      let slider = findByClass(panel, "flow-iteration-slider")
      check slider != nil

      let label = findByClass(panel, "iteration-label")
      check label != nil

      let rangeInput = findByClass(panel, "iteration-range")
      check rangeInput != nil

      dispose()

  test "renders value display":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)
      let r = MockRenderer()

      let panel = renderFlowPanel(r, vm)

      let display = findByClass(panel, "flow-value-display")
      check display != nil

      let toggleBtn = findByClass(panel, "raw-value-toggle")
      check toggleBtn != nil
      check toggleBtn.textContent == "Raw"

      dispose()

  test "renders flow steps container":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)
      let r = MockRenderer()

      let panel = renderFlowPanel(r, vm)

      let steps = findByClass(panel, "flow-steps")
      check steps != nil

      dispose()

  test "renders loading indicator (hidden by default)":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)
      let r = MockRenderer()

      let panel = renderFlowPanel(r, vm)

      let indicator = findByClass(panel, "flow-loading")
      check indicator != nil
      check indicator.styles.getOrDefault("display", "none") == "none"

      dispose()

# ---------------------------------------------------------------------------
# Flow mode switching tests
# ---------------------------------------------------------------------------

suite "IsoNim Flow Panel — mode switching":

  test "clicking line mode updates active class":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)
      let r = MockRenderer()

      let panel = renderFlowPanel(r, vm)

      let lineBtn = findByClass(panel, "mode-line")
      check lineBtn != nil
      lineBtn.fireEvent("click")

      check vm.flowMode.val == fmLine

      check "active" in lineBtn.attributes["class"]

      let callBtn = findByClass(panel, "mode-call")
      check "active" notin callBtn.attributes["class"]

      dispose()

  test "clicking function mode updates active class":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)
      let r = MockRenderer()

      let panel = renderFlowPanel(r, vm)

      let funcBtn = findByClass(panel, "mode-function")
      funcBtn.fireEvent("click")

      check vm.flowMode.val == fmFunction
      check "active" in funcBtn.attributes["class"]

      dispose()

# ---------------------------------------------------------------------------
# Flow raw value toggle tests
# ---------------------------------------------------------------------------

suite "IsoNim Flow Panel — raw values":

  test "toggle raw values button changes text":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)
      let r = MockRenderer()

      let panel = renderFlowPanel(r, vm)

      let toggleBtn = findByClass(panel, "raw-value-toggle")
      check toggleBtn.textContent == "Raw"

      toggleBtn.fireEvent("click")

      check vm.showRawValues.val == true
      check toggleBtn.textContent == "Formatted"
      check "active" in toggleBtn.attributes["class"]

      dispose()

# ---------------------------------------------------------------------------
# Flow iteration slider tests
# ---------------------------------------------------------------------------

suite "IsoNim Flow Panel — iteration slider":

  test "iteration label shows current / total":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)
      let r = MockRenderer()

      vm.iterationCount.val = 10

      let panel = renderFlowPanel(r, vm)

      let label = findByClass(panel, "iteration-label")
      check label != nil
      check "0" in label.textContent
      check "10" in label.textContent

      vm.selectIteration(5)

      check "5" in label.textContent

      dispose()

# ---------------------------------------------------------------------------
# Flow loading tests
# ---------------------------------------------------------------------------

suite "IsoNim Flow Panel — loading":

  test "loading indicator becomes visible when loading":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFlowVM(store)
      let r = MockRenderer()

      let panel = renderFlowPanel(r, vm)
      let indicator = findByClass(panel, "flow-loading")

      check indicator.styles["display"] == "none"

      vm.loadingState.val = lsLoading
      check indicator.styles["display"] == "block"

      vm.loadingState.val = lsIdle
      check indicator.styles["display"] == "none"

      dispose()

# ===========================================================================
# Timeline panel tests
# ===========================================================================

# ---------------------------------------------------------------------------
# Timeline structure tests
# ---------------------------------------------------------------------------

suite "IsoNim Timeline Panel — structure":

  test "renders root with timeline-component class":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTimelineVM(store)
      let r = MockRenderer()

      let panel = renderTimelinePanel(r, vm)

      check panel.kind == mnkElement
      check panel.tag == "div"
      check panel.attributes["class"] == "timeline-component"

      dispose()

  test "renders position indicator":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTimelineVM(store)
      let r = MockRenderer()

      let panel = renderTimelinePanel(r, vm)

      let posDiv = findByClass(panel, "timeline-position")
      check posDiv != nil

      let ticksSpan = findByClass(panel, "position-ticks")
      check ticksSpan != nil
      check "Tick:" in ticksSpan.textContent

      dispose()

  test "renders zoom controls":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTimelineVM(store)
      let r = MockRenderer()

      let panel = renderTimelinePanel(r, vm)

      let zoomBar = findByClass(panel, "timeline-zoom-controls")
      check zoomBar != nil

      let zoomOut = findByClass(panel, "zoom-out")
      let zoomIn = findByClass(panel, "zoom-in")
      let zoomLevel = findByClass(panel, "zoom-level")

      check zoomOut != nil
      check zoomIn != nil
      check zoomLevel != nil

      check zoomOut.tag == "button"
      check zoomIn.tag == "button"

      dispose()

  test "renders timeline track":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTimelineVM(store)
      let r = MockRenderer()

      let panel = renderTimelinePanel(r, vm)

      let track = findByClass(panel, "timeline-track")
      check track != nil

      let playhead = findByClass(panel, "timeline-playhead")
      check playhead != nil

      dispose()

  test "renders hover tooltip (hidden by default)":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTimelineVM(store)
      let r = MockRenderer()

      let panel = renderTimelinePanel(r, vm)

      let tooltip = findByClass(panel, "timeline-hover-tooltip")
      check tooltip != nil
      check tooltip.styles.getOrDefault("display", "none") == "none"

      dispose()

# ---------------------------------------------------------------------------
# Timeline position tests
# ---------------------------------------------------------------------------

suite "IsoNim Timeline Panel — position":

  test "position ticks updates reactively":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTimelineVM(store)
      let r = MockRenderer()

      let panel = renderTimelinePanel(r, vm)
      let ticksSpan = findByClass(panel, "position-ticks")

      check "0" in ticksSpan.textContent

      # Move debugger position
      var dbg = store.debugger.val
      dbg.rrTicks = 500'u64
      store.debugger.val = dbg

      check "500" in ticksSpan.textContent

      dispose()

# ---------------------------------------------------------------------------
# Timeline zoom tests
# ---------------------------------------------------------------------------

suite "IsoNim Timeline Panel — zoom":

  test "zoom in button doubles zoom level":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTimelineVM(store)
      let r = MockRenderer()

      let panel = renderTimelinePanel(r, vm)

      let zoomIn = findByClass(panel, "zoom-in")
      check vm.zoomLevel.val == 1.0

      zoomIn.fireEvent("click")

      check vm.zoomLevel.val == 2.0

      dispose()

  test "zoom out button halves zoom level":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTimelineVM(store)
      let r = MockRenderer()

      let panel = renderTimelinePanel(r, vm)

      let zoomOut = findByClass(panel, "zoom-out")
      check vm.zoomLevel.val == 1.0

      zoomOut.fireEvent("click")

      check vm.zoomLevel.val == 0.5

      dispose()

  test "zoom level display updates reactively":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTimelineVM(store)
      let r = MockRenderer()

      let panel = renderTimelinePanel(r, vm)

      let zoomText = findByClass(panel, "zoom-level")
      check "1.0x" in zoomText.textContent

      vm.zoom(4.0)

      check "4.0x" in zoomText.textContent

      dispose()

# ---------------------------------------------------------------------------
# Timeline hover tooltip tests
# ---------------------------------------------------------------------------

suite "IsoNim Timeline Panel — hover tooltip":

  test "tooltip shown when hovering":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTimelineVM(store)
      let r = MockRenderer()

      let panel = renderTimelinePanel(r, vm)
      let tooltip = findByClass(panel, "timeline-hover-tooltip")

      check tooltip.styles["display"] == "none"

      vm.hover(some(250'u64))
      check tooltip.styles["display"] == "block"
      check "250" in tooltip.textContent

      vm.hover(none(uint64))
      check tooltip.styles["display"] == "none"

      dispose()

# ===========================================================================
# Search panel tests
# ===========================================================================

# ---------------------------------------------------------------------------
# Search structure tests
# ---------------------------------------------------------------------------

suite "IsoNim Search Panel — structure":

  test "renders root with search-component class":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchVM(store)
      let r = MockRenderer()

      let panel = renderSearchPanel(r, vm)

      check panel.kind == mnkElement
      check panel.tag == "div"
      check panel.attributes["class"] == "search-component"

      dispose()

  test "renders four mode buttons":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchVM(store)
      let r = MockRenderer()

      let panel = renderSearchPanel(r, vm)

      let modeBar = findByClass(panel, "search-mode-selector")
      check modeBar != nil

      let cmdBtn = findByClass(panel, "mode-command")
      let fileBtn = findByClass(panel, "mode-file")
      let findBtn = findByClass(panel, "mode-find-in-files")
      let symBtn = findByClass(panel, "mode-find-symbol")

      check cmdBtn != nil
      check fileBtn != nil
      check findBtn != nil
      check symBtn != nil

      check cmdBtn.textContent == "Command"
      check fileBtn.textContent == "File"
      check findBtn.textContent == "Find in Files"
      check symBtn.textContent == "Find Symbol"

      # Command mode active by default
      check "active" in cmdBtn.attributes["class"]
      check "active" notin fileBtn.attributes["class"]

      dispose()

  test "renders search input":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchVM(store)
      let r = MockRenderer()

      let panel = renderSearchPanel(r, vm)

      let input = findByClass(panel, "search-query-input")
      check input != nil
      check input.attributes["placeholder"] == "Search..."

      dispose()

  test "renders results container (hidden by default)":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchVM(store)
      let r = MockRenderer()

      let panel = renderSearchPanel(r, vm)

      let results = findByClass(panel, "search-results")
      check results != nil
      check results.styles.getOrDefault("display", "none") == "none"

      dispose()

# ---------------------------------------------------------------------------
# Search mode switching tests
# ---------------------------------------------------------------------------

suite "IsoNim Search Panel — mode switching":

  test "clicking file mode updates active class":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchVM(store)
      let r = MockRenderer()

      let panel = renderSearchPanel(r, vm)

      let fileBtn = findByClass(panel, "mode-file")
      fileBtn.fireEvent("click")

      check vm.mode.val == smFile
      check "active" in fileBtn.attributes["class"]

      let cmdBtn = findByClass(panel, "mode-command")
      check "active" notin cmdBtn.attributes["class"]

      dispose()

  test "setting query shows results":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchVM(store)
      let r = MockRenderer()

      let panel = renderSearchPanel(r, vm)

      let results = findByClass(panel, "search-results")
      check results.styles["display"] == "none"

      vm.setQuery("test")

      check results.styles["display"] == "block"

      dispose()

  test "selected result indicator updates":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchVM(store)
      let r = MockRenderer()

      let panel = renderSearchPanel(r, vm)

      let indicator = findByClass(panel, "search-selected-indicator")
      check indicator.textContent == ""

      vm.selectResult(some(3))

      check "3" in indicator.textContent
      check "active" in indicator.attributes["class"]

      dispose()

# ===========================================================================
# Point List panel tests
# ===========================================================================

# ---------------------------------------------------------------------------
# Point List structure tests
# ---------------------------------------------------------------------------

suite "IsoNim Point List Panel — structure":

  test "renders root with point-list-component class":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createPointListVM(store)
      let r = MockRenderer()

      let panel = renderPointListPanel(r, vm)

      check panel.kind == mnkElement
      check panel.tag == "div"
      check panel.attributes["class"] == "point-list-component"

      dispose()

  test "renders header with title":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createPointListVM(store)
      let r = MockRenderer()

      let panel = renderPointListPanel(r, vm)

      let title = findByClass(panel, "point-list-title")
      check title != nil
      check title.textContent == "Points"

      dispose()

  test "renders points container":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createPointListVM(store)
      let r = MockRenderer()

      let panel = renderPointListPanel(r, vm)

      let container = findByClass(panel, "point-list-items")
      check container != nil

      dispose()

  test "edit indicator hidden by default":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createPointListVM(store)
      let r = MockRenderer()

      let panel = renderPointListPanel(r, vm)

      let editIndicator = findByClass(panel, "point-edit-indicator")
      check editIndicator != nil
      check editIndicator.styles.getOrDefault("display", "none") == "none"

      dispose()

# ---------------------------------------------------------------------------
# Point List interaction tests
# ---------------------------------------------------------------------------

suite "IsoNim Point List Panel — interactions":

  test "selected point indicator updates":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createPointListVM(store)
      let r = MockRenderer()

      let panel = renderPointListPanel(r, vm)

      let indicator = findByClass(panel, "point-selected-indicator")
      check indicator.textContent == ""

      vm.selectPoint(some(5))

      check "5" in indicator.textContent
      check "active" in indicator.attributes["class"]

      dispose()

  test "edit indicator shown when editing":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createPointListVM(store)
      let r = MockRenderer()

      let panel = renderPointListPanel(r, vm)

      let editIndicator = findByClass(panel, "point-edit-indicator")
      check editIndicator.styles["display"] == "none"

      vm.startEditing(2)

      check editIndicator.styles["display"] == "inline"
      check "2" in editIndicator.textContent

      vm.stopEditing()

      check editIndicator.styles["display"] == "none"

      dispose()

# ===========================================================================
# Scratchpad panel tests — closes section 5.4 entry "scratchpad" (§1.70)
#
# Mirrors the legacy ``ScratchpadComponent`` (``frontend/ui/scratchpad.nim``)
# which rendered a vertical stack of pinned values via the rich Karax
# ``ValueComponent`` sub-tree.  The IsoNim view replaces the Karax
# ``method render``; these tests cover the structural shell, value-row
# rendering, the empty-state placeholder, the per-row close button
# (``removeValue``), and the ``addFromExpression`` lookup flow.  The
# full expandable ``ValueComponent`` backend tree is deliberately not
# exercised here because ``ScratchpadValueEntry`` carries a flattened
# preview, but rows must keep the legacy collapsed ``value-*`` DOM.
# ---------------------------------------------------------------------------

proc makeScratchpadEntry(expression: string = "i";
                         valueText: string = "42";
                         isError: bool = false;
                         isLiteral: bool = false): ScratchpadValueEntry =
  ## Test fixture builder for ``ScratchpadValueEntry`` rows.
  ScratchpadValueEntry(
    expression: expression,
    valueText: valueText,
    isError: isError,
    isLiteral: isLiteral,
  )

# ---------------------------------------------------------------------------
# Structure
# ---------------------------------------------------------------------------

suite "IsoNim Scratchpad Panel — structure":

  test "root carries component-container + active-state classes":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)
      let r = MockRenderer()

      let panel = renderScratchpadPanel(r, vm)

      check panel.kind == mnkElement
      check panel.tag == "div"
      check "component-container" in panel.attributes["class"]
      check "active-state" in panel.attributes["class"]
      check panel.attributes["id"] == "scratchpadComponent-0"

      dispose()

  test "container constant matches the legacy componentContainerClass output":
    # Documents the wire shape — a regression here would break the
    # existing scss rules under static/styles/components/scratchpad.styl
    # (the rule is keyed on `[id^="scratchpadComponent-"]`).
    check ScratchpadContainerClass == "component-container active-state"

  test "empty VM renders value-components-container + empty-overlay":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)
      let r = MockRenderer()

      let panel = renderScratchpadPanel(r, vm)

      let list = findByClass(panel, "value-components-container")
      check list != nil
      check list.children.len == 0

      let overlay = findByClass(panel, "empty-overlay")
      check overlay != nil
      check overlay.textContent == ScratchpadEmptyStateText
      check "hidden" notin overlay.attributes["class"]

      dispose()

  test "empty-overlay carries the legacy invitation copy verbatim":
    # The exact wording is part of the user-facing contract — the
    # tooltip / docs describe the same flow.  A regression here would
    # be a UX change masquerading as a refactor.
    check ScratchpadEmptyStateText.startsWith(
      "You can add values from other components by right clicking")
    check "Add value to scratchpad" in ScratchpadEmptyStateText

# ---------------------------------------------------------------------------
# Row rendering
# ---------------------------------------------------------------------------

suite "IsoNim Scratchpad Panel — row rendering":

  test "addValue populates the value list reactively":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)
      let r = MockRenderer()

      let panel = renderScratchpadPanel(r, vm)
      let list = findByClass(panel, "value-components-container")
      check list.children.len == 0

      vm.addValue(makeScratchpadEntry("a", "1"))
      vm.addValue(makeScratchpadEntry("b", "2"))

      check list.children.len == 2

      dispose()

  test "row carries scratchpad-value-view class + close button":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)
      let r = MockRenderer()

      let panel = renderScratchpadPanel(r, vm)
      vm.addValue(makeScratchpadEntry("x", "99"))

      let list = findByClass(panel, "value-components-container")
      let row = list.children[0]
      check "scratchpad-value-view" in row.attributes["class"]

      let btn = findByClass(row, "ct-button-image-sm-secondary")
      check btn != nil
      check btn.tag == "button"
      check btn.attributes["id"] == "close-element"

      dispose()

  test "row renders legacy collapsed value DOM":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)
      let r = MockRenderer()

      let panel = renderScratchpadPanel(r, vm)
      vm.addValue(makeScratchpadEntry("board[1][2]", "X"))

      let valueRoot = findByClass(panel, "value-expanded")
      check valueRoot != nil
      check "border-value-0" in valueRoot.attributes["class"]
      check "value-expanded-name" in valueRoot.attributes["class"]

      let name = findByClass(panel, "value-name")
      check name != nil
      check name.textContent == "board[1][2]: "

      let textNode = findByClass(panel, "value-expanded-text")
      check textNode != nil
      check textNode.textContent == "X"

      dispose()

  test "empty-overlay hides once a value is pinned":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)
      let r = MockRenderer()

      let panel = renderScratchpadPanel(r, vm)
      let overlay = findByClass(panel, "empty-overlay")
      check "hidden" notin overlay.attributes["class"]

      vm.addValue(makeScratchpadEntry("a"))
      check "hidden" in overlay.attributes["class"]

      vm.clearValues()
      check "hidden" notin overlay.attributes["class"]

      dispose()

  test "literal entries keep the value preview in value-expanded-text":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)
      let r = MockRenderer()

      let panel = renderScratchpadPanel(r, vm)
      vm.addValue(makeScratchpadEntry("$msg", "hello world",
                                      isLiteral = true))

      let textNode = findByClass(panel, "value-expanded-text")
      check textNode.textContent == "hello world"

      dispose()

  test "error entries render with <error> marker + error class":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)
      let r = MockRenderer()

      let panel = renderScratchpadPanel(r, vm)
      vm.addValue(makeScratchpadEntry("crash", "boom", isError = true))

      let list = findByClass(panel, "value-components-container")
      let row = list.children[0]
      check "scratchpad-value-error" in row.attributes["class"]

      let errorText = findByClass(panel, "value-error")
      check errorText != nil
      check "value-expanded-text" in errorText.attributes["class"]
      check errorText.textContent == "<error: boom>"

      dispose()

  test "rows preserve insertion order":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)
      let r = MockRenderer()

      let panel = renderScratchpadPanel(r, vm)
      vm.addValue(makeScratchpadEntry("z", "26"))
      vm.addValue(makeScratchpadEntry("a", "1"))
      vm.addValue(makeScratchpadEntry("m", "13"))

      let list = findByClass(panel, "value-components-container")
      check list.children.len == 3
      check findByClass(list.children[0],
                        "value-name").textContent == "z: "
      check findByClass(list.children[0],
                        "value-expanded-text").textContent == "26"
      check findByClass(list.children[1],
                        "value-name").textContent == "a: "
      check findByClass(list.children[1],
                        "value-expanded-text").textContent == "1"
      check findByClass(list.children[2],
                        "value-name").textContent == "m: "
      check findByClass(list.children[2],
                        "value-expanded-text").textContent == "13"

      dispose()

# ---------------------------------------------------------------------------
# Interactions
# ---------------------------------------------------------------------------

suite "IsoNim Scratchpad Panel — interactions":

  test "clicking close removes that row from the VM":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)
      let r = MockRenderer()

      let panel = renderScratchpadPanel(r, vm)
      vm.addValue(makeScratchpadEntry("a", "1"))
      vm.addValue(makeScratchpadEntry("b", "2"))
      vm.addValue(makeScratchpadEntry("c", "3"))

      let list = findByClass(panel, "value-components-container")
      check list.children.len == 3

      # Click the middle row's close button.
      let row1 = list.children[1]
      let btn = findByClass(row1, "ct-button-image-sm-secondary")
      btn.fireEvent("click")

      check vm.entries.val.len == 2
      check vm.entries.val[0].expression == "a"
      check vm.entries.val[1].expression == "c"
      check list.children.len == 2

      dispose()

  test "removeValue with out-of-range index is a silent no-op":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)

      vm.addValue(makeScratchpadEntry("a", "1"))
      vm.removeValue(5)
      vm.removeValue(-1)

      check vm.entries.val.len == 1
      check vm.entries.val[0].expression == "a"

      dispose()

  test "clearValues drops every row":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)
      let r = MockRenderer()

      let panel = renderScratchpadPanel(r, vm)
      vm.addValue(makeScratchpadEntry("a", "1"))
      vm.addValue(makeScratchpadEntry("b", "2"))

      let list = findByClass(panel, "value-components-container")
      check list.children.len == 2

      vm.clearValues()
      check list.children.len == 0
      check vm.entries.val.len == 0

      dispose()

# ---------------------------------------------------------------------------
# VM defaults / addFromExpression
# ---------------------------------------------------------------------------

suite "IsoNim Scratchpad Panel — vm":

  test "createScratchpadVM defaults reflect the empty-state branch":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)

      check vm.entries.val.len == 0
      check vm.localsByExpression.val.len == 0
      check vm.isEmpty.val
      check vm.rowCount.val == 0
      check not vm.store.isNil

      dispose()

  test "isEmpty / rowCount memos track the entry list":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)

      check vm.isEmpty.val
      check vm.rowCount.val == 0

      vm.addValue(makeScratchpadEntry("a"))
      check not vm.isEmpty.val
      check vm.rowCount.val == 1

      vm.addValue(makeScratchpadEntry("b"))
      check vm.rowCount.val == 2

      vm.removeValue(0)
      check vm.rowCount.val == 1

      vm.clearValues()
      check vm.isEmpty.val
      check vm.rowCount.val == 0

      dispose()

  test "setLocals replaces the lookup table by expression key":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)

      vm.setLocals(@[
        makeScratchpadEntry("x", "1"),
        makeScratchpadEntry("y", "2"),
      ])
      check vm.localsByExpression.val.len == 2
      check vm.localsByExpression.val["x"].valueText == "1"

      # Replace — earlier entries are gone.
      vm.setLocals(@[
        makeScratchpadEntry("z", "9"),
      ])
      check vm.localsByExpression.val.len == 1
      check "x" notin vm.localsByExpression.val
      check vm.localsByExpression.val["z"].valueText == "9"

      dispose()

  test "addFromExpression appends a known local":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)

      vm.setLocals(@[
        makeScratchpadEntry("x", "1"),
        makeScratchpadEntry("y", "hello", isLiteral = true),
      ])

      vm.addFromExpression("y")
      check vm.entries.val.len == 1
      check vm.entries.val[0].expression == "y"
      check vm.entries.val[0].valueText == "hello"
      check vm.entries.val[0].isLiteral

      vm.addFromExpression("x")
      check vm.entries.val.len == 2
      check vm.entries.val[1].expression == "x"

      dispose()

  test "addFromExpression with unknown name is a silent no-op":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)

      vm.setLocals(@[makeScratchpadEntry("x", "1")])
      vm.addFromExpression("not-here")

      check vm.entries.val.len == 0

      dispose()

  test "rowClass adds the error modifier for error entries":
    check isonim_scratchpad_view.rowClass(false) == "scratchpad-value-view"
    check isonim_scratchpad_view.rowClass(true) ==
      "scratchpad-value-view scratchpad-value-error"

  test "cellText branches on isLiteral / isError flags":
    check cellText(makeScratchpadEntry("a", "1")) == "1"
    check cellText(makeScratchpadEntry("$msg", "hi",
                                       isLiteral = true)) == "hi"
    check cellText(makeScratchpadEntry("crash", "boom",
                                       isError = true)) ==
      "<error: boom>"

# ===========================================================================
# Shell panel tests
# ===========================================================================

# ---------------------------------------------------------------------------
# Shell structure tests
# ---------------------------------------------------------------------------

suite "IsoNim Shell Panel — structure":

  test "renders root with shell-component class":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createShellVM(store)
      let r = MockRenderer()

      let panel = renderShellPanel(r, vm)

      check panel.kind == mnkElement
      check panel.tag == "div"
      check panel.attributes["class"] == "shell-component"

      dispose()

  test "renders output area":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createShellVM(store)
      let r = MockRenderer()

      let panel = renderShellPanel(r, vm)

      let output = findByClass(panel, "shell-output")
      check output != nil

      dispose()

  test "renders input with prompt":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createShellVM(store)
      let r = MockRenderer()

      let panel = renderShellPanel(r, vm)

      let prompt = findByClass(panel, "shell-prompt")
      check prompt != nil
      check prompt.textContent == "$ "

      let input = findByClass(panel, "shell-input")
      check input != nil
      check input.attributes["placeholder"] == "Enter command..."

      dispose()

  test "history indicator hidden by default":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createShellVM(store)
      let r = MockRenderer()

      let panel = renderShellPanel(r, vm)

      let indicator = findByClass(panel, "shell-history-indicator")
      check indicator != nil
      check indicator.styles.getOrDefault("display", "none") == "none"

      dispose()

# ---------------------------------------------------------------------------
# Shell interaction tests
# ---------------------------------------------------------------------------

suite "IsoNim Shell Panel — interactions":

  test "input buffer reflects in input field":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createShellVM(store)
      let r = MockRenderer()

      let panel = renderShellPanel(r, vm)

      let input = findByClass(panel, "shell-input")

      vm.setInput("print(x)")

      check input.attributes["value"] == "print(x)"

      dispose()

  test "history indicator shown when navigating":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createShellVM(store)
      let r = MockRenderer()

      # Submit some history entries
      vm.setInput("cmd1")
      vm.submitInput()
      vm.setInput("cmd2")
      vm.submitInput()

      let panel = renderShellPanel(r, vm)

      let indicator = findByClass(panel, "shell-history-indicator")
      check indicator.styles["display"] == "none"

      vm.historyUp()

      check indicator.styles["display"] == "inline"
      check "2" in indicator.textContent

      dispose()

  test "scroll indicator shown when scrolled":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createShellVM(store)
      let r = MockRenderer()

      let panel = renderShellPanel(r, vm)

      let scrollInd = findByClass(panel, "shell-scroll-indicator")
      check scrollInd.styles["display"] == "none"

      vm.scroll(10)

      check scrollInd.styles["display"] == "inline"
      check "10" in scrollInd.textContent

# ===========================================================================
# Terminal Output panel tests
# ===========================================================================
#
# Cover:
# - Outer structure (root class, <pre> body, empty-overlay div).
# - Initial pre-load state ("Loading record output...") and post-load
#   empty state ("The current record does not print anything ...").
# - Per-line / per-fragment DOM produced by ``setLines``.
# - Fragment colour class flips when ``currentRRTicks`` changes.
# - Click handler routes through ``jumpToEvent`` to the backend mock.
#
# The render-effect that builds the ``<pre>`` body fires synchronously
# inside the reactive root, so no ``drain()`` is needed between
# mutations and assertions.

# ---------------------------------------------------------------------------
# Terminal Output helpers
# ---------------------------------------------------------------------------

proc makeTerminalLine(lineIndex: int;
                      fragments: seq[TerminalEventFragment]): TerminalLine =
  TerminalLine(lineIndex: lineIndex, fragments: fragments)

proc makeTerminalFragment(text: string; eventIndex: int = 0;
                          rrTicks: uint64 = 100'u64): TerminalEventFragment =
  TerminalEventFragment(
    htmlText: text,
    eventIndex: eventIndex,
    rrTicks: rrTicks,
  )

# ---------------------------------------------------------------------------
# Terminal Output structure tests
# ---------------------------------------------------------------------------

suite "IsoNim Terminal Output Panel — structure":

  test "renders root with terminal component-container class":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTerminalOutputVM(store)
      let r = MockRenderer()

      let panel = renderTerminalOutputPanel(r, vm)

      check panel.kind == mnkElement
      check panel.tag == "div"
      check "component-container" in panel.attributes["class"]
      check "terminal" in panel.attributes["class"]

      dispose()

  test "renders <pre> body and empty overlay":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTerminalOutputVM(store)
      let r = MockRenderer()

      let panel = renderTerminalOutputPanel(r, vm)

      let preNode = findByTag(panel, "pre")
      check preNode != nil

      let overlay = findByClass(panel, "empty-overlay")
      check overlay != nil

      dispose()

  test "initial state shows the loading-record overlay":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTerminalOutputVM(store)
      let r = MockRenderer()

      let panel = renderTerminalOutputPanel(r, vm)
      let overlay = findByClass(panel, "empty-overlay")

      check overlay.styles["display"] == "block"
      check "Loading record output" in overlay.textContent

      dispose()

  test "post-load empty state swaps to the no-output overlay":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTerminalOutputVM(store)
      let r = MockRenderer()

      let panel = renderTerminalOutputPanel(r, vm)
      vm.setLines(@[])  # marks initialLoad = false but leaves lines empty

      let overlay = findByClass(panel, "empty-overlay")
      check overlay.styles["display"] == "block"
      check "does not print anything" in overlay.textContent

      dispose()

# ---------------------------------------------------------------------------
# Terminal Output line rendering tests
# ---------------------------------------------------------------------------

suite "IsoNim Terminal Output Panel — line rendering":

  test "setLines populates one terminal-line per line with the expected id":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTerminalOutputVM(store)
      let r = MockRenderer()

      let panel = renderTerminalOutputPanel(r, vm)

      vm.setLines(@[
        makeTerminalLine(0, @[makeTerminalFragment("hello")]),
        makeTerminalLine(1, @[makeTerminalFragment("world")]),
      ])

      let lineNodes = findAllByClass(panel, "terminal-line")
      check lineNodes.len == 2
      check lineNodes[0].attributes["id"] == "terminal-line-0"
      check lineNodes[1].attributes["id"] == "terminal-line-1"

      # Empty overlay is hidden once lines are present.
      let overlay = findByClass(panel, "empty-overlay")
      check overlay.styles["display"] == "none"

      dispose()

  test "fragments render with the line's text content":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTerminalOutputVM(store)
      let r = MockRenderer()

      let panel = renderTerminalOutputPanel(r, vm)

      vm.setLines(@[
        makeTerminalLine(0, @[
          makeTerminalFragment("Sudoku solved:"),
          makeTerminalFragment(" 1 2 3"),
        ]),
      ])

      let lineNode = findByClass(panel, "terminal-line")
      check lineNode != nil
      check lineNode.children.len == 2
      # Concatenated text content of the line spans both fragments.
      check "Sudoku solved" in lineNode.textContent
      check "1 2 3" in lineNode.textContent

      dispose()

  test "fragment class reflects past/active/future relative to currentRRTicks":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTerminalOutputVM(store)
      let r = MockRenderer()

      let panel = renderTerminalOutputPanel(r, vm)

      # Three fragments at increasing rrTicks; pin the focus to the
      # middle one and expect past / active / future in order.
      vm.setLines(@[
        makeTerminalLine(0, @[
          makeTerminalFragment("a", eventIndex = 0, rrTicks = 5'u64),
          makeTerminalFragment("b", eventIndex = 1, rrTicks = 10'u64),
          makeTerminalFragment("c", eventIndex = 2, rrTicks = 15'u64),
        ]),
      ])
      vm.setCurrentRRTicks(10'u64)

      let lineNode = findByClass(panel, "terminal-line")
      check lineNode != nil
      check lineNode.children.len == 3
      check lineNode.children[0].attributes["class"] == "past"
      check lineNode.children[1].attributes["class"] == "active"
      check lineNode.children[2].attributes["class"] == "future"

      dispose()

  test "fragment classes update reactively when currentRRTicks changes":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTerminalOutputVM(store)
      let r = MockRenderer()

      let panel = renderTerminalOutputPanel(r, vm)

      vm.setLines(@[
        makeTerminalLine(0, @[
          makeTerminalFragment("a", eventIndex = 0, rrTicks = 100'u64),
        ]),
      ])
      vm.setCurrentRRTicks(50'u64)
      var lineNode = findByClass(panel, "terminal-line")
      check lineNode.children[0].attributes["class"] == "future"

      # Move past the fragment — class should flip to ``past``.
      vm.setCurrentRRTicks(200'u64)
      lineNode = findByClass(panel, "terminal-line")
      check lineNode.children[0].attributes["class"] == "past"

      dispose()

  test "clearLines returns the panel to the initial loading state":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTerminalOutputVM(store)
      let r = MockRenderer()

      let panel = renderTerminalOutputPanel(r, vm)

      vm.setLines(@[makeTerminalLine(0, @[makeTerminalFragment("x")])])
      check findAllByClass(panel, "terminal-line").len == 1

      vm.clearLines()

      check findAllByClass(panel, "terminal-line").len == 0
      let overlay = findByClass(panel, "empty-overlay")
      check overlay.styles["display"] == "block"
      check "Loading record output" in overlay.textContent

      dispose()

# ---------------------------------------------------------------------------
# Terminal Output interaction tests
# ---------------------------------------------------------------------------

suite "IsoNim Terminal Output Panel — interactions":

  test "fragment click dispatches ct/event-jump via the backend":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createTerminalOutputVM(store)
      let r = MockRenderer()

      let panel = renderTerminalOutputPanel(r, vm)

      vm.setLines(@[
        makeTerminalLine(0, @[
          makeTerminalFragment("hello",
                                eventIndex = 7,
                                rrTicks = 42'u64),
        ]),
      ])

      let lineNode = findByClass(panel, "terminal-line")
      let fragNode = lineNode.children[0]

      mock.clearReceivedCommands()
      fragNode.fireEvent("click")

      let req = mock.findCommand("ct/event-jump")
      check req.isSome
      check req.get.args["eventIndex"].getInt == 7
      check req.get.args["rrTicks"].getInt == 42

      dispose()

      dispose()

# ===========================================================================
# Build panel tests
# ===========================================================================
#
# Cover:
# - Outer structure (root class, header, header controls, output container).
# - Header text + class flips for the four BuildStatus values
#   (idle, running, succeeded, failed).
# - Per-line DOM produced by ``appendLine`` and the line-class hook
#   for parseable / stdout / stderr lines.
# - Reactive updates when ``output`` / ``code`` / ``running`` change.
# - Click handlers route to ``cancelBuild`` / ``clearOutput`` /
#   ``toggleAutoScroll`` via the mock backend or VM signal flips.
#
# The render-effect that builds the output container body fires
# synchronously inside the reactive root, so no ``drain()`` is needed
# between mutations and assertions.

# ---------------------------------------------------------------------------
# Build helpers
# ---------------------------------------------------------------------------

proc makeBuildLine(text: string;
                   isStdout: bool = true;
                   severity: BuildLineSeverity = blsNone;
                   path: string = "";
                   line: int = 0): BuildOutputLine =
  BuildOutputLine(
    htmlText: text,
    isStdout: isStdout,
    severity: severity,
    locationPath: path,
    locationLine: line,
  )

# ---------------------------------------------------------------------------
# Build structure tests
# ---------------------------------------------------------------------------

suite "IsoNim Build Panel — structure":

  test "renders root with build-panel class":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createBuildVM(store)
      let r = MockRenderer()

      let panel = renderBuildPanel(r, vm)

      check panel.kind == mnkElement
      check panel.tag == "div"
      check "build-panel" in panel.attributes["class"]

      dispose()

  test "renders header with controls and output container":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createBuildVM(store)
      let r = MockRenderer()

      let panel = renderBuildPanel(r, vm)

      check findByClass(panel, "build-header") != nil
      check findByClass(panel, "build-header-controls") != nil
      check findByClass(panel, "build-stop-btn") != nil
      check findByClass(panel, "build-clear-btn") != nil
      check findByClass(panel, "build-scroll-btn") != nil

      let outputContainer = findByClass(panel, "build-output-container")
      check outputContainer != nil
      check outputContainer.attributes["id"] == "build"

      dispose()

  test "header label is empty in the idle state":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createBuildVM(store)
      let r = MockRenderer()

      let panel = renderBuildPanel(r, vm)
      let label = findByClass(panel, "build-command-label")
      check label != nil
      check label.textContent == ""

      dispose()

  test "stop button starts disabled when no build is running":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createBuildVM(store)
      let r = MockRenderer()

      let panel = renderBuildPanel(r, vm)
      let stopBtn = findByClass(panel, "build-stop-btn")
      check stopBtn != nil
      # The disabled modifier class is present in the idle state.
      check "disabled" in stopBtn.attributes["class"]

      dispose()

# ---------------------------------------------------------------------------
# Build header reactive transitions
# ---------------------------------------------------------------------------

suite "IsoNim Build Panel — header reactivity":

  test "running build shows 'running <command>' header":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createBuildVM(store)
      let r = MockRenderer()

      let panel = renderBuildPanel(r, vm)

      vm.setCommand("cargo build")
      vm.setRunning(true)

      let label = findByClass(panel, "build-command-label")
      check label.textContent == "running cargo build"

      let header = findByClass(panel, "build-header")
      # No success / failure modifier while running.
      check "build-failed" notin header.attributes["class"]
      check "build-succeeded" notin header.attributes["class"]

      # Stop button leaves the disabled modifier when running.
      let stopBtn = findByClass(panel, "build-stop-btn")
      check "disabled" notin stopBtn.attributes["class"]

      dispose()

  test "successful build flips header to build-succeeded":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createBuildVM(store)
      let r = MockRenderer()

      let panel = renderBuildPanel(r, vm)

      vm.appendLine(makeBuildLine("Compiling foo"))
      vm.setCode(0)

      let label = findByClass(panel, "build-command-label")
      check label.textContent == "build succeeded"
      let header = findByClass(panel, "build-header")
      check "build-succeeded" in header.attributes["class"]

      dispose()

  test "failed build flips header to build-failed with exit code":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createBuildVM(store)
      let r = MockRenderer()

      let panel = renderBuildPanel(r, vm)

      vm.appendLine(makeBuildLine("Compiling foo"))
      vm.setCode(7)

      let label = findByClass(panel, "build-command-label")
      check label.textContent == "build failed (exit code 7)"
      let header = findByClass(panel, "build-header")
      check "build-failed" in header.attributes["class"]

      dispose()

# ---------------------------------------------------------------------------
# Build line rendering
# ---------------------------------------------------------------------------

suite "IsoNim Build Panel — line rendering":

  test "appendLine populates one output-container child per line":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createBuildVM(store)
      let r = MockRenderer()

      let panel = renderBuildPanel(r, vm)

      vm.appendLine(makeBuildLine("hello", isStdout = true))
      vm.appendLine(makeBuildLine("world", isStdout = false))

      let outputContainer = findByClass(panel, "build-output-container")
      check outputContainer.children.len == 2
      # First line is stdout.
      check outputContainer.children[0].attributes["class"] == "build-stdout"
      check outputContainer.children[0].textContent == "hello"
      # Second line is stderr.
      check outputContainer.children[1].attributes["class"] == "build-stderr"
      check outputContainer.children[1].textContent == "world"

      dispose()

  test "line with parsed location gets build-clickable + severity class":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createBuildVM(store)
      let r = MockRenderer()

      let panel = renderBuildPanel(r, vm)

      vm.appendLine(makeBuildLine(
        "src/main.nim(42, 5) Error: undeclared identifier",
        isStdout = false,
        severity = blsError,
        path = "src/main.nim",
        line = 42))

      let outputContainer = findByClass(panel, "build-output-container")
      check outputContainer.children.len == 1
      let cls = outputContainer.children[0].attributes["class"]
      check "build-output-line" in cls
      check "build-clickable" in cls
      check "build-line-error" in cls

      dispose()

  test "warning severity picks build-line-warning":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createBuildVM(store)
      let r = MockRenderer()

      let panel = renderBuildPanel(r, vm)

      vm.appendLine(makeBuildLine(
        "src/main.nim(7) Warning: unused import",
        isStdout = false,
        severity = blsWarning,
        path = "src/main.nim",
        line = 7))

      let outputContainer = findByClass(panel, "build-output-container")
      check "build-line-warning" in outputContainer.children[0].attributes["class"]

      dispose()

  test "clearOutput empties the output container and returns to idle":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createBuildVM(store)
      let r = MockRenderer()

      let panel = renderBuildPanel(r, vm)

      vm.appendLine(makeBuildLine("first"))
      vm.appendLine(makeBuildLine("second"))
      vm.setCode(1)

      let outputContainer = findByClass(panel, "build-output-container")
      check outputContainer.children.len == 2
      check vm.status.val == bsFailed

      vm.clearOutput()

      check outputContainer.children.len == 0
      check vm.status.val == bsIdle
      let label = findByClass(panel, "build-command-label")
      check label.textContent == ""

      dispose()

# ---------------------------------------------------------------------------
# Build interactions — controls map to backend / VM actions
# ---------------------------------------------------------------------------

suite "IsoNim Build Panel — interactions":

  test "stop button click dispatches ct/build-cancel while running":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createBuildVM(store)
      let r = MockRenderer()

      let panel = renderBuildPanel(r, vm)

      # Stop is a no-op when the panel is idle.  Flip to running and
      # confirm the click actually reaches the backend.
      vm.setRunning(true)
      mock.clearReceivedCommands()

      let stopBtn = findByClass(panel, "build-stop-btn")
      stopBtn.fireEvent("click")

      let req = mock.findCommand("ct/build-cancel")
      check req.isSome

      dispose()

  test "stop button is a no-op when no build is running":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createBuildVM(store)
      let r = MockRenderer()

      let panel = renderBuildPanel(r, vm)

      mock.clearReceivedCommands()
      let stopBtn = findByClass(panel, "build-stop-btn")
      stopBtn.fireEvent("click")

      check mock.findCommand("ct/build-cancel").isNone

      dispose()

  test "clear button empties the output via the VM action":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createBuildVM(store)
      let r = MockRenderer()

      let panel = renderBuildPanel(r, vm)

      vm.appendLine(makeBuildLine("noise"))
      let outputContainer = findByClass(panel, "build-output-container")
      check outputContainer.children.len == 1

      let clearBtn = findByClass(panel, "build-clear-btn")
      clearBtn.fireEvent("click")

      check outputContainer.children.len == 0
      check vm.output.val.len == 0

      dispose()

  test "auto-scroll button toggles the active modifier":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createBuildVM(store)
      let r = MockRenderer()

      let panel = renderBuildPanel(r, vm)
      let scrollBtn = findByClass(panel, "build-scroll-btn")

      # autoScroll defaults to true; the active class is present.
      check "active" in scrollBtn.attributes["class"]

      scrollBtn.fireEvent("click")
      check vm.autoScroll.val == false
      check "active" notin scrollBtn.attributes["class"]

      scrollBtn.fireEvent("click")
      check vm.autoScroll.val == true
      check "active" in scrollBtn.attributes["class"]

      dispose()

# ---------------------------------------------------------------------------
# Errors / Problems panel — value helpers and tests
# ---------------------------------------------------------------------------

proc makeProblem(severity: BuildLineSeverity;
                 path: string = "src/main.nim";
                 line: int = 1;
                 col: int = 1;
                 message: string = "diagnostic"): BuildProblemLine =
  BuildProblemLine(
    severity: severity,
    path: path,
    line: line,
    col: col,
    message: message,
  )

# ---------------------------------------------------------------------------
# Structure tests
# ---------------------------------------------------------------------------

suite "IsoNim Errors Panel — structure":

  test "renders root with problems-panel class":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createErrorsVM(store)
      let r = MockRenderer()

      let panel = renderErrorsPanel(r, vm)

      check panel.kind == mnkElement
      check panel.tag == "div"
      check "problems-panel" in panel.attributes["class"]

      dispose()

  test "renders header with counts and controls":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createErrorsVM(store)
      let r = MockRenderer()

      let panel = renderErrorsPanel(r, vm)

      check findByClass(panel, "problems-header") != nil
      check findByClass(panel, "problems-counts") != nil
      check findByClass(panel, "problems-controls") != nil
      check findByClass(panel, "problems-count-error") != nil
      check findByClass(panel, "problems-count-warning") != nil

      let listContainer = findByClass(panel, "problems-list")
      check listContainer != nil
      check listContainer.attributes["id"] == "problems-list"

      dispose()

  test "renders three filter buttons plus a Group by File toggle":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createErrorsVM(store)
      let r = MockRenderer()

      let panel = renderErrorsPanel(r, vm)

      let buttons = findAllByClass(panel, "problems-filter-btn")
      check buttons.len == 4
      # Order matches the legacy view: All, Errors, Warnings, Group by File.
      check buttons[0].textContent == "All"
      check buttons[1].textContent == "Errors"
      check buttons[2].textContent == "Warnings"
      check buttons[3].textContent == "Group by File"

      dispose()

  test "starts with the All filter active and group-by-file off":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createErrorsVM(store)
      let r = MockRenderer()

      let panel = renderErrorsPanel(r, vm)
      let buttons = findAllByClass(panel, "problems-filter-btn")

      check "active" in buttons[0].attributes["class"]
      check "active" notin buttons[1].attributes["class"]
      check "active" notin buttons[2].attributes["class"]
      check "active" notin buttons[3].attributes["class"]

      dispose()

  test "renders the empty-state overlay when there are no problems":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createErrorsVM(store)
      let r = MockRenderer()

      let panel = renderErrorsPanel(r, vm)
      let empty = findByClass(panel, "problems-empty")
      check empty != nil
      check empty.textContent == "No problems detected."

      dispose()

# ---------------------------------------------------------------------------
# Header reactivity
# ---------------------------------------------------------------------------

suite "IsoNim Errors Panel — header reactivity":

  test "count badges reflect setProblems updates":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createErrorsVM(store)
      let r = MockRenderer()

      let panel = renderErrorsPanel(r, vm)

      vm.setProblems(@[
        makeProblem(blsError),
        makeProblem(blsError),
        makeProblem(blsWarning),
      ])

      let errorBadge = findByClass(panel, "problems-count-error")
      let warningBadge = findByClass(panel, "problems-count-warning")
      check errorBadge != nil
      check warningBadge != nil
      check "2" in errorBadge.textContent
      check "1" in warningBadge.textContent

      # Total badge mirrors problems.len.
      let badges = findAllByClass(panel, "problems-count-badge")
      # The third badge (no severity modifier) carries the Total label.
      var totalBadge: MockNode = nil
      for b in badges:
        if "problems-count-error" notin b.attributes["class"] and
           "problems-count-warning" notin b.attributes["class"]:
          totalBadge = b
          break
      check totalBadge != nil
      check totalBadge.textContent == "Total: 3"

      dispose()

  test "appendProblem updates the badges incrementally":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createErrorsVM(store)
      let r = MockRenderer()

      let panel = renderErrorsPanel(r, vm)
      let errorBadge = findByClass(panel, "problems-count-error")
      check "0" in errorBadge.textContent

      vm.appendProblem(makeProblem(blsError))
      check "1" in errorBadge.textContent

      vm.appendProblem(makeProblem(blsError))
      check "2" in errorBadge.textContent

      dispose()

# ---------------------------------------------------------------------------
# Row rendering
# ---------------------------------------------------------------------------

suite "IsoNim Errors Panel — row rendering":

  test "setProblems populates one row per problem":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createErrorsVM(store)
      let r = MockRenderer()

      let panel = renderErrorsPanel(r, vm)

      vm.setProblems(@[
        makeProblem(blsError, path = "a.nim", line = 10, col = 1, message = "boom"),
        makeProblem(blsWarning, path = "b.nim", line = 2, col = 5, message = "shrug"),
      ])

      let listContainer = findByClass(panel, "problems-list")
      check listContainer.children.len == 2

      let firstClass = listContainer.children[0].attributes["class"]
      let secondClass = listContainer.children[1].attributes["class"]
      check "problems-row" in firstClass
      check "problems-severity-error" in firstClass
      check "problems-severity-warning" in secondClass

      dispose()

  test "row text content carries path, location, and message":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createErrorsVM(store)
      let r = MockRenderer()

      let panel = renderErrorsPanel(r, vm)

      vm.setProblems(@[
        makeProblem(blsError, path = "src/main.nim", line = 42, col = 7,
                    message = "undeclared identifier"),
      ])

      let listContainer = findByClass(panel, "problems-list")
      let row = listContainer.children[0]
      let pathDiv = findByClass(row, "problems-path")
      let locDiv = findByClass(row, "problems-location")
      let msgDiv = findByClass(row, "problems-message")
      check pathDiv != nil
      check locDiv != nil
      check msgDiv != nil
      check pathDiv.textContent == "src/main.nim"
      check locDiv.textContent == "42:7"
      check msgDiv.textContent == "undeclared identifier"

      dispose()

  test "negative col falls back to line-only location text":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createErrorsVM(store)
      let r = MockRenderer()

      let panel = renderErrorsPanel(r, vm)

      vm.setProblems(@[
        makeProblem(blsError, path = "x.nim", line = 9, col = -1,
                    message = "no col"),
      ])

      let listContainer = findByClass(panel, "problems-list")
      let row = listContainer.children[0]
      let locDiv = findByClass(row, "problems-location")
      check locDiv.textContent == "9"

      dispose()

  test "clearProblems empties the list and shows the empty overlay":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createErrorsVM(store)
      let r = MockRenderer()

      let panel = renderErrorsPanel(r, vm)

      vm.setProblems(@[
        makeProblem(blsError),
        makeProblem(blsWarning),
      ])
      let listContainer = findByClass(panel, "problems-list")
      check listContainer.children.len == 2

      vm.clearProblems()

      # After clearing the empty-state overlay is the only child.
      check listContainer.children.len == 1
      check "problems-empty" in listContainer.children[0].attributes["class"]
      check listContainer.children[0].textContent == "No problems detected."

      dispose()

# ---------------------------------------------------------------------------
# Filter behaviour
# ---------------------------------------------------------------------------

suite "IsoNim Errors Panel — filter behaviour":

  test "Errors filter button hides warning rows reactively":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createErrorsVM(store)
      let r = MockRenderer()

      let panel = renderErrorsPanel(r, vm)

      vm.setProblems(@[
        makeProblem(blsError, path = "a.nim", line = 1),
        makeProblem(blsWarning, path = "b.nim", line = 2),
        makeProblem(blsError, path = "c.nim", line = 3),
      ])

      let listContainer = findByClass(panel, "problems-list")
      check listContainer.children.len == 3

      let buttons = findAllByClass(panel, "problems-filter-btn")
      buttons[1].fireEvent("click")
      check vm.filter.val == pfErrors

      check listContainer.children.len == 2
      for row in listContainer.children:
        check "problems-severity-error" in row.attributes["class"]
      check "active" in buttons[1].attributes["class"]
      check "active" notin buttons[0].attributes["class"]

      dispose()

  test "Warnings filter button hides error rows":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createErrorsVM(store)
      let r = MockRenderer()

      let panel = renderErrorsPanel(r, vm)

      vm.setProblems(@[
        makeProblem(blsError),
        makeProblem(blsWarning),
        makeProblem(blsWarning),
      ])

      let buttons = findAllByClass(panel, "problems-filter-btn")
      buttons[2].fireEvent("click")

      let listContainer = findByClass(panel, "problems-list")
      check listContainer.children.len == 2
      for row in listContainer.children:
        check "problems-severity-warning" in row.attributes["class"]

      dispose()

  test "All filter restores every row after a narrower filter":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createErrorsVM(store)
      let r = MockRenderer()

      let panel = renderErrorsPanel(r, vm)

      vm.setProblems(@[
        makeProblem(blsError),
        makeProblem(blsWarning),
      ])

      let buttons = findAllByClass(panel, "problems-filter-btn")
      buttons[1].fireEvent("click")
      check findByClass(panel, "problems-list").children.len == 1

      buttons[0].fireEvent("click")
      check vm.filter.val == pfAll
      check findByClass(panel, "problems-list").children.len == 2

      dispose()

  test "Empty filtered result shows the empty-state overlay":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createErrorsVM(store)
      let r = MockRenderer()

      let panel = renderErrorsPanel(r, vm)

      vm.setProblems(@[
        makeProblem(blsWarning),
      ])

      # Filter to errors -> the single warning row drops out.
      let buttons = findAllByClass(panel, "problems-filter-btn")
      buttons[1].fireEvent("click")

      let listContainer = findByClass(panel, "problems-list")
      check listContainer.children.len == 1
      check "problems-empty" in listContainer.children[0].attributes["class"]

      dispose()

# ---------------------------------------------------------------------------
# Group by file behaviour
# ---------------------------------------------------------------------------

suite "IsoNim Errors Panel — group-by-file":

  test "Group by File toggles the grouped layout reactively":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createErrorsVM(store)
      let r = MockRenderer()

      let panel = renderErrorsPanel(r, vm)

      vm.setProblems(@[
        makeProblem(blsError, path = "a.nim", line = 1),
        makeProblem(blsError, path = "a.nim", line = 9),
        makeProblem(blsWarning, path = "b.nim", line = 7),
      ])

      let buttons = findAllByClass(panel, "problems-filter-btn")
      buttons[3].fireEvent("click")
      check vm.groupByFile.val == true

      let listContainer = findByClass(panel, "problems-list")
      # Grouped wrapper exists, with one file group per distinct path.
      let grouped = findByClass(listContainer, "problems-grouped")
      check grouped != nil

      let headers = findAllByClass(panel, "problems-file-header")
      check headers.len == 2
      check headers[0].textContent == "a.nim (2)"
      check headers[1].textContent == "b.nim (1)"

      # Each group contains the rows for its path.
      let groups = findAllByClass(panel, "problems-file-group")
      check groups.len == 2
      let firstGroupRows = findAllByClass(groups[0], "problems-row")
      check firstGroupRows.len == 2

      dispose()

# ---------------------------------------------------------------------------
# Interactions — row click dispatches a backend request
# ---------------------------------------------------------------------------

suite "IsoNim Errors Panel — interactions":

  test "row click dispatches ct/jump-location with path + line":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createErrorsVM(store)
      let r = MockRenderer()

      let panel = renderErrorsPanel(r, vm)

      vm.setProblems(@[
        makeProblem(blsError, path = "src/main.nim", line = 17),
      ])
      mock.clearReceivedCommands()

      let listContainer = findByClass(panel, "problems-list")
      let row = listContainer.children[0]
      row.fireEvent("click")

      let req = mock.findCommand("ct/jump-location")
      check req.isSome
      check req.get.args{"path"}.getStr == "src/main.nim"
      check req.get.args{"line"}.getInt == 17

      dispose()

  test "row click captures the right problem under group-by-file":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createErrorsVM(store)
      let r = MockRenderer()

      let panel = renderErrorsPanel(r, vm)

      vm.setProblems(@[
        makeProblem(blsError, path = "a.nim", line = 5),
        makeProblem(blsError, path = "b.nim", line = 9),
      ])
      vm.setGroupByFile(true)
      mock.clearReceivedCommands()

      # Click the second row which lives under the "b.nim" group.
      let groups = findAllByClass(panel, "problems-file-group")
      check groups.len == 2
      let bGroupRows = findAllByClass(groups[1], "problems-row")
      check bGroupRows.len == 1
      bGroupRows[0].fireEvent("click")

      let req = mock.findCommand("ct/jump-location")
      check req.isSome
      check req.get.args{"path"}.getStr == "b.nim"
      check req.get.args{"line"}.getInt == 9

      dispose()

# ===========================================================================
# IsoNim Search Results Panel — tests
#
# Cover the IsoNim Search Results view introduced in section 1.X of the
# migration handoff (the third and final ``vnodeToDom`` Karax bridge to
# come off after build / errors).  Verifies the same flows the legacy
# Karax view used to support: panel structure, header count badge,
# match-row rendering with grouping by file, query highlighting, filter
# narrowing, active / inactive root modifier, and click → jump-location
# routing.
# ===========================================================================

proc makeResult(path: string = "src/main.nim";
                line: int = 1;
                text: string = "match snippet"): SearchResultLine =
  SearchResultLine(text: text, path: path, line: line)

# ---------------------------------------------------------------------------
# Structure
# ---------------------------------------------------------------------------

suite "IsoNim Search Results Panel — structure":

  test "renders root with component-container + search-results classes":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchResultsVM(store)
      let r = MockRenderer()

      let panel = renderSearchResultsPanel(r, vm)

      check panel.kind == mnkElement
      check panel.tag == "div"
      let cls = panel.attributes["class"]
      check "component-container" in cls
      check "search-results" in cls

      dispose()

  test "starts inactive (search-results-non-active modifier)":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchResultsVM(store)
      let r = MockRenderer()

      let panel = renderSearchResultsPanel(r, vm)
      check "search-results-non-active" in panel.attributes["class"]
      check "search-results-active" notin panel.attributes["class"]

      dispose()

  test "renders header, find-query input, and body container":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchResultsVM(store)
      let r = MockRenderer()

      let panel = renderSearchResultsPanel(r, vm)

      check findByClass(panel, "search-results-header") != nil
      check findByClass(panel, "search-results-count") != nil
      check findByClass(panel, "search-results-find-query") != nil
      check findByClass(panel, "search-results-body") != nil

      dispose()

  test "header count starts at \"No results\" with no rows":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchResultsVM(store)
      let r = MockRenderer()

      let panel = renderSearchResultsPanel(r, vm)
      let count = findByClass(panel, "search-results-count")
      check count != nil
      check count.textContent == "No results"

      dispose()

  test "renders the empty-state overlay when there are no results":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchResultsVM(store)
      let r = MockRenderer()

      let panel = renderSearchResultsPanel(r, vm)
      let empty = findByClass(panel, "search-results-empty")
      check empty != nil
      check empty.textContent == "Run a search to see results here."

      dispose()

# ---------------------------------------------------------------------------
# Header reactivity
# ---------------------------------------------------------------------------

suite "IsoNim Search Results Panel — header reactivity":

  test "header count badge reflects setResults updates":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchResultsVM(store)
      let r = MockRenderer()

      let panel = renderSearchResultsPanel(r, vm)

      vm.setResults(@[
        makeResult(path = "a.nim", line = 1),
        makeResult(path = "a.nim", line = 2),
        makeResult(path = "b.nim", line = 7),
      ])

      let count = findByClass(panel, "search-results-count")
      check count != nil
      check count.textContent == "3 results"

      dispose()

  test "single-result count uses the singular noun":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchResultsVM(store)
      let r = MockRenderer()

      let panel = renderSearchResultsPanel(r, vm)
      vm.setResults(@[makeResult()])
      let count = findByClass(panel, "search-results-count")
      check count.textContent == "1 result"

      dispose()

  test "appendResults updates the badge incrementally":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchResultsVM(store)
      let r = MockRenderer()

      let panel = renderSearchResultsPanel(r, vm)
      let count = findByClass(panel, "search-results-count")
      check count.textContent == "No results"

      vm.appendResults(@[makeResult()])
      check count.textContent == "1 result"

      vm.appendResults(@[makeResult(line = 9), makeResult(line = 10)])
      check count.textContent == "3 results"

      dispose()

  test "panel root flips to search-results-active when results arrive":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchResultsVM(store)
      let r = MockRenderer()

      let panel = renderSearchResultsPanel(r, vm)
      check "search-results-non-active" in panel.attributes["class"]

      vm.setResults(@[makeResult()])

      check "search-results-active" in panel.attributes["class"]
      check "search-results-non-active" notin panel.attributes["class"]

      dispose()

# ---------------------------------------------------------------------------
# Row rendering — grouped by file
# ---------------------------------------------------------------------------

suite "IsoNim Search Results Panel — row rendering":

  test "setResults populates one match row per result, grouped by path":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchResultsVM(store)
      let r = MockRenderer()

      let panel = renderSearchResultsPanel(r, vm)

      vm.setResults(@[
        makeResult(path = "a.nim", line = 1, text = "let x = 1"),
        makeResult(path = "a.nim", line = 9, text = "let y = 2"),
        makeResult(path = "b.nim", line = 3, text = "echo z"),
      ])

      let rows = findAllByClass(panel, "search-results-match-row")
      check rows.len == 3

      let groups = findAllByClass(panel, "search-results-file-group")
      check groups.len == 2

      dispose()

  test "file-header preserves first-appearance order with row count":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchResultsVM(store)
      let r = MockRenderer()

      let panel = renderSearchResultsPanel(r, vm)

      vm.setResults(@[
        makeResult(path = "z.nim", line = 1),
        makeResult(path = "a.nim", line = 2),
        makeResult(path = "z.nim", line = 5),
      ])

      let headers = findAllByClass(panel, "search-results-file-header")
      check headers.len == 2

      let firstPath = findByClass(headers[0], "search-results-file-path")
      let firstCount = findByClass(headers[0], "search-results-file-count")
      check firstPath != nil
      check firstCount != nil
      check firstPath.textContent == "z.nim"
      check firstCount.textContent == " (2)"

      let secondPath = findByClass(headers[1], "search-results-file-path")
      let secondCount = findByClass(headers[1], "search-results-file-count")
      check secondPath.textContent == "a.nim"
      check secondCount.textContent == " (1)"

      dispose()

  test "row text content carries line number and snippet":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchResultsVM(store)
      let r = MockRenderer()

      let panel = renderSearchResultsPanel(r, vm)

      vm.setResults(@[makeResult(path = "main.nim", line = 42,
                                 text = "let foo = 1")])

      let rows = findAllByClass(panel, "search-results-match-row")
      check rows.len == 1
      let lineNum = findByClass(rows[0], "search-results-line-number")
      let matchText = findByClass(rows[0], "search-results-match-text")
      check lineNum != nil
      check matchText != nil
      check lineNum.textContent == "42"
      check matchText.textContent == "let foo = 1"

      dispose()

  test "clearResults empties the list and re-shows the empty overlay":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchResultsVM(store)
      let r = MockRenderer()

      let panel = renderSearchResultsPanel(r, vm)

      vm.setResults(@[makeResult(), makeResult(line = 2)])
      check findAllByClass(panel, "search-results-match-row").len == 2

      vm.clearResults()

      let body = findByClass(panel, "search-results-body")
      check body.children.len == 1
      check "search-results-empty" in body.children[0].attributes["class"]
      # And the panel root flips back to non-active.
      check "search-results-non-active" in panel.attributes["class"]

      dispose()

# ---------------------------------------------------------------------------
# Query highlighting
# ---------------------------------------------------------------------------

suite "IsoNim Search Results Panel — query highlighting":

  test "matched substring is wrapped in a search-results-highlight span":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchResultsVM(store)
      let r = MockRenderer()

      let panel = renderSearchResultsPanel(r, vm)

      vm.setQuery("foo")
      vm.setResults(@[makeResult(text = "let foo = 1")])

      let highlight = findByClass(panel, "search-results-highlight")
      check highlight != nil
      check highlight.textContent == "foo"

      dispose()

  test "case-insensitive match still highlights with original casing":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchResultsVM(store)
      let r = MockRenderer()

      let panel = renderSearchResultsPanel(r, vm)

      vm.setQuery("FOO")
      vm.setResults(@[makeResult(text = "let foo = 1")])

      let highlight = findByClass(panel, "search-results-highlight")
      check highlight != nil
      # The highlighted substring carries the source-text casing, not the
      # query casing — same behaviour as the legacy ``highlightMatch``.
      check highlight.textContent == "foo"

      dispose()

  test "no highlight span is emitted when the query does not match":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchResultsVM(store)
      let r = MockRenderer()

      let panel = renderSearchResultsPanel(r, vm)

      vm.setQuery("bar")
      vm.setResults(@[makeResult(text = "let foo = 1")])

      check findByClass(panel, "search-results-highlight") == nil

      dispose()

# ---------------------------------------------------------------------------
# Filter behaviour
# ---------------------------------------------------------------------------

suite "IsoNim Search Results Panel — filter behaviour":

  test "setFilter narrows the visible rows reactively":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchResultsVM(store)
      let r = MockRenderer()

      let panel = renderSearchResultsPanel(r, vm)

      vm.setResults(@[
        makeResult(path = "a.nim", line = 1, text = "alpha"),
        makeResult(path = "b.nim", line = 2, text = "beta"),
        makeResult(path = "c.nim", line = 3, text = "alpha gamma"),
      ])

      check findAllByClass(panel, "search-results-match-row").len == 3

      vm.setFilter("alpha")

      let visible = findAllByClass(panel, "search-results-match-row")
      check visible.len == 2

      # The header count tracks the unfiltered total — same as the
      # legacy view (the count is "results" from the search service,
      # the filter narrows display only).
      let count = findByClass(panel, "search-results-count")
      check count.textContent == "3 results"

      dispose()

  test "filter that excludes everything re-shows the empty overlay":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchResultsVM(store)
      let r = MockRenderer()

      let panel = renderSearchResultsPanel(r, vm)

      vm.setResults(@[
        makeResult(path = "a.nim", line = 1, text = "alpha"),
      ])
      check findAllByClass(panel, "search-results-match-row").len == 1

      vm.setFilter("nothingmatchesthis")
      let body = findByClass(panel, "search-results-body")
      check body.children.len == 1
      check "search-results-empty" in body.children[0].attributes["class"]

      dispose()

  test "empty filter restores every row":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchResultsVM(store)
      let r = MockRenderer()

      let panel = renderSearchResultsPanel(r, vm)

      vm.setResults(@[
        makeResult(path = "a.nim", line = 1, text = "alpha"),
        makeResult(path = "b.nim", line = 2, text = "beta"),
      ])

      vm.setFilter("alpha")
      check findAllByClass(panel, "search-results-match-row").len == 1

      vm.setFilter("")
      check findAllByClass(panel, "search-results-match-row").len == 2

      dispose()

# ---------------------------------------------------------------------------
# Interactions — row click dispatches a backend request
# ---------------------------------------------------------------------------

suite "IsoNim Search Results Panel — interactions":

  test "row click dispatches ct/jump-location with path + line":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createSearchResultsVM(store)
      let r = MockRenderer()

      let panel = renderSearchResultsPanel(r, vm)

      vm.setResults(@[makeResult(path = "src/main.nim", line = 17,
                                 text = "let foo = 1")])
      mock.clearReceivedCommands()

      let rows = findAllByClass(panel, "search-results-match-row")
      check rows.len == 1
      rows[0].fireEvent("click")

      let req = mock.findCommand("ct/jump-location")
      check req.isSome
      check req.get.args{"path"}.getStr == "src/main.nim"
      check req.get.args{"line"}.getInt == 17

      dispose()

  test "row click captures the right result under file grouping":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createSearchResultsVM(store)
      let r = MockRenderer()

      let panel = renderSearchResultsPanel(r, vm)

      vm.setResults(@[
        makeResult(path = "a.nim", line = 5, text = "first"),
        makeResult(path = "b.nim", line = 9, text = "second"),
        makeResult(path = "b.nim", line = 12, text = "third"),
      ])
      mock.clearReceivedCommands()

      # Click the third row, which lives under the second file group.
      let groups = findAllByClass(panel, "search-results-file-group")
      check groups.len == 2
      let bGroupRows = findAllByClass(groups[1], "search-results-match-row")
      check bGroupRows.len == 2
      bGroupRows[1].fireEvent("click")

      let req = mock.findCommand("ct/jump-location")
      check req.isSome
      check req.get.args{"path"}.getStr == "b.nim"
      check req.get.args{"line"}.getInt == 12

      dispose()

# ===========================================================================
# No-source panel tests
# ===========================================================================
#
# Cover:
# - Outer structure (root class, header text, content wrapper).
# - Default empty state — no message, default location, no history.
# - Reactive updates when ``message``, ``location``, ``history``,
#   ``originatingAddress``, and ``stopSignalText`` change.
# - The Jump-back button click forwards through to the backend via
#   ``ct/history-jump`` carrying the previous-path metadata.
#
# The render-effects that own the body and the trailing rows fire
# whenever any of their input signals change, so each test mutates a
# signal after rendering and asserts the resulting tree.

suite "IsoNim No-Source Panel — structure":

  test "renders root with the unknown-location class":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createNoSourceVM(store)
      let r = MockRenderer()

      let panel = renderNoSourcePanel(r, vm)

      check panel.kind == mnkElement
      check panel.tag == "div"
      check "unknown-location" in panel.attributes["class"]

      dispose()

  test "renders the Whoops! header and the content wrapper":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createNoSourceVM(store)
      let r = MockRenderer()

      let panel = renderNoSourcePanel(r, vm)

      let header = findByClass(panel, "unknown-location-header")
      check header != nil
      check "Whoops" in header.textContent

      let content = findByClass(panel, "unknown-location-content")
      check content != nil

      dispose()

  test "default state renders only the location border (no message, no history)":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createNoSourceVM(store)
      let r = MockRenderer()

      let panel = renderNoSourcePanel(r, vm)

      let borders = findAllByClass(panel, "unknown-border")
      # Only the location border (no message border, no history blocks).
      check borders.len == 1

      let messageNode = findByClass(panel, "unknown-location-message")
      check messageNode == nil

      let buttonNode = findByClass(panel, "jump-back-button")
      check buttonNode == nil

      dispose()

# ---------------------------------------------------------------------------
# No-source content tests
# ---------------------------------------------------------------------------

suite "IsoNim No-Source Panel — content":

  test "setMessage adds the unknown-location-message paragraph":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createNoSourceVM(store)
      let r = MockRenderer()

      let panel = renderNoSourcePanel(r, vm)

      vm.setMessage("Source not available for this frame")

      let messageNode = findByClass(panel, "unknown-location-message")
      check messageNode != nil
      check "Source not available" in messageNode.textContent

      dispose()

  test "setLocation populates the function/path/line rows":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createNoSourceVM(store)
      let r = MockRenderer()

      let panel = renderNoSourcePanel(r, vm)

      vm.setLocation(NoSourceLocationInfo(
        functionName: "main",
        path: "src/example.nim",
        line: 42,
      ))

      check "Function: 'main'" in panel.textContent
      check "Path: 'src/example.nim'" in panel.textContent
      check "Line: '42'" in panel.textContent

      dispose()

  test "setLocation hides path row when path is empty":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createNoSourceVM(store)
      let r = MockRenderer()

      let panel = renderNoSourcePanel(r, vm)

      vm.setLocation(NoSourceLocationInfo(
        functionName: "main",
        path: "",
        line: 42,
      ))

      check "Function: 'main'" in panel.textContent
      check "Path:" notin panel.textContent
      check "Line: '42'" in panel.textContent

      dispose()

  test "setLocation hides line row when line is negative":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createNoSourceVM(store)
      let r = MockRenderer()

      let panel = renderNoSourcePanel(r, vm)

      vm.setLocation(NoSourceLocationInfo(
        functionName: "main",
        path: "src/example.nim",
        line: -1,
      ))

      check "Function: 'main'" in panel.textContent
      check "Path: 'src/example.nim'" in panel.textContent
      check "Line:" notin panel.textContent

      dispose()

  test "setOriginatingAddress adds the trailing address paragraph":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createNoSourceVM(store)
      let r = MockRenderer()

      let panel = renderNoSourcePanel(r, vm)

      vm.setOriginatingAddress("0xdeadbeef")

      let addressNode = findByClass(panel, "unknown-location-address")
      check addressNode != nil
      check "Originating address: 0xdeadbeef" in addressNode.textContent

      dispose()

  test "setStopSignalText adds the trailing signal paragraph":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createNoSourceVM(store)
      let r = MockRenderer()

      let panel = renderNoSourcePanel(r, vm)

      vm.setStopSignalText("SIGSEGV")

      let signalNode = findByClass(panel, "unknown-location-signal")
      check signalNode != nil
      check "Signal received: SIGSEGV" in signalNode.textContent

      dispose()

# ---------------------------------------------------------------------------
# No-source history tests
# ---------------------------------------------------------------------------

suite "IsoNim No-Source Panel — history":

  test "setHistory(hasHistory=true) adds the context block and Jump-back button":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createNoSourceVM(store)
      let r = MockRenderer()

      let panel = renderNoSourcePanel(r, vm)

      vm.setHistory(NoSourceHistoryInfo(
        hasHistory: true,
        previousPath: "src/main.nim",
        action: "step",
      ))

      check "We were in 'src/main.nim'" in panel.textContent
      check "operation: 'step'" in panel.textContent

      let buttonNode = findByClass(panel, "jump-back-button")
      check buttonNode != nil
      check "Jump back" in buttonNode.textContent

      dispose()

  test "setHistory(hasHistory=false) removes the history blocks":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createNoSourceVM(store)
      let r = MockRenderer()

      let panel = renderNoSourcePanel(r, vm)

      # First populate.
      vm.setHistory(NoSourceHistoryInfo(
        hasHistory: true,
        previousPath: "src/main.nim",
        action: "step",
      ))
      check findByClass(panel, "jump-back-button") != nil

      # Then clear.
      vm.setHistory(NoSourceHistoryInfo())
      check findByClass(panel, "jump-back-button") == nil
      check "We were in" notin panel.textContent

      dispose()

  test "history block is hidden when action is empty (matches legacy guard)":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createNoSourceVM(store)
      let r = MockRenderer()

      let panel = renderNoSourcePanel(r, vm)

      # ``hasHistory`` true but no action — the legacy view kept the
      # history block hidden under the same circumstance.
      vm.setHistory(NoSourceHistoryInfo(
        hasHistory: true,
        previousPath: "src/main.nim",
        action: "",
      ))

      check findByClass(panel, "jump-back-button") == nil
      check "We were in" notin panel.textContent

      dispose()

# ---------------------------------------------------------------------------
# No-source interaction tests
# ---------------------------------------------------------------------------

suite "IsoNim No-Source Panel — interactions":

  test "Jump-back click dispatches ct/history-jump via the backend":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createNoSourceVM(store)
      let r = MockRenderer()

      let panel = renderNoSourcePanel(r, vm)

      vm.setHistory(NoSourceHistoryInfo(
        hasHistory: true,
        previousPath: "src/main.nim",
        action: "step",
      ))
      mock.clearReceivedCommands()

      let buttonNode = findByClass(panel, "jump-back-button")
      check buttonNode != nil
      buttonNode.fireEvent("click")

      let req = mock.findCommand("ct/history-jump")
      check req.isSome
      check req.get.args{"previousPath"}.getStr == "src/main.nim"
      check req.get.args{"action"}.getStr == "step"

      dispose()

  test "Jump-back is a no-op when there is no history":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createNoSourceVM(store)
      let r = MockRenderer()

      let panel = renderNoSourcePanel(r, vm)

      mock.clearReceivedCommands()
      vm.jumpBack()

      let req = mock.findCommand("ct/history-jump")
      check req.isNone

      dispose()

# ===========================================================================
# Step List panel tests
# ===========================================================================
#
# Cover:
# - Outer structure (root .step-list class, .step-lines container,
#   default empty state).
# - VM ordering invariants: ``setLineSteps`` sorts by ``delta`` and
#   ``appendLineSteps`` re-sorts after a streamed append.
# - Row variants: Line / Call / Return each emit the legacy class
#   hooks (``.step-line-flow-value``, ``.step-line-args``,
#   ``.step-line-return-value``) so any CSS / Playwright selector
#   keeps working.
# - Active-row highlight: ``setCurrentLocation`` flips the
#   ``active-step-line`` modifier on the row whose location matches
#   the live debugger position (rrTicks + path + line).
# - Click-to-jump: clicking a Line row dispatches ``ct/line-step-jump``
#   with the row's ``delta`` / ``rrTicks`` / ``path`` / ``line``.
# - Backend request shape: ``loadStepLinesFor`` emits
#   ``ct/load-step-lines`` with ``path`` / ``line`` / ``rrTicks`` /
#   ``count`` and the panel-height plumbing.

proc makeLineStep(delta: int; path: string; line: int; rrTicks: int;
                  fn: string = "f"; src: string = "x = 1"): StepLine =
  StepLine(
    kind: slkLine,
    delta: delta,
    location: StepLineLocation(
      path: path,
      line: line,
      functionName: fn,
      rrTicks: rrTicks,
    ),
    sourceLine: src,
    values: @[],
  )

proc makeCallStep(delta: int; src: string;
                  args: seq[StepLineFlowValue]): StepLine =
  StepLine(
    kind: slkCall,
    delta: delta,
    location: StepLineLocation(),
    sourceLine: src,
    values: args,
  )

proc makeReturnStep(delta: int; src: string;
                    ret: seq[StepLineFlowValue]): StepLine =
  StepLine(
    kind: slkReturn,
    delta: delta,
    location: StepLineLocation(),
    sourceLine: src,
    values: ret,
  )

suite "IsoNim Step List Panel — structure":

  test "renders root with the step-list class":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStepListVM(store)
      let r = MockRenderer()

      let panel = renderStepListPanel(r, vm)

      check panel.kind == mnkElement
      check panel.tag == "div"
      check "step-list" in panel.attributes["class"]

      dispose()

  test "renders step-list-lines-box and step-lines containers":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStepListVM(store)
      let r = MockRenderer()

      let panel = renderStepListPanel(r, vm)

      check findByClass(panel, "step-list-lines-box") != nil
      check findByClass(panel, "step-lines") != nil

      dispose()

  test "default state renders no rows":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStepListVM(store)
      let r = MockRenderer()

      let panel = renderStepListPanel(r, vm)

      let rows = findAllByClass(panel, "step-line")
      check rows.len == 0

      dispose()

# ---------------------------------------------------------------------------
# VM ordering invariants
# ---------------------------------------------------------------------------

suite "IsoNim Step List Panel — ordering":

  test "setLineSteps sorts rows by delta":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStepListVM(store)
      let r = MockRenderer()

      let panel = renderStepListPanel(r, vm)

      vm.setLineSteps(@[
        makeLineStep(2, "a.nim", 10, 100),
        makeLineStep(-1, "a.nim", 9, 99),
        makeLineStep(0, "a.nim", 9, 99),
      ])

      check vm.lineSteps.val.len == 3
      check vm.lineSteps.val[0].delta == -1
      check vm.lineSteps.val[1].delta == 0
      check vm.lineSteps.val[2].delta == 2

      let rows = findAllByClass(panel, "step-line")
      check rows.len == 3

      dispose()

  test "appendLineSteps re-sorts after streamed append":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStepListVM(store)
      let r = MockRenderer()

      discard renderStepListPanel(r, vm)

      vm.setLineSteps(@[
        makeLineStep(0, "a.nim", 9, 99),
        makeLineStep(2, "a.nim", 10, 100),
      ])

      # Streamed batch arrives out of order — appendLineSteps must
      # re-sort by delta so the panel stays in display order.
      vm.appendLineSteps(@[
        makeLineStep(-1, "a.nim", 8, 98),
        makeLineStep(1, "a.nim", 10, 100),
      ])

      check vm.lineSteps.val.len == 4
      check vm.lineSteps.val[0].delta == -1
      check vm.lineSteps.val[1].delta == 0
      check vm.lineSteps.val[2].delta == 1
      check vm.lineSteps.val[3].delta == 2

      dispose()

  test "appendLineSteps with empty input is a no-op":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStepListVM(store)

      vm.setLineSteps(@[
        makeLineStep(0, "a.nim", 9, 99),
        makeLineStep(1, "a.nim", 10, 100),
      ])
      vm.appendLineSteps(@[])

      check vm.lineSteps.val.len == 2

      dispose()

  test "clearLineSteps empties the row list":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStepListVM(store)
      let r = MockRenderer()

      let panel = renderStepListPanel(r, vm)
      vm.setLineSteps(@[makeLineStep(0, "a.nim", 9, 99)])
      check findAllByClass(panel, "step-line").len == 1

      vm.clearLineSteps()
      check findAllByClass(panel, "step-line").len == 0
      check vm.isEmpty.val == true

      dispose()

# ---------------------------------------------------------------------------
# Row rendering — Line / Call / Return variants.
# ---------------------------------------------------------------------------

suite "IsoNim Step List Panel — row rendering":

  test "Line row emits delta + location + source code spans":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStepListVM(store)
      let r = MockRenderer()

      let panel = renderStepListPanel(r, vm)

      vm.setLineSteps(@[
        StepLine(
          kind: slkLine,
          delta: -2,
          location: StepLineLocation(
            path: "src/example.nim",
            line: 42,
            functionName: "main",
            rrTicks: 100,
          ),
          sourceLine: "echo 1",
          values: @[],
        )
      ])

      check findByClass(panel, "step-line-delta") != nil
      check findByClass(panel, "step-line-location") != nil
      check findByClass(panel, "step-line-source-code") != nil
      check "-2" in panel.textContent
      check "example.nim:42[main]" in panel.textContent
      check "echo 1" in panel.textContent

      dispose()

  test "Line row renders flow values inline":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStepListVM(store)
      let r = MockRenderer()

      let panel = renderStepListPanel(r, vm)

      var line = makeLineStep(0, "a.nim", 9, 99)
      line.values = @[
        StepLineFlowValue(expression: "x", value: "1"),
        StepLineFlowValue(expression: "y", value: "2"),
      ]
      vm.setLineSteps(@[line])

      let flows = findAllByClass(panel, "step-line-flow-value")
      check flows.len == 2
      check "x" in flows[0].textContent
      check "1" in flows[0].textContent
      check "y" in flows[1].textContent
      check "2" in flows[1].textContent

      dispose()

  test "Call row emits step-line-call class and args":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStepListVM(store)
      let r = MockRenderer()

      let panel = renderStepListPanel(r, vm)

      vm.setLineSteps(@[
        makeCallStep(0, "f(x, y)", @[
          StepLineFlowValue(expression: "x", value: "1"),
          StepLineFlowValue(expression: "y", value: "2"),
        ])
      ])

      let callRow = findByClass(panel, "step-line-call")
      check callRow != nil
      check "f(x, y)" in callRow.textContent
      let args = findAllByClass(panel, "step-line-value")
      check args.len == 2
      check "x" in args[0].textContent
      check "1" in args[0].textContent

      dispose()

  test "Return row renders only the first value":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStepListVM(store)
      let r = MockRenderer()

      let panel = renderStepListPanel(r, vm)

      vm.setLineSteps(@[
        makeReturnStep(0, "return 42", @[
          StepLineFlowValue(expression: "->", value: "42"),
          # Extra entries past the first must NOT be rendered (legacy
          # guard: ``if values.len > 0: text values[0].expression``).
          StepLineFlowValue(expression: "ignored", value: "99"),
        ])
      ])

      let returnRow = findByClass(panel, "step-line-return")
      check returnRow != nil
      check "return 42" in returnRow.textContent

      let retValue = findByClass(panel, "step-line-return-value")
      check retValue != nil
      check "->" in retValue.textContent
      check "42" in retValue.textContent
      # The second entry must be absent.
      check "ignored" notin returnRow.textContent
      check "99" notin returnRow.textContent

      dispose()

  test "Return row with no values omits the return-value span":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStepListVM(store)
      let r = MockRenderer()

      let panel = renderStepListPanel(r, vm)

      vm.setLineSteps(@[makeReturnStep(0, "return", @[])])

      check findByClass(panel, "step-line-return") != nil
      check findByClass(panel, "step-line-return-value") == nil

      dispose()

  test "renders Line / Call / Return rows together in delta order":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStepListVM(store)
      let r = MockRenderer()

      let panel = renderStepListPanel(r, vm)

      vm.setLineSteps(@[
        makeReturnStep(2, "return 1", @[]),
        makeLineStep(0, "a.nim", 9, 99),
        makeCallStep(1, "f()", @[]),
      ])

      let rows = findAllByClass(panel, "step-line")
      check rows.len == 3
      # Sort by delta: 0, 1, 2.
      check "active-step-line" notin rows[0].attributes["class"]
        # placeholder: Line at delta 0 is not current because no
        # currentLocation has been set yet (default rrTicks = 0).
      check "step-line-call" in rows[1].attributes["class"]
      check "step-line-return" in rows[2].attributes["class"]

      dispose()

# ---------------------------------------------------------------------------
# Active-row highlight
# ---------------------------------------------------------------------------

suite "IsoNim Step List Panel — active row":

  test "setCurrentLocation flips the active-step-line modifier":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStepListVM(store)
      let r = MockRenderer()

      let panel = renderStepListPanel(r, vm)

      vm.setLineSteps(@[
        makeLineStep(-1, "a.nim", 9, 98),
        makeLineStep(0, "a.nim", 10, 99),
        makeLineStep(1, "a.nim", 11, 100),
      ])
      vm.setCurrentLocation(StepLineLocation(
        path: "a.nim", line: 10, rrTicks: 99))

      let rows = findAllByClass(panel, "step-line")
      check rows.len == 3
      check "active-step-line" notin rows[0].attributes["class"]
      check "active-step-line" in rows[1].attributes["class"]
      check "active-step-line" notin rows[2].attributes["class"]

      # The active row's <pre> wrapper also flips classes.
      let pres = findAllByClass(panel, "step-line-pre")
      check pres.len == 3
      check "active-step-line-pre" in pres[1].attributes["class"]
      check "inactive-step-line-pre" in pres[0].attributes["class"]

      dispose()

  test "isCurrentRow matches on rrTicks + path + line triple":
    let line = makeLineStep(0, "a.nim", 10, 99)

    # Exact match.
    check isCurrentRow(line, StepLineLocation(
      path: "a.nim", line: 10, rrTicks: 99))
    # Mismatched rrTicks.
    check not isCurrentRow(line, StepLineLocation(
      path: "a.nim", line: 10, rrTicks: 100))
    # Mismatched path.
    check not isCurrentRow(line, StepLineLocation(
      path: "b.nim", line: 10, rrTicks: 99))
    # Mismatched line.
    check not isCurrentRow(line, StepLineLocation(
      path: "a.nim", line: 11, rrTicks: 99))

# ---------------------------------------------------------------------------
# Backend request shape
# ---------------------------------------------------------------------------

suite "IsoNim Step List Panel — backend requests":

  test "loadStepLinesFor emits ct/load-step-lines with location + count":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createStepListVM(store)

      vm.setPanelHeight(20)
      mock.clearReceivedCommands()

      vm.loadStepLinesFor(StepLineLocation(
        path: "src/main.nim", line: 7, rrTicks: 42))

      let req = mock.findCommand("ct/load-step-lines")
      check req.isSome
      check req.get.args{"path"}.getStr == "src/main.nim"
      check req.get.args{"line"}.getInt == 7
      check req.get.args{"rrTicks"}.getInt == 42
      check req.get.args{"count"}.getInt == 20

      # Also resets the row list and refreshes the current location.
      check vm.lineSteps.val.len == 0
      check vm.currentLocation.val.path == "src/main.nim"
      check vm.currentLocation.val.line == 7
      check vm.currentLocation.val.rrTicks == 42

      dispose()

  test "loadStepLinesFor falls back to default panel height when unset":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createStepListVM(store)

      # Force the panelHeight signal to 0 so the legacy
      # offset-not-yet-measured path engages.
      vm.setPanelHeight(0)
      mock.clearReceivedCommands()

      vm.loadStepLinesFor(StepLineLocation(
        path: "a.nim", line: 1, rrTicks: 1))

      let req = mock.findCommand("ct/load-step-lines")
      check req.isSome
      # The default is the conservative 16-row capacity from the VM.
      check req.get.args{"count"}.getInt > 0

      dispose()

# ---------------------------------------------------------------------------
# Click → jump
# ---------------------------------------------------------------------------

suite "IsoNim Step List Panel — interactions":

  test "clicking a Line row dispatches ct/line-step-jump with delta + location":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createStepListVM(store)
      let r = MockRenderer()

      let panel = renderStepListPanel(r, vm)

      let target = StepLine(
        kind: slkLine,
        delta: 3,
        location: StepLineLocation(
          path: "src/main.nim",
          line: 17,
          functionName: "main",
          rrTicks: 142,
        ),
        sourceLine: "x = 1",
        values: @[],
      )
      vm.setLineSteps(@[target])
      mock.clearReceivedCommands()

      let row = findByClass(panel, "step-line")
      check row != nil
      row.fireEvent("click")

      let req = mock.findCommand("ct/line-step-jump")
      check req.isSome
      check req.get.args{"delta"}.getInt == 3
      check req.get.args{"path"}.getStr == "src/main.nim"
      check req.get.args{"line"}.getInt == 17
      check req.get.args{"rrTicks"}.getInt == 142

      dispose()

  test "jumpToStepLine sends the same payload when invoked directly":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createStepListVM(store)

      mock.clearReceivedCommands()
      vm.jumpToStepLine(StepLine(
        kind: slkLine,
        delta: -1,
        location: StepLineLocation(
          path: "x.nim", line: 4, rrTicks: 7),
        sourceLine: "echo",
        values: @[],
      ))

      let req = mock.findCommand("ct/line-step-jump")
      check req.isSome
      check req.get.args{"delta"}.getInt == -1
      check req.get.args{"path"}.getStr == "x.nim"
      check req.get.args{"line"}.getInt == 4
      check req.get.args{"rrTicks"}.getInt == 7

      dispose()

# ===========================================================================
# Calltrace Editor panel tests
# ===========================================================================
#
# Cover the IsoNim Calltrace Editor placeholder view introduced in
# section 1.45 of the IsoNim migration handoff.  The legacy Karax
# ``method render`` emitted only an empty
# ``<div class="component-container calltrace-editor">`` and the
# per-call helpers (``openNewCall`` / ``callView``) were not invoked
# from anywhere — they were dead-or-rarely-used helpers preserved
# across earlier refactors.  The IsoNim view keeps the same parity-
# faithful empty container so any CSS rules and Playwright selectors
# keyed on either class continue to work.
#
# Suites:
# - structure         — root class + childlessness + container constant
# - lifecycle         — markMounted / markUnmounted reactivity
# - vm                — defaults + signal independence

suite "IsoNim Calltrace Editor Panel — structure":

  test "renders root with the component-container and calltrace-editor classes":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceEditorVM(store)
      let r = MockRenderer()

      let panel = renderCalltraceEditorPanel(r, vm)

      check panel.kind == mnkElement
      check panel.tag == "div"
      let cls = panel.attributes["class"]
      check "component-container" in cls
      check "calltrace-editor" in cls

      dispose()

  test "container constant matches the legacy componentContainerClass output":
    # ``CalltraceEditorContainerClass`` mirrors what
    # ``componentContainerClass("calltrace-editor")`` produced in the
    # legacy Karax render (``"component-container calltrace-editor"``).
    # If the legacy template ever changes shape this regression test
    # will tell us before the panel-mounted DOM diverges.
    check CalltraceEditorContainerClass == "component-container calltrace-editor"

  test "renders no children — placeholder shell only":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceEditorVM(store)
      let r = MockRenderer()

      let panel = renderCalltraceEditorPanel(r, vm)

      # Match the legacy Karax ``method render`` which emitted an
      # empty container.  No headers, no buttons, no nested editors.
      check panel.children.len == 0

      dispose()

  test "renders nothing additional after re-evaluation (idempotent shell)":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceEditorVM(store)
      let r = MockRenderer()

      let panel = renderCalltraceEditorPanel(r, vm)
      let initialChildCount = panel.children.len

      # Touching the lifecycle signal must not introduce new DOM
      # children — the placeholder is intentionally inert.
      vm.markMounted()
      vm.markUnmounted()

      check panel.children.len == initialChildCount

      dispose()

# ---------------------------------------------------------------------------
# Calltrace Editor lifecycle tests
# ---------------------------------------------------------------------------

suite "IsoNim Calltrace Editor Panel — lifecycle":

  test "markMounted flips the mounted signal to true":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceEditorVM(store)

      check vm.mounted.val == false
      vm.markMounted()
      check vm.mounted.val == true

      dispose()

  test "markUnmounted flips the mounted signal back to false":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceEditorVM(store)

      vm.markMounted()
      check vm.mounted.val == true
      vm.markUnmounted()
      check vm.mounted.val == false

      dispose()

  test "render-effect runs on mount transitions without errors":
    # The placeholder view subscribes to ``mounted`` so future readers
    # establish the dependency edge.  Toggling the signal exercises
    # the reactive subscription and must not throw.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceEditorVM(store)
      let r = MockRenderer()

      discard renderCalltraceEditorPanel(r, vm)
      vm.markMounted()
      vm.markUnmounted()
      vm.markMounted()

      check vm.mounted.val == true

      dispose()

# ---------------------------------------------------------------------------
# Calltrace Editor VM defaults
# ---------------------------------------------------------------------------

suite "IsoNim Calltrace Editor Panel — vm":

  test "createCalltraceEditorVM defaults mounted to false":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceEditorVM(store)

      check vm.mounted.val == false
      check not vm.store.isNil

      dispose()

  test "two VM instances have independent mounted signals":
    # Single-instance panels in production share one VM, but the
    # constructor itself must produce isolated reactive state —
    # otherwise headless tests would leak between cases.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vmA = createCalltraceEditorVM(store)
      let vmB = createCalltraceEditorVM(store)

      vmA.markMounted()

      check vmA.mounted.val == true
      check vmB.mounted.val == false

      dispose()

# ---------------------------------------------------------------------------
# REPL Panel — display-mode dispatch
# ---------------------------------------------------------------------------
#
# These tests exercise ``renderReplPanel`` against ``ReplVM`` for each of
# the three legacy Karax branches (materialised / enabled / disabled),
# plus the imperative submit handler and the bounded-10 history slice
# rendered by ``renderHistoryEntriesMock``.  Mirrors the legacy
# ``ReplComponent.render`` shape and the ``self.history[^1].output =
# response`` mutation in ``onDebugOutput``.

suite "IsoNim REPL Panel — structure":

  test "renders root with repl-component class":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createReplVM(store)
      let r = MockRenderer()

      let panel = renderReplPanel(r, vm)

      check panel.kind == mnkElement
      check panel.tag == "div"
      check panel.attributes["class"] == "repl-component"

      dispose()

  test "defaults to disabled message branch":
    # Both ``materialized`` and ``replEnabled`` default to false in
    # ``createReplVM`` so the body should be the "REPL disabled" copy
    # — matches the legacy Karax ``else`` branch.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createReplVM(store)
      let r = MockRenderer()

      let panel = renderReplPanel(r, vm)

      check vm.displayMode.val == rdmReplDisabled
      let msg = findByClass(panel, "repl-disabled-msg")
      check msg != nil
      # Single text child carrying the verbatim disabled message.
      check msg.children.len == 1
      check msg.children[0].kind == mnkText
      check msg.children[0].text == REPL_DISABLED_MESSAGE

  # Materialised-trace branch wins over the ``replEnabled`` flag —
  # mirrors the legacy ``if usesMaterializedTraces ... elif config.repl
  # ... else ...`` ordering.
  test "materialised flag takes precedence over replEnabled":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createReplVM(store)
      vm.setReplEnabled(true)
      vm.setMaterialized(true)
      vm.setLangName("noir")
      let r = MockRenderer()

      let panel = renderReplPanel(r, vm)

      check vm.displayMode.val == rdmMaterializedDisabled
      let msg = findByClass(panel, "repl-disabled-msg")
      check msg != nil
      check msg.children[0].text ==
        "The Repl Component is not supported for Db based traces 'noir'"
      # The form / history container belong to the enabled branch and
      # must not appear here.
      check findByTag(panel, "form") == nil
      check findByClass(panel, "repl-input-history") == nil

  test "enabled flag (without materialised) renders prompt + history":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createReplVM(store)
      vm.setReplEnabled(true)
      let r = MockRenderer()

      let panel = renderReplPanel(r, vm)

      check vm.displayMode.val == rdmReplEnabled
      check findByClass(panel, "repl-disabled-msg") == nil

      # ``div#repl`` shell, ``form`` with ``input#repl-input`` child,
      # ``div#repl-history`` sibling — same shape as the legacy view.
      let shell = findByTag(panel, "div").children[0]
      check shell.attributes.getOrDefault("id", "") == "repl"

      let formEl = findByTag(panel, "form")
      check formEl != nil
      let inputEl = findByTag(panel, "input")
      check inputEl != nil
      check inputEl.attributes.getOrDefault("id", "") == "repl-input"
      check inputEl.attributes.getOrDefault("type", "") == "text"

      # ``#repl-history`` container exists and is empty for a fresh VM.
      var historyEl: MockNode = nil
      for c in shell.children:
        if c.attributes.getOrDefault("id", "") == "repl-history":
          historyEl = c
          break
      check historyEl != nil
      check historyEl.children.len == 0

      dispose()

# ---------------------------------------------------------------------------
# REPL Panel — display-mode reactivity
# ---------------------------------------------------------------------------

suite "IsoNim REPL Panel — display mode reactivity":

  test "flipping replEnabled swaps disabled message for prompt form":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createReplVM(store)
      let r = MockRenderer()

      let panel = renderReplPanel(r, vm)

      # Initially disabled — no form, message visible.
      check findByTag(panel, "form") == nil
      check findByClass(panel, "repl-disabled-msg") != nil

      vm.setReplEnabled(true)

      # Effect must rebuild the body in-place.
      check findByClass(panel, "repl-disabled-msg") == nil
      check findByTag(panel, "form") != nil
      check findByTag(panel, "input") != nil

      dispose()

  test "flipping materialised hides the prompt form":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createReplVM(store)
      vm.setReplEnabled(true)
      let r = MockRenderer()

      let panel = renderReplPanel(r, vm)

      check findByTag(panel, "form") != nil

      vm.setMaterialized(true)
      vm.setLangName("ruby")

      check findByTag(panel, "form") == nil
      let msg = findByClass(panel, "repl-disabled-msg")
      check msg != nil
      check msg.children[0].text ==
        "The Repl Component is not supported for Db based traces 'ruby'"

      dispose()

  test "langName updates rerender materialised message":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createReplVM(store)
      vm.setMaterialized(true)
      vm.setLangName("noir")
      let r = MockRenderer()

      let panel = renderReplPanel(r, vm)

      var msg = findByClass(panel, "repl-disabled-msg")
      check msg.children[0].text ==
        "The Repl Component is not supported for Db based traces 'noir'"

      vm.setLangName("cadence")
      msg = findByClass(panel, "repl-disabled-msg")
      check msg.children[0].text ==
        "The Repl Component is not supported for Db based traces 'cadence'"

      dispose()

# ---------------------------------------------------------------------------
# REPL Panel — submitInput dispatch
# ---------------------------------------------------------------------------

suite "IsoNim REPL Panel — submit input":

  test "submit handler dispatches to the registered closure and appends history":
    # Headless dispatcher captures the expression so we can assert it
    # was forwarded.  Mirrors the legacy ``debugRepl`` callout.
    createRoot proc(dispose: proc()) =
      var captured: seq[string] = @[]
      let dispatcher: ReplDispatcher = proc(input: string) =
        captured.add(input)

      let (store, _) = makeStoreWithMock()
      let vm = createReplVM(store, dispatcher)
      vm.setReplEnabled(true)
      let r = MockRenderer()

      let panel = renderReplPanel(r, vm)
      let formEl = findByTag(panel, "form")
      let inputEl = findByTag(panel, "input")
      check formEl != nil
      check inputEl != nil

      # ``MockNode.fireEvent`` calls ``proc()`` listeners with no event
      # arg, so the submit handler reads ``inputEl.attributes["value"]``
      # — set it explicitly here.
      r.setAttribute(inputEl, "value", "print x")
      formEl.fireEvent("submit")

      check captured == @["print x"]

      # History should have grown by one entry with rokLoading output.
      let entries = vm.history.val
      check entries.len == 1
      check entries[0].input == "print x"
      check entries[0].output.kind == rokLoading
      check entries[0].output.output == ""

      # The handler clears the input value so the next submit starts
      # from an empty prompt.
      check inputEl.attributes.getOrDefault("value", "") == ""

      dispose()

  test "submit ignores empty input":
    createRoot proc(dispose: proc()) =
      var captured: seq[string] = @[]
      let dispatcher: ReplDispatcher = proc(input: string) =
        captured.add(input)

      let (store, _) = makeStoreWithMock()
      let vm = createReplVM(store, dispatcher)
      vm.setReplEnabled(true)
      let r = MockRenderer()

      let panel = renderReplPanel(r, vm)
      let formEl = findByTag(panel, "form")

      # Without setting the value the handler reads "" and short-
      # circuits.  Both the dispatcher and the history must remain
      # untouched.
      formEl.fireEvent("submit")

      check captured.len == 0
      check vm.history.val.len == 0

      dispose()

  test "submitInput appended interaction renders into history container":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createReplVM(store)
      vm.setReplEnabled(true)
      let r = MockRenderer()

      let panel = renderReplPanel(r, vm)

      vm.submitInput("p y")

      # The render-effect should have re-rendered the body and
      # populated ``#repl-history`` with the input + output rows.
      let inputRow = findByClass(panel, "repl-input-history")
      check inputRow != nil
      check inputRow.children.len == 1
      check inputRow.children[0].kind == mnkText
      check inputRow.children[0].text == ">p y"

      let outputRow = findByClass(panel, "repl-output-history")
      check outputRow != nil
      let preEl = findByTag(outputRow, "pre")
      check preEl != nil
      # rokLoading -> "repl-output-loading" CSS class.
      check preEl.attributes.getOrDefault("class", "") == "repl-output-loading"

      dispose()

# ---------------------------------------------------------------------------
# REPL Panel — onDebugOutput
# ---------------------------------------------------------------------------

suite "IsoNim REPL Panel — onDebugOutput":

  test "onDebugOutput mutates last interaction's output":
    # Mirrors the legacy ``self.history[^1].output = response`` line in
    # ``ReplComponent.onDebugOutput``.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createReplVM(store)
      vm.setReplEnabled(true)

      vm.submitInput("expr1")
      check vm.history.val[^1].output.kind == rokLoading

      vm.onDebugOutput(ReplOutput(kind: rokResult, output: "42"))

      let entries = vm.history.val
      check entries.len == 1
      check entries[^1].output.kind == rokResult
      check entries[^1].output.output == "42"

      dispose()

  test "onDebugOutput updates rendered <pre> class + text":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createReplVM(store)
      vm.setReplEnabled(true)
      let r = MockRenderer()

      let panel = renderReplPanel(r, vm)
      vm.submitInput("err")

      vm.onDebugOutput(ReplOutput(kind: rokError, output: "boom"))

      let outputRow = findByClass(panel, "repl-output-history")
      check outputRow != nil
      let preEl = findByTag(outputRow, "pre")
      check preEl.attributes.getOrDefault("class", "") == "repl-output-error"
      check preEl.children.len == 1
      check preEl.children[0].text == "boom"

      dispose()

  test "onDebugOutput on empty history is a silent no-op":
    # Defensive guard against an out-of-order response that arrives
    # before any submit fired.  Matches the legacy guard implicitly:
    # the ``self.history[^1]`` indexer would crash on an empty list,
    # so the new VM checks the length explicitly.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createReplVM(store)

      vm.onDebugOutput(ReplOutput(kind: rokResult, output: "ignored"))

      check vm.history.val.len == 0

      dispose()

# ---------------------------------------------------------------------------
# REPL Panel — bounded-10 history rendering
# ---------------------------------------------------------------------------

suite "IsoNim REPL Panel — bounded history":

  test "renders only the last REPL_HISTORY_VISIBLE_LEN entries newest-first":
    # Push 12 interactions, expect the rendered list to contain only
    # the last 10 in newest-first order — mirrors the legacy
    # ``(history.len-1).countdown(history.len-10)`` slice.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createReplVM(store)
      vm.setReplEnabled(true)

      var entries: seq[ReplInteraction] = @[]
      for i in 0 ..< 12:
        entries.add(ReplInteraction(
          input: "cmd" & $i,
          output: ReplOutput(kind: rokResult, output: "out" & $i),
        ))
      vm.setHistory(entries)

      let r = MockRenderer()
      let panel = renderReplPanel(r, vm)

      let inputRows = findAllByClass(panel, "repl-input-history")
      let outputRows = findAllByClass(panel, "repl-output-history")
      check inputRows.len == REPL_HISTORY_VISIBLE_LEN
      check outputRows.len == REPL_HISTORY_VISIBLE_LEN

      # Newest first: row 0 must be the last appended interaction.
      check inputRows[0].children[0].text == ">cmd11"
      check inputRows[^1].children[0].text == ">cmd2"

      # Output ordering must mirror the input ordering.
      check findByTag(outputRows[0], "pre").children[0].text == "out11"
      check findByTag(outputRows[^1], "pre").children[0].text == "out2"

      dispose()

  test "history shorter than the limit renders every entry":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createReplVM(store)
      vm.setReplEnabled(true)

      vm.setHistory(@[
        ReplInteraction(input: "a",
          output: ReplOutput(kind: rokResult, output: "1")),
        ReplInteraction(input: "b",
          output: ReplOutput(kind: rokMove, output: "2")),
      ])

      let r = MockRenderer()
      let panel = renderReplPanel(r, vm)

      let inputRows = findAllByClass(panel, "repl-input-history")
      check inputRows.len == 2
      check inputRows[0].children[0].text == ">b"
      check inputRows[1].children[0].text == ">a"

      let outputRows = findAllByClass(panel, "repl-output-history")
      check findByTag(outputRows[0], "pre").attributes.getOrDefault(
        "class", "") == "repl-output-move"
      check findByTag(outputRows[1], "pre").attributes.getOrDefault(
        "class", "") == "repl-output-result"

      dispose()

  test "clearHistory wipes the rendered list":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createReplVM(store)
      vm.setReplEnabled(true)

      vm.setHistory(@[
        ReplInteraction(input: "a",
          output: ReplOutput(kind: rokResult, output: "1")),
      ])
      let r = MockRenderer()
      let panel = renderReplPanel(r, vm)
      check findAllByClass(panel, "repl-input-history").len == 1

      vm.clearHistory()
      check findAllByClass(panel, "repl-input-history").len == 0
      check findAllByClass(panel, "repl-output-history").len == 0

      dispose()

# ---------------------------------------------------------------------------
# REPL VM — defaults
# ---------------------------------------------------------------------------

suite "IsoNim REPL Panel — vm":

  test "createReplVM defaults reflect the disabled branch":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createReplVM(store)

      check vm.history.val.len == 0
      check vm.replEnabled.val == false
      check vm.materialized.val == false
      check vm.langName.val == ""
      check vm.displayMode.val == rdmReplDisabled
      check not vm.store.isNil

      dispose()

  test "outputClass mirrors legacy repl-output-<kind> mapping":
    # Documenting the legacy CSS contract — a regression here would
    # break the existing scss rules under static/styles/repl.scss.
    check outputClass(rokLoading) == "repl-output-loading"
    check outputClass(rokResult) == "repl-output-result"
    check outputClass(rokMove) == "repl-output-move"
    check outputClass(rokError) == "repl-output-error"

  test "inputDisplayText prefixes with '>' (legacy echo shape)":
    check inputDisplayText("p x") == ">p x"
    check inputDisplayText("") == ">"

# ===========================================================================
# Low Level Code panel tests
# ===========================================================================
#
# Cover:
# - Outer structure (root class matches the legacy
#   ``componentContainerClass("low-level-code")`` output, empty-state
#   instruction list).
# - Reactive updates: ``setInstructions`` populates the list,
#   ``setActiveOffset`` toggles the ``active-instruction`` class on
#   the matching row, ``setNoirProject`` swaps the offset display.
# - Address / error overlays render reactively from
#   ``setAddress`` / ``setErrorMessage``.
# - Click handler routes through ``jumpToInstruction`` to the
#   backend mock with the row's offset / source cross-reference.
# - VM defaults reflect the empty-state branch and the address /
#   error / Noir signals start inert.

const LowLevelCodePanelClass = "low-level-code"

proc makeInstr(name: string; offset: int = 0; args: string = "";
                other: string = ""; highLevelPath: string = "";
                highLevelLine: int = 0): LowLevelInstruction =
  ## Helper: synthesise a ``LowLevelInstruction`` with sensible
  ## defaults so each test can spell out only the fields it asserts.
  LowLevelInstruction(
    name: name,
    args: args,
    other: other,
    offset: offset,
    highLevelPath: highLevelPath,
    highLevelLine: highLevelLine,
  )

# ---------------------------------------------------------------------------
# Structure tests
# ---------------------------------------------------------------------------

suite "IsoNim Low Level Code Panel — structure":

  test "root carries component-container + low-level-code classes":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createLowLevelCodeVM(store)
      let r = MockRenderer()

      let panel = renderLowLevelCodePanel(r, vm)

      check "component-container" in panel.attributes["class"]
      check LowLevelCodePanelClass in panel.attributes["class"]

      dispose()

  test "container constant matches the legacy componentContainerClass output":
    # Documents the wire shape — a regression here would break the
    # existing scss rules under static/styles/low_level_code.scss
    # (and any test/page-object selectors keyed on the exact class
    # string).
    check LowLevelCodeContainerClass == "component-container low-level-code"

  test "empty VM renders an empty instruction list":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createLowLevelCodeVM(store)
      let r = MockRenderer()

      let panel = renderLowLevelCodePanel(r, vm)

      let listContainer = findByClass(panel, "low-level-code-instructions")
      check listContainer != nil
      check listContainer.children.len == 0
      check vm.isEmpty.val == true

      dispose()

  test "header overlay is empty when no address / error is set":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createLowLevelCodeVM(store)
      let r = MockRenderer()

      let panel = renderLowLevelCodePanel(r, vm)

      let headerContainer = findByClass(panel, "low-level-code-header")
      check headerContainer != nil
      check headerContainer.children.len == 0

      dispose()

# ---------------------------------------------------------------------------
# Instruction list rendering
# ---------------------------------------------------------------------------

suite "IsoNim Low Level Code Panel — instruction list":

  test "setInstructions populates the row list reactively":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createLowLevelCodeVM(store)
      let r = MockRenderer()

      let panel = renderLowLevelCodePanel(r, vm)
      let listContainer = findByClass(panel, "low-level-code-instructions")
      check listContainer.children.len == 0

      vm.setInstructions(@[
        makeInstr("mov", offset = 0, args = "rax, 1"),
        makeInstr("add", offset = 1, args = "rax, rbx"),
        makeInstr("ret", offset = 2),
      ])

      check listContainer.children.len == 3

      dispose()

  test "row spans render offset / name / args / other columns":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createLowLevelCodeVM(store)
      let r = MockRenderer()

      let panel = renderLowLevelCodePanel(r, vm)
      vm.setInstructions(@[
        makeInstr("mov", offset = 4, args = "rax, 1", other = "; init"),
      ])

      let listContainer = findByClass(panel, "low-level-code-instructions")
      let row = listContainer.children[0]
      check findByClass(row, "low-level-code-instruction-offset").textContent == "4"
      check findByClass(row, "low-level-code-instruction-name").textContent == "mov"
      check findByClass(row, "low-level-code-instruction-args").textContent == "rax, 1"
      check findByClass(row, "low-level-code-instruction-other").textContent == "; init"

      dispose()

  test "empty instruction name renders the legacy <no instructions> placeholder":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createLowLevelCodeVM(store)
      let r = MockRenderer()

      let panel = renderLowLevelCodePanel(r, vm)
      vm.setInstructions(@[
        makeInstr("", offset = 0),
      ])

      let listContainer = findByClass(panel, "low-level-code-instructions")
      let row = listContainer.children[0]
      check findByClass(row, "low-level-code-instruction-name").textContent ==
        "<no instructions>"

      dispose()

  test "Noir project flag swaps offset display to StepId(<offset>)":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createLowLevelCodeVM(store)
      let r = MockRenderer()

      let panel = renderLowLevelCodePanel(r, vm)

      vm.setInstructions(@[
        makeInstr("acir", offset = 7),
      ])
      let listContainer = findByClass(panel, "low-level-code-instructions")
      check findByClass(listContainer, "low-level-code-instruction-offset")
        .textContent == "7"

      vm.setNoirProject(true)
      check findByClass(listContainer, "low-level-code-instruction-offset")
        .textContent == "StepId(7)"

      dispose()

  test "source cross-ref span only renders when highLevelLine > 0":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createLowLevelCodeVM(store)
      let r = MockRenderer()

      let panel = renderLowLevelCodePanel(r, vm)
      vm.setInstructions(@[
        makeInstr("call", offset = 0, highLevelPath = "src/main.nim",
                   highLevelLine = 12),
        makeInstr("nop", offset = 1),
      ])

      let listContainer = findByClass(panel, "low-level-code-instructions")
      let firstRow = listContainer.children[0]
      let secondRow = listContainer.children[1]
      check findByClass(firstRow, "low-level-code-instruction-source")
        .textContent == "src/main.nim:12"
      check findByClass(secondRow, "low-level-code-instruction-source") == nil

      dispose()

  test "clearInstructions wipes the rendered list and resets the active offset":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createLowLevelCodeVM(store)
      let r = MockRenderer()

      let panel = renderLowLevelCodePanel(r, vm)
      vm.setInstructions(@[ makeInstr("nop", offset = 0) ])
      vm.setActiveOffset(0)

      let listContainer = findByClass(panel, "low-level-code-instructions")
      check listContainer.children.len == 1

      vm.clearInstructions()
      check listContainer.children.len == 0
      check vm.activeOffset.val == NO_ACTIVE_OFFSET

      dispose()

# ---------------------------------------------------------------------------
# Active row highlighting
# ---------------------------------------------------------------------------

suite "IsoNim Low Level Code Panel — active row":

  test "setActiveOffset toggles the active-instruction class on the matching row":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createLowLevelCodeVM(store)
      let r = MockRenderer()

      let panel = renderLowLevelCodePanel(r, vm)
      vm.setInstructions(@[
        makeInstr("mov", offset = 0),
        makeInstr("add", offset = 1),
        makeInstr("ret", offset = 2),
      ])

      let listContainer = findByClass(panel, "low-level-code-instructions")
      for row in listContainer.children:
        check "active-instruction" notin row.attributes["class"]

      vm.setActiveOffset(1)
      check "active-instruction" notin listContainer.children[0].attributes["class"]
      check "active-instruction" in listContainer.children[1].attributes["class"]
      check "active-instruction" notin listContainer.children[2].attributes["class"]

      vm.setActiveOffset(2)
      check "active-instruction" notin listContainer.children[1].attributes["class"]
      check "active-instruction" in listContainer.children[2].attributes["class"]

      dispose()

  test "negative active offset clears every row's active-instruction class":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createLowLevelCodeVM(store)
      let r = MockRenderer()

      let panel = renderLowLevelCodePanel(r, vm)
      vm.setInstructions(@[ makeInstr("nop", offset = 0) ])

      vm.setActiveOffset(0)
      let listContainer = findByClass(panel, "low-level-code-instructions")
      check "active-instruction" in listContainer.children[0].attributes["class"]

      vm.setActiveOffset(NO_ACTIVE_OFFSET)
      check "active-instruction" notin listContainer.children[0].attributes["class"]

      dispose()

  test "isActiveRow uses offset equality and ignores negative offsets":
    # Documenting the legacy contract — ``findHighlight`` returned -1
    # ("no row") when no instruction matched the live debugger line.
    let instr = makeInstr("nop", offset = 5)
    check isActiveRow(instr, 5) == true
    check isActiveRow(instr, 4) == false
    check isActiveRow(instr, NO_ACTIVE_OFFSET) == false

# ---------------------------------------------------------------------------
# Address / error overlays
# ---------------------------------------------------------------------------

suite "IsoNim Low Level Code Panel — overlays":

  test "setAddress renders the Originating address overlay":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createLowLevelCodeVM(store)
      let r = MockRenderer()

      let panel = renderLowLevelCodePanel(r, vm)
      check findByClass(panel, "low-level-code-address") == nil

      vm.setAddress(0x1000)
      let addrDiv = findByClass(panel, "low-level-code-address")
      check addrDiv != nil
      check addrDiv.textContent == "Originating address: 0x" & toHex(0x1000)

      dispose()

  test "address overlay disappears when address is reset to 0":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createLowLevelCodeVM(store)
      let r = MockRenderer()

      let panel = renderLowLevelCodePanel(r, vm)
      vm.setAddress(0xABCD)
      check findByClass(panel, "low-level-code-address") != nil

      vm.setAddress(0)
      check findByClass(panel, "low-level-code-address") == nil

      dispose()

  test "setErrorMessage renders the error overlay reactively":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createLowLevelCodeVM(store)
      let r = MockRenderer()

      let panel = renderLowLevelCodePanel(r, vm)
      check findByClass(panel, "low-level-code-error") == nil

      vm.setErrorMessage("function not found")
      let errDiv = findByClass(panel, "low-level-code-error")
      check errDiv != nil
      check errDiv.textContent == "function not found"

      vm.setErrorMessage("")
      check findByClass(panel, "low-level-code-error") == nil

      dispose()

# ---------------------------------------------------------------------------
# Backend interactions
# ---------------------------------------------------------------------------

suite "IsoNim Low Level Code Panel — interactions":

  test "loadAsmFor sends ct/load-asm-function with path / name / key payload":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createLowLevelCodeVM(store)

      mock.clearReceivedCommands()
      vm.loadAsmFor("src/main.nim", "main", key = "k1", forceReload = true)

      let req = mock.findCommand("ct/load-asm-function")
      check req.isSome
      check req.get.args["path"].getStr == "src/main.nim"
      check req.get.args["name"].getStr == "main"
      check req.get.args["key"].getStr == "k1"
      check req.get.args["forceReload"].getBool == true

      dispose()

  test "loadAsmFor pre-clears the row list before the response arrives":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createLowLevelCodeVM(store)

      vm.setInstructions(@[ makeInstr("nop", offset = 0) ])
      vm.setActiveOffset(0)
      vm.setErrorMessage("stale error")

      vm.loadAsmFor("src/main.nim", "main")

      check vm.instructions.val.len == 0
      check vm.activeOffset.val == NO_ACTIVE_OFFSET
      check vm.errorMessage.val == ""

      dispose()

  test "clicking a row dispatches ct/asm-instruction-jump with the offset / cross-ref":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createLowLevelCodeVM(store)
      let r = MockRenderer()

      let panel = renderLowLevelCodePanel(r, vm)
      vm.setInstructions(@[
        makeInstr("mov", offset = 0, highLevelPath = "src/a.nim",
                   highLevelLine = 3),
        makeInstr("ret", offset = 1, highLevelPath = "src/a.nim",
                   highLevelLine = 4),
      ])

      mock.clearReceivedCommands()
      let listContainer = findByClass(panel, "low-level-code-instructions")
      listContainer.children[1].fireEvent("click")

      let req = mock.findCommand("ct/asm-instruction-jump")
      check req.isSome
      check req.get.args["offset"].getInt == 1
      check req.get.args["highLevelPath"].getStr == "src/a.nim"
      check req.get.args["highLevelLine"].getInt == 4

      dispose()

  test "jumpToInstruction direct call sends the same payload shape":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createLowLevelCodeVM(store)

      mock.clearReceivedCommands()
      vm.jumpToInstruction(makeInstr("call", offset = 9,
                                      highLevelPath = "src/x.nim",
                                      highLevelLine = 21))

      let req = mock.findCommand("ct/asm-instruction-jump")
      check req.isSome
      check req.get.args["offset"].getInt == 9
      check req.get.args["highLevelPath"].getStr == "src/x.nim"
      check req.get.args["highLevelLine"].getInt == 21

      dispose()

# ---------------------------------------------------------------------------
# VM defaults / formatting helpers
# ---------------------------------------------------------------------------

suite "IsoNim Low Level Code Panel — vm":

  test "createLowLevelCodeVM defaults reflect the empty-state branch":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createLowLevelCodeVM(store)

      check vm.instructions.val.len == 0
      check vm.activeOffset.val == NO_ACTIVE_OFFSET
      check vm.address.val == 0
      check vm.errorMessage.val == ""
      check vm.noirProject.val == false
      check vm.isEmpty.val == true
      check not vm.store.isNil

      dispose()

  test "formatOffset mirrors legacy isNoirProject / no-step-id branches":
    let regular = makeInstr("nop", offset = 4)
    check formatOffset(regular, false) == "4"
    check formatOffset(regular, true) == "StepId(4)"

    let noStepId = makeInstr("nop", offset = -1)
    check formatOffset(noStepId, false) == "<no step id>"
    check formatOffset(noStepId, true) == "<no step id>"

  test "displayName returns <no instructions> for an empty name":
    check displayName(makeInstr("")) == "<no instructions>"
    check displayName(makeInstr("ret")) == "ret"

  test "rowClass adds the active-instruction modifier when active":
    check isonim_low_level_code_view.rowClass(false) == "low-level-code-instruction"
    check isonim_low_level_code_view.rowClass(true) == "low-level-code-instruction active-instruction"

# ===========================================================================
# Request Panel tests
# ===========================================================================
#
# Cover:
# - Outer structure (root carries the legacy ``component-container
#   request-panel`` class string, header + filters + table-header +
#   table-body containers present, empty state).
# - Reactive list rendering: ``addRequest`` populates the body, row
#   columns carry the right text.
# - Selection: ``selectRequest`` flips the ``selected`` modifier on
#   exactly the matching row.
# - Filter mutations: ``setFilterMethod`` / ``setFilterStatus`` /
#   ``setSearchText`` narrow ``filteredRequests`` and reset the
#   selection.
# - ``clearRequests`` resets state and re-shows the empty body.
# - ``statusClass`` covers the canonical HTTP status buckets.

const RequestPanelClass = "request-panel"

proc makeReq(httpMethod: string = "GET"; url: string = "/";
             status: int = 200; durationMs: int = 0;
             responseSize: int = 0; startGeid: int64 = 0;
             id: int = 0): RequestRecord =
  ## Helper: build a ``RequestRecord`` with sensible defaults so each
  ## test only spells out the fields it asserts on.  ``id`` defaults
  ## to ``0`` because the tests that need a deterministic numbering
  ## use ``addRequest`` (which assigns ids) rather than constructing
  ## ``RequestRecord``s by hand.
  RequestRecord(
    id: id,
    httpMethod: httpMethod,
    url: url,
    statusCode: status,
    durationMs: durationMs,
    responseSize: responseSize,
    startGeid: startGeid,
  )

# ---------------------------------------------------------------------------
# Structure tests
# ---------------------------------------------------------------------------

suite "IsoNim Request Panel — structure":

  test "root carries component-container + request-panel classes":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createRequestPanelVM(store)
      let r = MockRenderer()

      let panel = renderRequestPanel(r, vm)

      check "component-container" in panel.attributes["class"]
      check RequestPanelClass in panel.attributes["class"]

      dispose()

  test "container constant matches the legacy componentContainerClass output":
    # Documents the wire shape — a regression here would break the
    # existing scss rules under static/styles/request_panel.scss
    # (and any test/page-object selectors keyed on the exact class
    # string).
    check RequestPanelContainerClass == "component-container request-panel"

  test "empty VM renders headers + empty body":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createRequestPanelVM(store)
      let r = MockRenderer()

      let panel = renderRequestPanel(r, vm)

      check findByClass(panel, "request-panel-header") != nil
      check findByClass(panel, "request-panel-filters") != nil
      check findByClass(panel, "request-table-header") != nil
      let body = findByClass(panel, "request-table-body")
      check body != nil
      check body.children.len == 0

      dispose()

  test "count badge renders 0 / 0 requests in the empty state":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createRequestPanelVM(store)
      let r = MockRenderer()

      let panel = renderRequestPanel(r, vm)
      let count = findByClass(panel, "request-panel-count-text")
      check count != nil
      check count.textContent == "0 / 0 requests"

      dispose()

# ---------------------------------------------------------------------------
# Row rendering
# ---------------------------------------------------------------------------

suite "IsoNim Request Panel — row rendering":

  test "addRequest populates the table body reactively":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createRequestPanelVM(store)
      let r = MockRenderer()

      let panel = renderRequestPanel(r, vm)
      let body = findByClass(panel, "request-table-body")
      check body.children.len == 0

      vm.addRequest("GET", "/api/users", 200, 25, 512, 100)
      vm.addRequest("POST", "/api/items", 201, 60, 4096, 200)

      check body.children.len == 2

      dispose()

  test "row columns render id / method / url / status / duration / size":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createRequestPanelVM(store)
      let r = MockRenderer()

      let panel = renderRequestPanel(r, vm)
      vm.addRequest("POST", "/api/x", 201, 1500, 2048, 1)

      let body = findByClass(panel, "request-table-body")
      let row = body.children[0]
      check findByClass(row, "request-col-id").textContent == "1"
      check findByClass(row, "request-col-method").textContent == "POST"
      check findByClass(row, "request-col-url").textContent == "/api/x"
      check findByClass(row, "request-col-status").textContent == "201"
      # 1500 ms -> "1.5s" via formatDuration's truncated 1-decimal form.
      check findByClass(row, "request-col-duration").textContent == "1.5s"
      # 2048 B -> "2.0 KB" via formatSize's KB branch.
      check findByClass(row, "request-col-size").textContent == "2.0 KB"

      dispose()

  test "addRequest assigns sequential ids starting at 1":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createRequestPanelVM(store)

      vm.addRequest("GET", "/a", 200, 0, 0, 0)
      vm.addRequest("GET", "/b", 200, 0, 0, 0)
      vm.addRequest("GET", "/c", 200, 0, 0, 0)

      let entries = vm.requests.val
      check entries[0].id == 1
      check entries[1].id == 2
      check entries[2].id == 3

      dispose()

  test "count badge updates as rows arrive":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createRequestPanelVM(store)
      let r = MockRenderer()

      let panel = renderRequestPanel(r, vm)
      let count = findByClass(panel, "request-panel-count-text")

      check count.textContent == "0 / 0 requests"
      vm.addRequest("GET", "/a", 200, 0, 0, 0)
      check count.textContent == "1 / 1 requests"
      vm.addRequest("POST", "/b", 500, 0, 0, 0)
      check count.textContent == "2 / 2 requests"

      dispose()

  test "status column wraps the code in a request-status-<bucket> span":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createRequestPanelVM(store)
      let r = MockRenderer()

      let panel = renderRequestPanel(r, vm)
      vm.addRequest("GET", "/ok", 200, 0, 0, 0)
      vm.addRequest("GET", "/redirect", 301, 0, 0, 0)
      vm.addRequest("GET", "/missing", 404, 0, 0, 0)
      vm.addRequest("GET", "/boom", 500, 0, 0, 0)

      let body = findByClass(panel, "request-table-body")
      check findByClass(body.children[0], "request-status-success") != nil
      check findByClass(body.children[1], "request-status-redirect") != nil
      check findByClass(body.children[2], "request-status-client-error") != nil
      check findByClass(body.children[3], "request-status-server-error") != nil

      dispose()

# ---------------------------------------------------------------------------
# Selection
# ---------------------------------------------------------------------------

suite "IsoNim Request Panel — selection":

  test "selectRequest flips the selected class on exactly the matching row":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createRequestPanelVM(store)
      let r = MockRenderer()

      let panel = renderRequestPanel(r, vm)
      vm.addRequest("GET", "/a", 200, 0, 0, 0)
      vm.addRequest("GET", "/b", 200, 0, 0, 0)
      vm.addRequest("GET", "/c", 200, 0, 0, 0)

      let body = findByClass(panel, "request-table-body")
      for row in body.children:
        check "selected" notin row.attributes["class"]

      vm.selectRequest(1)
      check "selected" notin body.children[0].attributes["class"]
      check "selected" in body.children[1].attributes["class"]
      check "selected" notin body.children[2].attributes["class"]

      vm.selectRequest(2)
      check "selected" notin body.children[1].attributes["class"]
      check "selected" in body.children[2].attributes["class"]

      dispose()

  test "NO_SELECTED_INDEX clears every row's selected class":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createRequestPanelVM(store)
      let r = MockRenderer()

      let panel = renderRequestPanel(r, vm)
      vm.addRequest("GET", "/a", 200, 0, 0, 0)

      vm.selectRequest(0)
      let body = findByClass(panel, "request-table-body")
      check "selected" in body.children[0].attributes["class"]

      vm.selectRequest(NO_SELECTED_INDEX)
      check "selected" notin body.children[0].attributes["class"]

      dispose()

  test "row click dispatches selectRequest with the filtered-list index":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createRequestPanelVM(store)
      let r = MockRenderer()

      let panel = renderRequestPanel(r, vm)
      vm.addRequest("GET", "/a", 200, 0, 0, 0)
      vm.addRequest("GET", "/b", 200, 0, 0, 0)

      let body = findByClass(panel, "request-table-body")
      body.children[1].fireEvent("click")

      check vm.selectedIndex.val == 1
      check "selected" in body.children[1].attributes["class"]

      dispose()

# ---------------------------------------------------------------------------
# Filter behaviour
# ---------------------------------------------------------------------------

suite "IsoNim Request Panel — filters":

  test "setFilterMethod narrows the filtered list":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createRequestPanelVM(store)
      let r = MockRenderer()

      let panel = renderRequestPanel(r, vm)
      vm.addRequest("GET", "/a", 200, 0, 0, 0)
      vm.addRequest("POST", "/b", 200, 0, 0, 0)
      vm.addRequest("GET", "/c", 200, 0, 0, 0)

      let body = findByClass(panel, "request-table-body")
      check body.children.len == 3

      vm.setFilterMethod("GET")
      check vm.filteredRequests.val.len == 2
      check body.children.len == 2
      # Both rendered rows are GETs.
      for row in body.children:
        check findByClass(row, "request-col-method").textContent == "GET"

      vm.setFilterMethod("")
      check body.children.len == 3

      dispose()

  test "setFilterStatus filters by status-class bucket":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createRequestPanelVM(store)
      let r = MockRenderer()

      let panel = renderRequestPanel(r, vm)
      vm.addRequest("GET", "/ok", 200, 0, 0, 0)
      vm.addRequest("GET", "/missing", 404, 0, 0, 0)
      vm.addRequest("GET", "/boom", 500, 0, 0, 0)

      let body = findByClass(panel, "request-table-body")

      vm.setFilterStatus("4xx")
      check body.children.len == 1
      check findByClass(body.children[0], "request-col-status").textContent == "404"

      vm.setFilterStatus("5xx")
      check body.children.len == 1
      check findByClass(body.children[0], "request-col-status").textContent == "500"

      vm.setFilterStatus("")
      check body.children.len == 3

      dispose()

  test "setSearchText filters URLs case-insensitively":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createRequestPanelVM(store)
      let r = MockRenderer()

      let panel = renderRequestPanel(r, vm)
      vm.addRequest("GET", "/api/Users", 200, 0, 0, 0)
      vm.addRequest("GET", "/api/items", 200, 0, 0, 0)

      let body = findByClass(panel, "request-table-body")

      # Lower-case query — should still match "/api/Users".
      vm.setSearchText("users")
      check body.children.len == 1
      check findByClass(body.children[0], "request-col-url").textContent ==
        "/api/Users"

      vm.setSearchText("/api/")
      check body.children.len == 2

      vm.setSearchText("nothing")
      check body.children.len == 0

      dispose()

  test "count badge tracks filteredRequests vs total":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createRequestPanelVM(store)
      let r = MockRenderer()

      let panel = renderRequestPanel(r, vm)
      vm.addRequest("GET", "/a", 200, 0, 0, 0)
      vm.addRequest("POST", "/b", 200, 0, 0, 0)
      vm.addRequest("GET", "/c", 200, 0, 0, 0)

      let count = findByClass(panel, "request-panel-count-text")
      check count.textContent == "3 / 3 requests"

      vm.setFilterMethod("POST")
      check count.textContent == "1 / 3 requests"

      vm.setFilterMethod("")
      check count.textContent == "3 / 3 requests"

      dispose()

  test "filter mutation resets the selection":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createRequestPanelVM(store)

      vm.addRequest("GET", "/a", 200, 0, 0, 0)
      vm.addRequest("POST", "/b", 200, 0, 0, 0)
      vm.selectRequest(1)
      check vm.selectedIndex.val == 1

      vm.setFilterMethod("GET")
      check vm.selectedIndex.val == NO_SELECTED_INDEX

      vm.selectRequest(0)
      vm.setFilterStatus("2xx")
      check vm.selectedIndex.val == NO_SELECTED_INDEX

      vm.selectRequest(0)
      vm.setSearchText("/a")
      check vm.selectedIndex.val == NO_SELECTED_INDEX

      dispose()

# ---------------------------------------------------------------------------
# clearRequests
# ---------------------------------------------------------------------------

suite "IsoNim Request Panel — clearRequests":

  test "clearRequests wipes the body and resets the selection":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createRequestPanelVM(store)
      let r = MockRenderer()

      let panel = renderRequestPanel(r, vm)
      vm.addRequest("GET", "/a", 200, 0, 0, 0)
      vm.addRequest("GET", "/b", 200, 0, 0, 0)
      vm.selectRequest(0)

      let body = findByClass(panel, "request-table-body")
      check body.children.len == 2

      vm.clearRequests()
      check body.children.len == 0
      check vm.selectedIndex.val == NO_SELECTED_INDEX
      check vm.requests.val.len == 0

      dispose()

  test "clearRequests preserves the active filters":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createRequestPanelVM(store)

      vm.setFilterMethod("GET")
      vm.setFilterStatus("2xx")
      vm.setSearchText("/api/")

      vm.addRequest("GET", "/api/users", 200, 0, 0, 0)
      vm.clearRequests()

      check vm.filterMethod.val == "GET"
      check vm.filterStatus.val == "2xx"
      check vm.searchText.val == "/api/"

      dispose()

# ---------------------------------------------------------------------------
# Backend interactions
# ---------------------------------------------------------------------------

suite "IsoNim Request Panel — interactions":

  test "double-clicking a row dispatches ct/seek-to-geid with startGeid":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createRequestPanelVM(store)
      let r = MockRenderer()

      let panel = renderRequestPanel(r, vm)
      vm.addRequest("GET", "/a", 200, 0, 0, 12345)
      vm.addRequest("POST", "/b", 200, 0, 0, 67890)

      mock.clearReceivedCommands()
      let body = findByClass(panel, "request-table-body")
      body.children[1].fireEvent("dblclick")

      let req = mock.findCommand("ct/seek-to-geid")
      check req.isSome
      check req.get.args["geid"].getInt == 67890
      check req.get.args["url"].getStr == "/b"
      check req.get.args["httpMethod"].getStr == "POST"

      dispose()

  test "jumpToHandler with an out-of-range index is a no-op":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createRequestPanelVM(store)

      mock.clearReceivedCommands()
      vm.jumpToHandler(0)
      vm.jumpToHandler(-1)
      check mock.findCommand("ct/seek-to-geid").isNone

      dispose()

# ---------------------------------------------------------------------------
# VM defaults / formatting helpers
# ---------------------------------------------------------------------------

suite "IsoNim Request Panel — vm":

  test "createRequestPanelVM defaults reflect the empty-state branch":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createRequestPanelVM(store)

      check vm.requests.val.len == 0
      check vm.filterMethod.val == ""
      check vm.filterStatus.val == ""
      check vm.searchText.val == ""
      check vm.selectedIndex.val == NO_SELECTED_INDEX
      check vm.filteredRequests.val.len == 0
      check not vm.store.isNil

      dispose()

  test "statusBucket / statusClass cover the canonical HTTP status ranges":
    check statusBucket(200) == "success"
    check statusBucket(204) == "success"
    check statusBucket(301) == "redirect"
    check statusBucket(404) == "client-error"
    check statusBucket(500) == "server-error"
    check statusBucket(599) == "server-error"
    check statusBucket(100) == "unknown"
    check statusBucket(600) == "unknown"

    check statusClass(200) == "request-status-success"
    check statusClass(404) == "request-status-client-error"

  test "formatDuration / formatSize match the legacy column shapes":
    check formatDuration(0) == "0ms"
    check formatDuration(999) == "999ms"
    check formatDuration(1000) == "1.0s"
    check formatDuration(1500) == "1.5s"

    check formatSize(0) == "0 B"
    check formatSize(1023) == "1023 B"
    check formatSize(1024) == "1.0 KB"
    check formatSize(2048) == "2.0 KB"
    check formatSize(1024 * 1024) == "1.0 MB"

  test "rowClass adds the selected modifier when selected":
    check isonim_request_panel_view.rowClass(false) == "request-row"
    check isonim_request_panel_view.rowClass(true) == "request-row selected"

  test "countText renders the legacy '<filtered> / <total> requests' shape":
    check countText(0, 0) == "0 / 0 requests"
    check countText(2, 5) == "2 / 5 requests"

# ---------------------------------------------------------------------------
# IsoNim Trace Log Panel — closes section 5.4 entry "trace_log"
#
# Mirrors the legacy ``TraceLogComponent`` (``frontend/ui/trace_log.nim``)
# which rendered a DataTables grid of tracepoint stops.  The IsoNim
# view replaces the Karax render; these tests cover the structural
# shell, row rendering / sorting, selection, click → ``ct/event-jump``
# dispatch, the empty-state placeholder, and the helper procs.
# ---------------------------------------------------------------------------

proc makeTraceEntry(rrTicks: int; path: string = "src/main.nim";
                    line: int = 10;
                    functionName: string = "main";
                    locals: string = "x=1";
                    eventId: int = 0;
                    minRRTicks: int = 0;
                    maxRRTicks: int = 1000): TraceLogEntry =
  ## Test fixture builder for ``TraceLogEntry`` rows.
  TraceLogEntry(
    rrTicks: rrTicks,
    minRRTicks: minRRTicks,
    maxRRTicks: maxRRTicks,
    path: path,
    line: line,
    functionName: functionName,
    localsText: locals,
    eventId: eventId,
    tracepointId: 1,
  )

suite "IsoNim Trace Log Panel — structure":

  test "root carries component-container + traceLog classes":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTraceLogVM(store)
      let r = MockRenderer()

      let panel = renderTraceLogPanel(r, vm)

      check "component-container" in panel.attributes["class"]
      check "traceLog" in panel.attributes["class"]

      dispose()

  test "container constant matches the legacy componentContainerClass output":
    # Documents the wire shape — a regression here would break the
    # existing scss rules under static/styles/components/tracepoint.styl
    # (and any test/page-object selectors keyed on the exact class
    # string).
    check TraceLogContainerClass == "component-container traceLog"

  test "empty VM renders header + empty body":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTraceLogVM(store)
      let r = MockRenderer()

      let panel = renderTraceLogPanel(r, vm)

      check findByClass(panel, "trace-log-table-header") != nil
      let body = findByClass(panel, "trace-log-table-body")
      check body != nil
      check body.children.len == 0

      dispose()

  test "header columns label rr-ticks / Location / Function / Locals":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTraceLogVM(store)
      let r = MockRenderer()

      let panel = renderTraceLogPanel(r, vm)
      let header = findByClass(panel, "trace-log-table-header")
      let cols = findAllByClass(header, "trace-col-rr-ticks")
      let locCols = findAllByClass(header, "trace-col-location")
      let fnCols = findAllByClass(header, "trace-col-function")
      let localsCols = findAllByClass(header, "trace-col-locals")
      check cols.len >= 1
      check locCols.len == 1
      check fnCols.len == 1
      check localsCols.len == 1
      check cols[0].textContent == "rr-ticks"
      check locCols[0].textContent == "Location"
      check fnCols[0].textContent == "Function"
      check localsCols[0].textContent == "Locals"

      dispose()

  test "empty-state placeholder is visible when no entries":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTraceLogVM(store)
      let r = MockRenderer()

      let panel = renderTraceLogPanel(r, vm)
      let placeholder = findByClass(panel, "trace-log-empty")
      check placeholder != nil
      check placeholder.textContent == EmptyStateText
      check "hidden" notin placeholder.attributes["class"]

      dispose()

# ---------------------------------------------------------------------------
# Row rendering / sorting
# ---------------------------------------------------------------------------

suite "IsoNim Trace Log Panel — row rendering":

  test "addEntry populates the table body reactively":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTraceLogVM(store)
      let r = MockRenderer()

      let panel = renderTraceLogPanel(r, vm)
      let body = findByClass(panel, "trace-log-table-body")
      check body.children.len == 0

      vm.addEntry(makeTraceEntry(100, eventId = 11))
      vm.addEntry(makeTraceEntry(200, eventId = 22))

      check body.children.len == 2

      dispose()

  test "row columns render rr-ticks / file:line / function / locals":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTraceLogVM(store)
      let r = MockRenderer()

      let panel = renderTraceLogPanel(r, vm)
      vm.addEntry(makeTraceEntry(150, path = "src/sub/foo.nim",
                                 line = 42, functionName = "myFn",
                                 locals = "a=1 b=hello"))

      let body = findByClass(panel, "trace-log-table-body")
      let row = body.children[0]
      check findByClass(row, "trace-col-location").textContent == "foo.nim:42"
      check findByClass(row, "trace-col-function").textContent == "myFn"
      check findByClass(row, "trace-col-locals").textContent == "a=1 b=hello"
      # The rr-ticks column also contains the indicator span; the
      # number itself shows up in the column's text content.
      check "150" in findByClass(row, "trace-col-rr-ticks").textContent

      dispose()

  test "addEntry keeps rows sorted ascending by rrTicks":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTraceLogVM(store)

      vm.addEntry(makeTraceEntry(300, functionName = "c"))
      vm.addEntry(makeTraceEntry(100, functionName = "a"))
      vm.addEntry(makeTraceEntry(200, functionName = "b"))

      let entries = vm.entries.val
      check entries.len == 3
      check entries[0].rrTicks == 100
      check entries[1].rrTicks == 200
      check entries[2].rrTicks == 300

      dispose()

  test "rr-ticks indicator span carries the event-rr-ticks-line class":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTraceLogVM(store)
      let r = MockRenderer()

      let panel = renderTraceLogPanel(r, vm)
      vm.addEntry(makeTraceEntry(500, minRRTicks = 0, maxRRTicks = 1000))

      let body = findByClass(panel, "trace-log-table-body")
      let row = body.children[0]
      let indicator = findByClass(row, "event-rr-ticks-line")
      check indicator != nil
      # 500 in [0, 1000] -> 50%
      check "50%" in indicator.attributes["style"]

      dispose()

  test "empty-state placeholder hides once entries exist":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTraceLogVM(store)
      let r = MockRenderer()

      let panel = renderTraceLogPanel(r, vm)
      let placeholder = findByClass(panel, "trace-log-empty")
      check "hidden" notin placeholder.attributes["class"]

      vm.addEntry(makeTraceEntry(1))
      check "hidden" in placeholder.attributes["class"]

      vm.clearEntries()
      check "hidden" notin placeholder.attributes["class"]

      dispose()

# ---------------------------------------------------------------------------
# Selection
# ---------------------------------------------------------------------------

suite "IsoNim Trace Log Panel — selection":

  test "selectEntry flips the selected class on exactly the matching row":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTraceLogVM(store)
      let r = MockRenderer()

      let panel = renderTraceLogPanel(r, vm)
      vm.addEntry(makeTraceEntry(100))
      vm.addEntry(makeTraceEntry(200))
      vm.addEntry(makeTraceEntry(300))

      let body = findByClass(panel, "trace-log-table-body")
      for row in body.children:
        check "selected" notin row.attributes["class"]

      vm.selectEntry(1)
      check "selected" notin body.children[0].attributes["class"]
      check "selected" in body.children[1].attributes["class"]
      check "selected" notin body.children[2].attributes["class"]

      vm.selectEntry(2)
      check "selected" notin body.children[1].attributes["class"]
      check "selected" in body.children[2].attributes["class"]

      dispose()

  test "NO_SELECTED_INDEX clears every row's selected class":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTraceLogVM(store)
      let r = MockRenderer()

      let panel = renderTraceLogPanel(r, vm)
      vm.addEntry(makeTraceEntry(100))

      vm.selectEntry(0)
      let body = findByClass(panel, "trace-log-table-body")
      check "selected" in body.children[0].attributes["class"]

      vm.selectEntry(NO_SELECTED_INDEX)
      check "selected" notin body.children[0].attributes["class"]

      dispose()

  test "selectEntry with out-of-range index clamps to NO_SELECTED_INDEX":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTraceLogVM(store)

      vm.addEntry(makeTraceEntry(100))
      vm.selectEntry(5)
      check vm.selectedIndex.val == NO_SELECTED_INDEX

      vm.selectEntry(-2)
      check vm.selectedIndex.val == NO_SELECTED_INDEX

      dispose()

# ---------------------------------------------------------------------------
# Clear / replace semantics
# ---------------------------------------------------------------------------

suite "IsoNim Trace Log Panel — clearEntries":

  test "clearEntries wipes the body and resets selection":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTraceLogVM(store)
      let r = MockRenderer()

      let panel = renderTraceLogPanel(r, vm)
      vm.addEntry(makeTraceEntry(100))
      vm.addEntry(makeTraceEntry(200))
      vm.selectEntry(1)

      let body = findByClass(panel, "trace-log-table-body")
      check body.children.len == 2

      vm.clearEntries()
      check body.children.len == 0
      check vm.selectedIndex.val == NO_SELECTED_INDEX

      dispose()

  test "setEntries replaces the row list and sorts by rrTicks":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTraceLogVM(store)

      vm.setEntries(@[
        makeTraceEntry(300, functionName = "c"),
        makeTraceEntry(100, functionName = "a"),
        makeTraceEntry(200, functionName = "b"),
      ])

      let entries = vm.entries.val
      check entries.len == 3
      check entries[0].rrTicks == 100
      check entries[1].rrTicks == 200
      check entries[2].rrTicks == 300
      check vm.selectedIndex.val == NO_SELECTED_INDEX

      dispose()

# ---------------------------------------------------------------------------
# Click → ct/event-jump dispatch
# ---------------------------------------------------------------------------

suite "IsoNim Trace Log Panel — interactions":

  test "clicking a row dispatches ct/event-jump with the row's eventId":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createTraceLogVM(store)
      let r = MockRenderer()

      let panel = renderTraceLogPanel(r, vm)
      vm.addEntry(makeTraceEntry(100, eventId = 11))
      vm.addEntry(makeTraceEntry(200, eventId = 22, line = 99,
                                 path = "src/main.nim"))

      mock.clearReceivedCommands()
      let body = findByClass(panel, "trace-log-table-body")
      body.children[1].fireEvent("click")

      let req = mock.findCommand("ct/event-jump")
      check req.isSome
      check req.get.args["eventId"].getInt == 22
      check req.get.args["rrTicks"].getInt == 200
      check req.get.args["path"].getStr == "src/main.nim"
      check req.get.args["line"].getInt == 99

      dispose()

  test "clicking a row also flips the selection signal":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTraceLogVM(store)
      let r = MockRenderer()

      let panel = renderTraceLogPanel(r, vm)
      vm.addEntry(makeTraceEntry(100))
      vm.addEntry(makeTraceEntry(200))

      check vm.selectedIndex.val == NO_SELECTED_INDEX
      let body = findByClass(panel, "trace-log-table-body")
      body.children[1].fireEvent("click")

      check vm.selectedIndex.val == 1
      check "selected" in body.children[1].attributes["class"]

      dispose()

  test "jumpToEntry with an out-of-range index is a no-op":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createTraceLogVM(store)

      mock.clearReceivedCommands()
      vm.jumpToEntry(0)
      vm.jumpToEntry(-1)
      check mock.findCommand("ct/event-jump").isNone

      dispose()

# ---------------------------------------------------------------------------
# VM defaults / formatting helpers
# ---------------------------------------------------------------------------

suite "IsoNim Trace Log Panel — vm":

  test "createTraceLogVM defaults reflect the empty-state branch":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTraceLogVM(store)

      check vm.entries.val.len == 0
      check vm.selectedIndex.val == NO_SELECTED_INDEX
      check vm.isEmpty.val
      check vm.rowCount.val == 0
      check not vm.store.isNil

      dispose()

  test "isEmpty / rowCount memos track the entry list":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createTraceLogVM(store)

      check vm.isEmpty.val
      check vm.rowCount.val == 0

      vm.addEntry(makeTraceEntry(100))
      check not vm.isEmpty.val
      check vm.rowCount.val == 1

      vm.addEntry(makeTraceEntry(200))
      check vm.rowCount.val == 2

      vm.clearEntries()
      check vm.isEmpty.val
      check vm.rowCount.val == 0

      dispose()

  test "fileLineText splits the path and joins with the line number":
    let entry = makeTraceEntry(0, path = "src/sub/dir/foo.nim", line = 7)
    check fileLineText(entry) == "foo.nim:7"

    let entryNoSlash = makeTraceEntry(0, path = "main.nim", line = 3)
    check fileLineText(entryNoSlash) == "main.nim:3"

  test "rrTicksScale clamps to [0, 100]":
    check rrTicksScale(0, 0, 100) == 0
    check rrTicksScale(50, 0, 100) == 50
    check rrTicksScale(100, 0, 100) == 100
    # below-min and above-max clamp to the boundaries
    check rrTicksScale(-10, 0, 100) == 0
    check rrTicksScale(200, 0, 100) == 100
    # degenerate range (max <= min) returns 0 to avoid div-by-zero
    check rrTicksScale(50, 100, 100) == 0
    check rrTicksScale(50, 100, 50) == 0

  test "rowClass adds the selected modifier when selected":
    check isonim_trace_log_view.rowClass(false) == "trace-log-row"
    check isonim_trace_log_view.rowClass(true) == "trace-log-row selected"

# ===========================================================================
# Filesystem panel tests
# ===========================================================================

# ---------------------------------------------------------------------------
# Filesystem panel tests — closes section 5.4 entry "filesystem" (§1.71)
#
# Mirrors the legacy ``FilesystemComponent`` (``frontend/ui/filesystem.nim``)
# which rendered a jstree-backed source tree plus a parallel
# ``diff-files-list`` and a deep-review compact list.  The IsoNim view
# replaces the Karax ``method render``; these tests cover the structural
# shell, the collapsible tree (toggle / expand / collapse), the diff-list
# section, the deep-review compact rows, and the empty-state placeholder.
# The rich jstree affordances (animated open/close, contextmenu plugin,
# search plugin) are deliberately not exercised here — they remain a
# follow-up captured in the VM doc-comment.
# ---------------------------------------------------------------------------

proc makeFsEntry(text: string;
                 path: string = "";
                 isFolder: bool = false;
                 children: seq[FilesystemEntryNode] = @[];
                 diffClass: FilesystemDiffClass = fdcNone;
                 icon: string = ""): FilesystemEntryNode =
  ## Test fixture builder for ``FilesystemEntryNode`` rows.
  FilesystemEntryNode(
    id: "",
    text: text,
    path: (if path.len > 0: path else: text),
    icon: icon,
    isFolder: isFolder,
    isExpanded: false,
    diffClass: diffClass,
    children: children,
  )

proc makeFsRoot(children: seq[FilesystemEntryNode]): FilesystemEntryNode =
  ## Build a synthetic non-empty root (text != "" so ``isEmpty`` is
  ## false) holding ``children`` so the view renders them at the top
  ## level.  Mirrors the shape the legacy
  ## ``filesystem-loaded`` event handler produced.
  FilesystemEntryNode(
    id: "0",
    text: "/",
    path: "/",
    icon: "",
    isFolder: true,
    isExpanded: true,
    diffClass: fdcNone,
    children: children,
  )

# ---------------------------------------------------------------------------
# Structure
# ---------------------------------------------------------------------------

suite "IsoNim Filesystem Panel — structure":

  test "root carries component-container + filesystem-container classes":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)
      let r = MockRenderer()

      let panel = renderFilesystemPanel(r, vm)

      check panel.kind == mnkElement
      check panel.tag == "div"
      check "component-container" in panel.attributes["class"]
      check "filesystem-container" in panel.attributes["class"]

      dispose()

  test "container constants match the legacy class strings":
    # Documents the wire shape — a regression here would break the
    # existing scss rules under static/styles/components/filesystem.styl.
    check FilesystemContainerClass == "component-container filesystem-container"
    check FilesystemTreeContainerClass == "filesystem-tree"

  test "empty VM renders filesystem-tree + visible empty-overlay":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)
      let r = MockRenderer()

      let panel = renderFilesystemPanel(r, vm)

      let tree = findByClass(panel, "filesystem-tree")
      check tree != nil
      check tree.children.len == 0

      let overlay = findByClass(panel, "filesystem-empty-overlay")
      check overlay != nil
      check overlay.textContent == FilesystemEmptyStateText
      check "hidden" notin overlay.attributes["class"]

      dispose()

  test "diff + deep-review containers are present but hidden when empty":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)
      let r = MockRenderer()

      let panel = renderFilesystemPanel(r, vm)

      let diff = findByClass(panel, "diff-files-list")
      check diff != nil
      check "hidden" in diff.attributes["class"]

      let deepReview = findByClass(panel, "deepreview-file-list")
      check deepReview != nil
      check "hidden" in deepReview.attributes["class"]

      dispose()

# ---------------------------------------------------------------------------
# Tree rendering
# ---------------------------------------------------------------------------

suite "IsoNim Filesystem Panel — tree rendering":

  test "setRoot populates the tree reactively":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)
      let r = MockRenderer()

      let panel = renderFilesystemPanel(r, vm)
      let tree = findByClass(panel, "filesystem-tree")
      check tree.children.len == 0

      vm.setRoot(makeFsRoot(@[
        makeFsEntry("a.nim"),
        makeFsEntry("b.nim"),
      ]))
      check tree.children.len == 2

      dispose()

  test "file rows carry filesystem-entry + file class":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)
      let r = MockRenderer()

      let panel = renderFilesystemPanel(r, vm)
      vm.setRoot(makeFsRoot(@[makeFsEntry("foo.nim")]))

      let row = findByClass(panel, "filesystem-entry")
      check row != nil
      check "file" in row.attributes["class"]
      check "folder" notin row.attributes["class"]

      let label = findByClass(row, "filesystem-entry-label")
      check label != nil
      check label.textContent == "foo.nim"

      dispose()

  test "folder rows carry folder class + a twisty glyph":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)
      let r = MockRenderer()

      let panel = renderFilesystemPanel(r, vm)
      vm.setRoot(makeFsRoot(@[
        makeFsEntry("src", path = "src", isFolder = true,
                    children = @[makeFsEntry("inner.nim",
                                             path = "src/inner.nim")]),
      ]))

      let row = findByClass(panel, "filesystem-entry")
      check "folder" in row.attributes["class"]
      # Collapsed by default — twisty is the closed glyph.
      let twisty = findByClass(row, "filesystem-entry-twisty")
      check twisty.textContent == ">"

      dispose()

  test "expandPath shows children + toggles the twisty":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)
      let r = MockRenderer()

      let panel = renderFilesystemPanel(r, vm)
      vm.setRoot(makeFsRoot(@[
        makeFsEntry("src", path = "src", isFolder = true,
                    children = @[makeFsEntry("inner.nim",
                                             path = "src/inner.nim")]),
      ]))

      # Folder collapsed: children container is empty.
      var children = findByClass(panel, "filesystem-entry-children")
      check children.children.len == 0

      vm.expandPath("src")

      # After expansion the inner row materialises.
      let labels = findAllByClass(panel, "filesystem-entry-label")
      check labels.len == 2
      check labels[1].textContent == "inner.nim"

      # The twisty flips to open.
      let folderRow = findByClass(panel, "filesystem-entry")
      let twisty = findByClass(folderRow, "filesystem-entry-twisty")
      check twisty.textContent == "v"

      dispose()

  test "clicking a folder row toggles expansion":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)
      let r = MockRenderer()

      let panel = renderFilesystemPanel(r, vm)
      vm.setRoot(makeFsRoot(@[
        makeFsEntry("src", path = "src", isFolder = true,
                    children = @[makeFsEntry("inner.nim",
                                             path = "src/inner.nim")]),
      ]))

      let row = findByClass(panel, "filesystem-entry")
      check not vm.isExpanded("src")

      row.fireEvent("click")
      check vm.isExpanded("src")

      row.fireEvent("click")
      check not vm.isExpanded("src")

      dispose()

  test "diff-class modifiers thread through to the row":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)
      let r = MockRenderer()

      let panel = renderFilesystemPanel(r, vm)
      vm.setRoot(makeFsRoot(@[
        makeFsEntry("added.nim", diffClass = fdcAdded),
        makeFsEntry("changed.nim", diffClass = fdcChanged),
        makeFsEntry("deleted.nim", diffClass = fdcDeleted),
      ]))

      let rows = findAllByClass(panel, "filesystem-entry")
      check rows.len == 3
      check "diff-file-added" in rows[0].attributes["class"]
      check "diff-file-changed" in rows[1].attributes["class"]
      check "diff-file-deleted" in rows[2].attributes["class"]

      dispose()

  test "empty-overlay hides once a tree is loaded":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)
      let r = MockRenderer()

      let panel = renderFilesystemPanel(r, vm)
      let overlay = findByClass(panel, "filesystem-empty-overlay")
      check "hidden" notin overlay.attributes["class"]

      vm.setRoot(makeFsRoot(@[makeFsEntry("a.nim")]))
      check "hidden" in overlay.attributes["class"]

      vm.clearRoot()
      check "hidden" notin overlay.attributes["class"]

      dispose()

# ---------------------------------------------------------------------------
# Diff + deep-review surfaces
# ---------------------------------------------------------------------------

suite "IsoNim Filesystem Panel — diff + deep-review":

  test "setDiffEntries renders one row per entry with the basename":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)
      let r = MockRenderer()

      let panel = renderFilesystemPanel(r, vm)
      vm.setDiffEntries([
        FilesystemDiffEntry(path: "src/a.nim", zebra: false),
        FilesystemDiffEntry(path: "src/b.nim", zebra: true),
      ])

      let diff = findByClass(panel, "diff-files-list")
      check "hidden" notin diff.attributes["class"]
      check diff.children.len == 2
      check diff.children[0].textContent == "a.nim"
      check diff.children[1].textContent == "b.nim"
      check "path-even" in diff.children[0].attributes["class"]
      check "path-odd" in diff.children[1].attributes["class"]

      dispose()

  test "setDeepReview renders one compact row per file when active":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)
      let r = MockRenderer()

      let panel = renderFilesystemPanel(r, vm)
      vm.setDeepReview(true, [
        FilesystemDeepReviewFile(
          path: "src/a.nim", baseName: "a.nim", status: "A",
          linesAdded: 10, linesRemoved: 0,
          coverageExecuted: 5, coverageTotal: 10),
        FilesystemDeepReviewFile(
          path: "src/b.nim", baseName: "b.nim", status: "M",
          linesAdded: 3, linesRemoved: 7,
          coverageExecuted: 8, coverageTotal: 8),
      ])

      let dr = findByClass(panel, "deepreview-file-list")
      check "hidden" notin dr.attributes["class"]
      check dr.children.len == 2

      let firstName = findByClass(dr.children[0], "deepreview-file-name-compact")
      check firstName.textContent == "a.nim"

      let firstStatus = findByClass(dr.children[0],
                                    "deepreview-diff-status-compact")
      check "deepreview-diff-added" in firstStatus.attributes["class"]

      let secondStatus = findByClass(dr.children[1],
                                     "deepreview-diff-status-compact")
      check "deepreview-diff-modified" in secondStatus.attributes["class"]

      let firstLines = findByClass(dr.children[0],
                                   "deepreview-diff-lines-compact")
      check firstLines.textContent == "+10/-0"

      let firstCoverage = findByClass(dr.children[0],
                                      "deepreview-coverage-compact")
      check firstCoverage.textContent == "5/10"

      dispose()

  test "setDeepReview(false, ...) wipes any pending file list":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)
      let r = MockRenderer()

      let panel = renderFilesystemPanel(r, vm)
      vm.setDeepReview(true, [
        FilesystemDeepReviewFile(path: "x", baseName: "x", status: "A",
                                 linesAdded: 1, linesRemoved: 0,
                                 coverageExecuted: 0, coverageTotal: 0),
      ])
      let dr = findByClass(panel, "deepreview-file-list")
      check dr.children.len == 1

      # Pass a non-empty seq with active=false; the VM must drop it.
      vm.setDeepReview(false, [
        FilesystemDeepReviewFile(path: "y", baseName: "y", status: "M",
                                 linesAdded: 0, linesRemoved: 1,
                                 coverageExecuted: 0, coverageTotal: 0),
      ])
      check vm.deepReviewFiles.val.len == 0
      check "hidden" in dr.attributes["class"]

      dispose()

# ---------------------------------------------------------------------------
# VM defaults / formatting helpers
# ---------------------------------------------------------------------------

suite "IsoNim Filesystem Panel — vm":

  test "createFilesystemVM defaults reflect the empty-state branch":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)

      check vm.rootEntry.val.text == ""
      check vm.rootEntry.val.children.len == 0
      check vm.expandedPaths.val.len == 0
      check vm.diffEntries.val.len == 0
      check not vm.deepReviewActive.val
      check vm.deepReviewFiles.val.len == 0
      check vm.isEmpty.val
      check not vm.hasDiff.val
      check vm.totalEntryCount.val == 0
      check not vm.store.isNil

      dispose()

  test "totalEntryCount memos count every descendant":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)

      check vm.totalEntryCount.val == 0

      vm.setRoot(makeFsRoot(@[
        makeFsEntry("src", path = "src", isFolder = true, children = @[
          makeFsEntry("a.nim", path = "src/a.nim"),
          makeFsEntry("b.nim", path = "src/b.nim"),
        ]),
        makeFsEntry("README.md"),
      ]))
      # root + src + a.nim + b.nim + README.md = 5
      check vm.totalEntryCount.val == 5

      vm.clearRoot()
      check vm.totalEntryCount.val == 0

      dispose()

  test "toggleExpanded flips the membership in expandedPaths":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)

      check not vm.isExpanded("src")
      vm.toggleExpanded("src")
      check vm.isExpanded("src")
      vm.toggleExpanded("src")
      check not vm.isExpanded("src")

      # expandPath / collapsePath are idempotent.
      vm.expandPath("a")
      vm.expandPath("a")
      check vm.expandedPaths.val.len == 1
      vm.collapsePath("a")
      vm.collapsePath("a")
      check vm.expandedPaths.val.len == 0

      dispose()

  test "diffClassToCss maps the enum to the legacy CSS modifier strings":
    check diffClassToCss(fdcNone) == ""
    check diffClassToCss(fdcAdded) == "diff-file-added"
    check diffClassToCss(fdcChanged) == "diff-file-changed"
    check diffClassToCss(fdcDeleted) == "diff-file-deleted"

  test "twistyText branches on isFolder + expanded":
    check twistyText(makeFsEntry("a.nim"), false) == ""
    check twistyText(makeFsEntry("a.nim"), true) == ""
    let dir = makeFsEntry("src", path = "src", isFolder = true)
    check twistyText(dir, false) == ">"
    check twistyText(dir, true) == "v"

  test "diffEntryLabel returns the basename":
    check diffEntryLabel(FilesystemDiffEntry(path: "src/a.nim",
                                             zebra: false)) == "a.nim"
    check diffEntryLabel(FilesystemDiffEntry(path: "main.nim",
                                             zebra: true)) == "main.nim"

  test "deepReviewStatusClass maps single-letter codes to CSS modifiers":
    check deepReviewStatusClass("A") == "deepreview-diff-added"
    check deepReviewStatusClass("M") == "deepreview-diff-modified"
    check deepReviewStatusClass("D") == "deepreview-diff-deleted"
    check deepReviewStatusClass("") == ""
    check deepReviewStatusClass("Z") == ""

# ===========================================================================
# Command Palette panel tests (§1.72 — IsoNim Migration Campaign,
# mission goal #3).  Mirrors the Filesystem suite layout: structure,
# row rendering, interactions, vm/helpers.
# ===========================================================================

proc makeCpEntry(value: string;
                 kind: CommandPaletteResultKind = cprkCommand;
                 level: CommandPaletteNotificationLevel = cpnlInfo;
                 file: string = "";
                 line: int = 0;
                 symbolKind: string = "";
                 valueHighlighted: string = ""): CommandPaletteResultEntry =
  ## Build a synthetic ``CommandPaletteResultEntry`` for the view +
  ## VM tests.  Mirrors ``makeFsEntry`` / ``makeScratchpadEntry`` —
  ## defaults to a plain command-kind row so the ``value`` flows
  ## through to the rendered label without per-kind decoration.
  CommandPaletteResultEntry(
    value: value,
    valueHighlighted:
      if valueHighlighted.len > 0: valueHighlighted else: value,
    kind: kind,
    level: level,
    file: file,
    line: line,
    symbolKind: symbolKind,
    snippetSource: "",
  )

# ---------------------------------------------------------------------------
# Structure
# ---------------------------------------------------------------------------

suite "IsoNim Command Palette Panel — structure":

  test "root carries component-container + command-container classes":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCommandPaletteVM(store)
      let r = MockRenderer()

      let panel = renderCommandPalettePanel(r, vm)

      check panel.kind == mnkElement
      check panel.tag == "div"
      check "component-container" in panel.attributes["class"]
      check "command-container" in panel.attributes["class"]
      # Closed by default — outer wrapper carries the hidden modifier.
      check "hidden" in panel.attributes["class"]

      dispose()

  test "container constants match the legacy class strings":
    # Documents the wire shape — a regression here would break the
    # existing scss rules under static/styles/components/command.styl.
    check CommandPaletteContainerClass == "component-container command-container"
    check CommandPaletteSurfaceClass == "command-view"
    check CommandPaletteResultsClass == "command-results"
    check CommandPaletteResultRowClass == "command-result"
    check CommandPaletteHiddenModifier == "hidden"
    check CommandPaletteInputFieldClass == "command-input-field"
    check CommandPalettePlaceholderClass == "command-input-placeholder"

  test "empty VM renders surface + input row + results + empty overlay":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCommandPaletteVM(store)
      let r = MockRenderer()

      let panel = renderCommandPalettePanel(r, vm)

      let surface = findByClass(panel, "command-view")
      check surface != nil

      let inputRow = findByClass(panel, "command-input-row")
      check inputRow != nil

      let input = findByClass(panel, "command-input-field")
      check input != nil
      check input.tag == "input"

      let placeholder = findByClass(panel, "command-input-placeholder")
      check placeholder != nil
      # No hint set yet — the placeholder is empty.
      check placeholder.textContent == ""

      let results = findByClass(panel, "command-results")
      check results != nil
      # Empty result list — container starts hidden.
      check "hidden" in results.attributes["class"]

      let empty = findByClass(panel, "command-empty-overlay")
      check empty != nil
      check empty.textContent == CommandPaletteEmptyStateText
      # Inactive + no input -> overlay is hidden.
      check "hidden" in empty.attributes["class"]

      dispose()

  test "open() flips the outer hidden modifier":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCommandPaletteVM(store)
      let r = MockRenderer()

      let panel = renderCommandPalettePanel(r, vm)
      check "hidden" in panel.attributes["class"]

      vm.open()
      check "hidden" notin panel.attributes["class"]

      vm.close()
      check "hidden" in panel.attributes["class"]

      dispose()

# ---------------------------------------------------------------------------
# Row rendering
# ---------------------------------------------------------------------------

suite "IsoNim Command Palette Panel — row rendering":

  test "setResults populates the dropdown reactively":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCommandPaletteVM(store)
      let r = MockRenderer()

      let panel = renderCommandPalettePanel(r, vm)
      let results = findByClass(panel, "command-results")
      check results.children.len == 0

      vm.setResults([
        makeCpEntry("open-file"),
        makeCpEntry("close-tab"),
      ])
      check results.children.len == 2
      check "hidden" notin results.attributes["class"]

      dispose()

  test "row labels carry entry.value verbatim":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCommandPaletteVM(store)
      let r = MockRenderer()

      let panel = renderCommandPalettePanel(r, vm)
      vm.setResults([
        makeCpEntry("alpha"),
        makeCpEntry("beta"),
      ])

      let labels = findAllByClass(panel, "command-result-value")
      check labels.len == 2
      check labels[0].textContent == "alpha"
      check labels[1].textContent == "beta"

      dispose()

  test "kind modifier flows through to the row class string":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCommandPaletteVM(store)
      let r = MockRenderer()

      let panel = renderCommandPalettePanel(r, vm)
      vm.setResults([
        makeCpEntry("cmd", kind = cprkCommand),
        makeCpEntry("file.nim", kind = cprkFile),
        makeCpEntry("hello", kind = cprkProgram),
        makeCpEntry("text", kind = cprkTextSearch),
        makeCpEntry("Foo", kind = cprkSymbol, symbolKind = "function"),
        makeCpEntry("/ai prompt", kind = cprkAgent),
      ])

      let rows = findAllByClass(panel, "command-result")
      check rows.len == 6
      check "command-command" in rows[0].attributes["class"]
      check "command-file" in rows[1].attributes["class"]
      check "command-program" in rows[2].attributes["class"]
      check "command-text-search" in rows[3].attributes["class"]
      check "command-symbol" in rows[4].attributes["class"]
      check "command-agent" in rows[5].attributes["class"]

      dispose()

  test "selected modifier flips when selectedIndex changes":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCommandPaletteVM(store)
      let r = MockRenderer()

      let panel = renderCommandPalettePanel(r, vm)
      vm.setResults([
        makeCpEntry("a"),
        makeCpEntry("b"),
        makeCpEntry("c"),
      ])

      var rows = findAllByClass(panel, "command-result")
      check rows.len == 3
      # Default selection is row 0.
      check "command-selected" in rows[0].attributes["class"]
      check "command-selected" notin rows[1].attributes["class"]
      check "command-selected" notin rows[2].attributes["class"]

      vm.setSelected(2)
      rows = findAllByClass(panel, "command-result")
      check "command-selected" notin rows[0].attributes["class"]
      check "command-selected" notin rows[1].attributes["class"]
      check "command-selected" in rows[2].attributes["class"]

      dispose()

  test "zebra modifiers alternate between rows":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCommandPaletteVM(store)
      let r = MockRenderer()

      let panel = renderCommandPalettePanel(r, vm)
      vm.setResults([
        makeCpEntry("a"),
        makeCpEntry("b"),
        makeCpEntry("c"),
        makeCpEntry("d"),
      ])

      let rows = findAllByClass(panel, "command-result")
      check rows.len == 4
      check "command-even" in rows[0].attributes["class"]
      check "command-odd" in rows[1].attributes["class"]
      check "command-even" in rows[2].attributes["class"]
      check "command-odd" in rows[3].attributes["class"]

      dispose()

  test "symbol rows append the ': <symbolKind>' suffix":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCommandPaletteVM(store)
      let r = MockRenderer()

      let panel = renderCommandPalettePanel(r, vm)
      vm.setResults([
        makeCpEntry("Foo", kind = cprkSymbol, symbolKind = "function"),
        makeCpEntry("plain"),
      ])

      let suffixes = findAllByClass(panel, "command-result-suffix")
      check suffixes.len == 2
      check suffixes[0].textContent == ": function"
      # Non-symbol rows render an empty suffix slot.
      check suffixes[1].textContent == ""

      dispose()

  test "warn / error level adds the level modifier":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCommandPaletteVM(store)
      let r = MockRenderer()

      let panel = renderCommandPalettePanel(r, vm)
      vm.setResults([
        makeCpEntry("ok"),
        makeCpEntry("warn", level = cpnlWarning),
        makeCpEntry("err", level = cpnlError),
        makeCpEntry("good", level = cpnlSuccess),
      ])

      let rows = findAllByClass(panel, "command-result")
      check rows.len == 4
      # Info row carries no level modifier.
      check "command-warn" notin rows[0].attributes["class"]
      check "command-error" notin rows[0].attributes["class"]
      check "command-success" notin rows[0].attributes["class"]
      check "command-warn" in rows[1].attributes["class"]
      check "command-error" in rows[2].attributes["class"]
      check "command-success" in rows[3].attributes["class"]

      dispose()

# ---------------------------------------------------------------------------
# Interactions
# ---------------------------------------------------------------------------

suite "IsoNim Command Palette Panel — interactions":

  test "clicking a row updates selectedIndex":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCommandPaletteVM(store)
      let r = MockRenderer()

      let panel = renderCommandPalettePanel(r, vm)
      vm.setResults([
        makeCpEntry("alpha"),
        makeCpEntry("beta"),
        makeCpEntry("gamma"),
      ])

      let rows = findAllByClass(panel, "command-result")
      check vm.selectedIndex.val == 0

      rows[2].fireEvent("click")
      check vm.selectedIndex.val == 2

      rows[1].fireEvent("click")
      check vm.selectedIndex.val == 1

      dispose()

  test "empty-overlay shows when active + input present + no results":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCommandPaletteVM(store)
      let r = MockRenderer()

      let panel = renderCommandPalettePanel(r, vm)
      let empty = findByClass(panel, "command-empty-overlay")
      check "hidden" in empty.attributes["class"]

      vm.open()
      vm.setQuery("xyz")
      check "hidden" notin empty.attributes["class"]

      # Once results arrive the overlay hides again.
      vm.setResults([makeCpEntry("xyz-match")])
      check "hidden" in empty.attributes["class"]

      dispose()

  test "placeholder hint flows into the placeholder span":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCommandPaletteVM(store)
      let r = MockRenderer()

      let panel = renderCommandPalettePanel(r, vm)
      let placeholder = findByClass(panel, "command-input-placeholder")
      check placeholder.textContent == ""

      vm.setInputPlaceholder(":open file.nim")
      check placeholder.textContent == ":open file.nim"

      vm.setInputPlaceholder("")
      check placeholder.textContent == ""

      dispose()

# ---------------------------------------------------------------------------
# VM defaults / formatting helpers
# ---------------------------------------------------------------------------

suite "IsoNim Command Palette Panel — vm":

  test "createCommandPaletteVM defaults reflect the closed-state branch":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCommandPaletteVM(store)

      check not vm.isActive.val
      check vm.inputValue.val == ""
      check vm.inputPlaceholder.val == ""
      check vm.query.val == ""
      check vm.results.val.len == 0
      check vm.selectedIndex.val == 0
      check vm.activeCommandName.val == ""
      check vm.mode.val == cpmNormal
      check not vm.hasResults.val
      check vm.resultCount.val == 0
      check not vm.store.isNil

      dispose()

  test "setSelected clamps into [0, results.len)":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCommandPaletteVM(store)

      vm.setResults([
        makeCpEntry("a"),
        makeCpEntry("b"),
        makeCpEntry("c"),
      ])

      vm.setSelected(-5)
      check vm.selectedIndex.val == 0

      vm.setSelected(99)
      check vm.selectedIndex.val == 2

      vm.setSelected(1)
      check vm.selectedIndex.val == 1

      dispose()

  test "close() resets every transient piece of state":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCommandPaletteVM(store)

      vm.open()
      vm.setQuery("hello")
      vm.setInputPlaceholder("hint")
      vm.setMode(cpmAgent)
      vm.setActiveCommandName("open")
      vm.setResults([makeCpEntry("a")])

      vm.close()

      check not vm.isActive.val
      check vm.inputValue.val == ""
      check vm.inputPlaceholder.val == ""
      check vm.query.val == ""
      check vm.results.val.len == 0
      check vm.selectedIndex.val == 0
      check vm.mode.val == cpmNormal
      check vm.activeCommandName.val == ""

      dispose()

  test "clear() drops input/query/results but keeps isActive":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCommandPaletteVM(store)

      vm.open()
      vm.setQuery("hello")
      vm.setResults([makeCpEntry("a")])

      vm.clear()

      check vm.isActive.val
      check vm.inputValue.val == ""
      check vm.query.val == ""
      check vm.results.val.len == 0
      check vm.selectedIndex.val == 0

      dispose()

  test "resultKindClass maps the enum to per-kind CSS modifiers":
    check resultKindClass(cprkCommand) == "command-command"
    check resultKindClass(cprkFile) == "command-file"
    check resultKindClass(cprkProgram) == "command-program"
    check resultKindClass(cprkTextSearch) == "command-text-search"
    check resultKindClass(cprkSymbol) == "command-symbol"
    check resultKindClass(cprkAgent) == "command-agent"

  test "resultLevelClass maps notification levels to CSS modifiers":
    check resultLevelClass(cpnlInfo) == ""
    check resultLevelClass(cpnlWarning) == "command-warn"
    check resultLevelClass(cpnlError) == "command-error"
    check resultLevelClass(cpnlSuccess) == "command-success"

  test "rowZebraClass alternates between command-even and command-odd":
    check rowZebraClass(0) == "command-even"
    check rowZebraClass(1) == "command-odd"
    check rowZebraClass(2) == "command-even"
    check rowZebraClass(99) == "command-odd"

  test "rowSuffixText emits ': <symbolKind>' only for symbol rows":
    check rowSuffixText(makeCpEntry("Foo", kind = cprkSymbol,
                                    symbolKind = "function")) ==
      ": function"
    # Symbol row without a populated symbolKind renders an empty suffix.
    check rowSuffixText(makeCpEntry("Foo", kind = cprkSymbol)) == ""
    check rowSuffixText(makeCpEntry("plain")) == ""

  test "containerClass appends 'hidden' only when isActive is false":
    check isonim_command_palette_view.containerClass(true) ==
      CommandPaletteContainerClass
    check isonim_command_palette_view.containerClass(false) ==
      CommandPaletteContainerClass & " " & CommandPaletteHiddenModifier

# ===========================================================================
# Agent Activity DeepReview panel tests (§1.74 — IsoNim Migration
# Campaign, mission goal #3).  Mirrors the Filesystem / CommandPalette
# suite layout: structure, row rendering, interactions, vm/helpers.
# ===========================================================================

proc makeAdrFile(path: string;
                 covered: int = 0;
                 total: int = 0;
                 hasFlow: bool = false): AgentDeepReviewFileCoverage =
  ## Build a synthetic ``AgentDeepReviewFileCoverage`` row for the
  ## view + VM tests.  Defaults to a zero-coverage entry so each
  ## test can override only the fields it cares about.
  AgentDeepReviewFileCoverage(
    path: path,
    coveredLines: covered,
    totalLines: total,
    hasFlow: hasFlow,
  )

proc makeAdrNotif(label: string;
                  kind: AgentDeepReviewNotificationKind =
                    adrnkCoverageUpdate;
                  passed: bool = false): AgentDeepReviewNotification =
  ## Build a synthetic ``AgentDeepReviewNotification`` row.  Mirrors
  ## ``makeCpEntry``: defaults to a coverage-update kind so the
  ## label flows through to the rendered row body without per-kind
  ## decoration.
  AgentDeepReviewNotification(label: label, kind: kind, passed: passed)

# ---------------------------------------------------------------------------
# Structure
# ---------------------------------------------------------------------------

suite "IsoNim Agent Activity DeepReview Panel — structure":

  test "root carries component-container + activity-dr-container classes":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentActivityDeepReviewVM(store)
      let r = MockRenderer()

      let panel = renderAgentActivityDeepReviewPanel(r, vm)

      check panel.kind == mnkElement
      check panel.tag == "div"
      check "component-container" in panel.attributes["class"]
      check "activity-dr-container" in panel.attributes["class"]
      # Closed by default — outer wrapper carries the collapsed
      # modifier and the body carries the hidden modifier.
      check "activity-dr-collapsed" in panel.attributes["class"]

      dispose()

  test "container constants match the legacy class strings":
    # Documents the wire shape — a regression here would break the
    # existing scss rules under static/styles/components/activity-dr.styl.
    check AgentActivityDeepReviewContainerClass ==
      "component-container activity-dr-container"
    check AgentActivityDeepReviewBodyClass == "activity-dr-body"
    check AgentActivityDeepReviewCollapsedModifier == "activity-dr-collapsed"
    check AgentActivityDeepReviewHiddenModifier == "hidden"
    check AgentActivityDeepReviewLabelText == "DeepReview"
    check AgentActivityDeepReviewFilesEmptyText ==
      "No files with coverage data yet."
    check AgentActivityDeepReviewTestsEmptyText == "No test results yet."
    check AgentActivityDeepReviewNotifsEmptyText ==
      "No recent notifications."

  test "empty VM renders header + collapsed body shell":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentActivityDeepReviewVM(store)
      let r = MockRenderer()

      let panel = renderAgentActivityDeepReviewPanel(r, vm)

      let header = findByClass(panel, "activity-dr-header")
      check header != nil

      let label = findByClass(panel, "activity-dr-header-label")
      check label != nil
      check label.textContent == AgentActivityDeepReviewLabelText

      let chevron = findByClass(panel, "activity-dr-chevron")
      check chevron != nil
      # Closed by default -> chevron renders the '>' glyph.
      check chevron.textContent == ">"

      let body = findByClass(panel, "activity-dr-body")
      check body != nil
      check "hidden" in body.attributes["class"]

      dispose()

  test "toggleExpanded flips the collapsed + hidden modifiers":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentActivityDeepReviewVM(store)
      let r = MockRenderer()

      let panel = renderAgentActivityDeepReviewPanel(r, vm)
      check "activity-dr-collapsed" in panel.attributes["class"]
      let body = findByClass(panel, "activity-dr-body")
      check "hidden" in body.attributes["class"]

      vm.toggleExpanded()
      check "activity-dr-collapsed" notin panel.attributes["class"]
      check "hidden" notin body.attributes["class"]

      vm.toggleExpanded()
      check "activity-dr-collapsed" in panel.attributes["class"]
      check "hidden" in body.attributes["class"]

      dispose()

  test "header chevron flips between '>' and 'v' on toggle":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentActivityDeepReviewVM(store)
      let r = MockRenderer()

      let panel = renderAgentActivityDeepReviewPanel(r, vm)
      let chevron = findByClass(panel, "activity-dr-chevron")
      check chevron.textContent == ">"

      vm.setExpanded(true)
      check chevron.textContent == "v"

      vm.setExpanded(false)
      check chevron.textContent == ">"

      dispose()

# ---------------------------------------------------------------------------
# Row rendering — coverage cards / file table / test results / notifs
# ---------------------------------------------------------------------------

suite "IsoNim Agent Activity DeepReview Panel — row rendering":

  test "coverage card paints the formatted percent + counts":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentActivityDeepReviewVM(store)
      let r = MockRenderer()

      let panel = renderAgentActivityDeepReviewPanel(r, vm)

      vm.setCoverageSummary(AgentDeepReviewCoverageSummary(
        totalLinesCovered: 75,
        totalLinesUncovered: 25,
        coveragePercent: 75.0,
        functionsTraced: 0,
      ))

      let coverageCard = findByClass(panel, "activity-dr-card-coverage")
      check coverageCard != nil
      let valueNode = findByClass(coverageCard, "activity-dr-card-value")
      check valueNode != nil
      check valueNode.textContent == "75.0%"
      let detailNode = findByClass(coverageCard, "activity-dr-card-detail")
      check detailNode != nil
      check detailNode.textContent == "75 covered / 25 uncovered"

      dispose()

  test "tests card paints '<passed>/<run>' + warn modifier on failures":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentActivityDeepReviewVM(store)
      let r = MockRenderer()

      let panel = renderAgentActivityDeepReviewPanel(r, vm)

      vm.setTestResults(AgentDeepReviewTestResults(
        testsRun: 10, testsPassed: 7, testsFailed: 3,
        totalDurationMs: 0,
      ))

      let testsCard = findByClass(panel, "activity-dr-card-tests")
      check testsCard != nil
      let valueNode = findByClass(testsCard, "activity-dr-card-value")
      check valueNode.textContent == "7/10"
      let detailNode = findByClass(testsCard, "activity-dr-card-detail")
      check detailNode.textContent == "3 failed"
      check "activity-dr-card-warn" in detailNode.attributes["class"]

      # All-passing flips the warn modifier off + relabels.
      vm.setTestResults(AgentDeepReviewTestResults(
        testsRun: 4, testsPassed: 4, testsFailed: 0,
        totalDurationMs: 0,
      ))
      let detailNode2 = findByClass(testsCard, "activity-dr-card-detail")
      check detailNode2.textContent == "all passing"
      check "activity-dr-card-warn" notin detailNode2.attributes["class"]

      dispose()

  test "setFileCoverage populates the per-file rows reactively":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentActivityDeepReviewVM(store)
      let r = MockRenderer()

      let panel = renderAgentActivityDeepReviewPanel(r, vm)

      let filesContainer = findByClass(panel, "activity-dr-files")
      # Initial empty state — placeholder row visible.
      let emptyInitial = findByClass(panel, "activity-dr-files-empty")
      check emptyInitial != nil
      check emptyInitial.textContent == AgentActivityDeepReviewFilesEmptyText

      vm.setFileCoverage([
        makeAdrFile("/repo/src/a.nim", covered = 8, total = 10),
        makeAdrFile("/repo/src/b.nim", covered = 4, total = 4,
                    hasFlow = true),
      ])

      let rows = findAllByClass(panel, "activity-dr-files-row")
      check rows.len == 2

      # Row 0 — basename + coverage ratio + "--" flow indicator.
      let row0Name = findByClass(rows[0], "activity-dr-files-col-name")
      check row0Name.textContent == "a.nim"
      let row0Cov = findByClass(rows[0], "activity-dr-files-col-coverage")
      check row0Cov.textContent == "8/10"
      let row0Flow = findByClass(rows[0], "activity-dr-files-col-flow")
      check row0Flow.textContent == "--"

      # Row 1 — hasFlow = true so the flow column reads "yes".
      let row1Flow = findByClass(rows[1], "activity-dr-files-col-flow")
      check row1Flow.textContent == "yes"

      # Empty placeholder no longer rendered (rows replace it).
      let emptyAfter = findByClass(filesContainer, "activity-dr-files-empty")
      check emptyAfter == nil

      dispose()

  test "TestComplete notifications populate the test-results list":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentActivityDeepReviewVM(store)
      let r = MockRenderer()

      let panel = renderAgentActivityDeepReviewPanel(r, vm)

      # Default empty branch.
      let emptyInitial = findByClass(panel, "activity-dr-tests-empty")
      check emptyInitial != nil
      check emptyInitial.textContent == AgentActivityDeepReviewTestsEmptyText

      vm.appendNotification(makeAdrNotif("Test PASS: alpha (12ms)",
                                         kind = adrnkTestComplete,
                                         passed = true))
      vm.appendNotification(makeAdrNotif("Test FAIL: beta (5ms)",
                                         kind = adrnkTestComplete,
                                         passed = false))
      # A non-test notification must NOT show up in the test list.
      vm.appendNotification(makeAdrNotif("Coverage: foo.nim",
                                         kind = adrnkCoverageUpdate))

      let rows = findAllByClass(panel, "activity-dr-test-item")
      check rows.len == 2
      check "activity-dr-test-pass" in rows[0].attributes["class"]
      check "activity-dr-test-fail" in rows[1].attributes["class"]
      check rows[0].textContent == "Test PASS: alpha (12ms)"
      check rows[1].textContent == "Test FAIL: beta (5ms)"

      dispose()

  test "appendNotification renders most-recent first in the feed":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentActivityDeepReviewVM(store)
      let r = MockRenderer()

      let panel = renderAgentActivityDeepReviewPanel(r, vm)

      vm.appendNotification(makeAdrNotif("first"))
      vm.appendNotification(makeAdrNotif("second",
                                         kind = adrnkFlowTraceUpdate))
      vm.appendNotification(makeAdrNotif("third",
                                         kind = adrnkCollectionComplete))

      let rows = findAllByClass(panel, "activity-dr-notif-item")
      check rows.len == 3
      # Newest first — order reversed vs. append order.
      check rows[0].textContent == "third"
      check rows[1].textContent == "second"
      check rows[2].textContent == "first"

      # Per-kind modifiers carry the matching CSS class.
      check "activity-dr-notif-complete" in rows[0].attributes["class"]
      check "activity-dr-notif-flow" in rows[1].attributes["class"]
      check "activity-dr-notif-coverage" in rows[2].attributes["class"]

      dispose()

  test "clearNotifications restores the empty placeholder branch":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentActivityDeepReviewVM(store)
      let r = MockRenderer()

      let panel = renderAgentActivityDeepReviewPanel(r, vm)

      vm.appendNotification(makeAdrNotif("alpha"))
      check findAllByClass(panel, "activity-dr-notif-item").len == 1

      vm.clearNotifications()
      let rowsAfter = findAllByClass(panel, "activity-dr-notif-item")
      check rowsAfter.len == 0
      let emptyAfter = findByClass(panel, "activity-dr-notifs-empty")
      check emptyAfter != nil
      check emptyAfter.textContent == AgentActivityDeepReviewNotifsEmptyText

      dispose()

# ---------------------------------------------------------------------------
# Interactions
# ---------------------------------------------------------------------------

suite "IsoNim Agent Activity DeepReview Panel — interactions":

  test "header badge is visible only when collapsed AND data is present":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentActivityDeepReviewVM(store)
      let r = MockRenderer()

      let panel = renderAgentActivityDeepReviewPanel(r, vm)
      let badge = findByClass(panel, "activity-dr-header-badge")
      check badge != nil
      # Empty summary -> badge has no text.
      check badge.textContent == ""

      vm.setCoverageSummary(AgentDeepReviewCoverageSummary(
        totalLinesCovered: 8, totalLinesUncovered: 2,
        coveragePercent: 80.0, functionsTraced: 0,
      ))
      check badge.textContent == "80.0%"

      # Expanded -> badge text is suppressed (legacy "show only when
      # collapsed" behaviour).
      vm.setExpanded(true)
      check badge.textContent == ""

      vm.setExpanded(false)
      check badge.textContent == "80.0%"

      dispose()

  test "setCoverageSummary repaints both the badge and the card":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentActivityDeepReviewVM(store)
      let r = MockRenderer()

      let panel = renderAgentActivityDeepReviewPanel(r, vm)

      vm.setCoverageSummary(AgentDeepReviewCoverageSummary(
        totalLinesCovered: 1, totalLinesUncovered: 9,
        coveragePercent: 10.0, functionsTraced: 0,
      ))
      let cardValue = findByClass(panel, "activity-dr-card-coverage")
      check findByClass(cardValue, "activity-dr-card-value").textContent ==
        "10.0%"
      check findByClass(panel, "activity-dr-header-badge").textContent ==
        "10.0%"

      vm.setCoverageSummary(AgentDeepReviewCoverageSummary(
        totalLinesCovered: 9, totalLinesUncovered: 1,
        coveragePercent: 90.0, functionsTraced: 0,
      ))
      check findByClass(panel, "activity-dr-card-value").textContent ==
        "90.0%"
      check findByClass(panel, "activity-dr-header-badge").textContent ==
        "90.0%"

      dispose()

  test "setFileCoverage with empty seq restores the placeholder row":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentActivityDeepReviewVM(store)
      let r = MockRenderer()

      let panel = renderAgentActivityDeepReviewPanel(r, vm)

      vm.setFileCoverage([makeAdrFile("/x.nim", 1, 1)])
      check findAllByClass(panel, "activity-dr-files-row").len == 1

      vm.setFileCoverage([])
      check findAllByClass(panel, "activity-dr-files-row").len == 0
      let empty = findByClass(panel, "activity-dr-files-empty")
      check empty != nil
      check empty.textContent == AgentActivityDeepReviewFilesEmptyText

      dispose()

# ---------------------------------------------------------------------------
# VM defaults / formatting helpers
# ---------------------------------------------------------------------------

suite "IsoNim Agent Activity DeepReview Panel — vm":

  test "createAgentActivityDeepReviewVM defaults reflect the closed branch":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentActivityDeepReviewVM(store)

      check not vm.isExpanded.val
      check vm.fileCoverage.val.len == 0
      check vm.notifications.val.len == 0
      check vm.coverageSummary.val.totalLinesCovered == 0
      check vm.coverageSummary.val.coveragePercent == 0.0
      check vm.testResults.val.testsRun == 0
      check not vm.hasFailures.val
      check vm.notificationCount.val == 0
      check vm.coveragePercent.val == 0.0
      check not vm.store.isNil

      dispose()

  test "appendNotification trims to the MAX_NOTIFICATIONS cap":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentActivityDeepReviewVM(store)

      # Push 60 notifications — only the most recent 50 must remain.
      for i in 0 ..< 60:
        vm.appendNotification(makeAdrNotif("n" & $i))

      check vm.notifications.val.len == MAX_NOTIFICATIONS
      check vm.notificationCount.val == MAX_NOTIFICATIONS
      # First entry is now n10 (60-50), last is n59.
      check vm.notifications.val[0].label == "n10"
      check vm.notifications.val[^1].label == "n59"

      dispose()

  test "hasFailures memo flips when testsFailed > 0":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentActivityDeepReviewVM(store)

      check not vm.hasFailures.val

      vm.setTestResults(AgentDeepReviewTestResults(
        testsRun: 1, testsPassed: 1, testsFailed: 0))
      check not vm.hasFailures.val

      vm.setTestResults(AgentDeepReviewTestResults(
        testsRun: 2, testsPassed: 1, testsFailed: 1))
      check vm.hasFailures.val

      dispose()

  test "containerClass / bodyClass append the collapsed/hidden modifiers":
    # Pure-helper checks — no reactive root needed.  Use the
    # qualified module name because the same proc names exist for
    # the CommandPalette view.
    check isonim_agent_activity_deepreview_view.containerClass(true) ==
      AgentActivityDeepReviewContainerClass
    check isonim_agent_activity_deepreview_view.containerClass(false) ==
      AgentActivityDeepReviewContainerClass & " " &
        AgentActivityDeepReviewCollapsedModifier
    check isonim_agent_activity_deepreview_view.bodyClass(true) ==
      AgentActivityDeepReviewBodyClass
    check isonim_agent_activity_deepreview_view.bodyClass(false) ==
      AgentActivityDeepReviewBodyClass & " " &
        AgentActivityDeepReviewHiddenModifier

  test "formatPercent emits one-decimal-place + trailing %":
    check isonim_agent_activity_deepreview_view.formatPercent(0.0) == "0.0%"
    check isonim_agent_activity_deepreview_view.formatPercent(100.0) ==
      "100.0%"
    check isonim_agent_activity_deepreview_view.formatPercent(42.5) ==
      "42.5%"

  test "fileBasename returns the path tail":
    check isonim_agent_activity_deepreview_view.fileBasename(
      "/repo/a/b/c.nim") == "c.nim"
    check isonim_agent_activity_deepreview_view.fileBasename("a.nim") ==
      "a.nim"
    check isonim_agent_activity_deepreview_view.fileBasename("") == ""

  test "notificationKindClass maps each variant to its CSS modifier":
    check notificationKindClass(adrnkCoverageUpdate) ==
      "activity-dr-notif-coverage"
    check notificationKindClass(adrnkFlowTraceUpdate) ==
      "activity-dr-notif-flow"
    check notificationKindClass(adrnkTestComplete) ==
      "activity-dr-notif-test"
    check notificationKindClass(adrnkCollectionComplete) ==
      "activity-dr-notif-complete"

  test "testRowClass appends pass / fail modifier":
    check testRowClass(true) ==
      AgentActivityDeepReviewTestRowClass & " " &
        AgentActivityDeepReviewTestPassClass
    check testRowClass(false) ==
      AgentActivityDeepReviewTestRowClass & " " &
        AgentActivityDeepReviewTestFailClass

# ===========================================================================
# Welcome screen tests (§1.73 — welcome-screen Karax -> IsoNim migration,
# mission goal #3).  Covers the rendering cases already exercised by
# welcome_screen.spec.ts and the WelcomeScreenVM headless suite.
# ===========================================================================

proc makeWelcomeTrace(id: int; program: string;
                      args: seq[string] = @[];
                      date: string = "2026/05/02 12:00:00";
                      duration: string = "0.5s";
                      workdir: string = "/tmp"): RecentTraceRecord =
  RecentTraceRecord(
    id: id,
    program: program,
    args: args,
    workdir: workdir,
    date: date,
    duration: duration,
  )

proc makeWelcomeFolder(id: int; name: string; path: string): RecentFolderRecord =
  RecentFolderRecord(id: id, name: name, path: path)

proc makeWelcomeOption(name: string; inactive: bool = false):
    WelcomeStartOptionRecord =
  WelcomeStartOptionRecord(
    key: optionKey(name),
    name: name,
    inactive: inactive,
  )

# ---------------------------------------------------------------------------
# Structure
# ---------------------------------------------------------------------------

suite "IsoNim Welcome Screen — structure":

  test "welcome mode renders the wrapper, panels, and start options":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      let r = MockRenderer()
      vm.setStartOptions(@[
        makeWelcomeOption("Open folder"),
        makeWelcomeOption("Record new trace"),
      ])

      let panel = renderWelcomeScreenPanel(r, vm)

      check panel.kind == mnkElement
      check panel.tag == "div"
      check panel.attributes["class"] == WelcomeScreenRootClass

      let wrapper = findByClass(panel, "welcome-screen-wrapper")
      check wrapper != nil

      let welcome = findByClass(panel, "welcome-screen")
      check welcome != nil
      check "welcome-screen-loading" notin welcome.attributes["class"]

      let leftPanel = findByClass(panel, "welcome-left-panel")
      let rightPanel = findByClass(panel, "welcome-right-panel")
      check leftPanel != nil
      check rightPanel != nil

      let options = findAllByClass(panel, "start-option")
      check options.len == 2

      dispose()

  test "loading flag appends the loading modifier and overlay":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      let r = MockRenderer()

      let panel = renderWelcomeScreenPanel(r, vm)
      check findByClass(panel, "welcome-screen-loading-overlay") == nil

      vm.beginLoadingTrace(7)
      let welcome = findByClass(panel, "welcome-screen")
      check "welcome-screen-loading" in welcome.attributes["class"]
      let overlay = findByClass(panel, "welcome-screen-loading-overlay")
      check overlay != nil

      vm.endLoading()
      check findByClass(panel, "welcome-screen-loading-overlay") == nil

      dispose()

  test "new-record and online-trace modes swap the top-level surface":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      let r = MockRenderer()

      let panel = renderWelcomeScreenPanel(r, vm)
      check findByClass(panel, "welcome-screen") != nil

      vm.showNewRecord()
      check findByClass(panel, "new-record-screen") != nil
      check findByClass(panel, "new-online-trace-form") == nil

      vm.showOnlineTrace()
      check findByClass(panel, "new-online-trace-form") != nil

      vm.enterEditMode()
      check findByClass(panel, "welcome-screen") == nil
      check findByClass(panel, "new-record-screen") == nil

      dispose()

# ---------------------------------------------------------------------------
# Welcome-mode content
# ---------------------------------------------------------------------------

suite "IsoNim Welcome Screen — welcome mode":

  test "recent traces render time-ago text and tooltip content":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      let r = MockRenderer()

      vm.setRecentTraces(@[
        makeWelcomeTrace(1, "/usr/bin/python3", @["fib.py"],
                         date = "2026/05/02 12:00:00"),
      ])

      let panel = renderWelcomeScreenPanel(r, vm)
      let trace = findByClass(panel, "recent-trace")
      check trace != nil

      let timeAgo = findByClass(trace, "recent-trace-title-time")
      check timeAgo != nil
      check timeAgo.textContent.len > 0

      let tooltip = findByClass(trace, "recent-trace-tooltip")
      check tooltip != nil
      check "Program: /usr/bin/python3" in tooltip.textContent
      check "Args: fib.py" in tooltip.textContent

      dispose()

  test "hovering a trace toggles the tooltip visibility class":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      let r = MockRenderer()

      vm.setRecentTraces(@[makeWelcomeTrace(7, "/bin/ruby", @["app.rb"])])

      let panel = renderWelcomeScreenPanel(r, vm)
      let trace = findByClass(panel, "recent-trace")
      var tooltip = findByClass(panel, "recent-trace-tooltip")
      check "visible" notin tooltip.attributes["class"]

      trace.fireEvent("mouseover")
      check vm.hoveredTrace.val == 7
      tooltip = findByClass(panel, "recent-trace-tooltip")
      check "visible" in tooltip.attributes["class"]

      trace.fireEvent("mouseleave")
      check vm.hoveredTrace.val == NO_HOVERED_TRACE
      tooltip = findByClass(panel, "recent-trace-tooltip")
      check "visible" notin tooltip.attributes["class"]

      dispose()

  test "recent folders and start-option buttons render their labels":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      let r = MockRenderer()

      vm.setRecentFolders(@[
        makeWelcomeFolder(1, "examples", "/repo/examples"),
      ])
      vm.setStartOptions(@[
        makeWelcomeOption("Open folder"),
        makeWelcomeOption("Record new trace"),
        makeWelcomeOption("Open online trace", inactive = true),
      ])

      let panel = renderWelcomeScreenPanel(r, vm)

      let folderName = findByClass(panel, "recent-folder-name")
      check folderName != nil
      check folderName.textContent == "examples"

      let options = findAllByClass(panel, "start-option")
      check options.len == 3
      check "inactive-start-option" in options[2].attributes["class"]

      dispose()

  test "empty-state copy matches the first-time and traces-empty branches":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      let r = MockRenderer()

      let panel = renderWelcomeScreenPanel(r, vm)
      check "Welcome to CodeTracer!" in panel.textContent
      check RecentTracesEmptyText in panel.textContent

      vm.setRecentTraces(@[makeWelcomeTrace(1, "/bin/ct")])
      vm.setRecentFolders(@[])
      check "Welcome to CodeTracer!" notin panel.textContent
      check RecentFoldersEmptyText in panel.textContent

      dispose()

  test "click callbacks surface recent-trace, folder, and option actions":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      let r = MockRenderer()

      vm.setRecentTraces(@[makeWelcomeTrace(11, "/bin/python")])
      vm.setRecentFolders(@[makeWelcomeFolder(3, "demo", "/tmp/demo")])
      vm.setStartOptions(@[makeWelcomeOption("Record new trace")])

      var clickedTrace = -1
      var clickedFolder = ""
      var clickedOption = ""
      let callbacks = WelcomeScreenCallbacks(
        onRecentTraceClick: proc(traceId: int) = clickedTrace = traceId,
        onRecentFolderClick: proc(folderPath: string) = clickedFolder = folderPath,
        onStartOptionClick: proc(key: string) = clickedOption = key
      )

      let panel = renderWelcomeScreenPanel(r, vm, callbacks)
      findByClass(panel, "recent-trace").fireEvent("click")
      findByClass(panel, "recent-folder").fireEvent("click")
      findAllByClass(panel, "start-option")[0].fireEvent("click")

      check clickedTrace == 11
      check clickedFolder == "/tmp/demo"
      check clickedOption == "record-new-trace"

      dispose()

# ---------------------------------------------------------------------------
# Form interactions
# ---------------------------------------------------------------------------

suite "IsoNim Welcome Screen — forms":

  test "new-record form input events update the VM and emit callbacks":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      let r = MockRenderer()
      vm.showNewRecord()

      var gotExec = ""
      var gotArgs: seq[string] = @[]
      var gotWorkDir = ""
      var gotOutput = ""
      var toggled = 0
      let callbacks = WelcomeScreenCallbacks(
        onRecordExecutableChange: proc(path: string) = gotExec = path,
        onRecordArgsChange: proc(args: seq[string]) = gotArgs = args,
        onRecordWorkDirChange: proc(path: string) = gotWorkDir = path,
        onRecordOutputFolderChange: proc(path: string) = gotOutput = path,
        onToggleDefaultOutputFolder: proc() = inc toggled
      )

      let panel = renderWelcomeScreenPanel(r, vm, callbacks)
      let inputs = findAllByTag(panel, "input")
      check inputs.len >= 5

      r.setAttribute(inputs[0], "value", "/usr/bin/python3")
      inputs[0].fireEvent("input")
      r.setAttribute(inputs[1], "value", "fib.py --n 10")
      inputs[1].fireEvent("input")
      r.setAttribute(inputs[2], "value", "/tmp/work")
      inputs[2].fireEvent("input")
      inputs[3].fireEvent("change")
      r.setAttribute(inputs[4], "value", "/tmp/out")
      inputs[4].fireEvent("input")

      check vm.newRecord.val.executable == "/usr/bin/python3"
      check vm.newRecord.val.args == @["fib.py", "--n", "10"]
      check vm.newRecord.val.workDir == "/tmp/work"
      check vm.newRecord.val.outputFolder == "/tmp/out"
      check gotExec == "/usr/bin/python3"
      check gotArgs == @["fib.py", "--n", "10"]
      check gotWorkDir == "/tmp/work"
      check gotOutput == "/tmp/out"
      check toggled == 1

      dispose()

  test "online-trace form input updates VM and submit/back callbacks":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      let r = MockRenderer()
      vm.showOnlineTrace()

      var submitted = ""
      var backCount = 0
      let callbacks = WelcomeScreenCallbacks(
        onOnlineTraceInputChange: proc(value: string) = discard,
        onSubmitOnlineTrace: proc(value: string) = submitted = value,
        onShowWelcome: proc() =
          inc backCount
          vm.showWelcome()
      )

      let panel = renderWelcomeScreenPanel(r, vm, callbacks)
      let input = findByTag(panel, "input")
      r.setAttribute(input, "value", "abc123")
      input.fireEvent("input")
      check vm.onlineTraceInput.val == "abc123"

      let buttons = findAllByTag(panel, "button")
      buttons[1].fireEvent("click")
      check submitted == "abc123"

      buttons[0].fireEvent("click")
      check backCount == 1
      check vm.mode.val == wsmWelcome

      dispose()

# ---------------------------------------------------------------------------
# Helper coverage
# ---------------------------------------------------------------------------

suite "IsoNim Welcome Screen — helpers":

  test "helper procs map classes and strings consistently":
    check welcomeScreenClass(false) == "welcome-screen"
    check welcomeScreenClass(true) == "welcome-screen welcome-screen-loading"
    check traceTooltipClass(false) == "recent-trace-tooltip"
    check traceTooltipClass(true) == "recent-trace-tooltip visible"
    check startOptionClass(makeWelcomeOption("Open folder"), false) ==
      "start-option open-folder"
    check startOptionClass(makeWelcomeOption("Open online trace",
      inactive = true), true) ==
        "start-option open-online-trace inactive-start-option hovered"
    check traceCommandText(makeWelcomeTrace(1, "/usr/bin/python3",
      @["fib.py"])) == "python3 fib.py"
    check parseArgsInput("a  b   c") == @["a", "b", "c"]

  test "formatWelcomeTimeAgo returns a non-empty human string":
    let s = formatWelcomeTimeAgo("2026/05/02 12:00:00")
    check s.len > 0

# ===========================================================================
# Agent Activity panel tests (§1.75 — agent_activity Karax -> IsoNim
# migration, mission goal #3).
# ===========================================================================

proc makeAgentActivityMessage(id, content: string;
                              role: AgentActivityMessageRole = aamrAgent;
                              canceled: bool = false;
                              isLoading: bool = false;
                              diffs: seq[AgentActivityDiffEntry] = @[]):
    AgentActivityMessageEntry =
  AgentActivityMessageEntry(
    id: id,
    content: content,
    role: role,
    canceled: canceled,
    isLoading: isLoading,
    diffs: diffs,
  )

suite "IsoNim Agent Activity Panel — structure":

  test "root renders conversation and prompt controls":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentActivityVM(store)
      let r = MockRenderer()

      let panel = renderAgentActivityPanel(r, vm, componentId = 7)

      check panel.kind == mnkElement
      check panel.attributes["class"] == AgentActivityContainerClass
      check findByClass(panel, AgentActivityConversationClass) != nil
      check findByClass(panel, AgentActivityInteractionClass) != nil
      let input = findByTag(panel, "textarea")
      check input != nil
      check input.attributes["id"] == inputId(7)
      check input.attributes["placeholder"] == AgentActivityPlaceholderText

      dispose()

  test "messages render user and agent wrappers with status modifiers":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentActivityVM(store)
      let r = MockRenderer()
      let panel = renderAgentActivityPanel(r, vm, componentId = 4)

      vm.setMessages(@[
        makeAgentActivityMessage("u1", "hello", role = aamrUser),
        makeAgentActivityMessage("a1", "working", isLoading = true),
        makeAgentActivityMessage("a2", "stopped", canceled = true),
      ])

      let wrappers = findAllByClass(panel, "agent-msg-wrapper")
      check wrappers.len == 3
      check "user-wrapper" in wrappers[0].attributes["class"]
      check findByClass(wrappers[1], "ai-status") != nil
      check "(canceled)" in wrappers[2].textContent
      check findByClass(wrappers[0], AgentActivityMessageContentClass).textContent ==
        "hello"

      dispose()

  test "diff previews and terminals preserve legacy ids":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentActivityVM(store)
      let r = MockRenderer()
      let panel = renderAgentActivityPanel(r, vm, componentId = 3)

      vm.setMessages(@[
        makeAgentActivityMessage("a1", "patch", diffs = @[
          AgentActivityDiffEntry(
            id: 9,
            path: "/repo/a.nim",
            original: "old",
            modified: "new",
          )
        ])
      ])
      vm.setTerminals(@[
        AgentActivityTerminalEntry(id: "term-a", shellId: 42)
      ])

      let editor = findByClass(panel, "agent-editor")
      check editor != nil
      check editor.attributes["id"] == diffEditorId(3, 9)
      let shell = findByClass(panel, "shell-container")
      check shell != nil
      check shell.attributes["id"] == shellContainerId(42)

      dispose()

  test "submit/stop buttons react to loading state and invoke callbacks":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentActivityVM(store)
      let r = MockRenderer()
      var submitted = 0
      var stopped = 0
      let callbacks = AgentActivityCallbacks(
        onSubmitPrompt: proc() = (inc submitted),
        onStopPrompt: proc() = (inc stopped),
      )
      let panel = renderAgentActivityPanel(r, vm, componentId = 5,
                                           callbacks = callbacks)

      findByClass(panel, "agent-start-button").fireEvent("click")
      check submitted == 1
      vm.setLoading(true)
      check findByClass(panel, "agent-start-button") == nil
      findByClass(panel, "agent-stop-button").fireEvent("click")
      check stopped == 1

      dispose()

  test "input event updates VM and surfaces callback value":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentActivityVM(store)
      let r = MockRenderer()
      var changed = ""
      let callbacks = AgentActivityCallbacks(
        onInputChange: proc(value: string) = (changed = value),
      )
      let panel = renderAgentActivityPanel(r, vm, componentId = 6,
                                           callbacks = callbacks)
      let input = findByTag(panel, "textarea")

      r.setAttribute(input, "value", "run tests")
      input.fireEvent("input")

      check vm.inputValue.val == "run tests"
      check changed == "run tests"

      dispose()

suite "IsoNim Agent Activity Panel — helpers":

  test "helper ids and classes match the legacy selector surface":
    check messageWrapperClass(aamrUser) == "agent-msg-wrapper user-wrapper"
    check messageWrapperClass(aamrAgent) == "agent-msg-wrapper"
    check messageName(aamrUser) == "author"
    check messageName(aamrAgent) == "agent"
    check inputId(12) == "agent-query-text-12"
    check inputId(12, "-command") == "agent-query-text-12-command"
    check diffEditorId(2, 7) == "diff-editor-2-7"
    check shellContainerId(4) == "shellComponent-4"

# ===========================================================================
# Agent Workspace panel tests (§1.76 — agent_workspace Karax -> IsoNim
# migration, mission goal #3).
# ===========================================================================

proc makeAgentWorkspaceFile(path: string; covered = 0; total = 0;
                            hasFlow = false): AgentWorkspaceFileEntry =
  AgentWorkspaceFileEntry(
    path: path,
    coveredLines: covered,
    totalLines: total,
    hasFlow: hasFlow,
  )

suite "IsoNim Agent Workspace Panel — structure":

  test "empty VM renders the legacy empty-state shell":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentWorkspaceVM(store)
      let r = MockRenderer()

      let panel = renderAgentWorkspacePanel(r, vm, componentId = 8)

      check panel.kind == mnkElement
      check panel.attributes["class"] == AgentWorkspaceContainerClass
      let empty = findByClass(panel, AgentWorkspaceEmptyClass)
      check empty != nil
      check empty.textContent == AgentWorkspaceEmptyText
      check findByClass(panel, AgentWorkspaceHeaderClass) == nil

      dispose()

  test "workspace metadata renders header summary body and editor id":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentWorkspaceVM(store)
      let r = MockRenderer()
      let panel = renderAgentWorkspacePanel(r, vm, componentId = 9)

      vm.setWorkspaceMetadata("/tmp/agent", "session-1")
      vm.setSummary(AgentWorkspaceSummary(
        coveragePercent: 62.5,
        testsRun: 4,
        testsPassed: 3,
        testsFailed: 1,
        functionsTraced: 2,
      ))

      let header = findByClass(panel, AgentWorkspaceHeaderClass)
      check header != nil
      check findByClass(header, "agent-workspace-header-label").textContent ==
        "Agent Workspace"
      check findByClass(header, "agent-workspace-header-path").textContent ==
        "/tmp/agent"

      let summary = findByClass(panel, AgentWorkspaceSummaryClass)
      check summary != nil
      check "Coverage: 62.5%" in summary.textContent
      check "Tests: 3/4 passed" in summary.textContent
      check "Functions traced: 2" in summary.textContent

      let editor = findByClass(panel, AgentWorkspaceEditorClass)
      check editor != nil
      check editor.attributes["id"] == isonim_agent_workspace_view.editorId(9)

      dispose()

  test "file list renders selected state coverage badges and flow marker":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentWorkspaceVM(store)
      let r = MockRenderer()
      let panel = renderAgentWorkspacePanel(r, vm, componentId = 10)

      vm.setWorkspaceMetadata("/tmp/agent", "session-1")
      vm.setFiles(@[
        makeAgentWorkspaceFile("/repo/src/a.nim", covered = 1, total = 2),
        makeAgentWorkspaceFile("/repo/src/b.nim", covered = 4, total = 4,
                               hasFlow = true),
      ])
      vm.setSelectedFileIndex(1)

      let rows = findAllByClass(panel, "agent-workspace-file-item")
      check rows.len == 2
      check "selected" notin rows[0].attributes["class"]
      check "selected" in rows[1].attributes["class"]
      check findByClass(rows[0], "agent-workspace-file-name").textContent ==
        "a.nim"
      check findByClass(rows[0], "agent-workspace-coverage-badge").textContent ==
        "1/2"
      check findByClass(rows[1], "agent-workspace-flow-badge").textContent ==
        "flow"

      dispose()

suite "IsoNim Agent Workspace Panel — interactions":

  test "file click updates selection and invokes callback":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentWorkspaceVM(store)
      let r = MockRenderer()
      var selected = -1
      let callbacks = AgentWorkspaceCallbacks(
        onSelectFile: proc(index: int) = (selected = index),
      )
      let panel = renderAgentWorkspacePanel(r, vm, componentId = 11,
                                            callbacks = callbacks)
      vm.setWorkspaceMetadata("/tmp/agent", "session-1")
      vm.setFiles(@[
        makeAgentWorkspaceFile("/repo/a.nim", 1, 2),
        makeAgentWorkspaceFile("/repo/b.nim", 2, 2),
      ])

      let rows = findAllByClass(panel, "agent-workspace-file-item")
      rows[1].fireEvent("click")

      check selected == 1
      check vm.selectedFileIndex.val == 1

      dispose()

  test "overlay and view toggles update VM and callbacks":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentWorkspaceVM(store)
      let r = MockRenderer()
      var overlayToggles = 0
      var viewToggles = 0
      let callbacks = AgentWorkspaceCallbacks(
        onToggleOverlay: proc() = (inc overlayToggles),
        onToggleView: proc() = (inc viewToggles),
      )
      let panel = renderAgentWorkspacePanel(r, vm, componentId = 12,
                                            callbacks = callbacks)
      vm.setWorkspaceMetadata("/tmp/agent", "session-1")

      findByClass(panel, "agent-workspace-overlay-toggle").fireEvent("click")
      check overlayToggles == 1
      check not vm.coverageOverlayEnabled.val
      check findByClass(panel, "agent-workspace-overlay-toggle").textContent ==
        "Show Coverage"

      findByClass(panel, "agent-workspace-view-toggle").fireEvent("click")
      check viewToggles == 1
      check vm.viewKind.val == awvkUserWorkspace
      check findByClass(panel, "agent-workspace-header-label").textContent ==
        "User Workspace"

      dispose()

suite "IsoNim Agent Workspace Panel — helpers":

  test "helper text matches the legacy selector and label surface":
    check isonim_agent_workspace_view.editorId(7) ==
      "agent-workspace-editor-7"
    check isonim_agent_workspace_view.fileBasename("/repo/src/main.nim") ==
      "main.nim"
    check isonim_agent_workspace_view.fileBasename("main.nim") == "main.nim"
    check isonim_agent_workspace_view.viewLabel(awvkAgentWorkspace) ==
      "Agent Workspace"
    check isonim_agent_workspace_view.viewLabel(awvkUserWorkspace) ==
      "User Workspace"
    check isonim_agent_workspace_view.toggleViewText(awvkAgentWorkspace) ==
      "Switch to User"
    check isonim_agent_workspace_view.toggleViewText(awvkUserWorkspace) ==
      "Switch to Agent"
    check isonim_agent_workspace_view.fileItemClass(false) ==
      "agent-workspace-file-item"
    check isonim_agent_workspace_view.fileItemClass(true) ==
      "agent-workspace-file-item selected"
    check isonim_agent_workspace_view.overlayToggleText(true) == "Hide Coverage"
    check isonim_agent_workspace_view.overlayToggleText(false) == "Show Coverage"

# ===========================================================================
# VCS panel tests (§1.172 — VCS GoldenLayout Karax -> IsoNim shell/list slice,
# mission goal #3).
# ===========================================================================

proc makeVcsDiffFile(): VCSDiffFileRow =
  VCSDiffFileRow(
    fileIndex: 0,
    status: "M",
    path: "src/main.nim",
    additions: 1,
    deletions: 1,
    hunks: @[
      VCSHunkRow(
        oldStart: 10,
        oldCount: 2,
        newStart: 10,
        newCount: 2,
        selected: true,
        lines: @[
          VCSDiffLineRow(lineType: "removed", content: "old", oldLine: 10),
          VCSDiffLineRow(lineType: "added", content: "new", newLine: 10),
        ],
      )
    ],
  )

suite "IsoNim VCS Panel — structure":

  test "no-repo shell renders legacy empty state selectors":
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()
      let r = MockRenderer()
      let panel = renderVCSPanel(r, vm)

      vm.setGitRepoState(false, "Not a git repository")

      check panel.attributes["class"] == VCSContainerClass
      let noRepo = findByClass(panel, VCSNoRepoClass)
      check noRepo != nil
      check findByClass(noRepo, "vcs-no-repo-message").textContent ==
        "Not a git repository"

      dispose()

  test "normal git mode renders branch commits changed files and callbacks":
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()
      let r = MockRenderer()
      var selectedCommit = -1
      var selectedFile = ""
      var toggled = false
      let callbacks = VCSCallbacks(
        onSelectCommit: proc(index: int) = (selectedCommit = index),
        onSelectFile: proc(index: int; path: string) =
          (discard index; selectedFile = path),
        onToggleUnifiedDiff: proc() =
          (toggled = true; vm.setUnifiedDiff(true, @[makeVcsDiffFile()])),
      )
      let panel = renderVCSPanel(r, vm, callbacks)

      vm.setGitRepoState(true)
      vm.setHeader("main")
      vm.setBranchState("main", @["main", "feature"], false)
      vm.setCommits(@[
        VCSCommitRow(hash: "abc123", message: "initial", relativeTime: "1h"),
      ], selectedIndex = 0)
      vm.setChangedFiles(@[
        VCSFileRow(status: "M", path: "src/main.nim", baseName: "main.nim",
                   additions: 2, deletions: 1),
      ])

      check findByClass(panel, "vcs-branch-name").textContent == "main"
      check findByClass(panel, "vcs-commit-hash").textContent == "abc123"
      check findByClass(panel, "vcs-file-name").textContent == "main.nim"

      findByClass(panel, "vcs-commit-item").fireEvent("click")
      findByClass(panel, "vcs-file-item").fireEvent("click")
      findByClass(panel, "vcs-toggle-button").fireEvent("click")

      check selectedCommit == 0
      check selectedFile == "src/main.nim"
      check toggled
      check findByClass(panel, "deepreview-unified-diff") != nil

      dispose()

  test "DeepReview changed files mode renders selected file and coverage":
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()
      let r = MockRenderer()
      var selected = -1
      let callbacks = VCSCallbacks(
        onSelectFile: proc(index: int; path: string) =
          (discard path; selected = index),
      )
      let panel = renderVCSPanel(r, vm, callbacks)

      vm.setDeepReviewMode(true)
      vm.setHeader("Review session")
      vm.setChangedFiles(@[
        VCSFileRow(status: "A", path: "src/new.nim", baseName: "new.nim",
                   additions: 4, coverageText: "3/4", selected: true),
      ])

      check findByClass(panel, "vcs-branch-name").textContent ==
        "Review session"
      check findByClass(panel, "vcs-file-item").attributes["class"] ==
        "vcs-file-item vcs-file-selected"
      check findByClass(panel, "vcs-file-coverage").textContent == "3/4"

      findByClass(panel, "vcs-file-item").fireEvent("click")
      check selected == 0

      dispose()

  test "unified diff renders toolbar selection and hunk callback":
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()
      let r = MockRenderer()
      var selectedHunk = (-1, -1)
      let callbacks = VCSCallbacks(
        onSelectHunk: proc(fileIdx, hunkIdx: int; shiftKey, ctrlKey: bool) =
          (discard shiftKey; discard ctrlKey; selectedHunk = (fileIdx, hunkIdx)),
      )
      let panel = renderVCSPanel(r, vm, callbacks)

      vm.setGitRepoState(true)
      vm.setHeader("main")
      vm.setUnifiedDiff(true, @[makeVcsDiffFile()])
      vm.setHunkState(@[(0, 0)], toolbarVisible = true, copyFeedback = false)

      check findByClass(panel, "hunk-toolbar-count").textContent ==
        "1 hunk selected"
      check findByClass(panel, "deepreview-unified-file-path").textContent ==
        "src/main.nim"
      check findAllByClass(panel, "deepreview-unified-line").len == 2

      findByClass(panel, "deepreview-unified-hunk-header").fireEvent("click")
      check selectedHunk == (0, 0)

      dispose()

# ===========================================================================
# DeepReview panel tests (§1.77 — deepreview Karax -> IsoNim migration,
# mission goal #3).
# ===========================================================================

proc makeDeepReviewFileEntry(path: string; status = "M"; coverage = "2/4"):
    DeepReviewFileEntry =
  DeepReviewFileEntry(
    path: path,
    diffStatus: status,
    linesAdded: 2,
    linesRemoved: 1,
    coverageText: coverage,
    hasCoverage: true,
    hasFlow: true,
  )

proc makeDeepReviewUnifiedFile(): DeepReviewUnifiedFileEntry =
  DeepReviewUnifiedFileEntry(
    fileIndex: 0,
    path: "/repo/src/main.nim",
    diffStatus: "M",
    linesAdded: 1,
    linesRemoved: 1,
    hunks: @[
      DeepReviewHunkEntry(
        oldStart: 3,
        oldCount: 2,
        newStart: 3,
        newCount: 2,
        lines: @[
          DeepReviewDiffLineEntry(
            lineType: "removed",
            content: "old",
            oldLine: 3,
          ),
          DeepReviewDiffLineEntry(
            lineType: "added",
            content: "new",
            newLine: 3,
            values: @[
              DeepReviewFlowValueEntry(
                name: "x",
                value: "42",
                truncated: false,
              )
            ],
          ),
        ],
      )
    ],
  )

suite "IsoNim DeepReview Panel — structure":

  test "unloaded VM renders the legacy no-data error":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDeepReviewVM(store)
      let r = MockRenderer()

      let panel = renderDeepReviewPanel(r, vm, componentId = 2)

      check panel.kind == mnkElement
      check panel.attributes["class"] == DeepReviewContainerClass
      let err = findByClass(panel, DeepReviewErrorClass)
      check err != nil
      check err.textContent == DeepReviewNoDataText

      dispose()

  test "full-files mode renders header file list editor and calltrace":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDeepReviewVM(store)
      let r = MockRenderer()
      let panel = renderDeepReviewPanel(r, vm, componentId = 3)

      vm.setHasData(true)
      vm.setHeader("DeepReview: parser", "abcdef123456...", "1 files | 2 recordings | 9ms")
      vm.setFiles(@[makeDeepReviewFileEntry("/repo/src/main.nim")])
      vm.setExecutionState(0, 2, "main")
      vm.setIterationState(0, 3)
      vm.setCallNodes(@[
        DeepReviewCallNodeEntry(name: "main", executionCount: 2, depth: 0),
        DeepReviewCallNodeEntry(name: "helper", executionCount: 1, depth: 1),
      ])

      check findByClass(panel, DeepReviewHeaderClass) != nil
      check findByClass(panel, "deepreview-session-title").textContent ==
        "DeepReview: parser"
      check findByClass(panel, "deepreview-stats").textContent ==
        "1 files | 2 recordings | 9ms"
      check findByClass(panel, DeepReviewFileListClass) != nil
      check findByClass(panel, "deepreview-file-name").textContent == "main.nim"
      check findByClass(panel, "deepreview-coverage-badge").textContent == "2/4"
      check findByClass(panel, DeepReviewEditorClass).attributes["id"] ==
        isonim_deepreview_view.editorId(3)
      check findAllByClass(panel, "deepreview-calltrace-node").len == 2

      dispose()

  test "unified mode renders hunks line rows and flow values":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDeepReviewVM(store)
      let r = MockRenderer()
      let panel = renderDeepReviewPanel(r, vm, componentId = 4)

      vm.setHasData(true)
      vm.setViewMode(drpvmUnified)
      vm.setHeader("", "abcdef", "1 files | 1 recordings | 1ms")
      vm.setUnifiedFiles(@[makeDeepReviewUnifiedFile()])

      check findByClass(panel, DeepReviewUnifiedDiffClass) != nil
      check findByClass(panel, "deepreview-unified-file-path").textContent ==
        "/repo/src/main.nim"
      let rows = findAllByClass(panel, "deepreview-unified-line")
      check rows.len == 2
      check "deepreview-unified-line-removed" in rows[0].attributes["class"]
      check "deepreview-unified-line-added" in rows[1].attributes["class"]
      check findByClass(rows[1], "flow-parallel-value-name").textContent ==
        "<x>"
      check findByClass(rows[1], "flow-parallel-value-box").textContent ==
        "42"

      dispose()

suite "IsoNim DeepReview Panel — interactions":

  test "file mode and hunk clicks update VM and invoke callbacks":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDeepReviewVM(store)
      let r = MockRenderer()
      var selectedFile = -1
      var selectedMode = drpvmFullFiles
      var selectedHunk = (-1, -1)
      let callbacks = DeepReviewCallbacks(
        onSelectFile: proc(index: int) = (selectedFile = index),
        onSetViewMode: proc(mode: DeepReviewPanelViewMode) =
          (selectedMode = mode),
        onSelectHunk: proc(fileIdx, hunkIdx: int) =
          (selectedHunk = (fileIdx, hunkIdx)),
      )
      let panel = renderDeepReviewPanel(r, vm, componentId = 5,
                                        callbacks = callbacks)

      vm.setHasData(true)
      vm.setFiles(@[
        makeDeepReviewFileEntry("/repo/a.nim"),
        makeDeepReviewFileEntry("/repo/b.nim"),
      ])
      findAllByClass(panel, "deepreview-file-item")[1].fireEvent("click")
      check selectedFile == 1
      check vm.selectedFileIndex.val == 1

      findAllByClass(panel, "deepreview-mode-btn")[1].fireEvent("click")
      check selectedMode == drpvmUnified
      check vm.viewMode.val == drpvmUnified

      vm.setUnifiedFiles(@[makeDeepReviewUnifiedFile()])
      findByClass(panel, "deepreview-unified-hunk-header").fireEvent("click")
      check selectedHunk == (0, 0)

      dispose()

suite "IsoNim DeepReview Panel — helpers":

  test "helper text matches the legacy selector and class surface":
    check isonim_deepreview_view.editorId(8) == "deepreview-editor-8"
    check isonim_deepreview_view.fileBasename("/repo/src/main.nim") ==
      "main.nim"
    check isonim_deepreview_view.diffStatusCssClass("A") ==
      " deepreview-diff-added"
    check isonim_deepreview_view.diffStatusCssClass("M") ==
      " deepreview-diff-modified"
    check isonim_deepreview_view.diffStatusCssClass("D") ==
      " deepreview-diff-deleted"
    check isonim_deepreview_view.diffLinesSummary(2, 1) == "+2 / -1"
    check isonim_deepreview_view.fileItemClass(true) ==
      "deepreview-file-item selected"
    check isonim_deepreview_view.modeButtonClass(true) ==
      "deepreview-mode-btn deepreview-mode-btn-active"
    check isonim_deepreview_view.lineClass("added") ==
      "deepreview-unified-line deepreview-unified-line-added"

# ===========================================================================
# Standalone IsoNim app shell tests (§5.3 — app-level structure).
# ===========================================================================

suite "IsoNim App Shell — structure":

  test "renders one header and the expected section host list":
    let r = MockRenderer()
    let shell = renderIsoNimAppShell(r)

    check shell.root.kind == mnkElement
    check shell.root.attributes["class"] == "isonim-app-shell"

    let header = findByClass(shell.root, IsoNimAppHeaderClass)
    check header != nil
    check header.textContent == IsoNimAppHeaderText

    let sections = findAllByClass(shell.root, IsoNimPanelSectionClass)
    let contents = findAllByClass(shell.root, IsoNimSectionContentClass)
    check sections.len == IsoNimAppSectionSpecs.len
    check contents.len == IsoNimAppSectionSpecs.len
    check shell.sections.len == IsoNimAppSectionSpecs.len

    for i, spec in IsoNimAppSectionSpecs:
      check sections[i].attributes["id"] == sectionId(spec.panelId)
      check findByClass(sections[i], IsoNimSectionHeaderClass).textContent ==
        spec.title
      check shell.sections[i].panelId == spec.panelId
      check shell.sections[i].title == spec.title
      check shell.sections[i].content.attributes["class"] ==
        IsoNimSectionContentClass

  test "does not allocate an Editor host outside GoldenLayout context":
    let r = MockRenderer()
    let shell = renderIsoNimAppShell(r)

    for spec in IsoNimAppSectionSpecs:
      check spec.panelId != "editor"
      check spec.title != "Editor"

    check findByClass(shell.root, "editor-component") == nil
    check findByClass(shell.root, "monaco-editor") == nil
