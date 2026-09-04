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
##     div.request-panel-filters
##       input.request-filter-search.ct-input-panel.ct-input-search-image
##       div.ct-picker.ct-picker--chevron-right  (method picker)
##         div.ct-picker-trigger[.ct-picker-trigger--open]
##           span.ct-picker-chevron  (SVG)
##           span.ct-picker-label
##         div.ct-picker-dropdown  (when open)
##           div.ct-menu-item[.ct-menu-item--active]  (one per method)
##       div.ct-picker.ct-picker--chevron-right  (status picker, same structure)
##     div.request-table-header
##       div.request-col-id           text "#"
##       div.request-col-method       text "method"
##       div.request-col-url          text "URL"
##       div.request-col-status       text "Status"
##       div.request-col-duration     text "Duration"
##       div.request-col-size         text "Size"
##     div.request-table-body
##       div.request-row[.selected]   (one per filtered request)
##         div.request-col-id         text "<zero-padded id>"
##         div.request-col-method
##           span.request-method-badge.<method>  text "<httpMethod>"
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

const InFlightPlaceholder* = "—"
  ## Text rendered in the Status and Duration columns of an in-flight row.
  ## The pane spec (GUI/Core-Panes/Request-Panel.md § Live Sessions) says an
  ## in-flight row is "rendered distinctly, with no status or duration" — a
  ## placeholder keeps the column grid aligned while saying "not yet known",
  ## which a literal empty cell would not.

proc rowClass*(selected: bool; isOpen: bool = false): string =
  ## Outer ``.request-row`` modifier string.  ``selected`` mirrors the legacy
  ## ``"request-row selected"`` concatenation; ``isOpen`` adds the RS-M3
  ## in-flight modifier so CSS can grey the row while its completion is still
  ## outstanding.  Both modifiers can apply at once — an in-flight row is
  ## selectable like any other.
  result = "request-row"
  if selected:
    result &= " selected"
  if isOpen:
    result &= " request-row-open"

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
  ##
  ## Both counts are shown: with a filter active, "how many of how many"
  ## is the question the badge answers, and a live session makes the
  ## unfiltered total move on its own.
  countText(vm.filteredRequests.val.len, vm.requests.val.len)

proc statusText*(req: RequestRecord): string =
  ## Status-column text.  An in-flight row has no status code yet (the open
  ## record carries ``statusCode == 0``), so it renders the placeholder
  ## rather than a misleading ``0``.
  if req.isOpen:
    InFlightPlaceholder
  else:
    $req.statusCode

proc statusCellClass*(req: RequestRecord): string =
  ## Status-column span class.  In flight the span's own status byte is
  ## ``"unknown"``, which is exactly the ``request-status-unknown`` bucket
  ## ``statusClass(0)`` already yields — spelled out here so the intent
  ## survives any future change to the bucket ranges.
  if req.isOpen:
    "request-status-unknown"
  else:
    statusClass(req.statusCode)

proc durationText*(req: RequestRecord): string =
  ## Duration-column text; the placeholder while in flight, since the
  ## wall-clock duration is only known at completion.
  if req.isOpen:
    InFlightPlaceholder
  else:
    formatDuration(req.durationMs)

proc methodBadgeClass*(httpMethod: string): string =
  ## Returns the full CSS class string for the per-method badge:
  ## ``"request-method-badge request-method-<lowercase-method>"``.
  "request-method-badge request-method-" & httpMethod.toLowerAscii()

proc makeTabClickHandler*(vm: RequestPanelVM; tab: string): proc() =
  ## Returns a click handler that switches the detail panel to ``tab``.
  ## Uses a factory function so each call creates a unique closure
  ## capturing its own ``captured`` binding — avoids the closure-in-loop
  ## capture issue that arises with inline proc literals in for loops.
  let captured = tab
  result = proc() = vm.setDetailTab(captured)

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

proc formatReqId*(id: int): string =
  ## Zero-pads single-digit IDs so the ``#`` column aligns nicely
  ## (matches the reference design: 01, 02 … 09, 10, 11 …).
  if id < 10: "0" & $id else: $id

