## views/isonim_request_panel_view.nim
##
## IsoNim DOM-rendering view for the HTTP Request panel.
##
## Renders a live, reactive DOM tree driven by ``RequestPanelVM``
## signals.  Replaces the legacy Karax ``method render`` in
## ``frontend/ui/request_panel.nim`` (the IsoNim view is the single
## source of truth for the panel's DOM).
##
## Both renderer overloads (Mock and Web) produce the same outer
## structure mirroring the legacy ``componentContainerClass(
## "request-panel")`` layout::
##
##   div.component-container.request-panel
##     div.request-panel-header
##       div.request-panel-filters
##         select.request-filter-select  (method dropdown)
##         select.request-filter-select  (status dropdown)
##         input.request-filter-search   (URL search)
##       div.request-panel-count
##         text "<filtered>/<total> requests"
##     div.request-table-header
##       div.request-col-id           text "#"
##       div.request-col-method       text "Method"
##       div.request-col-url          text "URL"
##       div.request-col-status       text "Status"
##       div.request-col-duration     text "Duration"
##       div.request-col-size         text "Size"
##     div.request-table-body
##       div.request-row[.selected]   (one per filtered request)
##         div.request-col-id         text "<id>"
##         div.request-col-method     text "<httpMethod>"
##         div.request-col-url        text "<url>"
##         div.request-col-status
##           span.request-status-<bucket>  text "<statusCode>"
##         div.request-col-duration   text "<formatted duration>"
##         div.request-col-size       text "<formatted size>"
##
## Reactive surface:
## - One ``createRenderEffect`` rebuilds the table body whenever
##   ``filteredRequests`` or ``selectedIndex`` changes.  Mirrors the
##   ``low_level_code`` view's pattern (DSL builds the static shell,
##   imperative renderer ops inside the effect handle the row list).
## - The count badge is a small standalone ``createRenderEffect``
##   that swaps the text node when the totals change.
## - Filter inputs / select wires use the captured ``var``-binding
##   pattern from the REPL view (``ref = inputEl`` then imperative
##   ``addEventListener`` after the DSL expansion) so we can read
##   each control's value when its event fires.

import std/[strutils, tables]

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../store/types
import ../viewmodels/request_panel_vm

const RequestPanelContainerClass* = "component-container request-panel"
  ## Verbatim string the legacy ``componentContainerClass(
  ## "request-panel")`` template produced (see
  ## ``frontend/renderer.nim::componentContainerClass`` — emits
  ## ``"component-container " & class``).  Exposed for headless
  ## tests so they assert against the exact class string.

const HttpMethods* = ["GET", "POST", "PUT", "DELETE", "PATCH",
                      "HEAD", "OPTIONS"]
  ## Method-filter dropdown options.  Exposed so the view, the
  ## headless tests, and any future fixture builder share a single
  ## source of truth.  Order mirrors the legacy
  ## ``request_panel.nim::renderFilterBar`` array.

const StatusBucketOptions*: array[4, tuple[value: string; label: string]] = [
  (value: "2xx", label: "2xx Success"),
  (value: "3xx", label: "3xx Redirect"),
  (value: "4xx", label: "4xx Client Error"),
  (value: "5xx", label: "5xx Server Error"),
]
  ## Status-filter dropdown options.  Same ordering and label copy as
  ## the legacy view so visual regressions keep working.

# ---------------------------------------------------------------------------
# Reactive helpers used inside DSL expressions
# ---------------------------------------------------------------------------

proc rowClass*(selected: bool): string =
  ## Outer ``.request-row`` modifier for the selected row.  Mirrors
  ## the legacy ``"request-row selected"`` concatenation.
  if selected:
    "request-row selected"
  else:
    "request-row"

proc countText*(filtered, total: int): string =
  ## "<filtered>/<total> requests" badge text.  Matches the legacy
  ## ``fmt"{filtered.len} / {requests.len} requests"`` shape so any
  ## existing visual fixture keys keep matching.
  $filtered & " / " & $total & " requests"

proc countText*(vm: RequestPanelVM): string =
  ## Reactive overload — reads ``filteredRequests`` and ``requests``
  ## signals so that, when used inside a ``ui()`` DSL ``text`` slot,
  ## the resulting text node updates whenever either signal changes
  ## without rebuilding the surrounding span (the test fixtures grab
  ## the span by class once and re-check ``textContent``).
  let filtered = vm.filteredRequests.val.len
  let total = vm.requests.val.len
  countText(filtered, total)

