## store/replay_data_store.nim
##
## ReplayDataStore — the central reactive data layer for the ViewModel
## architecture.
##
## Holds IsoNim signals for every piece of state that panels display and
## exposes high-level request procs that talk to the BackendService.
## The store owns the RequestTracker to avoid duplicate in-flight
## requests and updates LoadingState signals so the UI can show
## spinners / errors.
##
## Usage:
##   let store = createReplayDataStore(backend)
##   # read reactive state
##   echo store.debugger.val.status       # dsIdle
##   # issue a command — signals update asynchronously
##   store.requestStep(sdForward)

import std/[json, options, strutils, tables]
# Diagnostics go through `vm_log`, not the renderer's `lib/logging`: that
# module reaches `dom`/`kdom` and would put a DOM shim in the Embed SDK's
# package graph (CodeTracer-Embed-SDK.md §3.2). See vm_log.nim.
import ../vm_log

import isonim/core/[signals, owner, async_compat]
import isonim/viewmodel

import ../backend/backend_service
import types, request_tracker, degraded_state
export degraded_state

const
  LiveMcrGetRecordingHeadCommand* = "ct/mcr-get-recording-head"
  LiveMcrRestoreAtCommand* = "ct/mcr-restore-at"
  LiveRecordingRestoreAtCommand* = "ct/live-restore-at"
  LiveMcrStepCommand* = "ct/mcr-live-step"
  SeekToGeidCommand* = "ct/seek-to-geid"
  LoadRequestSpansSinceCommand* = "ct/load-request-spans-since"
    ## RS-M3 — poll the backend for HTTP request spans committed since the
    ## cursor we last received.  The response body and the body of the
    ## ``ct/updated-http-requests`` event are the same shape, so both are fed
    ## through ``applyRequestSpanDelta``.

  UpdatedHttpRequestsEventKind* = "CtUpdatedHttpRequests"
    ## ``CtEventKind`` name the RealBackendService stamps into the envelope's
    ## ``kind`` field (see ``backend/real_backend.nim`` — it forwards
    ## ``$CtEventKind`` plus the raw body under ``data``).
  LoadRequestSpansSinceEventKind* = "CtLoadRequestSpansSince"
    ## The same envelope for the *response* to our own poll.  The renderer's
    ## ``asyncSendCtRequest`` resolves its promise immediately with an empty
    ## object and delivers the real body through the DAP response channel, so
    ## the response has to be consumed here rather than off the future.
    ## Applying it is harmless when the event already arrived: a delta merge is
    ## idempotent (same ids, same cursor).
  ReplayStatusEventKind* = "CtReplayStatus"
    ## The degraded-state channel (Page-Descriptions.md §14).
    ##
    ## One event carries all four axes because they are read together —
    ## `resolveDegradation` takes a snapshot, not four arguments — and
    ## because a host that knows one of them usually learns the rest at the
    ## same moment (session start, a validation verdict, a capability
    ## probe). Every field is optional and an absent field leaves its
    ## signal alone, so a host that only ever learns about capability can
    ## send `{"capability": "..."}` and nothing else.

# ---------------------------------------------------------------------------
# Store identity tracking — unique ID per store instance for diagnostics
# ---------------------------------------------------------------------------
var storeIdCounter {.global.}: int = 0

# ---------------------------------------------------------------------------
# Cross-platform future callback helper
# ---------------------------------------------------------------------------

proc onComplete(fut: BackendFuture[JsonNode];
                onSuccess: proc(); onError: proc()) =
  ## Convenience wrapper around `async_compat.onComplete` that discards
  ## the result value and error message, matching the fire-and-forget
  ## pattern used by store request procs.
  async_compat.onComplete(fut,
    onSuccess = proc(val: JsonNode) = onSuccess(),
    onError = proc(msg: string) = onError())

proc readRRTicks(response: JsonNode; fallback: uint64): uint64 =
  ## Accept the likely fake/real backend response shapes used while MCR live
  ## support is still behind test seams.
  if response.kind != JObject:
    return fallback

  for key in ["rrTicks", "recordingHead", "head"]:
    if response.hasKey(key):
      let raw = response[key].getBiggestInt
      if raw < 0:
        return 0'u64
      return uint64(raw)

  fallback

# ---------------------------------------------------------------------------
# Sub-store aggregates — group related signals
# ---------------------------------------------------------------------------

type
  CalltraceStore* = object
    ## Reactive state for the calltrace panel.
    lines*: Signal[seq[CallLine]]
    ## Per-call argument values keyed by ``CallLine.callKey``. The old
    ## Karax calltrace rows read the same map (``CalltraceComponent.args``)
    ## to render each row's ``.call-arg`` children. Mirroring it into the
    ## store lets the IsoNim view emit identical DOM driven purely by
    ## reactive data.
    args*: Signal[Table[string, seq[CallArg]]]
    startLineIndex*: Signal[int64]
    totalCallsCount*: Signal[uint64]
    finished*: Signal[bool]
    loadingState*: Signal[LoadingState]

  LocalsStore* = object
    ## Reactive state for the locals / globals panel.
    locals*: Signal[seq[Variable]]
    globals*: Signal[seq[Variable]]
    watches*: Signal[seq[Variable]]
      ## Answers to the user's watch expressions at the loaded step.
      ##
      ## Watches ride the `ct/load-locals` response — there is no separate
      ## `evaluate` route — so they arrive interleaved with the locals and
      ## are told apart by `value.isWatch`, which the backend sets. They
      ## are kept in their OWN signal rather than filtered out of `locals`
      ## at render time for two reasons: the Watches tab must be able to
      ## show a watch whose expression equals a local's name, and a watch
      ## that was REFUSED still has to be a row (its value is an `Error`
      ## carrying the reason), which a locals list has no place for.
    loadingState*: Signal[LoadingState]
    loadedForRRTicks*: Signal[uint64]
      ## The rrTicks value that the currently loaded data corresponds to.
      ## Lets the UI know whether the data is stale relative to the
      ## debugger position.
    codeStateLine*: Signal[string]
      ## Pre-formatted "<line> | <sourceCode>" string shown above the
      ## variables list (rendered as the `#code-state-line-{id}`
      ## element in the IsoNim state view).  The legacy Karax
      ## ``StateComponent.excerpt`` proc rendered the same text from
      ## ``data.ui.editors[path].sourceLines[line - 1]``; mirroring it
      ## into the store lets the IsoNim view emit the DOM the
      ## Playwright tests look for, regardless of whether the trace is
      ## RR or Materialized.  Empty string means "no source" — the
      ## view falls back to the ``no-code`` class with a blank label.

  EventLogWindowSource* = enum
    ## WHICH BACKEND ROUTE PRODUCED THE WINDOW `EventLogStore.rows` HOLDS.
    ##
    ## Two routes answer with the same underlying events in different shapes
    ## and, crucially, with different WINDOWS:
    ##
    ##   * `ct/event-load` answers a slice of the log chosen by `start`/`count`
    ##     — and, when the caller supplies neither, a fixed prefix of 20 rows
    ##     (`Handler::event_load`, `src/db-backend/src/dap_handler.rs`). It
    ##     applies no kind filter and no search.
    ##   * `ct/update-table` answers the window the PANE asked for: the user's
    ##     page (`start`/`length`), their kind filter (`selectedKinds`) and
    ##     their search (`search.value`), all applied server-side by
    ##     `EventDb::update_table`.
    ##
    ## A host that has both — the Electron desktop, whose DataTables widget
    ## pages with the second while `EventLogVM`'s auto-load effect issues the
    ## first — therefore has two producers writing one signal with two
    ## different answers to "which rows are on screen". Before this enum
    ## existed, whichever reply landed last won, so the shared rows flipped
    ## between the pane's actual page and an unfiltered 20-row prefix
    ## depending on network ordering.
    ##
    ## The precedence rule is in `applyEventLogRows`, and it is not arbitrary:
    ## the window the user is LOOKING AT is the one the pane paged, filtered
    ## and sorted to, so once a table window has been applied an event-load
    ## window no longer replaces the rows. It still raises the totals and the
    ## recording's extent, because those are facts about the recording rather
    ## than about the window. A host with only `ct/event-load` (the terminal,
    ## the GPUI shell, the storybook, an out-of-tree consumer) never sets
    ## `elwsTable` and is completely unaffected.
    elwsUnknown
      ## No window has been applied yet, or the producer did not say. A
      ## producer that passes this neither claims nor yields precedence: it is
      ## what `appendLiveEventRow` uses to re-apply the window it just grew.
    elwsEventLoad
      ## `ct/event-load` / the `ct/updated-events` echo of the same answer.
    elwsTable
      ## `ct/update-table` — the paged, filtered, sorted window a DataTables
      ## host renders.

  EventLogStore* = object
    ## Reactive state for the event-log panel.
    ##
    ## THE ROWS LIVE HERE AND NOT ON `EventLogVM`, for the reason
    ## `applyLocalsResponse` states about the locals: a payload that three
    ## front-ends each decode is a payload three front-ends can disagree
    ## about. `applyEventLogResponse` is the one decoder; `EventLogVM.eventRows`
    ## IS this signal, and the terminal, the desktop and any out-of-tree
    ## consumer read the same object.
    rows*: Signal[seq[EventLogRow]]
      ## The rows of the window most recently applied — `loadedStart` says
      ## which window that is. A page and not the whole log, because
      ## `ct/event-load` is paginated (`start`/`count`) and a store that
      ## pretended otherwise would have to decide what to do with the gap
      ## between two non-adjacent pages.
    recordsTotal*: Signal[int]
      ## The largest number of rows this session has been told about. It is a
      ## HIGH-WATER MARK rather than the engine's own count: `ct/event-load`'s
      ## response body carries `events`, `content` and `markers` and no total
      ## (`Handler::event_load`, `src/db-backend/src/dap_handler.rs`), so the
      ## only honest total available here is derived from what has arrived.
      ## The desktop's DataTables path has a real `recordsTotal` and publishes
      ## it through `applyEventLogRows`.
    recordsFiltered*: Signal[int]
      ## The same count after the server-side search filter, for a host that
      ## has one. Equal to `recordsTotal` when nothing filtered.
    maxRRTicks*: Signal[uint64]
      ## The recording's last step id, as reported by the events themselves.
      ## CTUI-8 established that this is the ONLY surface in the workspace that
      ## reports a completed replay's extent, which is why the terminal reads
      ## a whole page at open just to learn it.
    loadedStart*: Signal[int]
      ## The `start` offset of the window `rows` holds.
    windowSource*: Signal[EventLogWindowSource]
      ## Which route produced the window `rows` holds. See
      ## `EventLogWindowSource` for why one signal needs to remember this.
    loadingState*: Signal[LoadingState]

  PointListStore* = object
    ## Reactive state for the point list (tracepoints / breakpoints) and for
    ## the answers a post-hoc tracepoint sweep produced.
    ##
    ## Both are here for the same reason the event log's rows are: a point row
    ## is read by the terminal's list pane, the desktop's point list and the
    ## vocabulary's `tracepointsPaneView`, and the sweep that produces the
    ## engine-side ones has exactly one decoder — `applyTracepointResults`.
    rows*: Signal[seq[PointListEntry]]
      ## Every declared point, whatever became of it. `PointListVM.points` IS
      ## this signal.
      ##
      ## TWO PRODUCERS, deliberately, and they do not fight: project
      ## definitions (`point_collection_source.applyCollections`, which resolves
      ## anchors against source text) and the engine
      ## (`applyTracepointResults`, which reports what a sweep actually found).
      ## The second MERGES by `(path, line)` rather than replacing, so running a
      ## sweep over a collection's points annotates those rows instead of
      ## deleting the ones the sweep did not name.
    tracepointHits*: Signal[seq[TracepointSweepHit]]
      ## Every `Stop` the last sweep answered, in the engine's own order
      ## (ascending `rrTicks`). Cleared and replaced per sweep: a sweep is a
      ## complete walk of the recording, so merging two of them would report a
      ## history rather than a result.
    loadingState*: Signal[LoadingState]

  RequestSpansStore* = object
    ## RS-M3 — reactive state for the HTTP Request panel's live tail.
    ##
    ## The store, not the panel VM, owns the span list: the tail keeps
    ## growing while the panel is closed, and a panel re-mount must show the
    ## rows that arrived meanwhile rather than an empty table.
    requests*: Signal[seq[RequestRecord]]
      ## Merged rows in capture order (ascending ``id``, oldest first — the
      ## order the pane spec's Layout section requires).  A delta record
      ## whose ``id`` is already present replaces that row *in place*, so an
      ## open row settling into its completion never produces a second row.
    cursor*: Signal[int64]
      ## The cursor to send with the next poll.  **Opaque**: a chunk count
      ## for a span stream, a record count for a legacy sidecar.  It is
      ## echoed back verbatim and never has arithmetic done to it.  ``0``
      ## means "no cursor yet", which asks the backend for a snapshot.
    source*: Signal[string]
      ## ``"span-stream"`` / ``"legacy-jsonl"`` / ``"none"`` — which
      ## producer the last delta came from.  Diagnostics only; the merge
      ## rules do not depend on it.
    loadingState*: Signal[LoadingState]

  DegradedStateStore* = object
    ## The degraded-state catalogue's four axes, as signals
    ## (`store/degraded_state.nim`, Page-Descriptions.md §14).
    ##
    ## They live on the store rather than on a pane because §14's whole
    ## point is that each condition has *one* canonical treatment: five
    ## panes reading five copies would be five chances to disagree about
    ## whether this replay is windowed. The panes differ only in which
    ## rows they render, which is `store/degraded_state.nim`'s per-pane
    ## sensitivity sets.
    availability*: Signal[ReplayAvailability]
    integrity*: Signal[TraceIntegrity]
    capability*: Signal[ReplayCapability]
    sourceAvailability*: Signal[SourceAvailability]

  ReplayDataStore* = ref object of ViewModel
    ## Central reactive store.  Created via `createReplayDataStore`.
    storeId*: int  ## Unique identity for diagnostics — assigned in createReplayDataStore.
    session*: Signal[SessionState]
    debugger*: Signal[DebuggerState]
    currentGeid*: Signal[Option[uint64]]
    timeline*: Signal[TimelineState]
    agentSessions*: Signal[AgentSessionsState]
    calltrace*: CalltraceStore
    locals*: LocalsStore
    eventLog*: EventLogStore
    pointList*: PointListStore
    requestSpans*: RequestSpansStore
    degraded*: DegradedStateStore
    backend*: BackendService
    requestTracker*: RequestTracker

