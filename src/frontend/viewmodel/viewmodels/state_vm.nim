## viewmodels/state_vm.nim
##
## StateVM — ViewModel for the State (locals / globals / watches) panel.
##
## Holds reactive state for:
## - Which tab is active (locals, globals, watches)
## - Which variable paths are expanded in the tree view
## - Which path is selected (for keyboard navigation)
## - Watch expressions entered by the user
##
## Derives:
## - `currentVariables`: the variable list for the active tab
## - `isLoading`: whether the store is currently fetching data
##
## Runtime data loading is owned by this VM. The legacy StateComponent
## still mirrors backend responses into the shared store, but debugger
## moves in headless/app-VM sessions must be enough to request fresh locals
## without relying on component side effects.
##
## Usage:
##   let vm = createStateVM(store)
##   echo vm.activeTab.val        # stLocals
##   vm.selectTab(stGlobals)
##   echo vm.currentVariables.val # globals from the store

import std/[json, options, sets, tables, strutils]

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ../backend/backend_service
import ../collab/[reducer, runtime_role, session_core, types]
import ../store/[replay_data_store, types]
import origin_chain_types

type
  StateTab* = enum
    ## The three tabs available in the state panel.
    stLocals   ## Local variables at the current execution point
    stGlobals  ## Global / module-level variables
    stWatches  ## User-defined watch expressions

  StateVM* = ref object of ViewModel
    ## Reactive state for the State panel.
    ##
    ## Mutable signals:
    ##   activeTab       — which tab is shown
    ##   expandedPaths   — set of variable paths whose children are visible
    ##   selectedPath    — path under the cursor (empty string = none)
    ##   watchExpressions — list of user-entered watch expressions
    ##
    ## Derived memos:
    ##   currentVariables — the variable seq for the active tab
    ##   isLoading        — whether a locals request is in flight
    ##
    ## The store reference is kept for the auto-load effect.
    store*: ReplayDataStore
    collabCore*: CollaborativeSessionCore
    runtimeRole*: ViewModelRuntimeRole

    # -- Mutable state --
    activeTab*: Signal[StateTab]
    expandedPaths*: Signal[HashSet[string]]
    selectedPath*: Signal[string]
      ## Empty string means "no selection".
    watchExpressions*: Signal[seq[string]]

    # -- Derived state --
    currentVariables*: Memo[seq[Variable]]
    isLoading*: Memo[bool]
    codeStateLine*: Memo[string]
      ## Pre-formatted "<line> | <sourceCode>" string mirrored from
      ## the store. Empty when there is no source for the current
      ## position — the view renders the ``no-code`` fallback in that
      ## case so the ``#code-state-line-{id}`` element is always
      ## present in the DOM (Playwright tests rely on its presence).
    onToggleHistory*: proc(expression: string)
      ## Optional bridge installed by StateComponent so the IsoNim
      ## value-history button can still enter the legacy history
      ## request pipeline.

    # -- Value Origin Tracking (M4, spec §3.2.1 + §3.2.3) --
    expandedOrigins*: Signal[HashSet[VariableId]]
      ## Per-row inline expansion state for the origin chain in the
      ## State Pane. The State Pane subscribes per row to decide
      ## whether to render the in-row hop chain. Mirrors the
      ## `OriginChainVM.expandedOrigins` signal so the legacy
      ## state-pane bridge can mutate either side without dragging
      ## the OriginChainVM into every component that already imports
      ## StateVM.
    breadcrumbStack*: Signal[seq[BreadcrumbEntry]]
      ## Breadcrumb navigation state (spec §3.3). Mirrored from
      ## `OriginChainVM.breadcrumbStack` for the same reason as
      ## `expandedOrigins` above.
    originSummaries*: Signal[Table[string, OriginSummary]]
      ## Per-row `originSummary` keyed by variable name. Populated
      ## from the `ct/load-locals` response per spec §3.2.3.
    originPreferences*: Signal[OriginPreferences]
      ## Per-pane mirror of the user-mutable origin badge / chain
      ## preferences (spec §3.7). Defaults to
      ## ``defaultOriginPreferences()``; the host bridges any updates
      ## from ``OriginChainVM.preferences`` into this signal so the
      ## State-Pane row renderer can pick the right badge variant
      ## without dragging the OriginChainVM into the State component.
    originChainLookup*: proc(name: string): Option[OriginChain]
      ## Optional bridge installed by the host (`state.nim`) so the
      ## per-row expanded chain (spec §3.2.1 collapsed → expanded) can
      ## look up the active chain for a variable. Returns ``none`` when
      ## no chain has been fetched yet — the row then renders the
      ## badge only and waits for the response.
    onShowOriginProc*: proc(expression: string; location: Location)
      ## Optional bridge invoked by `onShowOrigin` — installed by
      ## `state.nim` to forward into `OriginChainVM.onShowOrigin`.

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

