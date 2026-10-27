## test_calltrace_view.nim
##
## The Call Trace panel is ONE view generic over the renderer
## (Shared-DOM-Front-Ends D3). This suite renders the very proc Electron, the
## web page and the VS Code webviews render, under `MockRenderer`, and checks
## the markup the Playwright page objects read (`CallTracePane`,
## `CallTraceEntry`), driven through the ViewModel: the rows follow the
## section the store holds, a row's arguments follow its call, the selection
## and the expand state follow the VM, and the search results follow the
## engine's answer.
##
## The backend is a `MockBackendService`; what is asserted is the DOM and the
## requests a click makes.

import std/[json, options, strutils, tables, unittest]

import isonim/core/[signals, owner, async_compat]
import isonim/testing/mock_dom

import backend/[backend_service, mock_backend]
import store/[replay_data_store, types]
import viewmodels/calltrace_vm
import views/isonim_calltrace_view

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

proc line(index: int; name: string; depth = 0; children = false;
          key = ""): CallLine =
  CallLine(index: index.int64, name: name, depth: depth,
           hasChildren: children, callKey: (if key.len > 0: key else: $index),
           location: Location(file: "/src/main.py", line: index + 1),
           rrTicks: uint64(index + 1))

proc setup(): (ReplayDataStore, CalltraceVM, MockBackendService) =
  let mock = newMockBackendService(autoRespond = true)
  let store = createReplayDataStore(mock.toBackendService())
  (store, createCalltraceVM(store), mock)