proc statusCodeText*(code: int): string =
  ## Standard HTTP reason phrase for common status codes.
  ## Returns an empty string for unrecognised codes.
  case code
  of 100: "Continue"
  of 101: "Switching Protocols"
  of 200: "OK"
  of 201: "Created"
  of 202: "Accepted"
  of 204: "No Content"
  of 206: "Partial Content"
  of 301: "Moved Permanently"
  of 302: "Found"
  of 303: "See Other"
  of 304: "Not Modified"
  of 307: "Temporary Redirect"
  of 308: "Permanent Redirect"
  of 400: "Bad Request"
  of 401: "Unauthorized"
  of 403: "Forbidden"
  of 404: "Not Found"
  of 405: "Method Not Allowed"
  of 408: "Request Timeout"
  of 409: "Conflict"
  of 410: "Gone"
  of 413: "Content Too Large"
  of 422: "Unprocessable Content"
  of 429: "Too Many Requests"
  of 500: "Internal Server Error"
  of 501: "Not Implemented"
  of 502: "Bad Gateway"
  of 503: "Service Unavailable"
  of 504: "Gateway Timeout"
  else: ""

proc detailStatusText*(code: int): string =
  ## Full status display string for the detail panel header:
  ## "NNN Reason Phrase" for known codes, just "NNN" otherwise.
  let reason = statusCodeText(code)
  if reason.len > 0: $code & " " & reason else: $code

const DetailTabs* = [
  ("headers",   "Headers"),
  ("request",   "Request"),
  ("response",  "Response"),
  ("timing",    "Timing"),
  ("calltrace", "Call Trace"),
  ("asyncflow", "Async Flow"),
]
  ## (tabId, displayLabel) pairs for the request detail tab bar.
  ## ``tabId`` values are used as ``vm.detailTab`` signal values.

# ---------------------------------------------------------------------------
# ct-picker chevron SVGs and option data
# ---------------------------------------------------------------------------

const chevronDownSvg* = """<svg width="9" height="5" viewBox="0 0 9 5" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M0.353516 0.353577L4.35352 4.35358L8.35352 0.353576" stroke="#DDDDDD" stroke-linejoin="round"/></svg>"""
  ## Down-pointing chevron SVG injected into ``.ct-picker-chevron`` spans.
  ## Matches the VCS branch-picker chevron shape and colour.
const chevronUpSvg* = """<svg width="9" height="5" viewBox="0 0 9 5" fill="none" xmlns="http://www.w3.org/2000/svg"><path d="M8.35352 4.35358L4.35352 0.353577L0.353516 4.35358" stroke="#DDDDDD" stroke-linejoin="round"/></svg>"""
  ## Up-pointing chevron — shown when a picker dropdown is open.

const MethodPickerOptions*: array[8, (string, string)] = [
  ("", "Method: All"),
  ("GET", "GET"),
  ("POST", "POST"),
  ("PUT", "PUT"),
  ("DELETE", "DELETE"),
  ("PATCH", "PATCH"),
  ("HEAD", "HEAD"),
  ("OPTIONS", "OPTIONS"),
]
  ## (filterValue, displayLabel) pairs for the Method filter picker.
  ## An empty ``filterValue`` means "all methods".

const StatusPickerOptions*: array[5, (string, string)] = [
  ("", "Status: All"),
  ("2xx", "2xx Success"),
  ("3xx", "3xx Redirect"),
  ("4xx", "4xx Client Error"),
  ("5xx", "5xx Server Error"),
]
  ## (filterValue, displayLabel) pairs for the Status filter picker.

# ---------------------------------------------------------------------------
# Picker host helpers — generic across Mock and Web renderers
# ---------------------------------------------------------------------------

proc appendRenderedChild(r: MockRenderer; host, child: MockNode) =
  ## Attach a rendered picker item to its container.  Mirrors the VCS view's
  ## helper of the same name so ``renderFilterPicker`` can stay generic.
  r.appendChild(host, child)

