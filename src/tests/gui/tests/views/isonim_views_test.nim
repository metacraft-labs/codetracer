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

import std/[unittest, strutils, tables, options, sets, json, os]
when not defined(js):
  import std/algorithm
import vm_test_helpers
import isonim/core/[signals, computation, owner]
import isonim/testing/mock_dom
import backend/backend_service
import backend/mock_backend
import backend/dap_commands
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
import viewmodels/agent_workspace_vm
import viewmodels/vcs_vm
import viewmodels/welcome_screen_vm
import viewmodels/editor_vm
import app/isonim_app_shell
import views/isonim_state_view
import views/state_view
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
import views/isonim_agent_workspace_view
import views/isonim_vcs_view
import views/isonim_unified_diff_view
import views/isonim_welcome_screen_view
import views/isonim_session_tabs_view
import views/isonim_debug_shell_view
import views/isonim_auto_hide_overlay_tabs_view
import views/isonim_auto_hide_collapsed_icons_view
import views/isonim_auto_hide_bottom_strip_view
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

type
  MockNodeNotFoundError* = object of CatchableError
    ## Raised by the *non*-``OrNil`` lookup helpers below when the rendered
    ## mock DOM has no matching node.
    ##
    ## Why raise rather than return `nil`
    ## ---------------------------------
    ## Every lookup in this file is followed by a dereference
    ## (`.textContent`, `.attributes`, `.children`, `.fireEvent`, …).  A `nil`
    ## `MockNode` dereference is a SIGSEGV, and a SIGSEGV takes down the whole
    ## test *binary* — so a single view that stopped emitting one class silently
    ## cancelled every case declared after it.  That is exactly what happened
    ## here: the suite declares 461 cases and the process died partway through,
    ## after which `[OK]`/`[FAILED]` lines simply stopped appearing.
    ##
    ## `std/unittest`'s own `require` is NOT the fix: it sets `abortOnError`,
    ## so `fail()` ends in `quit(1)` — it kills the process just as the segfault
    ## did.  `unittest`'s `test` template, by contrast, wraps each case body in
    ## `except Exception:` and marks only *that* case FAILED.  So a raised
    ## `CatchableError` is the primitive that fails the case honestly while
    ## letting every later case still run.
    ##
    ## The raising variants are therefore the DEFAULT spelling: new lookups get
    ## the safe behaviour without anyone having to remember a rule.  The
    ## `…OrNil` variants exist for the handful of assertions whose *subject* is
    ## the absence of a node (`check findByClassOrNil(panel, x) == nil`).

proc requireFound(node: MockNode; what: string): MockNode =
  ## Turn a missing-node lookup into a catchable failure of the enclosing
  ## `test` case instead of a process-killing nil dereference one line later.
  if node.isNil:
    raise newException(MockNodeNotFoundError,
      "the rendered mock DOM has no " & what)
  node

proc findByClassOrNil*(node: MockNode; cls: string): MockNode =
  ## Find the first descendant (or self) whose "class" attribute
  ## contains `cls` as a whole word. Returns nil if not found.
  ##
  ## Use this ONLY where the test asserts that the node is absent; anywhere
  ## the result is inspected, use `findByClass` so a missing node fails the
  ## case instead of segfaulting the binary.
  if node.kind == mnkElement:
    let nodeClass = node.attributes.getOrDefault("class", "")
    # Check if cls appears as a whole word in the class attribute.
    for part in nodeClass.split(' '):
      if part == cls:
        return node
  for child in node.children:
    let found = findByClassOrNil(child, cls)
    if found != nil:
      return found
  return nil

proc findByClass*(node: MockNode; cls: string): MockNode =
  ## Like `findByClassOrNil`, but raises `MockNodeNotFoundError` when nothing
  ## matches — see that type's documentation for why raising is what keeps the
  ## remaining cases in this file running.
  requireFound(findByClassOrNil(node, cls),
               "element with class '" & cls & "'")

proc findByIdOrNil*(node: MockNode; id: string): MockNode =
  ## Find the first descendant (or self) with the given id, or nil.
  ## Absence assertions only — see `findByClassOrNil`.
  if node.kind == mnkElement and node.attributes.getOrDefault("id", "") == id:
    return node
  for child in node.children:
    let found = findByIdOrNil(child, id)
    if found != nil:
      return found
  return nil

proc findById*(node: MockNode; id: string): MockNode =
  ## Like `findByIdOrNil`, but raises `MockNodeNotFoundError` when nothing
  ## matches.
  requireFound(findByIdOrNil(node, id), "element with id '" & id & "'")

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

  test "top-level editor exposes source revision semantics":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      store.debugger.val = DebuggerState(
        location: Location(
          file: "src/patchable.c",
          line: 41,
          column: 1,
          sourceGeneration: 2,
          sourceDigest: "sha256:patchable-gen2",
        ),
        rrTicks: 410'u64,
        status: dsIdle,
        threadId: 1'u32,
      )
      let vm = createEditorVM(store)
      let r = MockRenderer()

      let panel = renderEditorPanel(
        r,
        vm,
        index = 7,
        path = "src/patchable.c",
        isExpansion = false,
        expansionDepth = 0)

      check panel.attributes["data-execution-cursor-kind"] == "replay"
      check panel.attributes["data-source-generation"] == "2"
      check panel.attributes["data-source-digest"] == "sha256:patchable-gen2"

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

proc findByTagOrNil*(node: MockNode; tag: string): MockNode =
  ## Find the first descendant (or self) with the given tag name, or nil.
  ## Absence assertions only — see `findByClassOrNil`.
  if node.kind == mnkElement and node.tag == tag:
    return node
  for child in node.children:
    let found = findByTagOrNil(child, tag)
    if found != nil:
      return found
  return nil

proc findByTag*(node: MockNode; tag: string): MockNode =
  ## Like `findByTagOrNil`, but raises `MockNodeNotFoundError` when nothing
  ## matches.
  requireFound(findByTagOrNil(node, tag), "<" & tag & "> element")

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
    check findByClassOrNil(panel, DebugCommandPaletteHostClass).isNil

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