# ---------------------------------------------------------------------------
# Degraded state (Page-Descriptions.md §14)
# ---------------------------------------------------------------------------

proc degradedSnapshot*(store: ReplayDataStore): DegradedStateSnapshot =
  ## Read all four axes as one value. Every pane memo calls this, so a
  ## memo depends on exactly the signals the resolution needs and on all
  ## of them — a memo that read three would go stale on the fourth.
  DegradedStateSnapshot(
    availability: store.degraded.availability.val,
    integrity: store.degraded.integrity.val,
    capability: store.degraded.capability.val,
    sourceAvailability: store.degraded.sourceAvailability.val,
  )

proc setReplayAvailability*(store: ReplayDataStore;
                            availability: ReplayAvailability) =
  ## §14.1a. Set by the host when it learns whether the trace behind this
  ## session is retained, windowed, expired or terminal.
  store.degraded.availability.val = availability

proc setTraceIntegrity*(store: ReplayDataStore; integrity: TraceIntegrity) =
  ## §14's "Trace truncated" / "Divergence detected" rows.
  store.degraded.integrity.val = integrity

proc setReplayCapability*(store: ReplayDataStore;
                          capability: ReplayCapability) =
  ## §14.2. Set from the host's capability probe or from the failure that
  ## terminated the worker.
  store.degraded.capability.val = capability

proc setSourceAvailability*(store: ReplayDataStore;
                            availability: SourceAvailability) =
  ## §14's "No verified source" row.
  store.degraded.sourceAvailability.val = availability

proc parseReplayAvailability*(raw: string;
                              fallback: ReplayAvailability): ReplayAvailability =
  ## Wire spellings for `ReplayAvailability`, taken from §14.1a's own
  ## table rows rather than from the Nim identifiers, so the enum can be
  ## renamed without breaking a host.
  case raw
  of "retained": raRetained
  of "windowed-live": raWindowedLive
  of "window-expired": raWindowExpired
  of "never-generated": raNeverGenerated
  of "unreplayable": raUnreplayable
  else: fallback

proc parseTraceIntegrity*(raw: string; fallback: TraceIntegrity): TraceIntegrity =
  case raw
  of "complete": tiComplete
  of "truncated": tiTruncated
  of "divergent": tiDivergent
  else: fallback

proc parseReplayCapability*(raw: string;
                            fallback: ReplayCapability): ReplayCapability =
  ## §14.2's four failure rows, plus the capable case. The names are the
  ## detections in §14.2's "Detected" column, not generic error codes —
  ## that distinction is the row's entire point.
  case raw
  of "capable": rcCapable
  of "wasm-compilation-failed": rcWasmCompilationFailed
  of "insufficient-memory": rcInsufficientMemory
  of "range-requests-unsupported": rcRangeRequestsUnsupported
  of "worker-unsupported": rcWorkerUnsupported
  else: fallback

proc parseSourceAvailability*(raw: string;
                              fallback: SourceAvailability): SourceAvailability =
  case raw
  of "verified": savVerified
  of "unverified": savUnverified
  of "absent": savAbsent
  else: fallback

proc applyReplayStatus*(store: ReplayDataStore; body: JsonNode) =
  ## Decode a `CtReplayStatus` body into the four axes.
  ##
  ## Absent and unrecognised fields leave the corresponding signal
  ## untouched. An unrecognised value must NOT fall back to the
  ## undegraded default: a host that starts speaking a spelling this
  ## build does not know would otherwise silently report a healthy
  ## replay, which is the failure §14 exists to prevent.
  if body.isNil or body.kind != JObject:
    return
  if body.hasKey("availability") and body["availability"].kind == JString:
    store.setReplayAvailability(parseReplayAvailability(
      body["availability"].getStr, store.degraded.availability.val))
  if body.hasKey("integrity") and body["integrity"].kind == JString:
    store.setTraceIntegrity(parseTraceIntegrity(
      body["integrity"].getStr, store.degraded.integrity.val))
  if body.hasKey("capability") and body["capability"].kind == JString:
    store.setReplayCapability(parseReplayCapability(
      body["capability"].getStr, store.degraded.capability.val))
  if body.hasKey("sourceAvailability") and body["sourceAvailability"].kind == JString:
    store.setSourceAvailability(parseSourceAvailability(
      body["sourceAvailability"].getStr, store.degraded.sourceAvailability.val))

proc setDebuggerSnapshot(store: ReplayDataStore; rrTicks: uint64;
                         status: DebuggerStatus) =
  let current = store.debugger.val
  store.debugger.val = DebuggerState(
    rrTicks: rrTicks,
    location: current.location,
    status: status,
    threadId: current.threadId,
  )

proc setSessionMode*(store: ReplayDataStore; mode: DebugSessionMode) =
  ## Update only the debug-session mode, preserving connection/head state.
  var session = store.session.val
  session.debugSessionMode = mode
  if mode in {liveMcr, liveMaterialized}:
    session.lastLiveDebugSessionMode = mode
  store.session.val = session

proc enterCompletedReplayMode*(store: ReplayDataStore) =
  ## Declare that this session is now an ordinary completed replay.
  ##
  ## THE SYMMETRIC PARTNER OF `setSessionMode(liveMcr)`, and it was missing.
  ## `ui_js.handleDapLiveSessionSelected` announces a live session to the store;
  ## `handleDapReplaySelected` announced nothing, and pure replay was correct
  ## only because `completedReplay` is the enum's zero value and a fresh store
  ## therefore starts there.
  ##
  ## A REUSED TAB IS NOT A FRESH STORE. *Stop* now ends a debugging session and
  ## leaves the tab open precisely so a new one can be started in it
  ## (`ui/stop_command.nim`), so "this tab last held a live MCR session and now
  ## holds a replay" went from unlikely to the specified flow. Without this,
  ## `debugSessionMode` stayed `liveMcr` over the new replay, and two things
  ## broke that have nothing to do with liveness:
  ##
  ## * `backwardNavigationAvailable` (`debug_controls_vm.nim`) excludes
  ##   `{liveMcr, liveMaterialized}`, so reverse step over / in / out and
  ##   reverse continue were all greyed out on a replay that fully supports
  ##   them;
  ## * `invokeToolbarStep` routes `liveMcr` through `requestLiveToolbarAction`,
  ##   whose `liveToolbarActionAllowed` admits only `next`, `step-in`,
  ##   `step-out` and `continue` — so the reverse controls were dead as well as
  ##   grey, and the forward ones went to `ct/mcr-live-step` instead of the DAP
  ##   step path.
  ##
  ## `lastLiveDebugSessionMode` is cleared too, and that is not tidiness.
  ## It is what `rememberedLiveMode` returns to on *Jump to live*; carrying a
  ## previous session's live mode into a new replay would offer a jump back to
  ## a recording head that belongs to a program that is no longer running.
  ## Clearing it is safe because `completedReplay` cannot reach
  ## `historicalFromLive`: `enterHistoricalModeForNavigation` refuses unless
  ## the session is already live.
  var session = store.session.val
  session.debugSessionMode = completedReplay
  session.lastLiveDebugSessionMode = completedReplay
  store.session.val = session

proc setSupportsStepBack*(store: ReplayDataStore; supports: bool) =
  ## Update the supportsStepBack capability in the session state.
  var session = store.session.val
  session.supportsStepBack = supports
  store.session.val = session

proc isLiveSessionMode*(mode: DebugSessionMode): bool =
  mode in {liveMcr, liveMaterialized}

proc historicalModeTarget*(mode: DebugSessionMode): bool =
  mode.isLiveSessionMode or mode == historicalFromLive

proc rememberedLiveMode(session: SessionState): DebugSessionMode =
  if session.lastLiveDebugSessionMode in {liveMcr, liveMaterialized}:
    session.lastLiveDebugSessionMode
  elif session.debugSessionMode in {liveMcr, liveMaterialized}:
    session.debugSessionMode
  else:
    liveMcr

proc requestRecordingHead*(store: ReplayDataStore)

proc enterHistoricalModeForNavigation*(store: ReplayDataStore) =
  ## Mark a live recording session as browsing recorded history. Completed
  ## replay sessions stay completed replay: there is no live head to return to.
  var session = store.session.val
  if session.debugSessionMode in {liveMcr, liveMaterialized}:
    session.lastLiveDebugSessionMode = session.debugSessionMode
    session.debugSessionMode = historicalFromLive
    store.session.val = session
    store.requestRecordingHead()

proc requestHistoricalNavigation*(store: ReplayDataStore; command: string;
                                  args: JsonNode) =
  ## Send a navigation command that targets a recorded moment. When invoked
  ## from a live session, the UI enters historical mode immediately; the
  ## backend's complete-move event will refresh the exact debugger position.
  store.enterHistoricalModeForNavigation()
  discard store.backend.send(command, args)

