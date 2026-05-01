import
  std / [strformat, strutils, jsffi, math],
  kdom, vdom, karax, karaxdsl,
  ../types,
  ../lib/[ logging, jslib ]

proc getBoundingClientRect(node: js): HTMLBoundingRect {.importjs:"#.getBoundingClientRect()".}
proc tableScrollerInstance(tableContext: js): js {.importjs:"#.settings()[0].oScroller".}

proc roundLayoutPixels(value: float): int =
  if value <= 0.0:
    return 0

  result = max(1, value.round.int)

proc tableContainer(self: DataTableComponent): Node =
  if self.context.isNil:
    return nil

  let container = self.context.table().container()
  if container.isNil:
    return nil

  cast[Node](container)

proc tableViewport(self: DataTableComponent): Node =
  let container = self.tableContainer()

  if container.isNil:
    return nil

  if not container.parentNode.isNil:
    cast[Node](container.parentNode)
  else:
    container

proc tableScrollArea(self: DataTableComponent): Node =
  let container = self.tableContainer()

  if container.isNil:
    return nil

  cast[Node](container.findNodeInElement(".dt-scroll"))

proc tableScrollBody(self: DataTableComponent): Node =
  let scrollArea = self.tableScrollArea()

  if scrollArea.isNil:
    return nil

  cast[Node](scrollArea.findNodeInElement(".dt-scroll-body"))

proc tableScrollHead(self: DataTableComponent): Node =
  let scrollArea = self.tableScrollArea()

  if scrollArea.isNil:
    return nil

  cast[Node](scrollArea.findNodeInElement(".dt-scroll-head"))

proc tableScrollFoot(self: DataTableComponent): Node =
  let scrollArea = self.tableScrollArea()

  if scrollArea.isNil:
    return nil

  cast[Node](scrollArea.findNodeInElement(".dt-scroll-foot"))

proc measuredNodeHeight(node: Node): int =
  if node.isNil:
    return 0

  let rect = getBoundingClientRect(node.toJs)
  result = roundLayoutPixels(rect.height)

  if result == 0:
    result = node.toJs.clientHeight.to(int)

proc measureRenderedRowHeight(self: DataTableComponent): int =
  let scrollBody = self.tableScrollBody()

  if scrollBody.isNil:
    return self.rowHeight

  let row = cast[Node](scrollBody.findNodeInElement("tbody tr"))
  if row.isNil:
    return self.rowHeight

  let measuredHeight = measuredNodeHeight(row)
  if measuredHeight > 0:
    self.rowHeight = measuredHeight

  result = self.rowHeight

proc visibleViewportRows(self: DataTableComponent): int =
  let viewportHeight = measuredNodeHeight(self.tableScrollBody())
  let rowHeight = self.measureRenderedRowHeight()

  if viewportHeight <= 0 or rowHeight <= 0:
    return 0

  result = max(1, int(ceil(viewportHeight.float / rowHeight.float)))

proc syncScrollerMeasurements(self: DataTableComponent) =
  if self.context.isNil:
    return

  let scroller = tableScrollerInstance(self.context)
  if scroller.isNil or scroller.toJs == jsUndefined:
    return

  let rowHeight = self.measureRenderedRowHeight()
  if rowHeight <= 0:
    return

  # Scroller keeps its own cached row height; update it before remeasuring so
  # zoom/font-size changes don't leave a stale virtual scroll range behind.
  scroller.s.rowHeight = rowHeight
  scroller.s.heights.row = rowHeight
  scroller.s.autoHeight = false

proc rowTimestamp*(row: Element, event: ProgramEvent, rrTicks: int) =
  let currentDebuggerLocation = rrTicks
  if event.directLocationRRTicks < currentDebuggerLocation:
    row.classList.add("past")
  elif event.directLocationRRTicks == currentDebuggerLocation:
    row.classList.add("active")
  else:
    row.classList.add("future")

proc renderRRTicksLine*(rrTicks: int, minRRTicks: int, maxRRTicks: int, className: string): cstring =
  ## Render a visual timeline bar for the given rr ticks position.
  ## All arithmetic is done in float to avoid Nim 2.2 BigInt issues
  ## (int64 maps to JS BigInt and cannot be mixed with float).
  var percent = 0.0
  let rrTicksF = float(rrTicks)
  let minF = float(minRRTicks)
  let maxF = float(maxRRTicks)

  if maxF == minF:
    percent = 0.0
  elif maxF < minF:
    percent = 0.0
  elif rrTicksF < minF:
    percent = 0.0
  else:
    percent = ((rrTicksF - minF) * 100.0) / (maxF - minF)

  let remainingPercent = 101.0 - percent

  cstring(
    &"<div class=\"rr-ticks-time-container\">" &
    &"<span class=\"rr-ticks-time\">{rrticks}</span>" &
    &"</div>"&
    &"<div class=\"rr-ticks-line-container\">" &
    &"<span class=\"rr-ticks-line {className}\"></span>" &
    &"<span class=\"rr-ticks-empty-remaining\" style=\"width:{remainingPercent}%; left:{percent}%\"></span>" &
    &"</div>"
  )

