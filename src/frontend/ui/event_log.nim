import
  ../[ types, communication ],
  ../../common/ct_event,
  ui_imports, colors, trace, typetraits, strutils, jsconsole,
  datatable, strutils, base64

# ---------------------------------------------------------------------------
# ViewModel layer — wired in parallel with the legacy event-bus code.
# The EventLogVM receives the same data but does not affect rendering yet.
# ---------------------------------------------------------------------------
import std/json
from ../viewmodel/backend/backend_service import BackendService, BackendFuture
import ../viewmodel/store/replay_data_store
import ../viewmodel/store/types as vmtypes
from ../viewmodel/viewmodels/event_log_vm import
  EventLogVM, createEventLogVM, appendLiveDebuggerStop
from isonim/core/signals import val
from isonim/web/dom_api import nil
from ../viewmodel/views/isonim_event_log_view import
  mountIsoNimEventLog, mountIsoNimEventLogWithDataTables
from ../viewmodel/views/isonim_event_log_filter_dropdown_view import
  FilterTabRecord, FilterTagRow, FilterKindRecord, FilterDropdownCallbacks,
  FilterDropdownContainerId, FilterDropdownListId,
  mountFilterDropdownInto  # filtersEnabled param added

# Module-level EventLogVM instance. Created once and fed data whenever
# the legacy event-bus handlers fire. Rendering still reads from legacy
# data so behaviour is unchanged.
var eventLogVMInstance: EventLogVM
var eventLogVMStore: ReplayDataStore
var isoNimEventLogMounted*: bool = false

const eventLogMaxReloadRetries* = 8
  ## How many times `onUpdatedTable` will re-request the first page while
  ## the backend still answers with zero records.
  ##
  ## An empty first page is the normal ordering on a trace open — the
  ## debugger reports its entry location before `ct/event-load` returns —
  ## so the retries are the designed response and are logged at DEBUG.
  ## Running the budget out is not normal: nothing reloads the table
  ## afterwards, so the Event Log stays empty for the session. That case is
  ## logged at ERROR, in the `elif` next to the retry itself.

# Reference to the EventLogComponent instance so that the IsoNim mount
# callback can trigger DataTables initialisation via events().
var eventLogComponentRef: EventLogComponent

proc tryMountIsoNimEventLogPanel*()
proc eventLogAfterRedraws(self: EventLogComponent)
when defined(js):
  proc stringifyJs(o: JsObject): cstring {.importjs: "JSON.stringify(#)".}
  proc jsonParseJs(s: cstring): JsObject {.importjs: "JSON.parse(#)".}
  proc setTimeoutWithArg[T](cb: proc(x: T) {.cdecl.}, delay: int, arg: T) {.importjs: "setTimeout(#, #, #)".}

  proc jsonToJsObject(j: JsonNode): JsObject =
    jsonParseJs(cstring($j))

  proc jsonFromJsObject(o: JsObject): JsonNode =
    if o.isNil:
      return %*{}
    parseJson($stringifyJs(o))

  proc requestExtensionDap(command: cstring; args: JsObject;
                           resolve: proc(resp: JsObject)) {.importjs: """
    (function(command, args, resolve) {
      if (typeof vscode === "undefined" || !vscode || typeof vscode.postMessage !== "function") {
        resolve({});
        return;
      }
      var id = "event-log-dap-" + Date.now() + "-" + Math.random().toString(16).slice(2);
      function onMessage(event) {
        var message = event && event.data ? event.data : {};
        if (message.command !== "ct-vscode-dap-response" || message.requestId !== id) {
          return;
        }
        window.removeEventListener("message", onMessage);
        resolve(message.value || {});
      }
      window.addEventListener("message", onMessage);
      vscode.postMessage({
        command: "ct-vscode-dap-request",
        requestId: id,
        dapCommand: String(command || ""),
        value: args || {}
      });
    })(#, #, #);
  """.}


# ---------------------------------------------------------------------------
# ViewModel bridge procs — sync legacy event data into the parallel store.
# ---------------------------------------------------------------------------

proc installEventLogSwitchProcessBridge*(onSwitch: proc(recordingId: string)) =
  ## §5.3 — give the Event Log a way to rotate the session's active
  ## recording when a boundary chip's counterpart lives in a sibling
  ## trace. Called by the renderer bootstrap right after
  ## `initEventLogVMWithStore`, mirroring how the State Pane's
  ## "Switch process" menu is wired.
  if eventLogVMInstance.isNil:
    return
  eventLogVMInstance.onSwitchProcessProc = onSwitch

proc initEventLogVMWithStore*(store: ReplayDataStore) =
  ## Initialise the parallel EventLogVM using an externally-provided
  ## ReplayDataStore (typically the shared store from SessionViewModel).
  ##
  ## If a stub-backed instance already exists (created by initEventLogVM
  ## before the real backend was available), it is replaced so that the
  ## panel uses the real DapApi instead of the no-op stub.
  let replacing = eventLogVMInstance != nil
  if replacing:
    clog "EventLogVM: replacing existing instance with shared-store version"
  eventLogVMStore = store
  eventLogVMInstance = createEventLogVM(store)
  clog "EventLogVM: parallel ViewModel instance created (shared store)"
  # 2026-05-30 — earlier this proc unconditionally cleared
  # `isoNimEventLogMounted = false` before falling through to
  # tryMountIsoNimEventLogPanel().  That triggered a full re-mount of
  # the IsoNim shell, which rerenders the `data-tables-footer-rows-count`
  # placeholder back to "0".  The legacy DataTables onUpdatedTable
  # path then races against a stale rowsCount=0 reset (the
  # DataTables context is destroyed+recreated in `reInit`/`redrawColumns`
  # path), and the footer is observed at "0" rather than the live
  # `recordsTotal` until the next ajax round-trip lands — which the
  # cross-language GUI tests (circom/aiken/tolk/wasm event-log) read
  # within their 30s poll budget and fail on.
  #
  # The DOM doesn't need a re-mount when only the VM changes — only the
  # VM auto-load effects need to re-bind, and those rebind when the
  # next mutation propagates.  Skip the mount-state reset on
  # replacement.
  when defined(ctInExtension):
    if replacing and not eventLogComponentRef.isNil:
      isoNimEventLogMounted = false
      let hostId =
        if eventLogComponentRef.extensionRendererId.len > 0:
          eventLogComponentRef.extensionRendererId
        else:
          cstring"eventLogComponent-0"
      let host = document.getElementById(hostId)
      if not host.isNil:
        host.innerHTML = cstring""
      tryMountIsoNimEventLogPanel()
  if not replacing:
    tryMountIsoNimEventLogPanel()

proc initEventLogVM() =
  ## Lazily create the parallel EventLogVM backed by a stub
  ## BackendService.  Fallback when no shared store has been provided
  ## via `initEventLogVMWithStore`.
  if eventLogVMInstance != nil:
    return

  let stubSend = proc(command: string, args: JsonNode): BackendFuture[JsonNode] =
    when defined(js):
      when defined(ctInExtension):
        result = newPromise proc(resolve: proc(resp: JsonNode)) =
          requestExtensionDap(cstring(command), jsonToJsObject(args),
            proc(raw: JsObject) =
              try:
                resolve(jsonFromJsObject(raw))
              except CatchableError:
                resolve(%*{}))
      else:
        result = newPromise proc(resolve: proc(resp: JsonNode)) =
          resolve(%*{})
    else:
      var fut = newFuture[JsonNode]("stub-backend")
      fut.complete(%*{})
      result = fut

  let stubBackend = BackendService(
    sendProc: stubSend,
    onEventProc: proc(handler: proc(event: JsonNode)) = discard,
    disconnectProc: proc() = discard,
  )

  eventLogVMStore = createReplayDataStore(stubBackend)
  eventLogVMInstance = createEventLogVM(eventLogVMStore)
  clog "EventLogVM: parallel ViewModel instance created (stub backend)"
  tryMountIsoNimEventLogPanel()

proc syncEventLogDebuggerPosition(rrTicks: int, path: cstring, line: int;
                                  sourceGeneration: int = 0;
                                  sourceDigest: cstring = cstring"") =
  ## Mirror the legacy debugger position into the ViewModel store so
  ## the EventLogVM's auto-load effect fires with the updated rrTicks.
  if eventLogVMStore.isNil:
    return
  let ticks = cast[uint64](rrTicks)
  eventLogVMStore.updateDebuggerPosition(
    ticks, $path, line,
    sourceGeneration = sourceGeneration,
    sourceDigest = $sourceDigest)
  clog fmt"EventLogVM: synced debugger rrTicks={ticks}"

proc safeText(value: cstring): cstring =
  if value.isNil:
    cstring""
  else:
    value

# M49 — the legacy `syncMarkerRowsDom` / `installMarkerRowsDomSync` /
# `ensureEventLogActiveRecordingRole` trio used to live here. All three
# are gone, and each for its own reason.
#
# `syncMarkerRowsDom` rebuilt the `.event-log-marker-rows` subtree by
# hand from `vm.markerRows` — but that container is created and owned by
# the IsoNim Event Log shell (`isonim_event_log_view.nim`), which binds
# it reactively to `vm.visibleMarkerRows` through `indexEach`. Two
# writers shared one container: the legacy effect cleared `innerHTML`
# and re-appended plain elements while IsoNim's reconciler held
# references into the nodes it had created. It also bypassed the §5.4
# filter, so a filtered Event Log would have shown the unfiltered set
# whenever the legacy effect happened to run last.
#
# `ensureEventLogActiveRecordingRole` wrote a *fabricated*
# `window.data.activeRecording.role` (plus `activeProcess`,
# `session.activeProcess`, `sessionStorage` and `vscode` state) from a
# chip click, guarded by `boundaryId == "account-balance-with-wasm"` —
# the three-trace fixture's *directory* name, which no recording emits
# as a boundary id. It was shaped to satisfy a GUI assertion rather than
# to do anything a user wants, it could not fire on the recordings it
# named, and `window.data.activeRecording` exists nowhere else in the
# product. The active recording is `SessionViewModel`'s
# `activeProcessRecordingId`, and the DOM already publishes it: the
# process tree marks the selected row `aria-selected="true"`.
#
# The chip's real behaviour is now `EventLogVM.jumpToCounterpartOf`,
# which resolves the firing's counterpart through `ct/pairIndexLookup`
# and rotates the session through `SessionViewModel.onSwitchProcess` —
# the same entry point the process tree and the State Pane menu use.

proc liveEventLogSession(): bool =
  not eventLogVMStore.isNil and
    eventLogVMStore.session.val.debugSessionMode in {
      vmtypes.liveMcr,
      vmtypes.liveMaterialized,
      vmtypes.historicalFromLive}

proc locationSourcePath(location: types.Location): cstring =
  if not location.highLevelPath.isNil and location.highLevelPath.len > 0:
    location.highLevelPath
  elif not location.path.isNil and location.path.len > 0:
    location.path
  else:
    cstring""

proc locationSourceLine(location: types.Location): int =
  if location.highLevelLine > 0:
    location.highLevelLine
  else:
    location.line

func extrasOf(row: TableRow): EventLogRowExtras =
  ## The presentation-only half of one `ct/update-table` row.
  ##
  ## Its counterpart is `eventLogRowFromTableRow` in the store, which reads the
  ## SAME row and produces everything a neutral consumer needs. Between them
  ## every field of `TableRow` is accounted for exactly once, and the split is
  ## the one `EventLogRowExtras`' own header argues for field by field.
  EventLogRowExtras(
    fullPath: row.fullPath,
    lowLevelLocation: row.lowLevelLocation,
    metadata: row.metadata,
    semanticKind: row.semanticKind,
    base64Encoded: row.base64Encoded,
    rawEventId: row.rrEventId,
    rawLocationRRTicks: row.directLocationRRTicks,
  )

