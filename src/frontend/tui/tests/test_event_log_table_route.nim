## test_event_log_table_route.nim — the `ct/update-table` route, on a real trace.
##
## ## WHAT THIS SUITE IS FOR
##
## Two backend routes answer with the same recorded events in different shapes:
##
##   * `ct/event-load` serialises whole `ProgramEvent`s for a `(start, count)`
##     slice (`Handler::event_load`, `src/db-backend/src/dap_handler.rs`);
##   * `ct/update-table` answers `TableRow`s for the window a DataTables host
##     paged, filtered and sorted to (`EventDb::update_table`,
##     `src/db-backend/src/event_db.rs`).
##
## The Electron desktop is the only host that speaks the second, and until now
## it decoded that shape for itself, rendered from its own conversion, and
## published a SECOND conversion into `ReplayDataStore` that it never read
## back. A shared signal filled by a front-end that does not read it is a
## signal nobody can be wrong about, which is why this file exists: it asserts
## that the store's `ct/update-table` decoder describes THE SAME EVENTS as the
## `ct/event-load` route does, row for row, at the same absolute positions.
##
## ## WHY THE ASSERTIONS COMPARE CONTENT AND NOT SHAPE
##
## *"No events have been loaded"* is a legitimate degraded output of this pane,
## and an empty window is a well-formed answer to a badly-formed request. A
## count check cannot tell either from a rendering. So every case below
## compares the recorded VALUE of a row — its content string, its path, its
## line, its kind — against the same event as the OTHER route reported it, and
## the two windows are additionally required to disagree with each other where
## they are supposed to (a page at an interior offset must not hold the first
## page's rows), so a decoder that answered the same thing to every question
## fails rather than passes.
##
## ## WHY THE GROUND TRUTH IS DECODED HERE, AGAIN
##
## `wholeLog` below re-reads the `ct/event-load` wire with its own code and
## writes nothing into any store. It is deliberately a SECOND decoder: the
## repository has already been bitten once by an event-log oracle that called
## `requestAndLoadEventLog` — which feeds the store and reads its answer back
## out — and therefore compared the store against a field-renamed copy of
## itself, staying green under a mutation that shifted every line number (see
## `tests/test_event_log_jump.nim:wholeLog`). Sharing a decoder with the
## subject would assert only that the subject agrees with itself.
##
## The subject side is read the same way: the `ct/update-table` JSON is lifted
## into a plain `WireTableRow` here, field by field, and the PRODUCTION
## `eventLogRowFromTableRow` is what turns that into the row under test. What
## is being falsified is the mapping — which wire field becomes which row
## field, and what absolute index a paged row gets — which is exactly where
## the desktop's two conversions could drift apart.
##
## ## WHAT THE ARMING FOUND, INCLUDING THE ONE MUTATION THAT SURVIVED
##
## Twelve mutations were planted in the production decoders and this suite was
## rebuilt and rerun against each. Eleven reddened, in the case that owns the
## property: a line shifted by one, content read from the wrong key, an
## absolute index replaced by a page-local one, the wire's `eventIndex`
## ignored, the route-precedence rule removed, the window's owner not cleared,
## a path taken from the basename, `stdout` dropped from one representation,
## the recording's extent dropped from one representation.
##
## THE ARMING WAS THEN REPRODUCED INDEPENDENTLY, by a second pass that wrote
## its own mutations rather than replaying these, and reached the same verdicts
## — including the survivor. Both passes checked the decoder file back to a
## byte-identical sha256 after every arm, because a mutation left behind is a
## measurement of a tree nobody will ever have. That second pass also armed
## four mutations aimed at the `ct/event-load` JSON decoder specifically, since
## the single survivor sat there and a survivor is only informative if its
## neighbourhood is otherwise covered: three reddened, and the fourth — the
## decoder preferring the wire's `eventIndex` over the caller's offset —
## survived a gap this file now closes (see the case below).
##
## ONE SURVIVED, and it is recorded rather than hidden: setting the JSON
## decoder's `sourceDigest` to `""` left the suite green. The reason is not the
## assertion — the cross-representation equality below compares `EventLogRow`
## whole — it is that the field is EMPTY ON EVERY ROW THIS BACKEND CAN PRODUCE,
## and that is a stronger statement than "this fixture happens not to have one".
## It was measured both ways:
##
##   * by reading the two places a recorded `ProgramEvent` is built —
##     `Db::to_program_event` (`src/db-backend/src/db.rs`), the path every
##     CTFS/db-backed trace takes, and the `to_program_event` beside
##     `Handler::event_load` (`src/db-backend/src/dap_handler.rs`) — both of
##     which write `source_digest: String::new()` and `source_generation: 0`
##     as LITERALS. `TableRow::new` then copies whatever the event carries, so
##     both routes inherit the same empty value.
##   * by asking the wire, over a real `replay-server`, for every fixture in
##     the corpus that resolves on this machine: `noir_space_ship` (70
##     events), `calc` (6) and `wide_state` (6) each report exactly one
##     distinct `sourceDigest` — `""` — and one distinct `sourceGeneration` —
##     `0`.
##
## So ADDING A FIXTURE WOULD NOT CLOSE IT. `EventLogRow.sourceDigest` and
## `.sourceGeneration` are carried for a producer that does not exist yet; the
## day one does, this suite discriminates them without being touched, and until
## then no recording can tell a decoder that drops them from one that does. The
## honest general rule is the narrower one: a cross-representation equality can
## only falsify fields some producer populates.
##
## ## WHAT THIS SUITE DOES NOT COVER, SAID PLAINLY
##
## The desktop's own half of the change — `ui/event_log.nim`'s `extrasOf`,
## `programEventOf` and `dataTablePayload`, which project the store's rows back
## into the shape DataTables renders — is NOT exercised here and cannot be.
## That module is a browser module: it reaches `kdom`, jQuery and the
## DataTables FFI, so it compiles under `nim js` without `-d:nodejs` and there
## is no process that can both run it and hold a `replay-server`. Its coverage
## is the renderer compile of both arms (`-d:ctRenderer`, and the same plus
## `-d:ctInExtension`) plus the browser suites under `src/tests/gui/`.
##
## What IS asserted here is the half those two share: that the row the store
## produces from a `ct/update-table` window is the right event, at the right
## absolute position, with the right text.
##
## What is left uncovered, stated exactly rather than waved past. `extrasOf`
## and `programEventOf` are total field-for-field mappings with no branch in
## them, so a defect in either is a compile error or a wrong constant, not a
## wrong row. The two procs around them are NOT branch-free — both
## `syncProgramEventsFromStore` and `dataTablePayload` decide per row whether
## the extras still describe the window in hand — and that decision is the
## uncovered surface. Its failure mode is bounded by which fields live in the
## extras: a row that loses them renders without a metadata string and without
## the recorder's own event id, and keeps the file, the line, the content, the
## kind and the position, because those are on the neutral row. Nothing in this
## file observes that, and no `replay-server` test can.
##
## ## No mocks
##
## A real `.ct` trace recorded by a real recorder, opened by a real
## `replay-server` child process. Both routes are driven over that one process.
##
## ## WHY THIS FILE IS NOT UNDER `app/tests/`
##
## `tests/test_tui_facade_boundary.nim` fails any `.nim` under
## `src/frontend/tui/app/` that imports `headless_session` or
## `backend/stdio_backend`. This suite's subject is a real
## `HeadlessDebugSession`. The `tui` lane globs `tests/test_*.nim` and
## `app/tests/test_*.nim` identically.
##
## Compile + run (inside the dev shell):
##   nim c -r src/frontend/tui/tests/test_event_log_table_route.nim