proc updateRecordingHead*(store: ReplayDataStore; rrTicks: uint64) =
  ## Mirror a backend recording-head update into session and timeline state.
  var session = store.session.val
  session.recordingHeadRRTicks = rrTicks
  session.recordingHeadLoadingState = lsIdle
  store.session.val = session

  var timeline = store.timeline.val
  if rrTicks > timeline.maxRRTicks:
    timeline.maxRRTicks = rrTicks
  store.timeline.val = timeline

# ---------------------------------------------------------------------------
# RS-M3 — HTTP request span deltas
#
# Wire contract (implemented and tested backend-side in
# ``src/db-backend/src/request_spans.rs``; see
# ``codetracer-specs/Planned-Features/Request-Panel-Live-Sessions.milestones.org``
# §RS-M3):
#
#   { "spans": RequestRecord[], "cursor": <opaque>, "reset": bool,
#     "source": "span-stream" | "legacy-jsonl" | "none" }
#
# The same body is the ``ct/load-request-spans-since`` response AND the
# ``ct/updated-http-requests`` event payload, so one apply proc serves both.
#
# Client algorithm:
#   reset == true  -> replace the list with ``spans``
#   reset == false -> merge each record keyed on ``id``, last wins
#
# Filtering stays on the client (``RequestPanelVM.filteredRequests``). The
# backend deliberately never filters a delta: a row that matches a filter
# while it is open may stop matching once it completes, and if the backend
# had filtered the open row out, the superseding completion would never be
# sent and the panel would keep a stale in-flight row forever.
# ---------------------------------------------------------------------------

proc parseRequestRecord*(node: JsonNode): RequestRecord =
  ## Decode one wire ``RequestRecord``.  Every field is read defensively:
  ## a recorder that omits an optional key (``responseSize``,
  ## ``externalTracePath``) or a backend built before a field existed must
  ## degrade to a usable row rather than drop the request.
  if node.isNil or node.kind != JObject:
    return RequestRecord(status: "unknown")
  RequestRecord(
    id: node{"id"}.getInt(0),
    httpMethod: node{"httpMethod"}.getStr(""),
    url: node{"url"}.getStr(""),
    statusCode: node{"statusCode"}.getInt(0),
    durationMs: node{"durationMs"}.getInt(0),
    responseSize: node{"responseSize"}.getInt(0),
    startGeid: node{"startGeid"}.getBiggestInt(0).int64,
    isOpen: node{"isOpen"}.getBool(false),
    # An absent status byte is "unknown", matching the backend's
    # ``SpanStatus::Unknown`` default rather than silently reading as "ok".
    status:
      if node{"status"}.getStr("").len > 0: node{"status"}.getStr("")
      else: "unknown",
    # ``externalTracePath`` is nullable on the wire; ``getStr`` maps both
    # ``null`` and an absent key to "", which is this layer's "no external
    # container" sentinel (avoids Option noise across the JS/native split).
    externalTracePath: node{"externalTracePath"}.getStr(""),
  )

proc mergeRequestSpans*(existing: seq[RequestRecord];
                        delta: seq[RequestRecord]): seq[RequestRecord] =
  ## Merge ``delta`` into ``existing`` keyed on ``id``, last wins.
  ##
  ## ``id`` is the span id — 1-based and stable — so a re-delivered range
  ## (deltas may overlap; the backend re-sends a record whose completion
  ## superseded an earlier open one) updates the row in place and never
  ## appends a duplicate.  New ids are appended in delta order, which is
  ## ascending, preserving the panel's oldest-first ordering.
  result = existing
  var indexById = initTable[int, int]()
  for i, req in result:
    indexById[req.id] = i
  for req in delta:
    if indexById.hasKey(req.id):
      result[indexById[req.id]] = req
    else:
      indexById[req.id] = result.len
      result.add(req)

proc applyRequestSpanDelta*(store: ReplayDataStore; body: JsonNode) =
  ## Apply one delta body (response or event) to the store.
  ##
  ## Malformed bodies are ignored rather than clearing the panel: a
  ## truncated or unexpected payload must not destroy rows the user is
  ## looking at.
  if body.isNil or body.kind != JObject:
    return
  if not body.hasKey("spans") and not body.hasKey("cursor"):
    # Not a delta envelope at all (e.g. the empty object the renderer's
    # ``asyncSendCtRequest`` resolves its promise with).
    return

  var incoming: seq[RequestRecord] = @[]
  let spansNode = body{"spans"}
  if not spansNode.isNil and spansNode.kind == JArray:
    incoming = newSeqOfCap[RequestRecord](spansNode.len)
    for item in spansNode:
      incoming.add(parseRequestRecord(item))

  let reset = body{"reset"}.getBool(false)
  store.requestSpans.requests.val =
    if reset: incoming
    else: mergeRequestSpans(store.requestSpans.requests.val, incoming)

  if body.hasKey("cursor"):
    store.requestSpans.cursor.val = body{"cursor"}.getBiggestInt(0).int64
  let source = body{"source"}.getStr("")
  if source.len > 0:
    store.requestSpans.source.val = source
  store.requestSpans.loadingState.val = lsIdle

proc clearRequestSpans*(store: ReplayDataStore) =
  ## Drop every tailed row and forget the cursor, so the next poll asks for
  ## a fresh snapshot.  Used when the session restarts or the panel's
  ## "Clear" button is pressed.
  store.requestSpans.requests.val = @[]
  store.requestSpans.cursor.val = 0'i64
  store.requestSpans.source.val = ""
  store.requestSpans.loadingState.val = lsIdle

proc clearEventLog*(store: ReplayDataStore)
  ## Forward-declared: the event-log appliers are grouped with the other
  ## response handlers further down, and this is the one caller above them.

proc resetForNewSession*(store: ReplayDataStore) =
  ## Forget the requests a previous session — or no session at all — left
  ## outstanding, now that there is a backend able to answer.
  ##
  ## WHY A STORE CAN HOLD A REQUEST THAT WAS NEVER ASKED. The panel
  ## ViewModels issue their first request from an effect that runs at
  ## CONSTRUCTION, and construction happens in `configureMiddleware` —
  ## before `openSession` has made a worker on the web path, and before
  ## the DAP session is selected on the desktop one. `requestLocals` marks
  ## `"load-locals"` pending, hands the frame to a channel with no peer
  ## (`ipc.send` warns `no host for ...` and drops it), and the future is
  ## never settled, so `markComplete` in its `onComplete` is never reached.
  ##
  ## The entry then outlives the moment it was made for. When the worker
  ## does arrive and the first move re-fires the effect, the request is
  ## byte-identical — `rrTicks` is 0 at every position on a db-backend
  ## trace, so the dedup key `"0|"` matches exactly — and `isDuplicate`
  ## returns true. The store skips the send. Nothing asks, nothing
  ## answers, and the pane sits on the `lsLoading` the dead boot request
  ## set, waiting for a reply to a question that was never put. Thirty
  ## seconds later the DAP timeout (`dap.nim:428`) settles the original
  ## future, `markComplete` finally runs, and the pane converts from a
  ## stuck spinner into a silently empty one — a clear that arrives after
  ## the moment it was needed is not a clear.
  ##
  ## `ui/calltrace.nim:383` already carries this fix by hand, for one key
  ## (`"load-calltrace"`) at one handover. This is the same repair made
  ## once, for every key, at the moment that actually defines it: a
  ## backend became reachable, so nothing recorded before now is in
  ## flight.
  ##
  ## THE LOADING FLAG GOES WITH IT. Clearing the tracker alone would let
  ## the next request through but leave `lsLoading` set from the dead one,
  ## so the pane would paint "Loading..." over rows it had already
  ## received. The flag and the tracker entry were set by the same
  ## statement pair (`replay_data_store.nim:710-711`); they are cleared
  ## by the same one.
  ##
  ## Issuing one duplicate request is the acceptable failure here. A
  ## request asked twice is answered twice; a request never asked is
  ## never answered.
  store.requestTracker.clear()
  store.locals.loadingState.val = lsIdle
  # AND THE PREVIOUS RECORDING'S EVENT ROWS GO WITH THEM. All three call sites
  # in `ui_js.nim` run at the moment a backend first becomes reachable for a
  # DIFFERENT trace — two immediately before `DapLaunch`, one on the web path
  # once the replay worker exists — so
  # from this instant every row held here is a row of a recording nobody is
  # looking at any more. `EventLogComponent.clear` covers the desktop's own
  # copy; this covers the store, which is what a second host reads.
  #
  # `pointList` is deliberately NOT cleared. A declared point is a property of
  # the CHECKOUT — `applyCollections` resolves it against source text — and it
  # is still true of the next recording of the same program. Only the sweep
  # results are recording-specific, and the next sweep replaces them whole.
  store.clearEventLog()

proc requestRequestSpansSince*(store: ReplayDataStore) =
  ## Poll for spans committed since the stored cursor.
  ##
  ## The cursor is echoed back untouched.  A zero cursor asks for a
  ## snapshot, which is exactly what the first poll of a session wants.
  ##
  ## The future's value is applied when it carries a delta envelope (the
  ## mock and stdio backends resolve with the real body); in the Electron
  ## renderer the promise resolves with ``{}`` and the body arrives through
  ## the DAP response/event channel handled in
  ## ``installBackendEventHandlers``.  Both paths are idempotent.
  let key = "load-request-spans-since"
  let cursor = store.requestSpans.cursor.val
  if store.requestTracker.isDuplicate(key, $cursor):
    return

  store.requestTracker.markPending(key, $cursor)
  store.requestSpans.loadingState.val = lsLoading

  let fut = store.backend.send(LoadRequestSpansSinceCommand,
                               %*{"cursor": cursor})
  let s = store
  async_compat.onComplete(fut,
    onSuccess = proc(response: JsonNode) =
      s.requestTracker.markComplete(key)
      s.applyRequestSpanDelta(response)
      if s.requestSpans.loadingState.val == lsLoading:
        s.requestSpans.loadingState.val = lsIdle,
    onError = proc(msg: string) =
      s.requestTracker.markComplete(key)
      s.requestSpans.loadingState.val = lsError,
  )

proc installBackendEventHandlers(store: ReplayDataStore) =
  ## Consume backend responses/events that are not mirrored through the
  ## legacy component bridge. Most panel data still arrives through the
  ## existing event-bus subscriptions; live recording-head updates are a
  ## small session-level signal owned directly by the shared store.
  let s = store
  store.backend.onEvent proc(event: JsonNode) =
    if event.kind != JObject or not event.hasKey("kind"):
      return
    let kind = event["kind"].getStr
    case kind
    of "CtMcrGetRecordingHead":
      let payload =
        if event.hasKey("data"): event["data"]
        else: event
      let head = payload.readRRTicks(s.session.val.recordingHeadRRTicks)
      s.updateRecordingHead(head)
    of UpdatedHttpRequestsEventKind, LoadRequestSpansSinceEventKind:
      # RS-M3 — the live Request-panel tail.  The RealBackendService wraps
      # the DAP body under ``data``; the mock backend (and any caller that
      # already holds a bare delta) emits the envelope itself, so fall back
      # to the event node, exactly as the CtMcrGetRecordingHead branch does.
      let payload =
        if event.hasKey("data"): event["data"]
        else: event
      s.applyRequestSpanDelta(payload)
    of ReplayStatusEventKind:
      # Page-Descriptions.md §14. Same envelope convention as the two
      # branches above: RealBackendService nests the body under ``data``,
      # a mock emits the envelope itself.
      let payload =
        if event.hasKey("data"): event["data"]
        else: event
      s.applyReplayStatus(payload)
    else:
      discard

# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

