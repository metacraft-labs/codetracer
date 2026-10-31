## test_plat58_requests.nim — the Requests pane's shared pieces, which the
## desktop, the terminal and the GPUI window all draw from.
##
## LANE: `vm-unit`, `vm-unit-js` and `vm-unit-wasm`, by the directory glob.
##
## Spec: `GUI/Core-Panes/Request-Panel.md` § "The terminal and the GPUI window
## (PLAT-58)", N.1 – N.5.
##
## Asserted:
##
##   * THE ROW'S WORDS moved out of the desktop's view are the ViewModel's,
##     and the view still answers with them (the same symbols, re-exported):
##     the `#` column, the in-flight placeholder, the reason phrase;
##   * THE DISPLAY ROWS (`displayRows`): every cell of every row in the
##     desktop's words, each status bucket's and each verb's tone, the
##     selected row, an in-flight row's placeholders, the position of a held
##     row among all the matching ones while the engine windows them;
##   * THE COLUMNS (`requestsFit`): every column but the URL at its widest
##     cell and never cut, the URL taking the rest, its floor, and a pane
##     narrower than the floors scrolling;
##   * THE DOUBLE PRESS (`pressRow`): a press selects, a second on the same
##     request inside `RequestDoubleClickMs` activates, a late one or one on
##     another row selects again, a third starts counting afresh;
##   * THE ACTIVATION (`activate`): a seek for an ordinary row, a refusal
##     with the recorder's reason for a row with no handler step (and the
##     navigation message set), the external container handed over;
##   * THE ROW'S MENU (`rowMenu` / `runRowMenu`): its entries in order with
##     their reasons, each action's effect, a disabled entry doing nothing;
##   * THE PICKERS: their labels, the option lists the desktop draws, the
##     keyboard's moves over the held rows, clearing every filter;
##   * THE `:requests` FIELD (`requestsCommandOf`): alone it opens the field,
##     with text it searches, with nothing after the verb it clears;
##   * THE TAIL'S CADENCE (`pollTail`) and THE ONE-TIME REVEAL (`takeReveal`).
##
## NO MOCKS: the ViewModel runs for real, over no store at all for the pure
## parts (the rows are put in with `setRequests`, the entry point the desktop's
## legacy bridge uses) and over a real `ReplayDataStore` for the poll. The
## poll's transport is `BackendService` built here from three closures that
## record what was sent — the one stand-in, and why it is not a mock: the
## unit under test is the CADENCE (when a poll is due), whose whole input is
## the clock; what the engine answers to `ct/load-request-spans-since` is the
## `tui` lane's `test_plat58_requests.nim`'s, against a real `replay-server`
## on a real growing container.

import std/[json, strutils, unittest]

import isonim/core/[owner, signals, async_compat]

import ../../backend/backend_service
import ../../store/[replay_data_store, types]
import ../../viewmodels/request_panel_vm
import ../../viewmodels/table_fit
import ../../views/isonim_request_panel_view

var asserted = 0

template ck(condition: untyped) =
  inc asserted
  check condition

const ExpectedAssertions = 156

proc req(id: int; m, url: string; code, ms, size: int; geid = 0'i64;
         open = false; refused = ""; external = ""): RequestRecord =
  RequestRecord(id: id, httpMethod: m, url: url, statusCode: code,
                durationMs: ms, responseSize: size, startGeid: geid,
                isOpen: open, status: (if open: "unknown" else: "ok"),
                seekUnavailableReason: refused, externalTracePath: external)

proc demoRows(): seq[RequestRecord] =
  ## The RS-M4 demo session's eight requests (`tools/demo_request_session`'s
  ## `DemoRequests`), as the engine numbers them (span 1 is the process).
  @[req(2, "GET", "/api/users", 200, 12, 2148, 11),
    req(3, "POST", "/api/users", 201, 31, 96, 18),
    req(4, "GET", "/api/users/42", 200, 8, 512, 25),
    req(5, "GET", "/static/app.css", 304, 1, 0, 32),
    req(6, "DELETE", "/api/users/42", 404, 5, 48, 39),
    req(7, "GET", "/api/reports/slow", 200, 940, 8192, 46),
    req(8, "PUT", "/api/orders/7", 500, 220, 76, 53),
    req(9, "GET", "/health", 200, 1, 2, 60)]

suite "PLAT-58: the row's words are the ViewModel's":

  test "the moved helpers, through the ViewModel and the desktop's view":
    ck request_panel_vm.formatReqId(7) == "07"
    ck isonim_request_panel_view.formatReqId(12) == "12"
    ck InFlightPlaceholder == "—"
    ck detailStatusText(404) == "404 Not Found"
    ck statusText(req(1, "GET", "/", 0, 0, 0, open = true)) == "—"
    ck durationText(req(1, "GET", "/", 200, 1500, 0)) == "1.5s"
    ck MethodPickerOptions[0] == ("", "Method: All")
    ck StatusPickerOptions[4] == ("5xx", "5xx Server Error")