proc onRowClick(vm: RequestPanelVM; index: int): proc() =
  ## Closure factory that captures the row's filtered-list index so
  ## each row's click handler refers to its own value.  Without the
  ## per-row capture every row's closure would observe the loop
  ## variable's final value (same closure-capture concern as the
  ## low_level_code / step_list views).
  let captured = index
  result = proc() = vm.selectRequest(captured)

proc onRowDoubleClick(vm: RequestPanelVM; index: int): proc() =
  ## Closure factory for the per-row ``ondblclick`` handler.  Mirrors
  ## ``onRowClick`` but dispatches ``vm.jumpToHandler`` instead.
  let captured = index
  result = proc() = vm.jumpToHandler(captured)

# ---------------------------------------------------------------------------
# Mock renderer — headless test DOM
# ---------------------------------------------------------------------------

proc renderRowMock(r: MockRenderer; vm: RequestPanelVM;
                   req: RequestRecord; index: int;
                   selected: bool): MockNode =
  ## Render a single filtered request row.  Click/dblclick handlers
  ## map onto the VM actions; the status column wraps the code in a
  ## ``span`` carrying ``request-status-<bucket>`` so CSS rules can
  ## colour it independently.
  let onClick = onRowClick(vm, index)
  let onDblClick = onRowDoubleClick(vm, index)
  let statusCls = statusClass(req.statusCode)
  let row = ui(r):
    tdiv(class = rowClass(selected),
         onclick = onClick,
         ondblclick = onDblClick):
      tdiv(class = "request-col-id"):
        text $req.id
      tdiv(class = "request-col-method"):
        text req.httpMethod
      tdiv(class = "request-col-url"):
        text req.url
      tdiv(class = "request-col-status"):
        span(class = statusCls):
          text $req.statusCode
      tdiv(class = "request-col-duration"):
        text formatDuration(req.durationMs)
      tdiv(class = "request-col-size"):
        text formatSize(req.responseSize)
  row

