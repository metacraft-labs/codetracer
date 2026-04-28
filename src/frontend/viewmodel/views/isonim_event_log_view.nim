## views/isonim_event_log_view.nim
##
## IsoNim DOM-rendering view for the Event Log panel.
##
## Renders a live, reactive DOM tree driven by EventLogVM signals.
## When the VM's signals change (event rows, pagination, search,
## sort), the DOM updates automatically via IsoNim's
## `createRenderEffect`.
##
## Generic over the renderer type `R` so that:
## - `MockRenderer` can be used for headless unit tests
## - The web renderer can be used for real browser DOM
##
## This view is intended to eventually replace the Karax event_log.nim
## component. It consumes the same EventLogVM but renders through
## IsoNim's renderer API instead of Karax's VDOM.
##
## Usage (test):
##   let r = MockRenderer()
##   let panel = renderEventLogPanel(r, eventLogVM)
##   check panel.textContent.contains("Event Log")
##
## Usage (web):
##   import isonim/web/web_renderer
##   let r = WebRenderer()
##   let panel = renderEventLogPanel(r, eventLogVM)
##   # panel is a dom_api.Element, append to any real DOM container

import std/[options, strutils, tables]

import isonim/core/[signals, computation]
import isonim/dsl/components
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../store/types
import ../viewmodels/event_log_vm

# ---------------------------------------------------------------------------
# Column header names — used for both rendering and sort-click targets.
# ---------------------------------------------------------------------------

const
  COLUMN_NAMES = ["ID", "Kind", "Line", "Value"]
  ## Display names for event log table columns.
  ## Column indices correspond to EventLogRow fields:
  ##   0 = eventId, 1 = kind, 2 = line, 3 = value.

# ---------------------------------------------------------------------------
# Search input renderer
# ---------------------------------------------------------------------------

proc renderSearchInput*[R, N](r: R; parent: N; vm: EventLogVM) =
  ## Render the search/filter input for the event log.
  ## When the user types, we call `vm.setSearchQuery` to update the
  ## reactive state and trigger data re-fetch.
  let inputRow = r.createElement("div")
  r.setAttribute(inputRow, "class", "event-log-search-row")
  r.appendChild(parent, inputRow)

  let input = r.createElement("input")
  r.setAttribute(input, "class", "event-log-search-input")
  r.setAttribute(input, "placeholder", "Search events...")
  r.appendChild(inputRow, input)

  # In a real browser, we would read `input.value` on input events.
  # With MockRenderer, this is a placeholder.

# ---------------------------------------------------------------------------
# Sort header renderer
# ---------------------------------------------------------------------------

proc makeSortClickHandler(vm: EventLogVM; column: int): proc() =
  ## Factory to create a click handler for a sort-column header.
  let col = column
  result = proc() =
    vm.sort(col)

proc makeSortHeaderEffect[R, N](r: R; header: N;
                                 vm: EventLogVM; column: int;
                                 name: string): proc() =
  ## Factory to create a reactive effect that updates the sort indicator.
  let col = column
  let baseName = name
  result = proc() =
    let active = vm.sortColumn.val == col
    let asc = vm.sortAscending.val
    let indicator =
      if not active: ""
      elif asc: " ^"
      else: " v"
    r.setTextContent(header, baseName & indicator)
    if active:
      r.setAttribute(header, "class", "column-header column-" & $col & " sort-active")
    else:
      r.setAttribute(header, "class", "column-header column-" & $col)

proc renderColumnHeaders*[R, N](r: R; parent: N; vm: EventLogVM) =
  ## Render the column header row with sort controls.
  ## Clicking a header toggles sort on that column.
  let headerRow = r.createElement("div")
  r.setAttribute(headerRow, "class", "event-log-header-row")
  r.appendChild(parent, headerRow)

  for i, name in COLUMN_NAMES:
    let header = r.createElement("span")
    r.setAttribute(header, "class", "column-header column-" & $i)
    r.setTextContent(header, name)
    r.appendChild(headerRow, header)

    r.addEventListener(header, "click", makeSortClickHandler(vm, i))

    # Reactive sort indicator
    createRenderEffect makeSortHeaderEffect(r, header, vm, i, name)

# ---------------------------------------------------------------------------
# Event row list renderer
# ---------------------------------------------------------------------------

proc renderEventRows*[R, N](r: R; parent: N; vm: EventLogVM) =
  ## Render the event log rows container.
  ## Uses indexEach for positional rendering: when the event rows
  ## change, rows are updated in place or added/removed.
  let container = r.createElement("div")
  r.setAttribute(container, "class", "event-log-rows")
  r.appendChild(parent, container)

  proc makeRowClickHandler(vm: EventLogVM; index: int): proc() =
    let idx = index
    result = proc() =
      vm.selectRow(some(idx))

  proc makeRowDblClickHandler(vm: EventLogVM; index: int): proc() =
    let idx = index
    result = proc() =
      vm.doubleClickRow(idx)

  indexEach[EventLogRow, R, N](r, container,
    proc(): seq[EventLogRow] =
      vm.eventRows.val,
    proc(item: proc(): EventLogRow, index: int): N =
      let row = r.createElement("div")
      r.setAttribute(row, "class", "event-row")

      createRenderEffect proc() =
        let ev = item()

        # Clear and rebuild row content on each update.
        r.clearChildren(row)

        # Selected row highlighting
        let selected = vm.selectedRow.val
        if selected.isSome and selected.get == index:
          r.setAttribute(row, "class", "event-row selected")
        else:
          r.setAttribute(row, "class", "event-row")

        # Event ID cell
        let idCell = r.createElement("span")
        r.setAttribute(idCell, "class", "event-id")
        r.setTextContent(idCell, $ev.eventId)
        r.appendChild(row, idCell)

        # Kind cell
        let kindCell = r.createElement("span")
        r.setAttribute(kindCell, "class", "event-kind")
        r.setTextContent(kindCell, ev.kind)
        r.appendChild(row, kindCell)

        # Line cell
        let lineCell = r.createElement("span")
        r.setAttribute(lineCell, "class", "event-line")
        r.setTextContent(lineCell, $ev.line)
        r.appendChild(row, lineCell)

        # Value cell
        let valueCell = r.createElement("span")
        r.setAttribute(valueCell, "class", "event-value")
        r.setTextContent(valueCell, ev.value)
        r.appendChild(row, valueCell)

        # Re-register event listeners after rebuild.
        r.clearEventListeners(row)
        r.addEventListener(row, "click", makeRowClickHandler(vm, index))
        r.addEventListener(row, "dblclick", makeRowDblClickHandler(vm, index))

      row
  )