func eventLogKindOf(kindId: int): EventLogKind =
  ## `EventLogRow.kindId` back as the enum this front-end's `case` statements
  ## switch on.
  ##
  ## RANGE-CHECKED, because the neutral row's `kindId` is deliberately an `int`
  ## and not an enum: `eventLogRowFromJson` keeps whatever number the wire sent
  ## so that a kind this build has never heard of stays VISIBLE as a number
  ## instead of being flattened into a plausible-looking label. A bare
  ## `EventLogKind(kindId)` would turn that design into a range-check
  ## exception inside an event handler on the first such recording. The
  ## out-of-range answer is `Error`, which is the one kind whose rendering says
  ## "something is wrong here" rather than inventing a plausible category.
  if kindId >= ord(EventLogKind.low) and kindId <= ord(EventLogKind.high):
    EventLogKind(kindId)
  else:
    EventLogKind.Error

func programEventOf(row: vmtypes.EventLogRow;
                    extras: EventLogRowExtras): ProgramEvent =
  ## The store's neutral row, projected back into the legacy shape this
  ## front-end's renderers and DataTables columns are written against.
  ##
  ## **THE DIRECTION OF THIS ARROW IS THE POINT OF THE WHOLE CHANGE.** It used
  ## to run the other way: `programEventFromTableRow` decoded the wire into a
  ## `ProgramEvent`, the desktop rendered from that, and `storeRowOf` made a
  ## SECOND row out of it for whoever else was reading the store. Two rows from
  ## two conversions, only one of which anybody looked at — so a defect in the
  ## shared one was invisible here, which is exactly how a signal comes to be
  ## filled by a front-end that never reads it.
  ##
  ## Now there is one conversion (`eventLogRowFromTableRow`, in the store) and
  ## this projection. Nine of the fourteen fields below come from `row`,
  ## including every one a pane renders text or navigates by, so the rows the
  ## desktop PAINTS are the rows the store holds: break the store's decoder and
  ## this pane goes wrong with it.
  ##
  ## `tracepointResultIndex` and `bytes` are left at their zero values, which is
  ## what the old decoder wrote into them too — see `EventLogRowExtras` for the
  ## grep that found no reader for either.
  ProgramEvent(
    kind: eventLogKindOf(row.kindId),
    semanticKind: extras.semanticKind,
    content: cstring(row.value),
    rrEventId: extras.rawEventId,
    metadata: extras.metadata,
    highLevelPath: cstring(row.file),
    highLevelLine: row.line,
    directLocationRRTicks: extras.rawLocationRRTicks,
    eventIndex: row.eventIndex,
    tracepointResultIndex: 0,
    base64Encoded: extras.base64Encoded,
    maxRRTicks: int(row.maxRRTicks),
    stdout: row.stdout,
    sourceGeneration: row.sourceGeneration,
    sourceDigest: cstring(row.sourceDigest),
  )

proc syncProgramEventsFromStore(self: EventLogComponent;
                                fallbackRows: seq[vmtypes.EventLogRow] = @[]) =
  ## Rebuild `self.programEvents` from the rows the SHARED STORE is holding.
  ##
  ## THE ONLY WRITER of that field, and the moment the desktop stops keeping a
  ## parallel list. It reads the signal back rather than reusing the seq it just
  ## handed to `applyEventLogRows`, so a producer that replaced or cleared the
  ## window — `EventLogComponent.clear`, `resetForNewSession`, the live
  ## debugger-stop append — is reflected here instead of being silently
  ## outvoted by a copy this component kept.
  ##
  ## `rowExtras` is index-aligned with the window `loadEvents` captured it from,
  ## and that window is by definition the `elwsTable` one — so the extras are
  ## applied ONLY while the store is still holding a table window. Pairing them
  ## with an `elwsEventLoad` window would be worse than dropping them: the rows
  ## would carry another window's metadata, semantic kind and recorder id, all
  ## of them plausible and all of them describing a different event. What a row
  ## with empty extras loses is display text — the metadata string, the raw
  ## semantic kind — plus the two RAW numbers `EventLogRowExtras` keeps for
  ## fidelity. The source location a pane opens is not among them: `file` and
  ## `line` are on the neutral row. `directLocationRRTicks` IS from the extras
  ## and is what `programEventJump` seeks to, but the only reader that can reach
  ## a projected row is `onEnter`, and it needs the DataTables pane to be
  ## holding rows — which is to say a table window has landed and the extras
  ## apply.
  ##
  ## `fallbackRows` is what the caller decoded, used only when there is NO
  ## store to read. That cannot happen in a shipped build — `registerEventLogComponent`
  ## runs `initEventLogVM`, which creates a stub-backed store, long before any
  ## `ct/update-table` reply can arrive — but "the store is missing" must
  ## degrade to the rows this window actually brought rather than to an empty
  ## pane. An Event Log that renders nothing is the one failure this whole
  ## change must not be able to introduce.
  let hasStore = not eventLogVMStore.isNil
  let rows =
    if hasStore: eventLogVMStore.eventLog.rows.val
    else: fallbackRows
  let extrasApply =
    (not hasStore) or
    eventLogVMStore.eventLog.windowSource.val == elwsTable
  var events = newSeqOfCap[ProgramEvent](rows.len)
  for i, row in rows:
    let extras =
      if extrasApply and i < self.rowExtras.len: self.rowExtras[i]
      else: EventLogRowExtras()
    events.add programEventOf(row, extras)
  self.programEvents = events

proc dataTableRowOf(event: ProgramEvent; extras: EventLogRowExtras): JsObject =
  ## One row as DataTables will see it.
  ##
  ## A `ProgramEvent` plus the two path fields the widget's column definitions
  ## name (`data: "fullPath"`) and `ProgramEvent` does not have. The widget used
  ## to be handed raw `TableRow`s instead, which is the mirror image: it had the
  ## paths and lacked `highLevelPath`, `highLevelLine`, `eventIndex` and
  ## `maxRRTicks`, all four of which its own renderers read — so
  ## `eventLogDescriptionRepr(event, event.eventIndex)` was reading `undefined`
  ## off every row it drew. Every field either side of that seam is present now.
  ##
  ## **A COPY, NOT THE ARGUMENT ITSELF** (`PLAT35-PD2`, closed by PLAT-40).
  ## Under the JS backend an object argument is the caller's object, and the
  ## caller passes the variable of a `for` loop — ONE object, overwritten on
  ## every iteration. `event.toJs` handed DataTables that one object once per
  ## row, so every row of the table was the LAST event: `calc`'s six rows all
  ## read `stdout: checksum = 73`. `var row = event` is a fresh object per call.
  var row = event
  result = row.toJs
  # THE LOCATION COLUMN NEVER GOES BLANK FOR A ROW THAT HAS A LOCATION.
  # `fullPath` is the table reply's own text, and a capture of `calc`
  # (PLAT-40's re-take of PLAT-35's `returned-calltrace`) measured a reply
  # whose rows carried none — the column under the `location` header was
  # empty on every row while `highLevelPath`/`highLevelLine`, which the
  # neutral row always carries, said `main.py:111`. The reply's text wins
  # when it has one.
  result.fullPath =
    if extras.fullPath.len > 0: extras.fullPath
    elif event.highLevelPath.len > 0:
      cstring($event.highLevelPath.split("/")[^1] & ":" & $event.highLevelLine)
    else: extras.fullPath
  result.lowLevelLocation = extras.lowLevelLocation

proc renderColumnHeader(tableId: cstring; columns: seq[JsObject]) =
  ## **THE TABLE SAYS WHAT ITS COLUMNS ARE** (`PLAT35-PD2`, closed by
  ## PLAT-40). A strip of header cells above the rows, one per column, each
  ## carrying the column's OWN class — so the class rules that size a body
  ## cell (`.eventLog-index`, `.eventLog-fullpath`, …) size its header cell,
  ## and the two line up without either being measured.
  ##
  ## DataTables' own header row is NOT used: `data_tables.styl` hides it for
  ## every table, and showing it here made the Scroller re-measure the columns
  ## against a table layout these flex rows do not use — a capture with it
  ## visible lost the location column entirely. Drawn again, idempotently, on
  ## every column (re)initialisation, because the column set can change.
  let table = document.getElementById(tableId)
  if table.isNil: return
  var host = table.parentNode
  while not host.isNil and not cast[Element](host).classList.contains(cstring"data-table"):
    host = host.parentNode
  if host.isNil: return
  let old = cast[Element](host).querySelector(cstring".eventLog-column-header")
  if not old.isNil: old.parentNode.removeChild(old)
  let strip = document.createElement(cstring"div")
  strip.className = cstring"eventLog-column-header"
  for column in columns:
    let cell = document.createElement(cstring"span")
    cell.className = column.className.to(cstring)
    cell.textContent = column.title.to(cstring)
    strip.appendChild(cell)
  host.insertBefore(strip, host.firstChild)

proc dataTablePayload(self: EventLogComponent;
                      draw, recordsTotal, recordsFiltered: int): JsObject =
  ## The server-side-processing answer DataTables expects, built from the rows
  ## this component projected out of the store.
  ##
  ## The three counters are passed through from the engine's own reply rather
  ## than recomputed: `recordsTotal` and `recordsFiltered` drive the Scroller's
  ## virtual height and the footer, and they describe the WHOLE log and the
  ## whole filtered log, which a single window cannot know. `draw` is
  ## DataTables' request/response correlation token and must be echoed exactly.
  let extrasApply =
    eventLogVMStore.isNil or
    eventLogVMStore.eventLog.windowSource.val == elwsTable
      ## The same condition `syncProgramEventsFromStore` applies, for the same
      ## reason: the paths in `rowExtras` describe the table window and nothing
      ## else. This call site only ever runs immediately after `loadEvents`, so
      ## the condition holds — it is asserted rather than assumed because a
      ## stale path is a row that offers the wrong file to open.
  var rows = newSeq[JsObject](self.programEvents.len)
  for i, event in self.programEvents:
    let extras =
      if extrasApply and i < self.rowExtras.len: self.rowExtras[i]
      else: EventLogRowExtras()
    rows[i] = dataTableRowOf(event, extras)
  js{
    draw: draw,
    recordsTotal: recordsTotal,
    recordsFiltered: recordsFiltered,
    data: rows,
  }

proc equivalentTableRows(left, right: TableRow): bool =
  left.semanticKind == right.semanticKind and
    left.directLocationRRTicks == right.directLocationRRTicks and
    left.fullPath == right.fullPath and
    left.lowLevelLocation == right.lowLevelLocation and
    left.sourceGeneration == right.sourceGeneration and
    left.sourceDigest == right.sourceDigest

proc makeDebuggerStopRow(self: EventLogComponent; location: types.Location): TableRow =
  let path = locationSourcePath(location)
  let line = locationSourceLine(location)
  let description = cstring(fmt"debugger stop at {path}:{line}")
  let ticks = location.rrTicks
  let eventId =
    if ticks > 0:
      ticks
    else:
      1_000_000_000 + self.liveDebugRows.len

  TableRow(
    directLocationRRTicks: ticks,
    rrEventId: eventId,
    fullPath: cstring(fmt"{path}:{line}"),
    lowLevelLocation: path,
    kind: EventLogKind.Open,
    semanticKind: cstring"debugger-stop",
    content: description,
    metadata: description,
    base64Encoded: false,
    stdout: false,
    sourceGeneration: location.sourceGeneration,
    sourceDigest: safeText(location.sourceDigest)
  )