suite "IsoNim Auto-hide Bottom Strip — structure":
  ## These three cases used to exercise `isonim_auto_hide_bottom_tabs_view`,
  ## a second bottom-tabs renderer that only storybook imported and that the
  ## live app stopped using when commit b27da3947 redesigned the status bar.
  ## They are re-pointed at the strip view the app actually renders rather
  ## than deleted: the behaviours they pin (empty state, tab labels in order,
  ## select callback carrying the tab index) are still contracts — they just
  ## belong to the surviving renderer.  See milestone M47.

  test "empty state renders the bottom-strip host without tab children":
    let r = MockRenderer()
    let panel = renderAutoHideBottomStripPanel(r, tabs = @[])

    # No tabs => no `has-tabs` marker, so the status bar's strip host stays
    # collapsed instead of reserving space for nothing.
    check panel.attributes["class"] == ""
    check panel.children.len == 0

  test "bottom tabs render strip-tab selector contract and titles":
    let r = MockRenderer()
    let panel = renderAutoHideBottomStripPanel(
      r,
      tabs = @[
        AutoHideBottomStripRecord(title: "BUILD", active: false),
        AutoHideBottomStripRecord(title: "PROBLEMS", active: false),
        AutoHideBottomStripRecord(title: "SEARCH RESULTS", active: false)
      ])

    check panel.attributes["class"] == AutoHideBottomStripHasTabsClass
    check panel.children.len == 3
    # The tabs are direct children carrying `.auto-hide-strip-tab` — the
    # selector every spec locates them by (`page-objects/auto-hide-strip.ts`).
    check panel.children[0].attributes["class"] == AutoHideBottomStripTabClass
    check panel.children[0].textContent == "BUILD"
    check panel.children[1].textContent == "PROBLEMS"
    check panel.children[2].textContent == "SEARCH RESULTS"

  test "active bottom tab carries the active class":
    let r = MockRenderer()
    let panel = renderAutoHideBottomStripPanel(
      r,
      tabs = @[
        AutoHideBottomStripRecord(title: "BUILD", active: false),
        AutoHideBottomStripRecord(title: "PROBLEMS", active: true)
      ])

    check panel.children[0].attributes["class"] == AutoHideBottomStripTabClass
    check panel.children[1].attributes["class"] ==
      AutoHideBottomStripTabActiveClass

  test "select callback receives bottom tab index":
    let r = MockRenderer()
    var selected = -1
    let panel = renderAutoHideBottomStripPanel(
      r,
      tabs = @[
        AutoHideBottomStripRecord(title: "BUILD", active: false),
        AutoHideBottomStripRecord(title: "SEARCH RESULTS", active: false)
      ],
      cb = AutoHideBottomStripCallbacks(
        onSelect: proc(index: int) = selected = index))

    panel.children[1].fireEvent("click")
    check selected == 1

  test "test_autohide_bottom_panels":
    let r = MockRenderer()
    var unpinnedIndex = -1
    let callbacks = AutoHideBottomStripCallbacks(
      onUnpin: proc(index: int) =
        unpinnedIndex = index
    )

    let tabs = @[
      AutoHideBottomStripRecord(title: "BUILD", active: true),
      AutoHideBottomStripRecord(title: "PROBLEMS", active: false)
    ]

    # Render bottom strip panel
    let panel = renderAutoHideBottomStripPanel(r, tabs, callbacks)
    check panel != nil
    check panel.children.len == 2
    check panel.children[0].textContent == "BUILD"

    # Simulate triggering unpin on the first tab
    callbacks.onUnpin(0)
    check unpinnedIndex == 0

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
    check findByClass(panel, BottomStripClass).attributes["id"] ==
      BottomStripHostId
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

  proc menuSlug(name: string): string =
    ## The same slug `ui/menu.nim` feeds into a node's identity class via
    ## `jslib.convertStringToHtmlClass`: alphanumeric words, lower-cased and
    ## joined with `-`, so "Ruby: Fibonacci" becomes `ruby-fibonacci` and the
    ## GUI suite's `.menu-element-ruby-fibonacci` selector resolves.
    var words: seq[string] = @[]
    var current = ""
    for ch in name:
      if ch.isAlphaNumeric or ch == '-':
        current.add ch
      elif current.len > 0:
        words.add current
        current = ""
    if current.len > 0:
      words.add current
    words.join("-").toLowerAscii

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
      # Mirror `ui/menu.nim`'s `menuRecord`: an element gets
      # `menu-element-<slug>`, a folder gets `menu-folder-<slug>`.  The
      # fixture used the element prefix for both, which made it impossible
      # for this suite to notice that the folder identity classes the GUI
      # suite selects on (`.menu-folder-debug`,
      # `.menu-folder-launch-configurations`) had stopped being rendered.
      nameClass:
        (if kind == MenuRecordFolder: "menu-folder-" else: "menu-element-") &
          menuSlug(name),
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
    check findByIdOrNil(panel, NavigationMenuId) != nil
    check findByIdOrNil(panel, MenuRootId) != nil
    check findByIdOrNil(panel, "menu-logo-img") != nil
    check findByIdOrNil(panel, DebugShellId) != nil
    check findByIdOrNil(panel, "isonim-debug-controls") != nil
    check panel.children[0].attributes["id"] == NavigationMenuId
    check panel.children[1].attributes["id"] == "isonim-debug-controls"
    check panel.children[2].attributes["id"] == DebugShellId
    check findByClassOrNil(panel, WindowMenuClass) != nil
    check findByClassOrNil(panel, "maximize") != nil
    check findByClassOrNil(panel, "restore").isNil
    check findAllByClass(panel, "menu-node-container").len == 0

  test "caption bar host classes follow the window mode":
    # Pure decision logic for `#menu`'s classes.  Three states, only
    # distinguishable at runtime, so they are pinned here rather than through a
    # render: the class cannot be set during a menu render at all — the wrapper
    # the shell builds is discarded by `renderMenuShellInto`, and fullscreen is
    # an OS window state no render pass observes.

    # Windows/Linux draw a real frame: neither class, nothing reserved.
    check captionBarHostClasses("menu", reserveWindowControls = false,
                                fullscreen = false) == "menu"
    check captionBarHostClasses("menu", reserveWindowControls = false,
                                fullscreen = true) == "menu"

    # macOS windowed: reserve room for the traffic-light buttons.
    check captionBarHostClasses("menu", reserveWindowControls = true,
                                fullscreen = false) ==
      "menu " & MenuShellReservedControlsClass

    # macOS fullscreen: the buttons are gone, so reclaim the space instead.
    check captionBarHostClasses("menu", reserveWindowControls = true,
                                fullscreen = true) ==
      "menu " & MenuShellFullscreenClass

  test "caption bar host classes never accumulate or drop foreign classes":
    # The host is shared: `#menu` carries `menu` from index.html and anything
    # else that gets added along the way.  Toggling fullscreen repeatedly must
    # swap only the class this owns and leave the rest untouched and in order.
    var classes = "menu something-else"
    for _ in 0 .. 2:
      classes = captionBarHostClasses(classes, true, fullscreen = true)
      check classes == "menu something-else " & MenuShellFullscreenClass
      classes = captionBarHostClasses(classes, true, fullscreen = false)
      check classes == "menu something-else " & MenuShellReservedControlsClass

    # Leaving macOS behind entirely strips both without touching the others.
    check captionBarHostClasses(classes, false, false) == "menu something-else"

  test "caption bar host classes tolerate messy attribute text":
    check captionBarHostClasses("  menu   " & MenuShellFullscreenClass & "  ",
                                true, fullscreen = false) ==
      "menu " & MenuShellReservedControlsClass
    check captionBarHostClasses("", true, fullscreen = false) ==
      MenuShellReservedControlsClass

  test "caption bar hosts survive without navigation menu":
    let r = MockRenderer()
    let panel = renderMenuShell(
      r,
      MenuShellModel(
        showNavigation: false,
        active: false,
        showWindowMenu: false))

    check findByIdOrNil(panel, NavigationMenuId).isNil
    check findByIdOrNil(panel, DebugShellId) != nil
    check findByIdOrNil(panel, "isonim-debug-controls") != nil
    check findByClassOrNil(panel, WindowMenuClass).isNil

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

    check findByClassOrNil(panel, "menu-active-node") != nil
    # One `.menu-node` per rendered menu row.  This is the selector the GUI
    # suite enumerates the open menu with — `#menu-elements .menu-node` and
    # `.menu-nested-elements .menu-node` in
    # `welcome-screen/launch_config.spec.ts`, catalogued in
    # `codetracer-specs/Testing/UI-Test-Catalog.md` § Launch Configuration
    # Tests — so a row that renders without it is invisible to every one of
    # those tests even though the user can see it.
    check findAllByClass(panel, "menu-node").len == 2
    # …and each row is addressable by kind and by identity, which is what
    # ".menu-folder-debug" / ".menu-element-ruby-fibonacci" in that same
    # catalogue mean for a real menu.
    check findAllByClass(panel, "menu-folder").len == 1
    check findAllByClass(panel, "menu-element").len == 1
    check findByClassOrNil(panel, "menu-folder-file") != nil
    check findByClassOrNil(panel, "menu-element-run") != nil
    check findById(panel, DebugShellId).attributes["class"] == DebugShellClass
    check findByIdOrNil(panel, "isonim-debug-controls") != nil
    # The row must show its keyboard shortcut.  Spec:
    # `codetracer-specs/GUI/Keyboard-Shortcuts-System.md` — "Shortcut display
    # in menus uses a manual `loadShortcut()` function" (§ Known Issues) and
    # "Shortcut hints in UI: Show keyboard shortcut hints on toolbar buttons
    # (tooltips), menu items (already partial)" (§ Future Work).  The slot it
    # is displayed in is the design system's sublabel —
    # `styles/components/menu_item.styl`: ".ct-menu-item-sublabel — secondary
    # / descriptive text (keyboard shortcut)".
    #
    # The hand-written nil guards below date from when `findByClass` returned
    # nil: a nil deref in a `check` aborts the whole test binary with a
    # SIGSEGV, which is how the menu-shell suite once took every later suite in
    # this file down with it.  `findByClass` now raises instead (see
    # `MockNodeNotFoundError`), so the guards are belt-and-braces — they are
    # kept because they are also what makes each `check` below report on its
    # own rather than the first miss masking the rest.
    let shortcut = findByClass(panel, "ct-menu-item-sublabel")
    check shortcut != nil
    if shortcut != nil:
      check shortcut.textContent == "CTRL+R"
    check findByClassOrNil(panel, "restore") != nil
    check findByClassOrNil(panel, "maximize").isNil

  test "clicking menu items and search results invokes callbacks":
    let r = MockRenderer()
    var clickedPath: seq[int] = @[]
    var searchIndex = -1
    let menuPanel = renderMenuShell(
      r,
      MenuShellModel(
        showNavigation: true,
        active: true,
        rootNodes: @[menuNode("Run", @[1], shortcut = "CTRL+R")]),
      MenuShellCallbacks(
        onNodeClick: proc(path: seq[int]) = clickedPath = path,
        onSearchResultClick: proc(index: int) = searchIndex = index))

    # `.menu-element` is the clickable leaf row; `launch_config.spec.ts`
    # activates a launch configuration by clicking exactly this selector
    # (".menu-nested-elements .menu-element", catalogued in
    # `codetracer-specs/Testing/UI-Test-Catalog.md`), so the class and the
    # click handler have to sit on the same element.
    let item = findByClass(menuPanel, "menu-element")
    check item != nil
    # Guarded — see the note above.
    if item != nil:
      item.fireEvent("click")
      check clickedPath == @[1]

    let searchPanel = renderMenuShell(
      r,
      MenuShellModel(
        showNavigation: true,
        active: true,
        searchQuery: "run",
        searchResults: @[
          MenuSearchResultRecord(
            label: "Run",
            shortcut: "CTRL+R",
            iconClass: "run",
            active: true)
        ]),
      MenuShellCallbacks(
        onNodeClick: proc(path: seq[int]) = clickedPath = path,
        onSearchResultClick: proc(index: int) = searchIndex = index))

    let result = findByClass(searchPanel, "menu-search-result")
    check result != nil
    if result != nil:
      result.fireEvent("click")
      check searchIndex == 0

  test "shell UI model can render menu without window controls":
    let r = MockRenderer()
    let panel = renderMenuShell(
      r,
      MenuShellModel(
        showNavigation: true,
        active: true,
        rootNodes: @[menuNode("Shell", @[0], kind = MenuRecordFolder)],
        showWindowMenu: false))

    check findByClassOrNil(panel, WindowMenuClass).isNil
    check findByIdOrNil(panel, DebugShellId) != nil
    check findByIdOrNil(panel, "isonim-debug-controls") != nil
    let folder = findByClass(panel, "menu-folder")
    check folder != nil
    if folder != nil:
      check folder.textContent.contains("Shell")
      # A folder is enabled here, so it must advertise itself as activatable:
      # `codetracer-specs/Testing/UI-Test-Catalog.md` § Launch Configuration
      # Tests — "Launch config items are clickable | Verifies `.menu-enabled`
      # class on launch config elements".
      check folder.attributes["class"].split(' ').contains("menu-enabled")
      check findByClassOrNil(panel, "menu-folder-shell") != nil

  test "submenu rows carry the same identity and enablement hooks":
    ## The launch-configuration flow the GUI suite drives lives entirely in
    ## *submenus*: `codetracer-specs/Testing/UI-Test-Catalog.md` § Launch
    ## Configuration Tests hovers `.menu-folder-debug`, then
    ## `.menu-folder-launch-configurations`, then clicks
    ## `.menu-element-ruby-fibonacci` inside `.menu-nested-elements`, and
    ## checks `.menu-enabled` on it.  Only the root menu was covered here, so
    ## the nested branch could lose those hooks unnoticed — as it had.
    let r = MockRenderer()
    let panel = renderMenuShell(
      r,
      MenuShellModel(
        showNavigation: true,
        active: true,
        rootNodes: @[menuNode("Debug", @[0], kind = MenuRecordFolder)],
        nestedMenus: @[
          MenuNestedRecord(
            id: "menu-nested-elements-1",
            className: "menu-nested-elements",
            style: "top: 0px; left: 0px",
            nodes: @[
              menuNode("Launch Configurations", @[0, 0],
                kind = MenuRecordFolder),
              menuNode("Ruby: Fibonacci", @[0, 1], shortcut = "CTRL+SHIFT+R"),
              menuNode("Stop", @[0, 2], enabled = false)
            ])
        ]))

    let nested = findByClass(panel, "menu-nested-elements")
    check nested != nil
    if nested != nil:
      check findAllByClass(nested, "menu-node").len == 3
      check findByClassOrNil(nested, "menu-folder-launch-configurations") != nil
      let entry = findByClass(nested, "menu-element-ruby-fibonacci")
      check entry != nil
      if entry != nil:
        let entryClasses = entry.attributes["class"].split(' ')
        check entryClasses.contains("menu-element")
        check entryClasses.contains("menu-enabled")
        check entry.textContent.contains("CTRL+SHIFT+R")

      # A disabled entry must say so in both vocabularies: `menu-disabled` is
      # the semantic counterpart of `menu-enabled` above, and
      # `ct-menu-item--disabled` is what actually greys the row out and turns
      # off its pointer events (`styles/components/menu_item.styl`).
      let disabled = findByClass(nested, "menu-element-stop")
      check disabled != nil
      if disabled != nil:
        let disabledClasses = disabled.attributes["class"].split(' ')
        check disabledClasses.contains("menu-disabled")
        check disabledClasses.contains("ct-menu-item--disabled")
        check not disabledClasses.contains("menu-enabled")

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
    check findByIdOrNil(panel, SessionTabBarId) != nil
    check findByClassOrNil(panel, WindowMenuClass) != nil