# ---------------------------------------------------------------------------
# Pagination controls renderer
# ---------------------------------------------------------------------------

proc renderPagination*[R, N](r: R; parent: N; vm: EventLogVM) =
  ## Render pagination controls: prev button, page indicator, next button.
  let paginationBar = r.createElement("div")
  r.setAttribute(paginationBar, "class", "event-log-pagination")
  r.appendChild(parent, paginationBar)

  # Previous page button
  let prevBtn = r.createElement("button")
  r.setAttribute(prevBtn, "class", "page-prev")
  r.setTextContent(prevBtn, "Prev")
  r.appendChild(paginationBar, prevBtn)
  r.addEventListener(prevBtn, "click", proc() = vm.prevPage())

  createRenderEffect proc() =
    if vm.currentPage.val <= 0:
      r.setAttribute(prevBtn, "disabled", "true")
    else:
      r.removeAttribute(prevBtn, "disabled")

  # Page indicator text
  let pageText = r.createElement("span")
  r.setAttribute(pageText, "class", "page-indicator")
  r.appendChild(paginationBar, pageText)

  createRenderEffect proc() =
    let page = vm.currentPage.val + 1
    let total = vm.totalPages.val
    r.setTextContent(pageText, "Page " & $page & " / " & $total)

  # Next page button
  let nextBtn = r.createElement("button")
  r.setAttribute(nextBtn, "class", "page-next")
  r.setTextContent(nextBtn, "Next")
  r.appendChild(paginationBar, nextBtn)
  r.addEventListener(nextBtn, "click", proc() = vm.nextPage())

  createRenderEffect proc() =
    let maxPage = vm.totalPages.val - 1
    if vm.currentPage.val >= maxPage or maxPage < 0:
      r.setAttribute(nextBtn, "disabled", "true")
    else:
      r.removeAttribute(nextBtn, "disabled")

# ---------------------------------------------------------------------------
# Loading indicator
# ---------------------------------------------------------------------------

proc renderEventLogLoading*[R, N](r: R; parent: N; vm: EventLogVM) =
  ## Render a loading indicator that appears when event log data is loading.
  let indicator = r.createElement("div")
  r.setAttribute(indicator, "class", "event-log-loading")
  r.setTextContent(indicator, "Loading...")
  r.appendChild(parent, indicator)

  createRenderEffect proc() =
    let loading = vm.isLoading.val
    r.setStyle(indicator, "display", if loading: "block" else: "none")

# ---------------------------------------------------------------------------
# Main panel renderer — MockRenderer overload
# ---------------------------------------------------------------------------

proc renderEventLogPanel*(r: MockRenderer; vm: EventLogVM): MockNode =
  ## Render the complete Event Log panel.
  ##
  ## Structure:
  ##   div.event-log-component
  ##     div.event-log-search-row
  ##       input.event-log-search-input
  ##     div.event-log-header-row
  ##       span.column-header ...
  ##     div.event-log-loading          (hidden when not loading)
  ##     div.event-log-rows
  ##       div.event-row ...
  ##     div.event-log-pagination
  ##       button.page-prev
  ##       span.page-indicator
  ##       button.page-next
  ##
  ## All content is reactive: changing EventLogVM signals automatically
  ## updates the DOM tree via createRenderEffect.
  let panel = r.createElement("div")
  r.setAttribute(panel, "class", "event-log-component")

  # Search input
  renderSearchInput(r, panel, vm)

  # Column headers with sort controls
  renderColumnHeaders(r, panel, vm)

  # Loading indicator
  renderEventLogLoading(r, panel, vm)

  # Event rows
  renderEventRows(r, panel, vm)

  # Pagination
  renderPagination(r, panel, vm)

  panel

# ---------------------------------------------------------------------------
# WebRenderer overload — renders into real browser DOM elements
# ---------------------------------------------------------------------------

when defined(js):
  proc renderEventLogPanel*(r: WebRenderer;
                             vm: EventLogVM): isonim_dom.Element =
    ## Render the complete Event Log panel using real DOM elements.
    let panel = r.createElement("div")
    r.setAttribute(panel, "class", "event-log-component isonim-event-log")

    renderSearchInput(r, panel, vm)
    renderColumnHeaders(r, panel, vm)
    renderEventLogLoading(r, panel, vm)
    renderEventRows(r, panel, vm)
    renderPagination(r, panel, vm)

    panel

  proc mountIsoNimEventLog*(container: isonim_dom.Element;
                             vm: EventLogVM) =
    ## Mount the IsoNim event log view into a real DOM container.
    ##
    ## Creates the reactive DOM tree and appends it as a child of
    ## `container`. The IsoNim reactive effects handle all subsequent
    ## updates — no manual redraw is needed.
    let r = WebRenderer()
    let panel = renderEventLogPanel(r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