suite "PLAT-58: the display rows":

  test "every cell, every tone, in order":
    createRoot proc(dispose: proc()) =
      let vm = createRequestPanelVM(nil)
      vm.setRequests(demoRows())
      let rows = vm.displayRows()
      ck rows.len == 8
      ck rows[0].idText == "02"
      ck rows[0].httpMethod == "GET"
      ck rows[0].url == "/api/users"
      ck rows[0].status == "200"
      ck rows[0].duration == "12ms"
      ck rows[0].size == "2.0 KB"
      ck rows[0].statusTone == rtSuccess
      ck rows[0].methodTone == mtInformation
      ck rows[1].methodTone == mtSuccess          # POST
      ck rows[3].statusTone == rtRedirect         # 304
      ck rows[3].size == "0 B"
      ck rows[4].statusTone == rtClientError      # 404
      ck rows[4].methodTone == mtError            # DELETE
      ck rows[5].duration == "940ms"
      ck rows[6].statusTone == rtServerError      # 500
      ck rows[6].methodTone == mtWarning          # PUT
      ck methodTone("patch") == mtWarning
      ck methodTone("OPTIONS") == mtLabel
      ck methodTone("BREW") == mtLabel
      for i, r in rows:
        ck r.position == i and r.index == i and not r.selected
      dispose()

  test "an in-flight row and the selection":
    createRoot proc(dispose: proc()) =
      let vm = createRequestPanelVM(nil)
      vm.setRequests(@[req(2, "GET", "/a", 200, 3, 10),
                       req(3, "GET", "/slow", 0, 0, 0, open = true)])
      vm.selectRequest(1)
      let rows = vm.displayRows()
      ck rows[1].status == InFlightPlaceholder
      ck rows[1].duration == InFlightPlaceholder
      ck rows[1].statusTone == rtUnknown
      ck rows[1].isOpen
      ck rows[1].selected and not rows[0].selected
      let (ok, sel) = vm.selectedRequest()
      ck ok and sel.id == 3
      dispose()

  test "the filters hide rows and clear the selection":
    createRoot proc(dispose: proc()) =
      let vm = createRequestPanelVM(nil)
      vm.setRequests(demoRows())
      vm.selectRequest(2)
      vm.setSearchText("USERS")
      ck vm.selectedIndex.val == NO_SELECTED_INDEX
      ck vm.displayRows().len == 4
      vm.setFilterMethod("GET")
      ck vm.displayRows().len == 2
      vm.setFilterStatus("2xx")
      ck vm.displayRows().len == 2
      ck vm.methodPickerLabel == "GET"
      ck vm.statusPickerLabel == "2xx"
      ck vm.anyFilter
      vm.clearFilters()
      ck not vm.anyFilter
      ck vm.methodPickerLabel == "Method: All"
      ck vm.statusPickerLabel == "Status: All"
      ck vm.displayRows().len == 8
      dispose()

  test "a held row's place among the matching rows while windowed":
    createRoot proc(dispose: proc()) =
      let vm = createRequestPanelVM(nil)
      vm.setRequests(demoRows())
      ck not vm.windowed
      ck vm.heldIndexOf(3) == 3
      ck vm.heldIndexOf(8) == -1
      # The engine's window (`ct/load-request-spans {start, limit}`) as the
      # VM's effect installs it.
      vm.windowTotal.val = 200
      vm.windowStart.val = 40
      ck vm.windowed
      ck vm.matchingCount == 200
      ck vm.positionOf(0) == 40
      ck vm.heldIndexOf(39) == -1
      ck vm.heldIndexOf(40) == -1   # nothing held: the window's rows are not in
      dispose()

suite "PLAT-58: the columns":

  test "every column but the URL is never cut; the URL takes the rest":
    let f = requestsFit(2, 6, 17, 6, 8, 6, 80)
    ck f.mode == fmFit
    ck f.widths[0] == 2 and f.widths[1] == 6 and f.widths[3] == 6
    ck f.widths[4] == 8 and f.widths[5] == 6
    ck f.widths[2] == 80 - (2 + 6 + 6 + 8 + 6) - 5
    ck f.contentUnits == 80

  test "a narrow pane cuts the URL down to its floor, then scrolls":
    let shrink = requestsFit(2, 6, 40, 6, 8, 6, 50)
    ck shrink.mode == fmShrink
    ck shrink.widths[2] == 50 - 28 - 5
    ck shrink.widths[4] == 8
    let scroll = requestsFit(2, 6, 40, 6, 8, 6, 30)
    ck scroll.mode == fmScroll
    ck scroll.widths[2] == RequestUrlFloorCells
    ck scroll.contentUnits > 30
    ck RequestsColumnNames.len == RequestsColumnTitles.len