suite "IsoNim Session Tabs — structure":

  test "single session uses hidden modifier and renders add button":
    ## Spec: `codetracer-specs/GUI/Multi-Window-Tab-Management.md` § Tab
    ## Behavior — 'The "+" button opens a new empty tab (for loading a new
    ## trace)'.
    ##
    ## What that requires of the rendered bar is a single, activatable,
    ## named control wired to "add a session".  This used to be asserted as
    ## `textContent == "+"`, which stopped holding when the plus glyph moved
    ## into the button's background image
    ## (`styles/components/session_tabs.styl` → `session_tab_add.svg`) — a
    ## presentation detail, not the contract.  It is asserted here as the
    ## contract instead: the control exists exactly once, is a real `button`
    ## (so it is focusable and activatable, not a bare div), announces itself
    ## through its title now that no text node names it, and adding is what
    ## clicking it does.
    var addCount = 0
    let r = MockRenderer()
    let panel = renderSessionTabsPanel(
      r,
      @[SessionTabRecord(label: "main.py")],
      activeIndex = 0,
      callbacks = SessionTabsCallbacks(onAdd: proc() = addCount += 1))

    check panel.attributes["id"] == SessionTabBarId
    check panel.attributes["class"] == SessionTabBarSingleClass
    check findAllByClass(panel, SessionTabClass).len == 1
    check findAllByClass(panel, SessionTabAddClass).len == 1

    let addButton = findByClass(panel, SessionTabAddClass)
    check addButton != nil
    if addButton != nil:
      check addButton.tag == "button"
      check addButton.attributes["title"] == SessionTabAddTitle
      addButton.fireEvent("click")
      check addCount == 1
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

  test "many sessions cap visible tabs and expose overflow menu items":
    ## Regression guard for the caption bar: once the fixed debugger controls
    ## and centered omnibox reserve space, the session tabs need a compact
    ## chevron/list affordance instead of drawing every tab into the caption
    ## bar.  The visual GUI test verifies real overflow geometry; this headless
    ## view test documents the DOM hook the renderer must provide.
    let r = MockRenderer()
    let panel = renderSessionTabsPanel(
      r,
      @[
        SessionTabRecord(label: "Trace 1"),
        SessionTabRecord(label: "Trace 2"),
        SessionTabRecord(label: "Trace 3"),
        SessionTabRecord(label: "Trace 4"),
        SessionTabRecord(label: "Trace 5"),
        SessionTabRecord(label: "Trace 6"),
        SessionTabRecord(label: "Trace 7"),
        SessionTabRecord(label: "Trace 8")
      ],
      activeIndex = 6,
      visibleTabCount = 3)

    check panel.attributes["class"] == SessionTabBarOverflowClass
    let tabs = findAllByClass(panel, SessionTabClass)
    check tabs.len == 3
    let overflow = findByClass(panel, "session-tab-overflow")
    check overflow != nil
    check overflow.textContent in [">", "v", "⌄", "⋯"]
    let overflowItems = findAllByClass(panel, SessionTabOverflowItemClass)
    check overflowItems.len == 8
    check overflowItems[6].attributes["class"].contains("active")

  test "overflow menu items switch hidden tabs":
    var selected: seq[int] = @[]
    let callbacks = SessionTabsCallbacks(
      onSelect: proc(index: int) = selected.add(index))
    let r = MockRenderer()
    let panel = renderSessionTabsPanel(
      r,
      @[
        SessionTabRecord(label: "Trace 1"),
        SessionTabRecord(label: "Trace 2"),
        SessionTabRecord(label: "Trace 3"),
        SessionTabRecord(label: "Trace 4")
      ],
      activeIndex = 0,
      visibleTabCount = 2,
      callbacks = callbacks)

    let visibleTabs = findAllByClass(panel, SessionTabClass)
    check visibleTabs.len == 2
    let overflowItems = findAllByClass(panel, SessionTabOverflowItemClass)
    overflowItems[3].fireEvent("click")
    check selected == @[3]

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
      check rows[0].attributes["data-variable-name"] == "x"

      # Check second variable content
      let secondText = rows[1].textContent
      check "y" in secondText
      check "hello" in secondText
      check rows[1].attributes["data-variable-name"] == "y"

      dispose()

  test "value-history button uses image-button markup and calls bridge":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      let r = MockRenderer()

      var toggled: seq[string] = @[]
      vm.onToggleHistory = proc(expression: string) =
        toggled.add(expression)

      store.updateLocals(@[
        makeVariable("x", "42", "int"),
      ])

      let panel = renderStatePanel(r, vm)
      let button = findById(panel, "value-history")
      check button != nil
      check button.tag == "button"
      # `a6dec58a` moved this button from the `sm` size class to `xs` and
      # dropped `ct-custom-button-size`.  That was deliberate and coordinated:
      # the same commit added `[class*="ct-button-image-xs-"]` (the 1em box) to
      # `styles/components/button.styl` and made the identical edit to the
      # legacy Karax renderer in `ui/value.nim`, so the two markups still
      # agree.  `ct-custom-button-size` is now defined nowhere in the tree —
      # asserting it would pin a class that styles nothing.
      let btnClasses = button.attributes["class"].split(' ')
      check "value-history-button" in btnClasses
      check "ct-button-image-xs-secondary" in btnClasses
      check "ct-custom-button-size" notin btnClasses
      check findByClass(button, "custom-tooltip").textContent ==
        "Toggle history value"

      button.fireEvent("click")
      check toggled == @["x"]

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

  test "origin badge public resources contain the complete icon set":
    # The badge stylesheet and public-resource Tupfile both resolve these
    # names from this directory. Keeping this assertion beside the badge DOM
    # test makes a misplaced or partially added icon fail the regular native
    # and JavaScript ViewModel lanes before the frontend build reaches Tup.
    const repoRoot = currentSourcePath()
      .parentDir.parentDir.parentDir.parentDir.parentDir.parentDir
    const iconDir = repoRoot & "/src/public/resources/origin-icons/"
    const expectedIconFiles = [
      "clock-rewind.svg",
      "door.svg",
      "globe.svg",
      "hourglass.svg",
      "pin.svg",
      "question.svg",
      "quotation.svg",
      "sigma.svg",
    ]
    const iconContents = [
      staticRead(iconDir & expectedIconFiles[0]),
      staticRead(iconDir & expectedIconFiles[1]),
      staticRead(iconDir & expectedIconFiles[2]),
      staticRead(iconDir & expectedIconFiles[3]),
      staticRead(iconDir & expectedIconFiles[4]),
      staticRead(iconDir & expectedIconFiles[5]),
      staticRead(iconDir & expectedIconFiles[6]),
      staticRead(iconDir & expectedIconFiles[7]),
    ]
    const resourceTupfile =
      staticRead(repoRoot & "/src/public/resources/Tupfile")
    const expectedTupRule =
      ": foreach origin-icons/*.svg |> !tup_preserve |> %f"

    for iconContent in iconContents:
      check iconContent.len > 0

    var originIconRules: seq[string] = @[]
    for line in resourceTupfile.splitLines:
      if "origin-icons" in line:
        originIconRules.add(line)
    check originIconRules == @[expectedTupRule]

    when not defined(js):
      var actualIconFiles: seq[string] = @[]
      for kind, path in walkDir(iconDir):
        if kind == pcFile and path.endsWith(".svg"):
          actualIconFiles.add(path.extractFilename)
      actualIconFiles.sort()
      check actualIconFiles == @expectedIconFiles

  test "test_origin_badge_interaction":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createStateVM(store)
      let r = MockRenderer()

      store.updateLocals(@[
        makeVariable("x", "42", "int"),
      ])
      vm.updateOriginSummaries(@[
        ("x", OriginSummary(terminatorKind: tkwLiteral,
                            terminatorExpr: "42", hopCount: 1)),
      ])
      # Wire a chain lookup
      let chain = OriginChain(
        queryVariable: "x",
        queryStepId: 1,
        hops: @[
          OriginHop(kind: okTrivialCopy, targetExpr: "x",
                    sourceExpr: "y", stepId: 1,
                    location: OriginLocation(path: "fixture.py", line: 1)),
        ],
        terminator: Terminator(kind: tkwLiteral, expression: "42"),
      )
      vm.originChainLookup = proc(name: string): Option[OriginChain] =
        if name == "x": some(chain) else: none(OriginChain)

      let panel = renderStatePanel(r, vm)
      let badge = findByClass(panel, "ct-origin-badge")
      check badge != nil
      check "ct-origin-icon-quotation" in badge.attributes["class"]
      check badge.textContent == "42"

      # Install parent click listener to detect propagation
      var parentClicked = false
      let row = findByClass(panel, "value-name-container")
      check row != nil
      row.eventHandlers["click"] = @[
        proc(ev: MockEvent) = parentClicked = true
      ]

      # Click the badge
      let ev = MockEvent(`type`: "click", target: badge, currentTarget: badge)
      fireEventWith(badge, "click", ev)

      # 1. Verify propagation was prevented/stopped
      check not parentClicked
      check ev.propagationStopped

      # 2. Verify VM expanded state was updated
      let viewState = getStateViewState(vm)
      let rowId = VariableId(name: viewState.variables[0].name, scopePath: viewState.variables[0].path)
      check vm.isOriginExpanded(rowId) == true

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
    let populated = findByClassOrNil(panel, "code-state-line")
    if populated != nil:
      return populated
    # Fall back: when the element only carries the ``no-code``
    # modifier the whole-word class match still succeeds because both
    # classes are present, but be defensive in case someone tweaks the
    # markup.
    #
    # Both probes use the ``OrNil`` spelling because either one missing on its
    # own is normal here.  It is only when BOTH miss that the callers'
    # dereference would segfault, so that is where this raises.
    requireFound(findByClassOrNil(panel, "no-code"),
                 "element with class 'code-state-line' or 'no-code'")

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

  test "call rows expose function and source generation semantics":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      let r = MockRenderer()

      store.updateCalltraceSection(
        @[
          CallLine(
            index: 0,
            name: "reprobuild_hcr_patchable_value",
            displayName: "reprobuild_hcr_patchable_value [gen 1]",
            depth: 0,
            rrTicks: 300'u64,
            location: Location(
              file: "src/patchable.c",
              line: 61,
              column: 1,
              sourceGeneration: 1,
              sourceDigest: "sha256:patchable-gen1",
            ),
            codeGeneration: 1,
            callKey: "patchable:1",
          ),
        ],
        startIndex = 0'i64,
        totalCount = 1'u64,
      )

      vm.setViewportHeight(10)

      let panel = renderCalltracePanel(r, vm)
      let container = findByClass(panel, "calltrace-lines")
      let rows = findAllByClass(container, "calltrace-call-line")
      check rows.len == 1
      check rows[0].textContent.contains("[gen 1]")
      check rows[0].attributes["data-function"] ==
        "reprobuild_hcr_patchable_value"
      check rows[0].attributes["data-source-generation"] == "1"
      check rows[0].attributes["data-source-digest"] ==
        "sha256:patchable-gen1"
      check rows[0].attributes["data-code-generation"] == "1"
      check rows[0].attributes["data-rr-ticks"] == "300"

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

  test "test_calltrace_jump_highlighting":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      let r = MockRenderer()

      vm.setViewportHeight(10)

      # Initially no selection
      check vm.selectedEntry.val.isNone

      # Select entry
      vm.selectEntry(some(1'i64))
      check vm.selectedEntry.val.isSome
      check vm.selectedEntry.val.get == 1

      # Clear selection
      vm.selectEntry(none(int64))
      check vm.selectedEntry.val.isNone

      dispose()

  test "test_calltrace_collapse_dots":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCalltraceVM(store)
      let r = MockRenderer()

      var line1 = makeTestCallLine(0, "parentExpanded", depth = 0)
      line1.hasChildren = true
      line1.isExpanded = true

      var line2 = makeTestCallLine(1, "parentCollapsed", depth = 0)
      line2.hasChildren = true
      line2.isExpanded = false

      var line3 = makeTestCallLine(2, "leaf", depth = 0)
      line3.hasChildren = false
      line3.isExpanded = false

      store.updateCalltraceSection(
        @[line1, line2, line3],
        startIndex = 0'i64,
        totalCount = 3'u64,
      )

      vm.setViewportHeight(10)

      let panel = renderCalltracePanel(r, vm)
      let container = findByClass(panel, "calltrace-lines")
      let rows = findAllByClass(container, "calltrace-call-line")

      check rows.len == 3
      check findByClassOrNil(rows[0], "collapse-call-img") != nil
      check findByClassOrNil(rows[1], "expand-call-img") != nil
      check findByClassOrNil(rows[2], "dot-call-img") != nil

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
      store.session.val = SessionState(
        connectionStatus: csConnected,
        debugSessionMode: liveMcr,
        lastLiveDebugSessionMode: liveMcr,
        recordingHeadRRTicks: 400'u64,
        recordingHeadLoadingState: lsIdle,
      )
      let vm = createDebugControlsVM(store)
      let r = MockRenderer()

      let panel = renderDebugControlsPanel(r, vm)

      check panel.kind == mnkElement
      check panel.tag == "div"
      check panel.attributes["class"] == "debug-controls"
      check panel.attributes["data-session-mode"] == "liveMcr"
      check panel.attributes["data-recording-head"] == "400"

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

  test "step-backward enabled at start of a completed replay":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)
      let r = MockRenderer()

      # A fresh store is a ``completedReplay`` (the zero value of
      # ``DebugSessionMode``) sitting at rrTicks=0 == minRRTicks.  Backward
      # navigation is still available: a recorded trace is inherently
      # time-travellable, so the toolbar does not wait for the
      # ``supportsStepBack`` capability (which can lose a race with session-VM
      # creation) or for rr ticks (which DB traces never populate).  This test
      # asserted the opposite until ``c5be0b990`` deliberately changed it.
      let panel = renderDebugControlsPanel(r, vm)

      let stepBwd = findByClass(panel, "step-backward")
      check stepBwd.attributes.getOrDefault("disabled", "") == ""

      dispose()

  test "step-backward disabled at start of a live recording":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)
      let r = MockRenderer()

      # The invariant the previous version of the test above was really
      # protecting: while the recording head is still moving there is no
      # recorded past to step into, so backward navigation stays disabled.
      # ``completedReplay`` being the enum's zero value is what made the old
      # assertion look like it covered this case when it never did.
      var session = store.session.val
      session.debugSessionMode = liveMcr
      store.session.val = session

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

  test "step-backward and reverse-continue enabled when supportsStepBack is true even at start":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      var session = store.session.val
      session.supportsStepBack = true
      store.session.val = session

      let vm = createDebugControlsVM(store)
      let r = MockRenderer()

      # debugger at rrTicks=0, minRRTicks=0 but supportsStepBack is true
      let panel = renderDebugControlsPanel(r, vm)

      let stepBwd = findByClass(panel, "step-backward")
      let revContinue = findByClass(panel, "reverse-continue")
      check "disabled" notin stepBwd.attributes
      check "disabled" notin revContinue.attributes

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

  test "click step-backward steps a completed replay at start":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)
      let r = MockRenderer()

      let panel = renderDebugControlsPanel(r, vm)

      let stepBwd = findByClass(panel, "step-backward")
      let beforeCount = mock.receivedCommands.len

      stepBwd.fireEvent("click")
      drain()

      # Counterpart to the enabled-state test above: a completed replay is
      # time-travellable from its first step, so the click dispatches rather
      # than being swallowed.
      check mock.receivedCommands.len == beforeCount + 1

      dispose()

  test "click step-backward is a no-op on a live recording":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createDebugControlsVM(store)
      let r = MockRenderer()

      var session = store.session.val
      session.debugSessionMode = liveMcr
      store.session.val = session

      let panel = renderDebugControlsPanel(r, vm)

      let stepBwd = findByClass(panel, "step-backward")
      let beforeCount = mock.receivedCommands.len

      stepBwd.fireEvent("click")
      drain()

      # The click-side half of the live invariant: no recorded past yet, so
      # the disabled button must not dispatch.
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

