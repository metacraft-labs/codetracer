## views/isonim_calltrace_view.nim
##
## IsoNim DOM-rendering view for the Calltrace panel.
##
## Renders a live, reactive DOM tree driven by `CalltraceVM` signals.
## When the VM's signals change (visible lines, selected entry,
## scroll indicators, search query), the DOM updates automatically
## via IsoNim's `createRenderEffect`.
##
## Two structures are produced:
##
## - `MockRenderer` — simple test-friendly DOM used by headless unit
##   tests (see `src/tests/gui/tests/views/isonim_views_test.nim`).
##
## - `WebRenderer` — Karax-compatible DOM that preserves the exact
##   class names, IDs, and hierarchy that Playwright page objects
##   (`CallTracePane`, `CallTraceEntry`) expect:
##     `.component-container.calltrace-view.isonim-calltrace`
##     `.calltrace-call-line.calltrace-row[.event-selected]`
##     `.call-child-box#local-call-{index}`
##     `.toggle-call > .{dot|collapse}-call-img`
##     `.call-text#local-call-text-{index}` (click = select / double-click = jump)
##     `.calltrace-search > form > input.calltrace-search-input`
##     `.call-search-results > .search-result`
##
## Both renderers share the `forIn` / `indexEach` reactive list logic
## but render row contents differently to satisfy each contract.
##
## The DSL is used to express structure in single `ui()` blocks per
## logical region; reactive attributes (class, style, text) are wrapped
## automatically by the macro. Only behaviour that the DSL cannot
## express directly — `addEventListener` for handlers that need the
## raw `Event` object, scroll listeners — uses imperative wiring on
## elements captured via `ref = var`.

import std/[json, options, tables]

import isonim/core/[signals, computation]
import isonim/dsl/ui
import isonim/dsl/components
import isonim/testing/mock_dom

when defined(js):
  import isonim/web/web_renderer
  import isonim/web/dom_api as isonim_dom

import ../store/types
import ../backend/backend_service
import ../viewmodels/calltrace_vm

# ---------------------------------------------------------------------------
# Per-row click handlers
# ---------------------------------------------------------------------------
#
# The DSL attaches handlers via `onclick = expr` which expects `proc()`.
# Each row's handler must read the *current* line value so that updates
# to a row's underlying CallLine (via `indexEach`) are reflected in the
# action the click triggers. We achieve this by closing over the
# `item()` accessor: the handler reads the live signal value when fired,
# rather than capturing a stale snapshot.

type
  RowHandlers = object
    onSelect:    proc()
    onDblClick:  proc()
    onToggle:    proc()

proc rowHandlers(vm: CalltraceVM; item: proc(): CallLine): RowHandlers =
  ## Build the trio of click handlers used by both Mock and Web row
  ## bodies. Each handler reads the latest CallLine via `item()` so it
  ## stays correct under indexEach signal updates.
  let getLine = item
  RowHandlers(
    onSelect: proc() =
      let line = getLine()
      # Single click in the legacy Karax calltrace selects the row AND
      # navigates to the source location (calltraceJump). Without the
      # navigation, Playwright `activate()` selects the row but the
      # editor never opens the target file.
      vm.selectEntry(some(line.index))
      vm.doubleClickEntry(line.index),
    onDblClick: proc() =
      vm.doubleClickEntry(getLine().index),
    onToggle: proc() =
      vm.toggleExpandCallChildren(getLine().index),
  )

# ---------------------------------------------------------------------------
# Reactive helpers used inside DSL expressions
# ---------------------------------------------------------------------------

proc selectedRowClass(base: string; vm: CalltraceVM; item: proc(): CallLine): string =
  ## Compute the row class with the optional selected modifier.
  ## Wrapping this in a proc keeps the DSL attribute expression short.
  let sel = vm.selectedEntry.val
  let line = item()
  if sel.isSome and sel.get == line.index:
    base & " selected"
  else:
    base

proc paddingForDepth(item: proc(): CallLine; pxPerLevel: int): string =
  let depth = item().depth
  if depth > 0: $(depth * pxPerLevel) & "px" else: "0px"

