## test_viewport_contract.nim — Tier 1 for the viewport contract
## (Viewport-Driven-Loading V1-V2).
##
## A view reports one `Viewport`; each windowed ViewModel turns it into a
## windowed request. For every windowed ViewModel this suite asserts:
##
##   - a viewport of R rows at row F asks for exactly the GUI's window;
##   - a burst of reports within `ViewportDebounceMs` asks once;
##   - two requests differing in any response-affecting field are both sent;
##   - an unmeasured viewport asks for nothing.
##
## The backend is `MockBackendService`: the property under test is what the
## ViewModel SENDS, which the mock records, and no engine is needed to
## observe it. The debounce runs on a `TestClock` through the store's
## injected `viewportScheduler`, so time is advanced by the test, not waited.
##
## Runs on the C and JS backends.

import std/[json, options, tables, unittest]

import isonim/core/[signals, computation, owner, clock, async_compat]

import backend/[backend_service, mock_backend]
import store/[replay_data_store, request_tracker, types]
import viewport
import viewmodels/[calltrace_vm, event_log_vm, state_vm, step_list_vm,
                  search_results_vm, source_vm, editor_vm, omnibar_sources,
                  origin_chain_vm, origin_chain_types, vcs_vm]
import session_vm
import sdk/stop_loader

proc drain() = drainPlatformCallbacks()

proc storeWithMock(): tuple[store: ReplayDataStore; mock: MockBackendService] =
  let mock = newMockBackendService(autoRespond = true)
  (createReplayDataStore(mock.toBackendService()), mock)

proc recordingStore(sent: ref seq[(string, JsonNode)]): ReplayDataStore =
  ## A store whose backend records every command and answers `{}`. For a
  ## command `MockBackendService` refuses as unknown to the engine
  ## (`ct/load-step-lines` has no engine handler yet): the property under
  ## test is what the ViewModel SENDS, not what an engine would answer.
  let backend = BackendService(
    sendProc: proc(command: string; args: JsonNode): BackendFuture[JsonNode] =
      sent[].add((command, args))
      newCompletedFuture[JsonNode](newJObject()),
    onEventProc: proc(handler: EventHandler) = discard)
  createReplayDataStore(backend)

proc sent(mock: MockBackendService; command: string): seq[JsonNode] =
  for c in mock.receivedCommands:
    if c.command == command:
      result.add c.args

suite "the window a viewport asks for":

  test "R rows at row F: TrailRows above, LeadRows below":
    let w = listWindow(Viewport(rows: 25, firstRow: 100))
    check w.start == 100 - TrailRows
    check w.count == 25 + LeadRows + TrailRows

  test "at the top there is nothing above to ask for":
    let w = listWindow(Viewport(rows: 25, firstRow: 3))
    check w.start == 0
    check w.count == 25 + LeadRows + 3

  test "an unmeasured viewport has no window":
    check listWindow(Viewport(rows: 0, firstRow: 40)).count == 0
    check not Viewport().measured

  test "a held window covers the rows a smaller one asks for":
    check covers(RowWindow(start: 10, count: 50), RowWindow(start: 20, count: 10))
    check not covers(RowWindow(start: 10, count: 50), RowWindow(start: 55, count: 10))

suite "the debounce":

  test "a burst of reports within the debounce applies the last one, once":
    let clock = newTestClock()
    var applied: seq[Viewport]
    let gate = newViewportGate(
      proc(): ViewportScheduler = testClockScheduler(clock),
      proc(v: Viewport) = applied.add v)
    gate.submit(Viewport(rows: 10))
    clock.advance(30)
    gate.submit(Viewport(rows: 12))
    clock.advance(30)
    gate.submit(Viewport(rows: 14))
    check applied.len == 0
    clock.advance(ViewportDebounceMs)
    check applied == @[Viewport(rows: 14)]

  test "without a deferring timer every report applies at once":
    var applied: seq[Viewport]
    let gate = newViewportGate(nil, proc(v: Viewport) = applied.add v)
    gate.submit(Viewport(rows: 1))
    gate.submit(Viewport(rows: 2))
    check applied == @[Viewport(rows: 1), Viewport(rows: 2)]

  test "flush applies a waiting report now":
    let clock = newTestClock()
    var applied: seq[Viewport]
    let gate = newViewportGate(
      proc(): ViewportScheduler = testClockScheduler(clock),
      proc(v: Viewport) = applied.add v)
    gate.submit(Viewport(rows: 7))
    gate.flush()
    check applied == @[Viewport(rows: 7)]
    clock.advance(ViewportDebounceMs)
    check applied.len == 1