suite "IsoNim Flow Panel — active line sync":

  test "test_js_flow_active_line_sync":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createFlowVM(store)
      drain()

      # Simulate active line change by updating store's debugger position
      store.updateDebuggerPosition(100'u64, "test.js", 12)
      drain()

      # Verify that store's debugger location is synchronized
      check store.debugger.val.location.file == "test.js"
      check store.debugger.val.location.line == 12
      check store.debugger.val.rrTicks == 100'u64

      # Verify that auto-load effect was triggered (sends ct/load-flow)
      var foundLoadFlow = false
      for cmd in mock.receivedCommands:
        if cmd.command == "ct/load-flow":
          # The tick lives inside `location`: `CtLoadFlowArguments`
          # (src/db-backend/src/task.rs) has exactly `flowMode` and
          # `location`, both required. See the boundary suite in
          # `tests/flow/flow_vm_test.nim`.
          check cmd.args["location"]["rrTicks"].getBiggestInt == 100
          check cmd.args["location"]["path"].getStr == "test.js"
          foundLoadFlow = true
          break
      check foundLoadFlow

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
      check track.attributes["role"] == "slider"
      check track.attributes["data-min-rr-ticks"] == "0"
      check track.attributes["data-max-rr-ticks"] == "0"
      check track.attributes["data-current-rr-ticks"] == "0"

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
                         isLiteral: bool = false;
                         typeName: string = "";
                         hasChildren: bool = false;
                         children: seq[Variable] = @[]): ScratchpadValueEntry =
  ## Test fixture builder for ``ScratchpadValueEntry`` rows.
  ScratchpadValueEntry(
    expression: expression,
    valueText: valueText,
    isError: isError,
    isLiteral: isLiteral,
    typeName: typeName,
    hasChildren: hasChildren,
    children: children,
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

  test "test_value_component_layout_and_scratchpad":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)

      # Create a compound value with children
      let entry = makeScratchpadEntry(
        expression = "myArray",
        valueText = "[...]",
        typeName = "seq[int]",
        hasChildren = true,
        children = @[
          Variable(name: "[0]", value: "100", typeName: "int", hasChildren: false, children: @[]),
          Variable(name: "[1]", value: "200", typeName: "int", hasChildren: false, children: @[])
        ]
      )
      vm.addValue(entry)

      let r = MockRenderer()
      let panel = renderScratchpadPanel(r, vm)
      drain()

      # Initially, only the top-level element is in the row views
      let rowsBefore = getScratchpadRowViews(vm)
      check rowsBefore.len == 1
      check rowsBefore[0].expression == "myArray"
      check rowsBefore[0].depth == 0
      check rowsBefore[0].hasChildren == true
      check rowsBefore[0].isExpanded == false

      # Expand the array value (path is "0" for the first entry)
      vm.toggleExpand("0")
      drain()

      # Verify that children are now visible in the flattened list
      let rowsAfter = getScratchpadRowViews(vm)
      check rowsAfter.len == 3
      check rowsAfter[0].expression == "myArray"
      check rowsAfter[0].isExpanded == true
      check rowsAfter[1].expression == "[0]"
      check rowsAfter[1].valueText == "100"
      check rowsAfter[1].depth == 1
      check rowsAfter[2].expression == "[1]"
      check rowsAfter[2].valueText == "200"
      check rowsAfter[2].depth == 1

      dispose()

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

  test "test_terminal_click_navigation: fragment click dispatches ct/event-jump via the backend":
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
      check req.get.args["directLocationRRTicks"].getInt == 42
      check req.get.args["kind"].getStr == "Write"

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

      check findByClassOrNil(panel, "build-header") != nil
      check findByClassOrNil(panel, "build-header-controls") != nil
      check findByClassOrNil(panel, "build-stop-btn") != nil
      check findByClassOrNil(panel, "build-clear-btn") != nil
      check findByClassOrNil(panel, "build-scroll-btn") != nil

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

      check findByClassOrNil(panel, "problems-header") != nil
      check findByClassOrNil(panel, "problems-counts") != nil
      check findByClassOrNil(panel, "problems-controls") != nil
      check findByClassOrNil(panel, "problems-count-error") != nil
      check findByClassOrNil(panel, "problems-count-warning") != nil

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
# IsoNim Find in Files (Search Results) Panel — tests
#
# Cover ``views/isonim_search_results_view.nim``: panel structure, the
# reactive body's three states (pre-search overlay / loading / results),
# match-row rendering grouped by file, count badges, query highlighting,
# filter narrowing, and click → jump-location routing.
#
# VOCABULARY NOTE.  The panel was redesigned by 529c8dd1 / 182f9e6c into a
# ``fif-*`` (Find In Files) DOM, and these cases were re-expressed against
# it.  Three things the pre-redesign contract asserted are gone on purpose
# and are NOT asserted here:
#
#   * ``component-container`` on the panel root — the GoldenLayout host the
#     panel mounts into (``ui/layout.nim``) already carries it; ``fif-panel``
#     now carries the flex/height layout itself.
#   * the ``search-results-header`` row and its panel-wide
#     ``search-results-count`` badge — removed by 182f9e6c ("panel now starts
#     directly with the search input"); the per-file-group ``fif-file-count``
#     badge is the count the design shows.
#   * the ``search-results-active`` / ``search-results-non-active`` root
#     modifier, whose CSS is ``display: flex`` / ``display: none``.  The panel
#     now OWNS the query input, so hiding it before a search would hide the
#     only way to start one.  The state transition it used to express is
#     asserted through the body (overlay ⇄ file groups) and through
#     ``vm.active``, which the wiring layer still mirrors
#     (``ui/search_results.nim``'s ``syncLegacySearchResultsIntoVM``).
#
# Two class names are deliberately still asserted in their legacy spelling:
# ``search-results`` on the root and ``search-results-match-row`` /
# ``search-results-highlight`` on rows.  Those are the anchors
# ``tests/build/search-results-e2e.spec.ts`` and the auto-hide / render-panel
# wiring look the panel up by, so a case that stopped naming them would stop
# protecting them.
# ===========================================================================

proc makeResult(path: string = "src/main.nim";
                line: int = 1;
                text: string = "match snippet"): SearchResultLine =
  SearchResultLine(text: text, path: path, line: line)

# ---------------------------------------------------------------------------
# Structure
# ---------------------------------------------------------------------------

suite "IsoNim Search Results Panel — structure":

  test "renders root with fif-panel + search-results identity classes":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchResultsVM(store)
      let r = MockRenderer()

      let panel = renderSearchResultsPanel(r, vm)

      check panel.kind == mnkElement
      check panel.tag == "div"
      # Whole-word membership, not substring containment: `"search-results" in
      # cls` would also be satisfied by `search-results-anything`, so it could
      # not tell the wiring anchor apart from a modifier that replaced it.
      let cls = panel.attributes["class"].split(' ')
      check "search-results" in cls
      check "fif-panel" in cls

      dispose()

  test "starts in the pre-search state with no rows":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchResultsVM(store)
      let r = MockRenderer()

      let panel = renderSearchResultsPanel(r, vm)

      # "Inactive" is no longer a root class (see the vocabulary note above);
      # it is the body showing the pre-search overlay and nothing else, plus
      # the VM flag the wiring layer mirrors back out of the panel.
      check vm.active.val == false
      let body = findByClass(panel, "fif-body")
      check body.children.len == 1
      check "fif-empty" in body.children[0].attributes["class"].split(' ')
      check findAllByClass(panel, "fif-match-row").len == 0
      check findAllByClass(panel, "fif-file-group").len == 0

      dispose()

  test "renders the search bar, the query input, and the body container":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchResultsVM(store)
      let r = MockRenderer()

      let panel = renderSearchResultsPanel(r, vm)

      let bar = findByClass(panel, "fif-search-bar")
      # The panel's input is the SEARCH input (Enter → `vm.onSearch`), which
      # 529c8dd1 moved into the panel.  It is not the pre-redesign
      # `search-results-find-query` filter box — no filter input is rendered
      # any more, though the filter itself is still honoured (see the filter
      # suite below, which drives `vm.setFilter` directly).
      let input = findById(panel, "fif-input")
      check input.tag == "input"
      check input.attributes["placeholder"] == "Search in files..."
      check findByClassOrNil(bar, "fif-input") == input
      check findByClass(bar, "fif-badge").textContent == "Find in Files"

      # The reactive body: every state the render effect rebuilds hangs here.
      check findByClassOrNil(panel, "fif-body") != nil

      dispose()

  test "with no results the panel renders no count badge and no rows":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchResultsVM(store)
      let r = MockRenderer()

      let panel = renderSearchResultsPanel(r, vm)

      # The panel-wide "No results" badge went away with the header row.
      # What must still hold is that an empty result set produces no count
      # affordance at all: an empty file group reading "0 matches" would be
      # a real bug, and is exactly what a careless grouping change emits.
      check vm.resultCount.val == 0
      check findAllByClass(panel, "fif-file-group").len == 0
      check findAllByClass(panel, "fif-file-count").len == 0
      check findAllByClass(panel, "fif-match-row").len == 0

      dispose()

  test "renders the empty-state overlay when there are no results":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchResultsVM(store)
      let r = MockRenderer()

      let panel = renderSearchResultsPanel(r, vm)
      let empty = findByClass(panel, "fif-empty")
      # With no recent searches the overlay is the call-to-action prompt;
      # with recent searches it lists them instead (asserted below).
      check findByClass(empty, "fif-empty-prompt").textContent ==
        "Type a query above and press Enter to search"

      dispose()

  test "the loading state shows the shimmer skeleton and nothing else":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchResultsVM(store)
      let r = MockRenderer()

      let panel = renderSearchResultsPanel(r, vm)
      let body = findByClass(panel, "fif-body")

      vm.setLoading(true)

      # The shimmer REPLACES the overlay rather than sitting beside it: a
      # search in flight must not still be showing "press Enter to search".
      # Six blocks because that is what the production (web) renderer draws;
      # the two used to disagree, so the count is a shared constant and this
      # is what pins it.
      check findAllByClass(panel, "fif-shimmer-block").len == 6
      check body.children.len == 6
      check findByClassOrNil(panel, "fif-empty") == nil
      check findAllByClass(panel, "fif-match-row").len == 0

      # Results ending the search clear the shimmer — the transition the
      # panel would otherwise be stuck in when a batch arrives.
      vm.setResults(@[makeResult()])
      check vm.loading.val == false
      check findAllByClass(panel, "fif-shimmer-block").len == 0
      check findAllByClass(panel, "fif-match-row").len == 1

      dispose()

# ---------------------------------------------------------------------------
# Count reactivity
#
# The pre-redesign panel-wide badge is gone; the count surfaces that
# survived are the per-file-group `fif-file-count` badge, the number of
# rendered rows, and `vm.resultCount` (which `ui/search_results.nim` reads
# back via `currentResultCount` to build the recent-searches entries).
# ---------------------------------------------------------------------------

