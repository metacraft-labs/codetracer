import
  strformat, strutils, kdom, vdom, karax, karaxdsl, jsffi,
  ../types, ../lib, ../types, ../ui_helpers

proc rowTimestamp*(row: Element, event: ProgramEvent, rrTicks: int) =
  let currentDebuggerLocation = rrTicks
  if event.directLocationRRTicks < currentDebuggerLocation:
    row.classList.add("past")
  elif event.directLocationRRTicks == currentDebuggerLocation:
    row.classList.add("active")
  else:
    row.classList.add("future")

proc renderRRTicksLine*(rrTicks: int64, minRRTicks: int64, maxRRTicks: int64, className: string): cstring =
  var percent = 0.0
  let rrTicksSymbols = ($(rrTicks)).len

  if maxRRTicks == minRRTicks:
    if rrTicks == minRRTicks:
      percent = 0.0
    else:
      percent = 0.0
  elif maxRRTicks < minRRTicks:
    percent = 0.0
  elif rrTicks < minRRTicks:
    percent = 0.0
  else:
    let diff = maxRRTicks - minRRTicks
    percent = (cast[float](rrTicks.toJs - minRRTicks.toJs) * 100.0) / (diff.float)

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
  let container = cast[Node](self.context.table().container())

  if not container.isNil:
    let containerHeight = container.toJs.clientHeight.to(int)
    let scrollArea = cast[Node](container.findNodeInElement(".dataTables_scroll"))
    let scrollBody = cast[Node](scrollArea.findNodeInElement(".dataTables_scrollBody"))

    scrollArea.style.height = &"{containerHeight}px"
    scrollArea.style.maxHeight = &"{containerHeight}px"
    scrollBody.style.height = &"{containerHeight}px"
    scrollBody.style.maxHeight = &"{containerHeight}px"
    self.scrollAreaHeight = containerHeight
    self.context.scroller.measure()

proc updateTableFooter*(self: DataTableComponent) =
  if not self.inputFieldChange:
    let inputField = self.footerDom.findNodeInElement(".data-tables-footer-input")
    inputField.value = cstring($(self.startRow))

  let endRowField = self.footerDom.findNodeInElement(".data-tables-footer-end-row")
  endRowField.innerHTML = cstring($(self.endRow))

  let rowsCountField = self.footerDom.findNodeInElement(".data-tables-footer-rows-count")
  rowsCountField.innerHTML = cstring($(self.rowsCount))


proc updateTableRows*(self: DataTableComponent, redraw: bool = true) =
  let context = self.context
  let scroller = context.scroller
  let page = scroller.page()

  self.startRow = cast[int](page.start) + 1  
  self.endRow = cast[int](page["end"]) + 1

  if redraw:
    data.redraw()

proc resizeTable*(self: DataTableComponent) =
  if not self.context.isNil:
    self.resizeTableScrollArea()
    self.updateTableRows()

proc scrollTable*(table: DataTableComponent, position: cstring) =
  try:
    let startRow = parseInt($position)

    if startRow != 0:
      table.context.scroller.toPosition(max(startRow - floor((table.endRow - table.startRow) / 2), 0))
      table.updateTableRows()
    else:
      table.context.scroller.toPosition(startRow)
      table.updateTableRows()

  except:
    cerror getCurrentExceptionMsg()

proc tableFooter*(table: DataTableComponent): VNode =
  let class = &"data-tables-footer {table.startRow}to{table.endRow}"

  buildHtml(
    tdiv(class = class)
  ):
    tdiv(class = "data-tables-footer-info"):
      text "Rows"
      input(
        class = "data-tables-footer-input",
        onkeydown = proc(ev: KeyboardEvent, et: VNode) =
          if ev.keyCode == ENTER_KEY_CODE:
            table.inputFieldChange = false
            scrollTable(table, ev.target.value)
          else:
            table.inputFieldChange = true
            ev.stopPropagation(),
        value = $(table.startRow)
      )
      text "to"
      tdiv(class="data-tables-footer-end-row"):
        text($(table.endRow))
      text "of"
      tdiv(class="data-tables-footer-rows-count"):
        text($(table.rowsCount))

proc removeTracepointResults*(table: DataTableComponent, tracepoint: Tracepoint) =
  discard
