## viewmodels/event_log_vm.nim
##
## EventLogVM — ViewModel for the Event Log panel.
##
## Holds reactive state for:
## - Which row is selected
## - Pagination (current page, page size)
## - Search query for filtering events
## - Sort column and direction
##
## Derives:
## - `totalPages`: computed from the store's event log data and page size
## - `isLoading`: whether a data-fetch is currently in flight
##
## Also creates an auto-load effect that calls the backend to request
## event log data whenever the page, sort, or search parameters change.
##
## ## M25b — Correlation-marker Event-Log surface
##
## Extended with reactive signals for the correlation-marker rendering
## defined in `codetracer-specs/GUI/Debugging-Features/Correlation-Markers.md`
## §5:
##
## - `markerRows: Signal[seq[MarkerEventRow]]` — the cached marker
##   projection returned by `ct/event-load.markers`. Populated by
##   `EventLogVM.applyMarkerRowsResponse` from a DAP JSON node so the
##   view layer can render `↑ Send` / `↓ Recv` icons, boundary-ID
##   chips, and `show_value` formatted per `MarkerEventRow.format`.
## - `counterpartCache: Signal[Table[CounterpartKey, seq[CounterpartRef]]]`
##   — per-marker counterpart set keyed by `(boundary_id, direction,
##   key_value)`. Resolved against the cached pair index returned by
##   `ct/pairIndexLookup`. Single-load cache; reads serve locally.
## - `loadingBanner: Signal[MarkerLoadingBanner]` — tracks the §5.4.1
##   "loading correlation markers… X / Y firings" banner state. Emits
##   `mlbDone` once all firings have arrived. The banner is fed by
##   `ct/markerLoadStarted` / `ct/markerLoadProgress` /
##   `ct/markerLoadCompleted` events (decoded with
##   `applyMarkerLoadEvent`).
## - `filterBar: Signal[MarkerFilterBar]` — recognises the `boundary:`
##   and `unmatched` shorthands per spec §5.4 + the free-text input;
##   `visibleMarkerRows` is the reactive intersection.
## - `emptyState: Signal[MarkerEmptyState]` — surfaces the §5.5
##   "N markers declared in source; none fired" banner.
## - `toastState: Signal[MarkerToastState]` — drives the §7 one-time
##   workspace-scoped discovery toast; `dismissToast` flips the
##   workspace flag through the store.
##
## Usage:
##   let vm = createEventLogVM(store)
##   echo vm.currentPage.val      # 0
##   vm.nextPage()
##   echo vm.totalPages.val       # derived from store data

import std/[json, options, strutils, tables]

import isonim/core/[signals, computation, owner]
import isonim/core/async_compat
import isonim/viewmodel

import ../backend/backend_service
import ../store/[replay_data_store, types]

const
  ## Default number of rows per page in the event log panel.
  DEFAULT_PAGE_SIZE* = 50
  ## Default `format` hint applied when a marker omits the field
  ## (spec §5.2). Read by `formatShowValue` to truncate values with a
  ## middle ellipsis for compact display.
  DEFAULT_MARKER_FORMAT* = "summary:80"
  ## The §5.4 filter input recognises these shorthands as a leading
  ## token. They compose with the residual free-text input.
  MARKER_BOUNDARY_PREFIX* = "boundary:"
  MARKER_UNMATCHED_TOKEN* = "unmatched"

