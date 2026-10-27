## views/table_overflow_dom.nim — PLAT-70 Part B on the desktop (Electron and
## the web build): the table panes' cut cells, their full text on hover and
## under the row, and the copy of a row's whole text
## (Horizontal-Overflow.md §5).
##
## The decisions are the shared ViewModel's (`viewmodels/table_overflow`):
## this module measures a cell's width in characters of its own font, asks
## `fitCell` whether the cell's whole text fits, and marks the cells that do
## not (`data-ct-cut`). The browser draws their `…` (`text-overflow:
## ellipsis`, `components/table_overflow.styl`), exactly as §5.1 says the
## desktop does; the mark is what takes the hover and the `…` click, so the
## three front-ends agree about which cells are cut (HO-8).
##
## A pane opts in by marking its cells with `data-ct-cell="<pane>|<key>|
## <column>"` and their whole text with `data-ct-full`, and calling
## `attachTableOverflow` on its root once: the Variables pane's value
## (`isonim_state_view`) and the Event Log's cells (`ui/event_log`). The
## desktop's Call Trace is not one: its list scrolls sideways
## (`list_scrubber.styl`), so its rows are never cut.
##
## The view only draws and hit-tests: the hover clock, the open detail, the
## wrapping, the cap and the hint are the shared model's.

import std/[math, strutils]

import ../viewmodels/table_overflow

export table_overflow

