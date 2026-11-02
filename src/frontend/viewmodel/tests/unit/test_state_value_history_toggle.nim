## Headless ViewModel/View tests for the State panel's inline value history
## (issue #558).
##
## No mocks beyond the shared `MockBackendService` / `MockRenderer` test
## doubles the ViewModel testing architecture mandates (see
## `codetracer-specs/Testing/ViewModel-Testing-Architecture.md`): the real
## `StateVM`, the real `state_view` projection and the real IsoNim view are
## exercised. `MockBackendService` stands in for the DAP transport only;
## `MockRenderer` is IsoNim's renderer-agnostic DOM used so the same view code
## the browser runs can be walked natively.
##
## IMPORTANT — why every assertion here targets ONE panel instance:
##
## The regression these tests exist for is that the history rows were emitted
## by a plain `for` loop inside the view's `ui()` block. The IsoNim DSL expands
## such a loop as a ONE-SHOT structural construct, so it runs once at row
## construction and never again. A test that re-renders the panel after
## populating the data cannot see that: on a fresh build the loop runs *after*
## the data is in place and the rows appear. The live app mounts a single
## long-lived panel and updates it incrementally, which is what these tests
## reproduce — render once, mutate the VM, assert on the SAME node tree.
## Never re-render to observe an update in this file.

import std/[sets, tables, unittest, strutils, json, options]

import isonim/core/async_compat
import isonim/core/signals
import isonim/core/owner
import isonim/testing/mock_dom

import ../../store/types as store_types
import ../../viewmodels/state_vm
import ../../views/isonim_state_view

import ../../backend/mock_backend
import ../../store/replay_data_store

proc drain() =
  ## Flush whatever the reactive layer resolved synchronously.
  ##
  ## `drainPlatformCallbacks` rather than `asyncdispatch.poll(0)`: `poll` is
  ## only reachable through `std/asyncdispatch`, which drags in
  ## `std/nativesockets` and fails the JS compile outright
  ## (`undeclared identifier: 'cstringArrayToSeq'`). This helper is the
  ## cross-target primitive — a `poll(0)` on native, the pending-callback
  ## flush on JS — so the suite runs on both backends, which is what
  ## Front-End-Architecture.md §6 asks for and what the `vm-unit-js` lane
  ## exists to enforce.
  drainPlatformCallbacks()

proc findById*(node: MockNode; id: string): MockNode =
  if node.kind == mnkElement and node.attributes.getOrDefault("id", "") == id:
    return node
  for child in node.children:
    let found = findById(child, id)
    if found != nil:
      return found
  return nil

proc findByClass*(node: MockNode; className: string): MockNode =
  if node.kind == mnkElement and className in node.attributes.getOrDefault("class", ""):
    return node
  for child in node.children:
    let found = findByClass(child, className)
    if found != nil:
      return found
  return nil

proc findAllByClass*(node: MockNode; className: string; result: var seq[MockNode]) =
  if node.kind == mnkElement and className in node.attributes.getOrDefault("class", ""):
    result.add(node)
  for child in node.children:
    findAllByClass(child, className, result)

proc findAllByClass*(node: MockNode; className: string): seq[MockNode] =
  result = @[]
  findAllByClass(node, className, result)

proc findRowByName*(node: MockNode; name: string): MockNode =
  ## Locate a variable row by its `data-variable-name` attribute. Used
  ## instead of `findByClass` whenever more than one row is on screen, so
  ## an assertion cannot accidentally read the wrong row's sub-tree.
  if node.kind == mnkElement and
      node.attributes.getOrDefault("data-variable-name", "") == name:
    return node
  for child in node.children:
    let found = findRowByName(child, name)
    if found != nil:
      return found
  return nil

proc historyRowsOf(row: MockNode): seq[MockNode] =
  findAllByClass(row, "ct-history-inline-row")

proc historyDisplayOf(row: MockNode): string =
  let container = findByClass(row, "ct-history-inline-container")
  if container.isNil: "<missing>"
  else: container.styles.getOrDefault("display", "")

proc sampleHistory(): seq[ValueHistoryRow] =
  @[
    ValueHistoryRow(locationTicks: 100, valueText: "10"),
    ValueHistoryRow(locationTicks: 110, valueText: "42"),
  ]

