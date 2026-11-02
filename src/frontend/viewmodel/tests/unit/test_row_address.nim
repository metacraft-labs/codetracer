## test_row_address.nim
##
## Shared-DOM-Front-Ends D10 (decided 2026-10-26): the Call Trace and Event
## Log ViewModels give every row a logical address with no URL in it, and a
## host that passes the views a link builder gets each row's control as a link
## to what it builds. Recorded as codetracer-pm
## issues/2026-10-24-shared-pane-rows-are-clickable-without-a-role-a-keyboard-path-or-a-link.md.
##
## What is checked:
##
##   * `CalltraceVM.rowAddress` and `EventLogVM.rowAddress` (by the row's
##     position in what the ViewModel holds) carry the row's
##     coordinates — tick, call index and key, depth, sibling path; event
##     index, the recorder's kind verbatim, file, line, whether it has a
##     position — and nothing URL-shaped;
##   * `callPathsOf` numbers siblings exactly as BlockTracer's `call:` anchor
##     does: `blocktracerCallPath` below is a verbatim copy of
##     `blocktracer/client/src/debugger/deeplink_landing.callPath` (which
##     BlockTracer joins with `.`), and the two must agree on every row;
##   * the views, rendered under `MockRenderer` over their real ViewModels:
##     without a builder, the markup is the controls it always was; with one,
##     the call text is an `a.call-text[href]` and the event's index cell an
##     `a.eventLog-row-link[href][tabindex=-1]`, the `href` being what the
##     builder made of THAT row's address; a row the builder answers `""` for
##     has no `href` and stays a button. A click on a linked call text still
##     goes to the call. (What a plain versus a modified click does to the
##     browser's navigation needs a real DOM:
##     `src/frontend/tests/row_links_dom_test.nim`.)
##
## The backend is a `MockBackendService`: the store and the ViewModels are
## real, and what is asserted is their answers and the markup; the one
## request checked is the jump a click sends.
##
## THE CONTROLS: a builder that is never passed must leave the markup exactly
## as `test_shared_rows_are_controls` requires it, and a builder that answers
## `""` must produce no `href` at all.

import std/[options, strutils, tables, unittest]

import isonim/core/[async_compat, owner]
import isonim/testing/mock_dom

import ../../backend/mock_backend
import ../../store/[replay_data_store, row_address]
import ../../store/types as store_types
import ../../viewmodels/[calltrace_vm, event_log_vm]
import ../../views/[isonim_calltrace_view, isonim_event_log_view]

# Counted, so a loop over an empty list cannot pass by asserting nothing.
const ExpectedAssertions = 87

var checks = 0
template ck(cond: untyped) =
  inc checks
  check cond

func blocktracerCallPath(depths: seq[int]; i: int): string =
  ## Verbatim (over depths instead of `CallFrame`s) from BlockTracer's
  ## `client/src/debugger/deeplink_landing.callPath`: the oracle.
  var counters: seq[int]
  var pathAt: seq[string]
  for k in 0 .. i:
    let d = max(0, depths[k])
    while counters.len <= d: counters.add 0
    while pathAt.len <= d: pathAt.add ""
    for deeper in d + 1 ..< counters.len: counters[deeper] = 0
    let seg = $counters[d]
    inc counters[d]
    pathAt[d] = (if d == 0 or pathAt[d - 1].len == 0: seg
                 else: pathAt[d - 1] & "." & seg)
    if k == i: result = pathAt[d]

proc joined(path: seq[int]): string =
  var parts: seq[string]
  for p in path: parts.add $p
  parts.join(".")

proc callLine(index, depth: int; name: string): CallLine =
  CallLine(index: index.int64, name: name, depth: depth, callKey: "k" & $index,
           location: Location(file: "/src/main.nr", line: 10 + index),
           rrTicks: uint64(100 + index))

proc allByClass(node: MockNode; cls: string; found: var seq[MockNode]) =
  if node.isNil: return
  if node.kind == mnkElement and
      cls in node.attributes.getOrDefault("class", "").split(' '):
    found.add node
  for child in node.children:
    allByClass(child, cls, found)