import std/[json, strutils, unittest]

import isonim/core/signals
import isonim/viewmodel

import headless_session
# `sendDapRequest` / `drainEvents` are not part of what `headless_session`
# re-exports, and both routes here are driven straight over the transport.
import backend/stdio_backend
import store/[replay_data_store, types]

import ./fixtures/fixture_provider

# One line, deliberately: `ci/lib/run-nim-test-lane.sh` reads exactly this
# spelling as a RUNTIME assertion count, and inside a `const` block the
# declaration is invisible to it.
const ExpectedAssertions = 172
  ## The tally on a run where the fixture resolved. It is ASSERTED in the last
  ## case, not merely printed: `ci/lib/run-nim-test-lane.sh` reads this number
  ## as the lane's assertion count and is entitled to do so only because the
  ## file fails when its own tally disagrees.

var countedAssertions = 0

template ck(condition: untyped) =
  inc countedAssertions
  check condition

const
  FixtureName = "noir_space_ship"
    ## The densest log in the corpus — 70 recorded events against `calc`'s 6.
    ## A paging suite needs a log with an interior; a six-row log cannot tell
    ## "the window moved" from "the window is the whole thing".
  WindowLength = 8
    ## Small enough that an interior page is a proper subset of the log.
  EventKindsCount = 14
    ## `EVENT_KINDS_COUNT` (`src/db-backend/src/task.rs`). `selected_kinds` is
    ## a fixed-size Rust array, so a shorter list is a deserialisation failure
    ## rather than a partial filter.

