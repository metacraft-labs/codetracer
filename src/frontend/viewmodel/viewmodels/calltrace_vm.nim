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
import ../store/[replay_data_store, types]

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

proc doubleClickEntry*(vm: CalltraceVM; lineIndex: int64) =
  ## Navigate to the source location of the calltrace entry at `lineIndex`.
  ## Looks up the line in the store's calltrace data and sends a
  ## navigation command via the backend.
  let lines = vm.store.calltrace.lines.val
  let startIdx = vm.store.calltrace.startLineIndex.val
  let offset = lineIndex - startIdx
  if offset >= 0 and offset < lines.len.int64:
    let line = lines[offset.int]
    let args = %*{
      "file": line.location.file,
      "line": line.location.line,
      "rrTicks": line.rrTicks,
    }
    discard vm.store.backend.send("ct/calltrace-jump", args)

proc setSearchQuery*(vm: CalltraceVM; query: string) =
  ## Update the search query. The `highlightedMatches` memo will
  ## recompute automatically.
  vm.searchQuery.val = query

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
  withViewModel proc(dispose: proc()): CalltraceVM =
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

      if lines.len == 0 or vpHeight <= 0:
        return newSeq[CallLine]()

      # Calculate which portion of the store's lines falls within the viewport.
      # The store holds lines [storeStart .. storeStart + lines.len - 1].
      # The viewport wants lines [scrollPos .. scrollPos + vpHeight - 1].
      let viewStart = max(scrollPos, storeStart)
      let viewEnd = min(scrollPos + vpHeight.int64 - 1,
                        storeStart + lines.len.int64 - 1)

      if viewStart > viewEnd:
        return newSeq[CallLine]()

      let sliceStart = (viewStart - storeStart).int
      let sliceEnd = (viewEnd - storeStart).int
      result = lines[sliceStart .. sliceEnd]

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

    let vm = CalltraceVM(
      store: store,
      scrollPosition: scrollPosition,
      viewportHeight: viewportHeight,
      viewportDepth: viewportDepth,
      selectedEntry: selectedEntry,
      expandedNodes: expandedNodes,
      searchQuery: searchQuery,
      rawIgnorePatterns: rawIgnorePatterns,
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
      if vpHeight > 0 and dbg.rrTicks > 0'u64:
        # Request a section with buffer on both sides for smooth scrolling.
        let bufferStart = max(0'i64, scrollPos - CALLTRACE_BUFFER.int64)
        let totalHeight = vpHeight + CALLTRACE_BUFFER * 2
        store.requestCalltraceSection(
          bufferStart, totalHeight, depth,
          rrTicks = dbg.rrTicks,
          file = dbg.location.file,
          line = dbg.location.line,
          rawIgnorePatterns = patterns,
        )

    vm