type
  MarkerDirection* = enum
    ## Per spec §2 — only Send and Recv are well-formed.
    ## `mdUnknown` covers wire-shape regressions (legacy backend, bad
    ## JSON) so the renderer can degrade gracefully without throwing.
    mdSend
    mdRecv
    mdUnknown

  MarkerEventRow* = object
    ## §5.1 row metadata returned by `ct/event-load`. Mirrors the
    ## `MarkerEventRow` struct on the db-backend side; field order
    ## matches the JSON wire shape.
    eventIndex*: int
    markerId*: int
    boundaryId*: string
    direction*: MarkerDirection
    keyText*: string
    keyValue*: string
    showText*: string
    showValue*: string
    description*: string
    format*: string
    sourcePath*: string
    sourceLine*: int
    stepId*: int64
    recordingId*: string
      ## Populated by `ct/pairIndexLookup` responses (each
      ## counterpart carries its originating recording id so the §5.3
      ## jump button can render `→ recv (be:thread-1)` correctly).
      ## Empty for rows that come from the local event-load response.

  CounterpartKey* = tuple
    ## Composite cache key used by `EventLogVM.counterpartCache`. The
    ## key matches the M25b `ct/pairIndexLookup` request signature so a
    ## single cache lookup serves every Event-Log render call.
    boundaryId: string
    direction: MarkerDirection
    keyValue: string

  MarkerLoadingPhase* = enum
    mlbIdle      ## No marker load has started.
    mlbLoading   ## §5.4.1 banner visible.
    mlbDone      ## Banner cleared; cache frozen.

  MarkerLoadingBanner* = object
    ## §5.4.1 banner state. `loaded` and `total` populate the
    ## "loaded X / Y marker firings" label; `phase` drives the
    ## visibility transition.
    phase*: MarkerLoadingPhase
    loaded*: int
    total*: int

  MarkerFilterBar* = object
    ## §5.4 filter-bar state derived from `searchQuery`.
    ## `boundaryFilter` and `unmatchedOnly` correspond to the two
    ## shorthands; `freeText` is the residual after shorthand
    ## extraction.
    raw*: string
    boundaryFilter*: string
    unmatchedOnly*: bool
    freeText*: string

  MarkerEmptyStateKind* = enum
    mesHidden            ## No banner.
    mesDeclaredNoneFired ## §5.5 banner.

  MarkerEmptyState* = object
    kind*: MarkerEmptyStateKind
    declaredCount*: int

  MarkerToastKind* = enum
    mtHidden
    mtVisible

  MarkerToastState* = object
    ## §7 one-time discovery toast. The toast is workspace-scoped —
    ## `workspaceId` identifies which workspace already dismissed it
    ## (so the same workspace on a future load doesn't re-trigger).
    kind*: MarkerToastKind
    discoveredCount*: int
    workspaceId*: string

type
  EventLogVM* = ref object of ViewModel
    ## Reactive state for the Event Log panel.
    ##
    ## Mutable signals:
    ##   selectedRow      — index of the selected row, or none
    ##   currentPage      — zero-based page index
    ##   pageSize         — number of rows per page
    ##   searchQuery      — current search/filter text
    ##   sortColumn       — column index to sort by
    ##   sortAscending    — whether sort is ascending
    ##
    ## Derived memos:
    ##   totalPages       — total pages based on event count and page size
    ##   isLoading        — whether a request is in flight
    ##
    ## The store reference is kept for the auto-load effect and
    ## for navigation actions (double-click jump).
    store*: ReplayDataStore

    # -- Mutable state --
    selectedRow*: Signal[Option[int]]
    currentPage*: Signal[int]
    pageSize*: Signal[int]
    searchQuery*: Signal[string]
    sortColumn*: Signal[int]
    sortAscending*: Signal[bool]

    # -- Internal state for event log data --
    # These are owned by the VM since ReplayDataStore does not yet
    # have a dedicated event-log sub-store.
    eventRows*: Signal[seq[EventLogRow]]
    totalEventCount*: Signal[int]
    loadingState*: Signal[LoadingState]

    # -- M25b: Correlation-marker reactive surface --
    markerRows*: Signal[seq[MarkerEventRow]]
      ## The cached marker projection — populated by
      ## `applyMarkerRowsResponse`. The view reads this signal to
      ## render direction icons, boundary chips, and formatted show
      ## values per spec §5.1.
    counterpartCache*: Signal[Table[CounterpartKey, seq[MarkerEventRow]]]
      ## Per-`(boundary, direction, key)` cache populated by
      ## `applyPairIndexLookupResponse`. Reads serve from this map;
      ## the view never re-issues `ct/pairIndexLookup` for the same
      ## key (the §3.2.1 one-time-evaluation contract on the GUI
      ## side).
    loadingBanner*: Signal[MarkerLoadingBanner]
    filterBar*: Signal[MarkerFilterBar]
    emptyState*: Signal[MarkerEmptyState]
    toastState*: Signal[MarkerToastState]
    dismissedWorkspaces*: Signal[seq[string]]
      ## Per-workspace dismissal log. `dismissToast` adds the active
      ## workspace; `applyDiscoveredMarkers` skips the toast when the
      ## workspace already dismissed it.

    # -- Derived state --
    totalPages*: Memo[int]
    isLoading*: Memo[bool]
    visibleMarkerRows*: Memo[seq[MarkerEventRow]]
      ## §5.4 filter result. Computed reactively from `markerRows` +
      ## `filterBar` + `counterpartCache`.

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