var
  examinedFixtures = 0
  verifiedFixtures = 0
  skippedFixtures = 0

# ---------------------------------------------------------------------------
# The ground truth: `ct/event-load`, decoded here and stored nowhere
# ---------------------------------------------------------------------------

type
  TruthEvent = object
    ## One recorded event as the OTHER route reports it. Named after what it
    ## is — an expectation — rather than after any type the product holds, so
    ## that it cannot quietly become a copy of one.
    content: string
    file: string
    line: int
    kind: int
    stdout: bool
    semanticKind: string
    ticks: int64
    rrEventId: int
    eventIndex: int
    maxRRTicks: int64

proc wholeLog(session: HeadlessDebugSession): seq[TruthEvent] =
  ## The recording's entire event log in one `ct/event-load`, decoded from the
  ## raw wire. Writes nothing into the store — the subject's rows have to come
  ## from the subject's own path or this proves nothing.
  ##
  ## Sending this FIRST is also what makes the `ct/update-table` case possible
  ## at all: `Handler::event_load` calls `ensure_events_loaded`, which is what
  ## populates the `EventDb` that `update_table` pages over. A `ct/update-table`
  ## on a cold session answers an empty table, and an empty table is exactly
  ## the well-formed apology this file refuses to accept as a pass.
  let resp = session.backend.sendDapRequest(
    "ct/event-load", %*{"start": 0, "count": 1_000_000})
  discard session.backend.drainEvents()
  if not resp.getOrDefault("success").getBool(false):
    return
  let body = resp.getOrDefault("body")
  if body.isNil or body.kind != JObject:
    return
  let events = body.getOrDefault("events")
  if events.isNil or events.kind != JArray:
    return
  for i in 0 ..< events.len:
    let ev = events[i]
    result.add TruthEvent(
      content: ev.getOrDefault("content").getStr(""),
      file: ev.getOrDefault("highLevelPath").getStr(
        ev.getOrDefault("high_level_path").getStr("")),
      line: ev.getOrDefault("highLevelLine").getInt(
        ev.getOrDefault("high_level_line").getInt(0)),
      kind: ev.getOrDefault("kind").getInt(0),
      stdout: ev.getOrDefault("stdout").getBool(false),
      semanticKind: ev.getOrDefault("semanticKind").getStr(
        ev.getOrDefault("semantic_kind").getStr("")),
      ticks: ev.getOrDefault("directLocationRRTicks").getBiggestInt(0),
      rrEventId: ev.getOrDefault("rrEventId").getInt(
        ev.getOrDefault("rr_event_id").getInt(0)),
      # An absent `eventIndex` falls back to the row's POSITION in this answer,
      # which is its absolute index because this request starts at 0.
      eventIndex: ev.getOrDefault("eventIndex").getInt(
        ev.getOrDefault("event_index").getInt(i)),
      maxRRTicks: ev.getOrDefault("maxRRTicks").getBiggestInt(0))