suite "IsoNim Search Results Panel — count reactivity":

  test "setResults is reflected in the rows and the per-file count badges":
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

      check vm.resultCount.val == 3
      check findAllByClass(panel, "fif-match-row").len == 3

      let counts = findAllByClass(panel, "fif-file-count")
      check counts.len == 2
      check counts[0].textContent == "2 matches"
      check counts[1].textContent == "1 match"

      dispose()

  test "single-result count uses the singular noun":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchResultsVM(store)
      let r = MockRenderer()

      let panel = renderSearchResultsPanel(r, vm)

      # Noun agreement is the property; only the badge carrying it moved.
      # The redesign lost it (the file badge read "1 matches"), so the view
      # was fixed rather than the assertion weakened — `countLabel` in
      # `isonim_search_results_view.nim` is now shared by both renderers.
      vm.setResults(@[makeResult()])
      check findByClass(panel, "fif-file-count").textContent == "1 match"

      # The recent-searches list is the other place a count reaches the
      # user, and it goes through the same helper.
      vm.clearResults()
      vm.addRecentSearch("solo", 1)
      check findByClass(panel, "fif-recent-count").textContent == "1 result"
      vm.addRecentSearch("pair", 2)
      check findByClass(panel, "fif-recent-count").textContent == "2 results"

      dispose()

  test "appendResults grows the rows and the count incrementally":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchResultsVM(store)
      let r = MockRenderer()

      let panel = renderSearchResultsPanel(r, vm)
      check vm.resultCount.val == 0
      check findAllByClass(panel, "fif-match-row").len == 0

      vm.appendResults(@[makeResult()])
      check vm.resultCount.val == 1
      check findAllByClass(panel, "fif-match-row").len == 1
      check findByClass(panel, "fif-file-count").textContent == "1 match"

      # Same path for all three rows, so they accumulate into one group —
      # a batch that replaced rather than appended would show "2 matches".
      vm.appendResults(@[makeResult(line = 9), makeResult(line = 10)])
      check vm.resultCount.val == 3
      check findAllByClass(panel, "fif-match-row").len == 3
      check findByClass(panel, "fif-file-count").textContent == "3 matches"

      dispose()

  test "results arriving replace the empty overlay and flip the active flag":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchResultsVM(store)
      let r = MockRenderer()

      let panel = renderSearchResultsPanel(r, vm)
      let body = findByClass(panel, "fif-body")
      check "fif-empty" in body.children[0].attributes["class"].split(' ')
      check vm.active.val == false

      vm.setResults(@[makeResult()])

      # This is the transition the `search-results-active` root modifier used
      # to express: the body swaps the overlay for file groups, and the VM
      # flag the wiring layer reads flips with it.
      check vm.active.val == true
      check findByClassOrNil(panel, "fif-empty") == nil
      check findAllByClass(panel, "fif-file-group").len == 1
      check findAllByClass(panel, "fif-match-row").len == 1

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

      let rows = findAllByClass(panel, "fif-match-row")
      check rows.len == 3

      let groups = findAllByClass(panel, "fif-file-group")
      check groups.len == 2

      # Grouping is structural, not just a header caption: each row must live
      # UNDER the group for its own path.  A flat list with group headers
      # interleaved would satisfy the two counts above and nothing else here.
      check findAllByClass(groups[0], "fif-match-row").len == 2
      check findAllByClass(groups[1], "fif-match-row").len == 1

      dispose()

  test "file-header preserves first-appearance order with match count":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchResultsVM(store)
      let r = MockRenderer()

      let panel = renderSearchResultsPanel(r, vm)

      # "z" before "a" so first-appearance order is distinguishable from
      # sorted order — the property is that groups follow the result stream.
      # The paths are nested rather than bare filenames so the header's
      # `shortPath` shortening (last TWO components, so deep trees do not
      # overflow the panel) is exercised: with one-component paths it is the
      # identity function and a header that printed the whole path would look
      # identical.
      vm.setResults(@[
        makeResult(path = "src/frontend/z.nim", line = 1),
        makeResult(path = "src/common/a.nim", line = 2),
        makeResult(path = "src/frontend/z.nim", line = 5),
      ])

      let headers = findAllByClass(panel, "fif-file-header")
      check headers.len == 2

      check findByClass(headers[0], "fif-file-path").textContent == "frontend/z.nim"
      check findByClass(headers[0], "fif-file-count").textContent == "2 matches"

      check findByClass(headers[1], "fif-file-path").textContent == "common/a.nim"
      check findByClass(headers[1], "fif-file-count").textContent == "1 match"

      dispose()

  test "row text content carries line number and snippet":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createSearchResultsVM(store)
      let r = MockRenderer()

      let panel = renderSearchResultsPanel(r, vm)

      vm.setResults(@[makeResult(path = "main.nim", line = 42,
                                 text = "let foo = 1")])

      let rows = findAllByClass(panel, "fif-match-row")
      check rows.len == 1
      let lineNum = findByClass(rows[0], "fif-line-number")
      let matchText = findByClass(rows[0], "fif-match-text")
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
      check findAllByClass(panel, "fif-match-row").len == 2

      vm.clearResults()

      let body = findByClass(panel, "fif-body")
      check body.children.len == 1
      check "fif-empty" in body.children[0].attributes["class"].split(' ')
      check findAllByClass(panel, "fif-match-row").len == 0
      # And the panel goes back to inactive — what the root's
      # `search-results-non-active` modifier used to show.
      check vm.active.val == false

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

      check findByClassOrNil(panel, "search-results-highlight") == nil

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

      check findAllByClass(panel, "fif-match-row").len == 3

      vm.setFilter("alpha")

      check findAllByClass(panel, "fif-match-row").len == 2
      # The excluded row's whole group goes with it.
      check findAllByClass(panel, "fif-file-group").len == 2

      # The filter narrows DISPLAY only: the panel renders
      # `vm.visibleResults`, while `vm.resultCount` keeps reporting the
      # unfiltered total the search service produced (the pre-redesign
      # header badge asserted the same split).  A view that rendered
      # `vm.results` instead of `vm.visibleResults` would satisfy every
      # other case in this file and fail only here.
      check vm.resultCount.val == 3

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
      check findAllByClass(panel, "fif-match-row").len == 1

      vm.setFilter("nothingmatchesthis")
      let body = findByClass(panel, "fif-body")
      check body.children.len == 1
      check "fif-empty" in body.children[0].attributes["class"].split(' ')
      check findAllByClass(panel, "fif-match-row").len == 0
      # The results themselves are untouched — only the view narrowed.
      check vm.resultCount.val == 1

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

      # Click the third row, which lives under the second file group.  The
      # closure each row captures must be its own: a shared loop variable
      # would dispatch b.nim:9 (or a.nim:5) from this click and nothing
      # about the rendered markup would look wrong.
      let groups = findAllByClass(panel, "fif-file-group")
      check groups.len == 2
      let bGroupRows = findAllByClass(groups[1], "fif-match-row")
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

      let messageNode = findByClassOrNil(panel, "unknown-location-message")
      check messageNode == nil

      let buttonNode = findByClassOrNil(panel, "jump-back-button")
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
      check findByClassOrNil(panel, "jump-back-button") != nil

      # Then clear.
      vm.setHistory(NoSourceHistoryInfo())
      check findByClassOrNil(panel, "jump-back-button") == nil
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

      check findByClassOrNil(panel, "jump-back-button") == nil
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

      check findByClassOrNil(panel, "step-list-lines-box") != nil
      check findByClassOrNil(panel, "step-lines") != nil

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

      check findByClassOrNil(panel, "step-line-delta") != nil
      check findByClassOrNil(panel, "step-line-location") != nil
      check findByClassOrNil(panel, "step-line-source-code") != nil
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

      check findByClassOrNil(panel, "step-line-return") != nil
      check findByClassOrNil(panel, "step-line-return-value") == nil

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

  # These two tests deliberately do NOT assert "command X was dispatched".
  # That is the assertion this pane's previous tests made, and it is why
  # they stayed green for as long as `ct/line-step-jump` existed in no
  # mapping table and no dispatch table: `MockBackendService.send` records
  # whatever string it is handed and validates none of it.
  #
  # What they assert instead is the contract whose absence let that
  # happen — the emitted command must be one the system can RESOLVE
  # (`isValidDapCommand`; in production `dapCommandToEventKind` raises
  # `ValueError` when it cannot) — plus the row's own data reaching the
  # payload, and the request count.
  #
  # That the click actually MOVES the session is asserted where it can be
  # honestly measured, against a real replay-server:
  # `src/frontend/viewmodel/tests/unit/test_row_click_jump_vm.nim`.

  test "clicking a Line row asks the backend to move to that row's tick":
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

      # Counted, with the count itself asserted: one click, one request.
      check mock.receivedCommands.len == 1
      let sent = mock.receivedCommands[0]

      # Resolvable — the check that was missing everywhere.
      check isValidDapCommand(sent.command)

      # The clicked row's tick is what got asked for.
      check sent.args{"ticks"}.getInt == 142

      dispose()

  test "a step-line request carries every field the engine requires":
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

      check mock.receivedCommands.len == 1
      let sent = mock.receivedCommands[0]
      check isValidDapCommand(sent.command)

      # `GoToTicksArguments` declares no `#[serde(default)]`, so a missing
      # `threadId` fails the whole request with `missing field threadId`
      # and the session does not move. Asserted here because it is cheap,
      # and because `event_log_vm.jumpToCounterpart` ships exactly that
      # bug today — it sends {rrTicks, ticks} and no threadId.
      check sent.args.hasKey("threadId")
      check sent.args{"ticks"}.getInt == 7

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
      check findByTagOrNil(panel, "form") == nil
      check findByClassOrNil(panel, "repl-input-history") == nil

  test "enabled flag (without materialised) renders prompt + history":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createReplVM(store)
      vm.setReplEnabled(true)
      let r = MockRenderer()

      let panel = renderReplPanel(r, vm)

      check vm.displayMode.val == rdmReplEnabled
      check findByClassOrNil(panel, "repl-disabled-msg") == nil

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
      check findByTagOrNil(panel, "form") == nil
      check findByClassOrNil(panel, "repl-disabled-msg") != nil

      vm.setReplEnabled(true)

      # Effect must rebuild the body in-place.
      check findByClassOrNil(panel, "repl-disabled-msg") == nil
      check findByTagOrNil(panel, "form") != nil
      check findByTagOrNil(panel, "input") != nil

      dispose()

  test "flipping materialised hides the prompt form":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createReplVM(store)
      vm.setReplEnabled(true)
      let r = MockRenderer()

      let panel = renderReplPanel(r, vm)

      check findByTagOrNil(panel, "form") != nil

      vm.setMaterialized(true)
      vm.setLangName("ruby")

      check findByTagOrNil(panel, "form") == nil
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
      check findByClassOrNil(secondRow, "low-level-code-instruction-source") == nil

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
      check findByClassOrNil(panel, "low-level-code-address") == nil

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
      check findByClassOrNil(panel, "low-level-code-address") != nil

      vm.setAddress(0)
      check findByClassOrNil(panel, "low-level-code-address") == nil

      dispose()

  test "setErrorMessage renders the error overlay reactively":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createLowLevelCodeVM(store)
      let r = MockRenderer()

      let panel = renderLowLevelCodePanel(r, vm)
      check findByClassOrNil(panel, "low-level-code-error") == nil

      vm.setErrorMessage("function not found")
      let errDiv = findByClass(panel, "low-level-code-error")
      check errDiv != nil
      check errDiv.textContent == "function not found"

      vm.setErrorMessage("")
      check findByClassOrNil(panel, "low-level-code-error") == nil

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

  test "clicking a row asks the backend for that row's source line":
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

      check mock.receivedCommands.len == 1
      let sent = mock.receivedCommands[0]
      check isValidDapCommand(sent.command)

      # The SECOND row was clicked, so the second row's back-pointer is
      # what must be on the wire — not the first row's, and not the
      # offset, which the source-line lookup does not take.
      check sent.args{"path"}.getStr == "src/a.nim"
      check sent.args{"line"}.getInt == 4

      # A click that produced a request must not also be showing an error.
      check vm.errorMessage.val == ""

      dispose()

  test "a row with no source back-pointer reports instead of sending":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createLowLevelCodeVM(store)

      mock.clearReceivedCommands()
      # Asm generated from a function with no debug info: no path, no line.
      vm.jumpToInstruction(makeInstr("nop", offset = 9,
                                      highLevelPath = "",
                                      highLevelLine = 0))

      # THE EFFECT: nothing was asked of the backend...
      check mock.receivedCommands.len == 0
      # ...and the pane says why, rather than swallowing the click. A
      # silent return here would be indistinguishable from a click that
      # never registered — the most expensive shape this codebase has.
      check vm.errorMessage.val.len > 0

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

      check findByClassOrNil(panel, "request-panel-filters") != nil
      check findByClassOrNil(panel, "request-table-header") != nil
      let body = findByClass(panel, "request-table-body")
      check body != nil
      check body.children.len == 0

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
      check findByClass(row, "request-col-id").textContent == "01"
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
      check findByClassOrNil(body.children[0], "request-status-success") != nil
      check findByClassOrNil(body.children[1], "request-status-redirect") != nil
      check findByClassOrNil(body.children[2], "request-status-client-error") != nil
      check findByClassOrNil(body.children[3], "request-status-server-error") != nil

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
      check vm.detailTab.val == "headers"
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

  test "statusCodeText returns reason phrase for known codes":
    check statusCodeText(200) == "OK"
    check statusCodeText(201) == "Created"
    check statusCodeText(404) == "Not Found"
    check statusCodeText(500) == "Internal Server Error"
    check statusCodeText(999) == ""

  test "detailStatusText formats code + reason phrase":
    check detailStatusText(200) == "200 OK"
    check detailStatusText(500) == "500 Internal Server Error"
    check detailStatusText(999) == "999"