proc syncLiveDebuggerRowToVM(row: TableRow) =
  if eventLogVMInstance.isNil:
    return

  let eventId =
    if row.directLocationRRTicks > 0:
      uint64(row.directLocationRRTicks)
    else:
      uint64(row.rrEventId)

  # THROUGH THE SHARED DECODER, like every other `TableRow` on this host. This
  # used to be a third hand-written copy of that mapping — it read the row's
  # path and line through two helpers of its own and spelled the display kind
  # as a literal — so it could, and did, disagree with the rows beside it about
  # what a row of this recording looks like.
  #
  # Two fields are then overridden, and both are properties of a LIVE stop
  # rather than of the table shape:
  #
  # * the ticks. A stop at tick 0 is a real position on a db-backend trace
  #   (every position is tick 0 there), so `eventId` — which falls back to the
  #   synthetic `1_000_000_000 + n` that `makeDebuggerStopRow` minted — is the
  #   only identity that distinguishes one stop from the next. The shared
  #   decoder maps a non-positive tick to 0, which is right for a recorded
  #   event and wrong for this one.
  # * `maxRRTicks`. A live head IS the recording's current extent; the table
  #   route carries no extent at all (see `eventLogRowFromTableRow`).
  var liveRow = eventLogRowFromTableRow(row, 0)
  liveRow.eventId = eventId
  liveRow.rrTicks = eventId
  liveRow.maxRRTicks = eventId
  eventLogVMInstance.appendLiveDebuggerStop(liveRow)

proc addLiveDebuggerStopRow(self: EventLogComponent; location: types.Location): bool =
  if not liveEventLogSession():
    return false

  let path = locationSourcePath(location)
  let line = locationSourceLine(location)
  if path.len == 0 or line <= 0:
    return false

  let row = self.makeDebuggerStopRow(location)
  if self.liveDebugRows.len > 0 and
     equivalentTableRows(self.liveDebugRows[^1], row):
    return false

  self.liveDebugRows.add(row)
  syncLiveDebuggerRowToVM(row)
  true

proc mergeLiveDebuggerRows(self: EventLogComponent; data: var TableData): int =
  if self.liveDebugRows.len == 0:
    return 0

  for liveRow in self.liveDebugRows:
    var found = false
    for row in data.data:
      if equivalentTableRows(row, liveRow):
        found = true
        break
    if not found:
      data.data.add(liveRow)
      result += 1

proc tryMountIsoNimEventLogPanel*() =
  ## Mount the IsoNim event log view into the GoldenLayout-managed
  ## event log component container. The container is created by
  ## GoldenLayout with the id `eventLogComponent-0`. The IsoNim view
  ## replaces the previous component content and becomes the primary renderer,
  ## creating the DOM structure that DataTables attaches to.
  ##
  ## After mounting:
  ## - `isoNimEventLogMounted` is set to true
  ## - Generic component rendering stays on the direct mount path
  ## - The GoldenLayout component remains registered while the IsoNim view owns
  ##   the panel DOM directly
  ## - The EventLogComponent's events() runs to init DataTables on the
  ##   IsoNim-created `<table>` elements
  ## - Event handlers (onUpdatedTable, onUpdatedEvents, etc.) still feed
  ##   data through the DataTables API; IsoNim effects can also react
  ##
  ## Safe to call multiple times — mounts only once.
  cdebug "tryMountIsoNimEventLogPanel: called, isoNimEventLogMounted=" & $isoNimEventLogMounted & " vmIsNil=" & $eventLogVMInstance.isNil & " compRefIsNil=" & $eventLogComponentRef.isNil
  if isoNimEventLogMounted or eventLogVMInstance.isNil:
    cdebug "tryMountIsoNimEventLogPanel: skipping (already mounted or VM nil)"
    return
  if eventLogComponentRef.isNil:
    cdebug "tryMountIsoNimEventLogPanel: skipping (eventLogComponentRef is nil)"
    return

  # Wait for the DOM container to exist. GoldenLayout creates it when
  # the component is registered. IsoNim mounts directly into it —
  # no Karax renderer is involved.
  let key = cstring"eventLogComponent-0"
  var eventLogRetryCount = 0
  proc doMount() =
    if isoNimEventLogMounted:
      return
    eventLogRetryCount += 1
    let container = dom_api.getElementById(dom_api.document, key)
    if dom_api.isNodeNil(dom_api.Node(container)):
      if eventLogRetryCount > 200:
        cerror "tryMountIsoNimEventLogPanel: not ready after 200 retries, giving up"
        return
      discard setTimeout(proc() = doMount(), 10)
      return

    let containerNode = dom_api.Node(container)
    while not dom_api.isNodeNil(containerNode.firstChild):
      discard dom_api.removeChild(containerNode, containerNode.firstChild)

    isoNimEventLogMounted = true

    let comp = eventLogComponentRef
    let denseId = "eventLog-" & $comp.id & "-dense-table-" & $comp.index
    let detailedId = "eventLog-" & $comp.id & "-detailed-table-" & $comp.index
    let searchId = "eventLog-" & $comp.id & "-search"

    try:
      mountIsoNimEventLogWithDataTables(
        container,
        eventLogVMInstance,
        comp.id,
        denseId,
        detailedId,
        searchId,
        proc() =
          comp.init = false
          comp.redrawColumns = true
          comp.eventLogAfterRedraws()
      )
      cdebug "tryMountIsoNimEventLogPanel: mount COMPLETE in #eventLogComponent-0"

    except:
      cerror "tryMountIsoNimEventLogPanel: mount EXCEPTION: " & getCurrentExceptionMsg()

  doMount()

var arg: js

const
  CLICK_DELAY_TIMER = 5
  EVENT_LOG_TAG_NAMES: array[EventTag, string] = [
    "std streams",
    "read events",
    "write events",
    "network",
    "trace",
    "file",
    "errors",
    "evm events"
  ]

  EVENT_LOG_KIND_NAMES: array[EventLogKind, string] = [
    "write",
    "write file",
    "write(other)",
    "read",
    "read file",
    "read(other)",
    "read dir",
    "open dir",
    "close dir",
    "socket",
    "open",
    "error",

    "trace log event",
    "messages",
  ]

  EVENT_LOG_BUTTON_NAMES: array[EventDropDownBox, string] = [
    "Filter",
    "Trace events",
    "Recorded events",
    "_"
  ]

let kindTags: array[EventLogKind, seq[EventTag]] = [
  @[EventWrites, EventStd],   #Write
  @[EventWrites, EventFiles], #WriteFile
  @[EventWrites],             #WriteOther
  @[EventReads, EventStd],    #Read
  @[EventReads, EventFiles],  #ReadFile
  @[EventReads],              #ReadOther
  @[],                        #ReadDir
  @[],                        #OpenDir
  @[],                        #CloseDir
  @[EventNetwork],            #Socket
  @[EventFiles],              #Open
  @[EventErrorEvents],        #Error

  @[EventTrace],              #TraceLogEvent
  @[EventEvm]
]

var tagKinds: array[EventTag, seq[EventLogKind]]

for kind, tags in kindTags:
  for tag in tags:
    tagKinds[tag].add(kind)

when defined(ctInExtension):
  var eventLogComponentForExtension* {.exportc.}: EventLogComponent = makeEventLogComponent(data, 0, inExtension = true)

  proc bindEventLogExtensionHost(component: EventLogComponent) =
    if component.extensionRendererId.len == 0:
      return

    let host = document.getElementById(component.extensionRendererId)
    if host.isNil:
      return

    if eventLogComponentRef.isNil:
      eventLogComponentRef = component
    tryMountIsoNimEventLogPanel()

  proc makeEventLogComponentForExtension*(id: cstring): EventLogComponent {.exportc.} =
    if eventLogComponentForExtension.extensionRendererId.len == 0:
      eventLogComponentForExtension.extensionRendererId = id
      eventLogComponentForExtension.bindEventLogExtensionHost()
    result = eventLogComponentForExtension

proc events(self: EventLogComponent)
proc resizeEventLogHandler*(self: EventLogComponent)

proc denseId*(context: EventLogComponent): cstring =
  cstring("eventLog-" & $context.id & "-dense-table-" & $context.index)

proc detailedId*(context: EventLogComponent): cstring =
  cstring("eventLog-" & $context.id & "-detailed-table-" & $context.index)

template local*(expression: untyped): untyped {.dirty.} =
  cstring(self.type.name[0 .. 0].toLowerAscii() & self.type.name[1..^10] & "-" & expression)

proc resizeEventLogHandler*(self: EventLogComponent) =
  if self.denseTable.isNil or self.denseTable.context.isNil:
    return

  self.denseTable.resizeTable()
  if not self.denseTable.footerDom.isNil:
    self.denseTable.updateTableFooter()
  # self.detailedTable.resizeTable()

# `filterEvents` used to sit here: a client-side re-filter of `programEvents`
# by `selectedKinds`. It had no caller, and could not usefully acquire one —
# `EventDb::update_table` applies `selected_kinds` server-side before it builds
# the window, so every row this host receives has already passed that filter.
# Removed with the parallel row list it was written against.

# ---------------------------------------------------------------------------
# Filter dropdown — event-kind / event-tag filter panel
# ---------------------------------------------------------------------------

proc switchEventKindSelection(self: EventLogComponent, kind: EventLogKind) =
  self.selectedKinds[kind] = not self.selectedKinds[kind]

proc changeAllEventKinds(self: EventLogComponent, value: bool) =
  for tag, _ in self.tags:
    for kind in tagKinds[tag]:
      self.selectedKinds[kind] = value

proc isTagSelected(self: EventLogComponent, tag: EventTag): bool =
  var isChecked = true

  for kind in tagKinds[tag]:
    isChecked = self.selectedKinds[kind]
    if self.selectedKinds[kind]:
      break

  return isChecked

proc switchEventTagSelection(self: EventLogComponent, tag: EventTag, value: bool = false) =
  let isChecked = if not value: not self.isTagSelected(tag) else: true

  for kind in tagKinds[tag]:
    self.selectedKinds[kind] = isChecked

proc checkIndeterminateCheckbox(self: EventLogComponent, tag: EventTag): (bool, string) =
  var count = 0

  for kind in tagKinds[tag]:
    if self.selectedKinds[kind]:
      count += 1

  if count > 0 and count == tagKinds[tag].len:
    return (true, "checkmark")
  elif count != 0:
    return (true, "indeterminate-checkmark")
  else:
    return (false, "checkmark")

proc enableOrDisable(self: EventLogComponent): bool =
  var b: bool

  for tag, _ in self.tags:
    for kind in tagKinds[tag]:
      b = not self.selectedKinds[kind]
      if b:
        return b

  return b

proc isOnlyTraceSelected(self: EventLogComponent): bool =
  for tag, _ in self.tags:
    for kind in tagKinds[tag]:
      if self.selectedKinds[kind] and tag != EventTrace:
        return false
      elif not self.selectedKinds[kind] and tag == EventTrace:
        return false

  return true