proc allByClass(node: MockNode; cls: string): seq[MockNode] =
  allByClass(node, cls, result)

proc attr(node: MockNode; name: string): string =
  if node.isNil: "<no element>" else: node.attributes.getOrDefault(name, "<unset>")

proc frameLinks(a: RowAddress): string =
  ## A stand-in host builder: enough of the address to show which row it was
  ## built from. It refuses (answers `""`) for call 2, to exercise an
  ## unlinked row.
  if a.kind != rakFrame or a.callIndex == 2: ""
  else: "?t=" & $a.rrTicks & "&a=call:" & a.callPath.joined

proc eventLinks(a: RowAddress): string =
  if a.kind != rakEvent or not a.hasPosition: ""
  else: "?t=" & $a.rrTicks & "&e=" & $a.eventIndex & "&k=" & a.eventKind

suite "the call path is BlockTracer's":
  test "every row of a tree, and of a section that starts below depth 0":
    for depths in [@[0, 1, 2, 1, 2, 2, 0, 1, 1, 2],
                   @[2, 2, 1, 2, 0, 1, 3, 1]]:
      var lines: seq[CallLine]
      for i, d in depths:
        lines.add callLine(i, d, "f" & $i)
      let paths = callPathsOf(lines)
      ck paths.len == depths.len
      for i in 0 ..< depths.len:
        ck paths[i].joined == blocktracerCallPath(depths, i)

suite "the ViewModels give each row a logical address":
  test "a call-trace row: tick, call, depth and its place in the tree":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      let vm = createCalltraceVM(store)
      store.calltrace.lines.val = @[callLine(0, 0, "main"),
                                    callLine(1, 1, "a"),
                                    callLine(2, 1, "b"),
                                    callLine(3, 2, "c")]
      let a = vm.rowAddress(3)
      ck a.kind == rakFrame
      ck a.rrTicks == 103'u64
      ck a.callIndex == 3
      ck a.callKey == "k3"
      ck a.depth == 2
      ck a.callPath == @[0, 1, 0]
      # Past the held rows there is no row.
      ck vm.rowAddress(4).kind == rakNone
      # By position, not by `CallLine.index`: two rows a producer left with the
      # same index are still two addresses.
      store.calltrace.lines.val = @[callLine(0, 0, "x"), callLine(0, 1, "y")]
      ck vm.rowAddress(1).callPath == @[0, 0]
      ck vm.rowAddress(1).depth == 1
      dispose()

  test "an event-log row: tick, index, the recorder's kind, its line":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      let vm = createEventLogVM(store)
      store.applyEventLogRows(@[
        EventLogRow(eventId: 7, eventIndex: 40, kind: "storageWrite",
                    file: "/src/vault.sol", line: 12, rrTicks: 55),
        EventLogRow(eventId: 8, eventIndex: 41, kind: "output",
                    noPosition: true)], 20, recordsTotal = 60)
      let a = vm.rowAddress(20)
      ck a.kind == rakEvent
      ck a.rrTicks == 55'u64
      ck a.eventIndex == 40
      ck a.eventKind == "storageWrite"   # verbatim: the host classifies it
      ck a.file == "/src/vault.sol"
      ck a.line == 12
      ck a.hasPosition
      ck not vm.rowAddress(21).hasPosition
      # Outside the held window there is no row.
      ck vm.rowAddress(19).kind == rakNone
      ck vm.rowAddress(22).kind == rakNone
      dispose()

