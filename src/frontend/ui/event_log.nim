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
  mountFilterDropdownInto

# Module-level EventLogVM instance. Created once and fed data whenever
# the legacy event-bus handlers fire. Rendering still reads from legacy
# data so behaviour is unchanged.
var eventLogVMInstance: EventLogVM
var eventLogVMStore: ReplayDataStore
var isoNimEventLogMounted*: bool = false

# Reference to the EventLogComponent instance so that the IsoNim mount
# callback can trigger DataTables initialisation via events().
var eventLogComponentRef: EventLogComponent

proc tryMountIsoNimEventLogPanel()
proc eventLogAfterRedraws(self: EventLogComponent)

# ---------------------------------------------------------------------------
# ViewModel bridge procs — sync legacy event data into the parallel store.
# ---------------------------------------------------------------------------

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

proc parseTableRowLine(row: TableRow): int =
  let fullPath = $row.fullPath
  let colon = fullPath.rfind(":")
  if colon < 0 or colon >= fullPath.len - 1:
    return 0

  try:
    fullPath[colon + 1 .. ^1].parseInt
  except ValueError:
    0

proc tableRowPath(row: TableRow): cstring =
  if not row.lowLevelLocation.isNil and row.lowLevelLocation.len > 0:
    row.lowLevelLocation
  else:
    let fullPath = $row.fullPath
    let colon = fullPath.rfind(":")
    if colon > 0:
      cstring(fullPath[0 ..< colon])
    else:
      row.fullPath

proc programEventFromTableRow(row: TableRow; eventIndex: int; maxRRTicks: int): ProgramEvent =
  ProgramEvent(
    kind: row.kind,
    semanticKind: row.semanticKind,
    content: row.content,
    rrEventId: row.rrEventId,
    metadata: row.metadata,
    highLevelPath: tableRowPath(row),
    highLevelLine: parseTableRowLine(row),
    directLocationRRTicks: row.directLocationRRTicks,
    eventIndex: eventIndex,
    tracepointResultIndex: 0,
    base64Encoded: row.base64Encoded,
    maxRRTicks: maxRRTicks,
    stdout: row.stdout,
    sourceGeneration: row.sourceGeneration,
    sourceDigest: row.sourceDigest
  )

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

  eventLogVMInstance.appendLiveDebuggerStop(vmtypes.EventLogRow(
    eventId: eventId,
    eventIndex: 0,
    kindId: ord(row.kind),
    kind: "debugger-stop",
    file: $tableRowPath(row),
    line: parseTableRowLine(row),
    value: $row.metadata,
    rrTicks: eventId,
    maxRRTicks: eventId,
    sourceGeneration: row.sourceGeneration,
    sourceDigest: $row.sourceDigest,
  ))

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

proc tryMountIsoNimEventLogPanel() =
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
  cerror "tryMountIsoNimEventLogPanel: called, isoNimEventLogMounted=" & $isoNimEventLogMounted & " vmIsNil=" & $eventLogVMInstance.isNil & " compRefIsNil=" & $eventLogComponentRef.isNil
  if isoNimEventLogMounted or eventLogVMInstance.isNil:
    cerror "tryMountIsoNimEventLogPanel: skipping (already mounted or VM nil)"
    return
  if eventLogComponentRef.isNil:
    cerror "tryMountIsoNimEventLogPanel: skipping (eventLogComponentRef is nil)"
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
      cerror "tryMountIsoNimEventLogPanel: mount COMPLETE in #eventLogComponent-0"

    except:
      cerror "tryMountIsoNimEventLogPanel: mount EXCEPTION: " & getCurrentExceptionMsg()

  doMount()

var arg: js

