## views/pane_measure_dom.nim — the DOM host reports what each pane shows.
##
## HSF-V2 (Viewport-Driven-Loading V3): a pane's view measures nothing for its
## ViewModel; whoever MOUNTS the pane in a browser does. One ResizeObserver and
## one scroll listener per mounted pane: the pane's body height over the rows'
## measured advance is its rows, the scroll offset over the advance is the
## first row shown, and the width over a depth level's indent is the levels
## that fit (`pane_viewport.pixelPaneViewport`, the conversion every front-end
## shares). The ViewModel's `setViewport` then asks the replay for that
## window.
##
## Two hosts mount DOM panes and both use this module, so a pane pages the
## same way wherever it is shown:
##
##   * the desktop and web IDE's `ui/panel_host` (GoldenLayout containers);
##   * the VS Code webviews' `entries/vscode_panel`, whose ViewModels are
##     mirrors: a mirror's `setViewport` is relayed to the extension host's
##     primary (`sync/action_relay` `viewport/set`), which asks the replay.
##     Without a measurement there the panes never asked for a window, so the
##     Call Trace kept its first rows and the Event Log stayed empty
##     (codetracer-vscode-extension#37, #40).
##
## It imports no desktop module (`types.Data`, `ui_js`, the renderer), so the
## VS Code panel bundle can use it.

when not defined(js):
  {.error: "views/pane_measure_dom measures panes in a browser DOM (JS).".}

import isonim/core/[signals, computation]
from isonim/web/dom_api import nil

import ../session_vm
import ../pane_viewport
import ../viewport
from ../viewmodels/calltrace_vm import setViewport, setRowHeightPx
from ../viewmodels/state_vm import setViewport
from ../viewmodels/request_panel_vm import setViewport
from ../viewmodels/event_log_vm import setRowHeightPx, setViewport
from ../viewmodels/terminal_output_vm import nil
from ../viewmodels/trace_log_vm import setViewport
from ./isonim_calltrace_view import CallDepthIndentPx

const
  RequestRowFallbackPx = 24.0
    ## The Request panel's row pitch until a row is rendered to measure.
  StateRowFallbackPx = 22.0
    ## The State pane's row pitch until a row is rendered to measure.
  TraceRowFallbackPx = 22.0
    ## The Trace Log's row pitch until a row is rendered to measure.
  TerminalLineFallbackPx = 18.0
    ## A terminal line's height until one is drawn to measure.
  EventRowFallbackPx = 24.0
    ## An Event Log row's pitch until a row is rendered to measure.

type
  MeasuredPane* = enum
    ## The panes whose host measures them.
    mpCalltrace, mpState, mpTraceLog, mpTerminalOutput, mpEventLog,
    mpRequestPanel

  StopMeasuring* = proc()
    ## Disconnects a pane's resize observer and scroll listener.

  PaneMeasure = object
    ## How a pane is measured: the element that scrolls, a row's selector
    ## (the rows' measured advance), the pixels one depth level indents, and
    ## where the result goes. `fallbackRowPx` is the row pitch to use before
    ## a row exists.
    scroller: cstring
    row: cstring
    pxPerLevel: float
    countPartialRow: bool
      ## A row any of which shows counts (the State pane: it sizes how many
      ## values a stop and a "Load More" fetch).
    reportHidden: bool
      ## A hidden pane reports no rows, so the ViewModel falls back to its
      ## defaults, rather than keeping the last size it was told.
    fallbackRowPx: proc(): float
    report: proc(v: Viewport; rowPx: float)
    changed: proc()
      ## Read inside an effect: the pane's rows changed, measure again.

proc qsIn(el: dom_api.Element; sel: cstring): dom_api.Element
  {.importjs: "(#.querySelector(#) || null)".}
proc paneClientHeight(el: dom_api.Element): float
  {.importjs: "(#.clientHeight || 0)".}
proc paneClientWidth(el: dom_api.Element): float
  {.importjs: "(#.clientWidth || 0)".}
proc paneScrollTop(el: dom_api.Element): float
  {.importjs: "(#.scrollTop || 0)".}
proc rowPitchIn(el: dom_api.Element; sel: cstring): float {.importjs:
  "((el, sel) => { var r = el.querySelectorAll(sel); if (r.length === 0) return 0; if (r.length === 1) return r[0].getBoundingClientRect().height; return (r[r.length - 1].getBoundingClientRect().top - r[0].getBoundingClientRect().top) / (r.length - 1); })(#, #)".}
  ## The rows' ADVANCE, top to top, averaged over the rendered rows: what
  ## positions them (a sub-pixel advance is recovered exactly), not a row box.
proc watchPane(el: dom_api.Element; onChange: proc()): StopMeasuring {.importjs:
  "((el, cb) => { var ro = (typeof ResizeObserver !== 'undefined') ? new ResizeObserver(() => cb()) : null; if (ro) ro.observe(el); el.addEventListener('scroll', cb, {passive: true}); return () => { if (ro) ro.disconnect(); el.removeEventListener('scroll', cb); }; })(#, #)".}
  ## Call `onChange` on every resize and scroll of `el`; the result stops it.
proc paneSetTimeout(fn: proc(); ms: int) {.importjs: "setTimeout(#, #)".}

