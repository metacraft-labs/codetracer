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
## Degraded state (Page-Descriptions.md §14):
## - `degradedState`: resolved against `CalltracePaneDegradations`; a
##   truncated trace's call tree ends before the execution did
##
## Usage:
##   let vm = createCalltraceVM(store)
##   echo vm.scrollPosition.val     # 0
##   vm.scroll(100)
##   echo vm.visibleLines.val       # lines around index 100

import std/[json, sets, options, strutils, tables]
# Diagnostics go through `vm_log`, not the renderer's `lib/logging`: that
# module reaches `dom`/`kdom` and would put a DOM shim in the Embed SDK's
# package graph (CodeTracer-Embed-SDK.md §3.2). See vm_log.nim.
import ../vm_log

import isonim/core/[signals, computation, owner]
import isonim/viewmodel

import ../backend/backend_service
import ../collab/[runtime_role, session_core, types]
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
    collabCore*: CollaborativeSessionCore
    runtimeRole*: ViewModelRuntimeRole

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

    # -- Measured layout --
    # Actual rendered row height in CSS pixels, measured from the DOM after
    # the first batch of rows renders and updated on every zoom/resize.
    # Defaults to 24.0 (the legacy CALL_HEIGHT_PX constant) until measured.
    # Used by the view to compute the virtual-scroll container height
    # (totalCallsCount * rowHeightPx) and the translateY offset
    # (startLineIndex * rowHeightPx) so the loaded window is positioned
    # correctly regardless of font-size / em scaling.
    rowHeightPx*: Signal[float]

    # -- The call-stack fallback (PLAT-47) --
    fallbackStack*: Signal[seq[string]]
      ## The frames of the call STACK at the current stop, innermost first,
      ## set by a host ONLY when the recording provides no call trace (the
      ## store's `calltrace.lines` is empty after the host asked). A pane that
      ## has no trace to list shows these instead and says so — the terminal's
      ## and GPUI's calltrace panes; the desktop does not read it. Empty
      ## whenever the recording has a trace.

    # -- Derived state --
    visibleLines*: Memo[seq[CallLine]]
    hasMoreAbove*: Memo[bool]
    hasMoreBelow*: Memo[bool]
    highlightedMatches*: Memo[seq[int64]]
    isLoading*: Memo[bool]

    # -- Degraded state (Page-Descriptions.md §14) --
    degradedState*: Memo[PaneDegradation]
      ## Resolved against `CalltracePaneDegradations`. The row that
      ## matters most here is `pdTraceTruncated`: a truncated trace's
      ## call tree ends before the execution did, and a pane that renders
      ## it as an ordinary end of trace is making a false claim about the
      ## program.

# ---------------------------------------------------------------------------
# PLAT-49 part B (finding 8): ONE CALL ROW, SEMANTICALLY
# ---------------------------------------------------------------------------
#
# The desktop's calltrace row (`views/isonim_calltrace_view.renderCallLineRowWeb`)
# is: a depth offset; a toggle (`.collapse-call-img` / `.expand-call-img` /
# `.dot-call-img`); `.call-text` — `name #index`; `.call-args` — `(` then each
# `.call-arg` as `name=` + value, `, ` between them, `)`; and `.return` — ` => `
# and the return value when the call returned one. Selected, the row is
# `.event-selected` and its toggle `.active`.
#
# The terminal used to draw `name #index` and nothing else, and GPUI a plain
# list label. `CallRow` is that row as DATA — callee, arguments with their
# values, return value, depth, toggle state, flags — and `callRowSegments` its
# breakdown into typed runs, so every front-end draws the same parts and styles
# each by its KIND, the way the desktop's stylesheet styles each class.

type
  CallRowToggle* = enum
    ## The desktop's toggle icon.
    crtLeaf = "leaf"
      ## `.dot-call-img`: the call made no calls.
    crtExpanded = "expanded"
      ## `.collapse-call-img`: its children are listed below it.
    crtCollapsed = "collapsed"
      ## `.expand-call-img`: it has children, hidden.

  CallRowArg* = object
    name*: string
    value*: string
      ## The argument's value as the `calltrace-arg` presentation budget
      ## renders it (one line) — the desktop's `.call-arg-text`.

  CallRowFlag* = enum
    crfSelected = "selected"
      ## The selected row (`.event-selected`).
    crfCurrent = "current"
      ## The call the debugger is in.

  CallRow* = object
    ## One call-trace row, as data.
    index*: int64
    depth*: int
    callee*: string
      ## `displayName` when set, else `name` — the desktop's `callDisplayName`.
    args*: seq[CallRowArg]
    returnValue*: string
    hasReturn*: bool
      ## The call returned a value to show (`.return`'s ` => value`).
    toggle*: CallRowToggle
    flags*: set[CallRowFlag]
    rrTicks*: uint64
    file*: string
    line*: int

  CallSegmentKind* = enum
    ## The parts of a row, each styled by kind (the desktop's classes).
    csIndent = "indent"
    csToggle = "toggle"
    csCallee = "callee"           ## `.call-text`'s name
    csIndex = "index"             ## `.call-text`'s ` #N`
    csPunct = "punct"             ## `(`, `)`, `=`, `, `
    csArgName = "argName"         ## `.call-arg-name`
    csArgValue = "argValue"       ## `.call-arg-text`
    csReturnArrow = "returnArrow" ## `.return-arrow`
    csReturnValue = "returnValue" ## `.return-text`

  CallSegment* = object
    kind*: CallSegmentKind
    text*: string
    arg*: int
      ## PLAT-50: which argument a part belongs to — 1-based into the row's
      ## `args` (its name, its `=`, its value: the desktop's `.call-arg`),
      ## 0 for a part of no argument.