suite "PLAT-58: pointer and keys":

  test "a press selects; a second on the same row in time activates":
    createRoot proc(dispose: proc()) =
      let vm = createRequestPanelVM(nil)
      vm.setRequests(demoRows())
      ck vm.pressRow(2, 1000) == rpSelected
      ck vm.selectedIndex.val == 2
      ck vm.pressRow(2, 1000 + RequestDoubleClickMs) == rpActivate
      # A third press starts counting again.
      ck vm.pressRow(2, 1000 + RequestDoubleClickMs + 10) == rpSelected
      # Too late.
      ck vm.pressRow(2, 3000) == rpSelected
      # Another row in between.
      ck vm.pressRow(3, 3100) == rpSelected
      ck vm.pressRow(2, 3200) == rpSelected
      ck vm.selectedIndex.val == 2
      ck vm.pressRow(42, 3300) == rpNone
      ck vm.pressRow(2, 3350) == rpSelected   # rpNone forgot the last press
      dispose()

  test "a platform double click after the counted presses is not a second activation":
    createRoot proc(dispose: proc()) =
      var sent = 0
      let backend = BackendService(
        sendProc: proc(command: string;
                       args: JsonNode): BackendFuture[JsonNode] =
          inc sent
          newCompletedFuture[JsonNode](%*{"success": true}),
        onEventProc: proc(handler: EventHandler) = discard)
      let vm = createRequestPanelVM(createReplayDataStore(backend))
      vm.setRequests(demoRows())
      # A dblclick with no counted presses (a platform that delivers it).
      ck vm.doubleClickRow(1, 1_000)
      ck sent == 1
      # Two counted presses activate; the dblclick they make does not again.
      ck vm.pressRow(2, 5_000) == rpSelected
      ck vm.pressRow(2, 5_100) == rpActivate
      ck not vm.doubleClickRow(2, 5_110)
      # Later, a dblclick is one again.
      ck vm.doubleClickRow(2, 9_000)
      dispose()

  test "the keyboard's moves stay inside the rows held":
    createRoot proc(dispose: proc()) =
      let vm = createRequestPanelVM(nil)
      vm.setRequests(demoRows())
      ck vm.moveSelection("list.focus-next", 5) == 0
      ck vm.moveSelection("list.focus-next", 5) == 1
      ck vm.moveSelection("list.focus-page-down", 5) == 6
      ck vm.moveSelection("list.focus-page-down", 5) == 7
      ck vm.moveSelection("list.focus-previous", 5) == 6
      ck vm.moveSelection("list.focus-first", 5) == 0
      ck vm.moveSelection("list.focus-page-up", 5) == 0
      ck vm.moveSelection("list.focus-last", 5) == 7
      ck vm.moveSelection("list.activate", 5) == -1
      ck vm.selectedIndex.val == 7
      vm.selectRequest(NO_SELECTED_INDEX)
      ck vm.moveSelection("list.focus-previous", 5) == 7
      vm.setRequests(@[])
      ck vm.moveSelection("list.focus-next", 5) == -1
      dispose()

suite "PLAT-58: going to the handler":

  test "a seek, a refusal with its reason, an external container":
    createRoot proc(dispose: proc()) =
      var sent: seq[string] = @[]
      let backend = BackendService(
        sendProc: proc(command: string;
                       args: JsonNode): BackendFuture[JsonNode] =
          sent.add command & " " & $args{"geid"}.getBiggestInt(-1)
          newCompletedFuture[JsonNode](%*{"success": true}),
        onEventProc: proc(handler: EventHandler) = discard)
      let store = createReplayDataStore(backend)
      let vm = createRequestPanelVM(store)
      vm.setRequests(@[
        req(2, "GET", "/a", 200, 1, 1, geid = 77),
        req(3, "GET", "/b", 200, 1, 1, geid = 88,
            refused = "handler source steps were not recorded"),
        req(4, "GET", "/c", 200, 1, 1, geid = 99, external = "/tmp/other")])
      let a = vm.activate(0)
      ck a.kind == raSeek
      ck a.startGeid == 77
      ck sent == @["ct/seek-to-geid 77"]
      let b = vm.activate(1)
      ck b.kind == raRefused
      ck b.reason == "handler source steps were not recorded"
      ck vm.navigationMessage.val == b.reason
      ck sent.len == 1
      var opened = ""
      vm.openExternalTrace = proc(path: string; geid: int64) =
        opened = path & "@" & $geid
      let c = vm.activate(2)
      ck c.kind == raExternal
      ck c.tracePath == "/tmp/other"
      ck opened == "/tmp/other@99"
      ck sent.len == 1
      ck vm.activate(9).kind == raNone
      dispose()

