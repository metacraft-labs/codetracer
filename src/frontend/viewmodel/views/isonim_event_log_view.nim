## views/isonim_event_log_view.nim
##
## The Event Log panel: ONE generic view, `renderEventLogPanel[R, N]`, over
## `EventLogVM` — under `MockRenderer` for the headless tests, under
## `WebRenderer` for the desktop (mounted by `ui/panel_host.mountPanel`), the
## VS Code webview and the storybook.
##
## The rows are a keyed list (`forEachKeyed`) of the window the ViewModel
## holds, each keyed by its position in the list the pane pages through, so a
## scroll that slides the window keeps the rows it still shows. They sit
## `loadedStart` rows down inside a scroll area as tall as the whole
## (filtered) list, so the scrollbar spans the log and a scrolled-to window
## lands where it belongs. The panel host measures the area and reports it to
## the ViewModel (`setViewport`, `setRowHeightPx`), which asks the engine for
## the rows it shows (`ct/event-load`).
##
## The markup keeps the class names the desktop's Event Log always had — the
## dense table's `tbody tr` rows with their `data-*` identity, the
## `.eventLog-index` / `.rr-ticks-time` / `.eventLog-text` cells, the
## `.data-tables-footer` counters — which the Playwright page objects read
## (`src/tests/gui/page-objects/panes/event-log/`) and the stylesheets size.
##
## What only a browser has — the search field's typing, the footer's row
## field, the expander of a multi-line event and the scrollbar scrubber — is
## decoration added under `when N is isonim_dom.Element`.

import std/[math, options, strutils]

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/dsl/components
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom
  from std/jsffi import JsObject
  from ./list_scrubber_dom import attachListScrubber
  from ./table_fit_dom import attachEventLogFit
  # Enter and Space on a `role="button"` row or header cell are its click.
  import ./isonim_activation

import ../store/types
import ../viewmodels/event_log_vm
from ../viewmodels/table_overflow import pxOfCells, EventLogTablePane, oneLine
from std/unicode import runeLen
# PLAT-70 Part I: fit or scroll (Horizontal-Overflow.md §5.5).
import ../viewmodels/table_fit

export signals, computation, components

# ---------------------------------------------------------------------------
# What the DSL binds: free procs, so each attribute and text is one effect
# ---------------------------------------------------------------------------

const
  EventLogColumnsButtonClass* = "eventLog-columns-button"
  EventLogColumnsButtonText* = "Columns +"
  EventLogColumnsMenuClass* = "eventLog-columns-menu"
  EventLogColumnOptionClass* = "eventLog-column-option"
  EventLogColumnCheckClass* = "eventLog-column-check"
  EventLogColumnLeftClass* = "eventLog-column-left"
  EventLogColumnRightClass* = "eventLog-column-right"
  EventLogColumnGripClass* = "eventLog-column-grip"
    ## A header cell's separator grip, at its right edge (Horizontal-
    ## Overflow.md §5.2): a drag on it resizes the column (`ui/event_log`).
  EventLogColumnGripAttribute* = "data-ct-column-separator"
    ## On the grip: its column.
  EventLogRowClass* = "eventLog-row"
    ## Every event row; the panel host measures the rows' advance by it.
  EventLogScrollBodyClass* = "eventLog-scroll-body"
    ## The element that scrolls: the panel host's measured viewport.
  EventLogEmptyText* =
    "The current record appears to not have any system events like " &
    "std read/write, network or disc operations. You can add trace point " &
    "events to your code by selecting any line of code and pressing \"Enter\""
    ## What an empty log says (the desktop table's `emptyTable` text).

proc displayIf(cond: bool): string =
  if cond: "block" else: "none"

proc columnCheckClass*(vm: EventLogVM; col: EventLogColumn): string =
  EventLogColumnCheckClass &
    (if vm.columns.val.isVisible(col): " checked" else: "")

proc columnCheckGlyph*(vm: EventLogVM; col: EventLogColumn): string =
  if vm.columns.val.isVisible(col): "☑" else: "☐"