const
  ReturnArgName* = "__return"
    ## The `CallArg` that carries a call's return value beside its arguments
    ## — the desktop view's convention (`returnValueForRow`), which both
    ## decoders now fill from the call's `returnValue`.
  CallRowIndentCells* = 2
    ## A text medium's indent per depth level.
  CallToggleGlyphs*: array[CallRowToggle, string] = ["·", "▾", "▸"]
    ## A text medium's toggles: the desktop's dot, collapse and expand icons.

func callRowOf*(line: CallLine; args: seq[CallArg];
                selected: Option[int64] = none(int64);
                current = false): CallRow =
  ## THE ROW, from a `CallLine` and its call's `CallArg`s (the store's
  ## `calltrace.args[line.callKey]`).
  result = CallRow(
    index: line.index, depth: max(0, line.depth),
    callee: (if line.displayName.len > 0: line.displayName else: line.name),
    toggle: (if not line.hasChildren: crtLeaf
             elif line.isExpanded: crtExpanded
             else: crtCollapsed),
    rrTicks: line.rrTicks, file: line.location.file,
    line: line.location.line)
  for a in args:
    if a.name == ReturnArgName:
      result.returnValue = a.text
      result.hasReturn = a.text.len > 0
    else:
      result.args.add CallRowArg(name: a.name, value: a.text)
  if selected.isSome and selected.get == line.index:
    result.flags.incl crfSelected
  if current:
    result.flags.incl crfCurrent

func callRowSegments*(r: CallRow; indent = true): seq[CallSegment] =
  ## The row's parts in order: indent, toggle, callee, index, the argument
  ## list (always, `()` for none — the desktop's `.call-args` draws the
  ## parentheses for every row), and ` => value` when the call returned one.
  if indent and r.depth > 0:
    result.add CallSegment(kind: csIndent,
                           text: repeat(" ", r.depth * CallRowIndentCells))
  result.add CallSegment(kind: csToggle, text: CallToggleGlyphs[r.toggle])
  result.add CallSegment(kind: csPunct, text: " ")
  result.add CallSegment(kind: csCallee, text: r.callee)
  result.add CallSegment(kind: csIndex, text: " #" & $r.index)
  result.add CallSegment(kind: csPunct, text: "(")
  for i, a in r.args:
    if i > 0:
      result.add CallSegment(kind: csPunct, text: ", ")
    result.add CallSegment(kind: csArgName, text: a.name, arg: i + 1)
    result.add CallSegment(kind: csPunct, text: "=", arg: i + 1)
    result.add CallSegment(kind: csArgValue, text: a.value, arg: i + 1)
  result.add CallSegment(kind: csPunct, text: ")")
  if r.hasReturn:
    result.add CallSegment(kind: csReturnArrow, text: " => ")
    result.add CallSegment(kind: csReturnValue, text: r.returnValue)

func callRowText*(r: CallRow; indent = false): string =
  ## The row as one string — what the desktop's row reads as text
  ## (`.call-text` + `.call-args` + `.return`), without the toggle icon.
  for seg in r.callRowSegments(indent):
    if seg.kind notin {csToggle}:
      result.add seg.text
  result = result.strip(leading = true, trailing = false)

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
  if not vm.collabCore.isNil:
    let entryId = if lineIndex.isSome: $lineIndex.get else: ""
    discard vm.collabCore.dispatchLocalViewOp(
      vokSetCalltraceSelection,
      "calltrace.selectedEntry",
      %*{"entryId": entryId},
    )
    return
  vm.selectedEntry.val = lineIndex