proc selectRow*(vm: EventLogVM; row: Option[int]) =
  ## Set the currently selected row. Pass `none(int)` to clear.
  vm.selectedRow.val = row

proc appendLiveDebuggerStop*(vm: EventLogVM; row: EventLogRow) =
  ## Add a semantic live debugger-stop row to the ViewModel state.
  ##
  ## Persisted event rows still come from the backend; this covers the live
  ## debugger head where each stop is visible immediately and may later be
  ## mirrored by backend event loading.
  var rows = vm.eventRows.val
  for existing in rows:
    if existing.eventId == row.eventId and
       existing.kind == row.kind and
       existing.sourceGeneration == row.sourceGeneration and
       existing.sourceDigest == row.sourceDigest:
      return

  var nextRow = row
  nextRow.eventIndex = rows.len
  rows.add(nextRow)
  vm.eventRows.val = rows
  vm.totalEventCount.val = rows.len

proc doubleClickRow*(vm: EventLogVM; row: int) =
  ## Navigate to the source location of the event at `row`.
  ## Looks up the event in the VM's event rows and sends a
  ## ProgramEvent-shaped navigation command via the backend.
  let rows = vm.eventRows.val
  if row >= 0 and row < rows.len:
    let event = rows[row]
    let rrTicks =
      if event.rrTicks != 0'u64: event.rrTicks
      else: event.eventId
    let maxRRTicks =
      if event.maxRRTicks != 0'u64: event.maxRRTicks
      else: vm.store.timeline.val.maxRRTicks
    let args = %*{
      "kind": event.kindId,
      "content": event.value,
      "rrEventId": event.eventId,
      "eventId": event.eventId,
      "highLevelPath": event.file,
      "highLevelLine": event.line,
      "metadata": "",
      "bytes": event.value.len,
      "stdout": false,
      "directLocationRRTicks": rrTicks,
      "tracepointResultIndex": -1,
      "eventIndex": event.eventIndex,
      "base64Encoded": false,
      "maxRRTicks": maxRRTicks,
      "line": event.line,
      "sourceGeneration": event.sourceGeneration,
      "sourceDigest": event.sourceDigest,
    }
    vm.store.requestHistoricalNavigation("ct/event-jump", args)

proc nextPage*(vm: EventLogVM) =
  ## Advance to the next page, clamped to totalPages - 1.
  let maxPage = vm.totalPages.val - 1
  let next = vm.currentPage.val + 1
  if maxPage >= 0 and next <= maxPage:
    vm.currentPage.val = next

proc prevPage*(vm: EventLogVM) =
  ## Go back one page, clamped to 0.
  let prev = vm.currentPage.val - 1
  if prev >= 0:
    vm.currentPage.val = prev

proc sort*(vm: EventLogVM; column: int) =
  ## Sort by the given column. If already sorting by this column,
  ## toggle the direction. Otherwise, set the column and default
  ## to ascending.
  if vm.sortColumn.val == column:
    vm.sortAscending.val = not vm.sortAscending.val
  else:
    vm.sortColumn.val = column
    vm.sortAscending.val = true

proc setSearchQuery*(vm: EventLogVM; query: string) =
  ## Update the search query. Resets to page 0 since the result
  ## set changes.
  vm.searchQuery.val = query
  vm.currentPage.val = 0

proc setPageSize*(vm: EventLogVM; size: int) =
  ## Update the page size. Resets to page 0 to avoid stale offsets.
  if size > 0:
    vm.pageSize.val = size
    vm.currentPage.val = 0

# ---------------------------------------------------------------------------
# M25b — Marker-row metadata + counterpart cache helpers
# ---------------------------------------------------------------------------

proc parseMarkerDirection*(raw: string): MarkerDirection =
  ## Decode the wire-encoded direction (spec §2 — lowercase `send` /
  ## `recv`). Returns `mdUnknown` for legacy / malformed values so the
  ## renderer can degrade gracefully instead of throwing.
  case raw
  of "send": mdSend
  of "recv": mdRecv
  else: mdUnknown