proc resizeTableScrollArea*(self: DataTableComponent) =
  let container = self.tableContainer()

  if not container.isNil:
    # DataTables measures itself from its wrapper, but our real viewport is the
    # surrounding `.data-table` flex item. Reusing the wrapper height keeps the
    # previous explicit size around, which breaks visible-row calculations after zooming.
    let viewport = self.tableViewport()
    let viewportHeight = measuredNodeHeight(viewport)
    let containerHeight =
      if viewportHeight > 0:
        viewportHeight
      else:
        measuredNodeHeight(container)
    let scrollArea = self.tableScrollArea()
    let scrollBody = self.tableScrollBody()
    let scrollHead = self.tableScrollHead()
    let scrollFoot = self.tableScrollFoot()
    let scrollBodyHeight =
      if containerHeight > 0:
        max(containerHeight - measuredNodeHeight(scrollHead) - measuredNodeHeight(scrollFoot), 1)
      else:
        0

    if containerHeight > 0 and scrollBodyHeight > 0 and not scrollArea.isNil and not scrollBody.isNil:
      container.style.height = cstring(fmt"{containerHeight}px")
      container.style.maxHeight = cstring(fmt"{containerHeight}px")
      scrollArea.style.height = cstring(fmt"{containerHeight}px")
      scrollArea.style.maxHeight = cstring(fmt"{containerHeight}px")
      scrollBody.style.height = cstring(fmt"{scrollBodyHeight}px")
      scrollBody.style.maxHeight = cstring(fmt"{scrollBodyHeight}px")
      self.scrollAreaHeight = containerHeight
      discard self.context.columns.adjust()
      self.syncScrollerMeasurements()
      self.context.scroller.measure()

proc updateTableFooter*(self: DataTableComponent) =
  if self.footerDom.isNil:
    return

  if not self.inputFieldChange:
    let inputField = self.footerDom.findNodeInElement(".data-tables-footer-input")
    if not inputField.isNil:
      inputField.value = cstring($(self.startRow))

  let endRowField = self.footerDom.findNodeInElement(".data-tables-footer-end-row")
  if not endRowField.isNil:
    endRowField.innerHTML = cstring($(self.endRow))

  let rowsCountField = self.footerDom.findNodeInElement(".data-tables-footer-rows-count")
  if not rowsCountField.isNil:
    rowsCountField.innerHTML = cstring($(self.rowsCount))


proc updateTableRows*(self: DataTableComponent, redraw: bool = true) =
  if self.context.isNil:
    return

  let context = self.context
  let scroller = context.scroller
  let page = scroller.page()
  let totalRows = max(self.rowsCount, 0)
  var startRow = max(cast[int](page.start), 0)
  var endRow = max(cast[int](page["end"]), startRow)
  let visibleRows = self.visibleViewportRows()

  if totalRows == 0:
    self.startRow = 0
    self.endRow = 0
  else:
    if visibleRows > 0:
      endRow = min(startRow + visibleRows - 1, totalRows - 1)
    else:
      endRow = min(endRow, totalRows - 1)

    self.startRow = startRow + 1
    self.endRow = endRow + 1

  if redraw:
    data.redraw()

proc resizeTable*(self: DataTableComponent) =
  if not self.context.isNil:
    self.resizeTableScrollArea()
    self.updateTableRows(redraw = false)
    if not self.footerDom.isNil:
      self.updateTableFooter()

proc scrollTable*(table: DataTableComponent, position: cstring) =
  try:
    let startRow = parseInt($position)

    if startRow != 0:
      let viewportHalf = max((table.endRow - table.startRow) div 2, 0)
      table.context.scroller.toPosition(max(startRow - viewportHalf, 0))
      table.updateTableRows()
    else:
      table.context.scroller.toPosition(startRow)
      table.updateTableRows()

  except:
    cerror getCurrentExceptionMsg()

proc tableFooter*(table: DataTableComponent): VNode =
  let class = cstring(fmt"data-tables-footer {table.startRow}to{table.endRow}")

  buildHtml(
    tdiv(class = class)
  ):
    tdiv(class = "data-tables-footer-info"):
      text "Rows"
      input(
        class = "data-tables-footer-input ct-input-small mx-2",
        onkeydown = proc(ev: KeyboardEvent, et: VNode) =
          if ev.keyCode == ENTER_KEY_CODE:
            table.inputFieldChange = false
            scrollTable(table, ev.target.value)
          else:
            table.inputFieldChange = true
            ev.stopPropagation(),
        value = cstring($(table.startRow))
      )
      text "to"
      tdiv(class="data-tables-footer-end-row"):
        text($(table.endRow))
      text "of"
      tdiv(class="data-tables-footer-rows-count"):
        text($(table.rowsCount))

proc removeTracepointResults*(table: DataTableComponent, tracepoint: Tracepoint) =
  discard
