## views/isonim_calltrace_view.nim
##
## IsoNim DOM-rendering view for the Calltrace panel.
##
## Renders a live, reactive DOM tree driven by CalltraceVM signals.
## When the VM's signals change (visible lines, selected entry,
## scroll indicators, search query), the DOM updates automatically
## via IsoNim's `createRenderEffect`.
##
## This view is the primary renderer for the Calltrace panel,
## replacing the legacy Karax calltrace component. The DOM structure
## matches the Karax output exactly so that Playwright GUI tests
## continue to find elements via their existing selectors:
##
##   `.calltrace-lines`         — lines container
##   `.calltrace-call-line`     — each call line row
##   `.call-child-box`          — inner box per entry
##   `.call-text`               — function name text (click target)
##   `.toggle-call`             — expand/collapse toggle area
##   `.dot-call-img`            — leaf call marker
##   `.calltrace-search-input`  — search input
##   `.call-search-results`     — search results container
##   `.event-selected`          — selected row CSS class
##   `> span` first child       — depth offset (min-width style)
##
## Generic over the renderer type `R` so that:
## - `MockRenderer` can be used for headless unit tests
## - The web renderer can be used for real browser DOM
##
## Usage (test):
##   let r = MockRenderer()
##   let panel = renderCalltracePanel(r, calltraceVM)
##   check panel.textContent.contains("main")
##
## Usage (web):
##   import isonim/web/web_renderer
##   let r = WebRenderer()
##   let panel = renderCalltracePanel(r, calltraceVM)
##   # panel is an isonim_dom.Element, append to any real DOM container

import std/[json, options, tables, strutils]

import isonim/core/[signals, computation]
import isonim/dsl/components
import isonim/testing/mock_dom  # MockNode type used in generic signatures

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../store/types
import ../backend/backend_service
import ../viewmodels/calltrace_vm

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

proc makeSelectHandler(vm: CalltraceVM; lineIndex: int64): proc() =
  ## Factory to create a click handler with its own closure environment,
  ## avoiding the Nim closure-in-loop capture issue.
  let idx = lineIndex
  result = proc() =
    vm.selectEntry(some(idx))

proc makeDoubleClickHandler(vm: CalltraceVM; lineIndex: int64): proc() =
  ## Factory to create a double-click handler with its own closure environment.
  let idx = lineIndex
  result = proc() =
    vm.doubleClickEntry(idx)

# ---------------------------------------------------------------------------
# Scroll indicator renderers
# ---------------------------------------------------------------------------

proc renderScrollIndicatorAbove*[R, N](r: R; parent: N; vm: CalltraceVM) =
  ## Render the "more above" scroll indicator.
  ## Visible when there are calltrace entries above the viewport.
  let indicator = r.createElement("div")
  r.setAttribute(indicator, "class", "more-above")
  r.appendChild(parent, indicator)

  createRenderEffect proc() =
    r.setStyle(indicator, "display", if vm.hasMoreAbove.val: "block" else: "none")

proc renderScrollIndicatorBelow*[R, N](r: R; parent: N; vm: CalltraceVM) =
  ## Render the "more below" scroll indicator.
  ## Visible when there are calltrace entries below the viewport.
  let indicator = r.createElement("div")
  r.setAttribute(indicator, "class", "more-below")
  r.appendChild(parent, indicator)

  createRenderEffect proc() =
    r.setStyle(indicator, "display", if vm.hasMoreBelow.val: "block" else: "none")

# ---------------------------------------------------------------------------
# Search input renderer
# ---------------------------------------------------------------------------

proc renderSearchInput*[R, N](r: R; parent: N; vm: CalltraceVM) =
  ## Render the search input for filtering calltrace entries.
  let inputRow = r.createElement("div")
  r.setAttribute(inputRow, "class", "calltrace-search-row")
  r.appendChild(parent, inputRow)

  let input = r.createElement("input")
  r.setAttribute(input, "class", "calltrace-search-input")
  r.setAttribute(input, "placeholder", "Search calltrace...")
  r.appendChild(inputRow, input)

  # Note: In a real browser, we would read `input.value` on input events.
  # With MockRenderer, the input value isn't tracked — the actual
  # setSearchQuery call will come from the ViewModel action layer or a
  # higher-level integration. The input is wired up as a placeholder.