proc displayIf(cond: bool): string =
  if cond: "block" else: "none"

# ---------------------------------------------------------------------------
# MockRenderer renderer — simple structure for headless unit tests
# ---------------------------------------------------------------------------

proc argsForRow(vm: CalltraceVM; item: proc(): CallLine): seq[CallArg] =
  ## Look up the per-call argument list for the row's CallLine. Reads
  ## ``vm.store.calltrace.args.val`` reactively so views that wrap this
  ## inside a ``createRenderEffect`` re-run whenever the args map
  ## changes (a new calltrace section was loaded), or whenever the row's
  ## underlying CallLine swaps to a different ``callKey`` (indexEach
  ## reuses row elements as the visible-lines slice shifts).
  let line = item()
  let argsTable = vm.store.calltrace.args.val
  if line.callKey.len == 0:
    return @[]
  if line.callKey notin argsTable:
    return @[]
  for arg in argsTable[line.callKey]:
    if arg.name != "__return":
      result.add arg

proc returnValueForRow(vm: CalltraceVM; item: proc(): CallLine): string =
  ## Storybook fixtures can carry a synthetic ``__return`` arg so the
  ## IsoNim visual surface mirrors the Karax calltrace's ``=> value`` spans.
  ## Real calltrace rows that do not provide this sentinel render unchanged.
  let line = item()
  let argsTable = vm.store.calltrace.args.val
  if line.callKey.len == 0 or line.callKey notin argsTable:
    return ""
  for arg in argsTable[line.callKey]:
    if arg.name == "__return":
      return arg.text
  ""

proc returnArrowForRow(vm: CalltraceVM; item: proc(): CallLine): string =
  if returnValueForRow(vm, item).len > 0: " => " else: ""

proc renderCallLineRowMock(r: MockRenderer; vm: CalltraceVM;
                           item: proc(): CallLine): MockNode =
  ## Render a single calltrace row in the Mock-friendly structure.
  ## Only the row class, padding, name text and click handlers are
  ## reactive; all attribute updates are wired via the DSL.
  let h = rowHandlers(vm, item)
  var argsContainer: MockNode
  let row = ui(r):
    tdiv(class = selectedRowClass("calltrace-call-line", vm, item),
         padding_left = paddingForDepth(item, 16),
         onclick = h.onSelect,
         ondblclick = h.onDblClick):
      span(class = "call-name"):
        text item().name
      tdiv(class = "call-args", ref = argsContainer):
        discard

  # Reactively populate the args container with one ``.call-arg`` element
  # per call argument. Mirrors the historical Karax call-argument markup
  # so headless tests can assert the same DOM contract Playwright relies on.
  # We rebuild children from
  # scratch on each fire — this stays cheap because typical call-arg
  # counts are small (<10) and the effect only fires when the row's args
  # actually change.
  createRenderEffect proc() =
    let line = item()
    let callArgs = argsForRow(vm, item)
    r.clearChildren(argsContainer)
    # Iterate by index and copy the arg value into a local ``let``: the
    # DSL macro emits closures for each dynamic attribute, which can't
    # capture a ``lent T`` (Nim's default iteration view for ref-free
    # value types).  A plain ``let`` decouples the closures from the seq.
    for idx in 0 ..< callArgs.len:
      let argName = callArgs[idx].name
      let argText = callArgs[idx].text
      let argEl = ui(r):
        tdiv(class = "call-arg",
             id = "call-arg-" & line.callKey & "-" & argName):
          tdiv(class = "call-arg-header"):
            tdiv(class = "call-arg-name"):
              text argName & "="
            tdiv(class = "call-arg-text"):
              text argText
      r.appendChild(argsContainer, argEl)

  row