suite "a host's link builder makes the row's control a link":
  test "the call trace: no builder, a builder, a row it refuses":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      let vm = createCalltraceVM(store)
      store.calltrace.lines.val = @[callLine(0, 0, "main"),
                                    callLine(1, 1, "a"),
                                    callLine(2, 1, "b")]
      store.calltrace.totalCallsCount.val = 3
      # CONTROL: no builder, the controls of test_shared_rows_are_controls.
      let plain = renderCalltracePanel[MockRenderer, MockNode](MockRenderer(), vm)
      drainPlatformCallbacks()
      let plainTexts = plain.allByClass("call-text")
      ck plainTexts.len == 3
      for t in plainTexts:
        ck t.tag == "div"
        ck t.attr("role") == "button"
        ck t.attr("tabindex") == "0"
        ck t.attr("href") == "<unset>"

      let linked = renderCalltracePanel[MockRenderer, MockNode](
        MockRenderer(), vm, frameLinks)
      drainPlatformCallbacks()
      let texts = linked.allByClass("call-text")
      ck texts.len == 3
      if texts.len == 3:
        ck texts[1].tag == "a"
        ck texts[1].attr("href") == "?t=101&a=call:0.0"
        ck texts[1].attr("role") == "<unset>"   # a link is its own role
        ck texts[1].attr("tabindex") == "<unset>"
        ck texts[0].attr("href") == "?t=100&a=call:0"
        # CONTROL: the builder refused call 2 — no `href`, still a button.
        ck texts[2].tag == "a"
        ck texts[2].attr("href") == "<unset>"
        ck texts[2].attr("role") == "button"
        ck texts[2].attr("tabindex") == "0"
        # The structure is unchanged: the text sits between the toggle and
        # the arguments in its call box.
        let box = texts[1].parent
        ck box.attr("class").contains("call-child-box")
        ck box.children.len == 4
        if box.children.len == 4:
          ck box.children[0].attr("class") == "toggle-call"
          ck box.children[1] == texts[1]
          ck box.children[2].attr("class") == "call-args"
        # A click on the link still goes to the call.
        mock.clearReceivedCommands()
        texts[1].fireEvent("click")
        drainPlatformCallbacks()
        ck mock.findCommand("ct/calltrace-jump").isSome
      # The href follows the row when the section moves under it.
      store.calltrace.lines.val = @[callLine(5, 0, "next"),
                                    callLine(6, 0, "after"),
                                    callLine(7, 1, "inner")]
      drainPlatformCallbacks()
      let moved = linked.allByClass("call-text")
      ck moved.len == 3
      if moved.len == 3:
        ck moved[1].attr("href") == "?t=106&a=call:1"
        ck moved[2].attr("href") == "?t=107&a=call:1.0"
      dispose()

  test "the event log: the index cell links, the row stays the control":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = true)
      let store = createReplayDataStore(mock.toBackendService())
      let vm = createEventLogVM(store)
      store.applyEventLogRows(@[
        EventLogRow(eventId: 1, eventIndex: 0, kind: "event",
                    file: "/src/main.py", line: 3, rrTicks: 11),
        EventLogRow(eventId: 2, eventIndex: 1, kind: "write",
                    file: "/src/main.py", line: 4, rrTicks: 12),
        EventLogRow(eventId: 3, eventIndex: 2, kind: "output",
                    noPosition: true)], 0, recordsTotal = 3)
      # CONTROL: no builder, no link.
      let plain = renderEventLogPanel[MockRenderer, MockNode](MockRenderer(), vm)
      drainPlatformCallbacks()
      ck plain.allByClass("eventLog-row-link").len == 0

      let linked = renderEventLogPanel[MockRenderer, MockNode](
        MockRenderer(), vm, eventLinks)
      drainPlatformCallbacks()
      let rows = linked.allByClass("eventLog-row")
      ck rows.len == 3
      for row in rows:
        ck row.attr("role") == "button"
        ck row.attr("tabindex") == "0"
      let links = linked.allByClass("eventLog-row-link")
      ck links.len == 3
      if links.len == 3:
        ck links[0].tag == "a"
        ck links[0].attr("href") == "?t=11&e=0&k=event"
        ck links[0].attr("tabindex") == "-1"
        ck links[1].attr("href") == "?t=12&e=1&k=write"
        # CONTROL: no position, no URL — and no `href` at all.
        ck links[2].attr("href") == "<unset>"
        ck links[1].parent.attr("data-ct-cell").endsWith("|" & $elcIndex)
      # The row's click is unchanged.
      mock.clearReceivedCommands()
      if rows.len == 3:
        rows[1].fireEvent("click")
      drainPlatformCallbacks()
      ck mock.findCommand("ct/event-jump").isSome
      dispose()

  test "every assertion ran":
    check checks == ExpectedAssertions
