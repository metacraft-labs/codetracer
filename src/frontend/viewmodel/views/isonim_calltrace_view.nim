## views/isonim_calltrace_view.nim
##
## IsoNim DOM-rendering view for the Calltrace panel.
##
## Renders a live, reactive DOM tree driven by CalltraceVM signals.
## When the VM's signals change (visible lines, selected entry,
## scroll indicators, search query), the DOM updates automatically
## via IsoNim's `createRenderEffect`.
##
## Generic over the renderer type `R` so that:
## - `MockRenderer` can be used for headless unit tests
## - The web renderer can be used for real browser DOM
##
## This view is intended to eventually replace the Karax calltrace.nim
## component. It consumes the same CalltraceVM but renders through
## IsoNim's renderer API instead of Karax's VDOM.
##
## Usage (test):
##   let r = MockRenderer()
##   let panel = renderCalltracePanel(r, calltraceVM)
##   check panel.textContent.contains("main")
##
## Usage (web):
##   let panel = renderCalltracePanel(webRenderer, calltraceVM)
##   document.body.appendChild(panel)

import std/[options, tables]

import isonim/core/[signals, computation]
import isonim/dsl/components
import isonim/testing/mock_dom  # MockNode type used in generic signatures

import ../store/types
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