proc measureOf(pane: MeasuredPane; session: SessionViewModel): PaneMeasure =
  ## How `pane` is measured, reporting to `session`'s ViewModel; a pane whose
  ## ViewModel the session lacks reports nowhere (`report` nil).
  case pane
  of mpCalltrace:
    let vm = session.calltraceVM
    if vm.isNil: return PaneMeasure()
    PaneMeasure(
      scroller: cstring".local-calltrace-view",
      row: cstring".calltrace-call-line",
      pxPerLevel: CallDepthIndentPx,
      fallbackRowPx: proc(): float = vm.rowHeightPx.val,
      report: proc(v: Viewport; rowPx: float) =
        vm.setRowHeightPx(rowPx)
        vm.setViewport(v),
      changed: proc() = discard session.store.calltrace.lines.val)
  of mpState:
    let vm = session.stateVM
    if vm.isNil: return PaneMeasure()
    PaneMeasure(
      scroller: cstring".value-components-container",
      row: cstring".value-expanded",
      pxPerLevel: 0.0,
      countPartialRow: true,
      reportHidden: true,
      fallbackRowPx: proc(): float = StateRowFallbackPx,
      report: proc(v: Viewport; rowPx: float) = vm.setViewport(v),
      changed: proc() = discard session.store.locals.locals.val)
  of mpTraceLog:
    # The rows it shows (Viewport-Driven-Loading Q4): their locals are read
    # by window. A hidden pane reports none and reads nothing.
    let vm = session.traceLogVM
    if vm.isNil: return PaneMeasure()
    PaneMeasure(
      scroller: cstring".trace-log-table-body",
      row: cstring".trace-log-row",
      pxPerLevel: 0.0,
      countPartialRow: true,
      reportHidden: true,
      fallbackRowPx: proc(): float = TraceRowFallbackPx,
      report: proc(v: Viewport; rowPx: float) = vm.setViewport(v),
      changed: proc() = discard vm.entries.val)
  of mpTerminalOutput:
    # The line view asks for the lines it shows (Viewport-Driven-Loading
    # Q3): the `pre` holding the lines is the scroller. A hidden pane (no
    # height) reports none and asks nothing until it is shown.
    let vm = session.terminalOutputVM
    if vm.isNil: return PaneMeasure()
    PaneMeasure(
      scroller: cstring"pre",
      row: cstring".terminal-line",
      pxPerLevel: 0.0,
      countPartialRow: true,
      reportHidden: true,
      fallbackRowPx: proc(): float = TerminalLineFallbackPx,
      report: proc(v: Viewport; rowPx: float) =
        terminal_output_vm.setViewport(vm, v),
      changed: proc() = discard vm.lines.val)
  of mpEventLog:
    # The rows the list shows (Viewport-Driven-Loading V2): the engine is
    # asked for that window (`ct/event-load`), and the scroll area is as tall
    # as the whole list at the rows' measured pitch. A hidden pane reports
    # none and asks nothing until it is shown.
    let vm = session.eventLogVM
    if vm.isNil: return PaneMeasure()
    PaneMeasure(
      scroller: cstring".eventLog-scroll-body",
      row: cstring".eventLog-row",
      pxPerLevel: 0.0,
      countPartialRow: true,
      reportHidden: true,
      fallbackRowPx: proc(): float = EventRowFallbackPx,
      report: proc(v: Viewport; rowPx: float) =
        vm.setRowHeightPx(rowPx)
        vm.setViewport(v),
      changed: proc() = discard vm.eventRows.val)
  of mpRequestPanel:
    # The rows the table body shows (Viewport-Driven-Loading V2): a partly
    # visible row counts; the window held is padded by the view.
    let vm = session.requestPanelVM
    if vm.isNil: return PaneMeasure()
    PaneMeasure(
      scroller: cstring".request-table-body",
      row: cstring".request-row",
      pxPerLevel: 0.0,
      countPartialRow: true,
      fallbackRowPx: proc(): float = RequestRowFallbackPx,
      report: proc(v: Viewport; rowPx: float) = vm.setViewport(v),
      changed: proc() = discard vm.filteredRequests.val)

proc startMeasuringPane*(host: dom_api.Element; pane: MeasuredPane;
                         session: SessionViewModel): StopMeasuring =
  ## Measure `pane`, rendered inside `host`, for `session`'s ViewModel:
  ## attach its one observer and one scroll listener, and report now (one
  ## tick later, so the view's elements are laid out) and whenever the pane
  ## is resized or scrolled, or its rows change. Call it inside the reactive
  ## root the pane was rendered in: the row-change effect is disposed with
  ## it. The result disconnects the observer and the listener; nil when the
  ## pane has nothing to measure (no ViewModel, or its scroller is absent).
  let spec = measureOf(pane, session)
  if spec.report.isNil:
    return nil
  let scroller = qsIn(host, spec.scroller)
  if dom_api.isNodeNil(dom_api.Node(scroller)):
    return nil
  let measure = proc() =
    var rowPx = rowPitchIn(scroller, spec.row)
    if rowPx <= 0.0:
      rowPx = spec.fallbackRowPx()
    let v = pixelPaneViewport(scroller.paneClientHeight,
                              scroller.paneClientWidth, rowPx,
                              scroller.paneScrollTop, spec.pxPerLevel,
                              countPartialRow = spec.countPartialRow)
    if v.measured or spec.reportHidden:
      spec.report(v, rowPx)
  result = watchPane(scroller, measure)
  createEffect proc() =
    spec.changed()
    paneSetTimeout(measure, 0)
