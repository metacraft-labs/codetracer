## viewmodels/origin_chain_vm.nim
##
## OriginChainVM — ViewModel for Value Origin Tracking (M4).
##
## Holds reactive state for:
## - the active chain in the dedicated side panel,
## - the per-request loading flag (cancellable),
## - the set of variable rows expanded in the State Pane,
## - the breadcrumb stack of `(variable, step)` queries the user
##   navigated through,
## - the list of chains pinned by the user (mirrored into the
##   scratchpad VM via `onPinChain`),
## - the batched placeholder fill state for `ct/originSummary`
##   (debounce timer, pending tokens, in-flight flag),
## - the user preferences for the ubiquitous origin badge.
##
## Spec references:
## - §3.2.1 inline badge      — `expandedOrigins`, `iconClassForTerminator`.
## - §3.2.2 expanded chain    — `activeChain`, `onShowOrigin`, `onPushBreadcrumb`.
## - §3.2.3 ubiquitous badge  — `placeholderFillQueue`, `pendingFillTimer`.
## - §3.3 navigation          — `breadcrumbStack`, `onSeekToHop`.
## - §3.5 scratchpad          — `pinnedChains`, `onPinChain`.
## - §3.7 preferences         — `preferences`.
## - §5.3 DAP request         — issued via `BackendService.send("ct/originChain", …)`.
## - §5.3.2 lazy fill         — issued via `BackendService.send("ct/originSummary", …)`.
##
## Headless test posture (per the milestones-file Introduction): tests
## drive the real backend whenever possible. Pure VM-state tests run
## against the existing `MockBackendService` which records every command;
## the wire shape is asserted on a real db-backend in
## `src/db-backend/tests/origin_viewmodel_test.rs`.

import std/[json, options, sets, sequtils, hashes, tables]

import isonim/core/[signals, computation, owner, async_compat]
import isonim/viewmodel

import ../backend/backend_service
import ../store/[replay_data_store, types]
from ../store/stop_timeline import stopIdentityOf
import origin_chain_types

