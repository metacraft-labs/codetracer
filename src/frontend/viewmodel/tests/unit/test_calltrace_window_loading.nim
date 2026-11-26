## test_calltrace_window_loading.nim
##
## A scrolled-to window of the shared call trace, while it loads
## (codetracer-pm issues/2026-11-26-the-shared-call-trace-view-shows-a-blank-
## pane-while-a-scrolled-to-window-loads.md; Viewport-Driven-Loading
## V2 and V4). Three properties, each of which was missing:
##
## 1. **An answer for a window the viewport has left is not applied.** Only
##    the answer to the latest section request may replace the held rows,
##    whatever order the answers arrive in.
## 2. **A held window is not asked for again.** A scroll that stays inside
##    the rows the store holds, for the same stop, filter and depth, sends
##    nothing, and drops the answer to a request for a window it left.
## 3. **The pane shows where rows are loading.** The visible rows the store
##    does not hold are drawn as a placeholder at the place the rows will be,
##    not as an empty scroll area.
##
## WHY A MOCK BACKEND: the property is the ORDER and TIMING of answers
## relative to scrolls — a request still in flight while the viewport moves,
## two answers arriving out of order. A real engine answers in microseconds on
## any fixture small enough for a unit suite, so it cannot hold a request in
## flight on demand. `MockBackendService.deferResponses` holds each answer
## until the test settles it, which is exactly the slow-engine condition the
## issue measured (a ~10 s single-threaded worker). The answers carry the
## engine's section shape, decoded by the store's own decoder.

import std/[json, tables, unittest]

import isonim/core/[signals, owner, async_compat]
import isonim/testing/mock_dom

import backend/[backend_service, mock_backend]
import store/[replay_data_store, types]
import viewmodels/calltrace_vm
import views/isonim_calltrace_view

const Total = 1000

proc section(start, count: int; total = Total; name = "f"): JsonNode =
  ## The engine's answer for rows `start ..< start + count`; `name` prefixes
  ## each callee, so two answers for the same rows can be told apart.
  var lines = newJArray()
  for i in start ..< min(start + count, total):
    lines.add %*{"depth": 0, "content": {"kind": 0, "count": 0,
      "call": {"rawName": name & $i, "key": $i,
               "location": {"path": "/src/main.py", "line": i + 1,
                            "rrTicks": i + 1}}}}
  %*{"success": true, "body": {"callLines": lines,
     "startCallLineIndex": start, "totalCallsCount": total}}

proc startOf(cmd: ReceivedCommand): int =
  cmd.args["startCallLineIndex"].getInt

proc sectionRequests(mock: MockBackendService): seq[ReceivedCommand] =
  for c in mock.receivedCommands:
    if c.command == "ct/load-calltrace-section":
      result.add c

proc newDeferred(): (ReplayDataStore, MockBackendService) =
  let mock = newMockBackendService(autoRespond = true)
  mock.deferResponses = true
  (createReplayDataStore(mock.toBackendService()), mock)

proc byId(node: MockNode; id: string): MockNode =
  if node.isNil: return nil
  if node.attributes.getOrDefault("id", "") == id: return node
  for child in node.children:
    let found = byId(child, id)
    if not found.isNil: return found

suite "an answer for a window the viewport has left is not applied":

  test "the older answer arriving last does not replace the newer rows":
    let (store, mock) = newDeferred()
    store.requestCalltraceSection(startIndex = 0, height = 40, depth = 5)
    store.requestCalltraceSection(startIndex = 500, height = 40, depth = 5)
    check mock.pendingDeferredCount == 2
    mock.settleDeferredAt(1, section(500, 40))   # the newer answers first
    check store.calltrace.startLineIndex.val == 500
    mock.settleDeferredAt(0, section(0, 40))     # then the stale one
    check store.calltrace.startLineIndex.val == 500
    check store.calltrace.lines.val[0].index == 500
    check store.calltrace.loadingState.val == lsIdle

  test "the older answer arriving first is not shown in between":
    let (store, mock) = newDeferred()
    store.requestCalltraceSection(startIndex = 0, height = 40, depth = 5)
    store.requestCalltraceSection(startIndex = 500, height = 40, depth = 5)
    mock.settleDeferredAt(0, section(0, 40))
    # The viewport is at 500: rows 0..39 are not what it shows, and the
    # request for what it shows is still in flight.
    check store.calltrace.lines.val.len == 0
    check store.calltrace.loadingState.val == lsLoading
    mock.settleDeferredAt(0, section(500, 40))
    check store.calltrace.startLineIndex.val == 500
    check store.calltrace.loadingState.val == lsIdle

