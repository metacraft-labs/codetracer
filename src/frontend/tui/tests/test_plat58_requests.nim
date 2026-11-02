## test_plat58_requests.nim — the Requests pane on the terminal, Tier 1: the
## painter, its hit-testing and the runtime over a REAL `replay-server` on a
## container carrying request spans.
##
## Spec: `codetracer-pm` `spec/GUI/Core-Panes/Request-Panel.md` § "The terminal
## and the GPUI window (PLAT-58)".
##
## The recording is the RS-M4 demo session (`src/tools/demo_request_session`,
## the producer `just demo-request-panel` runs): a real `.ct` container written
## by the canonical writer, with eight requests over a recorded Python
## timeline, opened by the real engine. Asserted:
##
##   1. THE REVEAL — the recording serves requests, so the docked REQUESTS
##      pane opens by itself (once): before the idle tick it is a label, after
##      it the pane is on screen with its rows;
##   2. THE ROWS EQUAL THE DESKTOP'S — the terminal's painted rows, cell for
##      cell, against the desktop's own view (`isonim_request_panel_view.
##      renderRequestPanel`, its DOM read back) over the SAME session store,
##      and against the producer's input table (`DemoRequests`) formatted
##      here by hand: the oracle reads neither the painter nor the
##      ViewModel's helpers — and against the REAL Electron app's rows on the
##      same session (`src/tests/visual/answers/plat58-requests.electron.json`,
##      `just plat58-capture-electron`);
##   3. THE COLOURS — each status in its bucket's role, each method in its
##      badge's role, the selected row on the selection ground;
##   4. THE FILTERS — `:requests <text>`, the Method and Status pickers'
##      dropdowns (the desktop's options, the current one hinted), the row
##      menu's Filter by / Clear Filters — every result equal to the desktop
##      view's rows over the same store;
##   5. A DOUBLE PRESS GOES TO THE HANDLER — one press selects and moves
##      nothing; two in time move the recording to the request's handler
##      entry (its step, the producer's arithmetic: `6 + 7 i`), the editor to
##      the handler's line and the Call Trace to the request's call; a late
##      second press does not;
##   6. THE MENU — a right press opens the row's entries (Go to Handler, Copy
##      URL, Filter by Method, Filter by Status, Clear Filters) with their
##      reasons, equal to the real desktop's menu on the same row; Go to
##      Handler moves; Copy URL copies;
##   7. KEYS — with the pane focused, Down / End / Home move the selection,
##      Enter goes to its handler, Ctrl+C copies the URL, Escape clears;
##   8. THE WINDOW — a pane shorter than the list reports the rows it shows
##      and the engine answers that window; the wheel scrolls it and the
##      scrollbar is drawn;
##   9. THE LIVE TAIL — over a container that GROWS under the engine (the
##      producer's stages renamed into place), new rows arrive within a poll,
##      an in-flight row shows `—` and settles in place.
##
## THE STAND-INS, and why neither is a mock: the live tail needs a session
## the store calls live, and no native front-end opens a live MCR session yet
## — so case 9 declares the session live through the store's own
## `setSessionMode(liveMcr)`, which is exactly what the desktop does when its
## live session is selected (`ui_js.handleDapLiveSessionSelected`); the
## container, its growth and the engine's tail are real. And time: the double
## press is judged on the clock the runtime is handed (`handleToken`'s
## `nowMs`), which this suite supplies — the clock IS the input of the rule
## under test. Nothing else is stood in for.

import std/[json, os, strutils, tables, unittest]
from std/unicode import runes, `$`

import results
import isonim/testing/mock_dom
import headless_session
import headless_app/pane_clicks
import headless_app/layout_model
import codetracer_embed
import views/isonim_request_panel_view
import view_vocabulary/pane_views
import ../../../common/view_vocabulary