proc renderCalltracePanel*(r: MockRenderer; vm: CalltraceVM): MockNode =
  ## Render the complete Calltrace panel for Mock-based tests.
  ##
  ## Structure (matches `isonim_views_test.nim` expectations):
  ##   div.calltrace-component
  ##     div.more-above              (display reactive on hasMoreAbove)
  ##     div.calltrace-loading       (display reactive on isLoading)
  ##     div.calltrace-lines         (populated reactively by indexEach)
  ##     div.more-below              (display reactive on hasMoreBelow)
  ##     div.calltrace-search-row
  ##       input.calltrace-search-input
  var linesContainer: MockNode

  let panel = ui(r):
    tdiv(class = "calltrace-component"):
      tdiv(class = "more-above",
           display = displayIf(vm.hasMoreAbove.val)):
        discard
      tdiv(class = "calltrace-loading",
           display = displayIf(vm.isLoading.val)):
        text "Loading..."
      tdiv(class = "calltrace-lines", ref = linesContainer):
        discard
      tdiv(class = "more-below",
           display = displayIf(vm.hasMoreBelow.val)):
        discard
      tdiv(class = "calltrace-search-row"):
        input(class = "calltrace-search-input",
              placeholder = "Search calltrace...")

  indexEach[CallLine, MockRenderer, MockNode](r, linesContainer,
    proc(): seq[CallLine] = vm.visibleLines.val,
    proc(item: proc(): CallLine, index: int): MockNode =
      renderCallLineRowMock(r, vm, item))

  panel

# ---------------------------------------------------------------------------
# WebRenderer renderer — Karax-compatible structure for Playwright tests
# ---------------------------------------------------------------------------
#
# Each row's DOM mirrors the legacy Karax calltrace component:
#
#   div.calltrace-call-line.calltrace-row [.event-selected]
#     span                                           depth offset (min-width)
#     div.calltrace-child.call-depth
#       div.call-child-box#local-call-{index}
#         span.toggle-call                           click = expand/collapse
#           div.{collapse|dot}-call-img
#         div.call-text#local-call-text-{index}      click = select; dbl = jump
#           text "{name} #{index}"
#         div.call-args
#           text "()"
#
# `.call-text` is the click target — a single click selects the row,
# a double click navigates to source.