# ---------------------------------------------------------------------------
# Call line list renderer
# ---------------------------------------------------------------------------

proc renderCallLineList*[R, N](r: R; parent: N; vm: CalltraceVM) =
  ## Render the calltrace line list container.
  ## Uses indexEach for positional rendering: when the visible lines
  ## change, rows are updated in place or added/removed.
  let container = r.createElement("div")
  r.setAttribute(container, "class", "calltrace-lines")
  r.appendChild(parent, container)

  indexEach[CallLine, R, N](r, container,
    proc(): seq[CallLine] =
      vm.visibleLines.val,
    proc(item: proc(): CallLine, index: int): N =
      let row = r.createElement("div")
      r.setAttribute(row, "class", "call-line")

      createRenderEffect proc() =
        let line = item()

        # Clear and rebuild row content on each update.
        # A more optimised version would use per-field effects.
        r.clearChildren(row)

        # Depth-based indentation via padding-left style
        if line.depth > 0:
          r.setStyle(row, "padding-left", $(line.depth * 16) & "px")
        else:
          r.setStyle(row, "padding-left", "0px")

        # Selected entry highlighting
        let selected = vm.selectedEntry.val
        if selected.isSome and selected.get == line.index:
          r.setAttribute(row, "class", "call-line selected")
        else:
          r.setAttribute(row, "class", "call-line")

        # Function name
        let nameSpan = r.createElement("span")
        r.setAttribute(nameSpan, "class", "call-name")
        r.setTextContent(nameSpan, line.name)
        r.appendChild(row, nameSpan)

        # Click to select, double-click to navigate
        # Re-register event listeners on each rebuild since we clear children
        # and the row itself is reused. Event listeners are additive on MockNode
        # so we clear and re-add by rebuilding the listeners table.
        r.clearEventListeners(row)
        r.addEventListener(row, "click", makeSelectHandler(vm, line.index))
        r.addEventListener(row, "dblclick", makeDoubleClickHandler(vm, line.index))

      row
  )

# ---------------------------------------------------------------------------
# Loading indicator
# ---------------------------------------------------------------------------

proc renderCalltraceLoading*[R, N](r: R; parent: N; vm: CalltraceVM) =
  ## Render a loading indicator that appears when calltrace data is loading.
  let indicator = r.createElement("div")
  r.setAttribute(indicator, "class", "calltrace-loading")
  r.setTextContent(indicator, "Loading...")
  r.appendChild(parent, indicator)

  createRenderEffect proc() =
    let loading = vm.isLoading.val
    r.setStyle(indicator, "display", if loading: "block" else: "none")

# ---------------------------------------------------------------------------
# Main panel renderer
# ---------------------------------------------------------------------------

proc renderCalltracePanel*(r: MockRenderer; vm: CalltraceVM): MockNode =
  ## Render the complete Calltrace panel.
  ##
  ## Structure:
  ##   div.calltrace-component
  ##     div.more-above              (hidden when no entries above)
  ##     div.calltrace-loading       (hidden when not loading)
  ##     div.calltrace-lines
  ##       div.call-line ...
  ##     div.more-below              (hidden when no entries below)
  ##     div.calltrace-search-row
  ##       input.calltrace-search-input
  ##
  ## All content is reactive: changing CalltraceVM signals automatically
  ## updates the DOM tree via createRenderEffect.
  let panel = r.createElement("div")
  r.setAttribute(panel, "class", "calltrace-component")

  # Scroll indicator (above)
  renderScrollIndicatorAbove(r, panel, vm)

  # Loading indicator
  renderCalltraceLoading(r, panel, vm)

  # Call line list
  renderCallLineList(r, panel, vm)

  # Scroll indicator (below)
  renderScrollIndicatorBelow(r, panel, vm)

  # Search input
  renderSearchInput(r, panel, vm)

  panel

