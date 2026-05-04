## views/isonim_event_log_view.nim
##
## IsoNim DOM-rendering view for the Event Log panel.
##
## Two output structures:
##
## - `MockRenderer` — simple test-friendly DOM (search row, column
##   header row, event row list via `indexEach`, pagination, loading).
##   Used by `src/tests/gui/tests/views/isonim_views_test.nim`.
##
## - `WebRenderer` — Karax-compatible DOM that hosts the DataTables
##   widget. The IsoNim view creates the static container shell
##   (outer container, header with filter + search, `<table>`
##   placeholders, footer); after mount the caller initialises
##   DataTables on the `<table>` elements. DataTables manages its
##   own DOM from there.
##
## Both renderers express the panel structure in a single `ui()` block
## per overload. Reactive attributes (sort indicator class, pagination
## button enabled/disabled, page indicator text, loading display) use
## DSL helpers so the macro emits per-attribute `createRenderEffect`s.

import std/[options]

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/dsl/components
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../store/types
import ../viewmodels/event_log_vm

# ---------------------------------------------------------------------------
# Column header configuration
# ---------------------------------------------------------------------------

const
  COLUMN_NAMES = ["ID", "Kind", "Line", "Value"]
    ## Display labels for the Mock-renderer event-log columns.
    ## Index 0 = eventId, 1 = kind, 2 = line, 3 = value.

# ---------------------------------------------------------------------------
# Reactive expressions used inside DSL attributes
# ---------------------------------------------------------------------------

proc displayIf(cond: bool): string =
  if cond: "block" else: "none"

proc reactiveDisabled[R, N](r: R; el: N; isDisabled: proc(): bool) =
  ## Reactively toggle the `disabled` attribute on `el`. Browsers treat
  ## any value of `disabled` (including the empty string) as
  ## "disabled", so we add the attribute when the condition is true
  ## and *remove* it when false. The DSL's dynamic-attribute path
  ## always emits `setAttribute`, so we wire this case imperatively
  ## against an element captured via `ref = var` in the surrounding
  ## `ui()` block.
  createRenderEffect proc() =
    if isDisabled():
      r.setAttribute(el, "disabled", "true")
    else:
      r.removeAttribute(el, "disabled")

proc columnHeaderClass(vm: EventLogVM; col: int): string =
  ## Column header class with a reactive `sort-active` modifier.
  let base = "column-header column-" & $col
  if vm.sortColumn.val == col: base & " sort-active" else: base

proc columnHeaderText(vm: EventLogVM; col: int; baseName: string): string =
  ## Column header text with a reactive sort-direction indicator.
  if vm.sortColumn.val != col: return baseName
  if vm.sortAscending.val: baseName & " ^"
  else: baseName & " v"

proc rowClass(vm: EventLogVM; index: int): string =
  let sel = vm.selectedRow.val
  if sel.isSome and sel.get == index: "event-row selected" else: "event-row"

proc pageIndicatorText(vm: EventLogVM): string =
  let page = vm.currentPage.val + 1
  let total = vm.totalPages.val
  "Page " & $page & " / " & $total

proc prevButtonDisabled(vm: EventLogVM): bool =
  vm.currentPage.val <= 0

proc nextButtonDisabled(vm: EventLogVM): bool =
  let maxPage = vm.totalPages.val - 1
  vm.currentPage.val >= maxPage or maxPage < 0

# ---------------------------------------------------------------------------
# Click handler factories
# ---------------------------------------------------------------------------

proc onSortColumn(vm: EventLogVM; col: int): proc() =
  let c = col
  result = proc() = vm.sort(c)

proc onSelectRow(vm: EventLogVM; index: int): proc() =
  let i = index
  result = proc() = vm.selectRow(some(i))

proc onDoubleClickRow(vm: EventLogVM; index: int): proc() =
  let i = index
  result = proc() = vm.doubleClickRow(i)

# ---------------------------------------------------------------------------
# Row body (shared between Mock and Web simple variants)
# ---------------------------------------------------------------------------