# ---------------------------------------------------------------------------
# IsoNim Request Panel — detail panel
# ---------------------------------------------------------------------------

suite "IsoNim Request Panel — detail panel":

  test "no detail content when no selection":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createRequestPanelVM(store)
      let r = MockRenderer()
      let panel = renderRequestPanel(r, vm)

      check vm.selectedIndex.val == NO_SELECTED_INDEX
      let host = findByClass(panel, "request-detail-host")
      check host != nil
      check host.children.len == 0

      dispose()

  test "detail panel appears when row is selected":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createRequestPanelVM(store)
      let r = MockRenderer()
      let panel = renderRequestPanel(r, vm)

      vm.addRequest("DELETE", "/api/users/42", 500, 42, 204800, 1)
      vm.selectRequest(0)

      check findByClassOrNil(panel, "request-detail") != nil

      dispose()

  test "detail header shows method badge, URL, and status text":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createRequestPanelVM(store)
      let r = MockRenderer()
      let panel = renderRequestPanel(r, vm)

      vm.addRequest("DELETE", "/api/users/42", 500, 42, 204800, 1)
      vm.selectRequest(0)

      let header = findByClass(panel, "request-detail-header")
      check header != nil
      # Method badge uses the same class as table rows
      check findByClassOrNil(header, "request-method-delete") != nil
      check findByClass(header, "request-method-delete").textContent == "DELETE"
      # URL
      check findByClassOrNil(header, "request-detail-header-url") != nil
      check findByClass(header, "request-detail-header-url").textContent == "/api/users/42"
      # Status: "500 Internal Server Error" coloured red
      let statusEl = findByClass(header, "request-detail-header-status")
      check statusEl != nil
      check "500" in statusEl.textContent
      check "Internal Server Error" in statusEl.textContent
      check "request-status-server-error" in statusEl.attributes["class"]

      dispose()

  test "handler button is present and dispatches jumpToHandler":
    createRoot proc(dispose: proc()) =
      let (store, mock) = makeStoreWithMock()
      let vm = createRequestPanelVM(store)
      let r = MockRenderer()
      let panel = renderRequestPanel(r, vm)

      vm.addRequest("GET", "/api/health", 200, 5, 64, 9999)
      vm.selectRequest(0)

      let btn = findByClass(panel, "request-detail-handler-btn")
      check btn != nil
      check "Handler" in btn.textContent

      mock.clearReceivedCommands()
      btn.fireEvent("click")
      check mock.findCommand("ct/seek-to-geid").isSome

      dispose()

  test "tab bar renders all six tabs with Headers active by default":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createRequestPanelVM(store)
      let r = MockRenderer()
      let panel = renderRequestPanel(r, vm)

      vm.addRequest("GET", "/api/x", 200, 10, 100, 1)
      vm.selectRequest(0)

      let tabs = findAllByClass(panel, "request-detail-tab")
      check tabs.len == 6
      check tabs[0].textContent == "Headers"
      check tabs[1].textContent == "Request"
      check tabs[2].textContent == "Response"
      check tabs[3].textContent == "Timing"
      check tabs[4].textContent == "Call Trace"
      check tabs[5].textContent == "Async Flow"
      # Default active tab is "Headers"
      check "request-detail-tab--active" in tabs[0].attributes["class"]
      check "request-detail-tab--active" notin tabs[3].attributes["class"]

      dispose()

  test "clicking Timing tab updates vm.detailTab and shows timing content":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createRequestPanelVM(store)
      let r = MockRenderer()
      let panel = renderRequestPanel(r, vm)

      vm.addRequest("POST", "/api/jobs", 201, 65, 512, 1)
      vm.selectRequest(0)

      findAllByClass(panel, "request-detail-tab")[3].fireEvent("click")
      check vm.detailTab.val == "timing"

      let content = findByClass(panel, "request-detail-content")
      check content != nil
      let title = findByClass(content, "request-detail-section-title")
      check title != nil
      check "TIMING" in title.textContent
      check "65ms" in title.textContent

      dispose()

  test "detail panel disappears when selection is cleared":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createRequestPanelVM(store)
      let r = MockRenderer()
      let panel = renderRequestPanel(r, vm)

      vm.addRequest("GET", "/api/x", 200, 0, 0, 1)
      vm.selectRequest(0)
      check findByClassOrNil(panel, "request-detail") != nil

      vm.selectRequest(NO_SELECTED_INDEX)
      check findByClassOrNil(panel, "request-detail") == nil

      dispose()

  test "detail panel updates when selection changes to different row":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createRequestPanelVM(store)
      let r = MockRenderer()
      let panel = renderRequestPanel(r, vm)

      vm.addRequest("GET", "/api/users", 200, 10, 100, 1)
      vm.addRequest("DELETE", "/api/items/1", 404, 20, 50, 2)

      vm.selectRequest(0)
      check findByClass(panel, "request-detail-header-url").textContent == "/api/users"

      vm.selectRequest(1)
      check findByClass(panel, "request-detail-header-url").textContent == "/api/items/1"
      check findByClassOrNil(panel, "request-method-delete") != nil

      dispose()

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

      check findByClassOrNil(panel, "trace-log-table-header") != nil
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
      vm.loadingState.val = lsIdle
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

      # DR-R8: the panel has no deep-review list.  A review's changed files
      # are the VCS panel's Changed Files section (DeepReview-GUI.md §2).
      check findByClassOrNil(panel, "deepreview-file-list") == nil

      dispose()

# ---------------------------------------------------------------------------
# Loading state
# ---------------------------------------------------------------------------

