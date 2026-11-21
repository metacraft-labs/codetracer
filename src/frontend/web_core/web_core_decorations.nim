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

import std/jsffi

import ../viewmodel/viewmodels/table_overflow
import ../viewmodel/views/table_fit_dom
import ../viewmodel/views/table_overflow_dom
import ../viewmodel/views/list_scrubber_dom

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

proc pane(mount: JsObject; name: cstring): JsObject =
  let sel = cstring("[data-pane=\"" & $name & "\"]")
  mount.q(sel)

proc decorateCalltrace(p: JsObject) =
  let scroller = p.q(cstring".local-calltrace-view")
  let lines = p.q(cstring".calltrace-lines")
  if scroller.isNull or lines.isNull: return
  attachCallTraceFit(scroller, lines)
  discard attachTableOverflow(p, CallTraceTablePane, cstring".calltrace-call-line")
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
  discard attachListScrubber(scrollBody, dataTable,
    total = proc(): int = core.call0(cstring"eventLogTotal").toInt,
    current = proc(): int = core.call0(cstring"eventLogCurrent").toInt,
    rowHeight = proc(): float = max(1.0, core.call0(cstring"eventLogRowPx").toFloat),
    paneId = "eventLog")
  p.mark()

proc ctwDecoratePanes(mount: JsObject; core: JsObject) {.exportc.} =
  ## Decorate every pane that exists and is not decorated yet. Called by the
  ## host after each frame until all three are done; cheap once they are.
  for name in [cstring"calltrace", cstring"state", cstring"event-log"]:
    let p = mount.pane(name)
    if p.isNull or p.hasMark: continue
    case $name
    of "calltrace": decorateCalltrace(p)
    of "state": decorateState(p, core)
    else: decorateEventLog(p, core)

{.emit: "globalThis.ctwDecoratePanes = ctwDecoratePanes;".}
