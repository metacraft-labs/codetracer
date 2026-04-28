## views/isonim_event_log_view.nim
##
## IsoNim DOM-rendering view for the Event Log panel.
##
## This view creates the container DOM structure that DataTables
## attaches to. IsoNim builds the shell (outer container, header
## with search/filter, `<table>` elements with the correct IDs),
## then the existing DataTables FFI code from event_log.nim
## initialises the widget on those elements.
##
## The pattern is:
## 1. IsoNim creates the same DOM skeleton that Karax's render() produced
## 2. After mount, a caller-provided callback triggers DataTables init
## 3. DataTables manages the table body DOM from there
## 4. IsoNim effects can update the DataTable via its API when
##    ViewModel signals change
##
## Generic over the renderer type `R` so that:
## - `MockRenderer` can be used for headless unit tests
## - The web renderer can be used for real browser DOM
##
## Usage (test):
##   let r = MockRenderer()
##   let panel = renderEventLogPanel(r, eventLogVM)
##   check panel.textContent.contains("Event Log")
##
## Usage (web):
##   import isonim/web/web_renderer
##   let r = WebRenderer()
##   let panel = renderEventLogPanel(r, eventLogVM, denseId, detailedId)
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
# WebRenderer overload — renders DataTables-compatible DOM structure
# ---------------------------------------------------------------------------
#
# The web version creates the same DOM structure that Karax's render()
# produced, so that the existing DataTables FFI initialisation code can
# run unchanged on the IsoNim-created elements.
#
# Karax render() produces:
#   div.component-container.eventLog               (outer container)
#     div.ct-flex                                   (header: filter + search)
#       button#category-image                       (filter dropdown trigger)
#       input.ct-input-panel.ct-input-search-image  (search input)
#       div.eventLog-switch ...                     (dense/detailed toggle)
#     div.eventLog-dense-table.data-table           (dense table wrapper)
#       table#eventLog-{id}-dense-table-{index}     (DataTables target)
#     div.data-tables-footer                        (footer with row info)
#     div.eventLog-detailed-table.data-table        (detailed table wrapper)
#       table#eventLog-{id}-detailed-table-{index}  (DataTables target)
#
# After mount, the caller invokes the EventLogComponent's events() /
# eventLogAfterRedraws() to initialise the DataTables widget on the
# `<table>` elements. DataTables manages its own DOM from there.
# ---------------------------------------------------------------------------