proc isOnlyRecordedEventSelected(self: EventLogComponent): bool =
  ## True when the current selection matches the "recorded events only" preset:
  ## EventReads, EventFiles, EventNetwork, EventWrites, EventErrorEvents are
  ## fully selected; EventTrace and EventEvm are fully deselected.
  ## This mirrors the exact tags that onlyRecordedEvent() sets so that the
  ## "Recorded events" tab correctly shows as active after clicking it.
  const selectedTags  = [EventReads, EventFiles, EventNetwork,
                          EventWrites, EventErrorEvents]
  const deselectedTags = [EventTrace, EventEvm]

  for tag in selectedTags:
    for kind in tagKinds[tag]:
      if not self.selectedKinds[kind]:
        return false

  for tag in deselectedTags:
    for kind in tagKinds[tag]:
      if self.selectedKinds[kind]:
        return false

  return true

proc onlyTrace(self: EventLogComponent) =
  self.changeAllEventKinds(false)
  self.switchEventTagSelection(EventTrace, true)

proc onlyRecordedEvent(self: EventLogComponent) =
  let eventTags = [EventReads, EventFiles, EventNetwork, EventWrites, EventErrorEvents]

  self.changeAllEventKinds(false)

  for tag in eventTags:
    self.switchEventTagSelection(tag, true)

const FilterDropdownTriggerGap = 6.0
  ## Pixels between the filter button and the menu it opens.  Mirrors
  ## `DROPDOWN_TRIGGER_GAP` in styles/components/shared_widgets.styl, which
  ## every menu positioned by CSS uses; this menu is positioned from JavaScript,
  ## so it cannot read that value.

proc setupFilterDropdown(self: EventLogComponent) =
  ## Wire up the #category-image filter button to show/hide the event-kind
  ## filter dropdown.  Called once from eventLogAfterRedraws after the IsoNim
  ## shell has been mounted and DataTables has been initialised.
  ##
  ## The dropdown container is appended once to document.body (hidden) and
  ## repositioned on each show.  Content is refreshed via IsoNim DSL on every
  ## state change (mountFilterDropdownInto clears and remounts).
  let dropDownId = cstring"category-image"
  let containerId = cstring FilterDropdownContainerId

  proc showDropdown()  # forward decl

  proc reloadDenseTableAndRefresh() =
    if not self.denseTable.isNil and not self.denseTable.context.isNil:
      self.denseTable.context.ajax.reload(nil, false)
      self.autoScrollUpdate = true
    showDropdown()

  proc buildFilterTabs(): seq[FilterTabRecord] =
    @[
      FilterTabRecord(
        label: EVENT_LOG_BUTTON_NAMES[EventDropDownBox.OnlyTrace],
        isSelected: self.isOnlyTraceSelected()),
      FilterTabRecord(
        label: EVENT_LOG_BUTTON_NAMES[EventDropDownBox.OnlyRecordedEvent],
        isSelected: self.isOnlyRecordedEventSelected()),
    ]

  proc buildFilterRows(): seq[FilterTagRow] =
    for tag, _ in self.tags:
      let (isChecked, stateStr) = self.checkIndeterminateCheckbox(tag)
      let checkState =
        if stateStr == "indeterminate-checkmark": "indeterminate"
        elif isChecked: "checked"
        else: "unchecked"
      var kinds: seq[FilterKindRecord]
      for kind in tagKinds[tag]:
        kinds.add(FilterKindRecord(
          label: EVENT_LOG_KIND_NAMES[kind],
          checkState: if self.selectedKinds[kind]: "checked" else: "unchecked"))
      result.add(FilterTagRow(
        label: EVENT_LOG_TAG_NAMES[tag],
        checkState: checkState,
        kinds: kinds))

  proc buildFilterCallbacks(): FilterDropdownCallbacks =
    FilterDropdownCallbacks(
      onTabClick: proc(tabIndex: int) =
        case tabIndex
        of 0: self.onlyTrace()
        of 1: self.onlyRecordedEvent()
        else: discard
        reloadDenseTableAndRefresh(),
      onTagToggle: proc(tagIndex: int) =
        self.switchEventTagSelection(EventTag(tagIndex))
        reloadDenseTableAndRefresh(),
      onKindToggle: proc(tagIndex, kindIndex: int) =
        let kind = tagKinds[EventTag(tagIndex)][kindIndex]
        self.switchEventKindSelection(kind)
        reloadDenseTableAndRefresh(),
      onToggleEnabled: proc() =
        ## Toggle all kinds on or off.  enableOrDisable() returns true when at
        ## least one kind is currently deselected — clicking should enable all.
        ## When all are already selected it returns false — clicking disables all.
        self.changeAllEventKinds(self.enableOrDisable())
        reloadDenseTableAndRefresh())

  proc showDropdown() =
    var containerKdom = document.getElementById(containerId)

    if containerKdom.isNil:
      # Create the container once and attach the mousedown preventDefault
      # listener so clicks inside the dropdown do not blur the filter button.
      containerKdom = document.createElement(cstring"div")
      containerKdom.setAttribute(cstring"id", containerId)
      containerKdom.setAttribute(cstring"class", cstring"dropdown-container")
      containerKdom.addEventListener(cstring"mousedown", proc(e: Event) =
        e.preventDefault())
      document.body.appendChild(containerKdom)

    # Refresh content using IsoNim DSL — clears old children, remounts.
    # filtersEnabled = not enableOrDisable(): toggle is ON when all kinds selected.
    mountFilterDropdownInto(
      cast[dom_api.Element](containerKdom),
      buildFilterTabs(),
      buildFilterRows(),
      not self.enableOrDisable(),
      buildFilterCallbacks())

    let filterButton = document.getElementById(dropDownId)
    let rect = filterButton.getBoundingClientRect()
    containerKdom.style.position = "absolute"
    # The gap every menu leaves below its trigger.  It lives in CSS for the
    # menus a stylesheet can position (`DROPDOWN_TRIGGER_GAP`,
    # styles/components/shared_widgets.styl); this one is placed from a
    # measured rect because it is appended to `document.body`, so the same
    # 6px has to be added here.
    containerKdom.style.top = &"{rect.bottom + FilterDropdownTriggerGap}px"
    containerKdom.style.left = &"{rect.left}px"
    containerKdom.style.zIndex = "1000".cstring
    containerKdom.style.display = "block"
    filterButton.classList.add(cstring"open")
    filterButton.focus()

  proc hideDropdown() =
    let containerKdom = document.getElementById(containerId)
    if not containerKdom.isNil:
      containerKdom.style.display = "none"
    let filterButton = document.getElementById(dropDownId)
    if not filterButton.isNil:
      filterButton.classList.remove(cstring"open")

  # Attach handlers to the already-mounted #category-image button.
  let filterBtn = document.getElementById(dropDownId)
  if filterBtn.isNil:
    cwarn "setupFilterDropdown: #category-image not found in DOM"
    return

  filterBtn.addEventListener(cstring"focus", proc(e: Event) =
    self.focusedDropDowns[Filter] = true
    showDropdown())

  filterBtn.addEventListener(cstring"blur", proc(e: Event) =
    if self.dropDowns[Filter] or self.focusedDropDowns[Filter]:
      self.focusedDropDowns[Filter] = false
      self.dropDowns[Filter] = false
      hideDropdown())

  filterBtn.addEventListener(cstring"click", proc(e: Event) =
    for categoryType, value in self.dropDowns:
      if categoryType == Filter:
        self.dropDowns[categoryType] = not self.dropDowns[Filter]
    if not self.dropDowns[Filter] and self.focusedDropDowns[Filter]:
      cast[Element](e.target).blur())

  filterBtn.addEventListener(cstring"keydown", proc(e: Event) =
    ## Escape closes the menu, as it does for every other dropdown (see
    ## `setupDropdownDismissListeners` in ui/layout.nim, which handles the ones
    ## it can reach).  This menu is not in that registry: dismissal there works
    ## by re-clicking the trigger, and this trigger's open state is carried by
    ## focus rather than by a class — clicking it while open only toggles
    ## `dropDowns[Filter]` back on and leaves the menu up.
    ##
    ## The listener sits on the button because the button is what holds focus
    ## the whole time the menu is open: `showDropdown` focuses it, and the
    ## container swallows mousedown so clicking a checkbox never takes focus
    ## away.
    if cast[KeyboardEvent](e).keyCode == ESC_KEY_CODE:
      e.preventDefault()
      # Escape is a global shortcut too; without this the same press would
      # also reach the document-level handlers.
      e.stopPropagation()
      # Both flags first, so the `blur` below finds nothing left to close and
      # the next click on the button opens the menu rather than toggling a
      # state that says it is already open.
      self.focusedDropDowns[Filter] = false
      self.dropDowns[Filter] = false
      hideDropdown()
      filterBtn.blur())

proc findElement(self: EventLogComponent): Element =
  var denseTable = self.denseTable
  let context = denseTable.context

  if not context.isNil:
    let rows = context.rows()
    let indexes = rows.indexes()
    let denseTableRows =
      cast[seq[ProgramEvent]](rows.data())

    for i, _ in denseTableRows:
      let index = i + self.hiddenRows
      let datatableRow = context.row(indexes[i])
      let domNode = cast[Element](datatableRow.node())

      if not domNode.isNil:
        domNode.classList.remove("event-selected")

        if index == self.rowSelected:
          result = domNode

proc focusItem*(self: EventLogComponent) =
  let denseTable = self.denseTable
  let rowSelected = self.rowSelected
  let selectedRow = self.findElement()

  if not selectedRow.isNil:
    selectedRow.classList.add("event-selected")

proc findActiveRow(self: EventLogComponent, rrTicks: int, isEventJump: bool = false) =
  var denseTable = self.denseTable
  let context = denseTable.context
  cdebug "eventLog: findActiveRow"

  if not context.isNil:
    let debuggerLocationRRTicks = rrTicks
    let rows = context.rows()
    let indexes = rows.indexes()
    let denseTableRows =
      cast[seq[ProgramEvent]](rows.data())

    for i, row in denseTableRows:
      let index = i  + self.hiddenRows
      let datatableRow = context.row(indexes[i])
      let domNode = cast[Element](datatableRow.node())

      if not domNode.isNil:
        domNode.classList.remove("past")
        domNode.classList.remove("active")
        domNode.classList.remove("future")
        rowTimestamp(domNode, row, rrTicks)

      if not isEventJump:
        if row.directLocationRRTicks == debuggerLocationRRTicks:
          denseTable.activeRowIndex = index
          self.rowSelected = index
      else:
        if index > 0 and
          row.directLocationRRTicks >= debuggerLocationRRTicks and
          denseTableRows[i-1].directLocationRRTicks <= debuggerLocationRRTicks:
            denseTable.activeRowIndex = index
            self.rowSelected = index

    self.focusItem()

    if denseTable.autoScroll and isEventJump:
      scrollTable(denseTable, $(denseTable.activeRowIndex))

proc refreshDimming*(self: EventLogComponent) =
  ## Re-stamp `past` / `active` / `future` on every rendered row against the
  ## debugger's current position. This is the WHOLE of what a move does to the
  ## Event Log: the rows are static, so moving the reader can only move the
  ## boundary between what has happened and what has not
  ## (`GUI/Core-Panes/Event-Log-Pane.md` § "What a move changes, and what it
  ## does not").
  ##
  ## IT HAS TO BE EXPLICIT, AND IT DID NOT USED TO BE. Re-stamping happened as
  ## a side effect of the table being rebuilt on every move: `onUpdatedTable`
  ## ends by calling `findActiveRow`, which re-classes every row. So the pane
  ## got its dimming right by way of the very rebuild that was emptying it, and
  ## removing the rebuild removed the only thing refreshing the classes.
  ##
  ## `findActiveRow` is not a substitute even now, because `onCompleteMove`
  ## reaches it only on some paths — when the selected row lands outside the
  ## visible window and `autoScroll` is on, the move goes through
  ## `scrollOnMove`, which scrolls and never re-classes. Rows already rendered
  ## then keep whatever they were stamped with at creation, which is how an
  ## event BEFORE the current position stays dimmed after a jump forwards.
  ##
  ## Selection, focus and scrolling are deliberately not touched here. Those
  ## are separate gestures with their own conditions; conflating them is what
  ## left the dimming dependent on which branch a move happened to take.
  if self.denseTable.isNil:
    return
  let context = self.denseTable.context
  if context.isNil:
    return
  let rows = context.rows()
  let indexes = rows.indexes()
  let rowData = cast[seq[ProgramEvent]](rows.data())
  for i, row in rowData:
    let domNode = cast[Element](context.row(indexes[i]).node())
    if not domNode.isNil:
      domNode.classList.remove("past")
      domNode.classList.remove("active")
      domNode.classList.remove("future")
      rowTimestamp(domNode, row, self.activeRowTicks)

