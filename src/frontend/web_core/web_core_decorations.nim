## web_core_decorations.nim — the panes' DOM decoration, run in the host of
## the WebAssembly ViewModel core.
##
## On a `nim js` build the views decorate their own nodes (`when defined(js)`
## blocks: table fit and overflow, the event log's scrubber and search field).
## The wasm core cannot: it holds no node and cannot read layout. This bundle
## is that decoration, built with `nim js` into the host page
## (`ci/test/web-core-browser.sh`), run against the nodes IsoNim's frame
## applier owns, and reaching the core only through its exported entry points.
## It reuses the views' own DOM modules (`table_fit_dom`, `table_overflow_dom`,
## `list_scrubber_dom`), so the fit, the overflow cut and the scrubber are the
## same code the `nim js` panes run.
##
## `ctwDecoratePanes(mount, core)` decorates each pane once, when its element
## exists. `core` is the host's handle (`web_core_host.js`), which answers:
##
##   fullValueOf(path)            a cut variable's whole value (StateVM)
##   eventLogMetrics(cells, px)   the event log's columns viewport
##   eventLogSearch(query)        the event log's search query
##   eventLogTotal(), eventLogCurrent(), eventLogRowPx()   the scrubber's inputs
##   calltraceMeasured(pitch, originX, centerY)  Call Trace's measured rows

import std/[jsffi, options]

import ../viewmodel/viewmodels/table_overflow
import ../viewmodel/views/table_fit_dom
import ../viewmodel/views/table_overflow_dom
import ../viewmodel/views/list_scrubber_dom
import isonim/web/dom_api as isonim_dom
from ../viewmodel/views/isonim_calltrace_view import measureCallRowPitch, measureCallGuideAnchor

proc q(el: JsObject; sel: cstring): JsObject {.importjs: "#.querySelector(#)".}
proc isNull(el: JsObject): bool {.importjs: "(# == null)".}
proc hasMark(el: JsObject): bool {.importjs: "(#.dataset.ctwDecorated === '1')".}
proc mark(el: JsObject) {.importjs: "#.dataset.ctwDecorated = '1'".}
proc call0(core: JsObject; name: cstring): JsObject {.importjs: "#[#]()".}
proc callS(core: JsObject; name, a: cstring): cstring {.importjs: "String(#[#](#))".}
proc callNF(core: JsObject; name: cstring; a: int; b: float) {.importjs: "#[#](#, #)".}
proc callStr(core: JsObject; name, a: cstring) {.importjs: "#[#](#)".}
proc toInt(o: JsObject): int {.importjs: "(Number(#) | 0)".}
proc toFloat(o: JsObject): float {.importjs: "Number(#)".}
proc onInput(el: JsObject; cb: proc()) {.importjs: "#.addEventListener('input', #)".}
proc valueOf(el: JsObject): cstring {.importjs: "String(#.value || '')".}

proc onKeyEnter(el: JsObject; cb: proc(row: int)) {.importjs: """((el, cb) => el.addEventListener('keydown', (ev) => {
  if (ev.key === 'Enter') { const n = parseInt(el.value, 10); if (!isNaN(n)) cb(n); }
}))(#, #)""".}

proc setScrollTop(el: JsObject; v: float) {.importjs: "#.scrollTop = #".}

proc pane(mount: JsObject; name: cstring): JsObject =
  let sel = cstring("[data-pane=\"" & $name & "\"]")
  mount.q(sel)

proc observe(el: JsObject; childList: bool; attr: cstring; cb: proc())
    {.importjs: """((el, kids, attr, cb) => {
      const opts = kids ? { childList: true } : { attributes: true, attributeFilter: [attr] };
      new MutationObserver(() => cb()).observe(el, opts);
      if (kids && typeof ResizeObserver !== 'undefined') new ResizeObserver(() => cb()).observe(el);
    })(#, #, #, #)""".}
proc nextFrame(cb: proc()) {.importjs: "requestAnimationFrame(#)".}
proc callFFF(core: JsObject; name: cstring; a, b, c: float) {.importjs: "#[#](#, #, #)".}
proc revealOf(el: JsObject): cstring {.importjs: "String(#.getAttribute('data-ctw-reveal') || '')".}
proc revealRow(s: cstring): int {.importjs: "(Number(String(#).split(':')[1]) || 0)".}

proc decorateCalltrace(p: JsObject; core: JsObject) =
  let scroller = p.q(cstring".local-calltrace-view")
  let lines = p.q(cstring".calltrace-lines")
  if scroller.isNull or lines.isNull: return
  attachCallTraceFit(scroller, lines)
  discard attachTableOverflow(p, CallTraceTablePane, cstring".calltrace-call-line")
  # The rows' advance and the toggle anchor, measured here from the layout
  # and reported to the core, which draws the guides from them — the
  # measurement `decorateCalltracePanel` makes in process.
  var pitch = 0.0
  var queued = false
  let measure = proc() =
    queued = false
    let lineEl = cast[isonim_dom.Element](lines)
    let svgEl = lines.q(cstring"#svg-content-0")
    pitch = measureCallRowPitch(lineEl)
    let a = measureCallGuideAnchor(lineEl,
      cast[isonim_dom.Element](if svgEl.isNull: lines else: svgEl))
    if a.isSome:
      core.callFFF(cstring"calltraceMeasured", pitch, a.get.originX, a.get.centerY)
    elif pitch > 0.0:
      core.callFFF(cstring"calltraceMeasured", pitch, 0.0, 0.0)
  let schedule = proc() =
    if not queued:
      queued = true
      nextFrame(measure)
  lines.observe(true, cstring"", schedule)
  schedule()
  # A reveal the core asked for: scroll its row into view.
  scroller.observe(false, cstring"data-ctw-reveal", proc() =
    let row = revealRow(scroller.revealOf)
    let h = if pitch > 0.0: pitch else: 25.0
    scroller.setScrollTop(float(row) * h))
  p.mark()