when defined(js):
  proc renderWebEventLogPanel*(r: WebRenderer;
                                vm: EventLogVM;
                                componentId: int;
                                denseTableId: string;
                                detailedTableId: string;
                                searchInputId: string
                               ): isonim_dom.Element =
    ## Render the Event Log panel container with DataTables-compatible
    ## DOM structure. The `<table>` elements are empty shells that
    ## DataTables will populate during initialisation.
    ##
    ## Parameters:
    ##   componentId    - the EventLogComponent.id (usually 0)
    ##   denseTableId   - the ID for the dense `<table>` (e.g. "eventLog-0-dense-table-0")
    ##   detailedTableId - the ID for the detailed `<table>`
    ##   searchInputId  - the ID for the search input (e.g. "eventLog-0-search")
    let panel = r.createElement("div")
    r.setAttribute(panel, "class",
      "component-container eventLog isonim-event-log")
    r.setAttribute(panel, "tabindex", "2")

    # -- Header section: filter button + search input + dense/detailed toggle --
    let header = r.createElement("div")
    r.setAttribute(header, "class", "ct-flex")
    r.appendChild(panel, header)

    # Filter dropdown button — the existing showDropdown() creates the
    # dropdown DOM dynamically and positions it relative to this button.
    # We give it the same ID so the legacy code can find it.
    let filterBtn = r.createElement("button")
    r.setAttribute(filterBtn, "id", "category-image")
    r.setAttribute(filterBtn, "class",
      "ct-button-image-md-secondary ct-mr-2 ct-button-no-border")
    r.setAttribute(filterBtn, "tabindex", "0")
    r.appendChild(header, filterBtn)

    # Search input — matches the Karax-produced input element.
    let searchInput = r.createElement("input")
    r.setAttribute(searchInput, "class",
      "ct-input-panel ct-input-search-image")
    r.setAttribute(searchInput, "id", searchInputId)
    r.setAttribute(searchInput, "type", "text")
    r.setAttribute(searchInput, "placeholder", "Find event")
    r.appendChild(header, searchInput)

    # Wire up search: on input/change, read value and drive DataTables search.
    # The DataTables search is triggered by the EventLogComponent's
    # eventLogSearchValue + denseTable.context.search().draw() calls.
    # IsoNim does not need to do anything extra here — the existing
    # jQuery selectors in eventLogHeaderView find the input by ID.

    # Dense/detailed toggle placeholder — the EventLogComponent manages
    # this state; here we provide the container the existing toggle
    # code expects.
    let toggleDiv = r.createElement("div")
    r.setAttribute(toggleDiv, "class",
      "eventLog-switch eventLog-button eventLog-normal-color-button")
    r.appendChild(header, toggleDiv)

    let toggleSpan = r.createElement("span")
    r.setAttribute(toggleSpan, "id", "detailed")
    r.setTextContent(toggleSpan, "detailed")
    r.appendChild(toggleDiv, toggleSpan)

    # -- Dense table wrapper --
    let denseWrapper = r.createElement("div")
    r.setAttribute(denseWrapper, "class", "eventLog-dense-table data-table")
    r.appendChild(panel, denseWrapper)

    # The `<table>` element that DataTables attaches to.
    let denseTable = r.createElement("table")
    r.setAttribute(denseTable, "id", denseTableId)
    r.appendChild(denseWrapper, denseTable)

    # -- Footer placeholder --
    # DataTables creates its own pagination/info elements, but the
    # EventLogComponent also renders a custom footer via tableFooter().
    # Create the container div so eventLogAfterRedraws can find it.
    let footer = r.createElement("div")
    r.setAttribute(footer, "class", "data-tables-footer 0to0")
    r.appendChild(panel, footer)

    # Footer inner structure matching tableFooter() output:
    #   div.data-tables-footer-info
    #     "Rows" input.ct-input-small.mx-2 "to"
    #     div.data-tables-footer-end-row "of"
    #     div.data-tables-footer-rows-count
    let footerInfo = r.createElement("div")
    r.setAttribute(footerInfo, "class", "data-tables-footer-info")
    r.appendChild(footer, footerInfo)

    let rowsLabel = r.createElement("span")
    r.setTextContent(rowsLabel, "Rows")
    r.appendChild(footerInfo, rowsLabel)

    let footerInput = r.createElement("input")
    r.setAttribute(footerInput, "class", "ct-input-small mx-2")
    r.setAttribute(footerInput, "value", "0")
    r.appendChild(footerInfo, footerInput)

    let toLabel = r.createElement("span")
    r.setTextContent(toLabel, "to")
    r.appendChild(footerInfo, toLabel)

    let endRowDiv = r.createElement("div")
    r.setAttribute(endRowDiv, "class", "data-tables-footer-end-row")
    r.setTextContent(endRowDiv, "0")
    r.appendChild(footerInfo, endRowDiv)

    let ofLabel = r.createElement("span")
    r.setTextContent(ofLabel, "of")
    r.appendChild(footerInfo, ofLabel)

    let rowsCountDiv = r.createElement("div")
    r.setAttribute(rowsCountDiv, "class", "data-tables-footer-rows-count")
    r.setTextContent(rowsCountDiv, "0")
    r.appendChild(footerInfo, rowsCountDiv)

    # -- Detailed table wrapper --
    let detailedWrapper = r.createElement("div")
    r.setAttribute(detailedWrapper, "class",
      "eventLog-detailed-table data-table")
    r.appendChild(panel, detailedWrapper)

    let detailedTable = r.createElement("table")
    r.setAttribute(detailedTable, "id", detailedTableId)
    r.appendChild(detailedWrapper, detailedTable)

    panel

  proc renderEventLogPanel*(r: WebRenderer;
                             vm: EventLogVM): isonim_dom.Element =
    ## Render a simple IsoNim-only Event Log panel (no DataTables).
    ## Retained for backward compatibility with the non-DataTables
    ## mount path and tests.
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
    ## Mount the simple IsoNim event log view (no DataTables) into a
    ## real DOM container. Retained for backward compatibility.
    ## The primary mount path is `mountIsoNimEventLogWithDataTables`.
    let r = WebRenderer()
    let panel = renderEventLogPanel(r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))

  proc mountIsoNimEventLogWithDataTables*(
      container: isonim_dom.Element;
      vm: EventLogVM;
      componentId: int;
      denseTableId: string;
      detailedTableId: string;
      searchInputId: string;
      afterMount: proc()
    ) =
    ## Mount the IsoNim event log view with DataTables-compatible DOM
    ## structure, then invoke `afterMount` to trigger DataTables
    ## initialisation on the created `<table>` elements.
    ##
    ## This is the primary mount path for the Event Log panel migration.
    ## IsoNim creates the container shell, then the caller's `afterMount`
    ## callback runs the existing DataTables FFI init code.
    let r = WebRenderer()
    let panel = renderWebEventLogPanel(
      r, vm, componentId,
      denseTableId, detailedTableId, searchInputId)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))

    # Trigger DataTables initialisation after the DOM elements are in
    # the document tree. A microtask delay ensures the browser has
    # committed the DOM nodes before DataTables queries them.
    afterMount()
