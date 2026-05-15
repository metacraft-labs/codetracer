## HTTP Request Panel — displays captured HTTP requests in a filterable,
## sortable table.  Double-clicking a row will eventually seek the debugger
## to the handler entry point (wired in M6).
##
## Design follows the same Component patterns as `event_log.nim` and
## `scratchpad.nim`: inherits from Component, rendered via Karax buildHtml,
## registered through the standard `register` / mediator infrastructure.

import
  ui_imports,
  ../[ types, communication ],
  ../../common/ct_event

# ---------------------------------------------------------------------------
# Helper formatters
# ---------------------------------------------------------------------------

proc statusClass(code: int): cstring =
  ## CSS class suffix for the HTTP status badge.
  if code >= 200 and code < 300: cstring"request-status-success"
  elif code >= 300 and code < 400: cstring"request-status-redirect"
  elif code >= 400 and code < 500: cstring"request-status-client-error"
  elif code >= 500: cstring"request-status-server-error"
  else: cstring"request-status-unknown"

proc statusColor(code: int): kstring =
  ## Inline color matching the dark theme palette.
  if code >= 200 and code < 300: kstring"#3fb950"    # green
  elif code >= 300 and code < 400: kstring"#58a6ff"   # blue
  elif code >= 400 and code < 500: kstring"#d29922"   # yellow
  elif code >= 500: kstring"#f85149"                  # red
  else: kstring"#8b949e"                              # grey

proc methodColor(m: cstring): kstring =
  ## Per-verb color inspired by the Swagger / OpenAPI convention.
  case $m
  of "GET":    kstring"#61affe"
  of "POST":   kstring"#49cc90"
  of "PUT":    kstring"#fca130"
  of "DELETE": kstring"#f93e3e"
  of "PATCH":  kstring"#50e3c2"
  of "HEAD":   kstring"#9012fe"
  of "OPTIONS": kstring"#0d5aa7"
  else: kstring"#8b949e"

proc formatDuration(ms: int): cstring =
  if ms < 1000:
    cstring($ms & "ms")
  else:
    cstring(fmt"{ms div 1000}.{(ms mod 1000) div 100}s")

proc formatSize(bytes: int): cstring =
  if bytes < 1024:
    cstring($bytes & " B")
  elif bytes < 1024 * 1024:
    cstring(fmt"{bytes div 1024}.{(bytes mod 1024) * 10 div 1024} KB")
  else:
    let mb = bytes div (1024 * 1024)
    let remainder = (bytes mod (1024 * 1024)) * 10 div (1024 * 1024)
    cstring(fmt"{mb}.{remainder} MB")

# ---------------------------------------------------------------------------
# Component extension (ctInExtension boiler-plate)
# ---------------------------------------------------------------------------

when defined(ctInExtension):
  var requestPanelComponentForExtension* {.exportc.}: RequestPanelComponent =
    makeRequestPanelComponent(data, 0, inExtension = true)

  proc makeRequestPanelComponentForExtension*(id: cstring): RequestPanelComponent {.exportc.} =
    if requestPanelComponentForExtension.kxi.isNil:
      requestPanelComponentForExtension.kxi = setRenderer(
        proc: VNode = requestPanelComponentForExtension.render(), id, proc = discard)
    result = requestPanelComponentForExtension

# ---------------------------------------------------------------------------
# Filtering
# ---------------------------------------------------------------------------

proc matchesFilter(self: RequestPanelComponent, req: HttpRequestEntry): bool =
  ## Returns true when `req` passes the currently active filters.
  let state = self.panelState

  # Method filter
  if state.filterMethod.len > 0 and req.httpMethod != state.filterMethod:
    return false

  # Status-class filter (e.g. "2xx", "4xx")
  if state.filterStatus.len > 0:
    let s = $state.filterStatus
    case s
    of "2xx":
      if req.statusCode < 200 or req.statusCode >= 300: return false
    of "3xx":
      if req.statusCode < 300 or req.statusCode >= 400: return false
    of "4xx":
      if req.statusCode < 400 or req.statusCode >= 500: return false
    of "5xx":
      if req.statusCode < 500 or req.statusCode >= 600: return false
    else:
      discard

  # Free-text search on URL (case-insensitive)
  if state.searchText.len > 0:
    if ($state.searchText).toLowerAscii notin ($req.url).toLowerAscii:
      return false

  return true

proc filteredRequests(self: RequestPanelComponent): seq[HttpRequestEntry] =
  for req in self.panelState.requests:
    if self.matchesFilter(req):
      result.add(req)

# ---------------------------------------------------------------------------
# Public API — called by the backend when new data arrives
# ---------------------------------------------------------------------------

proc addRequest*(self: RequestPanelComponent,
                 httpMethod, url: cstring,
                 statusCode, durationMs, responseSize: int,
                 startGEID: int64) =
  ## Append a captured request. Called from the backend bridge (M6).
  let id = self.panelState.requests.len + 1
  self.panelState.requests.add(HttpRequestEntry(
    id: id,
    httpMethod: httpMethod,
    url: url,
    statusCode: statusCode,
    durationMs: durationMs,
    responseSize: responseSize,
    startGEID: startGEID,
    sliceFile: cstring"",
  ))
  self.redraw()

