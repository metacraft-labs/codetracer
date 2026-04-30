## viewmodels/calltrace_vm.nim
##
## CalltraceVM — ViewModel for the Calltrace panel.
##
## Holds reactive state for:
## - Scroll position and viewport height (viewport-based loading)
## - Which calltrace entry is selected
## - Which nodes are expanded/collapsed
## - Search query within the calltrace
##
## Derives:
## - `visibleLines`: the slice of CallLine entries that the viewport should render
## - `hasMoreAbove`: whether there are calltrace entries above the viewport
## - `hasMoreBelow`: whether there are calltrace entries below the viewport
## - `highlightedMatches`: indices of lines matching the search query
## - `isLoading`: whether the store is currently fetching calltrace data
##
## Also creates an auto-load effect that calls `store.requestCalltraceSection`
## whenever scrollPosition or viewportHeight change, so the panel always
## displays data for the current scroll region.
##
## Usage:
##   let vm = createCalltraceVM(store)
##   echo vm.scrollPosition.val     # 0
##   vm.scroll(100)
##   echo vm.visibleLines.val       # lines around index 100

import std/[json, sets, options, strutils]

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ../backend/backend_service
import ../store/[replay_data_store, request_tracker, types]

const
  ## Default panel depth (columns) used when requesting calltrace sections.
  ## The real UI computes this from the panel's pixel width; the VM uses a
  ## sensible default that the view layer can override via viewportDepth.
  DEFAULT_VIEWPORT_DEPTH* = 20

  ## Number of extra rows to request above and below the visible viewport.
  ## Keeps scrolling smooth by pre-fetching nearby data.
  CALLTRACE_BUFFER* = 20

type
  CalltraceVM* = ref object of ViewModel
    ## Reactive state for the Calltrace panel.
    ##
    ## Mutable signals:
    ##   scrollPosition     — first visible line index
    ##   viewportHeight     — number of visible rows in the panel
    ##   viewportDepth      — column depth of the panel (for indentation)
    ##   selectedEntry      — index of the selected calltrace line, or none
    ##   expandedNodes      — set of line indices whose children are visible
    ##   searchQuery        — current search/filter text
    ##   rawIgnorePatterns  — filter patterns for calltrace (e.g. "path~lib/system")
    ##
    ## Derived memos:
    ##   visibleLines       — the CallLine seq for the current viewport
    ##   hasMoreAbove       — whether entries exist above the viewport
    ##   hasMoreBelow       — whether entries exist below the viewport
    ##   highlightedMatches — indices of lines whose name matches searchQuery
    ##   isLoading          — whether a calltrace request is in flight
    ##
    ## The store reference is kept for the auto-load effect and for
    ## navigation actions (double-click jumps).
    store*: ReplayDataStore

    # -- Mutable state --
    scrollPosition*: Signal[int64]
    viewportHeight*: Signal[int]
    viewportDepth*: Signal[int]
    selectedEntry*: Signal[Option[int64]]
    expandedNodes*: Signal[HashSet[int64]]
    searchQuery*: Signal[string]
    rawIgnorePatterns*: Signal[string]

    # -- Backend search results --
    # Populated by the legacy calltrace component when it receives
    # CtCalltraceSearchResponse. Each entry is (name, rrTicks, key)
    # matching what the Karax search results view shows.
    backendSearchResults*: Signal[seq[tuple[name: string, rrTicks: int, key: string]]]

    # -- Derived state --
    visibleLines*: Memo[seq[CallLine]]
    hasMoreAbove*: Memo[bool]
    hasMoreBelow*: Memo[bool]
    highlightedMatches*: Memo[seq[int64]]
    isLoading*: Memo[bool]

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

proc scroll*(vm: CalltraceVM; position: int64) =
  ## Update the scroll position. The auto-load effect watches this signal
  ## and will trigger a `store.requestCalltraceSection` when it changes.
  if position < 0:
    vm.scrollPosition.val = 0'i64
  else:
    vm.scrollPosition.val = position

proc selectEntry*(vm: CalltraceVM; lineIndex: Option[int64]) =
  ## Set the currently selected calltrace entry.
  ## Pass `none(int64)` to clear the selection.
  vm.selectedEntry.val = lineIndex

