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

import std/[sets, tables, unittest, strutils]

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
      let panel = renderStatePanel(r, vm)
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

      let panel = renderStatePanel(r, vm)

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

      let panel = renderStatePanel(r, vm)

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