method onFocus*(self: EventLogComponent) {.async.} =
  self.focusItem()

func filename*(event: ProgramEvent): cstring =
  event.highLevelPath.split("/")[^1]

func reprAndLang(eventElement: ProgramEvent, index: int): (string, Lang) =
  let (name, lang) =
    case eventElement.kind:
    of WriteFile:
      (
        fmt"event:write to {eventElement.metadata} #{index}",
        toLangFromFilename(eventElement.metadata)
      )

    of ReadFile:
      (
        fmt"event:read from {eventElement.metadata} #{index}",
        toLangFromFilename(eventElement.metadata)
      )

    of WriteOther:
      (
        fmt"event:write: {eventElement.metadata} #{index}",
        LangUnknown
      )

    of ReadOther:
      (
        fmt"event:read: {eventElement.metadata} #{index}",
        LangUnknown
      )

    of Write:
      let into = if eventElement.stdout: "stdout" else: "stderr"
      (fmt"event:write to {into} #{index}", LangUnknown)

    of Read:
      ("event: read from stdin #{index}", LangUnknown)

    else:
      (fmt"event: {eventElement.kind} #{index}", LangUnknown)

  (name, lang)

func eventLogDescriptionRepr(eventElement: ProgramEvent, index: int): string =
  if not eventElement.semanticKind.isNil and eventElement.semanticKind.len > 0:
    case $eventElement.semanticKind
    of "debugger-stop":
      if eventElement.metadata.len > 0:
        return $eventElement.metadata
      elif eventElement.highLevelPath.len > 0 and eventElement.highLevelLine > 0:
        return fmt"debugger stop at {eventElement.highLevelPath}:{eventElement.highLevelLine}"
      else:
        return $eventElement.content
    else:
      discard

  case eventElement.kind:
    of Write:
      let into = if eventElement.stdout: "stdout" else: "stderr"
      fmt"{into}: {eventElement.content}"

    of Read:
      fmt"stdin: {eventElement.content}"

    of WriteFile:
      fmt"write to {eventElement.metadata}: {eventElement.content}"

    of ReadFile:
      fmt"read from {eventElement.metadata}: {eventElement.content}"

    of WriteOther:
      fmt"write: {eventElement.metadata}: {eventElement.content}"

    of ReadOther:
      fmt"read: {eventElement.metadata}: {eventElement.content}"

    of OpenDir, ReadDir, CloseDir:
      "eventually TODO"

    of Socket:
      fmt"socket: {eventElement.content}"

    of EventLogKind.Open:
      fmt"open {eventElement.metadata}"

    of EventLogKind.Error:
      fmt"error: {eventElement.content}"

    of EventLogKind.EvmEvent:
      if eventElement.metadata != "":
        fmt"{eventElement.metadata}: {eventElement.content}"
      else:
        fmt"{eventElement.content}"
    else:
      fmt"event {eventElement.kind}"

proc eventJump(self: EventLogComponent, event: ProgramEvent) =
  if not eventLogVMStore.isNil:
    eventLogVMStore.enterHistoricalModeForNavigation()
  self.api.emit(CtEventJump, event)
  self.api.emit(InternalNewOperation, NewOperation(name: fmt"Event jump #{event.rrEventId}", stableBusy: true))

proc programEventJump(self: EventLogComponent, event: ProgramEvent) =
  self.findActiveRow(event.directLocationRRTicks)
  self.activeRowTicks = event.directLocationRRTicks
  self.eventJump(event)

const DELAY: int64 = 200 # milliseconds

proc findTRNode*(node: js): js =
  return if node.tagName.to(cstring) == cstring("TR"):
    node else: findTRNode(node.parentNode)

proc jump(self: EventLogComponent, table: JsObject, e: JsObject) =
  cdebug "event_log: handler jump"
  var node = e.target

  if node.tagName.to(cstring) == cstring("TBODY"):
    return

  let trNode = node.findTRNode();
  let nodeRow = table.row(trNode)
  let data = nodeRow.data()
  var event: ProgramEvent

  if data.toJs != jsUndefined:
    # The row DataTables is holding IS this component's own projection of the
    # store's row (`dataTableRowOf`), so the clicked row can be read straight
    # back out instead of being decoded a third time. That third decode was
    # not merely redundant: it ran `programEventFromTableRow(row, 0, …)` on a
    # row object that carried no `highLevelPath`, no `highLevelLine` and no
    # `maxRRTicks` — `ct/update-table` sends none of the three — and stamped
    # `eventIndex` as the literal 0 for every row in the log. `ct/event-jump`
    # deserialises a whole `ProgramEvent` on the Rust side with none of those
    # three defaulted, so the jump payload was incomplete by construction.
    event = cast[ProgramEvent](data)
  else:
    # DataTables emits placeholder rows while the table is empty; they are not real events.
    return
  self.programEventJump(event)
  # if self.data.ui.activeFocus != self:
  #   self.data.focusComponent(self)

