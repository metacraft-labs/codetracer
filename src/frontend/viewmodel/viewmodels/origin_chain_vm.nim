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

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ../backend/backend_service
import ../store/[replay_data_store, types]
import origin_chain_types

type
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
      ## Counter incremented on every `onShowOrigin`. Used by
      ## `applyChainResponse` to ignore stale responses.
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
      ## Optional bridge installed by `state.nim` to forward pinned
      ## chains into `ScratchpadVM`.

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

proc onShowOrigin*(vm: OriginChainVM; expression: string; location: Location;
                   stepId: int64 = -1) =
  ## Dispatch a `ct/originChain` request (spec §5.3) for `expression`
  ## at `(location, stepId)`. The request is tracked via
  ## `latestRequestId` so `onCancelLoad` can ignore the late response.
  ## The breadcrumb stack is updated immediately so the user sees the
  ## navigation reflected even before the response arrives.
  ##
  ## Per spec §3.2.2 + M4 deliverable §9, ``onShowOrigin`` also opens
  ## the dedicated Origin Chain side panel. The State-Pane right-click
  ## "Show value origin" menu item routes here; the in-row badge
  ## click toggles the inline expansion and goes through the same
  ## entry-point.
  if vm.store.isNil or vm.store.backend.isNil:
    return
  let nextId = vm.latestRequestId.val + 1
  vm.latestRequestId.val = nextId
  vm.loading.val = true
  vm.sidePanelOpen.val = true

  var stack = vm.breadcrumbStack.val
  stack.add(BreadcrumbEntry(variableName: expression, stepId: stepId))
  vm.breadcrumbStack.val = stack

  let prefs = vm.preferences.val
  let args = originChainArgs(
    expression = expression,
    stepId = stepId,
    maxHops = prefs.defaultMaxHops,
  )
  discard vm.store.backend.send("ct/originChain", args)

proc openSidePanel*(vm: OriginChainVM) =
  ## Force-open the side panel (used by the command palette / keyboard
  ## shortcut paths that already have an ``activeChain`` populated).
  vm.sidePanelOpen.val = true

proc closeSidePanel*(vm: OriginChainVM) =
  ## Dismiss the side panel without clearing ``activeChain`` (so the
  ## same chain can be re-opened without re-fetching). Wired to the
  ## panel's Esc key handler per spec §13.0.
  vm.sidePanelOpen.val = false

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
  ## arriving response is treated as stale.
  vm.loading.val = false
  vm.latestRequestId.val = vm.latestRequestId.val + 1

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
  let args = %*{
    "expression": hop.targetExpr,
    "location": %*{
      "path": hop.location.path,
      "line": hop.location.line,
      "rrTicks": hop.location.rrTicks,
    },
    "stepId": hop.stepId,
  }
  vm.store.requestHistoricalNavigation("ct/history-jump", args)

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
  discard vm.store.backend.send("ct/originSummary", args)

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
      disposeProc: dispose,
    )
    vm

# Re-export `encodeLocation` so callers (`state.nim`, `value.nim`) can
# build location arguments without duplicating the JSON shape.
proc locationToJson*(loc: Location): JsonNode = encodeLocation(loc)