proc columnOptionTitle*(col: EventLogColumn): string =
  eventLogColumnTitle(col)

proc columnClass*(col: EventLogColumn): string =
  ## A column's cells' class — a header cell's and a body cell's alike, so
  ## the rules that size one size the other.
  case col
  of elcTick: "direct-location-rr-ticks eventLog-cell"
  of elcIndex: "eventLog-index eventLog-cell"
  of elcLocation: "eventLog-fullpath eventLog-cell"
  of elcKind: "eventLog-event eventLog-cell"
  of elcOutput: "eventLog-text eventLog-cell"

# ---------------------------------------------------------------------------
# PLAT-70 Part I: the columns fit or scroll (Horizontal-Overflow.md §5.5)
# ---------------------------------------------------------------------------

const DesktopColumnGapCells* = 1
  ## The space between two columns, in characters (the cells' padding): the
  ## terminal's `GapCells`, so both lay out the same table.

var fitCache: tuple[key: string; fit: TableFit]

proc rowLocation*(row: EventLogRow): string

proc desktopFit*(vm: EventLogVM): TableFit =
  ## The Event Log's columns in CHARACTERS of the table's font, laid out by
  ## the shared solver over the viewport the panel measured
  ## (`EventLogVM.tableMetrics`) and each column's widest cell over the rows
  ## held — the terminal's declaration (`eventLogFitColumns`,
  ## `eventLogDefaultCells`) in the terminal's units, so the desktop and the
  ## terminal make the same decision for the same rows and width (HO-13).
  let m = vm.tableMetrics.val
  let columns = vm.columns.val
  let rows = vm.eventRows.val
  var key = $m.cells & "|" & $columns.visibleColumns & "|" & $rows.len
  for col in EventLogColumn: key.add "," & $columns.widths[col]
  if rows.len > 0:
    key.add "|" & $rows[0].eventId & "|" & $rows[^1].eventId
  if fitCache.key == key:
    return fitCache.fit
  var widest: array[EventLogColumn, int]
  for row in rows:
    widest[elcTick] = max(widest[elcTick], ($row.rrTicks).len)
    widest[elcIndex] = max(widest[elcIndex], ($row.eventId).len)
    widest[elcLocation] = max(widest[elcLocation], rowLocation(row).runeLen)
    widest[elcOutput] = max(widest[elcOutput],
                            oneLine(eventLogText(row)).runeLen)
  result = fitTable(columns.eventLogFitColumns(widest, eventLogDefaultCells()),
                    m.cells, DesktopColumnGapCells)
  fitCache = (key, result)

proc desktopScrolls*(vm: EventLogVM): bool =
  ## SCROLL: the columns' floors do not fit the measured viewport — the
  ## table is laid out at them and its body scrolls sideways (HO-11).
  vm.tableMetrics.val.cells > 0 and vm.desktopFit.overflows

proc fitPx(vm: EventLogVM; cells: int): int =
  int(round(float(cells) * vm.tableMetrics.val.charPx))

proc tableMinWidthStyle*(vm: EventLogVM): string =
  ## The header's and the rows' width in SCROLL: the laid-out table's.
  if vm.desktopScrolls: "min-width: " & $vm.fitPx(vm.desktopFit.contentUnits) & "px"
  else: ""

proc scrollBodyStyle*(vm: EventLogVM): string =
  ## The body scrolls sideways only in SCROLL (the bar is overflow-only).
  if vm.desktopScrolls: "overflow-x: auto" else: ""

proc fitModeOf*(vm: EventLogVM): string =
  ## `data-ct-fit` on the table: the solver's mode, `fit` until measured.
  if vm.tableMetrics.val.cells <= 0: $fmFit else: $vm.desktopFit.mode

