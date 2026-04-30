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

import std/[unittest, asyncdispatch, strutils, tables, options, sets]
import isonim/core/[signals, owner]
import isonim/testing/mock_dom
import ../backend/backend_service
import ../backend/mock_backend
import ../store/types
import ../store/replay_data_store
import ../viewmodels/state_vm
import ../viewmodels/calltrace_vm
import ../viewmodels/debug_controls_vm
import ../viewmodels/event_log_vm
import ../viewmodels/flow_vm
import ../viewmodels/timeline_vm
import ../viewmodels/search_vm
import ../viewmodels/point_list_vm
import ../viewmodels/scratchpad_vm
import ../viewmodels/shell_vm
import ../views/isonim_state_view
import ../views/isonim_calltrace_view
import ../views/isonim_debug_controls_view
import ../views/isonim_event_log_view
import ../views/isonim_flow_view
import ../views/isonim_timeline_view
import ../views/isonim_search_view
import ../views/isonim_point_list_view
import ../views/isonim_scratchpad_view
import ../views/isonim_shell_view

# ---------------------------------------------------------------------------
# Test helpers
# ---------------------------------------------------------------------------

proc drain() =
  ## Drain the async event loop so that all synchronously-completed
  ## futures fire their callbacks.
  try:
    poll(0)
  except ValueError:
    discard

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
      check panel.attributes["class"] == "state-component"

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

# ===========================================================================
# Calltrace panel tests
# ===========================================================================

# ---------------------------------------------------------------------------
# Calltrace helpers
# ---------------------------------------------------------------------------

proc makeTestCallLine(index: int64; name: string; depth: int = 0;
                      rrTicks: uint64 = 100; file: string = "test.nim";
                      line: int = 1): CallLine =
  CallLine(
    index: index,
    name: name,
    depth: depth,
    rrTicks: rrTicks,
    location: Location(file: file, line: line),
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

      let rows = findAllByClass(container, "call-line")
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
      let rows = findAllByClass(container, "call-line")
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
      let rows = findAllByClass(container, "call-line")

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
      let rows = findAllByClass(container, "call-line")

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
      let rows = findAllByClass(container, "call-line")

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
# Scratchpad panel tests
# ===========================================================================

# ---------------------------------------------------------------------------
# Scratchpad structure tests
# ---------------------------------------------------------------------------

suite "IsoNim Scratchpad Panel — structure":

  test "renders root with scratchpad-component class":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)
      let r = MockRenderer()

      let panel = renderScratchpadPanel(r, vm)

      check panel.kind == mnkElement
      check panel.tag == "div"
      check panel.attributes["class"] == "scratchpad-component"

      dispose()

  test "renders header with title":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)
      let r = MockRenderer()

      let panel = renderScratchpadPanel(r, vm)

      let title = findByClass(panel, "scratchpad-title")
      check title != nil
      check title.textContent == "Scratchpad"

      dispose()

  test "renders items container":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)
      let r = MockRenderer()

      let panel = renderScratchpadPanel(r, vm)

      let container = findByClass(panel, "scratchpad-items")
      check container != nil

      dispose()

  test "renders comparison toggle button":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)
      let r = MockRenderer()

      let panel = renderScratchpadPanel(r, vm)

      let toggleBtn = findByClass(panel, "comparison-toggle")
      check toggleBtn != nil
      check toggleBtn.textContent == "Compare"

      dispose()

# ---------------------------------------------------------------------------
# Scratchpad interaction tests
# ---------------------------------------------------------------------------

suite "IsoNim Scratchpad Panel — interactions":

  test "comparison toggle changes text":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)
      let r = MockRenderer()

      let panel = renderScratchpadPanel(r, vm)

      let toggleBtn = findByClass(panel, "comparison-toggle")
      check toggleBtn.textContent == "Compare"

      toggleBtn.fireEvent("click")

      check vm.comparisonMode.val == true
      check toggleBtn.textContent == "Exit Compare"
      check "active" in toggleBtn.attributes["class"]

      dispose()

  test "selected item indicator updates":
    createRoot proc(dispose: proc()) =
      let (store, _) = makeStoreWithMock()
      let vm = createScratchpadVM(store)
      let r = MockRenderer()

      let panel = renderScratchpadPanel(r, vm)

      let indicator = findByClass(panel, "scratchpad-selected-indicator")
      check indicator.textContent == ""

      vm.selectItem(some(2))

      check "2" in indicator.textContent
      check "active" in indicator.attributes["class"]

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
      check prompt.textContent == "> "

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

      dispose()
