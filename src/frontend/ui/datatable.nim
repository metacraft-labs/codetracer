import
  std / [strformat, strutils, jsffi, math],
  kdom,
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

proc viewportSiblingsHeight(viewport, container: js): float {.importjs: """
  (function(v, c) {
    let total = 0;
    for (const child of v.children) {
      if (child === c) continue;
      const style = getComputedStyle(child);
      if (style.display === "none" || style.position === "absolute" ||
          style.position === "fixed") continue;
      const r = child.getBoundingClientRect();
      total += r.height + (parseFloat(style.marginTop) || 0) +
        (parseFloat(style.marginBottom) || 0);
    }
    return total;
  })(#, #)""".}
  ## The height of what shares the viewport with the table — a strip the
  ## panel draws above it (the event log's column header) or below it — that
  ## the table must leave room for.  Out-of-flow children overlay rather than
  ## take room, so they are not counted.

proc scrollerRowHeight(scroller: js): float {.importjs: "(Number(#.s.heights.row) || 0)".}
  ## The row height the Scroller is laying the table out with (its
  ## `s.heights.row`), or 0 while it has none. Every pixel the Scroller
  ## computes — the virtual body's height, the scroll offset of a row, and
  ## `page()`, which the footer reports — is that many pixels per row.

proc commonDrawnRowHeight(scrollBody: js): float {.importjs: """
  (function(body) {
    const byHeight = new Map();
    for (const tr of body.querySelectorAll("tbody > tr")) {
      if (tr.querySelector(".dt-empty, .dataTables_empty")) continue;
      const h = tr.getBoundingClientRect().height;
      if (!(h > 0)) continue;
      const key = Math.round(h * 100);
      const seen = byHeight.get(key);
      if (seen) seen.count += 1; else byHeight.set(key, { height: h, count: 1 });
    }
    let best = null;
    for (const g of byHeight.values()) {
      if (!best || g.count > best.count ||
          (g.count === best.count && g.height < best.height)) best = g;
    }
    return best ? best.height : 0;
  })(#)""".}
  ## The height most of the drawn EVENT rows share, or 0 while none is drawn
  ## (or the table is hidden, when every row measures 0).
  ##
  ## A table with no rows yet (before the first `ct/update-table` reply, or a
  ## search that matched nothing) still draws one row: DataTables' empty-table
  ## message (`td.dt-empty`). `styles/components/empty_states.styl` stretches
  ## that row to the whole scroll body so the message centres in the pane, so
  ## its height is the VIEWPORT's, not a row's. It must never be taken for a
  ## row: measured 2026-10-22 on `noir_space_ship`, it made the Scroller lay
  ## 70 rows of 27.6px out as 70 rows of 355px (#850).
  ##
  ## The most common height, not the first row's: the Scroller assumes every
  ## row is one height, and the rows are, except one the user has expanded
  ## (the output cell's `row-expander`, 73.6px against 27.6px). Taking that
  ## row's height when it happens to be first drawn would size the whole log
  ## to it and leave the viewport over rows that are not there. A tie goes to
  ## the shorter height, since an expanded row is only ever taller.

proc measureRenderedRowHeight(self: DataTableComponent): float =
  ## The height of the rows the table draws, kept in `self.rowHeight`.
  ##
  ## Fractional on purpose: the Scroller multiplies it by the row count to
  ## size the virtual body and divides scroll offsets by it to name rows, so a
  ## rounded height drifts by the rounding error times the row count — on a
  ## 27.64px row rounded to 28, a whole row by the end of a 70-row log. While
  ## no event row is drawn, the last known height is returned unchanged.
  let scrollBody = self.tableScrollBody()
  if scrollBody.isNil:
    return self.rowHeight

  let measuredHeight = commonDrawnRowHeight(scrollBody.toJs)
  if measuredHeight > 0.0:
    self.rowHeight = measuredHeight

  result = self.rowHeight

proc visibleViewportRows(self: DataTableComponent): int =
  # Measure from the .data-table flex-item (tableViewport) rather than the
  # scroll body's inline style, so the count reflects the event log's actual
  # rendered height and stays correct after panel resize.
  var viewportHeight = measuredNodeHeight(self.tableViewport())
  if viewportHeight <= 0:
    # Fall back to the scroll body if the viewport isn't measurable yet.
    viewportHeight = measuredNodeHeight(self.tableScrollBody())
  let rowHeight = self.measureRenderedRowHeight()

  if viewportHeight <= 0 or rowHeight <= 0.0:
    return 0

  result = max(1, int(ceil(viewportHeight.float / rowHeight)))