proc selectTab*(vm: StateVM; tab: StateTab) =
  ## Switch to a different tab. The `currentVariables` memo updates
  ## automatically because it depends on `activeTab`.
  if not vm.collabCore.isNil:
    discard vm.collabCore.dispatchLocalViewOp(
      vokSetStateTab,
      "statePane.activeTab",
      %*{"tab": $tab},
    )
    return
  vm.activeTab.val = tab

proc toggleExpand*(vm: StateVM; path: string) =
  ## Toggle whether a variable path is expanded or collapsed.
  ## If the path is currently in the expanded set it is removed;
  ## otherwise it is added.
  if not vm.collabCore.isNil:
    let expanded = not (path in vm.expandedPaths.val)
    let observedAddTags =
      if expanded: @[]
      else: vm.collabCore.liveAddTags(
        vm.collabCore.document.state.statePane.expandedPaths, path)
    discard vm.collabCore.dispatchLocalViewOp(
      vokToggleStatePath,
      "statePane.expandedPaths",
      %*{
        "path": path,
        "expanded": expanded,
        "observedAddTags": observedAddTags,
      },
    )
    return
  var paths = vm.expandedPaths.val
  if path in paths:
    paths.excl(path)
  else:
    paths.incl(path)
  vm.expandedPaths.val = paths

proc selectPath*(vm: StateVM; path: string) =
  ## Set the currently selected variable path.
  ## Pass an empty string to clear the selection.
  if not vm.collabCore.isNil:
    discard vm.collabCore.dispatchLocalViewOp(
      vokSetRegister,
      "statePane.selectedPath",
      %*{"value": path},
    )
    return
  vm.selectedPath.val = path

proc isOriginWatch*(expression: string): bool =
  ## Value Origin Tracking (M4) — `origin(expr)` watch prefix per
  ## spec §3.1 "Watch expression with the prefix `origin(expr)`".
  ## The watch evaluator routes any matching expression through the
  ## `ct/originChain` path instead of `ct/load-locals`.
  let trimmed = expression.strip
  trimmed.startsWith("origin(") and trimmed.endsWith(")")

proc unwrapOriginWatch*(expression: string): string =
  ## Return the inner expression for an `origin(...)` watch. Returns
  ## the original string when the watch is not an origin watch.
  let trimmed = expression.strip
  if not isOriginWatch(trimmed):
    return expression
  trimmed[len("origin(") ..< trimmed.len - 1].strip

proc addWatch*(vm: StateVM; expression: string) =
  ## Add a watch expression. Duplicates are silently ignored.
  ## After adding, the auto-load effect will re-request locals with
  ## the updated watch list on the next rrTicks change.
  ##
  ## Value Origin Tracking (M4) — when `expression` is an
  ## `origin(...)` watch (spec §3.1), the addition is recorded
  ## verbatim so subsequent navigation through the trace re-evaluates
  ## the origin chain. The actual `ct/originChain` dispatch is wired
  ## via the host bridge so the `OriginChainVM` observes the same
  ## response and updates its `activeChain` signal.
  if expression.len == 0:
    return
  if isOriginWatch(expression) and not vm.onShowOriginProc.isNil and
     not vm.store.isNil:
    let inner = unwrapOriginWatch(expression)
    if inner.len > 0:
      let loc = vm.store.debugger.val.location
      vm.onShowOriginProc(inner, loc)
  if not vm.collabCore.isNil:
    if vm.collabCore.liveWatchForExpression(expression).isSome:
      return
    let watchId = "watch:" & expression
    let orderKey = $vm.collabCore.document.state.statePane.visibleWatches.len
    discard vm.collabCore.dispatchLocalViewOp(
      vokAddWatch,
      "statePane.watchExpressions",
      %*{
        "watchId": watchId,
        "expression": expression,
        "orderKey": orderKey,
      },
    )
    return
  var exprs = vm.watchExpressions.val
  for existing in exprs:
    if existing == expression:
      return
  exprs.add(expression)
  vm.watchExpressions.val = exprs