when defined(js):
  import std/jsffi

  const
    TableCellAttribute* = "data-ct-cell"
      ## `<pane>|<key>|<column>` on a table cell.
    TableFullAttribute* = "data-ct-full"
      ## The cell's whole text.
    TableFullOfAttribute = "data-ct-full-of"
      ## The drawn text a lazily asked `data-ct-full` belongs to.
    TableTextAttribute* = "data-ct-text"
      ## The text the cell DRAWS, when it is not its whole text (a value
      ## drawn at its row's budget): what is measured against the cell.
    TableCutAttribute* = "data-ct-cut"
      ## On a cell drawn cut: its column (HO-8).
    MidCutTextAttribute = "data-ct-mid-text"
      ## PLAT-71: the text this pass drew in a cell cut in its middle.
    MidCutOfAttribute = "data-ct-mid-of"
      ## PLAT-71: the text the view drew there, which the cut stands for.
    TableDetailClass* = "ct-table-detail"
      ## A row's full text, open under it.
    TableTooltipClass* = "ct-table-tooltip"
      ## The tooltip of a truncated cell.
    StateDetailPane* = VariablesTablePane
    EventLogDetailPane* = EventLogTablePane
      ## The panes' names in a `DetailToggle` — the terminal's and GPUI's.

  type
    TablePaneDom* = ref object
      root*: JsObject
      pane*: string
      rowSelector*: cstring
        ## The row a detail opens under (`tr`, `.value-expanded`, …).
      pressedKey*: string
        ## The row last pressed in the pane: `list.show-detail`'s row when
        ## the pane marks no selected row of its own.
      swallowClick: bool
        ## The press was a `…`'s: the click it ends is not the row's.
      observer: JsObject
      scheduled: bool
      fullValueOf*: proc(key: string): string
        ## The pane's whole value of row `key`, for a cell that carries no
        ## `data-ct-full`: asked once a cell is found CUT, then kept on the
        ## cell beside the drawn text it was asked for (`data-ct-full-of`).

  var
    tablePanes: seq[TablePaneDom]
    hover: HoverClock
    hoverTimer = -1
    tooltipEl: JsObject
    openDetail*: DetailToggle
      ## The one row whose full text is open, across the table panes.
    copyChordOf*: proc(): string
      ## The resolved `list.copy` chord (KL-8), installed by the key router.
    lastPressedTablePane*: string
      ## The table pane last pressed — the palette's entries act on it while
      ## the palette holds the focus.

  proc nowMs(): float {.importjs: "Date.now()".}
  proc jsCharPx(el: JsObject): float {.importjs: """(function(el){
      const s = getComputedStyle(el);
      const c = (window.__ctCharCanvas = window.__ctCharCanvas ||
                 document.createElement('canvas')).getContext('2d');
      c.font = s.fontStyle + ' ' + s.fontWeight + ' ' + s.fontSize + ' ' +
               s.fontFamily;
      const w = c.measureText('0000000000').width / 10;
      return w > 0 ? w : 8;
    })(#)""".}
  proc attr(el: JsObject; name: cstring): cstring
    {.importjs: "(#.getAttribute(#) || '')".}
  proc setAttr(el: JsObject; name, value: cstring)
    {.importjs: "#.setAttribute(#, #)".}
  proc removeAttr(el: JsObject; name: cstring)
    {.importjs: "#.removeAttribute(#)".}
  proc queryAll(el: JsObject; sel: cstring): seq[JsObject]
    {.importjs: "Array.from(#.querySelectorAll(#))".}
  proc closest(el: JsObject; sel: cstring): JsObject =
    {.emit: [result, " = (", el, " && ", el, ".closest) ? ", el,
             ".closest(", sel, ") : null;"].}
  proc createEl(tag, cls: cstring): JsObject
    {.importjs: "(function(t,c){const d=document.createElement(t);d.className=c;return d;})(#,#)".}
  proc setText(el: JsObject; text: cstring) {.importjs: "#.textContent = #".}
  proc appendTo(parent, child: JsObject) {.importjs: "#.appendChild(#)".}
  proc insertAfterJs(node, newNode: JsObject) =
    {.emit: [node, ".parentNode.insertBefore(", newNode, ", ", node,
             ".nextSibling);"].}
  proc removeEl(el: JsObject) {.importjs: "#.remove()".}
  proc clientWidth(el: JsObject): float {.importjs: "#.clientWidth".}
  proc clientHeight(el: JsObject): float {.importjs: "#.clientHeight".}
  proc offsetHeight(el: JsObject): float {.importjs: "#.offsetHeight".}
  proc offsetLeftIn(el, row: JsObject): float {.importjs: """(function(el,row){
      return el.getBoundingClientRect().left - row.getBoundingClientRect().left;
    })(#,#)""".}
  proc isConnectedJs(el: JsObject): bool {.importjs: "(!!#.isConnected)".}
  proc rectOf(el: JsObject): JsObject {.importjs: "#.getBoundingClientRect()".}
  proc innerWidth(): float {.importjs: "(window.innerWidth)@".}
  proc innerHeight(): float {.importjs: "(window.innerHeight)@".}
  proc setStyle(el: JsObject; key, value: cstring)
    {.importjs: "#.style.setProperty(#, #)".}
  proc setTimeoutJs(f: proc(); ms: int): int {.importjs: "setTimeout(#, #)".}
  proc clearTimeoutJs(id: int) {.importjs: "clearTimeout(#)".}
  proc rafJs(f: proc()) {.importjs: "requestAnimationFrame(#)".}
  proc listen(el: JsObject; name: cstring; f: proc(ev: JsObject);
              capture: bool) {.importjs: "#.addEventListener(#, #, #)".}
  proc newObserver(f: proc()): JsObject
    {.importjs: "new MutationObserver(#)".}
  proc observe(o, el: JsObject)
    {.importjs: "#.observe(#, {childList: true, subtree: true, characterData: true})".}
  proc takeRecords(o: JsObject) {.importjs: "#.takeRecords()".}
  proc newResizeObserver(f: proc()): JsObject
    {.importjs: "new ResizeObserver(#)".}
  proc observeSize(o, el: JsObject) {.importjs: "#.observe(#)".}
  proc bodyEl(): JsObject {.importjs: "(document.body)@".}
  proc recordCopy(text: cstring)
    {.importjs: "(window.__ctCopied = window.__ctCopied || []).push(#)".}
    ## What `list.copy` put on the clipboard, for a Playwright reader.
  proc clipboardWrite(text: cstring)
    {.importjs: "(navigator.clipboard ? navigator.clipboard.writeText(#).catch(function(){}) : null)".}

  proc parts(cell: JsObject): tuple[pane, key, column: string] =
    let s = ($cell.attr(TableCellAttribute)).split('|')
    if s.len >= 3: (s[0], s[1], s[2]) else: ("", "", "")

  proc drawnOf(cell: JsObject): string

  proc fullOf(cell: JsObject): string =
    ## The cell's whole text: `data-ct-full` when it has one (or was given
    ## one once it was found cut), else what it draws.
    let full = cell.attr(TableFullAttribute)
    if full.len > 0: $full else: cell.drawnOf

  proc textOf(el: JsObject): cstring {.importjs: "(#.textContent || '')".}

  proc drawnOf(cell: JsObject): string =
    ## What the cell draws: `data-ct-text` when it carries one (a cell whose
    ## markup is more than its text), else its own text.
    let drawn = cell.attr(TableTextAttribute)
    if drawn.len > 0: $drawn else: $cell.textOf

  proc innerWidthOf(el: JsObject): float {.importjs: """(function(el){
      const s = getComputedStyle(el);
      return el.getBoundingClientRect().width -
             parseFloat(s.paddingLeft || '0') - parseFloat(s.paddingRight || '0') -
             parseFloat(s.borderLeftWidth || '0') - parseFloat(s.borderRightWidth || '0');
    })(#)""".}

  proc cellsOf(cell: JsObject): int =
    ## How many characters of its own font the cell holds: its content box's
    ## FRACTIONAL width (an integer `clientWidth` rounds a text that exactly
    ## fits down by a pixel and would call it cut), over one character's.
    max(0, int(floor((cell.innerWidthOf + 0.5) / cell.jsCharPx)))

  proc chord(): string =
    if copyChordOf.isNil: "" else: copyChordOf()

  proc setDrawnText(el: JsObject; text: cstring) {.importjs: """
    (function(el, t){
      const n = el.firstChild;
      if (n && n.nodeType === 3 && !n.nextSibling) n.nodeValue = t;
      else el.textContent = t;
    })(#, #)""".}
    ## The cell's text node's text — the node the view's renderer holds, so
    ## its next update still reaches it.

  proc middleCutPass(cell: JsObject; kind: CutKind): bool =
    ## PLAT-71 (Terminal-Adaptation §9.2): a column whose cut is not at its
    ## end — a path's middle, a number never cut silently — is drawn with the
    ## shared presenter's text, since `text-overflow` cuts only the end. The
    ## text the view drew is kept (`MidCutOfAttribute`) while the cell shows
    ## the cut; a new text from the view replaces both.
    let shown = $cell.textOf
    var whole = shown
    if $cell.attr(MidCutTextAttribute) == shown and shown.len > 0:
      whole = $cell.attr(MidCutOfAttribute)
    let fitted = fitCellAs(whole, cell.cellsOf, kind)
    if fitted.truncated:
      if shown != fitted.text:
        cell.setDrawnText(cstring(fitted.text))
      cell.setAttr(MidCutTextAttribute, cstring(fitted.text))
      cell.setAttr(MidCutOfAttribute, cstring(whole))
      cell.setAttr(TableFullAttribute, cstring(whole))
      cell.setAttr(TableCutAttribute, cstring(cell.parts.column))
    else:
      if shown != whole:
        cell.setDrawnText(cstring(whole))
      cell.removeAttr(MidCutTextAttribute)
      cell.removeAttr(MidCutOfAttribute)
      if cell.attr(TableCutAttribute).len > 0:
        cell.removeAttr(TableCutAttribute)
    true

  proc fitPass(t: TablePaneDom) =
    ## §5.1: every cell's `truncated`, from the shared fit, marked.
    for cell in t.root.queryAll(cstring("[" & TableCellAttribute & "]")):
      let parts = cell.parts
      let kind = cutKindOf(parts.pane, parts.column)
      if kind != ckEnd and cell.attr(TableTextAttribute).len == 0 and
         cell.middleCutPass(kind):
        continue
      let drawn = cell.drawnOf
      let fitted = fitCell(drawn, cell.cellsOf)
      if fitted.truncated:
        if not t.fullValueOf.isNil and
           $cell.attr(TableFullOfAttribute) != drawn:
          # A cut cell's whole value, from the pane (never sent with every
          # row): asked again only when what the cell draws changed.
          let whole = t.fullValueOf(cell.parts.key)
          cell.setAttr(TableFullAttribute,
                       cstring(if whole.len > 0: whole else: drawn))
          cell.setAttr(TableFullOfAttribute, cstring(drawn))
        cell.setAttr(TableCutAttribute, cstring(cell.parts.column))
      elif cell.attr(TableCutAttribute).len > 0:
        cell.removeAttr(TableCutAttribute)

  proc cellOfRow(t: TablePaneDom; key, column: string): JsObject =
    for cell in t.root.queryAll(cstring("[" & TableCellAttribute & "]")):
      let p = cell.parts
      if p.key == key and (column.len == 0 or p.column == column):
        return cell
    nil

  proc renderDetail(t: TablePaneDom) =
    ## §5.3: the open row's full text under it, wrapped in its cell's width,
    ## capped at `DetailMaxLines` with the copy hint.
    for old in t.root.queryAll(cstring("." & TableDetailClass)):
      old.removeEl()
    if openDetail.isOpenIn(t.pane):
      let cell = t.cellOfRow(openDetail.key, openDetail.column)
      if not cell.isNil:
        var row = cell.closest(t.rowSelector)
        if row.isNil: row = cell
        let rowH = max(1.0, row.offsetHeight)
        let bodyRows = int(t.root.clientHeight / rowH)
        let view = detailView(cell.fullOf, max(1, cell.cellsOf), bodyRows,
                              chord())
        let isTr = ($row.tagName.to(cstring)).toUpperAscii == "TR"
        let box = createEl(cstring(if isTr: "tr" else: "div"),
                           cstring(TableDetailClass))
        box.setAttr(cstring"data-ct-detail", cstring(openDetail.key))
        var host = box
        if isTr:
          host = createEl(cstring"td", cstring"")
          host.setAttr(cstring"colspan", cstring"99")
          box.appendTo(host)
        host.setStyle(cstring"padding-left",
                      cstring($int(cell.offsetLeftIn(row)) & "px"))
        for line in view.lines:
          let l = createEl(cstring"div", cstring"ct-table-detail-line")
          l.setText(cstring(line))
          host.appendTo(l)
        row.insertAfterJs(box)
    if not t.observer.isNil:
      t.observer.takeRecords()

  proc refresh(t: TablePaneDom) =
    t.scheduled = false
    t.fitPass()
    t.renderDetail()

  proc schedule(t: TablePaneDom) =
    if t.scheduled: return
    t.scheduled = true
    rafJs(proc() = t.refresh())

  proc refreshTablePanes*() =
    ## Re-fit and re-lay every attached pane (a resize, a new detail).
    for t in tablePanes:
      t.schedule()

  proc hideTooltip() =
    if not tooltipEl.isNil:
      tooltipEl.removeEl()
      tooltipEl = nil

  proc showTooltip(cell: JsObject) =
    hideTooltip()
    let r = cell.rectOf
    let charPx = cell.jsCharPx
    let rowH = max(1.0, r.height.to(float))
    let view = tooltipView(hover.full, int(innerWidth() / charPx),
                           int(innerHeight() / rowH), chord())
    let box = createEl(cstring"div", cstring(TableTooltipClass))
    box.setAttr(cstring"data-ct-cell-tooltip",
                cstring(hover.key & "|" & hover.column))
    for line in view.lines:
      let l = createEl(cstring"div", cstring"ct-table-tooltip-line")
      l.setText(cstring(line))
      box.appendTo(l)
    let below = r.bottom.to(float)
    let h = float(view.lines.len) * rowH
    let top = if below + h <= innerHeight(): below else: max(0.0, r.top.to(float) - h)
    box.setStyle(cstring"left", cstring($int(max(0.0, r.left.to(float))) & "px"))
    box.setStyle(cstring"top", cstring($int(top) & "px"))
    bodyEl().appendTo(box)
    tooltipEl = box

  proc armHover(cell: JsObject) =
    if hoverTimer >= 0:
      clearTimeoutJs(hoverTimer)
      hoverTimer = -1
    let due = hover.dueMs
    if due < 0: return
    let fire = proc() =
      hoverTimer = -1
      if hover.tick(int64(nowMs())):
        showTooltip(cell)
    hoverTimer = setTimeoutJs(fire, max(0, int(due - int64(nowMs()))))

  proc onMove(t: TablePaneDom; ev: JsObject) =
    let cell = ev.target.closest(cstring("[" & TableCellAttribute & "]"))
    let cut = not cell.isNil and cell.attr(TableCutAttribute).len > 0
    let changed =
      if cut:
        let p = cell.parts
        hover.pointerOver(p.pane, p.key, p.column, cell.fullOf, true,
                          int64(nowMs()))
      else:
        hover.pointerOver("", "", "", "", false, int64(nowMs()))
    if changed: hideTooltip()
    if cut: armHover(cell)

  proc dismissHover*() =
    ## A key or a press (§5.3).
    discard hover.dismiss()
    hideTooltip()

  proc toggleTableDetail*(pane, key, column: string): bool =
    ## §5.3: the row's full text under it; again closes it; one at a time.
    result = openDetail.toggleDetail(pane, key, column)
    refreshTablePanes()

  proc onPress(t: TablePaneDom; ev: JsObject) =
    ## A press in the pane: the row it is on becomes the pane's row; a press
    ## on a cut cell's `…` (its last character) opens its row's detail and
    ## goes no further — the row's own click (a jump) does not run.
    dismissHover()
    let cell = ev.target.closest(cstring("[" & TableCellAttribute & "]"))
    lastPressedTablePane = t.pane
    if cell.isNil: return
    t.pressedKey = cell.parts.key
    if cell.attr(TableCutAttribute).len == 0: return
    let r = cell.rectOf
    let x = ev.clientX.to(float)
    if x >= r.right.to(float) - 1.5 * cell.jsCharPx and
       x <= r.right.to(float):
      let p = cell.parts
      discard toggleTableDetail(p.pane, p.key, p.column)
      t.swallowClick = true
      discard ev.preventDefault()
      discard ev.stopPropagation()

  proc onClick(t: TablePaneDom; ev: JsObject) =
    ## The click that ends a `…` press goes no further (a row's click jumps
    ## the debugger; the `…` only opens the detail).
    if t.swallowClick:
      t.swallowClick = false
      discard ev.preventDefault()
      discard ev.stopPropagation()

  proc attachTableOverflow*(root: JsObject; pane: string;
                            rowSelector: cstring;
                            fullValueOf: proc(key: string): string = nil):
                            TablePaneDom =
    ## Opt `root` (a pane's element) in: its marked cells are fitted after
    ## every change and resize, hovered, clicked on their `…`.
    for t in tablePanes:
      if t.root == root: return t
    # The same pane mounted again: its old root, which has left the
    # document, is forgotten (`tablePaneOf` answers the new one).
    var kept: seq[TablePaneDom] = @[]
    for t in tablePanes:
      if t.pane != pane or t.root.isConnectedJs: kept.add t
    tablePanes = kept
    let t = TablePaneDom(root: root, pane: pane, rowSelector: rowSelector,
                         fullValueOf: fullValueOf)
    tablePanes.add t
    root.listen(cstring"mousemove", proc(ev: JsObject) = t.onMove(ev), false)
    let onLeave = proc(ev: JsObject) =
      if hover.pointerOver("", "", "", "", false, int64(nowMs())): hideTooltip()
    root.listen(cstring"mouseleave", onLeave, false)
    root.listen(cstring"mousedown", proc(ev: JsObject) = t.onPress(ev), true)
    root.listen(cstring"click", proc(ev: JsObject) = t.onClick(ev), true)
    root.listen(cstring"dblclick", proc(ev: JsObject) = t.onClick(ev), true)
    t.observer = newObserver(proc() = t.schedule())
    t.observer.observe(root)
    newResizeObserver(proc() = t.schedule()).observeSize(root)
    t.schedule()
    t

  proc tablePaneOf*(pane: string): TablePaneDom =
    for t in tablePanes:
      if t.pane == pane and t.root.isConnectedJs: return t
    nil

  proc focusedRowCell*(pane: string; selectedSelector: cstring): JsObject =
    ## `list.show-detail`'s and `list.copy`'s cell in `pane`: the first cell
    ## of its selected row, else of the row last pressed.
    let t = tablePaneOf(pane)
    if t.isNil: return nil
    if selectedSelector.len > 0:
      for row in t.root.queryAll(selectedSelector):
        for cell in row.queryAll(cstring("[" & TableCellAttribute & "]")):
          return cell
    if t.pressedKey.len > 0:
      return t.cellOfRow(t.pressedKey, "")
    nil

  proc showDetailOf*(pane: string; selectedSelector: cstring): bool =
    ## `list.show-detail` on the desktop: the focused row's detail.
    let cell = focusedRowCell(pane, selectedSelector)
    if cell.isNil: return false
    let p = cell.parts
    discard toggleTableDetail(p.pane, p.key, "")
    true

  proc copyRowOf*(pane: string; selectedSelector: cstring): bool =
    ## `list.copy` on the desktop: the focused row's WHOLE text.
    let cell = focusedRowCell(pane, selectedSelector)
    if cell.isNil: return false
    clipboardWrite(cstring(cell.fullOf))
    recordCopy(cstring(cell.fullOf))
    true