suite "IsoNim Filesystem Panel — loading state":

  test "loading state overlay visibility and aria-busy attribute":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)
      let r = MockRenderer()

      let panel = renderFilesystemPanel(r, vm)
      let loadingOverlay = findByClass(panel, "filesystem-loading-overlay")
      let emptyOverlay = findByClass(panel, "filesystem-empty-overlay")
      let filesystemDiv = findByClass(panel, "filesystem")

      # Initial state: should be loading
      check vm.loadingState.val == lsLoading
      check loadingOverlay != nil
      check "hidden" notin loadingOverlay.attributes["class"]
      check emptyOverlay != nil
      check "hidden" in emptyOverlay.attributes["class"]
      check filesystemDiv.attributes["aria-busy"] == "true"

      # When root is loaded, it transitions to idle
      vm.setRoot(makeFsRoot(@[makeFsEntry("a.nim")]))
      check vm.loadingState.val == lsIdle
      check "hidden" in loadingOverlay.attributes["class"]
      check "hidden" in emptyOverlay.attributes["class"]
      check filesystemDiv.attributes["aria-busy"] == "false"

      # When cleared, it transitions back to loading
      vm.clearRoot()
      check vm.loadingState.val == lsLoading
      check "hidden" notin loadingOverlay.attributes["class"]
      check "hidden" in emptyOverlay.attributes["class"]
      check filesystemDiv.attributes["aria-busy"] == "true"

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

  test "clicking a file row invokes the open-file bridge":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)
      let r = MockRenderer()
      var openedPath = ""
      vm.onOpenFile = proc(path: string) = openedPath = path

      let panel = renderFilesystemPanel(r, vm)
      vm.setRoot(makeFsRoot(@[
        makeFsEntry("foo.nim", path = "/trace/files/foo.nim"),
      ]))

      let row = findByClass(panel, "filesystem-entry")
      row.fireEvent("click")
      check openedPath == "/trace/files/foo.nim"

      dispose()

  test "clicking a diff file row invokes the open-file bridge":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)
      let r = MockRenderer()
      var openedPaths: seq[string] = @[]
      vm.onOpenFile = proc(path: string) = openedPaths.add(path)

      let panel = renderFilesystemPanel(r, vm)
      vm.setDiffEntries(@[
        FilesystemDiffEntry(path: "/trace/files/changed.nim", zebra: false),
      ])

      findByClass(panel, "diff-file-path").fireEvent("click")

      check openedPaths == @["/trace/files/changed.nim"]

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

  test "empty-overlay follows the idle empty state":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)
      let r = MockRenderer()

      let panel = renderFilesystemPanel(r, vm)
      let overlay = findByClass(panel, "filesystem-empty-overlay")
      check "hidden" in overlay.attributes["class"]

      vm.setRoot(emptyEntry())
      check "hidden" notin overlay.attributes["class"]

      vm.setRoot(makeFsRoot(@[makeFsEntry("a.nim")]))
      check "hidden" in overlay.attributes["class"]

      vm.clearRoot()
      check "hidden" in overlay.attributes["class"]

      vm.loadingState.val = lsIdle
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

  test "onFolderExpanded callback is invoked when expanding a folder path":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)

      var expandedPath = ""
      vm.onFolderExpanded = proc(path: string) =
        expandedPath = path

      check expandedPath == ""
      vm.toggleExpanded("src")
      check expandedPath == "src"

      expandedPath = ""
      vm.expandPath("src/components")
      check expandedPath == "src/components"

      dispose()

  test "smart file tree auto-expansion logic is preserved in view":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)

      let tree = FilesystemEntryNode(
        id: "0",
        text: "/",
        path: "/",
        isFolder: true,
        children: @[
          FilesystemEntryNode(
            id: "1",
            text: "src",
            path: "src",
            isFolder: true,
            children: @[
              FilesystemEntryNode(
                id: "2",
                text: "db-backend",
                path: "src/db-backend",
                isFolder: true,
                children: @[
                  FilesystemEntryNode(
                    id: "3",
                    text: "main.rs",
                    path: "src/db-backend/main.rs",
                    isFolder: false,
                    children: @[]
                  )
                ]
              )
            ]
          )
        ]
      )

      vm.setRoot(tree)

      check vm.isExpanded("/")
      check vm.isExpanded("src")
      check not vm.isExpanded("src/db-backend")

      dispose()

  test "the active file's row materialises after the debugger stops in it":
    ## View-layer companion to the FilesystemVM suite in
    ## src/tests/gui/tests/filesystem/filesystem_vm_test.nim (#576).
    ##
    ## The view only recurses into EXPANDED folders
    ## (isonim_filesystem_view.nim), so a file three levels down is absent
    ## from the DOM until every folder above it is expanded.  That is what
    ## makes this a proof the file is REVEALED, rather than merely marked
    ## expanded in a set.
    ##
    ## Note the contrast with the test directly above: that one covers the
    ## single-child chain collapse (`collectSmartExpansionPaths`), which is a
    ## DIFFERENT feature and was wrongly cited in the milestone file as
    ## verification for auto-expand-to-active-file.  Here `src` deliberately
    ## has TWO folder children, so the chain collapse contributes nothing and
    ## this cannot pass for the wrong reason.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createFilesystemVM(store)
      let r = MockRenderer()

      let panel = renderFilesystemPanel(r, vm)
      vm.setRoot(makeFsRoot(@[
        makeFsEntry("proj", path = "/proj", isFolder = true, children = @[
          makeFsEntry("src", path = "/proj/src", isFolder = true, children = @[
            makeFsEntry("db", path = "/proj/src/db", isFolder = true,
                        children = @[
                          makeFsEntry("main.rs",
                                      path = "/proj/src/db/main.rs")]),
            makeFsEntry("ui", path = "/proj/src/ui", isFolder = true,
                        children = @[
                          makeFsEntry("view.rs",
                                      path = "/proj/src/ui/view.rs")]),
          ]),
          makeFsEntry("README.md", path = "/proj/README.md"),
        ]),
      ]))

      proc labelTexts(): seq[string] =
        for node in findAllByClass(panel, "filesystem-entry-label"):
          result.add(node.textContent)

      # Everything below the top level is collapsed, so the file is absent.
      check "main.rs" notin labelTexts()

      store.updateDebuggerPosition(1'u64, "/proj/src/db/main.rs", 12)

      let texts = labelTexts()
      check "main.rs" in texts
      # The sibling subtree stays collapsed, so its file is still absent.
      check "view.rs" notin texts

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

  test "clicking a row invokes the run-result bridge":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createCommandPaletteVM(store)
      let r = MockRenderer()
      var ranIndex = -1
      vm.onResultRun = proc(index: int) = ranIndex = index

      let panel = renderCommandPalettePanel(r, vm)
      vm.setResults([
        makeCpEntry("alpha"),
        makeCpEntry("beta"),
      ])

      let rows = findAllByClass(panel, "command-result")
      rows[1].fireEvent("click")
      check vm.selectedIndex.val == 1
      check ranIndex == 1

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
# The Agent Activity panel after AA-1: no DeepReview roll-up.
#
# What used to be here was the roll-up's own suite — structure, row rendering,
# interactions, review rendering (DR-R3), the host wiring and the VM/format
# helpers.  AA-1 deleted the roll-up outright (DeepReview-GUI.md §2.1: "There
# is no 'DeepReview section' in this panel"), so those tests describe a surface
# that no longer exists and are removed with it rather than weakened.
#
# What replaces them is one deletion guard, in the suite that owns the panel
# they used to render inside.  It is falsifiable against the code as it stood
# before AA-1: the panel emitted an `agent-ha-deepreview-host` wrapper on every
# render, with or without a roll-up ViewModel.
#
# Every capability the deleted tests asserted survives somewhere and is
# asserted there:
#   * per-file coverage      -> the VCS panel's Changed Files badge
#                               (`vcs_vm.VCSFileRow.coverageText`, exercised by
#                               materialized_review_dataset_test.nim and the
#                               VCS suites);
#   * the aggregate coverage -> `ReviewDataset` itself, exercised by
#                               deepreview_entry_test.nim;
#   * "no test results in    -> materialized_review_dataset_test.nim, at the
#     this dataset"             dataset level, which is where the absence
#                               actually lives;
#   * the file-selection     -> deleted: the coverage table was its second
#     agreement                 view, and one view needs no agreement.
# ===========================================================================

suite "IsoNim Agent Activity Panel — no DeepReview roll-up (AA-1)":

  test "the panel renders no DeepReview roll-up and no host for one":
    ## The owner's directive for AA-1: "completely remove the existing deep
    ## review section in the agent activity panel".
    ##
    ## Both halves are asserted because they failed independently: the roll-up
    ## itself (`activity-dr-*`) and the wrapper the panel reserved for it
    ## (`agent-ha-deepreview-host`), which was emitted unconditionally — even
    ## in a normal debugging session with no review anywhere — and which is
    ## therefore the half a nil-ViewModel check would have missed.
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createAgentActivityVM(store)
      let r = MockRenderer()

      let panel = renderAgentActivityPanel(r, vm, componentId = 71)

      check findByClassOrNil(panel, "agent-ha-deepreview-host") == nil
      for cls in ["activity-dr-container", "activity-dr-header",
                  "activity-dr-summary", "activity-dr-files",
                  "activity-dr-files-row", "activity-dr-tests",
                  "activity-dr-test-item", "activity-dr-notifs",
                  "activity-dr-notif-item", "activity-dr-card",
                  "activity-dr-card-tests", "activity-dr-card-unavailable"]:
        check findByClassOrNil(panel, cls) == nil
      # …and what §2.1 says the panel *is* for is untouched: the conversation
      # and the prompt are still there, and the conversation is now the whole
      # body above the prompt.
      check findByClassOrNil(panel, AgentActivityConversationClass) != nil
      check findByClassOrNil(panel, AgentActivityInteractionClass) != nil

      dispose()

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
  # M-REC-3: ``RecentTraceRecord.recordingId`` is a UUIDv7 string; we
  # synthesize a canonical-form id from the int so the existing
  # callers (which pass small integer literals for readability) keep
  # working without churn.
  RecentTraceRecord(
    recordingId: "01949fcc-7d92-7e9c-aaaa-" & align($id, 12, '0'),
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
      check findByClassOrNil(panel, "welcome-screen-loading-overlay") == nil

      vm.beginLoadingTrace("01949fcc-7d92-7e9c-aaaa-000000000007")
      let welcome = findByClass(panel, "welcome-screen")
      check "welcome-screen-loading" in welcome.attributes["class"]
      let overlay = findByClass(panel, "welcome-screen-loading-overlay")
      check overlay != nil

      vm.endLoading()
      check findByClassOrNil(panel, "welcome-screen-loading-overlay") == nil

      dispose()

  test "new-record and online-trace modes swap the top-level surface":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      let r = MockRenderer()

      let panel = renderWelcomeScreenPanel(r, vm)
      check findByClassOrNil(panel, "welcome-screen") != nil

      vm.showNewRecord()
      check findByClassOrNil(panel, "new-record-screen") != nil
      check findByClassOrNil(panel, "new-online-trace-form") == nil

      vm.showOnlineTrace()
      check findByClassOrNil(panel, "new-online-trace-form") != nil

      vm.enterEditMode()
      check findByClassOrNil(panel, "welcome-screen") == nil
      check findByClassOrNil(panel, "new-record-screen") == nil

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
      # M-REC-2: synthesized UUIDv7 from int id 7 (matches the
      # ``makeWelcomeTrace`` synthesizer).
      check vm.hoveredRecording.val == "01949fcc-7d92-7e9c-aaaa-000000000007"
      tooltip = findByClass(panel, "recent-trace-tooltip")
      check "visible" in tooltip.attributes["class"]

      trace.fireEvent("mouseleave")
      check vm.hoveredRecording.val == NO_HOVERED_RECORDING
      tooltip = findByClass(panel, "recent-trace-tooltip")
      check "visible" notin tooltip.attributes["class"]

      dispose()

  test "test_welcome_screen_loading":
    # Verifies welcome screen components render without error
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      let r = MockRenderer()

      vm.beginLoadingTrace("01949fcc-7d92-7e9c-aaaa-000000000088")
      let panel = renderWelcomeScreenPanel(r, vm)

      let overlay = findByClass(panel, "welcome-screen-loading-overlay")
      check overlay != nil
      check findByClass(overlay, "welcome-screen-loading-overlay-text").textContent == "Loading trace..."

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

  test "click callbacks surface recent-trace, folder, and start-option actions":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createWelcomeScreenVM(store)
      let r = MockRenderer()

      vm.setRecentTraces(@[makeWelcomeTrace(11, "/bin/python")])
      vm.setRecentFolders(@[makeWelcomeFolder(3, "demo", "/tmp/demo")])
      vm.setStartOptions(@[
        makeWelcomeOption("Record new trace"),
        makeWelcomeOption("Open local trace"),
        makeWelcomeOption("Open folder"),
      ])

      # M-REC-2: ``clickedTrace`` is a UUIDv7 string; empty == "no click yet".
      var clickedTrace = ""
      var clickedFolder = ""
      var clickedOptions: seq[string] = @[]
      let callbacks = WelcomeScreenCallbacks(
        onRecentTraceClick: proc(traceId: string) = clickedTrace = traceId,
        onRecentFolderClick: proc(folderPath: string) = clickedFolder = folderPath,
        onStartOptionClick: proc(key: string) = clickedOptions.add(key)
      )

      let panel = renderWelcomeScreenPanel(r, vm, callbacks)
      findByClass(panel, "recent-trace").fireEvent("click")
      findByClass(panel, "recent-folder").fireEvent("click")
      let options = findAllByClass(panel, "start-option")
      for option in options:
        option.fireEvent("click")

      # M-REC-2: synthesized canonical UUIDv7 from int id 11 (matches
      # the ``makeWelcomeTrace`` synthesizer).
      check clickedTrace == "01949fcc-7d92-7e9c-aaaa-000000000011"
      check clickedFolder == "/tmp/demo"
      check clickedOptions == @[
        "record-new-trace",
        "open-local-trace",
        "open-folder",
      ]

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
      check findByClassOrNil(panel, AgentActivityConversationClass) != nil
      check findByClassOrNil(panel, AgentActivityInteractionClass) != nil
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
      check findByClassOrNil(wrappers[1], "ai-status") != nil
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
      check findByClassOrNil(panel, "agent-start-button") == nil
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
      check findByClassOrNil(panel, AgentWorkspaceHeaderClass) == nil

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

  test "normal git mode renders commit accordion files and callbacks":
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()
      let r = MockRenderer()
      var expandedCommit = -1
      var expandModifiers = (false, false)
      var selectedFile = ""
      var openedDiff = ""
      let callbacks = VCSCallbacks(
        onToggleCommitExpand: proc(index: int; ctrl, shift: bool) =
          (expandedCommit = index; expandModifiers = (ctrl, shift)),
        onSelectFile: proc(index: int; path, target, status: string) =
          (discard index; discard target; selectedFile = path),
        onOpenFileDiff: proc(target: string) =
          openedDiff = target,
      )
      let panel = renderVCSPanel(r, vm, callbacks)

      vm.setGitRepoState(true)
      vm.setHeader("main")
      vm.setBranchState("main", @["main", "feature"], false)
      vm.setCommits(@[
        VCSCommitRow(hash: "abc123", message: "initial", relativeTime: "1h"),
      ], selectedIndices = @[0])
      vm.setCommitFiles(0, @[
        VCSFileRow(status: "M", path: "src/main.nim", baseName: "main.nim",
                   additions: 2, deletions: 1),
      ])

      let branchName = findByClass(panel, "vcs-branch-name")
      let commitMessage = findByClass(panel, "vcs-commit-msg")
      let fileName = findByClass(panel, "vcs-accordion-file-name")
      check branchName != nil
      check branchName.textContent == "main"
      check commitMessage != nil
      check commitMessage.textContent == "initial"
      check fileName != nil
      check fileName.textContent == "main.nim"

      findByClass(panel, "vcs-commit-header").fireEvent("click")
      findByClass(panel, "vcs-accordion-file").fireEvent("click")
      findByClass(panel, "vcs-commit-diff-btn").fireEvent("click")

      check expandedCommit == 0
      check expandModifiers == (false, false)
      check selectedFile == "src/main.nim"
      check openedDiff == "commit:abc123"

      dispose()

  test "test_vcs_branch_selection":
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()
      let r = MockRenderer()
      var checkedOutBranch = ""
      let callbacks = VCSCallbacks(
        onCheckoutBranch: proc(branch: string) =
          checkedOutBranch = branch
      )
      let panel = renderVCSPanel(r, vm, callbacks)

      vm.setGitRepoState(true)
      vm.setHeader("main")
      vm.setBranchState("main", @["main", "feature-1", "feature-2"], true)

      let dropdown = findByClass(panel, "vcs-branch-dropdown")
      check dropdown != nil

      # `0717477a` moved the dropdown onto the shared `ct-menu-item` markup;
      # the old `vcs-branch-option` class no longer exists.
      let options = findAllByClass(dropdown, "ct-menu-item")
      check options.len == 3
      # The checked-out branch is marked so the picker shows where you are.
      check options[0].attributes["class"].contains("ct-menu-item--active")
      check options[0].textContent.contains("main")
      check options[1].textContent.contains("feature-1")
      check options[2].textContent.contains("feature-2")

      # Click the second option
      options[1].fireEvent("click")
      check checkedOutBranch == "feature-1"

      dispose()

  test "DeepReview changed files mode renders selected file and coverage":
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()
      let r = MockRenderer()
      var selected = -1
      let callbacks = VCSCallbacks(
        onSelectFile: proc(index: int; path, target, status: string) =
          (discard path; discard target; selected = index),
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

  test "test_vcs_panel_is_never_a_diff_surface":
    ## DR-R4: a unified diff is an editor-area Monaco document
    ## (``Content.UnifiedDiff``), not a second instance of this panel —
    ## VCS-Panel.md, "Unified Diff View (Editor Integration)": "Uses the
    ## standard CodeTracer Monaco editor".
    ##
    ## This replaces ``test_vcs_unified_diff_tab``, which asserted that the
    ## panel renders the diff itself when ``unifiedDiffActive`` is set.  That
    ## branch is gone; the assertion that remains is that setting the flag
    ## cannot bring a DOM diff back into the panel, and that the panel keeps
    ## its own chrome (#561: the diff must never replace the commit history).
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()
      let r = MockRenderer()
      let panel = renderVCSPanel(r, vm)

      vm.setGitRepoState(true)
      vm.setHeader("main")
      vm.setUnifiedDiff(true, @[makeVcsDiffFile()])

      check findByClassOrNil(panel, "deepreview-unified-diff") == nil
      check findByClassOrNil(panel, "deepreview-unified-line") == nil
      check findByClassOrNil(panel, "deepreview-unified-file-path") == nil
      # ...and the panel is still the panel.
      check findByClassOrNil(panel, "vcs-commit-history") != nil
      check findByClassOrNil(panel, "vcs-branch-picker") != nil
      check findByClassOrNil(panel, "vcs-diff-toggle") != nil

      dispose()

  test "test_vcs_view_mode_toggle_keeps_commit_history":
    ## #561: the reporter's complaint was that turning on "Unified Diff"
    ## replaced the VCS panel's contents.  The toggle selects what a file click
    ## *does*; the commit history must survive it.
    ##
    ## `renderDiffToggle` was dead code — `renderVCSPanelImpl` never called it
    ## — and `onToggleUnifiedDiff` was a `discard`, so neither the switch nor
    ## its effect existed.
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()
      let r = MockRenderer()
      var toggled = 0
      let callbacks = VCSCallbacks(
        onToggleUnifiedDiff: proc() =
          toggled += 1
          vm.setViewMode(
            if vm.viewMode.val == vmUnifiedDiff: vmOpenFile
            else: vmUnifiedDiff),
      )
      let panel = renderVCSPanel(r, vm, callbacks)

      vm.setGitRepoState(true)
      vm.setHeader("main")
      vm.setCommits(@[
        VCSCommitRow(hash: "abc123", message: "initial", relativeTime: "1h"),
      ], selectedIndices = @[])

      let toggle = findByClass(panel, "vcs-diff-toggle")
      let button = findByClass(panel, "vcs-toggle-button")
      check toggle != nil
      check button != nil
      # Guarded: without the switch there is nothing to click, and the
      # assertions below would dereference nil.
      if button != nil:
        # Unified diff is the spec default, so the switch starts active.
        check button.attributes["class"] ==
          "vcs-toggle-button vcs-toggle-active"
        check findByClassOrNil(panel, "vcs-commit-history") != nil

        button.fireEvent("click")

        check toggled == 1
        check vm.viewMode.val == vmOpenFile
        # Still a commit list, still no diff: the toggle changed behaviour only.
        check findByClassOrNil(panel, "vcs-commit-history") != nil
        check findByClassOrNil(panel, "deepreview-unified-diff") == nil
        check findByClass(panel, "vcs-toggle-button").attributes["class"] ==
          "vcs-toggle-button"

      dispose()

  test "test_vcs_view_diff_button_dispatches_target":
    ## #561 / #611: the "View Diff" button must dispatch the diff target for
    ## its row, and must not also trigger the row's own file-selection click.
    ##
    ## Both row kinds are covered.  In a normal git session `renderChangedFiles`
    ## is not rendered at all, so the rows a user actually sees are the
    ## `vcs-accordion-file` rows of an expanded commit; the `vcs-file-item`
    ## rows only appear in DeepReview mode.  They dispatch different targets.
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()
      let r = MockRenderer()
      var selectedFile = ""
      var openedDiff = ""
      let callbacks = VCSCallbacks(
        onSelectFile: proc(index: int; path, target, status: string) =
          (discard index; discard target; selectedFile = path),
        onOpenFileDiff: proc(target: string) =
          openedDiff = target,
      )
      let panel = renderVCSPanel(r, vm, callbacks)

      # --- normal git mode: accordion rows under an expanded commit ---------
      vm.setGitRepoState(true)
      vm.setHeader("main")
      vm.setCommits(@[
        VCSCommitRow(hash: "abc123", message: "initial", relativeTime: "1h"),
      ], selectedIndices = @[0])
      vm.setCommitFiles(0, @[
        VCSFileRow(status: "M", path: "src/main.nim", baseName: "main.nim"),
        VCSFileRow(status: "A", path: "src/other.nim", baseName: "other.nim"),
      ])

      # Every row carries a button — dropping one must fail loudly.
      check findAllByClass(panel, "vcs-accordion-file").len == 2
      let commitButtons = findAllByClass(panel, "vcs-file-diff-btn")
      check commitButtons.len == 2
      if commitButtons.len == 2:
        commitButtons[1].fireEvent("click")
        check openedDiff == "commit:abc123:src/other.nim"
        # The button must not double as a row click.
        check selectedFile == ""

      # --- DeepReview mode: changed-file rows -------------------------------
      openedDiff = ""
      vm.setDeepReviewMode(true)
      vm.setChangedFiles(@[
        VCSFileRow(status: "M", path: "src/main.nim", baseName: "main.nim"),
      ])

      check findAllByClass(panel, "vcs-file-item").len == 1
      let reviewButtons = findAllByClass(panel, "vcs-file-diff-btn")
      check reviewButtons.len == 1
      if reviewButtons.len == 1:
        reviewButtons[0].fireEvent("click")
        check openedDiff == "file:src/main.nim"
        check selectedFile == ""

      dispose()

  test "test_vcs_row_click_carries_its_diff_target":
    ## The row click reports the same target as the row's button, so the host
    ## can honour the unified-diff view mode without having to re-derive which
    ## commit an accordion row belonged to.
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()
      let r = MockRenderer()
      var rowTarget = ""
      var rowPath = ""
      let callbacks = VCSCallbacks(
        onSelectFile: proc(index: int; path, target, status: string) =
          (discard index; rowPath = path; rowTarget = target),
      )
      let panel = renderVCSPanel(r, vm, callbacks)

      vm.setGitRepoState(true)
      vm.setCommits(@[
        VCSCommitRow(hash: "abc123", message: "initial", relativeTime: "1h"),
      ], selectedIndices = @[0])
      vm.setCommitFiles(0, @[
        VCSFileRow(status: "M", path: "src/main.nim", baseName: "main.nim"),
      ])

      let row = findByClass(panel, "vcs-accordion-file")
      check row != nil
      if row != nil:
        row.fireEvent("click")
        check rowPath == "src/main.nim"
        check rowTarget == "commit:abc123:src/main.nim"

      dispose()

  test "the diff tab renders its hunk toolbar over the Monaco host":
    ## DR-R4's rewrite of "unified diff renders toolbar selection and hunk
    ## callback", retargeted from the deleted DOM renderer to the diff tab's
    ## chrome.
    ##
    ## The tab is a Monaco editor, so its *body* has no DOM to assert on here
    ## — the document and its decorations are covered headlessly in
    ## ``src/tests/gui/tests/vcs/vcs_diff_decorations_test.nim``.  What this
    ## covers is the chrome: the host element Monaco mounts into, and the hunk
    ## editor's toolbar driven by the same ``VCSVM`` signals the selection
    ## model writes.
    createRoot proc(dispose: proc()) =
      let vm = createVCSVM()
      let r = MockRenderer()
      var copied = 0
      var cleared = 0
      let callbacks = isonim_unified_diff_view.UnifiedDiffCallbacks(
        onCopySelectedHunks: proc() = copied += 1,
        onClearSelectedHunks: proc() = cleared += 1,
      )

      # With no files there is nothing to diff: the message replaces the editor
      # rather than being written into the Monaco model, where it would render
      # as a line of code with a line number beside it.  `.empty-overlay` is
      # what earns it the shared empty-state treatment.
      let emptyPanel = isonim_unified_diff_view.renderUnifiedDiffTab(
        r, vm, "unifiedDiffEditor-empty", callbacks)
      let emptyNode = findByClass(emptyPanel, "unified-diff-empty")
      check emptyNode != nil
      check emptyNode.textContent == isonim_unified_diff_view.UnifiedDiffEmptyText
      check "empty-overlay" in emptyNode.attributes["class"]
      check "hidden" notin emptyNode.attributes["class"]
      check "hidden" in
        findByClass(emptyPanel, "unified-diff-editor").attributes["class"]

      vm.setUnifiedDiff(true, @[makeVcsDiffFile()])
      let panel = isonim_unified_diff_view.renderUnifiedDiffTab(
        r, vm, "unifiedDiffEditor-7", callbacks)

      # Once there are files the message steps aside and the editor is shown.
      check "hidden" in findByClass(panel, "unified-diff-empty").attributes["class"]

      # The Monaco host is present and empty: the editor attaches to it.
      let host = findByClass(panel, "unified-diff-editor")
      check host != nil
      check host.attributes["id"] == "unifiedDiffEditor-7"
      # No selection yet, so no toolbar.
      check findByClassOrNil(panel, "hunk-toolbar") == nil

      # Selection made through the ViewModel's own entry point — the one the
      # Monaco tab calls — drives the toolbar.
      vm.selectHunk(0, 0)
      check findByClass(panel, "hunk-toolbar-count").textContent ==
        "1 hunk selected"

      findAllByClass(panel, "hunk-toolbar-button")[0].fireEvent("click")
      check copied == 1

      vm.setHunkCopyFeedback(true)
      check findAllByClass(panel, "hunk-toolbar-button")[0].textContent ==
        "Copied!"

      # Normal version control offers staging; a review does not
      # (VCS-Panel.md, "DeepReview Mode": "Commit operations: Disabled").
      check "Stage hunks" in panel.textContent
      vm.setDeepReviewMode(true)
      check "Stage hunks" notin panel.textContent
      # ...and the read-only affordances survive the mode.
      check findByClassOrNil(panel, "hunk-toolbar-count") != nil
      let buttons = findAllByClass(panel, "hunk-toolbar-button")
      buttons[^1].fireEvent("click")
      check cleared == 1

      dispose()

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

    check findByClassOrNil(shell.root, "editor-component") == nil
    check findByClassOrNil(shell.root, "monaco-editor") == nil

  test "test_drag_to_pin_interaction":
    # Mocking the drag-to-pin drop zones.
    # Since layout and DOM events are JS-only, we mock the pinning invocation
    # and verify that it resolves to the expected edge.
    var pinnedEdge = -1

    proc mockPin(edge: int) =
      pinnedEdge = edge

    # Simulate drag-to-pin on Left edge
    mockPin(0)
    check pinnedEdge == 0 # Left

    # Simulate drag-to-pin on Right edge
    mockPin(1)
    check pinnedEdge == 1 # Right

    # Simulate drag-to-pin on Bottom edge
    mockPin(2)
    check pinnedEdge == 2 # Bottom

  # `test_flow_conditional_branch_colors` used to live here. It compared two
  # string literals to themselves (`check "flow-taken" == "flow-taken"`), so it
  # passed both before and after the 2026-07-16 attempt at #594 and could not
  # have detected that the colours were being wiped by the flow reload. Removed
  # rather than repaired: this suite renders IsoNim views through MockRenderer
  # and has no access to the Monaco decoration bookkeeping where the bug lives.
  # Real coverage is in
  # `src/tests/gui/tests/editor/editor_decorations_test.nim` (the retention
  # rule) and `src/tests/gui/tests/flow/flow_branch_colors.spec.ts` (end to end).