proc setInnerHtml(r: MockRenderer; node: MockNode; html: string) =
  ## Set the inner HTML of a mock node.  ``renderFilterPicker`` uses this to
  ## inject the chevron SVG.  In the mock renderer this is a no-op: tests do
  ## not inspect the chevron SVG content.
  discard

# Web-renderer picker helpers forward-declared here (before renderFilterPicker)
# so that generic instantiation for WebRenderer finds setInnerHtml /
# appendRenderedChild. Mirrors the VCS view's pattern exactly.
when defined(js):
  proc setInnerHtml(r: WebRenderer; node: isonim_dom.Element; html: string) =
    ## Inject raw HTML into a DOM element.  Used by ``renderFilterPicker`` to
    ## insert the chevron SVG into ``.ct-picker-chevron`` spans.
    node.innerHTML = cstring(html)

  proc appendRenderedChild(r: WebRenderer; host, child: isonim_dom.Element) =
    ## Attach a rendered picker item to its container.
    r.appendChild(host, child)

  # ---------------------------------------------------------------------------
  # Drag-resize FFI — used by the detail panel resize handle
  # ---------------------------------------------------------------------------

  proc clientY(e: isonim_dom.Event): float {.importjs: "#.clientY".}
    ## Y coordinate of a mouse event relative to the viewport.

  proc elemHeight(el: isonim_dom.Element): float
    {.importjs: "#.getBoundingClientRect().height".}
    ## Live height of an element's bounding box.

  proc elemBottom(el: isonim_dom.Element): float
    {.importjs: "#.getBoundingClientRect().bottom".}
    ## Live bottom edge of an element's bounding box (viewport-relative).

  proc preventDefault(e: isonim_dom.Event) {.importjs: "#.preventDefault()".}
    ## Suppress the default browser action for an event (used on mousedown to
    ## prevent text-selection during a drag).

  proc setDocMouseMove(h: proc(e: isonim_dom.Event))
    {.importjs: "document.onmousemove = #".}
    ## Install a one-slot mousemove handler on document.  A second call
    ## replaces the previous handler, so only one drag is active at a time.

  proc clearDocMouseMove() =
    ## Remove the document mousemove handler installed by ``setDocMouseMove``.
    {.emit: "document.onmousemove = null;".}

  proc setDocMouseUp(h: proc(e: isonim_dom.Event))
    {.importjs: "document.onmouseup = #".}
    ## Install a one-slot mouseup handler on document (drag termination).

  proc clearDocMouseUp() =
    ## Remove the document mouseup handler installed by ``setDocMouseUp``.
    {.emit: "document.onmouseup = null;".}

proc renderFilterPicker[R](r: R; label: string; isOpen: bool;
                            currentValue: string;
                            options: openArray[(string, string)];
                            onToggle: proc();
                            onSelect: proc(value: string)): auto =
  ## Generic ``ct-picker`` renderer used for the Method and Status filter
  ## pickers.  Produces a ``div.ct-picker.ct-picker--chevron-right`` shell
  ## with a trigger row (chevron + label) and, when ``isOpen``, a floating
  ## dropdown of ``ct-menu-item`` rows.
  ##
  ## ``label``        — placeholder text shown when ``currentValue`` is empty
  ##                    (e.g. "Method: All").
  ## ``currentValue`` — the active filter value (``""`` means unfiltered).
  ## ``options``      — (filterValue, displayLabel) pairs; the entry whose
  ##                    ``filterValue == currentValue`` gets the
  ##                    ``ct-menu-item--active`` modifier.
  ## ``onToggle``     — called when the trigger is clicked.
  ## ``onSelect(v)``  — called when a dropdown item is clicked.
  var chevronHost: typeof(r.createElement("span"))
  var dropdown: typeof(r.createElement("div"))
  let chevronSvg = if isOpen: chevronUpSvg else: chevronDownSvg
  let triggerClass = if isOpen: "ct-picker-trigger ct-picker-trigger--open"
                     else: "ct-picker-trigger"
  let displayLabel = if currentValue == "": label else: currentValue
  let panel = ui(r):
    tdiv(class = "ct-picker ct-picker--chevron-right"):
      tdiv(class = triggerClass, onclick = onToggle):
        span(ref = chevronHost, class = "ct-picker-chevron")
        span(class = "ct-picker-label"):
          text displayLabel
      if isOpen:
        tdiv(ref = dropdown, class = "ct-picker-dropdown")
  r.setInnerHtml(chevronHost, chevronSvg)
  if isOpen:
    for (optValue, optLabel) in options:
      let v = optValue
      let ol = optLabel
      let itemClass = if v == currentValue: "ct-menu-item ct-menu-item--active"
                      else: "ct-menu-item"
      let item = ui(r):
        tdiv(class = itemClass, onclick = proc() = onSelect(v)):
          span(class = "ct-menu-item-label"):
            text ol
      r.appendRenderedChild(dropdown, item)
  panel