proc syncScrollerMeasurements(self: DataTableComponent) =
  if self.context.isNil:
    return

  let scroller = tableScrollerInstance(self.context)
  if scroller.isNil or scroller.toJs == jsUndefined:
    return

  let rowHeight = self.measureRenderedRowHeight()
  if rowHeight <= 0.0:
    return

  # Scroller keeps its own cached row height and viewport height; update both
  # before remeasuring so zoom/font-size/resize changes don't leave stale
  # virtual scroll dimensions behind.
  scroller.s.rowHeight = rowHeight
  scroller.s.heights.row = rowHeight
  scroller.s.autoHeight = false

  let scrollBodyHeight = measuredNodeHeight(self.tableScrollBody())
  if scrollBodyHeight > 0:
    # Tell the Scroller the current viewport height so measure() uses the
    # correct value rather than re-reading from a potentially stale DOM state.
    scroller.s.heights.viewport = scrollBodyHeight

proc rowSemanticKind(event: ProgramEvent): string =
  if not event.semanticKind.isNil and event.semanticKind.len > 0:
    $event.semanticKind
  else:
    $event.kind

proc rowTimestamp*(row: Element, event: ProgramEvent, rrTicks: int) =
  row.setAttribute(cstring"data-event-kind", cstring(rowSemanticKind(event)))
  row.setAttribute(cstring"data-rr-ticks", cstring($event.directLocationRRTicks))
  row.setAttribute(cstring"data-source-generation", cstring($event.sourceGeneration))
  row.setAttribute(cstring"data-source-digest", cstring(event.sourceDigest))
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
    &"<div class=\"rr-ticks-time-container\" style=\"height:auto;line-height:normal\">" &
    &"<span class=\"rr-ticks-time\" style=\"display:block;font-size:0.85em;text-indent:0\">{rrticks}</span>" &
    &"</div>" &
    &"<div class=\"rr-ticks-line-container\" style=\"margin-top:0.05em\">" &
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
    # Less whatever else stands in the viewport with the table: without this
    # the event log's column header (drawn above the table, inside the same
    # `.data-table`) made the scroll body exactly that much too tall, so its
    # bottom — and the horizontal scrollbar on it — slid under the footer.
    let siblings =
      if viewport.isNil or viewport == container: 0
      else: roundLayoutPixels(viewportSiblingsHeight(viewport.toJs, container.toJs))
    let viewportHeight = max(measuredNodeHeight(viewport) - siblings, 0)
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

      # Capture the current first-visible row BEFORE syncScrollerMeasurements
      # gives the Scroller the new row height.  The scroll offset was laid out
      # in the Scroller's OWN row height, so that is the divisor that names
      # the row at the top — not `self.rowHeight`, which any footer update
      # re-measures from the drawn rows and so may already hold the new value
      # (zoom, or the first real rows after the empty-table message).  We use
      # this to restore the same starting row after the change regardless of
      # direction (zoom-in makes rows taller; zoom-out makes them shorter).
      let currentScrollTop = scrollBody.toJs.scrollTop.to(float)
      let scrollerBefore = tableScrollerInstance(self.context)
      let oldRowHeight =  # 0 on the first call: no layout to preserve yet
        if scrollerBefore.isNil or scrollerBefore.toJs == jsUndefined: self.rowHeight
        else: scrollerRowHeight(scrollerBefore)

      self.syncScrollerMeasurements()

      # Reposition scrollTop so the same first visible row stays at the top
      # after zoom.  On the very first resize (oldRowHeight = 0, no rows yet)
      # we skip this and let the Scroller start from the top.
      if self.rowsCount > 0 and oldRowHeight > 0.0:
        let newRowH = self.measureRenderedRowHeight()
        if newRowH > 0.0:
          let startRow = math.floor(currentScrollTop / oldRowHeight)
          let virtualHeight = float(self.rowsCount) * newRowH
          let maxScrollTop = max(0.0, virtualHeight - float(scrollBodyHeight))
          # startRow * newRowH preserves the position; clamp so we never
          # overshoot the end of the virtual area (zoom-out near the bottom).
          scrollBody.toJs.scrollTop = min(startRow * newRowH, maxScrollTop)

      let scroller = self.context.scroller
      if not scroller.isNil and scroller.toJs != jsUndefined:
        scroller.measure()