suite "State component value history toggle":
  test "test_state_value_history_toggle: history arriving after expand renders into the mounted panel":
    createRoot proc(dispose: proc()) =
      let backend = newMockBackendService().toBackendService()
      let store = createReplayDataStore(backend)
      let vm = createStateVM(store)
      let r = MockRenderer()

      var toggled: seq[string] = @[]
      vm.onToggleHistory = proc(expression: string) =
        toggled.add(expression)

      store.locals.locals.val = @[
        store_types.Variable(name: "x", value: "42", typeName: "int",
                             hasChildren: false, children: @[])
      ]
      drain()

      # Mount the panel ONCE. Everything below asserts on this tree.
      let panel = renderStatePanel[MockRenderer, MockNode](r, vm)
      let button = findByClass(panel, "value-history-button")
      check button != nil

      # Collapsed: the container exists but is hidden and empty.
      check historyDisplayOf(panel) == "none"
      check historyRowsOf(panel).len == 0

      # 1. Click the history toggle button — this is what emits the
      #    `ct/load-history` request in the real app.
      button.fireEvent("click")
      drain()
      check toggled == @["x"]
      check "x" in vm.expandedHistories.val

      # The container becomes visible immediately, but no rows exist yet
      # because the response has not arrived.
      check historyDisplayOf(panel) == "block"
      check historyRowsOf(panel).len == 0

      # 2. The `CtUpdatedHistory` response arrives. This is the step the
      #    old test could not observe: it must repopulate the ALREADY
      #    MOUNTED container, with no re-render.
      vm.updateHistory("x", sampleHistory())
      drain()

      let historyRows = historyRowsOf(panel)
      check historyRows.len == 2
      if historyRows.len == 2:
        check "100" in historyRows[0].textContent
        check "10" in historyRows[0].textContent
        check "110" in historyRows[1].textContent
        check "42" in historyRows[1].textContent

      # 3. The row's right-click menu offers the same toggle.
      let row = findRowByName(panel, "x")
      check row != nil
      check "contextmenu" in row.eventListeners or
            "contextmenu" in row.eventHandlers

      row.fireEvent("contextmenu")
      let menu = vm.lastContextMenu.val
      check menu.len >= 1
      var toggleHistoryEntry: OriginContextMenuEntry
      var foundToggle = false
      for entry in menu:
        if entry.label == "Toggle value history":
          toggleHistoryEntry = entry
          foundToggle = true
      check foundToggle
      check not toggleHistoryEntry.action.isNil

      # 4. Collapsing must both hide the container AND drop the rows from
      #    the mounted tree — again without a re-render.
      toggleHistoryEntry.action()
      drain()
      check "x" notin vm.expandedHistories.val
      check historyDisplayOf(panel) == "none"
      check historyRowsOf(panel).len == 0

      # 5. Re-expanding must bring the cached rows straight back. The VM
      #    already holds the history, so `onToggleHistory` must NOT fire a
      #    second request.
      button.fireEvent("click")
      drain()
      check toggled == @["x"]
      check historyDisplayOf(panel) == "block"
      check historyRowsOf(panel).len == 2

      dispose()

  test "test_state_value_history_response_before_expand: rows render when the response precedes the toggle":
    ## Ordering guard. The backend may answer a history request issued for
    ## an earlier step (or a replayed session may prime the cache) before
    ## the user expands the row. The rows must still appear on expansion.
    createRoot proc(dispose: proc()) =
      let backend = newMockBackendService().toBackendService()
      let store = createReplayDataStore(backend)
      let vm = createStateVM(store)
      let r = MockRenderer()

      var toggled: seq[string] = @[]
      vm.onToggleHistory = proc(expression: string) =
        toggled.add(expression)

      store.locals.locals.val = @[
        store_types.Variable(name: "x", value: "42", typeName: "int",
                             hasChildren: false, children: @[])
      ]
      drain()

      let panel = renderStatePanel[MockRenderer, MockNode](r, vm)

      # Response first, expansion second.
      vm.updateHistory("x", sampleHistory())
      drain()
      # Still collapsed: nothing rendered, nothing requested.
      check historyDisplayOf(panel) == "none"
      check historyRowsOf(panel).len == 0

      let button = findByClass(panel, "value-history-button")
      check button != nil
      button.fireEvent("click")
      drain()

      check historyDisplayOf(panel) == "block"
      let rows = historyRowsOf(panel)
      check rows.len == 2
      if rows.len == 2:
        check "100" in rows[0].textContent
        check "42" in rows[1].textContent
      # The VM already had the history, so no redundant backend request.
      check toggled.len == 0

      dispose()

  test "test_state_value_history_nested_path_key: history is keyed by the dot-separated variable path":
    ## Locks the request/response key agreement for child rows: the button
    ## must request `obj.field` (the row's `path`, not its leaf `name`) and
    ## a response stored under that same key must render under that row —
    ## and only under that row.
    createRoot proc(dispose: proc()) =
      let backend = newMockBackendService().toBackendService()
      let store = createReplayDataStore(backend)
      let vm = createStateVM(store)
      let r = MockRenderer()

      var toggled: seq[string] = @[]
      vm.onToggleHistory = proc(expression: string) =
        toggled.add(expression)

      store.locals.locals.val = @[
        store_types.Variable(
          name: "obj", value: "{...}", typeName: "Point",
          hasChildren: true,
          children: @[
            store_types.Variable(name: "field", value: "7", typeName: "int",
                                 hasChildren: false, children: @[])
          ])
      ]
      drain()

      let panel = renderStatePanel[MockRenderer, MockNode](r, vm)

      # Expand the compound so the child row is materialised.
      vm.toggleExpand("obj")
      drain()
      let childRow = findRowByName(panel, "field")
      check childRow != nil

      let childButton = findByClass(childRow, "value-history-button")
      check childButton != nil
      childButton.fireEvent("click")
      drain()

      # The request key is the full path, not the leaf name.
      check toggled == @["obj.field"]
      check "obj.field" in vm.expandedHistories.val

      vm.updateHistory("obj.field", sampleHistory())
      drain()

      let childRows = historyRowsOf(childRow)
      check childRows.len == 2
      if childRows.len == 2:
        check "100" in childRows[0].textContent
        check "10" in childRows[0].textContent

      # The parent row must not have picked the child's history up.
      let parentRow = findRowByName(panel, "obj")
      check parentRow != nil
      check historyDisplayOf(parentRow) == "none"
      # `parentRow` contains `childRow` in the flattened list only if the
      # renderer nests them; it does not — rows are siblings — so the
      # parent's own sub-tree must carry no history rows at all.
      check historyRowsOf(parentRow).len == 0

      dispose()