const
  CLICK_DELAY_TIMER = 5
  EVENT_LOG_TAG_NAMES: array[EventTag, string] = [
    "std streams:",
    "read events:",
    "write events:",
    "network:",
    "trace:",
    "file:",
    "errors:",
    "evm events:"
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

    # The extension event-log surface has no panel markup of its own; keep the
    # exported component alive without retaining an empty Karax renderer.
    host.innerHTML = cstring""

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

proc filterEvents(self: EventLogComponent): seq[ProgramEvent] =
  var events: seq[ProgramEvent] = @[]

  for i in 0..<self.programEvents.len():
    let event = self.programEvents[i]
    if self.selectedKinds[event.kind]:
      events.add(event)

  return events

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
    mountFilterDropdownInto(
      cast[dom_api.Element](containerKdom),
      buildFilterTabs(),
      buildFilterRows(),
      buildFilterCallbacks())

    let filterButton = document.getElementById(dropDownId)
    let rect = filterButton.getBoundingClientRect()
    containerKdom.style.position = "absolute"
    containerKdom.style.top = &"{rect.bottom}px"
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
    let row = cast[TableRow](data)
    event = programEventFromTableRow(row, 0, self.data.maxRRTicks)
    event.bytes = 0
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
            title: cstring"direction location rr ticks",
            render: proc(directLocationRRTicks: int): cstring =
              renderRRTicksLine(directLocationRRTicks, self.data.minRRTicks, self.data.maxRRTicks, "event-rr-ticks-line")
          },
          js{
            className: cstring"eventLog-index eventLog-cell",
            data: cstring"rrEventId",
            title: cstring"rr event id"
          },
      ]
      if self.usesMaterializedTracesTrace:
        let lower = cstring("FullPath".toLowerAscii())

        denseColumns.add(
          js{
            className: cstring"eventLog-" & lower & " " & local("cell"),
            searchable: true,
            title: lower,
            data: cstring"fullPath",
          }
        )
      denseColumns.add(
        @[
          js{
            className: cstring"eventLog-event eventLog-cell",
            searchable: true,
            data: cstring"kind",
            title: cstring"event-image",
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
            title: cstring"text",
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
          createdRow: rowTimestamp,
          language: js{
            emptyTable: proc: cstring =
              # TODO if self.receivedUpdates:
              """The current record appears to not have any system events like std read/write,
              network or disc operations.</br>You can add trace point events to your code by selecting any
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
    cast[Node](jq(denseWrapper)).findNodeInElement(".dt-scroll-body")
      .addEventListener(
        cstring"scroll",
        proc () =
          self.denseTable.updateTableRows(redraw = true)
          self.redraw()
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
  console.log(cstring(fmt"event_log: loadEvents records={update.data.len} draw={update.draw}"))
  self.programEvents = @[]
  if update.data.len() > 0:
    self.receivedUpdates = true
  for i, row in update.data:
    self.programEvents.add(programEventFromTableRow(row, i, data.maxRRTicks))


method onUpdatedTable*(self: EventLogComponent, res: CtUpdatedTableResponseBody) {.async.} =
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

    self.loadEvents(mutData)

    self.tableCallback(mutData.toJs)
    self.redraw()

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
       not self.receivedUpdates and self.pendingReloadRetries < 8:
      self.pendingReloadRetries += 1
      let delay = 250 * self.pendingReloadRetries  # 250, 500, 750, ... ms
      cerror "[PIPELINE] event_log: onUpdatedTable got 0 records, scheduling reload retry " &
             $self.pendingReloadRetries & " in " & $delay & "ms"
      discard setTimeout(proc() =
        if not self.receivedUpdates and
           not self.denseTable.isNil and not self.denseTable.context.isNil:
          self.denseTable.context.ajax.reload(nil, false)
      , delay)

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

  for element in response:
    self.programEvents.add(element)

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
  self.eventsIndex = 0
  self.rowSelected = 0
  self.activeRowTicks = 0
  self.hiddenRows = 0
  self.liveDebugRows = @[]

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
  # Feed the same position into the parallel ViewModel store.
  initEventLogVM()
  syncEventLogDebuggerPosition(
    response.location.rrTicks,
    response.location.path,
    response.location.line,
    response.location.sourceGeneration,
    response.location.sourceDigest)

  self.location = response.location
  let lang = toLangFromFilename(self.location.path)
  # if self.data.ui.activeFocus != self:
  if not self.usesMaterializedTracesTraceSet:
    self.usesMaterializedTracesTrace = lang != LangUnknown and lang.usesMaterializedTraces
    self.usesMaterializedTracesTraceSet = true
    try:
      self.denseTable.context.column(2).visible(false)
    except:
      cwarn "Complete move came before initializing the event log component"

  let currentTime: int64 = now()
  self.location = response.location

  self.activeRowTicks = response.location.rrTicks
  self.lastJumpFireTime = currentTime
  let liveRowAdded = self.addLiveDebuggerStopRow(response.location)
  if liveRowAdded and not self.denseTable.isNil and not self.denseTable.context.isNil:
    discard setTimeout(proc() =
      if not self.denseTable.isNil and not self.denseTable.context.isNil:
        self.denseTable.context.ajax.reload(nil, false)
    , 0)
  if self.isFlowUpdate:
    self.findActiveRow(self.activeRowTicks, false)

    discard windowSetTimeout(
      proc =
        self.afterMove(),
        cast[int](MOVE_DELAY)
    )
    # else:
    #   self.findActiveRow(self.activeRowTicks, true)

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
  self.api = api

  # Store a module-level reference so the IsoNim mount callback can
  # trigger DataTables initialisation via eventLogAfterRedraws().
  if eventLogComponentRef.isNil:
    eventLogComponentRef = self
    # If the VM was already created before the component registered,
    # try mounting now.
    tryMountIsoNimEventLogPanel()

  api.subscribe(CtCompleteMove, proc(kind: CtEventKind, response: MoveState, sub: Subscriber) =
    discard self.onCompleteMove(response)
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
    if not self.started or (hasSourceRevision and liveEventStream):
      let firstLoad = not self.started
      self.started = true
      # Emit CtEventLoad to ensure the backend loads or refreshes events.
      # Live sessions can grow after the first stop, so source-revisioned
      # positions intentionally refresh the event table.
      self.api.emit(CtEventLoad, EmptyArg())
      if not self.denseTable.isNil and not self.denseTable.context.isNil:
        discard setTimeout(proc() =
          if not self.denseTable.isNil and not self.denseTable.context.isNil:
            if firstLoad:
              cerror "[PIPELINE] event_log: first CtCompleteMove, reloading DataTables ajax"
            else:
              cerror "[PIPELINE] event_log: source-revision move, reloading DataTables ajax"
            self.denseTable.context.ajax.reload(nil, false)
        , 500)
  )

  api.subscribe(CtUpdatedEvents, proc(kind: CtEventKind, response: seq[ProgramEvent], sub: Subscriber) =
    discard self.onUpdatedEvents(response)
  )

  api.subscribe(CtUpdatedEventsContent, proc(kind: CtEventKind, response: cstring, sub: Subscriber) =
    if self.ignoreOutput:
      return

    let lines = response.split(jsNl)
    var lineIndex = 0
    var eventsIndex = 0
    while lineIndex < lines.len and eventsIndex < self.programEvents.len:
      while true:
        if eventsIndex < self.programEvents.len:
          if self.programEvents[eventsIndex].kind in {Write, WriteFile, WriteOther, Read, ReadFile, ReadOther}:
            self.programEvents[eventsIndex].content = lines[lineIndex]
            lineIndex += 1
          eventsIndex += 1
        else:
          echo fmt"warn: no event for line number {lineIndex}"
          break

    self.redraw()
  )
  api.subscribe(CtUpdatedTable, proc(kind: CtEventKind, response: CtUpdatedTableResponseBody, sub: Subscriber) =
    discard self.onUpdatedTable(response)
  )
  api.subscribe(CtUpdatedTrace, proc(kind: CtEventKind, response: TraceUpdate, sub: Subscriber) =
    discard self.onUpdatedTrace(response)
  )

  api.emit(InternalLastCompleteMove, EmptyArg())

proc registerEventLogComponent*(component: EventLogComponent, api: MediatorWithSubscribers) {.exportc.} =
  component.register(api)