type
  RowChain* = object
    ## A State-pane row's origin chain and the stop it was asked at
    ## (`stop_timeline.stopIdentityOf`).
    stop*: string
    chain*: OriginChain

  OriginQueryRequest* = object
    ## Per-issued `ct/originChain` request. Tracking it on the VM lets
    ## `onCancelLoad` ignore late responses by comparing the response's
    ## request id against `latestRequestId`.
    requestId*: int
    expression*: string
    location*: Location
    stepId*: int64

  OriginChainVM* = ref object of ViewModel
    ## Reactive state for Value Origin Tracking. Used by the State Pane
    ## (inline badge + in-row expansion), the dedicated side-panel
    ## component (`isonim_origin_chain.nim`), the Scratchpad pinned
    ## entries, the omniscience-flow overlay, and the editor hover
    ## card.
    store*: ReplayDataStore

    # -- Mutable state --
    activeChain*: Signal[Option[OriginChain]]
      ## The chain rendered in the dedicated side panel + the in-row
      ## expansion of the last-clicked badge.
    loading*: Signal[bool]
      ## Spinner flag. Cleared when the matching response arrives or
      ## when `onCancelLoad` is called.
    pinnedChains*: Signal[seq[OriginChain]]
      ## Chains the user pinned via the "Pin chain" affordance. Each
      ## entry is also pushed into the scratchpad VM as a
      ## `ScratchpadChainEntry` so the Scratchpad pane reflects pins.
    expandedOrigins*: Signal[HashSet[VariableId]]
      ## Set of variable rows whose in-row chain is currently
      ## expanded. The State Pane subscribes to this signal to decide
      ## per row whether to render the in-row hop list.
    breadcrumbStack*: Signal[seq[BreadcrumbEntry]]
      ## Per-session navigation history. Each `onShowOrigin` push adds
      ## an entry; the side-panel renders them as clickable
      ## breadcrumbs (spec §3.3).
    preferences*: Signal[OriginPreferences]
      ## User-mutable badge / chain preferences (spec §3.7).
    placeholderFillQueue*: Signal[seq[string]]
      ## Pending placeholder tokens awaiting a batched
      ## `ct/originSummary` request (spec §3.2.3 batch fill).
    inFlightSummary*: Signal[bool]
      ## True while a batched `ct/originSummary` request is in flight.
    latestRequestId*: Signal[int]
    latestTransportRequest*: string
      ## The transport's identity of the latest `ct/originChain` sent, by the
      ## VM or by a host's own menu (`noteChainRequestSent`); "" when none is
      ## outstanding or it was cancelled. `applyChainAnswer` accepts only its
      ## answer.
      ## Counter incremented on every `onShowOrigin`. Used by
      ## `applyChainResponse` to ignore stale responses.
    sendingRowChainRequest: bool
      ## True only around `loadRowChain`'s own send: that request is a
      ## State-pane row's (§3.2.1), not the side panel's, so
      ## `noteChainRequestSent` does not make it the request whose answer
      ## `applyChainAnswer` shows. A request a host menu sends without the VM
      ## finds it false.
    rowChains*: Signal[Table[string, RowChain]]
      ## The chain of each State-pane row, by variable name, with the stop it
      ## was asked at: what the in-row block draws (spec §3.2.1). Every
      ## current-stop answer (`stepId` -1) lands here, whichever entry point
      ## asked, so expanding one row never empties another, and a chain asked
      ## at another stop is never drawn as this stop's (`rowChainAt`).
    rowChainsAskedStop: string
    rowChainsAsked: HashSet[string]
      ## The rows `loadRowChain` has asked about at `rowChainsAskedStop`, so a
      ## row is asked once per stop however often it is expanded or its
      ## summaries arrive. Reset when the stop changes.
    lastResolvedSummaries*: Signal[Table[string, OriginSummary]]
      ## Token → resolved-summary cache populated by responses to
      ## `ct/originSummary`. The State Pane subscribes and replaces
      ## `[?]` pills with the filled badge once the entry appears.
    sidePanelOpen*: Signal[bool]
      ## Whether the dedicated Origin Chain side panel (spec §3.2.2
      ## "Show in side panel" + §8.1) is currently visible. The host
      ## mounts ``ui/isonim_origin_chain.nim::renderPanelDom`` into a
      ## floating overlay when both this AND ``activeChain`` are
      ## populated; Esc / "close" affordances clear it.

    # -- Wiring --
    onSeekProc*: proc(stepId: int64; location: Location)
      ## Optional bridge installed by the host so `onSeekToHop` can
      ## reuse the existing `ct/history-jump` / `ct/goto-ticks` wiring.
    onPinChainProc*: proc(chain: OriginChain)
      ## Bridge to `ScratchpadVM.addChain`, installed by
      ## `origin_chain_bridges.wireOriginChainBridges` (which `ui/state.nim`
      ## calls). Nil only in a host that has not wired the VM.
    onSwitchProcessProc*: proc(recordingId: string)
      ## Optional bridge installed by `state.nim` to forward
      ## breadcrumb-chip clicks into `SessionViewModel.onSwitchProcess`
      ## per spec §14.8. The chip click handler also dispatches a
      ## seek via `onSeekProc` to the span's first hop so the editor
      ## scrolls to the recording entry point in the same gesture.

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

proc encodeLocation(loc: Location): JsonNode =
  ## Mirror the location field shape used by `ct/load-history` (the
  ## existing payload the backend already accepts).
  %*{
    "path": loc.file,
    "line": loc.line,
    "column": loc.column,
    "sourceGeneration": loc.sourceGeneration,
    "sourceDigest": loc.sourceDigest,
  }

proc derivePreferences(vm: OriginChainVM; key: string;
                       updater: proc(p: var OriginPreferences)) =
  ## Apply a mutation to the preferences signal. `key` is recorded in
  ## the comment so future telemetry can correlate writes with the
  ## spec preference name.
  ## (Pure setter — the actual persistence path goes through the
  ## already-existing settings layer; the VM only tracks the
  ## in-memory value.)
  discard key
  var prefs = vm.preferences.val
  updater(prefs)
  vm.preferences.val = prefs

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

proc applyChainResponse*(vm: OriginChainVM; chain: OriginChain;
                         requestId: int = -1)
proc applySummaryResponse*(vm: OriginChainVM; tokens: openArray[string];
                           summaries: openArray[OriginSummary])