suite "the Call Trace panel":

  test "the root and its regions carry the page object's ids":
    createRoot proc(dispose: proc()) =
      let (_, vm, _) = setup()
      let panel = renderCalltracePanel[MockRenderer, MockNode](MockRenderer(), vm)
      check "id" notin panel.attributes   # the host carries the pane's id
      check "isonim-calltrace" in panel.attributes["class"]
      check not panel.byId("calltrace-search-input-0").isNil
      check not panel.byId("calltraceScroll-0").isNil
      check panel.allByClass("calltrace-lines").len == 1
      dispose()

  test "the rows are the section the store holds":
    createRoot proc(dispose: proc()) =
      let (store, vm, _) = setup()
      let panel = renderCalltracePanel[MockRenderer, MockNode](MockRenderer(), vm)
      check panel.allByClass("calltrace-call-line").len == 0
      store.updateCalltraceSection(@[line(0, "main", children = true),
                                     line(1, "helper", 1)], 0'i64, 2'u64)
      let rows = panel.allByClass("calltrace-call-line")
      check rows.len == 2
      check rows.len == 2 and "main #0" in rows[0].textContent
      check not panel.byId("local-call-text-1").isNil
      store.updateCalltraceSection(@[line(5, "other")], 5'i64, 9'u64)
      check panel.allByClass("calltrace-call-line").len == 1
      check not panel.byId("local-call-text-5").isNil
      dispose()

  test "a row's arguments follow its call":
    createRoot proc(dispose: proc()) =
      let (store, vm, _) = setup()
      let panel = renderCalltracePanel[MockRenderer, MockNode](MockRenderer(), vm)
      var args = initTable[string, seq[CallArg]]()
      args["0"] = @[CallArg(name: "x", text: "1"), CallArg(name: "y", text: "2")]
      store.updateCalltraceSection(@[line(0, "main")], 0'i64, 1'u64,
                                   args = args)
      let shown = panel.allByClass("call-arg")
      check shown.len == 2
      check not panel.byId("call-arg-text-0-y").isNil
      check panel.byId("call-arg-text-0-y").textContent == "2"
      dispose()

  test "the selected row is marked":
    createRoot proc(dispose: proc()) =
      let (store, vm, _) = setup()
      let panel = renderCalltracePanel[MockRenderer, MockNode](MockRenderer(), vm)
      store.updateCalltraceSection(@[line(0, "main"), line(1, "helper")],
                                   0'i64, 2'u64)
      vm.selectEntry(some(1'i64))
      let rows = panel.allByClass("calltrace-call-line")
      check rows.len == 2
      check rows.len == 2 and "event-selected" in rows[1].attributes["class"]
      check rows.len == 2 and "event-selected" notin rows[0].attributes["class"]
      dispose()

  test "a click on a row goes to that call; the toggle expands it":
    createRoot proc(dispose: proc()) =
      let (store, vm, mock) = setup()
      let panel = renderCalltracePanel[MockRenderer, MockNode](MockRenderer(), vm)
      store.updateCalltraceSection(@[line(0, "main", children = true,
                                          key = "k0")], 0'i64, 1'u64)
      mock.clearReceivedCommands()
      fireEvent(panel.byId("local-call-text-0"), "click")
      check vm.selectedEntry.val == some(0'i64)
      check mock.findCommand("ct/calltrace-jump").isSome
      var toggles = panel.allByClass("toggle-call")
      check toggles.len == 1
      fireEvent(toggles[0], "click")
      check mock.findCommand("ct/expand-calls").isSome
      dispose()

  test "the search results follow the engine's answer":
    createRoot proc(dispose: proc()) =
      let (_, vm, _) = setup()
      let panel = renderCalltracePanel[MockRenderer, MockNode](MockRenderer(), vm)
      var hosts = panel.allByClass("call-search-results")
      check hosts.len == 1 and "hidden" in hosts[0].attributes["class"]
      vm.setBackendSearchResults(@[
        CalltraceSearchResult(name: "helper", key: "3", rrTicks: 7'u64,
          location: Location(file: "/src/main.py", line: 4)),
        CalltraceSearchResult(name: "helper", key: "9", rrTicks: 21'u64,
          location: Location(file: "/src/main.py", line: 4))])
      let rows = panel.allByClass("search-result")
      check rows.len == 2
      check rows.len == 2 and rows[0].textContent.contains("helper")
      check "hidden" notin hosts[0].attributes["class"]
      dispose()

  test "a search result jumps to its own call":
    createRoot proc(dispose: proc()) =
      let (_, vm, mock) = setup()
      let panel = renderCalltracePanel[MockRenderer, MockNode](MockRenderer(), vm)
      vm.setBackendSearchResults(@[
        CalltraceSearchResult(name: "helper", key: "3", rrTicks: 7'u64,
          location: Location(file: "/src/main.py", line: 4)),
        CalltraceSearchResult(name: "helper", key: "9", rrTicks: 21'u64,
          location: Location(file: "/src/main.py", line: 4))])
      mock.clearReceivedCommands()
      panel.allByClass("search-result")[0].fireEvent("mousedown")
      let jump = mock.findCommand("ct/calltrace-jump")
      check jump.isSome
      check jump.isSome and jump.get.args["rrTicks"].getInt == 7
      dispose()

suite "the call trace's search answer":
  # `setSearchQuery` asks `ct/search-calltrace` and the VM applies the answer
  # itself — the replay server's `CallSearchResponseBody`: at most the pane's
  # window of calls, and how many match in the whole trace.

  proc answer(names: openArray[string]; total: int): JsonNode =
    var calls = newJArray()
    for i, n in names:
      calls.add %*{"key": $(i + 1), "depth": 0,
                   "location": {"highLevelFunctionName": n, "rrTicks": 10 * (i + 1)}}
    %*{"type": "response", "command": "ct/search-calltrace", "success": true,
       "body": {"calls": calls, "total": total}}

  test "the answer is applied, and a window shorter than the matches says so":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService()
      let store = createReplayDataStore(mock.toBackendService())
      let vm = createCalltraceVM(store)
      let panel = renderCalltracePanel[MockRenderer, MockNode](MockRenderer(), vm)
      mock.expect("ct/search-calltrace", answer(["parse", "parse_expr"], 7))
      vm.setSearchQuery("parse")
      drainPlatformCallbacks()
      check vm.backendSearchResults.val.len == 2
      check vm.backendSearchResults.val.len == 2 and
            vm.backendSearchResults.val[1].name == "parse_expr" and
            vm.backendSearchResults.val[1].rrTicks == 20
      check vm.backendSearchTotal.val == 7
      check allByClass(panel, "search-result").len == 2
      let summary = allByClass(panel, "call-search-summary")
      check summary.len == 1
      check summary.len == 1 and summary[0].styles.getOrDefault("display") == "block"
      check summary.len == 1 and summary[0].textContent.contains("2 of 7")
      dispose()

  test "an answer for a query the reader has since changed is dropped":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService()
      mock.deferResponses = true
      let store = createReplayDataStore(mock.toBackendService())
      let vm = createCalltraceVM(store)
      vm.setSearchQuery("parse")
      vm.searchQuery.val = "eval"     # typed on before the answer came
      mock.settleDeferred(answer(["parse"], 1))
      check vm.backendSearchResults.val.len == 0
      dispose()

  test "clearing the query clears the results":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService()
      let store = createReplayDataStore(mock.toBackendService())
      let vm = createCalltraceVM(store)
      mock.expect("ct/search-calltrace", answer(["parse"], 1))
      vm.setSearchQuery("parse")
      drainPlatformCallbacks()
      check vm.backendSearchResults.val.len == 1
      vm.setSearchQuery("")
      check vm.backendSearchResults.val.len == 0
      check vm.backendSearchTotal.val == 0
      dispose()