proc decorateState(p: JsObject; core: JsObject) =
  let container = p.q(cstring".value-components-container")
  if container.isNull: return
  discard attachTableOverflow(p, StateDetailPane, cstring".value-expanded",
    proc(path: string): string = $core.callS(cstring"fullValueOf", cstring(path)))
  let rows = container.q(cstring":scope > div:last-child")
  if not rows.isNull:
    attachStateFit(container, rows)
  p.mark()

proc decorateEventLog(p: JsObject; core: JsObject) =
  let scrollBody = p.q(cstring".eventLog-scroll-body")
  let dataTable = p.q(cstring".eventLog-dense-table")
  let search = p.q(cstring".eventLog-search-field")
  if scrollBody.isNull or dataTable.isNull: return
  attachEventLogFit(scrollBody, dataTable, proc(cells: int; charPx: float) =
    core.callNF(cstring"eventLogMetrics", cells, charPx))
  if not search.isNull:
    let field = search
    field.onInput(proc() =
      core.callStr(cstring"eventLogSearch", field.valueOf))
  # The footer's row field: Enter scrolls the body to that row.
  let footer = p.q(cstring".data-tables-footer-input")
  if not footer.isNull:
    footer.onKeyEnter(proc(row: int) =
      scrollBody.setScrollTop(float(max(1, row) - 1) *
        max(1.0, core.call0(cstring"eventLogRowPx").toFloat)))
  discard attachListScrubber(scrollBody, dataTable,
    total = proc(): int = core.call0(cstring"eventLogTotal").toInt,
    current = proc(): int = core.call0(cstring"eventLogCurrent").toInt,
    rowHeight = proc(): float = max(1.0, core.call0(cstring"eventLogRowPx").toFloat),
    paneId = "eventLog")
  p.mark()

proc terminalWindow(core: JsObject): seq[int] {.importjs:
  "String(#.terminalWindow()).split(',').map(Number)".}
proc setStyle(el: JsObject; name, value: cstring) {.importjs:
  "#.style.setProperty(#, #)".}
proc parentOf(el: JsObject): JsObject {.importjs: "#.parentElement".}
proc firstLinePx(el: JsObject): float {.importjs:
  "(function(e){const l=e.querySelector('.terminal-line');return l ? l.getBoundingClientRect().height : 0;})(#)".}

proc decorateTerminalOutput(p: JsObject; core: JsObject) =
  ## The Terminal Output's line view as `decorateTerminalOutput`
  ## (`isonim_terminal_output_view`) lays it out in process: a column whose
  ## `pre` scrolls, its scrollbar a scrubber over every line, the lines
  ## outside the held window as the `pre`'s spacers, and the overflow-only
  ## horizontal bar under the lines. The counts are the core's
  ## (`ctwTerminalWindow`: total, current, first held, held, windowed).
  let pre = p.q(cstring"pre")
  if pre.isNull: return
  let panel = pre.parentOf
  panel.setStyle("display", "flex")
  panel.setStyle("flex-direction", "column")
  pre.setStyle("flex", "1 1 auto")
  pre.setStyle("min-height", "0")
  pre.setStyle("overflow-y", "auto")
  let lineHeight = proc(): float =
    let h = pre.firstLinePx
    if h > 0.0: h else: 18.0
  discard attachListScrubber(pre, panel,
    total = proc(): int = core.terminalWindow()[0],
    current = proc(): int = core.terminalWindow()[1],
    rowHeight = lineHeight,
    paneId = "terminalOutput")
  let spacers = proc() =
    let w = core.terminalWindow()
    if w.len < 5: return
    let h = lineHeight()
    if w[4] != 0:
      pre.setStyle("--ct-terminal-lines-above", cstring($(float(w[2]) * h) & "px"))
      pre.setStyle("--ct-terminal-lines-below",
                   cstring($(float(max(0, w[0] - w[2] - w[3])) * h) & "px"))
    else:
      pre.setStyle("--ct-terminal-lines-above", "0px")
      pre.setStyle("--ct-terminal-lines-below", "0px")
  pre.observe(true, cstring"", spacers)
  spacers()
  discard attachHorizontalScrubber(pre, panel, paneId = "terminalOutput",
                                   verticalTrack = true)
  p.mark()

proc ctwDecoratePanes(mount: JsObject; core: JsObject) {.exportc.} =
  ## Decorate every pane that exists and is not decorated yet. Called by the
  ## host after each frame until all three are done; cheap once they are.
  for name in [cstring"calltrace", cstring"state", cstring"event-log"]:
    let p = mount.pane(name)
    if p.isNull or p.hasMark: continue
    case $name
    of "calltrace": decorateCalltrace(p, core)
    of "state": decorateState(p, core)
    else: decorateEventLog(p, core)
  let terminal = mount.pane(cstring"terminal-output")
  if not terminal.isNull and not terminal.hasMark:
    decorateTerminalOutput(terminal, core)

{.emit: "globalThis.ctwDecoratePanes = ctwDecoratePanes;".}