when defined(js):

  proc createSvgElement(tag: cstring): isonim_dom.Element =
    {.emit: "`result` = document.createElementNS('http://www.w3.org/2000/svg', `tag`);".}

  proc appendTraceLine(svg: isonim_dom.Element; x1, y1, x2, y2: float) =
    let line = createSvgElement(cstring"line")
    isonim_dom.setAttribute(line, cstring"x1", cstring($x1))
    isonim_dom.setAttribute(line, cstring"y1", cstring($y1))
    isonim_dom.setAttribute(line, cstring"x2", cstring($x2))
    isonim_dom.setAttribute(line, cstring"y2", cstring($y2))
    isonim_dom.setAttribute(line, cstring"stroke-width", cstring"0.5")
    isonim_dom.appendChild(isonim_dom.Node(svg), isonim_dom.Node(line))

  proc rowClassWeb(vm: CalltraceVM; item: proc(): CallLine): string =
    let sel = vm.selectedEntry.val
    let line = item()
    if sel.isSome and sel.get == line.index:
      "calltrace-call-line calltrace-row event-selected"
    else:
      "calltrace-call-line calltrace-row"

  proc toggleIconClass(item: proc(): CallLine): string =
    let line = item()
    if line.hasChildren and line.isExpanded: "collapse-call-img"
    else: "dot-call-img"

  proc renderCallLineRowWeb(r: WebRenderer; vm: CalltraceVM;
                            item: proc(): CallLine): isonim_dom.Element =
    ## Render a single calltrace row using the Karax-compatible markup.
    ## All dynamic content (class, depth offset, expand state, IDs,
    ## name text, click handlers) is expressed in the DSL — the macro
    ## emits per-attr reactive effects so updates are fine-grained.
    ##
    ## NOTE: `indexEach` reuses the same row element across data changes
    ## (e.g. when scrolling shifts which CallLines are visible), so all
    ## per-line content — including IDs derived from `line.index` — must
    ## be reactive. Reading `item()` inside the DSL achieves that
    ## automatically.
    let h = rowHandlers(vm, item)
    var argsContainer: isonim_dom.Element
    let row = ui(r):
      tdiv(class = rowClassWeb(vm, item)):
        span(min_width = $(item().depth * 8) & "px"):
          discard
        tdiv(class = "calltrace-child call-depth"):
          tdiv(id = "local-call-" & $item().index, class = "call-child-box"):
            span(class = "toggle-call", onclick = h.onToggle):
              tdiv(class = toggleIconClass(item)):
                discard
            tdiv(id = "local-call-text-" & $item().index, class = "call-text",
                 onclick = h.onSelect, ondblclick = h.onDblClick):
              text item().name & " #" & $item().index
            tdiv(ref = argsContainer, class = "call-args",
                 id = "call-args-false-" & $item().index):
              discard
            span(class = "return"):
              span(class = "return-arrow"):
                text returnArrowForRow(vm, item)
              span(class = "return-text"):
                text returnValueForRow(vm, item)

    # Reactively populate the args container with one ``.call-arg``
    # element per argument. Mirrors the historical Karax call-argument
    # markup so Playwright's
    # ``CallTraceEntry.arguments()`` (page object) can locate each
    # arg via ``.call-arg`` and read the name from ``.call-arg-name``
    # (with the trailing ``=`` stripped) and the value from
    # ``.call-arg-text``. The effect re-runs whenever the args signal
    # changes (new section loaded) or the row's underlying CallLine
    # swaps to a different ``callKey`` (indexEach reuse on scroll).
    createRenderEffect proc() =
      let line = item()
      let callArgs = argsForRow(vm, item)
      r.clearChildren(argsContainer)
      # Opening "(": the legacy view emitted these as bare text nodes
      # inside the same ``.call-args`` container so the rendered string
      # reads ``(name=value, name2=value2)``.  Tests only locate the
      # ``.call-arg`` children, but the parens are part of the legacy
      # contract so we preserve them.
      let openParen = ui(r):
        span:
          text "("
      r.appendChild(argsContainer, openParen)
      # Iterate by index and copy each arg's fields into local ``let``s
      # so the DSL closures can capture them.  See the matching comment
      # in ``renderCallLineRowMock`` above for the lent-capture rationale.
      for i in 0 ..< callArgs.len:
        let argName = callArgs[i].name
        let argText = callArgs[i].text
        let argEl = ui(r):
          tdiv(class = "call-arg",
               id = "call-arg-" & $line.index & "-" & argName):
            tdiv(class = "call-arg-header",
                 id = "call-arg-header-" & $line.index & "-" & argName):
              tdiv(class = "call-arg-name",
                   id = "call-arg-name-" & $line.index & "-" & argName):
                text argName & "="
              tdiv(class = "call-arg-text",
                   id = "call-arg-text-" & $line.index & "-" & argName):
                text argText
        r.appendChild(argsContainer, argEl)
        if i < callArgs.len - 1:
          let sep = ui(r):
            span:
              text ", "
          r.appendChild(argsContainer, sep)
      let closeParen = ui(r):
        span:
          text ")"
      r.appendChild(argsContainer, closeParen)

    row

  proc renderSearchResultsList(r: WebRenderer; container: isonim_dom.Element;
                               vm: CalltraceVM) =
    ## Reactively populate the search-results container. The hide/show
    ## class flip is also reactive. On `mousedown`, the result emits a
    ## calltrace-jump command so the editor navigates to the entry.
    createRenderEffect proc() =
      let results = vm.backendSearchResults.val
      r.clearChildren(container)
      if results.len == 0:
        r.setAttribute(container, "class", "call-search-results hidden")
        return
      r.setAttribute(container, "class", "call-search-results")
      for res in results:
        let capturedRrTicks = res.rrTicks
        let key = res.key
        let name = res.name
        let resultEl = ui(r):
          tdiv(class = "search-result",
               onmousedown = proc() =
                 discard vm.store.backend.send(
                   "ct/calltrace-jump",
                   %*{"rrTicks": capturedRrTicks})):
            text "#" & key & " - rrTicks(" & $capturedRrTicks & "): " & name
        r.appendChild(container, resultEl)

  proc wireSearchForm(form, input: isonim_dom.Element; vm: CalltraceVM) =
    ## Wire up search form submission and Enter-key handling on the
    ## input. The DSL's `onclick` handler shape is `proc()`, but here
    ## we need access to the raw `Event` to call `preventDefault`, so
    ## these handlers are attached imperatively.
    let inputNode = isonim_dom.Node(input)
    isonim_dom.addEventListener(isonim_dom.Node(form), cstring"submit",
      proc(ev: isonim_dom.Event) =
        {.emit: "`ev`.preventDefault();".}
        {.emit: "`ev`.stopPropagation();".}
        var query: cstring
        {.emit: "`query` = `inputNode`.value || '';".}
        vm.setSearchQuery($query))
    isonim_dom.addEventListener(inputNode, cstring"keydown",
      proc(ev: isonim_dom.Event) =
        var keyCode: int
        {.emit: "`keyCode` = `ev`.keyCode || 0;".}
        if keyCode == 13:
          {.emit: "`ev`.preventDefault();".}
          {.emit: "`ev`.stopPropagation();".}
          var query: cstring
          {.emit: "`query` = `inputNode`.value || '';".}
          vm.setSearchQuery($query))

  proc wireScrollContainer(scrollContainer: isonim_dom.Element;
                            vm: CalltraceVM) =
    ## Wire scroll events to the VM. The DSL renderer-API `onscroll`
    ## variant exists, but the handler needs access to `scrollTop` from
    ## the element, so this is attached imperatively.
    const CALL_HEIGHT_PX = 24.0
    isonim_dom.addEventListener(isonim_dom.Node(scrollContainer),
      cstring"scroll",
      proc(ev: isonim_dom.Event) =
        var scrollTop: float
        {.emit: "`scrollTop` = `scrollContainer`.scrollTop || 0;".}
        vm.scroll(int64(scrollTop / CALL_HEIGHT_PX)))

  proc renderTraceSvg(r: WebRenderer; svgContainer: isonim_dom.Element;
                      vm: CalltraceVM) =
    ## Lightweight version of Karax ``redrawTraceLine`` for Storybook/visual
    ## parity.  It draws the same absolute SVG layer and approximate 8px-depth
    ## connector grid used by the legacy materialized calltrace.
    createRenderEffect proc() =
      let lines = vm.store.calltrace.lines.val
      r.clearChildren(svgContainer)
      let rowHeight = 25.0
      let width = 1868.0
      let height = max(float(lines.len) * rowHeight, 1.0)
      isonim_dom.setAttribute(svgContainer, cstring"width", cstring($width))
      isonim_dom.setAttribute(svgContainer, cstring"height", cstring($height))
      isonim_dom.setAttribute(svgContainer, cstring"viewBox",
                              cstring("0 0 " & $width & " " & $height))
      if lines.len < 2:
        return
      for i in 0 ..< lines.len:
        let depth = max(lines[i].depth, 0)
        let x1 = 10.0 + float(depth * 8)
        let topY = float(i) * rowHeight
        let centerY = topY + 12.5
        let bottomY = topY + rowHeight
        let startY = if i == 0: centerY else: topY
        let endY = if i == lines.high: centerY else: bottomY
        if endY > startY:
          appendTraceLine(svgContainer, x1, startY, x1, endY)
        if i < lines.high:
          let nextX = 10.0 + float(max(lines[i + 1].depth, 0) * 8)
          appendTraceLine(svgContainer, x1, bottomY, nextX, bottomY)

  proc renderCalltracePanel*(r: WebRenderer;
                             vm: CalltraceVM): isonim_dom.Element =
    ## Render the complete Calltrace panel using real DOM elements.
    ##
    ## DOM matches the legacy Karax `calltrace.nim render()` output so
    ## that Playwright page objects (CallTracePane, CallTraceEntry)
    ## continue to find every selector unchanged.
    var
      formEl, inputEl: isonim_dom.Element
      resultsContainer: isonim_dom.Element
      scrollContainer, innerContainer, linesContainer: isonim_dom.Element
      svgContainer: isonim_dom.Element

    let panel = ui(r):
      tdiv(id = "calltraceComponent-0",
           class = "component-container calltrace-view isonim-calltrace",
           `data-label` = "calltrace-data-label-0", tabindex = "2"):
        tdiv:
          tdiv(class = "calltrace-search"):
            form(ref = formEl, class = "calltrace-search-form-0"):
              input(ref = inputEl,
                    class = "calltrace-search-input calltrace-search-input-0 " &
                            "ct-input-panel ct-input-search-image",
                    `type` = "text", placeholder = "Search", tabindex = "0")
          tdiv(ref = resultsContainer, class = "call-search-results hidden"):
            discard
        tdiv(ref = scrollContainer,
             id = "calltraceScroll-0",
             class = "local-calltrace-view"):
          tdiv(ref = innerContainer,
               class = "local-calltrace",
               height = $(vm.store.calltrace.totalCallsCount.val.int * 24) & "px"):
            tdiv(ref = linesContainer, class = "calltrace-lines"):
              discard
        tdiv(class = "calltrace-loading",
             id = "calltrace-toggle-loading-0",
             display = displayIf(vm.isLoading.val)):
          text "Loading..."

    # Render the full window the store currently holds, not a
    # viewport-height-based slice.  The legacy Karax calltrace view
    # virtualised rendering by leveraging `translateY` and the DOM scroll
    # container (`#calltraceScroll-0`); the IsoNim view does not yet
    # implement that scroll-window translation, so a slicing memo here
    # would render only the first 25 lines and the remaining ~65 would
    # never enter the DOM.  That broke calltrace navigation for DB traces
    # (Python / Ruby sudoku): after a search-result click the calltrace
    # cursor moves inside the loaded section but the visible 25 rows
    # stayed at the top of the section, so Playwright's `findEntry` (which
    # only sees `.calltrace-call-line` elements that are in the DOM)
    # never observed the navigated function.  See:
    # `vm.visibleLines` (calltrace_vm.nim) — the slicing memo that the
    # Mock renderer still uses for its viewport-aware unit tests, and
    # `syncCalltraceData` (calltrace.nim) — which feeds the store.
    svgContainer = createSvgElement(cstring"svg")
    isonim_dom.setAttribute(svgContainer, cstring"id", cstring"svg-content-0")
    isonim_dom.setAttribute(svgContainer, cstring"class",
                            cstring"calltrace-svg-line")
    isonim_dom.setAttribute(svgContainer, cstring"width", cstring"1")
    isonim_dom.setAttribute(svgContainer, cstring"height", cstring"1")
    isonim_dom.setAttribute(svgContainer, cstring"viewBox", cstring"0 0 1 1")
    isonim_dom.appendChild(isonim_dom.Node(linesContainer),
                           isonim_dom.Node(svgContainer))

    indexEach[CallLine, WebRenderer, isonim_dom.Element](r, linesContainer,
      proc(): seq[CallLine] = vm.store.calltrace.lines.val,
      proc(item: proc(): CallLine, index: int): isonim_dom.Element =
        renderCallLineRowWeb(r, vm, item))

    renderSearchResultsList(r, resultsContainer, vm)
    renderTraceSvg(r, svgContainer, vm)
    wireSearchForm(formEl, inputEl, vm)
    wireScrollContainer(scrollContainer, vm)

    panel

  proc mountIsoNimCalltrace*(container: isonim_dom.Element;
                             vm: CalltraceVM) =
    ## Mount the IsoNim calltrace panel as a child of `container`.
    ## Reactive effects then handle every subsequent update — no manual
    ## redraw is needed. Call once, after the `CalltraceVM` exists.
    let r = WebRenderer()
    let panel = renderCalltracePanel(r, vm)
    isonim_dom.appendChild(isonim_dom.Node(container), isonim_dom.Node(panel))