proc events(self: EventLogComponent) =
  var context = self

  proc reinit(self: EventLogComponent) =
    self.kinds = JsAssoc[EventLogKind, bool]{}
    self.kindsEnabled = JsAssoc[EventLogKind, bool]{}
    self.tags = JsAssoc[EventTag, bool]{}
    for kind in EventLogKind.low .. EventLogKind.high:
      self.kinds[kind] = true
      self.kindsEnabled[kind] = true
    for tag in EventTag.low .. EventTag.high:
      self.tags[tag] = true

  proc handler(table: js, e: js) =
    let currentTime: int64 = now()
    if currentTime - self.lastJumpFireTime > CLICK_DELAY_TIMER:
      self.lastJumpFireTime = currentTime
      let isAction = cast[bool](e.target.classList[0] == "row-expander".toJs)
      if isAction:
        let textElement = e.currentTarget.childNodes[3]
        if textElement.classList[0] == "eventLog-text".toJs:
          if textElement.style.toJs.maxHeight == "24px".toJs:
            textElement.style.overflow = "auto"
            textElement.style.maxHeight = "20ch".toJs
            e.target.classList.remove("flow-hide-content")
            e.target.classList.add("flow-show-content")
          else:
            textElement.style.overflow = ""
            textElement.style.maxHeight = "24px".toJs
            e.target.classList.remove("flow-show-content")
            e.target.classList.add("flow-hide-content")
      else:
        self.jump(table, e)

  proc handlerMouseover(table: js, e: js) =
    discard

  proc handlerRightClick(table: js, e: js) =
    e.preventDefault()

    var node = e.target

    if node.tagName.to(cstring) == cstring("TBODY"):
      return

    let trNode = node.findTRNode();
    let nodeRow = table.row(trNode)
    let data = nodeRow.data()
    var index = 0
    var event: ProgramEvent

    if data.toJs != jsUndefined:
      event = cast[ProgramEvent](data)
    else:
      # Empty-table placeholder rows should not open an event view.
      return

    if event.kind != TraceLogEvent:
      let (name, lang) = reprAndLang(event, event.eventIndex)

      # open an editor
      self.data.makeEditorView(
        name,
        event.content.split("\\n").join(jsNl),
        ViewEventContent,
        lang
      )

  domwindow.handler = handler

  if not self.init or self.redrawColumns:
    console.time(cstring"new events: load in datatable: columns init")
    if not self.init:
      self.reInit()
    else:
      try:
        self.denseTable.context.clear().destroy()
        self.detailedTable.context.clear().destroy()
      except:
        cerror "event_log: " & getCurrentExceptionMsg()
        discard

    var ret = false

    try:
      var denseColumns = @[
          js{
            # width: cstring"100px",
            className: cstring"direct-location-rr-ticks eventLog-cell",
            data: cstring"directLocationRRTicks",
            orderable: true,
            targets: 0,
            title: cstring"tick",
            render: proc(directLocationRRTicks: int): cstring =
              renderRRTicksLine(directLocationRRTicks, self.data.minRRTicks, self.data.maxRRTicks, "event-rr-ticks-line")
          },
          js{
            className: cstring"eventLog-index eventLog-cell",
            data: cstring"rrEventId",
            title: cstring"#"
          },
      ]
      if self.usesMaterializedTracesTrace:
        let lower = cstring("FullPath".toLowerAscii())

        denseColumns.add(
          js{
            className: cstring"eventLog-" & lower & " " & local("cell"),
            searchable: true,
            title: cstring"location",
            data: cstring"fullPath",
          }
        )
      denseColumns.add(
        @[
          js{
            className: cstring"eventLog-event eventLog-cell",
            searchable: true,
            data: cstring"kind",
            title: cstring"",
            render: proc(kind: EventLogKind, t: js, event: ProgramEvent): cstring =
              if event.content.split("\n").len() == 2 and event.content.split("\n")[^1] == "":
                cstring""
              elif event.content.split("\n").len() > 1:
                cstring"""<span class="row-expander flow-hide-content flow-view-more-button"/>"""
              else:
                cstring""
          },
          js{
            className: cstring"eventLog-text eventLog-cell",
            searchable: true,
            data: cstring"content",
            title: cstring"output",
            render: proc(content: cstring, t: js, event: ProgramEvent): cstring =
              let text = case event.kind:
                of Write, WriteFile, WriteOther, Read, ReadFile, ReadOther,
                  OpenDir, ReadDir, CloseDir, Socket, EventLogKind.Open, EventLogKind.Error, EventLogKind.EvmEvent:
                  cstring(eventLogDescriptionRepr(event, event.eventIndex))

                of TraceLogEvent:
                  event.content

              text
          }
        ]
      )

      var detailedColumns = @[
          js{
            className: cstring"eventLog-detailed-index eventLog-cell",
            data: cstring"rrEventId"},
          js{
            className: cstring"eventLog-detailed-event eventLog-cell",
            searchable: true,
            data: cstring"kind",
            render: proc(event: EventLogKind): cstring =
              cstring""
          },
       ]

      console.timeEnd(cstring"new events: load in datatable: columns init")
      console.time(cstring"new events: load in datatable: optional columns")

      var renderColumns: array[
          EventOptionalColumn,
          proc(content: cstring, t: js, event: ProgramEvent): cstring
        ] =
        [
          proc(content: cstring, t: js, event: ProgramEvent): cstring {.closure.} =
            if event.kind != TraceLogEvent:
              cstring"&lt;unknown before jump&gt;"
            else:
              let filename = event.filename
              let line = event.highLevelLine
              cstring(fmt"{filename}:{line}"),
          proc(content: cstring, t: js, event: ProgramEvent): cstring {.closure.} =
            cstring"low level location"
        ]

      # if self.usesMaterializedTracesTrace:
      #   let lower = cstring("FullPath".toLowerAscii())

      #   denseColumns.add(
      #     js{
      #       className: cstring"eventLog-" & lower & " " & local("cell"),
      #       searchable: true,
      #       title: lower,
      #       data: cstring"fullPath",
      #     }
      #   )
      #   if false:
      #     let lower = cstring("LowLevelLocation".toLowerAscii())

      #     denseColumns.add(
      #       js{
      #         className: cstring"eventLog-" & lower & " " & local("cell"),
      #         searchable: true,
      #         title: lower,
      #         data: cstring"lowLevelLocation",
      #       }
      #     )

      console.timeEnd(cstring"new events: load in datatable: optional columns")
      console.time(cstring"new events: load in datatable: dense datatable preparation and call")

      let denseTableElement = jqFind(cstring"#" & self.denseId)

      denseTableElement.DataTable.ext.errMode = cstring"throw"
      self.denseTable.context = denseTableElement.DataTable(
        js{
          serverSide:     true,
          deferRender:    true,
          processing:     true,
          ordering:       true,
          searching:      true,
          scrollY:        2000,
          scrollCollapse: true,
          scroller:       true,
          scrollerCollapse: true,
          fixedColumns:   true,
          info: false,
          lengthChange: false,
          search: false,
          label: false,
          layout: js{
            top:        nil,
            topStart:   nil,
            topEnd:     nil,
            bottom:     nil,
            bottomStart:nil,
            bottomEnd:  nil
          },
          pageLength: -1,
          order:          @[[0.toJs, (cstring"asc").toJs]],
          colResize:      js{
            isEnabled: true,
            saveState: true},
          columns:        denseColumns,
          bInfo: false,
          # DataTables calls `createdRow(row, data, dataIndex, cells)`, so the
          # third argument is the row's ORDINAL, not a position on the
          # timeline.  Passing `rowTimestamp` straight in therefore compared
          # each event's `directLocationRRTicks` against a row number: for any
          # real trace the ticks dwarf the ordinal, so nearly every freshly
          # created row was classed `future` — `opacity: 0.5` on the whole
          # table — until a later `findActiveRow` happened to re-class it with
          # the real position.  When that correction does not run, the table
          # stays uniformly dimmed.  Dim against the debugger's actual
          # position instead; `self.activeRowTicks` is what `findActiveRow`
          # uses, so both paths now agree.
          createdRow: proc(row: Element, event: ProgramEvent, dataIndex: int) =
            rowTimestamp(row, event, self.activeRowTicks),
          language: js{
            emptyTable: proc: cstring =
              # TODO if self.receivedUpdates:
              """The current record appears to not have any system events like std read/write,
              network or disc operations. You can add trace point events to your code by selecting any
              line of code and pressing "Enter"""".cstring
              # else:
              #   "Loading record events...".cstring
          },
          ajax: proc(
            data: TableArgs,
            callback: proc(data: js),
            settings: js
          ) =
            var mutData = data
            self.tableCallback = callback
            self.drawId += 1
            mutData.draw = self.drawId
            self.drawId = mutData.draw
            self.hiddenRows = data.start
            let updateTableArgs =
              UpdateTableArgs(
                tableArgs: mutData,
                selectedKinds: self.selectedKinds,
                isTrace: false,
                eventSlot: 0,
              )
            self.api.emit(CtUpdateTable, updateTableArgs),
        }
      )
      renderColumnHeader(self.denseId, denseColumns)

      console.timeEnd(cstring"new events: load in datatable: dense datatable preparation and call")

    except:
      cerror "event_log: " & getCurrentExceptionMsg()
      console.timeEnd(cstring"new events: load in datatable: columns init")
      console.timeEnd(cstring"new events: load in datatable: optional columns")
      console.timeEnd(cstring"new events: load in datatable: dense datatable preparation and call")

      ret = true

    if ret:
      return

    console.time(cstring"new events: load in datatable: context changes and handlers")

    context.init = true
    context.denseTable.context = jqFind(cstring"#" & context.denseId).DataTable()
    context.detailedTable.context = jqFind(cstring"#" & context.detailedId).DataTable()
    context.redrawColumns = context.tableCallback.isNil
    context.eventsIndex = self.programEvents.len

    cdebug "event_log: setup " & $(cstring"#" & context.denseId & cstring" tbody")
    # cdebug "event_log: setup " & $(cstring"#" & context.detailedId & cstring" tbody")
    jqFind(cstring"#" & context.denseId & cstring" tbody").on(cstring"click", cstring"tr", proc(e: js) = handler(context.denseTable.context, e))
    jqFind(cstring"#" & context.detailedId & cstring" tbody").on(cstring"click", cstring"tr", proc(e: js) = handler(context.detailedTable.context, e))
    jqFind(cstring"#" & context.denseId & cstring" tbody").on(cstring"mouseover", cstring"td", proc(e: js) = handlerMouseover(context.denseTable.context, e))
    jqFind(cstring"#" & context.denseId & cstring" tbody").on(cstring"contextmenu", cstring"tr", proc(e: js) = handlerRightClick(context.denseTable.context, e))

    console.timeEnd(cstring"new events: load in datatable: context changes and handlers")

  else:

    console.time(cstring"new events: load in datatable: redraw")

    var events = self.programEvents

    console.timeEnd(cstring"new events: load in datatable: redraw")
    cdebug "event_log: setup " & $(cstring"#" & context.denseId & cstring" tbody")
    # cdebug "event_log: setup " & $(cstring"#" & context.detailedId & cstring" tbody")
    jqFind(cstring"#" & context.denseId & cstring" tbody").on(cstring"click", cstring"tr", proc(e: js) = handler(context.denseTable.context, e))
    let denseWrapper = cstring"#" & self.denseId & cstring"_wrapper"
    let denseScrollBody = cast[Node](jq(denseWrapper)).findNodeInElement(".dt-scroll-body")
    if not denseScrollBody.isNil:
      denseScrollBody.addEventListener(
        cstring"scroll",
        proc () =
          self.denseTable.updateTableRows(redraw = false)
          if not self.denseTable.footerDom.isNil:
            self.denseTable.updateTableFooter()
      )

    let detailedWrapper = cstring"#" & self.detailedId & cstring"_wrapper"
    let detailedScrollBody = cast[Node](jq(detailedWrapper)).findNodeInElement(".dt-scroll-body")
    if not detailedScrollBody.isNil:
      detailedScrollBody.addEventListener(
        cstring"scroll",
        proc () =
          self.detailedTable.updateTableRows(redraw = false)
          if not self.detailedTable.footerDom.isNil:
            self.detailedTable.updateTableFooter()
      )
    jqFind(cstring"#" & context.detailedId & cstring" tbody").on(cstring"click", cstring"tr", proc(e: js) = handler(context.detailedTable.context, e))
    jqFind(cstring"#" & context.denseId & cstring" tbody").on(cstring"mouseover", cstring"td", proc(e: js) = handlerMouseover(context.denseTable.context, e))
    jqFind(cstring"#" & context.denseId & cstring" tbody").on(cstring"contextmenu", cstring"tr", proc(e: js) = handlerRightClick(context.denseTable.context, e))

    if self.resizeObserver.isNil:
      let componentTab = cast[Node](jq(&"#eventLogComponent-{self.id}"))
      let resizeObserver = createResizeObserver(proc(entries: seq[Element]) =
        for entry in entries:
          let timeout = setTimeout(proc =
            resizeEventLogHandler(self), 100))
      resizeObserver.observe(componentTab)
      self.resizeObserver = resizeObserver


proc loadEvents*(self: EventLogComponent, update: TableData) =
  ## Take one `ct/update-table` window: decode it ONCE into the shared store,
  ## then project the store's rows back out as this front-end's `ProgramEvent`s.
  ##
  ## THE ORDER IS THE WHOLE DESIGN. The store is written first and read second,
  ## so the rows the desktop goes on to render are the rows every other consumer
  ## of `ReplayDataStore.eventLog` — the IsoNim event-log view, the VS Code
  ## surface built from the same `src/frontend`, the GPUI shell — is holding.
  ## Before this, the desktop decoded the window into `ProgramEvent`s for
  ## itself and published a SECOND conversion into the store that nothing here
  ## read back, which is why the shared signal could be wrong for a whole
  ## release without anyone seeing it.
  ##
  ## THE ABSOLUTE INDEX IS `hiddenRows`, not the page-local offset. DataTables
  ## hands the component `data.start` on every ajax call and it is kept there;
  ## a page fetched at start 40 holds absolute indices 40..n+40, and every
  ## pane's cursor is in that coordinate.
  ##
  ## `recordsTotal` / `recordsFiltered` come from the engine here, so they are
  ## passed rather than inferred: a search that matched fewer rows has to be
  ## able to lower the count.
  console.log(cstring(fmt"event_log: loadEvents records={update.data.len} draw={update.draw}"))
  if update.data.len() > 0:
    self.receivedUpdates = true

  self.rowExtras = @[]
  for row in update.data:
    self.rowExtras.add extrasOf(row)

  let decoded = eventLogRowsFromTableRows(update.data, self.hiddenRows,
                                          int64(data.maxRRTicks))
  if not eventLogVMStore.isNil:
    eventLogVMStore.applyEventLogRows(
      decoded, self.hiddenRows, update.recordsTotal, update.recordsFiltered,
      source = elwsTable)
  self.syncProgramEventsFromStore(decoded)