proc recordRowChain(vm: OriginChainVM; expression, stop: string;
                    chain: OriginChain)
proc forgetRowRequest(vm: OriginChainVM; expression, stop: string)
proc onCancelLoad*(vm: OriginChainVM)

proc sendChainQuery(vm: OriginChainVM; expression: string; stepId: int64;
                    forSidePanel: bool) =
  ## Send one `ct/originChain` (spec §5.3) for `expression`, asked about
  ## `stepId`, and route its answer. Every current-stop answer (`stepId` -1)
  ## is kept as that row's chain AT THE STOP IT WAS ASKED AT (`rowChains`),
  ## whoever asked; only a side-panel request's answer becomes the side
  ## panel's chain (`activeChain`), and only while it is the latest one.
  ##
  ## THE QUERY IS ABOUT `stepId`: the step the engine walks back from. -1 is
  ## the current stop, which is what the State pane's rows are about; a caller
  ## asking about another moment (a history entry, a hop) passes that step.
  let prefs = vm.preferences.val
  let args = originChainArgs(
    expression = expression,
    stepId = stepId,
    maxHops = prefs.defaultMaxHops,
  )
  # The side panel applies the answer to THIS request when it arrives —
  # unless a newer side-panel request or a cancel came first
  # (`applyChainResponse`'s id check), so a late answer never replaces the
  # chain the user asked for since. A row's request takes no id: it never
  # supersedes the side panel's.
  var panelId = -1
  if forSidePanel:
    panelId = vm.latestRequestId.val + 1
    vm.latestRequestId.val = panelId
    vm.loading.val = true
  let askedAt = stopIdentityOf(vm.store.debugger.val)
  let vmRef = vm
  # The transport names the request from inside `send`
  # (`dap.dispatchCtRequest` runs the `trackCtRequests` hook before it
  # writes the frame, synchronously), so `noteChainRequestSent` sees this
  # flag; clearing it afterwards keeps a later request from a host menu,
  # which never passes through here, counted as the side panel's.
  vm.sendingRowChainRequest = not forSidePanel
  try:
    async_compat.onComplete(vm.store.backend.send("ct/originChain", args),
      onSuccess = proc(response: JsonNode) =
        let body = responseBody(response)
        if responseSucceeded(response) and body.hasKey("hops"):
          let chain = parseOriginChain(body)
          if stepId < 0:
            vmRef.recordRowChain(expression, askedAt, chain)
          if forSidePanel:
            vmRef.applyChainResponse(chain, panelId)
        elif not forSidePanel:
          vmRef.forgetRowRequest(expression, askedAt),
      onError = proc(message: string) =
        if not forSidePanel:
          vmRef.forgetRowRequest(expression, askedAt))
  finally:
    vm.sendingRowChainRequest = false

proc onShowOrigin*(vm: OriginChainVM; expression: string; location: Location;
                   stepId: int64 = -1) =
  ## "Show value origin" — the State-Pane right-click menu, the command
  ## palette, the `origin(expr)` watch: dispatch a `ct/originChain` request
  ## (spec §5.3) for `expression` at `(location, stepId)` and, per spec §3.1 /
  ## §3.2.2 + M4 deliverable §9, open the dedicated Origin Chain side panel
  ## and push a breadcrumb, so the user sees the navigation even before the
  ## response arrives. The request is tracked via `latestRequestId` so
  ## `onCancelLoad` can ignore the late response.
  ##
  ## `location` is where the value is SHOWN — the source position the State
  ## pane's row belongs to — and does not change the question.
  ##
  ## The origin badge's in-place fetch is `loadRowChain`, which touches
  ## neither the side panel nor its breadcrumb trail.
  if vm.store.isNil or vm.store.backend.isNil:
    return
  vm.sidePanelOpen.val = true
  var stack = vm.breadcrumbStack.val
  stack.add(BreadcrumbEntry(variableName: expression, stepId: stepId))
  vm.breadcrumbStack.val = stack
  vm.sendChainQuery(expression, stepId, forSidePanel = true)

proc recordRowChain(vm: OriginChainVM; expression, stop: string;
                    chain: OriginChain) =
  var chains = vm.rowChains.val
  chains[expression] = RowChain(stop: stop, chain: chain)
  vm.rowChains.val = chains