suite "a held window is not asked for again":

  test "a scroll inside the held rows sends nothing; outside, one request":
    createRoot proc(dispose: proc()) =
      let (store, mock) = newDeferred()
      let vm = createCalltraceVM(store)
      vm.setViewport(Viewport(rows: 20, cols: 5, firstRow: 0))
      check mock.sectionRequests.len == 1
      mock.settleDeferred(section(0, 40))
      check store.calltrace.lines.val.len == 40
      mock.clearReceivedCommands()

      vm.setViewport(Viewport(rows: 20, cols: 5, firstRow: 5))
      vm.setViewport(Viewport(rows: 20, cols: 5, firstRow: 20))
      check mock.sectionRequests.len == 0
      check mock.pendingDeferredCount == 0

      vm.setViewport(Viewport(rows: 20, cols: 5, firstRow: 300))
      check mock.sectionRequests.len == 1
      check mock.sectionRequests[0].startOf == 290
      mock.settleDeferred(section(290, 50))
      dispose()

  test "a move asks again although the rows are held":
    createRoot proc(dispose: proc()) =
      let (store, mock) = newDeferred()
      let vm = createCalltraceVM(store)
      vm.setViewport(Viewport(rows: 20, cols: 5, firstRow: 0))
      mock.settleDeferred(section(0, 40))
      mock.clearReceivedCommands()
      store.updateDebuggerPosition(rrTicks = 77, file = "/src/main.py",
                                   line = 3)
      check mock.sectionRequests.len == 1
      mock.settleDeferred(section(0, 40))
      dispose()

  test "a reload asks again although the rows are held":
    createRoot proc(dispose: proc()) =
      let (store, mock) = newDeferred()
      let vm = createCalltraceVM(store)
      vm.setViewport(Viewport(rows: 20, cols: 5, firstRow: 0))
      mock.settleDeferred(section(0, 40))
      mock.clearReceivedCommands()
      vm.reloadWindow()
      check mock.sectionRequests.len == 1
      mock.settleDeferred(section(0, 40))
      dispose()

  test "a scroll inside rows a reload made stale does not drop the reload":
    # The engine changed the section under the same arguments (an
    # expansion, `reloadWindow`): the rows the store holds are stale, so
    # they must not count as held. A scroll inside them must not cancel the
    # reload and leave the old tree on screen.
    createRoot proc(dispose: proc()) =
      let (store, mock) = newDeferred()
      let vm = createCalltraceVM(store)
      vm.setViewport(Viewport(rows: 20, cols: 5, firstRow: 0))
      mock.settleDeferred(section(0, 40))
      vm.reloadWindow()                                           # in flight
      vm.setViewport(Viewport(rows: 20, cols: 5, firstRow: 5))    # inside
      while mock.pendingDeferredCount > 0:
        mock.settleDeferred(section(0, 40, name = "g"))
      check store.calltrace.lines.val.len == 40
      check store.calltrace.lines.val[0].name == "g0"
      check store.calltrace.loadingState.val == lsIdle
      dispose()

  test "scrolling back into the held rows drops the answer for the window left":
    createRoot proc(dispose: proc()) =
      let (store, mock) = newDeferred()
      let vm = createCalltraceVM(store)
      vm.setViewport(Viewport(rows: 20, cols: 5, firstRow: 0))
      mock.settleDeferred(section(0, 40))
      vm.setViewport(Viewport(rows: 20, cols: 5, firstRow: 300))  # in flight
      vm.setViewport(Viewport(rows: 20, cols: 5, firstRow: 5))    # back
      check mock.pendingDeferredCount == 1
      check store.calltrace.loadingState.val == lsIdle
      mock.settleDeferred(section(290, 50))   # the window it left
      check store.calltrace.startLineIndex.val == 0
      check store.calltrace.lines.val.len == 40
      dispose()