method onUpdatedTable*(self: EventLogComponent, res: CtUpdatedTableResponseBody) {.async.} =
  let component = self
  let response = res.tableUpdate

  if not response.isTrace and self.drawId == response.data.draw:
    let dt = self.denseTable
    var mutData = response.data

    let liveRowsAdded = self.mergeLiveDebuggerRows(mutData)
    if liveRowsAdded > 0:
      mutData.recordsTotal = response.data.recordsTotal + liveRowsAdded
      mutData.recordsFiltered = response.data.recordsFiltered + liveRowsAdded

    dt.rowsCount = mutData.recordsTotal

    for i, row in mutData.data:
      if row.base64Encoded:
        mutData.data[i].content = cstring(decode($mutData.data[i].content))

    # Capture before loadEvents because loadEvents sets receivedUpdates = true
    # when data arrives; we use this to fire resizeEventLogHandler only once.
    let isFirstDataLoad = not self.receivedUpdates

    self.loadEvents(mutData)

    # UNTOUCHED HAZARD, NAMED SO IT IS NOT LOST: this call is unguarded, and
    # `restart()` sets `self.tableCallback = nil`. A `ct/update-table` reply
    # that lands after a restart therefore calls nil. It is a stale-reference
    # bug of the same family as the four reported separately (a reference
    # outliving the thing it describes), it is NOT the cause of the Event Log
    # disappearing after a jump — that was the refetch-on-move above — and it
    # was left alone deliberately rather than folded into a fix for a
    # different defect.
    #
    # THE ROWS HANDED TO DATATABLES ARE THE STORE'S. `loadEvents` above wrote
    # this window into `ReplayDataStore` and read it back as
    # `self.programEvents`; `dataTablePayload` renders exactly those, so the
    # widget the user is looking at is downstream of the shared decode rather
    # than beside it. Handing `mutData` straight through — the raw
    # `ct/update-table` body — is what made the store's copy unfalsifiable
    # here.
    self.tableCallback(self.dataTablePayload(
      mutData.draw, mutData.recordsTotal, mutData.recordsFiltered))
    self.redraw()

    # Re-sync scroll-area dimensions after the first batch of real data lands.
    # On startup the virtual scroll area is 0-height (no rows yet), so mouse-
    # wheel scroll is locked until the Scroller learns the real recordsTotal.
    # The Scroller's own draw.dt→measure(false) may also reset the scroll body
    # height to a stale value; re-applying after a setTimeout(0) lets it finish
    # first, then we restore the panel height and re-measure.
    # We only do this once (isFirstDataLoad) — calling it on every update would
    # trigger scroller.measure() mid-scroll and snap the table back to the top.
    if isFirstDataLoad and mutData.recordsTotal > 0:
      discard setTimeout(proc = resizeEventLogHandler(self), 0)

    # The IsoNim event-log shell renders the footer once with a static
    # class string (`data-tables-footer 0to0`) and child counters fixed
    # at "0".  The current shell is mounted once and table redraws do not
    # rebuild that wrapper, so its class string and inner texts must be
    # updated explicitly after each ajax callback.  `updateTableRows` recomputes
    # `startRow`/`endRow` from the Scroller's current page and the new
    # `rowsCount`; `updateTableFooter` then writes those values into
    # the visible counters and parent class.  Page-object tests parse
    # the parent `.data-tables-footer` class with `(\d*)to`, so keeping
    # it in sync is part of the test contract.
    if not dt.isNil and not dt.context.isNil:
      dt.updateTableRows(redraw = false)
      if not dt.footerDom.isNil:
        dt.updateTableFooter()

    if self.autoScrollUpdate:
      self.findActiveRow(self.activeRowTicks, true)
      self.autoScrollUpdate = false
    else:
      self.findActiveRow(self.activeRowTicks)

    # When the backend returns 0 records but the debugger has already
    # positioned (self.started), the event data may not have been loaded
    # yet (ct/event-load still in flight).  Schedule retries with
    # exponential back-off so DataTables eventually populates once the
    # backend is ready.  Stop retrying after events arrive or after a
    # maximum number of attempts to avoid infinite spinning.
    if response.data.recordsTotal == 0 and self.started and
       self.liveDebugRows.len == 0 and
       not self.receivedUpdates and
       self.pendingReloadRetries < eventLogMaxReloadRetries:
      self.pendingReloadRetries += 1
      let delay = 250 * self.pendingReloadRetries  # 250, 500, 750, ... ms
      # Legitimate, hence DEBUG.  The comment above says it: an empty
      # first page means `ct/event-load` is still in flight, which is the
      # normal ordering on every trace open.  The retry below is the
      # designed response, and it is bounded, so the condition is expected
      # and already handled — it is not an error.  Exhausting the budget
      # IS, and the `elif` below is what reports it: demoting this line
      # without adding that would have left the failing case with no
      # signal at any level.
      cdebug "[PIPELINE] event_log: onUpdatedTable got 0 records, scheduling reload retry " &
             $self.pendingReloadRetries & " in " & $delay & "ms"
      setTimeoutWithArg(proc(comp: EventLogComponent) {.cdecl.} =
        if not comp.receivedUpdates and
           not comp.denseTable.isNil and not comp.denseTable.context.isNil:
          comp.denseTable.context.ajax.reload(nil, false)
      , delay, component)
    elif response.data.recordsTotal == 0 and self.started and
         self.liveDebugRows.len == 0 and
         not self.receivedUpdates and
         self.pendingReloadRetries == eventLogMaxReloadRetries:
      # Terminal, hence ERROR.  The retry budget above is gone and
      # `ct/event-load` still has not delivered a single record, so nothing
      # will reload the table again: the Event Log stays empty for the rest
      # of the session with no other trace of why.  This is the same
      # distinction the mount helpers in `ui/state.nim` and
      # `ui/calltrace.nim` draw between their `retry #` lines (progress)
      # and their "giving up" lines (failure).
      #
      # Counted past the cap so a later `onUpdatedTable` — the table is
      # reloaded by search, paging and every `CtCompleteMove` — cannot
      # repeat it and turn a one-off failure back into a stream.
      self.pendingReloadRetries += 1
      cerror "[PIPELINE] event_log: still 0 records after " &
             $eventLogMaxReloadRetries &
             " reload retries, giving up — the Event Log stays empty"

method onUpdatedTrace*(self: EventLogComponent, response: TraceUpdate) {.async.} =
  if response.firstUpdate or response.refreshEventLog or
      (not self.denseTable.context.isNil and cast[string](self.denseTable.context.search()) != ""):
    self.denseTable.context.ajax.reload(nil, false)
    self.findActiveRow(self.activeRowTicks, true)
  else:
    let dt = self.denseTable

    dt.rowsCount = response.totalCount
    self.redraw()

    # Keep the IsoNim-rendered footer in sync with the new totalCount
    # (see comment in `onUpdatedTable` for the full rationale — the
    # static IsoNim shell does not re-render on `redraw()`).
    if not dt.isNil and not dt.context.isNil:
      dt.updateTableRows(redraw = false)
      if not dt.footerDom.isNil:
        dt.updateTableFooter()

method onUpdatedEvents*(self: EventLogComponent, response: seq[ProgramEvent]) {.async.} =
  self.receivedUpdates = true
  if response.len > 0:
    self.data.maxRRTicks = response[0].maxRRTicks
  if self.ignoreOutput:
    return

  # `ct/updated-events` is the SAME payload `ct/event-load` answers with —
  # `Handler::event_load` sends the event and the response from one
  # `page_events` — so it is published here too rather than waiting for the
  # table round-trip the reload below will start. No count is supplied: this
  # event carries none, and `applyEventLogRows` then raises the totals to what
  # the window implies instead of inventing one.
  #
  # ## THE MIXED-PRODUCER WINDOW, AND WHY IT IS GONE
  #
  # This used to append the answer's rows to `self.programEvents` — the
  # DataTables window — and publish the concatenation at `start = hiddenRows`.
  # The two halves came from different producers and were not one contiguous
  # run, so `applyEventLogRows` stamped absolute indices onto the appended tail
  # by an arithmetic nobody could guarantee: a reader who trusted
  # `EventLogRow.eventIndex` between this moment and the reload that replaced
  # the list was reading invented positions.
  #
  # The repair is to stop concatenating. This answer is a `ct/event-load`
  # window and it is published AS ONE, decoded by the store's own
  # `ct/event-load`-shape decoder, at the offset its rows' own `eventIndex`
  # declares — which the backend sets from the absolute position in
  # `cached_events`. `elwsEventLoad` then yields to the paged table window when
  # there is one (see `EventLogWindowSource`), so on this host the publish
  # keeps the totals and the recording's extent current without ever putting a
  # second, differently-chosen window under the pane the user is reading.
  if not eventLogVMStore.isNil:
    var rows = newSeqOfCap[vmtypes.EventLogRow](response.len)
    for i, element in response:
      rows.add eventLogRowFromProgramEvent(element, i)
    let windowStart = if rows.len > 0: rows[0].eventIndex else: 0
    eventLogVMStore.applyEventLogRows(rows, windowStart,
                                      source = elwsEventLoad)
    # The projection follows the store, whichever window it ended up holding:
    # a no-op recompute when the table owns it, and the rows this answer
    # brought when nothing has paged yet.
    self.syncProgramEventsFromStore()

  if not self.denseTable.isNil and not self.denseTable.context.isNil:
    self.denseTable.context.ajax.reload()
  self.redraw()


method clear*(self: EventLogComponent) =
  if not self.denseTable.isNil and not self.denseTable.context.isNil:
    try:
      self.denseTable.context.clear().draw()
    except:
      cerror "event_log: clear dense: " & getCurrentExceptionMsg()

  if not self.detailedTable.isNil and not self.detailedTable.context.isNil:
    try:
      self.detailedTable.context.clear().draw()
    except:
      cerror "event_log: clear detailed: " & getCurrentExceptionMsg()

  self.programEvents = @[]
  # The extras go with the rows they describe. Leaving them would pair the
  # previous recording's metadata and paths with the next recording's first
  # window, one index at a time.
  self.rowExtras = @[]
  self.eventsIndex = 0
  self.rowSelected = 0
  self.activeRowTicks = 0
  self.hiddenRows = 0
  self.liveDebugRows = @[]
  # The store's copy goes with them. A restart that left the rows behind would
  # let a new recording's Event Log open showing the previous one's events to
  # every consumer that reads the store rather than DataTables.
  if not eventLogVMStore.isNil:
    eventLogVMStore.clearEventLog()

method restart*(self: EventLogComponent) =
  self.clear()
  if not self.denseTable.isNil and not self.denseTable.context.isNil:
    try:
      self.denseTable.context.rows().remove()
      self.denseTable.context.rows().draw()
    except:
      cerror "event_log: remove: " & getCurrentExceptionMsg()
    self.denseTable.context = nil

  if not self.detailedTable.isNil and not self.detailedTable.context.isNil:
    try:
      self.detailedTable.context.rows().remove()
      self.detailedTable.context.rows().draw()
    except:
      cerror "event_log: remove: " & getCurrentExceptionMsg()
    self.detailedTable.context = nil

  self.drawId = 0
  self.tableCallback = nil
  self.autoScrollUpdate = false
  self.started = false
  self.isFlowUpdate = false
  self.liveDebugRows = @[]
  self.init = false
  self.redrawColumns = true
  self.redraw()

proc eventLogSearchValue(self: EventLogComponent): cstring =
  let searchInput = jqFind("#eventLog-" & $self.id & "-search")
  if searchInput.isNil or searchInput.toJs.length.to(int) == 0:
    return cstring""

  let inputNode = searchInput[0]
  if inputNode.toJs == jsUndefined:
    return cstring""

  result = inputNode.value.to(cstring)

proc setupSearchInput(self: EventLogComponent) =
  ## Wire the oninput handler on the event log search field.  The IsoNim shell
  ## renders the input without handlers; we attach them here after mount.
  let searchId = cstring("eventLog-" & $self.id & "-search")
  let searchInput = document.getElementById(searchId)
  if searchInput.isNil:
    return

  let search = proc(e: Event) =
    if not self.isDetailed:
      if self.denseTable.isNil or self.denseTable.context.isNil:
        return
      let value = self.eventLogSearchValue()
      self.denseTable.context.search(value).draw()
    else:
      if self.detailedTable.isNil or self.detailedTable.context.isNil:
        return
      let value = self.eventLogSearchValue()
      self.detailedTable.context.search(value).draw()

  searchInput.addEventListener(cstring"input", search)
  searchInput.addEventListener(cstring"change", search)

proc eventLogAfterRedraws(self: EventLogComponent) =
  self.events()
  self.setupFilterDropdown()
  self.setupSearchInput()
  let denseWrapper = cstring"#" & self.denseId & cstring"_wrapper"
  let detailedWrapper = cstring"#" & self.detailedId & cstring"_wrapper"
  let componentTab = cast[Node](jq(&"#eventLogComponent-{self.id}"))

  self.denseTable.footerDom =
    cast[Element](componentTab.findNodeInElement(".data-tables-footer"))

  # Attach scroll → footer-row-range sync listeners.
  # These were previously in the dead else-branch of events() which was never
  # reached because events() is only called once (with self.init = false).
  let denseScrollBody = cast[Node](jq(denseWrapper)).findNodeInElement(".dt-scroll-body")
  if not denseScrollBody.isNil:
    denseScrollBody.addEventListener(
      cstring"scroll",
      proc () =
        self.denseTable.updateTableRows(redraw = false)
        if not self.denseTable.footerDom.isNil:
          self.denseTable.updateTableFooter()
    )
  let detailedScrollBody = cast[Node](jq(detailedWrapper)).findNodeInElement(".dt-scroll-body")
  if not detailedScrollBody.isNil:
    detailedScrollBody.addEventListener(
      cstring"scroll",
      proc () =
        self.detailedTable.updateTableRows(redraw = false)
        if not self.detailedTable.footerDom.isNil:
          self.detailedTable.updateTableFooter()
    )

  # Set up ResizeObserver so the DataTable is re-fitted whenever the event log
  # panel changes size. Previously in the dead else-branch of events() where it
  # was never reached; moved here so it fires correctly after mount.
  if self.resizeObserver.isNil:
    let resizeObserver = createResizeObserver(proc(entries: seq[Element]) =
      for entry in entries:
        discard setTimeout(proc =
          resizeEventLogHandler(self), 100))
    resizeObserver.observe(componentTab)
    self.resizeObserver = resizeObserver

  if not self.inExtension:
    if not self.isDetailed:
      jq(denseWrapper).show()
      jq(detailedWrapper).hide()
    else:
      jq(denseWrapper).hide()
      jq(detailedWrapper).show()

  self.denseTable.updateTableRows(redraw = true)
  self.detailedTable.updateTableRows(redraw = true)
  # if self.denseTable.scrollAreaHeight == 0:
  resizeEventLogHandler(self)