# ---------------------------------------------------------------------------
# The subject's input: `ct/update-table`, lifted off the wire
# ---------------------------------------------------------------------------

type
  WireTableRow = object
    ## One `ct/update-table` row, with the field names `TableRow` uses.
    ##
    ## A PLAIN VALUE CARRIER, not a decode. The product's own `TableRow` is not
    ## nameable from here — `common_types/codetracer_features/events.nim` is
    ## *included* into two hosts that bind `langstring` differently, so the
    ## native and the renderer builds hold two unrelated Nim types — which is
    ## the same reason `eventLogRowFromTableRow` is generic. Instantiating that
    ## generic over this object is what puts the production mapping under test.
    directLocationRRTicks: int
    rrEventId: int
    fullPath: string
    lowLevelLocation: string
    kind: int
    semanticKind: string
    content: string
    metadata: string
    base64Encoded: bool
    stdout: bool
    sourceGeneration: int
    sourceDigest: string

proc wireTableRow(node: JsonNode): WireTableRow =
  WireTableRow(
    directLocationRRTicks: node.getOrDefault("directLocationRRTicks").getInt(0),
    rrEventId: node.getOrDefault("rrEventId").getInt(0),
    fullPath: node.getOrDefault("fullPath").getStr(""),
    lowLevelLocation: node.getOrDefault("lowLevelLocation").getStr(""),
    kind: node.getOrDefault("kind").getInt(0),
    semanticKind: node.getOrDefault("semanticKind").getStr(""),
    content: node.getOrDefault("content").getStr(""),
    metadata: node.getOrDefault("metadata").getStr(""),
    base64Encoded: node.getOrDefault("base64Encoded").getBool(false),
    stdout: node.getOrDefault("stdout").getBool(false),
    sourceGeneration: node.getOrDefault("sourceGeneration").getInt(0),
    sourceDigest: node.getOrDefault("sourceDigest").getStr(""))

type
  TableAnswer = object
    rows: seq[WireTableRow]
    recordsTotal: int
    recordsFiltered: int

proc selectedKindsAll(): JsonNode =
  result = newJArray()
  for _ in 0 ..< EventKindsCount:
    result.add(%true)

proc updateTable(session: HeadlessDebugSession;
                 start, length: int): TableAnswer =
  ## One `ct/update-table` window, exactly as the desktop's DataTables ajax
  ## callback asks for it: `TableArgs` with the page offset and length, every
  ## event kind selected, the global event slot, no search.
  let args = %*{
    "tableArgs": {
      "columns": newJArray(),
      "draw": 1,
      "length": length,
      "order": newJArray(),
      "search": {"value": "", "regex": false},
      "start": start,
    },
    "selectedKinds": selectedKindsAll(),
    "isTrace": false,
    "eventSlot": 0,
  }
  let resp = session.backend.sendDapRequest("ct/update-table", args)
  discard session.backend.drainEvents()
  if not resp.getOrDefault("success").getBool(false):
    return
  let body = resp.getOrDefault("body")
  if body.isNil or body.kind != JObject:
    return
  let update = body.getOrDefault("tableUpdate")
  if update.isNil or update.kind != JObject:
    return
  let data = update.getOrDefault("data")
  if data.isNil or data.kind != JObject:
    return
  result.recordsTotal = data.getOrDefault("recordsTotal").getInt(0)
  result.recordsFiltered = data.getOrDefault("recordsFiltered").getInt(0)
  let rows = data.getOrDefault("data")
  if rows.isNil or rows.kind != JArray:
    return
  for row in rows:
    result.rows.add wireTableRow(row)

