## views/isonim_trace_log_view.nim
##
## IsoNim DOM-rendering view for the Trace Log panel.
##
## Renders a live, reactive DOM tree driven by ``TraceLogVM`` signals.
## Replaces the legacy Karax ``method render`` in
## ``frontend/ui/trace_log.nim`` (the IsoNim view is the single source
## of truth for the panel's DOM).
##
## ONE generic view (Shared-DOM-Front-Ends D3), ``renderTraceLogPanel[R, N]``,
## rendered under ``MockRenderer`` in the headless tests and ``WebRenderer`` on
## the desktop and the web page, where the panel host (``ui/panel_host``)
## mounts it and reports the rows it shows to ``TraceLogVM.setViewport``. The
## structure mirrors the legacy ``componentContainerClass("traceLog")``
## layout::
##
##   div.component-container.traceLog
##     div.trace-log-table-header
##       div.trace-col-rr-ticks    text "rr-ticks"
##       div.trace-col-location    text "Location"
##       div.trace-col-function    text "Function"
##       div.trace-col-locals      text "Locals"
##     div.trace-log-table-body
##       div.trace-log-row[.selected]   (one per entry)
##         div.trace-col-rr-ticks
##           span.event-rr-ticks-line   (positioned via inline left:%)
##           text "<rrTicks>"
##         div.trace-col-location  text "<filename>:<line>"
##         div.trace-col-function  text "<functionName>"
##         div.trace-col-locals    text "<localsText>"
##     div.trace-log-empty                shown when entries.len == 0
##       text "No trace results"
##
## Reactive surface:
## - One ``createRenderEffect`` rebuilds the table body whenever
##   ``entries`` or ``selectedIndex`` changes.  Mirrors the
##   ``request_panel`` view's pattern (DSL builds the static shell,
##   imperative renderer ops inside the effect handle the row list).
## - The empty-state placeholder is toggled inside the same effect
##   based on ``vm.isEmpty``.

import isonim/core/[signals, computation]
import isonim/dsl/[ui, components]
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../store/types
import ../viewmodels/trace_log_vm

# The generic procs expand the DSL at their instantiation site.
export signals, computation, components

const TraceLogContainerClass* = "component-container traceLog"
  ## Verbatim string the legacy ``componentContainerClass(
  ## "traceLog")`` template produced.  Exposed for headless tests so
  ## they assert against the exact class string.

const EmptyStateText* = "No trace results"
  ## Placeholder copy rendered when no tracepoint stops have been
  ## captured yet.  Kept as a constant so the view, the headless tests,
  ## and any future fixture builder share a single source of truth.

# ---------------------------------------------------------------------------
# Reactive helpers used inside DSL expressions
# ---------------------------------------------------------------------------

proc rowClass*(selected: bool): string =
  ## Outer ``.trace-log-row`` modifier for the selected row.  Mirrors
  ## the ``"<row> selected"`` concatenation pattern used by other
  ## migrated panels (request_panel / step_list).
  if selected:
    "trace-log-row selected"
  else:
    "trace-log-row"

proc rrTicksLineStyle*(entry: TraceLogEntry): string =
  ## ``style`` value for the ``event-rr-ticks-line`` indicator span.
  ## The legacy ``renderRRTicksLine`` produced an inline-styled
  ## ``<span>`` with a percentage ``left`` offset; we keep the same
  ## semantics here so existing CSS rules colour the indicator.
  "left: " & $rrTicksScale(entry.rrTicks, entry.minRRTicks,
                           entry.maxRRTicks) & "%"

proc onRowClick(vm: TraceLogVM; index: int): proc() =
  ## Closure factory that captures the row's index so each row's
  ## click handler refers to its own value.  Without the per-row
  ## capture every row's closure would observe the loop variable's
  ## final value (same closure-capture concern as the
  ## ``request_panel`` / ``step_list`` views).
  let captured = index
  result = proc() = vm.jumpToEntry(captured)

# ---------------------------------------------------------------------------
# The panel
# ---------------------------------------------------------------------------

proc renderTraceLogRow[R, N](r: R; vm: TraceLogVM; entry: TraceLogEntry;
                             index: int; selected: bool): N =
  ## One trace-log row. A click goes to the stop (``vm.jumpToEntry``,
  ## ``ct/event-jump``); the rr-ticks column wraps the indicator span so CSS
  ## can colour it independently.
  let lineStyle = rrTicksLineStyle(entry)
  ui(r):
    tdiv(class = rowClass(selected),
         onclick = onRowClick(vm, index)):
      tdiv(class = "trace-col-rr-ticks"):
        span(class = "event-rr-ticks-line",
             style = lineStyle):
          discard
        text $entry.rrTicks
      tdiv(class = "trace-col-location"):
        text fileLineText(entry)
      tdiv(class = "trace-col-function"):
        text entry.functionName
      tdiv(class = "trace-col-locals"):
        text entry.localsText

proc renderTraceLogPanel*[R, N](r: R; vm: TraceLogVM): N =
  ## The Trace Log panel. The static shell (header and body) is built once;
  ## one render effect rebuilds the body whenever ``entries`` or
  ## ``selectedIndex`` change and toggles the empty-state placeholder.
  var bodyContainer, emptyContainer: N

  let panel = ui(r):
    tdiv(class = TraceLogContainerClass, tabIndex = "2"):
      tdiv(class = "trace-log-table-header"):
        tdiv(class = "trace-col-rr-ticks"):
          text "rr-ticks"
        tdiv(class = "trace-col-location"):
          text "Location"
        tdiv(class = "trace-col-function"):
          text "Function"
        tdiv(class = "trace-col-locals"):
          text "Locals"
      tdiv(ref = bodyContainer, class = "trace-log-table-body"):
        discard
      tdiv(ref = emptyContainer, class = "trace-log-empty"):
        text EmptyStateText

  createRenderEffect proc() =
    let entries = vm.entries.val
    let selected = vm.selectedIndex.val
    r.clearChildren(bodyContainer)
    for i, entry in entries:
      r.appendChild(bodyContainer,
                    renderTraceLogRow[R, N](r, vm, entry, i, i == selected))
    # The placeholder is toggled by class, so the held reference stays
    # stable across updates.
    r.setAttribute(emptyContainer, "class",
                   if entries.len == 0: "trace-log-empty"
                   else: "trace-log-empty hidden")

  panel