template renderEventRowImpl(r, vm, item, index: untyped): untyped =
  ## Reactive event-log row. Class is reactive on selection; cell
  ## texts are reactive on the row's signal.
  let onClick    = onSelectRow(vm, index)
  let onDblClick = onDoubleClickRow(vm, index)
  ui(r):
    tdiv(class = rowClass(vm, index),
         onclick = onClick, ondblclick = onDblClick):
      span(class = "event-id"):
        text $item().eventId
      span(class = "event-kind"):
        text item().kind
      span(class = "event-line"):
        text $item().line
      span(class = "event-value"):
        text item().value

proc renderEventRow*(r: MockRenderer; vm: EventLogVM;
                     item: proc(): EventLogRow; index: int): MockNode =
  renderEventRowImpl(r, vm, item, index)

when defined(js):
  proc renderEventRow*(r: WebRenderer; vm: EventLogVM;
                       item: proc(): EventLogRow; index: int):
                       isonim_dom.Element =
    renderEventRowImpl(r, vm, item, index)

# ---------------------------------------------------------------------------
# MockRenderer panel — simple structure for headless tests
# ---------------------------------------------------------------------------

proc renderEventLogPanel*(r: MockRenderer; vm: EventLogVM): MockNode =
  ## Render the full Event Log panel for headless tests.
  ##
  ## Structure:
  ##   div.event-log-component
  ##     div.event-log-search-row
  ##       input.event-log-search-input
  ##     div.event-log-header-row
  ##       span.column-header.column-{i}[.sort-active]   text reactive
  ##     div.event-log-loading[display reactive]
  ##     div.event-log-rows                             populated by indexEach
  ##     div.event-log-pagination
  ##       button.page-prev[disabled reactive]
  ##       span.page-indicator                         text reactive
  ##       button.page-next[disabled reactive]
  var rowsContainer, prevBtn, nextBtn: MockNode

  let panel = ui(r):
    tdiv(class = "event-log-component"):
      tdiv(class = "event-log-search-row"):
        input(class = "event-log-search-input",
              placeholder = "Search events...")
      tdiv(class = "event-log-header-row"):
        for i, name in COLUMN_NAMES:
          span(class = columnHeaderClass(vm, i),
               onclick = onSortColumn(vm, i)):
            text columnHeaderText(vm, i, name)
      tdiv(class = "event-log-loading",
           display = displayIf(vm.isLoading.val)):
        text "Loading..."
      tdiv(ref = rowsContainer, class = "event-log-rows"):
        discard
      tdiv(class = "event-log-pagination"):
        button(ref = prevBtn, class = "page-prev",
               onclick = proc() = vm.prevPage()):
          text "Prev"
        span(class = "page-indicator"):
          text pageIndicatorText(vm)
        button(ref = nextBtn, class = "page-next",
               onclick = proc() = vm.nextPage()):
          text "Next"

  reactiveDisabled(r, prevBtn, proc(): bool = prevButtonDisabled(vm))
  reactiveDisabled(r, nextBtn, proc(): bool = nextButtonDisabled(vm))

  indexEach[EventLogRow, MockRenderer, MockNode](r, rowsContainer,
    proc(): seq[EventLogRow] = vm.eventRows.val,
    proc(item: proc(): EventLogRow, index: int): MockNode =
      renderEventRow(r, vm, item, index))

  panel

# ---------------------------------------------------------------------------
# WebRenderer — DataTables-compatible structure
# ---------------------------------------------------------------------------
#
# This shell mirrors what the legacy Karax `EventLogComponent.render()`
# produced, so the existing DataTables FFI initialisation code can run
# unchanged on the IsoNim-created elements.
#
#   div.component-container.eventLog
#     div.ct-flex                           (header row)
#       button#category-image               (filter dropdown trigger)
#       input.ct-input-panel#…              (search input)
#       div.eventLog-switch                 (dense/detailed toggle)
#         span#detailed
#     div.eventLog-dense-table.data-table
#       table#{denseTableId}                (DataTables target)
#     div.data-tables-footer
#       div.data-tables-footer-info         (Rows … of … counter)
#     div.eventLog-detailed-table.data-table
#       table#{detailedTableId}             (DataTables target)