proc directionWireText*(direction: MarkerDirection): string =
  ## Inverse of `parseMarkerDirection` — used by the DAP outbound
  ## arguments. `mdUnknown` falls back to the empty string so a buggy
  ## consumer surfaces the failure rather than silently asking the
  ## backend for the wrong direction.
  case direction
  of mdSend: "send"
  of mdRecv: "recv"
  of mdUnknown: ""

proc directionDisplayIcon*(direction: MarkerDirection): string =
  ## §5.1 row icon. The view-layer renderer concatenates the icon with
  ## the boundary chip / show value; keeping the mapping inside the
  ## ViewModel ensures both the Electron + VS Code surfaces render the
  ## same string.
  case direction
  of mdSend: "↑"
  of mdRecv: "↓"
  of mdUnknown: "?"

proc rowFromJson*(node: JsonNode): MarkerEventRow =
  ## Decode one `MarkerEventRow` wire entry. Tolerant of missing
  ## fields — the backend's `Option<String>` map to empty strings,
  ## which the renderer treats as "no value supplied".
  result = MarkerEventRow()
  if node.kind != JObject:
    return
  if node.hasKey("eventIndex"): result.eventIndex = node["eventIndex"].getInt
  if node.hasKey("markerId"): result.markerId = node["markerId"].getInt
  if node.hasKey("boundaryId"): result.boundaryId = node["boundaryId"].getStr
  if node.hasKey("direction"):
    result.direction = parseMarkerDirection(node["direction"].getStr)
  if node.hasKey("keyText"): result.keyText = node["keyText"].getStr
  if node.hasKey("keyValue"): result.keyValue = node["keyValue"].getStr
  if node.hasKey("showText") and node["showText"].kind == JString:
    result.showText = node["showText"].getStr
  if node.hasKey("showValue") and node["showValue"].kind == JString:
    result.showValue = node["showValue"].getStr
  if node.hasKey("description") and node["description"].kind == JString:
    result.description = node["description"].getStr
  if node.hasKey("format") and node["format"].kind == JString:
    result.format = node["format"].getStr
  if node.hasKey("sourcePath"): result.sourcePath = node["sourcePath"].getStr
  if node.hasKey("sourceLine"): result.sourceLine = node["sourceLine"].getInt
  if node.hasKey("stepId"): result.stepId = node["stepId"].getBiggestInt
  if node.hasKey("recordingId") and node["recordingId"].kind == JString:
    result.recordingId = node["recordingId"].getStr

proc formatShowValue*(row: MarkerEventRow): string =
  ## Apply the §5.2 format hint to the row's `showValue`. The
  ## supported specs are `text`, `json`, `hex`, and `summary:<n>` —
  ## anything else falls back to the default `summary:80` behaviour.
  ##
  ## The renderer reads this proc; encoding the rules in the
  ## ViewModel layer keeps the Electron + VS Code surfaces in lockstep
  ## without duplicating the JSON pretty-print + hex-dump logic in two
  ## places.
  let base = if row.showValue.len > 0: row.showValue else: row.keyValue
  let spec = if row.format.len > 0: row.format else: DEFAULT_MARKER_FORMAT
  if spec == "text":
    return base
  if spec == "json":
    try:
      let parsed = parseJson(base)
      return parsed.pretty(2)
    except JsonParsingError, ValueError:
      return base
  if spec == "hex":
    var hex = ""
    for ch in base:
      hex.add(toHex(ord(ch), 2))
    return hex
  if spec.startsWith("summary:"):
    var width = 80
    let rest = spec[8 .. ^1]
    try:
      width = parseInt(rest)
    except ValueError:
      width = 80
    if width <= 0 or base.len <= width:
      return base
    # Middle-ellipsis truncation. We bias the prefix slightly larger
    # than the suffix for odd widths so a 9-char limit on
    # "1234567890" yields "1234…7890" rather than "123…67890".
    let ellipsis = "…"
    let usable = max(width - ellipsis.len, 1)
    let prefixLen = (usable + 1) div 2
    let suffixLen = usable - prefixLen
    if prefixLen + suffixLen >= base.len:
      return base
    return base[0 ..< prefixLen] & ellipsis & base[^suffixLen .. ^1]
  base