# ---------------------------------------------------------------------------
# The `ct/updated-events` echo, which is what `EventLogComponent` receives
# ---------------------------------------------------------------------------

type
  WireProgramEvent = object
    ## One `ct/updated-events` entry, with the field names `ProgramEvent` uses
    ## — the typed value the renderer's event bus hands
    ## `EventLogComponent.onUpdatedEvents`. Carrier, not decoder; see
    ## `WireTableRow`.
    kind: int
    semanticKind: string
    content: string
    rrEventId: int
    highLevelPath: string
    highLevelLine: int
    stdout: bool
    directLocationRRTicks: int
    eventIndex: int
    maxRRTicks: int
    sourceGeneration: int
    sourceDigest: string

proc wireProgramEvent(node: JsonNode): WireProgramEvent =
  WireProgramEvent(
    kind: node.getOrDefault("kind").getInt(0),
    semanticKind: node.getOrDefault("semanticKind").getStr(""),
    content: node.getOrDefault("content").getStr(""),
    rrEventId: node.getOrDefault("rrEventId").getInt(0),
    highLevelPath: node.getOrDefault("highLevelPath").getStr(""),
    highLevelLine: node.getOrDefault("highLevelLine").getInt(0),
    stdout: node.getOrDefault("stdout").getBool(false),
    directLocationRRTicks:
      node.getOrDefault("directLocationRRTicks").getInt(0),
    eventIndex: node.getOrDefault("eventIndex").getInt(0),
    maxRRTicks: node.getOrDefault("maxRRTicks").getInt(0),
    sourceGeneration: node.getOrDefault("sourceGeneration").getInt(0),
    sourceDigest: node.getOrDefault("sourceDigest").getStr(""))

type
  UpdatedEventsEcho = object
    ## One `ct/updated-events` answer in BOTH representations it reaches a host
    ## in: `raw` is the JSON a DAP-channel reader sees, `typed` is the same
    ## payload after a typed event bus has deserialised it, which is what the
    ## renderer's `EventLogComponent.onUpdatedEvents` is handed. Keeping both
    ## is what lets the case below require the store's two decoders to agree.
    raw: JsonNode
    typed: seq[WireProgramEvent]

proc updatedEventsEcho(session: HeadlessDebugSession;
                       start, count: int): UpdatedEventsEcho =
  ## The `ct/updated-events` EVENT the backend pushes beside its `ct/event-load`
  ## response — the payload `EventLogComponent.onUpdatedEvents` is handed.
  ##
  ## Read off the event and not off the response on purpose: the defect this
  ## covers is in how that handler assigns absolute positions, and the handler
  ## never sees the response. (In the Electron renderer it could not: that
  ## host's `asyncSendCtRequest` settles the request promise with `{}` and
  ## delivers the real body down the event channel, so this event is the
  ## desktop's ONLY `ct/event-load` answer.)
  result.raw = newJArray()
  discard session.backend.sendDapRequest(
    "ct/event-load", %*{"start": start, "count": count})
  for event in session.backend.drainEvents():
    if event.getOrDefault("event").getStr("") != "ct/updated-events":
      continue
    let body = event.getOrDefault("body")
    if body.isNil or body.kind != JArray:
      continue
    result.raw = body
    result.typed = @[]
    for entry in body:
      result.typed.add wireProgramEvent(entry)

# ---------------------------------------------------------------------------

proc expectedKindLabel(kindId: int; stdout: bool; semanticKind: string): string =
  ## The display kind, spelled out here rather than by calling
  ## `eventKindLabel`. It is three lines and it is the rule the product is
  ## supposed to follow; importing the product's own copy would make this
  ## clause assert nothing.
  if semanticKind.len > 0: semanticKind
  elif stdout: "stdout"
  else: "event"