when defined(js):

  proc renderWebEventLogPanel*(r: WebRenderer;
                                vm: EventLogVM;
                                componentId: int;
                                denseTableId: string;
                                detailedTableId: string;
                                searchInputId: string
                               ): isonim_dom.Element =
    ## Render the Event Log shell. The `<table>` elements are empty
    ## placeholders; DataTables populates them after `afterMount`.
    ## `componentId` is currently unused inside the markup but kept on
    ## the public API so callers do not have to thread it themselves.
    discard componentId
    ui(r):
      tdiv(id = "eventLogComponent-" & $componentId,
           class = "component-container eventLog isonim-event-log",
           tabindex = "2"):
        tdiv(class = "ct-flex"):
          button(id = "category-image",
                 class = "ct-button-image-md-secondary ct-mr-2 ct-button-no-border",
                 tabindex = "0"):
            discard
          input(class = "ct-input-panel ct-input-search-image",
                id = searchInputId,
                `type` = "text",
                placeholder = "Find event")
          tdiv(class = "eventLog-switch eventLog-button eventLog-normal-color-button"):
            span(id = "detailed"):
              text "detailed"
        tdiv(class = "eventLog-dense-table data-table"):
          table(id = denseTableId):
            discard
        tdiv(class = "data-tables-footer 0to0"):
          tdiv(class = "data-tables-footer-info"):
            span:
              text "Rows"
            input(class = "ct-input-small mx-2", value = "0")
            span:
              text "to"
            tdiv(class = "data-tables-footer-end-row"):
              text "0"
            span:
              text "of"
            tdiv(class = "data-tables-footer-rows-count"):
              text "0"
        tdiv(class = "eventLog-detailed-table data-table"):
          table(id = detailedTableId):
            discard

  proc renderEventLogPanel*(r: WebRenderer;
                            vm: EventLogVM): isonim_dom.Element =
    ## Simple IsoNim-only rendering (no DataTables) — the same
    ## structure as the Mock panel, but using real DOM elements.
    ## Retained for backward compatibility with non-DataTables paths
    ## and tests that exercise the IsoNim row list directly.
    var rowsContainer, prevBtn, nextBtn: isonim_dom.Element

    let panel = ui(r):
      tdiv(class = "event-log-component isonim-event-log"):
        tdiv(class = "event-log-search-row"):
          input(class = "event-log-search-input",
                placeholder = "Search events...")
        tdiv(class = "event-log-header-row"):
          for i, name in COLUMN_NAMES:
            span(class = columnHeaderClass(vm, i),
                 onclick = onSortColumn(vm, i)):
              text columnHeaderText(vm, i, name)
        tdiv(class = "event-log-loading",
             display = displayIf(vm.isLoading.val)):
          text "Loading..."
        tdiv(ref = rowsContainer, class = "event-log-rows"):
          discard
        tdiv(class = "event-log-pagination"):
          button(ref = prevBtn, class = "page-prev",
                 onclick = proc() = vm.prevPage()):
            text "Prev"
          span(class = "page-indicator"):
            text pageIndicatorText(vm)
          button(ref = nextBtn, class = "page-next",
                 onclick = proc() = vm.nextPage()):
            text "Next"

    reactiveDisabled(r, prevBtn, proc(): bool = prevButtonDisabled(vm))
    reactiveDisabled(r, nextBtn, proc(): bool = nextButtonDisabled(vm))

    indexEach[EventLogRow, WebRenderer, isonim_dom.Element](r, rowsContainer,
      proc(): seq[EventLogRow] = vm.eventRows.val,
      proc(item: proc(): EventLogRow, index: int): isonim_dom.Element =
        renderEventRow(r, vm, item, index))

    panel

  proc mountIsoNimEventLog*(container: isonim_dom.Element;
                            vm: EventLogVM) =
    ## Mount the simple IsoNim event log view (no DataTables) into a
    ## real DOM container. Reactive effects handle every subsequent
    ## update — no manual redraw is needed.
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
    ## Mount the IsoNim event log shell (DataTables-compatible) and
    ## then invoke `afterMount` so the caller can initialise DataTables
    ## on the `<table>` elements. A microtask delay is **not** added
    ## here — the caller is responsible for ordering if DataTables
    ## requires the nodes to be already attached.
    let r = WebRenderer()
    let panel = renderWebEventLogPanel(
      r, vm, componentId, denseTableId, detailedTableId, searchInputId)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
    afterMount()
