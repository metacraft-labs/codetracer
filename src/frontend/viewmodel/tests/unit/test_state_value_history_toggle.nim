import std/[sets, tables, unittest, strutils]

import isonim/core/signals
import isonim/core/owner
import isonim/testing/mock_dom

import ../../../../common/types
import ../../store/types as store_types
import ../../viewmodels/state_vm
import ../../views/isonim_state_view

import ../../backend/mock_backend
import ../../store/replay_data_store
import std/asyncdispatch

proc drain() =
  try:
    poll(0)
  except ValueError:
    discard

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



suite "State component value history toggle":
  test "test_state_value_history_toggle: clicking the history button loads and displays inline history":
    createRoot proc(dispose: proc()) =
      let backend = newMockBackendService().toBackendService()
      let store = createReplayDataStore(backend)
      let vm = createStateVM(store)
      let r = MockRenderer()

      var toggled: seq[string] = @[]
      vm.onToggleHistory = proc(expression: string) =
        toggled.add(expression)

      store.locals.locals.val = @[
        store_types.Variable(name: "x", value: "42", typeName: "int", hasChildren: false, children: @[])
      ]
      drain()

      # Render the state panel
      let panel1 = renderStatePanel(r, vm)
      let button = findByClass(panel1, "value-history-button")
      check button != nil

      # Click the history toggle button
      button.fireEvent("click")
      check toggled == @["x"]
      check "x" in vm.expandedHistories.val

      # Initially, history is not yet populated
      var inlineContainer = findByClass(panel1, "ct-history-inline-container")
      check inlineContainer != nil
      check inlineContainer.styles.getOrDefault("display", "") == "block"

      # 2. Simulate CtUpdatedHistory response arriving
      let historyResults = @[
        HistoryResult(
          location: types.Location(rrTicks: 100),
          value: types.Value(text: "10"),
          time: 100,
        ),
        HistoryResult(
          location: types.Location(rrTicks: 110),
          value: types.Value(text: "42"),
          time: 110,
        )
      ]
      vm.updateHistory("x", historyResults)

      # 3. Verify history is rendered
      let panel2 = renderStatePanel(r, vm)
      let historyRows = findAllByClass(panel2, "ct-history-inline-row")
      check historyRows.len == 2

      check "100" in historyRows[0].textContent
      check "10" in historyRows[0].textContent

      check "110" in historyRows[1].textContent
      check "42" in historyRows[1].textContent

      # 4. Click toggle again to hide
      button.fireEvent("click")
      check "x" notin vm.expandedHistories.val

      let panel3 = renderStatePanel(r, vm)
      let inlineContainer3 = findByClass(panel3, "ct-history-inline-container")
      check inlineContainer3.styles.getOrDefault("display", "") == "none"

      dispose()