proc columnWidthStyle*(vm: EventLogVM; col: EventLogColumn): string =
  ## A column's width as its cells' style — header and body alike. In SCROLL
  ## (PLAT-70 Part I) every column is the solver's width; otherwise a column
  ## the user set (`EventLogColumns.widths`, `ColumnCellPx` pixels a cell) is
  ## that width and the others the stylesheet's own (Horizontal-Overflow.md
  ## §5.2), whose flex layout is the solver's FIT and SHRINK rule (fixed
  ## columns, the output the flex column).
  if vm.desktopScrolls:
    let fit = vm.desktopFit
    let k = vm.columns.val.visibleColumns.find(col)
    if k >= 0 and k < fit.widths.len:
      let px = $vm.fitPx(fit.widths[k] + DesktopColumnGapCells) & "px"
      return "flex: 0 0 " & px & "; width: " & px & "; max-width: " & px &
             "; min-width: " & px & "; box-sizing: border-box"
  let cells = vm.columns.val.widths[col]
  if cells <= 0: ""
  else:
    let px = $pxOfCells(cells) & "px"
    "flex: 0 0 " & px & "; width: " & px & "; max-width: " & px &
      "; min-width: " & px

proc columnHeaderText*(vm: EventLogVM; col: EventLogColumn): string =
  ## A header's label, with the order's arrow on the ordering column once the
  ## order is not the recorded one (tick, ascending).
  let order = vm.order()
  let title = if col == elcKind: "" else: eventLogColumnTitle(col)
  if order != RecordedEventOrder and order.column == col and title.len > 0:
    title & (if order.ascending: " ▲" else: " ▼")
  else:
    title

proc listPositions*(vm: EventLogVM): seq[int] =
  ## The positions, in the list the pane pages through, of the rows the
  ## ViewModel holds — the keys of the rows drawn.
  let start = vm.store.eventLog.loadedStart.val
  for i in 0 ..< vm.eventRows.val.len:
    result.add start + i

proc rowAt*(vm: EventLogVM; position: int): EventLogRow =
  ## The held row at `position`; an empty row once the window moved past it
  ## (its node is about to be dropped).
  let at = position - vm.store.eventLog.loadedStart.val
  let rows = vm.eventRows.val
  if at >= 0 and at < rows.len: rows[at] else: EventLogRow()

proc cellKey*(vm: EventLogVM; position: int; col: EventLogColumn): string =
  ## A body cell's name in the table panes' model (`data-ct-cell`): the pane,
  ## the event's id and the column, so it is cut, hovered and its `…`
  ## pressed through `table_overflow_dom` (Horizontal-Overflow.md §5).
  EventLogTablePane & "|" & $vm.rowAt(position).eventId & "|" & $col

proc rowClass*(vm: EventLogVM; position: int): string =
  ## A row's class: where it is against the debugger's position (`past`,
  ## `active`, `future` — the dimming a move changes, and the only thing it
  ## changes), and whether it is the current event (`event-selected`).
  let row = vm.rowAt(position)
  let now = vm.store.debugger.val.rrTicks
  let timing =
    if row.rrTicks < now: "past"
    elif row.rrTicks == now: "active"
    else: "future"
  var cls = EventLogRowClass & " " & timing
  if vm.store.eventLog.currentIndex.val == position:
    cls.add " event-selected"
  let sel = vm.selectedRow.val
  if sel.isSome and sel.get == position - vm.store.eventLog.loadedStart.val:
    cls.add " selected"
  cls

proc tickPercent(vm: EventLogVM; row: EventLogRow): float =
  ## Where the event's tick is on the recording's extent, for its tick bar.
  let timeline = vm.store.timeline.val
  let lo = float(timeline.minRRTicks)
  let hi = float(max(timeline.maxRRTicks, row.maxRRTicks))
  let t = float(row.rrTicks)
  if hi <= lo or t < lo: 0.0
  else: min(100.0, (t - lo) * 100.0 / (hi - lo))

proc tickRemainingWidth*(vm: EventLogVM; position: int): string =
  $(101.0 - tickPercent(vm, vm.rowAt(position))) & "%"

proc tickRemainingLeft*(vm: EventLogVM; position: int): string =
  $tickPercent(vm, vm.rowAt(position)) & "%"

proc rowLocation*(row: EventLogRow): string =
  ## The location column's text: the file's name and the line.
  if row.file.len == 0: ""
  else: row.file.rsplit('/', maxsplit = 1)[^1] & ":" & $row.line

