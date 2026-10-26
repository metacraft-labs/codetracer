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
when defined(js):
  # Enter and Space on a `role="button"` row are its click.
  import ./isonim_activation

import isonim/core/[signals, computation]
import isonim/dsl/[ui, components]
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom
  import std/[jsffi, math]

import ../store/types
import ../viewmodels/request_panel_vm

# The generic procs expand the DSL at their instantiation site.
export signals, computation, components

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
  ## A completed recording's rows are read by window, so the counts are the
  ## engine's (`matchingCount`, `recordedCount`), not the rows held.
  countText(vm.matchingCount, vm.recordedCount)

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

when defined(js):
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

  proc preventDragDefault(e: isonim_dom.Event) {.importjs: "#.preventDefault()".}
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

proc pickerSelectHandler(onSelect: proc(value: string); value: string): proc() =
  ## The click handler of one picker option: select `value`.
  ##
  ## A FACTORY, like `makeTabClickHandler` above and for the same reason: the
  ## options are built in a `for` loop, and an inline `proc() = onSelect(v)`
  ## over a loop-body `let` made every option select the LAST one
  ## (codetracer#860 sweep).
  result = proc() = onSelect(value)

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
        tdiv(class = itemClass, onclick = pickerSelectHandler(onSelect, v)):
          span(class = "ct-menu-item-label"):
            text ol
      r.appendChild(dropdown, item)
  panel

# ---------------------------------------------------------------------------
# The panel, for every renderer
# ---------------------------------------------------------------------------

proc renderDetailContent[R, N](r: R; req: RequestRecord; tab: string): N =
  ## The content area for the active detail tab.
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

proc renderDetail[R, N](r: R; vm: RequestPanelVM; req: RequestRecord;
                        tab: string; handle: var N): N =
  ## The detail panel of the selected request: header bar (method badge, URL,
  ## status, Handler button), tab bar, and the active tab's content. `handle`
  ## is the resize handle, for the browser to wire the drag to.
  let badgeCls = methodBadgeClass(req.httpMethod)
  let statusCls = statusCellClass(req)
  let statusDisplayText = if req.isOpen: InFlightPlaceholder
                          else: detailStatusText(req.statusCode)
  var handleEl, tabBarHost, contentHost: N
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
    r.appendChild(tabBarHost, tabEl)
  let content: N = renderDetailContent[R, N](r, req, tab)
  r.appendChild(contentHost, content)
  handle = handleEl
  panel

proc renderRow[R, N](r: R; vm: RequestPanelVM; req: RequestRecord;
                     index: int; selected: bool): N =
  ## One filtered request row; a click selects it, a double click goes to it.
  ## The method column wraps the text in a per-method badge ``span``; the
  ## status column's ``span`` carries ``request-status-<bucket>`` so CSS
  ## colours both independently.
  let statusCls = statusCellClass(req)
  let badgeCls = methodBadgeClass(req.httpMethod)
  ui(r):
    tdiv(role = "button", tabindex = "0", class = rowClass(selected, req.isOpen),
         onclick = onRowClick(vm, index),
         ondblclick = onRowDoubleClick(vm, index)):
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

when defined(js):
  proc inputValue(node: isonim_dom.Node): cstring {.importjs: "(#.value || '')".}
  proc requestRowHeight(body: JsObject): float {.importjs:
    "(function(b){const r=b.querySelector('.request-row');return r?r.getBoundingClientRect().height:0;})(#)".}
  proc setRequestPadding(body: JsObject; top, bottom: cstring) {.importjs:
    "(function(b,t,o){b.style.paddingTop=t;b.style.paddingBottom=o;})(#,#,#)".}
  proc decorateRequestPanel(searchInputEl, bodyEl: isonim_dom.Element;
                            vm: RequestPanelVM) =
    ## The browser's half: the search box reads the live input, and the held
    ## window of rows is padded to every matching row (Viewport-Driven-Loading
    ## V2; the panel host reports the rows the body shows).
    let searchNode = isonim_dom.Node(searchInputEl)
    isonim_dom.addEventListener(searchNode, cstring"input",
      proc(ev: isonim_dom.Event) =
        vm.setSearchText($searchNode.inputValue()))
    let body = cast[JsObject](bodyEl)
    createEffect proc() =
      let held = vm.filteredRequests.val.len
      let start = vm.windowStart.val
      let total = vm.matchingCount
      let measured = requestRowHeight(body)
      let h = if measured > 0.0: measured else: 24.0
      if vm.windowed:
        setRequestPadding(body, cstring($(float(start) * h) & "px"),
          cstring($(float(max(0, total - start - held)) * h) & "px"))
      else:
        setRequestPadding(body, cstring"", cstring"")