suite "PLAT-58: the row's menu":

  test "its entries, in order, with their reasons":
    createRoot proc(dispose: proc()) =
      let vm = createRequestPanelVM(nil)
      vm.setRequests(@[
        req(2, "get", "/api/users", 404, 1, 1),
        req(3, "GET", "/slow", 0, 0, 0, open = true,
            refused = "excluded from instrumentation")])
      let m = vm.rowMenu(0)
      ck m.len == 5
      ck m[0].label == "Go to Handler" and m[0].enabled
      ck m[1].label == "Copy URL" and m[1].enabled
      ck m[2].label == "Filter by Method: GET" and m[2].enabled
      ck m[3].label == "Filter by Status: 4xx" and m[3].enabled
      ck m[4].label == "Clear Filters" and not m[4].enabled
      ck m[4].reason == "no filter is on"
      let open = vm.rowMenu(1)
      ck not open[0].enabled
      ck open[0].reason == "excluded from instrumentation"
      ck open[3].label == "Filter by Status: —" and not open[3].enabled
      ck open[3].reason == "the request is still in flight"
      ck vm.rowMenu(5).len == 0
      dispose()

  test "each entry's effect; a disabled entry does nothing":
    createRoot proc(dispose: proc()) =
      let vm = createRequestPanelVM(nil)
      vm.setRequests(demoRows())
      let copied = vm.runRowMenu(4, rmCopyUrl)
      ck copied.done and copied.copied == "/api/users/42"
      ck vm.runRowMenu(4, rmFilterMethod).done
      ck vm.filterMethod.val == "DELETE"
      ck vm.displayRows().len == 1
      # The filter is on now: the entry says so and does nothing.
      let again = vm.rowMenu(0)
      ck not again[2].enabled
      ck again[2].reason == "the method filter is already DELETE"
      ck not vm.runRowMenu(0, rmFilterMethod).done
      ck vm.runRowMenu(0, rmFilterStatus).done
      ck vm.filterStatus.val == "4xx"
      ck vm.rowMenu(0)[4].enabled
      ck vm.runRowMenu(0, rmClearFilters).done
      ck not vm.anyFilter
      ck vm.displayRows().len == 8
      dispose()

suite "PLAT-58: the `:requests` field":

  test "alone it opens the field; with text it searches; empty clears":
    ck requestsCommandOf(":requests") == (true, true, "")
    ck requestsCommandOf("requests") == (true, true, "")
    ck requestsCommandOf(":requests /api/users ") == (true, false, "/api/users")
    ck requestsCommandOf(":requests ") == (true, false, "")
    ck requestsCommandOf("  :REQUESTS 42") == (true, false, "42")
    ck not requestsCommandOf(":requestsx").isRequests
    ck not requestsCommandOf(":grep requests").isRequests
    ck not requestsCommandOf(":req").isRequests

suite "PLAT-58: the tail and the reveal":

  test "a poll at most every RequestSpanPollIntervalMs":
    createRoot proc(dispose: proc()) =
      var sent: seq[string] = @[]
      let backend = BackendService(
        sendProc: proc(command: string;
                       args: JsonNode): BackendFuture[JsonNode] =
          sent.add command
          newCompletedFuture[JsonNode](%*{"success": true,
            "body": {"spans": [], "cursor": 1, "reset": true}}),
        onEventProc: proc(handler: EventHandler) = discard)
      let store = createReplayDataStore(backend)
      store.setSessionMode(liveMcr)
      let vm = createRequestPanelVM(store)
      ck vm.pollTail(10_000)
      ck not vm.pollTail(10_000 + RequestSpanPollIntervalMs - 1)
      ck vm.pollTail(10_000 + RequestSpanPollIntervalMs)
      ck sent.len >= 1
      ck sent[0] == "ct/load-request-spans-since"
      ck not createRequestPanelVM(nil).pollTail(0)
      dispose()

  test "revealed once, when the session's requests are known":
    createRoot proc(dispose: proc()) =
      let vm = createRequestPanelVM(nil)
      ck not vm.takeReveal()
      vm.setRequests(demoRows())
      ck vm.takeReveal()
      ck not vm.takeReveal()
      vm.setRequests(@[])
      vm.setRequests(demoRows())
      ck not vm.takeReveal()
      dispose()

  test "the assertion count":
    check asserted == ExpectedAssertions