proc isMultiline*(row: EventLogRow): bool =
  ## Whether the event's text spans lines (a trailing line break aside), so
  ## its kind cell offers to expand it.
  row.value.strip(leading = false, chars = {'\n', '\r'}).contains('\n')

proc expanderClass*(vm: EventLogVM; position: int): string =
  if vm.rowAt(position).isMultiline:
    "row-expander flow-hide-content flow-view-more-button"
  else:
    "row-expander-none"

proc listHeight*(vm: EventLogVM): string =
  ## The scroll area's height: the whole list's rows.
  $int(float(vm.listTotal) * vm.rowHeightPx.val) & "px"

proc windowOffset*(vm: EventLogVM): string =
  ## The held window's place in the scroll area.
  "translateY(" &
    $int(float(vm.store.eventLog.loadedStart.val) * vm.rowHeightPx.val) &
    "px)"

proc footerStart*(vm: EventLogVM): int =
  ## The footer's first row shown, counted from 1 (0 for an empty list).
  if vm.listTotal <= 0: 0
  else: min(vm.listTotal, max(0, vm.viewport.val.firstRow) + 1)

proc footerEnd*(vm: EventLogVM): int =
  ## The footer's last row shown.
  let v = vm.viewport.val
  min(vm.listTotal, max(0, v.firstRow) + max(0, v.rows))

proc footerClass*(vm: EventLogVM): string =
  ## The footer's class carries `<start>to<end>`, which the page objects
  ## read (`EventLogPane.rows`).
  "data-tables-footer " & $vm.footerStart & "to" & $vm.footerEnd

proc emptyDisplay*(vm: EventLogVM): string =
  displayIf(vm.loadingState.val != lsLoading and vm.listTotal <= 0 and
            vm.eventRows.val.len == 0)

proc markerBannerText*(vm: EventLogVM): string =
  ## §5.4.1 banner text.
  let banner = vm.loadingBanner.val
  case banner.phase
  of mlbLoading:
    "loading correlation markers… " & $banner.loaded & " / " & $banner.total & " firings"
  of mlbDone, mlbIdle:
    ""

proc markerBannerDisplay*(vm: EventLogVM): string =
  displayIf(vm.loadingBanner.val.phase == mlbLoading)

proc markerEmptyStateText*(vm: EventLogVM): string =
  ## §5.5 "N markers declared in source; none fired" banner.
  let state = vm.emptyState.val
  case state.kind
  of mesHidden: ""
  of mesDeclaredNoneFired:
    $state.declaredCount & " correlation markers declared in source; none fired during this recording"

proc markerEmptyStateDisplay*(vm: EventLogVM): string =
  displayIf(vm.emptyState.val.kind == mesDeclaredNoneFired)

proc markerToastText*(vm: EventLogVM): string =
  ## §7 one-time discovery toast.
  let toast = vm.toastState.val
  case toast.kind
  of mtHidden: ""
  of mtVisible:
    "CodeTracer discovered " & $toast.discoveredCount &
      " correlation markers in your source — matched output appears in the Event Log"

proc markerToastDisplay*(vm: EventLogVM): string =
  displayIf(vm.toastState.val.kind == mtVisible)

proc markerBoundaryChip*(row: MarkerEventRow): string =
  ## §5.1 boundary chip text, "[order-processing]".
  "[" & row.boundaryId & "]"

# ---------------------------------------------------------------------------
# Handlers, made by factories so each closes over its own value
# ---------------------------------------------------------------------------

proc onHeaderClick(vm: EventLogVM; col: EventLogColumn): proc() =
  result = proc() = vm.sortBy(vm.order().clickedHeader(col))

proc onRowClick(vm: EventLogVM; position: int): proc() =
  ## A click selects the event and moves the debugger to it.
  result = proc() =
    let at = position - vm.store.eventLog.loadedStart.val
    vm.selectRow(some(at))
    vm.doubleClickRow(at)