# ---------------------------------------------------------------------------
# WebRenderer overload — renders into real browser DOM elements
# ---------------------------------------------------------------------------
#
# The web version matches the Karax calltrace DOM exactly:
#   - Same container IDs (`calltraceComponent-{id}`, `calltraceScroll-{id}`)
#   - Same CSS classes (`.calltrace-call-line`, `.call-child-box`,
#     `.call-text`, `.toggle-call`, `.dot-call-img`, `.event-selected`)
#   - Same depth-offset `<span style="min-width: {depth*8}px">` pattern
#   - Click on `.call-text` delegates to the VM's selectEntry + doubleClickEntry
#
# This ensures Playwright page objects (CallTracePane, CallTraceEntry)
# find the same DOM structure they expect.
# ---------------------------------------------------------------------------

when defined(js):
  # -----------------------------------------------------------------------
  # Helper: create a call line row matching the Karax calltrace structure
  # -----------------------------------------------------------------------
  #
  # Karax produces per row:
  #   div.calltrace-call-line.calltrace-row [.event-selected]
  #     span (depth offset, style="min-width: {depth*8}px")
  #     div.calltrace-child.call-depth
  #       div.call-child-box#local-call-{key}
  #         span.toggle-call
  #           div.dot-call-img
  #         div.call-text#local-call-text-{key}
  #           text "functionName #key"
  #         div.call-args
  #           text "()"
  #
  # The `.call-text` is the click target for navigation (single click
  # selects, double click jumps to source).
  # -----------------------------------------------------------------------

  proc renderWebCallLineList(r: WebRenderer; parent: isonim_dom.Element;
                              vm: CalltraceVM) =
    ## Render the calltrace line list using Karax-compatible DOM structure.
    ## Wrapped in an indexEach for reactive list updates.
    let container = r.createElement("div")
    r.setAttribute(container, "class", "calltrace-lines")
    r.appendChild(parent, container)

    indexEach[CallLine, WebRenderer, isonim_dom.Element](r, container,
      proc(): seq[CallLine] =
        vm.visibleLines.val,
      proc(item: proc(): CallLine, index: int): isonim_dom.Element =
        let row = r.createElement("div")

        createRenderEffect proc() =
          let line = item()
          r.clearChildren(row)

          # Row class: calltrace-call-line calltrace-row [event-selected]
          let selected = vm.selectedEntry.val
          let isSelected = selected.isSome and selected.get == line.index
          let rowClass = if isSelected:
            "calltrace-call-line calltrace-row event-selected"
          else:
            "calltrace-call-line calltrace-row"
          r.setAttribute(row, "class", rowClass)

          # Depth offset span — Playwright reads min-width to infer depth.
          # Karax uses `style="min-width: {depth * 8}px"` on a leading <span>.
          let depthSpan = r.createElement("span")
          r.setStyle(depthSpan, "min-width", $(line.depth * 8) & "px")
          r.appendChild(row, depthSpan)

          # Outer call container: div.calltrace-child.call-depth
          let callChild = r.createElement("div")
          r.setAttribute(callChild, "class", "calltrace-child call-depth")
          r.appendChild(row, callChild)

          # Inner box: div.call-child-box#local-call-{index}
          let callBox = r.createElement("div")
          let lineKey = $line.index
          r.setAttribute(callBox, "id", "local-call-" & lineKey)
          r.setAttribute(callBox, "class", "call-child-box")
          r.appendChild(callChild, callBox)

          # Toggle area: span.toggle-call > div.dot-call-img
          # For now all entries show a dot (leaf marker). Expand/collapse
          # toggle will be added when the VM exposes child counts.
          let toggleSpan = r.createElement("span")
          r.setAttribute(toggleSpan, "class", "toggle-call")
          r.appendChild(callBox, toggleSpan)

          let dotDiv = r.createElement("div")
          r.setAttribute(dotDiv, "class", "dot-call-img")
          r.appendChild(toggleSpan, dotDiv)

          # Call text: div.call-text#local-call-text-{index}
          # Shows "functionName #key" matching the Karax format.
          let callText = r.createElement("div")
          r.setAttribute(callText, "id", "local-call-text-" & lineKey)
          r.setAttribute(callText, "class", "call-text")
          r.setTextContent(callText, line.name & " #" & lineKey)
          r.appendChild(callBox, callText)

          # Args placeholder: div.call-args > text "()"
          # The VM does not yet expose per-call arguments; render an
          # empty args container so the DOM structure is complete.
          let callArgs = r.createElement("div")
          r.setAttribute(callArgs, "class", "call-args")
          r.setTextContent(callArgs, "()")
          r.appendChild(callBox, callArgs)

          # Click to select
          r.clearEventListeners(callText)
          r.addEventListener(callText, "click",
            makeSelectHandler(vm, line.index))

          # Double-click to navigate to source
          r.addEventListener(callText, "dblclick",
            makeDoubleClickHandler(vm, line.index))

        row
    )

  # -----------------------------------------------------------------------
  # Search input (web version) — matches Karax calltrace search DOM
  # -----------------------------------------------------------------------

  proc renderWebSearchInput(r: WebRenderer; parent: isonim_dom.Element;
                             vm: CalltraceVM) =
    ## Render the calltrace search bar using the Karax-compatible DOM:
    ##   div.calltrace-search
    ##     form.calltrace-search-form-0
    ##       input.calltrace-search-input
    ##   div.call-search-results
    ##     div.search-result ...
    let searchDiv = r.createElement("div")
    r.setAttribute(searchDiv, "class", "calltrace-search")
    r.appendChild(parent, searchDiv)

    let form = r.createElement("form")
    r.setAttribute(form, "class", "calltrace-search-form-0")
    r.appendChild(searchDiv, form)

    let input = r.createElement("input")
    r.setAttribute(input, "class",
      "calltrace-search-input calltrace-search-input-0 ct-input-panel ct-input-search-image")
    r.setAttribute(input, "type", "text")
    r.setAttribute(input, "placeholder", "Search")
    r.setAttribute(input, "tabindex", "0")
    r.appendChild(form, input)

    # Wire up search form submission
    let inputNode = isonim_dom.Node(input)
    isonim_dom.addEventListener(isonim_dom.Node(form), cstring"submit",
      proc(ev: isonim_dom.Event) =
        {.emit: "`ev`.preventDefault();".}
        {.emit: "`ev`.stopPropagation();".}
        var query: cstring
        {.emit: "`query` = `inputNode`.value || '';".}
        vm.setSearchQuery($query)
    )

    # Wire up Enter key on input
    isonim_dom.addEventListener(isonim_dom.Node(input), cstring"keydown",
      proc(ev: isonim_dom.Event) =
        var keyCode: int
        {.emit: "`keyCode` = `ev`.keyCode || 0;".}
        if keyCode == 13:  # Enter
          {.emit: "`ev`.preventDefault();".}
          {.emit: "`ev`.stopPropagation();".}
          var query: cstring
          {.emit: "`query` = `inputNode`.value || '';".}
          vm.setSearchQuery($query)
    )

    # Search results container — Playwright queries `.call-search-results`
    # and `.search-result` inside it.
    let resultsDiv = r.createElement("div")
    r.setAttribute(resultsDiv, "class", "call-search-results hidden")
    r.appendChild(parent, resultsDiv)

    # Reactive update: show/hide results from backend search.
    # Uses backendSearchResults (populated by the legacy calltrace
    # component's registerSearchRes via CtCalltraceSearchResponse)
    # instead of the local highlightedMatches memo, because the
    # backend searches the full trace while local search only
    # covers the currently loaded viewport.
    createRenderEffect proc() =
      let results = vm.backendSearchResults.val
      r.clearChildren(resultsDiv)
      if results.len == 0:
        r.setAttribute(resultsDiv, "class", "call-search-results hidden")
      else:
        r.setAttribute(resultsDiv, "class", "call-search-results")
        for res in results:
          let resultDiv = r.createElement("div")
          r.setAttribute(resultDiv, "class", "search-result")
          # Format: "#key - rrTicks(N): functionName"
          # matching the Karax searchResultView output
          let text = "#" & res.key & " - rrTicks(" & $res.rrTicks & "): " & res.name
          r.setTextContent(resultDiv, text)
          r.appendChild(resultsDiv, resultDiv)

          # Click on search result navigates to the entry's location.
          # Use the key and rrTicks to build a calltrace-jump command.
          let capturedRrTicks = res.rrTicks
          r.addEventListener(resultDiv, "mousedown", proc() =
            let args = %*{
              "rrTicks": capturedRrTicks,
            }
            discard vm.store.backend.send("ct/calltrace-jump", args))

  # -----------------------------------------------------------------------
  # Loading indicator (web version)
  # -----------------------------------------------------------------------

  proc renderWebLoading(r: WebRenderer; parent: isonim_dom.Element;
                         vm: CalltraceVM) =
    let indicator = r.createElement("div")
    r.setAttribute(indicator, "class", "calltrace-loading")
    r.setAttribute(indicator, "id", "calltrace-toggle-loading-0")
    r.setTextContent(indicator, "Loading...")
    r.appendChild(parent, indicator)

    createRenderEffect proc() =
      let loading = vm.isLoading.val
      r.setStyle(indicator, "display", if loading: "block" else: "none")

  # -----------------------------------------------------------------------
  # Main panel renderer (WebRenderer)
  # -----------------------------------------------------------------------

  proc renderCalltracePanel*(r: WebRenderer;
                              vm: CalltraceVM): isonim_dom.Element =
    ## Render the complete Calltrace panel using real DOM elements.
    ##
    ## The DOM structure matches the Karax calltrace.nim render() output:
    ##   div.component-container.calltrace-view.isonim-calltrace
    ##     div  (header: search + async toggle placeholder)
    ##       div.calltrace-search
    ##         form > input.calltrace-search-input
    ##       div.call-search-results
    ##     div.local-calltrace-view#calltraceScroll-0  (scroll container)
    ##       div.local-calltrace  (inner wrapper, height set by totalCallsCount)
    ##         div.calltrace-lines  (reactive line list)
    ##           div.calltrace-call-line.calltrace-row ...
    ##     div.calltrace-loading#calltrace-toggle-loading-0
    ##
    ## All IDs use the `-0` suffix matching the default component id=0.
    ## Playwright page objects (CallTracePane, CallTraceEntry) query
    ## these selectors unchanged.
    let panel = r.createElement("div")
    r.setAttribute(panel, "class",
      "component-container calltrace-view isonim-calltrace")
    r.setAttribute(panel, "data-label", "calltrace-data-label-0")
    r.setAttribute(panel, "tabindex", "2")

    # Header section: search + async toggle placeholder
    let header = r.createElement("div")
    r.appendChild(panel, header)

    renderWebSearchInput(r, header, vm)

    # Scroll container
    let scrollContainer = r.createElement("div")
    r.setAttribute(scrollContainer, "id", "calltraceScroll-0")
    r.setAttribute(scrollContainer, "class", "local-calltrace-view")
    r.appendChild(panel, scrollContainer)

    # Wire up scroll events to feed the VM
    isonim_dom.addEventListener(isonim_dom.Node(scrollContainer), cstring"scroll",
      proc(ev: isonim_dom.Event) =
        var scrollTop: float
        {.emit: "`scrollTop` = `scrollContainer`.scrollTop || 0;".}
        let lineIndex = int64(scrollTop / 24.0)  # CALL_HEIGHT_PX = 24
        vm.scroll(lineIndex)
    )

    # Inner wrapper: div.local-calltrace
    let localCalltrace = r.createElement("div")
    r.setAttribute(localCalltrace, "class", "local-calltrace")
    r.appendChild(scrollContainer, localCalltrace)

    # Reactive height based on totalCallsCount for virtual scrolling
    createRenderEffect proc() =
      let total = vm.store.calltrace.totalCallsCount.val
      r.setStyle(localCalltrace, "height", $(total.int * 24) & "px")

    # Call line list
    renderWebCallLineList(r, localCalltrace, vm)

    # Loading indicator
    renderWebLoading(r, panel, vm)

    panel

  proc mountIsoNimCalltrace*(container: isonim_dom.Element;
                              vm: CalltraceVM) =
    ## Mount the IsoNim calltrace view into a real DOM container.
    ##
    ## Creates the reactive DOM tree and appends it as a child of
    ## `container`. The IsoNim reactive effects handle all subsequent
    ## updates — no manual redraw is needed.
    ##
    ## Call this once after the CalltraceVM has been created.
    ## This view is the primary calltrace renderer — the Karax
    ## calltrace render() returns an empty stub when this is mounted.
    let r = WebRenderer()
    let calltracePanel = renderCalltracePanel(r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(calltracePanel))