proc clearRequests*(self: RequestPanelComponent) =
  ## Remove all entries (e.g. on session restart).
  self.panelState.requests = @[]
  self.panelState.selectedIndex = -1
  self.redraw()

proc selectRequest*(self: RequestPanelComponent, index: int) =
  self.panelState.selectedIndex = index
  self.redraw()

proc jumpToHandler*(self: RequestPanelComponent, index: int) =
  ## Seek the debugger to the handler entry point (double-click action).
  ## Full wiring happens in M6; for now we just log.
  let filtered = self.filteredRequests()
  if index >= 0 and index < filtered.len:
    let req = filtered[index]
    console.log(cstring"RequestPanel: jump to handler at GEID ", req.startGEID)
    # M6 will replace this with:
    #   self.api.emit(CtSeekToGEID, req.startGEID)

# ---------------------------------------------------------------------------
# Render
# ---------------------------------------------------------------------------

proc renderFilterBar(self: RequestPanelComponent): VNode =
  ## Toolbar: method dropdown, status dropdown, URL search, count badge.
  buildHtml(tdiv(class = "request-panel-header")):
    tdiv(class = "request-panel-filters"):
      # -- Method filter --
      select(class = "request-filter-select"):
        proc onchange(ev: Event, n: VNode) =
          self.panelState.filterMethod = cast[cstring](ev.target.toJs.value)
          self.redraw()
        option(value = ""): text "All Methods"
        for m in ["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"]:
          option(value = cstring(m)): text cstring(m)

      # -- Status filter --
      select(class = "request-filter-select"):
        proc onchange(ev: Event, n: VNode) =
          self.panelState.filterStatus = cast[cstring](ev.target.toJs.value)
          self.redraw()
        option(value = ""): text "All Status"
        option(value = "2xx"): text "2xx Success"
        option(value = "3xx"): text "3xx Redirect"
        option(value = "4xx"): text "4xx Client Error"
        option(value = "5xx"): text "5xx Server Error"

      # -- URL search --
      input(class = "request-filter-search", `type` = "text",
            placeholder = "Search URL..."):
        proc oninput(ev: Event, n: VNode) =
          self.panelState.searchText = cast[cstring](ev.target.toJs.value)
          self.redraw()

    tdiv(class = "request-panel-count"):
      let filtered = self.filteredRequests()
      text cstring(fmt"{filtered.len} / {self.panelState.requests.len} requests")

proc renderTableHeader(self: RequestPanelComponent): VNode =
  ## Column headings row.
  buildHtml(tdiv(class = "request-table-header")):
    tdiv(class = "request-col-id"):   text "#"
    tdiv(class = "request-col-method"): text "Method"
    tdiv(class = "request-col-url"):    text "URL"
    tdiv(class = "request-col-status"): text "Status"
    tdiv(class = "request-col-duration"): text "Duration"
    tdiv(class = "request-col-size"):   text "Size"

proc renderTableBody(self: RequestPanelComponent): VNode =
  ## Scrollable list of request rows.
  let filtered = self.filteredRequests()
  buildHtml(tdiv(class = "request-table-body")):
    for i, req in filtered:
      let isSelected = i == self.panelState.selectedIndex
      let rowClass = if isSelected: "request-row selected" else: "request-row"
      # Capture loop variable for closures
      let capturedIndex = i
      tdiv(class = cstring(rowClass)):
        proc onclick(ev: Event, node: VNode) =
          self.selectRequest(capturedIndex)
        proc ondblclick(ev: Event, node: VNode) =
          self.jumpToHandler(capturedIndex)

        tdiv(class = "request-col-id"):
          text cstring($req.id)
        tdiv(class = "request-col-method"):
          span(style = style(StyleAttr.color, methodColor(req.httpMethod))):
            text req.httpMethod
        tdiv(class = "request-col-url"):
          text req.url
        tdiv(class = "request-col-status"):
          span(class = statusClass(req.statusCode),
               style = style(StyleAttr.color, statusColor(req.statusCode))):
            text cstring($req.statusCode)
        tdiv(class = "request-col-duration"):
          text formatDuration(req.durationMs)
        tdiv(class = "request-col-size"):
          text formatSize(req.responseSize)

method render*(self: RequestPanelComponent): VNode =
  buildHtml(
    tdiv(
      class = componentContainerClass("request-panel"),
      tabIndex = "0",
      onclick = proc(ev: Event, v: VNode) =
        ev.stopPropagation()
        if self.data.ui.activeFocus != self:
          self.data.ui.activeFocus = self
    )
  ):
    self.renderFilterBar()
    self.renderTableHeader()
    self.renderTableBody()

# ---------------------------------------------------------------------------
# Registration (mediator / event bus)
# ---------------------------------------------------------------------------

method register*(self: RequestPanelComponent, api: MediatorWithSubscribers) =
  self.api = api
  # M6 will subscribe to backend events here, e.g.:
  #   api.subscribe(CtUpdatedHttpRequests, ...)

method restart*(self: RequestPanelComponent) =
  self.clearRequests()

method clear*(self: RequestPanelComponent) =
  self.clearRequests()

proc registerRequestPanelComponent*(component: RequestPanelComponent,
                                     api: MediatorWithSubscribers) {.exportc.} =
  component.register(api)