proc onToggleColumn(vm: EventLogVM; col: EventLogColumn): proc() =
  result = proc() = discard vm.toggleColumn(col)

proc columnShownText(vm: EventLogVM; col: EventLogColumn): string =
  ## The column menu's check is a toggle button: pressed while the column is
  ## shown (https://www.w3.org/TR/wai-aria-1.2/#aria-pressed).
  if vm.columns.val.isVisible(col): "true" else: "false"

proc onMoveColumn(vm: EventLogVM; col: EventLogColumn; delta: int): proc() =
  result = proc() = discard vm.moveColumn(col, delta)

# ---------------------------------------------------------------------------
# Rows
# ---------------------------------------------------------------------------

proc renderEventCell*[R, N](r: R; vm: EventLogVM; position: int;
                            col: EventLogColumn): N =
  ## One cell of the row at `position`, for column `col`.
  case col
  of elcTick:
    ui(r):
      td(class = columnClass(col), style = columnWidthStyle(vm, col)):
        tdiv(class = "rr-ticks-time-container"):
          span(class = "rr-ticks-time"):
            text $vm.rowAt(position).rrTicks
        tdiv(class = "rr-ticks-line-container"):
          span(class = "rr-ticks-line event-rr-ticks-line"):
            discard
          span(class = "rr-ticks-empty-remaining",
               width = tickRemainingWidth(vm, position),
               left = tickRemainingLeft(vm, position)):
            discard
  of elcIndex:
    ui(r):
      td(class = columnClass(col), style = columnWidthStyle(vm, col),
         `data-ct-cell` = cellKey(vm, position, col)):
        text $vm.rowAt(position).eventId
  of elcLocation:
    ui(r):
      td(class = columnClass(col), style = columnWidthStyle(vm, col),
         `data-ct-cell` = cellKey(vm, position, col)):
        text rowLocation(vm.rowAt(position))
  of elcKind:
    ui(r):
      td(class = columnClass(col), style = columnWidthStyle(vm, col)):
        span(class = expanderClass(vm, position)):
          discard
  of elcOutput:
    ui(r):
      td(class = columnClass(col), style = columnWidthStyle(vm, col),
         `data-ct-cell` = cellKey(vm, position, col)):
        text eventLogText(vm.rowAt(position))

proc renderEventRow*[R, N](r: R; vm: EventLogVM; position: int): N =
  ## The row at `position` of the list: its identity as `data-*` attributes
  ## (what the page objects find rows by), a cell per shown column.
  var rowEl: N
  let row = ui(r):
    tr(ref = rowEl, class = rowClass(vm, position),
       `data-position` = $position,
       `data-event-kind` = eventLogKindName(vm.rowAt(position)),
       `data-event-path` = vm.rowAt(position).file,
       `data-rr-ticks` = $vm.rowAt(position).rrTicks,
       `data-max-rr-ticks` = $vm.rowAt(position).maxRRTicks,
       `data-source-generation` = $vm.rowAt(position).sourceGeneration,
       `data-source-digest` = vm.rowAt(position).sourceDigest,
       role = "button", tabindex = "0",
       onclick = onRowClick(vm, position)):
      discard

  forEachKeyed[EventLogColumn, R, N](r, rowEl,
    proc(): seq[EventLogColumn] = vm.columns.val.visibleColumns,
    proc(col: proc(): EventLogColumn; index: proc(): int): N =
      renderEventCell[R, N](r, vm, position, col()))
  row

proc renderMarkerRow*[R, N](r: R; vm: EventLogVM;
                            item: proc(): MarkerEventRow): N =
  ## §5.1 marker row: direction icon, boundary chip (§5.3, the jump to the
  ## counterpart on the other side of the boundary), formatted show value.
  ui(r):
    tdiv(class = "marker-row marker-direction-" & directionWireText(item().direction),
         `data-marker-id` = $item().markerId,
         `data-boundary-id` = item().boundaryId,
         `data-key-value` = item().keyValue,
         `data-source-path` = item().sourcePath,
         `data-source-line` = $item().sourceLine,
         `data-step-id` = $item().stepId):
      span(class = "marker-direction-icon"):
        text directionDisplayIcon(item().direction)
      span(class = "marker-boundary-chip",
           role = "button", tabindex = "0",
           onclick = proc() = vm.jumpToCounterpartOf(item())):
        text markerBoundaryChip(item())
      span(class = "marker-show-value"):
        text formatShowValue(item())

