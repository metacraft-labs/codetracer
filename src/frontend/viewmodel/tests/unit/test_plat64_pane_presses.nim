## test_plat64_pane_presses.nim — Input-Routing-And-Keymaps.md §5.1 on a DOM
## front-end: a press on an element of one of the session's panes is the
## pointer keymap's row, performed by `input/pane_presses` on the element's own
## identity. The views draw that identity and hold no handler of their own.
##
## Each case renders the shipped view (the very proc the desktop, the web page
## and the VS Code webviews render) under `MockRenderer`, finds the element a
## DOM hit test finds (`input/dom_pointer.HitRules`' selectors, by class or
## attribute), resolves the press through the shipped router over the shipped
## base keymaps, and performs the operation with `pane_presses` reading the
## mock node's attributes — what `dom_pane_presses` does with the DOM's.
##
## The one stand-in: `MockBackendService` answers the store's requests, so what
## is asserted is the ViewModel's state and the requests a press makes — the
## same arrangement as `test_calltrace_view.nim`. It is not a mock of anything
## under test: the view, the router, the keymaps and the procedures are the
## product's.

import std/[options, strutils, tables, unittest]

import isonim/core/[signals, owner]
import isonim/testing/mock_dom

import ../../backend/[backend_service, mock_backend]
import ../../store/[replay_data_store, types]
import ../../viewmodels/[calltrace_vm, point_list_vm]
import ../../views/[isonim_calltrace_view, isonim_point_list_view]
import ../../input/pane_presses
import ../../keymap/[base_keymaps, context_keys, editing_keymap, keymap_router,
                     scope_path, user_keymap]
import ../../viewmodels/product_mode
import ../../../../common/key_names

const Desktop = KeyDelivery(frontEnd: feDesktop, platform: pkLinux,
                            keyProtocol: kpNative)

proc byId(node: MockNode; id: string): MockNode =
  if node.isNil: return nil
  if node.attributes.getOrDefault("id", "") == id: return node
  for child in node.children:
    let found = byId(child, id)
    if not found.isNil: return found

proc byClass(node: MockNode; cls: string; found: var seq[MockNode]) =
  if node.isNil: return
  if cls in node.attributes.getOrDefault("class", "").split(' '):
    found.add node
  for child in node.children:
    byClass(child, cls, found)

proc allByClass(node: MockNode; cls: string): seq[MockNode] =
  byClass(node, cls, result)

proc readerOf(node: MockNode): AttributeReader =
  ## The DOM reader's rule: the attribute on the node or its nearest ancestor
  ## that carries it.
  result = proc(name: string): string =
    var n = node
    while not n.isNil:
      if name in n.attributes: return n.attributes[name]
      n = n.parent
    ""

proc operationOf(router: KeymapRouter; paneKind: string; kind: ElementKind;
                 gesture = "Click"): string =
  let facts = SessionFacts(product: pmDebug, replayLoaded: true,
                           editor: sourceViewFacts())
  let path = @[element(ekWindow, "window"), pane(paneKind), element(kind, "")]
  let res = router.routePointer(facts, path, nmNormal, gesture)
  if res.kind == erOperation: res.operation else: ""

proc line(index: int; name: string; children = false): CallLine =
  CallLine(index: index.int64, name: name, hasChildren: children,
           callKey: "k" & $index,
           location: Location(file: "/src/main.py", line: index + 1),
           rrTicks: uint64(index + 1))

suite "a press on a session pane's element runs its pointer row":

  test "the call trace: a press on a call goes to it, on its toggle expands it":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      let vm = createCalltraceVM(store)
      let panel = renderCalltracePanel[MockRenderer, MockNode](MockRenderer(), vm)
      store.updateCalltraceSection(@[line(0, "main", children = true),
                                     line(1, "helper")], 0'i64, 2'u64)
      let router = initKeymapRouter(bkCua, Desktop)
      let text = panel.byId("local-call-text-1")
      check not text.isNil
      # The view holds no handler: a click event on the element does nothing.
      mock.clearReceivedCommands()
      fireEvent(text, "click")
      check mock.findCommand("ct/calltrace-jump").isNone
      # The row is the keymap's: Click on a call row goes to the call.
      let op = router.operationOf("calltrace", ekRow)
      check op == "calltrace.go-to-call"
      check pressCalltrace(vm, op, readerOf(text))
      check vm.selectedEntry.val == some(1'i64)
      check mock.findCommand("ct/calltrace-jump").isSome
      let toggles = panel.allByClass("toggle-call")
      check toggles.len == 2
      let toggleOp = router.operationOf("calltrace", ekToggle)
      check toggleOp == "calltrace.toggle-call"
      check pressCalltrace(vm, toggleOp, readerOf(toggles[0]))
      check mock.findCommand("ct/expand-calls").isSome
      dispose()

  test "a user's row removing the base's leaves the press with nothing to run":
    let router = initKeymapRouter(bkCua, Desktop, user = parseUserKeymap(
      """[ { "key": "click", "command": "-calltrace.go-to-call",
             "when": "paneKind == calltrace && elementKind == row" } ]"""))
    check router.operationOf("calltrace", ekRow) != "calltrace.go-to-call"
    # ... and a user's row naming another operation takes it.
    let rebound = initKeymapRouter(bkCua, Desktop, user = parseUserKeymap(
      """[ { "key": "click", "command": "debugger.continue",
             "when": "paneKind == calltrace && elementKind == row" } ]"""))
    check rebound.operationOf("calltrace", ekRow) == "debugger.continue"

  test "Points: a press on a point selects it":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      let vm = createPointListVM(store)
      vm.points.val = @[
        PointListEntry(kind: "breakpoint", label: "a", enabled: true),
        PointListEntry(kind: "breakpoint", label: "b", enabled: true)]
      let panel = renderPointListPanel[MockRenderer, MockNode](MockRenderer(), vm)
      var rows: seq[MockNode]
      proc collect(n: MockNode) =
        if n.isNil: return
        if "data-point-index" in n.attributes: rows.add n
        for c in n.children: collect(c)
      collect(panel)
      check rows.len == 2
      let router = initKeymapRouter(bkCua, Desktop)
      let op = router.operationOf("pointList", ekRow)
      check op == "point-list.select"
      check pressPointList(vm, op, readerOf(rows[1]))
      check vm.selectedPoint.val == some(1)
      dispose()

  test "every procedure answers only its own operation":
    for op in SessionPressOperations:
      check not performSessionPress(nil, op, proc(name: string): string = "")
    check "calltrace.go-to-call" in SessionPressOperations
    check "low-level.toggle-sync" in SessionPressOperations