proc toggleExpand*(vm: CalltraceVM; lineIndex: int64) =
  ## Toggle whether a calltrace node is expanded or collapsed.
  ## If the index is currently in the expanded set it is removed;
  ## otherwise it is added.
  if not vm.collabCore.isNil:
    let id = $lineIndex
    let expanded = not (lineIndex in vm.expandedNodes.val)
    let observedAddTags =
      if expanded: @[]
      else: vm.collabCore.liveAddTags(
        vm.collabCore.document.state.calltrace.expandedNodes, id)
    discard vm.collabCore.dispatchLocalViewOp(
      vokToggleCalltraceExpansion,
      "calltrace.expandedNodes",
      %*{
        "id": id,
        "expanded": expanded,
        "observedAddTags": observedAddTags,
      },
    )
    return
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
      "callstackDepth": line.location.callstackDepth,
      "sourceGeneration": line.location.sourceGeneration,
      "sourceDigest": line.location.sourceDigest,
      "codeGeneration": line.codeGeneration,
    }
    vm.store.requestHistoricalNavigation("ct/calltrace-jump", args)

proc setSearchQuery*(vm: CalltraceVM; query: string) =
  ## Update the search query. Sends the query to the backend via
  ## ct/search-calltrace and also updates the local highlightedMatches.
  ## The backend response arrives via registerSearchRes in calltrace.nim
  ## which calls setBackendSearchResults.
  if not vm.collabCore.isNil:
    discard vm.collabCore.dispatchLocalViewOp(
      vokSetCalltraceSearch,
      "calltrace.searchQuery",
      %*{"query": query},
    )
  else:
    vm.searchQuery.val = query

  if not mayIssueBackendCommands(vm.runtimeRole):
    return

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

proc setRowHeightPx*(vm: CalltraceVM; h: float) =
  ## Update the measured row height in CSS pixels.  Called from the view after
  ## the first batch of rows renders and whenever a zoom or resize is detected.
  ## Only updates the signal when the value meaningfully changes (> 0.5 px
  ## delta) to avoid oscillating reactive cycles from sub-pixel rounding.
  if h > 0.0 and abs(h - vm.rowHeightPx.val) > 0.5:
    vm.rowHeightPx.val = h

func currentCallOf*(lines: openArray[CallLine]; tick: uint64;
                    stack: openArray[string]): Option[int64] =
  ## THE CALL THE DEBUGGER IS IN, among `lines`, at `tick` with the call
  ## STACK `stack` (innermost first): the last line entered at or before
  ## `tick` whose name is the innermost frame's and whose depth is the
  ## stack's (`stack.len - 1`, the trace's root being depth 0). A call that
  ## already returned was entered before `tick` too, so "the last line
  ## entered" alone would name `mul` while the debugger is back in `main`;
  ## with no stack, it is that fallback. `none` when no line qualifies. The
  ## desktop selects this call on every move (`CalltraceComponent
  ## .onCompleteMove` -> `selectEntry`); the terminal and GPUI mark it from
  ## this rule (PLAT-49 part B).
  var lastEntered = none(int64)
  for l in lines:
    if l.rrTicks > tick:
      continue
    lastEntered = some(l.index)
    let name = if l.displayName.len > 0: l.displayName else: l.name
    if stack.len > 0 and (name == stack[0] or l.name == stack[0]) and
       l.depth == stack.len - 1:
      result = some(l.index)
  if result.isNone and stack.len == 0:
    result = lastEntered

proc callRows*(vm: CalltraceVM): seq[CallRow] =
  ## The visible rows as `CallRow`s, with their arguments and return values
  ## from the store and the selection.
  let args = vm.store.calltrace.args.val
  let selected = vm.selectedEntry.val
  for line in vm.visibleLines.val:
    let a = if line.callKey.len > 0 and line.callKey in args:
              args[line.callKey]
            else: @[]
    result.add callRowOf(line, a, selected)

# ---------------------------------------------------------------------------
# Factory
# ---------------------------------------------------------------------------

