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
##   vm.setViewport(Viewport(rows: 30, firstRow: 100))
##   echo vm.visibleLines.val       # lines around index 100

import std/[json, sets, options, strutils, tables]
# Diagnostics go through `vm_log`, not the renderer's `lib/logging`: that
# module reaches `dom`/`kdom` and would put a DOM shim in the Embed SDK's
# package graph (CodeTracer-Embed-SDK.md §3.2). See vm_log.nim.
import ../vm_log

import isonim/core/[signals, computation, owner, graph, batch]
import isonim/viewmodel

import ../backend/backend_service
import ../collab/[runtime_role, session_core, types]
import ../store/[replay_data_store, request_tracker, types]
import ../viewport
export viewport

const
  ## The depth (columns) asked for while the pane's width is unknown
  ## (`Viewport.cols = 0`). Depth shapes indentation only; the ROWS of an
  ## unmeasured pane are never requested.
  DEFAULT_VIEWPORT_DEPTH* = 20

  ## Rows pre-fetched after the visible ones — `viewport.LeadRows`, kept
  ## under this name for the hosts that page the call trace themselves.
  CALLTRACE_BUFFER* = LeadRows

type
  CalltraceVM* = ref object of ViewModel
    ## Reactive state for the Calltrace panel.
    ##
    ## Mutable signals:
    ##   scrollPosition     — first visible line index
    ##   viewportHeight     — number of visible rows in the panel
    ##   viewportDepth      — column depth of the panel (for indentation)
    ##   selectedEntry      — index of the selected calltrace line, or none
    ##   selectedCallKey    — key of the CALL the selection follows, or ""
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
    viewport*: Signal[Viewport]
      ## What the view was given (`setViewport`). The three signals below
      ## are its parts, kept for the many readers of each.
    viewportGate: ViewportGate
    scrollPosition*: Signal[int64]
    viewportHeight*: Signal[int]
    viewportDepth*: Signal[int]
    selectedEntry*: Signal[Option[int64]]
    selectedCallKey*: Signal[string]
      ## The call the selection (the current-call mark) follows, by
      ## `CallLine.callKey`; "" when it follows none and `selectedEntry` is
      ## a bare index. While a key is held, `selectedEntry` is DERIVED from
      ## it: the index of the loaded line with that key, or `none` when no
      ## loaded line has it. A row position is not a call's identity: a
      ## collapse, an expansion or a filter change gives the index to
      ## another call, and a mark left on it claims the debugger is where
      ## it is not (Click-Navigation.md §3.3, #811). Set by `selectCall`,
      ## and by `toggleExpandCallChildren` for an index selection. Local to
      ## this front end: a selection another participant makes arrives as a
      ## bare row and drops it (`projectCalltraceViewState`).
    expandedNodes*: Signal[HashSet[int64]]
    searchQuery*: Signal[string]
    rawIgnorePatterns*: Signal[string]

    # -- Backend search results --
    # Populated by the legacy calltrace component when it receives
    # CtCalltraceSearchResponse. Each entry is (name, rrTicks, key)
    # matching what the Karax search results view shows.
    backendSearchResults*: Signal[seq[tuple[name: string, rrTicks: int, key: string]]]

    # -- Measured layout --
    # The rows' measured ADVANCE (top to top) in CSS pixels, measured from
    # the DOM after rows render and on every zoom/resize. Not the row box:
    # the two differ on the desktop (~25.28 vs 25 px), and only the advance
    # places the n-th row.
    # Defaults to 24.0 (the legacy CALL_HEIGHT_PX constant) until measured.
    # Used by the view to compute the virtual-scroll container height
    # (totalCallsCount * rowHeightPx) and the translateY offset
    # (startLineIndex * rowHeightPx) so the loaded window is positioned
    # correctly regardless of font-size / em scaling, and by the guide
    # lines, which are laid out one advance per row.
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

proc setViewport*(vm: CalltraceVM; v: Viewport) =
  ## The size and scroll position the view was given — the ONE way a view
  ## tells this ViewModel what it shows (Viewport-Driven-Loading V1). Reports
  ## are debounced on the store's `viewportScheduler`; the auto-load effect
  ## then asks for the window `viewport.listWindow` derives.
  vm.viewportGate.submit(v)