import ../app/runtime
import ../app/tui_app
import ../app/theme/capabilities
import ../app/theme/roles
import ../app/views/requests_pane
import ../app/views/shell
import ../app/views/styled_row
import ../host/tui_session
import ../../viewmodel/host/native_requests_host
import ../../../tools/demo_request_session

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads this spelling
# as the suite's RUNTIME assertion count.
const ExpectedAssertions = 126

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  Cols = 160
  Rows = 90
  Enter = "\r"
  Esc = "\x1b"
  Down = "\x1b[B"
  EndKey = "\x1b[F"
  HomeKey = "\x1b[H"
  CtrlC = "\x03"

proc newRuntime(width = Cols; height = Rows): TuiRuntime =
  let caps = resolveCapabilities(
    initTerminalEnv(term = "xterm-256color", colorterm = "truecolor",
                    lang = "en_US.UTF-8"), initCapabilityFlags())
  result = newTuiRuntime(newTuiApp(), caps, width, height)
  discard result.enableLayoutBinding()
  result.refreshMenuForKeymap()

proc sgr(code, row, col: int; release = false): string =
  "\x1b[<" & $code & ";" & $(col + 1) & ";" & $(row + 1) &
    (if release: "m" else: "M")

proc send(s: TuiSession; rt: TuiRuntime; token: string; nowMs = 0'i64) =
  let outcome = rt.handleToken(token, nowMs)
  s.applyOutcome(rt, outcome)

proc command(s: TuiSession; rt: TuiRuntime; line: string) =
  s.send(rt, ":")
  for ch in line:
    s.send(rt, $ch)
  s.send(rt, Enter)

proc open(path: string; width = Cols; height = Rows): (TuiRuntime, TuiSession) =
  let rt = newRuntime(width, height)
  let s = openTuiSession(path, viewportHeight = height - 8)
  s.header(rt)
  s.learnExtent()
  rt.app.requestsAct = proc(act: RequestsAct): RequestsActResult =
    s.requestsAct(rt, act)
  s.refresh(rt)
  (rt, s)

proc demoSession(name: string; through = DemoRequests.len;
                 openOnly = false): string =
  ## The RS-M4 producer's session in a fresh folder.
  result = getTempDir() / "plat58-" & name & "-" & $getCurrentProcessId()
  createDir(result)
  let written = writeDemoRequestSession(result, through, openOnly)
  doAssert written.isOk, written.error

# ---- the oracles ------------------------------------------------------------

proc electronAnswers(): JsonNode =
  ## The REAL desktop's panel on the same demo session
  ## (`plat58-requests-capture.spec.ts`, `just plat58-capture-electron`).
  let repo = currentSourcePath().parentDir.parentDir.parentDir.parentDir.parentDir
  parseJson(readFile(repo / "src/tests/visual/answers/plat58-requests.electron.json"))

proc handSize(bytes: int): string =
  ## `request_panel.styl`'s Size column, by hand: B, then one decimal KB.
  if bytes < 1024: $bytes & " B"
  else: $(bytes div 1024) & "." & $((bytes mod 1024) * 10 div 1024) & " KB"

proc handDuration(ms: int): string =
  if ms < 1000: $ms & "ms" else: $(ms div 1000) & "." & $((ms mod 1000) div 100) & "s"

proc oracleRow(i: int): seq[string] =
  ## Request `i` of the producer's table, as the desktop's columns show it.
  let d = DemoRequests[i]
  let id = i + 2
  @[(if id < 10: "0" & $id else: $id), d.httpMethod, d.url, $d.statusCode,
    handDuration(d.durationMs), handSize(d.responseSize)]

proc desktopRows(vm: RequestPanelVM): seq[seq[string]] =
  ## The DESKTOP's rows: its view rendered over `vm` and its DOM read back,
  ## one cell per `request-col-*` child.
  let r = MockRenderer()
  let panel = renderRequestPanel[MockRenderer, MockNode](r, vm)
  proc find(n: MockNode; cls: string): MockNode =
    if n.kind == mnkElement:
      for part in n.attributes.getOrDefault("class", "").split(' '):
        if part == cls:
          return n
    for c in n.children:
      let f = find(c, cls)
      if f != nil:
        return f
  let body = find(panel, "request-table-body")
  for row in body.children:
    var cells: seq[string] = @[]
    for c in row.children:
      cells.add textContent(c).strip()
    result.add cells

proc paneRows(rt: TuiRuntime): seq[seq[string]] =
  ## The terminal's painted rows, split back into their six cells.
  let (_, screen) = rt.requestsPaneScreen()
  for line in screen.painted:
    if line.len == 0:
      continue
    let parts = line.splitWhitespace()
    # id, method, then the URL (one word in this recording), status,
    # duration, size (`N B` / `N.N KB` are two words).
    result.add @[parts[0], parts[1], parts[2], parts[3], parts[4],
                 parts[5 .. ^1].join(" ")]

proc rowOnScreen(rt: TuiRuntime; id: int): tuple[row, col: int] =
  ## Where the request `id`'s row is painted (its URL cell), (-1, -1) off.
  let (_, screen) = rt.requestsPaneScreen()
  let m = rt.app.requests
  for k in 0 ..< screen.listRows:
    let i = m.rowAt(screen.top + k)
    if i >= 0 and m.rows[i].id == id:
      return (screen.listTop + k, screen.tableLeft + screen.fit.starts[2] + 1)
  (-1, -1)

proc pressRow(s: TuiSession; rt: TuiRuntime; id: int; nowMs: int64;
              button = 0) =
  let (row, col) = rt.rowOnScreen(id)
  doAssert row >= 0, "request " & $id & " is not on screen"
  s.send(rt, sgr(button, row, col), nowMs)
  s.send(rt, sgr(button, row, col, release = true), nowMs)

proc menuLabels(rt: TuiRuntime): seq[string] =
  for e in rt.app.contextMenu.menu.entries:
    result.add e.label

proc chooseMenu(s: TuiSession; rt: TuiRuntime; label: string) =
  ## Choose the open menu's entry `label` FROM THE KEYBOARD, as a user does:
  ## Down until it is the selected one, then Enter.
  var want = -1
  for i, e in rt.app.contextMenu.menu.entries:
    if e.label == label:
      want = i
  doAssert want >= 0, "no menu entry " & label
  for _ in 0 .. rt.app.contextMenu.menu.entries.len:
    if rt.app.contextMenu.selected == want:
      break
    s.send(rt, Down)
  doAssert rt.app.contextMenu.selected == want, label & " is not selectable"
  s.send(rt, Enter)

proc roleOf(rt: TuiRuntime; row, col: int): SemanticRole =
  let screen = shellScreenOf(rt)
  var at = 0
  for span in screen.styledRows[row]:
    let w = cellWidthOf(span.text)
    if col >= at and col < at + w:
      return span.style.role
    at += w
  srNone

proc charAt(rt: TuiRuntime; row, col: int): string =
  ## The character painted in cell (`row`, `col`), "" past the row.
  let screen = shellScreenOf(rt)
  var at = 0
  for span in screen.styledRows[row]:
    for r in span.text.runes:
      let w = cellWidthOf($r)
      if col >= at and col < at + w:
        return $r
      at += w
  ""

proc surfaceOf(rt: TuiRuntime; row, col: int): SemanticRole =
  let screen = shellScreenOf(rt)
  var at = 0
  for span in screen.styledRows[row]:
    let w = cellWidthOf(span.text)
    if col >= at and col < at + w:
      return span.style.surface
    at += w
  srNone

# ---------------------------------------------------------------------------

suite "PLAT-58 Tier 1: the Requests pane over a real engine":

  let folder = demoSession("full")
  var (rt, s) = open(folder)
  let vm = s.session.requestsVM

  test "1. the recording serves requests: the pane reveals itself, once":
    let before = rt.app.layoutBinding.layout
    let at = before.dockedIndex(paneRequests)
    ck at >= 0                                   # docked by the default
    ck not before.docked[at].open
    ck rt.app.requests.rows.len == 0             # not on screen: nothing asked
    ck s.pumpRequests(rt, 1_000)
    let after = rt.app.layoutBinding.layout
    ck after.docked[after.dockedIndex(paneRequests)].open
    ck rt.app.requests.total == DemoRequests.len
    ck rt.app.requests.rows.len == DemoRequests.len
    # Once: the user closes it and the next tick leaves it closed.
    discard rt.app.layoutBinding.dispatch(cmdCloseDocked(paneRequests))
    discard s.pumpRequests(rt, 2_000)
    let closed = rt.app.layoutBinding.layout
    ck not closed.docked[closed.dockedIndex(paneRequests)].open
    discard rt.app.layoutBinding.dispatch(cmdOpenDocked(paneRequests))
    s.refresh(rt)

  test "2. the rows equal the desktop's view and the producer's table":
    let painted = rt.paneRows()
    let desktop = desktopRows(vm)
    ck painted.len == DemoRequests.len
    ck desktop.len == DemoRequests.len
    let electron = electronAnswers()["rows"]
    ck electron.len == DemoRequests.len
    for i in 0 ..< DemoRequests.len:
      checkpoint("request " & $(i + 2) & ": terminal " & $painted[i] &
                 " desktop " & $desktop[i])
      ck painted[i] == oracleRow(i)
      ck desktop[i] == oracleRow(i)
      # …and the REAL desktop's, read from Electron's DOM.
      var cells: seq[string] = @[]
      for c in electron[i]["cells"]: cells.add c.getStr
      ck painted[i] == cells
    # The header, in the desktop's words.
    let (area, screen) = rt.requestsPaneScreen()
    let shellScreen = shellScreenOf(rt)
    let header = shellScreen.styledRows[screen.headerRow].rowText
    for title in ["#", "method", "URL", "Status", "Duration", "Size"]:
      ck title in header
    ck RequestSearchPlaceholder in
      shellScreen.styledRows[area.row].rowText
    ck "Method: All" in shellScreen.styledRows[area.row].rowText
    ck "Status: All" in shellScreen.styledRows[area.row].rowText
    # The vocabulary's view of the pane (what a front-end without a native
    # painter draws): the filter bar's words and a table of the same rows.
    let pv = requestsPaneView(vm)
    ck pv.pane == paneRequests
    ck pv.report.len == 0
    ck pkTable in pv.entries
    var tableRows: seq[seq[string]] = @[]
    for c in pv.root.children:
      if c.kind == pkTable:
        tableRows = c.rows
    ck tableRows.len == DemoRequests.len
    if tableRows.len > 0:
      ck tableRows[0] == oracleRow(0)

  test "3. the desktop's colours":
    let (_, screen) = rt.requestsPaneScreen()
    let col = screen.tableLeft
    for i in 0 ..< DemoRequests.len:
      let y = screen.listTop + i
      let statusCol = col + screen.fit.starts[3] + screen.fit.widths[3] - 1
      let methodCol = col + screen.fit.starts[1]
      let want = case DemoRequests[i].statusCode div 100
                 of 2: srChromeSuccess
                 of 3: srChromeInfo
                 of 4: srChromeNotification
                 else: srChromeError
      ck rt.roleOf(y, statusCol) == want
      # The status is right-aligned in its column, as the desktop's
      # `flex-end`: its last digit is in the column's last cell.
      ck rt.charAt(y, statusCol) == ($DemoRequests[i].statusCode)[^1 .. ^1]
      let wantMethod = case DemoRequests[i].httpMethod
                       of "GET": srChromeInfo
                       of "POST": srChromeSuccess
                       of "DELETE": srChromeError
                       else: srChromeNotification
      ck rt.roleOf(y, methodCol) == wantMethod

  test "4. the filters, equal to the desktop's":
    s.command(rt, "requests users")
    ck vm.searchText.val == "users"
    var ids: seq[int] = @[]
    for r in rt.app.requests.rows: ids.add r.id
    ck ids == @[2, 3, 4, 6]
    ck rt.paneRows() == desktopRows(vm)
    # The Method picker: the desktop's options, the current one hinted.
    let (area, screen) = rt.requestsPaneScreen()
    s.send(rt, sgr(0, area.row, screen.methodCol + 2))
    s.send(rt, sgr(0, area.row, screen.methodCol + 2, release = true))
    ck rt.app.contextMenu.open
    ck rt.menuLabels == @["Method: All", "GET", "POST", "PUT", "DELETE",
                          "PATCH", "HEAD", "OPTIONS"]
    ck rt.app.contextMenu.menu.entries[0].hint == RequestPickerCurrentHint
    s.chooseMenu(rt, "DELETE")
    ck vm.filterMethod.val == "DELETE"
    ids = @[]
    for r in rt.app.requests.rows: ids.add r.id
    ck ids == @[6]
    ck rt.paneRows() == desktopRows(vm)
    # The Status picker.
    let (area2, screen2) = rt.requestsPaneScreen()
    s.send(rt, sgr(0, area2.row, screen2.statusCol + 2))
    s.send(rt, sgr(0, area2.row, screen2.statusCol + 2, release = true))
    ck rt.menuLabels == @["Status: All", "2xx Success", "3xx Redirect",
                          "4xx Client Error", "5xx Server Error"]
    s.chooseMenu(rt, "2xx Success")
    ck rt.app.requests.rows.len == 0              # DELETE and 2xx: none
    ck rt.app.requests.total == 0
    ck desktopRows(vm).len == 0
    # The bare verb with a search on clears it (the field emptied and
    # submitted); with none it opens the field, holding the search.
    s.command(rt, "requests")
    ck vm.searchText.val == ""
    s.command(rt, "requests")
    ck rt.app.omnibar.isOpen
    ck rt.app.omnibar.query == ":requests "
    s.send(rt, Esc)
    vm.clearFilters()
    s.refresh(rt)
    ck rt.app.requests.rows.len == DemoRequests.len

  test "5. a double press goes to the handler; the Call Trace follows":
    let tickBefore = s.session.getCurrentRRTicks()
    # One press selects and moves nothing.
    s.pressRow(rt, 4, 10_000)
    ck rt.app.requests.selected == 2
    ck s.session.getCurrentRRTicks() == tickBefore
    ck rt.app.requests.detail.shown
    ck rt.app.requests.detail.status == "200 OK"
    # A second press, too late: still a selection.
    s.pressRow(rt, 4, 10_000 + RequestDoubleClickMs + 1)
    ck s.session.getCurrentRRTicks() == tickBefore
    # Two in time: the handler of request 4 (i = 2): step 6 + 7 * 2.
    s.pressRow(rt, 4, 20_000)
    s.pressRow(rt, 4, 20_100)
    # A materialized recording's position is its step (the engine's
    # `ct/goto-ticks` ordinal), which the request's `startGeid` names.
    checkpoint("after the double press: " & rt.app.notification)
    ck s.session.getCurrentRRTicks() == uint64(6 + 7 * 2)
    ck s.session.getCurrentLine() == 13
    ck s.session.getCurrentFile().endsWith(DemoProgramName)
    let ct = rt.app.callTrace
    ck ct.current >= 0
    if ct.current >= 0:
      checkpoint("the current call: " & ct.rows[ct.current].name)
      ck ct.rows[ct.current].name.startsWith("handle_request")
      ck ct.rows[ct.current].index == 2
    ck "handler" in rt.app.notification

  test "6. the row's menu":
    let (row, col) = rt.rowOnScreen(8)
    s.send(rt, sgr(2, row, col))
    s.send(rt, sgr(2, row, col, release = true))
    ck rt.app.contextMenu.open
    ck rt.app.contextMenu.menu.kind == cmkRequestRow
    ck rt.menuLabels == @["Go to Handler", "Copy URL",
                          "Filter by Method: PUT", "Filter by Status: 5xx",
                          "Clear Filters"]
    # The real desktop's menu on the same row: the same entries, the same
    # disabled ones.
    var desktopMenu: seq[(string, bool)] = @[]
    for e in electronAnswers()["rowMenu"]:
      desktopMenu.add (e["label"].getStr, not e["disabled"].getBool)
    var ours: seq[(string, bool)] = @[]
    for e in rt.app.contextMenu.menu.entries:
      ours.add (e.label, e.enabled)
    ck ours == desktopMenu
    ck not rt.app.contextMenu.menu.entries[4].enabled
    ck rt.app.contextMenu.menu.entries[4].reason == "no filter is on"
    s.chooseMenu(rt, "Go to Handler")
    ck s.session.getCurrentRRTicks() == uint64(6 + 7 * 6)
    s.send(rt, sgr(2, row, col))
    s.send(rt, sgr(2, row, col, release = true))
    s.chooseMenu(rt, "Copy URL")
    ck "/api/orders/7" in rt.app.notification

  test "7. keys, with the pane focused":
    # A press focuses the pane (and selects request 2).
    s.pressRow(rt, 2, 50_000)
    ck rt.app.requests.selected == 0
    s.send(rt, HomeKey)
    s.send(rt, EndKey)
    ck rt.app.requests.selected == DemoRequests.len - 1
    s.send(rt, HomeKey)
    s.send(rt, Down)
    ck rt.app.requests.selected == 1
    s.send(rt, Enter)
    ck s.session.getCurrentRRTicks() == uint64(6 + 7 * 1)
    s.send(rt, CtrlC)
    ck "/api/users" in rt.app.notification
    s.send(rt, Esc)
    ck rt.app.requests.selected == -1

  test "8. a short pane reads a window; the wheel scrolls it":
    let (rt2, s2) = open(folder, width = 120, height = 40)
    discard s2.pumpRequests(rt2, 0)
    let (_, screen) = rt2.requestsPaneScreen()
    checkpoint("list rows " & $screen.listRows)
    ck screen.listRows > 1 and screen.listRows < DemoRequests.len
    ck screen.trackCol >= 0
    ck s2.session.requestsVM.viewport.val.rows == screen.listRows
    let (area, _) = rt2.requestsPaneScreen()
    s2.send(rt2, sgr(65, screen.listTop, area.col + 4))   # wheel down
    ck rt2.app.requests.scrollTop > 0
    ck s2.session.requestsVM.viewport.val.firstRow ==
      clampRequestsTop(DemoRequests.len, rt2.app.requests.scrollTop,
                       screen.listRows)
    s2.close()

  test "9. the live tail: rows arrive, an in-flight row settles":
    let live = demoSession("live", through = 1)
    let (rt3, s3) = open(live)
    s3.session.session.store.setSessionMode(liveMcr)
    discard s3.pumpRequests(rt3, 0)
    var ids: seq[int] = @[]
    for r in rt3.app.requests.rows: ids.add r.id
    ck ids == @[2]
    for (through, openOnly, t) in [(3, false, 1_000'i64), (6, true, 2_000'i64)]:
      doAssert writeDemoRequestSession(live, through, openOnly).isOk
      discard s3.pumpRequests(rt3, t)
    ids = @[]
    for r in rt3.app.requests.rows: ids.add r.id
    ck ids == @[2, 3, 4, 5, 6, 7]
    let open = rt3.app.requests.rows[^1]
    ck open.isOpen and open.status == InFlightPlaceholder and
       open.duration == InFlightPlaceholder
    doAssert writeDemoRequestSession(live, 6).isOk
    discard s3.pumpRequests(rt3, 3_000)
    let settled = rt3.app.requests.rows[^1]
    ck rt3.app.requests.rows.len == 6
    ck not settled.isOpen and settled.status == "200" and
       settled.duration == "940ms"
    s3.close()
    removeDir(live)

  test "the assertion count":
    s.close()
    removeDir(folder)
    check countedAssertions == ExpectedAssertions