# ---------------------------------------------------------------------------
# Browser decoration
# ---------------------------------------------------------------------------

when defined(js):
  proc inputValueOf(el: isonim_dom.Element): cstring
    {.importjs: "(#.value || '')".}
  proc setInputValue(el: isonim_dom.Element; v: cstring)
    {.importjs: "#.value = #".}
  proc onDomEvent(el: isonim_dom.Element; name: cstring;
                  handler: proc(ev: JsObject); capture: bool)
    {.importjs: "#.addEventListener(#, #, #)".}
  proc targetOf(ev: JsObject): isonim_dom.Element {.importjs: "#.target".}
  proc closestOf(el: isonim_dom.Element; sel: cstring): isonim_dom.Element
    {.importjs: "((e, s) => (e && e.closest && e.closest(s)) || null)(#, #)".}
  proc classListToggle(el: isonim_dom.Element; cls: cstring)
    {.importjs: "#.classList.toggle(#)".}
  proc stopPropagationOf(ev: JsObject) {.importjs: "#.stopPropagation()".}
  proc keyOf(ev: JsObject): cstring {.importjs: "(#.key || '')".}
  proc scrollTopOf(el: isonim_dom.Element): float
    {.importjs: "(#.scrollTop || 0)".}
  proc setScrollTop(el: isonim_dom.Element; v: float)
    {.importjs: "#.scrollTop = #".}
  proc clientHeightOf(el: isonim_dom.Element): float
    {.importjs: "(#.clientHeight || 0)".}
  proc isFocused(el: isonim_dom.Element): bool
    {.importjs: "(document.activeElement === #)".}

  proc decorateEventLogPanel*(vm: EventLogVM;
                              searchInput, footerInput, scrollBody,
                              dataTable: isonim_dom.Element) =
    ## The browser half of the panel.
    ##
    ## * The search field searches as the user types (`setSearchQuery`; the
    ##   engine matches, and the list restarts from the top).
    ## * The footer's row field scrolls the list to the row typed into it,
    ##   and otherwise follows the scroll.
    ## * A multi-line event's expander opens its text in place, without the
    ##   row click that would move the debugger.
    ## * The scrollbar is a scrubber over the whole (filtered) log
    ##   (Scrollbar-Scrubbers.md): its track jumps there, its thumb drags,
    ##   and a mark shows the current event (`currentIndex`).
    let rowPx = proc(): float = max(1.0, vm.rowHeightPx.val)
    # PLAT-70 Part I (§5.5): the columns' viewport, measured on every resize
    # and reported to the ViewModel; in SCROLL the header follows the body.
    attachEventLogFit(cast[JsObject](scrollBody), cast[JsObject](dataTable),
                      proc(cells: int; charPx: float) =
                        vm.setTableMetrics(cells, charPx))
    onDomEvent(searchInput, cstring"input", proc(ev: JsObject) =
      vm.setSearchQuery($inputValueOf(searchInput)), false)

    createEffect proc() =
      let shown = $vm.footerStart
      if not footerInput.isFocused:
        footerInput.setInputValue(cstring(shown))
    onDomEvent(footerInput, cstring"keydown", proc(ev: JsObject) =
      if ev.keyOf == cstring"Enter":
        try:
          let row = max(1, parseInt($inputValueOf(footerInput)))
          scrollBody.setScrollTop(float(row - 1) * rowPx())
        except ValueError:
          discard, false)

    onDomEvent(scrollBody, cstring"click", proc(ev: JsObject) =
      let expander = closestOf(ev.targetOf, cstring".row-expander")
      if isonim_dom.isNodeNil(isonim_dom.Node(expander)):
        return
      ev.stopPropagationOf()
      let row = closestOf(expander, cstring"tr")
      if not isonim_dom.isNodeNil(isonim_dom.Node(row)):
        row.classListToggle(cstring"eventLog-expanded")
      expander.classListToggle(cstring"flow-hide-content")
      expander.classListToggle(cstring"flow-show-content"), true)

    let visible = proc(): int =
      max(1, int(clientHeightOf(scrollBody) / rowPx()))
    discard attachListScrubber(
      cast[JsObject](scrollBody), cast[JsObject](dataTable),
      total = proc(): int = vm.listTotal,
      current = proc(): int = vm.store.eventLog.currentIndex.val,
      rowHeight = rowPx,
      paneId = "eventLog",
      # ROUNDED, as the shared scrubber's own default is: a jump to row `k`
      # asks for the offset `k * rowPx()`, which the scroll body can clamp a
      # few pixels short when the list's height is not a whole number of
      # rows (measured on a 70-event log: a press at the track's end asked
      # for row 50, the body stopped at 1337 px over 26.8 px rows, 49.9 rows,
      # with the last event in view; the floor read row 49 and reported the
      # last event as out of view).
      firstVisible = proc(): int = int(round(scrollTopOf(scrollBody) / rowPx())),
      visibleRows = visible,
      jumpTo = proc(row: int) =
        scrollBody.setScrollTop(float(max(0, row)) * rowPx()))

