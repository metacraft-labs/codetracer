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
import ../views/isonim_state_view
import ../views/isonim_calltrace_view
import ../views/isonim_debug_controls_view

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

      let rows = findAllByClass(container, "variable-row")
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

      # Initially no variables
      let container = findByClass(panel, "value-components-container")
      check container.children.len == 0

      # Add variables
      store.updateLocals(@[
        makeVariable("count", "7", "int"),
      ])

      check container.children.len == 1
      check "count" in container.children[0].textContent
      check "7" in container.children[0].textContent

      # Update variables
      store.updateLocals(@[
        makeVariable("count", "8", "int"),
        makeVariable("name", "\"world\"", "string"),
      ])

      check container.children.len == 2
      check "8" in container.children[0].textContent
      check "name" in container.children[1].textContent

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
      check container.children.len == 1
      check "localVar" in container.children[0].textContent

      # Switch to globals
      vm.selectTab(stGlobals)

      check container.children.len == 1
      check "globalVar" in container.children[0].textContent

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
      check container.children.len == 1

      # Expand
      vm.toggleExpand("obj")

      # Now should show parent + 2 children = 3 rows
      check container.children.len == 3
      check "obj" in container.children[0].textContent
      check "field1" in container.children[1].textContent
      check "field2" in container.children[2].textContent

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