proc counterpartKey*(row: MarkerEventRow): CounterpartKey =
  ## Compose the `counterpartCache` lookup key. The key uses the
  ## *opposite* direction because the cache holds counterparts: a
  ## Send marker queries `(boundary, recv, key)` to find its Recv
  ## counterparts.
  let opposite =
    case row.direction
    of mdSend: mdRecv
    of mdRecv: mdSend
    of mdUnknown: mdUnknown
  (row.boundaryId, opposite, row.keyValue)

proc applyMarkerRowsResponse*(vm: EventLogVM; payload: JsonNode) =
  ## Populate `markerRows` from a `ct/event-load` response body. The
  ## body's `markers` field carries the decoded MarkerPayload rows;
  ## this proc converts them to typed `MarkerEventRow`s without
  ## re-evaluating tracepoints (the §3.2.1 contract).
  if payload.kind != JObject:
    return
  if not payload.hasKey("markers"):
    return
  let markersNode = payload["markers"]
  if markersNode.kind != JArray:
    return
  var rows: seq[MarkerEventRow] = @[]
  for entry in markersNode:
    rows.add(rowFromJson(entry))
  vm.markerRows.val = rows

proc applyPairIndexLookupResponse*(vm: EventLogVM; key: CounterpartKey; response: JsonNode) =
  ## Insert a `ct/pairIndexLookup` response into the counterpart
  ## cache. The response carries one entry per counterpart row —
  ## decoded into a `MarkerEventRow` (with `recordingId` populated)
  ## so the jump button has every field it needs without a second
  ## DAP request.
  var entries: seq[MarkerEventRow] = @[]
  if response.kind == JObject and response.hasKey("counterparts"):
    let arr = response["counterparts"]
    if arr.kind == JArray:
      for entry in arr:
        entries.add(rowFromJson(entry))
  var cache = vm.counterpartCache.val
  cache[key] = entries
  vm.counterpartCache.val = cache

proc counterpartsFor*(vm: EventLogVM; row: MarkerEventRow): seq[MarkerEventRow] =
  ## Lookup helper used by the renderer.
  let key = counterpartKey(row)
  let cache = vm.counterpartCache.val
  if cache.hasKey(key):
    cache[key]
  else:
    @[]

proc requestCounterparts*(vm: EventLogVM; row: MarkerEventRow) =
  ## Issue `ct/pairIndexLookup` for `row`'s counterpart set and store
  ## the response in `counterpartCache`. The request is keyed by the
  ## row's `(boundary, direction, key_value)` triple per spec §5.3.
  ## Multiple rows sharing a key collapse into one cache entry — the
  ## cache key includes the *opposite* direction (see
  ## `counterpartKey`) so a single Send query satisfies every Send
  ## row sharing the same key.
  let key = counterpartKey(row)
  let cache = vm.counterpartCache.val
  if cache.hasKey(key):
    return
  let args = %*{
    "boundaryId": row.boundaryId,
    "direction": directionWireText(row.direction),
    "keyValue": row.keyValue,
  }
  let future = vm.store.backend.send("ct/pairIndexLookup", args)
  let vmRef = vm
  let cacheKey = key
  onComplete(future,
    proc(response: JsonNode) =
      vmRef.applyPairIndexLookupResponse(cacheKey, response),
    proc(message: string) =
      # On error, install an empty counterpart slot so the renderer
      # treats the row as unmatched rather than blocking on a pending
      # request indefinitely. The error itself is surfaced through
      # the existing notification surface (not modelled here).
      vmRef.applyPairIndexLookupResponse(cacheKey, newJNull()))

proc parseFilterBar*(raw: string): MarkerFilterBar =
  ## Tokenise the §5.4 filter input. `boundary:<id>` and `unmatched`
  ## are extracted as composable shorthands; the residual free-text
  ## composes with both per the spec wording. Multiple `boundary:`
  ## tokens keep the *last* one (the spec doesn't allow OR-of-
  ## boundaries; a single boundary id is the only meaningful query).
  result.raw = raw
  var freeTextParts: seq[string] = @[]
  for tok in raw.split({' ', '\t'}):
    if tok.len == 0:
      continue
    if tok.startsWith(MARKER_BOUNDARY_PREFIX):
      result.boundaryFilter = tok[MARKER_BOUNDARY_PREFIX.len .. ^1]
    elif tok == MARKER_UNMATCHED_TOKEN:
      result.unmatchedOnly = true
    else:
      freeTextParts.add(tok)
  result.freeText = freeTextParts.join(" ")

