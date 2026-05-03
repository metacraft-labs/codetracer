## views/isonim_trace_log_view.nim
##
## IsoNim DOM-rendering view for the Trace Log panel.
##
## Renders a live, reactive DOM tree driven by ``TraceLogVM`` signals.
## Replaces the legacy Karax ``method render`` in
## ``frontend/ui/trace_log.nim`` (the IsoNim view is the single source
## of truth for the panel's DOM).
##
## Both renderer overloads (Mock and Web) produce the same outer
## structure mirroring the legacy ``componentContainerClass(
## "traceLog")`` layout::
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
import isonim/dsl/ui
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../store/types
import ../viewmodels/trace_log_vm

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
# Mock renderer — headless test DOM
# ---------------------------------------------------------------------------

proc renderRowMock(r: MockRenderer; vm: TraceLogVM; entry: TraceLogEntry;
                   index: int; selected: bool): MockNode =
  ## Render a single trace-log row.  The click handler maps onto
  ## ``vm.jumpToEntry`` (which dispatches ``ct/event-jump``); the
  ## rr-ticks column wraps the indicator span so CSS can colour it
  ## independently.
  let onClick = onRowClick(vm, index)
  let lineStyle = rrTicksLineStyle(entry)
  let row = ui(r):
    tdiv(class = rowClass(selected),
         onclick = onClick):
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
  row

proc renderTraceLogPanel*(r: MockRenderer; vm: TraceLogVM): MockNode =
  ## Render the Trace Log panel for the Mock renderer.
  ##
  ## The static shell (table-header + table-body containers) is built
  ## once via the DSL.  A single outer ``createRenderEffect`` rebuilds
  ## the body whenever ``entries`` or ``selectedIndex`` change and
  ## also toggles the empty-state placeholder.
  var bodyContainer: MockNode
  var emptyContainer: MockNode

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

  # Body + empty-state — rebuilt whenever the entry list or selection
  # changes.  ``selectedIndex`` is read inside the effect so the
  # subscription edge is established for it too.
  createRenderEffect proc() =
    let entries = vm.entries.val
    let selected = vm.selectedIndex.val
    r.clearChildren(bodyContainer)
    for i, entry in entries:
      let row = renderRowMock(r, vm, entry, i, i == selected)
      r.appendChild(bodyContainer, row)

    # Toggle the empty-state placeholder via a class instead of
    # remove/insert so the held ``emptyContainer`` reference stays
    # stable across reactive updates (matches the request_panel
    # count-badge pattern).
    if entries.len == 0:
      r.setAttribute(emptyContainer, "class", "trace-log-empty")
    else:
      r.setAttribute(emptyContainer, "class", "trace-log-empty hidden")

  panel

# ---------------------------------------------------------------------------
# Web renderer — production DOM
# ---------------------------------------------------------------------------

when defined(js):

  proc createWebElement(tag: string; cssClass: string = "";
                        elemId: string = ""): isonim_dom.Element =
    ## Helper: create a DOM element with optional class + id
    ## attributes.
    let n = isonim_dom.createElement(isonim_dom.document, cstring(tag))
    if cssClass.len > 0:
      isonim_dom.setAttribute(n, cstring"class", cstring(cssClass))
    if elemId.len > 0:
      isonim_dom.setAttribute(n, cstring"id", cstring(elemId))
    n

  proc createWebTextElement(tag: string; textValue: string;
                            cssClass: string = "";
                            elemId: string = ""): isonim_dom.Element =
    ## Helper: create an element with a text-node child in one shot.
    let n = createWebElement(tag, cssClass, elemId)
    let t = isonim_dom.createTextNode(isonim_dom.document, cstring(textValue))
    isonim_dom.appendChild(isonim_dom.Node(n), t)
    n

  proc clearWebChildren(node: isonim_dom.Element) =
    let asNode = isonim_dom.Node(node)
    while not isonim_dom.isNodeNil(asNode.firstChild):
      discard isonim_dom.removeChild(asNode, asNode.firstChild)

  proc renderRowWeb(vm: TraceLogVM; entry: TraceLogEntry;
                    index: int; selected: bool): isonim_dom.Element =
    ## Build a trace-log row in the real DOM.  Same shape as the Mock
    ## variant; click handler is wired imperatively via
    ## ``addEventListener``.
    let row = createWebElement("div", rowClass(selected))

    let rrDiv = createWebElement("div", "trace-col-rr-ticks")
    let lineSpan = createWebElement("span", "event-rr-ticks-line")
    isonim_dom.setAttribute(lineSpan, cstring"style",
                            cstring(rrTicksLineStyle(entry)))
    isonim_dom.appendChild(isonim_dom.Node(rrDiv), isonim_dom.Node(lineSpan))
    let rrText = isonim_dom.createTextNode(isonim_dom.document,
                                            cstring($entry.rrTicks))
    isonim_dom.appendChild(isonim_dom.Node(rrDiv), rrText)
    isonim_dom.appendChild(isonim_dom.Node(row), isonim_dom.Node(rrDiv))

    let locDiv = createWebTextElement("div", fileLineText(entry),
                                      "trace-col-location")
    isonim_dom.appendChild(isonim_dom.Node(row), isonim_dom.Node(locDiv))

    let fnDiv = createWebTextElement("div", entry.functionName,
                                     "trace-col-function")
    isonim_dom.appendChild(isonim_dom.Node(row), isonim_dom.Node(fnDiv))

    let localsDiv = createWebTextElement("div", entry.localsText,
                                         "trace-col-locals")
    isonim_dom.appendChild(isonim_dom.Node(row), isonim_dom.Node(localsDiv))

    let onClick = onRowClick(vm, index)
    isonim_dom.addEventListener(isonim_dom.Node(row), cstring"click",
                                proc(ev: isonim_dom.Event) = onClick())
    row

  proc renderTraceLogPanel*(r: WebRenderer; vm: TraceLogVM): isonim_dom.Element =
    ## Render the Trace Log panel for the real DOM.  Same dispatch
    ## shape as the Mock variant — outer wrapper plus a render-effect
    ## that rebuilds the body and toggles the empty-state placeholder.
    var bodyContainer: isonim_dom.Element
    var emptyContainer: isonim_dom.Element

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
      clearWebChildren(bodyContainer)
      for i, entry in entries:
        let row = renderRowWeb(vm, entry, i, i == selected)
        isonim_dom.appendChild(isonim_dom.Node(bodyContainer),
                               isonim_dom.Node(row))

      if entries.len == 0:
        isonim_dom.setAttribute(emptyContainer, cstring"class",
                                cstring"trace-log-empty")
      else:
        isonim_dom.setAttribute(emptyContainer, cstring"class",
                                cstring"trace-log-empty hidden")

    panel

  proc mountIsoNimTraceLogPanel*(container: isonim_dom.Element;
                                 vm: TraceLogVM) =
    ## Mount the IsoNim Trace Log panel as a child of ``container``.
    ## Reactive effects handle every subsequent update — no manual
    ## redraw is needed.
    let r = WebRenderer()
    let panel = renderTraceLogPanel(r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container),
                           isonim_dom.Node(panel))
