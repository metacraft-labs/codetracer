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
# Mirrors the legacy Karax ``callArgsView`` markup
# (``frontend/ui/calltrace.nim`` ~line 464).

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