proc setFilterInput*(vm: EventLogVM; raw: string) =
  ## Update the filter input. Recognises the §5.4 shorthands.
  vm.filterBar.val = parseFilterBar(raw)
  vm.searchQuery.val = raw
  vm.currentPage.val = 0

proc rowMatchesFilter*(row: MarkerEventRow; filter: MarkerFilterBar; isUnmatched: bool): bool =
  ## Predicate used by the `visibleMarkerRows` memo. Encapsulated as
  ## a free proc so the unit tests can pin the matching rules without
  ## touching VM state.
  if filter.boundaryFilter.len > 0 and row.boundaryId != filter.boundaryFilter:
    return false
  if filter.unmatchedOnly and not isUnmatched:
    return false
  if filter.freeText.len > 0:
    let needle = filter.freeText.toLowerAscii
    let haystack = (row.boundaryId & " " & row.keyValue & " " & row.showValue).toLowerAscii
    if not haystack.contains(needle):
      return false
  true

proc setLoadingBanner*(vm: EventLogVM; banner: MarkerLoadingBanner) =
  ## Direct setter for the loading banner. The DAP-event integrator
  ## uses this to drive the §5.4.1 banner transitions; tests use it
  ## to assert reactive subscribers fire.
  vm.loadingBanner.val = banner

proc applyMarkerLoadEvent*(vm: EventLogVM; event: JsonNode) =
  ## Drive the loading banner from a `ct/markerLoad*` DAP event.
  ## Recognises the three event shapes per spec §3.2.1.2:
  ## `ct/markerLoadStarted { totalDeclared }`,
  ## `ct/markerLoadProgress { loaded, total }`, and
  ## `ct/markerLoadCompleted { finalLoaded }`. Unknown shapes are
  ## ignored so the consumer can route every DAP event through here
  ## without filtering.
  if event.kind != JObject:
    return
  let kind =
    if event.hasKey("event") and event["event"].kind == JString:
      event["event"].getStr
    elif event.hasKey("kind") and event["kind"].kind == JString:
      event["kind"].getStr
    else:
      ""
  let body =
    if event.hasKey("body") and event["body"].kind == JObject:
      event["body"]
    else:
      event
  case kind
  of "ct/markerLoadStarted", "markerLoadStarted":
    let total = if body.hasKey("totalDeclared"): body["totalDeclared"].getInt else: 0
    vm.loadingBanner.val = MarkerLoadingBanner(phase: mlbLoading, loaded: 0, total: total)
  of "ct/markerLoadProgress", "markerLoadProgress":
    let loaded = if body.hasKey("loaded"): body["loaded"].getInt else: 0
    let total = if body.hasKey("total"): body["total"].getInt else: 0
    vm.loadingBanner.val = MarkerLoadingBanner(phase: mlbLoading, loaded: loaded, total: total)
  of "ct/markerLoadCompleted", "markerLoadCompleted":
    let final = if body.hasKey("finalLoaded"): body["finalLoaded"].getInt else: vm.loadingBanner.val.loaded
    vm.loadingBanner.val = MarkerLoadingBanner(phase: mlbDone, loaded: final, total: final)
  else:
    discard

proc applyDiscoveredMarkers*(vm: EventLogVM; declaredCount, firedCount: int; workspaceId: string) =
  ## Drive the §5.5 empty-state banner and the §7 one-time discovery
  ## toast. Called once per session-load after the marker load
  ## completes.
  if declaredCount > 0 and firedCount == 0:
    vm.emptyState.val = MarkerEmptyState(kind: mesDeclaredNoneFired, declaredCount: declaredCount)
  else:
    vm.emptyState.val = MarkerEmptyState(kind: mesHidden, declaredCount: declaredCount)
  if declaredCount > 0 and workspaceId notin vm.dismissedWorkspaces.val:
    vm.toastState.val = MarkerToastState(
      kind: mtVisible,
      discoveredCount: declaredCount,
      workspaceId: workspaceId,
    )
  else:
    vm.toastState.val = MarkerToastState(
      kind: mtHidden,
      discoveredCount: declaredCount,
      workspaceId: workspaceId,
    )