suite "the pane shows where the scrolled-to rows are loading":

  test "a placeholder stands at the visible rows the store does not hold":
    createRoot proc(dispose: proc()) =
      let (store, mock) = newDeferred()
      let vm = createCalltraceVM(store)
      let panel = renderCalltracePanel[MockRenderer, MockNode](MockRenderer(), vm)
      vm.setViewport(Viewport(rows: 20, cols: 5, firstRow: 0))
      mock.settleDeferred(section(0, 40))
      let ph = panel.byId("calltrace-placeholder-0")
      check not ph.isNil
      if ph.isNil:
        dispose()
        return
      check ph.styles.getOrDefault("display") == "none"

      # Rows 30..49 visible, 30..39 held: the placeholder covers 40..49.
      vm.setViewport(Viewport(rows: 20, cols: 5, firstRow: 30))
      check ph.styles.getOrDefault("display") == "block"
      check ph.attributes.getOrDefault("data-first-row") == "40"
      check ph.attributes.getOrDefault("data-rows") == "10"
      let pitch = vm.rowHeightPx.val
      check ph.styles.getOrDefault("transform") ==
        "translateY(" & $int(40.0 * pitch) & "px)"
      check ph.styles.getOrDefault("height") == $int(10.0 * pitch) & "px"

      # Far away: every visible row is a placeholder row.
      vm.setViewport(Viewport(rows: 20, cols: 5, firstRow: 600))
      check ph.styles.getOrDefault("display") == "block"
      check ph.attributes.getOrDefault("data-first-row") == "600"
      check ph.attributes.getOrDefault("data-rows") == "20"

      # The answers land: the stale one changes nothing, the current one
      # replaces the placeholder with rows.
      while mock.pendingDeferredCount > 1:
        mock.settleDeferred(section(20, 50))
      mock.settleDeferred(section(590, 50))
      check store.calltrace.startLineIndex.val == 590
      check ph.styles.getOrDefault("display") == "none"
      dispose()

  test "held rows inside the visible ones leave a placeholder on each side":
    # A viewport taller than the held section (a resize and a scroll at
    # once): the gap above the held rows and the gap below are both drawn
    # as loading, and the held rows between them are not covered.
    createRoot proc(dispose: proc()) =
      let (store, mock) = newDeferred()
      let vm = createCalltraceVM(store)
      let panel = renderCalltracePanel[MockRenderer, MockNode](MockRenderer(), vm)
      vm.setViewport(Viewport(rows: 20, cols: 5, firstRow: 300))
      mock.settleDeferred(section(290, 50))         # holds 290 ..< 340
      let above = panel.byId("calltrace-placeholder-0")
      let below = panel.byId("calltrace-placeholder-1")
      check not above.isNil and not below.isNil
      if above.isNil or below.isNil:
        dispose()
        return
      check above.styles.getOrDefault("display") == "none"
      check below.styles.getOrDefault("display") == "none"

      vm.setViewport(Viewport(rows: 70, cols: 5, firstRow: 280))   # 280..349
      let pitch = vm.rowHeightPx.val
      check above.styles.getOrDefault("display") == "block"
      check above.attributes.getOrDefault("data-first-row") == "280"
      check above.attributes.getOrDefault("data-rows") == "10"
      check above.styles.getOrDefault("transform") ==
        "translateY(" & $int(280.0 * pitch) & "px)"
      check below.styles.getOrDefault("display") == "block"
      check below.attributes.getOrDefault("data-first-row") == "340"
      check below.attributes.getOrDefault("data-rows") == "10"
      check below.styles.getOrDefault("transform") ==
        "translateY(" & $int(340.0 * pitch) & "px)"
      check below.styles.getOrDefault("height") == $int(10.0 * pitch) & "px"
      while mock.pendingDeferredCount > 0:
        mock.settleDeferred(section(270, 100))
      check above.styles.getOrDefault("display") == "none"
      check below.styles.getOrDefault("display") == "none"
      dispose()

  test "a refused window shows no loading placeholder":
    createRoot proc(dispose: proc()) =
      let (store, mock) = newDeferred()
      let vm = createCalltraceVM(store)
      let panel = renderCalltracePanel[MockRenderer, MockNode](MockRenderer(), vm)
      vm.setViewport(Viewport(rows: 20, cols: 5, firstRow: 0))
      mock.settleDeferred(%*{"success": false, "message": "busy"})
      check store.calltrace.loadingState.val == lsError
      let ph = panel.byId("calltrace-placeholder-0")
      check not ph.isNil
      if not ph.isNil:
        check ph.styles.getOrDefault("display") == "none"
      dispose()