proc forgetRowRequest(vm: OriginChainVM; expression, stop: string) =
  ## A row's request that produced no chain may be asked again: re-expanding
  ## the row retries it.
  if vm.rowChainsAskedStop == stop:
    vm.rowChainsAsked.excl(expression)

proc rowChainAt*(vm: OriginChainVM; expression, stop: string): Option[OriginChain] =
  ## The chain of the State-pane row `expression` at `stop`, if one was
  ## answered there. Reactive: reads `rowChains`.
  let chains = vm.rowChains.val
  if chains.hasKey(expression) and chains[expression].stop == stop:
    some(chains[expression].chain)
  else:
    none(OriginChain)

proc loadRowChain*(vm: OriginChainVM; expression: string; location: Location) =
  ## Ask for the chain of the State-pane row `expression` at the current
  ## stop, for the in-row block (spec §3.2.1, "expands the row in place"):
  ## the answer lands in `rowChains` only, so the side panel's chain, its
  ## pending request and its breadcrumb trail are left alone. Asked at most
  ## once per row per stop, so the expand click and the re-ask after a move
  ## cannot duplicate it.
  if vm.store.isNil or vm.store.backend.isNil:
    return
  let stop = stopIdentityOf(vm.store.debugger.val)
  if vm.rowChainAt(expression, stop).isSome:
    return
  if vm.rowChainsAskedStop != stop:
    vm.rowChainsAskedStop = stop
    vm.rowChainsAsked = initHashSet[string]()
  if expression in vm.rowChainsAsked:
    return
  vm.rowChainsAsked.incl(expression)
  vm.sendChainQuery(expression, stepId = -1, forSidePanel = false)

proc openSidePanel*(vm: OriginChainVM) =
  ## Force-open the side panel (used by the command palette / keyboard
  ## shortcut paths that already have an ``activeChain`` populated).
  vm.sidePanelOpen.val = true

proc closeSidePanel*(vm: OriginChainVM) =
  ## Dismiss the side panel without clearing ``activeChain`` (so the
  ## same chain can be re-opened without re-fetching). Wired to the
  ## panel's Esc key handler per spec §13.0.
  vm.sidePanelOpen.val = false

proc noteChainRequestSent*(vm: OriginChainVM; transportId: string) =
  ## A `ct/originChain` is being sent NOW, by whatever issued it (the VM or a
  ## host's own menu), under the transport's identity. Every request but a
  ## State-pane row's (`loadRowChain`) is the side panel's: it becomes the
  ## request whose answer `applyChainAnswer` accepts and shows there. A
  ## row's request leaves that tracking alone, so it neither supersedes a
  ## side-panel request still outstanding nor has its own answer shown in
  ## the side panel (spec §3.2.1 vs §3.2.2).
  if vm.sendingRowChainRequest:
    return
  vm.latestTransportRequest = transportId
  vm.loading.val = true

proc rejectChainAnswer*(vm: OriginChainVM; transportId: string): bool =
  ## A `ct/originChain` answer that arrived on the transport without a chain.
  ## It ends the side panel's wait (`onCancelLoad`) only when it answers the
  ## side panel's latest request — or names none while one is outstanding —
  ## so a row's failed fetch never cancels the side panel's; `true` when it
  ## did.
  if transportId.len > 0:
    if transportId != vm.latestTransportRequest:
      return false
  elif not vm.loading.val:
    return false
  vm.onCancelLoad()
  true

proc applyChainAnswer*(vm: OriginChainVM; chain: OriginChain;
                       transportId: string): bool =
  ## Apply a chain that arrived on the transport, named by the request it
  ## answers. Only the answer to the latest request sent, and not cancelled
  ## since, is applied; `true` when it was. An answer that carries no
  ## identity (a transport that names none) is applied while a request is
  ## outstanding.
  if transportId.len > 0:
    if transportId != vm.latestTransportRequest:
      return false
  elif not vm.loading.val:
    return false
  vm.activeChain.val = some(chain)
  vm.loading.val = false
  vm.latestTransportRequest = ""
  true