proc dismissToast*(vm: EventLogVM; workspaceId: string) =
  ## Hide the discovery toast and record the dismissal so the same
  ## workspace doesn't re-trigger it. The dismissal log is held on
  ## the VM here; production wiring persists it through the
  ## preferences-store bridge per spec §7.
  if workspaceId notin vm.dismissedWorkspaces.val:
    var dismissed = vm.dismissedWorkspaces.val
    dismissed.add(workspaceId)
    vm.dismissedWorkspaces.val = dismissed
  vm.toastState.val = MarkerToastState(
    kind: mtHidden,
    discoveredCount: vm.toastState.val.discoveredCount,
    workspaceId: workspaceId,
  )

proc jumpToCounterpart*(vm: EventLogVM; row: MarkerEventRow) =
  ## §5.3 jump-button action. Switches the active process via
  ## `ct/listProcesses` (when the counterpart lives in a sibling
  ## trace) then seeks the timeline via `ct/goto-ticks`. The Event
  ## Log highlights the row on the subsequent move-complete event.
  ##
  ## We deliberately do *not* introduce a new DAP request — the
  ## navigation reuses the surfaces M24 already shipped.
  if vm.loadingBanner.val.phase == mlbLoading:
    # Spec §5.4.1: "Jump-button rendering is deferred per row until
    # both endpoints of the pair are loaded." The view should not
    # render the button at all in this state, but defend in depth.
    return
  if row.recordingId.len > 0:
    let switchArgs = %*{"recordingId": row.recordingId}
    discard vm.store.backend.send("ct/listProcesses", switchArgs)
  let gotoArgs = %*{
    "rrTicks": row.stepId,
    "ticks": row.stepId,
  }
  discard vm.store.backend.send("ct/goto-ticks", gotoArgs)

# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