# EventLogComponent.render() removed: IsoNim is the primary renderer.
# Generic callers are expected to use direct IsoNim mount paths. All
# real rendering is handled by tryMountIsoNimEventLogPanel().

when defined(ctInExtension):
  method redrawForExtension*(self: EventLogComponent) =
    self.bindEventLogExtensionHost()

proc scrollOnMove*(self: EventLogComponent, rowSelected: int) =
  if rowSelected > self.denseTable.endRow - 1 or rowSelected < self.denseTable.startRow:
    scrollTable(self.denseTable, $(rowSelected))
    self.denseTable.updateTableRows()

const MOVE_DELAY: int64 = 300

proc afterMove(self: EventLogComponent) =
  let currentTime: int64 = now()
  let lastTimePlusDelay = (self.lastJumpFireTime.toJs + MOVE_DELAY.toJs).to(int64)

  if lastTimePlusDelay <= currentTime:
    self.findActiveRow(self.activeRowTicks, true)
    self.isFlowUpdate = false

method onCompleteMove*(self: EventLogComponent, response: MoveState) {.async.} =
  let component = self
  # Feed the same position into the parallel ViewModel store.
  initEventLogVM()
  syncEventLogDebuggerPosition(
    response.location.rrTicks,
    response.location.path,
    response.location.line,
    response.location.sourceGeneration,
    response.location.sourceDigest)

  self.location = response.location
  # if self.data.ui.activeFocus != self:
  # LRS-5's second deletion round: the DECISION this milestone had to take
  # rather than inherit (design §3.5's rule-7 correction).
  #
  # This flag used to be set from `toLangFromFilename(self.location.path)` --
  # the language of the ACTIVE FILE -- and `usesMaterializedTraces` of that.
  # It is the wrong input for what the flag gates, and it was measurably wrong
  # before this milestone: in a wasm-recorded Rust program the active path is a
  # `.rs` file, `usesMaterializedTraces(LangRust)` is `false`, and the Event Log
  # therefore took the NATIVE path through a MATERIALIZED recording.  Deleting
  # `LangRustWasm` would have left that unchanged rather than caused it, which
  # is why LRS-4's review recorded it as a pre-existing gap and left the
  # decision here.
  #
  # The decision: read the RECORDING, like the other four sites.  Three
  # reasons, in order of force.
  #
  # 1. What the flag gates is WHICH BACKEND the Event Log talks to -- the
  #    db-backend's materialized calltrace/event stream, or the native replay
  #    path.  That is a property of the container, not of the file on screen.
  # 2. The flag is LATCHED (`...Set` above): it is taken once, from whichever
  #    file happened to be active at the first complete-move.  A per-recording
  #    decision taken from an accidental per-move input is a race, not a
  #    design.
  # 3. Its own name says `...Trace`.
  #
  # What changes observably for a user: a recording whose active file is of a
  # different language than the recording's own summary.  Stepping into a `.c`
  # extension source from a Python (materialized) recording used to latch
  # `false` here and drive the Event Log down the native path inside a
  # materialized recording; it now stays materialized.  The converse -- a
  # native C recording whose first active file is a `.py` helper, which used
  # to latch `true` -- now stays native.  In both directions the Event Log now
  # agrees with the REPL, `lineStepJump`, the re-record path and the stored
  # calltrace mode instead of disagreeing with all four.
  if not self.usesMaterializedTracesTraceSet:
    self.usesMaterializedTracesTrace = self.data.trace.usesMaterializedTraces
    self.usesMaterializedTracesTraceSet = true
    try:
      self.denseTable.context.column(2).visible(false)
    except:
      cwarn "Complete move came before initializing the event log component"

  let currentTime: int64 = now()
  self.location = response.location

  self.activeRowTicks = response.location.rrTicks
  self.lastJumpFireTime = currentTime
  # The one thing a move owes this pane. Unconditional and ahead of every
  # branch below, because the branches are about selection and scrolling and
  # the dimming must not depend on which of them a given move happens to take.
  self.refreshDimming()
  let liveRowAdded = self.addLiveDebuggerStopRow(response.location)
  let dt = self.denseTable
  if liveRowAdded and not dt.isNil and not dt.context.isNil:
    setTimeoutWithArg(proc(dTable: DataTableComponent) {.cdecl.} =
      if not dTable.isNil and not dTable.context.isNil:
        dTable.context.ajax.reload(nil, false)
    , 0, dt)
  if self.isFlowUpdate:
    self.findActiveRow(self.activeRowTicks, false)

    setTimeoutWithArg(proc(comp: EventLogComponent) {.cdecl.} =
      comp.afterMove()
    , cast[int](MOVE_DELAY), component)
  else:
    if not self.denseTable.isNil:
      self.rowSelected = response.eventLogIndex
      self.denseTable.activeRowIndex = response.eventLogIndex
      self.autoScrollUpdate = true

      if self.denseTable.autoScroll:
        if self.rowSelected > self.denseTable.endRow - 1 or self.rowSelected < self.denseTable.startRow:
          self.scrollOnMove(self.rowSelected)
        else:
          self.findActiveRow(self.activeRowTicks, true)
      else:
        self.findActiveRow(self.activeRowTicks, true)

method onUp*(self: EventLogComponent) {.async.} =
  if self.rowSelected != 0:
    self.rowSelected -= 1
    self.focusItem()
    self.scrollOnMove(self.rowSelected)

method onDown*(self: EventLogComponent) {.async.} =
  if self.rowSelected < self.denseTable.rowsCount - 1:
    self.rowSelected += 1
    self.focusItem()
    self.scrollOnMove(self.rowSelected)

method onGotoStart*(self: EventLogComponent) {.async.} =
  self.rowSelected = 0
  self.focusItem()
  self.scrollOnMove(self.rowSelected)

method onGotoEnd*(self: EventLogComponent) {.async.} =
  self.rowSelected = self.denseTable.rowsCount - 1
  self.focusItem()
  self.scrollOnMove(self.rowSelected)

method onFindOrFilter*(self: EventLogComponent) {.async.} =
  var divElement = document.getElementsByClass("eventLog-search-field")[self.id]
  divElement.focus()

method onEnter*(self: EventLogComponent) {.async.} =
  let event = cast[ProgramEvent](self.programEvents[self.rowSelected - self.hiddenRows])
  self.programEventJump(event)

method register*(self: EventLogComponent, api: MediatorWithSubscribers) =
  let component = self
  component.api = api

  # Store a module-level reference so the IsoNim mount callback can
  # trigger DataTables initialisation via eventLogAfterRedraws().
  if eventLogComponentRef.isNil:
    eventLogComponentRef = component
    # If the VM was already created before the component registered,
    # try mounting now.
    tryMountIsoNimEventLogPanel()

  api.subscribe(CtCompleteMove, proc(kind: CtEventKind, response: MoveState, sub: Subscriber) =
    discard component.onCompleteMove(response)
    # On the first CtCompleteMove, DataTables has already been initialised
    # and its initial ajax request returned 0 records (the backend had not
    # finished loading events from the ct/event-load request yet).
    # Trigger a DataTables ajax reload so it re-requests data now that the
    # backend has had time to load events.  A short delay gives the backend
    # a margin to finish processing ct/event-load before the reload fires.
    let hasSourceRevision = response.location.sourceGeneration != 0 or
      (not response.location.sourceDigest.isNil and
        response.location.sourceDigest.len > 0)
    let liveEventStream =
      not eventLogVMStore.isNil and
      eventLogVMStore.session.val.debugSessionMode in {
        vmtypes.liveMcr,
        vmtypes.liveMaterialized,
        vmtypes.historicalFromLive}
    if not component.started or (hasSourceRevision and liveEventStream):
      let firstLoad = not component.started
      component.started = true
      # Emit CtEventLoad to ensure the backend loads or refreshes events.
      # Live sessions can grow after the first stop, so source-revisioned
      # positions intentionally refresh the event table.
      component.api.emit(CtEventLoad, EmptyArg())
      let dt = component.denseTable
      if not dt.isNil and not dt.context.isNil:
        setTimeoutWithArg(proc(comp: EventLogComponent) {.cdecl.} =
          let dTable = comp.denseTable
          if not dTable.isNil and not dTable.context.isNil:
            cdebug "[PIPELINE] event_log: first/revision CtCompleteMove, reloading DataTables ajax"
            dTable.context.ajax.reload(nil, false)
        , 500, component)
  )

  api.subscribe(CtUpdatedEvents, proc(kind: CtEventKind, response: seq[ProgramEvent], sub: Subscriber) =
    discard component.onUpdatedEvents(response)
  )

  api.subscribe(CtUpdatedEventsContent, proc(kind: CtEventKind, response: cstring, sub: Subscriber) =
    if component.ignoreOutput:
      return

    # NOTE, since `programEvents` is now a projection of the store's rows
    # rather than a list of its own: this overwrites `content` on the
    # PROJECTION and not on the store, and that is unchanged behaviour rather
    # than a new gap. The rows DataTables renders were already built before
    # this handler runs, `redraw()` does not re-feed them, and the next
    # `loadEvents` rebuilds the projection from the store — so the write has
    # always been to a copy that nothing subsequently reads. It is left alone
    # because repairing it means deciding what `ct/updated-events-content` is
    # FOR, which is a question about that route and not about this one.
    let lines = response.split(jsNl)
    var lineIndex = 0
    var eventsIndex = 0
    while lineIndex < lines.len and eventsIndex < component.programEvents.len:
      while true:
        if eventsIndex < component.programEvents.len:
          if component.programEvents[eventsIndex].kind in {Write, WriteFile, WriteOther, Read, ReadFile, ReadOther}:
            component.programEvents[eventsIndex].content = lines[lineIndex]
            lineIndex += 1
          eventsIndex += 1
        else:
          echo fmt"warn: no event for line number {lineIndex}"
          break

    component.redraw()
  )
  api.subscribe(CtUpdatedTable, proc(kind: CtEventKind, response: CtUpdatedTableResponseBody, sub: Subscriber) =
    discard component.onUpdatedTable(response)
  )
  api.subscribe(CtUpdatedTrace, proc(kind: CtEventKind, response: TraceUpdate, sub: Subscriber) =
    discard component.onUpdatedTrace(response)
  )

  api.emit(InternalLastCompleteMove, EmptyArg())

proc registerEventLogComponent*(component: EventLogComponent, api: MediatorWithSubscribers) {.exportc.} =
  initEventLogVM()
  component.register(api)