# ---------------------------------------------------------------------------
# Mock renderer — headless test DOM
# ---------------------------------------------------------------------------

proc renderDetailContentMock(r: MockRenderer; req: RequestRecord;
                              tab: string): MockNode =
  ## Renders the content area for the active detail tab.
  case tab
  of "timing":
    ui(r):
      tdiv(class = "request-detail-timing"):
        tdiv(class = "request-detail-section-title"):
          text "Timing (" & durationText(req) & ")"
        tdiv(class = "request-timing-row"):
          span(class = "request-timing-label"): text "Total"
          span(class = "request-timing-value"): text durationText(req)
  of "response":
    ui(r):
      tdiv(class = "request-detail-response"):
        tdiv(class = "request-detail-section-title"):
          text "Response"
        tdiv(class = "request-detail-row"):
          span(class = "request-detail-key"): text "Size"
          span(class = "request-detail-value"): text formatSize(req.responseSize)
  else:
    ui(r):
      tdiv(class = "request-detail-placeholder"):
        text "No data available for this tab."

proc renderDetailMock(r: MockRenderer; vm: RequestPanelVM;
                      req: RequestRecord; tab: string): MockNode =
  ## Full detail panel for the selected request — Mock renderer variant.
  ## Header bar: method badge | URL | status text | Handler button.
  ## Below: tab bar + content area driven by ``vm.detailTab``.
  let badgeCls = methodBadgeClass(req.httpMethod)
  let statusCls = statusCellClass(req)
  let statusDisplayText = if req.isOpen: InFlightPlaceholder
                          else: detailStatusText(req.statusCode)
  var tabBarHost: MockNode
  var contentHost: MockNode
  let panel = ui(r):
    tdiv(class = "request-detail"):
      tdiv(class = "request-detail-resize-handle")
      tdiv(class = "request-detail-header"):
        tdiv(class = "request-detail-header-left"):
          span(class = badgeCls):
            text req.httpMethod
          span(class = "request-detail-header-url"):
            text req.url
          span(class = "request-detail-header-status " & statusCls):
            text statusDisplayText
        tdiv(class = "request-detail-header-right"):
          button(class = "ct-button-md-primary request-detail-handler-btn",
                 onclick = proc() = vm.jumpToHandler(vm.selectedIndex.val)):
            text "Handler >"
      tdiv(ref = tabBarHost, class = "request-detail-tabs")
      tdiv(ref = contentHost, class = "request-detail-content")
  for (tabId, tabLabel) in DetailTabs:
    let tl = tabLabel
    let tabCls = if tabId == tab: "request-detail-tab request-detail-tab--active"
                 else: "request-detail-tab"
    let tabEl = ui(r):
      span(class = tabCls, onclick = makeTabClickHandler(vm, tabId)):
        text tl
    r.appendRenderedChild(tabBarHost, tabEl)
  r.appendRenderedChild(contentHost, renderDetailContentMock(r, req, tab))
  panel

