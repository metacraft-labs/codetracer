## views/table_fit_dom.nim — PLAT-70 Part I on the desktop (Electron and the
## web build): the table panes fit or scroll (Horizontal-Overflow.md §5.5).
##
## The decision is the shared solver's (`viewmodels/table_fit`): this module
## measures what only a browser knows — a pane's width and one character of
## its font — and projects the decision onto the DOM:
##
##   * the Event Log: its viewport in characters, reported to the ViewModel
##     (`EventLogVM.setTableMetrics`), which lays the columns out in the
##     terminal's units (`isonim_event_log_view.desktopFit`); in SCROLL the
##     header strip follows the body's sideways scroll;
##   * the Call Trace: each drawn row's floor (its text's left, its callee's
##     name, a `…`) and whole width, measured off the row; FIT and SHRINK cut
##     every row at the pane (its call box a table cell, `data-ct-cell`, so
##     Part B's pass marks the cut and gives it the hover, the detail and
##     the copy); SCROLL lays the rows out at the widest floor and the list
##     scrolls sideways (§5.5.5 — OQ-H5, proposed, awaiting the user);
##   * the State pane: each row's floor (everything but its value, and the
##     value's first cells) measured off the row; in SCROLL the rows are as
##     wide as the widest floor and the box scrolls sideways.
##
## `data-ct-fit` on each pane's scroller says the mode (`fit`, `shrink`,
## `scroll`), for a reader of the DOM.