proc applyChainResponse*(vm: OriginChainVM; chain: OriginChain;
                         requestId: int = -1) =
  ## Apply a decoded `ct/originChain` response to the VM state.
  ## `requestId` is the id of the request the chain answers; when it
  ## is older than `latestRequestId` (i.e. `onCancelLoad` fired in
  ## between) the chain is ignored.
  if requestId >= 0 and requestId != vm.latestRequestId.val:
    return
  vm.activeChain.val = some(chain)
  vm.loading.val = false

proc onCancelLoad*(vm: OriginChainVM) =
  ## Drop the spinner flag and bump the request counter so any future
  ## arriving response is treated as stale — the VM's own and one named by
  ## the transport alike.
  vm.loading.val = false
  vm.latestRequestId.val = vm.latestRequestId.val + 1
  vm.latestTransportRequest = ""

proc onSeekToHop*(vm: OriginChainVM; hop: OriginHop) =
  ## Invoke the host-provided seek bridge (spec §3.3 "Click a hop").
  ## Falls back to a `ct/history-jump` payload via the backend
  ## directly when no host bridge is installed (e.g. in unit tests).
  if not vm.onSeekProc.isNil:
    let loc = Location(file: hop.location.path, line: hop.location.line)
    vm.onSeekProc(hop.stepId, loc)
    return
  if vm.store.isNil or vm.store.backend.isNil:
    return
  # Fallback: forward the seek as a history-jump request so the
  # existing backend dispatcher (`ct/history-jump`) handles it.
  #
  # A FLAT `Location`, because that is what the command deserialises into.
  # This used to send `{expression, location: {path, line, rrTicks}, stepId}`
  # — a shape invented here, whose only field name in common with the
  # backend's `task::Location` is `expression`, which decides nothing.  The
  # destination fields sat one level down under `location` and so were never
  # read.  `Location` is `#[serde(default)]` at container level, so the
  # backend did not reject the payload: it deserialised a fully zeroed
  # location and seeked to `rrTicks = 0`, landing every hop click on the
  # first step of the recording and answering `success` (codetracer#698).
  #
  # `rrTicks` is the field `db.rs`'s `location_jump` actually navigates by,
  # and the backend now REFUSES a jump payload that omits it, so this shape
  # cannot silently regress to the nested one.
  let args = %*{
    "path": hop.location.path,
    "line": hop.location.line,
    "rrTicks": hop.location.rrTicks,
    "highLevelPath": hop.location.path,
    "highLevelLine": hop.location.line,
    "expression": hop.targetExpr,
  }
  vm.store.requestHistoricalNavigation("ct/history-jump", args)

proc onSwitchToSpan*(vm: OriginChainVM; span: CrossProcessSpan) =
  ## M29 §14.8 — switch the active recording to the one owning
  ## `span` and seek the editor to the span's first hop in the
  ## chain. Fires the `onSwitchProcessProc` bridge so the renderer
  ## routes through `SessionViewModel.onSwitchProcess`; then
  ## dispatches a seek via `onSeekProc` to the span's first hop so
  ## the editor follows. Both bridges are optional — unit tests can
  ## install one without the other and the call is a no-op for
  ## unconfigured surfaces.
  if not vm.onSwitchProcessProc.isNil and span.recordingId.len > 0:
    vm.onSwitchProcessProc(span.recordingId)
  let chainOpt = vm.activeChain.val
  if chainOpt.isNone:
    return
  let chain = chainOpt.get
  let idx = int(span.firstHopIndex)
  if idx < 0 or idx >= chain.hops.len:
    return
  vm.onSeekToHop(chain.hops[idx])

proc onPinChain*(vm: OriginChainVM; chain: OriginChain) =
  ## Pin `chain` in both the VM's local list and the scratchpad
  ## component (via `onPinChainProc`).
  var pinned = vm.pinnedChains.val
  pinned.add(chain)
  vm.pinnedChains.val = pinned
  if not vm.onPinChainProc.isNil:
    vm.onPinChainProc(chain)

proc onPushBreadcrumb*(vm: OriginChainVM; entry: BreadcrumbEntry) =
  ## Manually push a breadcrumb (used by the side-panel's recursive
  ## "Show value origin on operand" navigation).
  var stack = vm.breadcrumbStack.val
  stack.add(entry)
  vm.breadcrumbStack.val = stack