proc removeWatch*(vm: StateVM; expression: string) =
  ## Remove a watch expression by value. No-op if not found.
  if not vm.collabCore.isNil:
    let watch = vm.collabCore.liveWatchForExpression(expression)
    if watch.isNone:
      return
    discard vm.collabCore.dispatchLocalViewOp(
      vokRemoveWatch,
      "statePane.watchExpressions",
      %*{
        "watchId": watch.get.id,
        "observedAddTags": watch.get.addTags,
      },
    )
    return
  var exprs = vm.watchExpressions.val
  var idx = -1
  for i, e in exprs:
    if e == expression:
      idx = i
      break
  if idx >= 0:
    exprs.delete(idx)
    vm.watchExpressions.val = exprs

proc toggleHistory*(vm: StateVM; expression: string) =
  if not vm.onToggleHistory.isNil:
    vm.onToggleHistory(expression)

# ---------------------------------------------------------------------------
# Value Origin Tracking (M4) actions — keep adjacent to `toggleHistory`
# because each variable row exposes both an "open history" and an
# "open origin" affordance per spec §3.2.1 / §3.2.3.
# ---------------------------------------------------------------------------

proc onShowOrigin*(vm: StateVM; expression: string; location: Location) =
  ## Dispatch a `ct/originChain` request (spec §5.3) for `expression`
  ## at `location`. Sends the request directly via `BackendService.send`
  ## so the call site does not need to import the OriginChainVM, and
  ## also invokes the optional `onShowOriginProc` bridge that the host
  ## installs to keep the OriginChainVM in sync.
  ##
  ## The host bridge is invoked AFTER the wire send so that the
  ## OriginChainVM observes the request fire-and-forget — it tracks
  ## the response via its own event handler.
  if not vm.store.isNil and not vm.store.backend.isNil:
    let args = originChainArgs(expression = expression)
    discard vm.store.backend.send("ct/originChain", args)
  if not vm.onShowOriginProc.isNil:
    vm.onShowOriginProc(expression, location)

proc toggleOriginExpansion*(vm: StateVM; row: VariableId) =
  ## Toggle the in-row inline chain expansion for `row`. The State
  ## Pane subscribes per row and renders the chain when the row's id
  ## is present (spec §3.2.1 collapsed → expanded).
  var expanded = vm.expandedOrigins.val
  if row in expanded:
    expanded.excl(row)
  else:
    expanded.incl(row)
  vm.expandedOrigins.val = expanded

proc pushBreadcrumb*(vm: StateVM; entry: BreadcrumbEntry) =
  ## Push a breadcrumb entry — used by the right-click context menu
  ## that opens the chain in the dedicated side panel (spec §3.3).
  var stack = vm.breadcrumbStack.val
  stack.add(entry)
  vm.breadcrumbStack.val = stack

proc popBreadcrumb*(vm: StateVM): Option[BreadcrumbEntry] =
  var stack = vm.breadcrumbStack.val
  if stack.len == 0:
    return none(BreadcrumbEntry)
  let last = stack[^1]
  stack.setLen(stack.len - 1)
  vm.breadcrumbStack.val = stack
  some(last)