proc renderRowMock(r: MockRenderer; vm: RequestPanelVM;
                   req: RequestRecord; index: int;
                   selected: bool): MockNode =
  ## Render a single filtered request row.  Click/dblclick handlers
  ## map onto the VM actions.  The method column wraps the text in a
  ## ``span`` with a per-method badge class; the status column wraps
  ## the code in a ``span`` carrying ``request-status-<bucket>`` so
  ## CSS rules colour both independently.
  let onClick = onRowClick(vm, index)
  let onDblClick = onRowDoubleClick(vm, index)
  let statusCls = statusCellClass(req)
  let badgeCls = methodBadgeClass(req.httpMethod)
  let row = ui(r):
    tdiv(class = rowClass(selected, req.isOpen),
         onclick = onClick,
         ondblclick = onDblClick):
      tdiv(class = "request-col-id"):
        text formatReqId(req.id)
      tdiv(class = "request-col-method"):
        span(class = badgeCls):
          text req.httpMethod
      tdiv(class = "request-col-url"):
        text req.url
      tdiv(class = "request-col-status"):
        span(class = statusCls):
          text statusText(req)
      tdiv(class = "request-col-duration"):
        text durationText(req)
      tdiv(class = "request-col-size"):
        text formatSize(req.responseSize)
  row

proc renderRequestPanel*(r: MockRenderer; vm: RequestPanelVM): MockNode =
  ## Render the HTTP Request panel for the Mock renderer.
  ##
  ## The static shell (filter-bar + table-header + table-body containers)
  ## is built once via the DSL.  Reactive ``createRenderEffect`` procs
  ## rebuild each picker and the table body whenever their signals change.
  ## The Method and Status pickers use the shared ``renderFilterPicker``
  ## helper (``ct-picker ct-picker--chevron-right``) so they visually
  ## match the VCS branch-picker style with the chevron on the right.
  let methodPickerOpen = createSignal(false)
  let statusPickerOpen = createSignal(false)
  var methodPickerHost: MockNode
  var statusPickerHost: MockNode
  var searchInputEl: MockNode
  var bodyContainer: MockNode
  var detailContainer: MockNode

  let panel = ui(r):
    tdiv(class = RequestPanelContainerClass, tabIndex = "2"):
      # Filter bar: [🔍 Find by URL...]  [Method ▼]  [Status ▼]
      tdiv(class = "request-panel-filters"):
        input(ref = searchInputEl,
              class = "request-filter-search ct-input-panel ct-input-search-image",
              `type` = "text",
              placeholder = "Find by URL...")
        tdiv(ref = methodPickerHost)
        tdiv(ref = statusPickerHost)
      # Column headers
      tdiv(class = "request-table-header"):
        tdiv(class = "request-col-id"):
          text "#"
        tdiv(class = "request-col-method"):
          text "method"
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
      # Detail panel host — empty when no row is selected, populated reactively
      tdiv(ref = detailContainer, class = "request-detail-host"):
        discard

  # Search input handler.  Tests set ``value`` via ``r.setAttribute``
  # then fire ``"input"``; the handler reads it back the same way.
  let captureSearchEl = searchInputEl
  let captureVm = vm
  r.addEventListener(searchInputEl, "input", proc() =
    let v = captureSearchEl.attributes.getOrDefault("value", "")
    captureVm.setSearchText(v)
  )

  # Method picker — rebuilt reactively whenever its open flag or the
  # current filter value changes.
  createRenderEffect proc() =
    let isOpen = methodPickerOpen.val
    let currentMethod = vm.filterMethod.val
    r.clearChildren(methodPickerHost)
    let picker = renderFilterPicker(r, "Method: All", isOpen, currentMethod,
      MethodPickerOptions,
      onToggle = proc() = methodPickerOpen.val = not methodPickerOpen.val,
      onSelect = proc(v: string) =
        vm.setFilterMethod(v)
        methodPickerOpen.val = false)
    r.appendRenderedChild(methodPickerHost, picker)

  # Status picker — rebuilt reactively whenever its open flag or the
  # current filter value changes.
  createRenderEffect proc() =
    let isOpen = statusPickerOpen.val
    let currentStatus = vm.filterStatus.val
    r.clearChildren(statusPickerHost)
    let picker = renderFilterPicker(r, "Status: All", isOpen, currentStatus,
      StatusPickerOptions,
      onToggle = proc() = statusPickerOpen.val = not statusPickerOpen.val,
      onSelect = proc(v: string) =
        vm.setFilterStatus(v)
        statusPickerOpen.val = false)
    r.appendRenderedChild(statusPickerHost, picker)

  # Table body — rebuilt whenever the filtered list or selection changes.
  createRenderEffect proc() =
    let filtered = vm.filteredRequests.val
    let selected = vm.selectedIndex.val
    r.clearChildren(bodyContainer)
    for i, req in filtered:
      let row = renderRowMock(r, vm, req, i, i == selected)
      r.appendChild(bodyContainer, row)

  # Detail panel — rebuilt when selection, filtered list, or active tab changes.
  createRenderEffect proc() =
    let idx = vm.selectedIndex.val
    let filtered = vm.filteredRequests.val
    let tab = vm.detailTab.val
    r.clearChildren(detailContainer)
    if idx >= 0 and idx < filtered.len:
      r.appendRenderedChild(detailContainer,
                            renderDetailMock(r, vm, filtered[idx], tab))

  panel