proc renderRequestPanel*[R, N](r: R; vm: RequestPanelVM): N =
  ## The HTTP Request panel, under any renderer (Shared-DOM-Front-Ends D3);
  ## the panel host (`ui/panel_host`) mounts it and reports its rows.
  ##
  ## The static shell is built once via the DSL; the pickers, the table body
  ## and the detail panel are rebuilt by effects when their signals change.
  ## The Method and Status pickers use the shared ``renderFilterPicker``
  ## (``ct-picker ct-picker--chevron-right``), matching the VCS branch picker.
  mixin clearChildren, appendChild, addEventListener
  let methodPickerOpen = createSignal(false)
  let statusPickerOpen = createSignal(false)
  # Percentage of the panel height claimed by the detail pane, updated by the
  # drag-resize handle (browser only).
  let detailHeightPct = createSignal(50.0)
  var panelRef, methodPickerHost, statusPickerHost, searchInputEl: N
  var bodyContainer, detailContainer: N

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
      tdiv(class = "request-navigation-status", role = "status"):
        text vm.navigationMessage.val
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

  when N is MockNode:
    # Headless tests set ``value`` via ``r.setAttribute`` then fire "input";
    # the handler reads it back the same way.
    let captureSearchEl = searchInputEl
    r.addEventListener(searchInputEl, "input", proc() =
      vm.setSearchText(captureSearchEl.attributes.getOrDefault("value", "")))

  # Method picker — rebuilt whenever its open flag or the filter changes.
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
    r.appendChild(methodPickerHost, picker)

  # Status picker — rebuilt whenever its open flag or the filter changes.
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
    r.appendChild(statusPickerHost, picker)

  # Table body — rebuilt whenever the filtered list or the selection changes.
  createRenderEffect proc() =
    let filtered = vm.filteredRequests.val
    let selected = vm.selectedIndex.val
    r.clearChildren(bodyContainer)
    for i in 0 ..< filtered.len:
      let row: N = renderRow[R, N](r, vm, filtered[i], i, i == selected)
      r.appendChild(bodyContainer, row)

  when defined(js):
    when N is isonim_dom.Element:
      # The detail host's flex-basis follows the drag (kept apart from the
      # content effect so drag ticks don't rebuild the detail).
      createRenderEffect proc() =
        let pct = detailHeightPct.val
        let idx = vm.selectedIndex.val
        if idx >= 0:
          isonim_dom.setAttribute(detailContainer, cstring"style",
            cstring("flex: 0 0 " & $int(pct) & "%; min-height: 0"))
        else:
          isonim_dom.setAttribute(detailContainer, cstring"style", cstring"")

  # Detail panel — rebuilt when the selection, the list or the tab changes.
  createRenderEffect proc() =
    let idx = vm.selectedIndex.val
    let filtered = vm.filteredRequests.val
    let tab = vm.detailTab.val
    r.clearChildren(detailContainer)
    if idx >= 0 and idx < filtered.len:
      var handle: N
      let detail: N = renderDetail[R, N](r, vm, filtered[idx], tab, handle)
      r.appendChild(detailContainer, detail)
      when defined(js):
        when N is isonim_dom.Element:
          let capturePanel = panelRef
          let capturePct = detailHeightPct
          isonim_dom.addEventListener(isonim_dom.Node(handle), cstring"mousedown",
            proc(e: isonim_dom.Event) =
              e.preventDragDefault()
              let h = capturePanel.elemHeight
              let b = capturePanel.elemBottom
              setDocMouseMove proc(me: isonim_dom.Event) =
                let newPct = (b - me.clientY) / h * 100.0
                capturePct.val = max(15.0, min(85.0, newPct))
              setDocMouseUp proc(ue: isonim_dom.Event) =
                clearDocMouseMove()
                clearDocMouseUp())

  when defined(js):
    when N is isonim_dom.Element:
      decorateRequestPanel(searchInputEl, bodyContainer, vm)
  panel