proc callWindowArgs(vm: CalltraceVM): tuple[ok: bool; start: int64;
                                             height, depth: int] =
  ## The window the Electron GUI asks for (`ui/calltrace.nim` `loadLines`):
  ## `TrailRows` above the first visible row and `LeadRows` below the last,
  ## at the pane's measured depth. `ok` is false for an unmeasured pane.
  let v = vm.viewport.val
  let w = listWindow(v)
  if w.count <= 0:
    return (false, 0'i64, 0, 0)
  (true, w.start.int64, w.count,
   if v.cols > 0: v.cols else: DEFAULT_VIEWPORT_DEPTH)

proc requestWindow(vm: CalltraceVM) =
  ## Ask for the window the viewport shows, at the debugger's position, with
  ## the pane's filter.
  let (ok, start, height, depth) = vm.callWindowArgs()
  if not ok:
    return
  let dbg = vm.store.debugger.val
  vm.store.requestCalltraceSection(
    start, height, depth,
    rrTicks = dbg.rrTicks,
    file = dbg.location.file,
    line = dbg.location.line,
    rawIgnorePatterns = vm.rawIgnorePatterns.val,
  )

proc writeSelectedEntry(vm: CalltraceVM; lineIndex: Option[int64]) =
  ## Write `selectedEntry` (through the collaborative session when there is
  ## one), leaving `selectedCallKey` alone.
  if not vm.collabCore.isNil:
    let entryId = if lineIndex.isSome: $lineIndex.get else: ""
    discard vm.collabCore.dispatchLocalViewOp(
      vokSetCalltraceSelection,
      "calltrace.selectedEntry",
      %*{"entryId": entryId},
    )
    return
  vm.selectedEntry.val = lineIndex

func indexOfCall*(lines: openArray[CallLine]; key: string): Option[int64] =
  ## The index of the line among `lines` whose call key is `key`, or `none`
  ## when none is (or `key` is empty).
  if key.len == 0:
    return none(int64)
  for l in lines:
    if l.callKey == key:
      return some(l.index)
  none(int64)

proc followSelectedCall(vm: CalltraceVM) =
  ## Re-derive `selectedEntry` from the held call key against the loaded
  ## lines. Run on every section change and on every `selectCall`; a no-op
  ## while no key is held, so a bare index selection is never rewritten.
  let key = vm.selectedCallKey.val
  if key.len == 0:
    return
  let resolved = indexOfCall(vm.store.calltrace.lines.val, key)
  if resolved != vm.selectedEntry.val:
    vm.writeSelectedEntry(resolved)

proc selectEntry*(vm: CalltraceVM; lineIndex: Option[int64]) =
  ## Set the currently selected calltrace entry by INDEX, and nothing else:
  ## no backend command, no debugger state, no call to follow (it drops a
  ## call `selectCall` was following). The terminal keeps its call-stack
  ## frame cursor in this signal (`call_stack_binding
  ## .publishInspectionCursor`), so an index written here must stay the
  ## index it was. Pass `none(int64)` to clear the selection.
  vm.selectedCallKey.val = ""
  vm.writeSelectedEntry(lineIndex)

proc selectCall*(vm: CalltraceVM; callKey: string) =
  ## Select the call whose key is `callKey` and keep the selection on that
  ## call as sections load: `selectedEntry` is its row while a loaded line
  ## has the key and `none` while none does (Click-Navigation.md §3.3: "A
  ## row that is no longer present retires the mark rather than leaving
  ## the previous one standing"). The desktop marks the debugger's current
  ## call with this (`CalltraceComponent.onCompleteMove`). An empty key
  ## clears the selection.
  if callKey.len == 0:
    vm.selectEntry(none(int64))
    return
  vm.selectedCallKey.val = callKey
  vm.followSelectedCall()

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
    # "Expanding or collapsing a row is not activating it" (Click-
    # Navigation.md §3.3), and an expansion change keeps a row's identity,
    # not its index (Scrollbar-Scrubbers.md §3 item 6). The reload below
    # shifts every row after `line`, so a selection held as a bare index
    # would land on whichever call takes it (#811): follow the selected
    # row's CALL from here on instead.
    if vm.selectedCallKey.val.len == 0 and vm.selectedEntry.val.isSome:
      let selOffset = vm.selectedEntry.val.get - startIdx
      if selOffset >= 0 and selOffset < lines.len.int64:
        vm.selectedCallKey.val = lines[selOffset.int].callKey
    # nonExpandedKind is serialized as a u8 ordinal:
    #   Callstack=0, Children=1, Siblings=2, Calls=3,
    #   CallstackInternal=4, CallstackInternalChild=5
    let toggleArgs = %*{
      "callKey": line.callKey,
      "nonExpandedKind": 1,  # Children
      "count": 0,
    }
    discard vm.store.backend.send(command, toggleArgs)

    # Reload the section: the engine changed it under the SAME arguments,
    # so the request in flight for them (if any) answers the old tree. The
    # entry is cleared whatever it records — this is the one deliberate
    # re-ask of an identical request.
    vm.store.requestTracker.forget("load-calltrace")
    vm.requestWindow()

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
    # At most the pane's window of results (Viewport-Driven-Loading V2);
    # every match from a consumer that has not measured one.
    let args = %*{"value": query}
    let w = listWindow(vm.viewport.val)
    if w.count > 0:
      args["limit"] = %w.count
    discard vm.store.backend.send("ct/search-calltrace", args)

proc setBackendSearchResults*(vm: CalltraceVM;
    results: seq[tuple[name: string, rrTicks: int, key: string]]) =
  ## Update the backend search results. Called by the legacy calltrace
  ## component when it receives CtCalltraceSearchResponse.
  vm.backendSearchResults.val = results

proc setRawIgnorePatterns*(vm: CalltraceVM; patterns: string) =
  ## Update the calltrace filter patterns (e.g. "path~lib/system;path~chronicles").
  ## Triggers the auto-load effect if the value changes.
  vm.rawIgnorePatterns.val = patterns

const RowHeightEpsilonPx* = 0.01
  ## Below this, two measured row advances are the same advance. Browsers lay
  ## out in 1/64 px units and the view averages the advance over every
  ## rendered row, so a stable layout re-measures to well within this.
  ## It must stay far below the per-row error it is meant to see: the
  ## guide lines and the virtual scroll multiply the advance by the row index,
  ## so an ignored difference of d px is d * n px off by row n. (It was
  ## 0.5 px, which let a 24 px default stand in for a 24.4 px advance — 40 px
  ## off by row 100.)

proc setRowHeightPx*(vm: CalltraceVM; h: float) =
  ## Update the measured row advance in CSS pixels.  Called from the view
  ## after rows render, on scroll, and whenever a zoom or resize is detected.
  ## Only updates the signal when the value changes by more than
  ## `RowHeightEpsilonPx`, so re-measuring an unchanged layout re-runs no
  ## effect. Nothing the signal drives changes the rows' own advance, so
  ## publishing a new value cannot feed back into the next measurement.
  if h > 0.0 and abs(h - vm.rowHeightPx.val) > RowHeightEpsilonPx:
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

    let viewport = createSignal(Viewport())
    let scrollPosition = createSignal(0'i64)
    let viewportHeight = createSignal(0)
    let viewportDepth = createSignal(DEFAULT_VIEWPORT_DEPTH)
    let viewportGate = newViewportGate(
      proc(): ViewportScheduler = store.viewportScheduler,
      proc(v: Viewport) =
        batch(proc() =
          viewport.val = v
          scrollPosition.val = max(0, v.firstRow).int64
          viewportHeight.val = max(0, v.rows)
          viewportDepth.val =
            if v.cols > 0: v.cols else: DEFAULT_VIEWPORT_DEPTH))
    let selectedEntry = createSignal(none(int64))
    let selectedCallKey = createSignal("")
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
      viewport: viewport,
      viewportGate: viewportGate,
      scrollPosition: scrollPosition,
      viewportHeight: viewportHeight,
      viewportDepth: viewportDepth,
      selectedEntry: selectedEntry,
      selectedCallKey: selectedCallKey,
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

    # Selection follow effect: whenever a section loads (a collapse, an
    # expansion, a scroll, a filter change, a move), put the selection back
    # on the call it follows, or retire it when the section does not hold
    # that call (`followSelectedCall`).
    createEffect proc() =
      discard store.calltrace.lines.val
      discard selectedCallKey.val
      untrack(proc() = vm.followSelectedCall())

    # Auto-load effect: whenever the viewport, the filter or the debugger's
    # position changes, ask for the window the viewport shows
    # (Viewport-Driven-Loading V2). A move (step/jump) re-asks, as the
    # desktop's `loadLines` in `onCompleteMove` did. An UNMEASURED pane asks
    # nothing: the rows of a pane nobody has sized are not this ViewModel's
    # to guess, and a headless consumer that never renders must not
    # over-fetch. There is no whole-trace load either: the views render the
    # held window inside a scroll area sized from the trace's total.
    createEffect proc() =
      let v = viewport.val
      let dbg = store.debugger.val
      let patterns = rawIgnorePatterns.val
      when defined(js):
        vmDebug "[PIPELINE] CalltraceVM.autoLoad: storeId=" &
          $store.storeId & " rrTicks=" & $dbg.rrTicks & " rows=" &
          $v.rows & " firstRow=" & $v.firstRow & " cols=" & $v.cols &
          " patterns=" & patterns
      # No rrTicks guard — DB-based traces always have rrTicks=0.
      # RequestTracker deduplicates redundant backend requests.
      if not mayIssueBackendCommands(runtimeRole):
        return
      untrack(proc() = vm.requestWindow())

    vm