proc toggleExpand*(vm: CalltraceVM; lineIndex: int64) =
  ## Toggle whether a calltrace node is expanded or collapsed.
  ## If the index is currently in the expanded set it is removed;
  ## otherwise it is added.
  var nodes = vm.expandedNodes.val
  if lineIndex in nodes:
    nodes.excl(lineIndex)
  else:
    nodes.incl(lineIndex)
  vm.expandedNodes.val = nodes

proc toggleExpandCallChildren*(vm: CalltraceVM; lineIndex: int64) =
  ## Send an expand or collapse request to the backend for the calltrace
  ## entry at `lineIndex`. Looks up the line in the store to determine
  ## its current expand state and call key, then sends the appropriate
  ## DAP command ("ct/expand-calls" or "ct/collapse-calls").
  ##
  ## After changing the expand state, sends a calltrace section reload
  ## request so the backend returns the updated line data. This matches
  ## the legacy Karax pattern: toggleCalls() + loadLines().
  let lines = vm.store.calltrace.lines.val
  let startIdx = vm.store.calltrace.startLineIndex.val
  let offset = lineIndex - startIdx
  if offset >= 0 and offset < lines.len.int64:
    let line = lines[offset.int]
    if not line.hasChildren:
      return
    let command = if line.isExpanded: "ct/collapse-calls" else: "ct/expand-calls"
    # nonExpandedKind is serialized as a u8 ordinal:
    #   Callstack=0, Children=1, Siblings=2, Calls=3,
    #   CallstackInternal=4, CallstackInternalChild=5
    let toggleArgs = %*{
      "callKey": line.callKey,
      "nonExpandedKind": 1,  # Children
      "count": 0,
    }
    discard vm.store.backend.send(command, toggleArgs)

    # Reload the calltrace section. Clear the request tracker first so
    # the store doesn't deduplicate this as a redundant request (the
    # auto-load effect may have already sent the same parameters).
    vm.store.requestTracker.markComplete("load-calltrace")
    let scrollPos = vm.scrollPosition.val
    let vpHeight = vm.viewportHeight.val
    let depth = vm.viewportDepth.val
    let dbg = vm.store.debugger.val
    let patterns = vm.rawIgnorePatterns.val
    let effectiveHeight = if vpHeight > 0: vpHeight else: 50
    let bufferStart = max(0'i64, scrollPos - CALLTRACE_BUFFER.int64)
    let totalHeight = effectiveHeight + CALLTRACE_BUFFER * 2
    vm.store.requestCalltraceSection(
      bufferStart, totalHeight, depth,
      rrTicks = dbg.rrTicks,
      file = dbg.location.file,
      line = dbg.location.line,
      rawIgnorePatterns = patterns,
    )

proc doubleClickEntry*(vm: CalltraceVM; lineIndex: int64) =
  ## Navigate to the source location of the calltrace entry at `lineIndex`.
  ## Looks up the line in the store's calltrace data and sends a
  ## navigation command via the backend.
  let lines = vm.store.calltrace.lines.val
  let startIdx = vm.store.calltrace.startLineIndex.val
  let offset = lineIndex - startIdx
  if offset >= 0 and offset < lines.len.int64:
    let line = lines[offset.int]
    # The backend expects a Location struct with camelCase field names:
    #   path (not file), line, rrTicks, highLevelPath, highLevelLine, etc.
    let args = %*{
      "path": line.location.file,
      "line": line.location.line,
      "highLevelPath": line.location.file,
      "highLevelLine": line.location.line,
      "rrTicks": line.rrTicks,
    }
    discard vm.store.backend.send("ct/calltrace-jump", args)

proc setSearchQuery*(vm: CalltraceVM; query: string) =
  ## Update the search query. Sends the query to the backend via
  ## ct/search-calltrace and also updates the local highlightedMatches.
  ## The backend response arrives via registerSearchRes in calltrace.nim
  ## which calls setBackendSearchResults.
  vm.searchQuery.val = query

  # Also send the query to the backend for full-trace search.
  if query.len > 0:
    let args = %*{"value": query}
    discard vm.store.backend.send("ct/search-calltrace", args)

proc setBackendSearchResults*(vm: CalltraceVM;
    results: seq[tuple[name: string, rrTicks: int, key: string]]) =
  ## Update the backend search results. Called by the legacy calltrace
  ## component when it receives CtCalltraceSearchResponse.
  vm.backendSearchResults.val = results

proc setViewportHeight*(vm: CalltraceVM; height: int) =
  ## Update the viewport height (number of visible rows).
  ## Triggers the auto-load effect if the value changes.
  if height > 0:
    vm.viewportHeight.val = height

proc setViewportDepth*(vm: CalltraceVM; depth: int) =
  ## Update the viewport depth (number of indentation columns).
  if depth > 0:
    vm.viewportDepth.val = depth

proc setRawIgnorePatterns*(vm: CalltraceVM; patterns: string) =
  ## Update the calltrace filter patterns (e.g. "path~lib/system;path~chronicles").
  ## Triggers the auto-load effect if the value changes.
  vm.rawIgnorePatterns.val = patterns

# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

proc createCalltraceVM*(store: ReplayDataStore): CalltraceVM =
  ## Create a CalltraceVM inside a reactive root owned by `withViewModel`.
  ## The reactive root is disposed via `vm.dispose()`.
  ##
  ## Sets up:
  ## 1. Mutable signals with sensible defaults
  ## 2. Derived memos for visibleLines, hasMore*, highlightedMatches, isLoading
  ## 3. An auto-load effect that requests calltrace data when scroll/viewport changes
  when defined(js):
    {.emit: "console.error('[PIPELINE] createCalltraceVM: using store id=' + `store`.storeId);".}
  withViewModel proc(dispose: proc()): CalltraceVM =
    let wrappedDispose = proc() =
      when defined(js):
        {.emit: "console.error('[PIPELINE] CalltraceVM DISPOSED! This should only happen on cleanup.');".}
      dispose()

    let scrollPosition = createSignal(0'i64)
    let viewportHeight = createSignal(0)
    let viewportDepth = createSignal(DEFAULT_VIEWPORT_DEPTH)
    let selectedEntry = createSignal(none(int64))
    let expandedNodes = createSignal(initHashSet[int64]())
    let searchQuery = createSignal("")
    let rawIgnorePatterns = createSignal("")

    # Derived: extract the slice of lines that falls within the viewport.
    # The store holds a window of lines starting at `startLineIndex`.
    # We compute which of those fall within [scrollPosition, scrollPosition + viewportHeight).
    let visibleLines = createMemo[seq[CallLine]] proc(): seq[CallLine] =
      let lines = store.calltrace.lines.val
      let storeStart = store.calltrace.startLineIndex.val
      let scrollPos = scrollPosition.val
      let vpHeight = viewportHeight.val

      let diagStoreIdVL = store.storeId
      when defined(js):
        {.emit: "console.error('[PIPELINE] visibleLines memo: storeId=' + `diagStoreIdVL` + ' lines.len=' + `lines`.length + ' storeStart=' + `storeStart` + ' scrollPos=' + `scrollPos` + ' vpHeight=' + `vpHeight`);".}

      if lines.len == 0:
        when defined(js):
          {.emit: "console.error('[PIPELINE] visibleLines memo: returning empty (no lines in store)');".}
        return newSeq[CallLine]()

      # When viewport height is not yet known (e.g. before the resize
      # observer fires), show all available lines so the calltrace is
      # visible immediately. Playwright tests query `.calltrace-call-line`
      # right after the data arrives, so returning empty here would cause
      # test timeouts.
      let effectiveHeight = if vpHeight <= 0: lines.len else: vpHeight

      # Calculate which portion of the store's lines falls within the viewport.
      # The store holds lines [storeStart .. storeStart + lines.len - 1].
      # The viewport wants lines [scrollPos .. scrollPos + effectiveHeight - 1].
      let viewStart = max(scrollPos, storeStart)
      let viewEnd = min(scrollPos + effectiveHeight.int64 - 1,
                        storeStart + lines.len.int64 - 1)

      if viewStart > viewEnd:
        return newSeq[CallLine]()

      let sliceStart = (viewStart - storeStart).int
      let sliceEnd = (viewEnd - storeStart).int
      result = lines[sliceStart .. sliceEnd]
      when defined(js):
        {.emit: "console.error('[PIPELINE] visibleLines memo: returning ' + `result`.length + ' lines (slice ' + `sliceStart` + '..' + `sliceEnd` + ')');".}

    # Derived: whether there are entries above the current viewport.
    let hasMoreAbove = createMemo[bool] proc(): bool =
      scrollPosition.val > 0

    # Derived: whether there are entries below the current viewport.
    let hasMoreBelow = createMemo[bool] proc(): bool =
      let total = store.calltrace.totalCallsCount.val
      if total == 0:
        return false
      let scrollPos = scrollPosition.val
      let vpHeight = viewportHeight.val
      (scrollPos + vpHeight.int64) < total.int64

    # Derived: indices of lines whose name contains the search query.
    let highlightedMatches = createMemo[seq[int64]] proc(): seq[int64] =
      let query = searchQuery.val
      if query.len == 0:
        return newSeq[int64]()
      let lines = store.calltrace.lines.val
      let storeStart = store.calltrace.startLineIndex.val
      let lowerQuery = query.toLowerAscii()
      result = newSeq[int64]()
      for i, line in lines:
        if lowerQuery in line.name.toLowerAscii():
          result.add(storeStart + i.int64)

    # Derived: loading indicator.
    let isLoading = createMemo[bool] proc(): bool =
      store.calltrace.loadingState.val == lsLoading

    let backendSearchResults = createSignal(newSeq[tuple[name: string, rrTicks: int, key: string]]())

    let vm = CalltraceVM(
      store: store,
      scrollPosition: scrollPosition,
      viewportHeight: viewportHeight,
      viewportDepth: viewportDepth,
      selectedEntry: selectedEntry,
      expandedNodes: expandedNodes,
      searchQuery: searchQuery,
      rawIgnorePatterns: rawIgnorePatterns,
      backendSearchResults: backendSearchResults,
      visibleLines: visibleLines,
      hasMoreAbove: hasMoreAbove,
      hasMoreBelow: hasMoreBelow,
      highlightedMatches: highlightedMatches,
      isLoading: isLoading,
      disposeProc: dispose,
    )

    # Auto-load effect: whenever scrollPosition, viewportHeight, or the
    # debugger's rrTicks position changes, request the appropriate
    # calltrace section from the backend.  This replaces the old
    # scroll-handler + loadLines pattern and the loadLines call in
    # onCompleteMove.  The debugger position is watched so that a move
    # (step/jump) automatically triggers a fresh calltrace request,
    # mirroring the same pattern used by the StateVM's auto-load effect.
    createEffect proc() =
      let scrollPos = scrollPosition.val
      let vpHeight = viewportHeight.val
      let depth = viewportDepth.val
      let dbg = store.debugger.val
      let patterns = rawIgnorePatterns.val
      let diagRrTicks = dbg.rrTicks
      let diagStoreId = store.storeId
      when defined(js):
        {.emit: "console.error('[PIPELINE] CalltraceVM.autoLoad: storeId=' + `diagStoreId` + ' rrTicks=' + `diagRrTicks` + ' vpHeight=' + `vpHeight` + ' scrollPos=' + `scrollPos` + ' depth=' + `depth`);".}
      # No rrTicks guard — DB-based traces always have rrTicks=0.
      # RequestTracker deduplicates redundant backend requests.
      let effectiveHeight = if vpHeight > 0: vpHeight else: 50
      let bufferStart = max(0'i64, scrollPos - CALLTRACE_BUFFER.int64)
      let totalHeight = effectiveHeight + CALLTRACE_BUFFER * 2
      store.requestCalltraceSection(
        bufferStart, totalHeight, depth,
        rrTicks = dbg.rrTicks,
        file = dbg.location.file,
        line = dbg.location.line,
        rawIgnorePatterns = patterns,
      )

    vm