suite "CalltraceVM on the viewport contract":

  test "R rows at row F, C columns: exactly the GUI's window and depth":
    createRoot proc(dispose: proc()) =
      let (store, mock) = storeWithMock()
      let vm = createCalltraceVM(store)
      vm.setViewport(Viewport(rows: 25, cols: 13, firstRow: 100))
      drain()
      let asked = mock.sent("ct/load-calltrace-section")
      check asked.len == 1
      check asked[^1]["startCallLineIndex"].getBiggestInt == 100 - TrailRows
      check asked[^1]["height"].getInt == 25 + LeadRows + TrailRows
      check asked[^1]["depth"].getInt == 13
      dispose()

  test "a resize burst within 100 ms asks once":
    createRoot proc(dispose: proc()) =
      let (store, mock) = storeWithMock()
      let clock = newTestClock()
      store.viewportScheduler = testClockScheduler(clock)
      let vm = createCalltraceVM(store)
      for rows in [10, 11, 12, 13, 14]:
        vm.setViewport(Viewport(rows: rows))
        clock.advance(10)
      drain()
      check mock.sent("ct/load-calltrace-section").len == 0
      clock.advance(ViewportDebounceMs)
      drain()
      let asked = mock.sent("ct/load-calltrace-section")
      check asked.len == 1
      check asked[^1]["height"].getInt == 14 + LeadRows
      dispose()

  test "requests differing only in the filter are both sent":
    createRoot proc(dispose: proc()) =
      # Answers withheld, so the first request is still in flight when the
      # second is issued: only the request key can tell them apart.
      let mock = newMockBackendService(autoRespond = false)
      let store = createReplayDataStore(mock.toBackendService())
      let vm = createCalltraceVM(store)
      vm.setViewport(Viewport(rows: 10))
      vm.setRawIgnorePatterns("path~lib/system")
      let asked = mock.sent("ct/load-calltrace-section")
      check asked.len == 2
      check asked[0]["rawIgnorePatterns"].getStr == ""
      check asked[1]["rawIgnorePatterns"].getStr == "path~lib/system"
      dispose()

  test "an identical request in flight is not sent twice":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = false)
      let store = createReplayDataStore(mock.toBackendService())
      let vm = createCalltraceVM(store)
      vm.setViewport(Viewport(rows: 10))
      vm.setViewport(Viewport(rows: 10))
      check mock.sent("ct/load-calltrace-section").len == 1
      dispose()

  test "an unmeasured pane asks for nothing, even after a move":
    createRoot proc(dispose: proc()) =
      let (store, mock) = storeWithMock()
      discard createCalltraceVM(store)
      store.updateDebuggerPosition(42'u64, "main.nim", 3)
      drain()
      check mock.sent("ct/load-calltrace-section").len == 0
      dispose()

suite "EventLogVM on the viewport contract":

  test "R rows at row F: exactly the GUI's window":
    createRoot proc(dispose: proc()) =
      let (store, mock) = storeWithMock()
      let vm = createEventLogVM(store)
      vm.setViewport(Viewport(rows: 30, firstRow: 200))
      drain()
      let asked = mock.sent("ct/event-load")
      check asked.len == 1
      check asked[^1]["start"].getInt == 200 - TrailRows
      check asked[^1]["count"].getInt == 30 + LeadRows + TrailRows
      check vm.currentPage.val == 200 div 30
      dispose()

  test "a scroll burst within 100 ms asks once":
    createRoot proc(dispose: proc()) =
      let (store, mock) = storeWithMock()
      let clock = newTestClock()
      store.viewportScheduler = testClockScheduler(clock)
      let vm = createEventLogVM(store)
      for first in [0, 5, 10, 15]:
        vm.setViewport(Viewport(rows: 30, firstRow: first))
        clock.advance(20)
      drain()
      check mock.sent("ct/event-load").len == 0
      clock.advance(ViewportDebounceMs)
      drain()
      let asked = mock.sent("ct/event-load")
      check asked.len == 1
      check asked[^1]["start"].getInt == 15 - TrailRows
      dispose()

  test "the search is part of the request and of its key":
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = false)
      let store = createReplayDataStore(mock.toBackendService())
      let vm = createEventLogVM(store)
      vm.setViewport(Viewport(rows: 30))
      vm.setSearchQuery("tick")
      let asked = mock.sent("ct/event-load")
      check asked.len == 2
      check not asked[0].hasKey("search")
      check asked[1]["search"].getStr == "tick"
      dispose()

  test "a search typed in the filter bar asks for its results from the top":
    # The engine cuts the window from the MATCHING events, so a search asked
    # at the old scroll offset answers rows past the end of a short result
    # list: an empty pane over results that exist. `setSearchQuery` scrolls
    # to the top; the filter bar's `setFilterInput` must too, through the
    # viewport — `currentPage` is derived from it and moves no window.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = false)
      let store = createReplayDataStore(mock.toBackendService())
      let vm = createEventLogVM(store)
      vm.setViewport(Viewport(rows: 30, firstRow: 200))
      vm.setFilterInput("tick")
      let asked = mock.sent("ct/event-load")
      check asked.len == 2
      check asked[^1]["search"].getStr == "tick"
      check asked[^1]["start"].getInt == 0
      check vm.viewport.val.firstRow == 0
      check vm.currentPage.val == 0
      dispose()

  test "the filter bar's shorthands are not sent as search text":
    # `boundary:<id>` and `unmatched` select marker rows on the client
    # (Correlation-Markers §5.4). The engine's `search` matches text — event
    # content and path, a marker's boundary, key and shown value — so sent as
    # text they would match nothing and empty the pane.
    # Only the free text beside them is the log's search.
    createRoot proc(dispose: proc()) =
      let mock = newMockBackendService(autoRespond = false)
      let store = createReplayDataStore(mock.toBackendService())
      let vm = createEventLogVM(store)
      vm.setViewport(Viewport(rows: 30))
      vm.setFilterInput("boundary:order-processing tick")
      var asked = mock.sent("ct/event-load")
      check asked.len == 2
      check asked[^1]["search"].getStr == "tick"
      check vm.filterBar.val.boundaryFilter == "order-processing"
      # Only shorthands: no search at all, so the pane asks for the
      # unsearched window again.
      vm.setFilterInput("boundary:order-processing unmatched")
      asked = mock.sent("ct/event-load")
      check asked.len == 3
      check not asked[^1].hasKey("search")
      check vm.filterBar.val.unmatchedOnly
      dispose()

  test "a live stop during a search leaves the matches and their count":
    # The rows on hand are the engine's answer to the search. Whether a live
    # stop matches is the engine's question: the stop does not join the
    # matches, the pager keeps counting them, and only the recording's extent
    # grows. Without a search the stop joins the window as before.
    createRoot proc(dispose: proc()) =
      let backend = BackendService(
        sendProc: proc(command: string; args: JsonNode): BackendFuture[JsonNode] =
          let total = if args.hasKey("search"): 15 else: 100
          newCompletedFuture[JsonNode](%*{"events": [], "total": total}),
        onEventProc: proc(handler: EventHandler) = discard)
      let store = createReplayDataStore(backend)
      let vm = createEventLogVM(store)
      vm.setViewport(Viewport(rows: 10))
      vm.setSearchQuery("tick")
      drain()
      check vm.totalPages.val == 2
      vm.appendLiveDebuggerStop(EventLogRow(eventId: 500'u64, rrTicks: 500'u64,
                                            maxRRTicks: 500'u64, value: "stop"))
      check vm.eventRows.val.len == 0
      check vm.totalPages.val == 2
      check store.eventLog.maxRRTicks.val == 500'u64
      vm.setSearchQuery("")
      drain()
      vm.appendLiveDebuggerStop(EventLogRow(eventId: 501'u64, rrTicks: 501'u64,
                                            maxRRTicks: 501'u64, value: "stop"))
      check vm.eventRows.val.len == 1
      dispose()

  test "a search's pages are counted from its matches, not from the log":
    # The engine's `total` is the size of the SEARCHED list. A pager that
    # kept counting the whole log would offer pages past the last match,
    # each of them empty. The backend answers the way `event_load` does:
    # `total` is 100 events, or the 15 that match when the request searches.
    createRoot proc(dispose: proc()) =
      let backend = BackendService(
        sendProc: proc(command: string; args: JsonNode): BackendFuture[JsonNode] =
          let total = if args.hasKey("search"): 15 else: 100
          newCompletedFuture[JsonNode](%*{"events": [], "total": total}),
        onEventProc: proc(handler: EventHandler) = discard)
      let store = createReplayDataStore(backend)
      let vm = createEventLogVM(store)
      vm.setViewport(Viewport(rows: 10))
      drain()
      check vm.totalPages.val == 10
      vm.setSearchQuery("tick")
      drain()
      check vm.totalPages.val == 2
      # The whole log's size is still known, for a footer's "of N".
      check vm.totalEventCount.val == 100
      # And the pager stops at the last page of matches.
      vm.nextPage()
      vm.nextPage()
      check vm.currentPage.val == 1
      vm.setSearchQuery("")
      drain()
      check vm.totalPages.val == 10
      dispose()

  test "an unmeasured pane asks for nothing":
    createRoot proc(dispose: proc()) =
      let (store, mock) = storeWithMock()
      let vm = createEventLogVM(store)
      vm.setSearchQuery("x")
      vm.sort(1)
      drain()
      check mock.sent("ct/event-load").len == 0
      dispose()

suite "StepListVM on the viewport contract":

  test "R rows: the R rows either side of the line":
    createRoot proc(dispose: proc()) =
      let sent = new(seq[(string, JsonNode)])
      let vm = createStepListVM(recordingStore(sent))
      vm.setViewport(Viewport(rows: 12))
      vm.loadStepLinesFor(StepLineLocation(path: "a.nim", line: 3, rrTicks: 5))
      check sent[].len == 1
      check sent[][^1][0] == "ct/load-step-lines"
      check sent[][^1][1]["forwardCount"].getInt == 12
      check sent[][^1][1]["backwardCount"].getInt == 12
      dispose()

  test "an unmeasured list asks for nothing":
    createRoot proc(dispose: proc()) =
      let sent = new(seq[(string, JsonNode)])
      let vm = createStepListVM(recordingStore(sent))
      vm.loadStepLinesFor(StepLineLocation(path: "a.nim", line: 3, rrTicks: 5))
      check sent[].len == 0
      dispose()

suite "SearchResultsVM on the viewport contract":

  test "the viewport selects the rows a windowed view renders":
    createRoot proc(dispose: proc()) =
      let (store, _) = storeWithMock()
      let vm = createSearchResultsVM(store)
      var rows: seq[SearchResultLine]
      for i in 0 ..< 50:
        rows.add SearchResultLine(path: "f.nim", line: i + 1)
      vm.setResults(rows)
      check vm.visibleResults.val.len == 50
      vm.setViewport(Viewport(rows: 10, firstRow: 20))
      check vm.visibleResults.val.len == 10
      check vm.visibleResults.val[0].line == 21
      dispose()

suite "SourceVM on the viewport contract":

  test "a size-only report keeps the scroll where the ViewModel put it":
    createRoot proc(dispose: proc()) =
      let (store, _) = storeWithMock()
      let src = createSourceVM(store, createEditorVM(store))
      src.setViewport(Viewport(rows: 20))
      src.scrollTo(40)
      src.setViewport(src.viewport.withRows(30))
      check src.viewportHeight.val == 30
      check src.viewportTop.val == 40
      dispose()

  test "an unmeasured report changes nothing":
    createRoot proc(dispose: proc()) =
      let (store, _) = storeWithMock()
      let src = createSourceVM(store, createEditorVM(store))
      src.setViewport(Viewport(rows: 20))
      src.setViewport(Viewport(rows: 0))
      check src.viewportHeight.val == 20
      dispose()

suite "value history follows the stop":

  test "a move drops the cached histories and asks again for the open ones":
    createRoot proc(dispose: proc()) =
      let (store, _) = storeWithMock()
      let vm = createStateVM(store)
      var asked: seq[string]
      vm.onToggleHistory = proc(expression: string) = asked.add expression
      store.updateDebuggerPosition(10'u64, "main.nim", 3)
      vm.toggleHistory("total")
      check asked == @["total"]
      vm.updateHistory("total", @[ValueHistoryRow(locationTicks: 4, valueText: "1")])
      check vm.valueHistory.val.len == 1
      # The same stop again asks nothing and keeps the history.
      store.updateDebuggerPosition(10'u64, "main.nim", 3)
      check asked.len == 1
      check vm.valueHistory.val.len == 1
      # Another stop: the history was about the old one.
      store.updateDebuggerPosition(20'u64, "main.nim", 7)
      check vm.valueHistory.val.len == 0
      check asked == @["total", "total"]
      dispose()

  test "a closed history is not asked for again":
    createRoot proc(dispose: proc()) =
      let (store, _) = storeWithMock()
      let vm = createStateVM(store)
      var asked: seq[string]
      vm.onToggleHistory = proc(expression: string) = asked.add expression
      store.updateDebuggerPosition(10'u64, "main.nim", 3)
      vm.toggleHistory("total")
      vm.toggleHistory("total")
      store.updateDebuggerPosition(20'u64, "main.nim", 7)
      check asked == @["total"]
      dispose()

suite "the call-trace search asks for the pane's window of results":

  test "a measured pane limits the search to its window":
    createRoot proc(dispose: proc()) =
      let (store, mock) = storeWithMock()
      let vm = createCalltraceVM(store)
      vm.setViewport(Viewport(rows: 30))
      vm.setSearchQuery("calc")
      let asked = mock.sent("ct/search-calltrace")
      check asked.len == 1
      check asked[0]["value"].getStr == "calc"
      check asked[0]["limit"].getInt == 30 + LeadRows
      dispose()

  test "an unmeasured consumer asks for every match":
    createRoot proc(dispose: proc()) =
      let (store, mock) = storeWithMock()
      let vm = createCalltraceVM(store)
      vm.setSearchQuery("calc")
      let asked = mock.sent("ct/search-calltrace")
      check asked.len == 1
      check not asked[0].hasKey("limit")
      dispose()

suite "the current position's event index is asked once per tick":

  test "the same tick is not asked again; a new tick is":
    let mock = newMockBackendService(autoRespond = true)
    let store = createReplayDataStore(mock.toBackendService())
    store.requestEventIndexAt(10'u64)
    store.requestEventIndexAt(10'u64)
    drain()
    store.requestEventIndexAt(10'u64)
    store.requestEventIndexAt(11'u64)
    check mock.sent("ct/event-load").len == 2

suite "the request-span tail":

  test "a completed recording is counted once and never tailed":
    # Its rows are the panel's window (`RequestPanelVM.setViewport`); the
    # poll only learns how many requests there are, once.
    let mock = newMockBackendService(autoRespond = true)
    let store = createReplayDataStore(mock.toBackendService())
    store.requestRequestSpansSince()
    drain()
    store.requestRequestSpansSince()
    store.requestRequestSpansSince()
    check mock.sent("ct/load-request-spans-since").len == 0
    check mock.sent("ct/load-request-spans").len == 1
    check mock.sent("ct/load-request-spans")[0]["limit"].getInt == 1

  test "a live session keeps polling":
    let mock = newMockBackendService(autoRespond = true)
    let store = createReplayDataStore(mock.toBackendService())
    var session = store.session.val
    session.debugSessionMode = liveMcr
    store.session.val = session
    store.requestRequestSpansSince()
    drain()
    store.requestRequestSpansSince()
    drain()
    check mock.sent("ct/load-request-spans-since").len == 2

suite "the locals budget follows the state pane":

  test "unmeasured: the GUI's constant; measured: the pane's rows":
    check localsCountBudgetFor(Viewport()) == LocalsCountBudget
    check localsCountBudgetFor(Viewport(rows: 30)) == LocalsCountBudget
    check localsCountBudgetFor(Viewport(rows: 10, firstRow: 50)) ==
      (10 + LeadRows + TrailRows) * LocalsMinCountLimit

  test "the stop loader asks with the state pane's budget":
    let mock = newMockBackendService(autoRespond = true)
    let session = createSessionVM(mock.toBackendService())
    session.store.claimLocalsLoading()
    session.initializePanelViewModels()
    session.stateVM.setViewport(Viewport(rows: 10))
    session.store.updateDebuggerPosition(5'u64, "main.nim", 2)
    let loader = createStopLoader(session)
    loader.loadStop()
    let asked = mock.sent("ct/load-locals")
    check asked.len == 1
    check asked[0]["countBudget"].getInt ==
      (10 + LeadRows + TrailRows) * LocalsMinCountLimit

suite "the omnibar's symbols are the recording's functions":

  test "the engine's list, each going to its first call":
    let (store, _) = storeWithMock()
    store.applySymbolsResponse(%*{"symbols": [
      {"name": "calc", "path": "/src/calc.rs", "line": 3, "firstCallTicks": 40},
      {"name": "main", "path": "/src/main.rs", "line": 1, "firstCallTicks": 1}]})
    let found = symbolsOf(store)
    check found.len == 2
    check found[0].label == "calc"
    check found[0].target == "40"
    check found[0].detail == "calc.rs:3"

suite "origin chains":

  test "only the answer to the latest request, not cancelled, is applied":
    let (store, _) = storeWithMock()
    let vm = createOriginChainVM(store)
    let chainA = OriginChain(hops: @[OriginHop(targetExpr: "a")])
    let chainB = OriginChain(hops: @[OriginHop(targetExpr: "b")])
    vm.noteChainRequestSent("0:1")
    vm.noteChainRequestSent("0:2")
    # The older request's answer arrives late: not applied.
    check not vm.applyChainAnswer(chainA, "0:1")
    check vm.activeChain.val.isNone
    check vm.applyChainAnswer(chainB, "0:2")
    check vm.activeChain.val.get.hops[0].targetExpr == "b"
    # After a cancel, the cancelled request's answer is not applied.
    vm.noteChainRequestSent("0:3")
    vm.onCancelLoad()
    check not vm.applyChainAnswer(chainA, "0:3")
    check vm.activeChain.val.get.hops[0].targetExpr == "b"

  test "the summary fill goes on to the next batch":
    let mock = newMockBackendService(autoRespond = true)
    let store = createReplayDataStore(mock.toBackendService())
    let vm = createOriginChainVM(store)
    vm.enqueuePlaceholderFill("t1")
    vm.flushPlaceholderFill()
    # Queued while the first batch is in flight.
    vm.enqueuePlaceholderFill("t2")
    drain()
    # The first answer was applied and the fill moved on to the second batch.
    check mock.sent("ct/originSummary").len == 2
    drain()
    check not vm.inFlightSummary.val

suite "the VCS history reads what its list shows":

  test "the rows up to the last visible one, plus the lead":
    check historyCommitCount(Viewport()) == VcsHistoryUnmeasured
    check historyCommitCount(Viewport(rows: 20, firstRow: 40)) ==
      40 + 20 + LeadRows

suite "request bookkeeping":

  test "an older answer does not release a newer request's key":
    let t = newRequestTracker()
    t.markPending("k", "new")
    t.markComplete("k", "old")
    check t.isDuplicate("k", "new")