proc updateTableFooter*(self: DataTableComponent) =
  ## Synchronise the footer DOM (rendered statically by an IsoNim shell
  ## or created directly by `tableFooterDom`) with the current `startRow`,
  ## `endRow`, and `rowsCount` fields.
  ##
  ## The footer shell is rendered once with a static structure; this proc
  ## is the mechanism that keeps the visible counters in sync as DataTables
  ## reports new totals via the ajax callback.
  ##
  ## Page-object tests (e.g. `EventLogTab.getRows`) parse the parent
  ## `.data-tables-footer` element's class with the regex `(\d*)to`
  ## to read the current start row, so the class string must be kept
  ## in sync as well — otherwise the assertion stays at the literal
  ## "0to0" emitted at mount time.
  if self.footerDom.isNil:
    return

  # The suffix `<startRow>to<endRow>` is part of the test contract — see
  # `EventLogTab.getRows()` in
  # src/tests/gui/page-objects/layout_page.ts which parses the regex
  # `(\d*)to` out of the class attribute.
  self.footerDom.setAttribute(
    cstring"class",
    cstring(fmt"data-tables-footer {self.startRow}to{self.endRow}"))

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


proc syncScrollerToDrawnRows(self: DataTableComponent) =
  ## Re-measure the Scroller when the rows it is laying out are not the height
  ## it holds for them (#850).
  ##
  ## The Scroller's row height is written by `syncScrollerMeasurements`, which
  ## only `resizeTableScrollArea` runs: on a resize, and once on the data path.
  ## Neither is tied to the moment the table first draws REAL rows. On a trace
  ## open the table is sized while it still shows its empty-table message, and
  ## the one data-path resize is keyed to the first `ct/update-table` reply —
  ## which is commonly the empty one sent before `ct/event-load` has loaded the
  ## log. The Scroller then keeps a height that is not a row's for the whole
  ## session, and with it a virtual body, a fetch length and a `page()` (the
  ## footer) that all describe rows the table does not draw: the reported
  ## "Rows 19 to 34 of 73" at the bottom of the log.
  ##
  ## So whenever event rows are drawn, compare their common height with the
  ## Scroller's and, when they differ, run the whole resize: it writes the
  ## measured height and the viewport, keeps the row at the top where it was,
  ## and re-measures the Scroller (`scroller.measure()`), which re-fetches the
  ## window with the fetch length the true height implies. Once they agree
  ## this only reads the drawn rows' boxes and changes nothing, so it does not
  ## disturb a scroll in progress, and an expanded row does not set it off
  ## (`commonDrawnRowHeight`).
  ##
  ## Scroller's layout arithmetic: `dataTables.scroller.mjs` (`_scrollForce`,
  ## `measure`, `pixelsToRow`), https://datatables.net/extensions/scroller/
  if self.context.isNil:
    return

  let scroller = tableScrollerInstance(self.context)
  if scroller.isNil or scroller.toJs == jsUndefined:
    return

  let scrollBody = self.tableScrollBody()
  if scrollBody.isNil:
    return

  let drawnHeight = commonDrawnRowHeight(scrollBody.toJs)
  # Sub-pixel tolerance only: the Scroller is given the measured value
  # verbatim, so once synced the two are equal.
  if drawnHeight > 0.0 and abs(drawnHeight - scrollerRowHeight(scroller)) > 0.01:
    self.resizeTableScrollArea()