proc createReplayDataStore*(backend: BackendService): ReplayDataStore =
  ## Create the store inside a reactive root.  The root's dispose proc
  ## is stored on the ViewModel base so the caller can tear everything
  ## down with `store.dispose()`.
  withViewModel proc(dispose: proc()): ReplayDataStore =
    inc storeIdCounter
    let assignedId = storeIdCounter
    when defined(js):
      vmDebug "[PIPELINE] createReplayDataStore: creating store id=" & $assignedId
    let store = ReplayDataStore(
      storeId: assignedId,
      # -- top-level state --
      session: createSignal(SessionState(
        connectionStatus: csDisconnected,
      )),
      debugger: createSignal(DebuggerState(
        location: Location(file: "", line: 0, column: 0),
        rrTicks: 0'u64,
        status: dsIdle,
        threadId: 0'u32,
      )),
      currentGeid: createSignal(none(uint64)),
      timeline: createSignal(TimelineState(
        minRRTicks: 0'u64,
        maxRRTicks: 0'u64,
        currentRRTicks: 0'u64,
      )),
      agentSessions: createSignal(AgentSessionsState()),

      # -- calltrace --
      calltrace: CalltraceStore(
        lines: createSignal(newSeq[CallLine]()),
        args: createSignal(initTable[string, seq[CallArg]]()),
        startLineIndex: createSignal(0'i64),
        totalCallsCount: createSignal(0'u64),
        finished: createSignal(false),
        loadingState: createSignal(lsIdle),
      ),

      # -- locals --
      locals: LocalsStore(
        locals: createSignal(newSeq[Variable]()),
        globals: createSignal(newSeq[Variable]()),
        watches: createSignal(newSeq[Variable]()),
        loadingState: createSignal(lsIdle),
        loadedForRRTicks: createSignal(0'u64),
        codeStateLine: createSignal(""),
      ),

      # -- event log --
      eventLog: EventLogStore(
        rows: createSignal(newSeq[EventLogRow]()),
        recordsTotal: createSignal(0),
        recordsFiltered: createSignal(0),
        maxRRTicks: createSignal(0'u64),
        loadedStart: createSignal(0),
        windowSource: createSignal(elwsUnknown),
        loadingState: createSignal(lsIdle),
      ),

      # -- point list + tracepoint sweep results --
      pointList: PointListStore(
        rows: createSignal(newSeq[PointListEntry]()),
        tracepointHits: createSignal(newSeq[TracepointSweepHit]()),
        loadingState: createSignal(lsIdle),
      ),

      # -- HTTP request spans (RS-M3 live tail) --
      requestSpans: RequestSpansStore(
        requests: createSignal(newSeq[RequestRecord]()),
        cursor: createSignal(0'i64),
        source: createSignal(""),
        loadingState: createSignal(lsIdle),
      ),

      # -- degraded state (Page-Descriptions.md §14) --
      #
      # Seeded undegraded, deliberately: a session that has learned
      # nothing yet has not learned that something is wrong. The three
      # states that would justify refusing to open a debugger all arrive
      # from the host or the wire.
      degraded: DegradedStateStore(
        availability: createSignal(raRetained),
        integrity: createSignal(tiComplete),
        capability: createSignal(rcCapable),
        sourceAvailability: createSignal(savVerified),
      ),

      # -- services --
      backend: backend,
      requestTracker: newRequestTracker(),
      disposeProc: dispose,
    )
    store.installBackendEventHandlers()
    store

# ---------------------------------------------------------------------------
# Request procs
# ---------------------------------------------------------------------------

const
  LoadLocalsDefaultLang* = "c"
    ## What ``requestLocals`` sends for ``lang`` when the caller does not know
    ## the language: the wire name of ``LangC``, which is the Rust
    ## ``Lang::default()`` and is what the integer ``0`` this field used to
    ## carry decoded to.  Spelled as a literal here because this module is in
    ## the Embed SDK's package graph and deliberately does not import
    ## ``common_lang`` (see ``FlowTokenLanguage`` in ``flow_layout.nim``);
    ## ``store_test.nim`` pins it against ``langWireName(LangC)`` so the two
    ## cannot drift.

proc requestLocals*(store: ReplayDataStore; rrTicks: uint64;
                    countBudget: int = 3000;
                    minCountLimit: int = 50;
                    depthLimit: int = 7;
                    watchExpressions: seq[string] = @[];
                    lang: string = LoadLocalsDefaultLang) =
  ## Request locals/globals from the backend for the given rrTicks.
  ## Skipped if an identical request is already in flight.
  ##
  ## The backend expects the full ``CtLoadLocalsArguments`` set
  ## (rrTicks, countBudget, minCountLimit, depthLimit,
  ## watchExpressions, lang).  Default values match the legacy
  ## ``loadLocals`` in state.nim so callers that only know the
  ## tick position still produce a valid request.
  ##
  ## ``lang`` is the language's WIRE NAME -- ``langWireName(lang)`` on the Nim
  ## side, ``Lang::wire_name`` on the Rust side, decoded by ``ct-lang``'s
  ## ``lang_wire`` adapter -- never the ``Lang`` ordinal.  Until LRS-1 this
  ## field was ``lang: int = 0`` and the doc here said "the ordinal of the
  ## ``Lang`` enum (matching the Rust backend's ``#[repr(u8)]`` Lang which
  ## uses ``serde_repr``)"; that made the enum's declaration order a wire
  ## contract, and two hand-written senders had already got it wrong
  ## (``gui_ops.rs`` said Cairo = 32 and Solana = 35; the canonical ordinals
  ## were 30 and 36).  A name cannot be off by two.  The receiver refuses a
  ## bare integer, so a caller that still passes one gets an error rather
  ## than a silently wrong language.
  let key = "load-locals"
  # Include watch expressions in the dedup key so that adding a new
  # watch at the same rrTicks position still triggers a fresh request.
  #
  # THE EXPRESSIONS THEMSELVES, not how many there are. Keying on the
  # COUNT made the dedup blind to the most ordinary edit a user makes:
  # replacing one watch with another — remove `total`, add `n` — leaves
  # the count unchanged at the same step, so the request was suppressed
  # and the pane went on showing the answer to an expression that had
  # been deleted.
  let argsStr = $rrTicks & "|" & watchExpressions.join("\x1f")
  if store.requestTracker.isDuplicate(key, argsStr):
    return

  store.requestTracker.markPending(key, argsStr)
  store.locals.loadingState.val = lsLoading

  let args = %*{
    "rrTicks": rrTicks,
    "countBudget": countBudget,
    "minCountLimit": minCountLimit,
    "depthLimit": depthLimit,
    "watchExpressions": watchExpressions,
    "lang": lang,
  }
  let fut = store.backend.send("ct/load-locals", args)

  # In the native (C) backend the future resolves synchronously in
  # tests.  The actual JSON→Variable parsing will be added when the
  # locals panel is converted; for now we just update loading state.
  # The callback mutates reactive signals which are thread-local
  # (not gcsafe), but we are single-threaded so the cast is safe.
  let s = store
  let ticks = rrTicks
  fut.onComplete(
    onSuccess = proc() =
      s.requestTracker.markComplete(key)
      s.locals.loadingState.val = lsIdle
      s.locals.loadedForRRTicks.val = ticks,
    onError = proc() =
      s.requestTracker.markComplete(key)
      s.locals.loadingState.val = lsError,
  )

proc requestCalltraceSection*(store: ReplayDataStore;
                              startIndex: int64;
                              height: int;
                              depth: int;
                              rrTicks: uint64 = 0;
                              file: string = "";
                              line: int = 0;
                              rawIgnorePatterns: string = "";
                              optimizeCollapse: bool = true;
                              autoCollapsing: bool = false;
                              renderCallLineIndex: int = 0) =
  ## Request a window of calltrace lines from the backend.
  ## Skipped if an identical request is already in flight.
  ##
  ## The command name matches the legacy CtLoadCalltraceSection event
  ## ("ct/load-calltrace-section") so that the RealBackendService can
  ## translate it to the correct CtEventKind via dapCommandToEventKind.
  ## The backend responds with CtUpdatedCalltrace which is handled by
  ## the existing event-bus subscription in calltrace.nim.
  let key = "load-calltrace"
  let argsStr = $startIndex & "|" & $height & "|" & $depth & "|" & $rrTicks
  if store.requestTracker.isDuplicate(key, argsStr):
    return

  store.requestTracker.markPending(key, argsStr)
  store.calltrace.loadingState.val = lsLoading

  # Build a location sub-object matching the legacy CalltraceLoadArgs format.
  let args = %*{
    "location": {
      "rrTicks": rrTicks,
      "path": file,
      "line": line,
    },
    "startCallLineIndex": startIndex,
    "height": height,
    "depth": depth,
    "rawIgnorePatterns": rawIgnorePatterns,
    "optimizeCollapse": optimizeCollapse,
    "autoCollapsing": autoCollapsing,
    "renderCallLineIndex": renderCallLineIndex,
  }
  let fut = store.backend.send("ct/load-calltrace-section", args)

  let s = store
  fut.onComplete(
    onSuccess = proc() =
      s.requestTracker.markComplete(key)
      s.calltrace.loadingState.val = lsIdle,
    onError = proc() =
      s.requestTracker.markComplete(key)
      s.calltrace.loadingState.val = lsError,
  )

# ---------------------------------------------------------------------------
# Bridge procs — used by the legacy UI layer to feed data into the store
# without importing store/types (which would cause name conflicts with
# the legacy types).
# ---------------------------------------------------------------------------

proc updateDebuggerPosition*(store: ReplayDataStore;
                             rrTicks: uint64;
                             file: string = "";
                             line: int = 0;
                             geid: Option[uint64] = none(uint64);
                             sourceGeneration: int = 0;
                             sourceDigest: string = "") =
  ## Update the store's debugger signal with a new rrTicks position.
  ## Used by legacy UI code to mirror move events into the ViewModel layer.
  # Always construct and assign a new DebuggerState so the signal fires.
  # DB-based traces have rrTicks=0 for every position, so the old
  # `if current.rrTicks != rrTicks` guard prevented the signal from
  # ever triggering. Deduplication of redundant backend requests is
  # handled by RequestTracker, not here.
  let current = store.debugger.val
  when defined(js):
    vmDebug "[PIPELINE] updateDebuggerPosition: storeId=" &
      $store.storeId & " setting rrTicks=" & $rrTicks & " (was " &
      $current.rrTicks & ") file=" & file & " line=" & $line
  # Construct a NEW object — on JS backend, var = signal.val gets a
  # reference, so mutating and writing back the same object doesn't
  # trigger the signal's equality check (it compares to itself).
  store.debugger.val = DebuggerState(
    rrTicks: rrTicks,
    location: Location(
      file: file,
      line: line,
      sourceGeneration: sourceGeneration,
      sourceDigest: sourceDigest,
    ),
    status: current.status,
    threadId: current.threadId,
  )
  if geid.isSome:
    store.currentGeid.val = geid
  if store.session.val.debugSessionMode in {liveMcr, liveMaterialized} and
      rrTicks > store.session.val.recordingHeadRRTicks:
    store.updateRecordingHead(rrTicks)

proc updateCurrentGeid*(store: ReplayDataStore; geid: Option[uint64]) =
  ## Update the current visual replay GEID independently of rrTicks. MCR
  ## backends can report a graphics event id for the debugger stop even when
  ## the source-level rrTicks position is unchanged or unavailable.
  store.currentGeid.val = geid

proc updateLocals*(store: ReplayDataStore;
                   variables: seq[Variable]) =
  ## Replace the store's locals signal with a new variable list.
  ## Used by legacy UI code to mirror locals responses into the
  ## ViewModel layer.
  when defined(js):
    vmDebug "[PIPELINE] updateLocals: setting " & $variables.len & " variables"
  store.locals.locals.val = variables
  store.locals.loadingState.val = lsIdle

proc updateWatches*(store: ReplayDataStore;
                    watches: seq[Variable]) =
  ## Replace the store's watch-results signal.
  ##
  ## Called from the same response that populates `updateLocals`, because
  ## watches ride the `ct/load-locals` reply. Written UNCONDITIONALLY,
  ## including with an empty seq: a step where a watch stops resolving must
  ## clear the previous step's answer, or the pane keeps showing a stale
  ## value that is no longer true of where the debugger is standing.
  when defined(js):
    vmDebug "[PIPELINE] updateWatches: setting " & $watches.len & " watch result(s)"
  store.locals.watches.val = watches

proc applyLocalsResponse*(store: ReplayDataStore;
                          rows: seq[Variable]) =
  ## Write ONE `ct/load-locals` response into the store, splitting the
  ## watch answers out of the locals.
  ##
  ## THE ONE PLACE THE SPLIT HAPPENS. Watch answers ride this response
  ## (there is no `evaluate` route) and are marked `isWatch` by the
  ## backend, so every host that reads the response has to separate them.
  ## Before this existed each host did it — or failed to — on its own:
  ## the GUI asked for watches and discarded the answers, and the headless
  ## session asked for none at all while exporting `addWatch`. A single
  ## entry point is what stops the next host from inventing a third
  ## behaviour.
  ##
  ## Both signals are written on every response, INCLUDING with an empty
  ## seq: a step where a watch stops resolving must clear the previous
  ## step's answer rather than leave a stale value on screen next to a
  ## position it is no longer true of.
  var locals = newSeq[Variable]()
  var watches = newSeq[Variable]()
  for row in rows:
    if row.isWatch:
      watches.add(row)
    else:
      locals.add(row)
  store.updateLocals(locals)
  store.updateWatches(watches)

# ---------------------------------------------------------------------------
# Event log — one decoder for `ct/event-load`
# ---------------------------------------------------------------------------

func eventKindLabel*(kindId: int; stdout: bool; semanticKind: string): string =
  ## The row's DISPLAY kind, in one place.
  ##
  ## `ProgramEvent` carries two spellings of "what is this row": a numeric
  ## `kind` (`EventLogKind`, `src/db-backend/src/task.rs`) and an optional
  ## `semanticKind` string whose own doc comment says *"Empty means use
  ## `kind`"*. A pane needs a word, so the choice between them has to be made
  ## somewhere; making it here is what stops the terminal and the desktop from
  ## choosing differently for the same recorded event.
  ##
  ## `kindId` is deliberately NOT turned into an enum name. The numeric value
  ## is kept verbatim on `EventLogRow.kindId` and the terminal's
  ## `categoryFor(kindId, stdout)` classifies from it, so a value this
  ## function has never heard of stays visible as a number rather than being
  ## flattened into a plausible-looking label.
  if semanticKind.len > 0: semanticKind
  elif stdout: "stdout"
  else: "event"

func isNumber(node: JsonNode): bool =
  ## A JSON number in either of the two shapes `std/json` produces.
  ##
  ## `JFloat` is not hypothetical here: the Electron renderer hands this layer
  ## objects that went through `JSON.parse`, where every number is a double,
  ## and `getInt` answers its DEFAULT on a `JFloat` rather than truncating —
  ## so a check that tested only `JInt` would silently read 0 for a line number
  ## that was present.
  (not node.isNil) and node.kind in {JInt, JFloat}

func asInt(node: JsonNode): int =
  ## A JSON number as an `int`, whichever shape it arrived in.
  if node.isNil: 0
  elif node.kind == JInt: node.getInt(0)
  elif node.kind == JFloat: int(node.getFloat(0.0))
  else: 0

func firstTicks(node: JsonNode; names: varargs[string]): uint64 =
  ## The first of `names` this object carries as a number, as a tick count.
  ##
  ## `BiggestInt` rather than `int` because a tick is a 64-bit quantity and
  ## this module compiles for the JS backend too, where `int` is not one.
  ## Negative is clamped to 0: `directLocationRRTicks` is an `i64` on the wire
  ## and -1 is how some producers spell "no position".
  if node.isNil or node.kind != JObject:
    return 0'u64
  for name in names:
    let child = node.getOrDefault(name)
    if child.isNil:
      continue
    if child.kind == JInt:
      let raw = child.getBiggestInt(0)
      return if raw > 0: uint64(raw) else: 0'u64
    if child.kind == JFloat:
      let raw = child.getFloat(0.0)
      return if raw > 0.0: uint64(raw) else: 0'u64
  0'u64

func firstInt(node: JsonNode; names: varargs[string]): int =
  ## The first of `names` this object carries as a number, or 0.
  ##
  ## The wire has BOTH spellings in circulation: `ProgramEvent` serialises
  ## camelCase (`#[serde(rename_all(serialize = "camelCase"))]`) while the
  ## legacy echo path and several fixtures carry snake_case. Reading one and
  ## silently defaulting the other is how `line` came to be 0 on a payload
  ## that had it.
  if node.isNil or node.kind != JObject:
    return 0
  for name in names:
    let child = node.getOrDefault(name)
    if child.isNumber:
      return child.asInt
  0

func firstStr(node: JsonNode; names: varargs[string]): string =
  ## `firstInt` for strings.
  if node.isNil or node.kind != JObject:
    return ""
  for name in names:
    let child = node.getOrDefault(name)
    if not child.isNil and child.kind == JString and child.getStr("").len > 0:
      return child.getStr("")
  ""

proc eventLogRowFromJson*(node: JsonNode; positionIndex: int): EventLogRow =
  ## ONE `ProgramEvent` off the wire as ONE `EventLogRow`.
  ##
  ## THE ONE PLACE THE `ct/event-load` WIRE SHAPE IS READ. Three front-ends
  ## used to do this independently — the terminal built `EventRow`s in
  ## `tui/host/tui_session.nim`, the desktop built `ProgramEvent`s in
  ## `ui/event_log.nim`, and `headless_session` built a third shape for its
  ## callers — which is three chances to disagree about which key holds the
  ## line number and what an absent `semanticKind` means.
  ##
  ## `positionIndex` is the row's absolute position in the log (the request's
  ## `start` plus its offset in the page) and is used only when the payload
  ## omits `eventIndex`. It is not a substitute for the wire's value: a page
  ## fetched at `start = 40` has page-local offsets 0..n and absolute indices
  ## 40..n+40, and the cursor of every pane is in the absolute coordinate.
  result = EventLogRow()
  if node.isNil or node.kind != JObject:
    return
  result.value = node.getOrDefault("content").getStr("")
  result.file = firstStr(node, "highLevelPath", "high_level_path")
  result.line = firstInt(node, "highLevelLine", "high_level_line")
  result.rrTicks = firstTicks(node, "directLocationRRTicks",
                              "direct_location_rr_ticks")
  result.sourceGeneration = firstInt(node, "sourceGeneration",
                                     "source_generation")
  result.sourceDigest = firstStr(node, "sourceDigest", "source_digest")
  result.kindId = node.getOrDefault("kind").asInt
  result.stdout = node.getOrDefault("stdout").getBool(false)
  result.kind = eventKindLabel(result.kindId, result.stdout,
                               firstStr(node, "semanticKind", "semantic_kind"))
  let wireIndex = node.getOrDefault("eventIndex")
  let snakeIndex = node.getOrDefault("event_index")
  result.eventIndex =
    if wireIndex.isNumber: wireIndex.asInt
    elif snakeIndex.isNumber: snakeIndex.asInt
    else: positionIndex
  result.maxRRTicks = firstTicks(node, "maxRRTicks", "max_rr_ticks")
  # `rrEventId` is the recorder's own id for the event and is what the jump
  # payload echoes back; it is absent on some producers, and the tick is the
  # next best stable identity. Falling back to the POSITION would make two
  # different events in two different pages share an id.
  let rrEventId = firstInt(node, "rrEventId", "rr_event_id")
  result.eventId =
    if rrEventId > 0: uint64(rrEventId)
    elif result.rrTicks > 0'u64: result.rrTicks
    else: uint64(result.eventIndex + 1)

proc eventLogRowsFromJson*(payload: JsonNode; start: int = 0): seq[EventLogRow] =
  ## Every row of a `ct/event-load` answer, tolerant of the three envelopes
  ## this payload arrives in: the full DAP response (`{"body": {"events": …}}`),
  ## the response body alone (`{"events": …}`), and the bare array the
  ## `ct/updated-events` event carries.
  result = @[]
  if payload.isNil:
    return
  var eventsNode: JsonNode = nil
  if payload.kind == JArray:
    eventsNode = payload
  elif payload.kind == JObject:
    let body = payload.getOrDefault("body")
    let container =
      if not body.isNil and body.kind == JObject and body.hasKey("events"):
        body
      else:
        payload
    let events = container.getOrDefault("events")
    if not events.isNil and events.kind == JArray:
      eventsNode = events
  if eventsNode.isNil:
    return
  for i in 0 ..< eventsNode.len:
    result.add eventLogRowFromJson(eventsNode[i], start + i)

# ---------------------------------------------------------------------------
# `ct/update-table` — the OTHER wire shape the same events arrive in
#
# `EventDb::update_table` (src/db-backend/src/event_db.rs) answers with
# `TableRow`s, which `TableRow::new(&ProgramEvent)` derives from exactly the
# events `ct/event-load` serialises whole. The shape differs in three ways and
# only three, so the mapping below is short and total:
#
#   * the location is pre-joined into `fullPath` (`"<basename>:<line>"`) with
#     the unjoined path repeated in `lowLevelLocation`;
#   * `maxRRTicks` and `eventIndex` are NOT on the row — a paged answer knows
#     neither the recording's extent nor the absolute position of the slice it
#     was asked for, so both are supplied by the caller, which does;
#   * `bytes` and `tracepointResultIndex` are dropped by the backend before the
#     row is built, which is the first piece of evidence that neither belongs
#     on a shared row.
#
# WHY THIS IS GENERIC AND NOT TYPED AGAINST `TableRow`. There is no one
# `TableRow` type to be typed against: `common_types/codetracer_features/
# events.nim` is INCLUDED into two hosts that bind `langstring` differently —
# `common/types.nim` (`string`) and `frontend/types.nim` (`cstring`) — so the
# native and the renderer builds hold two unrelated Nim types with the same
# field names. A generic proc is one decoder that both instantiate, which is
# what keeps this store free of a `dom`-reaching import while still refusing to
# let a second copy of this mapping exist.
# ---------------------------------------------------------------------------

func tableRowSourceLine*[R](row: R): int =
  ## The line `TableRow.fullPath` carries after its final `:`.
  ##
  ## `TableRow::new` builds `fullPath` as `"<basename>:<high_level_line>"`, so
  ## the line is recoverable and nothing else on the row carries it. A path
  ## with no `:`, or a trailing `:` with nothing after it, yields 0 — the same
  ## "no line" this layer uses everywhere else, and a row a pane must not offer
  ## as a jump target.
  let fullPath = $row.fullPath
  let colon = fullPath.rfind(":")
  if colon < 0 or colon >= fullPath.len - 1:
    return 0
  try:
    fullPath[colon + 1 .. ^1].parseInt
  except ValueError:
    0

func tableRowSourcePath*[R](row: R): string =
  ## The row's source path.
  ##
  ## `lowLevelLocation` holds `ProgramEvent.high_level_path` verbatim and is
  ## preferred for that reason; `fullPath`'s prefix is only a BASENAME and is
  ## the fallback for a producer that left `lowLevelLocation` empty.
  let lowLevel = $row.lowLevelLocation
  if lowLevel.len > 0:
    return lowLevel
  let fullPath = $row.fullPath
  let colon = fullPath.rfind(":")
  if colon > 0: fullPath[0 ..< colon] else: fullPath

func eventLogRowFromTableRow*[R](row: R; absoluteIndex: int;
                                 maxRRTicks: int64 = 0): EventLogRow =
  ## ONE `ct/update-table` row as ONE `EventLogRow`.
  ##
  ## THE ONE PLACE THE TABLE WIRE SHAPE IS READ, the way
  ## `eventLogRowFromJson` is the one place the `ct/event-load` shape is. The
  ## desktop used to read it twice over: `programEventFromTableRow` built a
  ## legacy `ProgramEvent` for DataTables and `storeRowOf` then built a second
  ## row out of that for the store, so the rows a user looked at and the rows a
  ## second host read were two conversions that could drift apart. They are one
  ## conversion now, and the desktop's own `ProgramEvent` is projected back OUT
  ## of this row (`ui/event_log.nim:programEventOf`).
  ##
  ## `absoluteIndex` is the row's position in the WHOLE log — the request's
  ## `start` plus its offset in the page. The row carries no index of its own
  ## (see the header above), so unlike `eventLogRowFromJson` there is nothing
  ## to prefer over it; every cursor in every pane is in this coordinate.
  ##
  ## `maxRRTicks` likewise comes from the caller, which learns the recording's
  ## extent from the `ct/updated-events` echo. 0 means "not known here", and
  ## `applyEventLogRows` only ever raises the store's own high-water mark, so
  ## an unknown extent cannot lower one that is known.
  let ticks = row.directLocationRRTicks
  let rrEventId = row.rrEventId
  result = EventLogRow(
    eventId:
      if rrEventId > 0: uint64(rrEventId)
      elif ticks > 0: uint64(ticks)
      else: uint64(absoluteIndex + 1),
    eventIndex: absoluteIndex,
    kindId: ord(row.kind),
    kind: eventKindLabel(ord(row.kind), row.stdout, $row.semanticKind),
    file: tableRowSourcePath(row),
    line: tableRowSourceLine(row),
    value: $row.content,
    rrTicks: if ticks > 0: uint64(ticks) else: 0'u64,
    maxRRTicks: if maxRRTicks > 0: uint64(maxRRTicks) else: 0'u64,
    sourceGeneration: row.sourceGeneration,
    sourceDigest: $row.sourceDigest,
    stdout: row.stdout,
  )

func eventLogRowsFromTableRows*[R](rows: seq[R]; start: int = 0;
                                   maxRRTicks: int64 = 0): seq[EventLogRow] =
  ## One `ct/update-table` window as store rows, absolute indices assigned
  ## from `start` — which is the `TableArgs.start` the request asked for.
  result = newSeqOfCap[EventLogRow](rows.len)
  for i, row in rows:
    result.add eventLogRowFromTableRow(row, start + i, maxRRTicks)

func eventLogRowFromProgramEvent*[E](event: E;
                                     positionIndex: int): EventLogRow =
  ## ONE already-deserialised `ProgramEvent` as ONE `EventLogRow`.
  ##
  ## The typed sibling of `eventLogRowFromJson`, for the host that receives
  ## `ct/updated-events` through a typed event bus rather than as raw JSON —
  ## which is every renderer build. It is the SAME mapping, expressed over
  ## fields instead of over keys, and generic for the reason
  ## `eventLogRowFromTableRow` is: `ProgramEvent` is two unrelated Nim types
  ## depending on which host included `codetracer_features/events.nim`.
  ##
  ## `positionIndex` is used only when the event carries no `eventIndex` of its
  ## own; the wire's value wins, exactly as in `eventLogRowFromJson`, because a
  ## page fetched at `start = 40` has page-local offsets and absolute indices
  ## and every pane's cursor is in the absolute one.
  let ticks = event.directLocationRRTicks
  let rrEventId = event.rrEventId
  result = EventLogRow(
    eventId:
      if rrEventId > 0: uint64(rrEventId)
      elif ticks > 0: uint64(ticks)
      else: uint64(positionIndex + 1),
    eventIndex: if event.eventIndex > 0: event.eventIndex else: positionIndex,
    kindId: ord(event.kind),
    kind: eventKindLabel(ord(event.kind), event.stdout, $event.semanticKind),
    file: $event.highLevelPath,
    line: event.highLevelLine,
    value: $event.content,
    rrTicks: if ticks > 0: uint64(ticks) else: 0'u64,
    maxRRTicks: if event.maxRRTicks > 0: uint64(event.maxRRTicks) else: 0'u64,
    sourceGeneration: event.sourceGeneration,
    sourceDigest: $event.sourceDigest,
    stdout: event.stdout,
  )

proc applyEventLogRows*(store: ReplayDataStore;
                        rows: seq[EventLogRow];
                        start: int = 0;
                        recordsTotal: int = -1;
                        recordsFiltered: int = -1;
                        source: EventLogWindowSource = elwsUnknown) =
  ## Write ONE window of already-decoded event rows into the store.
  ##
  ## THE ONE PLACE EVERY PRODUCER ENDS. `applyEventLogResponse` decodes the
  ## wire and calls this; the desktop's DataTables path, whose rows arrive
  ## through `ct/update-table` in a different shape entirely, converts once and
  ## calls this; the live debugger head appends through `appendLiveEventRow`,
  ## which is this with one row.
  ##
  ## `recordsTotal` / `recordsFiltered` default to -1 meaning "the producer does
  ## not know", in which case the totals are raised to at least what this window
  ## implies and never lowered. A producer that DOES know (the desktop's table
  ## update carries the engine's own count) passes it and it is taken verbatim,
  ## including downwards — a filter that matched fewer rows has to be able to
  ## say so.
  ##
  ## `source` says WHICH ROUTE this window came from and decides one thing: an
  ## `elwsEventLoad` window does not replace an `elwsTable` one. See
  ## `EventLogWindowSource` for the whole rule and the reason. Everything below
  ## the rows — the totals, the recording's extent, the loading flag — is
  ## applied either way, because those are facts about the recording rather
  ## than about which slice of it is on screen.
  let yieldsToTableWindow =
    source == elwsEventLoad and
    store.eventLog.windowSource.val == elwsTable
  if not yieldsToTableWindow:
    store.eventLog.rows.val = rows
    store.eventLog.loadedStart.val = start
    if source != elwsUnknown:
      store.eventLog.windowSource.val = source
  if recordsTotal >= 0:
    store.eventLog.recordsTotal.val = recordsTotal
  else:
    store.eventLog.recordsTotal.val =
      max(store.eventLog.recordsTotal.val, start + rows.len)
  if recordsFiltered >= 0:
    store.eventLog.recordsFiltered.val = recordsFiltered
  elif not yieldsToTableWindow:
    # ONLY when this producer owns the window. `recordsFiltered` equals
    # `recordsTotal` for a producer that filters nothing, which is true of
    # `ct/event-load` and false of the table route — so letting an event-load
    # answer infer it here would erase the smaller count a live search had
    # just established and put the pane's footer back to "of <everything>"
    # while it is showing a filtered page.
    store.eventLog.recordsFiltered.val = store.eventLog.recordsTotal.val
  var maxTicks = store.eventLog.maxRRTicks.val
  for row in rows:
    if row.maxRRTicks > maxTicks:
      maxTicks = row.maxRRTicks
  store.eventLog.maxRRTicks.val = maxTicks
  # THE TIMELINE'S EXTENT FOLLOWS WHAT THE LOG LEARNS (PLAT-41). The
  # recording's extent is one fact, and for a completed recording the event
  # log's `maxRRTicks` is where every front-end learns it; the timeline's own
  # copy was raised only by LIVE recording-head updates, so on a replay the
  # native timeline drew `tick 4 / 0`. Raised, never lowered — as the log's.
  if maxTicks > store.timeline.val.maxRRTicks:
    var timeline = store.timeline.val
    timeline.maxRRTicks = maxTicks
    store.timeline.val = timeline
  store.eventLog.loadingState.val = lsIdle

proc applyEventLogResponse*(store: ReplayDataStore;
                            payload: JsonNode;
                            start: int = 0) =
  ## Write ONE `ct/event-load` answer into the store.
  ##
  ## THE `applyLocalsResponse` OF THE EVENT LOG, and it exists for the same
  ## reason: *"A single entry point is what stops the next host from inventing
  ## a third behaviour."* Before it, `requestAndLoadEventLog` returned a
  ## sequence and each caller converted it — the terminal into `EventRow`, the
  ## desktop into `ProgramEvent`, and a cross-renderer suite into
  ## `EventLogRow` by hand through a door meant for the live debugger stop.
  ##
  ## A payload with no `events` array leaves the store ALONE rather than
  ## clearing it. "The answer had no events" and "the answer was not an event
  ## load" are different facts and only one of them means the log is empty; the
  ## marker-only answers `EventLogVM`'s own effect routes through here are the
  ## second kind.
  if payload.isNil:
    return
  var hasEvents = false
  if payload.kind == JArray:
    hasEvents = true
  elif payload.kind == JObject:
    let body = payload.getOrDefault("body")
    hasEvents = payload.hasKey("events") or
      (not body.isNil and body.kind == JObject and body.hasKey("events"))
  if not hasEvents:
    return
  store.applyEventLogRows(eventLogRowsFromJson(payload, start), start,
                          source = elwsEventLoad)

proc appendLiveEventRow*(store: ReplayDataStore; row: EventLogRow): bool =
  ## Append one live debugger-stop row, and say whether it was new.
  ##
  ## Persisted event rows come from the backend through
  ## `applyEventLogResponse`; this covers the live debugger head, where each
  ## stop is visible immediately and may later be mirrored by a backend event
  ## load. The duplicate test is the identity the live producer can supply —
  ## `(eventId, kind, sourceGeneration, sourceDigest)` — because a live stop
  ## has no `eventIndex` of its own until it is appended.
  var rows = store.eventLog.rows.val
  for existing in rows:
    if existing.eventId == row.eventId and
       existing.kind == row.kind and
       existing.sourceGeneration == row.sourceGeneration and
       existing.sourceDigest == row.sourceDigest:
      return false
  var nextRow = row
  nextRow.eventIndex = store.eventLog.loadedStart.val + rows.len
  rows.add(nextRow)
  store.applyEventLogRows(rows, store.eventLog.loadedStart.val)
  true

proc clearEventLog*(store: ReplayDataStore) =
  ## Drop every row and every count. Used when a session restarts, so a new
  ## recording cannot inherit the previous one's log.
  store.eventLog.rows.val = @[]
  store.eventLog.recordsTotal.val = 0
  store.eventLog.recordsFiltered.val = 0
  store.eventLog.maxRRTicks.val = 0'u64
  store.eventLog.loadedStart.val = 0
  # AND THE WINDOW'S OWNER. A restart that left `elwsTable` behind would make
  # the store refuse the next `ct/event-load` window for a table that no longer
  # has any rows — the log would stay empty for every store consumer until the
  # new session's first `ct/update-table` reply happened to land.
  store.eventLog.windowSource.val = elwsUnknown
  store.eventLog.loadingState.val = lsIdle

# ---------------------------------------------------------------------------
# Point list + tracepoint sweeps
# ---------------------------------------------------------------------------

proc applyPointRows*(store: ReplayDataStore; rows: seq[PointListEntry]) =
  ## Replace the declared point rows.
  ##
  ## The definition-side producer (`point_collection_source.applyCollections`)
  ## ends here, as does `PointListVM.setPoints`. Written unconditionally,
  ## including with an empty seq: disabling every collection has to be able to
  ## empty the pane.
  store.pointList.rows.val = rows
  store.pointList.loadingState.val = lsIdle

proc applyVerifiedBreakpoints*(store: ReplayDataStore; path: string;
                               verifiedLines: openArray[int]) =
  ## Replace `path`'s breakpoint rows with the lines the ENGINE verified.
  ##
  ## **THE ONE DECODER OF BREAKPOINT ROWS** (PLAT-40), on every runtime: the
  ## native front-ends reach it through `HeadlessDebugSession.toggleBreakpoint`
  ## and Electron through its debugger service's `setBreakpoints` answer, so a
  ## breakpoint is on the point list because the engine bound it, whichever
  ## front-end asked. The lines are the engine's — a breakpoint binds to a
  ## recorded step, which need not be the line asked for — and a line below 1
  ## is not a place and is dropped. Rows of other kinds and other files are
  ## untouched; `path`'s breakpoint set is replaced whole, as DAP's
  ## `setBreakpoints` replaces it.
  var rows: seq[PointListEntry] = @[]
  for r in store.pointList.rows.val:
    if not (r.kind == PointKindBreakpoint and r.path == path):
      rows.add r
  for line in verifiedLines:
    if line >= 1:
      var name = path
      let slash = max(path.rfind('/'), path.rfind('\\'))
      if slash >= 0: name = path[slash + 1 .. ^1]
      rows.add PointListEntry(kind: PointKindBreakpoint,
                              label: name & ":" & $line, path: path,
                              line: line, enabled: true,
                              resolution: "verified")
  store.applyPointRows(rows)

proc tracepointSweepRequest*(specs: openArray[TracepointSweepSpec];
                             stopAfter = -1): JsonNode =
  ## The ``ct/run-tracepoints`` arguments for ``specs``: THE ONE PLACE THE
  ## WIRE SHAPE OF A ``Tracepoint`` IS SPELLED on this side, so that a
  ## reader of the Rust ``task::Tracepoint`` has exactly one Nim builder to
  ## hold it against.  ``headless_session.runTracepoints`` sends this
  ## verbatim; ``store_test.nim`` pins the key set.
  ##
  ## Every key is one the Rust struct declares.  There is NO ``lang`` key --
  ## since LRS-1 neither side has the field.  Until then a ``Lang`` ORDINAL
  ## was sent here (``spec.lang``, ``TracepointSweepSpec.lang: int``) because
  ## the Rust struct required the key, while the engine never read it; it was
  ## measured dead on ``calc`` (12 and 21 answered identically) and deleted on
  ## both sides rather than moved to a name.
  var tracepoints = newJArray()
  for spec in specs:
    tracepoints.add %*{
      "tracepointId": spec.tracepointId,
      "mode": 0,
      "line": spec.line,
      "offset": 0,
      "name": spec.path,
      "expression": spec.expression,
      "lastRender": 0,
      "isDisabled": false,
      "isChanged": true,
      "results": newJArray(),
      "tracepointError": "",
    }
  %*{
    "session": {
      "tracepoints": tracepoints,
      "found": newJArray(),
      "lastCount": 0,
      "results": newJObject(),
      "id": 0,
    },
    "stopAfter": stopAfter,
  }

proc applyTracepointResults*(store: ReplayDataStore;
                             specs: seq[TracepointSweepSpec];
                             hits: seq[TracepointSweepHit]) =
  ## Write ONE `ct/tracepoint-results` answer into the store.
  ##
  ## THE ONE PLACE A SWEEP BECOMES DATA, and it produces two things because the
  ## answer is two things:
  ##
  ##   * `tracepointHits` — every `Stop`, with its tick, its location and the
  ##     locals the expression named. This is what a timeline draws diamonds
  ##     from and what a trace pane lists.
  ##   * `pointList.rows` — one row per SPEC, because the sweep is also the
  ##     engine's answer to "where is this tracepoint and did it fire". A spec
  ##     with hits resolves to the location the ENGINE reported (which is the
  ##     authority — an anchor resolved against source text is a guess until
  ##     the engine agrees); a spec with none keeps the location it asked for
  ##     and says it found nothing.
  ##
  ## MERGED BY `(path, line)` RATHER THAN REPLACING. `applyCollections` is the
  ## other producer of these rows and it names points a sweep may not have run,
  ## so replacing would delete them. A spec that matches an existing row
  ## annotates it in place, which is what lets a pane show a declared
  ## collection and the engine's verdict on it as one list.
  store.pointList.tracepointHits.val = hits

  var hitCounts: seq[int] = @[]
  var hitLines: seq[int] = @[]
  var hitPaths: seq[string] = @[]
  var errors: seq[string] = @[]
  for _ in specs:
    hitCounts.add 0
    hitLines.add 0
    hitPaths.add ""
    errors.add ""
  for hit in hits:
    for i, spec in specs:
      # `tracepointId` is the engine's echo of what the request supplied, so it
      # is the identity to match on. A hit whose id names no spec is still in
      # `tracepointHits`; it just annotates no row.
      if spec.tracepointId == hit.tracepointId:
        inc hitCounts[i]
        if hitLines[i] == 0:
          hitLines[i] = hit.line
          hitPaths[i] = hit.path
        if errors[i].len == 0 and hit.errorMessage.len > 0:
          errors[i] = hit.errorMessage
        break

  var rows = store.pointList.rows.val
  for i, spec in specs:
    let located = hitCounts[i] > 0
    let path = if located and hitPaths[i].len > 0: hitPaths[i] else: spec.path
    let line = if located and hitLines[i] > 0: hitLines[i] else: spec.line
    let resolution =
      if errors[i].len > 0: "swept, errored"
      elif located: "swept"
      else: "swept, no hits"
    let detail =
      if errors[i].len > 0: errors[i]
      elif located: $hitCounts[i] & " hit(s)"
      else: "the sweep reached this line no times"
    var replaced = false
    for j in 0 ..< rows.len:
      if rows[j].path == spec.path and rows[j].line == spec.line and
         rows[j].line != 0:
        rows[j].line = line
        rows[j].path = path
        rows[j].resolution = resolution
        rows[j].detail = detail
        replaced = true
        break
    if not replaced:
      rows.add PointListEntry(
        kind: PointKindTracepoint,
        label: (if spec.expression.len > 0: spec.expression
                else: "tracepoint " & $spec.tracepointId),
        path: path,
        # 0 when the sweep found nothing and the request named no line: a row
        # whose line is 0 is a row a pane must not offer as a jump target, and
        # inventing one here would be the silent mislocation `rowOf`'s own
        # comment refuses.
        line: line,
        enabled: true,
        collection: "",
        resolution: resolution,
        detail: detail)
  store.pointList.rows.val = rows
  store.pointList.loadingState.val = lsIdle

proc updateCodeStateLine*(store: ReplayDataStore;
                          line: int;
                          sourceCode: string) =
  ## Update the formatted "<line> | <sourceCode>" string displayed above
  ## the variables list. Empty ``sourceCode`` means "no source available
  ## yet" — callers pass it that way when the editor for the current
  ## file has not loaded its source lines yet, or when the trace's
  ## position is on a synthetic location with no source mapping.
  ## The IsoNim state view reads this signal to decide between the
  ## populated ``code-state-line`` markup and the ``no-code`` fallback.
  let formatted =
    if sourceCode.len == 0: ""
    else: $line & CodeStateLineSeparator & sourceCode
  when defined(js):
    vmDebug "[PIPELINE] updateCodeStateLine: storeId=" &
      $store.storeId & " line=" & $line & " has_source=" &
      $(sourceCode.len > 0)
  store.locals.codeStateLine.val = formatted

proc makeVariable*(name, value, typeName: string;
                   hasChildren: bool = false;
                   children: seq[Variable] = @[];
                   isWatch: bool = false): Variable =
  ## Convenience constructor for Variable — avoids the need for callers
  ## to import store/types.
  Variable(name: name, value: value, typeName: typeName,
           hasChildren: hasChildren, children: children, isWatch: isWatch)

proc newVariableSeq*(): seq[Variable] =
  ## Create an empty seq of store Variables. Useful for callers that
  ## cannot name the Variable type due to import conflicts.
  newSeq[Variable]()

proc updateCalltraceSection*(store: ReplayDataStore;
                             lines: seq[CallLine];
                             startIndex: int64;
                             totalCount: uint64;
                             args: Table[string, seq[CallArg]] =
                                 initTable[string, seq[CallArg]]()) =
  ## Replace the store's calltrace signals with new section data.
  ## Used by legacy UI code to mirror calltrace responses into the
  ## ViewModel layer.
  ##
  ## ``args`` holds per-call argument values keyed by ``CallLine.callKey``.
  ## When omitted, the args signal is left untouched so callers that only
  ## know about lines (the legacy headless tests) still work; callers that
  ## carry args (notably ``syncCalltraceData`` in
  ## ``frontend/ui/calltrace.nim``) pass the parsed map alongside lines.
  when defined(js):
    vmDebug "[PIPELINE] updateCalltraceSection: storeId=" &
      $store.storeId & " setting " & $lines.len & " lines (was " &
      $store.calltrace.lines.val.len & "), startIndex=" & $startIndex &
      " totalCount=" & $totalCount
  store.calltrace.lines.val = lines
  # Replace args atomically with the new section's args.  If the caller
  # didn't supply any (the VM tests that only know about lines), the
  # existing args are cleared so stale entries from a prior section
  # don't bleed into the freshly loaded rows.
  store.calltrace.args.val = args
  store.calltrace.startLineIndex.val = startIndex
  store.calltrace.totalCallsCount.val = totalCount
  store.calltrace.loadingState.val = lsIdle

proc updateCalltraceArgs*(store: ReplayDataStore;
                          args: Table[string, seq[CallArg]]) =
  ## Replace the store's per-call argument map. Separate from
  ## ``updateCalltraceSection`` for callers that already have lines but
  ## want to feed args separately (e.g. when args arrive on a follow-up
  ## response). The signal is set unconditionally so empty maps overwrite
  ## stale data on a fresh navigation.
  store.calltrace.args.val = args

proc makeCallArg*(name, text: string): CallArg =
  ## Convenience constructor for the ViewModel ``CallArg``. Mirrors the
  ## ``makeCallLine`` helper above so callers in ``frontend/ui`` don't
  ## have to import ``store/types`` directly (which would clash with the
  ## legacy ``CallArg`` ref-object name).
  CallArg(name: name, text: text)

proc makeCallLine*(name: string; depth: int; rrTicks: uint64;
                   file: string = ""; line: int = 0;
                   sourceGeneration: int = 0;
                   sourceDigest: string = "";
                   codeGeneration: int = 0;
                   callstackDepth: int = 0;
                   hasChildren: bool = false; isExpanded: bool = false;
                   callKey: string = ""): CallLine =
  ## Convenience constructor for CallLine — avoids the need for callers
  ## to import store/types.
  CallLine(
    index: 0,
    name: name,
    depth: depth,
    rrTicks: rrTicks,
    location: Location(
      file: file,
      line: line,
      sourceGeneration: sourceGeneration,
      sourceDigest: sourceDigest,
      callstackDepth: callstackDepth),
    codeGeneration: codeGeneration,
    hasChildren: hasChildren,
    isExpanded: isExpanded,
    callKey: callKey,
  )

# ---------------------------------------------------------------------------
# The calltrace decoder — ONE policy for what a `callLines[]` entry becomes
# ---------------------------------------------------------------------------

type
  CallLineWire* = object
    ## **One `callLines[]` entry of `ct/load-calltrace-section`, reduced to
    ## the fields a calltrace row is made of.** Both decoders fill this — the
    ## native front-ends from the response's JSON (`callLineWireOf`), the
    ## desktop from its typed `CtUpdatedCalltraceResponseBody`
    ## (`ui/calltrace.syncCalltraceData`) — and `callLineOf` alone decides
    ## what the row says.
    ##
    ## PLAT-40 found the two decoders disagreeing: the native one named a row
    ## by the call's `rawName` and located it at the LOW-level `path`/`line`,
    ## never set `hasChildren`, `isExpanded` or `callKey`; the desktop named it
    ## by `highLevelFunctionName` at the high-level location. The same
    ## recording's call trace read differently on the terminal and on the
    ## desktop, and both panes were internally consistent about it.
    rawName*, highLevelFunctionName*: string
    path*, highLevelPath*: string
    line*, highLevelLine*: int
    rrTicks*: uint64
    depth*: int
    sourceGeneration*: int
    sourceDigest*: string
    callstackDepth*: int
    count*: int
      ## `content.count` — the backend's child count for the line.
    hiddenChildren*: bool
      ## `content.hiddenChildren`.
    loadedChildren*: int
      ## `content.call.children.len` — children the section already carries.
    callKey*: string

proc callLineOf*(w: CallLineWire; globalIndex: int64): CallLine =
  ## **What a calltrace row IS**, for every front-end.
  ##
  ## Named by the high-level function name, located at the high-level path and
  ## line: the language's own view of the call, the one the editor shows. The
  ## raw name and low-level location are the fallback for a recorder that
  ## leaves the high-level fields empty, so a row is never nameless while the
  ## backend sent a name.
  ##
  ## A line HAS children when the backend counts any or the section carries
  ## some; it is shown EXPANDED when it has children that are not hidden, or
  ## when its children are loaded — the legacy call-line semantics the IsoNim
  ## calltrace view mirrors.
  let children = if w.count > 0: w.count else: w.loadedChildren
  let hasChildren = children > 0
  let name =
    if w.highLevelFunctionName.len > 0: w.highLevelFunctionName else: w.rawName
  let (file, line) =
    if w.highLevelPath.len > 0: (w.highLevelPath, w.highLevelLine)
    else: (w.path, w.line)
  result = makeCallLine(
    name = name, depth = w.depth, rrTicks = w.rrTicks, file = file,
    line = line, sourceGeneration = w.sourceGeneration,
    sourceDigest = w.sourceDigest, codeGeneration = w.sourceGeneration,
    callstackDepth = w.callstackDepth, hasChildren = hasChildren,
    isExpanded = hasChildren and (not w.hiddenChildren or w.loadedChildren > 0),
    callKey = w.callKey)
  result.index = globalIndex

proc callLineWireOf*(entry: JsonNode): Option[CallLineWire] =
  ## One `callLines[]` entry of the JSON response, or `none` when it carries
  ## no call (the desktop's decoder skips such an entry, and so does this).
  if entry.isNil or entry.kind != JObject: return none(CallLineWire)
  let content = entry.getOrDefault("content")
  if content.isNil or content.kind != JObject: return none(CallLineWire)
  let call = content.getOrDefault("call")
  if call.isNil or call.kind != JObject: return none(CallLineWire)
  var w = CallLineWire(
    rawName: call.getOrDefault("rawName").getStr(""),
    depth: entry.getOrDefault("depth").getInt(0),
    count: content.getOrDefault("count").getInt(0),
    hiddenChildren: content.getOrDefault("hiddenChildren").getBool(false),
    callKey: call.getOrDefault("key").getStr(""))
  let children = call.getOrDefault("children")
  if not children.isNil and children.kind == JArray:
    w.loadedChildren = children.len
  let loc = call.getOrDefault("location")
  if not loc.isNil and loc.kind == JObject:
    w.path = loc.getOrDefault("path").getStr("")
    w.line = loc.getOrDefault("line").getInt(0)
    w.highLevelPath = loc.getOrDefault("highLevelPath").getStr("")
    w.highLevelLine = loc.getOrDefault("highLevelLine").getInt(0)
    w.highLevelFunctionName =
      loc.getOrDefault("highLevelFunctionName").getStr("")
    w.rrTicks = loc.getOrDefault("rrTicks").getBiggestInt(0).uint64
    w.sourceGeneration = loc.getOrDefault("sourceGeneration").getInt(0)
    w.sourceDigest = loc.getOrDefault("sourceDigest").getStr("")
    w.callstackDepth = loc.getOrDefault("callstackDepth").getInt(0)
  some(w)

proc applyCalltraceResponse*(store: ReplayDataStore; body: JsonNode): int =
  ## Decode a `ct/load-calltrace-section` response body into the store.
  ## Answers the number of rows written, or `-1` when the body is not a
  ## calltrace section (the store is then left ALONE, as
  ## `applyEventLogResponse` leaves it for a payload with no events).
  if body.isNil or body.kind != JObject: return -1
  let entries = body.getOrDefault("callLines")
  if entries.isNil or entries.kind != JArray: return -1
  let start = body.getOrDefault("startCallLineIndex").getBiggestInt(0).int64
  var lines: seq[CallLine] = @[]
  for i in 0 ..< entries.len:
    let w = callLineWireOf(entries[i])
    if w.isSome:
      lines.add callLineOf(w.get, start + i.int64)
  store.updateCalltraceSection(
    lines, start, body.getOrDefault("totalCallsCount").getBiggestInt(0).uint64)
  lines.len

proc stepDirectionToDapCommand*(direction: StepDirection): string =
  ## Map a StepDirection to the correct DAP command string.
  ## Each direction corresponds to a standard DAP command or a
  ## CodeTracer extension command, all of which are registered
  ## in the EVENT_KIND_TO_DAP_MAPPING table in dap.nim.
  case direction
  of sdForward:          "next"
  of sdBackward:         "stepBack"
  of sdStepIn:           "stepIn"
  of sdStepOut:          "stepOut"
  of sdContinue:         "continue"
  of sdReverseContinue:  "reverseContinue"
  of sdReverseStepIn:    "ct/reverseStepIn"
  of sdReverseStepOut:   "ct/reverseStepOut"

proc requestStep*(store: ReplayDataStore; direction: StepDirection) =
  ## Send a step command to the backend.
  ## Marks the debugger as stepping while the request is in flight.
  ##
  ## The direction is mapped to the correct DAP command string
  ## (e.g. sdForward → "next", sdStepIn → "stepIn") so that
  ## ``dapCommandToEventKind`` in dap.nim can resolve it without
  ## raising ``ValueError``.
  let key = "step"
  let dirStr = $direction
  if store.requestTracker.isDuplicate(key, dirStr):
    return

  store.requestTracker.markPending(key, dirStr)

  # Update debugger status to stepping.
  # Construct a NEW object to avoid JS reference semantics bug.
  let current = store.debugger.val
  store.debugger.val = DebuggerState(
    rrTicks: current.rrTicks,
    location: current.location,
    status: dsStepping,
    threadId: current.threadId,
  )

  let command = stepDirectionToDapCommand(direction)
  let threadId =
    if current.threadId == 0'u32:
      1
    else:
      current.threadId.int
  let args = %*{"direction": dirStr, "threadId": threadId}
  let fut = store.backend.send(command, args)

  let s = store
  fut.onComplete(
    onSuccess = proc() =
      s.requestTracker.markComplete(key),
    onError = proc() =
      s.requestTracker.markComplete(key)
      var dbg = s.debugger.val
      dbg.status = dsError
      s.debugger.val = dbg,
  )

proc requestRecordingHead*(store: ReplayDataStore) =
  ## Query the live MCR backend for the current recording head and mirror it
  ## into the session/timeline signals.
  let key = "mcr-recording-head"
  if store.requestTracker.isDuplicate(key, ""):
    return

  store.requestTracker.markPending(key, "")
  var session = store.session.val
  session.recordingHeadLoadingState = lsLoading
  store.session.val = session

  let fut = store.backend.send(LiveMcrGetRecordingHeadCommand, %*{})
  let s = store
  async_compat.onComplete(fut,
    onSuccess = proc(response: JsonNode) =
      s.requestTracker.markComplete(key)
      let head = response.readRRTicks(s.session.val.recordingHeadRRTicks)
      s.updateRecordingHead(head),
    onError = proc(msg: string) =
      s.requestTracker.markComplete(key)
      var failedSession = s.session.val
      failedSession.recordingHeadLoadingState = lsError
      s.session.val = failedSession,
  )

proc requestLiveToolbarAction*(store: ReplayDataStore; actionId: string) =
  ## Route a toolbar action to the fake/real live MCR command path instead of
  ## the completed-replay DAP step commands.
  let key = "mcr-live-step"
  if store.requestTracker.isDuplicate(key, actionId):
    return

  store.requestTracker.markPending(key, actionId)
  let current = store.debugger.val
  let runningStatus =
    if actionId == "continue": dsRunning
    else: dsStepping
  store.setDebuggerSnapshot(current.rrTicks, runningStatus)

  let threadId =
    if current.threadId == 0'u32:
      1
    else:
      current.threadId.int
  let args = %*{"action": actionId, "threadId": threadId}
  let fut = store.backend.send(LiveMcrStepCommand, args)

  let s = store
  fut.onComplete(
    onSuccess = proc() =
      s.requestTracker.markComplete(key)
      s.setDebuggerSnapshot(s.debugger.val.rrTicks, dsIdle),
    onError = proc() =
      s.requestTracker.markComplete(key)
      var dbg = s.debugger.val
      dbg.status = dsError
      s.debugger.val = dbg,
  )

proc requestSeekToGeid*(store: ReplayDataStore; geid: uint64) =
  ## Ask the backend to move the source/debugger position to a graphics event.
  ## The follow-up complete-move event is expected to refresh debugger state.
  store.requestHistoricalNavigation(SeekToGeidCommand, %*{"geid": geid})

proc requestRestoreAt*(store: ReplayDataStore; rrTicks: uint64;
                       jumpToLive: bool = false) =
  ## Restore execution at a recorded MCR position. A regular restore puts the
  ## toolbar into historical replay mode; jump-to-live restores to the tracked
  ## head and switches controls back to live mode.
  let key = if jumpToLive: "mcr-jump-to-live" else: "mcr-restore-at"
  let argsStr = $rrTicks
  if store.requestTracker.isDuplicate(key, argsStr):
    return

  store.requestTracker.markPending(key, argsStr)
  store.setDebuggerSnapshot(store.debugger.val.rrTicks, dsStepping)

  let liveMode = store.session.val.rememberedLiveMode
  let restoreCommand =
    if liveMode == liveMaterialized: LiveRecordingRestoreAtCommand
    else: LiveMcrRestoreAtCommand
  let args = %*{"rrTicks": rrTicks, "jumpToLive": jumpToLive}
  let fut = store.backend.send(restoreCommand, args)
  let s = store
  fut.onComplete(
    onSuccess = proc() =
      s.requestTracker.markComplete(key)

      var session = s.session.val
      if not jumpToLive and session.debugSessionMode in {liveMcr, liveMaterialized}:
        session.lastLiveDebugSessionMode = session.debugSessionMode
      session.debugSessionMode =
        if jumpToLive: session.rememberedLiveMode else: historicalFromLive
      if jumpToLive and session.recordingHeadRRTicks < rrTicks:
        session.recordingHeadRRTicks = rrTicks
      s.session.val = session

      var timeline = s.timeline.val
      timeline.currentRRTicks = rrTicks
      if rrTicks > timeline.maxRRTicks:
        timeline.maxRRTicks = rrTicks
      s.timeline.val = timeline
      s.setDebuggerSnapshot(rrTicks, dsIdle),
    onError = proc() =
      s.requestTracker.markComplete(key)
      var dbg = s.debugger.val
      dbg.status = dsError
      s.debugger.val = dbg,
  )

proc jumpToLive*(store: ReplayDataStore) =
  ## Restore to the last known live recording head.
  store.requestRestoreAt(store.session.val.recordingHeadRRTicks,
                         jumpToLive = true)