proc onPopBreadcrumb*(vm: OriginChainVM): Option[BreadcrumbEntry] =
  ## Pop the most-recent breadcrumb entry. Returns the popped entry
  ## (or `none` when the stack was empty) so the host can re-issue
  ## the matching `ct/originChain` if needed.
  var stack = vm.breadcrumbStack.val
  if stack.len == 0:
    return none(BreadcrumbEntry)
  let last = stack[^1]
  stack.setLen(stack.len - 1)
  vm.breadcrumbStack.val = stack
  some(last)

proc onClearBreadcrumbs*(vm: OriginChainVM) =
  ## Clear the entire breadcrumb stack (called on session switch).
  vm.breadcrumbStack.val = @[]

proc toggleExpanded*(vm: OriginChainVM; row: VariableId) =
  ## Toggle the inline expansion state for `row`. The State Pane
  ## subscribes to `expandedOrigins` and renders the in-row chain
  ## when the row's id is in the set.
  var expanded = vm.expandedOrigins.val
  if row in expanded:
    expanded.excl(row)
  else:
    expanded.incl(row)
  vm.expandedOrigins.val = expanded

proc isExpanded*(vm: OriginChainVM; row: VariableId): bool =
  row in vm.expandedOrigins.val

proc enqueuePlaceholderFill*(vm: OriginChainVM; token: string) =
  ## Queue `token` for the next batched `ct/originSummary` request
  ## (spec §3.2.3 batch fill). Duplicate tokens are de-duped before
  ## the request fires so a scroll event that touches the same
  ## placeholder twice does not cost two round-trips.
  if token.len == 0:
    return
  var queue = vm.placeholderFillQueue.val
  if token notin queue:
    queue.add(token)
    vm.placeholderFillQueue.val = queue

proc flushPlaceholderFill*(vm: OriginChainVM) =
  ## Dispatch the queued `ct/originSummary` batch immediately.
  ## Returns silently when the queue is empty or another batch is
  ## already in flight (the next flush attempt picks up where this
  ## one left off because the queue is only emptied after the
  ## response handler clears `inFlightSummary`).
  if vm.inFlightSummary.val:
    return
  let queue = vm.placeholderFillQueue.val
  if queue.len == 0:
    return
  if vm.store.isNil or vm.store.backend.isNil:
    return
  vm.inFlightSummary.val = true
  let args = originSummaryArgs(queue)
  # THE ANSWER IS APPLIED HERE, and the next batch follows: the fill used to
  # set `inFlightSummary` and wait for a caller of `applySummaryResponse`
  # that no host had, so it stopped after the first batch.
  let vmRef = vm
  let sent = queue
  async_compat.onComplete(vm.store.backend.send("ct/originSummary", args),
    onSuccess = proc(response: JsonNode) =
      if responseSucceeded(response):
        vmRef.applySummaryResponse(sent,
          parseOriginSummariesResponse(responseBody(response)))
      else:
        vmRef.inFlightSummary.val = false
      # Whatever was queued while this batch was in flight goes next.
      vmRef.flushPlaceholderFill(),
    onError = proc(message: string) =
      vmRef.inFlightSummary.val = false)

proc applySummaryResponse*(vm: OriginChainVM; tokens: openArray[string];
                           summaries: openArray[OriginSummary]) =
  ## Apply a decoded `ct/originSummary` response. Populates
  ## `lastResolvedSummaries` so `[?]` pills know to upgrade
  ## themselves, drains the resolved tokens from
  ## `placeholderFillQueue`, and clears the in-flight flag so the next
  ## scroll batch can fire.
  var cache = vm.lastResolvedSummaries.val
  let n = min(tokens.len, summaries.len)
  for i in 0 ..< n:
    cache[tokens[i]] = summaries[i]
  vm.lastResolvedSummaries.val = cache

  var queue = vm.placeholderFillQueue.val
  queue = queue.filterIt(it notin tokens)
  vm.placeholderFillQueue.val = queue
  vm.inFlightSummary.val = false

proc setShowContainingFunction*(vm: OriginChainVM; inline: bool) =
  ## Update the inline-badge `showContainingFunction` preference
  ## (spec §3.7). The side-panel toggle is updated via the dedicated
  ## `setShowContainingFunctionPanel` helper below.
  vm.derivePreferences("originBadge.showContainingFunction") do (
      p: var OriginPreferences):
    p.showContainingFunctionInline = inline