proc updateTableRows*(self: DataTableComponent, redraw: bool = true) =
  if self.context.isNil:
    return

  # The footer below is the Scroller's `page()`, which is only true while the
  # Scroller's row height is the drawn rows'.
  self.syncScrollerToDrawnRows()

  let context = self.context
  let scroller = context.scroller
  # Guard: the Scroller plugin may not be ready yet when DataTables is
  # still processing its first server-side ajax request.  In that case
  # `scroller` is undefined or `scroller.page()` returns undefined.
  if scroller.isNil or scroller.toJs == jsUndefined:
    return
  let page = scroller.page()
  if page.isNil:
    return
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
  ## Scroll the virtual table so the row at `position` (a row index rendered
  ## as text) is in view.
  ##
  ## `table.context` is the live jQuery-DataTables instance
  ## (https://datatables.net/reference/api/) and is legitimately nil in two
  ## windows on the *normal* startup path, not just in error cases:
  ##
  ##   * before ``EventLogComponent.updateTable`` has constructed the dense
  ##     and detailed tables — that only happens once the event log's
  ##     server-side ajax round-trip returns, while the debugger reports its
  ##     entry location (and therefore fires ``onCompleteMove`` →
  ##     ``scrollOnMove`` → here) as soon as the trace opens; and
  ##   * between ``EventLogComponent.restart`` clearing ``context`` and the
  ##     rebuilt table replacing it.
  ##
  ## A scroll request in either window is DROPPED, and that is the behaviour
  ## this guard preserves rather than one it introduces: the dereference used
  ## to raise, the blanket ``except`` below swallowed it, and no scroll
  ## happened either way.  ``DataTableComponent.activeRowIndex`` looks like it
  ## would carry the intent forward, but it is written and never read back —
  ## nothing re-applies it once the table exists — so do not rely on it here.
  ## Whether an early scroll request should instead be REPLAYED when
  ## ``updateTable`` finishes is a real question about the event log's startup
  ## behaviour; it is deliberately out of scope for the log-noise fix, and
  ## changing it here would silently alter where the event log lands on open.
  ##
  ## Guarding here rather than relying on the ``except`` below is what makes
  ## the log readable.  Dereferencing ``table.context.scroller`` with a nil
  ## context raised ``Cannot read properties of null (reading 'scroller')``
  ## four times on *every* trace open, and the blanket handler reported each
  ## one at ERROR — an unconditional error on the happy path that trains
  ## readers to ignore the console (Value-Origin-Tracking milestone M48).
  ## The handler is kept for genuine DataTables failures.
  if table.isNil or table.context.isNil:
    return

  try:
    let startRow = parseInt($position)

    if startRow != 0:
      let viewportHalf = max((table.endRow - table.startRow) div 2, 0)
      let scroller = table.context.scroller
      if not scroller.isNil and scroller.toJs != jsUndefined:
        scroller.toPosition(max(startRow - viewportHalf, 0))
        table.updateTableRows()
    else:
      let scroller = table.context.scroller
      if not scroller.isNil and scroller.toJs != jsUndefined:
        scroller.toPosition(startRow)
        table.updateTableRows()

  except:
    # Reaching here now means a real DataTables/Scroller failure, so say
    # which operation failed instead of logging a bare message.
    cerror "datatable: scrollTable(" & $position & ") failed: " &
      getCurrentExceptionMsg()

proc appendFooterText(parent: Node, value: cstring) =
  parent.appendChild(document.createTextNode(value))

proc footerDiv(className: cstring = cstring""): Node =
  result = document.createElement(cstring"div")
  if className != cstring"":
    result.setAttribute(cstring"class", className)

proc tableFooterDom*(table: DataTableComponent): Node =
  result = footerDiv(cstring(fmt"data-tables-footer {table.startRow}to{table.endRow}"))

  let info = footerDiv(cstring"data-tables-footer-info")
  result.appendChild(info)

  info.appendFooterText(cstring"Rows")

  let input = document.createElement(cstring"input")
  input.setAttribute(cstring"class", cstring"data-tables-footer-input ct-input-small mx-2")
  input.value = cstring($(table.startRow))
  input.addEventListener(cstring"keydown", proc(ev: Event) =
    let keyboardEvent = cast[KeyboardEvent](ev)
    if keyboardEvent.keyCode == ENTER_KEY_CODE:
      table.inputFieldChange = false
      scrollTable(table, ev.target.value)
    else:
      table.inputFieldChange = true
      ev.stopPropagation()
  )
  info.appendChild(input)

  info.appendFooterText(cstring"to")

  let endRow = footerDiv(cstring"data-tables-footer-end-row")
  endRow.appendFooterText(cstring($(table.endRow)))
  info.appendChild(endRow)

  info.appendFooterText(cstring"of")

  let rowsCount = footerDiv(cstring"data-tables-footer-rows-count")
  rowsCount.appendFooterText(cstring($(table.rowsCount)))
  info.appendChild(rowsCount)

proc removeTracepointResults*(table: DataTableComponent, tracepoint: Tracepoint) =
  discard
