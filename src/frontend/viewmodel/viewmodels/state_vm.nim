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
## Also creates an auto-load effect that calls `store.requestLocals`
## whenever the debugger's rrTicks position changes, so the panel
## always shows data for the current execution point.
##
## Usage:
##   let vm = createStateVM(store)
##   echo vm.activeTab.val        # stLocals
##   vm.selectTab(stGlobals)
##   echo vm.currentVariables.val # globals from the store

import std/sets

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ../store/[replay_data_store, types]

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

    # -- Mutable state --
    activeTab*: Signal[StateTab]
    expandedPaths*: Signal[HashSet[string]]
    selectedPath*: Signal[string]
      ## Empty string means "no selection".
    watchExpressions*: Signal[seq[string]]

    # -- Derived state --
    currentVariables*: Memo[seq[Variable]]
    isLoading*: Memo[bool]

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

proc selectTab*(vm: StateVM; tab: StateTab) =
  ## Switch to a different tab. The `currentVariables` memo updates
  ## automatically because it depends on `activeTab`.
  vm.activeTab.val = tab

proc toggleExpand*(vm: StateVM; path: string) =
  ## Toggle whether a variable path is expanded or collapsed.
  ## If the path is currently in the expanded set it is removed;
  ## otherwise it is added.
  var paths = vm.expandedPaths.val
  if path in paths:
    paths.excl(path)
  else:
    paths.incl(path)
  vm.expandedPaths.val = paths

proc selectPath*(vm: StateVM; path: string) =
  ## Set the currently selected variable path.
  ## Pass an empty string to clear the selection.
  vm.selectedPath.val = path

proc addWatch*(vm: StateVM; expression: string) =
  ## Add a watch expression. Duplicates are silently ignored.
  ## After adding, the auto-load effect will re-request locals with
  ## the updated watch list on the next rrTicks change.
  if expression.len == 0:
    return
  var exprs = vm.watchExpressions.val
  for existing in exprs:
    if existing == expression:
      return
  exprs.add(expression)
  vm.watchExpressions.val = exprs

proc removeWatch*(vm: StateVM; expression: string) =
  ## Remove a watch expression by value. No-op if not found.
  var exprs = vm.watchExpressions.val
  var idx = -1
  for i, e in exprs:
    if e == expression:
      idx = i
      break
  if idx >= 0:
    exprs.delete(idx)
    vm.watchExpressions.val = exprs

# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

proc createStateVM*(store: ReplayDataStore): StateVM =
  ## Create a StateVM inside a reactive root owned by `withViewModel`.
  ## The reactive root is disposed via `vm.dispose()`.
  ##
  ## Sets up:
  ## 1. Mutable signals with sensible defaults
  ## 2. Derived memos for `currentVariables` and `isLoading`
  ## 3. An auto-load effect that requests locals when rrTicks changes
  withViewModel proc(dispose: proc()): StateVM =
    let activeTab = createSignal(stLocals)
    let expandedPaths = createSignal(initHashSet[string]())
    let selectedPath = createSignal("")
    let watchExpressions = createSignal(newSeq[string]())

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

    let vm = StateVM(
      store: store,
      activeTab: activeTab,
      expandedPaths: expandedPaths,
      selectedPath: selectedPath,
      watchExpressions: watchExpressions,
      currentVariables: currentVariables,
      isLoading: isLoading,
      disposeProc: dispose,
    )

    # Auto-load effect: whenever rrTicks or watchExpressions change,
    # request fresh locals.  This replaces the legacy `loadLocals()`
    # call that used to happen inside `onMove` / `onCompleteMove`.
    createEffect proc() =
      let ticks = store.debugger.val.rrTicks
      let watches = watchExpressions.val
      let diagStoreId = store.storeId
      {.emit: "console.error('[PIPELINE] StateVM.autoLoad: storeId=' + `diagStoreId` + ' rrTicks=' + `ticks` + ' watches=' + `watches`.length);".}
      # No rrTicks guard — DB-based traces always have rrTicks=0.
      # RequestTracker deduplicates redundant backend requests.
      store.requestLocals(ticks, watchExpressions = watches)

    vm