suite "the ViewModel asks for a value history itself":
  # `StateVM.loadValueHistory` is what the desktop and the web page install as
  # `onToggleHistory` (`ui/state.initStateVMFromSession`): the request goes out
  # through the store's backend and the answer is applied by the ViewModel,
  # with no component subscription between them.

  proc historyAnswer(): JsonNode =
    ## The `ct/load-history` response envelope, in the shape the replay
    ## server's `load_history` answers (`HistoryUpdate`: `results`, each
    ## with its `location` and its `value`).
    %*{"type": "response", "command": "ct/load-history", "success": true,
       "body": {"expression": "x", "results": [
         {"location": {"path": "/src/main.rs", "line": 3, "rrTicks": 100},
          "value": {"kind": 7, "i": "10", "typ": {"kind": 7, "langType": "int"}}},
         {"location": {"path": "/src/main.rs", "line": 5, "rrTicks": 110},
          "value": {"kind": 7, "i": "42", "typ": {"kind": 7, "langType": "int"}}}],
         "total": 2, "start": 0}}

  test "a row's history is asked for at the current stop and applied":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService()
      let store = createReplayDataStore(mock.toBackendService())
      let vm = createStateVM(store)
      store.updateDebuggerPosition(120'u64, "/src/main.rs", 7)
      drain()
      mock.expect("ct/load-history", historyAnswer())
      mock.clearReceivedCommands()

      vm.loadValueHistory("x")
      drain()

      let sent = mock.findCommand("ct/load-history")
      check sent.isSome
      if sent.isSome:
        let args = sent.get.args
        check args["expression"].getStr == "x"
        check args["location"]["rrTicks"].getInt == 120
        check args["location"]["path"].getStr == "/src/main.rs"
        check args["location"]["line"].getInt == 7
      check vm.valueHistory.val.hasKey("x")
      if vm.valueHistory.val.hasKey("x"):
        let rows = vm.valueHistory.val["x"]
        check rows.len == 2
        check rows.len == 2 and rows[0].locationTicks == 100
        check rows.len == 2 and rows[1].locationTicks == 110
        check rows.len == 2 and rows[1].valueText.contains("42")
      dispose()

  test "a refused request leaves the history unanswered, not empty":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService()
      let store = createReplayDataStore(mock.toBackendService())
      let vm = createStateVM(store)
      mock.expect("ct/load-history",
        %*{"type": "response", "command": "ct/load-history",
           "success": false, "message": "no history"})
      vm.loadValueHistory("x")
      drain()
      check not vm.valueHistory.val.hasKey("x")
      dispose()

  test "toggling a row open asks through the installed loader":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      let vm = createStateVM(store)
      let theVm = vm
      vm.onToggleHistory = proc(expression: string) =
        theVm.loadValueHistory(expression)
      mock.clearReceivedCommands()
      vm.toggleHistory("x")
      drain()
      check mock.findCommand("ct/load-history").isSome
      dispose()

suite "a collection the locals budget cut short":

  test "its open row offers Load more, which asks for the next elements":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      let vm = createStateVM(store)
      store.locals.locals.val = @[
        store_types.Variable(name: "xs", value: "[1, 2, …]", typeName: "seq",
          hasChildren: true, moreElements: true, elementsTotal: 5,
          children: @[
            store_types.Variable(name: "[0]", value: "1", typeName: "int"),
            store_types.Variable(name: "[1]", value: "2", typeName: "int")])]
      drain()
      let panel = renderStatePanel[MockRenderer, MockNode](MockRenderer(), vm)
      let row = findRowByName(panel, "xs")
      let button = findByClass(row, "value-load-more")
      check button != nil
      # Closed, the row's elements are not shown, and neither is the offer.
      check button.styles.getOrDefault("display", "") == "none"
      vm.toggleExpand("xs")
      drain()
      check button.styles.getOrDefault("display", "") == "inline-block"
      check button.textContent == "Load more (2 of 5)"
      mock.clearReceivedCommands()
      button.fireEvent("click")
      drain()
      let sent = mock.findCommand("ct/load-value-elements")
      check sent.isSome
      check sent.isSome and sent.get.args["startIndex"].getInt == 2
      dispose()