proc distinctContents(rows: seq[EventLogRow]): int =
  var seen: seq[string] = @[]
  for row in rows:
    if row.value notin seen:
      seen.add row.value
  seen.len

# ---------------------------------------------------------------------------

suite "the event log's two routes describe one recording":

  test "noir_space_ship: ct/update-table windows decode into the shared store":
    inc examinedFixtures
    let resolution = resolveFixture(FixtureName)
    if resolution.outcome == foMissingPrereq:
      inc skippedFixtures
      let message = missingPrereqMessage(resolution.spec, resolution.detail)
      echo "  ", message
      ck message.startsWith(MissingPrereqSkipPrefix)
      ck resolution.tracePath.len == 0
      skip()
    else:
      inc verifiedFixtures
      let session = newHeadlessDebugSession(resolution.tracePath,
                                            findReplayServer())
      defer: session.close()

      # ---- GROUND TRUTH ---------------------------------------------------
      let truth = wholeLog(session)
      echo "EVENT LOG TABLE ROUTE: ", FixtureName, " has ", truth.len,
           " event(s) on ct/event-load"
      ck truth.len > 0
      # The suite needs an INTERIOR. Without one, "the window moved" and "the
      # window is the whole log" are the same observation and every case below
      # would pass on a decoder that ignored `start` entirely.
      ck truth.len > WindowLength * 2

      # ---- THE SUBJECT: a window at the very start ------------------------
      let first = session.updateTable(0, WindowLength)
      echo "  ct/update-table[0..", WindowLength, "] -> ", first.rows.len,
           " row(s); recordsTotal ", first.recordsTotal
      ck first.rows.len == WindowLength
      ck first.recordsTotal == truth.len

      let store = createReplayDataStore(session.backend.toBackendService())
      defer: store.dispose()

      store.applyEventLogRows(
        eventLogRowsFromTableRows(first.rows, 0, truth[0].maxRRTicks),
        0, first.recordsTotal, first.recordsFiltered, source = elwsTable)
      let firstRows = store.eventLog.rows.val
      ck firstRows.len == WindowLength

      # THE PANE IS SHOWING SOMETHING, and not the same something eight times.
      # An empty string is what an apology renders as, and a decoder that read
      # the wrong key would produce eight identical empties that a length check
      # would accept.
      ck distinctContents(firstRows) > 1

      # ROW FOR ROW, AGAINST THE OTHER ROUTE'S ANSWER FOR THE SAME EVENTS.
      for i, row in firstRows:
        ck row.value == truth[i].content
        ck row.file == truth[i].file
        ck row.line == truth[i].line
        ck row.kindId == truth[i].kind
        ck row.stdout == truth[i].stdout
        ck row.eventIndex == i
        ck row.kind == expectedKindLabel(truth[i].kind, truth[i].stdout,
                                         truth[i].semanticKind)
        ck row.rrTicks ==
          (if truth[i].ticks > 0: uint64(truth[i].ticks) else: 0'u64)

      # ---- AN INTERIOR WINDOW, WHICH IS WHERE `start` STOPS BEING FREE ----
      let offset = WindowLength
      let second = session.updateTable(offset, WindowLength)
      ck second.rows.len == WindowLength

      # The precondition that makes the comparison below meaningful: the two
      # windows must be different recordings of different moments. If the log
      # repeated itself here, agreeing with the truth at the wrong offset
      # would look like agreeing with it at the right one.
      var windowsDiffer = false
      for i in 0 ..< WindowLength:
        if second.rows[i].content != truth[i].content:
          windowsDiffer = true
          break
      ck windowsDiffer

      store.applyEventLogRows(
        eventLogRowsFromTableRows(second.rows, offset, truth[0].maxRRTicks),
        offset, second.recordsTotal, second.recordsFiltered,
        source = elwsTable)
      let secondRows = store.eventLog.rows.val
      ck secondRows.len == WindowLength
      ck store.eventLog.loadedStart.val == offset
      for i, row in secondRows:
        ck row.value == truth[offset + i].content
        ck row.line == truth[offset + i].line
        ck row.eventIndex == offset + i

      # ---- THE PAGED WINDOW IS NOT REPLACED BY THE PREFIX ROUTE -----------
      #
      # `EventLogVM`'s auto-load effect issues `ct/event-load` with no
      # `start`/`count`, so the backend answers a fixed 20-row PREFIX. On the
      # desktop that lands in the same signal the paged window does. Asserted
      # by CONTENT: after the prefix is applied, the store must still be
      # holding the event at absolute position `offset`, not the one at 0.
      let prefix = session.backend.sendDapRequest("ct/event-load", %*{})
      discard session.backend.drainEvents()
      ck prefix.getOrDefault("success").getBool(false)
      store.applyEventLogResponse(prefix.getOrDefault("body"), 0)
      ck store.eventLog.rows.val.len == WindowLength
      ck store.eventLog.rows.val[0].value == truth[offset].content
      ck store.eventLog.rows.val[0].value != truth[0].content
      ck store.eventLog.loadedStart.val == offset

      # …and once the window is cleared, the prefix route owns it again. A
      # precedence rule that outlived the session would leave the next
      # recording's log empty for every store consumer.
      store.clearEventLog()
      store.applyEventLogResponse(prefix.getOrDefault("body"), 0)
      ck store.eventLog.rows.val.len > 0
      ck store.eventLog.rows.val[0].value == truth[0].content

  test "noir_space_ship: ct/updated-events rows carry their own absolute index":
    ## The disclosed defect, in the coordinate it was disclosed in.
    ##
    ## `onUpdatedEvents` used to append this answer's rows to the DataTables
    ## window and publish the concatenation at the table's offset, so the
    ## appended tail's absolute indices were assigned by an arithmetic that had
    ## nothing to do with where those events actually are. The repair is that
    ## the answer is published as its OWN window, decoded by the store's
    ## `ct/event-load`-shape decoder, at the offset its rows declare.
    ##
    ## So: fetch an INTERIOR slice, and require every row to land on the event
    ## that truly occupies that absolute position — by content, not by count.
    inc examinedFixtures
    let resolution = resolveFixture(FixtureName)
    if resolution.outcome == foMissingPrereq:
      inc skippedFixtures
      echo "  ", missingPrereqMessage(resolution.spec, resolution.detail)
      skip()
    else:
      inc verifiedFixtures
      let session = newHeadlessDebugSession(resolution.tracePath,
                                            findReplayServer())
      defer: session.close()

      let truth = wholeLog(session)
      ck truth.len > WindowLength * 2

      let offset = WindowLength
      let echoed = session.updatedEventsEcho(offset, WindowLength)
      ck echoed.typed.len == WindowLength

      let store = createReplayDataStore(session.backend.toBackendService())
      defer: store.dispose()

      # Exactly what the repaired `onUpdatedEvents` does: decode each event of
      # THIS answer, with its position in THIS answer as the fallback index,
      # and publish the result as one window at the offset the first row
      # declares. Nothing from any other producer is concatenated in.
      var rows: seq[EventLogRow] = @[]
      for i, event in echoed.typed:
        rows.add eventLogRowFromProgramEvent(event, i)

      # ---- ONE SHAPE, TWO REPRESENTATIONS, REQUIRED TO AGREE --------------
      #
      # `ct/event-load`'s answer reaches a DAP-channel host as JSON and a
      # typed-event-bus host as a deserialised object, so the store carries the
      # mapping twice: `eventLogRowFromJson` and `eventLogRowFromProgramEvent`.
      # That is two representations of one shape and NOT two decodes of it —
      # but the difference is only worth anything if it is checked, because the
      # failure mode of "expressed twice" is that one copy is edited and the
      # other is not, and the two hosts then disagree about the same recording
      # with nothing failing.
      #
      # So the SAME bytes go through both and the rows must be EQUAL, field for
      # field. `EventLogRow` is a plain object, so `==` compares all of it: a
      # field added to one mapping and forgotten in the other reddens here on
      # the next run rather than in a bug report from whichever host was left
      # behind.
      let rowsFromJson = eventLogRowsFromJson(echoed.raw, offset)
      ck rowsFromJson.len == rows.len
      for i in 0 ..< rows.len:
        ck rowsFromJson[i] == rows[i]

      # ---- THE WIRE'S `eventIndex` BEATS THE CALLER'S OFFSET --------------
      #
      # ADDED BECAUSE AN ARMING PASS FOUND THIS UNCOVERED. Every other decode
      # in this file hands the JSON decoder a `positionIndex` that already
      # EQUALS the wire's own `eventIndex`, so a decoder that ignored the wire
      # and simply counted from its argument answers the same thing everywhere
      # and the suite stayed green under exactly that mutation. The property is
      # covered for the other two decoders and was not covered for this one.
      #
      # Decoding the SAME bytes at offset 0 separates them: only the wire's own
      # `eventIndex` can still put these rows at their true absolute positions,
      # so a decoder that preferred its argument now lands `offset` events
      # early — and the rows must additionally still equal the ones decoded at
      # `offset`, which is the same claim stated as an identity.
      let rowsAtZero = eventLogRowsFromJson(echoed.raw, 0)
      ck rowsAtZero.len == rowsFromJson.len
      for i in 0 ..< rowsAtZero.len:
        ck rowsAtZero[i].eventIndex == offset + i
        ck rowsAtZero[i] == rowsFromJson[i]

      let windowStart = if rows.len > 0: rows[0].eventIndex else: 0
      store.applyEventLogRows(rows, windowStart, source = elwsEventLoad)

      let applied = store.eventLog.rows.val
      ck applied.len == WindowLength
      ck distinctContents(applied) > 1
      ck store.eventLog.loadedStart.val == offset

      for i, row in applied:
        # THE INDEX, against the whole log rather than against the page. A row
        # that took the page-local offset lands `offset` events early, and the
        # content check below is what makes that visible rather than merely
        # off-by-a-number.
        ck row.eventIndex == offset + i
        ck row.value == truth[offset + i].content
        ck row.line == truth[offset + i].line
        ck row.file == truth[offset + i].file

      # CONTROL. The same comparison against the FIRST page must fail, or the
      # log repeats itself here and the case above proves nothing about
      # positions.
      var wouldMisreadAsFirstPage = false
      for i, row in applied:
        if row.value != truth[i].content:
          wouldMisreadAsFirstPage = true
          break
      ck wouldMisreadAsFirstPage

  test "the fixture corpus was reached":
    echo "EVENT LOG TABLE ROUTE: examined ", examinedFixtures,
         ", verified ", verifiedFixtures, ", skipped ", skippedFixtures
    ck examinedFixtures == 2
    ck verifiedFixtures + skippedFixtures == examinedFixtures
    # THE TALLY, ASSERTED. A case that returned early — a `check` that stopped
    # a loop, an exception swallowed by `unittest` — leaves this short, and the
    # suite says so instead of reporting a green run over assertions that never
    # executed. Both branches add exactly one to the count, so the number is
    # the same arithmetic either way, and the echo comes AFTER so the printed
    # figure is the one that was compared.
    if skippedFixtures == 0:
      ck countedAssertions == ExpectedAssertions
    else:
      ck countedAssertions < ExpectedAssertions
    echo "EVENT LOG TABLE ROUTE: ", countedAssertions, " assertion(s) of ",
         ExpectedAssertions, " expected"