# ---------------------------------------------------------------------------
# The panel
# ---------------------------------------------------------------------------

proc renderEventLogPanel*[R, N](r: R; vm: EventLogVM): N =
  ## The Event Log panel.
  ##
  ##   div.component-container.eventLog.event-log-component
  ##     div.ct-flex                      filter button, search, columns menu
  ##     div.eventLog-columns-menu        a row per column (show, move)
  ##     marker banner / toast / empty    Correlation-Markers §5.4.1, §7, §5.5
  ##     div.event-log-marker-rows        §5.1 marker rows
  ##     div.eventLog-dense-table.data-table
  ##       div.eventLog-column-header     a cell per shown column (sorts)
  ##       div.eventLog-scroll-body       the scroller
  ##         div.eventLog-scroll-space    as tall as the whole list
  ##           table > tbody              the held window, `loadedStart` down
  ##       div.dt-empty                   the empty log's text
  ##     div.data-tables-footer           Rows <start> to <end> of <total>
  ##
  ## The filter button (`#category-image`) is the desktop's: its drop-down,
  ## a selection of event kinds by tag, is the host's (`ui/event_log.nim`),
  ## and sets `EventLogVM.selectedKinds`.
  var searchInput, columnsMenu, markerContainer, headerStrip: N
  var scrollBody, tbodyEl, dataTable, footerInput: N
  let panel = ui(r):
    tdiv(class = "component-container eventLog event-log-component",
         tabindex = "2"):
      tdiv(class = "ct-flex"):
        button(id = "category-image",
               class = "ct-button-image-md-secondary ct-button-no-border",
               title = "Filter", tabindex = "0"):
          discard
        input(ref = searchInput,
              class = "ct-input-panel ct-input-search-image eventLog-search-field",
              `type` = "text",
              placeholder = "Find event",
              value = vm.searchQuery.val)
        button(class = "ct-button-sm-secondary " & EventLogColumnsButtonClass,
               title = "Show, hide or move the event log's columns",
               onclick = proc() = vm.toggleColumnsMenu()):
          text EventLogColumnsButtonText
      tdiv(ref = columnsMenu, class = EventLogColumnsMenuClass,
           display = displayIf(vm.columnsMenuOpen.val)):
        discard
      tdiv(class = "event-log-marker-banner",
           display = markerBannerDisplay(vm)):
        text markerBannerText(vm)
      tdiv(class = "event-log-marker-toast",
           display = markerToastDisplay(vm)):
        text markerToastText(vm)
      tdiv(class = "event-log-marker-empty",
           display = markerEmptyStateDisplay(vm)):
        text markerEmptyStateText(vm)
      tdiv(ref = markerContainer, class = "event-log-marker-rows"):
        discard
      tdiv(ref = dataTable, class = "eventLog-dense-table data-table",
           `data-ct-fit` = fitModeOf(vm)):
        tdiv(ref = headerStrip, class = "eventLog-column-header",
             style = tableMinWidthStyle(vm)):
          discard
        tdiv(ref = scrollBody, class = EventLogScrollBodyClass,
             style = scrollBodyStyle(vm)):
          tdiv(class = "eventLog-scroll-space", height = listHeight(vm),
               style = tableMinWidthStyle(vm)):
            table(class = "eventLog-rows", transform = windowOffset(vm),
                  style = tableMinWidthStyle(vm)):
              tbody(ref = tbodyEl):
                discard
        tdiv(class = "dt-empty", display = emptyDisplay(vm)):
          text EventLogEmptyText
        tdiv(class = "event-log-loading",
             display = displayIf(vm.isLoading.val)):
          discard
      tdiv(class = footerClass(vm)):
        tdiv(class = "data-tables-footer-info"):
          span:
            text "Rows"
          input(ref = footerInput,
                class = "ct-input-small mx-2 data-tables-footer-input",
                value = "0")
          span:
            text "to"
          tdiv(class = "data-tables-footer-end-row"):
            text $vm.footerEnd
          span:
            text "of"
          tdiv(class = "data-tables-footer-rows-count"):
            text $vm.listTotal

  # The header: a cell per shown column, in the ViewModel's order. A cell
  # orders the log by its column, so it is a control, as a row is.
  forEachKeyed[EventLogColumn, R, N](r, headerStrip,
    proc(): seq[EventLogColumn] = vm.columns.val.visibleColumns,
    proc(col: proc(): EventLogColumn; index: proc(): int): N =
      ui(r):
        span(class = columnClass(col()), `data-column` = $col(),
             style = columnWidthStyle(vm, col()),
             role = "button", tabindex = "0",
             onclick = onHeaderClick(vm, col())):
          span(class = "eventLog-column-label"):
            text columnHeaderText(vm, col())
          # Its separator: the grip a drag resizes the column by (§5.2).
          span(class = EventLogColumnGripClass,
               `data-ct-column-separator` = $col()):
            discard)

  # The rows: the held window, keyed by position in the list.
  forEachKeyed[int, R, N](r, tbodyEl,
    proc(): seq[int] = listPositions(vm),
    proc(position: proc(): int; index: proc(): int): N =
      renderEventRow[R, N](r, vm, position()))

  indexEach[MarkerEventRow, R, N](r, markerContainer,
    proc(): seq[MarkerEventRow] = vm.visibleMarkerRows.val,
    proc(item: proc(): MarkerEventRow, index: int): N =
      renderMarkerRow[R, N](r, vm, item))

  # The column menu: the ViewModel's ORDER, hidden columns in their places
  # (a hidden column cannot move; its arrows do nothing).
  forEachKeyed[EventLogColumn, R, N](r, columnsMenu,
    proc(): seq[EventLogColumn] = vm.columns.val.order,
    proc(item: proc(): EventLogColumn; index: proc(): int): N =
      ui(r):
        tdiv(class = EventLogColumnOptionClass, `data-column` = $item()):
          span(class = columnCheckClass(vm, item()),
               role = "button", tabindex = "0",
               `aria-pressed` = columnShownText(vm, item()),
               onclick = onToggleColumn(vm, item())):
            text columnCheckGlyph(vm, item())
          span(class = "eventLog-column-title"):
            text columnOptionTitle(item())
          button(class = EventLogColumnLeftClass, title = "Move left",
                 onclick = onMoveColumn(vm, item(), -1)):
            text "◀"
          button(class = EventLogColumnRightClass, title = "Move right",
                 onclick = onMoveColumn(vm, item(), 1)):
            text "▶")

  when defined(js):
    when N is isonim_dom.Element:
      decorateEventLogPanel(vm, searchInput, footerInput, scrollBody,
                            dataTable)
  panel