proc setShowContainingFunctionPanel*(vm: OriginChainVM; show: bool) =
  vm.derivePreferences("originBadge.showContainingFunction.sidePanel") do (
      p: var OriginPreferences):
    p.showContainingFunctionPanel = show

proc setExpressionStyle*(vm: OriginChainVM; style: OriginExpressionStyle) =
  ## Update `originBadge.expressionStyle` (spec §3.7).
  vm.derivePreferences("originBadge.expressionStyle") do (
      p: var OriginPreferences):
    p.expressionStyle = style

proc setEagerMode*(vm: OriginChainVM; surface: OriginPaneSurface;
                   mode: OriginEagerMode) =
  ## Override the per-surface eager/placeholder default (spec §3.2.3
  ## V1 defaults table + §3.7 `originDisplay.eagerMode.<surface>`).
  vm.derivePreferences("originDisplay.eagerMode") do (
      p: var OriginPreferences):
    p.eagerMode[surface] = mode

proc setBatchFillVisible*(vm: OriginChainVM; on: bool) =
  vm.derivePreferences("originDisplay.batchFillVisible") do (
      p: var OriginPreferences):
    p.batchFillVisible = on

proc setBatchFillThrottleMs*(vm: OriginChainVM; ms: int) =
  vm.derivePreferences("originDisplay.batchFillThrottleMs") do (
      p: var OriginPreferences):
    p.batchFillThrottleMs = ms

proc setDefaultMaxHops*(vm: OriginChainVM; maxHops: int) =
  vm.derivePreferences("originChain.defaultMaxHops") do (
      p: var OriginPreferences):
    p.defaultMaxHops = maxHops

proc setCollapseTrivialChainsThreshold*(vm: OriginChainVM; threshold: int) =
  vm.derivePreferences("originChain.collapseTrivialChainsThreshold") do (
      p: var OriginPreferences):
    p.collapseTrivialChainsThreshold = threshold

# ---------------------------------------------------------------------------
# Convenience derived helpers callable from the view layer
# ---------------------------------------------------------------------------

proc badgeText*(vm: OriginChainVM; summary: OriginSummary;
                atSidePanel: bool = false): string =
  badgeTextForSummary(summary, vm.preferences.val, atSidePanel)

proc currentEagerMode*(vm: OriginChainVM;
                      surface: OriginPaneSurface): OriginEagerMode =
  let prefs = vm.preferences.val
  if prefs.eagerMode.hasKey(surface):
    prefs.eagerMode[surface]
  else:
    oemEager

# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

proc createOriginChainVM*(store: ReplayDataStore): OriginChainVM =
  ## Create an OriginChainVM inside a reactive root owned by
  ## `withViewModel`. The reactive root is disposed via `vm.dispose()`.
  ##
  ## Mirrors the construction pattern used by `flow_vm.nim` /
  ## `event_log_vm.nim`. No auto-load effect — `OriginChainVM` is
  ## driven entirely by user actions (badge click / context menu /
  ## command palette / keyboard shortcut), so registering a
  ## debugger-position effect would issue spurious requests on every
  ## move.
  withViewModel proc(dispose: proc()): OriginChainVM =
    let vm = OriginChainVM(
      store: store,
      activeChain: createSignal(none(OriginChain)),
      loading: createSignal(false),
      pinnedChains: createSignal(newSeq[OriginChain]()),
      expandedOrigins: createSignal(initHashSet[VariableId]()),
      breadcrumbStack: createSignal(newSeq[BreadcrumbEntry]()),
      preferences: createSignal(defaultOriginPreferences()),
      placeholderFillQueue: createSignal(newSeq[string]()),
      inFlightSummary: createSignal(false),
      latestRequestId: createSignal(0),
      lastResolvedSummaries: createSignal(
        initTable[string, OriginSummary]()),
      sidePanelOpen: createSignal(false),
      rowChains: createSignal(initTable[string, RowChain]()),
      sendingRowChainRequest: false,
      disposeProc: dispose,
    )
    vm

# Re-export `encodeLocation` so callers (`state.nim`, `value.nim`) can
# build location arguments without duplicating the JSON shape.
proc locationToJson*(loc: Location): JsonNode = encodeLocation(loc)