proc updateOriginSummaries*(vm: StateVM;
                            summaries: openArray[(string, OriginSummary)]) =
  ## Bulk-replace the per-row origin-summary table. Called by the
  ## legacy `registerLocals` bridge so the IsoNim view sees the same
  ## data the legacy DOM consumes via the `ct/load-locals` response.
  var t = initTable[string, OriginSummary]()
  for (name, summary) in summaries:
    t[name] = summary
  vm.originSummaries.val = t

proc upsertOriginSummary*(vm: StateVM; name: string; summary: OriginSummary) =
  ## Update a single entry — used when a `ct/originSummary`
  ## placeholder fill arrives.
  var t = vm.originSummaries.val
  t[name] = summary
  vm.originSummaries.val = t

proc originSummaryFor*(vm: StateVM; name: string): Option[OriginSummary] =
  ## Look up the per-row origin summary for ``name``. Returns
  ## ``none`` when no summary has arrived yet — the State-Pane row
  ## renderer skips the badge in that case.
  let t = vm.originSummaries.val
  if t.hasKey(name):
    some(t[name])
  else:
    none(OriginSummary)

proc isOriginExpanded*(vm: StateVM; row: VariableId): bool =
  ## Convenience predicate used by the row renderer to decide whether
  ## to attach the in-row expanded chain block below the value cell.
  row in vm.expandedOrigins.val

# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

proc createStateVM*(store: ReplayDataStore;
                    collabCore: CollaborativeSessionCore = nil;
                    runtimeRole = vrrStandalone): StateVM =
  ## Create a StateVM inside a reactive root owned by `withViewModel`.
  ## The reactive root is disposed via `vm.dispose()`.
  ##
  ## Sets up:
  ## 1. Mutable signals with sensible defaults
  ## 2. Derived memos for `currentVariables` and `isLoading`
  ## 3. Optional bridge callbacks supplied by the legacy component
  withViewModel proc(dispose: proc()): StateVM =
    let activeTab = createSignal(stLocals)
    let expandedPaths = createSignal(initHashSet[string]())
    let selectedPath = createSignal("")
    let watchExpressions = createSignal(newSeq[string]())
    let expandedOrigins = createSignal(initHashSet[VariableId]())
    let breadcrumbStack = createSignal(newSeq[BreadcrumbEntry]())
    let originSummaries = createSignal(initTable[string, OriginSummary]())
    let originPreferences = createSignal(defaultOriginPreferences())

    # Derived: pick the right variable list based on the active tab.
    let currentVariables = createMemo[seq[Variable]] proc(): seq[Variable] =
      case activeTab.val
      of stLocals:
        store.locals.locals.val
      of stGlobals:
        store.locals.globals.val
      of stWatches:
        # Watches are evaluated server-side and returned as part of
        # the locals response. For now, return an empty seq; watch
        # results will be populated when the backend supports them.
        newSeq[Variable]()

    # Derived: loading indicator.
    let isLoading = createMemo[bool] proc(): bool =
      store.locals.loadingState.val == lsLoading

    # Derived: pre-formatted code-state-line text. The view uses the
    # presence of this string to decide between the populated and the
    # ``no-code`` fallback markup. Wrapped through a memo so any future
    # transformation (e.g. truncation or HTML escaping) has a single
    # site, and so the view's reactive reads observe a stable signal.
    let codeStateLine = createMemo[string] proc(): string =
      store.locals.codeStateLine.val

    let vm = StateVM(
      store: store,
      collabCore: collabCore,
      runtimeRole: runtimeRole,
      activeTab: activeTab,
      expandedPaths: expandedPaths,
      selectedPath: selectedPath,
      watchExpressions: watchExpressions,
      currentVariables: currentVariables,
      isLoading: isLoading,
      codeStateLine: codeStateLine,
      expandedOrigins: expandedOrigins,
      breadcrumbStack: breadcrumbStack,
      originSummaries: originSummaries,
      originPreferences: originPreferences,
      disposeProc: dispose,
    )

    createEffect proc() =
      let dbg = store.debugger.val
      let watches = watchExpressions.val
      if not mayIssueBackendCommands(runtimeRole):
        return
      store.requestLocals(dbg.rrTicks, watchExpressions = watches)

    vm