proc renderRequestPanel*(r: MockRenderer; vm: RequestPanelVM): MockNode =
  ## Render the HTTP Request panel for the Mock renderer.
  ##
  ## The static shell (header + table-header + table-body containers)
  ## is built once via the DSL.  Three outer ``createRenderEffect``
  ## blocks handle dynamic content:
  ## 1. Count badge — re-renders when filteredRequests / requests
  ##    counts change.
  ## 2. Table body — rebuilt on filteredRequests / selectedIndex
  ##    changes.
  ## Filter widget event listeners are wired imperatively against
  ## refs captured during DSL expansion.
  var methodSelectEl: MockNode
  var statusSelectEl: MockNode
  var searchInputEl: MockNode
  var countContainer: MockNode
  var bodyContainer: MockNode

  let panel = ui(r):
    tdiv(class = RequestPanelContainerClass, tabIndex = "2"):
      tdiv(class = "request-panel-header"):
        tdiv(class = "request-panel-filters"):
          # Method filter
          select(ref = methodSelectEl, class = "request-filter-select"):
            option(value = ""):
              text "All Methods"
            for m in HttpMethods:
              option(value = m):
                text m
          # Status-class filter
          select(ref = statusSelectEl, class = "request-filter-select"):
            option(value = ""):
              text "All Status"
            for opt in StatusBucketOptions:
              option(value = opt.value):
                text opt.label
          # URL search
          input(ref = searchInputEl,
                class = "request-filter-search",
                `type` = "text",
                placeholder = "Search URL...")
        tdiv(ref = countContainer, class = "request-panel-count"):
          span(class = "request-panel-count-text"):
            text countText(vm)
      tdiv(class = "request-table-header"):
        tdiv(class = "request-col-id"):
          text "#"
        tdiv(class = "request-col-method"):
          text "Method"
        tdiv(class = "request-col-url"):
          text "URL"
        tdiv(class = "request-col-status"):
          text "Status"
        tdiv(class = "request-col-duration"):
          text "Duration"
        tdiv(class = "request-col-size"):
          text "Size"
      tdiv(ref = bodyContainer, class = "request-table-body"):
        discard

  # Filter widget handlers.  ``MockNode.fireEvent`` calls the
  # registered ``proc()`` listeners with no event arg, so each
  # handler reads the source widget's "value" attribute directly.
  # Headless tests set the value via ``r.setAttribute`` before
  # firing the event.
  let captureMethodEl = methodSelectEl
  let captureStatusEl = statusSelectEl
  let captureSearchEl = searchInputEl
  let captureVm = vm
  r.addEventListener(methodSelectEl, "change", proc() =
    let v = captureMethodEl.attributes.getOrDefault("value", "")
    captureVm.setFilterMethod(v)
  )
  r.addEventListener(statusSelectEl, "change", proc() =
    let v = captureStatusEl.attributes.getOrDefault("value", "")
    captureVm.setFilterStatus(v)
  )
  r.addEventListener(searchInputEl, "input", proc() =
    let v = captureSearchEl.attributes.getOrDefault("value", "")
    captureVm.setSearchText(v)
  )

  # Count badge — the ``text countText(vm)`` call inside the static
  # ``ui()`` block above is wired reactively by the DSL: only the
  # text node updates when ``filteredRequests`` / ``requests``
  # change, so the surrounding span (which test fixtures grab once
  # via ``findByClass``) keeps its identity across re-renders.

  # Table body — rebuilt whenever the filtered list or selection
  # changes.  ``selectedIndex`` is read inside the effect so the
  # subscription edge is established for it too.
  createRenderEffect proc() =
    let filtered = vm.filteredRequests.val
    let selected = vm.selectedIndex.val
    r.clearChildren(bodyContainer)
    for i, req in filtered:
      let row = renderRowMock(r, vm, req, i, i == selected)
      r.appendChild(bodyContainer, row)

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

  proc createOption(value, label: string): isonim_dom.Element =
    ## Build a ``<option value="...">label</option>`` element.
    let opt = createWebElement("option")
    isonim_dom.setAttribute(opt, cstring"value", cstring(value))
    let t = isonim_dom.createTextNode(isonim_dom.document, cstring(label))
    isonim_dom.appendChild(isonim_dom.Node(opt), t)
    opt

  proc renderRowWeb(vm: RequestPanelVM; req: RequestRecord;
                    index: int; selected: bool): isonim_dom.Element =
    ## Build a request row in the real DOM.  Same shape as the Mock
    ## variant; click / dblclick handlers wired imperatively via
    ## ``addEventListener``.
    let row = createWebElement("div", rowClass(selected))

    let idDiv = createWebTextElement("div", $req.id, "request-col-id")
    isonim_dom.appendChild(isonim_dom.Node(row), isonim_dom.Node(idDiv))

    let methodDiv = createWebTextElement("div", req.httpMethod,
                                         "request-col-method")
    isonim_dom.appendChild(isonim_dom.Node(row), isonim_dom.Node(methodDiv))

    let urlDiv = createWebTextElement("div", req.url, "request-col-url")
    isonim_dom.appendChild(isonim_dom.Node(row), isonim_dom.Node(urlDiv))

    let statusDiv = createWebElement("div", "request-col-status")
    let statusSpan = createWebTextElement("span", $req.statusCode,
                                           statusClass(req.statusCode))
    isonim_dom.appendChild(isonim_dom.Node(statusDiv),
                           isonim_dom.Node(statusSpan))
    isonim_dom.appendChild(isonim_dom.Node(row), isonim_dom.Node(statusDiv))

    let durationDiv = createWebTextElement("div",
                                            formatDuration(req.durationMs),
                                            "request-col-duration")
    isonim_dom.appendChild(isonim_dom.Node(row), isonim_dom.Node(durationDiv))

    let sizeDiv = createWebTextElement("div", formatSize(req.responseSize),
                                        "request-col-size")
    isonim_dom.appendChild(isonim_dom.Node(row), isonim_dom.Node(sizeDiv))

    let onClick = onRowClick(vm, index)
    let onDbl = onRowDoubleClick(vm, index)
    isonim_dom.addEventListener(isonim_dom.Node(row), cstring"click",
                                proc(ev: isonim_dom.Event) = onClick())
    isonim_dom.addEventListener(isonim_dom.Node(row), cstring"dblclick",
                                proc(ev: isonim_dom.Event) = onDbl())
    row

  proc renderRequestPanel*(r: WebRenderer; vm: RequestPanelVM): isonim_dom.Element =
    ## Render the HTTP Request panel for the real DOM.  Same dispatch
    ## shape as the Mock variant — outer wrapper plus render-effects
    ## for the count badge and the table body.  Filter widget events
    ## are wired imperatively against the captured nodes.
    var methodSelectEl: isonim_dom.Element
    var statusSelectEl: isonim_dom.Element
    var searchInputEl: isonim_dom.Element
    var countContainer: isonim_dom.Element
    var bodyContainer: isonim_dom.Element

    let panel = ui(r):
      tdiv(class = RequestPanelContainerClass, tabIndex = "2"):
        tdiv(class = "request-panel-header"):
          tdiv(class = "request-panel-filters"):
            select(ref = methodSelectEl, class = "request-filter-select"):
              discard
            select(ref = statusSelectEl, class = "request-filter-select"):
              discard
            input(ref = searchInputEl,
                  class = "request-filter-search",
                  `type` = "text",
                  placeholder = "Search URL...")
          tdiv(ref = countContainer, class = "request-panel-count"):
            span(class = "request-panel-count-text"):
              text countText(vm)
        tdiv(class = "request-table-header"):
          tdiv(class = "request-col-id"):
            text "#"
          tdiv(class = "request-col-method"):
            text "Method"
          tdiv(class = "request-col-url"):
            text "URL"
          tdiv(class = "request-col-status"):
            text "Status"
          tdiv(class = "request-col-duration"):
            text "Duration"
          tdiv(class = "request-col-size"):
            text "Size"
        tdiv(ref = bodyContainer, class = "request-table-body"):
          discard

    # Populate the dropdown options imperatively — the DSL ``select``
    # body uses ``discard`` so nothing was emitted there.
    isonim_dom.appendChild(isonim_dom.Node(methodSelectEl),
                           isonim_dom.Node(createOption("", "All Methods")))
    for m in HttpMethods:
      isonim_dom.appendChild(isonim_dom.Node(methodSelectEl),
                             isonim_dom.Node(createOption(m, m)))
    isonim_dom.appendChild(isonim_dom.Node(statusSelectEl),
                           isonim_dom.Node(createOption("", "All Status")))
    for opt in StatusBucketOptions:
      isonim_dom.appendChild(isonim_dom.Node(statusSelectEl),
                             isonim_dom.Node(createOption(opt.value, opt.label)))

    # Filter widget handlers.  Read the value off the live element
    # via JS access ({.emit:.}) so HTMLInputElement / HTMLSelectElement
    # ``.value`` works without going through the typed wrapper.
    let methodNode = isonim_dom.Node(methodSelectEl)
    let statusNode = isonim_dom.Node(statusSelectEl)
    let searchNode = isonim_dom.Node(searchInputEl)
    isonim_dom.addEventListener(methodNode, cstring"change",
      proc(ev: isonim_dom.Event) =
        var v: cstring
        {.emit: "`v` = `methodNode`.value || '';".}
        vm.setFilterMethod($v))
    isonim_dom.addEventListener(statusNode, cstring"change",
      proc(ev: isonim_dom.Event) =
        var v: cstring
        {.emit: "`v` = `statusNode`.value || '';".}
        vm.setFilterStatus($v))
    isonim_dom.addEventListener(searchNode, cstring"input",
      proc(ev: isonim_dom.Event) =
        var v: cstring
        {.emit: "`v` = `searchNode`.value || '';".}
        vm.setSearchText($v))

    # Count badge — the ``text countText(vm)`` call inside the static
    # ``ui()`` block above produces a reactive text node managed by
    # the DSL.  Only the text node is patched when the signals
    # change; the surrounding span and its
    # ``request-panel-count-text`` class stay stable across updates.

    # Table body — rebuilt on filteredRequests / selectedIndex
    # changes.
    createRenderEffect proc() =
      let filtered = vm.filteredRequests.val
      let selected = vm.selectedIndex.val
      clearWebChildren(bodyContainer)
      for i, req in filtered:
        let row = renderRowWeb(vm, req, i, i == selected)
        isonim_dom.appendChild(isonim_dom.Node(bodyContainer),
                               isonim_dom.Node(row))

    panel

  proc mountIsoNimRequestPanel*(container: isonim_dom.Element;
                                 vm: RequestPanelVM) =
    ## Mount the IsoNim Request panel as a child of ``container``.
    ## Reactive effects handle every subsequent update — no manual
    ## redraw is needed.
    let r = WebRenderer()
    let panel = renderRequestPanel(r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container),
                           isonim_dom.Node(panel))