proc createEventLogVM*(store: ReplayDataStore): EventLogVM =
  ## Create an EventLogVM inside a reactive root owned by `withViewModel`.
  ## The reactive root is disposed via `vm.dispose()`.
  ##
  ## Sets up:
  ## 1. Mutable signals with sensible defaults
  ## 2. Derived memos for `totalPages` and `isLoading`
  ## 3. An auto-load effect that requests event log data when
  ##    page, sort, search, or debugger position changes
  withViewModel proc(dispose: proc()): EventLogVM =
    let selectedRow = createSignal(none(int))
    let currentPage = createSignal(0)
    let pageSize = createSignal(DEFAULT_PAGE_SIZE)
    let searchQuery = createSignal("")
    let sortColumn = createSignal(0)
    let sortAscending = createSignal(true)

    # Internal event log state (not yet in ReplayDataStore).
    let eventRows = createSignal(newSeq[EventLogRow]())
    let totalEventCount = createSignal(0)
    let loadingState = createSignal(lsIdle)

    # M25b — Marker reactive surface (spec §5).
    let markerRows = createSignal(newSeq[MarkerEventRow]())
    let counterpartCache = createSignal(initTable[CounterpartKey, seq[MarkerEventRow]]())
    let loadingBanner = createSignal(MarkerLoadingBanner(phase: mlbIdle, loaded: 0, total: 0))
    let filterBar = createSignal(MarkerFilterBar())
    let emptyState = createSignal(MarkerEmptyState(kind: mesHidden, declaredCount: 0))
    let toastState = createSignal(MarkerToastState(kind: mtHidden, discoveredCount: 0, workspaceId: ""))
    let dismissedWorkspaces = createSignal(newSeq[string]())

    # Derived: total pages from event count and page size.
    let totalPages = createMemo[int] proc(): int =
      let total = totalEventCount.val
      let ps = pageSize.val
      if ps <= 0:
        return 0
      (total + ps - 1) div ps

    # Derived: loading indicator.
    let isLoading = createMemo[bool] proc(): bool =
      loadingState.val == lsLoading

    # M25b — §5.4 visible-rows derivation. Reactive on markerRows +
    # filterBar + counterpartCache (the `unmatched` shorthand needs
    # the cache to know which rows have empty counterpart sets).
    let visibleMarkerRows = createMemo[seq[MarkerEventRow]] proc(): seq[MarkerEventRow] =
      let rows = markerRows.val
      let filter = filterBar.val
      let cache = counterpartCache.val
      var visible: seq[MarkerEventRow] = @[]
      for row in rows:
        let key = counterpartKey(row)
        let cps = if cache.hasKey(key): cache[key] else: @[]
        let isUnmatched = cps.len == 0
        if rowMatchesFilter(row, filter, isUnmatched):
          visible.add(row)
      visible

    let vm = EventLogVM(
      store: store,
      selectedRow: selectedRow,
      currentPage: currentPage,
      pageSize: pageSize,
      searchQuery: searchQuery,
      sortColumn: sortColumn,
      sortAscending: sortAscending,
      eventRows: eventRows,
      totalEventCount: totalEventCount,
      loadingState: loadingState,
      markerRows: markerRows,
      counterpartCache: counterpartCache,
      loadingBanner: loadingBanner,
      filterBar: filterBar,
      emptyState: emptyState,
      toastState: toastState,
      dismissedWorkspaces: dismissedWorkspaces,
      totalPages: totalPages,
      isLoading: isLoading,
      visibleMarkerRows: visibleMarkerRows,
      disposeProc: dispose,
    )

    # Auto-load effect: whenever page, sort, search, or debugger position
    # changes, request fresh event log data from the backend.
    #
    # Dedup intentionally piggybacks on the effect itself: ``store.debugger``
    # is reassigned on every legacy ``updateDebuggerPosition`` call (the
    # signal does *not* compare values), so without an explicit guard this
    # effect re-fires several times per CtCompleteMove — once per panel
    # that calls ``updateDebuggerPosition`` on the shared store.  When the
    # trace's entry stop sits on a non-zero rrTicks (e.g. the JavaScript
    # recorder's flow_test where step[0] has call_key=-1 and the first
    # real call starts at step 1, giving rrTicks=1 at launch) every one of
    # those reassignments would issue a fresh ``ct/event-load``.  Each
    # response then triggers ``onUpdatedEvents`` → ``ajax.reload`` →
    # ``ct/update-table``; the DataTables ``td.dt-empty`` "Loading…"
    # placeholder never clears because a newer ajax round-trip is always
    # in flight, and the GUI test times out.  Tracking the last
    # (rrTicks, page, pageSize, searchQuery, sortColumn, sortAscending)
    # tuple lets unchanged events keep the table populated rather than
    # forcing a reload — events are intrinsically static for non-live
    # traces, so re-fetching with the same parameters is wasted work.
    var lastTicks: uint64 = 0
    var lastPage = -1
    var lastPageSize = -1
    var lastQuery = ""
    var lastCol = -1
    var lastAsc = false
    var lastHadDebuggerPosition = false
    var hasFired = false
    createEffect proc() =
      let page = currentPage.val
      let ps = pageSize.val
      let query = searchQuery.val
      let col = sortColumn.val
      let asc = sortAscending.val
      let debuggerState = store.debugger.val
      let ticks = debuggerState.rrTicks
      let location = debuggerState.location
      let hasDebuggerPosition =
        ticks > 0'u64 or location.file.len > 0 or location.line != 0
      if hasDebuggerPosition or not hasFired:
        if hasFired and hasDebuggerPosition == lastHadDebuggerPosition and
            ticks == lastTicks and page == lastPage and
            ps == lastPageSize and query == lastQuery and
            col == lastCol and asc == lastAsc:
          return
        lastTicks = ticks
        lastPage = page
        lastPageSize = ps
        lastQuery = query
        lastCol = col
        lastAsc = asc
        lastHadDebuggerPosition = hasDebuggerPosition
        hasFired = true
        let args = %*{
          "page": page,
          "pageSize": ps,
          "searchQuery": query,
          "sortColumn": col,
          "sortAscending": asc,
          "rrTicks": ticks,
        }
        let future = store.backend.send("ct/event-load", args)
        let vmRef = vm
        onComplete(future,
          proc(response: JsonNode) =
            vmRef.applyMarkerRowsResponse(response),
          proc(message: string) =
            discard)

    vm