# ---------------------------------------------------------------------------
# Web renderer — production DOM
# ---------------------------------------------------------------------------

when defined(js):
  proc inputValue(node: isonim_dom.Node): cstring {.importjs: "(#.value || '')".}

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

  proc renderRowWeb(vm: RequestPanelVM; req: RequestRecord;
                    index: int; selected: bool): isonim_dom.Element =
    ## Build a request row in the real DOM.  Same shape as the Mock
    ## variant; click / dblclick handlers wired imperatively via
    ## ``addEventListener``.
    let row = createWebElement("div", rowClass(selected, req.isOpen))

    let idDiv = createWebTextElement("div", formatReqId(req.id), "request-col-id")
    isonim_dom.appendChild(isonim_dom.Node(row), isonim_dom.Node(idDiv))

    # Method badge: <div.request-col-method><span.request-method-badge ...>
    let methodDiv = createWebElement("div", "request-col-method")
    let methodBadge = createWebTextElement("span", req.httpMethod,
                                           methodBadgeClass(req.httpMethod))
    isonim_dom.appendChild(isonim_dom.Node(methodDiv),
                           isonim_dom.Node(methodBadge))
    isonim_dom.appendChild(isonim_dom.Node(row), isonim_dom.Node(methodDiv))

    let urlDiv = createWebTextElement("div", req.url, "request-col-url")
    isonim_dom.appendChild(isonim_dom.Node(row), isonim_dom.Node(urlDiv))

    let statusDiv = createWebElement("div", "request-col-status")
    let statusSpan = createWebTextElement("span", statusText(req),
                                           statusCellClass(req))
    isonim_dom.appendChild(isonim_dom.Node(statusDiv),
                           isonim_dom.Node(statusSpan))
    isonim_dom.appendChild(isonim_dom.Node(row), isonim_dom.Node(statusDiv))

    let durationDiv = createWebTextElement("div",
                                            durationText(req),
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

  proc renderDetailContentWeb(r: WebRenderer; req: RequestRecord;
                               tab: string): isonim_dom.Element =
    ## Tab content for the detail panel — Web renderer variant.
    case tab
    of "timing":
      ui(r):
        tdiv(class = "request-detail-timing"):
          tdiv(class = "request-detail-section-title"):
            text "Timing (" & durationText(req) & ")"
          tdiv(class = "request-timing-row"):
            span(class = "request-timing-label"): text "Total"
            span(class = "request-timing-value"): text durationText(req)
    of "response":
      ui(r):
        tdiv(class = "request-detail-response"):
          tdiv(class = "request-detail-section-title"):
            text "Response"
          tdiv(class = "request-detail-row"):
            span(class = "request-detail-key"): text "Size"
            span(class = "request-detail-value"): text formatSize(req.responseSize)
    else:
      ui(r):
        tdiv(class = "request-detail-placeholder"):
          text "No data available for this tab."

  proc renderDetailWeb(r: WebRenderer; vm: RequestPanelVM;
                       req: RequestRecord; tab: string;
                       onHandleDown: proc(e: isonim_dom.Event)): isonim_dom.Element =
    ## Full detail panel for the selected request — Web renderer variant.
    ## ``onHandleDown`` is wired to the resize handle's mousedown event so the
    ## caller (``renderRequestPanel``) can install the drag logic with access to
    ## the outer panel element and the ``detailHeightPct`` signal.
    let badgeCls = methodBadgeClass(req.httpMethod)
    let statusCls = statusCellClass(req)
    let statusDisplayText = if req.isOpen: InFlightPlaceholder
                            else: detailStatusText(req.statusCode)
    var handleEl: isonim_dom.Element
    var tabBarHost: isonim_dom.Element
    var contentHost: isonim_dom.Element
    let panel = ui(r):
      tdiv(class = "request-detail"):
        tdiv(ref = handleEl, class = "request-detail-resize-handle")
        tdiv(class = "request-detail-header"):
          tdiv(class = "request-detail-header-left"):
            span(class = badgeCls):
              text req.httpMethod
            span(class = "request-detail-header-url"):
              text req.url
            span(class = "request-detail-header-status " & statusCls):
              text statusDisplayText
          tdiv(class = "request-detail-header-right"):
            button(class = "ct-button-md-primary request-detail-handler-btn",
                   onclick = proc() = vm.jumpToHandler(vm.selectedIndex.val)):
              text "Handler >"
        tdiv(ref = tabBarHost, class = "request-detail-tabs")
        tdiv(ref = contentHost, class = "request-detail-content")
    for (tabId, tabLabel) in DetailTabs:
      let tl = tabLabel
      let tabCls = if tabId == tab: "request-detail-tab request-detail-tab--active"
                   else: "request-detail-tab"
      let tabEl = ui(r):
        span(class = tabCls, onclick = makeTabClickHandler(vm, tabId)):
          text tl
      r.appendRenderedChild(tabBarHost, tabEl)
    r.appendRenderedChild(contentHost, renderDetailContentWeb(r, req, tab))
    isonim_dom.addEventListener(isonim_dom.Node(handleEl), cstring"mousedown", onHandleDown)
    panel

  proc renderRequestPanel*(r: WebRenderer; vm: RequestPanelVM): isonim_dom.Element =
    ## Render the HTTP Request panel for the real DOM.  Matches the Mock
    ## variant: static shell via the DSL, three reactive effects for the
    ## Method picker, Status picker, and table body.  The pickers use the
    ## shared ``renderFilterPicker`` helper (``ct-picker--chevron-right``)
    ## so they visually match the VCS branch-picker with the chevron on
    ## the right side of the label.
    let methodPickerOpen = createSignal(false)
    let statusPickerOpen = createSignal(false)
    # Percentage of the panel height claimed by the detail pane.
    # Starts at 50% and is updated by the drag-resize handle.
    # Stored as a signal so the style-sync effect updates the inline flex-basis
    # reactively on every drag tick without rebuilding the detail content.
    let detailHeightPct = createSignal(50.0)
    var panelRef: isonim_dom.Element
    var methodPickerHost: isonim_dom.Element
    var statusPickerHost: isonim_dom.Element
    var searchInputEl: isonim_dom.Element
    var bodyContainer: isonim_dom.Element
    var detailContainer: isonim_dom.Element

    let panel = ui(r):
      tdiv(ref = panelRef, class = RequestPanelContainerClass, tabIndex = "2"):
        # Filter bar: [🔍 Find by URL...]  [Method ▼]  [Status ▼]
        tdiv(class = "request-panel-filters"):
          input(ref = searchInputEl,
                class = "request-filter-search ct-input-panel ct-input-search-image",
                `type` = "text",
                placeholder = "Find by URL...")
          tdiv(ref = methodPickerHost)
          tdiv(ref = statusPickerHost)
        # Column headers
        tdiv(class = "request-table-header"):
          tdiv(class = "request-col-id"):
            text "#"
          tdiv(class = "request-col-method"):
            text "method"
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
        # Detail panel host — empty when no row is selected, populated reactively
        tdiv(ref = detailContainer, class = "request-detail-host"):
          discard

    # Search handler — reads directly from the live input element.
    let searchNode = isonim_dom.Node(searchInputEl)
    isonim_dom.addEventListener(searchNode, cstring"input",
      proc(ev: isonim_dom.Event) =
        vm.setSearchText($searchNode.inputValue()))

    # Method picker — rebuilt reactively on open/filter state changes.
    createRenderEffect proc() =
      let isOpen = methodPickerOpen.val
      let currentMethod = vm.filterMethod.val
      clearWebChildren(methodPickerHost)
      let picker = renderFilterPicker(r, "Method: All", isOpen, currentMethod,
        MethodPickerOptions,
        onToggle = proc() = methodPickerOpen.val = not methodPickerOpen.val,
        onSelect = proc(v: string) =
          vm.setFilterMethod(v)
          methodPickerOpen.val = false)
      isonim_dom.appendChild(isonim_dom.Node(methodPickerHost),
                             isonim_dom.Node(picker))

    # Status picker — rebuilt reactively on open/filter state changes.
    createRenderEffect proc() =
      let isOpen = statusPickerOpen.val
      let currentStatus = vm.filterStatus.val
      clearWebChildren(statusPickerHost)
      let picker = renderFilterPicker(r, "Status: All", isOpen, currentStatus,
        StatusPickerOptions,
        onToggle = proc() = statusPickerOpen.val = not statusPickerOpen.val,
        onSelect = proc(v: string) =
          vm.setFilterStatus(v)
          statusPickerOpen.val = false)
      isonim_dom.appendChild(isonim_dom.Node(statusPickerHost),
                             isonim_dom.Node(picker))

    # Table body — rebuilt on filteredRequests / selectedIndex changes.
    createRenderEffect proc() =
      let filtered = vm.filteredRequests.val
      let selected = vm.selectedIndex.val
      clearWebChildren(bodyContainer)
      for i, req in filtered:
        let row = renderRowWeb(vm, req, i, i == selected)
        isonim_dom.appendChild(isonim_dom.Node(bodyContainer),
                               isonim_dom.Node(row))

    # Style effect: sync the detail host's flex-basis to detailHeightPct.
    # Runs on every drag tick (detailHeightPct changes) and on selection change
    # (to set or clear the style).  Kept separate from the content effect so
    # drag ticks don't trigger a full DOM rebuild.
    createRenderEffect proc() =
      let pct = detailHeightPct.val
      let idx = vm.selectedIndex.val
      if idx >= 0:
        isonim_dom.setAttribute(detailContainer, cstring"style",
          cstring("flex: 0 0 " & $int(pct) & "%; min-height: 0"))
      else:
        isonim_dom.setAttribute(detailContainer, cstring"style", cstring"")

    # Content effect: rebuild the detail panel DOM when selection, filtered
    # list, or active tab changes.  Wires the resize-handle drag each time
    # so the drag closure always captures a fresh panel bounding rect.
    createRenderEffect proc() =
      let idx = vm.selectedIndex.val
      let filtered = vm.filteredRequests.val
      let tab = vm.detailTab.val
      clearWebChildren(detailContainer)
      if idx >= 0 and idx < filtered.len:
        let capturePanel = panelRef
        let capturePct = detailHeightPct
        let onHandleDown = proc(e: isonim_dom.Event) =
          e.preventDefault()
          let h = capturePanel.elemHeight
          let b = capturePanel.elemBottom
          setDocMouseMove proc(me: isonim_dom.Event) =
            let newPct = (b - me.clientY) / h * 100.0
            capturePct.val = max(15.0, min(85.0, newPct))
          setDocMouseUp proc(ue: isonim_dom.Event) =
            clearDocMouseMove()
            clearDocMouseUp()
        isonim_dom.appendChild(isonim_dom.Node(detailContainer),
                               isonim_dom.Node(renderDetailWeb(r, vm, filtered[idx], tab, onHandleDown)))

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