when defined(js):
  import std/[jsffi, math, strutils]
  from std/unicode import runeLen

  import ../viewmodels/table_fit

  const
    TableFitAttribute* = "data-ct-fit"
      ## The solver's mode, on the element that scrolls.
    ScrubberPx = 8
      ## The list scrubber over a scroller's right edge (`list_scrubber.styl`,
      ## PANEL_SCROLLBAR_SIZE): not room for text.
    CalleeAttribute* = "data-ct-callee"
      ## On a call row's box: its callee's name (the floor keeps it whole).

  proc charPxOf(el: JsObject): float {.importjs: """(function(el){
      const s = getComputedStyle(el);
      const c = (window.__ctCharCanvas = window.__ctCharCanvas ||
                 document.createElement('canvas')).getContext('2d');
      c.font = s.fontStyle + ' ' + s.fontWeight + ' ' + s.fontSize + ' ' +
               s.fontFamily;
      const w = c.measureText('0000000000').width / 10;
      return w > 0 ? w : 8;
    })(#)""".}
  proc clientWidthOf(el: JsObject): float {.importjs: "#.clientWidth".}
  proc queryAll(el: JsObject; sel: cstring): seq[JsObject]
    {.importjs: "Array.from(#.querySelectorAll(#))".}
  proc query(el: JsObject; sel: cstring): JsObject
    {.importjs: "#.querySelector(#)".}
  proc isNil(el: JsObject): bool {.importjs: "(# == null)".}
  proc attr(el: JsObject; name: cstring): cstring
    {.importjs: "(#.getAttribute(#) || '')".}
  proc setAttr(el: JsObject; name, value: cstring)
    {.importjs: "#.setAttribute(#, #)".}
  proc setStyle(el: JsObject; key, value: cstring)
    {.importjs: "#.style.setProperty(#, #)".}
  proc removeStyle(el: JsObject; key: cstring)
    {.importjs: "#.style.removeProperty(#)".}
  proc textOf(el: JsObject): cstring {.importjs: "(#.textContent || '')".}
  proc leftIn(el, row: JsObject): float {.importjs: """(function(el,row){
      return el.getBoundingClientRect().left - row.getBoundingClientRect().left;
    })(#,#)""".}
  proc scrollLeftOf(el: JsObject): float {.importjs: "#.scrollLeft".}
  proc setScrollLeft(el: JsObject; v: float) {.importjs: "#.scrollLeft = #".}
  proc listen(el: JsObject; name: cstring; f: proc(ev: JsObject))
    {.importjs: "#.addEventListener(#, #, {passive: true})".}
  proc newResizeObserver(f: proc()): JsObject
    {.importjs: "new ResizeObserver(#)".}
  proc observeSize(o, el: JsObject) {.importjs: "#.observe(#)".}
  proc newMutationObserver(f: proc()): JsObject
    {.importjs: "new MutationObserver(#)".}
  proc observeTree(o, el: JsObject)
    {.importjs: "#.observe(#, {childList: true, subtree: true, characterData: true})".}
  proc rafJs(f: proc()) {.importjs: "requestAnimationFrame(#)".}
  proc fixedAroundPx(cell: JsObject): float {.importjs: """(function(cell){
      // A value cell's row less the value: from the row's left to the cell,
      // and from the cell to the right of its last drawn sibling (the type,
      // the controls) — not the row's blank right part.
      const host = cell.closest('[data-variable-name]') || cell.parentElement;
      const hr = host.getBoundingClientRect();
      const cr = cell.getBoundingClientRect();
      let right = cr.right;
      for (const sib of cell.parentElement.children) {
        if (sib === cell) continue;
        const r = sib.getBoundingClientRect();
        if (r.width > 0) right = Math.max(right, r.right);
      }
      return (cr.left - hr.left) + (right - cr.right);
    })(#)""".}

  proc applyMode(scroller, inner: JsObject; fit: TableFit; widthPx: int) =
    ## The scroller's sideways scroll exists only in SCROLL (§4.1's
    ## overflow-only bar); out of it the view returns to its left edge.
    scroller.setAttr(TableFitAttribute, cstring($fit.mode))
    if fit.overflows:
      scroller.setStyle("overflow-x", "auto")
      inner.setStyle("min-width", cstring($widthPx & "px"))
    else:
      scroller.setStyle("overflow-x", "hidden")
      inner.removeStyle("min-width")
      if scroller.scrollLeftOf > 0.0: scroller.setScrollLeft(0.0)

  # -------------------------------------------------------------------------
  # The Event Log
  # -------------------------------------------------------------------------

  proc attachEventLogFit*(scrollBody, dataTable: JsObject;
                          report: proc(cells: int; charPx: float)) =
    ## Report the columns' viewport, in characters of the table's font, on
    ## every resize; keep the header strip over the body's sideways scroll.
    let measure = proc() =
      let px = max(1.0, dataTable.charPxOf)
      report(int(floor((scrollBody.clientWidthOf - float(ScrubberPx)) / px)),
             px)
    # The header strip sits above the scrolling body: it follows the body's
    # sideways scroll by a translation (the table clips it in SCROLL,
    # `components/table_overflow.styl`), so each title stays over its cells.
    let follow = proc() =
      let head = dataTable.query(".eventLog-column-header")
      if not head.isNil:
        let left = scrollBody.scrollLeftOf
        if left > 0.0:
          head.setStyle("transform", cstring("translateX(" & $(-left) & "px)"))
        else:
          head.removeStyle("transform")
    newResizeObserver(proc() =
      measure()
      follow()).observeSize(scrollBody)
    measure()
    scrollBody.listen("scroll", proc(ev: JsObject) = follow())

  # -------------------------------------------------------------------------
  # The Call Trace
  # -------------------------------------------------------------------------

  proc fitCallTrace*(scroller, lines: JsObject): TableFit =
    ## §5.5.3 / §5.5.5 over the drawn rows: measured, decided, projected.
    let rows = lines.queryAll(".calltrace-call-line")
    if rows.len == 0:
      return
    var composite: seq[CompositeRow]
    var boxes: seq[(JsObject, int)]
    var px = 8.0
    for row in rows:
      let box = row.query(".call-child-box")
      let text = row.query(".call-text")
      if box.isNil or text.isNil:
        continue
      px = max(1.0, text.charPxOf)
      let unit = max(1, int(round(px)))
      let textLeft = int(round(text.leftIn(row)))
      let boxLeft = int(round(box.leftIn(row)))
      let callee = ($box.attr(CalleeAttribute)).runeLen
      let whole = ($box.attr("data-ct-full")).runeLen
      composite.add callFitRow(textLeft, callee, whole, unit)
      boxes.add (box, boxLeft)
    let viewport = max(0, int(scroller.clientWidthOf) - ScrubberPx)
    result = compositeFit(composite, viewport, "call")
    let layoutW = if result.overflows: result.compositeWidth else: viewport
    for (box, boxLeft) in boxes:
      # Each row's call box ends at the column's edge: past it the text is
      # cut (Part B's pass marks it, `components/table_fit.styl` draws `…`).
      box.setStyle("min-width", "0")
      box.setStyle("max-width", cstring($max(0, layoutW - boxLeft) & "px"))
      box.setStyle("overflow", "hidden")
    applyMode(scroller, lines, result, layoutW)

  proc attachCallTraceFit*(scroller, lines: JsObject) =
    ## Fit the call rows after every change of the rows and every resize.
    var scheduled = false
    let run = proc() =
      if scheduled: return
      scheduled = true
      rafJs(proc() =
        scheduled = false
        discard fitCallTrace(scroller, lines))
    newResizeObserver(run).observeSize(scroller)
    newMutationObserver(run).observeTree(lines)
    run()

  # -------------------------------------------------------------------------
  # The State pane
  # -------------------------------------------------------------------------

  proc fitState*(container, rowContainer: JsObject): TableFit =
    ## §5.5.3: each value row's floor is what is not its value — the
    ## indent, the name, the controls — and the value's first cells.
    var composite: seq[CompositeRow]
    for cell in rowContainer.queryAll("[data-ct-cell]"):
      let px = max(1.0, cell.charPxOf)
      let unit = max(1, int(round(px)))
      let fixed = int(round(cell.fixedAroundPx))
      let chars = ($cell.textOf).runeLen
      composite.add variableFitRow(fixed, chars, unit)
    let viewport = max(0, int(container.clientWidthOf) - ScrubberPx)
    result = compositeFit(composite, viewport, "row")
    applyMode(container, rowContainer, result, result.compositeWidth)

  proc attachStateFit*(container, rowContainer: JsObject) =
    var scheduled = false
    let run = proc() =
      if scheduled: return
      scheduled = true
      rafJs(proc() =
        scheduled = false
        discard fitState(container, rowContainer))
    newResizeObserver(run).observeSize(container)
    newMutationObserver(run).observeTree(rowContainer)
    run()