proc createCalltraceVM*(store: ReplayDataStore;
                        collabCore: CollaborativeSessionCore = nil;
                        runtimeRole = vrrStandalone): CalltraceVM =
  ## Create a CalltraceVM inside a reactive root owned by `withViewModel`.
  ## The reactive root is disposed via `vm.dispose()`.
  ##
  ## Sets up:
  ## 1. Mutable signals with sensible defaults
  ## 2. Derived memos for visibleLines, hasMore*, highlightedMatches, isLoading
  ## 3. An auto-load effect that requests calltrace data when scroll/viewport changes
  when defined(js):
    vmDebug "[PIPELINE] createCalltraceVM: using store id=" & $store.storeId
  withViewModel proc(dispose: proc()): CalltraceVM =
    let wrappedDispose = proc() =
      when defined(js):
        # Legitimate, hence DEBUG.  This is the dispose path itself:
        # it runs on session teardown and whenever a stub-backed VM is
        # replaced by a real-backend one during `configureMiddleware`.
        # Both are ordinary lifecycle events.  The shouting was a leftover
        # from debugging an unexpected early disposal; the fact that
        # disposal happened is worth tracing, but it is not an error.
        vmDebug "[PIPELINE] CalltraceVM disposed (session teardown or " &
          "stub-to-real-backend VM replacement)"
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

      when defined(js):
        vmDebug "[PIPELINE] visibleLines memo: storeId=" &
          $store.storeId & " lines.len=" & $lines.len & " storeStart=" &
          $storeStart & " scrollPos=" & $scrollPos & " vpHeight=" &
          $vpHeight

      if lines.len == 0:
        when defined(js):
          vmDebug "[PIPELINE] visibleLines memo: returning empty (no lines in store)"
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
      result = newSeq[CallLine]()
      for index in sliceStart .. sliceEnd:
        result.add(lines[index])
      when defined(js):
        vmDebug "[PIPELINE] visibleLines memo: returning " &
          $result.len & " lines (slice " & $sliceStart & ".." &
          $sliceEnd & ")"

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

    # Default 24.0 matches the legacy CALL_HEIGHT_PX constant; updated by the
    # view once rows have rendered so the virtual-scroll math uses the actual
    # em/rem-derived pixel height rather than the compile-time approximation.
    let rowHeightPx = createSignal(24.0)
    let fallbackStack = createSignal(newSeq[string]())

    # Derived: the §14 degraded state this pane renders.
    let degradedState = createMemo[PaneDegradation] proc(): PaneDegradation =
      resolveDegradation(store.degradedSnapshot(), CalltracePaneDegradations)

    let vm = CalltraceVM(
      store: store,
      collabCore: collabCore,
      runtimeRole: runtimeRole,
      scrollPosition: scrollPosition,
      viewportHeight: viewportHeight,
      viewportDepth: viewportDepth,
      selectedEntry: selectedEntry,
      expandedNodes: expandedNodes,
      searchQuery: searchQuery,
      rawIgnorePatterns: rawIgnorePatterns,
      backendSearchResults: backendSearchResults,
      rowHeightPx: rowHeightPx,
      fallbackStack: fallbackStack,
      visibleLines: visibleLines,
      hasMoreAbove: hasMoreAbove,
      hasMoreBelow: hasMoreBelow,
      highlightedMatches: highlightedMatches,
      isLoading: isLoading,
      degradedState: degradedState,
      disposeProc: wrappedDispose,
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
      when defined(js):
        vmDebug "[PIPELINE] CalltraceVM.autoLoad: storeId=" &
          $store.storeId & " rrTicks=" & $dbg.rrTicks & " vpHeight=" &
          $vpHeight & " scrollPos=" & $scrollPos & " depth=" & $depth
      # No rrTicks guard — DB-based traces always have rrTicks=0.
      # RequestTracker deduplicates redundant backend requests.
      if not mayIssueBackendCommands(runtimeRole):
        return
      let effectiveHeight = if vpHeight > 0: vpHeight else: 50
      var bufferStart = max(0'i64, scrollPos - CALLTRACE_BUFFER.int64)
      var totalHeight = effectiveHeight + CALLTRACE_BUFFER * 2
      # When the store already knows the total number of calls (this
      # happens after the first response arrives), expand the request
      # window to cover the entire trace whenever it fits in a
      # generous cap.  The IsoNim WebRenderer renders the full window
      # without DOM virtualization (see `isonim_calltrace_view.nim`
      # `indexEach` over `vm.store.calltrace.lines.val`), so the
      # number of `.calltrace-call-line` elements in the DOM is
      # bounded by the section we ask the backend to send.  Without
      # this expansion, calltrace navigation (Playwright `findEntry`)
      # cannot see entries beyond the initial 25-row viewport on DB
      # traces such as Python / Ruby sudoku, where `solve_sudoku`
      # lives well past row 25 of the global call-line index.  Once a
      # translateY-based virtualised renderer lands the cap can be
      # lowered again.
      #
      # When we're loading the entire trace, also pin `bufferStart=0`.
      # Otherwise scrollPos>BUFFER (after a `calltraceJump` that
      # re-anchors the view inside a function's body) makes the request
      # start mid-trace and the response — even with `height=totalCalls`
      # — only covers `[scrollPos-BUFFER .. totalCalls)`, dropping the
      # caller frames that came before.  Playwright's `findEntry` then
      # races a DOM that lacks the parent function entirely.  See
      # TODO 5.1(a) in the migration handoff.
      const FULL_WINDOW_CAP = 500
      let totalCalls = store.calltrace.totalCallsCount.val
      if totalCalls > 0'u64 and totalCalls.int <= FULL_WINDOW_CAP:
        totalHeight = max(totalHeight, totalCalls.int)
        bufferStart = 0'i64
      store.requestCalltraceSection(
        bufferStart, totalHeight, depth,
        rrTicks = dbg.rrTicks,
        file = dbg.location.file,
        line = dbg.location.line,
        rawIgnorePatterns = patterns,
      )

    vm
